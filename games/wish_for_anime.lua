--[[ Wish for Anime -- wishes, places, collects, merges, sells, upgrades, rebirths and fights gates (106516810880035)

     WISH     : wishes the moment the server's cooldown lets it, skipping the card reveal. Measured: 6
                wishes / 20s against the game's own auto-wish's 5 (the server gap was 1.3s early in the
                session and ~3.3s later, cause unknown). Uses whatever wish you have equipped. Pauses
                the game's own auto-wish while on and hands it back after.
     PLACE    : fills empty podiums with your best cards, then swaps the weakest placed card out for a
                better one. "Best" is the server's own income number for every card (the Gates roster),
                so mutations, colossal, giant, stars and levels all count. Works from anywhere.
     COLLECT  : teleports to as few spots on your plot as cover every podium (2 for 10), collects, and
                puts you back where you were. The server only pays within ~17 studs of a podium.
     MERGE    : 5 plain copies -> 1 colossal card (3x income), from anywhere, no cutscene.
     SELL     : sells plain copies of the rarities you tick. Never mutated, colossal, giant or starred
                cards, never one that out-earns your weakest placed card, and (with Merge on) keeps 4 of
                a name for the next merge.
     UPGRADES : the three global upgrades (Money Mult, Wish Luck, Mutation Luck) and the cards on your
                podiums, cheapest payback first. Anything that pays itself back inside PAYBACK seconds is
                bought; with Rebirth on, nothing else is, so the rebirth comes first.
     REBIRTH  : rebirths as soon as you can pay, then equips the best wish you have unlocked.
     GATES    : teleports to the Battle Gates NPC, starts the deepest stage your team survives with Auto
                Replay on, and goes back. Steps down after a quick defeat, up after a long run.
     REWARDS  : every live code, daily, playtime and index tickets; quest claims on their own toggle.

     Mechanics (probed through the bridge, 2026-11-25):
       Roll("Auto"|"Manual", dice) -> ({ {name=...} }, code). code 2 = too fast, 4 = inventory full
         (500), 6 = jackpot (wants "Manual"). The dice argument is ignored: the server rolls the
         equipped one. EquipDice above your rebirth is refused (code 5).
       Place(podium) places the held Tool; Remove(podium) gives it back. UpgradeFish(podium, "single").
       Collect(podium) pays at 9/10/17 studs, refused at 18/29/39. Merge(name, giant) -> colossal.
       Sell(name, mutation, all, colossal, giant, stars) works 174 studs from the sell NPC.
       Upgrade("U_Money"); price 100 * 1.65^level (luck ones 150 * 1.65^level), +0.1 per level.
       Rebirth: price ProgressionConfig.GetRebirthPrice(rebirth); resets money only (upgrades, cards
         and card levels stay).
       TowerBattle "Start" {Stage, Team} is refused away from the Gates NPC ("Move closer"); once
         running it goes on from anywhere, and the game's own battle controller sends the per-floor
         Ready. "SetAutoReplay" true makes the server restart it after each defeat.
     Not wired: the AutoCollect / x2 speed gamepass pads, rebirth skip, every Robux product, Jackpot /
       Hacker dice buys, traits / grades / auras / stat rerolls (they spend Tickets), the quest shop,
       Gate unlocks (stage 7 costs 1000 Quest Coins, 8+ cost 1e18+ cash), Research (rebirth 30), guilds,
       trading, the pumpkin event, group reward (needs the group).

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().wishAnimeStop() ]]

-- config ---------------------------------------------------------------------
local ROLL_GAP = 1.25 -- GeneralConfig.ROLL_COOLDOWN; a reply of code 2 retries after RETRY_FAST
local RETRY_FAST = 0.25 -- the server's real gap moves (1.3s early in a session, ~3.3s later): poll for it
local FULL_WAIT = 5 -- inventory full: look again this often (Merge / Sell make room)
local REMOTE_TIMEOUT = 6 -- an InvokeServer that has not answered by now is given up on
local ROSTER_AGE = 4 -- the server's card list is re-requested once it is older than this
local PLACE_EVERY = 3
local SWAP_MARGIN = 1.15 -- swap a placed card out only for one that earns this much more
local PODIUM_BACKOFF = 60 -- a podium that refused a Place is left alone this long (locked ones)
local COLLECT_EVERY = 15 -- raise to teleport less often; the podiums keep counting meanwhile
local COLLECT_REACH = 15 -- studs from a stop to a podium's pad (paid at 17, refused at 18)
local SETTLE = 0.45 -- after a teleport, before the server is asked anything
local MERGE_EVERY = 4
local MERGE_NEED = 5 -- GeneralConfig.MERGE_REQUIRED
local SELL_EVERY = 3
local SELL_KEEP = 4 -- copies of a name kept for the next merge while Merge is on
local SELL_PER_PASS = 25
local UPGRADE_EVERY = 2
local PAYBACK = 120 -- seconds; an upgrade that pays back faster is bought even before a rebirth
local LUCK_SHARE = 0.1 -- a luck upgrade is bought when it costs at most this share of your cash
local REBIRTH_EVERY = 3
local GATE_EVERY = 8
local GATE_QUICK = 2 -- a defeat at or below this floor counts as "too hard": one stage down
local GATE_STEP_UP = 40 -- a run that reaches this floor leaves and tries one stage deeper
local GATE_RETRY = 900 -- a stage that was too hard is not tried again for this long
local REWARD_EVERY = 30
local WATCHDOG = 60 -- a loop that has not finished a pass in this long is reported in F9

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().wishAnimeStop then
	getgenv().wishAnimeStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[wishanime]", ...)
end
local said = {}
local function first(key, ...)
	if not said[key] then
		said[key] = true
		log("first", key, ...)
	end
end

-- The strip is drained from a Heartbeat (our own identity); a loop thread writing to the window
-- throws "lacking capability Plugin" after its first task.wait.
local pending, lastSaid = nil, nil
local function say(msg)
	pending = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- game -----------------------------------------------------------------------
local PS = player:WaitForChild("PlayerScripts")
local ok, Network, Remotes, CDM, TowerConfig, DiceConfig, DiceEquipment, Progression, UpgradesConfig, ItemsConfig, CodesConfig, QuestConfig, RarityOrder =
	pcall(function()
		local Shared = ReplicatedStorage.Shared
		return require(Shared.Utils.Network),
			require(Shared.Constants.Remotes),
			require(game:GetService("StarterPlayer").StarterPlayerScripts.Manager.ClientDataManager), -- the live copy (PlayerScripts' is empty)
			require(Shared.Config.TowerConfig),
			require(Shared.Config.DiceConfig),
			require(Shared.Config.DiceEquipment),
			require(Shared.Config.ProgressionConfig),
			require(Shared.Config.UpgradesConfig),
			require(Shared.Config.ItemsConfig),
			require(Shared.Config.CodesConfig),
			require(Shared.Config.QuestConfig),
			require(Shared.Constants.RarityOrder)
	end)
if not ok then
	warn("[wishanime] the game's modules did not load:", Network)
	return
end
-- The game's own controllers, for pausing its auto-wish and reading whether a gate run is live.
local RollController = select(2, pcall(require, PS.Controller.RollController))
local BattleController = select(2, pcall(require, PS.Controller.TowerBattleController))

local function data()
	return CDM:GetData()
end

local function ticked(values)
	local set = {}
	for k, v in pairs(values) do
		if type(v) == "string" then
			set[v] = true
		elseif v then
			set[k] = true
		end
	end
	return set
end
assert(ticked({ "a", "b" }).b and ticked({ a = true }).a and not ticked({ a = false }).a, "ticked reads both shapes")

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function fmt(n)
	n = tonumber(n) or 0
	local i = 1
	while n >= 1000 and i < #SUFFIX do
		n /= 1000
		i += 1
	end
	return ("%.3g"):format(n) .. SUFFIX[i]
end
assert(fmt(25000) == "25K" and fmt(88e6) == "88M" and fmt(100) == "100", "fmt")

-- InvokeServer has no timeout; a server that never answers would park the loop forever.
local function invoke(name, ...)
	local res
	local args = table.pack(...)
	task.spawn(function()
		res = table.pack(pcall(Network.InvokeServer, Network, name, table.unpack(args, 1, args.n)))
	end)
	local t0 = os.clock()
	while not res and os.clock() - t0 < REMOTE_TIMEOUT do
		task.wait()
	end
	if not res then
		first("timeout " .. tostring(name), "no answer in", REMOTE_TIMEOUT, "s")
		return nil
	end
	if not res[1] then
		first("error " .. tostring(name), res[2])
		return nil
	end
	return table.unpack(res, 2, res.n)
end
local function fire(name, ...)
	pcall(Network.FireServer, Network, name, ...)
end

local function myPlot()
	local plots = workspace:FindFirstChild("Plots")
	return plots and plots:FindFirstChild(player.Name .. "'s plot")
end
local function root()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart"), c and c:FindFirstChildOfClass("Humanoid")
end
local function cash()
	local d = data()
	return d and tonumber(d.Money) or 0
end
local function cps()
	return tonumber(player:GetAttribute("CardIncomePerSecond")) or 0
end

-- One character, several loops that teleport it: Collect and Gates take turns.
local busy = false
local function claim(fn)
	while busy do
		task.wait(0.1)
	end
	busy = true
	local okc, err = pcall(fn)
	busy = false
	if not okc then
		warn("[wishanime] move failed:", err)
	end
end

local function tp(pos)
	local hrp = root()
	if not hrp then
		return false
	end
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.CFrame = CFrame.new(pos)
	task.wait(SETTLE)
	hrp = root()
	return hrp ~= nil and (hrp.Position - pos).Magnitude < 8
end

-- roster ---------------------------------------------------------------------
-- The server's card list: every card (Inventory:{GUID} / PlacedItems:<podium>) with its real income.
local roster, rosterAt = nil, 0
local conns = {}
table.insert(
	conns,
	Network:ConnectEvent(TowerConfig.Remote, function(kind, payload)
		if kind == "Roster" and type(payload) == "table" and type(payload.Entries) == "table" then
			roster, rosterAt = payload.Entries, os.clock()
		end
	end)
)
local function getRoster()
	if os.clock() - rosterAt > ROSTER_AGE then
		local asked = os.clock()
		fire(TowerConfig.Remote, "Roster")
		while rosterAt < asked and os.clock() - asked < 4 do
			task.wait(0.05)
		end
	end
	return roster or {}
end

local function toolByGuid(guid)
	for _, t in ipairs(player.Backpack:GetChildren()) do
		if t:IsA("Tool") and t:GetAttribute("GUID") == guid then
			return t
		end
	end
	local c = player.Character
	local held = c and c:FindFirstChildWhichIsA("Tool")
	if held and held:GetAttribute("GUID") == guid then
		return held
	end
	return nil
end

local function plain(t)
	return not (t:GetAttribute("m") or t:GetAttribute("colossal") or t:GetAttribute("giant") or (tonumber(t:GetAttribute("stars")) or 0) > 0)
end

-- the loop factory -----------------------------------------------------------
-- One generation counter per row: off-then-on inside an interval must not leave two threads.
local stats = { wishes = 0, placed = 0, swapped = 0, collected = 0, merged = 0, sold = 0, upgrades = 0, rebirths = 0, gates = 0 }
local beats = {}
local loops = {}
local function makeLoop(name, every, body, onSet)
	local st = { on = false, gen = 0 }
	function st.set(on)
		st.on = on
		st.gen += 1
		local mine = st.gen
		if onSet then
			pcall(onSet, on)
		end
		if not on then
			beats[name] = nil
			return
		end
		task.spawn(function()
			local function alive()
				return st.on and st.gen == mine
			end
			while alive() do
				beats[name] = os.clock()
				local okb, err = pcall(body, alive)
				if not okb then
					warn("[wishanime] " .. name .. ":", err)
				end
				task.wait(type(every) == "function" and every() or every)
			end
		end)
	end
	loops[name] = st
	return st
end

-- wish -----------------------------------------------------------------------
local gameAutoWas = nil
local wishLoop = makeLoop("wish", 0.03, function(alive)
	local d = data()
	if not d then
		task.wait(1)
		return
	end
	local dice = DiceEquipment.GetRollDice(d)
	local mode = DiceEquipment.RequiresManualRoll(d) and "Manual" or "Auto"
	local t0 = os.clock()
	local got, code = invoke(Remotes.ROLL, mode, dice)
	if type(got) == "table" then
		stats.wishes += #got
		local wait = ROLL_GAP - (os.clock() - t0)
		if wait > 0 and alive() then
			task.wait(wait)
		end
	elseif code == 2 then
		task.wait(RETRY_FAST)
	elseif code == 4 then
		say("inventory full (500): Merge / Sell make room")
		task.wait(FULL_WAIT)
	elseif code == 6 then
		first("jackpot", "a jackpot wish wants Manual; next call sends it")
		invoke(Remotes.ROLL, "Manual", dice)
	else
		first("roll code " .. tostring(code), "dice", dice)
		task.wait(1)
	end
end, function(on)
	-- The game's auto-wish fires the same remote and would eat our cooldown.
	if type(RollController) ~= "table" then
		return
	end
	if on then
		if gameAutoWas == nil then
			gameAutoWas = RollController.autoRoll == true
		end
		RollController.autoRoll = false
	elseif gameAutoWas ~= nil then
		RollController.autoRoll = gameAutoWas
		if gameAutoWas then
			pcall(RollController.LaunchRoll, RollController)
		end
		gameAutoWas = nil
	end
end)

-- place ----------------------------------------------------------------------
local podiumBad = {}
local function podiumNames()
	local plot = myPlot()
	local out = {}
	for _, p in ipairs(plot and plot.Podiums:GetChildren() or {}) do
		out[#out + 1] = p.Name
	end
	table.sort(out, function(a, b)
		return (tonumber(a) or 0) < (tonumber(b) or 0)
	end)
	return out
end

local function placeOn(podium, entry)
	local tool = toolByGuid(entry.Id:sub(#"Inventory:" + 1))
	local _, hum = root()
	if not tool or not hum then
		return false
	end
	pcall(hum.EquipTool, hum, tool)
	task.wait(0.15)
	local placed = invoke(Remotes.PLACE, podium)
	pcall(hum.UnequipTools, hum)
	if placed then
		rosterAt = 0 -- the list changed
		return true
	end
	podiumBad[podium] = os.clock()
	first("place refused " .. podium, entry.Name)
	return false
end

local placeLoop = makeLoop("place", PLACE_EVERY, function(alive)
	local entries = getRoster()
	local placed, inv = {}, {}
	for _, e in ipairs(entries) do
		local pod = type(e.Id) == "string" and e.Id:match("^PlacedItems:(.+)$")
		if pod then
			placed[pod] = e
		elseif type(e.Id) == "string" and e.Id:find("^Inventory:") then
			inv[#inv + 1] = e
		end
	end
	table.sort(inv, function(a, b)
		return (a.Income or 0) > (b.Income or 0)
	end)
	local nextBest = 1
	for _, pod in ipairs(podiumNames()) do
		if not alive() or not inv[nextBest] then
			break
		end
		if not placed[pod] and os.clock() - (podiumBad[pod] or -1e9) > PODIUM_BACKOFF then
			if placeOn(pod, inv[nextBest]) then
				stats.placed += 1
				say(("placed %s on podium %s (%s/s)"):format(inv[nextBest].Name, pod, fmt(inv[nextBest].Income)))
				nextBest += 1
			end
		end
	end
	-- one swap per pass: the weakest placed card that is not fighting a gate
	local weakest
	for pod, e in pairs(placed) do
		if not e.InBattle and (not weakest or (e.Income or 0) < (weakest.e.Income or 0)) then
			weakest = { pod = pod, e = e }
		end
	end
	local best = inv[nextBest]
	if alive() and weakest and best and (best.Income or 0) > (weakest.e.Income or 0) * SWAP_MARGIN then
		if invoke(Remotes.REMOVE, weakest.pod) then
			task.wait(0.3)
			if placeOn(weakest.pod, best) then
				stats.swapped += 1
				say(("swapped %s (%s/s) for %s (%s/s) on podium %s"):format(weakest.e.Name, fmt(weakest.e.Income), best.Name, fmt(best.Income), weakest.pod))
			end
		end
	end
end)

-- collect --------------------------------------------------------------------
-- Fewest stops that put every filled podium's pad within reach (greedy over pads and pad midpoints).
local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end
local function planStops(pads, reach)
	local cands = {}
	for i, a in ipairs(pads) do
		cands[#cands + 1] = a.pos
		for j = i + 1, #pads do
			cands[#cands + 1] = (a.pos + pads[j].pos) / 2
		end
	end
	local left, stops = {}, {}
	for i in ipairs(pads) do
		left[i] = true
	end
	while next(left) do
		local bestC, bestSet = nil, nil
		for _, c in ipairs(cands) do
			local set = {}
			for i in pairs(left) do
				if (flat(pads[i].pos) - flat(c)).Magnitude <= reach then
					set[#set + 1] = i
				end
			end
			if not bestSet or #set > #bestSet then
				bestC, bestSet = c, set
			end
		end
		if not bestSet or #bestSet == 0 then
			break
		end
		local names = {}
		for _, i in ipairs(bestSet) do
			left[i] = nil
			names[#names + 1] = pads[i].name
		end
		stops[#stops + 1] = { pos = bestC, names = names }
	end
	return stops
end
do -- the plot as probed: two rows of five, 18 apart, pads 12 apart -> 2 stops
	local pads = {}
	for i = 0, 4 do
		pads[#pads + 1] = { name = "a" .. i, pos = Vector3.new(130, 0, -75 - 12 * i) }
		pads[#pads + 1] = { name = "b" .. i, pos = Vector3.new(148, 0, -75 - 12 * i) }
	end
	local s = planStops(pads, COLLECT_REACH)
	local n = 0
	for _, st in ipairs(s) do
		n += #st.names
	end
	assert(n == 10 and #s <= 4, "planStops covers every pad")
end

local collectLoop = makeLoop("collect", COLLECT_EVERY, function(alive)
	local plot = myPlot()
	if not plot then
		return
	end
	local pads = {}
	for _, p in ipairs(plot.Podiums:GetChildren()) do
		local pad = p:FindFirstChild("Collect")
		if pad and plot.Items:FindFirstChild(p.Name) then
			pads[#pads + 1] = { name = p.Name, pos = pad.Position }
		end
	end
	if #pads == 0 then
		return
	end
	local stops = planStops(pads, COLLECT_REACH)
	claim(function()
		local hrp = root()
		if not hrp or not alive() then
			return
		end
		local back = hrp.CFrame
		local m0 = cash()
		for _, st in ipairs(stops) do
			if not alive() then
				break
			end
			if tp(st.pos + Vector3.new(0, 3, 0)) then
				for _, name in ipairs(st.names) do
					fire(Remotes.COLLECT, name)
				end
				task.wait(0.35)
			else
				first("collect tp", "did not arrive at", st.pos)
			end
		end
		local h = root()
		if h then
			h.CFrame = back
		end
		task.wait(0.5)
		local got = cash() - m0
		if got > 0 then
			stats.collected += got
			say(("collected %s from %d podiums in %d stops"):format(fmt(got), #pads, #stops))
		end
	end)
end)

-- merge ----------------------------------------------------------------------
local mergeLoop = makeLoop("merge", MERGE_EVERY, function(alive)
	local count = {}
	for _, t in ipairs(player.Backpack:GetChildren()) do
		local n = t:IsA("Tool") and t:GetAttribute("n")
		if n and not t:GetAttribute("m") and not t:GetAttribute("colossal") and (tonumber(t:GetAttribute("stars")) or 0) == 0 then
			local key = n .. (t:GetAttribute("giant") and "|g" or "")
			count[key] = (count[key] or 0) + 1
		end
	end
	for key, n in pairs(count) do
		if not alive() then
			break
		end
		if n >= MERGE_NEED then
			local name, g = key:match("^(.-)(|?g?)$")
			local r = invoke(Remotes.MERGE, name, g == "|g")
			if type(r) == "table" and r.success then
				stats.merged += 1
				say(("merged 5 %s -> colossal%s"):format(name, g == "|g" and " giant" or ""))
				rosterAt = 0
			else
				first("merge " .. key, type(r) == "table" and r.error or r)
			end
			task.wait(0.5)
		end
	end
end)

-- sell -----------------------------------------------------------------------
local sellRarity = {}
local sellLoop = makeLoop("sell", SELL_EVERY, function(alive)
	if not next(sellRarity) then
		return
	end
	local floorIncome = math.huge -- the weakest placed card: nothing at or above it is junk
	local incomeByGuid = {}
	for _, e in ipairs(getRoster()) do
		if type(e.Id) == "string" then
			if e.Id:find("^PlacedItems:") then
				floorIncome = math.min(floorIncome, e.Income or 0)
			else
				incomeByGuid[e.Id:sub(#"Inventory:" + 1)] = e.Income or 0
			end
		end
	end
	if floorIncome == math.huge then
		return -- nothing placed yet: Place gets first pick, sell nothing
	end
	local copies, plainCount = {}, {}
	for _, t in ipairs(player.Backpack:GetChildren()) do
		local n = t:IsA("Tool") and t:GetAttribute("n")
		local item = n and ItemsConfig.Items[n]
		if item and plain(t) then
			plainCount[n] = (plainCount[n] or 0) + 1
			if sellRarity[item.Rarity] and (incomeByGuid[t:GetAttribute("GUID")] or math.huge) < floorIncome then
				copies[n] = (copies[n] or 0) + 1
			end
		end
	end
	local merging = loops.merge.on
	local keep = merging and SELL_KEEP or 0
	local done = 0
	for n, c in pairs(copies) do
		if merging and plainCount[n] >= MERGE_NEED then
			continue -- Merge takes these first; selling now would race it for the same copies
		end
		for _ = 1, c - keep do
			if not alive() or done >= SELL_PER_PASS then
				return
			end
			fire(Remotes.SELL, n, nil, false, false, false, nil)
			done += 1
			stats.sold += 1
			task.wait(0.2)
		end
	end
	if done > 0 then
		say(("sold %d junk cards"):format(done))
	end
end)

-- upgrades -------------------------------------------------------------------
local GLOBAL = { "U_Money", "U_RollLuck", "U_MutationLuck" }
local globalOn = {}
local podiumUpOn = false
local function reserve()
	local d = data()
	if loops.rebirth and loops.rebirth.on and d then
		return Progression.GetRebirthPrice(tonumber(d.Rebirth) or 0) or 0
	end
	return 0
end
-- Buy when it pays back inside PAYBACK seconds, or when the cash above the rebirth reserve covers it.
local function affordable(price, payback)
	local m = cash()
	if price > m then
		return false
	end
	return (payback and payback <= PAYBACK) or m - price >= reserve()
end

local upgradeLoop = makeLoop("upgrade", UPGRADE_EVERY, function(alive)
	for _ = 1, 15 do -- up to 15 purchases a pass, re-ranked after each
		if not alive() then
			return
		end
		local d = data()
		if not d then
			return
		end
		local best -- { kind, id, price, score }: lowest payback first; luck has none and scores PAYBACK
		for _, id in ipairs(GLOBAL) do
			local cfg = UpgradesConfig[id]
			local lvl = tonumber(d.Upgrades and d.Upgrades[id]) or 0
			if globalOn[id] and cfg and lvl < (cfg.Max or 90) then
				local price = cfg.GetPrice(lvl)
				local payback, okBuy
				if id == "U_Money" then
					local gain = cps() * 0.1 / (1 + 0.1 * lvl) -- +0.1 on a multiplier that is 1 + 0.1 * level
					payback = gain > 0 and price / gain or math.huge
					okBuy = affordable(price, payback)
				else
					payback = math.huge
					okBuy = price <= cash() * LUCK_SHARE and affordable(price, nil)
				end
				local score = payback < math.huge and payback or PAYBACK
				if okBuy and (not best or score < best.score) then
					best = { kind = "global", id = id, price = price, score = score }
				end
			end
		end
		if podiumUpOn then
			local plot = myPlot()
			local income = {}
			for _, e in ipairs(getRoster()) do
				local pod = type(e.Id) == "string" and e.Id:match("^PlacedItems:(.+)$")
				if pod then
					income[pod] = e.Income or 0
				end
			end
			for _, p in ipairs(plot and plot.Podiums:GetChildren() or {}) do
				local bm = p:FindFirstChild("Buy/Max")
				local price = bm and tonumber(bm:GetAttribute("Cost"))
				local lvl = bm and tonumber(bm:GetAttribute("Level")) or 1
				if price and price > 0 and income[p.Name] and lvl < 100 then
					local gain = income[p.Name] * 0.04 / (1 + 0.04 * (lvl - 1))
					local payback = gain > 0 and price / gain or math.huge
					if affordable(price, payback) and (not best or payback < best.score) then
						best = { kind = "podium", id = p.Name, price = price, score = payback }
					end
				end
			end
		end
		if not best then
			return
		end
		local okUp
		if best.kind == "global" then
			okUp = invoke(Remotes.UPGRADE, best.id)
		else
			okUp = invoke(Remotes.UPGRADE_FISH, best.id, "single")
		end
		if not okUp then
			first("upgrade refused " .. best.id, fmt(best.price))
			return
		end
		stats.upgrades += 1
		say(("upgraded %s for %s"):format(best.kind == "global" and best.id or ("podium " .. best.id), fmt(best.price)))
		task.wait(0.25)
	end
end)

-- rebirth --------------------------------------------------------------------
local function bestDice(d)
	local best, order = nil, -1
	for name, cfg in pairs(DiceConfig.Dice) do
		if not cfg.LegacyOnly and DiceEquipment.IsPermanent(d, name) and (cfg.Order or 0) > order then
			best, order = name, cfg.Order or 0
		end
	end
	return best
end
local rebirthLoop = makeLoop("rebirth", REBIRTH_EVERY, function()
	local d = data()
	if not d then
		return
	end
	local want = bestDice(d)
	if want and DiceEquipment.GetActive(d) ~= want and DiceEquipment.GetQueuedDice(d) == nil then
		if invoke(Remotes.EQUIP_DICE, want) then
			say("equipped " .. want)
		end
	end
	local r = tonumber(d.Rebirth) or 0
	local price = Progression.GetRebirthPrice(r)
	if price and cash() >= price then
		local okR, code = invoke(Remotes.REBIRTH)
		if okR then
			stats.rebirths += 1
			say(("rebirth %d -> %d for %s"):format(r, r + 1, fmt(price)))
		elseif code == 3 then
			say("rebirth limit reached")
		else
			first("rebirth code " .. tostring(code), fmt(price))
		end
	end
end)

-- gates ----------------------------------------------------------------------
local gate = { run = nil, floor = 0, stage = nil, tooHard = {}, startedAt = 0, note = "off" }
table.insert(
	conns,
	Network:ConnectEvent(TowerConfig.Remote, function(kind, p)
		if type(p) ~= "table" then
			return
		end
		if kind == "Started" then
			gate.run, gate.floor, gate.stage = p.Run, 0, p.Stage
		elseif kind == "FloorCleared" and p.Run == gate.run then
			gate.floor = tonumber(p.Floor) or gate.floor
		elseif kind == "Finished" and p.Run == gate.run then
			if p.Reason == "Defeated" and (tonumber(p.Floor) or 0) <= GATE_QUICK and p.Stage then
				gate.tooHard[p.Stage] = os.clock()
			end
			if not p.Replaying then
				gate.run = nil
			end
		elseif kind == "Rejected" then
			gate.note = tostring(p.Message)
		end
	end)
)
local function gateNpc()
	local ev = workspace:FindFirstChild("FishFightEvent")
	local part = ev and ev:FindFirstChild("Gates", true)
	return part and part:IsA("BasePart") and part.Position or nil
end
local function stagePick()
	local d = data()
	local pick
	for _, s in ipairs(TowerConfig.Stages) do
		if TowerConfig.IsStageOpen(s) and TowerConfig.IsUnlocked(s, d) and os.clock() - (gate.tooHard[s.Id] or -1e9) > GATE_RETRY then
			pick = s.Id -- the deepest one that is open, unlocked and not recently too hard
		end
	end
	return pick
end
local function gateActive()
	return type(BattleController) == "table" and BattleController.Active == true
end
local function leaveGate()
	fire(TowerConfig.Remote, "SetAutoReplay", false)
	local run = gate.run or (type(BattleController) == "table" and BattleController.run)
	if run then
		fire(TowerConfig.Remote, "Leave", { Run = run })
	end
end

local gateLoop = makeLoop("gates", GATE_EVERY, function(alive)
	if gateActive() then
		-- the current stage keeps losing on floor 0 under Auto Replay: leave so the pick goes one down
		if gate.stage and os.clock() - (gate.tooHard[gate.stage] or -1e9) < GATE_RETRY then
			leaveGate()
			gate.note = gate.stage .. " too hard, stepping down"
		elseif gate.floor >= GATE_STEP_UP and gate.stage then
			local pick = stagePick()
			local deeper
			for i, s in ipairs(TowerConfig.Stages) do
				if s.Id == gate.stage and TowerConfig.Stages[i + 1] and TowerConfig.IsUnlocked(TowerConfig.Stages[i + 1], data()) then
					deeper = TowerConfig.Stages[i + 1].Id
				end
			end
			if deeper and deeper == pick then
				leaveGate()
				gate.note = ("floor %d on %s, trying %s"):format(gate.floor, gate.stage, deeper)
			end
		else
			gate.note = ("%s floor %d"):format(tostring(gate.stage), gate.floor)
		end
		return
	end
	local stage, npc = stagePick(), gateNpc()
	if not stage or not npc then
		gate.note = not npc and "Gates NPC not loaded" or "no stage open"
		return
	end
	local team = {}
	local entries = table.clone(getRoster())
	table.sort(entries, function(a, b)
		return (a.Power or 0) > (b.Power or 0)
	end)
	for i = 1, math.min(TowerConfig.TeamSize or 3, #entries) do
		team[i] = entries[i].Id
	end
	if #team == 0 then
		return
	end
	claim(function()
		local hrp = root()
		if not hrp or not alive() then
			return
		end
		local back = hrp.CFrame
		if tp(npc + Vector3.new(-1.5, 3, -1)) then
			gate.run = nil
			fire(TowerConfig.Remote, "Start", { Stage = stage, Team = team })
			local t0 = os.clock()
			while not gate.run and os.clock() - t0 < 6 do
				task.wait(0.1)
			end
		end
		local h = root()
		if h then
			h.CFrame = back
		end
	end)
	if gate.run then
		fire(TowerConfig.Remote, "SetAutoReplay", true)
		fire(TowerConfig.Remote, "SetHidden", { Run = gate.run, Hidden = true })
		stats.gates += 1
		gate.note = "started " .. stage
		say("gate started: " .. stage)
	else
		first("gate start", stage, gate.note)
	end
end, function(on)
	if not on then
		leaveGate()
		gate.note = "off"
	end
end)

-- rewards --------------------------------------------------------------------
local codesTried = {}
local lastIndex = 0
local rewardLoop = makeLoop("rewards", REWARD_EVERY, function()
	local d = data() or {}
	local redeemed = d.RedeemedCodes or {}
	for code, cfg in pairs(CodesConfig) do
		if type(cfg) == "table" and not cfg.Expired and not codesTried[code] and not redeemed[code] and not table.find(redeemed, code) then
			codesTried[code] = true
			local okC, msg = invoke(Remotes.REDEEM_CODE, code)
			log("code", code, okC, msg)
		end
	end
	local function findTable(...)
		for i = 1, select("#", ...) do
			local v = select(i, ...)
			if type(v) == "table" then
				return v
			end
		end
		return nil
	end
	local daily = findTable(invoke(Remotes.DAILY_REWARD, "Status"))
	if daily and daily.CanClaim then
		log("daily", invoke(Remotes.DAILY_REWARD, "Claim"))
	end
	local p = table.pack(invoke(Remotes.PLAYTIME_REWARD, "Status")) -- (true, nil, secondsLeft, rewardName, claimed)
	local left = tonumber(p[3])
	if left and left <= 0 and p[5] ~= true then
		log("playtime", invoke(Remotes.PLAYTIME_REWARD, "Claim"))
	end
	if os.clock() - lastIndex > 300 then
		lastIndex = os.clock()
		invoke(Remotes.CLAIM_INDEX_TICKETS)
	end
end)

local questLoop = makeLoop("quests", REWARD_EVERY, function(alive)
	local snap = invoke(QuestConfig.Remote, "Snapshot")
	if type(snap) ~= "table" or type(snap.Periods) ~= "table" then
		return
	end
	for period, pd in pairs(snap.Periods) do
		for id, q in pairs(pd.Quests or {}) do
			if alive() and q.Complete and not q.Claimed then
				local r = invoke(QuestConfig.Remote, "Claim", period, id, pd.Cycle)
				say(("quest %s %s: %s"):format(period, id, type(r) == "table" and tostring(r.Message) or tostring(r)))
			end
		end
	end
end)

-- watchdog: a loop that has not started a pass in WATCHDOG seconds is parked in a yield
task.spawn(function()
	while true do
		task.wait(10)
		for name, t in pairs(beats) do
			if os.clock() - t > WATCHDOG then
				warn("[wishanime] stuck:", name, "no pass for", math.floor(os.clock() - t), "s")
				beats[name] = os.clock()
			end
		end
		if not next(loops) then
			break
		end
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Wish for Anime", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "sparkles")
local Farm = Tab:AddLeftGroupbox("Wish & plot", "sparkles")
local Cards = Tab:AddLeftGroupbox("Cards", "layers")
local Spend = Tab:AddRightGroupbox("Spend", "trending-up")
local Extra = Tab:AddRightGroupbox("Gates & rewards", "swords")

local function toggle(box, idx, text, tip, loop)
	box:AddToggle(idx, {
		Text = text,
		Tooltip = tip,
		Default = false,
		Callback = function(state)
			pcall(loop.set, state)
		end,
	})
end

toggle(Farm, "Wish", "Auto Wish", "Wishes on the server's 1.25s cooldown with your equipped wish. Pauses the game's own auto-wish while on", wishLoop)
toggle(Farm, "Place", "Auto Place best", "Fills empty podiums with your best cards and swaps the weakest placed card for a better one (server's own income numbers). From anywhere", placeLoop)
toggle(Farm, "Collect", "Auto Collect", "Teleports to as few spots on your plot as reach every podium, collects, and puts you back. Every " .. COLLECT_EVERY .. "s", collectLoop)

toggle(Cards, "Merge", "Auto Merge", "5 plain copies of a card -> 1 colossal (3x income). From anywhere", mergeLoop)
toggle(Cards, "Sell", "Auto Sell junk", "Sells plain copies of the ticked rarities. Never mutated, colossal, giant or starred cards, never one that beats your weakest placed card; keeps 4 for the next merge while Merge is on", sellLoop)
local rarities = {}
for name, v in pairs(RarityOrder) do
	if type(v) == "number" then
		rarities[#rarities + 1] = name
	end
end
table.sort(rarities, function(a, b)
	return RarityOrder[a] < RarityOrder[b]
end)
local SELL_DEFAULT = { "Common", "Uncommon" }
for _, r in ipairs(SELL_DEFAULT) do
	sellRarity[r] = true -- Default does not fire the callback
end
Cards:AddDropdown("SellRarity", {
	Text = "Sell rarities",
	Values = rarities,
	Default = SELL_DEFAULT,
	Multi = true,
	Callback = function(picked)
		table.clear(sellRarity)
		for r in pairs(ticked(picked)) do
			sellRarity[r] = true
		end
	end,
})

toggle(Spend, "Upgrade", "Auto Upgrade", "Buys the ticked upgrades below, cheapest first. Anything paying back inside " .. PAYBACK .. "s is bought; with Rebirth on, nothing else", upgradeLoop)
local upValues = { "Money Mult", "Wish Luck", "Mutation Luck", "Podium cards" }
local upIds = { ["Money Mult"] = "U_Money", ["Wish Luck"] = "U_RollLuck", ["Mutation Luck"] = "U_MutationLuck" }
local UP_DEFAULT = { "Money Mult", "Podium cards" }
globalOn.U_Money, podiumUpOn = true, true
Spend:AddDropdown("UpgradeKinds", {
	Text = "Upgrade",
	Values = upValues,
	Default = UP_DEFAULT,
	Multi = true,
	Callback = function(picked)
		local set = ticked(picked)
		table.clear(globalOn)
		for label, id in pairs(upIds) do
			globalOn[id] = set[label] == true
		end
		podiumUpOn = set["Podium cards"] == true
	end,
})
toggle(Spend, "Rebirth", "Auto Rebirth + best wish", "Rebirths the moment you can pay (money resets; upgrades and cards stay), then equips the best wish you have unlocked", rebirthLoop)

toggle(Extra, "Gates", "Auto Gates", "Teleports to the Battle Gates NPC, starts the deepest stage your team survives with Auto Replay, and goes back. Leaves the run when turned off", gateLoop)
toggle(Extra, "Rewards", "Auto Rewards", "Live codes, daily, playtime and index tickets", rewardLoop)
toggle(Extra, "Quests", "Auto Quest claims", "Claims hourly, daily and weekly quests the moment they complete", questLoop)

local note, nextStrip = "idle", 0
table.insert(
	conns,
	RunService.Heartbeat:Connect(function()
		if pending then
			note, pending = pending, nil
		end
		local now = os.clock()
		if now < nextStrip then
			return
		end
		nextStrip = now + 0.5
		local d = data() or {}
		local plot = myPlot()
		pcall(Window.SetStatus, Window, {
			{ "Cash", fmt(d.Money) },
			{ "Income", fmt(cps()) .. "/s" },
			{ "Rebirth", tostring(d.Rebirth or "?") },
			{ "Wishes", stats.wishes },
			{ "Placed", ("%d/%d"):format(plot and #plot.Items:GetChildren() or 0, plot and #plot.Podiums:GetChildren() or 0) },
			{ "Bag", #player.Backpack:GetChildren() },
			{ "Merged", stats.merged },
			{ "Sold", stats.sold },
			{ "Gate", gate.note },
			{ "Now", note },
		})
	end)
)

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("WishForAnime", {})

local VirtualUser = game:GetService("VirtualUser")
table.insert(
	conns,
	player.Idled:Connect(function()
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end)
)

-- close ----------------------------------------------------------------------
local function stopAll()
	for _, st in pairs(loops) do
		pcall(st.set, false) -- Wish hands the game's auto-wish back, Gates leaves its run
	end
	table.clear(loops)
	for _, c in ipairs(conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().wishAnimeStop = nil
end)

getgenv().wishAnimeStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().wishAnimeStop = nil
end
