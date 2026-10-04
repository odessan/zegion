--[[ My Anime Mine -- chest, sell, upgrades, research, zones, index, mutations (79389059854988)

     Everything this game does goes through ONE remote, GamestateEvent:FireServer(name, ...), and the
     crew mines on its own server-side, so there is nothing to walk and nothing to hit. Each toggle
     below is a different event name, probed through the bridge unless it says UNPROVEN.

     CHEST    : MineTakeChest (no key = all) from wherever you stand, then walks to the item buyer and sells
                every ore key you hold (MineSellItems). The sale is range-gated ("Walk up to the item buyer
                to sell."): it snaps beside the SellStand, waits SELL_SETTLE, sells, snaps back. Characters
                are taken into your bag and never sold. Auto Sell is a gamepass; this is the free version.
     EQUIP    : MineEquipBest. Fired when a pickaxe was bought and every EQUIP_EVERY.
     PICKAXES : MineBuyPickaxe(index into MineConfig.Pickaxes) for the best in-stock pickaxe that beats
                your 8th best owned one. Restocks on a timer; the market is checked every MARKET_EVERY.
     TAP      : fireclickdetector on your nodes inside the detector's reach. Proven to land (a tap row in
                MineFX) but a tap is ~1e-5 of a crew hit at Z5. Off by default, kept because it was asked for.
     CHARS    : MineUpgradeCharacter(slot, "Damage" | "Speed" | "MineSpeed"), best gain per cost across all
                miner slots. Costs come from MineConfig and matched the server to the digit.
     ADAPTIVE : Equip Best ranks by what a miner does NOW, so a better character that is still level 1 never
                gets a pad (probed: it swapped a fresh Serious Baldy straight back out for a levelled Azta).
                Levels belong to the character and go into the bag with it, so a swap loses nothing. This
                finds the bagged character whose LEVEL-100 strength beats a pad's by PROMO_GAIN and whose
                catch-up cost is within PROMO_FRAC of cash, swaps it in (snap to the pad, press its
                HolderPrompt to pick up, MineEquipSlot to hold, press again to place, snap back), levels it
                first, and keeps Equip Best off until it has caught up. Needs Chars on.
     RESEARCH : MineBuySkill(zone, family, nodeId), cheapest open node of any unlocked zone first.
     ZONE     : MineSelectZone(next) once the current zone's research is 100% and the cash covers the unlock
                cost. The server refuses earlier ("Finish Voidreach's research first (33/70)."), so this
                only asks when it should work.
     CORE     : MineUpgradeTap, and MineBuyMinerSlot (UNPROVEN, slots were already 8/8).
     INDEX    : MineIndexClaim(category, tierKey, rewardIndex) for every claimable reward. UNPROVEN: nothing
                was claimable when probed. The arguments are exactly what the game's own Index screen sends.
     MUTATE   : MineRollMutation(slot) until the slot reaches the target variant. A roll REPLACES the variant
                outright and can land lower (probed: one slot went Bronze, Platinum, Bronze, Diamond, Bronze
                ... over 15 rolls), so it is a plain gamble: only slots below the target are rolled, and a slot
                stops the moment it reaches it. Expected rolls to reach a target = 1 / P(that variant or
                better): Diamond 2.5, Platinum 6, Rainbow 16, Frozen 40. The price scales with tier and with
                your research (Baldy was 1.5e24, then 4.9e26), so a roll is only taken while it costs at most
                the "Roll % of cash" input, best damage gained per cash first. Each roll is confirmed by the
                game's own MineFX "mutation" row, not by reading the save (which lags the roll).
                Odds per roll: Bronze 60%, Diamond 24%, Platinum 9.6%, Rainbow 3.8%, Frozen 1.5%.
     ALTAR    : MineRollEnchant(1) while you hold Enchanted Dice, MineEquipEnchant(slot, name) for the best
                enchant you hold. UNPROVEN: 0 dice when probed (the Index gives some; the rest is Robux).

     Spending: every purchase must cost at most "Spend %" of your cash (research gets RESEARCH_FRAC), so
     nothing empties the wallet and the zone unlock cost still builds up.

     Probed and dead (do not re-probe):
       MineSellItems from home                    refused, "Walk up to the item buyer to sell."
       Gem shop (MineGemShopBuy)                  closed until Soulforge (Z11), and 0 gems
       MineSelectZone with research unfinished    refused
       Pad prompt from home                       ignored, the server wants you within its 10 studs
       Equip Best right after a swap              reverts it, which is why Equip is paused while a promotion levels
     Not wired (Robux / not asked): Auto Sell pass, dice and scroll products, trade board, alliances,
     summon, crafting, daily spin and quests.

     RightControl opens / closes the panel. Stop: getgenv().animeMineStop() ]]

-- config ---------------------------------------------------------------------
local SELL_EVERY = 20 -- how often the chest is emptied and sold. Raise if the walk to the stand bothers you
local SELL_SETTLE = 0.6 -- after the snap beside the stand, before selling (0.6 probed). Raise if "Sold!" never lands
local SELL_CONFIRM = 3 -- the ores must leave your bag, or cash rise, inside this
local SELL_OFFSET = Vector3.new(6, 3, 0) -- where you stand relative to the SellStand
local EQUIP_EVERY = 30 -- Equip Best at least this often
local EQUIP_GAP = 3 -- ...and never closer together than this
local MARKET_EVERY = 5 -- pickaxe market check
local CONFIRM = 1.5 -- a purchase must show in your save inside this, or it is a refusal
local BACKOFF = 30 -- a purchase the server did not take is not retried for this long
local PER_PASS = 8 -- most purchases one pass makes before it yields to the others
local UPGRADE_EVERY = 1
local RESEARCH_EVERY = 1
local ZONE_EVERY = 5
local CORE_EVERY = 3
local MUTATE_EVERY = 2
local INDEX_EVERY = 30
local CLAIM_GAP = 0.7 -- the game's own Index screen waits 0.6 between claims
local ALTAR_EVERY = 10
local ALTAR_CONFIRM = 4
local TAP_GAP = 0.3 -- the server took ~5 of 10 taps fired 0.15s apart
local TAP_MARGIN = 1 -- stay this far inside the detector's MaxActivationDistance
local NODE_REFRESH = 5 -- how often the list of your nodes is rebuilt
local SPEND_PCT = 20 -- default "Spend %": one purchase costs at most this share of your cash
local RESEARCH_FRAC = 0.5 -- research is what opens the next zone, so it may take more
local MUTATE_FRAC = 0.05 -- a roll may cost at most this share of cash: 12 rolls at 20% took 85% of the wallet in 30s
local PROMO_FRAC = 0.1 -- Adaptive Equip only swaps a character in when levelling it up to the slot's strength costs at most this share of cash
local PROMO_GAIN = 1.25 -- ...and only when its level-100 strength beats the slot's level-100 strength by this factor
local PROMO_EVERY = 10 -- how often Adaptive Equip looks for a swap
local PROMO_TIMEOUT = 240 -- a promoted character that has not caught up by now is given up on (Equip Best then puts the old one back)
local PAD_OFFSET = Vector3.new(0, 4, 5) -- where you stand relative to a miner pad (the prompt reaches 10 studs, the server checks)
local PAD_SETTLE = 0.6 -- after the snap beside the pad, before pressing it
local PAD_CONFIRM = 3 -- each step of a swap must show in your save inside this
local SPEED_WEIGHT = 0.25 -- walking speed is worth this much of a damage or mine-speed point
local STUCK_AFTER = 60 -- the watchdog names a loop that has sat on one step this long

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().animeMineStop then
	getgenv().animeMineStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[mine]", ...)
end
local seen = {}
local function first(name, ...) -- the first time an unproven branch runs, say what it did
	if not seen[name] then
		seen[name] = true
		log("first", name, ...)
	end
end

-- game -----------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
local ok, GameState, MC, Items, Inventory, Stock, IndexRewards, Enchants = pcall(function()
	local M = ReplicatedStorage.Modules
	return require(M.GameState),
		require(M.MineConfig),
		require(M.Items),
		require(M.MineInventory),
		require(M.MineStock),
		require(M.MineIndexRewardsConfig),
		require(M.MineEnchantCatalog)
end)
if not Remotes or not ok then
	warn("[mine] the game's modules did not load:", GameState)
	return
end
local Event = Remotes:WaitForChild("GamestateEvent")
local Notice = Remotes:WaitForChild("SendNotification")

local function mine() -- the account and its MineGame table, nil until the save has loaded
	local d = GameState.GetData2()
	return d, d and d.MineGame
end

local function fmt(n)
	n = tonumber(n) or 0
	if n < 1e6 then
		return ("%d"):format(math.floor(n))
	end
	local e = math.floor(math.log10(n))
	return ("%.2fe%d"):format(n / 10 ^ e, e)
end
assert(fmt(999) == "999" and fmt(1.5e9) == "1.50e9" and fmt(7.6e22) == "7.60e22", "fmt")

local function minerSlots(mg) -- [{ key, holder }] for every slot that holds a miner
	local out = {}
	for key, h in pairs(mg.Holders or {}) do
		if type(key) == "string" and key:sub(1, 1) == "M" and type(h) == "table" and h.CharName then
			out[#out + 1] = { key = key, holder = h }
		end
	end
	table.sort(out, function(a, b)
		return a.key < b.key
	end)
	return out
end

-- shared state ---------------------------------------------------------------
local conns = {}
local stats = { sold = 0, taken = 0, picks = 0, ups = 0, skills = 0, zones = 0, muts = 0, claims = 0, rolls = 0, taps = 0, promos = 0 }
local promo, swapping -- the slot being levelled up after a swap { key, name, target, since }; true while a swap is under way
local spendFrac = SPEND_PCT / 100
local mutTarget = "Rainbow" -- a Rainbow Noon Pride (ceiling 7.2e17) already beats a Normal Serious Baldy (3.8e17)
local mutFrac = MUTATE_FRAC -- the "Roll % of cash" input writes this
local wantEquip, lastEquip = false, 0
local back = {} -- key -> os.clock() before which a refused purchase is not retried
local marks = {} -- loop name -> { step, since }
local pending = {} -- the panel strip is drained from a Heartbeat, never from a loop thread (lacking capability Plugin)
local lastSaid = {}
local nowNote = "idle"

local function say(name, msg)
	pending.now = name .. ": " .. msg
	if lastSaid[name] ~= msg then
		lastSaid[name] = msg
		log(name, msg)
	end
end

local function step(name, text)
	marks[name] = { text = text, at = os.clock() }
end

-- The server's own reason, kept for the log line of a refused purchase.
local lastNote = { text = "", at = -100 }
table.insert(conns, Notice.OnClientEvent:Connect(function(text)
	lastNote.text, lastNote.at = tostring(text), os.clock()
end))
local function said()
	return os.clock() - lastNote.at < 4 and ("server: " .. lastNote.text) or "no reply"
end

local warned = {}
local function refuse(key, msg) -- a refusal repeats every BACKOFF; say it once per 5 minutes
	if os.clock() - (warned[key] or -1e9) > 300 then
		warned[key] = os.clock()
		warn(msg)
	end
end

local function send(name, ...)
	local good, err = pcall(Event.FireServer, Event, name, ...)
	if not good then
		warn("[mine] send", name, err)
	end
	return good
end

local function settle(pred, secs, alive) -- poll every frame; true the moment pred is, false on timeout or stop
	local t0 = os.clock()
	while os.clock() - t0 < secs do
		if alive and not alive() then
			return false
		end
		if pred() then
			return true
		end
		task.wait()
	end
	return pred()
end

local function free(key)
	return (back[key] or 0) <= os.clock()
end

-- One toggle = one generation counter in `gens`; the body gets alive() so a long pass bails when switched off.
local gens = {}
local function runner(name, interval, body)
	return function(on)
		gens[name] = (gens[name] or 0) + 1
		marks[name] = nil
		if not on then
			return
		end
		local id = gens[name]
		task.spawn(function()
			local function alive()
				return gens[name] == id
			end
			while alive() do
				step(name, "pass")
				local good, err = pcall(body, alive)
				if not good then
					warn("[mine] " .. name .. " threw: " .. tostring(err))
				end
				step(name, "idle")
				task.wait(interval)
			end
		end)
	end
end

local running = true
task.spawn(function() -- watchdog: a parked loop cannot report, so a separate thread does
	local told = {}
	while running do
		task.wait(5)
		for name, m in pairs(marks) do
			local stuck = os.clock() - m.at
			if m.text ~= "idle" and stuck > STUCK_AFTER and told[name] ~= m.at then
				told[name] = m.at
				warn(("[mine] stuck %ds at: %s / %s"):format(stuck, name, m.text))
			end
		end
	end
end)

-- chest + sell ---------------------------------------------------------------
local function oreKeys()
	local _, mg = mine()
	local keys = {}
	if not mg then
		return keys
	end
	local order = Inventory.KindOrder and Inventory.KindOrder.OreFirst
	for _, e in ipairs(Inventory.Collect(mg, "All", order)) do
		if e.Kind == "Ore" and (e.SellCount or e.Count or 0) > 0 and (e.Worth or 0) > 0 then
			keys[#keys + 1] = e.Key
		end
	end
	return keys
end

local function sellBody(alive)
	local d, mg = mine()
	if not mg then
		return
	end
	if next(mg.Chest or {}) then
		step("Sell", "take chest")
		send("MineTakeChest")
		stats.taken += 1
		task.wait(1)
	end
	local keys = oreKeys()
	if #keys == 0 then
		say("sell", "no ores to sell")
		return
	end
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local stand = workspace:FindFirstChild("SellStand")
	if not hrp or not stand or not alive() then
		say("sell", hrp and "no SellStand" or "no character")
		return
	end
	local home, before = hrp.CFrame, d.Money
	step("Sell", "at the stand")
	pcall(function()
		hrp.CFrame = CFrame.new(stand:GetPivot().Position + SELL_OFFSET)
		task.wait(SELL_SETTLE)
		send("MineSellItems", keys)
		settle(function()
			local now = mine()
			return #oreKeys() == 0 or (now and now.Money > before)
		end, SELL_CONFIRM)
	end)
	pcall(function()
		hrp.CFrame = home -- always back, whatever happened at the stand
	end)
	local after = mine()
	if after and after.Money > before then
		stats.sold += #keys
		say("sell", ("sold %d ore kinds"):format(#keys))
	else
		say("sell", ("not paid for %d kinds (%s)"):format(#keys, said()))
	end
end

-- equip best -----------------------------------------------------------------
local function equipBody()
	if promo or swapping then
		return -- Equip Best ranks by CURRENT strength: it would put the old character straight back (probed)
	end
	if (wantEquip or os.clock() - lastEquip >= EQUIP_EVERY) and os.clock() - lastEquip >= EQUIP_GAP then
		wantEquip, lastEquip = false, os.clock()
		send("MineEquipBest")
		say("equip", "equip best sent")
	end
end

-- pickaxes -------------------------------------------------------------------
local function pickaxeBody(alive)
	for _ = 1, PER_PASS do
		local d, mg = mine()
		if not mg or not alive() then
			return
		end
		local byName = {}
		for _, def in ipairs(MC.Pickaxes) do
			byName[def.Name] = def
		end
		local n = #minerSlots(mg)
		local mults = {}
		for name, count in pairs(mg.Pickaxes or {}) do
			local def = byName[name]
			for _ = 1, math.min(tonumber(count) or 0, n) do
				if def then
					mults[#mults + 1] = def.Multiplier
				end
			end
		end
		table.sort(mults, function(a, b)
			return a > b
		end)
		local floor = mults[n] or 0 -- a pickaxe only helps if it beats the n-th best you already own
		local pick
		for i, def in ipairs(MC.Pickaxes) do
			local rem = Stock.IsStocked(def) and Stock.GetRemaining(d, def.Name) or nil -- the account table, not MineGame: it holds StockPurchases
			if
				rem
				and rem > 0
				and (mg.UnlockedZones or {})[def.ZoneReq]
				and def.Multiplier > floor
				and (tonumber(def.Cost) or math.huge) <= d.Money * spendFrac
				and free("pick" .. i)
				and (not pick or def.Multiplier > pick.def.Multiplier)
			then
				pick = { i = i, def = def }
			end
		end
		if not pick then
			say("pickaxes", ("nothing better to buy (best owned x%s)"):format(fmt(floor)))
			return
		end
		local owned = mg.Pickaxes[pick.def.Name] or 0
		step("Pickaxes", "buy " .. pick.def.Name)
		send("MineBuyPickaxe", pick.i)
		local took = settle(function()
			local _, now = mine()
			return now and (now.Pickaxes[pick.def.Name] or 0) > owned
		end, CONFIRM, alive)
		if took then
			stats.picks += 1
			wantEquip = true
			say("pickaxes", ("bought %s (x%s)"):format(pick.def.Name, fmt(pick.def.Multiplier)))
		else
			back["pick" .. pick.i] = os.clock() + BACKOFF
			refuse("pick" .. pick.i, ("[mine] pickaxe %s not bought (cost %s, cash %s, %s)"):format(pick.def.Name, fmt(pick.def.Cost), fmt(d.Money), said()))
			return
		end
		task.wait(0.2)
	end
end

-- tap ------------------------------------------------------------------------
local nodeList, nodeAt, nodeI = {}, -100, 0
local function myNodes()
	if os.clock() - nodeAt < NODE_REFRESH then
		return nodeList
	end
	nodeAt, nodeList = os.clock(), {}
	for _, m in ipairs(CollectionService:GetTagged("MineNode")) do
		local par = m.Parent
		while par and par ~= workspace and par:GetAttribute("OwnerUserId") == nil do
			par = par.Parent
		end
		if par and par ~= workspace and par:GetAttribute("OwnerUserId") == player.UserId then
			nodeList[#nodeList + 1] = m
		end
	end
	return nodeList
end

local function tapBody()
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	local list = myNodes()
	for _ = 1, #list do
		nodeI = nodeI % #list + 1
		local m = list[nodeI]
		local cd = m.Parent and m:FindFirstChild("NodeClick", true)
		if cd and cd:IsA("ClickDetector") and not m:GetAttribute("NodeBroken") then
			if (m:GetPivot().Position - hrp.Position).Magnitude <= cd.MaxActivationDistance - TAP_MARGIN then
				fireclickdetector(cd)
				stats.taps += 1
				say("tap", ("tapping %s"):format(m.Name))
				return
			end
		end
	end
	say("tap", "no node of yours in reach")
end

-- characters -----------------------------------------------------------------
local function ratio(f, level)
	local a = f(level)
	return a > 0 and f(level + 1) / a or 1
end
local UPGRADES = {
	{
		stat = "Damage",
		field = "CharLevel",
		max = MC.CharMaxLevel,
		cost = MC.GetCharacterUpgradeCost,
		gain = function(l)
			return ratio(MC.GetCharacterLevelMultiplier, l)
		end,
		weight = 1,
	},
	{
		stat = "Speed",
		field = "CharSpeedLevel",
		max = MC.CharSpeedMaxLevel,
		cost = MC.GetCharacterSpeedUpgradeCost,
		gain = function(l)
			return ratio(MC.GetCharacterSpeed, l)
		end,
		weight = SPEED_WEIGHT,
	},
	{
		stat = "MineSpeed",
		field = "CharMineSpeedLevel",
		max = MC.CharMineSpeedMaxLevel,
		cost = MC.GetCharacterMineSpeedUpgradeCost,
		gain = function(l)
			return ratio(MC.GetCharacterMineSpeed, l)
		end,
		weight = 1,
	},
}

local function charBody(alive)
	for _ = 1, PER_PASS do
		local d, mg = mine()
		if not mg or not alive() then
			return
		end
		local best
		for _, slot in ipairs(minerSlots(mg)) do
			local item = Items.GetItemData(slot.holder.CharName)
			local scaled = select(2, pcall(MC.GetHolderScaled, slot.holder))
			if item and not scaled and (not promo or promo.key == slot.key) then -- a fresh promotion gets every upgrade first
				for _, u in ipairs(UPGRADES) do
					local level = slot.holder[u.field] or 1
					local key = slot.key .. u.stat
					if level < u.max and free(key) then
						local cost = u.cost(level, item)
						local score = u.weight * math.log(u.gain(level)) / cost
						if cost <= d.Money * spendFrac and (not best or score > best.score) then
							best = { slot = slot, u = u, level = level, cost = cost, score = score, key = key }
						end
					end
				end
			end
		end
		if not best then
			say("chars", "nothing affordable")
			return
		end
		step("Chars", best.slot.key .. " " .. best.u.stat)
		send("MineUpgradeCharacter", best.slot.key, best.u.stat)
		local took = settle(function()
			local _, now = mine()
			local h = now and now.Holders[best.slot.key]
			return h and (h[best.u.field] or 1) > best.level
		end, CONFIRM, alive)
		if took then
			stats.ups += 1
			say("chars", ("%s %s -> %d"):format(best.slot.key, best.u.stat, best.level + 1))
		else
			back[best.key] = os.clock() + BACKOFF
			refuse(best.key, ("[mine] %s %s not upgraded (level %d, cost %s, cash %s, %s)"):format(best.slot.key, best.u.stat, best.level, fmt(best.cost), fmt(d.Money), said()))
		end
		task.wait(0.1)
	end
end

-- adaptive equip -------------------------------------------------------------
-- Equip Best puts the strongest miners on the pads by what they do NOW, so a character that is better
-- once levelled never gets in (a fresh Serious Baldy does 6e15 against a levelled Azta's 1.5e16). Levels
-- belong to the character and travel with it into the bag (stack key "Azta|86|Bronze|17|16"), so a swap
-- loses nothing. This promotes the character with the better CEILING, levels it up at once, and holds
-- Equip Best off meanwhile. The swap itself is the pad prompt, which the server range-checks.
local function strength(item, level, variant, mineLvl, pickMult)
	return MC.GetCharacterDamage(item)
		* MC.GetCharacterLevelMultiplier(level)
		* MC.GetVariantMult(variant)
		* pickMult
		* MC.GetCharacterMineSpeed(mineLvl)
end

local function pickMult(holder)
	local def = MC.GetHolderPickaxe(holder)
	return def and def.Multiplier or 1
end

local function slotStrength(holder, item)
	return strength(item, holder.CharLevel or 1, holder.CharVariant, holder.CharMineSpeedLevel or 1, pickMult(holder))
end

local function slotCeiling(holder, item)
	return strength(item, MC.CharMaxLevel, holder.CharVariant, MC.CharMineSpeedMaxLevel, pickMult(holder))
end

-- Cash to level a character (Damage and Mine Speed, best gain per cost first) until it matches `target`.
local function catchUp(item, level, mineLvl, variant, mult, target)
	local cost = 0
	for _ = 1, 400 do
		if strength(item, level, variant, mineLvl, mult) >= target then
			return cost
		end
		local dc = level < MC.CharMaxLevel and MC.GetCharacterUpgradeCost(level, item) or nil
		local mc = mineLvl < MC.CharMineSpeedMaxLevel and MC.GetCharacterMineSpeedUpgradeCost(mineLvl, item) or nil
		local ds = dc and math.log(ratio(MC.GetCharacterLevelMultiplier, level)) / dc or -1
		local ms = mc and math.log(ratio(MC.GetCharacterMineSpeed, mineLvl)) / mc or -1
		if not dc and not mc then
			return math.huge -- both capped and still short
		elseif ds >= ms then
			cost, level = cost + dc, level + 1
		else
			cost, mineLvl = cost + mc, mineLvl + 1
		end
	end
	return math.huge
end
assert(catchUp({ MineTier = 1 }, 1, 1, nil, 1, 0) == 0, "catchUp: already there costs nothing")

local function myPlot()
	local root = workspace:FindFirstChild("MineWorld")
	local plots = root and root:FindFirstChild("Plots")
	for _, p in ipairs(plots and plots:GetChildren() or {}) do
		if p:GetAttribute("OwnerUserId") == player.UserId then
			return p
		end
	end
	return nil
end

-- Carries one swap out. Returns whether the candidate now works the slot; any failure ends in Equip Best,
-- which re-seats everyone, so a half-finished swap never leaves a pad empty.
local function swap(best, alive)
	local plot = myPlot()
	local holders = plot and plot:FindFirstChild("Holders")
	local pad = holders and holders:FindFirstChild(best.key) and holders[best.key]:FindFirstChild("Pad")
	local prompt = pad and pad:FindFirstChild("HolderPrompt")
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not prompt or not hrp then
		return false
	end
	local function holder()
		local _, mg = mine()
		return mg and mg.Holders[best.key]
	end
	-- the candidate goes on the hotbar first, so the pad is empty for as short a time as possible
	local _, mg = mine()
	local idx = tostring(Inventory.TargetSlot(mg, best.stack))
	if (mg.Hotbar or {})[idx] ~= best.stack then
		send("MineAssignHotbar", idx, best.stack)
		if not settle(function()
			local _, m = mine()
			return (m.Hotbar or {})[idx] == best.stack
		end, PAD_CONFIRM, alive) then
			warn(("[mine] swap: %s did not reach hotbar slot %s (%s)"):format(best.stack, idx, said()))
			return false
		end
	end
	local home = hrp.CFrame
	local done = false
	swapping = true
	step("Adaptive", "at pad " .. best.key)
	pcall(function()
		hrp.CFrame = CFrame.new(pad.Position + PAD_OFFSET)
		task.wait(PAD_SETTLE)
		fireproximityprompt(prompt) -- pick the incumbent up: its levels go into the bag with it
		if not settle(function()
			local h = holder()
			return h and h.CharName == nil
		end, PAD_CONFIRM, alive) then
			return
		end
		send("MineEquipSlot", idx)
		if not settle(function()
			local _, m = mine()
			return tostring(m.Equipped) == idx
		end, PAD_CONFIRM, alive) then
			return
		end
		fireproximityprompt(prompt) -- place the held one
		done = settle(function()
			local h = holder()
			return h and h.CharName == best.name
		end, PAD_CONFIRM, alive)
	end)
	pcall(function()
		hrp.CFrame = home
	end)
	swapping = false
	if not done then
		send("MineEquipBest") -- put everyone back
		warn(("[mine] swap of %s into %s failed (%s), Equip Best asked to restore"):format(best.name, best.key, said()))
	end
	return done
end

local function promoBody(alive)
	local d, mg = mine()
	if not mg then
		return
	end
	if promo then
		local h = mg.Holders[promo.key]
		local item = h and h.CharName and Items.GetItemData(h.CharName)
		if item and h.CharName == promo.name and slotStrength(h, item) >= promo.target then
			stats.promos += 1
			say("adaptive", ("%s caught up on %s"):format(promo.name, promo.key))
			promo = nil
		elseif os.clock() - promo.since > PROMO_TIMEOUT then
			warn(("[mine] %s did not catch up on %s in %ds, giving up (Equip Best will decide)"):format(promo.name, promo.key, PROMO_TIMEOUT))
			promo = nil
		else
			say("adaptive", ("levelling %s on %s"):format(promo.name, promo.key))
		end
		return
	end
	local best
	for _, slot in ipairs(minerSlots(mg)) do
		local h = slot.holder
		local item = Items.GetItemData(h.CharName)
		local scaled = select(2, pcall(MC.GetHolderScaled, h))
		if item and not scaled then
			local target, ceiling, mult = slotStrength(h, item), slotCeiling(h, item), pickMult(h)
			for stack, count in pairs(mg.Characters or {}) do
				local name, level, variant, _, mineLvl = MC.ParseCharStack(stack)
				local cand = name and Items.GetItemData(name)
				if cand and cand.MineRole ~= "Hauler" and name ~= h.CharName and (tonumber(count) or 0) >= 1 and free("promo" .. stack .. slot.key) then
					local cCeil = strength(cand, MC.CharMaxLevel, variant, MC.CharMineSpeedMaxLevel, mult)
					if cCeil > ceiling * PROMO_GAIN then
						local cost = catchUp(cand, level, mineLvl, variant, mult, target)
						local gain = cCeil / ceiling
						if cost <= d.Money * PROMO_FRAC and (not best or gain > best.gain) then
							best = { key = slot.key, stack = stack, name = name, target = target, cost = cost, gain = gain, from = h.CharName }
						end
					end
				end
			end
		end
	end
	if not best then
		say("adaptive", "no better character worth its levelling cost")
		return
	end
	log(("adaptive: %s -> %s for %s (ceiling x%.1f, levelling to match costs %s of %s cash)"):format(best.from, best.name, best.key, best.gain, fmt(best.cost), fmt(d.Money)))
	if swap(best, alive) then
		promo = { key = best.key, name = best.name, target = best.target, since = os.clock() }
	else
		back["promo" .. best.stack .. best.key] = os.clock() + BACKOFF * 4
	end
end

-- research -------------------------------------------------------------------
local function researchBody(alive)
	for _ = 1, PER_PASS do
		local d, mg = mine()
		if not mg or not alive() then
			return
		end
		local best
		for _, zk in ipairs(MC.ZoneKeys) do
			if (mg.UnlockedZones or {})[zk] and MC.ZoneSkillNodes[zk] then
				local sk = (mg.Skills or {})[zk] or {}
				for _, node in ipairs(MC.GetSkillNodes(zk)) do
					local key = "skill" .. zk .. node.Id
					if not MC.IsSkillNodeMaxed(sk, node) and MC.IsSkillNodeOpen(sk, node) and free(key) then
						local cost = MC.GetSkillCost(zk, sk[node.Family] or 0, node.Family)
						if cost <= d.Money * RESEARCH_FRAC and (not best or cost < best.cost) then
							best = { zk = zk, node = node, cost = cost, level = sk[node.Family] or 0, key = key }
						end
					end
				end
			end
		end
		if not best then
			say("research", "nothing affordable")
			return
		end
		step("Research", best.zk .. " " .. best.node.Id)
		send("MineBuySkill", best.zk, best.node.Family, best.node.Id)
		local took = settle(function()
			local _, now = mine()
			return now and (((now.Skills or {})[best.zk] or {})[best.node.Family] or 0) > best.level
		end, CONFIRM, alive)
		if took then
			stats.skills += 1
			say("research", ("%s %s %d"):format(best.zk, best.node.Name or best.node.Id, best.level + 1))
		else
			back[best.key] = os.clock() + BACKOFF
			refuse(best.key, ("[mine] research %s %s not bought (cost %s, cash %s, %s)"):format(best.zk, best.node.Id, fmt(best.cost), fmt(d.Money), said()))
		end
		task.wait(0.1)
	end
end

-- zone -----------------------------------------------------------------------
local function zoneBody(alive)
	local d, mg = mine()
	if not mg then
		return
	end
	local cur = "Z" .. tostring(mg.CurrentZone or 1)
	local idx = table.find(MC.ZoneKeys, cur)
	local nxt = idx and MC.ZoneKeys[idx + 1]
	if not nxt then
		say("zone", "last zone")
		return
	end
	local done, total = MC.GetZoneResearchProgress(mg.Skills, cur)
	if done < total then
		say("zone", ("%s research %d/%d"):format(cur, done, total))
		return
	end
	local unlocked = (mg.UnlockedZones or {})[nxt]
	local cost = unlocked and 0 or (MC.Zones[nxt].UnlockCost or 0)
	if d.Money < cost then
		say("zone", ("research done, saving %s of %s for %s"):format(fmt(d.Money), fmt(cost), nxt))
		return
	end
	if not free("zone" .. nxt) then
		return
	end
	step("Zone", "select " .. nxt)
	send("MineSelectZone", nxt)
	local took = settle(function()
		local _, now = mine()
		return now and now.CurrentZone == idx + 1
	end, 3, alive)
	if took then
		stats.zones += 1
		say("zone", "moved to " .. nxt)
	else
		back["zone" .. nxt] = os.clock() + BACKOFF
		refuse("zone" .. nxt, ("[mine] could not move to %s (cost %s, cash %s, %s)"):format(nxt, fmt(cost), fmt(d.Money), said()))
	end
end

-- core upgrades --------------------------------------------------------------
local function coreBody(alive)
	local d, mg = mine()
	if not mg then
		return
	end
	local tap = mg.TapLevel or 1
	if tap < MC.TapMaxLevel and free("tap") then
		local cost = MC.GetTapUpgradeCost(tap)
		if cost <= d.Money * spendFrac then
			send("MineUpgradeTap")
			if settle(function()
				local _, now = mine()
				return now and (now.TapLevel or 1) > tap
			end, CONFIRM, alive) then
				say("core", "tap level " .. (tap + 1))
			else
				back.tap = os.clock() + BACKOFF
				warn("[mine] tap upgrade not bought:", said())
			end
		end
	end
	local slots = mg.MinerSlots or MC.BaseMinerSlots
	if slots < MC.MaxMinerSlots and free("slots") then
		local cost = MC.MinerSlotCosts[slots + 1]
		if cost and cost <= d.Money * spendFrac then
			first("slot", "MineBuyMinerSlot at", slots) -- UNPROVEN, slots were 8/8 when probed
			send("MineBuyMinerSlot")
			if settle(function()
				local _, now = mine()
				return now and (now.MinerSlots or 0) > slots
			end, CONFIRM, alive) then
				say("core", "miner slots " .. (slots + 1))
			else
				back.slots = os.clock() + BACKOFF
				warn("[mine] miner slot not bought:", said())
			end
		end
	end
end

-- index ----------------------------------------------------------------------
local function indexClaims(mg)
	local out = {}
	local held = IndexRewards.HeldNames(mg)
	for _, cat in ipairs(IndexRewards.Keys()) do
		local c = IndexRewards.Category(cat)
		local open = c and (c.Zone == nil or (mg.UnlockedZones or {})[cat] == true)
		if open and IndexRewards.Total(cat) > 0 then
			for _, tr in ipairs(IndexRewards.State(mg, cat, held).Track) do
				if tr.Reached then
					for i = 1, #(tr.Rewards or {}) do
						if not tr.ClaimedRewards[i] then
							out[#out + 1] = { cat, tr.Key, i }
						end
					end
				end
			end
		end
	end
	return out
end

local function indexBody(alive)
	local _, mg = mine()
	if not mg then
		return
	end
	local list = indexClaims(mg)
	if #list == 0 then
		say("index", "nothing to claim")
		return
	end
	for _, c in ipairs(list) do
		if not alive() then
			return
		end
		first("index claim", c[1], c[2], c[3]) -- UNPROVEN
		step("Index", c[1] .. " " .. tostring(c[2]))
		send("MineIndexClaim", c[1], c[2], c[3])
		stats.claims += 1
		task.wait(CLAIM_GAP)
	end
	local _, now = mine()
	local left = now and #indexClaims(now) or -1
	say("index", ("claimed %d, %d left"):format(#list, left))
	if left >= #list then
		warn(("[mine] index claims did not register (%d sent, %d still open, %s)"):format(#list, left, said()))
	end
end

-- mutation -------------------------------------------------------------------
-- The game's own MineFX "mutation" row is the roll's receipt: it names the slot, the variant before and
-- after. Other plots send the same rows, hence the plot check. (Reading the save instead races its sync.)
local mutSeen = {}
local MineFX = Remotes:WaitForChild("MineFX")
table.insert(conns, MineFX.OnClientEvent:Connect(function(p)
	if type(p) == "table" and p.t == "mutation" and p.key then
		local plot = myPlot()
		if plot and p.plot == tonumber(plot.Name:match("%d+")) then
			mutSeen[p.key] = { before = p.before, variant = p.variant, at = os.clock() }
		end
	end
end))

local function mutateBody(alive)
	for _ = 1, PER_PASS do
		local d, mg = mine()
		if not mg or not alive() then
			return
		end
		local tMult = MC.GetVariantMult(mutTarget)
		local target = MC.GetVariantRank(mutTarget)
		local pick
		for _, slot in ipairs(minerSlots(mg)) do
			local cur = MC.GetHolderVariant(slot.holder)
			local item = Items.GetItemData(slot.holder.CharName)
			local scaled = select(2, pcall(MC.GetHolderScaled, slot.holder))
			if item and not scaled and MC.GetVariantRank(cur) < target and not MC.IsSetterOnlyVariant(cur) and free("mut" .. slot.key) then
				local cost = MC.GetMutationRollCost(item, mg)
				if cost <= d.Money * mutFrac then
					-- damage gained per cash: the same roll price buys more on a character that hits harder
					local score = MC.GetCharacterDamage(item) * (tMult - MC.GetVariantMult(cur)) / cost
					if not pick or score > pick.score then
						pick = { slot = slot, cur = cur, cost = cost, score = score }
					end
				end
			end
		end
		if not pick then
			say("mutate", "nothing to roll (below target and affordable)")
			return
		end
		local key, t0 = pick.slot.key, os.clock()
		step("Mutate", key)
		send("MineRollMutation", key)
		local took = settle(function()
			local m = mutSeen[key]
			return m and m.at >= t0
		end, CONFIRM + 2, alive)
		stats.muts += 1
		if took then
			say("mutate", ("%s %s %s -> %s (cost %s)"):format(key, pick.slot.holder.CharName, mutSeen[key].before, mutSeen[key].variant, fmt(pick.cost)))
		else
			back["mut" .. key] = os.clock() + BACKOFF
			refuse("mut" .. key, ("[mine] mutation roll on %s not taken (cost %s, %s)"):format(key, fmt(pick.cost), said()))
			return
		end
		task.wait(0.2)
	end
end

-- altar ----------------------------------------------------------------------
local function altarBody(alive)
	local _, mg = mine()
	if not mg then
		return
	end
	if not Enchants.Unlocked(mg) then
		say("altar", "altar locked")
		return
	end
	local dice = MC.GetEnchantDiceCount(mg)
	if dice >= 1 then
		first("altar roll", "dice", dice) -- UNPROVEN, 0 dice when probed
		step("Altar", "roll")
		send("MineRollEnchant", 1)
		stats.rolls += 1
		if not settle(function()
			local _, now = mine()
			return now and MC.GetEnchantDiceCount(now) < dice
		end, ALTAR_CONFIRM, alive) then
			warn("[mine] enchant roll took no die:", said())
		end
	end
	for _, slot in ipairs(minerSlots(mg)) do
		if not alive() then
			return
		end
		local _, now = mine()
		local best, bestRank
		for name, count in pairs(now.EnchantItems or {}) do
			if (tonumber(count) or 0) >= 1 then
				local rank = Enchants.Rank(name)
				if not bestRank or rank > bestRank then
					best, bestRank = name, rank
				end
			end
		end
		local cur = MC.GetHolderEnchantName(now, slot.key)
		if best and (not cur or Enchants.Rank(cur) < bestRank) and free("ench" .. slot.key) then
			first("altar equip", slot.key, best) -- UNPROVEN
			send("MineEquipEnchant", slot.key, best)
			if settle(function()
				local _, n2 = mine()
				return n2 and MC.GetHolderEnchantName(n2, slot.key) == best
			end, CONFIRM, alive) then
				say("altar", ("%s wears %s"):format(slot.key, best))
			else
				back["ench" .. slot.key] = os.clock() + BACKOFF
				warn(("[mine] enchant %s not equipped on %s (%s)"):format(best, slot.key, said()))
			end
		end
	end
	say("altar", ("%d dice, %d rolled"):format(dice, stats.rolls))
end

-- setters --------------------------------------------------------------------
local setSell = runner("Sell", SELL_EVERY, sellBody)
local setEquip = runner("Equip", 1, equipBody)
local setPick = runner("Pickaxes", MARKET_EVERY, pickaxeBody)
local setTap = runner("Tap", TAP_GAP, tapBody)
local setChars = runner("Chars", UPGRADE_EVERY, charBody)
local setResearch = runner("Research", RESEARCH_EVERY, researchBody)
local setZone = runner("Zone", ZONE_EVERY, zoneBody)
local setCore = runner("Core", CORE_EVERY, coreBody)
local setIndex = runner("Index", INDEX_EVERY, indexBody)
local setMutate = runner("Mutate", MUTATE_EVERY, mutateBody)
local setAltar = runner("Altar", ALTAR_EVERY, altarBody)
local setAdaptive = runner("Adaptive", PROMO_EVERY, promoBody)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "My Anime Mine", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "pickaxe")
local Eco = Tab:AddLeftGroupbox("Economy", "coins")
local Prog = Tab:AddLeftGroupbox("Progress", "trending-up")
local Gamble = Tab:AddRightGroupbox("Rolls and claims", "dices")
local Cfg = Tab:AddRightGroupbox("Spending", "wallet")

local function toggle(group, idx, text, tip, setter)
	group:AddToggle(idx, {
		Text = text,
		Tooltip = tip,
		Default = false,
		Callback = function(state)
			setter(state)
		end,
	})
end

toggle(Eco, "Sell", "Auto Chest + Sell Ores", "Empties the chest into your bag, then snaps beside the item buyer, sells every ore and snaps back. Characters are kept. The sale is range-gated, so it does walk you there for about a second", setSell)
toggle(Eco, "Equip", "Auto Equip Best", "The game's own Equip Best button, after every pickaxe bought and every 30s", setEquip)
toggle(Eco, "Pickaxes", "Auto Buy Pickaxes", "Buys the best in-stock pickaxe that beats your 8th best one, when it costs at most Spend % of your cash. Checks the market every 5s", setPick)
toggle(Eco, "Tap", "Auto Tap Nodes", "Clicks your nodes inside the click range. It lands, but a tap is about 1e-5 of one crew hit at zone 5, so this barely matters", setTap)
toggle(Prog, "Adaptive", "Adaptive Equip", "Swaps in a character from your bag when it will be stronger once levelled, even though it is weaker today (Equip Best never does, it only compares today's strength). Levels the newcomer first and holds Equip Best off meanwhile. Needs Auto Upgrade Characters on, and walks you to the pad for a second", setAdaptive)
toggle(Prog, "Chars", "Auto Upgrade Characters", "Damage, Speed and Mine Speed on every miner slot, best gain per cost first, at most Spend % of cash per purchase", setChars)
toggle(Prog, "Research", "Auto Upgrade Research", "Buys the cheapest open research node of any unlocked zone, up to half your cash per node", setResearch)
toggle(Prog, "Zone", "Auto Move Zone", "When the current zone's research is 100% and your cash covers the next zone's unlock cost, moves to it. The server refuses earlier, so asking is harmless", setZone)
toggle(Prog, "Core", "Auto Core Upgrades", "Tap level, and the miner slot (unproven: slots were already full)", setCore)
toggle(Gamble, "Index", "Auto Claim Index", "Claims every reward the Index lists as claimable. Unproven: nothing was claimable when probed", setIndex)
toggle(Gamble, "Mutate", "Auto Roll Mutations", "Rolls miner slots that are below the target variant, best damage gained per cash first, while one roll costs at most the Roll % below. A roll REPLACES the variant and can land lower; a slot stops once it reaches the target. A Serious Baldy roll is 4.9e26 and a Rainbow takes about 16 rolls on average", setMutate)

local variants = {}
for _, v in ipairs(MC.GetVariantLadder()) do
	if v.VariantName ~= MC.DefaultVariant and (tonumber(v.Chance) or 0) > 0 then
		variants[#variants + 1] = v.VariantName
	end
end
Gamble:AddDropdown("MutTarget", {
	Text = "Mutation target",
	Tooltip = "A slot stops rolling once it has this variant or a better one",
	Values = variants,
	Default = mutTarget,
	Multi = false,
	Callback = function(value)
		if value then
			mutTarget = value
		end
	end,
})
toggle(Gamble, "Altar", "Auto Enchant Altar", "Rolls Enchanted Dice one at a time and equips the best enchant you hold on each slot. Unproven: you had no dice when this was probed", setAltar)

Cfg:AddInput("SpendPct", {
	Text = "Spend % of cash",
	Tooltip = "One purchase (upgrade, pickaxe, core, mutation roll) may cost at most this share of your cash. Research gets half. Lower it to save for a zone unlock",
	Default = tostring(SPEND_PCT),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		local v = tonumber(text)
		if v and v > 0 and v <= 100 then
			spendFrac = v / 100
		end
	end,
})

Cfg:AddInput("RollPct", {
	Text = "Roll % of cash",
	Tooltip = "One mutation roll may cost at most this share of your cash. Lower rolls less often and keeps cash for the rest, higher lets the expensive Baldy rolls run sooner. At 5% a roll never takes more than a twentieth of what you hold",
	Default = tostring(MUTATE_FRAC * 100),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		local v = tonumber(text)
		if v and v > 0 and v <= 100 then
			mutFrac = v / 100
		end
	end,
})

local function zoneStatus()
	local _, mg = mine()
	if not mg then
		return "loading"
	end
	local cur = "Z" .. tostring(mg.CurrentZone or 1)
	local good, done, total = pcall(MC.GetZoneResearchProgress, mg.Skills, cur)
	return good and ("%s research %d/%d"):format(cur, done, total) or cur
end

local nextStrip = 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	if pending.now then
		nowNote, pending.now = pending.now, nil
	end
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	local d = mine()
	pcall(Window.SetStatus, Window, { -- ponytail: thrown "lacking capability Plugin" when loaded through the bridge; silence, not fix
		{ "Cash", d and fmt(d.Money) or "-" },
		{ "Zone", zoneStatus() },
		{ "Sold", stats.sold },
		{ "Picks", stats.picks },
		{ "Upgrades", stats.ups },
		{ "Research", stats.skills },
		{ "Muts", stats.muts },
		{ "Promos", stats.promos },
		{ "Now", nowNote },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("MyAnimeMine", {})

local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- close ----------------------------------------------------------------------
local function stopAll()
	running = false
	for name in pairs(gens) do
		gens[name] += 1 -- every loop sees its generation change and ends
	end
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().animeMineStop = nil
end)

getgenv().animeMineStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().animeMineStop = nil
end

log("ready -- nothing runs until you switch a toggle on")
