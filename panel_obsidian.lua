--[[ Zegion panel (Obsidian) -- the same idea as panel.lua, for scripts that want the
     Obsidian look instead of WindUI.

     local panel = loadstring(game:HttpGet(PANEL_URL))()
     local Window, Library = panel({ game = "TP for Brainrots", size = UDim2.fromOffset(440, 320) })
     if not Window then return end

     Rows are Obsidian's own API, not WindUI's: Window:AddTab -> Tab:AddLeftGroupbox ->
     Groupbox:AddToggle("Idx", {Text, Default, Callback}). Nothing here translates between
     the two -- the callback timing and Set() re-entrancy differ, so an adapter would only
     hide a second set of quirks. panel.lua and every WindUI script are untouched.

     Same controls as panel.lua:
       "-" button    (top-left of the title bar) or RightControl -- rolls the body up so the
                     window is just its title bar, where it stands; again to roll it down
       RightAlt      hides the window outright, for a screenshot (Obsidian's ToggleKeybind)
     Loops keep running under either one.
     Stop:  Library:Unload() -- runs every Library:OnUnload callback, then destroys the UI. ]]

-- brand ----------------------------------------------------------------------
local BRAND = "Zegion"
local KEY = Enum.KeyCode.RightControl -- shade
local HIDE_KEY = Enum.KeyCode.RightAlt -- hide outright
local DISPLAY_ORDER = 2147483643 -- Obsidian ships at 998, under the Esc menu's own screens
local SCALE = 0.9 -- panel.lua uses 0.8, but Obsidian's text is smaller to begin with (11-14px)

-- Everything look-shaped lives here, so a restyle is one block. Graphite: neutral greys
-- with a near-white accent, so an "on" toggle reads as bright-vs-dark with no hue to
-- clash with a game's own UI. Swap AccentColor alone for a coloured variant.
local PALETTE = {
	BackgroundColor = Color3.fromRGB(16, 16, 16), -- the ground
	MainColor = Color3.fromRGB(26, 26, 26), -- rows and groupboxes, one step up from the ground
	OutlineColor = Color3.fromRGB(46, 46, 46), -- borders visible without shouting
	AccentColor = Color3.fromRGB(229, 229, 229), -- toggles, tab underline, hover ring
	FontColor = Color3.fromRGB(242, 242, 242), -- a hair under pure white
}
local FONT = Enum.Font.RobotoMono -- Jura was tried and dropped: thin, squared strokes turn to mush at 11-14px. Obsidian's own default is Code
local RADIUS = 8 -- Obsidian ships 4; rows, boxes and buttons all follow it
local ICON = "zap" -- lucide's bolt; stands in for the WindUI bolt-circle mark

local LIB_URL = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/Library.lua"

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

-- shade ----------------------------------------------------------------------
-- Obsidian has no minimise, only hide. Rebuilt the way panel.lua does it: hide the body,
-- shrink the window to its title bar, and pin the TOP-LEFT so it collapses where it
-- stands (Obsidian anchors MainFrame at (0,0), so a plain Size change already does).
--
-- Obsidian doesn't expose its title bar, so it's found by shape: the 48px-tall,
-- full-width, transparent Frame directly under MainFrame; its title holder is whichever
-- child carries the TextLabel reading BRAND.
local SHADE_H = 48 -- Obsidian's title bar height, hardcoded in CreateWindow
local BTN = 20 -- shade button size
local BTN_PAD = 34 -- room the button takes off the left of the title holder
local SHADE_MIN = 120 -- never narrower than the button plus the title
local SHADE_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local function installShade(Library, Window, shadeKey)
	local main = Window.MainFrame
	local scale = main:FindFirstChildOfClass("UIScale")
	local topbar, label
	for _, c in ipairs(main:GetChildren()) do
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
	local layout = holder and holder:FindFirstChildOfClass("UIListLayout")
	if not (holder and layout) then
		warn("[zegion] Obsidian's title bar changed shape -- no shade button. RightAlt still hides.")
		return
	end

	-- Make room on the left for the button; the holder centres its content in what's left.
	holder.Position = UDim2.fromOffset(BTN_PAD, 0)
	holder.Size = UDim2.new(0, holder.Size.X.Offset - BTN_PAD, 1, 0)

	-- Dressed in Obsidian's own scheme (panel colour, outline, lucide "minus") rather than
	-- WindUI's yellow, so it reads as part of this window and follows its palette.
	local scheme = Library.Scheme
	local btn = Instance.new("TextButton")
	btn.Name = "Shade"
	btn.AnchorPoint = Vector2.new(0, 0.5)
	btn.Position = UDim2.new(0, 10, 0.5, 0)
	btn.Size = UDim2.fromOffset(BTN, BTN)
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
		img.Size = UDim2.fromOffset(BTN - 8, BTN - 8)
		img.BackgroundTransparency = 1
		img.ImageColor3 = scheme.FontColor
		Library:ApplyLucideIcon(img, glyph)
		img.Parent = btn
	else
		btn.Text = "-" -- icon pack unavailable: a plain dash still does the job
		btn.TextColor3 = scheme.FontColor
		btn.TextSize = 14
		btn.Font = Enum.Font.Code
	end
	btn.MouseEnter:Connect(function()
		ring.Color = scheme.AccentColor
	end)
	btn.MouseLeave:Connect(function()
		ring.Color = scheme.OutlineColor
	end)
	btn.Parent = topbar

	local shaded, fullSize, fullHolder = false, nil, holder.Size
	local hidden = {} -- only what WE hid, so a row Obsidian keeps invisible stays invisible
	local function toggle()
		if not main.Parent then
			return -- window was unloaded; the key handler outlives it by a frame
		end
		shaded = not shaded
		local to
		if shaded then
			fullSize = main.Size -- read live: a window the user resized comes back its own size
			for _, c in ipairs(main:GetChildren()) do
				if c:IsA("GuiObject") and c ~= topbar and c.Visible then
					c.Visible = false
					hidden[#hidden + 1] = c
				end
			end
			for _, c in ipairs(topbar:GetChildren()) do -- search box, move icon
				if c:IsA("GuiObject") and c ~= holder and c ~= btn and c.Visible then
					c.Visible = false
					hidden[#hidden + 1] = c
				end
			end
			-- AbsoluteContentSize is post-UIScale, Size offsets are pre-scale.
			local s = scale and scale.Scale > 0 and scale.Scale or 1
			to = UDim2.fromOffset(math.max(SHADE_MIN, BTN_PAD + layout.AbsoluteContentSize.X / s + 16), SHADE_H)
			-- The holder is 30% of the FULL width and centres its content, so left alone the
			-- title floats off to the right of a bar that is now much narrower than it.
			holder.Size = UDim2.new(0, to.X.Offset - BTN_PAD, 1, 0)
		else
			holder.Size = fullHolder
			for _, c in ipairs(hidden) do
				if c.Parent then
					c.Visible = true
				end
			end
			table.clear(hidden)
			to = fullSize
		end
		TweenService:Create(main, SHADE_TWEEN, { Size = to }):Play()
	end

	btn.MouseButton1Click:Connect(toggle)
	-- gameProcessed is the whole guard: the panel has a search box, and without it the key
	-- shades the window from under you while you're typing in it.
	Library:GiveSignal(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and input.KeyCode == shadeKey then
			toggle()
		end
	end))
end

-- library --------------------------------------------------------------------
-- Obsidian keeps ONE ScreenGui and publishes itself as getgenv().Library, and a second
-- load does not unload the first -- two windows stack. So unload whatever is there before
-- fetching, and never cache: the library owns its own teardown, so a cached copy would be
-- one that Unload() had already gutted.
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
-- opts.key      shade key, default RightControl
-- opts.hideKey  hide-outright key, default RightAlt
-- opts.scale    UI scale, default SCALE (0.9)
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

	-- The brand mark, only if the lucide pack answered: a window Icon that fails to
	-- resolve leaves an empty square beside the title.
	local icon = Library:GetIcon(ICON) and ICON or nil

	local Window = Library:CreateWindow({
		Title = BRAND,
		Icon = icon,
		IconSize = UDim2.fromOffset(18, 18), -- 30 default; the title holder is only ~98px wide
		Footer = opts.game,
		Size = opts.size or UDim2.fromOffset(440, 320),
		Font = FONT,
		CornerRadius = RADIUS,
		Center = true,
		AutoShow = true,
		Resizable = true,
		AlwaysOnTop = true, -- OnTopOfCoreBlur, or the Esc menu's blur frosts the panel
		ShowCustomCursor = false, -- Obsidian hides the Roblox cursor and draws a "+" crosshair while the window is open
		ToggleKeybind = opts.hideKey or HIDE_KEY,
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

	-- Obsidian's SetDPIScale takes a percent and rescales every UIScale it owns, so the
	-- window, rows, text and dropdowns shrink together and Size offsets stay in unscaled
	-- pixels -- same trade as panel.lua's SCALE. Before the shade, which reads it live.
	pcall(function()
		Library:SetDPIScale((opts.scale or SCALE) * 100)
	end)

	installShade(Library, Window, opts.key or KEY)

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
