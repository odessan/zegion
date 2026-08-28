--[[ TP for Brainrots -- tp to each spawned item, hold E, run it back to base

     FARM   : sit in the Divine area, tp to every SpawnedItem in turn, grab it, bank it
     TP     : jump to the area or the base by hand

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl hides/shows it. Stop: getgenv().tpRotsStop() ]]

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
local WindUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()

local Window = WindUI:CreateWindow({
	Title = "TP for Brainrots",
	Icon = "solar:magic-stick-3-bold",
	Folder = "TPRots",
	Size = UDim2.fromOffset(420, 300),
	Topbar = { Height = 44, ButtonsType = "Mac" },
	OpenButton = { Title = "TP for Brainrots", Enabled = true, Draggable = true },
})
Window:SetToggleKey(Enum.KeyCode.RightControl)

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local Section = Tab:Section({ Title = RARITY, Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })

Section:Toggle({
	Title = "Farm " .. RARITY,
	Desc = "TP to each spawned item, grab it, bank it at base",
	Value = false,
	Callback = setFarming, -- :Set() re-fires this, so the off branch has to be re-entrant
})

Section:Button({ Title = "TP to area", Callback = function()
	tp(AREA)
end })
Section:Button({ Title = "TP to base", Callback = function()
	tp(BASE)
end })

local line = Section:Paragraph({ Title = "Status", Desc = "idle" })
status = function(msg)
	line:SetDesc(msg)
end

-- minimize -------------------------------------------------------------------
-- WindUI's Minimize hides the whole window and leaves only the floating open button,
-- which is easy to lose. Swapped for a shade: the body collapses, the topbar stays
-- put, and the same button rolls it back down. The farm keeps running either way.
local SHADE_PAD = 10 -- topbar height + window chrome; nudge if the shade clips

Window:DisableTopbarButtons({ "Minimize" }) -- before ours, it reuses the same slot

local shaded, fullSize = false, nil
Window:CreateTopbarButton("Shade", "minus", function()
	local main = Window.UIElements.Main
	shaded = not shaded

	if shaded then
		fullSize = main.Size -- read live, so a resized window comes back its own size
	end
	-- Topbar is the one child that stays. Going by name rather than by index keeps
	-- this working if WindUI reshuffles the body frames.
	for _, child in ipairs(main.Main:GetChildren()) do
		if child:IsA("GuiObject") and child.Name ~= "Topbar" then
			child.Visible = not shaded
		end
	end

	Window:SetSize(
		shaded and UDim2.new(main.Size.X.Scale, main.Size.X.Offset, 0, Window.Topbar.Height + SHADE_PAD)
			or fullSize
	)
end, 998, nil, Color3.fromHex("#F4C948")) -- same yellow the real Minimize used

-- close ----------------------------------------------------------------------
Window:OnDestroy(function()
	farming = false
	getgenv().tpRotsStop = nil
end)

getgenv().tpRotsStop = function()
	farming = false
	pcall(function()
		Window:Destroy()
	end)
	getgenv().tpRotsStop = nil
end
