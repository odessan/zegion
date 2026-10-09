--[[ Sword to Loot -- farm Power or dungeon loot, forge the best sword, sell, armor, rebirth, claims (106053668011557)

     FARM    : two modes, one toggle. "Training dummy" stands beside the best dummy your rebirths unlock and
               lets the game's own auto-attack hit it (the game swings by itself when a dummy is in reach):
               measured ~600 Power/s at tier 2. "Dungeon" walks the corridor stage by stage (Workspace.StageCheck),
               waits for the stage to clear, picks up the drops (Pickup is range-checked by the server: "Too far
               away" at 19 studs) and, when the carry is full, the stage cap is hit or health drops, teleports to
               the spawn and calls StageService.Return, the game's own Return button. Drops of a stage are lost
               when the next one clears, so they are picked before moving on. Death wipes the carry.
     FORGE   : ForgeService.BeginForge(materials) -> Hammer(sessionId) per swing -> FinishForge(1, nil, sessionId).
               The cut and the mesh profile are client visuals; the server took a forge with no profile (probed:
               W32, mult 5.3). A sword's mult is the AVERAGE of its materials' Multiple (MaterialHelper
               .blendMultiplier; probed: (4.6+6.5+4.8)/3 = 5.3 = the server's answer), so the best sword is the
               top-Multiple materials, as few as the minimum 3. Each forge takes the best remaining ones.
     EQUIP   : WeaponInvService.Equip(uid) for the highest-mult sword (probed, the held Tool swaps).
     SELL    : swords other than the equipped best and the locked ones (SellBatch), and optionally materials
               beyond the best N (Sell). Position-free, probed from 100 studs away.
     ARMOR   : ArmorService.Buy(id) for the most expensive armor you can afford above your best (probed A3).
     REBIRTH : ProgressService.Rebirth() when LevelHelper.getLevel(power) reaches the next RequireLevel (probed:
               #3 at level 83, resets Power, +2500 coins). Online rewards are claimed first (they scale with Power).
     CLAIMS  : OnlineRewardService.Claim("OLn") for every reached tier (probed OL1: +10532 Power) and
               IndexService.Claim("IRn") for every reached tier (probed IR2: +1 bag slot).

     Movement: on foot (Humanoid:MoveTo + pathfinding) plus the game's own Return teleport. Probed hops: 5..80
     studs stuck, 130 reverted a second later, so "Hop between stages" (off by default) chains 70-stud hops.
     Training dummies 7-9 are Robux tiers: never stood next to.
     Not wired: DailyRewardService.Claim (works the same way, ask), Robux upgrades (UpgradeService.PromptRobux).

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().swordToLootStop() ]]

-- config ---------------------------------------------------------------------
local CALL_GAP = 0.12 -- least gap between any two remote calls; a burst of kinds is the kick shape in sister games
local CALL_TIMEOUT = 10 -- an invoke that never returns is given up on after this
local HAMMER_GAP = 0.65 -- between Hammer calls; the server wants at least 0.5 (hammerUnlockAt), raise if swings are refused
local FORGE_EVERY = 2
local SELL_EVERY = 4
local ARMOR_EVERY = 3
local REBIRTH_EVERY = 5
local REWARD_EVERY = 10
local EQUIP_EVERY = 5
local INDEX_EVERY = 10
local FARM_BEAT = 0.5 -- the farm director's idle beat
local WALK_LEG = 4 -- one pathfinding waypoint may take this long before it is skipped
local DUMMY_STAND = 5 -- studs from the dummy to stand, on the side away from the Robux dummies
local HOP_STEP = 70 -- longest single hop of the optional teleport mode; 80 held in the probe, 130 reverted
local HOP_SETTLE = 0.35 -- wait after a hop, then check it held; raise if hops read as reverted
local HOP_MIN = 25 -- legs shorter than this are walked
local PICKUP_REACH = 8 -- walk to within this of a drop before Pickup (server refuses at ~19)
local DROP_WAIT = 1.5 -- after a clear, wait this long for the drops to appear before calling the stage empty
local CLEAR_WAIT = 20 -- a stage that is not cleared inside this is too hard: go home
local HURT = 0.5 -- go home from the dungeon below this health fraction
local HEAL_WAIT = 12 -- after a hurt trip wait up to this for health to come back
local WATCHDOG = 30 -- a loop whose step mark stops moving this long is reported

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local player = Players.LocalPlayer

if getgenv and getgenv().swordToLootStop then
	getgenv().swordToLootStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[swordtoloot]", ...)
end

local seen = {}
local function first(name, ...)
	if not seen[name] then
		seen[name] = true
		log("first", name, ...)
	end
end

-- The strip is drained from a Heartbeat (our own identity); a loop thread writing to the window
-- throws "lacking capability Plugin" after its first task.wait.
local note, lastSaid = "idle", nil
local function say(msg)
	note = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- game -----------------------------------------------------------------------
local okLoad, Knit, MaterialHelper, ArmorConfig, IndexRewardHelper, LevelHelper, RebirthHelper, TrainHelper =
	pcall(function()
		local H = ReplicatedStorage:WaitForChild("Helpers", 15)
		return require(ReplicatedStorage.Packages.Knit),
			require(H.MaterialHelper),
			require(H.ArmorHelper.ArmorConfig),
			require(H.IndexRewardHelper),
			require(H.LevelHelper),
			require(H.RebirthHelper),
			require(H.TrainHelper)
	end)
if not okLoad then
	warn("[swordtoloot] the game's modules did not load:", Knit)
	return
end
local DC = Knit.GetController("DataController")
local TZC = Knit.GetController("TrainZoneController")

local services = {}
-- Every remote call goes through here: one call per CALL_GAP slot (slots are reserved before yielding so two
-- loops cannot fire together), and a clock on the invoke so a parked handler cannot park the loop.
-- Returns what :await() returns: true, then whatever the server answered.
local nextCall = 0
local function rpc(service, method, ...)
	local now = os.clock()
	local at = math.max(now, nextCall)
	nextCall = at + CALL_GAP
	if at > now then
		task.wait(at - now)
	end
	local args, n = table.pack(...), select("#", ...)
	local result
	task.spawn(function()
		local okc, res = pcall(function()
			services[service] = services[service] or Knit.GetService(service)
			return table.pack(services[service][method](services[service], table.unpack(args, 1, n)):await())
		end)
		result = okc and res or table.pack(false, tostring(res))
	end)
	local t0 = os.clock()
	while not result and os.clock() - t0 < CALL_TIMEOUT do
		task.wait()
	end
	if not result then
		return false, "timeout"
	end
	return table.unpack(result, 1, result.n)
end

local function data()
	local ok, d = pcall(DC.GetAll, DC)
	return ok and type(d) == "table" and d or nil
end

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx" }
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

local stats = { forged = 0, sold = 0, armor = 0, rebirths = 0, claims = 0, trips = 0, drops = 0, equips = 0 }

-- breadcrumbs: every loop marks its step, a watchdog names the one that stopped moving
local marks = {}
local function step(loop, what)
	marks[loop] = { what, os.clock() }
end

-- loops ----------------------------------------------------------------------
-- One generation counter per toggle: off-then-on inside one interval must not leave the old thread alive.
local loops = {}
local function makeLoop(name, every, pass)
	local L = { on = false, gen = 0 }
	function L.set(state)
		L.on = state
		L.gen += 1
		if not state then
			marks[name] = nil
			return
		end
		local mine = L.gen
		task.spawn(function()
			while L.on and L.gen == mine do
				step(name, "pass")
				local okPass, err = pcall(pass, function()
					return L.on and L.gen == mine
				end)
				if not okPass then
					warn("[swordtoloot]", name, "pass threw:", err)
				end
				task.wait(every)
			end
		end)
	end
	loops[name] = L
	return L
end

-- character ------------------------------------------------------------------
local function root()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function humanoid()
	local c = player.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end
local function flat(a, b)
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- On foot: the dossier rates teleports kick-weighted. Pathfinds in waypoints, falls back to a straight
-- MoveTo when no path exists. Returns whether it ended within tol studs (horizontal) of dest.
local function walkTo(dest, alive, tol)
	tol = tol or 4
	local r, h = root(), humanoid()
	if not (r and h) or h.Health <= 0 then
		return false
	end
	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
	local okPath = pcall(function()
		path:ComputeAsync(r.Position, dest)
	end)
	local pts = { { Position = dest, Action = Enum.PathWaypointAction.Walk } }
	if okPath and path.Status == Enum.PathStatus.Success then
		pts = path:GetWaypoints()
	else
		first("nopath", tostring(dest))
	end
	for _, w in ipairs(pts) do
		if not alive() then
			return false
		end
		if w.Action == Enum.PathWaypointAction.Jump then
			h.Jump = true
		end
		h:MoveTo(w.Position)
		local t0, reissue = os.clock(), os.clock()
		r = root()
		while r and flat(r.Position, w.Position) > 3.5 and os.clock() - t0 < WALK_LEG do
			if not alive() or h.Health <= 0 then
				return false
			end
			task.wait(0.1)
			if os.clock() - reissue > 1.5 then
				reissue = os.clock()
				h:MoveTo(w.Position)
			end
			r = root()
		end
	end
	r = root()
	return r ~= nil and flat(r.Position, dest) <= tol
end

-- Optional: cover a long leg in hops of at most HOP_STEP studs (probed: 5..80 held, 130 reverted a second
-- later). A hop that does not hold turns hopping off for the session and the leg is walked.
local hopOn, hopBroken = false, false
local function travel(dest, alive, tol)
	if hopOn and not hopBroken then
		local c = player.Character
		local r = root()
		while c and r and alive() and flat(r.Position, dest) > HOP_MIN do
			local d = Vector3.new(dest.X - r.Position.X, 0, dest.Z - r.Position.Z)
			local stepLen = math.min(HOP_STEP, d.Magnitude)
			local spot = r.Position + d.Unit * stepLen
			c:PivotTo(CFrame.new(spot.X, dest.Y + 3, spot.Z))
			task.wait(HOP_SETTLE)
			r = root()
			if not r or flat(r.Position, spot) > 8 then
				hopBroken = true
				warn("[swordtoloot] a hop did not hold, walking from now on")
				break
			end
			first("hop", math.floor(stepLen))
		end
	end
	return walkTo(dest, alive, tol)
end

-- forge ----------------------------------------------------------------------
-- Pure: the n units with the highest score (ties by id), as {id=count}, their average score and the unit count.
local function pickUnits(bag, n, score)
	local ids = {}
	for id, c in pairs(bag) do
		if c > 0 then
			ids[#ids + 1] = id
		end
	end
	table.sort(ids, function(a, b)
		local sa, sb = score(a), score(b)
		if sa ~= sb then
			return sa > sb
		end
		return a < b
	end)
	local pick, left, sum = {}, n, 0
	for _, id in ipairs(ids) do
		if left <= 0 then
			break
		end
		local take = math.min(bag[id], left)
		pick[id] = take
		left -= take
		sum += score(id) * take
	end
	local units = n - left
	return pick, units > 0 and sum / units or 0, units
end
do
	local sc = { A = 4.6, B = 6.5, C = 4.8, D = 1 }
	local pick, avg, units = pickUnits({ A = 1, B = 1, C = 1, D = 5 }, 3, function(id)
		return sc[id]
	end)
	assert(pick.A == 1 and pick.B == 1 and pick.C == 1 and not pick.D and units == 3, "pickUnits takes the best")
	assert(math.abs(avg - 5.3) < 1e-9, "pickUnits averages (the probed forge: 5.3)")
	local _, _, short = pickUnits({ A = 1 }, 3, function()
		return 1
	end)
	assert(short == 1, "pickUnits reports a short bag")
end

local function materialScore(id)
	local info = MaterialHelper.getInfo(id)
	local mult = tonumber(info and info.Multiple) or 0
	local fx = 0
	for _ in ipairs(MaterialHelper.getEffects(id) or {}) do
		fx += 1
	end
	return mult + fx * 1e-3 -- the effect count only breaks ties: the sword's mult is the plain average
end

-- {id = count} of the materials in the bag a forge may use (not locked, usable in a normal forge)
local function forgeBag(d)
	local locks = (d.itemLocks and d.itemLocks.Material) or {}
	local bag = {}
	for _, b in ipairs(d.backpack or {}) do
		local id = b.id
		if type(id) == "string" and id:match("^M%d+$") and MaterialHelper.exists(id) and not locks[id]
			and MaterialHelper.canForgeWith(id, "Normal") then
			bag[id] = (bag[id] or 0) + (tonumber(b.count) or 0)
		end
	end
	return bag
end

local forgeUnits, forgeMinMult = 3, 0

local function forgeOnce()
	local d = data()
	if not d then
		return false
	end
	local minMats = (tonumber(forgeUnits) or 3)
	local pick, avg, units = pickUnits(forgeBag(d), minMats, materialScore)
	if units < minMats then
		say(("forge: %d/%d materials"):format(units, minMats))
		return false
	end
	if avg < forgeMinMult then
		say(("forge: best sword would be x%.2f, under your minimum"):format(avg))
		return false
	end
	step("forge", "begin")
	local ok, ctx, err = rpc("ForgeService", "BeginForge", pick)
	if not ok or type(ctx) ~= "table" or not ctx.sessionId then
		say("forge refused: " .. tostring(err or ctx))
		return false
	end
	first("beginforge", ctx.kind, ctx.rarity, ctx.mult, ctx.hammers)
	-- no alive() check from here: a session left open has to be finished (the whole run is ~4-6s)
	for i = 1, tonumber(ctx.hammers) or 6 do
		step("forge", "hammer " .. i)
		task.wait(HAMMER_GAP)
		local okH, rep = rpc("ForgeService", "Hammer", ctx.sessionId)
		if not okH or type(rep) ~= "table" then
			warn("[swordtoloot] hammer", i, "refused:", tostring(rep))
		end
	end
	step("forge", "finish")
	task.wait(HAMMER_GAP)
	local okF, entry = rpc("ForgeService", "FinishForge", 1, nil, ctx.sessionId)
	if okF and type(entry) == "table" then
		stats.forged += 1
		first("finishforge", entry.id, entry.mult)
		say(("forged %s x%.2f from %s"):format(tostring(entry.id), tonumber(entry.mult) or 0, fmt(units) .. " mats"))
		return true
	end
	warn("[swordtoloot] FinishForge refused:", tostring(entry))
	return false
end

makeLoop("forge", FORGE_EVERY, function(alive)
	while alive() and forgeOnce() do
		task.wait(0.2)
	end
end)

-- sell / equip ---------------------------------------------------------------
local function bestWeapon(d)
	local best, bm
	for uid, w in pairs(d.weapons or {}) do
		local m = tonumber(w.mult) or 0
		if not bm or m > bm then
			best, bm = uid, m
		end
	end
	return best, bm
end

local function equipBest()
	local d = data()
	if not d then
		return
	end
	local best = bestWeapon(d)
	if best and best ~= d.equippedWeapon then
		step("equip", "equip")
		local ok, res = rpc("WeaponInvService", "Equip", best)
		if ok and res == true then
			stats.equips += 1
			first("equip", d.weapons[best].id, d.weapons[best].mult)
		end
	end
end
makeLoop("equip", EQUIP_EVERY, equipBest)

makeLoop("sellW", SELL_EVERY, function()
	equipBest() -- never sell something better than what is held
	local d = data()
	if not d then
		return
	end
	local best = bestWeapon(d)
	local uids = {}
	for uid, w in pairs(d.weapons or {}) do
		if uid ~= d.equippedWeapon and uid ~= best and not w.locked then
			uids[#uids + 1] = uid
		end
	end
	if #uids == 0 then
		return
	end
	step("sellW", "sell " .. #uids)
	local ok, success, coins = rpc("WeaponInvService", "SellBatch", uids)
	first("sellbatch", ok, success, coins)
	if ok and success == true then
		stats.sold += #uids
		say(("sold %d swords for %s"):format(#uids, fmt(coins)))
	else
		warn("[swordtoloot] SellBatch refused:", tostring(success), tostring(coins))
	end
end)

makeLoop("sellM", SELL_EVERY, function()
	local d = data()
	if not d then
		return
	end
	local bag = forgeBag(d)
	local keep = pickUnits(bag, tonumber(forgeUnits) or 3, materialScore) -- what the next forge would use
	for id, c in pairs(bag) do
		local extra = c - (keep[id] or 0)
		if extra > 0 then
			step("sellM", "sell " .. id)
			local ok, success, coins = rpc("MaterialService", "Sell", id, extra)
			first("sellmat", id, extra, ok, success, coins)
			if ok and success == true then
				stats.sold += extra
			end
		end
	end
end)

-- armor ----------------------------------------------------------------------
makeLoop("armor", ARMOR_EVERY, function()
	local d = data()
	if not d then
		return
	end
	local owned = (d.armors and d.armors.owned) or {}
	local bestPrice = 0
	for id, has in pairs(owned) do
		local a = has and ArmorConfig[id]
		if a and a.Price > bestPrice then
			bestPrice = a.Price
		end
	end
	local pickId, pickPrice
	for id, a in pairs(ArmorConfig) do
		local p = a.Price
		if type(p) == "number" and not owned[id] and p > bestPrice and p <= (d.coins or 0)
			and (not pickPrice or p > pickPrice) then
			pickId, pickPrice = id, p
		end
	end
	if not pickId then
		return
	end
	step("armor", "buy " .. pickId)
	local ok, success, res = rpc("ArmorService", "Buy", pickId)
	if ok and success == true then
		stats.armor += 1
		say(("bought armor %s for %s"):format(pickId, fmt(pickPrice)))
		first("armor", pickId, pickPrice)
	else
		warn("[swordtoloot] armor refused:", pickId, tostring(success), tostring(res))
	end
end)

-- claims ---------------------------------------------------------------------
local function claimOnline()
	local ok, state = rpc("OnlineRewardService", "GetState")
	if not (ok and type(state) == "table" and type(state.tiers) == "table") then
		return
	end
	for _, t in ipairs(state.tiers) do
		if t.canClaim and not t.claimed then
			step("rewards", "claim " .. t.id)
			local okC, success, res = rpc("OnlineRewardService", "Claim", t.id)
			if okC and success == true then
				stats.claims += 1
				first("online", t.id)
				say("claimed online reward " .. t.id)
			else
				warn("[swordtoloot] online claim refused:", t.id, tostring(success), tostring(res))
			end
		end
	end
end
makeLoop("rewards", REWARD_EVERY, claimOnline)

makeLoop("index", INDEX_EVERY, function()
	local d = data()
	if not d then
		return
	end
	local idx = d.index or {}
	local claimed = idx.claimed or {}
	local collected = {}
	for _, ty in ipairs(IndexRewardHelper.getTypes()) do
		local n = 0
		for _, c in pairs(idx[ty:lower()] or {}) do
			if (tonumber(c) or 0) > 0 then
				n += 1
			end
		end
		collected[ty] = n
	end
	for _, id in ipairs(IndexRewardHelper.getList()) do
		local ty = IndexRewardHelper.getType(id)
		if not claimed[id] and collected[ty] and IndexRewardHelper.getCount(id) <= collected[ty] then
			step("index", "claim " .. id)
			local ok, success, res = rpc("IndexService", "Claim", id)
			if ok and success == true then
				stats.claims += 1
				first("index", id)
				say("claimed index " .. id)
			else
				warn("[swordtoloot] index claim refused:", id, tostring(success), tostring(res))
			end
		end
	end
end)

-- rebirth --------------------------------------------------------------------
makeLoop("rebirth", REBIRTH_EVERY, function()
	local d = data()
	if not d then
		return
	end
	local level = LevelHelper.getLevel(tonumber(d.power) or 0)
	if not RebirthHelper.canRebirth(level, tonumber(d.rebirths) or 0) then
		return
	end
	claimOnline() -- the SwordPower rewards scale with the Power a rebirth resets
	step("rebirth", "rebirth")
	local ok, success, res = rpc("ProgressService", "Rebirth")
	if ok and success == true then
		stats.rebirths += 1
		say(("rebirth #%s"):format(tostring(type(res) == "table" and res.rebirths or "?")))
		first("rebirth", type(res) == "table" and res.rebirths)
	else
		warn("[swordtoloot] rebirth refused:", tostring(success), tostring(res))
	end
end)

-- farm -----------------------------------------------------------------------
local farmMode, maxStage, pickFrom = "Dungeon", 3, 1

local function liveDummies()
	local live = workspace:FindFirstChild("Live")
	local mobs = live and live:FindFirstChild("Mob")
	local out = {}
	for _, m in ipairs(mobs and mobs:GetChildren() or {}) do
		if m:IsA("BasePart") and m:GetAttribute("Id") == "Dummy" then
			out[#out + 1] = m
		end
	end
	return out
end

-- Stand beside the best dummy the game says is yours, on the side away from the dummies that are not
-- (a locked one nearest to you pops the Robux purchase prompt).
local function dummySpot()
	local all, best, bb = liveDummies(), nil, -1
	local locked = {}
	for _, m in ipairs(all) do
		if TZC:IsUnlocked(m) then
			local b = TrainHelper.getBonus(tonumber(m:GetAttribute("TrainTier")) or 0) or 0
			if b > bb then
				best, bb = m, b
			end
		else
			locked[#locked + 1] = m.Position
		end
	end
	if not best then
		return nil
	end
	local away = Vector3.new(1, 0, 0)
	if #locked > 0 then
		local c = Vector3.zero
		for _, p in ipairs(locked) do
			c += p
		end
		c /= #locked
		local v = Vector3.new(best.Position.X - c.X, 0, best.Position.Z - c.Z)
		if v.Magnitude > 1 then
			away = v.Unit
		end
	end
	return best.Position + away * DUMMY_STAND, best
end

local function stageAttr()
	return tonumber(player:GetAttribute("DungeonStage")) or 1
end

local function stageMid(n)
	local sc = workspace:FindFirstChild("StageCheck")
	local a = sc and sc:FindFirstChild("Level" .. n)
	local b = sc and sc:FindFirstChild("Level" .. (n + 1))
	if not (a and b) then
		return nil
	end
	return Vector3.new((a.Position.X + b.Position.X) / 2, 45, (a.Position.Z + b.Position.Z) / 2)
end

local function healthy()
	local h = humanoid()
	return h ~= nil and h.Health > 0 and h.Health / math.max(h.MaxHealth, 1) >= HURT
end

-- the game's own Return button: teleport to the spawn, then StageService.Return banks the carry
local function goHome(why)
	local c, sp = player.Character, workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	if c and sp and humanoid() and humanoid().Health > 0 then
		c:PivotTo(sp.CFrame + Vector3.new(0, 3, 0))
	end
	local ok, success, banked = rpc("StageService", "Return")
	stats.trips += 1
	first("return", ok, success, banked)
	say(("home (%s), banked %s"):format(why, tostring(banked)))
end

local function collectDrops(alive)
	-- the stage counter ticks on the clear; the drops land a moment later (hopping got there first)
	local ok, list
	local t0 = os.clock()
	repeat
		ok, list = rpc("DropService", "GetMine")
		if ok and type(list) == "table" and #list > 0 then
			break
		end
		task.wait(0.2)
	until not alive() or os.clock() - t0 > DROP_WAIT
	if not ok or type(list) ~= "table" then
		return
	end
	log("stage", stageAttr() - 1, "drops on the ground:", #list, "carry", player:GetAttribute("PickupUsed"))
	table.sort(list, function(a, b)
		return (MaterialHelper.getPrice(a.matId) or 0) > (MaterialHelper.getPrice(b.matId) or 0)
	end)
	local limit = tonumber(player:GetAttribute("PickupLimit")) or 6
	for _, dr in ipairs(list) do
		if not alive() or not healthy() then
			return
		end
		if (tonumber(player:GetAttribute("PickupUsed")) or 0) >= limit then
			return
		end
		step("farm", "drop " .. tostring(dr.matId))
		local r = root()
		if r and flat(r.Position, dr.pos) > PICKUP_REACH then
			walkTo(dr.pos, alive, PICKUP_REACH - 1)
		end
		local okP, success, res = rpc("DropService", "Pickup", dr.id)
		if okP and success == true then
			stats.drops += 1
			first("pickup", dr.matId, res)
		else
			first("pickup-refused", tostring(res))
		end
	end
end

local function dungeonTrip(alive)
	local limit = tonumber(player:GetAttribute("PickupLimit")) or 6
	local j = stageAttr()
	while alive() do
		local target = stageMid(j)
		if not target then
			break -- past the last stage
		end
		step("farm", "walk to stage " .. j)
		say("dungeon: stage " .. j)
		travel(target, alive, 12)
		local t0 = os.clock()
		while alive() and healthy() and stageAttr() <= j and os.clock() - t0 < CLEAR_WAIT do
			task.wait(0.2)
		end
		if not alive() then
			return true -- stopped, not failed
		end
		if not healthy() then
			goHome("hurt")
			return true
		end
		if stageAttr() <= j then
			goHome("stage " .. j .. " not cleared")
			return true
		end
		if j >= pickFrom then
			collectDrops(alive)
		end
		if (tonumber(player:GetAttribute("PickupUsed")) or 0) >= limit then
			break
		end
		if j >= maxStage then
			break
		end
		j += 1
	end
	if player:GetAttribute("InDungeon") then
		goHome("trip done")
	end
	return true
end

makeLoop("farm", FARM_BEAT, function(alive)
	local h = humanoid()
	if not h or h.Health <= 0 or not root() then
		say("waiting for character")
		return
	end
	if farmMode == "Training dummy" then
		if player:GetAttribute("InDungeon") then
			goHome("to train")
			return
		end
		local spot = dummySpot()
		if not spot then
			say("no unlocked dummy in reach")
			return
		end
		if flat(root().Position, spot) > 3 then
			step("farm", "walk to dummy")
			say("walking to the dummy")
			walkTo(spot, alive, 3)
		else
			say("training")
		end
		return
	end
	if not player:GetAttribute("InDungeon") then
		if not healthy() then
			local t0 = os.clock()
			while alive() and not healthy() and os.clock() - t0 < HEAL_WAIT do
				task.wait(0.5)
			end
		end
		local first1 = stageMid(1)
		if not first1 then
			say("no StageCheck in the world")
			return
		end
		say("walking to the dungeon")
		travel(first1, alive, 12)
	end
	dungeonTrip(alive)
end)

-- watchdog -------------------------------------------------------------------
local watching = true
task.spawn(function()
	while watching do
		task.wait(5)
		for name, m in pairs(marks) do
			if loops[name] and loops[name].on and os.clock() - m[2] > WATCHDOG then
				warn(("[swordtoloot] %s stuck %ds at: %s"):format(name, os.clock() - m[2], m[1]))
				m[2] = os.clock()
			end
		end
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Sword to Loot", statusBar = true })
if not Window then
	watching = false
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "swords")
local Farm = Tab:AddLeftGroupbox("Farm", "swords")
local Craft = Tab:AddRightGroupbox("Forge and sell", "hammer")
local Prog = Tab:AddLeftGroupbox("Progress", "trending-up")

local function toggle(box, idx, text, tip, loopName)
	return box:AddToggle(idx, {
		Text = text,
		Tooltip = tip,
		Default = false,
		Callback = function(state)
			loops[loopName].set(state)
		end,
	})
end

toggle(Farm, "Farm", "Auto Farm", "Runs the mode picked below", "farm")
Farm:AddDropdown("Mode", {
	Text = "Farm mode",
	Tooltip = "Training dummy: stand beside the best dummy you have unlocked and let the game's auto-attack train Power (~600/s). Dungeon: walk the stages, pick up drops, bank them with the game's Return",
	Values = { "Dungeon", "Training dummy" },
	Default = "Dungeon",
	Multi = false,
	Callback = function(picked)
		farmMode = picked
	end,
})
Farm:AddInput("MaxStage", {
	Text = "Dungeon: deepest stage",
	Tooltip = "The trip turns back after this stage, or when the carry is full or health is low. Deeper stages drop better materials and hit harder; dying wipes the carry",
	Default = "3",
	Numeric = true,
	Finished = true,
	Callback = function(text)
		local n = math.floor(tonumber(text) or 0)
		if n >= 1 and n <= 21 then
			maxStage = n
		end
	end,
})

Farm:AddToggle("Hop", {
	Text = "Hop between stages",
	Tooltip = "Crosses a stage in 70-stud teleports instead of walking. A hop up to 80 studs held in the probe, 130 reverted; the server rules are kick-weighted, so this is off by default. If a hop does not hold it turns itself off and walks",
	Default = false,
	Callback = function(state)
		hopOn = state
		if state then
			hopBroken = false
		end
	end,
})

Farm:AddInput("PickFrom", {
	Text = "Dungeon: pick up from stage",
	Tooltip = "The carry holds only ~10 drops and a full one ends the trip, so shallow stages fill it with cheap materials. Set this to the first stage worth looting; earlier stages are cleared but not picked from",
	Default = "1",
	Numeric = true,
	Finished = true,
	Callback = function(text)
		local n = math.floor(tonumber(text) or 0)
		if n >= 1 and n <= 21 then
			pickFrom = n
		end
	end,
})

toggle(Craft, "Forge", "Auto Forge", "Forges the best sword your materials allow, again and again while 3+ usable ones are left. Skips locked materials", "forge")
Craft:AddInput("Units", {
	Text = "Materials per sword",
	Tooltip = "A sword's mult is the AVERAGE of its materials, so the minimum (3) of your best ones makes the strongest sword. More units dilute it",
	Default = "3",
	Numeric = true,
	Finished = true,
	Callback = function(text)
		local n = math.floor(tonumber(text) or 0)
		if n >= 3 and n <= 12 then
			forgeUnits = n
		end
	end,
})
Craft:AddInput("MinMult", {
	Text = "Forge only above mult",
	Tooltip = "Waits instead of forging a sword weaker than this (0 = forge whatever the best materials make)",
	Default = "0",
	Numeric = true,
	Finished = true,
	Callback = function(text)
		forgeMinMult = math.max(tonumber(text) or 0, 0)
	end,
})
toggle(Craft, "Equip", "Auto Equip Best Sword", "Equips the sword with the highest mult", "equip")
toggle(Craft, "SellW", "Auto Sell Swords", "Sells every sword except the best one, the equipped one and locked ones", "sellW")
toggle(Craft, "SellM", "Auto Sell Materials", "Sells the materials beyond your best N (N = Materials per sword). Off while you want to forge them", "sellM")

toggle(Prog, "Armor", "Auto Buy Armor", "Buys the most expensive armor you can afford that beats your best", "armor")
toggle(Prog, "Rebirth", "Auto Rebirth", "Rebirths as soon as your level allows. Resets Power (the rebirth bonus stays)", "rebirth")
toggle(Prog, "Online", "Auto Claim Online Rewards", "Claims every online-reward tier as it is reached", "rewards")
toggle(Prog, "Index", "Auto Claim Index", "Claims every index reward tier you have collected enough for", "index")

local conns = {}
local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
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
	local ok, level = pcall(LevelHelper.getLevel, tonumber(d.power) or 0)
	pcall(Window.SetStatus, Window, {
		{ "Coins", fmt(d.coins) },
		{ "Power", fmt(d.power) },
		{ "Lv", ok and tostring(level) or "?" },
		{ "Rebirths", tostring(d.rebirths or 0) },
		{ "Forged", stats.forged },
		{ "Sold", stats.sold },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("SwordToLoot", {})

-- close ----------------------------------------------------------------------
local function stopAll()
	for _, L in pairs(loops) do
		L.set(false)
	end
	watching = false
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().swordToLootStop = nil
end)

getgenv().swordToLootStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().swordToLootStop = nil
end
