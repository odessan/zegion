--[[ Sell Lemons -- protocol-replay tycoon: buy, upgrade, wake, rebirth, evolve, ascend (79268393072444)

     BUY     : every button in the tycoon is its own `Purchase` RemoteFunction, and the
               game's own BuyNext power fires it from the HUD -- so the whole tycoon can
               be bought without walking. Order comes from Balance.PurchaseOrder, which
               is the dev's own progression list, and prices from Balance.PurchasePrices
               scaled by the ascension penalty. Nothing is guessed.
     FOREVER : free Forever Purchase slots (one per ascension + inversion cards) go on as
               Auto buy reaches each item -- highest income source first, then the
               multipliers, managers/minigames, decor, until the whole tycoon is permanent.
               Buying more slots is Robux and never happens here.
     UPGRADE : each earner Part has an `Upgrade` RemoteFunction; the stack size is the
               UpgradeStack power, read off the game's GetNextUpgradeInfo().
     WAKE    : an income stream without its Manager bought is MANUAL -- it pays once and
               sleeps. WakeIncomeStream does remotely what standing on the prompt does,
               and the server answers a refusal with the seconds remaining, so the loop
               paces itself off the server instead of a constant.
     RESET   : Ascend (tycoon 100%) > Evolve (investor threshold) > Rebirth. Ascend and
               Evolve are strictly better than Rebirth when they're available, so they
               go first in the same pass.
     FREE    : drops are client-built and client-redeemed -- each one's own Touched
               handler is fired with your root part every 2s, so it's collected from
               anywhere, visual and all, including drops that were already lying there
               before the toggle went on. The cash vine, the phone offers and both minigames are
               the same shape: one or two round trips, no travel, no animation.
     CLICK   : the one thing that DOES need travel, and the one that has to be SLOW.
               fireclickdetector ignores the detector's own range, but the server checks
               how close you are before it pays, and it debounces per player -- so a tree
               sprayed in one frame pays for exactly one lemon. The sweep pins you over the
               fruit (aimed at the fruit, not the model's pivot), clicks ONE lemon, and
               confirms it by the ClickFruitPart vanishing, which is the same test the
               game's own picker uses. Then the next. A picked lemon KEEPS its ClickFruit
               tag and only loses that part, so the tag list alone will send you touring
               bare trees -- the sweep filters on pickable before it travels, and when the
               whole grove is bare it backs off to a 15s beat instead of spinning. It
               shares a claim with the buy fallback and only walks you home on the way out.
     ORCHARD : harvest ready plots, replant the best fruit, eat the best spare (or the fruit picked in "Eat which fruit"), unlock
               plots with tokens, sell every fruit but the best. Runs while any of its
               toggles is on. Calls go from wherever you stand; if the server refuses and a
               hop to the plot cures it, every later call hops first. The server's refusal
               reason lands on the status row and once in F9.
     BREED   : the wiki's mutation-stacking method, automated. Hunts Perfect/Blessed on
               free basic fruit (Mysterious Fertilizer on each roll) across plots that
               don't touch each other, destroys a miss the moment its mutations are final,
               cleanses a hit down to a donor, then rings the centre plot with donors and
               re-rolls the centre, keeping a fruit only if it's a better SEED (Perfect and
               Blessed counts; its junk is next generation's conversion slots). The ring is
               all Perfect until a pure Blessed donor exists, then 2 + 2 on opposite sides.
               Upgrade the centre buys Uranium (+2 mutations a roll), Irrigation and Soil
               Enricher for the centre plot; Growth fertilizer halves its waits. On a seed
               tie the centre keeps more junk (the pool, up to 8) and up to 3 Fast.
               Out of tokens with Broke mode on, misses ripen and are sold instead of
               destroyed. Only destroys trees it planted; your own are harvested first.
               The Breeding card on the Orchard tab shows the stage, the centre vs the
               best, each donor slot, every nursery tree with its timer, breeding stock
               and the last few events.
     POLISH  : cleans your highest-income fruit down to Perfect + Blessed for free: planted
               on the centre's four diagonals (two donors each, never the centre),
               no fertilizer, a roll kept only if it eats better. Nursery and farm stay off
               its neighbours; its last copies are never destroyed.
     FARM    : Mass produce grows one fruit -- your highest-income fruit, or the one you pick -- on
               its own plots with no fertilizer, and harvests each tree every time it
               regrows, so the buff you eat is the best one you've bred. Farm plots touch
               no centre, hunt tree or each other; Auto eat eats the farmed fruit first.

     AFK     : on by default -- nudges the idle kick away, rejoins on a disconnect.

     Archetype C throughout. Every number comes off ReplicatedStorage.Balance,
     ReplicatedStorage.Config or the game's own Tycoon components -- if a balance patch
     lands, this script picks it up without an edit.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().sellLemonsStop() ]]

-- config ---------------------------------------------------------------------
local BOOT_WAIT = 30 -- seconds to wait for the game's own LocalTycoon to exist

local BUY_GAP = 0.05 -- between purchase attempts; the server refuses the extras for free
local BUY_IDLE = 0.5 -- ...and between passes while saving up; nextBuy is a 450-name scan
local BUY_TIMEOUT = 1.5 -- waiting for the button's Purchased attribute before calling it a miss
local BUY_STRIKES = 3 -- remote buys only a hop rescued before we hop to every button first
local HOP_SETTLE = 0.2 -- after a hop, for the new position to reach the server

local UP_GAP = 0.1 -- between earner upgrades
local WAKE_GAP = 0.5 -- between wake sweeps; per-stream timing comes from the server
local WAKE_RECHECK = 20 -- how often to re-ask a stream the server called automatic

local POWER_GAP = 1 -- between power-level purchases (these spend a lot of investors at once)
-- a level may cost at most this share of your investors -- the game's own buy button warns
-- "that's most of your investors" past half. Raise to 1 to spend them all.
local POWER_SPEND = 0.5
local SPECIAL_GAP = 0.5 -- between special-purchase unlocks (ascension/energy gated, no cash)

local RESET_GAP = 3 -- between reset checks; a rebirth is a full server round trip
local RESET_TIMEOUT = 12 -- waiting for the rebirth/evolve/ascend counter to move
-- with Auto ascend on, rebirth and evolve wait once this share of the ascend purchases is
-- bought -- either one wipes the purchases and restarts the climb. 1 = never hold.
local ASCEND_HOLD = 0.9
-- ...but only while that share keeps climbing: the last purchases are the priciest (and
-- x3 per ascension), so a hold with no new purchase for this long lets them go ahead
local ASCEND_STALL = 300
local RB_RATIO = 1 -- rebirth when potential investors >= this * what you already have
local RB_MIN = 1 -- ...and never below this many, which is the game's own gate

-- The server range-checks a fruit click, so a sweep is one hop per TREE and then every
-- lemon on it -- not a thousand clicks from wherever you happen to be standing. A single
-- hop-and-sleep isn't enough: the humanoid drifts off the spot and the range check is live
-- for the whole time the clicks are landing, so the position is re-pinned every frame.
local CLICK_LIFT = 4 -- studs above the fruit cluster to park at, clear of the canopy
local CLICK_NEAR = 12 -- studs that count as "at the tree"; the detectors say 16, leave slack
local CLICK_SETTLE = 0.3 -- pinned in place before the first click, for the server to see us
-- One click at a time, spaced. The server debounces per player, so a whole tree fired in
-- one frame pays for one lemon -- which is what "it teleports but nothing gets picked"
-- looks like. Raise this if picks still miss; it's the only number that matters here.
local CLICK_RATE = 0.3 -- seconds between clicks
local CLICK_MISSES = 3 -- unconfirmed clicks in a row before we give up on this tree
local CLICK_COOLDOWN = 8 -- seconds before we come back to a tree we already picked clean
local CLICK_REVERTS = 4 -- hops the server undoes before we say so rather than spin
local CLICK_STEP = 0.05 -- between trees
local CLICK_GAP = 0.5 -- between full sweeps of the trees
local CLICK_IDLE = 15 -- ...and between sweeps once the whole grove is picked clean

local DROP_KINDS = { Cash = true, Tokens = true, Investors = true, Fruit = true, Companion = true }

local EXTRA_GAP = 10 -- between sweeps of the vine / minigames / companions
local ORCH_GAP = 1 -- between orchard sweeps (growth is on a 300s base clock, this is plenty)
local ORCH_LIFT = 3 -- studs above a plot's prompt part when a call has to be made up close
local ORCH_SETTLE = 0.3 -- after that hop, before the call; raise if near calls still refuse
-- Perfect (Value4) and Blessed (Rate4): the two +7.77 mutations, one on Cash and one on
-- Speed. Eating multiplies income by Cash x Speed, so these two are the whole target.
local BREED_MIN_NEIGHBOURS = 2 -- owned plots around the centre before stacking can start
local BREED_TOKEN_FLOOR = 0 -- the breeder never spends tokens below this; raise to bank some
local BREED_KEEP = 2 -- copies of breeding stock that eat and sell never touch
-- on a seed tie the centre keeps the roll with more junk, up to this many: junk is the pool
-- donors convert, and Uranium + Mysterious add 4 a generation, so 4 was too small a pool
local BREED_SLOTS = 8
local BREED_ENOUGH = 20 -- donor copies of a target after which hunting stops chasing it
-- Tables, one of them: plain number locals are constant-folded, tables take one of Luau's
-- 200 registers, and the file is at that ceiling.
local BREED_X = {
	targets = { Value4 = true, Rate4 = true },
	fast = 3, -- Fast copies worth keeping on a tie: Fast xN grows the tree (1+N)x faster
	minGrow = 20, -- seconds; a centre growing faster than this prefers LESS Fast (Mysterious must land in time)
	quickMin = 90, -- Growth Fertilizer (100 tokens) only on a centre phase with more than this left
	reserve = 200, -- tokens an upgrade purchase leaves behind for Mysterious rolls
	-- centre plot upgrades, bought in this order: Uranium (+2 mutations every roll, 10000),
	-- Irrigation (x2 growth, 500), Soil Enricher (x2 again, 5000). All tokens, never Robux.
	upgrades = { "Radioactive", "Irrigation", "Enricher" },
	polishN = 4, -- polish plots, at most: the centre's diagonals, each touching two donors
	farmKeep = 100, -- farm fruit copies Auto sell leaves; the surplus sells for tokens
}
-- Anti-AFK: a synthetic click this often. Roblox's idle kick is at 20 min and Idled fires
-- at ~2, so anything under a few minutes is plenty; the beat only covers clients where
-- Idled doesn't fire.
local AFK_BEAT = 60
-- After an ErrorPrompt (kick, disconnect, server shutdown), wait this long before rejoining
-- so the prompt's own teardown doesn't race the teleport.
local REJOIN_DELAY = 3
local CALL_TIMEOUT = 8 -- how long we wait on an InvokeServer before abandoning the thread
local WATCHDOG = 25 -- seconds without the breadcrumb moving before we say where we are
local DASH_GAP = 1 -- dashboard refresh

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local player = Players.LocalPlayer

if getgenv and getgenv().sellLemonsStop then
	getgenv().sellLemonsStop() -- re-running must not stack a second panel or a second loop
end

local function log(msg)
	print("[lemons] " .. msg)
end

local pending -- last thing a loop thread wanted on the status row; drained on Heartbeat
local function say(msg)
	pending = msg
end

local mark, markAt = "idle", os.clock()
local function step(what)
	mark, markAt = what, os.clock()
end

-- `pcall` does NOT bound a yield. InvokeServer has no timeout of its own, so a handler
-- that throttles, errors server-side or simply never returns parks the calling thread for
-- good -- and a parked loop thread is indistinguishable from a dead one: no error, no log
-- line, toggle still lit. There's nothing to catch, so stop waiting instead: fire on
-- another thread and give up on a clock. Returns the packed results, or nil on timeout.
-- The abandoned thread is harmless; it writes to locals nobody reads any more.
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
	local until_ = os.clock() + (timeout or CALL_TIMEOUT)
	repeat
		task.wait()
	until done or os.clock() > until_
	return done and res or nil
end

-- world ----------------------------------------------------------------------
-- Everything below is the game's own shared code. Requiring it rather than
-- reimplementing is the whole point: Balance.PurchaseOrder, the price curves and the
-- Huge arithmetic are all things a balance patch changes and a copy would go stale on.
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

if not (Balance and Config and Huge and LocalTycoon) then
	warn("[lemons] this isn't Sell Lemons, or the client hasn't booted -- no Balance/Config/Tycoon")
	return
end

local C = {} -- component classes, by short name
for name, path in pairs({
	Analyzer = "TycoonAnalyzer",
	Balances = "TycoonBalances",
	Powers = "TycoonPowers",
	Purchases = "TycoonPurchases",
	Income = "TycoonIncome",
	Rebirth = "TycoonRebirth",
	Evolution = "TycoonEvolution",
	Ascension = "TycoonAscension",
	Premium = "TycoonPremiumIncome",
	Locations = "TycoonLocations",
	Inversion = "TycoonInversion",
}) do
	C[name] = shared("Modules", "Tycoon", "Component", path)
end
local OrchardCls = shared("Modules", "Tycoon", "Orchard", "Orchard")
local OrchardFruitsCls = shared("Modules", "Tycoon", "Orchard", "OrchardFruits")
local PremiumPurchasesCls = shared("Modules", "Player", "PremiumPurchases")

-- `GetComponent` maps every ancestor class to the concrete one the client registered, so
-- asking with the shared base class is what the game's own UI does.
local tycoon
do
	local until_ = os.clock() + BOOT_WAIT
	repeat
		tycoon = LocalTycoon.get()
		if not tycoon then
			task.wait(0.2)
		end
	until tycoon or os.clock() > until_
	if not tycoon then
		warn("[lemons] no local Tycoon after " .. BOOT_WAIT .. "s -- rejoin, or you don't own a plot yet")
		return
	end
	pcall(function()
		tycoon:WaitForLoaded()
	end)
end

local function comp(name)
	if not C[name] then
		return nil
	end
	local ok, got = pcall(function()
		return tycoon:GetComponent(C[name])
	end)
	return ok and got or nil
end

local analyzer = comp("Analyzer")
if not analyzer then
	warn("[lemons] no TycoonAnalyzer -- the tycoon never finished mounting")
	return
end
pcall(function()
	analyzer:WaitForLoaded()
end)

local balances = comp("Balances")
local powers = comp("Powers")
local purchased = comp("Purchases")
local income = comp("Income")
local rebirth = comp("Rebirth")
local evolution = comp("Evolution")
local ascension = comp("Ascension")
local premium = comp("Premium")
local locations = comp("Locations")

-- The two global remote folders: every Core remote is a flat child with a dotted name,
-- e.g. RemoteRequest["OrchardPlot.Harvest"], not a nested folder.
local coreRoot = ReplicatedStorage:WaitForChild("Core", 10)
local coreRequest = coreRoot and coreRoot:FindFirstChild("RemoteRequest")
local coreSignal = coreRoot and coreRoot:FindFirstChild("RemoteSignal")
local tyRemotes = tycoon.Remotes

-- Warn once per missing name, not once per call: these are polled from loops, and a
-- renamed remote should cost one console line, not a line a second.
local warned = {}
local function once(name)
	if not warned[name] then
		warned[name] = true
		warn("[lemons] no remote named " .. name .. " -- the game renamed it")
	end
end

local function coreRF(name)
	local inst = coreRequest and coreRequest:FindFirstChild(name)
	if not inst then
		once(name)
	end
	return inst
end

local function coreRE(name)
	local inst = coreSignal and coreSignal:FindFirstChild(name)
	if not inst then
		once(name)
	end
	return inst
end

local function tyRF(name)
	local inst = tyRemotes and tyRemotes:FindFirstChild(name)
	if not inst then
		once(name)
	end
	return inst
end

-- Huge is log10 all the way down: multiply is +, pow is *, and plain <= compares. Every
-- price and balance below stays in that space -- converting out of it overflows instantly.
local HZERO = Huge.zero
local function money(v)
	if v == nil then
		return "-"
	end
	return table.concat({ Huge.formatShort(v, "$", 2) }, " ")
end
local function plain(v)
	if v == nil then
		return "-"
	end
	return table.concat({ Huge.formatShort(v, "", 2) }, " ")
end

local function cash()
	return balances and balances:GetCash() or HZERO
end

local function playerValues()
	return player:FindFirstChild("Values")
end

local function pvalue(key)
	local cfg = playerValues()
	return cfg and cfg:GetAttribute(key)
end

local function serverNow()
	return workspace:GetServerTimeNow()
end

local function char()
	local c = player.Character
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	return (hrp and c or nil), hrp
end

-- Two loops drive the character: the click sweep hops tree to tree, and the buy fallback
-- stands on a button. One claim so they can't teleport each other mid-click. It returns
-- whether it RAN, not whether it succeeded, and releases on every path including a throw --
-- and nothing yields between the check and the set, or both would clear it in one frame.
-- Anything that doesn't move you (every remote in this script) must NOT take it.
local busy = false
local function claim(fn)
	if busy then
		return false
	end
	busy = true
	local ok, err = pcall(fn)
	busy = false
	if not ok then
		warn("[lemons] claimed work failed: " .. tostring(err))
	end
	return true
end

-- Location teleports in this game are client-side (the server only ever tells the client to
-- move itself), so a hop is a straight CFrame write with nothing to pay for.
local function hopToPos(pos, lift)
	local c = char()
	if not (c and pos and pos.Magnitude > 1) then
		return false
	end
	local ok = pcall(function()
		c:PivotTo(CFrame.new(pos + Vector3.new(0, lift or 0, 0)))
	end)
	return ok
end

-- purchases ------------------------------------------------------------------
-- Balance.PurchaseOrder is 450+ names in the order the game's own "Buy Next" button
-- walks them, which is the dev-tuned progression -- income sources come before the decor
-- that decorates them. Buying out of that order only ever wastes cash, so it's opt-in.
local ORDER = Balance.PurchaseOrder or {}
local TOTAL = #ORDER

local buyAhead = false -- when the head of the order is unaffordable, buy anything that is
-- Forever purchases; the methods are filled in under "forever" below, once EARNER_RANK exists.
local forever = { on = false }
local buyStrikes, buyHop = 0, false

-- A button the server keeps refusing for a reason we can't see would otherwise sit at the
-- head of the order and block every purchase behind it, silently, for the whole run. Count
-- consecutive refusals per name and step it aside for a while -- something we can never
-- buy still has to give way, even though it never told us why.
local PARK_AFTER = 3 -- consecutive refusals before a name is stepped over
local PARK_FOR = 60 -- seconds it stays stepped over
local misses, parked = {}, {}

local function isParked(name)
	local until_ = parked[name]
	if not until_ then
		return false
	end
	if os.clock() > until_ then
		parked[name], misses[name] = nil, nil
		return false
	end
	return true
end

-- One refusal against `key`; true when that one parked it. Upgrades, powers and specials
-- share the ledger under a prefix ("up:", "pw:", "sp:") -- each of them used to retry the
-- same refused item forever and starve everything behind it.
local function strike(key)
	misses[key] = (misses[key] or 0) + 1
	if misses[key] >= PARK_AFTER then
		parked[key] = os.clock() + PARK_FOR
		return true
	end
	return false
end

local function allPurchases()
	local ok, map = pcall(function()
		return analyzer:GetPurchases()
	end)
	return ok and map or {}
end

-- The button's own Purchased attribute is the server's answer -- the RemoteFunction's
-- return value is not something to trust for "did it land".
local function isBought(p)
	return p.Instance:GetAttribute("Purchased") == true
end

local function buyable(p)
	return p:IsEnabled() and not isBought(p)
end

-- Two answers that matter: true (the world changed), false (fired and it's still there).
local function fire(p, perm)
	local rem = p.Instance:FindFirstChild("Purchase")
	if not rem then
		return nil
	end
	-- (remoteBuy, permanent). remoteBuy=true spends a BuyNext use. permanent=true spends a
	-- Forever Purchase slot -- free to USE (a slot per ascension, plus inversion cards);
	-- only buying MORE slots is Robux, and that's a dev product this never touches. Only
	-- forever.wants() sets it, and only while the game's own counter says a slot is free.
	-- Fired and forgotten -- the confirm is the Purchased attribute, not the return value.
	task.spawn(function()
		pcall(function()
			rem:InvokeServer(false, perm == true)
		end)
	end)
	local until_ = os.clock() + BUY_TIMEOUT
	repeat
		if isBought(p) then
			return true
		end
		task.wait()
	until os.clock() > until_
	return false
end

-- The fallback, for the case the server range-checks a non-BuyNext purchase: stand on the
-- button. A Purchase button is a Model with a `Button` BasePart somewhere under it.
local function hopTo(inst)
	local btn = inst:FindFirstChild("Button", true) or inst.PrimaryPart
	if not (btn and btn:IsA("BasePart") and hopToPos(btn.Position, 4)) then
		return false
	end
	task.wait(HOP_SETTLE)
	return true
end

-- Three answers, not two: true (bought), false (fired and it's still there -- a refusal
-- worth counting), nil (never got to try, because the other mover held the claim). Striking
-- on nil would park a perfectly good button over a scheduling collision.
local function buy(p)
	step("buy " .. p.Name)
	local perm = forever.wants(p)
	if buyHop then
		local got
		if not claim(function()
			hopTo(p.Instance)
			got = fire(p, perm)
		end) then
			return nil
		end
		return forever.landed(p, perm, got)
	end
	local got = fire(p, perm)
	if got == false then
		claim(function()
			if hopTo(p.Instance) then
				got = fire(p, perm)
			end
		end)
		-- Only a refusal the hop CURED says the server range-checks. Counting every refusal
		-- let one unbuyable button (3 misses -> parked) flip hop mode on for the whole run.
		if got == true then
			buyStrikes = buyStrikes + 1
			if buyStrikes >= BUY_STRIKES then
				buyHop = true
				log("remote buys only land up close -- hopping to each button from here on")
			end
		end
	elseif got == true then
		buyStrikes = 0
	end
	return forever.landed(p, perm, got)
end

-- The next thing to buy, and what it costs. Returns nil when the tycoon is complete,
-- which is exactly the Ascension condition.
local function nextBuy()
	local map = allPurchases()
	local firstBlocked
	for _, name in ipairs(ORDER) do
		local p = map[name]
		if p and buyable(p) and not isParked(name) then
			local okP, price = pcall(function()
				return p:GetPrice()
			end)
			price = okP and price or nil
			if price and price <= cash() then
				return p, price
			end
			firstBlocked = firstBlocked or p
			if not buyAhead then
				return nil, price, p -- in-order only: wait for this one
			end
		end
	end
	if buyAhead and firstBlocked then
		local okP, price = pcall(function()
			return firstBlocked:GetPrice()
		end)
		return nil, okP and price or nil, firstBlocked
	end
	return nil, nil, nil
end

local function purchaseCount()
	local ok, n = pcall(function()
		return purchased:GetPurchasedCount()
	end)
	return ok and n or 0
end

-- upgrades -------------------------------------------------------------------
-- GetNextUpgradeInfo applies the UpgradeStack power for us (and, at the max level where
-- the stack is infinite, works out how many the current cash buys). Reimplementing that
-- curve would go stale; the module won't.
local UP_MODES = { "Cheapest first", "Newest earner first" }
local upMode = UP_MODES[1]

local function earners()
	local ok, map = pcall(function()
		return analyzer:GetEarners()
	end)
	return ok and map or {}
end

-- Balance.EarnerIncomes is ordered by base income, so the last one you own is the
-- strongest -- dumping everything into it beats spreading once you're past the early game.
local EARNER_RANK = {}
do
	local names = {}
	for name, base in pairs(Balance.EarnerIncomes or {}) do
		table.insert(names, { name = name, base = base })
	end
	table.sort(names, function(a, b)
		return a.base > b.base
	end)
	for i, row in ipairs(names) do
		EARNER_RANK[row.name] = i
	end
end

local function upgradeInfo(e)
	local ok, info = pcall(function()
		return e:GetNextUpgradeInfo()
	end)
	if not ok or type(info) ~= "table" or info.Max or not info.Price then
		return nil
	end
	return info
end

-- One upgrade per call so a long sweep can be interrupted between them.
local function upgradeOnce(reserve)
	local best, bestInfo, bestKey
	for name, e in pairs(earners()) do
		if e:IsEnabled() and not isParked("up:" .. name) then
			local info = upgradeInfo(e)
			if info and info.Price <= cash() then
				-- Keep the next purchase affordable: purchases unlock earners and
				-- multipliers, and an upgrade that eats the cash for one is a net loss.
				local afford = reserve == nil or Huge.add(info.Price, reserve) <= cash()
				if afford then
					local key = upMode == UP_MODES[2] and (EARNER_RANK[name] or 99) or info.Price
					if not bestKey or key < bestKey then
						best, bestInfo, bestKey = e, info, key
					end
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
		pcall(function()
			best:UpgradeAsync(bestInfo.Count)
		end)
	end)
	-- Confirm on the level moving, not on the return value.
	local until_ = os.clock() + BUY_TIMEOUT
	repeat
		if best:GetUpgradeLevel() > level then
			misses["up:" .. best.Name] = nil
			return true, best.Name, bestInfo.Count
		end
		task.wait()
	until os.clock() > until_
	strike("up:" .. best.Name)
	return false, best.Name
end

-- forever --------------------------------------------------------------------
-- A Forever Purchase survives every rebirth, evolve and ascend. The game hands you one
-- slot per ascension (TycoonAscension.GetAscensionPermanentPurchasesRemaining) plus
-- whatever the inversion cards add (TycoonInversion.GetForeverCapacity) -- the same sum
-- its HUD toggle shows, and the toggle hides at 0, so that count is the gate.
--
-- The order is the one the game's own confirm dialogs push: every earner before any
-- multiplier ("instead of an income source"), multipliers / managers / minigames before
-- decor ("gives no benefit"). Within earners, the highest base income first; within the
-- rest, the latest in PurchaseOrder first (the progression gets stronger as it goes).
--
-- A slot is only spent AS the item is bought -- permanent is a flag on the ordinary
-- Purchase call -- so if the top pick is already owned this run, the slot waits for the
-- next reset rather than going to something worse. Slots don't expire.
do
	local TIER_NAME = { "income source", "multiplier", "manager/minigame", "decor" }

	-- Sorted once, when the tycoon has loaded: tiers and base incomes don't change mid-run.
	function forever.list()
		if forever.names then
			return forever.names
		end
		local idx = {}
		for i, n in ipairs(ORDER) do
			idx[n] = i
		end
		local rows = {}
		for name, p in pairs(allPurchases()) do
			if not p.Special then
				local ok, info = pcall(function()
					return analyzer:GetPurchaseInfo(name)
				end)
				info = ok and type(info) == "table" and info or {}
				local tier = info.Earner and 1
					or info.Multiplier and 2
					or (info.Automator or p.Instance:GetAttribute("Category") == "Minigame") and 3
					or 4
				-- EARNER_RANK: 1 is the strongest; unranked earners go after the ranked ones
				local key = info.Earner and (EARNER_RANK[info.Earner.Name] or 1000 - (idx[name] or 0)) or -(idx[name] or 0)
				table.insert(rows, { name = name, tier = tier, key = key })
			end
		end
		if #rows == 0 then
			return {} -- not loaded yet: don't cache an empty list
		end
		table.sort(rows, function(a, b)
			if a.tier ~= b.tier then
				return a.tier < b.tier
			end
			return a.key < b.key
		end)
		forever.names, forever.tier = {}, {}
		for _, r in ipairs(rows) do
			table.insert(forever.names, r.name)
			forever.tier[r.name] = TIER_NAME[r.tier]
		end
		return forever.names
	end

	function forever.slots()
		local n = 0
		pcall(function()
			n = n + ascension:GetAscensionPermanentPurchasesRemaining()
		end)
		pcall(function()
			n = n + comp("Inversion"):GetForeverCapacity()
		end)
		return n
	end

	local function isPerm(name)
		local ok, _, perm = pcall(function()
			return purchased:IsPurchased(name)
		end)
		return ok and perm == true
	end

	-- The best item not yet permanent, and how many are. nil once the whole tycoon is.
	function forever.target()
		local done = 0
		for _, name in ipairs(forever.list()) do
			if isPerm(name) then
				done = done + 1
			else
				return name, done
			end
		end
		return nil, done
	end

	function forever.wants(p)
		return forever.on and not p.Special and forever.slots() > 0 and forever.target() == p.Name
	end

	-- After a buy: say whether the slot took. The Purchased attribute confirms the BUY;
	-- only IsPurchased's second return confirms it's permanent.
	function forever.landed(p, perm, got)
		if perm and got == true then
			task.wait(0.3) -- the Permanent table replicates just behind the attribute
			if isPerm(p.Name) then
				log(("forever purchase: %s (%s)"):format(p.DisplayName or p.Name, forever.tier[p.Name] or "?"))
			elseif not forever.warned then
				forever.warned = true
				warn("[lemons] bought " .. p.Name .. " but it didn't stick as a forever purchase -- the server ignored the flag")
			end
		end
		return got
	end
end

-- wake -----------------------------------------------------------------------
-- A stream with no Manager purchased is manual: it pays once and sleeps. The refusal
-- carries the seconds remaining, so the server sets the pace and there's no constant to
-- get wrong. No remaining time at all means the stream went automatic -- stop asking.
local wakeRemote = tyRF("WakeIncomeStream")
local wakeNext, wakeAuto = {}, {}
local wakeBusy = false -- the wake loop and a saving buy loop both sweep; never at once

-- A reset -- ours or one done by hand -- makes everything learned about the old tycoon
-- wrong. wakeAuto was the slow restart: a stream that HAD its Manager stayed marked
-- automatic for WAKE_RECHECK, but the reset took the Manager away, so the first earner
-- sat asleep with no cash to buy past it.
local function forgetTycoon()
	table.clear(wakeNext)
	table.clear(wakeAuto)
	table.clear(misses)
	table.clear(parked)
end

local function wakeSweep()
	if not wakeRemote or wakeBusy then
		return 0
	end
	wakeBusy = true
	-- pcall'd so a throw can't leave wakeBusy stuck on and silence both callers for good
	local ok, n = pcall(function()
		local now = os.clock()
		local woke = 0
		for name, e in pairs(earners()) do
			if e:IsEnabled() and (wakeNext[name] or 0) <= now and (wakeAuto[name] or 0) <= now then
				step("wake " .. name)
				local r = callTimed(wakeRemote, 4, name)
				if r then
					local paid, remaining = r[1], r[2]
					if paid then
						woke = woke + 1
						wakeNext[name] = 0 -- ready again the moment the interval elapses
					elseif type(remaining) == "number" then
						wakeNext[name] = now + math.max(remaining, 0.05)
					else
						wakeAuto[name] = now + WAKE_RECHECK
					end
				end
			end
		end
		return woke
	end)
	wakeBusy = false
	return ok and n or 0
end

-- powers ---------------------------------------------------------------------
-- Config.Powers[name].Prices is an INVESTORS ladder, not cash or Robux (UIManageTilePower
-- checks the price against GetInvestors) -- UpgradePowerLevel buys a level outright.
-- Manage/UpgradeStack/BuyNext pay for themselves immediately; the rest
-- are quality of life. AutoFruit and Jetpack are world-gated, which the module knows.
local POWER_NAMES = {}
for name in pairs(Config.Powers or {}) do
	table.insert(POWER_NAMES, name)
end
table.sort(POWER_NAMES, function(a, b)
	local oa = (Config.Powers[a].Display or {}).Order or 99
	local ob = (Config.Powers[b].Display or {}).Order or 99
	return oa < ob
end)

local wantPowers = { Manage = true, UpgradeStack = true, BuyNext = true, WalkSpeed = true, ClickFruitValue = true }

local function powerLevel(name)
	if not powers then
		return 0
	end
	local ok, lvl = pcall(function()
		return powers:GetLevel(name)
	end)
	return ok and lvl or 0
end

-- Some powers only exist in one world (AutoFruit here, Jetpack in World 2); the module
-- knows which, so there's no place list to keep in sync.
local function powerHere(name)
	if not (C.Powers and C.Powers.isAvailableInCurrentWorld) then
		return true
	end
	local ok, yes = pcall(C.Powers.isAvailableInCurrentWorld, name)
	return not ok or yes
end

local function powerBuyOnce()
	if not powers then
		return false
	end
	local okI, budget = pcall(function()
		return Huge.multiply(balances:GetInvestors(), Huge.toHuge(POWER_SPEND))
	end)
	if not okI then
		return false
	end
	for _, name in ipairs(POWER_NAMES) do
		if wantPowers[name] and powerHere(name) and not isParked("pw:" .. name) then
			local lvl = powerLevel(name)
			local okMax, max = pcall(function()
				return powers:GetMaxLevel(name)
			end)
			if okMax and max and lvl < max then
				local ok, price = pcall(function()
					return powers:GetUpgradePrice(name)
				end)
				-- skip what we can't afford and try the next power, instead of firing it and
				-- waiting out a refusal on the same one every pass
				local okC, afford = pcall(function()
					return price <= budget
				end)
				if ok and price and okC and afford then
					step("power " .. name)
					task.spawn(function()
						pcall(function()
							powers:UpgradeAsync(name)
						end)
					end)
					local until_ = os.clock() + BUY_TIMEOUT
					repeat
						if powerLevel(name) > lvl then
							-- Selected level is what actually applies; a fresh level is
							-- useless until it's selected, and nil means "use the max".
							pcall(function()
								powers:SelectLevel(name, nil)
							end)
							misses["pw:" .. name] = nil
							return true, name, lvl + 1
						end
						task.wait()
					until os.clock() > until_
					strike("pw:" .. name)
					return false, name
				end
			end
		end
	end
	return false
end

-- specials -------------------------------------------------------------------
-- Special purchases are gated on ascensions and reactor energy rather than cash, so the
-- Enabled attribute is the whole check -- there is nothing to save up for.
local function specialUnlockOnce()
	local mine = tycoon.Instance
	for _, inst in ipairs(CollectionService:GetTagged("Tycoon.SpecialPurchase")) do
		if
			inst:IsDescendantOf(mine)
			and inst:GetAttribute("Enabled")
			and not inst:GetAttribute("Unlocked")
			and not isParked("sp:" .. inst.Name)
		then
			local rem = inst:FindFirstChild("Unlock")
			if rem then
				step("special " .. inst.Name)
				task.spawn(function()
					pcall(function()
						rem:InvokeServer()
					end)
				end)
				local until_ = os.clock() + BUY_TIMEOUT
				repeat
					if inst:GetAttribute("Unlocked") then
						return true, inst.Name
					end
					task.wait()
				until os.clock() > until_
				strike("sp:" .. inst.Name)
				return false, inst.Name
			end
		end
	end
	return false
end

-- resets ---------------------------------------------------------------------
-- Ascend needs all 450+ purchases and multiplies income by 7.77 while tripling prices.
-- Evolve needs the investor threshold and multiplies income speed by 42. Rebirth trades
-- cash for investors. When more than one is available the later one is strictly better,
-- so they're checked in that order in a single pass.
local autoRebirth, autoEvolve, autoAscend = false, false, false
local rbRatio = RB_RATIO

local function potentialInvestors()
	if not rebirth then
		return HZERO
	end
	local ok, v = pcall(function()
		return rebirth:GetPotentialInvestors()
	end)
	return ok and v or HZERO
end

local function investors()
	return balances and balances:GetInvestors() or HZERO
end

local function rebirthWorth()
	local pot = potentialInvestors()
	if pot < Huge.toHuge(RB_MIN) then
		return false, pot
	end
	local have = investors()
	if have <= HZERO then
		return true, pot
	end
	-- log10 space: "pot >= have * ratio" is "pot >= have + log10(ratio)".
	return Huge.multiply(have, Huge.toHuge(math.max(rbRatio, 0.0001))) <= pot, pot
end

local function evolveReady()
	if not evolution then
		return false, 0
	end
	local ok, prog = pcall(function()
		return evolution:GetEvolutionProgress()
	end)
	return ok and prog >= 1, ok and prog or 0
end

local function ascendReady()
	if not ascension then
		return false, 0
	end
	local ok, prog = pcall(function()
		return ascension:GetAscensionProgress()
	end)
	return ok and prog >= 1, ok and prog or 0
end

-- All three take an optional "free" boolean that routes through a Robux product. We never
-- pass it -- nil is the cash-only path.
--
-- The confirm is the counter moving, not the return value: a reset wipes and rewrites the
-- whole profile, and what comes back down the RemoteFunction differs per reset.
local RESET_COUNTER = {
	ascend = function()
		return ascension and ascension:GetAscension() or 0
	end,
	evolve = function()
		return evolution and evolution:GetTotalEvolves() or 0
	end,
	rebirth = function()
		return rebirth and rebirth:GetTotalRebirths() or 0
	end,
}

local function doReset(which)
	local remote = tyRF(which == "ascend" and "Ascend" or which == "evolve" and "Evolve" or "Rebirth")
	if not remote then
		return false
	end
	step(which)
	local before = RESET_COUNTER[which]()
	task.spawn(function()
		pcall(function()
			remote:InvokeServer()
		end)
	end)
	local until_ = os.clock() + RESET_TIMEOUT
	repeat
		if RESET_COUNTER[which]() > before then
			forgetTycoon()
			return true
		end
		task.wait(0.1)
	until os.clock() > until_
	return false
end

-- drops ----------------------------------------------------------------------
-- Drops are CLIENT-built: DropService.New hands the client an id, the client makes the
-- visual itself in a local workspace.Drops folder, and pickup is that part's own Touched
-- handler calling DropService.Redeem(id). Redeeming the id straight off the spawn event
-- (the first version) never touched the visual, so a drop it had already cashed sat on the
-- ground for its whole 1200s lifetime looking unpicked -- and anything lying there before
-- the toggle went on had an id we never saw. So: call the game's own handler instead.
local dropConn
local dropCount = 0
local dropKinds = {} -- everything on by default; the dropdown narrows it
for kind in pairs(DROP_KINDS) do
	dropKinds[kind] = true
end

local setDrops
do
	local DROP_SWEEP = 2 -- seconds between sweeps of the Drops folder
	local KIND_OF = { CashDrop = "Cash", RiftCashDrop = "Cash", TokenDrop = "Tokens", InvestorDrop = "Investors" }
	local canTouch = type(getconnections) == "function"
	local dropGen = 0

	-- Fruit and companion drops are their own models with their own names.
	local function wanted(drop)
		local k = KIND_OF[drop.Name]
		if k then
			return dropKinds[k]
		end
		return dropKinds.Fruit or dropKinds.Companion
	end

	-- The game's handler checks GetPlayerFromCharacter(hit.Parent), then redeems, pops the
	-- visual and plays the earn effect -- exactly what walking into it does, from anywhere.
	-- It disconnects itself on the first call, so a later pass over the same drop is a no-op.
	-- DropEffect leaves CanTouch on only the one part that carries the handler.
	local function touchAll()
		local folder = workspace:FindFirstChild("Drops")
		local _, hrp = char()
		if not (folder and hrp) then
			return 0
		end
		local n = 0
		for _, drop in ipairs(folder:GetChildren()) do
			if wanted(drop) then
				local parts = {}
				for _, d in ipairs(drop:GetDescendants()) do
					if d:IsA("BasePart") and d.CanTouch then
						table.insert(parts, d)
					end
				end
				if drop:IsA("BasePart") and drop.CanTouch then
					table.insert(parts, drop)
				end
				for _, part in ipairs(parts) do
					local ok, conns = pcall(getconnections, part.Touched)
					for _, c in ipairs(ok and conns or {}) do
						if c.Function and pcall(c.Function, hrp) then
							n = n + 1
						end
					end
				end
			end
		end
		return n
	end

	function setDrops(on)
		dropGen = dropGen + 1
		if dropConn then
			dropConn:Disconnect()
			dropConn = nil
		end
		if not on then
			return
		end
		if canTouch then
			local mine = dropGen
			task.spawn(function()
				while dropGen == mine do
					local ok, n = pcall(touchAll)
					if ok and n > 0 then
						dropCount = dropCount + n
					end
					task.wait(DROP_SWEEP)
				end
			end)
			return
		end
		-- No getconnections on this executor: fall back to redeeming ids off the spawn
		-- event. It pays, but the visual stays up until it expires.
		local newSig, redeem = coreRE("DropService.New"), coreRF("DropService.Redeem")
		if not (newSig and redeem) then
			say("no DropService remotes -- auto collect off")
			return
		end
		say("no getconnections -- redeeming new drops by id; old ones and the visuals stay")
		dropConn = newSig.OnClientEvent:Connect(function(id, kind)
			if not (id and dropKinds[kind or "Cash"]) then
				return
			end
			task.spawn(function()
				local r = callTimed(redeem, 6, id)
				if r and r[1] then
					dropCount = dropCount + 1
				elseif r and r[2] then
					warn("[lemons] drop refused: " .. tostring(r[2]))
				end
			end)
		end)
	end
end

-- click fruit ----------------------------------------------------------------
-- `fireclickdetector` ignores MaxActivationDistance, so the CLICK always fires -- but the
-- server range-checks the player before it pays, which is the one thing no amount of
-- firing gets around. So the sweep travels: hop to a tree, click every lemon on it, next
-- tree. Grouping by tree is what makes that ~10 hops instead of ~300.
--
-- Two kinds of tree: the public grove under Workspace (there from the start) and the three
-- Hill trees on your own plot, which arrive as the Hill1/2/3 purchases land. Other
-- players' hills are off by default -- they're across the map -- but they're also the only
-- lemons left once you've picked your own grove clean, so there's a toggle.
local clickOk = type(fireclickdetector) == "function"
local clickForeign = false

-- The game's own picker (ClickFruitService.GetNearestFruits) treats a fruit as pickable
-- only while it still has a ClickFruitPart -- the server destroys that on a pick and puts
-- it back when the lemon regrows. So it's both the "can I click this" test and the
-- "did my click land" confirm, and it's the same one the game uses on itself.
local function pickable(fruit)
	local part = fruit:FindFirstChild("ClickFruitPart")
	return part and part:FindFirstChildWhichIsA("ClickDetector") or nil
end

-- A PICKED lemon keeps its ClickFruit tag and only loses its ClickFruitPart, so the tag
-- list will happily hand back a tree with nothing left on it -- which is a hop, a settle
-- and a hop away, over and over, for as long as the grove takes to grow back. Filtering on
-- pickable here is what stops the sweep touring empty trees. Returns the rows and how many
-- trees were in range at all, so the caller can tell "nothing ready" from "nothing there".
local function clickTrees()
	local mine = tycoon.Instance
	local rows, byTree, seen = {}, {}, {}
	local inRange = 0
	for _, fruit in ipairs(CollectionService:GetTagged("ClickFruit")) do
		local tree = fruit.Parent
		-- Scope by shape, not by path: the Tycoon tag is what the game's own code walks up
		-- to. No tagged ancestor at all means the public grove, which is everyone's.
		local foreign, at = false, tree
		while at and at ~= workspace do
			if at:HasTag("Tycoon") then
				foreign = at ~= mine
				break
			end
			at = at.Parent
		end
		if tree and (clickForeign or not foreign) then
			if not seen[tree] then
				seen[tree] = true
				inRange = inRange + 1
			end
			if pickable(fruit) then
				local row = byTree[tree]
				if not row then
					row = { tree = tree, fruits = {} }
					byTree[tree] = row
					table.insert(rows, row)
				end
				table.insert(row.fruits, fruit)
			end
		end
	end
	return rows, inRange
end

-- Every one of the public trees is called "LemonTree", so the name tells you nothing about
-- which one you're at -- the position does, and that's what makes the breadcrumb move.
local function treeLabel(tree, at)
	local where = tree.Parent and tree.Parent.Name or "?"
	return ("%s @%d,%d"):format(where, at.X, at.Z)
end

-- Aim at the middle of the fruit, not the model's pivot: a tree's pivot is wherever the
-- importer left it, and parking relative to that is how you end up standing inside or
-- under the trunk with every lemon out of range.
local function fruitCentre(row)
	local sum, n = Vector3.zero, 0
	for _, fruit in ipairs(row.fruits) do
		if fruit:IsA("BasePart") then
			sum, n = sum + fruit.Position, n + 1
		end
	end
	return n > 0 and (sum / n) or nil
end

-- Pin, don't hop-and-sleep: a single PivotTo drifts (the humanoid falls, the trunk pushes)
-- and the server's range check is live for as long as the clicks are landing.
local function pin(target)
	local c, hrp = char()
	if not (c and hrp) then
		return nil
	end
	pcall(function()
		c:PivotTo(CFrame.new(target))
	end)
	return (hrp.Position - target).Magnitude <= CLICK_NEAR
end

-- One click, then wait and check. The server debounces per player, so a tree fired in one
-- frame pays for one lemon -- and ClickFruitValue means a single click already picks the
-- nearest Amt fruits, so the spray was never the shape. Fruits the click took as
-- neighbours drop out on their own, because they stop being pickable.
--
-- Returns arrived -- true, false (the server put us back), nil (no character) -- and how
-- many lemons were confirmed gone.
local function clickTreeAt(row, target)
	local picked, missed = 0, 0
	local settle = os.clock() + CLICK_SETTLE
	repeat
		if pin(target) == nil then
			return nil, 0
		end
		task.wait()
	until os.clock() > settle
	if not pin(target) then
		return false, 0
	end

	for _, fruit in ipairs(row.fruits) do
		if missed >= CLICK_MISSES then
			break
		end
		local cd = pickable(fruit)
		if cd then
			pcall(fireclickdetector, cd, 0)
			local until_ = os.clock() + CLICK_RATE
			repeat
				if pin(target) == nil then
					return nil, picked
				end
				task.wait()
			until os.clock() > until_
			if pickable(fruit) then
				missed = missed + 1
			else
				picked, missed = picked + 1, 0
			end
		end
	end
	return true, picked
end

-- A tree we just picked clean has nothing on it for CLICK_COOLDOWN seconds. Parking it
-- covers the gap between our click landing and the server's removal reaching us, so a
-- straggler frame can't send us straight back.
local clickPark = setmetatable({}, { __mode = "k" })
local clickHome, clickReverts = nil, 0
local clickIdle = false -- nothing ready anywhere: slow the beat right down

local function clickSweep(alive)
	if not clickOk then
		return 0
	end
	local _, hrp = char()
	if not hrp then
		return 0
	end
	clickHome = clickHome or hrp.Position -- remembered once, not re-read every sweep
	local rows, inRange = clickTrees()
	-- The grove regrows on a clock measured in minutes, not the half second this loop
	-- beats at. Spinning through an empty grove is what "it keeps teleporting to a tree
	-- with no lemons" looks like from the outside -- so when nothing is ready, wait.
	if #rows == 0 then
		clickIdle = true
		say(("no lemons ready across %d trees -- waiting for them to grow back%s"):format(
			inRange,
			clickForeign and "" or " (other plots' hills are off)"
		))
		return 0
	end
	clickIdle = false
	local n, visited = 0, 0
	for _, row in ipairs(rows) do
		if not alive() then
			break
		end
		if (clickPark[row.tree] or 0) <= os.clock() then
			local centre = fruitCentre(row)
			-- Parts that haven't replicated yet report the origin, which is the "not here"
			-- sentinel rather than a place to stand.
			if centre and centre.Magnitude > 1 then
				local target = centre + Vector3.new(0, CLICK_LIFT, 0)
				-- Per tree, not per sweep: a claim held for every tree starves the buy hop.
				claim(function()
					step("click " .. treeLabel(row.tree, centre))
					local arrived, picked = clickTreeAt(row, target)
					n, visited = n + picked, visited + 1
					clickPark[row.tree] = os.clock() + CLICK_COOLDOWN
					if arrived == false then
						clickReverts = clickReverts + 1
						if clickReverts == CLICK_REVERTS then
							log("the server keeps putting us back -- the hop isn't sticking, clicks won't pay")
						end
					elseif arrived then
						clickReverts = 0
					end
				end)
				task.wait(CLICK_STEP)
			end
		end
	end
	-- Going home is clickLoop's exit hook, not this: the loop spends most of its life asleep
	-- between sweeps, never saw the toggle drop, and left you parked on the last tree.
	-- Picked, not fired: a count of clicks sent says nothing, and "0 picked at 32 trees" is
	-- the line that tells you the rate is too fast rather than the travel being broken.
	if visited > 0 then
		say(("picked %d lemons at %d of %d trees"):format(n, visited, inRange))
	end
	return n
end

-- extras ---------------------------------------------------------------------
-- The cash vine is a free periodic claim; the timer is a server timestamp on the player,
-- so it's os-clock-proof. Nothing to walk to -- Use is a plain RemoteFunction on it.
local function vineClaim()
	local vine = CollectionService:GetTagged("CashVine")[1]
	local rem = vine and vine:FindFirstChild("Use")
	if not rem then
		return nil, "no cash vine here"
	end
	local ready = (pvalue("CashVineAvailable") or 0) - serverNow()
	if ready > 0 then
		return false, ("vine in %ds"):format(math.ceil(ready))
	end
	step("cash vine")
	local r = callTimed(rem, 6)
	if r and r[1] then
		return true, "vine paid " .. money(r[1])
	end
	return false, "vine refused" .. (r and r[2] and (" (" .. tostring(r[2]) .. ")") or "")
end

-- Both minigames hand the CLIENT the outcome to report: the race takes a placement 1-4
-- and pays base * MinigameRacePlacementCash[place] (1.0 for first), the trade takes a net
-- value the UI itself caps at the MaxEarnings the server just sent. So the maximum
-- honest report is first place and MaxEarnings -- no race, no chart, no cutscene.
-- Both are unlocked by an ordinary purchase. Asking before that is bought is a refusal the
-- server answers with an on-screen banner, and one a minute stacks -- so check the button.
local function minigameBought(name)
	local p = allPurchases()[name]
	return p ~= nil and isBought(p)
end

local function playRace()
	if not minigameBought("MinigameRace") then
		return false, "Lemon Dash not built yet"
	end
	local start, finish = coreRF("MinigameRaceService.Start"), coreRF("MinigameRaceService.End")
	if not (start and finish) then
		return false, "no race remotes"
	end
	local wait_ = (pvalue("MinigameRaceAvailable") or 0) - serverNow()
	if wait_ > 0 then
		return false, ("race in %ds"):format(math.ceil(wait_))
	end
	step("race start")
	local r = callTimed(start, 8)
	if not (r and r[1]) then
		return false, "race refused" .. (r and r[2] and (" (" .. tostring(r[2]) .. ")") or "")
	end
	step("race end")
	local e = callTimed(finish, 8, 1)
	if e and e[1] and e[1] > HZERO then
		return true, "race paid " .. money(e[1])
	end
	return false, "race paid nothing"
end

local function playTrade()
	if not minigameBought("MinigameTrade") then
		return false, "Lemon Trading floor not built yet"
	end
	local start, finish = coreRF("MinigameTradeService.Start"), coreRF("MinigameTradeService.End")
	if not (start and finish) then
		return false, "no trade remotes"
	end
	local wait_ = (pvalue("MinigameTradeAvailable") or 0) - serverNow()
	if wait_ > 0 then
		return false, ("trade in %ds"):format(math.ceil(wait_))
	end
	step("trade start")
	local r = callTimed(start, 8)
	local cfg = r and r[1]
	if type(cfg) ~= "table" or cfg.MaxEarnings == nil then
		return false, "trade refused" .. (r and r[2] and (" (" .. tostring(r[2]) .. ")") or "")
	end
	step("trade end")
	local e = callTimed(finish, 8, cfg.MaxEarnings)
	if e and e[1] and e[1] > HZERO then
		return true, "trade paid " .. money(e[1])
	end
	return false, "trade paid nothing"
end

-- The phone offer is a RemoteEvent both ways: the server sends a number, we send back
-- "Accept" / "Raise" / "Reject". Raising asks for more and the server can walk away
-- instead, so raises are opt-in and counted per offer.
local phoneConn
local phoneRaises, phoneSeen, phoneTaken = 0, 0, 0

local function setPhone(on)
	if phoneConn then
		phoneConn:Disconnect()
		phoneConn = nil
	end
	if not on then
		return
	end
	local rem = tyRemotes and tyRemotes:FindFirstChild("PhoneOffer")
	if not rem then
		say("no PhoneOffer remote")
		return
	end
	local raised = 0
	phoneConn = rem.OnClientEvent:Connect(function(v)
		if type(v) ~= "number" then
			raised = 0 -- offer ended
			return
		end
		phoneSeen = phoneSeen + 1
		if raised < phoneRaises then
			raised = raised + 1
			rem:FireServer("Raise")
		else
			raised = 0
			phoneTaken = phoneTaken + 1
			rem:FireServer("Accept")
			say("phone offer accepted at " .. money(v))
		end
	end)
end

-- Consumables already in the inventory only -- every one of these has a DevProductID and
-- a Robux path, and nothing here ever touches it. GetAvailable is count minus uses.
local function useOwnedBoosts()
	if not (premium and PremiumPurchasesCls) then
		return 0
	end
	local pp
	pcall(function()
		pp = tycoon.Owner:GetComponent(PremiumPurchasesCls)
	end)
	if not pp then
		return 0
	end
	local used = 0
	for name, cfg in pairs(Config.Products or {}) do
		if cfg.Consumed and (pp:GetAvailable(name) or 0) > 0 then
			local remote = name:match("^TimeCash") and "UseTimeCash"
				or name:match("^TimedRateBoost") and "UseTimedRateBoost"
				or name:match("^EarnerBoost") and "UseEarnerBoost"
			if remote then
				step("use " .. name)
				local r = callTimed(tyRemotes and tyRemotes:FindFirstChild(remote), 6, name)
				if r and r[1] then
					used = used + 1
				end
			end
		end
	end
	return used
end

local function claimCompanions()
	local cfg = player:FindFirstChild("Companions")
	local rem = player:FindFirstChild("ClaimCompanion")
	if not (cfg and rem) then
		return 0
	end
	local n = 0
	for _, entry in ipairs(cfg:GetChildren()) do
		local id = tonumber(entry.Name)
		if id and entry:GetAttribute("Discovered") and not entry:GetAttribute("Unlocked") then
			if callTimed(rem, 6, id) then
				n = n + 1
			end
		end
	end
	return n
end

local function claimOffline()
	local rem = tyRemotes and tyRemotes:FindFirstChild("PlayerClaimed")
	if not rem then
		return false
	end
	-- The cash is already granted server-side; this only clears the popup so it stops
	-- reserving the window and blocking the phone.
	return callTimed(rem, 6) ~= nil
end

-- orchard --------------------------------------------------------------------
-- Plots are tagged, and their whole state is attributes: State 0 empty / 1 tree growing /
-- 2 fruit growing / 3 ready, plus Available for one that can still be bought with tokens.
local PLOT_READY, PLOT_EMPTY = 3, 0

local function orchard()
	if not OrchardCls then
		return nil
	end
	local ok, o = pcall(function()
		return OrchardCls.getFromTycoon(tycoon)
	end)
	return ok and o or nil
end

local function myPlots()
	local mine = tycoon.Instance
	local out = {}
	for _, inst in ipairs(CollectionService:GetTagged("Tycoon.OrchardPlot")) do
		if inst:IsDescendantOf(mine) then
			table.insert(out, inst)
		end
	end
	return out
end

-- The fruit inventory is a RemoteTable of {Fruit=, Count=}. Ranked by GetCashFactor (Cash x
-- Speed, what eating pays), NOT GetPowerRating -- the billboard's stars count Fast and token
-- value, so a Perfect x30 + Fast x4 (x234) outrated a Perfect x264 + Blessed x55 (x377k),
-- and eat, sell and replant all acted on the worse fruit.
local function bestFruit(minCount)
	local o = orchard()
	if not (o and OrchardFruitsCls) then
		return nil
	end
	local ok, all = pcall(function()
		return o:GetComponent(OrchardFruitsCls):GetAll()
	end)
	if not ok or type(all) ~= "table" then
		return nil
	end
	local best, bestScore
	for _, row in ipairs(all) do
		if row.Fruit and (row.Count or 0) >= (minCount or 1) then
			local okR, score = pcall(function()
				return row.Fruit:GetCashFactor()
			end)
			score = okR and score or 0
			if not bestScore or score > bestScore then
				best, bestScore = row.Fruit, score
			end
		end
	end
	return best, bestScore
end

local EffectApplierCls = shared("Modules", "Tycoon", "Orchard", "OrchardFruitEffectApplier")
local Serialization = shared("Core", "SerializationService")
local orchHarvest, orchPlant, orchEat, orchPlots, orchSell = false, false, false, false, false
-- Orchard panel state, one table because the file is at Luau's 200-locals ceiling:
-- pick = "Eat which fruit" label (nil = best available), key = fruit -> label,
-- conn = the dropdown's Heartbeat watcher, sellBroke = Broke mode
-- farm = Mass produce on, farmPick = its dropdown label (nil = best seed), farmN = plots
-- to farm, farmT = the fruit it resolved to, farmPlots/farmBlock = plots it holds / their
-- neighbours too (the generic planter stays off those)
-- upgrade = buy Uranium/Irrigation/Enricher for the centre, quick = Growth Fertilizer on it
local orchUI = { sellBroke = false, farm = false, farmN = 3, farmPlots = {}, farmBlock = {}, upgrade = false, quick = false, polish = false, polishCleanse = false }

-- Every orchard remote answers (result, reason) -- the game's own billboard shows the
-- reason as "Failed to harvest tree (<reason>)". We try from wherever we stand first; if
-- the server refuses and a hop to the plot's prompt cures it, the server range-checks
-- (the prompt's MaxActivationDistance is 9) and every later call hops first. A reason a
-- hop did NOT cure (no tokens, already owned) never costs a hop again.
local orchNear = false
local orchNoHop, orchSeen = {}, {}

local function orchCall(rf, plot, ...)
	local args = table.pack(...)
	local function try()
		local r = callTimed(rf, 6, table.unpack(args, 1, args.n))
		return r and r[1], r and r[2]
	end
	local pp = plot and plot:FindFirstChild("PromptPart")
	local function near()
		local ok, why
		claim(function()
			if hopToPos(pp.Position, ORCH_LIFT) then
				task.wait(ORCH_SETTLE)
				ok, why = try()
			end
		end)
		return ok, why
	end

	local ok, why
	if orchNear and pp then
		ok, why = near()
	else
		ok, why = try()
		if not ok and why and pp and not orchNoHop[tostring(why)] then
			local first = tostring(why)
			ok, why = near()
			if ok then
				orchNear = true
				log("orchard calls are range-checked -- hopping to each plot from now on")
			elseif why and tostring(why) == first then
				orchNoHop[first] = true
			end
		end
	end
	if not ok and why then
		why = tostring(why)
		if not orchSeen[why] then
			orchSeen[why] = true
			warn("[lemons] orchard refused: " .. why)
		end
		say("orchard: " .. why)
	end
	return ok
end

-- breed ----------------------------------------------------------------------
-- The wiki's hunt -> purify -> cross-stack method, driven off the game's own shared
-- OrchardFruit.GetMutated. The rules that matter, read from that function:
--   * each neighbouring tree's fruit (the + pattern, GridPosition +-1) gets a 70% chance,
--     repeated, to SWAP one of the new tree's mutations for one of its own. Crossing
--     converts, it never adds; the count only grows via Mysterious Fertilizer (+2).
--   * positive mutations stack per copy: Perfect x3 is 1 + 3 * 7.77 cash.
--   * basic fruit plants for free (the game's own menu lists it with an infinite count),
--     so a failed roll costs 300s of tree growth and nothing else.
-- So: hunt target mutations on free basic fruit, cleanse a hit down to targets-only (a
-- "donor"), plant donors round a centre plot and keep re-rolling the centre -- Mysterious
-- adds two slots each generation and the donors convert them.
-- Its own function, not a do-block: Luau allows 200 live locals per FUNCTION, and a
-- do-block's locals count against the main chunk's. As a function the breeder gets a
-- fresh 200 of its own; only what the rest of the file touches lives out here.
local orchBreed, breedBest = false, nil
-- Breed OR Polish on: either way the breeder holds the field (Polish alone runs it lite --
-- the donor ring stands, no hunting, no centre rolls) and breeding stock is protected.
orchUI.owns = function()
	return orchBreed or orchUI.polish
end
local mutsTargets, fruitMuts, fruitScore, fruitSame, stock, breedProtects, breedSweep, breedInfo, fruitLabel
;(function()
	local OrchardFruitCls = shared("Modules", "Tycoon", "Orchard", "OrchardFruit")
	local OrchardItemsCls = shared("Modules", "Tycoon", "Orchard", "OrchardItems")
	local ITEMS = Config.Orchard and Config.Orchard.Items or {}
	local PLOT_FINAL = 2 -- from FruitGrowing on, a tree's mutations can't change

	-- Pure helpers over a raw {mutationKey = count} table.
	function mutsTargets(m)
		local n = 0
		for k, c in pairs(m) do
			if BREED_X.targets[k] then
				n = n + c
			end
		end
		return n
	end
	local function mutsJunk(m)
		local n = 0
		for k, c in pairs(m) do
			if not BREED_X.targets[k] then
				n = n + c
			end
		end
		return n
	end
	local function mutsIsDonor(m)
		return mutsTargets(m) > 0 and mutsJunk(m) == 0
	end
	assert(mutsIsDonor({ Value4 = 1 }) and mutsIsDonor({ Value4 = 2, Rate4 = 1 }))
	assert(not mutsIsDonor({}) and not mutsIsDonor({ Value4 = 1, Value1 = 1 }))
	assert(mutsTargets({ Rate4 = 2, ValueBad1 = 1 }) == 2 and mutsJunk({ Rate4 = 2, ValueBad1 = 1 }) == 1)

	-- SEED value: the income the targets alone would give, junk ignored. A centre fruit
	-- always comes out carrying two fresh fertilizer mutations (GetMutated crosses first,
	-- THEN adds them), and the donors convert those next generation -- so judging seeds by
	-- real income throws away "Perfect x4, Lazy, Draining" for a clean Perfect x2. Real
	-- income (fruitScore) is still what Auto eat picks by.
	local MUTS = Config.Orchard and Config.Orchard.Mutations or {}
	local function seedValue(m, cfg)
		cfg = cfg or MUTS
		local sum = {}
		for k, c in pairs(m) do
			local info = BREED_X.targets[k] and cfg[k]
			if info then
				sum[info.Effect] = (sum[info.Effect] or 0) + info.EffectValue * c
			end
		end
		local v = 1
		for _, s in pairs(sum) do
			v = v * (1 + s)
		end
		return v
	end
	do
		local cfg = { Value4 = { Effect = "Value", EffectValue = 7.77 }, Rate4 = { Effect = "Rate", EffectValue = 7.77 } }
		assert(seedValue({}, cfg) == 1)
		assert(math.abs(seedValue({ Value4 = 4, ValueBad2 = 1 }, cfg) - 32.08) < 1e-6)
		assert(seedValue({ Value4 = 1, Rate4 = 1 }, cfg) > seedValue({ Value4 = 2 }, cfg)) -- balance wins
	end

	-- Which targets a pure donor carries, as a set: {Value4 = true}, {Rate4 = true} or both.
	local TARGET_LIST = {}
	for k in pairs(BREED_X.targets) do
		table.insert(TARGET_LIST, k)
	end
	table.sort(TARGET_LIST)

	function fruitMuts(f)
		local ok, m = pcall(function()
			return f:GetMutations()
		end)
		return ok and type(m) == "table" and m or {}
	end
	function fruitScore(f)
		local ok, s = pcall(function()
			return f:GetCashFactor()
		end)
		return ok and tonumber(s) or 0
	end
	local function fruitSeed(f)
		return f and seedValue(fruitMuts(f)) or 1
	end
	-- Better seed first; on a tie, the one that also eats better.
	local function seedBeats(a, b)
		local sa, sb = fruitSeed(a), fruitSeed(b)
		if math.abs(sa - sb) > 1e-6 then
			return sa > sb
		end
		return fruitScore(a) > fruitScore(b) + 1e-6
	end
	function fruitSame(a, b)
		if a == b then
			return true
		end
		if not (a and b) then
			return false
		end
		local ok, eq = pcall(function()
			return a:IsEqual(b)
		end)
		return ok and eq == true
	end
	function fruitLabel(f)
		local ok, rows = pcall(function()
			return f:GetMutationsPriority()
		end)
		local parts = {}
		for _, r in ipairs(ok and rows or {}) do
			table.insert(parts, r.Count > 1 and (r.DisplayName .. " x" .. r.Count) or r.DisplayName)
		end
		return #parts > 0 and table.concat(parts, ", ") or "basic"
	end

	-- Perfect / Blessed / Fast / everything else, as copy counts.
	function BREED_X.split(m)
		local o = 0
		for k, c in pairs(m) do
			if k ~= "Value4" and k ~= "Rate4" and k ~= "GrowthRate1" then
				o = o + c
			end
		end
		return m.Value4 or 0, m.Rate4 or 0, m.GrowthRate1 or 0, o
	end
	assert(select(4, BREED_X.split({ Value4 = 2, Rate4 = 1, GrowthRate1 = 3, ValueBad1 = 2, Luck1 = 1 })) == 3)
	-- A plot's growth multiplier from its upgrades (Irrigation x2, Enricher x2).
	function BREED_X.speed(plot)
		local v = 1
		for name, u in pairs(Config.Orchard and Config.Orchard.PlotUpgrades or {}) do
			if u.Effect == "GrowthRate" and plot and plot:GetAttribute(name .. "Unlocked") == true then
				v = v * (u.EffectValue or 1)
			end
		end
		return v
	end
	-- Seconds for this fruit's tree to grow on that plot: Fast is on the fruit, the rest on the soil.
	function BREED_X.grow(f, plot)
		local ok, t = pcall(function()
			return f:GetTreeGrowTime()
		end)
		return (ok and tonumber(t) or 300) / BREED_X.speed(plot)
	end

	function stock()
		local o = orchard()
		local ok, all = pcall(function()
			return o:GetComponent(OrchardFruitsCls):GetAll()
		end)
		return ok and type(all) == "table" and all or {}
	end
	local function stockCount(f)
		for _, row in ipairs(stock()) do
			if fruitSame(row.Fruit, f) then
				return row.Count or 0
			end
		end
		return 0
	end
	local function plotFruit(plot)
		local o = orchard()
		local ok, f = pcall(function()
			return o:GetComponent(OrchardFruitsCls):GetPlotFruit(plot:GetAttribute("ID"))
		end)
		return ok and f or nil
	end
	local function tokens()
		local ok, t = pcall(function()
			return balances:GetTokens()
		end)
		return ok and tonumber(t) or 0
	end
	local function itemCount(name)
		local o = orchard()
		local ok, n = pcall(function()
			return o:GetComponent(OrchardItemsCls):GetCount(name)
		end)
		return ok and tonumber(n) or 0
	end
	local function canAfford(name)
		local info = ITEMS[name]
		return itemCount(name) > 0 or (info and tokens() >= info.Price + BREED_TOKEN_FLOOR)
	end
	-- The highest evolution you've reached gives the basic fruit with the most Pure, and Pure
	-- is +25% mutation luck per stack -- so the free roll is always the top one.
	local function basicFruit()
		local okE, evo = pcall(function()
			return evolution:GetEvolution()
		end)
		local ok, list = pcall(function()
			return OrchardFruitCls.getBasicFruits(okE and evo or 0)
		end)
		return ok and list and list[#list] or nil
	end

	-- A fruit the breeder must not eat or sell: anything carrying a target, down to BREED_KEEP.
	function breedProtects(f, count)
		-- the farm keeps its last copy; if it's farming the best seed, the breeder's keep
		-- below still applies -- returning here let eat take the best down to 1
		if orchUI.farm and orchUI.farmT and fruitSame(f, orchUI.farmT) and (count <= 1 or orchUI.farmHungry) then
			return true -- and while a farm plot is empty, every copy goes to planting first
		end
		if not orchUI.owns() then
			return false
		end
		if fruitSame(f, breedBest) or mutsTargets(fruitMuts(f)) > 0 then
			return count <= BREED_KEEP
		end
		return false
	end

	-- Per-plot memory, keyed by the plot Instance and cleared whenever it reads empty: whether
	-- WE planted its tree (only those are ever destroyed), what went in, and the verdict.
	-- Kept in getgenv so a re-paste still knows which trees are ours: otherwise every miss
	-- planted before it ripens its whole timer instead of being cut. Keys are plot Instances,
	-- which outlive the script; the sweep clears a plot's entries whenever it reads empty.
	local mem = getgenv().sellLemonsBreedMem or { {}, {}, {}, {} }
	getgenv().sellLemonsBreedMem = mem
	local breedMine, breedParent, breedKeep, breedJudged = mem[1], mem[2], mem[3], mem[4]
	local breedCentre
	local breedRolls, breedStage = 0, "hunt"
	local breedSaid = {}
	-- Tracking for the Breeding panel only: session counters, the last sweep's layout, and
	-- the recent events (newest first). Nothing in here steers the breeder.
	local bs = { started = nil, hits = 0, donors = 0, gens = 0, wins = 0, used = {}, events = {}, last = nil, farmCuts = 0 }
	local function note(msg)
		log("breed: " .. msg)
		table.insert(bs.events, 1, { os.clock(), msg })
		bs.events[9] = nil
	end
	-- for the dashboard and the sweep: stage, rolls, the labeller, the seed scorer, and
	-- whether the breeder is broke (then the sweep sells spare fruit whatever Auto sell says)
	local broke
	function breedInfo()
		return breedStage, breedRolls, fruitLabel, fruitSeed, orchUI.sellBroke and broke ~= nil and broke() or false
	end
	local function breedOnce(key, msg)
		if not breedSaid[key] then
			breedSaid[key] = true
			log("breed: " .. msg)
		end
	end

	local function gridKey(gp)
		local t = typeof(gp)
		if t ~= "Vector2" and t ~= "Vector2int16" and t ~= "Vector3" then
			return nil
		end
		return tostring(gp.X) .. "," .. tostring(gp.Y)
	end
	local function breedGrid(plots)
		local g = {}
		for _, p in ipairs(plots) do
			if p:GetAttribute("Enabled") == true then
				local k = gridKey(p:GetAttribute("GridPosition"))
				if k then
					g[k] = p
				end
			end
		end
		return g
	end
	local function neighbours(plot, g)
		local gp = plot:GetAttribute("GridPosition")
		local out = {}
		if not gp then
			return out
		end
		for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
			local n = g[gridKey(Vector2.new(gp.X + d[1], gp.Y + d[2]))]
			if n then
				table.insert(out, n)
			end
		end
		return out
	end

	local function byId(a, b)
		return (a:GetAttribute("ID") or 0) < (b:GetAttribute("ID") or 0)
	end

	-- Farm plots: up to orchUI.farmN owned plots that touch nothing that could hand a farm
	-- tree junk -- not the centre, not each other, and (the breeder assigns nursery after
	-- this, around them) not a hunt tree. Touching a pure donor is the best spot: all it can
	-- cross in is a target. Sticky, so a standing farm tree isn't moved by a plot purchase.
	local farmChoose
	do
	local farmSet = {}
	function farmChoose(g, role, centre)
		local donorN, cands = {}, {}
		for _, p in pairs(g) do
			if not (role and role[p]) and p ~= centre then
				local c = 0
				for _, n in ipairs(neighbours(p, g)) do
					c = c + ((role and role[n] == "donor") and 1 or 0)
				end
				donorN[p] = c
				table.insert(cands, p)
			end
		end
		table.sort(cands, function(a, b)
			if (farmSet[a] == true) ~= (farmSet[b] == true) then
				return farmSet[a] == true
			end
			if donorN[a] ~= donorN[b] then
				return donorN[a] > donorN[b]
			end
			return byId(a, b)
		end)
		local chosen, n = {}, 0
		for _, p in ipairs(cands) do
			if n >= (bs.farmAll and math.huge or orchUI.farmN) then
				break
			end
			local clear = true
			for _, nb in ipairs(neighbours(p, g)) do
				if nb == centre or chosen[nb] or (role and role[nb] == "polish") then
					clear = false
				end
			end
			if clear then
				chosen[p], n = true, n + 1
			end
		end
		table.clear(farmSet)
		for p in pairs(chosen) do
			farmSet[p] = true
		end
		return chosen
	end
	end

	-- Centre: the owned plot with the most owned neighbours, picked once per run so the cross
	-- doesn't wander as you buy plots. Donors are its neighbours, which are never adjacent to
	-- each other -- so while hunting they double as nursery plots and the centre stays empty.
	local function breedRoles(plots, g)
		if breedCentre and breedCentre:GetAttribute("Enabled") ~= true then
			breedCentre = nil
		end
		if not breedCentre then
			local best, bestN = nil, BREED_MIN_NEIGHBOURS - 1
			local owned = {}
			for _, p in pairs(g) do
				table.insert(owned, p)
			end
			table.sort(owned, byId)
			-- most neighbours first; among equals, the plot already carrying centre upgrades
			-- (Uranium on a donor plot would junk the donors)
			local bestU = -1
			for _, p in ipairs(owned) do
				local n, u = #neighbours(p, g), 0
				for _, name in ipairs(BREED_X.upgrades) do
					u = u + (p:GetAttribute(name .. "Unlocked") == true and 1 or 0)
				end
				if n > bestN or (n == bestN and n >= BREED_MIN_NEIGHBOURS and u > bestU) then
					best, bestN, bestU = p, n, u
				end
			end
			breedCentre = best
			if best then
				note(("centre is %s with %d donor plots around it"):format(best.Name, bestN))
			end
		end
		local role = {}
		local donors = breedCentre and neighbours(breedCentre, g) or {}
		if breedCentre then
			role[breedCentre] = "centre"
		end
		for _, d in ipairs(donors) do
			role[d] = "donor"
		end
		-- Polish: every free plot touching two donors -- the centre's four diagonals. They
		-- don't touch the centre or each other, so four roll the same fruit in parallel.
		-- Assigned before the farm so neither lands next to one.
		bs.polishPlots = {}
		if orchUI.polish and breedCentre then
			local owned = {}
			for _, p in pairs(g) do
				table.insert(owned, p)
			end
			table.sort(owned, byId)
			for _, p in ipairs(owned) do
				if not role[p] and #bs.polishPlots < BREED_X.polishN then
					local d, clash = 0, false
					for _, n in ipairs(neighbours(p, g)) do
						d = d + (role[n] == "donor" and 1 or 0)
						clash = clash or role[n] == "polish"
					end
					if d >= 2 and not clash then
						role[p] = "polish"
						table.insert(bs.polishPlots, p)
					end
				end
			end
		end
		if orchUI.farm then
			for p in pairs(farmChoose(g, role, breedCentre)) do
				role[p] = "farm"
			end
		end
		-- Nursery: greedy independent set over the rest, so no two hunt trees cross each other.
		-- A nursery tree next to a donor is fine -- it can only pick up target mutations.
		local rest = {}
		for _, p in pairs(g) do
			if not role[p] then
				table.insert(rest, p)
			end
		end
		table.sort(rest, byId)
		local taken = {}
		for p, r in pairs(role) do
			taken[p] = r == "donor" or r == "farm" or r == "polish" or nil
		end
		for _, p in ipairs(rest) do
			local clash = false
			for _, n in ipairs(neighbours(p, g)) do
				if (taken[n] and role[n] ~= "donor") or n == breedCentre then
					clash = true
				end
			end
			if not clash then
				role[p] = "nursery"
				taken[p] = true
			else
				role[p] = "idle"
			end
		end
		return role, donors
	end

	local function breedPlant(plot, fruit, rf)
		step("breed " .. plot.Name .. " / plant")
		if orchCall(rf.plant, plot, plot, { fruit:Serialize() }) then
			breedMine[plot], breedParent[plot] = true, fruit
			return true
		end
		return false
	end

	local function breedDestroy(plot, rf)
		step("breed " .. plot.Name .. " / destroy")
		return orchCall(rf.destroy, plot, plot)
	end

	-- Mutation fertilizer goes on a TreeGrowing plot; PendingMutationItem is how the game
	-- itself shows one is already queued, so it's also our "don't apply twice".
	local function breedApply(plot, name, rf)
		if plot:GetAttribute("PendingMutationItem") or not canAfford(name) then
			return false
		end
		if itemCount(name) < 1 then
			step("breed buy " .. name)
			-- (item, count, premium): premium = true is the Robux route. Never pass it.
			if not orchCall(rf.buy, nil, name, 1, nil) then
				return false
			end
		end
		step("breed " .. plot.Name .. " / " .. name)
		if orchCall(rf.use, plot, plot, name) then
			bs.used[name] = (bs.used[name] or 0) + 1
			return true
		end
		return false
	end

	-- Buy-if-needed and use an item that isn't a mutation fertilizer, with a 30s back-off
	-- after a refusal so a "not now" doesn't become a call every sweep.
	bs.no = {}
	function BREED_X.use(plot, name, rf, reserve)
		local info = ITEMS[name]
		if not info or (bs.no[name] or 0) > os.clock() then
			return false
		end
		if itemCount(name) < 1 then
			if tokens() < info.Price + BREED_TOKEN_FLOOR + (reserve or 0) then
				return false
			end
			step("breed buy " .. name)
			-- (item, count, premium): premium = true is the Robux route. Never pass it.
			if not orchCall(rf.buy, nil, name, 1, nil) then
				bs.no[name] = os.clock() + 30
				return false
			end
		end
		step("breed " .. plot.Name .. " / " .. name)
		local ok, why = orchCall(rf.use, plot, plot, name)
		if ok then
			bs.used[name] = (bs.used[name] or 0) + 1
			return true
		end
		bs.no[name] = os.clock() + 30
		breedOnce("use" .. name, ("%s refused on %s: %s"):format(info.DisplayName or name, plot.Name, tostring(why)))
		return false
	end

	-- Centre upgrades, one at a time in BREED_X.upgrades order: Uranium first because it
	-- doubles the only thing that adds mutations (+2 on top of Mysterious' +2 every roll).
	function BREED_X.upgrade(plot, rf)
		for _, name in ipairs(BREED_X.upgrades) do
			if plot:GetAttribute(name .. "Unlocked") ~= true then
				if BREED_X.use(plot, name, rf, BREED_X.reserve) then
					note(("bought %s for the centre %s"):format(ITEMS[name].DisplayName or name, plot.Name))
					return true
				end
				return false -- in order: don't buy Irrigation with the Uranium money
			end
		end
		return false
	end

	-- Growth Fertilizer halves what's left of the current phase, so it goes on while the
	-- phase still has more than BREED_X.quickMin seconds to run.
	function BREED_X.quick(plot, rf)
		local t = plot:GetAttribute("NextTime")
		if not (orchUI.quick and type(t) == "number" and t - workspace:GetServerTimeNow() > BREED_X.quickMin) then
			return false
		end
		return BREED_X.use(plot, "FertilizerQuickGrow", rf)
	end

	-- Harvest, then if the tree is still standing and it's ours, clear it: the fruit is
	-- already in stock, and a stale tree next to the cross would keep crossing into it.
	local function breedHarvest(plot, rf)
		step("breed " .. plot.Name .. " / harvest")
		if not orchCall(rf.harvest, plot, plot) then
			return false
		end
		breedMine[plot], breedKeep[plot], breedJudged[plot] = true, false, true
		task.wait(0.5)
		local after = plot:GetAttribute("State") or PLOT_EMPTY
		breedOnce("harvest", after == PLOT_EMPTY and "harvest empties the plot" or ("harvest leaves the tree (state " .. after .. ")"))
		if after ~= PLOT_EMPTY then
			breedDestroy(plot, rf)
		end
		return true
	end

	-- Targets still worth hunting: fewer than BREED_ENOUGH donor copies carry them. With 390
	-- Perfect donors banked, another Perfect hit is a 500-token Cleansing for nothing.
	local function needed()
		local have = {}
		for _, row in ipairs(stock()) do
			local m = row.Fruit and fruitMuts(row.Fruit) or {}
			if (row.Count or 0) > 0 and mutsIsDonor(m) then
				for k in pairs(m) do
					have[k] = (have[k] or 0) + row.Count
				end
			end
		end
		local need = {}
		for _, k in ipairs(TARGET_LIST) do
			if (have[k] or 0) < BREED_ENOUGH then
				need[k] = true
			end
		end
		return need, have
	end
	local function carriesNeeded(m, need)
		for k in pairs(need) do
			if (m[k] or 0) > 0 then
				return true
			end
		end
		return false
	end

	-- A hunt/purify verdict: keep a donor, or a target hit that's cleaner than what went in.
	local function nurseryKeeps(f, parent)
		local m = fruitMuts(f)
		if mutsTargets(m) == 0 or not carriesNeeded(m, needed()) then
			return false
		end
		if mutsIsDonor(m) then
			return true
		end
		local pm = parent and fruitMuts(parent) or {}
		return mutsTargets(pm) == 0 or mutsJunk(m) < mutsJunk(pm)
	end

	-- The cleanest target hit in stock that still needs cleansing, if we can pay to cleanse it.
	local function purifyCandidate()
		if not canAfford("FertilizerCleanse") then
			return nil
		end
		local best, bestJunk
		local need = needed()
		for _, row in ipairs(stock()) do
			local m = row.Fruit and fruitMuts(row.Fruit) or {}
			if (row.Count or 0) > 0 and carriesNeeded(m, need) and not mutsIsDonor(m) then
				if not bestJunk or mutsJunk(m) < bestJunk then
					best, bestJunk = row.Fruit, mutsJunk(m)
				end
			end
		end
		return best
	end

	-- The best pure donor in stock, preferring one that carries `want` (a target key) when
	-- asked -- falling back to any donor, so the ring fills with Perfect before a Blessed
	-- donor exists and switches over once one does. Second return: all donor copies.
	local function donorStock(want)
		local best, bestAny, total = nil, nil, 0
		for _, row in ipairs(stock()) do
			local m = row.Fruit and fruitMuts(row.Fruit) or {}
			if (row.Count or 0) > 0 and mutsIsDonor(m) then
				total = total + row.Count
				if not bestAny or seedBeats(row.Fruit, bestAny) then
					bestAny = row.Fruit
				end
				if want and (m[want] or 0) > 0 and (not best or seedBeats(row.Fruit, best)) then
					best = row.Fruit
				end
			end
		end
		return best or bestAny, total
	end

	-- The centre's order: better seed first; on a tie, more junk (up to BREED_SLOTS) wins,
	-- because junk is the only thing donors can turn into targets. A pure Perfect x3 centre
	-- comes back as Perfect x3 + 2 fresh junk every roll -- judged by eat value that's a loss
	-- forever, and the stack never climbs.
	local centreBeats
	do
	local function slots(f)
		return math.min(mutsJunk(fruitMuts(f)), BREED_SLOTS)
	end
	function centreBeats(a, b)
		local sa, sb = fruitSeed(a), fruitSeed(b)
		if math.abs(sa - sb) > 1e-6 then
			return sa > sb
		end
		if b and slots(a) ~= slots(b) then
			return slots(a) > slots(b)
		end
		-- Fast shortens every later generation, up to BREED_X.fast copies. Past
		-- BREED_X.minGrow seconds a tree grows too quickly to reliably fertilize, so less wins.
		if b then
			local function fast(f)
				local n = select(3, BREED_X.split(fruitMuts(f)))
				return BREED_X.grow(f, breedCentre) < BREED_X.minGrow and -n or math.min(n, BREED_X.fast)
			end
			local fa, fb = fast(a), fast(b)
			if fa ~= fb then
				return fa > fb
			end
		end
		return fruitScore(a) > fruitScore(b) + 1e-6
	end
	end

	local function bestStock()
		local best
		for _, row in ipairs(stock()) do
			if row.Fruit and (row.Count or 0) > 0 and (not best or centreBeats(row.Fruit, best)) then
				best = row.Fruit
			end
		end
		return best
	end


	-- Broke: can't pay for a Mysterious roll. Then a miss is worth more ripe than destroyed:
	-- harvested and sold, it's the tokens the next roll and the next Cleansing need.
	function broke()
		return not canAfford("FertilizerMutate")
	end

	-- One tree through the hunt/purify cycle. Returns whether it did anything.
	local function nurseryStep(plot, state, rf)
		if state == PLOT_EMPTY then
			-- every target banked: a hunt roll could only be sold, so don't pay for one
			if not next((needed())) then -- parens: needed() also returns the copy counts
				return false
			end
			local cand = purifyCandidate()
			local f = cand or basicFruit()
			return f ~= nil and breedPlant(plot, f, rf)
		end
		local parent = breedParent[plot]
		if state < PLOT_FINAL then
			local cleansing = parent and mutsTargets(fruitMuts(parent)) > 0
			return breedApply(plot, cleansing and "FertilizerCleanse" or "FertilizerMutate", rf)
		end
		if not breedJudged[plot] then
			local f = plotFruit(plot)
			if not f then
				return false
			end
			breedJudged[plot] = true
			breedKeep[plot] = nurseryKeeps(f, parent)
			if breedKeep[plot] then
				local donor = mutsIsDonor(fruitMuts(f))
				bs.hits = bs.hits + 1
				bs.donors = bs.donors + (donor and 1 or 0)
				note(("kept %s on %s (%s)"):format(fruitLabel(f), plot.Name, donor and "donor" or "needs cleansing"))
			elseif orchUI.sellBroke and broke() then
				breedRolls = breedRolls + 1
				breedKeep[plot] = "sell"
				breedOnce("broke", "out of tokens -- misses now ripen and get sold instead of destroyed")
			else
				breedRolls = breedRolls + 1
				return breedDestroy(plot, rf)
			end
		end
		if state == PLOT_READY then
			return breedHarvest(plot, rf)
		end
		return false
	end

	-- The centre: plant the best seed we have, Mysterious on it, and keep the result only if
	-- it's a better SEED than the best so far (targets only -- the junk it carries is next
	-- generation's conversion slots). A loser is destroyed at FruitGrowing, not left to ripen.
	function BREED_X.centreStep(plot, state, rf)
		if state == PLOT_EMPTY then
			local f = (breedBest and stockCount(breedBest) > 0) and breedBest or bestStock()
			return f ~= nil and breedPlant(plot, f, rf)
		end
		if state < PLOT_FINAL then
			-- Mysterious first: a halved timer must not beat the fertilizer in
			local did = breedApply(plot, "FertilizerMutate", rf)
			return BREED_X.quick(plot, rf) or did
		end
		if not breedJudged[plot] then
			local f = plotFruit(plot)
			if not f then
				return false
			end
			breedJudged[plot] = true
			-- Planting ate a copy of the parent, so destroying a tie burns the line down one copy
			-- per roll until it's gone. With pure donors a roll rarely loses targets (a cross
			-- swaps one mutation for another), so once copies run low an equal roll ripens:
			-- harvested, it's 3-5 copies of a seed just as good.
			local parent = breedParent[plot]
			local beats = centreBeats(f, breedBest or parent)
			local restock = not beats and parent ~= nil and fruitSeed(f) >= fruitSeed(parent) - 1e-6 and stockCount(parent) < BREED_KEEP
			breedKeep[plot] = beats or restock
			breedRolls = breedRolls + 1
			bs.gens = bs.gens + 1
			if beats then
				local was = breedBest or parent
				breedBest = f
				bs.wins = bs.wins + 1
				note(("new best seed x%.2f, eats x%.2f (%s)%s"):format(fruitSeed(f), fruitScore(f), orchUI.key(f),
					was and math.abs(fruitSeed(f) - fruitSeed(was)) < 1e-6 and " -- same seed, more slots for donors" or ""))
			elseif restock then
				note(("centre gen %d tied at x%.2f, ripening it to restock (%d copies left)"):format(bs.gens, fruitSeed(f), stockCount(parent)))
			else
				note(("centre gen %d lost: %s x%.2f"):format(bs.gens, orchUI.key(f), fruitSeed(f)))
				return breedDestroy(plot, rf)
			end
		end
		if state == PLOT_READY then
			return breedHarvest(plot, rf)
		end
		return breedKeep[plot] and BREED_X.quick(plot, rf) or false -- a keeper ripening
	end

	-- Polish: the highest-income fruit you hold, crossed with pure donors and NO fertilizer.
	-- Every swap takes a random mutation type off and puts Perfect or Blessed on, so junk
	-- only ever leaves and a target that's hit comes straight back. Nil once it's clean.
	function BREED_X.polishTarget()
		local best
		for _, row in ipairs(stock()) do
			if row.Fruit and (row.Count or 0) > 0 and (not best or fruitScore(row.Fruit) > fruitScore(best)) then
				best = row.Fruit
			end
		end
		local m = best and fruitMuts(best) or {}
		orchUI.polishT = (best and mutsJunk(m) > 0 and mutsTargets(m) > 0) and best or nil
		return orchUI.polishT
	end

	-- Plant the target, keep a roll only if it eats better, harvest the keeper (it's the next
	-- target). A tie is destroyed and retried -- unless that was the line's last copies, then
	-- it ripens like the centre's restock, so polishing can never lose the fruit.
	function BREED_X.polishStep(plot, state, rf, ready)
		if state == PLOT_EMPTY then
			local T = BREED_X.polishTarget()
			-- donors must stand first: a hunt tree on a donor plot would cross junk in
			return ready and T ~= nil and breedPlant(plot, T, rf)
		end
		if state < PLOT_FINAL then
			-- never Mysterious (it adds the junk we're removing). Cleansing lands after the
			-- donors cross, so it's one extra removal a roll on top of theirs -- a hit on a
			-- target costs one of hundreds, a hit on junk is a roll's work for 500 tokens.
			local did = orchUI.polishCleanse and breedApply(plot, "FertilizerCleanse", rf)
			return BREED_X.quick(plot, rf) or did or false
		end
		if not breedJudged[plot] then
			local f, parent = plotFruit(plot), breedParent[plot]
			if not f then
				return false
			end
			breedJudged[plot] = true
			local better = parent == nil or fruitScore(f) > fruitScore(parent) * (1 + 1e-9)
			local last = parent ~= nil and stockCount(parent) < BREED_KEEP
			breedKeep[plot] = better or last
			bs.polishRolls = (bs.polishRolls or 0) + 1
			if better then
				bs.polishWins = (bs.polishWins or 0) + 1
				note(("polish: %s eats x%.2f, %d junk left"):format(orchUI.key(f), fruitScore(f), mutsJunk(fruitMuts(f))))
			elseif not last then
				return breedDestroy(plot, rf)
			end
		end
		if state == PLOT_READY then
			return breedHarvest(plot, rf)
		end
		return breedKeep[plot] and BREED_X.quick(plot, rf) or false -- a keeper ripening
	end

	function breedSweep(alive, plots)
		local rf = {
			plant = coreRF("OrchardPlot.Plant"),
			harvest = coreRF("OrchardPlot.Harvest"),
			destroy = coreRF("OrchardPlot.DestroyTree"),
			use = coreRF("OrchardPlot.UseItem"),
			buy = tyRF("BuyOrchardItems"),
		}
		if not (rf.plant and rf.harvest and rf.destroy and rf.use and rf.buy and OrchardFruitCls and OrchardItemsCls) then
			say("breed: a remote or module is missing -- see F9")
			return 0
		end
		local g = breedGrid(plots)
		if not next(g) then
			say("breed: no owned plot has a GridPosition -- the game changed its layout")
			return 0
		end
		-- Nothing left to hunt: the nursery rests, so the farm may take every free plot.
		-- Sticky for the session: flipping back would turn standing farm trees into nursery
		-- plots, and the nursery would Cleanse them (they carry targets).
		local lite = not orchBreed -- Polish on, Breed off
		if orchUI.farm and not bs.farmAll and (lite or not next((needed()))) then
			bs.farmAll = true
			note("every target banked -- the farm takes the free plots the nursery leaves")
		end
		local role, donors = breedRoles(plots, g)

		-- Stacking starts once there are enough donors, in stock or already standing, to fill
		-- every plot round the centre.
		local standing, have = 0, {}
		local slot = {}
		for i, d in ipairs(donors) do
			slot[d] = i
			local f = (d:GetAttribute("State") or 0) >= PLOT_FINAL and plotFruit(d)
			if f and mutsIsDonor(fruitMuts(f)) then
				standing = standing + 1
				for k in pairs(fruitMuts(f)) do
					have[k] = true
				end
			end
		end
		local _, inStock = donorStock()
		for _, row in ipairs(stock()) do
			local m = row.Fruit and fruitMuts(row.Fruit) or {}
			if (row.Count or 0) > 0 and mutsIsDonor(m) then
				for k in pairs(m) do
					have[k] = true
				end
			end
		end
		breedStage = (#donors > 0 and standing + inStock >= #donors) and "stack" or "hunt"

		-- The hybrid ring. neighbours() lists row+1, row-1, col+1, col-1, so slots 1-2 and 3-4
		-- are opposite pairs. With only one target on hand every slot takes it (stack Perfect
		-- now, don't idle waiting for a rarer Blessed); once pure donors of both exist, each
		-- pair gets one target. Crossing only ever hands over the donor's own keys, so a
		-- 2+2 ring is what keeps the centre balanced -- and Cash x Speed rewards balance.
		local both = true
		for _, k in ipairs(TARGET_LIST) do
			both = both and have[k] == true
		end
		local function wantFor(i)
			return both and TARGET_LIST[(math.floor((i - 1) / 2) % #TARGET_LIST) + 1] or nil
		end

		local did, ready = 0, #donors > 0 and standing == #donors
		bs.started = bs.started or os.clock()
		bs.last = { role = role, donors = donors, want = {}, ready = ready, standing = standing, inStock = inStock, both = both }
		for i in ipairs(donors) do
			bs.last.want[i] = wantFor(i)
		end
		for _, plot in ipairs(plots) do
			if not alive() then
				return did
			end
			local r = role[plot]
			local state = plot:GetAttribute("State") or PLOT_EMPTY
			if state == PLOT_EMPTY then
				breedMine[plot], breedParent[plot], breedKeep[plot], breedJudged[plot] = nil, nil, nil, nil
			end
			local acted = false
			if r == nil or r == "farm" then
				-- not owned / Mass produce's
			elseif state ~= PLOT_EMPTY and not breedMine[plot] then
				-- A tree the breeder didn't plant: harvest it when ripe (its fruit lands in
				-- stock, so clearing it afterwards loses nothing), never destroy it before.
				if state == PLOT_READY then
					acted = breedHarvest(plot, rf)
				end
			elseif r == "polish" then
				acted = BREED_X.polishStep(plot, state, rf, ready)
			elseif r == "donor" then
				local f = state >= PLOT_FINAL and plotFruit(plot)
				local planted = breedParent[plot]
				local want = wantFor(slot[plot])
				local fm = f and fruitMuts(f)
				if breedStage == "stack" and fm and mutsIsDonor(fm) then
					-- A donor in the ring stands: never harvested. The one exception is the
					-- hybrid switch -- the wrong target on this pair, and a donor of the right
					-- one in stock to replace it. While hunting it's an ordinary nursery hit,
					-- harvested for the copies the ring needs.
					local swap = want and (fm[want] or 0) == 0 and breedMine[plot] and donorStock(want)
					if swap and (fruitMuts(swap)[want] or 0) > 0 then
						if not breedSaid["switch" .. plot.Name] then
							breedSaid["switch" .. plot.Name] = true
							note(("switching %s to a %s donor"):format(plot.Name, want))
						end
						acted = breedDestroy(plot, rf)
					end
				elseif breedStage == "stack" and state ~= PLOT_EMPTY and state < PLOT_FINAL and planted and mutsIsDonor(fruitMuts(planted)) then
					-- a donor growing in: no fertilizer, it would cost the targets
				elseif breedStage == "stack" and state == PLOT_EMPTY then
					local d = donorStock(want)
					acted = d ~= nil and breedPlant(plot, d, rf)
				elseif lite then
					-- polish only: no hunting -- a leftover tree ripens and is harvested, never cut
					acted = state == PLOT_READY and breedHarvest(plot, rf)
				else
					acted = nurseryStep(plot, state, rf)
				end
			elseif r == "nursery" then
				if lite then
					acted = state == PLOT_READY and breedHarvest(plot, rf)
				else
					acted = nurseryStep(plot, state, rf)
				end
			elseif r == "idle" and breedMine[plot] and not breedKeep[plot] and state ~= PLOT_READY then
				acted = breedDestroy(plot, rf) -- a stray of ours next to a hunt tree
			elseif r == "idle" and state == PLOT_READY then
				acted = breedHarvest(plot, rf)
			end
			if acted then
				did = did + 1
			end
		end

		-- The centre goes last and only once every donor is standing, so its first roll
		-- already crosses with the full ring.
		if breedCentre and alive() and orchUI.upgrade and BREED_X.upgrade(breedCentre, rf) then
			did = did + 1
		end
		if breedCentre and alive() then
			local state = breedCentre:GetAttribute("State") or PLOT_EMPTY
			if lite then
				-- polish only: the centre doesn't roll; whatever stands on it ripens and is harvested
				if state == PLOT_READY and breedHarvest(breedCentre, rf) then
					did = did + 1
				end
			elseif breedStage == "stack" and ready then
				if BREED_X.centreStep(breedCentre, state, rf) then
					did = did + 1
				end
			-- hunt only: in "stack" a donor being swapped drops `ready` for a few sweeps, and
			-- this used to cut the fertilized centre roll that was already growing
			elseif breedStage == "hunt" and breedMine[breedCentre] and state ~= PLOT_EMPTY and state ~= PLOT_READY and not breedKeep[breedCentre] then
				if breedDestroy(breedCentre, rf) then -- hunting: the centre stays empty
					did = did + 1
				end
			end
		end

		local best = breedBest or bestStock()
		say(("breed: %s%s · best seed x%.2f (%s) · %d rolls · %d tokens"):format(
			lite and ("polish only, " .. (BREED_X.polishTarget() and "cleaning" or "done -- top fruit is pure Perfect + Blessed, farming it"))
				or breedStage == "stack" and (ready and "stacking" or "planting donors") or ("hunting, " .. inStock .. "/" .. #donors .. " donors"),
			broke() and (orchUI.sellBroke and ", broke: selling misses" or ", broke: rolling without fertilizer") or "",
			fruitSeed(best),
			best and orchUI.key(best) or "none",
			breedRolls,
			tokens()
		))
		return did
	end

	-- What sell must leave alone while breeding: the best seed, any pure donor, and a junked
	-- hit only while its target is still being hunted (it's a Cleansing candidate then).
	orchUI.useful = function(f)
		if not f then
			return false
		end
		local m = fruitMuts(f)
		return fruitSame(f, breedBest) or fruitSame(f, orchUI.farmT) or fruitSame(f, orchUI.polishT) or mutsIsDonor(m) or carriesNeeded(m, needed())
	end

	-- Mass produce. The target: the dropdown's pick while you hold it (the last one seen
	-- stays the target while its trees are all that's left), else the best seed, else the
	-- highest-income fruit you own.
	orchUI.farmTarget = function()
		if orchUI.farmPick then
			for _, row in ipairs(stock()) do
				if row.Fruit and (row.Count or 0) > 0 and orchUI.key(row.Fruit) == orchUI.farmPick then
					orchUI.farmT = row.Fruit
					return row.Fruit
				end
			end
			if orchUI.farmT and orchUI.key(orchUI.farmT) ~= orchUI.farmPick then
				orchUI.farmT = nil
			end
			return orchUI.farmT
		end
		-- auto: the highest-INCOME fruit you hold (what eating pays), not the best seed -- a
		-- seed ranks junk-blind, so the newest best seed can eat for half of an older line
		-- Only ever moves UP: planting every copy of a new target empties the stock, and a
		-- target re-read from stock then fell back to the old, worse fruit and cut the new
		-- trees as "old target" -- polish's clean results were farmed away that way.
		-- ...but a target with no copies and no tree standing can't be farmed at all -- then
		-- it gives way to the best fruit you do hold
		local best = orchUI.farmT
		if best and stockCount(best) == 0 and not orchUI.farmStanding then
			best = nil
		end
		for _, row in ipairs(stock()) do
			if row.Fruit and (row.Count or 0) > 0 and (not best or fruitScore(row.Fruit) > fruitScore(best) * (1 + 1e-9)) then
				best = row.Fruit
			end
		end
		orchUI.farmT = best
		return orchUI.farmT
	end

	-- A farm tree is planted once and harvested every time it regrows (harvest leaves the
	-- tree standing), no fertilizer -- each plant costs 1 copy and every ripening pays 3-5.
	-- It's cut only when the target changed, or its fruit came back different ("drift").
	-- ponytail: whether a regrow can pick up mutations on its own is unmeasured -- the drift
	-- cut and its log line are how you'll find out.
	orchUI.farmSweep = function(alive, plots)
		local rf = { plant = coreRF("OrchardPlot.Plant"), harvest = coreRF("OrchardPlot.Harvest"), destroy = coreRF("OrchardPlot.DestroyTree") }
		if not (rf.plant and rf.harvest and rf.destroy) then
			return 0
		end
		local g = breedGrid(plots)
		local chosen = {}
		if orchUI.owns() then
			for p, r in pairs(bs.last and bs.last.role or {}) do
				if r == "farm" then
					chosen[p] = true
				end
			end
		else
			chosen = farmChoose(g, nil, nil)
		end
		local block = {}
		for p in pairs(chosen) do
			block[p] = true
			for _, n in ipairs(neighbours(p, g)) do
				block[n] = true
			end
		end
		orchUI.farmPlots, orchUI.farmBlock = chosen, block

		local T = orchUI.farmTarget()
		local function spare()
			-- one copy always stays back (to restock a cut tree); BREED_KEEP when the centre
			-- or polish rolls from this same fruit
			local held = orchUI.owns() and (fruitSame(T, breedBest) or fruitSame(T, orchUI.polishT))
			return T and stockCount(T) - (held and BREED_KEEP or 1) or 0
		end
		local did = 0
		for _, plot in ipairs(plots) do
			if not alive() then
				return did
			end
			if chosen[plot] then
				local st = plot:GetAttribute("State") or PLOT_EMPTY
				local f = st >= PLOT_FINAL and plotFruit(plot)
				local ok = false
				if st == PLOT_EMPTY then
					breedMine[plot], breedParent[plot], breedKeep[plot], breedJudged[plot] = nil, nil, nil, nil
					ok = spare() > 0 and breedPlant(plot, T, rf)
				elseif f and fruitSame(f, T) then
					if st == PLOT_READY then
						step("farm " .. plot.Name .. " / harvest")
						ok = orchCall(rf.harvest, plot, plot)
						bs.farmHarvests = (bs.farmHarvests or 0) + (ok and 1 or 0)
					end
				elseif st == PLOT_READY then
					-- someone else's fruit, or a drifted one: take the copies, then clear it
					step("farm " .. plot.Name .. " / harvest")
					ok = orchCall(rf.harvest, plot, plot)
					if f and breedParent[plot] and fruitSame(breedParent[plot], T) and not breedSaid.drift then
						breedSaid.drift = true
						note(("farm fruit drifted on %s: planted %s, grew %s"):format(plot.Name, orchUI.key(T), orchUI.key(f)))
					end
					task.wait(0.5)
					if (plot:GetAttribute("State") or PLOT_EMPTY) ~= PLOT_EMPTY and spare() > 0 then
						breedDestroy(plot, rf)
						bs.farmCuts = bs.farmCuts + 1
					end
				elseif breedMine[plot] and breedParent[plot] and T and not fruitSame(breedParent[plot], T) and spare() > 0 then
					-- our tree of an old target: the new one is ready to go in
					ok = breedDestroy(plot, rf)
					bs.farmCuts = bs.farmCuts + (ok and 1 or 0)
				end
				did = did + (ok and 1 or 0)
			end
		end
		-- For the next sweep and for Auto eat: is a farm plot still empty (then eat leaves the
		-- target alone -- a copy planted pays 3-5 every regrow, a copy eaten pays one buff),
		-- and does a tree of the target stand (then it stays the target at 0 copies).
		local hungry, standing = false, false
		for p in pairs(chosen) do
			local st = p:GetAttribute("State") or PLOT_EMPTY
			hungry = hungry or st == PLOT_EMPTY
			standing = standing or (st ~= PLOT_EMPTY and breedParent[p] ~= nil and fruitSame(breedParent[p], T))
		end
		orchUI.farmHungry, orchUI.farmStanding = hungry and T ~= nil, standing
		return did
	end

	-- Auto eat's first choice while Mass produce runs: the farmed fruit, down to its last copy.
	orchUI.farmEat = function()
		local T = orchUI.farm and orchUI.farmT
		return T and not breedProtects(T, stockCount(T)) and T or nil
	end

	-- The Breeding panel: {row title = text}. Read-only over the sweep's own state, so what
	-- it shows is what the next sweep acts on. Its own frame (a closure) keeps its locals off
	-- the main chunk's 200-register budget.
	orchUI.report = function()
		local STATE = { [0] = "empty", "tree growing", "fruit growing", "ready" }
		local function name(k)
			return MUTS[k] and MUTS[k].DisplayName or k
		end
		local function clock(sec)
			sec = math.max(0, math.floor(sec))
			if sec >= 3600 then
				return ("%dh%02dm"):format(sec // 3600, sec % 3600 // 60)
			end
			return sec >= 60 and ("%dm%02ds"):format(sec // 60, sec % 60) or (sec .. "s")
		end
		local function left(plot)
			local t = plot:GetAttribute("NextTime")
			return type(t) == "number" and (" " .. clock(t - workspace:GetServerTimeNow()) .. " left") or ""
		end
		local function seedTag(f)
			return f and ("%s (seed x%.2f)"):format(orchUI.key(f), fruitSeed(f)) or "none"
		end
		-- A plot's line: state, timer, the fertilizer queued on it, and what's on the tree.
		local function plotLine(plot)
			local st = plot:GetAttribute("State") or PLOT_EMPTY
			local parts = { plot.Name .. ": " .. (STATE[st] or tostring(st)) .. (st > PLOT_EMPTY and st < PLOT_READY and left(plot) or "") }
			local pend = plot:GetAttribute("PendingMutationItem")
			if pend then
				table.insert(parts, "fertilizer " .. (ITEMS[pend] and ITEMS[pend].DisplayName or pend))
			end
			if st >= PLOT_FINAL then
				table.insert(parts, seedTag(plotFruit(plot)))
			elseif breedParent[plot] then
				table.insert(parts, "from " .. fruitLabel(breedParent[plot]))
			end
			if not breedMine[plot] and st ~= PLOT_EMPTY then
				table.insert(parts, "not ours, harvest when ripe")
			elseif breedJudged[plot] then
				table.insert(parts, breedKeep[plot] == "sell" and "miss, ripening to sell" or breedKeep[plot] and "KEEP" or "miss, destroying")
			end
			return table.concat(parts, " · ")
		end

		local rows = {}
		local L = bs.last
		local runFor = bs.started and (os.clock() - bs.started) or 0

		-- Now: which stage, what it's waiting on, and what it's spent.
		local now = {}
		if not orchUI.owns() then
			table.insert(now, "breeder off -- turn on Breed the best fruit")
		elseif not orchBreed then
			table.insert(now, "POLISH ONLY: donor ring kept standing, no hunting, no centre rolls, no Mysterious")
		elseif not L then
			table.insert(now, "starting -- waiting for the first sweep")
		elseif breedStage == "hunt" then
			table.insert(now, ("HUNT: finding pure donors -- %d/%d for the ring (%d standing, %d in stock)"):format(
				L.standing + L.inStock, #L.donors, L.standing, L.inStock))
		else
			table.insert(now, L.ready and ("STACK: ring full, re-rolling the centre -- generation %d"):format(bs.gens + 1)
				or ("STACK: planting donors -- %d/%d standing, centre waits for all"):format(L.standing, #L.donors))
		end
		do
			local need, have = needed()
			local t = {}
			for _, k in ipairs(TARGET_LIST) do
				table.insert(t, ("%s %d%s"):format(name(k), have[k] or 0, need[k] and " (hunting)" or " (enough)"))
			end
			table.insert(now, "donor copies: " .. table.concat(t, " · ") .. (next(need) and "" or " -- nursery rests"))
		end
		local mys, cln = ITEMS.FertilizerMutate, ITEMS.FertilizerCleanse
		table.insert(now, ("tokens %d · Mysterious %d on hand (%s) · Cleansing %d on hand (%s)"):format(
			tokens(),
			itemCount("FertilizerMutate"), canAfford("FertilizerMutate") and "can roll" or "can't afford",
			itemCount("FertilizerCleanse"), canAfford("FertilizerCleanse") and "can cleanse" or "can't afford"))
		if orchBreed and broke() then
			table.insert(now, orchUI.sellBroke and "BROKE: misses ripen and get sold for tokens" or "BROKE: rolling without fertilizer (Broke mode is off)")
		end
		local spent = (bs.used.FertilizerMutate or 0) * (mys and mys.Price or 0) + (bs.used.FertilizerCleanse or 0) * (cln and cln.Price or 0)
		table.insert(now, ("session %s · %d rolls (%.0f/h) · %d hits · %d donors · used %d Mysterious + %d Cleansing (~%d tokens)"):format(
			clock(runFor), breedRolls, runFor > 60 and breedRolls / runFor * 3600 or 0, bs.hits, bs.donors,
			bs.used.FertilizerMutate or 0, bs.used.FertilizerCleanse or 0, spent))
		if (bs.used.FertilizerQuickGrow or 0) > 0 then
			table.insert(now, ("Growth Fertilizer used %d (~%d tokens)"):format(bs.used.FertilizerQuickGrow,
				bs.used.FertilizerQuickGrow * (ITEMS.FertilizerQuickGrow and ITEMS.FertilizerQuickGrow.Price or 0)))
		end
		rows["Now"] = table.concat(now, "\n")

		-- Centre: what's growing, what it came from, and whether it's beating the best.
		if L and breedCentre then
			local c = {}
			table.insert(c, plotLine(breedCentre))
			local st = breedCentre:GetAttribute("State") or PLOT_EMPTY
			-- Perfect / Blessed / Fast / other on what's growing (or what it was planted from),
			-- how fast it grows here, the plot's upgrades, and build-vs-convert.
			local cf = (st >= PLOT_FINAL and plotFruit(breedCentre)) or breedParent[breedCentre] or breedBest
			if cf then
				local p, b, fa, o = BREED_X.split(fruitMuts(cf))
				table.insert(c, ("Perfect %d · Blessed %d · Fast %d · other %d (%d total) · tree grows in %s here"):format(
					p, b, fa, o, p + b + fa + o, clock(BREED_X.grow(cf, breedCentre))))
				local junk = fa + o
				table.insert(c, junk < BREED_SLOTS and ("phase BUILD: pool %d/%d -- rolls add junk faster than the ring converts it"):format(junk, BREED_SLOTS)
					or ("phase CONVERT: pool %d -- the ring is turning junk into Perfect/Blessed"):format(junk))
				if fa > 0 and BREED_X.grow(cf, breedCentre) < BREED_X.minGrow then
					table.insert(c, "Fast is too high: grows under " .. BREED_X.minGrow .. "s, ties now prefer less Fast")
				end
			end
			do
				local have, nextUp = {}, nil
				for _, u in ipairs(BREED_X.upgrades) do
					if breedCentre:GetAttribute(u .. "Unlocked") == true then
						table.insert(have, ITEMS[u] and ITEMS[u].DisplayName or u)
					elseif not nextUp then
						nextUp = u
					end
				end
				table.insert(c, ("plot: %s · growth x%d%s"):format(#have > 0 and table.concat(have, ", ") or "no upgrades",
					BREED_X.speed(breedCentre),
					nextUp and (" · next %s %d tokens%s"):format(ITEMS[nextUp] and ITEMS[nextUp].DisplayName or nextUp,
						ITEMS[nextUp] and ITEMS[nextUp].Price or 0, orchUI.upgrade and "" or " (Upgrade the centre is off)") or ""))
			end
			if st >= PLOT_FINAL and breedBest then
				local f = plotFruit(breedCentre)
				if f then
					table.insert(c, ("vs best x%.2f: %s"):format(fruitSeed(breedBest), centreBeats(f, breedBest) and "BETTER, keeping" or "not better"))
				end
			elseif st == PLOT_EMPTY then
				table.insert(c, breedStage == "stack" and (L.ready and "planting next roll" or "empty until every donor stands") or "kept empty while hunting")
			end
			table.insert(c, ("generations %d · improvements %d%s"):format(bs.gens, bs.wins,
				bs.gens > 0 and (" (%.0f%%)"):format(bs.wins / bs.gens * 100) or ""))
			rows["Centre"] = table.concat(c, "\n")
		else
			rows["Centre"] = orchBreed and "no centre yet: needs an owned plot with " .. BREED_MIN_NEIGHBOURS .. "+ owned neighbours" or "-"
		end

		-- Donor ring: each slot, the target it's assigned, and what stands there.
		if L and #L.donors > 0 then
			local d = {}
			table.insert(d, L.both and "plan: hybrid ring, opposite pairs split between targets (balances Cash x Speed)"
				or "plan: every slot takes the one target you have donors for")
			for i, plot in ipairs(L.donors) do
				local want = L.want[i]
				local st = plot:GetAttribute("State") or PLOT_EMPTY
				local f = st >= PLOT_FINAL and plotFruit(plot)
				local role = breedStage == "hunt" and "hunting here until the ring fills"
					or f and mutsIsDonor(fruitMuts(f)) and "DONOR, crossing into the centre"
					or st == PLOT_EMPTY and "waiting for a donor from stock"
					or "donor growing in"
				table.insert(d, ("#%d %s%s -- %s"):format(i, plotLine(plot), want and (" · wants " .. name(want)) or "", role))
			end
			rows["Donor ring"] = table.concat(d, "\n")
		else
			rows["Donor ring"] = "-"
		end

		-- Nursery + idle: the hunt and purify trees.
		if L then
			local n, idle = {}, 0
			local plots = {}
			for plot, r in pairs(L.role) do
				if r == "nursery" then
					table.insert(plots, plot)
				elseif r == "idle" then
					idle = idle + 1
				end
			end
			table.sort(plots, byId)
			for _, plot in ipairs(plots) do
				local parent = breedParent[plot]
				local job = parent and mutsTargets(fruitMuts(parent)) > 0 and "PURIFY" or "hunt"
				table.insert(n, job .. " " .. plotLine(plot))
			end
			table.insert(n, ("%d nursery plots · %d idle (touch a hunt tree, left alone)"):format(#plots, idle))
			rows["Nursery"] = table.concat(n, "\n")
		else
			rows["Nursery"] = "-"
		end

		-- Stock: best seed, what the next centre roll plants, and every breeding fruit held.
		local s, donors, dirty = {}, {}, {}
		local need = needed()
		for _, row in ipairs(stock()) do
			local m = row.Fruit and fruitMuts(row.Fruit) or {}
			if (row.Count or 0) > 0 and mutsTargets(m) > 0 then
				table.insert(mutsIsDonor(m) and donors or dirty, row)
			end
		end
		table.sort(donors, function(a, b)
			return fruitSeed(a.Fruit) > fruitSeed(b.Fruit)
		end)
		table.sort(dirty, function(a, b)
			return mutsJunk(fruitMuts(a.Fruit)) < mutsJunk(fruitMuts(b.Fruit))
		end)
		-- "Perfect x3" is mutations, "678 copies" is how many you hold: say which is which
		local function listed(list, cap)
			local out = {}
			for i = 1, math.min(#list, cap) do
				local row = list[i]
				table.insert(out, ("  %s -- %d cop%s, seed x%.2f, eats x%.2f"):format(
					orchUI.key(row.Fruit), row.Count, row.Count == 1 and "y" or "ies", fruitSeed(row.Fruit), fruitScore(row.Fruit)))
			end
			if #list > cap then
				table.insert(out, ("  ... and %d more kinds"):format(#list - cap))
			end
			return table.concat(out, "\n")
		end
		local nextSeed = (breedBest and stockCount(breedBest) > 0) and breedBest or bestStock()
		table.insert(s, "best seed: " .. (breedBest and ("%s, eats x%.2f, %d copies"):format(seedTag(breedBest), fruitScore(breedBest), stockCount(breedBest)) or "none bred yet"))
		if breedBest then
			-- Cash x Speed multiply, so at a fixed count the even split is worth the most:
			-- Perfect 10 + Blessed 10 (x6194) eats ~40x what Perfect 20 alone (x156) does.
			local p, b = BREED_X.split(fruitMuts(breedBest))
			local even = (1 + 7.77 * (p + b) / 2) ^ 2
			table.insert(s, ("goal: Perfect %d + Blessed %d = %d stacked · %.0f%% of the even split's x%.0f"):format(
				p, b, p + b, fruitSeed(breedBest) / even * 100, even))
		end
		if nextSeed then
			local junk = mutsJunk(fruitMuts(nextSeed))
			table.insert(s, ("next centre roll: %s · %d junk slot%s for donors to convert"):format(
				seedTag(nextSeed), junk, junk == 1 and "" or "s"))
		end
		table.insert(s, #donors > 0 and (("donors (%d kinds, best first):\n"):format(#donors) .. listed(donors, 5)) or "donors: none yet")
		if #dirty > 0 then
			table.insert(s, ("target hits with junk (%d kinds)%s:\n"):format(#dirty,
				next(need) and ", cleanest first" or " -- not needed, enough donors; Auto sell sells these") .. listed(dirty, 3))
		end
		rows["Stock"] = table.concat(s, "\n")

		local e = {}
		for _, ev in ipairs(bs.events) do
			table.insert(e, clock(os.clock() - ev[1]) .. " ago: " .. ev[2])
		end
		rows["Recent"] = #e > 0 and table.concat(e, "\n") or "nothing yet"

		if orchUI.farm then
			local fl = {}
			local T = orchUI.farmT
			table.insert(fl, ("producing: %s%s"):format(T and orchUI.key(T) or "nothing yet -- no fruit to plant",
				T and (" -- %d copies, eats x%.2f"):format(stockCount(T), fruitScore(T)) or ""))
			local farmed = {}
			for p in pairs(orchUI.farmPlots) do
				table.insert(farmed, p)
			end
			table.sort(farmed, byId)
			for _, p in ipairs(farmed) do
				table.insert(fl, plotLine(p))
			end
			table.insert(fl, ("%d/%d farm plots · %d harvests · %d trees cut"):format(#farmed, orchUI.farmN, bs.farmHarvests or 0, bs.farmCuts))
			rows["Farm"] = table.concat(fl, "\n")
		else
			rows["Farm"] = "Mass produce is off"
		end

		-- Polish: what's being cleaned, how much junk is left, the plot, and the hit rate.
		if not orchUI.polish then
			rows["Polish"] = "Polish is off"
		elseif not (bs.polishPlots and bs.polishPlots[1]) then
			rows["Polish"] = "no polish plot: needs a free plot touching two donors (a diagonal of the centre)"
		else
			local pl = {}
			local T = orchUI.polishT
			if T then
				local p, b, fa, o = BREED_X.split(fruitMuts(T))
				table.insert(pl, ("cleaning %s -- eats x%.2f, %d junk left (Fast %d, other %d), Perfect %d · Blessed %d"):format(
					orchUI.key(T), fruitScore(T), fa + o, fa, o, p, b))
			else
				table.insert(pl, "done: your highest-income fruit is only Perfect + Blessed")
			end
			for _, pp in ipairs(bs.polishPlots) do
				table.insert(pl, plotLine(pp))
			end
			if not (L and L.ready) then
				table.insert(pl, "waits for every donor to stand -- a hunt tree next to it would cross junk in")
			end
			table.insert(pl, ("%d rolls · %d improved"):format(bs.polishRolls or 0, bs.polishWins or 0))
			rows["Polish"] = table.concat(pl, "\n")
		end
		return rows
	end
end)()

-- The sell remote takes the game's own serialised {Fruits = {fruit...}, Counts = {n...}},
-- the same table ClientOrchardFruits builds. Everything goes except the highest-income
-- fruit, which is what the planter and the eater both want.
-- ponytail: "keep the best one" by GetCashFactor; a keep-list by name if that's wrong.
local function sellSpare()
	local sellRF = tyRemotes and tyRemotes:FindFirstChild("SellFruits")
	local o = orchard()
	if not (sellRF and Serialization and o and OrchardFruitsCls) then
		return false
	end
	local keep = bestFruit(1)
	local ok, all = pcall(function()
		return o:GetComponent(OrchardFruitsCls):GetAll()
	end)
	if not (ok and type(all) == "table") then
		return false
	end
	local t = { Fruits = {}, Counts = {} }
	for _, row in ipairs(all) do
		-- While breeding, anything carrying a target (or the best centre fruit) is stock.
		local stockpile = (orchUI.owns() and orchUI.useful(row.Fruit)) or (orchUI.farm and fruitSame(row.Fruit, orchUI.farmT))
		-- the fruit picked in "Eat which fruit" is what Auto eat is waiting on
		stockpile = stockpile or (orchUI.pick and row.Fruit and orchUI.key(row.Fruit) == orchUI.pick)
		if row.Fruit and orchUI.farm and fruitSame(row.Fruit, orchUI.farmT) and (row.Count or 0) > BREED_X.farmKeep then
			-- a full field out-harvests the buff (a copy a minute) many times over: past
			-- farmKeep the surplus is tokens -- Uranium, Cleansing, Growth
			-- Counts is how many to sell: ClientOrchardFruits.SellFruit(fruit, n) sends {[fruit] = n}
			table.insert(t.Fruits, row.Fruit)
			table.insert(t.Counts, row.Count - BREED_X.farmKeep)
		elseif row.Fruit and (row.Count or 0) > 0 and not fruitSame(row.Fruit, keep) and not stockpile then
			table.insert(t.Fruits, row.Fruit)
			table.insert(t.Counts, row.Count)
		end
	end
	if #t.Fruits == 0 then
		return false
	end
	step("sell fruits")
	local okS, payload = pcall(function()
		return Serialization:Serialize(t)
	end)
	return okS and orchCall(sellRF, nil, payload)
end

local function orchardSweep(alive)
	local o = orchard()
	if o and not o:IsUnlocked() then
		say("orchard is still locked -- use Unlock the orchard first")
		return 0
	end
	local harvestRF = coreRF("OrchardPlot.Harvest")
	local plantRF = coreRF("OrchardPlot.Plant")
	local unlockRF = tyRemotes and tyRemotes:FindFirstChild("UnlockPlot")
	local did = 0
	local plots = myPlots()

	for _, plot in ipairs(plots) do
		if not alive() then
			return did
		end
		local state = plot:GetAttribute("State") or PLOT_EMPTY
		local owned = plot:GetAttribute("Enabled") == true
		if orchUI.owns() and owned then
			-- the breeder owns every planted plot; only unlocking stays here
		elseif orchUI.farm and orchUI.farmPlots[plot] then
			-- Mass produce's
		elseif orchHarvest and owned and state == PLOT_READY and harvestRF then
			step("harvest " .. plot.Name)
			if orchCall(harvestRF, plot, plot) then
				did = did + 1
			end
		elseif orchPlant and owned and state == PLOT_EMPTY and plantRF and not (orchUI.farm and orchUI.farmBlock[plot]) then
			-- ponytail: plants the highest-income fruit we own, which is the standard way
			-- to breed better ones. A "keep one of each" rule would need a seed ledger.
			local fruit = bestFruit(1)
			if fruit then
				step("plant " .. plot.Name)
				if orchCall(plantRF, plot, plot, { fruit:Serialize() }) then
					did = did + 1
				end
			end
		-- Available alone is NOT "for sale": an owned plot carries Available=true too (the
		-- dump's Plot21). The game's prompt draws the buy button on Available and not Enabled.
		elseif orchPlots and not owned and plot:GetAttribute("Available") and unlockRF then
			local id = plot:GetAttribute("ID")
			if id then
				step("unlock plot " .. tostring(id))
				if orchCall(unlockRF, plot, id) then
					did = did + 1
				end
			end
		end
	end

	if orchUI.owns() and alive() then
		breedSweep(alive, plots)
	end
	if orchUI.farm and alive() then
		did = did + orchUI.farmSweep(alive, plots)
	end
	-- Broke breeding sells the ripened misses itself: that's the only way it earns back the
	-- tokens for the next roll. sellSpare never sells a target fruit while breeding.
	local breedBroke = orchBreed and select(5, breedInfo())
	if (orchSell or breedBroke) and alive() and sellSpare() then
		did = did + 1
	end
	if orchUI.owns() then
		-- breedSweep already wrote the status row
	elseif did > 0 then
		say(("orchard: %d actions across %d plots"):format(did, #plots))
	elseif #plots == 0 then
		say("orchard: no plots found under your tycoon")
	end

	-- Eating is a timed income buff, so all that matters is that one is always active.
	-- Count >= 2 so we never eat the last copy of the fruit the planter wants.
	if orchEat and EffectApplierCls then
		local o = orchard()
		local eatRF = tyRemotes and tyRemotes:FindFirstChild("EatFruit")
		if o and eatRF then
			local okC, current = pcall(function()
				return o:GetComponent(EffectApplierCls):GetCurrentFruit()
			end)
			if okC and current == nil then
				local fruit = orchUI.farmEat()
				if not fruit then
					-- eat for income (Cash x Speed), never the star rating: stars count Fast and
					-- token value, so Perfect x30 + Fast x4 (10 stars, x234) outrated Perfect x264 +
					-- Blessed x55 (8.5 stars, x377k). Breeding stock stays at BREED_KEEP; without the
					-- breeder one copy stays back for the planter.
					local bestS, keep = nil, orchUI.owns() and 0 or 1
					for _, row in ipairs(stock()) do
						local s = row.Fruit and fruitScore(row.Fruit)
						if s and (row.Count or 0) > keep and not breedProtects(row.Fruit, row.Count) and (not bestS or s > bestS) then
							fruit, bestS = row.Fruit, s
						end
					end
				end
				if orchUI.pick then
					-- a named pick: eat it or nothing -- a stand-in would hold the buff slot
					-- for its whole duration and lock the pick out when it comes back
					fruit = nil
					for _, row in ipairs(stock()) do
						if row.Fruit and (row.Count or 0) > 0 and orchUI.key(row.Fruit) == orchUI.pick then
							if orchUI.owns() and breedProtects(row.Fruit, row.Count) then
								say("eat: " .. orchUI.pick .. " is breeding stock, not eating it")
							else
								fruit = row.Fruit
							end
							break
						end
					end
					if not fruit then
						say("eat: no " .. orchUI.pick .. " in your inventory")
					end
				end
				if fruit then
					step("eat fruit")
					if orchCall(eatRF, nil, { fruit:Serialize() }) then
						did = did + 1
					end
				end
			end
		end
	end

	return did
end

local function unlockOrchard()
	local o = orchard()
	if not o then
		return false, "no orchard in this world"
	end
	if o:IsUnlocked() then
		return false, "orchard already unlocked"
	end
	local rem = tyRemotes and tyRemotes:FindFirstChild("UnlockOrchard")
	if not rem then
		return false, "no UnlockOrchard remote"
	end
	local r = callTimed(rem, 8)
	if r and r[1] then
		return true, "orchard unlocked"
	end
	return false, "refused" .. (r and r[2] and (" (" .. tostring(r[2]) .. ")") or "")
end

-- loops ----------------------------------------------------------------------
-- One generation counter per loop, kept in the loop's own table: a shared one works right
-- up until there are two loops, because every callback bumps it and only the newest
-- thread survives. Only the current generation is allowed to flip its own switch off.
-- onExit runs the moment the switch drops, not when the thread next wakes (up to a whole
-- gap later). inBody is the watchdog's "working, not sleeping between beats".
local function looper(name, body, gapFn, onExit)
	local L = { on = false, gen = 0, inBody = false }
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
					warn(("[lemons] %s loop: %s"):format(name, tostring(err)))
				end
				if not alive() then
					break
				end
				task.wait(gapFn())
			end
			if L.gen == mine then
				step("idle")
			end
		end)
	end
	return L
end

local bought, upgraded, woke, poweredUp, specialed = 0, 0, 0, 0, 0
local resets = { rebirth = 0, evolve = 0, ascend = 0 }
local purchasesFirst = true

local buyMem = { idle = false, count = 0 } -- saving up (slow the beat) / purchases last pass
local buyLoop = looper("buy", function()
	-- The count dropping is a reset, whoever did it -- the manual ones included.
	local have = purchaseCount()
	if have < buyMem.count then
		forgetTycoon()
	end
	buyMem.count = have
	local p, price, blocked = nextBuy()
	buyMem.idle = not p
	if p then
		local got = buy(p)
		if got == true then
			bought = bought + 1
			misses[p.Name] = nil
			say(("bought %s for %s"):format(p.DisplayName or p.Name, money(price)))
		elseif got == false then
			-- Only a real refusal counts. nil means we never got to fire, which is the
			-- click sweep holding the claim, not the server saying no.
			if strike(p.Name) then
				log(("%s refused %d times -- stepping over it for %ds"):format(p.Name, PARK_AFTER, PARK_FOR))
			end
		end
	elseif blocked then
		-- Can't afford it: the cash has to come from somewhere. Right after a reset that's
		-- the first earner, which is manual until its Manager is bought -- so wake it here
		-- rather than wait for Auto wake income to be switched on too. Per-stream pacing
		-- comes from the server, so this costs nothing when every stream is running.
		wakeSweep()
		say(("saving for %s -- %s"):format(blocked.DisplayName or blocked.Name, money(price)))
	else
		say("tycoon complete -- nothing left to buy")
	end
end, function()
	return buyMem.idle and BUY_IDLE or BUY_GAP
end)

local upLoop = looper("upgrade", function()
	-- The reserve is the next purchase's price, so upgrades spend only the cash the buy
	-- loop isn't already saving. Turn "purchases first" off to upgrade flat out.
	local reserve
	-- only while Auto buy is on: otherwise nobody spends the reserve and upgrades stall
	if purchasesFirst and buyLoop.on then
		local _, price = nextBuy()
		reserve = price
	end
	local ok, who, count = upgradeOnce(reserve)
	if ok then
		upgraded = upgraded + 1
		say(("upgraded %s +%d"):format(who, count or 1))
	end
end, function()
	return UP_GAP
end)

local wakeLoop = looper("wake", function()
	woke = woke + wakeSweep()
end, function()
	return WAKE_GAP
end)

local powerLoop = looper("power", function()
	local ok, name, lvl = powerBuyOnce()
	if ok then
		poweredUp = poweredUp + 1
		say(("power %s -> level %d"):format(name, lvl))
	end
end, function()
	return POWER_GAP
end)

local specialLoop = looper("special", function()
	local ok, name = specialUnlockOnce()
	if ok then
		specialed = specialed + 1
		say("unlocked " .. name)
	end
end, function()
	return SPECIAL_GAP
end)

local resetLoop = looper("reset", function()
	if autoAscend and ascendReady() then
		local ok = doReset("ascend")
		resets.ascend = resets.ascend + (ok and 1 or 0)
		say(ok and "ascended" or "ascend refused")
		return
	end
	-- Ascend is worth more than either, and both reset the purchases it counts, so near the
	-- finish they wait. ascendReady's progress is purchased / required, off the game's own
	-- TycoonAscension.
	if autoAscend and (autoEvolve or autoRebirth) then
		local _, prog = ascendReady()
		-- The clock restarts on every step forward, so a hold only lets go once buying
		-- stalls. Below the threshold there's no hold to time: forget it, so a climb after
		-- a reset starts a fresh clock instead of inheriting an old, long-expired one.
		if prog < ASCEND_HOLD then
			resets.holdProg = nil
		elseif prog > (resets.holdProg or -1) then
			resets.holdProg, resets.holdAt = prog, os.clock()
		end
		local stalled = math.floor(os.clock() - (resets.holdAt or 0))
		if resets.holdProg and stalled < ASCEND_STALL then
			say(("holding rebirth/evolve for ascend -- %.0f%% bought, lets go after %ds with no new purchase (%ds so far)"):format(
				prog * 100, ASCEND_STALL, stalled))
			return
		end
	end
	if autoEvolve and evolveReady() then
		local ok = doReset("evolve")
		resets.evolve = resets.evolve + (ok and 1 or 0)
		say(ok and "evolved" or "evolve refused")
		return
	end
	if autoRebirth then
		local worth, pot = rebirthWorth()
		if worth then
			local ok = doReset("rebirth")
			resets.rebirth = resets.rebirth + (ok and 1 or 0)
			say(ok and ("rebirthed for " .. plain(pot) .. " investors") or "rebirth refused")
		end
	end
end, function()
	return RESET_GAP
end)

local clicks = 0
local clickLoop = looper("click", function(alive)
	clicks = clicks + clickSweep(alive)
end, function()
	return clickIdle and CLICK_IDLE or CLICK_GAP
end, function()
	-- wait out a tree mid-click (or another mover's hop); the sweep checks alive() before
	-- the next tree, so once the claim is free nothing moves us again
	while busy do
		task.wait()
	end
	if clickHome then
		hopToPos(clickHome, 0)
		clickHome = nil
	end
end)

-- Each on its own pcall: one of them throwing (a reply shape we didn't expect) used to
-- abort the rest of the pass, every pass. And their answers now reach the status row.
local extraLoop = looper("extras", function()
	local said = {}
	for _, fn in ipairs({ vineClaim, playRace, playTrade }) do
		local ok, a, b = pcall(fn)
		table.insert(said, tostring(ok and b or a))
	end
	pcall(claimCompanions)
	say(table.concat(said, " · "))
end, function()
	return EXTRA_GAP
end)

local orchLoop = looper("orchard", function(alive)
	orchardSweep(alive)
end, function()
	return ORCH_GAP
end)

-- anti-afk ---------------------------------------------------------------------
-- Two layers. The nudge stops the idle kick: VirtualUser on Idled and on a beat, plus
-- VirtualInputManager because some clients ignore VirtualUser. The rejoin covers the
-- disconnects a nudge can't (server restart, network drop) -- an ErrorPrompt is the one
-- thing all of those share. Both are CoreGui/Player connections teardown can't reach
-- through the panel, so they live in afk.conns and every handler checks afk.on too.
-- One table, methods on it: the main chunk is at Luau's 200-register ceiling.
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
	local mine = afk.gen
	afk.on = on
	for _, c in ipairs(afk.conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(afk.conns)
	if not on then
		return
	end
	local function alive()
		return afk.on and afk.gen == mine
	end
	table.insert(afk.conns, player.Idled:Connect(afk.nudge))
	task.spawn(function()
		-- WaitForChild yields, so it runs here rather than on the toggle's callback.
		local overlay
		pcall(function()
			overlay = game:GetService("CoreGui"):WaitForChild("RobloxPromptGui", 10):WaitForChild("promptOverlay", 10)
		end)
		if overlay and alive() then
			table.insert(
				afk.conns,
				overlay.ChildAdded:Connect(function(child)
					if child.Name ~= "ErrorPrompt" or not alive() then
						return
					end
					warn("[lemons] disconnected -- rejoining in " .. REJOIN_DELAY .. "s")
					task.wait(REJOIN_DELAY)
					pcall(function()
						game:GetService("TeleportService"):Teleport(game.PlaceId, player)
					end)
				end)
			)
		elseif not overlay then
			warn("[lemons] no promptOverlay -- anti-afk will nudge but can't rejoin")
		end
		while alive() do
			task.wait(AFK_BEAT)
			if alive() then
				afk.nudge()
			end
		end
	end)
end

-- Separate thread on purpose: a loop thread parked in a yielding InvokeServer can't
-- report that it is.
local dogGen = 0
local function startDog()
	dogGen = dogGen + 1
	local mine = dogGen
	task.spawn(function()
		while dogGen == mine do
			-- inside a body, not merely on: an idle orchard or a buy loop saving up doesn't move
			-- the mark either, and used to report "stuck" every 25s
			local running = false
			for _, l in ipairs({ buyLoop, upLoop, wakeLoop, powerLoop, specialLoop, resetLoop, clickLoop, extraLoop, orchLoop }) do
				running = running or (l.on and l.inBody)
			end
			if running and os.clock() - markAt > WATCHDOG then
				warn(("[lemons] stuck %ds at: %s"):format(math.floor(os.clock() - markAt), mark))
				markAt = os.clock()
			end
			task.wait(5)
		end
	end)
end

-- gui --------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Sell Lemons", -- fallback until the live name lands
	folder = "SellLemons", -- never rename: saved configs orphan
	size = UDim2.fromOffset(560, 460),
})
if not Window then
	return -- panel.lua already said why
end

-- WindUI hands a Multi dropdown's callback one of three shapes depending on the build
-- panel.lua fetched: a list, a map, or the row tables back. Normalise into a set we own --
-- reading a map as a list leaves the set empty, and an empty set matches nothing.
local function ticked(v)
	local set = {}
	if type(v) ~= "table" then
		return set
	end
	for k, val in pairs(v) do
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

-- Each tab's sections live in a do-block: nothing after a tab touches them, and the main
-- chunk is at Luau's 200-register ceiling.
do
local Main = Window:Tab({ Title = "Tycoon", Icon = "solar:home-2-bold" })

local Build = Main:Section({ Title = "Build", Icon = "solar:hammer-bold", Box = true, BoxBorder = true, Opened = true })

Build:Toggle({
	Title = "Auto buy",
	Desc = "Fires each button's own Purchase remote in Balance.PurchaseOrder -- no walking",
	Value = false,
	Callback = function(on)
		buyLoop.set(on)
		say(on and "buying" or "buy stopped")
	end,
})

Build:Toggle({
	Title = "Buy out of order when blocked",
	Desc = "Off: save for the next item in the game's own order, which puts income first",
	Value = buyAhead,
	Callback = function(on)
		buyAhead = on
	end,
})

Build:Toggle({
	Title = "Forever purchase, best first",
	Desc = "Spends your free Forever Purchase slots (one per ascension) as Auto buy reaches each item: highest income source first, then global cash/speed multipliers, then managers and minigames, then decor. Never buys slots with Robux",
	Value = false,
	Callback = function(on)
		forever.on = on
		local name = forever.target()
		say(on and ("forever: %d slot(s), next %s"):format(forever.slots(), tostring(name)) or "forever purchases off")
	end,
})

Build:Toggle({
	Title = "Auto upgrade earners",
	Desc = "Uses the UpgradeStack power's stack size, read off the game's own GetNextUpgradeInfo",
	Value = false,
	Callback = function(on)
		upLoop.set(on)
	end,
})

Build:Dropdown({
	Title = "Upgrade order",
	Values = UP_MODES,
	Value = upMode,
	Callback = function(v)
		if type(v) == "string" and v ~= "" then
			upMode = v
		end
	end,
})

Build:Toggle({
	Title = "Purchases first",
	Desc = "Upgrades only spend cash above the next purchase's price -- purchases unlock earners",
	Value = purchasesFirst,
	Callback = function(on)
		purchasesFirst = on
	end,
})

Build:Toggle({
	Title = "Auto wake income",
	Desc = "A stream with no Manager pays once and sleeps; this wakes it remotely, paced by the server",
	Value = false,
	Callback = function(on)
		wakeLoop.set(on)
	end,
})

local Power = Main:Section({ Title = "Powers", Icon = "solar:bolt-circle-bold", Box = true, BoxBorder = true, Opened = false })

Power:Toggle({
	Title = "Auto buy powers",
	Desc = "Powers cost INVESTORS (not cash, not Robux); buys a level only while it costs at most half your investors",
	Value = false,
	Callback = function(on)
		powerLoop.set(on)
	end,
})

do
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
			local want = ticked(v)
			table.clear(wantPowers)
			for name in pairs(want) do
				wantPowers[name] = true
			end
		end,
	})
end

Power:Toggle({
	Title = "Auto unlock specials",
	Desc = "Stargate / Staircase / Reactor pieces -- gated on ascensions and energy, never cash",
	Value = false,
	Callback = function(on)
		specialLoop.set(on)
	end,
})

local Reset = Main:Section({ Title = "Resets", Icon = "solar:refresh-circle-bold", Box = true, BoxBorder = true, Opened = false })

-- No master switch: the checks run while any of the three is on. The old "Run the reset
-- checks" toggle sat at the bottom of a collapsed card and read as "auto rebirth is broken".
local function resetArm()
	local want = autoAscend or autoEvolve or autoRebirth
	if want ~= resetLoop.on then
		resetLoop.set(want)
	end
end

Reset:Toggle({
	Title = "Auto ascend",
	Desc = "Only possible at 100% of the tycoon: x" .. tostring(Config.AscensionMultiplier) .. " income, x" .. tostring(Config.AscensionPenalty) .. " prices",
	Value = autoAscend,
	Callback = function(on)
		autoAscend = on
		resetArm()
	end,
})

Reset:Toggle({
	Title = "Auto evolve",
	Desc = "At 100% evolution progress: x" .. tostring(Config.EvolutionMultiplier) .. " income speed. Beats a rebirth whenever it's ready",
	Value = autoEvolve,
	Callback = function(on)
		autoEvolve = on
		resetArm()
	end,
})

Reset:Toggle({
	Title = "Auto rebirth",
	Desc = "Trades cash for investors once the potential clears the ratio below",
	Value = autoRebirth,
	Callback = function(on)
		autoRebirth = on
		resetArm()
	end,
})

Reset:Input({
	Title = "Rebirth at ratio",
	Desc = "Potential investors as a multiple of what you hold. 1 = double your investors",
	Value = tostring(RB_RATIO),
	Placeholder = "1",
	Callback = function(txt)
		local n = tonumber(txt)
		if n and n > 0 then
			rbRatio = n
			say("rebirth ratio " .. n)
		end
	end,
})


end

do
local Free = Window:Tab({ Title = "Free cash", Icon = "solar:dollar-minimalistic-bold" })

local Drops = Free:Section({ Title = "Drops", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })

Drops:Toggle({
	Title = "Auto collect drops",
	Desc = "Fires each drop's own pickup, as if you walked into it -- from anywhere, every 2s, including drops already on the ground",
	Value = false,
	Callback = function(on)
		setDrops(on)
		say(on and "collecting drops" or "drops off")
	end,
})

do
	local kinds = {}
	for kind in pairs(DROP_KINDS) do
		table.insert(kinds, kind)
	end
	table.sort(kinds)
	Drops:Dropdown({
		Title = "Which drops",
		Values = kinds,
		Multi = true,
		AllowNone = true,
		Value = kinds,
		Callback = function(v)
			local want = ticked(v)
			table.clear(dropKinds)
			for kind in pairs(want) do
				dropKinds[kind] = true
			end
		end,
	})
end

local Side = Free:Section({ Title = "Side income", Icon = "solar:gift-bold", Box = true, BoxBorder = true, Opened = true })

Side:Toggle({
	Title = "Auto click lemons",
	Desc = clickOk and "One lemon every " .. CLICK_RATE .. "s, confirmed picked before moving on. Skips trees with nothing on them"
		or "unavailable: this executor has no fireclickdetector",
	Value = false,
	Callback = function(on)
		if on and not clickOk then
			say("no fireclickdetector in this executor")
			return
		end
		clickLoop.set(on)
	end,
})

Side:Toggle({
	Title = "...including other plots' trees",
	Desc = "Their Hill trees are usually untouched, which is where the lemons are once your grove is bare",
	Value = clickForeign,
	Callback = function(on)
		clickForeign = on
		clickIdle = false -- a fresh set of trees: go and look now, don't sit out the backoff
	end,
})

Side:Toggle({
	Title = "Auto extras",
	Desc = "Cash vine, both minigames at max payout, and pending companions, on a 10s beat",
	Value = false,
	Callback = function(on)
		extraLoop.set(on)
	end,
})

Side:Toggle({
	Title = "Auto phone offers",
	Desc = "Accepts the server's cash offer the moment it lands, skipping the phone UI",
	Value = false,
	Callback = function(on)
		setPhone(on)
	end,
})

Side:Input({
	Title = "Raise the offer N times",
	Desc = "0 = accept at once. The server can walk away from a raise, so this is a gamble",
	Value = "0",
	Placeholder = "0",
	Callback = function(txt)
		local n = tonumber(txt)
		if n and n >= 0 then
			phoneRaises = math.floor(n)
			say("raising " .. phoneRaises .. "x before accepting")
		end
	end,
})

Side:Button({
	Title = "Play a minigame now",
	Desc = "Race and Trade both report their own outcome; this reports the best legal one",
	Callback = function()
		task.spawn(function()
			local _, r = playRace()
			local _, t = playTrade()
			say(tostring(r) .. " / " .. tostring(t))
		end)
	end,
})

Side:Button({
	Title = "Use owned boosts",
	Desc = "Only consumables already in your inventory -- nothing here opens a Robux prompt",
	Callback = function()
		task.spawn(function()
			local n = useOwnedBoosts()
			say(n == 0 and "no owned boosts to use" or ("used %d boost(s)"):format(n))
		end)
	end,
})

Side:Button({
	Title = "Dismiss the offline popup",
	Desc = "The cash is already yours; this clears the window it reserves",
	Callback = function()
		say(claimOffline() and "offline popup cleared" or "nothing to clear")
	end,
})

end

local Orch = Window:Tab({ Title = "Orchard", Icon = "solar:leaf-bold" })
local Grow = Orch:Section({ Title = "Grow", Icon = "solar:leaf-bold", Box = true, BoxBorder = true, Opened = true })

-- No master switch: the loop runs while any of these is on. A separate "run the loop"
-- toggle read as "Auto harvest is on and nothing happens".
local function orchArm()
	local want = orchHarvest or orchPlant or orchEat or orchPlots or orchSell or orchBreed or orchUI.farm or orchUI.polish
	if want ~= orchLoop.on then
		orchLoop.set(want)
	end
end

for _, row in ipairs({
	{ "Auto harvest", "Every ready plot you own -- tokens and a fruit, no prompt", function(on) orchHarvest = on end },
	{ "Auto replant", "Plants the highest-income (Cash x Speed) fruit you own into every empty plot", function(on) orchPlant = on end },
	{ "Auto eat", "Keeps a fruit buff active at all times; keeps one copy back for the planter", function(on) orchEat = on end },
	{ "Auto unlock plots", "Buys any plot that's for sale -- these cost tokens, not cash", function(on) orchPlots = on end },
	{ "Auto sell spare fruit", "Sells every fruit except your highest-income one, for tokens", function(on) orchSell = on end },
	{
		"Breed the best fruit",
		"Wiki method: hunt Perfect/Blessed on free fruit, cleanse to a donor, ring a centre plot with donors, re-roll the centre. Takes over every planted plot; spends tokens on Mysterious (20) and Cleansing (500) fertilizer, plus whatever the two toggles below allow",
		function(on) orchBreed = on end,
	},
	{
		"Upgrade the centre",
		"Buys Enriched Uranium (+2 mutations every roll, 10000 tokens), then Irrigation (500) and Soil Enricher (5000) for the centre plot, in that order, keeping 200 tokens for rolls. Permanent plot upgrades, tokens only",
		function(on) orchUI.upgrade = on end,
	},
	{
		"Growth fertilizer on centre",
		"Growth Fertilizer (100 tokens) on the centre and the polish plot whenever a tree or a kept fruit has 90s+ left -- each halves the wait. Faster generations, but 5x a Mysterious roll per use",
		function(on) orchUI.quick = on end,
	},
	{
		"Mass produce",
		"Grows the fruit picked below on its own farm plots, no fertilizer, and harvests each tree every time it regrows. Auto eat eats it first. Farm plots never touch the centre, a hunt tree or each other",
		function(on) orchUI.farm = on end,
	},
	{
		"Polish the top fruit",
		"Crosses your highest-income fruit with the pure donors on the four plots diagonal to the centre, no fertilizer, keeping a roll only if it eats better -- junk comes off, Perfect/Blessed go on, free. Goes idle once the top fruit is only Perfect + Blessed (Mass produce farms it) and restarts when a better fruit with junk shows up. Works with Breed off: the donor ring stays, nothing is hunted or rolled",
		function(on) orchUI.polish = on end,
	},
	{
		"Polish with Cleansing",
		"Cleansing Fertilizer (500 tokens) on every polish roll: one extra random mutation off after the donors' swaps. Roughly 1.3-2x faster polishing; a miss only costs one Perfect/Blessed copy",
		function(on) orchUI.polishCleanse = on end,
	},
	{
		"Broke mode",
		"Out of tokens for Mysterious: let misses ripen and sell them (plus spare fruit) for tokens. Off: misses are destroyed and trees keep rolling with no fertilizer",
		function(on) orchUI.sellBroke = on end,
	},
}) do
	Grow:Toggle({
		Title = row[1],
		Desc = row[2],
		Value = row[4] == true,
		Callback = function(on)
			row[3](on)
			orchArm()
		end,
	})
end

-- Rebuilt from the fruit inventory on Heartbeat (UI writes need our identity), only when
-- the set of names changes: Refresh leaks connections and redraws under the cursor.
do
	local AUTO = "Best available"
	orchUI.key = function(f)
		local ok, name = pcall(function()
			return f:GetFruitName()
		end)
		return (ok and name or "Fruit") .. " - " .. fruitLabel(f)
	end
	local dd = Grow:Dropdown({
		Title = "Eat which fruit",
		Desc = "Auto eat uses this one only; waits while you have none. Best available = highest income",
		Values = { AUTO },
		Value = AUTO,
		Callback = function(v)
			v = type(v) == "table" and (v.Title or v[1]) or v
			if v == AUTO then
				orchUI.pick = nil
			elseif type(v) == "string" and v ~= "" then
				orchUI.pick = v
			end -- "" is Refresh re-firing; keep the pick
		end,
	})
	local FARM_AUTO = "Highest income (auto)"
	local farmDd = Grow:Dropdown({
		Title = "Mass produce which fruit",
		Desc = "Highest income (auto) farms whichever fruit you hold eats for the most (Cash x Speed)",
		Values = { FARM_AUTO },
		Value = FARM_AUTO,
		Callback = function(v)
			v = type(v) == "table" and (v.Title or v[1]) or v
			if v == FARM_AUTO then
				orchUI.farmPick = nil
			elseif type(v) == "string" and v ~= "" then
				orchUI.farmPick = v
			end
		end,
	})
	Grow:Input({
		Title = "Farm plots",
		Desc = "Plots Mass produce holds while the nursery still hunts. Once every target is banked it takes every free plot (none touching each other)",
		Value = tostring(orchUI.farmN),
		Placeholder = "3",
		Callback = function(text)
			local n = tonumber(text)
			if n and n >= 1 then
				orchUI.farmN = math.floor(n)
			else
				say("farm plots unchanged -- needs a number from 1")
			end
		end,
	})

	-- {dropdown, its auto row, the orchUI field holding its pick}; one inventory read feeds both
	local lists = { { dd, AUTO, "pick", nil }, { farmDd, FARM_AUTO, "farmPick", nil } }
	local nextAt = 0
	orchUI.conn = RunService.Heartbeat:Connect(function()
		if os.clock() < nextAt then
			return
		end
		nextAt = os.clock() + 3
		local have, seen = {}, {}
		for _, row in ipairs(stock()) do
			local k = row.Fruit and (row.Count or 0) > 0 and orchUI.key(row.Fruit)
			if k and not seen[k] then
				seen[k] = true
				table.insert(have, k)
			end
		end
		for _, l in ipairs(lists) do
			local auto, pick = l[2], orchUI[l[3]]
			local names = { auto }
			for _, k in ipairs(have) do
				table.insert(names, k)
			end
			-- keep a pick you've run out of on the list, so it doesn't silently flip to auto
			if pick and not seen[pick] then
				table.insert(names, pick)
			end
			table.sort(names, function(a, b)
				return a == auto or (b ~= auto and a < b)
			end)
			local now = table.concat(names, "\0")
			if now ~= l[4] then
				l[4] = now
				pcall(function()
					l[1]:Refresh(names)
					l[1]:Select(pick or auto)
				end)
			end
		end
	end)
end

Grow:Button({
	Title = "Unlock the orchard",
	Desc = "Costs " .. money(Huge.toHuge(Config.Orchard.UnlockCashPrice)) .. " at base; the server's live price may differ",
	Callback = function()
		local _, msg = unlockOrchard()
		say(msg)
	end,
})

local Misc = Window:Tab({ Title = "Info", Icon = "solar:info-circle-bold" })
Misc:Section({ Title = "Session", Icon = "solar:shield-check-bold", Box = true, BoxBorder = true, Opened = true })
	:Toggle({
		Title = "Anti-AFK",
		Desc = "Clicks for you so the idle kick never lands, and rejoins this game if you get disconnected anyway",
		Value = true,
		Callback = function(on)
			afk.set(on)
			say(on and "anti-afk on" or "anti-afk off")
		end,
	})
-- A starting Value doesn't fire the callback, so on-by-default has to be armed by hand.
afk.set(true)
local Travel = Misc:Section({ Title = "Travel", Icon = "solar:map-point-bold", Box = true, BoxBorder = true, Opened = true })

-- Location teleports in this game are client-side (the server only ever tells the client
-- to move itself), so the dropdown is a straight CFrame write with nothing to confirm.
do
	local names, byName = {}, {}
	if locations then
		local ok, all = pcall(function()
			return locations:GetLocations()
		end)
		if ok then
			for name, loc in pairs(all) do
				if loc.CFrame then
					table.insert(names, name)
					byName[name] = loc.CFrame
				end
			end
		end
	end
	table.sort(names)
	if #names > 0 then
		Travel:Dropdown({
			Title = "Teleport to",
			Values = names,
			Value = names[1],
			Callback = function(v)
				-- Refuse rather than block: the click sweep would yank you back within the
				-- second, and a lock that waits it out reads as a broken button.
				if clickLoop.on then
					say("turn Auto click lemons off first -- it would move you straight back")
					return
				end
				local cf = byName[v]
				if cf and hopToPos(cf.Position, 0) then
					say("moved to " .. v)
				end
			end,
		})
	end
end

local Stats = Misc:Section({ Title = "Dashboard", Icon = "solar:chart-2-bold", Box = true, BoxBorder = true, Opened = true })
local status = Stats:Paragraph({ Title = "Status", Desc = "idle" })

-- One row per topic, so a long block doesn't hide the line you're looking for. Every row
-- is written ONLY from Heartbeat: the dashboard thread builds text after a task.wait, and a
-- resumed thread has lost the capability the hidden GUI needs -- the pcall swallowed that
-- and the old single row sat on "reading..." forever.
local dashRow, dashText = {}, {}
for _, title in ipairs({ "Money", "Resets", "Tycoon", "Orchard", "Session", "Running" }) do
	dashRow[title] = Stats:Paragraph({ Title = title, Desc = "reading..." })
end
-- The breeder's own panel, on the Orchard tab; fed through the same Heartbeat drain.
do
	local sec = Orch:Section({ Title = "Breeding", Icon = "solar:dna-bold", Box = true, BoxBorder = true, Opened = true })
	for _, title in ipairs({ "Now", "Farm", "Polish", "Centre", "Donor ring", "Nursery", "Stock", "Recent" }) do
		dashRow[title] = sec:Paragraph({ Title = title, Desc = "reading..." })
	end
end

-- A resumed loop thread lacks the capability the hidden GUI needs; Heartbeat runs with ours.
local drain = RunService.Heartbeat:Connect(function()
	for title, text in pairs(dashText) do
		dashText[title] = nil
		pcall(function()
			dashRow[title]:SetDesc(text)
		end)
	end
	if pending == nil then
		return
	end
	local msg = pending
	pending = nil
	if not pcall(function()
		status:SetDesc(msg)
	end) then
		log(msg)
	end
end)

local dashGen = 0
-- Its own function frame: the file sits at Luau's 200-register ceiling.
local startDash = (function()
	local function pct(x)
		return ("%d%%"):format(math.floor(math.clamp(x, 0, 1) * 100))
	end

	-- Log10 space: progress toward the rebirth gate is 10^(potential - target), where the
	-- target is what Auto rebirth waits for: your investors x the ratio, never below RB_MIN.
	local function rebirthProgress()
		local pot, have = potentialInvestors(), investors()
		local target = Huge.toHuge(RB_MIN)
		if have > HZERO then
			target = math.max(target, Huge.multiply(have, Huge.toHuge(math.max(rbRatio, 0.0001))))
		end
		if pot == HZERO then
			return 0, target
		end
		return math.min(1, 10 ^ (pot - target)), target
	end

	local function tokenCount()
		local ok, t = pcall(function()
			return balances:GetTokens()
		end)
		return ok and tonumber(t) or 0
	end

	local function orchardLine()
		local o = orchard()
		if not o then
			return "no orchard in this world"
		end
		if not o:IsUnlocked() then
			return "locked -- Unlock the orchard on the Orchard tab"
		end
		local owned, n = 0, { [0] = 0, 0, 0, 0 }
		for _, p in ipairs(myPlots()) do
			if p:GetAttribute("Enabled") == true then
				owned = owned + 1
				local st = p:GetAttribute("State") or 0
				n[st] = (n[st] or 0) + 1
			end
		end
		local stage, rolls, label, seed, isBroke = breedInfo()
		local buff = "no fruit buff"
		if EffectApplierCls then
			local ok, cur, left = pcall(function()
				local fx = o:GetComponent(EffectApplierCls)
				return fx:GetCurrentFruit(), fx:GetTimeLeft()
			end)
			if ok and cur then
				buff = ("eating x%.2f (%s) %ds left"):format(fruitScore(cur), label(cur), math.floor(tonumber(left) or 0))
			end
		end
		return table.concat({
			("plots %d   ready %d   fruiting %d   growing %d   empty %d"):format(owned, n[3], n[2], n[1], n[0]),
			buff,
			orchBreed and ("breed: %s%s   best seed %s x%.2f (eats x%.2f)   %d rolls"):format(
				stage,
				isBroke and ", broke" or "",
				breedBest and orchUI.key(breedBest) or "none",
				seed(breedBest),
				breedBest and fruitScore(breedBest) or 1,
				rolls
			) or "breed: off",
		}, "\n")
	end

	-- Each row is its own pcall, so one broken reader blanks one row, not the dashboard.
	local builders = {
		Money = function()
			local rate
			if income then
				local okR, v = pcall(function()
					return income:GetAverageStreamIncome()
				end)
				rate = okR and v or nil
			end
			return table.concat({
				("cash %s   income ~%s/s"):format(money(cash()), money(rate)),
				("investors %s   tokens %d"):format(plain(investors()), tokenCount()),
			}, "\n")
		end,
		Resets = function()
			local rb, target = rebirthProgress()
			local _, ev = evolveReady()
			local _, asc = ascendReady()
			return table.concat({
				("rebirth %s   +%s investors of %s needed%s"):format(
					pct(rb),
					plain(potentialInvestors()),
					plain(target),
					rb >= 1 and "   READY" or ""
				),
				("evolve %s   ascend %s"):format(pct(ev), pct(asc)),
				("rebirths %d   evolution %d   ascension %d"):format(
					rebirth and rebirth:GetRebirths() or 0,
					evolution and evolution:GetEvolution() or 0,
					ascension and ascension:GetAscension() or 0
				),
				("done this session: rebirth %d   evolve %d   ascend %d"):format(resets.rebirth, resets.evolve, resets.ascend),
			}, "\n")
		end,
		Tycoon = function()
			local ready, nextPrice, blocked = nextBuy()
			local next_ = ready or blocked
			local have = purchaseCount()
			local ft, fdone = forever.target()
			return table.concat({
				("purchases %d/%d (%s)"):format(have, TOTAL, pct(have / math.max(TOTAL, 1))),
				("next: %s   %s%s"):format(
					next_ and (next_.DisplayName or next_.Name) or "-",
					money(nextPrice),
					ready and "   affordable" or ""
				),
				("forever %d/%d   %d slot(s)   next: %s%s"):format(
					fdone,
					#forever.list(),
					forever.slots(),
					ft and (ft .. " (" .. (forever.tier and forever.tier[ft] or "?") .. ")") or "all done",
					forever.on and "" or "   (off)"
				),
			}, "\n")
		end,
		Orchard = orchardLine,
		Session = function()
			return table.concat({
				("bought %d   upgrades %d   wakes %d   powers %d   specials %d"):format(bought, upgraded, woke, poweredUp, specialed),
				("drops %d   lemons clicked %d   phone offers %d/%d taken"):format(dropCount, clicks, phoneTaken, phoneSeen),
			}, "\n")
		end,
		Running = function()
			local on = {}
			for _, row in ipairs({
				{ "buy", buyLoop },
				{ "upgrade", upLoop },
				{ "wake", wakeLoop },
				{ "powers", powerLoop },
				{ "specials", specialLoop },
				{ "resets", resetLoop },
				{ "click", clickLoop },
				{ "extras", extraLoop },
				{ "orchard", orchLoop },
			}) do
				if row[2].on then
					table.insert(on, row[1])
				end
			end
			return (#on > 0 and table.concat(on, ", ") or "nothing on") .. "\nat: " .. mark
		end,
	}

	return function()
		dashGen = dashGen + 1
		local mine = dashGen
		task.spawn(function()
			local nextBreed
			while dashGen == mine do
				for title, build in pairs(builders) do
					local ok, text = pcall(build)
					dashText[title] = ok and text or ("unreadable: " .. tostring(text))
				end
				-- the breeding panel reads stock and every plot, so every third tick is plenty
				nextBreed = (nextBreed or 0) - 1
				if nextBreed <= 0 then
					nextBreed = 3
					local ok, rows = pcall(orchUI.report)
					if ok then
						for title, text in pairs(rows) do
							dashText[title] = text
						end
					else
						dashText["Now"] = "unreadable: " .. tostring(rows)
					end
				end
				task.wait(DASH_GAP)
			end
		end)
	end
end)()

startDog()
startDash()
say(("ready -- %d/%d purchases, cash %s"):format(purchaseCount(), TOTAL, money(cash())))

-- close ------------------------------------------------------------------------
local function stopAll()
	buyLoop.set(false)
	upLoop.set(false)
	wakeLoop.set(false)
	powerLoop.set(false)
	specialLoop.set(false)
	resetLoop.set(false)
	clickLoop.set(false)
	extraLoop.set(false)
	orchLoop.set(false)
	dogGen = dogGen + 1
	dashGen = dashGen + 1
	setDrops(false)
	setPhone(false)
	afk.set(false) -- a stopped script must not rejoin you
	pcall(function()
		drain:Disconnect()
	end)
	pcall(function()
		orchUI.conn:Disconnect()
	end)
end

Window:OnDestroy(function()
	stopAll()
	getgenv().sellLemonsStop = nil
end)

getgenv().sellLemonsStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().sellLemonsStop = nil
end
