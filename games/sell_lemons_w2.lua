--[[ Sell Lemons: World 2 -- oxygen tycoon: buy, upgrade, wake, research, evolve, invert (75881787709393)

     BUY      : every button is its own `Purchase` RemoteFunction, fired in the order the game's
                own Buy Next walks -- Balance.PurchaseOrder, which World 2 ships with its own
                oxygen names. A refusal you could still afford hops onto the button and retries;
                three hop-cured buys in a row switch to hopping first, and every 10th buy tries
                remote again to switch back. ("cannot afford" in F9 is the game's own
                touch-to-buy firing when a hop lands you on a button -- harmless.)
     FOREVER  : World 2's "Forever Purchase" card hands out free buy-it-permanently slots -- no
                Robux, just `Purchase(false, true)`. Each slot goes to your strongest earner not
                already permanent (Balance.EarnerIncomes), so after an inversion the Oxygen Forge
                is already standing.
     UPGRADE  : the upgrade that pays for itself fastest -- income gained per Φ, off the game's
                own income maths -- stacked by the UpgradeStack power, and only with cash
                above the next purchase's price.
     WAKE     : an earner without its Manager pays once and sleeps. WakeIncomeStream does what
                clicking its gauge does; the server answers a refusal with the seconds left, so
                it sets the pace.
     POWERS   : cost RESEARCHERS. A level is bought only while it costs at most half of them.
     RESETS   : Invert > Evolve > Rebirth, one pass. Invert is World 2's ascension: once every
                purchase is bought, PrepareInversion deals five cards and ConfirmInversion keeps
                two. Cards are scored off InversionCardCatalog -- cash x speed / price, weather
                cards by how often their weather actually blows -- and the best two are kept. No
                black hole, no flip, no dialog. Near the finish rebirth/evolve wait for it.
     CRYSTALS : the ice chunks are World 2's click-fruit. The server range-checks and debounces
                a click, so it's one chunk at a time, pinned over it, confirmed by its
                ClickFruitPart vanishing. Your plot first, then every other plot's (on by
                default, own toggle). Off by default: it moves you.
     EXTRAS   : accept phone offers (optional raises), claim discovered companions, clear the
                offline-cash popup, anti-AFK (on by default).

     Not here because World 2 hasn't got it: orchard, cash drops, cash vine, both minigames,
     alien events, special purchases, the reactor. World 1 is sell_lemons.lua.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().sellLemonsW2Stop() ]]

-- config ---------------------------------------------------------------------
local BOOT_WAIT = 30 -- seconds to wait for the game's own LocalTycoon to exist
local CALL_TIMEOUT = 8 -- an InvokeServer that hasn't returned by now is abandoned

local BUY_GAP = 0.05 -- between purchases; the server refuses extras for free
local BUY_IDLE = 0.5 -- ...and between passes while saving up
local BUY_TIMEOUT = 1.5 -- waiting for Purchased / a level to move before calling it a miss
local HOP_SETTLE = 0.2 -- after a hop onto a button, for the position to reach the server
local BUY_GRACE = 0.5 -- after the server answers a buy, for Purchased to replicate; raise on lag
local HOP_CURES = 3 -- refusals IN A ROW a hop cured before every buy hops first...
local HOP_PROBE = 10 -- ...and while hopping, every Nth buy tries remote again
local PARK_AFTER = 3 -- consecutive refusals before an item is stepped over...
local PARK_FOR = 60 -- ...for this many seconds, so one dud can't block the whole order

local UP_GAP = 0.1 -- between earner upgrades
local WAKE_GAP = 0.5 -- between wake sweeps; per-stream timing comes from the server
local WAKE_RECHECK = 20 -- how often to re-ask a stream the server called automatic

local POWER_GAP = 1 -- between power-level purchases
local POWER_SPEND = 0.5 -- a level may cost at most this share of your researchers; 1 = all

local RESET_GAP = 3 -- between reset checks
local RESET_TIMEOUT = 12 -- waiting for the rebirth/evolve/inversion counter to move
local RB_RATIO = 1 -- rebirth when potential researchers >= this * what you have
-- rebirth/evolve both wipe the purchases an inversion needs, so past this share bought they
-- wait -- but only while purchases keep landing: INVERT_STALL seconds without one lets them go
local INVERT_HOLD = 0.9
local INVERT_STALL = 300

-- Inversion cards, scored in log10: x10 cash is +1, x0.5 price is +0.3. Price counts the same
-- as cash because both only matter for buying; researcher power is worth less because it only
-- feeds rebirths. Raise a weight to steer the picks.
local CARD_W = { CashMultiplier = 1, SpeedMultiplier = 1, CashPriceMultiplier = -1, InvestorBoostMultiplier = 0.5 }
local CARD_FOREVER = 1 -- one permanent-earner slot, survives every reset (~x10)
local CARD_EVOLUTION = 1.5 -- +1 evolution base: World 2's EvolutionMultiplier is ~x32
local CARD_COMPANION = 0.3 -- a companion card (Singularity) -- a collectible, not income

local CLICK_LIFT = 4 -- studs above a chunk to park at
local CLICK_NEAR = 12 -- studs that count as in range; the detectors say 16
local CLICK_SETTLE = 0.3 -- pinned before the first click after a hop
local CLICK_RATE = 0.3 -- between clicks; the server debounces per player, raise if picks miss
local CLICK_GAP = 1 -- between sweeps while chunks are ready
local CLICK_IDLE = 15 -- between sweeps once every chunk is picked
local CLICK_MISSES = 3 -- unconfirmed clicks in a row on another plot before it's parked...
local CLICK_PLOT_PARK = 120 -- ...for this long

local EXTRA_GAP = 10 -- companions / offline popup
local AFK_BEAT = 60 -- synthetic click this often; the idle kick is at 20 min
local REJOIN_DELAY = 3 -- after an ErrorPrompt, before rejoining
local WATCHDOG = 25 -- seconds without the breadcrumb moving before we say where we are
local DASH_GAP = 1

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local player = Players.LocalPlayer

if getgenv and getgenv().sellLemonsW2Stop then
	getgenv().sellLemonsW2Stop() -- re-running must not stack a second panel or loop
end

local function log(msg)
	print("[oxygen] " .. msg)
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
-- Returns the packed results, or nil on timeout.
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

-- Waits for fn() to go truthy; the confirm for every remote here is the world moving.
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

-- world ----------------------------------------------------------------------
-- The game's own shared modules, required rather than copied: prices, order, the card
-- catalogue and the Huge maths all move with a balance patch.
local function shared(...)
	local ok, mod = pcall(function(...)
		local at = ReplicatedStorage
		for _, name in ipairs({ ... }) do
			at = at:WaitForChild(name, 10)
		end
		return require(at)
	end, ...)
	return ok and type(mod) == "table" and mod or nil
end

local Balance = shared("Balance")
local Config = shared("Config")
local Huge = shared("Modules", "Huge")
local LocalTycoon = shared("Modules", "Tycoon", "LocalTycoon")
local Catalog = shared("Config", "InversionCardCatalog")
local Weather = shared("Config", "Weather")
local PremiumPurchasesCls = shared("Modules", "Player", "PremiumPurchases")

local C = {}
for name, path in pairs({
	Analyzer = "TycoonAnalyzer",
	Balances = "TycoonBalances",
	Powers = "TycoonPowers",
	Purchases = "TycoonPurchases",
	Rebirth = "TycoonRebirth",
	Evolution = "TycoonEvolution",
	Ascension = "TycoonAscension",
	Inversion = "TycoonInversion",
	Offline = "TycoonOfflineIncome",
	Income = "TycoonIncome",
}) do
	C[name] = shared("Modules", "Tycoon", "Component", path)
end

if not (Balance and Config and Huge and LocalTycoon and Catalog and C.Inversion) then
	warn("[oxygen] this isn't Sell Lemons, or the client hasn't booted")
	return
end
-- IsEnabled is the game's own world check; World 1 has the same modules and no inversions
if not C.Inversion.IsEnabled() then
	warn("[oxygen] this is World 1 -- run sell_lemons.lua there")
	return
end

local tycoon
do
	local deadline = os.clock() + BOOT_WAIT
	repeat
		tycoon = LocalTycoon.get()
		if not tycoon then
			task.wait(0.2)
		end
	until tycoon or os.clock() > deadline
	if not tycoon then
		warn("[oxygen] no local Tycoon after " .. BOOT_WAIT .. "s -- rejoin, or you don't own a plot yet")
		return
	end
	pcall(function()
		tycoon:WaitForLoaded()
	end)
end

-- GetComponent maps a shared base class to the concrete client one, which is what the
-- game's own UI does.
local function comp(name)
	local ok, got = pcall(function()
		return tycoon:GetComponent(C[name])
	end)
	return ok and got or nil
end

local analyzer = comp("Analyzer")
if not analyzer then
	warn("[oxygen] no TycoonAnalyzer -- the tycoon never finished mounting")
	return
end
pcall(function()
	analyzer:WaitForLoaded()
end)
local balances = comp("Balances")
local powers = comp("Powers")
local purchased = comp("Purchases")
local rebirth = comp("Rebirth")
local evolution = comp("Evolution")
local ascension = comp("Ascension") -- still the "all purchases bought" gauge in World 2
local inversion = comp("Inversion")
local offline = comp("Offline")
local income = comp("Income")

local tyRemotes = tycoon.Remotes
local warned = {}
local function tyRF(name)
	local inst = tyRemotes and tyRemotes:FindFirstChild(name)
	if not inst and not warned[name] then
		warned[name] = true
		warn("[oxygen] no remote named " .. name .. " -- the game renamed it")
	end
	return inst
end

-- Huge is log10 all the way down: multiply is +, and plain <= compares. Every balance stays
-- in that space; converting out of it overflows.
local HZERO = Huge.zero
local function money(v)
	return v == nil and "-" or table.concat({ Huge.formatShort(v, "Φ", 2) }, " ")
end
local function plain(v)
	return v == nil and "-" or table.concat({ Huge.formatShort(v, "", 2) }, " ")
end
local function cash()
	return balances and balances:GetCash() or HZERO
end
local function researchers()
	return balances and balances:GetInvestors() or HZERO
end
local function get(obj, method, fallback)
	if not obj then
		return fallback
	end
	local ok, v = pcall(obj[method], obj)
	if ok and v ~= nil then
		return v
	end
	return fallback
end

local function char()
	local c = player.Character
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	return (hrp and c or nil), hrp
end

-- The buy fallback and the crystal sweep both move you; one claim so they can't teleport
-- each other mid-action. Returns whether it RAN; nothing yields between check and set.
local busy = false
local function claim(fn)
	if busy then
		return false
	end
	busy = true
	local ok, err = pcall(fn)
	busy = false
	if not ok then
		warn("[oxygen] claimed work failed: " .. tostring(err))
	end
	return true
end

local function hopToPos(pos)
	local c = char()
	if not (c and pos and pos.Magnitude > 1) then
		return false
	end
	return (pcall(function()
		c:PivotTo(CFrame.new(pos))
	end))
end

-- One ledger for every "the server keeps saying no" -- buys, upgrades, powers -- under a
-- prefix, so a dud steps aside for PARK_FOR instead of blocking everything behind it.
local misses, parked = {}, {}
local function isParked(key)
	local until_ = parked[key]
	if until_ and os.clock() > until_ then
		parked[key], misses[key] = nil, nil
		return false
	end
	return until_ ~= nil
end
local function strike(key)
	misses[key] = (misses[key] or 0) + 1
	if misses[key] >= PARK_AFTER then
		parked[key] = os.clock() + PARK_FOR
		log(("%s refused %d times -- stepping over it for %ds"):format(key, PARK_AFTER, PARK_FOR))
	end
end

local wakeNext, wakeAuto = {}, {}
-- A reset (ours or by hand) makes everything learned about the old tycoon wrong -- most of
-- all "this stream is automatic", which the reset just took away with its Manager.
local function forgetTycoon()
	table.clear(wakeNext)
	table.clear(wakeAuto)
	table.clear(misses)
	table.clear(parked)
end

-- purchases ------------------------------------------------------------------
local ORDER = Balance.PurchaseOrder or {}
local TOTAL = #ORDER

-- Earner names strongest first; EarnerIncomes is each one's base income.
local EARNERS = {}
for name in pairs(Balance.EarnerIncomes or {}) do
	table.insert(EARNERS, name)
end
table.sort(EARNERS, function(a, b)
	return Balance.EarnerIncomes[a] > Balance.EarnerIncomes[b]
end)

local buy = { ahead = false, forever = true, cures = 0, hopFirst = false, count = 0, idle = false, n = 0 }

local function allPurchases()
	return get(analyzer, "GetPurchases", {})
end

local function isBought(p)
	return p.Instance:GetAttribute("Purchased") == true
end

local function purchaseCount()
	return get(purchased, "GetPurchasedCount", 0)
end

local function isPermanent(name)
	local ok, bought, perm = pcall(purchased.IsPurchased, purchased, name)
	return ok and bought and perm or false
end

-- Free permanent slots: what the game's own perma-buy toggle counts (Forever Purchase
-- products + the Forever card's capacity, minus what's already permanent).
local function foreverSlots()
	local ok, n = pcall(function()
		return ascension:GetAscensionPermanentPurchasesRemaining() + inversion:GetForeverCapacity()
	end)
	return ok and n or 0
end

-- The earners the free slots are for: the strongest ones not yet permanent, one per slot. An
-- earner reached in the order while it's in this set is bought permanently.
local function foreverTargets()
	local set, slots = {}, buy.forever and foreverSlots() or 0
	for _, name in ipairs(EARNERS) do
		if slots <= 0 then
			break
		end
		if not isPermanent(name) then
			set[name], slots = true, slots - 1
		end
	end
	return set
end

-- The confirm is the button's Purchased attribute, never the return value. remoteBuy stays
-- false (true spends a Buy Next use); perm is the forever slot.
-- true = bought; false = the server ANSWERED and BUY_GRACE later it still isn't; nil = no
-- answer yet (lag). Reading a slow reply as a refusal is what used to flip hop mode on.
local function fire(p, perm)
	local rem = p.Instance:FindFirstChild("Purchase")
	if not rem then
		return nil
	end
	local answeredAt
	task.spawn(function()
		pcall(rem.InvokeServer, rem, false, perm)
		answeredAt = os.clock()
	end)
	local deadline = os.clock() + CALL_TIMEOUT
	repeat
		if isBought(p) then
			return true
		end
		if answeredAt and os.clock() - answeredAt > BUY_GRACE then
			return false
		end
		task.wait()
	until os.clock() > deadline
	return isBought(p) or nil
end

local function hopOnto(p)
	local btn = p.Instance:FindFirstChild("Button", true) or p.Instance.PrimaryPart
	if not (btn and btn:IsA("BasePart") and hopToPos(btn.Position + Vector3.new(0, 4, 0))) then
		return false
	end
	task.wait(HOP_SETTLE)
	return true
end

-- true bought, false refused (count it), nil not a verdict (lag, a cash race, or the other
-- mover held the claim) -- nil is never struck and never counts toward hop mode.
local function buyOne(p, perm, price)
	step("buy " .. p.Name)
	buy.n = buy.n + 1
	-- Hop mode isn't a life sentence: every HOP_PROBE-th buy tries from here first.
	if not buy.hopFirst or buy.n % HOP_PROBE == 0 then
		local got = fire(p, perm)
		if got then
			if buy.hopFirst then
				log("remote buys land again -- back to buying from where you stand")
			end
			buy.hopFirst, buy.cures = false, 0
			return true
		end
		-- Refused while we can no longer afford it: the upgrade loop or a payout race took
		-- the cash between our check and the server's. Not distance -- the next pass retries.
		if got == nil or not (price <= cash()) then
			return nil
		end
	end
	local got, cured
	if not claim(function()
		if isBought(p) then
			got = true -- the first call landed late; nothing to cure
			return
		end
		if hopOnto(p) then
			got = fire(p, perm)
			cured = got == true
		end
	end) then
		return nil
	end
	-- Only a refusal the hop CURED says the server range-checks, and only HOP_CURES of them
	-- in a row -- one remote success resets the count.
	if cured and not buy.hopFirst then
		buy.cures = buy.cures + 1
		if buy.cures >= HOP_CURES then
			buy.hopFirst = true
			log(("%d buys in a row only landed up close -- hopping to buttons, re-trying remote every %d"):format(HOP_CURES, HOP_PROBE))
		end
	end
	return got
end

-- The next thing to buy and its price; nil item when saving (third return = what for) or
-- when the tycoon is complete (all nil) -- which is exactly the inversion condition.
local function nextBuy()
	local map = allPurchases()
	local blocked, blockedPrice
	for _, name in ipairs(ORDER) do
		local p = map[name]
		if p and p:IsEnabled() and not isBought(p) and not isParked(name) then
			local ok, price = pcall(p.GetPrice, p)
			price = ok and price or nil
			if price and price <= cash() then
				return p, price
			end
			if not blocked then
				blocked, blockedPrice = p, price
			end
			if not buy.ahead then
				break -- in order only: save for this one
			end
		end
	end
	return nil, blockedPrice, blocked
end

-- upgrades -------------------------------------------------------------------
-- One rule: buy the upgrade that pays for itself fastest. An earner's income scales by the
-- game's own TycoonIncome.getCountMultiplier(count), so k more levels add
-- income * (M(c+k) / M(c) - 1) per second, and that over the price ranks them. "Cheapest
-- first" poured cash into weak earners; "strongest first" ignored that its next level can
-- cost 1000x a weak one's for 2x the gain. Ties to neither -- it's the payback, measured.
-- ponytail: assumes the stream's Count moves 1 per level (the multiplier's own input); if
-- the ratio can't be read, every earner falls back to cheapest-first together.
local STACK = (Config.Powers.UpgradeStack or {}).Bonuses or {}

local function stackSize()
	local ok, lvl = pcall(powers.GetSelectedLevel, powers, "UpgradeStack")
	return ok and STACK[lvl] or 1
end

-- income/s the next k levels add, or nil when unreadable
local function upgradeGain(name, k)
	local ok, gain = pcall(function()
		local m, c = C.Income.getCountMultiplier, income:GetStreamCount(name)
		local ratio = Huge.divide(m(c + k, name), m(c, name))
		return Huge.multiply(income:GetAverageStreamIncome(name), Huge.subtract(ratio, Huge.one))
	end)
	return ok and gain or nil
end

-- One upgrade per call, so a toggle-off lands between them. reserve = cash to leave alone.
local function upgradeOnce(reserve)
	local budget = cash()
	if reserve then
		if not (reserve < budget) then
			return false
		end
		budget = Huge.subtract(budget, reserve)
	end
	local stack = stackSize()
	local best, bestCount, bestScore
	for name, e in pairs(get(analyzer, "GetEarners", {})) do
		if e:IsEnabled() and not isParked("up:" .. name) then
			-- Budget-capped stack (the game's own solver): a partial stack now beats saving for
			-- a full one, and at the infinite stack it's what the reserve leaves spendable --
			-- the old full-cash stack could never fit under a reserve, so upgrades froze.
			local ok, price, count = pcall(e.GetUpgradePrice, e, nil, stack, budget)
			if ok and price and (count or 0) > 0 and price <= budget and HZERO < price then
				local gain = upgradeGain(name, count)
				local score = Huge.divide(gain or Huge.one, price)
				if not bestScore or bestScore < score then
					best, bestCount, bestScore = e, count, score
				end
			end
		end
	end
	if not best then
		return false
	end
	step("upgrade " .. best.Name)
	local level = best:GetUpgradeLevel()
	task.spawn(function()
		pcall(best.UpgradeAsync, best, bestCount)
	end)
	if waitFor(function()
		return best:GetUpgradeLevel() > level
	end, BUY_TIMEOUT) then
		misses["up:" .. best.Name] = nil
		return true, best.Name, bestCount
	end
	strike("up:" .. best.Name)
	return false
end

-- wake -----------------------------------------------------------------------
-- The reply is (paid, secondsLeft): paid -> ready again next interval; secondsLeft -> come
-- back then; neither -> the stream is automatic (Manager bought), stop asking for a while.
local wakeRemote = tyRF("WakeIncomeStream")
local wakeBusy = false -- the wake loop and a saving buy loop both sweep; never at once

local function wakeSweep()
	if not wakeRemote or wakeBusy then
		return 0
	end
	wakeBusy = true
	local ok, n = pcall(function()
		local woke, now = 0, os.clock()
		for name, e in pairs(get(analyzer, "GetEarners", {})) do
			if e:IsEnabled() and (wakeNext[name] or 0) <= now and (wakeAuto[name] or 0) <= now then
				step("wake " .. name)
				local r = callTimed(wakeRemote, 4, name)
				if r then
					if r[1] then
						woke, wakeNext[name] = woke + 1, 0
					elseif type(r[2]) == "number" then
						wakeNext[name] = now + math.max(r[2], 0.05)
					else
						wakeAuto[name] = now + WAKE_RECHECK
					end
				end
			end
		end
		return woke
	end)
	wakeBusy = false -- after the pcall, so a throw can't leave it stuck on
	return ok and n or 0
end

-- powers ---------------------------------------------------------------------
-- Config.Powers[name].Prices is a researcher ladder (not cash, not Robux). Jetpack exists
-- only here and the orchard's AutoFruit only in World 1; isAvailableInCurrentWorld knows.
local POWER_NAMES = {}
for name in pairs(Config.Powers or {}) do
	local ok, here = pcall(C.Powers.isAvailableInCurrentWorld, name)
	if not ok or here then
		table.insert(POWER_NAMES, name)
	end
end
table.sort(POWER_NAMES, function(a, b)
	return ((Config.Powers[a].Display or {}).Order or 99) < ((Config.Powers[b].Display or {}).Order or 99)
end)
local wantPowers = { Manage = true, UpgradeStack = true, BuyNext = true }

local function powerLevel(name)
	local ok, lvl = pcall(powers.GetLevel, powers, name)
	return ok and lvl or 0
end

local function powerBuyOnce()
	if not powers then
		return false
	end
	local budget = Huge.multiply(researchers(), Huge.toHuge(POWER_SPEND))
	for _, name in ipairs(POWER_NAMES) do
		if wantPowers[name] and not isParked("pw:" .. name) then
			local lvl = powerLevel(name)
			local okM, max = pcall(powers.GetMaxLevel, powers, name)
			local okP, price = pcall(powers.GetUpgradePrice, powers, name)
			if okM and max and lvl < max and okP and price and price <= budget then
				step("power " .. name)
				task.spawn(function()
					pcall(powers.UpgradeAsync, powers, name)
				end)
				if waitFor(function()
					return powerLevel(name) > lvl
				end, BUY_TIMEOUT) then
					-- a fresh level does nothing until it's selected; nil = "use the max"
					pcall(powers.SelectLevel, powers, name, nil)
					misses["pw:" .. name] = nil
					return true, name, lvl + 1
				end
				strike("pw:" .. name)
				return false
			end
		end
	end
	return false
end

-- inversion cards ------------------------------------------------------------
-- How often each weather effect is up: its presets' share of the schedule's weights.
local weatherUp = {}
do
	local total = 0
	for _, p in pairs(Weather and Weather.Presets or {}) do
		total = total + p.Weight
	end
	for _, p in pairs(Weather and Weather.Presets or {}) do
		for _, fx in ipairs(p.Effects) do
			weatherUp[fx] = (weatherUp[fx] or 0) + p.Weight / total
		end
	end
end

-- log10 worth of one card. A weather card's multiplier only applies while its weather is up,
-- so it's worth its average: 1 + uptime * (m - 1). ponytail: cards scored one at a time --
-- two weather cards on the same effect multiply, which this undercounts a little.
local function cardScore(card, up)
	if type(card) ~= "table" then
		return -math.huge
	end
	local fx, s = card.Effects or {}, 0
	for key, w in pairs(CARD_W) do
		if fx[key] then
			s = s + w * math.log10(fx[key])
		end
	end
	if fx.WeatherEffect and fx.WeatherSpeedMultiplier then
		s = s + math.log10(1 + (up[fx.WeatherEffect] or 0) * (fx.WeatherSpeedMultiplier - 1))
	end
	s = s + (fx.ForeverCapacity or 0) * CARD_FOREVER + (fx.BonusEvolution or 0) * CARD_EVOLUTION
	if card.CompanionReward then
		s = s + CARD_COMPANION
	end
	return s
end

-- Indices (1-based, into ids) of the best n cards -- the shape ConfirmInversion takes.
local function pickCards(ids, n, cards, up)
	local order = {}
	for i in ipairs(ids) do
		table.insert(order, i)
	end
	table.sort(order, function(a, b)
		return cardScore(cards[ids[a]], up) > cardScore(cards[ids[b]], up)
	end)
	return { table.unpack(order, 1, math.min(n, #order)) }
end

do -- self-check: pure cash beats a wash, a rare weather card is worth its uptime, not its peak
	local cards = {
		Wash = { Effects = { CashPriceMultiplier = 0.5, CashMultiplier = 0.5 } },
		Home = { Effects = { CashMultiplier = 33.3 } },
		Storm = { Effects = { WeatherEffect = "Rain", WeatherSpeedMultiplier = 200 } },
	}
	assert(math.abs(cardScore(cards.Wash, {})) < 1e-9)
	assert(math.abs(cardScore(cards.Storm, { Rain = 0.07 }) - math.log10(1 + 0.07 * 199)) < 1e-9)
	local got = pickCards({ "Wash", "Home", "Storm" }, 2, cards, { Rain = 0.07 })
	assert(got[1] == 2 and got[2] == 3 and #got == 2)
end

local function cardName(id)
	local card = Catalog and Catalog.Cards[id]
	return card and card.DisplayName or tostring(id)
end

-- resets ---------------------------------------------------------------------
local resets = {
	rebirth = false, evolve = false, invert = false, ratio = RB_RATIO,
	done = { rebirth = 0, evolve = 0, invert = 0 },
	lastOffer = "none yet",
	busy = false, handled = {},
}

local function inversions()
	return get(inversion, "GetInversion", 0)
end
local function invertProgress()
	return get(ascension, "GetAscensionProgress", 0)
end

local function rebirthWorth()
	local pot = get(rebirth, "GetPotentialInvestors", HZERO)
	if pot < Huge.toHuge(1) then
		return false, pot
	end
	local have = researchers()
	-- log10 space: "pot >= have * ratio"
	return have <= HZERO or Huge.multiply(have, Huge.toHuge(math.max(resets.ratio, 0.0001))) <= pot, pot
end

-- Every reset has a cash-only default and a Robux route behind an optional trailing arg
-- (FreeRebirth / FreeEvolve products). We never pass it.
local function doReset(remoteName, counter)
	local rem = tyRF(remoteName)
	if not rem then
		return false
	end
	step(remoteName)
	local before = counter()
	task.spawn(function()
		pcall(rem.InvokeServer, rem)
	end)
	if waitFor(function()
		return counter() > before
	end, RESET_TIMEOUT) then
		forgetTycoon()
		return true
	end
	return false
end

local function thirdPick()
	local ok, n = pcall(function()
		return tycoon.Owner:GetComponent(PremiumPurchasesCls):GetAvailable("InversionThirdPick")
	end)
	return ok and n and n > 0
end

-- The offer is { Id, CardIds }; confirm takes the Id and the indices kept. The confirm is
-- the Inversion counter moving. `handled` stops the pushed offer (ShowInversionOffer) and our
-- own prepare from confirming the same deal twice.
local function confirmOffer(offer)
	if type(offer) ~= "table" or type(offer.CardIds) ~= "table" or offer.Id == nil or resets.handled[offer.Id] then
		return false, "no offer"
	end
	resets.handled[offer.Id] = true
	local picks = pickCards(offer.CardIds, thirdPick() and 3 or 2, Catalog.Cards, weatherUp)
	local names, kept = {}, {}
	for _, i in ipairs(picks) do
		kept[i] = true
	end
	for i, id in ipairs(offer.CardIds) do
		table.insert(names, (kept[i] and "[%s %.2f]" or "%s %.2f"):format(cardName(id), cardScore(Catalog.Cards[id], weatherUp)))
	end
	resets.lastOffer = table.concat(names, ", ")
	log("inversion offer: " .. resets.lastOffer)
	local before = inversions()
	step("confirm inversion")
	local r = callTimed(tyRF("ConfirmInversion"), CALL_TIMEOUT, offer.Id, picks)
	if waitFor(function()
		return inversions() > before
	end, RESET_TIMEOUT) then
		forgetTycoon()
		return true
	end
	return false, r and r[2] and tostring(r[2]) or "no answer"
end

local function invert()
	if resets.busy then
		return false, "already inverting"
	end
	resets.busy = true
	local ok, got, why = pcall(function()
		step("prepare inversion")
		local r = callTimed(tyRF("PrepareInversion"), CALL_TIMEOUT)
		if not (r and type(r[1]) == "table") then
			return false, r and r[2] and tostring(r[2]) or "no offer"
		end
		return confirmOffer(r[1])
	end)
	resets.busy = false
	if not ok then
		return false, tostring(got)
	end
	return got, why
end

-- While auto invert is on, the game's own card screen is muted (archetype D): our prepare
-- may make the server push the offer, and that screen locks your controls over a deal we
-- already answered. A pushed offer we didn't ask for (one left pending from a past session)
-- gets answered here. Muted BEFORE connecting ours, restored from stopAll.
local offerMute = { conns = {}, own = nil }
function offerMute.set(on)
	for _, c in ipairs(offerMute.conns) do
		pcall(c.Enable, c)
	end
	table.clear(offerMute.conns)
	if offerMute.own then
		offerMute.own:Disconnect()
		offerMute.own = nil
	end
	local rem = tyRemotes and tyRemotes:FindFirstChild("ShowInversionOffer")
	if not (on and rem) then
		return
	end
	if type(getconnections) == "function" then
		for _, c in ipairs(getconnections(rem.OnClientEvent)) do
			if pcall(c.Disable, c) then
				table.insert(offerMute.conns, c)
			end
		end
	end
	offerMute.own = rem.OnClientEvent:Connect(function(offer)
		if resets.busy then
			return
		end
		task.spawn(function()
			resets.busy = true
			local ok, got = pcall(confirmOffer, offer)
			resets.busy = false
			if ok and got then
				resets.done.invert = resets.done.invert + 1
				say("inverted (answered a pending offer)")
			end
		end)
	end)
end

-- crystals -------------------------------------------------------------------
-- The ice chunks on your plot carry the ClickFruit tag. A picked chunk keeps the tag and loses
-- its ClickFruitPart until it regrows -- the game's own picker tests exactly that -- so it's
-- both the "worth a hop" filter and the "did my click land" confirm.
--
-- Every plot has its own mounds, owned or empty, and anyone's chunks can be clicked -- so once
-- yours are picked the sweep tours the rest. A plot that doesn't pay (misses in a row) is
-- parked, so a server that only pays owners costs one visit per plot, not a loop of them.
local clickOk = type(fireclickdetector) == "function"
local crystal = { home = nil, idle = false, picked = 0, others = true }
local plotMiss = setmetatable({}, { __mode = "k" }) -- plot -> misses in a row
local plotPark = setmetatable({}, { __mode = "k" }) -- plot -> skip until (os.clock)

local function detector(chunk)
	local part = chunk:FindFirstChild("ClickFruitPart")
	return part and part:FindFirstChildWhichIsA("ClickDetector"), part
end

-- The plot a chunk sits on: the Tycoon-tagged ancestor (a shape, not a TycoonN path).
local function plotOf(chunk)
	local at = chunk.Parent
	while at and at ~= workspace do
		if at:HasTag("Tycoon") then
			return at
		end
		at = at.Parent
	end
	return workspace
end

-- Ready chunks as two lists: yours, and everyone else's (occupied and empty plots alike).
-- Only what's streamed in shows up; a far plot joins the tour once it replicates.
local function readyChunks()
	local own, others, mine = {}, {}, tycoon.Instance
	for _, chunk in ipairs(CollectionService:GetTagged("ClickFruit")) do
		local cd, part = detector(chunk)
		if cd and part.Position.Magnitude > 1 then
			local plot = plotOf(chunk)
			if plot == mine then
				table.insert(own, chunk)
			elseif crystal.others and (plotPark[plot] or 0) <= os.clock() then
				table.insert(others, chunk)
			end
		end
	end
	return own, others
end

-- Pin, don't hop-and-sleep: a single PivotTo drifts and the range check is live the whole
-- time. nil = no character, false = the server put us back.
local function pin(target)
	local c, hrp = char()
	if not c then
		return nil
	end
	pcall(c.PivotTo, c, CFrame.new(target))
	return (hrp.Position - target).Magnitude <= CLICK_NEAR
end

local function holdAt(target, secs)
	local deadline = os.clock() + secs
	repeat
		if pin(target) == nil then
			return nil
		end
		task.wait()
	until os.clock() > deadline
	return pin(target)
end

local function crystalSweep(alive)
	local _, hrp = char()
	if not (clickOk and hrp) then
		return
	end
	crystal.home = crystal.home or hrp.Position
	local own, others = readyChunks()
	crystal.idle = #own + #others == 0
	if crystal.idle then
		say("no crystals ready" .. (crystal.others and " on any plot" or " on your plot") .. " -- waiting for them to regrow")
		return
	end
	local at, n, mine = hrp.Position, 0, 0
	-- yours first, then the rest; nearest-first within each, so a mound goes in one hop
	for _, left in ipairs({ own, others }) do
		while #left > 0 and alive() do
			local bi, bd = 1, math.huge
			for i, chunk in ipairs(left) do
				local _, part = detector(chunk)
				local d = part and (part.Position - at).Magnitude or math.huge
				if d < bd then
					bi, bd = i, d
				end
			end
			local chunk = table.remove(left, bi)
			local plot = plotOf(chunk)
			local cd, part = detector(chunk)
			if cd and (plotPark[plot] or 0) <= os.clock() then
				claim(function()
					step("crystal " .. chunk:GetFullName())
					local target = part.Position + Vector3.new(0, CLICK_LIFT, 0)
					if (target - at).Magnitude > CLICK_NEAR / 2 then
						if not holdAt(target, CLICK_SETTLE) then
							return -- put back or no character: don't remember a spot we never reached
						end
						at = target
					end
					pcall(fireclickdetector, cd, 0)
					holdAt(at, CLICK_RATE)
					if not detector(chunk) then
						n, plotMiss[plot] = n + 1, 0
						mine = mine + (left == own and 1 or 0)
					else
						plotMiss[plot] = (plotMiss[plot] or 0) + 1
						if plotMiss[plot] >= CLICK_MISSES and plot ~= tycoon.Instance then
							plotPark[plot], plotMiss[plot] = os.clock() + CLICK_PLOT_PARK, 0
							log(("%s isn't paying out -- skipping it for %ds"):format(plot.Name, CLICK_PLOT_PARK))
						end
					end
				end)
			end
		end
	end
	crystal.picked = crystal.picked + n
	say(("picked %d crystals (%d yours, %d on other plots)"):format(n, mine, n - mine))
end

-- extras ---------------------------------------------------------------------
-- Phone offer: a RemoteEvent both ways -- the server sends a number, we answer "Accept" /
-- "Raise". A raise can make the caller walk away, so raises are opt-in and per offer.
local phone = { conn = nil, raises = 0, seen = 0, taken = 0 }
function phone.set(on)
	if phone.conn then
		phone.conn:Disconnect()
		phone.conn = nil
	end
	local rem = tyRemotes and tyRemotes:FindFirstChild("PhoneOffer")
	if not (on and rem) then
		return
	end
	local raised = 0
	phone.conn = rem.OnClientEvent:Connect(function(v)
		if type(v) ~= "number" then
			raised = 0 -- offer ended
			return
		end
		phone.seen = phone.seen + 1
		if raised < phone.raises then
			raised = raised + 1
			rem:FireServer("Raise")
		else
			raised = 0
			phone.taken = phone.taken + 1
			rem:FireServer("Accept")
			say("phone offer accepted at " .. money(v))
		end
	end)
end

local function claimCompanions()
	local cfg, rem = player:FindFirstChild("Companions"), player:FindFirstChild("ClaimCompanion")
	local n = 0
	for _, entry in ipairs(cfg and rem and cfg:GetChildren() or {}) do
		local id = tonumber(entry.Name)
		if id and entry:GetAttribute("Discovered") and not entry:GetAttribute("Unlocked") then
			local r = callTimed(rem, 6, id)
			if r and r[1] then
				n = n + 1
			end
		end
	end
	return n
end

-- The offline cash is already paid server-side; this clears the popup that sits on the
-- window and holds the phone back. DoubleOfflineCash is a Robux product -- never called.
local function claimOffline()
	if get(offline, "GetUnclaimedOfflineTime", 0) > 0 then
		callTimed(tyRF("PlayerClaimed"), 6)
		return true
	end
	return false
end

-- Consumables already in the inventory only. Each has a Robux path; this never touches it --
-- GetAvailable is owned minus used.
local BOOST_REMOTE = { TimeCash = "UseTimeCash", TimedRateBoost = "UseTimedRateBoost", EarnerBoost = "UseEarnerBoost" }
local function useOwnedBoosts()
	local ok, pp = pcall(function()
		return tycoon.Owner:GetComponent(PremiumPurchasesCls)
	end)
	if not (ok and pp) then
		return 0
	end
	local used = 0
	for name, cfg in pairs(Config.Products or {}) do
		local remote = cfg.Consumed and BOOST_REMOTE[name:match("^(%a+)%d*$") or ""]
		local okA, have = pcall(pp.GetAvailable, pp, name)
		if remote and okA and (have or 0) > 0 then
			local r = callTimed(tyRF(remote), 6, name)
			used = used + (r and r[1] and 1 or 0)
		end
	end
	return used
end

-- loops ----------------------------------------------------------------------
-- A generation counter per loop, in the loop's own table (a shared one keeps only the newest
-- thread alive). Only the current generation may end itself; onExit runs when the switch drops.
local loops = {}
local function looper(name, body, gapFn, onExit)
	local L = { name = name, on = false, gen = 0, inBody = false }
	function L.set(on)
		L.on = on
		L.gen = L.gen + 1
		if not on then
			if onExit then
				task.spawn(onExit)
			end
			return
		end
		local mine = L.gen
		task.spawn(function()
			local function alive()
				return L.on and L.gen == mine
			end
			while alive() do
				L.inBody = true
				local ok, err = pcall(body, alive)
				L.inBody = false
				if not ok then
					warn(("[oxygen] %s loop: %s"):format(name, tostring(err)))
				end
				if alive() then
					task.wait(gapFn())
				end
			end
		end)
	end
	table.insert(loops, L)
	return L
end

local stats = { bought = 0, forever = 0, upgraded = 0, woke = 0, powered = 0 }
local upFirst = true -- upgrades leave the next purchase's price alone

local buyLoop = looper("buy", function()
	local have = purchaseCount()
	if have < buy.count then
		forgetTycoon() -- the count dropping is a reset, whoever did it
	end
	buy.count = have
	local p, price, blocked = nextBuy()
	buy.idle = not p
	if p then
		local perm = foreverTargets()[p.Name] == true
		local got = buyOne(p, perm, price)
		if got then
			misses[p.Name] = nil
			stats.bought = stats.bought + 1
			stats.forever = stats.forever + (perm and 1 or 0)
			say(("bought %s%s for %s"):format(p.DisplayName or p.Name, perm and " FOREVER" or "", money(price)))
		elseif got == false then
			strike(p.Name)
		end
	elseif blocked then
		-- The cash has to come from somewhere: right after a reset that's the first earner,
		-- which is manual until its Manager lands. Server-paced, so free when all run.
		stats.woke = stats.woke + wakeSweep()
		say(("saving for %s -- %s"):format(blocked.DisplayName or blocked.Name, money(price)))
	else
		say("tycoon complete -- ready to invert")
	end
end, function()
	return buy.idle and BUY_IDLE or BUY_GAP
end)

local upLoop = looper("upgrade", function()
	local reserve
	if upFirst and buyLoop.on then -- only while someone is spending the reserve
		local _, price = nextBuy()
		reserve = price
	end
	local ok, who, count = upgradeOnce(reserve)
	if ok then
		stats.upgraded = stats.upgraded + 1
		say(("upgraded %s +%d"):format(who, count or 1))
	end
end, function()
	return UP_GAP
end)

local wakeLoop = looper("wake", function()
	stats.woke = stats.woke + wakeSweep()
end, function()
	return WAKE_GAP
end)

local powerLoop = looper("power", function()
	local ok, name, lvl = powerBuyOnce()
	if ok then
		stats.powered = stats.powered + 1
		say(("power %s -> level %d"):format(name, lvl))
	end
end, function()
	return POWER_GAP
end)

local resetLoop = looper("reset", function()
	local prog = invertProgress()
	if resets.invert and prog >= 1 then
		local ok, why = invert()
		resets.done.invert = resets.done.invert + (ok and 1 or 0)
		say(ok and ("inverted -- kept " .. resets.lastOffer) or ("invert refused: " .. tostring(why)))
		return
	end
	-- Near the finish, hold rebirth/evolve for the inversion -- but the clock restarts on each
	-- new purchase, so a climb that has stalled lets them go.
	if resets.invert then
		if prog < INVERT_HOLD then
			resets.holdProg = nil
		elseif prog > (resets.holdProg or -1) then
			resets.holdProg, resets.holdAt = prog, os.clock()
		end
		local stalled = math.floor(os.clock() - (resets.holdAt or 0))
		if resets.holdProg and stalled < INVERT_STALL then
			say(("holding rebirth/evolve for inversion -- %.0f%% bought, %ds idle of %d"):format(prog * 100, stalled, INVERT_STALL))
			return
		end
	end
	if resets.evolve and get(evolution, "GetEvolutionProgress", 0) >= 1 then
		local ok = doReset("Evolve", function()
			return get(evolution, "GetTotalEvolves", 0)
		end)
		resets.done.evolve = resets.done.evolve + (ok and 1 or 0)
		say(ok and "evolved" or "evolve refused")
		return
	end
	if resets.rebirth then
		local worth, pot = rebirthWorth()
		if worth then
			local ok = doReset("Rebirth", function()
				return get(rebirth, "GetTotalRebirths", 0)
			end)
			resets.done.rebirth = resets.done.rebirth + (ok and 1 or 0)
			say(ok and ("rebirthed for " .. plain(pot) .. " researchers") or "rebirth refused")
		end
	end
end, function()
	return RESET_GAP
end)

local crystalLoop = looper("crystals", crystalSweep, function()
	return crystal.idle and CLICK_IDLE or CLICK_GAP
end, function()
	-- wait out a click in flight, then take you back to where you were standing
	while busy do
		task.wait()
	end
	if crystal.home then
		hopToPos(crystal.home)
		crystal.home = nil
	end
end)

local extraLoop = looper("extras", function()
	pcall(claimOffline)
	local ok, n = pcall(claimCompanions)
	if ok and n > 0 then
		say(("claimed %d companion%s"):format(n, n == 1 and "" or "s"))
	end
end, function()
	return EXTRA_GAP
end)

-- anti-afk -------------------------------------------------------------------
-- The nudge stops the idle kick (VirtualUser, plus VirtualInputManager for clients that
-- ignore it); the rejoin covers what a nudge can't -- every disconnect ends in an
-- ErrorPrompt. CoreGui connections teardown can't reach, so every handler checks afk.on.
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
					warn("[oxygen] disconnected -- rejoining in " .. REJOIN_DELAY .. "s")
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

-- A separate thread: a loop parked in a yield can't report that it is.
local dogGen = 0
local function startDog()
	dogGen = dogGen + 1
	local mine = dogGen
	task.spawn(function()
		while dogGen == mine do
			local working = false
			for _, l in ipairs(loops) do
				working = working or (l.on and l.inBody)
			end
			if working and os.clock() - markAt > WATCHDOG then
				warn(("[oxygen] stuck %ds at: %s"):format(math.floor(os.clock() - markAt), mark))
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
	game = "Sell Lemons: World 2", -- fallback until the live name lands
	folder = "SellLemonsW2", -- never rename: saved configs orphan
	size = UDim2.fromOffset(540, 440),
})
if not Window then
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

do
	local Main = Window:Tab({ Title = "Tycoon", Icon = "solar:home-2-bold" })

	local Build = Main:Section({ Title = "Build", Icon = "solar:hammer-bold", Box = true, BoxBorder = true, Opened = true })
	Build:Toggle({
		Title = "Auto buy",
		Desc = "Each button's own Purchase remote, in the game's Buy Next order -- no walking",
		Value = false,
		Callback = function(on)
			buyLoop.set(on)
		end,
	})
	Build:Toggle({
		Title = "Spend forever slots on top earners",
		Desc = "Free slots from the Forever Purchase card; the strongest earner not yet permanent gets each one",
		Value = buy.forever,
		Callback = function(on)
			buy.forever = on
		end,
	})
	Build:Toggle({
		Title = "Buy out of order when blocked",
		Desc = "Off: save for the next item in the game's own order, which puts income first",
		Value = buy.ahead,
		Callback = function(on)
			buy.ahead = on
		end,
	})
	Build:Toggle({
		Title = "Auto upgrade earners",
		Desc = "Always the upgrade that pays for itself fastest (income gained per Φ), stacked by Stack Upgrade",
		Value = false,
		Callback = function(on)
			upLoop.set(on)
		end,
	})
	Build:Toggle({
		Title = "Purchases first",
		Desc = "Upgrades only spend cash above the next purchase's price",
		Value = upFirst,
		Callback = function(on)
			upFirst = on
		end,
	})
	Build:Toggle({
		Title = "Auto wake income",
		Desc = "Wakes every earner without a Manager, paced by the server's own timer",
		Value = false,
		Callback = function(on)
			wakeLoop.set(on)
		end,
	})

	local Power = Main:Section({ Title = "Powers", Icon = "solar:bolt-circle-bold", Box = true, BoxBorder = true, Opened = false })
	Power:Toggle({
		Title = "Auto buy powers",
		Desc = "Paid in researchers; a level is bought only while it costs at most half of them",
		Value = false,
		Callback = function(on)
			powerLoop.set(on)
		end,
	})
	local start = {}
	for _, name in ipairs(POWER_NAMES) do
		if wantPowers[name] then
			table.insert(start, name)
		end
	end
	Power:Dropdown({
		Title = "Which powers",
		Values = POWER_NAMES,
		Multi = true,
		AllowNone = true,
		Value = start,
		Callback = function(v)
			table.clear(wantPowers)
			for name in pairs(ticked(v)) do
				wantPowers[name] = true
			end
		end,
	})

	local Reset = Main:Section({ Title = "Resets", Icon = "solar:refresh-circle-bold", Box = true, BoxBorder = true, Opened = false })
	Reset:Toggle({
		Title = "Auto invert",
		Desc = "Once every purchase is bought: deal the cards, keep the best two by the card score (see header)",
		Value = false,
		Callback = function(on)
			resets.invert = on
			offerMute.set(on)
			resetLoop.set(resets.invert or resets.evolve or resets.rebirth)
		end,
	})
	Reset:Toggle({
		Title = "Auto evolve",
		Value = false,
		Callback = function(on)
			resets.evolve = on
			resetLoop.set(resets.invert or resets.evolve or resets.rebirth)
		end,
	})
	Reset:Toggle({
		Title = "Auto rebirth",
		Value = false,
		Callback = function(on)
			resets.rebirth = on
			resetLoop.set(resets.invert or resets.evolve or resets.rebirth)
		end,
	})
	Reset:Input({
		Title = "Rebirth at x researchers",
		Desc = "Rebirth once it would pay this many times what you have (1 = double them)",
		Value = tostring(RB_RATIO),
		Placeholder = "1",
		Callback = function(v)
			local n = tonumber(v)
			if n and n > 0 then
				resets.ratio = n
			end
		end,
	})

	local Extra = Main:Section({ Title = "Extras", Icon = "solar:star-bold", Box = true, BoxBorder = true, Opened = false })
	Extra:Toggle({
		Title = "Auto pick crystals",
		Desc = clickOk and "Hops over each ice chunk, one click at a time -- yours first; puts you back after"
			or "needs fireclickdetector -- your executor hasn't got it",
		Value = false,
		Callback = function(on)
			crystalLoop.set(on and clickOk)
		end,
	})
	Extra:Toggle({
		Title = "Crystals on other plots too",
		Desc = "Every other plot's mounds, occupied or empty, after yours; a plot that doesn't pay is skipped for 2 min",
		Value = crystal.others,
		Callback = function(on)
			crystal.others = on
		end,
	})
	Extra:Toggle({
		Title = "Accept phone offers",
		Value = false,
		Callback = function(on)
			phone.set(on)
		end,
	})
	Extra:Input({
		Title = "Raises per offer",
		Desc = "Ask for more this many times first -- the caller can walk away instead",
		Value = "0",
		Placeholder = "0",
		Callback = function(v)
			phone.raises = math.max(0, math.floor(tonumber(v) or 0))
		end,
	})
	Extra:Toggle({
		Title = "Claim companions + offline popup",
		Value = false,
		Callback = function(on)
			extraLoop.set(on)
		end,
	})
	Extra:Button({
		Title = "Use owned boosts",
		Desc = "Time cash / speed boosts already in your inventory -- never buys one",
		Callback = function()
			task.spawn(function()
				say(("used %d owned boost(s)"):format(useOwnedBoosts()))
			end)
		end,
	})
	Extra:Toggle({
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
local ROWS = { "Tycoon", "Resets", "Cards", "Session" }
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
	Tycoon = function()
		local p, price, blocked = nextBuy()
		local nxt = p and (p.DisplayName or p.Name) or blocked and (blocked.DisplayName or blocked.Name)
		return table.concat({
			("cash %s   researchers %s"):format(money(cash()), plain(researchers())),
			("purchases %d/%d   next %s %s"):format(purchaseCount(), TOTAL, nxt or "-", nxt and money(price) or ""),
			("forever slots free %d%s"):format(foreverSlots(), buy.hopFirst and "   buys hop to buttons" or ""),
		}, "\n")
	end,
	Resets = function()
		local evo = get(evolution, "GetEvolutionProgress", 0)
		return table.concat({
			("rebirths %d   potential %s researchers"):format(get(rebirth, "GetTotalRebirths", 0), plain(get(rebirth, "GetPotentialInvestors", HZERO))),
			("evolution %d (%.0f%% to next)"):format(get(evolution, "GetEvolution", 0), evo * 100),
			("inversions %d (%.0f%% bought)"):format(inversions(), invertProgress() * 100),
		}, "\n")
	end,
	Cards = function()
		local owned = {}
		for id, n in pairs(get(inversion, "GetCardCounts", {})) do
			if n > 0 then
				table.insert(owned, ("%s x%d"):format(cardName(id), n))
			end
		end
		table.sort(owned)
		return ("owned: %s\nlast offer: %s"):format(#owned > 0 and table.concat(owned, ", ") or "none", resets.lastOffer)
	end,
	Session = function()
		local on = {}
		for _, l in ipairs(loops) do
			if l.on then
				table.insert(on, l.name)
			end
		end
		return table.concat({
			("bought %d (%d forever)   upgrades %d   wakes %d   powers %d"):format(stats.bought, stats.forever, stats.upgraded, stats.woke, stats.powered),
			("rebirths %d   evolves %d   inversions %d   crystals %d   phone %d/%d"):format(
				resets.done.rebirth, resets.done.evolve, resets.done.invert, crystal.picked, phone.taken, phone.seen),
			("running: %s   at: %s"):format(#on > 0 and table.concat(on, ", ") or "nothing", mark),
		}, "\n")
	end,
}

local dashGen = 0
local function startDash()
	dashGen = dashGen + 1
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
say(("ready -- %d/%d purchases, cash %s"):format(purchaseCount(), TOTAL, money(cash())))

-- close ----------------------------------------------------------------------
local function stopAll()
	for _, l in ipairs(loops) do
		l.set(false)
	end
	dogGen = dogGen + 1
	dashGen = dashGen + 1
	phone.set(false)
	offerMute.set(false) -- give the game its card screen back
	afk.set(false) -- a stopped script must not rejoin you
	pcall(drain.Disconnect, drain)
end

Window:OnDestroy(function()
	stopAll()
	getgenv().sellLemonsW2Stop = nil
end)

getgenv().sellLemonsW2Stop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().sellLemonsW2Stop = nil
end
