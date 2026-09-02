--[[ Violence District -- ESP, auto skill check, Twist of Fate aim (93978595733734)

     ESP       : every other player gets a through-walls outline and a name tag, coloured
                 by their team. The round is Killer vs Survivors, so the colour IS the
                 information -- red is the thing hunting you, green is everyone else,
                 orange is a survivor who's been knocked.
     GENS      : a label per generator with its live repair percentage -- the number is
                 the point, so this one is text and not an outline.
     PALLETS   : an outline on every pallet still standing. A dropped-and-broken one
                 leaves the folder, so the tag going away IS the "already used" signal.
     WINDOWS   : an outline on every vault window.
     END GATES : an outline on both exit gates.

                 All four are found by CollectionService tag (Generator / pallet /
                 window / Exit), not by path, so a new map doesn't need a new script.
                 Roblox draws at most 31 Highlights at once and says nothing about the
                 rest, so players are adorned first and objects nearest-first.

     SKILLCHK  : presses Space inside the success band of the repair minigame. The band
                 is 102 to 116 degrees PAST Goal.Rotation -- the game's own numbers, read
                 out of Workspace.<you>.Skillcheck-gen, not guessed. Aiming at
                 Goal.Rotation itself, as this used to, misses by about a hundred degrees.

                 Deliberately a keypress and NOT a rewrite of the outgoing
                 SkillCheckResultEvent. That remote is only half of a decision the client
                 makes locally: the same branch that fires it also hides the UI, clears
                 isRepairing and untags the generator point. Rewrite the remote alone and
                 the server thinks you succeeded while your own client has torn the repair
                 down -- which locks you to the generator with no skill-check UI.

                 A missed press is just a missed check, handled by the game as normal.
                 Covers healing too; it is the same GUI.

     TOF AIM   : Twist of Fate always points at the killer. Aim and shoot the way you
                 normally would -- this rewrites the direction on its way out, so the
                 client's own gates (injured, cooldown, silenced, mid-action) still
                 apply and nothing about the shot looks unusual except that it lands.

                 It does NOT beat the 40% misfire. The client sends only the item and a
                 direction; the server rolls, raycasts and answers "Shoot" or
                 "SelfDamage" (ReplicatedStorage.Modules.Items.TwistoffateClient). There
                 is no client-side roll to flip and no hit chance replicated anywhere --
                 a misfire is decided on a machine this script can't reach. What this
                 removes is every OTHER way to miss.

     Client-side only otherwise: the ESP fires no remotes, so it can't be rejected and
     it can't desync you. It draws what the client already replicates.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().violenceEspStop() ]]

-- config ---------------------------------------------------------------------
local REFRESH = 0.1 -- seconds between sync passes. The billboard follows its adornee on
-- its own, so this beat only refreshes text and colour -- 10/s reads as live and costs
-- nothing. Raise it if you're chasing frames on a weak device.
local TAG_SIZE = UDim2.fromOffset(200, 44) -- name tag box; two lines of text
local TAG_OFFSET = Vector3.new(0, 2.6, 0) -- studs above the Head, clear of hats
local TEXT_SIZE = 14
local FILL_ALPHA = 0.7 -- Highlight body fill. Lower it for a solid silhouette; 1 is
-- outline-only, which is quieter but harder to catch out of the corner of your eye.

-- Teams are Spectator / Killer / Survivors (confirmed from the place dump). Anything
-- else -- a team the game adds later, or a player between rounds with none -- falls
-- through to DEFAULT rather than going invisible.
local TEAM_COLORS = {
	Killer = Color3.fromRGB(255, 60, 60),
	Survivors = Color3.fromRGB(80, 220, 110),
	Spectator = Color3.fromRGB(150, 150, 150),
}
local DEFAULT_COLOR = Color3.fromRGB(255, 255, 255)
local KNOCKED_COLOR = Color3.fromRGB(255, 145, 40) -- a downed survivor, from the
-- character's own Knocked attribute. Deliberately not red: at a glance the only thing
-- that should read as red is the killer.

-- World objects, all found by CollectionService tag. Adding one is a row: the tag, how
-- it's drawn, its colour, and optionally a text() for anything live worth reading.
--   mode "tag"       a floating label -- for something whose STATE you need (a %)
--   mode "highlight" an outline -- for something whose POSITION is the whole answer
local OBJECTS = {
	{
		key = "gens",
		tag = "Generator", -- Workspace.Map.Generators.* models carry it
		title = "Generators",
		desc = "Every generator and how far along it is",
		mode = "tag",
		color = Color3.fromRGB(255, 205, 70),
		text = function(inst)
			return ("Gen %d%%"):format(inst:GetAttribute("RepairProgress") or 0)
		end,
	},
	{
		key = "pallets",
		tag = "pallet", -- Workspace.Map.Pallets.* models; a broken one loses the tag
		title = "Pallets",
		desc = "Every pallet still standing",
		mode = "highlight",
		color = Color3.fromRGB(215, 155, 90),
	},
	{
		key = "windows",
		tag = "window", -- the Bottom part of each Workspace.Map.Vaults.Window
		title = "Windows",
		desc = "Every vault window",
		mode = "highlight",
		color = Color3.fromRGB(110, 185, 255),
	},
	{
		key = "gates",
		tag = "Exit",
		title = "End gates",
		desc = "Both exit gates",
		mode = "highlight",
		color = Color3.fromRGB(120, 255, 190),
		resolve = function(inst)
			-- The tag sits on ExitLever.Main, a lever-sized mesh. Two models up is
			-- Workspace.Map.Gate -- the doors themselves, which is what you can pick out
			-- from across the map. Falls back to the lever if the shape ever differs.
			local gate = inst.Parent and inst.Parent.Parent
			return (gate and gate:IsA("Model")) and gate or inst
		end,
	},
}

local MAX_HIGHLIGHTS = 31 -- Roblox renders no more than this many Highlights and gives
-- no error for the rest -- they just don't draw. Players are adorned first and objects
-- nearest-first, so what you lose is the pallet on the far side of the map.

local Players = game:GetService("Players")
local player = Players.LocalPlayer

if getgenv and getgenv().violenceEspStop then
	getgenv().violenceEspStop() -- re-running must not stack a second panel/loop
end

-- world ----------------------------------------------------------------------
-- Everything lives in one ScreenGui under the executor's hidden parent so the game's
-- own code never sees it and a round reset never reparents it away.
local holder = Instance.new("ScreenGui")
holder.Name = "ZegionESP"
holder.ResetOnSpawn = false
holder.Parent = (gethui and gethui()) or (get_hidden_gui and get_hidden_gui()) or game:GetService("CoreGui")

local function colorFor(plr, char)
	-- Knocked outranks team: a downed survivor is a different thing to you than a
	-- running one, whether you're going to pick them up or step over them.
	if char and (char:GetAttribute("Knocked") or char:HasTag("Knocked")) then
		return KNOCKED_COLOR
	end
	local team = plr.Team
	return (team and TEAM_COLORS[team.Name]) or DEFAULT_COLOR
end

local function rootOf(char)
	return char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Head"))
end

-- esp ------------------------------------------------------------------------
local CollectionService = game:GetService("CollectionService")

local esp = { players = false } -- one flag per OBJECTS row is added below
local marks = {} -- player or tagged instance -> { hl?, bb, label }

-- A mark builds only the pieces its mode asks for. Players get both -- the outline finds
-- them, the label says who and how far -- while a pallet is only ever a position, so a
-- label on it would be four words repeating what the glow already said.
local function markFor(key, mode)
	local m = marks[key]
	if m then
		return m
	end
	m = {}

	if mode ~= "highlight" then
		m.bb = Instance.new("BillboardGui")
		m.bb.Size = TAG_SIZE
		m.bb.StudsOffset = TAG_OFFSET
		m.bb.AlwaysOnTop = true
		m.bb.MaxDistance = math.huge
		m.bb.Parent = holder

		m.label = Instance.new("TextLabel")
		m.label.Size = UDim2.fromScale(1, 1)
		m.label.BackgroundTransparency = 1
		m.label.Font = Enum.Font.GothamBold
		m.label.TextSize = TEXT_SIZE
		m.label.TextStrokeTransparency = 0.4 -- readable on a bright wall or in a dark corner
		m.label.RichText = false
		m.label.Parent = m.bb
	end

	if mode ~= "tag" then
		m.hl = Instance.new("Highlight")
		m.hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop -- the whole point: through walls
		m.hl.FillTransparency = FILL_ALPHA
		m.hl.OutlineTransparency = 0
		m.hl.Parent = holder
	end

	marks[key] = m
	return m
end

local function clear(key)
	local m = marks[key]
	if not m then
		return
	end
	if m.hl then
		m.hl:Destroy()
	end
	if m.bb then
		m.bb:Destroy()
	end
	marks[key] = nil
end

local function clearAll(pred)
	for key in pairs(marks) do
		if not pred or pred(key) then
			clear(key)
		end
	end
end

-- A tagged Model hangs its billboard off its own PrimaryPart; a tagged Part is already
-- the anchor. Anything with neither isn't loaded yet and is skipped, not errored on.
local function anchorOf(inst)
	if inst:IsA("BasePart") then
		return inst
	end
	return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
end

local function syncPlayers(me)
	local used = 0
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= player then
			local char = plr.Character
			local root = rootOf(char)
			-- No root means dead, unloaded or streamed out. Drop the mark rather than
			-- leaving it stuck on a corpse -- it comes back free next pass.
			if not root then
				clear(plr)
				continue
			end

			local m = markFor(plr, "both")
			local color = colorFor(plr, char)
			used += 1

			m.hl.Adornee = char
			m.hl.FillColor = color
			m.hl.OutlineColor = color

			m.bb.Adornee = char:FindFirstChild("Head") or root
			local text = plr.DisplayName ~= plr.Name and (plr.DisplayName .. " (" .. plr.Name .. ")") or plr.Name
			if me then
				text = text .. ("\n%d studs"):format((root.Position - me.Position).Magnitude)
			end
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum and hum.MaxHealth > 0 then
				text = text .. ("  %d%%"):format(hum.Health / hum.MaxHealth * 100)
			end
			m.label.Text = text
			m.label.TextColor3 = color
		end
	end

	-- Players who left keep a mark until something reaps it; PlayerRemoving would do it
	-- too, but this pass already walks the table and needs no connection to unhook.
	clearAll(function(key)
		return typeof(key) == "Instance" and key:IsA("Player") and key.Parent ~= Players
	end)
	return used
end

local function isPlayerKey(key)
	return typeof(key) == "Instance" and key:IsA("Player")
end

local function syncObjects(me, budget)
	-- Everything is collected before anything is drawn, because the Highlight budget is
	-- global: whether a given pallet gets an outline depends on where every OTHER object
	-- is, not just that pallet.
	local wanted = {}
	for _, row in ipairs(OBJECTS) do
		if esp[row.key] then
			for _, tagged in ipairs(CollectionService:GetTagged(row.tag)) do
				local inst = row.resolve and row.resolve(tagged) or tagged
				local anchor = anchorOf(inst)
				if anchor then
					table.insert(wanted, {
						inst = inst,
						anchor = anchor,
						row = row,
						dist = me and (anchor.Position - me.Position).Magnitude or 0,
					})
				end
			end
		end
	end
	table.sort(wanted, function(a, b)
		return a.dist < b.dist
	end)

	local seen = {}
	for _, w in ipairs(wanted) do
		seen[w.inst] = true
		local m = markFor(w.inst, w.row.mode)
		if m.hl then
			if budget > 0 then
				budget -= 1
				m.hl.Adornee = w.inst
				m.hl.FillColor = w.row.color
				m.hl.OutlineColor = w.row.color
			else
				m.hl.Adornee = nil -- over budget it wouldn't draw anyway; leaving the
				-- Adornee set would just spend the slot on the far side of the map
			end
		end
		if m.bb then
			m.bb.Adornee = w.anchor
			local text = w.row.text and w.row.text(w.inst) or w.row.title
			if me then
				text = text .. ("\n%d studs"):format(w.dist)
			end
			m.label.Text = text
			m.label.TextColor3 = w.row.color
		end
	end

	-- A broken pallet, a finished map and a toggled-off row all look the same from here:
	-- the mark wasn't touched this pass. One `seen` set reaps all three.
	clearAll(function(key)
		return not isPlayerKey(key) and not seen[key]
	end)
end

local function anyOn()
	if esp.players then
		return true
	end
	for _, row in ipairs(OBJECTS) do
		if esp[row.key] then
			return true
		end
	end
	return false
end

local gen = 0
local function restart()
	gen += 1
	local mine = gen -- off-then-on inside one REFRESH must not leave two loops running
	if not anyOn() then
		clearAll()
		return
	end
	task.spawn(function()
		while gen == mine and anyOn() do
			local ok, err = pcall(function()
				local me = rootOf(player.Character)
				local used = 0
				if esp.players then
					used = syncPlayers(me) -- players claim their outlines first
				else
					clearAll(isPlayerKey)
				end
				syncObjects(me, MAX_HIGHLIGHTS - used)
			end)
			if not ok then
				warn("[violence] esp", err)
			end
			task.wait(REFRESH)
		end
	end)
end

-- skill check ----------------------------------------------------------------
-- Read straight out of the game's own Workspace.<you>.Skillcheck-gen. Pressing Space
-- calls handleSkillCheck("success"), which does NOT mean success -- it re-grades from
-- the needle itself:
--
--     local Rotation = Line.Rotation
--     if 102 + Goal.Rotation <= Rotation and Rotation <= 116 + Goal.Rotation then
--         SkillCheckResultEvent:FireServer("success", 1, gen, point); Great:Play()
--     elseif Rotation <= 159 + Goal.Rotation then  -> "neutral", 0
--     else -> "fail", -10, Frame.Visible = false, isRepairing = false
--
-- So the band is 102..116 degrees PAST Goal.Rotation, not at it -- which is why every
-- earlier attempt to aim at Goal.Rotation missed by about a hundred degrees.
--
-- And it is why the previous version locked you to the generator: rewriting the
-- outgoing remote told the server "success" while this function had already taken its
-- fail branch locally -- hiding the UI, clearing isRepairing and untagging the point.
-- The server kept you repairing, the client had torn its own UI down. Never rewrite one
-- half of a client-authoritative decision; make the client decide the way you want.
local PRESS_AT = 102 -- degrees past Goal.Rotation where "success" starts (game's number)
local PRESS_END = 116 -- ...and ends. Past this to +159 is "neutral", beyond that "fail".
-- Press on entry, not in the middle: the needle only ever arrives from below, and the
-- frame or two the keypress spends reaching the game's handler carries it further in.
-- Landing at the far edge would demote a success to a neutral.

local VIM = game:GetService("VirtualInputManager")
local skill = { on = false, log = false }

local function checkParts()
	local gui = player:FindFirstChildOfClass("PlayerGui")
	local screen = gui and gui:FindFirstChild("SkillCheckPromptGui")
	local frame = screen and screen:FindFirstChild("Check")
	if frame and frame.Visible then
		return frame:FindFirstChild("Line"), frame:FindFirstChild("Goal")
	end
end

local skillGen = 0
local function setSkill(state)
	skill.on = state
	skillGen += 1
	local mine = skillGen
	if not state then
		return
	end
	task.spawn(function()
		local armed = true
		while skill.on and skillGen == mine do
			local line, goal = checkParts()
			if not line or not goal then
				armed = true -- the prompt is down; the next one is a new check
			else
				local rot, from = line.Rotation, goal.Rotation + PRESS_AT
				if skill.log then
					print(("[violence] line %.1f goal %.1f window %.0f-%.0f"):format(
						rot, goal.Rotation, from, goal.Rotation + PRESS_END))
				end
				if armed and rot >= from and rot <= goal.Rotation + PRESS_END then
					armed = false
					VIM:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
					task.wait()
					VIM:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
				end
			end
			task.wait() -- the needle crosses a 14 degree band in a handful of frames
		end
		-- Never leave the key logically held if the loop is killed mid-press.
		pcall(function()
			VIM:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
		end)
	end)
end

-- twist of fate --------------------------------------------------------------
-- The item's whole client half is one line: Fire:FireServer(item, camera.LookVector).
-- So rather than rebuild that call -- which means guessing what `item` is, and losing
-- every gate the game already enforces -- hook the namecall and swap arg 2 for a vector
-- aimed at the killer. The game supplies the item, the aim, the cooldown and the
-- animation; only the direction is ours.
local Remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes", 10)
local Fire = Remotes
	and Remotes:WaitForChild("Items", 10)
	and Remotes.Items:WaitForChild("Twist of Fate", 10)
	and Remotes.Items["Twist of Fate"]:WaitForChild("Fire", 10)

-- The hook outlives the panel: a __namecall hook can't be cleanly removed, so it's
-- installed once per session and reads a flag. Re-pasting reuses it instead of stacking
-- a second one -- which is why the state lives in getgenv and not in a local.
local aim = getgenv().ZegionTofAim or { on = false, hooked = false }
getgenv().ZegionTofAim = aim

-- The direction is computed OUT here, on its own beat, and the hook only reads the
-- field. That's not an optimisation: finding the killer means GetPlayers/FindFirstChild,
-- and a namecall made from inside the namecall hook overwrites getnamecallmethod() for
-- the call still in flight -- so the pass-through fired as Fire:FindFirstChild(item,
-- direction) instead of FireServer, which is the "argument #1 expects a string" and
-- "unable to cast Vector3 to bool" pair. Nothing inside the hook may call a method.
local function killerRoot()
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= player and plr.Team and plr.Team.Name == "Killer" then
			return rootOf(plr.Character)
		end
	end
end

local aimGen = 0
local function trackKiller(state)
	aimGen += 1
	local mine = aimGen
	if not state then
		aim.dir = nil
		return
	end
	task.spawn(function()
		while aim.on and aimGen == mine do
			-- ponytail: aimed root-to-root. If the server ever raycasts from the barrel
			-- instead, the few studs of offset show up as misses at range and the fix is
			-- to originate this at the gun model's Primarypart.
			local target, me = killerRoot(), rootOf(player.Character)
			aim.dir = (target and me) and (target.Position - me.Position).Unit or nil
			task.wait() -- the shot uses whatever this last wrote, so a frame stale at most
		end
		aim.dir = nil
	end)
end

if Fire and not aim.hooked and hookmetamethod and getnamecallmethod then
	local wrap = newcclosure or function(f)
		return f
	end
	local old
	old = hookmetamethod(
		game,
		"__namecall",
		wrap(function(self, ...)
			-- Table reads and comparisons only in here. No method calls. See above.
			if aim.on and aim.dir and self == Fire and getnamecallmethod() == "FireServer" then
				local item = ...
				return old(self, item, aim.dir)
			end
			return old(self, ...)
		end)
	)
	aim.hooked = true
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Violence District", -- fallback until the live name lands
	folder = "ViolenceDistrict", -- unchanged: renaming it orphans configs already saved in-game
	size = UDim2.fromOffset(440, 430), -- seven rows across three sections
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:eye-bold" })
local Sec = Tab:Section({
	Title = "ESP",
	Icon = "solar:users-group-rounded-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})

Sec:Toggle({
	Title = "Player ESP",
	Desc = "Outline + name tag on everyone, coloured by team",
	Value = false,
	Callback = function(v)
		esp.players = v
		restart()
	end,
})

for _, row in ipairs(OBJECTS) do
	esp[row.key] = false
	Sec:Toggle({
		Title = row.title,
		Desc = row.desc,
		Value = false,
		Callback = function(v)
			esp[row.key] = v
			restart()
		end,
	})
end

local RepairSec = Tab:Section({
	Title = "Repairing",
	Icon = "solar:bolt-circle-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})

RepairSec:Toggle({
	Title = "Auto skill check",
	Desc = "Presses Space inside the real success band. Works for healing too",
	Value = false,
	Callback = setSkill,
})

RepairSec:Toggle({
	Title = "Log skill checks",
	Desc = "Prints the needle, the goal and the success window to F9",
	Value = false,
	Callback = function(v)
		skill.log = v
	end,
})

local ItemSec = Tab:Section({
	Title = "Twist of Fate",
	Icon = "solar:crosshair-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})

ItemSec:Toggle({
	Title = "Aim at killer",
	Desc = "Shoot as normal; the shot points at the killer. Can't beat the 40% misfire -- that roll is the server's",
	Value = false,
	Callback = function(v)
		if v and not aim.hooked then
			warn("[violence] no namecall hook -- executor is missing hookmetamethod/getnamecallmethod")
		end
		aim.on = v
		trackKiller(v) -- the hook can't look the killer up itself; this feeds it
	end,
})

Tab:Paragraph({
	Title = "Teams",
	Desc = "Red = Killer, green = Survivors, grey = Spectator, white = no team yet",
})

-- close ----------------------------------------------------------------------
local function stopAll()
	esp.players = false
	for _, row in ipairs(OBJECTS) do
		esp[row.key] = false
	end
	restart() -- anyOn() is false now, so this clears every mark instead of relooping
	setSkill(false)
	aim.on = false -- the hook stays installed for the session; the flag is the off switch
	trackKiller(false)
	pcall(function()
		holder:Destroy()
	end)
end

Window:OnDestroy(function()
	stopAll()
	getgenv().violenceEspStop = nil
end)

getgenv().violenceEspStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().violenceEspStop = nil
end
