--[[ Split Sea for Animals -- split, keep the best of every wave, hatch, train, grow (88047783411976)

     SPLIT    : WaveService.Start(5). 5 is the top of the charge bar -- the "Excellent!" the game
                shows only buys open time, and nothing here uses open time, so every split is
                perfect for free. The server rolls the wave and hands back its whole spawn list;
                picking up is client-only (PickupController welds a local model to you) and the
                claim is Finished(ids) from spawn. So nothing walks the sea: every item the wave
                rolled is scored and the best <Carry> of them are claimed in one call.
     BOSSES   : the purple doors lead to a boss room whose item is in that same spawn list
                (isBossItem). The boss, its chase and its "caught you" are all client-side --
                BossComponent reports a catch by calling Finished({}) itself -- so a boss item
                claimed by id is never chased. Big/huge eggs a tier up; taken when it scores best.
                Which bosses you can reach is your Power (reach >= the boss's wave part).
     RARITY   : optional multi-select -- only items wearing a ticked rarity label are taken (still
                most valuable first), and auto sell never sells an egg of a ticked rarity.
     BEST     : an egg is worth what it hatches into, not its rarity label: sum over its animals
                of chance x cash/s, x mutation x size -- BrainrotUtils' own maths -- plus the
                index: completing an egg's collection in one mutation adds 10% to your cash
                multiplier, so a hatch that fills a gap scores its share of that.
     TRAIN    : stands you on your plot's training pad and calls StartTraining(); the server
                ticks Power every second while you stay on it (the dump never paid off it).
     x2 BONUS : its own switch, on by default: every SpawnBonus id is claimed with ClaimBonus,
                retried for a few seconds if refused -- also while you train by hand.
     EGGS     : best eggs from inventory onto free plot spots (10 max), each hatched the moment
                its timer ends. InitSkip is never called -- that is the Robux skip.
     EQUIP    : AnimalService.EquipBest, the server's own button, when an inventory animal beats
                the weakest on your plot or a slot is free.
     UPGRADE  : Carry, plot slots, staffs (luck), dumbbells (power), by cost per weight; waits
                while the next rebirth is close. Speed is off by default -- nothing here walks.
     REBIRTH  : once cash covers the next one (x the input). What a rebirth wipes is decided
                server-side and isn't in the dump -- watch your first one.
     SELL     : off by default. Inventory caps at 200 and a full one refuses splits; this keeps
                the best eggs and sells animals your plot has outgrown.

     First split probes where the server wants you: Start from where you stand, then from the
     sea edge; the claim from spawn. The winner is kept and printed to F9.

     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().splitSeaStop() ]]

-- config ---------------------------------------------------------------------
local TICK = 0.1 -- the brain's beat; every step below is gated on its own clock
local CALL_TIMEOUT = 8 -- an InvokeServer that hasn't returned by now is abandoned

local SPLIT_GAP_MIN = 0.2 -- floor between splits; a refusal backs off from here...
local SPLIT_GAP_MAX = 10 -- ...up to this. Raise the floor if the server starts refusing
local EDGE_WAIT = 2 -- after a hop to the sea edge, for the server to clear InSpawn
local SPAWN_WAIT = 3 -- after a hop to spawn, for the server to write InSpawn
local CLAIM_WAIT = 3 -- after Finished, for the claimed ids to reach your inventory

local HATCH_GAP = 1
local HATCH_PARK = 8 -- a hatch plays a 3s animation before the egg leaves PlacedEggs
local PLACE_GAP = 0.5
local PLACE_CONFIRM = 2
local EGG_LIFT = 1.5 -- studs above the plot surface a placed egg is aimed at
local SPOT_CLEAR = 3 -- a spot this close to an existing egg counts as taken
local EQUIP_GAP = 10 -- EquipBest is a server-side sort; no need to ask often
local UPGRADE_GAP = 2
local UPGRADE_CONFIRM = 2
local REBIRTH_GAP = 3
local TRAIN_GAP = 1 -- re-arm check; a split hop or a respawn can end a training session
local PAD_RANGE = 4 -- studs off your training pad before the next train check hops you back
local PAD_SETTLE = 0.3 -- after that hop, for the server to see you on the pad
local TRAIN_STALL = 6 -- s of "training" with Power not moving before F9 says so
local BONUS_RETRY = 0.5 -- between x2 bonus claims the server refused...
local BONUS_WINDOW = 4 -- ...for this long after it spawned; raise if F9 shows early refusals
local SELL_GAP = 5
local SELL_CONFIRM = 2 -- after a sale, for the item to leave the inventory
local SELL_BATCH = 20 -- sales per pass, so a big clear-out doesn't hold the brain
local EGG_KEEP = 30 -- auto sell keeps this many of your best eggs

local INV_LIMIT = 200 -- Modifiers.InventoryLimit
local MAX_EGGS = 10 -- Modifiers.MaxEggs
local BASE_SLOTS = 10 -- Modifiers.MaxAnimals before PlotUpgrade and passes
local SAVE_HORIZON = 120 -- s: when the next rebirth is this close at current income, upgrades wait
local INCOME_WINDOW = 30 -- s of CashEarned averaged into the income figure
local INDEX_WEIGHT = 1 -- scales the index share in egg scores; 0 ranks on cash/s alone
-- Upgrade priority: an upgrade is ranked by price / weight, cheapest first. Carry multiplies
-- every split; staffs raise roll luck; dumbbells raise Power -> reach -> better parts and bosses.
-- ponytail: hand-set weights, not a simulated payback -- replace if a real rate is measurable
local WEIGHT = { Carry = 4, staff = 2, tool = 2, PlotUpgrade = 1.5, PlotUpgradeFull = 3, MovementSpeed = 0.1 }

local WATCHDOG = 30
local AFK_BEAT = 60
local REJOIN_DELAY = 5
local DASH_GAP = 1

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().splitSeaStop then
	getgenv().splitSeaStop() -- re-running must not stack a second panel or loop
end

local function log(msg)
	print("[split_sea] " .. msg)
end

local pending -- last line a loop wants on the status row; drained on Heartbeat
local function say(msg)
	pending = msg
end

local mark, markAt = "idle", os.clock()
local function step(what)
	mark, markAt = what, os.clock()
end

-- pcall doesn't bound a yield: an InvokeServer that never returns parks the thread for good,
-- which looks exactly like a dead loop. Fire on another thread and give up on a clock.
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

local function count(t)
	local n = 0
	for _ in pairs(t or {}) do
		n = n + 1
	end
	return n
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

-- remotes --------------------------------------------------------------------
-- Knit, vendored: Packages._Index["sleitnick_knit@1.7.0"].knit.Services. Matched on "knit"
-- inside the folder name so a version bump isn't a dead script.
local function knitServices()
	local pkgs = ReplicatedStorage:FindFirstChild("Packages")
	local index = pkgs and pkgs:FindFirstChild("_Index")
	for _, child in ipairs(index and index:GetChildren() or {}) do
		if child.Name:lower():find("knit") then
			local knit = child:FindFirstChild("knit")
			local services = knit and knit:FindFirstChild("Services")
			if services then
				return services
			end
		end
	end
end
local SERVICES = knitServices()

local function remote(svc, name, kind)
	local s = SERVICES and SERVICES:FindFirstChild(svc)
	local f = s and s:FindFirstChild(kind or "RF")
	local r = f and f:FindFirstChild(name)
	if not r then
		warn(("[split_sea] %s.%s missing -- that feature is off"):format(svc, name))
	end
	return r
end

-- Buying a staff or a dumbbell equips it server-side (the dump: BuyPickaxe("stone") is
-- followed by EquippedPickaxe = "stone" with no Equip call), so neither Equip is wired.
-- Deliberately NOT wired: EggService.InitSkip and RebirthService.InitSkip (Robux skips),
-- UpgradesService.PromptAnimalSlotTier / PromptSpeedTier and every BuyRBX (Robux prompts).
local R = {
	start = remote("WaveService", "Start"),
	finished = remote("WaveService", "Finished"),
	train = remote("TrainingService", "StartTraining"),
	untrain = remote("TrainingService", "StopTraining"),
	claimBonus = remote("TrainingService", "ClaimBonus"),
	spawnBonus = remote("TrainingService", "SpawnBonus", "RE"),
	buyTool = remote("TrainingService", "BuyTrainTool"),
	buyStaff = remote("PickaxeService", "BuyPickaxe"),
	upgrade = remote("UpgradesService", "Upgrade"),
	rebirth = remote("RebirthService", "Rebirth"),
	place = remote("EggService", "PlaceEgg"),
	hatch = remote("EggService", "HatchEgg"),
	equipBest = remote("AnimalService", "EquipBest"),
	cashEarned = remote("AnimalService", "CashEarned", "RE"),
	sellEgg = remote("InventoryService", "SellEgg"),
	sellRot = remote("InventoryService", "SellBrainrot"),
}

-- configs --------------------------------------------------------------------
-- The game's own tables, required rather than copied: odds, prices and multipliers all move
-- with a balance patch.
local function cfg(name)
	local ok, m = pcall(function()
		return require(ReplicatedStorage.Configs[name])
	end)
	if not ok then
		warn(("[split_sea] Configs.%s unreadable (%s)"):format(name, tostring(m)))
		return nil
	end
	return m
end
local C = {
	eggs = cfg("EggsConfig"),
	rots = cfg("BrainrotsConfig"),
	mut = cfg("MutationConfig"),
	size = cfg("SizeConfig"),
	traits = cfg("TraitsConfig"),
	up = cfg("UpgradeConfig"),
	rebirth = cfg("RebirthConfig"),
	staff = cfg("StaffConfig"),
	tools = cfg("TrainToolConfig"),
	wave = cfg("WaveConfig"),
	boss = cfg("BossConfig"),
	reach = cfg("PowerWaveConfig"),
}
-- WaveConfig.MAX_TIME_EXTENSION: what a full charge bar sends (StaffController rounds
-- MIN + (MAX - MIN) * bar to this at the top).
local PERFECT = C.wave and C.wave.MAX_TIME_EXTENSION or 5

-- data -----------------------------------------------------------------------
-- The client's mirror of your save (ReplicaController -> PlayerDataReplica). Data, so
-- streaming can't touch it, and it's what the game's own HUD reads.
local replica, lastScan = nil, -math.huge
local function D()
	if replica and replica.Data then
		return replica.Data
	end
	pcall(function()
		local Knit = require(ReplicatedStorage.Packages.Knit)
		local rc = Knit.GetController("ReplicaController")
		if rc:IsReplicaReady() then
			replica = rc:GetReplica()
		end
	end)
	-- An executor whose require hands back a fresh Knit (not the started one) lands here: the
	-- replica is still in the heap, shaped like no other table.
	if not replica and getgc and os.clock() - lastScan > 10 then
		lastScan = os.clock()
		for _, v in ipairs(getgc(true)) do
			if type(v) == "table" then
				local d = rawget(v, "Data")
				if type(d) == "table" and rawget(d, "PlacedAnimals") and rawget(d, "Currencies") then
					replica = v
					break
				end
			end
		end
	end
	return replica and replica.Data
end

local function cash(d)
	return (d.Currencies or {}).Cash or 0
end

-- value ----------------------------------------------------------------------
-- BrainrotUtils.GetCashPerSecondBase, restated so a scoring pass can't be taken down by that
-- module's other requires: base x mutation x 1.25^(level-1) x traits x size.
local function rotCps(e)
	local c = C.rots and C.rots.CONFIG[e.brainrotType]
	if not c then
		return 0
	end
	local m = C.mut and C.mut[e.mutation or "NORMAL"]
	local s = C.size and C.size.SIZES[e.size or "baby"]
	local t = 1
	for _, tr in pairs(type(e.traits) == "table" and e.traits or {}) do
		local tc = C.traits and C.traits.TRAITS and C.traits.TRAITS[tr]
		t = t * (tc and tc.cashMulti or 1)
	end
	return (c.cashPerSecond or 1) * (m and m.cashMulti or 1) * 1.25 ^ ((e.level or 1) - 1) * t * (s and s.cashMulti or 1)
end

-- What an egg hatches into, on average. Mutation and size carry through the hatch (the dump:
-- a GOLD basic egg hatched a GOLD pigeon), so they multiply every outcome.
local function eggCps(egg, mutation, size)
	local total, sum = 0, 0
	for _, it in ipairs(egg.items or {}) do
		total = total + it.chance
	end
	for _, it in ipairs(egg.items or {}) do
		if it.type == "Brainrot" then
			sum = sum + it.chance / total * rotCps({ brainrotType = it.id, mutation = mutation or "NORMAL", size = size })
		end
	end
	return sum
end

if C.rots and C.mut and C.size then
	local id = next(C.rots.CONFIG)
	local mut, sz = next(C.mut), next(C.size.SIZES)
	local base = rotCps({ brainrotType = id })
	local got = rotCps({ brainrotType = id, mutation = mut, size = sz, level = 2 })
	local want = base * C.mut[mut].cashMulti * C.size.SIZES[sz].cashMulti * 1.25
	assert(math.abs(got - want) <= 1e-9 * math.max(1, want), "rotCps multipliers")
	local egg = { items = { { id = id, type = "Brainrot", chance = 60 }, { id = id, type = "Brainrot", chance = 40 } } }
	assert(math.abs(eggCps(egg, "NORMAL", "baby") - base) <= 1e-9 * math.max(1, base), "eggCps weighting")
end

local function plotCps(d)
	local sum = 0
	for _, a in pairs(d.PlacedAnimals or {}) do
		sum = sum + rotCps(a)
	end
	return sum
end

-- Modifiers.CashMulti: each egg index completed in a mutation (every animal the egg can
-- hatch, unlocked in that mutation) adds 10% of the base multiplier. A hatch that fills one of
-- k gaps is 1/k of that, so the bonus is P(new) / k x 10% of what your plot earns.
-- ponytail: ignores the UnlockedEggs[egg].NORMAL gate CompletedEggs also checks
local function indexBonus(d, egg, mutation)
	if INDEX_WEIGHT <= 0 or not C.eggs or not C.eggs.IsInIndex(egg) then
		return 0
	end
	local unlocked = d.UnlockedBrainrots or {}
	local mut = mutation or "NORMAL"
	local total, missing, pNew = 0, 0, 0
	for _, it in ipairs(egg.items) do
		total = total + it.chance
	end
	for _, it in ipairs(egg.items) do
		if it.type == "Brainrot" and not (unlocked[it.id] and unlocked[it.id][mut]) then
			missing = missing + 1
			pNew = pNew + it.chance / total
		end
	end
	if missing == 0 then
		return 0
	end
	return INDEX_WEIGHT * pNew / missing * 0.1 * plotCps(d)
end

-- One number for anything a wave or an inventory can hold, in base cash/s.
local function worth(d, e)
	if e.eggType then
		local egg = C.eggs and C.eggs.EGGS[e.eggType]
		return egg and eggCps(egg, e.mutation, e.size) + indexBonus(d, egg, e.mutation) or 0
	end
	if e.brainrotType then
		return rotCps(e)
	end
	return 0
end

local function hatchSeconds(e)
	local egg = C.eggs and C.eggs.EGGS[e.eggType]
	local s = C.size and C.size.SIZES[e.size or "baby"]
	return (egg and egg.hatchTime or 0) * (s and s.timeToHatchMulti or 1)
end

local function describe(e)
	local name = e.eggType or e.brainrotType or "?"
	local mut = e.mutation and e.mutation ~= "NORMAL" and (e.mutation:lower() .. " ") or ""
	local sz = e.size and e.size ~= "baby" and (e.size .. " ") or ""
	return mut .. sz .. name
end

-- Inventory eggs, best first; a tie goes to the shorter hatch.
local function inventoryEggs(d)
	local list = {}
	for key, it in pairs(d.Inventory or {}) do
		local e = it.innerEntity
		if it.itemType == "Egg" and e then
			table.insert(list, { key = key, id = e.id or key, e = e, v = worth(d, e), t = hatchSeconds(e) })
		end
	end
	table.sort(list, function(a, b)
		if a.v ~= b.v then
			return a.v > b.v
		end
		return a.t < b.t
	end)
	return list
end

local function plotStats(d)
	local placed, weakest = 0, math.huge
	for _, a in pairs(d.PlacedAnimals or {}) do
		placed = placed + 1
		weakest = math.min(weakest, rotCps(a))
	end
	-- A lower bound: passes and VIP add slots we don't count, which only costs a skipped EquipBest.
	local slots = BASE_SLOTS + ((d.Upgrades or {}).PlotUpgrade or 0)
	return placed, slots, weakest
end

local function reach(d)
	return C.reach and C.reach.GetReach(d.Power or 0) or 5
end

-- world ----------------------------------------------------------------------
local function root()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function hop(cf)
	local r = root()
	if not r then
		return false
	end
	r.AssemblyLinearVelocity = Vector3.zero
	player.Character:PivotTo(cf)
	return true
end

-- InSpawn is the server's own flag (no client script sets it), so it doubles as proof a hop
-- landed where the server can see it.
local function inSpawn()
	return player:GetAttribute("InSpawn") == true
end

local function spawnCF()
	local s = workspace:FindFirstChildWhichIsA("SpawnLocation")
	return s and s.CFrame * CFrame.new(0, 4, 0)
end

-- SeaEdge is a Zone volume; standing IN it is the check, so no lift.
local function edgeCF()
	local e = workspace:FindFirstChild("SeaEdge")
	return e and e:IsA("BasePart") and e.CFrame
end

local function myPlot()
	local plots = workspace:FindFirstChild("Plots")
	for _, p in ipairs(plots and plots:GetChildren() or {}) do
		if p:GetAttribute("Owner") == player.UserId then
			return p
		end
	end
	return nil
end

-- Your plot's TrainingAreaPlaceholder: the server's part under the client's cloned pad. The
-- game's own StartTraining(StandPart) pins you on it, and in the dump Power only moved while
-- pinned there -- so training means standing on it, and home is the pad while it's on.
local function padCF()
	local plot = myPlot()
	local pad = plot and plot:FindFirstChild("TrainingAreaPlaceholder", true)
	if not (pad and pad:IsA("BasePart")) then
		return nil
	end
	return pad.CFrame * CFrame.new(0, pad.Size.Y / 2 + 3, 0)
end

-- The panel's switches. Declared here, above everything that reads them (a trip home ends on
-- the pad while Auto Train is on); the brain below runs whichever are set.
local want = { split = false, train = false, place = false, hatch = false, equip = false, upgrade = false, sell = false }
local padNotSpawn = false
local function toSpawn()
	local pad = want.train and not padNotSpawn and padCF()
	local r = root()
	if inSpawn() and (not pad or (r and (r.Position - pad.Position).Magnitude <= PAD_RANGE)) then
		return true
	end
	if pad and hop(pad) and waitFor(inSpawn, SPAWN_WAIT) then
		return true
	end
	if pad then
		padNotSpawn = true
		log("your training pad isn't inside spawn -- claims go from the spawn point, training re-hops after")
	end
	local cf = spawnCF()
	if not cf or not hop(cf) then
		return false
	end
	return waitFor(inSpawn, SPAWN_WAIT)
end

local function toSea()
	local cf = edgeCF()
	if not cf or not hop(cf) then
		return false
	end
	waitFor(function()
		return not inSpawn()
	end, EDGE_WAIT)
	return true
end

-- The staff is a Tool tagged PickaxeTool; the game equips it at the sea edge before a split.
local function holdStaff()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	for _, t in ipairs(char:GetChildren()) do
		if t:IsA("Tool") and t:HasTag("PickaxeTool") then
			return
		end
	end
	for _, t in ipairs(player.Backpack:GetChildren()) do
		if t:IsA("Tool") and t:HasTag("PickaxeTool") then
			pcall(hum.EquipTool, hum, t)
			return
		end
	end
end

-- income ---------------------------------------------------------------------
-- CashEarned({animalId = amount}) arrives about once a second: the real income, every
-- multiplier included, without recomputing Modifiers.CashMulti.
local income = { samples = {}, conn = nil, since = os.clock() }
function income.rate()
	local now, sum = os.clock(), 0
	local keep = {}
	for _, s in ipairs(income.samples) do
		if now - s[1] <= INCOME_WINDOW then
			sum = sum + s[2]
			table.insert(keep, s)
		end
	end
	income.samples = keep
	return sum / math.max(1, math.min(INCOME_WINDOW, now - income.since))
end
if R.cashEarned then
	income.conn = R.cashEarned.OnClientEvent:Connect(function(map)
		local sum = 0
		for _, v in pairs(type(map) == "table" and map or {}) do
			sum = sum + (tonumber(v) or 0)
		end
		table.insert(income.samples, { os.clock(), sum })
	end)
end

-- split ----------------------------------------------------------------------
local split = {
	gap = SPLIT_GAP_MIN,
	startAt = nil, -- nil until probed, then "here" or "edge"
	waves = 0,
	claimed = 0,
	boss = 0,
	refused = 0,
	missed = 0,
	takeBoss = true,
	last = "-",
}

local function tryStart()
	holdStaff()
	local r = callTimed(R.start, CALL_TIMEOUT, PERFECT)
	local w = r and r[1]
	return type(w) == "table" and w or nil
end

local function openWave()
	if split.startAt == "edge" then
		toSea()
		return tryStart()
	end
	local w = tryStart()
	if w then
		if not split.startAt then
			split.startAt = "here"
			log("probe: Start works from where you stand -- no hop to the sea")
		end
		return w
	end
	if split.startAt == "here" then
		return nil -- proven to work here; this refusal is about something else
	end
	if toSea() then
		w = tryStart()
		if w then
			split.startAt = "edge"
			log("probe: Start wants you at the sea edge -- hopping there each split")
		end
	end
	return w
end

-- rarity ---------------------------------------------------------------------
-- The label the game prints: EggsConfig.rarity on an egg, BrainrotsConfig.rarity on an animal
-- (BrainrotUtils fills in the ones the config leaves blank when it loads). A filter only --
-- inside the ticked set the pick is still by value, since the label alone misprices eggs.
local function rarityOf(e)
	if e.eggType then
		local egg = C.eggs and C.eggs.EGGS[e.eggType]
		return egg and egg.rarity
	end
	local c = e.brainrotType and C.rots and C.rots.CONFIG[e.brainrotType]
	return c and c.rarity
end

-- Dropdown order: by the lowest egg tier wearing each label; animal-only labels last.
local RARITIES = {}
do
	local low = {}
	for _, egg in pairs(C.eggs and C.eggs.EGGS or {}) do
		if egg.rarity then
			low[egg.rarity] = math.min(low[egg.rarity] or math.huge, egg.tier or math.huge)
		end
	end
	for _, c in pairs(C.rots and C.rots.CONFIG or {}) do
		if c.rarity and not low[c.rarity] then
			low[c.rarity] = math.huge
		end
	end
	for r in pairs(low) do
		table.insert(RARITIES, r)
	end
	table.sort(RARITIES, function(a, b)
		if low[a] ~= low[b] then
			return low[a] < low[b]
		end
		return a < b
	end)
end

local wantRarity = {} -- ticked labels; empty means every rarity. Cleared and refilled, never replaced
local function filtering()
	return next(wantRarity) ~= nil
end
local function rarityOk(e)
	return not filtering() or wantRarity[rarityOf(e) or ""] == true
end

local function rankWave(d, wave)
	local picks = {}
	for _, s in pairs(wave.spawns or {}) do
		local e = type(s) == "table" and s.entity
		if e and e.id and (split.takeBoss or not s.isBossItem) and rarityOk(e) then
			table.insert(picks, { id = e.id, e = e, v = worth(d, e), boss = s.isBossItem and s.bossId })
		end
	end
	table.sort(picks, function(a, b)
		return a.v > b.v
	end)
	return picks
end

local function splitOnce(d)
	local carry = math.max(1, (d.Upgrades or {}).Carry or 1)
	if count(d.Inventory) + carry > INV_LIMIT then
		split.last = "inventory full -- place/hatch it down or turn on Auto sell junk"
		return
	end
	step("split / start")
	local wave = openWave()
	if not wave then
		split.refused = split.refused + 1
		split.gap = math.min(SPLIT_GAP_MAX, split.gap * 1.5)
		split.last = ("Start refused (%d) -- backing off to %.1fs"):format(split.refused, split.gap)
		-- End Run: closes a wave the server still has open (a script restarted mid-wave).
		toSpawn()
		callTimed(R.finished, CALL_TIMEOUT, {})
		return
	end
	split.waves = split.waves + 1
	local picks = rankWave(d, wave)
	if split.waves == 1 then
		log(("probe: wave reach=%s time=%s spawns=%d, best %s (%.2f/s)"):format(
			tostring(wave.reach), tostring(wave.time), #picks, picks[1] and describe(picks[1].e) or "-", picks[1] and picks[1].v or 0))
	end
	local ids, names, bosses = {}, {}, 0
	for i = 1, math.min(carry, #picks) do
		ids[i] = picks[i].id
		names[i] = describe(picks[i].e) .. (picks[i].boss and " [" .. picks[i].boss .. "]" or "")
		bosses = bosses + (picks[i].boss and 1 or 0)
	end

	step("split / to spawn")
	if not toSpawn() and split.waves == 1 then
		log("probe: never saw InSpawn after the hop -- claiming anyway")
	end
	step("split / claim")
	local r = callTimed(R.finished, CALL_TIMEOUT, ids)
	if split.waves == 1 then
		log("probe: Finished answered " .. tostring(r and r[1]))
	end
	if #ids == 0 then
		split.last = filtering() and "nothing of your ticked rarities in that wave" or "empty wave"
		return
	end
	local landed = waitFor(function()
		local now = D()
		local inv, placed = now.Inventory or {}, now.PlacedAnimals or {}
		for _, id in ipairs(ids) do
			if inv[id] or placed[id] then
				return true
			end
		end
	end, CLAIM_WAIT)
	if landed then
		split.claimed = split.claimed + #ids
		split.boss = split.boss + bosses
		split.gap = math.max(SPLIT_GAP_MIN, split.gap * 0.8)
		split.last = "claimed " .. table.concat(names, ", ")
	else
		split.missed = split.missed + 1
		split.last = ("claim didn't land (%d) -- %s"):format(split.missed, table.concat(names, ", "))
		if split.missed == 2 then
			warn("[split_sea] two claims in a row didn't reach the inventory -- the server may want the walk. Paste F9.")
		end
	end
end

-- eggs -----------------------------------------------------------------------
local eggs = { placed = 0, hatched = 0, hands = false, parked = {} }

local function parked(id)
	return (eggs.parked[id] or 0) > os.clock()
end

local function hatchReady(d)
	local now = workspace:GetServerTimeNow()
	for id, egg in pairs(d.PlacedEggs or {}) do
		if (egg.startTime or math.huge) + (egg.duration or 0) <= now and not parked(id) then
			step("hatch " .. tostring(egg.type))
			local r = callTimed(R.hatch, CALL_TIMEOUT, id)
			eggs.parked[id] = os.clock() + HATCH_PARK
			if r and r[1] then
				eggs.hatched = eggs.hatched + 1
			end
		end
	end
end

-- MaxEggs is 10, so a 5x2 grid across the plot surface, minus spots an egg already sits on.
local function freeSpots(plot)
	local surf = plot:FindFirstChild("PlotSurface", true)
	if not (surf and surf:IsA("BasePart")) then
		return {}
	end
	local taken = {}
	local folder = plot:FindFirstChild("Eggs", true)
	for _, m in ipairs(folder and folder:GetChildren() or {}) do
		local ok, pv = pcall(m.GetPivot, m)
		if ok then
			table.insert(taken, pv.Position)
		end
	end
	local long = surf.Size.X >= surf.Size.Z
	local spots = {}
	for i = 1, 5 do
		for j = 1, 2 do
			local a, b = ((i - 0.5) / 5 - 0.5) * 0.8, ((j - 0.5) / 2 - 0.5) * 0.8
			local lx = (long and a or b) * surf.Size.X
			local lz = (long and b or a) * surf.Size.Z
			local p = surf.CFrame:PointToWorldSpace(Vector3.new(lx, surf.Size.Y / 2 + EGG_LIFT, lz))
			local clear = true
			for _, t in ipairs(taken) do
				if (Vector3.new(t.X, p.Y, t.Z) - p).Magnitude < SPOT_CLEAR then
					clear = false
					break
				end
			end
			if clear then
				table.insert(spots, p)
			end
		end
	end
	return spots
end

local function eggTool(id)
	for _, where in ipairs({ player.Backpack, player.Character }) do
		for _, t in ipairs(where and where:GetChildren() or {}) do
			if t:IsA("Tool") and t:GetAttribute("EntityId") == id then
				return t
			end
		end
	end
end

-- The game places from the egg Tool's Activated with PlaceEgg(id, pivot). First rung: the
-- remote alone. Second: what the real client does -- the Tool in hand, standing on the spot.
-- Whichever lands first is kept.
local function placeOne(item, spot)
	local cf = CFrame.new(spot) * CFrame.Angles(0, math.pi / 2, 0)
	local function gone()
		return not (D().Inventory or {})[item.key]
	end
	if not eggs.hands then
		callTimed(R.place, CALL_TIMEOUT, item.id, cf)
		if waitFor(gone, PLACE_CONFIRM) then
			return true
		end
	end
	local tool = eggTool(item.id)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if tool and hum then
		pcall(hum.EquipTool, hum, tool)
	end
	hop(cf * CFrame.new(0, 3, 0))
	task.wait(0.2)
	callTimed(R.place, CALL_TIMEOUT, item.id, cf)
	local ok = waitFor(gone, PLACE_CONFIRM)
	if ok and not eggs.hands then
		eggs.hands = true
		log("probe: PlaceEgg wants the egg in hand on the spot -- doing that from now on")
	end
	return ok
end

local function placeEggs(d)
	local free = MAX_EGGS - count(d.PlacedEggs)
	if free <= 0 then
		return
	end
	local list = inventoryEggs(d)
	if #list == 0 then
		return
	end
	local plot = myPlot()
	local spots = plot and freeSpots(plot) or {}
	local n = 0
	for _, item in ipairs(list) do
		if n >= math.min(free, #spots) then
			break
		end
		if not parked(item.key) then
			n = n + 1
			step("place " .. describe(item.e))
			if placeOne(item, spots[n]) then
				eggs.placed = eggs.placed + 1
			else
				eggs.parked[item.key] = os.clock() + 30
			end
		end
	end
	toSpawn()
end

-- equip / sell ---------------------------------------------------------------
local extra = { equips = 0, sold = 0 }

local function equipWanted(d)
	local placed, slots, weakest = plotStats(d)
	for _, it in pairs(d.Inventory or {}) do
		if it.itemType == "Brainrot" and it.innerEntity then
			if placed < slots or rotCps(it.innerEntity) > weakest then
				return true
			end
		end
	end
	return false
end

local function equipBest(d)
	if equipWanted(d) then
		step("equip best")
		callTimed(R.equipBest, CALL_TIMEOUT)
		extra.equips = extra.equips + 1
	end
end

-- One sale, confirmed by the item leaving the inventory. The first of each kind prints the
-- server's answer, so a refusal says why instead of looking like "nothing happens".
local sellProbe = {}
local function sellOne(kind, remoteFn, key, arg, label)
	step("sell " .. label)
	local res = callTimed(remoteFn, CALL_TIMEOUT, arg)
	local ok = waitFor(function()
		return not (D().Inventory or {})[key]
	end, SELL_CONFIRM)
	if not sellProbe[kind] then
		sellProbe[kind] = true
		log(("probe: %s(%s) answered %s, %s -- %s"):format(remoteFn and remoteFn.Name or "missing remote",
			label, tostring(res and res[1]), tostring(res and res[2]), ok and "sold" or "still in inventory"))
	end
	if ok then
		extra.sold = extra.sold + 1
	else
		extra.sellFails = (extra.sellFails or 0) + 1
	end
	return ok
end

-- Irreversible, so narrow: eggs outside your EGG_KEEP best, and animals worse than the weakest
-- on a full plot (EquipBest has had its chance first). No fullness gate -- junk goes when seen.
-- An egg of a rarity you're farming is never junk, whatever it scores.
local function sellJunk(d)
	local budget = SELL_BATCH
	local list = inventoryEggs(d)
	for i = #list, EGG_KEEP + 1, -1 do
		if budget <= 0 then
			return
		end
		if not (filtering() and rarityOk(list[i].e)) then
			budget = budget - 1
			sellOne("egg", R.sellEgg, list[i].key, list[i].key, describe(list[i].e))
		end
	end
	local placed, slots, weakest = plotStats(d)
	if placed < slots then
		extra.sellNote = ("plot %d/%d -- animals go to Equip Best, not sold"):format(placed, slots)
		return
	end
	extra.sellNote = ("selling animals under %s/s"):format(money(weakest))
	for key, it in pairs(d.Inventory or {}) do
		if budget <= 0 then
			return
		end
		local e = it.innerEntity
		if it.itemType == "Brainrot" and e and rotCps(e) < weakest then
			budget = budget - 1
			sellOne("animal", R.sellRot, key, e.id or key, describe(e))
		end
	end
end

-- upgrades / rebirth ---------------------------------------------------------
local up = { speed = false, bought = 0, next = "-" }
local rb = { at = 1, done = 0 }

-- Staffs and dumbbells the shop sells for cash: a cost, and not a pass/event/secret one.
local function forSale(v)
	return type(v.cost) == "number" and v.cost > 0 and not v.isSpecial and not v.passRequired and not v.hideIfNotOwned
end

-- The upgrade station's own rule: the cheapest one that beats the best you own.
local function nextBetter(list, owned, stat)
	local best = 0
	for key in pairs(owned or {}) do
		local v = list[key]
		if v and (v[stat] or 0) > best then
			best = v[stat]
		end
	end
	local pick
	for key, v in pairs(list or {}) do
		if forSale(v) and not (owned or {})[key] and (v[stat] or 0) > best and (not pick or v.cost < pick.cost) then
			pick = { key = key, cost = v.cost, name = v.name or key }
		end
	end
	return pick
end

local function nextRebirth(d)
	local nxt = C.rebirth and C.rebirth.REBIRTH[(d.Rebirth or 0) + 1]
	if not nxt then
		return nil
	end
	local need = 0
	for cur, amount in pairs(nxt.Cost or {}) do
		local have = (d.Currencies or {})[cur] or 0
		if cur == "Cash" then
			need = amount
		elseif have < amount then
			return nxt, math.huge
		end
	end
	return nxt, need
end

local function saving(d)
	if not rb.on then
		return false
	end
	local nxt, need = nextRebirth(d)
	if not nxt or need == math.huge then
		return false
	end
	local short = need * rb.at - cash(d)
	local rate = income.rate()
	return short > 0 and rate > 0 and short / rate < SAVE_HORIZON
end

local function upgradeCandidates(d)
	local list = {}
	local levels = d.Upgrades or {}
	local placed, slots = plotStats(d)
	local function add(label, cost, weight, buy, done)
		if cost and cost > 0 and cost < math.huge then
			table.insert(list, { label = label, cost = cost, score = cost / weight, buy = buy, done = done })
		end
	end
	for _, id in ipairs({ "Carry", "PlotUpgrade", "MovementSpeed" }) do
		if C.up and (id ~= "MovementSpeed" or up.speed) then
			local lvl = levels[id] or 0
			local weight = WEIGHT[id]
			if id == "PlotUpgrade" and placed >= slots then
				weight = WEIGHT.PlotUpgradeFull
			end
			add(id, C.up.GetPrice(id, lvl + 1), weight, function()
				return callTimed(R.upgrade, CALL_TIMEOUT, id, 1)
			end, function()
				return ((D().Upgrades or {})[id] or 0) > lvl
			end)
		end
	end
	local staff = C.staff and nextBetter(C.staff, d.OwnedPickaxes, "luck")
	if staff then
		add("staff " .. staff.name, staff.cost, WEIGHT.staff, function()
			return callTimed(R.buyStaff, CALL_TIMEOUT, staff.key)
		end, function()
			return (D().OwnedPickaxes or {})[staff.key]
		end)
	end
	local tool = C.tools and nextBetter(C.tools.TRAIN_TOOLS, d.OwnedTrainTools, "gainPerTrain")
	if tool then
		add("dumbbell " .. tool.name, tool.cost, WEIGHT.tool, function()
			return callTimed(R.buyTool, CALL_TIMEOUT, tool.key)
		end, function()
			return (D().OwnedTrainTools or {})[tool.key]
		end)
	end
	table.sort(list, function(a, b)
		return a.score < b.score
	end)
	return list
end

-- Only the top-ranked upgrade is ever bought: a cheaper, weaker one bought while saving for
-- it is exactly the wasted currency this is meant to avoid.
local function upgradeOnce(d)
	local top = upgradeCandidates(d)[1]
	if not top then
		up.next = "everything bought"
		return
	end
	up.next = ("%s %s"):format(top.label, money(top.cost))
	if saving(d) then
		up.next = up.next .. " (saving for rebirth)"
		return
	end
	if cash(d) < top.cost then
		return
	end
	step("upgrade " .. top.label)
	top.buy()
	if waitFor(top.done, UPGRADE_CONFIRM) then
		up.bought = up.bought + 1
		say("bought " .. top.label)
	end
end

local function rebirthOnce(d)
	local nxt, need = nextRebirth(d)
	if not nxt or need == math.huge or cash(d) < need * rb.at then
		return
	end
	local before = d.Rebirth or 0
	step("rebirth")
	callTimed(R.rebirth, CALL_TIMEOUT)
	if waitFor(function()
		return (D().Rebirth or 0) > before
	end, UPGRADE_CONFIRM) then
		rb.done = rb.done + 1
		log(("rebirth %d -> x%s cash"):format(before + 1, tostring(nxt.CashMulti)))
	end
end

-- training -------------------------------------------------------------------
-- Server state, so this is a switch plus a re-arm, not a loop of presses. IsTraining is the
-- server's flag on the Player (the dump: Players.<you> IsTraining -> true right after
-- StartTraining); the character copy is the fallback other clients see.
local train = { arms = 0, bonuses = 0, conn = nil, power = nil, powerAt = os.clock(), warned = false }

local function training()
	local c = player.Character
	return player:GetAttribute("IsTraining") == true or (c ~= nil and c:GetAttribute("IsTraining") == true)
end

local function trainTick(d)
	local r = root()
	if not r then
		return
	end
	local pad = padCF()
	if pad and (r.Position - pad.Position).Magnitude > PAD_RANGE then
		step("train / to pad")
		hop(pad)
		task.wait(PAD_SETTLE)
	end
	local power = d.Power or 0
	if not training() then
		step("train / start")
		local res = callTimed(R.train, CALL_TIMEOUT)
		train.arms = train.arms + 1
		train.power, train.powerAt = power, os.clock()
		if train.arms == 1 then
			log(("probe: StartTraining answered %s, pad %s"):format(tostring(res and res[1]), pad and "found" or "NOT found"))
		end
		return
	end
	if power ~= train.power then
		train.power, train.powerAt, train.warned = power, os.clock(), false
	elseif os.clock() - train.powerAt > TRAIN_STALL and not train.warned then
		train.warned = true
		warn(("[split_sea] training for %ds with Power stuck at %s%s"):format(TRAIN_STALL, money(power),
			want.split and split.startAt == "edge" and " -- each split hops you off the pad; try Auto Train alone" or ""))
	end
end

-- The x2 button on the Power counter: the server announces a bonus id on SpawnBonus and
-- ClaimBonus(id) pays it. The game only draws the button while ITS controller trains you, so
-- remote training never shows it -- claim by id instead, whoever started the training. The
-- dump's hand-claims landed 0.9-2.2s after the spawn, so an early refusal is retried on a
-- short beat rather than written off; the first answer goes to F9.
local function claimBonus(id)
	local deadline = os.clock() + BONUS_WINDOW
	repeat
		local r = callTimed(R.claimBonus, CALL_TIMEOUT, id)
		if not train.bonusProbe then
			train.bonusProbe = true
			log(("probe: ClaimBonus answered %s, %s"):format(tostring(r and r[1]), tostring(r and r[2])))
		end
		if r and r[1] then
			train.bonuses = train.bonuses + 1
			return
		end
		task.wait(BONUS_RETRY)
	until os.clock() > deadline
	train.bonusMissed = (train.bonusMissed or 0) + 1
end

local function setBonus(on)
	if train.conn then
		pcall(train.conn.Disconnect, train.conn)
		train.conn = nil
	end
	if on and R.spawnBonus then
		train.conn = R.spawnBonus.OnClientEvent:Connect(function(id)
			task.spawn(claimBonus, id)
		end)
	end
end

-- brain ----------------------------------------------------------------------
-- One thread, one beat. Each step runs on its own clock, in priority order: free the plot
-- (hatch, place, equip, sell) before spending, spend before splitting, split last because
-- it is the slow one. Everything that moves you lives in here, so nothing fights over the
-- character.
rb.on = false
local due = {}
local function every(name, gap)
	local now = os.clock()
	if (due[name] or 0) > now then
		return false
	end
	due[name] = now + gap
	return true
end

local lastErr = {}
local function run(name, fn, d)
	local ok, err = pcall(fn, d)
	if not ok and os.clock() - (lastErr[name] or 0) > 5 then
		lastErr[name] = os.clock()
		warn(("[split_sea] %s: %s"):format(name, tostring(err)))
	end
end

local brain = { on = false, gen = 0, inBody = false }
function brain.set(on)
	brain.on = on
	brain.gen = brain.gen + 1
	if not on then
		return
	end
	local mine = brain.gen
	task.spawn(function()
		while brain.on and brain.gen == mine do
			local d = D()
			if not d then
				say("waiting for your save data...")
				task.wait(1)
				continue
			end
			brain.inBody = true
			if want.hatch and every("hatch", HATCH_GAP) then
				run("hatch", hatchReady, d)
			end
			if want.place and every("place", PLACE_GAP) then
				run("place", placeEggs, d)
			end
			if want.equip and every("equip", EQUIP_GAP) then
				run("equip", equipBest, d)
			end
			if want.sell and every("sell", SELL_GAP) then
				run("sell", sellJunk, d)
			end
			if rb.on and every("rebirth", REBIRTH_GAP) then
				run("rebirth", rebirthOnce, d)
			end
			if want.upgrade and every("upgrade", UPGRADE_GAP) then
				run("upgrade", upgradeOnce, d)
			end
			if want.train and every("train", TRAIN_GAP) then
				run("train", trainTick, d)
			end
			if want.split and every("split", split.gap) then
				run("split", splitOnce, d)
			end
			brain.inBody = false
			step("idle")
			task.wait(TICK)
		end
	end)
end

local function rethink()
	local any = rb.on
	for _, on in pairs(want) do
		any = any or on
	end
	if any ~= brain.on then
		brain.set(any)
	end
end

-- anti-afk -------------------------------------------------------------------
-- The nudge stops the idle kick (VirtualUser, plus VirtualInputManager for clients that
-- ignore it); the rejoin covers what a nudge can't. CoreGui connections teardown can't reach,
-- so every handler checks afk.on.
local afk = { on = false, gen = 0, conns = {} }
function afk.nudge()
	pcall(function()
		local vu = game:GetService("VirtualUser")
		vu:CaptureController()
		vu:ClickButton2(Vector2.new())
	end)
	pcall(function()
		local vim = game:GetService("VirtualInputManager")
		vim:SendMouseButtonEvent(0, 0, 1, true, game, 0)
		vim:SendMouseButtonEvent(0, 0, 1, false, game, 0)
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
					warn("[split_sea] disconnected -- rejoining in " .. REJOIN_DELAY .. "s")
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
	dogGen = dogGen + 1
	local mine = dogGen
	task.spawn(function()
		while dogGen == mine do
			if brain.on and brain.inBody and os.clock() - markAt > WATCHDOG then
				warn(("[split_sea] stuck %ds at: %s"):format(math.floor(os.clock() - markAt), mark))
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
	game = "Split Sea for Animals", -- fallback until the live name lands
	folder = "SplitSeaForAnimals", -- never rename: saved configs orphan
	size = UDim2.fromOffset(540, 440),
})
if not Window then
	if income.conn then
		income.conn:Disconnect()
	end
	return -- panel.lua already said why
end

-- WindUI hands a Multi dropdown a list, a map or the row tables depending on the build;
-- normalise into a set we own.
local function ticked(v)
	local set = {}
	for k, val in pairs(type(v) == "table" and v or {}) do
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

local function toggle(sec, title, desc, key)
	sec:Toggle({
		Title = title,
		Desc = desc,
		Value = false,
		Callback = function(on)
			want[key] = on
			rethink()
		end,
	})
end

do
	local Main = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })

	local Sea = Main:Section({ Title = "Sea", Icon = "solar:water-bold", Box = true, BoxBorder = true, Opened = true })
	toggle(Sea, "Auto Split Sea", "Perfect every time; the best <Carry> items of each wave claimed by id -- no walking", "split")
	Sea:Toggle({
		Title = "Take boss items",
		Desc = "The purple doors' eggs. The chase is client-side, so claiming by id is never chased",
		Value = split.takeBoss,
		Callback = function(on)
			split.takeBoss = on
		end,
	})
	Sea:Dropdown({
		Title = "Only take these rarities",
		Desc = "Empty = everything. Among the ticked ones the most valuable still goes first; auto sell spares them",
		Values = RARITIES,
		Multi = true,
		AllowNone = true,
		Value = {},
		Callback = function(v)
			table.clear(wantRarity)
			for name in pairs(ticked(v)) do
				if table.find(RARITIES, name) then
					wantRarity[name] = true
				end
			end
		end,
	})
	Sea:Toggle({
		Title = "Auto Train",
		Desc = "Stands you on your training pad and keeps the server training you",
		Value = false,
		Callback = function(on)
			want.train = on
			if not on then
				task.spawn(callTimed, R.untrain, CALL_TIMEOUT) -- server state: off means off
			end
			rethink()
		end,
	})
	Sea:Toggle({
		Title = "Auto x2 bonus",
		Desc = "Claims every x2 Power bonus the moment it spawns -- works when you train by hand too",
		Value = true,
		Callback = function(on)
			setBonus(on)
		end,
	})

	local Farm = Main:Section({ Title = "Plot", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })
	toggle(Farm, "Auto Place Eggs", "Best eggs first, onto free plot spots (10 max)", "place")
	toggle(Farm, "Auto Hatch", "The moment each timer ends -- never the Robux skip", "hatch")
	toggle(Farm, "Auto Equip Best", "The server's own Equip Best, when your inventory beats your plot", "equip")
	toggle(Farm, "Auto sell junk", "Eggs outside your 30 best, animals weaker than anything on your full plot", "sell")

	local Grow = Main:Section({ Title = "Progress", Icon = "solar:bolt-circle-bold", Box = true, BoxBorder = true, Opened = true })
	toggle(Grow, "Auto Upgrade", "Carry, plot slots, staffs, dumbbells -- the best cost per weight, one at a time", "upgrade")
	Grow:Toggle({
		Title = "Include Speed upgrades",
		Desc = "Off: nothing here walks, so speed is wasted cash",
		Value = up.speed,
		Callback = function(on)
			up.speed = on
		end,
	})
	Grow:Toggle({
		Title = "Auto Rebirth",
		Desc = "As soon as cash covers it; upgrades hold back while it's close",
		Value = false,
		Callback = function(on)
			rb.on = on
			rethink()
		end,
	})
	Grow:Input({
		Title = "Rebirth at x cost",
		Desc = "Rebirth once cash is this many times the price (1 = as soon as affordable)",
		Value = tostring(rb.at),
		Placeholder = "1",
		Callback = function(v)
			local n = tonumber(v)
			if n and n >= 1 then
				rb.at = n
			end
		end,
	})
	Grow:Toggle({
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
local statsSec = Stats:Section({ Title = "Dashboard", Icon = "solar:chart-2-bold", Box = true, BoxBorder = true, Opened = true })
local status = statsSec:Paragraph({ Title = "Status", Desc = "idle" })
local ROWS = { "Sea", "Bosses", "Eggs", "Plot", "Progress", "Session" }
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
	Sea = function(d)
		local only = {}
		for _, r in ipairs(RARITIES) do
			if wantRarity[r] then
				table.insert(only, r)
			end
		end
		return ("splits %d   claimed %d (boss %d)   refused %d   gap %.1fs   start %s\ntaking: %s\nlast: %s"):format(
			split.waves, split.claimed, split.boss, split.refused, split.gap, split.startAt or "unprobed",
			#only > 0 and table.concat(only, ", ") or "every rarity", split.last)
	end,
	Bosses = function(d)
		local r, out = reach(d), {}
		local names = {}
		for id, b in pairs(C.boss or {}) do
			if not b.isEventBoss then
				table.insert(names, id)
			end
		end
		table.sort(names)
		for _, id in ipairs(names) do
			local b = C.boss[id]
			local cd = ((d.BossCooldowns or {})[id] or 0) - os.time()
			local state = r < b.wavePart and ("needs reach %d"):format(b.wavePart) or cd > 0 and ("%ds"):format(cd) or "ready"
			table.insert(out, id .. " " .. state)
		end
		return ("reach %d\n%s"):format(r, table.concat(out, "   "))
	end,
	Eggs = function(d)
		local list = inventoryEggs(d)
		local soonest = math.huge
		local now = workspace:GetServerTimeNow()
		for _, egg in pairs(d.PlacedEggs or {}) do
			soonest = math.min(soonest, (egg.startTime or 0) + (egg.duration or 0) - now)
		end
		return ("inventory %d eggs, best %s   placed %d/%d   next hatch %s\nplaced %d   hatched %d%s"):format(
			#list, list[1] and ("%s %.1f/s"):format(describe(list[1].e), list[1].v) or "-",
			count(d.PlacedEggs), MAX_EGGS, soonest == math.huge and "-" or ("%ds"):format(math.max(0, math.ceil(soonest))),
			eggs.placed, eggs.hatched, eggs.hands and "   (placing by hand)" or "")
	end,
	Plot = function(d)
		local placed, slots, weakest = plotStats(d)
		return ("animals %d/%d+   income %s/s   weakest %s/s base\ninventory %d/%d   equip-best calls %d   sold %d (refused %d)\n%s"):format(
			placed, slots, money(income.rate()), weakest == math.huge and "-" or money(weakest),
			count(d.Inventory), INV_LIMIT, extra.equips, extra.sold, extra.sellFails or 0, extra.sellNote or "")
	end,
	Progress = function(d)
		local nxt, need = nextRebirth(d)
		local lv = d.Upgrades or {}
		return ("cash %s   power %s   carry %d   plot +%d   rebirth %d (next %s)\nstaff %s   dumbbell %s   next buy %s"):format(
			money(cash(d)), money(d.Power or 0), lv.Carry or 1, lv.PlotUpgrade or 0, d.Rebirth or 0,
			nxt and (need == math.huge and "needs another currency" or money(need)) or "max",
			tostring(d.EquippedPickaxe), tostring(d.EquippedTrainTool), up.next)
	end,
	Session = function()
		local on = {}
		for k, v in pairs(want) do
			if v then
				table.insert(on, k)
			end
		end
		if rb.on then
			table.insert(on, "rebirth")
		end
		table.sort(on)
		return ("upgrades %d   rebirths %d   training re-arms %d   x2 bonuses %d (missed %d)\nrunning: %s   at: %s"):format(
			up.bought, rb.done, train.arms, train.bonuses, train.bonusMissed or 0,
			#on > 0 and table.concat(on, ", ") or "nothing", mark)
	end,
}

local dashGen = 0
local function startDash()
	dashGen = dashGen + 1
	local mine = dashGen
	task.spawn(function()
		while dashGen == mine do
			local d = D()
			for title, build in pairs(builders) do
				if d then
					local ok, text = pcall(build, d)
					dashText[title] = ok and text or ("unreadable: " .. tostring(text))
				end
			end
			task.wait(DASH_GAP)
		end
	end)
end

-- A starting Value = true doesn't fire the callback; arm it by hand.
afk.set(true)
setBonus(true)
startDog()
startDash()
say(D() and "ready" or "ready -- save data not read yet, retrying")

-- close ----------------------------------------------------------------------
local function stopAll()
	for k in pairs(want) do
		want[k] = false
	end
	rb.on = false
	brain.set(false)
	dogGen = dogGen + 1
	dashGen = dashGen + 1
	setBonus(false)
	task.spawn(callTimed, R.untrain, CALL_TIMEOUT) -- server state: a closed panel must not keep training
	afk.set(false) -- a stopped script must not rejoin you
	pcall(drain.Disconnect, drain)
	if income.conn then
		pcall(income.conn.Disconnect, income.conn)
	end
end

Window:OnDestroy(function()
	stopAll()
	getgenv().splitSeaStop = nil
end)

getgenv().splitSeaStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().splitSeaStop = nil
end
