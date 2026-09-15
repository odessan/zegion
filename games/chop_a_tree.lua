--[[ Chop a Tree -- trees, treasure, sell (110730550789828)

     FARM : sends the game's own "tree killed" remote on your swing beat, loots every
            treasure the server drops back, and deposits the moment the carry is full.
            You don't move and no tree on the map changes.

            Chopping is simulated on your client: HP, swings and reach all live in
            TreeChopSystem, and the server only ever hears ChopTreeHit({zone, ...}, seq),
            one zone index per tree that died. Probed: a spaced fake kill pays wood and
            rolls a drop, ten in one frame pay once. LootTreasure takes a dropId and no
            position ("ok" from 200 studs, "full" at the cap), and EndChopRun alone moves
            the carry into your stock -- so "go home" is one remote, not a walk.

            Zone "Auto" scores every Treezone of the world you're in (TreeZonesData's
            bounds: 1-13, 14-26, 27-39) by wood per swing, and waits ceil(HP / Strength)
            swings before reporting each kill -- a real player's pace, so a zone you can't
            one-shot is still farmable. "All unlocked worlds" widens that to world 2/3 by
            the zone2Unlocked/zone3Unlocked flags, untested against the server. A zone that pays no wood for a while gets a run re-entry first (hop
            past the StartLine), then gets benched for the session and Auto steps down.
     TRAIN: SwingReward:FireServer() on a beat -- the same call a click sends. The game's
            own click handler caps you at 0.06s, so that's the default; the console reports
            how many the server acknowledges (AxeStrengthSync) per second, which is the only
            honest measure of whether going faster buys anything. The Auto Clicker gamepass
            remote (SetAutoClicker) is deliberately not wired: without the pass it's a popup.
     AURA : SpinAura:InvokeServer(nil) until the roll is at least the picked rarity, then
            equips it and switches itself off. Calling the remote directly skips the whole
            cinematic -- the animation is AurasMenu's, run after the reply, not the server's.
            A roll the server holds as pendingSwap is answered with ChooseRolledAura:
            "equip" on a hit, "keep" otherwise. Spends Wins (AurasData.spinCost: 100K, more
            once Zone2/3 is unlocked); stops on "broke". The "lucky" spin is not wired --
            its rerolls are a paid currency.
     SELL : SellTreasure(nil) -- the Sell All button, which works from anywhere. "Sell x2"
            is Robux and deliberately not wired.

     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().chopTreeStop() ]]

-- config ---------------------------------------------------------------------
local MIN_GAP = 0.15 -- floor under the swing beat. Raise it if kills stop paying wood at high SwingSpeedMult
local SEQ_BASE = 1e6 -- our ChopTreeHit seq starts here, far above the game's own counter, so the two never collide
local STALL_TIME = 10 -- seconds with no wood (and at least 3 kills sent) before we act. Raise if AxeDataSync lags
local MAX_HITS = 100 -- zones needing more swings per kill than this are ignored: they pay too slowly and stall slowly
local LOOT_TIMEOUT = 5 -- InvokeServer has no timeout of its own; a parked loot would park the farm
local DEPOSIT_WAIT = 3 -- how long to wait for carried to hit 0 after EndChopRun
local QUEUE_CAP = 60 -- drops kept waiting while a deposit is in flight; oldest go first
local TRAIN_GAP = 0.06 -- the game's own click debounce. Lower it only if the acks/s in the console climb with it
local SPIN_GAP = 0.35 -- the game's own retry after a "busy"; raise if busy replies keep coming
local SELL_GAP = 3 -- Sell All beat. It's one call for everything, no reason to spam it
local RUN_IN = 12 -- studs past the StartLine to land when (re-)entering a run
local LIFT = 4

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().chopTreeStop then
	getgenv().chopTreeStop() -- re-running must not stack a second panel/loop
end

local ChopTreeHit = RS:WaitForChild("ChopTreeHit", 10)
local LootTreasure = RS:WaitForChild("LootTreasure", 10)
local EndChopRun = RS:WaitForChild("EndChopRun", 10)
local SellTreasure = RS:WaitForChild("SellTreasure", 10)
local SwingReward = RS:WaitForChild("SwingReward", 10)
local SpinAura = RS:WaitForChild("SpinAura", 10)
local ChooseRolledAura = RS:WaitForChild("ChooseRolledAura", 10)
local AurasData = require(RS.Shared:WaitForChild("AurasData"))
-- ponytail: copy of AurasData's private rank table (not exported); a new rarity needs a line here
local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret" }
local ZonesData = require(RS:WaitForChild("Shared"):WaitForChild("TreeZonesData"))

-- world ----------------------------------------------------------------------
local mirror = { wood = 0, carried = 0, max = 0, stock = 0, world2 = false, world3 = false }
local drops = {} -- dropIds the server rolled for us, oldest first
local conns = {}

table.insert(conns, RS:WaitForChild("AxeDataSync").OnClientEvent:Connect(function(d)
	if type(d) ~= "table" then
		return
	end
	if type(d.wood) == "number" then
		mirror.wood = d.wood
	end
	-- same flags AurasMenu reads for spin cost; nil means "not in this sync", not "locked"
	if d.zone2Unlocked ~= nil then
		mirror.world2 = d.zone2Unlocked == true
	end
	if d.zone3Unlocked ~= nil then
		mirror.world3 = d.zone3Unlocked == true
	end
	if type(d.treasureCarried) == "table" then
		mirror.carried = #d.treasureCarried
	end
	if type(d.treasureMax) == "number" and d.treasureMax > 0 then
		mirror.max = d.treasureMax
	end
	if type(d.treasureStock) == "table" then
		local n = 0
		for _, c in d.treasureStock do
			n += tonumber(c) or 0
		end
		mirror.stock = n
	end
end))

-- Every drop, including the ones the game's own swings earn: looting those too is free.
table.insert(conns, RS:WaitForChild("TreasureDrop").OnClientEvent:Connect(function(_, list)
	if type(list) ~= "table" then
		return
	end
	for _, v in list do
		if type(v) == "table" and v.dropId then
			table.insert(drops, v.dropId)
		end
	end
	while #drops > QUEUE_CAP do
		table.remove(drops, 1)
	end
end))

local trainAcks = 0 -- one per swing the server actually paid Strength for
table.insert(conns, RS:WaitForChild("AxeStrengthSync").OnClientEvent:Connect(function()
	trainAcks += 1
end))

-- The game's own list (TrainingSystem.lua), so the panel reads the same as the HUD.
local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qn", "Sx", "Sp", "Oc", "No", "Dc", "Ud", "Dd", "Td", "Qad", "Qid", "Sxd", "Spd" }
local function short(n)
	n = tonumber(n) or 0
	local i = 1
	while math.abs(n) >= 1000 and i < #SUFFIX do
		n /= 1000
		i += 1
	end
	return i == 1 and tostring(math.floor(n)) or ("%.2f%s"):format(n, SUFFIX[i])
end
assert(short(999) == "999" and short(1500) == "1.50K" and short(4.5e25) == "45.00Sp")

local function strength()
	local ls = player:FindFirstChild("leaderstats")
	local s = ls and ls:FindFirstChild("Strength")
	return s and tonumber(s.Value) or 0
end

-- Treezone indices this map actually has. Folders/parts named TreezoneN sit directly under
-- each ZoneN, and a container replicates even when its trees haven't streamed in.
local function presentZones()
	local set, list = {}, {}
	for _, zone in workspace:GetChildren() do
		if zone.Name:match("^Zone%d+$") then
			for _, c in zone:GetChildren() do
				local i = ZonesData.zoneIndexFromName(c.Name)
				if i and not set[i] then
					set[i] = true
					table.insert(list, i)
				end
			end
		end
	end
	table.sort(list)
	return list
end

local benched = {} -- zone index -> true once it stalled through a re-entry

local function nearestStartLine()
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return nil, nil
	end
	local best, bestD
	for _, zone in workspace:GetChildren() do
		local line = zone.Name:match("^Zone%d+$") and zone:FindFirstChild("StartLine")
		if line and line:IsA("BasePart") then
			local d = (line.Position - hrp.Position).Magnitude
			if not bestD or d < bestD then
				best, bestD = line, d
			end
		end
	end
	return best, hrp
end

-- Treezones of the world you're standing in, from TreeZonesData's own bounds. Not from the
-- TreezoneN marker parts: those are BaseParts and stream out, which hid every zone past
-- the ones near you (Auto sat on 8 with Strength for 11). The part scan is the fallback.
local WORLDS = {
	{ 1, ZonesData.ZONE_COUNT },
	{ ZonesData.ZONE_COUNT + 1, ZonesData.ZONE2_LAST },
	{ ZonesData.ZONE2_LAST + 1, ZonesData.MAX_ZONE },
}

local function worldZones(scope)
	local worlds = {}
	if scope == "All unlocked worlds" then
		worlds = { WORLDS[1] }
		if mirror.world2 then
			table.insert(worlds, WORLDS[2])
		end
		if mirror.world3 then
			table.insert(worlds, WORLDS[3])
		end
	else
		local line = nearestStartLine()
		local here = line and WORLDS[tonumber(line.Parent.Name:match("^Zone(%d+)$")) or 0]
		if not here then
			return presentZones()
		end
		worlds = { here }
	end
	local list = {}
	for _, b in worlds do
		for i = b[1], b[2] do
			table.insert(list, i)
		end
	end
	return list
end

local function swingGap()
	local mult = tonumber(player:GetAttribute("SwingSpeedMult")) or 1
	-- ponytail: the game's own swing cadence, fixed; walk it down if the server allows faster
	return math.max(MIN_GAP, ZonesData.TREE_SWING / (mult > 0 and mult or 1))
end

-- Swings a real player needs to fell one tree here: what we wait before reporting the kill.
local function hitsFor(z)
	local s = strength()
	return s > 0 and math.max(1, math.ceil(ZonesData.hpForZone(z) / s)) or math.huge
end
assert(math.ceil(1.7e11 / 14.19e9) == 12)

-- Best wood per second: woodForZone / swings (the swing gap is the same for every zone, so
-- it drops out). HP climbs ~5.5x a zone and wood far less, so in practice this lands on the
-- deepest one-swing zone -- but where nothing is one-swing (new world, low Strength) it
-- still finds the best multi-swing zone instead of giving up. Ties go deeper for the luck.
-- ponytail: ignores luckForZone (drop odds); weigh it in if treasure matters more than wood
local function autoZone(scope)
	local zones = worldZones(scope)
	local best, bestScore, blocked = nil, -1, {}
	for _, z in zones do
		local hits = hitsFor(z)
		if hits <= MAX_HITS then
			if benched[z] then
				table.insert(blocked, z)
			else
				local score = ZonesData.woodForZone(z) / hits
				if score >= bestScore then
					best, bestScore = z, score
				end
			end
		end
	end
	return best or zones[1] or 1, blocked
end

-- The game counts you "in a run" once you're >2 studs past the StartLine along its Z, and
-- fires EndChopRun when you walk back behind it. So a hop behind then in is a fresh run.
local function enterRun(fresh)
	local line, hrp = nearestStartLine()
	if not line then
		return
	end
	local z = line.CFrame:PointToObjectSpace(hrp.Position).Z
	if z > 2 and not fresh then
		return
	end
	if fresh then
		hrp.CFrame = line.CFrame * CFrame.new(0, LIFT, -8)
		task.wait(0.5)
	end
	hrp.CFrame = line.CFrame * CFrame.new(0, LIFT, RUN_IN)
	task.wait(0.5)
end

-- farm -----------------------------------------------------------------------
local pending -- status text; a resumed loop thread can't touch the panel, Heartbeat drains it
local function say(msg)
	pending = msg
	print("[chop] " .. msg)
end
local pendingZone -- same drain, own row: train chatter overwrites Status every 5s
local pendingAura
local function sayAura(msg)
	pendingAura = msg
	print("[chop] aura: " .. msg)
end

local picked = "Auto"
local scope = "This world"
local perHit = 1
local counts = { kills = 0, loots = 0, deposits = 0 }

local function deposit()
	EndChopRun:FireServer()
	local t0 = os.clock()
	repeat
		task.wait(0.1)
	until mirror.carried == 0 or os.clock() - t0 > DEPOSIT_WAIT
	counts.deposits += 1
end

local function invoke(remote, ...)
	local args = table.pack(...)
	local done, res
	task.spawn(function()
		local ok, r = pcall(function()
			return remote:InvokeServer(table.unpack(args, 1, args.n))
		end)
		done, res = true, ok and r or nil
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < LOOT_TIMEOUT do
		task.wait()
	end
	return res
end

local function loot(id)
	return invoke(LootTreasure, id)
end

local function chopper(alive)
	local seq = SEQ_BASE
	local zone, shownKey, lastWood, reentered = nil, nil, mirror.wood, false
	local paidAt, sentSince = os.clock(), 0
	enterRun(false)
	while alive() do
		local want, blocked = tonumber(picked) or 1, {}
		if picked == "Auto" then
			want, blocked = autoZone(scope)
		end
		local hits = hitsFor(want)
		if want ~= zone then
			zone, reentered, paidAt, sentSince = want, false, os.clock(), 0
		end
		local key = ("%d:%s:%s"):format(zone, tostring(hits), table.concat(blocked, ","))
		if key ~= shownKey then -- re-announce when Strength drops the swing count, too
			shownKey = key
			pendingZone = ("Treezone%d%s -- HP %s  ·  %s swings/kill%s"):format(
				zone,
				picked == "Auto" and " (Auto)" or "",
				short(ZonesData.hpForZone(zone)),
				hits == math.huge and "?" or tostring(hits),
				#blocked > 0 and ("  ·  no pay (locked?): " .. table.concat(blocked, ", ")) or ""
			)
			say("chopping " .. pendingZone)
		end

		-- Wait out the swings a real player would need, THEN report the kill.
		-- In slices, so a toggle-off or a dropdown pick doesn't sit out a 100-swing wait.
		local wait = swingGap() * math.min(hits, MAX_HITS)
		local t0, was = os.clock(), picked
		while alive() and picked == was and os.clock() - t0 < wait do
			task.wait(math.min(0.25, wait - (os.clock() - t0)))
		end
		if not alive() then
			break
		elseif picked ~= was then
			continue
		end
		local hit = table.create(perHit, zone)
		seq += 1
		pcall(ChopTreeHit.FireServer, ChopTreeHit, hit, seq)
		counts.kills += perHit
		sentSince += 1

		if mirror.wood ~= lastWood then
			lastWood, reentered, paidAt, sentSince = mirror.wood, false, os.clock(), 0
		else
			-- By time, not by count: at 12 swings a kill, 12 dry kills was two minutes of nothing.
			if sentSince >= 3 and os.clock() - paidAt >= math.max(STALL_TIME, wait * 3) then
				paidAt, sentSince = os.clock(), 0
				if not reentered then
					reentered = true
					say(("no wood from Treezone%d, re-entering the run"):format(zone))
					enterRun(true)
				elseif picked == "Auto" then
					benched[zone] = true
					say(("Treezone%d still pays nothing, benched"):format(zone))
				else
					say(("Treezone%d pays nothing -- locked, or not your world"):format(zone))
				end
			end
		end
	end
	pendingZone = "not farming"
end

local function looter(alive)
	while alive() do
		local id = drops[1]
		if not id then
			task.wait(0.1)
			continue
		end
		if mirror.max > 0 and mirror.carried >= mirror.max then
			deposit() -- the mirror already says full: skip the refused call
		end
		local res = loot(id)
		if res == "full" then
			deposit()
			res = loot(id)
		end
		table.remove(drops, table.find(drops, id) or 1)
		if res == "ok" then
			counts.loots += 1
			if counts.loots % 10 == 0 then
				say(("looted %d, deposited %d times, stock %d"):format(counts.loots, counts.deposits, mirror.stock))
			end
		end
	end
end

-- One toggle row = one gen counter in its closure, so off-then-on can't double the loop.
local function loopToggle(bodies)
	local gen, on = 0, false
	return function(state)
		on = state
		gen += 1
		if not state then
			return
		end
		local mine = gen
		local alive = function()
			return on and gen == mine
		end
		for _, body in bodies do
			task.spawn(function()
				local ok, err = pcall(body, alive)
				if not ok then
					warn("[chop] " .. tostring(err))
				end
			end)
		end
	end
end

local setFarm = loopToggle({ chopper, looter })
local trainGap = TRAIN_GAP
local setTrain = loopToggle({
	function(alive)
		local sent, acks0, t0 = 0, trainAcks, os.clock()
		while alive() do
			pcall(SwingReward.FireServer, SwingReward)
			sent += 1
			if os.clock() - t0 >= 5 then
				local dt = os.clock() - t0
				-- console only: the dashboard's Train row already shows the paid rate
				print(("[chop] train: sent %.1f/s, server paid %.1f/s"):format(sent / dt, (trainAcks - acks0) / dt))
				sent, acks0, t0 = 0, trainAcks, os.clock()
			end
			task.wait(trainGap)
		end
	end,
})

local function rank(auraId)
	local a = AurasData.get(auraId)
	return a and table.find(RARITIES, a.rarity) or 0, a
end

local targetRarity = "Mythic"
local rollOff -- set by the roll loop; Heartbeat flips the toggle (a loop thread can't touch the panel)
local setRoll = loopToggle({
	function(alive)
		local stopSelf = function()
			if alive() then -- an old gen finishing must not switch off a restarted roll
				rollOff = true
			end
		end
		local want = table.find(RARITIES, targetRarity) or #RARITIES
		local have = rank(player:GetAttribute("EquippedAura"))
		if have >= want then
			sayAura(("already wearing %s or better"):format(targetRarity))
			stopSelf()
			return
		end
		local rolls = 0
		while alive() do
			local r = invoke(SpinAura, nil)
			if type(r) ~= "table" then
				task.wait(SPIN_GAP) -- timed out or threw: try again, the server owns the cadence
			elseif r.err == "broke" then
				sayAura(("out of Wins after %d rolls"):format(rolls))
				stopSelf()
				return
			elseif r.ok ~= true then
				task.wait(SPIN_GAP) -- "busy" and anything else we haven't seen
			else
				rolls += 1
				local got, aura = rank(r.auraId)
				local hit = got >= want
				if r.pendingSwap == true then
					pcall(ChooseRolledAura.FireServer, ChooseRolledAura, hit and "equip" or "keep", r.auraId)
				end
				if hit then
					sayAura(("%s (%s) after %d rolls"):format(aura.name, aura.rarity, rolls))
					stopSelf()
					return
				end
				local msg = ("%d rolls, last %s"):format(rolls, aura and ("%s (%s)"):format(aura.name, aura.rarity) or tostring(r.auraId))
				if rolls % 20 == 0 then
					sayAura(msg)
				else
					pendingAura = msg -- the row redraws once a frame anyway; F9 only every 20
				end
			end
		end
	end,
})

local setSell = loopToggle({
	function(alive)
		while alive() do
			if mirror.stock > 0 then
				pcall(SellTreasure.FireServer, SellTreasure, nil)
			end
			task.wait(SELL_GAP)
		end
	end,
})

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window = panel({ game = "Chop a Tree", folder = "ChopATree", size = UDim2.fromOffset(440, 380) })
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })

-- Section order is card order, so the dashboard is built first; everything that writes to
-- it goes through the Heartbeat drain at the bottom.
local Dash = Tab:Section({ Title = "Dashboard", Icon = "solar:chart-2-bold", Box = true, BoxBorder = true, Opened = true })
-- One card, one line per item: six Paragraphs was a screen of padding for six short lines.
local DASH_ORDER = { "stats", "treasure", "zone", "train", "aura", "status" }
local DASH_LABEL = { stats = "", treasure = "Treasure: ", zone = "Zone: ", train = "Train: ", aura = "Aura: ", status = "Status: " }
local dashText = { stats = "-", treasure = "-", zone = "not farming", train = "-", aura = "-", status = "idle" }
local dashCard = Dash:Paragraph({ Title = "Live", Desc = "loading..." })

local Farm = Tab:Section({ Title = "Farm", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })

Farm:Toggle({
	Title = "Auto Farm",
	Desc = "Chop by remote, loot every drop, deposit when full. Doesn't move you",
	Value = false,
	Callback = setFarm,
})

-- Every zone, not just this world's: picking a world-2 zone while standing in world 1 is
-- how you find out whether the server checks where you are.
local zoneValues = { "Auto" }
for i = 1, ZonesData.MAX_ZONE do
	table.insert(zoneValues, tostring(i))
end
Farm:Dropdown({
	Title = "Treezone",
	Desc = "Auto = most wood per second, paced to the swings each kill really takes",
	Values = zoneValues,
	Value = "Auto",
	Callback = function(v)
		if table.find(zoneValues, v) then
			picked = v
			table.clear(benched) -- a new pick deserves a fresh look at every zone
		end
	end,
})

local SCOPES = { "This world", "All unlocked worlds" }
Farm:Dropdown({
	Title = "Auto looks at",
	Desc = "All unlocked worlds is a test: works only if the server ignores which world you stand in",
	Values = SCOPES,
	Value = scope,
	Callback = function(v)
		if table.find(SCOPES, v) then
			scope = v
			table.clear(benched)
		end
	end,
})

Farm:Slider({
	Title = "Trees per swing",
	Desc = "Kills reported per hit. A real swing reports every tree in reach; 1 is the probed value",
	Step = 1,
	Value = { Min = 1, Max = 6, Default = 1 },
	Callback = function(v)
		perHit = math.max(1, math.floor(tonumber(v) or 1))
	end,
})

local Train = Tab:Section({ Title = "Train", Icon = "solar:dumbbell-large-bold", Box = true, BoxBorder = true, Opened = true })

Train:Toggle({
	Title = "Auto Train",
	Desc = "Clicks for Strength at the game's max click rate. Runs alongside the farm",
	Value = false,
	Callback = setTrain,
})

Train:Slider({
	Title = "Train every",
	Desc = "Seconds between clicks. 0.06 is the game's own cap; watch 'server paid' in F9",
	Step = 0.01,
	Value = { Min = 0.01, Max = 0.3, Default = TRAIN_GAP },
	Callback = function(v)
		trainGap = tonumber(v) or TRAIN_GAP
	end,
})

local Aura = Tab:Section({ Title = "Aura", Icon = "solar:stars-bold", Box = true, BoxBorder = true, Opened = true })

Aura:Dropdown({
	Title = "Stop at",
	Desc = "Rolls until an aura of this rarity or better, equips it, stops",
	Values = { "Rare", "Epic", "Legendary", "Mythic", "Secret" },
	Value = targetRarity,
	Callback = function(v)
		if table.find(RARITIES, v) then
			targetRarity = v
		end
	end,
})

local rollToggle = Aura:Toggle({
	Title = "Auto Roll Aura",
	Desc = "No animation. Spends Wins every roll; stops when broke",
	Value = false,
	Callback = setRoll,
})

Farm:Toggle({
	Title = "Auto Sell",
	Desc = "Sell All every few seconds while you have stock",
	Value = false,
	Callback = setSell,
})

Farm:Button({ Title = "Deposit now", Callback = function()
	task.spawn(deposit)
end })

local shown -- last text written: SetDesc only on change, a redraw per frame is wasted work
local function show(row, text)
	dashText[row] = text
	local lines = {}
	for _, key in DASH_ORDER do
		table.insert(lines, DASH_LABEL[key] .. dashText[key])
	end
	local all = table.concat(lines, "\n")
	if all ~= shown then
		shown = all
		pcall(function()
			dashCard:SetDesc(all)
		end)
	end
end

local lastAura = "not rolling"
local nextTick, acksAt, paidRate = 0, trainAcks, 0
local drain = RunService.Heartbeat:Connect(function()
	if rollOff then
		rollOff = nil
		pcall(rollToggle.Set, rollToggle, false) -- re-enters setRoll(false), which ends the gen
	end
	if pendingAura ~= nil then
		lastAura, pendingAura = pendingAura, nil
	end
	if pendingZone ~= nil then
		show("zone", pendingZone)
		pendingZone = nil
	end
	if pending ~= nil then
		show("status", pending)
		pending = nil
	end

	local now = os.clock()
	if now < nextTick then
		return
	end
	-- Once a second: the numbers come from mirrors the events keep, so this reads, never asks.
	paidRate, acksAt, nextTick = trainAcks - acksAt, trainAcks, now + 1
	show("stats", ("%s Strength  ·  %s Wood"):format(short(strength()), short(mirror.wood)))
	show("treasure", ("carry %d/%d  ·  stock %d  ·  looted %d  ·  deposits %d"):format(
		mirror.carried, mirror.max, mirror.stock, counts.loots, counts.deposits))
	show("train", ("server paid %d/s  ·  every %.2fs"):format(paidRate, trainGap))
	local _, worn = rank(player:GetAttribute("EquippedAura"))
	show("aura", ("wearing %s  ·  %s"):format(worn and ("%s (%s)"):format(worn.name, worn.rarity) or "none", lastAura))
end)

-- close ----------------------------------------------------------------------
local function stopAll()
	setFarm(false)
	setSell(false)
	setTrain(false)
	setRoll(false)
	drain:Disconnect()
	for _, c in conns do
		c:Disconnect()
	end
end

Window:OnDestroy(function()
	stopAll()
	getgenv().chopTreeStop = nil
end)

getgenv().chopTreeStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().chopTreeStop = nil
end
