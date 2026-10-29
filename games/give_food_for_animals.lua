--[[ Give Food for Animals -- perfect throws with no animation, training, upgrades, best animals placed (120219252362013)

     THROW  : throw back to back from the start line: every throw a perfect meter, full power, and
              none of the camera / flight / reveal sequence
     TRAIN  : stand on your plot's pull-up bar and train (the only XP source: throws give none)
              Both on: THROW burst, then TRAIN block, repeat (the server refuses one during the other)
     BAR    : buy the next pull-up bar as soon as you can afford it (XP per rep doubles each tier)
     FOOD   : buy the best food you can afford and equip the best one you own
     PLACE  : put your best animals on the plot (the Animals panel's "Equip best")

     How it works (probed live, v1168): a throw is three RemoteFunctions, Throw_Start() ->
     Throw_Resolve(meter 0..1) -> Throw_Complete(). The meter value is the client's own number, so
     1 is a perfect throw (Accuracy 1) every time. The cutscene is all client-side, so skipping it is
     not running ThrowController; Throw_Complete still blocks ~6s on the server (flight + reveal),
     which is the real rate. Start refuses "TooFar" off the StarterArea and pins you to the pad;
     Complete sends you home to the plot, so each throw hops back (74 studs, the distance the game
     moves you itself; Start needs ~0.15s after it, and says "Cooldown" for a moment after Complete).
     Hopping makes the cycle ~8s against ~10s walking: Complete's server wait is the cap.
     Training: Training_Start() on LocalPlotProps.TrainingArea.TrainingSpot ("TooFar" elsewhere),
     XP ticks server-side until Training_Stop(). Training_Start during a throw says "Throwing".
     Stand_Upgrade() buys the next bar; Shop_Buy(i) / Shop_Equip(i) take the FoodsConfig index, and
     foods can be bought out of order. Plot_EquipBest() places the best animals.
     PROBED AND DEAD: Throw_Cancel after Resolve keeps nothing (no animal, Throws count unchanged),
     so Complete can't be skipped; throwing while training (server refuses both ways).
     The game auto-starts its own animated training in the bar's circle (and its throw past the line)
     whenever ClientState.Busy is clear, so the farm holds Busy while it runs.
     Movement: hop, held at 74 studs (user asked for TP in chat). Not wired: Throw_UseSuper / SuperThrow (Robux).

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().giveFoodStop() ]]

-- config ---------------------------------------------------------------------
local LINE_BACK = 3 -- studs behind the CrossLine to stand. Lower if Start says TooFar; under 0 starts the game's own throw.
local HOP_SETTLE = 0.15 -- seconds after a hop before Start; 0 gets "TooFar" (the server hasn't seen the move yet)
local START_TRIES = 3 -- seconds to keep retrying Start on TooFar / Cooldown (a short cooldown follows Complete)
local PLACE_EVERY = 5 -- seconds between Equip best calls. Raise if the server ever rate-limits it.
local RETRY = 2 -- seconds after a refused throw. Raise if refusals come in bursts.
local THROW_BURST = 5 -- throws per cycle when training is on too (panel input)
local TRAIN_FOR = 60 -- seconds of training per cycle when throwing is on too (panel input)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().giveFoodStop then
	getgenv().giveFoodStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[givefood]", ...)
end

local note, lastSaid = "idle", nil
local function say(msg)
	note = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

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
assert(fmt(25000) == "25K" and fmt(1500) == "1.5K" and fmt(100) == "100", "fmt")

-- world ----------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
if not Remotes then
	warn("[givefood] ReplicatedStorage.Remotes not found: wrong game?")
	return
end
local Config = ReplicatedStorage:WaitForChild("Config")
local okCfg, StandsConfig, FoodsConfig = pcall(function()
	return require(Config.StandsConfig), require(Config.FoodsConfig)
end)
if not okCfg then
	warn("[givefood] config modules did not load:", StandsConfig)
	return
end

-- The game's busy flag (its line poll and training stand down while set) and its data mirror.
local mods = {}
for _, m in ipairs(player:WaitForChild("PlayerScripts"):GetDescendants()) do
	local want = m.Name == "ClientState" or m.Name == "DataController" or m.Name == "TrainingController"
	if want and m:IsA("ModuleScript") and not mods[m.Name] then
		local ok, mod = pcall(require, m)
		mods[m.Name] = ok and mod or nil
	end
end
local ClientState, DataController, TrainingController = mods.ClientState, mods.DataController, mods.TrainingController
local function data(key)
	local ok, v = pcall(function()
		return DataController:Get(key)
	end)
	return ok and v or nil
end

local function invoke(name, ...)
	local ok, res = pcall(Remotes[name].InvokeServer, Remotes[name], ...)
	if not ok then
		return { Ok = false, Reason = tostring(res) }
	end
	return type(res) == "table" and res or { Ok = false, Reason = tostring(res) }
end

-- Every range-checked call says "TooFar" until the server has seen a hop (and Start says "Cooldown"
-- just after a Complete): retry those for START_TRIES seconds, return anything else at once.
local function invokeNear(name, ...)
	local res
	local untilT = os.clock() + START_TRIES
	repeat
		res = invoke(name, ...)
		if res.Ok or (res.Reason ~= "TooFar" and res.Reason ~= "Cooldown") then
			break
		end
		task.wait(0.15)
	until os.clock() > untilT
	return res
end

local function lineSpot()
	local area = workspace:FindFirstChild("StarterArea")
	local line = area and area:FindFirstChild("CrossLine")
	local z = line and line.Position.Z or (area and area.Position.Z + area.Size.Z / 2) or -40
	return Vector3.new(area and area.Position.X or 0, 0, z + LINE_BACK)
end

local function barSpot()
	local props = workspace:FindFirstChild("LocalPlotProps")
	local spot = props and props:FindFirstChild("TrainingArea") and props.TrainingArea:FindFirstChild("TrainingSpot")
	if not spot then
		return nil
	end
	return spot:IsA("Model") and spot:GetPivot().Position or spot.Position
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

-- Same distance the game moves you itself on every throw (pad <-> plot, 74 studs), so a hop.
local function hopTo(spot)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (root and spot) then
		return false
	end
	if (flat(root.Position) - flat(spot)).Magnitude < 3 then
		return true
	end
	local target = Vector3.new(spot.X, root.Position.Y, spot.Z)
	root.AssemblyLinearVelocity = Vector3.zero
	root.CFrame = CFrame.lookAt(target, target + Vector3.new(0, 0, -1))
	task.wait(HOP_SETTLE)
	return true
end

-- The game's own training starts by itself in the bar's circle and its throw at the line, each
-- locking the character, whenever ClientState.Busy is clear: the farm holds it while it runs.
local function holdGame(alive)
	while ClientState and ClientState.Busy and ClientState.Busy ~= "Zegion" and alive() do
		say("waiting for the game (" .. tostring(ClientState.Busy) .. ")")
		if ClientState.Busy == "Training" and TrainingController then
			pcall(TrainingController.Stop) -- its own exit: camera, movement and the server all reset
		end
		task.wait(0.5)
	end
	if ClientState and alive() then
		ClientState.Busy = "Zegion"
	end
end

local function releaseGame()
	if ClientState and ClientState.Busy == "Zegion" then
		ClientState.Busy = nil
	end
end

-- throw / train --------------------------------------------------------------
local stats = { thrown = 0, refused = 0, placed = 0, bars = 0, foods = 0, last = "-" }
local training = false -- ours: Training_Start said Ok and no Stop since
local tryFood -- defined with the bar below; throwOnce calls it

local function stopTraining()
	if training or player:GetAttribute("Training") then
		invoke("Training_Stop")
	end
	training = false
end

local function throwOnce(alive)
	holdGame(alive)
	stopTraining()
	tryFood(true)
	hopTo(lineSpot())
	local okRun, err = pcall(function()
		local s = invokeNear("Throw_Start")
		if not s.Ok then
			stats.refused += 1
			say("start refused: " .. tostring(s.Reason))
			task.wait(RETRY)
			return
		end
		local r = invoke("Throw_Resolve", 1) -- 1 = the meter's top, a perfect throw
		if not r.Ok then
			stats.refused += 1
			say("resolve refused: " .. tostring(r.Reason))
			invoke("Throw_Cancel")
			task.wait(RETRY)
			return
		end
		local what = ((r.Mutation and r.Mutation ~= "" and r.Mutation .. " ") or "") .. tostring(r.Rarity) .. " " .. tostring(r.DisplayName)
		say(("landing %s at %dm (%s/s)"):format(what, math.floor(r.Distance or 0), fmt(r.Income)))
		local c = invoke("Throw_Complete") -- the server's own ~6s: flight time plus the reveal
		if c.Ok then
			stats.thrown += 1
			stats.last = what .. " " .. fmt(r.Income) .. "/s"
		else
			stats.refused += 1
			say("complete refused: " .. tostring(c.Reason))
		end
	end)
	if not okRun then
		warn("[givefood] throw threw:", err)
		invoke("Throw_Cancel")
		task.wait(RETRY)
	end
end

local buyBar, buyFood = false, false

local function shopSpot()
	local props = workspace:FindFirstChild("LocalPlotProps")
	local shop = props and props:FindFirstChild("FoodShop")
	return shop and shop:GetPivot().Position
end

-- The best food we can buy right now: highest index that is released, not owned and affordable.
local function bestFoodToBuy(money, owned)
	for i = FoodsConfig.CountAll(), 1, -1 do
		local f = FoodsConfig.Get(i)
		if f and not (owned[i] or owned[tostring(i)]) and not FoodsConfig.IsLocked(i) and (f.Price or math.huge) <= money then
			return i, f
		end
	end
	return nil
end

-- Shop_Buy is range-checked against the plot's FoodShop ("TooFar" from the line), so it runs from
-- the farm loop: hop there only when there is something to buy.
function tryFood(hop)
	if not buyFood then
		return
	end
	local idx, food = bestFoodToBuy(tonumber(data("Money")) or 0, data("OwnedFoods") or {})
	if idx and idx > (data("EquippedFood") or 0) then -- only upgrades
		if hop then
			hopTo(shopSpot())
		end
		local res = hop and invokeNear("Shop_Buy", idx) or invoke("Shop_Buy", idx)
		if res.Ok then
			stats.foods += 1
			log("bought food", food.Name, fmt(food.Price))
		else
			log("food refused:", food.Name, res.Reason)
		end
	end
	local best = 0 -- equip the best owned food (one bought by hand counts too)
	for i, v in pairs(data("OwnedFoods") or {}) do
		i = tonumber(i)
		if v and i and i > best then
			best = i
		end
	end
	if best > (data("EquippedFood") or 0) then
		local res = invoke("Shop_Equip", best)
		log("equip food", best, res.Ok and "ok" or tostring(res.Reason))
	end
end

-- Stand_Upgrade is range-checked against the bar ("TooFar" from the line), so it is bought here,
-- while training, standing on it.
local function tryBar()
	local nextBar = buyBar and StandsConfig.Get((data("Stand") or 0) + 1)
	if not (nextBar and (nextBar.Price or math.huge) <= (tonumber(data("Money")) or 0)) then
		return
	end
	local res = invoke("Stand_Upgrade")
	if res.Ok then
		stats.bars += 1 -- no restart: Training_Start while training says "Busy"
		log("bought bar", nextBar.Name, fmt(nextBar.Price))
	else
		log("bar refused:", res.Reason)
	end
end

-- Keeps training running for `seconds`, restarting it if the server ends it.
local function trainFor(seconds, alive)
	local untilT = os.clock() + seconds
	while os.clock() < untilT and alive() do
		holdGame(alive)
		if not (training and player:GetAttribute("Training")) then
			if not hopTo(barSpot()) then
				say("pull-up bar not found")
				task.wait(RETRY)
				continue
			end
			local res = invokeNear("Training_Start")
			training = res.Ok == true
			if not training then
				say("training refused: " .. tostring(res.Reason))
				task.wait(RETRY)
				continue
			end
		end
		say(("training (level %s)"):format(tostring(data("Level") or "?")))
		tryBar()
		tryFood(false) -- the bar is in the shop's range (26 studs): no hop, training keeps going
		task.wait(1)
	end
end

-- One generation counter per toggle: off-then-on inside one wait must not leave the old thread alive.
local function makeLoop(pass)
	local L = { on = false, gen = 0 }
	function L.set(onNow)
		L.on = onNow
		L.gen += 1
		if not onNow then
			return
		end
		local mine = L.gen
		local function alive()
			return L.on and L.gen == mine
		end
		task.spawn(function()
			while alive() do
				local ok, err = pcall(pass, alive)
				if not ok then
					warn("[givefood] pass threw:", err)
					task.wait(RETRY)
				end
			end
		end)
	end
	return L
end

-- Throwing and training share the character and the server refuses one during the other, so one
-- loop owns both and alternates when both are on.
local want = { throw = false, train = false }
local body = makeLoop(function(alive)
	if want.throw and want.train then
		for _ = 1, THROW_BURST do
			if not (alive() and want.throw) then
				break
			end
			throwOnce(alive)
		end
		if alive() and want.train then
			trainFor(TRAIN_FOR, function()
				return alive() and want.train
			end)
		end
	elseif want.throw then
		throwOnce(alive)
	elseif want.train then
		trainFor(5, function()
			return alive() and want.train and not want.throw
		end)
	end
end)

local function setBody(kind, on)
	want[kind] = on
	if kind == "throw" and on then
		task.spawn(invoke, "Player_SetThrowPower", 0) -- 0 is the slider's top: full power, the farthest area
	end
	if kind == "train" and not on then
		task.spawn(stopTraining)
	end
	if want.throw or want.train then
		if not body.on then
			body.set(true)
		end
	else
		body.set(false)
		releaseGame()
		say("stopped")
	end
end

-- upgrades and placing -------------------------------------------------------
local placer = makeLoop(function(alive)
	local res = invoke("Plot_EquipBest")
	if res.Ok and (res.Placed or 0) > 0 then
		stats.placed += res.Placed
		log(("placed %d (plot holds %d best)"):format(res.Placed, res.Count or 0))
	elseif not res.Ok then
		log("equip best refused:", res.Reason)
	end
	local untilT = os.clock() + PLACE_EVERY
	while os.clock() < untilT and alive() do
		task.wait(0.25)
	end
end)

-- Both are bought from the farm loop (range-checked), so a toggle only sets the flag.
local function setBuy(kind, on)
	if kind == "bar" then
		buyBar = on
	else
		buyFood = on
	end
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Give Food for Animals", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "bone")
local Farm = Tab:AddLeftGroupbox("Farm", "target")

Farm:AddToggle("AutoThrow", {
	Text = "Auto perfect throw",
	Tooltip = "Throw back to back from the start line: perfect meter, full power, no animation",
	Default = false,
	Callback = function(state)
		pcall(setBody, "throw", state)
	end,
})

Farm:AddToggle("AutoTrain", {
	Text = "Auto train",
	Tooltip = "Train on your pull-up bar. With auto throw on too, it alternates (the game won't do both at once)",
	Default = false,
	Callback = function(state)
		pcall(setBody, "train", state)
	end,
})

Farm:AddInput("ThrowBurst", {
	Text = "Throws per cycle",
	Tooltip = "With both on: this many throws, then a training block",
	Default = tostring(THROW_BURST),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		THROW_BURST = math.max(1, math.floor(tonumber(text) or THROW_BURST))
	end,
})

Farm:AddInput("TrainFor", {
	Text = "Training seconds per cycle",
	Tooltip = "With both on: how long each training block lasts",
	Default = tostring(TRAIN_FOR),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		TRAIN_FOR = math.max(5, tonumber(text) or TRAIN_FOR)
	end,
})

local Ups = Tab:AddRightGroupbox("Upgrades", "arrow-up")

Ups:AddToggle("AutoBar", {
	Text = "Auto upgrade pull-up bar",
	Tooltip = "Buy the next bar as soon as you can afford it (while auto train has you on the bar: the game wants you standing at it)",
	Default = false,
	Callback = function(state)
		pcall(setBuy, "bar", state)
	end,
})

Ups:AddToggle("AutoFood", {
	Text = "Auto upgrade food",
	Tooltip = "Buy the best food you can afford, equip the best you own (checked between throws and while training)",
	Default = false,
	Callback = function(state)
		pcall(setBuy, "food", state)
	end,
})

Ups:AddToggle("AutoPlace", {
	Text = "Auto place best animals",
	Tooltip = "Equip best every " .. PLACE_EVERY .. "s: your highest-income animals go on the plot",
	Default = false,
	Callback = function(state)
		pcall(placer.set, state)
	end,
})

local conns = {}
local leaderstats = player:WaitForChild("leaderstats", 10)
local function stat(name)
	local v = leaderstats and leaderstats:FindFirstChild(name)
	return v and tostring(v.Value) or "-"
end

local nextStrip = 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	pcall(Window.SetStatus, Window, {
		{ "Cash", stat("Money") },
		{ "Income", stat("Money/s") },
		{ "Level", tostring(data("Level") or "-") },
		{ "Thrown", stats.thrown .. (stats.refused > 0 and (" (" .. stats.refused .. " refused)") or "") },
		{ "Placed", stats.placed },
		{ "Bought", stats.bars .. " bars, " .. stats.foods .. " foods" },
		{ "Last", stats.last },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("GiveFoodForAnimals", {})

local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- close ----------------------------------------------------------------------
local function stopAll()
	want.throw, want.train = false, false
	body.set(false)
	placer.set(false)
	buyBar, buyFood = false, false
	task.spawn(stopTraining)
	releaseGame()
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().giveFoodStop = nil
end)

getgenv().giveFoodStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().giveFoodStop = nil
end
