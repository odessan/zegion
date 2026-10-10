--[[ Swordwave Legend -- hop-run the stage road for Wins, click for Power, equip, rebirth, spend, raid (113220849219354)

     WINS    : a LAP. RequestReturnHub, equip the best weapon, hop out to the road and hop to each stage's entry
               in steps of 120 studs or less. The game's own pet / sword clears the stage within ~1.5s of you being
               in it and the client reports it (ReportCombat Cleared), so the whole lap is hops and a wait for Wins
               to change. Stage pay grows about 4x per stage (stage 1 = 2, stage 14 = 335K at 25K per click), and a
               stage pays once per trip from the hub (revisiting inside a trip paid 0, six of six), so a lap is
               hub -> stage 1 .. N -> hub. A lap to stage 14 earned ~760K Wins in 28s.
     WAVEDASH: the shop row Wavestep, 17.5K rebirth balance for level 1 (a second 149-Robux button sits beside it; this
               script only ever spends balance). Owned and armed (SetWavestepArmed), leaving the hub does it all on
               its own, nothing to fire: after the game's ~2.3s spawn hold the server clears every stage you can
               one-shot at once, up to its coverage cap (stage 50 at level 1), pays them together, moves CurrentStage
               past them and teleports you to the first stage it did not cover; the pet clears that one normally.
               Probed: stage 1 -> 27, +2B Wins at 2.5s, teleport at 3.3s, stage 27 paid +11B at 7s. A lap went from
               ~45s to 3-16s. The lap therefore always works from UI.currentStage(), never from 1. The "Use WaveDash"
               toggle only arms it if the player has not, and disarms again only what it armed.
     DEPTH   : the lap goes as deep as it still gets paid. The first stage that pays nothing (or the first time health
               drops under HP_FLOOR) is remembered with your Power at that moment, and is tried again only once Power
               is CAP_RETRY times higher. Stage 15 cost 290 of 1000 health at 5e5 Power; stage 14 is where it stopped
               paying at weapon 3.
     POWER   : TrainClick at ~9/s from its own thread. The server credits at most ~8.4 clicks/s (sent 5/10/20/25 per
               second: 5.4 / 7.8 / 8.4 / 8.4 credited), so 9 saturates it. Needs no stand, no walking.
     WEAPON  : weapons unlock by Wins on their own; you EQUIP one by touching its pad (Workspace.MainHub.WeaponTerrace
               .WeaponSlot_NN.Pad), so the script hops onto the highest unlocked pad in the hub. Weapon 8 was x1400 on
               click power. Auto Equip Best is a Robux-priced shop row, not wired.
     REBIRTH : RequestRebirth when pending >= 1 and the power multiplier it buys, (1 + 0.1*(balance+pending)) /
               (1 + 0.1*balance), is at least REBIRTH_GAIN. Measured: 8 -> 326 balance made click power x33.6, and
               three laps (95s) later it stood at 1.8M per click, depth 19, weapon 10, 87M Wins. The game's own preview
               says "Low value" because it does not count the weapons coming back. Resets Power, Wins, weapons, stage.
     UPGRADE : Dojo (RequestDojoUpgrade) whenever the snapshot says it can; shop rows (BuyRebirthUpgrade(id)) only when
               the cost is under 1/SHOP_HEADROOM of your balance, because the balance IS the rebirth multiplier.
     PETS    : EquipBestPets on a timer (blocked while a raid runs).
     RAID    : the Rift schedule (a boss every 20 min, join window opens 60s before the fight): RiftNetwork.Request
               "RiftJoin" {intervalId}, reply eligibility "Joined". The server teleports you to the arena (-2400, 32,
               -782), the pet fights by itself (RiftPetAppliedDamage) and the 3-player boss fell in ~2 min with no
               input; player attribute RiftActive is true throughout and the game puts you back at (4, 140) after.
               Rewards are trait tickets / seals / fusion tokens on boss-% milestones, which this script does not
               spend. A join stops the director first (hops from the arena would be hundreds of studs); a raid costs
               ~2-5 of every 20 minutes of laps, so it is off unless ticked.

     Hop ceilings (probed, rule 10): hub 80 studs (160 was reverted), road 160 held. The script uses 70 / 120.
     Walk-only fallback: three reverts in a row and a leg is walked with Humanoid:MoveTo.
     Not wired (Robux): Wavestep (WaveDash), Auto Equip Best, the pet-slot / evolve / echo-pack purchases, RiftSummon.
     Not wired (needs you): Auto Win needs the game's Roblox group.

     RightControl opens / closes the panel. Stop: getgenv().swordwaveLegendStop() ]]

-- config ---------------------------------------------------------------------
local TRAIN_GAP = 0.115 -- between TrainClicks. The server credits ~8.4/s at most, so 9/s saturates it. Raise if the remote flood limit (30/s) gets close
local HOP_HUB = 70 -- studs per hop inside the hub. 80 held, 160 was reverted
local HOP_ROAD = 120 -- studs per hop on the road. 160 held; a stage is ~113 studs long
local HOP_SETTLE = 0.15 -- after each hop, before the position is checked. Raise if hops read as reverted
local ARRIVE = 8 -- studs (flat) from a target that count as arrived
local REVERT_MAX = 3 -- reverted hops in a row before a leg is walked
local ROAD_X, ROAD_Y = 4, 3.5 -- the road runs along Z at x=4
local ROAD_START_Z = 140 -- first road point, ~60 studs past the hub exit at z=80
local STAGE_INSET = 6 -- studs past a stage's entry that count as inside its arena
local FIRST_PAY_WAIT = 8 -- stage 1 waits out the game's spawn hold (~2.3s) after a hub return
local PAY_WAIT = 8 -- a stage that has not paid by now is the depth limit (stage 14 took 4.1s, stage 27 took 4.5s)
local HP_FLOOR = 0.4 -- leave the road under this fraction of max health
local CAP_RETRY = 4 -- a failed stage is tried again once Power is this many times higher
local MAX_STAGE = 200 -- deepest stage a lap aims for. Zone 11 (201+) opens after Reincarnation
local HUB_WAIT = 8 -- seconds a RequestReturnHub has to land
local LAP_GAP = 0.3 -- between laps
local REBIRTH_GAIN = 3 -- rebirth when it multiplies click power by at least this. Raise to rebirth less often
local REBIRTH_WAIT = 8 -- the rebirth has to show (Wins reset) inside this
local SHOP_HEADROOM = 20 -- buy a shop row only when its cost x this <= your balance (it is the rebirth multiplier)
local SPEND_EVERY = 2 -- Dojo / shop check beat
local BUY_GAP = 1.2 -- between BuyRebirthUpgrade calls (limit: 1/s, burst 4)
local PETS_EVERY = 60 -- EquipBestPets beat
local RAID_POLL = 20 -- Rift schedule poll beat; 3s inside a join window
local STUCK_AFTER = 40 -- the watchdog names the step the director has sat in this long

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")
local player = Players.LocalPlayer

if getgenv and getgenv().swordwaveLegendStop then
	getgenv().swordwaveLegendStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[swordwave]", ...)
end

local seen = {}
local function first(name, ...) -- one console line per unproven branch
	if not seen[name] then
		seen[name] = true
		log(name, ...)
	end
end

-- The panel strip is drained from a Heartbeat, which the engine calls with our own identity.
-- A loop thread that writes to the window directly throws "lacking capability Plugin" after its first task.wait.
local pending, lastSaid = {}, nil
local function say(msg)
	pending.now = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- breadcrumb: the watchdog thread (separate, so a parked director can still be reported)
local mark, markAt = "idle", os.clock()
local function step(s)
	mark, markAt = s, os.clock()
end

-- game -----------------------------------------------------------------------
local okm, UI, Stages, RebirthCfg = pcall(function()
	return require(player:WaitForChild("PlayerScripts"):WaitForChild("UI"):WaitForChild("UIState")),
		require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("StagesConfig")),
		require(ReplicatedStorage.Shared.Config.RebirthConfig)
end)
if not okm or type(UI) ~= "table" or type(UI.Snapshot) ~= "table" then
	warn("[swordwave] the game's modules did not load:", UI)
	return
end
local Remotes = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes")
local GP = Remotes:WaitForChild("GameplayRemoteEvents", 15)
if not GP then
	warn("[swordwave] GameplayRemoteEvents not found")
	return
end
local R = {}
for _, name in ipairs({ "TrainClick", "RequestReturnHub", "RequestRebirth", "BuyRebirthUpgrade", "RequestDojoUpgrade", "EquipBestPets" }) do
	R[name] = GP:WaitForChild(name, 10)
	if not R[name] then
		warn("[swordwave] remote missing:", name)
		return
	end
end
R.SetWavestepArmed = GP:FindFirstChild("SetWavestepArmed") -- optional: only the WaveDash toggle needs it
local RiftReq = Remotes:FindFirstChild("RiftNetwork") and Remotes.RiftNetwork:FindFirstChild("Request")
local COEFF = tonumber(RebirthCfg.PowerGainPerRebirth) or 0.1 -- 8 balance -> x1.8, 326 -> x33.6 (probed)

local function S() -- always the live table: UIState replaces it, a cached copy goes stale (probed at the rebirth)
	return UI.Snapshot
end

-- "1|3.18|6" = 3.18e6 (sign|mantissa|exponent); a plain number or "0" also read
local function big(v)
	if type(v) == "number" then
		return v
	end
	if type(v) ~= "string" then
		return 0
	end
	local sign, m, e = v:match("^(%-?%d+)|([%d%.eE%+%-]+)|(%-?%d+)$")
	if sign then
		return (tonumber(sign) or 0) * (tonumber(m) or 0) * 10 ^ (tonumber(e) or 0)
	end
	return tonumber((v:gsub(",", ""))) or 0
end
assert(math.abs(big("1|3.18|6") - 3.18e6) < 1 and big("1|8|0") == 8 and big(0) == 0 and big("0") == 0, "big")

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function fmt(n)
	local i = 1
	while n >= 1000 and i < #SUFFIX do
		n /= 1000
		i += 1
	end
	return ("%.3g"):format(n) .. SUFFIX[i]
end
assert(fmt(25000) == "25K" and fmt(1500) == "1.5K" and fmt(260e9) == "260B" and fmt(100) == "100", "fmt")

local function gain(balance, pend) -- the click-power multiplier a rebirth buys
	return (1 + COEFF * (balance + pend)) / (1 + COEFF * balance)
end
assert(math.abs(gain(8, 318) - 33.6 / 1.8) < 1e-6, "gain")

-- A Rift join teleports us to the arena (probed: (-2400, 32, -782), the pet fights by itself), so while one is on, no
-- hop, click or lap may run. The schedule poll sets raidBusy; the game's own RiftActive attribute backs it up.
local raidBusy = false
local function inRaid()
	return raidBusy or player:GetAttribute("RiftActive") == true
end

local function root()
	local c = player.Character
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	return hrp, hum
end

local function callTimed(rf, secs, ...) -- an InvokeServer with no timeout parks the thread forever
	local args, done, res = table.pack(...), false, nil
	task.spawn(function()
		local ok, r = pcall(function()
			return rf:InvokeServer(table.unpack(args, 1, args.n))
		end)
		res = ok and r or nil
		done = true
	end)
	local t = os.clock()
	while not done and os.clock() - t < secs do
		task.wait(0.05)
	end
	return res
end

-- world ----------------------------------------------------------------------
local function waitChar(secs)
	local t = os.clock()
	while os.clock() - t < secs do
		local hrp, hum = root()
		if hrp and hum and hum.Health > 0 then
			return true
		end
		task.wait(0.2)
	end
	return false
end

-- One hop of at most `maxStep` studs along the line to `pos`, checked after HOP_SETTLE. Three reverts in a row and
-- the leg is walked instead. Returns whether we arrived.
local function walkTo(pos, secs)
	local hrp, hum = root()
	if not (hrp and hum) then
		return false
	end
	hum:MoveTo(pos)
	local t = os.clock()
	while os.clock() - t < secs do
		hrp = root()
		if not hrp then
			return false
		end
		if (Vector3.new(hrp.Position.X, 0, hrp.Position.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude <= ARRIVE then
			return true
		end
		task.wait(0.1)
	end
	return false
end

local function hopTo(pos)
	local reverts = 0
	for _ = 1, 40 do
		local hrp = root()
		if not hrp or inRaid() then
			return false
		end
		local flat = Vector3.new(pos.X - hrp.Position.X, 0, pos.Z - hrp.Position.Z)
		if flat.Magnitude <= ARRIVE then
			return true
		end
		local maxStep = S().InHub and HOP_HUB or HOP_ROAD
		local stepv = flat.Magnitude > maxStep and flat.Unit * maxStep or flat
		local target = Vector3.new(hrp.Position.X + stepv.X, pos.Y, hrp.Position.Z + stepv.Z)
		player.Character:PivotTo(CFrame.new(target, target + Vector3.new(0, 0, 1)))
		task.wait(HOP_SETTLE)
		local now = root()
		if not now then
			return false
		end
		if (now.Position - target).Magnitude > 12 then
			reverts += 1
			first("hop reverted", ("%.0f studs, from z=%.0f"):format(stepv.Magnitude, hrp.Position.Z))
			if reverts >= REVERT_MAX then
				first("walking a leg", "after", reverts, "reverts")
				return walkTo(pos, 12)
			end
		else
			reverts = 0
		end
	end
	return false
end

local function toHub()
	for _ = 1, 3 do
		if S().InHub then
			return true
		end
		if inRaid() then
			return false -- the game drops it in a raid, and the raid ends by itself
		end
		R.RequestReturnHub:FireServer()
		local t = os.clock()
		while not S().InHub and os.clock() - t < HUB_WAIT do
			task.wait(0.1)
		end
		task.wait(0.4)
		if S().InHub then
			return true
		end
		task.wait(1.2) -- RequestReturnHub: 1/s refill
	end
	return false
end

local function topWeapon()
	local top = 0
	for _, i in ipairs(S().UnlockedWeapons or {}) do
		if i > top then
			top = i
		end
	end
	return top
end

local function equipBest()
	local top = topWeapon()
	if top == 0 or S().EquippedWeapon == top then
		return true
	end
	local hub = workspace:FindFirstChild("MainHub")
	local terrace = hub and hub:FindFirstChild("WeaponTerrace")
	local slot = terrace and terrace:FindFirstChild(("WeaponSlot_%02d"):format(top), true)
	local pad = slot and slot:FindFirstChild("Pad")
	if not pad then
		first("no weapon pad", top)
		return false
	end
	for _ = 1, 2 do
		hopTo(Vector3.new(pad.Position.X, pad.Position.Y + 3, pad.Position.Z))
		local t = os.clock()
		while S().EquippedWeapon ~= top and os.clock() - t < 2 do
			task.wait(0.1)
		end
		if S().EquippedWeapon == top then
			first("weapon equipped by pad", top)
			return true
		end
		hopTo(Vector3.new(ROAD_X, pad.Position.Y + 3, 80)) -- step off and back on: the pad needs a fresh touch
	end
	return false
end

-- farm -----------------------------------------------------------------------
local stats = { laps = 0, wins = 0, rebirths = 0, deepest = 0, last = 0 }
local blocked, blockedPower = nil, 0 -- the first stage that did not pay, and our Power then
local maxStage = MAX_STAGE

local function onRoad() -- a failure only counts as a depth limit if we were still standing on the road
	local hrp = root()
	return hrp ~= nil and math.abs(hrp.Position.X - ROAD_X) < 40 and hrp.Position.Z > 100 and not S().InHub
end

local function goal()
	if not blocked then
		return maxStage
	end
	if big(S().Power) >= blockedPower * CAP_RETRY then
		return math.min(blocked, maxStage) -- try the failed stage again
	end
	return math.max(1, math.min(blocked - 1, maxStage))
end

-- Hop to each stage's entry and wait for Wins to change. Returns the deepest stage that paid and why it stopped.
local function road(alive)
	local want = goal()
	local reached, why = 0, "done"
	step("road / out")
	if not hopTo(Vector3.new(ROAD_X, ROAD_Y, ROAD_START_Z)) then
		return 0, "could not hop out"
	end
	local k = math.max(1, UI.currentStage())
	while k <= want do
		if not alive() or inRaid() then
			why = "stopped"
			break
		end
		local e = Stages.EntryPosition(k)
		local wins0 = S().Wins
		step("road / stage " .. k .. " hop")
		if not hopTo(Vector3.new(ROAD_X, ROAD_Y, e.Z + STAGE_INSET)) then
			why = "hop failed at " .. k
			break
		end
		step("road / stage " .. k .. " clear")
		local t, paid = os.clock(), false
		local limit = k == 1 and FIRST_PAY_WAIT or PAY_WAIT
		while os.clock() - t < limit do
			if S().Wins ~= wins0 then
				paid = true
				break
			end
			local _, hum = root()
			if not hum or hum.Health <= 0 then
				why = "died at " .. k
				break
			end
			if hum.Health < hum.MaxHealth * HP_FLOOR then
				why = ("health %d at %d"):format(hum.Health, k)
				break
			end
			task.wait(0.05)
		end
		if not paid then
			if inRaid() or not onRoad() then
				why = "left the road at " .. k -- teleported (raid) or sent home: says nothing about the stage
				break
			end
			if why == "done" then
				why = "no pay at " .. k
			end
			if k >= 2 then
				blocked, blockedPower = k, big(S().Power)
			end
			break
		end
		reached = k
		if blocked and k >= blocked then
			blocked = nil -- the stage that stopped us paid this time
		end
		-- WaveDash (armed + owned): the server cleared every stage we can one-shot in one go and moved CurrentStage
		-- past them, then teleports us to the first one it did not cover (probed: 1 -> 27, +2B Wins at 2.5s, teleport
		-- at 3.3s). Wait until we stop moving, and carry on from the stage the game says is next.
		local nextStage = math.max(k + 1, UI.currentStage())
		if nextStage > k + 1 then
			first("wavestep", ("stage %d -> %d"):format(k, nextStage))
			step("road / wavestep settle")
			local still, z0 = os.clock(), nil
			local t1 = os.clock()
			while os.clock() - still < 1.2 and os.clock() - t1 < 6 do
				local hrp = root()
				local z = hrp and hrp.Position.Z
				if z ~= z0 then
					z0, still = z, os.clock()
				end
				task.wait(0.1)
			end
			reached = nextStage - 1
			if blocked and reached >= blocked then
				blocked = nil
			end
		end
		k = nextStage
	end
	return reached, why
end

local function rebirthDue()
	local s = S()
	local pend = big(s.PendingRebirths)
	if pend < 1 then
		return false, 1
	end
	local g = gain(big(s.RebirthBalance), pend)
	return g >= REBIRTH_GAIN, g
end

local rebirthOn, equipOn, farmOn = false, false, false
local lastRebirth = 0

local function rebirth()
	local due, g = rebirthDue()
	if not due then
		return false
	end
	local s = S()
	log(("rebirth: pending %s, balance %s, click power x%.1f; Wins %s Power %s"):format(fmt(big(s.PendingRebirths)), fmt(big(s.RebirthBalance)), g, fmt(big(s.Wins)), fmt(big(s.Power))))
	local life0 = S().LifetimeRebirths
	R.RequestRebirth:FireServer()
	local t = os.clock()
	while os.clock() - t < REBIRTH_WAIT and S().LifetimeRebirths == life0 do
		task.wait(0.1)
	end
	if S().LifetimeRebirths == life0 then
		first("rebirth refused", "LifetimeRebirths did not move in", REBIRTH_WAIT, "s")
		return false
	end
	stats.rebirths += 1
	blocked = nil -- Power is back to 1, so the old limit says nothing
	lastRebirth = os.clock()
	log(("rebirth done: balance %s, click power %s"):format(fmt(big(S().RebirthBalance)), fmt(big(S().PowerPerClick))))
	task.wait(1)
	return true
end

local function director(alive)
	while alive() do
		local ok, err = pcall(function()
			if inRaid() then
				step("director / raid")
				say("in the raid")
				task.wait(1)
				return
			end
			if not waitChar(10) then
				say("no character")
				return
			end
			step("director / hub")
			if not toHub() then
				say("could not reach the hub")
				task.wait(2)
				return
			end
			if equipOn then
				step("director / weapon")
				equipBest()
			end
			if rebirthOn and os.clock() - lastRebirth > 3 and rebirth() then
				return
			end
			local w0, t0 = big(S().Wins), os.clock()
			local reached, why = road(alive)
			toHub()
			local gained = big(S().Wins) - w0
			stats.laps += 1
			stats.wins += gained
			stats.last = reached
			if reached > stats.deepest then
				stats.deepest = reached
			end
			say(("lap %d: stage %d (%s), +%s Wins in %.0fs"):format(stats.laps, reached, why, fmt(math.max(0, gained)), os.clock() - t0))
		end)
		if not ok then
			warn("[swordwave] director:", err)
			task.wait(1)
		end
		task.wait(LAP_GAP)
	end
end

-- power: its own thread, no movement
local function trainer(alive)
	while alive() do
		if not inRaid() then
			pcall(function()
				R.TrainClick:FireServer()
			end)
		end
		task.wait(TRAIN_GAP)
	end
end

-- spend: remotes only, so it runs beside the director
local SHOP_SKIP = { Wavestep = true, AutoEquipBest = true, WalkSpeed = true } -- Robux rows / useless when you hop
local function spender(alive)
	local lastBuy = 0
	while alive() do
		pcall(function()
			local s = S()
			if s.DojoCanUpgrade and s.DojoNextLevel ~= nil then
				local lvl = s.DojoLevel
				R.RequestDojoUpgrade:FireServer()
				first("dojo upgrade fired", "level", lvl, "gate", s.DojoNextGate)
				task.wait(1.2)
				if S().DojoLevel ~= lvl then
					log("dojo level", lvl, "->", S().DojoLevel)
				end
			end
			local bal = big(s.RebirthBalance)
			local rows = {}
			for _, row in ipairs(s.RebirthShop or {}) do
				if not SHOP_SKIP[row.Id] and row.Level < row.MaxLevel and row.StageRequirementMet ~= false then
					local okp, state = pcall(UI.shopPriceState, row)
					if okp and state == "Afford" and big(row.NextCost) * SHOP_HEADROOM <= bal then
						rows[#rows + 1] = row
					end
				end
			end
			table.sort(rows, function(a, b)
				return big(a.NextCost) < big(b.NextCost)
			end)
			local row = rows[1]
			if row and os.clock() - lastBuy > BUY_GAP then
				lastBuy = os.clock()
				local lvl = row.Level
				R.BuyRebirthUpgrade:FireServer(row.Id)
				task.wait(1)
				local after
				for _, r2 in ipairs(S().RebirthShop or {}) do
					if r2.Id == row.Id then
						after = r2.Level
					end
				end
				log(("shop %s: level %s -> %s (cost %s, balance %s -> %s)"):format(row.Id, tostring(lvl), tostring(after), fmt(big(row.NextCost)), fmt(bal), fmt(big(S().RebirthBalance))))
			end
		end)
		task.wait(SPEND_EVERY)
	end
end

local function petter(alive)
	while alive() do
		pcall(function()
			if not inRaid() then
				local before = table.concat(S().ActivePets or {}, ",")
				R.EquipBestPets:FireServer()
				task.wait(2)
				first("pets equip best", before, "->", table.concat(S().ActivePets or {}, ","))
			end
		end)
		task.wait(PETS_EVERY)
	end
end

-- raid: join the Rift inside its window. What a join does to the character is logged, not assumed.
local joinedInterval = nil
local function raider(alive)
	while alive() do
		local nap = RAID_POLL
		pcall(function()
			if not RiftReq then
				first("no RiftNetwork.Request")
				return
			end
			local res = callTimed(RiftReq, 5, "Snapshot", {})
			local sch = res and res.data and res.data.Schedule
			local cur = sch and sch.current
			local raid = res and res.data and res.data.Raid
			if raid and raid.active == true then
				raidBusy = true
			elseif raidBusy and raid and raid.active == false then
				raidBusy = false
				log("raid over")
			end
			if not (sch and sch.enabled and cur) then
				return
			end
			local now = workspace:GetServerTimeNow()
			if now < cur.joinOpensAt - 5 then
				nap = math.min(RAID_POLL, math.max(3, cur.joinOpensAt - now - 4))
				return
			end
			if now >= cur.joinOpensAt and now < cur.joinClosesAt then
				nap = 3
				if joinedInterval ~= cur.intervalId and sch.eligibility ~= "Locked" then
					joinedInterval = cur.intervalId
					step("raid / join " .. tostring(cur.bossName))
					raidBusy = true -- before the call: the director must stop hopping the moment the server moves us
					local rep = callTimed(RiftReq, 8, "RiftJoin", { intervalId = cur.intervalId })
					if not (type(rep) == "table" and rep.ok == true) then
						raidBusy = false
					end
					local okj, enc = pcall(function()
						return game:GetService("HttpService"):JSONEncode(rep)
					end)
					log("RiftJoin", cur.bossName, "eligibility", tostring(sch.eligibility), "reply", okj and enc or tostring(rep))
				end
			end
		end)
		task.wait(nap)
	end
end

-- toggles --------------------------------------------------------------------
local function switch(body)
	local on, gen = false, 0
	return function(state)
		on = state
		gen += 1
		local mine = gen
		if state then
			task.spawn(function()
				local ok, err = pcall(body, function()
					return on and gen == mine
				end)
				if not ok then
					warn("[swordwave] loop ended:", err)
				end
			end)
		end
	end
end

local setFarm, setTrain, setSpend, setPets, setRaid
setFarm = switch(function(alive)
	farmOn = true
	director(alive)
	farmOn = false
end)
setTrain = switch(trainer)
setSpend = switch(spender)
setPets = switch(petter)
setRaid = switch(raider)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Swordwave Legend", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "swords")
local Farm = Tab:AddLeftGroupbox("Farm", "swords")
local Grow = Tab:AddRightGroupbox("Grow", "trending-up")
local Extra = Tab:AddRightGroupbox("Extras", "paw-print")

Farm:AddToggle("Farm", {
	Text = "Auto Farm (Wins laps)",
	Tooltip = "Hops out of the hub and through the stage road, one stage at a time as deep as it still pays, then back to the hub. Stage pay grows about 4x per stage",
	Default = false,
	Callback = function(state)
		setFarm(state)
		if not state then
			say("farm off")
		end
	end,
})
local waveToggle
local weArmed = false -- we flipped it on, so we flip it back; an arm the player made stays
waveToggle = Farm:AddToggle("Wavedash", {
	Text = "Use WaveDash",
	Tooltip = "Needs the WaveDash upgrade (17.5K rebirth balance, bought in the Rebirth shop). Armed, leaving the hub clears every stage you can one-shot in about 3 seconds and pays them all; the lap then carries on from the next stage with hops. Off = plain hop laps",
	Default = false,
	Callback = function(state)
		if not R.SetWavestepArmed then
			return
		end
		if state then
			if not (S().Entitlements and S().Entitlements.Wavestep) then
				say("WaveDash is not owned: buy it in the Rebirth shop first")
				pcall(function()
					waveToggle:SetValue(false)
				end)
				return
			end
			if not S().WavestepArmed then
				R.SetWavestepArmed:FireServer(true)
				weArmed = true
				first("wavestep armed by us")
			end
		elseif weArmed then
			weArmed = false
			R.SetWavestepArmed:FireServer(false)
		end
	end,
})
Farm:AddToggle("Train", {
	Text = "Auto Train (Power clicks)",
	Tooltip = "TrainClick about 9 times a second, which is what the server credits at most. Works anywhere, no stand needed",
	Default = false,
	Callback = function(state)
		setTrain(state)
	end,
})
Farm:AddToggle("Weapon", {
	Text = "Auto Equip Best Weapon",
	Tooltip = "At the start of each lap, hops onto the pad of the highest weapon you have unlocked (weapons unlock on Wins by themselves)",
	Default = false,
	Callback = function(state)
		equipOn = state
	end,
})
Farm:AddInput("MaxStage", {
	Text = "Deepest stage to aim for",
	Tooltip = "Laps never go past this. The script also stops on its own at the first stage that does not pay or costs too much health",
	Default = tostring(MAX_STAGE),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		maxStage = math.clamp(math.floor(tonumber(text) or MAX_STAGE), 1, 220)
	end,
})
Farm:AddButton({
	Text = "Back to hub",
	Func = function()
		task.spawn(function()
			pcall(toHub)
		end)
	end,
})

Grow:AddToggle("Rebirth", {
	Text = "Auto Rebirth",
	Tooltip = "Rebirths when the click-power multiplier it buys is at least the number below. Resets Power, Wins, weapons and stage progress; keeps rebirth balance. A lap or three puts the weapons back",
	Default = false,
	Callback = function(state)
		rebirthOn = state
	end,
})
Grow:AddInput("RebirthGain", {
	Text = "Rebirth when it multiplies by",
	Tooltip = "1 + 0.1 x (balance + pending), against 1 + 0.1 x balance. 3 = rebirth once it triples click power. Raise to rebirth less often",
	Default = tostring(REBIRTH_GAIN),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		REBIRTH_GAIN = math.max(1.05, tonumber(text) or REBIRTH_GAIN)
	end,
})
Grow:AddToggle("Upgrade", {
	Text = "Auto Upgrade (Dojo + shop)",
	Tooltip = "Dojo whenever it is available. Shop rows only when the cost is a small share of your rebirth balance, since the balance is also your rebirth multiplier. Robux rows are never bought",
	Default = false,
	Callback = function(state)
		setSpend(state)
	end,
})
local line = Grow:AddLabel("-", true)

Extra:AddToggle("Pets", {
	Text = "Auto Equip Best Pets",
	Tooltip = "EquipBestPets once a minute (the game blocks it during a raid)",
	Default = false,
	Callback = function(state)
		setPets(state)
	end,
})
Extra:AddToggle("Raid", {
	Text = "Auto Join Rift Raid",
	Tooltip = "Joins the Rift boss inside its join window (one every 20 minutes, the window opens 60s before the fight). Laps pause while a raid is on",
	Default = false,
	Callback = function(state)
		setRaid(state)
		if not state then
			raidBusy = false
		end
	end,
})

local conns = {}
local note = "idle"
local nextStrip = 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	if pending.now then
		note, pending.now = pending.now, nil
	end
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	local s = S()
	pcall(Window.SetStatus, Window, {
		{ "Wins", fmt(big(s.Wins)) },
		{ "Power", fmt(big(s.Power)) },
		{ "Click", fmt(big(s.PowerPerClick)) },
		{ "Rebirths", fmt(big(s.RebirthBalance)) .. (big(s.PendingRebirths) >= 1 and (" +" .. fmt(big(s.PendingRebirths))) or "") },
		{ "Depth", stats.last .. "/" .. stats.deepest .. (blocked and (" (stuck at " .. blocked .. ")") or "") },
		{ "Laps", stats.laps },
		{ "Now", note },
	})
	pcall(function()
		local _, g = rebirthDue()
		line:SetText(("Pending %s, rebirth now would be x%.1f. Weapon %s of %s unlocked."):format(fmt(big(s.PendingRebirths)), g, tostring(s.EquippedWeapon), tostring(topWeapon())))
	end)
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("SwordwaveLegend", {})

table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- watchdog: a parked director cannot report itself
local closed = false
task.spawn(function()
	while not closed do
		task.wait(5)
		if farmOn and os.clock() - markAt > STUCK_AFTER and mark ~= "director / raid" then
			warn(("[swordwave] stuck %.0fs at: %s"):format(os.clock() - markAt, mark))
			markAt = os.clock()
		end
	end
end)

-- close ----------------------------------------------------------------------
local function stopAll()
	if weArmed and R.SetWavestepArmed then
		weArmed = false
		pcall(function()
			R.SetWavestepArmed:FireServer(false) -- server state outlives the panel
		end)
	end
	setFarm(false)
	setTrain(false)
	setSpend(false)
	setPets(false)
	setRaid(false)
	farmOn, rebirthOn, equipOn, raidBusy = false, false, false, false
	closed = true
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().swordwaveLegendStop = nil
end)

getgenv().swordwaveLegendStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().swordwaveLegendStop = nil
end
