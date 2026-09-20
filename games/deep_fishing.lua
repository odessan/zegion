--[[ Deep Fishing -- protocol-replay fishing: perfect cast, best fish first, no cinematic (132239307080610)

     FARM   : casts, picks the best fish out of the school the server just rolled, claims
              them and resets -- one round trip per cast, no arc, no dive, no pull-up, no
              camera. The cinematic never starts because we never touch the charge UI.
     CATCH  : the server claims in the order WE list the indices and stops at your hook
              capacity, so the list goes out sorted by sell value. A floor dropdown drops
              the rarities you don't want taking a slot.
     SELL   : one Sell per fish you chose to sell, by inventory id -- the server can only
              take the id you name, so a keeper cannot be sold by accident. Batched so a
              whole backpack costs a couple of round trips, not one per fish. OFF by default;
              with it off a full backpack stops the farm and says so.
     LOOT   : the non-fish half of a cast. Chests, cages and Like Gifts open with one packet
              each -- no walking, nothing to equip. Auto-open is OFF by default. Enchant
              Stones roll the shrine until an enchant you ticked lands; Mutation Scrolls
              respin the fish you're holding until its mutation is one you ticked.
     BAIT   : the luck multiplier that actually moves. Auto-use spends the best bait in the
              bag when the active charges hit zero; auto-buy restocks it, walking down from
              the highest luck until the cash and the shelf agree. Price and Luck come from
              the content module the shop UI itself reads; stock from the shop's own remote.
     EXTRAS : auto-upgrade, codes, world hop.

     This is archetype C, all of it: the game ships its own server code in
     ReplicatedStorage.Shared.Events.ThrowRod, so every number below is read off the
     enforcement rather than guessed.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().deepFishingStop() ]]

-- config ---------------------------------------------------------------------
-- ThrowRod.lua:568 scores the cast off the power byte alone:
--   p >= 0.4 and p < 0.55 -> quality 2 ("Perfect"), 0.1..0.9 -> 1.5, else 1.
-- Quality is the whole of distance, depth and therefore rarity, so there is exactly one
-- right number to send and no timing to simulate. Dead centre of the perfect band.
local POWER = 0.475

local CAST_TIMEOUT = 4 -- seconds waiting for the server's "Started" before we give up on a cast
local CYCLE_GAP = 0.05 -- between finishing one cast and starting the next
-- Warp flushes every queued Fire on PostSimulation, and iterates its per-event queues in
-- dictionary order -- so two DIFFERENT events queued in the same frame can arrive in either
-- order. FishCaught before CancelThrow and CancelThrow before the next ThrowRod both matter
-- (CancelThrow wipes the school; a ThrowRod that overtakes it is refused "already_active"),
-- so every step of the sequence gets its own frame. One frame each, not a sleep.
local STEP = 0 -- extra seconds on top of the frame gap; 0 is right unless the server lags

-- FishHooked("won") is rejected unless os.clock() - fight.started >= required / MaxClickRate
-- (ThrowRod.lua:1152, CatchFight.MaxClickRate = 12). That wait is the floor for a Secret or
-- Exotic and nothing else in the script can shorten it.
local FIGHT_PAD = 0.2 -- margin over required/12 to cover the round trip in both directions

local SELL_BATCH = 40 -- Sell invokes fired together; Warp packs one identifier's requests into one packet
local SELL_GAP = 0.25 -- between batches, well inside Warp's 200-per-2s per-identifier limit
local SELL_AT = 0.85 -- sell when the backpack is this full, regardless of the every-N-casts setting

local SNAP = 0.35 -- seconds parked at the seller for the position to replicate before selling
local ARRIVE = 5 -- cap on waiting out a GameplayPaused after a hop

local IDLE = 0.5 -- beat when the farm can't run (no rod, out of area)
local WATCHDOG = 20 -- seconds without the breadcrumb moving before we say where we are

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().deepFishingStop then
	getgenv().deepFishingStop() -- re-running must not stack a second panel or a second loop
end

local function log(msg)
	print("[deep] " .. msg)
end

local pending -- last thing a loop thread wanted on the status row; drained on Heartbeat
local function say(msg)
	pending = msg
end

local mark, markAt = "idle", os.clock()
local function step(what)
	mark, markAt = what, os.clock()
end

-- world ----------------------------------------------------------------------
-- The game's whole framework is one require away and the module cache is shared, so this
-- is the same table its own controllers hold: Events (Warp channels), Content (the fish
-- table with live prices), Config, Modules, Services, and PlayerData.Client.Data, which
-- is the client's mirror of the save the HUD reads. Nothing here is a reimplementation.
local ok, Shared = pcall(function()
	return require(ReplicatedStorage:WaitForChild("Shared", 10))
end)
if not ok or type(Shared) ~= "table" or not Shared.Events then
	warn("[deep] ReplicatedStorage.Shared didn't load -- wrong game, or the client hasn't booted yet")
	return
end

local Events, Content, Config, Modules, Services, Utils =
	Shared.Events, Shared.Content, Shared.Config, Shared.Modules, Shared.Services, Shared.Utils
local RarityConfig = Config.RarityConfig
local CatchFight = Modules.CatchFight
local ThrowArea = Modules.ThrowArea

local function data()
	return Shared.PlayerData.Client.Data
end

-- Events.Client() spins forever on a name it hasn't registered (Events.lua:31 has a bare
-- repeat/wait), which would park a loop thread with nothing in the console. Every name is
-- an Instance under ReplicatedStorage.Events, so check there first and refuse instead.
local eventRoot = ReplicatedStorage:WaitForChild("Events", 10)
local eventFolders = {}
for _, name in ipairs({ "RemoteEvents", "RemoteFunctions" }) do
	local folder = eventRoot and eventRoot:FindFirstChild(name)
	if folder then
		table.insert(eventFolders, folder)
	end
end
local evCache = {}
local function ev(name)
	if evCache[name] ~= nil then
		return evCache[name] or nil
	end
	local exists = false
	for _, folder in ipairs(eventFolders) do
		if folder and folder:FindFirstChild(name) then
			exists = true
			break
		end
	end
	if not exists then
		warn("[deep] no event named " .. name .. " -- the game renamed it")
		evCache[name] = false
		return nil
	end
	local got, chan = pcall(Events.Client, name)
	evCache[name] = got and chan or false
	return evCache[name] or nil
end

-- Rarities, low to high, straight off RarityConfig. Exclusive is OffLadder with Order 9,
-- which lands it at the top -- exactly where a "sell up to" ladder wants it.
local LADDER = {}
do
	local rows = {}
	for name, info in pairs(RarityConfig.Items) do
		table.insert(rows, { name = name, order = info.Order or 0 })
	end
	table.sort(rows, function(a, b)
		return a.order < b.order
	end)
	for _, row in ipairs(rows) do
		table.insert(LADDER, row.name)
	end
end
local function rarityOrder(name)
	return RarityConfig.GetOrder(name) or 0
end
assert(#LADDER >= 8 and rarityOrder(LADDER[1]) < rarityOrder(LADDER[#LADDER]), "rarity ladder is out of order")

local fishCache = {}
local function fishInfo(name)
	if fishCache[name] == nil then
		local got, info = pcall(function()
			return Content.Item.Fish:Get(name, true)
		end)
		fishCache[name] = (got and info) or false
	end
	return fishCache[name] or nil
end

-- The game's own price function: size cubed, mutation multiplier, gamepasses, index boost,
-- enchants, live cash boost. Worth the pcall to get the boosts right rather than guessing.
local function sellValue(name, size, mutation)
	local got, value = pcall(function()
		return Services.Item:GetSellValue(player, {
			Type = "Fish",
			Name = name,
			Data = { Size = size, Mutation = mutation },
		})
	end)
	if got and type(value) == "number" then
		return value
	end
	local info = fishInfo(name)
	return info and (info.SellPrice or 0) * (size or 1) ^ 3 or 0
end

-- How many of a school the server will actually claim: FishCaught breaks at the hook
-- capacity, and separately at whatever room the backpack has left.
local function claimCap()
	local d = data()
	local hooks = 3
	pcall(function()
		local world = Config.WorldsConfig.ForPlayerData(d)
		hooks = Config.UpgradesConfig.CapacityValue(d.Upgrades and d.Upgrades.Capacity or 0, world.UpgradeEffect or 1)
			+ (Modules.Enchant.Add(d, "HookSlots") or 0)
	end)
	local free = hooks
	pcall(function()
		local cap = Services.Backpack:GetCap()
		free = math.max(cap.Cap - cap.Count, 0)
	end)
	return math.max(math.min(hooks, free), 0), free
end

-- Backpack fullness, 0..1. Reports whether it could read: failing open to 0 would read as
-- "empty" and silently switch auto-sell off for the length of the run.
local function fullness()
	local got, cap = pcall(function()
		return Services.Backpack:GetCap()
	end)
	if not got or type(cap) ~= "table" or not cap.Cap then
		return nil
	end
	return cap.Count / cap.Cap
end

local function char()
	local c = player.Character
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	return (hrp and c or nil), hrp
end

local function settle()
	local until_ = os.clock() + ARRIVE
	while player.GameplayPaused and os.clock() < until_ do
		task.wait(0.05)
	end
end

local function hop(cf)
	local _, hrp = char()
	if not hrp then
		return false
	end
	hrp.CFrame = cf
	settle()
	return true
end

-- Throw area ------------------------------------------------------------------
-- The cast is refused "left_area_on_release" unless the server's own IsInside passes, and
-- that is a bounding-box test on the HumanoidRootPart against the parts under
-- Interactable.Throw -- a volume, not a surface, so no lift. Rather than guess an offset,
-- try candidates against the game's own predicate and keep the first that passes.
local function throwFolder()
	local got, folder = pcall(function()
		return Utils.WorldFolder.Interactable("Throw")
	end)
	return got and folder or nil
end

local function anchorCF()
	local folder = throwFolder()
	if not folder then
		return nil
	end
	for _, part in ipairs(folder:GetChildren()) do
		if part:IsA("BasePart") then
			for _, lift in ipairs({ 0, part.Size.Y * 0.5, 3 }) do
				local pos = part.Position + Vector3.new(0, lift, 0)
				if ThrowArea.IsInside(folder, pos) then
					return CFrame.new(pos)
				end
			end
		end
	end
	return nil
end

local function inArea()
	local _, hrp = char()
	local folder = throwFolder()
	if not hrp or not folder then
		return false
	end
	return ThrowArea.IsInside(folder, hrp.Position, ThrowArea.RELEASE_MARGIN)
end

-- The server checks the Tool in your Character is named exactly RodEquipped, so equipping
-- is a Humanoid:EquipTool on the Backpack copy -- the EquipTool event exists but routes
-- through a server controller we can't read, and this one we can confirm locally.
local function rodOut()
	local c = char()
	local want = data() and data().RodEquipped or "Wooden Rod"
	if not c then
		return false, "no character"
	end
	local held = c:FindFirstChildOfClass("Tool")
	if held and held.Name == want then
		return true
	end
	local hum = c:FindFirstChildOfClass("Humanoid")
	local tool = player:FindFirstChild("Backpack") and player.Backpack:FindFirstChild(want)
	if not hum or not tool then
		return false, "no " .. want .. " in the backpack"
	end
	pcall(function()
		hum:EquipTool(tool)
	end)
	task.wait(0.1)
	local now = c:FindFirstChildOfClass("Tool")
	return (now and now.Name == want), "equip didn't take"
end

-- farm ------------------------------------------------------------------------
local farmToggle -- built in the gui section; the loop switches itself off through it
local farm = { on = false, gen = 0 }
local catchFloor = "Everything" -- rarity below this doesn't get a hook slot
local sellUpTo = "Uncommon" -- sell this rarity and everything below it
local keepMutated = true
local sellEvery = 20 -- casts between sell sweeps; 0 = only when the backpack is nearly full
local keepStreak = true
local sellSnap = true
-- Both off by default: they're the two that spend something you can't get back -- one opens
-- a chest you might have wanted to hold, the other empties the bag against a rarity rule you
-- haven't looked at yet. Opt in once you've set the rules.
local autoSell = false
local autoOpen = false

local stats = { casts = 0, caught = 0, sold = 0, earned = 0, refused = 0 }

-- The only honest confirm. FishCaught returns nothing and the server fires
-- FishesReceivedNotification only when it actually processed at least one fish, so a run of
-- casts with no receipt means nothing is reaching the claim -- a different bug from the
-- server refusing the cast, and the two get fixed in opposite ways.
local dry = 0
local receipts = 0
local receiptConn
do
	local chan = ev("FishesReceivedNotification")
	if chan then
		receiptConn = chan:Connect(function(list)
			receipts = receipts + (type(list) == "table" and #list or 1)
			dry = 0
		end)
	end
end

-- One cast, whole protocol. Returns "ok", or a short reason.
local function cast()
	local throwRod, fishCaught, fishHooked, cancel =
		ev("ThrowRod"), ev("FishCaught"), ev("FishHooked"), ev("CancelThrow")
	if not (throwRod and fishCaught and cancel) then
		return "missing an event"
	end

	step("cast/await")
	local started, refused
	local key = throwRod:Connect(function(kind, payload)
		if kind == "Started" and type(payload) == "table" then
			started = payload
		elseif kind == "Refused" then
			refused = tostring(payload)
		end
	end)

	throwRod:Fire(true, POWER)

	local deadline = os.clock() + CAST_TIMEOUT
	while not started and not refused and os.clock() < deadline do
		task.wait()
	end
	pcall(function()
		throwRod:Disconnect(key)
	end)

	if refused then
		-- A stale cast of ours is the one refusal we can clear ourselves.
		if refused == "already_active" then
			cancel:Fire(true)
			task.wait()
		end
		return "refused: " .. refused
	end
	if not started then
		cancel:Fire(true)
		return "server never answered"
	end

	local school = started.school or {}
	local sizes = started.sizes or {}
	local mutations = started.mutations or {}
	local specials = started.specials or {}
	local throwId = started.throwId

	-- Rank what the server already rolled. FishCaught walks the index list in OUR order and
	-- breaks at capacity, so sorting here is the whole of "prioritise by value".
	step("cast/rank")
	local floor = catchFloor ~= "Everything" and rarityOrder(catchFloor) or 0
	local picks = {}
	for i, name in ipairs(school) do
		local info = fishInfo(name)
		local rarity = info and info.Rarity or "Common"
		if rarityOrder(rarity) >= floor then
			local mutation = mutations[i] or nil
			table.insert(picks, {
				index = i,
				name = name,
				rarity = rarity,
				fight = CatchFight.Required(info),
				score = sellValue(name, sizes[i] or 1, mutation),
			})
		end
	end
	table.sort(picks, function(a, b)
		if a.score == b.score then
			return a.index < b.index
		end
		return a.score > b.score
	end)

	local cap = claimCap()
	if cap <= 0 then
		cancel:Fire(true)
		return "no room -- sell first"
	end
	while #picks > cap do
		table.remove(picks)
	end

	-- Specials (scrolls, chests, the rush items) sit past the end of the school and cost no
	-- hook slot on the way in -- FishCaught claims them through a different branch.
	local indices = {}
	for _, pick in ipairs(picks) do
		table.insert(indices, pick.index)
	end
	for i in ipairs(specials) do
		table.insert(indices, #school + i)
	end
	if #indices == 0 then
		cancel:Fire(true)
		return "nothing worth keeping"
	end

	-- Fights: Secret and above (RarityConfig order >= 7) need a started fight and a won one,
	-- and the server times the gap between them. Start every fight in one frame so they run
	-- the clock down together instead of one after another.
	step("cast/hook")
	local longest = 0
	if fishHooked then
		for _, pick in ipairs(picks) do
			if pick.fight then
				fishHooked:Fire(true, pick.index, "fight", nil, true)
				longest = math.max(longest, pick.fight)
			elseif keepStreak then
				-- Not needed for the claim; it is the only thing that feeds the streak counter.
				fishHooked:Fire(true, pick.index)
			end
		end
	end

	if longest > 0 and fishHooked then
		step("cast/fight")
		task.wait(longest / CatchFight.MaxClickRate + FIGHT_PAD)
		for _, pick in ipairs(picks) do
			if pick.fight then
				fishHooked:Fire(true, pick.index, "won", pick.fight)
			end
		end
	end

	step("cast/claim")
	task.wait(STEP)
	fishCaught:Fire(true, throwId, indices, false)
	task.wait(STEP)
	-- Ends the server's cast sequence immediately: clears the active-throw guard and the
	-- school, so the next ThrowRod is accepted this second instead of after the pull-up,
	-- the showcase hold and the return arc.
	cancel:Fire(true)

	stats.casts = stats.casts + 1
	stats.caught = stats.caught + #picks
	dry = dry + 1
	if dry == 5 then
		warn("[deep] 5 casts with no FishesReceivedNotification -- the claims aren't landing. "
			.. "Check the backpack isn't full, and that the school indices still start at 1.")
	end
	return "ok", picks
end

-- sell -------------------------------------------------------------------------
-- Per item, by inventory id. The server can only take the id we name, so a keeper is
-- unreachable by construction -- which is worth more here than the one call SellAll would be.
local function sellPlan()
	local limit = sellUpTo ~= "Nothing" and rarityOrder(sellUpTo) or -1
	local plan = {}
	if limit < 0 then
		return plan
	end
	local inv = data() and data().Inventory
	if type(inv) ~= "table" then
		return plan
	end
	for guid, item in pairs(inv) do
		if type(item) == "table" and item.Type == "Fish" and not Modules.Lock.IsLocked(item) then
			local info = fishInfo(item.Name)
			local mutation = item.Data and item.Data.Mutation
			if info and info.SellPrice and rarityOrder(info.Rarity) <= limit then
				if not (keepMutated and mutation) then
					table.insert(plan, guid)
				end
			end
		end
	end
	return plan
end

local function sellNow()
	local sell = ev("Sell")
	if not sell then
		return 0, 0
	end
	local plan = sellPlan()
	if #plan == 0 then
		return 0, 0
	end

	local home
	if sellSnap then
		local _, hrp = char()
		local got, npc = pcall(function()
			return Utils.WorldFolder.Interactable("NPC_Sell")
		end)
		local target = got and npc and npc:FindFirstChildWhichIsA("BasePart", true)
		if hrp and target then
			home = hrp.CFrame
			hop(target.CFrame + Vector3.new(0, 4, 0))
			task.wait(SNAP)
		end
	end

	local count, total = 0, 0
	for base = 1, #plan, SELL_BATCH do
		local batch, done = {}, 0
		for i = base, math.min(base + SELL_BATCH - 1, #plan) do
			table.insert(batch, plan[i])
		end
		for _, guid in ipairs(batch) do
			task.spawn(function()
				local got, value = pcall(function()
					return sell:Invoke(5, guid)
				end)
				if got and type(value) == "number" and value > 0 then
					count = count + 1
					total = total + value
				end
				done = done + 1
			end)
		end
		local deadline = os.clock() + 8
		while done < #batch and os.clock() < deadline do
			task.wait()
		end
		task.wait(SELL_GAP)
	end

	if home then
		hop(home)
	end
	stats.sold = stats.sold + count
	stats.earned = stats.earned + total
	return count, total
end

-- bait -------------------------------------------------------------------------
-- takeBestBait spends one charge of the highest-Luck active bait per cast, and one Consume
-- is five casts. Keeping it topped up is the single biggest multiplier on what the school
-- rolls, and it costs one packet every five casts.
local function bestBaitGuid()
	local inv = data() and data().Inventory
	if type(inv) ~= "table" then
		return nil
	end
	local bestGuid, bestLuck
	for guid, item in pairs(inv) do
		if type(item) == "table" and item.Type == "Bait" then
			local got, info = pcall(function()
				return Content.Item.Bait:Get(item.Name, true)
			end)
			local luck = got and info and info.Luck or 0
			if not bestLuck or luck > bestLuck then
				bestGuid, bestLuck = guid, luck
			end
		end
	end
	return bestGuid, bestLuck
end

local function baitCharges()
	local active = data() and data().ActiveBaits
	if type(active) ~= "table" then
		return 0
	end
	local total = 0
	for _, n in pairs(active) do
		if type(n) == "number" then
			total = total + n
		end
	end
	return total
end

-- How many of a named bait are sitting in the bag. Bait is amount-stacked, so it's one
-- inventory row with an Amount, not N rows -- and the Amount is the buy's only receipt.
local function baitCount(name)
	local inv = data() and data().Inventory
	if type(inv) ~= "table" then
		return 0
	end
	for _, item in pairs(inv) do
		if type(item) == "table" and item.Type == "Bait" and item.Name == name then
			return math.max(tonumber(item.Data and item.Data.Amount) or 1, 0)
		end
	end
	return 0
end

-- The shop needs no plumbing of its own: Price, Luck and Rarity are all in the content
-- module the shop UI itself reads (UI/Interfaces/Baits.lua fills Infos straight from
-- Bait:GetCollection()). Only the stock is a remote, and only because it's server state.
local BAITS = {}
do
	local got, all = pcall(function()
		return Content.Item.Bait:GetCollection()
	end)
	for name, info in pairs(got and all or {}) do
		if type(info.Price) == "number" and info.Price > 0 then -- Robux-only baits have none
			table.insert(BAITS, { name = name, price = info.Price, luck = info.Luck or 0 })
		end
	end
	-- Best luck first: that's the order the picker walks down when cash or stock runs out.
	table.sort(BAITS, function(a, b)
		if a.luck == b.luck then
			return a.price < b.price
		end
		return a.luck > b.luck
	end)
end
assert(#BAITS == 0 or BAITS[1].luck >= BAITS[#BAITS].luck, "bait ladder is out of order")

-- Stock lives under ReplicatedStorage.Events.Game -- plain RemoteFunction/RemoteEvent, not
-- Warp. Ask once per bait, then let UpdateStockEvent keep the number current: the game's own
-- shop labels are driven off exactly this pair, so a count here is what the shelf says.
local gameRemotes = eventRoot and eventRoot:FindFirstChild("Game")
local stock, stockAsked = {}, {}
local stockConn
if gameRemotes and gameRemotes:FindFirstChild("UpdateStockEvent") then
	stockConn = gameRemotes.UpdateStockEvent.OnClientEvent:Connect(function(name, n)
		if type(name) == "string" and type(n) == "number" then
			stock[name], stockAsked[name] = n, true
		end
	end)
end

-- nil means "no answer" -- unknown, or a bait the stock system doesn't manage. Treat that as
-- available: failing closed here would silently refuse to buy anything the server never
-- reported on.
local function stockOf(name)
	if stockAsked[name] then
		return stock[name]
	end
	stockAsked[name] = true
	local fn = gameRemotes and gameRemotes:FindFirstChild("GetStockFunction")
	if fn then
		local got, n = pcall(function()
			return fn:InvokeServer(name)
		end)
		if got and type(n) == "number" then
			stock[name] = n
		end
	end
	return stock[name]
end

local BUY_QTY = 5 -- baits per top-up; each one is five casts, so this is ~25 casts of luck
local BUY_GAP = 0.3 -- between Buy fires -- the server answers each one on its own
local BUY_CONFIRM = 2.5 -- seconds waiting for the stack to grow before calling it refused

local baitTarget = "Best affordable"
local autoBuyBait = false
local autoUseBait = true
local baitSnap = false -- the buy is a UI-driven remote with no distance code; see the toggle

local function baitShopCF()
	local got, npc = pcall(function()
		return Utils.WorldFolder.Path({ "Map", "NPC_Baits" })
	end)
	local part = got and npc and (npc:IsA("BasePart") and npc or npc:FindFirstChildWhichIsA("BasePart", true))
	return part and (part.CFrame + Vector3.new(0, 4, 0)) or nil
end

-- Best luck we can afford a whole top-up of, skipping anything the shelf says is empty.
-- Requiring the full BUY_QTY on purpose: spending the last of your cash on one premium bait
-- buys five casts, where the tier below buys twenty-five.
local function pickBait()
	if baitTarget ~= "Best affordable" then
		for _, row in ipairs(BAITS) do
			if row.name == baitTarget then
				local left = stockOf(row.name)
				return (left == nil or left > 0) and row or nil, left == 0 and "out of stock" or nil
			end
		end
		return nil, "unknown bait"
	end
	local cash = data() and data().Cash or 0
	for _, row in ipairs(BAITS) do
		local left = stockOf(row.name)
		if row.price * BUY_QTY <= cash and (left == nil or left > 0) then
			return row
		end
	end
	return nil, "nothing affordable in stock"
end

local function buyBait(row, qty)
	local shop = ev("BaitShop")
	if not shop then
		return 0, "no BaitShop channel"
	end
	local home
	if baitSnap then
		local cf, hrp = baitShopCF(), select(2, char())
		if cf and hrp then
			home = hrp.CFrame
			hop(cf)
			task.wait(SNAP)
		end
	end

	local bought, why = 0, nil
	for _ = 1, qty do
		local before = baitCount(row.name)
		shop:Fire(true, "Buy", row.name)
		local deadline = os.clock() + BUY_CONFIRM
		while baitCount(row.name) <= before and os.clock() < deadline do
			task.wait(0.05)
		end
		if baitCount(row.name) <= before then
			-- Cash, stock or distance -- from here they all look the same, so write the shelf
			-- off and let the picker step down a tier rather than re-ask every top-up.
			stock[row.name], stockAsked[row.name] = 0, true
			why = "server refused " .. row.name
			break
		end
		bought = bought + 1
		task.wait(BUY_GAP)
	end

	if home then
		hop(home)
	end
	return bought, why or ("bought %dx %s"):format(bought, row.name)
end

-- One pass: buy if the bag is empty and auto-buy is on, then spend one on the active pool.
-- This runs every cast, so a failed buy parks for BUY_RETRY rather than saying the same
-- thing sixty times a minute -- the shelf restocks on a 300s clock anyway.
local BUY_RETRY = 45
local buyRetryAt = 0

local function topUpBait()
	if not autoUseBait or baitCharges() > 0 then
		return false
	end
	local guid = bestBaitGuid()
	if not guid and autoBuyBait and os.clock() >= buyRetryAt then
		local row, why = pickBait()
		if not row then
			buyRetryAt = os.clock() + BUY_RETRY
			say("auto-buy bait: " .. (why or "nothing to buy"))
			return false
		end
		local n, reason = buyBait(row, BUY_QTY)
		if n == 0 then
			buyRetryAt = os.clock() + BUY_RETRY
			say("auto-buy bait: " .. reason)
			return false
		end
		guid = bestBaitGuid()
	end
	local consume = guid and ev("ConsumeBait")
	if not consume then
		return false
	end
	consume:Fire(true, guid)
	return true
end

-- loot ---------------------------------------------------------------------------
-- Chests, cages and Like Gifts are the whole non-fish half of a cast. All three open with
-- one packet and nothing else: the guid IS the payload, there is no proximity check and
-- nothing has to be equipped (Backpack/ToolActivation/{Chest,Cage,Exclusive}.lua just read
-- the slot's guid and fire). All three are amount-stacked, so one guid can be twelve chests.
local OPENERS = { Chest = "FishingObject", Cage = "FishingObject", Exclusive = "LikeGift" }

-- Nothing comes back on either channel, so the confirm is the stack shrinking in the save
-- mirror -- which is also what tells us to stop when the server quietly refuses.
local function stackAmount(guid)
	local inv = data() and data().Inventory
	local item = type(inv) == "table" and inv[guid]
	if type(item) ~= "table" then
		return 0
	end
	return math.max(tonumber(item.Data and item.Data.Amount) or 1, 0)
end

local function openLoot(kinds)
	local inv = data() and data().Inventory
	if type(inv) ~= "table" then
		return 0
	end
	local queue = {}
	for guid, item in pairs(inv) do
		if type(item) == "table" and OPENERS[item.Type] and (not kinds or kinds[item.Type]) then
			table.insert(queue, { guid = guid, channel = OPENERS[item.Type], name = item.Name })
		end
	end

	local opened = 0
	for _, row in ipairs(queue) do
		local chan = ev(row.channel)
		local strikes = 0
		while chan and stackAmount(row.guid) > 0 and strikes < 3 do
			local before = stackAmount(row.guid)
			chan:Fire(true, "Open", row.guid)
			-- One round trip, then look. A stack that didn't move is the server refusing.
			local deadline = os.clock() + 2
			while stackAmount(row.guid) >= before and os.clock() < deadline do
				task.wait(0.05)
			end
			if stackAmount(row.guid) >= before then
				strikes = strikes + 1
			else
				strikes = 0
				opened = opened + 1
			end
		end
		if strikes >= 3 then
			warn("[deep] " .. tostring(row.name) .. " wouldn't open -- the server is refusing it")
		end
	end
	return opened
end

-- enchant ------------------------------------------------------------------------
-- "Hold an Enchant Stone to enchant your rod" is a denial code the SERVER sends (Enchant
-- Stone -> slot 1, Ultra -> slot 2), so this is the equip-then-fire idiom: the remote
-- ignores its arguments and acts on the Tool in your hand. Inventory items are Tools in
-- the Backpack named by their guid -- rods are the exception, being hotbar tools.
local STONES = { [1] = "Enchant Stone", [2] = "Ultra Enchant Stone" }

local function scrollGuid(name)
	local inv = data() and data().Inventory
	if type(inv) ~= "table" then
		return nil, 0
	end
	for guid, item in pairs(inv) do
		if type(item) == "table" and item.Type == "Scroll" and item.Name == name then
			return guid, math.max(tonumber(item.Data and item.Data.Amount) or 1, 0)
		end
	end
	return nil, 0
end

local function equipGuid(guid)
	local c = char()
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	local tool = player:FindFirstChild("Backpack") and player.Backpack:FindFirstChild(guid)
	if not hum or not tool then
		return false
	end
	pcall(function()
		hum:EquipTool(tool) -- takes out whatever is held first, so a swap is one call
	end)
	task.wait(0.1)
	local held = c:FindFirstChildOfClass("Tool")
	return held ~= nil and held.Name == guid
end

-- The shrine's own prompt is 12 studs and the server has no "too far" denial code, so the
-- range check is probably client-side only -- but a snap costs one teleport and settles it.
local function shrineCF()
	local got, node = pcall(function()
		return Utils.WorldFolder.Path({ "Map", "Enchant", "ProxmityAttachment" }) -- the game's own typo
	end)
	if not got or not node then
		return nil
	end
	if node:IsA("Attachment") then
		return CFrame.new(node.WorldPosition + Vector3.new(0, 3, 0))
	end
	local part = node:IsA("BasePart") and node or node:FindFirstChildWhichIsA("BasePart", true)
	return part and (part.CFrame + Vector3.new(0, 3, 0)) or nil
end

-- Rolls until one of `wanted` lands, or the stones run out. `wanted` empty = roll once.
local function enchantRoll(slot, wanted, snap)
	local chan = ev("Enchant")
	if not chan then
		return 0, "no Enchant channel"
	end
	local stone = STONES[slot]
	local _, have = scrollGuid(stone)
	if have <= 0 then
		return 0, "no " .. stone
	end

	local home
	if snap then
		local cf, hrp = shrineCF(), select(2, char())
		if cf and hrp then
			home = hrp.CFrame
			hop(cf)
			task.wait(SNAP)
		end
	end

	local landed, rolls, reason = nil, 0, nil
	local result, denied
	local key = chan:Connect(function(kind, payload)
		if kind == "Result" then
			result = payload
		elseif kind == "Denied" then
			denied = tostring(payload)
		end
	end)

	while true do
		local guid, left = scrollGuid(stone)
		if not guid or left <= 0 then
			reason = reason or ("out of " .. stone)
			break
		end
		if not equipGuid(guid) then
			reason = "couldn't hold the " .. stone
			break
		end
		result, denied = nil, nil
		chan:Fire(true, "Roll")
		local deadline = os.clock() + 8
		while not result and not denied and os.clock() < deadline do
			task.wait(0.05)
		end
		if denied then
			-- Busy is the shrine's cooldown, not a refusal; everything else is terminal.
			if denied == "Busy" then
				task.wait(1)
			else
				reason = "server said " .. denied
				break
			end
		elseif result and type(result) == "table" then
			rolls = rolls + 1
			landed = result.Name
			if not next(wanted) or wanted[landed] then
				reason = "rolled " .. tostring(landed)
				break
			end
		else
			reason = "the shrine never answered"
			break
		end
		task.wait(0.2)
	end

	pcall(function()
		chan:Disconnect(key)
	end)
	if home then
		hop(home)
	end
	rodOut() -- the stone displaced the rod; the farm needs it back in hand
	return rolls, reason or ("rolled " .. tostring(landed))
end

-- reroll -------------------------------------------------------------------------
-- MutationReroll acts on the fish you hold and spends a Mutation Scroll (or Ultra). The
-- confirm is the fish's own Data.Mutation in the save mirror, not the reply -- the reply
-- is a reveal animation we skip.
local function heldFish()
	local c = char()
	local held = c and c:FindFirstChildOfClass("Tool")
	local inv = data() and data().Inventory
	local item = held and type(inv) == "table" and inv[held.Name]
	if type(item) == "table" and item.Type == "Fish" then
		return held.Name, item
	end
	return nil
end

local function dealerCF()
	local got, node = pcall(function()
		return Utils.WorldFolder.Interactable("MutationDealer")
	end)
	local part = got and node and node:FindFirstChildWhichIsA("BasePart", true)
	return part and (part.CFrame + Vector3.new(0, 3, 0)) or nil
end

local function currentMutation(guid)
	local inv = data() and data().Inventory
	local item = type(inv) == "table" and inv[guid]
	return type(item) == "table" and item.Data and item.Data.Mutation or nil
end

local function rerollHeld(ultra, wanted, snap)
	local chan = ev("MutationReroll")
	if not chan then
		return 0, "no MutationReroll channel"
	end
	local guid = heldFish()
	if not guid then
		return 0, "hold the fish you want rerolled"
	end
	local scroll = ultra and Config.MutationRerollConfig.UltraScrollItem or Config.MutationRerollConfig.ScrollItem

	local home
	if snap then
		local cf, hrp = dealerCF(), select(2, char())
		if cf and hrp then
			home = hrp.CFrame
			hop(cf)
			task.wait(SNAP)
		end
	end

	local spins, reason = 0, nil
	local denied
	local key = chan:Connect(function(kind, payload)
		if kind == "Denied" then
			denied = tostring(payload)
		end
	end)

	-- The reveal is ~5.7s of animation the server drives; Skip cuts it, and "Busy" is the
	-- server telling us we asked again before it finished. Back off on that, nothing else.
	local gap = 0.6
	while true do
		local _, left = scrollGuid(scroll)
		if left <= 0 then
			reason = reason or ("out of " .. scroll)
			break
		end
		if wanted[currentMutation(guid) or "None"] then
			reason = "kept " .. tostring(currentMutation(guid) or "None")
			break
		end
		local before = currentMutation(guid)
		denied = nil
		chan:Fire(true, "Spin", ultra and true or false)
		task.wait()
		chan:Fire(true, "Skip") -- the reveal is client-side theatre; the roll already happened

		local deadline = os.clock() + 10
		while currentMutation(guid) == before and not denied and os.clock() < deadline do
			task.wait(0.05)
		end
		if denied then
			if denied == "Busy" then
				gap = math.min(gap * 1.5, 6)
				task.wait(gap)
			else
				reason = "server said " .. denied
				break
			end
		elseif currentMutation(guid) ~= before then
			spins = spins + 1
			gap = math.max(gap * 0.97, 0.3)
			task.wait(gap)
		else
			-- No change and no refusal: the roll landed on the same mutation. Counts as a spin.
			spins = spins + 1
			task.wait(gap)
		end
		if spins > 500 then
			reason = "stopped at 500 spins"
			break
		end
	end

	pcall(function()
		chan:Disconnect(key)
	end)
	if home then
		hop(home)
	end
	return spins, reason or ("now " .. tostring(currentMutation(guid) or "None"))
end

-- upgrades -----------------------------------------------------------------------
-- Cheapest affordable first, which is also the fastest route to Capacity -- every level is
-- one more fish per cast, and the cast is the expensive part.
local function buyUpgrades()
	local buy = ev("Upgrades")
	if not buy then
		return 0
	end
	local d = data()
	local bought = 0
	for _ = 1, 8 do
		local pick, price
		for _, key in ipairs(Config.UpgradesConfig.Order) do
			local level = d.Upgrades and d.Upgrades[key] or 0
			local row = Config.UpgradesConfig[key]
			if row and level < (row.MaxLevel or 0) then
				local cost = Config.UpgradesConfig.GetPrice(key, level)
				if cost <= (d.Cash or 0) and (not price or cost < price) then
					pick, price = key, cost
				end
			end
		end
		if not pick then
			break
		end
		buy:Fire(true, "Buy", pick)
		bought = bought + 1
		task.wait(0.35) -- the reply is a Replicate; give Cash and Upgrades time to land
	end
	return bought
end

-- loop -------------------------------------------------------------------------
local function setFarm(on)
	farm.on = on
	farm.gen = farm.gen + 1
	local mine = farm.gen
	if not on then
		step("idle")
		return
	end
	task.spawn(function()
		local sinceSell = 0
		while farm.on and farm.gen == mine do
			if not char() then
				step("wait/character")
				say("waiting for a character")
				task.wait(IDLE)
			elseif workspace:GetAttribute("ThrowDisabled") == true then
				step("wait/disabled")
				say("the server has throwing disabled here")
				task.wait(IDLE)
			else
				local equipped, why = rodOut()
				if not equipped then
					step("wait/rod")
					say(why or "no rod")
					task.wait(IDLE)
				else
					if not inArea() then
						step("travel")
						local cf = anchorCF()
						if not cf then
							say("can't find the throw area in this world")
							task.wait(IDLE)
						else
							hop(cf)
						end
					end

					if inArea() then
						topUpBait()
						local result, picks = cast()
						local forceSell = false
						if result == "ok" then
							sinceSell = sinceSell + 1
							local best = picks and picks[1]
							-- receipts, not picks: the server's own count of what it took.
							say(
								("cast %d | %d fish%s | $%s earned")
									:format(
										stats.casts,
										receipts,
										best and (" | best " .. best.rarity .. " " .. best.name) or "",
										tostring(math.floor(stats.earned))
									)
							)
						else
							stats.refused = stats.refused + 1
							say(result)
							if result:find("no room") then
								forceSell = true -- sweep rather than spin on a full bag
							else
								task.wait(IDLE)
							end
						end

						-- Opening is one packet and a look, and a chest sat in the bag is a chest
						-- whose bait and scrolls aren't working for the next cast.
						if autoOpen and farm.on and farm.gen == mine then
							step("open")
							openLoot()
						end

						-- A full bag refuses every cast, so it always ends the run -- the only
						-- question is whether selling is allowed to clear it first.
						local stopWhy
						local full = fullness()
						if autoSell then
							local due = forceSell or (sellEvery > 0 and sinceSell >= sellEvery) or (full and full >= SELL_AT)
							if due and farm.on and farm.gen == mine then
								step("sell")
								local count, total = sellNow()
								sinceSell = 0
								if count > 0 then
									say(("sold %d fish for $%s"):format(count, tostring(math.floor(total))))
								elseif forceSell then
									stopWhy = "backpack full and nothing matches 'Sell up to' -- widen it or clear some fish"
								end
							end
						elseif forceSell then
							stopWhy = "backpack full -- turn Auto sell on, or sell some fish yourself"
						end

						if stopWhy then
							-- Flip the flag ourselves first: a loop thread's Set can fail on
							-- capability, and then the toggle stays lit over a dead loop.
							farm.on = false
							-- Set re-enters the callback, which writes "stopped" -- so say it after.
							pcall(function()
								farmToggle:Set(false)
							end)
							say(stopWhy)
							return
						end
					end
				end
			end
			task.wait(CYCLE_GAP)
		end
		if farm.gen == mine then
			step("idle")
		end
	end)
end

-- Separate thread on purpose: a farm thread parked in a yield can't report that it is.
local dogGen = 0
local function startDog()
	dogGen = dogGen + 1
	local mine = dogGen
	task.spawn(function()
		while dogGen == mine do
			if farm.on and os.clock() - markAt > WATCHDOG then
				warn(("[deep] stuck %ds at: %s"):format(math.floor(os.clock() - markAt), mark))
				markAt = os.clock()
			end
			task.wait(5)
		end
	end)
end

-- gui --------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Deep Fishing", -- fallback until the live name lands
	folder = "DeepFishing", -- never rename: saved configs orphan
	size = UDim2.fromOffset(520, 440),
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Fish", Icon = "solar:waterdrops-bold" })
local Farm = Tab:Section({ Title = "Farm", Icon = "solar:bolt-circle-bold", Box = true, BoxBorder = true, Opened = true })

farmToggle = Farm:Toggle({
	Title = "Auto fish",
	Desc = "Perfect cast, best fish first, no cinematic",
	Value = false,
	Callback = function(on)
		setFarm(on)
		if on then
			say("starting")
		else
			say("stopped")
		end
	end,
})

local catchValues = { "Everything" }
for _, name in ipairs(LADDER) do
	table.insert(catchValues, name)
end
Farm:Dropdown({
	Title = "Catch from",
	Desc = "Anything below this doesn't take a hook slot. Slots are the scarce thing, not casts",
	Values = catchValues,
	Value = catchFloor,
	Callback = function(v)
		if table.find(catchValues, v) then
			catchFloor = v
		end
	end,
})

Farm:Toggle({
	Title = "Feed the streak",
	Desc = "Also sends FishHooked per fish. Costs nothing, keeps the game's streak bonus alive",
	Value = keepStreak,
	Callback = function(on)
		keepStreak = on
	end,
})

local Sell = Tab:Section({ Title = "Sell", Icon = "solar:dollar-minimalistic-bold", Box = true, BoxBorder = true, Opened = true })

Sell:Toggle({
	Title = "Auto sell",
	Desc = "Off until you've set the rule below. With it off, a full backpack stops the farm",
	Value = autoSell,
	Callback = function(on)
		autoSell = on
	end,
})

local sellValues = { "Nothing" }
for _, name in ipairs(LADDER) do
	table.insert(sellValues, name)
end
Sell:Dropdown({
	Title = "Sell up to",
	Desc = "This rarity and everything below it. Uncommon = sell Common/Uncommon, keep Rare+",
	Values = sellValues,
	Value = sellUpTo,
	Callback = function(v)
		if table.find(sellValues, v) then
			sellUpTo = v
		end
	end,
})

Sell:Toggle({
	Title = "Never sell mutated",
	Desc = "A mutated Common outsells a plain Legendary; this keeps it whatever the rarity rule says",
	Value = keepMutated,
	Callback = function(on)
		keepMutated = on
	end,
})

Sell:Input({
	Title = "Sell every N casts",
	Desc = "0 = only when the backpack is nearly full",
	Value = tostring(sellEvery),
	Placeholder = "20",
	Callback = function(v)
		sellEvery = math.max(tonumber(v) or sellEvery, 0)
	end,
})

Sell:Toggle({
	Title = "Walk to the seller",
	Desc = "Parks you at NPC_Sell for the call and puts you back. Off if you know the server doesn't check",
	Value = sellSnap,
	Callback = function(on)
		sellSnap = on
	end,
})

Sell:Button({
	Title = "Sell now",
	Callback = function()
		if farm.on then
			say("turn Auto fish off first -- it would teleport you mid-sweep")
			return
		end
		task.spawn(function()
			local count, total = sellNow()
			say(count == 0 and "nothing matched the rule" or ("sold %d fish for $%s"):format(count, tostring(math.floor(total))))
		end)
	end,
})

local Bait = Tab:Section({ Title = "Bait", Icon = "solar:magnet-bold", Box = true, BoxBorder = true, Opened = true })

Bait:Toggle({
	Title = "Auto use",
	Desc = "Consumes the highest-luck bait in the bag whenever the active charges hit zero",
	Value = autoUseBait,
	Callback = function(on)
		autoUseBait = on
	end,
})

Bait:Toggle({
	Title = "Auto buy",
	Desc = "Buys " .. BUY_QTY .. " when the bag runs out. Only fires when auto use has nothing left to spend",
	Value = autoBuyBait,
	Callback = function(on)
		autoBuyBait = on
	end,
})

local baitValues = { "Best affordable" }
for _, row in ipairs(BAITS) do
	table.insert(baitValues, row.name)
end
Bait:Dropdown({
	Title = "Buy",
	Desc = "Best affordable walks down from the highest luck until the cash and the shelf agree",
	Values = baitValues,
	Value = baitTarget,
	Callback = function(v)
		if table.find(baitValues, v) then
			baitTarget = v
			table.clear(stockAsked) -- a new pick deserves a fresh look at the shelf
			table.clear(stock)
		end
	end,
})

Bait:Toggle({
	Title = "Walk to the bait shop",
	Desc = "Off by default: the buy is a UI remote with no distance code. Turn it on if buys get refused",
	Value = baitSnap,
	Callback = function(on)
		baitSnap = on
	end,
})

Bait:Button({
	Title = "Use now",
	Desc = "Spends one of the highest-luck bait in the bag, whatever the active charges are",
	Callback = function()
		local guid, luck = bestBaitGuid()
		local consume = guid and ev("ConsumeBait")
		if not consume then
			say("no bait in the backpack")
			return
		end
		consume:Fire(true, guid)
		say(("used the best bait (luck %s) -- 5 casts"):format(tostring(luck)))
	end,
})

Bait:Button({
	Title = "Buy now",
	Callback = function()
		task.spawn(function()
			local row, why = pickBait()
			if not row then
				say(why or "nothing to buy")
				return
			end
			local n, reason = buyBait(row, BUY_QTY)
			say(reason .. (n > 0 and ("  (%d in the bag)"):format(baitCount(row.name)) or ""))
		end)
	end,
})

local Extra = Tab:Section({ Title = "Extras", Icon = "solar:star-bold", Box = true, BoxBorder = true, Opened = true })

Extra:Button({
	Title = "Buy upgrades",
	Desc = "Cheapest affordable first -- Capacity is more fish per cast",
	Callback = function()
		task.spawn(function()
			local n = buyUpgrades()
			say(n == 0 and "nothing affordable" or ("bought %d upgrades"):format(n))
		end)
	end,
})

Extra:Button({
	Title = "Redeem codes",
	Desc = "The list comes from the game's own CodesConfig, so it's never stale",
	Callback = function()
		local codes = ev("Codes")
		if not codes then
			return
		end
		task.spawn(function()
			local n = 0
			for _, row in ipairs(Config.CodesConfig.Codes or {}) do
				if type(row) == "table" and type(row.Code) == "string" then
					codes:Fire(true, row.Code)
					n = n + 1
					task.wait(0.35)
				end
			end
			say(("sent %d codes -- the game says which landed"):format(n))
		end)
	end,
})

local worldValues = {}
for key in pairs(Config.WorldsConfig.Worlds) do
	if not Config.WorldsConfig.Worlds[key].NoFishing then
		table.insert(worldValues, key)
	end
end
table.sort(worldValues)
Extra:Dropdown({
	Title = "Go to world",
	Desc = "Costs the unlock price the first time. The farm re-finds the throw area by itself",
	Values = worldValues,
	Value = worldValues[1],
	Callback = function(v)
		if not table.find(worldValues, v) then
			return
		end
		local tp = ev("Teleport")
		if tp then
			tp:Fire(true, v)
			say("asked for " .. v)
		end
	end,
})

-- Loot tab ----------------------------------------------------------------------
-- WindUI hands a Multi dropdown's callback one of three shapes depending on the build
-- panel.lua fetched: a list, a map, or the row tables back. Normalise into a set we own --
-- reading a map as a list leaves the set empty, and an empty set matches nothing.
local function ticked(v)
	local set = {}
	if type(v) ~= "table" then
		return set
	end
	for k, val in pairs(v) do
		if type(k) == "number" then
			local name = type(val) == "table" and (val.Title or val.Value) or val
			if type(name) == "string" then
				set[name] = true
			end
		elseif val == true then
			set[k] = true
		end
	end
	return set
end

local Loot = Window:Tab({ Title = "Loot", Icon = "solar:box-bold" })
local Open = Loot:Section({ Title = "Chests & cages", Icon = "solar:box-minimalistic-bold", Box = true, BoxBorder = true, Opened = true })

Open:Toggle({
	Title = "Open as they come in",
	Desc = "Chests, cages and Like Gifts. One packet each, no walking, nothing to equip",
	Value = autoOpen,
	Callback = function(on)
		autoOpen = on
	end,
})

Open:Button({
	Title = "Open everything now",
	Callback = function()
		task.spawn(function()
			local n = openLoot()
			say(n == 0 and "nothing to open" or ("opened %d"):format(n))
		end)
	end,
})

local Ench = Loot:Section({ Title = "Enchant", Icon = "solar:magic-stick-3-bold", Box = true, BoxBorder = true, Opened = true })

-- Label each enchant with what it actually does, and keep a label -> name map: the ticked
-- set is keyed on the label the dropdown hands back, not on the enchant's own name.
local enchantValues = { [1] = {}, [2] = {} }
local enchantOf = {}
do
	for name, info in pairs(Config.EnchantConfig.Items) do
		-- Pool() skips Locked entries, so the shrine can never roll one: listing it would
		-- be a "stop at" that spins until the stones run out and never says why.
		if not info.Locked then
			local bits = {}
			for effect, amount in pairs(info.Effects or {}) do
				table.insert(bits, effect .. " " .. tostring(amount))
			end
			table.sort(bits)
			local label = name .. (#bits > 0 and (" (" .. table.concat(bits, ", ") .. ")") or "")
			enchantOf[label] = name
			table.insert(enchantValues[info.Slot == 2 and 2 or 1], label)
		end
	end
	table.sort(enchantValues[1])
	table.sort(enchantValues[2])
end

local enchantSlot = 1
local enchantWanted = {}
local enchantDrop

Ench:Dropdown({
	Title = "Slot",
	Desc = "Normal spends an Enchant Stone (slot 1); Ultra spends an Ultra Stone (slot 2)",
	Values = { "Normal", "Ultra" },
	Value = "Normal",
	Callback = function(v)
		enchantSlot = v == "Ultra" and 2 or 1
		table.clear(enchantWanted) -- the old picks belong to the other slot's list
		if enchantDrop then
			pcall(function()
				enchantDrop:Refresh(enchantValues[enchantSlot])
			end)
		end
	end,
})

enchantDrop = Ench:Dropdown({
	Title = "Stop at",
	Desc = "Rolls until one of these lands or the stones run out. Nothing ticked = roll once",
	Values = enchantValues[1],
	Multi = true,
	AllowNone = true,
	Value = {},
	Callback = function(v)
		table.clear(enchantWanted) -- held live by a running roll; replacing it would orphan the read
		for label in pairs(ticked(v)) do
			local name = enchantOf[label]
			if name then
				enchantWanted[name] = true
			end
		end
	end,
})

Ench:Button({
	Title = "Roll the shrine",
	Callback = function()
		if farm.on then
			say("turn Auto fish off first -- enchanting swaps the rod out of your hand")
			return
		end
		task.spawn(function()
			local rolls, why = enchantRoll(enchantSlot, enchantWanted, sellSnap)
			say(("%d rolls -- %s"):format(rolls, why))
		end)
	end,
})

local Roll = Loot:Section({ Title = "Mutation reroll", Icon = "solar:refresh-bold", Box = true, BoxBorder = true, Opened = true })

local mutationValues = { "None" }
for _, name in ipairs(Config.MutationRerollConfig.RollOrder()) do
	table.insert(mutationValues, name)
end
local mutationWanted = {}
local rerollUltra = false

Roll:Toggle({
	Title = "Ultra scrolls",
	Desc = "Spends Ultra Mutation Scrolls: better odds, and size only ever goes up",
	Value = rerollUltra,
	Callback = function(on)
		rerollUltra = on
	end,
})

Roll:Dropdown({
	Title = "Stop at",
	Desc = "Spins the held fish until its mutation is one of these, or the scrolls run out",
	Values = mutationValues,
	Multi = true,
	AllowNone = true,
	Value = {},
	Callback = function(v)
		table.clear(mutationWanted)
		for name in pairs(ticked(v)) do
			mutationWanted[name] = true
		end
	end,
})

Roll:Button({
	Title = "Reroll held fish",
	Desc = "Equip the fish first -- the remote acts on what you hold",
	Callback = function()
		if farm.on then
			say("turn Auto fish off first -- rerolling needs the fish in your hand, not the rod")
			return
		end
		if not next(mutationWanted) then
			say("tick at least one mutation, or it would spin forever")
			return
		end
		task.spawn(function()
			local spins, why = rerollHeld(rerollUltra, mutationWanted, sellSnap)
			say(("%d spins -- %s"):format(spins, why))
		end)
	end,
})

-- Two rows, one message: half the buttons live on the Loot tab and a status you have to
-- switch tabs to read is a status nobody reads.
local lines = {
	Extra:Paragraph({ Title = "Status", Desc = "idle" }),
	Roll:Paragraph({ Title = "Status", Desc = "idle" }),
}

-- A resumed loop thread lacks the capability the hidden GUI needs; Heartbeat runs with ours.
local drain = RunService.Heartbeat:Connect(function()
	if pending == nil then
		return
	end
	local msg = pending
	pending = nil
	local wrote = false
	for _, row in ipairs(lines) do
		if pcall(function()
			row:SetDesc(msg)
		end) then
			wrote = true
		end
	end
	if not wrote then
		log(msg)
	end
end)

startDog()

do
	local cap, free = claimCap()
	say(("ready -- %d hook slots, %d backpack slots free"):format(cap, free))
end

-- close ------------------------------------------------------------------------
local function stopAll()
	setFarm(false)
	dogGen = dogGen + 1
	-- The server's cast guard outlives the panel; leaving it set refuses your next manual cast.
	pcall(function()
		local cancel = ev("CancelThrow")
		if cancel then
			cancel:Fire(true)
		end
	end)
	pcall(function()
		drain:Disconnect()
	end)
	pcall(function()
		if stockConn then
			stockConn:Disconnect()
		end
	end)
	pcall(function()
		local chan = ev("FishesReceivedNotification")
		if chan and receiptConn then
			chan:Disconnect(receiptConn)
		end
	end)
end

Window:OnDestroy(function()
	stopAll()
	getgenv().deepFishingStop = nil
end)

getgenv().deepFishingStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().deepFishingStop = nil
end
