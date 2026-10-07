--[[ Drop a Fruit -- sell fruit, bank coins, roll + buy, upgrade, rebirth, all by remote (82132121666307)

     FRUIT   : every fruit your trees drop goes straight into the hole: FruitController's SendToHole, the
               same call a click on a fruit makes. Nothing is carried and you never move. Probed: a backlog of
               47 cleared in one pass. The steady rate is whatever your trees drop.
     COINS   : every coin of yours is collected through the game's own Coin:Collect (Replica "Collect").
               Probed +4.5 for 3 coins from where you stand.
     ROLL    : pulls the lever the moment the server's cooldown (5s / rollSpeed) is up. The result lands at
               once, so the 5s animation is never waited on. Extra pulls are dropped silently (probed).
     BUY     : buys the best slot of a roll whose rarity (and mutation, if any ticked) you picked, when you
               can pay and the backpack has room. plot.roll.buy(slot), accepted from 23 studs (probed).
               A tree your next rebirth asks for (a Lemon for rebirth 2) is bought whatever the filters say.
     EQUIP   : entity.equipBest after every buy and every 30s (probed: swapped Garlic for Cabbage).
     SELL    : when the backpack is full, sells the lowest-value unplaced tree of a ticked rarity, never one
               a rebirth still asks for (entity.sell, probed).
     UPGRADE : buys the cheapest affordable upgrade-tree node, same filter as the game's own counter (probed).
     LEVEL   : levels placed trees with the Upgrade tool, cheapest first (entity.upgrade, probed).
     REBIRTH : rebirth.perform when RebirthUtil.canRebirth says yes (coins + required trees). Not probed:
               the first one needs 50K and a Lemon.
     CRYSTALS: rebirth upgrades (Crystals), cheapest first among the ticked ones (rebirth.upgrade, probed with
               rollLuck). Each one has a rebirth requirement; canPurchase checks it.
     REWARDS : daily, playtime (claimed 1-7 live), index milestones, offline, and every code in the game's
               config (UPDATE1 probed: +675 and a luck boost). Two early playtime fires were silent; the live
               run's claims all landed, cause not pinned down.
     STARS   : during Starfall, weather.collectStar(id) for every star nobody has taken. Not probed: the
               client range-checks 5 studs, the server may too.

     Probed and dead: plot.autoRoll (the game's own auto roller) needs the autoRollMachine rebirth upgrade
     and stops at the first match without buying, so the own roller beats it.
     Movement: nothing here moves the character. The dossier rates teleports KICK-WEIGHTED; no hop was tried.

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().dropFruitStop() ]]

-- config ---------------------------------------------------------------------
local FRUIT_EVERY = 0.25 -- sweep for fruit to send; SendToHole throttles itself to 0.5s per fruit
local COIN_EVERY = 0.25 -- sweep for coins to collect
local ROLL_TICK = 0.15 -- the roll loop's beat; the pull itself waits for the server's cooldown
local ROLL_SLACK = 0.15 -- pull this long after the cooldown ends (clock skew); raise if pulls get dropped
local ROLL_RETRY = 1 -- no new result this long after a pull = dropped, pull again
local BUY_CONFIRM = 2 -- a bought tree must show up in the inventory inside this
local EQUIP_EVERY = 30 -- equip best this often even with nothing bought
local UPGRADE_EVERY = 1 -- upgrade tree, tree levels, crystals, rebirth: one look this often
local UPGRADE_BACKOFF = 10 -- a purchase the server did not take is not retried for this long
local SELL_EVERY = 2
local REWARD_EVERY = 30
local STAR_EVERY = 0.5
local WATCHDOG = 30 -- a loop whose step mark stops moving this long is reported

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().dropFruitStop then
	getgenv().dropFruitStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[dropfruit]", ...)
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
local Shared = ReplicatedStorage:WaitForChild("Shared", 15)
local ok, R, C, PDC, FC, CC, RC, UU, RU, EU, IU, IRU, Enums =pcall(function()
	local Ctl, Util = Shared.Client.Controllers, Shared.Modules.Game.Util
	return require(Shared.Remotes),
		require(Shared.Config),
		require(Ctl.Player.PlayerDataController),
		require(Ctl.Game.FruitController),
		require(Ctl.Game.CoinController),
		require(Shared.Modules.Replica.ReplicaController),
		require(Util.UpgradeUtil),
		require(Util.RebirthUtil),
		require(Util.EntityUtil),
		require(Util.InventoryUtil),
		require(Util.IndexRewardUtil),
		require(Shared.Enums)
end)
if not ok then
	warn("[dropfruit] the game's modules did not load:", R)
	return
end

local function data()
	local rep = PDC:GetReplica()
	return rep and rep.Data
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

local function rarityIndex(name)
	local e = C.Entities[name]
	local r = e and C.Rarities[e.Rarity]
	return r and r.Index or 0
end

local function sortedKeys(t, by)
	local out = {}
	for k in pairs(t) do
		out[#out + 1] = k
	end
	table.sort(out, by or function(a, b)
		return a < b
	end)
	return out
end

local RARITIES = sortedKeys(C.Rarities, function(a, b)
	return C.Rarities[a].Index < C.Rarities[b].Index
end)
local MUTATIONS = {}
for _, name in ipairs(sortedKeys(C.Mutations, function(a, b)
	return (C.Mutations[a].Index or 0) < (C.Mutations[b].Index or 0)
end)) do
	if not C.Mutations[name].Hidden then
		MUTATIONS[#MUTATIONS + 1] = name
	end
end

local stats = { fruit = 0, coins = 0, pulls = 0, bought = 0, sold = 0, upgrades = 0, levels = 0, rebirths = 0, crystals = 0, stars = 0 }

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
					warn("[dropfruit]", name, "pass threw:", err)
				end
				task.wait(every)
			end
		end)
	end
	loops[name] = L
	return L
end

-- fruit ----------------------------------------------------------------------
makeLoop("fruit", FRUIT_EVERY, function()
	for _, f in ipairs(FC:GetGrabbable()) do
		f:SendToHole()
		stats.fruit += 1
	end
end)

-- coins ----------------------------------------------------------------------
makeLoop("coins", COIN_EVERY, function()
	for _, c in ipairs(CC:GetCollectable()) do
		c:Collect()
		stats.coins += 1
	end
end)

-- roll + buy -----------------------------------------------------------------
local rarityOn, mutOn = {}, {}
local lastRollTime, lastResultId, lastPull, judged = 0, nil, 0, nil

local function rollCooldown(d)
	local speed = UU.getValue("rollSpeed", d.Upgrades, d.RebirthUpgrades)
	return C.Roll.Animation.Time / ((speed and speed > 0) and speed or 1)
end

local function invCount(d)
	local n = 0
	for _ in pairs(d.Inventory.List) do
		n += 1
	end
	return n
end

-- best slot of a result that passes the filters and that we can pay for; nil, reason otherwise
local function pickSlot(d, res)
	local anyMut = next(mutOn) ~= nil
	local missing = {} -- trees the next rebirth asks for: bought whatever the filters say
	for _, m in ipairs(RU.getMissingEntities(d) or {}) do
		missing[m.Name] = true
	end
	local best, bestKey, why = nil, nil, "no ticked rarity"
	for slot, name in ipairs(res.Entities) do
		local e = C.Entities[name]
		local mut = res.Mutations[slot]
		if e and (missing[name] or rarityOn[e.Rarity] and (not anyMut or mutOn[mut])) then
			local cost = EU.getCost(name, mut)
			if (d.Stats[cost.Type] or 0) < cost.Amount then
				why = ("can't pay %s for %s"):format(fmt(cost.Amount), name)
			else
				local key = rarityIndex(name) * 1e6 + EU.getValue(name, 1, mut)
				if not bestKey or key > bestKey then
					best, bestKey = slot, key
				end
			end
		end
	end
	return best, why
end

local buyLoop, rollLoop -- the roll loop judges the result itself when Buy is on

local function judge(d, res)
	if judged == res.Id then
		return
	end
	if IU.isBackpackFull(d) then
		return "backpack full", true -- not judged: retried once Sell makes room
	end
	judged = res.Id
	local slot, why = pickSlot(d, res)
	if not slot then
		return why
	end
	local name, mut = res.Entities[slot], res.Mutations[slot]
	local before = invCount(d)
	step("roll", "buy " .. name)
	R.plot.roll.buy:fire(slot)
	local t0 = os.clock()
	while invCount(d) <= before and os.clock() - t0 < BUY_CONFIRM do
		task.wait()
	end
	if invCount(d) > before then
		stats.bought += 1
		first("buy", name, mut)
		say(("bought %s %s (%s)"):format(mut, name, C.Entities[name].Rarity))
		if loops.equip.on then
			R.entity.equipBest:fire()
		end
	else
		warn("[dropfruit] buy not confirmed:", name, mut, "slot", slot, "coin", d.Stats.Coin)
	end
	return nil
end

local function rollPass()
	local d = data()
	if not d then
		return
	end
	local res = d.Roll and d.Roll.Result
	if res and res.Id and res.Id ~= lastResultId then
		lastResultId, lastRollTime = res.Id, res.Time
	end
	if buyLoop.on and res and res.Id then
		local why, hold = judge(d, res)
		if why then
			say("roll: " .. why)
		end
		if hold then
			return -- a full bag would throw good rolls away; wait for Sell or for you
		end
	end
	if not rollLoop.on then
		return
	end
	local ready = now() >= lastRollTime + rollCooldown(d) + ROLL_SLACK
	-- a pull that produced nothing is retried after ROLL_RETRY, so a skewed clock can't park the loop
	if (ready or os.clock() - lastPull > rollCooldown(d) + ROLL_RETRY) and os.clock() - lastPull > ROLL_RETRY then
		step("roll", "pull")
		lastPull = os.clock()
		R.plot.roll.pull:fire()
		stats.pulls += 1
	end
end
rollLoop = makeLoop("roll", ROLL_TICK, rollPass)
buyLoop = makeLoop("buy", ROLL_TICK, function()
	if not rollLoop.on then
		rollPass() -- Buy alone judges the rolls you pull by hand
	end
end)

-- equip ----------------------------------------------------------------------
makeLoop("equip", EQUIP_EVERY, function()
	R.entity.equipBest:fire()
end)

-- sell junk ------------------------------------------------------------------
local sellOn = {}
makeLoop("sell", SELL_EVERY, function()
	local d = data()
	if not (d and IU.isBackpackFull(d)) then
		return
	end
	local need = RU.getRequiredEntityCounts(d.Stats.Rebirth) or {}
	local worst, worstVal
	for id, e in pairs(d.Inventory.List) do
		local cfg = C.Entities[e.Name]
		if not e.Placed and cfg and sellOn[cfg.Rarity] and not need[e.Name] then
			local v = EU.getValue(e.Name, e.Level, e.Mutation)
			if not worstVal or v < worstVal then
				worst, worstVal = id, v
			end
		end
	end
	if not worst then
		say("bag full, nothing of a ticked rarity to sell")
		return
	end
	local e = d.Inventory.List[worst]
	step("sell", "sell " .. e.Name)
	R.entity.sell:fire({ worst })
	task.wait(1)
	if not d.Inventory.List[worst] then
		stats.sold += 1
		say(("sold %s %s (bag was full)"):format(e.Mutation, e.Name))
	end
end)

-- upgrades -------------------------------------------------------------------
local refused = {} -- id -> os.clock() before which it is not retried
local function tryBuy(key, fire, done)
	if (refused[key] or 0) > os.clock() then
		return false
	end
	fire()
	local t0 = os.clock()
	while not done() and os.clock() - t0 < 1.5 do
		task.wait()
	end
	if done() then
		return true
	end
	refused[key] = os.clock() + UPGRADE_BACKOFF
	first("refused " .. key, "backing off", UPGRADE_BACKOFF)
	return false
end

-- the game's own affordable-node filter (UpgradeUtil.getAffordableUpgradeCount)
local function treeCandidates(d)
	local out = {}
	for _, n in pairs(C.Upgrade.Tree) do
		if not n.IsAnchor and not n.IsOpener and not d.Upgrades[n.Id] and n.Cost then
			local open = (n.Dependency == nil and n.Side == Enums.Upgrade.Side.Origin)
				or UU.getDistanceFromOwned(n.Id, d.Upgrades) <= 1
			if open and (d.Stats[n.Cost.Type] or 0) >= n.Cost.Amount then
				out[#out + 1] = n
			end
		end
	end
	table.sort(out, function(a, b)
		return a.Cost.Amount < b.Cost.Amount
	end)
	return out
end

makeLoop("upgrade", UPGRADE_EVERY, function(alive)
	local d = data()
	for _, n in ipairs(treeCandidates(d)) do
		if not alive() then
			return
		end
		step("upgrade", "tree " .. n.Id)
		if
			tryBuy("tree " .. n.Id, function()
				R.upgrade:fire(n.Id)
			end, function()
				return d.Upgrades[n.Id] ~= nil
			end)
		then
			stats.upgrades += 1
			say(("upgrade %s (%s)"):format(n.Id, fmt(n.Cost.Amount)))
			return -- re-read prices next pass
		end
	end
end)

makeLoop("level", UPGRADE_EVERY, function()
	local d = data()
	if not d.Upgrades.upgradeTool then
		say("level: needs the Upgrade tool (upgrade tree, 250)")
		return
	end
	local max = EU.getMaxLevel(d.Upgrades, d.RebirthUpgrades)
	local free = EU.hasFreeUpgrade(d)
	local best, bestCost
	for id, e in pairs(d.Inventory.List) do
		if e.Placed and e.Level < max then
			local cost = EU.getUpgradeCost(e.Name, e.Level, e.Mutation)
			if (free or (d.Stats[cost.Type] or 0) >= cost.Amount) and (not bestCost or cost.Amount < bestCost) then
				best, bestCost = id, cost.Amount
			end
		end
	end
	if not best then
		return
	end
	local e = d.Inventory.List[best]
	local lvl = e.Level
	step("level", "level " .. e.Name)
	if
		tryBuy("level " .. best, function()
			R.entity.upgrade:fire(best)
		end, function()
			return d.Inventory.List[best] == nil or d.Inventory.List[best].Level > lvl
		end)
	then
		stats.levels += 1
		say(("levelled %s to %d (%s)"):format(e.Name, lvl + 1, free and "free" or fmt(bestCost)))
	end
end)

local crystalOn = {}
makeLoop("crystals", UPGRADE_EVERY, function()
	local d = data()
	local best, bestCost
	for id in pairs(crystalOn) do
		if RU.Upgrade.canPurchase(d, id) then
			local nxt = RU.Upgrade.getNextLevel(id, d.RebirthUpgrades)
			if nxt and (not bestCost or nxt.Cost.Amount < bestCost) then
				best, bestCost = id, nxt.Cost.Amount
			end
		end
	end
	if not best then
		return
	end
	local lvl = d.RebirthUpgrades[best] or 0
	step("crystals", "crystal " .. best)
	if
		tryBuy("crystal " .. best, function()
			R.rebirth.upgrade:fire(best)
		end, function()
			return (d.RebirthUpgrades[best] or 0) > lvl
		end)
	then
		stats.crystals += 1
		say(("rebirth upgrade %s -> %d (%d crystals)"):format(best, lvl + 1, bestCost))
	end
end)

makeLoop("rebirth", UPGRADE_EVERY, function()
	local d = data()
	if not RU.canRebirth(d) then
		return
	end
	local before = d.Stats.Rebirth
	step("rebirth", "perform")
	if
		tryBuy("rebirth", function()
			R.rebirth.perform:fire()
		end, function()
			local nd = data()
			return nd and nd.Stats.Rebirth > before
		end)
	then
		stats.rebirths += 1
		say(("rebirth %d -> %d"):format(before, data().Stats.Rebirth))
	end
end)

-- rewards --------------------------------------------------------------------
local triedCodes = {} -- one try per code per run; an expired code is refused for good
makeLoop("rewards", REWARD_EVERY, function()
	local d = data()
	local rw = d.Rewards
	if rw.Daily and now() - (rw.Daily.LastClaim or 0) >= C.Rewards.Daily.Time.Reset then
		R.reward.daily:fire()
		first("daily")
	end
	if d.Tutorial.Completed and rw.Playtime and rw.Playtime.Start > 0 then
		local played = now() - rw.Playtime.Start
		for i, p in ipairs(C.Rewards.Playtime) do
			if p.Time <= played and not rw.Playtime.Claimed[tostring(i)] then
				R.reward.playtime:fire(i)
				first("playtime", i)
				break
			end
		end
	end
	for mut, cfg in pairs(C.Mutations) do
		if not cfg.Hidden then
			for _, goal in ipairs(IRU.getGoals(mut)) do
				if IRU.isReady(d, goal) then
					R.reward.index:fire(goal.Key)
					first("index", goal.Key)
				end
			end
		end
	end
	for code in pairs(C.Codes.List) do
		if not d.RedeemedCodes[code] and not triedCodes[code] then
			triedCodes[code] = true
			task.spawn(function()
				local okReq, good, msg = pcall(function()
					return R.code.redeem:request(code):expect()
				end)
				log("code", code, okReq and good, msg)
			end)
			task.wait(C.Codes.Cooldown + 0.2)
		end
	end
	R.offline.claim:fire()
end)

-- stars ----------------------------------------------------------------------
makeLoop("stars", STAR_EVERY, function()
	for _, rep in pairs(RC._replicas) do
		if rep.Class == "Weather" and type(rep.Data.Stars) == "table" then
			for id, star in pairs(rep.Data.Stars) do
				if type(star) == "table" and not star.Collector then
					R.weather.collectStar:fire(id)
					stats.stars += 1
					first("star", id)
				end
			end
		end
	end
end)

-- watchdog -------------------------------------------------------------------
local watching = true
task.spawn(function()
	while watching do
		task.wait(5)
		for name, m in pairs(marks) do
			if loops[name] and loops[name].on and os.clock() - m[2] > WATCHDOG then
				warn(("[dropfruit] %s stuck %ds at: %s"):format(name, os.clock() - m[2], m[1]))
				m[2] = os.clock()
			end
		end
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Drop a Fruit", statusBar = true })
if not Window then
	watching = false
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "apple")
local Farm = Tab:AddLeftGroupbox("Farm", "apple")
local Roll = Tab:AddLeftGroupbox("Roll", "dices")
local Up = Tab:AddRightGroupbox("Upgrades", "trending-up")
local Misc = Tab:AddRightGroupbox("Extras", "gift")

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

toggle(Farm, "Fruit", "Auto Sell Fruit", "Sends every fruit your trees drop into the hole, from wherever you stand", "fruit")
toggle(Farm, "Coins", "Auto Collect Coins", "Collects every coin of yours, from wherever you stand", "coins")
toggle(Farm, "Equip", "Auto Equip Best", "Equip Best after every buy and every 30s", "equip")
toggle(Farm, "Sell", "Auto Sell Junk (bag full)", "When the backpack is full, sells the lowest-value unplaced tree of a rarity ticked below. Never one a rebirth still needs", "sell")
Farm:AddDropdown("SellRarity", {
	Text = "Rarities to sell",
	Values = RARITIES,
	Default = { "Common", "Uncommon" },
	Multi = true,
	Callback = function(picked)
		table.clear(sellOn)
		for k in pairs(ticked(picked)) do
			sellOn[k] = true
		end
	end,
})
sellOn.Common, sellOn.Uncommon = true, true -- Default does not fire the callback

toggle(Roll, "Roll", "Auto Roll", "Pulls the lever the moment the cooldown is up; skips the animation", "roll")
toggle(Roll, "Buy", "Auto Buy", "Buys the best slot whose rarity (and mutation, if any ticked) is picked below, when you can pay and the bag has room", "buy")
local rarityDefault = {}
for _, r in ipairs(RARITIES) do
	if C.Rarities[r].Index >= 3 then
		rarityDefault[#rarityDefault + 1] = r
		rarityOn[r] = true -- Default does not fire the callback
	end
end
Roll:AddDropdown("BuyRarity", {
	Text = "Rarities to buy",
	Values = RARITIES,
	Default = rarityDefault,
	Multi = true,
	Callback = function(picked)
		table.clear(rarityOn)
		for k in pairs(ticked(picked)) do
			rarityOn[k] = true
		end
		judged = nil -- re-judge the current roll against the new filter
	end,
})
Roll:AddDropdown("BuyMutation", {
	Text = "Mutations to buy (none = any)",
	Values = MUTATIONS,
	Default = {},
	Multi = true,
	Callback = function(picked)
		table.clear(mutOn)
		for k in pairs(ticked(picked)) do
			mutOn[k] = true
		end
		judged = nil
	end,
})

toggle(Up, "Upgrade", "Auto Upgrade Tree", "Buys the cheapest affordable upgrade-tree node", "upgrade")
toggle(Up, "Level", "Auto Level Trees", "Levels placed trees with the Upgrade tool, cheapest first", "level")
toggle(Up, "Rebirth", "Auto Rebirth", "Rebirths as soon as you have the coins and the trees it asks for. Resets coins", "rebirth")
toggle(Up, "Crystals", "Auto Rebirth Upgrades", "Spends Crystals on the ticked rebirth upgrades, cheapest first", "crystals")
local crystalIds = sortedKeys(C.Rebirth.Upgrade.List)
local crystalDefault = {}
for _, id in ipairs(crystalIds) do
	if id ~= "autoRollMachine" then -- the own roller does its job and also buys
		crystalDefault[#crystalDefault + 1] = id
		crystalOn[id] = true
	end
end
Up:AddDropdown("CrystalIds", {
	Text = "Rebirth upgrades to buy",
	Values = crystalIds,
	Default = crystalDefault,
	Multi = true,
	Callback = function(picked)
		table.clear(crystalOn)
		for k in pairs(ticked(picked)) do
			crystalOn[k] = true
		end
	end,
})

toggle(Misc, "Rewards", "Auto Claim Rewards", "Daily, playtime, index milestones, offline earnings and every code in the game's config", "rewards")
toggle(Misc, "Stars", "Auto Collect Stars", "During Starfall, claims every star nobody has taken (unproven: the server may want you near it)", "stars")

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
	pcall(Window.SetStatus, Window, {
		{ "Coins", fmt(d.Stats.Coin or 0) },
		{ "Crystals", tostring(d.Stats.Crystal or 0) },
		{ "Fruit", stats.fruit },
		{ "Pulls", stats.pulls },
		{ "Bought", stats.bought },
		{ "Upg", stats.upgrades + stats.levels + stats.crystals },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("DropAFruit", {})

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
	getgenv().dropFruitStop = nil
end)

getgenv().dropFruitStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().dropFruitStop = nil
end
