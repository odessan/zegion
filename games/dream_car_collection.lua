--[[ Dream Car Collection -- crates, cars, cash, upgrades, rebirth, cleaning, rewards (76841016201110)

     CRATES  : the game's own server-side Auto Spawn / Auto Open (LuckyBlock.SetAutomation), free, no gamepass.
               The server buys the conveyor crates of the tiers you tick (about one a second), places them
               and opens them when they hatch. Quick Open skips the reveal. Your own settings are put back
               when the panel closes. The real ceiling is your placed-crate limit (15 + Max Items upgrade):
               a Legendary holds a slot for 120s, so tick the tiers whose hatch time suits you.
     CARS    : fills every empty card slot best car first, then swaps a placed car for a better backpack one
               (pick up the worst, place the best). Same result as the group-only Place Best button.
               The server places the car you HOLD, so each car goes hotbar -> equip -> PlaceCar.
     SORT    : reorders the placed cars so slot 1 has the best $/s and the rest follow, highest first
               (PickupCar + place, ~0.5s a move, ties keep their order). UNPROVEN as a whole: the pickup
               and the hold-and-place were probed separately, the reordering was not.
     CASH    : ClaimAll from anywhere (position-free, probed at 300 studs), every few seconds.
     UPGRADE : buys the ticked upgrades in priority order with the game's own cost maths. Max Items first.
     REBIRTH : fires Rebirth.Request once the next rebirth is affordable. UNPROVEN: never fired, so what it
               resets is unknown. It prints a before/after line to F9. Off by default.
     CLEAN   : cleans every placed car whose shine ran out (12h, 1.25x cash on that car, +10 gems), one at a
               time, about 40s each. Progress is only sent for the current stage; the server paces it.
     REWARDS : index claim-all, finished daily/achievement quests, playtime milestones, the daily reward.
     SELL    : the game's server-side Auto Sell by the rarities you tick. Nothing is ticked to start with.

     Probed and dead (do not re-probe):
       BuyLuckyBlock / OpenRequest   no effect (the automation does both)
       PlaceCar with only a carId    ignored, the car must be held (12 of 12 refused)
       PlaceBest for non-members     "group_only". Members: one call, ~0.15s, reason "sorted" (opt-in toggle)
       pickups in a 0.05s burst      18 of 27 dropped: PickupCar goes one at a time (~0.15s each)
       Instant clean                 Progress 100 at once is capped to ~5%/s by the server
       Cleaning mode "Auto"          never started a session
     Not wired (Robux): OpenNow / OpenAllNow / RecoverCrate, car packs, Rebirth skip, Upgrades.RobuxRequest,
       gem-shop Robux, offline double, Instant Hatch / Fast Hatch / Auto Skip passes. Never press a crate
       before its ReadyAt: the prompt turns into an OPEN NOW (Robux) offer.
     Not wired (not asked): free spin, gem shop, codes, PlaceBest, trading, car shows.

     RightControl opens / closes the panel. Stop: getgenv().dreamCarsStop() ]]

-- config ---------------------------------------------------------------------
local CLAIM_EVERY = 3 -- seconds between ClaimAll. The cards hold ~300k/s on a mid account; raise it to claim less
local PLACE_EVERY = 2 -- how often the car loop looks for a free slot or a better car
local TOOL_WAIT = 1.2 -- MoveCarRequest must turn the car into a Tool inside this (probed 0.05-0.2s)
local EQUIP_WAIT = 1.5 -- the Tool must reach your hands inside this
local PLACE_CONFIRM = 3 -- the card must show the car inside this (probed 0.1-0.2s)
local PLACE_FAIL_BACKOFF = 5 -- a pass that placed nothing waits this long before trying again
local PLACEBEST_REPLY = 2 -- Place Best answers inside this (probed 0.16s)
local SORT_EVERY = 20 -- how often the slot order is re-checked. A new car better than the rest shifts everything below it, ~0.5s a move
local UPGRADE_EVERY = 3
local UPGRADE_BACKOFF = 30 -- an upgrade the server did not take is not retried for this long
local BUY_REPLY = 2 -- an upgrade purchase answers inside this
local REBIRTH_EVERY = 5
local REBIRTH_REPLY = 6 -- how long to wait for the server to take a rebirth
local REBIRTH_BACKOFF = 60 -- after a rebirth the server did not take
local REWARDS_EVERY = 20
local SYNC_EVERY = 30 -- quest list refresh
local INDEX_EVERY = 90 -- index claim-all even when the car count did not change
local CLEAN_EVERY = 15 -- how often to look for a car whose shine ran out
local CLEAN_GAP = 0.25 -- between Progress sends (the game's own client throttles at 0.22)
local CLEAN_START = 5 -- a session must report Started inside this
local CLEAN_MAX = 120 -- a session still running after this is stopped (probed 39s)
local CLEAN_RETRY = 120 -- a car whose session failed is skipped for this long
local AUTO_ACK = 2 -- an automation setting is answered inside this
local STRIP_EVERY = 0.5
local UPGRADE_ORDER = { "MaxItems", "RollLuck", "MutationLuck", "FoamSpray", "PowerWash", "OfflineEarning", "PlayerSpeed" }
local UPGRADE_DEFAULT = { MaxItems = true, RollLuck = true, MutationLuck = true, FoamSpray = true, PowerWash = true }
local TIER_DEFAULT = { Rare = true, Epic = true, Legendary = true }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")
local player = Players.LocalPlayer

if getgenv and getgenv().dreamCarsStop then
	getgenv().dreamCarsStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[dreamcars]", ...)
end

-- The panel strip is drained from a Heartbeat (our own identity); a loop thread that writes to
-- the window directly throws "lacking capability Plugin" after its first task.wait.
local note, lastSaid = "idle", nil
local function say(msg)
	note = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

local function ticked(values)
	local set = {}
	for k, v in pairs(values) do
		if type(v) == "string" then
			set[v] = true -- list form
		elseif v then
			set[k] = true -- map form
		end
	end
	return set
end
assert(ticked({ "a", "b" }).b and ticked({ a = true }).a and not ticked({ a = false }).a, "ticked reads both shapes")

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

-- game -----------------------------------------------------------------------
local Networking = require(ReplicatedStorage.Networking)
local PlayerDataShared = require(ReplicatedStorage.Shared.Managers.PlayerDataShared)
local CashMath = require(ReplicatedStorage.Shared.Utility.CashMath)
local UpgradeUtil = require(ReplicatedStorage.Shared.Utility.UpgradeUtil)
local BoostCalculator = require(ReplicatedStorage.Shared.Utility.BoostCalculator)
local CarShineUtil = require(ReplicatedStorage.Shared.Utility.CarShineUtil)
local Upgrades = require(ReplicatedStorage.GAMEPLAY.Economy.Upgrades)
local Rebirths = require(ReplicatedStorage.GAMEPLAY.Economy.Rebirths)
local LuckyBlocks = require(ReplicatedStorage.GAMEPLAY.Economy.LuckyBlocks)
local PlaytimeCfg = require(ReplicatedStorage.GAMEPLAY.Economy.PlaytimeRewardsConfig)
local CarsCfg = require(ReplicatedStorage.GAMEPLAY.Cars)
local RarityOrder = require(ReplicatedStorage.GAMEPLAY.Rarity).Order

local okData, data = PlayerDataShared.PlayerDataContainers:WaitForObject(player):await()
assert(okData and data, "player data container not found (is the game loaded?)")
local Action = ReplicatedStorage:WaitForChild("BaseInventoryRemotes"):WaitForChild("Action")

local function get(key)
	return data:GetValue(key)
end

local function myPlot()
	local bases = workspace:FindFirstChild("rbx-build") and workspace["rbx-build"]:FindFirstChild("Bases")
	for _, m in ipairs(bases and bases:GetChildren() or {}) do
		if m:GetAttribute("OwnerUserId") == player.UserId then
			return m
		end
	end
	return nil
end

local function plotId()
	local m = myPlot()
	return m and m:GetAttribute("PlotId")
end

local function cashNumber()
	local ok, n = pcall(CashMath.ToNumber, get("Cash"))
	return ok and n or 0
end

local stats = { opened = 0, cleaned = 0, placed = 0, swapped = 0, sorted = 0, upgrades = 0, claimed = 0, rebirths = 0 }
local unsubs = {} -- listen() hands back an unsubscribe function

-- state read by the loops -----------------------------------------------------
local tierOn, rarityOn, upOn = {}, {}, {}
for t in pairs(TIER_DEFAULT) do
	tierOn[t] = true -- Default does not fire the callback, so arm by hand
end
for id in pairs(UPGRADE_DEFAULT) do
	upOn[id] = true
end
local reserveRebirth = true
local flags = { buy = false, open = false, sell = false, rebirth = false }

-- crate automation (server-side) ----------------------------------------------
-- SetAutomation{key, tier, enabled, sequence}; the server answers each with accepted. A value that
-- already holds is answered accepted=false, which is fine. The setting is saved server-side and
-- outlives this script, so everything we touch is put back by stopAll.
local seq = math.max(getgenv().dreamCarsSeq or 0, os.time())
local acks, queue, draining = {}, {}, false
table.insert(unsubs, Networking.LuckyBlock.AutomationSettingsResult.listen(function(v)
	acks[v.sequence] = v
end))

local function autoSet(key, tier, enabled)
	table.insert(queue, { key, tier or "", enabled })
	if draining then
		return
	end
	draining = true
	task.spawn(function()
		while #queue > 0 do
			local q = table.remove(queue, 1)
			seq += 1
			getgenv().dreamCarsSeq = seq
			local mine = seq
			Networking.LuckyBlock.SetAutomation.send({ key = q[1], tier = q[2], enabled = q[3], sequence = mine })
			local dl = os.clock() + AUTO_ACK
			while not acks[mine] and os.clock() < dl do
				task.wait(0.05)
			end
			acks[mine] = nil
		end
		draining = false
	end)
end

local function serverValue(key, tier)
	local cfg = get("CrateAutomation") or {}
	if key == "BuyTier" then
		return (cfg.BuyTiers or {})[tier] == true
	elseif key == "SellRarity" then
		return (cfg.SellRarities or {})[tier] == true
	elseif key == "AutoPlace" or key == "ClaimAllToBuy" or key == "AutoSellIncludePacks" then
		return cfg[key] ~= false
	end
	return cfg[key] == true
end

local touched = {} -- "key:tier" -> the value the server had before we touched it
local function setAuto(key, tier, enabled)
	local id = key .. ":" .. (tier or "")
	if touched[id] == nil then
		touched[id] = { key, tier, serverValue(key, tier) }
	end
	autoSet(key, tier, enabled)
end

local function restoreAuto()
	for _, t in pairs(touched) do
		autoSet(t[1], t[2], t[3])
	end
	table.clear(touched)
end

local function syncTiers()
	for _, t in ipairs(LuckyBlocks.Order) do
		local want = tierOn[t] == true
		if serverValue("BuyTier", t) ~= want then
			setAuto("BuyTier", t, want)
		end
	end
end

local function syncRarities()
	for _, r in ipairs(RarityOrder) do
		local want = rarityOn[r] == true
		if serverValue("SellRarity", r) ~= want then
			setAuto("SellRarity", r, want)
		end
	end
end

local function setBuy(on)
	flags.buy = on
	if on then
		setAuto("AutoPlace", nil, true)
		setAuto("ClaimAllToBuy", nil, true) -- lets the server spend the cards' cash on crates
		syncTiers()
		setAuto("AutoSpawn", nil, true)
		say(next(tierOn) and "buying crates" or "tick a crate tier to buy")
	else
		setAuto("AutoSpawn", nil, false)
	end
end

local function setOpen(on)
	flags.open = on
	setAuto("AutoOpen", nil, on)
	setAuto("QuickOpen", nil, on)
	setAuto("MuteQuickRoll", nil, on)
end

local function setSell(on)
	flags.sell = on
	if on then
		syncRarities()
	end
	setAuto("AutoSell", nil, on)
end

local openSeen = {}
table.insert(unsubs, Networking.LuckyBlock.OpenResult.listen(function(v)
	if v.carId and not openSeen[v.carId] then -- the server repeats a result while it is presented
		openSeen[v.carId] = true
		stats.opened += 1
	end
end))

-- cash ------------------------------------------------------------------------
local genClaim, claimOn = 0, false
local function claimLoop(mine)
	while claimOn and genClaim == mine do
		local id = plotId()
		if id then
			pcall(function()
				Action:FireServer("ClaimAll", id)
			end)
			stats.claimed += 1
		end
		task.wait(CLAIM_EVERY)
	end
end

local function setClaim(on)
	genClaim += 1
	claimOn = on
	if on then
		task.spawn(claimLoop, genClaim)
	end
end

-- one claim on the character: placing cars and cleaning both drive your hands
local busy = false
local function claim(fn, alive)
	while busy do
		if not alive() then
			return false
		end
		task.wait(0.1)
	end
	busy = true -- nothing yields between the check and the set
	local ok, err = pcall(fn)
	busy = false
	if not ok then
		warn("[dreamcars] claimed step failed:", err)
	end
	return true
end

-- cars ------------------------------------------------------------------------
local function slotCount()
	return Rebirths.GetCollectionCardSlotCount(tonumber(get("Rebirths")) or 0)
end

-- a slot the server emptied keeps its key with "" as the value
local function slotOf(n)
	local v = (get("CarSlots") or {})["CollectionCard" .. n]
	if v ~= nil and v ~= "" then
		return v
	end
	return nil
end

local function carScore(car)
	return BoostCalculator.GetPermanentCarCashPerSecond(CarsCfg[car.Template], car, data)
end

local function survey()
	local cars = get("Cars") or {}
	local placedAt, free = {}, {}
	for n = 1, slotCount() do
		local id = slotOf(n)
		if id then
			placedAt[id] = n
		else
			table.insert(free, n)
		end
	end
	local back, placed = {}, {}
	for id, car in pairs(cars) do
		if type(car) == "table" and CarsCfg[car.Template] then
			local e = { id = id, tpl = car.Template, mut = car.Mutation or "", s = carScore(car), slot = placedAt[id] }
			table.insert(e.slot and placed or back, e)
		end
	end
	table.sort(back, function(a, b)
		return a.s > b.s
	end)
	table.sort(placed, function(a, b)
		return a.s < b.s
	end)
	return free, back, placed
end

local function toolFor(carId)
	for _, root in ipairs({ player.Backpack, player.Character }) do
		for _, t in ipairs(root and root:GetChildren() or {}) do
			if t:IsA("Tool") and t:GetAttribute("CarId") == carId then
				return t
			end
		end
	end
	return nil
end

-- a car outside the hotbar is not a Tool yet: MoveCarRequest puts it in a hotbar slot (slot 1 took it
-- every time in the probe; the others are the fallback if the server refuses a slot)
local function ensureTool(carId)
	local t = toolFor(carId)
	if t then
		return t
	end
	for s = 1, 9 do
		Networking.Backpack.MoveCarRequest.send({ carId = carId, slot = s })
		local dl = os.clock() + TOOL_WAIT
		while os.clock() < dl do
			t = toolFor(carId)
			if t then
				return t
			end
			task.wait(0.05)
		end
	end
	return nil
end

local function placeHeld(e, slotN)
	local t = ensureTool(e.id)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not (t and hum) then
		return false
	end
	pcall(hum.EquipTool, hum, t)
	local dl = os.clock() + EQUIP_WAIT
	while t.Parent ~= player.Character and os.clock() < dl do
		task.wait(0.05)
	end
	local id = plotId()
	if not id then
		return false
	end
	Action:FireServer("PlaceCar", id, e.id, slotN)
	dl = os.clock() + PLACE_CONFIRM
	while slotOf(slotN) ~= e.id and os.clock() < dl do
		task.wait(0.05)
	end
	return slotOf(slotN) == e.id
end

-- The game's own Place Best: one server call that places and sorts the whole book (probed 0.15s for
-- 8 swaps, reason "sorted"). It is group-only: a non-member gets "group_only" once and we stop asking.
local placeBestResult
table.insert(unsubs, Networking.Backpack.PlaceBestResult.listen(function(v)
	placeBestResult = v
end))
local usePlaceBest, groupBlocked = false, false

local function tryPlaceBest()
	placeBestResult = nil
	Networking.Backpack.PlaceBestRequest.send()
	local dl = os.clock() + PLACEBEST_REPLY
	while not placeBestResult and os.clock() < dl do
		task.wait(0.05)
	end
	local r = placeBestResult
	if not r then
		return false
	end
	if r.reason == "group_only" then
		groupBlocked = true
		say("Place Best needs the game's group: placing by hand")
		return false
	end
	return r.reason == "sorted" or r.reason == "" or r.reason == "cooldown"
end

local genPlace, placeOn = 0, false
local function placePass(mine)
	local alive = function()
		return placeOn and genPlace == mine
	end
	local free, back, placed = survey()
	local swaps = back[1] and placed[1] and back[1].s > placed[1].s
	if not ((#free > 0 and #back > 0) or swaps) then
		return nil -- nothing to do
	end
	if usePlaceBest and not groupBlocked and tryPlaceBest() then
		return true
	end
	local didAny = false
	local ran = claim(function()
		local k = 1
		while free[k] and back[1] and alive() do
			local e = table.remove(back, 1) -- best first
			if not placeHeld(e, free[k]) then
				return
			end
			stats.placed += 1
			didAny = true
			k += 1
		end
		-- sort the book: placed is worst-first, back is best-first, so this converges
		local i = 1
		local id = plotId()
		while alive() and id and back[i] and placed[i] and back[i].s > placed[i].s do
			Action:FireServer("PickupCar", id, placed[i].id)
			local dl = os.clock() + PLACE_CONFIRM
			while slotOf(placed[i].slot) and os.clock() < dl do
				task.wait(0.05)
			end
			if not placeHeld(back[i], placed[i].slot) then
				return
			end
			stats.swapped += 1
			didAny = true
			i += 1
		end
	end, alive)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		hum:UnequipTools()
	end
	return ran and didAny
end

local function placeLoop(mine)
	while placeOn and genPlace == mine do
		local ok, did = pcall(placePass, mine)
		if not ok then
			warn("[dreamcars] place pass failed:", did)
			did = false
		end
		-- nil = nothing to place (the normal idle state), false = there was work and none landed
		task.wait(did == false and PLACE_FAIL_BACKOFF or PLACE_EVERY)
	end
end

local function setPlace(on)
	genPlace += 1
	placeOn = on
	if on then
		task.spawn(placeLoop, genPlace)
	end
end

-- sort the slots: best car in slot 1, descending. A move is PickupCar + hold + PlaceCar (~0.5s).
-- Slot i is made to hold target i by emptying it and lifting the wanted car off wherever it is; the
-- car that was bumped out lands later in its own slot (it can only belong further down), so no
-- spare slot is needed. Ties keep their current order, so a sorted book costs nothing to re-check.
local function findSlot(carId)
	for n = 1, slotCount() do
		if slotOf(n) == carId then
			return n
		end
	end
	return nil
end

local function pickup(carId, slotN)
	local id = plotId()
	if not id then
		return false
	end
	Action:FireServer("PickupCar", id, carId)
	local dl = os.clock() + PLACE_CONFIRM
	while slotOf(slotN) == carId and os.clock() < dl do
		task.wait(0.05)
	end
	return slotOf(slotN) ~= carId
end

local genSort, sortOn = 0, false
local function sortPass(mine)
	local alive = function()
		return sortOn and genSort == mine
	end
	if usePlaceBest and not groupBlocked then
		-- Place Best sorts as well as places, and its order differs slightly from ours: sorting by hand
		-- on top of it would shuffle two cars back and forth
		if tryPlaceBest() then
			return 0
		end
		if not groupBlocked then
			return 0
		end
	end
	local moved = 0
	claim(function()
		local _, _, placed = survey()
		table.sort(placed, function(a, b)
			if a.s ~= b.s then
				return a.s > b.s
			end
			return a.slot < b.slot
		end)
		for i, want in ipairs(placed) do
			if not alive() then
				return
			end
			if slotOf(i) ~= want.id then
				local cur = slotOf(i)
				if cur and not pickup(cur, i) then
					return
				end
				local at = findSlot(want.id)
				if at and not pickup(want.id, at) then
					return
				end
				if not placeHeld(want, i) then
					return
				end
				moved += 1
				stats.sorted += 1
			end
		end
	end, alive)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		hum:UnequipTools()
	end
	return moved
end

local function sortLoop(mine)
	while sortOn and genSort == mine do
		local ok, moved = pcall(sortPass, mine)
		if not ok then
			warn("[dreamcars] sort pass failed:", moved)
		end
		task.wait(SORT_EVERY)
	end
end

local function setSort(on)
	genSort += 1
	sortOn = on
	if on then
		task.spawn(sortLoop, genSort)
	end
end

-- cleaning --------------------------------------------------------------------
local session = { stage = "Foam", ev = nil }
table.insert(unsubs, Networking.Cleaning.SessionState.listen(function(v)
	if v.stage then
		session.stage = v.stage
	end
	session.ev = v.event
end))

local genClean, cleanOn = 0, false
local cleanRetry = {}

local function nextDirty()
	local cars = get("Cars") or {}
	local best
	for n = 1, slotCount() do
		local id = slotOf(n)
		local car = id and cars[id]
		if car and CarsCfg[car.Template] and CarShineUtil.HasWashablePanels(car) and (tonumber(car.ShinyUntil) or 0) <= os.time() and (cleanRetry[id] or 0) <= os.clock() then
			local s = carScore(car)
			if not best or s > best.s then
				best = { id = id, s = s, tpl = car.Template }
			end
		end
	end
	return best
end

local function cleanOne(car, alive)
	session.ev = nil
	Networking.Cleaning.RequestStart.send({ mode = "Manual", carId = car.id })
	local dl = os.clock() + CLEAN_START
	while session.ev ~= "Started" and os.clock() < dl and alive() do
		task.wait(0.1)
	end
	if session.ev ~= "Started" then
		cleanRetry[car.id] = os.clock() + CLEAN_RETRY
		return false
	end
	local t0 = os.clock()
	while alive() and os.clock() - t0 < CLEAN_MAX do
		local ev = session.ev
		if ev ~= "Started" and ev ~= "Progress" and ev ~= "Stage" then
			break
		end
		Networking.Cleaning.Progress.send({ phase = session.stage, progress = 100 })
		task.wait(CLEAN_GAP)
	end
	if session.ev == "Completed" then
		stats.cleaned += 1
		return true
	end
	Networking.Cleaning.RequestStop.send({})
	cleanRetry[car.id] = os.clock() + CLEAN_RETRY
	return false
end

local function cleanLoop(mine)
	local alive = function()
		return cleanOn and genClean == mine
	end
	while alive() do
		local car = nextDirty()
		if car then
			say("cleaning " .. car.tpl)
			claim(function()
				cleanOne(car, alive)
			end, alive)
			say("idle")
			task.wait(1)
		else
			task.wait(CLEAN_EVERY)
		end
	end
end

local function setClean(on)
	genClean += 1
	cleanOn = on
	if on then
		task.spawn(cleanLoop, genClean)
	end
end

-- upgrades --------------------------------------------------------------------
local buyResult
table.insert(unsubs, Networking.Upgrades.BuyResult.listen(function(v)
	buyResult = v
end))

local genUp, upgradeOn = 0, false
local upBackoff = {}
local function upgradePass(mine)
	local rb = tonumber(get("Rebirths")) or 0
	if flags.rebirth and reserveRebirth then
		local nl = Rebirths.GetNextLevel(rb)
		if nl and not CashMath.CanAfford(get("Cash"), nl.Cost) then
			say("saving for rebirth")
			return
		end
	end
	for _, id in ipairs(UPGRADE_ORDER) do
		if not (upgradeOn and genUp == mine) then
			return
		end
		local ty = Upgrades.Types[id]
		if upOn[id] and ty and not ty.Disabled and (upBackoff[id] or 0) <= os.clock() then
			local lvl = UpgradeUtil.GetLevel(get("Upgrades"), id)
			if UpgradeUtil.MeetsRebirthGate(id, rb) and not UpgradeUtil.IsMaxed(id, lvl, rb) and UpgradeUtil.GetAffordableLevels(id, lvl, get("Cash"), rb) >= 1 then
				buyResult = nil
				Networking.Upgrades.BuyRequest.send({ id = id, buyAll = true })
				local dl = os.clock() + BUY_REPLY
				while not (buyResult and buyResult.id == id) and os.clock() < dl do
					task.wait(0.05)
				end
				if buyResult and buyResult.id == id and buyResult.reason == "" and (buyResult.levelsBought or 0) > 0 then
					stats.upgrades += buyResult.levelsBought
					say(("%s -> %d"):format(id, buyResult.newLevel))
				else
					upBackoff[id] = os.clock() + UPGRADE_BACKOFF
				end
			end
		end
	end
end

local function upgradeLoop(mine)
	while upgradeOn and genUp == mine do
		local ok, err = pcall(upgradePass, mine)
		if not ok then
			warn("[dreamcars] upgrade pass failed:", err)
		end
		task.wait(UPGRADE_EVERY)
	end
end

local function setUpgrade(on)
	genUp += 1
	upgradeOn = on
	if on then
		task.spawn(upgradeLoop, genUp)
	end
end

-- rebirth ---------------------------------------------------------------------
-- ponytail: UNPROVEN. Rebirth.Request{version=1} was never fired; what it resets is unknown.
local rebirthResult
table.insert(unsubs, Networking.Rebirth.Result.listen(function(v)
	rebirthResult = v
end))

local genRb, rebirthOn = 0, false
local function rebirthPass()
	local rb = tonumber(get("Rebirths")) or 0
	local nl = Rebirths.GetNextLevel(rb)
	if not (nl and CashMath.CanAfford(get("Cash"), nl.Cost)) then
		return 0
	end
	local cars = 0
	for _ in pairs(get("Cars") or {}) do
		cars += 1
	end
	log("REBIRTH firing at", rb, "cash", get("Cash"), "cars", cars, "upgrades", get("Upgrades"))
	rebirthResult = nil
	Networking.Rebirth.Request.send({ version = 1 })
	local dl = os.clock() + REBIRTH_REPLY
	while not rebirthResult and os.clock() < dl do
		task.wait(0.1)
	end
	task.wait(1)
	local after = 0
	for _ in pairs(get("Cars") or {}) do
		after += 1
	end
	log("REBIRTH reply", rebirthResult, "rebirths now", get("Rebirths"), "cash", get("Cash"), "cars", after, "upgrades", get("Upgrades"))
	if (tonumber(get("Rebirths")) or 0) > rb then
		stats.rebirths += 1
		return 5
	end
	return REBIRTH_BACKOFF
end

local function rebirthLoop(mine)
	while rebirthOn and genRb == mine do
		local ok, extra = pcall(rebirthPass)
		if not ok then
			warn("[dreamcars] rebirth pass failed:", extra)
			extra = REBIRTH_BACKOFF
		end
		task.wait(REBIRTH_EVERY + (extra or 0))
	end
end

local function setRebirth(on)
	genRb += 1
	rebirthOn = on
	flags.rebirth = on
	if on then
		task.spawn(rebirthLoop, genRb)
	end
end

-- rewards ---------------------------------------------------------------------
local questSync
table.insert(unsubs, Networking.Quests.Sync.listen(function(v)
	questSync = v
end))

local genRw, rewardsOn = 0, false
local lastSync, lastIndex, lastCars = -SYNC_EVERY, -INDEX_EVERY, -1
local sent = {} -- "kind:key" -> when, so a reward is not re-asked every pass
local function once(key, retryAfter)
	if (sent[key] or -1e9) + retryAfter > os.clock() then
		return false
	end
	sent[key] = os.clock()
	return true
end

local function rewardsPass(mine)
	local alive = function()
		return rewardsOn and genRw == mine
	end
	local now = os.clock()
	-- index: when the car count moved, or on a slow beat
	local n = 0
	for _ in pairs(get("Cars") or {}) do
		n += 1
	end
	if n ~= lastCars or now - lastIndex >= INDEX_EVERY then
		lastCars, lastIndex = n, now
		Networking.Index.ClaimAllRequest.send(nil)
	end
	-- quests
	if now - lastSync >= SYNC_EVERY then
		lastSync = now
		Networking.Quests.RequestSync.send({})
	end
	if type(questSync) == "table" then
		for period, pv in pairs(questSync) do
			if type(pv) == "table" and type(pv.quests) == "table" then
				for _, q in pairs(pv.quests) do
					if alive() and type(q) == "table" and q.id and q.completed and not q.claimed and once("q:" .. period .. q.id, 60) then
						local name = q.period or (period:sub(1, 1):upper() .. period:sub(2))
						Networking.Quests.ClaimRequest.send({ period = name, questId = q.id })
						task.wait(0.6)
					end
				end
			end
		end
	end
	-- playtime milestones: the data does not say which are claimed, so ask once per day and slot
	local pt = get("PlaytimeRewards")
	if type(pt) == "table" and (tonumber(pt.dayKey) or -1) >= 0 then
		for slot, secs in ipairs(PlaytimeCfg.Milestones) do
			if alive() and (tonumber(pt.seconds) or 0) >= secs and once("p:" .. pt.dayKey .. ":" .. slot, 1e9) then
				Networking.PlayerData.ClaimPlaytimeReward.send({ dayKey = pt.dayKey, slot = slot })
				task.wait(0.6)
			end
		end
	end
	-- daily reward
	local dr = get("DailyRewards")
	if type(dr) == "table" and os.time() >= (tonumber(dr.nextClaimAt) or math.huge) and once("d:" .. tostring(dr.nextDay), 60) then
		Networking.PlayerData.ClaimDailyReward.send({ day = dr.nextDay })
	end
end

local function rewardsLoop(mine)
	while rewardsOn and genRw == mine do
		local ok, err = pcall(rewardsPass, mine)
		if not ok then
			warn("[dreamcars] rewards pass failed:", err)
		end
		task.wait(REWARDS_EVERY)
	end
end

local function setRewards(on)
	genRw += 1
	rewardsOn = on
	if on then
		task.spawn(rewardsLoop, genRw)
	end
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Dream Car Collection", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "car")
local Crates = Tab:AddLeftGroupbox("Crates", "package")
local Cars = Tab:AddLeftGroupbox("Cars", "car")
local Money = Tab:AddRightGroupbox("Money", "coins")
local Extra = Tab:AddRightGroupbox("Rewards and sell", "gift")

-- every control's callback is wrapped: a throw is reported, not propagated, and the switch has flipped
local function safe(fn)
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			warn("[dreamcars] callback failed:", err)
		end
	end
end

local tierValues, tierByLabel, tierDefault = {}, {}, {}
for _, t in ipairs(LuckyBlocks.Order) do
	local cfg = LuckyBlocks.Tiers[t]
	local label = ("%s (%s, %ds)"):format(t, fmt(cfg.cashCost), cfg.hatchSeconds)
	table.insert(tierValues, label)
	tierByLabel[label] = t
	if TIER_DEFAULT[t] then
		table.insert(tierDefault, label)
	end
end

Crates:AddToggle("Buy", {
	Text = "Auto Buy + Place Crates",
	Tooltip = "The game's own server-side Auto Spawn: buys the conveyor crates of the tiers below (about one a second) and places them. Your own setting is put back when the panel closes",
	Default = false,
	Callback = safe(setBuy),
})
Crates:AddDropdown("Tiers", {
	Text = "Crate tiers to buy",
	Tooltip = "Price and hatch time in brackets. Placed crates are capped (15 + Max Items upgrade) and a long hatch holds a slot, so a Legendary (120s) is slower per slot than a Rare (10s) but its cars are better",
	Values = tierValues,
	Default = tierDefault,
	Multi = true,
	Callback = safe(function(picked)
		table.clear(tierOn)
		for label in pairs(ticked(picked)) do
			local t = tierByLabel[label]
			if t then
				tierOn[t] = true
			end
		end
		if flags.buy then
			syncTiers()
		end
	end),
})
Crates:AddToggle("Open", {
	Text = "Auto Open Crates (quick)",
	Tooltip = "The game's server-side Auto Open with Quick Open: opens each crate when it hatches and skips the reveal. Also mutes the quick-roll sound",
	Default = false,
	Callback = safe(setOpen),
})
Cars:AddToggle("Place", {
	Text = "Auto Place + Sort Cars",
	Tooltip = "Fills every empty card slot with your best backpack car, then swaps a placed car for a better one. Holds each car in your hands for a moment",
	Default = false,
	Callback = safe(setPlace),
})
Cars:AddToggle("UsePlaceBest", {
	Text = "Use game's Place Best (group)",
	Tooltip = "Lets the game's own Place Best button do the placing and sorting in one server call (about 0.15s for the whole book). Needs you to have joined the game's group; without it the script says so and places by hand. Off by default: our own placing works for everyone",
	Default = false,
	Callback = safe(function(on)
		usePlaceBest = on
	end),
})
Cars:AddToggle("Sort", {
	Text = "Sort Slots by Income",
	Tooltip = "Reorders the placed cars so the best $/s is in slot 1 and the rest follow, highest first. Each move picks a car up and places it again (about 0.5s, and a pickup collects that card's cash). Equal cars keep their order. Works alone or with Auto Place",
	Default = false,
	Callback = safe(setSort),
})
Cars:AddToggle("Clean", {
	Text = "Auto Clean Cars",
	Tooltip = "Cleans each placed car whose shine ran out: 12h of 1.25x cash on that car and +10 gems, about 40s a car. The game's own cleaning view takes your camera while it runs",
	Default = false,
	Callback = safe(setClean),
})
Money:AddToggle("Claim", {
	Text = "Auto Collect Cash",
	Tooltip = "ClaimAll from wherever you stand, every few seconds",
	Default = false,
	Callback = safe(setClaim),
})
Money:AddToggle("Upgrade", {
	Text = "Auto Upgrade",
	Tooltip = "Buys the ticked upgrades in priority order (Max Items first) with the game's own cost maths. Never touches a Robux route",
	Default = false,
	Callback = safe(setUpgrade),
})
Money:AddDropdown("UpgradeIds", {
	Text = "Upgrades to buy",
	Tooltip = "In this priority order. Max Items raises the placed-crate cap, which is the throughput limit",
	Values = UPGRADE_ORDER,
	Default = (function()
		local d = {}
		for _, id in ipairs(UPGRADE_ORDER) do
			if UPGRADE_DEFAULT[id] then
				table.insert(d, id)
			end
		end
		return d
	end)(),
	Multi = true,
	Callback = safe(function(picked)
		table.clear(upOn)
		for id in pairs(ticked(picked)) do
			upOn[id] = true
		end
	end),
})
Money:AddToggle("Rebirth", {
	Text = "Auto Rebirth (untested)",
	Tooltip = "Fires Rebirth the moment the next one is affordable. UNPROVEN: never fired before, and what it resets is unknown. Prints a before/after line to F9. Off by default",
	Default = false,
	Callback = safe(setRebirth),
})
Money:AddToggle("Reserve", {
	Text = "Save cash for rebirth",
	Tooltip = "While Auto Rebirth is on, upgrades wait until the rebirth is affordable (coarse: it pauses upgrades, not just reserves the price)",
	Default = true,
	Callback = safe(function(on)
		reserveRebirth = on
	end),
})
Extra:AddToggle("Rewards", {
	Text = "Auto Claim Rewards",
	Tooltip = "Index claim-all, finished daily and achievement quests, playtime milestones and the daily reward. Free ones only",
	Default = false,
	Callback = safe(setRewards),
})
Extra:AddToggle("Sell", {
	Text = "Auto Sell Cars",
	Tooltip = "The game's server-side Auto Sell for the rarities below. Your backpack holds 300 cars, so a long run needs it. Nothing is ticked to start with: check what you sell",
	Default = false,
	Callback = safe(setSell),
})
Extra:AddDropdown("SellRarity", {
	Text = "Rarities to sell",
	Tooltip = "Cars of these rarities that are not placed are sold for cash",
	Values = RarityOrder,
	Default = {},
	Multi = true,
	Callback = safe(function(picked)
		table.clear(rarityOn)
		for r in pairs(ticked(picked)) do
			rarityOn[r] = true
		end
		if flags.sell then
			syncRarities()
		end
	end),
})

local function carStatus()
	local free, back = survey()
	return ("%d/%d placed, %d spare"):format(slotCount() - #free, slotCount(), #back)
end

local function crateStatus()
	local placed, carried = 0, 0
	for _ in pairs(get("PlacedLuckyBlocks") or {}) do
		placed += 1
	end
	for _ in pairs(get("LuckyBlocks") or {}) do
		carried += 1
	end
	return ("%d/%d placed, %d held"):format(placed, LuckyBlocks.GetPlacedLimit(get("Upgrades")), carried)
end

local conns = {}
local nextStrip = 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + STRIP_EVERY
	pcall(function()
		Window:SetStatus({
			{ "Cash", fmt(cashNumber()) },
			{ "Gems", tostring(get("Gems") or 0) },
			{ "Rebirths", tostring(get("Rebirths") or 0) },
			{ "Cars", carStatus() },
			{ "Crates", crateStatus() },
			{ "Opened", stats.opened },
			{ "Cleaned", stats.cleaned },
			{ "Upgrades", stats.upgrades },
			{ "Now", note },
		})
	end)
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("DreamCarCollection", {})

table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- close ----------------------------------------------------------------------
local function stopAll()
	setClaim(false)
	setPlace(false)
	setSort(false)
	setClean(false)
	setUpgrade(false)
	setRebirth(false)
	setRewards(false)
	flags.buy, flags.open, flags.sell = false, false, false
	restoreAuto() -- server-side settings outlive the script: hand back what they were
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
	-- the setting writes above drain on their own thread, and need the ack listener until they are done
	task.spawn(function()
		local dl = os.clock() + 15
		while (draining or #queue > 0) and os.clock() < dl do
			task.wait(0.1)
		end
		for _, un in ipairs(unsubs) do
			pcall(un)
		end
		table.clear(unsubs)
	end)
end

Library:OnUnload(function()
	stopAll()
	getgenv().dreamCarsStop = nil
end)

getgenv().dreamCarsStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().dreamCarsStop = nil
end
