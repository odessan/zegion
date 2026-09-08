--[[ Don't Steal a Bobo -- steal NPCs out of the field, bank them, run the plot (120135584963579)

     FARM     : scores every NPC standing in Workspace.Map.Zones.Field.NPC with the game's
                own SharedUtils.CalculateIncome, TPs to the single best one, holds its
                Pickup prompt, then TPs straight back to your plot -- which is inside the
                Safe zone, and arriving there is what makes the server hand the NPC over.

                One at a time, because the carry is one at a time: the server tracks it as
                a boolean (CarryNPCState), and the NPC model itself gets Carrier=<UserId>
                while you have it. That attribute is the grab confirm -- the model is
                reparented to Workspace.CarriedNPCModels the moment it's yours, so "it left
                the folder" alone would also be true of a despawn or someone else's steal.

     COLLECT  : fires Plot.CollectCash for every occupied slot on your plot. The game's own
                button is a client-side Touched handler that ends in exactly this remote, so
                firing it skips both the walk and the handler's 0.3s per-button debounce.
                Never moves the character, so it runs alongside the farm.

     EQUIP    : Plot.EquipBestNPCs on a timer -- the server's own "put my best on the base"
                button, so the ranking is the game's, not a guess of mine.

     SORT     : ranks what's placed by income and moves each one to the floor it belongs on,
                best on floor 1 and up from there. Floor granularity, not slot: MoveNPCSlot
                takes a target FLOOR and drops into whatever slot is free there, and that is
                the only reordering remote the client has.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().boboStop() ]]

-- config ---------------------------------------------------------------------
local STAND_OFF = 3.5 -- studs to the SIDE of an NPC to stand, at its own height. Not above
-- it: a vertical offset means you are falling for the whole grab, and re-pinning a falling
-- character every pass is what made the old version bounce on the spot. The prompt reaches
-- 10, so anything under that and clear of the mesh works.
local DRIFT = 5 -- studs of drift before the pin is re-asserted. Rewriting the CFrame every
-- tick fights gravity visibly; only correcting a real slide does not.
local SETTLE = 4 -- ping multiples to wait after a TP. Raise if presses fire and nothing
-- happens: the prompt's range check runs against where the SERVER thinks you are.
local GRAB_TIMEOUT = 4 -- seconds on one NPC, across all press methods, before calling it a
-- refusal. Has to cover a full 0.5s hold per method plus the server's answer.
local HOLD_GRACE = 0.9 -- seconds past HoldDuration that one hold is given to be answered
-- before moving on to the next press method
local ARRIVE = 3 -- seconds to wait for a streamed-out model's PrimaryPart after hopping to it
local EXPIRY_MARGIN = 6 -- skip an NPC with fewer than this many seconds left on ExpiresAt.
-- Field NPCs despawn on a 120s clock; paying a teleport for one that dies on arrival is
-- pure loss, and an expiry looks exactly like a lost race from here.
local DEPOSIT_TIMEOUT = 8 -- seconds at the plot waiting for the server to take the NPC off
-- you. It happens the tick your Zone attribute flips to "Safe".
local BANK_SETTLE = 0.4 -- seconds after a successful deposit before hopping out again
local REFUSE_PARK = 25 -- seconds an NPC is skipped after refusing a full press window
local MISS_STRIKES = 3 -- consecutive "never streamed in" misses before an NPC is parked too.
-- Without this the best-first sort re-picks an unreachable target forever, silently.
local REVERT_STRIKES = 3 -- teleports that snap back before the farm gives up and says so
local IDLE = 1 -- seconds between sweeps when the field came up empty

local COLLECT_EVERY = 6 -- seconds between cash sweeps of your plot
local COLLECT_GAP = 0.05 -- seconds between slots inside one sweep. The client's own handler
-- debounces at 0.3s per button; this is per-slot, so it does not need to match.
local EQUIP_EVERY = 15 -- seconds between EquipBestNPCs. It is a bulk remote with a server
-- cooldown behind it -- firing it faster just gets refused.
local SORT_EVERY = 30 -- seconds between plot sorts
local SORT_PASSES = 6 -- MoveNPCSlot passes per sort. Each move needs a free slot on the
-- target floor, so a sort resolves over several passes as holes open up.
local MOVE_GAP = 0.25 -- seconds between MoveNPCSlot calls

local STUCK_AFTER = 20 -- seconds on one breadcrumb before the watchdog says so
local KEY_TOGGLE = Enum.KeyCode.RightControl

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local VIM = game:GetService("VirtualInputManager")
local player = Players.LocalPlayer
local ping = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]

if getgenv and getgenv().boboStop then
	getgenv().boboStop() -- re-running must not stack a second panel/loop
end

local running = true

-- remotes --------------------------------------------------------------------
-- Plain folders, no Knit, no dispatcher. RequestTeleportHome is deliberately NOT in here:
-- PickupUI reads TeleportHomeCredits and falls back to a Robux dev product, so firing it
-- with no credits opens a purchase prompt. We hop home ourselves; it costs nothing.
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PlotR = Remotes:WaitForChild("Plot")
local CollectCash = PlotR:WaitForChild("CollectCash")
local EquipBestNPCs = PlotR:WaitForChild("EquipBestNPCs")
local MoveNPCSlot = PlotR:WaitForChild("MoveNPCSlot")
local GetPlot = PlotR:WaitForChild("GetPlot")
local Alert = Remotes:WaitForChild("Alert")

-- The game's own numbers. CalculateIncome is what the base HUD reads, so requiring it
-- beats reimplementing the level curve, the mutation table and the trait bonuses.
-- ponytail: toNumber saturates past 1e308 -- if a maxed plot ever sorts as one flat tie,
-- compare GammaNum values with GammaNum.gt instead of collapsing them to doubles here.
local Shared = ReplicatedStorage:WaitForChild("Shared")
local SharedUtils, GammaHelper
pcall(function()
	SharedUtils = require(Shared.SharedUtils)
end)
pcall(function()
	GammaHelper = require(Shared.GammaNumHelper)
end)

-- The client's mirror of your save. Data.Slots / Data.NPCs is what the plot loops read:
-- an Instance scan of the plot goes blank the moment the farm streams it out, the replica
-- does not. Optional -- the loops that need it say so rather than silently doing nothing.
local Aggregation
pcall(function()
	Aggregation = require(player:WaitForChild("PlayerScripts"):WaitForChild("ClientLoader").Modules.DataAggregation)
end)

local function replica()
	if not Aggregation then
		return nil
	end
	local ok, rep = pcall(Aggregation.GetReplica)
	if ok and rep and rep.Data then
		return rep
	end
	return nil
end

-- status ---------------------------------------------------------------------
-- Loop threads never write to the panel directly: a resumed thread comes back with
-- reduced capability and every write after a task.wait throws. A Heartbeat connection
-- drains this instead -- the engine calls that with our own identity.
local pending, pendingQuiet = nil, false

local function post(msg)
	pending, pendingQuiet = msg, false
end

local function status(msg)
	pending, pendingQuiet = msg, true
end

local mark, markAt = "idle", os.clock()
local function step(where)
	mark, markAt = where, os.clock()
end

-- The server's refusal reasons are worded nowhere else -- "Your base is full!" exists in
-- no client script. Keep the last one with its clock so a grab only trusts one that
-- arrived inside its own window.
local lastAlert, lastAlertAt = nil, 0
local alertConn = Alert.OnClientEvent:Connect(function(...)
	local best
	for _, v in ipairs({ ... }) do
		if type(v) == "string" and v:find(" ") and (not best or #v > #best) then
			best = v
		end
	end
	if best then
		lastAlert, lastAlertAt = best, os.clock()
	end
end)

local function alertSince(t)
	if lastAlert and lastAlertAt >= t then
		return lastAlert
	end
	return nil
end

-- world ----------------------------------------------------------------------
local function hrp()
	local char = player.Character
	if not char then
		return nil
	end
	return char:FindFirstChild("HumanoidRootPart")
end

-- Three answers, not two: "arrived", "the server put me back" and "I have no character".
-- Counting a respawn as a snap-back would retire the fast path over nothing.
local function tp(pos)
	local root = hrp()
	if not root then
		return nil
	end
	local cf = typeof(pos) == "Vector3" and CFrame.new(pos) or pos
	root.CFrame = cf
	task.wait((ping:GetValue() * SETTLE) / 1000)
	while running and player.GameplayPaused do
		task.wait(0.1)
	end
	root = hrp()
	if not root then
		return nil
	end
	return (root.Position - cf.Position).Magnitude < 25
end

-- GetPlot is the server telling you which one is yours, which beats matching OwnerName
-- against a display name. The scan is the fallback for a session where the invoke never
-- answers; both are checked for ownership, so neither can hand back someone else's plot.
local plotCache
local function myPlot()
	if plotCache and plotCache.Parent then
		return plotCache
	end
	plotCache = nil
	local ok, got = pcall(function()
		return GetPlot:InvokeServer()
	end)
	if ok and typeof(got) == "Instance" and got:IsA("Model") then
		plotCache = got
		return plotCache
	end
	local plots = workspace:FindFirstChild("Map")
	plots = plots and plots:FindFirstChild("Plots")
	for _, p in ipairs(plots and plots:GetChildren() or {}) do
		if p:GetAttribute("OwnerName") == player.Name then
			plotCache = p
			return plotCache
		end
	end
	return nil
end

local function homeCFrame()
	local plot = myPlot()
	if not plot then
		return nil
	end
	local base = plot.PrimaryPart or plot:FindFirstChild("Base")
	if base then
		return CFrame.new(base.Position + Vector3.new(0, 6, 0))
	end
	local ok, pivot = pcall(function()
		return plot:GetPivot()
	end)
	return ok and (pivot + Vector3.new(0, 6, 0)) or nil
end

-- How many slots are actually UNLOCKED. 10 + UpgradePlot.Value is what the client's own
-- floor maths uses, so it is the authority; the plot's Slots folder is only the fallback,
-- and it overcounts -- slot 11 is built and standing there on a plot that owns ten.
local function slotCount()
	local up = player:FindFirstChild("UpgradePlot")
	if up then
		return 10 + up.Value
	end
	local plot = myPlot()
	local folder = plot and plot:FindFirstChild("Slots")
	local n = 0
	for _, s in ipairs(folder and folder:GetChildren() or {}) do
		local i = tonumber(s.Name)
		if i and i > n then
			n = i
		end
	end
	return math.max(n, 10)
end

local function fieldFolder()
	local map = workspace:FindFirstChild("Map")
	local zones = map and map:FindFirstChild("Zones")
	local field = zones and zones:FindFirstChild("Field")
	return field and field:FindFirstChild("NPC")
end

-- scoring --------------------------------------------------------------------
local function traitsOf(raw)
	if type(raw) == "table" then
		return raw
	end
	if type(raw) ~= "string" or raw == "" then
		return {}
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	return (ok and type(decoded) == "table") and decoded or {}
end

-- The game's own suffix formatter, so a number in the panel reads the way the same number
-- reads on the base HUD (1.4Qd, not 1400000000000000).
local function money(n)
	if GammaHelper then
		local ok, s = pcall(GammaHelper.toSuffix, n)
		if ok and s then
			return tostring(s)
		end
	end
	return ("%.0f"):format(n)
end

local function income(id, mutation, level, traits, variation, fly, ride)
	if not (SharedUtils and GammaHelper and id) then
		return 0
	end
	local ok, gamma = pcall(SharedUtils.CalculateIncome, id, mutation, level or 1, traits, variation, fly, ride)
	if not ok then
		return 0
	end
	local ok2, n = pcall(GammaHelper.toNumber, gamma)
	return (ok2 and tonumber(n)) or 0
end

-- Field spawns are always level 1, so the level term drops out and this is the whole
-- ranking: base income x (mutation + traits) x variation x fly x ride.
local function scoreField(model)
	return income(
		model:GetAttribute("NPCId"),
		model:GetAttribute("Mutation"),
		1,
		traitsOf(model:GetAttribute("NPCTraits")),
		model:GetAttribute("Variation"),
		model:GetAttribute("Fly") == true,
		model:GetAttribute("Ride") == true
	)
end

local function scoreOwned(entry)
	if type(entry) ~= "table" then
		return 0
	end
	return income(entry.Type, entry.Mutation, entry.Level, entry.Traits, entry.Variation, entry.Fly, entry.Ride)
end

-- farm -----------------------------------------------------------------------
local farm = { on = false, gen = 0, got = 0, missed = 0, reverts = 0, last = "-", walk = false }

-- Weak keys so a despawned model drops out of the park list on its own.
local parked = setmetatable({}, { __mode = "k" })
local misses = setmetatable({}, { __mode = "k" })

local function alive(mine)
	return running and farm.on and farm.gen == mine
end

local function carrier(model)
	return model:GetAttribute("Carrier")
end

-- The model, if we can find it; true when the server says we're carrying but the model
-- has streamed out from under us (still a reason to go home before grabbing again);
-- false when our hands are empty.
local function carrying()
	local folder = workspace:FindFirstChild("CarriedNPCModels")
	for _, m in ipairs(folder and folder:GetChildren() or {}) do
		if carrier(m) == player.UserId then
			return m
		end
	end
	if Aggregation then
		local ok, sess = pcall(Aggregation.GetSessionReplica)
		if ok and sess and sess.Data and sess.Data.CarryNPCState == true then
			return true
		end
	end
	return false
end

-- Candidates, best first. A model that is already being carried is someone else's race,
-- not a refusal; one whose timer is nearly out is a teleport we would pay for nothing.
local function candidates()
	local folder = fieldFolder()
	if not folder then
		return {}
	end
	local now = workspace:GetServerTimeNow()
	local out = {}
	for _, m in ipairs(folder:GetChildren()) do
		if m:IsA("Model") and not m:GetAttribute("BeingCarried") and (parked[m] or 0) < os.clock() then
			local expires = m:GetAttribute("ExpiresAt")
			-- A Model with no parts in it yet reports the origin as its pivot, so that is
			-- the "not replicated" sentinel -- hopping to it would drop us at (0,0,0).
			local ok, pivot = pcall(function()
				return m:GetPivot().Position
			end)
			if ok and pivot.Magnitude > 1 and (not expires or expires - now > EXPIRY_MARGIN) then
				local score = scoreField(m)
				if score > 0 then
					table.insert(out, { model = m, score = score })
				end
			end
		end
	end
	table.sort(out, function(a, b)
		return a.score > b.score
	end)
	return out
end

-- Three ways to press E and they are not equivalent, so try each until one takes.
-- fireproximityprompt triggers server-side and skips the client entirely; InputHoldBegin
-- goes down the real input path so the client's own Triggered fires too; SendKeyEvent is
-- an actual key press. Which one wins is not stable between games, so all three stay.
--
-- This prompt is a HOLD (HoldDuration 0.5), and a hold is not a tap: begin, poll, end --
-- once. Re-pressing on a beat sends HoldEnded every 0.1s, which is exactly what the engine
-- reads as "they let go", so the hold never completes and the grab never lands however
-- long you spin. A leaked begin sticks the prompt held and poisons every later grab, so
-- release() runs on every exit including the failures.
local function holdOnce(prompt, method, model, mine, pin)
	local began = false
	local function release()
		if not began then
			return
		end
		began = false
		if method == 2 then
			pcall(function()
				prompt:InputHoldEnd()
			end)
		elseif method == 3 then
			pcall(function()
				VIM:SendKeyEvent(false, prompt.KeyboardKeyCode, false, game)
			end)
		end
	end

	if method == 1 then
		if not fireproximityprompt then
			return false
		end
		pcall(fireproximityprompt, prompt, math.max(prompt.HoldDuration, 0))
	elseif method == 2 then
		if not pcall(function()
			prompt:InputHoldBegin()
		end) then
			return false
		end
		began = true
	else
		if not pcall(function()
			VIM:SendKeyEvent(true, prompt.KeyboardKeyCode, false, game)
		end) then
			return false
		end
		began = true
	end

	local deadline = os.clock() + math.max(prompt.HoldDuration, 0.05) + HOLD_GRACE
	while os.clock() < deadline do
		if carrier(model) == player.UserId then
			release()
			return true
		end
		if not alive(mine) or model.Parent == nil then
			release()
			return false
		end
		-- Correct a real slide, don't rewrite the CFrame every tick: a character standing
		-- on the ground barely moves, and re-pinning one that IS moving is the bounce.
		local root = hrp()
		if root and (root.Position - pin.Position).Magnitude > DRIFT then
			root.CFrame = pin
		end
		task.wait(0.05)
	end
	release()
	return false
end

local winner = nil -- the press method that last actually took an NPC

-- true = it is ours, false = it refused for the whole window, nil = nothing to press at
-- (not streamed in). Conflating the last two makes a streaming hiccup read as a refusal.
local function grab(model, mine)
	step("grab " .. tostring(model:GetAttribute("NPCId")) .. " / reach")
	local prompt = model:FindFirstChild("Prompts") and model.Prompts:FindFirstChild("Pickup")
	if not prompt then
		prompt = model:WaitForChild("Prompts", ARRIVE)
		prompt = prompt and prompt:FindFirstChild("Pickup")
	end
	if not prompt then
		prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
	end
	if not prompt then
		return nil
	end

	-- All three of these gates are enforced by the client, which is us. Out of range there
	-- is no press at all, which reads as a refusal rather than a miss. math.huge is
	-- rejected by the engine and throws, so: big and finite.
	local hadLOS, hadDist = prompt.RequiresLineOfSight, prompt.MaxActivationDistance
	pcall(function()
		prompt.RequiresLineOfSight = false
		prompt.MaxActivationDistance = 500
		prompt.Enabled = true
	end)

	-- Stand beside it at its own height, decided once. Facing it as well, so the E badge
	-- lands where a player's would and nothing about the pose is odd.
	local anchor = prompt:FindFirstAncestorWhichIsA("BasePart")
	local aim = anchor and anchor.Position or model:GetPivot().Position
	local pin = CFrame.new(aim + Vector3.new(STAND_OFF, 0, 0), aim)
	tp(pin)

	step("grab " .. tostring(model:GetAttribute("NPCId")) .. " / press")
	local since = os.clock()
	local deadline = since + GRAB_TIMEOUT
	-- Once one method has actually taken an NPC, use it alone. Cycling all three after that
	-- spends two thirds of every grab window on holds we know don't work here.
	local order = winner and { winner } or { 1, 2, 3 }
	local i = 0
	while alive(mine) and os.clock() < deadline do
		i = i + 1
		local method = order[((i - 1) % #order) + 1]
		if holdOnce(prompt, method, model, mine, pin) then
			winner = method
			pcall(function()
				prompt.RequiresLineOfSight = hadLOS
				prompt.MaxActivationDistance = hadDist
			end)
			return true
		end
		if model.Parent == nil or (model:GetAttribute("BeingCarried") and carrier(model) ~= player.UserId) then
			break -- expired, or someone else got there first
		end
	end

	pcall(function()
		prompt.RequiresLineOfSight = hadLOS
		prompt.MaxActivationDistance = hadDist
	end)
	if carrier(model) == player.UserId then
		return true
	end
	local why = alertSince(since)
	if why then
		post(why) -- the server answered; that alone proves the press reached it
	end
	return false
end

-- Arriving in the Safe zone IS the deposit -- the server flips your Zone attribute and
-- takes the NPC in the same tick. There is no deposit remote to fire.
local function bank(mine)
	local home = homeCFrame()
	if not home then
		post("no plot found -- claim one and the farm can bank")
		return false
	end
	step("bank / travel")
	tp(home)
	step("bank / wait")
	local deadline = os.clock() + DEPOSIT_TIMEOUT
	while alive(mine) and os.clock() < deadline do
		-- Empty hands is the confirm, and it is read the same way whether we still have a
		-- model reference or the thing streamed out on the way home.
		if carrying() == false then
			return true
		end
		local root = hrp()
		if root then
			root.CFrame = home -- hold the spot; a drift out of Safe cancels the handover
		end
		task.wait(0.1)
	end
	return false
end

local function sweep(mine)
	-- Finish a carry we started before doing anything else -- one at a time is the
	-- server's rule, and a held NPC blocks every later grab.
	if carrying() ~= false then
		if bank(mine) then
			farm.got = farm.got + 1
		end
		task.wait(BANK_SETTLE)
		return true
	end

	step("scan")
	local list = candidates()
	if #list == 0 then
		status("field empty -- waiting for spawns")
		return false
	end

	local pick = list[1]
	local model = pick.model
	local name = tostring(model:GetAttribute("NPCId"))
	status(("going for %s (%s) -- %s/s"):format(name, tostring(model:GetAttribute("Mutation")), money(pick.score)))

	-- Aim twice: this first hop can only target the bare model, which on a streamed-out one
	-- is wherever the pivot sits. grab() re-aims off the prompt's own part once it exists.
	local hop = tp(model:GetPivot().Position + Vector3.new(STAND_OFF, 0, 0))
	if hop == false then
		farm.reverts = farm.reverts + 1
		if farm.reverts >= REVERT_STRIKES then
			post("the server keeps putting me back where I started -- teleports are being refused")
			farm.reverts = 0
		end
		return true
	elseif hop == nil then
		task.wait(0.5) -- respawning; not a revert
		return true
	end
	farm.reverts = 0

	-- A far model replicates as a Model and nothing else, so the parts are the grab's job,
	-- not the filter's.
	if not model.PrimaryPart then
		model:WaitForChild("HumanoidRootPart", ARRIVE)
	end

	local got = grab(model, mine)
	if got == true then
		farm.last = name
		if bank(mine) then
			farm.got = farm.got + 1
			post(("banked %s -- %d this run"):format(name, farm.got))
		else
			post(("carried %s but the handover never landed -- am I on my own plot?"):format(name))
		end
		task.wait(BANK_SETTLE)
	elseif got == false then
		parked[model] = os.clock() + REFUSE_PARK
		misses[model] = nil
		farm.missed = farm.missed + 1
	else
		-- Never streamed in. Free the first couple of times, then parked anyway: under a
		-- best-first sort an unreachable target sits at the head of the queue forever.
		local n = (misses[model] or 0) + 1
		misses[model] = n
		if n >= MISS_STRIKES then
			parked[model] = os.clock() + REFUSE_PARK
			post(("%s never streams in -- parking it"):format(name))
		end
	end
	return true
end

local function setFarm(state)
	farm.on = state
	farm.gen = farm.gen + 1
	if not state then
		status("farm off")
		return
	end
	if not (SharedUtils and GammaHelper) then
		post("SharedUtils/GammaNumHelper would not load -- nothing to rank NPCs by")
		return
	end
	local mine = farm.gen
	task.spawn(function()
		post("farm on")
		while alive(mine) do
			local did
			local ok, err = pcall(function()
				did = sweep(mine)
			end)
			if not ok then
				post("sweep error: " .. tostring(err))
			end
			task.wait(did and 0 or IDLE)
		end
		step("idle")
	end)
end

-- plot -----------------------------------------------------------------------
local collector = { on = false, gen = 0 }
local equipper = { on = false, gen = 0 }
local sorter = { on = false, gen = 0 }

-- Built by the panel below; a loop that switches itself off has to push the row with it,
-- and Set(v, false) suppresses the callback so the off branch doesn't re-enter.
local collectToggle, sortToggle

-- Occupied slots come off the replica, not off the plot Models: the farm parks you a few
-- hundred studs away and the plot streams out, which would read as "no slots" everywhere
-- except standing at home.
local function occupiedSlots()
	local rep = replica()
	if not rep or type(rep.Data.Slots) ~= "table" then
		return nil
	end
	local out = {}
	for k, s in pairs(rep.Data.Slots) do
		local i = tonumber(k)
		if i and type(s) == "table" and s.Occupied == true then
			table.insert(out, { slot = i, guid = s.NPCGuid })
		end
	end
	table.sort(out, function(a, b)
		return a.slot < b.slot
	end)
	return out
end

local function collectOnce()
	if not myPlot() then
		return nil
	end
	local slots = occupiedSlots()
	if not slots then
		return nil
	end
	for _, s in ipairs(slots) do
		pcall(function()
			CollectCash:FireServer(s.slot)
		end)
		task.wait(COLLECT_GAP)
	end
	return #slots
end

local function setCollect(state)
	collector.on = state
	collector.gen = collector.gen + 1
	if not state then
		return
	end
	local mine = collector.gen
	task.spawn(function()
		while running and collector.on and collector.gen == mine do
			local n = collectOnce()
			if n == nil then
				post("collect needs your plot and the client's save mirror -- one of them isn't there")
				if collector.gen == mine then
					collector.on = false
					pcall(function()
						collectToggle:Set(false, false)
					end)
				end
				return
			end
			status(("collected %d slots"):format(n))
			task.wait(COLLECT_EVERY)
		end
	end)
end

local function setEquip(state)
	equipper.on = state
	equipper.gen = equipper.gen + 1
	if not state then
		return
	end
	local mine = equipper.gen
	task.spawn(function()
		while running and equipper.on and equipper.gen == mine do
			pcall(function()
				EquipBestNPCs:FireServer()
			end)
			task.wait(EQUIP_EVERY)
		end
	end)
end

-- Rank everything placed, hand each one the floor it belongs on -- best on floor 1, then
-- up. MoveNPCSlot only takes a floor and only lands in a free slot there, so this resolves
-- over several passes as holes open. A completely full plot cannot be reordered at all.
-- ponytail: floor granularity. Exact per-slot order would mean PickupSlotNPC to open a
-- hole and PlaceNPC(guid, slot) to place into it -- add that if within-floor order matters.
local function sortOnce()
	local rep = replica()
	if not rep or type(rep.Data.NPCs) ~= "table" then
		return nil, "no save mirror"
	end
	local slots = occupiedSlots()
	if not slots or #slots == 0 then
		return 0, "nothing placed"
	end

	local ranked = {}
	for _, s in ipairs(slots) do
		local entry = s.guid and rep.Data.NPCs[s.guid]
		table.insert(ranked, { guid = s.guid, score = scoreOwned(entry) })
	end
	table.sort(ranked, function(a, b)
		return a.score > b.score
	end)

	local want = {}
	for rank, e in ipairs(ranked) do
		want[e.guid] = math.ceil(rank / 10)
	end

	local max = slotCount()
	local moves = 0
	for _ = 1, SORT_PASSES do
		local live = occupiedSlots()
		if not live then
			break
		end
		local filled = {}
		for _, s in ipairs(live) do
			local f = math.ceil(s.slot / 10)
			filled[f] = (filled[f] or 0) + 1
		end
		local moved = false
		for _, s in ipairs(live) do
			local target = want[s.guid]
			local here = math.ceil(s.slot / 10)
			if target and target ~= here then
				local capacity = math.min(target * 10, max) - ((target - 1) * 10 + 1) + 1
				if capacity > (filled[target] or 0) then
					pcall(function()
						MoveNPCSlot:FireServer(s.slot, target)
					end)
					filled[target] = (filled[target] or 0) + 1
					filled[here] = (filled[here] or 1) - 1
					moves, moved = moves + 1, true
					task.wait(MOVE_GAP)
				end
			end
		end
		if not moved then
			break
		end
	end
	return moves, moves == 0 and "already in order, or no free slot to move into" or nil
end

local function setSort(state)
	sorter.on = state
	sorter.gen = sorter.gen + 1
	if not state then
		return
	end
	local mine = sorter.gen
	task.spawn(function()
		while running and sorter.on and sorter.gen == mine do
			local moves, why = sortOnce()
			if moves == nil then
				post("sort needs the client's save mirror -- " .. tostring(why))
				if sorter.gen == mine then
					sorter.on = false
					pcall(function()
						sortToggle:Set(false, false)
					end)
				end
				return
			end
			status(moves > 0 and ("sorted -- %d moved"):format(moves) or ("sort: " .. tostring(why)))
			task.wait(SORT_EVERY)
		end
	end)
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Don't Steal a Bobo", -- fallback until the live name lands
	folder = "DontStealABobo", -- unchanged: renaming it orphans configs already saved in-game
	size = UDim2.fromOffset(500, 400),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local line = Tab:Paragraph({ Title = "Status", Desc = "idle" })

local Field = Tab:Section({ Title = "Field", Icon = "solar:leaf-bold", Box = true, BoxBorder = true, Opened = true })

Field:Toggle({
	Title = "Auto farm best",
	Desc = "TP to the highest-income NPC in the field, hold its prompt, TP back to your plot. One at a time -- the carry is one at a time.",
	Value = false,
	Callback = setFarm,
})

Field:Button({
	Title = "What's out there?",
	Desc = "Prints the top of the field to the console without touching anything.",
	Callback = function()
		local list = candidates()
		if #list == 0 then
			post("field is empty")
			return
		end
		for i = 1, math.min(5, #list) do
			print(
				("[bobo] #%d %s (%s, %s) -- %s/s"):format(
					i,
					tostring(list[i].model:GetAttribute("NPCId")),
					tostring(list[i].model:GetAttribute("Mutation")),
					tostring(list[i].model:GetAttribute("Variation")),
					money(list[i].score)
				)
			)
		end
		post(("%d NPCs in the field, best is %s"):format(#list, tostring(list[1].model:GetAttribute("NPCId"))))
	end,
})

local Plot = Tab:Section({ Title = "Plot", Icon = "solar:wallet-money-bold", Box = true, BoxBorder = true, Opened = true })

collectToggle = Plot:Toggle({
	Title = "Auto collect cash",
	Desc = "Fires the collect remote for every occupied slot on your plot. Never moves you, so it runs alongside the farm.",
	Value = false,
	Callback = setCollect,
})

Plot:Toggle({
	Title = "Auto equip best",
	Desc = "The game's own Equip Best button, on a timer. The server picks; nothing here second-guesses it.",
	Value = false,
	Callback = setEquip,
})

sortToggle = Plot:Toggle({
	Title = "Auto sort plot",
	Desc = "Best earners on floor 1, worst on top. Floor-level, not slot-level -- and a completely full plot can't be reordered.",
	Value = false,
	Callback = setSort,
})

Plot:Button({
	Title = "Collect now",
	Callback = function()
		local n = collectOnce()
		post(n and ("collected %d slots"):format(n) or "no plot, or no save mirror to read slots from")
	end,
})

Plot:Button({
	Title = "Sort now",
	Callback = function()
		local moves, why = sortOnce()
		post(moves and (moves > 0 and ("moved %d"):format(moves) or tostring(why)) or ("sort: " .. tostring(why)))
	end,
})

-- Drains whatever the loops last left. pcall'd anyway: if even this cannot write the panel
-- the run carries on with the status going nowhere, rather than taking a loop down with it.
local drain, lastPrinted
drain = RunService.Heartbeat:Connect(function()
	if pending == nil then
		return
	end
	local msg, quiet = pending, pendingQuiet
	pending = nil
	pcall(function()
		line:SetDesc(msg)
	end)
	if not quiet and msg ~= lastPrinted then
		lastPrinted = msg
		print("[bobo]", msg)
	end
end)

-- A farm thread parked in a yield cannot report anything, so the watchdog is its own
-- thread. The halves of a step are named separately: "grab X / reach" and "grab X / press"
-- stop for completely different reasons.
task.spawn(function()
	local told
	while running do
		task.wait(5)
		if farm.on and os.clock() - markAt > STUCK_AFTER and told ~= mark then
			told = mark
			warn(("[bobo] stuck %ds at: %s"):format(math.floor(os.clock() - markAt), mark))
		end
	end
end)

post(myPlot() and ("ready -- plot %s"):format(tostring(myPlot():GetAttribute("PlotIndex"))) or "ready -- no plot claimed yet")

-- close ------------------------------------------------------------------------
local function stopAll()
	running = false
	farm.on = false
	farm.gen = farm.gen + 1
	collector.on = false
	collector.gen = collector.gen + 1
	equipper.on = false
	equipper.gen = equipper.gen + 1
	sorter.on = false
	sorter.gen = sorter.gen + 1
	pcall(function()
		alertConn:Disconnect()
	end)
	pcall(function()
		drain:Disconnect()
	end)
end

Window:OnDestroy(function()
	stopAll()
	getgenv().boboStop = nil
end)

getgenv().boboStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().boboStop = nil
end
