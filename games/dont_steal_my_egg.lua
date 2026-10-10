--[[ Don't Steal My Egg -- race for eggs, place, hatch, equip, sell, train, upgrade, rebirth, change world (135675416428111)

     RACE    : the game's chase is client-simulated and the server only checks your Speed, so a lap is the
               four CombatService calls the client sends (Start, BeginRound, WakeUp, Caught) with no chase in
               between. ~1s per boss instead of ~8s. Chain: boss1, boss2, ... until the server's own
               fleeSpeedMultiplier goes above 1 (that boss is faster than your Speed, Caught comes back nil).
               Finish + ClaimRunEgg pays the egg of the last boss caught; PlotService:TeleportToPlot brings you
               home. Probed at Speed 7484: boss1-3 caught, boss4 (needs 10000) refused.
     PLACE   : EggService:PlaceEgg(EntityId, CFrame) on your PlotSurface, best egg first, up to the game's
               MaxEggs. Any spot on the surface is accepted; stacked eggs too (probed).
     HATCH   : EggService:HatchEgg(EggId) the moment the timer is up; early is refused (probed).
     EQUIP   : AnimalService:EquipBest (probed: re-placed a picked-up animal).
     SELL    : InventoryService:SellBrainrot on every unlocked, non-special animal left in the bag after an
               EquipBest (probed: +cash, animal gone).
     TRAIN   : the game's own TrainingController:StartTraining(standPart): pins you on the treadmill inside your
               plot and the server pays Speed (probed: 691 -> 1878 in 15s with the golden treadmill, 3 ticks/s).
               It stops for every lap and starts again by itself.
     TREADMILL: TrainingService:BuyTrainTool, best affordable non-pass treadmill (a buy equips it; probed).
     PEN     : UpgradesService:Upgrade("PlotUpgrade", n): +1 animal slot, +2 egg slots per level (probed 0 -> 1).
               It goes before a treadmill when both are affordable.
     WORLD   : BiomeService:ChangeBiome to the highest unlocked world. A world unlocks when a lap catches the
               last boss of the one before (boss7 asks for 1.25M Speed), so Race + Train do the "kill the boss".
               Probed: the lap returned state BIOME_FINISH on boss7, desert unlocked, ChangeBiome took it.
     REBIRTH : RebirthService:Rebirth when Cash covers the next step. Probed 0 -> 3: it keeps Speed, treadmills,
               pen, animals and worlds; only the multiplier changes.

     Equip cooldown: the server refuses any equip within ~5s of the last ("Please wait a little bit (3s) before
     equipping again!"), so every equip goes through one 6s gate and the Equip loop only calls with an animal in the bag.
     A lap in a world whose first boss outruns you catches nothing and claims nothing (harmless, just wasted).

     Probed and dead: EggService.SetAutoHatch / SetAutoSell answer false (paid), InitSkip and the rebirth skip are
     Robux products, none of them is wired.
     Movement: nothing here teleports. The server moves you for a lap (Start) and PlotService:TeleportToPlot
     brings you home; the treadmill pin is the game's own controller. Dossier rates teleports KICK-WEIGHTED.

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().dontStealEggStop() ]]

-- config ---------------------------------------------------------------------
local LAP_GAP = 0.3 -- pause between the race calls; probed clean at 0.3, lower and Caught may come back nil
local RACE_EVERY = 0.5 -- the race loop's beat
local EGG_BUFFER = 40 -- no new lap while this many eggs wait unplaced in the bag; lower trains more, raise banks eggs
local LAP_REST = 8 -- with Auto Train on, the treadmill gets this long after every lap; raise for Speed, lower for eggs
local PLACE_EVERY = 0.5
local PLACE_GAP = 0.25 -- between two PlaceEgg calls in one pass
local HATCH_EVERY = 0.5
local HATCH_SLACK = 0.15 -- hatch this long after the timer ends (clock skew); an early HatchEgg is refused
local HATCH_RETRY = 4 -- an egg we asked to hatch is not asked again for this long (the reveal runs 3s)
local EQUIP_EVERY = 6
local SELL_EVERY = 4
local SELL_GAP = 0.15
local EQUIP_GAP = 6 -- the server answers "Please wait a little bit (3s) before equipping again!" to an equip within ~5s of the last
local SETTLE = 0.8 -- after stopping the treadmill: StartTraining ignores calls within 0.7s of a stop
local TRAIN_EVERY = 1
local SPEND_EVERY = 2 -- treadmill and pen
local SPEND_BACKOFF = 10 -- a purchase the server did not take is not retried for this long
local WORLD_EVERY = 3
local REBIRTH_EVERY = 3
local WATCHDOG = 30 -- a loop whose step mark stops moving this long is reported

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local player = Players.LocalPlayer

if getgenv and getgenv().dontStealEggStop then
	getgenv().dontStealEggStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[egg]", ...)
end

local seen = {}
local function first(name, ...)
	if not seen[name] then
		seen[name] = true
		log("first", name, ...)
	end
end

-- The strip is drained from a Heartbeat (our own identity); a loop thread writing to the window
-- throws "lacking capability Plugin" after its first task.wait.
local note, lastSaid = "idle", nil
local function say(msg)
	note = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- game -----------------------------------------------------------------------
local ok, Knit, Modifiers, EggUtils, PlotUtils, EggsConfig, TrainToolConfig, RebirthConfig, UpgradeConfig, BiomeConfig, BrainrotsConfig = pcall(function()
	local RS = ReplicatedStorage
	return require(RS.Packages.Knit),
		require(RS.Modifiers),
		require(RS.GameShared.EggUtils),
		require(RS.GameShared.PlotUtils),
		require(RS.Configs.EggsConfig),
		require(RS.Configs.TrainToolConfig),
		require(RS.Configs.RebirthConfig),
		require(RS.Configs.UpgradeConfig),
		require(RS.Configs.BiomeConfig),
		require(RS.Configs.BrainrotsConfig)
end)
if not ok then
	warn("[egg] the game's modules did not load:", Knit)
	return
end
pcall(function()
	Knit.OnStart():await()
end)

local okS, Combat, Eggs, Animal, Inventory, Training, Upgrades, Rebirth, Biome, Plot, Replica, TC = pcall(function()
	return Knit.GetService("CombatService"),
		Knit.GetService("EggService"),
		Knit.GetService("AnimalService"),
		Knit.GetService("InventoryService"),
		Knit.GetService("TrainingService"),
		Knit.GetService("UpgradesService"),
		Knit.GetService("RebirthService"),
		Knit.GetService("BiomeService"),
		Knit.GetService("PlotService"),
		Knit.GetController("ReplicaController"),
		Knit.GetController("TrainingController")
end)
if not okS then
	warn("[egg] the game's services did not load:", Combat)
	return
end

local function data()
	return Replica:GetPlayerData()
end

local function cash()
	local d = data()
	return d and d.Currencies and d.Currencies.Cash or 0
end

local function now()
	return workspace:GetServerTimeNow()
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

local stats = { laps = 0, caught = 0, placed = 0, hatched = 0, sold = 0, tools = 0, pen = 0, worlds = 0, rebirths = 0 }
local bestBoss = "-"

-- breadcrumbs: every loop marks its step, a watchdog names the one that stopped moving
local marks = {}
local function step(loop, what)
	marks[loop] = { what, os.clock() }
end

-- loops ----------------------------------------------------------------------
-- One generation counter per toggle: off-then-on inside one interval must not leave the old thread alive.
local loops = {}
local function makeLoop(name, every, pass)
	local L = { on = false, gen = 0 }
	function L.set(state)
		L.on = state
		L.gen += 1
		if not state then
			marks[name] = nil
			return
		end
		local mine = L.gen
		task.spawn(function()
			while L.on and L.gen == mine do
				step(name, "pass")
				local okPass, err = pcall(pass, function()
					return L.on and L.gen == mine
				end)
				if not okPass then
					warn("[egg]", name, "pass threw:", err)
				end
				task.wait(every)
			end
		end)
	end
	loops[name] = L
	return L
end

-- The character belongs to one body at a time: a lap, a world change and the treadmill start all move it.
-- Returns whether fn ran, not whether it worked; released on every path including a throw.
local busy = false
local function claim(fn)
	if busy then
		return false
	end
	busy = true
	local okRun, err = pcall(fn)
	busy = false
	if not okRun then
		warn("[egg] claimed body threw:", err)
	end
	return true
end

local function alive()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum and hum.Health > 0 and char:FindFirstChild("HumanoidRootPart") ~= nil
end

-- eggs -----------------------------------------------------------------------
local function bagEggs()
	local out = {}
	local d = data()
	for id, it in pairs(d and d.Inventory or {}) do
		if it.itemType == "Egg" and it.innerEntity then
			local e = it.innerEntity
			local cfg = EggsConfig.EGGS[e.eggType]
			out[#out + 1] = { id = id, type = e.eggType, size = e.size, mutation = e.mutation, tier = cfg and cfg.tier or 0 }
		end
	end
	table.sort(out, function(a, b)
		if a.tier ~= b.tier then
			return a.tier > b.tier
		end
		return (a.size == "big" and 1 or 0) > (b.size == "big" and 1 or 0)
	end)
	return out
end

local function placedEggs()
	local out = {}
	for _, e in ipairs(CollectionService:GetTagged("PlacedEgg")) do
		if e:GetAttribute("OwnerId") == player.UserId then
			out[#out + 1] = e
		end
	end
	return out
end

local function plotSurface()
	local plot = PlotUtils.GetPlayerPlot(player)
	return plot and plot:FindFirstChild("PlotSurface", true)
end

-- a 5 x 4 grid over the surface; the first spot with no egg on it, else the first (stacking is accepted)
local COLS, ROWS, STEP = 5, 4, 10
local function spotCF(surf, taken)
	local pick = 0
	for i = 0, COLS * ROWS - 1 do
		local cf = surf.CFrame * CFrame.new((i % COLS - (COLS - 1) / 2) * STEP, surf.Size.Y / 2, (i // COLS - (ROWS - 1) / 2) * STEP)
		local free = true
		for _, p in ipairs(taken) do
			if (Vector3.new(p.X, 0, p.Z) - Vector3.new(cf.Position.X, 0, cf.Position.Z)).Magnitude < STEP / 2 then
				free = false
				break
			end
		end
		if free then
			pick = i
			break
		end
	end
	return surf.CFrame * CFrame.new((pick % COLS - (COLS - 1) / 2) * STEP, surf.Size.Y / 2, (pick // COLS - (ROWS - 1) / 2) * STEP) * CFrame.Angles(0, math.rad(90), 0)
end

makeLoop("place", PLACE_EVERY, function(isOn)
	local bag = bagEggs()
	if #bag == 0 then
		return
	end
	local surf = plotSurface()
	if not surf then
		say("place: plot surface not found")
		return
	end
	local mine = placedEggs()
	local cap = Modifiers.Get(player, "MaxEggs") or 20
	local taken = {}
	for _, e in ipairs(mine) do
		taken[#taken + 1] = e:GetPivot().Position
	end
	for _, egg in ipairs(bag) do
		if not isOn() or #mine >= cap then
			break
		end
		step("place", "place " .. egg.type)
		local model = EggUtils.CreateEggModel(egg.type, egg.mutation, egg.size)
		local cf = EggUtils.GetValidEggCFrame(surf, model, spotCF(surf, taken))
		model:Destroy()
		local placed = Eggs:PlaceEgg(egg.id, cf)
		if placed then
			stats.placed += 1
			mine[#mine + 1] = true
			taken[#taken + 1] = cf.Position
			first("place", egg.type, egg.size)
		else
			first("place-refused", egg.type, egg.size, #mine, cap)
			break
		end
		task.wait(PLACE_GAP)
	end
end)

local hatchAsked = {}
makeLoop("hatch", HATCH_EVERY, function(isOn)
	local t = now()
	for _, e in ipairs(placedEggs()) do
		local id = e:GetAttribute("EggId")
		local start, dur = e:GetAttribute("StartTime"), e:GetAttribute("Duration")
		if id and start and dur and start + dur + HATCH_SLACK <= t and (hatchAsked[id] or 0) + HATCH_RETRY <= os.clock() then
			if not isOn() then
				return
			end
			step("hatch", "hatch " .. tostring(e:GetAttribute("EggType")))
			hatchAsked[id] = os.clock()
			if Eggs:HatchEgg(id) then
				stats.hatched += 1
				first("hatch", e:GetAttribute("EggType"))
			else
				first("hatch-refused", e:GetAttribute("EggType"), start + dur - t)
			end
			task.wait(0.1)
		end
	end
end)

-- animals --------------------------------------------------------------------
local function bagAnimals()
	local out = {}
	local d = data()
	for id, it in pairs(d and d.Inventory or {}) do
		if it.itemType == "Brainrot" and it.innerEntity and not it.innerEntity.locked then
			local cfg = BrainrotsConfig.CONFIG[it.innerEntity.brainrotType]
			if cfg and not cfg.specialMulti then -- the game asks before selling a special one; so do we: never
				out[#out + 1] = id
			end
		end
	end
	return out
end

-- Every equip (animals and treadmills, from any loop) goes through one gate; nothing yields between the check
-- and the stamp, so two loops cannot both slip through the same window.
local lastEquip = 0
local function equipGate()
	while os.clock() < lastEquip + EQUIP_GAP do
		task.wait(0.1)
	end
	lastEquip = os.clock()
end

local function equipBest()
	step("equip", "EquipBest")
	equipGate()
	Animal:EquipBest()
end

-- Nothing to equip unless an animal is sitting in the bag: skips the "already equipped" toast and most
-- collisions with the server's own equip on the way home.
makeLoop("equip", EQUIP_EVERY, function()
	local d = data()
	for _, it in pairs(d and d.Inventory or {}) do
		if it.itemType == "Brainrot" then
			equipBest()
			return
		end
	end
end)

makeLoop("sell", SELL_EVERY, function(isOn)
	if #bagAnimals() == 0 then
		return
	end
	equipBest() -- the best go to the slots first; what is left in the bag is the junk
	task.wait(1)
	for _, id in ipairs(bagAnimals()) do
		if not isOn() then
			return
		end
		step("sell", "sell " .. id)
		Inventory:SellBrainrot(id)
		stats.sold += 1
		first("sell", id)
		task.wait(SELL_GAP)
	end
end)

-- race -----------------------------------------------------------------------
local function lap()
	step("race", "Start")
	local r = Combat:Start()
	if not r then
		say("race: Start refused")
		return false
	end
	stats.laps += 1
	local lastBoss
	while r do
		if (r.fleeSpeedMultiplier or 1) > 1 then
			break -- the server's own flag: this boss outruns your Speed
		end
		step("race", "chase " .. tostring(r.bossId))
		task.wait(LAP_GAP)
		Combat:BeginRound()
		task.wait(LAP_GAP)
		Combat:WakeUp()
		task.wait(LAP_GAP)
		local c = Combat:Caught()
		if not c then
			break
		end
		stats.caught += 1
		lastBoss = r.bossId
		if c.state == "BIOME_FINISH" or not c.transition then
			first("biome-finish", r.bossId, c.state)
			break
		end
		r = Combat:ProceedTransition()
	end
	step("race", "Finish")
	Combat:Finish()
	local egg = Combat:ClaimRunEgg()
	first("claim", lastBoss, egg and egg.eggId, egg and egg.size)
	if stats.laps % 10 == 1 then
		log("lap", stats.laps, "last boss", lastBoss, "egg", egg and egg.eggId, "speed", data().Speed)
	end
	bestBoss = lastBoss or bestBoss
	return true
end

local nextLap = 0
makeLoop("race", RACE_EVERY, function()
	if os.clock() < nextLap then
		return
	end
	if #bagEggs() >= EGG_BUFFER then
		say("race: egg bag full, waiting for the hatchery")
		return
	end
	if not alive() or player:GetAttribute("InCombat") then
		return
	end
	claim(function()
		if TC:IsTraining() then
			TC:StopTraining(true)
			task.wait(SETTLE)
		end
		say("race: lap")
		lap()
		step("race", "home")
		Plot:TeleportToPlot()
		task.wait(0.5)
		nextLap = os.clock() + (loops.train.on and LAP_REST or 0)
	end)
end)

-- train ----------------------------------------------------------------------
local TPC = nil
pcall(function()
	TPC = require(Knit.Components.TrainingPlaceholderComponent)
end)

local function standPart()
	local plot = PlotUtils.GetPlayerPlot(player)
	local inner = plot and plot:FindFirstChild(plot.Name)
	local ph = inner and inner:FindFirstChild("TrainingAreaPlaceholder")
	if not (ph and TPC) then
		return nil
	end
	local okC, comp = TPC:WaitForInstance(ph, 2):await()
	if okC and comp and comp:IsTreadmillBuilt() then
		return comp:GetStandPart()
	end
	return nil
end

makeLoop("train", TRAIN_EVERY, function()
	if busy or TC:IsTraining() or not alive() or player:GetAttribute("InCombat") then
		return
	end
	claim(function()
		step("train", "stand")
		local sp = standPart()
		if not sp then
			say("train: treadmill not found")
			return
		end
		TC:StartTraining(sp)
		first("train", sp:GetFullName())
		task.wait(0.5)
	end)
end)

-- spend ----------------------------------------------------------------------
local backoff = {}
local function backedOff(key)
	return (backoff[key] or 0) > os.clock()
end

makeLoop("treadmill", SPEND_EVERY, function()
	local d = data()
	if not d then
		return
	end
	-- the base upgrade is the scarcer purchase (10 levels, one slot each): when it is affordable it goes first
	if loops.pen.on and not backedOff("pen") then
		local price = UpgradeConfig.GetPrice("PlotUpgrade", (d.Upgrades and d.Upgrades.PlotUpgrade or 0) + 1)
		if price and price <= cash() then
			return
		end
	end
	local owned, equipped = d.OwnedTrainTools or {}, d.EquippedTrainTool
	local eqGain = equipped and TrainToolConfig.TRAIN_TOOLS[equipped] and TrainToolConfig.TRAIN_TOOLS[equipped].gainPerTrain or 0
	local buy, bestOwned
	for id, t in pairs(TrainToolConfig.TRAIN_TOOLS) do
		if owned[id] then
			if not bestOwned or t.gainPerTrain > TrainToolConfig.TRAIN_TOOLS[bestOwned].gainPerTrain then
				bestOwned = id
			end
		elseif type(t.cost) == "number" and not t.isSpecial and not t.passRequired and t.cost <= cash() and t.gainPerTrain > eqGain then
			if not buy or t.gainPerTrain > TrainToolConfig.TRAIN_TOOLS[buy].gainPerTrain then
				buy = id
			end
		end
	end
	if buy and not backedOff("tool" .. buy) then
		step("treadmill", "buy " .. buy)
		Training:BuyTrainTool(buy) -- returns nothing; a buy equips it (probed), so confirm on state
		task.wait(1)
		if (data().OwnedTrainTools or {})[buy] then
			stats.tools += 1
			first("tool", buy)
		else
			backoff["tool" .. buy] = os.clock() + SPEND_BACKOFF
			first("tool-refused", buy, cash())
		end
	elseif bestOwned and equipped ~= bestOwned and TrainToolConfig.TRAIN_TOOLS[bestOwned].gainPerTrain > eqGain then
		step("treadmill", "equip " .. bestOwned)
		equipGate()
		Training:EquipTrainTool(bestOwned)
		first("tool-equip", bestOwned)
	end
end)

makeLoop("pen", SPEND_EVERY, function()
	local d = data()
	if not d or backedOff("pen") then
		return
	end
	local level = d.Upgrades and d.Upgrades.PlotUpgrade or 0
	local n = UpgradeConfig.GetMaxBuyable("PlotUpgrade", level, cash())
	if n < 1 then
		return
	end
	step("pen", "upgrade x" .. n)
	Upgrades:Upgrade("PlotUpgrade", n)
	task.wait(1)
	local after = data().Upgrades and data().Upgrades.PlotUpgrade or 0
	if after > level then
		stats.pen += after - level
		first("pen", level, "->", after)
	else
		backoff.pen = os.clock() + SPEND_BACKOFF
		first("pen-refused", level, n, cash())
	end
end)

-- world ----------------------------------------------------------------------
makeLoop("world", WORLD_EVERY, function()
	local d = data()
	if not d or busy then
		return
	end
	local best, order = nil, -1
	for id, cfg in pairs(BiomeConfig) do
		if (d.UnlockedBiomes or {})[id] and cfg.order > order then
			best, order = id, cfg.order
		end
	end
	if not best or best == d.CurrentBiome or backedOff("world") then
		return
	end
	claim(function()
		if TC:IsTraining() then
			TC:StopTraining(true)
			task.wait(SETTLE)
		end
		say("world: " .. tostring(d.CurrentBiome) .. " -> " .. best)
		step("world", "ChangeBiome " .. best)
		Biome:ChangeBiome(best)
		task.wait(3)
		if data().CurrentBiome == best then
			stats.worlds += 1
			first("world", best)
		else
			backoff.world = os.clock() + SPEND_BACKOFF
			first("world-refused", best)
		end
	end)
end)

-- rebirth --------------------------------------------------------------------
makeLoop("rebirth", REBIRTH_EVERY, function()
	local d = data()
	local nextStep = d and RebirthConfig.REBIRTH[(d.Rebirth or 0) + 1]
	if not nextStep or cash() < nextStep.Cost.Cash or backedOff("rebirth") then
		return
	end
	step("rebirth", "Rebirth")
	local before = d.Rebirth or 0
	Rebirth:Rebirth() -- never InitSkip: that is a Robux product
	task.wait(2)
	if (data().Rebirth or 0) > before then
		stats.rebirths += 1
		first("rebirth", before, "->", data().Rebirth)
	else
		backoff.rebirth = os.clock() + SPEND_BACKOFF
		first("rebirth-refused", before, cash())
	end
end)

-- watchdog -------------------------------------------------------------------
local watching = true
task.spawn(function()
	while watching do
		task.wait(5)
		for name, m in pairs(marks) do
			if loops[name] and loops[name].on and os.clock() - m[2] > WATCHDOG then
				warn(("[egg] %s stuck %ds at: %s"):format(name, os.clock() - m[2], m[1]))
				m[2] = os.clock()
			end
		end
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Don't Steal My Egg", statusBar = true })
if not Window then
	watching = false
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "egg")
local Hatchery = Tab:AddLeftGroupbox("Eggs", "egg")
local Grow = Tab:AddRightGroupbox("Grow", "trending-up")

local function toggle(box, idx, text, tip, loopName)
	return box:AddToggle(idx, {
		Text = text,
		Tooltip = tip,
		Default = false,
		Callback = function(state)
			loops[loopName].set(state)
		end,
	})
end

toggle(Hatchery, "Race", "Auto Farm", "Runs the boss race by remote, about 1s per boss: no chase. Pays the egg of the last boss your Speed can catch. Stops the treadmill for each lap", "race")
toggle(Hatchery, "Place", "Auto Place Egg", "Places the best eggs in your bag on your plot, up to the game's egg limit", "place")
toggle(Hatchery, "Hatch", "Auto Hatch Egg", "Hatches each egg the moment its timer ends", "hatch")
toggle(Hatchery, "Equip", "Auto Equip Best", "Equip Best every few seconds", "equip")
toggle(Hatchery, "Sell", "Auto Sell", "Equips the best, then sells every unlocked, non-special animal left in the bag", "sell")

toggle(Grow, "Train", "Auto Train", "Stands you on your treadmill (the game's own call) and keeps you there between laps", "train")
toggle(Grow, "Treadmill", "Auto Upgrade Treadmill", "Buys the best treadmill you can afford; the buy equips it", "treadmill")
toggle(Grow, "Pen", "Auto Upgrade Pen", "Buys base upgrades (+1 animal slot, +2 egg slots each) as soon as the Cash is there", "pen")
toggle(Grow, "World", "Auto Move World", "Moves you to the highest unlocked world. A world unlocks when a lap catches the last boss of the one before", "world")
toggle(Grow, "Rebirth", "Auto Rebirth", "Rebirths as soon as the Cash covers it. Resets progress", "rebirth")

local conns = {}
local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

local nextStrip = 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	local t = os.clock()
	if t < nextStrip then
		return
	end
	nextStrip = t + 0.5
	local d = data()
	if not d then
		return
	end
	local placedAnimals = 0
	for _ in pairs(d.PlacedAnimals or {}) do
		placedAnimals += 1
	end
	pcall(Window.SetStatus, Window, {
		{ "Cash", fmt(d.Currencies and d.Currencies.Cash or 0) },
		{ "Speed", fmt(d.Speed or 0) },
		{ "Eggs", #bagEggs() .. "+" .. #placedEggs() },
		{ "Pets", placedAnimals .. "/" .. (Modifiers.Get(player, "MaxAnimals") or 10) },
		{ "Laps", stats.laps },
		{ "Boss", bestBoss },
		{ "RB", d.Rebirth or 0 },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("DontStealMyEgg", {})

-- close ----------------------------------------------------------------------
local function stopAll()
	for _, L in pairs(loops) do
		L.set(false)
	end
	watching = false
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
	pcall(function()
		if TC:IsTraining() then
			TC:StopTraining(true)
		end
	end)
end

Library:OnUnload(function()
	stopAll()
	getgenv().dontStealEggStop = nil
end)

getgenv().dontStealEggStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().dontStealEggStop = nil
end
