--[[ Wake up the Animal -- throw, echo, train Breath, claim, sell, buy (122281262593872)

     THROW  : the whole throw without the minigame. Hops onto the start line (two 35-stud jumps; you
              land 1 stud short of the band the game's own controller auto-starts on, so it never opens
              its meter), StartPlay, SubmitNote at the meter's peak (0.75s, Perfect on every throw), and
              when the server rolls an echo (about half the throws) ResolveEcho(0) 1s later: a hit pushes
              the throw +168 studs, which at the end of a biome lands in the NEXT one (8 of 8 echo hits from
              biome 6 woke Volcanic Lands animals). Then FinishPlay(skip), which wakes the animal, places it
              in your pen if it beats one there (the server does that itself) and sends you home.
              About 1.9s a throw, 2.9s with an echo. Everything is remote; the only movement is the hop.
     TRAIN  : stands on your base's trainer pad (the server sets Training and pays Breath xp every 1.1s)
              and fires TrainGust every 5.5s (the server's own cooldown: faster calls return nil).
              Breath sets how far a throw goes: 800 reaches biome 7, 1200 biome 8 ... 5000 biome 12.
     SPLIT  : throwing needs the start line and training needs the pad, so with both on they alternate:
              TRAIN_SECONDS on the pad, then THROWS_PER_ROUND throws. With one on, it runs non-stop.
     GIFTS  : GiftGet, then GiftClaim for every "ready" playtime / quest / streak / bonus gift.
     EQUIP  : the game's EQUIP BEST (Animals placeBest) every 10s. A wake that beats the pen is placed by the
              server already; this catches animals from before the script and new slots.
     SELL   : once the bag holds SELL_AT animals: Animals placeBest, then sellAll (the game's own SELL ALL:
              it keeps placed, carried and locked animals). Works from anywhere, no sell pad.
     BUY    : trainer levels first (UpgradeTrainer, in order), then the best instrument you can pay for
              (Shop buyInstrument, which also equips it). Costs are the game's config. A reserve box keeps
              cash back from both. Both remotes work from anywhere.

     Probed and dead: breathUse above 1 (the server clamps it); an early SubmitNote (the server times the
     note on its own clock: sent at 0 or 0.3s it scores Weak); TrainGust faster than 5.5s; StartPlay off the
     start line (refused 48 studs away). Not wired: ClaimFreePet (group join, a Golden Bear), ClaimOffline
     (shown once on join; the 5x claim is Robux), RedeemCode (no codes in the client), lucky throws and rift
     keys (Robux), the Debug* remotes. Movement: 40-stud hops held (Z.moves 2026-11-28), glide not measured.

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().wakeAnimalStop() ]]

-- config ---------------------------------------------------------------------
local HOP_STEP = 35 -- studs per jump; 40 held, 80 was never tried (no floor that far)
local HOP_SETTLE = 0.15 -- between jumps. Raise if the hop lands you back where you started
local ARRIVE_TOL = 4 -- studs: closer than this counts as arrived
local NOTE_LEAD = 0.03 -- send the note this much before the 0.75s peak to cover the trip to the server
local ECHO_WAIT = 1 -- after the note; 1 to 4.5s all hit, 0.3s missed
local START_RETRY = { 0.35, 1, 2 } -- StartPlay refused right after a hop: retry on this ladder
local THROW_GAP = 0.2 -- after FinishPlay, before the next hop
local GUST_EVERY = 5.6 -- the server's gust cooldown is 5.5s
local TRAIN_RECHECK = 2 -- off the pad (Training not set) this long and it hops back on
local THROWS_PER_ROUND = 20 -- with both on: throws per round...
local TRAIN_SECONDS = 60 -- ...and seconds on the pad per round
local GIFT_EVERY = 30
local SELL_AT = 100 -- bag size that triggers a sell (the bag holds 1500)
local SELL_EVERY = 5
local EQUIP_EVERY = 10 -- the server places a better wake by itself; this catches the rest (new slots, old bag)
local BUY_EVERY = 5
local STUCK_AFTER = 30 -- the watchdog prints when the breadcrumb has not moved for this long

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().wakeAnimalStop then
	getgenv().wakeAnimalStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[wakeanimal]", ...)
end

local said = {}
local function first(name, ...)
	if not said[name] then
		said[name] = true
		log("first", name, ...)
	end
end

-- The strip is drained from a Heartbeat: a loop thread writing to the window throws
-- "lacking capability Plugin" after its first task.wait.
local pending, lastSaid = {}, nil
local function say(msg, slot)
	pending[slot or "now"] = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

local mark, markAt = "idle", os.clock()
local function step(m)
	mark, markAt = m, os.clock()
end

-- game -----------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
local ok, Rules, Layout, Economy, Trainer, Instruments = pcall(function()
	local Shared = ReplicatedStorage.Shared
	return require(Shared.Rules),
		require(Shared.Layout),
		require(Shared.Config.Economy),
		require(Shared.Config.Trainer),
		require(Shared.Config.Instruments)
end)
if not Remotes or not ok then
	warn("[wakeanimal] the game's modules did not load:", Rules)
	return
end
local R = {}
for _, name in { "StartPlay", "SubmitNote", "ResolveEcho", "FinishPlay", "TrainGust", "UpgradeTrainer", "Shop", "Animals", "GiftGet", "GiftClaim" } do
	R[name] = Remotes:WaitForChild(name, 10)
	if not R[name] then
		warn("[wakeanimal] remote missing:", name)
		return
	end
end

local PEAK = Economy.note.periodSeconds / 2 -- Rules.pointerAt is 1 at half a period
assert(Rules.powerAt(PEAK) == Economy.note.maxPower, "the meter peaks at half a period")
local START_POS = Vector3.new(0, 3, Layout.CORRIDOR_START_Z - 1) -- server band, not the client's
assert(not Layout.nearStartLine(START_POS, 0) and Layout.nearStartLine(START_POS, 2), "start spot sits between the bands")

local function fmt(n)
	local s = pcall(Rules.formatNumber, n) and Rules.formatNumber(n)
	return s or tostring(n)
end

local function attr(k, default)
	local v = player:GetAttribute(k)
	if v == nil then
		return default
	end
	return v
end

local function call(remote, ...)
	local res = table.pack(pcall(remote.InvokeServer, remote, ...))
	if not res[1] then
		warn("[wakeanimal]", remote.Name, "threw:", res[2])
		return nil
	end
	return table.unpack(res, 2, res.n)
end

-- The game's own toast, for a throw that improved the pen. Optional: a fresh require may not be the live copy.
local toast
do
	local controllers = player:FindFirstChild("PlayerScripts")
	controllers = controllers and controllers:FindFirstChild("Client")
	controllers = controllers and controllers:FindFirstChild("Controllers")
	local hud = controllers and controllers:FindFirstChild("HudController")
	local okHud, Hud = pcall(require, hud)
	if okHud and type(Hud) == "table" and type(Hud.toast) == "function" then
		toast = function(text)
			pcall(Hud.toast, text, Color3.fromRGB(255, 220, 120))
		end
	end
end

-- world ----------------------------------------------------------------------
local function root()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

-- Teleport in jumps no longer than the measured ceiling, judged on arrival, one retry from where it left you.
local function hopTo(pos)
	for _ = 1, 2 do
		local hrp = root()
		if not hrp then
			return false
		end
		local from = hrp.Position
		local n = math.max(1, math.ceil((pos - from).Magnitude / HOP_STEP))
		for i = 1, n do
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.CFrame = CFrame.new(from:Lerp(pos, i / n))
			task.wait(HOP_SETTLE)
		end
		if (hrp.Position - pos).Magnitude < ARRIVE_TOL then
			return true
		end
		first("hop retry", from, "->", pos, "landed", hrp.Position)
	end
	return false
end

local function padPos()
	return Layout.trainerPad(attr("BaseIndex", 1)).Position + Vector3.new(0, 3, 0)
end

-- throw ----------------------------------------------------------------------
local throwOn, trainOn = false, false
local stats = { throws = 0, perfect = 0, echoes = 0, hits = 0, improved = 0, refused = 0, gifts = 0, sold = 0, bought = 0, gusts = 0 }
local best -- this session's best wake: { name, income }
local breath0 = attr("Breath", 0)

local function noteResult(res)
	local rec = type(res) == "table" and res.record
	if not rec then
		return
	end
	local income = tonumber(res.income) or 0
	local name = ("%s %s %s"):format(rec.mut or "", rec.size or "", rec.id or "?")
	if not best or income > best.income then
		best = { name = name, income = income }
	end
	if res.improved or res.newBest then
		stats.improved += 1
		log(("pen improved: %s at %s/s (biome %s)"):format(name, fmt(income), tostring(res.biomeIndex)))
		if toast then
			toast(("%s +%s/s"):format(name, fmt(income)))
		end
	end
end

local function throwOnce()
	step("throw / hop")
	if not hopTo(START_POS) then
		say("hop to the start line did not land")
		task.wait(1)
		return
	end
	step("throw / start")
	local started = call(R.StartPlay)
	for _, gap in START_RETRY do
		if started then
			break
		end
		task.wait(gap)
		started = call(R.StartPlay)
	end
	if not started then
		stats.refused += 1
		local hrp = root()
		say(("StartPlay refused at %s"):format(hrp and tostring(hrp.Position) or "?"))
		task.wait(1)
		return
	end
	local t0 = os.clock()
	task.wait(math.max(0, PEAK - NOTE_LEAD - (os.clock() - t0)))
	step("throw / note")
	local note = call(R.SubmitNote, PEAK)
	local res = note
	if type(note) == "table" then
		stats.throws += 1
		if note.grade == "Perfect" then
			stats.perfect += 1
		else
			first("not perfect", note.grade, note.power)
		end
		if note.echo then
			stats.echoes += 1
			task.wait(ECHO_WAIT)
			step("throw / echo")
			local e = call(R.ResolveEcho, 0)
			if type(e) == "table" then
				res = e
				if e.echoHit then
					stats.hits += 1
				else
					first("echo missed", ECHO_WAIT)
				end
			end
		end
	else
		first("note reply", tostring(note))
	end
	step("throw / finish")
	call(R.FinishPlay, true)
	noteResult(res)
	if type(res) == "table" then
		say(("%s %s m, biome %s%s"):format(tostring(res.grade), fmt(math.floor((res.distance or 0) * Rules.METERS_PER_STUD)), tostring(res.biomeIndex), res.echoHit and ", echo" or ""))
	end
	task.wait(THROW_GAP)
end

-- train ----------------------------------------------------------------------
-- Stays until training is switched off, or (with throwing on) TRAIN_SECONDS are up.
local function trainRound()
	local start = os.clock()
	local nextGust, offSince = 0, nil
	step("train / hop")
	hopTo(padPos())
	while trainOn and not (throwOn and os.clock() - start >= TRAIN_SECONDS) do
		if attr("Training", false) then
			offSince = nil
			if os.clock() >= nextGust then
				step("train / gust")
				local g = call(R.TrainGust)
				if g then
					stats.gusts += 1
				end
				nextGust = os.clock() + (g and GUST_EVERY or 1)
			end
			say(("training: Breath %s (+%d), %d gusts"):format(fmt(attr("Breath", 0)), attr("Breath", 0) - breath0, stats.gusts), "phase")
		else
			offSince = offSince or os.clock()
			if os.clock() - offSince > TRAIN_RECHECK then
				first("off the pad", root() and root().Position)
				step("train / re-hop")
				hopTo(padPos())
				offSince = nil
			end
		end
		step("train / wait")
		task.wait(0.25)
	end
end

-- body -----------------------------------------------------------------------
-- One thread owns the character: throwing and training take turns on it.
local bodyRunning = false
local function bodyLoop()
	bodyRunning = true
	while throwOn or trainOn do
		if throwOn then
			local n = 0
			while throwOn and not (trainOn and n >= THROWS_PER_ROUND) do
				pending.phase = ("throwing %d/%s"):format(n + 1, trainOn and tostring(THROWS_PER_ROUND) or "-")
				throwOnce()
				n += 1
			end
		end
		if trainOn then
			trainRound()
		end
	end
	step("idle")
	pending.phase = "idle"
	bodyRunning = false
end

local function kickBody()
	if not bodyRunning and (throwOn or trainOn) then
		task.spawn(function()
			local okB, err = pcall(bodyLoop)
			if not okB then
				bodyRunning = false
				warn("[wakeanimal] body loop died:", err)
			end
		end)
	end
end

-- side loops (no body) -------------------------------------------------------
local giftOn, sellOn, equipOn, trainerBuyOn, instrumentBuyOn = false, false, false, false, false
local reserve = 0
local running = true

local function claimGifts()
	local g = call(R.GiftGet)
	if type(g) ~= "table" then
		return
	end
	local function take(kind, i)
		if call(R.GiftClaim, kind, i) == true then
			stats.gifts += 1
			say(("claimed %s gift %s"):format(kind, tostring(i or "")))
		else
			first("gift refused", kind, i)
		end
	end
	for _, kind in { "play", "quest" } do
		for i, row in (g[kind] or {}) do
			if type(row) == "table" and row.state == "ready" then
				take(kind, i)
			end
		end
	end
	for _, row in (g.streak or {}) do
		if type(row) == "table" and row.state == "ready" then
			take("streak", nil)
			break
		end
	end
	if type(g.bonus) == "table" and g.bonus.state == "ready" then
		take("bonus", nil)
	end
end

local function sellBag()
	local bag = attr("BagCount", 0)
	if bag < SELL_AT then
		return
	end
	call(R.Animals, "placeBest") -- anything better than the pen goes in before the sale
	task.wait(0.4)
	local okS, why = call(R.Animals, "sellAll")
	if okS then
		stats.sold += bag
		say(("sold %d animals (cash %s)"):format(bag, fmt(attr("Money", 0))))
	else
		log("sellAll refused at bag", bag, why) -- seen once 20s after a sale (Economy.sellSeconds = 20?); the next pass took
	end
end

local function owned()
	local set = {}
	for id in string.gmatch(attr("Owned", ""), "[^,]+") do
		set[id] = true
	end
	return set
end

-- The best instrument by luck that is owned or affordable; nil when the equipped one already is it.
local function nextInstrument(money, have)
	local equipped = attr("Equipped", "WoodenFlute")
	local cur = Rules.instrumentById[equipped]
	local bestRow = cur
	for _, row in Instruments do
		if row.luck > (bestRow and bestRow.luck or 0) and (have[row.id] or row.cost <= money) then
			bestRow = row
		end
	end
	if bestRow and bestRow.id ~= equipped then
		return bestRow
	end
	return nil
end
do -- self-check against the live list: never picks something it can't pay for and doesn't own
	local pick = nextInstrument(0, { WoodenFlute = true })
	assert(pick == nil or pick.cost == 0, "nextInstrument respects money")
end

local function buyPass()
	local money = attr("Money", 0) - reserve
	if trainerBuyOn then
		local nxt = Trainer.levels[attr("TrainerLevel", 1) + 1]
		if nxt and nxt.cost <= money then
			local lv = attr("TrainerLevel", 1)
			local okU, why = call(R.UpgradeTrainer)
			if okU then
				stats.bought += 1
				say(("trainer %d -> %d (%s, %s xp a cycle)"):format(lv, lv + 1, nxt.name, fmt(nxt.perCycle)))
				return -- one buy per pass: the next pass re-reads the cash
			end
			first("trainer refused", why)
		end
	end
	if instrumentBuyOn then
		local have = owned()
		local row = nextInstrument(money, have)
		if row then
			local okB, why = call(R.Shop, have[row.id] and "equip" or "buyInstrument", row.id)
			if okB then
				stats.bought += 1
				say(("instrument: %s (luck x%s)"):format(row.name, fmt(row.luck)))
			else
				first("instrument refused", row.id, why)
			end
		end
	end
end

local function every(gap, isOn, fn, name)
	task.spawn(function()
		while running do
			if isOn() then
				local okP, err = pcall(fn)
				if not okP then
					warn("[wakeanimal]", name, "failed:", err)
				end
			end
			task.wait(gap)
		end
	end)
end
every(GIFT_EVERY, function()
	return giftOn
end, claimGifts, "gifts")
every(SELL_EVERY, function()
	return sellOn
end, sellBag, "sell")
every(EQUIP_EVERY, function()
	return equipOn
end, function()
	call(R.Animals, "placeBest")
end, "equip")
every(BUY_EVERY, function()
	return trainerBuyOn or instrumentBuyOn
end, buyPass, "buy")

task.spawn(function() -- watchdog: a thread parked in a yield can't report itself
	local warned = nil
	while running do
		task.wait(5)
		if bodyRunning and os.clock() - markAt > STUCK_AFTER and warned ~= markAt then
			warned = markAt
			warn(("[wakeanimal] stuck %ds at: %s"):format(math.floor(os.clock() - markAt), mark))
		end
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Wake up the Animal", statusBar = true })
if not Window then
	running = false
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "paw-print")
local Farm = Tab:AddLeftGroupbox("Farm", "wind")
local Extra = Tab:AddRightGroupbox("Extras", "gift")

Farm:AddToggle("Throw", {
	Text = "Auto Throw + Echo",
	Tooltip = "Hops to the start line and throws: Perfect every time, echo hit 1s later when the server rolls one (it reaches the next biome). About 2s a throw",
	Default = false,
	Callback = function(state)
		throwOn = state
		kickBody()
		if not state then
			say("throwing off")
		end
	end,
})
Farm:AddToggle("Train", {
	Text = "Auto Train Breath",
	Tooltip = "Stands on your trainer pad and gusts every 5.5s. Breath decides how far a throw goes. With Throw on too, they take turns",
	Default = false,
	Callback = function(state)
		trainOn = state
		kickBody()
		if not state then
			say("training off")
		end
	end,
})
Farm:AddInput("ThrowsPerRound", {
	Text = "Throws per round",
	Default = tostring(THROWS_PER_ROUND),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		THROWS_PER_ROUND = math.max(1, math.floor(tonumber(text) or THROWS_PER_ROUND))
	end,
})
Farm:AddInput("TrainSeconds", {
	Text = "Training seconds per round",
	Default = tostring(TRAIN_SECONDS),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		TRAIN_SECONDS = math.max(5, tonumber(text) or TRAIN_SECONDS)
	end,
})

Extra:AddToggle("Gifts", {
	Text = "Auto Claim Gifts",
	Tooltip = "Playtime, quest, streak and bonus gifts, every 30s",
	Default = false,
	Callback = function(state)
		giftOn = state
	end,
})
Extra:AddToggle("EquipBest", {
	Text = "Auto Equip Best",
	Tooltip = "Presses the game's EQUIP BEST every 10s: the best animals you own go into the pen",
	Default = false,
	Callback = function(state)
		equipOn = state
	end,
})
Extra:AddToggle("Sell", {
	Text = "Auto Sell Bag",
	Tooltip = "At the bag size below: Equip Best, then Sell All. Keeps placed, carried and locked animals. Lock one in the game's inventory to keep it",
	Default = false,
	Callback = function(state)
		sellOn = state
	end,
})
Extra:AddInput("SellAt", {
	Text = "Sell when the bag holds",
	Default = tostring(SELL_AT),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		SELL_AT = math.max(1, math.floor(tonumber(text) or SELL_AT))
	end,
})
Extra:AddToggle("BuyTrainer", {
	Text = "Auto Upgrade Trainer",
	Tooltip = "Buys the next trainer level whenever the cash (minus the reserve) covers it. Runs before instruments",
	Default = false,
	Callback = function(state)
		trainerBuyOn = state
	end,
})
Extra:AddToggle("BuyInstrument", {
	Text = "Auto Buy Best Instrument",
	Tooltip = "Buys and equips the highest-luck instrument the cash (minus the reserve) covers; equips a better one you already own",
	Default = false,
	Callback = function(state)
		instrumentBuyOn = state
	end,
})
Extra:AddInput("Reserve", {
	Text = "Cash reserve (never spent)",
	Default = "0",
	Numeric = true,
	Finished = true,
	Callback = function(text)
		reserve = math.max(0, tonumber(text) or 0)
	end,
})

local conns = {}
local note, phase = "idle", "idle"
local nextStrip = 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	if pending.now then
		note, pending.now = pending.now, nil
	end
	if pending.phase then
		phase, pending.phase = pending.phase, nil
	end
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	local b = attr("Breath", 0)
	pcall(Window.SetStatus, Window, {
		{ "Cash", fmt(attr("Money", 0)) },
		{ "Breath", ("%s (+%d), biome %s"):format(fmt(b), b - breath0, tostring(Rules.biomeForBreath(b))) },
		{ "Throws", ("%d (%d perfect, echo %d/%d)"):format(stats.throws, stats.perfect, stats.hits, stats.echoes) },
		{ "Best", best and ("%s %s/s"):format(best.name, fmt(best.income)) or "-" },
		{ "Pen +", stats.improved },
		{ "Sold", stats.sold },
		{ "Bought", stats.bought },
		{ "Gifts", stats.gifts },
		{ "Phase", phase },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("WakeUpTheAnimal", {})

-- The game's own Idled handler calls AfkRejoin after 1110s idle, which ends a long farm: mute it while
-- loaded, and answer Idled ourselves.
local muted = {}
if getconnections then
	for _, c in getconnections(player.Idled) do
		pcall(function()
			c:Disable()
			table.insert(muted, c)
		end)
	end
else
	first("no getconnections: the game's AFK rejoin stays armed")
end
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
	throwOn, trainOn = false, false
	giftOn, sellOn, equipOn, trainerBuyOn, instrumentBuyOn = false, false, false, false, false
	for _, c in muted do
		pcall(function()
			c:Enable()
		end)
	end
	table.clear(muted)
	for _, c in conns do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().wakeAnimalStop = nil
end)

getgenv().wakeAnimalStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().wakeAnimalStop = nil
end
