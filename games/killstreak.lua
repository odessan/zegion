--[[ Killstreak -- ESP for the battle royale (108448382032231)  PlaceVersion 402

     ESP    : an outline that follows each avatar's shape (a Highlight, through walls), a name, a
              health bar (and a shield bar), the numbers, the distance and the weapon in their
              hands over every live character in the match -- players AND bots, the bots are what
              fills the lobby to ~36. Optional box and tracers. Roblox draws 31 Highlights at most,
              so the outline covers the nearest 28; the labels cover everyone.
              Screen space (Drawing), so nothing is added to the characters and the game never
              sees it; it fires no remotes at all, so there is nothing for the server to reject.
     TEAM   : "friendly" is the game's own test (Client.Combat.isFriendly: same Party on a BR
              server, the team table otherwise, a drone follows its owner). Teammates are hidden
              unless you tick them, and drawn green when you do.

     Mechanics read live (2026-10-13, 37 characters, all of them children of workspace):
       character   Model in workspace root, Humanoid + HumanoidRootPart, one Tool in hands
       player      Players:GetPlayerFromCharacter; Party player attribute = squad id
       bot         no Player, tagged "Bot" (CollectionService), attrs UserId (negative) and Team;
                   a deployed drone is a Bot too, tag "Drone", 25 hp
       health      Humanoid.Health / MaxHealth (250)
       shield      Humanoid attribute "Shields", cap ReplicatedFirst.BattleRoyaleConfig.Shields

     RightControl opens / closes the panel (so does the Zegion logo). Stop: getgenv().killstreakStop() ]]

-- config ---------------------------------------------------------------------
local SCAN_EVERY = 0.2 -- seconds between rebuilds of the target list. The DRAWING is every frame
-- regardless; this only paces the enumeration (friendly test, tool lookup, chams), the costly half.
local POOL = 40 -- boxes drawn at most, nearest first. A match holds ~36 characters, so slack.
local TEXT_SIZE = 13 -- label size in px. Raise it on a high-DPI screen.
local BOX_RATIO = 0.55 -- box width as a fraction of its height (a stood-up R15 rig).
local TOP_OFFSET = 2.8 -- studs above HumanoidRootPart that the box top sits (clears the head)
local FOOT_OFFSET = 3.1 -- studs below it that the box bottom sits (the soles)
local CHAMS_CAP = 28 -- Highlights at once. Roblox draws 31 in total and says nothing about the rest,
-- so the furthest characters past this get no outline (the box / skeleton-free labels still show).
local SHIELD_FALLBACK = 150 -- shield cap if BattleRoyaleConfig.Shields can't be read

local COL_ENEMY = Color3.fromRGB(255, 70, 70)
local COL_BOT = Color3.fromRGB(255, 170, 60)
local COL_FRIEND = Color3.fromRGB(80, 220, 120)
local COL_SHIELD = Color3.fromRGB(80, 170, 255)
local COL_BLACK = Color3.new(0, 0, 0)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local player = Players.LocalPlayer

if getgenv and getgenv().killstreakStop then
	getgenv().killstreakStop() -- re-running must not stack a second panel or a second set of boxes
end

local function log(...)
	print("[killstreak]", ...)
end

if not Drawing then
	warn("[killstreak] this executor has no Drawing library; the ESP can't draw")
	return
end

-- game -----------------------------------------------------------------------
-- The game's own friendly test, so squads, versus teams and drone owners follow its rules
-- rather than a guess of ours. ponytail: Party-only fallback if the module won't load.
local okF, isFriendlyFn = pcall(function()
	return require(ReplicatedStorage.Client.Combat.isFriendly)
end)

local shieldMax = SHIELD_FALLBACK
pcall(function()
	local v = require(game:GetService("ReplicatedFirst").BattleRoyaleConfig).Shields
	if type(v) == "number" and v > 0 then
		shieldMax = v
	end
end)

local function friendly(model, plr)
	if okF then
		local ok, r
		if plr then
			ok, r = pcall(isFriendlyFn, plr)
		else
			ok, r = pcall(isFriendlyFn, nil, model)
		end
		if ok then
			return r == true
		end
	end
	local party = plr and plr:GetAttribute("Party")
	return party ~= nil and party == player:GetAttribute("Party")
end

-- state ----------------------------------------------------------------------
local esp = {
	on = true,
	box = false, -- the outline replaces it; tick it back for the far ones past the Highlight cap
	name = true,
	health = true,
	shield = true,
	dist = true,
	tool = true,
	tracer = false,
	chams = true, -- avatar-shaped outline
	fill = 1, -- Highlight FillTransparency: 1 = outline only, 0 = solid silhouette
	bots = true,
	team = false, -- show teammates
	maxDist = 2000,
}

-- hp 0..1 -> red..green; a pure helper, so it carries its own check
local function hpColor(f)
	f = math.clamp(f, 0, 1)
	return Color3.new(1 - f, f, 0.15)
end
do
	local c0, c1 = hpColor(0), hpColor(1)
	assert(c0.R == 1 and c0.G == 0 and c1.R == 0 and c1.G == 1 and hpColor(5).G == 1, "hpColor")
end

-- scan -----------------------------------------------------------------------
local targets = {} -- nearest first
local summary = { n = 0, players = 0, bots = 0, near = "-", weak = "-" }

local function scan()
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
	local mine = player.Character
	local list, np, nb = {}, 0, 0
	for _, m in ipairs(workspace:GetChildren()) do
		if m:IsA("Model") and m ~= mine then
			local hum = m:FindFirstChildOfClass("Humanoid")
			local hrp = hum and m:FindFirstChild("HumanoidRootPart")
			if hrp and hum.Health > 0 then
				local plr = Players:GetPlayerFromCharacter(m)
				local bot = plr == nil
				if not bot or esp.bots then
					local fr = friendly(m, plr)
					local d = (hrp.Position - camPos).Magnitude
					if (not fr or esp.team) and d <= esp.maxDist then
						local drone = bot and CollectionService:HasTag(m, "Drone")
						local tool = m:FindFirstChildOfClass("Tool")
						list[#list + 1] = {
							m = m,
							hum = hum,
							hrp = hrp,
							bot = bot,
							fr = fr,
							name = drone and "Drone" or (plr and plr.Name or m.Name),
							tool = tool and tool.Name or "",
							d = d,
						}
						if bot then
							nb += 1
						else
							np += 1
						end
					end
				end
			end
		end
	end
	table.sort(list, function(a, b)
		return a.d < b.d
	end)
	targets = list
	local weak
	for _, t in ipairs(list) do
		if not t.fr and (not weak or t.hum.Health < weak.hum.Health) then
			weak = t
		end
	end
	summary.n, summary.players, summary.bots = #list, np, nb
	summary.near = list[1] and ("%s %d st"):format(list[1].name, list[1].d) or "-"
	summary.weak = weak and ("%s %d hp"):format(weak.name, math.ceil(weak.hum.Health)) or "-"
end

-- chams: a fixed pool of Highlights built once, here, on the script's own thread; the loop only
-- re-points Adornee. They sit under workspace.Terrain, NOT the executor's hidden GUI: a
-- Heartbeat connection can't write to anything under gethui() when the script is loaded
-- through the bridge ("lacking capability Plugin", every property, 28 of 28 writes), and
-- Terrain outlives the camera, which the game may replace at match start.
local holder = Instance.new("Folder")
holder.Name = "ZegionKillstreak"
holder.Parent = workspace.Terrain
local pool = {}
for i = 1, CHAMS_CAP do
	local hl = Instance.new("Highlight")
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop -- the point: through walls
	hl.OutlineTransparency = 0
	hl.Parent = holder
	pool[i] = hl
end

local function colorOf(t)
	return t.fr and COL_FRIEND or (t.bot and COL_BOT or COL_ENEMY)
end

local function syncChams()
	local on = esp.on and esp.chams
	for i, hl in ipairs(pool) do
		local t = on and targets[i]
		if t then
			hl.Adornee = t.m
			hl.FillColor, hl.OutlineColor = colorOf(t), colorOf(t)
			hl.FillTransparency = esp.fill
		else
			hl.Adornee = nil
		end
	end
end

-- draw -----------------------------------------------------------------------
local slots = {}

local function newSquare(filled, thick, color)
	local s = Drawing.new("Square")
	s.Filled, s.Thickness, s.Color, s.Visible = filled, thick, color, false
	return s
end

local function newText(center)
	local t = Drawing.new("Text")
	t.Size, t.Center, t.Outline, t.OutlineColor, t.Visible = TEXT_SIZE, center, true, COL_BLACK, false
	return t
end

local function newSlot()
	local line = Drawing.new("Line")
	line.Thickness, line.Visible = 1, false
	return {
		boxO = newSquare(false, 3, COL_BLACK), -- the dark rim that keeps the box readable on any wall
		box = newSquare(false, 1, COL_ENEMY),
		barBg = newSquare(true, 1, COL_BLACK),
		bar = newSquare(true, 1, COL_ENEMY),
		shBg = newSquare(true, 1, COL_BLACK),
		sh = newSquare(true, 1, COL_SHIELD),
		name = newText(true),
		info = newText(true),
		tool = newText(true),
		line = line,
	}
end

local function hide(s)
	for _, d in pairs(s) do
		d.Visible = false
	end
end

local function hideAll()
	for _, s in pairs(slots) do
		hide(s)
	end
end

local function drawSlot(s, t, cam, vp)
	local hum, hrp = t.hum, t.hrp
	if hum.Health <= 0 or not hrp.Parent then
		hide(s)
		return
	end
	local p = hrp.Position
	local top, onT = cam:WorldToViewportPoint(p + Vector3.new(0, TOP_OFFSET, 0))
	local bot, onB = cam:WorldToViewportPoint(p - Vector3.new(0, FOOT_OFFSET, 0))
	if top.Z <= 0 or bot.Z <= 0 or not (onT or onB) then
		hide(s)
		return
	end
	local h = math.max(bot.Y - top.Y, 4)
	local w = h * BOX_RATIO
	local x, y = math.floor(top.X - w / 2), math.floor(top.Y)
	local col = colorOf(t)
	local dist = (p - cam.CFrame.Position).Magnitude

	s.boxO.Visible, s.box.Visible = esp.box, esp.box
	if esp.box then
		s.boxO.Position, s.boxO.Size = Vector2.new(x, y), Vector2.new(w, h)
		s.box.Position, s.box.Size, s.box.Color = Vector2.new(x, y), Vector2.new(w, h), col
	end

	local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
	s.barBg.Visible, s.bar.Visible = esp.health, esp.health
	if esp.health then
		s.barBg.Position, s.barBg.Size = Vector2.new(x - 6, y - 1), Vector2.new(4, h + 2)
		s.bar.Position, s.bar.Size = Vector2.new(x - 5, y + h * (1 - frac)), Vector2.new(2, h * frac)
		s.bar.Color = hpColor(frac)
	end

	local sv = hum:GetAttribute("Shields")
	local shield = type(sv) == "number" and sv or 0
	local showSh = esp.shield and shield > 0
	s.shBg.Visible, s.sh.Visible = showSh, showSh
	if showSh then
		local sf = math.clamp(shield / shieldMax, 0, 1)
		s.shBg.Position, s.shBg.Size = Vector2.new(x - 11, y - 1), Vector2.new(4, h + 2)
		s.sh.Position, s.sh.Size = Vector2.new(x - 10, y + h * (1 - sf)), Vector2.new(2, h * sf)
	end

	s.name.Visible = esp.name
	if esp.name then
		s.name.Text = t.bot and (t.name == "Drone" and t.name or t.name .. " [BOT]") or t.name
		s.name.Color = col
		s.name.Position = Vector2.new(top.X, y - TEXT_SIZE - 3)
	end

	local parts = {}
	if esp.health then
		parts[#parts + 1] = shield > 0 and ("%d+%d"):format(math.ceil(hum.Health), shield) or tostring(math.ceil(hum.Health))
	end
	if esp.dist then
		parts[#parts + 1] = math.floor(dist) .. " st"
	end
	s.info.Visible = #parts > 0
	if #parts > 0 then
		s.info.Text = table.concat(parts, "  ")
		s.info.Color = Color3.new(1, 1, 1)
		s.info.Position = Vector2.new(top.X, y + h + 2)
	end

	local showTool = esp.tool and t.tool ~= ""
	s.tool.Visible = showTool
	if showTool then
		s.tool.Text = t.tool
		s.tool.Color = Color3.fromRGB(200, 200, 200)
		s.tool.Position = Vector2.new(top.X, y + h + 2 + (#parts > 0 and TEXT_SIZE + 1 or 0))
	end

	s.line.Visible = esp.tracer
	if esp.tracer then
		s.line.From, s.line.To, s.line.Color = Vector2.new(vp.X / 2, vp.Y), Vector2.new(top.X, y + h), col
	end
end

local wasOn = false
local function draw()
	if not esp.on then
		if wasOn then
			hideAll()
			wasOn = false
		end
		return
	end
	wasOn = true
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local vp = cam.ViewportSize
	for i = 1, math.min(#targets, POOL) do
		local s = slots[i]
		if not s then
			s = newSlot()
			slots[i] = s
		end
		drawSlot(s, targets[i], cam, vp)
	end
	for i = #targets + 1, #slots do
		hide(slots[i])
	end
end

local conns = {}
local lastScan = 0
local said = {}
local function soft(what, fn) -- pcall that says the first error of each kind, so a dead stage isn't silent
	local ok, err = xpcall(fn, debug.traceback)
	if not ok and not said[what] then
		said[what] = true
		warn("[killstreak]", what, "failed:", err)
	end
end
table.insert(
	conns,
	-- Heartbeat, not RenderStepped: the engine calls RenderStepped with a thread that lacks
	-- the capability to touch the hidden-GUI Highlights ("lacking capability Plugin")
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - lastScan >= SCAN_EVERY then
			lastScan = now
			-- a dead character or a mid-respawn registry throws rather than returning empty,
			-- and an ESP that dies on your own death is an ESP that is off for most of a round
			soft("scan", scan)
			soft("chams", syncChams)
		end
		soft("draw", draw)
	end)
)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Killstreak", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local function toggle(group, idx, text, tip, key, default)
	return group:AddToggle(idx, {
		Text = text,
		Tooltip = tip,
		Default = default,
		Callback = function(v)
			esp[key] = v
		end,
	})
end

local Tab = Window:AddTab("ESP", "eye")
local Draw = Tab:AddLeftGroupbox("ESP", "eye")
local Who = Tab:AddRightGroupbox("Targets", "users")

toggle(Draw, "Esp", "ESP", "Master switch. Everything below is drawn over the game, client-side only", "on", true)
toggle(Draw, "Chams", "Outline", "An outline that follows each avatar's shape, through walls, on the nearest " .. CHAMS_CAP .. " targets (Roblox draws 31 highlights at most)", "chams", true)
Draw:AddSlider("Fill", {
	Text = "Outline fill",
	Tooltip = "0 = solid silhouette, 100 = outline only",
	Default = 100,
	Min = 0,
	Max = 100,
	Rounding = 0,
	Suffix = "%",
	Callback = function(v)
		esp.fill = v / 100
	end,
})
toggle(Draw, "Box", "Box", "A box around each character", "box", false)
toggle(Draw, "Name", "Name", "Username (bots are tagged [BOT])", "name", true)
toggle(Draw, "Health", "Health", "Health bar and the number", "health", true)
toggle(Draw, "Shield", "Shield", "Shield bar next to the health bar, when they have any", "shield", true)
toggle(Draw, "Dist", "Distance", "Studs from your camera", "dist", true)
toggle(Draw, "Tool", "Weapon", "The tool in their hands", "tool", true)
toggle(Draw, "Tracer", "Tracers", "A line from the bottom of the screen to each target", "tracer", false)

toggle(Who, "Bots", "Bots", "Include the AI bots (and drones)", "bots", true)
toggle(Who, "Team", "Teammates", "Show your own squad too, in green", "team", false)
Who:AddSlider("MaxDist", {
	Text = "Max distance",
	Default = esp.maxDist,
	Min = 100,
	Max = 5000,
	Rounding = 0,
	Suffix = " st",
	Callback = function(v)
		esp.maxDist = v
	end,
})
Who:AddLabel("Red = player, orange = bot, green = teammate.", true)

local nextStrip = 0
table.insert(
	conns,
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now < nextStrip then
			return
		end
		nextStrip = now + 0.5
		pcall(Window.SetStatus, Window, { -- ponytail: thrown "lacking capability Plugin" when loaded through the bridge; silence, not fix
			{ "Targets", summary.n },
			{ "Players", summary.players },
			{ "Bots", summary.bots },
			{ "Nearest", summary.near },
			{ "Weakest", summary.weak },
		})
	end)
)

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("Killstreak", {})

-- close ----------------------------------------------------------------------
local function stopAll()
	esp.on = false
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
	for _, s in pairs(slots) do
		for _, d in pairs(s) do
			pcall(function()
				d:Remove()
			end)
		end
	end
	table.clear(slots)
	pcall(function()
		holder:Destroy()
	end)
end

Library:OnUnload(function()
	stopAll()
	getgenv().killstreakStop = nil
end)

getgenv().killstreakStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().killstreakStop = nil
end

log("loaded;", #Players:GetPlayers(), "players,", shieldMax, "shield cap")
