--[[ Warrior Evolution -- stage laps for Wins, train on the best zone, rebirth, guns, skins, pets (96124247562170)

     PlaceVersion 2665

     FARM    : a lap = cross each stage's Entrance wall in order and stand just past it; the SERVER kills the stage's
               mobs by itself (about 1.5-3s a stage, no SetGunTarget / PunchRequest needed), then touch the last stage's
               win pad. The pad pays W<stage> Wins (AutoplayCourse "W" attributes: 650 at stage 8, 100K at 15) and the
               server sends you back to the lobby. Depth is the whole game: W grows ~2x a stage, a stage costs ~2.5s. The
               script climbs one stage per good lap and parks a stage where you died or the fight timed out, until
               DamageMult has grown 25% or you rebirthed.
     TRAIN   : occupancy. Standing inside a Targets zone's bounding box sets OnTarget and the server pays Exp (~420K/s on
               zone 5 at 7 rebirths, nothing on the wire). The best zone is the highest ExpMult your Rebirths unlock; the
               gamepass zones (TargetX10 / X50 / X250) are skipped unless you own them.
     REBIRTH : RebirthRequest() once Level >= RebirthConfig.RequiredLevel(Rebirths). Resets Level; Wins, guns, pets stay.
     GUNS    : GunShopConfig ladder in order. No remote: the pad's GunPrompt is the buy. Hop to it, press, confirm on
               OwnedGuns, EquipGun the best.
     SKINS   : GunSkinAction(id) for Wins skins, cheapest first. PETS: HatchEgg for the best Wins egg, EquipBestPets /
               EquipBestItems. ABILITIES: FireAbility on cooldown during a fight or while training.
     CLAIMS  : wheel spin, daily, playtime tiers, missions (all free, server decides). POTIONS: UsePotion for the Wins /
               Power / Coin ones when none is running.

     Movement: hops of <=85 studs every 0.3s (probed: single hops held to 100, 150 reverted; 8 hops at 300 studs/s held).
     The anti-cheat verdict was KICK-WEIGHTED; the user said yes to hop tests in chat on 2026-10-13. Stand just inside the
     Entrance, never on the enemy spawn: stage 8 killed the character at the spawn centre in 2s (1019 HP).

     PROBED (2026-10-13, live): stage fights are server-side, ~2s a stage up to 12; the Entrance must be LANDED IN and the
     server must have set Stage = n (0.6s dwell worked, 0.15s did not) or the pad pays nothing; the pad pays on a plain
     firetouchinterest from up to 75 studs away. Mobs are client rigs (workspace.EnemyRigs_Client), workspace.Enemies stays
     empty. The equipped gun's RANGE decides who you can hit: the auto-bought SPAS-12 / Benelli reach 45 (SCAR-L 90), so a
     Sniper holding 50 studs off is only killed after an approach hop. Stage 13 was a power wall at 1.4B DamageMult with
     the Benelli (parked, retried after DamageMult +25%). AFK pads in this game are the Targets zones; their Exp scales
     with the equipped gun (224M/s on zone 7 after M82).
     PROBED AND DEAD: hopping to World 2 / 3 zones (the straight line crosses void, fell to y = -357 by the 4th hop); a
     hop of 150 studs (reverted, 100 held); standing on the enemy spawn at stage 8 (dead in 2s); the 3-stud arrival
     tolerance at y = 6 over a ground of y = 3 (never arrives: compare horizontally).
     UNPROBED: WorldTravel (answers "far" past PORTAL_REACH 30, needs stage 15 / 30 cleared), the Alien / Ninja stage
     lanes, UseNuke (a free nuke is granted on a death at a new frontier stage), the daily / playtime / mission claim
     replies (sent, answers not read), HatchEgg x3.

     Not wired (Robux): every ProductRequest / GamepassRequest (guns, skins, eggs, AutoRebirth, Autoplay, x3 hatch,
     nukes), the Robux and Token eggs, the x2 Wins pad. Not built: world travel (World 2 and 3 stages 16-45; WorldTravel
     answers "far" past PORTAL_REACH 30).

     RightControl opens / closes the panel. Stop: getgenv().warriorEvoStop() ]]

-- config ---------------------------------------------------------------------
local HOP_STEP = 85 -- studs per hop. A single hop of 100 held, 150 reverted; keep well under
local HOP_GAP = 0.3 -- seconds between hops. 90 studs / 0.3s (300 studs/s) held for 8 hops; raise if a lap reverts
local STAND_PAST = 6 -- studs past an Entrance to wait out the fight. The enemy spawn itself killed us at stage 8
local CROSS_WAIT = 1.5 -- seconds an Entrance has to set Stage = n after we land in it (0.6 worked, 0.15 did not)
local ENGAGE_WAIT = 2.5 -- after crossing, seconds to wait for the fight to show before calling the stage already cleared
local FIGHT_TIMEOUT = 60 -- one stage's fight gives up after this long (then that depth is parked)
local FIGHT_STALL = 12 -- ...or when no mob has died for this long (a stage-10 mob took ~6s to die with the same gun)
local KITE_DIST = 30 -- a mob this close makes the character hop away. Melee mobs hit at 3.4 and sprint 24 studs/s
local KITE_GAIN = 12 -- a hop must put at least this many more studs between us and the nearest mob
local KITE_GAP = 0.4 -- seconds between kite hops (<= 85 studs each, inside the 300 studs/s that held)
local STALL_APPROACH = 4 -- no mob died for this long: hop toward the nearest one (it is out of the gun's range)
local PAD_WAIT = 3 -- seconds the pad has to pay (Wins change) after the touch
local PARK_DAMAGE = 1.25 -- a parked stage opens again once DamageMult is this much higher than when it failed
local SAFE_FRACTION = 0.5 -- a stage that was cleared at some DamageMult is only tried again above this share of it
local TRAIN_SECS = 90 -- Auto mode: seconds on the target before a farm phase. Raise for more Exp, lower for more Wins
local FARM_SECS = 60 -- Auto mode: seconds of laps per phase
local TRAIN_SLICE = 4 -- one director pass on the target
local ERRAND_EVERY = 4 -- seconds between spending checks
local SPEND_FRACTION = 0.5 -- skins and eggs cost at most this share of Wins (the next gun is never held back)
local PRESS_TRIES = 4 -- prompt presses per gun before it is parked
local CONFIRM = 3 -- seconds a purchase has to show in the world
local PARK = 60 -- a pad or purchase that refused is left alone this long
local REBIRTH_EVERY = 3
local CLAIM_EVERY = 90
local ANTIAFK_EVERY = 45 -- the game sends AntiAFK_Heartbeat on real input every 60s
local PETS_EVERY = 120
local STUCK_AFTER = 40 -- the watchdog names the step the director has sat in this long

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")
local player = Players.LocalPlayer

if getgenv and getgenv().warriorEvoStop then
	getgenv().warriorEvoStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[warrior]", ...)
end

local seen = {}
local function first(name, ...) -- one console line per unproven branch
	if not seen[name] then
		seen[name] = true
		log(name, ...)
	end
end

-- the panel strip is drained from a Heartbeat (a resumed thread throws "lacking capability Plugin" on its second write)
local pending, lastSaid = {}, nil
local function say(msg)
	pending.now = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

local mark, markAt = "idle", os.clock() -- breadcrumb for the watchdog thread
local function step(s)
	mark, markAt = s, os.clock()
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
assert(fmt(25000) == "25K" and fmt(1500) == "1.5K" and fmt(260e9) == "260B" and fmt(100) == "100", "fmt")

local function csv(s) -- "A,B,C" -> { A = true, B = true, C = true }
	local t = {}
	for part in tostring(s or ""):gmatch("[^,]+") do
		t[part] = true
	end
	return t
end
assert(csv("Colt 1911,Deagle").Deagle and not csv("").x and csv("a,b").b, "csv")

-- game -----------------------------------------------------------------------
local Packets = require(ReplicatedStorage:WaitForChild("Packets", 15))
local SD = ReplicatedStorage:WaitForChild("SharedData", 15)
local okw, WorldConfig = pcall(require, SD:WaitForChild("WorldConfig", 10))
local okg, GunShop = pcall(require, SD:WaitForChild("GunShopConfig", 10))
local oks, SkinCfg = pcall(require, SD:WaitForChild("GunSkinConfig", 10))
local okp, PetCfg = pcall(require, SD:WaitForChild("PetConfig", 10))
local oka, AbilityCfg = pcall(require, SD:WaitForChild("AbilityConfig", 10))
local okr, RebirthCfg = pcall(function()
	return require(ReplicatedStorage:WaitForChild("RebirthSystem", 10):WaitForChild("RebirthConfig", 10))
end)
local Course = ReplicatedStorage:WaitForChild("AutoplayCourse", 15)
if not (okw and okg and okr and Course and Packets) then
	warn("[warrior] the game's modules did not load:", WorldConfig, GunShop, RebirthCfg)
	return
end
local function A(name)
	return player:GetAttribute(name)
end
local function N(name)
	return tonumber(player:GetAttribute(name)) or 0
end

-- one Packets call that cannot park the caller: a Response packet yields until the server answers
local function send(name, ...)
	local p = Packets[name]
	if not p then
		first("no packet " .. name)
		return false
	end
	local args, done, res = table.pack(...), false, nil
	task.spawn(function()
		local ok, r = pcall(function()
			return p:Fire(table.unpack(args, 1, args.n))
		end)
		res = ok and r or nil
		done = true
	end)
	local t = os.clock()
	while not done and os.clock() - t < 4 do
		task.wait(0.05)
	end
	return done, res
end

-- movement -------------------------------------------------------------------
local function character()
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	local root = ch and ch:FindFirstChild("HumanoidRootPart")
	if hum and root and hum.Health > 0 then
		return hum, root
	end
	return nil, nil
end

-- Hops of <= HOP_STEP; true when there. A hop that the server undid three times in a row ends the trip.
local function hopTo(pos, alive)
	local bad = 0
	for _ = 1, 80 do
		if alive and not alive() then
			return false, "stopped"
		end
		local hum, root = character()
		if not hum then
			return false, "no character"
		end
		local d = pos - root.Position
		if Vector3.new(d.X, 0, d.Z).Magnitude < 2.5 and math.abs(d.Y) < 8 then
			return true
		end
		local stepv = d.Magnitude > HOP_STEP and d.Unit * HOP_STEP or d
		local target = root.Position + stepv
		root.CFrame = CFrame.new(target)
		task.wait(HOP_GAP)
		local _, r2 = character()
		if not r2 then
			return false, "no character"
		end
		if (r2.Position - target).Magnitude > 8 then
			bad += 1
			if bad >= 3 then
				return false, "reverted"
			end
		else
			bad = 0
		end
	end
	return false, "hop timeout"
end

-- state ----------------------------------------------------------------------
local dead, gen = false, 0
local farmOn, trainOn = false, false
local rebirthOn, gunsOn, skinsOn, petsOn, abilitiesOn, claimsOn, potionsOn = false, false, false, false, false, false, false
local maxStageCap = 0 -- 0 = learn it
local trainSecs, farmSecs = TRAIN_SECS, FARM_SECS
local phase, phaseAt = "farm", os.clock()
local conns = {} -- RBXScriptConnections, disconnected on unload
local tokens = {} -- side-loop generation tokens; clearing the table ends the loops
local parked = {} -- [key] = os.clock() it may be tried again
local stageParked = {} -- [stage] = { dmg = DamageMult } where a lap died or timed out
local okAt = {} -- [stage] = lowest DamageMult a lap has finished that stage at
local maxSeen = 0 -- highest stage this session finished a lap at
local stats = { laps = 0, fails = 0, wins = 0, rebirths = 0, guns = 0, skins = 0, eggs = 0 }
local lapDepth = 0

local function isParked(key)
	return (parked[key] or 0) > os.clock()
end

local function alive()
	return not dead and (farmOn or trainOn)
end

-- farm -----------------------------------------------------------------------
local function worldRow()
	local ok, w = pcall(WorldConfig.Of, player)
	if ok and type(w) == "table" and w.FirstStage then
		return w
	end
	return { FirstStage = 1, LastStage = 15, Id = "Army" }
end

local function coursePoint(prefix, stage)
	local v = Course:GetAttribute(prefix .. stage)
	return typeof(v) == "Vector3" and v or nil
end

-- the world row names where its stages live ("GameMechanics.Stages", "World 2.GameMechanics.Stages")
local function stageFolder(stage)
	local ok, w = pcall(WorldConfig.ForStage, stage)
	local node = ok and type(w) == "table" and w.Stages and workspace
	for part in tostring(ok and type(w) == "table" and w.Stages or ""):gmatch("[^%.]+") do
		node = node and node:FindFirstChild(part)
	end
	return node and node:FindFirstChild("Stage" .. stage) or nil
end

-- the stage to try this lap: climb one past the best finished lap, stop under the first parked stage
local function chooseDepth()
	local w = worldRow()
	local last = w.LastStage
	if maxStageCap > 0 then
		last = math.min(last, maxStageCap)
	end
	local dmg = N("DamageMult")
	local open = w.FirstStage
	for s = w.FirstStage, last do
		local p = stageParked[s]
		if p and dmg < p.dmg * PARK_DAMAGE then
			break
		end
		stageParked[s] = nil
		-- a rebirth drops DamageMult to a fraction of what cleared this stage (8.3M -> 148K): do not expect the same
		if okAt[s] and dmg < okAt[s] * SAFE_FRACTION then
			break
		end
		open = s
	end
	local frontier = math.max(maxSeen, N("StageCleared"), w.FirstStage - 1) + 1
	return math.max(w.FirstStage, math.min(open, frontier, last)), w
end

-- The mobs are CLIENT rigs: workspace.Enemies stays empty mid-fight (probed), the models are "Guard 10_74847" and the
-- like under workspace.EnemyRigs_Client (there are several folders of that name). Positions inside the stage's lane only,
-- since the rigs of the stage before linger for a second after they die.
local function mobPositions(E, X)
	local out = {}
	local lo, hi = E.X - 10, (X and X.X or E.X + 70) + 10
	for _, f in ipairs(workspace:GetChildren()) do
		if f.Name == "EnemyRigs_Client" then
			for _, m in ipairs(f:GetChildren()) do
				if m:IsA("Model") and m.Name:find("_%d+$") then
					local ok, cf = pcall(m.GetPivot, m)
					local p = ok and cf.Position
					if p and p.X >= lo and p.X <= hi and math.abs(p.Z - E.Z) <= 30 then
						table.insert(out, p)
					end
				end
			end
		end
	end
	return out
end

-- Keep distance. Melee mobs sprint at ~24 studs/s (probed: Guards and Chargers crossed 90 studs in 3.5s) and the gun
-- reaches 45-90, so when one closes inside KITE_DIST the character hops to whichever spot of the lane is farthest from
-- every mob, if that gains KITE_GAIN studs: one hop of <=85 buys about three seconds. A Sniper holds 40-55 studs off
-- whatever you do, so it never triggers a hop on its own.
local kiteOn, lastKite, kites = true, 0, 0
local _, GunCfg = pcall(require, SD:WaitForChild("GunConfig", 10))
local function gunRange()
	local ok, r = pcall(GunCfg.RangeOf, A("EquippedGun"))
	return ok and tonumber(r) or 60
end
local function kite(n, E, stalled)
	local hum, root = character()
	local X = coursePoint("X", n)
	if not hum or os.clock() - lastKite < KITE_GAP then
		return
	end
	local mobs = mobPositions(E, X)
	if #mobs == 0 then
		return
	end
	local function clearance(p) -- distance to the nearest mob
		local best = math.huge
		for _, m in ipairs(mobs) do
			best = math.min(best, (Vector3.new(m.X, 0, m.Z) - Vector3.new(p.X, 0, p.Z)).Magnitude)
		end
		return best
	end
	local here = clearance(root.Position)
	local range = gunRange()
	local lo, hi = E.X + 2, (X and X.X or E.X + 70) - 3
	if here >= math.min(KITE_DIST, range * 0.5) then
		-- nobody is close, yet nothing has died for a while: a mob (a Sniper holds 40-55 studs off) is out of the gun's
		-- reach. Close in on the nearest one until it is inside 60% of the range, then the kite rule takes over again.
		if stalled and here > range * 0.8 then
			local nearest
			for _, m in ipairs(mobs) do
				if not nearest or (m - root.Position).Magnitude < (nearest - root.Position).Magnitude then
					nearest = m
				end
			end
			local dir = Vector3.new(root.Position.X - nearest.X, 0, root.Position.Z - nearest.Z)
			dir = dir.Magnitude > 0.5 and dir.Unit or Vector3.new(-1, 0, 0)
			local want = nearest + dir * (range * 0.6)
			lastKite = os.clock()
			root.CFrame = CFrame.new(math.clamp(want.X, lo, hi), 4, math.clamp(want.Z, E.Z - 12, E.Z + 12))
			first("approach hop", ("stage %d: nearest mob %.0f studs, gun range %.0f"):format(n, here, range))
		end
		return
	end
	local best, bestC = nil, here + KITE_GAIN
	for fx = 0, 1, 1 / 3 do -- (lo and hi were set above)
		for _, dz in ipairs({ -8, 0, 8 }) do
			local p = Vector3.new(lo + (hi - lo) * fx, 4, E.Z + dz)
			local c = clearance(p)
			if c > bestC then
				best, bestC = p, c
			end
		end
	end
	if not best then
		return -- the mobs are all round the lane: standing still is as good as any hop
	end
	lastKite = os.clock()
	kites += 1
	root.CFrame = CFrame.new(best)
	first("kite hop", ("stage %d: nearest mob %.0f studs, hopped to a spot %.0f from it"):format(n, here, bestC))
end

-- wait for stage n's fight: the encounter shows (EncounterRemaining > 0) then empties. A stage the run counter already
-- covers (StageClearedRun >= n when we crossed) has no fight at all. A fight ends on the clock only when it makes no
-- progress (the mob count has not dropped for FIGHT_STALL) or runs past FIGHT_TIMEOUT: kiting makes slow kills survivable.
local function fight(n, E, runAtCross)
	if runAtCross >= n then
		first("stage " .. n .. " has no fight (run counter was ahead)")
		task.wait(0.3)
		return true
	end
	local t, sawEnc, lastEnc, lastDrop = os.clock(), false, -1, os.clock()
	while os.clock() - t < FIGHT_TIMEOUT do
		if not alive() then
			return false, "stopped"
		end
		if not character() then
			return false, "died"
		end
		if kiteOn and E then
			pcall(kite, n, E, sawEnc and os.clock() - lastDrop > STALL_APPROACH)
		end
		local enc = N("EncounterRemaining")
		if enc > 0 then
			sawEnc = true
		end
		if enc ~= lastEnc then
			lastEnc, lastDrop = enc, os.clock()
		end
		if sawEnc and enc == 0 then
			return true
		end
		if not sawEnc and os.clock() - t > ENGAGE_WAIT and enc == 0 then
			first("stage " .. n .. " showed no fight within " .. ENGAGE_WAIT .. "s")
			return true
		end
		if sawEnc and os.clock() - lastDrop > FIGHT_STALL then
			return false, ("no kill for %ds (%d mobs left)"):format(FIGHT_STALL, enc)
		end
		task.wait(0.1)
	end
	return false, "fight timeout"
end

local function padTouch(depth)
	local f = stageFolder(depth)
	local pads = f and f:WaitForChild("WinPads", 3)
	local pad = pads and pads:FindFirstChild(A("x2Wins") == true and "Gamepass" or "Normal")
	local part = pad and pad:WaitForChild("Touch", 3)
	local _, root = character()
	if not (part and root) then
		return false, "pad not streamed"
	end
	local before, lapsBefore = N("Wins"), N("WinPadLaps")
	local function paid()
		return N("Wins") > before or N("WinPadLaps") > lapsBefore -- Wins alone can fall under a purchase made in the same second
	end
	local function waitPaid()
		local t = os.clock()
		while os.clock() - t < PAD_WAIT and not paid() do
			task.wait(0.1)
		end
		return paid()
	end
	firetouchinterest(root, part, 0)
	task.wait(0.2)
	firetouchinterest(root, part, 1)
	if not waitPaid() then -- the touch event can be dropped: stand on the pad itself and try once more
		first("pad touch dropped, standing on it")
		root.CFrame = CFrame.new(part.Position + Vector3.new(0, 3, 0))
		task.wait(0.4)
		firetouchinterest(root, part, 0)
		task.wait(0.2)
		firetouchinterest(root, part, 1)
		waitPaid()
	end
	if not paid() then
		log(("pad %d unpaid: Stage %s Run %s Arena %s Laps %s"):format(depth, tostring(A("Stage")), tostring(A("StageClearedRun")), tostring(A("StageArena")), tostring(A("WinPadLaps"))))
	end
	return paid(), N("Wins") - before
end

local function waitAlive(secs)
	local t = os.clock()
	while os.clock() - t < secs and alive() do
		if character() then
			return true
		end
		task.wait(0.2)
	end
	return character() ~= nil
end

-- one lap to `depth`; returns true when the pad paid
local function lap()
	local depth, w = chooseDepth()
	lapDepth = depth
	local e1 = coursePoint("E", w.FirstStage)
	if not e1 then
		say("farm: no course points yet")
		task.wait(2)
		return false
	end
	local t0, wins0 = os.clock(), N("Wins")
	step("lap " .. depth .. " / lobby")
	if not waitAlive(12) then
		return false
	end
	local ok, why = hopTo(Vector3.new(e1.X - 35, 4, e1.Z), alive)
	if not ok then
		say("lap: " .. tostring(why) .. " going to the lobby")
		task.wait(1)
		return false
	end
	for n = w.FirstStage, depth do
		local E = coursePoint("E", n)
		if not E then
			return false
		end
		step(("lap %d / stage %d cross"):format(depth, n))
		local okc, whyc = hopTo(Vector3.new(E.X - 3, 4, E.Z), alive)
		local _, root = character()
		if not (okc and root) then
			say(("lap %d: %s before stage %d"):format(depth, tostring(whyc), n))
			return false
		end
		local runAtCross = N("StageClearedRun")
		-- The Entrance is a 0.6-stud wall: land in it (hopping past never touches it) and stay until the server has
		-- recorded Stage = n. The pad pays by that attribute, so a 0.15s dwell that skipped it paid nothing.
		local crossed = false
		for attempt = 1, 2 do
			local _, r = character()
			if not r then
				return false
			end
			r.CFrame = CFrame.new(E.X + 0.2, 4, E.Z)
			local tc = os.clock()
			while os.clock() - tc < CROSS_WAIT and N("Stage") ~= n do
				task.wait(0.05)
			end
			if N("Stage") == n then
				crossed = true
				break
			end
			r.CFrame = CFrame.new(E.X - 3, 4, E.Z) -- step back out and cross again
			task.wait(0.3)
		end
		if not crossed then
			say(("lap %d: entrance %d did not register"):format(depth, n))
			log(("lap %d: entrance %d did not register (Stage %s)"):format(depth, n, tostring(A("Stage"))))
			return false
		end
		local _, r3 = character()
		if not r3 then
			return false
		end
		r3.CFrame = CFrame.new(E.X + STAND_PAST, 4, E.Z)
		step(("lap %d / stage %d fight"):format(depth, n))
		say(("lap to stage %d: fighting %d"):format(depth, n))
		local okf, whyf = fight(n, E, runAtCross)
		if not okf then
			if whyf ~= "stopped" then
				stageParked[n] = { dmg = N("DamageMult") }
				maxSeen = math.min(maxSeen, n - 1)
				stats.fails += 1
				log(("lap %d failed at stage %d: %s (hp %s, DamageMult %s, parked)"):format(depth, n, whyf, character() and "ok" or "dead", fmt(N("DamageMult"))))
				waitAlive(15)
			end
			return false
		end
	end
	step("lap " .. depth .. " / pad")
	local X, Ez = coursePoint("X", depth), coursePoint("E", depth)
	if X and Ez then -- the pad sits past the Exit, outside streaming range from where the fight was: go and let it load
		hopTo(Vector3.new(X.X - 4, 4, Ez.Z), alive)
	end
	local paid, got = padTouch(depth)
	if paid then
		stats.laps += 1
		stats.wins += got
		maxSeen = math.max(maxSeen, depth)
		for s = w.FirstStage, depth do
			okAt[s] = math.min(okAt[s] or math.huge, N("DamageMult"))
		end
		local dt = os.clock() - t0
		log(("lap %d ok: +%s Wins in %.1fs (%s/s), Wins %s"):format(depth, fmt(got), dt, fmt(got / dt), fmt(N("Wins"))))
		task.wait(0.4) -- the server moves us to the lobby right after the pay
		return true
	end
	first("pad did not pay", got)
	log(("lap %d: pad did not pay (%s); Wins %s -> %s"):format(depth, tostring(got), fmt(wins0), fmt(N("Wins"))))
	return false
end

-- train ----------------------------------------------------------------------
-- Only the world you stand in. World 2 and 3 have zones worth 10x more (AlienTarget1 x200 for 0 rebirths) but they sit
-- 1800 / 3600 studs away over void: a straight hop falls to y = -357 (probed), WorldTravel is the only way there.
local function targetModels()
	local out = {}
	local stages = tostring(worldRow().Stages or "")
	local rootName = stages:match("^([^%.]+)%.") -- "World 2.GameMechanics.Stages" -> "World 2"; World 1 has none
	local root = rootName and rootName ~= "GameMechanics" and workspace:FindFirstChild(rootName) or workspace
	local gm = root:FindFirstChild("GameMechanics")
	local folder = gm and gm:FindFirstChild("Targets")
	for _, m in ipairs(folder and folder:GetChildren() or {}) do
		if m:IsA("Model") and m:GetAttribute("ExpMult") then
			table.insert(out, m)
		end
	end
	return out
end

-- highest ExpMult the rebirths unlock; the gamepass zones count only when the matching attribute is on
local function bestTarget()
	local best
	for _, m in ipairs(targetModels()) do
		local gp = m:GetAttribute("GamepassKey")
		local ok = N("Rebirths") >= (m:GetAttribute("RebirthsRequired") or 0) and (not gp or A(gp) == true)
		if ok and (not best or m:GetAttribute("ExpMult") > best:GetAttribute("ExpMult")) then
			best = m
		end
	end
	return best
end

local lastTarget
local function trainSlice(secs)
	local m = bestTarget()
	if not m then
		say("train: no zone unlocked")
		task.wait(2)
		return
	end
	if m ~= lastTarget then
		lastTarget = m
		log(("training zone %s (x%s Exp)"):format(m.Name, tostring(m:GetAttribute("ExpMult"))))
	end
	local cf = m:GetBoundingBox()
	local t = os.clock()
	local offAt
	while alive() and os.clock() - t < secs do
		local hum, root = character()
		if not hum then
			waitAlive(12)
		elseif A("OnTarget") ~= true then
			offAt = offAt or os.clock()
			if os.clock() - offAt > 0.8 or (root.Position - cf.Position).Magnitude > 30 then
				step("train / hop onto " .. m.Name)
				hopTo(cf.Position, alive)
				offAt = nil
				task.wait(0.6) -- OnTarget is the server's answer: give it a tick
			end
		else
			offAt = nil
		end
		step("train / on " .. m.Name)
		say(("training zone %s, Exp %s/s"):format(m.Name, fmt(0)))
		task.wait(0.4)
	end
end

-- errands: guns, skins, eggs (the director walks; the rest are timers) ---------
local function ownedGuns()
	return csv(A("OwnedGuns"))
end

local function pressPrompt(prompt, confirm)
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 30
	for i = 1, PRESS_TRIES do
		pcall(fireproximityprompt, prompt)
		local t = os.clock()
		while os.clock() - t < CONFIRM / PRESS_TRIES + 0.4 do
			if confirm() then
				return true, i
			end
			task.wait(0.1)
		end
	end
	return confirm(), PRESS_TRIES
end

local function gunErrand()
	local owned = ownedGuns()
	local idx = GunShop.NextPurchasable(owned)
	local row = idx and GunShop.LADDER[idx]
	if not row or isParked("gun" .. idx) or N("Wins") < row.Cost then
		return false, row and row.Cost or math.huge
	end
	local btn = GunShop.FindButton(idx)
	local prompt = btn and btn:FindFirstChildWhichIsA("ProximityPrompt", true)
	local part = prompt and prompt:FindFirstAncestorWhichIsA("BasePart")
	if not part then
		parked["gun" .. idx] = os.clock() + PARK
		first("gun " .. row.Name .. " has no pad streamed in")
		return false, row.Cost
	end
	step("gun " .. row.Name .. " / hop")
	say(("buying %s (%s Wins)"):format(row.Name, fmt(row.Cost)))
	local ok, why = hopTo(part.Position + Vector3.new(0, 3, 0), alive)
	if not ok then
		parked["gun" .. idx] = os.clock() + PARK
		log("gun hop failed:", why)
		return false, row.Cost
	end
	task.wait(0.4)
	step("gun " .. row.Name .. " / press")
	local got, tries = pressPrompt(prompt, function()
		return ownedGuns()[row.Name] == true
	end)
	if got then
		stats.guns += 1
		log(("bought %s (press %d), Wins %s"):format(row.Name, tries, fmt(N("Wins"))))
		if A("EquippedGun") ~= row.Name then
			send("EquipGun", row.Name)
		end
		return true, row.Cost
	end
	parked["gun" .. idx] = os.clock() + PARK
	log(("gun %s: %d presses, not owned (Wins %s, cost %s)"):format(row.Name, tries, fmt(N("Wins")), fmt(row.Cost)))
	return false, row.Cost
end

-- What skins and eggs may spend: the Wins above the next gun's price (a gun of another world does not count: it is not
-- buyable from here), times SPEND_FRACTION. Without the reserve the cheap egg loop ate every Win the guns were waiting for.
local function budget()
	local idx = GunShop.NextPurchasable(ownedGuns())
	local row = idx and GunShop.LADDER[idx]
	local reserve = (row and (not row.World or row.World == worldRow().Id)) and row.Cost or 0
	return math.max(0, N("Wins") - reserve) * SPEND_FRACTION
end
assert(SPEND_FRACTION > 0 and SPEND_FRACTION <= 1, "SPEND_FRACTION")

local function skinTick() -- no body needed: GunSkinAction is one packet
	if not oks then
		return
	end
	local owned, have = csv(A("OwnedGunSkins")), budget()
	local pick, cost
	for id, s in pairs(SkinCfg.Skins) do
		if s.Source == "Wins" and s.Cost and not owned[id] and not isParked("skin" .. id) and s.Cost <= have then
			if not cost or s.Cost < cost then
				pick, cost = id, s.Cost
			end
		end
	end
	if not pick then
		return
	end
	send("GunSkinAction", pick)
	local t = os.clock()
	while os.clock() - t < CONFIRM and not csv(A("OwnedGunSkins"))[pick] do
		task.wait(0.1)
	end
	if csv(A("OwnedGunSkins"))[pick] then
		stats.skins += 1
		log(("bought skin %s (%s Wins)"):format(pick, fmt(cost)))
	else
		parked["skin" .. pick] = os.clock() + PARK
		log("skin " .. pick .. " refused (Wins " .. fmt(have) .. ")")
	end
end

local function eggTick()
	if not okp or N("PetCount") >= N("PetStorage") - 1 or A("EggHatching") == true then
		return
	end
	local have, pick, pickOrder = budget(), nil, -1
	for name, e in pairs(PetCfg.Eggs) do
		local wins = tostring(e.CostType or "Wins"):lower():find("win") ~= nil
		if wins and (not e.World or e.World == (worldRow().Id)) and e.Cost <= have and not isParked("egg" .. name) and (e.Order or 0) > pickOrder then
			pick, pickOrder = name, e.Order or 0
		end
	end
	if not pick then
		return
	end
	local before = N("PetCount")
	step("egg " .. pick)
	send("HatchEgg", pick, false)
	local t = os.clock()
	while os.clock() - t < 8 and N("PetCount") == before do
		task.wait(0.2)
	end
	if N("PetCount") > before then
		stats.eggs += 1
		log("hatched " .. pick .. ", pets " .. N("PetCount"))
		send("EquipBestPets")
	else
		parked["egg" .. pick] = os.clock() + PARK
		log("egg " .. pick .. " gave no pet (Wins " .. fmt(have) .. ")")
	end
end

-- director -------------------------------------------------------------------
local directorGen = 0
local function director(mine)
	local nextErrand = 0
	while alive() and directorGen == mine do
		local now = os.clock()
		if now >= nextErrand then
			nextErrand = now + ERRAND_EVERY
			if gunsOn then
				pcall(gunErrand)
			end
			if petsOn then
				pcall(eggTick)
			end
		end
		if farmOn and trainOn then
			local span = phase == "train" and trainSecs or farmSecs
			if os.clock() - phaseAt > span then
				phase = phase == "train" and "farm" or "train"
				phaseAt = os.clock()
				log("phase " .. phase)
			end
		else
			phase = farmOn and "farm" or "train"
		end
		if phase == "farm" then
			local ok, err = pcall(lap)
			if not ok then
				warn("[warrior] lap threw:", err)
				task.wait(1)
			end
		else
			local ok, err = pcall(trainSlice, TRAIN_SLICE)
			if not ok then
				warn("[warrior] train threw:", err)
				task.wait(1)
			end
		end
		task.wait()
	end
	if directorGen == mine then
		step("idle")
		say("idle")
	end
end

local function ensureDirector()
	if (farmOn or trainOn) and not (dead or tokens.director) then
		tokens.director = true
		directorGen += 1
		local mine = directorGen
		task.spawn(function()
			step("director")
			local ok, err = pcall(director, mine)
			if not ok then
				warn("[warrior] director died:", err)
			end
			if directorGen == mine then
				tokens.director = nil
			end
		end)
	end
end

-- side loops (no body needed) --------------------------------------------------
local function loopFlag(key, flag, every, body)
	return function(state)
		if state and not tokens[key] then
			gen += 1
			local mine = gen
			tokens[key] = mine
			task.spawn(function()
				while not dead and flag() and tokens[key] == mine do
					local ok, err = pcall(body)
					if not ok then
						warn("[warrior] " .. key .. ":", err)
					end
					task.wait(every)
				end
				if tokens[key] == mine then
					tokens[key] = nil
				end
			end)
		end
	end
end

local rebirthAt = 0
local function rebirthBody()
	local need = RebirthCfg.RequiredLevel(N("Rebirths"))
	if N("Level") >= need and os.clock() - rebirthAt > 6 then
		rebirthAt = os.clock()
		local before = N("Rebirths")
		step("rebirth")
		send("RebirthRequest")
		local t = os.clock()
		while os.clock() - t < 4 and N("Rebirths") == before do
			task.wait(0.2)
		end
		if N("Rebirths") > before then
			stats.rebirths += 1
			log(("rebirth %d (was level %d, needed %d)"):format(N("Rebirths"), need, need))
			if farmOn and trainOn then -- Level and DamageMult start over: climb back on the zone before the next lap
				phase, phaseAt = "train", os.clock()
			end
		else
			first("rebirth refused at level", N("Level"), "need", need)
		end
	end
end

local function skinBody()
	skinTick()
end

local abilityReady = {}
local function abilityBody()
	if not oka or not (N("EncounterRemaining") > 0 or A("OnTarget") == true) then
		return
	end
	local scale = tonumber(A("AbilityCooldownScale")) or 1
	for id in pairs(csv(A("EquippedAbilities"))) do
		if (abilityReady[id] or 0) <= os.clock() then
			local ok, def = pcall(AbilityCfg.Get, id)
			local cd = ok and type(def) == "table" and tonumber(def.Cooldown) or 10
			abilityReady[id] = os.clock() + cd * scale + 0.4
			send("FireAbility", id)
			first("ability fired " .. id)
		end
	end
end

local petsAt = 0
local function equipBody()
	if os.clock() - petsAt >= PETS_EVERY then
		petsAt = os.clock()
		send("EquipBestPets")
		send("EquipBestItems")
	end
end

local function claimsBody()
	if N("Spins") > 0 then
		send("WheelSpin")
		task.wait(4) -- the client reports the landing after its animation; the prize is credited around then
		send("WheelLanded")
		first("wheel spun")
	end
	send("DailyReward", "claim")
	local progress = N("PlaytimeProgress")
	local okc, cfg = pcall(function()
		return require(SD:WaitForChild("PlaytimeRewardsConfig", 5))
	end)
	if okc and type(cfg.TIERS) == "table" then
		for i, tier in ipairs(cfg.TIERS) do
			if type(tier) == "table" and (tonumber(tier.At) or math.huge) <= progress then
				send("ClaimFreeReward", "claim", tier.Index or i)
			end
		end
	end
	for i = 1, 3 do
		send("Missions", "claim", i)
	end
	send("Missions", "claim", "bonus")
end

local function potionsBody()
	if not (farmOn or trainOn) then
		return
	end
	for _, kind in ipairs({ "Win4Long", "Win4", "Win", "WinShort", "Exp4Long", "Exp4", "Exp", "ExpShort", "Coin" }) do
		local running = N(kind .. "BoostUntil") > workspace:GetServerTimeNow()
		if N("Potion" .. kind) > 0 and not running then
			send("UsePotion", kind)
			first("potion used " .. kind)
			task.wait(1)
		end
	end
end

local setRebirth = loopFlag("rebirth", function()
	return rebirthOn
end, REBIRTH_EVERY, rebirthBody)
local setSkins = loopFlag("skins", function()
	return skinsOn
end, ERRAND_EVERY * 2, skinBody)
local setAbilities = loopFlag("abilities", function()
	return abilitiesOn
end, 0.5, abilityBody)
local setPets = loopFlag("pets", function()
	return petsOn
end, 10, equipBody)
local setClaims = loopFlag("claims", function()
	return claimsOn
end, CLAIM_EVERY, claimsBody)
local setPotions = loopFlag("potions", function()
	return potionsOn
end, 20, potionsBody)
local antiAfk = loopFlag("afk", function()
	return farmOn or trainOn
end, ANTIAFK_EVERY, function()
	send("AntiAFK_Heartbeat")
end)

local function setFarm(state)
	farmOn = state
	if state then
		phase, phaseAt = "farm", os.clock()
		antiAfk(true)
		ensureDirector()
	end
end
local function setTrain(state)
	trainOn = state
	if state then
		phase = farmOn and phase or "train"
		phaseAt = os.clock()
		antiAfk(true)
		ensureDirector()
	end
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Warrior Evolution", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "swords")
local Farm = Tab:AddLeftGroupbox("Farm", "swords")
local Spend = Tab:AddRightGroupbox("Spend and claim", "coins")

Farm:AddToggle("Farm", {
	Text = "Auto Farm stages",
	Tooltip = "Hops through the stage lane, the server kills the mobs, then touches the win pad. Climbs one stage per good lap and parks a stage where you died",
	Default = false,
	Callback = function(state)
		pcall(setFarm, state)
		if not state then
			say("farm off")
		end
	end,
})
Farm:AddToggle("Train", {
	Text = "Auto Train",
	Tooltip = "Stands on the best Targets zone your rebirths unlock (Exp with nothing on the wire). With Farm on too, the two alternate on a clock",
	Default = false,
	Callback = function(state)
		pcall(setTrain, state)
		if not state then
			say("train off")
		end
	end,
})
Farm:AddInput("TrainSecs", {
	Text = "Train seconds (Auto)",
	Default = tostring(TRAIN_SECS),
	Numeric = true,
	Finished = true,
	Tooltip = "Only when Farm and Train are both on: seconds on the zone before a farm phase",
	Callback = function(text)
		trainSecs = math.max(10, tonumber(text) or TRAIN_SECS)
	end,
})
Farm:AddInput("FarmSecs", {
	Text = "Farm seconds (Auto)",
	Default = tostring(FARM_SECS),
	Numeric = true,
	Finished = true,
	Tooltip = "Only when Farm and Train are both on: seconds of laps before the zone",
	Callback = function(text)
		farmSecs = math.max(10, tonumber(text) or FARM_SECS)
	end,
})
Farm:AddInput("MaxStage", {
	Text = "Max stage (0 = learn it)",
	Default = "0",
	Numeric = true,
	Finished = true,
	Tooltip = "Never lap deeper than this stage. 0 lets the script climb until a lap fails",
	Callback = function(text)
		maxStageCap = math.max(0, math.floor(tonumber(text) or 0))
	end,
})
Farm:AddToggle("Kite", {
	Text = "Keep distance from mobs",
	Tooltip = "During a stage fight, hops to the spot of the lane farthest from every mob whenever one gets within 30 studs, so slow kills do not become melee deaths. Without it stage 10 killed the character in 4 seconds",
	Default = true,
	Callback = function(state)
		kiteOn = state
	end,
})
local farmLine = Farm:AddLabel("-", true)

Spend:AddToggle("Rebirth", {
	Text = "Auto Rebirth",
	Tooltip = "RebirthRequest the moment Level reaches the game's requirement. Resets Level only; Wins, guns and pets stay. Never the Robux skip",
	Default = false,
	Callback = function(state)
		rebirthOn = state
		pcall(setRebirth, state)
	end,
})
Spend:AddToggle("Guns", {
	Text = "Auto buy best gun",
	Tooltip = "Hops to the next ladder pad when Wins cover it, presses its Buy prompt, equips it. Never the Robux gun products",
	Default = false,
	Callback = function(state)
		gunsOn = state
	end,
})
Spend:AddToggle("Skins", {
	Text = "Auto buy skins",
	Tooltip = "GunSkinAction for the cheapest Wins skin you do not own, spending at most half the Wins above the next gun's price. Robux skins and the wheel skin are skipped",
	Default = false,
	Callback = function(state)
		skinsOn = state
		pcall(setSkins, state)
	end,
})
Spend:AddToggle("Pets", {
	Text = "Eggs and pets",
	Tooltip = "Hatches the best Wins egg that costs at most half the Wins above the next gun's price (pets raise the Exp multiplier), then equips the best pets and items every 2 minutes. Robux and Token eggs are skipped",
	Default = false,
	Callback = function(state)
		petsOn = state
		pcall(setPets, state)
	end,
})
Spend:AddToggle("Abilities", {
	Text = "Auto abilities",
	Tooltip = "FireAbility for every equipped ability on its cooldown while a fight or the training zone is running",
	Default = false,
	Callback = function(state)
		abilitiesOn = state
		pcall(setAbilities, state)
	end,
})
Spend:AddToggle("Claims", {
	Text = "Free claims",
	Tooltip = "Wheel spin, daily reward, playtime tiers and missions every 90s. The server decides what is claimable; nothing here costs Robux",
	Default = false,
	Callback = function(state)
		claimsOn = state
		pcall(setClaims, state)
	end,
})
Spend:AddToggle("Potions", {
	Text = "Use potions",
	Tooltip = "Drinks a Wins / Power / Coin potion you own when none of that kind is running, while Farm or Train is on",
	Default = false,
	Callback = function(state)
		potionsOn = state
		pcall(setPotions, state)
	end,
})

local note, nextStrip = "idle", 0
local lastW, lastE, lastAt, rateW, rateE = N("Wins"), N("ExpEarned"), os.clock(), 0, 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	if pending.now then
		note, pending.now = pending.now, nil
	end
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	if now - lastAt >= 10 then
		rateW, rateE = (N("Wins") - lastW) / (now - lastAt), (N("ExpEarned") - lastE) / (now - lastAt)
		lastW, lastE, lastAt = N("Wins"), N("ExpEarned"), now
		if farmOn or trainOn then
			log(("rate: Wins %s/s, Exp %s/s (phase %s, stage %d, level %d, rebirths %d)"):format(fmt(rateW), fmt(rateE), phase, lapDepth, N("Level"), N("Rebirths")))
		end
	end
	local need = okr and RebirthCfg.RequiredLevel(N("Rebirths")) or 0
	pcall(farmLine.SetText, farmLine, ("%s phase, stage %d (best %d), next rebirth at level %d"):format(phase, lapDepth, maxSeen, need))
	pcall(Window.SetStatus, Window, {
		{ "Wins", fmt(N("Wins")) },
		{ "Power", fmt(N("TotalPower")) },
		{ "Level", N("Level") },
		{ "Rebirths", N("Rebirths") },
		{ "Gun", tostring(A("EquippedGun") or "-") },
		{ "Wins/s", fmt(rateW) },
		{ "Exp/s", fmt(rateE) },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("WarriorEvolution", {})

table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- watchdog: a parked director cannot report itself
task.spawn(function()
	while not dead do
		task.wait(5)
		if (farmOn or trainOn) and os.clock() - markAt > STUCK_AFTER and mark ~= "idle" then
			warn(("[warrior] stuck %ds at: %s"):format(os.clock() - markAt, mark))
			markAt = os.clock()
		end
	end
end)

-- close ----------------------------------------------------------------------
local function stopAll()
	farmOn, trainOn = false, false
	rebirthOn, gunsOn, skinsOn, petsOn, abilitiesOn, claimsOn, potionsOn = false, false, false, false, false, false, false
	gen += 1
	directorGen += 1
	table.clear(tokens) -- the loops compare their own token against this table and end
	dead = true
end

Library:OnUnload(function()
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
	stopAll()
	getgenv().warriorEvoStop = nil
end)

getgenv().warriorEvoStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().warriorEvoStop = nil
end
