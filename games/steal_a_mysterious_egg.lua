--[[ Steal a Mysterious Egg -- dungeon egg heist, nest hatcher and treadmill roller (117032685902228)

     STEAL  : teleport onto the best egg in all eight zones, grab it, teleport home. That's the
              whole loop. "Best" is the game's own EggIncomeFloor (zone x rarity), with
              WeightKG breaking ties. Standing on your plot's Spawn banks it instantly. A
              3083-stud hop to Zone 8 was probed landing 1 stud off, so there is no walking
              and no boss to outrun. Whatever you're holding is put away before every grab:
              the server refuses a steal while an egg Tool is in your hand.
     PLACE  : its own toggle. Puts the richest backpack egg into the nest with
              PlaceHeldItem whenever the nest has room. The nest size is read off the
              server's own "(10/10 eggs)" message. SWAP (off by default) picks the weakest
              unstarted nest egg back up when a backpack egg is worth SWAP_RATIO times more.
     HATCH  : RequestHatch on every ready nest egg, from anywhere; it's the same call the
              Eggs panel makes. The game's reveal is muted and EggHatchAnimComplete is
              answered at once, which is what the server waits on before handing you
              the pet.
     TRAIN  : while the heist has nothing to take, it stands you on your treadmill (touch).
     ROLL   : RollTreadmillCreature straight to the server while you're on the treadmill,
              minus the reel animation. The game's own client rolls too and shares the
              server's ~2s cooldown, so its calls are refused locally while Auto Roll is on.
              The gap starts at 2.3s, creeps down on success and steps up on RollTooSoon.
     UPGRADES: plot income, offline income, roller luck and size, pet slots, dungeon rebirth.
              Every one starts OFF.

     Not wired, on purpose: GrowAll (dev product 3711115792), SetAutoSellRarity (AutoSell
     gamepass), PaidCompanionEgg / GiftPurchase / SuperPackOffer (Robux), TreadmillAfkRejoin
     (it rejoins you), RequestTreadmillUpgrade (no call site in the dump, arguments unknown).

     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().stealMysteriousEggStop() ]]

-- config ---------------------------------------------------------------------
local LIFT = 4 -- studs above an egg's pivot to land. Probed: the steal lands from here in 0.11s
local OPEN_DIST = 60 -- forced MaxActivationDistance. Big and finite: math.huge throws
local PRESS_GAP = 0.5 -- between re-presses. The hold is 0.35s; pressing faster only
-- cancels the hold that is already running
local GRAB_TIMEOUT = 3 -- one egg. Probed at 0.11s; this is what a refusal costs
local ARRIVE = 3 -- seconds for a far egg's prompt to stream in after the hop
local SNAP_CHECK = 0.25 -- after a hop, before trusting the position. A server revert only
-- shows after a round trip
local SNAP_TOLERANCE = 40 -- studs off target that count as "put back", not gravity drift
local REVERT_STRIKES = 3 -- consecutive reverts before hops are retired for chunked travel
local CHUNK = 150 -- studs per step once hops are retired
local CHUNK_GAP = 0.15 -- seconds between chunk steps
local BANK_TIMEOUT = 3 -- at Spawn before trying the EggHatch pad. Probed: cleared instantly
local TOOL_WAIT = 2 -- for the egg Tool after the carry clears
local PLACE_WAIT = 2 -- for a placed Tool to leave the backpack
local NEST_RETRY = 30 -- after "egg nest is full" with no size in the message, how long
-- placing stays off unless a hatch lands first
local PLACE_FAIL_PARK = 30 -- a place that neither lands nor says "full", even at home, parks
-- placing this long
local PLACE_POLL = 0.3 -- Auto Place beat. Short, so it slips in right after a bank
local SWAP_RATIO = 2 -- a backpack egg must be worth this many times the weakest nest egg
-- before Swap picks that one up. Well above 1, or two near-equal eggs would trade places forever
local PARK_SECONDS = 60 -- how long a refused or unreachable egg is skipped
local REFUSE_STRIKES = 2 -- full-timeout refusals before an egg is parked
local MISS_STRIKES = 3 -- consecutive "no prompt to press" before parking it too
local IDLE_BEAT = 5 -- max nap with nothing to steal; a spawn wakes it sooner
local HATCH_POLL = 1 -- seconds between nest scans
local HATCH_RETRY = 8 -- before re-asking for the same egg
local ROLL_GAP_START = 2.3 -- first roll gap. Recorded: the server took rolls 2.0s apart and
-- refused them at 1.9-2.0s
local ROLL_GAP_MIN = 1 -- lowest the gap may walk down to (a Double Roll Speed pass may allow it)
local ROLL_GAP_MAX = 10 -- highest a run of refusals may push it
local ROLL_DESCENT = 0.97 -- gap multiplier per accepted roll
local ROLL_STEP_UP = 0.1 -- seconds added per RollTooSoon. Small: the answer sits right above
local EQUIP_EVERY = 30 -- EquipBestPets throttle after rolls that awarded a pet
local TRAIN_BEAT = 3 -- re-check that you're still on the treadmill
local UPGRADE_BEAT = 2 -- between purchase attempts on one row
local INVOKE_TIMEOUT = 8 -- bound on every InvokeServer; a parked invoke looks like a dead loop
local STUCK_AFTER = 45 -- watchdog: seconds on one step before printing where it is stuck

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().stealMysteriousEggStop then
	getgenv().stealMysteriousEggStop() -- re-running must not stack a second panel or loop
end

local running = true
local Events = ReplicatedStorage:WaitForChild("Events", 10)
if not Events then
	warn("[mystegg] no ReplicatedStorage.Events -- wrong game?")
	return
end

local function log(...)
	print("[mystegg]", ...)
end

-- A loop thread that writes to the window directly throws "lacking capability Plugin"
-- after its first task.wait, so rows get their text through a Heartbeat drain.
local pending = {}
local function say(key, msg)
	pending[key] = msg
end

local function mod(name)
	local ok, m = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Modules", 10):WaitForChild(name, 10))
	end)
	if not ok or type(m) ~= "table" then
		warn("[mystegg] couldn't load Modules." .. name .. ":", m)
		return nil
	end
	return m
end
local Econ = mod("EggEconomyConfigurations")
local PlotUpgradeCfg = mod("DungeonPlotUpgradeConfigurations")
local RollerCfg = mod("RollerUpgradeConfigurations")
local PlotCfg = mod("PlotConfigurations")

pcall(function()
	game:GetService("GuiService"):SetGameplayPausedNotificationEnabled(false)
end)

-- helpers --------------------------------------------------------------------
local function char()
	local c = player.Character
	local root = c and c:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil, nil
	end
	return c, root
end

-- Carrying lives on the CHARACTER, not the Player, so a respawn clears it by itself.
local function carrying()
	local c = player.Character
	return c ~= nil and c:GetAttribute("CarryingEgg") == true
end

local function onTreadmill()
	local c = player.Character
	return c ~= nil and c:GetAttribute("OnTreadmill") == true
end

-- "Put away or place your held egg before stealing another!": the server won't let you steal
-- with an egg Tool in your hand, and a banked egg can land there. Put it back in the backpack.
local function putAway()
	local c = player.Character
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	if hum and c:FindFirstChildOfClass("Tool") then
		pcall(hum.UnequipTools, hum)
	end
end

local function waitFor(seconds, pred)
	local deadline = os.clock() + seconds
	repeat
		if pred() then
			return true
		end
		task.wait(0.05)
	until os.clock() >= deadline
	return pred()
end

local function money()
	local ls = player:FindFirstChild("leaderstats")
	local m = ls and ls:FindFirstChild("Money")
	return m and tonumber(m.Value) or 0
end

local function short(n)
	n = tonumber(n) or 0
	for _, u in ipairs({ { 1e15, "Qa" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
		if n >= u[1] then
			return ("%.1f%s"):format(n / u[1], u[2])
		end
	end
	return ("%d"):format(n)
end

-- InvokeServer has no timeout. Fire it on its own thread and stop waiting on a clock;
-- the abandoned thread only writes to locals nobody reads.
local function callTimed(remote, seconds, ...)
	local args = table.pack(...)
	local done, result
	task.spawn(function()
		local ok, res = pcall(function()
			return remote:InvokeServer(table.unpack(args, 1, args.n))
		end)
		done, result = ok, res
	end)
	local deadline = os.clock() + seconds
	while done == nil and os.clock() < deadline do
		task.wait()
	end
	if done == nil then
		log(("%s never answered in %ds"):format(remote.Name, seconds))
		return false, nil
	end
	return done, result
end

-- Picklists, normalised: WindUI hands a Multi dropdown's callback a list, a map, or row
-- tables depending on its build.
local function ticked(values)
	local set = {}
	for k, v in pairs(values or {}) do
		if type(v) == "string" then
			set[v] = true
		elseif type(v) == "table" and v.Title then
			set[v.Title] = true
		elseif v == true then
			set[k] = true
		end
	end
	return set
end
assert(ticked({ "Epic" }).Epic, "list form")
assert(ticked({ Epic = true }).Epic, "map form")
assert(not ticked({ Epic = false }).Epic, "unticked map key stays off")

-- One claim on the character: steal, place, train and rebirth all move you, and two of them
-- teleporting at once time each other out. Returns whether it RAN.
local busy = false
local function claim(fn)
	if busy then
		return false
	end
	busy = true
	local ok, err = pcall(fn)
	busy = false
	if not ok then
		warn("[mystegg]", err)
	end
	return true
end

-- Breadcrumb + watchdog: a farm parked in a yield can't report itself.
local mark, markAt = "start", os.clock()
local function step(name)
	mark, markAt = name, os.clock()
end

-- plot -----------------------------------------------------------------------
local function plot()
	return workspace:FindFirstChild("Plot_" .. player.Name)
end

local function eggHatch()
	local p = plot()
	return p and p:FindFirstChild("EggHatch", true)
end

local function homeSpot()
	local p = plot()
	local spawn = p and p:FindFirstChild("Spawn")
	if spawn and spawn:IsA("BasePart") then
		return spawn.Position + Vector3.new(0, 3, 0)
	end
	return p and p:GetPivot().Position or nil
end

local function isEggTool(t)
	if not t:IsA("Tool") then
		return false
	end
	local eggs = ReplicatedStorage:FindFirstChild("Eggs")
	local name = t:GetAttribute("OriginalName") or t.Name
	return (eggs and eggs:FindFirstChild(name) ~= nil) or t:GetAttribute("EggScale") ~= nil
end

local function eggTools()
	local out = {}
	for _, where in ipairs({ player:FindFirstChildOfClass("Backpack"), player.Character }) do
		if where then
			for _, t in ipairs(where:GetChildren()) do
				if isEggTool(t) then
					table.insert(out, t)
				end
			end
		end
	end
	return out
end

local function toolSet()
	local s = {}
	for _, t in ipairs(eggTools()) do
		s[t] = true
	end
	return s
end

-- scoring --------------------------------------------------------------------
local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic" }
local ZONES = { "Zone 1", "Zone 2", "Zone 3", "Zone 4", "Zone 5", "Zone 6", "Zone 7", "Zone 8" }
local RARITY_RANK = {}
for i, r in ipairs(RARITIES) do
	RARITY_RANK[r] = i
end

local function normRarity(r)
	r = tostring(r or "")
	return r == "Mythical" and "Mythic" or r
end

-- The game's own value model: RarityIncome x ZoneMultipliers x Variation x Progression.
-- Zone and rarity both move it by orders of magnitude, so neither alone sorts right.
local function score(zone, rarity, name)
	if Econ and Econ.EggIncomeFloor then
		local ok, s = pcall(Econ.EggIncomeFloor, zone, rarity, tostring(name or ""))
		if ok and type(s) == "number" then
			return s
		end
	end
	return (RARITY_RANK[rarity] or 0) * 10 ^ (tonumber(zone) or 0) -- degraded, still ordered
end

-- An egg Tool is "<Rarity> <Family> Egg" ("Legendary Unicorn Egg"), and Families is in zone
-- order, so the family word IS the zone. ponytail: name parse; a Tool attribute naming the
-- zone would beat it if one turns up.
local FAMILY_ZONE = {}
for i, fam in ipairs(Econ and Econ.Families or {}) do
	FAMILY_ZONE[fam] = i
end
local function parseToolName(name)
	local rarity, family = tostring(name):match("^(%a+)%s+(%a+)%s+Egg$")
	return normRarity(rarity), FAMILY_ZONE[family]
end
do
	local r, z = parseToolName("Legendary Unicorn Egg")
	assert(r == "Legendary", "rarity is the first word")
	assert(z == FAMILY_ZONE.Unicorn, "family maps to its zone")
	assert(parseToolName("Roll Egg - Cat") == "", "non-matching names degrade to no rarity")
end

-- Egg Tools and nest egg models carry the same OriginalName/EggScale, so one score ranks both
-- and a swap compares like with like.
local function itemScore(t)
	local name = t:GetAttribute("OriginalName") or t.Name
	local rarity, zone = parseToolName(name)
	return score(zone or 1, rarity, name) * math.max(1, tonumber(t:GetAttribute("EggScale")) or 1)
end

-- steal ----------------------------------------------------------------------
local wantZones, wantRarities = {}, {}
for i = 1, #ZONES do
	wantZones[i] = true
end
for _, r in ipairs(RARITIES) do
	wantRarities[r] = true
end
local parked = setmetatable({}, { __mode = "k" })
local refusals = setmetatable({}, { __mode = "k" })
local misses = setmetatable({}, { __mode = "k" })

local function eggZone(egg)
	return tonumber(egg:GetAttribute("DungeonZone") or egg:GetAttribute("Zone"))
end

local function best()
	local root = workspace:FindFirstChild("Eggs")
	if not root then
		return nil
	end
	local now = os.clock()
	local pick, pickScore, pickKg
	for _, zoneFolder in ipairs(root:GetChildren()) do
		for _, spawn in ipairs(zoneFolder:GetChildren()) do
			local egg = spawn:FindFirstChild("SpawnedEgg")
			if egg and egg:IsA("Model") and not (parked[egg] and now < parked[egg]) then
				local zone = eggZone(egg)
				local rarity = normRarity(egg:GetAttribute("Rarity") or egg:GetAttribute("EggRarity"))
				if zone and wantZones[zone] and wantRarities[rarity] then
					local s = score(zone, rarity, egg:GetAttribute("DisplayName"))
					local kg = tonumber(egg:GetAttribute("WeightKG")) or 0
					if not pickScore or s > pickScore or (s == pickScore and kg > pickKg) then
						pick, pickScore, pickKg = egg, s, kg
					end
				end
			end
		end
	end
	return pick, pickScore
end

local function labelOf(egg)
	return ("%s (Z%s, %skg)"):format(
		tostring(egg:GetAttribute("DisplayName") or egg.Name),
		tostring(eggZone(egg)),
		short(egg:GetAttribute("WeightKG"))
	)
end

-- travel ---------------------------------------------------------------------
local hopRetired, reverts = false, 0

local function leaveTreadmill()
	if onTreadmill() then
		pcall(function()
			Events.LeaveTreadmill:FireServer()
		end)
		waitFor(1.5, function()
			return not onTreadmill()
		end)
	end
end

-- "ok" | "reverted" | "nochar". A respawn is not a revert: counting it would retire the fast
-- path over nothing.
local function hop(pos)
	local _c, root = char()
	if not root then
		return "nochar"
	end
	root.AssemblyLinearVelocity = Vector3.zero
	root.CFrame = CFrame.new(pos)
	task.wait(SNAP_CHECK)
	local t0 = os.clock()
	while player.GameplayPaused and os.clock() - t0 < 3 do
		task.wait(0.1)
	end
	_c, root = char()
	if not root then
		return "nochar"
	end
	return (root.Position - pos).Magnitude > SNAP_TOLERANCE and "reverted" or "ok"
end

-- ponytail: straight-line chunks with no pathing, only reached if the server starts
-- refusing long hops. It never has so far.
local function chunked(pos)
	for _ = 1, 200 do
		local _c, root = char()
		if not root then
			return false
		end
		local delta = pos - root.Position
		if delta.Magnitude < SNAP_TOLERANCE then
			return true
		end
		root.AssemblyLinearVelocity = Vector3.zero
		root.CFrame = CFrame.new(root.Position + delta.Unit * math.min(CHUNK, delta.Magnitude))
		task.wait(CHUNK_GAP)
	end
	return false
end

local function travel(pos)
	leaveTreadmill()
	if not hopRetired then
		local verdict = hop(pos)
		if verdict == "ok" then
			reverts = 0
			return true
		elseif verdict == "nochar" then
			return false
		end
		reverts += 1
		warn(("[mystegg] teleport was undone (%d/%d)"):format(reverts, REVERT_STRIKES))
		if reverts < REVERT_STRIKES then
			return false
		end
		hopRetired = true
		warn("[mystegg] the server is refusing long hops -- moving in chunks from here on")
	end
	return chunked(pos)
end

-- grab -----------------------------------------------------------------------
local vim = game:GetService("VirtualInputManager")
local METHODS = {
	{ "fireproximityprompt", function(prompt)
		fireproximityprompt(prompt, prompt.HoldDuration)
	end },
	{ "InputHold", function(prompt)
		task.spawn(function()
			pcall(function()
				prompt:InputHoldBegin()
			end)
			task.wait(prompt.HoldDuration + 0.1)
			pcall(function()
				prompt:InputHoldEnd() -- on every exit: a leaked begin poisons later grabs
			end)
		end)
	end },
	{ "key press", function(prompt)
		task.spawn(function()
			vim:SendKeyEvent(true, prompt.KeyboardKeyCode, false, game)
			task.wait(prompt.HoldDuration + 0.1)
			vim:SendKeyEvent(false, prompt.KeyboardKeyCode, false, game)
		end)
	end },
}
local method = type(fireproximityprompt) == "function" and 1 or 2 -- probe winner first

local function findPrompt(egg, seconds)
	local deadline = os.clock() + seconds
	repeat
		local p = egg:FindFirstChildWhichIsA("ProximityPrompt", true)
		if p then
			return p
		end
		task.wait(0.1)
	until os.clock() >= deadline or not egg.Parent
	return nil
end

-- "ok" | "refused" | "nostream" | "gone". Someone else taking it is a lost race, not a
-- refusal, and must not count against the egg.
local function grab(egg, alive)
	step("grab " .. labelOf(egg) .. " / prompt")
	local prompt = findPrompt(egg, ARRIVE)
	if not prompt then
		return egg.Parent and "nostream" or "gone"
	end
	pcall(function()
		prompt.Enabled = true
		prompt.RequiresLineOfSight = false
		prompt.MaxActivationDistance = OPEN_DIST
	end)
	local _c, root = char()
	if not root then
		return "nostream"
	end
	-- Pinned to the landing spot read once: the carried egg rides above you, so chasing its
	-- live pivot would walk you upwards.
	local pin = root.CFrame
	step("grab " .. labelOf(egg) .. " / press")
	local deadline, lastPress = os.clock() + GRAB_TIMEOUT, 0
	while os.clock() < deadline and alive() do
		if carrying() then
			return "ok"
		end
		if not egg.Parent then
			return waitFor(0.4, carrying) and "ok" or "gone"
		end
		if os.clock() - lastPress >= PRESS_GAP then
			lastPress = os.clock()
			putAway() -- every press: something may have equipped an egg since the last one
			pcall(METHODS[method][2], prompt)
		end
		_c, root = char()
		if root then
			root.CFrame = pin -- hold through a boss knockback
		end
		task.wait()
	end
	return carrying() and "ok" or "refused"
end

-- nest -----------------------------------------------------------------------
local nestCap = nil -- learnt from the server's own "(10/10 eggs)"; nil until it first says so
local nestFullUntil = 0 -- fallback gate while nestCap is unknown
local placeParkedUntil = 0
local fullSignal = 0 -- bumped by the listener on every "nest is full"
local placeFromHome = false -- flips on if a place only ever lands once you're standing home
local stats = { stolen = 0, placed = 0, hatched = 0, rolls = 0, lost = 0, swapped = 0 }

local function nestEggs()
	local out = {}
	local hatch = eggHatch()
	for _, m in ipairs(hatch and hatch:GetChildren() or {}) do
		if m:IsA("Model") and m:GetAttribute("IsEgg") == true then
			table.insert(out, m)
		end
	end
	return out
end

-- Counting against the server's own number beats a timer: a hatch frees a slot the moment the
-- egg turns into a pet, not whenever a retry clock runs out.
local function nestHasRoom()
	if os.clock() < placeParkedUntil then
		return false
	end
	if nestCap then
		return #nestEggs() < nestCap
	end
	return os.clock() >= nestFullUntil
end

local function bestTools()
	local tools = eggTools()
	table.sort(tools, function(a, b)
		return itemScore(a) > itemScore(b)
	end)
	return tools
end

-- The server acts on what you HOLD: equip, then PlaceHeldItem with no arguments, the same call
-- the game's own action button makes. "placed" (the Tool left you) | "full" (the server said
-- so) | "nothing" (neither, which is the one worth worrying about).
local function place(tool)
	local c = player.Character
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	if not hum or not tool.Parent then
		return "nothing"
	end
	pcall(hum.EquipTool, hum, tool)
	waitFor(0.5, function()
		return tool.Parent == c
	end)
	local signal = fullSignal
	pcall(function()
		Events.PlaceHeldItem:FireServer()
	end)
	local backpack = player:FindFirstChildOfClass("Backpack")
	local function gone()
		return tool.Parent ~= c and tool.Parent ~= backpack
	end
	waitFor(PLACE_WAIT, function()
		return fullSignal ~= signal or gone()
	end)
	if gone() then
		stats.placed += 1
		return "placed"
	end
	putAway() -- never leave an egg in hand: it blocks the next steal
	return fullSignal ~= signal and "full" or "nothing"
end

-- One egg, the richest in the backpack. Where you stand first: the probe's place reached the
-- server from Spawn, 43 studs off the nest. Home only if that does nothing, and then remembered.
-- The caller holds the claim.
local function placeBest(alive)
	local tool = bestTools()[1]
	if not tool then
		return false
	end
	step("place " .. tool.Name)
	local function goHome()
		local spot = homeSpot()
		local _c, root = char()
		if spot and root and (root.Position - spot).Magnitude > 60 then
			travel(spot)
		end
	end
	if placeFromHome then
		goHome()
	end
	local r = place(tool)
	if r == "nothing" and not placeFromHome and alive() then
		goHome()
		r = place(tool)
		if r ~= "nothing" then
			placeFromHome = true
			log("placing only lands from home -- going home to place from now on")
		end
	end
	if r == "nothing" then
		placeParkedUntil = os.clock() + PLACE_FAIL_PARK
		warn(("[mystegg] PlaceHeldItem did nothing, even at home -- placing parked %ds"):format(PLACE_FAIL_PARK))
	end
	return r == "placed"
end

-- Nest eggs that may be traded out: not hatching and not ready (a ready egg should hatch, not
-- move). ponytail: whether a picked-up egg keeps its incubation isn't probed. The game ships
-- PersistentHatchTimers=true, which suggests it does. That's why Swap starts off.
local function weakestNestEgg()
	local weak, weakScore
	for _, m in ipairs(nestEggs()) do
		local dur = tonumber(m:GetAttribute("HatchDuration")) or math.huge
		local prog = tonumber(m:GetAttribute("HatchProgress")) or 0
		if not m:GetAttribute("HatchingStarted") and m:GetAttribute("HatchReady") ~= true and prog < dur then
			local s = itemScore(m)
			if not weakScore or s < weakScore then
				weak, weakScore = m, s
			end
		end
	end
	return weak, weakScore
end

-- Frees a slot only. The next Auto Place pass fills it with the best egg, the picked-up one
-- included, so a swap can never put back something worse.
local function swapOut(tool)
	local weak, weakScore = weakestNestEgg()
	if not weak or itemScore(tool) < weakScore * SWAP_RATIO then
		return false
	end
	local hatch = weak.Parent
	pcall(function()
		Events.RequestPickUpEgg:FireServer(weak)
	end)
	if not waitFor(PLACE_WAIT, function()
		return weak.Parent ~= hatch
	end) then
		return false
	end
	stats.swapped += 1
	nestFullUntil = 0
	log(("swapped out %s for %s"):format(tostring(weak:GetAttribute("OriginalName") or weak.Name), tool.Name))
	return true
end

-- farm -----------------------------------------------------------------------
-- Returns the new egg Tool, or false.
local function bank(alive)
	local spot = homeSpot()
	if not spot then
		warn("[mystegg] no Plot_" .. player.Name .. " -- can't bank")
		return false
	end
	local before = toolSet()
	step("bank / hop home")
	travel(spot)
	local cleared = waitFor(BANK_TIMEOUT, function()
		return not carrying()
	end)
	if not cleared and alive() then
		local hatch = eggHatch()
		if hatch and hatch:IsA("BasePart") then
			step("bank / EggHatch pad")
			travel(hatch.Position + Vector3.new(0, hatch.Size.Y / 2 + 3, 0))
			cleared = waitFor(BANK_TIMEOUT, function()
				return not carrying()
			end)
		end
	end
	if not cleared then
		return false
	end
	step("bank / wait for tool")
	local tool
	waitFor(TOOL_WAIT, function()
		for _, t in ipairs(eggTools()) do
			if not before[t] then
				tool = t
				return true
			end
		end
		return false
	end)
	if not tool then
		stats.lost += 1 -- carry cleared with nothing to show: a respawn or a catch
		return false
	end
	stats.stolen += 1
	return tool
end

-- Steal only: best egg, grab, home, done. Placing is Auto Place's job.
local function cycle(alive)
	if carrying() then
		return bank(alive) and "banked" or "moved" -- toggled on mid-carry, or a failed bank
	end

	local egg, s = best()
	if not egg then
		say("farm", "nothing matching your filters -- waiting for a spawn")
		return "idle"
	end
	local label = labelOf(egg)
	say("farm", ("-> %s  score %s"):format(label, short(s)))
	step("travel to " .. label)
	if not travel(egg:GetPivot().Position + Vector3.new(0, LIFT, 0)) then
		return "moved"
	end
	if not alive() then
		return "moved"
	end

	local result = grab(egg, alive)
	if result == "nostream" then
		misses[egg] = (misses[egg] or 0) + 1
		if misses[egg] >= MISS_STRIKES then
			parked[egg], misses[egg] = os.clock() + PARK_SECONDS, nil
			log("parked " .. label .. " -- never streamed in")
		end
		return "moved"
	elseif result == "refused" then
		misses[egg] = nil
		refusals[egg] = (refusals[egg] or 0) + 1
		if refusals[egg] >= REFUSE_STRIKES then
			parked[egg], refusals[egg] = os.clock() + PARK_SECONDS, nil
			log(("parked %s -- refused with %s"):format(label, METHODS[method][1]))
			method = method % #METHODS + 1 -- which press wins isn't stable between runs
			log("switching press to " .. METHODS[method][1])
		end
		return "moved"
	elseif result == "gone" then
		return "moved"
	end

	misses[egg], refusals[egg] = nil, nil
	local tool = bank(alive)
	if not tool then
		warn("[mystegg] stole " .. label .. " but it never banked -- check F9 for the game's reason")
		return "moved"
	end
	log("banked " .. label)
	say("farm", "banked " .. label)
	return "banked"
end

-- loops ----------------------------------------------------------------------
-- One shape for every toggle: a per-row generation counter, so off-then-on inside a sleep
-- can't leave the old thread alive, and only the current generation may exit a loop.
-- body(alive) returns the seconds until its next pass.
local rows = {}
local function loop(name, body, onStart)
	local row = { on = false, gen = 0 }
	function row.set(on)
		row.on = on
		row.gen += 1
		local mine = row.gen
		if not on then
			return
		end
		if onStart then
			onStart()
		end
		task.spawn(function()
			local function alive()
				return running and row.on and row.gen == mine
			end
			while alive() do
				local ok, wait = pcall(body, alive)
				if not ok then
					warn(("[mystegg] %s threw: %s"):format(name, tostring(wait)))
					wait = 2
				end
				local untilT = os.clock() + (tonumber(wait) or 1)
				while alive() and os.clock() < untilT do
					task.wait(0.1)
				end
			end
		end)
	end
	rows[name] = row
	return row
end

local farmIdle = true
local wake = false
local placer -- forward: the farm yields a beat to it after every bank

local farm = loop("farm", function(alive)
	local result = "moved"
	if not claim(function()
		result = cycle(alive)
	end) then
		return 0.2
	end
	farmIdle = result == "idle"
	if farmIdle then
		step("idle")
		wake = false
		local t0 = os.clock()
		while alive() and not wake and os.clock() - t0 < IDLE_BEAT do
			task.wait(0.2)
		end
		return 0
	end
	if result == "banked" then
		-- You're standing at home right now, which is where a place is cheapest. Leave the
		-- claim free for one Auto Place beat before hopping out again.
		return placer and placer.on and nestHasRoom() and PLACE_POLL * 2 or 0
	end
	return 0.3
end, function()
	farmIdle = false
end)

local swapOn = false
placer = loop("place", function(alive)
	if carrying() then
		return PLACE_POLL
	end
	local top = bestTools()[1]
	if not top then
		return PLACE_POLL
	end
	if not nestHasRoom() then
		if swapOn and os.clock() >= placeParkedUntil then
			swapOut(top) -- doesn't move you, so no claim
		end
		return 1
	end
	local placed = false
	claim(function()
		placed = placeBest(alive)
	end)
	return placed and 0.1 or PLACE_POLL
end)

local hatchAsked = setmetatable({}, { __mode = "k" })
local hatcher = loop("hatch", function()
	local hatch = eggHatch()
	if not hatch then
		return 3
	end
	for _, m in ipairs(hatch:GetChildren()) do
		if m:IsA("Model") and m:GetAttribute("IsEgg") == true and not m:GetAttribute("HatchingStarted") then
			local dur = tonumber(m:GetAttribute("HatchDuration")) or math.huge
			local prog = tonumber(m:GetAttribute("HatchProgress")) or 0
			local ready = m:GetAttribute("HatchReady") == true or prog >= dur
			if ready and os.clock() >= (hatchAsked[m] or 0) then
				hatchAsked[m] = os.clock() + HATCH_RETRY
				pcall(function()
					Events.RequestHatch:FireServer(m)
				end)
				task.wait(0.2)
			end
		end
	end
	return HATCH_POLL
end)

-- Stands you on the treadmill whenever nothing else needs the character.
local function touchTreadmill()
	local p = plot()
	local model = p and p:FindFirstChild("TreadmillModel")
	local touch = model and model:FindFirstChild("Touch")
	local _c, root = char()
	if not (touch and root and firetouchinterest) then
		return false
	end
	firetouchinterest(root, touch, 0)
	task.wait(0.2)
	firetouchinterest(root, touch, 1)
	return waitFor(1.5, onTreadmill)
end

local trainer = loop("train", function()
	if (farm.on and not farmIdle) or onTreadmill() or carrying() then
		return TRAIN_BEAT
	end
	claim(function()
		if not touchTreadmill() then
			say("tread", "couldn't get on the treadmill (no Touch part, or no firetouchinterest)")
		end
	end)
	return TRAIN_BEAT
end)

-- The game's own TreadmillRollClient rolls by itself for as long as you're on the treadmill,
-- on its reel cadence, and the server keeps ONE cooldown per player. So a second roller races
-- it, and whichever call lands second gets RollTooSoon however long its own gap is. While Auto
-- Roll is on, the game's calls get a refusal answered locally (its client shows the idle egg
-- and retries in 1s) and only ours reach the server.
-- A __namecall hook can't be removed, so it's installed once per session and reads a
-- getgenv table, which re-pastes flip rather than stacking a second hook.
local rollHook = getgenv().ZegionMystEggRoll
if not rollHook then
	rollHook = { block = false, mine = false, refused = { Success = false, Reason = "ZegionOwnsRolls" } }
	getgenv().ZegionMystEggRoll = rollHook
end
rollHook.remote = Events:FindFirstChild("RollTreadmillCreature")
if not rollHook.hooked and hookmetamethod and getnamecallmethod and rollHook.remote then
	local wrap = newcclosure or function(f)
		return f
	end
	local old
	old = hookmetamethod(
		game,
		"__namecall",
		wrap(function(self, ...)
			-- Table reads, writes and comparisons only. A method call in here would overwrite
			-- getnamecallmethod() for the call still in flight.
			if rollHook.block and self == rollHook.remote and getnamecallmethod() == "InvokeServer" then
				if not rollHook.mine then
					return rollHook.refused
				end
				rollHook.mine = false
			end
			return old(self, ...)
		end)
	)
	rollHook.hooked = true
end
if not rollHook.hooked then
	warn("[mystegg] no hookmetamethod -- the game's own roller keeps running, expect RollTooSoon")
end

-- Ours marks itself right before the call. Nothing yields between the mark and the namecall,
-- so the game's thread can't slip in and borrow it.
local function rollOnce()
	local done, result
	task.spawn(function()
		local ok, res = pcall(function()
			rollHook.mine = true
			return rollHook.remote:InvokeServer()
		end)
		rollHook.mine = false
		done, result = ok, res
	end)
	local deadline = os.clock() + INVOKE_TIMEOUT
	while done == nil and os.clock() < deadline do
		task.wait()
	end
	return done == true, result
end

-- Recorded: the game's own rolls held 2.0s apart and were refused at 1.9-2.0s. So start just
-- above, creep down on success, and step up a little on each refusal rather than multiplying
-- away from the answer.
local rollGap, rollFloor, lastReason, lastEquip = ROLL_GAP_START, ROLL_GAP_MIN, nil, 0
local roller = loop("roll", function()
	if not onTreadmill() then
		say("tread", ("rolls %d -- waiting until you're on the treadmill"):format(stats.rolls))
		return 1
	end
	if not rollHook.remote then
		return 10
	end
	local ok, r = rollOnce()
	if ok and type(r) == "table" and r.Success then
		stats.rolls += 1
		rollGap = math.max(rollFloor, rollGap * ROLL_DESCENT)
		if not r.AwardedEgg and os.clock() - lastEquip > EQUIP_EVERY then
			lastEquip = os.clock()
			pcall(function()
				Events.EquipBestPets:FireServer()
			end)
		end
		say("tread", ("rolls %d  last: %s %s  gap %.2fs"):format(stats.rolls, tostring(r.Rarity), tostring(r.Name), rollGap))
		return rollGap
	end
	local reason = type(r) == "table" and tostring(r.Reason or r.Message) or "no answer"
	if reason ~= lastReason then
		lastReason = reason
		log("roll refused: " .. reason)
	end
	if reason == "PetLimitReached" then
		say("tread", "pet limit reached -- sell or place pets to keep rolling")
		return 15
	end
	rollFloor = math.min(ROLL_GAP_MAX, rollGap + ROLL_STEP_UP)
	rollGap = rollFloor
	say("tread", ("rolls %d  refused (%s)  gap %.2fs"):format(stats.rolls, reason, rollGap))
	return rollGap
end, function()
	rollGap, rollFloor, lastReason = ROLL_GAP_START, ROLL_GAP_MIN, nil
end)

-- The game plays its hatch reveal, then fires EggHatchAnimComplete(uuid), and the server
-- waits on that call. Its handler is muted and answered at once. Ours connects AFTER the
-- muting, or getconnections would hand back our own listener too.
local severed, hatchAnswer = {}, nil
local function setSkipAnim(on)
	if hatchAnswer then
		hatchAnswer:Disconnect()
		hatchAnswer = nil
	end
	for _, c in ipairs(severed) do
		pcall(function()
			c:Enable()
		end)
	end
	table.clear(severed)
	if not on then
		return
	end
	if not (Events:FindFirstChild("EggHatchAnim") and Events:FindFirstChild("EggHatchAnimComplete")) then
		warn("[mystegg] EggHatchAnim / EggHatchAnimComplete moved -- hatch animations stay")
		return
	end
	if not getconnections then
		say("nest", "no getconnections -- hatch animations stay")
		return
	end
	local ok, list = pcall(getconnections, Events.EggHatchAnim.OnClientEvent)
	for _, c in ipairs(ok and list or {}) do
		if pcall(function()
			c:Disable()
		end) then
			table.insert(severed, c)
		end
	end
	if #severed == 0 then
		return -- nothing muted: the game's own handler still answers, don't double it
	end
	hatchAnswer = Events.EggHatchAnim.OnClientEvent:Connect(function(_egg, _cf, _animal, _rarity, uuid)
		pcall(function()
			Events.EggHatchAnimComplete:FireServer(uuid)
		end)
	end)
end

-- upgrades -------------------------------------------------------------------
local dungeonState = nil -- the server's own {Income, Offline, ...} mirror, pushed on "State"

local function buyDungeon(kind)
	if not PlotUpgradeCfg then
		return 30
	end
	local level = dungeonState and tonumber(dungeonState[kind]) or tonumber(player:GetAttribute("Dungeon" .. kind .. "Level")) or 0
	local price = PlotUpgradeCfg.Price(kind, level)
	if not price then
		say("upg", kind .. " income is maxed")
		return 30
	end
	if money() < price then
		return UPGRADE_BEAT
	end
	pcall(function()
		Events.DungeonPlotUpgrade:FireServer("Buy", kind, level, "One")
	end)
	say("upg", ("bought %s level %d for $%s"):format(kind, level + 1, short(price)))
	return UPGRADE_BEAT
end

local function buyRoller(kind)
	if not RollerCfg then
		return 30
	end
	local level = RollerCfg.Level(player:GetAttribute("Roller" .. kind .. "Level"))
	local price = RollerCfg.Price(kind, level + 1)
	if not price then
		say("upg", "roller " .. kind .. " is maxed")
		return 30
	end
	if money() < price then
		return UPGRADE_BEAT
	end
	local _ok, r = callTimed(Events.RequestRollerUpgrade, INVOKE_TIMEOUT, kind, "One") -- "One" is the cash path
	if type(r) == "table" and r.Message then
		say("upg", "roller " .. kind .. ": " .. tostring(r.Message))
	end
	return UPGRADE_BEAT
end

local function buySlot()
	if not PlotCfg then
		return 30
	end
	local _ok, cap = callTimed(Events.GetPlotCapacity, INVOKE_TIMEOUT)
	cap = tonumber(cap)
	if not cap then
		return 10
	end
	if cap >= (PlotCfg.MaxSlots or 14) then
		say("upg", "pet slots are maxed")
		return 60
	end
	local price = PlotCfg.GetUpgradePrice(cap + 1)
	if not price or money() < price then
		return UPGRADE_BEAT
	end
	local _ok2, r = callTimed(Events.RequestPlotUpgrade, INVOKE_TIMEOUT)
	say("upg", ("pet slot %d: %s"):format(cap + 1, type(r) == "table" and (r.Success and "bought" or tostring(r.Message)) or "no answer"))
	return UPGRADE_BEAT
end

-- ponytail: the least-tested row. Rebirth goes through the Super Spin, which the game
-- only offers at the station, so it snaps there, spins, answers the ReturnToken the reveal
-- would have sent, and hands back. Watch F9 the first time.
local function rebirth(alive)
	local _ok, q = callTimed(Events.DungeonRebirthQuote, INVOKE_TIMEOUT)
	if type(q) ~= "table" or not q.Ready then
		return 15
	end
	if not (q.CanAfford or q.Pending) then
		say("upg", ("rebirth: keys %s / %s"):format(short(q.Keys), short(q.Price)))
		return 30
	end
	local station = workspace:FindFirstChild("SuperSpinStation")
	local button = station and station:FindFirstChild("RollButton", true)
	if not button then
		warn("[mystegg] no SuperSpinStation.RollButton -- can't rebirth")
		return 60
	end
	claim(function()
		if not alive() then
			return
		end
		step("rebirth / super spin")
		travel(button.Position + Vector3.new(0, 4, 0))
		task.wait(0.35)
		local _ok2, r = callTimed(Events.SuperSpinRequest, 20, true)
		log("super spin answered:", type(r) == "table" and (tostring(r.Success) .. " " .. tostring(r.Message)) or tostring(r))
		if type(r) == "table" and r.ReturnToken then
			pcall(function()
				Events.DungeonSuperSpinReturn:FireServer(r.ReturnToken)
			end)
		end
		say("upg", type(r) == "table" and r.Success and "rebirthed!" or "rebirth refused -- see F9")
	end)
	return 30
end

local UPGRADES = {
	{ title = "Plot income", desc = "+5% income per level, cash", seed = true, run = function()
		return buyDungeon("Income")
	end },
	{ title = "Offline income", desc = "cash", seed = true, run = function()
		return buyDungeon("Offline")
	end },
	{ title = "Roller luck", desc = "better roll odds, cash", run = function()
		return buyRoller("Luck")
	end },
	{ title = "Roller size", desc = "bigger roll eggs, cash", run = function()
		return buyRoller("Size")
	end },
	{ title = "Pet slots", desc = "more pets on the plot, cash", run = buySlot },
	{ title = "Dungeon rebirth", desc = "RESETS progress for the rebirth reward once keys reach the target", run = rebirth },
}

-- listeners ------------------------------------------------------------------
local conns = {}
local function on(signal, fn)
	table.insert(conns, signal:Connect(fn))
end

-- The server words its reasons here and nowhere else.
if Events:FindFirstChild("ShowNotification") then
	on(Events.ShowNotification.OnClientEvent, function(msg)
		msg = tostring(msg)
		if msg:find("nest is full") then
			fullSignal += 1
			nestFullUntil = os.clock() + NEST_RETRY
			local cap = tonumber(msg:match("%(%d+/(%d+) eggs%)")) -- "(10/10 eggs)"
			if cap then
				nestCap = cap
			end
		elseif msg:find("Put away or place your held egg") then
			putAway() -- the steal was refused for the egg in your hand; the next press retries
		elseif msg:find("^Hatched") then
			stats.hatched += 1
			nestFullUntil = 0 -- a hatch is the only thing that frees a slot
			placeParkedUntil = 0
			wake = true
		end
	end)
end
if Events:FindFirstChild("DungeonPlotUpgrade") then
	on(Events.DungeonPlotUpgrade.OnClientEvent, function(kind, state)
		if kind == "State" and type(state) == "table" then
			dungeonState = state
		end
	end)
end
if Events:FindFirstChild("EggSpawnAlert") then
	on(Events.EggSpawnAlert.OnClientEvent, function()
		wake = true
	end)
end
local eggsRoot = workspace:FindFirstChild("Eggs")
if eggsRoot then
	on(eggsRoot.DescendantAdded, function(d)
		if d.Name == "SpawnedEgg" then
			wake = true
		end
	end)
end

local collectCash = false
if Events:FindFirstChild("OfflineCashPile") and Events:FindFirstChild("OfflineCashCollect") then
	on(Events.OfflineCashPile.OnClientEvent, function()
		if collectCash then
			pcall(function()
				Events.OfflineCashCollect:FireServer("collect")
			end)
		end
	end)
end

-- Anti-AFK: Idled is the last warning before the kick; the 60s nudge keeps it from coming.
local hasVU, vu = pcall(game.GetService, game, "VirtualUser")
local function nudge()
	if not hasVU or not running then
		return
	end
	local cf = workspace.CurrentCamera and workspace.CurrentCamera.CFrame or CFrame.new()
	pcall(function()
		vu:CaptureController()
		vu:Button2Down(Vector2.new(0, 0), cf)
		task.wait(0.05)
		vu:Button2Up(Vector2.new(0, 0), cf)
	end)
end
on(player.Idled, nudge)
task.spawn(function()
	while running do
		task.wait(60)
		nudge()
	end
end)

-- Watchdog, on its own thread because a parked farm thread can't report anything.
task.spawn(function()
	local warnedMark = nil
	while running do
		task.wait(5)
		if farm.on and mark ~= "idle" and os.clock() - markAt > STUCK_AFTER and warnedMark ~= markAt then
			warnedMark = markAt
			warn(("[mystegg] stuck %ds at: %s"):format(os.clock() - markAt, mark))
		end
	end
end)

-- gui ------------------------------------------------------------------------
-- Fetched here rather than installed by the loader, so this file still pastes and runs alone.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window = panel({
	game = "Steal a Mysterious Egg", -- fallback until the live name lands
	folder = "StealMysteriousEgg", -- never rename: saved configs orphan
	size = UDim2.fromOffset(500, 420),
})
if not Window then
	running = false
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	return -- panel.lua already said why
end

local MainTab = Window:Tab({ Title = "Heist", Icon = "solar:egg-bold" })
local Farm = MainTab:Section({ Title = "Steal", Icon = "solar:running-bold", Box = true, BoxBorder = true, Opened = true })

Farm:Toggle({
	Title = "Auto Steal",
	Desc = "Teleport to the best egg, grab it, back to base. Placing is Auto Place",
	Value = false,
	Callback = function(state)
		farm.set(state) -- re-entrant: Set() and a double click both land here
		if not state then
			say("farm", "stopped")
		end
	end,
})

local zoneValues = {}
for _, z in ipairs(ZONES) do
	table.insert(zoneValues, z)
end
Farm:Dropdown({
	Title = "Zones",
	Values = zoneValues,
	Value = zoneValues,
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		local set = ticked(values)
		table.clear(wantZones) -- cleared, not replaced: the loop reads this table live
		for i, z in ipairs(ZONES) do
			wantZones[i] = set[z] or nil
		end
	end,
})

Farm:Dropdown({
	Title = "Rarities",
	Desc = "Richest of the ticked ones wins -- zone counts as much as rarity",
	Values = RARITIES,
	Value = RARITIES,
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		local set = ticked(values)
		table.clear(wantRarities)
		for _, r in ipairs(RARITIES) do
			wantRarities[r] = set[r] or nil
		end
	end,
})

local farmLine = Farm:Paragraph({ Title = "Status", Desc = "idle" })
local statLine = Farm:Paragraph({ Title = "Session", Desc = "-" })

local Nest = MainTab:Section({ Title = "Nest", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })
Nest:Toggle({
	Title = "Auto Place",
	Desc = "Richest backpack egg into the nest whenever there's room",
	Value = true,
	Callback = placer.set,
})
Nest:Toggle({
	Title = "Swap weaker nest eggs",
	Desc = ("Pick up the weakest unstarted nest egg when a backpack egg is worth %dx more"):format(SWAP_RATIO),
	Value = false,
	Callback = function(state)
		swapOn = state
	end,
})
Nest:Button({
	Title = "Place best eggs now",
	Desc = "Best first, until the nest is full",
	Callback = function()
		task.spawn(function()
			local n = 0
			local ran = claim(function()
				placeParkedUntil, nestFullUntil = 0, 0 -- a manual press retries whatever was parked
				while running and not carrying() and nestHasRoom() and placeBest(function()
					return running
				end) do
					n += 1
				end
			end)
			if not ran then
				say("nest", "busy stealing -- Auto Place will get to it")
			elseif n == 0 then
				say("nest", #eggTools() == 0 and "no eggs in your backpack" or "nest is full")
			else
				say("nest", ("placed %d egg(s)"):format(n))
			end
		end)
	end,
})
Nest:Toggle({
	Title = "Auto Hatch",
	Desc = "Hatch every ready nest egg, from anywhere",
	Value = true,
	Callback = hatcher.set,
})
Nest:Toggle({
	Title = "Skip hatch animation",
	Desc = "Mutes the reveal and tells the server it finished",
	Value = true,
	Callback = setSkipAnim,
})
Nest:Toggle({
	Title = "Collect offline cash",
	Value = true,
	Callback = function(state)
		collectCash = state
		if state then
			pcall(function()
				Events.OfflineCashCollect:FireServer("query") -- re-sends a pile we joined before
			end)
		end
	end,
})
local nestLine = Nest:Paragraph({ Title = "Nest", Desc = "-" })

local TreadTab = Window:Tab({ Title = "Treadmill", Icon = "solar:bolt-circle-bold" })
local Tread = TreadTab:Section({ Title = "Train & roll", Icon = "solar:bolt-bold", Box = true, BoxBorder = true, Opened = true })
Tread:Toggle({
	Title = "Auto Train",
	Desc = "Stand on your treadmill whenever the heist has nothing to take",
	Value = false,
	Callback = trainer.set,
})
Tread:Toggle({
	Title = "Auto Roll",
	Desc = "Rolls straight to the server, no reel. Only while on the treadmill",
	Value = false,
	Callback = function(state)
		rollHook.block = state -- off hands rolling back to the game's own client
		roller.set(state)
	end,
})
local treadLine = Tread:Paragraph({ Title = "Rolls", Desc = "-" })

local UpgTab = Window:Tab({ Title = "Upgrades", Icon = "solar:graph-up-bold" })
local Upg = UpgTab:Section({ Title = "Spend (all off by default)", Icon = "solar:wallet-bold", Box = true, BoxBorder = true, Opened = true })
for i, u in ipairs(UPGRADES) do
	local row = loop("upgrade" .. i, u.run, u.seed and function()
		pcall(function()
			Events.DungeonPlotUpgrade:FireServer("Refresh") -- seed the level mirror
		end)
	end or nil)
	Upg:Toggle({ Title = u.title, Desc = u.desc, Value = false, Callback = row.set })
end
local upgLine = Upg:Paragraph({ Title = "Last", Desc = "-" })

-- A starting Value = true fires no callback, so the default-on rows are armed by hand.
hatcher.set(true)
placer.set(true)
setSkipAnim(true)
collectCash = true
pcall(function()
	Events.OfflineCashCollect:FireServer("query")
end)

-- "nest" messages go to the Status row: the Nest row is rewritten every second by the drain.
local lines = { farm = farmLine, nest = farmLine, tread = treadLine, upg = upgLine }
local lastStats = 0
local drain = RunService.Heartbeat:Connect(function()
	for key, msg in pairs(pending) do
		pending[key] = nil
		if not pcall(function()
			lines[key]:SetDesc(msg)
		end) then
			print("[mystegg]", msg)
		end
	end
	if os.clock() - lastStats > 1 then
		lastStats = os.clock()
		pcall(function()
			statLine:SetDesc(("stolen %d  placed %d  swapped %d  hatched %d  lost %d"):format(
				stats.stolen,
				stats.placed,
				stats.swapped,
				stats.hatched,
				stats.lost
			))
			local held = #eggTools()
			if os.clock() < placeParkedUntil then
				nestLine:SetDesc(("placing parked %ds -- see F9  |  backpack eggs %d"):format(placeParkedUntil - os.clock(), held))
			else
				nestLine:SetDesc(("nest %d/%s %s  |  backpack eggs %d"):format(
					#nestEggs(),
					nestCap and tostring(nestCap) or "?",
					nestHasRoom() and "(room)" or "(full)",
					held
				))
			end
		end)
	end
end)

-- close ----------------------------------------------------------------------
local function stopAll()
	running = false
	for _, row in pairs(rows) do
		row.set(false)
	end
	setSkipAnim(false) -- the game's own reveal comes back for manual hatches
	rollHook.block = false -- and its own roller gets the server back
	collectCash = false
	for _, c in ipairs(conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(conns)
	if drain then
		drain:Disconnect()
		drain = nil
	end
end

Window:OnDestroy(function()
	stopAll()
	getgenv().stealMysteriousEggStop = nil
end)

getgenv().stealMysteriousEggStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().stealMysteriousEggStop = nil
end

log("loaded")
