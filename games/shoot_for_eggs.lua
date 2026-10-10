--[[ Shoot for Eggs -- shoot wild eggs, place, hatch, sell, upgrade, fight the boss (135911818477576)

     HUNT   : walks to the range deck and shoots wild eggs (weaponFire, a ray the SERVER casts from the origin we
              send). An egg dies when its Health attribute hits 0 and lands in your bag, nothing to pick up. Picks
              the highest-income egg you can break inside the kill-time cap (and that hatches inside the hatch-time
              cap), or the nearest ticked one with Best egg off. Reach is ~400 studs and the origin must be within
              ~15 studs of you (probed: 15 accepted, 30 refused), so it stands on the deck at the egg's X and shoots.
              The server paces shots at the gun's own rpm and magazine; faster is dropped (0.1s gap landed 4 of 12).
              Turns the game's Killcam setting off (restored on stop) so a kill is one eggBroke, no cutscene.
     PLACE  : equips an egg Tool and sends eggPlace(spot, 0) on free ground of your plot, best income first.
     HATCH  : fires each HatchPrompt that is Enabled from within ~20 studs (the server refused 35 and 44, took 28).
     PAD    : stands on the damage pad when there is nothing to do (the game's own client fires padShoot there; it
              pays damage and cash while you stand on it, and nothing off it). Claims the bonus token it offers.
     GUN    : buys the next gun in the game's order when you can pay and the rebirth gate is open (buyGun from anywhere).
     TARGET : buyTarget whenever the next level is affordable. PEN: buyPen for more animal slots.
     SELL   : sells backpack animals by rarity band and/or below an income/s floor. Eggs are never sold.
     BOSS   : joins every boss (bossJoin during the Invite window), shoots it and walks out of every zone it
              announces. Swoop = a lane 8 wide each side, FireRain = a circle of 12, Stomp = a ring you jump,
              Inferno = the whole arena except the wedges it lists as safe.
     REBIRTH: doRebirth when Cash is REBIRTH_X times the cost and no gun is affordable (it WIPES cash).
     CLAIMS : the daily reward and the wheel's free spin.

     Probed and dead (do not re-probe):
       buyDamage            no spend, no denial: the old upgrade path under BalanceVersion "new"
       collectAnimal / padShoot from afar   nothing: need to be within 60 of an animal / on the pad
       weaponFire with the origin 30+ studs from you   refused, no echo
       Humanoid:MoveTo / Move / Jump on the pad   do nothing (the game rewrites your CFrame while MoveDirection is 0)
       groupRewardClaim     needs the group
     Not wired (Robux): hatch Skip, offline buy, gamepass damage, product packs, wheel spin packs, ads.

     RightControl opens / closes the panel. Stop: getgenv().shootEggsStop() ]]

-- config ---------------------------------------------------------------------
local RANGE = 380 -- reach of a shot. 400 landed, 500 did not; raise only to test
local ORIGIN_MAX = 10 -- the shot's origin may move this far from you to clear the deck edge (server limit is 15-30)
local KILL_CAP = 20 -- seconds. An egg that needs longer than this at your gun and damage is skipped
local HATCH_CAP = 600 -- seconds. Best egg ignores eggs that take longer than this to hatch
local HUNT_BATCH = 6 -- eggs in the bag before it goes home to place them
local HUNT_MAX = 90 -- seconds in one hunt before it goes home regardless
local WALK_SPEED = 30 -- studs/s the character walks (WalkSpeed 32); only used to rank eggs by effort
local HOME_SHARE = 4 -- seconds of the trip home charged to every egg when ranking them
local STATS_EVERY = 30 -- seconds between stats lines in the console
local EGG_TO_ANIMAL = 10 -- rough: an egg's animals earn about this times the egg's income number (Fish Egg 1.2k -> 1.9k..60k seen). Only used by Replace weak animals
local ROTATE_X = 2 -- replace the weakest placed animal when the best egg in the bag is expected to beat it by this factor
local EGG_STRIKES = 2 -- health checks in a row with accepted shots and no drop before an egg is written off
local EGG_CHECK = 1.5 -- seconds between those checks (Health takes a moment to replicate back)
local BAD_EGG_FOR = 120 -- seconds a written-off or blocked egg is left alone
local DECK_EDGE = 2 -- studs in from the deck's north edge to stand
local DECK_INSET = 8 -- studs in from the deck's ends
local PLACE_REACH = 28 -- stand within this of a spot before sending eggPlace (35 was accepted)
local PLACE_CLEAR = 1 -- extra studs between placed things, on top of both PlacementRadius
local PLACE_STEP = 3 -- grid spacing of candidate spots
local HATCH_REACH = 16 -- stand within this of an egg's prompt (the server took 28, refused 35)
local HATCH_WAIT = 3.5 -- a fired HatchPrompt must remove the egg inside this
local PAD_SETTLE = 2 -- seconds to wait for OnDamagePad after stepping on
local STEP_KEY_HOLD = 0.35 -- a key press this long steps off the pad (a pad freezes MoveTo)
local SELL_EVERY = 6 -- seconds between looks at the backpack
local SELL_GAP = 0.25 -- between sellOne calls
local EQUIP_EVERY = 20 -- seconds between equipBest presses while Sell is on
local BUY_EVERY = 3 -- gun / target / pen look
local BUY_BACKOFF = 20 -- a purchase the server did not take waits this long
local REBIRTH_X = 1.5 -- rebirth when Cash >= this times the cost
local REBIRTH_GAP = 90 -- minimum seconds between rebirths
local CLAIM_EVERY = 90
local BOSS_MARGIN = 2.5 -- studs added to every boss zone
local BOSS_JUMP_LEAD = 14 -- jump the stomp ring when it is this far from you (it moves ~54/s, the jump peaks at 0.25s)
local WATCHDOG = 40 -- seconds of one step before the console says where it is stuck
local AFK_EVERY = 30 -- seconds between keep-alive inputs (the game reports idle at 60s and hops you at 1020s)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")
local VIM = game:GetService("VirtualInputManager")
local player = Players.LocalPlayer

if getgenv and getgenv().shootEggsStop then
	getgenv().shootEggsStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[shootegg]", ...)
end
local seen = {}
local function first(name, ...) -- one line the first time an unproven branch runs
	if not seen[name] then
		seen[name] = true
		log("first:", name, ...)
	end
end

-- The panel strip is drained from a Heartbeat, which the engine calls with our own identity.
-- A loop thread that writes to the window directly throws "lacking capability Plugin" after its first task.wait.
local pending, lastSaid = {}, nil
local function say(msg, slot)
	pending[slot or "now"] = msg
	if (slot or "now") == "now" and msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- breadcrumb + watchdog: a parked yield looks exactly like a dead farm, so name the step
local mark, markAt = "start", os.clock()
local function step(name)
	mark, markAt = name, os.clock()
end

-- game -----------------------------------------------------------------------
local Packages = ReplicatedStorage:WaitForChild("Packages", 15)
local Shared = ReplicatedStorage:WaitForChild("Shared", 15)
local Remotes = ReplicatedStorage:WaitForChild("FoundryRemotes", 15)
local okMods, Net, ED, WD, SD, TD, PD, BD, AD, RD, SeD, WhD = pcall(function()
	local m = Shared.Modules.Game
	return require(Packages.Net),
		require(m.EggData),
		require(m.WeaponData),
		require(m.ShopData),
		require(m.TargetData),
		require(m.PenData),
		require(m.BossData),
		require(m.AnimalData),
		require(m.RebirthData),
		require(m.SettingsData),
		require(m.WheelData)
end)
if not (Packages and Shared and Remotes and okMods) then
	warn("[shootegg] the game's modules did not load:", Net)
	return
end

local running = true
local conns = {}
local S = { -- the toggles; every loop reads these live
	hunt = false,
	best = true,
	place = false,
	hatch = false,
	pad = false,
	gun = false,
	target = false,
	pen = false,
	sell = false,
	rotate = false,
	equip = false,
	boss = false,
	rebirth = false,
	claims = false,
}
local eggOn, sellOn = {}, {}
local forceSell = {} -- sell ids of animals the rotate step took off the plot
local minIncome = 0 -- income/s floor for Sell (0 = off)
local stats = { kills = 0, placed = 0, hatched = 0, sold = 0, shots = 0, boss = 0, bossWins = 0, bought = 0 }
local bossNote = "idle"

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

local function num(attr)
	return tonumber(player:GetAttribute(attr)) or 0
end
local function fire(name, ...) -- one-way send; the game wraps FireServer in Net.attempt
	return pcall(Net.attempt, name, ...)
end
local function char()
	local c = player.Character
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	if hrp and hum and hum.Health > 0 then
		return hrp, hum, c
	end
	return nil
end
local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end
local function inBoss()
	return player:GetAttribute(BD.IN_FIGHT) == true
end

-- events ----------------------------------------------------------------------
local ev = {
	ammo = { n = 1, mag = 1, reloading = false },
	echo = 0, -- clock of the last accepted shot of ours
	echoN = 0, -- how many the server has accepted
	placed = nil, -- last eggPlaced payload
	sellList = nil,
	daily = nil,
	wheel = nil,
	hatched = 0,
	broke = 0,
}
local function on(name, fn)
	local r = Remotes:FindFirstChild(name)
	if r then
		table.insert(conns, r.OnClientEvent:Connect(fn))
	else
		warn("[shootegg] no remote", name)
	end
end
on("weaponAmmo", function(a, m, r)
	ev.ammo.n, ev.ammo.mag, ev.ammo.reloading = a, m, r
end)
on("weaponShot", function(who)
	if who == player then
		ev.echo = os.clock()
		ev.echoN += 1
	end
end)
on("eggPlaced", function(ok, a)
	ev.placed = { ok = ok, a = a, at = os.clock() }
end)
on("sellList", function(l)
	ev.sellList = { items = l, at = os.clock() }
end)
on("dailyState", function(t)
	ev.daily = t
end)
on("wheelState", function(t)
	ev.wheel = t
end)
on("eggHatched", function()
	ev.hatched += 1
end)
on("eggBroke", function()
	ev.broke += 1
end)
on("padBonusOffer", function()
	if S.pad then
		first("padBonusOffer")
		task.delay(0.6, function()
			fire("padBonusClaim")
		end)
	end
end)

-- world ------------------------------------------------------------------------
local function ownPlot()
	for _, m in ipairs(workspace:GetChildren()) do
		if m:IsA("Model") and m:GetAttribute("OwnerUserId") == player.UserId and m.Name:match("^Plot") then
			return m
		end
	end
	return nil
end
local function plotCentre(plot)
	local c = plot:GetAttribute("BoundsCentre")
	local s = plot:GetAttribute("BoundsSize")
	if typeof(c) ~= "Vector3" or typeof(s) ~= "Vector3" then
		local cf, size = plot:GetBoundingBox()
		return cf.Position, size
	end
	return c, s
end
-- the pad belonging to your plot: the DamageAuto model nearest it
local function myPad()
	local plot = ownPlot()
	if not plot then
		return nil
	end
	local best, bd
	for _, d in ipairs(workspace:GetChildren()) do
		if d:IsA("Model") and d.Name == "DamageAuto" and d:FindFirstChild("Target") and d:FindFirstChild("FloorTarget") then
			local dist = (d:GetPivot().Position - plot:GetPivot().Position).Magnitude
			if not bd or dist < bd then
				best, bd = d, dist
			end
		end
	end
	if best then
		local part = best.FloorTarget:FindFirstChildWhichIsA("BasePart", true)
		return part and part.Position or best:GetPivot().Position
	end
	return nil
end
local function deckPart()
	return workspace:FindFirstChild("RollGround")
end

local function wildEggs()
	local list = {}
	for _, m in ipairs(workspace:GetChildren()) do
		if m:IsA("Model") and ED.eggs[m.Name] and type(m:GetAttribute("Health")) == "number" then
			list[#list + 1] = m
		end
	end
	return list
end
local centres = setmetatable({}, { __mode = "k" }) -- wild eggs never move (0 of 60 in 4s): cache the centre
local function eggCentre(m)
	local c = centres[m]
	if not c then
		c = m:GetBoundingBox().Position
		centres[m] = c
	end
	return c
end

local function backpackEggs()
	local list = {}
	local bp = player:FindFirstChildOfClass("Backpack")
	local c = player.Character
	for _, holder in ipairs({ bp, c }) do
		if holder then
			for _, t in ipairs(holder:GetChildren()) do
				if t:IsA("Tool") and t:GetAttribute("EggType") ~= nil and ED.eggs[t:GetAttribute("EggType")] then
					list[#list + 1] = t
				end
			end
		end
	end
	table.sort(list, function(a, b)
		return ED.eggs[a:GetAttribute("EggType")].income > ED.eggs[b:GetAttribute("EggType")].income
	end)
	return list
end
local function heldEggs()
	return num("CarriedEggs")
end

-- movement ---------------------------------------------------------------------
-- The game's pad code rewrites your CFrame every frame while Humanoid.MoveDirection is ~0, and MoveTo / Move / Jump
-- report 0 there, so a scripted walk freezes at the pad's edge. A real key press (MoveDirection > 0) steps off.
local function nudge(dir)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local look = flat(cam.CFrame.LookVector)
	local right = flat(cam.CFrame.RightVector)
	if look.Magnitude < 0.1 or right.Magnitude < 0.1 then
		return
	end
	look, right = look.Unit, right.Unit
	local want = flat(dir)
	if want.Magnitude < 0.1 then
		return
	end
	want = want.Unit
	local keys = { { Enum.KeyCode.W, look }, { Enum.KeyCode.S, -look }, { Enum.KeyCode.D, right }, { Enum.KeyCode.A, -right } }
	table.sort(keys, function(a, b)
		return a[2]:Dot(want) > b[2]:Dot(want)
	end)
	local key = keys[1][1]
	pcall(function()
		VIM:SendKeyEvent(true, key, false, game)
	end)
	task.wait(STEP_KEY_HOLD)
	pcall(function()
		VIM:SendKeyEvent(false, key, false, game)
	end)
end

local function walk(goal, tol, timeout, stop)
	tol = tol or 3
	local t0, still, last = os.clock(), nil, nil
	while running and os.clock() - t0 < (timeout or 25) do
		if stop and stop() then
			return false
		end
		local hrp, hum = char()
		if hrp then
			local d = (flat(hrp.Position) - flat(goal)).Magnitude
			if d <= tol then
				return true
			end
			hum:MoveTo(goal)
			task.wait(0.1)
			local p = hrp.Position
			if last and (p - last).Magnitude < 0.05 then
				still = still or os.clock()
				if os.clock() - still > 0.5 then
					nudge(goal - p)
					still = nil
				end
			else
				still = nil
			end
			last = p
		else
			task.wait(0.3)
		end
	end
	return false
end

-- going between the deck (z < pad) and the plot (z > pad) passes the pad: swing round it
local function walkRoute(goal, tol, timeout, stop)
	local pad = myPad()
	local hrp = char()
	if pad and hrp then
		local a, b = hrp.Position.Z, goal.Z
		local lo, hi = pad.Z - 16, pad.Z + 16
		local x = pad.X + 26
		if a < lo and b > hi then
			if not walk(Vector3.new(x, goal.Y, lo), 4, timeout, stop) or not walk(Vector3.new(x, goal.Y, hi), 4, timeout, stop) then
				return false
			end
		elseif a > hi and b < lo then
			if not walk(Vector3.new(x, goal.Y, hi), 4, timeout, stop) or not walk(Vector3.new(x, goal.Y, lo), 4, timeout, stop) then
				return false
			end
		end
	end
	return walk(goal, tol, timeout, stop)
end

-- gun --------------------------------------------------------------------------
local function gunTool()
	local c = player.Character
	if c then
		for _, t in ipairs(c:GetChildren()) do
			if t:IsA("Tool") and t:GetAttribute("EggType") == nil and WD.get(t.Name) then
				return t
			end
		end
	end
	return nil
end
local function ensureGun()
	if gunTool() then
		return true
	end
	local _, hum = char()
	local bp = player:FindFirstChildOfClass("Backpack")
	local tool = bp and bp:FindFirstChild(tostring(player:GetAttribute("Weapon")))
	if hum and tool then
		pcall(hum.UnequipTools, hum)
		pcall(hum.EquipTool, hum, tool)
		task.wait(0.3)
	end
	return gunTool() ~= nil
end
local function gunStats()
	local g = WD.get(tostring(player:GetAttribute("Weapon"))) or WD.get("Slingshot")
	return g.rpm, g.magazine, g.reload
end
local lastShot = 0
local function gunReady()
	local rpm = gunStats()
	return ev.ammo.n > 0 and not ev.ammo.reloading and os.clock() - lastShot >= 60 / rpm + 0.02
end
local function shoot(origin, dir)
	lastShot = os.clock()
	stats.shots += 1
	fire("weaponFire", origin, dir)
end
local reloadAsked = 0
local function keepLoaded()
	if ev.ammo.n == 0 and not ev.ammo.reloading and os.clock() - lastShot > 0.5 and os.clock() - reloadAsked > 0.8 then
		reloadAsked = os.clock()
		fire("weaponReload")
	end
end
local function killSeconds(hp)
	local sd = num("ShotDamage")
	if sd <= 0 then
		return math.huge
	end
	local rpm, mag, reload = gunStats()
	local shots = math.max(math.ceil(hp / sd), 1)
	return shots * 60 / rpm + math.floor((shots - 1) / math.max(mag, 1)) * reload
end
assert(killSeconds(1) > 0 and killSeconds(1e30) > killSeconds(1), "killSeconds grows with health")

-- hunt -------------------------------------------------------------------------
local killCap, hatchCap = KILL_CAP, HATCH_CAP
local bad = setmetatable({}, { __mode = "k" }) -- egg -> clock until which it is left alone

local function deckStand(c)
	local deck = deckPart()
	if not deck then
		return
	end
	local half = deck.Size.X / 2 - DECK_INSET
	local x = math.clamp(c.X, deck.Position.X - half, deck.Position.X + half)
	local z = deck.Position.Z - deck.Size.Z / 2 + DECK_EDGE
	return Vector3.new(x, deck.Position.Y + deck.Size.Y / 2 + 3, z)
end

-- standing on the deck already and the egg is inside reach: no need to walk to its ideal spot
local function canFrom(pos, c)
	local deck = deckPart()
	if not deck then
		return false
	end
	local rel = pos - deck.Position
	return math.abs(rel.X) <= deck.Size.X / 2 and math.abs(rel.Z) <= deck.Size.Z / 2 + 1 and math.abs(rel.Y) < 12
		and (c - (pos + Vector3.new(0, 1.5, 0))).Magnitude <= RANGE - 15
end

local function losOk(origin, c, egg)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }
	local r = workspace:Raycast(origin, (c - origin).Unit * ((c - origin).Magnitude + 2), params)
	return r == nil or r.Instance:IsDescendantOf(egg) or (r.Position - c).Magnitude < 6
end

-- income per second of effort: walking to the egg's spot on the deck + the kill + a share of the trip home
local function eggValue(income, walkStuds, kill)
	return income / (walkStuds / WALK_SPEED + kill + HOME_SHARE)
end
assert(eggValue(100, 0, 1) > eggValue(100, 300, 1) and eggValue(300, 0, 1) > eggValue(100, 0, 1), "eggValue: nearer and richer win")

local function pickEgg()
	local now = os.clock()
	local hrp = char()
	local me = hrp and hrp.Position or Vector3.zero
	local best, bestKey
	local why = { total = 0, unticked = 0, benched = 0, range = 0, slow = 0, hatch = 0 }
	for _, m in ipairs(wildEggs()) do
		local name = m.Name
		local cfg = ED.eggs[name]
		local hp = m:GetAttribute("Health")
		why.total += 1
		if not eggOn[name] or hp <= 0 then
			why.unticked += 1
		elseif (bad[m] or 0) >= now then
			why.benched += 1
		else
			local c = eggCentre(m)
			local stand = deckStand(c)
			if not (stand and (c - (stand + Vector3.new(0, 1.5, 0))).Magnitude <= RANGE) then
				why.range += 1
			elseif killSeconds(hp) > killCap then
				why.slow += 1
			elseif S.best and cfg.hatchTime > hatchCap then
				why.hatch += 1
			else
				local t = killSeconds(hp)
				local walkStuds = canFrom(me, c) and 0 or (flat(stand) - flat(me)).Magnitude
				local key = S.best and eggValue(cfg.income, walkStuds, t) or -(c - stand).Magnitude
				if not bestKey or key > bestKey then
					best, bestKey = m, key
				end
			end
		end
	end
	return best, why
end

-- shoot one egg until it dies. true = killed, false = given up
local function shootEgg(egg, stop)
	local c = eggCentre(egg)
	local stand = deckStand(c)
	-- an origin up to ORIGIN_MAX from you that has a clear line; prefer your own position
	local function findOrigin()
		local hrp = char()
		if not hrp then
			return nil
		end
		local o = hrp.Position + Vector3.new(0, 1.5, 0)
		local toward = flat(c - o)
		local cands = { o }
		if toward.Magnitude > 1 then
			cands[#cands + 1] = o + toward.Unit * ORIGIN_MAX
			cands[#cands + 1] = o + Vector3.new(0, ORIGIN_MAX, 0)
			cands[#cands + 1] = o + toward.Unit * ORIGIN_MAX * 0.7 + Vector3.new(0, ORIGIN_MAX * 0.7, 0)
		end
		for _, cand in ipairs(cands) do
			if (cand - c).Magnitude <= RANGE + 15 and losOk(cand, c, egg) then
				return cand
			end
		end
		return nil
	end
	local hrp0 = char()
	local origin
	if hrp0 and canFrom(hrp0.Position, c) then
		origin = findOrigin() -- no walking when the egg is already in reach from here
	end
	if not origin then
		step("hunt walk to deck")
		if not walkRoute(stand, 2.5, 30, stop) then
			return false
		end
		origin = findOrigin()
	end
	if not char() then
		return false
	end
	if not origin then
		bad[egg] = os.clock() + BAD_EGG_FOR
		first("blocked egg", egg.Name, ("at %d,%d,%d"):format(c.X, c.Y, c.Z))
		return false
	end
	step("hunt shooting " .. egg.Name)
	if not ensureGun() then
		say("no gun in hand")
		return false
	end
	local hp0 = egg:GetAttribute("Health")
	local t0, sent, echo0 = os.clock(), 0, ev.echoN
	local checkAt, checkHp, checkN, flat_ = t0, hp0, echo0, 0
	local cap = math.max(killCap * 2, 15)
	local dir = (c - origin).Unit
	local function done(ok, why)
		log(("egg %s hp %s -> %s: %s (%d sent, %d accepted, %.1fs, dist %d)"):format(
			egg.Name, fmt(hp0), egg.Parent and fmt(egg:GetAttribute("Health") or 0) or "gone", why, sent, ev.echoN - echo0,
			os.clock() - t0, (c - origin).Magnitude))
		return ok
	end
	while running and egg.Parent and (egg:GetAttribute("Health") or 0) > 0 and os.clock() - t0 < cap do
		if stop and stop() then
			return done(false, "stopped")
		end
		-- fire at the gun's own cadence (an automatic gun lands ~10/s); waiting on each shot's echo would cap it at 2-3/s
		if gunReady() then
			shoot(origin, dir)
			sent += 1
		else
			keepLoaded()
		end
		task.wait()
		local now = os.clock()
		if now - checkAt >= EGG_CHECK then
			local hp = egg:GetAttribute("Health") or 0
			if ev.echoN - checkN >= 2 and hp >= checkHp then
				flat_ += 1
			else
				flat_ = 0
			end
			checkAt, checkHp, checkN = now, hp, ev.echoN
			if flat_ >= EGG_STRIKES then
				bad[egg] = now + BAD_EGG_FOR
				return done(false, "health not moving")
			end
		end
	end
	-- Health reaches 0 a moment before the model is destroyed, so a drained egg is a kill
	local t1 = os.clock()
	while egg.Parent and (egg:GetAttribute("Health") or 0) <= 0 and os.clock() - t1 < 1.5 do
		task.wait(0.05)
	end
	if not egg.Parent or (egg:GetAttribute("Health") or 0) <= 0 then
		stats.kills += 1
		return done(true, "killed")
	end
	bad[egg] = os.clock() + BAD_EGG_FOR
	return done(false, "timed out")
end

-- settings: the game's own switch for the egg-break cutscene
local killcamWas
local function setKillcam(off)
	if off then
		if killcamWas == nil then
			killcamWas = true -- the default; the first state dump says otherwise only if the user turned it off
			local got
			local r = Remotes:FindFirstChild("settingsState")
			local c
			if r then
				c = r.OnClientEvent:Connect(function(t)
					got = t
				end)
			end
			fire(SeD.CHANNEL, "state")
			local t0 = os.clock()
			while got == nil and os.clock() - t0 < 2 do
				task.wait(0.1)
			end
			if c then
				c:Disconnect()
			end
			if type(got) == "table" and got.Killcam ~= nil then
				killcamWas = got.Killcam
			end
		end
		fire(SeD.CHANNEL, "set", "Killcam", false)
	elseif killcamWas ~= nil then
		fire(SeD.CHANNEL, "set", "Killcam", killcamWas)
		killcamWas = nil
	end
end

-- home: place + hatch -----------------------------------------------------------
local placeBlockedUntil = 0

local function placedEggs(plot)
	local list = {}
	for _, ch in ipairs(plot:GetChildren()) do
		if ch.Name == "PlacedEgg" then
			list[#list + 1] = ch
		end
	end
	return list
end
-- the server refuses eggPlace ("Pet slots full") when the animals already fill the pen; placed eggs do not count
local function penFull(plot)
	return (tonumber(plot:GetAttribute("PenUsed")) or 0) >= (tonumber(plot:GetAttribute("PenCapacity")) or 0)
end
local function hatchPrompt(egg)
	for _, d in ipairs(egg:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "HatchPrompt" then
			return d
		end
	end
	return nil
end
local function promptPos(p)
	local par = p.Parent
	if par:IsA("Attachment") then
		return par.WorldPosition
	elseif par:IsA("BasePart") then
		return par.Position
	end
	return par:GetPivot().Position
end
local function readyEggs(plot)
	local list = {}
	for _, egg in ipairs(placedEggs(plot)) do
		local p = hatchPrompt(egg)
		if p and p.Enabled then
			list[#list + 1] = { egg = egg, prompt = p }
		end
	end
	return list
end

-- a free spot for an egg of radius r on the plot floor, nearest to `near`
local function freeSpot(plot, r, near)
	local c, s = plotCentre(plot)
	local hx, hz = math.max(s.X / 2 - r - 1, 0), math.max(s.Z / 2 - r - 1, 0)
	local things = {}
	local ignore = { player.Character }
	for _, ch in ipairs(plot:GetChildren()) do
		if ch.Name == "PlacedEgg" or ch.Name == "HatchedAnimal" then
			local home = ch:GetAttribute("Home")
			things[#things + 1] = { p = typeof(home) == "Vector3" and home or ch:GetPivot().Position, r = ch:GetAttribute("PlacementRadius") or 2 }
			ignore[#ignore + 1] = ch
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	local best, bd
	local x = c.X - hx
	while x <= c.X + hx do
		local z = c.Z - hz
		while z <= c.Z + hz do
			local ok = true
			for _, t in ipairs(things) do
				if (Vector3.new(x - t.p.X, 0, z - t.p.Z)).Magnitude < r + t.r + PLACE_CLEAR then
					ok = false
					break
				end
			end
			if ok then
				local d = (Vector3.new(x, 0, z) - flat(near)).Magnitude
				if not bd or d < bd then
					local hit = workspace:Raycast(Vector3.new(x, c.Y + 30, z), Vector3.new(0, -80, 0), params)
					if hit then
						best, bd = Vector3.new(x, hit.Position.Y, z), d
					end
				end
			end
			z += PLACE_STEP
		end
		x += PLACE_STEP
	end
	return best
end

local function holdOnly(tool)
	local _, hum = char()
	if not hum then
		return false
	end
	if tool.Parent == player.Character and #{ gunTool() } == 0 then
		return true
	end
	pcall(hum.UnequipTools, hum)
	task.wait(0.15)
	pcall(hum.EquipTool, hum, tool)
	local t0 = os.clock()
	while os.clock() - t0 < 1.2 do
		if tool.Parent == player.Character then
			return true
		end
		task.wait(0.05)
	end
	return false
end

local function placeAll(plot, stop)
	local n = 0
	for _ = 1, 40 do
		if not running or (stop and stop()) then
			break
		end
		local eggs = backpackEggs()
		if #eggs == 0 then
			break
		end
		if penFull(plot) then
			placeBlockedUntil = os.clock() + 10
			say("pen full: sell animals or buy pen slots")
			break
		end
		local tool = eggs[1]
		local r = tool:GetAttribute("PlacementRadius") or 2
		local hrp = char()
		if not hrp then
			break
		end
		step("place find spot")
		local spot = freeSpot(plot, r, hrp.Position)
		if not spot then
			placeBlockedUntil = os.clock() + 60
			say("plot has no free spot")
			break
		end
		if (flat(spot) - flat(hrp.Position)).Magnitude > PLACE_REACH then
			step("place walk to spot")
			if not walk(spot, PLACE_REACH - 6, 12, stop) then
				break
			end
		end
		step("place equip " .. tostring(tool:GetAttribute("EggType")))
		if not holdOnly(tool) then
			say("could not hold " .. tool.Name)
			break
		end
		ev.placed = nil
		fire("eggPlace", spot, 0)
		local t0 = os.clock()
		while not ev.placed and os.clock() - t0 < 2 do
			task.wait(0.05)
		end
		local res = ev.placed
		if res and res.ok then
			n += 1
			stats.placed += 1
			first("place", tool.Name)
		else
			local why = res and tostring(res.a) or "no reply"
			say("place refused: " .. why)
			first("place refused", why)
			placeBlockedUntil = os.clock() + 20
			break
		end
		task.wait(0.15)
	end
	return n
end

local function hatchAll(plot, stop)
	local n = 0
	for _ = 1, 40 do
		if not running or (stop and stop()) then
			break
		end
		local list = readyEggs(plot)
		if #list == 0 then
			break
		end
		local hrp = char()
		if not hrp then
			break
		end
		table.sort(list, function(a, b)
			return (promptPos(a.prompt) - hrp.Position).Magnitude < (promptPos(b.prompt) - hrp.Position).Magnitude
		end)
		local job = list[1]
		local pos = promptPos(job.prompt)
		step("hatch walk to " .. job.egg:GetAttribute("EggType"))
		if (flat(pos) - flat(hrp.Position)).Magnitude > HATCH_REACH then
			-- stand HATCH_REACH-4 short of the egg on the side we come from
			local back = flat(hrp.Position - pos)
			local goal = back.Magnitude > 1 and (pos + back.Unit * (HATCH_REACH - 6)) or pos
			walk(Vector3.new(goal.X, hrp.Position.Y, goal.Z), 3, 12, stop)
		end
		step("hatch fire")
		pcall(fireproximityprompt, job.prompt)
		local t0 = os.clock()
		while job.egg.Parent and os.clock() - t0 < HATCH_WAIT do
			task.wait(0.1)
		end
		if not job.egg.Parent then
			n += 1
			stats.hatched += 1
			first("hatch", job.egg:GetAttribute("EggType"), ("%.1fs"):format(os.clock() - t0))
		else
			-- refused (too far, or still animating): skip it for a moment so the next egg gets its turn
			bad[job.egg] = os.clock() + 5
			first("hatch not taken", job.egg:GetAttribute("EggType"))
			task.wait(0.5)
		end
	end
	return n
end

-- pad ---------------------------------------------------------------------------
local function onPad()
	return player:GetAttribute("OnDamagePad") == true
end
local function goPad(stop)
	if onPad() then
		return true
	end
	local pad = myPad()
	if not pad then
		return false
	end
	step("pad walk")
	walkRoute(Vector3.new(pad.X, pad.Y + 3, pad.Z), 6, 30, stop) -- it freezes at the edge, which is enough
	local t0 = os.clock()
	while not onPad() and os.clock() - t0 < PAD_SETTLE do
		task.wait(0.1)
	end
	return onPad()
end
local function leavePad(toward)
	if not onPad() then
		return
	end
	local hrp = char()
	if hrp then
		nudge(toward - hrp.Position)
	end
end

-- director -----------------------------------------------------------------------
local function wantMoreEggs()
	local held = heldEggs()
	if S.place then
		return held < HUNT_BATCH
	end
	return held < math.max(num("EggLimit") - 2, 1)
end

local function homeWork(plot)
	if not plot then
		return false
	end
	if S.hatch and #readyEggs(plot) > 0 then
		return true
	end
	if S.place and os.clock() >= placeBlockedUntil and not penFull(plot) and #backpackEggs() > 0 then
		return true
	end
	return false
end

-- The game's own Home button (goHome) is a server teleport to the plot centre: probed 115 studs from the deck in 0.06s,
-- and it takes you off the pad. Walking is the fallback.
local lastHomeFire = 0
local function goHome(plot, stop)
	local c = plotCentre(plot)
	local hrp = char()
	if not hrp then
		return false
	end
	local goal = Vector3.new(c.X, hrp.Position.Y, c.Z)
	if (flat(hrp.Position) - flat(goal)).Magnitude < 12 then
		return true
	end
	if os.clock() - lastHomeFire > 3 then
		lastHomeFire = os.clock()
		step("home button")
		fire("goHome")
		local t0 = os.clock()
		while os.clock() - t0 < 2 do
			local h = char()
			if h and (flat(h.Position) - flat(goal)).Magnitude < 25 then
				first("goHome", ("%.2fs"):format(os.clock() - t0))
				task.wait(0.2) -- let the move settle before the next step
				return true
			end
			task.wait(0.05)
		end
		first("goHome did not move us")
	end
	if onPad() then
		leavePad(goal)
	end
	step("home walk")
	return walkRoute(goal, 6, 40, stop)
end

local function director()
	local stopBoss = function()
		return not running or inBoss()
	end
	-- "hunt" runs a whole batch on the deck, then "home" does the place + hatch trip; a single ready egg never pulls
	-- it off the deck (the two stations are ~100 studs apart)
	local mode = "home"
	while running do
		local ok, err = pcall(function()
			if inBoss() then
				step("director waits for the boss fight")
				while running and inBoss() do
					task.wait(0.5)
				end
				task.wait(1.5)
				mode = "home"
				return
			end
			local plot = ownPlot()
			if not (S.hunt or S.place or S.hatch or S.pad) or not plot then
				step("director idle")
				task.wait(0.7)
				return
			end
			if mode == "hunt" then
				mode = "home"
				if not (S.hunt and wantMoreEggs() and heldEggs() < num("EggLimit") - 1) then
					return
				end
				local t0, kills0 = os.clock(), stats.kills
				setKillcam(true)
				say("hunting eggs")
				if onPad() then
					local hrp = char()
					if hrp then
						leavePad(hrp.Position + Vector3.new(0, 0, -1))
					end
				end
				while running and not inBoss() and S.hunt and wantMoreEggs() and os.clock() - t0 < HUNT_MAX do
					local egg, why = pickEgg()
					if not egg then
						say("hunt: no egg inside the caps")
						log(("no egg: %d wild, %d unticked, %d benched, %d out of range, %d too slow, %d hatch too long"):format(
							why.total, why.unticked, why.benched, why.range, why.slow, why.hatch))
						task.wait(1.5)
						break
					end
					shootEgg(egg, stopBoss)
				end
				log(("hunt over: %d kills in %.0fs, %d in the bag"):format(stats.kills - kills0, os.clock() - t0, heldEggs()))
				return
			end
			if homeWork(plot) then
				say("home: place + hatch")
				if goHome(plot, stopBoss) then
					if S.hatch then
						hatchAll(plot, stopBoss)
					end
					if S.place and os.clock() >= placeBlockedUntil then
						placeAll(plot, stopBoss)
					end
					if S.hatch then
						hatchAll(plot, stopBoss)
					end
				end
				return
			end
			if S.hunt and wantMoreEggs() and heldEggs() < num("EggLimit") - 1 then
				mode = "hunt"
				return
			end
			if S.pad then
				if not onPad() then
					say("going to the pad")
					goPad(stopBoss)
				else
					say("on the pad")
				end
				task.wait(1)
				return
			end
			say("waiting for eggs to hatch")
			task.wait(1)
		end)
		if not ok then
			warn("[shootegg] director:", err)
			task.wait(1)
		end
	end
end

-- boss -----------------------------------------------------------------------------
local function sNow()
	return workspace:GetServerTimeNow()
end
local function segDist(p, a, b)
	p, a, b = flat(p), flat(a), flat(b)
	local ab = b - a
	local t = math.clamp((p - a):Dot(ab) / math.max(ab:Dot(ab), 1e-6), 0, 1)
	return (p - (a + ab * t)).Magnitude
end
local function arenaCentre()
	local a = workspace:FindFirstChild(BD.ARENA)
	return a and a:GetPivot().Position or Vector3.new(0, 1500, -24785.67), a and a:GetAttribute("Radius") or 85
end

local function fightBoss()
	stats.boss += 1
	local hazards, ring = {}, nil
	local c0, arenaR = arenaCentre()
	local fxConn, hbConn
	local function inside(h, p)
		if h.kind == "circle" then
			return (flat(p) - flat(h.c)).Magnitude < h.r + BOSS_MARGIN
		elseif h.kind == "lane" then
			return segDist(p, h.a, h.b) < h.hw + BOSS_MARGIN
		else -- inferno: the whole disc except the wedges it lists as safe, and never the middle
			local d = flat(p) - flat(h.c)
			if d.Magnitude >= h.r + BOSS_MARGIN then
				return false
			end
			if d.Magnitude < 10 then
				return true
			end
			local ang = math.deg(math.atan2(d.Z, d.X)) % 360
			for _, s in ipairs(h.safe) do
				if math.abs(((ang - s) + 180) % 360 - 180) <= h.wedge / 2 - 5 then
					return false
				end
			end
			return true
		end
	end
	local function blockedAt(p, now)
		for _, h in ipairs(hazards) do
			if h.t1 > now and inside(h, p) then
				return h
			end
		end
		return nil
	end
	local function inArena(p)
		return (flat(p) - flat(c0)).Magnitude < arenaR - 6
	end
	local function pickSafe(me, now)
		local cands = {}
		for _, dist in ipairs({ 0, 5, 10, 16, 24, 34 }) do
			for a = 0, 330, 30 do
				cands[#cands + 1] = { dist + 0, dist == 0 and me or me + Vector3.new(math.cos(math.rad(a)) * dist, 0, math.sin(math.rad(a)) * dist) }
			end
		end
		for _, h in ipairs(hazards) do
			if h.kind == "inferno" and h.t1 > now then
				for _, s in ipairs(h.safe) do
					local p = h.c + Vector3.new(math.cos(math.rad(s)), 0, math.sin(math.rad(s))) * 32
					cands[#cands + 1] = { (flat(p) - flat(me)).Magnitude, Vector3.new(p.X, me.Y, p.Z) }
				end
			end
		end
		local best, bc
		for _, c in ipairs(cands) do
			if inArena(c[2]) and not blockedAt(c[2], now) and (not bc or c[1] < bc) then
				best, bc = c[2], c[1]
			end
		end
		return best
	end
	local R = Remotes
	fxConn = R.bossFx.OnClientEvent:Connect(function(kind, p)
		if type(p) ~= "table" then
			return
		end
		local at, tele = p.at or sNow(), p.telegraph or 1
		if kind == "FireRain" then
			table.insert(hazards, { kind = "circle", c = p.point, r = p.radius or 12, t0 = at + tele - 0.1, t1 = at + tele + 0.4 })
		elseif kind == "Swoop" then
			table.insert(hazards, { kind = "lane", a = p.from, b = p.to, hw = p.width or 8, t0 = at + tele - 0.1, t1 = at + tele + 0.75 })
		elseif kind == "StompWarn" then
			table.insert(hazards, { kind = "circle", c = p.point, r = 14, t0 = at - 0.5, t1 = at + tele + 0.2 })
		elseif kind == "Stomp" then
			ring = { c = p.point, reach = p.reach or 70, grow = p.grow or 1.3, th = p.thickness or 4, at = p.at or sNow(), jumped = false }
			first("boss stomp")
		elseif kind == "Inferno" and type(p.safe) == "table" then
			table.insert(hazards, { kind = "inferno", c = p.point, r = p.radius, safe = p.safe, wedge = p.wedge or 40, t0 = at + tele - 0.1, t1 = at + tele + 0.5 })
			first("boss inferno")
		end
	end)
	hbConn = RunService.Heartbeat:Connect(function()
		if not inBoss() then
			return
		end
		local hrp, hum = char()
		if not hrp then
			return
		end
		local now = sNow()
		for i = #hazards, 1, -1 do
			if hazards[i].t1 + 0.5 < now then
				table.remove(hazards, i)
			end
		end
		if ring then
			local age = now - ring.at
			if age > ring.grow + 0.3 then
				ring = nil
			elseif not ring.jumped then
				local r = ring.reach * age / ring.grow
				local d = (flat(hrp.Position) - flat(ring.c)).Magnitude
				if d < ring.reach + ring.th and d - r < BOSS_JUMP_LEAD and d - r > 1 then
					ring.jumped = true
					pcall(hum.ChangeState, hum, Enum.HumanoidStateType.Jumping) -- hum.Jump is overwritten by the control module
				end
			end
		end
		if blockedAt(hrp.Position, now) then
			local c = pickSafe(hrp.Position, now)
			if c then
				hum:MoveTo(c)
			end
		end
	end)
	bossNote = "fighting"
	local t0 = os.clock()
	local lastSent = 0
	while running and inBoss() and os.clock() - t0 < 330 do
		local hrp = char()
		local bf = workspace:FindFirstChild("BossFight")
		local boss = bf and bf:FindFirstChildWhichIsA("Model")
		if hrp and boss and workspace:GetAttribute("BossPhase") == "Active" then
			ensureGun()
			if gunReady() then
				local o = hrp.Position + Vector3.new(0, 1.5, 0)
				shoot(o, (boss:GetBoundingBox().Position - o).Unit)
			else
				keepLoaded()
			end
			local hp = workspace:GetAttribute("BossHealth")
			if os.clock() - lastSent > 1 then
				lastSent = os.clock()
				bossNote = ("boss %.0f%%  you %d hp"):format((tonumber(hp) or 1) * 100, select(2, char()) and select(2, char()).Health or 0)
			end
		end
		task.wait(0.03)
	end
	fxConn:Disconnect()
	hbConn:Disconnect()
	bossNote = "idle"
end

on("bossResult", function(t)
	if type(t) == "table" then
		if t.won then
			stats.bossWins += 1
		end
		log("boss result:", t.won and "WON" or "lost", t.reason)
	end
end)

local function bossLoop()
	local lastJoin = 0
	while running do
		local ok, err = pcall(function()
			if not S.boss then
				bossNote = "off"
				task.wait(1)
				return
			end
			local phase = workspace:GetAttribute("BossPhase")
			if inBoss() then
				fightBoss()
				return
			end
			if phase == "Invite" and player:GetAttribute("BossJoined") ~= true and os.clock() - lastJoin > 3 then
				lastJoin = os.clock()
				first("boss join")
				fire(BD.JOIN)
				bossNote = "joined, waiting for the arena"
			elseif phase == "Idle" then
				local nextAt = tonumber(workspace:GetAttribute(BD.NEXT_AT))
				bossNote = nextAt and ("next in %ds"):format(math.max(nextAt - sNow(), 0)) or "idle"
			end
			task.wait(0.5)
		end)
		if not ok then
			warn("[shootegg] boss:", err)
			task.wait(1)
		end
	end
end

-- shop loops ----------------------------------------------------------------------
local function ownedGuns()
	local set = {}
	for name in tostring(player:GetAttribute("OwnedWeapons") or ""):gmatch("[^,]+") do
		set[name] = true
	end
	return set
end
local function nextGun()
	local owned = ownedGuns()
	for _, name in ipairs(SD.gunOrder) do
		if not owned[name] then
			return name
		end
	end
	return nil
end
local function gunAffordable()
	local name = nextGun()
	if not name then
		return false
	end
	local req = SD.guns[name] and SD.guns[name].rebirth
	return num("Cash") >= WD.priceOf(name) and (not req or num("Rebirths") >= req)
end

local function waitAttr(attr, from, secs)
	local t0 = os.clock()
	while os.clock() - t0 < secs do
		if num(attr) ~= from then
			return true
		end
		task.wait(0.1)
	end
	return false
end

local function buyLoop()
	local backoff = { gun = 0, target = 0, pen = 0 }
	while running do
		local ok, err = pcall(function()
			local now = os.clock()
			if S.gun and now >= backoff.gun then
				local name = nextGun()
				if name and gunAffordable() then
					local before = tostring(player:GetAttribute("OwnedWeapons"))
					fire("buyGun", name)
					local t0 = os.clock()
					while os.clock() - t0 < 3 and tostring(player:GetAttribute("OwnedWeapons")) == before do
						task.wait(0.1)
					end
					if tostring(player:GetAttribute("OwnedWeapons")) ~= before then
						stats.bought += 1
						say("bought " .. name, "buy")
						first("buyGun", name)
					else
						backoff.gun = os.clock() + BUY_BACKOFF
						say("buyGun " .. name .. " not taken", "buy")
					end
				end
				local owned = ownedGuns()
				local top
				for _, g in ipairs(SD.gunOrder) do
					if owned[g] then
						top = g
					end
				end
				if top and tostring(player:GetAttribute("Weapon")) ~= top and not inBoss() then
					first("equipGun", top)
					fire("equipGun", top)
				end
			end
			if S.target and now >= backoff.target then
				local lvl = num("TargetLevel")
				local nxt = TD.next(lvl)
				if nxt and lvl < TD.MAX_LEVEL and num("Cash") >= nxt.cash then
					fire("buyTarget")
					if waitAttr("TargetLevel", lvl, 3) then
						stats.bought += 1
						first("buyTarget", lvl + 1)
					else
						backoff.target = os.clock() + BUY_BACKOFF
					end
				end
			end
			if S.pen and now >= backoff.pen then
				local lvl = num("PenLevel")
				local nxt = PD.next(lvl)
				if nxt and lvl < PD.MAX_LEVEL and num("Cash") >= nxt.cash then
					fire("buyPen")
					if waitAttr("PenLevel", lvl, 3) then
						stats.bought += 1
						first("buyPen", lvl + 1)
					else
						backoff.pen = os.clock() + BUY_BACKOFF
					end
				end
			end
		end)
		if not ok then
			warn("[shootegg] buy:", err)
		end
		task.wait(BUY_EVERY)
	end
end

local lastRebirth = 0
local function rebirthLoop()
	while running do
		local ok, err = pcall(function()
			if S.rebirth and not inBoss() and os.clock() - lastRebirth > REBIRTH_GAP then
				local n = num("Rebirths")
				if not RD.maxed(n) and num("Cash") >= RD.cost(n) * REBIRTH_X and not gunAffordable() then
					lastRebirth = os.clock()
					first("rebirth", n + 1, "cash", fmt(num("Cash")))
					fire("doRebirth")
					waitAttr("Rebirths", n, 4)
				end
			end
		end)
		if not ok then
			warn("[shootegg] rebirth:", err)
		end
		task.wait(5)
	end
end

local function claimLoop()
	while running do
		local ok, err = pcall(function()
			if S.claims then
				ev.daily, ev.wheel = nil, nil
				fire("dailyRequest")
				fire(WhD.REQUEST)
				local t0 = os.clock()
				while (not ev.daily or not ev.wheel) and os.clock() - t0 < 3 do
					task.wait(0.1)
				end
				if ev.daily and ev.daily.ready then
					first("dailyClaim")
					fire("dailyClaim")
					task.wait(1)
				end
				if ev.wheel and (tonumber(ev.wheel.spins) or 0) > 0 then
					first("wheelSpin")
					fire(WhD.SPIN)
					task.wait(WhD.SPIN_SECONDS + 1)
				end
			end
		end)
		if not ok then
			warn("[shootegg] claims:", err)
		end
		task.wait(CLAIM_EVERY)
	end
end

-- animals: equip best, then sell what is left of the rarities / below the floor ---------
local function rarityOf(animal)
	local ok, band = pcall(AD.band, animal)
	return ok and band or AD.bands[1]
end
local function sellLoop()
	local lastEquip = 0
	while running do
		local ok, err = pcall(function()
			if (S.sell or S.equip) and not inBoss() then
				if os.clock() - lastEquip > EQUIP_EVERY then
					lastEquip = os.clock()
					fire("equipBest")
					task.wait(1)
				end
			end
			-- a full pen refuses new eggs: store the weakest placed animal your filters would sell anyway (animalStore
			-- works from anywhere), and the sell pass below turns it into cash
			local plot = ownPlot()
			if (S.sell or S.rotate) and S.place and plot and penFull(plot) and #backpackEggs() > 0 and not inBoss() then
				local best = backpackEggs()[1]
				local expect = ED.eggs[best:GetAttribute("EggType")].income * EGG_TO_ANIMAL
				local weakest, wi, why
				for _, a in ipairs(plot:GetChildren()) do
					if a.Name == "HatchedAnimal" then
						local inc = tonumber(a:GetAttribute("Income")) or 0
						local byFilter = S.sell and (sellOn[rarityOf(tostring(a:GetAttribute("Animal") or ""))] or (minIncome > 0 and inc < minIncome))
						local byRotate = S.rotate and inc * ROTATE_X < expect
						if (byFilter or byRotate) and (not wi or inc < wi) then
							weakest, wi, why = a, inc, byFilter and "filter" or "rotate"
						end
					end
				end
				if weakest then
					first("make room", why, weakest:GetAttribute("Animal"), "income/s", fmt(wi), "for", best:GetAttribute("EggType"))
					fire("animalStore", weakest)
					if why == "rotate" then
						forceSell["A|" .. tostring(weakest:GetAttribute("Animal")) .. "|" .. tostring(weakest:GetAttribute("Variant"))] = true
					end
					task.wait(1)
				end
			end
			if (S.sell or next(forceSell)) and not inBoss() and num("CarriedPets") > 0 then
				ev.sellList = nil
				fire("sellRequest")
				local t0 = os.clock()
				while not ev.sellList and os.clock() - t0 < 2 do
					task.wait(0.1)
				end
				local list = ev.sellList and ev.sellList.items
				if type(list) == "table" then
					for _, it in ipairs(list) do
						if not running then
							break
						end
						if it.kind == "Animal" and it.id then
							local income = (tonumber(it.price) or 0) / AD.SELL_SECONDS
							local byBand = S.sell and sellOn[rarityOf(it.animal or "")]
							local byIncome = S.sell and minIncome > 0 and income < minIncome
							local forced = forceSell[it.id]
							if byBand or byIncome or forced then
								forceSell[it.id] = nil
								fire("sellOne", it.id)
								stats.sold += (tonumber(it.count) or 1)
								first("sell", it.id, "income/s", fmt(income), "band", rarityOf(it.animal or ""))
								task.wait(SELL_GAP)
							end
						end
					end
				end
			end
		end)
		if not ok then
			warn("[shootegg] sell:", err)
		end
		task.wait(SELL_EVERY)
	end
end

-- anti-afk: the game flags you idle at 60s and sends you to a new server at 1020s ---------
local function afkLoop()
	while running do
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
			local cam = workspace.CurrentCamera
			if cam then
				local c = cam.ViewportSize / 2
				VIM:SendMouseMoveEvent(c.X + math.random(-3, 3), c.Y + math.random(-3, 3), game)
			end
		end)
		task.wait(AFK_EVERY)
	end
end
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- watchdog: a farm thread parked in a yield cannot report itself --------------------------
task.spawn(function()
	while running do
		task.wait(5)
		if os.clock() - markAt > WATCHDOG and (S.hunt or S.place or S.hatch or S.pad) and mark ~= "director idle" and mark ~= "director waits for the boss fight" then
			warn(("[shootegg] stuck %ds at: %s"):format(os.clock() - markAt, mark))
			markAt = os.clock()
		end
	end
end)

task.spawn(function()
	while running do
		task.wait(STATS_EVERY)
		log(("stats: kills %d placed %d hatched %d sold %d shots %d bought %d boss %d (%d won) cash %s gun %s dmg %s"):format(
			stats.kills, stats.placed, stats.hatched, stats.sold, stats.shots, stats.bought, stats.boss, stats.bossWins,
			fmt(num("Cash")), tostring(player:GetAttribute("Weapon")), fmt(num("ShotDamage"))))
	end
end)
task.spawn(director)
task.spawn(bossLoop)
task.spawn(buyLoop)
task.spawn(rebirthLoop)
task.spawn(claimLoop)
task.spawn(sellLoop)
task.spawn(afkLoop)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Shoot for Eggs", statusBar = true })
if not Window then
	running = false
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "crosshair")
local Hunt = Tab:AddLeftGroupbox("Eggs", "egg")
local Plot = Tab:AddLeftGroupbox("Plot", "layout-grid")
local Boss = Tab:AddLeftGroupbox("Boss", "skull")
local Shop = Tab:AddRightGroupbox("Shop", "shopping-cart")
local Zoo = Tab:AddRightGroupbox("Animals", "paw-print")
local Extra = Tab:AddRightGroupbox("Extras", "sparkles")

local names = {}
for _, n in ipairs(ED.order) do
	if ED.eggs[n] then
		names[#names + 1] = n
		eggOn[n] = true -- Default does not fire the callback, so arm by hand
	end
end

Hunt:AddToggle("Hunt", {
	Text = "Auto Shoot Eggs",
	Tooltip = "Walks to the range deck and shoots wild eggs from the ones ticked below. A kill lands in your bag with no pickup. Turns the game's Killcam off while on",
	Default = false,
	Callback = function(v)
		S.hunt = v
		if not v then
			setKillcam(false)
		end
	end,
})
Hunt:AddToggle("Best", {
	Text = "Best egg first",
	Tooltip = "On: the highest-income egg you can break inside the kill cap that hatches inside the hatch cap. Off: the nearest ticked egg",
	Default = true,
	Callback = function(v)
		S.best = v
	end,
})
Hunt:AddDropdown("Eggs", {
	Text = "Eggs to shoot",
	Tooltip = "Only these are shot. All are ticked to start with",
	Values = names,
	Default = names,
	Multi = true,
	Callback = function(picked)
		table.clear(eggOn)
		for n in pairs(ticked(picked)) do
			eggOn[n] = true
		end
	end,
})
Hunt:AddInput("KillCap", {
	Text = "Max kill time (s)",
	Tooltip = "An egg that needs longer than this at your gun and damage is skipped. Raise it to reach better eggs",
	Default = tostring(KILL_CAP),
	Numeric = true,
	Finished = true,
	Callback = function(t)
		killCap = math.max(tonumber(t) or KILL_CAP, 1)
	end,
})
Hunt:AddInput("HatchCap", {
	Text = "Max hatch time (s)",
	Tooltip = "Best egg skips eggs that take longer than this to hatch",
	Default = tostring(HATCH_CAP),
	Numeric = true,
	Finished = true,
	Callback = function(t)
		hatchCap = math.max(tonumber(t) or HATCH_CAP, 1)
	end,
})
Plot:AddToggle("Place", {
	Text = "Auto Place Egg",
	Tooltip = "Equips each egg in your bag and places it on free ground of your plot, best income first",
	Default = false,
	Callback = function(v)
		S.place = v
		placeBlockedUntil = 0
	end,
})
Plot:AddToggle("Hatch", {
	Text = "Auto Hatch Egg",
	Tooltip = "Walks to each egg whose timer is up and presses its Hatch prompt (the server refuses beyond ~30 studs)",
	Default = false,
	Callback = function(v)
		S.hatch = v
	end,
})
Plot:AddToggle("Pad", {
	Text = "Idle on the damage pad",
	Tooltip = "Stands on your pad when nothing else needs doing: it pays damage and cash while you stand on it. Claims the bonus token it offers",
	Default = false,
	Callback = function(v)
		S.pad = v
	end,
})
Boss:AddToggle("Boss", {
	Text = "Auto Boss Fight",
	Tooltip = "Joins every boss (every 10 minutes), shoots it and walks out of each zone it announces. The server moves you to the arena and back",
	Default = false,
	Callback = function(v)
		S.boss = v
	end,
})
Shop:AddToggle("Gun", {
	Text = "Auto Buy Best Gun",
	Tooltip = "Buys the next gun in the game's order the moment you can pay for it (and the rebirth gate is open). The game equips it",
	Default = false,
	Callback = function(v)
		S.gun = v
	end,
})
Shop:AddToggle("Target", {
	Text = "Auto Upgrade Target",
	Tooltip = "Buys the next target level whenever you can pay. Your Robux route is never touched",
	Default = false,
	Callback = function(v)
		S.target = v
	end,
})
Shop:AddToggle("Pen", {
	Text = "Auto Buy Pen Slots",
	Tooltip = "More animals earning on your plot at once. Level 2 is cheap, level 3 is 16.7M",
	Default = false,
	Callback = function(v)
		S.pen = v
	end,
})
Zoo:AddToggle("Sell", {
	Text = "Auto Sell Animals",
	Tooltip = "Presses Equip Best, then sells backpack animals of the rarities ticked below or earning less than the income floor (about, for the backpack). With Auto Place on and the pen full it also stores the weakest matching animal off your plot to make room. Eggs are never sold",
	Default = false,
	Callback = function(v)
		S.sell = v
	end,
})
Zoo:AddDropdown("SellBand", {
	Text = "Rarities to sell",
	Tooltip = "Nothing is ticked to start with",
	Values = AD.bands,
	Default = {},
	Multi = true,
	Callback = function(picked)
		table.clear(sellOn)
		for n in pairs(ticked(picked)) do
			sellOn[n] = true
		end
	end,
})
Zoo:AddInput("MinIncome", {
	Text = "Sell below income/s",
	Tooltip = "Sell any backpack animal earning less than this per second. 0 turns it off",
	Default = "0",
	Numeric = true,
	Finished = true,
	Callback = function(t)
		minIncome = math.max(tonumber(t) or 0, 0)
	end,
})
Zoo:AddToggle("Rotate", {
	Text = "Replace weak animals with better eggs",
	Tooltip = "A full pen refuses new eggs. With Auto Place on, this stores the weakest placed animal and sells it when the best egg in your bag is expected to earn 2x more (a rough guess: an egg's animals earn about 10x its income number). Off by default",
	Default = false,
	Callback = function(v)
		S.rotate = v
	end,
})
Zoo:AddToggle("Equip", {
	Text = "Auto Equip Best Animals",
	Tooltip = "Presses the game's Equip Best every 20s so your best animals hold the plot slots",
	Default = false,
	Callback = function(v)
		S.equip = v
	end,
})
Extra:AddToggle("Claims", {
	Text = "Auto Claim Daily + Wheel",
	Tooltip = "Claims the daily reward and takes the wheel's free spin when it is ready",
	Default = false,
	Callback = function(v)
		S.claims = v
	end,
})
Extra:AddToggle("Rebirth", {
	Text = "Auto Rebirth",
	Tooltip = "WIPES your cash. Rebirths when Cash is 1.5x the cost and no gun is affordable: +50% cash and +25% damage each, cost x7 each",
	Default = false,
	Callback = function(v)
		S.rebirth = v
	end,
})

local function eggStatus()
	local plot = ownPlot()
	return ("%d held, %d placed"):format(heldEggs(), plot and #placedEggs(plot) or 0)
end

local note, buyNote = "idle", ""
local nextStrip = 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	if pending.now then
		note, pending.now = pending.now, nil
	end
	if pending.buy then
		buyNote, pending.buy = pending.buy, nil
	end
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	pcall(Window.SetStatus, Window, {
		{ "Cash", fmt(num("Cash")) },
		{ "Eggs", eggStatus() },
		{ "Gun", tostring(player:GetAttribute("Weapon")) .. " " .. fmt(num("ShotDamage")) },
		{ "Kills", stats.kills },
		{ "Hatched", stats.hatched },
		{ "Sold", stats.sold },
		{ "Boss", bossNote .. (stats.bossWins > 0 and (" (" .. stats.bossWins .. " won)") or "") },
		{ "Bought", buyNote ~= "" and buyNote or stats.bought },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("ShootForEggs", {})

-- close ----------------------------------------------------------------------
local function stopAll()
	running = false
	for k in pairs(S) do
		S[k] = false
	end
	setKillcam(false)
	pcall(function()
		VIM:SendKeyEvent(false, Enum.KeyCode.W, false, game)
		VIM:SendKeyEvent(false, Enum.KeyCode.A, false, game)
		VIM:SendKeyEvent(false, Enum.KeyCode.S, false, game)
		VIM:SendKeyEvent(false, Enum.KeyCode.D, false, game)
	end)
	for _, c in ipairs(conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().shootEggsStop = nil
end)

getgenv().shootEggsStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().shootEggsStop = nil
end
