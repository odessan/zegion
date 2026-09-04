--[[ Flash -- auto dash/warp spam

     Fires the DashEvent sequence on a loop: StartCharge -> charge time -> EndWarp
     -> ClearDash.  SKIP_OPEN also cuts the end-of-dash reveal (the lucky block
     "opening"), so a manual dash ends the instant the server says so.

     Executor: paste and run.  Studio: LocalScript in StarterPlayerScripts.
     G or the FLASH button toggles. Stop: getgenv().flashStop() ]]

-- config ---------------------------------------------------------------------
local KEY_TOGGLE = Enum.KeyCode.G
-- ponytail: the two knobs. CHARGE is the value the real client sends as its charge
-- time, and we actually wait that long -- the server times the charge itself, so
-- reporting a duration you didn't spend is the obvious way to get flagged. GAP is
-- the dash cooldown; too low and EndWarp lands on a dash the server hasn't cleared.
local CHARGE = 0.092025542631745
local GAP = 0.6
-- The dash visuals are all client-side (DashClient). The one that costs time is the
-- CameraResetEvent EndWarp handler -- it clones VFX.portal, tweens your root and the
-- camera into it, plays Tackle and waits ~1.1s before handing control back. That is
-- the "opening". It can't just be switched off, because it's also what un-hijacks
-- the camera and fires ClearDash, so we replace it with the reset it ends on.
-- DestructionEvent (20 debris parts per wall) goes with it -- pure decoration.
-- ponytail: needs getconnections; without it this is a no-op and the cutscene stays.
-- flashStop() restores the originals.
local SKIP_OPEN = true

-- setup ----------------------------------------------------------------------
if getgenv and getgenv().flashStop then
	getgenv().flashStop()
end

local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local Event = RS:WaitForChild("DashEvent")
local player = game:GetService("Players").LocalPlayer

-- skip open ------------------------------------------------------------------
-- resetWalkSpeed() in DashClient: these VFX run at 48, everything else at 32.
local FAST_VFX = {
	Starlight = true,
	Superflash = true,
	Firestorm = true,
	Cyroflash = true,
	Stormflash = true,
	Saberflash = true,
	Electflash = true,
	Galaxyflash = true,
}

-- toggleGameplayUI(false) parks the hotbar offscreen at charge time and stashes each
-- element's old spot in an OriginalPos attribute. Nothing else writes that attribute,
-- so putting every one of them back is the whole restore.
local function showHUD()
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end
	for _, v in ipairs(playerGui:GetDescendants()) do
		if v:IsA("GuiObject") then
			local orig = v:GetAttribute("OriginalPos")
			if orig then
				v.Position = orig
			end
		end
	end
	pcall(function()
		local purse = require(RS:WaitForChild("Purse", 2))
		if purse and purse.SetEnabled then
			purse.SetEnabled(true)
		end
	end)
end

-- Every branch of the original handler -- EndWarp, ForceStopDash, NormalReset,
-- RaidEnded -- converges on this same reset, so one path covers all of them.
local function endDashNow(_kind, serverClears)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return
	end

	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Custom
	cam.CameraSubject = hum
	cam.FieldOfView = 70

	hum.AutoRotate = true
	hum.JumpPower = 50
	hum.WalkSpeed = FAST_VFX[char:GetAttribute("EquippedVFX")] and 48 or 32
	hum:Move(Vector3.new(0, 0, 0))

	local animator = hum:FindFirstChildOfClass("Animator")
	if animator then
		for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
			track:Stop(0)
		end
	end

	showHUD()

	-- The original fires this 0.65s in, and skips it when the server says it clears
	-- the dash itself. Miss it and the server leaves you mid-dash.
	if not serverClears then
		Event:FireServer("ClearDash")
	end
end

local killed = {} -- originals we switched off, so flashStop can put them back
local ours = nil -- our replacement handler
local function skipOpen(enable)
	if not getconnections then
		return false
	end
	if enable then
		for _, name in ipairs({ "CameraResetEvent", "DestructionEvent" }) do
			local remote = RS:FindFirstChild(name)
			if remote then
				for _, c in ipairs(getconnections(remote.OnClientEvent)) do
					c:Disable()
					table.insert(killed, c)
				end
			end
		end
		ours = RS.CameraResetEvent.OnClientEvent:Connect(endDashNow)
	else
		if ours then
			ours:Disconnect()
			ours = nil
		end
		for _, c in ipairs(killed) do
			pcall(function()
				c:Enable()
			end)
		end
		table.clear(killed)
	end
	return true
end

local running = true -- flipped by flashStop
local on = false -- the toggle

-- loop -----------------------------------------------------------------------
task.spawn(function()
	while running do
		if on then
			-- pcall: a kick/teleport mid-sequence invalidates the remote, and an
			-- error here kills the loop for the rest of the session.
			pcall(function()
				Event:FireServer("StartCharge")
				task.wait(CHARGE)
				Event:FireServer(CHARGE)
				Event:FireServer("EndWarp")
				Event:FireServer("ClearDash")
			end)
			task.wait(GAP)
		else
			task.wait(0.1)
		end
	end
end)

-- ui -------------------------------------------------------------------------
local BG = Color3.fromRGB(20, 21, 28)
local ROW = Color3.fromRGB(35, 38, 50)
local ON_C = Color3.fromRGB(52, 168, 110)
local TXT = Color3.fromRGB(232, 234, 245)
local MUTED = Color3.fromRGB(122, 127, 146)
local ACCENT = Color3.fromRGB(124, 92, 255)
local ACCENT2 = Color3.fromRGB(0, 210, 255)
local W = 190

local gui = Instance.new("ScreenGui")
gui.Name = "FlashForBrainrots"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(W, 96)
panel.Position = UDim2.new(0.5, -W / 2, 0, 60)
panel.BackgroundColor3 = BG
panel.BorderSizePixel = 0
panel.Active = true
panel.Draggable = true -- ponytail: deprecated but one line; same as the other panels
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)

local stroke = Instance.new("UIStroke", panel)
stroke.Color = Color3.fromRGB(58, 62, 82)
stroke.Thickness = 1
stroke.Transparency = 0.3

local bar = Instance.new("Frame")
bar.Size = UDim2.new(1, -2, 0, 3)
bar.Position = UDim2.fromOffset(1, 1)
bar.BorderSizePixel = 0
bar.BackgroundColor3 = ACCENT
bar.Parent = panel
Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 3)
Instance.new("UIGradient", bar).Color = ColorSequence.new(ACCENT, ACCENT2)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -28, 0, 22)
title.Position = UDim2.fromOffset(14, 12)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextColor3 = TXT
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "FLASH"
title.Parent = panel

local hint = Instance.new("TextLabel")
hint.Size = UDim2.new(1, -28, 0, 14)
hint.Position = UDim2.fromOffset(14, 30)
hint.BackgroundTransparency = 1
hint.Font = Enum.Font.Gotham
hint.TextSize = 10
hint.TextColor3 = MUTED
hint.TextXAlignment = Enum.TextXAlignment.Left
hint.Text = KEY_TOGGLE.Name .. " also toggles"
hint.Parent = panel

local btn = Instance.new("TextButton")
btn.Size = UDim2.new(1, -28, 0, 30)
btn.Position = UDim2.fromOffset(14, 52)
btn.BackgroundColor3 = ROW
btn.BorderSizePixel = 0
btn.AutoButtonColor = false
btn.Font = Enum.Font.GothamBold
btn.TextSize = 12
btn.TextColor3 = TXT
btn.Text = "OFF"
btn.Parent = panel
Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)

-- One entry point for both the button and the key, so the label can never disagree
-- with what the loop is doing.
local function setOn(v)
	on = v
	btn.Text = v and "ON" or "OFF"
	btn.BackgroundColor3 = v and ON_C or ROW
end

btn.MouseButton1Click:Connect(function()
	setOn(not on)
end)

-- Held so the stop can drop it: teardown destroys the gui, and without this the key
-- still calls setOn against destroyed rows, one more handler per re-paste.
local keyConn = UIS.InputBegan:Connect(function(input, typing)
	if not typing and input.KeyCode == KEY_TOGGLE then
		setOn(not on)
	end
end)

if getgenv then
	getgenv().flashStop = function()
		running, on = false, false
		skipOpen(false)
		pcall(function()
			keyConn:Disconnect()
		end)
		pcall(function()
			gui:Destroy()
		end)
		getgenv().flashStop = nil -- or the next paste calls a stop for a destroyed gui
		print("[Flash] stopped")
	end
end

if SKIP_OPEN then
	print("[Flash] skip open:", skipOpen(true) and "on" or "no getconnections -- cutscene stays")
end

print("[Flash] loaded --", KEY_TOGGLE.Name, "or the button toggles")
