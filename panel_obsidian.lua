--[[ Zegion panel (Obsidian) -- the same idea as panel.lua, for scripts that want the
     Obsidian look instead of WindUI.

     local panel = loadstring(game:HttpGet(PANEL_URL))()
     local Window, Library = panel({ game = "TP for Brainrots", size = UDim2.fromOffset(440, 320) })
     if not Window then return end

     Rows are Obsidian's own API, not WindUI's: Window:AddTab -> Tab:AddLeftGroupbox ->
     Groupbox:AddToggle("Idx", {Text, Default, Callback}). Nothing here translates between
     the two -- the callback timing and Set() re-entrancy differ, so an adapter would only
     hide a second set of quirks. panel.lua and every WindUI script are untouched.

     Key:   RightControl  hides / shows the window (Obsidian's own ToggleKeybind)
     Stop:  Library:Unload() -- runs every Library:OnUnload callback, then destroys the UI.

     No shade pill: Obsidian hides the whole window and the key brings it back, which is
     enough on PC. Add one if a script needs the loops visible while collapsed. ]]

-- brand ----------------------------------------------------------------------
local BRAND = "Zegion"
local KEY = Enum.KeyCode.RightControl
local DISPLAY_ORDER = 2147483643 -- Obsidian ships at 998, under the Esc menu's own screens

local LIB_URL = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/Library.lua"

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
-- opts.key   show/hide key, default RightControl
local function panel(opts)
	local Library, why = loadObsidian()
	if not Library then
		warn("[zegion] Obsidian would not load (" .. tostring(why) .. ") -- no panel, nothing started.")
		return nil
	end

	local Window = Library:CreateWindow({
		Title = BRAND,
		Footer = opts.game,
		Size = opts.size or UDim2.fromOffset(440, 320),
		Center = true,
		AutoShow = true,
		Resizable = true,
		AlwaysOnTop = true, -- OnTopOfCoreBlur, or the Esc menu's blur frosts the panel
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
