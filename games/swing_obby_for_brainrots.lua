--[[ Swing Obby for Brainrots -- take the richest brainrot in the top zone, bank it

     FARM  : one brainrot per lap. Pick the richest one in the top zone, tp onto it,
             grab it, tp to base -- arriving banks it -- and go again.
     ZONE  : Auto Farm Zone works one zone -- 14 today, highest income in it first.
             When a higher one unlocks, type its number in and grab a fresh park spot
             with pivot_tp.
     RARITY: Auto Farm Rarity hunts the ticked rarities in ANY zone, highest income
             first. It REPLACES the zone filter rather than narrowing it: rarity is
             spread across every zone (a Legendary showed up in zone 9), so asking for
             both at once usually asks for something that isn't up. Income picks between
             the ticked ones either way -- a Divine that pays less than the Ancient
             beside it isn't the one you want, since Modules.BrainrotInfo scales income
             by level and rank on top of the rarity's base. One farm at a time: turning
             either on turns the other off.
     VIP   : zone 15 is skipped by both farms -- it's the pass-only zone and its
             brainrots are the richest on the server, so the rarity farm would head
             straight there and time out every lap. SKIP_VIP = false if you have it.
     TP    : jump to the zone or to base by hand.

     Brainrots live in workspace.ActiveBrainrots, one ServerHitbox part each, and every
     part carries the whole row as attributes -- Name, Zone, Income, Rarity, Mutation,
     Status, SpawnCFrame. So the pick needs nothing to have streamed in: read the list
     off the attributes, then teleport straight onto the winner. The zone park spot is
     only where we wait when the zone has nothing left to take.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl hides/shows it. Stop: getgenv().swingRotsStop() ]]

-- config ---------------------------------------------------------------------
local ZONE = 14 -- the top zone today. Every brainrot carries its own Zone attribute,
-- so this number IS the filter -- there's no zone table to keep in sync. The Zone row
-- in the panel overrides it live.
local ZONE_AT = Vector3.new(2070, 60, -37404) -- where to park while the zone is empty
local BASE = Vector3.new(132, -10, -69) -- where a carried brainrot is banked

local VIP_ZONE = 15 -- Modules.BrainrotInfo.VIP_ZONE. It gets its own tier and rank rolls
-- (GetRandomTier hands zone 15 a flat 1.3 spread and GetRandomRank a x5), so it is where
-- the fattest brainrots on the server sit -- and the rarity farm would walk straight into
-- it every lap. Skipped by default because you can't get in without the pass; flip
-- SKIP_VIP off if you own it and the whole zone opens up.
local SKIP_VIP = true

-- Modules.BrainrotInfo.RarityOrder, low to high -- the same string the server writes
-- into each part's Rarity attribute, so this list is the dropdown AND the filter.
local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret", "Ancient", "Divine" }
local DEFAULT_RARITIES = { "Secret", "Ancient", "Divine" }

local WILD = "Wild" -- Status of a brainrot nobody has taken yet. Anything else is
-- already someone's, and firing at it burns a whole GRAB_TIMEOUT for nothing.

local SETTLE = 4 -- ping multiples to wait after a tp. Raise if grabs fire but nothing
-- lands: the pickup's range check runs against where the SERVER thinks you are.
local GRAB_TIMEOUT = 5 -- give up on one brainrot. One you can't win blocks the lap.
local DEPOSIT = 0.2 -- seconds parked at base. The bank fires the moment the server sees
-- you standing there, which the tp below has already waited out -- this is slack for a
-- ping spike, nothing more. Raise it only if one ever comes back with you.
local DWELL = 1.5 -- seconds between looks when the zone has nothing to take

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local ping = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]

if getgenv and getgenv().swingRotsStop then
	getgenv().swingRotsStop() -- re-running must not stack a second panel/loop
end

local say = function() end -- replaced by the panel below

-- Income is a raw number in the attribute (51021862484) and the status line has room
-- for about six characters of it.
local UNITS = { "", "K", "M", "B", "T", "Qa", "Qi" }
local function money(n)
	local i = 1
	while n >= 1000 and i < #UNITS do
		n, i = n / 1000, i + 1
	end
	return ("%.4g%s"):format(n, UNITS[i])
end
assert(money(0) == "0", "no suffix below a thousand")
assert(money(51021862484) == "51.02B", "billions read as B")
assert(money(2.5e18) == "2.5Qi", "the table goes as far as Qi")

-- world ----------------------------------------------------------------------
local function hrp()
	local char = player.Character or player.CharacterAdded:Wait()
	return char:WaitForChild("HumanoidRootPart", 10)
end

-- Teleport is instant client-side; the server needs a round trip or two before it
-- agrees you're there, and it agrees with the pickup's range check, not with you.
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

-- farm -----------------------------------------------------------------------
local zone = ZONE -- live: the Zone row writes this
local wanted = {} -- live: the Rarity dropdown writes this
-- Two farms, one runner. Which one is on IS the filter -- see takeable() -- and the
-- toggles turn each other off, because they'd fight over the character otherwise.
local zoneOn, rarityOn = false, false

-- WindUI hands a multi-select back as a LIST of names in some builds and as a
-- name -> true MAP in others, and which one you get depends on the library the panel
-- fetched, not on anything here. Reading it as a list when it's a map leaves `wanted`
-- empty, and an empty want-set with the toggle on takes nothing at all -- which is
-- exactly what it looks like when "target rarity doesn't work". Take whichever side of
-- the pair is the string and stop caring which build is in front of us.
local function ticked(values)
	local set = {}
	for k, v in pairs(values) do
		if type(v) == "string" then
			set[v] = true -- list form: 1 -> "Secret"
		elseif v then
			set[k] = true -- map form: "Secret" -> true
		end
	end
	return set
end
assert(ticked({ "Secret", "Divine" }).Divine, "the list form ticks its names")
assert(ticked({ Secret = true }).Secret, "the map form ticks its keys")
assert(not ticked({ Secret = false }).Secret, "an unticked key in the map form stays off")

-- In module order rather than hash order, so the panel reads Secret, Ancient, Divine
-- every time instead of a different shuffle each tick.
local function label(set)
	local out = {}
	for _, name in ipairs(RARITIES) do
		if set[name] then
			table.insert(out, name)
		end
	end
	return #out > 0 and table.concat(out, ", ") or "nothing"
end
assert(label({ Divine = true, Common = true }) == "Common, Divine", "listed low to high")
assert(label({}) == "nothing", "an empty tick set says so rather than reading blank")
local farming, gen = false, 0

-- Where a brainrot is, without needing it to have streamed in. Falls back to the pivot
-- for anything the server spawned without the attribute.
local function at(entry)
	return entry:GetAttribute("SpawnCFrame") or entry:GetPivot()
end

-- Zone and rarity are ALTERNATIVES, not a pair. Rarity is spread across every zone --
-- the Legendary in the dump sat in zone 9, not 14 -- so "Legendary AND zone 14" asks for
-- something that usually isn't up, and the loop parks looking like it's broken. The
-- rarity farm hunts its rarities wherever they are; the zone farm works one zone. Either
-- way income picks inside the filter, and Wild gates both: anything else is already taken.
--
-- Zone comes back as a number in the dump, but tonumber costs nothing and survives it
-- being written as a string. Rarity is the plain Modules.BrainrotInfo string, so one an
-- update adds under a rarity nobody ticked is skipped rather than an error.
local function takeable(entry)
	if entry:GetAttribute("Status") ~= WILD then
		return false
	end
	-- Ahead of both farms, not inside one: the zone farm only reaches VIP if you type 15,
	-- but the rarity farm ignores zones entirely and would beeline for it every lap.
	if SKIP_VIP and tonumber(entry:GetAttribute("Zone")) == VIP_ZONE then
		return false
	end
	if rarityOn then
		return wanted[entry:GetAttribute("Rarity")] == true
	end
	return tonumber(entry:GetAttribute("Zone")) == zone
end

-- Richest of those. Income is what the farm is actually for, so it stays the sort even
-- when rarities are ticked -- rarity narrows the field, income picks out of it.
local function best(fold)
	local top, topWorth
	for _, entry in ipairs(fold:GetChildren()) do
		if takeable(entry) then
			local worth = entry:GetAttribute("Income") or 0
			if not topWorth or worth > topWorth then
				top, topWorth = entry, worth
			end
		end
	end
	return top, topWorth or 0
end

-- The server accepting the grab shows up two ways, and which one this game uses isn't
-- in the dump this was written from: the part leaves the folder, or its Status stops
-- reading Wild. Either one is the server telling you it took.
local function taken(entry, fold, status0)
	return entry.Parent ~= fold or entry:GetAttribute("Status") ~= status0
end

local function grab(entry, fold)
	local status0 = entry:GetAttribute("Status")
	local cf = at(entry)
	if not tp(cf) then
		return false
	end

	-- Prompt AND touch every pass, rather than picking one. Confirmed working in game as
	-- a pair; which half does the work was never pinned down, and firing the one the
	-- game ignores costs a function call. Don't drop either without spy.lua saying which.
	local box = entry:IsA("BasePart") and entry or entry:FindFirstChildWhichIsA("BasePart", true)
	local deadline = os.clock() + GRAB_TIMEOUT
	repeat
		local root = hrp()
		root.CFrame = cf -- these sit on obby platforms; without the re-pin you slide off
		-- mid-grab and the range check starts failing halfway through the timeout
		local prompt = entry:FindFirstChildWhichIsA("ProximityPrompt", true)
		if prompt then
			pcall(fireproximityprompt, prompt)
		end
		if box and firetouchinterest then
			pcall(firetouchinterest, root, box, 0)
			pcall(firetouchinterest, root, box, 1)
		end
		task.wait()
	until taken(entry, fold, status0) or os.clock() > deadline or not farming

	return taken(entry, fold, status0)
end

-- One brainrot: zone -> grab -> base. Returns whether anything was banked, which is
-- what decides between going straight back for the next one and waiting out a DWELL.
local function lap()
	local fold = workspace:FindFirstChild("ActiveBrainrots")
	if not fold then
		say("no ActiveBrainrots -- wrong game?")
		return false
	end

	local target, worth = best(fold)
	if not target then
		-- Naming the filter that came up empty is the difference between "waiting for a
		-- spawn" and "you asked for something that never spawns", which look identical.
		local why = ("zone %d empty"):format(zone)
		if rarityOn then
			why = "no " .. label(wanted) .. " up"
		elseif SKIP_VIP and zone == VIP_ZONE then
			why = ("zone %d is VIP -- skipped, see SKIP_VIP"):format(VIP_ZONE)
		end
		say(why)
		tp(ZONE_AT) -- park in the zone and wait for the next spawn
		return false
	end

	say(("%s %s ($%s/s)"):format(
		target:GetAttribute("Rarity") or "?",
		target:GetAttribute("Name") or target.Name,
		money(worth)
	))
	if not grab(target, fold) then
		return false
	end

	say("banking")
	tp(BASE)
	task.wait(DEPOSIT) -- arriving IS the deposit; this is just slack, see the config note
	return true
end

-- One runner for both toggles: it re-reads the filter every lap, so switching farms
-- takes effect at the next brainrot without restarting anything. The guard is what makes
-- the switch seamless -- turning the other one off calls in here with `true` still true,
-- and without it that would retire the running loop mid-teleport for no reason.
local function setFarming(on)
	if on == farming then
		return
	end
	farming = on
	if not on then
		say("returning to base") -- the loop below does the tp on its way out
		return
	end

	gen += 1
	local mine = gen -- off-then-on inside one wait would otherwise leave two loops running
	task.spawn(function()
		local total = 0
		while farming and gen == mine do
			local ok, got = pcall(lap)
			if not ok then
				warn("[swingrots]", got) -- brainrots vanish mid-lap; a dead part throws
			elseif got then
				total += 1
				say(("farming - %d banked"):format(total))
			end
			if not (ok and got) then
				task.wait(DWELL)
			end
		end
		-- Going home happens here, not in the off branch, so it can't fight a lap that's
		-- still mid-teleport. gen check: a re-toggle already owns the character.
		if gen == mine then
			tp(BASE)
			say(("idle - %d banked"):format(total))
		end
	end)
end

-- gui ------------------------------------------------------------------------
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a
-- restyle is one file and not sixteen. Fetched here rather than installed by the loader,
-- so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Swing Obby for Brainrots", -- fallback until the live name lands
	folder = "SwingRots",
	size = UDim2.fromOffset(420, 340),
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local Section = Tab:Section({ Title = "Farm", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })

-- Each filter sits directly above the toggle that uses it, so the panel reads as two
-- farms rather than four unrelated rows. Declared first: each callback turns the other
-- toggle off, and :Set() needs the handle to exist before the click can happen.
local zoneToggle, rarityToggle

Section:Input({
	Title = "Zone",
	Desc = "Which zone Auto Farm Zone works. 14 is the top one today.",
	Value = tostring(ZONE),
	Placeholder = tostring(ZONE),
	Callback = function(v)
		zone = tonumber(v) or ZONE -- a half-typed number shouldn't empty the zone
	end,
})

zoneToggle = Section:Toggle({
	Title = "Auto Farm Zone",
	Desc = "Highest income in the zone first, one at a time, banked at base",
	Value = false,
	Callback = function(v) -- :Set() re-fires this, so both branches have to be re-entrant
		zoneOn = v
		if v and rarityOn then
			rarityToggle:Set(false)
		end
		setFarming(zoneOn or rarityOn)
	end,
})

wanted = ticked(DEFAULT_RARITIES)

Section:Dropdown({
	Title = "Rarity",
	Desc = "What Auto Farm Rarity hunts. Richest of the ticked ones wins, not the rarest.",
	Values = RARITIES,
	Value = DEFAULT_RARITIES,
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		-- Rebuilt rather than patched: the callback hands over the whole selection, and
		-- the loop reads `wanted` live, so a re-tick lands on the next lap on its own.
		wanted = ticked(values)
		if rarityOn then
			say("hunting " .. label(wanted)) -- the tick is only visible here
		end
	end,
})

rarityToggle = Section:Toggle({
	Title = "Auto Farm Rarity",
	Desc = "Highest income of the ticked rarities, in ANY zone -- Zone stops applying",
	Value = false,
	Callback = function(v)
		rarityOn = v
		if v and zoneOn then
			zoneToggle:Set(false)
		end
		if v then
			say("hunting " .. label(wanted))
		end
		setFarming(zoneOn or rarityOn)
	end,
})

Section:Button({ Title = "TP to zone", Callback = function()
	tp(ZONE_AT)
end })
Section:Button({ Title = "TP to base", Callback = function()
	tp(BASE)
end })

local line = Section:Paragraph({ Title = "Status", Desc = "idle" })
say = function(msg)
	line:SetDesc(msg)
end

-- close ----------------------------------------------------------------------
-- Both toggle flags go with it: the loop reads `farming`, but a leftover zoneOn/rarityOn
-- would have the next paste's panel come up claiming a farm that isn't running.
local function stopAll()
	zoneOn, rarityOn = false, false
	farming = false
end

Window:OnDestroy(function()
	stopAll()
	getgenv().swingRotsStop = nil
end)

getgenv().swingRotsStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().swingRotsStop = nil
end
