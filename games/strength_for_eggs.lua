--[[ +1 Strength for Eggs -- steal, place, hatch, sell, train, upgrade, crystals (98610101874791)

     FARM     : eggs of the rarities and zones you tick, best first. The server snaps you back to the last
                spot you legally stood on ~0.4s after any teleport, so a trip is: pin yourself to the wall
                (a Heartbeat re-teleport every 0.12s keeps the server believing it), hit it until its
                GateAccess_<zone> shows up, pin to the egg, press its prompt, teleport home. The held egg
                banks the moment you are home and access to every wall resets, so each trip breaks its
                own wall. A zone whose wall would take longer than "Max wall seconds" is left alone
                (Forest/Beach/Desert fall in a few hits at ~50K strength; Arctic is ~9M HP).
     PLACE    : eggs from your inventory onto free ground of your plot, best rarity first.
     HATCH    : Open the moment the egg's timer is up (earlier is refused). The hatch finishes on Open;
                the 8-12s reveal animation is cosmetic, so it is muted and acked at once.
     EQUIP    : the game's Equip Best, whenever your friend count changes.
     SELL     : hatched friends of the rarities you tick, from the inventory. Nothing is ticked to start with.
     TRAIN    : Activate Dumbell every 0.62s (the server's floor is 0.6s). Pauses while a trip has the
                character (a Tool in hand blocks wall hits) and while you carry an egg.
     UPGRADE  : cheapest affordable of the farm (plot level), Carry and Speed upgrades you tick.
     DUMBELLS : buys the best affordable dumbell (price order is not required) and equips the strongest owned.
     CRYSTAL  : the limited Anubis quest. When a crystal spawns (Rare Spawn Chat), pins to it and takes it,
                then claims the Ancient Dumbell when all nine are found.

     Probed and dead (do not re-probe):
       Damage Gate from home / far, no pin     0 popups: the server checks range
       Steal prompt pressed from home          silently ignored: needs you within ~5 studs
       Open Lucky Block 3s before the timer    refused
       Collect Earnings                        pays nothing
       Wall hit with the dumbell in hand       0 popups (Tool must be unequipped)
       Hit gap below ~0.65s                    dropped, not refused (adaptive gap below)
       Press 0.05s after the teleport          too early; 0.12s flaky; 0.3s used
     Pin cadence probed (6s at the Arctic wall): every 0.12s -> 2 client-side pull-backs, 0.06 -> 7, 0.03 -> 7, every
     frame -> 0, so the pin runs every Heartbeat. The camera is frozen during trips on top of that.
     Not wired (Robux): Skip Incubation, Skip Upgrade, Teleport-to-base while carrying, Prompt Revive,
                the Robux twins of upgrades and dumbells, Upgrade Carry Limit.
     Not wired (not asked): Index / daily / offline claims, Fuse machine, rebirth, basement.
     UNPROVEN until it prints once: more than one egg per trip (Carry level), crystal press, the muted hatch ack.

     RightControl opens / closes the panel. Stop: getgenv().strengthEggsStop() ]]

-- config ---------------------------------------------------------------------
local PIN_EVERY = 0 -- seconds between re-teleports while pinned: 0 = every Heartbeat. The server snaps you back ~0.4s after a teleport; probed over 6s at the wall: 0.12 -> 2 pull-backs, 0.06 -> 7, 0.03 -> 7, every frame -> 0 (and 100% of samples at the wall)
local MISS_TRIES = 2 -- a press with no reply is re-tried this many times (wait x2, x4 STEAL_WAIT) before the egg is benched
local STEAL_WAIT = 0.3 -- after pinning to an egg, before the first press. 0.05 missed, 0.12 was flaky; raise if "none" shows up
local REACT_WAIT = 0.35 -- a press must change the carry flag, the inventory or draw a server note inside this
local HIT_GAP0 = 0.7 -- wall-hit gap to start from; it adapts: x1.2 on a missed popup, x0.97 on a landed one
local HIT_MIN, HIT_MAX = 0.62, 1.3
local DMG_PER_STR = 0.6 -- a wall hit does 0.6 x Strength (probed: 93000 at 155K)
local MAX_WALL_SEC = 20 -- skip a zone whose wall would take longer than this (the box in the panel changes it)
local BANK_WAIT = 1.2 -- after teleporting home the carry flag must clear inside this, else walk home
local WALK_MAX = 20 -- walking home to bank, at most this long, then the egg is dropped
local TRIP_GAP = 0.15 -- between trips
local NO_EGG_WAIT = 1.5 -- when nothing ticked is in reach
local BENCH_START = 5 -- an egg that refused is left alone this long, doubling per refusal up to BENCH_MAX
local BENCH_MAX = 60
local TRAIN_GAP = 0.62 -- Activate Dumbell: the server answers one per 0.6s and drops the rest
local PLACE_GAP = 0.3
local PLACE_CONFIRM = 1.5
local SPOT_STEP = 9 -- studs between candidate egg spots on the plot floor
local SPOT_CLEAR = 8 -- no other placed thing within this of a new egg
local SPOT_INSET = 7
local HATCH_RETRY = 2 -- an egg opened but still incubating is tried again after this
local SELL_GAP = 0.25
local SELL_CONFIRM = 1.5
local EQUIP_GAP = 2
local EQUIP_EVERY = 30
local UPGRADE_EVERY = 1.5
local UPGRADE_BACKOFF = 10
local DUMBELL_EVERY = 2
local CALL_TIMEOUT = 8 -- an InvokeServer that has not answered by then is abandoned
local MIN_RARITY_DEFAULT = 3 -- eggs of this rarity order and up start ticked (3 = Rare)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local player = Players.LocalPlayer

if getgenv and getgenv().strengthEggsStop then
	getgenv().strengthEggsStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[strengtheggs]", ...)
end

-- The panel strip is drained from a Heartbeat, which the engine calls with our own identity.
-- A loop thread that writes to the window directly throws "lacking capability Plugin" after its first wait.
local pending, lastSaid = {}, nil
local function say(msg, quiet, slot)
	pending[slot or "now"] = msg
	if not quiet and msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- game -----------------------------------------------------------------------
local function waitFor(cond, secs)
	local dl = os.clock() + secs
	while os.clock() < dl do
		if cond() then
			return true
		end
		task.wait(0.03)
	end
	return cond() and true or false
end

local Lib
do
	local g = getrenv and getrenv()._G or _G -- the game's _G is not the executor's
	local ok = waitFor(function()
		return g._loaded == true and g._Lib and g._Lib.Data and g._Lib.Database and g._Lib.Shared
	end, 90)
	if not ok then
		warn("[strengtheggs] the game's _Lib never loaded (wrong place or still joining?)")
		return
	end
	Lib = g._Lib
end
local RemotesFolder = ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("Network"):WaitForChild("Remotes")
local remoteCache = {}
local function R(name)
	local r = remoteCache[name]
	if r and r.Parent then
		return r
	end
	r = RemotesFolder:WaitForChild(name, 10)
	remoteCache[name] = r
	return r
end

local function data()
	local ok, d = pcall(function()
		return Lib.Data:Get()
	end)
	return ok and d or {}
end

-- InvokeServer has no timeout: answer on a clock. Replies here carry the Remote itself as their first value, so
-- the table comes back as out[3]; callers confirm on state anyway.
local function callTimed(rf, ...)
	local args, out, done = table.pack(...), nil, false
	task.spawn(function()
		out = table.pack(pcall(rf.InvokeServer, rf, table.unpack(args, 1, args.n)))
		done = true
	end)
	local dl = os.clock() + CALL_TIMEOUT
	while not done and os.clock() < dl do
		task.wait()
	end
	return done and out or nil
end

local function ticked(values)
	local set = {}
	for k, v in pairs(values) do
		if type(v) == "string" then
			set[v] = true -- list form
		elseif v then
			set[k] = true -- map form
		end
	end
	return set
end
assert(ticked({ "a", "b" }).b and ticked({ a = true }).a and not ticked({ a = false }).a, "ticked reads both shapes")

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function fmt(n)
	n = tonumber(n) or 0
	local i = 1
	while n >= 1000 and i < #SUFFIX do
		n /= 1000
		i += 1
	end
	return ("%.3g"):format(n) .. SUFFIX[i]
end
assert(fmt(25000) == "25K" and fmt(1500) == "1.5K" and fmt(260e9) == "260B" and fmt(100) == "100", "fmt")

local function count(t)
	local n = 0
	for _ in pairs(t or {}) do
		n += 1
	end
	return n
end

-- seconds a wall takes at this strength and hit gap
local function secsFor(hp, strength, gap)
	local dmg = math.max(DMG_PER_STR * (tonumber(strength) or 0), 1)
	return math.ceil(hp / dmg) * gap
end
assert(secsFor(10000, 155000, 0.7) == 0.7 and secsFor(375000, 155000, 0.5) == 2.5, "secsFor")

-- the rarity and zone vocabulary, off the game's own tables
local RARITY_ORDER = Lib.Shared.RarityOrders
local ZONE_ORDER = Lib.Shared.ZONE_ORDERS
local function rarityRank(name)
	return RARITY_ORDER[name] or 99
end
local ZONES = {}
for z in pairs(ZONE_ORDER) do
	ZONES[#ZONES + 1] = z
end
table.sort(ZONES, function(a, b)
	return ZONE_ORDER[a] < ZONE_ORDER[b]
end)

-- egg model names equal Friends[id].Name; the entry carries Zone, Rarity, HatchTime. Duplicate ids exist, so key by name.
local eggByName, eggRarities, friendRarities = {}, {}, {}
do
	local seenE, seenF = {}, {}
	for _, e in pairs(Lib.Database.Friends) do
		if type(e) == "table" and e.Name then
			if e.Type == "Lucky Block" then
				eggByName[e.Name] = e
				if e.Rarity and not seenE[e.Rarity] then
					seenE[e.Rarity] = true
					eggRarities[#eggRarities + 1] = e.Rarity
				end
			elseif e.Rarity and not seenF[e.Rarity] then
				seenF[e.Rarity] = true
				friendRarities[#friendRarities + 1] = e.Rarity
			end
		end
	end
	local byRank = function(a, b)
		return rarityRank(a) < rarityRank(b) or (rarityRank(a) == rarityRank(b) and a < b)
	end
	table.sort(eggRarities, byRank)
	table.sort(friendRarities, byRank)
end

-- world ----------------------------------------------------------------------
local function root()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function humanoid()
	local c = player.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end
local function dist(pos)
	local r = root()
	return r and (r.Position - pos).Magnitude or math.huge
end
local function tp(cf)
	local r, c = root(), player.Character
	if not (r and c) then
		return false
	end
	c:PivotTo(cf)
	r.AssemblyLinearVelocity = Vector3.zero
	return true
end

local plot
do
	local plots = workspace:WaitForChild("Plots")
	waitFor(function()
		for _, p in ipairs(plots:GetChildren()) do
			local o = p:FindFirstChild("owner")
			if o and o.Value == player.Name then
				plot = p
				return true
			end
		end
	end, 60)
end
local base = plot and plot:FindFirstChild("Base")
if not (plot and base) then
	warn("[strengtheggs] your plot was not found")
	return
end
local home = base.CFrame * CFrame.new(0, base.Size.Y / 2 + 3, 0)
local homePos = home.Position

-- the server remembers the last place you LEGALLY stood and snaps you back to it after any teleport, so trips
-- must start from home: if you are somewhere else (respawn, wandered off), walk back
local function walkHome()
	local h = humanoid()
	if not h then
		return false
	end
	local t0 = os.clock()
	while dist(homePos) > 8 and os.clock() - t0 < WALK_MAX do
		h:MoveTo(homePos)
		task.wait(0.25)
	end
	return dist(homePos) <= 12
end

-- pin: re-teleport every PIN_EVERY so the server keeps believing we stand there ------------------------------
local pinCF, pinAt = nil, 0
local pinCon = RunService.Heartbeat:Connect(function()
	if pinCF and os.clock() - pinAt >= PIN_EVERY then
		pinAt = os.clock()
		tp(pinCF)
	end
end)
local function pinTo(cf)
	pinCF, pinAt = cf, os.clock()
	tp(cf)
end
local function unpin()
	pinCF = nil
end

-- The server rewinds you home a few times a second while you are pinned elsewhere, and a camera that follows the
-- character shows every jump. While a trip has the character the camera is frozen on the plot instead, and let
-- go again a second after the last trip.
local freezeCam = true
local camSaved, camBusyEnd = nil, 0
local function lockCamera()
	local cam = workspace.CurrentCamera
	if not freezeCam or camSaved or not cam then
		return
	end
	camSaved = { type = cam.CameraType, subject = cam.CameraSubject }
	cam.CameraType = Enum.CameraType.Scriptable -- keeps the CFrame it had
end
local function unlockCamera()
	local cam = workspace.CurrentCamera
	local s = camSaved
	camSaved = nil
	if s and cam then
		cam.CameraType = s.type == Enum.CameraType.Scriptable and Enum.CameraType.Custom or s.type
		local h = humanoid()
		cam.CameraSubject = (s.subject and s.subject.Parent) and s.subject or h
	end
end

-- events we read (never polled) --------------------------------------------------------------------------------
local conns = {}
local noteN, lastNote = 0, ""
local popN = 0
local heldFlips = 0
local totalHP = {} -- zone -> MaxHealth x TotalLayers, from Gate States
local layerOf = {} -- zone -> the wall layer now being hit, from Gate Visual
local finishedOf = {} -- zone -> every layer broken? GateAccess_<zone> turns true BEFORE that (3 hits = 107M of Volcano's 192M), and the server refuses the 2nd egg until it does
-- notes our own helpers cause (Equip Best, the bank) are not a reply to a press
local NOISE = { "best animals", "Successfully" }
table.insert(
	conns,
	R("Send Notification").OnClientEvent:Connect(function(msg)
		msg = tostring(msg)
		for _, s in ipairs(NOISE) do
			if msg:find(s, 1, true) then
				return
			end
		end
		noteN += 1
		lastNote = msg
	end)
)
table.insert(
	conns,
	R("Gate Visual").OnClientEvent:Connect(function(kind, a, b, c, d)
		if kind == "DamagePopup" then
			popN += 1
		elseif kind == "State" then
			layerOf[a] = c -- ("State", zone, hp, layer, finished, opened)
			finishedOf[a] = d
		elseif kind == "ImpactLayer" then
			layerOf[a] = b -- ("ImpactLayer", zone, layer, hp)
		elseif kind == "OpenLayer" then
			layerOf[a] = (b or 0) + 1 -- ("OpenLayer", zone, layer): the next one is active
		end
	end)
)
table.insert(
	conns,
	player:GetAttributeChangedSignal("holdingFriend"):Connect(function()
		heldFlips += 1
	end)
)
local function holding()
	return player:GetAttribute("holdingFriend") == true
end
local function hasAccess(zone)
	return player:GetAttribute("GateAccess_" .. zone) == true
end
local function isNight()
	return workspace:FindFirstChild("NightPart") ~= nil or workspace:GetAttribute("NightActive") == true
end
local function invFriends()
	return (data().Inventory or {}).Friends or {}
end
local function invN()
	return #invFriends()
end

local function loadGates()
	local out = callTimed(R("Gate States"))
	local tbl = out and out[1] and out[3]
	if type(tbl) == "table" then
		for zone, g in pairs(tbl) do
			if type(g) == "table" and g.MaxHealth and g.TotalLayers then
				totalHP[zone] = g.MaxHealth * g.TotalLayers
			end
		end
	end
	for zone, cfg in pairs(Lib.Database.Gates or {}) do
		if not totalHP[zone] and cfg.Health then
			totalHP[zone] = cfg.Health * (cfg.Layers or 1) -- the config's layer counts are off from the server's: fallback only
		end
	end
end
task.spawn(loadGates)

-- state read by the loops ----------------------------------------------------------------------------------
local stats = { stolen = 0, trips = 0, hatched = 0, placed = 0, sold = 0, upgrades = 0, dumbells = 0, trained = 0, crystals = 0 }
local rarOn, zoneOn, sellOn, upgOn = {}, {}, {}, {}
local maxWall = MAX_WALL_SEC
local preferMut = true
local hitGap = HIT_GAP0
local placeOn, placePass = false, nil -- Auto Place: the farm calls placePass between trips (set in "place" below)
local busy = false -- a trip (or a crystal grab) has the character: Place, Train and Hatch stay out
local crystalQ = {}
local crystalWatch = false
local zoneBench = {} -- zone -> when it may be tried again (walls that did not give)
local eggBench = setmetatable({}, { __mode = "k" }) -- egg model -> { til, n }

local function strength()
	return tonumber(data().Strength) or 0
end
-- still to break: no access yet, or access granted early while layers remain
local function walled(zone)
	return not hasAccess(zone) or finishedOf[zone] == false
end
local function wallSecs(zone)
	if not walled(zone) then
		return 0
	end
	local hp = totalHP[zone]
	return hp and secsFor(hp, strength(), math.max(hitGap, HIT_GAP0)) or 0
end

local function withBusy(fn)
	local dl = os.clock() + 20
	while busy and os.clock() < dl do
		task.wait(0.05)
	end
	if busy then
		return false
	end
	busy = true
	lockCamera()
	local ok, err = pcall(fn)
	busy = false
	camBusyEnd = os.clock()
	if not ok then
		warn("[strengtheggs] trip failed:", err)
	end
	return true
end

local function unequipTools()
	local h = humanoid()
	if h then
		pcall(h.UnequipTools, h)
	end
end

-- press ------------------------------------------------------------------------------------------------------
local function pressFire(pr)
	fireproximityprompt(pr)
end
local function pressHold(pr)
	pr:InputHoldBegin()
	task.wait(math.max(pr.HoldDuration, 0.05) + 0.05)
	pr:InputHoldEnd()
end
local function pressKey(pr)
	local k = pr.KeyboardKeyCode ~= Enum.KeyCode.Unknown and pr.KeyboardKeyCode or Enum.KeyCode.E
	VirtualInputManager:SendKeyEvent(true, k, false, game)
	task.wait(math.max(pr.HoldDuration, 0.05) + 0.1)
	VirtualInputManager:SendKeyEvent(false, k, false, game)
end
local METHODS = { { "fire", pressFire }, { "hold", pressHold }, { "key", pressKey } }
local pressWon = 1 -- the method that last worked goes first (fire won Forest, key won Beach/Desert in the probe)

-- fire / hold / key in turn until reacted() says the server heard. Returns whether it did.
local function pressUntil(pr, reacted)
	pr.RequiresLineOfSight = false
	pr.MaxActivationDistance = 25
	pr.Enabled = true
	local w = pressWon
	for _, m in ipairs({ w, w, (w % 3) + 1, ((w + 1) % 3) + 1 }) do
		if not pr.Parent then
			return false
		end
		pcall(METHODS[m][2], pr)
		if waitFor(reacted, REACT_WAIT) then
			pressWon = m
			return true
		end
	end
	return false
end

-- walls ------------------------------------------------------------------------------------------------------------
-- A wall is a stack of layers running away from your base (Layer_1 nearest) and a hit only lands within ~16 studs of
-- the ACTIVE layer. The Info part marks the middle of the stack, which for the deep walls (Volcano 7 layers, Void 10)
-- is inside layer 3-4 and ~50 studs from layer 1: standing there landed 0 of 12 hits. So stand 6 studs in front of the
-- active layer's near face and follow it as layers open (also why a fixed spot dropped hits on Beach/Desert).
local function wallCF(zone)
	local g = workspace.Map.Gates:FindFirstChild(zone)
	local gen = g and g:FindFirstChild("Blocks") and g.Blocks:FindFirstChild("Generated")
	local l = gen and (gen:FindFirstChild("Layer_" .. (layerOf[zone] or 1)) or gen:FindFirstChild("Layer_1"))
	if l and l:IsA("BasePart") then
		return CFrame.new(l.Position.X, 5, l.Position.Z + l.Size.Z / 2 + 6)
	end
	local info = g and g:FindFirstChild("Info")
	return info and CFrame.new(info.Position.X, 5, info.Position.Z + 10)
end

-- pinned at the wall, hit until GateAccess_<zone>. The gap learns the server's floor from the popups it sends back.
local breakLogs = 0
local wallDoneAt = -99 -- when the last wall break ended, for the "no reply" context line
local function ensureAccess(zone, alive)
	if not walled(zone) then
		return true
	end
	if not hasAccess(zone) then
		layerOf[zone], finishedOf[zone] = nil, nil -- a bank resets every wall to layer 1
	end
	local cf = wallCF(zone)
	if not cf then
		return false
	end
	unequipTools()
	pinTo(cf)
	task.wait(0.25)
	local deadline = os.clock() + math.max(10, wallSecs(zone) * 2 + 6)
	local hits, popped = 0, 0
	while walled(zone) and alive() and os.clock() < deadline do
		local want = wallCF(zone)
		if want and want ~= cf then
			cf = want
			pinTo(cf) -- the active layer moved back: follow it
		end
		local p0 = popN
		pcall(function()
			R("Damage Gate"):FireServer(zone)
		end)
		hits += 1
		local landed = waitFor(function()
			return popN > p0 or not walled(zone)
		end, 0.4)
		if landed then
			popped += 1
			hitGap = math.max(HIT_MIN, hitGap * 0.97)
		else
			hitGap = math.min(HIT_MAX, hitGap * 1.2)
		end
		if not walled(zone) then
			break
		end
		task.wait(hitGap)
		if hits == 12 and popped == 0 then
			break -- nothing lands: wrong place or a Tool in hand; leave it to the bench
		end
	end
	wallDoneAt = os.clock()
	if hasAccess(zone) and breakLogs < 8 then
		breakLogs += 1
		log(
			("wall %s open: %d hits, %d landed, gap %.2f, strength %s, finished=%s"):format(
				zone,
				hits,
				popped,
				hitGap,
				fmt(strength()),
				tostring(finishedOf[zone])
			)
		)
	end
	if hasAccess(zone) and walled(zone) then
		-- access came but no "finished" ever did: go and try the egg anyway rather than bench a zone that may be fine
		log(("wall %s: access but not finished after %d hits (layer %s); trying the egg anyway"):format(zone, hits, tostring(layerOf[zone])))
		return true
	end
	if not hasAccess(zone) then
		unpin()
		if alive() then -- not just pre-empted by a crystal
			zoneBench[zone] = os.clock() + 30
			say(("wall %s did not give (%d hits, %d landed, gap %.2f, layer %s)"):format(zone, hits, popped, hitGap, tostring(layerOf[zone])), false, "now")
		end
		return false
	end
	return true
end

-- steal ---------------------------------------------------------------------------------------------------------------
local function liveEggs()
	local out = {}
	local folder = workspace:FindFirstChild("Live") and workspace.Live:FindFirstChild("Friends")
	for _, m in ipairs(folder and folder:GetChildren() or {}) do
		local rp = m:FindFirstChild("RootPart")
		local pr = m:FindFirstChildWhichIsA("ProximityPrompt", true)
		local e = eggByName[m.Name]
		if m:IsA("Model") and rp and pr and pr.Name == "StealPrompt" and e then
			local lbl = m:FindFirstChild("MutationEgg", true)
			lbl = lbl and lbl:FindFirstChildWhichIsA("TextLabel", true)
			out[#out + 1] = {
				model = m,
				rp = rp,
				prompt = pr,
				zone = e.Zone,
				rarity = e.Rarity,
				name = m.Name,
				mut = lbl and lbl.Text ~= "" and lbl.Text or nil,
			}
		end
	end
	return out
end

local function benchEgg(egg)
	local b = eggBench[egg.model] or { n = 0 }
	b.n += 1
	b.til = os.clock() + math.min(BENCH_MAX, BENCH_START * 2 ^ (b.n - 1))
	eggBench[egg.model] = b
end

-- best ticked egg in an affordable zone: rarity, then mutated, then the cheaper zone
local function pickEgg(zone, from)
	local best, bs, why = nil, -math.huge, "nothing ticked is up"
	local now = os.clock()
	for _, e in ipairs(liveEggs()) do
		local b = eggBench[e.model]
		local zb = zoneBench[e.zone]
		if not e.zone or (zone and e.zone ~= zone) then
			-- not this zone
		elseif not (rarOn[e.rarity] and zoneOn[e.zone]) then
			-- not ticked
		elseif b and b.til > now then
			why = "ticked eggs are benched after refusals"
		elseif zb and zb > now then
			why = ("wall of %s did not give, retrying soon"):format(e.zone)
		elseif wallSecs(e.zone) > maxWall then
			why = ("wall of %s takes ~%.0fs (> %.0fs)"):format(e.zone, wallSecs(e.zone), maxWall)
		else
			local s = rarityRank(e.rarity) * 1000 + (preferMut and e.mut and 500 or 0) - (ZONE_ORDER[e.zone] or 99) * 10
			if from then
				s -= (e.rp.Position - from).Magnitude / 100
			end
			if s > bs then
				best, bs = e, s
			end
		end
	end
	return best, why
end

-- Leave the carry at home: teleport, and if the server put us back somewhere else, walk.
local function bankHome(inv0)
	unpin()
	tp(home)
	if not waitFor(function()
		return not holding()
	end, BANK_WAIT) then
		say("banking on foot", true)
		local h = humanoid()
		local t0 = os.clock()
		while holding() and os.clock() - t0 < WALK_MAX do
			if h then
				h:MoveTo(homePos)
			end
			task.wait(0.25)
		end
		if holding() then
			pcall(function()
				R("Drop Friend"):FireServer()
			end)
			log("could not bank, dropped the egg")
		end
	end
	return waitFor(function()
		return invN() > inv0
	end, 2)
end

local firstMulti = true
local function trip(egg, alive)
	local zone = egg.zone
	say(("%s %s (%s) wall ~%.0fs"):format(zone, egg.name, egg.rarity, wallSecs(zone)))
	stats.trips += 1
	unequipTools()
	if dist(homePos) > 20 then
		walkHome()
	end
	if not ensureAccess(zone, alive) then
		return
	end
	local inv0 = invN()
	local cap = 1 + (tonumber(data().CarryLevel) or 0)
	local got, cur = 0, egg
	while cur and got < cap and alive() do
		local n0, h0, i0 = noteN, heldFlips, invN()
		local ok, tries = false, 0
		-- A press the server ignores without a word (no note, no carry flag) is the "sometimes it works, sometimes it
		-- doesn't": it follows a wall break or a long hop, so the server probably has not accepted the new position yet.
		-- Re-pin and wait longer once before benching the egg.
		for attempt = 1, MISS_TRIES do
			tries = attempt
			pinTo(CFrame.new(cur.rp.Position + Vector3.new(0, 3, 4)))
			task.wait(STEAL_WAIT * attempt * attempt)
			ok = pressUntil(cur.prompt, function()
				return heldFlips > h0 or invN() > i0 or noteN > n0
			end)
			if ok or not alive() then
				break
			end
		end
		if tries > 1 and ok and (heldFlips > h0 or invN() > i0) then
			log(("press on %s needed try %d (wait %.2fs)"):format(cur.name, tries, STEAL_WAIT * tries * tries))
		elseif not ok and cur.prompt.Parent then
			log(
				("no reply from %s after %d tries: %.0f studs from it, prompt Enabled=%s, hold=%.2f, wall done %.1fs ago"):format(
					cur.name,
					tries,
					dist(cur.rp.Position),
					tostring(cur.prompt.Enabled),
					cur.prompt.HoldDuration,
					os.clock() - wallDoneAt
				)
			)
		end
		if ok and (heldFlips > h0 or invN() > i0) then
			got += 1
			eggBench[cur.model] = { n = 1, til = os.clock() + BENCH_MAX } -- it is gone from the world in a moment: never pick it again
			if got == 2 and firstMulti then
				firstMulti = false
				log("second egg of one trip taken (carry cap", cap, ")")
			end
		else
			benchEgg(cur)
			if got >= 1 and got < cap then
				log(
					("egg #%d refused: %s (%s z=%.0f, access=%s finished=%s layer=%s)"):format(
						got + 1,
						noteN > n0 and lastNote or "no reply",
						cur.name,
						cur.rp.Position.Z,
						tostring(hasAccess(zone)),
						tostring(finishedOf[zone]),
						tostring(layerOf[zone])
					)
				)
			elseif got == 0 then
				say(("press on %s: %s"):format(cur.name, noteN > n0 and lastNote or "no reply"))
			end
			break
		end
		if got >= cap then
			break
		end
		cur = pickEgg(zone, cur.rp.Position) -- same zone only: its wall is open
	end
	if got == 0 then
		unpin()
		tp(home)
		return
	end
	local banked = bankHome(inv0)
	local took = invN() - inv0
	if took > 0 then
		stats.stolen += took
	elseif got > 0 and not banked then
		log("steal reacted but the inventory did not grow")
	end
end

-- farm -------------------------------------------------------------------------------------------------------------------
local genFarm = 0
local function farmLoop(mine)
	local function alive()
		return genFarm == mine and not (crystalWatch and #crystalQ > 0)
	end
	while genFarm == mine do
		local good, err = pcall(function()
			if isNight() then
				say("night: the islands are closed while eggs reset")
				task.wait(1)
				return
			end
			if not root() then
				task.wait(0.5)
				return
			end
			local egg, why = pickEgg()
			if not egg then
				say("no egg: " .. why, true)
				task.wait(NO_EGG_WAIT)
				return
			end
			if not withBusy(function()
				trip(egg, alive)
			end) then
				task.wait(0.2)
			end
			if placeOn and placePass then
				for _ = 1, 4 do -- at home after the bank: set down whatever is waiting before the next trip
					if not placePass(true) then
						break
					end
				end
			end
			task.wait(TRIP_GAP)
		end)
		if not good then
			warn("[strengtheggs] farm pass failed:", err)
			unpin()
			task.wait(1)
		end
	end
	unpin()
end
local function setFarm(on)
	genFarm += 1
	if on then
		task.spawn(farmLoop, genFarm)
	else
		unpin()
	end
end

-- crystals ---------------------------------------------------------------------------------------------------------------
local quest = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("LimitedAnubisQuest")
local CRYSTAL_TOTAL = count(Lib.Shared.ANUBIS_CRYSTAL_CHANCES)
local function crystalsFound()
	return data().AnubisCrystals or {}
end
local function crystalHas(zone)
	return table.find(crystalsFound(), zone) ~= nil
end
local function promptPos(pr)
	local a = pr.Parent
	return a:IsA("Attachment") and a.WorldPosition or a.Position
end
local function pushCrystal(pr)
	if pr:IsA("ProximityPrompt") and pr.Name == "CrystalPrompt" and pr.Parent and pr.Parent.Parent then
		crystalQ[#crystalQ + 1] = { prompt = pr, zone = pr.Parent.Parent.Name }
	end
end
local function claimAnubis()
	local unlocked = data().UnlockedDumbells or {}
	local id = Lib.Shared.ANUBIS_QUEST_DUMBELL or "E_Dumbell_1"
	if #crystalsFound() >= CRYSTAL_TOTAL and not table.find(unlocked, id) then
		pcall(function()
			R("Claim Anubis Dumbell"):FireServer()
		end)
		log("all", CRYSTAL_TOTAL, "crystals found: claimed the Ancient Dumbell")
	end
end

local firstCrystal = true
local genCrystal = 0
local function snipe(item, mine)
	local pr, zone = item.prompt, item.zone
	if not pr.Parent or crystalHas(zone) then
		return
	end
	withBusy(function()
		unequipTools()
		if dist(homePos) > 20 then
			walkHome()
		end
		local c0 = #crystalsFound()
		local function grab()
			local n0 = noteN
			pinTo(CFrame.new(promptPos(pr) + Vector3.new(0, 3, 3)))
			task.wait(STEAL_WAIT)
			pressUntil(pr, function()
				return #crystalsFound() > c0 or not pr.Parent or noteN > n0
			end)
			waitFor(function()
				return #crystalsFound() > c0 or not pr.Parent
			end, 0.6)
			return n0
		end
		local n0 = grab()
		if #crystalsFound() <= c0 and pr.Parent and noteN > n0 and lastNote:lower():find("wall") then
			-- the wall rule applies here too: break the zone's wall, then take it
			if ensureAccess(zone, function()
				return genCrystal == mine
			end) then
				grab()
			end
		end
		unpin()
		tp(home)
		waitFor(function()
			return not holding()
		end, 1)
		if #crystalsFound() > c0 then
			stats.crystals += 1
			log(("took the %s crystal (%d/%d)"):format(zone, #crystalsFound(), CRYSTAL_TOTAL))
			claimAnubis()
		elseif firstCrystal then
			firstCrystal = false
			log("crystal press at", zone, "did not take; last server note:", lastNote)
		end
	end)
end

local function setCrystal(on)
	genCrystal += 1
	crystalWatch = on
	table.clear(crystalQ)
	if not on then
		return true
	end
	if not quest then
		say("crystal event is not in this server")
		return false
	end
	local mine = genCrystal
	for _, d in ipairs(quest:GetDescendants()) do
		pushCrystal(d)
	end
	claimAnubis()
	task.spawn(function()
		while genCrystal == mine do
			local item = table.remove(crystalQ, 1)
			if item then
				local good, err = pcall(snipe, item, mine)
				if not good then
					warn("[strengtheggs] crystal grab failed:", err)
					unpin()
				end
			else
				task.wait(0.1)
			end
		end
	end)
	return true
end
if quest then
	table.insert(
		conns,
		quest.DescendantAdded:Connect(function(d)
			if crystalWatch then
				pushCrystal(d)
			end
		end)
	)
end

-- place ------------------------------------------------------------------------------------------------------------------
local genPlace = 0
local eggBadUntil, badSpot = {}, {}

local function placedPos()
	local out = {}
	for _, pf in pairs(data().PlotFriends or {}) do
		if type(pf) == "table" and type(pf.pos) == "table" then
			out[#out + 1] = Vector2.new(pf.pos.x or 0, pf.pos.z or 0)
		end
	end
	return out
end
-- grid over the plot floor in the floor's own x,z (the coordinates Place Friend takes), centre first
local function freeSpot()
	local taken = placedPos()
	local sx, sz = base.Size.X / 2 - SPOT_INSET, base.Size.Z / 2 - SPOT_INSET
	local cands = {}
	for x = -sx, sx, SPOT_STEP do
		for z = -sz, sz, SPOT_STEP do
			cands[#cands + 1] = Vector2.new(x, z)
		end
	end
	table.sort(cands, function(a, b)
		return a.Magnitude < b.Magnitude
	end)
	for _, c in ipairs(cands) do
		local key = ("%d,%d"):format(c.X, c.Y)
		local free = not (badSpot[key] and os.clock() - badSpot[key] < 60)
		for _, t in ipairs(taken) do
			if (t - c).Magnitude < SPOT_CLEAR then
				free = false
				break
			end
		end
		if free then
			return c, key
		end
	end
end
assert(SPOT_STEP >= SPOT_CLEAR, "grid spots must not clash with each other")

local function bestEggInInventory()
	local best, bs
	for _, f in ipairs(invFriends()) do
		local e = Lib.Database.Friends[f.id]
		if e and e.Type == "Lucky Block" and not (eggBadUntil[f.uid] and eggBadUntil[f.uid] > os.clock()) then
			local s = rarityRank(e.Rarity) * 100000 - (e.HatchTime or 0)
			if not bs or s > bs then
				best, bs = f, s
			end
		end
	end
	return best
end

-- One egg onto the plot. Called by the farm between trips (the character is home then, and the trip loop leaves a
-- gap of 0.15s that a 0.3s poll never caught: Auto Place did nothing while the farm ran) and by placeLoop when no
-- trip has the character. Returns whether an egg was placed.
local placing, whyAt = false, {}
local placeFails, placePause = 0, 0
local function placeWhy(msg)
	say(msg, true)
	if os.clock() - (whyAt[msg] or -99) > 20 then
		whyAt[msg] = os.clock()
		log("place idle: " .. msg)
	end
end
placePass = function(fromFarm)
	if placing or (busy and not fromFarm) or holding() or not root() then
		return false
	end
	if os.clock() < placePause then
		return false
	end
	local f = bestEggInInventory()
	if not f then
		return false
	end
	-- No slot gate: the plot held 31 of "27" slots, so getPlotSlots is not the server's limit. Try, and let a refusal say so.
	if dist(homePos) > 60 then
		placeWhy(("not at the plot (%.0f studs): the server wants you there to place"):format(dist(homePos)))
		return false
	end
	local spot, key = freeSpot()
	if not spot then -- every grid spot is taken: stack on top of something (UNPROVEN that the server allows overlap)
		spot = Vector2.new(math.random(-20, 20), math.random(-20, 20))
		key = "stack"
	end
	placing = true
	local ok, placed = pcall(function()
		pcall(function()
			R("Place Friend"):FireServer(f.uid, spot.X, spot.Y)
		end)
		return waitFor(function()
			return (data().PlotFriends or {})[f.uid] ~= nil
		end, PLACE_CONFIRM)
	end)
	placing = false
	if ok and placed then
		stats.placed += 1
		placeFails = 0
		return true
	end
	badSpot[key] = os.clock()
	eggBadUntil[f.uid] = os.clock() + 5
	placeFails += 1
	log(("place refused at %s with %d on the plot (slots %d), last note: %s"):format(key, count(data().PlotFriends), Lib.Shared.getPlotSlots(data().BaseLevel), lastNote))
	if placeFails >= 3 then -- the plot really is full (or the spot rule bites): stop hammering, try again in a while
		placeFails, placePause = 0, os.clock() + 15
	end
	return false
end

local function placeLoop(mine)
	while genPlace == mine do
		local good, err = pcall(function()
			task.wait(placePass(false) and PLACE_GAP or 0.3)
		end)
		if not good then
			warn("[strengtheggs] place pass failed:", err)
			task.wait(1)
		end
	end
end
local function setPlace(on)
	genPlace += 1
	placeOn = on
	if on then
		task.spawn(placeLoop, genPlace)
	end
end

-- hatch ------------------------------------------------------------------------------------------------------------------
-- The server finishes the hatch on Open; the reveal is only the client's animation, which ends by acking
-- Play Lucky Block Anim(uid). Mute the game's listener (before ours) and ack at once.
local genHatch = 0
local hatchMuted, hatchAck = nil, nil
local opened = {}

local function muteHatch()
	if hatchMuted or not getconnections then
		return
	end
	hatchMuted = {}
	local anim = R("Play Lucky Block Anim")
	for _, c in ipairs(getconnections(anim.OnClientEvent)) do
		if pcall(function()
			c:Disable()
		end) then
			hatchMuted[#hatchMuted + 1] = c
		end
	end
	hatchAck = anim.OnClientEvent:Connect(function(_, uid)
		if type(uid) == "string" then
			anim:FireServer(uid)
		end
	end)
end
local function unmuteHatch()
	if hatchAck then
		hatchAck:Disconnect()
		hatchAck = nil
	end
	for _, c in ipairs(hatchMuted or {}) do
		pcall(function()
			c:Enable()
		end)
	end
	hatchMuted = nil
end

local function hatchLoop(mine)
	while genHatch == mine do
		local good, err = pcall(function()
			local did = false
			for uid, pf in pairs(data().PlotFriends or {}) do
				if genHatch ~= mine then
					break
				end
				if
					type(pf) == "table"
					and pf.incubating
					and (pf.finishTime or math.huge) <= os.time()
					and os.clock() - (opened[uid] or -9) > HATCH_RETRY
				then
					opened[uid] = os.clock()
					pcall(function()
						R("Open Lucky Block"):FireServer(uid)
					end)
					if
						waitFor(function()
							local x = (data().PlotFriends or {})[uid]
							return not (x and x.incubating)
						end, 1.5)
					then
						stats.hatched += 1
					end
					did = true
				end
			end
			if not did then
				task.wait(0.25)
			end
		end)
		if not good then
			warn("[strengtheggs] hatch pass failed:", err)
			task.wait(1)
		end
	end
end
local function setHatch(on)
	genHatch += 1
	if on then
		muteHatch()
		task.spawn(hatchLoop, genHatch)
	else
		unmuteHatch()
	end
end

-- equip ------------------------------------------------------------------------------------------------------------------
local genEquip = 0
local function equipLoop(mine)
	local sig, lastFire = nil, -EQUIP_EVERY
	while genEquip == mine do
		local d = data()
		local now = os.clock()
		local s = ("%d:%d"):format(#((d.Inventory or {}).Friends or {}), count(d.PlotFriends))
		if (s ~= sig and now - lastFire >= EQUIP_GAP) or now - lastFire >= EQUIP_EVERY then
			sig, lastFire = s, now
			pcall(function()
				R("Equip Best"):FireServer()
			end)
		end
		task.wait(1)
	end
end
local function setEquip(on)
	genEquip += 1
	if on then
		task.spawn(equipLoop, genEquip)
	end
end

-- sell -------------------------------------------------------------------------------------------------------------------
local genSell = 0
local sellTried = {}
local function sellLoop(mine)
	while genSell == mine do
		local good, err = pcall(function()
			local did = false
			local list = table.clone(invFriends())
			for _, f in ipairs(list) do
				if genSell ~= mine then
					break
				end
				local e = Lib.Database.Friends[f.id]
				if e and e.Type ~= "Lucky Block" and sellOn[e.Rarity] and os.clock() - (sellTried[f.uid] or -99) > 10 then
					sellTried[f.uid] = os.clock()
					pcall(function()
						R("Sell Friend From Inventory"):FireServer(f.uid)
					end)
					local gone = waitFor(function()
						for _, g in ipairs(invFriends()) do
							if g.uid == f.uid then
								return false
							end
						end
						return true
					end, SELL_CONFIRM)
					if gone then
						stats.sold += 1
					end
					did = true
					task.wait(SELL_GAP)
				end
			end
			if not did then
				task.wait(1)
			end
		end)
		if not good then
			warn("[strengtheggs] sell pass failed:", err)
			task.wait(1)
		end
	end
end
local function setSell(on)
	genSell += 1
	if on then
		task.spawn(sellLoop, genSell)
	end
end

-- train ------------------------------------------------------------------------------------------------------------------
local genTrain = 0
local function dumbellTool()
	local c = player.Character
	for _, t in ipairs(c and c:GetChildren() or {}) do
		if t:IsA("Tool") and t:GetAttribute("Type") == "Dumbell" then
			return t, true
		end
	end
	for _, t in ipairs(player.Backpack:GetChildren()) do
		if t:IsA("Tool") and t:GetAttribute("Type") == "Dumbell" then
			return t, false
		end
	end
end
local function trainLoop(mine)
	while genTrain == mine do
		if busy or holding() or not root() then
			task.wait(0.2)
		else
			local tool, inHand = dumbellTool()
			if not tool then
				say("train: no dumbell in your backpack", true)
				task.wait(1)
			else
				if not inHand then
					local h = humanoid()
					if h then
						pcall(h.EquipTool, h, tool)
					end
					task.wait(0.15)
				end
				pcall(function()
					R("Activate Dumbell"):FireServer()
				end)
				stats.trained += 1
				task.wait(TRAIN_GAP)
			end
		end
	end
end
local function setTrain(on)
	genTrain += 1
	if on then
		task.spawn(trainLoop, genTrain)
	end
end

-- upgrade ----------------------------------------------------------------------------------------------------------------
local genUpgrade = 0
local backoff = {}
local function upgradeLoop(mine)
	while genUpgrade == mine do
		local good, err = pcall(function()
			local d = data()
			local cash = tonumber(d.Cash) or 0
			local cands = {}
			for _, id in ipairs({ "Speed", "Carry" }) do
				local tr = Lib.Database.UpgradeTracks[id]
				local price = upgOn[id] and tr and Lib.Shared.getNextUpgradePrice(tr, d)
				if price and cash >= price and (backoff[id] or 0) < os.clock() then
					cands[#cands + 1] = { id = id, price = price, stat = tr.Stat, level = d[tr.Stat] }
				end
			end
			local lvl = tonumber(d.BaseLevel) or 0
			local fp = upgOn.Farm and lvl < Lib.Shared.MAX_PLOT_LEVEL and Lib.Database.BaseLevelPrices[lvl + 1]
			if fp and cash >= fp and (backoff.Farm or 0) < os.clock() then
				cands[#cands + 1] = { id = "Farm", price = fp, stat = "BaseLevel", level = d.BaseLevel }
			end
			table.sort(cands, function(a, b)
				return a.price < b.price
			end)
			local c = cands[1]
			if c then
				if c.id == "Farm" then
					callTimed(R("Purchase Floor"), lvl + 1)
				else
					pcall(function()
						R("Buy Upgrade"):FireServer(c.id)
					end)
				end
				if
					waitFor(function()
						return (tonumber(data()[c.stat]) or 0) > (tonumber(c.level) or 0)
					end, 1.5)
				then
					stats.upgrades += 1
					say(("%s upgrade bought for %s"):format(c.id, fmt(c.price)), true, "up")
				else
					backoff[c.id] = os.clock() + UPGRADE_BACKOFF
					log(c.id, "upgrade was not taken; last note:", lastNote)
				end
			end
		end)
		if not good then
			warn("[strengtheggs] upgrade pass failed:", err)
		end
		task.wait(UPGRADE_EVERY)
	end
end
local function setUpgrade(on)
	genUpgrade += 1
	if on then
		task.spawn(upgradeLoop, genUpgrade)
	end
end

-- dumbells ---------------------------------------------------------------------------------------------------------------
local genDumbell = 0
local dumbBackoff = {}
local function dumbellLoop(mine)
	while genDumbell == mine do
		local good, err = pcall(function()
			local d = data()
			local cash = tonumber(d.Cash) or 0
			local have = {}
			for _, id in ipairs(d.UnlockedDumbells or {}) do
				have[id] = true
			end
			-- the best affordable, not the next in order: the server took Dumbell_3 while Dumbell_5 and _7 were owned
			local pick, ps
			for id, e in pairs(Lib.Database.Dumbells) do
				if
					not have[id]
					and not e.Exclusive
					and not e.RobuxOnly
					and e.Price
					and e.Price > 0
					and cash >= e.Price
					and (dumbBackoff[id] or 0) < os.clock()
					and (not ps or (e.Strength or 0) > ps)
				then
					pick, ps = id, e.Strength or 0
				end
			end
			if pick then
				pcall(function()
					R("Buy Dumbell"):FireServer(pick)
				end)
				if
					waitFor(function()
						return table.find(data().UnlockedDumbells or {}, pick) ~= nil
					end, 2)
				then
					stats.dumbells += 1
					say(("bought %s"):format(Lib.Database.Dumbells[pick].Name), false, "dumb")
				else
					dumbBackoff[pick] = os.clock() + UPGRADE_BACKOFF
				end
			end
			-- equip the strongest owned (the Ancient Dumbell counts through its multiplier)
			d = data()
			local best, bs
			for _, id in ipairs(d.UnlockedDumbells or {}) do
				if Lib.Database.Dumbells[id] and not Lib.Database.Dumbells[id].RobuxOnly then
					local s = Lib.Shared.getDumbellStrength(d, id)
					if not bs or s > bs then
						best, bs = id, s
					end
				end
			end
			if best and d.EquippedDumbell ~= best then
				pcall(function()
					R("Equip Dumbell"):FireServer(best)
				end)
			end
		end)
		if not good then
			warn("[strengtheggs] dumbell pass failed:", err)
		end
		task.wait(DUMBELL_EVERY)
	end
end
local function setDumbell(on)
	genDumbell += 1
	if on then
		task.spawn(dumbellLoop, genDumbell)
	end
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "+1 Strength for Eggs", size = UDim2.fromOffset(560, 470), statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "egg")
local Farm = Tab:AddLeftGroupbox("Eggs", "egg")
local Crys = Tab:AddLeftGroupbox("Crystals", "gem")
local Base = Tab:AddRightGroupbox("Base", "layout-grid")
local Grow = Tab:AddRightGroupbox("Strength", "dumbbell")

local rarDefault = {}
for _, r in ipairs(eggRarities) do
	if rarityRank(r) >= MIN_RARITY_DEFAULT then
		rarDefault[#rarDefault + 1] = r
		rarOn[r] = true -- Default does not fire the callback, so arm by hand
	end
end
for _, z in ipairs(ZONES) do
	zoneOn[z] = true
end
for _, id in ipairs({ "Farm", "Carry", "Speed" }) do
	upgOn[id] = true
end

local function safeToggle(toggle, ok)
	if not ok then
		pcall(function()
			toggle:SetValue(false)
		end)
	end
end

Farm:AddToggle("Farm", {
	Text = "Auto Farm Eggs",
	Tooltip = "Pins to the wall, breaks it, pins to the egg, presses it, banks at home. Best rarity first among the ticked zones whose wall is quick enough",
	Default = false,
	Callback = setFarm,
})
Farm:AddDropdown("Rarities", {
	Text = "Rarities to steal",
	Tooltip = "Egg rarities worth a trip. Rare and up start ticked",
	Values = eggRarities,
	Default = rarDefault,
	Multi = true,
	Callback = function(picked)
		table.clear(rarOn)
		for name in pairs(ticked(picked)) do
			rarOn[name] = true
		end
	end,
})
Farm:AddDropdown("Zones", {
	Text = "Zones",
	Tooltip = "Eggs of a zone only count when its wall is open to you: a ticked zone with a huge wall is left alone until your strength catches up (see Max wall seconds)",
	Values = ZONES,
	Default = ZONES,
	Multi = true,
	Callback = function(picked)
		table.clear(zoneOn)
		for name in pairs(ticked(picked)) do
			zoneOn[name] = true
		end
	end,
})
Farm:AddInput("MaxWall", {
	Text = "Max wall seconds",
	Tooltip = "A zone whose wall needs longer than this to break at your strength is skipped. Each trip rebreaks its wall because the bank resets access",
	Default = tostring(MAX_WALL_SEC),
	Numeric = true,
	Finished = true,
	Placeholder = "20",
	Callback = function(v)
		local n = tonumber(v)
		maxWall = (n and n > 0) and n or MAX_WALL_SEC
	end,
})
Farm:AddToggle("FreezeCam", {
	Text = "Freeze camera during trips",
	Tooltip = "The server pulls you back home several times a second while a trip has you pinned elsewhere. This keeps the view on your plot instead of showing every jump",
	Default = true,
	Callback = function(state)
		freezeCam = state
		if not state then
			unlockCamera()
		end
	end,
})
Farm:AddToggle("PreferMut", {
	Text = "Prefer mutated eggs",
	Tooltip = "Among eggs of the same rarity, a mutated one (Golden, Diamond, event mutations) goes first",
	Default = true,
	Callback = function(state)
		preferMut = state
	end,
})
local crystalToggle
crystalToggle = Crys:AddToggle("Crystal", {
	Text = "Auto Snipe Crystals",
	Tooltip = "When a crystal spawns anywhere, goes straight there, takes it and comes back. Claims the Ancient Dumbell at nine. Takes priority over the egg farm",
	Default = false,
	Callback = function(state)
		safeToggle(crystalToggle, setCrystal(state))
	end,
})
Base:AddToggle("Place", {
	Text = "Auto Place Egg",
	Tooltip = "Puts eggs from your inventory on free ground of your plot, best rarity first, while there are free slots",
	Default = false,
	Callback = setPlace,
})
Base:AddToggle("Hatch", {
	Text = "Auto Hatch Egg",
	Tooltip = "Opens each egg the moment its timer is up (earlier is refused). The reveal animation is muted and acked at once",
	Default = false,
	Callback = setHatch,
})
Base:AddToggle("Equip", {
	Text = "Auto Equip Best",
	Tooltip = "Presses the game's Equip Best whenever your friend count changes",
	Default = false,
	Callback = setEquip,
})
Base:AddToggle("Sell", {
	Text = "Auto Sell Friends",
	Tooltip = "Sells hatched friends of the rarities ticked below from your inventory, one at a time. Placed friends are never touched",
	Default = false,
	Callback = setSell,
})
Base:AddDropdown("SellRarity", {
	Text = "Rarities to sell",
	Tooltip = "Nothing is ticked to start with",
	Values = friendRarities,
	Default = {},
	Multi = true,
	Callback = function(picked)
		table.clear(sellOn)
		for name in pairs(ticked(picked)) do
			sellOn[name] = true
		end
	end,
})
Grow:AddToggle("Train", {
	Text = "Auto Train",
	Tooltip = "Activates your dumbell every 0.62s. Pauses by itself while a trip has the character and while you carry an egg",
	Default = false,
	Callback = setTrain,
})
Grow:AddToggle("Dumbells", {
	Text = "Auto Buy Dumbells",
	Tooltip = "Buys the best dumbell you can afford and equips the strongest you own",
	Default = false,
	Callback = setDumbell,
})
Grow:AddToggle("Upgrade", {
	Text = "Auto Upgrade",
	Tooltip = "Cheapest affordable of the ticked upgrades. Robux routes are never touched",
	Default = false,
	Callback = setUpgrade,
})
Grow:AddDropdown("Upgrades", {
	Text = "Upgrades to buy",
	Tooltip = "Farm = plot level (+2 slots), Carry = eggs per trip, Speed = walk speed",
	Values = { "Farm", "Carry", "Speed" },
	Default = { "Farm", "Carry", "Speed" },
	Multi = true,
	Callback = function(picked)
		table.clear(upgOn)
		for name in pairs(ticked(picked)) do
			upgOn[name] = true
		end
	end,
})

-- the strip text is built on a plain thread (it reads game modules); a Heartbeat only copies it across
local strip, note, upNote = nil, "idle", ""
local stripAlive = true
task.spawn(function()
	while stripAlive do
		local d = data()
		local slots = Lib.Shared.getPlotSlots(d.BaseLevel)
		local lines = {
			{ "Cash", fmt(d.Cash) },
			{ "Strength", fmt(d.Strength) },
			{ "Stolen", stats.stolen },
			{ "Plot", ("%d/%d"):format(count(d.PlotFriends), slots) },
			{ "Hatched", stats.hatched },
			{ "Sold", stats.sold },
		}
		if crystalWatch then
			lines[#lines + 1] = { "Crystals", ("%d/%d"):format(#crystalsFound(), CRYSTAL_TOTAL) }
		end
		if upNote ~= "" then
			lines[#lines + 1] = { "Bought", upNote }
		end
		lines[#lines + 1] = { "Now", note }
		strip = lines
		task.wait(0.5)
	end
end)
local nextStrip = 0
table.insert(
	conns,
	RunService.Heartbeat:Connect(function()
		if pending.now then
			note, pending.now = pending.now, nil
		end
		if pending.up then
			upNote, pending.up = pending.up, nil
		end
		if pending.dumb then
			upNote, pending.dumb = pending.dumb, nil
		end
		local now = os.clock()
		if camSaved and not busy and now - camBusyEnd > 1 then
			unlockCamera()
		end
		if now < nextStrip or not strip then
			return
		end
		nextStrip = now + 0.5
		Window:SetStatus(strip)
	end)
)

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("StrengthForEggs", {})

local VirtualUser = game:GetService("VirtualUser")
table.insert(
	conns,
	player.Idled:Connect(function()
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end)
)

-- close ----------------------------------------------------------------------
local function stopAll()
	setFarm(false)
	setCrystal(false)
	setPlace(false)
	setHatch(false) -- hands the hatch animation back
	setEquip(false)
	setSell(false)
	setTrain(false)
	setUpgrade(false)
	setDumbell(false)
	stripAlive = false
	unpin()
	unlockCamera()
	pinCon:Disconnect()
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
	pcall(function()
		if holding() then
			bankHome(invN())
		end
	end)
end

Library:OnUnload(function()
	stopAll()
	getgenv().strengthEggsStop = nil
end)

getgenv().strengthEggsStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().strengthEggsStop = nil
end

log("ready: tick what you want, the status strip names what each loop is doing")
