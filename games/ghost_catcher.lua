--[[ Ghost Catcher -- catch orbs by zone, place, hatch, train, upgrade training and pen (70577084454790)
     PlaceVersion 2891

     ZONES   : World 1..10 are stretches of one road along +Z (centres in ZONES); CurrentWorld follows your
               position and a zone's orbs only stream in once you are there. A 300s cycle (SpecialSpawnTimer):
               "Hunt", then a ~20s "Reset" that closes the wall at z=202 (BarrierClosed) and sends everyone home.
               OrbsLeft_<World> counts what a zone has left this cycle (World 1: -1, endless). The highest ticked
               zone with orbs left and Power for its Commons goes first.
     CATCH   : glides to the best orb (zone, then rarity, then distance), fires its CatchPrompt in range,
               then plays the catch by remote: CatchSequence.Progress(orb, true, t, "kb") holds, and every yank the
               server announces (Update.y = { s, b, e }) gets a release then a press inside [b, e] ("hit").
               The fill is server-simulated (CatchBalance.FILL_SECONDS: ~5s Common .. ~9.4s Divine, plus yanks):
               that is the floor. Probed: a Progress timestamp forged 4s early is ignored.
     PLACE   : on your plot only (refused silently from 100 studs, accepted on it): equip the orb Tool, the server
               answers EnterPlacementMode, then PlotSystem.ConfirmPlacement(pos) on a free spot of a grid.
     HATCH   : HatchSystem.RequestHatch(orb) once HatchState is READY, then HatchSystem.EquipBest() puts the ghost
               on the plot (probed: income 5 -> 7/s). Position-free: hatched from 121 studs away in a live run.
     HOME    : every errand at home (place, pad, signs) starts with the HUD's Base button,
               QuickTravel.TravelRequest("Base"): ~0.05s to ~25 studs from your plot, then a short glide.
               Ignored every time from World 2 (cause unknown); then the bus brings you home (~6s).
     PLOT    : orbs have their own cap, HatchConfig.GetPlotSlots(BuiltLevel) (6 at level 2, 8 at 4), apart from
               ghosts; EquipBest fills the ghost slots and leaves the weak ghosts in the bag (not sold).
     TRAIN   : stand on your station's "stand area" and the server trains you (+PowerPerSecond of the level;
               probed +28 in 6s at level 2). TrainingRemotes.TrainingState:FireServer() stops it. Training only
               fills the time nothing else needs the character: catching comes first.
     UPGRADES: the sign prompts, within 10 studs: TrainingUpgradePrompt and PlotUpgradePrompt. Probed while broke:
               the server answered "poor" / "NOT ENOUGH CASH", so the route reaches the purchase. The Robux prompt
               beside the training one (TrainingRobuxPrompt) is never fired. Pen goes first when both are affordable.

     Movement: KICK-WEIGHTED. Probed 2026-10-11: single hops of 40 studs held, 80 reverted (the server rewrote
     AC_AllowUntil); a chain at 60 studs/s reverted after ~90 studs; 10-stud steps every 0.3s (33 studs/s) held
     for 100 studs, 40 studs/s reverted after 50. GLIDE_STEP / GLIDE_GAP stay under that; walking (20/s) got
     stuck on fences. Inside the Ghost Bus (GhostBus.Toggle) the check lifts: 83 studs/s clean, ~91 flagged,
     167 reverted, so every long glide rides it (BUS_GAP). No zone-teleport remote exists: PortalTravel is
     leftover kit code, QuickTravel only knows Base / Gear / Sell.
     Live runs 2026-10-11: 40+ catches, 0 lost, 1 training and 1 pen upgrade bought, World 2 hunted at 550+ Power.

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().ghostCatcherStop() ]]

-- config ---------------------------------------------------------------------
local GLIDE_STEP = 10 -- studs per hop; 40 held, 80 reverted
local GLIDE_GAP = 0.33 -- seconds between hops (30 studs/s); raise if "glide reverted" shows up
local REVERT = 5 -- a hop that lands further than this from its aim is a revert
local BUS_MIN = 80 -- a glide longer than this rides the Ghost Bus
local BUS_GAP = 0.12 -- seconds between hops in the bus: 83 studs/s clean, ~91 flagged (AC_AllowUntil), 167 reverted
local HOME_FAR = 40 -- an errand at home further than this takes the Base button instead of a glide
local HOP_MAX = 35 -- an orb this close is one hop (40 held, 80 reverted), when we have stood still HOP_REST
local HOP_REST = 1
local LOOK_AGAIN = 45 -- a ticked zone we went to look at is not visited again for this long unless it streams orbs
local MIN_POWER_RATIO = 1 -- skip orbs whose CatchBalance required power is above Power x this (weak catches crawl)
local CATCH_REACH = 5 -- glide this close to an orb (its prompt reaches 12-15)
local START_WAIT = 1.5 -- after the prompt, how long to wait for the server's Start
local YANK_AT = 0.4 -- press this far into a yank window [b, e]; 0.45 probed as a hit
local CATCH_TIMEOUT = 30 -- a catch with no End by then is let go
local BENCH = 20 -- an orb we failed on is skipped this long
local PLACE_BATCH = 5 -- go home to place once the bag holds this many orbs (a full bag always goes)
local PLACE_STEP = 6 -- grid spacing of placement spots on the plot
local PLACE_MARGIN = 3 -- the client keeps placements this far inside the plot edge
local PLACE_CLEAR = 4.5 -- a spot this close to an orb or ghost of ours is taken
local PLACE_WAIT = 1.5 -- after ConfirmPlacement, how long the orb gets to leave the bag
local PLOT_FULL_WAIT = 20 -- after the plot refuses three spots in a row, no place trip for this long
local HATCH_EVERY = 1
local HATCH_RETRY = 6 -- an orb we asked to hatch is not asked again for this long
local EQUIP_GAP = 6 -- EquipBest at most this often
local UPGRADE_BACKOFF = 15 -- a purchase that did not take is not retried for this long
local TICK = 0.2 -- the director's beat
local WATCHDOG = 40 -- a loop whose step mark stops moving this long is reported

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().ghostCatcherStop then
	getgenv().ghostCatcherStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[ghost]", ...)
end

local seen = {}
local function first(name, ...)
	if not seen[name] then
		seen[name] = true
		log("first", name, ...)
	end
end

-- The strip is drained from a Heartbeat (our own identity); a loop thread writing to the window
-- throws "lacking capability Plugin" after its first task.wait.
local note, lastSaid = "idle", nil
local function say(msg)
	note = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- game -----------------------------------------------------------------------
local ok, CatchBalance, TrainingConfig, HatchConfig = pcall(function()
	return require(ReplicatedStorage:WaitForChild("CatchBalance", 10)),
		require(ReplicatedStorage:WaitForChild("TrainingConfig", 10)),
		require(ReplicatedStorage:WaitForChild("HatchConfig", 10))
end)
if not ok then
	warn("[ghost] the game's modules did not load:", CatchBalance)
	return
end

local CS = ReplicatedStorage:WaitForChild("CatchSequence", 10)
local PlotSystem = ReplicatedStorage:WaitForChild("PlotSystem", 10)
local HatchSystem = ReplicatedStorage:WaitForChild("HatchSystem", 10)
local TrainingRemotes = ReplicatedStorage:WaitForChild("TrainingRemotes", 10)
local PlotUpgrade = ReplicatedStorage:WaitForChild("PlotUpgrade", 10)
if not (CS and PlotSystem and HatchSystem and TrainingRemotes and PlotUpgrade) then
	warn("[ghost] a remote folder is missing: the game changed")
	return
end

local BAG = CatchBalance.ORB_BAG or 20
local RANK = CatchBalance.RARITY_DIFFICULTY or {}

-- Zones are stretches of one road along +Z; CurrentWorld follows your position and a zone's orbs only stream
-- in once you are there. Centres probed 2026-10-11 from the orbs' Float_areaCenter attributes.
local ZONES = {
	World1 = Vector3.new(0, 0, -22),
	World2 = Vector3.new(1, 0, 295),
	World3 = Vector3.new(-1, 0, 472),
	World4 = Vector3.new(2, 0, 650),
	World5 = Vector3.new(3, 0, 834),
	World6 = Vector3.new(3, 0, 1007),
	World7 = Vector3.new(3, 0, 1357),
	World8 = Vector3.new(3, 0, 1184),
	World9 = Vector3.new(3, 0, 1530), -- ponytail: W9/W10 extrapolated (+175 a zone), the zone cache corrects them on sight
	World10 = Vector3.new(3, 0, 1705),
}
local ORDER = { "World1", "World2", "World3", "World4", "World5", "World6", "World7", "World8", "World9", "World10" }
local WORLD_N = {}
for i, w in ipairs(ORDER) do
	WORLD_N[w] = i
end
local okWI, WorldInfo = pcall(function()
	return require(ReplicatedStorage:WaitForChild("WorldInfo", 5))
end)
local function zoneLabel(w)
	local info = okWI and WorldInfo and WorldInfo.WORLDS and WorldInfo.WORLDS[w]
	return ("%d %s"):format(WORLD_N[w], info and info.Name or w)
end
assert(WORLD_N.World10 == 10, "world order")

local function now()
	return workspace:GetServerTimeNow()
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

local function stat(name)
	local ls = player:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild(name)
	return v and tonumber(v.Value) or 0
end

local stats = { caught = 0, missed = 0, placed = 0, hatched = 0, trainUps = 0, pens = 0, reverts = 0 }

-- breadcrumbs: every loop marks its step, a watchdog names the one that stopped moving
local marks = {}
local function step(loop, what)
	marks[loop] = { what, os.clock() }
end

local running = true
local want = { catch = false, place = false, hatch = false, train = false, trainUp = false, pen = false }

local function root()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hum and hrp and hum.Health > 0 then
		return hrp, hum
	end
	return nil, nil
end

-- world ----------------------------------------------------------------------
local function myPlot()
	local plots = workspace:FindFirstChild("Plots")
	for _, p in ipairs(plots and plots:GetChildren() or {}) do
		if p:GetAttribute("OwnerUserId") == player.UserId then
			return p
		end
	end
	return nil
end

local function mine(folderName)
	local out = {}
	local f = workspace:FindFirstChild(folderName)
	for _, m in ipairs(f and f:GetChildren() or {}) do
		if m:GetAttribute("OwnerUserId") == player.UserId then
			out[#out + 1] = m
		end
	end
	return out
end

local function tools()
	local out = {}
	for _, holder in ipairs({ player:FindFirstChildOfClass("Backpack"), player.Character }) do
		for _, t in ipairs(holder and holder:GetChildren() or {}) do
			if t:IsA("Tool") then
				out[#out + 1] = t
			end
		end
	end
	return out
end

local function bagOrbs()
	local out = {}
	for _, t in ipairs(tools()) do
		if t:GetAttribute("IsOrb") then
			out[#out + 1] = t
		end
	end
	-- rarest first, so a short plot takes the best ones
	table.sort(out, function(a, b)
		return (RANK[a:GetAttribute("Rarity")] or 0) > (RANK[b:GetAttribute("Rarity")] or 0)
	end)
	return out
end

local function bagGhosts()
	local n = 0
	for _, t in ipairs(tools()) do
		if not t:GetAttribute("IsOrb") and t:GetAttribute("GhostRecordId") then
			n += 1
			first("ghost-tool", t.Name)
		end
	end
	return n
end

local groundParams = RaycastParams.new()
local function groundY(p, fallback)
	groundParams.FilterDescendantsInstances = { player.Character }
	-- from just above the character: a ray from high up lands you on tree crowns and sign boards
	local hit = workspace:Raycast(Vector3.new(p.X, p.Y + 6, p.Z), Vector3.new(0, -60, 0), groundParams)
	return hit and hit.Position.Y or fallback
end

-- The wall between World 1 and World 2 closes for the ~20s "Reset" phase of the 5-minute cycle
-- (SpecialSpawnTimer.BarrierClosed); the server then sends everyone home and pushes back anyone crossing it.
local function wallBetween(a, b)
	local timer = ReplicatedStorage:FindFirstChild("SpecialSpawnTimer")
	local wall = workspace:FindFirstChild("WorldBarrier")
	local col = wall and wall:FindFirstChild("Collider")
	if not (timer and timer:GetAttribute("BarrierClosed") and col) then
		return false
	end
	return (a.Z - col.Position.Z) * (b.Z - col.Position.Z) < 0
end

local lastHop = 0
-- Moves by GLIDE_STEP hops every GLIDE_GAP, standing on whatever ground is under each hop. `target` is a
-- Vector3 or a function returning one (an orb floats). Returns whether we got within `reach`.
-- The Ghost Bus (GhostBus.Toggle, the game's own vehicle, WalkSpeed 44 and up to x2.3 boosted) lifts the
-- server's speed check: our hops ran clean at 83 studs/s inside it against ~33 on foot. It refuses to start in
-- the spawn circle and no-drive zones; then we glide on foot.
local GhostBus = ReplicatedStorage:FindFirstChild("GhostBus")
local busRefusedUntil = 0
local function inBus()
	return player:GetAttribute("InGhostBus") == true
end
local function setBus(on)
	if not GhostBus or inBus() == on then
		return inBus() == on
	end
	if on and os.clock() < busRefusedUntil then
		return false
	end
	GhostBus.Toggle:FireServer()
	local t = os.clock()
	while inBus() ~= on and os.clock() - t < 1.5 do
		task.wait(0.05)
	end
	if on and not inBus() then
		busRefusedUntil = os.clock() + 2 -- no-drive zones are small: the glide asks again once it has moved on
		first("bus-refused", Vector3.new(math.floor(root() and root().Position.X or 0), 0, math.floor(root() and root().Position.Z or 0)))
	elseif on then
		first("bus")
		task.wait(0.3)
	end
	return inBus() == on
end

local glideSteps
local function glide(target, reach)
	local hrp = root()
	local aim = type(target) == "function" and target() or nil
	if type(target) ~= "function" then
		aim = target
	end
	local far = hrp and aim and (Vector3.new(aim.X - hrp.Position.X, 0, aim.Z - hrp.Position.Z)).Magnitude > BUS_MIN
	local t0, from = os.clock(), hrp and hrp.Position
	local okG, usedBus = glideSteps(target, reach, far)
	if inBus() then
		setBus(false) -- catching, placing and the pad all want you on foot
	end
	local now_ = root()
	if far and from and now_ then
		log(("glide %d studs in %.1fs (%s)%s"):format((now_.Position - from).Magnitude, os.clock() - t0, usedBus and "bus" or "on foot", okG and "" or " - did not arrive"))
	end
	return okG
end

-- Boards the bus whenever more than BUS_MIN is left and it is not refusing (an orb area is a no-drive
-- zone: start on foot, board once out of it).
function glideSteps(target, reach, wantBus)
	local busLift, usedBus = nil, false
	for _ = 1, 600 do
		if not running then
			return false, usedBus
		end
		local hrp, hum = root()
		if not hrp then
			return false, usedBus
		end
		local aim = target
		if type(target) == "function" then
			aim = target() -- nil once the orb is gone; `f() or f` would hand back the function
		end
		if not aim or wallBetween(hrp.Position, aim) then
			return false, usedBus
		end
		local flat = Vector3.new(aim.X - hrp.Position.X, 0, aim.Z - hrp.Position.Z)
		if flat.Magnitude <= reach then
			return true, usedBus
		end
		if wantBus and not inBus() and flat.Magnitude > BUS_MIN and os.clock() >= busRefusedUntil and setBus(true) then
			usedBus = true
			hrp, hum = root()
			if not hrp then
				return false, usedBus
			end
			busLift = math.clamp(hrp.Position.Y - groundY(hrp.Position, hrp.Position.Y - 3), 2, 8)
		end
		hum:MoveTo(hrp.Position) -- a leftover walk order drags you back off every hop
		local stepV = flat.Magnitude > GLIDE_STEP and flat.Unit * GLIDE_STEP or flat
		if flat.Magnitude <= HOP_MAX and os.clock() - lastHop >= HOP_REST then
			stepV = flat -- from rest, a near target is one hop; mid-glide it would be a burst over the speed check
		end
		lastHop = os.clock()
		local lift = (busLift and inBus()) and busLift or hum.HipHeight + hrp.Size.Y / 2 + 0.2
		local nxt = hrp.Position + stepV
		nxt = Vector3.new(nxt.X, groundY(nxt, hrp.Position.Y - lift) + lift, nxt.Z)
		hrp.CFrame = CFrame.lookAt(nxt, nxt + stepV)
		hrp.AssemblyLinearVelocity = Vector3.zero
		task.wait((busLift and inBus()) and BUS_GAP or GLIDE_GAP)
		local after = root()
		if after and (after.Position - nxt).Magnitude > REVERT then
			stats.reverts += 1
			say(("glide reverted (%d so far)"):format(stats.reverts))
			task.wait(1)
		end
	end
	return false, usedBus
end

-- The HUD's Base button: QuickTravel.TravelRequest("Base") moves you in ~0.05s to ~25 studs from your plot
-- (probed; the server rewrites AC_AllowUntil itself, so it is the sanctioned teleport). Any errand at home
-- takes it when home is further than a short glide, then glides the rest.
local QuickTravel = ReplicatedStorage:FindFirstChild("QuickTravel")
local function goHome(aim, reach)
	local hrp = root()
	if hrp and QuickTravel and (Vector3.new(aim.X - hrp.Position.X, 0, aim.Z - hrp.Position.Z)).Magnitude > HOME_FAR then
		-- right after a catch the server ignores the request (both slow trips started 0.2s after an End)
		local t = os.clock()
		while player.Character and player.Character:GetAttribute("CatchOrb") and os.clock() - t < 3 do
			task.wait(0.1)
		end
		-- ponytail: from World 2 it was ignored every time (cause unknown), so one try, then the bus home
		local from, moved = hrp.Position, false
		QuickTravel.TravelRequest:FireServer("Base")
		t = os.clock()
		while os.clock() - t < 1.5 and not moved do
			local h = root()
			moved = h ~= nil and (h.Position - from).Magnitude > 10
			task.wait()
		end
		if moved then
			first("base-travel")
			task.wait(0.3) -- let the server see where it put us before the first hop
		else
			first("base-travel-ignored", player:GetAttribute("CurrentWorld"))
		end
	end
	return glide(aim, reach)
end

local function leaveTraining()
	if player:GetAttribute("TrainingLock") then
		TrainingRemotes.TrainingState:FireServer() -- what the game's own jump-to-leave sends
		task.wait(0.4)
	end
end

-- catch ----------------------------------------------------------------------
local cur = { orb = nil, started = nil, last = nil, ended = nil }
local conns = {}
table.insert(
	conns,
	CS.Start.OnClientEvent:Connect(function(orb)
		if orb == cur.orb then
			cur.started = orb
		end
	end)
)
table.insert(
	conns,
	CS.Update.OnClientEvent:Connect(function(u)
		if type(u) == "table" then
			cur.last = u
		end
	end)
)
table.insert(
	conns,
	CS.End.OnClientEvent:Connect(function(okEnd, rarity, weight)
		cur.ended = { ok = okEnd, rarity = rarity, weight = weight }
	end)
)

local benched = setmetatable({}, { __mode = "k" })
local folders, foldersAt = {}, -math.huge
local function spawnFolders()
	if os.clock() - foldersAt > 30 then
		foldersAt = os.clock()
		table.clear(folders)
		for _, d in ipairs(workspace:GetDescendants()) do
			if d.Name == "SpawnedOrbs" then
				folders[#folders + 1] = d
			end
		end
	end
	return folders
end

local zoneOn = { World1 = true }

local function canCatch(world, rarity)
	local okP, need = pcall(CatchBalance.GetRequiredPower, world, rarity)
	return not (okP and type(need) == "number") or stat("Power") >= need * MIN_POWER_RATIO
end

-- the best streamed orb in a ticked zone: highest zone, then rarest, then nearest
local function pickOrb()
	local hrp = root()
	if not hrp then
		return nil
	end
	local best, bestKey
	for _, f in ipairs(spawnFolders()) do
		for _, o in ipairs(f:GetChildren()) do
			local world, rarity = o:GetAttribute("WorldId"), o:GetAttribute("Rarity")
			if zoneOn[world] and (benched[o] or 0) < os.clock() and canCatch(world, rarity) then
				local pr = o:FindFirstChildWhichIsA("ProximityPrompt", true)
				local pos = o:GetPivot().Position
				if pr and pr.Enabled and pos.Magnitude > 1 then
					local key = (WORLD_N[world] or 0) * 1e6 + (RANK[rarity] or 0) * 1e4 - (pos - hrp.Position).Magnitude
					if not best or key > bestKey then
						best, bestKey = o, key
					end
				end
			end
		end
	end
	return best
end

-- A ticked zone above `floor` that may hold orbs we cannot see from here: the server's per-cycle count says
-- some are left, the wall is open, Power covers its Commons, and we have not just looked.
local looked = {}
local function spawnTimer()
	return ReplicatedStorage:FindFirstChild("SpecialSpawnTimer")
end
local function zoneToVisit(floor)
	local timer = spawnTimer()
	local closed = timer and timer:GetAttribute("BarrierClosed")
	for i = #ORDER, floor + 1, -1 do
		local w = ORDER[i]
		local left = timer and timer:GetAttribute("OrbsLeft_" .. w)
		if zoneOn[w] and ZONES[w] and (w == "World1" or not closed) and left ~= 0 and canCatch(w, "Common") and (looked[w] or 0) + LOOK_AGAIN < os.clock() then
			return w
		end
	end
	return nil
end

local function visit(w)
	looked[w] = os.clock()
	step("dir", "zone " .. w)
	say("zone: going to look in " .. zoneLabel(w))
	glide(ZONES[w], 8)
	task.wait(1) -- the zone's orbs stream in
end

local function catch(orb)
	local rarity = tostring(orb:GetAttribute("Rarity"))
	local pr = orb:FindFirstChildWhichIsA("ProximityPrompt", true)
	if not pr then
		return nil
	end
	step("dir", "catch " .. rarity .. " / glide")
	say("catch: going to " .. rarity)
	if not glide(function()
		return orb.Parent and orb:GetPivot().Position or nil
	end, CATCH_REACH) then
		benched[orb] = os.clock() + BENCH
		return nil
	end

	cur.orb, cur.started, cur.last, cur.ended = orb, nil, nil, nil
	step("dir", "catch " .. rarity .. " / start")
	fireproximityprompt(pr)
	local t = os.clock()
	while not cur.started and os.clock() - t < START_WAIT do
		task.wait()
	end
	if not cur.started and orb.Parent then
		first("start-fallback", rarity) -- fireproximityprompt started every probe; the real hold is the spare
		pr:InputHoldBegin()
		task.wait(pr.HoldDuration + 0.15)
		pr:InputHoldEnd()
		t = os.clock()
		while not cur.started and os.clock() - t < START_WAIT do
			task.wait()
		end
	end
	if not cur.started then
		benched[orb] = os.clock() + BENCH
		cur.orb = nil
		first("start-refused", rarity, orb:GetFullName())
		return false
	end

	say("catch: " .. rarity)
	step("dir", "catch " .. rarity .. " / hold")
	CS.Progress:FireServer(orb, true, now(), "kb")
	local answered, t0 = {}, os.clock()
	while not cur.ended and running and os.clock() - t0 < CATCH_TIMEOUT do
		local y = cur.last and cur.last.y
		if type(y) == "table" and y.i and not answered[y.i] and y.b and y.e then
			answered[y.i] = true
			step("dir", "catch " .. rarity .. " / yank " .. y.i)
			CS.Progress:FireServer(orb, false, now(), "kb")
			local at = y.b + (y.e - y.b) * YANK_AT
			while now() < at and running do
				task.wait()
			end
			CS.Progress:FireServer(orb, true, now(), "kb")
		end
		task.wait()
	end
	local ended = cur.ended
	cur.orb = nil
	if not ended then
		CS.Progress:FireServer(orb, false, now(), "kb")
		benched[orb] = os.clock() + BENCH
		stats.missed += 1
		log("catch timed out", rarity, ("%.1fs"):format(os.clock() - t0))
		return false
	end
	if ended.ok then
		stats.caught += 1
		first("catch", rarity, ("%.1fs"):format(os.clock() - t0))
		return true
	end
	benched[orb] = os.clock() + BENCH
	stats.missed += 1
	log("catch lost", rarity, ("%.1fs"):format(os.clock() - t0), "progress", cur.last and cur.last.p)
	return false
end

-- hatch ----------------------------------------------------------------------
local hatchAsked = setmetatable({}, { __mode = "k" })
local lastEquip, lastGhosts = 0, 0
local function hatchPass()
	for _, o in ipairs(mine("PlacedOrbs")) do
		if o:GetAttribute("HatchState") == "READY" and (hatchAsked[o] or 0) + HATCH_RETRY <= os.clock() then
			step("hatch", "hatch " .. tostring(o:GetAttribute("Rarity")))
			hatchAsked[o] = os.clock()
			HatchSystem.RequestHatch:FireServer(o)
			stats.hatched += 1
			local hrp, plot = root(), myPlot()
			first("hatch", o:GetAttribute("Rarity"), "from", hrp and plot and math.floor((hrp.Position - plot.Position).Magnitude) or "?", "studs")
			task.wait(0.15)
		end
	end
	-- the ghost reaches the bag after the reveal (~5s); EquipBest then puts the best ones on the plot
	-- only when a ghost arrived: the weak ones EquipBest leaves in the bag would otherwise re-ask forever
	local ghosts = bagGhosts()
	if ghosts > lastGhosts and os.clock() - lastEquip >= EQUIP_GAP then
		step("hatch", "EquipBest")
		lastEquip = os.clock()
		HatchSystem.EquipBest:FireServer()
		task.wait(1.5)
		lastGhosts = bagGhosts()
	elseif ghosts < lastGhosts then
		lastGhosts = ghosts
	end
end

-- place ----------------------------------------------------------------------
local placeMode = false
local placeMsg = nil
table.insert(
	conns,
	PlotSystem.EnterPlacementMode.OnClientEvent:Connect(function()
		placeMode = true
	end)
)
table.insert(
	conns,
	PlotSystem.PlacementMessage.OnClientEvent:Connect(function(m)
		placeMsg = tostring(m)
	end)
)

local badSpot = {}
local plotFullUntil = 0

-- Orbs have their own cap, the game's HatchConfig.GetPlotSlots(BuiltLevel) (6 at level 2): placing went on
-- with 6 ghosts on the plot and stopped at 6 orbs. Three refusals in a row still close the plot for a while.
local function orbRoom(plot)
	return HatchConfig.GetPlotSlots(plot:GetAttribute("BuiltLevel") or 1) - #mine("PlacedOrbs")
end

local function spotKey(p)
	return math.floor(p.X + 0.5) .. "," .. math.floor(p.Z + 0.5)
end

local function freeSpot(plot, taken)
	local hx, hz = plot.Size.X / 2 - PLACE_MARGIN, plot.Size.Z / 2 - PLACE_MARGIN
	for x = -hx, hx, PLACE_STEP do
		for z = -hz, hz, PLACE_STEP do
			local p = plot.CFrame:PointToWorldSpace(Vector3.new(x, plot.Size.Y / 2, z))
			if (badSpot[spotKey(p)] or 0) < os.clock() then
				local free = true
				for _, q in ipairs(taken) do
					if (Vector3.new(q.X, 0, q.Z) - Vector3.new(p.X, 0, p.Z)).Magnitude < PLACE_CLEAR then
						free = false
						break
					end
				end
				if free then
					return p
				end
			end
		end
	end
	return nil
end

local function placeAll(orbs)
	local plot = myPlot()
	if not plot then
		say("place: no plot of yours found")
		return
	end
	step("dir", "place / glide home")
	say(("place: %d orbs"):format(#orbs))
	if not goHome(plot.Position, 3) then
		return
	end
	local _, hum = root()
	local taken = {}
	for _, folder in ipairs({ "PlacedOrbs", "PlacedGhosts" }) do
		for _, m in ipairs(mine(folder)) do
			taken[#taken + 1] = m:GetPivot().Position
		end
	end
	local refused = 0
	for _, tool in ipairs(orbs) do
		if not running or not want.place or not hum then
			break
		end
		if orbRoom(plot) <= 0 then
			say("place: plot holds its " .. HatchConfig.GetPlotSlots(plot:GetAttribute("BuiltLevel") or 1) .. " orbs")
			break
		end
		local spot = freeSpot(plot, taken)
		if not spot then
			plotFullUntil = os.clock() + PLOT_FULL_WAIT
			say("place: no free spot on the plot")
			break
		end
		step("dir", "place " .. tool.Name .. " / equip")
		placeMode, placeMsg = false, nil
		pcall(hum.EquipTool, hum, tool)
		local t = os.clock()
		while not placeMode and os.clock() - t < 2 do
			task.wait()
		end
		if not placeMode then
			first("place-no-mode", tool.Name)
		end
		step("dir", "place " .. tool.Name .. " / confirm")
		PlotSystem.ConfirmPlacement:FireServer(spot)
		t = os.clock()
		while tool.Parent and (tool.Parent == player.Character or tool.Parent:IsA("Backpack")) and os.clock() - t < PLACE_WAIT do
			task.wait()
		end
		if tool.Parent == nil or not (tool.Parent == player.Character or tool.Parent:IsA("Backpack")) then
			stats.placed += 1
			refused = 0
			taken[#taken + 1] = spot
			first("place", tool.Name)
		else
			badSpot[spotKey(spot)] = os.clock() + 60
			refused += 1
			log("place refused", tool.Name, spotKey(spot), placeMsg or "(no message)")
			if refused >= 3 then
				plotFullUntil = os.clock() + PLOT_FULL_WAIT
				say("place: plot refuses, waiting for hatches")
				break
			end
		end
	end
	pcall(hum.UnequipTools, hum)
	if want.hatch then
		hatchPass() -- we are standing on the plot anyway
	end
end

-- upgrades -------------------------------------------------------------------
local backoff = {}
local function backedOff(key)
	return (backoff[key] or 0) > os.clock()
end

local function penSign(plot)
	for _, m in ipairs(workspace:GetChildren()) do
		if m:IsA("Model") and m:GetAttribute("PlotName") == plot.Name and m:FindFirstChild("PlotUpgradePrompt", true) then
			return m
		end
	end
	return nil
end

local function penPrice(plot)
	local sign = plot and penSign(plot)
	local btn = sign and sign:FindFirstChild("PriceButton", true)
	return btn and btn:GetAttribute("Price"), sign
end

local function station(plot)
	local ts = workspace:FindFirstChild("TrainingStations")
	return ts and plot and ts:FindFirstChild(plot.Name)
end

local function trainPrice()
	local nxt = TrainingConfig.GetNextLevelData(player:GetAttribute("VacuumLevel") or 1)
	return nxt and nxt.Cost
end

local feedback = nil
table.insert(
	conns,
	PlotUpgrade.Feedback.OnClientEvent:Connect(function(m)
		feedback = tostring(m)
	end)
)

-- glide to 5 studs in front of the prompt (our side of it), fire it, wait for `done()`
local function buyAt(key, prompt, done)
	local hrp = root()
	local at = prompt.Parent:IsA("Attachment") and prompt.Parent.WorldPosition or prompt.Parent.Position
	local away = Vector3.new(hrp.Position.X - at.X, 0, hrp.Position.Z - at.Z)
	local aim = at + (away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)) * 5
	step("dir", key .. " / glide")
	if not goHome(aim, 2) then
		return false
	end
	step("dir", key .. " / prompt")
	fireproximityprompt(prompt)
	local t = os.clock()
	while os.clock() - t < 3 do
		if done() then
			return true
		end
		task.wait(0.1)
	end
	backoff[key] = os.clock() + UPGRADE_BACKOFF
	return false
end

local function buyPen(plot, sign)
	local before = plot:GetAttribute("BuiltLevel")
	local coins = stat("Coins")
	feedback = nil
	say("pen: upgrading")
	local okBuy = buyAt("pen", sign:FindFirstChild("PlotUpgradePrompt", true), function()
		return (feedback and feedback:find("UPGRADED")) or plot:GetAttribute("BuiltLevel") ~= before or stat("Coins") < coins - 1000
	end)
	if okBuy then
		stats.pens += 1
		first("pen", before, feedback)
	else
		log("pen refused", feedback or "(no reply)", "coins", fmt(coins))
	end
end

local function buyTraining(plot)
	local st = station(plot)
	local prompt = st and st:FindFirstChild("TrainingUpgradePrompt", true)
	if not prompt then
		say("training: upgrade sign not found")
		backoff.trainUp = os.clock() + UPGRADE_BACKOFF
		return
	end
	local before = player:GetAttribute("VacuumLevel")
	say("training: upgrading")
	if buyAt("trainUp", prompt, function()
		return player:GetAttribute("VacuumLevel") ~= before
	end) then
		stats.trainUps += 1
		first("trainUp", before, "->", player:GetAttribute("VacuumLevel"))
	else
		log("training upgrade refused, level", before, "coins", fmt(stat("Coins")))
	end
end

-- train ----------------------------------------------------------------------
local function train(plot)
	if player:GetAttribute("TrainingLock") then
		say("training")
		return
	end
	local st = station(plot)
	local pad = st and st:FindFirstChild("stand area", true)
	if not pad then
		say("train: stand area not found")
		return
	end
	step("dir", "train / glide")
	if not goHome(pad.Position, 1) then
		return
	end
	local hrp = root()
	if hrp then
		hrp.CFrame = CFrame.new(pad.Position.X, hrp.Position.Y, pad.Position.Z) * hrp.CFrame.Rotation
	end
	local t = os.clock()
	while not player:GetAttribute("TrainingLock") and os.clock() - t < 2 do
		task.wait(0.1)
	end
	if player:GetAttribute("TrainingLock") then
		first("train", player:GetAttribute("VacuumPower"))
		say("training")
	else
		first("train-refused", pad:GetFullName())
		say("train: the pad did not start training")
	end
end

-- director -------------------------------------------------------------------
-- One thread owns the character: upgrades, then a place trip, then a catch, then the training pad.
local function tick()
	local hrp = root()
	if not hrp then
		say("waiting for the character")
		task.wait(1)
		return
	end
	local plot = myPlot()
	local coins = stat("Coins")

	if want.pen and plot and not backedOff("pen") then
		local price, sign = penPrice(plot)
		if price and sign and price <= coins then
			leaveTraining()
			buyPen(plot, sign)
			return
		end
	end
	if want.trainUp and plot and not backedOff("trainUp") then
		local price = trainPrice()
		if price and price <= coins then
			leaveTraining()
			buyTraining(plot)
			return
		end
	end

	local orbs = bagOrbs()
	local target = want.catch and #orbs < BAG and pickOrb() or nil
	local better = want.catch and #orbs < BAG and zoneToVisit(target and WORLD_N[target:GetAttribute("WorldId")] or 0)
	local room = plot and orbRoom(plot) or 0
	if want.place and #orbs > 0 and room > 0 and os.clock() >= plotFullUntil and (#orbs >= math.min(PLACE_BATCH, room) or #orbs >= BAG or not (target or better)) then
		leaveTraining()
		placeAll(orbs)
		return
	end
	if better then
		leaveTraining()
		visit(better)
		return
	end
	if target then
		leaveTraining()
		catch(target)
		return
	end
	if want.train and plot then
		train(plot)
		return
	end
	if want.catch and #orbs >= BAG then
		say("catch: bag full (" .. #orbs .. ")")
	elseif want.catch then
		say("catch: no orb your Power can catch in the ticked zones")
	else
		say("idle")
	end
end

task.spawn(function()
	while running do
		step("dir", "tick")
		local okTick, err = pcall(tick)
		if not okTick then
			warn("[ghost] director threw:", err)
			task.wait(1)
		end
		task.wait(TICK)
	end
end)

task.spawn(function()
	while running do
		if want.hatch then
			step("hatch", "pass")
			local okH, err = pcall(hatchPass)
			if not okH then
				warn("[ghost] hatch threw:", err)
			end
		else
			marks.hatch = nil
		end
		task.wait(HATCH_EVERY)
	end
end)

-- watchdog -------------------------------------------------------------------
task.spawn(function()
	while running do
		task.wait(5)
		for name, m in pairs(marks) do
			if os.clock() - m[2] > WATCHDOG then
				warn(("[ghost] %s stuck %ds at: %s"):format(name, os.clock() - m[2], m[1]))
				m[2] = os.clock()
			end
		end
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Ghost Catcher", statusBar = true })
if not Window then
	running = false
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "ghost")
local Catching = Tab:AddLeftGroupbox("Ghosts", "ghost")
local Grow = Tab:AddRightGroupbox("Grow", "trending-up")

local function toggle(box, idx, text, tip, key)
	return box:AddToggle(idx, {
		Text = text,
		Tooltip = tip,
		Default = false,
		Callback = function(state)
			want[key] = state
			if key == "train" and not state then
				pcall(leaveTraining)
			end
		end,
	})
end

toggle(Catching, "Catch", "Auto Catch", "Glides to the rarest orb of your world and catches it by remote: hold, and every yank hit in its window. ~5-9s an orb, the server's own fill time", "catch")
local zoneValues, zoneByLabel = {}, {}
for _, w in ipairs(ORDER) do
	local label = zoneLabel(w)
	zoneValues[#zoneValues + 1] = label
	zoneByLabel[label] = w
end
-- a Multi dropdown hands over a map ({ label = true }); some builds a list. Read both.
local function ticked(v)
	local out = {}
	for k, val in pairs(v or {}) do
		if type(k) == "number" then
			out[val] = true
		elseif val then
			out[k] = true
		end
	end
	return out
end
assert(ticked({ "a" }).a and ticked({ a = true }).a and not ticked({ a = false }).a, "ticked")
Catching:AddDropdown("Zones", {
	Text = "Zones",
	Tooltip = "Where Auto Catch hunts. The highest ticked zone with orbs left goes first; orbs your Power cannot catch at full speed are skipped (World 2 wants 500, World 3 8K, World 4 40K)",
	Values = zoneValues,
	Default = { zoneValues[1] },
	Multi = true,
	Callback = function(picked)
		table.clear(zoneOn)
		for label in pairs(ticked(picked)) do
			if zoneByLabel[label] then
				zoneOn[zoneByLabel[label]] = true
			end
		end
	end,
})
toggle(Catching, "Place", "Auto Place Orbs", "Takes the orbs home and places them on free spots of your plot (rarest first) once the bag holds a few", "place")
toggle(Catching, "Hatch", "Auto Hatch", "Hatches every orb of yours the moment it is ready, then Equip Best puts the ghosts on the plot", "hatch")

toggle(Grow, "Train", "Auto Train", "Stands you on your training pad whenever catching and placing don't need you", "train")
toggle(Grow, "TrainUp", "Auto Upgrade Training", "Buys the next training level at the sign as soon as the Coins are there (never the Robux one)", "trainUp")
toggle(Grow, "Pen", "Auto Upgrade Pen", "Buys the next plot level at the sign as soon as the Coins are there; goes before training", "pen")

table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		local vu = game:GetService("VirtualUser")
		vu:CaptureController()
		vu:ClickButton2(Vector2.new())
	end)
end))

local nextStrip = 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	local t = os.clock()
	if t < nextStrip then
		return
	end
	nextStrip = t + 0.5
	pcall(Window.SetStatus, Window, {
		{ "Coins", fmt(stat("Coins")) },
		{ "Power", fmt(stat("Power")) },
		{ "Bag", #bagOrbs() .. "/" .. BAG },
		{ "Plot", #mine("PlacedOrbs") .. "+" .. #mine("PlacedGhosts") },
		{ "Zone", tostring(player:GetAttribute("CurrentWorld")) },
		{ "Caught", stats.caught },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("GhostCatcher", {})

-- close ----------------------------------------------------------------------
local function stopAll()
	running = false
	for k in pairs(want) do
		want[k] = false
	end
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
	if cur.orb then
		pcall(function()
			CS.Progress:FireServer(cur.orb, false, now(), "kb")
		end)
	end
	pcall(leaveTraining)
	if inBus() then
		task.spawn(pcall, setBus, false)
	end
end

Library:OnUnload(function()
	stopAll()
	getgenv().ghostCatcherStop = nil
end)

getgenv().ghostCatcherStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().ghostCatcherStop = nil
end
