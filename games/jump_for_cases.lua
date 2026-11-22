--[[ Jump for Cases -- kicks for cases, carries them home past the wave, opens them, lifts between (93545804988403)

     FARM      : one kick per lap, all of it the game's own controller driven by us:
                     server jump-zone TP -> KickAuto.press() -> KickAuto.lock() at the
                     bar's peak (Perfect) -> 50 BoostKick clicks in the air -> the case
                     drops -> skip its cutscene -> glide home holding it -> safeClaim.
                 The case pool is the server's: it computes the landing from your
                 KickPower and the boosts, and a spoofed `landed` position is ignored. So
                 distance (= rarer cases) is Strength, which is LIFT and better weights.
                 The wave that chases you home is CLIENT-reported (`waveHit`), and the
                 client skips the report while you stand in workspace.Zones.CollectZone,
                 so that part is pinned onto you, locally, for the whole carry. The claim
                 itself is the server's: it checks your real position (refused from the
                 landing, accepted around Z 360 on the way back).
                 The carry home is a glide at CARRY_FACTOR x your WalkSpeed. Holding a case
                 the server speed-checks you and kills you when you outrun it: 75 studs/s
                 at WalkSpeed 51 held, 150 and 105 were pulled back and died. A pull-back
                 lowers the factor for the rest of the session.
                 The check scales with WalkSpeed: after speed upgrades 172 studs/s held.
     LIFT      : holds the barbell (hotbar 1) for LIFT seconds between kicks, or in 30s
                 chunks when FARM is off. Strength ticks server-side while it is held.
                 RequestSelectHotbar TOGGLES (re-sending 1 puts the barbell away), and the
                 server refuses it during a kick session and while a spin UI is open
                 (_SpinUIOpen, a case reveal or the wheel).
     TRAIN     : answers the rhythm circles the server spawns while you lift (OsuTrain
                 spawn -> hit at the ring's close). The combo speeds the lift ticks up:
                 149 Strength/s at combo 30 against 71 plain. Faked ids do nothing.
     OPEN      : opens the ticked case kinds between kicks, RequestOpenCase -> CaseOpened ->
                 RequestRevealComplete after REVEAL_AFTER (the spin is 8s; the early
                 complete is accepted).
     COLLECT   : the game's own server-side Auto Collect (you own it). Put back at unload.
     REBIRTH   : RequestRebirth between kicks once KickPower meets the rebirth panel's
                 "x/y Jump Power". The game's own Auto Rebirth setting is kept off while
                 this runs: it fires mid-flight, teleports you to base and wastes the lap.
     WEIGHTS   : buys the most expensive cash barbell you can afford above the one you hold;
                 the shop is not sequential (Copper bought straight from Basic).
     SPEED     : RequestSpeedUpgrade +26 units when it costs under SPEED_SHARE of your cash.
                 More WalkSpeed is a faster carry home.
     LEVEL     : RequestSlotLevel on the placed pet whose next level is cheapest, one level
                 at a time, priced from its Slots["Slot N"] sign ("$263B | Lvl 21 > Lvl 22").
                 The game's MAX button (RequestSlotLevelMax) took slot 1 from 21 to 27 and
                 doubled income, but spends everything on one pet. The $100M base sign
                 (RequestBaseUpgrade, a cash multiplier) showed nothing in one probe: unwired.
     PLACE BEST / FREEBIES : the game's Place Best button; daily, free wheel, offline,
                 index gems, perm quest, on a slow beat.

     Probed and dead: collect spam (pays only what accrued), landing spoof, the server
     jump-zone TP while holding a case (ignored), faked OsuTrain ids, glide >= 105 studs/s
     while carrying. Paid, never wired: respawn-keep-case (ad / Robux), Robux barbells,
     the 600x / skip-rebirth products.

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().jumpCasesStop() ]]

-- config ---------------------------------------------------------------------
local CARRY_FACTOR = 1.45 -- carry glide = this x WalkSpeed. 1.47 held, 2.9 was pulled back and killed. Lower if carries die
local CARRY_FLOOR = 1.0 -- pull-backs never take the factor below this
local CARRY_BACKOFF = 0.85 -- factor x this per pull-back
local TRAVEL_SPEED = 300 -- empty-handed glide back to the hub; 3000 held in the movement ladder, no carry check without a case
local SLACK = 6 -- studs off the last written position, 3 frames running, = pulled back
local HOME = Vector3.new(207.25, 26, 100) -- the jump zone pad, behind the client's safezone (Z 122.75)
local BOOSTS = 50 -- the server's boostMaxClicks
local BOOST_GAP = 0.1 -- the server's boostMinInterval is 0.09
local PEAK_WINDOW = 0.03 -- seconds either side of the bar's peak; Perfect is the top 8%
local ZONE_WAIT = 5 -- the jump-zone TP must put you in the kick zone inside this
local TAKEOFF_WAIT = 14 -- press -> flight; the windup animation is ~4-6s
local LAND_WAIT = 120 -- flight -> case `begin`, cap. A strong kick laps the track: 40s was too short at 182M Strength
local HANDOFF_WAIT = 15 -- `begin` -> the case in your hands (0.05s once the cutscene is skipped)
local CLAIM_WAIT = 8 -- home -> the case counted
local LIFT_SECS = 20 -- default lift between kicks
local REVEAL_AFTER = 1.0 -- open -> RequestRevealComplete
local OPEN_WAIT = 3 -- the CaseOpened reply must land inside this
local ECON_EVERY = 5 -- weights / speed / place best beat
local LEVEL_BURST = 20 -- pet levels bought per beat at most, cheapest slot each time
local LEVEL_GAP = 0.25 -- between RequestSlotLevel calls; the slot sign reprices inside this
local FREEBIE_EVERY = 120
local PLACE_EVERY = 30
local SPEED_SHARE = 0.1 -- a speed upgrade may cost at most this share of your cash, so the next barbell is not starved
local SPEED_TILE = 7 -- SpeedUpgradesConfig.Tiles[7] = Run26, the cash tile (+26 units)
local STUCK_AFTER = 90 -- the watchdog says so when the worker sits on one step this long

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().jumpCasesStop then
	getgenv().jumpCasesStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[jumpcases]", ...)
end
local said = {}
local function first(key, ...) -- one line per unproven branch the first time it runs
	if not said[key] then
		said[key] = true
		log(key, ...)
	end
end

-- The strip is drained from a Heartbeat: a loop thread writing to the window throws
-- "lacking capability Plugin" after its first task.wait.
local pending, lastSaid = nil, nil
local function say(msg)
	pending = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

local SUFFIX = { "K", "M", "B", "T", "Qd", "Qn", "Sx", "Sp", "Oc", "No", "De" }
local function fmt(n)
	n = tonumber(n) or 0
	if math.abs(n) < 1000 then
		return tostring(math.floor(n))
	end
	local i = math.min(math.floor(math.log10(math.abs(n)) / 3), #SUFFIX)
	return ("%.1f%s"):format(n / 10 ^ (i * 3), SUFFIX[i])
end
assert(fmt(999) == "999" and fmt(1500) == "1.5K" and fmt(2.5e9) == "2.5B")

local MONEY_SUFFIX = { K = 1e3, M = 1e6, B = 1e9, T = 1e12, Qd = 1e15, Qn = 1e18, Sx = 1e21, Sp = 1e24, Oc = 1e27, No = 1e30, De = 1e33 }
local function money(text) -- "$263B" / "5K" -> number, anything else -> nil
	local num, suf = tostring(text):gsub("[%$,%s]", ""):match("^(%d*%.?%d+)(%a*)$")
	if not num then
		return nil
	end
	if suf == "" then
		return tonumber(num)
	end
	return MONEY_SUFFIX[suf] and tonumber(num) * MONEY_SUFFIX[suf] or nil
end
assert(money("$263B") == 263e9 and money("$2.9T") == 2.9e12 and money("5K") == 5000 and money("Lvl 2") == nil)

-- world ----------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
local R = {}
for _, n in ipairs({
	"RequestTopHubTeleport", "BoostKick", "FallRewardEvent", "RespawnPrompt", "RequestSelectHotbar",
	"OsuTrain", "RequestOpenCase", "CaseOpened", "RequestRevealComplete", "RequestSetSetting",
	"RequestBuyWeight", "RequestEquipWeight", "RequestSpeedUpgrade", "RequestSlotLevel", "RequestRebirth", "BasePetsRequest", "RequestDailyClaim", "RequestSpinWheel",
	"RequestClaimOffline", "RequestClaimAllIndexGems", "RequestClaimPermQuest", "SpinUIState",
}) do
	R[n] = Remotes:FindFirstChild(n)
	if not R[n] then
		log("WARN remote missing:", n)
	end
end
local OsuCfg = require(ReplicatedStorage:WaitForChild("OsuTrainConfig"))
local WeightsConfig = require(ReplicatedStorage:WaitForChild("WeightsConfig"))
local SpeedCfg = require(ReplicatedStorage:WaitForChild("SpeedUpgradesConfig"))

local function A(k)
	return player:GetAttribute(k)
end
local function fire(name, ...)
	local r = R[name]
	if r then
		return pcall(r.FireServer, r, ...)
	end
	return false
end
-- InvokeServer has no timeout: fire it on its own thread and give up on a clock
local function invokeTimed(name, secs, ...)
	local r, done, res = R[name], false, nil
	if not r then
		return nil
	end
	local args = table.pack(...)
	task.spawn(function()
		local ok, v = pcall(r.InvokeServer, r, table.unpack(args, 1, args.n))
		res, done = ok and v or nil, true
	end)
	local t = os.clock()
	while not done and os.clock() - t < secs do
		task.wait(0.1)
	end
	return res
end

local function kickAuto()
	local env = getrenv and getrenv()
	return env and env._G and env._G.KickAuto -- the game's own auto-kick handle (a LocalScript's _G)
end
local function root()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart"), c and c:FindFirstChildOfClass("Humanoid")
end
local function holding()
	return (A("_HoldingCase") or "") ~= ""
end

-- Every Cases_<Kind> attribute is a case count. A mutated drop gets its own key, made at runtime
-- (Cases_BlackHole_MUT_Lava) and opened by that key, so counts are read live, never from a list.
local function baseKind(key)
	return key:match("^(.-)_MUT_") or key
end
assert(baseKind("BlackHole_MUT_Lava") == "BlackHole" and baseKind("Void") == "Void")
local CASE_KEYS = {} -- base kinds, for the dropdown
for k in pairs(player:GetAttributes()) do
	if k:sub(1, 6) == "Cases_" and not k:find("_MUT_") then
		CASE_KEYS[#CASE_KEYS + 1] = k:sub(7)
	end
end
table.sort(CASE_KEYS)
local function heldCases() -- key -> count, every case kind you hold right now
	local out = {}
	for k, v in pairs(player:GetAttributes()) do
		if k:sub(1, 6) == "Cases_" and (tonumber(v) or 0) > 0 then
			out[k:sub(7)] = tonumber(v)
		end
	end
	return out
end
local function caseTotal()
	local n = 0
	for _, v in pairs(heldCases()) do
		n += v
	end
	return n
end

-- state ----------------------------------------------------------------------
local on = { farm = false, lift = false, train = false, open = false, rebirth = false, weights = false, speed = false, level = false, place = false, free = false }
local liftSecs = LIFT_SECS
local caseOn = {} -- kind -> true
local stats = { cases = 0, lost = 0, kicks = 0, opened = 0, bought = 0, speed = 0, levels = 0, last = "-" }
local carryFactor = CARRY_FACTOR
local crumb, crumbAt = "idle", os.clock()
local function step(s)
	crumb, crumbAt = s, os.clock()
end

local function declineOffer()
	if A("_RespawnOffer") then
		fire("RespawnPrompt", { kind = "decline" }) -- the free answer; keeping the case is an ad / Robux
		local t = os.clock()
		while A("_RespawnOffer") and os.clock() - t < 3 do
			task.wait(0.1)
		end
	end
end

-- glide ----------------------------------------------------------------------
-- Per-Heartbeat lerp with velocity zeroed. 3 frames more than SLACK studs off the position we
-- wrote last = the server pulled us back: slow down and keep going from where it put us.
local function glideTo(target, speed, alive, onPull)
	local hrp = root()
	if not hrp then
		return false, "no character"
	end
	local pos, bad = hrp.Position, 0
	local deadline = os.clock() + (target - pos).Magnitude / math.max(speed, 1) * 3 + 10
	while alive() and os.clock() < deadline do
		local dt = RunService.Heartbeat:Wait()
		if not hrp.Parent then
			return false, "no character"
		end
		local cur = hrp.Position
		bad = ((cur - pos).Magnitude > SLACK) and bad + 1 or 0
		if bad >= 3 then
			speed, pos, bad = onPull(speed), cur, 0
		end
		local d = target - pos
		if d.Magnitude < 4 then
			return true
		end
		pos += d.Unit * math.min(d.Magnitude, speed * dt)
		hrp.CFrame = CFrame.new(pos) * hrp.CFrame.Rotation
		hrp.AssemblyLinearVelocity = Vector3.zero
	end
	return false, alive() and "glide timed out" or "stopped"
end

-- farm -----------------------------------------------------------------------
local began -- the server's FallRewardEvent `begin` for us: the case drop
local farmConns = {}
table.insert(farmConns, R.FallRewardEvent.OnClientEvent:Connect(function(m)
	if type(m) == "table" and m.player == player and m.kind == "begin" then
		began = m
		if on.farm then
			fire("FallRewardEvent", { kind = "waveCutsceneDone" }) -- skips the 8s case spin
		end
	end
end))

local function withZonePinned(fn)
	-- the client reports the wave unless you are inside CollectZone: keep the (local) part on you
	local zones = workspace:FindFirstChild("Zones")
	local cz = zones and zones:FindFirstChild("CollectZone")
	if not (cz and cz:IsA("BasePart")) then
		first("WARN no workspace.Zones.CollectZone: the wave will get you on the way home")
		return fn()
	end
	local cf, size = cz.CFrame, cz.Size
	local pin = RunService.Heartbeat:Connect(function()
		local hrp = root()
		if hrp then
			cz.CFrame = hrp.CFrame
			cz.Size = Vector3.new(40, 40, 40)
		end
	end)
	local ok, a, b = pcall(fn)
	pin:Disconnect()
	cz.CFrame, cz.Size = cf, size
	if not ok then
		error(a, 0)
	end
	return a, b
end

local function carryHome(alive)
	local hrp, hum = root()
	if not hrp then
		return false, "no character"
	end
	local t = os.clock()
	while (hrp.Anchored or hum.WalkSpeed == 0) and os.clock() - t < 5 do
		task.wait() -- the landing anchors you until the hand-off releases you
	end
	local speed = math.max(hum.WalkSpeed, 16) * carryFactor
	step(("carrying %s home at %d studs/s"):format(A("_HoldingCase") or "?", speed))
	local ok, why = glideTo(HOME, speed, alive, function(s)
		carryFactor = math.max(CARRY_FLOOR, carryFactor * CARRY_BACKOFF)
		log(("pulled back at %d studs/s carrying; factor now %.2f"):format(s, carryFactor))
		return s * CARRY_BACKOFF
	end)
	return ok, why
end

local function kickOnce(alive)
	declineOffer()
	local KA = kickAuto()
	if not KA then
		say("WARN the game's KickAuto handle is missing (getrenv()._G.KickAuto)")
		task.wait(3)
		return
	end
	local hrp = root()
	if not hrp then
		task.wait(1)
		return
	end
	local before = caseTotal()
	if holding() then
		stats.last = tostring(A("_HoldingCase"))
		first("resuming a carry already in hand")
	else
		step("to the jump zone")
		fire("RequestSelectHotbar", 0)
		if not KA.state().inZone then
			fire("RequestTopHubTeleport", { kind = "jumpzone" })
			local t = os.clock()
			while not KA.state().inZone and os.clock() - t < ZONE_WAIT and alive() do
				task.wait(0.1)
			end
		end
		if not KA.state().inZone then
			say("not in the kick zone after the TP (respawn offer, a cutscene?); retrying")
			task.wait(2)
			return
		end
		step("kick bar")
		began = nil
		KA.press()
		local t = os.clock()
		while not KA.state().minigameActive and os.clock() - t < 3 do
			task.wait()
		end
		local s = KA.state()
		if not s.minigameActive then
			say("the kick bar did not open; retrying")
			task.wait(1)
			return
		end
		local f = tonumber(s.oscFreq) or 1.1
		-- triangle wave, period 2f, full at t mod 2f == f (KickController's bar)
		t = os.clock()
		while math.abs((os.clock() - s.startTime) % (2 * f) - f) >= PEAK_WINDOW and os.clock() - t < 5 do
			task.wait()
		end
		pcall(KA.lock)
		stats.kicks += 1
		step("takeoff")
		hrp = root()
		t = os.clock()
		while hrp and hrp.Parent and hrp.Position.Z < 140 and os.clock() - t < TAKEOFF_WAIT and alive() do
			task.wait()
		end
		step("flying, boosting")
		local boosts, grounded = 0, nil
		while not began and os.clock() - t < LAND_WAIT and alive() do
			if A("_IsKicking") then
				grounded = nil
				if boosts < BOOSTS then
					fire("BoostKick")
					boosts += 1
				end
			else
				grounded = grounded or os.clock()
				if os.clock() - grounded > 8 then
					break -- down for 8s with no case: this kick paid nothing
				end
			end
			task.wait(BOOST_GAP)
		end
		if not began then
			say("no case dropped after the kick (landed nowhere?)")
			return
		end
		stats.last = tostring(began.winningKey or began.rarity)
	end
	local ok, why = withZonePinned(function()
		step("waiting for the hand-off")
		local t = os.clock()
		while not holding() and os.clock() - t < HANDOFF_WAIT and alive() do
			task.wait()
		end
		if not holding() then
			return false, "the case never reached your hands"
		end
		local done, w = carryHome(alive)
		if not done then
			return false, w
		end
		step("claiming")
		t = os.clock()
		while holding() and os.clock() - t < CLAIM_WAIT do
			task.wait(0.1)
		end
		return not holding(), holding() and "home, but the claim was not taken" or nil
	end)
	local got = caseTotal() - before
	if got > 0 then
		stats.cases += got
		local h = root()
		say(("banked %s x%d (%d this session, %d lost) at Z %d"):format(stats.last, got, stats.cases, stats.lost, h and h.Position.Z or -1))
	elseif alive() then
		stats.lost += 1
		say(("lost the %s case: %s (KickPower %s, carry factor %.2f)"):format(
			stats.last, tostring(why or (ok and "no count change" or "?")), fmt(A("KickPower")), carryFactor))
		declineOffer()
	end
end

-- lift -----------------------------------------------------------------------
local function lifting()
	return A("_AuraLifting") == true
end
local function holdBarbell()
	local t0 = os.clock()
	while A("_InKickSession") and os.clock() - t0 < 6 do
		task.wait(0.2) -- the hotbar is refused until the server closes the kick session
	end
	-- ...and while a spin UI (case reveal, wheel) is open: the client reports it with SpinUIState
	t0 = os.clock()
	while A("_SpinUIOpen") and os.clock() - t0 < 4 do
		task.wait(0.2)
	end
	if A("_SpinUIOpen") then
		first("closing a lingering spin UI so the barbell can come out")
		fire("SpinUIState", "background", false)
		fire("SpinUIState", false)
		task.wait(0.5)
	end
	for _ = 1, 3 do
		if lifting() then
			return true
		end
		-- the select TOGGLES: re-sending 1 while slot 1 is active puts the barbell away
		if A("ActiveHotbar") == 1 then
			fire("RequestSelectHotbar", 0)
			task.wait(0.5)
		end
		fire("RequestSelectHotbar", 1) -- slot 1 is the barbell
		local t = os.clock()
		while not lifting() and os.clock() - t < 3 do
			task.wait(0.1)
		end
	end
	local h = root()
	first(("WARN hotbar 1 did not start lifting (hotbar %s, kick session %s, holding %s, Z %d)"):format(
		tostring(A("ActiveHotbar")), tostring(A("_InKickSession")), tostring(A("_HoldingCase")), h and h.Position.Z or -1))
	return lifting()
end
local function liftFor(secs, alive)
	local hrp = root()
	if hrp and hrp.Position.Z > HOME.Z + 40 and not holding() then
		step("back to the hub to lift")
		glideTo(HOME, TRAVEL_SPEED, alive, function(s)
			return s * 0.7
		end)
	end
	if not holdBarbell() then
		task.wait(1)
		return
	end
	local s0, t = tonumber(A("Strength")) or 0, os.clock()
	while alive() and os.clock() - t < secs do
		step(("lifting (%s Strength, %s/s)"):format(fmt(A("Strength")), fmt(((tonumber(A("Strength")) or 0) - s0) / math.max(1, os.clock() - t))))
		task.wait(1)
		if not lifting() then
			holdBarbell()
		end
	end
end

local trainConn
local function setTrain(state)
	on.train = state
	if trainConn then
		trainConn:Disconnect()
		trainConn = nil
	end
	if state and R.OsuTrain then
		trainConn = R.OsuTrain.OnClientEvent:Connect(function(m)
			if type(m) == "table" and m.kind == "spawn" and m.id ~= nil then
				local life = math.max(0.2, tonumber(m.life) or OsuCfg.LIFE_BASE)
				task.delay(life * OsuCfg.APPROACH_AT + 0.03, function() -- the ring closes here
					if on.train then
						fire("OsuTrain", { kind = "hit", id = m.id })
					end
				end)
			end
		end)
	end
end

-- open -----------------------------------------------------------------------
local lastReveal
local openConn = R.CaseOpened and R.CaseOpened.OnClientEvent:Connect(function(m)
	if type(m) == "table" and m.RevealId then
		lastReveal = m
	end
end)
local function openSome(alive, cap)
	local n = 0
	for kind in pairs(heldCases()) do
		while caseOn[baseKind(kind)] and (tonumber(A("Cases_" .. kind)) or 0) > 0 and n < cap and alive() and not holding() do
			step("opening " .. kind)
			lastReveal = nil
			local have = tonumber(A("Cases_" .. kind)) or 0
			fire("RequestOpenCase", kind)
			local t = os.clock()
			while not lastReveal and os.clock() - t < OPEN_WAIT do
				task.wait()
			end
			if not lastReveal then
				say(("opening %s got no reply; skipping it this lap"):format(kind))
				return n
			end
			task.wait(REVEAL_AFTER)
			fire("RequestRevealComplete", { id = lastReveal.RevealId })
			n += 1
			stats.opened += 1
			say(("opened %s -> %s (%s)"):format(kind, tostring(lastReveal.Brainrot), tostring(lastReveal.Mutation)))
			t = os.clock()
			while ((tonumber(A("Cases_" .. kind)) or 0) >= have or A("_OpeningCase")) and os.clock() - t < 2 do
				task.wait(0.1)
			end
		end
	end
	return n
end

-- rebirth ----------------------------------------------------------------------
-- The requirement is the rebirth panel's "37.2K/5K Jump Power"; RequestRebirth also teleports you
-- to base (RebirthTeleport), which is why it only runs here, between kicks.
local function rebirthNeed()
	local ok, label = pcall(function()
		return player.PlayerGui.Game.Frames.Rebirth.Content.BarFrame.Bar.Amount.Text
	end)
	local need = ok and tostring(label):match("/%s*([^%s]+)%s+Jump")
	return need and money(need)
end
local function rebirthIfReady()
	local need = rebirthNeed()
	local kp = tonumber(A("KickPower")) or 0
	if not need then
		first("WARN rebirth requirement label not found; auto rebirth idle")
		return
	end
	if kp < need then
		return
	end
	step("rebirthing")
	local r0 = tonumber(A("Rebirths")) or 0
	fire("RequestRebirth", { mode = "rebirth" })
	local t = os.clock()
	while (tonumber(A("Rebirths")) or 0) == r0 and os.clock() - t < 4 do
		task.wait(0.1)
	end
	if (tonumber(A("Rebirths")) or 0) > r0 then
		say(("rebirth %d (Jump Power %s, needed %s)"):format(A("Rebirths"), fmt(kp), fmt(need)))
		task.wait(1.5) -- let the RebirthTeleport land before the next jump-zone TP
	else
		say("rebirth refused at Jump Power " .. fmt(kp) .. " / " .. fmt(need))
	end
end

-- worker: the one thread that uses the character --------------------------------
local workerGen = 0
local function worker()
	workerGen += 1
	local mine = workerGen
	local function alive()
		return workerGen == mine and (on.farm or on.lift or on.open or on.rebirth)
	end
	local function farming()
		return alive() and on.farm
	end
	local function liftingOn()
		return alive() and on.lift
	end
	task.spawn(function()
		while alive() do
			local ok, err = pcall(function()
				if on.open then
					openSome(alive, 50)
				end
				if on.farm then
					kickOnce(farming)
				end
				if on.rebirth and not holding() then
					rebirthIfReady()
				end
				if on.lift and alive() then
					-- farm off: 30s chunks, so opening still gets a turn between them
					liftFor(on.farm and liftSecs or 30, liftingOn)
				elseif not on.farm then
					step("waiting for cases to open")
					task.wait(2)
				end
			end)
			if not ok then
				say("WARN worker: " .. tostring(err))
				task.wait(2)
			end
		end
		if workerGen == mine then
			step("idle")
		end
	end)
end
local function restartWorker()
	if on.farm or on.lift or on.open or on.rebirth then
		worker()
	else
		workerGen += 1
		step("idle")
	end
end

-- econ: position-free spends and claims --------------------------------------------
local orig = { collect = A("_AutoCollectEnabled") == true, rebirth = A("AutoRebirthOn") == true }
local function setSetting(key, value)
	fire("RequestSetSetting", { key = key, value = value })
end

local function weightIndex(name)
	for i, k in ipairs(WeightsConfig.Order) do
		if k == name then
			return i
		end
	end
	return 0
end
local weightBackoff = 0
local function buyWeight()
	if os.clock() < weightBackoff or A("_InKickSession") then
		return -- the equip is refused during a kick session (Radioactive bought mid-carry stayed unequipped)
	end
	local cash = tonumber(A("Cash")) or 0
	local cur = weightIndex(A("EquippedWeight"))
	local best
	for i = #WeightsConfig.Order, cur + 1, -1 do
		local w = WeightsConfig.Get(WeightsConfig.Order[i])
		if w and tonumber(w.Price) and w.Price > 0 and w.Price <= cash then
			best = WeightsConfig.Order[i]
			break
		end
	end
	if best then
		fire("RequestBuyWeight", { key = best })
		local t = os.clock()
		while A("EquippedWeight") ~= best and os.clock() - t < 2 do
			task.wait(0.1)
		end
		if A("EquippedWeight") ~= best then
			-- a buy does not always equip (Copper did, Sand did not); an owned one equips by key
			fire("RequestEquipWeight", { key = best })
			t = os.clock()
			while A("EquippedWeight") ~= best and os.clock() - t < 2 do
				task.wait(0.1)
			end
		end
		if A("EquippedWeight") == best then
			stats.bought += 1
			say("bought and equipped " .. best)
		else
			say("the shop did not take " .. best .. "; retrying in a minute")
			weightBackoff = os.clock() + 60
		end
	end
end
local speedBackoff = 0
local function buySpeed()
	if os.clock() < speedBackoff then
		return
	end
	local n = tonumber(A("SpeedUpgrades")) or 0
	local ok, cost = pcall(SpeedCfg.TotalCost, n, 26)
	cost = ok and tonumber(cost) or nil
	if not cost or cost > (tonumber(A("Cash")) or 0) * SPEED_SHARE then
		return
	end
	fire("RequestSpeedUpgrade", { index = SPEED_TILE, introFree = false })
	local t = os.clock()
	while (tonumber(A("SpeedUpgrades")) or 0) == n and os.clock() - t < 3 do
		task.wait(0.1)
	end
	if (tonumber(A("SpeedUpgrades")) or 0) > n then
		stats.speed += 1
		first("speed upgrades buying: +26 for " .. fmt(cost))
	else
		speedBackoff = os.clock() + 60 -- capped, or the server's price differs from the config
		first("a speed upgrade was refused; backing off a minute at a time")
	end
end
-- Each Floors.*.Slots["Slot N"] sign reads "$263B | Lvl 21 > Lvl 22": its next level's price.
local function slotPrices()
	local plot = workspace:FindFirstChild("Plots") and workspace.Plots:FindFirstChild("Plot" .. tostring(A("BasePlot")))
	local out = {}
	if not plot then
		return out
	end
	for _, d in ipairs(plot:GetDescendants()) do
		local g = d:GetAttribute("_GlobalSlot")
		if g and d.Name:match("^Slot %d+$") then
			local price, lvl
			for _, t in ipairs(d:GetDescendants()) do
				if t:IsA("TextLabel") then
					price = price or money(t.Text)
					lvl = lvl or t.Text:match("^Lvl %d+")
				end
			end
			if price and lvl then -- no "Lvl a > Lvl b" = empty slot, maxed, or a paid pet
				out[#out + 1] = { slot = g, price = price }
			end
		end
	end
	table.sort(out, function(a, b)
		return a.price < b.price
	end)
	return out
end

local function levelPets()
	for _ = 1, LEVEL_BURST do
		local cheapest = slotPrices()[1]
		if not cheapest or cheapest.price > (tonumber(A("Cash")) or 0) then
			return
		end
		fire("RequestSlotLevel", { slot = cheapest.slot })
		stats.levels += 1
		first("levelling pets", ("(first: slot %d for %s)"):format(cheapest.slot, fmt(cheapest.price)))
		task.wait(LEVEL_GAP)
	end
end

local lastPlace, lastFree = 0, 0
local function freebies()
	if A("Daily_Claimable") then
		fire("RequestDailyClaim")
	end
	fire("RequestSpinWheel", { mode = "free" })
	fire("RequestClaimOffline")
	fire("RequestClaimAllIndexGems")
	task.spawn(invokeTimed, "RequestClaimPermQuest", 5, {})
end

local econGen = 0
local function econ()
	econGen += 1
	local mine = econGen
	task.spawn(function()
		while econGen == mine and (on.weights or on.speed or on.level or on.place or on.free) do
			pcall(function()
				if on.weights then
					buyWeight()
				end
				if on.speed then
					buySpeed()
				end
				if on.level then
					levelPets()
				end
				if on.place and os.clock() - lastPlace > PLACE_EVERY then
					lastPlace = os.clock()
					fire("BasePetsRequest", "PlaceBest")
				end
				if on.free and os.clock() - lastFree > FREEBIE_EVERY then
					lastFree = os.clock()
					freebies()
				end
			end)
			task.wait(ECON_EVERY)
		end
	end)
end

-- watchdog --------------------------------------------------------------------
local watchGen = 0
task.spawn(function()
	watchGen += 1
	local mine = watchGen
	while watchGen == mine do
		task.wait(10)
		if crumb ~= "idle" and os.clock() - crumbAt > STUCK_AFTER and (on.farm or on.open) then
			log(("stuck at '%s' for %ds"):format(crumb, os.clock() - crumbAt))
			crumbAt = os.clock()
		end
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Jump for Cases", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "dices")
local Farm = Tab:AddLeftGroupbox("Kick", "rocket")
local Lift = Tab:AddLeftGroupbox("Strength", "dumbbell")
local Cases = Tab:AddRightGroupbox("Cases", "package-open")
local Econ = Tab:AddRightGroupbox("Spend and claim", "coins")

Farm:AddToggle("Farm", {
	Text = "Auto kick farm",
	Tooltip = "Kick at Perfect, boost, carry the case home past the wave, bank it",
	Default = false,
	Callback = function(state)
		on.farm = state
		restartWorker()
	end,
})
Farm:AddLabel("Carries glide at 1.45x WalkSpeed; a pull-back lowers it. Speed upgrades make the trip shorter.", true)

Lift:AddToggle("Lift", {
	Text = "Lift between kicks",
	Tooltip = "Holds the barbell (hotbar 1). With the farm off it lifts nonstop",
	Default = false,
	Callback = function(state)
		on.lift = state
		restartWorker()
	end,
})
Lift:AddInput("LiftSecs", {
	Text = "Lift seconds between kicks",
	Default = tostring(LIFT_SECS),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		liftSecs = math.clamp(tonumber(text) or LIFT_SECS, 0, 3600)
	end,
})
Lift:AddToggle("Train", {
	Text = "Auto train (hit the circles)",
	Tooltip = "Answers the rhythm circles 1-5 while lifting; the combo speeds Strength up ~2x",
	Default = false,
	Callback = function(state)
		setTrain(state)
	end,
})

local caseDefault = {}
for _, k in ipairs(CASE_KEYS) do
	caseDefault[#caseDefault + 1] = k
	caseOn[k] = true -- Default does not fire the callback, so arm by hand
end
local function ticked(v) -- a Multi dropdown hands a map; accept a list too
	local out = {}
	for k, x in pairs(v or {}) do
		if type(k) == "number" then
			out[x] = true
		elseif x then
			out[k] = true
		end
	end
	return out
end
assert(ticked({ "A" }).A and ticked({ B = true }).B and not ticked({ C = false }).C)
Cases:AddDropdown("CaseKinds", {
	Text = "Case kinds to open",
	Values = CASE_KEYS,
	Default = caseDefault,
	Multi = true,
	Callback = function(picked)
		table.clear(caseOn)
		for k in pairs(ticked(picked)) do
			caseOn[k] = true
		end
	end,
})
Cases:AddToggle("Open", {
	Text = "Auto open cases",
	Tooltip = "Opens the ticked kinds between kicks, skipping the 8s spin",
	Default = false,
	Callback = function(state)
		on.open = state
		restartWorker()
	end,
})

Econ:AddToggle("Collect", {
	Text = "Auto collect (game's own)",
	Tooltip = "Your owned Auto Collect setting; put back at unload",
	Default = false,
	Callback = function(state)
		setSetting("AutoCollect", state or orig.collect)
	end,
})
Econ:AddToggle("Rebirth", {
	Text = "Auto rebirth (between kicks)",
	Tooltip = "Rebirths once Jump Power meets the requirement, never mid-kick: resets Jump Power only, +1x money",
	Default = false,
	Callback = function(state)
		on.rebirth = state
		-- the game's own Auto Rebirth fires mid-flight and wastes the lap: keep it off while we drive
		setSetting("AutoRebirth", (not state) and orig.rebirth)
		restartWorker()
	end,
})
local function econToggle(idx, key, text, tip)
	Econ:AddToggle(idx, {
		Text = text,
		Tooltip = tip,
		Default = false,
		Callback = function(state)
			on[key] = state
			econ()
		end,
	})
end
econToggle("Weights", "weights", "Auto buy best barbell", "The priciest cash barbell you can afford above the one you hold")
econToggle("Speed", "speed", "Auto speed upgrades", "+26 speed units when it costs under 10% of your cash")
econToggle("Level", "level", "Auto level placed pets", "One level at a time on the slot whose next level is cheapest")
econToggle("PlaceBest", "place", "Place best brainrots", "The game's Place Best button every 30s")
econToggle("Free", "free", "Auto claim freebies", "Daily, free wheel, offline, index gems, perm quest")

local conns = {}
local note = "idle"
local nextStrip = 0
local s0, sAt = tonumber(A("Strength")) or 0, os.clock()
local strRate = 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	if pending then
		note, pending = pending, nil
	end
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	if now - sAt >= 10 then
		local s = tonumber(A("Strength")) or 0
		strRate, s0, sAt = math.max(0, (s - s0) / (now - sAt)), s, now
	end
	pcall(Window.SetStatus, Window, {
		{ "Cash", fmt(A("Cash")) },
		{ "Cases", ("%d banked, %d lost, last %s"):format(stats.cases, stats.lost, stats.last) },
		{ "Opened", stats.opened .. " cases, " .. stats.levels .. " pet levels" },
		{ "Strength", fmt(A("Strength")) .. " (+" .. fmt(strRate) .. "/s)" },
		{ "Carry", ("%.2fx"):format(carryFactor) },
		{ "Now", crumb .. (note ~= crumb and (" | " .. note) or "") },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("JumpForCases", {})

local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- close ----------------------------------------------------------------------
local function stopAll()
	on.farm, on.lift, on.open, on.rebirth = false, false, false, false
	on.weights, on.speed, on.level, on.place, on.free = false, false, false, false, false
	workerGen += 1
	econGen += 1
	watchGen += 1
	setTrain(false)
	setSetting("AutoCollect", orig.collect)
	setSetting("AutoRebirth", orig.rebirth)
	for _, c in ipairs(farmConns) do
		c:Disconnect()
	end
	if openConn then
		openConn:Disconnect()
	end
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().jumpCasesStop = nil
end)

getgenv().jumpCasesStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().jumpCasesStop = nil
end
