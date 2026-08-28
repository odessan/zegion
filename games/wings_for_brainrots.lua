--[[ Wings for Brainrots -- +1 Wings for Brainrot (84332574190497)

     ZONES      : tick as many rarity pads as you like. They're worked HIGHEST TIER
                  FIRST every cycle, and a pad that just paid out gets worked again
                  before the loop drops to the next one down -- so a busy top zone
                  keeps your attention instead of being visited once per rotation.
     FARM ZONE  : TP onto the pad, grab its brainrots BEST FIRST, and when the carry
                  is full fly home and PlaceBest them into your plot slots.

                  "Best" is income per second, worked out the way the game does it:

                      ItemConfigurations.Items[name].Income * 1.125^(Level-1) * mutation

                  The 1.125 and the mutation table aren't in any module -- the growth
                  is read off the Earnings billboards in a dump (2M at Lvl 21 shows
                  21.1M, 30M at Lvl 8 shows 68.4M, 30M at Lvl 11 shows 97.4M; all
                  three land on 1.125 to four figures), and the multipliers are the
                  literal table inside ShopController. That matters because the carry
                  holds 1-6 brainrots: which ones you take IS the farm.
     FARM GOD   : the same loop pinned to the God pad, polled faster because the god
                  brainrot is on a timer and everyone else is racing you for it.
                  Turning one farm toggle on turns the other off -- they'd fight over
                  the character otherwise.
     UPGRADE    : buys the ticked stats through the game's own UpgradesController with
                  amount "Max", so one call spends whatever the money covers instead of
                  one level per round trip. Speed is what gates rebirth.
     REBIRTH    : fires RequestRebirth on an interval. The server refuses until max
                  speed clears RebirthConfig.GetCost, so refusals are the normal case.

     Carry state is read off Character.CarryModelsLocal, the folder the game's own
     CarryDisplayController creates -- one child per carried brainrot, gone at zero.
     That's the only client-side copy of the server's carry list, and the tutorial
     waits on the same folder, so it's the game's own definition of "am I holding one".

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl hides/shows it. The minus button rolls it up to a bare Zegion pill.
     Stop: getgenv().wingsRotsStop() ]]

-- config ---------------------------------------------------------------------
-- Pad centers, straight off a dump of workspace.ItemSpawners. These are BaseParts and
-- the map streams them out when you're far away, so they can't be read at panel-build
-- time -- which is the whole reason they're written down here instead of scanned.
-- Order is the tier order in ReplicatedStorage.Configs.RarityConfig.
local ZONES = {
	{ "Uncommon", Vector3.new(35, 0.5, 295.3) },
	{ "Rare", Vector3.new(31.7, -0.5, 516.2) },
	{ "Epic", Vector3.new(31.9, -0.5, 824.5) },
	{ "Legendary", Vector3.new(33.6, -0.5, 1253.2) },
	{ "Mythical", Vector3.new(31.3, -0.5, 1821.7) },
	{ "Secret", Vector3.new(32.2, -0.5, 2554.9) },
	{ "Celestial", Vector3.new(35.1, -0.5, 4051.9) },
	{ "Cosmic", Vector3.new(34.1, -0.5, 6135.2) },
	{ "God", Vector3.new(32.6, -0.5, 10007.4) },
}
local GOD = "God"
local DEFAULT_ZONES = { "Cosmic" }

-- Income growth per level, derived from the Earnings billboards (see the header). Not
-- in any module -- if a level's worth of income stops matching what the billboard says,
-- this is the number to re-derive.
local INCOME_GROWTH = 1.125

-- Verbatim from the table inside StarterPlayerScripts.ShopController, which is where the
-- shop prints "$x/s". MutationConfigurations holds only colors, so this is the one copy.
local MUTATION_MULT = {
	Normal = 1,
	Golden = 2,
	Diamond = 3,
	Galaxy = 4,
	Rainbow = 4.5,
	Lava = 5,
	Hacker = 7,
	UFO = 8,
	Easter = 9,
}

local LIFT = 15 -- studs above a pad center to land. The pads sit at ground level and
-- workspace.KillParts sweeps the corridor; land above, not in.
local SETTLE = 4 -- ping multiples to wait after a TP. Raise if grabs fire but nothing
-- lands: the prompt's range check runs against where the SERVER thinks you are.
local GRAB_TIMEOUT = 5 -- give up on one brainrot. A prompt you can't win blocks the sweep.
local BANK_TIMEOUT = 8 -- give up on a PlaceBest. Slots full looks exactly like this.
local BANK_RETRY = 0.5 -- seconds between PlaceBest fires while waiting for the carry to drop
local DWELL = 1.5 -- seconds between sweeps of a normal zone
local GOD_DWELL = 0.5 -- ...and of the God pad, which is empty until it isn't
local UPGRADE_EVERY = 3 -- seconds between upgrade rounds; this one spends money
local REBIRTH_EVERY = 5 -- seconds between rebirth attempts
local STATS = { "Speed", "Stamina", "Carry" } -- keys of ReplicatedStorage.Configs.UpgradesConfig
local DEFAULT_STATS = { "Speed" } -- Speed is the rebirth gate; Carry costs 500k a level
local KEY_TOGGLE = Enum.KeyCode.RightControl

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
local ping = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]

if getgenv and getgenv().wingsRotsStop then
	getgenv().wingsRotsStop() -- re-running must not stack a second panel/loop
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local UpgradeRequested = Remotes:WaitForChild("UpgradeRequested")
local PlaceBestRequested = Remotes:WaitForChild("PlaceBestRequested")
local RequestRebirth = ReplicatedStorage:WaitForChild("Events"):WaitForChild("RequestRebirth")

-- The game's own income table and number formatter. Requiring beats copying: the item
-- list is 100+ entries and every update adds to it.
local itemConfigs, numbers
pcall(function()
	itemConfigs = require(ReplicatedStorage.Modules.ItemConfigurations)
	numbers = require(ReplicatedStorage.Modules.NumberFormatter)
end)

local say = function() end -- replaced by the panel below

local function money(n)
	return numbers and numbers.Format(n) or tostring(math.floor(n))
end

-- world ----------------------------------------------------------------------
local anchor = {}
for _, z in ipairs(ZONES) do
	anchor[z[1]] = z[2] + Vector3.new(0, LIFT, 0)
end

local function hrp()
	local char = player.Character or player.CharacterAdded:Wait()
	return char:WaitForChild("HumanoidRootPart", 10)
end

-- Teleport is instant client-side; the server needs a round trip or two before it
-- agrees you're there, and streaming leaves you paused with nothing loaded around you.
local function tp(pos)
	local root = hrp()
	if not root then
		return false
	end
	root.CFrame = typeof(pos) == "Vector3" and CFrame.new(pos) or pos
	task.wait((ping:GetValue() * SETTLE) / 1000)
	while player.GameplayPaused do
		task.wait(0.1)
	end
	return true
end

local function pad(zone)
	local spawners = workspace:FindFirstChild("ItemSpawners")
	return spawners and spawners:FindFirstChild(zone)
end

-- One child per carried brainrot, or no folder at all when the carry is empty. Reads
-- 0 for about half a second after a respawn, before CarryDisplayController rebuilds it.
local function carrying()
	local char = player.Character
	local fold = char and char:FindFirstChild("CarryModelsLocal")
	return fold and #fold:GetChildren() or 0
end

-- Carry capacity is UpgradesConfig.Carry: Base 1 + 1 per level, i.e. the level itself.
local function capacity()
	local up = player:FindFirstChild("Upgrades")
	local lvl = up and up:FindFirstChild("CarryLevel")
	return lvl and lvl.Value or 1
end

-- The countdown on the pedestal screen is written by the server -- nothing on the client
-- computes it, and there's no spawn interval in any config. It only exists once the God
-- zone has streamed in, so it's a readout for while you're parked there, never a signal
-- for when to fly over. Found by shape: GOD_TIMER.Screen.SurfaceGui.Frame.Timer.
local function godTimer()
	local screen = workspace:FindFirstChild("GOD_TIMER")
	local label = screen and screen:FindFirstChild("Timer", true)
	return label and label.Text
end

local function plotSpot()
	local plots = workspace:FindFirstChild("Plots")
	local plot = plots and plots:FindFirstChild("Plot_" .. player.Name)
	if not plot then
		return nil -- every plot sits at its owner's own X; there is no sane fallback
	end
	-- The action-button banner is at the plot entrance at ground level; the plot model's
	-- own pivot is the middle of a three-storey building.
	local at = plot:FindFirstChild("ActionButtons") or plot
	return at:GetPivot().Position + Vector3.new(0, 5, 0)
end

-- farm -----------------------------------------------------------------------
-- Income per second, as the game computes it. Every input is an attribute the server
-- already wrote onto the model, so this needs nothing to have streamed but the model.
-- Anything missing from ItemConfigurations scores 0 and sorts last rather than blocking
-- the sweep -- a brainrot added by an update is still worth grabbing, just last.
local function worth(item)
	local data = itemConfigs and itemConfigs.GetItemData(item:GetAttribute("OriginalName") or item.Name)
	if not data or not data.Income then
		return 0
	end
	local level = item:GetAttribute("Level") or 1
	local mult = MUTATION_MULT[item:GetAttribute("Mutation") or "Normal"] or 1
	return data.Income * INCOME_GROWTH ^ (level - 1) * mult
end

-- Best first. The carry holds 1-6, so the order here decides what you actually keep.
local function spawnedIn(zone)
	local out = {}
	local fold = pad(zone)
	if fold then
		for _, item in ipairs(fold:GetChildren()) do
			if item:GetAttribute("IsSpawnedItem") then
				table.insert(out, { item = item, home = item.Parent, worth = worth(item) })
			end
		end
	end
	-- The god brainrot has its own pedestal in workspace root, and the dump caught it
	-- there with no IsSpawnedItem attribute -- it would never survive the filter above.
	-- Its prompt only exists while a god is actually up, so checking for one is the check.
	if zone == GOD then
		local pedestal = workspace:FindFirstChild("GOD_BRAINROT_SPAWN")
		if pedestal and pedestal:FindFirstChildWhichIsA("ProximityPrompt", true) then
			table.insert(out, { item = pedestal, home = pedestal.Parent, worth = worth(pedestal) })
		end
	end
	-- Scored once up front, not inside the comparator: worth() reads five attributes and
	-- a sort calls its comparator far more often than it has elements.
	table.sort(out, function(a, b)
		return a.worth > b.worth
	end)
	return out, fold
end

-- The prompt hangs off whichever part the model calls its own -- Mesh, Cube.035, Circle
-- -- so a recursive search beats naming the path, and it doubles as the streaming check:
-- no prompt yet means the model hasn't loaded, not that it can't be picked up.
local function grab(item, alive)
	local prompt = item:FindFirstChildWhichIsA("ProximityPrompt", true)
	if not prompt or not prompt.Enabled then
		return false
	end

	local before, parent0 = carrying(), item.Parent
	tp(item:GetPivot())

	-- fireproximityprompt returns nothing useful. The carry going up, or the model
	-- leaving the pad, is the server telling you it accepted the grab.
	local deadline = os.clock() + GRAB_TIMEOUT
	repeat
		pcall(fireproximityprompt, prompt)
		task.wait()
	until carrying() > before or item.Parent ~= parent0 or os.clock() > deadline or not alive()

	return carrying() > before
end

-- Walking home is the intended way to bank, but PlaceBest is the button the game's own
-- inventory offers and it does the slot picking for us. We fly to the plot anyway so a
-- server-side distance check, if there is one, can't quietly eat the carry.
local function bank()
	local held = carrying()
	if held == 0 then
		return
	end
	local home = plotSpot()
	if not home then
		say("no plot found - can't bank")
		return
	end

	say(("banking %d"):format(held))
	tp(home)
	local deadline = os.clock() + BANK_TIMEOUT
	repeat
		PlaceBestRequested:FireServer()
		task.wait(BANK_RETRY)
	until carrying() == 0 or os.clock() > deadline

	if carrying() > 0 then
		say(("%d stuck - plot slots full?"):format(carrying()))
	end
end

local function sweep(zone, alive)
	local items, fold = spawnedIn(zone)
	if not fold then
		tp(anchor[zone]) -- pad hasn't streamed in, or we drifted out of the zone
		return 0
	end

	local got = 0
	for _, entry in ipairs(items) do
		if not alive() then
			break
		end
		-- The list was sorted before the first grab, and a bank costs two teleports --
		-- plenty of time for someone else to take one. Skipping is free; not skipping
		-- costs the whole GRAB_TIMEOUT firing at a prompt nobody can win.
		if entry.item.Parent ~= entry.home then
			continue
		end
		if carrying() >= capacity() then
			bank()
			tp(anchor[zone])
		end
		say(("%s - %s ($%s/s)"):format(zone, entry.item.Name, money(entry.worth)))
		if grab(entry.item, alive) then
			got += 1
		end
	end

	if carrying() > 0 then
		bank()
		tp(anchor[zone])
	end
	return got
end

-- Which pads to work this cycle, best first. God, when it's on, is the whole list --
-- the point of that toggle is to sit on one pad. ZONES is written in ascending tier,
-- so walking it backwards is "highest value first" without a second ordering to keep
-- in sync.
local ticked, godOn, farmOn = {}, false, false

local function order()
	if godOn then
		return { GOD }
	end
	local list = {}
	for i = #ZONES, 1, -1 do
		local name = ZONES[i][1]
		if name ~= GOD and ticked[name] then
			table.insert(list, name)
		end
	end
	return list
end

-- One runner for both toggles. It re-reads order() every cycle, so re-ticking zones
-- takes effect at the next pad without restarting anything.
local gen, running = 0, false

local function setRunning(on)
	if on == running then
		return
	end
	running = on
	if not on then
		say("idle")
		return
	end

	gen += 1
	local mine = gen
	-- Bumping gen retires the previous thread; alive() is how the sweep and the grab
	-- deep inside it find out, instead of running on to the end of a pad we've left.
	local function alive()
		return running and gen == mine
	end

	task.spawn(function()
		local total = 0
		while alive() do
			local list = order()
			if #list == 0 then
				say("no zones ticked")
				task.wait(DWELL)
			end
			for _, zone in ipairs(list) do
				if not alive() then
					break
				end
				tp(anchor[zone])
				-- Work a paying pad again before dropping to the next one down. A zone
				-- that came up empty gets one look and we move on.
				local got
				repeat
					local ok, n = pcall(sweep, zone, alive)
					if not ok then
						warn("[wingsrots]", n) -- brainrots vanish mid-sweep; a dead model throws
						n = 0
					end
					got, total = n, total + n
					local clock = zone == GOD and godTimer()
					say(("%s - %d banked%s"):format(zone, total, clock and (" - " .. clock) or ""))
					task.wait(zone == GOD and GOD_DWELL or DWELL)
				until got == 0 or not alive()
			end
		end
		if gen == mine then
			say(("idle - %d banked"):format(total))
		end
	end)
end

-- boosts ---------------------------------------------------------------------
-- The game's own controller; :Upgrade(stat, "Max") makes it work out how many levels
-- the money covers. Reimplementing that means copying a geometric price curve.
local upgrades
pcall(function()
	upgrades = require(ReplicatedStorage.Modules.UpgradesController)
end)

local function upgrade(stat)
	if upgrades and pcall(upgrades.Upgrade, upgrades, stat, "Max") then
		return
	end
	UpgradeRequested:FireServer(stat, 1) -- Carry is capped at 6 and its "Max" path throws
end

-- One generation counter per loop, same reason as the farm: toggling off and on inside
-- a single interval otherwise leaves the sleeping thread alive next to the new one.
local function every(state, interval, body)
	state.gen += 1
	local mine = state.gen
	task.spawn(function()
		while state.on and state.gen == mine do
			pcall(body)
			task.wait(interval)
		end
	end)
end

local upgrader = { on = false, gen = 0 }
local rebirther = { on = false, gen = 0 }
local pickedStats = DEFAULT_STATS

-- gui ------------------------------------------------------------------------
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a
-- restyle is one file and not sixteen. Fetched here rather than installed by the loader,
-- so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Wings for Brainrots", -- fallback until the live name lands
	folder = "WingsRots", -- unchanged: renaming it orphans configs already saved in-game
	size = UDim2.fromOffset(440, 400),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local Farm = Tab:Section({ Title = "Farm", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })
local Boost = Tab:Section({ Title = "Boosts", Icon = "solar:double-alt-arrow-up-bold", Box = true, BoxBorder = true, Opened = true })

local zoneToggle, godToggle

local zoneNames = {}
for _, z in ipairs(ZONES) do
	if z[1] ~= GOD then
		table.insert(zoneNames, z[1])
	end
end
for _, name in ipairs(DEFAULT_ZONES) do
	ticked[name] = true
end

Farm:Dropdown({
	Title = "Zones",
	Desc = "Ticking only ticks. Worked highest tier first, best brainrot first.",
	Values = zoneNames,
	Value = DEFAULT_ZONES,
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		-- Rebuilt rather than patched: the callback hands over the whole selection, and
		-- the loop reads `ticked` live, so a re-tick lands at the next pad on its own.
		ticked = {}
		for _, name in ipairs(values) do
			ticked[name] = true
		end
	end,
})

zoneToggle = Farm:Toggle({
	Title = "Auto Farm Zone",
	Desc = "Work the ticked pads, best brainrot first, PlaceBest when the carry fills",
	Value = false,
	Callback = function(v) -- :Set() re-fires this, so both branches have to be re-entrant
		farmOn = v
		if v and godOn then
			godToggle:Set(false)
		end
		setRunning(farmOn or godOn)
	end,
})

godToggle = Farm:Toggle({
	Title = "Auto Farm God Zone",
	Desc = "Sit on the God pad and take the god brainrot the moment it lands",
	Value = false,
	Callback = function(v)
		godOn = v
		if v and farmOn then
			zoneToggle:Set(false)
		end
		setRunning(farmOn or godOn)
	end,
})

Farm:Button({ Title = "TP to zone", Callback = function()
	local list = order()
	tp(anchor[list[1] or DEFAULT_ZONES[1]]) -- the one the farm would work first
end })
Farm:Button({ Title = "TP to plot", Callback = function()
	local home = plotSpot()
	if home then
		tp(home)
	else
		say("no plot found")
	end
end })

Boost:Dropdown({
	Title = "Stats",
	Desc = "What Auto Upgrade buys. Speed is the one rebirth needs.",
	Values = STATS,
	Value = DEFAULT_STATS,
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		pickedStats = values
	end,
})

Boost:Toggle({
	Title = "Auto Upgrade",
	Desc = "Buys the ticked stats at max affordable amount",
	Value = false,
	Callback = function(v)
		upgrader.on = v
		if v then
			every(upgrader, UPGRADE_EVERY, function()
				for _, stat in ipairs(pickedStats) do
					upgrade(stat)
				end
			end)
		end
	end,
})

Boost:Toggle({
	Title = "Auto Rebirth",
	Desc = "Fires RequestRebirth on a timer; the server refuses until you qualify",
	Value = false,
	Callback = function(v)
		rebirther.on = v
		if v then
			every(rebirther, REBIRTH_EVERY, function()
				RequestRebirth:FireServer()
			end)
		end
	end,
})

local line = Farm:Paragraph({ Title = "Status", Desc = "idle" })
say = function(msg)
	line:SetDesc(msg)
end

-- close ----------------------------------------------------------------------
local function stopAll()
	farmOn, godOn = false, false
	upgrader.on, rebirther.on = false, false
	setRunning(false)
end

Window:OnDestroy(function()
	stopAll()
	getgenv().wingsRotsStop = nil
end)

getgenv().wingsRotsStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().wingsRotsStop = nil
end
