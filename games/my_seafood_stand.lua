--[[ Auto cook -- equip raw -> Insert -> collect at Perfect -> Serve

     Only touches stands whose Owner attribute is you. Cookers are the stands with a
     Hitbox / Hitbox1 / Hitbox2, seats are the slots with SlotKind=Serve. Every slot
     carries SlotState -- Empty, Served, or cooking with a CookProgress running 0 -> 1.

     Seafood are Tools in the Backpack -- RawFood=true going in, CookedFood=true
     coming out -- and Insert/Serve act on what you have equipped, so every remote
     here is preceded by an equip.

     Executor: paste and run.  Studio: LocalScript in StarterPlayerScripts.
     H or the COOK button toggles. Stop: getgenv().cookStop() ]]

-- config ---------------------------------------------------------------------
local FISH = nil -- e.g. "Anchovy" to cook only those; nil takes whatever is raw
-- CookingConfig puts "Perfect" at progress 0.4 -> 0.66. Sitting near the bottom of
-- that band rather than the middle: overshooting is what burns food, and undershooting
-- into "Almost Done" costs a grade where burning costs the lot. Shrimp cooks in 5s, so
-- the whole band is 1.3s wide and the slack has to go somewhere.
local TARGET = 0.45
local KEY_TOGGLE = Enum.KeyCode.H
local POLL = 0.1 -- the game's own promptRefreshRate
local IDLE = 2 -- back off this long when there is nothing left to insert
-- The server enforces CookingConfig.promptDistance (10.5), verified at 153 studs: the
-- Insert was simply ignored. Anything further than REACH gets a snap to the stand and
-- back, so you can be anywhere. SNAP is how long the new position needs to replicate
-- before the remote lands -- raise it if actions start getting dropped on a bad ping.
-- TELEPORT = false never moves you: out-of-range slots are just skipped until you walk
-- back. The game's own freecam (Settings > Freecam) is the no-teleport way to be
-- somewhere else -- it moves the camera and leaves your character on the plot.
local TELEPORT = true
local REACH = 9 -- under 10.5, leaving room for the stand's own size
local SNAP = 0.15

-- setup ----------------------------------------------------------------------
if getgenv and getgenv().cookStop then
	getgenv().cookStop()
end

local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local Event = RS.Remotes.Events.CookAction
local player = game:GetService("Players").LocalPlayer
local ME = player.UserId

local running = false
local threads = {}

-- stands ---------------------------------------------------------------------
-- ponytail: re-read every time rather than cached -- stands get placed, moved and
-- sold mid-round, and a stale hitbox is a remote fired at nothing.
local function mine()
	local cookers, tables = {}, {}
	for _, stand in ipairs(workspace.Stands:GetChildren()) do
		if stand:GetAttribute("Owner") == ME then
			for _, part in ipairs(stand:GetChildren()) do
				if part.Name:match("^Hitbox%d?$") then
					table.insert(cookers, part)
				elseif part:GetAttribute("SlotKind") == "Serve" then
					table.insert(tables, part)
				end
			end
		end
	end
	return cookers, tables
end

-- A seat is a slot like any cooker slot: SlotState is Empty or Served. Counting
-- ServedFood models on the stand was a guess, and it was the wrong one -- a Picnic
-- Table's three seats share one stand, so the count never said which seat was free.
--
-- Nearest free seat, not the first one found: promptDistance is 10.5 studs, so this
-- keeps the snap short when roaming and avoids it entirely when it can.
local function freeSeat()
	local _, tables = mine()
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local best, bestDist = nil, math.huge
	for _, hitbox in ipairs(tables) do
		if hitbox:GetAttribute("SlotState") == "Empty" then
			local d = root and (hitbox.Position - root.Position).Magnitude or 0
			if d < bestDist then
				best, bestDist = hitbox, d
			end
		end
	end
	return best, bestDist
end

-- holding --------------------------------------------------------------------
-- ponytail: one global lock. Only one tool can be equipped at a time, so two slots
-- equipping at once would have each inserting the other's fish. Per-slot queues if
-- you ever run enough cookers for the wait to matter.
local busy = false

local function equip(pred)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	-- Collect can put the cooked food straight into your hand, and a held tool lives
	-- in the character, not the Backpack -- so check there first or Serve fires with
	-- nothing equipped the moment it's the only cooked item you own.
	local held = char:FindFirstChildOfClass("Tool")
	if held and pred(held) then
		return held
	end
	for _, tool in ipairs(player.Backpack:GetChildren()) do
		if tool:IsA("Tool") and pred(tool) then
			hum:EquipTool(tool)
			return tool
		end
	end
end

-- Every remote runs through here: take the lock, hold the right tool, be standing
-- close enough, fire, put everything back. pred is nil for actions that need no tool.
--
-- The server checks CookingConfig.promptDistance, so from across the map the character
-- itself has to be there when the remote lands -- snap the root there and back. Within
-- range this costs nothing: no teleport, no waits, and the lock is held for the length
-- of one FireServer.
-- ponytail: one global lock, so while roaming each action queues behind the last for
-- ~2*SNAP. Standing on your plot removes the cost entirely; if you want to roam with
-- many fast cookers, that queue is what to attack next.
local function act(hitbox, action, pred)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")

	-- Fast path. Collect needs no tool, so with nothing to equip and nothing to snap
	-- there is nothing to serialize: every slot that hits its window fires in the same
	-- frame. Standing within reach of all your cookers is what makes collects land
	-- together -- as soon as one is far enough to need the snap, they queue again.
	if not pred and root and (hitbox.Position - root.Position).Magnitude <= REACH then
		Event:FireServer(hitbox, action)
		return true
	end

	while busy do
		task.wait(0.05)
	end
	busy = true

	local ok = true
	if pred then
		ok = equip(pred) ~= nil
	end

	if ok then
		root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		local far = root and (hitbox.Position - root.Position).Magnitude > REACH
		if far and not TELEPORT then
			busy = false
			return false -- out of range and not allowed to move: the server would drop it
		end
		local home = far and root.CFrame
		if home then
			root.CFrame = CFrame.new(hitbox.Position + Vector3.new(0, 3, 0))
			task.wait(SNAP) -- let the new position replicate before the server judges it
		end
		Event:FireServer(hitbox, action)
		if home then
			task.wait(SNAP)
			root.CFrame = home
		end
	end

	busy = false
	return ok
end

local function isRaw(tool)
	return tool:GetAttribute("RawFood") and (FISH == nil or tool.Name == FISH)
end

local function isCooked(tool)
	return tool:GetAttribute("CookedFood") ~= nil
end

-- one slot, one thread -------------------------------------------------------
-- Watching CookProgress beats timing a cook: it already accounts for boosters and
-- speed buffs, and cook times run from 5s to four real days, so no shared cycle fits.
local function cook(hitbox)
	while running and hitbox.Parent do
		if hitbox:GetAttribute("SlotState") == "Empty" then
			local had = act(hitbox, "Insert", isRaw)
			task.wait(0.3)
			if not had or hitbox:GetAttribute("SlotState") == "Empty" then
				task.wait(IDLE) -- out of raw seafood, or the server refused it
			end
		elseif (hitbox:GetAttribute("CookProgress") or 0) >= TARGET then
			act(hitbox, "Collect")
			task.wait(0.3)
		else
			-- Coarse polling while the bar is far off, frame-accurate once it's close.
			-- ponytail: 0.3 is an arbitrary "getting close"; the point is only to stop
			-- paying 0.1s of our own latency out of Shrimp's 1.3s window.
			task.wait((hitbox:GetAttribute("CookProgress") or 0) >= 0.3 and 0 or POLL)
		end
	end
end

-- serving, on its own clock ---------------------------------------------------
-- Not tied to a cook cycle: anything cooked in the backpack goes onto a free seat,
-- whether this script cooked it or you did. The equip lock keeps it off the cookers.
local function serve()
	while running do
		local seat = freeSeat()
		if seat and act(seat, "Serve", isCooked) then
			task.wait(0.3)
		else
			task.wait(IDLE) -- no seat free, or nothing cooked to put on it
		end
	end
end

-- Cookers get bought, placed and sold while this runs, so slots are picked up as they
-- appear rather than snapshotted at start. Keyed by the hitbox itself: a cook thread
-- ends on its own when its hitbox leaves the workspace, and a replacement is a new
-- instance, so it gets a new thread.
local function supervise()
	local watched = {}
	while running do
		for _, hitbox in ipairs(mine()) do
			if not watched[hitbox] then
				watched[hitbox] = true
				table.insert(threads, task.spawn(cook, hitbox))
				print("[auto_cook] slot added: " .. hitbox.Parent.Name .. "." .. hitbox.Name)
			end
		end
		task.wait(3)
	end
end

local function start()
	if running then
		return
	end
	running = true
	table.insert(threads, task.spawn(supervise))
	table.insert(threads, task.spawn(serve))
end

local function stop()
	running = false
	for _, t in ipairs(threads) do
		pcall(task.cancel, t)
	end
	threads = {}
	busy = false
end

-- widgets --------------------------------------------------------------------
local COL = {
	panel = Color3.fromRGB(24, 24, 29),
	card = Color3.fromRGB(36, 36, 43),
	idle = Color3.fromRGB(58, 58, 68),
	on = Color3.fromRGB(46, 122, 66),
	text = Color3.fromRGB(238, 238, 242),
	dim = Color3.fromRGB(140, 140, 152),
	bad = Color3.fromRGB(232, 110, 110),
}

local gui = Instance.new("ScreenGui")
gui.Name = "AutoCook"
gui.ResetOnSpawn = false
gui.Parent = (gethui and gethui()) or player:WaitForChild("PlayerGui")

local function corner(inst, r)
	local c = Instance.new("UICorner", inst)
	c.CornerRadius = UDim.new(0, r or 6)
	return c
end

local order = 0
local function rowFrame(parent)
	order += 1
	local f = Instance.new("Frame", parent)
	f.LayoutOrder = order
	f.Size = UDim2.new(1, 0, 0, 34)
	f.BackgroundColor3 = COL.card
	f.BorderSizePixel = 0
	corner(f, 8)
	local p = Instance.new("UIPadding", f)
	p.PaddingLeft, p.PaddingRight = UDim.new(0, 10), UDim.new(0, 8)
	return f
end

local function rowLabel(parent, text, color)
	local l = Instance.new("TextLabel", parent)
	l.Size = UDim2.new(1, -60, 1, 0)
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamMedium
	l.TextSize = 13
	l.TextColor3 = color or COL.text
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Text = text
	return l
end

-- shell ----------------------------------------------------------------------
local root = Instance.new("Frame", gui)
root.Size = UDim2.new(0, 220, 0, 0)
root.AutomaticSize = Enum.AutomaticSize.Y
root.Position = UDim2.fromScale(0.04, 0.3)
root.BackgroundColor3 = COL.panel
root.BorderSizePixel = 0
root.Active = true
root.Draggable = true -- ponytail: deprecated but works; no custom drag handler
corner(root, 10)

local layout = Instance.new("UIListLayout", root)
layout.SortOrder = Enum.SortOrder.LayoutOrder -- default is Name, which sorts by class name
layout.Padding = UDim.new(0, 6)
local rootPad = Instance.new("UIPadding", root)
rootPad.PaddingTop, rootPad.PaddingBottom = UDim.new(0, 10), UDim.new(0, 10)
rootPad.PaddingLeft, rootPad.PaddingRight = UDim.new(0, 10), UDim.new(0, 10)

local header = rowFrame(root)
rowLabel(header, "AUTO COOK").Font = Enum.Font.GothamBold

local closeBtn = Instance.new("TextButton", header)
closeBtn.AnchorPoint = Vector2.new(1, 0.5)
closeBtn.Position = UDim2.new(1, 0, 0.5, 0)
closeBtn.Size = UDim2.fromOffset(24, 24)
closeBtn.BackgroundColor3 = COL.card
closeBtn.BorderSizePixel = 0
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 14
closeBtn.TextColor3 = COL.dim
closeBtn.Text = "X"
corner(closeBtn)
closeBtn.MouseEnter:Connect(function()
	closeBtn.BackgroundColor3, closeBtn.TextColor3 = COL.bad, COL.text
end)
closeBtn.MouseLeave:Connect(function()
	closeBtn.BackgroundColor3, closeBtn.TextColor3 = COL.card, COL.dim
end)

local cookRow = rowFrame(root)
rowLabel(cookRow, "Cook (" .. KEY_TOGGLE.Name .. ")")

local switch = Instance.new("TextButton", cookRow)
switch.AnchorPoint = Vector2.new(1, 0.5)
switch.Position = UDim2.new(1, 0, 0.5, 0)
switch.Size = UDim2.fromOffset(52, 24)
switch.BackgroundColor3 = COL.idle
switch.BorderSizePixel = 0
switch.AutoButtonColor = false -- keeps the green ON state from being washed out
switch.Font = Enum.Font.GothamBold
switch.TextSize = 11
switch.TextColor3 = COL.text
switch.Text = "OFF"
corner(switch, 12)

local statusRow = rowFrame(root)
local status = rowLabel(statusRow, "idle", COL.dim)
status.Size = UDim2.new(1, 0, 1, 0)
status.TextSize = 12

local function toggle()
	if running then
		stop()
	else
		start()
	end
	switch.Text = running and "ON" or "OFF"
	switch.BackgroundColor3 = running and COL.on or COL.idle
end

switch.MouseButton1Click:Connect(toggle)

local input = UIS.InputBegan:Connect(function(io, typing)
	if not typing and io.KeyCode == KEY_TOGGLE then
		toggle()
	end
end)

-- The one line worth watching: how many slots are cooking and whether there is
-- anything left to feed them. "0 raw" is the answer to most "why did it stop".
local alive = true
task.spawn(function()
	while alive do
		local slots = mine()
		local cooking, raw, done = 0, 0, 0
		for _, hb in ipairs(slots) do
			if hb:GetAttribute("SlotState") ~= "Empty" then
				cooking += 1
			end
		end
		for _, tool in ipairs(player.Backpack:GetChildren()) do
			if tool:IsA("Tool") and isRaw(tool) then
				raw += 1
			elseif tool:IsA("Tool") and isCooked(tool) then
				done += 1
			end
		end
		if not freeSeat() then
			status.Text = "no free seat"
			status.TextColor3 = COL.bad
		else
			status.Text = running and ("%d/%d cooking · %d raw · %d cooked"):format(cooking, #slots, raw, done)
				or ("idle · %d slots · %d raw · %d cooked"):format(#slots, raw, done)
			status.TextColor3 = COL.dim
		end
		task.wait(1)
	end
end)

-- close ----------------------------------------------------------------------
local function shutdown()
	alive = false
	stop()
	input:Disconnect()
	gui:Destroy()
	if getgenv then
		getgenv().cookStop = nil
	end
end

closeBtn.MouseButton1Click:Connect(shutdown)

if getgenv then
	getgenv().cookStop = shutdown
end
