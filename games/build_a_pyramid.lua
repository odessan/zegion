--[[ Build a Pyramid -- haul blocks from the quarry to the pyramid, train, upgrade (123720558354386)

     BUILD   : lap after lap: hop onto the ground of the quarry, Pickup until your hands are full, hop to the
               part of the current pyramid layer with the most free cells, Place until your hands are empty.
               Nothing walks. About 24 blocks per 2.5s at Strength 806; the game's own bulk upgrades and
               Strength are what raise it. Hops land on the floor, not in the air.
     TRAIN   : StartBench on gym 1. The bench keeps paying after you leave it, so it runs beside the farm.
               Strength is the carry capacity (1 + level). Watches the stat and restarts the bench if it stops.
     UPGRADE : the cheaper next level of Bulk Pickup / Bulk Place, while a grab or a place is still smaller
               than your carry capacity. Fewer calls per lap; the capacity, not the call count, is the cap.
     KEEP    : the game's own AFK activity ping every few seconds (the game moves an idle player to an AFK
               server after 18 minutes) plus the usual Idled click.

     Probed and dead (do not re-probe):
       Pickup from 243 studs away         refused. Inside the Region:Quarry volume every call is answered
       Place on a cell 66 studs away      refused (range is 32 * (1 + 0.1 * placementRange level))
       StartBench from 109 studs away     refused; from 4 studs it starts
       hops (up to 371 studs)             all stuck, 20 of 20. No speed check, no snap-back
       call gap                           Pickup and Place answered at 0.02s; replies take ~0.07s, that is the pace
       codes                              WELCOME (500 Speed + 500 Strength), FREECODE (500 coins) one-time and spent,
                                          PYRAMID1500 FullyClaimed
     Facts the loop leans on:
       A refusal still returns the carry state ("count:units:...") as the second value, so the unit
       counter is read off every reply, refused or not. The first call after a 0.1s hop is refused
       (the server has not seen you arrive yet), so the phases retry instead of sleeping longer.
     Not wired (Robux): CommerceService, the SkipTiers products, gym 9.
     Not wired (not asked): placementRange (hopping makes range irrelevant), treadmills, gyms 2-8 (they need
       completed pyramids), the group free gift, muting the completion cutscene.
     UNPROVEN (prints its first outcome to F9): a pyramid completing mid-run (the loop waits for the reset),
       the bench surviving hundreds of laps (the watchdog restarts it), a layer change in the middle of a lap.

     RightControl opens / closes the panel. Stop: getgenv().pyramidStop() ]]

-- config ---------------------------------------------------------------------
local HOP_SETTLE = 0.1 -- after every teleport. Raise if the first Pickup/Place after a hop keeps being refused for more than a call or two
local CALL_GAP = 0.02 -- between Pickup / Place calls. 0.02 was fully answered; the reply time (~0.07s) is the real pace
local RETRY_GAP = 0.05 -- after a refusal that is not "full" / "empty"
local MISS_MAX = 6 -- refusals in a row before a phase gives up
local CALL_TIMEOUT = 5 -- an InvokeServer with no reply inside this is abandoned
local STAND_UP = 5 -- studs above a cell's centre to land on the pyramid (block top is 1.5 up, the root 3 above the feet)
local GROUND_UP = 3.5 -- studs above the quarry floor to land
local ARRIVE_NEAR = 15 -- a hop that ends further than this from its target did not stick
local RANGE_MARGIN = 2 -- a cell must be this far inside the place range
local SPACE_CELLS = 4 -- the next Place keeps this many cells off the last ones: the server fills extras within 3 of each
local SPACE_SECONDS = 1.2 -- ...for this long, until the replica shows them
local STALL_LAPS = 4 -- laps in a row that placed nothing before the toggle switches itself off and says why
local WAIT_POLL = 2 -- while the pyramid is complete / rebuilding
local BENCH_CHECK = 6 -- how often the bench is checked for still paying
local BENCH_SETTLE = 1.5 -- after StartBench, before the first reading
local UPGRADE_EVERY = 3
local UPGRADE_BACKOFF = 15 -- an upgrade the server did not take is not retried for this long
local AFK_EVERY = 4 -- the game's own client reports activity every 5s

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().pyramidStop then
	getgenv().pyramidStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[pyramid]", ...)
end

-- The panel strip is drained from a Heartbeat, which the engine calls with our own identity.
-- A loop thread that writes to the window directly throws "lacking capability Plugin" after its first task.wait.
local pending, lastSaid = {}, nil
local function say(msg, quiet)
	pending.now = msg
	if not quiet and msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- game -----------------------------------------------------------------------
local Services
do
	local packages = ReplicatedStorage:WaitForChild("Packages", 15)
	local index = packages and packages:WaitForChild("_Index", 15)
	for _, c in ipairs(index and index:GetChildren() or {}) do
		if c.Name:lower():find("knit") then -- the folder is versioned (sleitnick_knit@1.7.0): match inside the name
			local k = c:FindFirstChild("knit")
			Services = k and k:FindFirstChild("Services")
			if Services then
				break
			end
		end
	end
end
local Regions = workspace:WaitForChild("Regions", 15)
local Quarry = Regions and Regions:WaitForChild("Region:Quarry", 15)
-- Knit makes its remotes a moment after the server starts: wait for each one rather than indexing it
local function remote(service, kind, name, optional)
	local s = Services:WaitForChild(service, optional and 5 or 20)
	local k = s and s:WaitForChild(kind, optional and 5 or 20)
	local r = k and k:WaitForChild(name, optional and 5 or 20)
	if not r then
		if optional then
			warn("[pyramid] optional remote " .. service .. "." .. kind .. "." .. name .. " is missing; running without it")
			return nil
		end
		error(service .. "." .. kind .. "." .. name .. " never appeared")
	end
	return r
end
local ok, Pickup, Place, StartBench, StopBench, PurchaseUpgrade, AfkActivity, CarryChanged, BlockPlaced, StatValues, PR, UL, UCat, UE, PyramidConfig, CarryConfig, StatProgression, Suffixes = pcall(function()
	local Shared = ReplicatedStorage.Shared
	return remote("BookService", "RF", "Pickup"),
		remote("PyramidService", "RF", "Place"),
		remote("GymService", "RF", "StartBench"),
		remote("GymService", "RF", "StopBench"),
		remote("DataService", "RF", "PurchaseUpgrade"),
		remote("AFKService", "RE", "Activity", true),
		remote("BookService", "RE", "CarryStateChanged", true),
		remote("PyramidService", "RE", "BlockPlaced", true),
		remote("DataService", "RP", "StatValues", true),
		require(Shared.Placement.PyramidRuntime),
		require(Shared.Upgrades.UpgradeLevels),
		require(Shared.Config.UpgradeCatalog),
		require(Shared.Upgrades.UpgradeEffects),
		require(Shared.Config.PyramidConfig),
		require(Shared.Config.CarryConfig),
		require(Shared.Stats.StatProgression),
		require(Shared.Stats.Suffixes)
end)
if not (ok and Quarry) then
	warn("[pyramid] the game's remotes or modules were not found (" .. tostring(Pickup) .. "); it has probably been updated")
	return
end

local SUFFIX = {}
for i, s in ipairs(Suffixes) do
	SUFFIX[s] = 1000 ^ (i - 1)
end
local function parseNum(v) -- "1,100" -> 1100, "2.5K" -> 2500
	local s = tostring(v):gsub("[%$,%s]", "")
	local n, suf = s:match("^(%-?%d*%.?%d+)(%a*)$")
	local mult = n and SUFFIX[suf]
	return mult and tonumber(n) * mult or nil
end
assert(parseNum("1,100") == 1100 and parseNum("2.5K") == 2500 and parseNum("x") == nil)
local function fmt(n)
	if not n then
		return "-"
	end
	local i = 1
	while n >= 1000 and Suffixes[i + 1] do
		n, i = n / 1000, i + 1
	end
	return (i == 1 and "%d" or "%.2f"):format(n) .. Suffixes[i]
end

local units, coins = nil, nil -- carried blocks (read off every reply's receipt) and the coin balance (StatValues)
local stats = { laps = 0, placed = 0, grabs = 0, t0 = os.clock() }
local function seen(receipt)
	local u = type(receipt) == "string" and receipt:match("^%d+:(%d+)")
	if u then
		units = tonumber(u)
	end
end
local function capacity()
	return StatProgression.carryCapacityForLevel(CarryConfig.Capacity, player:GetAttribute("StrengthLevel"))
end
local function leaderstat(name)
	local ls = player:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild(name)
	return v and tostring(v.Value)
end

local conns = {}
if CarryChanged then
	table.insert(conns, CarryChanged.OnClientEvent:Connect(seen))
end
if StatValues then
	table.insert(conns, StatValues.OnClientEvent:Connect(function(t)
		if type(t) == "table" and parseNum(t.Coins) then
			coins = parseNum(t.Coins)
		end
	end))
end

-- world ----------------------------------------------------------------------
local recent = {} -- cells just placed on (and the extras the server added), kept clear of for a moment
local function nearRecent(x, z)
	local now = os.clock()
	for i = #recent, 1, -1 do
		local r = recent[i]
		if now - r.t > SPACE_SECONDS then
			table.remove(recent, i)
		elseif math.abs(r.x - x) <= SPACE_CELLS and math.abs(r.z - z) <= SPACE_CELLS then
			return true
		end
	end
	return false
end
local function mark(g, layer, s)
	local x, z = g.fromSlotIndex(layer, s)
	if x then
		recent[#recent + 1] = { x = x, z = z, t = os.clock() }
	end
end
if BlockPlaced then
	table.insert(conns, BlockPlaced.OnClientEvent:Connect(function(layer, slots)
		local c = PR.getContext(workspace)
		if c and type(slots) == "table" then
			for _, s in ipairs(slots) do
				mark(c.geometry, layer, s)
			end
		end
	end))
end

-- nearest free cell of the current layer to `at` (the finder the game's own ghost uses). reachFrom / reach
-- keep only cells the server will accept from where you stand; spaced skips cells next to the last Places
local function pickCell(at, radius, reachFrom, reach, spaced)
	local c = PR.getContext(workspace)
	if not c or c.model:GetAttribute("Complete") == true then
		return nil
	end
	local layer, gen = c.model:GetAttribute("CurrentLayer"), c.model:GetAttribute("PlacementGeneration")
	if not layer then
		return nil
	end
	local folder, g = c.model:FindFirstChild("Layer" .. layer), c.geometry
	local s = g.findNearestFreeSlot(layer, at, function(i)
		if not PR.isSlotFreeInReplica(folder, layer, i, nil, g) then
			return false
		end
		local x, z = g.fromSlotIndex(layer, i)
		if reachFrom and (g.getCellPosition(layer, x, z) - reachFrom).Magnitude > reach then
			return false
		end
		return not (spaced and nearRecent(x, z))
	end, radius)
	if not s then
		return nil
	end
	local x, z = g.fromSlotIndex(layer, s)
	return layer, s, gen, g.getCellPosition(layer, x, z), g
end

-- A spot over a free cell in the busiest part of the layer: the 3x3 patches (10x10 cells each) with the most
-- free cells. ponytail: counts the '0's of the occupancy masks, so a patch hanging over the layer's edge counts a
-- little high; the free-cell finder below it is what decides, this only picks where to start
local function bestSpot()
	local c = PR.getContext(workspace)
	local layer = c and c.model:GetAttribute("CurrentLayer")
	if not layer or c.model:GetAttribute("Complete") == true then
		return nil
	end
	local g, folder = c.geometry, c.model:FindFirstChild("Layer" .. layer)
	local side, patch = g.getLayerSide(layer), PyramidConfig.PatchSide
	local anchor
	if folder and folder:GetAttribute("OccupancyVersion") == 1 then
		local cols = g.getPatchColumns(layer)
		local free = {}
		for i = 1, cols * cols do
			local m = folder:GetAttribute("OccupiedPatch" .. i)
			free[i] = type(m) == "string" and select(2, m:gsub("0", "")) or 0
		end
		local best, bestScore = nil, 0
		for pz = 0, cols - 1 do
			for px = 0, cols - 1 do
				local score = 0
				for dz = -1, 1 do
					for dx = -1, 1 do
						local qx, qz = px + dx, pz + dz
						if qx >= 0 and qx < cols and qz >= 0 and qz < cols then
							score += free[qz * cols + qx + 1]
						end
					end
				end
				if score > bestScore then
					best, bestScore = { px, pz }, score
				end
			end
		end
		if best then
			anchor = g.getCellPosition(layer, math.min(best[1] * patch + patch // 2, side - 1), math.min(best[2] * patch + patch // 2, side - 1))
		end
	end
	anchor = anchor or g.getCellPosition(layer, side // 2, side // 2)
	local _, _, _, p = pickCell(anchor, side, nil, nil, false)
	return p and CFrame.new(p + Vector3.new(0, STAND_UP, 0))
end

local quarryStand = nil
local function findQuarryStand() -- the floor under the middle of the quarry volume, so hops land on the ground
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local skip = { Quarry }
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(skip, p.Character)
		end
	end
	params.FilterDescendantsInstances = skip
	local hit = workspace:Raycast(Quarry.Position, Vector3.new(0, -400, 0), params)
	local top = Quarry.Position.Y + Quarry.Size.Y / 2
	local y = hit and hit.Position.Y + GROUND_UP or Quarry.Position.Y
	quarryStand = CFrame.new(Quarry.Position.X, math.min(y, top), Quarry.Position.Z)
	return quarryStand
end

local function root()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function hop(cf) -- true when the move stuck
	local hrp = root()
	if not hrp then
		return false
	end
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.CFrame = cf
	task.wait(HOP_SETTLE)
	hrp = root()
	return hrp ~= nil and (hrp.Position - cf.Position).Magnitude < ARRIVE_NEAR
end

-- the character: one claim, wrapped around everything that teleports, and nothing else
local busy, waiting = false, 0
local function claim(fn)
	waiting += 1
	while busy do
		task.wait()
	end
	waiting -= 1
	busy = true
	local good, err = pcall(fn)
	busy = false
	if not good then
		log("error: " .. tostring(err))
	end
	return good
end

local function callTimed(remote, ...) -- returns the first two replies, or nil when it errored or timed out
	local args, done, out = table.pack(...), false, nil
	task.spawn(function()
		out = table.pack(pcall(remote.InvokeServer, remote, table.unpack(args, 1, args.n)))
		done = true
	end)
	local deadline = os.clock() + CALL_TIMEOUT
	while not done and os.clock() < deadline do
		task.wait()
	end
	if done and out[1] then
		return out[2], out[3], out[4]
	end
	return nil
end

-- farm -----------------------------------------------------------------------
-- The server's real carry cap can sit under the client's formula (1 + StrengthLevel). When it refuses grabs while
-- you hold blocks, that is "full": the number is kept (until Strength changes) so the next lap does not hop to the
-- quarry for nothing, and the lap goes on to place what it holds.
local learned = nil -- { at = capacity() when learned, units = what the server held at }
local function fullAt()
	local cap = capacity()
	return learned and learned.at == cap and learned.units or cap
end
local function fill(alive) -- Pickup until the hands are full
	local miss = 0
	while alive() and (units == nil or units < fullAt()) do
		local good, receipt = callTimed(Pickup, Quarry)
		seen(receipt) -- a refusal carries the state too
		if good == true then
			miss = 0
			stats.grabs += 1
		else
			miss += 1
			if miss >= MISS_MAX then
				local hrp = root()
				if units and units > 0 then
					learned = { at = capacity(), units = units }
					log(("quarry refuses grabs at %d units (formula says %d): treating that as full"):format(units, capacity()))
					return nil
				end
				log(("quarry refused %d grabs with empty hands | stood %s | %s from the quarry centre | cap %d"):format(
					MISS_MAX, tostring(hrp and hrp.Position), hrp and math.floor((hrp.Position - Quarry.Position).Magnitude) or "?", capacity()))
				return "the quarry refused " .. MISS_MAX .. " grabs with empty hands"
			end
			task.wait(RETRY_GAP)
		end
		task.wait(CALL_GAP)
	end
end

local function drain(alive) -- Place until the hands are empty, moving to a fuller part of the layer when none is in reach
	local miss, moves = 0, 0
	while alive() and (units == nil or units > 0) do
		local hrp = root()
		if not hrp then
			return "wait"
		end
		local reach = UE.placeDistance(player, PyramidConfig.PlaceDistance) - RANGE_MARGIN
		local layer, s, gen, _, g = pickCell(hrp.Position, math.ceil(reach / PyramidConfig.BlockSize), hrp.Position, reach, true)
		if not layer then
			local cf = bestSpot()
			if not cf then
				return "wait" -- complete, rebuilding or not streamed in: keep the blocks and look again
			end
			moves += 1
			if moves > 3 then
				return "no free cell in reach after " .. (moves - 1) .. " moves"
			end
			if not hop(cf) then
				return "the hop onto the pyramid did not stick"
			end
		else
			local good, receipt, n = callTimed(Place, layer, s, gen)
			seen(receipt)
			if good == true then
				miss = 0
				stats.placed += n or 1
				mark(g, layer, s)
			else
				miss += 1
				if miss >= MISS_MAX then
					return "the pyramid refused " .. MISS_MAX .. " places"
				end
				task.wait(RETRY_GAP)
			end
		end
		task.wait(CALL_GAP)
	end
end

local function lap(alive) -- returns nil, or why it got nowhere ("wait" = not a failure)
	if not root() then
		return "wait"
	end
	if units == nil or units < fullAt() then
		if not hop(quarryStand or findQuarryStand()) then
			return "the hop to the quarry did not stick"
		end
		say("quarry: grabbing", true)
		local why = fill(alive)
		if why and units == 0 then
			-- the floor spot was refused with empty hands: the spot probe 2 proved (middle of the volume, in the air) once
			log("retrying the quarry from the middle of the volume")
			hop(CFrame.new(Quarry.Position + Vector3.new(0, 4, 0)))
			why = fill(alive)
		end
		if why then
			return why
		end
	end
	if not alive() then
		return nil
	end
	if units == 0 then
		return "nothing was picked up"
	end
	local cf = bestSpot()
	if not cf then
		return "wait"
	end
	say("pyramid: placing", true)
	if not hop(cf) then
		return "the hop onto the pyramid did not stick"
	end
	return drain(alive)
end

local farm = { on = false, gen = 0 }
local farmToggle
local function setFarm(state)
	farm.gen += 1
	farm.on = state
	if not state then
		return
	end
	local mine = farm.gen
	local function alive()
		return farm.on and farm.gen == mine
	end
	task.spawn(function()
		pcall(findQuarryStand)
		local stalled = 0
		while alive() do
			local before, why = stats.placed, nil
			claim(function()
				why = lap(alive)
			end)
			if not alive() then
				break
			end
			if why == "wait" then
				say("waiting: the pyramid is complete, rebuilding or not loaded")
				task.wait(WAIT_POLL)
			elseif stats.placed == before then
				stalled += 1
				say(why or "a lap placed nothing", true)
				if stalled >= STALL_LAPS then
					log("stopped: " .. tostring(why or "laps placed nothing"))
					say("stopped: " .. tostring(why or "laps placed nothing"))
					pcall(function()
						if farm.gen == mine then
							farmToggle:SetValue(false)
						end
					end)
					return
				end
			else
				stalled = 0
				stats.laps += 1
			end
			if waiting > 0 then
				task.wait() -- let a waiting bench start take the character between laps
			end
		end
	end)
end

-- train ----------------------------------------------------------------------
local function startBench() -- body for claim: hop to bench 1, start it, hop back
	local gym = workspace:FindFirstChild("Gym")
	local folder = gym and gym:FindFirstChild("1")
	local pp = folder and folder:FindFirstChild("PromptPart", true)
	local hrp = root()
	if not (pp and hrp) then
		say("bench: gym 1 is not loaded")
		return false
	end
	local back = hrp.CFrame
	if not hop(CFrame.new(pp.Position + Vector3.new(0, 3, 4))) then
		say("bench: the hop did not stick")
		hop(back)
		return false
	end
	local good = callTimed(StartBench, "1")
	hop(back)
	if good ~= true then
		say("bench: the server refused StartBench")
	end
	return good == true
end

local bench = { on = false, gen = 0 }
local function setBench(state)
	bench.gen += 1
	bench.on = state
	if not state then
		task.spawn(function()
			pcall(callTimed, StopBench) -- server state: it keeps training until told, even from far away
		end)
		return
	end
	local mine = bench.gen
	task.spawn(function()
		local last = nil
		while bench.on and bench.gen == mine do
			local now = leaderstat("Strength")
			if now == nil or now == last then -- not rising: (re)start it
				claim(function()
					if bench.on and bench.gen == mine then
						startBench()
					end
				end)
				task.wait(BENCH_SETTLE)
				last = leaderstat("Strength")
			else
				last = now
				say("bench: training", true)
			end
			task.wait(BENCH_CHECK)
		end
	end)
end

-- upgrade --------------------------------------------------------------------
local UPGRADES = { "bulkPickup", "bulkPlace" } -- placementRange is not wired: hopping makes range irrelevant
local upgrade = { on = false, gen = 0 }
local backoff = {}
local function setUpgrade(state)
	upgrade.gen += 1
	upgrade.on = state
	if not state then
		return
	end
	local mine = upgrade.gen
	task.spawn(function()
		while upgrade.on and upgrade.gen == mine do
			local best, bestCost
			for _, id in ipairs(UPGRADES) do
				local def = UCat.ById[id]
				local lvl = UL.fromPlayer(player, id)
				local cost = def and lvl < def.MaxLevel and def.Costs[lvl + 1]
				-- a grab / a place that already holds your whole capacity gains nothing from the next level
				if cost and 1 + lvl < capacity() and (backoff[id] or 0) <= os.clock() and coins and cost <= coins and (not bestCost or cost < bestCost) then
					best, bestCost = id, cost
				end
			end
			if best then
				local before = UL.fromPlayer(player, best)
				local reply = callTimed(PurchaseUpgrade, best)
				task.wait(0.5)
				if UL.fromPlayer(player, best) > before then
					log(("bought %s level %d for %s"):format(best, before + 1, fmt(bestCost)))
				else
					backoff[best] = os.clock() + UPGRADE_BACKOFF
					log(("%s was not bought (reply %s)"):format(best, tostring(reply)))
				end
			end
			task.wait(UPGRADE_EVERY)
		end
	end)
end

-- keep -----------------------------------------------------------------------
local afk = { on = false, gen = 0 }
local function setAfk(state)
	afk.gen += 1
	afk.on = state
	if not state then
		return
	end
	local mine = afk.gen
	task.spawn(function()
		while afk.on and afk.gen == mine do
			if AfkActivity then
				pcall(AfkActivity.FireServer, AfkActivity)
			end
			task.wait(AFK_EVERY)
		end
	end)
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Build a Pyramid", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "triangle")
local Build = Tab:AddLeftGroupbox("Pyramid", "triangle")
local Train = Tab:AddRightGroupbox("Train", "dumbbell")
local Up = Tab:AddRightGroupbox("Upgrades", "trending-up")
local Keep = Tab:AddRightGroupbox("Keep alive", "shield")

farmToggle = Build:AddToggle("Farm", {
	Text = "Auto Build Pyramid",
	Tooltip = "Hops to the quarry floor, grabs until full, hops to the freest part of the current layer, places until empty. Moves your character: do not run it with Auto Train's hop at the same moment (they take turns)",
	Default = false,
	Callback = setFarm,
})
Train:AddToggle("Bench", {
	Text = "Auto Train Strength (bench 1)",
	Tooltip = "Starts the gym 1 bench and leaves; it keeps paying from anywhere. Strength is your carry capacity. Restarted if the stat stops rising, stopped when you untick it or unload",
	Default = false,
	Callback = setBench,
})
Up:AddToggle("Upgrade", {
	Text = "Auto Upgrade (Bulk Pickup / Place)",
	Tooltip = "Buys the cheaper next level of Bulk Pickup or Bulk Place while one grab / place is still smaller than your carry capacity. Coins only: no Robux route is touched",
	Default = false,
	Callback = setUpgrade,
})
Keep:AddToggle("Afk", {
	Text = "Anti AFK",
	Tooltip = "Sends the game's own activity ping every few seconds. The game moves an idle player to an AFK server after 18 minutes",
	Default = true,
	Callback = setAfk,
})
setAfk(true) -- Default does not fire the callback, so arm it by hand

-- Calling a function out of a game module (PR.getContext, capacity) switches the calling thread to that script's
-- context, and a SetStatus after it throws "lacking capability Plugin" every beat. So the game's functions are
-- read on their own thread into plain values, and the Heartbeat below only touches those.
local info, infoLive = { layer = "-", cap = 0 }, true
task.spawn(function()
	while infoLive do
		pcall(function()
			local c = PR.getContext(workspace)
			info.layer = c and (c.model:GetAttribute("Complete") == true and "done" or c.model:GetAttribute("CurrentLayer")) or "-"
			info.cap = capacity()
		end)
		task.wait(0.5)
	end
end)

local note = "idle"
local nextStrip = 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	if pending.now then
		note, pending.now = pending.now, nil
	end
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	local mins = (now - stats.t0) / 60
	Window:SetStatus({
		{ "Coins", fmt(coins) },
		{ "Strength", leaderstat("Strength") or "-" },
		{ "Carry", (units or 0) .. "/" .. info.cap },
		{ "Layer", info.layer },
		{ "Placed", stats.placed },
		{ "Per min", mins > 0.2 and math.floor(stats.placed / mins) or "-" },
		{ "Laps", stats.laps },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("PyramidBuilder", {})

local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- close ----------------------------------------------------------------------
local function stopAll()
	infoLive = false
	setFarm(false)
	setUpgrade(false)
	setAfk(false)
	if bench.on then
		setBench(false) -- StopBench: the bench is server state and outlives the panel
	end
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().pyramidStop = nil
end)

getgenv().pyramidStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().pyramidStop = nil
end
