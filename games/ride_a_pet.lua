--[[ Ride a Pet -- world-egg farm by name or by luck (124216119978534)

     BY NAME : tick egg types (listed best luck first); the farm takes the best ticked egg
               on the map, teleports to it, picks it up, and teleports back to your plot.
               A picked-up egg rides in player.Basket on a 25-30s BreakAt clock and only
               becomes a Tool once delivered home -- so the trip home IS the collect.
     BY LUCK : same loop, but any egg whose luck is at least the number you type (7M, 1B).
               The two toggles are exclusive -- turning one on turns the other off.

     Eggs come from ReplicatedStorage.ServerData.ActiveEggs, not workspace.RenderedEggs:
     RenderedEggs is the client's own drawing of that folder, named by egg type with no id,
     and the pickup remote wants the id.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().rideAPetStop() ]]

-- config ---------------------------------------------------------------------
-- The pickup prompt is cloned from Assets.Prompts.Pickup with MaxActivationDistance 15, and
-- its Triggered only fires EggPickup(id) -- so the server keeps its own range check and we
-- stand on the egg rather than open a gate.
local LIFT = 4 -- studs above the egg's Position we park at; exactly on it bounces us
local PRESS_GAP = 0.25 -- between re-fires of EggPickup while parked on the egg
local GRAB_WINDOW = 3 -- seconds of re-firing before an egg counts as refused
local CONFIRM_GRACE = 1.5 -- the egg leaving ActiveEggs and the Basket entry landing are two replications
-- The server samples our position every 0.5s (TeleportLastPosition / TeleportLastClock) and
-- answers a big jump with "Teleport detected". One 111-stud jump passed the probe; real
-- play peaks at ~74 studs/s. So travel is a glide: this many studs per second, written
-- every frame. 150 = 75 studs per sample. Lower it if "Teleport detected" comes back;
-- raise it (carefully) if eggs break on the way home -- BreakSeconds is 25.
local GLIDE_SPEED = 150
local PAUSE_WAIT = 2 -- cap on waiting out a GameplayPaused after a hop
local ARRIVE_RADIUS = 25 -- further than this from where we aimed = the server reverted the hop
local DEPOSIT_WAIT = 6 -- seconds at the plot for the Basket to empty. Well under BreakSeconds (25)
local TOUCH_AFTER = 1 -- if the Basket hasn't emptied by now, also touch the plot's Baseplate
-- (it carries a TouchInterest; standing on it may not register a teleported arrival)
local EGG_STRIKES = 2 -- refused windows before an egg is parked
local RETRY_AFTER = 30 -- seconds a parked egg is skipped
local IDLE = 1 -- beat when nothing matches
local WATCHDOG = 25 -- seconds without the breadcrumb moving before we say where we are

local SUFFIX = { k = 1e3, m = 1e6, b = 1e9, t = 1e12, qa = 1e15, qi = 1e18 }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().rideAPetStop then
	getgenv().rideAPetStop() -- re-running must not stack a second panel or a second loop
end

local function log(msg)
	print("[ride] " .. msg)
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
-- Same lookup the game's EggSpawning client does: ServerData if it exists, else the root.
local ActiveEggs = (ReplicatedStorage:FindFirstChild("ServerData") or ReplicatedStorage):WaitForChild("ActiveEggs", 10)
local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
local EggPickup = Remotes and Remotes:FindFirstChild("Game") and Remotes.Game:FindFirstChild("EggPickup")
local EggsMod = ReplicatedStorage:FindFirstChild("GameData") and ReplicatedStorage.GameData:FindFirstChild("Eggs")
local okEggs, EggDefs = pcall(require, EggsMod)
if not (ActiveEggs and EggPickup and okEggs and type(EggDefs) == "table") then
	warn("[ride] ActiveEggs / EggPickup / GameData.Eggs missing -- wrong game, or it updated")
	return
end

local function luckOf(name)
	local def = EggDefs[name]
	return def and tonumber(def.Luck) or 0
end

local function fmt(n)
	for _, s in ipairs({ { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
		if n >= s[1] then
			return (("%.1f"):format(n / s[1]):gsub("%.0$", "")) .. s[2]
		end
	end
	return tostring(n)
end
assert(fmt(7000000) == "7M" and fmt(1500000000) == "1.5B" and fmt(50) == "50")

local function parseLuck(text)
	local num, suffix = tostring(text):gsub("[,%s]", ""):match("^(%d*%.?%d+)(%a*)$")
	local n = tonumber(num)
	local mult = suffix == "" and 1 or SUFFIX[(suffix or ""):lower()]
	return n and mult and n * mult or nil
end
assert(parseLuck("7M") == 7e6 and parseLuck("1.5b") == 1.5e9 and parseLuck("300") == 300)
assert(parseLuck("abc") == nil and parseLuck("5zz") == nil)

-- Dropdown rows: every egg with a Luck, best first. Premium eggs (Dragon, Giant) are store
-- items with no Luck and never spawn in the world, so they'd be a pick that never matches.
local LABELS, NAME_OF = {}, {}
do
	local names = {}
	for name, def in pairs(EggDefs) do
		if type(def) == "table" and tonumber(def.Luck) and not def.Premium then
			table.insert(names, name)
		end
	end
	table.sort(names, function(a, b)
		return luckOf(a) > luckOf(b)
	end)
	for _, name in ipairs(names) do
		local label = ("%s  (%s)"):format(name, fmt(luckOf(name)))
		table.insert(LABELS, label)
		NAME_OF[label] = name
	end
end

local function hrp()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function flags()
	return player:GetAttribute("TeleportFlags") or 0
end

-- The plot the game's own General:GetPlot returns: Data.Owner is an ObjectValue on us.
local function homeCF()
	local plots = workspace:FindFirstChild("Plots")
	for _, plot in ipairs(plots and plots:GetChildren() or {}) do
		local owner = plot:FindFirstChild("Data") and plot.Data:FindFirstChild("Owner")
		local base = plot:FindFirstChild("Baseplate")
		if owner and owner.Value == player and base then
			return base.CFrame * CFrame.new(0, 6, 0), base -- the game's own cheat-TP target
		end
	end
	return nil
end

-- Carried eggs: player.Basket holds one Configuration per egg (Egg, BreakAt, BreakSeconds).
-- The game's own BreakTimer reads the same folder to draw the countdown.
local function carried()
	local basket = player:FindFirstChild("Basket")
	return basket and #basket:GetChildren() or 0
end

-- Mirror of the renderer's skip rules: a PrivateTo egg for someone else isn't drawn for
-- us, and neither is a type already in CollectedEggs ("Blackhole Egg,") -- the server
-- won't hand those over either.
local function visibleToUs(egg, name)
	local private = egg:GetAttribute("PrivateTo")
	if private and private ~= player.UserId then
		return false
	end
	local collected = player:GetAttribute("CollectedEggs")
	return not (type(collected) == "string" and collected:find(name .. ",", 1, true))
end

-- travel ---------------------------------------------------------------------
-- Server-side anti-cheat is real here (TeleportFlags / TeleportLastPosition on the player,
-- sampled every 0.5s), so every hop logs a flag bump instead of assuming hops are free.
local lastFlags = flags()

-- true arrived / false the server reverted us / nil no character to move
-- A straight-line glide at GLIDE_SPEED rather than a jump. CFrame writes ignore collision,
-- so terrain in the way doesn't matter; velocity is zeroed each frame or gravity piles up
-- and flings us on arrival.
local function hop(cf)
	local root = hrp()
	if not root then
		return nil
	end
	local from = root.Position
	local dist = (cf.Position - from).Magnitude
	-- Read once: a slider moved mid-glide would otherwise jump us forward along the line.
	local t0, speed = os.clock(), GLIDE_SPEED
	while true do
		root = hrp()
		if not root then
			return nil
		end
		local a = math.min((os.clock() - t0) * speed / math.max(dist, 1), 1)
		root.CFrame = cf.Rotation + from:Lerp(cf.Position, a)
		root.AssemblyLinearVelocity = Vector3.zero
		if a >= 1 then
			break
		end
		RunService.Heartbeat:Wait()
	end
	local deadline = os.clock() + PAUSE_WAIT
	while player.GameplayPaused and os.clock() < deadline do
		task.wait()
	end
	root = hrp()
	if not root then
		return nil
	end
	local now = flags()
	if now ~= lastFlags then
		log(("TeleportFlags %d -> %d"):format(lastFlags, now))
		lastFlags = now
	end
	return (root.Position - cf.Position).Magnitude <= ARRIVE_RADIUS
end

-- farm -----------------------------------------------------------------------
local mode, gen = nil, 0 -- nil / "name" / "luck"
local wanted = {} -- egg name -> true, from the name dropdown
local minLuck = 1e6
local parked = setmetatable({}, { __mode = "k" }) -- egg -> os.clock() it may be tried again
local strikes = setmetatable({}, { __mode = "k" })

local function matches(name)
	if mode == "name" then
		return wanted[name] == true
	end
	return mode == "luck" and luckOf(name) >= minLuck
end

-- An egg further from home than a glide can carry before BreakSeconds (25) is a wasted trip
-- that ends in EggBroke. 5s of slack for the grab window and the deposit.
local function reachable(pos, home)
	return not home or (pos - home.Position).Magnitude / GLIDE_SPEED < 20
end

local function best()
	local now, root, home = os.clock(), hrp(), homeCF()
	local here = root and root.Position or Vector3.zero
	local pick, pickLuck, pickDist
	for _, egg in ipairs(ActiveEggs:GetChildren()) do
		local name, pos = egg:GetAttribute("Egg"), egg:GetAttribute("Position")
		if name and typeof(pos) == "Vector3" and (parked[egg] or 0) <= now and matches(name) and visibleToUs(egg, name) and reachable(pos, home) then
			local luck, dist = luckOf(name), (pos - here).Magnitude
			if not pick or luck > pickLuck or (luck == pickLuck and dist < pickDist) then
				pick, pickLuck, pickDist = egg, luck, dist
			end
		end
	end
	return pick
end

-- true got it (a Basket entry landed on us) / false still sat there after the window
-- (a refusal) / nil gone but not ours -- despawned or someone else took it; no strike.
-- The probe showed the egg vanishing with no Tool: Basket is where it goes, not Backpack.
local function grab(egg, name, cf)
	local before = carried()
	local deadline = os.clock() + GRAB_WINDOW
	repeat
		if egg.Parent ~= ActiveEggs then
			break
		end
		local root = hrp()
		if not root then
			return nil
		end
		root.CFrame = cf -- rewritten every pass; drifting out of 15 studs is a silent timeout
		pcall(EggPickup.FireServer, EggPickup, egg.Name)
		task.wait(PRESS_GAP)
	until os.clock() > deadline
	local grace = os.clock() + CONFIRM_GRACE
	repeat
		if carried() > before then
			return true
		end
		task.wait()
	until os.clock() > grace
	if egg.Parent == ActiveEggs then
		return false
	end
	log(name .. " left the map but nothing landed in the Basket -- despawned or someone beat us")
	return nil
end

-- Home, then wait for the Basket to empty. true delivered / false still carrying after
-- DEPOSIT_WAIT (logged -- the delivery trigger is the one thing no probe has confirmed) /
-- nil no plot or no character.
local function deposit(what)
	local home, base = homeCF()
	if not home then
		say("can't find your plot")
		return nil
	end
	step("deposit " .. what)
	say("delivering " .. what .. " to plot")
	if hop(home) == nil then
		return nil
	end
	local start, touched = os.clock(), false
	repeat
		if carried() == 0 then
			return true
		end
		local root = hrp()
		if root then
			root.CFrame = home -- stay put; the plot is what the server checks
			if not touched and firetouchinterest and os.clock() - start > TOUCH_AFTER then
				touched = true
				pcall(firetouchinterest, root, base, 0)
				task.wait()
				pcall(firetouchinterest, root, base, 1)
			end
		end
		task.wait(0.1)
	until os.clock() - start > DEPOSIT_WAIT
	log(("still carrying %d egg(s) %ds after reaching the plot -- delivery trigger isn't what we think"):format(carried(), DEPOSIT_WAIT))
	return false
end

local function lap()
	-- A carried egg from a manual pickup or a lap cut short: deliver it before it breaks.
	if carried() > 0 then
		return deposit("carried egg") ~= nil
	end

	step("pick")
	local egg = best()
	if not egg then
		say(mode == "name" and "none of the ticked eggs are on the map" or ("nothing at luck >= " .. fmt(minLuck)))
		return false
	end
	local name = egg:GetAttribute("Egg")
	local cf = CFrame.new(egg:GetAttribute("Position") + Vector3.new(0, LIFT, 0))

	step("grab " .. name .. " / hop")
	say(("going for %s (%s)"):format(name, fmt(luckOf(name))))
	local landed = hop(cf)
	if landed == nil then
		return false
	elseif landed == false then
		say("the server reverted the hop -- see TeleportFlags in F9")
	end

	step("grab " .. name .. " / press")
	local got = grab(egg, name, cf)
	if got == false then
		strikes[egg] = (strikes[egg] or 0) + 1
		if strikes[egg] >= EGG_STRIKES then
			parked[egg], strikes[egg] = os.clock() + RETRY_AFTER, nil
			log(("%s refused %d times -- parked %ds"):format(name, EGG_STRIKES, RETRY_AFTER))
		end
		say("refused: " .. name)
		return true
	elseif got == nil then
		return true
	end

	log("got " .. name)
	if deposit(name) then
		log("delivered " .. name)
	end
	return true
end

local function setMode(new)
	mode = new
	gen += 1
	local mine = gen
	if not new then
		step("idle")
		say("stopped")
		return
	end
	table.clear(parked)
	table.clear(strikes)
	task.spawn(function()
		while mode and gen == mine do
			if os.clock() - markAt > WATCHDOG then
				log(("stuck %.0fs at: %s"):format(os.clock() - markAt, mark))
				markAt = os.clock()
			end
			task.wait(5)
		end
	end)
	task.spawn(function()
		while mode and gen == mine do
			local did
			local ok, err = pcall(function()
				did = lap()
			end)
			if not ok then
				log("lap failed: " .. tostring(err))
			end
			task.wait(did and 0 or IDLE)
		end
	end)
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Ride a Pet", -- fallback until the live name lands
	folder = "RideAPet", -- never rename: saved configs orphan
	size = UDim2.fromOffset(460, 420),
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local ByName = Tab:Section({ Title = "By name", Icon = "solar:list-bold", Box = true, BoxBorder = true, Opened = true })
local ByLuck = Tab:Section({ Title = "By luck", Icon = "solar:star-bold", Box = true, BoxBorder = true, Opened = true })

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
assert(ticked({ "a" }).a and ticked({ a = true }).a and not ticked({ a = false }).a)

ByName:Dropdown({
	Title = "Eggs",
	Desc = "Best luck first. The farm always takes the best ticked egg on the map.",
	Values = LABELS,
	Value = {},
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		table.clear(wanted) -- the loop holds this table; replacing it would strand the loop
		for label in pairs(ticked(values)) do
			if NAME_OF[label] then
				wanted[NAME_OF[label]] = true
			end
		end
	end,
})

local nameToggle, luckToggle
nameToggle = ByName:Toggle({
	Title = "Auto farm by name",
	Value = false,
	Callback = function(on)
		if on then
			pcall(function()
				luckToggle:Set(false, false)
			end)
			setMode("name")
		elseif mode == "name" then
			setMode(nil)
		end
	end,
})

ByLuck:Input({
	Title = "Min luck",
	Desc = "The number on the egg's billboard. Suffixes work: 500K, 7M, 1.5B",
	Value = fmt(minLuck),
	Placeholder = "7M",
	Callback = function(text)
		local n = parseLuck(text)
		if n then
			minLuck = n
			say("min luck " .. fmt(n))
		else
			say("can't read '" .. tostring(text) .. "' -- try 7M")
		end
	end,
})

luckToggle = ByLuck:Toggle({
	Title = "Auto farm by luck",
	Value = false,
	Callback = function(on)
		if on then
			pcall(function()
				nameToggle:Set(false, false)
			end)
			setMode("luck")
		elseif mode == "luck" then
			setMode(nil)
		end
	end,
})

local Misc = Tab:Section({ Title = "Misc", Icon = "solar:map-point-bold", Box = true, BoxBorder = true, Opened = true })
Misc:Slider({
	Title = "Glide speed",
	Desc = "Studs/s. Lower if 'Teleport detected'; higher reaches further eggs before they break",
	Value = { Min = 50, Max = 400, Default = GLIDE_SPEED },
	Step = 10,
	Callback = function(v)
		GLIDE_SPEED = tonumber(v) or GLIDE_SPEED -- read live by hop() and reachable()
	end,
})
Misc:Button({
	Title = "TP to plot",
	Callback = function()
		if mode then
			say("turn the farm off first -- it would teleport you straight back")
			return
		end
		local home = homeCF()
		say(not home and "can't find your plot" or hop(home) and "at your plot" or "the server reverted the hop")
	end,
})
local line = Misc:Paragraph({ Title = "Status", Desc = "idle" })

-- A resumed loop thread lacks the capability the hidden GUI needs; Heartbeat runs with ours.
local drain = RunService.Heartbeat:Connect(function()
	if pending == nil then
		return
	end
	local msg = pending
	pending = nil
	if not pcall(function()
		line:SetDesc(msg)
	end) then
		log(msg)
	end
end)

say(("ready -- %d eggs on the map"):format(#ActiveEggs:GetChildren()))

-- close ----------------------------------------------------------------------
local function stopAll()
	setMode(nil)
	pcall(function()
		drain:Disconnect()
	end)
end

Window:OnDestroy(function()
	stopAll()
	getgenv().rideAPetStop = nil
end)

getgenv().rideAPetStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().rideAPetStop = nil
end
