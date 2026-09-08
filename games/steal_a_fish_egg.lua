--[[ Steal a Fish Egg -- fish eggs off the ocean beds (99183404085821)

     FARM   : scores every egg on the map, teleports to the best one, holds its prompt,
              and banks it by firing TheLinePart's touch -- from wherever it is standing.

              There is no return trip. The steal completes on a server-side Touched on
              workspace.TheLine.TheLinePart, and firetouchinterest reaches that handler
              without moving you, so a Mythic in Atlantis costs one teleport, not two.

              "Best" is the fish's PerSec out of the game's own FishSystem.FishConfig,
              times the egg's Scale multiplier (Scale, not Kg -- feeding raw Kg into
              PerSecScaleExponent saturates the clamp at 118kg and eggs run to 1.3M).
              NOT rarity: rarity is fixed per fish type and runs
              backwards against value -- an Epic ChickenFish (6,500/s) is worth 3.7x a
              Legendary Dolphin (1,770/s), and an Epic MohawkTang (14/s) is worth less
              than a Basic Stingray (22/s). Rarity is printed, never sorted on.

     MIN $/S: eggs scoring under this are skipped. You carry one egg at a time and each
              one costs a Backpack slot you place by hand, so hauling a 5/s Goldfish is
              worse than waiting. With nothing over the floor it parks at your base and
              idles on SpawnedEggs.ChildAdded rather than spinning -- out of the chasers'
              water, and where you place what it banked.

     TP BASE: a button, to your own base's SpawnPoint -- where you place what you banked.
              Refuses while Auto Farm is on rather than teleporting you mid-grab.

     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().stealFishEggStop() ]]

-- config ---------------------------------------------------------------------
local LIFT = 6 -- studs above an egg's PrimaryPart to land. The prompt reaches ~15 and the
-- models are a few studs tall, so this is "close enough to grab, not inside the mesh".
local OPEN_DIST = 200 -- what we force MaxActivationDistance to before pressing. All three
-- prompt gates are client-enforced, so all three can be opened -- but math.huge is
-- rejected by the engine and THROWS, inside the pcall, with nothing in the console.
local SETTLE = 0.35 -- after a hop, before the first press. The prompt's range check runs
-- against where the SERVER thinks we are. Raise if grabs fire but nothing lands.
local PRESS_GAP = 0.05 -- between re-fires of the prompt. The grab landed in 0.05s when
-- probed, so this is a retry cadence, not a hold timer.
local GRAB_TIMEOUT = 4 -- give up on one egg. A grab that lands does so well under 1s;
-- this wants to stay small, because a refusal is what teaches us to park a target.
local BANK_TIMEOUT = 3 -- wait for the in-place touch to bank before falling back to the
-- line. Two round trips, so it needs headroom over ping.
local LINE_BANK_TIMEOUT = 5 -- wait after actually hopping to the line
local ARRIVE = 3 -- WaitForChild budget for an egg's PrimaryPart after a hop
local SNAP_CHECK = 0.6 -- how long after a hop to re-check position. A server revert only
-- shows up after a round trip; checking immediately would always read "arrived".
local SNAP_TOLERANCE = 60 -- studs. Past this we were put back, not merely drifting.
local REVERT_STRIKES = 3 -- consecutive reverts before the hop is retired for the session
local REFUSE_STRIKES = 3 -- refusals before a target is parked
local PARK_SECONDS = 90 -- how long a parked target stays skipped
local MISS_STRIKES = 3 -- consecutive "no prompt to fire at" before parking too. Something
-- we can never reach still has to step aside, even though it never refused us.
local IDLE_BEAT = 5 -- re-check cadence while idling under the floor, as a backstop to the
-- ChildAdded wakeup in case a spawn ever lands without firing it
local BASE_RADIUS = 25 -- how close to the base spawn counts as "already parked". Wide
-- enough that ordinary drift doesn't re-teleport you every idle beat.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local player = Players.LocalPlayer

if getgenv and getgenv().stealFishEggStop then
	getgenv().stealFishEggStop() -- re-running must not stack a second panel or loop
end

-- The panel drains this from a Heartbeat, which the engine calls with our own identity.
-- A loop thread that writes to the window directly gets away with its first write and
-- throws "lacking capability Plugin" on every one after a task.wait.
local pending = nil
local function say(msg)
	pending = msg
end

local function log(...)
	print("[stealegg]", ...)
end

-- world ----------------------------------------------------------------------
local function char()
	local c = player.Character
	if not c then
		return nil, nil
	end
	local hrp = c:FindFirstChild("HumanoidRootPart")
	return (hrp and c or nil), hrp
end

local function carrying()
	return player:GetAttribute("CarryingEgg") == true
end

-- Banking and LOSING the egg both clear CarryingEgg, so the only honest confirm is a Tool
-- that wasn't there before. It lands in the Backpack and is auto-equipped into the
-- Character about a tenth of a second later -- ChaseCarryUI unequips everything while you
-- carry, so it re-equips the moment the carry ends -- which is why both are scanned.
local function toolNames()
	local seen = {}
	local c = player.Character
	for _, where in ipairs({ player:FindFirstChildOfClass("Backpack"), c }) do
		if where then
			for _, t in ipairs(where:GetChildren()) do
				if t:IsA("Tool") then
					seen[t] = true
				end
			end
		end
	end
	return seen
end

local function gainedTool(before)
	local c = player.Character
	for _, where in ipairs({ player:FindFirstChildOfClass("Backpack"), c }) do
		if where then
			for _, t in ipairs(where:GetChildren()) do
				if t:IsA("Tool") and not before[t] then
					return t.Name
				end
			end
		end
	end
	return nil
end

-- scoring --------------------------------------------------------------------
-- The whole value model is one require. PerSec spans 5 to 196,000,000 across the 37 fish
-- while Kg only moves the payout inside a 0.7..2 band, so PerSec dominates by seven orders
-- of magnitude and a Kg sort is not a near-miss -- it is a different farm.
local byModel, kgMin, kgMax, kgExp = nil, 0.7, 2, 0.22

local function loadConfig()
	local ok, cfg = pcall(function()
		local sys = ReplicatedStorage:WaitForChild("FishSystem", 10)
		return require(sys:WaitForChild("FishConfig", 10))
	end)
	if not ok or type(cfg) ~= "table" or type(cfg.Fish) ~= "table" then
		warn("[stealegg] FishConfig failed to load -- falling back to a Kg sort, which ranks")
		warn("[stealegg] eggs WRONG. Check whether the module moved:", cfg)
		return false
	end
	byModel = {}
	local n = 0
	for _, fish in pairs(cfg.Fish) do
		if type(fish) == "table" and fish.EggModelName then
			byModel[fish.EggModelName] = fish
			n = n + 1
		end
	end
	local s = cfg.Settings
	if type(s) == "table" then
		kgMin = tonumber(s.MinPerSecMultiplier) or kgMin
		kgMax = tonumber(s.MaxPerSecMultiplier) or kgMax
		kgExp = tonumber(s.PerSecScaleExponent) or kgExp
	end
	log(("FishConfig loaded -- %d egg types, Kg multiplier %.2f..%.2f"):format(n, kgMin, kgMax))
	return true
end

-- The server computes the real FishPerSec and never sends us the formula, so this is a
-- monotonic approximation from the same constants. It only has to ORDER eggs correctly,
-- and against a 7-order-of-magnitude PerSec spread this band cannot flip the ranking
-- except between two eggs of the same type -- where it is exactly the right tiebreak.
--
-- It takes SCALE, not Kg. The constant is PerSec*Scale*Exponent and it pairs with
-- Min/MaxPerSecMultiplier the same way PerSecGuiScaleExponent pairs with
-- PerSec{Min,Max}GuiScale. Feeding it raw Kg saturates the clamp at 118kg -- every egg
-- above that would score identically, and eggs run to 1,300,000kg.
local function sizeMult(model)
	local scale = tonumber(model:GetAttribute("Scale"))
	if not scale or scale <= 0 then
		-- No Scale attribute: fall back to Kg so ordering degrades rather than collapsing.
		-- EggConfig.KgScalePoints is the real Kg->Scale curve; this is its rough shape.
		local kg = tonumber(model:GetAttribute("Kg")) or 0
		scale = kg > 0 and math.clamp(0.75 * (kg ^ 0.13), 0.75, 6.5) or 0.75
	end
	return math.clamp(scale ^ kgExp, kgMin, kgMax)
end

local function scoreOf(model)
	if not byModel then
		return tonumber(model:GetAttribute("Kg")) or 0 -- degraded, but not nothing
	end
	local fish = byModel[model:GetAttribute("EggType")]
	if not fish then
		return 0
	end
	return (tonumber(fish.PerSec) or 0) * sizeMult(model)
end

-- Self-checks: the ordering is the whole feature, so it fails loudly at load rather than
-- quietly ranking eggs wrong for a whole session.
do
	local function fake(attrs)
		return { GetAttribute = function(_, k)
			return attrs[k]
		end }
	end
	assert(sizeMult(fake({ Scale = 6.5 })) > sizeMult(fake({ Scale = 0.75 })), "sizeMult rises with Scale")
	assert(sizeMult(fake({ Scale = 6.5 })) < kgMax, "sizeMult must NOT saturate across the real Scale range")
	assert(sizeMult(fake({ Kg = 75000 })) > sizeMult(fake({ Kg = 10 })), "Kg fallback stays monotonic")
	assert(sizeMult(fake({})) >= kgMin, "no attributes at all still floors cleanly")
end

local function labelOf(model)
	return ("%s / %s / %s kg"):format(
		tostring(model:GetAttribute("DisplayName") or model.Name),
		tostring(model:GetAttribute("Rarity")),
		tostring(math.floor(tonumber(model:GetAttribute("Kg")) or 0))
	)
end

local function money(n)
	for _, unit in ipairs({ { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
		if n >= unit[1] then
			return ("%.1f%s"):format(n / unit[1], unit[2])
		end
	end
	return ("%.0f"):format(n)
end

-- Weak keys, so a despawned egg drops out of the park list on its own.
local parked = setmetatable({}, { __mode = "k" })
local refusals = setmetatable({}, { __mode = "k" })
local misses = setmetatable({}, { __mode = "k" })

local floor = 0 -- live, written by the Min $/s input

local function best()
	local folder = workspace:FindFirstChild("SpawnedEggs")
	if not folder then
		return nil
	end
	local now = os.clock()
	local pick, pickScore
	for _, m in ipairs(folder:GetChildren()) do
		if m:IsA("Model") and m:GetAttribute("PromptBusy") ~= true then
			local until_ = parked[m]
			if not until_ or now >= until_ then
				local s = scoreOf(m)
				if s >= floor and (not pickScore or s > pickScore) then
					pick, pickScore = m, s
				end
			end
		end
	end
	return pick, pickScore
end

-- travel ---------------------------------------------------------------------
local hopRetired = false
local reverts = 0

-- Three answers, not two. Counting a respawn as a revert would retire the fast path over
-- nothing, and conflating "reverted" with "arrived" hides the one thing worth knowing.
local function hop(pos)
	local c, hrp = char()
	if not c then
		return "nochar"
	end
	hrp.CFrame = CFrame.new(pos)
	task.wait(SNAP_CHECK)
	local c2, hrp2 = char()
	if not c2 then
		return "nochar"
	end
	if (hrp2.Position - pos).Magnitude > SNAP_TOLERANCE then
		return "reverted"
	end
	return "ok"
end

-- MoveTo only steers and gives up after ~6-8s, so it has to be re-issued on a beat.
local function swimTo(pos, budget)
	local c = select(1, char())
	if not c then
		return false
	end
	local hum = c:FindFirstChildOfClass("Humanoid")
	if not hum then
		return false
	end
	local deadline = os.clock() + (budget or 20)
	while os.clock() < deadline do
		local c2, hrp2 = char()
		if not c2 then
			return false
		end
		if (hrp2.Position - pos).Magnitude < 12 then
			return true
		end
		hum:MoveTo(pos)
		task.wait(0.5)
	end
	return false
end

local function travel(pos)
	if not hopRetired then
		local verdict = hop(pos)
		if verdict == "ok" then
			reverts = 0
			return true
		elseif verdict == "nochar" then
			return false -- a respawn, not a refusal: leave the strike count alone
		end
		reverts = reverts + 1
		warn(("[stealegg] teleport was undone (%d/%d)"):format(reverts, REVERT_STRIKES))
		if reverts >= REVERT_STRIKES then
			hopRetired = true
			warn("[stealegg] the server is refusing teleports -- swimming from here on.")
			say("teleport refused, swimming")
		end
	end
	return swimTo(pos)
end

-- grab -----------------------------------------------------------------------
-- All three gates are enforced by the client, which is us, so all three can be opened.
-- Out of range there is no press at all, which reads as a refusal rather than a miss.
local function openGates(prompt)
	pcall(function()
		prompt.Enabled = true
		prompt.RequiresLineOfSight = false
		prompt.MaxActivationDistance = OPEN_DIST
	end)
end

-- fireproximityprompt won every probe in 0.05s, so it leads. The other two are kept
-- because which one wins is not stable between games or runs, and a fallback that is
-- never reached costs nothing.
local function press(prompt)
	if fireproximityprompt then
		pcall(function()
			fireproximityprompt(prompt, 1)
		end)
		return
	end
	local ok = pcall(function()
		prompt:InputHoldBegin()
	end)
	if ok then
		-- InputHoldEnd on EVERY exit: a leaked begin sticks the prompt held and poisons
		-- every later grab.
		task.delay(prompt.HoldDuration + 0.35, function()
			pcall(function()
				prompt:InputHoldEnd()
			end)
		end)
		return
	end
	local key = prompt.KeyboardKeyCode
	if key and key ~= Enum.KeyCode.Unknown then
		VirtualInputManager:SendKeyEvent(true, key, false, game)
		task.delay(prompt.HoldDuration + 0.35, function()
			VirtualInputManager:SendKeyEvent(false, key, false, game)
		end)
	end
end

-- "ok" | "refused" | "nostream". A streaming hiccup and a refusal are different bugs and
-- get fixed in opposite ways, so they must not share an answer.
local function grab(model, alive)
	local part = model.PrimaryPart or model:WaitForChild("PrimaryPart", ARRIVE)
	if not part then
		return "nostream"
	end
	local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
	if not prompt then
		return "nostream"
	end
	openGates(prompt)

	-- Pin to a spot read ONCE, before the loop: the grab puts the egg above your
	-- shoulders, so re-reading its live pivot each pass turns you into a rocket.
	local pin = part.Position + Vector3.new(0, LIFT, 0)
	task.wait(SETTLE)

	local deadline = os.clock() + GRAB_TIMEOUT
	while os.clock() < deadline do
		if not alive() then
			return "refused"
		end
		if carrying() then
			return "ok"
		end
		press(prompt)
		local _c, hrp = char()
		if hrp then
			hrp.CFrame = CFrame.new(pin) -- hold through knockback; a chaser would otherwise
			-- drag us out of range and a working press would read as a refusal
		end
		task.wait(PRESS_GAP)
	end
	return carrying() and "ok" or "refused"
end

-- base -----------------------------------------------------------------------
-- Known path first, scan as the fallback: the player's own BaseName attribute names it
-- directly, but that attribute is only useful if it still agrees with OwnerUserId -- a
-- base gets reassigned when someone leaves.
local function myBase()
	local bases = workspace:FindFirstChild("Bases")
	if not bases then
		return nil
	end
	local named = player:GetAttribute("BaseName")
	if named then
		local b = bases:FindFirstChild(tostring(named))
		if b and b:GetAttribute("OwnerUserId") == player.UserId then
			return b
		end
	end
	for _, b in ipairs(bases:GetChildren()) do
		if b:GetAttribute("OwnerUserId") == player.UserId then
			return b
		end
	end
	return nil
end

-- Returns the spot to stand on, or nil. The base MODEL's pivot is ~13 studs up in the air
-- above the tank, so landing on that drops you; SpawnPoint is the one on the ground.
local function baseSpot()
	local b = myBase()
	if not b then
		return nil
	end
	local spawn = b:FindFirstChild("SpawnPoint")
	if spawn and spawn:IsA("BasePart") then
		return spawn.Position + Vector3.new(0, 3, 0), b.Name
	end
	return b:GetPivot().Position, b.Name
end

-- Distance rather than a "we already parked" flag: a respawn, a chaser knockback or a
-- manual swim all move us off the pad, and a flag would keep insisting we are still there.
local function nearBase(spot)
	local _c, hrp = char()
	return hrp ~= nil and (hrp.Position - spot).Magnitude < BASE_RADIUS
end

-- bank -----------------------------------------------------------------------
local function theLine()
	local folder = workspace:FindFirstChild("TheLine")
	return folder and folder:FindFirstChild("TheLinePart")
end

local function fireLine(line)
	local _c, hrp = char()
	if not hrp or not firetouchinterest then
		return false
	end
	pcall(function()
		firetouchinterest(hrp, line, 0) -- begin
	end)
	task.wait(0.15)
	pcall(function()
		firetouchinterest(hrp, line, 1) -- end
	end)
	return true
end

local function waitBanked(before, window)
	local deadline = os.clock() + window
	while os.clock() < deadline do
		if not carrying() then
			task.wait(0.4) -- the Tool is a second round trip after the attribute clears
			return gainedTool(before)
		end
		task.wait(0.05)
	end
	return nil
end

-- Fires in place first. That was probe-confirmed on a CoralReef egg, near the line -- what
-- is NOT proven is whether it still registers from the far end of the map, so the hop to
-- the line stays as a fallback and the console says which path actually paid.
local function bank(before)
	local line = theLine()
	if not line then
		warn("[stealegg] workspace.TheLine.TheLinePart is gone -- the map changed")
		return nil
	end

	if fireLine(line) then
		local tool = waitBanked(before, BANK_TIMEOUT)
		if tool then
			return tool, "in place"
		end
	end

	-- Into the part's own plane at a Y inside its extents, not past it: a jump that lands
	-- beyond a Touched volume never intersects it and fires nothing.
	local y = math.max(line.Position.Y - line.Size.Y / 2 + 3, 118)
	travel(Vector3.new(line.Position.X, y, line.Position.Z))
	fireLine(line)
	local tool = waitBanked(before, LINE_BANK_TIMEOUT)
	if tool then
		return tool, "at the line"
	end
	return nil
end

-- farm -----------------------------------------------------------------------
local farming, gen = false, 0
local spawnWatch, notify, drain = nil, nil, nil
local setFarming -- forward, so the toggle can switch itself off

local function cycle(alive)
	local model, score = best()
	if not model then
		return "idle"
	end

	local label = labelOf(model)
	say(("-> %s ($%s/s)"):format(label, money(score)))

	local part = model.PrimaryPart
	local pos = part and part.Position or model:GetPivot().Position
	if not travel(pos + Vector3.new(0, LIFT, 0)) then
		return "moved" -- no character, or swimming timed out; just go round again
	end
	if not alive() then
		return "stopped"
	end

	local before = toolNames()
	local result = grab(model, alive)

	if result == "nostream" then
		local n = (misses[model] or 0) + 1
		misses[model] = n
		if n >= MISS_STRIKES then
			parked[model] = os.clock() + PARK_SECONDS
			misses[model] = nil
			log(("parked %s -- unreachable %dx"):format(label, n))
		end
		return "moved"
	elseif result == "refused" then
		misses[model] = nil
		local n = (refusals[model] or 0) + 1
		refusals[model] = n
		if n >= REFUSE_STRIKES then
			parked[model] = os.clock() + PARK_SECONDS
			refusals[model] = nil
			log(("parked %s -- refused %dx"):format(label, n))
		end
		return "moved"
	end

	misses[model], refusals[model] = nil, nil
	local tool, how = bank(before)
	if tool then
		log(("banked %s ($%s/s) %s -- %s"):format(label, money(score), how, tool))
		say(("banked %s ($%s/s)"):format(label, money(score)))
		return "banked"
	end

	warn(("[stealegg] grabbed %s but could not bank it. Check F9 for the game's own"):format(label))
	warn("[stealegg] notification -- that is where the server words its reason.")
	say("grabbed but could not bank")
	return "moved"
end

setFarming = function(on)
	farming = on
	gen = gen + 1
	local mine = gen
	local function alive()
		return farming and gen == mine
	end

	if not on then
		if spawnWatch then
			spawnWatch:Disconnect()
			spawnWatch = nil
		end
		say("stopped")
		return
	end

	local folder = workspace:FindFirstChild("SpawnedEggs")
	if not folder then
		warn("[stealegg] no workspace.SpawnedEggs -- wrong game, or it hasn't replicated yet")
		say("no SpawnedEggs folder")
		farming = false
		return
	end

	-- Event-driven idle: the same signal the game's own TutorialClient watches. A spawn
	-- wakes the loop instead of it polling an empty map.
	local wake = false
	spawnWatch = folder.ChildAdded:Connect(function()
		wake = true
	end)

	task.spawn(function()
		say("scanning")
		while alive() do
			local ok, result = pcall(cycle, alive)
			if not ok then
				warn("[stealegg] cycle threw:", result)
				task.wait(1)
			elseif result == "idle" then
				-- Wait at base, not wherever the last bank left us. Banking in place is what
				-- makes the farm fast, but it also leaves you floating in open water with the
				-- chasers -- and base is where the eggs get placed anyway.
				local spot, name = baseSpot()
				if spot and not nearBase(spot) then
					say("nothing to take -- heading to " .. tostring(name))
					travel(spot)
				end
				say(("nothing over $%s/s -- waiting at %s"):format(money(floor), tostring(name or "base")))
				local waited = 0
				while alive() and not wake and waited < IDLE_BEAT do
					task.wait(0.25)
					waited = waited + 0.25
				end
				wake = false
			elseif result == "banked" then
				task.wait(0.1) -- a pass that did something goes straight round
			else
				task.wait(0.3)
			end
		end
		-- Only the current generation may flip the switch off, or an old thread finishing
		-- kills a farm that has since been restarted.
		if gen == mine then
			say("stopped")
		end
	end)
end

-- gui ------------------------------------------------------------------------
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a restyle
-- is one file and not seventeen. Fetched here rather than installed by the loader, so this
-- file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Steal a Fish Egg", -- fallback until the live name lands
	folder = "StealFishEgg", -- unchanged: renaming it orphans configs already saved in-game
	size = UDim2.fromOffset(460, 360),
})
if not Window then
	return -- panel.lua already said why
end

loadConfig()

local Tab = Window:Tab({ Title = "Main", Icon = "solar:egg-bold" })
local Farm = Tab:Section({ Title = "Farm", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })

Farm:Toggle({
	Title = "Auto Farm",
	Desc = "Best egg on the map, grab it, bank it. No return trip.",
	Value = false,
	Callback = setFarming, -- :Set() re-fires this, and setFarming is re-entrant
})

Farm:Input({
	Title = "Min $/s",
	Desc = "Skip anything worth less. Blank or 0 takes everything.",
	Value = "0",
	Placeholder = "0",
	Callback = function(text)
		floor = tonumber((tostring(text):gsub("[%$,%s]", ""))) or 0
		log(("floor set to $%s/s"):format(money(floor)))
	end,
})

Farm:Button({
	Title = "TP to base",
	Desc = "Your own base's spawn point, for placing the eggs you've banked",
	Callback = function()
		-- Refuse rather than block: a button that silently waits out a farm sweep and
		-- then teleports you mid-grab reads as broken twice over.
		if farming then
			say("turn Auto Farm off first")
			return
		end
		local spot, name = baseSpot()
		if not spot then
			say("couldn't find your base -- do you own one?")
			warn("[stealegg] no Bases child with OwnerUserId == you, and BaseName didn't resolve")
			return
		end
		say("-> " .. tostring(name))
		if travel(spot) then
			say("at " .. tostring(name))
		else
			say("couldn't reach " .. tostring(name))
		end
	end,
})

local line = Farm:Paragraph({ Title = "Status", Desc = "idle" })

drain = RunService.Heartbeat:Connect(function()
	if pending == nil then
		return
	end
	local msg = pending
	pending = nil
	if not pcall(function()
		line:SetDesc(msg)
	end) then
		print("[stealegg]", msg)
	end
end)

-- The server's real reason for a refusal is worded nowhere else -- not in any client
-- script, not on the model. Listening costs one connection.
local notifyRemote = ReplicatedStorage:FindFirstChild("NotificationRemotes")
notifyRemote = notifyRemote and notifyRemote:FindFirstChild("Notify")
if notifyRemote then
	notify = notifyRemote.OnClientEvent:Connect(function(a, b)
		log("game says:", tostring(a), tostring(b))
	end)
end

-- close ----------------------------------------------------------------------
local function stopAll()
	setFarming(false)
	if notify then
		notify:Disconnect()
		notify = nil
	end
	if drain then
		drain:Disconnect()
		drain = nil
	end
end

Window:OnDestroy(function()
	stopAll()
	getgenv().stealFishEggStop = nil
end)

getgenv().stealFishEggStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().stealFishEggStop = nil
end
