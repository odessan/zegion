--[[ Turret Defense -- roll, buy, place and upgrade turrets, run the waves, all off the wire (100641654440407)

     ROLL    : fires the lever's own RandomizerRoll remote and buys whatever the reply lists that
               is worth a slot. Rolling costs nothing (probed), only the buy does, so this never
               walks to the lever. "Worth a slot" = there is room for it on your plot, or (Replace
               on) it out-damages your weakest placed turret by SWAP_MARGIN. "Buy these rarities"
               narrows that to the rarities you tick (all ticked by default).
     PLACE   : puts every unplaced turret on a spot the game's own PlacementValidator accepts --
               the same module the server checks with, so a spot it approves is one the server
               approves. No camera, no cursor, no character movement.
     REPLACE : removes the weakest placed turret for a better one. Off by default: RemoveItemEvent
               was never probed. The first swap checks the turret came back to your inventory and
               switches itself off if it did not.
     WAVES   : Auto Wave starts the run when it is stopped and turns on the game's own server-side
               auto-wave (turned back off when you stop). Speed 1x/2x; 3x is a product, not wired.
     UPGRADE : Rolls, Luck and Plot use the game's own cost tables. Turrets buys levels 5 at a time
               (the server takes exactly 1 or 5) at the game's exact price, best damage-per-cash first.
     SWORD   : equips your best sword and fires SwordHitEvent at a rate you set while a run is on.
               The server doesn't hold it to the client's ~0.7s swing (probed at 11/s).
     CRATES  : opens each crate when its timer ends (the server rechecks the timer) and refills free
               slots with the best ticked type you can pay for. Swords feed Auto Sword and the Index.
     CLAIM   : Index milestones (permanent Damage / Cash / XP / Luck), the daily reward, the free offline
               reward. Buy-for-Index also buys a turret you have never owned, since the turret
               milestones count discoveries.

     Probed and dead: OpenCrate before the timer, UpgradeTurret with any amount but 1 or 5,
     PurchaseTurret (no answer), repeat daily / offline / tutorial claims (deduped or pay nothing).
     Not wired on purpose: PromptSkipTimer (crate skip), the teaser turret (slot 7, dev product
     3709853791), SetWaveSpeed(3) (Owns3xSpeed), AdminActionEvent, TravelToWorld (swaps your save slot).

     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().turretDefenseStop() ]]

-- config ---------------------------------------------------------------------
-- The roll gap walks DOWN from a safe value: a call inside the server's cooldown is
-- dropped with no reply, which reads as "no reply" below and backs the gap off by 1.5x;
-- every reply nudges it 3% lower. It settles just above the real limit.
local ROLL_GAP_START = 1.0
local ROLL_GAP_MIN = 0.25
local ROLL_GAP_MAX = 6
local ROLL_REPLY = 3 -- how long to wait for the roll's reply before calling it dropped

local INVOKE_TIMEOUT = 8 -- InvokeServer has no timeout; give up on it after this long
local CONFIRM = 2.5 -- how long to wait for the world to show a placement / level / removal
local GRID = 4 -- PlacementValidator.GRID_SIZE; the game snaps placements to it
local SLOT_REFRESH = 20 -- re-scan the plot for build slots this often (a plot upgrade may add some)
local INV_REFRESH = 30 -- backstop re-read of the inventory, in case an update was missed
local ARRANGE_EVERY = 10 -- retry placing leftover turrets this often (each try scans the plot's slots)

-- A fresh turret has to beat the weakest placed one by this much before it swaps in.
-- Levels are ignored in the comparison (a level-40 basic vs a new one), so keep it loose.
local SWAP_MARGIN = 1.5
local UPGRADE_GAP = 1 -- seconds between upgrade passes
local UPGRADE_BATCH = 5 -- levels per UpgradeTurret call. The server honours exactly 1 or 5:
-- probed 25 and 100, both silently ignored, no refusal toast either.
local INDEX_EVERY = 30 -- seconds between Index milestone sweeps
local CLAIM_DAILY_EVERY = 600 -- the server answers "Already claimed today" (probed), so this is cheap
local DISCOVER_SPEND = 0.25 -- Buy-for-Index only takes a new turret costing at most this share of your cash
local CRATE_MARGIN = 1.5 -- seconds past a crate's timer before OpenCrate. The server rechecks the
-- timer ("Crate is not ready yet!", probed), so there is nothing to gain by going early.
local CRATE_RETRY = 30 -- seconds before retrying a crate type the server didn't sell
local WAVE_GRACE = 6 -- seconds the run must sit stopped before Auto Wave restarts it. The
-- server's own auto-wave may restart it first, and ToggleWaveState is a toggle -- firing
-- on top of that would stop it again.
local WAVE_SPEED = 2 -- 1 or 2; 3 is a paid product
local SWORD_RATE = 10 -- swings per second. Probed clean at 11/s; higher is untested, and the
-- server sees every one, so raise it only as far as the hits keep counting.
local AFK_EVERY = 60
local BOARD_REFRESH = 1

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().turretDefenseStop then
	getgenv().turretDefenseStop() -- re-running must not stack a second panel or a second loop
end

-- world ----------------------------------------------------------------------
local Events = ReplicatedStorage:WaitForChild("Events", 10)
local Functions = ReplicatedStorage:WaitForChild("Functions", 10)
local Modules = ReplicatedStorage:WaitForChild("Modules", 10)
if not (Events and Functions and Modules) then
	warn("[TurretDefense] no ReplicatedStorage.Events/Functions/Modules -- wrong game, or it hasn't replicated yet")
	return
end

-- These modules are shared with the server, so the prices, cooldowns and the placement
-- rules are the real ones and a balance patch costs nothing.
local function req(name)
	local m = Modules:WaitForChild(name, 5) -- always a timeout; an infinite yield is a hang
	local ok, mod = false, nil
	if m then
		ok, mod = pcall(require, m)
	end
	return ok and mod or nil
end
local Items = req("ItemConfigurations")
local Swords = req("SwordConfigurations") -- optional: without it Auto Sword can't rank swords
local Upg = req("UpgradeConfigurations")
local Valid = req("PlacementValidator")
local Finder = req("TurretModelFinder")
if not (Items and Upg and Valid and Finder) then
	warn("[TurretDefense] a game module didn't load (ItemConfigurations / UpgradeConfigurations / PlacementValidator / TurretModelFinder)")
	return
end

local running = true
local conns, stoppers = {}, {}
local pendingMsg, pendingStats -- drained into the panel on Heartbeat (see gui)
local function say(msg)
	pendingMsg = msg
	print("[TurretDefense] " .. msg)
end

local warned = {}
local function fire(name, ...)
	local r = Events:FindFirstChild(name)
	if not r then
		if not warned[name] then
			warned[name] = true
			warn("[TurretDefense] no remote '" .. name .. "' -- the game renamed it")
		end
		return false
	end
	return (pcall(r.FireServer, r, ...))
end

-- pcall does not bound a yield, so an invoke that never returns would park the caller
-- forever. Fire it on its own thread and stop waiting on a clock. Returns ok and the
-- packed reply (reply[1] is pcall's ok, the server's returns follow).
local function invoke(remote, ...)
	if not remote then
		return false
	end
	local args, done, out = table.pack(...), false, nil
	task.spawn(function()
		out = table.pack(pcall(remote.InvokeServer, remote, table.unpack(args, 1, args.n)))
		done = true
	end)
	local deadline = os.clock() + INVOKE_TIMEOUT
	while not done and os.clock() < deadline do
		task.wait()
	end
	if not done then
		say(remote.Name .. " never answered in " .. INVOKE_TIMEOUT .. "s -- carrying on without it")
		return false
	end
	return out[1], out
end

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function fmt(n)
	local i = 1
	while math.abs(n) >= 1000 and i < #SUFFIX do
		n /= 1000
		i += 1
	end
	if i == 1 then
		return tostring(math.floor(n))
	end
	return ("%.2f%s"):format(n, SUFFIX[i])
end
assert(fmt(999) == "999", "under a thousand prints whole")
assert(fmt(1500) == "1.50K", "thousands take the K suffix")

local function cash()
	local ls = player:FindFirstChild("leaderstats")
	local v = ls and (ls:FindFirstChild("Cash") or ls:FindFirstChild("Money"))
	return v and v.Value or 0
end

local function myPlot()
	local plots = workspace:FindFirstChild("Plots")
	if plots then
		for _, p in ipairs(plots:GetChildren()) do
			if p:GetAttribute("OwnerId") == player.UserId then
				return p
			end
		end
	end
	return nil
end

-- Damage per second at level 1. Dynamic-damage turrets (Damage = 0, a multiplier on the
-- rest of your defence) can't be scored from the config, so they rank by price.
-- ponytail: levels and modifiers are ignored, add them if the swap ever misjudges.
local function score(id)
	local c = Items[id]
	if not c then
		return 0
	end
	if (c.Damage or 0) > 0 then
		return c.Damage / math.max(c.FireRate or 1, 0.05)
	end
	return c.Price or 0
end
assert(score("Basic Turret") < score("Tesla"), "a stronger turret scores higher")

-- inventory ------------------------------------------------------------------
-- InventoryUpdated carries the whole map (the game's own PlacementHandler replaces its copy
-- with it), so the mirror is a straight assignment and never needs a per-item patch.
local inv, invAt = {}, 0
local function refreshInv()
	local ok, out = invoke(Functions:FindFirstChild("GetInventory"))
	if ok and type(out[2]) == "table" then
		inv = out[2]
	end
	invAt = os.clock()
end
table.insert(
	conns,
	Events:WaitForChild("InventoryUpdated").OnClientEvent:Connect(function(map)
		if type(map) == "table" then
			inv = map
			invAt = os.clock()
		end
	end)
)

-- placement ------------------------------------------------------------------
local slotCache = { plot = nil, at = 0, list = {} }
local function slotsOf(plot)
	if slotCache.plot ~= plot or os.clock() - slotCache.at > SLOT_REFRESH or #slotCache.list == 0 then
		local list = {}
		for _, d in ipairs(plot:GetDescendants()) do
			if d:IsA("BasePart") and d.Name == "Slot" then
				table.insert(list, d)
			end
		end
		slotCache = { plot = plot, at = os.clock(), list = list }
	end
	return slotCache.list
end

-- The game's ghost math, done over every grid cell of every build slot instead of under a
-- cursor. Validate takes the PlacementBox's CFrame; the server is sent the PRIMARY part's,
-- which is the same thing only when the box is the primary part -- so carry the offset.
local function findSpot(plot, id)
	local model = Finder.find(id)
	local box = model and model:FindFirstChild("PlacementBox")
	if not (box and box:IsA("BasePart")) then
		return nil
	end
	local size = box.Size
	local rel = model.PrimaryPart and box.CFrame:ToObjectSpace(model.PrimaryPart.CFrame) or CFrame.new()
	local slots = slotsOf(plot)
	for _, s in ipairs(slots) do
		local ss = s.Size
		for gx = 0, math.max(0, ss.X - size.X), GRID do
			for gz = 0, math.max(0, ss.Z - size.Z), GRID do
				local cf = s.CFrame * CFrame.new(gx + size.X / 2 - ss.X / 2, ss.Y / 2 + size.Y / 2, gz + size.Z / 2 - ss.Z / 2)
				if Valid.validate(plot, cf, size, slots) then
					return cf * rel
				end
			end
		end
	end
	return nil
end

local function placedList(plot)
	local out = {}
	for _, m in ipairs(plot:GetChildren()) do
		if m:IsA("Model") and m:GetAttribute("IsPlacedItem") then
			local ok, id = pcall(Finder.getItemId, m)
			id = ok and id or m.Name
			table.insert(out, { model = m, id = id, score = score(id) })
		end
	end
	return out
end

local function worstPlaced(plot)
	local worst
	for _, t in ipairs(placedList(plot)) do
		if not worst or t.score < worst.score then
			worst = t
		end
	end
	return worst
end

local function bestUnplaced()
	local best, bestScore = nil, -1
	for id, n in pairs(inv) do
		if type(n) == "number" and n > 0 and Items[id] and score(id) > bestScore then
			best, bestScore = id, score(id)
		end
	end
	return best
end

local placedTotal = 0
local function placeAt(plot, id, cf)
	local before = #placedList(plot)
	fire("PlaceItemEvent", id, cf, plot)
	local deadline = os.clock() + CONFIRM
	while os.clock() < deadline do
		if #placedList(plot) > before then
			inv[id] = math.max(0, (inv[id] or 1) - 1)
			placedTotal += 1
			return true
		end
		task.wait()
	end
	return false
end

local function placePass(plot, alive)
	local ids = {}
	for id, n in pairs(inv) do
		if type(n) == "number" and n > 0 and Items[id] then
			table.insert(ids, id)
		end
	end
	table.sort(ids, function(a, b)
		return score(a) > score(b)
	end)
	for _, id in ipairs(ids) do
		for _ = 1, inv[id] or 0 do
			if not alive() then
				return
			end
			local cf = findSpot(plot, id)
			if not cf then
				break -- no room for this footprint; a smaller turret may still fit
			end
			if not placeAt(plot, id, cf) then
				say("the server refused a placement of " .. id)
				break
			end
		end
	end
end

local replaceOn, replaceBroken = false, false
local function swapOut(worst)
	local before = inv[worst.id] or 0
	fire("RemoveItemEvent", worst.model)
	local deadline = os.clock() + CONFIRM
	while os.clock() < deadline and (worst.model.Parent ~= nil or (inv[worst.id] or 0) <= before) do
		task.wait()
	end
	if worst.model.Parent ~= nil then
		say("the server refused to remove " .. worst.id)
		return false
	end
	if (inv[worst.id] or 0) <= before then
		replaceBroken = true
		say("removing a turret did not return it to your inventory -- Replace is switched off for this session")
		return false
	end
	return true
end

-- Place what fits; then, with Replace on, trade the weakest placed turret for the best
-- unplaced one while the margin holds. Capped so one pass can't churn the whole plot.
local arrangedAt = 0
local function arrange(plot, alive)
	arrangedAt = os.clock()
	placePass(plot, alive)
	if not replaceOn or replaceBroken then
		return
	end
	for _ = 1, 8 do
		if not alive() then
			return
		end
		local best, worst = bestUnplaced(), worstPlaced(plot)
		if not (best and worst and score(best) >= score(worst.id) * SWAP_MARGIN) then
			return
		end
		if not swapOut(worst) then
			return
		end
		placePass(plot, alive)
	end
end

-- roll -----------------------------------------------------------------------
local rollReply
table.insert(
	conns,
	Events:WaitForChild("RandomizerRoll").OnClientEvent:Connect(function(results)
		rollReply = results or false -- a nil reply is the server saying no
	end)
)

local rollGap = ROLL_GAP_START
local rolls, buys, spent = 0, 0, 0
local function rollOnce(alive)
	rollReply = nil
	fire("RandomizerRoll")
	local deadline = os.clock() + ROLL_REPLY
	while rollReply == nil and os.clock() < deadline and alive() do
		task.wait()
	end
	if not rollReply then
		rollGap = math.min(ROLL_GAP_MAX, rollGap * 1.5)
		return nil
	end
	rollGap = math.max(ROLL_GAP_MIN, rollGap * 0.97)
	rolls += 1
	return rollReply
end

local function candidates(res, plot)
	local out = {}
	for i = 1, math.min(plot:GetAttribute("Rolls") or 1, 6) do
		local id = res[i]
		if type(id) == "string" and id ~= "" and id ~= "Bonus" and Items[id] then
			table.insert(out, { slot = i, id = id, score = score(id) })
		end
	end
	table.sort(out, function(a, b)
		return a.score > b.score
	end)
	return out
end

-- index ----------------------------------------------------------------------
-- The Index pays permanent Damage / Cash / XP / Luck boosts for milestones ("discover 15
-- turrets"). Discovered is the set of turrets you have owned, so the cheap way to the
-- turret milestones is to buy each new kind once.
local IC = req("IndexConfig") -- optional: without it Auto Claim skips the Index
local indexData, indexAt = nil, 0
local function refreshIndex()
	local ok, out = invoke(Functions:FindFirstChild("GetIndexData"))
	if ok and type(out[2]) == "table" then
		indexData = out[2]
	end
	indexAt = os.clock()
end
local function undiscovered(id)
	if not indexData or type(indexData.Discovered) ~= "table" then
		return false
	end
	return not indexData.Discovered[Finder.getBaseName(id)]
end
local function discoveredCount()
	local n = 0
	for _ in pairs(indexData and indexData.Discovered or {}) do
		n += 1
	end
	return n
end

-- The roll's own rarity table: which rarity each turret rolls as, and how likely it is. A variant
-- ("Flame Tesla") rolls as its base turret's rarity. ponytail: a turret in no rarity (the shop-only
-- ones) passes the filter, since it can't come out of a roll anyway.
local RC = req("RandomizerConfigurations") -- optional: without it the rarity filter is off
local rarityOf, rarityNames, rarityWanted = {}, {}, {}
for _, r in ipairs(RC and RC.Rarities or {}) do
	table.insert(rarityNames, r.Name)
	rarityWanted[r.Name] = true -- every rarity ticked = buy whatever fits, as before
	for _, t in ipairs(r.Turrets) do
		rarityOf[t] = r.Name
	end
end
local function rarityAllowed(id)
	local r = rarityOf[Finder.getBaseName(id)]
	return r == nil or rarityWanted[r] == true
end

local discoverOn = true -- Buy new turrets for the Index (armed by hand: Value = true doesn't fire the callback)
local function wantIt(plot, id)
	-- Index discoveries are bought whatever their rarity (they are capped at DISCOVER_SPEND of your cash)
	if discoverOn and undiscovered(id) and (Items[id].Price or 0) <= cash() * DISCOVER_SPEND then
		return true
	end
	if not rarityAllowed(id) then
		return false
	end
	if findSpot(plot, id) then
		return true
	end
	if not replaceOn or replaceBroken then
		return false
	end
	local worst = worstPlaced(plot)
	return worst ~= nil and score(id) >= worst.score * SWAP_MARGIN
end

local function buy(c)
	local price = (Items[c.id].Price or 0) * (player:GetAttribute("IsVIP") and 0.85 or 1)
	if cash() < price then
		return false
	end
	local held = inv[c.id] or 0
	local ok, out = invoke(Events:FindFirstChild("RandomizerPickup"), c.slot)
	if ok and out[2] == true then
		buys += 1
		spent += price
		say("bought " .. c.id .. " for " .. fmt(price))
		-- Placement reads the inventory mirror, and InventoryUpdated can land after the reply.
		-- Wait for the mirror to show the turret; re-read it if the event never comes.
		local deadline = os.clock() + CONFIRM
		while (inv[c.id] or 0) <= held and os.clock() < deadline do
			task.wait()
		end
		if (inv[c.id] or 0) <= held then
			refreshInv()
		end
		return true
	end
	if ok and out[3] then
		say("buy refused: " .. tostring(out[3]))
	end
	return false
end

local function rollPass(alive)
	local plot = myPlot()
	if not plot then
		return "couldn't find your plot"
	end
	if os.clock() - invAt > INV_REFRESH then
		refreshInv()
	end
	if IC and discoverOn and os.clock() - indexAt > INDEX_EVERY then
		refreshIndex()
	end
	local res = rollOnce(alive)
	if not res then
		return nil
	end
	for _, c in ipairs(candidates(res, plot)) do
		if not alive() then
			return nil
		end
		local wasNew = undiscovered(c.id)
		if wantIt(plot, c.id) and buy(c) then
			if wasNew then
				-- self-check: does owning it register as discovered, or only placing it?
				local before = discoveredCount()
				task.wait(0.5)
				refreshIndex()
				say(("new turret %s -- Index discovered %d -> %d"):format(c.id, before, discoveredCount()))
			end
			arrange(plot, alive)
		end
	end
	-- Anything still unplaced (bought with no room, or room freed since) gets another try on a
	-- slow beat, so a turret never waits for the next buy to be placed.
	if os.clock() - arrangedAt > ARRANGE_EVERY and bestUnplaced() then
		arrange(plot, alive)
	end
	return nil
end

-- waves ----------------------------------------------------------------------
-- Same tracking as the game's own HUD: WaveStateChanged's first argument is "a run is on".
-- It doesn't fire on join, so seed from the button's label the HUD sets.
local waveOn, stoppedAt = false, os.clock()
pcall(function()
	local btn = player.PlayerGui.GUI.HUD.Top.Buttons.WaveButton
	local label = btn:FindFirstChild("Name")
	waveOn = label ~= nil and label.Text == "Stop"
end)
table.insert(
	conns,
	Events:WaitForChild("WaveStateChanged").OnClientEvent:Connect(function(state)
		waveOn = state == true
		if not waveOn then
			stoppedAt = os.clock()
		end
	end)
)

local autoSet = false
local function wavePass(alive)
	if not waveOn and os.clock() - stoppedAt > WAVE_GRACE then
		fire("ToggleWaveState")
		local deadline = os.clock() + CONFIRM
		while not waveOn and os.clock() < deadline and alive() do
			task.wait()
		end
		stoppedAt = os.clock() -- refused or not, don't fire again for another grace period
	end
	return nil
end

-- sword ----------------------------------------------------------------------
-- SwordHitEvent carries only the tool: the server picks what gets hit. The client fires it
-- once per ~0.7s swing animation, but the server doesn't hold it to that (probed: 30 fires
-- at 11/s all counted, 36 enemy hits from 30 swings), so the swing rate is ours to set.
local weapons, equippedName = {}, nil
local function setWeapons(map, equipped)
	if type(map) == "table" then
		weapons = map
	end
	if type(equipped) == "string" then
		equippedName = equipped
	end
end
table.insert(
	conns,
	Events:WaitForChild("WeaponsInventoryUpdated").OnClientEvent:Connect(setWeapons)
)
task.spawn(function()
	local ok, out = invoke(Functions:FindFirstChild("GetWeaponsInventory"))
	if ok then
		setWeapons(out[2], out[3])
	end
end)

local function bestSword()
	local best, bestDmg = nil, -1
	for name, n in pairs(weapons) do
		local c = Swords and Swords[name]
		if type(n) == "number" and n > 0 and c and c.Damage > bestDmg then
			best, bestDmg = name, c.Damage
		end
	end
	return best
end

local function swordTool()
	local char = player.Character
	local pack = player:FindFirstChildOfClass("Backpack")
	local found
	for _, holder in ipairs({ char, pack }) do
		for _, t in ipairs(holder and holder:GetChildren() or {}) do
			if t:IsA("Tool") and t:HasTag("Sword") and (not found or t.Name == equippedName) then
				found = t
			end
		end
	end
	return found
end

local swings = 0
local function swordPass(alive)
	if not waveOn then
		task.wait(0.5) -- nothing to hit between runs
		return nil
	end
	local best = bestSword()
	if best and best ~= equippedName then
		fire("EquipWeapon", best)
		equippedName = best
		task.wait(0.5) -- the server swaps the Tool in; give it a beat
	end
	local tool = swordTool()
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not (tool and hum) then
		return nil
	end
	if tool.Parent ~= player.Character then
		pcall(hum.EquipTool, hum, tool)
	end
	if fire("SwordHitEvent", tool) then
		swings += 1
	end
	return nil
end

-- upgrades -------------------------------------------------------------------
local reserve = 0 -- cash the upgrade loops leave alone (for turret buys)

local function stepPlotUpgrade(remote, attr, costs, max)
	local plot = myPlot()
	if not plot then
		return nil
	end
	local lv = plot:GetAttribute(attr) or 1
	if lv >= max then
		return attr .. " is maxed"
	end
	local cost = costs[lv]
	if not cost or cash() - reserve < cost then
		return nil
	end
	fire(remote)
	local deadline = os.clock() + CONFIRM
	while plot:GetAttribute(attr) == lv and os.clock() < deadline do
		task.wait()
	end
	return nil
end

-- Cost of n levels starting at level lv, the game's own formula (TurretInfoHandler.canAfford).
-- Probed: 1 level of a 600-price turret cost 300, 5 levels from level 2 cost 2014 -- exact.
local function levelCost(id, lv, n)
	local price = (Items[id] and Items[id].Price) or 100
	local total = 0
	for i = 0, n - 1 do
		total += math.floor(price / 2 * math.pow(1.1, lv + i - 1))
	end
	return total
end
assert(levelCost("Improved Turret", 1, 1) == 300, "level 1 -> 2 costs half the price")
assert(levelCost("Improved Turret", 2, 5) == 2014, "matches the probed cost of five levels")

-- Best damage bought per cash first: score / cost of the next level. ponytail: assumes a level adds a
-- fixed share of base damage; swap in the real curve if the game ever exposes it.
local function turretPass(alive)
	local plot = myPlot()
	if not plot then
		return nil
	end
	local list = placedList(plot)
	for _, t in ipairs(list) do
		t.lv = t.model:GetAttribute("Level") or 1
		t.value = t.score / math.max(levelCost(t.id, t.lv, 1), 1)
	end
	table.sort(list, function(a, b)
		return a.value > b.value
	end)
	for _, t in ipairs(list) do
		if not alive() then
			return nil
		end
		local left = Upg.MaxTurretLevel - t.lv
		local n = left >= UPGRADE_BATCH and UPGRADE_BATCH or 1 -- the server takes exactly 1 or 5
		if left > 0 and cash() - reserve >= levelCost(t.id, t.lv, n) then
			fire("UpgradeTurret", t.model, n)
			local deadline = os.clock() + CONFIRM
			while (t.model:GetAttribute("Level") or 1) == t.lv and os.clock() < deadline do
				task.wait()
			end
		end
	end
	return nil
end

-- crates ---------------------------------------------------------------------
-- Every crate is a sword, and new swords count toward the Index. The timer is the server's
-- (OpenCrate early is refused), so the loop just opens what is ready and refills free slots.
local Crates = req("CrateConfigurations")
local crateWanted = { Basic = true, Volcano = true, Aquamarine = true } -- short timers by default

-- Multi dropdowns hand the callback a list, a map or row tables depending on the WindUI build.
local function ticked(values)
	local set = {}
	for k, v in pairs(values) do
		if type(v) == "string" then
			set[v] = true
		elseif type(v) == "table" and v.Title then
			set[v.Title] = true
		elseif v then
			set[k] = true
		end
	end
	return set
end
assert(ticked({ "Basic" }).Basic and ticked({ Basic = true }).Basic, "list and map forms both tick")
local crateStock, crateTried = {}, {}
if Crates then
	table.insert(
		conns,
		Events:WaitForChild("UpdateCrateStocks").OnClientEvent:Connect(function(map)
			if type(map) == "table" then
				crateStock = map
			end
		end)
	)
end

local function crateSlots(plot)
	local out = {}
	local extras = plot:FindFirstChild("PlotExtras")
	local folder = extras and extras:FindFirstChild("ChestSlots")
	for _, s in ipairs(folder and folder:GetChildren() or {}) do
		local n = tonumber(s.Name:match("^Slot(%d+)$"))
		if n then
			local chest
			for _, m in ipairs(s:GetChildren()) do
				if m:IsA("Model") then
					chest = m
				end
			end
			table.insert(out, { n = n, chest = chest })
		end
	end
	return out
end

local function cratePass(alive)
	local plot = myPlot()
	if not (Crates and plot) then
		return nil
	end
	local free = 0
	for _, s in ipairs(crateSlots(plot)) do
		local c = s.chest
		if c and c.Parent then
			local at, dur = c:GetAttribute("PlacedAt"), c:GetAttribute("TimerDuration")
			if at and dur and os.time() >= at + dur + CRATE_MARGIN then
				fire("OpenCrate", s.n)
				local deadline = os.clock() + CONFIRM
				while c.Parent ~= nil and os.clock() < deadline and alive() do
					task.wait()
				end
			end
		else
			free += 1
		end
	end
	if free == 0 then
		return nil
	end
	local kinds = {}
	for name, cfg in pairs(Crates) do
		if crateWanted[name] then
			table.insert(kinds, { name = name, price = cfg.Price or 0 })
		end
	end
	table.sort(kinds, function(a, b)
		return a.price > b.price -- the best crate you can pay for
	end)
	for _, k in ipairs(kinds) do
		local stock = crateStock[k.name]
		local retryOk = os.clock() - (crateTried[k.name] or -1e9) > CRATE_RETRY
		if (stock == nil and retryOk or (stock or 0) > 0) and cash() - reserve >= k.price then
			fire("PurchaseCrate", k.name)
			crateTried[k.name] = os.clock()
			local deadline = os.clock() + CONFIRM
			local sold = false
			while not sold and os.clock() < deadline and alive() do
				local now = 0
				for _, s in ipairs(crateSlots(plot)) do
					if not (s.chest and s.chest.Parent) then
						now += 1
					end
				end
				sold = now < free
				task.wait()
			end
			if sold then
				say("bought a " .. k.name .. " crate")
			end
			return nil
		end
	end
	return nil
end

-- claims ---------------------------------------------------------------------
-- Milestones are checked with the game's own IsComplete, so a new milestone in a patch is
-- picked up for free. The daily reward and the offline reward are one-shot on the server
-- (probed: a second claim is refused / pays nothing), so a slow beat is plenty.
local claimOn, dailyAt = false, -1e9
table.insert(
	conns,
	Events:WaitForChild("ShowOfflineReward").OnClientEvent:Connect(function()
		if claimOn then
			fire("ClaimOfflineReward") -- the free claim; the 5x version is a product and isn't touched
		end
	end)
)

local function claimPass(alive)
	if IC then
		refreshIndex()
		for _, m in ipairs(IC.Milestones) do
			if not alive() or not indexData then
				return nil
			end
			local claimed = type(indexData.Claimed) == "table" and indexData.Claimed[m.Id]
			local ok, done = pcall(IC.IsComplete, m, indexData)
			if ok and done and not claimed then
				local sent, out = invoke(Functions:FindFirstChild("ClaimIndexReward"), m.Id)
				if sent and out[2] then
					say(("Index %s claimed: +%s%% %s"):format(m.Id, tostring(m.Reward.Percent), m.Reward.Kind))
				end
				task.wait(0.5)
			end
		end
	end
	if os.clock() - dailyAt > CLAIM_DAILY_EVERY then
		dailyAt = os.clock()
		local sent, out = invoke(Events:FindFirstChild("ClaimDailyReward"))
		if sent and out[2] == true then
			say("daily reward claimed")
		end
	end
	return nil
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window = panel({ game = "Turret Defense", folder = "TurretDefense", size = UDim2.fromOffset(520, 440) })
if not Window then
	running = false
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	return
end

-- A looping toggle with its own generation counter: off-then-on inside one delay can't
-- leave the old thread alive, and only the current generation may switch the row off.
local function loopToggle(sec, opts)
	local on, gen, row = false, 0, nil
	local function kill()
		on = false
		gen += 1
		if opts.off then
			opts.off()
		end
	end
	row = sec:Toggle({
		Title = opts.title,
		Desc = opts.desc,
		Value = false,
		Callback = function(state)
			if not state then
				kill()
				return
			end
			on = true
			gen += 1
			local mine = gen
			if opts.on then
				opts.on()
			end
			local function alive()
				return running and on and gen == mine
			end
			task.spawn(function()
				while alive() do
					local ok, why = pcall(opts.body, alive)
					if not ok then
						warn("[TurretDefense] " .. opts.title .. ": " .. tostring(why))
					elseif why and alive() then
						-- the loop asked to stop, with a reason the user should read
						kill()
						pcall(row.Set, row, false)
						say(why)
						return
					end
					task.wait(opts.delay())
				end
			end)
		end,
	})
	table.insert(stoppers, kill)
	return row
end

local Farm = Window:Tab({ Title = "Farm", Icon = "solar:home-2-bold" })
local line = Farm:Paragraph({ Title = "Status", Desc = "idle" })
local board = Farm:Paragraph({ Title = "Board", Desc = "-" })

local rollSec = Farm:Section({ Title = "Turrets", Icon = "solar:refresh-circle-bold", Box = true, BoxBorder = true, Opened = true })
loopToggle(rollSec, {
	title = "Auto Roll & Buy",
	desc = "Rolls from anywhere, buys turrets that fit or beat your weakest, places them",
	on = function()
		rollGap = ROLL_GAP_START
		if next(inv) == nil then
			task.spawn(refreshInv)
		end
	end,
	body = rollPass,
	delay = function()
		return rollGap
	end,
})
rollSec:Toggle({
	Title = "Replace weaker turrets",
	Desc = "Removes your weakest placed turret for a better roll. Untested remove: checks the first swap and turns itself off if the turret was lost",
	Value = false,
	Callback = function(state)
		replaceOn = state
		if state then
			replaceBroken = false
		end
	end,
})

if RC and #rarityNames > 0 then
	local odds = {}
	for _, r in ipairs(RC.Rarities) do
		table.insert(odds, ("%s %.4g%%"):format(r.Name, r.Weight / RC.TotalWeight * 100))
	end
	rollSec:Dropdown({
		Title = "Buy these rarities",
		Desc = "Rolls keep coming, but only turrets of a ticked rarity are bought. Base odds at Luck 1: " .. table.concat(odds, ", "),
		Values = rarityNames,
		Value = rarityNames,
		Multi = true,
		AllowNone = true,
		Callback = function(picked)
			table.clear(rarityWanted)
			for k in pairs(ticked(picked)) do
				rarityWanted[k] = true
			end
		end,
	})
end
rollSec:Toggle({
	Title = "Buy new turrets for the Index",
	Desc = "Buys a turret you've never owned when it costs up to a quarter of your cash, even with no room for it and whatever its rarity. The Index pays permanent boosts",
	Value = true,
	Callback = function(state)
		discoverOn = state
	end,
})

local waveSec = Farm:Section({ Title = "Waves", Icon = "solar:bolt-circle-bold", Box = true, BoxBorder = true, Opened = true })
waveSec:Dropdown({
	Title = "Wave speed",
	Desc = "3x is a paid product and isn't offered",
	Values = { "1x", "2x" },
	Value = WAVE_SPEED .. "x",
	Callback = function(v)
		local n = ({ ["1x"] = 1, ["2x"] = 2 })[v]
		if n then
			WAVE_SPEED = n
			if autoSet then
				fire("SetWaveSpeed", n)
			end
		end
	end,
})
loopToggle(waveSec, {
	title = "Auto Wave",
	desc = "Starts the run when it is stopped and turns on the game's own auto-wave (off again when you stop)",
	on = function()
		autoSet = true
		fire("SetAutoWave", true)
		fire("SetWaveSpeed", WAVE_SPEED)
	end,
	off = function()
		if autoSet then
			autoSet = false
			fire("SetAutoWave", false) -- server state: it outlives this panel unless told
		end
	end,
	body = wavePass,
	delay = function()
		return 1
	end,
})

local swordSec = Farm:Section({ Title = "Sword", Icon = "solar:bolt-circle-bold", Box = true, BoxBorder = true, Opened = true })
swordSec:Input({
	Title = "Swings per second",
	Desc = "The server counts every swing, faster than you can by hand. 1-30",
	Value = tostring(SWORD_RATE),
	Placeholder = tostring(SWORD_RATE),
	Callback = function(v)
		SWORD_RATE = math.clamp(tonumber(v) or SWORD_RATE, 1, 30)
	end,
})
loopToggle(swordSec, {
	title = "Auto Sword",
	desc = "Equips your best sword and swings it while a run is on. Stand near the enemy path -- range is the server's call",
	body = swordPass,
	delay = function()
		return 1 / SWORD_RATE
	end,
})

local Up = Window:Tab({ Title = "Upgrades", Icon = "solar:arrow-up-bold" })
local upSec = Up:Section({ Title = "Spend", Icon = "solar:dollar-bold", Box = true, BoxBorder = true, Opened = true })
upSec:Input({
	Title = "Keep this much cash",
	Desc = "Upgrades never dip below it, so turret buys keep their money. Numbers only",
	Value = "0",
	Placeholder = "0",
	Callback = function(v)
		reserve = math.max(tonumber(v) or 0, 0)
	end,
})
local function upgradeToggle(title, desc, body)
	loopToggle(upSec, {
		title = title,
		desc = desc,
		body = body,
		delay = function()
			return UPGRADE_GAP
		end,
	})
end
upgradeToggle("Upgrade Rolls", "More turrets per roll, at the game's own price for each step", function()
	return stepPlotUpgrade("UpgradeRolls", "Rolls", Upg.RollUpgradeCosts, Upg.MaxRolls)
end)
upgradeToggle("Upgrade Luck", "Better odds per roll, up to the game's max luck level", function()
	return stepPlotUpgrade("UpgradeLuck", "Luck", Upg.LuckUpgradeCosts, Upg.MaxLuck)
end)
upgradeToggle("Upgrade Plot", "Plot health, so waves take longer to break you", function()
	return stepPlotUpgrade("UpgradePlotEvent", "BaseLevel", Upg.PlotUpgradeCosts, Upg.MaxPlotLevel)
end)
upgradeToggle("Upgrade Turrets", "Buys levels 5 at a time where damage per cash is best, at the game's exact price", turretPass)

local Misc = Window:Tab({ Title = "Misc", Icon = "solar:box-bold" })
local crateSec = Misc:Section({ Title = "Crates", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })
if Crates then
	local kinds = {}
	for name, cfg in pairs(Crates) do
		table.insert(kinds, { name = name, price = cfg.Price or 0 })
	end
	table.sort(kinds, function(a, b)
		return a.price < b.price
	end)
	local names = {}
	for _, k in ipairs(kinds) do
		table.insert(names, k.name)
	end
	crateSec:Dropdown({
		Title = "Crate types to buy",
		Desc = "Buys the best ticked type you can afford whenever a slot is free. Long timers hold a slot (Demon 8h, Hacker 24h)",
		Values = names,
		Value = { "Basic", "Volcano", "Aquamarine" },
		Multi = true,
		AllowNone = true,
		Callback = function(picked)
			table.clear(crateWanted)
			for k in pairs(ticked(picked)) do
				crateWanted[k] = true
			end
		end,
	})
	loopToggle(crateSec, {
		title = "Auto Crates",
		desc = "Opens crates the moment their timer ends and refills free slots. Swords feed Auto Sword and the Index",
		body = cratePass,
		delay = function()
			return 1
		end,
	})
end

local claimSec = Misc:Section({ Title = "Rewards", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })
loopToggle(claimSec, {
	title = "Auto Claim",
	desc = "Index milestones (permanent Damage / Cash / XP / Luck boosts), the daily reward, and the free offline reward",
	on = function()
		claimOn = true
		dailyAt = -1e9
	end,
	off = function()
		claimOn = false
	end,
	body = claimPass,
	delay = function()
		return INDEX_EVERY
	end,
})

-- The board is built on a plain thread (reads only) and handed to Heartbeat, which is the
-- one place a panel write is still allowed after a task.wait.
task.spawn(function()
	while running do
		local plot = myPlot()
		local placed = plot and #placedList(plot) or 0
		pendingStats = ("cash %s | wave %s (best %s) | placed %d | rolls %d, bought %d for %s | gap %.2fs | %s")
			:format(
				fmt(cash()),
				tostring(player:GetAttribute("CurrentWave") or "?"),
				tostring(player:GetAttribute("HighestWave") or "?"),
				placed,
				rolls,
				buys,
				fmt(spent),
				rollGap,
				waveOn and "run on" or "run stopped"
			)
		task.wait(BOARD_REFRESH)
	end
end)
table.insert(
	conns,
	RunService.Heartbeat:Connect(function()
		if pendingMsg then
			local msg = pendingMsg
			pendingMsg = nil
			pcall(function()
				line:SetDesc(msg)
			end)
		end
		if pendingStats then
			local s = pendingStats
			pendingStats = nil
			pcall(function()
				board:SetDesc(s)
			end)
		end
	end)
)

-- anti-afk -------------------------------------------------------------------
-- Idled is the last warning before the 20-minute kick; the 60s nudge keeps the timer
-- far from it in case one Idled is missed. ponytail: always on, no toggle.
local hasVU, vu = pcall(game.GetService, game, "VirtualUser")
local function nudge()
	if not hasVU then
		return
	end
	local cf = workspace.CurrentCamera and workspace.CurrentCamera.CFrame or CFrame.new()
	pcall(function()
		vu:CaptureController()
		vu:Button2Down(Vector2.new(0, 0), cf)
		task.wait(0.05)
		vu:Button2Up(Vector2.new(0, 0), cf)
	end)
end
table.insert(conns, player.Idled:Connect(nudge))
task.spawn(function()
	while running do
		task.wait(AFK_EVERY)
		nudge()
	end
end)

-- close ----------------------------------------------------------------------
local function stopAll()
	running = false
	for _, kill in ipairs(stoppers) do
		kill() -- Auto Wave's off() turns the server-side auto-wave back off
	end
	for _, c in ipairs(conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(conns)
end

Window:OnDestroy(function()
	stopAll()
	getgenv().turretDefenseStop = nil
end)
getgenv().turretDefenseStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().turretDefenseStop = nil
end

task.spawn(refreshInv)
say("ready")
