--[[ Zegion panel -- the shared chrome every game script builds its UI on.

     local panel = loadstring(game:HttpGet(PANEL_URL))()
     local Window, WindUI = panel({ game = "Wings for Brainrots", folder = "WingsRots" })
     if not Window then return end

     Everything brand-shaped lives in here and nowhere else: the topbar wording, the
     icon, the floating bubble, the topbar height, the live game name and the shade.
     Restyle once, every script picks it up the next time it's pasted.

     A script keeps its own Tabs, Sections and rows -- this only builds the window and
     hands it back. Each script fetches this itself rather than relying on the loader to
     install it, so every one of them still pastes and runs on its own.

     Keys:  RightControl  minimise / expand -- the body rolls up to a bare Zegion pill
            RightAlt      hide the window outright, for a screenshot

     Loops keep running under either one.

     The window is raised above the Roblox menu, so Esc no longer buries it -- see the
     "above" block for why that needs a reparent, a DisplayOrder and a blur flag rather
     than any one of the three. ]]

-- brand ----------------------------------------------------------------------
local BRAND = "Zegion"
local ICON = "solar:bolt-circle-bold" -- one mark for every script; verify names at api.iconify.design
local TOPBAR_H = 58 -- two stacked labels (16px over 13px); 44 is a one-line topbar and reads packed
-- The panel key rolls the body up and down -- minimise and expand, the Shade button on a
-- key. It used to hide the window outright, which is a bad default: WindUI only draws
-- its floating open button on touch devices, so on a PC the panel was simply GONE with
-- nothing left to click and no way back except re-pasting.
local KEY = Enum.KeyCode.RightControl
-- Hiding outright is still worth having -- for a screenshot, or to see what's under the
-- panel -- so it keeps a key, just not the one you'll hit by reflex. RightAlt sits next
-- to RightControl and Roblox binds neither, so both panel keys stay under one hand and
-- no game action is stolen by picking them.
local HIDE_KEY = Enum.KeyCode.RightAlt

-- Everything at once: WindUI keeps ONE UIScale on the ScreenGui, so this shrinks the
-- window, the rows, the text and the icons together and no layout constant below has to
-- change -- Size offsets stay in unscaled pixels and the panel just draws smaller.
-- 0.8 is about as far down as the 13px subtitle stays comfortable at 1080p; a script that
-- needs more room on screen passes its own opts.scale rather than shrinking everyone.
local SCALE = 0.8

local SHADE_TRIM = 12 -- fallback trailing space, only used if the left inset can't be read
local SHADE_MIN = 160 -- never shade narrower than the traffic lights + the shade button,
-- or there is nothing left to click and the window is unrecoverable
local SHADE_PAD = 0 -- extra height under the topbar. The topbar centres its content in
-- its OWN height, so anything added here is empty space below it and the pill reads
-- bottom-heavy. Raise only if the bar clips.

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

-- windui ---------------------------------------------------------------------
-- Fetched, not vendored, and one launch is FOUR requests to raw.githubusercontent: the
-- library, then the lucide, solar and craft icon packs its own bootstrap pulls. Any one
-- coming back empty ends the same way -- WindUI hands the nil straight to loadstring
-- (dist/main.lua:24496) and Opiumware reports "missing argument #3 to 'loadstring'"
-- from a stack with no line of your script in it. Nothing is broken when that happens;
-- the host rate-limited, and the fix is to ask again.
--
-- ponytail: the retry wraps the whole load, not just the fetch -- three of the four
-- requests happen inside WindUI where there is nothing to guard.
local WINDUI_URL = "https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"

local function loadWindUI()
	local env = getgenv and getgenv() or {}
	if env.ZegionWindUI then
		return env.ZegionWindUI -- second script this session: four requests already paid for
	end
	if not game:IsLoaded() then
		game.Loaded:Wait() -- HttpGet during the join is flaky; don't burn tries on it
	end

	local last
	for attempt = 1, 5 do
		local ok, lib = pcall(function()
			return loadstring(game:HttpGet(WINDUI_URL))()
		end)
		if ok and lib then
			env.ZegionWindUI = lib
			return lib
		end
		last = tostring(lib)
		warn(("[zegion] WindUI load %d/5 failed: %s"):format(attempt, last))
		task.wait(2) -- long enough for a rate limit to clear, short enough to not sit here
	end
	return nil, last
end

-- shade ----------------------------------------------------------------------
-- WindUI's own Minimize hides the whole window and leaves nothing but the floating open
-- button, which it only draws on touch devices -- on a PC the window would be gone with
-- nothing left to click. Swapped for a shade: the body collapses to a bare Zegion pill
-- and the same button rolls it back down. Loops keep running either way.
--
-- The pill is sized to its CONTENT, not to the window: keeping the full width leaves a
-- 440-wide black slab with a title in the corner of it. The game name is dropped on the
-- way down for the same reason -- collapsed, the panel is brand only.
--
-- Main is anchored at its CENTRE, so a resize on its own moves all four edges: the pill
-- would land mid-screen, and rolling it back down near the top of the screen pushed the
-- bar off it with nothing left to click. Every resize is paired with a position nudge of
-- half the delta, pinning the TOP-LEFT instead, so the bar collapses where it stands.
local SHADE_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local function installShade(WindUI, Window, setAuthorVisible, shadeKey)
	-- Measured, not guessed, so the bar fits whatever the title happens to be. WindUI
	-- lays the topbar out as three frames: Left (icon + title, AutomaticSize "X"), Right
	-- (the traffic lights and this button) and Center. With ButtonsType "Mac" it
	-- positions Left after Right, so the right-hand edge of the widest child IS the end
	-- of the content. AbsoluteSize is post-UIScale while Size offsets are pre-scale,
	-- hence the divide.
	local function shadeSize(fullWidth)
		local topbar = Window.UIElements.Main.Main.Topbar
		local scale = tonumber(WindUI.UIScale) or 1
		if scale <= 0 then
			scale = 1
		end

		local edge, inset = 0, math.huge
		for _, child in ipairs(topbar:GetChildren()) do
			-- Center is the tab-strip slot: unused and invisible here, but when it IS
			-- used it's sized to fill the window, defeating the whole measurement.
			if child:IsA("GuiObject") and child.Visible and child.Name ~= "Center" then
				local left = child.AbsolutePosition.X - topbar.AbsolutePosition.X
				edge = math.max(edge, left + child.AbsoluteSize.X)
				inset = math.min(inset, left) -- the gap in front of the traffic lights
			end
		end

		-- Trailing space is the leading space, measured rather than picked: a constant
		-- that looks right at one title length is visibly lopsided at another.
		local trim = inset < math.huge and inset or SHADE_TRIM
		local w = math.clamp((edge + trim) / scale, SHADE_MIN, fullWidth)
		return UDim2.fromOffset(w, Window.Topbar.Height + SHADE_PAD)
	end

	Window:DisableTopbarButtons({ "Minimize" }) -- before ours, it reuses the same slot

	local shaded, fullSize, shadeTo = false, nil, nil
	-- Named rather than inlined into CreateTopbarButton so the key below drives the exact
	-- same path -- a second copy of this would be a second place for the shaded flag and
	-- the two cached sizes to drift out of step with the button's.
	local function toggle()
		local main = Window.UIElements.Main
		-- The window was closed; the connection outlives it by a frame or two.
		if not main.Parent then
			return
		end
		shaded = not shaded

		-- Author goes first and the measurement waits a frame for it: Topbar.Left is
		-- AutomaticSize "X", and AutomaticSize resolves during the layout pass, not on
		-- the assignment. Measuring in the same frame reads the width the label still
		-- had, and the pill comes out game-name wide.
		setAuthorVisible(not shaded)
		RunService.Heartbeat:Wait()

		-- Both read live on the way down: a window the user resized comes back its own
		-- size, and the bar is re-measured each time in case the title, the buttons or
		-- the UIScale have changed since. Kept in upvalues so the way back up doesn't
		-- have to re-derive either end -- see the note on mid-tween reads below.
		if shaded then
			fullSize = main.Size
			shadeTo = shadeSize(fullSize.X.Offset)
		end
		-- Topbar is the one child that stays. Going by name rather than by index keeps
		-- this working if WindUI reshuffles the body frames.
		for _, child in ipairs(main.Main:GetChildren()) do
			if child:IsA("GuiObject") and child.Name ~= "Topbar" then
				child.Visible = not shaded
			end
		end

		-- Both ends are known, so the delta is computed rather than read back off a
		-- frame that is still mid-tween from the last click.
		local from, to = shaded and fullSize or shadeTo, shaded and shadeTo or fullSize
		local p = main.Position
		Window:SetSize(to)
		-- Matched to SetSize's own tween, or the corner visibly slides while the size catches up.
		TweenService:Create(main, SHADE_TWEEN, {
			Position = UDim2.new(
				p.X.Scale,
				p.X.Offset + (to.X.Offset - from.X.Offset) / 2,
				p.Y.Scale,
				p.Y.Offset + (to.Y.Offset - from.Y.Offset) / 2
			),
		}):Play()
	end

	Window:CreateTopbarButton("Shade", "minus", toggle, 998, nil, Color3.fromHex("#F4C948")) -- same yellow the real Minimize used

	-- gameProcessed is the whole guard: the panel has a search bar, and without it the
	-- key shades the window from under you while you're typing in it.
	local conn
	conn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and input.KeyCode == shadeKey then
			toggle()
		end
	end)
	-- Re-pasting a script builds a whole new window; without this the old one's handler
	-- lives on and every panel ever opened this session answers the key.
	Window.UIElements.Main.Destroying:Connect(function()
		conn:Disconnect()
	end)

	return function()
		return shaded
	end
end

-- above ----------------------------------------------------------------------
-- The Roblox menu (Esc) is CoreGui, and CoreGui draws over PlayerGui whatever
-- DisplayOrder says -- so a panel living in PlayerGui is underneath it by construction
-- and no amount of ordering fixes that. Three things, and all three are needed:
--
--   * be in CoreGui at all. gethui() is the executor's own slot inside it, and is where
--     WindUI already puts itself on most executors -- this only moves the window when it
--     didn't, which is also the case where nothing else here would have helped.
--   * DisplayOrder above the core menu's. Roblox's own screens sit in single digits;
--     max int is not subtle, but there is nothing above it to collide with.
--   * OnTopOfCoreBlur, or the menu's blur is laid over the panel and you get a legible
--     window behind frosted glass. Newer clients only, hence the pcall.
local DISPLAY_ORDER = 2147483647

local function raise(gui)
	if not gui or not gui:IsA("ScreenGui") then
		return false
	end
	if gethui and gui:IsDescendantOf(game:GetService("Players").LocalPlayer) then
		pcall(function()
			gui.Parent = gethui()
		end)
	end
	pcall(function()
		gui.DisplayOrder = DISPLAY_ORDER
	end)
	pcall(function()
		gui.OnTopOfCoreBlur = true
	end)
	return not gui:IsDescendantOf(game:GetService("Players").LocalPlayer)
end

-- panel ----------------------------------------------------------------------
-- opts.game   the fallback subtitle, used until the live name lands (required)
-- opts.folder where WindUI saves configs -- keep whatever the script already used, or
--             configs saved under the old name are orphaned (required)
-- opts.size   window size, default 440x400
-- opts.key    minimise/expand key, default RightControl. NOTE: this used to be the
--             hide-outright key. Every script passes RightControl for "the panel key",
--             so the roles were swapped here rather than in twenty-one call sites.
-- opts.hideKey   hide the window outright, default RightAlt (was opts.shadeKey)
-- opts.scale  UI scale, default SCALE
local function panel(opts)
	local WindUI, why = loadWindUI()
	if not WindUI then
		warn("[zegion] WindUI would not load (" .. tostring(why) .. ") -- no panel, nothing started.")
		return nil
	end

	local Window = WindUI:CreateWindow({
		Title = BRAND,
		Author = opts.game, -- a second label under the title, stacked by WindUI's own layout
		Icon = ICON,
		Folder = opts.folder,
		Size = opts.size or UDim2.fromOffset(440, 400),
		HideSearchBar = opts.hideSearchBar, -- nil is WindUI's own default (shown)
		Topbar = { Height = TOPBAR_H, ButtonsType = "Mac" },
		OpenButton = { Title = BRAND, Enabled = true, Draggable = true },
	})
	-- WindUI's own toggle is the hide-outright one, so it gets the secondary key. The
	-- primary key goes to the shade, below.
	Window:SetToggleKey(opts.hideKey or HIDE_KEY)
	-- After CreateWindow, not before: the UIScale instance is built with the window, and
	-- SetUIScale is what updates WindUI.UIScale itself -- which the shade measurement
	-- below reads to convert AbsoluteSize back into offsets.
	pcall(function()
		Window:SetUIScale(opts.scale or SCALE)
	end)

	-- Only the window's OWN ScreenGui, found by walking up from a frame we hold rather
	-- than by name. Deliberately not its siblings: when WindUI lands directly in CoreGui
	-- those siblings are Roblox's own screens, and handing them max DisplayOrder would
	-- reorder the player's actual game UI to fix ours. If WindUI ever splits the open
	-- button or the toasts into their own ScreenGui, those stay under the menu -- a
	-- cosmetic gap, and the cheap price of not touching instances we don't own.
	local mine = Window.UIElements.Main:FindFirstAncestorOfClass("ScreenGui")
	if mine and not raise(mine) then
		warn("[zegion] panel is still in PlayerGui -- no gethui, so the Esc menu will cover it")
	end

	-- WindUI selects nothing on its own, so a fresh panel opens on an empty body and the
	-- first tab has to be clicked before anything shows. Wrapped here rather than a
	-- SelectTab(1) at the bottom of all 14 scripts. A script that wants to land somewhere
	-- else just calls otherTab:Select() after its tabs exist -- last call wins.
	local rawTab, landed = Window.Tab, false
	function Window.Tab(self, cfg)
		local tab = rawTab(self, cfg)
		if not landed then
			landed = true
			tab:Select()
		end
		return tab
	end

	local isShaded
	local function setAuthorVisible(visible)
		local author = Window.UIElements.Main.Main.Topbar.Left.Title:FindFirstChild("Author")
		if author then
			author.Visible = visible
		end
	end
	isShaded = installShade(WindUI, Window, setAuthorVisible, opts.key or KEY)

	-- The live name, so a game that renames itself doesn't leave the panel lying --
	-- "Wings for Brainrots" ships as "+1 Wings for Brainrots", "Steal an Animal" is
	-- "Save Animals!" now. GetProductInfo is a yielding web call, so it runs after the
	-- window exists rather than in front of it: rate-limited or dead, it costs nothing
	-- but the fallback string.
	task.spawn(function()
		local ok, info = pcall(function()
			return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
		end)
		if ok and info and info.Name then
			Window:SetAuthor(info.Name)
			setAuthorVisible(not isShaded()) -- SetAuthor draws the label visible
		end
	end)

	return Window, WindUI
end

-- ponytail: deliberately NOT cached in getgenv. This file is one small request, and a
-- cached copy means editing it and re-pasting in the same session silently runs the old
-- one. WindUI is the expensive fetch (four requests) and that IS cached, above.
return panel
