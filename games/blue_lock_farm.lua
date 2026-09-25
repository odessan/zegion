--[[ Blue Lock Farm -- roll lockers, open them into players, keep the plot at its best (132767904294856)

     ROLL     : RequestConveyorRoll is free and paced only by the game's own cooldown, so the
                belt rolls non-stop and PurchaseConveyorRoll is fired only for a locker your
                filter wants: a minimum tier (the locker) and/or a minimum variant (the
                mutation) -- each "this and above", in the game's own order -- or, optionally,
                any locker whose average pull beats your weakest slot by 25% and costs at most
                30 min of income. A wanted locker you can't afford yet is held on the belt
                while income will cover it inside those 30 min (both inputs). With Buy matches
                off, the belt stops on the first match and waits for you to buy it. The AutoConveyor
                gamepass is all client-side and fires these same two remotes; you don't need it.
     LOCKERS  : open every ready locker (OpenBoxOnDropper -- the player lands on that same
                slot), level every slotted player to your cap, swap a bag player that's better at the
                cap onto your weakest slot (else fire the game's own Equip Best),
                then place: an empty slot gets your richest locker; otherwise the richest locker
                whose average pull beats your weakest player by 25% (input) replaces it.
                A placed locker can't be taken back out (the only other action on it is the
                Robux skip), so it is never the thing replaced.
     LEVELS   : RequestPlayerUnitLevelUp takes the SLOT, not the player -- only players on the
                plot can level. Cheapest $ per $/ball gained goes first, up to your cap.
     SELL     : every tier below your pick, bar the variants you keep. The merchant only sells
                your held item or a whole category, so each tool is equipped and sold as
                "HeldItem". The category sells would
                take keepers with them and are deliberately not wired. A locker sells for
                exactly what it cost.
     CRATES   : the pile at your conveyor's end is picked up (PickupCrateBox) and sold at your
                plot's sell NPC (SellCrate) -- two remotes, no walking once the server allows it.
     SPAWNS   : variant tokens (server-wide race, rarest first), grade tokens and potions,
                woken by the node's own Occupied attribute rather than a scan.
     UPGRADES : every cash upgrade the game ships, bought by payback: price / (income x the
                share it adds). Luck, open time and conveyor tier get a weighted share (config).

     Nothing in the dump says which remotes the server range-checks, so every action that
     might be is tried from where you stand first, confirmed on the world moving, and hopped
     to (then back) only on a miss; two hop-cured misses make that action hop first. F9 says
     which way each one went. Not wired: SkipBoxOnDropper / Skip All / Recover (dev products).

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().blueLockFarmStop() ]]

-- config ---------------------------------------------------------------------
local CALL_TIMEOUT = 8 -- an InvokeServer that hasn't returned by now is abandoned
local CONFIRM = 1.2 -- remote-first confirm window before hopping; raise on lag
local HOP_LIFT = 3 -- studs above a target to land
local HOP_SETTLE = 0.25 -- after a hop, for the position to reach the server
local HOP_CURES = 2 -- misses a hop cured, in a row, before an action hops first...
local HOP_PROBE = 10 -- ...and while hopping, every Nth call tries remote again

local ROLL_SLACK = 0.05 -- on top of the game's own roll cooldown
local ROLL_TIMEOUT = 2 -- waiting for RollId to move after a roll
-- minutes of income: a "beats my weakest" buy may cost at most this much, and a wanted but
-- unaffordable locker is held on the belt only if income covers it this fast
local MAX_WAIT = 30
local SMART_STOCK = 3 -- "beats my weakest slot" buys stop at this many unplaced lockers

local ROSTER_GAP = 0.3 -- between locker passes that did something
local ROSTER_IDLE = 2 -- ...and that didn't
local LEVEL_GAP = 0.12 -- between level-ups; the dump shows 0.1-0.2s landing fine
local LEVEL_BATCH = 25 -- level-ups per pass before re-planning
local EQUIP_GAP = 3.5 -- the game's own Equip Best button refuses faster than 3s
local EQUIP_SETTLE = 1 -- after Equip Best, for the slots to replicate
-- percent: a locker replaces your weakest player (and gets bought for it) only if its
-- average pull beats that player by this much at your cap
local MARGIN = 25
local SELL_BATCH = 10 -- tools sold per pass

local CRATE_GAP = 3 -- between pile checks; a pure attribute read
local CRATE_MIN = 20 -- balls in the pile before it's worth two remotes

local SPAWN_CONFIRM = 0.8 -- tokens are a race: shorter remote-first window
local SPAWN_IDLE = 5 -- safety-net sweep when no Occupied signal fired

local UPG_GAP = 2
local MAX_PAYBACK = 20 -- minutes; an upgrade that pays back slower waits
local LUCK_WEIGHT = 0.5 -- luck share counts as this much income share (can't be priced)
local OPEN_WEIGHT = 0.5 -- open-time share saved, same idea
local ROLL_WEIGHT = 0.5 -- conveyor tier: expected roll value share, same idea
local GENERIC_GAIN = 0.02 -- an upgrade this script has no model for

local AFK_BEAT = 60 -- the game's own AntiAfk sends you to a reserved server after 15 min idle
local REJOIN_DELAY = 3
local WATCHDOG = 25
local DASH_GAP = 1

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local player = Players.LocalPlayer

if getgenv and getgenv().blueLockFarmStop then
	getgenv().blueLockFarmStop() -- re-running must not stack a second panel or loop
end

local function log(msg)
	print("[bluelock] " .. msg)
end

local pending -- last line a loop wants on the status row; drained on Heartbeat
local function say(msg)
	pending = msg
end

local mark, markAt = "idle", os.clock()
local function step(what)
	mark, markAt = what, os.clock()
end

-- pcall doesn't bound a yield: an InvokeServer that never returns parks the thread for good.
local function callTimed(remote, timeout, ...)
	if not remote then
		return nil
	end
	local args = table.pack(...)
	local done, res
	task.spawn(function()
		local ok, a, b = pcall(function()
			return remote:InvokeServer(table.unpack(args, 1, args.n))
		end)
		res = ok and { a, b } or false
		done = true
	end)
	local deadline = os.clock() + (timeout or CALL_TIMEOUT)
	repeat
		task.wait()
	until done or os.clock() > deadline
	return done and res or nil
end

local function waitFor(fn, timeout)
	local deadline = os.clock() + timeout
	repeat
		local ok, yes = pcall(fn)
		if ok and yes then
			return true
		end
		task.wait()
	until os.clock() > deadline
	return false
end

-- world ----------------------------------------------------------------------
-- The game's own modules, required rather than copied: prices, odds, the $/ball formula and
-- the save-data mirror all move with a balance patch.
local function shared(...)
	local ok, mod = pcall(function(...)
		local at = ReplicatedStorage
		for _, name in ipairs({ ... }) do
			at = at:WaitForChild(name, 10)
		end
		return require(at)
	end, ...)
	return ok and type(mod) == "table" and mod or nil
end

local Data = shared("Client", "Data", "ClientDataManager")
local BoxService = shared("Shared", "Services", "BoxService")
local UnitService = shared("Shared", "Services", "PlayerUnitService")
local InventoryService = shared("Shared", "Services", "InventoryService")
local CurrencyService = shared("Shared", "Services", "CurrencyService")
local ItemService = shared("Shared", "Services", "ItemService")
local Boxes = shared("Shared", "Core", "Storage", "Game", "BoxesLibrary")
local Variants = shared("Shared", "Core", "Storage", "Game", "VariantsLibrary")
local Upgrades = shared("Shared", "Core", "Storage", "Game", "UpgradesLibrary")
local Collectables = shared("Shared", "Core", "Storage", "Game", "CollectableObjectsLibrary")
local Constants = shared("Shared", "Constants")
local HitboxUtils = shared("Shared", "Utility", "HitboxUtils")
local NumberUtils = shared("Shared", "Utility", "NumberUtils")

if not (Data and BoxService and UnitService and InventoryService and Boxes and Variants and Upgrades and Constants and HitboxUtils) then
	warn("[bluelock] this isn't Blue Lock Farm, or the client hasn't booted")
	return
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local R = setmetatable({}, {
	__index = function(t, name)
		local r = Remotes and Remotes:FindFirstChild(name)
		rawset(t, name, r)
		return r
	end,
})

local function data()
	return Data.GetData()
end
local function cash()
	local d = data()
	return d and d.Currency and d.Currency.Cash or 0
end
local function money(n)
	local ok, s = pcall(NumberUtils.AbbreviateNumber, n)
	return "$" .. (ok and s or tostring(math.floor(n)))
end

-- Your plot's parts by tag + the game's own getInstPlot, never by path.
local function mine(inst)
	local ok, plot = pcall(HitboxUtils.getInstPlot, inst)
	return ok and plot ~= nil and plot.Name == player.Name
end
local function tagged(tag)
	for _, v in ipairs(CollectionService:GetTagged(tag)) do
		if mine(v) then
			return v
		end
	end
end
local function posOf(inst)
	if not inst then
		return nil
	end
	local ok, p = pcall(function()
		return inst:IsA("Model") and inst:GetPivot().Position or inst.Position
	end)
	return ok and p or nil
end

local function slots()
	local out = {}
	for _, p in ipairs(CollectionService:GetTagged("DropperBasePart")) do
		if p:GetAttribute("Unlocked") and mine(p) then
			table.insert(out, p)
		end
	end
	return out
end

local function backpack()
	return player:FindFirstChildOfClass("Backpack")
end
local function findTool(match)
	for _, holder in ipairs({ backpack(), player.Character }) do
		for _, t in ipairs(holder and holder:GetChildren() or {}) do
			if t:IsA("Tool") and match(t) then
				return t
			end
		end
	end
end

local function boxCount(box, variant)
	local inv = data().Inventory
	local b = inv and inv.Boxes and inv.Boxes[box]
	return b and b[variant] and b[variant].Amount or 0
end
local function crates()
	return data().Crates or {}
end

-- value ------------------------------------------------------------------------
-- $/ball is the game's own GetPlayerUnitCashPerDrop. Everything is compared at the level
-- auto-upgrade will take it to, so a fresh level-1 pull isn't judged against a levelled one.
local roster = { open = false, place = false, level = false, equip = false, sellLockers = false, sellUnits = false, cap = 10 }

local function value(name, variant, level, grade)
	local ok, v = pcall(UnitService.GetPlayerUnitCashPerDrop, nil, {
		PlayerUnitName = name,
		PlayerUnitVariant = variant or "Normal",
		PlayerUnitLevel = level or 1,
		PlayerUnitGrade = grade,
	})
	return ok and v or 0
end
local function target()
	return roster.level and roster.cap or 1
end
local function potential(name, variant, level, grade)
	return value(name, variant, math.max(level or 1, target()), grade)
end
local function slotPotential(p)
	return potential(p:GetAttribute("PlayerUnitName"), p:GetAttribute("PlayerUnitVariant"), p:GetAttribute("PlayerUnitLevel"), p:GetAttribute("PlayerUnitGrade"))
end

-- A locker's unit is its box's PlayerUnits by Chance (sums to 100); its variant is the locker's.
local function boxEV(box, variant)
	local b = Boxes[box]
	if not b then
		return 0
	end
	local ev = 0
	for unit, u in pairs(b.PlayerUnits) do
		ev = ev + (u.Chance or 0) / 100 * value(unit, variant, target())
	end
	return ev
end
-- boxEV reads Chance as a percentage; the library builds it from a table that sums to 100.
-- A patch that changes that would skew every locker ranking quietly, so say so once.
for name, b in pairs(Boxes) do
	local sum = 0
	for _, u in pairs(b.PlayerUnits or {}) do
		sum = sum + (u.Chance or 0)
	end
	if math.abs(sum - 100) > 0.5 then
		warn(("[bluelock] %s unit chances sum to %s, not 100 -- locker values are off"):format(name, sum))
	end
end

local function weakest()
	local best, bestV
	for _, p in ipairs(slots()) do
		if p:GetAttribute("Type") == "PlayerUnit" then
			local v = slotPotential(p)
			if not bestV or v < bestV then
				best, bestV = p, v
			end
		end
	end
	return best, bestV
end

local function incomePerSec()
	local total = 0
	for _, p in ipairs(slots()) do
		if p:GetAttribute("Type") == "PlayerUnit" then
			total = total
				+ value(p:GetAttribute("PlayerUnitName"), p:GetAttribute("PlayerUnitVariant"), p:GetAttribute("PlayerUnitLevel"), p:GetAttribute("PlayerUnitGrade"))
		end
	end
	local ok, mult = pcall(CurrencyService.GetCurrencyMultiplier, player, "Cash")
	return total / (Constants.DROP_COOLDOWN or 4) * (ok and mult or 1)
end

-- Every locker stack in the bag: { box, variant, amount, ev }.
local function lockers()
	local out = {}
	for box, variants in pairs((data().Inventory or {}).Boxes or {}) do
		for variant, v in pairs(variants) do
			if (v.Amount or 0) > 0 then
				table.insert(out, { box = box, variant = variant, amount = v.Amount, ev = boxEV(box, variant) })
			end
		end
	end
	return out
end
local function lockersWaiting()
	local n = 0
	for _, l in ipairs(lockers()) do
		n = n + l.amount
	end
	return n
end

local function emptySlot()
	for _, p in ipairs(slots()) do
		local t = p:GetAttribute("Type")
		if t ~= "Box" and t ~= "PlayerUnit" then
			return p
		end
	end
end

-- A locker is worth your weakest slot when its average pull beats that player by MARGIN%,
-- both at your cap. Every player scales by the same 1.18^level, so the level drops out.
-- One rule for the roll and the placer, so nothing gets bought that then never goes down.
local function beats(box, variant, w)
	return w ~= nil and Boxes[box] ~= nil and boxEV(box, variant) >= slotPotential(w) * (1 + MARGIN / 100)
end
-- Price brake and hold limit: MAX_WAIT minutes of income.
local function withinWait(amount)
	return amount <= incomePerSec() * MAX_WAIT * 60
end

-- Tiers in the game's own Index order, variants rarest last; both shown by display name.
-- rank() is the position in that order -- what "at least" and "below" compare.
local TIERS, VARIANTS, tierKey, variantKey = {}, {}, {}, {}
local tierRank, variantRank = {}, {}
do
	local list = {}
	for key, b in pairs(Boxes) do
		table.insert(list, { key = key, name = b.DisplayName or key, rank = b.Index or 0 })
	end
	table.sort(list, function(a, b)
		return a.rank < b.rank
	end)
	for i, e in ipairs(list) do
		table.insert(TIERS, e.name)
		tierKey[e.name] = e.key
		tierRank[e.key] = i
	end
	list = {}
	for key, v in pairs(Variants) do
		table.insert(list, { key = key, name = v.DisplayName or key, rank = v.Multiplier or 0 })
	end
	table.sort(list, function(a, b)
		return a.rank < b.rank
	end)
	for i, e in ipairs(list) do
		table.insert(VARIANTS, e.name)
		variantKey[e.name] = e.key
		variantRank[e.key] = i
	end
end
local ANY, NOTHING = "Any", "Nothing"

-- movement -------------------------------------------------------------------
local move = { tp = true, back = true, park = false }

local function root()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function humanoid()
	local c = player.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end
local function hop(pos)
	local c = player.Character
	if not (c and pos) then
		return false
	end
	local ok = pcall(function()
		c:PivotTo(CFrame.new(pos + Vector3.new(0, HOP_LIFT, 0)))
	end)
	waitFor(function()
		return not player.GameplayPaused
	end, 3)
	return ok
end
local function goHome(back)
	if move.park then
		local station = posOf(tagged("RollConveyorPart"))
		if station then
			return hop(station + Vector3.new(0, 0, 6))
		end
	end
	if move.back and back and player.Character then
		pcall(function()
			player.Character:PivotTo(back)
		end)
	end
end

-- Everything that moves you or swaps the held tool shares one claim, re-entrant for the
-- thread holding it (a sell holds it, and its hop fallback claims again). Returns whether it RAN.
local owner
local function claim(fn)
	local me = coroutine.running()
	if owner == me then
		fn()
		return true
	end
	if owner then
		return false
	end
	owner = me
	local ok, err = pcall(fn)
	owner = nil
	if not ok then
		warn("[bluelock] claimed work failed: " .. tostring(err))
	end
	return true
end

-- One shape for every remote that might be range-checked: fire from where you are, confirm
-- on the world moving, on a miss hop next to `where`, fire again, go home. Returns true
-- (landed), false (refused either way), nil (someone else is moving you -- try later).
local route = {}
local function act(key, where, fire, confirm, timeout)
	local r = route[key]
	if not r then
		r = { hopFirst = false, cured = 0, n = 0 }
		route[key] = r
	end
	r.n = r.n + 1
	local remoteFirst = not r.hopFirst or r.n % HOP_PROBE == 0
	if remoteFirst then
		pcall(fire)
		if waitFor(confirm, timeout or CONFIRM) then
			if r.hopFirst then
				r.hopFirst = false
				log(key .. " works from anywhere again")
			end
			r.cured = 0
			return true
		end
	end
	if not (move.tp and where) then
		return false
	end
	local ok = false
	local ran = claim(function()
		local rt = root()
		local back = rt and rt.CFrame
		if not hop(where) then
			return
		end
		task.wait(HOP_SETTLE)
		local okC, early = pcall(confirm)
		if not (okC and early) then -- a late answer to the remote try must not be paid twice
			pcall(fire)
		end
		ok = waitFor(confirm, timeout or CONFIRM)
		goHome(back)
	end)
	if not ran then
		return nil
	end
	if ok and remoteFirst then
		r.cured = r.cured + 1
		if r.cured >= HOP_CURES and not r.hopFirst then
			r.hopFirst = true
			log(key .. " is range-checked -- hopping first from now on")
		end
	end
	return ok
end

-- Equip, run, unequip -- inside the claim, because two loops holding different tools
-- would each sell the other's.
local function holding(tool, fn)
	return claim(function()
		local hum = humanoid()
		if not (hum and tool and tool.Parent) then
			return
		end
		pcall(hum.EquipTool, hum, tool)
		waitFor(function()
			return tool.Parent == player.Character
		end, 1)
		fn()
		pcall(hum.UnequipTools, hum)
	end)
end

-- loops ----------------------------------------------------------------------
-- A generation counter per loop, in the loop's own table. Only the current generation may
-- end itself; alive() lets a long pass bail mid-list.
local loops = {}
local function looper(name, body, gapFn)
	local L = { name = name, on = false, gen = 0, inBody = false }
	function L.set(on)
		L.on = on
		L.gen = L.gen + 1
		if not on then
			return
		end
		local mine_ = L.gen
		task.spawn(function()
			local function alive()
				return L.on and L.gen == mine_
			end
			while alive() do
				L.inBody = true
				local ok, err = pcall(body, alive)
				L.inBody = false
				if not ok then
					warn(("[bluelock] %s loop: %s"):format(name, tostring(err)))
				end
				if alive() then
					task.wait(gapFn())
				end
			end
		end)
	end
	table.insert(loops, L)
	return L
end

local stats = { rolls = 0, bought = 0, opened = 0, levels = 0, placed = 0, replaced = 0, soldL = 0, soldU = 0, crates = 0, spawns = 0, lost = 0, upgrades = 0 }
local reserve = 0 -- every spender keeps this much cash

-- roll -----------------------------------------------------------------------
-- saving: the price of a pull Buy matches is holding until income covers it (MAX_WAIT at
-- most). Levels and upgrades leave it alone on top of your reserve, or they'd spend every
-- dollar the hold is waiting for. A Buy-off stop never saves: it has no end.
-- minTier / minVariant: game keys, nil = Any.
local roll = { buy = true, minTier = nil, minVariant = nil, either = false, smart = false, seenId = nil, judged = false, lastRoll = 0, saving = 0 }

-- "At least this tier" / "at least this variant"; both on Any matches nothing.
local function matches(box, variant)
	local mt, mv = roll.minTier, roll.minVariant
	if not (mt or mv) then
		return false
	end
	local t = mt ~= nil and (tierRank[box] or 0) >= tierRank[mt]
	local v = mv ~= nil and (variantRank[variant] or 0) >= variantRank[mv]
	if roll.either then
		return t or v
	end
	return (t or not mt) and (v or not mv)
end
do -- self-check: ranks follow the game's own order (Team Z lowest, Normal lowest)
	local low, high = tierKey[TIERS[1]], tierKey[TIERS[#TIERS]]
	roll.minTier, roll.minVariant = tierKey[TIERS[2]], nil
	assert(not matches(low, "Normal") and matches(high, "Normal"), "min tier compare")
	roll.minTier, roll.minVariant = nil, variantKey[VARIANTS[2]]
	assert(not matches(low, variantKey[VARIANTS[1]]) and matches(low, variantKey[VARIANTS[#VARIANTS]]), "min variant compare")
	roll.minTier, roll.minVariant = nil, nil
	assert(not matches(high, variantKey[VARIANTS[#VARIANTS]]), "Any + Any buys nothing")
end

local function wanted(box, variant)
	if matches(box, variant) then
		return true
	end
	if not roll.smart then
		return false
	end
	-- Only lockers the placer would actually use count toward the stock; a hunted keeper
	-- that sits in the bag mustn't switch the income rule off.
	local empty, w = emptySlot() ~= nil, weakest()
	local stock = 0
	for _, l in ipairs(lockers()) do
		if empty or beats(l.box, l.variant, w) then
			stock = stock + l.amount
		end
	end
	-- The price brake is for replacements only: a hunted locker is one you asked for, and an
	-- empty slot earns nothing (an empty plot's income is 0, which would brake every buy).
	if stock >= SMART_STOCK then
		return false
	end
	return empty or (beats(box, variant, w) and withinWait(BoxService.GetBoxPrice(box, variant)))
end

-- "bought", "skip", "match" (Buy off: stop here for you), "poor" (can't afford), "full",
-- or false (the server said no)
local function judge(part)
	local box, variant = part:GetAttribute("BoxName"), part:GetAttribute("Variant") or "Normal"
	if not roll.buy then
		return box and matches(box, variant) and "match" or "skip", box, variant
	end
	if not (box and wanted(box, variant)) then
		return "skip"
	end
	local price = BoxService.GetBoxPrice(box, variant)
	if cash() - price < reserve then
		return "poor", box, variant, price
	end
	if not (BoxService.HasBoxInventorySpace(player, 1) and InventoryService.HasInventorySpace(player, 1)) then
		return "full", box, variant
	end
	local before = boxCount(box, variant)
	step("buy " .. box .. " " .. variant)
	local ok = act("buy", posOf(part), function()
		R.PurchaseConveyorRoll:FireServer()
	end, function()
		return boxCount(box, variant) > before
	end)
	if ok then
		stats.bought = stats.bought + 1
		log(("bought %s %s for %s"):format(variant, box, money(price)))
		return "bought", box, variant
	end
	return false, box, variant
end

local rollLoop = looper("roll", function()
	local part = tagged("RollConveyorPart")
	if not part then
		say("no roll station on your plot yet")
		return
	end
	if player:GetAttribute("TutorialConveyorLock") then
		say("finish the game's tutorial first -- the belt is locked")
		return
	end
	local id = part:GetAttribute("RollId")
	if id ~= roll.seenId then
		roll.seenId, roll.judged, roll.heldCount = id, false, nil
	end
	if not roll.judged then
		roll.saving = 0
		local verdict, box, variant, price = judge(part)
		local short = verdict == "poor" and price + reserve - cash()
		if verdict == "match" then
			-- No saving here: this hold has no end until you buy by hand, and reserving its
			-- price froze every level-up behind a 400M B11 Overflow nobody was buying.
			-- Buy matches is off: the belt stops on your pick and waits. Buying it by hand
			-- moves your locker count (the RollId doesn't), and that's when rolling resumes.
			local have = boxCount(box, variant)
			if not roll.heldCount then
				roll.heldCount = have
				log(("%s %s on the belt -- stopped rolling until you buy it"):format(variant, box))
			end
			-- Follow the count DOWN: Auto place / Auto sell can take one of these out of the
			-- bag while you wait, and then your buy only brings it back level -- never above.
			roll.heldCount = math.min(roll.heldCount or have, have)
			if have <= roll.heldCount then
				say(("%s %s on the belt -- buy it to keep rolling"):format(variant, box))
				return
			end
		elseif short and withinWait(short) then
			roll.saving = price
			say(("holding %s %s on the belt -- %s short"):format(variant, box, money(short)))
			return
		elseif verdict == "full" then
			say("locker inventory full -- rolling on, buying nothing")
		end
		roll.judged = true
	end
	local cd = BoxService.GetConveyorRollCooldown(player) + ROLL_SLACK
	local untilT = part:GetAttribute("RollCooldownUntil")
	local wait_ = math.max(roll.lastRoll + cd - os.clock(), untilT and untilT - workspace:GetServerTimeNow() or 0)
	if wait_ > 0 then
		task.wait(wait_)
	end
	step("roll")
	roll.lastRoll = os.clock()
	R.RequestConveyorRoll:FireServer()
	if waitFor(function()
		return part:GetAttribute("RollId") ~= id
	end, ROLL_TIMEOUT) then
		stats.rolls = stats.rolls + 1
	end
end, function()
	return 0.05
end)

-- lockers --------------------------------------------------------------------
-- One thread for the whole roster, in the order the request asks for: open -> level ->
-- Equip Best -> place -> sell. Two threads would have Equip Best moving a player the sell
-- pass is holding, so they don't get two.
local sell = { below = nil, keep = {}, guard = true } -- below: tier key, nil = sell nothing
local lastEquip = -math.huge

local function openReady(alive)
	local did = false
	for _, p in ipairs(slots()) do
		if not alive() then
			break
		end
		if p:GetAttribute("Type") == "Box" and BoxService.IsBoxReady(p:GetAttribute("BoxName"), p:GetAttribute("PlacedAt"), p:GetAttribute("Variant")) then
			step("open slot " .. p.Name)
			local res
			local ok = act("open", p.Position, function()
				res = callTimed(R.OpenBoxOnDropper, CALL_TIMEOUT, p)
			end, function()
				return p:GetAttribute("Type") == "PlayerUnit"
			end)
			if ok then
				stats.opened = stats.opened + 1
				did = true
				log(("opened slot %s: %s %s"):format(p.Name, tostring(p:GetAttribute("PlayerUnitVariant")), tostring(p:GetAttribute("PlayerUnitName") or (res and res[1]))))
			end
		end
	end
	return did
end

local function levelUp(alive)
	local cands = {}
	local maxL = math.min(roster.cap, Constants.MaxPlayerUnitLevel or 50)
	for _, p in ipairs(slots()) do
		local name = p:GetAttribute("PlayerUnitName")
		local lvl = p:GetAttribute("PlayerUnitLevel") or 1
		if p:GetAttribute("Type") == "PlayerUnit" and name and lvl < maxL then
			local variant, grade = p:GetAttribute("PlayerUnitVariant"), p:GetAttribute("PlayerUnitGrade")
			local cost = UnitService.GetLevelUpgradeCost(player, name, variant, lvl + 1)
			local gain = value(name, variant, lvl + 1, grade) - value(name, variant, lvl, grade)
			if cost and gain > 0 then
				table.insert(cands, { p = p, lvl = lvl, cost = cost, ratio = cost / gain })
			end
		end
	end
	table.sort(cands, function(a, b)
		return a.ratio < b.ratio
	end)
	local n, why = 0, nil
	for _, c in ipairs(cands) do
		if n >= LEVEL_BATCH or not alive() then
			break
		end
		local label = ("slot %s (%s L%d -> %d, %s)"):format(c.p.Name, tostring(c.p:GetAttribute("PlayerUnitName")), c.lvl, c.lvl + 1, money(c.cost))
		if cash() - c.cost >= reserve + roll.saving then
			step("level " .. label)
			local ok = act("level", c.p.Position, function()
				R.RequestPlayerUnitLevelUp:FireServer(c.p)
			end, function()
				return (c.p:GetAttribute("PlayerUnitLevel") or 1) > c.lvl
			end)
			if ok then
				n = n + 1
				stats.levels = stats.levels + 1
				task.wait(LEVEL_GAP)
			else
				why = why or ("%s: %s"):format(label, ok == nil and "busy teleporting elsewhere" or "server didn't take it")
			end
		elseif cash() - c.cost >= reserve then
			why = why or ("%s: saving %s for the locker held on the belt"):format(label, money(roll.saving))
		else
			why = why or ("%s: short %s"):format(label, money(c.cost + reserve - cash()))
		end
	end
	-- Say why a pass levelled nothing, once per new reason -- "it just doesn't level" otherwise
	-- has nothing in F9 to go on.
	if n == 0 and why and why ~= roster.lastWhy then
		roster.lastWhy = why
		log("not levelling -- " .. why)
		say("not levelling -- " .. why)
	elseif n > 0 then
		roster.lastWhy = nil
	end
	return n > 0
end

-- The game's Equip Best ranks by $/ball NOW; this script ranks at your level cap. They
-- disagree about a fresh level-1 pull, and Equip Best would bench it -- in the bag, where it
-- can't be levelled. So it fires only when some bag player beats your weakest slot both ways
-- (or a slot is empty), i.e. only swaps this script would make itself.
local disagreeLogged = {}
local function equipAgrees()
	local bag = {}
	for guid, u in pairs(data().PlayerUnits or {}) do
		if not u.Equipped then
			bag[guid] = u
		end
	end
	if next(bag) == nil then
		return false
	end
	if emptySlot() then
		return true, "a slot is empty"
	end
	-- The slot Equip Best would give up is the one lowest RIGHT NOW -- usually a fresh pull.
	-- Both tests are against that same slot, or a bag player that only beats some other slot
	-- at the cap would still get the fresh pull benched.
	local low, lowNow
	for _, p in ipairs(slots()) do
		if p:GetAttribute("Type") == "PlayerUnit" then
			local now = value(p:GetAttribute("PlayerUnitName"), p:GetAttribute("PlayerUnitVariant"), p:GetAttribute("PlayerUnitLevel"), p:GetAttribute("PlayerUnitGrade"))
			if not lowNow or now < lowNow then
				low, lowNow = p, now
			end
		end
	end
	if not low then
		return false -- every slot is a locker opening; nothing to swap
	end
	local lowPot = slotPotential(low)
	for guid, u in pairs(bag) do
		local now = value(u.PlayerUnitName, u.Variant, u.Level, u.Grade)
		local pot = potential(u.PlayerUnitName, u.Variant, u.Level, u.Grade)
		if now > lowNow and pot > lowPot then
			return true, ("%s %s L%d beats slot %s (%s)"):format(tostring(u.Variant), u.PlayerUnitName, u.Level or 1, low.Name, tostring(low:GetAttribute("PlayerUnitName")))
		elseif now > lowNow and not disagreeLogged[guid] then
			disagreeLogged[guid] = true
			log(("held Equip Best: it would swap %s %s (L%d) in for slot %s (%s), which is better at level %d"):format(
				tostring(u.Variant),
				u.PlayerUnitName,
				u.Level or 1,
				low.Name,
				tostring(low:GetAttribute("PlayerUnitName")),
				target()
			))
		end
	end
	return false
end

-- Once every slotted player is at the cap, "best now" and "best at the cap" are the same
-- ranking for the whole plot, so the game's own Equip Best can't bench a pull that's still
-- levelling -- let it arrange the plot its way, once per line-up. The signature is the
-- players, not their slots, so the game's own shuffle doesn't read as a new line-up.
local settledSig
local function settled()
	local maxL = math.min(roster.cap, Constants.MaxPlayerUnitLevel or 50)
	local who = {}
	for _, p in ipairs(slots()) do
		if p:GetAttribute("Type") == "PlayerUnit" then
			local lvl = p:GetAttribute("PlayerUnitLevel") or 1
			if roster.level and lvl < maxL then
				return nil -- still levelling: the gate alone decides
			end
			table.insert(who, ("%s/%s/%d"):format(tostring(p:GetAttribute("PlayerUnitName")), tostring(p:GetAttribute("PlayerUnitVariant")), lvl))
		end
	end
	if #who == 0 then
		return nil
	end
	table.sort(who)
	return table.concat(who, ";")
end

-- The one swap Equip Best can never make: a bag player better only at the cap (a fresh L1
-- pull that got benched) loses on $/ball now, so the game's ranking never puts it back --
-- and in the bag it can't level. Pick up the weakest slot and place it there by hand.
local function swapIn()
	local w, wv = weakest()
	if not w or emptySlot() or not InventoryService.HasInventorySpace(player, 1) then
		return false -- an empty slot is Equip Best's job
	end
	local guid, u, uv
	for g, x in pairs(data().PlayerUnits or {}) do
		if not x.Equipped then
			local v = potential(x.PlayerUnitName, x.Variant, x.Level, x.Grade)
			if v > wv and (not uv or v > uv) then
				guid, u, uv = g, x, v
			end
		end
	end
	if not guid then
		return false
	end
	local label = ("%s %s L%d"):format(tostring(u.Variant), u.PlayerUnitName, u.Level or 1)
	step("swap in " .. label)
	if not act("remove", w.Position, function()
		R.RemovePlayerUnitFromDropper:FireServer(w)
	end, function()
		return w:GetAttribute("Type") ~= "PlayerUnit"
	end) then
		return false
	end
	local function fire()
		R.PlacePlayerUnitOnDropper:FireServer(w, guid)
	end
	local function landed()
		return w:GetAttribute("Type") == "PlayerUnit" and w:GetAttribute("PlayerUnitName") == u.PlayerUnitName
	end
	-- The game's Place reads the held tool, like lockers; hold it in case the server checks.
	local tool = findTool(function(t)
		return t:GetAttribute("InventoryKey") == guid
	end)
	local ok
	if tool then
		holding(tool, function()
			ok = act("place", w.Position, fire, landed)
		end)
	else
		ok = act("place", w.Position, fire, landed)
	end
	if ok then
		log(("swapped %s onto slot %s -- better at level %d than what was there"):format(label, w.Name, target()))
	end
	return ok == true
end

local function equipBest()
	if os.clock() - lastEquip < EQUIP_GAP then
		return false
	end
	if swapIn() then
		lastEquip = os.clock()
		return true
	end
	local yes, why = equipAgrees()
	if not yes then
		local sig = settled()
		if not sig or sig == settledSig then
			return false
		end
		settledSig = sig
		yes, why = true, ("every slotted player is at level %d -- letting the game arrange the plot"):format(target())
	end
	step("equip best")
	log("Equip Best -- " .. why)
	lastEquip = os.clock()
	pcall(function()
		R.EquipBestPlayerUnits:FireServer()
	end)
	task.wait(EQUIP_SETTLE)
	return true
end

-- An empty slot loses nothing, so it takes the richest locker. A replacement takes the
-- richest locker that beats your weakest player by MARGIN%.
local function placeLocker()
	local bag = lockers()
	if #bag == 0 then
		return false
	end
	local slot, replacing, pick = emptySlot(), false, nil
	if slot then
		for _, l in ipairs(bag) do
			if not pick or l.ev > pick.ev then
				pick = l
			end
		end
	else
		local w = weakest()
		for _, l in ipairs(bag) do
			if beats(l.box, l.variant, w) and (not pick or l.ev > pick.ev) then
				pick = l
			end
		end
		if not (pick and InventoryService.HasInventorySpace(player, 1)) then
			return false
		end
		step("free slot " .. w.Name)
		if not act("remove", w.Position, function()
			R.RemovePlayerUnitFromDropper:FireServer(w)
		end, function()
			return w:GetAttribute("Type") ~= "PlayerUnit"
		end) then
			return false
		end
		slot, replacing = w, true
	end
	local box, variant = pick.box, pick.variant
	step(("place %s %s on slot %s"):format(variant, box, slot.Name))
	local function fire()
		R.PlaceBoxOnDropper:FireServer(slot, box, variant)
	end
	local function landed()
		return slot:GetAttribute("Type") == "Box"
	end
	-- The game's own Place reads the held tool; the remote carries the names anyway, but
	-- holding the matching locker costs nothing and covers a server that checks.
	local tool = findTool(function(t)
		return t:GetAttribute("InventoryType") == "Box" and t.Name == box and (t:GetAttribute("Variant") or "Normal") == variant
	end)
	local ok
	if tool then
		holding(tool, function()
			ok = act("place", slot.Position, fire, landed)
		end)
	else
		ok = act("place", slot.Position, fire, landed)
	end
	if ok then
		stats.placed = stats.placed + 1
		stats.replaced = stats.replaced + (replacing and 1 or 0)
		log(("placed %s %s on slot %s%s"):format(variant, box, slot.Name, replacing and " (replaced the weakest)" or ""))
	end
	return ok == true
end

local function sellable(tier, variant, v, wv)
	if not (tier and sell.below and (tierRank[tier] or math.huge) < tierRank[sell.below]) or sell.keep[variant or "Normal"] then
		return false
	end
	return not (sell.guard and wv and v > wv)
end

local function sellTool(tool, gone)
	local where = posOf(CollectionService:GetTagged("MerchantHitbox")[1])
	local ok
	holding(tool, function()
		ok = act("sell", where, function()
			R.MerchantSell:FireServer("HeldItem")
		end, gone)
	end)
	return ok
end

local function sellPass(alive)
	local _, wv = weakest()
	local n = 0
	local bp = backpack()
	for _, tool in ipairs(bp and bp:GetChildren() or {}) do
		if n >= SELL_BATCH or not alive() then
			break
		end
		local kind = tool:GetAttribute("InventoryType")
		if kind == "Box" and roster.sellLockers then
			local box, variant = tool.Name, tool:GetAttribute("Variant") or "Normal"
			if sellable(box, variant, boxEV(box, variant), wv) then
				local before = boxCount(box, variant)
				step("sell locker " .. variant .. " " .. box)
				if sellTool(tool, function()
					return boxCount(box, variant) < before
				end) then
					n = n + 1
					stats.soldL = stats.soldL + 1
				end
			end
		elseif kind == "PlayerUnit" and roster.sellUnits then
			local guid = tool:GetAttribute("InventoryKey")
			local u = guid and (data().PlayerUnits or {})[guid]
			if u and not u.Equipped then
				local tier = BoxService.GetBoxForPlayerUnit(u.PlayerUnitName)
				if sellable(tier, u.Variant, potential(u.PlayerUnitName, u.Variant, u.Level, u.Grade), wv) then
					step("sell player " .. u.PlayerUnitName)
					if sellTool(tool, function()
						return (data().PlayerUnits or {})[guid] == nil
					end) then
						n = n + 1
						stats.soldU = stats.soldU + 1
					end
				end
			end
		end
	end
	return n > 0
end

local rosterDid = false
local rosterLoop = looper("lockers", function(alive)
	rosterDid = false
	if roster.open and openReady(alive) then
		rosterDid = true
	end
	if roster.level and alive() and levelUp(alive) then
		rosterDid = true
	end
	if roster.equip and alive() and equipBest() then -- before place: judge the weakest on the best team
		rosterDid = true
	end
	if roster.place and alive() then
		if placeLocker() then
			rosterDid = true
		end
	end
	if (roster.sellLockers or roster.sellUnits) and alive() and sellPass(alive) then
		rosterDid = true
	end
end, function()
	return rosterDid and ROSTER_GAP or ROSTER_IDLE
end)

local function rosterSync()
	rosterLoop.set(roster.open or roster.place or roster.level or roster.equip or roster.sellLockers or roster.sellUnits)
end

-- crates ---------------------------------------------------------------------
local crate = { min = CRATE_MIN }

local crateLoop = looper("crates", function(alive)
	local pile = tagged("ConveyorCollectPart")
	if pile and (pile:GetAttribute("PendingBallCount") or 0) >= crate.min then
		if InventoryService.HasInventorySpace(player, 1) then
			local before = 0
			for _ in pairs(crates()) do
				before = before + 1
			end
			step("pick up crate")
			act("pickup", posOf(pile), function()
				R.PickupCrateBox:FireServer(pile)
			end, function()
				local n = 0
				for _ in pairs(crates()) do
					n = n + 1
				end
				return n > before
			end)
		else
			say("inventory full -- can't pick up the crate pile")
		end
	end
	local npc = posOf(tagged("SellNPC"))
	for guid in pairs(crates()) do
		if not alive() then
			break
		end
		step("sell crate")
		local function fire()
			R.SellCrate:FireServer(guid)
		end
		local function gone()
			return crates()[guid] == nil
		end
		local tool = findTool(function(t)
			return t:GetAttribute("InventoryKey") == guid
		end)
		local ok
		if tool then -- the game's own sell reads the held crate; the guid rides along regardless
			holding(tool, function()
				ok = act("crate sell", npc, fire, gone)
			end)
		else
			ok = act("crate sell", npc, fire, gone)
		end
		if ok then
			stats.crates = stats.crates + 1
		end
	end
end, function()
	return CRATE_GAP
end)

-- spawns ---------------------------------------------------------------------
-- Variant tokens rank by their variant's multiplier (a server-wide race, so first); the
-- collectables by what they're worth to a farm.
local COLLECT_RANK = { CashPotion = 3, LuckPotion = 2, GradeToken = 1 }
local SPAWN_KINDS = { "Variant tokens" }
for key in pairs(Collectables or {}) do
	table.insert(SPAWN_KINDS, key)
end
table.sort(SPAWN_KINDS)
local spawn = { want = {}, poke = true, conns = {}, lastSweep = 0 }
for _, k in ipairs(SPAWN_KINDS) do
	spawn.want[k] = true
end

local function spawnInfo(node)
	if CollectionService:HasTag(node, "VariantTokenSpawn") then
		local v = node:GetAttribute("Variant")
		return "Variant tokens", 1000 + (Variants[v] and Variants[v].Multiplier or 0), R.CollectVariantTokenSpawn, v
	end
	local key = node:GetAttribute("ObjectKey")
	local item = Collectables and Collectables[key] and Collectables[key].ItemName
	return key, COLLECT_RANK[key] or 0, R.CollectCollectableObject, item
end

local function liveSpawns()
	local out = {}
	for _, tag in ipairs({ "VariantTokenSpawn", "CollectableObject" }) do
		for _, node in ipairs(CollectionService:GetTagged(tag)) do
			if node:IsA("BasePart") and node:GetAttribute("Occupied") == true then
				local kind, rank, remote, item = spawnInfo(node)
				if kind and spawn.want[kind] then
					table.insert(out, { node = node, rank = rank, remote = remote, item = item, kind = kind })
				end
			end
		end
	end
	table.sort(out, function(a, b)
		return a.rank > b.rank
	end)
	return out
end

local function itemAmount(item)
	if not (ItemService and item) then
		return 0
	end
	local ok, n = pcall(ItemService.GetAmountOfItem, player, item)
	if type(n) == "table" then -- the server keeps potions as { Amount = n }; the mirror may too
		n = n.Amount
	end
	return ok and tonumber(n) or 0
end

local spawnLoop = looper("spawns", function(alive)
	if not (spawn.poke or os.clock() - spawn.lastSweep > SPAWN_IDLE) then
		return
	end
	spawn.poke, spawn.lastSweep = false, os.clock()
	for _, s in ipairs(liveSpawns()) do
		if not alive() then
			break
		end
		local before = itemAmount(s.item)
		step("collect " .. tostring(s.item))
		local ok = act(s.kind == "Variant tokens" and "token" or "collectable", s.node.Position, function()
			s.remote:FireServer(s.node)
		end, function()
			return s.node:GetAttribute("Occupied") ~= true
		end, SPAWN_CONFIRM)
		if ok then
			-- Occupied clearing is also what someone else's grab looks like; the bag decides.
			if waitFor(function()
				return itemAmount(s.item) > before
			end, 1) then
				stats.spawns = stats.spawns + 1
				log("collected " .. tostring(s.item))
			else
				stats.lost = stats.lost + 1
			end
		elseif ok == nil then
			spawn.poke = true -- the claim was busy; come straight back
		end
	end
end, function()
	return 0.1
end)

local function spawnWatch(on)
	for _, c in ipairs(spawn.conns) do
		pcall(c.Disconnect, c)
	end
	table.clear(spawn.conns)
	if not on then
		return
	end
	local function poke()
		spawn.poke = true
	end
	local function watch(node)
		if node:IsA("BasePart") then
			table.insert(spawn.conns, node:GetAttributeChangedSignal("Occupied"):Connect(poke))
		end
	end
	for _, tag in ipairs({ "VariantTokenSpawn", "CollectableObject" }) do
		for _, node in ipairs(CollectionService:GetTagged(tag)) do
			watch(node)
		end
		table.insert(spawn.conns, CollectionService:GetInstanceAddedSignal(tag):Connect(function(node)
			watch(node)
			poke()
		end))
	end
	if R.VariantTokenSpawned then
		table.insert(spawn.conns, R.VariantTokenSpawned.OnClientEvent:Connect(poke))
	end
	poke()
end

-- upgrades -------------------------------------------------------------------
-- Payback = price / (income/s x the share of income this level adds). Luck, open time and
-- the conveyor tier don't pay cash directly, so their share is weighted (config).
local function amount(name, n)
	local u = Upgrades[name]
	local ok, a = pcall(u.GetAmount, n)
	return ok and a or 0
end

local function rollEV(tier)
	local ok, mult = pcall(Upgrades.ConveyorLuck.GetBoxMultipliers, tier)
	if not ok then
		return 0
	end
	local w, v = 0, 0
	for name, b in pairs(Boxes) do
		local wt = (b.Weight or 0) * (mult[name] or 0)
		w = w + wt
		v = v + wt * boxEV(name, "Normal")
	end
	return w > 0 and v / w or 0
end

local GAIN = {
	CrateCashBoost = function(n)
		return (amount("CrateCashBoost", n + 1) - amount("CrateCashBoost", n)) / (1 + amount("CrateCashBoost", n))
	end,
	PlayerUnitExpansion = function()
		return 1 / math.max(1, #slots())
	end,
	Luck = function(n)
		return LUCK_WEIGHT * (amount("Luck", n + 1) - amount("Luck", n)) / (1 + amount("Luck", n))
	end,
	OpenTimeBoost = function(n)
		return OPEN_WEIGHT * (amount("OpenTimeBoost", n + 1) - amount("OpenTimeBoost", n))
	end,
	-- ponytail: one tier ahead only; a tier that dips (tier 5 guts Manshine City) is never
	-- bought even when the one after it would pay. Look two ahead if that ever matters.
	ConveyorLuck = function(n)
		local now = rollEV(n + 1)
		return now > 0 and ROLL_WEIGHT * (rollEV(n + 2) / now - 1) or 0
	end,
}

-- Every cash upgrade the game lists, found in its own library: the Upgrades menu's rows
-- plus the conveyor tier (a button on your plot). The polisher pair needs 11 expansions and
-- a flow this script doesn't run.
local UPG_NAMES, upgKey, upgWant = {}, {}, {}
for name, u in pairs(Upgrades) do
	if type(u) == "table" and type(u.GetPrice) == "function" and (not u.HiddenOnGui or name == "ConveyorLuck") then
		local shown = u.DisplayName or name
		table.insert(UPG_NAMES, shown)
		upgKey[shown] = name
		upgWant[name] = name ~= "WalkSpeed"
	end
end
table.sort(UPG_NAMES)

local function upgradePlan()
	local income = incomePerSec()
	local best
	for name, on in pairs(upgWant) do
		local u = Upgrades[name]
		local n = (data().Upgrades or {})[name] or 0
		if on and u and not (u.MaxPurchases and n >= u.MaxPurchases) then
			local okP, price = pcall(u.GetPrice, n)
			local gain = GAIN[name] and GAIN[name](n) or GENERIC_GAIN
			if okP and price and gain > 0 and income > 0 then
				local payback = price / (income * gain)
				if not best or payback < best.payback then
					best = { name = name, n = n, price = price, payback = payback }
				end
			end
		end
	end
	return best
end

local upgLoop = looper("upgrades", function()
	local best = upgradePlan()
	if not best then
		return
	end
	if best.payback > MAX_PAYBACK * 60 then
		say(("next upgrade %s pays back in %dm -- waiting"):format(best.name, math.floor(best.payback / 60)))
		return
	end
	if cash() - best.price < reserve + roll.saving then
		return
	end
	step("upgrade " .. best.name)
	R.PurchaseUpgrade:FireServer(best.name)
	if waitFor(function()
		return ((data().Upgrades or {})[best.name] or 0) > best.n
	end, CONFIRM) then
		stats.upgrades = stats.upgrades + 1
		log(("upgraded %s to %d for %s (pays back in %ds)"):format(best.name, best.n + 1, money(best.price), math.floor(best.payback)))
	end
end, function()
	return UPG_GAP
end)

-- anti-afk -------------------------------------------------------------------
-- The game's own AntiAfk fires RejoinRemote after 15 minutes without input, which puts you
-- in a fresh RESERVED server -- and this script doesn't follow you there. The nudge is a
-- real input event, which is what resets that timer. The rejoin covers a disconnect; a
-- failed teleport draws an ErrorPrompt too, so it needs the connection actually gone.
--
-- The nudge is a keypress on a key nothing binds, and only after a minute without your own
-- input. It used to be a right-click (VirtualUser ClickButton2 + VirtualInputManager button 1),
-- and a right-button down/up is camera-drag in Roblox: landing in the middle of your own mouse
-- input it could leave the camera stuck to the mouse until Esc. A key can't touch the camera.
-- ponytail: VirtualInputManager only -- a client that ignores it gets no nudge; add
-- VirtualUser:SetKeyDown back if an idle kick ever shows up with this on.
local NUDGE_KEY = Enum.KeyCode.F15
local afk = { on = false, gen = 0, conns = {}, tpFail = -math.huge, rejoining = false, lastInput = os.clock() }
function afk.offline()
	local ok, gone = pcall(function()
		local nc = game:FindService("NetworkClient")
		return not (nc and nc:FindFirstChildWhichIsA("ClientReplicator"))
	end)
	return not ok or gone
end
function afk.nudge()
	if os.clock() - afk.lastInput < AFK_BEAT then
		return -- you're at the keyboard; your own input already feeds both idle timers
	end
	pcall(function()
		local vim = game:GetService("VirtualInputManager")
		vim:SendKeyEvent(true, NUDGE_KEY, false, game)
		vim:SendKeyEvent(false, NUDGE_KEY, false, game)
	end)
end
function afk.set(on)
	afk.gen = afk.gen + 1
	afk.on = on
	for _, c in ipairs(afk.conns) do
		pcall(c.Disconnect, c)
	end
	table.clear(afk.conns)
	if not on then
		return
	end
	local mine_ = afk.gen
	local function alive()
		return afk.on and afk.gen == mine_
	end
	table.insert(afk.conns, player.Idled:Connect(afk.nudge))
	table.insert(afk.conns, game:GetService("UserInputService").InputBegan:Connect(function(input)
		if input.KeyCode ~= NUDGE_KEY then -- our own nudge isn't you being here
			afk.lastInput = os.clock()
		end
	end))
	table.insert(afk.conns, game:GetService("TeleportService").TeleportInitFailed:Connect(function(who)
		if who == player then
			afk.tpFail = os.clock()
		end
	end))
	task.spawn(function()
		local overlay
		pcall(function()
			overlay = game:GetService("CoreGui"):WaitForChild("RobloxPromptGui", 10):WaitForChild("promptOverlay", 10)
		end)
		if overlay and alive() then
			table.insert(afk.conns, overlay.ChildAdded:Connect(function(child)
				if child.Name ~= "ErrorPrompt" or not alive() then
					return
				end
				task.wait(0.5)
				if alive() and os.clock() - afk.tpFail > 5 and afk.offline() and not afk.rejoining then
					afk.rejoining = true
					warn("[bluelock] disconnected -- rejoining in " .. REJOIN_DELAY .. "s")
					task.wait(REJOIN_DELAY)
					pcall(function()
						game:GetService("TeleportService"):Teleport(game.PlaceId, player)
					end)
					task.delay(30, function()
						afk.rejoining = false
					end)
				end
			end))
		end
		while alive() do
			task.wait(AFK_BEAT)
			if alive() then
				afk.nudge()
			end
		end
	end)
end

-- A separate thread: a loop parked in a yield can't report that it is.
local dogGen = 0
local function startDog()
	dogGen = dogGen + 1
	local mine_ = dogGen
	task.spawn(function()
		while dogGen == mine_ do
			local working = false
			for _, l in ipairs(loops) do
				working = working or (l.on and l.inBody)
			end
			if working and os.clock() - markAt > WATCHDOG then
				warn(("[bluelock] stuck %ds at: %s"):format(math.floor(os.clock() - markAt), mark))
				markAt = os.clock()
			end
			task.wait(5)
		end
	end)
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window = panel({
	game = "Blue Lock Farm", -- fallback until the live name lands
	folder = "BlueLockFarm", -- never rename: saved configs orphan
	size = UDim2.fromOffset(540, 460),
})
if not Window then
	return -- panel.lua already said why
end

-- WindUI hands a Multi dropdown a list, a map or the row tables depending on the build;
-- normalise into a set we own, translated through `key` (display name -> game key).
local function ticked(v, key)
	local set = {}
	for k, val in pairs(type(v) == "table" and v or {}) do
		local name
		if type(k) == "number" then
			name = type(val) == "table" and (val.Title or val.Value) or val
		elseif val == true then
			name = k
		end
		if type(name) == "string" then
			set[key and key[name] or name] = true
		end
	end
	return set
end
local function refill(set, v, key)
	table.clear(set)
	for k in pairs(ticked(v, key)) do
		set[k] = true
	end
end
-- A single dropdown: the game key for a pick, false for the "none" entry, nil for anything
-- else (a Refresh re-firing "" must not wipe a good pick). Some builds hand back the row table.
local function pick(v, key, none)
	if type(v) == "table" then
		v = v.Title or v.Value or v[1]
	end
	if v == none then
		return false
	end
	return key[v]
end
local function withNone(none, list)
	local out = { none }
	for _, v in ipairs(list) do
		table.insert(out, v)
	end
	return out
end
local function num(v, lo)
	local n = tonumber((tostring(v):gsub("[%$,%s]", "")))
	return n and n >= (lo or 0) and n or nil
end

do
	local Main = Window:Tab({ Title = "Farm", Icon = "solar:home-2-bold" })

	local Roll = Main:Section({ Title = "Roll", Icon = "solar:refresh-circle-bold", Box = true, BoxBorder = true, Opened = true })
	Roll:Toggle({
		Title = "Auto roll",
		Desc = "Free rolls on the game's own cooldown; nothing is bought unless Buy matches is on",
		Value = false,
		Callback = function(on)
			roll.saving, roll.seenId = 0, nil -- no hold outlives the belt loop
			rollLoop.set(on)
		end,
	})
	Roll:Toggle({
		Title = "Buy matches",
		Desc = "On: buys matches (one you'll afford within a minute is held). Off: rolling STOPS on a match until you buy it",
		Value = roll.buy,
		Callback = function(on)
			roll.buy = on
		end,
	})
	Roll:Dropdown({
		Title = "Min tier",
		Desc = "This tier and every tier above it",
		Values = withNone(ANY, TIERS),
		Value = ANY,
		Callback = function(v)
			local k = pick(v, tierKey, ANY)
			if k ~= nil then
				roll.minTier = k or nil
			end
		end,
	})
	Roll:Dropdown({
		Title = "Min variant",
		Desc = "This variant and every rarer one. Any + Any buys nothing (except the rule below)",
		Values = withNone(ANY, VARIANTS),
		Value = ANY,
		Callback = function(v)
			local k = pick(v, variantKey, ANY)
			if k ~= nil then
				roll.minVariant = k or nil
			end
		end,
	})
	Roll:Dropdown({
		Title = "Match",
		Values = { "Tier AND variant", "Tier OR variant" },
		Value = "Tier AND variant",
		Callback = function(v)
			roll.either = v == "Tier OR variant"
		end,
	})
	Roll:Toggle({
		Title = "Also buy anything better than my weakest slot",
		Desc = ("Even if it doesn't match the filters above: fills an empty slot, or beats your weakest by the margin; stops at %d waiting"):format(
			SMART_STOCK
		),
		Value = roll.smart,
		Callback = function(on)
			roll.smart = on
		end,
	})
	Roll:Input({
		Title = "Better by at least (%)",
		Desc = "Average pull vs your weakest player, both at your cap -- used for buying AND placing",
		Value = tostring(MARGIN),
		Placeholder = "25",
		Callback = function(v)
			local n = num(v, 0)
			if n then
				MARGIN = n
			end
		end,
	})
	Roll:Input({
		Title = "Max wait / price (minutes of income)",
		Desc = "Hold an unaffordable wanted locker this long at most; a \"better\" buy may cost this much at most",
		Value = tostring(MAX_WAIT),
		Placeholder = "30",
		Callback = function(v)
			local n = num(v, 0)
			if n then
				MAX_WAIT = n
			end
		end,
	})

	local Lock = Main:Section({ Title = "Lockers & players", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })
	Lock:Toggle({
		Title = "Auto open lockers",
		Desc = "The player lands on the same slot; then level -> Equip Best -> re-place",
		Value = false,
		Callback = function(on)
			roster.open = on
			rosterSync()
		end,
	})
	Lock:Toggle({
		Title = "Auto place lockers",
		Desc = "Empty slot gets your richest locker; otherwise the richest one beating your weakest player by the margin (Roll) replaces it",
		Value = false,
		Callback = function(on)
			roster.place = on
			rosterSync()
		end,
	})
	Lock:Toggle({
		Title = "Auto level players",
		Desc = "Players on the plot only (the remote takes the slot); cheapest $ per $/ball first",
		Value = false,
		Callback = function(on)
			roster.level = on
			rosterSync()
		end,
	})
	Lock:Input({
		Title = "Level cap",
		Desc = "Stop levelling a player here",
		Value = tostring(roster.cap),
		Placeholder = "10",
		Callback = function(v)
			local n = num(v, 1)
			if n then
				roster.cap = math.floor(n)
			end
		end,
	})
	Lock:Toggle({
		Title = "Auto Equip Best",
		Desc = "A bag player better at your cap swaps onto your weakest slot (even at L1); otherwise the game's own EquipBestPlayerUnits, once each time every slotted player reaches the cap",
		Value = false,
		Callback = function(on)
			roster.equip = on
			rosterSync()
		end,
	})

	local Sell = Main:Section({ Title = "Sell", Icon = "solar:tag-price-bold", Box = true, BoxBorder = true, Opened = false })
	Sell:Toggle({
		Title = "Auto sell lockers",
		Desc = "Unplaced lockers in the tiers below; a locker sells for what it cost",
		Value = false,
		Callback = function(on)
			roster.sellLockers = on
			rosterSync()
		end,
	})
	Sell:Toggle({
		Title = "Auto sell players",
		Desc = "Players in your bag (never one on a slot) from the tiers below",
		Value = false,
		Callback = function(on)
			roster.sellUnits = on
			rosterSync()
		end,
	})
	Sell:Dropdown({
		Title = "Sell tiers below",
		Desc = "Every tier under this one is sold; this tier and up are kept. A player's tier is its locker's",
		Values = withNone(NOTHING, TIERS),
		Value = NOTHING,
		Callback = function(v)
			local k = pick(v, tierKey, NOTHING)
			if k ~= nil then
				sell.below = k or nil
			end
		end,
	})
	Sell:Dropdown({
		Title = "Never sell variants",
		Values = VARIANTS,
		Multi = true,
		AllowNone = true,
		Value = {},
		Callback = function(v)
			refill(sell.keep, v, variantKey)
		end,
	})
	Sell:Toggle({
		Title = "Never sell anything better than my weakest slot",
		Value = sell.guard,
		Callback = function(on)
			sell.guard = on
		end,
	})

	local Map = Main:Section({ Title = "Crates & spawns", Icon = "solar:map-point-bold", Box = true, BoxBorder = true, Opened = false })
	Map:Toggle({
		Title = "Auto crates",
		Desc = "Picks up your conveyor's pile and sells it at your sell NPC",
		Value = false,
		Callback = function(on)
			crateLoop.set(on)
		end,
	})
	Map:Input({
		Title = "Pick up at balls",
		Value = tostring(crate.min),
		Placeholder = tostring(CRATE_MIN),
		Callback = function(v)
			local n = num(v, 1)
			if n then
				crate.min = math.floor(n)
			end
		end,
	})
	Map:Toggle({
		Title = "Auto tokens & potions",
		Desc = "Wakes on each spawn node's Occupied flag; variant tokens first, rarest first",
		Value = false,
		Callback = function(on)
			spawnWatch(on)
			spawnLoop.set(on)
		end,
	})
	Map:Dropdown({
		Title = "Collect",
		Values = SPAWN_KINDS,
		Multi = true,
		AllowNone = true,
		Value = SPAWN_KINDS,
		Callback = function(v)
			refill(spawn.want, v)
		end,
	})

	local Up = Window:Tab({ Title = "Upgrades", Icon = "solar:bolt-circle-bold" })
	local UpSec = Up:Section({ Title = "Permanent upgrades", Icon = "solar:graph-up-bold", Box = true, BoxBorder = true, Opened = true })
	UpSec:Toggle({
		Title = "Auto upgrades",
		Desc = "Best payback first; see the header for how luck / open time / conveyor tier are weighed",
		Value = false,
		Callback = function(on)
			upgLoop.set(on)
		end,
	})
	local start = {}
	for _, shown in ipairs(UPG_NAMES) do
		if upgWant[upgKey[shown]] then
			table.insert(start, shown)
		end
	end
	UpSec:Dropdown({
		Title = "Which upgrades",
		Values = UPG_NAMES,
		Multi = true,
		AllowNone = true,
		Value = start,
		Callback = function(v)
			local set = ticked(v, upgKey)
			for name in pairs(upgWant) do
				upgWant[name] = set[name] == true
			end
		end,
	})
	UpSec:Input({
		Title = "Max payback (minutes)",
		Value = tostring(MAX_PAYBACK),
		Placeholder = tostring(MAX_PAYBACK),
		Callback = function(v)
			local n = num(v, 0.1)
			if n then
				MAX_PAYBACK = n
			end
		end,
	})
	UpSec:Input({
		Title = "Keep at least $",
		Desc = "Every spender -- lockers, levels, upgrades -- leaves this much",
		Value = "0",
		Placeholder = "0",
		Callback = function(v)
			local n = tostring(v):gsub("[%$,%s]", "")
			local ok, parsed = pcall(NumberUtils.AbbreviationToNumber, n)
			reserve = (ok and tonumber(parsed)) or tonumber(n) or reserve
		end,
	})

	local Set = Window:Tab({ Title = "Settings", Icon = "solar:settings-bold" })
	local Move = Set:Section({ Title = "Teleport & idle", Icon = "solar:running-bold", Box = true, BoxBorder = true, Opened = true })
	Move:Toggle({
		Title = "Teleport when the server wants you close",
		Desc = "Off: remote-only; anything range-checked just fails (F9 says which)",
		Value = move.tp,
		Callback = function(on)
			move.tp = on
		end,
	})
	Move:Toggle({
		Title = "Go back after a teleport",
		Value = move.back,
		Callback = function(on)
			move.back = on
		end,
	})
	Move:Toggle({
		Title = "Idle at my roll station",
		Desc = "After a teleport, park by the belt instead of where you were",
		Value = move.park,
		Callback = function(on)
			move.park = on
		end,
	})
	Move:Toggle({
		Title = "Anti-AFK + rejoin",
		Desc = "Also stops the game's own 15-minute move to a reserved server",
		Value = true,
		Callback = function(on)
			afk.set(on)
		end,
	})
end

-- Loop threads lose the capability to write to the panel after their first yield, so they
-- leave text in upvalues and Heartbeat (our own identity) writes it.
local Stats = Window:Tab({ Title = "Stats", Icon = "solar:chart-bold" })
local statsSec = Stats:Section({ Title = "Dashboard", Icon = "solar:chart-2-bold", Box = true, BoxBorder = true, Opened = true })
local status = statsSec:Paragraph({ Title = "Status", Desc = "idle" })
local dashRow, dashText = {}, {}
for _, title in ipairs({ "Plot", "Session" }) do
	dashRow[title] = statsSec:Paragraph({ Title = title, Desc = "reading..." })
end

local drain = RunService.Heartbeat:Connect(function()
	for title, text in pairs(dashText) do
		dashText[title] = nil
		pcall(dashRow[title].SetDesc, dashRow[title], text)
	end
	if pending then
		local msg = pending
		pending = nil
		pcall(status.SetDesc, status, msg)
	end
end)

local builders = {
	Plot = function()
		local s = slots()
		local units, lockers = 0, 0
		for _, p in ipairs(s) do
			local t = p:GetAttribute("Type")
			units = units + (t == "PlayerUnit" and 1 or 0)
			lockers = lockers + (t == "Box" and 1 or 0)
		end
		local w, wv = weakest()
		return table.concat({
			("cash %s   income %s/s"):format(money(cash()), money(incomePerSec())),
			("slots %d: %d players, %d opening   lockers in bag %d"):format(#s, units, lockers, lockersWaiting()),
			("weakest slot %s at %s/ball (cap %d)"):format(w and w.Name or "-", money(wv or 0), target()),
		}, "\n")
	end,
	Session = function()
		local on, hops = {}, {}
		for _, l in ipairs(loops) do
			if l.on then
				table.insert(on, l.name)
			end
		end
		for key, r in pairs(route) do
			if r.hopFirst then
				table.insert(hops, key)
			end
		end
		return table.concat({
			("rolls %d   bought %d   opened %d   placed %d (%d replaced)"):format(stats.rolls, stats.bought, stats.opened, stats.placed, stats.replaced),
			("levels %d   sold %d lockers, %d players   crates %d   upgrades %d"):format(stats.levels, stats.soldL, stats.soldU, stats.crates, stats.upgrades),
			("spawns %d (lost %d races)   hop first: %s"):format(stats.spawns, stats.lost, #hops > 0 and table.concat(hops, ", ") or "none"),
			("running: %s   at: %s"):format(#on > 0 and table.concat(on, ", ") or "nothing", mark),
		}, "\n")
	end,
}

local dashGen = 0
local function startDash()
	dashGen = dashGen + 1
	local mine_ = dashGen
	task.spawn(function()
		while dashGen == mine_ do
			for title, build in pairs(builders) do
				local ok, text = pcall(build)
				dashText[title] = ok and text or ("unreadable: " .. tostring(text))
			end
			task.wait(DASH_GAP)
		end
	end)
end

-- A starting Value = true doesn't fire the callback; arm it by hand.
afk.set(true)
startDog()
startDash()
say(("ready -- %d slots, cash %s"):format(#slots(), money(cash())))

-- close ----------------------------------------------------------------------
local function stopAll()
	for _, l in ipairs(loops) do
		l.set(false)
	end
	spawnWatch(false)
	dogGen = dogGen + 1
	dashGen = dashGen + 1
	afk.set(false) -- a stopped script must not rejoin you
	pcall(drain.Disconnect, drain)
end

Window:OnDestroy(function()
	stopAll()
	getgenv().blueLockFarmStop = nil
end)

getgenv().blueLockFarmStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().blueLockFarmStop = nil
end
