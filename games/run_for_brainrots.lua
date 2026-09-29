--[[ Run For Brainrots -- tp to each spawned item, hold E, run it back to base (94702395375549)

     FARM   : sit in the Divine area, tp to every SpawnedItem in turn, grab it, bank it
     TP     : jump to the area or the base by hand

     Executor only: the panel is Obsidian (panel_obsidian.lua), fetched with HttpGet, which
     Studio blocks. RightControl hides / shows it; the Unload button closes it.
     Stop: getgenv().tpRotsStop() ]]

-- config ---------------------------------------------------------------------
local AREA = Vector3.new(-5, 19, 5437) -- Divine area. Being here is what makes the folder stream in.
local BASE = Vector3.new(7, 19, -483) -- where a carried item is banked
local RARITY = "Divine" -- folder name under workspace.ItemSpawners
local SETTLE = 4 -- ping multiples to wait after a tp. Raise if grabs land but items don't bank.
local BANK = 1 -- seconds parked at base. Raise if items come back with you.
local DWELL = 1.5 -- seconds between sweeps when the folder is empty
local GRAB_TIMEOUT = 5 -- give up on one item after this; a prompt you can't win blocks the whole loop

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local ping = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]

if getgenv and getgenv().tpRotsStop then
	getgenv().tpRotsStop() -- re-running must not stack a second panel/loop
end

-- world ----------------------------------------------------------------------
local function hrp()
	local char = player.Character or player.CharacterAdded:Wait()
	return char:WaitForChild("HumanoidRootPart", 10)
end

-- Teleport is instant client-side; the server needs a round trip or two before it
-- agrees you're there, and it agrees with the prompt's range check, not with you.
local function tp(pos)
	local root = hrp()
	if not root then
		return false
	end
	root.CFrame = typeof(pos) == "Vector3" and CFrame.new(pos) or pos
	task.wait((ping:GetValue() * SETTLE) / 1000)
	while player.GameplayPaused do -- streaming pause: nothing around you exists yet
		task.wait(0.1)
	end
	return true
end

local function folder()
	local spawners = workspace:FindFirstChild("ItemSpawners")
	return spawners and spawners:FindFirstChild(RARITY)
end

-- farm -----------------------------------------------------------------------
local farming, gen = false, 0
local status = function() end -- replaced by the panel below

-- The prompt hangs off the model somewhere (RootPart, a Mesh); recursive search beats
-- naming the path, and it's also the streaming check: no prompt yet = not loaded yet.
local function grab(item, fold)
	local prompt = item:FindFirstChildWhichIsA("ProximityPrompt", true)
	if not prompt then
		return false
	end

	tp(item:GetPivot())

	-- fireproximityprompt returns nothing useful. The item leaving the folder is the
	-- server telling you it accepted the grab.
	local until_ = os.clock() + GRAB_TIMEOUT
	repeat
		pcall(fireproximityprompt, prompt)
		task.wait()
	until item.Parent ~= fold or os.clock() > until_ or not farming

	return item.Parent ~= fold
end

local function sweep()
	local fold = folder()
	if not fold then
		tp(AREA) -- not streamed in yet, or we drifted out of the zone
		return 0
	end

	local got = 0
	for _, item in ipairs(fold:GetChildren()) do
		if not farming then
			break
		end
		if grab(item, fold) then
			got += 1
			status(("banking %d"):format(got))
			tp(BASE)
			task.wait(BANK)
			tp(AREA)
		end
	end
	return got
end

local function setFarming(on)
	farming = on
	if not on then
		status("returning to base") -- the loop below does the tp on its way out
		return
	end

	gen += 1
	local mine = gen -- off-then-on inside one wait would otherwise leave two loops running
	task.spawn(function()
		tp(AREA)
		local total = 0
		while farming and gen == mine do
			local ok, got = pcall(sweep)
			if not ok then
				warn("[tprots]", got) -- items vanish mid-sweep; indexing a dead model throws
			else
				total += got
			end
			status(("farming - %d banked"):format(total))
			task.wait(DWELL)
		end
		-- Going home happens here, not in the off branch, so it can't fight a sweep
		-- that's still mid-teleport. gen check: a re-toggle already owns the character.
		if gen == mine then
			tp(BASE)
			status(("idle - %d banked"):format(total))
		end
	end)
end

-- gui ------------------------------------------------------------------------
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a
-- restyle is one file and not sixteen. Fetched here rather than installed by the loader,
-- so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, Library = panel({
	game = "TP for Brainrots", -- footer until the live name lands
	size = UDim2.fromOffset(440, 320),
})
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "house")
local Box = Tab:AddLeftGroupbox(RARITY, "box")

Box:AddToggle("Farm", {
	Text = "Farm " .. RARITY,
	Tooltip = "TP to each spawned item, grab it, bank it at base",
	Default = false,
	Callback = setFarming, -- SetValue re-fires this, so the off branch has to be re-entrant
})

Box:AddButton({ Text = "TP to area", Func = function()
	tp(AREA)
end })
Box:AddButton({ Text = "TP to base", Func = function()
	tp(BASE)
end })

local line = Box:AddLabel("Status: idle", true)
-- The farm thread has been through a task.wait, and a resumed thread lacks the capability
-- to write into the hidden GUI -- the first write lands, every later one throws and kills
-- the farm with the toggle still lit. So the loop leaves the message in an upvalue and a
-- Heartbeat connection (engine identity) writes it.
local pending
status = function(msg)
	pending = msg
end
Library:GiveSignal(game:GetService("RunService").Heartbeat:Connect(function()
	if pending then
		local msg = pending
		pending = nil
		line:SetText("Status: " .. msg)
	end
end))

-- Obsidian has no red close button, so the way out is a button (or the next paste).
Box:AddButton({ Text = "Unload", Risky = true, Func = function()
	Library:Unload()
end })

-- close ----------------------------------------------------------------------
-- Unload runs every OnUnload callback, then destroys the UI -- so Stop is just Unload.
Library:OnUnload(function()
	farming = false
	getgenv().tpRotsStop = nil
end)

getgenv().tpRotsStop = function()
	farming = false
	pcall(function()
		Library:Unload()
	end)
	getgenv().tpRotsStop = nil
end
