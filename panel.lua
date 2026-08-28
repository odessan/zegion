--[[ Zegion panel -- the shared chrome every game script builds its UI on.

     local panel = loadstring(game:HttpGet(PANEL_URL))()
     local Window, WindUI = panel({ game = "Wings for Brainrots", folder = "WingsRots" })
     if not Window then return end

     Everything brand-shaped lives in here and nowhere else: the topbar wording, the
     icon, the floating bubble, the topbar height, the live game name and the shade.
     Restyle once, every script picks it up the next time it's pasted.

     A script keeps its own Tabs, Sections and rows -- this only builds the window and
     hands it back. Each script fetches this itself rather than relying on the loader to
     install it, so every one of them still pastes and runs on its own. ]]

-- brand ----------------------------------------------------------------------
local BRAND = "Zegion"
local ICON = "solar:bolt-circle-bold" -- one mark for every script; verify names at api.iconify.design
local TOPBAR_H = 58 -- two stacked labels (16px over 13px); 44 is a one-line topbar and reads packed
local KEY = Enum.KeyCode.RightControl

local SHADE_TRIM = 28 -- trailing space after the title. The measured 8 (Topbar's own
-- PaddingRight) is true to the content but reads clipped against the corner radius.
local SHADE_MIN = 160 -- never shade narrower than the traffic lights + the shade button,
-- or there is nothing left to click and the window is unrecoverable
local SHADE_PAD = 10 -- window chrome under the topbar; nudge if the shade clips

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

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

local function installShade(WindUI, Window, setAuthorVisible)
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

		local edge = 0
		for _, child in ipairs(topbar:GetChildren()) do
			-- Center is the tab-strip slot: unused and invisible here, but when it IS
			-- used it's sized to fill the window, defeating the whole measurement.
			if child:IsA("GuiObject") and child.Visible and child.Name ~= "Center" then
				edge = math.max(edge, child.AbsolutePosition.X + child.AbsoluteSize.X - topbar.AbsolutePosition.X)
			end
		end

		local w = math.clamp(edge / scale + SHADE_TRIM, SHADE_MIN, fullWidth)
		return UDim2.fromOffset(w, Window.Topbar.Height + SHADE_PAD)
	end

	Window:DisableTopbarButtons({ "Minimize" }) -- before ours, it reuses the same slot

	local shaded, fullSize, shadeTo = false, nil, nil
	Window:CreateTopbarButton("Shade", "minus", function()
		local main = Window.UIElements.Main
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
	end, 998, nil, Color3.fromHex("#F4C948")) -- same yellow the real Minimize used

	return function()
		return shaded
	end
end

-- panel ----------------------------------------------------------------------
-- opts.game   the fallback subtitle, used until the live name lands (required)
-- opts.folder where WindUI saves configs -- keep whatever the script already used, or
--             configs saved under the old name are orphaned (required)
-- opts.size   window size, default 440x400
-- opts.key    toggle key, default RightControl
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
	Window:SetToggleKey(opts.key or KEY)

	local isShaded
	local function setAuthorVisible(visible)
		local author = Window.UIElements.Main.Main.Topbar.Left.Title:FindFirstChild("Author")
		if author then
			author.Visible = visible
		end
	end
	isShaded = installShade(WindUI, Window, setAuthorVisible)

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
