--[[ Zegion panel (Obsidian) -- the same idea as panel.lua, for scripts that want the
     Obsidian look instead of WindUI.

     local panel = loadstring(game:HttpGet(PANEL_URL))()
     local Window, Library = panel({ game = "TP for Brainrots", size = UDim2.fromOffset(440, 320) })
     if not Window then return end

     Rows are Obsidian's own API, not WindUI's: Window:AddTab -> Tab:AddLeftGroupbox ->
     Groupbox:AddToggle("Idx", {Text, Default, Callback}). Nothing here translates between
     the two -- the callback timing and Set() re-entrancy differ, so an adapter would only
     hide a second set of quirks. panel.lua and every WindUI script are untouched.

     One control, on every platform: the Zegion logo.
       floating logo   a 56px draggable button that stays on screen whether the window is open
                       or not -- tap it to open, tap it again to close
       title-bar logo  the same mark at the window's top-left; also closes it
       RightControl    the same toggle from a keyboard
     Closing hides the window outright; loops keep running. Obsidian's own mobile Toggle/Lock
     buttons are turned off -- the logo replaces them.
     Stop:  Library:Unload() -- runs every Library:OnUnload callback, then destroys the UI. ]]

-- brand ----------------------------------------------------------------------
local BRAND = "Zegion"
local KEY = Enum.KeyCode.RightControl -- open / close, same as the logo
local DISPLAY_ORDER = 2147483643 -- Obsidian ships at 998, under the Esc menu's own screens

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
local BUBBLE_AT = UDim2.fromOffset(12, 120) -- under Roblox's own top-left buttons
local BAR_BTN = 32 -- title-bar logo
local BAR_BTN_PAD = 40 -- room it takes off the left of the title holder
local SHADE_H = 48 -- Obsidian's title bar height, hardcoded in CreateWindow

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

-- Draws the mark into `btn`, whichever of the three forms is available.
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

-- Floating button. Obsidian's AddDraggableButton already tells a tap from a drag (a click
-- only counts if the pointer moved 12px or less), so a thumb that nudges it while tapping
-- still opens the window. Excluded from UIScale: a touch target that shrinks with the
-- panel's scale stops being one.
local function installBubble(Library, asset)
	local drag = Library:AddDraggableButton("", function()
		Library:Toggle()
	end, true, true)
	local btn = drag.Button
	btn.Size = UDim2.fromOffset(BUBBLE, BUBBLE)
	btn.Position = BUBBLE_AT
	drawMark(Library, btn, BUBBLE - 20, asset, 30)
end

-- Title-bar logo. Obsidian doesn't expose its title bar, so it is found by shape: the
-- 48px-tall, full-width, transparent Frame directly under MainFrame; its title holder is
-- whichever child carries the TextLabel reading BRAND.
local function installTitleLogo(Library, Window, asset)
	local topbar, label
	for _, c in ipairs(Window.MainFrame:GetChildren()) do
		if c:IsA("Frame") and c.BackgroundTransparency == 1 and c.Size == UDim2.new(1, 0, 0, SHADE_H) then
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
		warn("[zegion] Obsidian's title bar changed shape -- no title logo. The floating logo still works.")
		return
	end

	-- Make room on the left for the button; the holder centres its content in what's left.
	holder.Position = UDim2.fromOffset(BAR_BTN_PAD, 0)
	holder.Size = UDim2.new(0, holder.Size.X.Offset - BAR_BTN_PAD, 1, 0)

	local btn = Instance.new("TextButton")
	btn.Name = "Logo"
	btn.AnchorPoint = Vector2.new(0, 0.5)
	btn.Position = UDim2.new(0, 4, 0.5, 0)
	btn.Size = UDim2.fromOffset(BAR_BTN, BAR_BTN)
	btn.BackgroundTransparency = 1
	btn.AutoButtonColor = false
	btn.BorderSizePixel = 0
	btn.Text = ""
	drawMark(Library, btn, BAR_BTN - 8, asset, 22)
	btn.MouseButton1Click:Connect(function()
		Library:Toggle()
	end)
	btn.Parent = topbar
end

-- library --------------------------------------------------------------------
-- Obsidian keeps ONE ScreenGui and publishes itself as getgenv().Library, and a second
-- load does not unload the first -- two windows stack. So unload whatever is there before
-- fetching, and never cache: the library owns its own teardown, so a cached copy would be
-- one that Unload() had already gutted.
local LIB_URL = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/Library.lua"

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
-- opts.size  window size, default 440x320
-- opts.key   open / close key, default RightControl
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

	local Window = Library:CreateWindow({
		Title = BRAND,
		Footer = opts.game,
		Size = opts.size or UDim2.fromOffset(440, 320),
		Font = FONT,
		CornerRadius = RADIUS,
		Center = true,
		AutoShow = true,
		Resizable = true,
		AlwaysOnTop = true, -- OnTopOfCoreBlur, or the Esc menu's blur frosts the panel
		ShowCustomCursor = false, -- Obsidian hides the Roblox cursor and draws a "+" crosshair while the window is open
		ShowMobileButtons = false, -- its Toggle/Lock buttons; the logo below replaces them
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

	installTitleLogo(Library, Window, asset)
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
-- and the old copy would silently run. Obsidian itself is still upstream, not forked: the
-- rail / flat-row layout from the design canvas is the change that needs Library.lua's
-- CreateWindow, and nothing above does.
return panel
