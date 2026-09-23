--[[ Build to Kill Zombie -- drive, hunt, roll, buy, upgrade, repeat (105011592530400)

     FARM   : launch, drive, return, repeat. The car is driven by the game's own physics
              step off Humanoid.MoveDirection (the path its mobile thumbstick uses), so the
              steering here is a real input, not a teleport -- the server's speed validator
              (RunValidationConfig: strikes end the run) never sees anything a hand wouldn't.
              Cash is 4 per 10 studs of validated distance plus CashPerKill per zombie.
     HUNT   : steers toward zombies AHEAD of you inside a forward cone, never back for one --
              every stud you drive is also cash, so a zombie behind you is a zombie missed.
              Priority picks which one: densest pack (default), furthest, nearest, richest.
              Walls and other cars are probed ahead and steered around; a car that stops
              moving reverses out; a run whose fuel is gone ends and relaunches by itself.
     NITRO  : holds the game's own Nitro button (its InputBegan handler) while the tank is
              full enough, and lets go before it runs dry. Only if your car has a Turbo part.
     ROLL   : presses Roll at your plot's stations until an item worth stopping for lands.
              Rolling is FREE (the price is on the Buy prompt, not the lever), so auto-roll on
              its own never spends a coin -- it stops at the first item >= "Stop at" and waits.
     BUY    : buys the displayed item when its rarity is ticked, or when it's a part your next
              blueprint is missing, and only when CashValue covers PartCatalog.Cost. Never
              short: an unaffordable Buy is the server's cue to offer the Robux InstantBuy.
     BUILD  : spawns the best blueprint you own every part for, if it's worth more than the
              car you have (sum of part costs). Off by default -- it replaces your build.
     SKILLS : buys the cheapest affordable skill-tree node in the branches you tick.
     REWARDS: weekly quests, offline earnings, the group chest, every live code.
     BOSS   : joins the battle when the alert opens; in battle, drives at the boss and
              detours for fuel cans when the tank runs low.

     Everything talks to the game through its own Packets module (one RemoteEvent, binary
     packets); the roll and buy stations are server-side ProximityPrompts.

     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().killZombieStop() ]]

-- config ---------------------------------------------------------------------
-- Steering. The planner picks an aim point at PLAN_BEAT; the steer runs every frame.
local PLAN_BEAT = 0.1
local LOOKAHEAD = 120 -- studs ahead along the run axis for the no-target aim point
-- StageConfig.CorridorHalfWidth is 400 around RouteOrigin; stay inside it with margin, a
-- car hugging the edge of the streamed corridor drives into terrain that isn't there yet.
local CORRIDOR = 320
-- steer = sin(heading error) * gain, clamped. Raise if it drifts wide of targets, lower if
-- it weaves -- the game's own turn rate already scales with speed.
local STEER_GAIN = 2.2

-- Hunting window. A zombie counts only if it's AHEAD_MIN..AHEAD_MAX studs ahead and no more
-- than CONE studs sideways per stud ahead (0.9 is about 42 degrees): sharp turns cost more
-- distance-cash than a 5-25 cash kill pays early on.
local AHEAD_MIN = 12
local AHEAD_MAX = 260
local CONE = 0.9
local CLUSTER = 25 -- radius a "densest" target counts neighbours in

-- Obstacles. Probe length grows with speed; a blocked probe swings the aim for AVOID_HOLD.
local PROBE_BASE = 18
local PROBE_PER_SPEED = 0.6
local AVOID_HOLD = 0.6

-- Unstick: slower than STUCK_SPEED for STUCK_TIME while the game is actually pushing us
-- (DriveForce non-zero) -> reverse for REVERSE_TIME with the wheel the other way.
local STUCK_SPEED = 3
local STUCK_TIME = 1.5
local REVERSE_TIME = 1.2

-- End of run: out of fuel and slower than END_SPEED for END_HOLD, or no validated distance
-- gained for GIVE_UP seconds whatever the fuel says (a wedged car shouldn't farm nothing).
local END_SPEED = 2
local END_HOLD = 2
local GIVE_UP = 25

local LAUNCH_TIMEOUT = 10 -- seconds from SpawnCar to sitting in the driver seat
local RETURN_TIMEOUT = 8
local LAUNCH_STRIKES = 3 -- refused launches in a row before the farm stops and says why
local SHOP_WINDOW = 20 -- most seconds the farm waits between runs for auto-roll to finish

-- Roll/buy stations. Both prompts have MaxActivationDistance 5, so we stand on the part.
local SETTLE = 0.25 -- after the hop, for the position to replicate before the press
local ROLL_CONFIRM = 3 -- waiting for our RollSpin (a Legendary+ skip asks first)
local DISPLAY_SLACK = 3 -- on top of the spin duration, waiting for RollDisplay
local BUY_CONFIRM = 3

local NITRO_ON = 0.6 -- press when the tank is at least this full
local NITRO_OFF = 0.05 -- let go here; at 0 the game locks nitro until you release anyway

local FUEL_LOW = 0.4 -- in battle, detour for a fuel can below this fraction of the tank
local SKILL_POLL = 3
local QUEST_POLL = 60 -- the server pushes QuestsChanged on progress; this is only a resync
local BOSS_POLL = 1

local AFK_BEAT = 60
local REJOIN_DELAY = 3
local WATCHDOG = 30

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer

if getgenv and getgenv().killZombieStop then
	getgenv().killZombieStop() -- re-running must not stack a second panel or loop
end

local running = true

local function log(msg)
	print("[btkz] " .. msg)
end

local pending -- last thing a loop thread wanted on the status row; drained on Heartbeat
local function say(msg)
	pending = msg
end

local mark, markAt = "idle", os.clock()
local function step(what)
	mark, markAt = what, os.clock()
end

-- world ----------------------------------------------------------------------
-- Every packet the game uses is one require away, and the module cache is shared, so these
-- are the same objects its controllers hold: ids line up by construction.
local okP, Packets = pcall(function()
	return require(ReplicatedStorage:WaitForChild("Packages", 10):WaitForChild("Packets", 10))
end)
if not okP or type(Packets) ~= "table" or not Packets.SpawnCar then
	warn("[btkz] Packages.Packets didn't load -- wrong game, or the client hasn't booted yet")
	return
end

local Data = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data")
local function need(name)
	local ok, m = pcall(require, Data:WaitForChild(name, 10))
	if not ok then
		warn("[btkz] couldn't require " .. name .. ": " .. tostring(m))
	end
	return ok and m or nil
end
local PartCatalog = need("PartCatalog")
local ZombieConfig = need("ZombieConfig")
local RollConfig = need("RollConfig")
local SkillConfig = need("SkillConfig")
local QuestConfig = need("QuestConfig")
local CodesConfig = need("CodesConfig")
local BlueprintConfig = need("BlueprintConfig")
local GamepassConfig = need("GamepassConfig")
if not (PartCatalog and ZombieConfig and RollConfig) then
	return
end

-- Controllers are only nice-to-have: BuildController for the inventory (blueprints),
-- UIController to close a confirm dialog we answered ourselves.
local function controller(name)
	local ok, m = pcall(function()
		return require(ReplicatedStorage.Controllers[name])
	end)
	return ok and type(m) == "table" and m or nil
end
local BuildController = controller("BuildController")
local UIController = controller("UIController")

local RARITIES = PartCatalog.Rarities -- Common .. Secret, the order every filter ranks by
local RANK = {}
for i, r in ipairs(RARITIES) do
	RANK[r] = i
end

local conns = {} -- packet + instance connections; all dropped in stopAll
local function on(name, fn)
	local p = Packets[name]
	if not (p and p.OnClientEvent) then
		warn("[btkz] no packet " .. name .. " -- the game renamed it")
		return
	end
	table.insert(
		conns,
		p.OnClientEvent:Connect(function(...)
			local ok, err = pcall(fn, ...)
			if not ok then
				warn("[btkz] " .. name .. " handler: " .. tostring(err))
			end
		end)
	)
end

local function fire(name, ...)
	local p = Packets[name]
	if not p then
		warn("[btkz] no packet " .. name)
		return false
	end
	return pcall(p.Fire, p, ...)
end

-- Response packets yield until the server answers and have no timeout we can trust; a
-- parked thread looks exactly like a dead one, so give up on a clock instead.
local function callTimed(fn, timeout)
	local done, res = false, nil
	task.spawn(function()
		local ok, r = pcall(fn)
		res = ok and r or nil
		done = true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < timeout do
		task.wait()
	end
	return done, res
end

local function cash()
	local v = player:FindFirstChild("CashValue")
	return v and v.Value or 0
end

local function humanoid()
	local c = player.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

local function rootPart()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function flat(v)
	local f = Vector3.new(v.X, 0, v.Z)
	if f.Magnitude < 1e-3 then
		return nil
	end
	return f.Unit
end

local function myCar()
	local cars = workspace:FindFirstChild("Cars")
	if not cars then
		return nil
	end
	for _, m in ipairs(cars:GetChildren()) do
		if m:IsA("Model") and m:GetAttribute("DriverUserId") == player.UserId then
			return m
		end
	end
	return nil
end

local function seatedIn(car, hum)
	local seat = hum and hum.SeatPart
	return seat ~= nil and seat.Name == "DriverSeat" and seat:IsDescendantOf(car)
end

local plotCache
local function myPlot()
	if plotCache and plotCache.Parent and plotCache:GetAttribute("OwnerUserId") == player.UserId then
		return plotCache
	end
	plotCache = nil
	local game_ = workspace:FindFirstChild("Game")
	local plots = game_ and game_:FindFirstChild("Lobby") and game_.Lobby:FindFirstChild("Plots")
	for _, p in ipairs(plots and plots:GetChildren() or {}) do
		if p:GetAttribute("OwnerUserId") == player.UserId then
			plotCache = p
			return p
		end
	end
	return nil
end

-- zombies --------------------------------------------------------------------
-- A mirror of the server's zombie list, decoded from the same buffers ZombieController
-- reads (its table is a local). Snapshot/Moves/Spawned/Died, one clock with the game's.
local zombies = {} -- id -> { pos, cash }
local stats = { runs = 0, kills = 0, killCash = 0, runCash = 0, best = 0, bought = 0, rolls = 0 }

local function addZombie(id, variant, pos)
	local name = ZombieConfig.VariantOrder[variant]
	local def = name and ZombieConfig.Variants[name]
	zombies[id] = { pos = pos, cash = def and def.CashPerKill or 0 }
end

on("ZombieSnapshot", function(buf)
	table.clear(zombies)
	local o = 2
	for _ = 1, buffer.readu16(buf, 0) do
		local pos = Vector3.new(buffer.readf32(buf, o + 3), buffer.readf32(buf, o + 7), buffer.readf32(buf, o + 11))
		addZombie(buffer.readu16(buf, o), buffer.readu8(buf, o + 2), pos)
		o += 25 -- u16 id, u8 variant, 3xf32 pos, u8 yaw, u8 hp, f64 appear
	end
end)
on("ZombieMoves", function(buf)
	local o = 2
	for _ = 1, buffer.readu16(buf, 0) do
		local z = zombies[buffer.readu16(buf, o)]
		if z then
			z.pos = Vector3.new(buffer.readf32(buf, o + 2), buffer.readf32(buf, o + 6), buffer.readf32(buf, o + 10))
		end
		o += 15 -- u16 id, 3xf32 pos, u8 yaw
	end
end)
on("ZombieSpawned", function(id, variant, pos)
	addZombie(id, variant, pos)
end)
on("ZombieDied", function(id, killer, reward)
	zombies[id] = nil
	if killer == player.UserId and reward > 0 then
		stats.kills += 1
		stats.killCash += reward
	end
end)
-- We connected after the game's own ZombieSync, so ask again: the server re-sends the
-- snapshot to both listeners, and the game's controller just rebuilds what it had.
fire("ZombieSync")

-- Boss battle mirror: the boss position and the fuel cans that only spawn in battle.
local bosses, fuels = {}, {}
local function vecArg(...)
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if typeof(v) == "Vector3" then
			return v
		end
	end
	return nil
end
on("BossSpawned", function(id, ...)
	bosses[id] = vecArg(...)
end)
on("BossState", function(id, ...)
	bosses[id] = vecArg(...) or bosses[id]
end)
on("BossRemoved", function(id)
	bosses[id] = nil
end)
on("FuelSpawned", function(id, pos)
	fuels[id] = pos
end)
on("FuelCollected", function(id)
	fuels[id] = nil
end)
on("FuelRemoved", function(id)
	fuels[id] = nil
end)

-- drive ----------------------------------------------------------------------
-- Pure steering: throttle and wheel for a flat look/right basis and a flat unit direction
-- to the aim. Anything behind is a full-lock U-turn forward -- reverse top speed is 0.4x.
local function steerTo(look, right, to)
	local fwd, side = look:Dot(to), right:Dot(to)
	if fwd < 0 then
		return 1, side >= 0 and 1 or -1
	end
	return 1, math.clamp(side * STEER_GAIN, -1, 1)
end
do
	local L, R = Vector3.new(1, 0, 0), Vector3.new(0, 0, 1)
	local t, s = steerTo(L, R, L)
	assert(t == 1 and s == 0, "straight ahead steers straight")
	t, s = steerTo(L, R, Vector3.new(1, 0, 1).Unit)
	assert(t == 1 and s > 0, "target to the right steers right")
	t, s = steerTo(L, R, Vector3.new(-1, 0, -0.1).Unit)
	assert(t == 1 and s == -1, "target behind-left is a full left U-turn")
end

local farm = { on = false, gen = 0, strikes = 0, blueprint = false }
local drive = {
	manual = false, -- steer whenever you're in your car, without the launch loop
	hunt = true,
	priority = "Densest ahead",
	nitro = false,
	aim = nil,
	target = nil,
	reverseUntil = 0,
	reverseSteer = 1,
	avoidUntil = 0,
	avoidDir = nil,
	stuckFor = 0,
	lastS = 0,
	nitroHeld = false,
	gen = 0,
}

local function driving()
	return drive.manual or farm.on
end

-- The Move lands in MoveDirection, which CarController's PhysicsStep reads on PreSimulation.
-- Bound one priority after the ControlModule so its per-frame zero doesn't win the frame.
local STEER_BIND = "ZegionKillZombieSteer"
local function steerFrame()
	if not driving() then
		return
	end
	local car, hum = myCar(), humanoid()
	local chassis = car and car.PrimaryPart
	if not (chassis and seatedIn(car, hum) and drive.aim) then
		return
	end
	local cf = chassis.CFrame
	local look, right = flat(cf.LookVector), flat(cf.RightVector)
	if not (look and right) then
		return
	end
	local t, s
	if os.clock() < drive.reverseUntil then
		t, s = -1, drive.reverseSteer
	else
		local to = flat(drive.aim - chassis.Position)
		if not to then
			return
		end
		t, s = steerTo(look, right, to)
	end
	drive.lastS = s
	hum:Move(look * t + right * s, false)
end
RunService:BindToRenderStep(STEER_BIND, Enum.RenderPriority.Input.Value + 1, steerFrame)

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true
local filterAt = 0
local function refreshFilter(car)
	if os.clock() - filterAt < 1 then
		return
	end
	filterAt = os.clock()
	local list = { car } -- other cars stay in: they're obstacles too
	local zf = workspace:FindFirstChild("ClientZombies")
	if zf then
		table.insert(list, zf) -- we want to hit these
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	for _, v in ipairs(CollectionService:GetTagged("CarRayIgnore")) do
		table.insert(list, v) -- the game's own "not solid for cars" set
	end
	rayParams.FilterDescendantsInstances = list
end

local function wall(from, dir, len)
	local hit = workspace:Raycast(from, dir * len, rayParams)
	return hit ~= nil and hit.Normal.Y < 0.5
end

local function rotY(v, deg)
	return (CFrame.Angles(0, math.rad(deg), 0) * CFrame.new(v)).Position
end

-- Route frame: RouteOrigin + RunAxis. Lateral offset is what the corridor clamp bounds.
local function routeFrame(car)
	local axis = car:GetAttribute("RunAxis")
	axis = typeof(axis) == "Vector3" and flat(axis) or Vector3.new(1, 0, 0)
	local stages = workspace:FindFirstChild("Game") and workspace.Game:FindFirstChild("Stages")
	local origin = stages and stages:GetAttribute("RouteOrigin")
	if typeof(origin) ~= "Vector3" then
		origin = car:GetAttribute("RunOrigin")
	end
	if typeof(origin) ~= "Vector3" then
		origin = car:GetPivot().Position
	end
	return axis, Vector3.new(-axis.Z, 0, axis.X), origin
end

local function inWindow(z, pos, axis, lat, origin)
	local d = z.pos - pos
	local ahead = d:Dot(axis)
	return ahead >= AHEAD_MIN
		and ahead <= AHEAD_MAX
		and math.abs(d:Dot(lat)) <= ahead * CONE + 6
		and math.abs((z.pos - origin):Dot(lat)) <= CORRIDOR
end

local function pickTarget(pos, axis, lat, origin)
	local cands = {}
	for id, z in pairs(zombies) do
		if inWindow(z, pos, axis, lat, origin) then
			table.insert(cands, id)
		end
	end
	local best, bestScore
	for _, id in ipairs(cands) do
		local z = zombies[id]
		local dist = (z.pos - pos).Magnitude
		local score
		if drive.priority == "Furthest ahead" then
			score = (z.pos - pos):Dot(axis)
		elseif drive.priority == "Nearest ahead" then
			score = -dist
		elseif drive.priority == "Richest ahead" then
			score = z.cash / (1 + dist / 100)
		else
			-- ponytail: O(n^2) over the window only (tens of zombies), fine at 10Hz
			score = -dist / 1000
			for _, other in ipairs(cands) do
				if (zombies[other].pos - z.pos).Magnitude <= CLUSTER then
					score += 1
				end
			end
		end
		if not bestScore or score > bestScore then
			best, bestScore = id, score
		end
	end
	return best
end

local function nearest(set, pos)
	local best, bestD
	for _, p in pairs(set) do
		local d = (p - pos).Magnitude
		if not bestD or d < bestD then
			best, bestD = p, d
		end
	end
	return best
end

local function battleAim(car, pos)
	local tank = (car:GetAttribute("Fuel") or 0) / math.max(car:GetAttribute("FuelTime") or 1, 1e-3)
	if tank < FUEL_LOW then
		local can = nearest(fuels, pos)
		if can then
			return can
		end
	end
	local boss = nearest(bosses, pos)
	if boss then
		return boss
	end
	local zs = {}
	for _, z in pairs(zombies) do
		table.insert(zs, z.pos) -- minions
	end
	return nearest(zs, pos)
end

-- The game pushes nitro from the HUD button's InputBegan; calling its handler with a fake
-- MouseButton1 is exactly a held click, and InputEnded is the release.
local function pushNitro(down)
	if not getconnections then
		return false
	end
	local ok, btn = pcall(function()
		return player.PlayerGui.MainGui.HUD.Vehicle.Nitro
	end)
	if not ok or not btn then
		return false
	end
	local input = {
		UserInputType = Enum.UserInputType.MouseButton1,
		UserInputState = down and Enum.UserInputState.Begin or Enum.UserInputState.End,
	}
	for _, c in ipairs(getconnections(down and btn.InputBegan or btn.InputEnded)) do
		pcall(function()
			if c.Function then
				c.Function(input)
			end
		end)
	end
	drive.nitroHeld = down
	return true
end

local function updateNitro(car)
	local fuel = car:GetAttribute("NitroFuel") or 0
	local usable = drive.nitro and (car:GetAttribute("TurboMult") or 1) > 1
	if drive.nitroHeld and (not usable or fuel <= NITRO_OFF) then
		pushNitro(false)
	elseif not drive.nitroHeld and usable and fuel >= NITRO_ON then
		pushNitro(true)
	end
end

-- One planner tick: aim point, obstacle swing, unstick, nitro.
local function plan(dt)
	local car, hum = myCar(), humanoid()
	local chassis = car and car.PrimaryPart
	if not (chassis and seatedIn(car, hum)) then
		drive.aim, drive.target = nil, nil
		if drive.nitroHeld then
			pushNitro(false)
		end
		return
	end
	refreshFilter(car)
	local pos = chassis.Position
	local vel = chassis.AssemblyLinearVelocity
	local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
	local axis, lat, origin = routeFrame(car)
	local aim

	if player:GetAttribute("InBattle") then
		aim = battleAim(car, pos)
		drive.target = nil
	end
	if not aim then
		local along, off = (pos - origin):Dot(axis), (pos - origin):Dot(lat)
		aim = origin + axis * (along + LOOKAHEAD) + lat * math.clamp(off, -CORRIDOR, CORRIDOR)
		if drive.hunt and not player:GetAttribute("InBattle") then
			local z = drive.target and zombies[drive.target]
			if not (z and inWindow(z, pos, axis, lat, origin)) then
				drive.target = pickTarget(pos, axis, lat, origin)
				z = drive.target and zombies[drive.target]
			end
			if z then
				aim = z.pos
			end
		end
	end

	-- Obstacles: probe toward the aim; on a wall, take the smallest swing that's clear.
	local now = os.clock()
	if now < drive.avoidUntil and drive.avoidDir then
		aim = pos + drive.avoidDir * 40
	else
		local to = flat(aim - pos)
		local len = PROBE_BASE + speed * PROBE_PER_SPEED
		if to and wall(pos, to, len) then
			local found
			for _, deg in ipairs({ 25, -25, 50, -50, 80, -80 }) do
				local d = rotY(to, deg)
				if not wall(pos, d, len) then
					found = d
					break
				end
			end
			if found then
				drive.avoidDir, drive.avoidUntil = found, now + AVOID_HOLD
				aim = pos + found * 40
			else
				drive.reverseUntil, drive.reverseSteer = now + REVERSE_TIME, -(drive.lastS >= 0 and 1 or -1)
			end
		end
	end

	-- Unstick. DriveForce is zeroed by the game whenever it's holding us (countdown, stage
	-- streaming, empty tank), so "slow while it pushes" is the only honest stuck signal.
	-- An empty tank brakes through the same force, so it has to be fuelled as well.
	local okF, push = pcall(function()
		return chassis.DriveForce.Force.Magnitude
	end)
	local pushing = okF and push > 1 and (car:GetAttribute("Fuel") or 0) > 0
	if pushing and speed < STUCK_SPEED and now > drive.reverseUntil then
		drive.stuckFor += dt
		if drive.stuckFor >= STUCK_TIME then
			drive.stuckFor = 0
			drive.reverseUntil, drive.reverseSteer = now + REVERSE_TIME, -(drive.lastS >= 0 and 1 or -1)
		end
	else
		drive.stuckFor = 0
	end

	updateNitro(car)
	drive.aim = aim
end

local function startPlanner()
	drive.gen += 1
	local mine = drive.gen
	task.spawn(function()
		local last = os.clock()
		while running and drive.gen == mine do
			task.wait(PLAN_BEAT)
			local now = os.clock()
			if driving() then
				local ok, err = pcall(plan, now - last)
				if not ok then
					warn("[btkz] plan: " .. tostring(err))
				end
			elseif drive.aim then
				drive.aim = nil
				if drive.nitroHeld then
					pushNitro(false)
				end
			end
			last = now
		end
	end)
end
startPlanner()

-- farm -----------------------------------------------------------------------
-- The character is shared: a run seats it in the car, the shop stands it on a prompt.
-- claim() serialises the two; manual buttons refuse instead of queueing behind a run.
local busy = false
local function claim(fn, ...)
	while busy do
		task.wait()
	end
	busy = true
	local ok, err = pcall(fn, ...)
	busy = false
	if not ok then
		warn("[btkz] " .. tostring(err))
	end
	return ok
end

local shop -- forward: the farm waits on shop.idle between runs

local function waitFor(cond, timeout)
	local t0 = os.clock()
	while not cond() do
		if os.clock() - t0 > timeout then
			return false
		end
		task.wait(0.1)
	end
	return true
end

local function launch()
	step("launch")
	fire("SpawnCar")
	return waitFor(function()
		local car = myCar()
		return car ~= nil and seatedIn(car, humanoid())
	end, LAUNCH_TIMEOUT)
end

-- Drive until the run is over by the game's own numbers; returns its validated totals.
local function runOnce(alive)
	local car = myCar()
	local lastDist, lastGain, slowFor = 0, os.clock(), 0
	local dist, earned = 0, 0
	while alive() do
		car = myCar()
		if not car then
			break
		end
		dist = car:GetAttribute("ValidatedDistance") or dist
		earned = car:GetAttribute("ValidatedCash") or earned
		if dist > lastDist + 1 then
			lastDist, lastGain = dist, os.clock()
		end
		if player:GetAttribute("InBattle") then
			lastGain = os.clock() -- the battle ends itself; distance doesn't move in an arena
		else
			local chassis = car.PrimaryPart
			local v = chassis and chassis.AssemblyLinearVelocity or Vector3.zero
			local speed = Vector3.new(v.X, 0, v.Z).Magnitude
			slowFor = ((car:GetAttribute("Fuel") or 0) <= 0 and speed < END_SPEED) and slowFor + 0.25 or 0
			if slowFor >= END_HOLD or (car:GetAttribute("CarHealth") or 100) <= 0 then
				break
			end
			if os.clock() - lastGain > GIVE_UP then
				log(("no distance for %ds -- ending the run"):format(GIVE_UP))
				break
			end
		end
		step(("run %d -- %d studs"):format(stats.runs + 1, dist))
		task.wait(0.25)
	end
	return dist, earned
end

local function returnCar()
	step("return")
	if player:GetAttribute("InBattle") then
		return false -- ToggleLaunch refuses in battle too; the battle ends itself
	end
	fire("DespawnCar")
	return waitFor(function()
		return myCar() == nil
	end, RETURN_TIMEOUT)
end

local bestBlueprint -- forward: build section

local function setFarm(state)
	farm.on = state
	farm.gen += 1
	local mine = farm.gen
	if not state then
		pcall(function()
			local hum = humanoid()
			if hum then
				hum:Move(Vector3.zero, false)
			end
		end)
		return
	end
	farm.strikes = 0
	local function alive()
		return running and farm.on and farm.gen == mine
	end
	task.spawn(function()
		while alive() do
			if not myCar() then
				-- Between runs: let the shop spend what the last run earned, then launch.
				if shop and (shop.roll or shop.buy) then
					step("shop window")
					local t0 = os.clock()
					task.wait(0.5)
					while alive() and not shop.idle and os.clock() - t0 < SHOP_WINDOW do
						task.wait(0.25)
					end
				end
				if farm.blueprint and bestBlueprint then
					bestBlueprint(true)
				end
				if not alive() then
					break
				end
				local ok = false
				claim(function()
					ok = launch()
				end)
				if not ok then
					farm.strikes += 1
					if farm.strikes >= LAUNCH_STRIKES then
						say("launch refused " .. LAUNCH_STRIKES .. "x -- does the car have a seat, wheels and an engine?")
						farm.on = false
						break
					end
					say(("launch didn't take (%d/%d), retrying"):format(farm.strikes, LAUNCH_STRIKES))
					task.wait(2)
					continue
				end
				farm.strikes = 0
			end
			say("driving")
			local dist, earned = runOnce(alive)
			if not alive() then
				break
			end
			stats.runs += 1
			stats.best = math.max(stats.best, dist)
			stats.runCash += earned
			say(("run %d: %d studs, $%d"):format(stats.runs, dist, earned))
			claim(returnCar)
			task.wait(0.5)
		end
	end)
end

-- shop -----------------------------------------------------------------------
shop = {
	roll = false,
	buy = false,
	stopAt = "Legendary",
	buySet = { Rare = true, Epic = true, Legendary = true, Mythical = true, Secret = true },
	forBlueprint = true, -- also buy parts the next blueprint is missing, whatever the rarity
	stations = { RollBlocks = true, RollWeapons = true },
	shown = {}, -- station -> part on display (our plot only)
	spun = {}, -- station -> os.clock() of our last RollSpin
	bought = {}, -- station -> os.clock() of our last RollPurchased
	idle = true,
	gen = 0,
	method = nil, -- winning press method index, once one has bought something
	held = {}, -- station -> part we already said we're holding, so it's said once
}
local STATIONS = { "RollBlocks", "RollWeapons" }

local function mine(plotName)
	local p = myPlot()
	return p ~= nil and p.Name == plotName
end

on("RollSpin", function(plotName, station, _, uid)
	if mine(plotName) then
		shop.shown[station] = nil
		if uid == player.UserId then
			shop.spun[station] = os.clock()
		end
	end
end)
on("RollDisplay", function(plotName, station, part)
	if mine(plotName) then
		shop.shown[station] = part
	end
end)
on("RollClear", function(plotName, station)
	if mine(plotName) then
		shop.shown[station] = nil
	end
end)
on("RollPurchased", function(plotName, station, uid)
	if mine(plotName) then
		shop.shown[station] = nil
		if uid == player.UserId then
			shop.bought[station] = os.clock()
		end
	end
end)

-- Blueprint bookkeeping, shared by buy ("is this part one the next blueprint needs?") and
-- build ("which blueprint can I spawn now?"). Owned = inventory + parts on the car, which
-- is exactly what the game's own Blueprints menu counts.
local function owned()
	if not (BuildController and BlueprintConfig) then
		return nil
	end
	local ok, res = pcall(function()
		return BlueprintConfig.Owned(BuildController.GetInventory(), BuildController.GetMirror())
	end)
	return ok and res or nil
end

local function neededNext(part)
	local have = owned()
	if not have then
		return false
	end
	for _, name in ipairs(BlueprintConfig.Order) do
		local missing = BlueprintConfig.Missing(BlueprintConfig.Required(name), have)
		if not BlueprintConfig.IsEmpty(missing) then
			return missing[part] ~= nil -- the cheapest blueprint you can't build yet
		end
	end
	return false
end

-- "buy", "keep" (stop rolling this station and leave it on display), or "skip".
local function decide(part)
	local def = PartCatalog.Parts[part]
	if not def then
		return "keep" -- never roll over something we can't read
	end
	if shop.buy and (shop.buySet[def.Rarity] or (shop.forBlueprint and neededNext(part))) then
		return "buy"
	end
	if (RANK[def.Rarity] or 0) >= (RANK[shop.stopAt] or math.huge) then
		return "keep"
	end
	return "skip"
end

-- The Legendary+ "are you sure you want to skip" dialog: answer it from the same rule.
on("RollConfirmation", function(plotName, station, part, token)
	if not (shop.roll and mine(plotName) and shop.stations[station]) then
		return -- not ours to answer: leave the game's dialog for the player
	end
	local skip = decide(part) == "skip"
	fire("ConfirmRollSkip", token, skip)
	if UIController and UIController.CloseGui then
		task.defer(pcall, UIController.CloseGui, "Confirmation")
	end
end)

local function hop(part)
	local hrp = rootPart()
	local hum = humanoid()
	if not (hrp and part) then
		return false
	end
	if hum and hum.SeatPart then
		return false -- seated means a car; the shop only runs in the lobby
	end
	hrp.CFrame = CFrame.new(part.Position + Vector3.new(0, 1.5, 0))
	hrp.AssemblyLinearVelocity = Vector3.zero
	task.wait(SETTLE)
	return true
end

local function openGates(prompt)
	pcall(function()
		prompt.RequiresLineOfSight = false
		prompt.MaxActivationDistance = 30 -- big and finite: math.huge throws
	end)
end

-- Three ways to press, tried in order until one lands; the winner is used alone after.
local METHODS = {
	function(prompt)
		fireproximityprompt(prompt, prompt.HoldDuration)
	end,
	function(prompt)
		prompt:InputHoldBegin()
		task.wait(prompt.HoldDuration + 0.1)
		prompt:InputHoldEnd()
	end,
	function(prompt)
		local vim = game:GetService("VirtualInputManager")
		vim:SendKeyEvent(true, prompt.KeyboardKeyCode, false, game)
		task.wait(prompt.HoldDuration + 0.1)
		vim:SendKeyEvent(false, prompt.KeyboardKeyCode, false, game)
	end,
}

local function press(prompt, landed, timeout)
	openGates(prompt)
	local order = {}
	if shop.method then
		table.insert(order, shop.method)
	end
	for i = 1, #METHODS do
		if i ~= shop.method and (i ~= 1 or fireproximityprompt) then
			table.insert(order, i)
		end
	end
	for _, i in ipairs(order) do
		pcall(METHODS[i], prompt)
		if waitFor(landed, timeout) then
			shop.method = i
			return true
		end
	end
	return false
end

local function stationFolder(station)
	local plot = myPlot()
	local rolls = plot and plot:FindFirstChild("Rolls")
	return rolls and rolls:FindFirstChild(station)
end

local function rollStation(station)
	local f = stationFolder(station)
	local lever = f and f:FindFirstChild("Roll")
	local prompt = lever and lever:FindFirstChildWhichIsA("ProximityPrompt", true)
	if not prompt then
		return false
	end
	step("roll " .. station)
	if not hop(lever) then
		return false
	end
	local since = os.clock()
	local ok = press(prompt, function()
		return (shop.spun[station] or 0) >= since
	end, ROLL_CONFIRM)
	if not ok then
		return false
	end
	stats.rolls += 1
	local speed = 1
	pcall(function()
		speed = GamepassConfig.RollSpeed(player)
	end)
	waitFor(function()
		return shop.shown[station] ~= nil
	end, RollConfig.SpinDuration / math.max(speed, 0.1) + DISPLAY_SLACK)
	return true
end

local function buyStation(station, part)
	local def = PartCatalog.Parts[part]
	-- Short on cash is where the server offers the Robux InstantBuy instead. Never press it.
	if not def or cash() < def.Cost then
		return false
	end
	local f = stationFolder(station)
	local place = f and f:FindFirstChild("ItemPlace")
	local prompt = place and place:FindFirstChild("BuyPrompt", true)
	if not (prompt and prompt.Enabled) then
		return false
	end
	step("buy " .. part)
	if not hop(place) then
		return false
	end
	local since, before = os.clock(), cash()
	local ok = press(prompt, function()
		return (shop.bought[station] or 0) >= since or shop.shown[station] ~= part or cash() <= before - def.Cost * 0.5
	end, BUY_CONFIRM)
	if ok then
		stats.bought += 1
		say(("bought %s (%s) for $%d"):format(def.Name, def.Rarity, def.Cost))
	end
	return ok
end

-- One pass over the stations; returns whether it did anything (idle feeds the farm).
local function shopPass()
	if myCar() or not myPlot() or not rootPart() then
		return false
	end
	local did = false
	for _, station in ipairs(STATIONS) do
		if not (shop.stations[station] and (shop.roll or shop.buy)) then
			continue
		end
		local part = shop.shown[station]
		local d = part and decide(part)
		if d == "buy" then
			local def = PartCatalog.Parts[part]
			if cash() >= def.Cost then
				claim(function()
					did = buyStation(station, part) or did
				end)
			elseif shop.held[station] ~= part then
				shop.held[station] = part
				say(("holding %s (%s) -- saving for $%d"):format(def.Name, def.Rarity, def.Cost))
			end
		elseif d == "keep" then
			if shop.held[station] ~= part then
				shop.held[station] = part
				say(("stopped on %s (%s) -- buy it or roll on"):format(PartCatalog.Parts[part] and PartCatalog.Parts[part].Name or part, PartCatalog.Parts[part] and PartCatalog.Parts[part].Rarity or "?"))
			end
		elseif shop.roll then
			claim(function()
				did = rollStation(station) or did
			end)
		end
	end
	return did
end

local function startShop()
	shop.gen += 1
	local gen = shop.gen
	if not (shop.roll or shop.buy) then
		shop.idle = true
		return
	end
	fire("RollSync") -- re-sends RollDisplay for what's already on our stations
	task.spawn(function()
		while running and shop.gen == gen and (shop.roll or shop.buy) do
			local ok, did = pcall(shopPass)
			if not ok then
				warn("[btkz] shop: " .. tostring(did))
				did = false
			end
			shop.idle = not did
			task.wait(did and 0.1 or 0.5)
		end
		shop.idle = true
	end)
end

local function setRollCategories(set)
	local list = {}
	for cat in pairs(RollConfig.Categories) do
		if set[cat] then
			table.insert(list, cat)
		end
	end
	if #list == 0 then
		return false -- the server needs at least one, same as the game's own menu
	end
	table.sort(list)
	fire("SetRollCategories", table.concat(list, ","))
	return true
end

-- build ----------------------------------------------------------------------
local function buildCost(counts)
	local sum = 0
	for id, n in pairs(counts) do
		local def = PartCatalog.Parts[id]
		sum += (def and def.Cost or 0) * n
	end
	return sum
end

-- Spawn the priciest blueprint you own every part for, if it beats the car you have.
bestBlueprint = function(quiet)
	local have = owned()
	if not have then
		if not quiet then
			say("blueprints unavailable -- BuildController didn't load")
		end
		return false
	end
	local current = {}
	local okM, mirror = pcall(BuildController.GetMirror)
	for _, p in ipairs(okM and mirror or {}) do
		current[p.Id] = (current[p.Id] or 0) + 1
	end
	local now = buildCost(current)
	for i = #BlueprintConfig.Order, 1, -1 do
		local name = BlueprintConfig.Order[i]
		local req = BlueprintConfig.Required(name)
		if BlueprintConfig.IsEmpty(BlueprintConfig.Missing(req, have)) and buildCost(req) > now then
			fire("SpawnBlueprint", name)
			say(("spawned blueprint %s"):format(name))
			return true
		end
	end
	if not quiet then
		say("no ownable blueprint beats your current car")
	end
	return false
end

-- skills ---------------------------------------------------------------------
local skills = { on = false, gen = 0, owned = nil, want = {} }
local BRANCHES = {
	Luck = "Luck",
	RollCooldown = "Golden/rainbow rolls",
	SupportSlots = "Weapon slots",
	PlotExpansion = "Plot size",
	TotalMorePlacement = "More placement",
	TotalDamageExtra = "Damage",
	TotalHealthExtra = "Health",
	Paint = "Paint",
}
local BRANCH_LIST = { "Luck", "Golden/rainbow rolls", "Weapon slots", "Plot size", "More placement", "Damage", "Health", "Paint" }
for _, b in ipairs(BRANCH_LIST) do
	skills.want[b] = true
end

on("SkillsChanged", function(json)
	local ok, list = pcall(HttpService.JSONDecode, HttpService, json)
	if ok and type(list) == "table" then
		local set = {}
		for _, id in ipairs(list) do
			set[id] = true
		end
		skills.owned = set
	end
end)

local function branchOf(def)
	for key in pairs(def.Effects or {}) do
		return BRANCHES[key]
	end
	return nil
end

local function cheapestSkill()
	if not (SkillConfig and SkillConfig.ById and skills.owned) then
		return nil
	end
	local best
	for id, def in pairs(SkillConfig.ById) do
		local b = branchOf(def)
		if b and skills.want[b] and SkillConfig.CanBuy(skills.owned, id) and (not best or def.Cost < best.Cost) then
			best = def
		end
	end
	return best
end

local function setSkills(state)
	skills.on = state
	skills.gen += 1
	local gen = skills.gen
	if not state then
		return
	end
	fire("RequestSkills")
	task.spawn(function()
		while running and skills.on and skills.gen == gen do
			local def = cheapestSkill()
			if def and cash() >= def.Cost then
				local before = skills.owned
				fire("BuySkill", def.Id)
				waitFor(function()
					return skills.owned ~= before
				end, 3)
				if skills.owned and skills.owned[def.Id] then
					say(("skill: %s ($%d)"):format(def.Title or def.Id, def.Cost))
				end
			end
			task.wait(SKILL_POLL)
		end
	end)
end

-- rewards --------------------------------------------------------------------
local rewards = { on = false, gen = 0, quests = nil, claiming = {} }

on("QuestsChanged", function(json)
	local ok, t = pcall(HttpService.JSONDecode, HttpService, json)
	if ok and type(t) == "table" then
		rewards.quests = t
		table.clear(rewards.claiming)
	end
end)

local function claimQuests()
	local q = rewards.quests
	if not (q and QuestConfig) then
		return 0
	end
	local n = 0
	for _, def in ipairs(QuestConfig.Quests) do
		local progress = type(q.Progress) == "table" and q.Progress[def.Id] or 0
		local claimed = type(q.Claimed) == "table" and q.Claimed[def.Id]
		if not claimed and (tonumber(progress) or 0) >= def.Goal and not rewards.claiming[def.Id] then
			rewards.claiming[def.Id] = true
			fire("ClaimQuest", def.Id)
			n += 1
		end
	end
	return n
end

local function claimOnce()
	fire("ClaimOffline") -- the free claim; Triple is a Robux product and never sent
	if player:GetAttribute("GroupReward") ~= true then
		fire("ClaimChestReward") -- refused server-side unless you're in the group
	end
end

local function setRewards(state)
	rewards.on = state
	rewards.gen += 1
	local gen = rewards.gen
	if not state then
		return
	end
	claimOnce()
	task.spawn(function()
		local synced = 0
		while running and rewards.on and rewards.gen == gen do
			if os.clock() - synced > QUEST_POLL then
				synced = os.clock()
				fire("RequestQuests")
			end
			local n = claimQuests()
			if n > 0 then
				say(("claimed %d quest%s"):format(n, n == 1 and "" or "s"))
			end
			task.wait(2)
		end
	end)
end

local function redeemCodes()
	if not CodesConfig then
		return 0
	end
	local seen = getgenv().ZegionKillZombieCodes or {}
	getgenv().ZegionKillZombieCodes = seen
	local now, n = workspace:GetServerTimeNow(), 0
	for code, def in pairs(CodesConfig) do
		if type(def) == "table" and def.Active and (not def.ExpiredTime or def.ExpiredTime > now) and not seen[code] then
			local done, res = callTimed(function()
				return Packets.RedeemCode:Fire(code:upper())
			end, 5)
			seen[code] = true
			n += 1
			log(("code %s -> %s"):format(code, done and tostring(res) or "no answer"))
			task.wait(0.3)
		end
	end
	return n
end

-- boss -----------------------------------------------------------------------
local boss = { on = false, gen = 0 }
local function setBoss(state)
	boss.on = state
	boss.gen += 1
	local gen = boss.gen
	if not state then
		return
	end
	task.spawn(function()
		while running and boss.on and boss.gen == gen do
			local ok, alert = pcall(function()
				return player.PlayerGui.MainGui.HUD.Boss.BossJoinAlert
			end)
			if ok and alert and alert.Visible and not player:GetAttribute("InBattle") then
				fire("JoinBattle")
				say("joined the boss battle")
				task.wait(3)
			end
			task.wait(BOSS_POLL)
		end
	end)
end

-- anti-afk -------------------------------------------------------------------
local afk = { on = false, gen = 0, conns = {} }

local function nudge()
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

local function setAfk(state)
	afk.gen += 1
	local gen = afk.gen
	afk.on = state
	for _, c in ipairs(afk.conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(afk.conns)
	if not state then
		return
	end
	table.insert(afk.conns, player.Idled:Connect(nudge))
	task.spawn(function()
		local overlay
		pcall(function()
			overlay = game:GetService("CoreGui"):WaitForChild("RobloxPromptGui", 10):WaitForChild("promptOverlay", 10)
		end)
		if overlay and afk.on and afk.gen == gen then
			table.insert(
				afk.conns,
				overlay.ChildAdded:Connect(function(child)
					if child.Name ~= "ErrorPrompt" or not (afk.on and running) then
						return
					end
					warn("[btkz] disconnected -- rejoining in " .. REJOIN_DELAY .. "s")
					task.wait(REJOIN_DELAY)
					pcall(function()
						game:GetService("TeleportService"):Teleport(game.PlaceId, player)
					end)
				end)
			)
		end
		while afk.on and afk.gen == gen and running do
			task.wait(AFK_BEAT)
			if afk.on and afk.gen == gen and running then
				nudge()
			end
		end
	end)
end

-- A parked farm thread can't report itself; this one can.
task.spawn(function()
	while running do
		task.wait(5)
		if farm.on and os.clock() - markAt > WATCHDOG then
			warn(("[btkz] stuck %ds at: %s"):format(os.clock() - markAt, mark))
			markAt = os.clock()
		end
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Build to Kill Zombie", -- fallback until the live name lands
	folder = "BuildToKillZombie", -- never rename: saved configs orphan
	size = UDim2.fromOffset(520, 440),
})
if not Window then
	running = false
	RunService:UnbindFromRenderStep(STEER_BIND)
	return -- panel.lua already said why
end

-- WindUI hands a Multi dropdown's callback a list, a map, or the row tables back depending
-- on the build; normalise into a set we own.
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

local function keysOf(set, order)
	local out = {}
	for _, k in ipairs(order) do
		if set[k] then
			table.insert(out, k)
		end
	end
	return out
end

-- Farm tab ----
local FarmTab = Window:Tab({ Title = "Farm", Icon = "solar:bolt-circle-bold" })
local Run = FarmTab:Section({ Title = "Runs", Icon = "solar:bolt-circle-bold", Box = true, BoxBorder = true, Opened = true })

Run:Toggle({
	Title = "Auto farm",
	Desc = "Launch, drive, return, repeat -- rolls and buys between runs if those are on",
	Value = false,
	Callback = function(state)
		setFarm(state)
		say(state and "farming" or "stopped")
	end,
})

Run:Toggle({
	Title = "Auto drive only",
	Desc = "Steers whenever you're in your car; you launch and return yourself",
	Value = false,
	Callback = function(state)
		drive.manual = state
	end,
})

Run:Toggle({
	Title = "Auto nitro",
	Desc = "Holds nitro from " .. math.floor(NITRO_ON * 100) .. "% tank. Needs a Turbo part on the car",
	Value = false,
	Callback = function(state)
		if state and not getconnections then
			say("this executor has no getconnections -- auto nitro can't press the button")
			return
		end
		drive.nitro = state
	end,
})

Run:Toggle({
	Title = "Spawn best blueprint between runs",
	Desc = "Replaces your build when you own every part of a pricier blueprint",
	Value = false,
	Callback = function(state)
		farm.blueprint = state
	end,
})

local Hunt = FarmTab:Section({ Title = "Targets", Icon = "solar:target-bold", Box = true, BoxBorder = true, Opened = true })

Hunt:Toggle({
	Title = "Hunt zombies",
	Desc = "Off = straight line for pure distance. On = swerve for zombies ahead, never back",
	Value = drive.hunt,
	Callback = function(state)
		drive.hunt = state
		drive.target = nil
	end,
})

local PRIORITIES = { "Densest ahead", "Furthest ahead", "Nearest ahead", "Richest ahead" }
Hunt:Dropdown({
	Title = "Priority",
	Desc = "Densest = most kills per swerve. Furthest = least steering. Richest = CashPerKill",
	Values = PRIORITIES,
	Value = drive.priority,
	Callback = function(v)
		if table.find(PRIORITIES, v) then
			drive.priority = v
			drive.target = nil
		end
	end,
})

local statusLine = Run:Paragraph({ Title = "Status", Desc = "idle" })
local statsLine = Hunt:Paragraph({ Title = "Session", Desc = "-" })

-- Shop tab ----
local ShopTab = Window:Tab({ Title = "Shop", Icon = "solar:cart-large-2-bold" })
local Roll = ShopTab:Section({ Title = "Roll", Icon = "solar:refresh-bold", Box = true, BoxBorder = true, Opened = true })

Roll:Toggle({
	Title = "Auto roll",
	Desc = "Free: rolling never spends cash. Stops on the first item at or above 'Stop at'",
	Value = false,
	Callback = function(state)
		shop.roll = state
		table.clear(shop.held)
		startShop()
	end,
})

Roll:Dropdown({
	Title = "Stop at",
	Desc = "Rolling pauses on this rarity or better and leaves it on display",
	Values = RARITIES,
	Value = shop.stopAt,
	Callback = function(v)
		if RANK[v] then
			shop.stopAt = v
			table.clear(shop.held)
		end
	end,
})

Roll:Dropdown({
	Title = "Stations",
	Values = { "Blocks", "Weapons" },
	Multi = true,
	AllowNone = true,
	Value = { "Blocks", "Weapons" },
	Callback = function(v)
		local set = ticked(v)
		shop.stations.RollBlocks = set.Blocks == true
		shop.stations.RollWeapons = set.Weapons == true
	end,
})

local CATS = { "Block", "Engine", "Fuel", "Wheel" }
local catNow = {}
do
	local attr = player:GetAttribute(RollConfig.CategoryAttribute)
	for _, c in ipairs(type(attr) == "string" and string.split(attr, ",") or CATS) do
		catNow[c] = true
	end
end
Roll:Dropdown({
	Title = "Block station rolls",
	Desc = "Narrow it to Engine/Wheel to stop wasting rolls on blocks",
	Values = CATS,
	Multi = true,
	AllowNone = true,
	Value = keysOf(catNow, CATS),
	Callback = function(v)
		if not setRollCategories(ticked(v)) then
			say("tick at least one category -- the server needs one")
		end
	end,
})

local Buy = ShopTab:Section({ Title = "Buy", Icon = "solar:cart-large-2-bold", Box = true, BoxBorder = true, Opened = true })

Buy:Toggle({
	Title = "Auto buy",
	Desc = "Buys the displayed item if its rarity is ticked and your cash covers it -- never short",
	Value = false,
	Callback = function(state)
		shop.buy = state
		table.clear(shop.held)
		startShop()
	end,
})

Buy:Dropdown({
	Title = "Buy rarities",
	Values = RARITIES,
	Multi = true,
	AllowNone = true,
	Value = keysOf(shop.buySet, RARITIES),
	Callback = function(v)
		table.clear(shop.buySet)
		for r in pairs(ticked(v)) do
			shop.buySet[r] = true
		end
		table.clear(shop.held)
	end,
})

Buy:Toggle({
	Title = "Also buy blueprint parts",
	Desc = "Any rarity, if the cheapest blueprint you can't build yet is missing it",
	Value = shop.forBlueprint,
	Callback = function(state)
		shop.forBlueprint = state
	end,
})

Buy:Button({
	Title = "Spawn best blueprint now",
	Callback = function()
		if myCar() then
			say("return the car first -- the build is locked while it's out")
			return
		end
		bestBlueprint(false)
	end,
})

local shopLine = Buy:Paragraph({ Title = "Status", Desc = "idle" })

-- Progress tab ----
local ProgTab = Window:Tab({ Title = "Progress", Icon = "solar:star-bold" })
local Skill = ProgTab:Section({ Title = "Skill tree", Icon = "solar:graph-up-bold", Box = true, BoxBorder = true, Opened = true })

Skill:Toggle({
	Title = "Auto buy skills",
	Desc = "Cheapest affordable node in the ticked branches, every " .. SKILL_POLL .. "s",
	Value = false,
	Callback = setSkills,
})

Skill:Dropdown({
	Title = "Branches",
	Values = BRANCH_LIST,
	Multi = true,
	AllowNone = true,
	Value = BRANCH_LIST,
	Callback = function(v)
		table.clear(skills.want)
		for b in pairs(ticked(v)) do
			skills.want[b] = true
		end
	end,
})

local Reward = ProgTab:Section({ Title = "Rewards", Icon = "solar:gift-bold", Box = true, BoxBorder = true, Opened = true })

Reward:Toggle({
	Title = "Auto rewards",
	Desc = "Weekly quests as they complete, plus offline earnings and the group chest once",
	Value = false,
	Callback = setRewards,
})

Reward:Button({
	Title = "Redeem all codes",
	Desc = "Every code in the game's CodesConfig that hasn't expired",
	Callback = function()
		task.spawn(function()
			local n = redeemCodes()
			say(n == 0 and "no new codes" or ("tried %d codes -- results in F9"):format(n))
		end)
	end,
})

local Boss = ProgTab:Section({ Title = "Boss", Icon = "solar:danger-bold", Box = true, BoxBorder = true, Opened = true })

Boss:Toggle({
	Title = "Auto join battles",
	Desc = "Joins when the alert opens. In battle the drive rams the boss and grabs fuel cans",
	Value = false,
	Callback = setBoss,
})

local MiscSec = ProgTab:Section({ Title = "Session", Icon = "solar:shield-check-bold", Box = true, BoxBorder = true, Opened = true })
MiscSec:Toggle({
	Title = "Anti-AFK + rejoin",
	Desc = "Clicks before the idle kick; rejoins on a disconnect prompt",
	Value = true,
	Callback = setAfk,
})
setAfk(true) -- a starting Value doesn't fire the callback, so arm it by hand

-- A resumed loop thread lacks the capability the hidden GUI needs; Heartbeat runs with ours.
local statsAt = 0
local drain = RunService.Heartbeat:Connect(function()
	if pending ~= nil then
		local msg = pending
		pending = nil
		local wrote = false
		for _, row in ipairs({ statusLine, shopLine }) do
			if pcall(function()
				row:SetDesc(msg)
			end) then
				wrote = true
			end
		end
		if not wrote then
			log(msg)
		end
	end
	if os.clock() - statsAt > 1 then
		statsAt = os.clock()
		pcall(function()
			statsLine:SetDesc(
				("%d runs · best %d studs · $%d run cash\n%d kills ($%d) · %d rolls · %d bought"):format(
					stats.runs,
					stats.best,
					stats.runCash,
					stats.kills,
					stats.killCash,
					stats.rolls,
					stats.bought
				)
			)
		end)
	end
end)

if (player:GetAttribute("Tutorial") or 0) < 8 then
	say("finish the tutorial first -- rolls, blueprints and quests are locked until then")
else
	say("ready")
end

-- close ----------------------------------------------------------------------
local function stopAll()
	running = false
	setFarm(false)
	drive.manual = false
	drive.gen += 1
	shop.roll, shop.buy = false, false
	shop.gen += 1
	setSkills(false)
	setRewards(false)
	setBoss(false)
	setAfk(false)
	pcall(function()
		RunService:UnbindFromRenderStep(STEER_BIND)
	end)
	if drive.nitroHeld then
		pushNitro(false) -- a held nitro would keep draining after we're gone
	end
	pcall(function()
		drain:Disconnect()
	end)
	for _, c in ipairs(conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(conns)
end

Window:OnDestroy(function()
	stopAll()
	getgenv().killZombieStop = nil
end)

getgenv().killZombieStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().killZombieStop = nil
end
