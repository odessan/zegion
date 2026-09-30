--[[ Zegion panel (Obsidian) -- the same idea as panel.lua, for scripts that want the
     Obsidian look instead of WindUI. Loads Zegion's fork of Obsidian (obsidian/Library.lua).

     local panel = loadstring(game:HttpGet(PANEL_URL))()
     local Window, Library = panel({ game = "TP for Brainrots", size = UDim2.fromOffset(480, 320) })
     if not Window then return end

     Rows are Obsidian's own API, not WindUI's: Window:AddTab -> Tab:AddLeftGroupbox ->
     Groupbox:AddToggle("Idx", {Text, Default, Callback}). Nothing here translates between
     the two -- the callback timing and Set() re-entrancy differ, so an adapter would only
     hide a second set of quirks. panel.lua and every WindUI script are untouched.

     Open and close, the same on every platform:
       "-" button       top-left of the window: closes it (loops keep running)
       floating logo    a 56px draggable button, right edge, middle of the screen. It is on
                        screen only while the window is closed; tap it to open the window
       RightControl     the same toggle from a keyboard
     Obsidian's own mobile Toggle/Lock buttons are turned off -- the logo replaces them.
     A window with a single tab hides its sidebar; a second tab brings it back as a 56px
     icon rail. Window:AddSettingsTab("Folder", { "IdxToNotSave" }) adds a Settings tab with
     the config manager (see "settings" below).
     Stop:  Library:Unload() -- runs every Library:OnUnload callback, then destroys the UI. ]]

-- brand ----------------------------------------------------------------------
local BRAND = "Zegion"
local KEY = Enum.KeyCode.RightControl -- open / close, same as the buttons
local DISPLAY_ORDER = 2147483643 -- Obsidian ships at 998, under the Esc menu's own screens
local MIN_WIDTH = 480 -- narrower and the title holder has no room for the two title-bar controls

-- Everything look-shaped lives here, so a restyle is one block. Warm charcoal with one
-- vermilion signal colour: an "on" toggle is the only saturated thing on screen. Swap
-- AccentColor alone for another signal (the design canvas tried #d8ff4f, #5cd1c4, #e8e3d8).
local PALETTE = {
	BackgroundColor = Color3.fromRGB(14, 13, 12), -- the ground
	MainColor = Color3.fromRGB(23, 22, 19), -- rows and groupboxes, one step up from the ground
	OutlineColor = Color3.fromRGB(46, 43, 37), -- borders visible without shouting
	AccentColor = Color3.fromRGB(255, 106, 61), -- toggles, tab underline, hover ring, the logo
	FontColor = Color3.fromRGB(236, 231, 221), -- warm off-white
}
local FONT = Enum.Font.RobotoMono -- Jura was tried and dropped: thin, squared strokes turn to mush at 11-14px. Obsidian's own default is Code
local RADIUS = 8 -- Obsidian ships 4; rows, boxes and buttons all follow it
local ICON = "zap" -- lucide's bolt: only the stand-in when the logo image cannot load

-- logo -----------------------------------------------------------------------
-- logo.png is a white mark on transparent, so ImageLabel.ImageColor3 tints it to whatever
-- AccentColor is. Executors cannot upload to Roblox, so the file is fetched once, written
-- next to the workspace and read back with getcustomasset; any missing piece falls back to
-- a lucide bolt, then to a plain "Z", so the buttons always exist.
local LOGO_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/logo.png"
local LOGO_DIR = "Zegion"
local LOGO_FILE = LOGO_DIR .. "/logo_v1.png" -- bump the suffix when logo.png changes, or the old copy is kept
local BUBBLE = 56 -- floating button; 44 is the touch-target floor, 56 reads on a phone
local BUBBLE_MARGIN = 12 -- gap to the right edge of the screen
local DRAG_SLOP = 8 -- px a press may wander and still count as a tap
local MIN_BTN = 24 -- title-bar "-" button
local MARK = 20 -- title-bar logo mark
local BAR_PAD = 66 -- room both take off the left of the title holder: 8 + 24 + 8 + 20 + 6
local BAR_H = 48 -- Obsidian's title bar height, hardcoded in CreateWindow
local RAIL_W = 56 -- the icon-only sidebar a window gets once it has two tabs

local function logoAsset()
	if not (writefile and isfile and getcustomasset and makefolder and isfolder) then
		return nil
	end
	local ok, asset = pcall(function()
		if not isfolder(LOGO_DIR) then
			makefolder(LOGO_DIR)
		end
		if not isfile(LOGO_FILE) then
			local png = game:HttpGet(LOGO_URL)
			if type(png) ~= "string" or png:sub(2, 4) ~= "PNG" then
				error("logo.png did not come back as a PNG")
			end
			writefile(LOGO_FILE, png)
		end
		return getcustomasset(LOGO_FILE)
	end)
	return ok and asset or nil
end

-- Draws the mark into `btn` (a TextButton or TextLabel), whichever form is available.
local function drawMark(Library, btn, px, asset, fallbackSize)
	local scheme = Library.Scheme
	if asset then
		local img = Instance.new("ImageLabel")
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.Position = UDim2.fromScale(0.5, 0.5)
		img.Size = UDim2.fromOffset(px, px)
		img.BackgroundTransparency = 1
		img.Image = asset
		img.ImageColor3 = scheme.AccentColor
		img.Parent = btn
		return
	end
	local glyph = Library:GetIcon(ICON)
	if glyph then
		local img = Instance.new("ImageLabel")
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.Position = UDim2.fromScale(0.5, 0.5)
		img.Size = UDim2.fromOffset(px * 0.7, px * 0.7)
		img.BackgroundTransparency = 1
		img.ImageColor3 = scheme.AccentColor
		Library:ApplyLucideIcon(img, glyph)
		img.Parent = btn
	else
		btn.Text = "Z"
		btn.TextColor3 = scheme.AccentColor
		btn.TextSize = fallbackSize
		btn.Font = Enum.Font.Code
	end
end

-- Floating logo. Own press/drag handling rather than Obsidian's AddDraggableButton: that one
-- decides "tap" from the pointer's state at release and felt dead here. A press that moves
-- more than DRAG_SLOP drags the button; one that does not, opens the window on release.
-- Hidden while the window is open -- the window has its own "-".
local function installBubble(Library, asset)
	local UserInputService = game:GetService("UserInputService")
	local RunService = game:GetService("RunService")

	local view = Library.ScreenGui.AbsoluteSize
	if view.X < 100 or view.Y < 100 then
		view = workspace.CurrentCamera.ViewportSize
	end

	local btn = Instance.new("TextButton")
	btn.Name = "LogoBubble"
	btn.Size = UDim2.fromOffset(BUBBLE, BUBBLE)
	btn.Position = UDim2.fromOffset(view.X - BUBBLE - BUBBLE_MARGIN, (view.Y - BUBBLE) / 2)
	btn.BackgroundColor3 = Library.Scheme.BackgroundColor
	btn.AutoButtonColor = false
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.Visible = false -- the Heartbeat below shows it once the window is closed
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0, RADIUS + 6)
	round.Parent = btn
	local ring = Instance.new("UIStroke")
	ring.Color = Library.Scheme.OutlineColor
	ring.Parent = btn
	drawMark(Library, btn, BUBBLE - 20, asset, 30)
	btn.Parent = Library.Floats

	local pressed, from, origin, moved
	btn.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			pressed, from, origin, moved = t, input.Position, btn.Position, false
		end
	end)
	Library:GiveSignal(UserInputService.InputChanged:Connect(function(input)
		if not pressed then
			return
		end
		local t = input.UserInputType
		if t ~= Enum.UserInputType.MouseMovement and t ~= pressed then
			return
		end
		local d = input.Position - from
		if not moved and math.sqrt(d.X * d.X + d.Y * d.Y) <= DRAG_SLOP then
			return
		end
		moved = true
		local size = Library.ScreenGui.AbsoluteSize
		btn.Position = UDim2.fromOffset(
			math.clamp(origin.X.Offset + d.X, 0, math.max(0, size.X - BUBBLE)),
			math.clamp(origin.Y.Offset + d.Y, 0, math.max(0, size.Y - BUBBLE))
		)
	end))
	Library:GiveSignal(UserInputService.InputEnded:Connect(function(input)
		if not pressed or input.UserInputType ~= pressed then
			return
		end
		local wasDrag = moved
		pressed = nil
		if not wasDrag then
			Library:Toggle(true)
		end
	end))

	-- Heartbeat, not a task loop: a resumed thread lacks the capability to write the hidden GUI.
	Library:GiveSignal(RunService.Heartbeat:Connect(function()
		local want = not Library.Toggled
		if btn.Visible ~= want then
			btn.Visible = want
		end
	end))
end

-- Title-bar controls: a "-" button that closes the window, and the logo mark beside it.
-- Obsidian doesn't expose its title bar, so it is found by shape: the 48px-tall, full-width,
-- transparent Frame directly under MainFrame; its title holder is whichever child carries
-- the TextLabel reading BRAND.
local function installTitleControls(Library, Window, asset)
	local topbar, label
	for _, c in ipairs(Window.MainFrame:GetChildren()) do
		if c:IsA("Frame") and c.BackgroundTransparency == 1 and c.Size == UDim2.new(1, 0, 0, BAR_H) then
			topbar = c
			break
		end
	end
	for _, d in ipairs(topbar and topbar:GetDescendants() or {}) do
		if d:IsA("TextLabel") and d.Text == BRAND then
			label = d
			break
		end
	end
	local holder = label and label.Parent
	if not holder then
		warn("[zegion] Obsidian's title bar changed shape -- no title-bar controls. RightControl still closes.")
		return
	end

	-- Make room on the left; the holder centres its content in what's left.
	holder.Position = UDim2.fromOffset(BAR_PAD, 0)
	holder.Size = UDim2.new(0, holder.Size.X.Offset - BAR_PAD, 1, 0)

	local scheme = Library.Scheme
	local btn = Instance.new("TextButton")
	btn.Name = "Minimize"
	btn.AnchorPoint = Vector2.new(0, 0.5)
	btn.Position = UDim2.new(0, 8, 0.5, 0)
	btn.Size = UDim2.fromOffset(MIN_BTN, MIN_BTN)
	btn.BackgroundColor3 = scheme.MainColor
	btn.AutoButtonColor = false
	btn.BorderSizePixel = 0
	btn.Text = ""
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0, RADIUS / 2)
	round.Parent = btn
	local ring = Instance.new("UIStroke")
	ring.Color = scheme.OutlineColor
	ring.Parent = btn
	local glyph = Library:GetIcon("minus")
	if glyph then
		local img = Instance.new("ImageLabel")
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.Position = UDim2.fromScale(0.5, 0.5)
		img.Size = UDim2.fromOffset(MIN_BTN - 8, MIN_BTN - 8)
		img.BackgroundTransparency = 1
		img.ImageColor3 = scheme.FontColor
		Library:ApplyLucideIcon(img, glyph)
		img.Parent = btn
	else
		btn.Text = "-" -- icon pack unavailable: a plain dash still does the job
		btn.TextColor3 = scheme.FontColor
		btn.TextSize = 16
		btn.Font = Enum.Font.Code
	end
	btn.MouseEnter:Connect(function()
		ring.Color = scheme.AccentColor
	end)
	btn.MouseLeave:Connect(function()
		ring.Color = scheme.OutlineColor
	end)
	btn.MouseButton1Click:Connect(function()
		Library:Toggle(false)
	end)
	btn.Parent = topbar

	local mark = Instance.new("TextLabel")
	mark.Name = "Mark"
	mark.AnchorPoint = Vector2.new(0, 0.5)
	mark.Position = UDim2.new(0, 8 + MIN_BTN + 8, 0.5, 0)
	mark.Size = UDim2.fromOffset(MARK, MARK)
	mark.BackgroundTransparency = 1
	mark.Text = ""
	drawMark(Library, mark, MARK, asset, 16)
	mark.Parent = topbar
end

-- settings -------------------------------------------------------------------
-- Window:AddSettingsTab(folder, ignore) -- a "Settings" tab with Obsidian's config manager
-- (SaveManager): name, save, load, delete, autoload, import/export. Call it once, AFTER the
-- script has built the rest of its UI, because the autoload runs at the end of it and a
-- config can only restore controls that already exist. `folder` names the per-game config
-- folder under workspace/Zegion/. `ignore` lists Idx values that must not be saved, e.g. a
-- master switch, whose restore would flip everything else a second time.
--
-- Loading a config fires every control's callback, so a saved "Auto Click = on" starts
-- the loop. That is the point, and it is why autoload is something the user sets on
-- purpose: nothing loads until a config is marked autoload.
--
-- ponytail: SaveManager comes from upstream, unforked. Its load makes an empty
-- ObsidianLibSettings folder in workspace as a side effect; fork the file if that bothers you.
local SAVE_URL = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/addons/SaveManager.lua"
local SCALES = { "80%", "90%", "100%", "110%", "120%" }

local function addSettingsTab(Library, Window, folder, ignore, keyName)
	local ok, SaveManager = pcall(function()
		local src = game:HttpGet(SAVE_URL)
		if type(src) ~= "string" or #src < 1000 then
			error("empty response from raw.githubusercontent (rate limit)")
		end
		return assert(loadstring(src))()
	end)
	if not ok then
		warn("[zegion] SaveManager would not load (" .. tostring(SaveManager) .. ") -- no Settings tab.")
		return
	end

	SaveManager:SetLibrary(Library)
	SaveManager:IgnoreThemeSettings()
	SaveManager:SetFolder("Zegion/" .. folder)
	local skip = { "ZegionScale" }
	for _, idx in ipairs(ignore or {}) do
		skip[#skip + 1] = idx
	end
	SaveManager:SetIgnoreIndexes(skip)

	local Tab = Window:AddTab("Settings", "settings")
	local Interface = Tab:AddLeftGroupbox("Interface")
	Interface:AddDropdown("ZegionScale", {
		Text = "Scale",
		Values = SCALES,
		Default = "100%",
		Callback = function(v)
			pcall(function()
				Library:SetDPIScale(tonumber(tostring(v):match("%d+")))
			end)
		end,
	})
	Interface:AddLabel("Open and close: " .. keyName, true)

	SaveManager:BuildConfigSection(Tab)
	SaveManager:LoadAutoloadConfig()
end

-- library --------------------------------------------------------------------
-- Obsidian keeps ONE ScreenGui and publishes itself as getgenv().Library, and a second
-- load does not unload the first -- two windows stack. So unload whatever is there before
-- fetching, and never cache: the library owns its own teardown, so a cached copy would be
-- one that Unload() had already gutted.
-- Zegion's fork (obsidian/Library.lua, edits marked FORK(zegion)), not deividcomsono's upstream.
local LIB_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/obsidian/Library.lua"

local function loadObsidian()
	local env = getgenv and getgenv() or {}
	local old = env.Library
	if old and old.Unload then
		pcall(function()
			old:Unload()
		end)
	end
	if not game:IsLoaded() then
		game.Loaded:Wait() -- HttpGet during the join is flaky; don't burn tries on it
	end

	local last
	for attempt = 1, 5 do
		local ok, lib = pcall(function()
			local src = game:HttpGet(LIB_URL)
			if type(src) ~= "string" or #src < 1000 then
				error("empty response from raw.githubusercontent (rate limit)")
			end
			return assert(loadstring(src))()
		end)
		if ok and lib then
			return lib
		end
		last = tostring(lib)
		warn(("[zegion] Obsidian load %d/5 failed: %s"):format(attempt, last))
		task.wait(2 * attempt)
	end
	return nil, last
end

-- panel ----------------------------------------------------------------------
-- opts.game  the footer, until the live name lands (required)
-- opts.size  window size, default 480x320; never narrower than 480
-- opts.key   open / close key, default RightControl
-- opts.statusBar  true reserves the 36px status strip; then Window:SetStatus({ {"Zone", 4}, ... })
--                 and Window:SetStatusAction("Unload", fn, true) fill it. Off by default: an
--                 empty strip is 36px of nothing
-- opts.scale UI scale, e.g. 0.9; default is Obsidian's own 100%
local function panel(opts)
	local Library, why = loadObsidian()
	if not Library then
		warn("[zegion] Obsidian would not load (" .. tostring(why) .. ") -- no panel, nothing started.")
		return nil
	end

	-- Palette first: elements read the scheme when they're built, so anything created by
	-- CreateWindow already comes out in it. The registry pass afterwards catches what
	-- Obsidian built at load (floats, tooltips, notifications).
	for key, color in pairs(PALETTE) do
		Library.Scheme[key] = color
	end

	local asset = logoAsset()

	local size = opts.size or UDim2.fromOffset(MIN_WIDTH, 320)
	local Window = Library:CreateWindow({
		Title = BRAND,
		Footer = opts.game,
		Size = UDim2.fromOffset(math.max(size.X.Offset, MIN_WIDTH), size.Y.Offset),
		Font = FONT,
		CornerRadius = RADIUS,
		Center = true,
		AutoShow = true,
		Resizable = true,
		AlwaysOnTop = true, -- OnTopOfCoreBlur, or the Esc menu's blur frosts the panel
		ShowCustomCursor = false, -- Obsidian hides the Roblox cursor and draws a "+" crosshair while the window is open
		StatusBar = opts.statusBar == true, -- fork: the strip under the title bar; Window:SetStatus / SetStatusAction fill it
		ShowMobileButtons = false, -- its Toggle/Lock buttons; the floating logo replaces them
		ToggleKeybind = opts.key or KEY,
		NotifySide = "Right",
	})
	if not Window then
		warn("[zegion] Obsidian refused to open a window. Nothing started.")
		return nil
	end

	pcall(function()
		Library.ScreenGui.DisplayOrder = DISPLAY_ORDER
	end)

	Library:UpdateColorsUsingRegistry()

	-- Obsidian's own 100% unless a script asks. SetDPIScale takes a percent and rescales
	-- every UIScale it owns, so the window, rows, text and dropdowns move together and Size
	-- offsets stay in unscaled pixels.
	if opts.scale then
		pcall(function()
			Library:SetDPIScale(opts.scale * 100)
		end)
	end

	-- Sidebar (fork): one tab needs none. Counted as the script adds tabs, so a second tab
	-- brings it back without the script knowing.
	local tabs, addTab = 0, Window.AddTab
	Window.AddTab = function(self, ...)
		local tab = addTab(self, ...)
		tabs += 1
		if tabs < 2 then
			Window:SetSidebarHidden(true)
		else
			Window:SetSidebarRail(RAIL_W)
		end
		return tab
	end
	Window.AddSettingsTab = function(_, folder, ignore)
		addSettingsTab(Library, Window, folder, ignore, (opts.key or KEY).Name)
	end

	installTitleControls(Library, Window, asset)
	installBubble(Library, asset)

	-- The live name, after the window exists: GetProductInfo yields, and rate-limited or
	-- dead it costs nothing but the fallback footer.
	task.spawn(function()
		local ok, info = pcall(function()
			return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
		end)
		if ok and info and info.Name then
			pcall(function()
				Window:SetFooter(info.Name)
			end)
		end
	end)

	return Window, Library
end

-- ponytail: deliberately not cached, for the same reason panel.lua isn't -- edit, re-paste,
-- and the old copy would silently run.
return panel
