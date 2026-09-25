--[[ Loot to Forge -- stage loot, forge, sell, Frozen Tower, train, rewards (118805555015549)

     Every fight in this game is client-side: mobs, their HP, your HP and your death are all
     simulated by your own client, and no attack remote exists. The server's side is three
     calls, and none of them needs a mob or your position (probed, 2026-09-25):

     FARM    : StageFinishedRF("Stage_N") hands back that stage's whole drop list the moment you
               ask -- the game calls it when the mobs SPAWN, not when they die. GetOreRF(uuid)
               picks one up (returns your bag count, nil when refused), ClaimedAllOreRE banks the
               bag from anywhere. No cooldown server-side; the 30s respawn is client theatre.
               So "kill mobs", "walk to loot" and "return to base when full" are all one loop:
               ask -> pick best-price first -> bank whenever the bag fills. Highest stage first,
               stepping down past any the server refuses.
     COMBAT  : nothing to automate. Damage is EnemyHitBE on your client and never reaches the
               server; the server doesn't know whether a mob died.
     FORGE   : ForgeRF({ConfigType, UUIDList}). Ore COUNT rolls the category (13 = Great, which
               beats Katana at every tier; 4 = Light Hat). The tier comes from the ore you put in
               the MOST of (not the rarest), and average ore POWER centres a bell curve over the
               items. The game's own ForgeUtils/Helpers give the exact odds per ore set, and
               BalanceUtils the exact Train value of a loadout -- so a forge only happens when
               P(result beats what you wear) clears the slider. Weapons take your strongest 13
               (an upgrade over ~200M needs Bussin-Ice or better); hats take the cheapest 4 that
               hold the best odds and never touch weapon-grade ores. Armor only gives Defence,
               which only matters in client-side fights: it is never forged.
     EQUIP   : whichever weapon/hat maximises BalanceUtils' own Train maths (percent weapons x
               your best plain one, capped, plus affixes).
     SELL    : TrySellItemRE(uuid, n) from anywhere, by rarity ticks (ores and gear separate).
               Never sold: equipped, anything whose removal lowers your Train (your best plain
               weapon feeds percent weapons), enhanced gear, Exclusive, stones, tickets, and the
               ores the forge has reserved. TrySellAllRE is never used -- it sells forge stock.
     TOWER   : the Frozen Tower (rebirth 2+, 1 ticket a run). TryIntoDungeonRF(1), then per round
               StartRoundRE(r) -> 0.35s -> CompleteRoundRF(r), which returns the loot. 30 rounds in
               ~11s. The game's own round flow is muted for the run so its 80s timer and its late
               StartRound(1) can't interfere, then restored.
     TRAIN   : stands you in the best free training area your rebirth allows; the server sets
               AutoTrainAreaID and the game's own TrainCTRL clicks from there.
     EXTRA   : online / offline / daily-ticket / Index / update-log rewards, Super Loot sniper
               (KillSuperLootRE + GetOreRF on the server's spawn broadcast), upgrades by cheapest
               first, rebirth when your level allows. What a rebirth resets is server-side and
               not in the dump -- watch your first one.

     Robux paths deliberately NOT wired: ClassRoll, TowerTicketPack, SkipRebirth, OfflineRewardx10.

     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().lootForgeStop() ]]

-- config ---------------------------------------------------------------------
local TICK = 0.1 -- the brain's beat; every step below runs on its own clock
local CALL_TIMEOUT = 8 -- an InvokeServer that hasn't returned by now is abandoned

local FARM_GAP = 2.5 -- default seconds between stage clears; a fast player's pace (slider)
local FARM_GAP_MIN = 0.2
local STAGE_STRIKES = 3 -- refused asks in a row before a stage is parked...
local STAGE_PARK = 120 -- ...for this long (s); the server may unlock it as you progress

local ROUND_WAIT = 0.35 -- StartRound -> CompleteRound; 0 was refused, 0.3 held every round
local ROUND_RETRIES = 3
local TOWER_GAP = 5 -- between tower runs while tickets last

local FORGE_GAP = 3
local FORGE_ODDS = 10 -- % default: forge only when P(upgrade) is at least this
local WEAPON_ORES, HAT_ORES = 13, 4 -- 13 = 100% Great, 4 = 100% Light Hat (ForgePercent)
-- Ore power 99+ (Rust-Sludge and up) is weapon stock: a Great upgrade over ~200M Train needs an
-- average of ~114 (Bussin-Ice 39%, Panic-Core 89%, The Apex 95% vs K_24). Hats never take it.
local WEAPON_GRADE = 99
local HAT_MIN_POWER = 60 -- hat ores below this drag the average off 67 (Dark Matter, 60, still holds 97%)
local EQUIP_GAP = 3
local SELL_GAP = 4
local SELL_BATCH = 25
local UPGRADE_GAP = 2
local REBIRTH_GAP = 5
local REWARD_GAP = 10
local INDEX_LEVEL_GAP = 60
local TRAIN_GAP = 3
local PAD_SETTLE = 0.4 -- after a hop onto a pad, for the server to see you there
local CONFIRM = 2.5 -- s to wait for the server's backpack/eco push after an action
local SNIPE_RETRIES = 4

local WATCHDOG = 30
local AFK_BEAT = 60 -- AFKClient fires AFKHandle after 1100s without input
local REJOIN_DELAY = 5
local DASH_GAP = 1

local RARITIES = { "Common", "UnCommon", "Rare", "Epic", "Legendary", "Mythic", "Eternal", "Secret", "Ancient", "Infinite" }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().lootForgeStop then
	getgenv().lootForgeStop() -- re-running must not stack a second panel or loop
end

local function log(msg)
	print("[loot_forge] " .. msg)
end

local pending -- last line a loop wants on the status row; drained on Heartbeat
local function say(msg)
	pending = msg
end

local mark, markAt = "idle", os.clock()
local function step(what)
	mark, markAt = what, os.clock()
end

local due = {} -- per-step clocks for the brain; a step runs when its own gap has passed
local function every(name, gap)
	local now = os.clock()
	if (due[name] or 0) > now then
		return false
	end
	due[name] = now + gap
	return true
end

-- pcall doesn't bound a yield: an InvokeServer that never returns parks the thread for good.
-- Returns the packed results, false on a thrown error, nil on timeout.
local function callTimed(remote, timeout, ...)
	if not remote then
		return nil
	end
	local args = table.pack(...)
	local done, res
	task.spawn(function()
		local ok, a, b, c = pcall(function()
			return remote:InvokeServer(table.unpack(args, 1, args.n))
		end)
		res = ok and { a, b, c } or false
		done = true
	end)
	local deadline = os.clock() + (timeout or CALL_TIMEOUT)
	repeat
		task.wait()
	until done or os.clock() > deadline
	return done and res or nil
end

local function fire(remote, ...)
	if remote then
		pcall(remote.FireServer, remote, ...)
	end
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

local SUFFIX = { "", "K", "M", "B", "T", "Qd", "Qn", "Sx", "Sp", "Oc", "No", "Dc" }
local function money(n)
	n = tonumber(n) or 0
	local i = 1
	while math.abs(n) >= 1000 and i < #SUFFIX do
		n, i = n / 1000, i + 1
	end
	return (i == 1 and "%d%s" or "%.2f%s"):format(n, SUFFIX[i])
end

local function ticked(values)
	local set = {}
	for k, v in pairs(values or {}) do
		if type(v) == "string" then
			set[v] = true -- list form: 1 -> "Common"
		elseif type(v) == "table" and v.Title then
			set[v.Title] = true -- row form
		elseif v then
			set[k] = true -- map form: "Common" -> true
		end
	end
	return set
end
assert(ticked({ "Common", "Rare" }).Rare, "the list form ticks its names")
assert(ticked({ Common = true }).Common, "the map form ticks its keys")
assert(not ticked({ Common = false }).Common, "an unticked key in the map form stays off")

local function stageNum(name)
	return tonumber(tostring(name):match("^Stage_(%d+)$"))
end
assert(stageNum("Stage_27") == 27 and stageNum("Stage_x") == nil, "stageNum reads Stage_<n> only")

-- remotes --------------------------------------------------------------------
-- Plain folders: ReplicatedStorage.Remote.<Group>.<Name> (CommunicationUtils.Get).
local RemoteRoot = ReplicatedStorage:WaitForChild("Remote", 10)
local function remote(group, name)
	local g = RemoteRoot and RemoteRoot:FindFirstChild(group)
	local r = g and g:FindFirstChild(name)
	if not r then
		warn(("[loot_forge] Remote.%s.%s missing -- that feature is off"):format(group, name))
	end
	return r
end

local R = {
	stageFinished = remote("Stage", "StageFinishedRF"),
	getOre = remote("Stage", "GetOreRF"),
	claimAll = remote("Stage", "ClaimedAllOreRE"),
	forge = remote("Forge", "ForgeRF"),
	equip = remote("Backpack", "TryEquipItemRE"),
	sell = remote("Backpack", "TrySellItemRE"),
	intoDungeon = remote("Dungeon", "TryIntoDungeonRF"),
	startRound = remote("Dungeon", "StartRoundRE"),
	completeRound = remote("Dungeon", "CompleteRoundRF"),
	exitDungeon = remote("Dungeon", "ExitDungeonRE"),
	dailyTicket = remote("Dungeon", "TryClaimDailyDunTicRE"),
	exitDungeonBE = remote("Stage", "ExitDungeonBE"),
	giveUpBE = remote("Dungeon", "DungeonGiveUpBE"),
	superLoot = remote("SuperLoot", "RefreshSuperLootRE"),
	killSuperLoot = remote("SuperLoot", "KillSuperLootRE"),
	online = remote("Online", "TryClaimRE"),
	offline = remote("Offline", "TryClaimOfflineRewardRE"),
	indexExp = remote("Index", "TryClaimIndexExpRF"),
	indexLevel = remote("Index", "TryClaimLevelRewardRF"),
	updateLog = remote("UpdateLog", "TryClaimUPDRewardRE"),
	upgrade = remote("Upgrade", "UpgradeOnceRE"),
	rebirth = remote("Rebirth", "TryRebirthRE"),
	totalData = remote("Profile", "GetTotalDataRF"),
	update = remote("Profile", "UpdateDataRE"),
	updateTotal = remote("Profile", "UpdateTotalDataRE"),
	message = remote("Message", "MessageRE"),
}

-- configs --------------------------------------------------------------------
-- The game's own modules, required rather than copied: odds, prices and the Train maths all
-- move with a balance patch. Pure functions, so a fresh require is as good as the live one.
local function need(path)
	local ok, m = pcall(function()
		local node = ReplicatedStorage
		for part in path:gmatch("[^%.]+") do
			node = node:WaitForChild(part, 5)
		end
		return require(node)
	end)
	if not ok then
		warn(("[loot_forge] %s unreadable (%s)"):format(path, tostring(m)))
		return nil
	end
	return m
end
local C = {
	loots = need("Config.Stage.Loots"),
	ore = need("Config.Ore.Helper"),
	any = need("Config.AnyHelper"),
	upgrade = need("Config.Upgrade.Config"),
	rebirth = need("Config.Rebirth.Helper"),
	train = need("Config.TrainArea.Config"),
	online = need("Config.Online.Reward"),
	updateLog = need("Config.UpdateLog.Config"),
	forge = need("Utils.ForgeUtils"),
	weaponHelper = need("Config.Weapon.Helper"),
	armorHelper = need("Config.Armor.Helper"),
	balance = need("Utils.BalanceUtils"),
}

local MAX_STAGE = 0
for name in pairs(C.loots or {}) do
	MAX_STAGE = math.max(MAX_STAGE, stageNum(name) or 0)
end
if MAX_STAGE == 0 then
	MAX_STAGE = 27 -- Config.Stage.Loots at dump time
end

-- data -----------------------------------------------------------------------
-- Our own mirror of the save: seeded by GetTotalDataRF, kept by the same UpdateDataRE the
-- game's ProfileData listens on. Data, so streaming can't touch it, and it doesn't depend on
-- whether this executor's require shares the game's module cache.
local store, bpVersion = nil, 0
local conns = {}
table.insert(conns, R.update.OnClientEvent:Connect(function(key, value)
	if store then
		store[key] = value
	end
	if key == "Backpack" then
		bpVersion += 1
	end
end))
table.insert(conns, R.updateTotal.OnClientEvent:Connect(function(all)
	store = all
	bpVersion += 1
end))
task.spawn(function()
	local res = callTimed(R.totalData)
	if res and type(res[1]) == "table" and not store then
		store = res[1]
		bpVersion += 1
	end
end)

local function S(key)
	return store and store[key]
end

local lastMsg, lastMsgAt = "", 0
table.insert(conns, R.message.OnClientEvent:Connect(function(text)
	lastMsg, lastMsgAt = tostring(text), os.clock()
end))

local eco = player:WaitForChild("Eco", 10)
local function ecoValue(name)
	local v = eco and eco:FindFirstChild(name)
	return v and v.Value or 0
end

local function tickets()
	local n = 0
	for _, it in pairs((S("Backpack") or {}).have or {}) do
		if it.ID == "Dungeon_Ticket" then
			n += it.Number or 1
		end
	end
	return n
end

-- UpgradeData.GetMaxNum("OrePack"): config Number at your level + bonus Number
local function bagCap()
	local u = (S("Upgrade") or {}).OrePack or {}
	local row = C.upgrade and C.upgrade.OrePack and C.upgrade.OrePack[u.Level or 0]
	return (row and row.Number or 4) + (u.Number or 0)
end

local function root()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- value ----------------------------------------------------------------------
-- Click power is GetEquipmentAdd(Train) x (1 + GetEquipmentBoost(Train)) x things no item
-- changes, so this product ranks loadouts exactly the way the server pays them.
local function score(bp)
	if not C.balance then
		return 0
	end
	local ok, v = pcall(function()
		return C.balance.GetEquipmentAdd(player, "Train", bp) * (1 + C.balance.GetEquipmentBoost(player, "Train", bp))
	end)
	return ok and v or 0
end

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do
		out[k] = v
	end
	return out
end

local function wearing(bp, slot, uuid, have)
	local eq = copy(bp.equiped)
	eq[slot] = uuid
	return { equiped = eq, have = have or bp.have }
end

local function configType(t)
	return (t == "Armor" or t == "Hat") and "Armor" or t
end

local function rarityOf(it)
	local ok, r = pcall(C.any.GetRarity, configType(it.Type), it.ID)
	return ok and r or nil
end

-- world ----------------------------------------------------------------------
local function hop(cf)
	local r = root()
	if not r then
		return false
	end
	r.CFrame = cf
	return true
end

local function pad(name)
	local touched = workspace:FindFirstChild("TOUCHED")
	return touched and touched:FindFirstChild(name)
end

local function forgeTable()
	local wm = workspace:FindFirstChild("WorldModel")
	local t = wm and wm:FindFirstChild("ForgeTable")
	return t and (t:FindFirstChild("Part") or t:FindFirstChildWhichIsA("BasePart", true))
end

-- Remote first from wherever you stand; if the server doesn't answer, hop onto the thing the
-- game's UI hangs off and try once more. Whichever wins is remembered and printed once.
local where = {}
local function act(key, place, doIt, confirm)
	if where[key] ~= "pad" then
		doIt()
		if confirm() then
			if not where[key] then
				where[key] = "remote"
				log(key .. " works by remote from anywhere")
			end
			return true
		end
		if where[key] == "remote" then
			return false -- proven path, so this is a real refusal
		end
	end
	local part, r = place and place(), root()
	if not (part and r) then
		return false
	end
	local back = r.CFrame
	r.CFrame = part.CFrame
	task.wait(PAD_SETTLE)
	doIt()
	local ok = confirm()
	hop(back)
	if ok and where[key] ~= "pad" then
		where[key] = "pad"
		log(key .. " needs you at the " .. part.Name .. " -- hopping there each time")
	end
	return ok
end

local function bpChanged(since)
	return function()
		return waitFor(function()
			return bpVersion ~= since
		end, CONFIRM)
	end
end

-- farm -----------------------------------------------------------------------
local farm = {
	mode = "Highest unlocked",
	picks = {}, -- stage numbers for "Selected stages"
	gap = FARM_GAP,
	minRank = 1, -- skip ores below this rarity number
	rr = 0,
	park = {},
	strikes = {},
	paid = {}, -- stages that have handed out drops this session
	clears = 0,
	ores = 0,
	claims = 0,
	refused = 0,
	lastStage = nil,
	dirty = true, -- bank once on start: the game's own play may have left ores in the bag
}

local function claim()
	fire(R.claimAll)
	farm.claims += 1
end

local function nextStage()
	local now = os.clock()
	if farm.mode == "Highest unlocked" then
		for n = MAX_STAGE, 1, -1 do
			if (farm.park[n] or 0) <= now then
				return n
			end
		end
		return nil
	end
	local list = {}
	for n in pairs(farm.picks) do
		if (farm.park[n] or 0) <= now then
			table.insert(list, n)
		end
	end
	if #list == 0 then
		return nil
	end
	table.sort(list)
	farm.rr = farm.rr % #list + 1
	return list[farm.rr]
end

local function pick(uuid)
	local res = callTimed(R.getOre, CALL_TIMEOUT, uuid)
	return res and tonumber(res[1])
end

local function farmOnce()
	if farm.dirty then
		claim()
		farm.dirty = false
	end
	local n = nextStage()
	if not n then
		say("every stage is parked -- the server refused them all; retrying in " .. STAGE_PARK .. "s")
		return
	end
	local stage = "Stage_" .. n
	step("farm " .. stage .. " / ask")
	local res = callTimed(R.stageFinished, CALL_TIMEOUT, stage)
	local drops = res and res[1]
	if type(drops) ~= "table" or next(drops) == nil then
		farm.refused += 1
		due.farm = 0 -- a refusal costs no pace: step straight on to the next stage down
		farm.strikes[n] = (farm.strikes[n] or 0) + 1
		-- a stage that never paid is written off on its first no, so the walk down from the
		-- top to your real unlock is one call per locked stage, not three
		if farm.strikes[n] >= (farm.paid[n] and STAGE_STRIKES or 1) then
			farm.strikes[n] = 0
			farm.park[n] = os.clock() + STAGE_PARK
			log(("%s refused %d times -- parked %ds%s"):format(stage, STAGE_STRIKES, STAGE_PARK,
				os.clock() - lastMsgAt < 3 and (" (server: " .. lastMsg .. ")") or ""))
		end
		return
	end
	farm.strikes[n] = 0
	farm.paid[n] = true
	farm.clears += 1
	farm.lastStage = n

	local list = {}
	for uuid, id in pairs(drops) do
		local rank = C.ore and C.ore.GetRarityNumber(id) or 1
		if rank >= farm.minRank then
			table.insert(list, { uuid = uuid, id = id, price = C.ore and C.ore.GetPrice(id) or 0 })
		end
	end
	table.sort(list, function(a, b)
		return a.price > b.price
	end)

	step("farm " .. stage .. " / pick")
	local cap, held = bagCap(), 0
	for _, o in ipairs(list) do
		local count = pick(o.uuid)
		if not count and held > 0 then
			claim() -- refused with ores held: the bag is fuller than we think; bank, try again
			held = 0
			count = pick(o.uuid)
		end
		if not count then
			break -- refused on an empty bag: this drop list is spent
		end
		farm.ores += 1
		held = count
		if count >= cap then
			claim()
			held = 0
		end
	end
	if held > 0 then
		claim()
	end
	say(("%s: %d drops, %d picked (bag %d)"):format(stage, #list, farm.ores, cap))
end

-- super loot -----------------------------------------------------------------
-- The server broadcasts each Super Loot spawn (rarity, uuid, oreID, stage, cf); the client
-- builds the "boss", counts its hits, then sends KillSuperLootRE(uuid) and picks the ore up
-- under the same uuid. Nothing in that needs the fight.
local snipe = { on = true, want = { Legendary = true, Eternal = true, Secret = true }, queue = {}, got = 0, missed = 0 }
table.insert(conns, R.superLoot.OnClientEvent:Connect(function(rarity, uuid, oreId)
	if snipe.on and uuid and snipe.want[tostring(rarity)] then
		table.insert(snipe.queue, { rarity = tostring(rarity), uuid = uuid, id = oreId })
	end
end))

local function snipeOnce()
	local s = table.remove(snipe.queue, 1)
	step("snipe " .. s.rarity)
	fire(R.killSuperLoot, s.uuid)
	for _ = 1, SNIPE_RETRIES do
		task.wait(0.3)
		if pick(s.uuid) then
			claim()
			snipe.got += 1
			log(("sniped %s Super Loot (%s)"):format(s.rarity, tostring(s.id)))
			return
		end
	end
	snipe.missed += 1
	log(("%s Super Loot refused%s"):format(s.rarity, os.clock() - lastMsgAt < 3 and (" -- server: " .. lastMsg) or ""))
end

-- tower ----------------------------------------------------------------------
local tower = { keep = 0, runs = 0, rounds = 0, coin = 0, items = 0, last = "-" }

-- The game's DungeonData table, the one its DungeonManager calls. A require that re-ran the
-- module hands back a copy whose init never ran (GetData() is nil) -- then look in the heap.
local ddCache
local function liveDungeonData()
	if ddCache then
		return ddCache
	end
	local ok, m = pcall(function()
		return require(ReplicatedStorage.LocalData.DungeonData)
	end)
	if ok and type(m) == "table" and type(m.GetData) == "function" and m.GetData() ~= nil then
		ddCache = m
		return m
	end
	if getgc then
		for _, v in ipairs(getgc(true)) do
			if type(v) == "table" and type(rawget(v, "CompleteRound")) == "function" and type(rawget(v, "TryClaimDailyDunTic")) == "function" then
				local okd, d = pcall(v.GetData)
				if okd and d ~= nil then
					ddCache = v
					return v
				end
			end
		end
	end
	return nil
end

local function towerOnce()
	step("tower / enter")
	local coinBefore, itemsBefore = tower.coin, tower.items
	local dd = liveDungeonData()
	local origStart, origExit
	if dd then
		origStart, origExit = dd.StartRound, dd.ExitDungeon
		dd.StartRound = function() end -- its late StartRound(1) would reset the server's round
		dd.ExitDungeon = function() end -- its 80s timer would end our run
	else
		warn("[loot_forge] couldn't reach the game's DungeonData -- tower runs unmuted")
	end
	local ok = pcall(function()
		local into = callTimed(R.intoDungeon, CALL_TIMEOUT, 1)
		if not (into and into[1]) then
			tower.last = "entry refused" .. (os.clock() - lastMsgAt < 3 and (": " .. lastMsg) or "")
			return
		end
		tower.runs += 1
		local cleared = 0
		for r = 1, 30 do
			step("tower / round " .. r)
			local won = false
			for try = 1, ROUND_RETRIES do
				if try == 1 or try == ROUND_RETRIES then
					fire(R.startRound, r)
				end
				task.wait(ROUND_WAIT * try)
				local res = callTimed(R.completeRound, CALL_TIMEOUT, r)
				local loot = res and res[1]
				if type(loot) == "table" and next(loot) ~= nil then
					for _, item in ipairs(loot) do
						if item.ID == "Coin" then
							tower.coin += item.Number or 0
						else
							tower.items += item.Number or 1
						end
					end
					won = true
					break
				end
			end
			if not won then
				break
			end
			cleared = r
			tower.rounds += 1
			-- the game's HUD only counts rounds its own mobs die in, which never happens here;
			-- DungeonFightGUI.SetRoundText writes this one label
			pcall(function()
				player.PlayerGui.Dungeon.Top.Round.text.TextLabel.Text = ("Round %d"):format(math.min(r + 1, 30))
			end)
		end
		tower.last = ("cleared %d/30"):format(cleared)
	end)
	fire(R.exitDungeon)
	task.wait(0.3)
	pcall(function()
		R.exitDungeonBE:Fire() -- the game's own teardown: its mobs, its HUD, back to spawn
	end)
	if player:GetAttribute("Dead") then
		pcall(function()
			R.giveUpBE:Fire() -- a tower death is client-side too; this is the game's revive
		end)
	end
	if dd then
		dd.StartRound, dd.ExitDungeon = origStart, origExit
	end
	if not ok then
		tower.last = "error"
	end
	log(("tower run %d: %s, +%s coin, +%d items, %d tickets left"):format(
		tower.runs, tower.last, money(tower.coin - coinBefore), tower.items - itemsBefore, tickets()))
	say("tower: " .. tower.last)
end

-- forge ----------------------------------------------------------------------
local forge = {
	odds = FORGE_ODDS,
	weapon = true,
	hat = true,
	reserve = {}, -- ore uuid -> count the next forge wants; the seller leaves these alone
	made = 0,
	skipped = 0,
	last = "-",
	plan = { Weapon = "-", Hat = "-" },
}

-- Your ore stacks, highest power first.
local function oreStacks(have)
	local list = {}
	for uuid, it in pairs(have or {}) do
		if it.Type == "Ore" and (it.Number or 0) > 0 then
			table.insert(list, {
				uuid = uuid,
				id = it.ID,
				n = it.Number,
				power = C.ore and C.ore.GetPower(it.ID) or 0,
				price = C.ore and C.ore.GetPrice(it.ID) or 0,
			})
		end
	end
	table.sort(list, function(a, b)
		return a.power > b.power
	end)
	return list
end

-- Weapons: the top-power ores. The bell curve centres on the average power and the good Greats
-- sit at design power 123-150, so nothing but the strongest ores ever gets there.
local function weaponSet(stacks)
	local set, tab, left = {}, {}, WEAPON_ORES
	for _, s in ipairs(stacks) do
		if left <= 0 then
			break
		end
		local take = math.min(s.n, left)
		set[s.uuid] = take
		tab[s.id] = (tab[s.id] or 0) + take
		left -= take
	end
	return left == 0 and set or nil, tab
end

-- The forge's percent table for a set of ores. GetForgeOreResult picks the tier from the ore you
-- put in the MOST of (GetBigIDList runs over the counts first), not the rarest one; the average
-- power then centres a bell curve over every item in those tiers. This is GetEquPercent's own
-- sequence, run through the game's helpers -- checked offline against the dump's modules.
local function forgePercent(kind, oreTab)
	local lo, hi = C.forge.GetForgeOreResult(oreTab)
	local avg = C.forge.GetOreAvgPower(oreTab)
	local list = {}
	for tier = lo, hi do
		if kind == "Weapon" then
			list = C.weaponHelper.GetForgeWeaponsByTLevel("Great", tier, list)
		else
			list = C.armorHelper.GetForgeArmorsByTLevel("Hat_Light", tier, list)
		end
	end
	local weights, total = C.forge.GetEquipmentWeightTable(kind == "Weapon" and "Weapon" or "Armor", list, avg), 0
	for _, w in pairs(weights) do
		total += w
	end
	local pct = {}
	for id, w in pairs(weights) do
		pct[id] = total > 0 and w / total or 0
	end
	return pct, avg
end

-- P(the forged item beats what you wear), and the set's average power.
local function upgradeOdds(kind, bp, oreTab)
	local ok, pct, avg = pcall(forgePercent, kind, oreTab)
	if not ok or type(pct) ~= "table" then
		return nil
	end
	local now = score(bp)
	local have = copy(bp.have)
	local p = 0
	for id, chance in pairs(pct) do
		have["?forge"] = { ID = id, Type = kind }
		if score(wearing(bp, kind, "?forge", have)) > now then
			p += chance
		end
	end
	return p, avg
end

-- Hats: the cheapest 4 that still give the best odds. Light hats top out at design power 67,
-- so strong ores buy nothing past that, and weapon-grade ores are never used. A candidate is k
-- of one ore (the one that sets the tier) plus the cheapest other ores, fewer than k of each so
-- the tier ore stays the most numerous. The odds decide; the sell value breaks ties.
local function hatSet(stacks, bp)
	local pool = {}
	for _, s in ipairs(stacks) do
		if s.power >= HAT_MIN_POWER and s.power < WEAPON_GRADE then
			table.insert(pool, s)
		end
	end
	table.sort(pool, function(a, b)
		return a.price < b.price
	end)
	local best
	for _, lead in ipairs(pool) do
		for k = math.min(lead.n, HAT_ORES), 2, -1 do
			local set, tab, cost, left = { [lead.uuid] = k }, { [lead.id] = k }, lead.price * k, HAT_ORES - k
			for _, s in ipairs(pool) do
				if left <= 0 then
					break
				end
				if s.uuid ~= lead.uuid then
					local take = math.min(s.n, k - 1, left)
					if take > 0 then
						set[s.uuid], tab[s.id] = take, (tab[s.id] or 0) + take
						cost += s.price * take
						left -= take
					end
				end
			end
			if left == 0 then
				local p = upgradeOdds("Hat", bp, tab)
				if p and (not best or p > best.p + 0.001 or (math.abs(p - best.p) <= 0.001 and cost < best.cost)) then
					best = { set = set, tab = tab, p = p, cost = cost }
				end
			end
		end
	end
	if not best then
		return nil
	end
	return best.set, best.tab
end

local function plural(tab)
	local out = {}
	for id, n in pairs(tab) do
		local okN, name = pcall(C.any.GetDisName, "Ore", id)
		table.insert(out, ("%dx %s"):format(n, okN and name or id))
	end
	table.sort(out)
	return table.concat(out, " + ")
end

local function forgeOnce()
	local bp = S("Backpack")
	if not (bp and bp.have and C.forge) then
		return
	end
	table.clear(forge.reserve)
	local stacks = oreStacks(bp.have)
	for _, kind in ipairs({ "Weapon", "Hat" }) do
		if (kind == "Weapon" and forge.weapon) or (kind == "Hat" and forge.hat) then
			local set, tab
			if kind == "Weapon" then
				set, tab = weaponSet(stacks)
			else
				set, tab = hatSet(stacks, bp)
			end
			if not set then
				forge.plan[kind] = "not enough ores"
			else
				for uuid, n in pairs(set) do
					forge.reserve[uuid] = (forge.reserve[uuid] or 0) + n
				end
				local p, avg = upgradeOdds(kind, bp, tab)
				forge.plan[kind] = p and ("%.1f%% upgrade (avg power %.0f: %s)"):format(p * 100, avg or 0, plural(tab)) or "odds unreadable"
				if p and p * 100 >= forge.odds then
					step("forge " .. kind)
					local since = bpVersion
					local okF = act("forge", forgeTable, function()
						local res = callTimed(R.forge, CALL_TIMEOUT, { ConfigType = kind == "Weapon" and "Weapon" or "Armor", UUIDList = set })
						forge.lastRes = res and res[1]
					end, function()
						return forge.lastRes and bpChanged(since)()
					end)
					if okF then
						forge.made += 1
						forge.last = ("%s at %.1f%%"):format(kind, p * 100)
						say("forged a " .. kind:lower() .. " -- " .. forge.plan[kind])
						return -- the backpack moved; re-plan on fresh data next pass
					end
					forge.last = kind .. " refused" .. (os.clock() - lastMsgAt < 3 and (": " .. lastMsg) or "")
				else
					forge.skipped += 1
				end
			end
		end
	end
end

-- equip ----------------------------------------------------------------------
local equipBad = {} -- uuid -> true when the server refused to equip it (UsePower, say)
local equips = 0
local function equipOnce()
	local bp = S("Backpack")
	if not (bp and bp.have) then
		return
	end
	for _, slot in ipairs({ "Weapon", "Hat" }) do
		local cur = (bp.equiped or {})[slot]
		local best, bestScore = cur, score(bp)
		for uuid, it in pairs(bp.have) do
			if it.Type == slot and uuid ~= cur and not equipBad[uuid] then
				local s = score(wearing(bp, slot, uuid))
				if s > bestScore then
					best, bestScore = uuid, s
				end
			end
		end
		if best ~= cur then
			step("equip " .. slot)
			fire(R.equip, best, slot)
			if waitFor(function()
				local now = S("Backpack")
				return now and now.equiped and now.equiped[slot] == best
			end, CONFIRM) then
				equips += 1
				log(("equipped %s %s"):format(slot, tostring(bp.have[best].ID)))
			else
				equipBad[best] = true
			end
			return
		end
	end
end

-- sell -----------------------------------------------------------------------
local sell = { ores = {}, gear = {}, sold = 0, coin = 0, refused = 0, forgeReserve = true }
for i = 1, 8 do
	sell.ores[RARITIES[i]] = true -- Common..Secret: keeps Ore_40+ (Ancient) as forge stock
end
for i = 1, 5 do
	sell.gear[RARITIES[i]] = true -- Common..Legendary
end

local NEVER = { Material = true, EnchStone = true }

local function sellable(bp, uuid, it, now)
	if NEVER[it.Type] or not C.any then
		return 0
	end
	for _, eq in pairs(bp.equiped or {}) do
		if eq == uuid then
			return 0
		end
	end
	local ct = configType(it.Type)
	local rarity = rarityOf(it)
	if not rarity or rarity == "Exclusive" then
		return 0
	end
	local okU, unsell = pcall(C.any.CheckIsUnSell, ct, it.ID)
	local okP, price = pcall(C.any.GetSellPrice, ct, it.ID)
	if (okU and unsell) or not okP or (tonumber(price) or 0) <= 0 then
		return 0
	end
	local n = it.Number or 1
	if it.Type == "Ore" then
		if not sell.ores[rarity] then
			return 0
		end
		if sell.forgeReserve then
			n -= forge.reserve[uuid] or 0
		end
		return math.max(n, 0)
	end
	if not sell.gear[rarity] or next(it.EnchanceList or {}) ~= nil then
		return 0
	end
	local without = copy(bp.have)
	without[uuid] = nil
	if score({ equiped = bp.equiped, have = without }) < now then
		return 0 -- your Train drops without it: the best plain weapon/hat a percent item reads
	end
	return n
end

local function sellOnce()
	local bp = S("Backpack")
	if not (bp and bp.have) then
		return
	end
	local now, batch = score(bp), 0
	local since = bpVersion
	for uuid, it in pairs(bp.have) do
		local n = sellable(bp, uuid, it, now)
		if n > 0 then
			step("sell " .. tostring(it.ID))
			local ok = act("sell", function()
				return pad("Sell")
			end, function()
				fire(R.sell, uuid, n)
			end, bpChanged(since))
			since = bpVersion
			if not ok then
				sell.refused += 1
				return
			end
			sell.sold += n
			local okP, price = pcall(C.any.GetSellPrice, configType(it.Type), it.ID)
			sell.coin += (okP and tonumber(price) or 0) * n
			batch += 1
			if batch >= SELL_BATCH then
				return
			end
		end
	end
end

-- upgrades / rebirth ---------------------------------------------------------
local up = { reserve = 0, bought = 0, next = "-" }
local rb = { on = false, done = 0 }

local function upgradeOnce()
	local levels = S("Upgrade") or {}
	local coin = ecoValue("coin")
	local best, bestPrice
	for kind, rows in pairs(C.upgrade or {}) do
		local lv = (levels[kind] or {}).Level or 0
		local row = rows[lv + 1]
		if row and (not bestPrice or row.Price < bestPrice) then
			best, bestPrice = kind, row.Price
		end
	end
	up.next = best and ("%s %s"):format(best, money(bestPrice)) or "all maxed"
	if not best or coin < bestPrice + up.reserve then
		return
	end
	step("upgrade " .. best)
	local before = ((levels[best] or {}).Level or 0)
	if act("upgrade", function()
		return pad("Upgrade")
	end, function()
		fire(R.upgrade, best)
	end, function()
		return waitFor(function()
			return (((S("Upgrade") or {})[best] or {}).Level or 0) > before
		end, CONFIRM)
	end) then
		up.bought += 1
		log(("upgraded %s to %d"):format(best, before + 1))
	end
end

local function rebirthOnce()
	local r, lv = ecoValue("rebirth"), ecoValue("level")
	if not C.rebirth or C.rebirth.CheckIsMax(r) or lv < (C.rebirth.GetNeedLevel(r + 1) or math.huge) then
		return
	end
	step("rebirth")
	fire(R.rebirth)
	if waitFor(function()
		return ecoValue("rebirth") > r
	end, CONFIRM) then
		rb.done += 1
		log(("rebirth %d -> %d"):format(r, r + 1))
	end
end

-- rewards --------------------------------------------------------------------
local rewards = { claimed = 0, offlineDone = false, logDone = {}, dailyAt = 0 }

local function rewardsOnce()
	-- online time: OnlineData.GetOnlineTimes() = ServerTime - StartTick
	local online = S("Online")
	if online and C.online then
		local t = (workspace:GetAttribute("ServerTime") or os.time()) - (online.StartTick or os.time())
		local got = online.Reward or {}
		for key, row in pairs(C.online) do
			if not got[key] and not got[tonumber(key)] and t >= (row.Time or math.huge) then
				fire(R.online, key)
				rewards.claimed += 1
			end
		end
	end
	-- offline: the free Claim (the x10 next to it is a dev product)
	if not rewards.offlineDone and player:GetAttribute("OfflineRewardValue") then
		rewards.offlineDone = true
		fire(R.offline)
		rewards.claimed += 1
	end
	-- the daily tower ticket
	local dun, today = S("Dungeon"), workspace:GetAttribute("today")
	if dun and today and not (dun.DailyGet or {})[today] and os.clock() > rewards.dailyAt then
		rewards.dailyAt = os.clock() + 60
		fire(R.dailyTicket)
		rewards.claimed += 1
	end
	-- Index exp for everything unlocked but unclaimed ("Weapon-K_24" -> "Weapon", "K_24")
	local index = S("Index")
	if index and index.unlocked then
		local n = 0
		for key in pairs(index.unlocked) do
			if not (index.claimed or {})[key] then
				local kind, id = tostring(key):match("^(.-)%-(.+)$")
				if kind then
					callTimed(R.indexExp, CALL_TIMEOUT, kind, id)
					rewards.claimed += 1
					n += 1
					if n >= 10 then
						break
					end
				end
			end
		end
	end
	if every("indexLevel", INDEX_LEVEL_GAP) then
		callTimed(R.indexLevel)
	end
	-- update-log rewards, once each (PemData "UPDRD_<i>" marks the claimed ones)
	local pem = S("Pem") or {}
	for i = 1, #(C.updateLog or {}) do
		if not pem["UPDRD_" .. i] and not rewards.logDone[i] then
			rewards.logDone[i] = true
			fire(R.updateLog, i)
		end
	end
end

-- train ----------------------------------------------------------------------
local train = { arms = 0, area = nil, warned = false }

local function bestArea()
	local r, best = ecoValue("rebirth"), nil
	for i, row in ipairs(C.train or {}) do
		if not row.IsPay and (row.NeedRebirth or 0) <= r then
			best = i
		end
	end
	return best
end

local function trainOnce()
	local n = bestArea()
	if not n then
		return
	end
	train.area = n
	if tonumber(player:GetAttribute("AutoTrainAreaID")) == n then
		train.warned = false
		return
	end
	local area = workspace:FindFirstChild("TOUCHED") and workspace.TOUCHED:FindFirstChild("AutoTrainArea")
	local part = area and area:FindFirstChild(tostring(n))
	if not part then
		return
	end
	step("train / area " .. n)
	hop(part.CFrame)
	train.arms += 1
	if not waitFor(function()
		return tonumber(player:GetAttribute("AutoTrainAreaID")) == n
	end, CONFIRM) and not train.warned then
		train.warned = true
		warn(("[loot_forge] stood in training area %d but the server didn't start training you"):format(n))
	end
end

-- brain ----------------------------------------------------------------------
-- One thread, one beat, in priority order: a Super Loot is gone in seconds, a tower run
-- needs the stage loop quiet, backpack work (forge -> equip -> sell) is ordered so the
-- seller never sells an ore the forge just planned for, and the stage loop runs last.
-- Nothing else moves your character or touches your backpack, so nothing can fight.
local want = { farm = false, tower = false, forge = false, equip = false, sell = false, upgrade = false, rewards = false, train = false }

local lastErr = {}
local function run(name, fn)
	local ok, err = pcall(fn)
	if not ok and os.clock() - (lastErr[name] or 0) > 5 then
		lastErr[name] = os.clock()
		warn(("[loot_forge] %s: %s"):format(name, tostring(err)))
	end
end

local brain = { on = false, gen = 0, inBody = false }
function brain.set(on)
	brain.on = on
	brain.gen += 1
	if not on then
		return
	end
	local mine = brain.gen
	task.spawn(function()
		while brain.on and brain.gen == mine do
			if not store then
				say("waiting for your save data...")
				task.wait(1)
				continue
			end
			brain.inBody = true
			if #snipe.queue > 0 then
				run("snipe", snipeOnce)
			end
			if want.tower and every("tower", TOWER_GAP) and ecoValue("rebirth") >= 2 and tickets() > tower.keep then
				run("tower", towerOnce)
			end
			if want.forge and every("forge", FORGE_GAP) then
				run("forge", forgeOnce)
			end
			if want.equip and every("equip", EQUIP_GAP) then
				run("equip", equipOnce)
			end
			if want.sell and every("sell", SELL_GAP) then
				run("sell", sellOnce)
			end
			if want.upgrade and every("upgrade", UPGRADE_GAP) then
				run("upgrade", upgradeOnce)
			end
			if rb.on and every("rebirth", REBIRTH_GAP) then
				run("rebirth", rebirthOnce)
			end
			if want.rewards and every("rewards", REWARD_GAP) then
				run("rewards", rewardsOnce)
			end
			if want.train and every("train", TRAIN_GAP) then
				run("train", trainOnce)
			end
			if want.farm and every("farm", farm.gap) then
				run("farm", farmOnce)
			end
			brain.inBody = false
			step("idle")
			task.wait(TICK)
		end
	end)
end

local function rethink()
	local any = rb.on or snipe.on
	for _, on in pairs(want) do
		any = any or on
	end
	if any ~= brain.on then
		brain.set(any)
	end
end

-- anti-afk -------------------------------------------------------------------
-- AFKClient counts seconds since the last InputBegan and fires AFKHandle at 1100; a real key
-- event resets it (VirtualUser alone doesn't reach InputBegan). F15 is bound to nothing.
local afk = { on = false, gen = 0, conns = {} }
function afk.nudge()
	pcall(function()
		local vim = game:GetService("VirtualInputManager")
		vim:SendKeyEvent(true, Enum.KeyCode.F15, false, game)
		vim:SendKeyEvent(false, Enum.KeyCode.F15, false, game)
	end)
	pcall(function()
		local vu = game:GetService("VirtualUser")
		vu:CaptureController()
		vu:ClickButton2(Vector2.new())
	end)
end
function afk.set(on)
	afk.gen += 1
	afk.on = on
	for _, c in ipairs(afk.conns) do
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
	task.spawn(function()
		local overlay
		pcall(function()
			overlay = game:GetService("CoreGui"):WaitForChild("RobloxPromptGui", 10):WaitForChild("promptOverlay", 10)
		end)
		if overlay and alive() then
			table.insert(afk.conns, overlay.ChildAdded:Connect(function(child)
				if child.Name == "ErrorPrompt" and alive() then
					warn("[loot_forge] disconnected -- rejoining in " .. REJOIN_DELAY .. "s")
					task.wait(REJOIN_DELAY)
					pcall(function()
						game:GetService("TeleportService"):Teleport(game.PlaceId, player)
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

-- A separate thread: a brain parked in a yield can't report that it is.
local dogGen = 0
local function startDog()
	dogGen += 1
	local mine = dogGen
	task.spawn(function()
		while dogGen == mine do
			if brain.on and brain.inBody and os.clock() - markAt > WATCHDOG then
				warn(("[loot_forge] stuck %ds at: %s"):format(math.floor(os.clock() - markAt), mark))
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
	game = "Loot to Forge", -- fallback until the live name lands
	folder = "LootToForge", -- never rename: saved configs orphan
	size = UDim2.fromOffset(560, 460),
})
if not Window then
	for _, c in ipairs(conns) do
		pcall(c.Disconnect, c)
	end
	return -- panel.lua already said why
end

local function toggle(sec, title, desc, key, value)
	sec:Toggle({
		Title = title,
		Desc = desc,
		Value = value or false,
		Callback = function(on)
			want[key] = on
			rethink()
		end,
	})
end

local function card(tab, title, icon)
	return tab:Section({ Title = title, Icon = icon, Box = true, BoxBorder = true, Opened = true })
end

local stageNames = {}
for n = 1, MAX_STAGE do
	table.insert(stageNames, "Stage_" .. n)
end

do
	local Farm = Window:Tab({ Title = "Farm", Icon = "solar:home-2-bold" })

	local farming = card(Farm, "Farming", "solar:map-point-bold")
	toggle(farming, "Auto Farm", "Asks the server for a stage's drops, picks best-price first, banks -- no mobs, no walking", "farm")
	farming:Dropdown({
		Title = "Stage mode",
		Values = { "Highest unlocked", "Selected stages" },
		Value = farm.mode,
		Callback = function(v)
			if v == "Highest unlocked" or v == "Selected stages" then
				farm.mode = v
			end
		end,
	})
	farming:Dropdown({
		Title = "Selected stages",
		Desc = "Rotated in order when the mode is 'Selected stages'",
		Values = stageNames,
		Value = {},
		Multi = true,
		AllowNone = true,
		Callback = function(picked)
			table.clear(farm.picks)
			for name in pairs(ticked(picked)) do
				local n = stageNum(name)
				if n then
					farm.picks[n] = true
				end
			end
		end,
	})
	farming:Slider({
		Title = "Seconds per stage",
		Desc = "2.5 is a fast player's pace. The server has no cooldown -- lower is your risk to take",
		Step = 0.1,
		Value = { Min = FARM_GAP_MIN, Max = 10, Default = FARM_GAP },
		Callback = function(v)
			farm.gap = math.max(tonumber(v) or FARM_GAP, FARM_GAP_MIN)
		end,
	})

	local combat = card(Farm, "Combat", "solar:sword-bold")
	combat:Paragraph({
		Title = "No kill needed",
		Desc = "Mobs, their HP and yours are simulated on your client; the server never hears a hit. "
			.. "Drops are rolled when a stage is asked for, so Auto Farm skips the fight entirely -- "
			.. "nothing to one-shot, and you can't die to a mob that never spawns.",
	})

	local loot = card(Farm, "Loot", "solar:box-bold")
	loot:Dropdown({
		Title = "Skip ores below",
		Desc = "Everything is picked best-price first and banked when the bag fills, so 'Common' loses nothing",
		Values = RARITIES,
		Value = "Common",
		Callback = function(v)
			for i, name in ipairs(RARITIES) do
				if name == v then
					farm.minRank = i
				end
			end
		end,
	})
	loot:Toggle({
		Title = "Super Loot sniper",
		Desc = "The moment the server announces one: kill + pick up by id, from anywhere",
		Value = true,
		Callback = function(on)
			snipe.on = on
			rethink()
		end,
	})
	loot:Dropdown({
		Title = "Super Loot rarities",
		Values = { "Legendary", "Eternal", "Secret" },
		Value = { "Legendary", "Eternal", "Secret" },
		Multi = true,
		AllowNone = true,
		Callback = function(picked)
			table.clear(snipe.want)
			for k in pairs(ticked(picked)) do
				snipe.want[k] = true
			end
		end,
	})
end

do
	local Gear = Window:Tab({ Title = "Forge", Icon = "solar:fire-bold" })

	local f = card(Gear, "Forge", "solar:fire-bold")
	f:Paragraph({
		Title = "How it picks",
		Desc = "Weapons: your 13 strongest ores (100% Great) -- beating ~200M Train needs Bussin-Ice, Panic-Core or The Apex. "
			.. "Hats: the cheapest 4 that keep the best odds (e.g. 2 Colanite + 2 Secret), never weapon-grade ores. "
			.. "Forges only when the game's own odds say the result beats what you wear -- the Stats tab shows those odds. Armor is Defence only, never forged.",
	})
	toggle(f, "Auto Forge", "Odds-gated; reserves the ores it plans to use", "forge")
	f:Toggle({
		Title = "Forge weapons",
		Value = true,
		Callback = function(on)
			forge.weapon = on
		end,
	})
	f:Toggle({
		Title = "Forge hats",
		Value = true,
		Callback = function(on)
			forge.hat = on
		end,
	})
	f:Slider({
		Title = "Min upgrade odds (%)",
		Desc = "Below this the ores are kept (or sold, per your ticks) instead of burned on a likely downgrade",
		Step = 1,
		Value = { Min = 1, Max = 100, Default = FORGE_ODDS },
		Callback = function(v)
			forge.odds = tonumber(v) or FORGE_ODDS
		end,
	})
	toggle(f, "Auto Equip Upgrade", "Weapon and hat by the game's own Train maths", "equip")

	local s = card(Gear, "Selling", "solar:dollar-bold")
	toggle(s, "Auto Sell", "By remote from anywhere. Never: equipped, enhanced, Exclusive, stones, tickets, your Train sources", "sell")
	local function rarityPicker(title, desc, set)
		local current = {}
		for _, name in ipairs(RARITIES) do
			if set[name] then
				table.insert(current, name)
			end
		end
		s:Dropdown({
			Title = title,
			Desc = desc,
			Values = RARITIES,
			Value = current,
			Multi = true,
			AllowNone = true,
			Callback = function(picked)
				table.clear(set)
				for k in pairs(ticked(picked)) do
					set[k] = true
				end
			end,
		})
	end
	rarityPicker("Sell ores of rarity", "Ore_32-39 are Secret, Ore_40-47 Ancient, Ore_48 Infinite", sell.ores)
	rarityPicker("Sell gear of rarity", "Weapons, hats, armor you don't wear and that don't feed your Train", sell.gear)
	s:Toggle({
		Title = "Keep the forge's ores",
		Desc = "The ores Auto Forge plans to use are never sold, even if their rarity is ticked",
		Value = true,
		Callback = function(on)
			sell.forgeReserve = on
		end,
	})
end

do
	local Tower = Window:Tab({ Title = "Tower", Icon = "solar:buildings-bold" })
	local t = card(Tower, "Frozen Tower", "solar:snowflake-bold")
	t:Paragraph({
		Title = "How it runs",
		Desc = "Rebirth 2+, 1 ticket per run, always from round 1 (the most loot per ticket). "
			.. "Each round is StartRound -> 0.35s -> CompleteRound, which hands back the loot: ~11s for all 30.",
	})
	toggle(t, "Auto Tower", "Runs while you have tickets above the keep; pauses the stage loop for the run", "tower")
	t:Input({
		Title = "Keep tickets",
		Value = "0",
		Placeholder = "0",
		Callback = function(v)
			tower.keep = math.max(tonumber(v) or 0, 0)
		end,
	})
end

do
	local Progress = Window:Tab({ Title = "Progress", Icon = "solar:bolt-circle-bold" })

	local tr = card(Progress, "Training", "solar:dumbbell-bold")
	toggle(tr, "Auto Train", "Stands you in the best free training area your rebirth allows; the game clicks from there", "train")

	local g = card(Progress, "Upgrades & rebirth", "solar:arrow-up-bold")
	toggle(g, "Auto Upgrade", "OrePack / Luck / Train, cheapest next level first", "upgrade")
	g:Input({
		Title = "Coin reserve",
		Desc = "Upgrades leave at least this many coins",
		Value = "0",
		Placeholder = "0",
		Callback = function(v)
			up.reserve = math.max(tonumber(v) or 0, 0)
		end,
	})
	g:Toggle({
		Title = "Auto Rebirth",
		Desc = "Whenever your level meets the next one (25 x rebirth). What it resets is server-side -- watch the first",
		Value = false,
		Callback = function(on)
			rb.on = on
			rethink()
		end,
	})

	local x = card(Progress, "Rewards", "solar:gift-bold")
	toggle(x, "Auto Rewards", "Online time, offline, daily tower ticket, Index exp + levels, update log", "rewards")
	x:Toggle({
		Title = "Anti-AFK + rejoin",
		Value = true,
		Callback = function(on)
			afk.set(on)
		end,
	})
end

-- Loop threads lose the capability to write to the panel after their first yield, so they
-- leave text in upvalues and Heartbeat (our own identity) writes it.
local Stats = Window:Tab({ Title = "Stats", Icon = "solar:chart-bold" })
local statsSec = card(Stats, "Dashboard", "solar:chart-2-bold")
local status = statsSec:Paragraph({ Title = "Status", Desc = "idle" })
local ROWS = { "Farm", "Forge", "Tower", "Progress", "Session" }
local dashRow, dashText = {}, {}
for _, title in ipairs(ROWS) do
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
	Farm = function()
		local parked = {}
		for n, t in pairs(farm.park) do
			if t > os.clock() then
				table.insert(parked, n)
			end
		end
		table.sort(parked)
		return ("clears %d   ores %d   banks %d   refused %d   last Stage_%s   bag %d\nparked: %s   super loot %d (missed %d)"):format(
			farm.clears, farm.ores, farm.claims, farm.refused, tostring(farm.lastStage or "-"), bagCap(),
			#parked > 0 and table.concat(parked, ",") or "none", snipe.got, snipe.missed)
	end,
	Forge = function()
		local bp = S("Backpack") or {}
		local eq = bp.equiped or {}
		local function name(slot)
			local it = eq[slot] and (bp.have or {})[eq[slot]]
			return it and it.ID or "-"
		end
		return ("wearing %s + %s   train score %s\nnext weapon %s   next hat %s   forged %d   last %s\nsold %d (~%s)   refused %d   equips %d"):format(
			name("Weapon"), name("Hat"), money(score(bp)), forge.plan.Weapon, forge.plan.Hat, forge.made, forge.last,
			sell.sold, money(sell.coin), sell.refused, equips)
	end,
	Tower = function()
		return ("tickets %d   runs %d   rounds %d   coin %s   items %d   last %s"):format(
			tickets(), tower.runs, tower.rounds, money(tower.coin), tower.items, tower.last)
	end,
	Progress = function()
		return ("coin %s   level %d   rebirth %d   power %s\nnext upgrade %s   bought %d   rebirths %d   train area %s (arms %d)   rewards %d"):format(
			money(ecoValue("coin")), ecoValue("level"), ecoValue("rebirth"), money(ecoValue("power")),
			up.next, up.bought, rb.done, tostring(train.area or "-"), train.arms, rewards.claimed)
	end,
	Session = function()
		local on = {}
		for k, v in pairs(want) do
			if v then
				table.insert(on, k)
			end
		end
		table.sort(on)
		return ("running: %s   at: %s\nlast server message: %s"):format(#on > 0 and table.concat(on, ", ") or "nothing", mark, lastMsg)
	end,
}
local dashGen = 0
local function startDash()
	dashGen += 1
	local mine = dashGen
	task.spawn(function()
		while dashGen == mine do
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
rethink() -- the sniper is on by default
say("ready")

-- close ----------------------------------------------------------------------
local function stopAll()
	for k in pairs(want) do
		want[k] = false
	end
	rb.on = false
	snipe.on = false
	brain.set(false)
	dogGen += 1
	dashGen += 1
	afk.set(false) -- a stopped script must not rejoin you
	pcall(drain.Disconnect, drain)
	for _, c in ipairs(conns) do
		pcall(c.Disconnect, c)
	end
end

Window:OnDestroy(function()
	stopAll()
	getgenv().lootForgeStop = nil
end)

getgenv().lootForgeStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().lootForgeStop = nil
end
