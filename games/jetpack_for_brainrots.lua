--[[ Island Farm -- tick some zones, loop them against the finish line

     ZONE      : multi-select over Workspace > Map > Islands (1-8, Frenzy), listed by
                 number with Frenzy last. Ticking only ticks -- TELEPORT goes to the
                 first one ticked, AUTO FARM visits them all.
     AUTO FARM : toggle. Cycles the ticked zones. At each one it TPs in, waits for
                 Brainrots to stream, and works the list BEST FIRST, carrying up to
                 the carry limit before it banks:

                     brainrot -> StealPrompt -> ... -> full -> bank -> next brainrot

                 PRIORITY_ZONE (Frenzy) goes first every cycle and REPEATS while it
                 keeps yielding, so an active event gets worked to empty before the
                 other zones get a turn. A whole rotation that finds nothing parks for
                 IDLE rather than bouncing between empty zones.

     Targets are whatever is in workspace.Brainrots with a StealPrompt inside and
     within RADIUS of the island pivot. That prompt check is also the zone filter for
     free: the base plots (0,0,0 and -2,0,0) hold brainrots with no StealPrompt, so
     they never make the list.

     A zone can only be read by STANDING IN IT, and there is no way around that. Two
     things hide it, and only one of them is beatable:

       - the client culls its own world. BrainrotsWorkspaceCuller moves brainrots more
         than ~15 zones (1500 studs) away OUT of workspace.Brainrots and into
         ReplicatedStorage.BrainrotsHidden, same folder names and pivots. Beatable:
         both roots get scanned, and the culler re-parents within half a second of
         arriving (PlayerZoneTracker polls position at 0.5s).
       - Roblox streaming withholds the Models themselves. The "<x>,<y>,<z>" folders
         always replicate -- no BaseParts in them -- so a zone you have never visited
         is an EMPTY folder, not a missing one, and reads exactly like a zone you
         picked clean. NOT beatable from here: it's the server's copy that's missing.

     That second one is why "score the zone before flying there" cannot work, however
     much it looks like it should.

     Ordering, both read off the billboard because that is the ONLY place this game puts
     either -- no attributes, no value objects. Income comes from the "$2.98B/s" label,
     rarity from its own label matched against the BrainrotsInfo ladder:

         PRIORITY_ZONE : rarity, then income, then distance
         everywhere else : income, then rarity, then distance

     Anything whose billboard hasn't streamed scores 0 on both and goes last.

     BANK      : land ON Workspace.Map.Walls.TouchStart. Banking is one client-side
                 Touched connection (Source.GameModules.TouchEvents) that clears
                 isInGame and calls GameHandler.ClaimRewards -> Knit Game.RF
                 ClaimRewards, so a touch is the entire mechanism. A PivotTo THROUGH
                 a part never touches it, but a PivotTo ONTO one overlaps it, which
                 is a real touch; firetouchinterest is the backstop for the frame
                 physics misses. There is no walk and no lava: the strip this used to
                 land on was at y=55, and TouchStart is at y=90.8 -- 35 studs up,
                 which is why crossing never banked. Banking fills your BACKPACK;
                 putting brainrots into base slots is a separate job from the
                 inventory, and not what this loop is for.
     BASE      : plain TP, kept for getting out of trouble by hand. Not in the loop.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill and back; RightAlt hides it outright.
     Stop: getgenv().islandTpStop() ]]

-- config ---------------------------------------------------------------------
local BASE = CFrame.new(26.7890625, 58.0223694, 74.3964844, -1, 0, 0, 0, 1, 0, 0, 0, -1)

-- ponytail: the waits are latency and streaming, which no amount of code can work out
-- from here. Everything else below is read off the game, not guessed.
local TP_OFFSET = Vector3.new(0, 10, 0) -- above an island pivot (model center, not surface)
local GRAB_OFFSET = Vector3.new(0, 3, 0) -- above a brainrot pivot; StealPrompt reaches 10 studs
local RADIUS = 500 -- how far from the island pivot still counts as "this zone"
local PICK_RADIUS = 25 -- re-finding the brainrot after landing on its old spot
local STREAM_POLL = 0.25 -- how often to re-scan a zone that hasn't shown anything yet
local ZONE_DWELL = 4 -- seconds of polling before an island counts as genuinely empty
local APPROACH_WAIT = 0.35 -- after landing on a brainrot, before the prompt is live
local GRAB_WAIT = 1 -- how long to wait for the carry model to appear before calling it a miss
local BANK_TRIES = 3 -- touches of TouchStart before giving up on this carry
local BANK_WAIT = 0.35 -- after a touch, before isCarryingRewards clears (handler debounces at 0.1)
local STREAM_TIMEOUT = 3 -- max seconds to wait for a region to stream before jumping in anyway
local IDLE = 5 -- seconds parked after a full cycle that found nothing in any zone
local PRIORITY_ZONE = "Frenzy" -- worked first and repeated while it pays; "" for a flat rotation
local KEY_TOGGLE = Enum.KeyCode.RightControl

-- Verbatim from ReplicatedStorage.Source.Info.BrainrotsInfo.byRarity, in its DECLARED
-- order -- ascending tier, which an alphabetical sort would scramble. Note this game
-- puts divine above celestial, the opposite of the ladder in fall_for_brainrots.
--
-- Only the order is needed, never the name lists: each brainrot's billboard prints its
-- own rarity as a label, so a hundred-name lookup table would be a second copy of a
-- fact already on screen.
local RARITY_ORDER = {
	"common",
	"uncommon",
	"rare",
	"epic",
	"legendary",
	"mythical",
	"cosmic",
	"secret",
	"celestial",
	"divine",
}

-- Cash suffixes, as the billboards spell them. Keys are lowercased at lookup, so Qa and
-- Qi can't collide with a plain Q -- the match is exact, not first-letter.
local SUFFIX = {
	k = 1e3,
	m = 1e6,
	b = 1e9,
	t = 1e12,
	qa = 1e15,
	qi = 1e18,
	sx = 1e21,
	sp = 1e24,
	oc = 1e27,
	no = 1e30,
	dc = 1e33,
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- BrainrotsHidden lives here
local RunService = game:GetService("RunService") -- only the status drain uses this
local player = Players.LocalPlayer

if getgenv and getgenv().islandTpStop then
	getgenv().islandTpStop()
end

-- world ----------------------------------------------------------------------
-- The numbered folders each hold a Model that carries the pivot, but a folder being
-- the model itself is one line to cover, so cover it.
local function pivotOf(inst)
	if inst:IsA("Model") or inst:IsA("BasePart") then
		return inst:GetPivot()
	end
	local child = inst:FindFirstChildWhichIsA("Model") or inst:FindFirstChildWhichIsA("BasePart")
	return child and child:GetPivot()
end

local function scanIslands()
	local out = {}
	local map = workspace:FindFirstChild("Map")
	local islands = map and map:FindFirstChild("Islands")
	if not islands then
		return out
	end
	for i, child in ipairs(islands:GetChildren()) do
		local cf = pivotOf(child)
		if cf then
			table.insert(out, { name = child.Name, cf = cf, order = i })
		end
	end
	-- Islands 7 and 8 each appear twice, so the name alone can't identify a row --
	-- sort numerically, keep explorer order as the tiebreak. Frenzy sorts last, being
	-- unnumbered, which is also where it sits on the map.
	table.sort(out, function(a, b)
		local na, nb = tonumber(a.name), tonumber(b.name)
		if na and nb and na ~= nb then
			return na < nb
		end
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.order < b.order
	end)
	-- Labelled for the LIST, not for the folder. The folder names are bare numbers that
	-- repeat, so "8. 7" was the row index and the folder name disagreeing in public --
	-- and a repeated name can't key a tick either. Numbered by position instead, which
	-- is the order you'd work them in anyway; unnumbered folders keep their own name.
	-- The seen check is cheap insurance: two rows sharing a label would share a tick.
	local seen, n = {}, 0
	for _, entry in ipairs(out) do
		if tonumber(entry.name) then
			n += 1
			entry.label = "Island " .. n
		else
			entry.label = entry.name
		end
		local base, k = entry.label, 1
		while seen[entry.label] do
			k += 1
			entry.label = ("%s (%d)"):format(base, k)
		end
		seen[entry.label] = true
	end
	return out
end

-- The income is only ever billboard TEXT -- these models carry no attributes and no
-- value objects at all. It reads "$2.98B/s", or "$8/s" with no suffix, and is usually
-- wrapped in rich-text font tags, so we match the number and its suffix wherever they
-- sit in the string. Anchoring on "/s" keeps it off the level and price labels.
local function parseCash(text)
	local num, suffix = text:match("%$([%d%.,]+)(%a*)/s")
	if not num then
		return nil
	end
	local n = tonumber((num:gsub(",", "")))
	return n and n * (SUFFIX[suffix:lower()] or 1) or nil
end

assert(parseCash("$2.98B/s") == 2.98e9)
assert(parseCash("$8/s") == 8)
assert(parseCash("Lv.22") == nil)

local RARITY_RANK = {}
for i, name in ipairs(RARITY_ORDER) do
	RARITY_RANK[name] = i
end

-- One walk for both facts, since they come off the same set of labels. Rich-text tags
-- are stripped first: the income label is wrapped in them, and the rarity label has to
-- match the ladder exactly -- exactly is what keeps "Secret Lucky Block" from counting
-- as Secret, while the plain "Secret" label on the same billboard still does.
--
-- Zeroes mean the billboard hasn't streamed yet, which sorts last rather than wrong.
local function infoOf(model)
	local value, rarity = 0, 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("TextLabel") then
			local clean = d.Text:gsub("<[^>]*>", ""):match("^%s*(.-)%s*$")
			if value == 0 then
				value = parseCash(clean) or 0
			end
			if rarity == 0 then
				rarity = RARITY_RANK[clean:lower()] or 0
			end
		end
	end
	return value, rarity
end

-- Brainrots is a chunk grid: folders named "<x>,<y>,<z>" on a 100-stud step, only a
-- few of which hold anything. Rather than decode the names we just measure distance
-- from the island pivot, which is the same answer without a grid constant to get wrong.
--
-- BOTH roots, because the client culls its own world: BrainrotsWorkspaceCuller keeps
-- the far chunks in ReplicatedStorage.BrainrotsHidden with pivots and billboards
-- intact. Scanning those is how a zone gets scored without going there. The prompt on
-- a hidden model can't be fired, which is fine -- runZone re-scans after it lands, and
-- by then the culler has moved the chunk back into workspace.
local function scanBrainrots(pos, radius, rarityFirst)
	local out = {}
	-- Two ifs, not a two-element literal: a nil in the middle of a table constructor
	-- makes ipairs stop early and silently drops the other root.
	local roots = {}
	local live = workspace:FindFirstChild("Brainrots")
	local hidden = ReplicatedStorage:FindFirstChild("BrainrotsHidden")
	if live then
		table.insert(roots, live)
	end
	if hidden then
		table.insert(roots, hidden)
	end
	for _, root in ipairs(roots) do
		for _, folder in ipairs(root:GetChildren()) do
			for _, model in ipairs(folder:GetChildren()) do
				local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
				local ok, cf = pcall(model.GetPivot, model)
				if prompt and ok then
					local dist = (cf.Position - pos).Magnitude
					if dist <= radius then
						local value, rarity = infoOf(model)
						table.insert(out, {
							model = model,
							prompt = prompt,
							cf = cf,
							dist = dist,
							value = value,
							rarity = rarity,
						})
					end
				end
			end
		end
	end
	-- Best first, nearest to break ties. rarityFirst swaps the top two keys: rarity and
	-- income mostly agree, but level and mutations move income within a tier, so a
	-- levelled Cosmic can out-earn a fresh Divine. Both keys stay in play either way.
	table.sort(out, function(a, b)
		if rarityFirst and a.rarity ~= b.rarity then
			return a.rarity > b.rarity
		end
		if a.value ~= b.value then
			return a.value > b.value
		end
		if a.rarity ~= b.rarity then
			return a.rarity > b.rarity
		end
		return a.dist < b.dist
	end)
	return out
end

local function hrp()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- No offset means "use this CFrame exactly". With an offset we take position only,
-- because an island's own rotation would tilt the character with it.
--
-- "Gameplay Paused" is the streaming pause: you landed somewhere the client hasn't
-- received yet. StreamingEnabled belongs to the server and can't be switched off from
-- here, but requesting the region first leaves nothing to pause for. It yields, so the
-- character is re-read afterwards -- you may have respawned during the wait.
local function tp(cf, offset)
	local target = offset and CFrame.new(cf.Position + offset) or cf
	pcall(function()
		player:RequestStreamAroundAsync(target.Position, STREAM_TIMEOUT)
	end)
	local char = player.Character
	if not char or not hrp() then
		return false
	end
	char:PivotTo(target)
	-- Then wait out the streaming pause. The islands are up to 10,000 studs apart, so
	-- RequestStreamAroundAsync timing out is normal on the long jumps, and landing
	-- inside an unreceived region freezes the character mid-air with GameplayPaused
	-- set -- a farm that fires prompts through that pause does nothing at all. Capped,
	-- because a pause that never lifts should cost one zone, not the whole run.
	local t0 = os.clock()
	while player.GameplayPaused and os.clock() - t0 < STREAM_TIMEOUT do
		task.wait(0.1)
	end
	return true
end

local function fire(prompt)
	prompt.RequiresLineOfSight = false -- client-side only, but the client is what gates the prompt
	if fireproximityprompt then
		fireproximityprompt(prompt, 1)
	else
		-- ponytail: no executor globals -- the honest hold, which needs you in range.
		prompt:InputHoldBegin()
		task.wait(prompt.HoldDuration + 0.1)
		prompt:InputHoldEnd()
	end
end

-- A picked-up brainrot is parented into your CHARACTER as a Model -- that's what
-- PlayerManagers.PlayerCarriedRewardsAnimator watches Character.ChildAdded for.
--
-- The DELTA is the confirm, never the total: the equipped jetpack is a Model under the
-- character too ("Jetpack8"), so the baseline isn't zero, and comparing before/after
-- means never having to know which of the character's Models are its own.
local function models()
	local char, n = player.Character, 0
	for _, m in ipairs(char and char:GetChildren() or {}) do
		if m:IsA("Model") then
			n += 1
		end
	end
	return n
end

-- Returns whether the server actually handed one over. A fire that changes nothing
-- while you're already carrying means the carry is full (GameConfigs.CARRY_LIMIT caps
-- at 6, less until you've bought the upgrades) -- there is no "you're full" signal
-- anywhere else, so the miss IS the signal.
local function grab(prompt)
	local before = models()
	fire(prompt)
	local t0 = os.clock()
	repeat
		task.wait(0.05)
		if models() > before then
			return true
		end
	until os.clock() - t0 > GRAB_WAIT
	return false
end

-- The whole banking mechanism is one client-side Touched on Workspace.Map.Walls
-- TouchStart (Source.GameModules.TouchEvents): it clears isInGame and calls
-- GameHandler.ClaimRewards. So all that has to happen is a touch of that part.
--
-- Landing ON it is a genuine one -- a PivotTo THROUGH a part never overlaps it, but a
-- PivotTo onto it does, and overlap is what Touched is. firetouchinterest is the
-- backstop for the frame physics doesn't notice, and costs nothing when it isn't there.
-- Confirmed by isCarryingRewards, the server attribute the HUD's own Drop button reads,
-- rather than by a wait: "the deposit silently didn't take" is the failure this hides.
local function bank()
	if not player:GetAttribute("isCarryingRewards") then
		return true -- nothing to bank
	end
	local map = workspace:FindFirstChild("Map")
	local walls = map and map:FindFirstChild("Walls")
	local part = walls and walls:WaitForChild("TouchStart", 3) -- always a timeout
	if not part then
		return false -- unstreamed; the caller keeps the carry and comes back
	end
	for _ = 1, BANK_TRIES do
		if not tp(part.CFrame) then
			return false
		end
		local char = player.Character
		local head = char and char:FindFirstChild("Head")
		if firetouchinterest and head then
			pcall(function()
				firetouchinterest(head, part, true)
				task.wait()
				firetouchinterest(head, part, false)
			end)
		end
		task.wait(BANK_WAIT)
		if not player:GetAttribute("isCarryingRewards") then
			return true
		end
	end
	return false
end

-- zones ----------------------------------------------------------------------
-- Keyed by entry.label, not by the entry itself: WindUI hands the callback back the
-- {Title=, Desc=} row it was given, which is a fresh table on every redraw, so the
-- label assigned in scanIslands is the one thing both sides can agree on.
local zoneItems, chosen = {}, {}

-- Ticked zones in list order. Read fresh per cycle, so a zone that stops existing drops
-- out on its own instead of erroring mid-farm.
local function orderedZones()
	local out = {}
	for _, entry in ipairs(zoneItems) do
		if chosen[entry.label] then
			table.insert(out, entry)
		end
	end
	return out
end

-- farm -----------------------------------------------------------------------
local farming, stolen = false, 0

-- The farm loop never writes to the panel, it leaves a line here. Executors hand a
-- RESUMED thread back with reduced capability, so the first status write in a loop
-- lands and every one after a task.wait throws "cannot access 'Instance' (lacking
-- capability Plugin)" -- the panel lives in the hidden GUI, which is the part that
-- needs the capability. Uncaught, that kills the farm thread on its second lap.
-- The panel drains this from a Heartbeat, which the engine calls with our own identity.
local pending = nil
local function say(msg)
	pending = msg
end

-- Returns how many it took, so the cycle can tell an empty rotation from a working one.
local function runZone(island, rarityFirst)
	-- Go, THEN look. Scoring a zone from base doesn't work and can't be made to:
	-- BrainrotsHidden is not a map of the world, it is a cache of what this client has
	-- already been sent. Roblox replicates the "<x>,<y>,<z>" folders (no BaseParts, so
	-- streaming never withholds them) but withholds the Models inside until you are in
	-- range, so a zone you haven't visited reads as an EMPTY zone rather than an
	-- unknown one, and the two are indistinguishable from here. Reading it as empty is
	-- what made every far island answer "nothing in any zone" without moving.
	say(island.name .. ": arriving")
	tp(island.cf, TP_OFFSET)
	-- Polled, not scanned once. A zone up to 10,000 studs from the last one takes a
	-- moment to arrive, and a single scan on landing calls a busy island empty and
	-- leaves. Bails the instant something shows up, so a loaded zone costs one beat.
	local targets, t0 = {}, os.clock()
	repeat
		task.wait(STREAM_POLL)
		targets = scanBrainrots(island.cf.Position, RADIUS, rarityFirst)
	until #targets > 0 or os.clock() - t0 > ZONE_DWELL
	if #targets == 0 then
		-- Also the whole of the Frenzy handling: the event only fills the zone while
		-- it's up, and an empty zone is an empty zone. Standing there IS the check,
		-- and an inactive one costs one teleport.
		say(island.name .. ": empty -- next zone")
		return 0
	end

	-- Positions are a snapshot: the models move in and out of workspace while we're
	-- away banking, so each trip returns to the remembered spot and re-finds whatever
	-- is standing there now. Anything already taken is simply gone, and gets skipped.
	--
	-- Indexed by hand rather than ipairs because a full carry has to retry the SAME
	-- target after banking, and a miss with nothing in hand has to move past it.
	local got, i = 0, 1
	while farming and i <= #targets do
		local t = targets[i]
		say(
			string.format(
				"%s: %d/%d %s [%s $%.3g/s]",
				island.name,
				i,
				#targets,
				t.model.Name,
				RARITY_ORDER[t.rarity] or "?",
				t.value
			)
		)
		tp(t.cf, GRAB_OFFSET)
		task.wait(APPROACH_WAIT)
		local here = scanBrainrots(t.cf.Position, PICK_RADIUS)[1]
		if not here then
			i += 1 -- taken, or never streamed in
		elseif grab(here.prompt) then
			got, stolen, i = got + 1, stolen + 1, i + 1
		elseif player:GetAttribute("isCarryingRewards") then
			-- Full: bank and come straight back to this one. If banking itself fails
			-- there is nowhere to put the next brainrot either, so stop rather than
			-- spin -- and say so, because it's the one failure worth looking at.
			say(island.name .. ": full -- banking")
			if not bank() then
				say("couldn't bank -- carry stuck, see console (F9)")
				warn("[IslandFarm] bank failed; still carrying")
				break
			end
		else
			i += 1 -- prompt fired, server said no, and we aren't carrying: not a full carry
		end
	end

	-- The trip back is per ZONE now, not per brainrot: the carry holds up to
	-- CARRY_LIMIT, so banking after every single grab was five wasted round trips
	-- out of six.
	if farming then
		bank()
	end
	return got
end

local function runCycle(zones)
	local any = false

	-- Whether Frenzy is active can't be seen from anywhere else -- see runZone: the
	-- client is only sent the brainrots it's near, so the only way to know is to stand
	-- there. So we don't detect the event at all -- we go there FIRST and stay while it
	-- keeps paying. An inactive Frenzy costs one wasted TP; an active one gets worked
	-- to empty before any other zone gets a turn, and the cycle comes straight back.
	local priority, rest = nil, {}
	for _, island in ipairs(zones) do
		if not priority and PRIORITY_ZONE ~= "" and island.name:lower() == PRIORITY_ZONE:lower() then
			priority = island
		else
			table.insert(rest, island)
		end
	end

	while farming and priority do
		local got = runZone(priority, true) -- rarity first while the event is up
		any = got > 0 or any
		if got == 0 then
			break -- not active (or picked clean); let the other zones have their turn
		end
	end

	for _, island in ipairs(rest) do
		if not farming then
			break
		end
		any = runZone(island) > 0 or any
	end
	-- A whole rotation with nothing to show for it: park rather than keep bouncing
	-- between empty zones. Raise IDLE for fewer round trips while waiting on Frenzy.
	if farming and not any then
		say("nothing in any zone -- idling (" .. stolen .. " taken)")
		task.wait(IDLE)
	end
end

local farmGen = 0
local farmToggle -- assigned by the panel; the off path has to move the switch too
local setFarming -- forward: the thread's own exit calls back into it

local function startFarm()
	farmGen += 1
	local mine = farmGen -- off-then-on shouldn't leave two loops driving one character
	task.spawn(function()
		while farming and farmGen == mine do
			-- Re-read the ticks every cycle, so untick and retick land without a restart.
			local zones = orderedZones()
			if #zones == 0 then
				say("tick at least one zone")
				break
			end
			-- A crash in here used to kill the thread silently, leaving FARM stuck ON
			-- with nothing happening. Name it and switch off cleanly instead.
			local ok, err = pcall(runCycle, zones)
			if not ok then
				warn("[IslandFarm]", err)
				say("crashed -- see console (F9)")
				break
			end
		end
		if farmGen == mine then
			setFarming(false)
		end
	end)
end

setFarming = function(state)
	if farming == state then
		return
	end
	farming = state
	if farmToggle then
		-- Same capability trap as the status line: this runs on the farm thread when the
		-- loop exits on its own. The flag above is what actually stops it, so a switch
		-- that won't move is cosmetic, not fatal.
		pcall(function()
			farmToggle:Set(state) -- re-enters here, which the equality guard absorbs
		end)
	end
	if state then
		startFarm()
	else
		say("stopped -- " .. stolen .. " taken")
	end
end

-- gui ------------------------------------------------------------------------
-- ponytail: the hand-rolled widget kit is gone. WindUI already ships rows, toggles,
-- multi-select dropdowns, drag, resize and the topbar buttons, so there is nothing here
-- worth owning. Fetched at runtime; nothing to vendor.
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a
-- restyle is one file and not sixteen. Fetched here rather than installed by the loader,
-- so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Island Farm", -- fallback until the live name lands
	folder = "IslandFarm", -- unchanged: renaming it orphans configs already saved in-game
	size = UDim2.fromOffset(440, 360),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local Farm = Tab:Section({ Title = "Farm", Icon = "solar:magic-stick-3-bold", Box = true, BoxBorder = true, Opened = true })

farmToggle = Farm:Toggle({
	Title = "Auto farm",
	Desc = "Cycle the ticked zones, best first, banking each time the carry fills up",
	Value = false,
	Callback = setFarming, -- :Set() re-fires this, so setFarming has to be re-entrant
})

local zoneDrop = Farm:Dropdown({
	Title = "Zones",
	Desc = "Ticking only ticks -- TELEPORT goes to the first, AUTO FARM visits them all",
	Values = {},
	Value = {},
	Multi = true,
	AllowNone = true,
	-- WindUI hands back the whole {Title=, Desc=} row it was given, not the label
	-- string -- ticking a zone used to write nothing into `chosen`, which is why the
	-- list looked ticked and AUTO FARM answered "tick at least one zone". Both shapes
	-- are handled because a plain-string Values list is one edit away.
	Callback = function(picked)
		chosen = {}
		for _, v in ipairs(picked) do
			chosen[typeof(v) == "table" and v.Title or v] = true
		end
		say(#orderedZones() .. " zones ticked")
	end,
})

local line = Farm:Paragraph({ Title = "Status", Desc = "idle" })

-- Drains whatever the farm thread last left. pcall'd anyway: if even this can't write
-- the panel, the run carries on with the status going to the console instead of taking
-- the loop down with it.
RunService.Heartbeat:Connect(function()
	if pending == nil then
		return
	end
	local msg = pending
	pending = nil
	if not pcall(function()
		line:SetDesc(msg)
	end) then
		print("[IslandFarm]", msg)
	end
end)

-- wiring ---------------------------------------------------------------------
-- Rebuilding drops the ticks, because the entries they point at are new objects. That's
-- the honest outcome: the list you re-read is not the list you ticked.
local function refresh()
	zoneItems, chosen = scanIslands(), {}
	local values = {}
	for _, entry in ipairs(zoneItems) do
		-- Distance out, because the map is a corridor along -Z and how far out an
		-- island is IS what you're choosing between. The folder name comes along so a
		-- renumbered row is still traceable back to Islands.<name> in the explorer.
		table.insert(values, {
			Title = entry.label,
			Desc = ("%.0f studs out -- Islands.%s"):format(math.abs(entry.cf.Z), entry.name),
		})
	end
	zoneDrop:Refresh(values)
	say(#zoneItems .. " islands found -- tick the ones to farm")
end

local Manual = Tab:Section({ Title = "Manual", Icon = "solar:cursor-bold", Box = true, BoxBorder = true, Opened = true })

Manual:Button({
	Title = "Teleport to first ticked zone",
	Callback = function()
		local first = orderedZones()[1] -- first ticked; FARM is what visits the rest
		if not first then
			say("tick a zone first")
			return
		end
		task.spawn(function()
			say(tp(first.cf, TP_OFFSET) and ("at " .. first.name) or "no character")
		end)
	end,
})

Manual:Button({
	Title = "Bank carry",
	Desc = "Touch the finish line to hand whatever you're carrying to your backpack",
	Callback = function()
		task.spawn(function()
			say(bank() and "banked" or "couldn't bank -- line not loaded?")
		end)
	end,
})

Manual:Button({
	Title = "TP to base",
	Callback = function()
		task.spawn(function()
			say(tp(BASE) and "at base" or "no character")
		end)
	end,
})

Manual:Button({
	Title = "Rescan islands",
	Desc = "Rebuilds the zone list. Clears your ticks.",
	Callback = refresh,
})

refresh()

-- close ----------------------------------------------------------------------
-- The loop exits on its own flag, so this really does stop it.
-- ponytail: rerun the script to come back.
local function stop()
	farming = false
	getgenv().islandTpStop = nil
	pcall(function()
		Window:Destroy()
	end)
end

Window:OnDestroy(stop)
getgenv().islandTpStop = stop
