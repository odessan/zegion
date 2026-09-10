--[[ Anime Dice -- rolls, slots, levels, sells and towers, all off the wire (113290951185459)

     ROLL     : invokes RollDice on the server's own cooldown, skipping the client's roll
                cutscene entirely. Stops itself before the inventory cap instead of eating
                a "your inventory is full" toast every 2.5s.
     CASH     : collects every unlocked slot's balance. No walking -- CollectBalance takes
                a slot number and has no distance check.
     EQUIP    : ranks your units by the income they WOULD earn at the comparison level, so
                a fresh rare unit can displace a levelled common one. The game's own
                EquipBest ranks by income RIGHT NOW, which permanently benches anything
                less than 5.75x better than what's already levelled.
     UPGRADE  : levels the slotted units, lowest level first, up to the level you type.
     SELL     : rarity / chance / value filters, batched into one bulk sell. Never sells
                what's slotted, locked, on the tower team, or about to be equipped.
     REBIRTH  : rebirths when you can afford it. This is what unlocks slots 5-13, so while
                it's on, Upgrade only spends money above the next rebirth's price.
     TOWERS   : plays a tower floor by floor. Combat is entirely server-side arithmetic,
                so this runs from anywhere alongside everything else. The tower team is
                separate storage from your plot slots -- nothing gets swapped out.
     REWARDS  : daily, group, offline, quests and every code the game ships.

     Nothing here moves your character. Every action is a remote with no position check.

     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().animeDiceStop() ]]

-- config ---------------------------------------------------------------------
-- The server's roll gate is the "Roll Duration" buff (2.5s by default) and a call inside
-- it is silently dropped, so pacing to the live buff wastes nothing. The epsilon is for
-- clock skew: land a hair early and the call is thrown away for free, but it's a wasted
-- remote and the user asked not to flood.
local ROLL_MIN_GAP = 0.05

-- The level every unit is RANKED at -- not a level anything is levelled to. Because income
-- is base * (1 + 0.25*(L-1)), giving every unit the same L makes that factor identical
-- across the comparison and cancel out, which leaves pure chance/mutation/trait/grade. Any
-- value ranks the same order; 20 only matters for the margin below, which is measured
-- against it. Script-only: there is no reading of this a player could act on.
local COMPARISON_LEVEL = 20

-- Displacing a levelled unit with a level-1 one costs you the whole levelling bill again,
-- so a marginal improvement isn't worth taking. 1.10 = "must project at least 10% better".
-- Script-only for the same reason.
local SWAP_MARGIN = 1.10

-- This one IS on the panel, because it spends your money and the right answer depends on
-- what else you want to buy. The loop reads the live value each pass, so retyping it takes
-- effect immediately with no re-toggle. A level costs base_income * 1.6^(L-1) and pays back
-- 25% of base income per second, so payback is 4 * 1.6^(L-1) seconds -- ~26s at level 5,
-- 4.6min at 10, 48min at 15, 8.4 HOURS at 20. The last few levels are money you could have
-- spent on a rebirth instead.
local UPGRADE_TARGET = 20

-- Rebirth 10 unlocks slot 13, the last one (PlotConfig.GetSlotRebirthRequirement). 11 is
-- the last tier in Rebirths.lua and costs 1e24; past 10 you're buying multipliers, not
-- slots, so this is where the reserve stops holding money back from Upgrade.
local MAX_REBIRTH = 10

local COLLECT_GAP = 5 -- seconds between cash sweeps. Balance accrues 1/s with no cap and
-- nothing expires, so collecting slowly costs nothing -- but Upgrade spends what's
-- collected, so this is also how often money becomes spendable.

local PIPELINE_QUIET = 1.0 -- a roll can add several units at once; wait this long after
-- the last inventory write before running the pass, so a burst is one pass not five.
local PIPELINE_HEARTBEAT = 15 -- run the pass anyway this often, so nothing stalls if the
-- inventory event is missed (a rebirth unlocks slots without adding a unit, for one).

-- InvokeServer has no timeout and pcall does not bound a yield: a handler that throttles
-- or never returns parks the calling thread forever, which is indistinguishable from a
-- dead loop -- no error, no log line, toggle still lit. So we don't wait on it.
local INVOKE_TIMEOUT = 8

local SETTLE = 0.55 -- UnitService.Equip and PlotService.InteractSlot are each behind a
-- 0.5s debounce (different keys, so they don't block each other -- this is the spacing
-- between two consecutive Equips).
local CONFIRM = 2.5 -- how long to wait for the server to show a unit actually in a slot

-- At a 2.5s roll cooldown that's ~24 pulls a minute, so the event feed lives in the F9
-- console rather than on the panel -- a ten-line box turned over faster than it could be
-- read. Common pulls still count toward the totals; only these print. Mutations always
-- print regardless of the threshold, because the mutation multiplies the base chance by
-- 10 up to 1e6 and a mutated Common is a rarer event than its own chance suggests.
local LOG_CHANCE = 1000 -- print a pull at or rarer than 1 in N
local BOARD_REFRESH = 1 -- seconds between stat-block redraws
local REROLL_GAP = 0.35 -- roll_grade / roll_trait share a 0.25s debounce
local BOOST_GAP = 0.4

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().animeDiceStop then
	getgenv().animeDiceStop() -- re-running must not stack a second panel or a second loop
end

-- world ----------------------------------------------------------------------
-- Every module below ships in ReplicatedStorage because this game keeps its whole
-- framework there -- including the code the SERVER runs. So the formulas, prices and
-- cooldowns are the real ones, and requiring them beats copying tables that go stale on
-- the next balance patch. require() hits the client's module cache, so nothing re-runs.
local function requireAt(root, ...)
	local node = root
	for _, name in ipairs({ ... }) do
		if not node then
			return nil
		end
		node = node:WaitForChild(name, 5) -- always a timeout; an infinite yield is a hang
	end
	if not node then
		return nil
	end
	local ok, mod = pcall(require, node)
	return ok and mod or nil
end

local Framework = ReplicatedStorage:WaitForChild("Framework", 10)
if not Framework then
	warn("[AnimeDice] no ReplicatedStorage.Framework -- wrong game, or it hasn't replicated yet")
	return
end

local Data = requireAt(Framework, "Features", "Data", "DataController")
local Registry = requireAt(Framework, "Features", "Inventory", "EntryRegistry")
local PlotConfig = requireAt(Framework, "Features", "Plot", "PlotConfig")
local UnitUtil = requireAt(Framework, "Features", "Inventory", "Kinds", "Unit", "UnitUtil")
local SellUtil = requireAt(Framework, "Features", "Selling", "SellUtil")
local Rarities = requireAt(Framework, "Other", "Rarities")
local Buffs = requireAt(Framework, "Features", "Buffs", "BuffController")
local Rebirths = requireAt(Framework, "Features", "Rebirth", "Rebirths")
local TowerList = requireAt(Framework, "Features", "Towers", "Towers")
local TowerRefs = requireAt(Framework, "Features", "Towers", "TowerRefs")
local QuestConfig = requireAt(Framework, "Features", "Quests", "QuestConfig")
local MonetizationConfig = requireAt(Framework, "Features", "Monetization", "MonetizationConfig")
local DiceList = requireAt(Framework, "Features", "Rolling", "Dice")
local NumberFormatter = requireAt(ReplicatedStorage, "Packages", "NumberFormatter")
local Grades = requireAt(Framework, "Features", "Grades", "Grades")
local TraitTable = requireAt(Framework, "Features", "Traits", "Traits")

-- Refuse to start rather than half-start. Without these four there is no ranking, no slot
-- list and no inventory -- every feature would be guessing, which is worse than nothing.
if not (Data and Registry and PlotConfig and Rarities) then
	warn("[AnimeDice] core modules missing (Data/EntryRegistry/PlotConfig/Rarities) -- the game has been restructured")
	return
end

-- The optional ones each silently disable a feature, and a disabled feature looks exactly
-- like a broken one from the panel. Name them once at load so "it does nothing" has an
-- answer in the console instead of needing a guess.
do
	local missing = {}
	for name, mod in pairs({
		UnitUtil = UnitUtil, -- Auto Upgrade (level prices)
		SellUtil = SellUtil, -- the Value sell filter
		Buffs = Buffs, -- roll pacing and the inventory cap
		Rebirths = Rebirths, -- Auto Rebirth and the upgrade reserve
		Towers = TowerList, -- the tower list and the simulator
		TowerRefs = TowerRefs, -- tower team size and action names
		QuestConfig = QuestConfig, -- quest claiming
		MonetizationConfig = MonetizationConfig, -- the codes list
		Dice = DiceList, -- the board's luck readout
		Grades = Grades, -- Auto Grade Reroll (which grades are protected)
		Traits = TraitTable, -- Auto Trait Reroll (which traits are protected)
	}) do
		if not mod then
			table.insert(missing, name)
		end
	end
	if #missing > 0 then
		table.sort(missing)
		warn("[AnimeDice] optional modules not found, features using them are off: " .. table.concat(missing, ", "))
	end
end

-- Remotes are all ReplicatedStorage.Network.<Service>.<RE|RF>.<Name>. Resolved lazily and
-- re-resolved if the instance goes away, so a rejoin or a streaming hiccup doesn't leave
-- a dead reference behind a toggle that still looks lit.
local Network = ReplicatedStorage:WaitForChild("Network", 10)
local remoteCache = {}
local function remote(service, kind, name)
	local id = service .. "/" .. kind .. "/" .. name
	local got = remoteCache[id]
	if got and got.Parent then
		return got
	end
	if not Network then
		return nil
	end
	local svc = Network:WaitForChild(service, 5)
	local folder = svc and svc:WaitForChild(kind, 5)
	local inst = folder and folder:WaitForChild(name, 5)
	remoteCache[id] = inst
	return inst
end

local function fire(service, name, ...)
	local rem = remote(service, "RE", name)
	if not rem then
		return false
	end
	-- pcall'd because the server rejecting us is the normal case, not a reason to kill a
	-- loop: not enough money, slot locked, already claimed.
	return (pcall(rem.FireServer, rem, ...))
end

-- Returns a packed table of the results, or nil if the call was refused OR never came
-- back. The abandoned thread is harmless -- it writes to locals nobody reads afterwards.
local function invoke(service, name, ...)
	local rem = remote(service, "RF", name)
	if not rem then
		return nil
	end
	local args = table.pack(...)
	local done, out = false, nil
	task.spawn(function()
		local packed = table.pack(pcall(function()
			return rem:InvokeServer(table.unpack(args, 1, args.n))
		end))
		if packed[1] then
			out = { table.unpack(packed, 2, packed.n) }
		end
		done = true
	end)
	local started = os.clock()
	while not done and os.clock() - started < INVOKE_TIMEOUT do
		task.wait()
	end
	return done and out or nil
end

-- The farm threads never write to the panel: an executor hands a RESUMED thread back with
-- reduced capability, so the first status write lands and every one after a task.wait
-- throws "lacking capability Plugin" -- the panel lives in the hidden GUI, which is the
-- part that needs it. A Heartbeat connection drains this instead; the engine calls
-- Heartbeat with our own identity.
local pending = nil
local function say(msg)
	pending = msg
end

-- anti-idle --------------------------------------------------------------------
-- Roblox kicks after ~20 minutes without input, and this script is unusually exposed to
-- it: nothing here moves the character. Every feature is a remote with no position check,
-- so an unattended run genuinely never produces an input event -- where a walk-around farm
-- would defeat the kick by accident. A right-click through VirtualUser counts as input
-- without doing anything in the game.
--
-- Two triggers, because one missed Idled event costs the whole session: a 60s timer so the
-- idle clock never gets near 20 minutes, and Idled itself as the last warning before the
-- kick. ponytail: no rejoin-on-disconnect. That one has to live in CoreGui, where teardown
-- can't reach it, so a stopped script would still drag you back into the game -- add it
-- only if sessions actually start dropping.
local hasVU, vu = pcall(game.GetService, game, "VirtualUser")
local hasVIM, vim = pcall(game.GetService, game, "VirtualInputManager")
if not (hasVU or hasVIM) then
	warn("[AnimeDice] anti-idle unavailable (no VirtualUser or VirtualInputManager) -- expect a 20min kick")
end

local nudges = 0
local function nudge(why)
	-- Both input paths: a client that ignores one may still honour the other.
	if hasVU then
		local cf = workspace.CurrentCamera and workspace.CurrentCamera.CFrame or CFrame.new()
		pcall(function()
			vu:CaptureController()
			-- Down+up rather than ClickButton2: some clients drop the one-shot version.
			vu:Button2Down(Vector2.new(0, 0), cf)
			task.wait(0.05)
			vu:Button2Up(Vector2.new(0, 0), cf)
		end)
	end
	if hasVIM then
		pcall(function()
			vim:SendMouseButtonEvent(0, 0, 1, true, game, 0) -- right button, harmless
			vim:SendMouseButtonEvent(0, 0, 1, false, game, 0)
		end)
	end
	nudges = nudges + 1
	-- ponytail: a print is the whole diagnostic. "It still kicked me" is unanswerable
	-- without knowing whether the nudges were going out.
	print(("[AnimeDice] anti-idle nudge #%d (%s)"):format(nudges, why))
end

local idleConn = player.Idled:Connect(function()
	nudge("Idled") -- Roblox's own idle warning: the kick is what comes next
end)
local idleGen = 0
do
	idleGen = idleGen + 1
	local mine = idleGen
	task.spawn(function()
		while idleGen == mine do
			task.wait(60)
			if idleGen == mine then
				nudge("timer")
			end
		end
	end)
end

-- stats ----------------------------------------------------------------------
-- UnitConfig builds these per entry, so the exponents and the multiplier stack live in
-- the game's code and not here:
--   c        = chance * variant.chanceMultiplier * mutation.chance
--   income   = c^0.725 * trait.income * grade.income * (1 + 0.25*(level-1))
--   damage   = c^0.58  * trait.damage                       <- no level term
-- Level is therefore worth exactly x5.75 at level 20, and worth NOTHING in a tower.
local function cfgOf(name)
	local cfg = Registry.getEntryConfig(name)
	if cfg and cfg.kind == "Unit" then
		return cfg
	end
	return nil
end

-- Income at an arbitrary level, which is the whole point of the ranking: at a level every
-- unit shares, the (1 + 0.25*(L-1)) factor is identical for all of them and cancels, so
-- this IS chance-ranking -- with mutation, trait and grade weighted the way the game
-- weights them rather than the way we'd guess.
local function incomeAt(cfg, attrs, level)
	if type(cfg.income) ~= "function" then
		return 0
	end
	local ok, v = pcall(cfg.income, {
		mutation = attrs.mutation,
		trait = attrs.trait,
		grade = attrs.grade,
		level = level or attrs.level or 1,
	})
	return (ok and type(v) == "number") and v or 0
end

local function damageOf(cfg, attrs)
	if type(cfg.damage) ~= "function" then
		return 0
	end
	local ok, v = pcall(cfg.damage, attrs)
	return (ok and type(v) == "number") and v or 0
end

local function healthOf(cfg, attrs)
	if type(cfg.health) ~= "function" then
		return 0
	end
	local ok, v = pcall(cfg.health, attrs)
	return (ok and type(v) == "number") and v or 0
end

-- nil, not 0, for the two `limited` units (Fused Zamatsu, Emelia): they're defined by
-- income instead of chance so UnitConfig leaves cfg.chance nil. Returning 0 would make
-- the chance filter read them as the worst thing you own and sell your Exclusives.
local function chanceOf(cfg, attrs)
	if type(cfg.chance) ~= "function" then
		return nil
	end
	local ok, v = pcall(cfg.chance, attrs)
	return (ok and type(v) == "number") and v or nil
end

-- The rarity ladder, by the game's own sortOrder. Built by walking Rarities.Refs rather
-- than typing the names out, so a new tier appears in the dropdown by itself. "Secret II"
-- is declared in Refs but has no sortOrder entry, so it drops out here -- deliberately:
-- a rarity we can't rank is one we must not filter on.
local rarityRank, rarityNames = {}, {}
for _, display in pairs(Rarities.Refs) do
	local meta = Rarities.Get(display)
	if meta and meta.sortOrder then
		rarityRank[display] = meta.sortOrder
		table.insert(rarityNames, display)
	end
end
table.sort(rarityNames, function(a, b)
	return rarityRank[a] < rarityRank[b]
end)

local function rarityOf(cfg, attrs)
	if type(cfg.getRarity) ~= "function" then
		return cfg.rarity
	end
	local ok, v = pcall(cfg.getRarity, attrs)
	return ok and v or cfg.rarity
end

-- Self-check, not a test suite: if a balance patch changes the level curve away from
-- +25%/level, every ranking and every upgrade decision below is quietly wrong, and this
-- is the one line that notices. Chance-value independent on purpose -- it checks the
-- SHAPE of the curve, so re-tuning a unit doesn't trip it.
do
	local probe
	for name in pairs(Registry.entriesOfKind("Unit")) do
		local cfg = cfgOf(name)
		if cfg and incomeAt(cfg, {}, 1) > 100 then
			probe = cfg
			break
		end
	end
	if probe then
		local one, twenty = incomeAt(probe, {}, 1), incomeAt(probe, {}, 20)
		assert(one > 0 and math.abs(twenty / one - 5.75) < 0.02, "[AnimeDice] income no longer scales as 1 + 0.25*(level-1)")
	end
end

-- state ----------------------------------------------------------------------
-- Everything here reads the client's mirror of the save (a replicated Value tree), not
-- Instances. That matters because slot models stream out and the inventory has no
-- Instance form at all -- and it's what the game's own HUD reads.
local function readNum(fn, fallback)
	local ok, v = pcall(fn)
	return (ok and type(v) == "number") and v or fallback
end

local function money()
	return readNum(Data.Money, 0)
end
local function rebirthCount()
	return readNum(Data.Rebirth, 0)
end

-- Reports whether it could READ, not just what it found: failing open to an empty list
-- reads as "you own nothing", which would tell the sell pass there's nothing to protect.
local function units()
	local ok, inv = pcall(Data.Inventory)
	if not ok or type(inv) ~= "table" then
		return {}, false
	end
	local out = {}
	for key, item in pairs(inv) do
		if type(item) == "table" and (item.amount or 0) > 0 then
			local cfg = cfgOf(item.name)
			if cfg then
				table.insert(out, { key = key, name = item.name, cfg = cfg, attrs = item.attributes or {} })
			end
		end
	end
	return out, true
end

local function slotTable()
	local ok, s = pcall(Data.Slots)
	if not ok or type(s) ~= "table" then
		return {}, false
	end
	return s, true
end

-- Slot 1-4 are free; 5-13 each want a rebirth count. A locked slot isn't missing, it's
-- refused -- CollectBalance, LevelUpSlot and InteractSlot all check IsSlotUnlocked -- so
-- there is no point firing at one.
local function unlockedSlots()
	local r = rebirthCount()
	local out = {}
	local max = 13
	if type(PlotConfig.GetMaxSlots) == "function" then
		local ok, v = pcall(PlotConfig.GetMaxSlots)
		if ok and type(v) == "number" then
			max = v
		end
	end
	for i = 1, max do
		local need = 0
		if type(PlotConfig.GetSlotRebirthRequirement) == "function" then
			local ok, v = pcall(PlotConfig.GetSlotRebirthRequirement, i)
			if ok and type(v) == "number" then
				need = v
			end
		end
		if r >= need then
			table.insert(out, i)
		end
	end
	return out
end

local function towerTeam()
	local ok, t = pcall(Data.TowerTeam)
	if not ok or type(t) ~= "table" then
		return {}
	end
	return t
end

local function buff(name, fallback)
	if not Buffs or type(Buffs.GetBuff) ~= "function" then
		return fallback
	end
	local ok, v = pcall(Buffs.GetBuff, name)
	return (ok and type(v) == "number") and v or fallback
end

local function alive()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return char ~= nil and hum ~= nil and hum.Health > 0
end

-- board ----------------------------------------------------------------------
-- Two things: numbers that are always current, and a short log of things worth reading.
-- Every loop below reports into this, so it has to be defined before all of them.
--
-- Nothing here touches an Instance. Counters and the ring buffer are plain table writes,
-- which is what makes them safe to call from a resumed loop thread; a single Heartbeat
-- connection in the gui section does all the rendering.
local startedAt = os.clock()
local stats = {
	rolls = 0, -- RollDice calls we made
	gained = 0, -- units the server actually granted
	sold = 0,
	sellIncome = 0,
	levels = 0,
	rebirths = 0,
	floors = 0,
	gems = 0, -- grade rerolls spent
	rerolls = 0, -- trait rerolls spent
	boosts = 0,
	loot = {}, -- [entryName] = amount, from towers and claims
	best = "", -- rarest pull this session, already formatted
	bestChance = 0, -- the mutation-adjusted 1-in-N it was picked on
}

-- Straight to the console, which is where the house keeps its diagnostics anyway and is
-- the one place that keeps scrollback. The `[server] ...` lines in particular are the only
-- wording the game ever gives for a refusal, and they're worth still having an hour later.
local function logEvent(text)
	print("[AnimeDice] " .. text)
end

-- The game's own compact formatter, so "1 in 3.5K" here reads the same as the number the
-- game prints two inches away in its Backpack UI. Falls back rather than failing: a
-- missing formatter must cost you the thousands separator, not the whole board.
local function short(n)
	if type(n) ~= "number" then
		return "?"
	end
	if NumberFormatter and type(NumberFormatter.FormatCompact) == "function" then
		local ok, s = pcall(NumberFormatter.FormatCompact, n)
		if ok and s then
			return s
		end
	end
	return string.format("%.0f", n)
end

-- The other direction, for the threshold inputs. Chances here reach 1 in 56 trillion and
-- the sell value scales with them, so typing the digits out is sixteen zeroes you have to
-- count. Same two-step the game's own auto-sell box uses: tonumber first (plain digits and
-- scientific notation like 1e16), then the game's compact parser, which is case-insensitive
-- and knows the whole ladder -- k, m, b, t, qd, qi, sx ... up to ocvg. So "10Qd" works.
local function parseAmount(text)
	local cleaned = tostring(text or ""):gsub("[,%s]", "")
	if cleaned == "" then
		return nil
	end
	local n = tonumber(cleaned)
	if not n and NumberFormatter and type(NumberFormatter.ParseCompact) == "function" then
		local ok, parsed = pcall(NumberFormatter.ParseCompact, cleaned)
		n = ok and parsed or nil
	end
	if type(n) ~= "number" or n ~= n or n <= 0 or n == math.huge then
		return nil -- rejects NaN and inf as well as junk; a NaN threshold matches nothing
	end
	return n
end

do -- self-check: the suffix ladder is the whole point of this helper
	assert(parseAmount("1000") == 1000, "plain digits")
	assert(parseAmount("1,000") == 1000, "grouping symbol")
	assert(parseAmount("1e16") == 1e16, "scientific")
	assert(parseAmount("abc") == nil and parseAmount("") == nil, "junk rejected")
	if NumberFormatter and type(NumberFormatter.ParseCompact) == "function" then
		assert(parseAmount("10Qd") == 1e16, "compact suffix, case-insensitive")
		assert(parseAmount("2.5b") == 2.5e9, "compact with a decimal")
	end
end

-- "Goko (1 in 3.5K, Gold, Mythical)" -- everything you'd want to know about a pull on one
-- line, and every field guarded, because a `limited` unit has no chance function at all.
local function describe(name, attrs, cfg)
	cfg = cfg or cfgOf(name)
	if not cfg then
		return name
	end
	local bits = {}
	local chance = chanceOf(cfg, attrs)
	if chance then
		table.insert(bits, "1 in " .. short(chance))
	elseif cfg.limited then
		table.insert(bits, "Limited")
	end
	if attrs.mutation then
		table.insert(bits, attrs.mutation)
	end
	local rarity = rarityOf(cfg, attrs)
	if rarity then
		table.insert(bits, rarity)
	end
	if #bits == 0 then
		return name
	end
	return ("%s (%s)"):format(name, table.concat(bits, ", "))
end

local function addLoot(name, amount)
	stats.loot[name] = (stats.loot[name] or 0) + (amount or 1)
end

-- What the plot is actually paying you, computed the way PlotClass's own 1s loop computes
-- it: each unlocked slot's unit income times the Money Multiplier buff. Worth having on
-- screen because it's the number every other feature here is trying to raise.
local function incomePerSec()
	local slots = slotTable()
	local okInv, inv = pcall(Data.Inventory)
	if not okInv or type(inv) ~= "table" then
		return 0
	end
	local total = 0
	for _, i in ipairs(unlockedSlots()) do
		local slot = slots[tostring(i)]
		local item = slot and slot.unitId and inv[slot.unitId]
		local cfg = item and cfgOf(item.name)
		if cfg then
			total = total + incomeAt(cfg, item.attributes or {}, nil)
		end
	end
	return total * buff("Money Multiplier", 1)
end

-- Tower drops arrive as "Pirate Damage I", "Pirate Damage II", "Pirate Damage III" -- nine
-- distinct entry names for three things, which is what turned the loot line into a
-- run-on. Collapsing the tier makes it scannable, and the tier is noise once the only
-- question the line answers is whether towering is still paying.
local function lootFamily(name)
	return (name:gsub("%s+I+$", ""))
end

local function luckNow()
	local base = 1
	if DiceList and type(DiceList.Get) == "function" then
		local okName, name = pcall(Data.Dice)
		if okName and name then
			local okDice, dice = pcall(DiceList.Get, name)
			if okDice and type(dice) == "table" and dice.luck then
				base = dice.luck
			end
		end
	end
	return base * buff("Luck", 1)
end

-- cash -----------------------------------------------------------------------
-- The workspace path (Plots.Claimed.<uuid>.Slots.N.Balance.Hitbox) is the client's touch
-- shim; PlotService.CollectBalance takes a slot NUMBER, checks only that the slot is
-- unlocked, and never looks at where you are. So there is no plot to find and no uuid to
-- read -- the balances are in your own save data.
local function sweepCash()
	local slots = slotTable()
	local fired = 0
	for _, i in ipairs(unlockedSlots()) do
		local slot = slots[tostring(i)]
		if slot and (slot.balance or 0) > 0 then
			fire("PlotService", "CollectBalance", i)
			fired = fired + 1
		end
	end
	return fired
end

-- roll -----------------------------------------------------------------------
-- The game ships its own auto-roll, but its loop lives on the CLIENT and waits out the
-- roll cutscene before firing again, so it rolls slower than the server would allow.
-- Invoking RollDice directly skips the animation entirely; the server's own per-player
-- gate (the Roll Duration buff) is then the only floor.
local rollOn, rollGen = false, 0
local rollCount, capStated = 0, false
local savedAutoRoll = nil -- the game's persistent AutoRoll flag, restored on teardown

-- RollService refuses at UnitStorage + (Rolls - 1) units and answers with a toast every
-- time. Both numbers are buffs, so they're readable here -- gate locally and the refusal
-- never happens rather than being swallowed by a pcall.
local function rollBlocked()
	local list, couldRead = units()
	if not couldRead then
		return false -- can't read is not "full"; let the server answer instead of stalling
	end
	return #list >= (buff("Unit Storage", 100) + (buff("Rolls", 1) - 1))
end

local wakePipeline -- forward: a cap hit asks the sell pass to make room

local function setRolling(on)
	rollOn = on
	rollGen = rollGen + 1
	local mine = rollGen
	if not on then
		-- Put the player's own setting back the way we found it. Ours is a live loop, so
		-- leaving theirs off would silently change how the game behaves after we're gone.
		if savedAutoRoll ~= nil then
			fire("RollService", "SetAutoRoll", savedAutoRoll)
			savedAutoRoll = nil
		end
		return
	end
	-- Their client loop invokes the same remote and holds the same cooldown while its
	-- cutscene plays, so leaving it on roughly halves our rate for no visible reason.
	local ok, cur = pcall(Data.AutoRoll)
	if ok and cur == true then
		savedAutoRoll = true
		fire("RollService", "SetAutoRoll", false)
	end
	capStated = false
	task.spawn(function()
		while rollOn and rollGen == mine do
			if rollBlocked() then
				if not capStated then
					capStated = true
					say("inventory full -- rolling paused")
					logEvent("inventory full, rolling paused")
					wakePipeline("cap") -- let the sell pass make room, if it's on
				end
				task.wait(1)
			else
				capStated = false
				-- No result check: RollDice returns nil both when the cooldown ate the
				-- call and when the roll happened but the unit hasn't been granted yet
				-- (RollService delays the grant by RollDuration + RollDuration/3). The
				-- inventory event is what tells us a unit actually arrived.
				invoke("RollService", "RollDice")
				rollCount = rollCount + 1
				stats.rolls = stats.rolls + 1
				say(("rolling -- %d calls, %.1fs gap"):format(rollCount, buff("Roll Duration", 2.5)))
				task.wait(math.max(buff("Roll Duration", 2.5), 0) + ROLL_MIN_GAP)
			end
		end
	end)
end

-- equip ----------------------------------------------------------------------
-- Two rankings, and the difference between them is the whole feature. The server's own
-- EquipBest sorts by income RIGHT NOW, so once a slotted unit is levelled to 20 it takes
-- 5.75x -- about 11.6x rarer -- to beat it, and everything between 2x and 11x rarer is
-- benched forever and therefore never levelled. Ranking at a shared level removes the
-- level term from both sides and asks the only question that matters: which unit is
-- worth investing in.
local upgradeTarget = UPGRADE_TARGET -- the one level the panel does expose
local sortSlots = false

local function ranked(level)
	local list = units()
	for _, u in ipairs(list) do
		u.proj = incomeAt(u.cfg, u.attrs, level)
		u.now = incomeAt(u.cfg, u.attrs, nil)
	end
	return list
end

local function topBy(list, field, n)
	local copy = table.clone(list)
	table.sort(copy, function(a, b)
		if a[field] == b[field] then
			return a.key < b.key -- same tie-break the server uses, so results are stable
		end
		return a[field] > b[field]
	end)
	local out, keys = {}, {}
	for i = 1, math.min(n, #copy) do
		out[i] = copy[i]
		keys[copy[i].key] = true
	end
	return out, keys
end

local function sameKeys(a, b)
	for k in pairs(a) do
		if not b[k] then
			return false
		end
	end
	for k in pairs(b) do
		if not a[k] then
			return false
		end
	end
	return true
end

-- Puts one unit into one slot. Collect first: UpdateSlotUnit zeroes the slot's balance,
-- so replacing an occupied slot without collecting burns whatever it had accrued.
local function placeInSlot(key, index)
	fire("PlotService", "CollectBalance", index)
	local res = invoke("UnitService", "Equip", key)
	if not (res and res[1]) then
		return false -- no character, dead, or the 0.5s UnitAction debounce
	end
	fire("PlotService", "InteractSlot", index)
	-- Confirm on the world changing, not on a return value: InteractSlot is a signal and
	-- tells us nothing at all.
	local deadline = os.clock() + CONFIRM
	while os.clock() < deadline do
		local slots = slotTable()
		local slot = slots[tostring(index)]
		if slot and slot.unitId == key then
			return true
		end
		task.wait(0.1)
	end
	return false
end

-- Lifts a slot's unit into your hands, leaving the slot empty. InteractSlot only does this
-- when your hands are ALREADY empty -- holding something makes it place instead -- which is
-- why sortPass unequips before it starts.
local function liftFromSlot(index)
	fire("PlotService", "CollectBalance", index) -- clearing a slot drops its balance
	fire("PlotService", "InteractSlot", index)
	local deadline = os.clock() + CONFIRM
	while os.clock() < deadline do
		local slot = slotTable()[tostring(index)]
		if not (slot and slot.unitId) then
			return true
		end
		task.wait(0.1)
	end
	return false
end

-- Drops what you're holding into a slot, displacing whatever was there back to inventory
-- (with its level intact -- a slot only stores the unit's key).
local function dropIntoSlot(index, key)
	fire("PlotService", "CollectBalance", index)
	fire("PlotService", "InteractSlot", index)
	local deadline = os.clock() + CONFIRM
	while os.clock() < deadline do
		local slot = slotTable()[tostring(index)]
		if slot and slot.unitId == key then
			return true
		end
		task.wait(0.1)
	end
	return false
end

-- Puts the right units in the right ORDER. Purely presentational -- PlotClass credits each
-- slot its own unit's income, so position pays nothing -- which is why it's behind its own
-- toggle and runs only when the order is actually wrong.
--
-- There is no "move" remote to use: UpdateSlotUnit refuses a unit that is already assigned
-- to another slot, so every move is lift-then-drop, two InteractSlots at 0.5s of debounce
-- each. Walking the slots in ASCENDING order is what bounds it to one move per slot: once
-- slot i holds the right unit nothing can displace it again, because a displaced unit
-- always lands in inventory and every slot below i is already correct.
local function sortPass(want, open)
	-- Is it already sorted? Much the commonest case, and it must cost nothing.
	local slots = slotTable()
	local sorted = true
	for rank, unit in ipairs(want) do
		local index = open[rank]
		local slot = index and slots[tostring(index)]
		if not (slot and slot.unitId == unit.key) then
			sorted = false
			break
		end
	end
	if sorted then
		return
	end
	if not alive() then
		return -- the pickup half goes through UnitService.Equip, which needs a Humanoid
	end

	-- Empty-handed, or the first InteractSlot places what we're holding instead of lifting
	-- what's in the slot. Unequip only destroys the Tool; the unit stays in inventory.
	invoke("UnitService", "Unequip")
	task.wait(SETTLE)

	local moved = 0
	for rank, unit in ipairs(want) do
		local index = open[rank]
		if not index then
			break
		end
		-- Re-read every iteration: the previous move displaced someone, and this loop is
		-- the only thing that knows where they went.
		local live = slotTable()
		local here = live[tostring(index)]
		if not (here and here.unitId == unit.key) then
			local from = nil
			for _, i in ipairs(open) do
				local slot = live[tostring(i)]
				if slot and slot.unitId == unit.key then
					from = i
					break
				end
			end
			local ok
			if from then
				ok = liftFromSlot(from) and dropIntoSlot(index, unit.key)
			else
				ok = placeInSlot(unit.key, index) -- it was displaced into inventory
			end
			if not ok then
				-- Bail rather than thrash. A failed drop leaves a unit in hand and a slot
				-- empty, which the next equipPass fills -- nothing is lost either way.
				say("sort: a move was refused, stopping")
				break
			end
			moved = moved + 1
			task.wait(SETTLE)
		end
	end
	if moved > 0 then
		say(("sort: %d move%s"):format(moved, moved == 1 and "" or "s"))
	end
end

local wantedKeys = {} -- read by the sell pass: never sell what we're about to slot

local function equipPass()
	local list = ranked(COMPARISON_LEVEL)
	if #list == 0 then
		return
	end
	local open = unlockedSlots()
	local n = #open
	if n == 0 then
		return
	end

	local want, wantSet = topBy(list, "proj", n)
	local _, serverSet = topBy(list, "now", n) -- what EquipBest would pick, unchanged
	wantedKeys = wantSet

	local slots = slotTable()
	local current = {}
	for _, i in ipairs(open) do
		local slot = slots[tostring(i)]
		if slot and slot.unitId then
			current[slot.unitId] = i
		end
	end

	-- Already right? Nothing to do. Checked before the EquipBest shortcut because
	-- EquipBest re-slots and would churn the plot for no gain.
	local currentSet = {}
	for key in pairs(current) do
		currentSet[key] = true
	end
	-- Right units already. Only the order can still be wrong, and sortPass returns
	-- immediately when it isn't.
	if sameKeys(currentSet, wantSet) then
		if sortSlots then
			sortPass(want, open)
		end
		return
	end

	-- Where our answer and the server's agree, take the server's: one signal, atomic, and
	-- it collects every balance and orders the slots strongest-first on its way through --
	-- which also leaves the order correct, so no sortPass is needed after it.
	if sameKeys(wantSet, serverSet) then
		fire("PlotService", "EquipBest")
		say("equip: EquipBest (server ranking agrees)")
		return
	end

	if not alive() then
		say("equip: waiting for a character") -- UnitService.Equip needs a live Humanoid
		return
	end

	-- Adds richest first, drops poorest first, so the first pair is the best trade
	-- available. If that one can't clear the margin, none of the later ones can either.
	local adds, drops = {}, {}
	for _, u in ipairs(want) do
		if not current[u.key] then
			table.insert(adds, u)
		end
	end
	local byKey = {}
	for _, u in ipairs(list) do
		byKey[u.key] = u
	end
	for key, index in pairs(current) do
		if not wantSet[key] then
			table.insert(drops, { index = index, unit = byKey[key] })
		end
	end
	table.sort(adds, function(a, b)
		return a.proj > b.proj
	end)
	table.sort(drops, function(a, b)
		return (a.unit and a.unit.proj or 0) < (b.unit and b.unit.proj or 0)
	end)

	local empty = {}
	for _, i in ipairs(open) do
		local slot = slots[tostring(i)]
		if not (slot and slot.unitId) then
			table.insert(empty, i)
		end
	end

	local moved = 0
	for _, add in ipairs(adds) do
		local target = table.remove(empty, 1)
		if not target then
			local drop = drops[1]
			if not drop then
				break
			end
			local incumbent = drop.unit and drop.unit.proj or 0
			-- The displaced unit keeps its level and goes back to inventory, so a swap
			-- loses nothing permanently -- but the newcomer has to be re-levelled from 1,
			-- and that bill is why a 2% improvement isn't worth taking.
			if incumbent > 0 and add.proj < incumbent * SWAP_MARGIN then
				break
			end
			table.remove(drops, 1)
			target = drop.index
		end
		if placeInSlot(add.key, target) then
			moved = moved + 1
		end
		task.wait(SETTLE) -- consecutive Equips share one 0.5s debounce
	end
	if moved > 0 then
		say(("equip: placed %d unit%s"):format(moved, moved == 1 and "" or "s"))
	end
	-- The placement loop fills whatever slot was free, not the ranked one, so ordering is
	-- a separate pass over the same `want`.
	if sortSlots then
		sortPass(want, open)
	end
end

-- upgrade --------------------------------------------------------------------
-- LevelUpSlot takes a SLOT index, not a unit key -- only a slotted unit can be levelled,
-- which is exactly why the equip pass has to run first.
local rebirthOn = false
local maxRebirth = MAX_REBIRTH

-- What Upgrade is not allowed to spend below. Rebirth wipes Money to zero, so if Upgrade
-- drains the pot first the rebirth never happens -- and rebirths are what unlock slots
-- 5-13. A ninth slot is +100% income; a level is +25%.
local function rebirthReserve()
	if not (rebirthOn and Rebirths and type(Rebirths.GetNext) == "function") then
		return 0
	end
	local r = rebirthCount()
	if r >= maxRebirth then
		return 0
	end
	local ok, nxt = pcall(Rebirths.GetNext, r)
	if not ok or type(nxt) ~= "table" or type(nxt.cost) ~= "number" then
		return 0
	end
	return nxt.cost
end

local function upgradePass()
	if not (UnitUtil and type(UnitUtil.GetLevelPrice) == "function") then
		return
	end
	local target = upgradeTarget
	local levelled = 0
	for _ = 1, 200 do -- bounded: a refusal we mis-read must not spin forever
		local slots = slotTable()
		local best, bestIndex, bestLevel = nil, nil, nil
		local readOk, inv = pcall(Data.Inventory)
		if not readOk or type(inv) ~= "table" then
			return
		end
		for _, i in ipairs(unlockedSlots()) do
			local slot = slots[tostring(i)]
			local item = slot and slot.unitId and inv[slot.unitId]
			if item and cfgOf(item.name) then
				local level = (item.attributes or {}).level or 1
				-- Lowest level first. Payback is 1.6^(L-1) * 4 / (trait*grade) seconds --
				-- it doesn't depend on the unit's rarity at all -- so the cheapest level
				-- available anywhere on the plot is always the best next purchase.
				if level < target and (not bestLevel or level < bestLevel) then
					best, bestIndex, bestLevel = item, i, level
				end
			end
		end
		if not best then
			break
		end
		local ok, price = pcall(UnitUtil.GetLevelPrice, best.name, best.attributes or {})
		if not ok or type(price) ~= "number" then
			break
		end
		if money() - price < rebirthReserve() then
			say(("upgrade: holding %s for the next rebirth"):format(rebirthReserve() > 0 and "cash" or "off"))
			break
		end
		fire("PlotService", "LevelUpSlot", bestIndex)
		task.wait(0.15) -- level_up_unit debounce is 0.1s
		-- Confirm on the level actually moving. LevelUpSlot is a signal; "not enough
		-- money" comes back as a toast, not as a return value.
		local after = slotTable()[tostring(bestIndex)]
		local freshOk, fresh = pcall(Data.Inventory)
		local now = (freshOk and type(fresh) == "table" and after and after.unitId) and fresh[after.unitId] or nil
		local newLevel = now and (now.attributes or {}).level or bestLevel
		if newLevel <= bestLevel then
			break -- refused; nothing to be gained by asking again this pass
		end
		levelled = levelled + 1
		stats.levels = stats.levels + 1
	end
	if levelled > 0 then
		say(("upgrade: +%d level%s"):format(levelled, levelled == 1 and "" or "s"))
	end
end

-- sell -----------------------------------------------------------------------
-- SellUtil refuses anything slotted or `locked` on the server side, which covers "never
-- sell an equipped unit" for free. What it does NOT cover is the tower team -- that's
-- separate storage, and TowerService quietly nulls a team slot when its unit is sold.
local sellOn = false
local sellModes = { Rarity = false, Chance = false, Value = false }
local sellMatch = "Any"
local minRarity, minChance, minValue = "Mythical", 1000, 10000

local function protectedKeys(list)
	local safe = {}
	for key in pairs(wantedKeys) do
		safe[key] = true -- what the equip pass just decided to slot, before it lands
	end
	local slots = slotTable()
	for _, slot in pairs(slots) do
		if type(slot) == "table" and slot.unitId then
			safe[slot.unitId] = true
		end
	end
	for _, key in pairs(towerTeam()) do
		if type(key) == "string" then
			safe[key] = true
		end
	end
	-- Also the team we'd want NEXT: EquipBestTowerTeam re-ranks the whole inventory, so
	-- protecting only the current four lets the sweep eat its own replacements.
	local size = (TowerRefs and TowerRefs.MAX_TEAM_SIZE) or 4
	for _, u in ipairs(list) do
		u.dmg = damageOf(u.cfg, u.attrs)
	end
	local _, topDamage = topBy(list, "dmg", size)
	for key in pairs(topDamage) do
		safe[key] = true
	end
	return safe
end

local function sellPass()
	if not sellOn then
		return
	end
	if not (sellModes.Rarity or sellModes.Chance or sellModes.Value) then
		return
	end
	local list, couldRead = units()
	if not couldRead then
		return -- an unreadable inventory reads as empty, and empty protects nothing
	end
	local safe = protectedKeys(list)
	local floorRank = rarityRank[minRarity]
	local doomed = {}
	for _, u in ipairs(list) do
		if not safe[u.key] and not (u.attrs.locked) then
			local votes, checks = 0, 0
			if sellModes.Rarity and floorRank then
				checks = checks + 1
				local rank = rarityRank[rarityOf(u.cfg, u.attrs) or ""]
				-- An unrankable rarity is never junk. Guessing here sells something we
				-- cannot describe, which is the one mistake with no undo.
				if rank and rank < floorRank then
					votes = votes + 1
				end
			end
			if sellModes.Chance then
				checks = checks + 1
				local c = chanceOf(u.cfg, u.attrs)
				if c and c < minChance then
					votes = votes + 1
				end
			end
			if sellModes.Value and SellUtil and type(SellUtil.GetSellPrice) == "function" then
				checks = checks + 1
				local ok, price = pcall(SellUtil.GetSellPrice, u.name, u.attrs)
				if ok and type(price) == "number" and price < minValue then
					votes = votes + 1
				end
			end
			local junk = (sellMatch == "All") and (checks > 0 and votes == checks) or (votes > 0)
			if junk then
				table.insert(doomed, u.key)
			end
		end
	end
	if #doomed == 0 then
		return
	end
	-- One bulk call: SellInventory takes the whole list and the debounce is per-call, so
	-- a hundred separate sells would take ten seconds and gain nothing.
	local res = invoke("SellService", "SellInventory", doomed)
	local earned = res and res[1] or 0
	local sold = res and res[2] or #doomed
	stats.sold = stats.sold + sold
	stats.sellIncome = stats.sellIncome + earned
	say(("sell: %d unit%s"):format(sold, sold == 1 and "" or "s"))
	logEvent(("sold %d unit%s for $%s"):format(sold, sold == 1 and "" or "s", short(earned)))
end

-- pipeline -------------------------------------------------------------------
-- One thread, in order, because the ordering IS the correctness: a sell pass running
-- beside the equip pass would sell a unit that the equip pass had already decided to
-- slot, and no amount of shared state makes that reliably safe.
--
-- Woken by the inventory, not polled: RollDice returns BEFORE the unit exists (the server
-- grants it after RollDuration + RollDuration/3), so anything that reacts to the roll
-- call itself is reading yesterday's inventory.
local equipOn, upgradeOn = false, false
local pipelineGen, pipelineWake = 0, 0

function wakePipeline(_why)
	pipelineWake = os.clock()
end

local function startPipeline()
	pipelineGen = pipelineGen + 1
	local mine = pipelineGen
	task.spawn(function()
		local lastRun = 0
		while pipelineGen == mine do
			local now = os.clock()
			local due = (pipelineWake > 0 and now - pipelineWake >= PIPELINE_QUIET)
				or (now - lastRun >= PIPELINE_HEARTBEAT)
			if due and (equipOn or upgradeOn or sellOn) then
				pipelineWake, lastRun = 0, now
				if equipOn then
					pcall(equipPass)
				end
				if upgradeOn then
					pcall(upgradePass)
				end
				if sellOn then
					pcall(sellPass)
				end
			end
			task.wait(0.25)
		end
	end)
end

-- rebirth --------------------------------------------------------------------
local rebirthGen = 0
local function setRebirth(on)
	rebirthOn = on
	rebirthGen = rebirthGen + 1
	local mine = rebirthGen
	if not on then
		return
	end
	task.spawn(function()
		while rebirthOn and rebirthGen == mine do
			local r = rebirthCount()
			local nxt = Rebirths and Rebirths.GetNext and select(2, pcall(Rebirths.GetNext, r))
			if type(nxt) == "table" and type(nxt.cost) == "number" and r < maxRebirth then
				if money() >= nxt.cost then
					-- Uncollected slot balances survive a rebirth but Money does not, so
					-- sweeping first turns them into rebirth progress instead of leaving
					-- them stranded behind a wipe.
					sweepCash()
					task.wait(0.6)
					if money() >= nxt.cost then
						fire("RebirthService", "Rebirth")
						task.wait(1)
						-- A rebirth unlocks slots without adding a unit, so the inventory
						-- event never fires -- ask for the pass by hand.
						wakePipeline("rebirth")
						stats.rebirths = stats.rebirths + 1
						say(("rebirth %d -> %d"):format(r, r + 1))
						logEvent(("rebirth %d -> %d (slots may have unlocked)"):format(r, r + 1))
					end
				end
			end
			task.wait(3)
		end
	end)
end

-- towers ---------------------------------------------------------------------
-- Nothing about a tower is physical. PlayTower has no position check, combat is resolved
-- entirely inside TowerClass:completeFloor on the server, and the rewards are handed over
-- per floor by EntryService.Give -- there is no reward remote to fire. So this loop runs
-- from anywhere, at the same time as everything else, and shares nothing with them.
local towerOn, towerGen = false, 0
local selectedTower, autoSelectTower = nil, false
-- Declared up here because the tower loop uses them and the boosts section is further
-- down: TowerClass bakes the Damage Multiplier into a run at creation, so damage boosts
-- have to be burned by the tower loop right before PlayTower, not by the boost loop
-- whenever it next comes round.
local boostOn = false
local useDamageBoosts = function() end
local towerSay = function(_) end -- replaced once the Towers tab exists

-- Read once with a literal fallback: these are compared against every action the server
-- sends back, and indexing a nil TowerRefs there would kill the loop thread mid-run with
-- nothing on screen to say why.
local ACT_FLOOR_DONE = (TowerRefs and TowerRefs.Actions and TowerRefs.Actions.floorCompleted) or "floorCompleted"
local ACT_ENDED = (TowerRefs and TowerRefs.Actions and TowerRefs.Actions.ended) or "ended"
local TEAM_SIZE = (TowerRefs and TowerRefs.MAX_TEAM_SIZE) or 4

local towerNames = {}
if TowerList and type(TowerList.GetAll) == "function" then
	local ok, all = pcall(TowerList.GetAll)
	if ok and type(all) == "table" then
		for name, cfg in pairs(all) do
			table.insert(towerNames, { name = name, order = cfg.order or 99 })
		end
		table.sort(towerNames, function(a, b)
			return a.order < b.order
		end)
	end
end

local function teamStats()
	local team, inv = towerTeam(), nil
	local ok, got = pcall(Data.Inventory)
	if ok and type(got) == "table" then
		inv = got
	end
	if not inv then
		return {}
	end
	local dmgBuff, hpBuff = buff("Damage Multiplier", 1), buff("Health Multiplier", 1)
	local out = {}
	for i = 1, ((TowerRefs and TowerRefs.MAX_TEAM_SIZE) or 4) do
		local key = team[i]
		local item = key and inv[key]
		local cfg = item and cfgOf(item.name)
		if cfg then
			table.insert(out, {
				damage = damageOf(cfg, item.attributes or {}) * dmgBuff,
				health = healthOf(cfg, item.attributes or {}) * hpBuff,
			})
		end
	end
	return out
end

-- Replays the server's own arithmetic. Every input is in the shared config, so this isn't
-- a model of the fight -- it IS the fight, minus the drop rolls. What it buys us is the
-- ability to answer "which tower is worth running" before paying 3s to find out.
local function simulate(towerName, team)
	if not (TowerList and TowerRefs) or #team == 0 then
		return nil
	end
	local ok, cfg = pcall(TowerList.Get, towerName)
	if not ok or type(cfg) ~= "table" then
		return nil
	end
	local hp = {}
	for i, m in ipairs(team) do
		hp[i] = m.health
	end
	local wait = TowerRefs.ActionWaitTime
	local startWait = TowerRefs.FloorStartedWaitTime
	local floor, member, elapsed, items = 1, 1, 0, 0
	local guard = 0
	while member <= #team do
		guard = guard + 1
		if guard > 5000 then
			break -- a config that can never resolve must not hang the panel
		end
		local enemy = cfg.enemyHealth(floor)
		local hit = cfg.enemyDamage(floor)
		-- Each CompleteTowerFloor call starts the enemy at full health and runs until the
		-- floor is cleared or the team is wiped, so a call is one floor, not one exchange.
		elapsed = elapsed + (floor == 1 and startWait.initial or startWait.transition)
		local first = true
		while true do
			if not first then
				elapsed = elapsed + startWait.repeated
			end
			first = false
			enemy = enemy - team[member].damage
			elapsed = elapsed + wait.damageEnemy
			if enemy <= 0 then
				elapsed = elapsed + wait.floorCompleted
				for _, tier in ipairs(cfg.drops) do
					if tier.minFloor <= floor then
						for _, entry in ipairs(tier.entries) do
							items = items + (entry.amount * entry.chance / 100)
						end
					end
				end
				floor = floor + 1
				break
			end
			hp[member] = hp[member] - hit
			elapsed = elapsed + wait.damagePlayer
			if hp[member] <= 0 then
				elapsed = elapsed + wait.memberDefeated
				member = member + 1
				if member > #team then
					break
				end
			end
		end
		if cfg.maxFloors and floor > cfg.maxFloors then
			break
		end
	end
	-- ponytail: one number for "how good is this run" -- expected dropped items per
	-- second, counting a Gem and a Luck I as one item each. Swap in a per-entry weight if
	-- you start caring about gems specifically.
	return { floor = floor - 1, seconds = elapsed, items = items, rate = elapsed > 0 and items / elapsed or 0 }
end

local towerReport = "no team"
local function refreshTowerReport()
	local team = teamStats()
	if #team == 0 then
		towerReport = "no tower team equipped"
		return nil
	end
	local lines, best, bestRate = {}, nil, -1
	for _, entry in ipairs(towerNames) do
		local sim = simulate(entry.name, team)
		if sim then
			table.insert(lines, ("%s: floor %d, %.1f items/min"):format(entry.name, sim.floor, sim.rate * 60))
			if sim.rate > bestRate then
				best, bestRate = entry.name, sim.rate
			end
		end
	end
	towerReport = table.concat(lines, "\n")
	return best
end

-- Ends a run and makes sure the SERVER agrees it ended. CancelTower only sets
-- endingQueued; TowerClass destroys the tower object inside the NEXT completeFloor call,
-- and TowerService keeps exactly one tower per player. The game's own controller gets
-- away with fire-and-forget because its floor loop is still running and makes that call
-- for it -- ours isn't. Skip the drain and the tower lives on the server for the rest of
-- the session, and every later PlayTower is refused with a plain nil.
local function endTower()
	local cancelled = invoke("Towers", "CancelTower")
	if not (cancelled and cancelled[1] == true) then
		return true -- CancelTower returns false when there was nothing running
	end
	-- The last floor's own animation cooldown still has to expire before the server will
	-- take another call, so this is a retry, not a single poke.
	local deadline = os.clock() + 25
	while os.clock() < deadline do
		local seq = invoke("Towers", "CompleteTowerFloor")
		if type(seq) == "table" and type(seq[1]) == "table" then
			for _, action in ipairs(seq[1]) do
				if action.action == ACT_ENDED then
					return true
				end
			end
		end
		task.wait(0.4)
	end
	warn("[AnimeDice] tower would not close -- rejoin if Auto Tower stays stuck")
	return false
end

local function setTower(on)
	towerOn = on
	towerGen = towerGen + 1
	local mine = towerGen
	if not on then
		-- On its own thread: called from teardown, and endTower is allowed to sit for
		-- several seconds. A window close that hangs reads as a crash.
		task.spawn(endTower)
		return
	end
	task.spawn(function()
		while towerOn and towerGen == mine do
			-- Damage ignores level entirely, so the best tower team only changes when a
			-- rarer unit arrives -- there is nothing to keep re-equipping.
			--
			-- Compared in ORDER, not as a set. Units fight one at a time in TowerTeam index
			-- order -- index 1 until it dies, then 2 -- so the same four units arranged
			-- wrongly means opening with your weakest and dying shallower. A set
			-- comparison sees nothing wrong with that. EquipBestTowerTeam writes them
			-- damage-descending with the same key tiebreak topBy uses, so once it has run
			-- this check passes and stops re-firing.
			local list = units()
			for _, u in ipairs(list) do
				u.dmg = damageOf(u.cfg, u.attrs)
			end
			local wantOrder = topBy(list, "dmg", TEAM_SIZE)
			local have = towerTeam()
			local ordered = #wantOrder > 0
			for i, unit in ipairs(wantOrder) do
				if have[i] ~= unit.key then
					ordered = false
					break
				end
			end
			if have[#wantOrder + 1] ~= nil then
				ordered = false -- a stale entry past the end, left by a shrunken inventory
			end
			if not ordered then
				fire("Towers", "EquipBestTowerTeam")
				task.wait(1.1) -- 1s debounce on EquipBestTowerTeam
			end
			-- TowerClass.new returns nil on an empty team and PlayTower then answers with
			-- a bare nil, which is indistinguishable from every other refusal. Say it
			-- here, where we can actually tell.
			if next(towerTeam()) == nil then
				towerSay("no tower team -- roll or unlock some units first")
				task.wait(3)
				continue
			end

			local pick = autoSelectTower and refreshTowerReport() or selectedTower
			if not pick then
				towerSay("pick a tower first")
				task.wait(2)
			else
				-- Last thing before starting: TowerClass reads Damage Multiplier ONCE, at
				-- creation, so a boost used a second later does nothing for this run.
				if boostOn then
					useDamageBoosts()
				end
				local started = invoke("Towers", "PlayTower", pick)
				if not (started and started[1]) then
					-- PlayTower is refused for exactly two reasons worth telling apart:
					-- the 3s debounce, or a tower already running for us. Only the second
					-- is permanent, and the cure is to actually close that one out.
					towerSay(("%s refused -- closing any stuck run"):format(pick))
					endTower()
					task.wait(3.2) -- playTower debounce is 3s
				else
					local floors = 0
					local lastReply = os.clock()
					towerSay(("%s -- started"):format(pick))
					while towerOn and towerGen == mine do
						local seq = invoke("Towers", "CompleteTowerFloor")
						if type(seq) ~= "table" or type(seq[1]) ~= "table" then
							-- nil is the server's own animation cooldown OR no tower left.
							-- Budgeted in seconds, not tries: a floor where a member eats
							-- twenty hits is a legitimate 13s+ of sequence to wait out,
							-- and a fixed try count would abandon a healthy run.
							if os.clock() - lastReply > 30 then
								towerSay(("%s -- no reply for 30s, restarting"):format(pick))
								break
							end
							task.wait(0.25)
						else
							lastReply = os.clock()
							local ended = false
							for _, action in ipairs(seq[1]) do
								if action.action == ACT_FLOOR_DONE then
									floors = floors + 1
									stats.floors = stats.floors + 1
									-- The only loot feed there is: DropNotification is
									-- never fired for towers, but the server hands the
									-- per-floor drop table back in the sequence itself.
									if type(action.rewards) == "table" then
										local got = {}
										for name, amount in pairs(action.rewards) do
											addLoot(name, amount)
											table.insert(got, ("%s x%d"):format(name, amount))
										end
										if #got > 0 then
											table.sort(got)
											logEvent(("floor %d: %s"):format(action.floor or floors, table.concat(got, ", ")))
										end
									end
								elseif action.action == ACT_ENDED then
									ended = true
								end
							end
							towerSay(("%s -- %d floor%s cleared"):format(pick, floors, floors == 1 and "" or "s"))
							if ended then
								logEvent(("%s ended at floor %d"):format(pick, floors))
								break
							end
						end
					end
					-- Whatever got us out, leave nothing running: a break on the timeout
					-- above is exactly the state that would refuse the next PlayTower.
					endTower()
					task.wait(3.2)
				end
			end
		end
	end)
end

-- rerolls --------------------------------------------------------------------
-- The biggest income lever in the game, and it runs on tower loot. Grades multiply income
-- x1.1 to x25, traits x1.2 to x15, and both MULTIPLY the same unit -- a locked S+ and a
-- Monarch together is x80 on everything that unit will ever earn.
--
-- The catch is that a reroll is not an improvement: it replaces the value outright, and
-- the weighted average grade is only x1.54. So rolling a unit that's already sitting at
-- A+ loses income in expectation. What you're buying is the lock: S/S+/Z/Z+ and
-- Samurai/Shogun/Monarch/Transcendent are `protected`, and the server checks that BEFORE
-- spending the item, so a locked unit is permanent and costs nothing to ask about again.
--
-- Hence one unit at a time. The lock chance per item is the same whoever you spend it on
-- (~1.05% for grades, ~0.67% for traits), so concentrating on the single best slotted unit
-- costs nothing and keeps the interim slump confined to one slot instead of all thirteen.
local function heldAmount(entryName)
	local ok, inv = pcall(Data.Inventory)
	if not ok or type(inv) ~= "table" then
		return 0
	end
	-- Stackable entries key on the entry NAME, not a GUID (EntryService.Give), so "Gems"
	-- and "Trait Reroll" are looked up directly.
	local row = inv[entryName]
	return (type(row) == "table" and row.amount) or 0
end

-- Highest projected income among slotted units whose field isn't locked yet. Slotted only:
-- a reroll spent on a unit that isn't earning is spent on nothing.
local function rerollTarget(field, tbl)
	local slots = slotTable()
	local ok, inv = pcall(Data.Inventory)
	if not ok or type(inv) ~= "table" then
		return nil
	end
	local best, bestProj = nil, nil
	for _, i in ipairs(unlockedSlots()) do
		local slot = slots[tostring(i)]
		local key = slot and slot.unitId
		local item = key and inv[key]
		local cfg = item and cfgOf(item.name)
		if cfg then
			local attrs = item.attributes or {}
			local current = attrs[field]
			local meta = current and tbl[current]
			if not (meta and meta.protected) then
				local proj = incomeAt(cfg, attrs, COMPARISON_LEVEL)
				if not bestProj or proj > bestProj then
					best, bestProj = { key = key, name = item.name }, proj
				end
			end
		end
	end
	return best
end

-- One shape, two instances. Returns the setter the toggle calls.
local function rerollLoop(opts)
	local on, gen = false, 0
	return function(enable)
		on = enable
		gen = gen + 1
		local mine = gen
		if not on then
			return
		end
		task.spawn(function()
			while on and gen == mine do
				if not opts.tbl then
					say(opts.label .. ": module missing")
					task.wait(5)
				elseif heldAmount(opts.item) < 1 then
					task.wait(2) -- nothing to spend; towers will bring more
				else
					local target = rerollTarget(opts.field, opts.tbl)
					if not target then
						-- Every slotted unit is locked. Nothing left to buy, so idle
						-- rather than burn items on units that would refuse anyway.
						say(opts.label .. ": every slotted unit is locked")
						task.wait(5)
					else
						local before = heldAmount(opts.item)
						fire(opts.service, "Roll", target.key)
						task.wait(REROLL_GAP)
						local after = heldAmount(opts.item)
						if after < before then
							-- Count what was actually SPENT, not what was asked: a target
							-- that locked between the pick and the fire costs nothing.
							stats[opts.counter] = stats[opts.counter] + (before - after)
							local okInv, inv = pcall(Data.Inventory)
							local row = okInv and type(inv) == "table" and inv[target.key] or nil
							local now = row and (row.attributes or {})[opts.field]
							local meta = now and opts.tbl[now]
							if meta and meta.protected then
								logEvent(("%s LOCKED %s on %s"):format(opts.label, tostring(now), target.name))
							end
							-- Grade and trait both feed cfg.income, so the ranking just
							-- changed -- but an attribute write fires no OnKeyAdded, so
							-- the pipeline has to be told by hand.
							wakePipeline("reroll")
						end
					end
				end
			end
		end)
	end
end

local setGradeReroll = rerollLoop({
	service = "GradeService",
	item = "Gems",
	field = "grade",
	tbl = Grades,
	label = "grade",
	counter = "gems",
})
local setTraitReroll = rerollLoop({
	service = "TraitService",
	item = "Trait Reroll",
	field = "trait",
	tbl = TraitTable,
	label = "trait",
	counter = "rerolls",
})

-- boosts ---------------------------------------------------------------------
-- Stacking is lossless: BoostService sets remaining = remaining + duration on the entry's
-- own ActiveEntries row, and different tiers are separate rows with multiplicative buffs.
-- So there is no "is a better one already running" check to write -- the only real waste
-- is burning a boost on a system that isn't switched on, or at a moment it can't reach.
local function boostKind(cfg)
	local buffs = cfg.buffs
	if type(buffs) ~= "table" then
		return nil
	end
	-- Read the buff it grants, not the `category` string: a renamed category would
	-- silently disable the feature, a renamed buff key would break the game itself.
	if buffs.Luck then
		return "luck"
	end
	if buffs["Damage Multiplier"] then
		return "damage"
	end
	if buffs["Money Multiplier"] then
		return "money"
	end
	return nil
end

-- Uses every boost of one kind that you hold. Returns how many went out.
local function useBoostKind(kind)
	local ok, inv = pcall(Data.Inventory)
	if not ok or type(inv) ~= "table" then
		return 0
	end
	-- Snapshot first. Using a boost rewrites the inventory, and mutating the table we're
	-- iterating is how you get "invalid key to 'next'".
	local todo = {}
	for key, item in pairs(inv) do
		if type(item) == "table" and (item.amount or 0) > 0 then
			local cfg = Registry.getEntryConfig(item.name)
			if cfg and cfg.kind == "Boost" and boostKind(cfg) == kind then
				table.insert(todo, { key = key, name = item.name, amount = item.amount })
			end
		end
	end
	local used = 0
	for _, entry in ipairs(todo) do
		for _ = 1, entry.amount do
			fire("BoostService", "Use", entry.key)
			stats.boosts = stats.boosts + 1
			used = used + 1
			task.wait(BOOST_GAP)
		end
		logEvent(("used %d x %s"):format(entry.amount, entry.name))
	end
	return used
end

useDamageBoosts = function()
	return useBoostKind("damage")
end

local boostGen = 0
local function setBoosts(on)
	boostOn = on
	boostGen = boostGen + 1
	local mine = boostGen
	if not on then
		return
	end
	task.spawn(function()
		while boostOn and boostGen == mine do
			-- Luck only pays while something is rolling.
			if rollOn then
				useBoostKind("luck")
			end
			-- Income accrues whether or not anything else is running.
			if boostOn and boostGen == mine then
				useBoostKind("money")
			end
			-- Damage is deliberately NOT here. The tower loop burns those at PlayTower,
			-- which is the only moment they can affect a run.
			task.wait(10)
		end
	end)
end

-- rewards --------------------------------------------------------------------
local function claimAll()
	fire("DailyRewardService", "Claim")
	fire("GroupRewardService", "Claim")
	fire("OfflineEarningsService", "Claim")
	-- QuestService.Claim wants (period, questId, expiresAt) and checks the expiry against
	-- your own save, so the arguments have to come from the live data rather than a list.
	if QuestConfig and type(QuestConfig.Periods) == "table" then
		local ok, quests = pcall(Data.Quests)
		if ok and type(quests) == "table" then
			for period, cfg in pairs(QuestConfig.Periods) do
				local mine = quests[period]
				if type(mine) == "table" and type(cfg.quests) == "table" then
					for _, quest in ipairs(cfg.quests) do
						local done = (mine.progress or {})[quest.id] or 0
						if done >= (quest.target or math.huge) and not (mine.claimed or {})[quest.id] then
							fire("QuestService", "Claim", period, quest.id, mine.expiresAt)
							task.wait(0.25) -- QuestClaim debounce is 0.2s
						end
					end
				end
			end
		end
	end
end

local function redeemCodes()
	if not (MonetizationConfig and type(MonetizationConfig.Codes) == "table") then
		return 0
	end
	-- Read the codes out of the game's own config instead of hardcoding a list, so an
	-- update's new code redeems itself.
	local n = 0
	for code in pairs(MonetizationConfig.Codes) do
		fire("MonetizationService", "RedeemCode", code)
		n = n + 1
		task.wait(0.6) -- RedeemCode debounce is 0.5s
	end
	return n
end

local rewardsOn, rewardsGen = false, 0
local function setRewards(on)
	rewardsOn = on
	rewardsGen = rewardsGen + 1
	local mine = rewardsGen
	if not on then
		return
	end
	task.spawn(function()
		while rewardsOn and rewardsGen == mine do
			pcall(claimAll)
			task.wait(60)
		end
	end)
end

-- cash loop ------------------------------------------------------------------
local cashOn, cashGen = false, 0
local function setCash(on)
	cashOn = on
	cashGen = cashGen + 1
	local mine = cashGen
	if not on then
		return
	end
	task.spawn(function()
		while cashOn and cashGen == mine do
			pcall(sweepCash)
			task.wait(COLLECT_GAP)
		end
	end)
end

-- gui ------------------------------------------------------------------------
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a restyle
-- is one file and not forty. Fetched here rather than installed by the loader, so this
-- file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Anime Dice",
	folder = "AnimeDice", -- never rename: WindUI's saved configs are keyed on this
	size = UDim2.fromOffset(520, 430),
})
if not Window then
	return -- panel.lua already said why
end

local MainTab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local UnitTab = Window:Tab({ Title = "Units", Icon = "solar:users-group-rounded-bold" })
local TowerTab = Window:Tab({ Title = "Towers", Icon = "solar:buildings-2-bold" })
local ExtraTab = Window:Tab({ Title = "Rewards", Icon = "solar:gift-bold" })

local BoardSec = MainTab:Section({ Title = "Overview", Icon = "solar:chart-2-bold", Box = true, BoxBorder = true, Opened = true })
-- Three cards rather than one block: WindUI renders a Paragraph's Title heavier than its
-- body, so the headings do the grouping work that column alignment can't -- the panel font
-- is proportional, so padded columns would not line up anyway.
local boardWallet = BoardSec:Paragraph({ Title = "Wallet", Desc = "starting..." })
local boardSession = BoardSec:Paragraph({ Title = "Session", Desc = "starting..." })
local boardLoot = BoardSec:Paragraph({ Title = "Loot", Desc = "nothing yet" })

local RollSec = MainTab:Section({ Title = "Rolling", Icon = "solar:dice-bold", Box = true, BoxBorder = true, Opened = true })
local CashSec = MainTab:Section({ Title = "Cash", Icon = "solar:dollar-minimalistic-bold", Box = true, BoxBorder = true, Opened = true })

RollSec:Toggle({
	Title = "Auto Roll",
	Desc = "Invokes RollDice on the server cooldown, skipping the roll cutscene",
	Value = false,
	Callback = function(v) -- :Set() re-fires this, so both branches must be re-entrant
		setRolling(v)
		if not v then
			say("idle")
		end
	end,
})

CashSec:Toggle({
	Title = "Auto Collect Cash",
	Desc = "Collects every unlocked slot's balance -- no walking, no plot lookup",
	Value = false,
	Callback = setCash,
})

CashSec:Button({
	Title = "Collect now",
	Callback = function()
		say(("collected %d slot(s)"):format(sweepCash()))
	end,
})

CashSec:Toggle({
	Title = "Auto Rebirth",
	Desc = "Rebirths when affordable -- this is what unlocks slots 5-13",
	Value = false,
	Callback = function(v)
		setRebirth(v)
		wakePipeline("rebirth-toggle")
	end,
})

CashSec:Input({
	Title = "Stop rebirthing at",
	Desc = "10 unlocks every slot. Past that you're buying multipliers, not slots.",
	Value = tostring(MAX_REBIRTH),
	Placeholder = "10",
	Callback = function(text)
		local n = tonumber(text)
		if n and n >= 0 then
			maxRebirth = math.floor(n)
		else
			say("rebirth cap unchanged -- needs a number")
		end
	end,
})

local EquipSec = UnitTab:Section({ Title = "Equip & Upgrade", Icon = "solar:ranking-bold", Box = true, BoxBorder = true, Opened = true })
local SellSec = UnitTab:Section({ Title = "Sell", Icon = "solar:tag-price-bold", Box = true, BoxBorder = true, Opened = true })

EquipSec:Toggle({
	Title = "Auto Equip Best",
	Desc = "Ranks by projected income, so a rare level-1 can displace a levelled common",
	Value = false,
	Callback = function(v)
		equipOn = v
		wakePipeline("equip-toggle")
	end,
})



EquipSec:Toggle({
	Title = "Sort slots strongest-first",
	Desc = "Cosmetic, and slow -- about a second per slot out of place. A slot pays its own unit's income, not its position.",
	Value = false,
	Callback = function(v)
		sortSlots = v
		wakePipeline("sort-toggle")
	end,
})

EquipSec:Toggle({
	Title = "Auto Upgrade",
	Desc = "Levels slotted units, lowest level first",
	Value = false,
	Callback = function(v)
		upgradeOn = v
		wakePipeline("upgrade-toggle")
	end,
})

EquipSec:Input({
	Title = "Upgrade to level",
	Desc = "Payback is 4 x 1.6^(L-1) seconds: ~5min at 10, ~48min at 15, ~8h at 20",
	Value = tostring(UPGRADE_TARGET),
	Placeholder = "20",
	Callback = function(text)
		local n = tonumber(text)
		if n and n >= 1 then
			upgradeTarget = math.floor(n)
			wakePipeline("upgrade-level")
		else
			say("upgrade target unchanged -- needs a number >= 1")
		end
	end,
})

EquipSec:Toggle({
	Title = "Auto Grade Reroll",
	Desc = "Spends Gems on the best slotted unit until its grade locks (S/S+/Z/Z+), then the next",
	Value = false,
	Callback = setGradeReroll,
})

EquipSec:Toggle({
	Title = "Auto Trait Reroll",
	Desc = "Same, with Trait Rerolls. Locks at Samurai/Shogun/Monarch/Transcendent.",
	Value = false,
	Callback = setTraitReroll,
})

SellSec:Toggle({
	Title = "Auto Sell",
	Desc = "Runs after the equip pass, so nothing is sold before it's been judged",
	Value = false,
	Callback = function(v)
		sellOn = v
		wakePipeline("sell-toggle")
	end,
})

SellSec:Dropdown({
	Title = "Filters",
	Desc = "Rarity and Chance are the same axis -- rarity IS a chance bucket",
	Values = { "Rarity", "Chance", "Value" },
	Value = {},
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		-- Rebuilt rather than patched: WindUI hands over the whole selection, in click
		-- order, and mutates its own table in place -- so copy out, never hold the ref.
		sellModes = { Rarity = false, Chance = false, Value = false }
		if type(values) == "table" then
			for k, v in pairs(values) do
				local name = type(v) == "string" and v or (v == true and k or nil)
				if name and sellModes[name] ~= nil then
					sellModes[name] = true
				end
			end
		end
	end,
})

SellSec:Dropdown({
	Title = "Match",
	Desc = "Any: sell if one filter calls it junk. All: sell only if every filter does.",
	Values = { "Any", "All" },
	Value = "Any",
	Callback = function(v)
		if v == "Any" or v == "All" then
			sellMatch = v
		end
	end,
})

SellSec:Dropdown({
	Title = "Sell below rarity",
	Values = rarityNames,
	Value = rarityRank["Mythical"] and "Mythical" or rarityNames[1],
	Callback = function(v)
		-- Ignore an unknown value instead of assigning it: this callback also fires on a
		-- rebuild, with whatever placeholder the dropdown happens to hold.
		if rarityRank[v] then
			minRarity = v
		end
	end,
})

SellSec:Input({
	Title = "Sell below 1 in N",
	Desc = "Accepts 10Qd, 2.5b, 1e16 or plain digits -- the panel echoes back what it read",
	Value = tostring(minChance),
	Placeholder = "10Qd",
	Callback = function(text)
		local n = parseAmount(text)
		if n then
			minChance = n
			-- Echo the parsed value back: "10Qd" and "10qd" and "10,000,000,000,000,000"
			-- are the same number, and the only way to be sure it read what you meant is
			-- to see it printed in the form you can already recognise elsewhere.
			say(("sell below 1 in %s"):format(short(n)))
		else
			say(("chance floor unchanged (still 1 in %s) -- couldn't read that"):format(short(minChance)))
		end
	end,
})

SellSec:Input({
	Title = "Sell below value",
	Desc = "Sell price is income x 40 -- the only filter that sees trait/grade/level. Accepts 10Qd, 2.5b, 1e16.",
	Value = tostring(minValue),
	Placeholder = "10Qd",
	Callback = function(text)
		local n = parseAmount(text)
		if n then
			minValue = n
			say(("sell below $%s"):format(short(n)))
		else
			say(("value floor unchanged (still $%s) -- couldn't read that"):format(short(minValue)))
		end
	end,
})

local TowerSec = TowerTab:Section({ Title = "Tower", Icon = "solar:sword-bold", Box = true, BoxBorder = true, Opened = true })
local towerLine

local names = {}
for _, entry in ipairs(towerNames) do
	table.insert(names, entry.name)
end
selectedTower = names[1]

TowerSec:Dropdown({
	Title = "Tower",
	Values = names,
	Value = selectedTower,
	Callback = function(v)
		for _, name in ipairs(names) do
			if name == v then
				selectedTower = v
				return
			end
		end
	end,
})

TowerSec:Toggle({
	Title = "Auto Tower",
	Desc = "Server-side combat -- runs from anywhere, alongside everything else",
	Value = false,
	Callback = function(v)
		setTower(v)
		if not v then
			towerSay("off")
		end
	end,
})

TowerSec:Toggle({
	Title = "Auto-select best tower",
	Desc = "Simulates all four with your team and takes the best expected drops/second",
	Value = false,
	Callback = function(v)
		autoSelectTower = v
	end,
})

TowerSec:Button({
	Title = "Simulate all towers",
	Callback = function()
		refreshTowerReport()
		if towerLine then
			pcall(function()
				towerLine:SetDesc(towerReport)
			end)
		end
	end,
})

towerLine = TowerSec:Paragraph({ Title = "Predicted runs", Desc = "press Simulate" })

-- The tower loop reports here rather than into the Main tab's status, because the Towers
-- tab is where you're looking when you want to know whether it's doing anything. Same
-- upvalue-plus-Heartbeat trick as `say`: a resumed loop thread can't touch the GUI.
local towerPending = nil
towerSay = function(msg)
	towerPending = msg
end
local towerStatus = TowerSec:Paragraph({ Title = "Tower status", Desc = "off" })
local towerDrain
towerDrain = RunService.Heartbeat:Connect(function()
	if towerPending == nil then
		return
	end
	local msg = towerPending
	towerPending = nil
	if not pcall(function()
		towerStatus:SetDesc(msg)
	end) then
		print("[AnimeDice][tower]", msg)
	end
end)

local RewardSec = ExtraTab:Section({ Title = "Rewards", Icon = "solar:gift-bold", Box = true, BoxBorder = true, Opened = true })

RewardSec:Toggle({
	Title = "Auto claim rewards",
	Desc = "Daily, group, offline earnings and finished quests, every 60s",
	Value = false,
	Callback = setRewards,
})

RewardSec:Button({
	Title = "Claim now",
	Callback = function()
		task.spawn(function()
			pcall(claimAll)
			say("claimed what was available")
		end)
	end,
})

RewardSec:Toggle({
	Title = "Auto use boosts",
	Desc = "Luck only while rolling, Damage only while towering, Income always",
	Value = false,
	Callback = setBoosts,
})

RewardSec:Button({
	Title = "Redeem all codes",
	Callback = function()
		task.spawn(function()
			say(("redeeming %d code(s)"):format(redeemCodes()))
		end)
	end,
})

local line = MainTab:Section({ Title = "Status", Icon = "solar:info-circle-bold", Box = true, BoxBorder = true, Opened = true }):Paragraph({
	Title = "Status",
	Desc = "idle",
})

-- Held in an upvalue and disconnected by stopAll: it outlives Window:Destroy otherwise,
-- re-pcalling into a destroyed row every frame, and every re-paste adds another.
local drain
drain = RunService.Heartbeat:Connect(function()
	if pending == nil then
		return
	end
	local msg = pending
	pending = nil
	if not pcall(function()
		line:SetDesc(msg)
	end) then
		print("[AnimeDice]", msg)
	end
end)

-- The whole board is rendered from one Heartbeat, throttled. Heartbeat is called with our
-- own identity, so unlike the loop threads this can read the data AND write the rows in
-- the same place -- no pending/drain dance needed here.
local SEP = "   \u{00B7}   " -- middle dot; the panel font is proportional, so a separator
-- reads as a column boundary where padded spaces just look like a ragged gap.

local function walletText()
	local rows = { ("$%s%s+%s/s"):format(short(money()), SEP, short(incomePerSec())) }
	local r = rebirthCount()
	-- As a percentage, because the raw tiers run 5e4 up to 1e24 and are impossible to
	-- eyeball against a compact-formatted balance.
	local nxt
	if Rebirths and type(Rebirths.GetNext) == "function" then
		local ok, got = pcall(Rebirths.GetNext, r)
		nxt = (ok and type(got) == "table" and type(got.cost) == "number" and got.cost > 0) and got or nil
	end
	if nxt then
		table.insert(rows, ("Rebirth %d \u{2192} %d%s%.1f%% of $%s"):format(r, r + 1, SEP, math.min(money() / nxt.cost * 100, 100), short(nxt.cost)))
	else
		table.insert(rows, ("Rebirth %d%smaxed"):format(r, SEP))
	end
	return table.concat(rows, "\n")
end

local function sessionText()
	local up = os.clock() - startedAt
	local cap = math.floor(buff("Unit Storage", 100) + (buff("Rolls", 1) - 1))
	local rows = {
		("%d:%02d uptime%s%d rolls%s%.1f/min"):format(
			math.floor(up / 60), math.floor(up % 60), SEP, stats.rolls, SEP, up > 0 and stats.rolls / up * 60 or 0
		),
		("Luck x%s%sInventory %d/%d"):format(short(luckNow()), SEP, #(units()), cap),
	}
	-- Only counters that have actually moved. A row of zeroes for every switched-off
	-- feature is noise, and "rebirths 0" sitting under "Rebirth 8" read as a contradiction.
	local moved = {}
	local function add(n, label)
		if n > 0 then
			table.insert(moved, n .. " " .. label)
		end
	end
	add(stats.gained, "kept")
	add(stats.sold, "sold")
	add(stats.levels, "levels")
	add(stats.floors, "floors")
	add(stats.rebirths, "rebirths")
	add(stats.gems, "gem rolls")
	add(stats.rerolls, "trait rolls")
	add(stats.boosts, "boosts")
	if #moved > 0 then
		table.insert(rows, table.concat(moved, SEP))
	end
	if stats.sellIncome > 0 then
		table.insert(rows, ("Sales $%s"):format(short(stats.sellIncome)))
	end
	if stats.best ~= "" then
		table.insert(rows, "Best  " .. stats.best)
	end
	return table.concat(rows, "\n")
end

local function lootText()
	local groups = {}
	for name, amount in pairs(stats.loot) do
		local fam = lootFamily(name)
		groups[fam] = (groups[fam] or 0) + amount
	end
	local list = {}
	for fam, amount in pairs(groups) do
		table.insert(list, { fam = fam, n = amount })
	end
	if #list == 0 then
		return "nothing yet"
	end
	table.sort(list, function(a, b)
		if a.n == b.n then
			return a.fam < b.fam
		end
		return a.n > b.n
	end)
	local out = {}
	for i = 1, math.min(#list, 6) do
		table.insert(out, ("%s x%d"):format(list[i].fam, list[i].n))
	end
	if #list > 6 then
		table.insert(out, ("+%d more"):format(#list - 6))
	end
	return table.concat(out, SEP)
end

local boardTick = 0
local boardConn
boardConn = RunService.Heartbeat:Connect(function(dt)
	boardTick = boardTick + dt
	if boardTick < BOARD_REFRESH then
		return
	end
	boardTick = 0
	pcall(function()
		boardWallet:SetDesc(walletText())
		boardSession:SetDesc(sessionText())
		boardLoot:SetDesc(lootText())
	end)
end)

-- wiring ---------------------------------------------------------------------
-- The server's own notification channels. TextNotification is the ONLY place strings like
-- "Your unit inventory is full" or "You can't afford to level this up!" are ever worded --
-- they exist in no client script -- so this is the answer to "why did it stop".
local noteConns = {}
do
	local text = remote("NotificationService", "RE", "TextNotification")
	if text then
		table.insert(noteConns, text.OnClientEvent:Connect(function(payload)
			if type(payload) == "table" and type(payload.message) == "string" then
				logEvent("[server] " .. payload.message)
			end
		end))
	end
	-- Fired only by the Daily / Group / Quest claims -- rolls and tower floors do NOT come
	-- through here, which is why those two are counted at their own source instead.
	local drop = remote("NotificationService", "RE", "DropNotification")
	if drop then
		table.insert(noteConns, drop.OnClientEvent:Connect(function(name, amount)
			if type(name) == "string" then
				addLoot(name, amount or 1)
				logEvent(("claimed %s x%s"):format(name, tostring(amount or 1)))
			end
		end))
	end
end

-- The inventory Value fires this when the server grants a rolled unit, which is the only
-- honest signal that a roll finished. Falls back to the pipeline's own heartbeat if the
-- accessor isn't there, so a framework change costs latency rather than the feature.
local unhook
do
	local ok, disconnect = pcall(function()
		return Data.Inventory.OnKeyAdded(function(key)
			wakePipeline("inventory")
			-- Also the "what rolled" feed. Units are stackable = false, so every pull is
			-- a brand new key and lands here exactly once. Stackables (Gems, boosts) only
			-- fire the first time you ever own one, which is why loot is counted at the
			-- tower and claim ends instead.
			local okInv, inv = pcall(Data.Inventory)
			local item = (okInv and type(inv) == "table" and type(key) == "string") and inv[key] or nil
			local cfg = item and cfgOf(item.name)
			if not cfg then
				return
			end
			local attrs = item.attributes or {}
			stats.gained = stats.gained + 1
			local chance = chanceOf(cfg, attrs)
			-- Track the rarest pull of the session on the mutation-adjusted chance, which
			-- is what actually made it rare.
			if chance and chance > stats.bestChance then
				stats.bestChance = chance
				stats.best = describe(item.name, attrs, cfg)
			end
			-- A mutation always prints: it multiplies the base chance by 10 up to 1e6, so
			-- a mutated common is a rarer event than its unmutated chance suggests.
			if attrs.mutation or (chance and chance >= LOG_CHANCE) or cfg.limited then
				logEvent("rolled " .. describe(item.name, attrs, cfg))
			end
		end)
	end)
	if ok and type(disconnect) == "function" then
		unhook = disconnect
	else
		print("[AnimeDice] no Inventory.OnKeyAdded -- pipeline falls back to its heartbeat")
	end
end

startPipeline()
say("ready -- nothing here moves your character")

-- close ----------------------------------------------------------------------
local function stopAll()
	setRolling(false) -- also restores the game's own AutoRoll flag
	setCash(false)
	setRebirth(false)
	setRewards(false)
	setTower(false)
	setBoosts(false)
	setGradeReroll(false)
	setTraitReroll(false)
	equipOn, upgradeOn, sellOn = false, false, false
	pipelineGen = pipelineGen + 1 -- retires the pipeline thread
	idleGen = idleGen + 1 -- and the anti-idle timer
	if idleConn then
		idleConn:Disconnect()
		idleConn = nil
	end
	if unhook then
		pcall(unhook)
		unhook = nil
	end
	if drain then
		drain:Disconnect()
		drain = nil
	end
	if towerDrain then
		towerDrain:Disconnect()
		towerDrain = nil
	end
	if boardConn then
		boardConn:Disconnect()
		boardConn = nil
	end
	for _, conn in ipairs(noteConns) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	table.clear(noteConns)
end

Window:OnDestroy(function()
	stopAll()
	getgenv().animeDiceStop = nil
end)

getgenv().animeDiceStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().animeDiceStop = nil
end
