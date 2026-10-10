--[[ Clone for Eggs -- steal, place, hatch, equip, clones, train, upgrade (76943966208523)

     STEAL   : the egg thief. Picks the best egg on any base that you ticked (EggsConfig tier, rarest first),
               teleports next to it, takes it with PickupEgg, and teleports straight into the spawn volume,
               which banks it into your bag. About 1-3s per egg, the boss never gets to chase you. Probed:
               the pickup is refused from afar and accepted from 2 studs; the bank is instant in the spawn.
               Ranking: egg tier first, then the base's mutation (Rainbow 2x ... Normal 1x), with a dropdown to
               skip mutations you do not want. UNPROVEN: that the base's Mutation attribute is the egg's; the
               first 3 steals print "mutation check" comparing it with the bag entry.
     PLACE   : puts the best egg in your bag on free ground of your plot, up to the plot's egg cap. Works from
               anywhere (probed from 124 studs). Off = eggs just stay in the bag.
     HATCH   : HatchEgg the moment a placed egg's timer is up. Tries it from where you stand; if the server
               refuses that twice it walks to each egg instead.   UNPROVEN either way, F9 prints the first outcome.
     EQUIP   : the game's own Equip Best, when your animal count changes (5s server cooldown).
     CLONES  : sends your clones to a zone (or the game's own "best area"), re-asserted on a slow beat. The
               game's controller walks them and does the handshakes. Restores your old target when switched off.
                                                                                          UNPROVEN: SetTarget reply
     TRAIN   : raw StartTraining. Probed: runs from anywhere, does not pin you, and keeps running through the
               teleports of Steal (Speed kept rising), so Steal never has to pause it. Restarts if Speed stalls.
     UPGRADE : cheapest affordable of the ticked upgrades (clones, base, carry), cash prices from UpgradeConfig.
     TREADMILL: buys the best treadmill you can afford (cash only) and equips it.
                                                                    UNPROVEN: that the tool changes the raw train rate

     MUTE BOSS: the game's AreaController runs each boss chase on YOUR client (BossConfig speed vs your MovementSpeed,
               x2.5 when you are slower) and reports the catch with BossCaught. A Cave boss (Balrog King, 410) out-runs
               you, so its simulated chase sometimes touches you before the egg banks ("It took its egg back"). The toggle
               mutes that listener while on. UNPROVEN: that the server has no catch fallback of its own.

     Learned live: with Auto Clone Farm on, a manual pickup on a base one of your clones is walking to was refused
     again and again; with clones off Steal ran clean. Steal now skips clone-targeted bases (still to confirm with both on).

     Probed and dead (do not re-probe):
       PickupEgg from far away   refused (reply false) at 5000 studs, accepted 2 studs from the egg
       Index claim               no remote exists
     Not wired (Robux): SetAutoHatch (gamepass), InitSkip, speed / slot tiers, passRequired treadmills, Gifting.
     Not wired (not asked): rebirth, selling, daily / free / quest / playtime claims, carrying more than one egg.

     RightControl opens / closes the panel. Stop: getgenv().cloneEggsStop() ]]

-- config ---------------------------------------------------------------------
local SETTLE_START = 0.25 -- after teleporting next to an egg, wait this long before PickupEgg. Adapts: a refusal that a retry fixes raises it
local SETTLE_MIN = 0.2 -- ...and a clean run lowers it toward this. Probed: 0.05s was refused, 0.15s accepted
local ZONE_STRIKES = 3 -- this many refusals in a row in one zone and that zone is parked (Cave eggs were refused in the probe, the other zones were not)
local CHASE_MAX = 20 -- a chase whose Ended event never arrived stops blocking its base after this long
local BASE_BENCH = 8 -- after a refusal the whole base is left alone this long: its boss may be busy with a clone, and the next-best egg is usually on the same base
local ZONE_PARK = 300 -- ...for this long, then it gets another two tries
local SETTLE_MAX = 0.6 -- the cap. Raise if pickups keep being refused right after the teleport
local STREAM_WAIT = 1.5 -- after teleporting to a hen, wait this long for its parts to stream in before aiming at it. Raise if refusals show "parts streamed false"
local BANK_WAIT = 4 --the stolen egg must show up in the bag inside this after the teleport to the spawn
local STEAL_GAP = 0.1 -- between steals
local STEAL_FAILS = 6 -- this many refusals in a row and stealing pauses for STEAL_PAUSE
local STEAL_PAUSE = 10
local HEN_BENCH = 120 -- an egg we took, or the server refused, is not tried again for this long. 30 was too short: the emptied hens came back off the bench and were refused, which parked the whole zone
local HEN_BENCH_MAX = 600 -- ...a hen refused again and again doubles its wait up to this
local TAKEN_BENCH = 5 -- an egg another player just took (EggTaken) is skipped for this long
local BAG_MAX = 100 -- stealing pauses at this many eggs in the bag (the box in the panel changes it)
local PLACE_GAP = 0.3 -- between PlaceEgg calls
local PLACE_CONFIRM = 1.5 -- a placed egg must leave the bag inside this
local SPOT_STEP = 5 -- studs between candidate egg spots on the plot
local SPOT_CLEAR = 5 -- keep this far from every egg already placed
local SPOT_INSET = 6 -- keep spots this far from the plot floor's edge
local SPOT_BENCH = 30 -- a spot the server refused is not tried again for this long
local HATCH_GAP = 0.15 -- between HatchEgg calls
local HATCH_CONFIRM = 2 -- a hatched egg must flag IsHatching or vanish inside this
local HATCH_RAW_FAILS = 2 -- this many unconfirmed raw hatches in a row and it switches to walking to the eggs
local EQUIP_GAP = 5.5 -- the server refuses Equip Best inside 5s
local EQUIP_EVERY = 45 -- press anyway this often, in case a change was missed
local CLONE_EVERY = 3 -- how often the clone target is checked and re-asserted
local UPGRADE_EVERY = 2
local UPGRADE_BACKOFF = 10 -- a purchase the server did not take is not retried for this long
local TRAIN_STALL = 6 -- Speed has not risen for this long: restart training
local CALL_TIMEOUT = 6 -- InvokeServer has no timeout of its own
local AUTO_BEST = "Auto best (game's own)"

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Stats = game:GetService("Stats")
local player = Players.LocalPlayer

if getgenv and getgenv().cloneEggsStop then
	getgenv().cloneEggsStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[cloneeggs]", ...)
end

-- The panel strip is drained from a Heartbeat, which the engine calls with our own identity.
-- A loop thread that writes to the window directly throws "lacking capability Plugin" after
-- its first task.wait.
local pending, lastSaid = {}, {}
local function say(slot, msg, quiet)
	pending[slot] = msg
	if not quiet and msg ~= lastSaid[slot] then
		lastSaid[slot] = msg
		log(slot .. ":", msg)
	end
end

-- game -----------------------------------------------------------------------
local Services
do
	local idx = ReplicatedStorage:WaitForChild("Packages", 15) and ReplicatedStorage.Packages:WaitForChild("_Index", 15)
	for _, c in ipairs(idx and idx:GetChildren() or {}) do
		if c.Name:lower():find("knit") and c:FindFirstChild("knit") and c.knit:FindFirstChild("Services") then
			Services = c.knit.Services -- by shape: the versioned folder name changes on a dependency bump
		end
	end
end
local ok, EggsConfig, UpgradeConfig, AreasConfig, TrainToolConfig, TutorialConfig, Modifiers = pcall(function()
	local C = ReplicatedStorage.Configs
	return require(C.EggsConfig),
		require(C.UpgradeConfig),
		require(C.AreasConfig),
		require(C.TrainToolConfig),
		require(C.TutorialConfig),
		require(ReplicatedStorage.Modifiers)
end)
local EggUtils, MutationConfig
pcall(function()
	EggUtils = require(ReplicatedStorage.GameShared.EggUtils)
end)
pcall(function()
	MutationConfig = require(ReplicatedStorage.Configs.MutationConfig)
end)
-- mutation ids, best income first (NORMAL last); the base roll is server-side, we can only choose bases
local MUT_ORDER = {}
for id in pairs(MutationConfig or {}) do
	MUT_ORDER[#MUT_ORDER + 1] = id
end
table.sort(MUT_ORDER, function(a, b)
	return MutationConfig[a].cashMulti > MutationConfig[b].cashMulti
end)
local function mutMulti(id)
	local m = MutationConfig and MutationConfig[id]
	return m and m.cashMulti or 1
end
if not Services or not ok then
	warn("[cloneeggs] the game's services or modules did not load:", Services, EggsConfig)
	return
end
local EGGS = EggsConfig.EGGS
local zoneOfEgg = {} -- egg id -> zone id, from the zones' own drop lists
for zid, z in pairs(AreasConfig.AREAS) do
	for _, e in ipairs(z.eggs or {}) do
		zoneOfEgg[e.id] = zid
	end
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

-- InvokeServer with a clock: a handler that errors or never returns would park the loop forever.
-- Returns replied (no error, inside CALL_TIMEOUT), then the reply values.
local remoteCache = {}
local function remote(svc, name)
	local key = svc .. "." .. name
	local r = remoteCache[key]
	if not (r and r.Parent) then
		local s = Services:FindFirstChild(svc)
		local f = s and s:FindFirstChild("RF")
		r = f and f:FindFirstChild(name)
		remoteCache[key] = r
	end
	return r
end
local function invoke(svc, name, ...)
	local r = remote(svc, name)
	if not (r and r:IsA("RemoteFunction")) then
		return false
	end
	local args, done, out = table.pack(...), false, nil
	task.spawn(function()
		out = table.pack(pcall(r.InvokeServer, r, table.unpack(args, 1, args.n)))
		done = true
	end)
	local deadline = os.clock() + CALL_TIMEOUT
	while not done and os.clock() < deadline do
		task.wait()
	end
	if not done or not out[1] then
		return false
	end
	return true, out[2], out[3]
end

local function controller(name)
	local okK, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
	if not okK then
		return nil
	end
	local okC, c = pcall(Knit.GetController, name)
	return okC and c or nil
end
local replica
local function D()
	if replica and replica.Data then
		return replica.Data
	end
	local rc = controller("ReplicaController")
	if rc then
		local okR, r = pcall(rc.GetReplica, rc)
		if okR then
			replica = r
		end
	end
	return replica and replica.Data or {}
end
local function cash()
	return (D().Currencies or {}).Cash or 0
end

local function waitFor(fn, timeout)
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		if fn() then
			return true
		end
		task.wait(0.05)
	end
	return fn() and true or false
end

-- character and claim --------------------------------------------------------
-- One thing at a time may drive the character. Returns whether fn RAN; released on every path.
local busy = false
local function claim(fn)
	if busy then
		return false
	end
	busy = true
	local okc, err = pcall(fn)
	busy = false
	if not okc then
		warn("[cloneeggs]", err)
	end
	return true
end
local function tp(cf)
	local c = player.Character
	if c and c:FindFirstChild("HumanoidRootPart") then
		c:PivotTo(cf)
		return true
	end
	return false
end
local ping = Stats.Network.ServerStatsItem["Data Ping"]
local function pingSec()
	local okp, v = pcall(function()
		return ping:GetValue()
	end)
	return okp and v / 1000 or 0.1
end

-- plot and bag ---------------------------------------------------------------
local function myPlot()
	local plots = workspace:FindFirstChild("Plots")
	for _, p in ipairs(plots and plots:GetChildren() or {}) do
		if p:GetAttribute("Owner") == player.UserId then
			return p
		end
	end
end
local function plotSurface()
	local p = myPlot()
	return p and p:FindFirstChild("PlotSurface", true)
end
local function placedEggs()
	local o = {}
	for _, e in ipairs(CollectionService:GetTagged("PlacedEgg")) do
		if e:GetAttribute("OwnerId") == player.UserId and e.Parent then
			o[#o + 1] = e
		end
	end
	return o
end
local function bagEggs() -- [entityId] = entry
	local o = {}
	for id, e in pairs(D().Inventory or {}) do
		if type(e) == "table" and e.itemType == "Egg" then
			o[id] = e
		end
	end
	return o
end
local function tierOf(eggType)
	local e = EGGS[eggType]
	return e and e.tier or 0
end
local function spawnPart()
	local sd = workspace:FindFirstChild("SpawnDetector")
	return sd and sd:IsA("BasePart") and sd or nil
end
local function insideBox(part, pos)
	local l, half = part.CFrame:PointToObjectSpace(pos), part.Size / 2
	return math.abs(l.X) <= half.X and math.abs(l.Y) <= half.Y and math.abs(l.Z) <= half.Z
end
-- Standing on the middle of your plot floor (3 studs up = hip height), or nil without a plot.
local function plotGround()
	local surf = plotSurface()
	return surf and CFrame.new(surf.CFrame:PointToWorldSpace(Vector3.new(0, surf.Size.Y / 2 + 3, 0)))
end
-- Where to stand to bank an egg: the plot floor when it lies inside the spawn volume (one hop, on the
-- ground), else the volume's centre (which hangs in the air; the caller walks you to the plot after).
local groundBank, refusalLogs = true, 0 -- groundBank goes false the first time the plot floor fails to bank
local function carriedEggs()
	local c, n = player.Character, 0
	for _, x in ipairs(c and c:GetChildren() or {}) do
		if x:HasTag("CarriedEgg") or x:HasTag("Pickable") then
			n += 1
		end
	end
	return n
end
local function bankCF(sp)
	local g = plotGround()
	if groundBank and g and insideBox(sp, g.Position) then
		return g, true
	end
	return sp.CFrame, false
end

-- stats and benches ----------------------------------------------------------
local stats = { stolen = 0, placed = 0, hatched = 0, bought = 0, equips = 0, refused = 0 }
local eggOn, upOn, mutOn = {}, {}, {}
local bagMax = BAG_MAX
local zone = AUTO_BEST
local benchUntil = {} -- key -> os.clock() deadline: hens and plot spots the server refused
local function benched(key)
	local t = benchUntil[key]
	if t and t > os.clock() then
		return true
	end
	benchUntil[key] = nil
	return false
end
local function bench(key, secs)
	benchUntil[key] = os.clock() + secs
end

-- loops: one generation counter per toggle --------------------------------------
-- set(state) returns false when start() refused, so the caller can flip the switch back.
local function newLoop(body, gap)
	local self = { on = false, gen = 0 }
	function self.set(state)
		self.gen += 1
		local mine = self.gen
		self.on = state
		if not state then
			if self.stop then
				task.spawn(self.stop)
			end
			return true
		end
		if self.start then
			local okS, why = self.start()
			if okS == false then
				self.on = false
				if why then
					log(why)
				end
				return false
			end
		end
		task.spawn(function()
			local function alive()
				return self.on and self.gen == mine
			end
			while alive() do
				local okB, err = pcall(body, alive)
				if not okB then
					warn("[cloneeggs]", err)
					task.wait(2)
				end
				task.wait(type(gap) == "function" and gap() or gap)
			end
		end)
		return true
	end
	return self
end

-- steal ----------------------------------------------------------------------
local settle = SETTLE_START
local stealFails, stealPausedUntil = 0, 0
local zoneStrikes, zoneParked = {}, {} -- refusals in a row per zone / when its park ends
local mutChecks, mutChecksOdd = 0, 0
local chasing = {} -- base id -> deadline while its boss is chasing someone (BossChaseStarted .. Ended)
local chaseStartedAt, timingLogs = {}, 0 -- base id -> clock of its last BossChaseStarted; steals timed so far (see the "timing:" line)
-- Bases one of YOUR clones is walking to (CloneController replica, Clones[id].targetBaseId). A manual pickup on
-- such a base was refused over and over for the same whale egg in a live run; UNPROVEN that this is why.
local cloneTargets, cloneTargetsAt = {}, 0
local function cloneTargeted(base)
	local now = os.clock()
	if now - cloneTargetsAt > 0.5 then
		cloneTargetsAt = now
		table.clear(cloneTargets)
		local cc = controller("CloneController")
		local okD, d = pcall(function()
			return cc and cc:GetData()
		end)
		for _, c in pairs(okD and d and d.Clones or {}) do
			if type(c) == "table" and c.targetBaseId then
				cloneTargets[c.targetBaseId] = true
			end
		end
	end
	return cloneTargets[base] == true
end
local henFails = {} -- hen key -> refusals so far; each one doubles its bench
local tookHen, lastSteal = {}, 0 -- hen keys we emptied (a refusal there is a stale hen, not a locked zone) / clock of the last clean steal
-- Live run: emptied hens were refused again 80-110s later while still drawn on the base with their egg, and the
-- server's reply carries no reason. So an emptied hen stays benched until its attributes CHANGE (the game putting a
-- new egg there) instead of until a timer runs out. tookSig: false = baseline not read yet, string = the baseline.
local tookSig, attrLogs = {}, 0
local function attrSig(m)
	local parts = {}
	for k, v in pairs(m:GetAttributes()) do
		parts[#parts + 1] = k .. "=" .. tostring(v)
	end
	table.sort(parts)
	return table.concat(parts, " ")
end
local function isChasing(base)
	return (chasing[base] or 0) > os.clock()
end

local function henKey(base, idx)
	return "hen:" .. tostring(base) .. ":" .. tostring(idx)
end
local function zoneKey(typ)
	return zoneOfEgg[typ] or typ
end
local function zoneIsParked(typ)
	local t = zoneParked[zoneKey(typ)]
	return t ~= nil and t > os.clock()
end
-- The game sets the base's Mutation attribute when it builds the base; the hen is a child of that model.
-- UNPROVEN: the attribute's exact home. The first steal prints what it found.
local function henMutation(h)
	local base = h.Parent
	return (base and base:GetAttribute("Mutation")) or h:GetAttribute("Mutation") or "NORMAL"
end
local function bestHen()
	local best
	for _, h in ipairs(CollectionService:GetTagged("SpawnedBaseEgg")) do
		local typ, base, idx = h:GetAttribute("EggType"), h:GetAttribute("BaseId"), h:GetAttribute("Placeholder")
		local tk = base and idx and tookSig[henKey(base, idx)]
		if tk ~= nil then
			local key, sig = henKey(base, idx), attrSig(h)
			if tk == false then
				tookSig[key] = sig -- first look after the take: this is what an emptied hen looks like
			elseif sig ~= tk then
				log("hen changed since we took it, eligible again:", key, "was", tk, "now", sig)
				tookSig[key], tookHen[key], henFails[key] = nil, nil, 0
				benchUntil[key] = nil
			end
		end
		if typ and base and idx and eggOn[typ] and h:IsDescendantOf(workspace) and not h:GetAttribute("EggHidden") and not benched(henKey(base, idx)) and not benched("base:" .. tostring(base)) and not isChasing(base) and not cloneTargeted(base) and not zoneIsParked(typ) then
			local mut = henMutation(h)
			if mutOn[mut] or not (MutationConfig and MutationConfig[mut]) then -- a mutation the dropdown does not know is stolen, not skipped
				local tier, multi = tierOf(typ), mutMulti(mut)
				-- tier first (a tier step is worth far more than 2x), mutation breaks ties within a tier
				if not best or tier > best.tier or (tier == best.tier and multi > best.multi) then
					best = { m = h, base = base, idx = idx, typ = typ, tier = tier, mut = mut, multi = multi }
				end
			end
		end
	end
	return best
end

local function distTo(m) -- studs from your root to the model's pivot, for the refusal log
	local c = player.Character
	local r = c and c:FindFirstChild("HumanoidRootPart")
	return r and math.floor((r.Position - m:GetPivot().Position).Magnitude) or "?"
end

-- The hop into the spawn can be undone by the server, which leaves you beside the boss: "You were too slow to escape
-- <boss>! It took its egg back." Timing showed the hop itself takes ~0ms and the chase starts at the pickup, so the
-- only intermittent thing left is the hop not sticking. Called from every wait while banking: puts you back within a poll.
local pinLogs = 0
local function holdSpot(cf)
	local c = player.Character
	local r = c and c:FindFirstChild("HumanoidRootPart")
	local off = r and (r.Position - cf.Position).Magnitude
	if off and off > 8 then
		if pinLogs < 6 then
			pinLogs += 1
			log(("the hop into the spawn did not stick (%d studs off), putting you back"):format(off))
		end
		tp(cf)
	end
end

-- PROBE: the first steal after an idle stretch loses its egg ("took its egg back") while the ones chained after it bank,
-- with identical timing. This prints the state at the moment the bag is checked, for the first 3 banked steals and the
-- first 6 lost ones, so the two can be compared. Remove once the cause is known.
local snapOk, snapBad = 0, 0
-- PROBE: every server->client event around a steal on one clock, printed with the bank probe. Mute was ON and a Cave
-- egg was still taken back, so either the controller is not really muted or the server decides on its own.
local traceBuf, traceT0 = {}, 0
local function trace(msg)
	if #traceBuf < 40 and os.clock() - traceT0 < 8 then
		traceBuf[#traceBuf + 1] = ("+%dms %s"):format((os.clock() - traceT0) * 1000, msg)
	end
end
local function brief(...)
	local parts = {}
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		parts[i] = type(v) == "table" and "table" or tostring(v)
	end
	return table.concat(parts, ", ")
end
local function bankSnap(sp, bankAt, onGround, idle)
	local c = player.Character
	local r = c and c:FindFirstChild("HumanoidRootPart")
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	return ("Speed stat %s, WalkSpeed %s, inside spawn volume %s, %s studs from the bank spot, onGround %s, carried %d, idle before %ss, humanoid %s, velocity %s, player attrs [%s]"):format(
		fmt(D().Speed or 0),
		hum and tostring(hum.WalkSpeed) or "?",
		tostring(r and insideBox(sp, r.Position)),
		r and tostring(math.floor((r.Position - bankAt.Position).Magnitude)) or "?",
		tostring(onGround),
		carriedEggs(),
		tostring(idle),
		hum and hum:GetState().Name or "?",
		r and tostring(math.floor(r.AssemblyLinearVelocity.Magnitude)) or "?",
		attrSig(player)
	)
end

-- boss chase -----------------------------------------------------------------
-- The game's AreaController runs every boss chase as a CLIENT simulation: the boss walks at BossConfig.GetChaseSpeed
-- (a boss faster than your MovementSpeed runs 2.5x) and when it touches you the client REPORTS it with BossCaught. A
-- Cave boss (Balrog King, 410) beats your speed, so its simulated chase sometimes touches you before the server banks
-- the egg: "You were too slow to escape ... It took its egg back". Muting AreaController's BossChaseStarted listener
-- means the boss never chases, so nothing is ever reported. UNPROVEN: that the server has no fallback of its own.
-- Restored from stopAll; a boss never started from here stays asleep on screen, nothing else changes.
local mutedChase = {}
local function setBossMute(on)
	if not on then
		for _, c in ipairs(mutedChase) do
			pcall(function()
				c:Enable()
			end)
		end
		table.clear(mutedChase)
		return true
	end
	local re = Services:FindFirstChild("AreaService") and Services.AreaService:FindFirstChild("RE")
	local ev = re and re:FindFirstChild("BossChaseStarted")
	if not (ev and getconnections) then
		return false, "BossChaseStarted or getconnections is not available here"
	end
	local okG, list = pcall(function()
		return getconnections(ev.OnClientEvent)
	end)
	for _, c in ipairs(okG and list or {}) do
		local okS, scr = pcall(function()
			return getfenv(c.Function).script
		end)
		-- by script name, never "all listeners": ours (below) is on the same event
		if okS and typeof(scr) == "Instance" and scr.Name == "AreaController" and pcall(function()
			c:Disable()
		end) then
			mutedChase[#mutedChase + 1] = c
		end
	end
	if #mutedChase == 0 then
		return false, "the game's AreaController listener was not found"
	end
	return true
end

local function stealOnce()
	local sp = spawnPart()
	local h = bestHen()
	if not sp then
		say("steal", "no SpawnDetector, cannot bank")
		return "stop"
	end
	if not h then
		say("steal", "no ticked egg on any base")
		return "none"
	end
	local before = bagEggs()
	local result = "fail"
	local ran = claim(function()
		local key = henKey(h.base, h.idx)
		local idle = lastSteal > 0 and math.floor(os.clock() - lastSteal) or "never" -- seconds since the previous clean steal
		local pos = h.m:GetPivot().Position
		if carriedEggs() > 0 then
			-- a carried egg that never banked refuses every later pickup (MaxPickup 1): bank it first
			log("still carrying an egg, banking it before the next steal")
			tp(sp.CFrame)
			waitFor(function()
				return carriedEggs() == 0
			end, BANK_WAIT)
		end
		tp(CFrame.new(pos + Vector3.new(0, 3, 0)))
		-- A hen far from you replicates as a bare Model: its pivot is where the importer left it, not where the egg
		-- is, and the pickup is range-checked. Wait for the parts to stream in, then aim again at the real spot.
		local tArrive, tPick, retried = os.clock(), 0, false
		traceT0 = tArrive
		table.clear(traceBuf)
		local gotParts = h.m:FindFirstChildWhichIsA("BasePart", true) ~= nil
		if not gotParts then
			gotParts = waitFor(function()
				return h.m:FindFirstChildWhichIsA("BasePart", true) ~= nil
			end, STREAM_WAIT)
		end
		local real = h.m:GetPivot().Position
		if (real - pos).Magnitude > 3 then
			pos = real
			tp(CFrame.new(pos + Vector3.new(0, 3, 0)))
		end
		task.wait(math.max(settle, pingSec() * 3))
		local replied, got, why = invoke("AreaService", "PickupEgg", h.base, h.idx)
		local clean = replied and got == true
		if not clean then
			-- refused: stale / taken egg, or the server had not seen us arrive yet. Once more, slower.
			retried = true
			task.wait(0.3)
			replied, got, why = invoke("AreaService", "PickupEgg", h.base, h.idx)
			if replied and got == true then
				settle = math.min(SETTLE_MAX, settle + 0.1)
				clean = true
			end
		else
			settle = math.max(SETTLE_MIN, settle * 0.95)
		end
		tPick = os.clock()
		trace("pickup answered, clean = " .. tostring(clean))
		if clean then
			local baseModel = h.m.Parent
			task.delay(1.2, function() -- is the boss actually chasing? the controller turns its highlight on in "Chasing"
				local hl = baseModel and baseModel:FindFirstChild("ChaseHighlight", true)
				trace("boss ChaseHighlight.Enabled = " .. tostring(hl and hl.Enabled))
			end)
		end
		if clean and attrLogs < 3 then
			attrLogs += 1
			log("hen attrs at take:", attrSig(h.m)) -- compare with the refusal line's "hen attrs" to see what an emptied hen looks like
		end
		if not clean and refusalLogs < 8 then
			refusalLogs += 1
			log("pickup refused:", h.typ, "tier", h.tier, h.base, "replied", replied, "got", got, "why", why, "stale hen", tookHen[key] == true, "since last steal", lastSteal > 0 and math.floor(os.clock() - lastSteal) or "never", "parts streamed", gotParts, "dist", distTo(h.m), "hen attrs", attrSig(h.m), "when emptied", tookSig[key], "base chasing", isChasing(h.base), "carried", carriedEggs(), "Chased", player:GetAttribute("Chased"), "settle", settle)
		end
		if not clean then
			bench("base:" .. tostring(h.base), BASE_BENCH)
		end
		local zk = zoneKey(h.typ)
		if clean then
			zoneStrikes[zk] = 0
			tookHen[key] = true
			tookSig[key] = false
			lastSteal = os.clock()
		elseif tookHen[key] then
			-- a hen we already emptied refuses by definition: bench it (below), do not blame the zone
		else
			zoneStrikes[zk] = (zoneStrikes[zk] or 0) + 1
			if zoneStrikes[zk] >= ZONE_STRIKES then
				zoneStrikes[zk] = 0
				zoneParked[zk] = os.clock() + ZONE_PARK
				log(("%s refused %d in a row, skipping it for %ds"):format(zk, ZONE_STRIKES, ZONE_PARK))
				say("steal", ("%s refused, skipped for %dm"):format(zk, ZONE_PARK // 60))
			end
		end
		-- ours now, or not takeable: either way not this one again. A hen that keeps refusing waits longer each time.
		henFails[key] = clean and 0 or (henFails[key] or 0) + 1
		bench(key, clean and HEN_BENCH or math.min(HEN_BENCH_MAX, HEN_BENCH * 2 ^ (henFails[key] - 1)))
		local bankAt, onGround = bankCF(sp)
		tp(bankAt) -- the spawn volume is what banks it; do not stay by the boss
		if clean and timingLogs < 8 then
			-- "You were too slow to escape <boss>! It took its egg back." is a clock somewhere; this says which leg eats it
			timingLogs += 1
			local cs = chaseStartedAt[h.base]
			log(("timing: arrive->pickup %dms%s, pickup->in the spawn %dms, boss chase began %s"):format(
				(tPick - tArrive) * 1000, retried and " (after a refused first try)" or "", (os.clock() - tPick) * 1000,
				cs and ("%dms after arrival"):format((cs - tArrive) * 1000) or "no event"))
		end
		if clean and onGround then
			waitFor(function()
				holdSpot(bankAt)
				return carriedEggs() > 0
			end, 0.5) -- let the carried model appear before asking whether it is gone
			if not waitFor(function()
				holdSpot(bankAt)
				return carriedEggs() == 0
			end, 1.5) then
				groundBank = false
				log("the plot floor did not bank the egg, using the spawn volume centre from now on")
				tp(sp.CFrame)
			end
		end
		if clean then
			local gained = waitFor(function()
				holdSpot(bankAt)
				for id in pairs(bagEggs()) do
					if not before[id] then
						return true
					end
				end
				return false
			end, BANK_WAIT)
			if (gained and snapOk < 3) or (not gained and snapBad < 6) then
				if gained then
					snapOk += 1
				else
					snapBad += 1
				end
				log("bank probe " .. (gained and "ok" or "LOST") .. ":", "boss mute listeners", #mutedChase, "|", bankSnap(sp, bankAt, onGround, idle))
				log("events around this steal (ms after arriving):\n" .. table.concat(traceBuf, "\n"))
			end
			if gained then
				result = "ok"
				stats.stolen += 1
				local label = h.mut ~= "NORMAL" and (" " .. h.mut) or ""
				say("steal", ("took %s%s (tier %d)"):format(EGGS[h.typ] and EGGS[h.typ].name or h.typ, label, h.tier))
				local odd = h.mut ~= "NORMAL"
				if (odd and mutChecksOdd < 3) or (not odd and mutChecks < 2) then
					-- The bag entry leaves mutation nil for a Normal egg (probed), so only a mutated one proves the link.
					for id, e in pairs(bagEggs()) do
						if not before[id] then
							if odd then
								mutChecksOdd += 1
							else
								mutChecks += 1
							end
							log("mutation check: base said", h.mut, "- bag egg says", e.innerEntity and e.innerEntity.mutation)
						end
					end
				end
			else
				result = "unbanked"
				say("steal", "took an egg but the bag did not gain it")
				-- the boss put the egg back on its hen: that hen is takeable again, not "emptied by us"
				tookHen[key], tookSig[key], henFails[key] = nil, nil, 0
				bench(key, BASE_BENCH)
			end
		end
		if not onGround then
			local g = plotGround()
			if g then
				tp(g) -- banked from the volume's centre in the air: now go down to your plot
			end
		end
	end)
	return ran and result or "busy"
end

local stealLoop = newLoop(function()
	local now = os.clock()
	if now < stealPausedUntil then
		return
	end
	if count(bagEggs()) >= bagMax then
		say("steal", ("bag full (%d)"):format(bagMax), true)
		return
	end
	local r = stealOnce()
	if r == "ok" then
		stealFails = 0
	elseif r == "none" then
		task.wait(1)
	elseif r == "stop" then
		task.wait(3)
	elseif r == "busy" then
		task.wait(0.3)
	else
		stealFails += 1
		stats.refused += 1
		if stealFails >= STEAL_FAILS then
			stealFails = 0
			stealPausedUntil = os.clock() + STEAL_PAUSE
			say("steal", ("refused %d in a row (bag full? locked?), pausing %ds"):format(STEAL_FAILS, STEAL_PAUSE))
		end
	end
end, STEAL_GAP)
stealLoop.start = function()
	if not spawnPart() then
		return false, "no SpawnDetector in the workspace, cannot bank eggs"
	end
	if not next(D()) then
		return false, "the save mirror is not readable yet"
	end
	stealFails, stealPausedUntil = 0, 0
	return true
end

-- place ----------------------------------------------------------------------
local function eggModelCF(surf, cf, inner)
	if EggUtils and inner then
		local okM, m = pcall(EggUtils.CreateEggModel, inner.eggType, inner.mutation, inner.size)
		if okM and m then
			local okV, v = pcall(EggUtils.GetValidEggCFrame, surf, m, cf)
			m:Destroy()
			if okV and v then
				return v
			end
		end
	end
	return cf
end
-- nearest-to-centre spot on the plot floor that is clear of every placed egg and not benched
local function freeSpot(surf)
	local taken = {}
	for _, e in ipairs(placedEggs()) do
		taken[#taken + 1] = e:GetPivot().Position
	end
	local size = surf.Size
	local best, bestD
	local nx = math.max(1, math.floor((size.X - 2 * SPOT_INSET) / SPOT_STEP))
	local nz = math.max(1, math.floor((size.Z - 2 * SPOT_INSET) / SPOT_STEP))
	for ix = 0, nx do
		for iz = 0, nz do
			local lx = -size.X / 2 + SPOT_INSET + ix * SPOT_STEP
			local lz = -size.Z / 2 + SPOT_INSET + iz * SPOT_STEP
			local world = surf.CFrame:PointToWorldSpace(Vector3.new(lx, size.Y / 2, lz))
			local key = ("spot:%d:%d"):format(ix, iz)
			if not benched(key) then
				local clear = true
				for _, t in ipairs(taken) do
					if (Vector3.new(t.X, 0, t.Z) - Vector3.new(world.X, 0, world.Z)).Magnitude < SPOT_CLEAR then
						clear = false
						break
					end
				end
				local d = Vector3.new(lx, 0, lz).Magnitude
				if clear and (not bestD or d < bestD) then
					best, bestD = { world = world, key = key }, d
				end
			end
		end
	end
	return best
end
local function placeCap()
	local okM, v = pcall(function()
		return Modifiers.Get(player, "MaxEggs")
	end)
	return okM and v or nil
end

local placeLoop = newLoop(function()
	local surf = plotSurface()
	if not surf then
		say("place", "no plot surface found", true)
		return
	end
	local cap = placeCap()
	local placed = #placedEggs()
	if cap and placed >= cap then
		say("place", ("plot full (%d/%d), eggs stay in the bag"):format(placed, cap), true)
		return
	end
	local bestId, bestE, bestTier
	for id, e in pairs(bagEggs()) do
		local t = tierOf(e.innerEntity and e.innerEntity.eggType)
		if not bestTier or t > bestTier then
			bestId, bestE, bestTier = id, e, t
		end
	end
	if not bestId then
		return
	end
	local spot = freeSpot(surf)
	if not spot then
		say("place", "no free spot on the plot", true)
		return
	end
	local cf = eggModelCF(surf, CFrame.new(spot.world) * CFrame.Angles(0, math.pi / 2, 0), bestE.innerEntity)
	local replied, got = invoke("EggService", "PlaceEgg", bestId, cf)
	local landed = replied and got ~= false and waitFor(function()
		return (D().Inventory or {})[bestId] == nil
	end, PLACE_CONFIRM)
	if landed then
		stats.placed += 1
		say("place", ("placed %s"):format(EGGS[bestE.innerEntity.eggType] and EGGS[bestE.innerEntity.eggType].name or "egg"))
	else
		bench(spot.key, SPOT_BENCH)
		say("place", "PlaceEgg refused, spot benched", true)
	end
	task.wait(PLACE_GAP)
end, 0.25)

-- hatch ----------------------------------------------------------------------
local rawHatchFails, hatchNeedsNear, hatchLogged = 0, false, false
local function ready(e)
	return (e:GetAttribute("StartTime") or math.huge) + (e:GetAttribute("Duration") or 0) - workspace:GetServerTimeNow() <= 0
end
local function hatchConfirmed(e)
	return waitFor(function()
		return not e.Parent or e:GetAttribute("IsHatching") == true
	end, HATCH_CONFIRM)
end
local hatchLoop = newLoop(function(alive)
	for _, e in ipairs(placedEggs()) do
		if not alive() then
			return
		end
		local id = e:GetAttribute("EggId")
		if id and ready(e) and not e:GetAttribute("IsHatching") then
			local confirmed
			if hatchNeedsNear then
				-- UNPROVEN branch: the server wants us at the egg
				local ran = claim(function()
					tp(CFrame.new(e:GetPivot().Position + Vector3.new(0, 3, 0)))
					task.wait(math.max(settle, pingSec() * 3))
					invoke("EggService", "HatchEgg", id)
					confirmed = hatchConfirmed(e)
					local g = plotGround()
					local sp = spawnPart()
					if g or sp then
						tp(g or sp.CFrame)
					end
				end)
				if not ran then
					task.wait(0.3)
				end
			else
				invoke("EggService", "HatchEgg", id)
				confirmed = hatchConfirmed(e)
				if confirmed then
					rawHatchFails = 0
				else
					rawHatchFails += 1
					if rawHatchFails >= HATCH_RAW_FAILS then
						hatchNeedsNear = true
						log("hatch from afar was refused " .. rawHatchFails .. "x, walking to the eggs from now on")
					end
				end
			end
			if confirmed then
				stats.hatched += 1
				if not hatchLogged then
					hatchLogged = true
					log("first hatch confirmed", hatchNeedsNear and "(walked to the egg)" or "(raw, from afar)")
				end
			end
			task.wait(HATCH_GAP)
		end
	end
end, 0.5)

-- equip best -----------------------------------------------------------------
local lastEquip, lastSig = 0, nil
local function animalSig()
	local d = D()
	local n = 0
	for _, e in pairs(d.Inventory or {}) do
		if type(e) == "table" and e.itemType ~= "Egg" then
			n += 1
		end
	end
	return n .. ":" .. count(d.PlacedAnimals)
end
local equipLoop = newLoop(function()
	local now = os.clock()
	local sig = animalSig()
	if now - lastEquip < EQUIP_GAP then
		return
	end
	if sig ~= lastSig or now - lastEquip >= EQUIP_EVERY then
		lastSig, lastEquip = sig, now
		local replied = invoke("AnimalService", "EquipBest")
		if replied then
			stats.equips += 1
		end
	end
end, 1)

-- clones ---------------------------------------------------------------------
local cloneOrig
local function cloneData()
	local cc = controller("CloneController")
	if not cc then
		return nil
	end
	local okD, d = pcall(cc.GetData, cc)
	return okD and d or nil
end
local cloneFirst = true
local cloneLoop = newLoop(function()
	local d = cloneData()
	if not d then
		return
	end
	if d.Unlocked == false then
		say("clones", "portal locked (finish the tutorial)", true)
		return
	end
	local want, auto = zone, zone == AUTO_BEST
	local ok1 = auto and d.AutoTarget == true or (not auto and d.AutoTarget ~= true and d.Target == want)
	if ok1 then
		say("clones", auto and "auto best area" or ("zone " .. want), true)
		return
	end
	local a, b
	if auto then
		a, b = invoke("CloneService", "SetAutoTarget", true)
	else
		invoke("CloneService", "SetAutoTarget", false)
		a, b = invoke("CloneService", "SetTarget", want)
	end
	if cloneFirst then
		cloneFirst = false
		log("first clone call outcome (UNPROVEN)", "replied", a, "value", b, "now Target", (cloneData() or {}).Target, "Auto", (cloneData() or {}).AutoTarget)
	end
end, CLONE_EVERY)
cloneLoop.start = function()
	local d = cloneData()
	if not d then
		return false, "CloneController is not ready"
	end
	cloneOrig = { target = d.Target, auto = d.AutoTarget }
	return true
end
cloneLoop.stop = function()
	local o = cloneOrig
	cloneOrig = nil
	if not o then
		return
	end
	if o.auto then
		invoke("CloneService", "SetAutoTarget", true)
	else
		invoke("CloneService", "SetAutoTarget", false)
		invoke("CloneService", "SetTarget", o.target or "idle")
	end
end

-- train ----------------------------------------------------------------------
local trainSpeed, trainSince = 0, 0
local bonusCon
local function trainStart()
	local replied, got = invoke("TrainingService", "StartTraining")
	trainSpeed, trainSince = D().Speed or 0, os.clock()
	return replied and got ~= false
end
local trainLoop = newLoop(function()
	local speed = D().Speed or 0
	local now = os.clock()
	if speed > trainSpeed then
		trainSpeed, trainSince = speed, now
	elseif now - trainSince > TRAIN_STALL then
		say("train", "Speed stalled, restarting")
		invoke("TrainingService", "StopTraining")
		task.wait(0.8)
		if not trainStart() then
			say("train", "StartTraining refused")
		end
	end
end, 1)
trainLoop.start = function()
	if player:GetAttribute(TutorialConfig.TREADMILL_UNLOCKED_ATTRIBUTE) ~= true then
		return false, "the treadmill is not unlocked yet (tutorial)"
	end
	if not trainStart() then
		return false, "StartTraining was refused"
	end
	local re = Services:FindFirstChild("TrainingService") and Services.TrainingService:FindFirstChild("RE")
	local sb = re and re:FindFirstChild("SpawnBonus")
	if sb and sb:IsA("RemoteEvent") then
		bonusCon = sb.OnClientEvent:Connect(function(id)
			task.spawn(function()
				local replied, got = invoke("TrainingService", "ClaimBonus", id)
				if not trainLoop.bonusLogged then
					trainLoop.bonusLogged = true
					log("first bonus claim (UNPROVEN reply)", replied, got)
				end
			end)
		end)
	end
	return true
end
trainLoop.stop = function()
	if bonusCon then
		bonusCon:Disconnect()
		bonusCon = nil
	end
	invoke("TrainingService", "StopTraining")
end

-- upgrade --------------------------------------------------------------------
local upgradeBench = {}
local upgradeFirst = true
local upgradeLoop = newLoop(function()
	local d = D()
	local c = cash()
	local bestId, bestPrice, bestLvl
	for id in pairs(upOn) do
		if not (upgradeBench[id] and upgradeBench[id] > os.clock()) then
			local lvl = (d.Upgrades or {})[id] or 0
			local okP, price = pcall(UpgradeConfig.GetPrice, id, lvl + 1)
			if okP and type(price) == "number" and price <= c and (not bestPrice or price < bestPrice) then
				bestId, bestPrice, bestLvl = id, price, lvl
			end
		end
	end
	if not bestId then
		return
	end
	local replied, got = invoke("UpgradesService", "Upgrade", bestId, 1)
	local took = replied and waitFor(function()
		return ((D().Upgrades or {})[bestId] or 0) > bestLvl
	end, 1.5)
	if upgradeFirst then
		upgradeFirst = false
		log("first upgrade outcome", bestId, "level", bestLvl, "price", fmt(bestPrice), "replied", replied, "reply", got, "took", took)
	end
	if took then
		stats.bought += 1
		say("upgrade", ("%s -> %d"):format(UpgradeConfig.Upgrades[bestId].name, bestLvl + 1))
	else
		upgradeBench[bestId] = os.clock() + UPGRADE_BACKOFF
	end
end, UPGRADE_EVERY)

-- treadmill ------------------------------------------------------------------
local function ownedTools()
	local set = {}
	for k, v in pairs(D().OwnedTrainTools or {}) do
		if type(v) == "string" then
			set[v] = true
		elseif v then
			set[k] = true
		end
	end
	return set
end
local function toolGain(id)
	local t = TrainToolConfig.TRAIN_TOOLS[id]
	return t and t.gainPerTrain or 0
end
local toolBench, toolFirst = {}, true
local toolLoop = newLoop(function()
	local d = D()
	local owned = ownedTools()
	local rebirth = d.Rebirth or 0
	local c = cash()
	local bestOwned
	for id in pairs(owned) do
		if not bestOwned or toolGain(id) > toolGain(bestOwned) then
			bestOwned = id
		end
	end
	local pick
	for id, t in pairs(TrainToolConfig.TRAIN_TOOLS) do
		-- never the Robux routes: passRequired tools, and anything with no cash price
		if not owned[id] and not t.passRequired and type(t.cost) == "number" and t.cost > 0 and t.cost <= c
			and (not t.rebirthRequired or rebirth >= t.rebirthRequired)
			and t.gainPerTrain > (bestOwned and toolGain(bestOwned) or 0)
			and not (toolBench[id] and toolBench[id] > os.clock())
			and (not pick or t.gainPerTrain > toolGain(pick)) then
			pick = id
		end
	end
	if pick then
		local replied, got = invoke("TrainingService", "BuyTrainTool", pick)
		local took = replied and waitFor(function()
			return ownedTools()[pick]
		end, 1.5)
		if toolFirst then
			toolFirst = false
			log("first treadmill buy (UNPROVEN)", pick, "replied", replied, "reply", got, "owned now", took)
		end
		if took then
			stats.bought += 1
			bestOwned = (not bestOwned or toolGain(pick) > toolGain(bestOwned)) and pick or bestOwned
			say("tool", "bought " .. TrainToolConfig.TRAIN_TOOLS[pick].name)
		else
			toolBench[pick] = os.clock() + UPGRADE_BACKOFF
		end
	end
	if bestOwned and d.EquippedTrainTool ~= bestOwned then
		invoke("TrainingService", "EquipTrainTool", bestOwned)
	end
end, UPGRADE_EVERY)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Clone to Steal Eggs", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "egg")
local Eggs = Tab:AddLeftGroupbox("Eggs", "egg")
local Pets = Tab:AddLeftGroupbox("Animals", "paw-print")
local Farm = Tab:AddRightGroupbox("Clones and training", "footprints")
local Up = Tab:AddRightGroupbox("Upgrades", "trending-up")

-- Value / Default does not fire the callback, so a toggle that is on by default is armed by hand.
local function addToggle(group, idx, text, tip, loop)
	local tg
	tg = group:AddToggle(idx, {
		Text = text,
		Tooltip = tip,
		Default = false,
		Callback = function(state)
			if loop.set(state) == false then
				pcall(function()
					tg:SetValue(false) -- re-enters this callback with false, which is idempotent
				end)
			end
		end,
	})
	return tg
end

-- eggs to steal: rarest first in the list, all ticked to start with
local eggList = {}
for id, cfg in pairs(EGGS) do
	eggList[#eggList + 1] = cfg
	eggOn[id] = true
end
table.sort(eggList, function(a, b)
	return a.tier > b.tier
end)
local eggValues, eggByLabel = {}, {}
for _, cfg in ipairs(eggList) do
	local label = ("%s [%s]"):format(cfg.name, cfg.rarity)
	eggValues[#eggValues + 1] = label
	eggByLabel[label] = cfg.id
end

addToggle(Eggs, "Steal", "Auto Steal Egg", "Teleports to the best ticked egg on any base, takes it and teleports into the spawn volume to bank it. The boss never gets to chase you. Training keeps running", stealLoop)
local muteBoss
muteBoss = Eggs:AddToggle("MuteBoss", {
	Text = "Mute boss chase (experimental)",
	Tooltip = "Stops the game's client from chasing you after a steal, so a boss faster than you (Balrog King in the Cave) cannot take the egg back. On by default: with it on, Cave eggs banked 3 of 3. If the bag stops gaining, turn it off",
	Default = true,
	Callback = function(state)
		local okM, why = setBossMute(state)
		if state and not okM then
			log(why)
			pcall(function()
				muteBoss:SetValue(false) -- re-enters with false, which restores nothing and is idempotent
			end)
		end
	end,
})
-- Default does not fire the callback, so a toggle that starts on is armed by hand
do
	local okM, why = setBossMute(true)
	if okM then
		log("boss chase muted (" .. #mutedChase .. " listener)")
	else
		log("boss chase NOT muted:", why)
		pcall(function()
			muteBoss:SetValue(false)
		end)
	end
end
Eggs:AddDropdown("StealEggs", {
	Text = "Eggs to steal",
	Tooltip = "Rarest first. Untick the cheap ones to leave them to your clones. All are ticked to start with",
	Values = eggValues,
	Default = eggValues,
	Multi = true,
	Callback = function(picked)
		table.clear(eggOn)
		for label in pairs(ticked(picked)) do
			local id = eggByLabel[label]
			if id then
				eggOn[id] = true
			end
		end
	end,
})
Eggs:AddInput("BagMax", {
	Text = "Stop stealing at (eggs in bag)",
	Tooltip = "Stealing pauses when the bag holds this many eggs. Auto Place empties it",
	Default = tostring(BAG_MAX),
	Numeric = true,
	Finished = true,
	Placeholder = tostring(BAG_MAX),
	Callback = function(v)
		local n = tonumber(v)
		bagMax = (n and n >= 1) and math.floor(n) or BAG_MAX -- an empty or 0 box means the default, not "never steal"
	end,
})
if MutationConfig then
	local mutValues, mutByLabel = {}, {}
	for _, id in ipairs(MUT_ORDER) do
		local m = MutationConfig[id]
		local label = ("%s (%gx)"):format(m.name, m.cashMulti)
		mutValues[#mutValues + 1] = label
		mutByLabel[label] = id
		mutOn[id] = true
	end
	Eggs:AddDropdown("StealMutations", {
		Text = "Mutations to steal",
		Tooltip = "Mutation is rolled per base when it spawns and every egg on it shares it. Rarer egg tier always goes first; among eggs of the same tier the better mutation goes first. Untick Normal to take only mutated bases (about 1 in 10, so often nothing to steal)",
		Values = mutValues,
		Default = mutValues,
		Multi = true,
		Callback = function(picked)
			table.clear(mutOn)
			for label in pairs(ticked(picked)) do
				local id = mutByLabel[label]
				if id then
					mutOn[id] = true
				end
			end
		end,
	})
end
addToggle(Eggs, "Place", "Auto Place Egg", "Puts the best egg in your bag on free ground of your plot, up to the plot's egg cap. Off = stolen eggs just stay in the bag", placeLoop)
addToggle(Eggs, "Hatch", "Auto Hatch Egg", "Hatches each placed egg the moment its timer is up. Tries it from where you stand, walks to the egg if the server refuses that", hatchLoop)
addToggle(Pets, "Equip", "Auto Equip Best", "Presses the game's Equip Best when your animal count changes (the server allows one per 5s)", equipLoop)

local zoneValues = { AUTO_BEST }
for _, id in ipairs(AreasConfig.GetOrderedIds()) do
	zoneValues[#zoneValues + 1] = id
end
addToggle(Farm, "Clones", "Auto Clone Farm", "Sends your clones to the zone below and keeps them there. Restores your old target when switched off", cloneLoop)
Farm:AddDropdown("Zone", {
	Text = "Clone zone",
	Tooltip = "The game's own 'best area', or one zone. A zone you have not unlocked is refused by the server",
	Values = zoneValues,
	Default = AUTO_BEST,
	Callback = function(v)
		if type(v) == "string" and v ~= "" then
			zone = v
		end
	end,
})
addToggle(Farm, "Train", "Auto Train", "Runs the treadmill from anywhere and claims the speed bonuses. Keeps running while Auto Steal teleports you around", trainLoop)

local upIds = {}
for id in pairs(UpgradeConfig.Upgrades) do
	upIds[#upIds + 1] = id
end
table.sort(upIds)
local upValues, upByLabel = {}, {}
for _, id in ipairs(upIds) do
	local label = UpgradeConfig.Upgrades[id].name
	upValues[#upValues + 1] = label
	upByLabel[label] = id
	upOn[id] = true
end
addToggle(Up, "Upgrade", "Auto Upgrade", "Buys the cheapest affordable of the ticked upgrades with cash. Robux-only levels are never touched", upgradeLoop)
Up:AddDropdown("UpgradeIds", {
	Text = "Upgrades",
	Tooltip = "Clone count and speed, the clone steal limit, the base, carry. All ticked to start with",
	Values = upValues,
	Default = upValues,
	Multi = true,
	Callback = function(picked)
		table.clear(upOn)
		for label in pairs(ticked(picked)) do
			local id = upByLabel[label]
			if id then
				upOn[id] = true
			end
		end
	end,
})
addToggle(Up, "Treadmill", "Auto Upgrade Treadmill", "Buys the best treadmill you can pay for in cash and equips it. Pass-only and Robux treadmills are skipped", toolLoop)

local conns = {}
local note = { steal = "off", place = "off", clones = "off", train = "off", upgrade = "", tool = "" }
-- The strip text is worked out on a plain thread (it calls into the game's modules, which the
-- Heartbeat callback must not: SetStatus threw "lacking capability Plugin" with that mix) and the
-- Heartbeat only hands the finished rows to the window.
local strip, stripOn = nil, true
task.spawn(function()
	local rateAt, rateSpeed, rate = 0, 0, 0
	while stripOn do
		local okS, err = pcall(function()
			for slot, msg in pairs(pending) do
				note[slot] = msg
				pending[slot] = nil
			end
			local now = os.clock()
			local speed = D().Speed or 0
			if now - rateAt >= 5 then
				rate = rateAt > 0 and (speed - rateSpeed) / (now - rateAt) or 0
				rateAt, rateSpeed = now, speed
			end
			local cap = placeCap()
			local active = {}
			local aw = ReplicatedStorage:FindFirstChild("ActiveWeathers")
			for _, w in ipairs(aw and aw:GetChildren() or {}) do
				active[#active + 1] = w.Name
			end
			strip = {
				{ "Cash", fmt(cash()) },
				{ "Speed", fmt(speed) .. (rate > 0 and (" +" .. fmt(rate) .. "/s") or "") },
				{ "Eggs", ("%d in bag, %d/%s placed"):format(count(bagEggs()), #placedEggs(), cap and tostring(cap) or "?") },
				{ "Stolen", tostring(stats.stolen) .. (stats.refused > 0 and (" (" .. stats.refused .. " refused)") or "") },
				{ "Hatched", tostring(stats.hatched) },
				{ "Bought", tostring(stats.bought) },
				{ "Steal", note.steal },
				{ "Place", note.place },
				{ "Clones", note.clones },
				{ "Event", #active > 0 and table.concat(active, ", ") or "none" },
			}
		end)
		if not okS then
			warn("[cloneeggs] strip:", err)
		end
		task.wait(0.5)
	end
end)
local stripSent, nextStrip = nil, 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	local now = os.clock()
	if strip and strip ~= stripSent and now >= nextStrip then
		stripSent, nextStrip = strip, now + 0.5
		Window:SetStatus(strip)
	end
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("CloneForEggs", {})

local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- the game's own taken-egg notice: skip a hen another player just emptied
do
	local re = Services:FindFirstChild("AreaService") and Services.AreaService:FindFirstChild("RE")
	local function hook(name, fn)
		local ev = re and re:FindFirstChild(name)
		if ev and ev:IsA("RemoteEvent") then
			table.insert(conns, ev.OnClientEvent:Connect(fn))
		end
	end
	hook("EggTaken", function(base, idx)
		bench(henKey(base, idx), TAKEN_BENCH)
	end)
	-- a boss mid-chase (a clone of yours or someone else's) may refuse pickups on its base
	hook("BossChaseStarted", function(base)
		chasing[base] = os.clock() + CHASE_MAX
		chaseStartedAt[base] = os.clock()
	end)
	hook("BossChaseEnded", function(base)
		chasing[base] = nil
	end)
end

-- PROBE: feed the trace from every server->client event of the services that talk about eggs, bosses and notices
for _, svcName in ipairs({ "AreaService", "NotificationService", "SoundService" }) do
	local svc = Services:FindFirstChild(svcName)
	local folder = svc and svc:FindFirstChild("RE")
	for _, ev in ipairs(folder and folder:GetChildren() or {}) do
		if ev:IsA("RemoteEvent") and ev.Name ~= "BaseSpawned" and ev.Name ~= "BaseRemoved" then
			table.insert(conns, ev.OnClientEvent:Connect(function(...)
				trace(svcName .. "." .. ev.Name .. " (" .. brief(...) .. ")")
			end))
		end
	end
end

-- close ----------------------------------------------------------------------
local function stopAll()
	stripOn = false
	setBossMute(false) -- the game's own boss controller must not stay muted after we leave
	for _, l in ipairs({ stealLoop, placeLoop, hatchLoop, equipLoop, cloneLoop, trainLoop, upgradeLoop, toolLoop }) do
		if l.on then
			l.set(false) -- clones restore the old target, training stops
		end
	end
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().cloneEggsStop = nil
end)

getgenv().cloneEggsStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().cloneEggsStop = nil
end
