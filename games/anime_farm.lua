--[[ Anime Farm -- sell crates, level units, roll + buy + place + open boxes, upgrades, grades, rewards (81833593897486)
     PlaceVersion 15. Only Grade and Trait move the character (v15 made both rolls need you at the stand); every
     other remote below was accepted from 55-74 studs away (the plot is ~120 studs across).

     SELL    : PickupCrateBox(CollectPart) takes every pending ball as one crate Tool (889 balls = 27.3M in one go),
               then SellCrate(crate InventoryKey) pays it out, 0.1s later, from 55 studs off the sell NPC.
     LEVEL UP: RequestPlayerUnitLevelUp(dropper part). The cheapest payback first across every placed unit and
               every income upgrade, one spender, so two loops never fight over the cash. Payback of a level is
               cost / (0.12 x drop / 4s) and grows x1.205 a level, so low levels go first. Up to MaxPlayerUnitLevel 50.
               Same-frame bursts are dropped (5 sent, 1 taken); 0.25s apart all took.
     BOXES   : NewRequestConveyorRoll is free and re-rolls the belt every ~1s (RollCooldownUntil), replacing the
               box on it. Only a box whose expected level-1 drop (box's unit chances x variant multiplier) beats
               the weakest placed unit's CURRENT drop (levels included) by BOX_MARGIN is bought, so the plot never
               gets weaker (ranking by base drop instead swapped levelled units for Guild/Pirate boxes in the first
               live run): PurchaseConveyorRoll(box, variant,
               price). It is placed on a free slot (the weakest unit is removed to the backpack when there is none)
               with PlaceBoxOnDropper(part, box, variant), and OpenBoxOnDropper(part) (InvokeServer -> unit name,
               variant) the moment BoxService.IsBoxReady says so. The unit lands on that dropper.
     EQUIP   : RemovePlayerUnitFromDropper(part) + PlacePlayerUnitOnDropper(part, guid), our own rule. A free slot
               gets the best backpack unit at equal level (L1 drop); a full plot swaps the weakest placed unit
               (drop now) for it when its L1 drop is higher (strict, so no ping-pong) and judge() says the levelling
               pays back. NOT the game's EquipBestPlayerUnits: that ranks by drop now, so a fresh L1 Unbound GRYuno
               (1.57M, 20x at equal level) stayed in the backpack behind a L36 NIKakashi (4.04M), and it would put
               Kakashi straight back over Yuno after our swap. Live: Kakashi-over-Yuno swapped back in 2s, stayed.
               Droppers carry no guid and the data no dropper: unplace() reads which guid turned unequipped.
     UPGRADES: PurchaseUpgrade(name) from anywhere. Crate Cash and Base Expansion are ranked by payback with the
               level-ups; Conveyor Luck / Open Time / Luck have no income formula, so they count as +X% income
               (OTHER_VALUE). Walk Speed is never bought: nothing here walks.
     COMPARE : a unit's every stat is its level-1 drop (unit base x variant x grade x trait); damage and tower
               health follow it and every level scales all units by the same 1.12, so units compare exactly at
               an equal level. judge() weighs a box (or unit) against what it would push out at THAT unit's
               level and at L50, and counts price + levelling the new one up + the slot's income lost while the
               box opens. Verdict Replace / Keep current / Invest in both (empty slot). The buy and place rule
               ("Pays back", default) uses it; "Beats now" is the simpler L1-beats-current rule. The panel shows
               the belt's verdict; Print side-by-side (or getgenv().animeFarmCompare()) prints every unit.
     GRADE   : NewRerollPlayerUnitGrade(guid, useToken, currentGrade). A roll REPLACES the grade (D -> F seen),
               so it rolls the best placed unit only until it reaches the target, then moves to the next one.
               Pays with tokens (BestOf 2), cash (~10 x level-1 drop scaled by level, 993K at L21; capped at a %
               of cash per roll) or tokens then cash.
               v15 gate (client GUI and server): the unit must be OFF the plot and you within GradeService.
               ROLL_RANGE 25 of the GradingHitbox part (Workspace.Systems.Interactables.Grading, ~105 studs from the
               plot), unless you own Bluetooth (Mad Scientist craft: 10 BluetoothPotion + 100 of each token +
               Cursed + 5 Transcendent; or a BluetoothPotion). Refused silently, nothing spent. So a TRIP: unplace,
               hop there, roll up to ROLL_BATCH, hop back, place on the same dropper (the slot is held meanwhile).
               Live: DEAki F -> A in 10 token rolls, ~3.5s of travel a trip, unit back on its dropper.
     TRAIT   : RerollPlayerUnitTrait(guid, currentTrait), Trait tokens only, same stop-at-target rule, same v15
               gate and trip at the TraitsHitbox (~145 studs). Live: MAHimmel FortuneI -> FortuneIII in 16.
               A roll replaces, so running out of tokens mid-chase can leave a unit worse than it started.
     TOWER   : StartInfinityTowerBattle(tower, 4 guids) + SetInfinityTowerAutoBattle(tower, true); the server's
               Auto restarts each run. Units keep producing while they fight. Floors roll Trait/Grade tokens,
               cash, potions. The next tower needs floor 250 (locked start returns nil).
     WALLET  : one lock around every cash spend; without it a box bought between a level-up's check and the
               server got the level-up refused.
     REWARDS : ClaimAllIndexRewards (+2 grade tokens seen), ClaimPlaytimeReward(i) for each Claimable one,
               ClaimDailyReward, ClaimOfflineEarnings.
     ANTI-AFK: the game's AntiAfk fires RejoinRemote after 900s without InputBegan/Ended and teleports you to a
               reserved server (that is what ended the first bridge session). An F15 key event every 60s resets it
               (same kit and fix as blue_lock_farm.lua).

     Probed and dead (do not re-probe):
       PurchaseConveyorRoll at price 1        refused, the server charges the real price
       PurchaseConveyorRoll for a box not on the belt   refused (both at 1 and at the real price)
       PlaceBoxOnDropper keeping the box      no: the count drops by one like it should
       buy -> level -> sell to the merchant   unit sells for 20 drops, box for 35%: only Slayer/Pirate net a
                                              profit and the best case is ~290K per 41s slot, << the farm
       StartInfinityTowerBattle on a locked tower   returns nil (Pirate Island with Distant Castle best 214)
       Grade / trait roll on a placed unit, or from the plot   refused silently since v15 (see GRADE)
       ClaimPlaytimeReward(4) / (5) while Claimable   nothing happens (2026-11-15, v15 tiered rewards; the game's
                                              own button sends the same call); 1-3 claimed fine. Unresolved
     Movement (Z.moves 2026-11-14): hops kept to 40 studs, 80 reverted; glide pulled back at 30 studs/s. One 40
       hop undone 2026-11-15, so travel() drops to 60% per revert and walks the rest.
     Live test 2026-11-14: every toggle on, 4 min: 0 refusals, 38 crates, income 1.12M/s -> 2.87M/s; started
       once with an emptied slot (Equip Best refilled it, junk boxes stayed held).
     Live test 2026-11-15 (v15): every toggle on, 3 min, started with a slot emptied by hand: 0 WARN, slot refilled
       in 2s, 25 crates, grade and trait trips until both token pools ran out, every unit back on the plot.
     Not wired (Robux): SkipBoxOnDropper / Skip All (dev products SkipTimers / SkipAllTimers), AutoConveyor pass,
       BoxPurchaseProductId. Not wired (out of reach / unprobed): Crate Polisher (1.5e14 + 11 expansions),
       obby bonus, collectables, item rain, potions (UseItem), variant tokens, codes.
     The PS.Client.Controllers / JJK half of the decompile is a sibling game's kit (its Net remote does not exist
     here); everything above is ReplicatedStorage.Client.Core.

     RightControl opens / closes the panel. Stop: getgenv().animeFarmStop() ]]

-- config ---------------------------------------------------------------------
local SELL_EVERY = 6 -- between crate pickups. One crate holds every pending ball, so this is only how stale the cash is
local SELL_WAIT = 2 -- the crate Tool must show up inside this after PickupCrateBox
local SPEND_GAP = 0.3 -- between purchases. 0.25 apart all took; same-frame bursts are dropped
local SPEND_IDLE = 1 -- when nothing is worth buying, look again after this
local MAX_PAYBACK = 3600 -- seconds. A level-up or upgrade that takes longer to pay for itself waits (raise to spend harder)
local OTHER_VALUE = { ConveyorLuck = 0.15, OpenTimeBoost = 0.05, Luck = 0.05 } -- treated as +this share of income
local BACKOFF = 10 -- a purchase the server did not take is not retried for this long
local CONFIRM = 1.5 -- a purchase must show in the data inside this
local ROLL_SPARE = 0.05 -- added to RollCooldownUntil before the next roll
local BOX_MARGIN = 1.25 -- a box's expected L1 drop must beat the weakest placed unit's current drop by this factor (raise to buy fewer, better boxes)
local BOX_SHARE_DEFAULT = 50 -- % of cash one box may cost
local BOX_INV_CAP = 95 -- stop buying at this many boxes held (the game's cap is 100)
local OPEN_WAIT = 6 -- OpenBoxOnDropper is an InvokeServer; give up on it after this
local EQUIP_GAP = 3.2 -- between two unit swaps, so the level loop and the box loop see each one land
local GRADE_GAP = 0.8 -- fallback roll gap; the real one is GradeService.GetRerollCooldown (0.75s, x0.75 with a token)
local HOP_MAX = 40 -- studs per hop (Z.moves 2026-11-14: 40 held, 80 reverted); a revert drops it to 60% and walks the rest
local HOP_GAP = 0.35 -- after a hop the position must still be there; a pull-back shows inside this
local WALK_TIMEOUT = 40 -- a walk (after a hop was undone) gives up after this
local STAND_IN = 8 -- studs from the station's hitbox to stop at; the server allows GradeService.ROLL_RANGE (25)
local ARRIVE_SETTLE = 0.5 -- after arriving, before the first roll: the server has to see you there
local ROLL_BATCH = 30 -- rolls per trip before going home to put the unit back (bounds how long its slot sits empty)
local ROLL_DUD = 4 -- this many rolls in a row that spend nothing = the server is refusing; go home
local GRADE_SHARE = 10 -- % of cash one cash grade roll may cost
local CLAIM_EVERY = 20
local AFK_BEAT = 60 -- an F15 key event this often resets the game's 900s AntiAfk rejoin
local WATCHDOG = 90 -- a loop whose breadcrumb has not moved this long is logged as stuck

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().animeFarmStop then
	getgenv().animeFarmStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[animefarm]", ...)
end

-- The strip is drained from a Heartbeat: a resumed loop thread that writes to the window throws
-- "lacking capability Plugin" after its first task.wait.
local pending, lastSaid = {}, {}
local function say(slot, msg, quiet)
	pending[slot] = msg
	if not quiet and msg ~= lastSaid[slot] then
		lastSaid[slot] = msg
		log(slot .. ": " .. msg)
	end
end

-- game -----------------------------------------------------------------------
local RS = ReplicatedStorage
local Remotes = RS:WaitForChild("Remotes", 15)
local ok, CDM, BS, PUS, US, UL, BL, VS, GL, PRS, PRL = pcall(function()
	return require(RS.Client.Data.ClientDataManager),
		require(RS.Shared.Services.BoxService),
		require(RS.Shared.Services.PlayerUnitService),
		require(RS.Shared.Services.UpgradesService),
		require(RS.Shared.Core.Storage.Game.UpgradesLibrary),
		require(RS.Shared.Core.Storage.Game.BoxesLibrary),
		require(RS.Shared.Services.VariantService),
		require(RS.Shared.Core.Storage.Game.GradesLibrary),
		require(RS.Shared.Services.PlaytimeRewardsService),
		require(RS.Shared.Core.Storage.Game.PlaytimeRewardsLibrary)
end)
if not Remotes or not ok then
	warn("[animefarm] the game's modules did not load:", CDM)
	return
end
local function R(name)
	return Remotes:WaitForChild(name, 10)
end
local MAX_LEVEL = require(RS.Shared.Constants).MaxPlayerUnitLevel or 50

local function data()
	return CDM.GetData()
end
local function cash()
	local d = data()
	return d and d.Currency and d.Currency.Cash or 0
end

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function fmt(n)
	local i = 1
	while n >= 1000 and i < #SUFFIX do
		n /= 1000
		i += 1
	end
	return ("%.3g"):format(n) .. SUFFIX[i]
end
assert(fmt(25000) == "25K" and fmt(1500) == "1.5K" and fmt(100) == "100", "fmt")

local function ticked(values)
	local set = {}
	for k, v in pairs(values) do
		if type(v) == "string" then
			set[v] = true
		elseif v then
			set[k] = true
		end
	end
	return set
end
assert(ticked({ "a" }).a and ticked({ b = true }).b and not ticked({ c = false }).c, "ticked")

-- world ----------------------------------------------------------------------
local CollectionService = game:GetService("CollectionService")

local function root()
	local c = player.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	if not (h and h.Health > 0) then
		return nil
	end
	return c:FindFirstChild("HumanoidRootPart"), h
end
local function flat(a, b)
	return Vector2.new(a.X - b.X, a.Z - b.Z).Magnitude
end

-- Hops of hopMax studs, each judged, then Humanoid:MoveTo re-issued every second. No whole-distance jump (80
-- reverted, every trip here is 100+) and no glide (pulled back at 30 studs/s, slower than a hop chain).
local hopMax = HOP_MAX
local function travel(pos, tol)
	local r = root()
	if not r then
		return false
	end
	local start = r.Position
	local n = math.ceil(flat(start, pos) / hopMax)
	for i = 1, n do
		r = root()
		if not r then
			return false
		end
		local p = start:Lerp(pos, i / n) + Vector3.new(0, 3, 0)
		r.CFrame = CFrame.new(p) * r.CFrame.Rotation
		r.AssemblyLinearVelocity = Vector3.zero
		task.wait(HOP_GAP)
		r = root()
		if not r then
			return false
		end
		if flat(r.Position, p) > 10 then
			hopMax = math.max(15, math.floor(hopMax * 0.6))
			log(("a %d-stud hop was undone; hops are %d studs now, walking the rest"):format(math.floor(flat(start, pos) / n), hopMax))
			break
		end
	end
	local t0 = os.clock()
	while true do
		local r2, h = root()
		if not r2 then
			return false
		end
		if flat(r2.Position, pos) <= tol then
			return true
		end
		if os.clock() - t0 > WALK_TIMEOUT then
			return false
		end
		h:MoveTo(pos)
		task.wait(1)
	end
end

-- guid -> dropper of a unit off its slot on a roll trip: the slot is held for it, so neither the box loop nor
-- the equip pass fills it while it is away
local away = {}
local function isHeld(d)
	for _, p in pairs(away) do
		if p == d then
			return true
		end
	end
	return false
end

local function plot()
	local pm = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("PlotModels")
	local p = pm and pm:FindFirstChild(player.Name)
	return p and p:FindFirstChild("Systems")
end

-- every dropper part of your plot, unlocked ones only
local function droppers()
	local out = {}
	local s = plot()
	local conv = s and s:FindFirstChild("TycoonConveyor") and s.TycoonConveyor:FindFirstChild("Conveyors")
	if not conv then
		return out
	end
	for _, c in ipairs(conv:GetChildren()) do
		local f = c:FindFirstChild("Droppers")
		for _, d in ipairs(f and f:GetChildren() or {}) do
			if d:IsA("BasePart") and d:GetAttribute("Unlocked") then
				out[#out + 1] = d
			end
		end
	end
	return out
end

local function unitOf(d, level)
	return {
		PlayerUnitName = d:GetAttribute("PlayerUnitName"),
		PlayerUnitVariant = d:GetAttribute("PlayerUnitVariant"),
		PlayerUnitLevel = level or d:GetAttribute("PlayerUnitLevel") or 1,
		PlayerUnitGrade = d:GetAttribute("PlayerUnitGrade"),
		PlayerUnitTrait = d:GetAttribute("PlayerUnitTrait"),
	}
end
local function dropOf(d, level)
	return PUS.GetPlayerUnitCashPerDrop(player, unitOf(d, level))
end

-- expected level-1 drop of a box, from its units' chances
local BOX_EV = {}
for name, b in pairs(BL) do
	if type(b) == "table" and b.BoxPrice and type(b.PlayerUnits) == "table" then
		local sum, w = 0, 0
		for _, u in pairs(b.PlayerUnits) do
			if type(u) == "table" then
				sum += (u.CashPerDrop or 0) * (u.Chance or 0)
				w += u.Chance or 0
			end
		end
		BOX_EV[name] = w > 0 and sum / w or 0
	end
end
assert(BOX_EV.Pirate and math.abs(BOX_EV.Pirate - 92.5) < 0.01, "Pirate EV is 92.5 (60x45 + 90x30 + 130x15 + 190x10)")
local function boxValue(name, variant)
	return (BOX_EV[name] or 0) * VS.GetMultiplier(variant or "Normal")
end

-- slots: free unlocked droppers, and the placed unit with the lowest drop as it is NOW (levels included).
-- A box is bought only when its level-1 expected drop beats that: the plot never gets weaker. Ranking by
-- level-1 drop instead (base value) swapped out levelled units for cheap Guild/Pirate boxes in the first run.
local function slotState()
	local free, weakest, weakVal, boxes, units = nil, nil, math.huge, 0, 0
	for _, d in ipairs(droppers()) do
		local t = d:GetAttribute("Type")
		if t == nil then
			if not isHeld(d) then
				free = free or d
			end
		elseif t == "Box" then
			boxes += 1
		elseif t == "PlayerUnit" then
			units += 1
			local v = dropOf(d)
			if v < weakVal then
				weakest, weakVal = d, v
			end
		end
	end
	return free, weakest, weakest and weakVal or 0, boxes, units
end

-- farm -----------------------------------------------------------------------
local stats = { sold = 0, soldBalls = 0, levels = 0, upgrades = 0, rolls = 0, bought = 0, placed = 0, opened = 0, graded = 0 }
local beat = {} -- loop -> { at = os.clock(), step = "..." }
local function step(loop, what)
	beat[loop] = { at = os.clock(), step = what }
end

local function waitFor(pred, secs)
	local t0 = os.clock()
	repeat
		if pred() then
			return true
		end
		task.wait(0.1)
	until os.clock() - t0 > secs
	return pred() and true or false
end

-- One wallet for every loop that spends cash (levels, upgrades, boxes, cash grade rolls). Without it a box bought
-- between a level-up's cash check and the server handling it got the level-up refused (cost 80.1M, cash 63.4M
-- after). First come, first served: a plain busy flag let back-to-back cash grade rolls re-take it in the
-- same instant they freed it, and rolling and levelling sat starved behind them for 100s+.
local nextTicket, serving = 0, 0
local function withWallet(fn)
	local mine = nextTicket
	nextTicket += 1
	while serving ~= mine do
		task.wait(0.03)
	end
	local good, a = pcall(fn)
	serving += 1
	if not good then
		error(a, 0)
	end
	return a
end

-- one generation counter per loop: flipping a toggle off and on never leaves two threads running
local gen = {}
local function loop(name, body)
	gen[name] = (gen[name] or 0) + 1
	local mine = gen[name]
	task.spawn(function()
		while gen[name] == mine do
			step(name, "tick")
			local good, err = pcall(body, function()
				return gen[name] == mine
			end)
			if not good then
				warn("[animefarm] " .. name .. ": " .. tostring(err))
				task.wait(2)
			end
		end
		beat[name] = nil
	end)
end
local function stop(name)
	gen[name] = (gen[name] or 0) + 1
	beat[name] = nil
end

-- sell -----------------------------------------------------------------------
local function crateTool()
	for _, where in ipairs({ player.Character, player:FindFirstChild("Backpack") }) do
		for _, t in ipairs(where and where:GetChildren() or {}) do
			if t:IsA("Tool") and t:GetAttribute("InventoryType") == "Crate" then
				return t
			end
		end
	end
	return nil
end

local function sellBody(alive)
	local s = plot()
	local cp = s and s:FindFirstChild("TycoonConveyor") and s.TycoonConveyor:FindFirstChild("CollectPart")
	if cp and not crateTool() and (cp:GetAttribute("PendingBallCount") or 0) > 0 then
		step("sell", "pickup")
		R("PickupCrateBox"):FireServer(cp)
		waitFor(crateTool, SELL_WAIT)
	end
	local tool = crateTool()
	if tool then
		-- the crate Tool carries its own payout ("Cash" = "27.34M"); a cash diff is muddied by the spend loop
		local key, worth, balls = tool:GetAttribute("InventoryKey"), tostring(tool:GetAttribute("Cash") or "?"), tool:GetAttribute("BallCount") or 0
		step("sell", "sell " .. tostring(key))
		R("SellCrate"):FireServer(key)
		if waitFor(function()
			return tool.Parent == nil
		end, 3) then
			stats.sold += 1
			stats.soldBalls += balls
			say("sell", ("sold a crate of %d balls for %s"):format(balls, worth))
		else
			say("sell", "WARN crate not sold (" .. tostring(key) .. ")")
		end
	end
	local t0 = os.clock()
	while alive() and os.clock() - t0 < SELL_EVERY do
		task.wait(0.25)
	end
end

-- spend: level-ups + upgrades, cheapest payback first ------------------------
local spendLevels, spendUpgrades = false, false
local upgradeOn = { CrateCashBoost = true, PlayerUnitExpansion = true, ConveyorLuck = true, OpenTimeBoost = true, Luck = true }
local UPGRADE_LABELS = {
	{ "PlayerUnitExpansion", "Base Expansion (+1 slot)" },
	{ "CrateCashBoost", "Crate Cash Boost" },
	{ "ConveyorLuck", "Conveyor Luck (better boxes)" },
	{ "OpenTimeBoost", "Open Time Boost" },
	{ "Luck", "Luck Boost" },
}
local refused = {} -- key -> os.clock() until which it is skipped

local function amount(u, n)
	local good, v = pcall(u.GetAmount, n)
	return good and tonumber(v) or 0
end

local function candidates()
	local list = {}
	local cps = PUS.GetCashPerSecond(player)
	local _, _, weakVal = slotState()
	if spendLevels then
		for _, d in ipairs(droppers()) do
			local lvl = d:GetAttribute("PlayerUnitLevel")
			if d:GetAttribute("Type") == "PlayerUnit" and lvl and lvl < MAX_LEVEL then
				local cost = PUS.GetLevelUpgradeCost(player, unitOf(d), lvl + 1)
				local gain = (dropOf(d, lvl + 1) - dropOf(d)) / 4
				if cost and gain > 0 then
					list[#list + 1] = { key = "L:" .. d:GetFullName(), cost = cost, payback = cost / gain, part = d, level = lvl }
				end
			end
		end
	end
	if spendUpgrades then
		local up = data().Upgrades or {}
		for name in pairs(upgradeOn) do
			local u = UL[name]
			local n = US.GetTimesPurchased(player, name)
			if u and (not u.MaxPurchases or n < u.MaxPurchases) then
				local good, cost = pcall(u.GetPrice, n)
				if good and cost then
					local gain
					if name == "CrateCashBoost" then
						gain = cps * (amount(u, n + 1) - amount(u, n)) / (1 + amount(u, n))
					elseif name == "PlayerUnitExpansion" then
						gain = math.max(weakVal, 1) / 4 -- a new slot ends up holding about what the weakest one does
					else
						gain = cps * (OTHER_VALUE[name] or 0.02)
					end
					if gain > 0 then
						list[#list + 1] = { key = "U:" .. name, cost = cost, payback = cost / gain, upgrade = name, have = up[name] or n }
					end
				end
			end
		end
	end
	table.sort(list, function(a, b)
		return a.payback < b.payback
	end)
	return list
end

local function spendBody(alive)
	local now = os.clock()
	local pick
	for _, c in ipairs(candidates()) do
		if not (refused[c.key] and refused[c.key] > now) then
			pick = c
			break
		end
	end
	if not pick or pick.payback > MAX_PAYBACK then
		say("spend", pick and ("next: %s pays back in %ds (> %ds)"):format(pick.upgrade or ("level " .. (pick.level + 1)), math.floor(pick.payback), math.floor(MAX_PAYBACK)) or "nothing to buy")
		task.wait(SPEND_IDLE)
		return
	end
	if pick.cost > cash() then
		say("spend", ("saving %s for %s"):format(fmt(pick.cost), pick.upgrade or (pick.part:GetAttribute("PlayerUnitName") .. " L" .. pick.level + 1)))
		task.wait(SPEND_IDLE)
		return
	end
	step("spend", pick.key)
	local took = withWallet(function()
	if pick.cost > cash() then
		return "skip" -- another loop spent it while we waited for the wallet
	end
	local took
	if pick.part and (pick.part:GetAttribute("Type") ~= "PlayerUnit" or pick.part:GetAttribute("PlayerUnitLevel") ~= pick.level) then
		return "skip" -- the box loop swapped this slot since the list was made; rank again
	elseif pick.part then
		local before = cash()
		R("RequestPlayerUnitLevelUp"):FireServer(pick.part)
		-- the level attribute lands before the cash mirror does; ranking again on the stale cash got the next
		-- level-up refused (3 times in a 3-minute soak), so wait for both
		took = waitFor(function()
			return (pick.part:GetAttribute("PlayerUnitLevel") or 0) > pick.level
		end, CONFIRM)
		if took then
			stats.levels += 1
			waitFor(function()
				return cash() ~= before
			end, 1) -- the level attribute lands before the cash mirror; ranking on stale cash gets the next one refused
		else
			log(("level-up refused: %s L%d cost %s, cash %s, now %s L%s"):format(tostring(pick.part:GetAttribute("PlayerUnitName")), pick.level, fmt(pick.cost), fmt(cash()), tostring(pick.part:GetAttribute("Type")), tostring(pick.part:GetAttribute("PlayerUnitLevel"))))
		end
	else
		local n = US.GetTimesPurchased(player, pick.upgrade)
		R("PurchaseUpgrade"):FireServer(pick.upgrade)
		took = waitFor(function()
			return US.GetTimesPurchased(player, pick.upgrade) > n
		end, CONFIRM)
		if took then
			stats.upgrades += 1
			say("spend", ("bought %s (%s, pays back in %ds)"):format(pick.upgrade, fmt(pick.cost), math.floor(pick.payback)))
		end
	end
	return took
	end)
	if took == "skip" then
		return
	end
	if not took then
		refused[pick.key] = os.clock() + BACKOFF
		say("spend", "WARN not taken: " .. pick.key)
	end
	if alive() then
		task.wait(SPEND_GAP)
	end
end

local function setSpend()
	if spendLevels or spendUpgrades then
		if not beat.spend then
			loop("spend", spendBody)
		end
	else
		stop("spend")
	end
end

-- boxes: roll, buy, place, open ---------------------------------------------
local boxOn, variantOn = {}, {}
local boxShare = BOX_SHARE_DEFAULT
local buying, placing, opening, equipping = false, false, false, false

-- A unit's L1 drop at its grade and trait, and its drop now
local function unitBase(u)
	local q = {
		PlayerUnitName = u.PlayerUnitName,
		PlayerUnitVariant = u.Variant,
		PlayerUnitLevel = 1,
		PlayerUnitGrade = u.Grade,
		PlayerUnitTrait = u.Trait,
	}
	local base = PUS.GetPlayerUnitCashPerDrop(player, q)
	q.PlayerUnitLevel = u.Level or 1
	return base, PUS.GetPlayerUnitCashPerDrop(player, q)
end

-- The best backpack unit AT EQUAL LEVEL (its L1 drop, which is the ratio between two units at any level), with
-- its drop now. Ranking by the drop now kept a L36 Unbound NIKakashi (4.04M) over a fresh Unbound GRYuno (1.57M
-- at L1, 20x Kakashi at equal level) in the backpack (live, 2026-11-15).
local function bestSpare()
	local best, bb, bv, bu
	for guid, u in pairs(data().PlayerUnits or {}) do
		if not u.Equipped and not away[guid] then
			local base, now = unitBase(u)
			if not bb or base > bb then
				best, bb, bv, bu = guid, base, now, u
			end
		end
	end
	return best, bv or 0, bb or 0, bu
end

-- RemovePlayerUnitFromDropper(part) -> the guid that came off. The dropper carries no guid and the data no
-- dropper, so it is whichever placed unit turned unequipped.
local function unplace(d)
	local before = {}
	for guid, u in pairs(data().PlayerUnits or {}) do
		if u.Equipped then
			before[guid] = true
		end
	end
	R("RemovePlayerUnitFromDropper"):FireServer(d)
	local off
	waitFor(function()
		if d:GetAttribute("Type") ~= nil then
			return false
		end
		local units = data().PlayerUnits or {}
		for guid in pairs(before) do
			if not (units[guid] and units[guid].Equipped) then
				off = guid
				return true
			end
		end
		return false
	end, CONFIRM)
	return off
end

-- PlacePlayerUnitOnDropper(part, guid), probed 2026-11-15: puts that exact backpack unit on that dropper
local function place(d, guid)
	R("PlacePlayerUnitOnDropper"):FireServer(d, guid)
	return waitFor(function()
		local u = (data().PlayerUnits or {})[guid]
		return d:GetAttribute("Type") == "PlayerUnit" and u and u.Equipped and true or false
	end, CONFIRM)
end

-- boxes held, best value first: { name, variant, value }
local function heldBoxes()
	local out = {}
	for name, vars in pairs((data().Inventory or {}).Boxes or {}) do
		for variant, e in pairs(vars) do
			if (e.Amount or 0) > 0 and BOX_EV[name] then
				out[#out + 1] = { name = name, variant = variant, value = boxValue(name, variant) }
			end
		end
	end
	table.sort(out, function(a, b)
		return a.value > b.value
	end)
	return out
end

-- compare ----------------------------------------------------------------------
-- Every stat a unit has is one number: its level-1 drop = the box unit's CashPerDrop x variant x grade x trait
-- cash multiplier (PlayerUnitService.GetPlayerUnitCashPerDrop). Tower damage is that drop x the trait's damage
-- multiplier and tower health 8x it x the trait's health multiplier (GetInfinityTowerBattleState, probed). A
-- level multiplies all of it by the same 1.12, so two units compared at the SAME level differ by exactly the
-- ratio of their level-1 drops, at L1, L30 or L50 alike. No skills, equipment or synergies exist to weigh.
-- What differs is the price of getting there: a level costs drop(L-1) x sqrt(grade) x 0.25 x 1.2054^(L-2), so
-- levelling a fresh unit to L50 costs ~1.7 million of its own level-1 drops (catch-up to L30 ~14 thousand), and a
-- high grade levels cheaper per unit of income (cost grows with sqrt(grade), income with grade).
local LEVEL_STEP, COST_STEP = 1.12, 1.2053571428571428
local function gradeMult(g)
	return g and GL[g] and GL[g].Multiplier or 1
end
local function catchUp(base, grade, toLevel)
	local sum = 0
	for l = 2, toLevel do
		sum += base * LEVEL_STEP ^ (l - 2) * math.sqrt(gradeMult(grade)) * 0.25 * COST_STEP ^ (l - 2)
	end
	return sum
end
do -- catchUp must agree with the game's own price for one level
	local zoro = BL.Pirate.PlayerUnits.PIZoro
	local game7 = PUS.GetLevelUpgradeCost(player, { PlayerUnitName = "PIZoro", PlayerUnitVariant = "Normal" }, 7)
	local mine7 = catchUp(zoro.CashPerDrop, nil, 7) - catchUp(zoro.CashPerDrop, nil, 6)
	assert(game7 and math.abs(game7 - mine7) <= 1, "catchUp matches GetLevelUpgradeCost")
end

local buyRule = "Pays back" -- or "Beats now"
-- Weigh a new unit of level-1 drop `base` (a box's expected one, or a real unit) against what it would push out:
-- the weakest placed unit, or with a free slot the best backpack unit (Equip Best would put that there).
-- Returns verdict, a one-line reason, and the numbers for the side-by-side.
-- `fromLevel` is the new unit's level when it is a levelled backpack unit (a box's unit lands at 1).
local function judge(base, grade, price, openSecs, fromLevel)
	local free, weakest, weakVal = slotState()
	local inc, incLevel, incName
	if free then
		local spare, spareVal = bestSpare()
		if spare then
			local u = data().PlayerUnits[spare]
			inc, incLevel, incName = spareVal, u.Level or 1, u.PlayerUnitName .. " (backpack)"
		end
	elseif weakest then
		inc, incLevel, incName = weakVal, weakest:GetAttribute("PlayerUnitLevel") or 1, weakest:GetAttribute("PlayerUnitName")
	end
	local r = { base = base, price = price }
	if not inc then
		r.verdict, r.why = "Invest in both", "a slot is empty and nothing in the backpack would fill it"
		return r.verdict, r.why, r
	end
	r.incName, r.incLevel, r.incNow = incName, incLevel, inc
	r.incBase = inc / LEVEL_STEP ^ (incLevel - 1)
	fromLevel = fromLevel or 1
	local atLevel = math.max(incLevel, fromLevel)
	r.newAtLevel = base * LEVEL_STEP ^ (atLevel - 1)
	r.newAt50 = base * LEVEL_STEP ^ (MAX_LEVEL - 1)
	r.incAt50 = r.incBase * LEVEL_STEP ^ (MAX_LEVEL - 1)
	r.catchUp = catchUp(base, grade, atLevel) - catchUp(base, grade, fromLevel)
	r.lost = inc / 4 * (openSecs or 0) -- what the slot does not earn while the box opens
	local gain = (r.newAtLevel - inc) / 4
	r.payback = gain > 0 and (price + r.catchUp + r.lost) / gain or math.huge
	if buyRule == "Beats now" then
		if base > inc * BOX_MARGIN then
			r.verdict, r.why = "Replace", ("L1 %s beats %s's %s now"):format(fmt(base), incName, fmt(inc))
		else
			r.verdict, r.why = "Keep current", ("L1 %s is not %.2fx %s's %s"):format(fmt(base), BOX_MARGIN, incName, fmt(inc))
		end
	elseif r.newAtLevel <= inc * BOX_MARGIN then
		r.verdict, r.why = "Keep current", ("at L%d it would drop %s vs %s's %s"):format(incLevel, fmt(r.newAtLevel), incName, fmt(inc))
	elseif r.payback <= MAX_PAYBACK then
		r.verdict, r.why = "Replace", ("%.1fx %s at L%d; price + catch-up + open time paid back in %ds"):format(r.newAtLevel / inc, incName, incLevel, math.floor(r.payback))
	else
		r.verdict, r.why = "Keep current", ("%.1fx %s at equal level, but it pays back in %ds (> %ds)"):format(r.newAtLevel / inc, incName, math.floor(math.min(r.payback, 1e9)), math.floor(MAX_PAYBACK))
	end
	return r.verdict, r.why, r
end
local function openSecs(name, variant)
	local full = BS.GetBoxTimeToOpen(name, variant)
	local good, cut = pcall(BS.GetBoxTimerReduction, player, name, variant)
	return full - (good and cut or 0)
end

-- InvokeServer that cannot park the loop
local function invoke(remote, secs, ...)
	local args, done, res = table.pack(...), false, nil
	task.spawn(function()
		res = table.pack(pcall(remote.InvokeServer, remote, table.unpack(args, 1, args.n)))
		done = true
	end)
	waitFor(function()
		return done
	end, secs)
	if res and res[1] then
		return true, table.unpack(res, 2, res.n)
	end
	return false
end

local function openReady()
	for _, d in ipairs(droppers()) do
		if d:GetAttribute("Type") == "Box" then
			local name, at, variant = d:GetAttribute("BoxName"), d:GetAttribute("PlacedAt"), d:GetAttribute("Variant")
			if name and BS.IsBoxReady(name, at, variant) then
				step("box", "open " .. name)
				local _, got, gotVariant = invoke(R("OpenBoxOnDropper"), OPEN_WAIT, d)
				if got then
					stats.opened += 1
					say("box", ("opened %s %s -> %s %s"):format(variant, name, tostring(gotVariant), tostring(got)))
				else
					say("box", "WARN open refused: " .. name)
				end
			end
		end
	end
end

-- put the best held box that judge() says Replace / Invest in both for on a free slot (or the weakest unit's
-- slot). A held box is already paid for, so its price counts as 0.
local function placeBest()
	for _, b in ipairs(heldBoxes()) do
		local verdict = judge(b.value, nil, 0, openSecs(b.name, b.variant))
		if verdict == "Keep current" then
			return -- best first, so nothing after this one is worth a slot either
		end
		local free, weakest = slotState()
		local target = free
		if not target and weakest then
			step("box", "remove for " .. b.name)
			R("RemovePlayerUnitFromDropper"):FireServer(weakest)
			if waitFor(function()
				return weakest:GetAttribute("Type") == nil
			end, CONFIRM) then
				target = weakest
			end
		end
		if not target then
			return
		end
		step("box", "place " .. b.name)
		R("PlaceBoxOnDropper"):FireServer(target, b.name, b.variant)
		if waitFor(function()
			return target:GetAttribute("Type") == "Box"
		end, CONFIRM) then
			stats.placed += 1
			say("box", ("placed %s %s on %s"):format(b.variant, b.name, target.Parent.Parent.Name .. "/" .. target.Name))
		else
			say("box", "WARN place refused: " .. b.name)
			return
		end
	end
end

local function rollAndBuy()
	local s = plot()
	local belt = s and s:FindFirstChild("RollStation") and s.RollStation:FindFirstChild("ConveyorPart")
	if not belt or BS.GetTotalBoxInventoryAmount(player) >= BOX_INV_CAP then
		return
	end
	-- a held box worth a slot goes on first; no point rolling for another
	local held = heldBoxes()[1]
	if held and judge(held.value, nil, 0, openSecs(held.name, held.variant)) ~= "Keep current" then
		return
	end
	local untilT = belt:GetAttribute("RollCooldownUntil") or 0
	local left = untilT + ROLL_SPARE - workspace:GetServerTimeNow()
	if left > 0 then
		task.wait(math.min(left, 1.5))
	end
	local id = belt:GetAttribute("RollId")
	step("box", "roll")
	R("NewRequestConveyorRoll"):FireServer()
	if not waitFor(function()
		return belt:GetAttribute("RollId") ~= id
	end, 2) then
		return
	end
	stats.rolls += 1
	local name, variant = belt:GetAttribute("BoxName"), belt:GetAttribute("Variant")
	if not name or not boxOn[name] or not variantOn[variant] then
		return
	end
	local value, price = boxValue(name, variant), BS.GetConveyorBoxPrice(name, variant)
	local verdict, why = judge(value, nil, price, openSecs(name, variant))
	say("cmp", ("Belt: %s %s (L1 %s/drop, %s) -> %s: %s"):format(variant, name, fmt(value), fmt(price), verdict:upper(), why), true)
	if verdict == "Keep current" then
		say("buy", ("skip %s %s: %s"):format(variant, name, why), true)
		return
	end
	withWallet(function()
		if price > cash() * boxShare / 100 then
			say("buy", ("%s %s costs %s, over %d%% of cash"):format(variant, name, fmt(price), boxShare))
			return
		end
		local n = BS.GetTotalBoxInventoryAmount(player)
		step("box", "buy " .. name)
		R("PurchaseConveyorRoll"):FireServer(name, variant, price)
		if waitFor(function()
			return BS.GetTotalBoxInventoryAmount(player) > n
		end, CONFIRM) then
			stats.bought += 1
			say("buy", ("bought %s %s for %s (%s/drop at L1)"):format(variant, name, fmt(price), fmt(value)))
		else
			say("buy", "WARN buy refused: " .. variant .. " " .. name)
		end
	end)
end

-- Equip: one placement per pass, by our own rule, never the game's EquipBestPlayerUnits, which re-sorts every slot
-- by the drop NOW and would put a levelled weak unit straight back over a fresh strong one. A free slot gets the
-- best backpack unit at equal level. Full: that unit replaces the weakest placed one (lowest drop now) when it is
-- better at equal level (its L1 drop is higher: a strict order, so two units can never swap back and forth) AND
-- judge() says the levelling it needs pays back inside Max payback. The level loop then levels it first, since
-- a low level is the cheapest payback.
local lastSwap = -math.huge
local function equipPass()
	if os.clock() - lastSwap < EQUIP_GAP then
		return
	end
	local spare, _, base, u = bestSpare()
	if not spare then
		return
	end
	local free, weakest = slotState()
	local target, off, why = free, nil, "free slot"
	if not target then
		if not weakest or base <= dropOf(weakest, 1) then
			return
		end
		local verdict, reason = judge(base, u.Grade, 0, 0, u.Level or 1)
		if verdict ~= "Replace" then
			say("equip", ("keep %s over %s L%d: %s"):format(tostring(weakest:GetAttribute("PlayerUnitName")), u.PlayerUnitName, u.Level or 1, reason), true)
			return
		end
		lastSwap = os.clock()
		why = reason
		step("box", "swap out " .. tostring(weakest:GetAttribute("PlayerUnitName")))
		off = unplace(weakest)
		if not off then
			say("equip", "WARN remove refused: " .. tostring(weakest:GetAttribute("PlayerUnitName")))
			return
		end
		target = weakest
	end
	lastSwap = os.clock()
	step("box", "place " .. u.PlayerUnitName)
	if place(target, spare) then
		say("equip", ("placed %s %s L%d (%s)"):format(tostring(u.Variant), u.PlayerUnitName, u.Level or 1, why))
	else
		say("equip", "WARN place refused: " .. u.PlayerUnitName)
		if off then
			place(target, off) -- never leave the slot empty over a refused swap
		end
	end
end

local function boxBody(alive)
	if opening then
		openReady()
	end
	if placing and alive() then
		placeBest()
	end
	if equipping and alive() then
		equipPass()
	end
	if buying and alive() then
		rollAndBuy()
	else
		task.wait(0.5)
	end
end

local function setBox()
	if buying or placing or opening or equipping then
		if not beat.box then
			loop("box", boxBody)
		end
	else
		stop("box")
	end
end

-- grade ----------------------------------------------------------------------
local GRADE_ORDER = {}
for name, g in pairs(GL) do
	if type(g) == "table" and g.Multiplier then
		GRADE_ORDER[#GRADE_ORDER + 1] = name
	end
end
table.sort(GRADE_ORDER, function(a, b)
	return GL[a].Multiplier < GL[b].Multiplier
end)
local gradeTarget = "A"
local gradePay = "Tokens only" -- "Cash only" / "Tokens, then cash"
local gradeShare = GRADE_SHARE

-- roll trips -------------------------------------------------------------------
-- PlaceVersion 15 (2026-11-15) gates both rolls twice, in the client GUI and on the server alike: the unit must be
-- OFF the plot ("This unit is placed on your plot!") and you must stand within GradeService.ROLL_RANGE (25) of the
-- station's tagged hitbox (GradingHitbox / TraitsHitbox), unless you own Bluetooth (Mad Scientist craft, or a
-- BluetoothPotion). Both refusals are silent: no notification and nothing spent. Probed: placed unit at the
-- stand refused, backpack unit 105 studs off refused, backpack unit at the stand rolled (token 56 -> 55, F -> D).
-- So a trip takes the unit off its dropper (the slot is held for it), goes to the station, rolls a batch, comes
-- back and puts it on the same dropper. Grade and Trait both drive the character, so one trip at a time.
local GS = require(RS.Shared.Services.GradeService)
local TS = require(RS.Shared.Services.TraitService)
local moving = false

-- the dropper a unit sits on: the data has no dropper and the dropper no guid, so match what both carry. A twin
-- (same name, variant, level, grade, trait) is caught by unplace() handing back the other guid.
local function dropperOf(u)
	for _, d in ipairs(droppers()) do
		if
			d:GetAttribute("Type") == "PlayerUnit"
			and d:GetAttribute("PlayerUnitName") == u.PlayerUnitName
			and d:GetAttribute("PlayerUnitVariant") == u.Variant
			and (d:GetAttribute("PlayerUnitLevel") or 1) == (u.Level or 1)
			and d:GetAttribute("PlayerUnitGrade") == u.Grade
			and d:GetAttribute("PlayerUnitTrait") == u.Trait
		then
			return d
		end
	end
	return nil
end

-- spec = { slot, tag, spent() -> number that drops when a roll is paid, blocked(u) -> reason or nil, roll(guid, u) }
local function trip(spec, guid, alive)
	local u = (data().PlayerUnits or {})[guid]
	local d = u and u.Equipped and dropperOf(u)
	local st = CollectionService:GetTagged(spec.tag)[1]
	local r = root()
	if not (d and st and r) then
		say(spec.slot, ("WARN no %s"):format(not d and "dropper for " .. tostring(u and u.PlayerUnitName) or not st and spec.tag or "character"))
		task.wait(3)
		return
	end
	local home = r.Position
	moving, away[guid] = true, d
	step(spec.slot, "unplace " .. u.PlayerUnitName)
	local off = unplace(d)
	if off ~= guid then
		away[guid] = nil
		if off then
			place(d, off) -- the match took a twin; put it back
		end
		moving = false
		say(spec.slot, "WARN could not take " .. u.PlayerUnitName .. " off its slot")
		task.wait(3)
		return
	end
	local good, err = pcall(function()
		step(spec.slot, "travel")
		if not (GS.CanReachRollStation(player, spec.tag) or travel(st.Position, STAND_IN)) then
			say(spec.slot, "WARN could not reach the " .. spec.tag)
			return
		end
		task.wait(ARRIVE_SETTLE)
		local n, duds = 0, 0
		while alive() and n < ROLL_BATCH and duds < ROLL_DUD do
			local cur = data().PlayerUnits[guid]
			local why = cur and spec.blocked(cur)
			if not cur or why then
				say(spec.slot, why or "unit gone")
				return
			end
			local before = spec.spent()
			step(spec.slot, "roll " .. cur.PlayerUnitName)
			spec.roll(guid, cur)
			n += 1
			duds = waitFor(function()
				return spec.spent() < before
			end, 1) and 0 or duds + 1
		end
		if duds >= ROLL_DUD then
			say(spec.slot, ("WARN %d rolls in a row spent nothing: the server is refusing"):format(duds))
		end
	end)
	-- every path comes home and puts the unit back, a thrown error included
	step(spec.slot, "home")
	travel(home, 4)
	step(spec.slot, "place back")
	local back = place(d, guid)
	if not back then
		back = place(d, guid) -- one retry: the first can land while the walk home is still settling
	end
	if not back then
		say(spec.slot, "WARN could not put " .. u.PlayerUnitName .. " back (Auto Equip will)")
	end
	away[guid], moving = nil, false
	if not good then
		error(err, 0)
	end
end

local function rollGap(useToken)
	local good, cd = pcall(GS.GetRerollCooldown, player, useToken)
	return (good and tonumber(cd) or GRADE_GAP) + 0.05
end

local gradeSpec
gradeSpec = {
	slot = "grade",
	tag = GS.HITBOX_TAG or "GradingHitbox",
	spent = function()
		local d = data()
		return (d.Tokens and d.Tokens.Grade or 0) + (gradeSpec.cash and cash() or 0)
	end,
	blocked = function(u)
		if gradeMult(u.Grade) >= gradeMult(gradeTarget) then
			return ("%s reached %s"):format(u.PlayerUnitName, tostring(u.Grade))
		end
		local tokens = data().Tokens and data().Tokens.Grade or 0
		gradeSpec.cash = not (gradePay ~= "Cash only" and tokens > 0)
		if not gradeSpec.cash then
			return nil
		elseif gradePay == "Tokens only" then
			return "out of grade tokens"
		end
		local cost = PUS.GetGradeRerollCost(player, {
			PlayerUnitName = u.PlayerUnitName,
			PlayerUnitVariant = u.Variant,
			PlayerUnitLevel = u.Level,
			PlayerUnitTrait = u.Trait,
		})
		if cost > cash() * gradeShare / 100 then
			return ("a cash roll costs %s, over %d%% of cash"):format(fmt(cost), gradeShare)
		end
		return nil
	end,
	roll = function(guid, u)
		local before, useToken = u.Grade, not gradeSpec.cash
		if useToken then
			R("NewRerollPlayerUnitGrade"):FireServer(guid, true, before)
		else
			withWallet(function()
				R("NewRerollPlayerUnitGrade"):FireServer(guid, false, before)
				task.wait(0.3) -- long enough for the charge to land in the cash mirror; the cooldown waits outside the lock
			end)
		end
		task.wait(rollGap(useToken))
		local now = (data().PlayerUnits or {})[guid]
		stats.graded += 1
		say("grade", ("%s %s: %s -> %s (%s)"):format(tostring(u.Variant), u.PlayerUnitName, tostring(before or "F"), tostring(now and now.Grade or "F"), useToken and "token" or "cash"))
	end,
}

local function gradeBody(alive)
	if moving then
		task.wait(1)
		return
	end
	local d = data()
	local target = gradeMult(gradeTarget)
	-- placed units, best level-1 drop without their grade first
	local pick, pv, pu
	for guid, u in pairs(d.PlayerUnits or {}) do
		if u.Equipped and gradeMult(u.Grade) < target then
			local v = PUS.GetPlayerUnitCashPerDrop(player, {
				PlayerUnitName = u.PlayerUnitName,
				PlayerUnitVariant = u.Variant,
				PlayerUnitLevel = u.Level or 1,
				PlayerUnitTrait = u.Trait,
			})
			if not pv or v > pv then
				pick, pv, pu = guid, v, u
			end
		end
	end
	if not pick then
		say("grade", "every placed unit is at " .. gradeTarget .. " or better")
		task.wait(5)
		return
	end
	-- checked here as well as in the trip, so an unaffordable roll never costs a walk
	local why = gradeSpec.blocked(pu)
	if why then
		say("grade", ("%s is %s; %s"):format(pu.PlayerUnitName, tostring(pu.Grade or "F"), why))
		task.wait(3)
		return
	end
	trip(gradeSpec, pick, alive)
end

-- trait ----------------------------------------------------------------------
-- RerollPlayerUnitTrait(guid, currentTrait), one Trait token a roll (probed: token 5 -> 4, TraitPity +1). Like a
-- grade, a roll replaces the trait, so the best placed unit is rolled only until its cash multiplier reaches
-- the target. Trait tokens come from the Infinity Tower (5 from one 214-floor run). Same v15 gates as a grade
-- roll, at the Traits station: a trip (above).
local TL = require(RS.Shared.Core.Storage.Game.TraitsLibrary)
local function traitCash(t)
	return t and TL[t] and TL[t].CashMultiplier or 1
end
local TRAIT_ORDER = {}
for name, t in pairs(TL) do
	if type(t) == "table" and (t.CashMultiplier or 1) > 1 then
		TRAIT_ORDER[#TRAIT_ORDER + 1] = name
	end
end
table.sort(TRAIT_ORDER, function(a, b)
	return traitCash(a) < traitCash(b) or (traitCash(a) == traitCash(b) and a < b)
end)
local traitTarget = "FortuneIII"

local traitSpec = {
	slot = "trait",
	tag = TS.HITBOX_TAG or "TraitsHitbox",
	spent = function()
		return data().Tokens and data().Tokens.Trait or 0
	end,
	blocked = function(u)
		if traitCash(u.Trait) >= traitCash(traitTarget) then
			return ("%s reached %s"):format(u.PlayerUnitName, tostring(u.Trait))
		elseif (data().Tokens and data().Tokens.Trait or 0) < 1 then
			return "out of trait tokens (the tower drops them)"
		end
		return nil
	end,
	roll = function(guid, u)
		local before = u.Trait
		R("RerollPlayerUnitTrait"):FireServer(guid, before)
		local good, cd = pcall(TS.GetRerollCooldown, player)
		task.wait((good and tonumber(cd) or GRADE_GAP) + 0.05)
		local now = (data().PlayerUnits or {})[guid]
		say("trait", ("%s %s: %s -> %s"):format(tostring(u.Variant), u.PlayerUnitName, tostring(before or "none"), tostring(now and now.Trait or "none")))
	end,
}

local function traitBody(alive)
	if moving then
		task.wait(1)
		return
	end
	local d = data()
	local target = traitCash(traitTarget)
	local pick, pv
	for guid, u in pairs(d.PlayerUnits or {}) do
		if u.Equipped and traitCash(u.Trait) < target then
			local v = PUS.GetPlayerUnitCashPerDrop(player, {
				PlayerUnitName = u.PlayerUnitName,
				PlayerUnitVariant = u.Variant,
				PlayerUnitLevel = u.Level or 1,
				PlayerUnitGrade = u.Grade,
			})
			if not pv or v > pv then
				pick, pv = guid, v
			end
		end
	end
	local tokens = d.Tokens and d.Tokens.Trait or 0
	if not pick or tokens < 1 then
		say("trait", not pick and ("every placed unit has %s or better"):format(traitTarget) or "no trait tokens (the tower drops them)")
		task.wait(5)
		return
	end
	trip(traitSpec, pick, alive)
end

-- infinity tower ---------------------------------------------------------------
-- StartInfinityTowerBattle(tower, { up to 4 guids }) (InvokeServer) and SetInfinityTowerAutoBattle(tower, true):
-- the server's Auto restarts a run the moment one ends (seen: ended at floor 214, back at floor 13 seconds later),
-- so this only starts it, keeps Auto on, and swaps in a better team or the next tower between runs. Units in
-- the tower keep producing on their droppers (13 equipped before and during). Each floor rolls a reward (3%
-- Trait token, 6% cash, 0.6% Grade token, potions; InfinityTowerFloorsLibrary) and enemies pay
-- BaseEnemyCash x 1.056^floor. The next tower needs floor 250 in the previous one: StartInfinityTowerBattle
-- on a locked tower returns nil (probed, Pirate Island at a best of 214).
local TF = require(RS.Shared.Core.Storage.Game.InfinityTowerFloorsLibrary)
local ITS = require(RS.Shared.Services.InfinityTowerService)
local TOWER_EVERY = 10
local TOWER_SWAP_FLOOR = 3 -- a team or tower swap only happens while a run is below this floor (nothing to lose)
local towerAuto = nil -- the tower we switched Auto on for, so teardown can switch it off again

local function bestTower()
	local best
	for name, t in pairs(TF) do
		if type(t) == "table" and t.LayoutOrder and not ITS.GetPlayBlockReason(player, name) then
			if not best or t.LayoutOrder > TF[best].LayoutOrder then
				best = name
			end
		end
	end
	return best
end

local function bestTeam()
	local list = {}
	for guid in pairs(data().PlayerUnits or {}) do
		list[#list + 1] = { guid = guid, dmg = PUS.GetDamageBasis(player, guid) * PUS.GetHealthBasis(player, guid) }
	end
	table.sort(list, function(a, b)
		return a.dmg > b.dmg
	end)
	local team, set = {}, {}
	for i = 1, math.min(4, #list) do
		team[i], set[list[i].guid] = list[i].guid, true
	end
	return team, set
end

local function towerBody(alive)
	local tower = bestTower()
	local okState, st = invoke(R("GetInfinityTowerBattleState"), 8)
	if okState and type(st) == "table" and st.TowerName then
		local team, set = bestTeam()
		local same = true
		for _, u in ipairs(st.Units or {}) do
			same = same and set[u.Guid] == true
		end
		same = same and #(st.Units or {}) == #team
		if (st.Floor or 0) <= TOWER_SWAP_FLOOR and (st.TowerName ~= tower or not same) then
			step("tower", "exit to swap")
			R("ExitInfinityTowerBattle"):FireServer(st.TowerName)
			say("tower", st.TowerName ~= tower and ("moving up to %s"):format(tower) or "swapping in a stronger team")
			task.wait(2)
			return
		end
		if st.AutoBattle ~= true then
			R("SetInfinityTowerAutoBattle"):FireServer(st.TowerName, true)
			towerAuto = st.TowerName
		end
		local hi = ITS.GetHighestFloor(player, st.TowerName)
		say("tower", ("%s floor %d (best %d)"):format(TF[st.TowerName] and TF[st.TowerName].DisplayName or st.TowerName, st.Floor or 0, hi), true)
	elseif tower then
		local team = bestTeam()
		if #team == 0 then
			say("tower", "no units")
		else
			step("tower", "start " .. tower)
			local good, res = invoke(R("StartInfinityTowerBattle"), 8, tower, team)
			if good and res then
				R("SetInfinityTowerAutoBattle"):FireServer(tower, true)
				towerAuto = tower
				say("tower", ("started %s with %d units, Auto on"):format(tower, #team))
			else
				say("tower", "WARN start refused: " .. tower)
			end
		end
	end
	local t0 = os.clock()
	while alive() and os.clock() - t0 < TOWER_EVERY do
		task.wait(0.5)
	end
end

local function stopTower()
	stop("tower")
	if towerAuto then
		pcall(function()
			R("SetInfinityTowerAutoBattle"):FireServer(towerAuto, false) -- give the player's own setting back; the run ends by itself
		end)
		towerAuto = nil
	end
end

-- rewards --------------------------------------------------------------------
local claimedOffline = false
local function claimBody(alive)
	step("claim", "index")
	R("ClaimAllIndexRewards"):FireServer()
	for _, r in ipairs(PRL.Rewards or {}) do
		local good, st = pcall(PRS.GetRewardState, player, r.Index)
		if good and st == "Claimable" then
			step("claim", "playtime " .. r.Index)
			R("ClaimPlaytimeReward"):FireServer(r.Index)
			say("claim", "playtime reward " .. r.Index)
			task.wait(0.5)
		end
	end
	R("ClaimDailyReward"):FireServer()
	if not claimedOffline then
		claimedOffline = true
		R("ClaimOfflineEarnings"):FireServer()
	end
	local t0 = os.clock()
	while alive() and os.clock() - t0 < CLAIM_EVERY do
		task.wait(0.5)
	end
end

-- anti-afk -------------------------------------------------------------------
local NUDGE_KEY = Enum.KeyCode.F15
local afkConns = {}
local lastInput = os.clock()
local function setAfk(on)
	for _, c in ipairs(afkConns) do
		pcall(c.Disconnect, c)
	end
	table.clear(afkConns)
	stop("afk")
	if not on then
		return
	end
	table.insert(afkConns, game:GetService("UserInputService").InputBegan:Connect(function(input)
		if input.KeyCode ~= NUDGE_KEY then
			lastInput = os.clock()
		end
	end))
	loop("afk", function(alive)
		local t0 = os.clock()
		while alive() and os.clock() - t0 < AFK_BEAT do
			task.wait(1)
		end
		if alive() and os.clock() - lastInput >= AFK_BEAT then
			pcall(function()
				local vim = game:GetService("VirtualInputManager")
				vim:SendKeyEvent(true, NUDGE_KEY, false, game)
				vim:SendKeyEvent(false, NUDGE_KEY, false, game)
			end)
		end
	end)
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Anime Farm", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "swords")
local Crates = Tab:AddLeftGroupbox("Crates", "package")
local Units = Tab:AddLeftGroupbox("Units", "users")
local Boxes = Tab:AddRightGroupbox("Boxes", "box")
local Upgrades = Tab:AddRightGroupbox("Upgrades", "trending-up")
local Misc = Tab:AddLeftGroupbox("Rewards", "gift")

Crates:AddToggle("Sell", {
	Text = "Auto Sell Crates",
	Tooltip = "Picks up the whole collector as one crate and sells it, every few seconds, from wherever you stand",
	Default = false,
	Callback = function(on)
		if on then
			loop("sell", sellBody)
		else
			stop("sell")
		end
	end,
})

Units:AddToggle("Level", {
	Text = "Auto Level Up",
	Tooltip = "Levels placed units, cheapest payback first (ranked together with Auto Upgrades), up to level 50",
	Default = false,
	Callback = function(on)
		spendLevels = on
		setSpend()
	end,
})
Units:AddToggle("Equip", {
	Text = "Auto Equip Best",
	Tooltip = "Fills a free slot with the best backpack unit, and swaps out the weakest placed unit for a backpack one that is better at equal level when levelling it pays back inside Max payback. Places units itself: the game's Equip Best ranks by income now and would put a levelled weak unit back",
	Default = false,
	Callback = function(on)
		equipping = on
		setBox()
	end,
})
Units:AddToggle("Grade", {
	Text = "Auto Grade",
	Tooltip = "Rerolls the best placed unit's grade until it reaches the target, then the next one. The game only rolls a unit off the plot, at the Grading stand: this takes it off, walks there, rolls up to 30, walks back and puts it back. MOVES YOUR CHARACTER",
	Default = false,
	Callback = function(on)
		if on then
			loop("grade", gradeBody)
		else
			stop("grade")
		end
	end,
})
Units:AddDropdown("GradeTarget", {
	Text = "Grade target",
	Tooltip = "Stop rolling a unit once it has this grade or better. A 2x, S 3x, SS 6.5x, X 8x, EX 10x, UR 14x",
	Values = GRADE_ORDER,
	Default = gradeTarget,
	Callback = function(v)
		gradeTarget = v
	end,
})
Units:AddDropdown("GradePay", {
	Text = "Grade pays with",
	Tooltip = "A token roll is best of 2 and costs nothing else. A cash roll is ~10x the unit's level-1 drop, scaled by level (993K at L21), capped by the % below",
	Values = { "Tokens only", "Cash only", "Tokens, then cash" },
	Default = gradePay,
	Callback = function(v)
		gradePay = v
	end,
})
Units:AddInput("GradeShare", {
	Text = "Max % of cash per cash grade roll",
	Default = tostring(GRADE_SHARE),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		gradeShare = math.clamp(tonumber(text) or GRADE_SHARE, 1, 100)
	end,
})

local boxNames = {}
for name in pairs(BOX_EV) do
	boxNames[#boxNames + 1] = name
end
table.sort(boxNames, function(a, b)
	return BL[a].BoxPrice < BL[b].BoxPrice
end)
local boxLabels, boxByLabel = {}, {}
for _, name in ipairs(boxNames) do
	local label = ("%s (%s)"):format(BL[name].DisplayName or name, fmt(BL[name].BoxPrice))
	boxLabels[#boxLabels + 1] = label
	boxByLabel[label] = name
	boxOn[name] = true -- Default does not fire the callback
end
local variantNames = {}
for name, v in pairs(require(RS.Shared.Core.Storage.Game.VariantsLibrary)) do
	if type(v) == "table" and (v.Chance or 0) > 0 then
		variantNames[#variantNames + 1] = name
		variantOn[name] = true
	end
end
table.sort(variantNames, function(a, b)
	return VS.GetMultiplier(a) < VS.GetMultiplier(b)
end)

Boxes:AddToggle("Buy", {
	Text = "Auto Roll + Buy Boxes",
	Tooltip = "Rerolls the belt (free, ~1s) until it shows a ticked box whose expected drop beats your weakest placed unit, then buys it",
	Default = false,
	Callback = function(on)
		buying = on
		setBox()
	end,
})
Boxes:AddToggle("Place", {
	Text = "Auto Place Boxes",
	Tooltip = "Puts held boxes that beat your weakest unit on a free slot, removing the weakest unit to the backpack when there is none",
	Default = false,
	Callback = function(on)
		placing = on
		setBox()
	end,
})
Boxes:AddToggle("Open", {
	Text = "Auto Open Boxes",
	Tooltip = "Opens each placed box the moment its timer is up",
	Default = false,
	Callback = function(on)
		opening = on
		setBox()
	end,
})
Boxes:AddDropdown("BoxList", {
	Text = "Boxes to buy",
	Values = boxLabels,
	Default = boxLabels,
	Multi = true,
	Callback = function(picked)
		table.clear(boxOn)
		for label in pairs(ticked(picked)) do
			if boxByLabel[label] then
				boxOn[boxByLabel[label]] = true
			end
		end
	end,
})
Boxes:AddDropdown("Variants", {
	Text = "Variants to buy",
	Tooltip = "A variant multiplies both the price and the unit's income (Golden 1.5x ... Malevolent 75x) and the open time",
	Values = variantNames,
	Default = variantNames,
	Multi = true,
	Callback = function(picked)
		table.clear(variantOn)
		for name in pairs(ticked(picked)) do
			variantOn[name] = true
		end
	end,
})
Boxes:AddInput("BoxShare", {
	Text = "Max % of cash per box",
	Default = tostring(BOX_SHARE_DEFAULT),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		boxShare = math.clamp(tonumber(text) or BOX_SHARE_DEFAULT, 1, 100)
	end,
})

Upgrades:AddToggle("Upgrades", {
	Text = "Auto Upgrades",
	Tooltip = "Buys the ticked upgrades, ranked by payback together with level-ups. Walk Speed is never bought",
	Default = false,
	Callback = function(on)
		spendUpgrades = on
		setSpend()
	end,
})
local upLabels, upByLabel = {}, {}
for _, row in ipairs(UPGRADE_LABELS) do
	upLabels[#upLabels + 1] = row[2]
	upByLabel[row[2]] = row[1]
end
Upgrades:AddDropdown("UpgradeList", {
	Text = "Upgrades to buy",
	Values = upLabels,
	Default = upLabels,
	Multi = true,
	Callback = function(picked)
		table.clear(upgradeOn)
		for label in pairs(ticked(picked)) do
			if upByLabel[label] then
				upgradeOn[upByLabel[label]] = true
			end
		end
	end,
})
Upgrades:AddInput("MaxPayback", {
	Text = "Max payback (seconds)",
	Tooltip = "A level-up or upgrade that takes longer than this to earn back its price waits. Raise it to spend harder",
	Default = tostring(MAX_PAYBACK),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		MAX_PAYBACK = math.max(tonumber(text) or MAX_PAYBACK, 10)
	end,
})

Units:AddToggle("Trait", {
	Text = "Auto Trait (tokens)",
	Tooltip = "Rerolls the best placed unit's trait with Trait tokens until its cash multiplier reaches the target, then the next one. Same trip as Auto Grade, to the Traits stand. MOVES YOUR CHARACTER",
	Default = false,
	Callback = function(on)
		if on then
			loop("trait", traitBody)
		else
			stop("trait")
		end
	end,
})
Units:AddDropdown("TraitTarget", {
	Text = "Trait target",
	Tooltip = "Fortune I 1.1x, II 1.3x, III / Assassin 1.5x, Phoenix 1.75x, Midas / Angelic 2x, Sovereign 3x cash",
	Values = TRAIT_ORDER,
	Default = traitTarget,
	Callback = function(v)
		traitTarget = v
	end,
})

local Tower = Tab:AddRightGroupbox("Infinity Tower", "castle")
Tower:AddToggle("Tower", {
	Text = "Auto Infinity Tower",
	Tooltip = "Starts the highest unlocked tower with your 4 strongest units and keeps the game's own Auto on, so runs restart by themselves. Units keep producing on their droppers. Swaps team or tower only at the start of a run",
	Default = false,
	Callback = function(on)
		if on then
			loop("tower", towerBody)
		else
			stopTower()
		end
	end,
})

-- the side-by-side: every unit at its level, at L1 and at L50, tower stats, and what the rest of L50 costs
local function printComparison()
	local rows = {}
	for guid, u in pairs(data().PlayerUnits or {}) do
		local lvl = u.Level or 1
		local now = PUS.GetCashPerDrop(player, guid)
		local base = now / LEVEL_STEP ^ (lvl - 1)
		rows[#rows + 1] = {
			name = ("%s %s %s/%s"):format(u.Variant or "Normal", u.PlayerUnitName, u.Grade or "F", u.Trait or "-"),
			lvl = lvl,
			now = now,
			base = base,
			at50 = base * LEVEL_STEP ^ (MAX_LEVEL - 1),
			dmg = PUS.GetDamageBasis(player, guid),
			hp = PUS.GetHealthBasis(player, guid) * 8,
			rest = catchUp(base, u.Grade, MAX_LEVEL) - catchUp(base, u.Grade, lvl),
			placed = u.Equipped,
		}
	end
	table.sort(rows, function(a, b)
		return a.base > b.base
	end)
	log(("%-38s %3s %9s %9s %9s %9s %9s %9s  %s"):format("unit (variant name grade/trait)", "L", "now/drop", "L1 base", "at L50", "tower dmg", "tower hp", "to L50", "where"))
	for _, r in ipairs(rows) do
		log(("%-38s %3d %9s %9s %9s %9s %9s %9s  %s"):format(r.name:sub(1, 38), r.lvl, fmt(r.now), fmt(r.base), fmt(r.at50), fmt(r.dmg), fmt(r.hp), fmt(r.rest), r.placed and "placed" or "backpack"))
	end
	local s = plot()
	local belt = s and s:FindFirstChild("RollStation") and s.RollStation:FindFirstChild("ConveyorPart")
	local name, variant = belt and belt:GetAttribute("BoxName"), belt and belt:GetAttribute("Variant")
	local lines = {}
	local function verdictLine(label, value, price, secs)
		local v, why, r = judge(value, nil, price, secs)
		local line = ("%s: L1 %s/drop -> %s. %s"):format(label, fmt(value), v:upper(), why)
		if r.incName then
			line ..= ("  [vs %s L%d: now %s vs %s at equal level; L50 %s vs %s; catch-up %s, open-time loss %s]"):format(r.incName, r.incLevel, fmt(r.incNow), fmt(r.newAtLevel), fmt(r.incAt50), fmt(r.newAt50), fmt(r.catchUp), fmt(r.lost))
		end
		log(line)
		lines[#lines + 1] = ("%s -> %s"):format(label, v:upper())
	end
	if name then
		verdictLine(("belt %s %s (%s)"):format(variant, name, fmt(BS.GetConveyorBoxPrice(name, variant))), boxValue(name, variant), BS.GetConveyorBoxPrice(name, variant), openSecs(name, variant))
	end
	for _, b in ipairs(heldBoxes()) do
		verdictLine(("held %s %s"):format(b.variant, b.name), b.value, 0, openSecs(b.name, b.variant))
	end
	say("cmp", #lines > 0 and table.concat(lines, " | ") or "nothing on the belt or in the inventory to compare", true)
end

local Compare = Tab:AddLeftGroupbox("Compare", "scale")
local cmpLabel = Compare:AddLabel("Roll the belt or press the button below", true)
Compare:AddDropdown("BuyRule", {
	Text = "Buy / place rule",
	Tooltip = "Pays back: compare both units at the weakest unit's level (the game scales every unit by the same 1.12 a level), and buy only if box price + levelling the new one up + the slot's lost income while it opens are earned back inside Max payback. Beats now: the new unit at level 1 must already out-earn the weakest placed one",
	Values = { "Pays back", "Beats now" },
	Default = buyRule,
	Callback = function(v)
		buyRule = v
	end,
})
Compare:AddButton({
	Text = "Print side-by-side (F9)",
	Func = function()
		pcall(printComparison)
	end,
})
getgenv().animeFarmCompare = printComparison

Misc:AddToggle("Claim", {
	Text = "Auto Claim Rewards",
	Tooltip = "Index rewards, playtime rewards as they unlock, daily login, offline earnings",
	Default = false,
	Callback = function(on)
		if on then
			loop("claim", claimBody)
		else
			stop("claim")
		end
	end,
})
Misc:AddToggle("AntiAfk", {
	Text = "Anti-AFK",
	Tooltip = "The game rejoins you to a private server after 15 minutes without input. This sends an F15 key every minute you are away",
	Default = true,
	Callback = setAfk,
})
setAfk(true) -- Default = true does not fire the callback

local conns = {}
local note = {}
local nextStrip = 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	for k, v in pairs(pending) do
		note[k], pending[k] = v, nil
		if k == "cmp" then
			pcall(cmpLabel.SetText, cmpLabel, v)
		end
	end
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	local _, _, _, opening_, units = slotState()
	pcall(Window.SetStatus, Window, {
		{ "Cash", fmt(cash()) },
		{ "Per sec", fmt(PUS.GetCashPerSecond(player)) },
		{ "Slots", ("%d units, %d boxes"):format(units, opening_) },
		{ "Sold", ("%d crates (%s balls)"):format(stats.sold, fmt(stats.soldBalls)) },
		{ "Levels", stats.levels .. " +" .. stats.upgrades .. " upg" },
		{ "Boxes", ("%d rolls, %d bought, %d opened"):format(stats.rolls, stats.bought, stats.opened) },
		{ "Spend", note.spend or "off" },
		{ "Box", note.buy or note.box or "off" },
		{ "Grade", note.grade or "off" },
		{ "Trait", note.trait or "off" },
		{ "Tower", note.tower or "off" },
	})
end))

-- watchdog: a loop whose breadcrumb stops moving is named with where it stopped
loop("watch", function()
	task.wait(15)
	for name, b in pairs(beat) do
		if name ~= "watch" and os.clock() - b.at > WATCHDOG then
			warn(("[animefarm] stuck: %s at '%s' for %ds"):format(name, b.step, math.floor(os.clock() - b.at)))
			b.at = os.clock()
		end
	end
end)

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

Window:AddSettingsTab("AnimeFarm", {})

-- close ----------------------------------------------------------------------
local function stopAll()
	for name in pairs(gen) do
		stop(name)
	end
	spendLevels, spendUpgrades, buying, placing, opening, equipping = false, false, false, false, false, false
	stopTower()
	setAfk(false)
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().animeFarmStop = nil
	getgenv().animeFarmCompare = nil
end)

getgenv().animeFarmStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().animeFarmStop = nil
end
