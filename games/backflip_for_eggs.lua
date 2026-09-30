--[[ Backflip for Eggs -- steal, place, hatch, equip, rebirth, train (88611017452341)

     EGGS    : hops to the best nest egg on any platform, steals it, hops back over the
               Lobby line and the egg is yours ~0.25s later. Nothing walks and the guardian
               never lands (its chase is simulated on OUR client and it reports the catch
               itself). Best = the game's own AnimalConfig.rateOf on the nest's scale and
               mutation, filtered by the rarities ticked and a max hatch time.
     PLACE   : puts held eggs on free ground of your plot (placeEgg, ~0.3s apart). The plot takes
               PLOT_MAX_EGGS (20); once it is full nothing is fired and the farm keeps stealing
               into your hands, uncapped, so the best held egg drops in as each one hatches.
     HATCH   : hatchEgg the moment an egg's timer is up, one at a time.
     EQUIP   : fills free plot slots with your best stored animal, then swaps the worst
               placed one for a better stored one (unequipAnimal -> placeAnimal).
     REBIRTH : requestRebirth as soon as cash covers it (pulls the machine's stored cash first).
     UPGRADE : upgradePlot (+1 animal slot, 10 -> 20) as soon as cash covers PlotConfig.upgradeCost.
               With REBIRTH also on, whichever of the two costs less is bought first.
     TRAIN   : stands on the treadmill belt while nothing else needs you, and claims every
               boost the moment it is offered (about 2x for 2.5s).
     CASH    : hops onto the collection machine pad every 15s. Standing on it IS the collect.
     INDEX   : claimAllRewards when a discovered animal has an unclaimed reward (cash + speed).

     Probed and dead (do not re-probe):
       enterTreadmill from anywhere   pays 0, the server sends treadmillLeft after 5s
       firetouchinterest on the pad   pays 0, only standing on it collects
       hatchEgg before the timer      refused, silently
       requestSendToPlot while carrying  does nothing
       placeEgg/hatchEgg bursts under ~0.3s  drop the later ones
     Not wired (Robux): requestEggSkip, EGG_SKIP_PRODUCTS, REBIRTH_SKIP_PRODUCTS, speed gamepasses.

     Escape rule: the server refuses the claim when your pace is under
     EGG_CLAIM_PACE_FRACTION x the platform guardian's pace ("Too slow! Escaping that guardian
     needs 65B speed"). Platform 10 refused at 484 speed, 1 / 2 / 5 claimed. The script prefilters
     with SpeedConfig and, when the server refuses anyway, parks that platform and every one above it
     until your speed grows PARK_GAIN times.

     RightControl opens / closes the panel. Stop: getgenv().backflipEggsStop() ]]

-- config ---------------------------------------------------------------------
local SETTLE = 0.3 -- after a hop to a nest, before the press. The server reads where it thinks we are. Raise if presses fire and nothing lands
local LIFT = 3 -- studs above a nest part to land: close enough for the prompt, not inside the mesh
local OPEN_DIST = 30 -- what MaxActivationDistance is forced to before pressing. Finite: math.huge THROWS
local PRESS_WAIT = 0.6 -- per press attempt, wait this long for CarryingEgg. Probed: it lands well inside 0.2s
local CLAIM_TIMEOUT = 2.5 -- after the hop home, CarryingEgg must clear inside this. Probed 0.21 to 0.31s
local GAIN_WAIT = 1.0 -- carry cleared, then the inventory must gain the egg inside this or it was refused
local CARRY_MAX = 2 -- eggs held before the farm pauses so Place can drain them. Raise for fewer, longer batches
local BENCH_SECONDS = 20 -- a nest that would not press (taken by someone else) sits out this long
local PARK_GAIN = 1.5 -- a refused platform reopens when speed has grown by this factor
local PACE_MULT = 1.35 -- the chase multiplier the client gives you. Set 1 if a platform the prefilter allows keeps refusing
local PLACE_EQUIP_WAIT = 1 -- wait for EquipTool to land before placing
local PLACE_CONFIRM = 2 -- the held egg must leave the inventory inside this
local PLACE_FAILS = 2 -- consecutive failed placements before placing backs off FULL_HOLD
local FULL_HOLD = 15 -- placing rests this long after a "no room" the egg count did not predict, or until a hatch
local HATCH_GAP = 0.3 -- between hatchEgg calls; a faster burst drops the later ones
local HATCH_CONFIRM = 1.5
local PARK_AFTER = 1.5 -- the treadmill only takes you back after this long with nothing else moving you
local COLLECT_EVERY = 15
local GRID = 4 -- studs between candidate egg spots
local INSET = 8 -- keep spots this far from the plot ground's edge
local SPOT_CLEAR = 3.5 -- the server wants 2.5 between eggs; a little extra
local RATE_EDGE = 1.01 -- a stored animal must beat the worst placed one by this factor to swap
local MAX_HATCH_MIN = 60 -- default cap on an egg's hatch time, in minutes. A 24h egg is a dead slot

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().backflipEggsStop then
	getgenv().backflipEggsStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[backflip]", ...)
end

-- The panel strip is drained from a Heartbeat, which the engine calls with our own identity.
-- A loop thread that writes to the window directly throws "lacking capability Plugin" after
-- its first task.wait.
local pending, lastSaid = nil, nil
local placeOn = false -- Auto Place's switch, read by the farm's carry gate
local function say(msg)
	pending = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg) -- the strip only shows the latest; the console keeps the trail
	end
end

-- game -----------------------------------------------------------------------
local Remotes = ReplicatedStorage.Packages.Networker._remotes
local function ev(name)
	return Remotes[name].RemoteEvent
end

local ok, DS, SpeedConfig, AnimalConfig, EggConfig, RebirthConfig, GameConfig, PlotConfig = pcall(function()
	local libs = ReplicatedStorage.Libraries
	return require(ReplicatedStorage.Packages.DataService).client,
		require(libs.SpeedConfig),
		require(libs.AnimalConfig),
		require(libs.EggConfig),
		require(libs.RebirthConfig),
		require(libs.GameConfig),
		require(libs.PlotConfig)
end)
if not ok then
	warn("[backflip] the game's modules did not load:", DS)
	return
end
local Services = nil
pcall(function()
	Services = require(ReplicatedStorage.Libraries.Services)
end)

local function dget(key)
	local good, v = pcall(function()
		return DS:get(key)
	end)
	return good and v or nil
end

local function count(t)
	local n = 0
	for _ in pairs(t or {}) do
		n += 1
	end
	return n
end

local function wait_until(cond, secs)
	local dl = os.clock() + secs
	while os.clock() < dl do
		if cond() then
			return true
		end
		task.wait(0.03)
	end
	return cond() and true or false
end

local function ticked(values)
	local set = {}
	for k, v in pairs(values) do
		if type(v) == "string" then
			set[v] = true -- list form
		elseif v then
			set[k] = true -- map form
		end
	end
	return set
end
assert(ticked({ "a", "b" }).b and ticked({ a = true }).a and not ticked({ a = false }).a, "ticked reads both shapes")

-- world ----------------------------------------------------------------------
local function char()
	return player.Character
end
local function hrp()
	local c = char()
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function hum()
	local c = char()
	return c and c:FindFirstChildOfClass("Humanoid")
end
local function plotModel()
	local id = player:GetAttribute("PlotId")
	local plots = workspace:FindFirstChild("Plots")
	return plots and id and plots:FindFirstChild(tostring(id))
end
local function ground()
	local plot = plotModel()
	local g = plot and plot:FindFirstChild("Plot", true)
	return g and g:IsA("BasePart") and g or nil
end
local function plotHome() -- lobby side of Workspace.Start (z 66.37): the plot is at z ~12
	local g = ground()
	return g and g.CFrame * CFrame.new(0, g.Size.Y / 2 + 3, 0) or nil
end
local function hop(cf)
	local r = hrp()
	if not (r and cf) then
		return false
	end
	r.CFrame = cf
	r.AssemblyLinearVelocity = Vector3.zero
	return true
end
local function carrying()
	return player:GetAttribute("CarryingEgg")
end
local function plotData()
	return dget("plot") or {}
end
local function plotEggs()
	return plotData().eggs or {}
end
local function plotAnimals()
	return plotData().animals or {}
end
local function eggCount()
	return count(dget("inventory")) -- every held egg is a Tool, this is its data twin
end
local fullUntil = 0 -- set by the server's "no room" and by placements that keep failing
-- The game's own placement preview refuses at PLOT_MAX_EGGS, so read the cap instead of learning
-- it from refusals: every refused placeEgg is a toast on screen.
local function plotFull()
	return count(plotEggs()) >= GameConfig.PLOT_MAX_EGGS or os.clock() < fullUntil
end

-- The one character. Loops that move it, or hold a Tool, take this per pass and never per loop.
local busy = false
local function claim(fn)
	if busy then
		return false
	end
	busy = true
	local good, err = pcall(fn)
	busy = false
	if not good then
		warn("[backflip]", err)
	end
	return true
end
local function withChar(fn, alive)
	local dl = os.clock() + 10
	while not claim(fn) do
		if os.clock() > dl or not alive() then
			return false
		end
		task.wait(0.03)
	end
	return true
end

local lastMove = 0 -- last time a job moved us; the treadmill waits PARK_AFTER past it

local function onBelt()
	local good, on = pcall(function()
		return Services.TreadmillClient:isOnTreadmill()
	end)
	return good and on == true
end
-- The client pins us to the belt every frame, so a hop while pinned is undone at once. Jump is
-- how the game itself lets go.
local function leaveBelt()
	if not onBelt() then
		return
	end
	local h = hum()
	if h then
		h.Jump = true
	end
	if not wait_until(function()
		return not onBelt()
	end, 1.5) then
		warn("[backflip] still pinned to the treadmill after jumping")
	end
end
local function enterBelt()
	local plot = plotModel()
	local belt = plot and plot:FindFirstChild("Treadmill")
	if belt and belt:IsA("BasePart") then
		hop(belt.CFrame * CFrame.new(0, belt.Size.Y / 2 + 3, 0))
		wait_until(onBelt, 2)
	end
end

-- The game's own reasons. "Too slow!" is the escape gate; the rest are for the console.
local tooSlowAt = 0
local collectedAt = 0
local notifyConn, collectConn
local function listen()
	notifyConn = ev("UI").OnClientEvent:Connect(function(a, b, text)
		if a == "triggerEffect" and b == "Notification" and type(text) == "string" then
			log("game says:", text)
			if text:find("Too slow") then
				tooSlowAt = os.clock()
			elseif text:find("no room") then
				fullUntil = os.clock() + FULL_HOLD
			end
		end
	end)
	collectConn = ev("PlotAnimals").OnClientEvent:Connect(function(a)
		if a == "collected" then
			collectedAt = os.clock()
		end
	end)
end

-- scoring --------------------------------------------------------------------
local RARITIES = { "common", "uncommon", "rare", "epic", "legendary", "mythic", "cosmic", "secret", "divine" }
local rarityOn = {}
for _, r in ipairs(RARITIES) do
	rarityOn[r] = true
end
local maxHatch = MAX_HATCH_MIN * 60

local function rateOf(id, scale, mutation, bestOwn)
	local good, r = pcall(AnimalConfig.rateOf, id, scale, bestOwn or 0, mutation or "")
	if good and type(r) == "number" then
		return r
	end
	local a = AnimalConfig.Animals[id]
	return a and (a.cashPerSecond or 0) * (scale or 1) or 0
end

-- Your pace while chased against the platform guardian's, the server's own EGG_CLAIM_PACE_FRACTION
-- rule as far as three probes show. Optimistic on purpose (PACE_MULT): a wrong "yes" costs one
-- refused steal and gets the platform parked, a wrong "no" would silently hide it.
local parked = {} -- platform -> speed at the refusal
local function speedNow()
	return dget("speed") or 0
end
local function claimable(n, speed)
	local p = EggConfig.Platforms[n]
	if not p then
		return false
	end
	local pace = SpeedConfig.walkSpeedFor(speed) * PACE_MULT
	if pace < SpeedConfig.guardianPace(p.guardian) * GameConfig.EGG_CLAIM_PACE_FRACTION then
		return false
	end
	local at = parked[n]
	return not (at and speed < at * PARK_GAIN)
end
do -- the probe's numbers at speed 484: 1, 2 and 5 claimed, 10 was refused
	local s = 484
	if not (claimable(1, s) and claimable(2, s) and claimable(5, s) and not claimable(10, s)) then
		warn("[backflip] the pace rule disagrees with the probe; balance may have changed")
	end
end

local benched = setmetatable({}, { __mode = "k" }) -- nest part -> retry-after

local function nests()
	local out = {}
	local root = workspace:FindFirstChild("EggSpawns")
	if not root then
		return out
	end
	local speed = speedNow()
	local now = os.clock()
	for _, pr in ipairs(root:GetDescendants()) do
		if pr:IsA("ProximityPrompt") and pr.Enabled and pr:GetAttribute("PromptId") == "StealEgg" then
			local part = pr.Parent
			if part and part:IsA("BasePart") and part:GetAttribute("EggState") == "Nest" and (benched[part] or 0) < now then
				local id = part:GetAttribute("EggId")
				local egg = EggConfig.Eggs[id]
				local animal = AnimalConfig.Animals[id]
				local a = part
				while a.Parent and a.Parent ~= root do
					a = a.Parent
				end
				local platform = tonumber(a.Name)
				if egg and animal and platform and rarityOn[animal.rarity] and egg.hatchTime <= maxHatch and claimable(platform, speed) then
					out[#out + 1] = {
						prompt = pr,
						part = part,
						platform = platform,
						id = id,
						score = rateOf(id, part:GetAttribute("EggScale"), part:GetAttribute("EggMutation")),
					}
				end
			end
		end
	end
	table.sort(out, function(x, y)
		return x.score > y.score
	end)
	return out
end

-- farm -----------------------------------------------------------------------
local stats = { stolen = 0, refused = 0, placed = 0, hatched = 0, swaps = 0, rebirths = 0, boosts = 0, upgrades = 0 }

local function stealOne(t)
	leaveBelt()
	if carrying() then -- a leftover carry; bank it before anything else
		hop(plotHome())
		wait_until(function()
			return not carrying()
		end, CLAIM_TIMEOUT)
	end
	local before = eggCount()
	local t0 = os.clock()
	if not hop(t.part.CFrame * CFrame.new(0, LIFT, 0)) then
		return "nochar"
	end
	task.wait(SETTLE)
	wait_until(function()
		return not player.GameplayPaused
	end, 3)
	local pr = t.prompt
	pcall(function()
		pr.RequiresLineOfSight = false
		pr.MaxActivationDistance = OPEN_DIST
	end)
	local got = false
	for _, how in ipairs({ "fire", "fire", "hold" }) do
		if how == "fire" then
			pcall(fireproximityprompt, pr)
		else
			pcall(function()
				pr:InputHoldBegin()
				task.wait(pr.HoldDuration + 0.15)
				pr:InputHoldEnd()
			end)
		end
		if wait_until(carrying, PRESS_WAIT) then
			got = true
			break
		end
	end
	if not got then
		hop(plotHome())
		return "nopress"
	end
	hop(plotHome())
	wait_until(function()
		return not carrying()
	end, CLAIM_TIMEOUT)
	if wait_until(function()
		return eggCount() > before
	end, GAIN_WAIT) then
		return "ok"
	end
	return tooSlowAt >= t0 and "slow" or "refused"
end

local function farmStep(alive)
	-- The pause only exists so Place can drain the hands. With Place off, or a full plot, nothing
	-- drains them, so the farm never stops: the hands become the queue, and Place drops the best
	-- of it in as each placed egg hatches.
	local held = eggCount()
	if placeOn and not plotFull() and held >= CARRY_MAX then
		say("holding " .. held .. " eggs, placing them")
		return 0.3
	end
	local list = nests()
	local t = list[1]
	if not t then
		say("no eligible nest (rarity, hatch cap or speed)")
		return 1
	end
	local res
	if not claim(function()
		res = stealOne(t)
	end) then
		return 0.05
	end
	lastMove = os.clock()
	if res == "ok" then
		stats.stolen += 1
		say(("stole %s (p%d) x%d"):format(t.id, t.platform, stats.stolen))
	elseif res == "slow" then
		stats.refused += 1
		local speed = speedNow()
		for p = t.platform, #EggConfig.Platforms do
			parked[p] = speed
		end
		say(("platform %d and up need more speed than %s"):format(t.platform, tostring(math.floor(speed))))
	elseif res == "nopress" or res == "refused" then
		benched[t.part] = os.clock() + BENCH_SECONDS
	end
	return 0.05
end

-- plot -----------------------------------------------------------------------
-- Egg spots are stored as x/z LOCAL to the ground part, so free space can be read straight off
-- the data instead of raycasting the plot.
local function freeSpot()
	local g = ground()
	if not g then
		return nil
	end
	local occupied = {}
	for _, e in pairs(plotEggs()) do
		if e.x and e.z then
			occupied[#occupied + 1] = Vector2.new(e.x, e.z)
		end
	end
	local hx, hz = g.Size.X / 2 - INSET, g.Size.Z / 2 - INSET
	local spots = {}
	for x = -hx, hx, GRID do
		for z = -hz, hz, GRID do
			spots[#spots + 1] = Vector2.new(x, z)
		end
	end
	for i = #spots, 2, -1 do
		local j = math.random(i)
		spots[i], spots[j] = spots[j], spots[i]
	end
	for _, s in ipairs(spots) do
		local free = true
		for _, o in ipairs(occupied) do
			if (o - s).Magnitude < SPOT_CLEAR then
				free = false
				break
			end
		end
		if free then
			return g.CFrame:PointToWorldSpace(Vector3.new(s.X, g.Size.Y / 2, s.Y))
		end
	end
	return nil
end

local function toolsWith(attr)
	local out = {}
	for _, where in ipairs({ player:FindFirstChildOfClass("Backpack"), char() }) do
		if where then
			for _, t in ipairs(where:GetChildren()) do
				if t:IsA("Tool") and t:GetAttribute(attr) then
					out[#out + 1] = t
				end
			end
		end
	end
	return out
end

local function equip(tool)
	local h = hum()
	if not h then
		return false
	end
	pcall(h.EquipTool, h, tool)
	wait_until(function()
		return tool.Parent == char()
	end, PLACE_EQUIP_WAIT)
	task.wait(0.1)
	return tool.Parent == char()
end

local function placeOne(tool)
	local key = tool:GetAttribute("EggKey")
	local spot = freeSpot()
	if not (spot and equip(tool)) then
		return false
	end
	ev("PlotEggs"):FireServer("placeEgg", spot, tool)
	return wait_until(function()
		local inv = dget("inventory")
		return not (inv and inv[key])
	end, PLACE_CONFIRM)
end

local placeFails = 0
local function placeStep(alive)
	if plotFull() then
		return 0.5
	end
	local tools = toolsWith("EggId")
	if #tools == 0 then
		return 0.4
	end
	table.sort(tools, function(a, b) -- best first: the plot may only have room for some
		return rateOf(a:GetAttribute("EggId"), a:GetAttribute("EggScale"), a:GetAttribute("EggMutation"))
			> rateOf(b:GetAttribute("EggId"), b:GetAttribute("EggScale"), b:GetAttribute("EggMutation"))
	end)
	withChar(function()
		for _, tool in ipairs(tools) do
			if not alive() or plotFull() then
				break
			end
			if placeOne(tool) then
				placeFails = 0
				stats.placed += 1
				say("placed " .. tostring(tool:GetAttribute("EggId")))
			else
				placeFails += 1
				if placeFails >= PLACE_FAILS then
					placeFails = 0
					fullUntil = os.clock() + FULL_HOLD
					say(("placing keeps failing with %d/%d on the plot, resting %ds"):format(count(plotEggs()), GameConfig.PLOT_MAX_EGGS, FULL_HOLD))
					break
				end
			end
			task.wait(0.05)
		end
	end, alive)
	return 0.2
end

local hatchBench = {}
local function hatchStep(alive)
	local now = workspace:GetServerTimeNow()
	local ready = {}
	for id, e in pairs(plotEggs()) do
		if type(e.hatchAt) == "number" and e.hatchAt <= now and (hatchBench[id] or 0) < os.clock() then
			ready[#ready + 1] = id
		end
	end
	if #ready == 0 then
		return 0.5
	end
	withChar(function()
		for _, id in ipairs(ready) do
			if not alive() then
				break
			end
			for _ = 1, 2 do
				ev("PlotEggs"):FireServer("hatchEgg", id)
				if wait_until(function()
					return plotEggs()[id] == nil
				end, HATCH_CONFIRM) then
					stats.hatched += 1
					fullUntil = 0
					break
				end
				task.wait(HATCH_GAP)
			end
			if plotEggs()[id] then
				hatchBench[id] = os.clock() + 5
			end
			task.wait(HATCH_GAP)
		end
	end, alive)
	return 0.2
end

-- The rate ranking of stored vs placed animals uses the game's own formula. Mimics read the
-- best own rate, so it is taken from the placed set.
local function ranked(t, bestOwn)
	local out = {}
	for key, a in pairs(t) do
		out[#out + 1] = { key = key, a = a, r = rateOf(a.animalId, a.scale, a.mutation, bestOwn) }
	end
	table.sort(out, function(x, y)
		return x.r > y.r
	end)
	return out
end
local function animalTool(key)
	for _, t in ipairs(toolsWith("AnimalKey")) do
		if t:GetAttribute("AnimalKey") == key then
			return t
		end
	end
	return nil
end
local function placeAnimal(key)
	local tool = animalTool(key)
	local spot = freeSpot()
	if not (tool and spot and equip(tool)) then
		return false
	end
	ev("AnimalTools"):FireServer("placeAnimal", spot, tool)
	return wait_until(function()
		return plotAnimals()[key] ~= nil
	end, PLACE_CONFIRM)
end

local function equipStep(alive)
	local stored = dget("storedAnimals") or {}
	if next(stored) == nil then
		return 1
	end
	local plot = plotModel()
	local cap = plot and plot:GetAttribute("Capacity") or 0
	local placed = plotAnimals()
	local bestOwn = 0
	pcall(function()
		bestOwn = AnimalConfig.bestOwnRate(placed)
	end)
	local best = ranked(stored, bestOwn)[1]
	local mine = ranked(placed, bestOwn)
	local worst = mine[#mine]
	withChar(function()
		if #mine < cap then
			if placeAnimal(best.key) then
				stats.swaps += 1
				say("placed " .. best.a.animalId)
			end
		elseif worst and best.r > worst.r * RATE_EDGE then
			ev("AnimalInventory"):FireServer("unequipAnimal", worst.key)
			if wait_until(function()
				return animalTool(worst.key) ~= nil
			end, 2) and placeAnimal(best.key) then
				stats.swaps += 1
				say(("swapped %s for %s"):format(worst.a.animalId, best.a.animalId))
			end
		end
	end, alive)
	return 1
end

-- progress -------------------------------------------------------------------
local lastCollect = 0
local function storedCash()
	local plot = plotModel()
	if not plot then
		return 0
	end
	local base, at, rate = plot:GetAttribute("MachineBase"), plot:GetAttribute("MachineBaseAt"), plot:GetAttribute("MachineRate")
	if type(base) ~= "number" or type(at) ~= "number" or type(rate) ~= "number" then
		return 0
	end
	return base + rate * (workspace:GetServerTimeNow() - at)
end

local function collectNow(alive)
	local plot = plotModel()
	local machine = plot and plot:FindFirstChild("CollectionMachine")
	local pad = machine and machine:FindFirstChild("Collect")
	if not (pad and pad:IsA("BasePart")) then
		return
	end
	withChar(function()
		leaveBelt()
		local t0 = os.clock()
		hop(pad.CFrame * CFrame.new(0, pad.Size.Y / 2 + 3, 0)) -- standing on it is the collect
		wait_until(function()
			return collectedAt >= t0
		end, 1)
		hop(plotHome())
		lastMove = os.clock()
	end, alive)
	lastCollect = os.clock()
end

local function collectStep(alive)
	if os.clock() - lastCollect >= COLLECT_EVERY then
		collectNow(alive)
	end
	return 1
end

-- Rebirth and Upgrade spend one wallet. With both on, whichever costs less right now goes first:
-- early that is plot slots (10k, 100k, ...), once they outprice a rebirth it is rebirths.
local rebirthOn, upgradeOn = false, false
local function rebirthCost()
	local rb = dget("rebirths") or 0
	return not RebirthConfig.isMax(rb) and RebirthConfig.costFor(rb) or nil, rb
end
local function plotCap(plot)
	local cap = plot:GetAttribute("Capacity")
	if type(cap) ~= "number" or cap < 1 then
		return GameConfig.PLOT_CAPACITY_DEFAULT -- what the game's own upgrade button assumes
	end
	return math.floor(cap)
end
local function upgradeCost()
	local plot = plotModel()
	return plot and PlotConfig.upgradeCost(plotCap(plot)) or nil
end
local function outbid(mine, theirs, theirOn) -- the other purchase is on and cheaper: wait for it
	return theirOn and theirs ~= nil and theirs < mine
end
assert(outbid(100, 10, true) and not outbid(100, 10, false) and not outbid(10, 100, true) and not outbid(10, nil, true), "outbid")

local function rebirthStep(alive)
	local cost, rb = rebirthCost()
	if not cost then
		say("max rebirths")
		return 5
	end
	if outbid(cost, upgradeCost(), upgradeOn) then
		return 1
	end
	local cash = dget("cash") or 0
	if cash < cost and cash + storedCash() >= cost and os.clock() - lastCollect > 2 then
		collectNow(alive)
		cash = dget("cash") or 0
	end
	if cash >= cost then
		ev("Rebirth"):FireServer("requestRebirth")
		if wait_until(function()
			return (dget("rebirths") or 0) > rb
		end, 3) then
			stats.rebirths += 1
			say("rebirthed to " .. (rb + 1))
		end
	end
	return 1
end

local function upgradeStep(alive)
	local plot = plotModel()
	if not plot then
		return 2
	end
	local cap = plotCap(plot)
	local cost = PlotConfig.upgradeCost(cap)
	if not cost then
		say("plot at max capacity")
		return 10
	end
	if outbid(cost, rebirthCost(), rebirthOn) then
		return 1
	end
	if (dget("cash") or 0) >= cost then
		ev("PlotUpgrades"):FireServer("upgradePlot")
		if wait_until(function()
			return plotCap(plot) > cap
		end, 3) then
			stats.upgrades += 1
			say(("plot capacity %d -> %d"):format(cap, cap + 1))
		end
	end
	return 1
end

local boostConn
local function trainStep(alive)
	if os.clock() - lastMove < PARK_AFTER or busy or onBelt() then
		return 0.4
	end
	claim(enterBelt)
	return 0.5
end

local function indexStep(alive)
	local disc, claimed = dget("discoveredAnimals") or {}, dget("claimedAnimalRewards") or {}
	for id in pairs(disc) do
		local a = AnimalConfig.Animals[id]
		if a and a.reward and not claimed[id] then
			ev("Index"):FireServer("claimAllRewards")
			task.wait(1)
			break
		end
	end
	return 3
end

-- toggles --------------------------------------------------------------------
-- One generation counter per toggle: off-then-on inside one wait must not leave the sleeping
-- thread alive, and a stale thread must never act after its toggle went off.
local function loop(name, step)
	local on, gen = false, 0
	return function(state)
		on = state
		gen += 1
		local mine = gen
		if not state then
			return
		end
		local function alive()
			return on and gen == mine
		end
		task.spawn(function()
			while alive() do
				local good, wait = pcall(step, alive)
				if not good then
					warn("[backflip] " .. name .. ":", wait)
					wait = 2
				end
				task.wait(wait or 0.25)
			end
		end)
	end
end

local setFarm = loop("farm", farmStep)
local setPlaceLoop = loop("place", placeStep)
local function setPlace(state)
	placeOn = state
	setPlaceLoop(state)
end
local setHatch = loop("hatch", hatchStep)
local setEquip = loop("equip", equipStep)
local setRebirthLoop = loop("rebirth", rebirthStep)
local function setRebirth(state)
	rebirthOn = state
	setRebirthLoop(state)
end
local setUpgradeLoop = loop("upgrade", upgradeStep)
local function setUpgrade(state)
	upgradeOn = state
	setUpgradeLoop(state)
end
local setCollect = loop("collect", collectStep)
local setIndex = loop("index", indexStep)
local setTrainLoop = loop("train", trainStep)

local function setTrain(state)
	if boostConn then
		boostConn:Disconnect()
		boostConn = nil
	end
	if state then
		boostConn = ev("Treadmill").OnClientEvent:Connect(function(m)
			if m == "boostOffered" then
				ev("Treadmill"):FireServer("claimBoost")
				stats.boosts += 1
			end
		end)
	elseif onBelt() then
		task.spawn(function()
			withChar(leaveBelt, function()
				return true
			end)
		end)
	end
	setTrainLoop(state)
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Backflip for Eggs", size = UDim2.fromOffset(560, 430), statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "egg")
local Eggs = Tab:AddLeftGroupbox("Eggs", "egg")
local Progress = Tab:AddRightGroupbox("Progress", "trending-up")

Eggs:AddToggle("Farm", {
	Text = "Auto Farm Egg",
	Tooltip = "Hops to the best nest egg, steals it and hops over the Lobby line to bank it. A platform whose guardian outpaces you is skipped and retried as your speed grows",
	Default = false,
	Callback = setFarm,
})
local rarityNames = {}
for _, r in ipairs(RARITIES) do
	rarityNames[#rarityNames + 1] = r:sub(1, 1):upper() .. r:sub(2)
end
Eggs:AddDropdown("Rarity", {
	Text = "Rarities to take",
	Tooltip = "Rarity of the animal the egg hatches into. Within the ticked ones the highest cash per second goes first",
	Values = rarityNames,
	Default = rarityNames,
	Multi = true,
	Callback = function(picked)
		table.clear(rarityOn)
		for name in pairs(ticked(picked)) do
			rarityOn[name:lower()] = true
		end
	end,
})
Eggs:AddInput("MaxHatch", {
	Text = "Max hatch (minutes)",
	Tooltip = "Skips eggs that take longer than this to hatch. The rarest ones run to 24 hours and would sit in a slot all day",
	Default = tostring(MAX_HATCH_MIN),
	Numeric = true,
	Finished = true,
	Placeholder = "60",
	Callback = function(v)
		maxHatch = math.max(0, tonumber(v) or MAX_HATCH_MIN) * 60
	end,
})
Eggs:AddToggle("Place", {
	Text = "Auto Place Egg",
	Tooltip = "Puts held eggs on free ground of your plot, one at a time. Pauses the farm's next steal while it works",
	Default = false,
	Callback = setPlace,
})
Eggs:AddToggle("Hatch", {
	Text = "Auto Hatch Egg",
	Tooltip = "Hatches each egg the moment its timer is up. Hatching early is refused by the server",
	Default = false,
	Callback = setHatch,
})
Eggs:AddToggle("Equip", {
	Text = "Auto Equip Best",
	Tooltip = "Fills free plot slots with your best stored animal, then swaps a better stored one in for the worst placed one",
	Default = false,
	Callback = setEquip,
})

Progress:AddToggle("Rebirth", {
	Text = "Auto Rebirth",
	Tooltip = "Rebirths as soon as cash covers it, collecting the machine's stored cash first. A rebirth resets cash only",
	Default = false,
	Callback = setRebirth,
})
Progress:AddToggle("Upgrade", {
	Text = "Auto Upgrade Plot",
	Tooltip = "Buys +1 animal slot (up to 20) as soon as cash covers it. With Auto Rebirth also on, the cheaper of the two is bought first",
	Default = false,
	Callback = setUpgrade,
})
Progress:AddToggle("Train", {
	Text = "Auto Train",
	Tooltip = "Stands on the treadmill belt whenever nothing else needs you, and claims every boost as it is offered",
	Default = false,
	Callback = setTrain,
})
Progress:AddToggle("Collect", {
	Text = "Auto Collect Cash",
	Tooltip = "Steps onto the collection machine pad every 15s. Standing on it is the collect",
	Default = false,
	Callback = setCollect,
})
Progress:AddToggle("Index", {
	Text = "Auto Index Reward",
	Tooltip = "Claims index rewards (cash and speed) once a discovered animal has one waiting",
	Default = false,
	Callback = setIndex,
})

-- "2 held, 20/20 placed, hatch 4m": a full plot is only a stall worth reading if you can see
-- when it ends.
local function eggStatus()
	local placed, soonest = 0, math.huge
	for _, e in pairs(plotEggs()) do
		placed += 1
		if type(e.hatchAt) == "number" then
			soonest = math.min(soonest, e.hatchAt)
		end
	end
	local s = ("%d held, %d/%d placed"):format(eggCount(), placed, GameConfig.PLOT_MAX_EGGS)
	if soonest < math.huge then
		local left = math.max(0, math.floor(soonest - workspace:GetServerTimeNow())) -- %d throws on a fraction
		s ..= left < 60 and (", hatch %ds"):format(left) or (", hatch %dm"):format(math.ceil(left / 60))
	end
	return s
end

local conns = {}
local note = "idle"
local nextStrip = 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	if pending then
		note, pending = pending, nil
	end
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	Window:SetStatus({
		{ "Speed", math.floor(speedNow()) },
		{ "Cash", math.floor(dget("cash") or 0) },
		{ "Rebirths", dget("rebirths") or 0 },
		{ "Eggs", eggStatus() },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

listen()

-- last, so the autoload finds every control
Window:AddSettingsTab("BackflipForEggs", {})

local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- close ----------------------------------------------------------------------
local function stopAll()
	setFarm(false)
	setPlace(false)
	setHatch(false)
	setEquip(false)
	setRebirth(false)
	setUpgrade(false)
	setCollect(false)
	setIndex(false)
	setTrain(false) -- also lets go of the belt
	for _, c in ipairs({ notifyConn, collectConn }) do
		if c then
			c:Disconnect()
		end
	end
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().backflipEggsStop = nil
end)

getgenv().backflipEggsStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().backflipEggsStop = nil
end
