--[[ Pull a Dino -- perfect throws, training, equip best, upgrades, codes, gifts, eggs (127366577128237)

     THROW   : teleports onto the throw pad and throws with the meter at its exact peak, every time: PERFECT
               (1.25x distance, 1.5x luck; the paid Auto Throw pass releases at 0.86). ThrowStart ->
               ThrowRelease(Start + 0.909) -> ThrowFinish. The server meters on its own receive time, so the
               0.909s is waited out for real. The server sends you home after ThrowFinish; one straight jump
               back 0.5s later holds. Banked lucky throws and the super throw are spent by the server on
               their own. ~2.4s a throw, the server's floor ("Slow down!" under it; the gap adapts). Mutes the game's own throw controller while on (it auto-starts a
               throw on the pad and shoves you 16 studs back when that fails).
     TRAIN   : the bench on your plot. Train("start") and the server does reps (~0.6s each, XP -> levels ->
               ThrowPower); the x2 bubbles are hit as they come. With THROW on as well it alternates:
               N throws, then T seconds of training (both in the panel).
     EQUIP   : the game's Equip Best (DinoAction "EquipBest"), from anywhere, whenever your dino count or
               plot slots change, and every EQUIP_EVERY as a backstop.
     SELL    : every N throws, Equip Best first, then a trip to the SELL stand: SellAll when nothing in the
               backpack is kept, otherwise one Sell per dino. Kept: the rarities you tick and any dino with a
               Serial. Sales pay almost nothing (9 dinos = 1.2M at 1.2B/s income); it clears the backpack.
     UPGRADE : cheapest affordable of the next training station (BuyStation), the next harpoon (bought and
               equipped) and the next plot slot (never past PlotMaxSlots: slot 21 is Robux).
     CODES   : every code in the game's own config (Config.Codes), ~1 a second (the server's limit),
               again every CODES_EVERY for the ones with a cooldown.
     GIFTS   : ClaimGift(n) the moment each gift's mark passes (timed from GiftStart, as the game's panel does).
     EGGS    : the daily-task egg: Egg "Claim" when the task is done, "Place" into a free nest, "Hatch" when
               the nest's ReadyAt passes. Tried from where you stand, then at the nest.

     Movement (zb moves 2026-11-18): hops kept to 40 studs, glide held to 3000 studs/s, straight 150-stud
     teleports pad <-> plot held. The undone hops seen early were the game's throw controller, not the server.

     Probed and dead (do not re-probe):
       ZoneCap past your best zone      cap 40 still landed in the zone your power reaches (it only lowers)
       early release, future timestamp  the server meters at receipt (lead 0.55 -> "Good" 0.62)
       ThrowCancel instead of Finish    keeps the dino, but the next ThrowStart says "Already throwing!"
       a second ThrowStart unfinished   "Already throwing!"
       free wheel spin / supporter dino need the game's Roblox group ("Join the group first")
       SellAll away from the stand      "Go to the SELL stand!"
     Not wired (Robux): Auto Throw / Auto Train passes, lucky throw, twirl, board, crash offers, HackSkip,
     plot slot 21, money/luck packs. Not wired (not asked): secret egg (code + lamp), hack computer.

     RightControl opens / closes the panel (so does the Zegion logo). Stop: getgenv().pullDinoStop() ]]

-- config ---------------------------------------------------------------------
local REPLY_WAIT = 6 -- an InvokeServer that has not answered in this long is given up on
local TP_SETTLE = 0.2 -- after a teleport, wait this long before judging it (x the try number)
local TP_TRIES = 3 -- straight teleports before falling back to a glide
local TP_TOL = 6 -- studs: arrived
local GLIDE_SPEED = 600 -- studs/s for the fallback glide (3000 held in zb moves); lower it if glides get pulled back
local THROW_GAP = 2.4 -- start to start; the server answers "Slow down!" under ~2.4s (measured 2.41-2.58 accepted)
local THROW_GAP_UP, THROW_GAP_DOWN = 0.15, 0.03 -- adaptive: up per "Slow down!", down per accepted throw
local THROW_GAP_MIN, THROW_GAP_MAX = 1.8, 4
local PAD_SETTLE = { 0.35, 1, 2 } -- "Stand on the throw platform!" after a teleport: retry after each of these
local HOME_WAIT = 1.5 -- after ThrowFinish, wait up to this long for the server to send you home
local POST_HOME = 0.5 -- then this long before jumping back to the pad (an instant jump got undone)
local TRAIN_STOP_WAIT = 1.5 -- after Train("stop"), wait this long for the bench to let go
local BUBBLE_DELAY = 0.15 -- hit a training bubble this long after it shows
local EQUIP_GAP = 2 -- at least this long between Equip Best presses
local EQUIP_EVERY = 30 -- press anyway this often
local SELL_GAP = 0.3 -- between single Sell calls
local UPGRADE_EVERY = 1.5
local UPGRADE_BACKOFF = 10 -- a purchase the server refused is not retried for this long
local CODE_GAP = 1.6 -- between RedeemCode calls ("Slow down a little!" at ~1/s)
local CODES_EVERY = 900 -- retry codes that have a cooldown this often
local GIFT_EVERY = 5
local EGG_EVERY = 10
local WATCHDOG = 25 -- a loop that has not moved its breadcrumb in this long is reported

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer

if getgenv and getgenv().pullDinoStop then
	getgenv().pullDinoStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[pulldino]", ...)
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
local okMods, C, RemTable = pcall(function()
	return require(ReplicatedStorage.Shared.Config), require(ReplicatedStorage.Shared.Remotes)
end)
if not Remotes or not okMods then
	warn("[pulldino] the game's modules did not load:", C)
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

-- MeterValue peaks where (t * cycles) % 1 == 0.5
local PEAK = 0.5 / C.Throw.MeterCyclesPerSecond
assert(C.MeterValue(PEAK) > 0.999 and C.MeterValue(PEAK + 0.2) < 0.9, "meter peak")

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

local function myPlot()
	local plots = workspace.Map:FindFirstChild("Plots")
	return plots and plots:FindFirstChild("Plot" .. tostring(attr("PlotId")))
end

-- world-fixed spots, read once (the map is not streamed; re-read if a part goes missing)
local spots = {}
local function spot(name)
	if spots[name] then
		return spots[name]
	end
	local p
	if name == "pad" then
		p = workspace.Map.ThrowArea.Platform.ThrowPad.Position + Vector3.new(0, 3, 0)
	elseif name == "stand" then
		p = workspace.Map.Market.SellStand:GetPivot().Position + Vector3.new(0, -4, 8) -- probed: SellAll took here
	else
		local plot = myPlot()
		local part = plot and plot.Training:FindFirstChild(name == "bench" and "TrainSpot" or "UpgradePlate")
		p = part and part.Position + Vector3.new(0, 3, 0)
	end
	spots[name] = p
	return p
end

local RARITIES = {}
for _, r in ipairs(C.Rarities) do
	RARITIES[#RARITIES + 1] = type(r) == "table" and (r.Id or r.Name) or tostring(r)
end

local stats = { throws = 0, perfect = 0, trained = 0, sold = 0, upgrades = 0, codes = 0, gifts = 0, eggs = 0 }
local best = { income = 0, text = "-" }

-- movement -------------------------------------------------------------------
local function glide(pos)
	local r = root()
	if not r then
		return false
	end
	local from = r.Position
	local dist = (pos - from).Magnitude
	local t0 = os.clock()
	local dur = dist / GLIDE_SPEED
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
		r.Anchored = false -- the bench anchors you; a teleport out of it must not carry that
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

-- mute -----------------------------------------------------------------------
-- The game's throw controller calls ThrowStart through the shared Remotes table whenever you stand on the
-- pad for 0.2s. A stub there answering the controller's own silent reason keeps it quiet with no hook;
-- our calls go to the real remote. Restored on stop.
local stub = {
	InvokeServer = function()
		return { Ok = false, Reason = "Stand on the throw platform!" }
	end,
}
local function muteThrow(on)
	RemTable.ThrowStart = on and stub or R.ThrowStart
end

-- throw ----------------------------------------------------------------------
local throwGap, lastStart = THROW_GAP, -1e9
local function throwOnce()
	step("farm", "to pad")
	if not tp(spot("pad")) then
		say("pad: the teleport did not hold")
		task.wait(1)
		return false
	end
	step("farm", "start")
	local wait = lastStart + throwGap - os.clock()
	if wait > 0 then
		task.wait(wait)
	end
	lastStart = os.clock()
	local s = invoke(R.ThrowStart)
	-- right after the bench (or any teleport) the server can still place you off the pad: retry standing still
	for _, d in ipairs(PAD_SETTLE) do
		if type(s) ~= "table" or s.Reason ~= "Stand on the throw platform!" then
			break
		end
		task.wait(d)
		tp(spot("pad"))
		lastStart = os.clock()
		s = invoke(R.ThrowStart)
	end
	if type(s) ~= "table" or not s.Ok then
		local why = type(s) == "table" and s.Reason or "no answer"
		if why == "Slow down!" then
			throwGap = math.min(throwGap + THROW_GAP_UP, THROW_GAP_MAX)
			say(("throw gap -> %.2fs"):format(throwGap), true)
			return false
		end
		say("throw refused: " .. tostring(why))
		if why == "Already throwing!" then
			R.ThrowFinish:FireServer() -- a throw left open by a stop mid-way
		end
		task.wait(0.5)
		return false
	end
	local t = s.Start + PEAK
	while workspace:GetServerTimeNow() < t do
		task.wait()
	end
	step("farm", "release")
	local r = invoke(R.ThrowRelease, REPLY_WAIT, t)
	if type(r) ~= "table" or not r.Ok then
		say("release failed: " .. tostring(type(r) == "table" and r.Reason or "no answer"))
		R.ThrowCancel:FireServer()
		task.wait(1)
		return false
	end
	if r.DinoId == nil then
		-- a free twirl (r.Spin) or the lucky board (r.Board): the release reply carries no dino and
		-- ThrowSpinDone's does. Finishing without it throws the dino away (15 lost before this was seen).
		local d = invoke(R.ThrowSpinDone)
		if type(d) == "table" and d.Ok then
			if r.Board and not firsts.board then
				first("board", HttpService:JSONEncode(d))
			end
			r = d
		else
			say("spin done refused: " .. tostring(type(d) == "table" and d.Reason or "no answer"))
		end
	end
	step("farm", "finish")
	local from = root() and root().Position
	R.ThrowFinish:FireServer()
	local w = os.clock()
	while from and root() and (root().Position - from).Magnitude < 20 and os.clock() - w < HOME_WAIT do
		task.wait()
	end
	stats.throws += 1
	throwGap = math.max(throwGap - THROW_GAP_DOWN, THROW_GAP_MIN)
	if r.Grade == "Perfect" then
		stats.perfect += 1
	end
	local line = ("%s %s%s (%s) %s/s, %s %s"):format(
		r.Grade or "?",
		r.Variant and r.Variant ~= "Normal" and (r.Variant .. " ") or "",
		tostring(r.Dino),
		tostring(r.Rarity),
		fmt(r.Income),
		tostring(r.ZoneName),
		fmt(r.Distance)
	)
	if (r.Income or 0) > best.income then
		best.income, best.text = r.Income, ("%s (%s) %s/s"):format(tostring(r.Dino), tostring(r.Rarity), fmt(r.Income))
	end
	say("throw " .. stats.throws .. ": " .. line)
	task.wait(POST_HOME)
	return true
end

-- train ----------------------------------------------------------------------
local training = false
local trainCons = {}
local function trainEvents(on)
	for _, c in ipairs(trainCons) do
		c:Disconnect()
	end
	table.clear(trainCons)
	if not on then
		return
	end
	table.insert(
		trainCons,
		R.TrainBubble.OnClientEvent:Connect(function(id)
			if training then
				task.delay(BUBBLE_DELAY, function()
					R.TrainBubbleHit:FireServer(id)
				end)
			end
		end)
	)
	table.insert(
		trainCons,
		R.TrainResult.OnClientEvent:Connect(function(res)
			if type(res) == "table" and (res.Gain or 0) > 0 then
				stats.trained += 1
			end
		end)
	)
end

local function trainFor(secs, alive)
	step("farm", "to bench")
	if not tp(spot("bench")) then
		say("bench: the teleport did not hold")
		task.wait(1)
		return
	end
	training = true
	R.Train:FireServer("start")
	say(("training %ds (power %s)"):format(secs, fmt(attr("ThrowPower"))))
	local dl = os.clock() + secs
	while alive() and os.clock() < dl do
		step("farm", "training")
		task.wait(0.25)
	end
	R.Train:FireServer("stop")
	training = false
	local w = os.clock()
	local r = root()
	while r and r.Anchored and os.clock() - w < TRAIN_STOP_WAIT do
		task.wait(0.05)
	end
	r = root()
	if r then
		r.Anchored = false
	end
end

-- sell -----------------------------------------------------------------------
local keepOn = { Mythic = true, Primal = true, Secret = true }
local sellEvery = 25

local function sellTrip()
	step("farm", "sell")
	invoke(R.DinoAction, REPLY_WAIT, "EquipBest") -- never sell something better than what is placed
	task.wait(0.5)
	local inv = invoke(R.GetInventory)
	if type(inv) ~= "table" then
		return
	end
	local bag, sellIds = 0, {}
	for _, d in ipairs(inv) do
		if (d.Slot or 0) == 0 then
			bag += 1
			local cfg = C.Dinos[d.Name]
			local rarity = cfg and cfg.Rarity
			if not d.Serial and not (cfg and cfg.NoSell) and rarity and not keepOn[rarity] then
				sellIds[#sellIds + 1] = d.Id
			end
		end
	end
	if #sellIds == 0 then
		return
	end
	if not tp(spot("stand")) then
		say("sell: the teleport did not hold")
		return
	end
	task.wait(0.3)
	local got, n = 0, 0
	if #sellIds == bag then
		local r = invoke(R.DinoAction, REPLY_WAIT, "SellAll")
		if type(r) == "table" and r.Ok then
			got, n = r.Money or 0, r.Count or #sellIds
		else
			say("sell all refused: " .. tostring(type(r) == "table" and r.Reason or "no answer"))
		end
	else
		for _, id in ipairs(sellIds) do
			local r = invoke(R.DinoAction, REPLY_WAIT, "Sell", id)
			first("sell one", type(r) == "table" and HttpService:JSONEncode(r) or tostring(r))
			if type(r) == "table" and r.Ok then
				got += r.Money or 0
				n += 1
			end
			task.wait(SELL_GAP)
		end
	end
	stats.sold += n
	if n > 0 then
		say(("sold %d dinos for %s (kept %d)"):format(n, fmt(got), bag - n))
	end
end

-- upgrade (the station's range is unproven; a refusal while affordable sends the farm to the plate) ----
local wantPlate = false
local backoff = {}

local function nextHarpoon()
	local owned = {}
	for id in tostring(attr("OwnedHarpoons") or ""):gmatch("[^,]+") do
		owned[id] = true
	end
	local top = 0
	for i, h in ipairs(C.Harpoons) do
		if owned[h.Id] then
			top = i
		end
	end
	return C.Harpoons[top + 1]
end

local function candidates(want)
	local out = {}
	if want.Station then
		local nxt = C.Training[(attr("StationTier") or 0) + 1]
		if nxt then
			out[#out + 1] = { kind = "station", price = nxt.Price, name = nxt.Name }
		end
	end
	if want.Harpoon then
		local h = nextHarpoon()
		if h then
			out[#out + 1] = { kind = "harpoon", price = h.Price, name = h.Id }
		end
	end
	if want.Slot then
		local slots = attr("PlotSlots") or 0
		local price = slots < C.PlotMaxSlots and C.PlotSlotPrices[slots + 1]
		if price then
			out[#out + 1] = { kind = "slot", price = price, name = "slot " .. (slots + 1) }
		end
	end
	table.sort(out, function(a, b)
		return a.price < b.price
	end)
	return out
end

local function buy(c)
	local r
	if c.kind == "station" then
		r = invoke(R.BuyStation)
	elseif c.kind == "harpoon" then
		r = invoke(R.ShopAction, REPLY_WAIT, "BuyHarpoon", c.name)
		if type(r) == "table" and r.Ok then
			invoke(R.ShopAction, REPLY_WAIT, "EquipHarpoon", c.name)
		end
	else
		r = invoke(R.ShopAction, REPLY_WAIT, "BuyPlotSlots")
	end
	return type(r) == "table" and r.Ok, type(r) == "table" and r.Reason
end

-- eggs -----------------------------------------------------------------------
local function eggState()
	local okJ, st = pcall(HttpService.JSONDecode, HttpService, attr("EggState") or "")
	return okJ and type(st) == "table" and st or nil
end

local function nests()
	local plot = myPlot()
	local folder = plot and plot:FindFirstChild("EggNests")
	local out = {}
	for _, n in ipairs(folder and folder:GetChildren() or {}) do
		out[#out + 1] = n
	end
	table.sort(out, function(a, b)
		return a.Name < b.Name
	end)
	return out
end

local eggErrand = nil -- a nest action refused from afar: the farm runs it at the nest
local function eggAction(kind, idx, nest)
	local r = invoke(R.Egg, REPLY_WAIT, kind, idx)
	first("egg " .. kind, type(r) == "table" and HttpService:JSONEncode(r) or tostring(r))
	if type(r) == "table" and r.Ok then
		stats.eggs += 1
		say(("egg %s, nest %d"):format(kind:lower(), idx))
		return true
	end
	if nest then
		eggErrand = { kind = kind, idx = idx, pos = nest:GetPivot().Position + Vector3.new(0, 3, 0) }
	end
	return false
end

local function eggPass()
	local st = eggState()
	if not st then
		return
	end
	if st.Done then
		local r = invoke(R.Egg, REPLY_WAIT, "Claim")
		first("egg claim", type(r) == "table" and HttpService:JSONEncode(r) or tostring(r))
		if type(r) == "table" and r.Ok then
			say("egg task done: +1 egg")
		end
		st = eggState() or st
	end
	local now = workspace:GetServerTimeNow()
	for i, n in ipairs(nests()) do
		local idx = n:GetAttribute("NestIndex") or i
		local placed, ready = n:GetAttribute("PlacedAt") or 0, n:GetAttribute("ReadyAt") or 0
		if placed > 0 and ready > 0 and now >= ready then
			eggAction("Hatch", idx, n)
		elseif placed == 0 and (st.Inv or 0) > 0 then
			if eggAction("Place", idx, n) then
				st.Inv -= 1
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
					warn("[pulldino]", name, "pass threw:", err)
					task.wait(1)
				end
				task.wait(every)
			end
		end)
	end
	loops[name] = L
	return L
end

-- the farm owns the character: throwing, training and every trip (sell, station plate, nest)
local farmWant = { throw = false, train = false, sell = false }
local throwsPerCycle, trainSecs = 10, 30
local cycleThrows, sinceSell = 0, 0
local farm = makeLoop("farm", 0, function(alive)
	if farmWant.sell and sinceSell >= sellEvery then
		sinceSell = 0
		sellTrip()
	end
	if wantPlate then
		wantPlate = false
		step("farm", "plate")
		if tp(spot("plate")) then
			task.wait(0.3)
			local okB, why = buy({ kind = "station" })
			say(okB and "station bought at the plate" or ("station refused at the plate: " .. tostring(why)))
			if okB then
				stats.upgrades += 1
			end
		end
	end
	if eggErrand then
		local e = eggErrand
		eggErrand = nil
		step("farm", "nest")
		if tp(e.pos) then
			task.wait(0.3)
			local r = invoke(R.Egg, REPLY_WAIT, e.kind, e.idx)
			first("egg at nest " .. e.kind, type(r) == "table" and HttpService:JSONEncode(r) or tostring(r))
		end
	end
	if farmWant.throw and (not farmWant.train or cycleThrows < throwsPerCycle) then
		if throwOnce() then
			cycleThrows += 1
			sinceSell += 1
		end
	elseif farmWant.train then
		trainFor(trainSecs, alive)
		cycleThrows = 0
	else
		task.wait(0.5)
	end
end)

local function setFarm()
	local on = farmWant.throw or farmWant.train
	muteThrow(farmWant.throw)
	trainEvents(farmWant.train)
	if not on and training then
		R.Train:FireServer("stop")
		training = false
	end
	if on ~= farm.on then
		farm.set(on)
	end
	if not on then
		say("idle")
	end
end

local equipState = { sig = nil, at = -99 }
local equip = makeLoop("equip", 1, function()
	local sig = ("%s|%s|%s"):format(tostring(attr("DinoCount")), tostring(attr("Backpack")), tostring(attr("PlotSlots")))
	local now = os.clock()
	if (sig ~= equipState.sig and now - equipState.at >= EQUIP_GAP) or now - equipState.at >= EQUIP_EVERY then
		local before = tonumber(attr("MoneyPerSec")) or 0
		equipState.sig, equipState.at = sig, now
		local r = invoke(R.DinoAction, REPLY_WAIT, "EquipBest")
		if type(r) == "table" and r.Ok and not r.Already then
			task.wait(0.8)
			local after = tonumber(attr("MoneyPerSec")) or 0
			say(("equip best: %s/s -> %s/s"):format(fmt(before), fmt(after)))
		end
	end
end)

local upWant = { Station = false, Harpoon = false, Slot = false }
local upgrade = makeLoop("upgrade", UPGRADE_EVERY, function()
	local cash = money()
	for _, c in ipairs(candidates(upWant)) do
		if c.price <= cash and os.clock() >= (backoff[c.kind] or 0) then
			local okB, why = buy(c)
			if okB then
				stats.upgrades += 1
				say(("bought %s %s for %s"):format(c.kind, c.name, fmt(c.price)))
			else
				backoff[c.kind] = os.clock() + UPGRADE_BACKOFF
				first("refused " .. c.kind, tostring(why))
				if c.kind == "station" and farm.on then
					wantPlate = true -- affordable and refused: try standing on the plate
				end
			end
			return -- one purchase a pass; the next pass re-reads cash
		end
	end
end)

local codesDone, codesAt = {}, -1e9
local codes = makeLoop("codes", 5, function(alive)
	if os.clock() - codesAt < CODES_EVERY then
		return
	end
	codesAt = os.clock()
	for code, def in pairs(C.Codes) do
		if not alive() then
			return
		end
		if not codesDone[code] then
			local r = invoke(R.RedeemCode, REPLY_WAIT, code)
			local why = type(r) == "table" and (r.Text or r.Reason) or "no answer"
			if type(r) == "table" and r.Ok then
				stats.codes += 1
				say(("code %s: %s"):format(code, tostring(why)))
			end
			if type(r) == "table" and (r.Ok or tostring(r.Reason):lower():find("already")) and not def.Cooldown then
				codesDone[code] = true -- one-time codes are never tried again this session
			end
			task.wait(CODE_GAP)
		end
	end
end)

local gifts = makeLoop("gifts", GIFT_EVERY, function()
	local claimed = {}
	for n in tostring(attr("GiftsClaimed") or ""):gmatch("%d+") do
		claimed[tonumber(n)] = true
	end
	-- the game's own gift panel times gifts from GiftStart on the server clock; PlayTime lags it (refused at the edge)
	local start = tonumber(attr("GiftStart"))
	local played = start and workspace:GetServerTimeNow() - start - 2 or 0
	for i, g in ipairs(C.Gifts) do
		if not claimed[i] and played >= g.At and os.clock() >= (backoff["gift" .. i] or 0) then
			local r = invoke(R.ClaimGift, REPLY_WAIT, i)
			if type(r) == "table" and r.Ok then
				stats.gifts += 1
				say(("gift %d: %s"):format(i, tostring(r.Text)))
			else
				backoff["gift" .. i] = os.clock() + 30
				first("gift refused", i, type(r) == "table" and r.Reason or "no answer")
			end
		end
	end
end)

local eggs = makeLoop("eggs", EGG_EVERY, eggPass)

-- watchdog -------------------------------------------------------------------
local watching = true
task.spawn(function()
	while watching do
		task.wait(5)
		for name, m in pairs(marks) do
			if loops[name] and loops[name].on and os.clock() - m[2] > WATCHDOG then
				warn(("[pulldino] %s stuck %ds at: %s"):format(name, os.clock() - m[2], m[1]))
				m[2] = os.clock()
			end
		end
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Pull a Dino", statusBar = true })
if not Window then
	watching = false
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "target")
local Farm = Tab:AddLeftGroupbox("Throw and train", "target")
local Dinos = Tab:AddLeftGroupbox("Dinos", "paw-print")
local Up = Tab:AddRightGroupbox("Upgrades", "trending-up")
local Free = Tab:AddRightGroupbox("Free stuff", "gift")

local function guarded(fn)
	return function(state)
		local okCb, err = pcall(fn, state)
		if not okCb then
			warn("[pulldino] toggle failed:", err)
		end
	end
end

Farm:AddToggle("Throw", {
	Text = "Auto Throw (perfect)",
	Tooltip = "Teleports onto the throw pad and releases at the meter's exact peak: PERFECT every throw. Mutes the game's own throw controller while on",
	Default = false,
	Callback = guarded(function(state)
		farmWant.throw = state
		setFarm()
	end),
})
Farm:AddToggle("Train", {
	Text = "Auto Train",
	Tooltip = "Trains on your plot's bench and hits the x2 bubbles. With Auto Throw on too it alternates: the throws below, then the training seconds below",
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
		trainSecs = math.max(5, math.floor(tonumber(text) or trainSecs))
	end,
})

Dinos:AddToggle("Equip", {
	Text = "Auto Equip Best",
	Tooltip = "Presses the game's Equip Best whenever your dino count or plot slots change, from anywhere",
	Default = false,
	Callback = guarded(equip.set),
})
Dinos:AddToggle("Sell", {
	Text = "Auto Sell backpack",
	Tooltip = "Every N throws: Equip Best, then a trip to the SELL stand. Never sells the rarities ticked below or a dino with a serial number. Sales pay very little; this keeps the backpack clear",
	Default = false,
	Callback = guarded(function(state)
		farmWant.sell = state
	end),
})
Dinos:AddDropdown("Keep", {
	Text = "Never sell",
	Values = RARITIES,
	Default = { "Mythic", "Primal", "Secret" },
	Multi = true,
	Callback = function(picked)
		table.clear(keepOn)
		for name in pairs(ticked(picked)) do
			keepOn[name] = true
		end
	end,
})
Dinos:AddInput("SellEvery", {
	Text = "Sell every N throws",
	Default = tostring(sellEvery),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		sellEvery = math.max(1, math.floor(tonumber(text) or sellEvery))
	end,
})

local function upToggle(idx, key, text, tip)
	Up:AddToggle(idx, {
		Text = text,
		Tooltip = tip,
		Default = false,
		Callback = guarded(function(state)
			upWant[key] = state
			local any = upWant.Station or upWant.Harpoon or upWant.Slot
			if any ~= upgrade.on then
				upgrade.set(any)
			end
		end),
	})
end
upToggle("Station", "Station", "Auto buy training station", "Next bench dino: more power per level, faster reps")
upToggle("Harpoon", "Harpoon", "Auto buy harpoon", "Next harpoon in the shop list (more luck), equipped straight away")
upToggle("Slot", "Slot", "Auto buy plot slot", "Next plot slot, up to the free maximum (slot 21 is Robux and never bought)")

Free:AddToggle("Codes", {
	Text = "Auto redeem codes",
	Tooltip = "Every code in the game's own config, about one a second. Cooldown codes are retried every 15 min",
	Default = false,
	Callback = guarded(codes.set),
})
Free:AddToggle("Gifts", {
	Text = "Auto claim playtime gifts",
	Default = false,
	Callback = guarded(gifts.set),
})
Free:AddToggle("Eggs", {
	Text = "Auto daily-task eggs",
	Tooltip = "Claims the egg when the daily task is done, places it in a free nest and hatches it when ready",
	Default = false,
	Callback = guarded(eggs.set),
})

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
		local lucky = (attr("LuckyThrows") or 0) + (attr("LuckyThrows60") or 0) + (attr("LuckyThrows50") or 0)
		local zone = C.ZoneForDistance(tonumber(attr("BestDistance")) or 0)
		pcall(Window.SetStatus, Window, {
			{ "Cash", fmt(money()) .. " (" .. fmt(attr("MoneyPerSec")) .. "/s)" },
			{ "Power", fmt(attr("ThrowPower")) },
			{ "Zone", zone and zone.Name or "-" },
			{ "Throws", stats.throws .. " (" .. stats.perfect .. " perfect)" },
			{ "Best", best.text },
			{ "Lucky", lucky },
			{ "Bought", stats.upgrades },
			{ "Now", note },
		})
	end)
)

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("PullADino", {})

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
	farmWant.throw, farmWant.train, farmWant.sell = false, false, false
	setFarm() -- hands ThrowStart back to the game's controller, stops the bench
	for _, L in pairs(loops) do
		L.set(false)
	end
	watching = false
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
	local r = root()
	if r then
		r.Anchored = false
	end
end

Library:OnUnload(function()
	stopAll()
	getgenv().pullDinoStop = nil
end)

getgenv().pullDinoStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().pullDinoStop = nil
end
