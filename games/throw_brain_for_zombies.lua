--[[ Throw Brain for Zombies -- perfect throws, bench training, equip best, sell, auto buy (75854363819554)

     THROW   : walks to just short of the launch strip and throws PERFECT, every time:
               Request("ThrowOpen") stamps the server's meter clock, 0.85s later Request("Throw", { Hit = 1,
               T = 0.85 }) lands on its peak (Perfect = true, Bonus 20). The server times the meter itself: a
               Throw sent sooner after ThrowOpen comes back not perfect (Bonus 2-10). One throw per ~6.5s
               (the flight; anything sooner is { ok = false, slow = true }), and a too-early try costs ~1.3s
               more, so the gap is learned: -0.02s per first-try throw, +0.25s per refusal. Throwing needs
               the character at the strip (refused from 95 studs, taken 2.5 studs short of it) and not on
               the bench. Standing ON the strip (|X| < 48, Z < -48.5) makes the game's own controller start a
               throw, so the script stands at Z = -46.
     TRAIN   : walks onto your bench; the game starts lifting by itself and sends Rep every 0.5s. Our own
               Rep loop on top: the server takes ~2.8 a second (measured 520K -> 730K XP/s on the Candy
               bench, +40%) and refuses the rest. Rep needs you lifting on the bench (refused from the strip).
               Leaving is the game's own client stopLift (getgc), which also sends BenchStop and unfreezes
               you. With THROW on too it alternates blocks: N throws, then T seconds on the bench.
     ZOMBIES : EquipBest (position-free) whenever a stored zombie beats the weakest placed one: income went
               $4.1T/s -> $157T/s on the first call. SELL (position-free, Sell(uid)) keeps the KEEP best
               stored zombies by income and sells the rest; eggs and anything good enough to place are kept.
     BUY     : BuyBench when the next bench is affordable (each tier doubles XP per rep). BuyBrain(tier)
               skips tiers (the server checks money only) and equips itself: the highest affordable brain.
               A brain ahead of your zone multiplies luck (Config.ZoneBrainLuck: 4.5x at +1, 20x at +2, up
               to 80x). BuyPen (Config.PenPrice(PenCap)) only out of money above half the next brain.
     LUCKY   : passes Lucky = true while you have LuckyThrows (100x luck). Not run live: you had none.

     Zones: Power = 18 + (Level - 1) * 5, distance = Config.Distance(Power), zone N+1 at Config.ReachPower[N * 3 + 1].
     Movement (zb moves 2026-11-27): hops undone at 20 studs (kept to 10), so every trip is a walk at the
     game's own 33 studs/s, ~3s between bench and strip.

     Probed and dead (do not re-probe):
       Throw off the strip / while lifting   ok=false (95 studs away; and with Lifting set)
       Throw right after ThrowOpen           accepted, not perfect (the server's clock decides the meter)
       Throw without ThrowOpen               accepted off-peak (uses the last stamp)
       Throw sooner than ~6.3s               { ok = false, slow = true }; 6.2s refused, 6.5s taken first try
       Rep off the bench / BenchStart away   ok=false
       Rep faster than ~0.35s                refused; the cap does not move with the x2 bubble
       x2 bubble (Event X2Offer -> X2Tap)    works, but it is 1s of x2 every ~10s: not wired. The 20x bubble is paid.
       ClaimGift                             needs the group joined ({ join = true }); ClaimFree is one-time (claimed)
     Not wired: Fuse (its UI is disabled in the game), Rush / Money Rain / Boss (admin events), trades,
     gamepasses and products (Lucky1, Boost20x, potions, packs), SetPowerUse (a lower throw power to stay in a
     zone with a bigger brain bonus: an idea, not probed).

     RightControl opens / closes the panel (so does the Zegion logo). Stop: getgenv().throwBrainStop() ]]

-- config ---------------------------------------------------------------------
local REPLY_WAIT = 6 -- an InvokeServer that has not answered in this long is given up on
local PEAK = 0.85 -- seconds from ThrowOpen to the meter's first peak (period 0.85 once you have 3+ throws)
local GAP_START = 6.6 -- first guess at the server's gap between throws; it learns from there
local GAP_MIN = 5.5
-- a refused try costs ~1.2s and the ready point creeps up with distance, so the gap rises fast and falls slowly
local GAP_DOWN = 0.01 -- a throw taken on its first try lowers the gap this much
local GAP_UP = 0.3 -- a refused first try raises it this much
local RETRY = 0.3 -- after a refused Throw, wait this long before the next ThrowOpen
local MAX_TRIES = 15 -- no throw accepted after this many tries: walk back to the spot and start over
local THROW_SPOT = Vector3.new(0, 0, -46) -- 2.5 studs short of the strip (Z < -48.5 starts the game's own throw)
local WALK_TOL = 3 -- studs: arrived
local WALK_TIMEOUT = 15
local REP_EVERY = 0.12 -- our Rep loop; the server keeps ~one in three at this pace
local LIFT_WAIT = 5 -- seconds on the bench for the game to start lifting before walking off and on again
local KEEP = 20 -- stored zombies kept by income (the rest is sold)
local SELL_GAP = 0.08 -- between Sell calls in one pass
local ZOMBIES_EVERY = 3
local SHOP_EVERY = 2
local SHOP_BACKOFF = 10 -- a purchase the server refused is not retried for this long
local PEN_RESERVE = 0.5 -- pen slots only from money above this share of the next brain's price
local WATCHDOG = 30

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().throwBrainStop then
	getgenv().throwBrainStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[throwbrain]", ...)
end

-- The strip is drained from a Heartbeat: a loop thread that writes to the window throws
-- "lacking capability Plugin" after its first task.wait.
local pending, lastSaid = nil, nil
local function say(msg)
	pending = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

local firsts = {}
local function first(name, ...) -- one console line the first time an unproven branch runs
	if not firsts[name] then
		firsts[name] = true
		log("first " .. name, ...)
	end
end

local marks = {}
local function step(loop, what)
	marks[loop] = { what, os.clock() }
end

-- game -----------------------------------------------------------------------
local TBZ = ReplicatedStorage:WaitForChild("TBZ", 15)
local Request = TBZ and TBZ:WaitForChild("Remotes", 10) and TBZ.Remotes:WaitForChild("Request", 10)
local okC, C = pcall(function()
	return require(TBZ:WaitForChild("Config"))
end)
if not Request or not okC or type(C) ~= "table" or type(C.ZombieIncome) ~= "function" then
	warn("[throwbrain] the game's remotes or Config did not load:", C)
	return
end

-- InvokeServer has no timeout; a handler that never answers would park the loop forever.
local function call(cmd, arg)
	local done, res = false, nil
	task.spawn(function()
		local okCall, r = pcall(Request.InvokeServer, Request, cmd, arg)
		res = okCall and r or nil
		done = true
	end)
	local dl = os.clock() + REPLY_WAIT
	while not done and os.clock() < dl do
		task.wait()
	end
	return type(res) == "table" and res or { ok = false, msg = done and "no reply" or "timed out" }
end

-- the game's own client functions, found once by name
local clientFn = {}
pcall(function()
	for _, f in ipairs(getgc(false)) do
		if type(f) == "function" and islclosure(f) then
			local okI, src, name = pcall(debug.info, f, "sn")
			if okI and type(src) == "string" and name == "stopLift" and src:find("TBZ_Client$") then
				clientFn.stopLift = f
			end
		end
	end
end)
if not clientFn.stopLift then
	warn("[throwbrain] the game's stopLift was not found: leaving the bench sends BenchStop only, the camera may stay put")
end

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function fmt(n)
	n = tonumber(n) or 0
	local i = 1
	while math.abs(n) >= 1000 and i < #SUFFIX do
		n /= 1000
		i += 1
	end
	return ("%.3g"):format(n) .. SUFFIX[i]
end
assert(fmt(25000) == "25K" and fmt(1.57e14) == "157T" and fmt(100) == "100", "fmt")

local function attr(name)
	return player:GetAttribute(name)
end
local function money()
	return tonumber(attr("Money")) or 0
end
local function humanoid()
	local ch = player.Character
	return ch and ch:FindFirstChildOfClass("Humanoid")
end
local function lifting()
	local ch = player.Character
	return ch ~= nil and ch:GetAttribute("Lifting") ~= nil
end

local function zoneOf(power)
	local okZ, z = pcall(function()
		return C.BiomeAt(C.Distance(power))
	end)
	return okZ and tonumber(z) or nil
end
local function nextZonePower(zone)
	return zone and C.ReachPower and C.ReachPower[zone * 3 + 1] or nil
end
-- self-check against the 2026-11-27 config; a balance patch only costs the status line, so warn, never stop
if zoneOf(2383) ~= 8 or zoneOf(2700) ~= 9 then
	warn("[throwbrain] Config.Distance / BiomeAt changed: the Zone and Power columns may be off")
end

local function incomeOf(z)
	local okI, v = pcall(C.ZombieIncome, z)
	return okI and tonumber(v) or 0
end

local stats = { throws = 0, refused = 0, gapSum = 0, gapN = 0, sold = 0, soldFor = 0, equips = 0, bought = 0, reps = 0 }
local best = { income = 0, text = "-" }

-- movement -------------------------------------------------------------------
local function benchPos()
	local okP, p = pcall(function()
		return C.PlotOrigin(attr("Plot")) + C.Layout.Bench
	end)
	return okP and p or nil
end

-- The client's bench pin (a RenderStep PivotTo within 12 studs of the bench) can outlive the server's Lifting
-- attribute, so near the bench the game's stopLift is called whether or not Lifting is set; it is harmless idle.
local function leaveBench()
	local h = humanoid()
	local b = benchPos()
	local near = h and h.RootPart and b and Vector3.new(h.RootPart.Position.X - b.X, 0, h.RootPart.Position.Z - b.Z).Magnitude < 14
	if not lifting() and not near then
		return
	end
	if clientFn.stopLift then
		pcall(clientFn.stopLift)
	else
		call("BenchStop")
	end
	local w = os.clock()
	while lifting() and os.clock() - w < 2 do
		task.wait(0.05)
	end
end

-- hops are undone past 10 studs here, so every trip is the game's own walk
local function walkTo(pos, alive)
	local h = humanoid()
	local r = h and h.RootPart
	if not r then
		return false
	end
	local tgt = Vector3.new(pos.X, r.Position.Y, pos.Z)
	local t0 = os.clock()
	local lastPos, stillSince = r.Position, os.clock()
	while alive() and os.clock() - t0 < WALK_TIMEOUT do
		h = humanoid()
		r = h and h.RootPart
		if not r then
			return false
		end
		local flat = Vector3.new(r.Position.X - tgt.X, 0, r.Position.Z - tgt.Z)
		if flat.Magnitude < WALK_TOL then
			return true
		end
		if (r.Position - lastPos).Magnitude > 0.5 then
			lastPos, stillSince = r.Position, os.clock()
		elseif os.clock() - stillSince > 1.5 then
			-- frozen (WalkSpeed 0) or pinned by the bench: the game's own stopLift releases both
			first("walk held", ("WalkSpeed %s: calling the game's stopLift"):format(tostring(h.WalkSpeed)))
			if clientFn.stopLift then
				pcall(clientFn.stopLift)
			end
			stillSince = os.clock()
		end
		h:MoveTo(tgt)
		task.wait(0.25)
	end
	return false
end

-- throw ----------------------------------------------------------------------
local gap = GAP_START
local lastThrow = -1e9
local useLucky = false

local function throwOnce(alive)
	leaveBench()
	step("farm", "to strip")
	if not walkTo(THROW_SPOT, alive) then
		if alive() then
			say("strip: the walk did not arrive")
		end
		task.wait(1)
		return false
	end
	local readyAt = lastThrow + gap
	local r, tries, firstTry = nil, 0, true
	while alive() and not r and tries < MAX_TRIES do
		step("farm", "throw wait")
		local openAt = readyAt - PEAK
		while alive() and os.clock() < openAt do
			task.wait()
		end
		if not alive() then
			return false
		end
		step("farm", "throw")
		local opened = os.clock()
		call("ThrowOpen")
		tries += 1
		while os.clock() < opened + PEAK do
			task.wait()
		end
		local lucky = useLucky and (tonumber(attr("LuckyThrows")) or 0) > 0 or nil
		if lucky then
			first("lucky throw", "LuckyThrows " .. tostring(attr("LuckyThrows")))
		end
		local sent = os.clock()
		local res = call("Throw", { Hit = 1, T = PEAK, Lucky = lucky })
		if res.ok then
			r = res
			local g = sent - lastThrow
			if firstTry then
				gap = math.max(GAP_MIN, gap - GAP_DOWN)
			end
			if lastThrow > 0 and g < gap + 6 then -- back-to-back only, not across a training block
				stats.gapSum += g
				stats.gapN += 1
			end
			lastThrow = sent
		elseif res.slow then
			if firstTry and lastThrow > 0 then
				gap += GAP_UP
			end
			firstTry = false
			readyAt = os.clock() + RETRY + PEAK
		else
			stats.refused += 1
			say("throw refused: " .. tostring(res.msg or "no reason (off the strip? bag full?)"))
			task.wait(2)
			return false
		end
	end
	if not r then
		if alive() then
			say(("no throw accepted in %d tries"):format(MAX_TRIES))
		end
		return false
	end
	if not r.Perfect then
		first("not perfect", ("try %d"):format(tries))
	end
	stats.throws += 1
	local okN, name = pcall(C.CatchName, r.Zombie, r.Kg, r.Mut)
	name = okN and tostring(name) or tostring(r.Zombie)
	if (tonumber(r.Income) or 0) > best.income then
		best.income, best.text = tonumber(r.Income), ("%s %s/s"):format(name, fmt(r.Income))
	end
	say(
		("throw %d (try %d, gap %.2fs): %s%s %s/s, zone %s, %s studs"):format(
			stats.throws,
			tries,
			gap,
			r.Perfect and "" or "(not perfect) ",
			name,
			fmt(r.Income),
			tostring(r.Biome),
			fmt(r.Dist)
		)
	)
	return true
end

-- train ----------------------------------------------------------------------
local function toBench(alive)
	if lifting() then
		return true
	end
	local pos = benchPos()
	if not pos then
		say("train: no plot / bench position")
		return false
	end
	for attempt = 1, 2 do
		step("farm", "to bench")
		if not walkTo(pos, alive) then
			return false
		end
		local w = os.clock()
		while alive() and not lifting() and os.clock() - w < LIFT_WAIT do
			task.wait(0.1)
		end
		if lifting() then
			return true
		end
		-- the game's pad trigger re-arms only after you leave it: step off and back on
		if attempt == 1 then
			first("bench re-arm", "lifting did not start: stepping off the bench")
			walkTo(pos + Vector3.new(0, 0, 12), alive)
		end
	end
	return false
end

local function trainFor(secs, alive)
	if not toBench(alive) then
		if alive() then
			say("train: the bench did not start lifting")
		end
		task.wait(2)
		return
	end
	local l0 = tonumber(attr("Level")) or 0
	say(("training%s (level %d)"):format(secs and (" " .. secs .. "s") or "", l0))
	local dl = secs and os.clock() + secs
	while alive() and (not dl or os.clock() < dl) do
		step("farm", "training")
		if not lifting() then
			if not toBench(alive) then
				break
			end
		end
		if call("Rep").ok then
			stats.reps += 1
		end
		task.wait(REP_EVERY)
	end
	if secs then
		leaveBench()
		say(("trained %ds: level %d -> %d"):format(secs, l0, tonumber(attr("Level")) or 0))
	end
end

-- zombies --------------------------------------------------------------------
local zWant = { equip = false, sell = false }
local equipNoop = nil -- signature at which EquipBest last changed nothing

local function zombiesPass()
	local st = call("GetState")
	if not st.ok or type(st.Zombies) ~= "table" then
		return
	end
	local placed, stored, weakest = 0, {}, math.huge
	for _, z in pairs(st.Zombies) do
		if z.Placed then
			placed += 1
			weakest = math.min(weakest, incomeOf(z))
		elseif not z.Egg then
			stored[#stored + 1] = z
		end
	end
	table.sort(stored, function(a, b)
		return incomeOf(a) > incomeOf(b)
	end)
	local cap = tonumber(attr("PenCap")) or 0
	if zWant.equip and #stored > 0 then
		local top = incomeOf(stored[1])
		local sig = #stored .. "|" .. placed .. "|" .. cap .. "|" .. top
		if (placed < cap or top > weakest) and sig ~= equipNoop then
			local before = tonumber(attr("Income")) or 0
			local r = call("EquipBest")
			if r.ok then
				stats.equips += 1
				task.wait(0.5)
				local after = tonumber(attr("Income")) or 0
				local changed = math.abs(after - before) > math.max(before, 1) * 0.001
				equipNoop = not changed and sig or nil
				if changed then
					say(("equip best: %s/s -> %s/s"):format(fmt(before), fmt(after)))
				end
				return -- the pen changed: the next pass re-reads it before selling
			end
		end
	end
	if zWant.sell then
		for i = KEEP + 1, #stored do
			local z = stored[i]
			-- anything good enough for the pen waits for Equip Best instead of being sold
			if placed >= cap and incomeOf(z) <= weakest then
				local m0 = money()
				local r = call("Sell", z.Uid)
				if r.ok then
					stats.sold += 1
					stats.soldFor += math.max(0, money() - m0)
				else
					first("sell refused", tostring(r.msg))
					break
				end
				task.wait(SELL_GAP)
			end
		end
	end
end

-- loops ----------------------------------------------------------------------
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
		local function alive()
			return L.on and L.gen == mine
		end
		task.spawn(function()
			while alive() do
				step(name, "pass")
				local okPass, err = pcall(pass, alive)
				if not okPass then
					warn("[throwbrain]", name, "pass threw:", err)
					task.wait(1)
				end
				task.wait(every)
			end
		end)
	end
	loops[name] = L
	return L
end

-- the farm owns the character: throwing and training
local farmWant = { throw = false, train = false }
local throwsPerCycle, trainSecs = 10, 60
local cycleThrows = 0
local farm = makeLoop("farm", 0, function(alive)
	if farmWant.throw and (not farmWant.train or cycleThrows < throwsPerCycle) then
		if throwOnce(alive) then
			cycleThrows += 1
		end
	elseif farmWant.train then
		trainFor(farmWant.throw and trainSecs or nil, alive)
		cycleThrows = 0
	else
		task.wait(0.5)
	end
end)

local function setFarm()
	local on = farmWant.throw or farmWant.train
	if on ~= farm.on then
		farm.set(on)
	end
	if not on then
		task.spawn(leaveBench)
		say("idle")
	end
end

local zombies = makeLoop("zombies", ZOMBIES_EVERY, zombiesPass)
local function setZombies()
	local any = zWant.equip or zWant.sell
	if any ~= zombies.on then
		zombies.set(any)
	end
end

-- shop -----------------------------------------------------------------------
local shopWant = { bench = false, brain = false, pen = false }
local backoff = {}
local ownedBrains, ownedAt = {}, -1e9

-- returns the tier to buy (highest affordable above every owned one), the next brain up, and the best owned tier.
-- Fails closed: an unread owned list buys nothing (an empty one once bought tier 22 over an owned 23, and a buy equips).
local function bestBrain(cash)
	if os.clock() - ownedAt > 30 then
		local st = call("GetState")
		if st.ok and type(st.Brains) == "table" then
			table.clear(ownedBrains)
			for k in pairs(st.Brains) do -- keys are strings: { ["23"] = true }
				local t = tonumber(k)
				if t then
					ownedBrains[t] = true
				end
			end
			ownedAt = os.clock()
		else
			first("GetState failed", tostring(st.msg))
		end
	end
	if next(ownedBrains) == nil then
		return nil, nil, nil
	end
	local top = 0
	for t in pairs(ownedBrains) do
		top = math.max(top, t)
	end
	local floor = math.max(top, tonumber(attr("Equipped")) or 0)
	local buy, nextUp = nil, nil
	for t, b in ipairs(C.Brains) do
		if t > floor then
			if b.Price <= cash then
				buy = t
			elseif not nextUp then
				nextUp = b
			end
		end
	end
	return buy, nextUp, top
end

local function tryBuy(key, cmd, arg, what)
	if os.clock() < (backoff[key] or 0) then
		return false
	end
	local m0 = money()
	local r = call(cmd, arg)
	if r.ok then
		stats.bought += 1
		ownedAt = -1e9
		say(("bought %s for %s"):format(what, fmt(m0 - money())))
		return true
	end
	backoff[key] = os.clock() + SHOP_BACKOFF
	first(key .. " refused", tostring(r.msg))
	return false
end

local shop = makeLoop("shop", SHOP_EVERY, function()
	local cash = money()
	local nb = C.Benches[(tonumber(attr("Bench")) or 0) + 1]
	if shopWant.bench and nb and nb.Price <= cash then
		tryBuy("bench", "BuyBench", nil, nb.Name)
		return -- one purchase a pass; the next pass re-reads cash
	end
	local buy, nextUp, top = bestBrain(cash)
	if shopWant.brain and buy then
		tryBuy("brain", "BuyBrain", buy, C.Brains[buy].Name)
		return
	end
	if shopWant.brain and top and (tonumber(attr("Equipped")) or 0) < top and os.clock() >= (backoff.equip or 0) then
		local r = call("Equip", top) -- the brain shop's own call for an owned brain
		if r.ok then
			say("equipped " .. tostring(C.Brains[top] and C.Brains[top].Name or top))
		else
			backoff.equip = os.clock() + SHOP_BACKOFF
			first("equip brain refused", tostring(r.msg))
		end
	end
	local cap = tonumber(attr("PenCap")) or 0
	if shopWant.pen and cap < (C.PenMax or 24) then
		local okP, cost = pcall(C.PenPrice, cap)
		local reserve = (shopWant.brain and nextUp) and nextUp.Price * PEN_RESERVE or 0
		if okP and cost and cash - cost >= reserve then
			tryBuy("pen", "BuyPen", nil, ("pen slots (cap %d)"):format(cap))
		end
	end
end)
local function setShop()
	local any = shopWant.bench or shopWant.brain or shopWant.pen
	if any ~= shop.on then
		shop.set(any)
	end
end

-- watchdog -------------------------------------------------------------------
local watching = true
task.spawn(function()
	while watching do
		task.wait(5)
		for name, m in pairs(marks) do
			if loops[name] and loops[name].on and m[1] ~= "training" and os.clock() - m[2] > WATCHDOG then
				warn(("[throwbrain] %s stuck %ds at: %s"):format(name, os.clock() - m[2], m[1]))
				m[2] = os.clock()
			end
		end
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Throw Brain for Zombies", statusBar = true })
if not Window then
	watching = false
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "brain")
local Farm = Tab:AddLeftGroupbox("Throw and train", "target")
local Zombies = Tab:AddLeftGroupbox("Zombies", "skull")
local Shop = Tab:AddRightGroupbox("Shop", "shopping-cart")

local function guarded(fn)
	return function(state)
		local okCb, err = pcall(fn, state)
		if not okCb then
			warn("[throwbrain] toggle failed:", err)
		end
	end
end

Farm:AddToggle("Throw", {
	Text = "Auto Throw (perfect)",
	Tooltip = "Walks to the launch strip and throws on the meter's peak: PERFECT every throw, one every ~6.5s (the server's flight gap)",
	Default = false,
	Callback = guarded(function(state)
		farmWant.throw = state
		setFarm()
	end),
})
Farm:AddToggle("Train", {
	Text = "Auto Train (bench)",
	Tooltip = "Lifts on your bench with extra reps (+40% XP). With Auto Throw on too it alternates: the throws below, then the seconds below",
	Default = false,
	Callback = guarded(function(state)
		farmWant.train = state
		setFarm()
	end),
})
Farm:AddInput("ThrowsPerCycle", {
	Text = "Throws, then train",
	Default = tostring(throwsPerCycle),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		throwsPerCycle = math.max(1, math.floor(tonumber(text) or throwsPerCycle))
	end,
})
Farm:AddInput("TrainSecs", {
	Text = "Seconds of training",
	Default = tostring(trainSecs),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		trainSecs = math.max(10, math.floor(tonumber(text) or trainSecs))
	end,
})
Farm:AddToggle("Lucky", {
	Text = "Use Lucky throws",
	Tooltip = "Spends your LuckyThrows (100x luck) on the next throws while you have any",
	Default = false,
	Callback = function(state)
		useLucky = state
	end,
})

Zombies:AddToggle("Equip", {
	Text = "Auto Equip Best",
	Tooltip = "The game's Equip Best, from anywhere, whenever a stored zombie beats your weakest placed one or the pen has room",
	Default = false,
	Callback = guarded(function(state)
		zWant.equip = state
		setZombies()
	end),
})
Zombies:AddToggle("Sell", {
	Text = "Auto Sell (keep best stored)",
	Tooltip = "Sells stored zombies past the best ones below, from anywhere. Never sells placed zombies, eggs, or anything good enough for the pen",
	Default = false,
	Callback = guarded(function(state)
		zWant.sell = state
		setZombies()
	end),
})
Zombies:AddInput("Keep", {
	Text = "Stored zombies to keep",
	Default = tostring(KEEP),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		KEEP = math.max(0, math.floor(tonumber(text) or KEEP))
	end,
})

local function shopToggle(idx, key, text, tip)
	Shop:AddToggle(idx, {
		Text = text,
		Tooltip = tip,
		Default = false,
		Callback = guarded(function(state)
			shopWant[key] = state
			setShop()
		end),
	})
end
shopToggle("Bench", "bench", "Auto buy benches", "The next bench as soon as you can afford it: each tier doubles XP per rep")
shopToggle("Brain", "brain", "Auto buy best brain", "The highest brain tier you can afford (tiers can be skipped); it equips itself")
shopToggle("Pen", "pen", "Auto buy pen slots", "BuyPen, only out of money above half the next brain's price (up to 24 slots)")

local conns = {}
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
		local power = tonumber(attr("Power")) or 0
		local zone = zoneOf(power)
		local nz = nextZonePower(zone)
		local brain = C.Brains[tonumber(attr("Equipped")) or 0]
		local bench = C.Benches[tonumber(attr("Bench")) or 0]
		pcall(Window.SetStatus, Window, {
			{ "Cash", fmt(money()) .. " (" .. fmt(attr("Income")) .. "/s)" },
			{ "Level", tostring(attr("Level")) },
			{ "Power", tostring(power) .. (nz and (" / " .. nz) or "") },
			{ "Zone", tostring(zone or "-") },
			{ "Brain", brain and brain.Name or "-" },
			{ "Bench", bench and bench.Name or "-" },
			{ "Throws", stats.throws .. (stats.gapN > 0 and (" (%.1fs each)"):format(stats.gapSum / stats.gapN) or "") },
			{ "Best", best.text },
			{ "Sold", stats.sold .. " (" .. fmt(stats.soldFor) .. ")" },
			{ "Now", note },
		})
	end)
)

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("ThrowBrainZombies", {})

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
	farmWant.throw, farmWant.train = false, false
	zWant.equip, zWant.sell = false, false
	shopWant.bench, shopWant.brain, shopWant.pen = false, false, false
	for _, L in pairs(loops) do
		L.set(false)
	end
	task.spawn(function()
		task.wait(0.3) -- let a Rep in flight land first
		pcall(leaveBench)
	end)
	watching = false
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().throwBrainStop = nil
end)

getgenv().throwBrainStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().throwBrainStop = nil
end
