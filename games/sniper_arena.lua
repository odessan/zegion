--[[ Sniper Arena -- ESP and aim for the sniper FPS (119259569670784)

     ESP    : a box, a name and a health bar over every live enemy in your world. Screen
              space, so it doesn't care what the game does to their transparency, and it
              reads health straight off the replicated attribute rather than guessing.
     AIM    : three ways to put the crosshair on a head, armed here and live only while
              you HOLD the aim key. Assist hands the job to the game's own aim assist,
              Snap steers the camera itself, Silent moves nothing and rewrites the shot.

     The aim key defaults to right mouse -- which is this game's ADS -- so aim engages
     exactly when you scope and never while you're running around.

     This is a PvP game with real people in it, which none of the other scripts in here
     are. There is no client-side anti-cheat (the whole tree has no hookmetamethod /
     getgenv / checkcaller string in it), but the server logs Noscope/Quickscope/KillStreak
     on every kill, so what gets you banned is a person watching, not code. Assist is the
     default for that reason and Silent ships off.

     RightShift frees the cursor so you can click the panel, and locks it back so you can
     play -- this game re-locks the mouse every second, so the panel needs it.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     End panics: every feature off, in one keypress, without finding the panel.
     Stop: getgenv().sniperArenaStop() ]]

-- config ---------------------------------------------------------------------
local ESP_MAX_DIST = 1500 -- studs past which a target isn't drawn. The game's own bullet
-- cap is 700 (Config.Combat.BulletMaxDistance), so anything past that is information
-- rather than a target -- lower this if the screen gets busy.
local ESP_MAX_DRAWN = 24 -- box pool ceiling. Sorted by distance, so the ones you drop are
-- always the furthest. Servers here run ~16 entities, so this is slack, not a limit.
local ESP_REFRESH = 0.25 -- seconds between rebuilds of the target list. The DRAWING is
-- every frame regardless; this only paces the enumeration, which is the expensive half.
local ESP_TEXT = 13 -- name label size in px
local BOX_RATIO = 0.62 -- box width as a fraction of its height. Derived from a stood-up
-- R15 rig; raise it if crouched targets look pinched.

local AIM_FOV = 12 -- degrees off the crosshair a target must be within to be picked. This
-- is the single number that decides how obvious the aim looks: 5 is a nudge, 30 is a
-- spinbot. The game's own assist works out to roughly 35 at point blank, tightening with
-- distance, so anything under 15 is inside what an ordinary player already gets on mobile.
local AIM_SMOOTH = 12 -- Snap mode lerp rate, per second. Multiplied by delta time, so it's
-- framerate-independent: 4 is a lazy drag, 12 is firm, 40 is indistinguishable from a
-- teleport. The game's own assist peaks at about 10.
local AIM_WALLCHECK = true -- refuse a target you have no line of sight to. Off makes the
-- aim track through walls, which is instantly readable to anyone spectating you.
local AIM_HEAD = true -- aim at the head rather than the torso. The head is also what makes
-- a hit register as a headshot: the server decides that from the part NAME the client's
-- own crosshair raycast landed on, so aiming here is what earns the multiplier.
local AIM_TEAMCHECK = true -- honour the game's own friendly test. Off only makes sense in
-- FFA, where the game already reports everyone as an enemy.

local AIM_KEY = Enum.UserInputType.MouseButton2 -- hold to engage. Accepts a KeyCode too.
local AIM_HOLD = true -- true = live while held, false = press once to latch on/off
local PANIC_KEY = Enum.KeyCode.End -- everything off, no panel needed
local MOUSE_KEY = Enum.KeyCode.RightShift -- free the cursor to use the panel, and lock it
-- back. It needs its own key: this game re-locks the mouse to centre on a one-second loop,
-- so the panel is unclickable without it -- and freeing the cursor stops the camera
-- following the mouse, so leaving it free means you cannot aim. Locked by default.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
local Camera = workspace.CurrentCamera

if getgenv and getgenv().sniperArenaStop then
	getgenv().sniperArenaStop() -- re-running must not stack a second panel or a second hook
end

-- game modules ---------------------------------------------------------------
-- Everything this script does routes through the game's own modules rather than through
-- Instance paths, because this game keeps almost nothing where you'd look for it: an
-- entity's model is parented under the Player for humans and under a Highlight holder for
-- bots, and it gets REPARENTED as the game highlights it. The registry is the only stable
-- handle. A `require` here returns the same table the game's own code is holding.
local M = {}
do
	local ok, err = pcall(function()
		M.EntityService = require(ReplicatedStorage.Remote.EntityService)
		M.Entity = require(ReplicatedStorage.Remote.EntityService.Entity)
		M.WorldManager = require(ReplicatedStorage.Remote.EntityService.WorldManager)
		M.EntityController = require(ReplicatedStorage.Client.EntityController)
		M.GameService = require(ReplicatedStorage.Remote.GameService)
		M.GameController = require(ReplicatedStorage.Client.GameController)
		M.Settings = require(ReplicatedStorage.Client.Settings)
		M.InputHelper = require(ReplicatedStorage.Client.InputHelper)
		M.Components = require(ReplicatedStorage.Common.CombatService.Components)
	end)
	if not ok then
		warn("[sniper] the game's module tree moved, nothing here will work: " .. tostring(err))
		return
	end
end
local LocalEntity = M.EntityService.LocalEntity

-- world ----------------------------------------------------------------------
-- One target list, rebuilt on a beat, read by both ESP and aim. Rebuilding is the only
-- expensive part; reading a cached record costs nothing, so the drawing can stay on
-- RenderStepped while the enumeration ticks at ESP_REFRESH.
local targets = {}
local lastBuild = 0

-- The registry is a TableUtils.NewDict proxy. It implements __iter and __len but NOT
-- __pairs, so `pairs(dict)` walks the proxy's own bookkeeping (_count/_items/OnAdded/
-- OnRemoved) and hands you four rows that look exactly like four enemies. Generalized-for
-- is the only correct read, here and on Room.Clients / ClientsByTeam / World.Entities.
local function eachEntity(fn)
	local dict = M.WorldManager.GetFocusedEntities()
	if not dict then
		return
	end
	for _, e in dict do
		fn(e)
	end
end

-- The head is two different things depending on who you're looking at, and the difference
-- is silent: GetHeadPart() is only implemented on PlayerEntity, so it returns nil for
-- every bot -- and this game's servers are mostly bots. The rig's own Head is the general
-- answer; GetHeadAt() (root + 1.5) is the fallback when the rig hasn't streamed, and it
-- lands within 0.05 studs of the real Collider.Head.
local function headOf(e, rig)
	local part = e:GetHeadPart() or (rig and rig:FindFirstChild("Head"))
	if part then
		return part.Position
	end
	local cf = e:GetHeadAt()
	return cf and cf.Position
end

local function isEnemy(e)
	if e == LocalEntity or not e:IsAlive() then
		return false
	end
	-- IsFriendly is the only test that survives every mode. GetEnemyTeams() returns an
	-- empty list while you're spectating another room, and in FFA it returns a bucket that
	-- contains YOU -- both of which read as "no enemies" rather than as a bug.
	if AIM_TEAMCHECK and LocalEntity:IsFriendly(e) then
		return false
	end
	return true
end

local function build()
	local out = {}
	local camPos = Camera.CFrame.Position
	eachEntity(function(e)
		if not isEnemy(e) then
			return
		end
		local ctrl = M.EntityController.GetController(e)
		local rig = ctrl and ctrl:GetCurrentModel()
		local pivot = e:GetPivot(true) -- raw root CFrame; GetPivot() would give the feet
		local feet = e:GetPivot()
		if not pivot then
			return
		end
		local head = headOf(e, rig)
		if not head then
			return
		end
		local pos = pivot.Position
		local dist = (pos - camPos).Magnitude
		if dist > ESP_MAX_DIST then
			return
		end
		table.insert(out, {
			entity = e,
			instance = e.Instance,
			rig = rig,
			bot = e.Instance:HasTag("Bot"),
			name = e:GetDisplayName() or "?",
			head = head,
			pos = pos,
			feet = feet and feet.Position or (pos - Vector3.new(0, 3, 0)),
			health = e.Health or 0,
			maxHealth = e.MaxHealth or 100,
			dist = dist,
		})
	end)
	table.sort(out, function(a, b)
		return a.dist < b.dist
	end)
	targets = out
end

-- esp ------------------------------------------------------------------------
local esp = { box = true, name = true, health = true, bots = true, on = false }

local screen = Instance.new("ScreenGui")
screen.Name = "ZegionSniperESP"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 9
screen.Enabled = false
-- gethui() keeps it out of PlayerGui, where the game's own HUD code walks children.
pcall(function()
	screen.Parent = (gethui and gethui()) or (get_hidden_gui and get_hidden_gui()) or player:WaitForChild("PlayerGui")
end)
if not screen.Parent then
	screen.Parent = player:WaitForChild("PlayerGui")
end

-- A fixed pool, built once. Creating and destroying Frames per target per frame is the
-- usual way an ESP turns into a stutter; here nothing is ever created after startup and
-- an unused slot is just Visible = false.
local pool = {}
local function newSlot()
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = screen

	local box = Instance.new("Frame")
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Size = UDim2.fromScale(1, 1)
	box.Parent = holder
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1
	stroke.Color = Color3.fromRGB(255, 70, 60)
	stroke.Parent = box

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamMedium
	label.TextSize = ESP_TEXT
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.4
	label.Size = UDim2.new(1, 80, 0, ESP_TEXT + 2)
	label.Position = UDim2.new(0, -40, 0, -ESP_TEXT - 4)
	label.Parent = holder

	local barBg = Instance.new("Frame")
	barBg.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	barBg.BackgroundTransparency = 0.35
	barBg.BorderSizePixel = 0
	barBg.Size = UDim2.new(0, 3, 1, 0)
	barBg.Position = UDim2.new(0, -6, 0, 0)
	barBg.Parent = holder

	local bar = Instance.new("Frame")
	bar.BorderSizePixel = 0
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.fromScale(0, 1)
	bar.Parent = barBg

	return { holder = holder, box = box, stroke = stroke, label = label, barBg = barBg, bar = bar }
end
for _ = 1, ESP_MAX_DRAWN do
	table.insert(pool, newSlot())
end

local function drawESP()
	local used = 0
	if esp.on then
		local camPos = Camera.CFrame.Position
		for _, t in ipairs(targets) do
			if used >= ESP_MAX_DRAWN then
				break
			end
			if esp.bots or not t.bot then
				-- Two projections, not eight corners: the box is derived from the head and
				-- feet points, which is both cheaper and steadier than a bounding box that
				-- swells every time an arm swings.
				local top, onScreen = Camera:WorldToViewportPoint(t.head + Vector3.new(0, 0.6, 0))
				local bottom = Camera:WorldToViewportPoint(t.feet)
				if onScreen then
					local h = math.abs(bottom.Y - top.Y)
					local w = h * BOX_RATIO
					if h > 4 then
						used += 1
						local s = pool[used]
						s.holder.Position = UDim2.fromOffset(top.X - w / 2, top.Y)
						s.holder.Size = UDim2.fromOffset(w, h)
						s.holder.Visible = true
						s.box.Visible = esp.box

						s.label.Visible = esp.name
						if esp.name then
							s.label.Text = ("%s%s  [%d]"):format(t.name, t.bot and " (bot)" or "", math.floor(t.dist))
						end

						s.barBg.Visible = esp.health
						if esp.health then
							local frac = math.clamp(t.health / math.max(t.maxHealth, 1), 0, 1)
							s.bar.Size = UDim2.fromScale(1, frac)
							-- red at zero through green at full; one lerp, no colour table
							s.bar.BackgroundColor3 = Color3.fromRGB(255, 60, 50):Lerp(Color3.fromRGB(90, 230, 110), frac)
						end
					end
				end
			end
		end
	end
	for i = used + 1, ESP_MAX_DRAWN do
		pool[i].holder.Visible = false
	end
end

-- aim ------------------------------------------------------------------------
local aim = { assist = false, snap = false, silent = false, engaged = false, latched = false }

-- Same raycast shape the game's own assist uses (CameraController's params): the
-- CanCollide group with RespectCanCollide off, so it sees map geometry and not players.
local losParams = RaycastParams.new()
losParams.CollisionGroup = "CanCollide"
losParams.RespectCanCollide = false
losParams.FilterType = Enum.RaycastFilterType.Exclude

local function aimPointOf(t)
	return AIM_HEAD and t.head or t.pos
end

-- Nearest to the crosshair by ANGLE, not by screen pixels: an angle is the same number at
-- every FOV, so changing your scope doesn't quietly widen the cone.
local function pick()
	local cf = Camera.CFrame
	local origin, look = cf.Position, cf.LookVector
	local best, bestAngle
	for _, t in ipairs(targets) do
		local p = aimPointOf(t)
		local to = p - origin
		local mag = to.Magnitude
		if mag > 1 then
			local dot = math.clamp(look:Dot(to / mag), -1, 1)
			local angle = math.deg(math.acos(dot))
			if angle <= AIM_FOV and (not bestAngle or angle < bestAngle) then
				if AIM_WALLCHECK then
					-- Built by insert, not as a literal: a streamed-out rig makes t.rig nil,
					-- and a nil in the middle of an array literal truncates it -- the filter
					-- would silently shrink to one entry and every target would read as
					-- blocked by its own body.
					local ignore = {}
					if t.rig then
						table.insert(ignore, t.rig)
					end
					if t.instance then
						table.insert(ignore, t.instance)
					end
					if player.Character then
						table.insert(ignore, player.Character)
					end
					losParams.FilterDescendantsInstances = ignore
					if workspace:Raycast(origin, to, losParams) then
						continue -- something solid in the way; try the next one
					end
				end
				best, bestAngle = t, angle
			end
		end
	end
	return best
end

local current -- the target the aim modules are all working on this frame

-- Mode A: the game's own aim assist, which is already written, already framerate-correct,
-- and already carries the smoke/flash/line-of-sight gates. It is switched off on PC by a
-- single branch in AutoAim.lua -- `if InputHelper.IsKeyboard() ... then return end` -- and
-- the BoolValue that would override it is only created in Studio, so this one function is
-- the whole gate. InputHelper is an unprotected table, so it's a plain assignment.
local realIsKeyboard = M.InputHelper.IsKeyboard
local savedSettings = {}
local assistHooked = false

-- Every write to a setting fires UpdateData:FireServer and the server PERSISTS it, so a
-- naive `Settings.AutoAim.Value = true` follows you to your next session. PauseSync is the
-- game's own suppression list and is re-exported on the Settings facade.
local function setSetting(name, value)
	local obj = M.Settings[name]
	if not obj then
		return
	end
	if savedSettings[name] == nil then
		savedSettings[name] = obj.Value
		pcall(function()
			M.Settings.PauseSync(obj)
		end)
	end
	pcall(function()
		obj.Value = value
	end)
end

local function restoreSettings()
	for name, value in pairs(savedSettings) do
		local obj = M.Settings[name]
		if obj then
			pcall(function()
				obj.Value = value
			end)
		end
	end
	table.clear(savedSettings)
end

-- Arming and firing are separate on purpose. Installing the hook is the expensive, stateful
-- half -- it rewrites a shared function and snapshots four settings -- and doing that on
-- every trigger release would churn a server-persisted setting dozens of times a round.
-- So the toggle installs, and the aim key only flips the one boolean the assist reads.
local function armAssist(on)
	if on and not assistHooked then
		assistHooked = true
		M.InputHelper.IsKeyboard = function()
			return false
		end
		-- Without this the IsKeyboard flip sends the game to CameraMode_NonKeyboard, which
		-- defaults to third person -- you'd turn on aim assist and lose first person.
		setSetting("CameraMode_NonKeyboard", 1)
		setSetting("AutoAimStrength", 100)
		setSetting("HipfireAim", true)
		setSetting("AutoAim", false) -- armed, not live: the key decides
	elseif not on and assistHooked then
		assistHooked = false
		M.InputHelper.IsKeyboard = realIsKeyboard
		restoreSettings()
	end
end

local function liveAssist(on)
	if assistHooked then
		pcall(function()
			M.Settings.AutoAim.Value = on -- already inside PauseSync, so this doesn't replicate
		end)
	end
end

-- Mode C: no camera movement at all. The client picks who it hit and asserts the headshot
-- (ClientShootableComponent sets Target / TargetPos / TargetHeadshot from its own crosshair
-- raycast, and the headshot is decided by the hit part being NAMED "Head"), so rewriting
-- those three fields is the whole feature.
--
-- ponytail: only those three. args.Start / Direction / Spread are client-supplied too, but
-- each one is a separate unverified guess about what the server will accept, and this one
-- has at least been probed.
local Shootable = M.Components.Shootable
local realLocalShoot = Shootable and Shootable.LocalShoot
local silentHooked = false

local function setSilent(on)
	if not Shootable or not realLocalShoot then
		return
	end
	if on and not silentHooked then
		silentHooked = true
		Shootable.LocalShoot = function(self, args)
			local t = aim.engaged and current
			if t and t.entity:IsAlive() then
				args = args or {}
				args.Target = t.instance
				-- Object space, not world: this is the lag-compensation representation the
				-- server rewinds the victim against.
				local pivot = t.entity:GetPivot(true)
				if pivot then
					args.TargetPos = pivot:PointToObjectSpace(aimPointOf(t))
					args.TargetHeadshot = AIM_HEAD
				end
			end
			return realLocalShoot(self, args)
		end
	elseif not on and silentHooked then
		silentHooked = false
		Shootable.LocalShoot = realLocalShoot
	end
end

-- Mode B: steer the camera ourselves.
--
-- NOT via CameraController.ConnectPrivateEvent -- both of its slots are capped at one
-- connection and both are already taken (AutoAim holds CameraModHandle, Combat/Camera holds
-- CameraPostHandle), so a third connect throws "illegal private event access" outside
-- Studio. RenderPriority.Camera + 9 lands just before the game snapshots the CFrame it
-- treats as authoritative at +10, so a write here persists instead of being reverted a
-- frame later the way a write at +11 would be.
local STEP = "ZegionSniperAim"
local stepBound = false

local function onRender(dt)
	local now = os.clock()
	if now - lastBuild >= ESP_REFRESH then
		lastBuild = now
		-- A dead character or a mid-respawn registry throws rather than returning empty,
		-- and an ESP that dies on your own death is an ESP that is off for most of a round.
		pcall(build)
	end

	current = (aim.snap or aim.silent) and aim.engaged and pick() or nil

	if aim.snap and current then
		local cf = Camera.CFrame
		local goal = CFrame.lookAt(cf.Position, aimPointOf(current))
		Camera.CFrame = cf:Lerp(goal, math.clamp(AIM_SMOOTH * dt, 0, 1))
	end

	drawESP()
end

local function bindStep(on)
	if on and not stepBound then
		stepBound = true
		RunService:BindToRenderStep(STEP, Enum.RenderPriority.Camera.Value + 9, onRender)
	elseif not on and stepBound then
		stepBound = false
		pcall(function()
			RunService:UnbindFromRenderStep(STEP)
		end)
	end
end

local function anythingOn()
	return esp.on or aim.assist or aim.snap or aim.silent
end

local function sync()
	screen.Enabled = esp.on
	bindStep(anythingOn())
	if not anythingOn() then
		targets = {}
		drawESP()
	end
end

-- keys -----------------------------------------------------------------------
-- Aim is ARMED in the panel and LIVE only while the key is down. An always-on aimbot is
-- both worse to play with and the thing a spectator notices; a panel toggle you have to
-- free the mouse to reach is useless mid-fight.
local function keyHeld()
	if typeof(AIM_KEY) == "EnumItem" and AIM_KEY.EnumType == Enum.UserInputType then
		return UserInputService:IsMouseButtonPressed(AIM_KEY)
	end
	return UserInputService:IsKeyDown(AIM_KEY)
end

local function keyMatches(input)
	return input.UserInputType == AIM_KEY or input.KeyCode == AIM_KEY
end

-- The game re-locks the cursor to centre on a one-second loop whenever you're alive and in
-- a round (Camera.lua's updateMouseBehavior), so the panel is unclickable mid-match without
-- this. PauseMouse is keyed, so it composes with the game's own callers instead of fighting
-- them, and it frees the cursor WITHOUT pausing combat -- toggles keep working, loops keep
-- running. It stays OFF at launch: a free cursor is exactly what stops the camera following
-- the mouse, so grabbing it on open would leave you unable to turn.
local mousePaused = false
local function pauseMouse(on)
	if on == mousePaused then
		return
	end
	mousePaused = on
	pcall(function()
		if on then
			M.GameController.PauseMouse("Zegion")
		else
			M.GameController.ResumeMouse("Zegion")
		end
	end)
end

local stopAll -- forward declaration; the panic key and the teardown share one path

-- Held state is POLLED, not latched off InputBegan/InputEnded. A latch desyncs the moment
-- the window loses focus mid-hold -- Roblox never sends the InputEnded -- and leaves aim
-- stuck on with no obvious way to notice.
local heartbeat = RunService.Heartbeat:Connect(function()
	if AIM_HOLD then
		local held = keyHeld()
		if held ~= aim.engaged then
			aim.engaged = held
			if aim.assist then
				liveAssist(held) -- Assist is a setting, so it toggles with the key like the rest
			end
		end
	else
		aim.engaged = aim.latched
	end
end)

-- gameProcessedEvent is NOT filtered here on purpose: right mouse is this game's ADS, so
-- the engine reports every press of the default aim key as already-processed and the usual
-- `if gameProcessed then return end` guard would drop all of them.
local inputConn = UserInputService.InputBegan:Connect(function(input)
	if input.KeyCode == PANIC_KEY then
		stopAll()
		return
	end
	if input.KeyCode == MOUSE_KEY then
		pauseMouse(not mousePaused)
		return
	end
	if not AIM_HOLD and keyMatches(input) then
		aim.latched = not aim.latched
		if aim.assist then
			liveAssist(aim.latched)
		end
	end
end)

-- gui ------------------------------------------------------------------------
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a restyle
-- is one file and not eighteen. Fetched here rather than installed by the loader, so this
-- file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Sniper Arena", -- fallback until the live name lands
	folder = "SniperArena", -- unchanged: renaming it orphans configs already saved in-game
	size = UDim2.fromOffset(460, 420),
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:scope-bold" })
local EspSec = Tab:Section({ Title = "ESP", Icon = "solar:eye-bold", Box = true, BoxBorder = true, Opened = true })
local AimSec = Tab:Section({ Title = "Aim", Icon = "solar:target-bold", Box = true, BoxBorder = true, Opened = true })
local KeySec = Tab:Section({ Title = "Keys", Icon = "solar:keyboard-bold", Box = true, BoxBorder = true, Opened = true })

EspSec:Toggle({
	Title = "ESP",
	Desc = "Box, name and health bar over every live enemy",
	Value = false,
	Callback = function(v)
		esp.on = v
		sync()
	end,
})
EspSec:Toggle({ Title = "Box", Value = true, Callback = function(v)
	esp.box = v
end })
EspSec:Toggle({ Title = "Name + distance", Value = true, Callback = function(v)
	esp.name = v
end })
EspSec:Toggle({ Title = "Health bar", Value = true, Callback = function(v)
	esp.health = v
end })
EspSec:Toggle({
	Title = "Show bots",
	Desc = "Most of a server here is bots -- off leaves only real players drawn",
	Value = true,
	Callback = function(v)
		esp.bots = v
	end,
})

-- The three aim modes all drive the same camera, so they push each other off rather than
-- stacking. Set(v, false) suppresses the callback -- without the second argument the two
-- toggles would bounce each other back on.
local tAssist, tSnap, tSilent

local function exclusive(keep)
	if keep ~= "assist" and aim.assist then
		aim.assist = false
		armAssist(false)
		pcall(function()
			tAssist:Set(false, false)
		end)
	end
	if keep ~= "snap" and aim.snap then
		aim.snap = false
		pcall(function()
			tSnap:Set(false, false)
		end)
	end
end

tAssist = AimSec:Toggle({
	Title = "Aim: Assist",
	Desc = "The game's own aim assist, unlocked on PC and turned up. Smoothest, quietest.",
	Value = false,
	Callback = function(v)
		aim.assist = v
		if v then
			exclusive("assist")
		end
		armAssist(v)
		liveAssist(v and aim.engaged)
		sync()
	end,
})

tSnap = AimSec:Toggle({
	Title = "Aim: Snap",
	Desc = "Steers the camera to the head while the key is held. Obvious to spectators.",
	Value = false,
	Callback = function(v)
		aim.snap = v
		if v then
			exclusive("snap")
		end
		sync()
	end,
})

tSilent = AimSec:Toggle({
	Title = "Aim: Silent (unproven)",
	Desc = "Rewrites the shot instead of moving the camera. Run the probe before trusting it.",
	Value = false,
	Callback = function(v)
		aim.silent = v
		setSilent(v)
		sync()
	end,
})

AimSec:Toggle({
	Title = "Head",
	Desc = "Aim at the head -- also what makes the server score it as a headshot",
	Value = AIM_HEAD,
	Callback = function(v)
		AIM_HEAD = v
	end,
})
AimSec:Toggle({
	Title = "Wall check",
	Desc = "Refuse targets you have no line of sight to",
	Value = AIM_WALLCHECK,
	Callback = function(v)
		AIM_WALLCHECK = v
	end,
})
AimSec:Input({
	Title = "FOV (degrees)",
	Value = tostring(AIM_FOV),
	Placeholder = "12",
	Callback = function(v)
		AIM_FOV = math.clamp(tonumber(v) or AIM_FOV, 1, 180)
	end,
})
AimSec:Input({
	Title = "Smoothing",
	Desc = "Snap mode only. 4 is a drag, 12 firm, 40 a teleport.",
	Value = tostring(AIM_SMOOTH),
	Placeholder = "12",
	Callback = function(v)
		AIM_SMOOTH = math.clamp(tonumber(v) or AIM_SMOOTH, 1, 100)
	end,
})

local KEYS = {
	["Right Mouse (ADS)"] = Enum.UserInputType.MouseButton2,
	["Left Mouse"] = Enum.UserInputType.MouseButton1,
	["Middle Mouse"] = Enum.UserInputType.MouseButton3,
	["C"] = Enum.KeyCode.C,
	["V"] = Enum.KeyCode.V,
	["Left Alt"] = Enum.KeyCode.LeftAlt,
}
local keyNames = {}
for name in pairs(KEYS) do
	table.insert(keyNames, name)
end
table.sort(keyNames)

KeySec:Dropdown({
	Title = "Aim key",
	Values = keyNames,
	Value = "Right Mouse (ADS)",
	Callback = function(v)
		-- Refresh re-fires this with whatever the row still holds, "" included, so an
		-- unknown value is ignored rather than assigned.
		if KEYS[v] then
			AIM_KEY = KEYS[v]
			aim.latched = false
		end
	end,
})
KeySec:Toggle({
	Title = "Hold to aim",
	Desc = "Off = press once to latch on, press again for off",
	Value = AIM_HOLD,
	Callback = function(v)
		AIM_HOLD = v
		aim.latched = false
		aim.engaged = false
		liveAssist(false)
	end,
})
KeySec:Button({
	Title = "Free / lock cursor (RightShift)",
	Desc = "The game re-locks the mouse every second; this is how you reach the panel",
	Callback = function()
		pauseMouse(not mousePaused)
	end,
})
KeySec:Button({
	Title = "Panic (End)",
	Desc = "Every feature off at once, same path as the teardown",
	Callback = function()
		stopAll()
	end,
})

-- close ----------------------------------------------------------------------
-- Restoring matters more here than in a farm script: three of these hooks outlive the
-- panel. A stale IsKeyboard leaves the game's aim assist on forever, a stale LocalShoot
-- rewrites every shot you fire by hand, and a settings write that never gets reverted
-- follows you into your next session.
stopAll = function()
	esp.on, aim.assist, aim.snap, aim.silent = false, false, false, false
	aim.engaged, aim.latched = false, false
	armAssist(false)
	setSilent(false)
	M.InputHelper.IsKeyboard = realIsKeyboard
	restoreSettings()
	bindStep(false)
	pauseMouse(false)
	screen.Enabled = false
	drawESP()
	-- Named one at a time rather than looped over a literal: any of these is nil if WindUI
	-- handed back nothing, and ipairs over a hole stops early -- which would leave the rows
	-- after the gap lit while their features are off.
	local function unlit(row)
		if row then
			pcall(function()
				row:Set(false, false) -- second arg suppresses the callback, so this can't re-arm
			end)
		end
	end
	unlit(tAssist)
	unlit(tSnap)
	unlit(tSilent)
	print("[sniper] everything off")
end

local function teardown()
	stopAll()
	pcall(function()
		heartbeat:Disconnect()
	end)
	pcall(function()
		inputConn:Disconnect()
	end)
	pcall(function()
		screen:Destroy()
	end)
end

Window:OnDestroy(function()
	teardown()
	getgenv().sniperArenaStop = nil
end)

getgenv().sniperArenaStop = function()
	teardown()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().sniperArenaStop = nil
end
