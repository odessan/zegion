--[[ Roll Cases for Brainrots -- 97665661589897

     KICK       : the whole case loop, and it never opens the minigame. What the
                  server sees is four messages -- charge, tier, launch, landed --
                  and the tier is a bare string the CLIENT picks:

                      RequestKick:FireServer({ tier = "Perfect" })

                  So the bar is a timing toy, not the protocol. Driving it means
                  sampling a 1.1s triangle wave, which needs frames; this game runs
                  at ~3fps on a loaded server, where a 0.95 band is never even
                  observed and the old bar-watching version simply never locked.
                  Declaring the tier skips the sampling problem AND the charge
                  animation. Tier decides distance, distance decides which of the
                  12 zones you land in, and the zone decides the case -- so Perfect
                  plus a forced landing is the whole farm.

                  Banking teleports rather than walks: the credit is a server-side
                  zone check that cares where you are, not how you got there.

                  What CANNOT be skipped is the arc DURATION. The real client only
                  reports a landing once elapsed >= arcDur, and the server refuses
                  an early one -- reporting at 0.1s into a 7.9s arc got the landing
                  dropped and a fallback credit at 15-18s instead. So the landing
                  waits out arcDur. The flight itself, every frame of animation
                  around it, and the travel back are all still gone; that one clock
                  is the server's and it stays.
     OPEN       : opens the ticked cases straight off the remote -- no confirm
                  dialog, no spin frame, 3 at a time through RequestOpenCaseMulti
                  (the server clamps count to 3). SKIP REVEAL switches off the
                  handler that plays the spin and answers the server in its place
                  -- firing RequestRevealComplete alone does NOT skip anything,
                  the client plays it either way. Three remotes feed the reveal
                  (CaseOpened, CaseReveal3D, CaseMulti3D) and cutting one leaves
                  the others playing. Needs getconnections.
     BASE       : Collect fires the base pad plus every plate slot; Place is the
                  pad's own auto-place. Both are one remote each and the server
                  refuses what you haven't earned, which is the normal case.
     SELL       : brainrotAll for the rarities you TICK, and only those. Nothing
                  is ticked by default on purpose -- an empty rarity list on this
                  remote means "all of them", which is how you sell your Secrets.
     CLAIM      : daily / offline / index gems / free wheel spin / like / perm
                  quest / the forever-reward ladder, fired in one pass.
     UPKEEP     : rebirth and the cheapest speed tile on a timer. Refusals are
                  normal -- the server says no until you qualify.

     The FLIGHT tab is a separate bargain and lives apart for that reason. The
     server sends the arc it wants flown -- start, direction, range, floor height,
     boost allowance -- and the CLIENT reports where it ended up:

         RequestKick:FireServer({ action = "landed", position = <Vector3> })

     MAX BOOST spends the whole allowance the server sent, through the game's own
     _G.KickFlightClient.Teleport, which clamps against that same allowance. Nothing
     is invented; it's what mashing boost for the full arc would have earned.

     FORCE LANDING answers with a zone of your choosing the moment the kick
     launches. Every field but Z comes back out of the server's own payload, so the
     one made-up number is how far down the runway you claim to have got -- and it
     skips the whole 10-20s flight, which is most of what a kick costs. Zone Z bands
     are in ZONE_Z below, and everything is clamped to the FinalWall the same way
     KickController clamps its own lap-end report.

     The kick half needs _G.KickAuto, the table KickController publishes (press,
     lock, state). That's the game's own client API for its own auto-kick, so it
     needs no gamepass and no key injection. If it's missing the panel says so and
     the kick toggle does nothing -- everything else still works.

     Read it through getrenv(), never with a bare _G -- see `gameG` below. An
     executor gives a pasted script its own global table, so a plain _G.KickAuto is
     nil here even while the game is happily running its own auto-kick off it.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl hides/shows it. The minus button rolls it up to a bare Zegion pill.
     Stop: getgenv().rollCasesStop() ]]

-- config ---------------------------------------------------------------------
-- The tier the client declares. KickController picks this off the bar and sends it
-- as a bare string -- "Bad" / "Good" / "Great" / "Excellent" / "Perfect" -- so the
-- bar is a timing toy and this is the actual protocol. Perfect is the top band and
-- the one that flies furthest.
local TIER = "Perfect"
local CHARGE_HOLD = 0.4 -- seconds between charge and tier. A real client can't send
-- these back to back because a human is watching a bar in between; a zero-length
-- charge is the one part of this sequence no player could produce. Don't set to 0.
local FLIGHT_WAIT = 6 -- seconds to wait for the server's arc after declaring the tier
local LAND_MARGIN = 0.2 -- seconds past arcDur before reporting the landing. The real
-- client's flight loop only reports once elapsed >= arcDur ("if arcDur2 <= v409"), so
-- it never lands early and the server evidently refuses one that does -- reporting at
-- 0.1s into a 7.9s arc got the landing dropped and a fallback credit at 15-18s. The
-- arc duration is the server's clock, not an animation, so it cannot be skipped; what
-- IS skipped is the flight itself and every frame of animation around it.
local LAUNCH_HOLD = 0.25 -- seconds between the server's "start" and our "launch". The
-- real client fires launch off a marker in the jump animation, which we never play;
-- this stands in for that beat. The arc does not arrive until the launch does.

local RETURN_EVERY = 4 -- seconds between AutoReturn fires while out of the zone.
-- Verbatim from AutoKickController -- the server ignores them faster than that.
local PRESS_GAP = 1.2 -- seconds after banking before the next charge. Below ~1 the
-- charge lands while the server still has you mid-kick and is dropped silently.
local FLIGHT_TIMEOUT = 25 -- give up waiting for a case after a kick. A kick that
-- lands short of every zone gives nothing, and waiting forever stalls the loop.
local BANK_TIMEOUT = 20 -- give up getting a case into the Collect zone. Generous
-- because the hop back from Zone12 is ~5000 studs and has to wait out streaming.

local OPEN_EVERY = 0.6 -- seconds between open batches. The reveal is skipped so
-- this is purely the server's own open cooldown; raise it if opens go missing.
local OPEN_BATCH = 3 -- RequestOpenCaseMulti clamps to 3 server-side. Not a knob.

local COLLECT_EVERY = 2 -- seconds between money sweeps
local PLACE_EVERY = 5 -- ...and auto-place fires
local SELL_EVERY = 10 -- ...and sell rounds. This one destroys brainrots: keep it slow.
local UPKEEP_EVERY = 6 -- ...and rebirth + speed. This one spends money.
-- Where each zone sits down the runway, as the midpoint of every part the zone's
-- folder owns in a dump of workspace.Map.Zones. The kick zone is at Z~107 and the
-- flight is +Z, so this list is also the value order -- Zone12 is the far end.
-- Zone8 and Zone9 were captured with 5 and 12 parts against Zone1's 315, so their
-- midpoints are the softest numbers here; if a landing there misses, widen from a
-- fresh dump rather than nudging blind.
local ZONE_Z = {
	{ "Zone1", 193 },
	{ "Zone2", 372 },
	{ "Zone3", 605 },
	{ "Zone4", 889 },
	{ "Zone5", 1220 },
	{ "Zone6", 1592 },
	{ "Zone7", 2013 },
	{ "Zone8", 2467 },
	{ "Zone9", 3025 },
	{ "Zone10", 3648 },
	{ "Zone11", 4310 },
	{ "Zone12", 5233 },
}
local FLIGHT_EDGE = 6 -- studs to stay back from the far wall. KickController's own
-- lap-end report lands at FinalWall.Z - 6, so this is its number, not a guess.

local SLOTS = 8 -- plate slots per plot, off a dump of Plots.Plot1.SlotConfigs (1-8,
-- 5 missing). Firing a slot you don't own is refused, so the range costs nothing.
local FOREVER_STEPS = 20 -- forever-reward ladder depth. Sequential and server-checked;
-- firing past the end is refused, so overshooting is free.

local KEY_TOGGLE = Enum.KeyCode.RightControl

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

if getgenv and getgenv().rollCasesStop then
	getgenv().rollCasesStop() -- re-running must not stack a second panel/loop
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local function remote(name)
	return Remotes:WaitForChild(name, 10)
end

local RequestAutoReturn = remote("RequestAutoReturn")
local RequestEquipBrainrot = remote("RequestEquipBrainrot")
local RequestOpenCase = remote("RequestOpenCase")
local RequestOpenCaseMulti = remote("RequestOpenCaseMulti")
local RequestRevealComplete = remote("RequestRevealComplete")
local CaseOpened = remote("CaseOpened")
local CaseError = remote("CaseError")
local RequestBasePad = remote("RequestBasePad")
local RequestCollect = remote("RequestCollect")
local SellShopRequest = remote("SellShopRequest")
local RequestRebirth = remote("RequestRebirth")
local RequestSpeedUpgrade = remote("RequestSpeedUpgrade")
local RequestKick = remote("RequestKick")
local KickFeedback = remote("KickFeedback")

-- The game's own case table: 32 cases and every update adds to it, so requiring
-- beats copying. Luck is the tier ordering the shop and the zone odds both use.
local casesConfig
pcall(function()
	casesConfig = require(ReplicatedStorage:WaitForChild("CasesConfig", 10))
end)
if not (casesConfig and casesConfig.Cases) then
	-- Both dropdowns are built from it, and WindUI has nothing to draw from an empty
	-- list. Saying so beats a panel that half-builds and then errors somewhere else.
	warn("[rollcases] ReplicatedStorage.CasesConfig didn't load -- wrong game, or it moved.")
	return
end

local say = function() end -- replaced by the panel below

-- game globals ---------------------------------------------------------------
-- An executor runs a pasted script in its OWN global table. The game's LocalScripts
-- share a different one, and that's where KickController publishes KickAuto and
-- KickFlightClient -- so a plain `_G.KickAuto` here reads an empty table and is
-- always nil, no matter how well the game is running. getrenv() is the way across.
--
-- Captured once because the table itself is stable; the fields on it are read live
-- at every call, which is what matters (KickFlightClient is republished per flight).
-- Falls back to our own _G on an executor without getrenv, where the two may
-- genuinely be the same table.
local gameG = _G
pcall(function()
	local renv = getrenv()
	if type(renv) == "table" and type(renv._G) == "table" then
		gameG = renv._G
	end
end)

-- cases ----------------------------------------------------------------------
-- Cheapest first. Luck is the one field every case has and it's monotonic with
-- tier, so it doubles as the ordering and saves keeping a second list in sync.
local function caseKeys()
	local out = {}
	for key, def in pairs(casesConfig and casesConfig.Cases or {}) do
		table.insert(out, { key = key, luck = tonumber(def.Luck) or 0, name = def.DisplayName or key })
	end
	table.sort(out, function(a, b)
		return a.luck < b.luck
	end)
	return out
end

-- The server writes your stock onto the player as one attribute per case type.
-- That's the same number the confirm dialog prints as "(You own %d)".
local function owned(key)
	return tonumber(player:GetAttribute("Cases_" .. key)) or 0
end

-- Rarities in the order the cases introduce them: walk the cases cheapest first
-- and take each tier the first time it shows up. Derived rather than written down
-- because this is the list the SELL toggle destroys things from.
local function rarities()
	local seen, out = {}, {}
	for _, entry in ipairs(caseKeys()) do
		local def = casesConfig.Cases[entry.key]
		for _, r in ipairs(def.Rarities or {}) do
			if not seen[r] then
				seen[r] = true
				table.insert(out, r)
			end
		end
	end
	return out
end

-- kick -----------------------------------------------------------------------
-- KickController publishes this for its own auto-kick. We only want state().inZone
-- off it now -- the kick itself goes over the remote -- but that one field saves
-- reimplementing the zone test. Read live; it doesn't exist until the controller runs.
local function kickApi()
	local api = gameG.KickAuto
	return type(api) == "table" and api or nil
end

-- Bumped by the KickFeedback listener further down, once per arc the server sends.
-- kickOnce records it before charging and waits for it to move, which is how it
-- knows the server accepted the kick without trusting a return value.
local flightSeq = 0

-- Declared up here, not down in the flight section: kickOnce reads flight.last and
-- a local declared after it would leave that reading a nil global instead.
local flight = { boost = false, force = false, zone = "Zone12", last = nil }

local function zone(name)
	local zones = workspace:FindFirstChild("Zones")
	local part = zones and zones:FindFirstChild(name)
	return part and part:IsA("BasePart") and part or nil
end

local function holding()
	local case = player:GetAttribute("_HoldingCase")
	return type(case) == "string" and case ~= "" and case or nil
end

-- The Collect zone is ~14 studs from the jump zone, but at 3fps a walk over it is
-- seconds of nothing. Set the root straight onto it and give the server a beat to
-- agree we're there -- the credit is a zone check on the server's copy of our
-- position, so what matters is that it sees us inside, not how we arrived.
local function tpTo(part)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (root and part) then
		return false
	end
	root.CFrame = CFrame.new(part.Position + Vector3.new(0, 3, 0))
	-- Landing at Zone12 puts us ~5000 studs from the Collect zone, and a hop that far
	-- arrives before anything around it has streamed in. Touching the world while
	-- paused is how a deposit silently doesn't take.
	local spins = 0
	while player.GameplayPaused and spins < 40 do
		task.wait(0.1)
		spins += 1
	end
	return true
end

-- One kick, start to banked. Returns what landed, or nil.
--
-- This does NOT touch the minigame. The bar is a client-side timing toy: the whole
-- protocol the server sees is charge -> tier -> launch -> landed, and the tier is a
-- bare string the client picks. Driving the bar instead means sampling a 1.1s
-- triangle wave, which needs frames -- at the 3fps this game actually runs at, a
-- 0.95 band is never even observed, so the old version simply never locked.
-- Declaring the tier sidesteps the sampling problem entirely and skips the charge
-- animation as a bonus.
local function kickOnce(alive)
	-- Still carrying from a kick that timed out last cycle -- bank it before kicking
	-- again, or the charge is refused and we spin.
	if not holding() then
		local api = kickApi()
		if api and not api.state().inZone then
			say("returning to the jump zone")
			RequestAutoReturn:FireServer()
			local deadline = os.clock() + RETURN_EVERY
			repeat
				task.wait(0.2)
			until api.state().inZone or os.clock() > deadline or not alive()
			if not api.state().inZone then
				return nil -- next cycle fires AutoReturn again
			end
		end

		-- charge -> tier. CHARGE_HOLD is the beat between them: the real client can't
		-- send these back to back because a human is watching a bar in between, and a
		-- zero-length charge is the one thing in this sequence that looks like nothing
		-- a player could produce.
		local seen = flightSeq
		say("kicking (" .. TIER .. ")")
		RequestKick:FireServer({ action = "charge" })
		task.wait(CHARGE_HOLD)
		RequestKick:FireServer({ tier = TIER })

		-- Now three hops, not one: the server sends "start", our listener answers
		-- with "launch" after LAUNCH_HOLD, and only then does the arc come back.
		-- FLIGHT_WAIT has to cover all of that plus a 3fps round trip.
		local deadline = os.clock() + FLIGHT_WAIT
		repeat
			task.wait(0.1)
		until flightSeq ~= seen or os.clock() > deadline or not alive()
		if flightSeq == seen then
			say("no flight came back - kick refused?")
			return nil
		end

		-- The landing itself is fired by the KickFeedback handler, so a hand-thrown
		-- kick gets it too. What's left is waiting for the server to credit a case.
		--
		-- That wait is the open question: if the server paces the credit to the arc
		-- duration it sent us, no client can skip it and this is the floor. If it
		-- credits on the landed message, this should be one round trip and anything
		-- longer means our position was refused and the case arrived by the normal
		-- route instead. Timing it is the only way to tell those apart, so say it.
		local landedAt = os.clock()
		local deadline2 = os.clock() + FLIGHT_TIMEOUT
		repeat
			task.wait(0.1)
		until holding() or os.clock() > deadline2 or not alive()
		if holding() then
			local took = os.clock() - landedAt
			local arc = tonumber(flight.last and flight.last.arcDur) or 0
			warn(("[rollcases] case took %.1fs after landed (arcDur was %.1fs) -- %s")
				:format(took, arc, took < 3 and "landing accepted"
					or "landing looks refused, server fell back to its own"))
		end
	end

	local case = holding()
	if not case then
		return nil -- landed short of every zone, or the kick was refused
	end

	local collect = zone("CollectZone")
	if not collect then
		say("no CollectZone -- can't bank")
		return nil
	end

	say("banking " .. case)
	local deadline = os.clock() + BANK_TIMEOUT
	repeat
		tpTo(collect) -- re-issued: respawns and the landing shove both move us off it
		task.wait(0.3)
	until not holding() or os.clock() > deadline or not alive()

	if holding() then
		-- How far off the zone we ended up is the whole diagnosis: still at the
		-- landing site means the hop back never took, sitting on the zone means the
		-- server isn't crediting the deposit.
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		local gap = root and (root.Position - collect.Position).Magnitude or -1
		warn(("[rollcases] still holding %s, %.0f studs from CollectZone"):format(case, gap))
		say(("stuck holding %s (%.0f studs off)"):format(case, gap))
		return nil
	end
	return case
end

-- open -----------------------------------------------------------------------
-- Firing RequestRevealComplete does NOT skip the reveal. It only tells the server
-- we're done watching -- FrameController's own CaseOpened handler then calls
-- playReveal(payload) unconditionally, and THAT is the animation. Its one silent
-- path needs payload.PlayerAuto, which only the server sets on its own auto-open
-- session, so there is no flag we can pass to get it.
--
-- So skipping means switching that handler off and answering the server ourselves.
-- Same trick flash_for_brainrots.lua uses on its dash cutscene.
--
-- ponytail: needs getconnections; without it the reveal plays and we say so rather
-- than pretending the toggle did something. It also takes out LoreDialogueController's
-- CaseOpened listener, which is first-open lore chatter -- restored on toggle-off.
-- Cutting a controller off an event we answer ourselves. Two rules, both learned the
-- hard way: mute BEFORE connecting our own handler, or getconnections hands us our
-- own and we switch ourselves off with the rest; and mute every remote that feeds
-- the thing, not just the obvious one.
local muted = {}

local function mute(remote)
	if not (getconnections and remote) or muted[remote] then
		return false
	end
	local list = {}
	for _, c in ipairs(getconnections(remote.OnClientEvent)) do
		pcall(function()
			c:Disable()
		end)
		table.insert(list, c)
	end
	muted[remote] = list
	return true
end

local function unmute(remote)
	local list = remote and muted[remote]
	if not list then
		return
	end
	for _, c in ipairs(list) do
		pcall(function()
			c:Enable()
		end)
	end
	muted[remote] = nil
end

local revealConn = nil

local REVEAL_REMOTES = { CaseOpened, remote("CaseReveal3D"), remote("CaseMulti3D") }

local function skipReveal(enable)
	if enable == (revealConn ~= nil) then
		return true -- already in the asked-for state
	end

	if not enable then
		pcall(function()
			player:SetAttribute("_ShowCasesOpening", true)
			Remotes.RequestSetSetting:FireServer({ key = "ShowCasesOpening", value = true })
		end)
		if revealConn then
			revealConn:Disconnect()
			revealConn = nil
		end
		for _, r in ipairs(REVEAL_REMOTES) do
			unmute(r)
		end
		return true
	end

	-- The game's own Settings switch. CaseEquipOpenController's CaseReveal3D handler
	-- returns early when this is false, so it's the supported way to lose the 3D
	-- reveal. Set locally for right now, sent to the server so it survives a respawn.
	pcall(function()
		player:SetAttribute("_ShowCasesOpening", false)
		Remotes.RequestSetSetting:FireServer({ key = "ShowCasesOpening", value = false })
	end)

	if not getconnections then
		say("no getconnections -- reveals will keep animating")
		return false
	end

	-- Three remotes feed the reveal, not one. CaseOpened is the spin frame,
	-- CaseReveal3D the single 3D reveal, CaseMulti3D the three-at-a-time one --
	-- cutting only the first is why this kept animating.
	for _, r in ipairs(REVEAL_REMOTES) do
		mute(r)
	end

	-- Connected after the mute, and now the only thing releasing the server's gate.
	-- Miss it and the next open is refused.
	revealConn = CaseOpened.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		pcall(function()
			if type(payload.RevealIds) == "table" and #payload.RevealIds > 0 then
				RequestRevealComplete:FireServer({ ids = payload.RevealIds })
			elseif type(payload.RevealId) == "string" and payload.RevealId ~= "" then
				RequestRevealComplete:FireServer({ id = payload.RevealId })
			end
		end)
	end)
	return true
end

-- The two reasons the server refuses an open. Worth surfacing: "nothing is happening"
-- is nearly always a full inventory, and no amount of retrying fixes that.
local lastError = nil
CaseError.OnClientEvent:Connect(function(payload)
	if type(payload) == "table" and type(payload.reason) == "string" then
		lastError = payload.reason
	end
end)

-- The confirm dialog equips before it opens (CaseOpenConfirm.onceFire) and the held
-- case is what the open animation reads. Only fired on a key change -- re-equipping
-- the case you're already holding is a wasted round trip per batch.
local equipped = nil
local function openBatch(key)
	local have = owned(key)
	if have <= 0 then
		return 0
	end
	if equipped ~= key then
		equipped = key
		RequestEquipBrainrot:FireServer("case::" .. key)
		task.wait(0.15)
	end

	local n = math.min(OPEN_BATCH, have)
	if n > 1 then
		RequestOpenCaseMulti:FireServer({ case = key, count = n })
	else
		RequestOpenCase:FireServer(key)
	end

	-- Stock dropping is the server confirming the open. The return values lie and
	-- CaseOpened fires for other players' opens too.
	local deadline = os.clock() + math.max(OPEN_EVERY, 2)
	repeat
		task.wait(0.1)
	until owned(key) < have or os.clock() > deadline
	return have - owned(key)
end

-- flight ---------------------------------------------------------------------
-- Everything here hangs off one server message. When a kick launches, the server
-- sends KickFeedback{kind="flight", ...} carrying the arc it wants the client to
-- fly: flatStartPos, flatDir, targetRange, baseFloorY and a boost allowance. The
-- client simulates that arc for ten to twenty seconds and then reports back with
-- RequestKick{action="landed", position=...}.
--
-- So the landing point is whatever the client says it is. The two toggles below sit
-- on opposite sides of that: BOOST spends the allowance the server itself sent, and
-- LAND reports a position of our choosing and skips the flight entirely.

local zoneZ = {}
for _, entry in ipairs(ZONE_Z) do
	zoneZ[entry[1]] = entry[2]
end

-- Same lookup KickController's lapWarpSpanZ does, same fallback. Past this wall the
-- runway wraps and the client counts a lap instead of landing, so it's the ceiling
-- on any Z we report.
local function spanEndZ()
	local walls = workspace:FindFirstChild("InvisWalls")
	local wall = walls and walls:FindFirstChild("FinalWall")
	return (wall and wall:IsA("BasePart")) and wall.Position.Z or 5294.2
end

-- The game publishes _G.KickFlightClient.Teleport(studs) per flight and clamps what
-- you ask for to the allowance in the payload, returning what it actually granted.
-- Spending the whole allowance in one call is what mashing boost for the entire arc
-- would have earned -- the cap is the server's number, so this forges nothing.
local function maxBoost(payload)
	local api = gameG.KickFlightClient
	if not (type(api) == "table" and type(api.Teleport) == "function") then
		say("no _G.KickFlightClient -- flight already over?")
		return
	end

	-- Two ways the server expresses the allowance. If it sends neither, the client's
	-- own cap is infinity and asking for "everything" would fling us off the map, so
	-- that case does nothing rather than guessing a number.
	local cap = tonumber(payload.boostDistCap)
	if not cap then
		local horiz = tonumber(payload.horizClampDist)
		cap = horiz and horiz - (tonumber(payload.targetRange) or 0) or nil
	end
	if not (cap and cap > 0) then
		say("no boost allowance in this kick")
		return
	end

	say(("boost +%d studs"):format(api.Teleport(cap)))
end

-- Every component but Z comes straight back out of the server's own payload, so the
-- one invented number is how far down the runway we claim to have got.
--
-- ponytail: the client's own flight keeps running and reports its natural landing a
-- few seconds later, so the server sees two "landed" for one kick. It has taken the
-- first one every time in testing; if that ever changes, the fix is to disable
-- KickController's KickFeedback connection with getconnections and drive the whole
-- flight from here instead.
local function landAt(payload, zone)
	local target = zoneZ[zone]
	if not (payload and target) then
		say("no flight in progress")
		return
	end

	local start = payload.flatStartPos
	local x = typeof(start) == "Vector3" and start.X or 0
	local y = tonumber(payload.baseFloorY) or (typeof(start) == "Vector3" and start.Y) or 0

	-- How far this kick was ever allowed to go. The server sends the range it wants
	-- flown plus whatever boost allowance you have, and horizClampDist when it wants
	-- to say so outright -- so a zone past that was never reachable on this kick and
	-- claiming it is just asking to be clamped or rejected. Say which zone you got
	-- instead of silently landing short.
	-- Only horizClampDist is the server SAYING how far it will accept. targetRange
	-- plus boostDistCap is just the arc it expects you to fly, and clamping to that
	-- turns a landing the server might well have taken into one we refused to ask
	-- for. So clamp to the stated limit when there is one, and otherwise only to the
	-- far wall, which is map geometry rather than policy.
	local range = tonumber(payload.targetRange) or 0
	local cap = tonumber(payload.boostDistCap) or 0
	local horiz = tonumber(payload.horizClampDist)
	local startZ = typeof(start) == "Vector3" and start.Z or 0
	local reachZ = horiz and (startZ + horiz) or math.huge

	-- The arc, once per kick, because these are the numbers that decide whether a
	-- zone is reachable at all and nothing else prints them.
	warn(("[rollcases] arc: startZ=%.0f targetRange=%.0f boostCap=%.0f horizClamp=%s -> natural Z %.0f")
		:format(startZ, range, cap, horiz and ("%.0f"):format(horiz) or "none", startZ + range + cap))

	local z = math.min(target, reachZ, spanEndZ() - FLIGHT_EDGE)

	RequestKick:FireServer({ action = "landed", position = Vector3.new(x, y, z) })

	if z < target - 1 then
		-- Name the zone we actually reached, so "Zone12 does nothing" reads as
		-- "Zone12 is out of range on a Perfect kick" instead of looking like a bug.
		local got = zone
		for _, entry in ipairs(ZONE_Z) do
			if entry[2] <= z then
				got = entry[1]
			end
		end
		say(("%s out of range (max Z %d) - landed %s"):format(zone, reachZ, got))
	else
		say(("landed in %s (Z %d)"):format(zone, z))
	end
end

-- Our own listener, and the switch that takes KickController's off the same event.
-- That handler is why a forced landing kept coming up short: it runs the whole
-- flight simulation and fires its OWN reportLanding at the natural distance a few
-- seconds after ours, and the server honours the later one. It is also the flight
-- animation. Cutting it settles both at once.
local flightConn = nil

local function connectFlight()
	flightConn = KickFeedback.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or payload.kicker ~= player then
			return
		end

		-- The exchange is start -> launch -> flight, and the launch half is ours now.
		-- doLaunch fires it from inside runLocalKickSequence, which only runs on
		-- "start" and is exactly the handler cutFlight switches off -- so with the
		-- flight cut nobody sends it, the server never sends the arc, and the loop
		-- sits there reporting "no flight came back". Send it here instead.
		if payload.kind == "start" then
			if flight.force then
				task.delay(LAUNCH_HOLD, function()
					pcall(function()
						RequestKick:FireServer({ action = "launch" })
					end)
				end)
			end
			return
		end

		if payload.kind ~= "flight" then
			return
		end
		flight.last = payload
		flightSeq += 1 -- kickOnce is waiting on this
		task.defer(function()
			if flight.boost then
				pcall(maxBoost, payload) -- no-op while the flight is cut; see cutFlight
			end
			if flight.force then
				-- Wait out the server's own clock, then report. Firing early is what
				-- was losing the landing; see LAND_MARGIN.
				local arc = tonumber(payload.arcDur) or 0
				task.delay(arc + LAND_MARGIN, function()
					pcall(landAt, payload, flight.zone)
				end)
			end
		end)
	end)
end

-- Ours goes off first so getconnections can't hand it back to us as one of the
-- game's, then straight back on afterwards -- we still need the arc payload.
--
-- Muting KickFeedback also means _G.KickFlightClient is never republished, since the
-- game creates it inside the handler we just cut. That's fine: boost only matters
-- when you're flying the real arc, and if you're forcing the landing you picked the
-- distance directly. The two are mutually exclusive by nature, not by accident.
local function cutFlight(enable)
	if flightConn then
		flightConn:Disconnect()
		flightConn = nil
	end
	if enable then
		if not mute(KickFeedback) then
			say("no getconnections -- the flight animation stays")
		end
	else
		unmute(KickFeedback)
	end
	connectFlight()
end

connectFlight()

-- claims ---------------------------------------------------------------------
-- Every one of these is fire-and-forget and refused when there's nothing to take, so
-- the whole set goes in one pass with no state to track. pcall each: a remote missing
-- after an update shouldn't take the rest of the list with it.
local function claimAll()
	local function fire(name, ...)
		local r = Remotes:FindFirstChild(name)
		if r then
			pcall(function(...)
				if r:IsA("RemoteFunction") then
					r:InvokeServer(...)
				else
					r:FireServer(...)
				end
			end, ...)
		end
	end

	fire("RequestDailySync")
	fire("RequestDailyClaim")
	fire("RequestClaimOffline")
	fire("RequestClaimAllIndexGems")
	fire("RequestSpinWheel", { mode = "free" })
	fire("RequestClaimLikeReward", {})
	fire("RequestClaimPermQuest", {})
	-- The ladder is sequential and the server checks the order, so walking it up from
	-- 1 claims everything you're owed and is refused for everything you aren't.
	for i = 1, FOREVER_STEPS do
		fire("RequestCollectForeverReward", i)
	end
	say("claim pass sent")
end

-- loops ----------------------------------------------------------------------
-- One generation counter per toggle. Without it, off-then-on inside a single interval
-- leaves the sleeping thread alive next to the new one, firing at double rate.
local function every(name, state, interval, body)
	state.gen += 1
	local mine = state.gen
	task.spawn(function()
		while state.on and state.gen == mine do
			-- The pcall is load-bearing -- models vanish mid-sweep and a dead instance
			-- throws -- but swallowing the message turns every bug into "it just sits
			-- there". Say what broke and carry on.
			local ok, err = pcall(body, function()
				return state.on and state.gen == mine
			end)
			if not ok then
				warn(("[rollcases] %s: %s"):format(name, tostring(err)))
				say(name .. " errored - see F9")
			end
			task.wait(interval)
		end
	end)
end

local kicker = { on = false, gen = 0 }
local opener = { on = false, gen = 0 }
local collector = { on = false, gen = 0 }
local placer = { on = false, gen = 0 }
local seller = { on = false, gen = 0 }
local upkeeper = { on = false, gen = 0 }
local claimer = { on = false, gen = 0 }
local LOOPS = { kicker, opener, collector, placer, seller, upkeeper, claimer }

local pickedCases, pickedRarities = {}, {}
local banked = 0

-- gui ------------------------------------------------------------------------
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a
-- restyle is one file and not seventeen. Fetched here rather than installed by the
-- loader, so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Roll Cases for Brainrots",
	folder = "RollCases",
	size = UDim2.fromOffset(440, 430),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local Farm = Tab:Section({ Title = "Cases", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })
local Base = Tab:Section({ Title = "Base", Icon = "solar:home-smile-bold", Box = true, BoxBorder = true, Opened = true })
local Extra =
	Tab:Section({ Title = "Extras", Icon = "solar:gift-bold", Box = true, BoxBorder = true, Opened = true })

Farm:Toggle({
	Title = "Auto Kick",
	Desc = "Declare PERFECT, land in the Flight tab's zone, teleport the case to Collect",
	Value = false,
	Callback = function(v)
		kicker.on = v
		-- The loop is only fast because the landing is answered for it; without this
		-- every kick sits through the real 10-20s arc. Same flag the Flight tab's
		-- Force Landing drives, so the two can't disagree.
		flight.force = v
		cutFlight(v) -- takes KickController's flight handler off the event
		if not v then
			return
		end
		-- kickApi is only used for the in-zone check now, not to drive anything, so
		-- a missing one costs us an AutoReturn guard rather than the whole loop.
		if not kickApi() then
			say("no KickAuto - kicking anyway, stand in the jump zone")
		end
		banked = 0
		every("kicker", kicker, PRESS_GAP, function(alive)
			local got = kickOnce(alive)
			if got then
				banked += 1
				say(("banked %s (%d this run)"):format(got, banked))
			end
		end)
	end,
})

local caseNames, caseByName = {}, {}
for _, entry in ipairs(caseKeys()) do
	table.insert(caseNames, entry.name)
	caseByName[entry.name] = entry.key
end

Farm:Dropdown({
	Title = "Cases to open",
	Desc = "Worked in the order listed, cheapest first. Ticking only ticks.",
	Values = caseNames,
	Value = {},
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		pickedCases = {}
		for _, name in ipairs(values) do
			table.insert(pickedCases, caseByName[name])
		end
	end,
})

Farm:Toggle({
	Title = "Auto Open",
	Desc = "Opens the ticked cases 3 at a time until you run out",
	Value = false,
	Callback = function(v)
		opener.on = v
		if not v then
			return
		end
		every("opener", opener, OPEN_EVERY, function(alive)
			if #pickedCases == 0 then
				say("no cases ticked")
				return
			end
			for _, key in ipairs(pickedCases) do
				if not alive() then
					break
				end
				if owned(key) > 0 then
					lastError = nil
					local n = openBatch(key)
					say(lastError and ("open refused: " .. lastError) or ("opened %d %s (%d left)"):format(n, key, owned(key)))
					if lastError == "inventoryfull" then
						return -- retrying is pointless until something is sold
					end
				end
			end
		end)
	end,
})

Farm:Toggle({
	Title = "Skip Reveal",
	Desc = "Cut the spin animation entirely and answer the server ourselves. Manual opens too.",
	Value = true,
	Callback = skipReveal,
})

Base:Toggle({
	Title = "Auto Collect",
	Desc = "Base pad plus every plate slot on your plot",
	Value = false,
	Callback = function(v)
		collector.on = v
		if not v then
			return
		end
		every("collector", collector, COLLECT_EVERY, function()
			RequestBasePad:FireServer("Collect")
			local plot = tonumber(player:GetAttribute("BasePlot"))
			if plot then
				for slot = 1, SLOTS do
					RequestCollect:FireServer(plot, slot)
				end
			end
		end)
	end,
})

Base:Toggle({
	Title = "Auto Place",
	Desc = "Fires the plot's own auto-place pad",
	Value = false,
	Callback = function(v)
		placer.on = v
		if not v then
			return
		end
		every("placer", placer, PLACE_EVERY, function()
			RequestBasePad:FireServer("Place")
		end)
	end,
})

Base:Dropdown({
	Title = "Sell rarities",
	Desc = "What Auto Sell destroys. Nothing ticked = nothing sold.",
	Values = rarities(),
	Value = {},
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		pickedRarities = values
	end,
})

Base:Toggle({
	Title = "Auto Sell",
	Desc = "Sells every brainrot of the ticked rarities. This one is destructive.",
	Value = false,
	Callback = function(v)
		seller.on = v
		if not v then
			return
		end
		every("seller", seller, SELL_EVERY, function()
			-- An empty list is "all rarities" to this remote, which would sell the
			-- Secrets you're farming for. Refusing to fire is the guard.
			if #pickedRarities == 0 then
				say("no rarities ticked -- not selling")
				return
			end
			SellShopRequest:InvokeServer({ kind = "brainrotAll", rarities = pickedRarities })
			say(("sold %d rarities"):format(#pickedRarities))
		end)
	end,
})

Extra:Button({ Title = "Claim everything", Callback = claimAll })

Extra:Toggle({
	Title = "Auto Claim",
	Desc = "The same pass on a timer -- daily, offline, gems, free spin, quests",
	Value = false,
	Callback = function(v)
		claimer.on = v
		if v then
			every("claimer", claimer, 60, claimAll)
		end
	end,
})

Extra:Toggle({
	Title = "Auto Rebirth + Speed",
	Desc = "Rebirth and the cheapest speed tile on a timer; refusals are normal",
	Value = false,
	Callback = function(v)
		upkeeper.on = v
		if not v then
			return
		end
		every("upkeeper", upkeeper, UPKEEP_EVERY, function()
			RequestRebirth:FireServer({ mode = "rebirth" })
			RequestSpeedUpgrade:FireServer({ index = 1 })
		end)
	end,
})

-- flight tab -----------------------------------------------------------------
-- Its own tab, under Main, because this half is a different bargain: Main drives
-- the game's own client API and this one answers the server with numbers it didn't
-- send. Keeping them apart means you can't leave one on by accident.
local Flight = Window:Tab({ Title = "Flight", Icon = "solar:rocket-2-bold" })
local Arc = Flight:Section({ Title = "Arc", Icon = "solar:route-bold", Box = true, BoxBorder = true, Opened = true })

Arc:Paragraph({
	Title = "How the landing works",
	Desc = "The server sends the arc, the client flies it and reports where it stopped."
		.. " Boost spends the allowance the server sent. Land reports a spot of our"
		.. " choosing and skips the flight -- that one is a forged report.",
})

Arc:Toggle({
	Title = "Max Boost",
	Desc = "Spend the server's whole boost allowance. Needs the real flight -- inert while Force Landing is on.",
	Value = false,
	Callback = function(v)
		flight.boost = v
	end,
})

local zoneNames = {}
for _, entry in ipairs(ZONE_Z) do
	table.insert(zoneNames, entry[1])
end

Arc:Dropdown({
	Title = "Land in",
	Desc = "Zones run near to far; Zone12 is the end of the runway.",
	Values = zoneNames,
	Value = flight.zone,
	Callback = function(v)
		flight.zone = typeof(v) == "table" and v[1] or v
	end,
})

Arc:Toggle({
	Title = "Force Landing",
	Desc = "Report the picked zone the instant a kick launches -- no flight, ~2s a kick",
	Value = false,
	Callback = function(v)
		flight.force = v
		cutFlight(v)
	end,
})

Arc:Button({
	Title = "Land now",
	Callback = function()
		landAt(flight.last, flight.zone)
	end,
})

local line = Farm:Paragraph({ Title = "Status", Desc = "idle" })
say = function(msg)
	line:SetDesc(msg)
end

skipReveal(true) -- matches the toggle's default Value
if not kickApi() then
	say("no _G.KickAuto yet -- opening and base loops still work")
end

-- close ----------------------------------------------------------------------
local function stopAll()
	for _, state in ipairs(LOOPS) do
		state.on = false
		state.gen += 1 -- retires the running thread even if it's mid-wait
	end
	flight.boost, flight.force = false, false
	skipReveal(false) -- puts the reveal handlers and the Settings toggle back
	cutFlight(false) -- ...and KickController's flight handler
	if flightConn then
		flightConn:Disconnect()
		flightConn = nil
	end
end

Window:OnDestroy(function()
	stopAll()
	getgenv().rollCasesStop = nil
end)

getgenv().rollCasesStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().rollCasesStop = nil
end
