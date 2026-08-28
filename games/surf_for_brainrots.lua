--[[ Surf for Brainrots -- Surf for Brainrots (98916904742148)

     RARITY     : tick which lucky blocks are worth a trip. This is the only "where"
                  control the game needs -- each of the ten islands spawns ONE rarity
                  (workspace.Map.SpawnParts is literally Common..Transcendent, one
                  folder each), so ticking a rarity IS ticking its zone. The farm
                  teleports to the block, never to the island, so there is nothing a
                  separate zone list could say that this doesn't.
                  Exclusives are the one exception -- a world mutation can drop one on
                  any island -- which is why they get their own tick.
     AUTO FARM  : steal matching blocks BEST FIRST, teleporting back to your plot after
                  each one before going out for the next. Nothing is placed and nothing
                  is opened.

                  There is NO trip back to base here, because there is nothing at base
                  to make the trip for. This game has no bank: no deposit pad, no stow
                  prompt -- the only prompts on a plot are each stand's Place, Sell and
                  Pick Up. A stolen block is in Inventory.Friends the instant the steal
                  lands (it's where the gift and sell screens look up what you're
                  holding), and it floats over your head until you Place it on a stand
                  or Drop it. Held and banked are the same state. The tutorial's "Run
                  back to base!" step is just walking home so you can Place.

                  So the farm fills the carry and parks at your plot -- capacity is
                  CarryLevel + 1, hard max 9. AUTO UPGRADE CARRY is the only lever that
                  raises it; the only way to empty it is to place or open some yourself.
                  It re-tests every 10s and picks straight up when you free a slot.

                  AUTO FARM and SNIPE OG+ are meant to run together. They share one
                  claim on the character, so whichever gets there first drives and the
                  other waits its turn -- they can't teleport each other mid-grab.
     SNIPE OG+  : listens on Live.Friends.ChildAdded and goes the moment an OG, Divine,
                  Transcendent or Exclusive appears. Those tiers spawn on a timer rather
                  than continuously (the island signs read "OG in 08:11"), so the farm's
                  own sweep can miss the window -- this doesn't. Works with AUTO FARM
                  off; it ignores the rarity ticks and the carry only.
     COLLECT    : touches every EARNING cash pad on your plot on a 5s beat, through
                  firetouchinterest, so it reaches every floor you own without moving
                  you. This is the Auto Collect gamepass, done by hand. Pads on floors
                  you haven't bought are skipped -- touching one asks to buy the floor
                  rather than paying out.
     SPEED      : Upgrade Speed 5 then Upgrade Speed -- bulk first, single mops up the
                  remainder. Speed is also the rebirth gate, so this feeds REBIRTH.
     BOOST/CARRY: Upgrade Boost (100 levels), Upgrade Carry Limit (8 levels, +1 block
                  per trip each). Both spend cash, so they run on a slow beat.
     REBIRTH    : fires only when Speed + PermSpeedBonus clears the next tier's
                  SpeedRequirement, read live off the game's own Rebirths table. Blind
                  spam would just be refused forty times a minute.

     Every rarity, mutation, price and requirement is REQUIRED off the game's own
     modules, never copied -- SharedModules.Shared and SharedModules.Database. An
     update that adds a tier or a mutation is picked up with no edit here.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl hides/shows it. Stop: getgenv().surfRotsStop() ]]

-- config ---------------------------------------------------------------------
local SETTLE = 4 -- ping multiples to wait after a TP before trusting the new position;
-- raise it if grabs time out on an island you've only just arrived at
local POLL = 0.2 -- beat between re-reads while waiting on the world
local DWELL = 1 -- seconds between sweeps
local GRAB_TIMEOUT = 3 -- seconds of firing one Steal prompt before calling it refused
local FIRE_EVERY = 0.2 -- beat between prompt fires inside one grab. NOT every frame:
-- the server answers a refused steal with an on-screen notification, so a frame-rate
-- loop buries the screen in "Reached maximum Carry Limit" at 60 a second. The prompt's
-- HoldDuration is 0.1, so this is still far faster than it needs to be
local GRAB_FAILS = 2 -- refusals in a row that mean the carry is full rather than that we
-- lost a race. The backstop for the notification below, in case its wording changes
local FULL_WAIT = 10 -- seconds before re-testing a full carry; each test costs two
-- refused grabs at GRAB_TIMEOUT apiece, so there's no point doing it on the DWELL beat
local DOOMED = 2 -- skip a block with fewer than this many seconds left on its despawn
-- timer -- the trip costs more than that and the grab would time out on an empty island
local SNIPE_WAIT = 6 -- seconds a sniped block is re-attempted while the farm holds the
-- character; blocks live ~100s, so there is room to queue behind one sweep

local COLLECT_EVERY = 5 -- seconds between cash pad sweeps
local SPEED_EVERY = 1 -- seconds between speed rounds; the server refuses when broke
local BOOST_EVERY = 3 -- seconds between boost attempts; this one spends money
local CARRY_EVERY = 5 -- seconds between carry attempts; so does this one, in millions
local REBIRTH_EVERY = 5 -- seconds between rebirth checks
local DATA_STALE = 3 -- seconds a Data: Get result is reused for. Every loop wants
-- CarryLevel or Cash and it's a RemoteFunction round trip, so it's read once and shared
local KEY_TOGGLE = Enum.KeyCode.RightControl

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService") -- only the shade uses this
local player = Players.LocalPlayer
local ping = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]

if getgenv and getgenv().surfRotsStop then
	getgenv().surfRotsStop() -- re-running must not stack a second panel/loop
end

local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local Remotes = SharedModules:WaitForChild("Network"):WaitForChild("Remotes")
local Live = workspace:WaitForChild("Live")
local Friends = Live:WaitForChild("Friends")

local UpgradeSpeed = Remotes:WaitForChild("Upgrade Speed")
local UpgradeSpeed5 = Remotes:WaitForChild("Upgrade Speed 5")
local UpgradeBoost = Remotes:WaitForChild("Upgrade Boost")
local UpgradeCarry = Remotes:WaitForChild("Upgrade Carry Limit")
local Rebirth = Remotes:WaitForChild("Rebirth")
local DataGet = Remotes:WaitForChild("Data: Get")
local Notify = Remotes:WaitForChild("Send Notification")

-- The game's own tables. Requiring beats copying: RarityOrders decides what "OG or
-- higher" means, Friends is 200+ entries and grows every update, and Rebirths is the
-- forty-tier speed ladder. None of it is worth keeping a second copy of in sync.
local Shared, Database
pcall(function()
	Shared = require(SharedModules.Shared)
	Database = require(SharedModules.Database)
end)
if not (Shared and Database) then
	return warn("[surfrots] SharedModules didn't load -- wrong game?")
end

local FriendsDB = Database.Friends
local Rebirths = Database.Rebirths

local say = function() end -- replaced by the panel below

-- world ----------------------------------------------------------------------
-- Rarity ladder, ascending, straight off the game's ordering table. Doubles as the
-- dropdown's list and as the sort key, so a tier added by an update shows up in both.
local RARITIES = {}
for rarity in pairs(Shared.RarityOrders) do
	table.insert(RARITIES, rarity)
end
table.sort(RARITIES, function(a, b)
	return Shared.RarityOrders[a] < Shared.RarityOrders[b]
end)

-- "OG or higher" as the game itself orders it: OG 9, Divine 10, Transcendent and
-- Exclusive 11. Named rather than written as 9 so it tracks a re-ordering.
local SNIPE_FLOOR = Shared.RarityOrders.OG

-- A spawned block carries an ID attribute keyed into Database.Friends. The name index
-- is the fallback for one that hasn't had its attributes replicated yet -- the model is
-- named for its display name, which is unique across the table.
local byName = {}
for _, entry in pairs(FriendsDB) do
	if entry.Name then
		byName[entry.Name] = entry
	end
end

local function friendData(model)
	local id = model:GetAttribute("ID")
	return (id and FriendsDB[tostring(id)]) or byName[model.Name]
end

local function hrp()
	local char = player.Character or player.CharacterAdded:Wait()
	return char:WaitForChild("HumanoidRootPart", 10)
end

-- Teleport is instant client-side; the server needs a round trip or two before it
-- agrees you're there, and streaming leaves you paused with nothing loaded around you.
-- The game teleports you the same way on spawn (StarterCharacterScripts.Spawn To Plot
-- writes HumanoidRootPart.CFrame outright), so there is nothing here it doesn't do.
local function tp(pos)
	local root = hrp()
	if not root then
		return false
	end
	root.CFrame = typeof(pos) == "Vector3" and CFrame.new(pos) or pos
	task.wait((ping:GetValue() * SETTLE) / 1000)
	while player.GameplayPaused do
		task.wait(POLL)
	end
	return true
end

local function myPlot()
	for _, plot in ipairs(workspace:WaitForChild("Plots"):GetChildren()) do
		local owner = plot:FindFirstChild("owner")
		if owner and owner.Value == player.Name then
			return plot
		end
	end
end

-- One shared read of the server's copy of you. Cash, CarryLevel, Speed and Rebirth are
-- wanted by four different loops on four different beats; without the cache they'd be
-- four RemoteFunction round trips a second between them.
local dataCache, dataAt = nil, 0

local function stats()
	if dataCache and os.clock() - dataAt < DATA_STALE then
		return dataCache
	end
	local ok, result = pcall(function()
		return DataGet:InvokeServer(player)
	end)
	if ok and typeof(result) == "table" then
		dataCache, dataAt = result, os.clock()
	end
	return dataCache
end

-- value ----------------------------------------------------------------------
-- Every lucky block is MoneyPerSecond 0 -- the payout is whatever it opens into -- so
-- rarity is the whole score, with the mutation multiplier as a tiebreak inside a tier.
-- getMutationMulti is the game's own: it stacks the base mutation with the event ones.
local function worth(model, entry)
	entry = entry or friendData(model)
	if not entry then
		return 0
	end
	local events = {}
	pcall(function()
		events = HttpService:JSONDecode(model:GetAttribute("event_mutations") or "[]")
	end)
	local mult = Shared.getMutationMulti(model:GetAttribute("mutation"), events) or 1
	return (Shared.RarityOrders[entry.Rarity] or 0) + (mult - 1) / 100
end

-- Seconds left before the server despawns it. Every spawned block carries `timer` as an
-- absolute server time, which is what the game's own Friends Timer script counts down.
local function lifeLeft(model)
	local timer = model:GetAttribute("timer")
	return timer and timer - workspace:GetServerTimeNow() or math.huge
end

-- Stealing does NOT reparent the block -- it stays in Live.Friends and gains CarryOwner,
-- which is how the game's own CarryFloat finds what to float over your head. So this one
-- attribute is both "is it still up for grabs" and "did my grab land".
local function heldCount()
	local n = 0
	for _, model in ipairs(Friends:GetChildren()) do
		if model:GetAttribute("CarryOwner") == player.UserId then
			n += 1
		end
	end
	return n
end

-- The carry limit announces itself. A steal the server turns down comes back as a
-- Send Notification reading "Reached maximum Carry Limit", which beats every way of
-- inferring it: no Data: Get round trip to go stale, no counting refused grabs, and it
-- lands on the FIRST rejection instead of after two full timeouts.
-- Cleared by the farm on a timer rather than by watching the held count, so freeing a
-- slot needs no bookkeeping here -- one refused grab every FULL_WAIT is the re-test.
local carryFull = false

local notifyConn = Notify.OnClientEvent:Connect(function(msg)
	if typeof(msg) == "string" and msg:find("Carry Limit") then
		carryFull = true
	end
end)

-- Home. There is no bank here, but a block on your head is stealable in the open and
-- your plot is where you'd place or open it, so the farm comes back between grabs.
local function goHome()
	local plot = myPlot()
	local base = plot and plot:FindFirstChild("Base")
	local pad = base and base:FindFirstChild("Teleport")
	if not pad then
		return false
	end
	return tp(pad.WorldCFrame)
end

-- The farm and the sniper both drive the character; let them run at once unclaimed and
-- they teleport each other mid-prompt and both time out. Returns whether it RAN, not
-- whether it succeeded -- a throw mid-sweep is the normal case (blocks despawn and
-- indexing a dead model errors) and the caller should carry on.
local busy = false

local function claim(fn)
	if busy then
		return false
	end
	busy = true
	local ok, err = pcall(fn)
	busy = false
	if not ok then
		warn("[surfrots]", err)
	end
	return true
end

-- farm -----------------------------------------------------------------------
local wanted = {} -- rarity -> true, live-read by the sweep

-- Returns true when the server gave it to us, false when it fired for the full timeout
-- and the block is still unclaimed, nil when there was nothing to fire at. The loop
-- also exits on SOMEONE ELSE's CarryOwner landing -- losing a race is not a refusal.
local function grab(model, alive)
	local prompt = model:FindFirstChild("RootPart")
	prompt = prompt and prompt:FindFirstChildWhichIsA("ProximityPrompt")
	if not prompt or not prompt.Enabled then
		return nil
	end

	tp(model:GetPivot())

	local deadline = os.clock() + GRAB_TIMEOUT
	repeat
		pcall(fireproximityprompt, prompt)
		task.wait(FIRE_EVERY)
	until model:GetAttribute("CarryOwner")
		or model.Parent ~= Friends
		or carryFull -- the server said no; firing again just repeats the notification
		or os.clock() > deadline
		or not alive()

	return model:GetAttribute("CarryOwner") == player.UserId
end

-- Unclaimed matching blocks, best first. Scored once up front rather than inside the
-- comparator: worth() decodes a JSON attribute and a sort calls its comparator far more
-- often than it has elements.
local function candidates(match)
	local out = {}
	for _, model in ipairs(Friends:GetChildren()) do
		local entry = model:IsA("Model") and not model:GetAttribute("CarryOwner") and friendData(model)
		if entry and match(entry) and lifeLeft(model) > DOOMED then
			table.insert(out, { model = model, entry = entry, worth = worth(model, entry) })
		end
	end
	table.sort(out, function(a, b)
		return a.worth > b.worth
	end)
	return out
end

local function ticked(entry)
	return wanted[entry.Rarity] == true
end

local function snipeworthy(entry)
	return (Shared.RarityOrders[entry.Rarity] or 0) >= SNIPE_FLOOR
end

-- One pass: take matching blocks best first until the server stops handing them over.
--
-- The cap is NOT read off your save. CarryLevel + 1 is the real number, but reading it
-- means a Data: Get round trip, and a lookup that fails or hasn't landed reads as 1 --
-- which parks a nine-slot carry after a single block and looks exactly like the script
-- is stuck holding one. Two refused grabs in a row IS the cap, and that's the server's
-- own answer instead of a guess at it.
local function sweep(alive)
	local got, misses = 0, 0

	for _, found in ipairs(candidates(ticked)) do
		if not alive() or carryFull then
			break
		end
		-- The list was sorted before the first grab and each grab costs a teleport --
		-- plenty of time for someone else to take one. Skipping is free; not skipping
		-- costs the whole GRAB_TIMEOUT firing at a prompt nobody can win.
		if not found.model:GetAttribute("CarryOwner") then
			say(("%s (%s)"):format(found.entry.Name, found.entry.Rarity))
			local took = grab(found.model, alive)
			if took == true then
				got, misses = got + 1, 0
				-- Straight home with it before going back out. Costs a teleport per
				-- block; what it buys is that the block is never sat on your head in an
				-- open zone while the next grab runs.
				say(("got %s - heading home"):format(found.entry.Name))
				goHome()
			elseif took == false then
				-- nil is "no prompt to fire at", i.e. it hasn't streamed in -- not the
				-- same signal as the server turning a grab down, so it isn't counted.
				misses += 1
				if misses >= GRAB_FAILS then
					return got, true
				end
			end
		end
	end
	return got, carryFull
end

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
	-- deep inside it find out, instead of running on through a zone we've left.
	local function alive()
		return running and gen == mine
	end

	task.spawn(function()
		local total = 0
		while alive() do
			local got, full = 0, false
			local ran = claim(function()
				got, full = sweep(alive)
			end)
			total += got
			if full then
				-- Not an error and not something this script can fix. There is no bank
				-- to run back to in this game -- held IS in the inventory -- so the only
				-- ways to free a slot are placing on a stand or Drop Friend, and the
				-- farm deliberately does neither. Clear room and it picks straight up.
				say(("carry full - holding %d, place or open some"):format(heldCount()))
				claim(goHome) -- park at the plot, not stood in a zone with a full stack
				task.wait(FULL_WAIT)
				-- Dropping the flag IS the re-test: the next sweep tries one grab, and
				-- either it lands because you freed a slot or the server says no again.
				-- One refused grab every FULL_WAIT, instead of a screen full of them.
				carryFull = false
			else
				if ran then
					say(("%d banked - holding %d"):format(total, heldCount()))
				end
				task.wait(DWELL)
			end
		end
		if gen == mine then
			say(("idle - %d banked"):format(total))
		end
	end)
end

-- snipe ----------------------------------------------------------------------
-- The high tiers spawn on a schedule rather than continuously, so waiting for the next
-- sweep can miss the whole window. ChildAdded is the game telling us the moment one
-- lands. The attributes arrive a frame or two behind the model, hence the short wait
-- for an ID before deciding.
local sniping = false

local function onSpawned(model)
	if not (sniping and model:IsA("Model")) then
		return
	end

	local deadline = os.clock() + 1
	while not model:GetAttribute("ID") and model.Parent == Friends and os.clock() < deadline do
		task.wait()
	end

	local entry = friendData(model)
	if not (entry and snipeworthy(entry)) then
		return
	end

	if carryFull then
		return say(("SNIPE missed %s - carry full"):format(entry.Name))
	end

	say(("SNIPE %s (%s)"):format(entry.Name, entry.Rarity))
	-- Queue behind a sweep rather than giving up on it: claim() refuses while the farm
	-- holds the character, and one of these is worth waiting a few seconds for.
	local deadline2 = os.clock() + SNIPE_WAIT
	repeat
		if model:GetAttribute("CarryOwner") or model.Parent ~= Friends then
			return
		end
		-- Waits whether or not it got the character: without the wait on the ran branch
		-- a refused grab returns instantly and this spins, re-firing the prompt as fast
		-- as the loop turns -- the notification flood, moved from grab() to here.
		claim(function()
			grab(model, function()
				return sniping
			end)
		end)
		task.wait(POLL)
	until model:GetAttribute("CarryOwner") or carryFull or os.clock() > deadline2 or not sniping

	if model:GetAttribute("CarryOwner") == player.UserId then
		say(("SNIPED %s (%s)"):format(entry.Name, entry.Rarity))
		claim(goHome)
	end
end

-- Held in an upvalue and dropped on close: re-running the script would otherwise leave
-- the old copy's handler connected alongside the new one for the life of the session.
local spawnConn = Friends.ChildAdded:Connect(function(model)
	task.spawn(onSpawned, model)
end)

-- cash -----------------------------------------------------------------------
-- The pad's own Touched handler is what fires Collect Earnings, with the server's own
-- guards already on it, so firing the TouchInterest IS the vanilla path -- no guessing
-- whether the remote validates distance. It also reaches every floor from wherever
-- you're stood, which is why this doesn't take claim() and can run next to the farm.
-- ponytail: if a future update moves the handler off Touched, fire the remote directly
-- instead -- Remotes["Collect Earnings"]:FireServer(pad.Name) -- and teleport per pad.
local hasFTI = typeof(firetouchinterest) == "function"

local function collectPass()
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	local plot = myPlot()
	local pads = plot and plot:FindFirstChild("CollectPads")
	if not (hasFTI and head and pads) then
		return
	end
	for _, pad in ipairs(pads:GetChildren()) do
		local top = pad:FindFirstChild("Top")
		local gui = top and top:FindFirstChild("PadGui")
		-- PadGui is the whole filter, and it's the game's own: the Touched handler won't
		-- fire Collect Earnings without it either. Three things it rules out --
		--   locked floor  : keeps PurchaseInfo and never gets a PadGui at all. Touching
		--                   one fires the "Purchase Floor" signal instead of collecting,
		--                   which is the $2M confirmation dialog popping up mid-sweep.
		--   empty stand   : PadGui, Enabled false. Nothing to collect.
		--   unopened block: PadGui, Enabled false -- a lucky block earns nothing until
		--                   it's opened, so every block this farm banks has a dead pad.
		-- Going by shape also means no BaseLevel lookup: which floors you own is already
		-- written into the pads by the time we read them.
		if gui and gui.Enabled then
			-- 0 begins the touch, 1 ends it; the handler runs on the begin.
			pcall(firetouchinterest, head, top, 0)
			task.wait()
			pcall(firetouchinterest, head, top, 1)
		end
	end
end

-- upgrade --------------------------------------------------------------------
-- Bulk first, then the single: five levels at once when the cash is there, and the
-- single mops up whatever's left over. Both are refused server-side when broke, which
-- is the whole affordability check -- there is nothing to test client-side.
local function speedPass()
	UpgradeSpeed5:FireServer()
	UpgradeSpeed:FireServer()
end

-- Blind rebirth spam would be refused all day and would fire the moment the server
-- accepted, mid-carry. Gated on the game's own ladder instead: forty tiers of
-- SpeedRequirement, and every BoostRequirement in the table is 0.
local function rebirthPass()
	local data = stats()
	if not data then
		return
	end
	local tier = Rebirths[(data.Rebirth or 0) + 1]
	if not tier then
		return
	end
	local speed = (data.Speed or 0) + (data.PermSpeedBonus or 0)
	if speed >= tier.SpeedRequirement and (data.Boost or 0) >= (tier.BoostRequirement or 0) then
		Rebirth:FireServer()
		dataAt = 0 -- the rebirth resets Speed; don't gate the next check on a stale copy
	end
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

local collector = { on = false, gen = 0 }
local speeder = { on = false, gen = 0 }
local booster = { on = false, gen = 0 }
local carrier = { on = false, gen = 0 }
local rebirther = { on = false, gen = 0 }

-- gui ------------------------------------------------------------------------
local WindUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()

local Window = WindUI:CreateWindow({
	Title = "Surf for Brainrots",
	Icon = "solar:waterdrops-bold",
	Folder = "SurfRots",
	Size = UDim2.fromOffset(440, 460),
	Topbar = { Height = 44, ButtonsType = "Mac" },
	OpenButton = { Title = "Surf for Brainrots", Enabled = true, Draggable = true },
})
Window:SetToggleKey(KEY_TOGGLE)

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local Farm = Tab:Section({ Title = "Farm", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })
local Plot = Tab:Section({ Title = "Plot", Icon = "solar:buildings-2-bold", Box = true, BoxBorder = true, Opened = true })
local Boost =
	Tab:Section({ Title = "Boosts", Icon = "solar:double-alt-arrow-up-bold", Box = true, BoxBorder = true, Opened = true })

-- table.clear, never `= {}`: the farm thread holds `wanted` as an upvalue, so replacing
-- it leaves the loop reading the copy nobody ticks any more.
local function retick(values)
	table.clear(wanted)
	for _, rarity in ipairs(values) do
		wanted[rarity] = true
	end
end

retick(RARITIES)

local rarityDrop = Farm:Dropdown({
	Title = "Rarity",
	Desc = "Also the zone picker -- one island per rarity. Untick one and it's invisible.",
	Values = RARITIES,
	Value = RARITIES,
	Multi = true,
	AllowNone = true,
	Callback = retick,
})

-- One button rather than two: empty means "tick everything", anything else means
-- "clear it", so the next press always does the opposite of the last one. :Select()
-- writes the selection and redraws the menu but deliberately does NOT fire the
-- Callback, which is why retick has to be called by hand alongside it.
Farm:Button({ Title = "Rarity: all / none", Callback = function()
	local picked = next(wanted) == nil and RARITIES or {}
	rarityDrop:Select(picked)
	retick(picked)
end })

Farm:Toggle({
	Title = "Auto Farm",
	Desc = "Steal best first and leave it in the inventory. Nothing is placed or opened.",
	Value = false,
	Callback = setRunning,
})

Farm:Toggle({
	Title = "Snipe OG+",
	Desc = "Jump on OG / Divine / Transcendent / Exclusive the frame it spawns",
	Value = false,
	Callback = function(v)
		sniping = v
	end,
})

Farm:Button({ Title = "TP to best block", Callback = function()
	claim(function()
		local best = candidates(ticked)[1]
		if best then
			tp(best.model:GetPivot())
			say(("at %s (%s)"):format(best.entry.Name, best.entry.Rarity))
		else
			say("nothing matching has spawned")
		end
	end)
end })

Plot:Toggle({
	Title = "Collect All Cash",
	Desc = "Every earning pad on your plot, every 5s. Never touches an unbought floor.",
	Value = false,
	Callback = function(v)
		collector.on = v
		if v then
			every(collector, COLLECT_EVERY, collectPass)
		end
	end,
})

Plot:Button({ Title = "TP to plot", Callback = function()
	claim(function()
		if not goHome() then
			say("no plot found")
		end
	end)
end })

Boost:Toggle({
	Title = "Auto Upgrade Speed",
	Desc = "Bulk five then single. Speed is the rebirth gate, so this feeds Auto Rebirth.",
	Value = false,
	Callback = function(v)
		speeder.on = v
		if v then
			every(speeder, SPEED_EVERY, speedPass)
		end
	end,
})

Boost:Toggle({
	Title = "Auto Upgrade Boost",
	Desc = "Upgrade Boost on a timer -- 100 levels, +22.5% launch power each",
	Value = false,
	Callback = function(v)
		booster.on = v
		if v then
			every(booster, BOOST_EVERY, function()
				UpgradeBoost:FireServer()
			end)
		end
	end,
})

Boost:Toggle({
	Title = "Auto Upgrade Carry",
	Desc = "8 levels, +1 block held each -- how much the farm banks before it parks",
	Value = false,
	Callback = function(v)
		carrier.on = v
		if v then
			every(carrier, CARRY_EVERY, function()
				UpgradeCarry:FireServer()
			end)
		end
	end,
})

Boost:Toggle({
	Title = "Auto Rebirth",
	Desc = "Only when Speed clears the next tier. Resets your speed -- watch it fire.",
	Value = false,
	Callback = function(v)
		rebirther.on = v
		if v then
			every(rebirther, REBIRTH_EVERY, rebirthPass)
		end
	end,
})

local line = Farm:Paragraph({ Title = "Status", Desc = "idle" })
say = function(msg)
	line:SetDesc(msg)
end

-- minimize -------------------------------------------------------------------
-- WindUI's own Minimize hides the whole window and leaves nothing but the floating
-- open button, which it only draws on touch devices -- on a PC the window would be
-- gone with nothing left to click. Swapped for a shade: the body collapses to a bare
-- title bar and the same button rolls it back down. Loops keep farming either way.
--
-- The shade is sized to its CONTENT, not to the window: keeping the full width just
-- leaves a 440-wide black slab with a title in the corner of it.
--
-- Main is anchored at its CENTRE, so a resize on its own moves all four edges: the
-- shade would land mid-screen, and rolling it back down near the top of the screen
-- pushed the title bar off it with nothing left to click. Every resize is paired with
-- a position nudge of half the delta, pinning the TOP-LEFT corner instead, so the bar
-- collapses where it stands and grows back down and right from the same spot.
local SHADE_TRIM = 8 -- Topbar's own PaddingRight -- the breathing room after the title
local SHADE_MIN = 160 -- never shade narrower than the traffic lights + this button, or
-- there is nothing left to click to get the window back
local SHADE_PAD = 10 -- topbar height + window chrome; nudge if the shade clips

Window:DisableTopbarButtons({ "Minimize" }) -- before ours, it reuses the same slot

-- Measured, not guessed, so the bar fits whatever the title happens to be. WindUI lays
-- the topbar out as three frames: Left (icon + title, AutomaticSize "X"), Right (the
-- traffic lights and this button), and Center. With ButtonsType "Mac" it positions Left
-- after Right, so the right-hand edge of the widest child IS the end of the content.
-- AbsoluteSize is post-UIScale while Size offsets are pre-scale, hence the divide.
local function shadeSize(fullWidth)
	local topbar = Window.UIElements.Main.Main.Topbar
	local scale = tonumber(WindUI.UIScale) or 1
	if scale <= 0 then
		scale = 1
	end

	local edge = 0
	for _, child in ipairs(topbar:GetChildren()) do
		-- Center is the tab-strip slot: unused and invisible here, but when it IS used
		-- it's sized to fill the window, which would defeat the whole measurement.
		if child:IsA("GuiObject") and child.Visible and child.Name ~= "Center" then
			edge = math.max(edge, child.AbsolutePosition.X + child.AbsoluteSize.X - topbar.AbsolutePosition.X)
		end
	end

	local w = math.clamp(edge / scale + SHADE_TRIM, SHADE_MIN, fullWidth)
	return UDim2.fromOffset(w, Window.Topbar.Height + SHADE_PAD)
end

local SHADE_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local shaded, fullSize, shadeTo = false, nil, nil
Window:CreateTopbarButton("Shade", "minus", function()
	local main = Window.UIElements.Main
	shaded = not shaded

	-- Both read live on the way down: a window the user resized comes back its own size,
	-- and the bar is re-measured each time in case the title, the buttons or the UIScale
	-- have changed since. Kept in upvalues so the way back up doesn't have to re-derive
	-- either end -- see the note on mid-tween reads below.
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

	-- Both ends are known, so the delta is computed rather than read back off a frame
	-- that is still mid-tween from the last click.
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

-- close ----------------------------------------------------------------------
local function stopAll()
	sniping = false
	collector.on, speeder.on, booster.on, carrier.on, rebirther.on = false, false, false, false, false
	setRunning(false)
	if spawnConn then
		spawnConn:Disconnect()
		spawnConn = nil
	end
	if notifyConn then
		notifyConn:Disconnect()
		notifyConn = nil
	end
end

Window:OnDestroy(function()
	stopAll()
	getgenv().surfRotsStop = nil
end)

getgenv().surfRotsStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().surfRotsStop = nil
end
