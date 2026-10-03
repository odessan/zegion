--[[ Break and Steal Eggs -- break eggs, steal the animals, bank them, and the base around it (114326934417838)

     BREAK    : hits the live egg worth the most per second -- its zone's average animal cash over (swings x 0.36s
                + a bank trip) -- among the zones you tick that your pickaxe breaks in at most "Max swings".
                Speed is not checked: ZonesConfig.RequiredPower only drives the game's "recommended speed"
                popups and the guard chase, and the bank is a teleport. Stands beside the egg, pickaxe in hand,
                one hit every 0.36s -- and when another breakable egg is within reach of a spot between them,
                stands there and hits both on every beat (the cooldown is per egg). Waits while you carry
                something, so the bank goes first.
     STEAL    : takes animal pickups of the rarities you tick, richest $/s first, by pressing their prompt from
                where you stand. Anyone may take anyone's hatch (ReservedUserId is only the tutorial's,
                AdminNotes.lua:111). Banks by teleporting home the moment the satchel is full, or when nothing
                else is left to take. Skips one with under 3s to live.
     TITANIC  : every 30 min a Titanic egg (10x HP, 30x luck) lives 10 min in zone 2-5. Goes and hits it, and
                stays while its HP is falling fast enough (yours plus everyone else's hits) to break before it
                expires; otherwise back to Break and a re-check in 60s. Any TITANIC-bracket pickup anywhere --
                the Titanic's or a 1-in-250 normal hatch -- is pressed the moment it appears, retried for 4s,
                and banked. A full satchel is dropped first (DropCarriedRemote) to make room. UNTESTED in play.
     INDEX    : the index's Claim All whenever it says something is Ready.
     EQUIP    : the game's Equip Best after every bank, and every 30s.
     PICKAXE  : buys the strongest pickaxe you can afford (the shop equips it). TRAIL: same for trails.
     TREADMILL: stands on your plot's treadmill whenever Break has had nothing to do for a few seconds.
     SELL     : backpack animals of the rarities you tick, only while every plot slot is full, never one that
                earns more than your weakest placed animal or at least the "keep" box. UNPROVEN, see below.

     Proven by probe: steal by fireproximityprompt from 40 studs (Carrying in 0.3s); bank = PivotTo your plot's
       SpawnPoint (banked 0.5s later, no snap-back, the guard chase does not matter); Index ClaimAll and
       Equip Best from anywhere; the treadmill session starts only when standing on it; two different eggs
       hit in the same frame from their midpoint both take damage (4 of 4 groups, 0 rejected).
     Probed and dead (do not re-probe):
       EggHitRequest from 30 studs        refused 3 of 3 (EggHitRejected); EggConfig.HitRange 8 is enforced
       hits faster than 0.35s             0.35 landed 8/8, 0.25 4/8, 0.15 2/8, 0.05 0/8
       one-frame bursts                   3 -> 0 landed, 6 -> 1: HitBurst 3 is not a free burst
       hits with the pickaxe put away     0 of 3
       treadmill by firetouchinterest     no session from afar
     UNPROVEN (each prints its first outcome to F9): steal from further than 40 studs (falls back to a hop
       beside it), buying a pickaxe / trail more than one tier ahead (falls back to the next one), Sell.
     Some eggs refuse every hit (a Rock Egg did, 11 of 11, probably one another player is breaking): three
       refusals in a row benches that egg for 30s.
     Not wired (Robux): pickaxe / trail DevProductId buys, MergeMachine SkipEgg / SkipAll, FastSwing, DoubleCash.
     Not wired (not asked or unprobed): Merge (irreversible, never probed), treadmill / plot upgrades.
     Not wired (not in the live game): satchel upgrade. SatchelConfig names a "SatchelUpgrade" station tag, but
       no instance carries it, no remote or client code buys it, and every player seen -- one with 11T cash --
       is SatchelTier 1. Check: #game.CollectionService:GetTagged("SatchelUpgrade") > 0 means it shipped.

     RightControl opens / closes the panel. Stop: getgenv().breakStealStop() ]]

-- config ---------------------------------------------------------------------
local HIT_GAP = 0.36 -- between hits. Server HitCooldown is 0.35: 0.35 landed 8/8, 0.25 only 4/8. Raise if refusals pile up
local HIT_STAND = 2.5 -- studs from the egg's shell to stand at. HitRange is 8 from the surface
local CLUSTER_REACH = 6 -- a neighbour egg joins the hit when it is this close (surface) to the shared stand point. Probe 3 landed at 3.7-4.6
local CLUSTER_MAX = 2 -- eggs hit in one frame. 2 is proven (4 of 4 groups); 3 was never found to test -- raise and watch F9 "cluster" lines
local MAX_SWINGS = 60 -- default for the box: an egg needing more hits than this is skipped (60 x 0.36 = 22s)
local REJECT_STRIKES = 3 -- refusals in a row on one egg and it is benched
local BENCH = 30 -- seconds a benched egg or pickup is left alone
local TRIP = 2 -- seconds a steal + bank costs; only used to rank eggs against each other
local STEAL_CONFIRM = 1.2 -- Carrying must show up this soon after a press (0.3s measured)
local STEAL_NEAR = 40 -- a far press is proven up to here; further is tried once, then hopped to if it fails
local STEAL_REACH = 5000 -- MaxActivationDistance the prompt is opened to. Big and finite: math.huge throws
local DESPAWN_MARGIN = 3 -- a pickup with fewer seconds than this to live is not worth the press
local BANK_CONFIRM = 2.5 -- Carrying must clear this long after landing home (0.5s measured)
local TITANIC_RATE_WINDOW = 10 -- seconds of the Titanic's HP history its fall rate is measured over
local TITANIC_RECHECK = 60 -- a Titanic that won't fall in time is looked at again after this
local TITANIC_GRAB = 4 -- a TITANIC pickup is pressed again and again for this long (the prompt may wake late)
local TITANIC_PRESS = 0.25 -- between those presses
local CLAIM_WAIT = 6 -- a loop waits this long for another to let go of the character
local PAUSE_CAP = 3 -- after a hop, wait out GameplayPaused at most this long
local EQUIP_GAP = 2 -- between Equip Best presses
local EQUIP_EVERY = 30 -- press anyway this often
local INDEX_GAP = 2 -- between Claim All presses
local SHOP_EVERY = 2 -- how often the pickaxe / trail shops are looked at
local SHOP_CONFIRM = 2 -- a buy must show up in your owned list this soon
local SHOP_BACKOFF = 15 -- a buy the server did not take is not retried for this long
local TREAD_IDLE = 3 -- Break must have had nothing to do this long before the treadmill takes the character
local TREAD_SLICE = 4 -- the treadmill re-checks whether anything else wants the character this often
local SELL_EVERY = 5
local SELL_TIMEOUT = 5 -- BackpackSellRemote (a RemoteFunction) must answer inside this
local STUCK_WARN = 30 -- the watchdog prints when the character has been held this long by one step

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().breakStealStop then
	getgenv().breakStealStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[breaksteal]", ...)
end

-- The strip is drained from a Heartbeat: a loop thread that writes to the window throws
-- "lacking capability Plugin" after its first task.wait.
local pending, lastSaid = nil, nil
local function say(msg, quiet)
	pending = msg
	if not quiet and msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- game -----------------------------------------------------------------------
local Shared = ReplicatedStorage:WaitForChild("Shared", 15)
local ok, EggRewards, EggRarity, ZonesConfig, PickaxeConfig, TrailsConfig = pcall(function()
	return require(Shared.EggRewards),
		require(Shared.EggRarity),
		require(Shared.ZonesConfig),
		require(Shared.PickaxeConfig),
		require(Shared.TrailsConfig)
end)
if not ok then
	warn("[breaksteal] the game's modules did not load:", EggRewards)
	return
end
local R = {}
for _, name in ipairs({
	"EggHitRequest",
	"EggHitRejected",
	"AnimalBankedRemote",
	"IndexRemote",
	"PetsInventoryRemote",
	"PickaxeShopRequest",
	"TrailShopRequest",
	"TreadmillSessionRemote",
	"BackpackSellRemote",
	"Notify",
}) do
	R[name] = ReplicatedStorage:WaitForChild(name, 10)
	if not R[name] then
		warn("[breaksteal] missing remote " .. name .. " -- the game changed")
		return
	end
end
local hasFPP = type(fireproximityprompt) == "function"
local DropCarried = ReplicatedStorage:FindFirstChild("DropCarriedRemote") -- optional: only the Titanic grab uses it
local okT, TitanicEggConfig = pcall(require, Shared:FindFirstChild("TitanicEggConfig"))
local TITANIC = okT and TitanicEggConfig.Bracket or "TITANIC"
local TATTR = okT and TitanicEggConfig.Attributes
	or { NextAt = "TitanicNextAt", EggName = "TitanicEggName", ZoneIndex = "TitanicZoneIndex", EndsAt = "TitanicEndsAt" }

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

local function attr(name)
	return player:GetAttribute(name)
end
local function cash()
	return tonumber(attr("Cash")) or 0
end
local function root()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function carryCount()
	return tonumber(attr("CarryCount")) or (attr("Carrying") and 1 or 0)
end
local function carrying()
	return attr("Carrying") ~= nil
end
local function full()
	return carryCount() >= (tonumber(attr("SatchelCapacity")) or 1)
end

local function hop(cf)
	local c = player.Character
	if not c then
		return false
	end
	c:PivotTo(cf)
	local r = root()
	if r then
		r.AssemblyLinearVelocity = Vector3.zero
	end
	local dl = os.clock() + PAUSE_CAP
	while player.GameplayPaused and os.clock() < dl do
		task.wait(0.1)
	end
	return true
end

-- the plot is found by owner, never by number: Base_5 in the dump is just where we spawned that time
local plotCache
local function ownPlot()
	if plotCache and plotCache.Parent then
		return plotCache
	end
	local plots = workspace:FindFirstChild("Plots")
	for _, p in ipairs(plots and plots:GetChildren() or {}) do
		if p:GetAttribute("OwnerUserId") == player.UserId then
			plotCache = p
			return p
		end
	end
end
local function homeCF()
	local plot = ownPlot()
	local sp = plot and plot:FindFirstChild("SpawnPoint")
	local pos = sp and sp.Position or (plot and plot:GetPivot().Position)
	return pos and CFrame.new(pos + Vector3.new(0, 3, 0))
end

-- The server's own reason for a refusal is only ever worded on Notify.
local lastNote, lastNoteAt = nil, -99
local conns = {}
table.insert(
	conns,
	R.Notify.OnClientEvent:Connect(function(...)
		local parts = {}
		for i, v in ipairs({ ... }) do
			parts[i] = tostring(v)
		end
		lastNote, lastNoteAt = table.concat(parts, " "), os.clock()
	end)
)
local function freshNote(since)
	return lastNoteAt >= since and lastNote or "(no notice)"
end

local stats = { hits = 0, broken = 0, stolen = 0, banked = 0, claims = 0, bought = 0, sold = 0, titanic = 0 }

-- character -------------------------------------------------------------------
-- Break, the bank trip, a hop to a far pickup and the treadmill all move you; one holder at a time.
-- claim() returns whether fn RAN. `waiting` tells the treadmill to let go; `urgent` (a bank or a Titanic
-- grab is coming) tells Break and the Titanic hitter to.
local busy, waiting, urgent = false, 0, 0
local mark, markAt = "idle", os.clock()
local function step(s)
	mark, markAt = s, os.clock()
end
-- The treadmill session is the server's: leave it the way a jump off does before anything else moves you,
-- or it may hold you on the belt.
local onTreadmill = false
local function leaveTreadmill()
	if onTreadmill then
		onTreadmill = false
		pcall(R.TreadmillSessionRemote.FireServer, R.TreadmillSessionRemote)
	end
end
local function claim(fn, isTreadmill)
	waiting += 1
	local dl = os.clock() + CLAIM_WAIT
	while busy and os.clock() < dl do
		task.wait()
	end
	waiting -= 1
	if busy then
		return false
	end
	busy = true
	if not isTreadmill then
		leaveTreadmill()
	end
	local good, err = pcall(fn)
	busy = false
	step("idle")
	if not good then
		warn("[breaksteal]", err)
	end
	return true
end

-- One toggle = one loop with its own generation counter, so off-then-on never leaves two threads.
-- pass(alive) returns whether it did something; an idle pass sleeps `idle`.
local function looper(name, pass, idle)
	local gen = 0
	return function(on)
		gen += 1
		local mine = gen
		if not on then
			return
		end
		local function alive()
			return gen == mine
		end
		task.spawn(function()
			while alive() do
				local good, did = pcall(pass, alive)
				if not good then
					warn("[breaksteal] " .. name .. " pass failed:", did)
					task.wait(1)
				elseif not did then
					task.wait(idle)
				end
			end
		end)
	end
end

-- break -----------------------------------------------------------------------
-- Average cash of the animals each zone hatches, weighted by their chance: what an egg there is worth.
local zoneValue = {}
do
	local sum, weight = {}, {}
	for _, p in pairs(EggRewards.Pool) do
		local z = tonumber(p.Zone)
		if z and tonumber(p.Cash) then
			local w = tonumber(p.Chance) or 1
			sum[z] = (sum[z] or 0) + p.Cash * w
			weight[z] = (weight[z] or 0) + w
		end
	end
	for z, s in pairs(sum) do
		zoneValue[z] = weight[z] > 0 and s / weight[z] or 0
	end
end

local zoneOn = {}
local maxSwings = MAX_SWINGS
local benched = setmetatable({}, { __mode = "k" }) -- egg or pickup -> os.clock() it is free again
local rejected = setmetatable({}, { __mode = "k" }) -- egg -> refusals since its Health last dropped
local lastBreakWork = -99
local stealOn = false -- Break waits for the bank while this is on
local sniping = false -- a Titanic is up and the sniper wants it: Break stands aside

table.insert(
	conns,
	R.EggHitRejected.OnClientEvent:Connect(function(part)
		if typeof(part) == "Instance" then
			rejected[part] = (rejected[part] or 0) + 1
		end
	end)
)

local function isLive(e)
	return e
		and e.Parent ~= nil
		and not (e:GetAttribute("Broken") or e:GetAttribute("Hatching") or e:GetAttribute("Despawning"))
end

local function damage()
	local t = PickaxeConfig.Tiers[tonumber(attr("PickaxeTier")) or 1]
	return t and t.Damage or 1
end

local function swingsFor(e)
	return math.ceil((tonumber(e:GetAttribute("Health")) or 1) / damage())
end
assert(math.ceil(7 / 250) == 1 and math.ceil(1125 / 250) == 5, "swings: Zone1 eggs fall to one Diamond hit")

-- a live egg in a ticked zone, not benched. The Titanic is the sniper's: Break never sinks minutes into it
local function breakable(e)
	local z = e:IsA("BasePart") and tonumber(e:GetAttribute("ZoneIndex"))
	return z and zoneOn[z] and not e:GetAttribute("Titanic") and isLive(e) and (benched[e] or 0) < os.clock()
end

local function bestEgg()
	local r = root()
	local here = r and r.Position or Vector3.zero
	local best, bestScore, bestDist, seen = nil, -1, math.huge, 0
	for _, e in ipairs(CollectionService:GetTagged("BreakableEgg")) do
		if breakable(e) then
			seen += 1
			local n = swingsFor(e)
			if n <= maxSwings then
				local score = (zoneValue[tonumber(e:GetAttribute("ZoneIndex"))] or 1) / (n * HIT_GAP + TRIP)
				local d = (e.Position - here).Magnitude
				if score > bestScore or (score == bestScore and d < bestDist) then
					best, bestScore, bestDist = e, score, d
				end
			end
		end
	end
	return best, seen
end

-- the server's own range measure (S/EggTargeting.lua:70): flat distance past the shell, then height past it
local function surface(e, p)
	local half = math.max(e.Size.X, e.Size.Z) / 2
	local d = p - e.Position
	local flat = math.max(Vector3.new(d.X, 0, d.Z).Magnitude - half, 0)
	local up = math.max(math.abs(d.Y) - e.Size.Y / 2, 0)
	return math.sqrt(flat * flat + up * up)
end
assert(surface({ Size = Vector3.new(4, 4, 4), Position = Vector3.zero }, Vector3.new(5, 0, 0)) == 3, "surface: 5 from the centre of a 4-wide egg is 3")

-- The hit cooldown is per egg (probe 3: two eggs hit in one frame both took damage, 4 of 4 groups), so every
-- breakable neighbour within reach of a shared stand point is hit on the same beat. Nearest first, while the
-- centroid stays inside CLUSTER_REACH of every member. Returns the members (target first) and the stand point.
local function cluster(e)
	local group, centre = { e }, e.Position
	local near = {}
	for _, n in ipairs(CollectionService:GetTagged("BreakableEgg")) do
		if n ~= e and breakable(n) and swingsFor(n) <= maxSwings and (n.Position - e.Position).Magnitude < 25 then
			near[#near + 1] = n
		end
	end
	table.sort(near, function(a, b)
		return (a.Position - e.Position).Magnitude < (b.Position - e.Position).Magnitude
	end)
	for _, n in ipairs(near) do
		if #group >= CLUSTER_MAX then
			break
		end
		local sum = n.Position
		for _, g in ipairs(group) do
			sum += g.Position
		end
		local c = sum / (#group + 1)
		local fits = surface(n, c) <= CLUSTER_REACH
		for _, g in ipairs(group) do
			fits = fits and surface(g, c) <= CLUSTER_REACH
		end
		if fits then
			group[#group + 1], centre = n, c
		end
	end
	return group, #group > 1 and centre or nil
end

local function equipPickaxe()
	local c = player.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	if not h then
		return false
	end
	if c:FindFirstChild(PickaxeConfig.ToolName) then
		return true
	end
	local tool = player.Backpack:FindFirstChild(PickaxeConfig.ToolName)
	if tool then
		pcall(h.EquipTool, h, tool)
		task.wait(0.2)
	end
	return c:FindFirstChild(PickaxeConfig.ToolName) ~= nil
end

-- root outside the shell, facing the egg, at its height: surface distance HIT_STAND
local function besideCF(e)
	local half = math.max(e.Size.X, e.Size.Z) / 2
	local p = e.Position + Vector3.new(half + HIT_STAND, 0, 0)
	return CFrame.lookAt(p, e.Position)
end

-- one beat: pin (every beat -- one hop drifts out of the 8-stud range), hit every live member, wait out the cooldown
local function swing(group, stand)
	local r = root()
	if not r then
		return false
	end
	r.CFrame = stand
	r.AssemblyLinearVelocity = Vector3.zero
	for _, e in ipairs(group) do
		if isLive(e) then
			R.EggHitRequest:FireServer(e)
			stats.hits += 1
		end
	end
	task.wait(HIT_GAP)
	return true
end

local clusterLogs = 0
local function hitEgg(e, alive)
	step("break " .. tostring(e:GetAttribute("EggType")) .. " / equip")
	if not equipPickaxe() then
		say("no Pickaxe in your backpack")
		task.wait(1)
		return
	end
	rejected[e] = 0
	local last = tonumber(e:GetAttribute("Health")) or math.huge
	local deadline = os.clock() + swingsFor(e) * HIT_GAP * 1.5 + 4
	local group, centre = cluster(e)
	local stand = centre and CFrame.lookAt(centre, Vector3.new(e.Position.X, centre.Y, e.Position.Z)) or besideCF(e)
	step("break " .. tostring(e:GetAttribute("EggType")) .. " / hit x" .. #group)
	while alive() and isLive(e) and urgent == 0 and not carrying() and os.clock() < deadline do
		lastBreakWork = os.clock()
		if not swing(group, stand) then
			return
		end
		local h = tonumber(e:GetAttribute("Health")) or last
		if h < last then
			last, rejected[e] = h, 0
		elseif rejected[e] >= REJECT_STRIKES then
			benched[e] = os.clock() + BENCH
			log(("%s refused %d hits in a row, benched %ds (%s)"):format(e:GetFullName(), rejected[e], BENCH, freshNote(os.clock() - 2)))
			return
		end
		if not equipPickaxe() then
			return
		end
	end
	-- neighbours that fell alongside; a multi-hit one left standing is simply picked again next pass
	local extra = 0
	for i = 2, #group do
		if not isLive(group[i]) then
			extra += 1
		end
	end
	stats.broken += extra
	if #group > 1 and clusterLogs < 3 then -- the first few prove it live; after that it is noise
		clusterLogs += 1
		log(("cluster x%d: target %s, %d neighbour(s) broke on the same beats"):format(#group, isLive(e) and "standing" or "broke", extra))
	end
	if not isLive(e) then
		stats.broken += 1
		say(("broke %s (%d broken)"):format(tostring(e:GetAttribute("EggType")), stats.broken), true)
	elseif os.clock() >= deadline then
		benched[e] = os.clock() + BENCH -- took far longer than its swings should: someone healing it, or a range we never reach
	end
end

local setBreak = looper("break", function(alive)
	if urgent > 0 or sniping or (carrying() and stealOn) then
		return false -- the bank and the Titanic go first; a long carry is a long guard chase
	end
	local e, seen = bestEgg()
	if not e then
		say(("no egg to break: %d live in the ticked zones, none under %d swings (damage %s)"):format(seen, maxSwings, fmt(damage())), true)
		return false
	end
	return claim(function()
		hitEgg(e, alive)
	end)
end, 0.5)

-- steal + bank ----------------------------------------------------------------
local rarityOn = {}
local farWorks = nil -- nil = untested past STEAL_NEAR; set by the first such press
local anchorOf = setmetatable({}, { __mode = "k" }) -- pickup -> its prompt

-- The game's client moves each StealPrompt into its own workspace.PromptAnchor part, which it slides
-- along the model's SURFACE every Heartbeat (SurfacePrompt.lua), so the model itself holds no prompt.
-- Match by distance to the model's bounding box, not its pivot: a big Whale's surface is far from its
-- pivot, and pivot-nearest picked a neighbour's prompt (refused, "no notice", every 30s).
local ANCHOR_GAP = 3 -- studs an anchor may sit outside the model's box and still be its own
local function boxGap(m, pos)
	local cf, size = m:GetBoundingBox()
	local p = cf:PointToObjectSpace(pos)
	local h = size / 2
	return Vector3.new(math.max(math.abs(p.X) - h.X, 0), math.max(math.abs(p.Y) - h.Y, 0), math.max(math.abs(p.Z) - h.Z, 0)).Magnitude
end
local function promptFor(m)
	local pr = anchorOf[m]
	if pr and pr.Parent and pr.Parent:IsA("BasePart") and boxGap(m, pr.Parent.Position) <= ANCHOR_GAP then
		return pr
	end
	pr = nil
	local bestD = ANCHOR_GAP
	for _, a in ipairs(workspace:GetChildren()) do
		if a.Name == "PromptAnchor" and a:IsA("BasePart") then
			local p = a:FindFirstChildWhichIsA("ProximityPrompt")
			local d = p and boxGap(m, a.Position)
			if d and d <= bestD then
				pr, bestD = p, d
			end
		end
	end
	pr = pr or m:FindFirstChildWhichIsA("ProximityPrompt", true)
	anchorOf[m] = pr
	return pr
end

local function pickupRate(m)
	local good, v = pcall(
		EggRewards.PlacedCashPerSecond,
		m:GetAttribute("AnimalName"),
		m:GetAttribute("SizeMult"),
		m:GetAttribute("Mutation"),
		m:GetAttribute("WeightKg"),
		m:GetAttribute("Variant")
	)
	return good and tonumber(v) or 0
end

local function bestPickup()
	local folder = workspace:FindFirstChild("AnimalPickups")
	local now = workspace:GetServerTimeNow()
	local best, bestPr, bestRate = nil, nil, -1
	for _, m in ipairs(folder and folder:GetChildren() or {}) do
		local left = (tonumber(m:GetAttribute("DespawnAtServerTime")) or math.huge) - now
		if m:IsA("Model") and rarityOn[m:GetAttribute("Rarity")] and left > DESPAWN_MARGIN and (benched[m] or 0) < os.clock() then
			local pr = promptFor(m)
			local owner = pr and pr:GetAttribute("ReservedUserId")
			if pr and (owner == nil or owner == player.UserId) then
				local rate = pickupRate(m)
				if rate > bestRate then
					best, bestPr, bestRate = m, pr, rate
				end
			end
		end
	end
	return best, bestPr, bestRate
end

local function press(pr, confirm)
	-- every gate on a prompt is the client's, i.e. ours; the game disables them all once the satchel is full
	pcall(function()
		pr.Enabled = true
		pr.RequiresLineOfSight = false
		pr.MaxActivationDistance = STEAL_REACH
	end)
	local c0 = carryCount()
	pcall(fireproximityprompt, pr)
	local dl = os.clock() + (confirm or STEAL_CONFIRM)
	while carryCount() <= c0 and os.clock() < dl do
		task.wait()
	end
	return carryCount() > c0
end

-- true got it, false refused, nil could not try
local function steal(m, pr, rate)
	local r = root()
	if not r then
		return nil
	end
	local name = tostring(m:GetAttribute("AnimalName"))
	local dist = (m:GetPivot().Position - r.Position).Magnitude
	local got
	if dist <= STEAL_NEAR or farWorks ~= false then
		got = press(pr)
		if dist > STEAL_NEAR and farWorks == nil then
			farWorks = got
			log(("first press from %d studs (past the proven %d): %s"):format(math.floor(dist), STEAL_NEAR, got and "TOOK -- far steals stay on" or "refused -- hopping beside from now on"))
		end
	end
	if not got and dist > STEAL_NEAR then
		claim(function()
			step("steal " .. name .. " / hop")
			hop(m:GetPivot() + Vector3.new(3, 3, 0))
			task.wait(0.3)
			got = press(pr)
		end)
	end
	if got then
		stats.stolen += 1
		say(("stole %s %s (%s/s)"):format(tostring(m:GetAttribute("Rarity")), name, fmt(rate)))
	else
		benched[m] = os.clock() + BENCH
		-- the server gives no reason here, so say what we pressed: a gap or a stranger's ReservedUserId is our bug,
		-- a model that is gone a moment later is a race someone else won
		local a = pr.Parent
		local gap = a and a:IsA("BasePart") and ("%.1f studs"):format(boxGap(m, a.Position)) or "?"
		task.delay(1, function()
			log(("steal %s refused (%s) -- %d studs, prompt %q on an anchor %s from the model, reserved %s, %s"):format(
				name,
				freshNote(os.clock() - 3),
				math.floor(dist),
				tostring(pr.ObjectText ~= "" and pr.ObjectText or pr.ActionText),
				gap,
				tostring(pr:GetAttribute("ReservedUserId")),
				m.Parent and "pickup still there 1s later" or "pickup gone 1s later (someone else took it)"
			))
		end)
	end
	return got
end

local function bank()
	local cf = homeCF()
	if not cf then
		say("no plot of yours found")
		return false
	end
	urgent += 1
	local n = carryCount()
	local ran = claim(function()
		step("bank / hop home")
		hop(cf)
		local dl = os.clock() + BANK_CONFIRM
		while carrying() and os.clock() < dl do
			task.wait()
		end
		if carrying() then
			warn("[breaksteal] landed home and still carrying -- the bank did not take:", freshNote(os.clock() - BANK_CONFIRM))
		else
			say(("banked %d"):format(n), true)
		end
	end)
	urgent -= 1
	return ran
end

local setSteal = looper("steal", function()
	if carrying() and full() then
		return bank()
	end
	local m, pr, rate = bestPickup()
	if not m then
		if carrying() then
			return bank() -- nothing else to fill the satchel with: bank what we have
		end
		say("no pickup to take (tick rarities, or break some eggs)", true)
		return false
	end
	return steal(m, pr, rate) ~= nil
end, 0.25)

-- equip / index ---------------------------------------------------------------
local equipDue, lastEquip = false, -99
local indexOn, lastIndex = false, -99

table.insert(
	conns,
	R.AnimalBankedRemote.OnClientEvent:Connect(function(list)
		for _, row in ipairs(type(list) == "table" and list or {}) do
			stats.banked += tonumber(type(row) == "table" and row.Count) or 1
		end
		equipDue = true
	end)
)
table.insert(
	conns,
	R.IndexRemote.OnClientEvent:Connect(function(kind, state)
		if not indexOn or kind ~= "State" or type(state) ~= "table" or os.clock() - lastIndex < INDEX_GAP then
			return
		end
		for _, v in pairs(state) do
			if v == "Ready" then
				lastIndex = os.clock()
				stats.claims += 1
				R.IndexRemote:FireServer("ClaimAll", nil)
				say("claimed the index rewards", true)
				return
			end
		end
	end)
)

local setEquip = looper("equip", function()
	local now = os.clock()
	if (equipDue and now - lastEquip >= EQUIP_GAP) or now - lastEquip >= EQUIP_EVERY then
		equipDue, lastEquip = false, now
		R.PetsInventoryRemote:FireServer("EquipBest", nil)
	end
	return false
end, 0.5)

-- shop ------------------------------------------------------------------------
local function owned(attrName)
	local set = {}
	for id in tostring(attr(attrName) or ""):gmatch("%d+") do
		set[tonumber(id)] = true
	end
	return set
end
assert(next(owned("NoSuchAttr")) == nil, "owned: empty")

-- rows {id, power, price} for one shop, in the game's own order
local SHOPS = {
	Pickaxe = {
		remote = R.PickaxeShopRequest,
		owned = "OwnedPickaxes",
		equipped = "PickaxeTier",
		rows = {},
	},
	Trail = {
		remote = R.TrailShopRequest,
		owned = "OwnedTrails",
		equipped = "EquippedTrail",
		rows = {},
	},
}
for i, t in ipairs(PickaxeConfig.Tiers) do
	table.insert(SHOPS.Pickaxe.rows, { id = i, name = t.Name, power = t.Damage, price = t.Price or 0 })
end
for _, t in ipairs(TrailsConfig.Trails) do
	table.insert(SHOPS.Trail.rows, { id = t.Id, name = t.Name, power = t.Multiplier, price = t.Price or 0 })
end
for _, s in pairs(SHOPS) do
	table.sort(s.rows, function(a, b)
		return a.power < b.power
	end)
	s.cool, s.skipTested = 0, nil -- skipTested: nil untested, true buying ahead works, false it doesn't
end

local function waitFor(cond, timeout)
	local dl = os.clock() + timeout
	while not cond() and os.clock() < dl do
		task.wait()
	end
	return cond()
end

local function shopPass(kind)
	local s = SHOPS[kind]
	if s.cool > os.clock() then
		return false
	end
	local have, cur = owned(s.owned), tonumber(attr(s.equipped)) or 0
	local curPower = 0
	for _, row in ipairs(s.rows) do
		if row.id == cur then
			curPower = row.power
		end
	end
	-- an owned one stronger than the equipped one: equip it (free)
	local bestOwned
	for _, row in ipairs(s.rows) do
		if have[row.id] and row.power > curPower then
			bestOwned = row
		end
	end
	if bestOwned then
		s.remote:FireServer("Equip", bestOwned.id)
		if not waitFor(function()
			return tonumber(attr(s.equipped)) == bestOwned.id
		end, SHOP_CONFIRM) then
			s.cool = os.clock() + SHOP_BACKOFF
		end
		return true
	end
	-- the next one up, and the strongest affordable one up
	local nextRow, top
	for _, row in ipairs(s.rows) do
		if not have[row.id] and row.power > curPower and row.price > 0 then
			nextRow = nextRow or row
			if row.price <= cash() then
				top = row
			end
		end
	end
	if not top then
		return false
	end
	local pick = (s.skipTested == false) and nextRow or top
	if pick.price > cash() then
		return false
	end
	local t0 = os.clock()
	s.remote:FireServer("Buy", pick.id)
	local got = waitFor(function()
		return owned(s.owned)[pick.id] == true
	end, SHOP_CONFIRM)
	if pick ~= nextRow and s.skipTested == nil then
		s.skipTested = got
		log(("%s: buying %s ahead of %s %s"):format(kind, pick.name, nextRow.name, got and "TOOK" or "refused -- buying in order from now on"))
	end
	if got then
		stats.bought += 1
		say(("bought %s %s for %s"):format(kind, pick.name, fmt(pick.price)))
	elseif pick == nextRow or s.skipTested then -- a refused skip-ahead retries next pass with the next tier
		s.cool = os.clock() + SHOP_BACKOFF
		log(("%s %s not taken: %s"):format(kind, pick.name, freshNote(t0)))
	end
	return got
end

local setPickaxe = looper("pickaxe", function()
	return shopPass("Pickaxe")
end, SHOP_EVERY)
local setTrail = looper("trail", function()
	return shopPass("Trail")
end, SHOP_EVERY)

-- titanic ---------------------------------------------------------------------
-- TitanicEggConfig: one egg every 30 min, alive 10 min, zone 2-5, HP x10, luck x30. The egg part carries
-- Titanic = true (EggEffects.lua:378); workspace carries its name, zone and end time for the banner.
local sniperOn = false
local titanicBenchUntil = 0 -- a Titanic that won't fall in time is left alone until this
local hatchWait = { untilAt = 0, cf = nil } -- after it breaks, stand where it was until its pickup shows
local grabbing = setmetatable({}, { __mode = "k" }) -- TITANIC pickup -> a grab thread owns it
local announced = setmetatable({}, { __mode = "k" }) -- Titanic egg -> logged once

local function titanicEgg()
	for _, e in ipairs(CollectionService:GetTagged("BreakableEgg")) do
		if e:IsA("BasePart") and e:GetAttribute("Titanic") == true and isLive(e) then
			return e
		end
	end
	return nil
end

local function titanicLeft()
	local ends = tonumber(workspace:GetAttribute(TATTR.EndsAt))
	return ends and ends - workspace:GetServerTimeNow() or math.huge
end

local function clock(s)
	s = math.max(0, math.floor(s))
	return ("%d:%02d"):format(s // 60, s % 60)
end
assert(clock(75.9) == "1:15" and clock(-3) == "0:00", "clock")

-- Press a TITANIC-bracket pickup until it is ours, then bank it. Everyone sees it appear at the same moment,
-- so this runs on its own thread straight off ChildAdded rather than waiting for the steal loop's beat.
local function grab(m)
	if grabbing[m] then
		return
	end
	grabbing[m] = true
	urgent += 1 -- Break, the Titanic hitter and the treadmill let go of the character
	local good, err = pcall(function()
		local name = tostring(m:GetAttribute("AnimalName"))
		local r = root()
		local dist = r and (m:GetPivot().Position - r.Position).Magnitude or 0
		log(("TITANIC %s %s appeared %d studs away"):format(tostring(m:GetAttribute("Rarity")), name, math.floor(math.min(dist, 1e6))))
		if full() and DropCarried then
			local held = attr("Carrying")
			DropCarried:FireServer() -- UNPROVEN: what the game's own drop button sends (ChaseAlertController.lua:242)
			local freed = waitFor(function()
				return not full()
			end, 1)
			log(("dropped %s to make room: %s"):format(tostring(held), freed and "took" or "NOT taken"))
		end
		local t0 = os.clock()
		local got, hopped = false, false
		while not got and m.Parent and os.clock() < t0 + TITANIC_GRAB do
			local pr = promptFor(m)
			r = root()
			if not pr or not r then
				task.wait(0.05) -- the client hasn't moved the prompt into its anchor yet
			else
				if not hopped and farWorks ~= true and (m:GetPivot().Position - r.Position).Magnitude > STEAL_NEAR then
					hopped = true
					claim(function()
						step("titanic grab / hop")
						hop(m:GetPivot() + Vector3.new(3, 3, 0))
					end)
				end
				got = press(pr, TITANIC_PRESS)
			end
		end
		if got then
			stats.titanic += 1
			stats.stolen += 1
			say(("GOT TITANIC %s in %.1fs"):format(name, os.clock() - t0))
			bank()
		else
			log(("lost TITANIC %s: %s after %.1fs (%s)"):format(name, m.Parent and "still there" or "taken or gone", os.clock() - t0, freshNote(t0)))
		end
	end)
	urgent -= 1
	if not good then
		warn("[breaksteal] titanic grab:", err)
	end
end

local function watchPickup(m)
	if not sniperOn or not m:IsA("Model") then
		return
	end
	task.spawn(function()
		local dl = os.clock() + 2 -- attributes may land a beat after the model
		while m.Parent and m:GetAttribute("WeightBracket") == nil and os.clock() < dl do
			task.wait()
		end
		if sniperOn and m:GetAttribute("WeightBracket") == TITANIC then
			grab(m)
		end
	end)
end
local pickupFolder = workspace:FindFirstChild("AnimalPickups")
if pickupFolder then
	table.insert(conns, pickupFolder.ChildAdded:Connect(watchPickup))
end

-- Hit the Titanic while its HP falls fast enough -- ours plus everyone else's hits, measured, not assumed --
-- to break before it expires. Yours alone rarely does past zone 2; a busy server's often does.
local function hitTitanic(e, alive)
	if not announced[e] then
		announced[e] = true
		log(("Titanic %s in zone %s: %s HP = %d of your hits, %s left"):format(tostring(e:GetAttribute("EggType")), tostring(e:GetAttribute("ZoneIndex")), fmt(e:GetAttribute("Health")), swingsFor(e), clock(math.min(titanicLeft(), 1e6))))
	end
	step("titanic / hit")
	local hist, t0 = {}, os.clock()
	while alive() and isLive(e) and urgent == 0 and not carrying() do
		if not equipPickaxe() then
			say("no Pickaxe in your backpack")
			task.wait(1)
			return
		end
		lastBreakWork = os.clock()
		hatchWait.cf = besideCF(e)
		if not swing(e) then
			return
		end
		local now, h = os.clock(), tonumber(e:GetAttribute("Health")) or 0
		table.insert(hist, { t = now, h = h })
		while #hist > 1 and now - hist[1].t > TITANIC_RATE_WINDOW do
			table.remove(hist, 1)
		end
		if now - t0 >= TITANIC_RATE_WINDOW then
			local rate = (hist[1].h - h) / math.max(now - hist[1].t, 0.1)
			local left = titanicLeft()
			if rate <= 0 or h / rate > left then
				titanicBenchUntil = now + TITANIC_RECHECK
				sniping = false
				say(("Titanic won't fall in time: %s HP at %s/s, %s left -- back to Break, re-check in %ds"):format(fmt(h), fmt(rate), clock(math.min(left, 1e6)), TITANIC_RECHECK))
				return
			end
			say(("Titanic: %s HP at %s/s, falls in ~%s"):format(fmt(h), fmt(rate), clock(h / rate)), true)
		end
	end
	if not isLive(e) then
		hatchWait.untilAt = os.clock() + 10 -- the dump's hatch took 6.7s from break to pickup
		say("Titanic broken -- standing by for the hatch")
	end
end

local setSniper = looper("titanic", function(alive)
	-- sweep for a TITANIC pickup the listener missed (up before the toggle, or the folder came late)
	local folder = workspace:FindFirstChild("AnimalPickups")
	for _, m in ipairs(folder and folder:GetChildren() or {}) do
		if m:GetAttribute("WeightBracket") == TITANIC and not grabbing[m] then
			task.spawn(grab, m)
		end
	end
	local e = titanicEgg()
	local waitingHatch = not e and os.clock() < hatchWait.untilAt and hatchWait.cf ~= nil
	sniping = waitingHatch or (e ~= nil and titanicBenchUntil < os.clock())
	if not sniping or urgent > 0 or carrying() then
		return false
	end
	return claim(function()
		if e then
			hitTitanic(e, alive)
			return
		end
		step("titanic / waiting for the hatch")
		while alive() and urgent == 0 and os.clock() < hatchWait.untilAt do
			local r = root()
			if r then
				r.CFrame = hatchWait.cf
				r.AssemblyLinearVelocity = Vector3.zero
			end
			task.wait(0.2)
		end
		hatchWait.untilAt = 0
	end)
end, 0.5)

local function titanicNote()
	local now = workspace:GetServerTimeNow()
	local name = workspace:GetAttribute(TATTR.EggName)
	local got = stats.titanic > 0 and (" (got " .. stats.titanic .. ")") or ""
	if name then
		return ("%s, zone %s, %s left%s"):format(tostring(name), tostring(workspace:GetAttribute(TATTR.ZoneIndex)), clock((tonumber(workspace:GetAttribute(TATTR.EndsAt)) or now) - now), got)
	end
	local nextAt = tonumber(workspace:GetAttribute(TATTR.NextAt))
	return (nextAt and ("next in " .. clock(nextAt - now)) or "-") .. got
end

-- treadmill -------------------------------------------------------------------
local function treadmillPart()
	local plot = ownPlot()
	for _, m in ipairs(plot and plot:GetChildren() or {}) do
		if m:IsA("Model") and m:GetAttribute("SpeedMultiplier") then
			return m:FindFirstChild("Hitbox")
		end
	end
end

local setTreadmill = looper("treadmill", function(alive)
	if busy or waiting > 0 or urgent > 0 or sniping or carrying() or os.clock() - lastBreakWork < TREAD_IDLE then
		return false
	end
	local hb = treadmillPart()
	if not hb then
		say("no treadmill on your plot", true)
		return false
	end
	return claim(function()
		step("treadmill")
		local spot = CFrame.new(hb.Position + Vector3.new(0, hb.Size.Y / 2 + 3, 0))
		local r = root()
		if not onTreadmill or not r or (r.Position - spot.Position).Magnitude > 8 then
			hop(spot)
			onTreadmill = true
		end
		local dl = os.clock() + TREAD_SLICE
		while alive() and waiting == 0 and urgent == 0 and not sniping and os.clock() < dl do
			task.wait(0.25)
		end
		if not alive() then
			leaveTreadmill()
		end
	end, true)
end, 0.5)

-- sell ------------------------------------------------------------------------
local sellRarity, keepRate, sellTold = {}, 0, false

local function callTimed(rf, timeout, ...)
	local box
	local args = table.pack(...)
	task.spawn(function()
		box = table.pack(pcall(rf.InvokeServer, rf, table.unpack(args, 1, args.n)))
	end)
	local dl = os.clock() + timeout
	while not box and os.clock() < dl do
		task.wait()
	end
	return box
end

local function sellPass()
	local plot = ownPlot()
	if not plot or (plot:GetAttribute("AnimalsPlaced") or 0) < (plot:GetAttribute("MaxAnimals") or math.huge) then
		return false -- a free slot: Equip Best should place them, not us sell them
	end
	local weakest = math.huge
	local placed = plot:FindFirstChild("PlacedAnimals")
	for _, a in ipairs(placed and placed:GetChildren() or {}) do
		weakest = math.min(weakest, tonumber(a:GetAttribute("CashPerSecond")) or math.huge)
	end
	local list, total = {}, 0
	for _, t in ipairs(player.Backpack:GetChildren()) do
		if CollectionService:HasTag(t, "AnimalTool") then
			local name = t:GetAttribute("AnimalName")
			local rate = EggRewards.PlacedCashPerSecond(name, t:GetAttribute("SizeMult"), t:GetAttribute("Mutation"), t:GetAttribute("WeightKg"), t:GetAttribute("Variant"))
			if sellRarity[EggRewards.RarityOf(name)] and rate <= weakest and (keepRate <= 0 or rate < keepRate) and #list < 200 then
				list[#list + 1] = t
				total += rate
			end
		end
	end
	if #list == 0 then
		return false
	end
	local cash0, t0 = cash(), os.clock()
	local box = callTimed(R.BackpackSellRemote, SELL_TIMEOUT, list)
	local gone = 0
	for _, t in ipairs(list) do
		if t.Parent ~= player.Backpack then
			gone += 1
		end
	end
	if not sellTold then
		sellTold = true -- UNPROVEN path: say exactly what happened the first time
		log(("SELL first try: %d tools sent, %d gone, cash %s -> %s, reply %s, notice %s"):format(#list, gone, fmt(cash0), fmt(cash()), box and tostring(box[2]) or "none in " .. SELL_TIMEOUT .. "s", freshNote(t0)))
	end
	stats.sold += gone
	if gone > 0 then
		say(("sold %d animals (%s/s between them)"):format(gone, fmt(total)))
	end
	return gone > 0
end
local setSell = looper("sell", sellPass, SELL_EVERY)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Break and Steal Eggs", statusBar = true })
if not Window then
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "egg")
local Farm = Tab:AddLeftGroupbox("Eggs", "pickaxe")
local Steal = Tab:AddLeftGroupbox("Steal", "hand")
local Base = Tab:AddRightGroupbox("Base", "house")
local Shop = Tab:AddRightGroupbox("Shop", "shopping-cart")
local Sell = Tab:AddRightGroupbox("Sell", "coins")

local zoneValues, zoneByLabel = {}, {}
for i, z in ipairs(ZonesConfig.Zones) do
	local label = ("Zone %d (%s)"):format(i, tostring(z.Rarity))
	zoneValues[i], zoneByLabel[label] = label, i
	zoneOn[i] = true -- Default does not fire the callback, so arm by hand
end
local rarities = EggRarity.Ladder()
for _, r in ipairs(rarities) do
	rarityOn[r] = true
end

Farm:AddToggle("Break", {
	Text = "Auto Break Eggs",
	Tooltip = "Hits the egg worth the most per second in the ticked zones: its zone's average animal over the swings it needs. Stands beside it with the pickaxe out. Waits while you carry something",
	Default = false,
	Callback = function(state)
		setBreak(state)
	end,
})
Farm:AddDropdown("Zones", {
	Text = "Zones",
	Tooltip = "Eggs in these zones only. Zones your pickaxe can't break inside Max swings are skipped anyway",
	Values = zoneValues,
	Default = zoneValues,
	Multi = true,
	Callback = function(picked)
		table.clear(zoneOn)
		for label in pairs(ticked(picked)) do
			local i = zoneByLabel[label]
			if i then
				zoneOn[i] = true
			end
		end
	end,
})
Farm:AddInput("MaxSwings", {
	Text = "Max swings per egg",
	Tooltip = "Eggs needing more hits than this with your pickaxe are skipped. One hit is 0.36s",
	Default = tostring(MAX_SWINGS),
	Numeric = true,
	Finished = true,
	Placeholder = tostring(MAX_SWINGS),
	Callback = function(v)
		local n = tonumber(v)
		maxSwings = (n and n >= 1) and math.floor(n) or MAX_SWINGS
	end,
})

local stealToggle
stealToggle = Steal:AddToggle("Steal", {
	Text = "Auto Steal + Bank",
	Tooltip = "Takes pickups hatched for you (or for nobody) of the ticked rarities, best $/s first, from where you stand, and teleports home to bank once the satchel is full",
	Default = false,
	Callback = function(state)
		if state and not hasFPP then
			stealOn = false
			setSteal(false)
			pcall(function()
				stealToggle:SetValue(false)
			end)
			say("Auto Steal needs fireproximityprompt (this executor has none)")
			return
		end
		stealOn = state
		setSteal(state)
	end,
})
Steal:AddDropdown("Rarities", {
	Text = "Animal rarities",
	Tooltip = "Only pickups of these rarities are taken",
	Values = rarities,
	Default = rarities,
	Multi = true,
	Callback = function(picked)
		table.clear(rarityOn)
		for r in pairs(ticked(picked)) do
			rarityOn[r] = true
		end
	end,
})

Base:AddToggle("Equip", {
	Text = "Auto Equip Best",
	Tooltip = "The game's Equip Best after every bank, and every 30s",
	Default = false,
	Callback = function(state)
		equipDue = state
		setEquip(state)
	end,
})
Base:AddToggle("Index", {
	Text = "Auto Claim Index",
	Tooltip = "Claim All whenever the index has a Ready reward",
	Default = false,
	Callback = function(state)
		indexOn = state
		if state then
			lastIndex = -99
			pcall(R.IndexRemote.FireServer, R.IndexRemote, "Get", nil) -- the answer is a State push the listener reads
		end
	end,
})
Farm:AddToggle("Titanic", {
	Text = "Titanic Sniper",
	Tooltip = "When the 30-minute Titanic egg is up, hits it while it is falling fast enough to break in time, then presses its TITANIC pickup the instant it hatches and banks it. Also grabs any TITANIC pickup from an ordinary egg anywhere. Takes priority over Break",
	Default = false,
	Callback = function(state)
		sniperOn = state
		if not state then
			sniping = false
		end
		setSniper(state)
	end,
})

Base:AddToggle("Treadmill", {
	Text = "Auto Treadmill",
	Tooltip = "Stands on your plot's treadmill (speed = zone access) whenever Break has had nothing to do for a few seconds",
	Default = false,
	Callback = function(state)
		setTreadmill(state)
		if not state and not busy then
			leaveTreadmill()
		end
	end,
})

Shop:AddToggle("Pickaxe", {
	Text = "Auto Buy Pickaxe",
	Tooltip = "Buys the strongest pickaxe you can afford, for cash only",
	Default = false,
	Callback = setPickaxe,
})
Shop:AddToggle("Trail", {
	Text = "Auto Buy Trail",
	Tooltip = "Buys the trail with the biggest speed multiplier you can afford, for cash only",
	Default = false,
	Callback = setTrail,
})

Sell:AddToggle("Sell", {
	Text = "Auto Sell (untested)",
	Tooltip = "Sells backpack animals of the ticked rarities while every plot slot is full, never one earning more than your weakest placed animal or at least the keep box. Nothing is ticked to start with",
	Default = false,
	Callback = setSell,
})
Sell:AddDropdown("SellRarity", {
	Text = "Rarities to sell",
	Values = rarities,
	Default = {},
	Multi = true,
	Callback = function(picked)
		table.clear(sellRarity)
		for r in pairs(ticked(picked)) do
			sellRarity[r] = true
		end
	end,
})
Sell:AddInput("Keep", {
	Text = "Keep at or above $/s",
	Tooltip = "0 = no extra floor",
	Default = "0",
	Numeric = true,
	Finished = true,
	Placeholder = "0",
	Callback = function(v)
		keepRate = tonumber(v) or 0
	end,
})

local note, nextStrip = "idle", 0
table.insert(
	conns,
	RunService.Heartbeat:Connect(function()
		if pending then
			note, pending = pending, nil
		end
		local now = os.clock()
		if now < nextStrip then
			return
		end
		nextStrip = now + 0.5
		Window:SetStatus({
			{ "Cash", fmt(cash()) },
			{ "Speed", fmt(attr("SpeedPower")) },
			{ "Carry", ("%d/%d"):format(carryCount(), tonumber(attr("SatchelCapacity")) or 1) },
			{ "Broken", stats.broken },
			{ "Stolen", stats.stolen },
			{ "Banked", stats.banked },
			{ "Titanic", titanicNote() },
			{ "Now", note },
		})
	end)
)

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("BreakStealEggs", {})

local running = true
-- watchdog: a thread parked in a yield can't report itself
task.spawn(function()
	while running do
		if busy and os.clock() - markAt > STUCK_WARN then
			warn(("[breaksteal] stuck %ds at: %s"):format(math.floor(os.clock() - markAt), mark))
			markAt = os.clock()
		end
		task.wait(5)
	end
end)

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
	running = false
	stealOn, indexOn, sniperOn, sniping = false, false, false, false
	setSniper(false)
	setBreak(false)
	setSteal(false)
	setEquip(false)
	setPickaxe(false)
	setTrail(false)
	setTreadmill(false)
	setSell(false)
	leaveTreadmill()
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().breakStealStop = nil
end)

getgenv().breakStealStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().breakStealStop = nil
end
