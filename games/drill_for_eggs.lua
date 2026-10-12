--[[ Drill for Eggs -- teleport-grab eggs by zone and rarity, place, hatch, train, upgrade drills, rebirth (120656419209274)
     PlaceVersion 482

     WORLD   : twelve pits down one road (ZONE_ORDER: Common .. Elemental), each behind a wall in workspace.Floors with a
               RequiredPower. Wild eggs wander the pit floors in workspace.Live.Friends (attribute SpawnZone, a StealPrompt
               on RootPart, a `timer` that despawns them). Which rarity an egg is comes from the Friends database by NAME
               (Database.Friends[id].Rarity, AnimalEgg = true); a Common pit holds Epic-rarity eggs too.
     FARM    : TP in <=100-stud legs to 3 studs from the egg, fireproximityprompt (server accepts it 0.06-0.17s after the
               landing; the first press after a TP sometimes needs a second one), then TP home at once: the carry
               (Character CarryingEggs, Player holdingFriend) wakes the zone's guardian (GuardianAggro), and arriving at
               your plot banks the egg into Data.Inventory.Friends as a Tool. ~0.8s a trip, ~1.5s with the place.
               Grabs are refused in a zone whose wall is unbroken (probed: Rare egg, 4 studs away, nothing happens).
               TeleportToBase while carrying is a Robux product: never wired.
     WALLS   : `Wall Broken(zone, false)` is accepted when Strength >= the floor's RequiredPower / 15 (the floors carry
               HPx15 = true: the client's HP bar is 15x the server's number) AND we stand near the floor. Probed:
               Common ok at 1560, Rare refused at 1560, Legendary refused from home at 2.2x its attribute and taken ~1s
               after a TP onto its floor, Mythic (attribute 22.5B) taken at 1.62B, Secret (9.4T) refused at 44M. It sets
               Player attribute BrokenWalls ("Common,Rare,Epic"). The wall and PitBarriers collisions are local only,
               which a TP does not care about. They stay broken through a rebirth.
     PLACE   : `Place Friend(uid, x, z)` with x, z in Base-local space (Base = your plot's Base part), no Tool in hand
               needed. Hatch: `Open Lucky Block(uid)` once finishTime has passed (3s Common .. 45s Epic), position-free.
               With the pen full (animals >= getPlotSlots(BaseLevel)) a hatched animal goes to the inventory ("Plot full");
               `Equip Best()` then puts the strongest animals of plot + inventory on the plot (probed: Pickup Friend(uid)
               took one off, Equip Best put it back) and `Sell Friend From Inventory(uid)` sells the leftovers (probed
               +340 for a Pig). Animals earn cash with no collecting. Eggs occupy a grid spot while they incubate
               (Common 3s, Epic 60s, Legendary 90s, Mythic 300s, Secret 720s), so a full plot pauses the farm.
     TRAIN   : `Activate Dumbell("auto")`: ~9 clicks/s are credited (20/s sends are dropped), +Dumbell strength each.
               The AutoTrainer tier multiplier (x1.1 a tier) applies only while InTrainingZone, i.e. standing in your
               plot's LevelUpTouchZone (probed 1024 Strength/s there with our clicks at tier 2 against 818 outside).
     UPGRADES: all gated by the drill cap = the highest Dumbell_N you own. Buy Dumbell(id) takes cash and equips it
               (probed). Upgrade AutoTrainer and Upgrade WalkSpeed are free up to the cap. Purchase Floor(level + 1)
               (a RemoteFunction, returns ok, message) is free and wants drill getPlotDrillRequirement(level + 1) (3, 6, 9..).
     REBIRTH : `Rebirth()` needs Strength >= Rebirths[n + 1].StrengthRequirement; probed 2026-10-12: Strength goes to 0
               and Level to 1, cash, drills, tiers, pen, animals and broken walls all stay, money x CashMulti.
     Unwired on purpose (Robux): Skip Incubation, TeleportToBase, Skip (rebirth), Drill Boost, Buy Dumbell by RobuxID,
     the AutoCollect pad (animals pay without it).

     Movement: KICK-WEIGHTED by the dossier, probed 2026-10-12: legs of 5, 10, 20, 40, 80, 120 studs held at 0.2s, 1s,
     3s; 40+ grab-and-home cycles of ~300 studs a leg (~220 studs/s) with no revert or kick. After REVERT_LIMIT
     reverts in a row the legs shrink to SLOW_LEG every SLOW_GAP for SLOW_FOR seconds.

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().drillForEggsStop() ]]

-- config ---------------------------------------------------------------------
local LEG = 100 -- studs per teleport leg; 120 held in the ladder
local LEG_GAP = 0.06 -- seconds between legs; the server needs a beat to see the move
local SLOW_LEG = 40 -- the glide used after a run of reverts
local SLOW_GAP = 0.3
local SLOW_FOR = 60 -- seconds the glide stays on
local REVERT = 12 -- a teleport that lands further than this from its aim did not stick
local REVERT_LIMIT = 3 -- reverts in a row that switch to the glide
local EGG_OFFSET = Vector3.new(0, 1, 3) -- where to stand against an egg (its prompt reaches 12)
local GRAB_TRIES = 4 -- presses per egg; the first after a landing is sometimes ignored
local GRAB_GAP = 0.12 -- between presses
local GRAB_WAIT = 0.5 -- how long a press waits for CarryingEggs to show
local BANK_WAIT = 5 -- after the TP home, how long the egg may take to reach the inventory (2.5 cut off Rare trips)
local MIN_TIMER = 3 -- an egg with fewer seconds on its despawn timer is not worth a trip
local BENCH = 12 -- an egg we failed on is skipped this long
local MAX_MISSES = 3 -- consecutive failed eggs before we go home to look again
local TRIP_REST = 0.25 -- seconds between trips: a human-ish cadence, raise it if the server ever kicks
local TICK = 0.1
local HATCH_EVERY = 0.5
local HATCH_GAP = 0.12 -- between two Open Lucky Block fires
local UPGRADE_EVERY = 1
local UPGRADE_GAP = 0.3 -- between repeated Upgrade AutoTrainer / WalkSpeed fires
local HP_DIV = 15 -- walls flagged HPx15 break for RequiredPower / 15 of Strength; lower it if "did not break" shows up
local WALL_SETTLE = 0.4 -- after the TP onto a wall, how long the server needs to see us there
local WALL_TRIES = 4 -- Wall Broken fires per visit
local WALL_WAIT = 0.8 -- how long one fire may take to show in BrokenWalls
local WALL_RETRY = 20 -- a wall that would not break is left alone this long
local EQUIP_EVERY = 1 -- Auto Equip Best looks at the inventory this often (equipBest itself is throttled by EQUIP_GAP)
local SELL_EVERY = 1
local SELL_GAP = 0.2
local REBIRTH_EVERY = 3
local REBIRTH_MIN_GAIN = 1.02 -- skip a rebirth whose CashMulti gain is below this ratio
local WALL_FACTOR = 100 -- wait out a rebirth while the next wall's power is within this multiple of Strength
local STATS_EVERY = 30 -- seconds between the progress line in the console
local CLICK_GAP = 0.115 -- ~8.7 clicks/s: the server credits ~9/s and drops the rest
local PLACE_STEP = 11 -- grid spacing of egg spots on the plot
local PLACE_MARGIN = 5 -- keep this far inside the plot edge
local PLACE_RANGE = 60 -- place only while we stand this close to the plot
local PLACE_WAIT = 0.8 -- how long a Place Friend may take to show in the save
local PLACE_BACKLOG = 3 -- trips pause while this many eggs wait in the inventory for a spot
local EQUIP_GAP = 3 -- seconds between two Equip Best fires (the game's own equip cooldown is a few seconds)
local BADSPOT = 60 -- an inventory item the server would not place is left alone this long
local WATCHDOG = 30

-- game -----------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().drillForEggsStop then
	getgenv().drillForEggsStop() -- re-running must not stack a second panel/loop
end

local env = getrenv and getrenv()._G
local t0 = os.clock()
while not (env and env._loaded and env._Lib) and os.clock() - t0 < 40 do
	task.wait(0.5)
end
local Lib = env and env._Lib
if not Lib then
	warn("[drill] the game's _Lib never loaded")
	return
end
local Shared, DB = Lib.Shared, Lib.Database
local Remotes = (function()
	local sm = ReplicatedStorage:WaitForChild("SharedModules", 10)
	local nw = sm and sm:WaitForChild("Network", 10)
	return nw and nw:WaitForChild("Remotes", 10)
end)()
if not Remotes then
	warn("[drill] the Network.Remotes folder is missing: the game changed")
	return
end

local ZONE_ORDER = Shared.ZONE_ORDER or { "Common", "Rare", "Epic", "Legendary", "Mythic", "Secret", "Brainrot god", "OG", "Divine", "Transcendent", "Ancient", "Elemental" }
local RANK = {}
for i, z in ipairs(ZONE_ORDER) do
	RANK[z] = i
end

-- egg model name -> rarity, from the game's own database
local EGG_RARITY = {}
for _, v in pairs(DB.Friends) do
	if type(v) == "table" and v.AnimalEgg and v.Name and v.Rarity then
		EGG_RARITY[v.Name] = v.Rarity
	end
end
local function isEgg(id)
	local v = DB.Friends[id]
	return v ~= nil and (v.AnimalEgg == true or v.Type == "Lucky Block")
end

local function data()
	local ok, d = pcall(function()
		return Lib.Data:Get()
	end)
	return ok and d or nil
end

local function fire(name, ...)
	local r = Remotes:FindFirstChild(name)
	if not r then
		return false
	end
	local args = table.pack(...)
	return (pcall(function()
		r:FireServer(table.unpack(args, 1, args.n))
	end))
end

-- InvokeServer has no timeout and pcall does not bound a yield: give up on a clock instead
local function invoke(name, timeout, ...)
	local r = Remotes:FindFirstChild(name)
	if not r then
		return nil
	end
	local args, done, res = table.pack(...), false, nil
	task.spawn(function()
		res = table.pack(pcall(function()
			return r:InvokeServer(table.unpack(args, 1, args.n))
		end))
		done = true
	end)
	local start = os.clock()
	while not done and os.clock() - start < timeout do
		task.wait(0.05)
	end
	return done and res or nil
end

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
assert(fmt(25000) == "25K" and fmt(1500) == "1.5K" and fmt(100) == "100", "fmt")

-- BrokenWalls is a string naming the zones whose wall is down; read it by containment
local function parseBroken(s)
	local out = {}
	if type(s) == "string" then
		for _, z in ipairs(ZONE_ORDER) do
			if s:find(z, 1, true) then
				out[z] = true
			end
		end
	end
	return out
end
assert(parseBroken("Common,Rare").Rare and parseBroken("Common").Common and not parseBroken("Common").Rare and next(parseBroken(nil)) == nil, "parseBroken")

local function broken()
	return parseBroken(player:GetAttribute("BrokenWalls"))
end

local stats = { trips = 0, banked = 0, missed = 0, placed = 0, hatched = 0, sold = 0, walls = 0, rebirths = 0, reverts = 0, pens = 0, drills = 0, bankSum = 0, bankMax = 0 }
local note = "idle"
local function say(text)
	note = text
end
local seen = {}
local function first(tag, ...) -- the first time an unproven branch runs, say so with its numbers
	if not seen[tag] then
		seen[tag] = true
		print("[drill] first " .. tag, ...)
	end
end

-- breadcrumbs: every loop marks its step, a watchdog names the one that stopped moving
local marks = {}
local function step(loop, what)
	marks[loop] = { what, os.clock() }
end

local running = true
local conns = {}
local want = {
	farm = false, place = false, hatch = false, sell = false, gate = false, equip = false,
	train = false, drill = false, trainUp = false, pen = false, walls = false, rebirth = false,
}
local zoneOn, rarityOn = {}, {}

local function root()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hum and hrp and hum.Health > 0 then
		return hrp, hum
	end
	return nil, nil
end

local function carrying()
	local char = player.Character
	return char and tonumber(char:GetAttribute("CarryingEggs")) or 0
end

-- world ----------------------------------------------------------------------
local function myPlot()
	local plots = workspace:FindFirstChild("Plots")
	if not plots then
		return nil
	end
	for _, p in ipairs(plots:GetChildren()) do
		local o = p:FindFirstChild("owner")
		if o and o.Value == player.Name then
			return p, p:FindFirstChild("Base")
		end
	end
	return nil
end

local function homePos()
	local _, base = myPlot()
	return base and base.Position + Vector3.new(0, 4, 0) or nil
end

local function trainPos()
	local plot = myPlot()
	local zone = plot and plot:FindFirstChild("LevelUpTouchZone")
	zone = zone and zone:FindFirstChild("Corners")
	zone = zone and zone:FindFirstChild("Zone")
	return zone and Vector3.new(zone.Position.X, 4, zone.Position.Z) or nil
end

local function slots(d)
	return Shared.getPlotSlots(d.BaseLevel or 0)
end

local function counts(d)
	local animals, eggs = 0, 0
	for _, f in pairs(d.PlotFriends) do
		if f.incubating then
			eggs += 1
		else
			animals += 1
		end
	end
	return animals, eggs
end

-- teleport -------------------------------------------------------------------
local slowUntil, revertRun = 0, 0
-- True when we are where we aimed. The legs are short because a long hop is a kick elsewhere in this family of games.
local function tpTo(pos)
	local slow = os.clock() < slowUntil
	local leg, gap = slow and SLOW_LEG or LEG, slow and SLOW_GAP or LEG_GAP
	for _ = 1, 60 do
		local hrp = root()
		if not hrp then
			return false
		end
		local d = pos - hrp.Position
		if d.Magnitude <= 2 then
			break
		end
		local nxt = d.Magnitude > leg and hrp.Position + d.Unit * leg or pos
		hrp.CFrame = CFrame.new(nxt)
		hrp.AssemblyLinearVelocity = Vector3.zero
		task.wait(gap)
	end
	local hrp = root()
	if hrp and (hrp.Position - pos).Magnitude <= REVERT then
		revertRun = 0
		return true
	end
	revertRun += 1
	stats.reverts += 1
	if revertRun >= REVERT_LIMIT then
		revertRun = 0
		slowUntil = os.clock() + SLOW_FOR
		warn(("[drill] %d teleports in a row did not stick: gliding in %d-stud legs for %ds"):format(REVERT_LIMIT, SLOW_LEG, SLOW_FOR))
	end
	return false
end

-- farm -----------------------------------------------------------------------
local benched = setmetatable({}, { __mode = "k" })

local function eggPos(m)
	local rp = m:FindFirstChild("RootPart")
	if rp then
		return rp.Position
	end
	local p = m:GetPivot().Position
	return p.Magnitude > 1 and p or nil
end

local function rarityOf(m)
	local r = EGG_RARITY[m.Name]
	if r then
		return r
	end
	local bb = m:FindFirstChild("FriendBillboard")
	local lbl = bb and bb:FindFirstChild("Rarity", true)
	return lbl and lbl.Text or nil
end

-- Best rarity first, then the closest to where we stand. Returns the egg, or nil and why not.
local function pickEgg()
	local folder = workspace:FindFirstChild("Live") and workspace.Live:FindFirstChild("Friends")
	local hrp = root()
	if not (folder and hrp) then
		return nil, "no eggs folder"
	end
	local open = broken()
	local nowT, best, bestRank, bestDist = workspace:GetServerTimeNow(), nil, -1, 0
	local locked, total = {}, 0
	for _, m in ipairs(folder:GetChildren()) do
		local zone = m:GetAttribute("SpawnZone")
		local rarity = rarityOf(m)
		if zone and zoneOn[zone] and (rarity == nil or rarityOn[rarity]) then
			total += 1
			if not open[zone] then
				locked[zone] = true
			elseif (benched[m] or 0) <= os.clock() and ((m:GetAttribute("timer") or math.huge) - nowT) > MIN_TIMER then
				local p = eggPos(m)
				if p then
					local rank, dist = RANK[rarity or ""] or 0, (p - hrp.Position).Magnitude
					if rank > bestRank or (rank == bestRank and dist < bestDist) then
						best, bestRank, bestDist = m, rank, dist
					end
				end
			end
		end
	end
	if best then
		return best
	end
	local names = {}
	for z in pairs(locked) do
		names[#names + 1] = z
	end
	table.sort(names, function(a, b)
		return RANK[a] < RANK[b]
	end)
	if #names > 0 and total > 0 then
		return nil, "locked: " .. table.concat(names, ", ") .. " (break the wall)"
	end
	return nil, "no egg in the ticked zones and rarities"
end

local function goHome()
	local home = homePos()
	if not home then
		return false
	end
	for _ = 1, 3 do
		if tpTo(home) then
			return true
		end
	end
	return false
end

local function freeSlots(d)
	local animals, eggs = counts(d)
	return slots(d) - animals - eggs
end

-- One trip: land at the egg, press, and come straight home. Returns true when an egg is banked, false when the
-- press never took (the egg is benched), nil when the trip did not start.
local function trip(egg)
	step("dir", "trip " .. egg.Name)
	local pos = eggPos(egg)
	if not pos then
		benched[egg] = os.clock() + BENCH
		return nil
	end
	stats.trips += 1
	say("to " .. egg.Name .. " (" .. tostring(egg:GetAttribute("SpawnZone")) .. ")")
	-- the confirm is a NEW egg uid in the inventory: a count would be moved by the sell and hatch loops mid-trip
	local before = {}
	local d0 = data()
	for _, f in ipairs(d0 and d0.Inventory.Friends or {}) do
		before[f.uid] = true
	end
	if not tpTo(pos + EGG_OFFSET) then
		benched[egg] = os.clock() + BENCH
		return nil
	end
	step("dir", "press " .. egg.Name)
	local got = false
	for _ = 1, GRAB_TRIES do
		if not egg.Parent then
			break
		end
		local hrp = root()
		local rp = egg:FindFirstChild("RootPart")
		if hrp and rp and (rp.Position - hrp.Position).Magnitude > 8 then
			tpTo(rp.Position + EGG_OFFSET) -- it wandered off
		end
		local pr = egg:FindFirstChildWhichIsA("ProximityPrompt", true)
		if pr then
			pcall(function()
				pr.RequiresLineOfSight = false
				fireproximityprompt(pr)
			end)
		end
		local start = os.clock()
		while os.clock() - start < GRAB_WAIT and carrying() == 0 do
			task.wait(0.03)
		end
		if carrying() > 0 then
			got = true
			break
		end
		task.wait(GRAB_GAP)
	end
	if not got then
		benched[egg] = os.clock() + BENCH
		stats.missed += 1
		first("miss", egg.Name, egg:GetAttribute("SpawnZone"), "parent", tostring(egg.Parent))
		return false
	end
	step("dir", "home")
	goHome()
	local start = os.clock()
	while os.clock() - start < BANK_WAIT do
		local d = data()
		local fresh = false
		for _, f in ipairs(d and d.Inventory.Friends or {}) do
			if not before[f.uid] and isEgg(f.id) then
				fresh = true
				break
			end
		end
		if fresh then
			local lat = os.clock() - start
			stats.banked += 1
			stats.bankSum += lat
			stats.bankMax = math.max(stats.bankMax, lat)
			first("bank", egg.Name, ("%.2fs"):format(lat))
			return true
		end
		task.wait(0.05)
	end
	warn("[drill] went home with " .. egg.Name .. " but nothing reached the inventory (carry " .. carrying() .. ")")
	return false
end

-- place ----------------------------------------------------------------------
local badUntil = {}
local placing = false

local function freeSpot(base, d)
	local used = {}
	for _, f in pairs(d.PlotFriends) do
		if f.pos then
			used[#used + 1] = f.pos
		end
	end
	local hx = base.Size.X / 2 - PLACE_MARGIN
	local hz = base.Size.Z / 2 - PLACE_MARGIN
	local z = -hz
	while z <= hz do
		local x = -hx
		while x <= hx do
			local ok = true
			for _, u in ipairs(used) do
				if (u.x - x) ^ 2 + (u.z - z) ^ 2 < (PLACE_STEP * 0.9) ^ 2 then
					ok = false
					break
				end
			end
			if ok then
				return x, z
			end
			x += PLACE_STEP
		end
		z += PLACE_STEP
	end
	return nil
end

local function inventoryEggs(d)
	local out = {}
	for _, f in ipairs(d.Inventory.Friends) do
		if isEgg(f.id) then
			out[#out + 1] = f
		end
	end
	-- the rarest first, as the farm takes them
	table.sort(out, function(a, b)
		return (RANK[(DB.Friends[a.id] or {}).Rarity or ""] or 0) > (RANK[(DB.Friends[b.id] or {}).Rarity or ""] or 0)
	end)
	return out
end

local function inventoryAnimals(d)
	local n = 0
	for _, f in ipairs(d.Inventory.Friends) do
		if not isEgg(f.id) then
			n += 1
		end
	end
	return n
end

-- Equip Best puts the strongest animals of plot + inventory on the plot and leaves the weaker ones in the inventory
-- (probed: Pickup Friend took an animal off, Equip Best put it back). Throttled: the game has an equip cooldown.
local lastEquip = 0
local function equipBest()
	if os.clock() - lastEquip < EQUIP_GAP then
		return false
	end
	lastEquip = os.clock()
	first("equip best")
	fire("Equip Best")
	task.wait(0.8)
	return true
end

-- Puts every egg of the inventory on a free spot of the plot, the rarest first.
local function placeAll()
	if placing then
		return
	end
	local _, base = myPlot()
	local hrp = root()
	local d = data()
	if not (base and hrp and d) or (hrp.Position - base.Position).Magnitude > PLACE_RANGE then
		return
	end
	placing = true
	step("place", "pass")
	local ok, err = pcall(function()
		for _, f in ipairs(inventoryEggs(d)) do
			if (badUntil[f.uid] or 0) <= os.clock() then
				local x, z = freeSpot(base, data() or d)
				if not x then
					say("plot: no free spot")
					break
				end
				fire("Place Friend", f.uid, x, z)
				local start = os.clock()
				local landed = false
				while os.clock() - start < PLACE_WAIT do
					local cur = data()
					if cur and cur.PlotFriends[f.uid] then
						landed = true
						break
					end
					task.wait(0.05)
				end
				if landed then
					stats.placed += 1
					first("place", f.id, ("%.1f,%.1f"):format(x, z))
				else
					badUntil[f.uid] = os.clock() + BADSPOT
					warn("[drill] Place Friend was not taken for egg " .. tostring(f.id))
				end
			end
		end
	end)
	placing = false
	marks.place = nil
	if not ok then
		warn("[drill] place threw:", err)
	end
end

-- hatch ----------------------------------------------------------------------
local function hatchPass()
	local d = data()
	if not d then
		return
	end
	local now = os.time()
	for uid, f in pairs(d.PlotFriends) do
		if f.incubating and f.finishTime and now >= f.finishTime then
			local hrp, base = root(), select(2, myPlot())
			first("hatch", f.id, "from", base and hrp and ("%.0f studs"):format((hrp.Position - base.Position).Magnitude) or "?")
			fire("Open Lucky Block", uid) -- never Skip Incubation: that one is a Robux product
			stats.hatched += 1
			task.wait(HATCH_GAP)
		end
	end
	-- a hatch with the pen full lands the animal in the inventory: let the game put the best ones on the plot
	local cur = data()
	if cur and inventoryAnimals(cur) > 0 then
		equipBest()
	end
end

-- sell -----------------------------------------------------------------------
local function sellPass()
	local d = data()
	if not d or inventoryAnimals(d) == 0 then
		return
	end
	-- what Equip Best leaves in the inventory is weaker than what stands on the plot: that is the overflow
	equipBest()
	d = data()
	if not d or freeSlots(d) > 0 then
		return
	end
	for _, f in ipairs(d.Inventory.Friends) do
		if not isEgg(f.id) then
			first("sell", f.id, DB.Friends[f.id] and DB.Friends[f.id].Name)
			fire("Sell Friend From Inventory", f.uid)
			stats.sold += 1
			task.wait(SELL_GAP)
		end
	end
end

-- upgrades -------------------------------------------------------------------
local function upgradePass()
	local d = data()
	if not d then
		return
	end
	local cap = Shared.getDrillUpgradeCap(d)
	if want.drill then
		-- the highest drill we can pay for: the cap is the highest id owned, so skipping the cheaper ones costs nothing
		local best, price
		for i = cap + 1, 40 do
			local e = DB.Dumbells["Dumbell_" .. i]
			if e and e.Price and e.Price > 0 then
				if e.Price <= d.Cash then
					best, price = i, e.Price
				else
					break
				end
			end
		end
		if best then
			first("drill", "Dumbell_" .. best, fmt(price))
			fire("Buy Dumbell", "Dumbell_" .. best) -- cash only: the RobuxID route is never fired
			stats.drills += 1
			task.wait(0.5)
			d = data() or d
			cap = Shared.getDrillUpgradeCap(d)
		end
	end
	if want.trainUp then
		-- free, capped by the drill cap
		for _ = 1, 12 do
			local cur = data()
			if not cur or (cur.AutoTrainTier or 0) >= cap or not DB.AutoTrainTiers[(cur.AutoTrainTier or 0) + 1] then
				break
			end
			local lvl = cur.AutoTrainTier or 0
			fire("Upgrade AutoTrainer")
			task.wait(UPGRADE_GAP)
			if ((data() or cur).AutoTrainTier or 0) == lvl then
				break
			end
		end
		for _ = 1, 12 do
			local cur = data()
			if not cur or (cur.WalkSpeedLevel or 0) >= cap or not DB.WalkSpeedTiers[(cur.WalkSpeedLevel or 0) + 1] then
				break
			end
			local lvl = cur.WalkSpeedLevel or 0
			fire("Upgrade WalkSpeed")
			task.wait(UPGRADE_GAP)
			if ((data() or cur).WalkSpeedLevel or 0) == lvl then
				break
			end
		end
	end
	if want.pen then
		local cur = data() or d
		local level = cur.BaseLevel or 0
		local nextLevel = level + 1
		local maxLevel = Shared.MAX_PLOT_LEVEL or 14
		local price = DB.BaseLevelPrices[nextLevel] or 0
		if nextLevel <= maxLevel and cap >= Shared.getPlotDrillRequirement(nextLevel) and cur.Cash >= price then
			local res = invoke("Purchase Floor", 5, nextLevel)
			first("pen", nextLevel, res and tostring(res[2]) or "no answer", res and tostring(res[3]) or "")
			if ((data() or cur).BaseLevel or 0) > level then
				stats.pens += 1
			end
		end
	end
end

-- walls ----------------------------------------------------------------------
local wallBench = {}

-- The first closed zone, its floor, and whether Strength reaches it. Zones open in order and cost more each, so only
-- the first closed one can be affordable.
local function nextWall()
	local d = data()
	local floors = workspace:FindFirstChild("Floors")
	if not (d and floors) then
		return nil
	end
	local open = broken()
	for _, z in ipairs(ZONE_ORDER) do
		if not open[z] then
			local f = floors:FindFirstChild(z)
			local need = f and f:GetAttribute("RequiredPower")
			if need and f:GetAttribute("HPx15") then
				need /= HP_DIV -- the client's HP bar is 15x what the server asks for (probed on five walls)
			end
			return z, f, need, need ~= nil and (d.Strength or 0) >= need
		end
	end
	return nil
end

-- The server wants us at the wall: probed, Legendary was refused from home at 2.2x its power and taken within ~1s of
-- standing on its floor. So TP onto the floor, let the position land, fire until BrokenWalls names the zone, go home.
local function wallTrip(z, f, need)
	step("dir", "wall " .. z)
	say("breaking the " .. z .. " wall")
	local top = f.Position + Vector3.new(0, f.Size.Y / 2 + 3, 0)
	if not tpTo(top) then
		wallBench[z] = os.clock() + BENCH
		return
	end
	task.wait(WALL_SETTLE)
	local ok = false
	for _ = 1, WALL_TRIES do
		fire("Wall Broken", z, false)
		local start = os.clock()
		while os.clock() - start < WALL_WAIT and not broken()[z] do
			task.wait(0.05)
		end
		if broken()[z] then
			ok = true
			break
		end
	end
	if ok then
		stats.walls += 1
		first("wall", z, fmt(need), "at", fmt((data() or {}).Strength or 0))
	else
		wallBench[z] = os.clock() + WALL_RETRY
		warn(("[drill] the %s wall did not break at Strength %s (needs %s)"):format(z, fmt((data() or {}).Strength or 0), fmt(need)))
	end
	goHome()
end

-- rebirth --------------------------------------------------------------------
local function rebirthPass()
	local d = data()
	if not d then
		return
	end
	local cur = d.Rebirth or 0
	local nxt = DB.Rebirths[cur + 1]
	if not nxt or (d.Strength or 0) < nxt.StrengthRequirement then
		return
	end
	local mult = cur > 0 and DB.Rebirths[cur] and DB.Rebirths[cur].CashMulti or 1
	if nxt.CashMulti / mult < REBIRTH_MIN_GAIN then
		return
	end
	-- Strength resets to 0 and walls need it: a wall that is nearly affordable goes first
	if want.walls then
		local z, _, need = nextWall()
		if z and need and need <= d.Strength * WALL_FACTOR then
			say("rebirth waits for the " .. z .. " wall")
			return
		end
	end
	first("rebirth", cur + 1, "Strength", fmt(d.Strength))
	fire("Rebirth")
	stats.rebirths += 1
	task.wait(1)
end

-- train ----------------------------------------------------------------------
local function parkTraining()
	local pos = trainPos()
	if not pos then
		say("train: no training zone on the plot")
		return
	end
	if not player:GetAttribute("InTrainingZone") then
		step("dir", "park")
		tpTo(pos)
	end
	say("training")
end

-- director -------------------------------------------------------------------
-- One thread owns the character: an egg trip, else the training zone. Everything that does not move us
-- (hatch, upgrades, walls, rebirth, sell, clicks) runs on its own thread.
local misses = 0
local function tick()
	local hrp = root()
	if not hrp then
		say("waiting for the character")
		task.wait(1)
		return
	end
	if carrying() > 0 then
		step("dir", "carrying: home")
		goHome()
		task.wait(0.3)
		return
	end
	local d = data()
	if want.walls then
		local z, f, need, can = nextWall()
		if z and can and (wallBench[z] or 0) <= os.clock() then
			wallTrip(z, f, need)
			return
		end
	end
	if want.farm and d then
		if want.gate and freeSlots(d) <= 0 then
			say("farm paused: pen full")
		elseif want.place and #inventoryEggs(d) >= PLACE_BACKLOG then
			-- eggs we cannot place are trips for nothing; spots free up as eggs hatch
			say("farm paused: " .. #inventoryEggs(d) .. " eggs wait for a spot")
		else
			local egg, why = pickEgg()
			if egg then
				local ok = trip(egg)
				if ok then
					misses = 0
					if want.place then
						placeAll()
					end
				elseif ok == false then
					misses += 1
					if misses >= MAX_MISSES then
						misses = 0
						goHome()
					end
				end
				task.wait(TRIP_REST)
				return
			end
			say(why)
		end
	end
	if want.place then
		placeAll() -- eggs left in the inventory while Auto Farm is off
	end
	if want.train then
		parkTraining()
	elseif not want.farm then
		say("idle")
	end
end

local function loop(name, every, want_, fn)
	task.spawn(function()
		while running do
			if want_() then
				step(name, "pass")
				local ok, err = pcall(fn)
				if not ok then
					warn(("[drill] %s threw: %s"):format(name, tostring(err)))
				end
			else
				marks[name] = nil
			end
			task.wait(every)
		end
	end)
end

task.spawn(function()
	while running do
		step("dir", "tick")
		local ok, err = pcall(tick)
		if not ok then
			warn("[drill] director threw:", err)
			task.wait(1)
		end
		task.wait(TICK)
	end
end)
loop("hatch", HATCH_EVERY, function()
	return want.hatch
end, hatchPass)
loop("equip", EQUIP_EVERY, function()
	return want.equip
end, function()
	local d = data()
	if d and inventoryAnimals(d) > 0 then
		equipBest()
	end
end)
loop("sell", SELL_EVERY, function()
	return want.sell
end, sellPass)
loop("upgrade", UPGRADE_EVERY, function()
	return want.drill or want.trainUp or want.pen
end, upgradePass)
loop("rebirth", REBIRTH_EVERY, function()
	return want.rebirth
end, rebirthPass)

-- clicks: outside the zone they pay the drill's strength, inside it x the AutoTrainer tier
task.spawn(function()
	while running do
		if want.train and not player:GetAttribute("holdingFriend") then
			fire("Activate Dumbell", "auto")
			task.wait(CLICK_GAP)
		else
			task.wait(0.25)
		end
	end
end)

-- watchdog -------------------------------------------------------------------
task.spawn(function()
	local nextStats = os.clock() + STATS_EVERY
	while running do
		task.wait(5)
		if os.clock() >= nextStats then
			nextStats = os.clock() + STATS_EVERY
			print(("[drill] trips %d banked %d (bank avg %.2fs max %.2fs) missed %d placed %d hatched %d sold %d walls %d pens %d drills %d rebirths %d reverts %d | %s"):format(
				stats.trips, stats.banked, stats.banked > 0 and stats.bankSum / stats.banked or 0, stats.bankMax, stats.missed, stats.placed,
				stats.hatched, stats.sold, stats.walls, stats.pens, stats.drills, stats.rebirths, stats.reverts, note))
		end
		for name, m in pairs(marks) do
			if os.clock() - m[2] > WATCHDOG then
				warn(("[drill] %s stuck %ds at: %s"):format(name, os.clock() - m[2], m[1]))
				m[2] = os.clock()
			end
		end
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Drill for Eggs", statusBar = true })
if not Window then
	running = false
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "egg")
local Eggs = Tab:AddLeftGroupbox("Eggs", "egg")
local Grow = Tab:AddRightGroupbox("Grow", "trending-up")

local function toggle(box, idx, text, tip, key)
	return box:AddToggle(idx, {
		Text = text,
		Tooltip = tip,
		Default = false,
		Callback = function(state)
			want[key] = state
		end,
	})
end

-- a Multi dropdown hands over a map ({ label = true }); some builds a list. Read both.
local function ticked(v)
	local out = {}
	for k, val in pairs(v or {}) do
		if type(k) == "number" then
			out[val] = true
		elseif val then
			out[k] = true
		end
	end
	return out
end
assert(ticked({ "a" }).a and ticked({ a = true }).a and not ticked({ a = false }).a, "ticked")

local function fill(set, picked)
	table.clear(set)
	for label in pairs(ticked(picked)) do
		set[label] = true
	end
end

toggle(Eggs, "Farm", "Auto Farm Eggs", "Teleports to the best egg of the ticked zones and rarities, grabs it and teleports home to bank it: ~0.8s a trip. Zones whose wall is still up are skipped", "farm")
for _, z in ipairs(ZONE_ORDER) do
	zoneOn[z], rarityOn[z] = true, true -- Default does not fire the callback, so arm the sets by hand
end
Eggs:AddDropdown("Zones", {
	Text = "Zones",
	Tooltip = "Which pits Auto Farm visits. A pit opens when its wall is broken (Auto Break Walls, or drill it yourself)",
	Values = ZONE_ORDER,
	Default = ZONE_ORDER,
	Multi = true,
	Callback = function(picked)
		fill(zoneOn, picked)
	end,
})
Eggs:AddDropdown("Rarities", {
	Text = "Egg rarities",
	Tooltip = "Which eggs Auto Farm takes, whatever pit they sit in. The rarest goes first, then the closest",
	Values = ZONE_ORDER,
	Default = ZONE_ORDER,
	Multi = true,
	Callback = function(picked)
		fill(rarityOn, picked)
	end,
})
toggle(Eggs, "Place", "Auto Place Eggs", "Puts every banked egg on a free spot of your plot, right after each trip", "place")
toggle(Eggs, "Hatch", "Auto Hatch Eggs", "Opens every egg of yours the moment its timer is up (never the Robux Skip)", "hatch")
toggle(Eggs, "Sell", "Sell Overflow Animals", "With the pen full a hatched animal lands in your inventory: Equip Best puts the strongest on the plot, then the weaker ones are sold", "sell")
toggle(Eggs, "Gate", "Pause Trips When Pen Full", "Skips egg trips while animals plus growing eggs fill every slot, so no trip ends in overflow", "gate")

toggle(Grow, "Equip", "Auto Equip Best", "Whenever an animal sits in your inventory, the game's Equip Best puts the strongest animals on the plot. Works on its own, with or without Auto Hatch and Sell", "equip")
toggle(Grow, "Train", "Auto Train", "Fires clicks at ~9/s and parks you in your plot's training zone when no egg trip needs you (x the AutoTrainer tier there)", "train")
toggle(Grow, "Drill", "Auto Upgrade Drill", "Buys the best drill you can pay for in cash: stronger clicks, and it raises the cap of every other upgrade", "drill")
toggle(Grow, "TrainUp", "Auto Upgrade Train", "Free AutoTrainer ore tiers and WalkSpeed levels, up to the drill cap", "trainUp")
toggle(Grow, "Pen", "Auto Upgrade Pen", "Expands the farm (more animal slots) whenever your drill allows the next level. Free", "pen")
toggle(Grow, "Walls", "Auto Break Walls", "Breaks the next pit's wall as soon as Strength reaches its power", "walls")
toggle(Grow, "Rebirth", "Auto Rebirth", "Rebirths when Strength reaches the requirement (cash multiplier). Resets Strength only; waits while the next wall is within reach", "rebirth")

table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		local vu = game:GetService("VirtualUser")
		vu:CaptureController()
		vu:ClickButton2(Vector2.new())
	end)
end))

local nextStrip = 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	local t = os.clock()
	if t < nextStrip then
		return
	end
	nextStrip = t + 0.5
	local d = data()
	if not d then
		return
	end
	local animals, eggs = counts(d)
	local open = 0
	for _ in pairs(broken()) do
		open += 1
	end
	pcall(Window.SetStatus, Window, {
		{ "Cash", fmt(d.Cash) },
		{ "Power", fmt(d.Strength) },
		{ "Drill", Shared.getDrillUpgradeCap(d) .. "/40" },
		{ "Walls", open .. "/" .. #ZONE_ORDER },
		{ "Pen", animals .. "/" .. slots(d) .. " +" .. eggs },
		{ "Banked", stats.banked },
		{ "Rebirth", d.Rebirth or 0 },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("DrillForEggs", {})

-- close ----------------------------------------------------------------------
local function stopAll()
	running = false
	for k in pairs(want) do
		want[k] = false
	end
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().drillForEggsStop = nil
end)

getgenv().drillForEggsStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().drillForEggsStop = nil
end
