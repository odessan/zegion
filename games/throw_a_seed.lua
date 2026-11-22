--[[ Throw a Seed -- perfect throws, training, place best, sell, bars, garden, free stuff (129081220403721)

     THROW   : glides onto the launch strip and throws at the meter's exact peak, every time: PERFECT.
               Aim -> 0.75s -> Here -> Throw:InvokeServer(1). The server times the meter from its own Aim
               (0.5 - cos(t / 1.5 * 2pi) / 2, peak at 0.75s), ignores a second Aim while one is open, and
               clamps the meter at 1, so distance (and the zone, and the seed) only grows with Strength.
               One throw per flight: the server answers nil to anything sooner and says nothing when it
               ends. 6-7s at 290 studs, 7-8s at 1.7K, and at ~6K two modes: ~7.5s on about a third of
               throws, ~9.7s on the rest. The server takes an Aim even mid-flight and keeps it open (a
               refused Throw does not close it) and meters from it, so: one Aim, then a Throw on each
               meter peak (every 1.5s) from +8.3s; the first peak after the flight is accepted and
               perfect. Overlapping Aim/Throw pairs were accepted too, but off-peak: never perfect, zone 13
               instead of 15. No paid skip exists. A Throw works without a Collect first; one Collect
               banks every open seed (proven 68 -> 70 plants).
               Collect(true) banks the seed and re-arms; Collect() banks it and sends you home.
               Between throws it parks just off the strip, because the game's own throw controller
               starts a throw (anchors you, shows the meter) whenever you stand on it; its abort() is
               called around every throw so the meter never sticks on screen.
     TRAIN   : the pull-up bar on your plot (its TrainPrompt; the server listens to the prompt, no remote).
               Pays in batches, ~+193 every 7s on the Iron Bar, and the first batch takes longer than a
               throw cooldown, so with THROW on as well it alternates blocks: N throws, then T seconds.
               A throw is refused while training, a prompt is refused mid-throw: StopTrain / Collect()
               first, always.
               The x2 bubble: the server sends Notify("XPOffer", { id, ttl = 3 }) about every 4s while you
               train; Request("XPBoost", { id }) claims it (the game's own button refuses under 0.15s).
               Measured over 35s each: +1.10B Strength unclaimed, +1.86B claimed (~1.7x).
     PLANTS  : Place Best and Sell Stored are the game's own buttons, from anywhere. Sell Stored never
               sells a placed plant, and the server itself keeps rare, mutated and pack plants.
     SHOP    : BuyBar (more Strength per rep) first; BuyCapacity only out of what the next bar leaves.
     FREE    : ClaimDaily when DailyReady, every playtime gift as it comes due, CollectOffline on start.

     Movement (zb moves 2026-11-23): hops kept to 40 studs (80 undone), glide held to 3000 studs/s.
     The strip is ~55 studs from the plot: one teleport, glide as the fallback.

     Probed and dead (do not re-probe):
       Throw from off the strip            nil (the server checks you stand on Map.Canyon.LaunchStrip)
       meter 3 instead of 1                clamped to 1 (distance unchanged)
       Throw sooner than the flight        nil at 2-6s, accepted at 7s (290 studs); 7s nil, 8s ok (1.7K)
       Aim again without Collect           nil at 3s and 5s
       Collect() (go home) early, then Aim nil at 4s -> 6s, accepted at 7.6s: the same floor
       a softer throw for a shorter flight zone 15 needs meter >= 0.94 (~6% shorter), and loses distance luck
       a landing signal                    none: 12s of attributes and Notify after a throw, only ThrowT0/Throws
       Throw while training                nil
       a short train window per cooldown   pays nothing: the first rep batch lands after ~7s+
       SetSkipCine                         client-only cinematic, no effect on the server's gap
       synthetic tap / InputBegan call     the game's input never sees it; executor hooks do not see the
                                           game's own remote calls either (irrelevant once replayed)
     Not wired: fuse (removed on request; Request("Fuse", { ids = {a, b, c} }), never run live),
     rebirth (only RebirthCost is in the client, no call; unlocks at zone 10), codes (none in the
     client), Robux passes and products (LuckyThrow, TrainingBoost, packs), Harvest / Big Tom events.

     RightControl opens / closes the panel (so does the Zegion logo). Stop: getgenv().throwSeedStop() ]]

-- config ---------------------------------------------------------------------
local REPLY_WAIT = 6 -- an InvokeServer that has not answered in this long is given up on
local TP_SETTLE = 0.15 -- after a teleport, wait this long before judging it (x the try number)
local TP_TRIES = 3 -- straight teleports before falling back to a glide
local TP_TOL = 6 -- studs: arrived
local GLIDE_SPEED = 600 -- studs/s for the fallback glide (3000 held in zb moves); lower it if glides get pulled back
local PEAK = 0.75 -- seconds from Aim to the meter's peak (period 1.5s)
-- The server takes an Aim even mid-flight and keeps that one open (a second is ignored); only the Throw waits for
-- the flight, and it meters from the open Aim. The meter peaks every METER_PERIOD, so one Aim and a Throw on each
-- peak: the first peak after the flight is accepted AND perfect. The flight has two modes at ~6K studs (~7.5s on
-- about a third of throws, ~9.7s on the rest), so the peaks sit at FIRST_PEAK and FIRST_PEAK + 1.5 to catch both.
local FIRST_PEAK = 8.3 -- seconds after the last accepted Throw; the peaks after it follow every METER_PERIOD
local METER_PERIOD = 1.5
local MAX_PEAKS = 8 -- no throw accepted after this many peaks: Collect() and start over
local TRAIN_STOP_WAIT = 1.5 -- after StopTrain, wait this long for Training to clear
local PROMPT_TRIES = 6 -- TrainPrompt presses before giving up on this block
local XP_CLAIM_DELAY = 0.3 -- after an x2 offer shows, claim it this much later (ttl is 3s; under 0.15 the game refuses its own tap)
local PLANTS_EVERY = 2 -- seconds between plant passes (place / sell)
local SHOP_EVERY = 1.5
local SHOP_BACKOFF = 10 -- a purchase the server refused is not retried for this long
local BAR_RESERVE = 0.5 -- garden slots only from money above this share of the next bar's price
local CLAIM_EVERY = 10
local WATCHDOG = 30 -- a loop that has not moved its breadcrumb in this long is reported

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().throwSeedStop then
	getgenv().throwSeedStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[throwseed]", ...)
end

-- The strip is drained from a Heartbeat: a loop thread that writes to the window throws
-- "lacking capability Plugin" after its first task.wait.
local pending, lastSaid = nil, nil
local function say(msg, quiet)
	pending = msg
	if not quiet and msg ~= lastSaid then
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
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
local okMods, B, S = pcall(function()
	return require(ReplicatedStorage.Balance), require(player:WaitForChild("PlayerScripts"):WaitForChild("ClientState", 15))
end)
if not Remotes or not okMods or type(S) ~= "table" or type(S.Request) ~= "function" then
	warn("[throwseed] the game's modules did not load:", B)
	return
end
local R = setmetatable({}, {
	__index = function(t, name)
		local r = Remotes:WaitForChild(name, 10)
		rawset(t, name, r)
		return r
	end,
})

-- InvokeServer has no timeout; a handler that never answers would park the loop forever.
local function invoke(remote, timeout, ...)
	local args = table.pack(...)
	local done, res = false, nil
	task.spawn(function()
		local okCall, r = pcall(remote.InvokeServer, remote, table.unpack(args, 1, args.n))
		res = okCall and r or nil
		done = true
	end)
	local dl = os.clock() + (timeout or REPLY_WAIT)
	while not done and os.clock() < dl do
		task.wait()
	end
	return res
end

-- The game's own Request (Remotes.Request "Cmd", args) with the same timeout; returns ok, message.
local function request(cmd, args)
	local done, ok, msg = false, false, nil
	task.spawn(function()
		local okCall, a, b = pcall(S.Request, cmd, args)
		ok, msg = okCall and a or false, okCall and b or a
		done = true
	end)
	local dl = os.clock() + REPLY_WAIT
	while not done and os.clock() < dl do
		task.wait()
	end
	return ok, done and msg or "no answer"
end

local function meter(t)
	return 0.5 - math.cos(t / METER_PERIOD * math.pi * 2) * 0.5
end
assert(meter(PEAK) > 0.999 and meter(PEAK + METER_PERIOD * 2) > 0.999 and meter(PEAK - 0.3) < 0.7, "meter peaks")

-- The game's throw controller, found once: abort() is client-only (hides the meter, unanchors, resets the
-- camera, idles the controller with a 1.5s grace before it would start another throw on the strip).
local gameAbort
pcall(function()
	for _, f in ipairs(getgc(false)) do
		if type(f) == "function" and islclosure(f) then
			local okI, src, name = pcall(debug.info, f, "sn")
			if okI and name == "abort" and type(src) == "string" and src:find("ThrowClient") then
				gameAbort = f
				break
			end
		end
	end
end)
if not gameAbort then
	warn("[throwseed] the game's throw abort() was not found: the meter may stay on screen (a respawn clears it)")
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
assert(fmt(25000) == "25K" and fmt(1.19e9) == "1.19B" and fmt(100) == "100", "fmt")

local function attr(name)
	return player:GetAttribute(name)
end
local function money()
	return tonumber(attr("Money")) or 0
end
local function root()
	local ch = player.Character
	return ch and ch:FindFirstChild("HumanoidRootPart")
end
local function training()
	local ch = player.Character
	return ch ~= nil and ch:GetAttribute("Training") == true
end

local function freeClient()
	if gameAbort then
		pcall(gameAbort)
	end
	local r = root()
	if r then
		r.Anchored = false
	end
end

-- world-fixed spots, read once (re-read when a part goes missing)
local spots = {}
local function spot(name)
	if spots[name] then
		return spots[name]
	end
	local p
	if name == "strip" or name == "park" then
		local s = workspace.Map.Canyon.LaunchStrip
		-- park: just past the strip's home-side edge, where the game's controller does not start a throw
		p = s.Position + Vector3.new(0, 3, name == "park" and (s.Size.Z / 2 + 6) or 0)
	else
		local plot = workspace.Map.Plots:FindFirstChild(tostring(attr("Plot")))
		local ts = plot and plot:FindFirstChild("BarStation") and plot.BarStation:FindFirstChild("TrainSpot", true)
		p = ts and ((ts:IsA("Attachment") and ts.WorldPosition or ts.Position) + Vector3.new(0, 1, 0))
	end
	spots[name] = p
	return p
end
local function trainPrompt()
	local plot = workspace.Map.Plots:FindFirstChild(tostring(attr("Plot")))
	return plot and plot:FindFirstChild("TrainPrompt", true)
end

local stats = { throws = 0, refused = 0, gapSum = 0, gapN = 0, sold = 0, soldFor = 0, placed = 0, bought = 0, gifts = 0, boosts = 0 }
local best = { income = 0, text = "-" }

-- movement -------------------------------------------------------------------
local function glide(pos)
	local r = root()
	if not r then
		return false
	end
	local from = r.Position
	local dur = (pos - from).Magnitude / GLIDE_SPEED
	local t0 = os.clock()
	while true do
		local a = math.min((os.clock() - t0) / math.max(dur, 0.01), 1)
		r = root()
		if not r then
			return false
		end
		r.AssemblyLinearVelocity = Vector3.zero
		r.CFrame = CFrame.new(from:Lerp(pos, a))
		if a >= 1 then
			break
		end
		RunService.Heartbeat:Wait()
	end
	task.wait(TP_SETTLE)
	r = root()
	return r ~= nil and (r.Position - pos).Magnitude < TP_TOL
end

local function tp(pos)
	if not pos then
		return false
	end
	for i = 1, TP_TRIES do
		local r = root()
		if not r then
			return false
		end
		if (r.Position - pos).Magnitude < TP_TOL then
			return true
		end
		r.Anchored = false
		r.AssemblyLinearVelocity = Vector3.zero
		r.CFrame = CFrame.new(pos)
		task.wait(TP_SETTLE * i)
		r = root()
		if r and (r.Position - pos).Magnitude < TP_TOL then
			return true
		end
	end
	first("glide fallback", "a straight teleport was undone 3 times")
	return glide(pos)
end

-- throw ----------------------------------------------------------------------
local lastThrow = -1e9

local function stopTraining()
	if not training() then
		return
	end
	request("StopTrain")
	local w = os.clock()
	while training() and os.clock() - w < TRAIN_STOP_WAIT do
		task.wait(0.05)
	end
end

local function throwOnce(alive)
	stopTraining()
	local wait = lastThrow + FIRST_PEAK - PEAK - os.clock()
	if wait > 0 then
		step("farm", "cooldown")
		if not tp(spot("park")) then
			say("park: the teleport did not hold")
		end
		local dl = os.clock() + wait
		while alive() and os.clock() < dl do
			task.wait(0.1)
		end
		if not alive() then
			return false
		end
	end
	step("farm", "to strip")
	freeClient() -- 1.5s grace: the game's controller does not start its own throw under ours
	if not tp(spot("strip")) then
		say("strip: the teleport did not hold")
		task.wait(1)
		return false
	end
	-- An Aim sent mid-flight is ignored, so one goes out every METER_PERIOD: whichever the server keeps, the
	-- peaks fall on the same instants, and a Throw goes out on each until one is accepted.
	step("farm", "throw")
	local aimAt = os.clock()
	local r, wonAt, peaks = nil, nil, 0
	local function untilT(t)
		while os.clock() < t do
			task.wait()
		end
	end
	while alive() and not r and peaks < MAX_PEAKS do
		untilT(aimAt + METER_PERIOD * peaks)
		freeClient() -- 1.5s grace: the game's controller does not start its own throw under ours
		R.Aim:FireServer()
		local at = aimAt + PEAK + METER_PERIOD * peaks
		peaks += 1
		untilT(at)
		R.Here:FireServer()
		local res = invoke(R.Throw, REPLY_WAIT, 1)
		if type(res) == "table" then
			r, wonAt = res, at
		end
	end
	freeClient()
	if not r then
		if alive() then
			stats.refused += 1
			say(("no throw accepted on %d peaks: Collect() and start over"):format(MAX_PEAKS))
		end
		R.Collect:FireServer()
		task.wait(1.5)
		return false
	end
	if not r.perfect then
		first("not perfect", ("meter %s on peak %d"):format(tostring(r.meter), peaks))
	end
	R.Collect:FireServer(true) -- banks it now (Place Best and Sell see it), stays armed; proven harmless mid-flight
	if lastThrow > 0 and wonAt - lastThrow < FIRST_PEAK + METER_PERIOD * 3 then -- back-to-back only, not across training
		stats.gapSum += wonAt - lastThrow
		stats.gapN += 1
	end
	lastThrow = wonAt
	stats.throws += 1
	if (r.income or 0) > best.income then
		best.income, best.text = r.income, ("%s %s/s"):format(tostring(r.plant), fmt(r.income))
	end
	say(
		("throw %d: %s%s%s %s/s, zone %s, %s studs"):format(
			stats.throws,
			r.perfect and "" or "(not perfect) ",
			(r.mutation or 1) ~= 1 and ("mut " .. tostring(r.mutation) .. " ") or "",
			tostring(r.plant),
			fmt(r.income),
			tostring(r.zone),
			fmt(r.distance)
		)
	)
	tp(spot("park"))
	return true
end

-- train ----------------------------------------------------------------------
local function startTraining()
	local prompt = trainPrompt()
	if not prompt then
		say("train: no TrainPrompt on your plot")
		return false
	end
	for _ = 1, PROMPT_TRIES do
		fireproximityprompt(prompt)
		local w = os.clock()
		while not training() and os.clock() - w < 0.6 do
			task.wait(0.05)
		end
		if training() then
			return true
		end
	end
	return false
end

-- secs = nil: train until the farm stops or wants to throw again
local function trainFor(secs, alive)
	if training() then
		step("farm", "training")
	else
		if lastThrow > 0 then
			-- Collect() leaves throw mode (the prompt is refused in it) and sends you home; let that land first
			R.Collect:FireServer()
			task.wait(0.4)
		end
		freeClient()
		step("farm", "to bar")
		if not tp(spot("bar")) then
			say("bar: the teleport did not hold")
			task.wait(1)
			return
		end
		step("farm", "prompt")
		if not startTraining() then
			say("train: the prompt did not start a session")
			task.wait(2)
			return
		end
	end
	local s0 = tonumber(attr("Strength")) or 0
	say(("training%s (Strength %s)"):format(secs and (" " .. secs .. "s") or "", fmt(s0)))
	local dl = secs and os.clock() + secs
	while alive() and (not dl or os.clock() < dl) do
		step("farm", "training")
		if not training() then
			freeClient()
			tp(spot("bar"))
			startTraining()
		end
		task.wait(0.5)
	end
	if secs then
		stopTraining()
		say(("trained %ds: +%s Strength"):format(secs, fmt((tonumber(attr("Strength")) or 0) - s0)))
	end
end

-- plants ---------------------------------------------------------------------
local function incomeOf(p)
	local okI, v = pcall(B.Income, tonumber(p.rarity) or 1, p.size, p.mutation, 1, p.plant)
	return okI and tonumber(v) or tonumber(p.income) or 0
end

local function isFodder(p) -- what Sell Stored would sell anyway
	if p.placed or (tonumber(p.rarity) or 99) > (B.AutoSellMaxTier or 9) or (p.mutation or 1) ~= 1 then
		return false
	end
	if type(B.PackPlant) == "table" and B.PackPlant[p.plant] then
		return false
	end
	return not (type(B.HarvestKeep) == "function" and B.HarvestKeep(p))
end

local function garden()
	local placed, free, weakest = 0, {}, math.huge
	for _, p in ipairs(S.plants or {}) do
		if p.placed then
			placed += 1
			weakest = math.min(weakest, incomeOf(p))
		else
			free[#free + 1] = p
		end
	end
	return placed, free, weakest
end

local plantWant = { place = false, sell = false }
local placeNoop = nil -- plant-list signature at which Place Best last changed nothing

local function placePass()
	local placed, free, weakest = garden()
	if #free == 0 then
		return
	end
	local cap = tonumber(attr("Capacity")) or 0
	local top = 0
	for _, p in ipairs(free) do
		top = math.max(top, incomeOf(p))
	end
	if placed >= cap and top <= weakest then
		return
	end
	-- the game ranks plants its own way: a press that changed nothing is not repeated until the plants change
	local sig = #(S.plants or {}) .. "|" .. placed .. "|" .. cap
	if sig == placeNoop then
		return
	end
	local before = tonumber(attr("Income")) or 0
	local ok, msg = request("PlaceBest")
	if ok then
		stats.placed += 1
		task.wait(0.5)
		local after = tonumber(attr("Income")) or 0
		local changed = math.abs(after - before) > math.max(before, 1) * 0.001 -- Income drifts on its own
		placeNoop = not changed and sig or nil
		if changed then
			say(("place best: %s/s -> %s/s (%s)"):format(fmt(before), fmt(after), tostring(msg)))
		end
	end
end

local function sellPass()
	local _, free = garden()
	local any = false
	for _, p in ipairs(free) do
		if isFodder(p) then
			any = true
			break
		end
	end
	if not any then
		return
	end
	local m0 = money()
	local ok, msg = request("SellStored")
	if ok then
		stats.sold += 1
		stats.soldFor += math.max(0, money() - m0)
		say(tostring(msg))
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
					warn("[throwseed]", name, "pass threw:", err)
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
local throwsPerCycle, trainSecs = 6, 45
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
		task.spawn(function()
			stopTraining()
			freeClient()
		end)
		say("idle")
	end
end

local plants = makeLoop("plants", PLANTS_EVERY, function()
	-- order matters: place the best, then sell what is left
	if plantWant.place then
		placePass()
	end
	if plantWant.sell then
		sellPass()
	end
end)
local function setPlants()
	local any = plantWant.place or plantWant.sell
	if any ~= plants.on then
		plants.set(any)
	end
end

local shopWant = { bar = false, cap = false }
local backoff = {}
local function nextBar()
	local bar = tonumber(attr("Bar")) or 1
	local maxBar = type(B.BarMax) == "function" and B.BarMax() or #B.Bars
	return bar < maxBar and B.Bars[bar + 1] or nil
end
local shop = makeLoop("shop", SHOP_EVERY, function()
	local cash = money()
	local nb = nextBar()
	if shopWant.bar and nb and nb.price <= cash and os.clock() >= (backoff.bar or 0) then
		local ok, msg = request("BuyBar")
		if ok then
			stats.bought += 1
			say(("bought %s for %s (%s/rep)"):format(nb.name, fmt(nb.price), fmt(nb.power)))
		else
			backoff.bar = os.clock() + SHOP_BACKOFF
			first("bar refused", tostring(msg))
		end
		return -- one purchase a pass; the next pass re-reads cash
	end
	local capNow = tonumber(attr("Capacity")) or 0
	if shopWant.cap and capNow < (B.CapacityMax or 30) and os.clock() >= (backoff.cap or 0) then
		local cost = B.CapacityCost(capNow)
		local reserve = (shopWant.bar and nb) and nb.price * BAR_RESERVE or 0
		if cost and cash - cost >= reserve then
			local ok, msg = request("BuyCapacity")
			if ok then
				stats.bought += 1
				say(("garden slot %d for %s"):format(capNow + 1, fmt(cost)))
			else
				backoff.cap = os.clock() + SHOP_BACKOFF
				first("capacity refused", tostring(msg))
			end
		end
	end
end)
local function setShop()
	local any = shopWant.bar or shopWant.cap
	if any ~= shop.on then
		shop.set(any)
	end
end

local offlineDone = false
local claims = makeLoop("claims", CLAIM_EVERY, function()
	if not offlineDone then
		offlineDone = true
		local ok = request("CollectOffline")
		if ok then
			say("offline earnings collected")
		end
	end
	if attr("DailyReady") == true and os.clock() >= (backoff.daily or 0) then
		local m0 = money()
		local ok, msg = request("ClaimDaily")
		if ok then
			say(("daily reward claimed (+%s)"):format(fmt(money() - m0)))
		else
			backoff.daily = os.clock() + 60
			first("daily refused", tostring(msg))
		end
	end
	local claimed = {}
	for d in tostring(attr("GiftsClaimed") or ""):gmatch("%d+") do
		claimed[tonumber(d)] = true
	end
	local start = tonumber(attr("SessionStart"))
	local played = start and workspace:GetServerTimeNow() - start or 0
	for i, g in ipairs(B.Gifts or {}) do
		if not claimed[i] and played >= g.at + 1 and os.clock() >= (backoff["gift" .. i] or 0) then
			local ok, msg = request("ClaimGift", { i = i })
			if ok then
				stats.gifts += 1
				say(("playtime gift %d claimed"):format(i))
			else
				backoff["gift" .. i] = os.clock() + 30
				first("gift refused", i, tostring(msg))
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
			if loops[name] and loops[name].on and m[1] ~= "training" and os.clock() - m[2] > WATCHDOG then
				warn(("[throwseed] %s stuck %ds at: %s"):format(name, os.clock() - m[2], m[1]))
				m[2] = os.clock()
			end
		end
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Throw a Seed", statusBar = true })
if not Window then
	watching = false
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "sprout")
local Farm = Tab:AddLeftGroupbox("Throw and train", "target")
local Plants = Tab:AddLeftGroupbox("Plants", "sprout")
local Shop = Tab:AddRightGroupbox("Shop", "shopping-cart")
local Free = Tab:AddRightGroupbox("Free stuff", "gift")

local function guarded(fn)
	return function(state)
		local okCb, err = pcall(fn, state)
		if not okCb then
			warn("[throwseed] toggle failed:", err)
		end
	end
end

Farm:AddToggle("Throw", {
	Text = "Auto Throw (perfect)",
	Tooltip = "Glides onto the launch strip and throws at the meter's exact peak: PERFECT every throw, one every ~6.5s (the server's limit)",
	Default = false,
	Callback = guarded(function(state)
		farmWant.throw = state
		setFarm()
	end),
})
Farm:AddToggle("Train", {
	Text = "Auto Train",
	Tooltip = "Pull-ups on your plot's bar. With Auto Throw on too it alternates: the throws below, then the training seconds below",
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

local function plantToggle(idx, key, text, tip)
	Plants:AddToggle(idx, {
		Text = text,
		Tooltip = tip,
		Default = false,
		Callback = guarded(function(state)
			plantWant[key] = state
			setPlants()
		end),
	})
end
plantToggle("Place", "place", "Auto Place Best", "The game's Place Best, from anywhere, whenever a stored plant beats your weakest placed one or a slot is free")
plantToggle("Sell", "sell", "Auto Sell Stored", "The game's Sell Stored, from anywhere. Never sells placed plants; the game keeps rare, mutated and pack plants itself")

Shop:AddToggle("Bars", {
	Text = "Auto buy bars",
	Tooltip = "The next pull-up bar as soon as you can afford it: more Strength per rep",
	Default = false,
	Callback = guarded(function(state)
		shopWant.bar = state
		setShop()
	end),
})
Shop:AddToggle("Capacity", {
	Text = "Auto buy garden slots",
	Tooltip = "BuyCapacity, only out of money left over after half of the next bar's price (up to 30 slots)",
	Default = false,
	Callback = guarded(function(state)
		shopWant.cap = state
		setShop()
	end),
})

Free:AddToggle("Claims", {
	Text = "Auto claim daily / gifts / offline",
	Tooltip = "Daily reward when ready, every playtime gift as it comes due, offline earnings once",
	Default = false,
	Callback = guarded(claims.set),
})

local conns = {}
-- the x2 bubble during training: claim every offer the server sends while Auto Train has you on the bar
table.insert(
	conns,
	R.Notify.OnClientEvent:Connect(function(kind, data)
		if kind ~= "XPOffer" or type(data) ~= "table" or not farmWant.train or not training() then
			return
		end
		task.delay(XP_CLAIM_DELAY, function()
			local ok, msg = request("XPBoost", { id = data.id })
			if ok then
				stats.boosts += 1
			else
				first("x2 refused", tostring(msg))
			end
		end)
	end)
)
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
		local str = tonumber(attr("Strength")) or 0
		local okZ, reach = pcall(B.ZoneReach, str)
		local nextZ = okZ and B.ZoneStrength and B.ZoneStrength[(reach or 0) + 1]
		pcall(Window.SetStatus, Window, {
			{ "Cash", fmt(money()) .. " (" .. fmt(attr("Income")) .. "/s)" },
			{ "Strength", fmt(str) .. (nextZ and (" / " .. fmt(nextZ)) or "") },
			{ "Zone", okZ and tostring(reach) or "-" },
			{ "Bar", tostring(attr("Bar")) },
			{ "x2", tostring(stats.boosts) },
			{ "Throws", stats.throws .. (stats.gapN > 0 and (" (%.1fs each)"):format(stats.gapSum / stats.gapN) or "") },
			{ "Best", best.text },
			{ "Sold", fmt(stats.soldFor) },
			{ "Now", note },
		})
	end)
)

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("ThrowASeed", {})

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
	plantWant.place, plantWant.sell = false, false
	shopWant.bar, shopWant.cap = false, false
	for _, L in pairs(loops) do
		L.set(false)
	end
	pcall(stopTraining)
	pcall(freeClient)
	watching = false
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().throwSeedStop = nil
end)

getgenv().throwSeedStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().throwSeedStop = nil
end
