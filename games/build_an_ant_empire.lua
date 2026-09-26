--[[ Build an Ant Empire -- claim, sell, roll, upgrade (78490532994307)

     The server's own ECS systems ship to the client (ReplicatedStorage.Battle.Game.Ecs.
     Player.Player_Server), so every rule below is read, not guessed. Everything goes over
     one socket: EventBus.RemoteEvent:FireServer("ECS_COMMAND", name, args).

     CLAIM: ClaimAntReward for every equipped slot on a 3.1s beat. The server's only gate is
            3s per slot; the game fires it once per ant walk (~30s). Probed: 10 payouts in
            30s against 0 walking. The food lands in a per-slot store (no cap), and
            ClaimWorkerAntFood moves it to you -- exact amounts, read off AntFoodStore.
     SELL : the price is uniform 0.5-2.0 gold/food, rerolled every 20s per server
            (FoodSellPriceService). Food has no cap and no other use, so hold it and sell
            all of it whenever the price is at or above the slider. SellShopVIP pins 2.5.
     ROLL : RollAnt is free (3s server cooldown). Keeping a rolled ant is ClaimRolledAnt at
            that unit's Price -- and a claim you can't afford opens a Robux prompt, so every
            buy needs gold >= cost x GOLD_MARGIN + reserve on a fresh read. Buys when it beats
            your weakest equipped ant (or a slot is empty) and/or meets the minimum rarity.
            Equip best (the game's own action) runs once after new ants land.
     UPGRD: Balanced buys whatever adds the most (power x food multiplier) per gold: global
            Ant Attack, per-ant levels (+10% each), ant slots. Nest layers, queen, luck and
            roll count don't pay directly; they're bought when they cost under
            INDIRECT_MINUTES of income. Ant move speed only changes how fast ants WALK, which
            fast claiming no longer waits on, so Balanced never buys it. Custom weights all
            eight. AddAntSlot short of gold is a Robux prompt too -- same gold gate. Ant levels
            take a cap, and "Strongest 3 only" keeps levels off ants a roll will replace.
     SHOP : GearShopRequest Purchase for the ticked items while the 5-min stock lasts, priciest
            first. Short of gold is a plain refusal here; the Robux restock is never touched.
     POTN : a mutation potion only takes on an ant with NO mutation (BackPackStore
            ApplyMutationPotion: "AntAlreadyMutated"), so upgrading Leaf -> Petal is Remove
            Mutation first, then the potion. Goes on the ant it adds the most to. Jellies are
            never applied -- they speed up walking, which fast claim doesn't wait on.
     RWRD : online-time, 7-day, index (ants + mutations) and group rewards, the same free
            WuKong actions the game's buttons send; a claim that isn't ready is refused, free.
     DNGN : walks into each new dungeon entrance, starts the fight, spams the boost click (no
            server rate limit), stands on every time coin, and puts you back home after. Pays
            pet tokens per boss, and at most one egg a run.
     EGGS : places eggs on your room's pet range, hatches them at HatchAt, spends pet tokens
            on the ticked eggs. Placing needs the egg HELD first -- SetBackpackHeldEntry.
     PETS : best pets by effect (food value, double food > luck > walk speed) into your pet
            slots; pet levels join the upgrade spender's payback pool on their own toggle.
     AFK  : a F15 keypress after a minute of no input resets the game's 17-min idle reconnect
            (AfkReconnectConfig), and a real disconnect rejoins.

     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().antEmpireStop() ]]

-- config ---------------------------------------------------------------------
local CLAIM_GAP = 3.1 -- ClaimAntRewardSystem pays a slot once per 3.0s; the extra 0.1 keeps "TooSoon" out of its log
local ROLL_GAP = 3.1 -- RollAnt cooldown (ConstConfig, 3s). Faster rolls are dropped, not queued
local SPEND_GAP = 0.8 -- seconds between two gold spends, so the gold mirror catches up. Raise on a laggy server
local GOLD_MARGIN = 1.02 -- spend only when gold covers cost x this: a spend the server finds short is a Robux popup
local UPGRADE_TICK = 1 -- auto-upgrade decision beat
local EQUIP_DELAY = 1.5 -- after the last ant bought / slot unlocked, equip best once
local INDIRECT_MINUTES = 5 -- queen / luck / roll count / layers buy when they cost under this much income
local SAVE_RATIO = 0.5 -- buy an affordable upgrade only if it's at least this good as the best one; else save up
local INVOKE_TIMEOUT = 8 -- WuKong actions are InvokeServer, which never times out on its own
local SELL_AT = 1.5 -- default sell threshold (base gold per food)
local LEVEL_TOP = 3 -- "Strongest only" levels this many ants
local POTION_TICK = 2 -- potion check beat
local APPLY_WAIT = 3 -- seconds for the backpack to show a Remove before the potion goes on
local REWARD_TICK = 60 -- reward check beat; the online reward's tiers are minutes apart
local AFK_BEAT = 60 -- nudge after this long without your own input
local REJOIN_DELAY = 3
local DUNGEON_POLL = 5 -- entrance check beat; one spawns at most every 5 min
local ENTER_TIMEOUT = 25 -- seconds from the prompt to a session id: the cutscene handshake is ~10s
local CLICK_GAP = 0.05 -- boost clicks: 2 points each, 50 = 2x, 100 = 4x. Faster fills the meter sooner
local COIN_RETRY = 1 -- seconds before re-trying a time coin pickup
local EGG_TICK = 5 -- egg place / hatch / buy beat
local EGG_SPACING = 6 -- studs between placed eggs on the pet range grid
local PET_TICK = 5 -- pet equip beat
-- ponytail: fixed pet weights by effect. Food value and double food both scale income 1:1;
-- luck only rolls better; move speed is walking, which fast claim skips
local PET_WEIGHT = {
	PetFoodValueBonusPercent = 1,
	PetDoubleFoodChancePercent = 1,
	PetLuckBonusPercent = 0.25,
	PetAntMoveSpeedBonusPercent = 0,
}

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer

if getgenv and getgenv().antEmpireStop then
	getgenv().antEmpireStop() -- re-running must not stack a second panel/loop
end

local Bus = RS:WaitForChild("Packages"):WaitForChild("EventBus"):WaitForChild("RemoteEvent", 10)
local WuKong = require(RS:WaitForChild("WuKong"))
local FoodStore = require(RS:WaitForChild("WuKongHooks"):WaitForChild("AntFoodStore"))
local Backpack = require(RS:WaitForChild("UI"):WaitForChild("Backpack"):WaitForChild("Model"):WaitForChild("BackpackModel"))
local AntHelper = require(RS:WaitForChild("Helper"):WaitForChild("AntAttributeHelper"))
local LuckQueen = require(RS.Helper:WaitForChild("LuckQueenProgression"))
local Gen = RS:WaitForChild("_genConfigs")
local UNITS = require(Gen:WaitForChild("battle_tbunit"))
local TAGS = require(Gen:WaitForChild("battle_tbtag"))
local ATTRS = require(Gen:WaitForChild("battle_tbattribute"))
local SLOT_PRICES = require(Gen:WaitForChild("battle_tbnestunlock"))
local ITEMS = require(Gen:WaitForChild("ui_tbbackpackitem"))
local ONLINE = require(Gen:WaitForChild("battle_tbonlineaward"))
local Mutation = require(RS:WaitForChild("Configs"):WaitForChild("MutationCrystalConfig"))
local EGG_SHOP = require(Gen:WaitForChild("event_peteggshop"))
local Battle = RS:WaitForChild("Battle"):WaitForChild("Game")
local DUNGEON = require(Battle:WaitForChild("Config"):WaitForChild("DungeonConfig"))
local PetSkills = require(Battle:WaitForChild("Ecs"):WaitForChild("Pets"):WaitForChild("PetSkills"))
local PetConfig = require(Battle.Ecs.Pets:WaitForChild("EquippedPetConfig"))

-- The server's attribute keys (battle_tbattribute). Rank order from PlayerDataHelper's
-- paid-vendor table; OP sits below Celestial, the unit prices agree.
--
-- Every Chinese string is written as decimal byte escapes, the way the game's decompiled
-- source has them: an executor that reads the paste as Latin-1 mangles a UTF-8 literal
-- (/货币/ arrived garbled, KeyNotFoundException). Keep every string literal ASCII;
-- comments don't run, so the Chinese beside each escape stays for reading.
local A = {
	attack = "\232\154\130\232\154\129\230\148\187\229\135\187\229\138\155", -- 蚂蚁攻击力 ant attack: every payout x (1 + value)
	speed = "\232\154\130\232\154\129\231\167\187\233\128\159", -- 蚂蚁移速 ant move speed: walking only
	layer = "\229\183\162\231\169\180\229\177\130\230\149\176", -- 巢穴层数 nest layers: unlock slot rows
	queen = "\232\154\129\229\144\142\231\173\137\231\186\167", -- 蚁后等级 queen level: rarity pool, luck cap
	luck = "\229\185\184\232\191\144\229\128\188", -- 幸运值 luck
	roll = "\229\141\149\230\138\189\230\149\176\233\135\143", -- 单抽数量 ants per roll
}
local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Exotic", "Secret", "Divine", "OP", "Celestial" }
local BUY = "?\232\180\173\228\185\176" -- ?购买, the action suffix
local EQUIP_BEST = "/\232\131\140\229\140\133\231\179\187\231\187\159/\232\131\140\229\140\133\232\163\133\229\164\135\230\156\128\228\189\179\229\141\149\228\189\141" .. BUY -- /背包系统/背包装备最佳单位
local MERCHANT = "/\229\138\159\232\131\189\229\149\134\228\186\186/" -- /功能商人/
local ONLINE_ACT = MERCHANT .. "\229\156\168\231\186\191\229\165\150\229\138\177\233\162\134\229\143\150" .. BUY -- 在线奖励领取
local SEVEN_ACT = MERCHANT .. "\228\184\131\230\151\165\229\165\150\229\138\177\233\162\134\229\143\150" .. BUY -- 七日奖励领取
local GROUP_ACT = "/\230\180\187\229\138\168/\231\190\164\231\187\132\229\165\150\229\138\177/\231\190\164\231\187\132\230\175\143\230\151\165\229\165\150\229\138\177" .. BUY -- /活动/群组奖励/群组每日奖励
local INDEX_ACT = "/\229\155\190\233\137\180\231\179\187\231\187\159/\233\162\134\229\143\150\229\155\190\233\137\180\229\165\150\229\138\177" .. BUY -- /图鉴系统/领取图鉴奖励
-- ponytail: IndexRewardConfig's two tracks, copied; a third track needs a line here
local INDEX_TRACKS = {
	AntCollectReward = "\232\154\130\232\154\129\229\155\190\233\137\180\229\165\150\229\138\177\232\191\155\229\186\166", -- 蚂蚁图鉴奖励进度
	MutationCollectReward = "\231\170\129\229\143\152\229\155\190\233\137\180\229\165\150\229\138\177\232\191\155\229\186\166", -- 突变图鉴奖励进度
}
local CURRENCY = "/\232\180\167\229\184\129/" -- /货币/
local PROPERTY = "/\229\177\158\230\128\167/" -- /属性/
local COUNT = "?\229\177\158\230\128\167\230\149\176\233\135\143" -- ?属性数量
local GOLD = "\233\135\145\229\184\129" -- 金币
local FOOD = "\233\163\159\231\137\169" -- 食物
local CURRENT_QUEEN = "\229\189\147\229\137\141\232\154\129\229\144\142\231\173\137\231\186\167" -- 当前蚁后等级
local PET_TOKEN = "\229\174\160\231\137\169\228\187\163\229\184\129" -- 宠物代币
local PET_MAX = "\229\174\160\231\137\169\230\156\128\229\164\167\232\163\133\229\164\135\230\149\176\233\135\143" -- 宠物最大装备数量
local EGG_BUY = MERCHANT .. "\232\180\173\228\185\176\229\174\160\231\137\169\232\155\139" .. BUY -- 购买宠物蛋

for _ = 1, 60 do -- the WuKong facade answers nothing until the server has handed it your data
	if player:GetAttribute("PlayerWukongReady") then
		break
	end
	task.wait(0.5)
end

-- world ----------------------------------------------------------------------
local conns = {}

local function raw(...) -- EventBus events outside the ECS whitelist (shop, potions)
	pcall(Bus.FireServer, Bus, ...)
end
local function cmd(name, args)
	raw("ECS_COMMAND", name, args)
end

local function query(path)
	local ok, v = pcall(WuKong.ExecuteQuery, WuKong, path)
	return ok and tonumber(v) or nil -- nil = couldn't read; every gate below refuses on nil
end
local function prop(name)
	return query(PROPERTY .. name .. COUNT)
end
local function gold()
	return query(CURRENCY .. GOLD .. COUNT)
end
local function food()
	return query(CURRENCY .. FOOD .. COUNT)
end

-- attribute -> { level, value, nextValue, cost } ; cost is nil at max. The price on a
-- level's row is what it costs to leave it (PlayerDataHelper.GetPlayerUpgradeAttributeInfo).
local ROWS = {}
for name, cfg in ATTRS do
	ROWS[name] = {}
	for _, row in cfg.Info or {} do
		ROWS[name][row.Level] = row
	end
end
local function attr(name)
	local lv = prop(name)
	if not lv then
		return nil
	end
	lv = math.max(math.floor(lv), 1)
	local cur, nxt = ROWS[name][lv], ROWS[name][lv + 1]
	if not cur then
		return nil
	end
	return { level = lv, value = cur.Value or lv, nextValue = nxt and nxt.Value, cost = nxt and cur.Price or nil }
end

-- A backpack V packs unit, trait and exp: ((unit-1) * 64 + tag) * 512 + exp + 1.
local function decode(V)
	V = tonumber(V)
	if not V or V < 1 then
		return nil
	end
	local n = math.floor(V) - 1
	local rest = n // 512
	local exp, tag, unit = n % 512, rest % 64, rest // 64 + 1
	local cfg = UNITS["Unit" .. unit]
	if not cfg or not cfg.Attack then
		return nil -- pets and ride-only units share the encoding and have no Attack
	end
	local t = TAGS[tag]
	local mul = t and t.Mul or 1
	return {
		unit = cfg,
		exp = exp,
		tag = tag,
		mul = mul,
		price = tonumber(cfg.Price) or 0,
		power = AntHelper.GetAttackByExp(cfg.Attack, exp, mul),
		base = AntHelper.GetAttackByExp(cfg.Attack, exp, 1), -- what a mutation multiplies
	}
end
assert(decode(1).unit.Id == "Unit1" and decode(163841).unit.Id == "Unit6" and decode(32769).unit.Id == "Unit2")

-- Equipped ants, unlocked slot count, the weakest equipped and the best spare. nil when the
-- backpack hasn't loaded -- never an empty nest, which would read as "buy everything".
local function readAnts()
	local ok, data = pcall(Backpack.Load, Backpack, player)
	if not ok or type(data) ~= "table" or type(data.EquippedBySlot) ~= "table" or next(data.EquippedBySlot) == nil then
		return nil
	end
	local st = {
		slots = {},
		count = 0,
		unlocked = 0,
		weakest = math.huge,
		spare = 0,
		total = 0,
		items = data.ItemStacks or {},
		pets = data.Pets or {}, -- key -> { Id, Level, Size }
		equippedPets = data.EquippedPets or {},
		eggs = data.PetEggStacks or {}, -- egg id -> count
	}
	for _, on in data.UnlockedAntSlots or {} do
		if on then
			st.unlocked += 1
		end
	end
	for k, e in data.EquippedBySlot do
		local s, a = tonumber(k), type(e) == "table" and decode(e.V)
		if s and a then
			st.slots[s] = a
			st.count += 1
			st.total += a.power
			st.weakest = math.min(st.weakest, a.power)
		end
	end
	for v, n in data.Stacks or {} do
		local a = (tonumber(n) or 0) > 0 and decode(v)
		if a then
			st.spare = math.max(st.spare, a.power)
		end
	end
	if st.weakest == math.huge then
		st.weakest = 0
	end
	return st
end
table.insert(conns, Backpack:BindUpdated(function() end)) -- registers the backpack's client observer

-- The next slot AddAntSlot will take: SlotBuyable is the room's own "unlock prompt here" flag.
-- nil, false = room not streamed in (don't conclude anything); nil, true = none left in these layers.
local function buyableSlot()
	local room = workspace:FindFirstChild("Rooms")
	room = room and room:FindFirstChild(tostring(player:GetAttribute("RoomIndex")))
	local pos = room and room:FindFirstChild("AntPos")
	if not pos then
		return nil, false
	end
	local best
	for _, m in pos:GetDescendants() do
		if m:IsA("Model") and m:GetAttribute("SlotBuyable") == true and m:GetAttribute("SlotUnlocked") ~= true then
			local s = tonumber(m.Name)
			if s and (not best or s < best) then
				best = s
			end
		end
	end
	return best, true
end

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qn", "Sx", "Sp", "Oc", "No", "Dc" }
local function short(n)
	n = tonumber(n) or 0
	local i = 1
	while math.abs(n) >= 1000 and i < #SUFFIX do
		n /= 1000
		i += 1
	end
	return i == 1 and tostring(math.floor(n)) or ("%.2f%s"):format(n, SUFFIX[i])
end
assert(short(999) == "999" and short(1500) == "1.50K")

local function parseAmount(s)
	s = tostring(s or ""):gsub("[%$,%s]", "")
	local num, suf = s:match("^(-?%d*%.?%d+)(%a*)$")
	if not num then
		return nil
	end
	local i = suf == "" and 1 or table.find(SUFFIX, suf:sub(1, 1):upper() .. suf:sub(2):lower())
	return i and tonumber(num) * 1000 ^ (i - 1) or nil
end
assert(parseAmount("25k") == 25000 and parseAmount("1.5M") == 1.5e6 and parseAmount("0") == 0)

-- farm -----------------------------------------------------------------------
local pending -- status text; a resumed loop thread can't touch the panel, Heartbeat drains it
local function say(msg)
	pending = msg
	print("[ant] " .. msg)
end

local opts = {
	sellOn = false,
	sellAt = SELL_AT,
	stronger = true,
	minRarityOn = false,
	minRarity = "Epic",
	equipOn = false,
	reserve = 0,
	mode = "Balanced",
	claimGap = CLAIM_GAP,
	waitMin = 10, -- minutes of income we'll pause rolling to afford a better ant; 0 = never
	upgradeOn = false,
	levelOn = false,
	petLevelOn = false,
	dungeonOn = false,
	maxLevel = 512, -- AntAttributeHelper: exp caps at 511, so level 512
	levelWhich = "All equipped",
}
local shopWanted = {} -- ItemId -> true; filled from the dropdown, cleared in place
local shop = { stock = {}, nextAt = 0 } -- GearShopSnapshot mirror
local BALANCED = { attack = 1, antLevel = 1, petLevel = 1, slot = 1, layer = 1, queen = 1, luck = 1, roll = 1, speed = 0 }
local OWN_TOGGLE = { antLevel = "levelOn", petLevel = "petLevelOn" } -- everything else is Auto upgrade's
local weights = table.clone(BALANCED)

local price = { base = nil, mult = 1, untilT = 0 } -- from SellFoodPriceUpdate
local stats = { collected = 0, sold = 0, bought = 0, upgrades = 0, since = os.clock() }
local lastBuy, lastSpend, equipDue = "-", 0, nil

-- One spender at a time, and never two within SPEND_GAP: the check and the set don't yield,
-- so two threads can't both pass it.
local function takeSpend()
	if os.clock() - lastSpend < SPEND_GAP then
		return false
	end
	lastSpend = os.clock()
	return true
end

local function invokeTimed(fn)
	local done, res
	task.spawn(function()
		local ok, r = pcall(fn)
		done, res = true, ok and r or nil
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < INVOKE_TIMEOUT do
		task.wait(0.1)
	end
	return res
end

local function sellNow()
	if not opts.sellOn or not price.base or price.base < opts.sellAt then
		return
	end
	if price.untilT - os.clock() < 1 then
		return -- about to reroll, and the server prices at the moment it sells
	end
	local f = food()
	if f and f >= 1 then
		cmd("SellPlayerFood", { Source = "PlayerFoodPrompt", FoodAmount = math.floor(f) })
	end
end

-- Moves everything the slot stores hold into your food. A slot the game's own worker ant
-- emptied first is refused alone ("NotEnoughFood"); the rest still go through.
local function collectFood()
	local ok, data = pcall(FoodStore.GetClientData)
	local claims, sum = {}, 0
	for k, v in ok and data.Slots or {} do
		local s, n = tonumber(k), math.floor(tonumber(v) or 0)
		if s and n > 0 then
			table.insert(claims, { SlotIndex = s, Amount = n })
			sum += n
		end
	end
	if #claims > 0 then
		cmd("ClaimWorkerAntFood", { Claims = claims, SubmissionId = HttpService:GenerateGUID(false) })
		stats.collected += sum
	end
end

local function claimer(alive)
	pcall(FoodStore.GetClientData) -- first call registers the store observer
	local warned = false
	while alive() do
		local st = readAnts()
		if st and st.count > 0 then
			local idx = {}
			for s in st.slots do
				table.insert(idx, s)
			end
			cmd("ClaimAntReward", { AntIndices = idx })
		elseif not warned then
			warned = true
			say("backpack not loaded yet -- claiming starts when it is")
		end
		task.wait(opts.claimGap / 2) -- payouts reach the client store in about a ping; collect mid-beat
		collectFood()
		sellNow() -- food keeps arriving through a good price window
		task.wait(opts.claimGap / 2)
	end
end

local function priceWatcher(alive)
	while alive() do
		cmd("RequestSellFoodPrice", { Source = "SellShopModel" })
		-- next ask lands just after the reroll; the reply's RemainingSeconds says when
		task.wait(math.clamp(price.untilT - os.clock() + 0.3, 1, 21))
	end
end

local function rank(r)
	return table.find(RARITIES, r) or 0
end

-- Food per second is (sum of power) x (1 + attack value) / claim gap, so every direct
-- upgrade is scored as gain in (power x multiplier) per gold.
local function avgGoldPerFood()
	return (opts.sellAt + 2) / 2 * (price.mult or 1) -- mean of the prices we sell at
end
local function incomePerSec(st)
	local atk = attr(A.attack)
	return st.total * (1 + (atk and atk.value or 0)) / opts.claimGap * avgGoldPerFood()
end

-- A rolled ant that passes the filters but costs more than we have. A pending roll is only
-- ever "Replaced" by the NEXT roll (RollAntSystem.setPendingRollResults), so rolling pauses
-- and it stays claimable -- and every other spender leaves its price alone meanwhile.
local held -- { id, cost, label, giveUp }
local function spendable(g)
	return g - opts.reserve - (held and held.cost * GOLD_MARGIN or 0)
end

-- A roll batch: buy what qualifies, strongest first, against a virtual nest so two good
-- rolls don't both count as beating the same weakest ant.
local function onRoll(p)
	local deadline = os.clock() + 2 -- a batch is "Replaced" 3s after the next roll lands
	while not takeSpend() do
		if os.clock() > deadline then
			return
		end
		task.wait(0.1)
	end
	local st, g = readAnts(), gold()
	if not st or not g then
		return
	end
	local nest = {}
	for _, a in st.slots do
		table.insert(nest, a.power)
	end
	for _ = #nest + 1, st.unlocked do
		table.insert(nest, 0) -- an empty unlocked slot is beaten by anything
	end
	table.sort(nest)
	local picks = {}
	for _, r in p.Results do
		local cfg = type(r) == "table" and r.ClaimId and UNITS[r.UnitId]
		if cfg and cfg.Attack then
			local t = TAGS[tonumber(r.TagId) or 0]
			table.insert(picks, { r = r, power = AntHelper.GetAttackByExp(cfg.Attack, 0, t and t.Mul or 1) })
		end
	end
	table.sort(picks, function(a, b)
		return a.power > b.power
	end)
	local budget = g - opts.reserve
	for _, pk in picks do
		local cost = tonumber(pk.r.Cost) or math.huge
		local okRarity = not opts.minRarityOn or rank(pk.r.Rarity) >= rank(opts.minRarity)
		local okStrong = not opts.stronger or (nest[1] ~= nil and pk.power > nest[1])
		local label = ("%s %s (%s, %s power)"):format(pk.r.Rarity, pk.r.UnitId, short(cost), short(pk.power))
		if okRarity and okStrong and cost * GOLD_MARGIN <= budget then
			cmd("ClaimRolledAnt", { ClaimId = pk.r.ClaimId })
			budget -= cost
			lastSpend = os.clock()
			if nest[1] then
				nest[1] = pk.power
				table.sort(nest)
			end
			lastBuy = label
		elseif okRarity and okStrong and opts.waitMin > 0 then
			-- worth waiting for only if income covers the gap inside the cap
			local rate = incomePerSec(st)
			local secs = rate > 0 and (cost * GOLD_MARGIN - budget) / rate or math.huge
			if secs <= opts.waitMin * 60 then
				held = { id = pk.r.ClaimId, cost = cost, label = label, giveUp = os.clock() + secs * 1.5 + 30 }
				say(("rolling paused: saving for %s, ~%d min"):format(label, math.ceil(secs / 60)))
				return -- a weaker buy now would only push this one further off
			end
		end
	end
end

local rollOn = false
local function roller(alive)
	local q, cur = attr(A.queen), prop(CURRENT_QUEEN)
	if q and cur and cur >= 1 and cur < q.level then
		cmd("SetCurrentAntQueenLevel", { Level = q.level }) -- a lower queen pool is worse at every rarity
	end
	while alive() do
		if held then
			local g = gold()
			if g and held.cost * GOLD_MARGIN <= g - opts.reserve and takeSpend() then
				cmd("ClaimRolledAnt", { ClaimId = held.id })
				lastBuy, held = held.label, nil
				say("bought the ant we saved for: " .. lastBuy)
			elseif os.clock() > held.giveUp then
				say("gave up saving for " .. held.label .. " -- income ran slower than estimated")
				held = nil
			end
			task.wait(0.5)
		else
			cmd("RollAnt", { Source = "ProximityPrompt" })
			task.wait(ROLL_GAP)
		end
	end
end

local function equipper(alive)
	equipDue = os.clock()
	while alive() do
		if equipDue and os.clock() >= equipDue then
			equipDue = nil
			invokeTimed(function()
				return WuKong:ExecuteAction(EQUIP_BEST, "__null__", "__null__", { "[]" })
			end)
		end
		task.wait(0.5)
	end
end

local function candidates(st)
	local w = opts.mode == "Balanced" and BALANCED or weights
	local list = {}
	local function add(key, label, cost, gain, run)
		-- ant levels belong to their own toggle, everything else to Auto upgrade; one pool, so
		-- with both on a level still competes on payback against Attack and slots
		local enabled = opts[OWN_TOGGLE[key] or "upgradeOn"]
		if enabled and cost and cost > 0 and w[key] > 0 then
			table.insert(list, { label = label, cost = cost, score = gain and gain / cost * w[key], run = run })
		end
	end
	local atk = attr(A.attack)
	local mult = 1 + (atk and atk.value or 0)
	local income = st.total * mult / opts.claimGap * avgGoldPerFood() -- gold per second

	if atk and atk.cost then
		add("attack", "Ant Attack " .. atk.level + 1, atk.cost, st.total * (atk.nextValue - atk.value), function()
			cmd("UpgradePlayerAttribute", { AttributeName = A.attack })
		end)
	end
	local order = {}
	for s in st.slots do
		table.insert(order, s)
	end
	table.sort(order, function(x, y)
		return st.slots[x].power > st.slots[y].power
	end)
	for i, s in order do
		local a = st.slots[s]
		local inTop = opts.levelWhich == "All equipped" or i <= LEVEL_TOP
		if inTop and a.exp < 511 and a.exp + 2 <= opts.maxLevel then
			add("antLevel", ("slot %d ant Lv%d"):format(s, a.exp + 2), AntHelper.GetUpgradeCostByExp(a.price, a.exp), a.power * 0.1 * mult, function()
				cmd("UpgradeEquippedAnt", { AntIndex = s, Source = "RoomAntInfoGui" })
			end)
		end
	end
	-- A pet level adds LevelBonus (0.5) points to its effect (PetSkills.GetSkill). For food value
	-- and double food that's +0.5% of income; scored as the power that would add as much.
	for key, rec in st.equippedPets do
		local eff, value = PetSkills.GetSkill(rec)
		local cfg = UNITS[rec.Id]
		local lv = tonumber(rec.Level) or 1
		if eff and cfg and lv < PetConfig.MaxLevel and (PET_WEIGHT[eff] or 0) > 0 then
			local gain = st.total * mult * 0.5 / (100 + value) * PET_WEIGHT[eff]
			-- the server prices pet levels off BasePrice, not Price (EquippedPetServerSystem)
			add("petLevel", ("pet %s Lv%d"):format(cfg.Name or rec.Id, lv + 1), PetConfig.GetUpgradeGoldCost(tonumber(cfg.BasePrice) or 0, lv), gain, function()
				cmd("UpgradePet", { RequestId = HttpService:GenerateGUID(false), PetKey = key, ExpectedLevel = lv })
			end)
		end
	end
	local slot, seen = buyableSlot()
	if slot then
		local row = SLOT_PRICES[st.unlocked]
		-- ponytail: a new slot is valued at the best spare ant, else your weakest -- the roll fills it
		local fill = st.spare > 0 and st.spare or st.weakest
		add("slot", "ant slot " .. slot, row and row.Price, fill * mult, function()
			cmd("AddAntSlot", { Source = "RoomAntInfoGui", RoomIndex = player:GetAttribute("RoomIndex"), SlotIndex = slot })
			equipDue = os.clock() + EQUIP_DELAY
		end)
	end

	-- Indirect: no gain to score, so "cheap next to income" is the whole test. gain = nil
	-- marks them; the picker takes them before any direct one.
	local function indirect(key, name, label, gate)
		local a = attr(name)
		if a and a.cost and gate(a) and a.cost <= INDIRECT_MINUTES * 60 * income * w[key] then
			add(key, label .. " " .. a.level + 1, a.cost, nil, function()
				cmd("UpgradePlayerAttribute", { AttributeName = name })
			end)
		end
	end
	local yes = function()
		return true
	end
	indirect("layer", A.layer, "Nest layer", function()
		return seen and not slot -- only once every slot in the current layers is bought
	end)
	indirect("queen", A.queen, "Queen", yes)
	local q = attr(A.queen)
	indirect("luck", A.luck, "Luck", function(a)
		return q ~= nil and LuckQueen.CanUpgradeLuck(a.level, q.level)
	end)
	indirect("roll", A.roll, "Ants per roll", yes)
	indirect("speed", A.speed, "Ant speed", yes) -- weight 0 in Balanced
	return list
end

local function upgrader(alive)
	while alive() do
		local st, g = readAnts(), gold()
		if st and g then
			local list = candidates(st)
			local budget = spendable(g)
			local best, pick
			for _, c in list do
				if not c.score then
					if c.cost * GOLD_MARGIN <= budget and (not pick or c.cost < pick.cost) then
						pick = c -- cheapest affordable indirect wins outright
					end
				elseif not best or c.score > best.score then
					best = c
				end
			end
			if not pick and best then
				for _, c in list do
					if c.score and c.cost * GOLD_MARGIN <= budget and c.score >= best.score * SAVE_RATIO then
						if not pick or c.score > pick.score then
							pick = c
						end
					end
				end
			end
			if pick and takeSpend() then
				pick.run()
				stats.upgrades += 1
				say(("upgrade: %s (%s)"):format(pick.label, short(pick.cost)))
			elseif best and not pick then
				pending = ("saving for %s (%s)"):format(best.label, short(best.cost))
			end
		end
		task.wait(UPGRADE_TICK)
	end
end

-- Ticked items in stock, priciest first (the rare potions are the ones worth having), one
-- buy per spend gap. Nothing ticked in stock = sleep to the restock, capped so a gold rise
-- is noticed within half a minute.
local function shopper(alive)
	raw("GearShopRequest", { Action = "Snapshot" })
	task.wait(1)
	while alive() do
		local g, bought = gold(), false
		if g then
			local order = {}
			for id, cfg in ITEMS do
				if shopWanted[id] and (tonumber(shop.stock[id]) or 0) > 0 then
					table.insert(order, cfg)
				end
			end
			table.sort(order, function(a, b)
				return a.CoinPrice > b.CoinPrice
			end)
			for _, cfg in order do
				if cfg.CoinPrice * GOLD_MARGIN <= spendable(g) and takeSpend() then
					raw("GearShopRequest", { Action = "Purchase", ItemId = cfg.id })
					shop.stock[cfg.id] = (tonumber(shop.stock[cfg.id]) or 1) - 1 -- until the result's snapshot lands
					say("shop: bought " .. cfg.DisplayName)
					bought = true
					break
				end
			end
		end
		if bought then
			task.wait(SPEND_GAP)
		else
			local wait = shop.nextAt - workspace:GetServerTimeNow()
			if wait <= 0 then
				raw("GearShopRequest", { Action = "Snapshot" })
				wait = 5
			end
			task.wait(math.clamp(wait + 1, 1, 30))
		end
	end
end

-- The held mutation potion with the biggest multiplier, and the equipped ant it adds the
-- most to: base power x (new - old). A mutated ant qualifies only while a Remove is held.
local function potionPlan(st)
	local pot, potMul = nil, 1
	for id, n in st.items do
		local m = (tonumber(n) or 0) > 0 and Mutation.Get(id)
		local t = m and m.Mode == "Apply" and TAGS[m.TagId]
		if t and t.Mul > potMul then
			pot, potMul = id, t.Mul
		end
	end
	if not pot then
		return nil
	end
	local canRemove = (tonumber(st.items.RemoveMuCs) or 0) > 0
	local slot, gain = nil, 0
	for s, a in st.slots do
		if a.mul < potMul and (a.tag == 0 or canRemove) and a.base * (potMul - a.mul) > gain then
			slot, gain = s, a.base * (potMul - a.mul)
		end
	end
	return slot, pot
end

local function applier(alive)
	while alive() do
		local st = readAnts()
		local slot, pot
		if st then
			slot, pot = potionPlan(st)
		end
		if slot then
			local room = player:GetAttribute("RoomIndex")
			if st.slots[slot].tag > 0 then
				raw("UsePotionOnRoomSlot", { RoomIndex = room, SlotIndex = slot, ItemId = "RemoveMuCs" })
				local t0, cleared = os.clock(), false
				while not cleared and os.clock() - t0 < APPLY_WAIT do
					task.wait(0.25)
					local now = readAnts()
					cleared = now ~= nil and now.slots[slot] ~= nil and now.slots[slot].tag == 0
				end
			end
			raw("UsePotionOnRoomSlot", { RoomIndex = room, SlotIndex = slot, ItemId = pot })
			say(("potion: %s on slot %d"):format(ITEMS[pot] and ITEMS[pot].DisplayName or pot, slot))
			task.wait(APPLY_WAIT) -- let the backpack show the new trait before judging again
		end
		task.wait(POTION_TICK)
	end
end

local function act(path, ...)
	local args = table.pack(...)
	return invokeTimed(function()
		return WuKong:ExecuteAction(path, table.unpack(args, 1, args.n))
	end)
end

-- The game's own OnlineState reads this attribute: data[i] = 1 once tier i is claimed,
-- online seconds = totalOnlineTime + (now - onlinetime).
local function onlineReady()
	local ok, d = pcall(HttpService.JSONDecode, HttpService, player:GetAttribute("onlineaward") or "")
	if not ok or type(d) ~= "table" or type(d.data) ~= "table" then
		return true -- unreadable: ask anyway, a refusal is free
	end
	local online = (tonumber(d.totalOnlineTime) or 0) + math.max(0, os.time() - (tonumber(d.onlinetime) or os.time()))
	for i, flag in d.data do
		local row = ONLINE[i]
		if flag == 0 and row and online >= (tonumber(row.OnlineTime) or math.huge) then
			return true
		end
	end
	return false
end

local function rewarder(alive)
	local last = {}
	local function due(key, every)
		if os.clock() - (last[key] or -math.huge) < every then
			return false
		end
		last[key] = os.clock()
		return true
	end
	while alive() do
		if onlineReady() then
			act(ONLINE_ACT, "__null__", "__null__", "__null__")
		end
		if due("seven", 600) then
			act(SEVEN_ACT, "__null__", "__null__", "__null__")
		end
		if due("group", 1800) then
			act(GROUP_ACT) -- group members only; everyone else is refused
		end
		if due("index", 300) then
			for id, progress in INDEX_TRACKS do
				for _ = 1, 30 do -- one tier per call; stop when the claimed tier stops moving
					local before = prop(progress) or 0
					act(INDEX_ACT, "__null__", "__null__", { HttpService:JSONEncode({ ConfigId = id, Level = before + 1 }) })
					task.wait(1)
					if (prop(progress) or 0) <= before then
						break
					end
					say(("index reward: %s tier %d"):format(id, before + 1))
				end
			end
		end
		task.wait(REWARD_TICK)
	end
end

-- anti-afk: blue_lock_farm.lua's, verbatim but for the tag. The nudge is a key nothing binds,
-- only after a minute without your own input: a right-click is camera-drag in Roblox.
-- ponytail: VirtualInputManager only -- add VirtualUser back if an idle kick ever shows up.
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
		return -- you're at the keyboard; your own input already feeds the idle timer
	end
	pcall(function()
		local vim = game:GetService("VirtualInputManager")
		vim:SendKeyEvent(true, NUDGE_KEY, false, game)
		vim:SendKeyEvent(false, NUDGE_KEY, false, game)
	end)
end
function afk.set(on)
	afk.gen += 1
	afk.on = on
	for _, c in afk.conns do
		pcall(c.Disconnect, c)
	end
	table.clear(afk.conns)
	if not on then
		return
	end
	local mine = afk.gen
	local function alive()
		return afk.on and afk.gen == mine
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
				-- a failed teleport draws an ErrorPrompt too; only a gone connection rejoins
				if alive() and os.clock() - afk.tpFail > 5 and afk.offline() and not afk.rejoining then
					afk.rejoining = true
					warn("[ant] disconnected -- rejoining in " .. REJOIN_DELAY .. "s")
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

-- dungeon --------------------------------------------------------------------
-- DungeonServerSystem ships to the client too. An entrance spawns every 5 min at 40%, lasts
-- 10, one run per player each. Its prompt is server-side (Triggered), so a press from range
-- enters; the game's own client then runs the cutscene handshake and the server teleports
-- you in. The fight waits for "Start" (the game sends it on your click). Clicks fill a boost
-- meter with no server rate limit; each kill drops a time coin (+15s) 20% of the time, which
-- the server checks against your root's distance, so we stand on it. Each boss pays pet
-- tokens; an egg drops at most once a run (5% per kill). The server walks you home after.
local dungeon = { state = nil, tried = {}, coins = {}, lastSync = 0 }

local function hrp()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function promptPos(prompt)
	local at = prompt.Parent
	if at and at:IsA("Attachment") then
		return at.WorldPosition
	elseif at and at:IsA("BasePart") then
		return at.Position
	end
	return nil
end

local function press(prompt)
	pcall(function()
		prompt.RequiresLineOfSight = false
		prompt.MaxActivationDistance = 40 -- big and finite: math.huge throws
	end)
	if fireproximityprompt then
		pcall(fireproximityprompt, prompt, prompt.HoldDuration)
	else
		pcall(prompt.InputHoldBegin, prompt)
		task.wait(prompt.HoldDuration + 0.1)
		pcall(prompt.InputHoldEnd, prompt)
	end
end

local function openEntrance()
	local folder = workspace:FindFirstChild("DungeonEntrances")
	local now = workspace:GetServerTimeNow()
	for _, m in folder and folder:GetChildren() or {} do
		local id = m:GetAttribute("DungeonEntranceId")
		if id and not dungeon.tried[id] and (tonumber(m:GetAttribute("ExpiresAt")) or 0) - now > ENTER_TIMEOUT then
			return id, m
		end
	end
	return nil
end

local function grabCoins(sid, st)
	local cfg = DUNGEON.TimeCoin
	local now = workspace:GetServerTimeNow()
	for _, c in st.timeCoins or {} do
		local landed = now >= (tonumber(c.landsAt) or math.huge)
		local due = os.clock() - (dungeon.coins[c.id] or -math.huge) >= COIN_RETRY
		if landed and due then
			dungeon.coins[c.id] = os.clock()
			if typeof(c.position) == "Vector3" then
				local root = hrp()
				if root then
					root.CFrame = CFrame.new(c.position + Vector3.new(0, 3, 0))
					task.wait(0.2) -- the server reads the root's replicated position
				end
				cmd("DungeonCommand", { Action = "PickupTimeCoin", SessionId = sid, CoinId = c.id })
			elseif now - c.landsAt > 1 then
				-- The game's renderer picks the landing spot; if it hasn't, pick one on the ring
				-- toward us: MinRadius..MaxRadius from the boss, exactly LandingHeight (Session.PlaceTimeCoin).
				local root = hrp()
				local dir = root and (root.Position - DUNGEON.BossPosition) * Vector3.new(1, 0, 1)
				dir = dir and dir.Magnitude > 0.1 and dir.Unit or Vector3.xAxis
				local p = DUNGEON.BossPosition + dir * (cfg.MinRadius + cfg.MaxRadius) / 2
				cmd("DungeonCommand", {
					Action = "PlaceTimeCoin",
					SessionId = sid,
					CoinId = c.id,
					Position = Vector3.new(p.X, cfg.LandingHeight, p.Z),
				})
			end
		end
	end
end

-- Drives one session to its end. false = never got in.
local function fight(alive)
	local t0 = os.clock()
	while alive() and not player:GetAttribute("DungeonSessionId") do
		if os.clock() - t0 > ENTER_TIMEOUT then
			return false
		end
		task.wait(0.25)
	end
	local sid = player:GetAttribute("DungeonSessionId")
	local startedAt = -math.huge
	table.clear(dungeon.coins)
	while alive() and sid and player:GetAttribute("DungeonSessionId") == sid do
		local st = dungeon.state
		if st and st.sessionId == sid then
			if st.status == "ready" and os.clock() - startedAt > 2 then
				cmd("DungeonCommand", { Action = "Start", SessionId = sid })
				startedAt = os.clock()
			elseif st.status == "fighting" or st.status == "intermission" or st.status == "dropping" then
				cmd("DungeonCommand", { Action = "Click", SessionId = sid })
				grabCoins(sid, st)
			end
		end
		if os.clock() - dungeon.lastSync > 1 then -- the server pushes state on change; ask anyway
			cmd("DungeonCommand", { Action = "Sync" })
			dungeon.lastSync = os.clock()
		end
		task.wait(CLICK_GAP)
	end
	return true
end

local function dungeoneer(alive)
	while alive() do
		if player:GetAttribute("DungeonSessionId") then
			fight(alive) -- already inside: a re-paste mid-run
		else
			local id, model = openEntrance()
			local root = hrp()
			if id and root then
				dungeon.tried[id] = true
				dungeon.rejected = nil
				local home = root.CFrame -- the server returns you to the entrance, not here
				say("dungeon: entering " .. tostring(model:GetAttribute("BossId")))
				root.CFrame = model:GetPivot() + Vector3.new(0, 4, 0)
				-- the prompt's part streams in with the model's region
				local prompt, t0 = nil, os.clock()
				repeat
					task.wait(0.25)
					local holder = model:FindFirstChild("promt", true)
					prompt = holder and holder:FindFirstChildWhichIsA("ProximityPrompt")
				until prompt or os.clock() - t0 > 5
				local at = prompt and promptPos(prompt)
				if at then
					root.CFrame = CFrame.new(at + Vector3.new(0, 2, 0))
					task.wait(0.3)
					press(prompt)
					if fight(alive) then
						local st = dungeon.state or {}
						say(("dungeon: done -- %s bosses, %s pet tokens%s"):format(
							tostring(st.kills or "?"), tostring(st.reward or "?"), (st.eggCount or 0) > 0 and ", egg!" or ""))
					else
						say("dungeon: didn't get in (" .. tostring(dungeon.rejected or "no session") .. ")")
					end
				else
					say("dungeon: entrance prompt never streamed in")
				end
				task.wait(2) -- the exit cutscene hands the character back
				local back = hrp()
				if back and not player:GetAttribute("DungeonSessionId") then
					back.CFrame = home
				end
			end
		end
		task.wait(DUNGEON_POLL)
	end
end

-- pets -----------------------------------------------------------------------
-- Eggs (dungeon drops, or bought with pet tokens) go down inside your room's PetMoveRanage
-- (sic) and hatch at HatchAt. Placing a pet or an egg needs it HELD first -- the server
-- checks BackpackHeldKind/Key (EquippedPetServerSystem) -- so every place is hold, act, unhold.
local function petRange()
	local rooms = workspace:FindFirstChild("Rooms")
	local room = rooms and rooms:FindFirstChild(tostring(player:GetAttribute("RoomIndex")))
	local r = room and room:FindFirstChild("PetMoveRanage", true)
	return r and r:IsA("BasePart") and r or nil
end

local function ground(range, x, z)
	local p = range.CFrame:PointToWorldSpace(Vector3.new(x, range.Size.Y / 2, z))
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character, range, workspace:FindFirstChild("PlacedPetEggs") }
	local hit = workspace:Raycast(p + Vector3.new(0, 20, 0), Vector3.new(0, -200, 0), params)
	return hit and hit.Position, hit and hit.Normal
end

local function eggSpot(range)
	local folder = workspace:FindFirstChild("PlacedPetEggs")
	local half = range.Size / 2
	for x = -half.X + 3, half.X - 3, EGG_SPACING do
		for z = -half.Z + 3, half.Z - 3, EGG_SPACING do
			local pos, normal = ground(range, x, z)
			local free = pos ~= nil
			for _, m in folder and folder:GetChildren() or {} do
				if free and m:IsA("Model") and (m:GetPivot().Position - pos).Magnitude < EGG_SPACING then
					free = false
				end
			end
			if free then
				return pos, normal
			end
		end
	end
	return nil
end

local function hold(kind, key, extra)
	local args = { Kind = kind, EntryKey = kind .. ":" .. key }
	for k, v in extra do
		args[k] = v
	end
	raw("SetBackpackHeldEntry", args)
	local t0 = os.clock()
	while player:GetAttribute("BackpackHeldEntryKey") ~= args.EntryKey and os.clock() - t0 < 2 do
		task.wait(0.1)
	end
	return player:GetAttribute("BackpackHeldEntryKey") == args.EntryKey
end

local function unhold()
	raw("SetBackpackHeldEntry", {})
end

local eggWanted = {} -- egg id -> true, from the dropdown; cleared in place
local function egger(alive)
	local warned = {}
	while alive() do
		local inRun = player:GetAttribute("DungeonSessionId") ~= nil
		-- hatch every egg of ours that's ready
		local folder = workspace:FindFirstChild("PlacedPetEggs")
		local now = workspace:GetServerTimeNow()
		for _, m in folder and folder:GetChildren() or {} do
			local mine = tonumber(m:GetAttribute("OwnerUserId")) == player.UserId
			if not inRun and mine and m:GetAttribute("IsPlacedPetEgg") and now >= (tonumber(m:GetAttribute("HatchAt")) or math.huge) then
				raw("HatchPlacedPetEgg", { HatchId = m:GetAttribute("HatchId") })
				say("egg: hatching " .. tostring(m.Name))
				task.wait(1)
			end
		end
		local st = not inRun and readAnts()
		if st then
			-- place one held egg per pass
			for id, n in st.eggs do
				if (tonumber(n) or 0) > 0 then
					local range = petRange()
					local pos, normal
					if range then
						pos, normal = eggSpot(range)
					end
					if pos and hold("PetEgg", id, { PetEggId = id }) then
						raw("PlaceSelectedPetEgg", { PetEggId = id, Position = pos, Normal = normal })
						task.wait(0.5)
						unhold()
						say("egg: placed " .. id)
					elseif not warned.range then
						warned.range = true
						warn("[ant] no free spot on the pet range, or the egg wouldn't hold")
					end
					break
				end
			end
			-- spend pet tokens on the priciest ticked egg they cover
			local tokens = query(CURRENCY .. PET_TOKEN .. COUNT)
			local pick
			for id, row in EGG_SHOP do
				if eggWanted[id] and tokens and row.Price <= tokens and (not pick or row.Price > pick.Price) then
					pick = row
				end
			end
			if pick then
				act(EGG_BUY, "__null__", "__null__", { pick.PetEggid, 1 })
				say(("egg: bought %s for %d pet tokens"):format(pick.PetEggid, pick.Price))
			end
		end
		task.wait(EGG_TICK)
	end
end

local function petScore(rec)
	local eff, value = PetSkills.GetSkill(rec)
	return eff and value * (PET_WEIGHT[eff] or 0) or 0
end

-- Fill empty pet slots with the best backpack pet; once full, swap the weakest equipped one
-- out for a better one. PetMoveRanage clamps the spot, so the range's centre always takes.
local function petEquipper(alive)
	while alive() do
		local st = not player:GetAttribute("DungeonSessionId") and readAnts()
		local max = prop(PET_MAX)
		local range = petRange()
		if st and max and range then
			local weakest, best
			local count = 0
			for key, rec in st.equippedPets do
				count += 1
				local s = petScore(rec)
				if not weakest or s < weakest.score then
					weakest = { key = key, rec = rec, score = s }
				end
			end
			for key, rec in st.pets do
				local s = petScore(rec)
				if s > 0 and (not best or s > best.score) then
					best = { key = key, score = s }
				end
			end
			local room = count < max
			if best and not room and weakest and best.score > weakest.score then
				cmd("UnequipPet", { RequestId = HttpService:GenerateGUID(false), PetKey = weakest.key, ExpectedLevel = weakest.rec.Level })
				say("pets: swapping out " .. tostring(weakest.rec.Id))
				task.wait(1)
				room = true
			end
			if best and room then
				local pos, normal = ground(range, 0, 0)
				if pos and hold("Pet", best.key, { PetKey = best.key }) then
					cmd("PlacePet", { PetKey = best.key, Position = pos, Normal = normal })
					task.wait(0.5)
					unhold()
					say("pets: equipped " .. tostring(st.pets[best.key] and st.pets[best.key].Id))
				end
			end
		end
		task.wait(PET_TICK)
	end
end

table.insert(conns, Bus.OnClientEvent:Connect(function(name, p)
	if type(p) ~= "table" then
		return
	end
	if name == "DungeonState" then
		if p.status == "rejected" then
			dungeon.rejected = p.reason
		elseif p.sessionId then
			dungeon.state = p
		end
		return
	end
	if name == "GearShopSnapshot" or name == "GearShopResult" then
		local snap = name == "GearShopSnapshot" and p or p.Snapshot
		if type(snap) == "table" then
			shop.stock = type(snap.StockByItem) == "table" and snap.StockByItem or {}
			shop.nextAt = tonumber(snap.NextRefreshAt) or 0
		end
		if name == "GearShopResult" and p.Success == false then
			pending = ("shop refused %s: %s"):format(tostring(p.ItemId), tostring(p.Reason))
		end
		return
	end
	if name == "SellFoodPriceUpdate" then
		price.base = tonumber(p.BaseGoldPerFood) or tonumber(p.GoldPerFood)
		price.mult = tonumber(p.FoodSellMultiplier) or 1
		price.untilT = os.clock() + (tonumber(p.RemainingSeconds) or 0)
		task.spawn(sellNow)
	elseif name == "SellResuit" then -- sic, FoodSellConfig.ResultEvent
		if p.Success and type(p.Result) == "table" then
			stats.sold += tonumber(p.Result.GoldAmount) or 0
		end
	elseif name == "RollAntResult" then
		if rollOn and p.Source == nil and type(p.Results) == "table" then
			task.spawn(onRoll, p) -- it waits on the spend gate; an event thread shouldn't
		end
	elseif name == "ClaimRolledAntResult" then
		if p.Success then
			stats.bought += 1
			equipDue = os.clock() + EQUIP_DELAY
		elseif p.Reason == "NotEnoughGold" then
			warn("[ant] a rolled ant was short of gold -- if a Robux prompt opened, close it")
		end
	elseif name == "AddAntSlotResult" and p.PromptRobuxPurchase then
		warn("[ant] slot unlock was short of gold -- if a Robux prompt opened, close it")
	end
end))

-- One toggle row = one gen counter in its closure, so off-then-on can't double the loop.
local function loopToggle(bodies, onFlag)
	local gen, on = 0, false
	return function(state)
		on = state
		gen += 1
		if onFlag then
			onFlag(state)
		end
		if not state then
			return
		end
		local mine = gen
		local alive = function()
			return on and gen == mine
		end
		for _, body in bodies do
			task.spawn(function()
				local ok, err = pcall(body, alive)
				if not ok then
					warn("[ant] " .. tostring(err))
				end
			end)
		end
	end
end

local setClaim = loopToggle({ claimer })
local setSell = loopToggle({ priceWatcher }, function(s)
	opts.sellOn = s
end)
local setRoll = loopToggle({ roller }, function(s)
	rollOn = s
	if not s then
		held = nil -- nobody's rolling, so nothing to save for
	end
end)
local setEquip = loopToggle({ equipper }, function(s)
	opts.equipOn = s
end)
local setSpender = loopToggle({ upgrader })
-- Three toggles, one spender: each flips its own flag, the loop runs while any is on.
local function spenderToggle(flag)
	return function(s)
		opts[flag] = s
		setSpender(opts.upgradeOn or opts.levelOn or opts.petLevelOn)
	end
end
local setUpgrade = spenderToggle("upgradeOn")
local setLevel = spenderToggle("levelOn")
local setPetLevel = spenderToggle("petLevelOn")
local setShop = loopToggle({ shopper })
local setApply = loopToggle({ applier })
local setRewards = loopToggle({ rewarder })
local setDungeon = loopToggle({ dungeoneer })
local setEggs = loopToggle({ egger })
local setPets = loopToggle({ petEquipper })

-- Multi dropdowns hand back a list, a map, or {Title=} rows depending on the WindUI build.
local function ticked(values)
	local set = {}
	for k, v in values or {} do
		if type(v) == "string" then
			set[v] = true -- list form: 1 -> "Leaf Mutation Potion"
		elseif type(v) == "table" and v.Title then
			set[v.Title] = true -- row form
		elseif v then
			set[k] = true -- map form: "Leaf Mutation Potion" -> true
		end
	end
	return set
end
assert(ticked({ "a" }).a and ticked({ a = true }).a and not ticked({ a = false }).a and ticked({ { Title = "a" } }).a)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window = panel({ game = "Build an Ant Empire", folder = "AntEmpire", size = UDim2.fromOffset(480, 420) })
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })

local Dash = Tab:Section({ Title = "Dashboard", Icon = "solar:chart-2-bold", Box = true, BoxBorder = true, Opened = true })
local DASH_ORDER = { "stats", "price", "nest", "roll", "status" }
local DASH_LABEL = { stats = "", price = "Price: ", nest = "Nest: ", roll = "Roll: ", status = "Status: " }
local dashText = { stats = "-", price = "-", nest = "-", roll = "-", status = "idle" }
local dashCard = Dash:Paragraph({ Title = "Live", Desc = "loading..." })

local Food = Tab:Section({ Title = "Food", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })
Food:Toggle({
	Title = "Fast claim",
	Desc = "Every ant paid every 3.1s instead of once per walk, then collected. Doesn't move you",
	Value = false,
	Callback = setClaim,
})
Food:Slider({
	Title = "Claim every",
	Desc = "Seconds between claims. The server pays each ant once per 3.0s, so lower does nothing",
	Step = 0.1,
	Value = { Min = 3, Max = 30, Default = CLAIM_GAP },
	Callback = function(v)
		opts.claimGap = math.max(3, tonumber(v) or CLAIM_GAP)
	end,
})
Food:Toggle({
	Title = "Auto sell",
	Desc = "Sells all food whenever the server price is at or above the slider",
	Value = false,
	Callback = setSell,
})
Food:Slider({
	Title = "Sell at price",
	Desc = "Base gold per food (0.5-2.0, new every 20s). 1.5 = +40% over selling at any price",
	Step = 0.05,
	Value = { Min = 1, Max = 2, Default = SELL_AT },
	Callback = function(v)
		opts.sellAt = tonumber(v) or SELL_AT
	end,
})

local Roll = Tab:Section({ Title = "Roll", Icon = "solar:stars-bold", Box = true, BoxBorder = true, Opened = true })
Roll:Toggle({
	Title = "Auto roll + buy",
	Desc = "Free roll every 3.1s; buys what passes the filters below with gold above the reserve",
	Value = false,
	Callback = setRoll,
})
Roll:Slider({
	Title = "Wait for a better ant",
	Desc = "Minutes of income to pause rolling for a better ant you can't afford yet. 0 = never wait",
	Step = 1,
	Value = { Min = 0, Max = 60, Default = opts.waitMin },
	Callback = function(v)
		opts.waitMin = math.max(0, tonumber(v) or 0)
	end,
})
Roll:Toggle({
	Title = "Only if stronger",
	Desc = "Buy only an ant that beats your weakest equipped one, or fills an empty slot",
	Value = opts.stronger,
	Callback = function(s)
		opts.stronger = s
	end,
})
Roll:Toggle({
	Title = "Minimum rarity",
	Desc = "Also require the rarity below. With both filters off, every affordable roll is bought",
	Value = opts.minRarityOn,
	Callback = function(s)
		opts.minRarityOn = s
	end,
})
Roll:Dropdown({
	Title = "Rarity",
	Values = RARITIES,
	Value = opts.minRarity,
	Callback = function(v)
		if table.find(RARITIES, v) then
			opts.minRarity = v
		end
	end,
})
Roll:Toggle({
	Title = "Auto equip best",
	Desc = "The game's own Equip Best, once after new ants or a new slot -- not on a timer",
	Value = false,
	Callback = setEquip,
})

local Up = Window:Tab({ Title = "Upgrades", Icon = "solar:arrow-up-bold" })
local UpSec = Up:Section({ Title = "Auto upgrade", Icon = "solar:bolt-circle-bold", Box = true, BoxBorder = true, Opened = true })
UpSec:Toggle({
	Title = "Auto upgrade",
	Desc = "Attack, slots, layers, queen, luck, roll count by payback. Ant levels: their own toggle below",
	Value = false,
	Callback = setUpgrade,
})
local MODES = { "Balanced", "Custom" }
UpSec:Dropdown({
	Title = "Priority",
	Desc = "Balanced = payback math, never ant speed. Custom = the weights below",
	Values = MODES,
	Value = opts.mode,
	Callback = function(v)
		if table.find(MODES, v) then
			opts.mode = v
		end
	end,
})
UpSec:Input({
	Title = "Gold reserve",
	Desc = "Never spend below this -- ant buys and upgrades both. 25k, 1.5M, 2B...",
	Value = "0",
	Placeholder = "0",
	Callback = function(text)
		local n = parseAmount(text)
		if n and n >= 0 then
			opts.reserve = n
		end
	end,
})

local Lv = Up:Section({ Title = "Nest ant levels", Icon = "solar:ranking-bold", Box = true, BoxBorder = true, Opened = true })
Lv:Toggle({
	Title = "Auto level ants",
	Desc = "Levels equipped ants (+10% power each) up to the cap below, above the gold reserve",
	Value = false,
	Callback = setLevel,
})
Lv:Slider({
	Title = "Max ant level",
	Desc = "Auto upgrade never levels an ant past this. 512 = the game's cap",
	Step = 1,
	Value = { Min = 1, Max = 512, Default = opts.maxLevel },
	Callback = function(v)
		opts.maxLevel = math.floor(tonumber(v) or 512)
	end,
})
local LEVEL_WHICH = { "All equipped", "Strongest 3 only" }
Lv:Dropdown({
	Title = "Level which ants",
	Desc = "Payback favours cheap ants, whose levels are lost when a roll replaces them",
	Values = LEVEL_WHICH,
	Value = opts.levelWhich,
	Callback = function(v)
		if table.find(LEVEL_WHICH, v) then
			opts.levelWhich = v
		end
	end,
})

local W = Up:Section({ Title = "Custom weights", Icon = "solar:tuning-2-bold", Box = true, BoxBorder = true, Opened = false })
local WEIGHT_ROWS = {
	{ "attack", "Ant Attack", "All food x(1 + value)" },
	{ "antLevel", "Ant levels", "+10% power per level on one ant" },
	{ "petLevel", "Pet levels", "+0.5 to the pet's effect per level" },
	{ "slot", "Ant slots", "Room for one more ant" },
	{ "layer", "Nest layers", "Unlocks more slot rows" },
	{ "queen", "Queen level", "Better roll pool, higher luck cap" },
	{ "luck", "Luck", "Rarer rolls" },
	{ "roll", "Ants per roll", "More ants per roll" },
	{ "speed", "Ant speed", "Walking only -- does nothing with Fast claim" },
}
for _, row in WEIGHT_ROWS do
	W:Slider({
		Title = row[2],
		Desc = row[3] .. ". 0 = never",
		Step = 0.5,
		Value = { Min = 0, Max = 3, Default = weights[row[1]] },
		Callback = function(v)
			weights[row[1]] = tonumber(v) or 0
		end,
	})
end

local ShopTab = Window:Tab({ Title = "Shop", Icon = "solar:cart-large-2-bold" })
local ShopSec = ShopTab:Section({ Title = "Gear shop", Icon = "solar:cart-large-2-bold", Box = true, BoxBorder = true, Opened = true })
ShopSec:Toggle({
	Title = "Auto buy",
	Desc = "Buys the ticked items while the 5-min stock lasts, priciest first, above the gold reserve",
	Value = false,
	Callback = setShop,
})
local itemRows, idByName = {}, {}
for id, cfg in ITEMS do
	table.insert(itemRows, cfg)
	idByName[cfg.DisplayName] = id
end
table.sort(itemRows, function(a, b)
	return (a.sort or 0) < (b.sort or 0)
end)
local itemNames, defaultTicks = {}, {}
for _, cfg in itemRows do
	table.insert(itemNames, cfg.DisplayName)
	if cfg.Tag == "Potion" then -- mutations + Remove; the jellies only speed up walking
		table.insert(defaultTicks, cfg.DisplayName)
		shopWanted[cfg.id] = true
	end
end
ShopSec:Dropdown({
	Title = "Items",
	Desc = "Jellies are unticked: they speed up walking, which fast claim doesn't wait on",
	Values = itemNames,
	Value = defaultTicks,
	Multi = true,
	AllowNone = true,
	Callback = function(picked)
		table.clear(shopWanted) -- in place: the shop loop holds this table
		for name in ticked(picked) do
			if idByName[name] then
				shopWanted[idByName[name]] = true
			end
		end
	end,
})
ShopSec:Toggle({
	Title = "Auto-apply potions",
	Desc = "Best held mutation onto the ant it adds most to; Removes a weaker mutation first",
	Value = true,
	Callback = setApply,
})

local PetTab = Window:Tab({ Title = "Pets", Icon = "solar:paw-bold" })
local DunSec = PetTab:Section({ Title = "Dungeon", Icon = "solar:shield-bold", Box = true, BoxBorder = true, Opened = true })
DunSec:Toggle({
	Title = "Auto dungeon",
	Desc = "Enters each new entrance, starts the fight, clicks the boost, grabs time coins, comes home",
	Value = false,
	Callback = setDungeon,
})

local EggSec = PetTab:Section({ Title = "Eggs", Icon = "solar:egg-bold", Box = true, BoxBorder = true, Opened = true })
EggSec:Toggle({
	Title = "Auto eggs",
	Desc = "Places eggs on your pet range, hatches them when ready, buys the ticked eggs with pet tokens",
	Value = false,
	Callback = setEggs,
})
-- egg id <- the boss it comes from (event_tbpetegg Disname), so the list reads like the game
local EGG_NAMES = { PetEgg1 = "Snail (luck)", PetEgg2 = "Spider (walk speed)", PetEgg3 = "Mantis (double food)", PetEgg4 = "Ladybug (food value)" }
local eggIdByName, eggList = {}, {}
for id, name in EGG_NAMES do
	eggIdByName[name] = id
end
for i = 1, 4 do
	table.insert(eggList, EGG_NAMES["PetEgg" .. i])
end
eggWanted.PetEgg3, eggWanted.PetEgg4 = true, true
EggSec:Dropdown({
	Title = "Buy eggs",
	Desc = "Priciest ticked egg the pet tokens cover. Spider only speeds up walking",
	Values = eggList,
	Value = { EGG_NAMES.PetEgg3, EGG_NAMES.PetEgg4 },
	Multi = true,
	AllowNone = true,
	Callback = function(picked)
		table.clear(eggWanted) -- in place: the egg loop holds this table
		for name in ticked(picked) do
			if eggIdByName[name] then
				eggWanted[eggIdByName[name]] = true
			end
		end
	end,
})

local PetSec = PetTab:Section({ Title = "Pets", Icon = "solar:paw-bold", Box = true, BoxBorder = true, Opened = true })
PetSec:Toggle({
	Title = "Auto equip best pets",
	Desc = "Fills pet slots with the best pets; swaps the weakest out for a better one",
	Value = false,
	Callback = setPets,
})
PetSec:Toggle({
	Title = "Auto level pets",
	Desc = "Food value and double-food pets, by payback against every other upgrade you have on",
	Value = false,
	Callback = setPetLevel,
})

local Misc = Window:Tab({ Title = "Misc", Icon = "solar:settings-bold" })
local MiscSec = Misc:Section({ Title = "Rewards & AFK", Icon = "solar:gift-bold", Box = true, BoxBorder = true, Opened = true })
MiscSec:Toggle({
	Title = "Auto claim rewards",
	Desc = "Online-time, 7-day, index and group rewards, as they come due",
	Value = false,
	Callback = setRewards,
})
MiscSec:Toggle({
	Title = "Anti-AFK + rejoin",
	Desc = "Stops the 17-min idle reconnect to a server without this script; rejoins on a disconnect",
	Value = true,
	Callback = afk.set,
})

local shown -- last text written: SetDesc only on change
local function show(row, text)
	dashText[row] = text
	local lines = {}
	for _, key in DASH_ORDER do
		table.insert(lines, DASH_LABEL[key] .. dashText[key])
	end
	local all = table.concat(lines, "\n")
	if all ~= shown then
		shown = all
		pcall(function()
			dashCard:SetDesc(all)
		end)
	end
end

local nextTick = 0
local drain = RunService.Heartbeat:Connect(function()
	if pending ~= nil then
		show("status", pending)
		pending = nil
	end
	local now = os.clock()
	if now < nextTick then
		return
	end
	nextTick = now + 1
	local mins = math.max((now - stats.since) / 60, 1 / 60)
	show("stats", ("%s gold  |  %s food  |  %s food/min collected"):format(short(gold()), short(food()), short(stats.collected / mins)))
	show("price", price.base and ("%.2f base (x%.2f)  |  %ds left  |  sold %s gold"):format(
		price.base, price.mult, math.max(0, math.floor(price.untilT - now)), short(stats.sold)) or "waiting for the server")
	local st = readAnts()
	show("nest", st and ("%d/%d slots  |  %s power  |  %d upgrades bought"):format(st.count, st.unlocked, short(st.total), stats.upgrades) or "backpack not loaded")
	show("roll", held and ("PAUSED, saving for %s"):format(held.label) or ("%d ants bought  |  last %s"):format(stats.bought, lastBuy))
end)

-- A starting Value = true doesn't fire its callback: arm the rows that start on.
setApply(true)
afk.set(true)

-- close ----------------------------------------------------------------------
local function stopAll()
	setClaim(false)
	setSell(false)
	setRoll(false)
	setEquip(false)
	setUpgrade(false)
	setLevel(false)
	setPetLevel(false)
	setDungeon(false)
	setEggs(false)
	setPets(false)
	setShop(false)
	setApply(false)
	setRewards(false)
	afk.set(false) -- a stopped script must not rejoin you
	drain:Disconnect()
	for _, c in conns do
		pcall(function()
			c:Disconnect()
		end)
	end
end

Window:OnDestroy(function()
	stopAll()
	getgenv().antEmpireStop = nil
end)

getgenv().antEmpireStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().antEmpireStop = nil
end
