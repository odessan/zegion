--[[ Drill Block for Dumpling Squishy -- richest squishy on the map, one at a time (86943068337855)

     FARM   : every wild squishy carries the CollectionService tag "Animal" and an Income
              attribute that already has its Level and Mutation baked in, so the pick is a
              plain max over one tagged list -- no folder walk, no rarity table, no parsing.
              Hop to it, press, carry it home, and the game saves it the moment you touch
              your own BaseEnteranceFloor. Then round again.
     SWEEP  : touches every ClaimButton on your plot. It never moves you, so it keeps
              paying while the farm is off in the Eternal zone.
     NEAREST: turn "Richest first" off to take the closest one instead. Income here spans
              six orders of magnitude (a Radioactive Geode pays $11M/s against a Common's
              $600), so richest-first is almost always what you want.
     MIN    : skip anything under this. Blank or 0 takes everything.

     No remote in this script places, sells or drops anything. Depositing is the game's
     own auto-save at the entrance floor; the plot is never touched.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().drillBlockStop() ]]

-- config ---------------------------------------------------------------------
-- Measured, not guessed. A probe run in a live server did one whole cycle -- pick, hop,
-- press, carry, deposit -- in a shade over one second, with fireproximityprompt landing
-- the grab in 0.11s and the entrance auto-save clearing the carry in 0.4s. Every number
-- below is sized against those two, so raising one is a real decision and not a shrug.
local REACH = 200 -- MaxActivationDistance we force on the prompt. Big and FINITE:
-- math.huge is rejected by the engine and throws, and it throws inside the pcall around
-- the press -- a grab that fails with an empty console. The prompt ships at 12.
local LIFT = 3 -- studs above a squishy's pivot to land. Enough not to spawn inside the
-- mesh, well inside the range check once REACH is open.
local PRESS_GAP = 0.1 -- between re-fires of the prompt inside one grab window

-- There is deliberately NO fixed settle between arriving and pressing. The prompt is
-- server-side, so an early press simply does nothing, and the press loop re-fires on
-- PRESS_GAP while the confirm (the carry count) is polled every pass. The retry loop IS
-- the settle: it costs nothing when the server was already ready, and unlike a constant
-- it cannot be tuned wrong.
local GRAB_WINDOW = 2.5 -- give up on one squishy. The probe's grab landed in 0.11s, so
-- this is generous -- and it wants to stay small, because a refusal is ambiguous and this
-- is what each ambiguous one costs.
local ARRIVE = 3 -- seconds to wait for a model's ProximityPrompt to stream in after the
-- hop. This, not a stream request, is what covers a target whose parts haven't arrived:
-- 221 of the map's 311 squishies were replicated as bare Models on the probe run.
local PAUSE_WAIT = 2 -- cap on waiting out a GameplayPaused after a hop
local ARRIVE_RADIUS = 25 -- studs; further than this from where we aimed means the server
-- reverted the hop rather than that we drifted. The probe measured 0.0 into a far zone,
-- so a revert here is news -- but the count is kept anyway, because a game that allows
-- the jump today can range-check it after an update.
local HOME_TIMEOUT = 8 -- give up waiting for the carry to clear at the entrance floor
local MIN_LIFE = 8 -- seconds of ExpiresAt a target must have left. Below this the hop is
-- likely to be paid for ground that empties on arrival.

local REFUSE_PARK = 20 -- seconds a squishy is set aside for after it refuses us or turns
-- out to be unreachable. A richest-first queue re-picks the top entry the instant its
-- park expires, so something you can never reach still has to step aside for a while.
local ZONE_STRIKES = 4 -- refusals in one zone before it's written off for the session

local SWEEP = 2 -- seconds between cash sweeps of your plot
local TOUCH_GAP = 0.05 -- between the begin and end of a batched touch sweep
local IDLE = 0.5 -- beat when nothing is worth going for. A pass that DID something goes
-- straight round again: an idle beat between grabs is dead time on every single item.
local STUCK_AFTER = 25 -- seconds a breadcrumb may sit unchanged before the watchdog says so
local KEY_TOGGLE = Enum.KeyCode.RightControl

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().drillBlockStop then
	getgenv().drillBlockStop() -- re-running must not stack a second panel/loop
end

-- The live config the loops read. The panel's rows write into this table, so the toggles
-- and getgenv() are the same object rather than two copies drifting apart.
getgenv().DrillBlockConfig = getgenv().DrillBlockConfig or {}
local CFG = getgenv().DrillBlockConfig
-- Filled in per key rather than with `or`, which cannot express a default of true.
for k, v in
	{ AutoFarm = false, AutoSweep = false, PreferHighestValue = true, MinIncome = 0, Debug = false }
do
	if CFG[k] == nil then
		CFG[k] = v
	end
end

local running = true

-- The farm thread never writes to the panel, it leaves a line here. Executors hand a
-- RESUMED thread back with reduced capability, so the first status write lands and every
-- one after a task.wait throws "cannot access 'Instance' (lacking capability Plugin)" --
-- the panel lives in the hidden GUI, which is the part that needs it. Uncaught, that
-- kills the farm on its second lap with the toggle still lit. A Heartbeat drains it
-- instead; the engine calls Heartbeat with our own identity.
local pending = nil
local function say(msg)
	pending = msg
end
local function debug(...)
	if CFG.Debug then
		print("[drill]", ...)
	end
end

-- The breadcrumb. Two assignments per slow step, and a separate watchdog thread reads it
-- -- separate because a farm thread parked in a yield cannot report anything about
-- itself, and "it stopped and there was nothing in the console" is this repo's most
-- common bug report. Name the halves of a step apart: "grab X / press" and "grab X /
-- stream" have completely different causes.
local mark, markAt = "idle", os.clock()
local function step(what)
	mark, markAt = what, os.clock()
end

-- The game's own client data. Replica is how the game itself answers "what am I carrying"
-- and "which plot is mine", and it is DATA, so streaming cannot take it away from us the
-- way it takes away the Instances under a plot we've teleported a thousand studs from.
local replica
pcall(function()
	replica = require(ReplicatedStorage.Packages.Replica).ForPlayer(player)
end)
if not replica then
	warn("[drill] no Replica -- falling back to counting Backpack tools")
end

-- Networker publishes its remotes under names that contain slashes, so this is a
-- FindFirstChild call on a literal string and not a path.
local holder = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Networker"):WaitForChild("Holder")
local Notify = holder:FindFirstChild("RE/NotificationManager/Notify")

-- world ----------------------------------------------------------------------
-- A farm that hops across the map twice a second flashes the "Gameplay Paused" banner
-- constantly. This hides the NOTIFICATION only: player.GameplayPaused still goes true and
-- the character is still frozen while the region streams in, so tp()'s wait below stays
-- exactly as it was. Turning this off is cosmetic -- treating it as a fix would just move
-- the symptom from "banner all day" to "presses fire while the world is still empty".
-- pcall'd: it's a newer GuiService method and an older client errors on the index.
pcall(function()
	game:GetService("GuiService"):SetGameplayPausedNotificationEnabled(false)
end)

local function hrp()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- false when there's no character to move OR when the server put us back where we were.
-- The two are worth telling apart the day one of them starts happening; today every
-- caller treats both as "didn't get there", so they share an answer.
local function tp(cf)
	local root = hrp()
	if not root then
		return false
	end
	root.CFrame = cf
	local until_ = os.clock() + PAUSE_WAIT
	while player.GameplayPaused and os.clock() < until_ do
		task.wait(0.05)
	end
	root = hrp() -- may have respawned while we waited
	return root ~= nil and (root.Position - cf.Position).Magnitude < ARRIVE_RADIUS
end

-- How many squishies am I carrying. Replica first, the Backpack count as the fallback.
local function carrying()
	if replica then
		local ok, list = pcall(function()
			return replica:Get({ "CarryingAnimals" })
		end)
		if ok and type(list) == "table" then
			return #list
		end
	end
	local n = 0
	for _, where in { player:FindFirstChildOfClass("Backpack"), player.Character } do
		for _, t in pairs(where and where:GetChildren() or {}) do
			if t:IsA("Tool") and t:GetAttribute("AnimalTool") then
				n += 1
			end
		end
	end
	return n
end

-- The game's own client never reads the plot's Owner attribute: PlotServiceClient.IsMine
-- compares the plot's UUID against the player Replica's PlotUUID, so that's the contract
-- and this uses it. Owner is kept as the fallback and compared as a STRING, which is what
-- it actually is -- matching it as a number is why the first probe run found no plot.
-- Re-read every cycle: plots are handed out on join and the match can land late.
local function myPlot()
	local plots = workspace:FindFirstChild("Plots")
	if not plots then
		return nil
	end
	local mine
	if replica then
		local ok, uuid = pcall(function()
			return replica:Get({ "PlotUUID" })
		end)
		if ok then
			mine = uuid
		end
	end
	local uid = tostring(player.UserId)
	for _, p in pairs(plots:GetChildren()) do
		local owner = p:GetAttribute("Owner")
		if (mine and mine ~= "" and p:GetAttribute("UUID") == mine) or tostring(owner) == uid then
			return p
		end
	end
	return nil
end

-- farm -----------------------------------------------------------------------
-- Weak keys, so a despawned squishy drops out of the park table on its own rather than
-- being a leak we have to sweep.
local park = setmetatable({}, { __mode = "k" })
local zoneStrikes = {}

-- The game's own formatter. AnimalTool's billboard builds this exact "$1.23M/s" string
-- with it, so the panel reads the way the HUD does instead of near enough.
local numbers
pcall(function()
	numbers = require(ReplicatedStorage.Packages.NumberUtils)
end)
local function abbrev(n)
	local ok, s = pcall(function()
		return numbers.AbbreviateComma(n, ".", true)
	end)
	return ok and s or tostring(math.floor(n))
end

-- The server's own words for a refusal. These strings exist in no client script, so this
-- event is the only place the real reason is ever worded -- and a notification arriving
-- inside a grab window is also proof the press REACHED the server, which rules out a
-- whole class of bug in one line.
local lastNote, lastNoteAt = nil, 0
local noteConn
if Notify then
	noteConn = Notify.OnClientEvent:Connect(function(msg)
		if type(msg) == "string" then -- other shapes unobserved; add one when you see one
			lastNote, lastNoteAt = msg, os.clock()
		end
	end)
end

-- Match on the model and its pivot, and nothing else. Requiring a PrimaryPart here would
-- be right for a spawner folder we're standing in and wrong for a whole map: a far model
-- replicates as a Model with its attributes and WorldPivot and no parts at all, so
-- gating on parts makes every distant target invisible until you've walked into its zone
-- by hand -- the one case where you don't need the script. Streaming the parts is the
-- grab's job. A Model with no parts reports the origin, so the pivot is its own sentinel.
local function candidates()
	local now, out = workspace:GetServerTimeNow(), {}
	local root = hrp()
	local here = root and root.Position or Vector3.zero
	local minIncome = tonumber(CFG.MinIncome) or 0
	for _, m in pairs(CollectionService:GetTagged("Animal")) do
		local income = m:GetAttribute("Income")
		local zone = m.Parent and m.Parent.Name or "?"
		local expires = m:GetAttribute("ExpiresAt")
		local pos = m:GetPivot().Position
		if
			m.Parent
			and income
			and income >= minIncome
			and m:GetAttribute("UUID")
			and pos.Magnitude > 1 -- not "replicated as a Model with nothing in it yet"
			and (park[m] or 0) < os.clock()
			and (zoneStrikes[zone] or 0) < ZONE_STRIKES
			and (not expires or expires <= 0 or expires - now > MIN_LIFE)
		then
			table.insert(out, {
				model = m,
				zone = zone,
				income = income,
				pos = pos,
				dist = (pos - here).Magnitude,
			})
		end
	end
	table.sort(out, function(a, b)
		if not CFG.PreferHighestValue then
			return a.dist < b.dist
		end
		if a.income ~= b.income then
			return a.income > b.income
		end
		return a.dist < b.dist -- a tie goes to the near one
	end)
	return out
end

-- true = the carry went up, false = fired for the whole window and it's still sat there
-- (a refusal, worth a strike), nil = nothing to fire at, i.e. not streamed in. Conflating
-- the last two is what makes a streaming hiccup read as a full carry.
local function grab(entry)
	local m = entry.model
	step("grab " .. tostring(m:GetAttribute("AnimalName")) .. " / hop")
	local aim = CFrame.new(entry.pos + Vector3.new(0, LIFT, 0))
	if not tp(aim) then
		return nil
	end

	step("grab " .. tostring(m:GetAttribute("AnimalName")) .. " / stream")
	local prompt
	local until_ = os.clock() + ARRIVE
	repeat
		prompt = m:FindFirstChildWhichIsA("ProximityPrompt", true)
		if not prompt then
			task.wait(0.1)
		end
	until prompt or os.clock() > until_ or not m.Parent
	if not prompt then
		return nil
	end

	-- All three of these gates are enforced by the CLIENT, which is us, so all three can
	-- be opened -- and out of range there is no press at all, which reads as a refusal
	-- rather than as a miss.
	pcall(function()
		prompt.RequiresLineOfSight = false
		prompt.MaxActivationDistance = REACH
		prompt.Enabled = true
	end)

	-- Re-aim at what the range check actually measures from. On a model whose mesh hangs
	-- off a per-squishy part name (BananaPeel, GRAPE_JELL, Red_Apple) that is nowhere
	-- near the pivot we hopped to.
	local anchor = prompt:FindFirstAncestorWhichIsA("BasePart")
	if anchor then
		aim = CFrame.new(anchor.Position + Vector3.new(0, LIFT, 0))
	end

	step("grab " .. tostring(m:GetAttribute("AnimalName")) .. " / press")
	local before = carrying()
	local noteBefore = lastNoteAt
	local deadline = os.clock() + GRAB_WINDOW
	repeat
		local root = hrp()
		if not root then
			return nil
		end
		root.CFrame = aim -- hold the spot: one hop drifts and the range check starts
		-- failing mid-window, which reads as a refusal
		pcall(function()
			fireproximityprompt(prompt, 1)
		end)
		task.wait(PRESS_GAP)
		if carrying() > before then
			return true
		end
	until os.clock() > deadline
	if lastNoteAt > noteBefore then
		debug("server said:", lastNote)
	end
	return false
end

-- Streaming eats the plot's PARTS while the farm is off in a far zone. The plot Model
-- itself keeps replicating -- name, attributes, pivot -- so myPlot() still finds it and
-- everything looks fine, but FindFirstChild("BaseEnteranceFloor") is nil exactly when we
-- need it. That read as "no entrance floor", left us carrying, and the loop went for the
-- next squishy: with a carry cap as low as 1 every following grab was refused, and those
-- refusals struck zones that had done nothing wrong.
-- So cache the POSITION the first time we see the floor, never the Instance, and aim
-- twice when we haven't got one yet: hop to the plot's pivot, let the parts arrive, then
-- hop to the floor itself.
local homePos = nil

local function entranceOf(plot)
	local floor = plot:FindFirstChild("BaseEnteranceFloor") -- the game's spelling
	if floor then
		homePos = floor.Position
	end
	return homePos
end

-- The deposit is the game's own: touching your plot's entrance floor auto-saves whatever
-- you're carrying. Nothing here fires PlaceAnimal, SellAnimal or Drop.
local function goHome()
	step("home / find plot")
	local plot = myPlot()
	if not plot then
		return false, "no plot"
	end

	local pos = entranceOf(plot)
	if not pos then
		step("home / stream plot")
		if tp(plot:GetPivot()) == nil then
			return false, "no character"
		end
		local deadline = os.clock() + ARRIVE
		repeat
			task.wait(0.1)
			pos = entranceOf(plot)
		until pos or os.clock() > deadline
		if not pos then
			return false, "entrance floor never streamed in"
		end
	end

	step("home / hop")
	if not tp(CFrame.new(pos + Vector3.new(0, 4, 0))) then
		return false, "hop refused"
	end
	step("home / auto-save")
	local deadline = os.clock() + HOME_TIMEOUT
	repeat
		task.wait(0.1)
		if carrying() == 0 then
			return true
		end
	until os.clock() > deadline
	return false, "carry never cleared"
end

local farm = { on = false, gen = 0 }

local function setFarming(v)
	farm.on = v
	CFG.AutoFarm = v
	if not v then
		say("stopped")
		return
	end
	farm.gen += 1
	local mine = farm.gen
	task.spawn(function()
		local taken, lastName, lastIncome, lastFail = 0, "?", 0, nil
		while farm.on and farm.gen == mine do
			-- Deposit before anything else, every lap. This is the ONE place a carry is
			-- cleared, so a grab that succeeded and a carry left over from a failed
			-- deposit take the same path out. It also makes a broken deposit cost one
			-- refused grab instead of poisoning every zone in turn: while we're holding
			-- something, every prompt on the map refuses us and none of it is the zone's
			-- fault.
			if carrying() > 0 then
				local home, reason = goHome()
				if home then
					taken, lastFail = taken + 1, nil
					say(("%d taken -- last %s $%s/s"):format(taken, lastName, abbrev(lastIncome)))
				else
					say("holding, can't deposit: " .. tostring(reason))
					if reason ~= lastFail then -- once per reason, not once per lap
						warn("[drill] carrying but cannot deposit:", reason)
						lastFail = reason
					end
					step("idle")
					task.wait(IDLE)
					continue
				end
			end

			local list = candidates()
			local entry = list[1]
			if not entry then
				say("nothing worth going for")
				step("idle")
				task.wait(IDLE)
				continue
			end

			local name = tostring(entry.model:GetAttribute("AnimalName"))
			say(("-> %s  $%s/s  %s"):format(name, abbrev(entry.income), entry.zone))
			local got = grab(entry)

			if got == true then
				zoneStrikes[entry.zone] = 0
				lastName, lastIncome = name, entry.income
				-- No deposit here: the top of the next lap does it, and it does it for a
				-- leftover carry too. One path, one place the carry is cleared.
			elseif got == false then
				-- A real refusal. Park the target and count it against the zone, which is
				-- how the script discovers its own reach instead of being told.
				park[entry.model] = os.clock() + REFUSE_PARK
				zoneStrikes[entry.zone] = (zoneStrikes[entry.zone] or 0) + 1
				debug("refused", name, "in", entry.zone, "strike", zoneStrikes[entry.zone])
				if zoneStrikes[entry.zone] >= ZONE_STRIKES then
					warn(("[drill] %s written off for the session after %d refusals")
						:format(entry.zone, ZONE_STRIKES))
				end
			else
				-- Never streamed in, or the hop didn't land. Parked as long as a refusal:
				-- grab() already gave it ARRIVE seconds while we stood on it, so a target
				-- with still no prompt has had its chance -- and under a richest-first
				-- sort an unreachable one would otherwise sit at the head of the queue
				-- blocking everything beneath it.
				park[entry.model] = os.clock() + REFUSE_PARK
				debug("parked unreachable", name)
			end
		end
		if farm.gen == mine then -- only the current generation may flip the switch off
			farm.on = false
		end
	end)
end

-- sweep ----------------------------------------------------------------------
-- Never moves the character, which is the whole point: firetouchinterest reaches the
-- server's Touched handler from wherever the farm has taken us. Batched -- every begin,
-- one gap, every end -- so ten pads cost one TOUCH_GAP and not ten.
local sweep = { on = false, gen = 0 }

local function pads(plot)
	local out = {}
	for _, d in pairs(plot:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "Main" and d.Parent and d.Parent.Name == "ClaimButton" then
			table.insert(out, d)
		end
	end
	return out
end

local function sweepOnce()
	local plot = myPlot()
	if not plot then
		return nil
	end
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	if not (firetouchinterest and head) then
		return nil
	end
	local list = pads(plot)
	for _, pad in ipairs(list) do
		pcall(firetouchinterest, head, pad, true)
	end
	task.wait(TOUCH_GAP)
	for _, pad in ipairs(list) do
		pcall(firetouchinterest, head, pad, false)
	end
	return #list
end

local function setSweep(v)
	sweep.on = v
	CFG.AutoSweep = v
	if not v then
		return
	end
	sweep.gen += 1
	local mine = sweep.gen
	task.spawn(function()
		while sweep.on and sweep.gen == mine do
			local n = sweepOnce()
			if n == nil then
				debug("sweep: no plot or no character yet")
			elseif n == 0 then
				debug("sweep: no ClaimButtons under the plot")
			end
			task.wait(SWEEP)
		end
		if sweep.gen == mine then
			sweep.on = false
		end
	end)
end

-- gui ------------------------------------------------------------------------
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a restyle
-- is one file and not thirty. Fetched here rather than installed by the loader, so this
-- file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Drill Block for Dumpling Squishy", -- fallback until the live name lands
	folder = "DrillBlockSquishy", -- unchanged: renaming it orphans configs saved in-game
	size = UDim2.fromOffset(460, 400),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:box-minimalistic-bold" })
local Farm = Tab:Section({ Title = "Farm", Icon = "solar:magic-stick-3-bold", Box = true, BoxBorder = true, Opened = true })
local Extra = Tab:Section({ Title = "Extras", Icon = "solar:dollar-minimalistic-bold", Box = true, BoxBorder = true, Opened = true })

Farm:Toggle({
	Title = "Auto Farm",
	Desc = "Richest squishy on the map, then home to the entrance floor",
	Value = CFG.AutoFarm,
	Callback = setFarming, -- :Set() re-fires this, and setFarming is re-entrant
})

Farm:Toggle({
	Title = "Richest first",
	Desc = "Off = take the closest one instead",
	Value = CFG.PreferHighestValue,
	Callback = function(v)
		CFG.PreferHighestValue = v
	end,
})

Farm:Input({
	Title = "Min income",
	Desc = "Skip anything paying less than this per second. Blank takes everything",
	Value = tostring(CFG.MinIncome),
	Placeholder = "0",
	Callback = function(v)
		CFG.MinIncome = tonumber((v:gsub("[%$,%s]", ""))) or 0
		say(("min income $%s/s"):format(abbrev(CFG.MinIncome)))
	end,
})

Farm:Button({
	Title = "TP to best",
	Callback = function()
		if farm.on then
			say("turn Auto Farm off first")
			return
		end
		local best = candidates()[1]
		if not best then
			say("nothing spawned")
			return
		end
		say(("%s  $%s/s  %s"):format(best.model:GetAttribute("AnimalName"), abbrev(best.income), best.zone))
		tp(CFrame.new(best.pos + Vector3.new(0, LIFT, 0)))
	end,
})

Farm:Button({
	Title = "TP home",
	Callback = function()
		if farm.on then
			say("turn Auto Farm off first")
			return
		end
		local ok, why = goHome()
		say(ok and "home" or ("home failed: " .. tostring(why)))
	end,
})

Extra:Toggle({
	Title = "Auto Sweep",
	Desc = "Touches every ClaimButton on your plot; doesn't move you",
	Value = CFG.AutoSweep,
	Callback = setSweep,
})

Extra:Toggle({
	Title = "Debug",
	Desc = "Refusals, server notifications and park decisions to F9",
	Value = CFG.Debug,
	Callback = function(v)
		CFG.Debug = v
	end,
})

Extra:Button({
	Title = "Clear skips",
	Desc = "Un-parks every squishy and re-opens every written-off zone",
	Callback = function()
		table.clear(zoneStrikes)
		park = setmetatable({}, { __mode = "k" })
		say("skips cleared")
	end,
})

-- A row's Callback fires on user interaction and almost nowhere else -- a starting
-- Value = true does NOT fire it. So anything the config table already had switched on
-- (setting getgenv().DrillBlockConfig before pasting is the whole point of it being a
-- table) has to be armed by hand, or the toggle draws ON with nothing behind it.
if CFG.AutoFarm then
	setFarming(true)
end
if CFG.AutoSweep then
	setSweep(true)
end

local line = Farm:Paragraph({ Title = "Status", Desc = "idle" })

-- Drains whatever the farm thread last left. pcall'd anyway: if even this can't write the
-- panel, the run carries on with the status going to the console instead of taking the
-- loop down with it. Held in an upvalue and disconnected by stopAll, or it outlives
-- Window:Destroy and re-pcalls into a destroyed row every frame.
local drain
drain = RunService.Heartbeat:Connect(function()
	if pending == nil then
		return
	end
	local msg = pending
	pending = nil
	if not pcall(function()
		line:SetDesc(msg)
	end) then
		print("[drill]", msg)
	end
end)

-- A farm thread parked in a yield cannot report on itself, so the watchdog is its own
-- thread and reads only the breadcrumb.
task.spawn(function()
	while running do
		task.wait(5)
		if (farm.on or sweep.on) and os.clock() - markAt > STUCK_AFTER then
			warn(("[drill] stuck %ds at: %s"):format(math.floor(os.clock() - markAt), mark))
			markAt = os.clock() -- report once per window, not every five seconds
		end
	end
end)

-- close ----------------------------------------------------------------------
local function stopAll()
	running = false
	setFarming(false)
	setSweep(false)
	pcall(function()
		drain:Disconnect()
	end)
	if noteConn then
		pcall(function()
			noteConn:Disconnect()
		end)
	end
end

Window:OnDestroy(function()
	stopAll()
	getgenv().drillBlockStop = nil
end)

getgenv().drillBlockStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().drillBlockStop = nil
end
