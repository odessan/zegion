--[[ Roll for Pets to Fight -- roll, buy, sell, upgrade, advance, claim, dungeon, all through the game's one Action remote (137395343406581)

     ROLL    : pulls the lever the moment the server's cooldown is up (2.0s, less with Swift Rolls). Probed: a
               second pull inside the cooldown is refused with the exact readyAt, so that is what paces it.
     BUY     : buys a revealed offer when it beats your weakest fielded pet (the game's own StatCalculator
               power), fills a free pen slot, is a species you never owned, is a ticked rarity or variant, or
               is the pet your next rebirth asks for. BuyPet took from 21 studs (probed).
     EQUIP   : the game's own Equip Best after every buy, fuse and feed (probed).
     SELL    : chest -> bag -> merchant, two calls. Selling is range-checked by the server (16 studs from the
               merchant, probed: refused at 37, paid at 11), so this walks you to the merchant once and
               back there whenever you drift. Collect and roll both work from that spot (probed).
     UPGRADE : tree nodes and pens from the server's own quotes, best payback first among what you can pay.
     ADVANCE : farms the unlocked stage that pays the most gold per second (EnemyConfig hp and gold against
               your team DPS), buys the next stage once the last one is the best place to farm, kills the
               boss when the team can, unlocks the next biome. One past the unlocked stage or biome is
               refused (probed).
     REBIRTH : when the game says canRebirth (ran live: rebirth 1). It resets cash and loot only.
     CLAIM   : daily, playtime tiers, the free wheel spin, quests, timed and season quests, collection
               milestones, offline cash. Each fires only when the state says it is due (probed: playtime 1-2,
               wheel; an early tier is refused).
     FUSE    : the game's own Fuse All when a stack of five exists. SALVAGE deletes the weakest idle pets of
               the ticked rarities when storage runs out: off unless you switch it on, never a locked pet,
               a variant, a fielded pet or one on a trip.
     TRIPS   : Send All / Claim All expeditions from the plot (probed: sent 5 idle pets on two trips).
     FEED    : every food you hold into your strongest fielded pet (probed: 9 biscuits = +16 levels).
     POTIONS : uses a potion you hold whenever its boost is not running (probed: Luck Potion I, 10 min).
     DUNGEON : the game's HUB teleport, a walk to the portal, Enter, Ready, and home again when the run ends
               (probed: 36 crystals a stage, 14 stages). CLIMB is the game's idle Auto-Climb, started and claimed.
     RAID    : joins the raid boss when it opens (5 minutes every half hour) through the client's own
               EnterWorldBoss { teleport = true }, from the plot. Ran live: 7 bosses, rank 1, +2.2K crystals.

     Probed and dead: rolling inside the cooldown, buying before the reveal, StageSelect one past the
     unlocked stage, a locked biome, an early playtime tier, a 60s bag auto-sale (it never came).
     Not wired: the Auto-Roll unlock (3.5K, 2.3s a pull: slower than this), the paid Auto-Buy / Auto-Collect
     passes (this is both), ShopPurchase, GiftPurchase, the Admin action.
     Movement: no teleport of ours. The game's own HOME / HUB buttons and a plain walk at normal WalkSpeed.

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().rollPetsStop() ]]

-- config ---------------------------------------------------------------------
local CALL_GAP = 0.12 -- least time between any two Action calls (the server allows 20/s overall, 2-6/s per action)
local ROLL_TICK = 0.15 -- beat of the roll and buy loops; the pull itself waits for the server's readyAt
local ROLL_SLACK = 0.05 -- pull this long after readyAt; raise if pulls come back "Cooldown"
local BUY_SLACK = 0.05 -- judge an offer this long after its reveal; raise if buys come back "Cooldown"
local HOLD_RARE = 120 -- keep a wanted offer you cannot pay for this long before rolling it away
local EQUIP_EVERY = 60 -- equip best this often even with nothing bought
local LOOT_EVERY = 10 -- collect + sell beat
local MERCHANT_STAND = 10 -- stand this far from the merchant (the server sells inside 16)
local SELL_REACH = 14 -- further than this from the merchant = walk back
local HOME_IF_OVER = 60 -- further than this from the merchant = the game's HOME button first, then walk
local TELEPORT_SETTLE = 1.5 -- after a HOME / HUB teleport, before the next step
local WALK_TIMEOUT = 15 -- a walk that takes longer gave up (blocked); the next pass goes HOME first
local UPGRADE_EVERY = 0.5 -- one purchase per look
local UPGRADE_BACKOFF = 10 -- a purchase the server refused is not retried for this long
local ADVANCE_EVERY = 3
local BOSS_TRY = 60 -- fight a boss only when the team kills it inside this many seconds
local RESPAWN = 1.5 -- StageConfig.RESPAWN_DELAY, the dead time after every kill
local CLAIM_EVERY = 20
local WHEEL_FREE = 86400 -- WheelConfig.FREE_INTERVAL: one free spin a day
local PETS_EVERY = 30 -- fuse and salvage beat
local SALVAGE_BATCH = 20 -- pets per salvage call (the server takes up to 100)
local TRIPS_EVERY = 60
local FEED_EVERY = 15
local DUNGEON_TICK = 5
local DUNGEON_MAX = 1800 -- a run still going after this is left
local WATCHDOG = 60 -- a loop whose step mark stops moving this long is reported

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().rollPetsStop then
	getgenv().rollPetsStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[rollpets]", ...)
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
-- Several loops talk at once, so a line is printed again only after SAY_AGAIN seconds: comparing with
-- the last line alone let two loops alternate and print both every pass.
local SAY_AGAIN = 30
local note, saidAt, saidCount = "idle", {}, 0
local function say(msg)
	note = msg
	local t = os.clock()
	if (saidAt[msg] or -SAY_AGAIN) + SAY_AGAIN <= t then
		if not saidAt[msg] then
			saidCount += 1
			if saidCount > 200 then
				table.clear(saidAt)
				saidCount = 1
			end
		end
		saidAt[msg] = t
		log(msg)
	end
end

-- game -----------------------------------------------------------------------
local okMods, Net, SS, SC, EC, QC, PTC, PC, POC, WBR = pcall(function()
	local Ctl = player:WaitForChild("PlayerScripts"):WaitForChild("Client", 15).Controllers
	local Shared = ReplicatedStorage:WaitForChild("Shared", 15)
	return require(Ctl.Net),
		require(Ctl.StateStore),
		require(Shared.Utilities.StatCalculator),
		require(Shared.Config.EnemyConfig),
		require(Shared.Config.QuestConfig),
		require(Shared.Config.PlaytimeConfig),
		require(Shared.Config.PetConfig),
		require(Shared.Config.PotionConfig),
		require(Shared.Utilities.WorldBossRules)
end)
if not okMods then
	warn("[rollpets] the game's modules did not load:", Net)
	return
end

local function state()
	if not SS.isReady() then
		return nil
	end
	return SS.get()
end

local function now()
	return Net.serverNow()
end

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function fmt(n)
	if n >= 1e36 then
		return ("%.2e"):format(n)
	end
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
			set[v] = true -- list form
		elseif v then
			set[k] = true -- map form
		end
	end
	return set
end
assert(ticked({ "a" }).a and ticked({ a = true }).a and not ticked({ a = false }).a, "ticked reads both shapes")

local stats = { rolls = 0, bought = 0, sold = 0, upgrades = 0, claims = 0, fused = 0, salvaged = 0, runs = 0 }

-- breadcrumbs: every loop marks its step, a watchdog names the one that stopped moving
local marks = {}
local function step(loop, what)
	marks[loop] = { what, os.clock() }
end

-- One Action remote, rate-limited per player: the gate is around the call, with a real busy flag
-- (nothing yields between the check and the set), so three loops cannot fire in the same idle window.
-- Net.request gives up by itself after 15s, so a call cannot park a loop.
local busy, lastCall, seq = false, 0, 0
local function call(action, payload)
	while busy do
		task.wait()
	end
	busy = true
	local gap = CALL_GAP - (os.clock() - lastCall)
	if gap > 0 then
		task.wait(gap)
	end
	seq += 1
	local ok, r = pcall(Net.request, action, payload, { key = "zegion" .. seq, silent = true })
	lastCall = os.clock()
	busy = false
	if not ok or type(r) ~= "table" then
		return { ok = false, code = "Threw", message = tostring(r) }
	end
	return r
end

local function refused(action, r)
	first(action .. " refused " .. tostring(r.code), r.message)
end

-- loops ----------------------------------------------------------------------
-- One generation counter per toggle: off-then-on inside one interval must not leave the old thread alive.
local loops = {}
local function makeLoop(name, every, pass)
	local L = { on = false, gen = 0 }
	function L.set(on)
		L.on = on
		L.gen += 1
		if not on then
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
					warn("[rollpets]", name, "pass threw:", err)
				end
				task.wait(every)
			end
		end)
	end
	loops[name] = L
	return L
end

-- world ----------------------------------------------------------------------
local function root()
	local ch = player.Character
	return ch and ch:FindFirstChild("HumanoidRootPart")
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function promptPos(prompt)
	local p = prompt.Parent
	if p:IsA("Attachment") then
		return p.WorldPosition
	elseif p:IsA("BasePart") then
		return p.Position
	end
	return nil
end

-- Both spots are world-fixed for the session and stream out when you are in the dungeon arena,
-- so the position is cached the first time the prompt is seen.
local merchantAt, portalAt
local function merchant()
	if merchantAt then
		return merchantAt
	end
	local plots = workspace:FindFirstChild("PlayerPlots")
	local plot = plots and plots:FindFirstChild("Plot_" .. tostring(SS.myPlotId()))
	if plot then
		for _, d in ipairs(plot:GetDescendants()) do
			if d:IsA("ProximityPrompt") and d.ActionText == "Sell" then
				merchantAt = promptPos(d)
				break
			end
		end
	end
	return merchantAt
end

local function portal()
	if portalAt then
		return portalAt
	end
	local map = workspace:FindFirstChild("Map")
	local prompt = map and map:FindFirstChild("DungeonEnterPrompt", true)
	if prompt then
		portalAt = promptPos(prompt)
	end
	return portalAt
end

-- Two loops drive the character (the merchant walk and the dungeon trip): one claim, refused rather
-- than queued, released on every path.
local moving = false
local function claim(fn)
	if moving then
		return false
	end
	moving = true
	local ok, err = pcall(fn)
	moving = false
	if not ok then
		warn("[rollpets] a trip threw:", err)
	end
	return true
end

local function walkTo(goal, within, timeout, alive)
	local t0, issued = os.clock(), 0
	while os.clock() - t0 < timeout and alive() do
		local r = root()
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if not r or not hum then
			return false
		end
		if flat(r.Position - goal).Magnitude <= within then
			return true
		end
		if os.clock() - issued > 1 then -- MoveTo only steers and gives up by itself
			issued = os.clock()
			hum:MoveTo(goal)
		end
		task.wait(0.15)
	end
	return false
end

local function inRun(s)
	local d, w = s.derived.dungeon, s.derived.worldBoss
	return (d and d.run ~= nil) or (w and w.inFight == true) or false
end

local function nearMerchant()
	local r, m = root(), merchant()
	if not r or not m then
		return false
	end
	return flat(r.Position - m).Magnitude <= SELL_REACH
end

local walkFails = 0
local function goMerchant(loop, alive)
	if nearMerchant() then
		return true
	end
	local ran = claim(function()
		local r, m = root(), merchant()
		if not r then
			return
		end
		if not m or walkFails >= 2 or (r.Position - m).Magnitude > HOME_IF_OVER then
			step(loop, "the game's HOME teleport")
			call("Teleport", { to = "Plot" })
			task.wait(TELEPORT_SETTLE)
			r, m = root(), merchant()
			if not r or not m then
				return
			end
		end
		step(loop, "walk to the merchant")
		local away = flat(r.Position - m)
		local dir = away.Magnitude > 1 and away.Unit or Vector3.new(1, 0, 0)
		local goal = m + dir * MERCHANT_STAND
		if walkTo(Vector3.new(goal.X, r.Position.Y, goal.Z), 2.5, WALK_TIMEOUT, alive) then
			walkFails = 0
		else
			walkFails += 1
			first("walk to the merchant gave up", "the next try goes HOME first")
		end
	end)
	return ran and nearMerchant()
end

-- pets -----------------------------------------------------------------------
local RARITIES = table.clone(PC.RARITY_ORDER)
local VARIANTS = {}
for _, v in ipairs(PC.VARIANT_ORDER) do
	if v ~= "Normal" then
		VARIANTS[#VARIANTS + 1] = v
	end
end

local function rarityOf(species)
	local okGet, def = pcall(PC.get, species)
	return okGet and type(def) == "table" and def.rarity or "?"
end

local function power(pet)
	local okPower, p = pcall(SC.instancePower, pet)
	return okPower and tonumber(p) or 0
end

local function idle(pet)
	return not SC.isPlaced(pet) and not SC.isAway(pet)
end

-- instancePower leaves the level out and the server's dps has it in, so an offer is put on the dps
-- scale through the lowest dps-per-power among the pets you own (a level 1 pet's).
local function fielded(s)
	local weakest, perPower
	for id, pet in pairs(s.pets) do
		local st = s.derived.petStats[id]
		local p = power(pet)
		if st and p > 0 then
			local k = st.dps / p
			if not perPower or k < perPower then
				perPower = k
			end
			if SC.isPlaced(pet) and (not weakest or st.dps < weakest) then
				weakest = st.dps
			end
		end
	end
	return weakest, perPower
end

local buyOn = { stronger = true, new = true }
local rarityOn, variantOn = {}, {}
local reserve = 0

local function want(o, s)
	if o.species == s.rebirth.nextRequiredPet and not s.rebirth.requiredPetUnlocked then
		return "rebirth"
	end
	if rarityOn[o.rarity] then
		return "rarity"
	end
	if o.variant ~= "Normal" and variantOn[o.variant] then
		return "variant"
	end
	if buyOn.new then
		local d = s.collection.discovered[o.species]
		if not d or not d[o.variant] then
			return "new"
		end
	end
	if buyOn.stronger then
		if s.derived.deployedCount < s.derived.deployLimit then
			return "stronger"
		end
		local weakest, perPower = fielded(s)
		local p = power({ species = o.species, variant = o.variant, level = 1, stars = 0 })
		if weakest and perPower and p * perPower > weakest then
			return "stronger"
		end
	end
	return nil
end

local judged = {} -- pedestal -> the offer id the buy pass has dealt with
local held = {} -- offer id -> when we started saving for it
local saving, savingUntil = 0, 0 -- cash the upgrade and advance loops leave alone while an offer is held
local needEquip = false
local rollReadyAt, confirmRoll = 0, false

makeLoop("buy", ROLL_TICK, function()
	local s = state()
	if not s then
		return
	end
	local t = now()
	for pid, o in pairs(s.offers) do
		if judged[pid] ~= o.id and t >= (o.revealAt or 0) + BUY_SLACK then
			step("buy", "judge " .. pid)
			local why = want(o, s)
			local gold = s.currencies.Gold - reserve
			if not why then
				judged[pid] = o.id
			elseif o.price <= gold then
				local r = call("BuyPet", { pedestalId = pid, offerId = o.id })
				judged[pid] = o.id
				held[o.id] = nil
				if r.ok then
					stats.bought += 1
					needEquip = true
					local name = (o.variant ~= "Normal" and o.variant .. " " or "") .. o.species
					say(("bought %s %s (%s) for %s"):format(o.rarity, name, why, fmt(o.price)))
				elseif r.code == "Cooldown" then
					judged[pid] = nil -- still rolling: look again
				else
					refused("BuyPet", r)
				end
			elseif why == "stronger" or why == "new" then
				judged[pid] = o.id
			else
				held[o.id] = held[o.id] or os.clock()
				if os.clock() - held[o.id] > HOLD_RARE then
					judged[pid] = o.id
					held[o.id] = nil
				else
					saving, savingUntil = o.price, os.clock() + 2 -- renewed every pass while the hold lasts
					say(("saving %s for %s %s"):format(fmt(o.price), o.rarity, o.species))
				end
			end
		end
	end
end)

makeLoop("roll", ROLL_TICK, function()
	local s = state()
	if not s or now() < rollReadyAt then
		return
	end
	if loops.buy.on then
		for pid, o in pairs(s.offers) do
			if judged[pid] ~= o.id then
				return -- the buy pass has not dealt with this roll yet
			end
		end
	end
	step("roll", "RollPets")
	local r = call("RollPets", confirmRoll and { confirm = true } or {})
	confirmRoll = false
	if r.ok then
		stats.rolls += 1
		rollReadyAt = now() + (r.data and tonumber(r.data.duration) or 2) + ROLL_SLACK
	elseif r.code == "Cooldown" and r.data and r.data.readyAt then
		rollReadyAt = r.data.readyAt + ROLL_SLACK
	elseif r.code == "ConfirmRequired" then
		if loops.buy.on then
			confirmRoll = true -- the buy pass passed on it, or gave up saving for it
			first("roll confirm", "rolling a kept offer away after the buy pass passed on it")
		else
			say("a rare offer is on a pedestal: buy it, or pull once by hand")
			rollReadyAt = now() + 5
		end
	else
		refused("RollPets", r)
		rollReadyAt = now() + 1
	end
end)

-- what the spending loops may use: cash minus the reserve, minus what a held offer is waiting for
local function spendable(s)
	return s.currencies.Gold - reserve - (os.clock() < savingUntil and saving or 0)
end

local lastEquip = 0
makeLoop("equip", 1, function()
	if not needEquip and os.clock() - lastEquip < EQUIP_EVERY then
		return
	end
	local s = state()
	if not s or inRun(s) then
		return
	end
	step("equip", "EquipBest")
	needEquip = false
	lastEquip = os.clock()
	local r = call("EquipBest", nil)
	if not r.ok and r.code ~= "NothingToDo" then
		refused("EquipBest", r)
	end
end)

-- loot -----------------------------------------------------------------------
makeLoop("loot", LOOT_EVERY, function(alive)
	local s = state()
	if not s or inRun(s) then
		return
	end
	local chest, bag = s.loot.chest, s.loot.bag
	if (chest.count or 0) <= 0 and (bag.count or 0) <= 0 then
		return
	end
	if not goMerchant("loot", alive) then
		return
	end
	if (chest.count or 0) > 0 then
		step("loot", "CollectChest")
		local r = call("CollectChest", {})
		if not r.ok and r.code ~= "NothingToDo" then
			refused("CollectChest", r)
		end
	end
	step("loot", "SellAllLoot")
	local r = call("SellAllLoot", {})
	if r.ok then
		local gold = r.data and tonumber(r.data.Gold) or 0
		stats.sold += gold
		say("sold loot for " .. fmt(gold))
	elseif r.code == "TooFar" then
		walkFails += 1 -- the spot we walked to is not in reach: HOME first next time
		refused("SellAllLoot", r)
	elseif r.code ~= "NothingToDo" then
		refused("SellAllLoot", r)
	end
end)

-- upgrades -------------------------------------------------------------------
-- The payback numerator: roughly what one more level adds to gold per second, as a share.
-- ponytail: damage, cash and attack speed are the game's own additive steps; the rest are judgement
-- (luck and pedestals pay through future pets). Read the price formulas if the order looks wrong late.
local GAIN = {
	Damage = function(l)
		return 0.1 / (1 + 0.1 * l)
	end,
	GoldGain = function(l)
		return 0.1 / (1 + 0.1 * l)
	end,
	AttackSpeed = function(l)
		return 0.03 / (1 + 0.03 * l)
	end,
	Luck = function(l)
		return l < 35 and 0.2 or l < 60 and 0.05 or 0.015
	end,
	Pedestal = function()
		return 0.08
	end,
	SwiftRolls = function()
		return 0.04
	end,
	BargainHunter = function()
		return 0.02
	end,
	BossBounty = function()
		return 0.02
	end,
}
assert(GAIN.Damage(0) > GAIN.Damage(10) and GAIN.Luck(0) > GAIN.Luck(70), "gains shrink with level")

local parked = {} -- purchase key -> os.clock() until which it is left alone

makeLoop("upgrade", UPGRADE_EVERY, function()
	local s = state()
	if not s then
		return
	end
	local gold = spendable(s)
	local best, bestScore
	local function offer(key, cost, gain, buy, label)
		if cost and cost > 0 and cost <= gold and (parked[key] or 0) < os.clock() then
			local score = gain / cost
			if not bestScore or score > bestScore then
				best, bestScore = { key = key, buy = buy, label = label, cost = cost }, score
			end
		end
	end
	for id, q in pairs(s.derived.treeQuotes) do
		-- a part-levelled node reads "InProgress", not "Available": the first filter here skipped every one
		if q.state ~= "Locked" and q.state ~= "Maxed" and not q.rebirthLocked and q.currency == "Gold" and id ~= "AutoRoll" then
			local gain
			if q.track == "PetStorage" then
				gain = (s.derived.freePetSlots or 99) < 15 and 1 or 0.001
			else
				local f = GAIN[q.track]
				gain = f and f(q.trackLevel or 0) or 0.01
			end
			offer("node:" .. id, q.nextCost, gain, function()
				return call("BuyUpgradeNode", { nodeId = id, mode = "One" })
			end, id)
		end
	end
	for id, q in pairs(s.derived.penQuotes) do
		if not q.atMax and q.currency == "Gold" then
			offer("pen:" .. id, q.cost, 1 / math.max(1, s.derived.deployLimit), function()
				return call("BuyPen", { penId = id, action = q.action })
			end, id .. " pen " .. tostring(q.action))
		end
	end
	if not best then
		return
	end
	step("upgrade", best.label)
	local r = best.buy()
	if r.ok then
		stats.upgrades += 1
		needEquip = true -- a new pen slot wants a pet
		say(("upgrade %s for %s"):format(best.label, fmt(best.cost)))
	else
		parked[best.key] = os.clock() + UPGRADE_BACKOFF
		refused("upgrade " .. best.label, r)
	end
end)

-- advance --------------------------------------------------------------------
local STAGES = 5 -- StageConfig.STAGE_COUNT

local function enemy(biome, stage)
	local okE, e = pcall(EC.forStage, biome, stage)
	if okE and type(e) == "table" and tonumber(e.hp) and tonumber(e.gold) then
		return e
	end
	return nil
end

-- gold per second of a stage: its gold over the kill time plus the respawn gap
local function rate(e, dps)
	return e.gold / (e.hp / math.max(dps, 1) + RESPAWN)
end
assert(rate({ gold = 2212, hp = 1000 }, 399) > rate({ gold = 4305, hp = 3500 }, 399), "stage 4 beat the boss at 399 dps")

local function bestStage(s)
	local dps = s.derived.teamDps or 0
	local biome, stage, top
	for _, gate in ipairs(s.derived.stage.biomeGates) do
		if gate.unlocked then
			for i = 1, math.min(STAGES, s.biomes.stageUnlocked[gate.id] or 1) do
				local e = enemy(gate.id, i)
				local v = e and rate(e, dps)
				if v and (not top or v > top) then
					biome, stage, top = gate.id, i, v
				end
			end
		end
	end
	return biome, stage
end

local function frontier(s)
	local biome
	for _, gate in ipairs(s.derived.stage.biomeGates) do
		if gate.unlocked then
			biome = gate.id
		end
	end
	return biome, biome and math.min(STAGES, s.biomes.stageUnlocked[biome] or 1) or nil
end

-- The next stage is bought only once the last unlocked one is the best place to farm: a stage the team
-- cannot farm is cash thrown away (the first live run spent 313K on Cavern 2 and 3 at 875 dps). A biome
-- is bought as soon as its boss is dead and the cash is there. Only the last stage quotes the next one.
makeLoop("advance", ADVANCE_EVERY, function()
	local s = state()
	if not s then
		return
	end
	local st = s.derived.stage
	local fBiome, fStage = frontier(s)
	if not fBiome then
		return
	end
	local gold = spendable(s)
	local at = st.biome == fBiome and st.stage == fStage
	local toBiome, toStage = bestStage(s)
	local buy = toBiome == fBiome and toStage == fStage and fStage < STAGES
	if fStage == STAGES then
		if not s.biomes.bossDefeated[fBiome] then
			local e = enemy(fBiome, fStage)
			if e and e.hp / math.max(s.derived.teamDps or 0, 1) <= BOSS_TRY then
				toBiome, toStage = fBiome, fStage -- the next biome wants this boss dead
				if at then
					step("advance", "boss of " .. fBiome)
					say("fighting the boss of " .. fBiome)
				end
			end
		else
			for _, gate in ipairs(s.derived.stage.biomeGates) do
				if gate.requiresBossOf == fBiome and not gate.unlocked and (gate.goldCost or 0) <= gold then
					toBiome, toStage, buy = fBiome, fStage, true
				end
			end
		end
	end
	local nxt = st.next
	if buy and at and nxt and not nxt.locked and (nxt.cost or 0) <= gold then
		step("advance", "StageNext")
		local r = call("StageNext", nil)
		if r.ok then
			say(("unlocked %s %s for %s"):format(tostring(nxt.biome), tostring(nxt.stage), fmt(nxt.cost or 0)))
		else
			refused("StageNext", r)
		end
		return
	end
	if toBiome and (toBiome ~= st.biome or toStage ~= st.stage) then
		step("advance", "StageSelect " .. toBiome .. " " .. toStage)
		local r = call("StageSelect", { biomeId = toBiome, stage = toStage })
		if not r.ok then
			refused("StageSelect", r)
		end
	end
end)

makeLoop("rebirth", ADVANCE_EVERY, function()
	local s = state()
	if not s or not s.rebirth.canRebirth then
		return
	end
	step("rebirth", "Rebirth")
	local r = call("Rebirth", { expectedCount = s.rebirth.count })
	if r.ok then
		say("rebirth " .. tostring((s.rebirth.count or 0) + 1))
		first("rebirth took", tostring(r.message))
	else
		refused("Rebirth", r)
	end
end)

-- claims ---------------------------------------------------------------------
local function claimed(action, payload, what)
	step("claim", what)
	local r = call(action, payload)
	if r.ok then
		stats.claims += 1
		say("claimed " .. what)
	else
		refused(action, r)
	end
	return r.ok
end

makeLoop("claim", CLAIM_EVERY, function()
	local s = state()
	if not s then
		return
	end
	local t = now()
	if s.daily.canClaim then
		claimed("ClaimDaily", {}, "daily")
	end
	for _, tier in ipairs(PTC.TIERS) do
		if s.playtime.claimed[tier.tier] == false and t >= s.playtime.sessionStart + tier.minutes * 60 then
			claimed("ClaimPlaytime", { tier = tier.tier }, "playtime " .. tier.minutes .. "m")
		end
	end
	-- wheel.freeAt is when the last free spin was TAKEN (0 = never); the next one is a day later
	local spun = s.wheel.freeAt or 0
	if spun == 0 or spun + WHEEL_FREE <= t then
		claimed("SpinWheel", {}, "free wheel spin")
	end
	local quest = s.derived.activeQuest
	if quest and s.quests.completed[quest] and not s.quests.claimed[quest] then
		claimed("ClaimQuest", { questId = quest }, "quest " .. quest)
	end
	for _, kind in ipairs({ "daily", "weekly" }) do
		local timed = s.timedQuests[kind]
		for slot, q in ipairs(timed and timed.quests or {}) do
			if q.done and not q.claimed then
				claimed("ClaimTimedQuest", { kind = kind, slot = slot }, kind .. " quest " .. tostring(q.id))
			end
		end
		local season = s.season.quests and s.season.quests[kind]
		for slot, q in ipairs(season and season.quests or {}) do
			if q.done and not q.claimed then
				if claimed("ClaimSeasonQuest", { kind = kind, slot = slot }, "season " .. kind .. " quest " .. tostring(q.id)) then
					call("ClaimAllSeason", {}) -- the xp may have opened a reward; "nothing to claim" is fine
				end
			end
		end
	end
	for _, m in ipairs(QC.COLLECTION_MILESTONES) do
		if not m.auto and (s.derived.collectionCount or 0) >= m.count and not s.collection.milestonesClaimed[m.key] then
			claimed("ClaimCollectionMilestone", { milestone = m.count }, "collection " .. m.count)
		end
	end
	if (s.offline.gold or 0) > 0 then
		claimed("ClaimOffline", {}, "offline cash")
	end
end)

-- fuse and salvage -----------------------------------------------------------
local salvageOn = { on = false }
local salvageRarity = {}
local keepFree = 5

local function salvageList(s)
	local list = {}
	for id, pet in pairs(s.pets) do
		if idle(pet)
			and not pet.locked
			and pet.variant == "Normal"
			and (pet.stars or 0) == 0
			and salvageRarity[rarityOf(pet.species)]
			and pet.species ~= s.rebirth.nextRequiredPet
		then
			local st = s.derived.petStats[id]
			list[#list + 1] = { id = id, dps = st and st.dps or 0 }
		end
	end
	table.sort(list, function(a, b)
		return a.dps < b.dps
	end)
	local ids = {}
	for i = 1, math.min(#list, SALVAGE_BATCH) do
		ids[i] = list[i].id
	end
	return ids
end

makeLoop("pets", PETS_EVERY, function()
	local s = state()
	if not s or inRun(s) then
		return
	end
	local stacks, stack = {}, nil
	for _, pet in pairs(s.pets) do
		if not SC.isAway(pet) and not pet.locked then
			local key = pet.species .. "|" .. pet.variant .. "|" .. tostring(pet.stars or 0)
			stacks[key] = (stacks[key] or 0) + 1
			if stacks[key] == 5 then
				stack = pet.species
			end
		end
	end
	if stack then
		step("pets", "FuseAllPets")
		local r = call("FuseAllPets", {})
		if r.ok then
			stats.fused += 1
			needEquip = true
			say("fused a stack of " .. stack)
			return -- the state moved: salvage looks again next pass
		elseif r.code ~= "NothingToDo" then
			refused("FuseAllPets", r)
		end
		-- "nothing to do" = a five the server will not fuse (fielded pets): fall through, or a stack
		-- like that starves the salvage below for good (it did, in the first state-table run)
	end
	if salvageOn.on and (s.derived.freePetSlots or 99) <= keepFree then
		local ids = salvageList(s)
		if #ids > 0 then
			step("pets", "SalvagePets " .. #ids)
			local r = call("SalvagePets", { petIds = ids })
			if r.ok then
				stats.salvaged += #ids
				say(("salvaged %d idle pets"):format(#ids))
			else
				refused("SalvagePets", r)
			end
		else
			first("storage full, nothing to salvage", "tick more rarities, or fuse / lock by hand")
		end
	end
end)

-- trips, food ----------------------------------------------------------------
makeLoop("trips", TRIPS_EVERY, function()
	local s = state()
	if not s or needEquip then
		return
	end
	local t, out, back = now(), 0, false
	for _, trip in pairs(s.expeditions.trips) do
		out += 1
		if (trip.endsAt or math.huge) <= t then
			back = true
		end
	end
	if back then
		step("trips", "ClaimAllExpeditions")
		local r = call("ClaimAllExpeditions", {})
		if r.ok then
			stats.claims += 1
			say("claimed the expeditions that came back")
			out = 0 -- send again below
		else
			refused("ClaimAllExpeditions", r)
		end
	end
	if out < 3 then -- ExpeditionConfig.SLOTS
		for _, pet in pairs(s.pets) do
			if idle(pet) then
				step("trips", "SendAllExpeditions")
				local r = call("SendAllExpeditions", {})
				if r.ok then
					say("sent idle pets on expeditions")
				elseif r.code ~= "NothingToDo" and r.code ~= "NotFound" then
					refused("SendAllExpeditions", r)
				end
				break
			end
		end
	end
end)

makeLoop("feed", FEED_EVERY, function()
	local s = state()
	if not s then
		return
	end
	local bestId, bestDps
	for id, pet in pairs(s.pets) do
		local st = s.derived.petStats[id]
		if SC.isPlaced(pet) and st and (not bestDps or st.dps > bestDps) then
			bestId, bestDps = id, st.dps
		end
	end
	if not bestId then
		return
	end
	for foodId, count in pairs(s.inventory.foods) do
		if count > 0 then
			step("feed", foodId)
			local r = call("FeedPet", { petId = bestId, foodId = foodId, all = true })
			if r.ok then
				local d = r.data or {}
				say(("fed %s x%s: level %s"):format(foodId, tostring(d.used), tostring(d.toLevel)))
			else
				refused("FeedPet", r)
			end
		end
	end
end)

-- One potion at a time per boost: a second one only queues behind the first.
makeLoop("potion", FEED_EVERY, function()
	local s = state()
	if not s then
		return
	end
	local t = now()
	for potionId, count in pairs(s.inventory.potions) do
		local item = POC.ITEMS[potionId]
		local boost = item and s.boosts[item.boostId]
		if count > 0 and item and not (boost and (boost.endsAt or 0) > t) then
			step("potion", potionId)
			local r = call("UsePotion", { potionId = potionId, count = 1 })
			if r.ok then
				say("used " .. potionId)
			else
				refused("UsePotion", r)
			end
		end
	end
end)

-- dungeon --------------------------------------------------------------------
local dungeonGap = 15 -- minutes between runs
local nextRun = 0

local function goHome(loop, alive)
	step(loop, "the game's HOME teleport")
	call("Teleport", { to = "Plot" })
	task.wait(TELEPORT_SETTLE)
	local r, m = root(), merchant()
	if r and m then
		step(loop, "walk to the merchant")
		local away = flat(r.Position - m)
		local goal = m + (away.Magnitude > 1 and away.Unit or Vector3.new(1, 0, 0)) * MERCHANT_STAND
		walkTo(Vector3.new(goal.X, r.Position.Y, goal.Z), 2.5, WALK_TIMEOUT, alive)
	end
end

makeLoop("dungeon", DUNGEON_TICK, function(alive)
	local s = state()
	if not s or os.clock() < nextRun or inRun(s) then
		return
	end
	local ran = claim(function()
		step("dungeon", "the game's HUB teleport")
		call("Teleport", { to = "Hub" })
		task.wait(TELEPORT_SETTLE)
		local at = portal()
		if not at then
			first("dungeon portal not found", "no DungeonEnterPrompt under workspace.Map")
			goHome("dungeon", alive)
			return
		end
		step("dungeon", "walk to the portal")
		walkTo(at, 9, 30, alive)
		step("dungeon", "EnterDungeon")
		local r = call("EnterDungeon", {})
		if not r.ok then
			refused("EnterDungeon", r)
			goHome("dungeon", alive)
			return
		end
		call("DungeonReady", { ready = true }) -- skips the 20s team pick
		stats.runs += 1
		local t0 = os.clock()
		task.wait(2)
		while alive() and os.clock() - t0 < DUNGEON_MAX do
			local now2 = state()
			local run = now2 and now2.derived.dungeon.run
			if not run then
				break
			end
			step("dungeon", "run, stage " .. tostring(run.stage))
			say("dungeon stage " .. tostring(run.stage))
			task.wait(2)
		end
		local after = state()
		if after and after.derived.dungeon.run then
			step("dungeon", "LeaveDungeon")
			call("LeaveDungeon", {})
			task.wait(TELEPORT_SETTLE)
		end
		say("dungeon run over, best stage " .. tostring(after and after.derived.dungeon.bestStage))
		goHome("dungeon", alive)
	end)
	if ran then
		nextRun = os.clock() + dungeonGap * 60
	end
end)

makeLoop("climb", 30, function()
	local s = state()
	local ac = s and s.derived.autoClimb
	if not ac or inRun(s) then
		return
	end
	if ac.done then
		step("climb", "ClaimAutoClimb")
		local r = call("ClaimAutoClimb", {})
		if r.ok then
			stats.claims += 1
			say("claimed the auto-climb")
		else
			refused("ClaimAutoClimb", r)
		end
	elseif not ac.active and not ac.blocked then
		step("climb", "StartAutoClimb")
		local r = call("StartAutoClimb", {})
		if r.ok then
			say("auto-climb started")
		else
			refused("StartAutoClimb", r)
		end
	end
end)

-- The raid boss opens for 5 minutes every 30 (WorldBossRules.phaseAt). The client's own "Teleport"
-- button sends EnterWorldBoss { teleport = true }, so no walk to the portal is needed.
local bossSlot -- the slot we already entered, or gave up on
makeLoop("boss", DUNGEON_TICK, function(alive)
	local s = state()
	if not s or inRun(s) then
		return
	end
	local t = now()
	local phase, _, win = WBR.phaseAt(t)
	if phase ~= "Open" or win.slot == bossSlot or t >= win.cutoffAt then
		return
	end
	claim(function()
		step("boss", "EnterWorldBoss")
		local r = call("EnterWorldBoss", { teleport = true })
		bossSlot = win.slot
		if not r.ok then
			refused("EnterWorldBoss", r)
			return
		end
		first("EnterWorldBoss took", tostring(win.bossId))
		call("WorldBossReady", { ready = true }) -- skips the 12s team pick
		stats.runs += 1
		task.wait(3)
		while alive() and now() < win.closesAt + 120 do
			local cur = state()
			if not cur or not cur.derived.worldBoss.inFight then
				break
			end
			step("boss", "raid boss fight")
			say("raid boss fight")
			task.wait(2)
		end
		say("raid boss over")
		goHome("boss", alive)
	end)
end)

-- watchdog -------------------------------------------------------------------
local watching = true
task.spawn(function()
	while watching do
		task.wait(5)
		for name, m in pairs(marks) do
			if loops[name] and loops[name].on and os.clock() - m[2] > WATCHDOG and m[1] ~= "pass" then
				warn(("[rollpets] %s stuck %ds at: %s"):format(name, os.clock() - m[2], m[1]))
				m[2] = os.clock()
			end
		end
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Roll for Pets to Fight", statusBar = true })
if not Window then
	watching = false
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "dices")
local Farm = Tab:AddLeftGroupbox("Roll and Buy", "dices")
local Cash = Tab:AddLeftGroupbox("Loot", "coins")
local Up = Tab:AddRightGroupbox("Progress", "trending-up")
local More = Window:AddTab("Extras", "gift")
local Rewards = More:AddLeftGroupbox("Rewards", "gift")
local Pets = More:AddLeftGroupbox("Pets", "paw-print")
local Dungeon = More:AddRightGroupbox("Dungeon", "swords")

local function toggle(box, idx, text, tip, loopName)
	return box:AddToggle(idx, {
		Text = text,
		Tooltip = tip,
		Default = false,
		Callback = function(on)
			loops[loopName].set(on)
		end,
	})
end

local function setFrom(set)
	return function(picked)
		table.clear(set)
		for k in pairs(ticked(picked)) do
			set[k] = true
		end
		table.clear(judged) -- re-judge the offers on the pedestals against the new filter
	end
end

toggle(Farm, "Roll", "Auto Roll", "Pulls the lever the moment the server's cooldown is up", "roll")
toggle(Farm, "Buy", "Auto Buy", "Buys a revealed offer that passes any filter below, when you can pay. The pet your next rebirth asks for is always bought", "buy")
toggle(Farm, "Equip", "Auto Equip Best", "The game's own Equip Best after every buy, fuse and new pen slot", "equip")
Farm:AddToggle("BuyStronger", {
	Text = "Buy: stronger than my weakest",
	Tooltip = "An offer that would out-damage your weakest fielded pet, or any offer while a pen slot is free",
	Default = true,
	Callback = function(on)
		buyOn.stronger = on
		table.clear(judged)
	end,
})
Farm:AddToggle("BuyNew", {
	Text = "Buy: species I never owned",
	Tooltip = "Fills the collection (milestone rewards and discovery luck)",
	Default = true,
	Callback = function(on)
		buyOn.new = on
		table.clear(judged)
	end,
})
Farm:AddDropdown("BuyRarity", {
	Text = "Buy: always these rarities",
	Values = RARITIES,
	Default = {},
	Multi = true,
	Callback = setFrom(rarityOn),
})
Farm:AddDropdown("BuyVariant", {
	Text = "Buy: always these variants",
	Values = VARIANTS,
	Default = {},
	Multi = true,
	Callback = setFrom(variantOn),
})

toggle(Cash, "Loot", "Auto Collect + Sell", "Chest to bag to merchant every 10s. Walks you to the merchant (the server sells only inside 16 studs) and back whenever you drift", "loot")
Cash:AddInput("Reserve", {
	Text = "Keep this much cash",
	Default = "0",
	Numeric = true,
	Finished = true,
	Callback = function(text)
		reserve = math.max(0, tonumber(text) or 0)
	end,
})

toggle(Up, "Upgrade", "Auto Upgrade", "Tree nodes and pens from the game's own quotes, best payback first among what you can pay", "upgrade")
toggle(Up, "Advance", "Auto Advance", "Farms the unlocked stage that pays most, buys the next stage, kills the boss when the team can, unlocks the next biome", "advance")
toggle(Up, "Rebirth", "Auto Rebirth", "Rebirths when the game says you can. Resets cash and loot, keeps everything else", "rebirth")

toggle(Rewards, "Claim", "Auto Claim", "Daily, playtime, free wheel spin, quests, timed and season quests, collection milestones, offline cash", "claim")
toggle(Rewards, "Trips", "Auto Expeditions", "Sends idle pets on expeditions and claims the ones that are back", "trips")
toggle(Rewards, "Feed", "Auto Feed", "Every food you hold goes into your strongest fielded pet", "feed")
toggle(Rewards, "Potion", "Auto Potions", "Uses a potion you hold whenever its boost is not running", "potion")

toggle(Pets, "Fuse", "Auto Fuse", "The game's own Fuse All when a stack of five exists. Also runs Salvage below when that is on", "pets")
Pets:AddToggle("Salvage", {
	Text = "Salvage when storage is full",
	Tooltip = "DELETES the weakest idle pets of the rarities below for crystals. Never a locked pet, a variant, a starred pet, a fielded pet or one on a trip. Needs Auto Fuse on",
	Default = false,
	Risky = true,
	Callback = function(on)
		salvageOn.on = on
	end,
})
Pets:AddDropdown("SalvageRarity", {
	Text = "Rarities to salvage",
	Values = RARITIES,
	Default = { "Common", "Uncommon" },
	Multi = true,
	Callback = function(picked)
		table.clear(salvageRarity)
		for k in pairs(ticked(picked)) do
			salvageRarity[k] = true
		end
	end,
})
salvageRarity.Common, salvageRarity.Uncommon = true, true -- Default does not fire the callback
Pets:AddInput("KeepFree", {
	Text = "Salvage at this many free slots",
	Default = "5",
	Numeric = true,
	Finished = true,
	Callback = function(text)
		keepFree = math.max(0, tonumber(text) or 5)
	end,
})

toggle(Dungeon, "Dungeon", "Auto Dungeon", "HUB teleport, walk to the portal, run until the team falls, then home to the merchant. Selling pauses while you are inside", "dungeon")
Dungeon:AddInput("DungeonGap", {
	Text = "Minutes between runs",
	Default = "15",
	Numeric = true,
	Finished = true,
	Callback = function(text)
		dungeonGap = math.max(0, tonumber(text) or 15)
		nextRun = 0
	end,
})
toggle(Dungeon, "Climb", "Auto-Climb (idle)", "Starts the game's idle Auto-Climb and claims it when it is done", "climb")
toggle(Dungeon, "Boss", "Auto Raid Boss", "Joins the raid boss when it opens (5 minutes every half hour), then home to the merchant. Skipped while a dungeon run is on", "boss")

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
	local s = state()
	if not s then
		return
	end
	pcall(Window.SetStatus, Window, {
		{ "Cash", fmt(s.currencies.Gold or 0) },
		{ "Crystals", fmt(s.currencies.Crystals or 0) },
		{ "Stage", tostring(s.derived.stage.biome) .. " " .. tostring(s.derived.stage.stage) },
		{ "Rolls", stats.rolls },
		{ "Bought", stats.bought },
		{ "Sold", fmt(stats.sold) },
		{ "Upg", stats.upgrades },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("RollForPetsToFight", {})

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
end

Library:OnUnload(function()
	stopAll()
	getgenv().rollPetsStop = nil
end)

getgenv().rollPetsStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().rollPetsStop = nil
end
