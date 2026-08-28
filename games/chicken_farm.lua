--[[ Chicken Farm GUI
     Executor only: the UI is WindUI, pulled in with HttpGet, which Studio blocks.
     Add a feature = one entry in ACTIONS below. The GUI builds itself from it. ]]

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remotes = game:GetService("ReplicatedStorage"):WaitForChild("Paper"):WaitForChild("Remotes")
local rf = remotes:WaitForChild("__remotefunction")
local re = remotes:WaitForChild("__remoteevent")

local INTERVAL = 0.2 -- ponytail: fixed rate, add a delay box if a game rate-limit needs tuning
local running = true -- flipped by Close; every loop in here watches it

-- anti-afk ------------------------------------------------------------------
-- Roblox kicks after ~20 min without input. A right-click through VirtualUser counts
-- as input without doing anything in the game. Two triggers, because relying on Idled
-- alone means one missed event costs you the session:
--   * every 60s regardless, so the idle timer never gets near 20 min
--   * on Idled, which is the last warning before the kick
-- ponytail: always on, no toggle.
local hasVU, vu = pcall(game.GetService, game, "VirtualUser")
local hasVIM, vim = pcall(game.GetService, game, "VirtualInputManager")
print("[ChickenFarm] anti-afk: VirtualUser", hasVU and "ok" or "MISSING", "| VirtualInputManager", hasVIM and "ok" or "MISSING")

-- Two input paths, because a client that ignores one may still honor the other.
local nudges = 0
local function nudge(why)
	if hasVU then
		-- Down+Up beats ClickButton2: some clients ignore the one-shot version.
		local cf = workspace.CurrentCamera and workspace.CurrentCamera.CFrame or CFrame.new()
		pcall(function()
			vu:CaptureController()
			vu:Button2Down(Vector2.new(0, 0), cf)
			task.wait(0.05)
			vu:Button2Up(Vector2.new(0, 0), cf)
		end)
	end
	if hasVIM then
		pcall(function()
			vim:SendMouseButtonEvent(0, 0, 1, true, game, 0) -- right button, harmless
			vim:SendMouseButtonEvent(0, 0, 1, false, game, 0)
		end)
	end
	nudges = nudges + 1
	-- ponytail: a print is the whole diagnostic. "Still kicked" is unanswerable without it.
	print(("[ChickenFarm] nudge #%d (%s) at %ds uptime"):format(nudges, why or "timer", math.floor(os.clock())))
end

-- Last line of defence: whatever the disconnect reason (idle kick, the game's own AFK
-- check, a network drop), the error prompt shows up in CoreGui. Rejoin on sight.
-- ponytail: covers every cause at once instead of diagnosing which one fired.
task.spawn(function()
	local ok, overlay = pcall(function()
		local gui = game:GetService("CoreGui"):WaitForChild("RobloxPromptGui", 10)
		return gui and gui:WaitForChild("promptOverlay", 10)
	end)
	if not ok or not overlay then
		-- ponytail: timeout instead of blocking forever, so a missing prompt GUI is visible
		warn("[ChickenFarm] rejoin-on-disconnect NOT armed (no CoreGui.RobloxPromptGui.promptOverlay)")
		return
	end
	print("[ChickenFarm] rejoin-on-disconnect armed")
	overlay.ChildAdded:Connect(function(child)
		if child.Name:find("ErrorPrompt") then
			warn("[ChickenFarm] disconnected - rejoining")
			pcall(function()
				game:GetService("TeleportService"):Teleport(game.PlaceId, player)
			end)
		end
	end)
end)

local afk = player.Idled:Connect(function()
	nudge("Idled") -- Roblox's own idle warning fired: ~20 min without input it accepted
end)
task.spawn(function()
	while running do
		task.wait(60)
		nudge("timer")
	end
end)

-- fire ----------------------------------------------------------------------
-- pcall so a server-side error doesn't kill an auto loop.
-- NOTE: FireServer returns nothing, so ok=true only means the call left the client.
-- The server can ignore it silently. Believe the game, not the return value.
local function send(remote, method, ...)
	local ok, err = pcall(remote[method], remote, ...)
	if not ok then
		warn("[ChickenFarm]", err) -- no status line in the UI; errors go to the console (F9)
	end
	return ok
end

-- Eggs and lucky blocks are both addressed by a uuid the client already knows.
-- ponytail: assumes the uuid is the instance name or one of its attributes. Use Spy
-- to see the real id if a scan finds nothing.
local function isUuid(s)
	return #s == 36 and s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-") ~= nil
end

local function uuidOf(inst)
	if isUuid(inst.Name) then
		return inst.Name
	end
	for _, v in pairs(inst:GetAttributes()) do
		if type(v) == "string" and isUuid(v) then
			return v
		end
	end
	return nil
end

-- keyword keeps egg ids from being fired at the lucky-block remote and vice versa:
-- an id counts as a match when the word shows up in its own name or an ancestor's.
--
-- Nothing in this place actually carries those words, so the keyword never matches and
-- the choice of fallback is what decides behavior:
--   uuids("egg")          -> falls back to every uuid. Collect Eggs is the catch-all
--                            collector and this fallback is the only reason it works.
--   uuids("luck", true)   -> strict: collects nothing rather than firing egg ids at
--                            the lucky-block remote and double-collecting.
local function named(inst, keyword)
	local node = inst
	for _ = 1, 4 do
		if not node or node == workspace then
			return false
		end
		if node.Name:lower():find(keyword) then
			return true
		end
		node = node.Parent
	end
	return false
end

local function uuids(keyword, strict)
	local hits, any = {}, {}
	for _, d in ipairs(workspace:GetDescendants()) do
		local id = uuidOf(d)
		if id then
			local entry = { id = id, inst = d }
			table.insert(any, entry)
			if named(d, keyword) then
				table.insert(hits, entry)
			end
		end
	end
	if #hits > 0 then
		return hits
	end
	return strict and {} or any
end

-- Reads the "Egg Multiplier: 1.04x" text. Found by its content, not a path, so a UI
-- reshuffle doesn't break it. The label can live in PlayerGui, the executor's hidden
-- gui container, or a Billboard/SurfaceGui out in workspace - check all three.
local multLabel, lastScan = nil, 0
local function findMult()
	if multLabel and multLabel.Parent then
		return multLabel
	end
	multLabel = nil
	if os.clock() - lastScan < 2 then
		return nil -- ponytail: scanning workspace every 0.2s is not free; 2s is plenty
	end
	lastScan = os.clock()

	-- known path first (confirmed in-game); the scan below is the fallback if the
	-- game moves it. Saves sweeping all of workspace when the part streams back in.
	local direct = workspace:FindFirstChild("Map")
	direct = direct and direct:FindFirstChild("EggMultiplierPart")
	direct = direct and direct:FindFirstChild("UI")
	direct = direct and direct:FindFirstChild("Multi")
	if direct and direct:IsA("TextLabel") then
		multLabel = direct
		return direct
	end

	local roots = { playerGui, workspace }
	if gethui then
		table.insert(roots, gethui())
	end
	for _, root in ipairs(roots) do
		local ok, kids = pcall(root.GetDescendants, root) -- CoreGui can be off limits
		if ok then
			for _, d in ipairs(kids) do
				if d:IsA("TextLabel") and d.Text:find("Multiplier") then
					multLabel = d
					print("[ChickenFarm] multiplier label:", d:GetFullName(), "=", d.Text)
					return d
				end
			end
		end
	end
	return nil
end

local function multiplier()
	local l = findMult()
	return l and tonumber(l.Text:match("([%d%.]+)%s*x"))
end

-- ACTIONS -------------------------------------------------------------------
-- label   row text
-- group   which card it lands in, see GROUPS. Unset = "Advanced" (collapsed).
-- remote  rf (RemoteFunction) or re (RemoteEvent)
-- method  "InvokeServer" or "FireServer"
-- cmd     first arg the server switches on
-- interval  optional seconds between fires while ON (default INTERVAL)
-- once    true = one-shot button with a confirm dialog instead of a looping toggle
-- input   optional control on its own row: {cycle = {..values}, default = v} -> dropdown,
--         or {text = "default"} -> text box
-- run     optional override taking (self, value). Default: send(remote, method, cmd)
local ACTIONS = {
	{
		label = "Buy + Merge",
		group = "Buy",
		input = { cycle = { 1, 5, 25, 100 }, default = 25 },
		run = function(self, qty)
			send(rf, "InvokeServer", "Buy Chickens", qty)
			-- harmless if the 100 bundle already auto-merged: the server just has
			-- nothing to merge. ponytail: cheaper than detecting which bundle merges.
			send(rf, "InvokeServer", "Merge Chickens")
		end,
	},
	{
		label = "Collect Eggs",
		group = "Collect",
		run = function()
			for _, e in ipairs(uuids("egg")) do
				send(re, "FireServer", "Collect Egg", e.id)
				-- ponytail: the game's own LocalScript normally clears the model; firing the
				-- remote directly skips that, so drop it here. Client-side only (cosmetic),
				-- but it also stops the scan re-firing the same id every tick.
				pcall(game.Destroy, e.inst)
			end
		end,
	},
	{
		label = "Collect Cash",
		group = "Collect",
		remote = rf,
		method = "InvokeServer",
		cmd = "Collect Cash",
	},
	{
		-- Three steps in the game's own order: pick the block up by id, open it,
		-- claim what came out. Open and Claim are cheap no-ops when there is
		-- nothing to open, so the chain runs unconditionally.
		label = "Lucky Blocks",
		group = "Collect",
		run = function()
			for _, b in ipairs(uuids("luck", true)) do
				send(rf, "InvokeServer", "Collect Lucky Block", b.id)
				pcall(game.Destroy, b.inst) -- same cosmetic cleanup as the eggs
			end
			send(rf, "InvokeServer", "Open Lucky Block")
			task.wait(0.3) -- let the open resolve before claiming
			send(re, "FireServer", "Claim Opened Chicken")
		end,
	},
	{
		label = "Upgrade Process",
		remote = rf,
		method = "InvokeServer",
		cmd = "Upgrade Process Level",
		interval = 5, -- spends cash on every hit; don't drain the bank at 0.2s
	},
	{
		label = "Upgrade Buy Tier",
		remote = rf,
		method = "InvokeServer",
		cmd = "Upgrade Buy Tier Level",
		interval = 5, -- same reasoning as Upgrade Process: each hit costs cash
	},
	{
		-- Wipes progress, so it never goes on a loop: once = true gives it a
		-- press-to-fire button with a confirm instead of an ON/OFF switch.
		label = "Rebirth",
		remote = rf,
		method = "InvokeServer",
		cmd = "Rebirth",
		once = true,
	},
	{
		label = "Deposit @",
		group = "Deposit",
		input = { text = "1.4" },
		-- The multiplier label updates every ~30s. Fire once per window, not per tick:
		-- deposit when the value changes to something >= the threshold. The 28s clause
		-- covers a window that happens to repeat the previous value.
		run = function(self, minText)
			local m = multiplier()
			if not m then
				-- once every 5s, not every tick
				if os.clock() - (self.warnedAt or -math.huge) > 5 then
					self.warnedAt = os.clock()
					warn("[ChickenFarm] no 'Multiplier' text found - is the label visible?")
				end
				return
			end
			local fresh = m ~= self.last or (os.clock() - (self.firedAt or 0)) > 28
			self.last = m
			if fresh and m >= (tonumber(minText) or 1.4) then
				self.firedAt = os.clock()
				send(rf, "InvokeServer", "Deposit Eggs")
			end
		end,
	},
}

-- spy -----------------------------------------------------------------------
-- Logs the remote calls the game itself makes, so you can read the args the server
-- actually wants. Turn on, do the action manually, check the console (F9).
local spyOld, spy = nil, false
local function startSpy()
	if not (hookmetamethod and getnamecallmethod) then
		warn("[ChickenFarm] spy needs an executor")
		return false
	end
	if spyOld then
		return true
	end
	spyOld = hookmetamethod(game, "__namecall", function(self, ...)
		local m = getnamecallmethod()
		if spy and (m == "FireServer" or m == "InvokeServer") and typeof(self) == "Instance" and self.Parent == remotes then
			local parts = {}
			for _, v in ipairs({ ... }) do
				table.insert(parts, typeof(v) == "Instance" and (v:GetFullName() .. " <Instance>") or tostring(v))
			end
			print("[spy]", self.Name, m, table.concat(parts, " | "))
		end
		return spyOld(self, ...)
	end)
	return true
end

-- shell ---------------------------------------------------------------------
-- ponytail: the hand-rolled widget kit is gone. WindUI already ships rows, toggles,
-- dropdowns, drag, resize, search and the topbar buttons, so there is nothing here
-- worth owning. Fetched at runtime; nothing to vendor.
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a
-- restyle is one file and not sixteen. Fetched here rather than installed by the loader,
-- so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Chicken Farm", -- fallback until the live name lands
	folder = "ChickenFarm", -- unchanged: renaming it orphans configs already saved in-game
	size = UDim2.fromOffset(520, 400),
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })

-- GROUPS --------------------------------------------------------------------
-- One card per group, rendered in this order. Every action names one; anything
-- that names none lands in Advanced, which starts collapsed.
--   master  optional switch at the top of the card that fans out to the group's
--           toggles. Nil for groups where flipping everything makes no sense.
--   opened  false = card starts collapsed.
local GROUPS = {
	{
		name = "Collect",
		icon = "solar:box-bold",
		desc = "Everything that picks things up",
		master = "Collect everything",
		opened = true,
	},
	{ name = "Buy", icon = "solar:cart-large-2-bold", opened = true },
	{ name = "Deposit", icon = "solar:safe-2-bold", opened = true },
	{
		name = "Advanced",
		icon = "solar:settings-bold",
		desc = "Spends cash, wipes progress, or only useful when something is broken",
		opened = false,
	},
}

-- Box + BoxBorder are what turn a bare header into a card: WindUI paints the
-- surface from its SectionBox theme tokens and the hairline from
-- SectionBoxBorder, so this tracks the active theme instead of pinning colors.
-- ponytail: no dividers between the cards - the card edge already is the divider.
local sections, members = {}, {}
for _, g in ipairs(GROUPS) do
	sections[g.name] = Tab:Section({
		Title = g.name,
		Desc = g.desc,
		Icon = g.icon,
		Box = true,
		BoxBorder = true,
		Opened = g.opened,
	})
	members[g.name] = {}
end

-- Masters go in before the build loop so they sit at the top of their card. The
-- member list they fan out to is still empty here and fills in below; the callback
-- only ever runs on a click, long after that.
for _, g in ipairs(GROUPS) do
	if g.master then
		local list = members[g.name]
		sections[g.name]:Toggle({
			Title = g.master,
			Desc = "Flips every switch in this group",
			Value = false,
			Callback = function(state)
				for _, t in ipairs(list) do
					-- Set fires each toggle's own Callback, so the loop-start logic
					-- below stays the single copy. This is a fan-out, not new state.
					t:Set(state)
				end
			end,
		})
	end
end

-- An action's `input` spec becomes its own row above the action, not an inline
-- control: WindUI rows are full width. Returns read(), same contract as before.
local function inputFor(section, action)
	local spec = action.input
	if spec.cycle then
		local values, current = {}, tostring(spec.default)
		for _, v in ipairs(spec.cycle) do
			table.insert(values, tostring(v))
		end
		section:Dropdown({
			Title = action.label .. " amount",
			Values = values,
			Value = current,
			Callback = function(v)
				current = v
			end,
		})
		return function()
			return tonumber(current) or spec.default
		end
	end

	local current = spec.text
	section:Input({
		Title = action.label .. " value",
		Value = current,
		Placeholder = spec.text,
		Callback = function(v)
			current = v
		end,
	})
	return function()
		return current
	end
end

-- build ---------------------------------------------------------------------
for _, action in ipairs(ACTIONS) do
	local group = sections[action.group] and action.group or "Advanced"
	local section = sections[group]
	local read = action.input and inputFor(section, action)

	local function fire()
		if action.run then
			action.run(action, read and read() or nil)
		else
			send(action.remote, action.method, action.cmd)
		end
	end

	if action.once then
		-- WindUI's dialog replaces the old two-click arm-then-fire pill. Not a
		-- toggle, so it stays out of the master's member list.
		section:Button({
			Title = action.label,
			Callback = function()
				Window:Dialog({
					Title = action.label,
					Content = "Run " .. action.label .. "? This cannot be undone.",
					Buttons = {
						{ Title = "Cancel", Variant = "Secondary" },
						{ Title = "Run", Variant = "Primary", Callback = fire },
					},
				})
			end,
		})
		continue
	end

	local on = false
	table.insert(
		members[group],
		section:Toggle({
			Title = action.label,
			Value = false,
			Callback = function(state)
				on = state
				if not state then
					return
				end
				task.spawn(function()
					while on and running do
						fire()
						task.wait(action.interval or INTERVAL)
					end
				end)
			end,
		})
	)
end

sections.Advanced:Toggle({
	Title = "Spy remotes",
	Desc = "Logs the game's own remote calls to the console (F9)",
	Value = false,
	Callback = function(on)
		spy = on and startSpy() and true or false
	end,
})

-- close ----------------------------------------------------------------------
-- The red button destroys the window after WindUI's own confirm dialog, so teardown
-- hangs off OnDestroy: stop every loop, silence the spy, drop the anti-afk hook. The
-- __namecall hook itself stays installed (executors have no unhook) but is a plain
-- passthrough once spy is false. ponytail: rerun the script to come back.
Window:OnDestroy(function()
	running, spy = false, false
	afk:Disconnect()
end)
