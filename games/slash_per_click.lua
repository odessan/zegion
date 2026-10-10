--[[ Slash per Click -- sit on the best AFK pad, Auto Win for Wins, buy fists and auras, rebirth (101558013317432)

     FARM     : one director, one thing at a time. PAD = stand on the best AFK pad your rebirths unlock (probed: Train1
                180 Power/s and a Level range in 20s, Train2 216/s, so 20-50x what punching walls pays). WIN = flip the
                game's own server-side Auto Win (walks the wall course, breaks the walls, steps on the win pads: the
                only source of Wins). Mode "Auto" alternates the two on a clock; "Pad" / "Win" stay put.
     PUNCH    : while Auto Win runs, also fires PunchRequest at its target every 0.4s (the server lands about one in
                0.4s; the game's own animation fires every 0.5s). A small gain, only in WIN.
     REBIRTH  : the moment the game's own level check passes, RebirthRequest "Max". Resets Power and Level only (probed:
                Wins, fists, auras and the equipped fist are kept). The next pad row unlocks by itself.
     FISTS    : walks to the best fist pad you can afford (higher than the equipped one) and presses its prompt.
                Wins are the price; a fist is auto-equipped.
     AURAS    : AuraWins for the cheapest unowned aura once it costs no more than the next fist.
     PETS     : EquipBest and AutoMerge on a timer.
     BLADE    : unproven. When the Admin Blade shrine's prompt turns on, or a sword drop lands, walks to it and claims.
                Probed: the shrine event was already over (prompt disabled, Remaining 0).

     Everything moves by walking: the server kicks for a teleport or a speed change ("Exploit activity detected:
     Unauthorized teleport or speed", error 267: a 300-stud hop did it). No teleports, no walk-speed edits.

     Not wired (Robux): SkipRebirth, PowerBundle, AuraRobux, the charm shop's BuyRobux / RefreshRobux, the offline
     reward's Double, the VIP fist. Not built: world teleports (a world unlocks by clearing the one before it) and the
     charm shop (Buy answered nothing from a script: probe it with a hand click first).

     RightControl opens / closes the panel. Stop: getgenv().slashPerClickStop() ]]

-- config ---------------------------------------------------------------------
local PAD_SECS = 120 -- Auto mode: seconds on the pad before a Win phase. Raise for more Power, lower for more Wins
local WIN_SECS = 45 -- Auto mode: seconds of Auto Win per phase. A phase also ends early only if the pad is refused
local PUNCH_GAP = 0.4 -- between extra punches. The server landed 12 of 12 at 0.4s and 8 of 12 at 0.35s; raise if Power stalls
local ARRIVE = 4 -- studs from a pad (horizontal) that count as arrived. The prompts reach 6-7
local WALK_TIMEOUT = 45 -- one walk gives up after this long and the director tries again
local STUCK_STEPS = 3 -- path legs with no progress before a walk gives up
local PRESS_TRIES = 3 -- prompt presses per pad before it is parked
local CONFIRM = 3 -- seconds a pad press has to show in the world (AFKPad / OwnedFists)
local PARK = 60 -- a pad or drop that refused is left alone this long
local SPEND_EVERY = 2 -- aura check beat
local REBIRTH_EVERY = 3
local PETS_EVERY = 90
local STUCK_AFTER = 40 -- the watchdog names the step the director has sat in this long

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local VirtualUser = game:GetService("VirtualUser")
local player = Players.LocalPlayer

if getgenv and getgenv().slashPerClickStop then
	getgenv().slashPerClickStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[slash]", ...)
end

local seen = {}
local function first(name, ...) -- one console line per unproven branch
	if not seen[name] then
		seen[name] = true
		log(name, ...)
	end
end

-- The panel strip is drained from a Heartbeat, which the engine calls with our own identity.
-- A loop thread that writes to the window directly throws "lacking capability Plugin" after its first task.wait.
local pending, lastSaid = {}, nil
local function say(msg)
	pending.now = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- breadcrumb: the watchdog thread (separate, so a parked director can still be reported)
local mark, markAt = "idle", os.clock()
local function step(s)
	mark, markAt = s, os.clock()
end

-- game -----------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("PunchEscapeRemotes", 15)
local okc, Config = pcall(function()
	return require(ReplicatedStorage:WaitForChild("PunchEscapeConfig", 15))
end)
if not Remotes or not okc or type(Config) ~= "table" or not Config.Training or not Config.Worlds then
	warn("[slash] the game's modules did not load:", Config)
	return
end
local R = {}
for _, name in ipairs({ "AutoWinRequest", "PunchRequest", "AFKExitRequest", "RebirthRequest", "PurchaseRequest" }) do
	R[name] = Remotes:WaitForChild(name, 10)
end
local PetAction = ReplicatedStorage:FindFirstChild("PetInventoryAction")
local Stats = player:WaitForChild("PlayerStats")
local Numeric = player:WaitForChild("NumericStats")
local OwnedFists = player:WaitForChild("OwnedFists")
local OwnedAuras = player:WaitForChild("OwnedAuras")
local power, wins, rebirths = Numeric:WaitForChild("Power"), Numeric:WaitForChild("Wins"), Numeric:WaitForChild("Rebirths")
local level, afkPad, equippedFist = Stats:WaitForChild("Level"), Stats:WaitForChild("AFKPad"), Stats:WaitForChild("EquippedFist")

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function fmt(n)
	local i = 1
	while n >= 1000 and i < #SUFFIX do
		n /= 1000
		i += 1
	end
	return ("%.3g"):format(n) .. SUFFIX[i]
end
assert(fmt(25000) == "25K" and fmt(1500) == "1.5K" and fmt(260e9) == "260B" and fmt(100) == "100", "fmt")

local function currentWorld()
	return player:GetAttribute("CurrentWorld") or 1
end

-- The best AFK pad your rebirths unlock in the world you stand in. Rows with a GamePassId are the paid dummies; skipped.
local function worldOfRow(row)
	for w, wd in ipairs(Config.Worlds) do
		if row >= wd.FirstTraining and row <= wd.LastTraining then
			return w
		end
	end
	return nil
end
local function bestPad(reb, world)
	local row, mult
	for r, t in ipairs(Config.Training) do
		if not t.GamePassId and (t.Rebirths or 0) <= reb and worldOfRow(r) == world and (not mult or t.Multiplier > mult) then
			row, mult = r, t.Multiplier
		end
	end
	return row, mult
end
do -- Train1..Train9 are World 1's rows; the probe showed Training[2] at x1.5 needing 1 rebirth
	assert(worldOfRow(1) == 1 and worldOfRow(10) == 2, "worldOfRow")
	local r, m = bestPad(0, 1)
	assert(r == 1 and m == 1.25, "bestPad 0")
	r, m = bestPad(1, 1)
	assert(r == 2 and m == 1.5, "bestPad 1")
	r, m = bestPad(100, 1)
	assert(r == 7 and m == 15, "bestPad 100 skips the gamepass rows")
end

local function padModel(row, world)
	local w = workspace:FindFirstChild("Worlds")
	w = w and w:FindFirstChild("World " .. world)
	w = w and w:FindFirstChild("Train")
	return w and (w:FindFirstChild("Train" .. row) or w:FindFirstChild("Train" .. ((row - 1) % 9 + 1)))
end

-- walking --------------------------------------------------------------------
local function character()
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	local root = ch and ch:FindFirstChild("HumanoidRootPart")
	if hum and root and hum.Health > 0 then
		return hum, root
	end
	return nil, nil
end

local function moveTo(hum, p, timeout)
	local done = false
	local c = hum.MoveToFinished:Connect(function()
		done = true
	end)
	hum:MoveTo(p)
	local t = os.clock()
	while not done and os.clock() - t < timeout do
		task.wait(0.05)
	end
	c:Disconnect()
	return done
end

local function near(root, pos)
	local d = root.Position - pos
	return Vector3.new(d.X, 0, d.Z).Magnitude <= ARRIVE and math.abs(d.Y) < 5 -- a prompt reaches 6 in 3D: standing under a terrace is not arrived
end

-- true when arrived. A teleport is a kick here, so every leg is a walk; the path planner routes round scenery
-- (a straight MoveTo stuck against a decoration at x -87 in the probe).
local function walkTo(pos, alive)
	local t0, stuckN, prev = os.clock(), 0, nil
	while alive() and os.clock() - t0 < WALK_TIMEOUT do
		local hum, root = character()
		if not hum then
			return false, "no character"
		end
		if near(root, pos) then
			return true
		end
		prev = root.Position
		local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
		local planned = pcall(path.ComputeAsync, path, root.Position, pos)
		if planned and path.Status == Enum.PathStatus.Success then
			for i, wp in ipairs(path:GetWaypoints()) do
				if i > 1 then
					if not alive() or near(root, pos) then
						break
					end
					if wp.Action == Enum.PathWaypointAction.Jump then
						hum:ChangeState(Enum.HumanoidStateType.Jumping) -- probed: hum.Jump = true did not clear the 3-stud terrace step, this does
					end
					if not moveTo(hum, wp.Position, 2.5) then
						break
					end
				end
			end
		else
			moveTo(hum, pos, 3)
		end
		if (root.Position - prev).Magnitude < 1 then
			stuckN += 1
			if stuckN >= STUCK_STEPS then
				return false, "stuck at " .. tostring(root.Position)
			end
		else
			stuckN = 0
		end
	end
	local _, root = character()
	return root ~= nil and near(root, pos), "walk timeout"
end

-- a spot a few studs from a pad on the side we come from, so we never stand inside it
local function standNear(part, onTop)
	local _, root = character()
	local p = part.Position
	if onTop then -- a fist pad is a 4x4 plate on a terrace: the plate itself is the one spot known to be standable
		return Vector3.new(p.X, p.Y + 3, p.Z)
	end
	if not root then
		return p
	end
	local d = Vector3.new(root.Position.X - p.X, 0, root.Position.Z - p.Z)
	d = d.Magnitude > 0.1 and d.Unit or Vector3.new(0, 0, 1)
	return Vector3.new(p.X, p.Y + 3, p.Z) + d * 3 -- the pad's own height: fists 6-15 sit on raised terraces (y 3.8 and 7.5)
end

-- state ----------------------------------------------------------------------
local dead, gen = false, 0
local farmOn, mode = false, "Auto"
local punchOn, rebirthOn, fistsOn, aurasOn, petsOn, bladeOn = false, false, false, false, false, false
local phase, phaseAt = "pad", os.clock()
local conns = {} -- RBXScriptConnections, disconnected on unload
local tokens = {} -- side-loop generation tokens; clearing the table ends the loops
local parked = {} -- [key] = os.clock() it may be tried again
local stats = { rebirths = 0, fists = 0, auras = 0, padFails = 0 }
local weSetWin = false
local onPad = nil -- the pad row we last confirmed standing on; cleared by a deliberate leave

local function isParked(key)
	return (parked[key] or 0) > os.clock()
end

local function winOn()
	return player:GetAttribute("AutoWin") == true
end
local function setWin(on)
	if on then
		weSetWin = true
	end
	pcall(R.AutoWinRequest.FireServer, R.AutoWinRequest, on)
end
local function waitFor(cond, secs)
	local t = os.clock()
	while not cond() and os.clock() - t < secs do
		task.wait(0.1)
	end
	return cond()
end
local function stopWin()
	if winOn() then
		setWin(false)
		waitFor(function()
			return not winOn()
		end, 3)
	end
end
local function leavePad()
	onPad = nil -- a deliberate exit is not a "pad dropped"
	if afkPad.Value > 0 then
		pcall(R.AFKExitRequest.FireServer, R.AFKExitRequest)
		waitFor(function()
			return afkPad.Value == 0
		end, 3)
	end
end

-- errands: fists and the blade --------------------------------------------------
-- The highest fist above the equipped one that Wins can pay for, and the cheapest one still ahead (the aura budget).
local function fistTargets()
	local w = workspace:FindFirstChild("Worlds")
	w = w and w:FindFirstChild("World " .. currentWorld())
	w = w and w:FindFirstChild("Fists")
	local best, nextCost = nil, math.huge
	if not w then
		return nil, nextCost
	end
	local eq, have = equippedFist.Value, wins.Value
	for _, pad in ipairs(w:GetChildren()) do
		local idx, cost = pad:GetAttribute("FistIndex"), pad:GetAttribute("WinCost")
		local owned = idx and OwnedFists:FindFirstChild("Fist" .. idx)
		if idx and cost and idx > eq and owned and not owned.Value and not pad:GetAttribute("GamePassId") then
			nextCost = math.min(nextCost, cost)
			if cost <= have and not isParked("fist" .. idx) and (not best or idx > best:GetAttribute("FistIndex")) then
				best = pad
			end
		end
	end
	return best, nextCost
end

local function errandFist(pad, alive)
	local idx = pad:GetAttribute("FistIndex")
	local prompt = pad:FindFirstChildWhichIsA("ProximityPrompt", true)
	local owned = OwnedFists:FindFirstChild("Fist" .. idx)
	if not (prompt and owned) then
		parked["fist" .. idx] = os.clock() + PARK
		return
	end
	step("fist " .. idx .. " / leave")
	stopWin()
	leavePad()
	step("fist " .. idx .. " / walk")
	say(("walking to Fist %d (%s Wins)"):format(idx, fmt(pad:GetAttribute("WinCost"))))
	local ok, why = walkTo(standNear(prompt.Parent, true), alive)
	if not ok then
		first("fist walk failed", idx, why)
		parked["fist" .. idx] = os.clock() + PARK
		return
	end
	for _ = 1, PRESS_TRIES do
		step("fist " .. idx .. " / press")
		pcall(fireproximityprompt, prompt)
		if waitFor(function()
			return owned.Value
		end, CONFIRM) then
			stats.fists += 1
			say(("bought Fist %d, Wins left %s"):format(idx, fmt(wins.Value)))
			return
		end
	end
	log("fist", idx, "not bought after", PRESS_TRIES, "presses, wins", wins.Value, "cost", pad:GetAttribute("WinCost"))
	parked["fist" .. idx] = os.clock() + PARK
end

-- Unproven: the shrine prompt (hold 1.5, range 12) and the falling sword drop are the only two ways this reaches us.
local function bladeTarget()
	local shrine = workspace:FindFirstChild("AdminBladeShrine")
	local prompt = shrine and shrine:FindFirstChild("ClaimAdminBlade", true)
	if prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled and not isParked("shrine") then
		return "shrine", prompt, prompt.Parent
	end
	local drop = workspace:FindFirstChild("ActiveSwordDrop")
	local anchor = drop and drop:FindFirstChild("SwordDropAnchor", true)
	if anchor and not isParked("drop") then
		return "drop", nil, anchor
	end
	return nil, nil, nil
end

local function errandBlade(kind, prompt, part, alive)
	step("blade " .. kind .. " / walk")
	stopWin()
	leavePad()
	say("going for the " .. kind)
	local ok, why = walkTo(kind == "drop" and part.Position or standNear(part), alive)
	parked[kind] = os.clock() + PARK -- unproven either way: one try per window
	if not ok then
		first("blade walk failed", kind, why)
		return
	end
	if prompt then
		step("blade shrine / press")
		for _ = 1, PRESS_TRIES do
			pcall(fireproximityprompt, prompt)
			task.wait(1)
		end
	else
		task.wait(3)
	end
	first("blade " .. kind .. " tried", "pos", part.Position)
end

-- phases ---------------------------------------------------------------------
local padRow, padMult = nil, nil
local function ensurePad(alive)
	local row, mult = bestPad(rebirths.Value, currentWorld())
	padRow, padMult = row, mult
	if not row then
		return false, "no pad row for this world"
	end
	if afkPad.Value == row then
		onPad = row
		return true
	end
	-- UNVERIFIED: one run saw AFKPad drop off a pad it had just taken and come back by itself. A moment's recheck is
	-- cheaper than a walk, and the log line names the state if it happens again.
	task.wait(1.5)
	if afkPad.Value == row then
		return true
	end
	if onPad == row then -- the same row we held: not a rebirth unlocking a better one
		first("pad dropped", "row", row, "now", afkPad.Value, "reb", rebirths.Value, "lvl", level.Value, "autowin", winOn())
	end
	onPad = nil
	step("pad / stop win")
	stopWin()
	if afkPad.Value > 0 then -- a better row unlocked (a rebirth), or the wrong one
		leavePad()
	end
	local model = padModel(row, currentWorld())
	local prompt = model and model:FindFirstChildWhichIsA("ProximityPrompt", true)
	if not prompt then
		return false, "no prompt for Train" .. row
	end
	step("pad Train" .. row .. " / walk")
	say(("walking to Train%d (x%s)"):format(row, tostring(mult)))
	local ok, why = walkTo(standNear(prompt.Parent), alive)
	if not ok then
		return false, why
	end
	for _ = 1, PRESS_TRIES do
		step("pad Train" .. row .. " / press")
		pcall(fireproximityprompt, prompt)
		if waitFor(function()
			return afkPad.Value == row
		end, CONFIRM) then
			onPad = row
			say(("on Train%d (x%s)"):format(row, tostring(mult)))
			return true
		end
	end
	return false, "Train" .. row .. " refused " .. PRESS_TRIES .. " presses at " .. rebirths.Value .. " rebirths"
end

local function ensureWin(alive)
	if afkPad.Value > 0 then
		step("win / leave pad")
		leavePad()
	end
	if not winOn() then
		step("win / start")
		setWin(true)
		waitFor(winOn, 3)
		say("Auto Win on")
	end
end

local function director(mine)
	local function alive()
		return farmOn and gen == mine and not dead
	end
	local padFails = 0
	phase, phaseAt = mode == "Win" and "win" or "pad", os.clock()
	while alive() do
		local ok, err = pcall(function()
			if fistsOn then
				local pad = fistTargets()
				if pad then
					errandFist(pad, alive)
				end
			end
			if bladeOn then
				local kind, prompt, part = bladeTarget()
				if kind then
					errandBlade(kind, prompt, part, alive)
				end
			end
			if not alive() then
				return
			end
			local now = os.clock()
			if mode == "Pad" then
				phase = "pad"
			elseif mode == "Win" then
				phase = "win"
			elseif phase == "pad" and now - phaseAt >= PAD_SECS then
				phase, phaseAt = "win", now
				say("Auto: Win phase")
			elseif phase == "win" and now - phaseAt >= WIN_SECS then
				phase, phaseAt = "pad", now
				say("Auto: Pad phase")
			end
			if phase == "pad" then
				local ok2, why = ensurePad(alive)
				if ok2 then
					padFails = 0
				else
					padFails += 1
					stats.padFails += 1
					log("pad failed", padFails, why)
					if padFails >= 3 then
						say("pad refused 3 times, Auto Win for this window: " .. tostring(why))
						padFails = 0
						phase, phaseAt = "win", os.clock()
					end
				end
			else
				ensureWin(alive)
			end
		end)
		if not ok then
			first("director error " .. tostring(err), err)
			task.wait(2)
		end
		step("director / idle")
		task.wait(0.5)
	end
end

local function setFarm(on)
	farmOn = on
	gen += 1
	if on then
		local mine = gen
		task.spawn(director, mine)
	else
		task.spawn(function()
			if weSetWin then
				stopWin()
			end
		end)
	end
end

-- side loops (remote only, never move you) ---------------------------------------
local function loopFlag(name, flagGet, every, body)
	return function(on)
		if on then
			local token = {} -- a re-toggle inside one beat must not leave the old thread running
			tokens[name] = token
			task.spawn(function()
				while flagGet() and not dead and tokens[name] == token do
					local ok, err = pcall(body)
					if not ok then
						first(name .. " error " .. tostring(err), err)
					end
					task.wait(every)
				end
			end)
		else
			tokens[name] = nil
		end
	end
end

local function rebirthBody()
	local n = Config.GetAffordableRebirths(rebirths.Value, level.Value)
	if n > 0 then
		step("rebirth")
		local before = rebirths.Value
		pcall(R.RebirthRequest.FireServer, R.RebirthRequest, "Max")
		if waitFor(function()
			return rebirths.Value > before
		end, 4) then
			stats.rebirths += rebirths.Value - before
			say(("rebirthed to %d"):format(rebirths.Value))
		else
			first("rebirth refused", "level", level.Value, "reb", rebirths.Value, "affordable", n)
		end
	end
end

local function auraBody()
	local _, nextFist = fistTargets()
	for idx, a in ipairs(Config.Auras) do
		local own = OwnedAuras:FindFirstChild("Aura" .. idx)
		if own and not own.Value then
			if a.Cost <= wins.Value and a.Cost <= nextFist and not isParked("aura" .. idx) then
				step("aura " .. idx)
				pcall(R.PurchaseRequest.FireServer, R.PurchaseRequest, "AuraWins", idx) -- never AuraRobux
				if waitFor(function()
					return own.Value
				end, 2) then
					stats.auras += 1
					say(("bought aura %d (%s)"):format(idx, a.Name))
				else
					parked["aura" .. idx] = os.clock() + PARK
					first("aura refused", idx, a.Name, "wins", wins.Value, "cost", a.Cost)
				end
			end
			return -- the cheapest unowned one gates the rest
		end
	end
end

local function petsBody()
	if PetAction then
		step("pets")
		pcall(PetAction.FireServer, PetAction, "EquipBest")
		task.wait(1)
		pcall(PetAction.FireServer, PetAction, "AutoMerge")
	end
end

local setRebirth = loopFlag("rebirth", function()
	return rebirthOn
end, REBIRTH_EVERY, rebirthBody)
local setAuras = loopFlag("auras", function()
	return aurasOn
end, SPEND_EVERY, auraBody)
local setPets = loopFlag("pets", function()
	return petsOn
end, PETS_EVERY, petsBody)
-- extra punches while Auto Win runs, at the target the game's own client aims at
local setPunch = loopFlag("punch", function()
	return punchOn
end, PUNCH_GAP, function()
	local tg = player:GetAttribute("AutoWinTarget")
	if winOn() and typeof(tg) == "Vector3" then
		pcall(R.PunchRequest.FireServer, R.PunchRequest, tg)
		first("extra punch", tg)
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Slash per Click", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "swords")
local Farm = Tab:AddLeftGroupbox("Farm", "swords")
local Spend = Tab:AddRightGroupbox("Spend and claim", "coins")

Farm:AddToggle("Farm", {
	Text = "Auto Farm",
	Tooltip = "Stands on the best AFK pad your rebirths unlock and/or runs the game's Auto Win, by the mode below. Walks everywhere: a teleport is a kick in this game",
	Default = false,
	Callback = function(state)
		pcall(setFarm, state)
		if not state then
			say("farm off")
		end
	end,
})
Farm:AddDropdown("Mode", {
	Text = "Mode",
	Tooltip = "Pad: AFK pad only (Power). Win: Auto Win only (Wins, for fists). Auto: Pad for 2 minutes, then Auto Win for 45s, and round again",
	Values = { "Auto", "Pad", "Win" },
	Default = "Auto",
	Multi = false,
	Callback = function(value)
		if value then
			mode = value
			phaseAt = os.clock()
		end
	end,
})
Farm:AddToggle("Punch", {
	Text = "Extra punches in Auto Win",
	Tooltip = "Fires a punch at Auto Win's target every 0.4s on top of the game's own 0.5s one. Small gain, only while Auto Win runs",
	Default = false,
	Callback = function(state)
		pcall(setPunch, state)
	end,
})
local farmLine = Farm:AddLabel("-", true)

Spend:AddToggle("Rebirth", {
	Text = "Auto Rebirth",
	Tooltip = "Rebirths as soon as the game's level check passes. Resets Power and Level only; Wins, fists and auras stay, and the next AFK pad row unlocks. Never the Robux skip",
	Default = false,
	Callback = function(state)
		rebirthOn = state
		pcall(setRebirth, state)
	end,
})
Spend:AddToggle("Fists", {
	Text = "Auto buy best fist",
	Tooltip = "Walks to the best fist pad Wins can pay for (higher than the one you hold) and presses it. Leaves the pad or Auto Win for the trip. Never the VIP fist",
	Default = false,
	Callback = function(state)
		fistsOn = state
	end,
})
Spend:AddToggle("Auras", {
	Text = "Auto buy auras",
	Tooltip = "AuraWins for the cheapest aura you do not own, once it costs no more than the next fist. Never the Robux aura",
	Default = false,
	Callback = function(state)
		aurasOn = state
		pcall(setAuras, state)
	end,
})
Spend:AddToggle("Pets", {
	Text = "Pets: equip best + merge",
	Tooltip = "EquipBest and AutoMerge every 90s. Merge needs three identical pets, so it usually answers nothing to merge",
	Default = false,
	Callback = function(state)
		petsOn = state
		pcall(setPets, state)
	end,
})
Spend:AddToggle("Blade", {
	Text = "Grab Admin Blade / sword drop",
	Tooltip = "Unproven. When the shrine prompt turns on or a sword drop lands, walks to it and claims. The shrine event was over when probed",
	Default = false,
	Callback = function(state)
		bladeOn = state
	end,
})

local note, nextStrip = "idle", 0
local lastP, lastW, lastAt, rateP, rateW = power.Value, wins.Value, os.clock(), 0, 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	if pending.now then
		note, pending.now = pending.now, nil
	end
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	if now - lastAt >= 10 then -- measured rate over the last 10s, for the strip and the console
		rateP, rateW = (power.Value - lastP) / (now - lastAt), (wins.Value - lastW) / (now - lastAt)
		lastP, lastW, lastAt = power.Value, wins.Value, now
		if farmOn then
			log(("rate %s: power %s/s, wins %.1f/s (reb %d, lvl %d, fist %d)"):format(
				phase, fmt(rateP), rateW, rebirths.Value, level.Value, equippedFist.Value
			))
		end
	end
	local nextLevel = Config.GetRebirthLevel(rebirths.Value)
	pcall(farmLine.SetText, farmLine, ("%s phase, pad %s, next rebirth at level %d"):format(
		phase, padRow and ("Train" .. padRow .. " x" .. tostring(padMult)) or "-", nextLevel
	))
	pcall(Window.SetStatus, Window, { -- ponytail: thrown "lacking capability Plugin" when loaded through the bridge; silence, not fix
		{ "Power", fmt(power.Value) },
		{ "Wins", fmt(wins.Value) },
		{ "Rebirths", rebirths.Value },
		{ "Level", level.Value },
		{ "Fist", equippedFist.Value },
		{ "Power/s", fmt(rateP) },
		{ "Wins/s", ("%.1f"):format(rateW) },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("SlashPerClick", {})

table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- watchdog: a parked director cannot report itself
task.spawn(function()
	while not dead do
		task.wait(5)
		if farmOn and os.clock() - markAt > STUCK_AFTER and mark ~= "director / idle" then
			warn(("[slash] stuck %ds at: %s"):format(os.clock() - markAt, mark))
			markAt = os.clock()
		end
	end
end)

-- close ----------------------------------------------------------------------
local function stopAll()
	farmOn, rebirthOn, fistsOn, aurasOn, petsOn, bladeOn, punchOn = false, false, false, false, false, false, false
	gen += 1
	table.clear(tokens) -- the loops compare their own token against this table and end
	dead = true
	-- Auto Win is server state: it outlives the panel, so it is switched off here
	pcall(R.AutoWinRequest.FireServer, R.AutoWinRequest, false)
end

Library:OnUnload(function()
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
	stopAll()
	getgenv().slashPerClickStop = nil
end)

getgenv().slashPerClickStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().slashPerClickStop = nil
end
