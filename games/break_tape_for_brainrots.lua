--[[ Slot Farm
     Two independent switches:
       Auto Brainrot - TP to each slot, press E to grab, TP back to base, repeat.
       Auto Collect  - touches every Floor*/Slots/Slot*/CollectButton/Touch part,
                       one every COOLDOWN seconds. Covers all floors, not just 1.

     Executor: paste and run.  Studio: LocalScript in StarterPlayerScripts.
     G toggles Auto Brainrot, H toggles Auto Collect. Stop: getgenv().slotStop() ]]

-- config ---------------------------------------------------------------------
local BASE = CFrame.new(-0.1328125, 1.54734516, -746.400085, -1, 0, 0, 0, 1, 0, 0, 0, -1)

local SLOTS = {
	CFrame.new(-41.5128746, 6.52133083, 880.239868, 1, 0, 0, 0, 1, 0, 0, 0, 1),
	CFrame.new(-19.7528706, 7.05116463, 893.559875, 1, 0, 0, 0, 1, 0, 0, 0, 1),
	CFrame.new(18.4971294, 6.24213839, 893.559875, 1, 0, 0, 0, 1, 0, 0, 0, 1),
	CFrame.new(38.1471252, 5.40019369, 881.169922, 1, 0, 0, 0, 1, 0, 0, 0, 1),
	CFrame.new(-0.802870274, 7.49990368, 878.519897, 1, 0, 0, 0, 1, 0, 0, 0, 1),
	CFrame.new(21.3571301, 5.40019369, 864.979858, 1, 0, 0, 0, 1, 0, 0, 0, 1),
	CFrame.new(-19.8128681, 7.05116463, 864.979858, 1, 0, 0, 0, 1, 0, 0, 0, 1),
}

-- ponytail: these waits are the whole tuning surface. A teleport is not instant on
-- the server -- it replicates a frame or two late, and a grab fired before the
-- server agrees you moved does nothing. Raise SETTLE if slots come up empty.
local SETTLE = 0.35 -- after a TP, before pressing E
local AFTER_GRAB = 0.25 -- after E, before TPing to base
local AT_BASE = 0.35 -- at base, before the next slot (deposit time)
local GRAB_RADIUS = 25 -- studs; how far to look for a prompt around you
local COOLDOWN = 2.5 -- seconds before every cash collect
-- The pad's Touched is connected server-side only, so the server has to actually
-- see us standing there -- a place-and-yank inside one network frame doesn't count.
-- Hold long enough for the position to replicate and the handler to run.
local TOUCH_HOLD = 0.6 -- seconds overlapping the pad, when collecting by teleport
-- "fire" = firetouchinterest. Instant, doesn't move you. Needs a TouchInterest
--          on the pad -- Dex shows these have one.
-- "tp"   = teleport onto the pad. Slower and moves you, but it's a real overlap.
-- "both" = fire, then tp.
-- Confirmed on this game: fire reaches the server-side Touched handler (10 of 120
-- pads paid out on a live test), so there is no reason to move the character.
-- Fire also means all 120 pads go in one frame and the whole plot collects at once.
local COLLECT_MODE = "fire"

local KEY_BRAINROT = Enum.KeyCode.G
local KEY_COLLECT = Enum.KeyCode.H

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local player = Players.LocalPlayer

if getgenv and getgenv().slotStop then
	getgenv().slotStop()
end

local alive = true
local autoBrainrot, autoCollect = false, false
local laps, grabs, collected = 0, 0, 0
local confirmed = 0 -- server-acknowledged collects (see ShowCashPopUp below)
local status = "idle"

-- receipt --------------------------------------------------------------------
-- ShowCashPopUp is server -> client: the game telling us to draw a +cash popup.
-- Firing it does nothing (it's the popup, not the payout) but LISTENING to it is
-- proof a collect actually landed. "collected" counts what we tried; "ok" counts
-- what the server paid out. If they diverge, the touch isn't registering.
-- Both connections here are held in `conns` and dropped by stop(): they outlive
-- gui:Destroy otherwise, and every re-paste arms another set against dead rows.
local conns = {}

local popup = game:GetService("ReplicatedStorage"):WaitForChild("Events", 5)
popup = popup and popup:FindFirstChild("ShowCashPopUp")
if popup then
	table.insert(
		conns,
		popup.OnClientEvent:Connect(function()
			confirmed = confirmed + 1
		end)
	)
else
	warn("[SlotFarm] no ShowCashPopUp -- collect confirmation is off")
end

-- teleport --------------------------------------------------------------------
local function hrp()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function tp(cf)
	local char = player.Character or player.CharacterAdded:Wait()
	local root = char:FindFirstChild("HumanoidRootPart") or char:WaitForChild("HumanoidRootPart", 5)
	if not root then
		return false
	end
	root.CFrame = cf
	return true
end

-- Both loops move the same character, so they take turns. ponytail: one global
-- flag, not a queue -- there are two loops and there will not be a third.
local busy = false
local function withBody(fn)
	while busy and alive do
		task.wait(0.05)
	end
	busy = true
	local ok, err = pcall(fn)
	busy = false
	if not ok then
		warn("[SlotFarm]", err)
	end
	return ok
end

-- grab ------------------------------------------------------------------------
-- Two paths on purpose. fireproximityprompt is the executor one: instant, ignores
-- HoldDuration, no line of sight needed. VirtualInputManager is the fallback that
-- works in Studio -- a real E press, so it obeys the hold time.
local hasFPP = typeof(fireproximityprompt) == "function"
local hasFTI = typeof(firetouchinterest) == "function"
local hasVIM, vim = pcall(game.GetService, game, "VirtualInputManager")

local function nearestPrompt()
	local root = hrp()
	if not root then
		return nil
	end
	local best, bestDist = nil, GRAB_RADIUS
	-- ponytail: full descendant scan per grab. 7 grabs per lap, not per frame.
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Enabled then
			local part = d.Parent
			if part and part:IsA("BasePart") then
				local dist = (part.Position - root.Position).Magnitude
				if dist < bestDist then
					best, bestDist = d, dist
				end
			end
		end
	end
	return best
end

local function grab()
	local prompt = nearestPrompt()
	if prompt and hasFPP then
		pcall(fireproximityprompt, prompt, 1)
		grabs = grabs + 1
		return true
	end
	if hasVIM then
		pcall(function()
			vim:SendKeyEvent(true, Enum.KeyCode.E, false, game)
			task.wait(0.6) -- long enough for a HoldDuration prompt
			vim:SendKeyEvent(false, Enum.KeyCode.E, false, game)
		end)
		grabs = grabs + 1
		return true
	end
	return false
end

-- collect ----------------------------------------------------------------------
-- Dex path is Plot_<you> > Floor1 > Slots > Slot1 > CollectButton > Touch, and the
-- same shape repeats for floors 2-10. Matching on the shape means new floors are
-- picked up the moment they exist -- no per-floor list to maintain.
--
-- Scoped to YOUR plot on purpose. Every plot on the server has the same pads, and
-- scanning all of them meant 2.5s each spent on other people's bases, which pay
-- nothing -- your own Slot1 came around once every few minutes.
local function myPlot()
	local exact = workspace:FindFirstChild("Plot_" .. player.Name, true)
	if exact then
		return exact
	end
	-- ponytail: name match only. If the game ever stops naming plots after the
	-- owner, read the owner value off the plot instead.
	for _, d in ipairs(workspace:GetChildren()) do
		if d.Name:find(player.Name, 1, true) then
			return d
		end
	end
	return nil
end

local plot = myPlot()
if plot then
	print("[SlotFarm] plot:", plot:GetFullName())
else
	warn("[SlotFarm] no plot named Plot_" .. player.Name .. " -- scanning all of workspace")
end

local function collectParts()
	local root = plot or workspace
	if plot and not plot.Parent then -- plot got rebuilt (rejoin, reset)
		plot = myPlot()
		root = plot or workspace
	end
	local out = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d.Name == "Touch" and d:IsA("BasePart") and d.Parent and d.Parent.Name == "CollectButton" then
			out[#out + 1] = d
		end
	end
	return out
end

-- Collecting by teleport: put the root INSIDE the pad so the overlap actually
-- fires Touched, hold briefly, then put it back where it was. Nothing to fake,
-- so nothing to silently swallow.
local function touch(part)
	local root = hrp()
	if not root then
		return false
	end
	if COLLECT_MODE ~= "tp" and hasFTI then
		local ok, err = pcall(firetouchinterest, root, part, 0)
		if ok then
			task.wait(0.05)
			pcall(firetouchinterest, root, part, 1)
		else
			warn("[SlotFarm] firetouchinterest:", err)
		end
		if COLLECT_MODE == "fire" then
			return ok
		end
	end
	local back = root.CFrame
	root.CFrame = part.CFrame -- overlapping, not hovering above
	task.wait(TOUCH_HOLD)
	root.CFrame = back
	return true
end

-- Set by the GUI below. Declared here so the collect loop can flip its own switch
-- back to OFF and have the panel agree.
local repaintCollect = function() end

-- loops --------------------------------------------------------------------------
task.spawn(function()
	while alive do
		if autoBrainrot then
			for i, slot in ipairs(SLOTS) do
				if not (alive and autoBrainrot) then
					break
				end
				status = "slot " .. i
				withBody(function()
					tp(slot)
					task.wait(SETTLE)
					grab()
					task.wait(AFTER_GRAB)
					status = "base"
					tp(BASE)
				end)
				task.wait(AT_BASE)
			end
			laps = laps + 1
		else
			task.wait(0.2)
		end
	end
end)

task.spawn(function()
	while alive do
		if autoCollect then
			-- Rescan every pass: floors unlock mid-session and the list goes stale.
			local parts = collectParts()
			-- Print the count every pass. "Nothing happened" is unanswerable without
			-- knowing whether the scan found zero pads or found them and they failed.
			print(("[SlotFarm] collect pass: %d pads"):format(#parts))
			if #parts == 0 then
				warn("[SlotFarm] no CollectButton/Touch parts under workspace -- run the scan snippet")
				task.wait(2)
			end
			-- A pass that pays out nothing means the plot is empty: no brainrots, or
			-- nothing has generated yet. Firing 120 touches every 2.5s at an empty
			-- plot is pure noise, so stop and say why rather than spin forever.
			local before = confirmed
			if COLLECT_MODE == "fire" then
				-- Nothing moves, so every pad goes in the same frame and COOLDOWN
				-- becomes a pause between whole passes instead of between pads.
				for _, part in ipairs(parts) do
					if part.Parent and touch(part) then
						collected = collected + 1
					end
				end
				task.wait(COOLDOWN)
			else
				-- tp/both: one body, one pad at a time.
				for _, part in ipairs(parts) do
					if not (alive and autoCollect) then
						break
					end
					task.wait(COOLDOWN)
					if autoCollect and part.Parent then
						if withBody(function()
							touch(part)
						end) then
							collected = collected + 1
						end
					end
				end
			end
			if confirmed == before and #parts > 0 then
				autoCollect = false
				repaintCollect()
				warn("[SlotFarm] no cash collected this pass -- plot is empty. Auto Collect OFF.")
			end
		else
			task.wait(0.2)
		end
	end
end)

-- gui -----------------------------------------------------------------------------
local BG = Color3.fromRGB(28, 28, 32)
local ROW = Color3.fromRGB(40, 40, 46)
local ON_C = Color3.fromRGB(38, 120, 60)
local TXT = Color3.fromRGB(235, 235, 235)

local gui = Instance.new("ScreenGui")
gui.Name = "SlotFarm"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(230, 132)
panel.Position = UDim2.new(0.5, -115, 0, 12) -- top center
panel.BackgroundColor3 = BG
panel.BorderSizePixel = 0
panel.Active = true
panel.Draggable = true -- ponytail: deprecated but one line; swap for InputBegan drag if it breaks
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -34, 0, 26)
title.Position = UDim2.fromOffset(10, 4)
title.BackgroundTransparency = 1
title.TextColor3 = TXT
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "SLOT FARM"
title.Parent = panel

local x = Instance.new("TextButton")
x.Size = UDim2.fromOffset(22, 22)
x.Position = UDim2.new(1, -28, 0, 6)
x.BackgroundColor3 = Color3.fromRGB(120, 40, 44)
x.TextColor3 = Color3.fromRGB(240, 230, 230)
x.Font = Enum.Font.GothamBold
x.TextSize = 13
x.Text = "X"
x.AutoButtonColor = false
x.Parent = panel
Instance.new("UICorner", x).CornerRadius = UDim.new(0, 4)

-- One row = label + ON/OFF switch. Returns a setter so the key binding and the
-- click go through the same path.
local function row(y, label, get, set)
	local f = Instance.new("Frame")
	f.Size = UDim2.new(1, -20, 0, 28)
	f.Position = UDim2.fromOffset(10, y)
	f.BackgroundColor3 = ROW
	f.BorderSizePixel = 0
	f.Parent = panel
	Instance.new("UICorner", f).CornerRadius = UDim.new(0, 6)

	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, -66, 1, 0)
	l.Position = UDim2.fromOffset(10, 0)
	l.BackgroundTransparency = 1
	l.TextColor3 = TXT
	l.Font = Enum.Font.Gotham
	l.TextSize = 12
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = label
	l.Parent = f

	local sw = Instance.new("TextButton")
	sw.Size = UDim2.fromOffset(48, 20)
	sw.Position = UDim2.new(1, -54, 0, 4)
	sw.BackgroundColor3 = ROW
	sw.TextColor3 = TXT
	sw.Font = Enum.Font.GothamBold
	sw.TextSize = 11
	sw.AutoButtonColor = false
	sw.Text = "OFF"
	sw.Parent = f
	Instance.new("UICorner", sw).CornerRadius = UDim.new(0, 5)

	local function paint()
		sw.Text = get() and "ON" or "OFF"
		sw.BackgroundColor3 = get() and ON_C or Color3.fromRGB(58, 58, 66)
	end
	sw.MouseButton1Click:Connect(function()
		set(not get())
		paint()
	end)
	paint()
	return paint
end

local paintBrainrot = row(36, "Auto Brainrot  (G)", function()
	return autoBrainrot
end, function(v)
	autoBrainrot = v
end)

local paintCollect = row(68, "Auto Collect Cash  (H)", function()
	return autoCollect
end, function(v)
	autoCollect = v
end)

repaintCollect = paintCollect

local stat = Instance.new("TextLabel")
stat.Size = UDim2.new(1, -20, 0, 24)
stat.Position = UDim2.fromOffset(10, 100)
stat.BackgroundTransparency = 1
stat.TextColor3 = Color3.fromRGB(150, 150, 160)
stat.Font = Enum.Font.Gotham
stat.TextSize = 11
stat.TextXAlignment = Enum.TextXAlignment.Left
stat.Text = "idle"
stat.Parent = panel

table.insert(
	conns,
	UIS.InputBegan:Connect(function(input, typing)
		if typing then
			return
		end
		if input.KeyCode == KEY_BRAINROT then
			autoBrainrot = not autoBrainrot
			paintBrainrot()
		elseif input.KeyCode == KEY_COLLECT then
			autoCollect = not autoCollect
			paintCollect()
		end
	end)
)

-- Counters in the panel, so "is it actually doing anything?" is answerable at a glance.
task.spawn(function()
	while alive do
		stat.Text = ("laps %d  grabs %d  cash %d/%d"):format(laps, grabs, confirmed, collected)
		task.wait(0.3)
	end
end)

local function stop()
	alive, autoBrainrot, autoCollect = false, false, false
	for _, c in ipairs(conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(conns)
	pcall(function()
		gui:Destroy()
	end)
	if getgenv then
		getgenv().slotStop = nil -- or the next paste calls a stop for a destroyed gui
	end
	print(("[SlotFarm] stopped -- %d laps, %d grabs, %d/%d collects confirmed"):format(laps, grabs, confirmed, collected))
end

x.MouseButton1Click:Connect(stop)

if getgenv then
	getgenv().slotStop = stop
end

print(("[SlotFarm] ready -- grab via %s, collect via %s"):format(
	hasFPP and "fireproximityprompt" or (hasVIM and "VirtualInputManager E" or "NOTHING"),
	COLLECT_MODE .. (COLLECT_MODE ~= "tp" and not hasFTI and " (no firetouchinterest -- tp only)" or "")
))