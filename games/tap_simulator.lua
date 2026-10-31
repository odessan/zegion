--[[ Tap Simulator -- tap, rebirth, skill tree, upgrades, hatch, equip best (72858262610964)

     TAP     : TapService.TapRequested at 10/s, which is the server's cap: faster taps are dropped
               silently (probed 5/10/20/50/100 per second: 15/28/29/29/29 answered in 3s). If you own the
               Auto Clicker skill it is switched on too: alone it pays the same as 10 manual taps/s, and the
               two together paid 4% more (421 vs 437 coins/s), so they share one cap.
     REBIRTH : RebirthService.RebirthRequested { Index } at your top unlocked tier (x1/5/25/125/600/...),
               once you can pay for it. A tier is charged at today's unit price and every single rebirth
               raises it by 175, so the big tier is a bulk discount (600 singles ~57M, one x600 ~26M at 240
               rebirths). Pays gems; resets coins to 0.
     CRAFT   : MachineService.MachineCraftRequested { Machine = "Golden", Action = "Craft", PetIds } with 6
               copies of a Normal pet (100%). The server wants you near the machine (~20 studs), so it walks
               to workspace.GoldenMachine and takes turns with Hatch. Craft All needs Goldens Mastery Lv. 4.
               Not wired: Diamond (its machine is on Heaven), Shiny (a timed queue).
     SKILLS  : SkillTreeService.Unlock { Name } on the cheapest node your gems cover, priced by the game's
               own SkillTreeFormula. A node the server refuses (not adjacent yet) is parked for a while.
     UPGRADE : UpgradeService.Purchase { Name } in the game's order, paid in gems (so it shares them with
               SKILLS). Most need a zone you have not reached ("ZoneLocked", RequiredZone = Winter) or a skill
               node ("SkillTreeNode"): those are parked and retried. Back-to-back calls get "RateLimited".
     HATCH   : EggService.EggHatchRequested { Egg, Count } with Count 3 when you can pay for 3, else 1 (the
               game's own pick; triple is free, x8 is a gamepass and not wired). One request per ~4.1s, paced
               by the server. It refuses past ~20 studs ("TooFar", OK at 18, refused at 25), so it walks next
               to the egg first.
     EQUIP   : PetService.PetActionRequested { Action = "EquipBest", Mode = "Clicks" }, the inventory's
               own Best button, whenever your pet count changes and every EQUIP_EVERY.
     INDEX   : PetIndexService.ClaimAllRequested on a slow beat (no visible change on a fresh account).
     CODES   : type a code, press Redeem (CodeService.RF.Redeem). No code list ships with the game.

     Movement: this server polices position. A 30-stud hop held; 60 and 150 studs, and a 40 studs/s
     glide, each made the server ignore every call for 20-40s afterwards (taps unanswered). So the only
     travel here is walking (Humanoid:MoveTo), which only Hatch needs.

     Probed and dead / not needed (do not re-probe):
       taps above 10/s                  dropped by the server, they only add flood risk
       quest claim                      the server auto-claims finished quests (QuestAutoClaimed)
       offline claim                    granted on join ("NothingPending"); pays 4 taps/s while away
       tap chests                       on locked islands, and range-checked ("Get closer to the chest!")
       hops over 30 studs, any glide    the server goes silent for 20-40s
     Not wired (Robux): x8 hatch, godly hatch, gamepass perks, token purchases.
     Anti-cheat: Comm kicks for a remote flood above 500 calls/s sustained (1500 in one second).

     RightControl opens / closes the panel. Stop: getgenv().tapSimStop() ]]

-- config ---------------------------------------------------------------------
local TAP_GAP = 0.1 -- 10/s is the server's cap; lower only adds dropped calls toward the flood limit
local REBIRTH_EVERY = 0.5 -- how often to check whether the top rebirth tier is affordable
local SKILL_EVERY = 2
local SKILL_PARK = 60 -- a node the server refused is not tried again for this long
local UPGRADE_EVERY = 3
local UPGRADE_PARK = 60 -- a refused upgrade (zone locked, too poor) waits this long
local UPGRADE_GAP = 0.5 -- between Purchase calls: three back to back got "RateLimited"
local HATCH_GAP = 0.3 -- after a hatch reply, before the next request; raise if the server answers "busy"
local HATCH_REPLY = 6 -- an EggHatchResult must land inside this
local HATCH_STAND = 8 -- studs from the egg to stand at (the server refuses past ~20)
local WALK_TIMEOUT = 10 -- give up a walk to the egg after this long
local EQUIP_GAP = 2
local EQUIP_EVERY = 30
local INDEX_EVERY = 60
local CALL_TIMEOUT = 5 -- an InvokeServer that has not answered by then is abandoned

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().tapSimStop then
	getgenv().tapSimStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[tapsim]", ...)
end

-- The panel strip is drained from a Heartbeat (a loop thread loses the capability after its first wait).
local pending, lastSaid = nil, nil
local function say(msg)
	pending = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- first(name, ...) prints a branch the first time it runs, so a live log shows which paths were taken
local seen = {}
local function first(name, ...)
	if not seen[name] then
		seen[name] = true
		log("first:", name, ...)
	end
end

-- game -----------------------------------------------------------------------
local Services = ReplicatedStorage:WaitForChild("RemoteServices", 15)
local ok, DataController, RebirthConfig, SkillTreeFormula, UpgradeConfig, EggConfig, EggPricing = pcall(function()
	return require(ReplicatedStorage:FindFirstChild("DataController", true)),
		require(ReplicatedStorage.Shared:FindFirstChild("RebirthConfig", true)),
		require(ReplicatedStorage.Shared.Progression.SkillTreeFormula),
		require(ReplicatedStorage.Shared.Progression.UpgradeConfig),
		require(ReplicatedStorage.Shared.Pets.LaunchEggConfig),
		require(ReplicatedStorage.Shared.Pets.EggPricing)
end)
if not Services or not ok then
	warn("[tapsim] the game's modules did not load:", DataController)
	return
end

local function remote(service, kind, name)
	return Services:WaitForChild(service):WaitForChild(kind):WaitForChild(name)
end
local TapRequested = remote("TapService", "RE", "TapRequested")
local AutoClickRequested = remote("AutoClickService", "RE", "AutoClickRequested")
local RebirthRequested = remote("RebirthService", "RE", "RebirthRequested")
local SkillUnlock = remote("SkillTreeService", "RF", "Unlock")
local UpgradePurchase = remote("UpgradeService", "RF", "Purchase")
local HatchRequested = remote("EggService", "RE", "EggHatchRequested")
local HatchResult = remote("EggService", "RE", "EggHatchResult")
local PetAction = remote("PetService", "RE", "PetActionRequested")
local IndexClaimAll = remote("PetIndexService", "RE", "ClaimAllRequested")
local CodeRedeem = remote("CodeService", "RF", "Redeem")

-- the client's live save mirror; the server writes into it, so reads are always current
local function data()
	return DataController:GetReplica().Data
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

-- InvokeServer has no timeout; a handler that never answers would park the loop forever
local function invoke(rf, ...)
	local args, result, done = table.pack(...), nil, false
	task.spawn(function()
		result = table.pack(pcall(function()
			return rf:InvokeServer(table.unpack(args, 1, args.n))
		end))
		done = true
	end)
	local t = os.clock()
	while not done and os.clock() - t < CALL_TIMEOUT do
		task.wait()
	end
	if not done then
		return nil, "timeout"
	end
	if not result[1] then
		return nil, tostring(result[2])
	end
	return result[2]
end

local stats = { taps = 0, rebirths = 0, skills = 0, upgrades = 0, hatched = 0, equips = 0, crafted = 0 }

-- one generation counter per toggle: off-then-on inside one wait must not leave two loops running
local function looper(name, pass)
	local gen = 0
	return function(on)
		gen += 1
		local mine = gen
		if not on then
			return
		end
		task.spawn(function()
			while gen == mine do
				local good, err = pcall(pass, function()
					return gen == mine
				end)
				if not good then
					warn("[tapsim] " .. name .. " pass failed:", err)
					task.wait(1)
				end
			end
		end)
	end
end

-- tap ------------------------------------------------------------------------
local seq = 2000000 -- our own ClientSequence range, clear of the game's counter
local autoClickWas = nil -- the player's own Auto Clicker setting, handed back on stop

local function hasAutoClicker()
	local good, has = pcall(SkillTreeFormula.HasAutoClicker, data())
	return good and has
end

local setTap = looper("tap", function(alive)
	if hasAutoClicker() and data().Settings.AutoClickerEnabled ~= true then
		if autoClickWas == nil then
			autoClickWas = false
		end
		first("autoclicker on")
		AutoClickRequested:FireServer({ Enabled = true })
	end
	local t0 = os.clock()
	while alive() and os.clock() - t0 < 5 do
		seq += 1
		TapRequested:FireServer({ Auto = false, ClientSequence = seq, Source = "button" })
		stats.taps += 1
		task.wait(TAP_GAP)
	end
end)

local function restoreAutoClicker()
	if autoClickWas == false then
		AutoClickRequested:FireServer({ Enabled = false })
	end
	autoClickWas = nil
end

-- rebirth --------------------------------------------------------------------
-- Tiers 1..RebirthButtons+1 are unlocked (a fresh account has 1; the first rebirth unlocked 2 and 3).
-- RebirthConfig.GetPrice = 800 * amount * (1 + 0.21875 * (rebirths - 1)): a whole tier is charged at
-- today's unit price, while every single rebirth raises it by 175. So the top tier is a bulk discount
-- (600 singles at 240 rebirths ~57M coins, one x600 ~26M) and waiting for it beats rebirthing small.
local rebirthPick = 0 -- tier index chosen in the panel; 0 = top unlocked

local function pickTier(d)
	local top = 1 + (d.Upgrades.RebirthButtons or 0)
	local tier = (rebirthPick > 0 and rebirthPick < top) and rebirthPick or top -- a locked pick waits for its button
	local amount = RebirthConfig.GetAmountFromIndex(tier)
	return tier, amount, RebirthConfig.GetPrice(amount, d.Statistics.Rebirths)
end
assert(RebirthConfig.GetPrice(600, 30) == 600 * RebirthConfig.GetPrice(1, 30), "a tier is priced at one unit price")

local setRebirth = looper("rebirth", function()
	local d = data()
	local tier, amount, price = pickTier(d)
	if d.Currencies.Coins >= price then
		local before = d.Statistics.Rebirths
		RebirthRequested:FireServer({ Index = tier })
		local t = os.clock()
		while data().Statistics.Rebirths == before and os.clock() - t < 3 do
			task.wait(0.1)
		end
		if data().Statistics.Rebirths > before then
			stats.rebirths += data().Statistics.Rebirths - before
			say(("rebirth x%s for %s coins (now %s)"):format(fmt(amount), fmt(price), fmt(data().Statistics.Rebirths)))
		else
			say(("rebirth tier %d refused at %s coins"):format(tier, fmt(d.Currencies.Coins)))
			task.wait(3)
		end
	end
	task.wait(REBIRTH_EVERY)
end)

-- skills ---------------------------------------------------------------------
local skillParked = {}

local function cheapestSkill(d)
	local best, bestPrice
	for name in pairs(SkillTreeFormula.Nodes) do
		if not d.SkillTree.Unlocked[name] and os.clock() >= (skillParked[name] or 0) then
			local good, price = pcall(SkillTreeFormula.GetPrice, d, name)
			local withheld = select(2, pcall(SkillTreeFormula.IsWithheld, d, name)) == true
			if good and type(price) == "number" and price > 0 and not withheld and (not bestPrice or price < bestPrice) then
				best, bestPrice = name, price
			end
		end
	end
	return best, bestPrice
end

local setSkills = looper("skills", function()
	local d = data()
	local name, price = cheapestSkill(d)
	if name and d.Currencies.Gems >= price then
		local reply, err = invoke(SkillUnlock, { Name = name })
		if type(reply) == "table" and reply.Success then
			stats.skills += 1
			say(("skill: %s for %s gems"):format(name, fmt(price)))
			return -- straight round: there may be another affordable node
		end
		skillParked[name] = os.clock() + SKILL_PARK
		first("skill refused " .. tostring(type(reply) == "table" and reply.Reason or err), name)
	end
	task.wait(SKILL_EVERY)
end)

-- upgrades -------------------------------------------------------------------
local upgradeParked = {}

local setUpgrades = looper("upgrades", function(alive)
	for _, name in ipairs(UpgradeConfig.Order) do
		if not alive() then
			return
		end
		local def = UpgradeConfig.Definitions[name]
		local level = data().Upgrades[name] or 0
		if def and level < def.Total and os.clock() >= (upgradeParked[name] or 0) then
			local reply, err = invoke(UpgradePurchase, { Name = name })
			if type(reply) == "table" and reply.Success then
				stats.upgrades += 1
				say(("upgrade: %s -> %d"):format(def.Title or name, level + 1))
			else
				local limited = type(reply) == "table" and reply.Reason == "RateLimited"
				upgradeParked[name] = os.clock() + (limited and 2 or UPGRADE_PARK)
				local why = type(reply) == "table" and (reply.Reason or "?") .. (reply.RequiredZone and (" " .. reply.RequiredZone) or "") or err
				first("upgrade refused " .. tostring(why), name)
			end
			task.wait(UPGRADE_GAP)
		end
	end
	task.wait(UPGRADE_EVERY)
end)

-- hatch ----------------------------------------------------------------------
local hatchEgg = "Basic"
local hatchSeq = 3000000
local lastResult = nil
local resultCon = HatchResult.OnClientEvent:Connect(function(r)
	if type(r) == "table" and type(r.Seq) == "number" and r.Seq > 3000000 then
		lastResult = r
	end
end)

local function eggModel(name)
	local eggs = workspace:FindFirstChild("Eggs")
	return eggs and eggs:FindFirstChild(name)
end

-- Hatch and Craft both walk you somewhere (egg / machine, ~20 studs each). One claim, so they take
-- turns per pass instead of steering the character against each other. Returns whether fn ran.
local busy = false
local function claim(fn, ...)
	if busy then
		return false
	end
	busy = true
	local good, err = pcall(fn, ...)
	busy = false
	if not good then
		error(err, 0)
	end
	return true
end

-- walking is the only travel that does not make this server stop answering (see the header)
local function walkNear(pos, alive)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (hum and root) then
		return false
	end
	local flat = Vector3.new(root.Position.X - pos.X, 0, root.Position.Z - pos.Z)
	if flat.Magnitude <= HATCH_STAND + 4 then
		return true
	end
	local dir = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(1, 0, 0)
	local goal = Vector3.new(pos.X, root.Position.Y, pos.Z) + dir * HATCH_STAND
	local t = os.clock()
	while alive() and os.clock() - t < WALK_TIMEOUT do
		hum:MoveTo(goal) -- re-issued: MoveTo gives up on its own after ~8s
		task.wait(0.5)
		local f = Vector3.new(root.Position.X - pos.X, 0, root.Position.Z - pos.Z)
		if f.Magnitude <= HATCH_STAND + 4 then
			return true
		end
	end
	return false
end

local function hatchPass(alive)
	local cfg = EggConfig[hatchEgg]
	local model = eggModel(hatchEgg)
	if not (cfg and model) then
		say("hatch: egg " .. tostring(hatchEgg) .. " not found")
		task.wait(2)
		return
	end
	-- the game's own pick (EggController.pickAutoHatchCount): 3 if you can pay for 3, else 1. 8 needs the
	-- x8Egg gamepass and is not wired
	local d = data()
	local count = (EggPricing.GetTotal(d, hatchEgg, cfg.Price, 3) <= d.Currencies.Coins and 3)
		or (EggPricing.GetUnitPrice(d, hatchEgg, cfg.Price) <= d.Currencies.Coins and 1)
	if not count then
		task.wait(0.5)
		return
	end
	if not walkNear(model:GetPivot().Position, alive) then
		say("hatch: could not walk to " .. hatchEgg)
		task.wait(2)
		return
	end
	hatchSeq += 1
	local mine = hatchSeq
	lastResult = nil
	HatchRequested:FireServer({ Egg = hatchEgg, Count = count, Auto = false, Seq = mine })
	local t = os.clock()
	while alive() and not (lastResult and lastResult.Seq == mine) and os.clock() - t < HATCH_REPLY do
		task.wait()
	end
	local r = lastResult
	if r and r.Seq == mine and r.Success then
		stats.hatched += type(r.Pets) == "table" and #r.Pets or count
		first("hatch ok x" .. count, hatchEgg, ("%.1fs"):format(os.clock() - t))
	elseif r and r.Seq == mine then
		say(("hatch refused: %s (%s)"):format(tostring(r.Error), hatchEgg))
		task.wait(2)
	else
		say("hatch: no reply in " .. HATCH_REPLY .. "s")
	end
end

local setHatch = looper("hatch", function(alive)
	if not claim(hatchPass, alive) then
		task.wait(0.5)
		return
	end
	task.wait(HATCH_GAP)
end)

-- equip ----------------------------------------------------------------------
local function petCount(d)
	local n = 0
	for _ in pairs(d.Pets.Owned) do
		n += 1
	end
	return n
end

local equipState = { count = -1, at = -99 }
local setEquip = looper("equip", function()
	local d, now = data(), os.clock()
	local n = petCount(d)
	if (n ~= equipState.count and now - equipState.at >= EQUIP_GAP) or now - equipState.at >= EQUIP_EVERY then
		local before = d.Pets.PowerMultiplier
		equipState.count, equipState.at = n, now
		PetAction:FireServer({ Action = "EquipBest", Mode = "Clicks" })
		stats.equips += 1
		task.wait(1)
		if data().Pets.PowerMultiplier ~= before then
			say(("equip best: power x%s -> x%s"):format(fmt(before), fmt(data().Pets.PowerMultiplier)))
		end
	end
	task.wait(0.5)
end)

-- craft ----------------------------------------------------------------------
-- MachineConfig.Chances[n] is the success % for n copies of one species; the last entry is 100%, so a
-- craft always uses exactly that many (Golden 6 Normal). The server wants you near the machine ("You must
-- be near the Golden Machine.": OK at ~17 studs, refused at ~23). Craft All is the game's bulk version,
-- but it needs Goldens Mastery Lv. 4, so this does one craft at a time.
-- ponytail: Golden only. The Diamond machine is on Heaven (an island you reach later); add "Diamond" to
-- CRAFTS with its model name once someone stands next to one.
local CRAFTS = { Golden = "GoldenMachine" } -- machine key -> model name in workspace
local MachineConfig = require(ReplicatedStorage.Shared.Pets.MachineConfig)
local CraftRequested = remote("MachineService", "RE", "MachineCraftRequested")
local CraftResult = remote("MachineService", "RE", "MachineCraftResult")
local craftReply = nil
local craftCon = CraftResult.OnClientEvent:Connect(function(r)
	craftReply = r
end)

-- copies of one species, of the machine's source tier, that nothing else wants
local function craftBatch(d, machine)
	local cfg = MachineConfig[machine]
	local need = cfg and cfg.Chances and #cfg.Chances
	if not need then
		return nil
	end
	local equipped = {}
	for _, id in ipairs(d.Pets.Equipped) do
		equipped[id] = true
	end
	local by = {}
	for id, p in pairs(d.Pets.Owned) do
		if p.Tier == cfg.SourceTier and not p.Locked and not equipped[id] and not p.Mutation and not p.Enchants and p.Rarity ~= "Secret" then
			local list = by[p.Name] or {}
			by[p.Name] = list
			list[#list + 1] = id
			if #list == need then
				return p.Name, list
			end
		end
	end
	return nil
end

-- the nearest copy of the machine (Sky Island has a second GoldenMachine far above spawn)
local function nearestModel(name)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local best, bestD
	for _, m in ipairs(workspace:GetChildren()) do
		if m.Name == name and root then
			local dist = (m:GetPivot().Position - root.Position).Magnitude
			if not bestD or dist < bestD then
				best, bestD = m, dist
			end
		end
	end
	return best
end

local function craftPass(alive)
	local did = false
	for machine, modelName in pairs(CRAFTS) do
		local name, ids = craftBatch(data(), machine)
		local model = name and nearestModel(modelName)
		if model and alive() and not walkNear(model:GetPivot().Position, alive) then
			say("craft: could not walk to the " .. machine .. " machine")
			model = nil
		end
		while model and name and alive() do
			craftReply = nil
			CraftRequested:FireServer({ Machine = machine, Action = "Craft", PetIds = ids })
			local t = os.clock()
			while not craftReply and os.clock() - t < CALL_TIMEOUT do
				task.wait()
			end
			if craftReply and craftReply.Crafted then
				stats.crafted += 1
				say(("craft: %d %s -> %s %s"):format(#ids, name, machine, name))
				did = true
				task.wait(0.3)
				name, ids = craftBatch(data(), machine) -- every batch while we stand here
			else
				say(("craft %s refused: %s"):format(machine, tostring(craftReply and craftReply.Reason or "no reply")))
				task.wait(5)
				break
			end
		end
	end
	return did
end

local setCraft = looper("craft", function(alive)
	-- only take the character when there is a batch to craft, so Hatch keeps it the rest of the time
	local ready = false
	for machine in pairs(CRAFTS) do
		ready = ready or craftBatch(data(), machine) ~= nil
	end
	if ready then
		claim(craftPass, alive)
	end
	task.wait(ready and 0.5 or 3)
end)

-- index ----------------------------------------------------------------------
local setIndex = looper("index", function(alive)
	IndexClaimAll:FireServer()
	local t = os.clock()
	while alive() and os.clock() - t < INDEX_EVERY do
		task.wait(1)
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Tap Simulator", statusBar = true })
if not Window then
	resultCon:Disconnect()
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "mouse-pointer-click")
local Farm = Tab:AddLeftGroupbox("Farm", "mouse-pointer-click")
local Spend = Tab:AddLeftGroupbox("Spend", "trending-up")
local Pets = Tab:AddRightGroupbox("Eggs and pets", "egg")
local Extra = Tab:AddRightGroupbox("Extras", "gift")

Farm:AddToggle("Tap", {
	Text = "Auto Tap",
	Tooltip = "10 taps a second, the server's cap (faster is dropped). Also switches on your Auto Clicker skill if you own it",
	Default = false,
	Callback = setTap,
})
Farm:AddToggle("Rebirth", {
	Text = "Auto Rebirth",
	Tooltip = "Rebirths at your highest unlocked tier the moment you can pay for it. Resets coins to 0 and pays gems",
	Default = false,
	Callback = setRebirth,
})
local TOP = "Top unlocked"
local rebirthValues, rebirthByLabel = { TOP }, { [TOP] = 0 }
for i = 1, 12 do
	local label = "x" .. fmt(RebirthConfig.GetAmountFromIndex(i))
	rebirthValues[#rebirthValues + 1] = label
	rebirthByLabel[label] = i
end
Farm:AddDropdown("RebirthAmount", {
	Text = "Rebirths per loop",
	Tooltip = "Top unlocked is the cheapest per rebirth: a tier is charged at today's price, while every single rebirth makes the next one dearer. A tier you have not unlocked yet uses your top one until it opens",
	Values = rebirthValues,
	Default = TOP,
	Callback = function(label)
		rebirthPick = rebirthByLabel[label] or 0
	end,
})
Spend:AddToggle("Skills", {
	Text = "Auto Skill Tree",
	Tooltip = "Spends gems on the cheapest skill node you can unlock, again and again",
	Default = false,
	Callback = setSkills,
})
Spend:AddToggle("Upgrades", {
	Text = "Auto Upgrades",
	Tooltip = "Buys upgrades in the game's order. Most need a zone you have not reached yet; those are retried every minute. Paid in gems, the same gems Auto Skill Tree spends",
	Default = false,
	Callback = setUpgrades,
})

local eggValues, eggByLabel, eggDefault = {}, {}, nil
do
	local list = {}
	for _, m in ipairs(workspace:FindFirstChild("Eggs") and workspace.Eggs:GetChildren() or {}) do
		local cfg = EggConfig[m.Name]
		if type(cfg) == "table" and type(cfg.Price) == "number" then
			list[#list + 1] = { name = m.Name, price = cfg.Price }
		end
	end
	table.sort(list, function(a, b)
		return a.price < b.price
	end)
	for _, e in ipairs(list) do
		local label = ("%s (%s)"):format(e.name, fmt(e.price))
		eggValues[#eggValues + 1] = label
		eggByLabel[label] = e.name
		if e.name == "Basic" then
			eggDefault = label
		end
	end
end
Pets:AddToggle("Hatch", {
	Text = "Auto Hatch",
	Tooltip = "Walks next to the egg below (the server refuses past ~20 studs) and hatches one at a time while you can pay for it",
	Default = false,
	Callback = setHatch,
})
Pets:AddDropdown("Egg", {
	Text = "Egg",
	Tooltip = "Price in brackets. An egg on an island you have not unlocked is refused",
	Values = eggValues,
	Default = eggDefault,
	Callback = function(label)
		hatchEgg = eggByLabel[label] or hatchEgg
	end,
})
Pets:AddToggle("Equip", {
	Text = "Auto Equip Best",
	Tooltip = "Presses the inventory's Best button (by click power) whenever your pet count changes",
	Default = false,
	Callback = setEquip,
})
Pets:AddToggle("Craft", {
	Text = "Auto Craft Golden",
	Tooltip = "Walks to the Golden Machine and turns every 6 copies of a Normal pet into a Golden one (100%). Takes turns with Auto Hatch. Never touches equipped, locked, mutated, enchanted or Secret pets",
	Default = false,
	Callback = setCraft,
})
Extra:AddToggle("Index", {
	Text = "Auto Claim Index",
	Tooltip = "Claims every pet index reward once a minute. Quests and offline rewards the server claims by itself",
	Default = false,
	Callback = setIndex,
})
local codeText = ""
Extra:AddInput("Code", {
	Text = "Code",
	Default = "",
	Finished = false,
	Callback = function(text)
		codeText = text
	end,
})
local codeLine = Extra:AddLabel("-", true)
Extra:AddButton({
	Text = "Redeem",
	Func = function()
		local code = codeText:gsub("^%s+", ""):gsub("%s+$", "")
		if code == "" then
			return
		end
		task.spawn(function()
			local reply, err = invoke(CodeRedeem, code)
			local msg = type(reply) == "table" and (reply.Success and "redeemed " .. code or tostring(reply.Reason or reply.Error or "refused")) or tostring(reply or err)
			say("code: " .. msg)
		end)
		codeLine:SetText("sent " .. code)
	end,
})

local conns = { resultCon, craftCon }
local note, nextStrip, tapMark, tapRate = "idle", 0, { t = os.clock(), n = 0 }, 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	if pending then
		note, pending = pending, nil
	end
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	if now - tapMark.t >= 5 then
		tapRate = (stats.taps - tapMark.n) / (now - tapMark.t)
		tapMark.t, tapMark.n = now, stats.taps
	end
	local d = data()
	pcall(Window.SetStatus, Window, { -- ponytail: thrown "lacking capability Plugin" when loaded through the bridge; silence, not fix
		{ "Coins", fmt(d.Currencies.Coins) },
		{ "Gems", fmt(d.Currencies.Gems) },
		{ "Rebirths", fmt(d.Statistics.Rebirths) },
		{ "Taps", ("%.1f/s"):format(tapRate) },
		{ "Hatched", stats.hatched },
		{ "Crafted", stats.crafted },
		{ "Skills", stats.skills },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("TapSimulator", {})

local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- close ----------------------------------------------------------------------
local function stopAll()
	setTap(false)
	setRebirth(false)
	setSkills(false)
	setUpgrades(false)
	setHatch(false)
	setEquip(false)
	setCraft(false)
	setIndex(false)
	restoreAutoClicker()
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().tapSimStop = nil
end)

getgenv().tapSimStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().tapSimStop = nil
end
