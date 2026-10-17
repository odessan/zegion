--[[ Hike for Eggs -- treadmill, click, poles, eggs, pets, rebirth, quests, rangers (110432290690507)
     PlaceVersion 557

     Live-tested 2026-10-17 through the bridge, 5 min soak with every toggle on: stage 6-10 Legendary/Mythic eggs
     stolen (walk out 9-15s, 21-32s per trip), placed, hatched; poles, upgrades, quests, rebirth (Level 100), camps,
     Strength30 boost all fired and took. Pen full: only an egg rarer than your weakest placed pet is worth a trip.

     TRAIN    : stands you on your pen's treadmill belt (the server pays Strength only while ActiveTreadmill = 1,
                which is "be on the belt"; ~60k/s at Jade poles, millions at Storm). Every errand ends back there.
     CLICK    : the Click remote at ~8/s. The server credits ~8.4/s whatever you send (probed 7/14/25 per s: +15.7k,
                +18.8k, +18.8k Strength/s at gain 2250), so this sends at the cap and never faster. Position-free.
     SHOP     : walks to the Flipper stand and buys the best pole your Cash covers (a skip-ahead buy is accepted:
                Jade -> Storm in one go; a pole's Strength is the treadmill multiplier, ~2x per step early),
                then to an Upgrade stand for Agility / Pen capacity / Value. Both are range-gated (refused at 42
                studs, taken at 11 and at 4). A treadmill TIER is the worst buy (+12.5% for 70M at tier 5) so it
                is bought only with a wide cash margin and never ahead of a pole.
     EGGS     : the nests are a pure function of NestConfig.layout (rarity per slot, position), so every stage is
                known without it being streamed. Walks to the best ticked rarity of an unlocked stage, EggGrab,
                walks home (the egg banks as a Tool the moment you cross the pen line). A direct EggGrab starts no
                guardian chase: the chase belongs to the game's own prompt handler, which never ran, so nothing
                ever sends Caught. Probed at stage 4 (walk 7s there, 6.5s back, Secured).
     PLACE    : Place "Egg" at a free spot of your pen floor, from the belt (probed: HatchingEggs 0 -> 1).
     HATCH    : OpenEgg(id) the moment the egg's timer is up, from wherever you are (the "Growing eggs" panel's Open
                button; probed at z = -503 mid-steal-trip). Bare "Hatch" fired from the belt was ignored.
     EQUIP    : EquipBestPets whenever a pet sits unplaced.
     QUESTS   : Quest(id) for every finished quest, then 2x Strength boosts with the Tokens (Strength30 first).
     CLAIMS   : Daily, ClaimOffline (never the 4x, that is Robux).
     REBIRTH  : when Level covers Progression.requiredLevel. Resets Strength and Level; keeps poles, cash, pets.
     RANGERS  : builds camps with Dust, collects finished queues.

     Probed and dead (do not re-probe):
       EggGrab from home, 560 studs away          false: the grab is range-gated
       Flipper / Upgrade from the pen or 40 studs refused: they are range-gated to their stands
       Click above ~8.4/s                         credited the same as 8.4/s
       Hatch fired from the belt                  ignored
     Not wired (Robux): InstantHatch, GrowAll, SkipRebirth, Offline4x, Robux twins of upgrades, PortableTreadmill.
     Not wired (not asked): trails, group claim, codes, the Magnet upgrade (pickup reach, no use here).
     Movement: walk only (Humanoid:MoveTo at the game's own speed, ~75 studs/s). Hops of 5-30 studs held when probed,
                but a walk is faster than a short hop chain and the dossier rates teleports KICK-WEIGHTED.
     Egg stages above 24 sit on a second trail (x 250 -> 2300) the walk does not know the route to: EGG_STAGE_CEIL.

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().hikeEggsStop() ]]

-- config ---------------------------------------------------------------------
local CLICK_GAP = 0.12 -- seconds between Click sends; the server credits ~8.4/s, so 0.12 sits just above the cap
local HOME_BEAT = 0.5 -- the train loop's beat
local BELT_TOL = 1.2 -- studs from the belt centre that counts as standing on it
local BELT_WAIT = 2.5 -- after arriving, ActiveTreadmill must be 1 inside this or the belt is re-walked
local SHOP_EVERY = 6 -- the shop loop's beat; a trip only happens when something is affordable
local SHOP_BACKOFF = 45 -- an item the server did not take is not retried for this long
local STAND_TOL = 4 -- studs from a stand before firing at it (flipper bought at 11, upgrades at 4)
local TIER_MARGIN = 3 -- a treadmill tier is bought only with this many times its price in Cash
local EGG_STAGE_CEIL = 24 -- stages 25+ are on the second trail; the walk does not know that route
local EGG_BACKLOG = 2 -- no new trip while this many egg Tools wait unplaced in the bag
local WALK_CAP = 60 -- one walk leg gives up after this long
local STUCK_AFTER = 4 -- no progress for this long on a walk leg = stuck, the leg ends
local GRAB_DWELL = 0.35 -- after SwimStage matches, before EggGrab. The server reads where it thinks we are; raise if grabs say false
local GRAB_TRIES = 3
local GRAB_GAP = 0.4
local BANK_WAIT = 4 -- after reaching the belt, CarryRarity must clear inside this
local EGG_BENCH = 25 -- an egg the server refused sits out this long
local PLACE_EVERY = 0.7
local PLACE_CONFIRM = 1.6 -- the held egg must leave the hand inside this
local PLACE_BACKOFF = 10
local PLACE_RANGE = 90 -- Place only while this close to the pen centre (probed fine from the belt, ~35 studs)
local SPOT_STEP = 9 -- studs between candidate egg spots on the pen floor
local SPOT_CLEAR = 8 -- no other placed thing within this of a new egg
local SPOT_INSET = 8
local HATCH_EVERY = 1
local HATCH_CONFIRM = 3 -- the egg must leave Hatching inside this after OpenEgg, else it sits out HATCH_BACKOFF
local HATCH_BACKOFF = 4 -- the first OpenEgg after the client's clock said Ready was refused once; the retry takes
local EQUIP_EVERY = 6 -- a server equip cooldown is longer than the toast says in other games; one gate for all
local QUEST_EVERY = 20
local DAILY_EVERY = 300
local REBIRTH_EVERY = 5
local REBIRTH_BACKOFF = 30
local RANGER_EVERY = 90
local RANGER_NEAR = 5
local WATCHDOG = 40

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().hikeEggsStop then
	getgenv().hikeEggsStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[hike]", ...)
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

-- game -----------------------------------------------------------------------
local SA = ReplicatedStorage:WaitForChild("SwimAdventure", 15)
if not SA then
	warn("[hike] ReplicatedStorage.SwimAdventure not found: wrong game?")
	return
end
local okMods, Config, NestConfig, StateStream, StageLadder, QuestConfig, Progression, RangerConfig, TreadmillConfig = pcall(function()
	return require(SA.Config),
		require(SA.NestConfig),
		require(SA.StateStream),
		require(SA.StageLadder),
		require(SA.QuestConfig),
		require(SA.Progression),
		require(SA.RangerConfig),
		require(SA.TreadmillConfig)
end)
if not okMods then
	warn("[hike] the game's modules did not load:", Config)
	return
end
local Remotes = SA:WaitForChild("Remotes")
local Action, ClickRemote, EggGrab = Remotes.Action, Remotes.Click, Remotes.EggGrab
local NestEggs = SA:FindFirstChild("NestEggs")

local function state()
	return StateStream.Current()
end

local function now()
	return workspace:GetServerTimeNow()
end

local RANK = {}
for i, name in ipairs(Config.RarityNames) do
	RANK[name] = i
end

local stats = { clicks = 0, stolen = 0, lost = 0, placed = 0, hatched = 0, poles = 0, ups = 0, quests = 0, boosts = 0, rebirths = 0, camps = 0 }

-- breadcrumbs: every loop marks its step, a watchdog names the one that stopped moving
local marks = {}
local function step(loop, what)
	marks[loop] = { what, os.clock() }
end

-- loops ----------------------------------------------------------------------
-- One generation counter per toggle: off-then-on inside one interval must not leave the old thread alive.
local loops = {}
local waiting = {} -- see errand(): loops that have work and no body yet
local function makeLoop(name, every, pass)
	local L = { on = false, gen = 0 }
	function L.set(onNow)
		L.on = onNow
		L.gen += 1
		if not onNow then
			marks[name] = nil
			waiting[name] = nil -- a switched-off loop must not hold the steal loop back
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
					warn("[hike]", name, "pass threw:", err)
				end
				marks[name] = nil -- idle between passes: the watchdog only names a pass that is still running
				task.wait(every)
			end
		end)
	end
	loops[name] = L
	return L
end

-- The character belongs to one errand at a time. Returns whether fn ran, not whether it worked;
-- released on every path including a throw.
local busy = false
local function claim(fn)
	if busy then
		return false
	end
	busy = true
	local okRun, err = pcall(fn)
	busy = false
	if not okRun then
		warn("[hike] claimed body threw:", err)
	end
	return true
end

-- An errand that has work but finds the body taken registers here, and the steal loop starts no new trip while
-- anyone waits: otherwise a loop that retries every 0.4s re-claims the body before a 6s or 90s beat ever sees it free.
local function errand(name, fn)
	if claim(function()
		waiting[name] = nil
		fn()
	end) then
		return true
	end
	waiting[name] = true
	return false
end

local function hum()
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function root()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function alive()
	local h, r = hum(), root()
	return h ~= nil and r ~= nil and h.Health > 0
end

local function flat(a, b)
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- Walk to a point (horizontal tolerance). Re-issues MoveTo on a beat because MoveTo gives up after ~8s,
-- ends when stopped(), after maxS, or when the horizontal distance stops shrinking for STUCK_AFTER.
local function walkTo(pos, tol, maxS, stopped)
	local t0, bestAt, best = os.clock(), os.clock(), math.huge
	while os.clock() - t0 < (maxS or WALK_CAP) do
		if stopped and stopped() then
			return false, "stopped"
		end
		local r, h = root(), hum()
		if not (r and h and h.Health > 0) then
			return false, "dead"
		end
		local d = flat(r.Position, pos)
		if d <= tol then
			return true, d
		end
		if d < best - 1 then
			best, bestAt = d, os.clock()
		elseif os.clock() - bestAt > STUCK_AFTER then
			return false, "stuck"
		end
		h:MoveTo(pos)
		task.wait(0.1)
	end
	return false, "timeout"
end

-- Hub legs go through PathfindingService (the stands and fences block a straight line: a walk from the Upgrade
-- stand at (83, 549) to the trail stuck there); the trail itself is open, so the long legs stay straight.
local PathfindingService = game:GetService("PathfindingService")
local function pathTo(pos, tol, maxS, stopped)
	local r = root()
	if not r then
		return false, "dead"
	end
	local path = PathfindingService:CreatePath({ AgentRadius = 2.5, AgentHeight = 5, AgentCanJump = true })
	local okC = pcall(function()
		path:ComputeAsync(r.Position, pos)
	end)
	if not okC or path.Status ~= Enum.PathStatus.Success then
		first("path-fallback", tostring(okC), tostring(path.Status))
		return walkTo(pos, tol, maxS, stopped)
	end
	local t0 = os.clock()
	for _, wp in ipairs(path:GetWaypoints()) do
		if os.clock() - t0 > (maxS or WALK_CAP) then
			return false, "timeout"
		end
		local h = hum()
		if h and wp.Action == Enum.PathWaypointAction.Jump then
			h.Jump = true
		end
		local okW, why = walkTo(wp.Position, 3, 6, stopped)
		if not okW and why ~= "timeout" then
			return false, why
		end
	end
	return walkTo(pos, tol, 6, stopped)
end

local HUB_EDGE_Z = 515 -- the hub (pen, stands, belt) is south of this; the trail runs north from its gate at x ~ 0
local HUB_GATE = Vector3.new(0, 19, 525)
local function navTo(pos, tol, maxS, stopped)
	local r = root()
	if not r then
		return false, "dead"
	end
	local fromHub, toHub = r.Position.Z > HUB_EDGE_Z, pos.Z > HUB_EDGE_Z
	if fromHub and toHub then
		return pathTo(pos, tol, maxS, stopped)
	elseif fromHub then
		local okG, why = pathTo(HUB_GATE, 4, 25, stopped)
		if not okG then
			return false, why
		end
	elseif toHub then
		local okG, why = walkTo(HUB_GATE, 6, maxS, stopped)
		if not okG then
			return false, why
		end
		return pathTo(pos, tol, 25, stopped)
	end
	return walkTo(pos, tol, maxS, stopped)
end

-- InvokeServer has no timeout; give up on a clock instead of parking the pass.
local function callTimed(fn, secs)
	local done, a, b = false, nil, nil
	task.spawn(function()
		local okCall, x, y = pcall(fn)
		if okCall then
			a, b = x, y
		end
		done = true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < secs do
		task.wait(0.05)
	end
	return done, a, b
end

-- world ----------------------------------------------------------------------
local function penModel()
	local pens = workspace:FindFirstChild("SwimWorld") and workspace.SwimWorld:FindFirstChild("Pens")
	local name = player:GetAttribute("Pen")
	return pens and name and pens:FindFirstChild(name)
end

local beltCache
local function beltPos()
	if beltCache and beltCache.Parent then
		return beltCache.Position + Vector3.new(0, 1.5, 0)
	end
	local pen = penModel()
	local tm = pen and pen:FindFirstChild("Treadmill")
	local belt = tm and tm:FindFirstChild("MovingBelt")
	beltCache = belt
	return belt and belt.Position + Vector3.new(0, 1.5, 0)
end

local function penCenter()
	local pen = penModel()
	return pen and pen:GetAttribute("Center"), pen and pen:GetAttribute("Size")
end

local function shopPos()
	local sw = workspace:FindFirstChild("SwimWorld")
	local part = sw and sw:FindFirstChild("FlipperShop")
	return part and part.Position
end

local function nearestStand(prefix)
	local r = root()
	if not r then
		return nil
	end
	local best, bd
	for _, m in ipairs(workspace:GetChildren()) do
		if m:IsA("Model") and m.Name:sub(1, #prefix) == prefix then
			local d = flat(m:GetPivot().Position, r.Position)
			if not bd or d < bd then
				best, bd = m, d
			end
		end
	end
	return best and best:GetPivot().Position
end

local function goHome(stopped)
	local b = beltPos()
	if not b then
		return false
	end
	return navTo(b, BELT_TOL, WALK_CAP, stopped)
end

-- train + click ----------------------------------------------------------------
makeLoop("train", HOME_BEAT, function(on)
	if busy or not alive() then
		return
	end
	local b = beltPos()
	if not b then
		first("no-belt", player:GetAttribute("Pen"))
		return
	end
	local r = root()
	if (player:GetAttribute("ActiveTreadmill") or 0) > 0 and flat(r.Position, b) < 4 then
		say("on the belt")
		return
	end
	claim(function()
		step("train", "to belt")
		say("walking to the belt")
		goHome(function()
			return not on()
		end)
		local t0 = os.clock()
		while on() and os.clock() - t0 < BELT_WAIT and (player:GetAttribute("ActiveTreadmill") or 0) == 0 do
			task.wait(0.1)
		end
		if (player:GetAttribute("ActiveTreadmill") or 0) > 0 then
			first("belt-active", flat(r.Position, b))
		else
			first("belt-not-active", root() and root().Position)
		end
	end)
end)

makeLoop("click", CLICK_GAP, function()
	if alive() then
		ClickRemote:FireServer()
		stats.clicks += 1
	end
end)

-- shop -----------------------------------------------------------------------
local bench = {} -- key -> clock until which it is not retried
local function benched(key)
	return (bench[key] or 0) > os.clock()
end

local function poleStrength(id)
	for _, f in ipairs(Config.Flippers) do
		if f.Id == id then
			return f.Strength
		end
	end
	return 0
end

local function bestPole(st)
	local have = poleStrength(st.Flipper)
	local best
	for _, f in ipairs(Config.Flippers) do
		-- Acquisition rows (Daily / Store / Limited) are not for sale for Cash
		if not f.Acquisition and f.Price <= st.Cash and f.Strength > have and not benched("pole" .. f.Id) then
			if not best or f.Strength > best.Strength then
				best = f
			end
		end
	end
	return best
end

local UPGRADE_IDS = { "Agility", "PenCapacity", "Value" } -- Magnet (pickup reach) is not wired
local function upgradePlan(st)
	local out = {}
	for _, id in ipairs(UPGRADE_IDS) do
		local lvl = (st.Upgrades or {})[id] or 0
		local okMax, max = pcall(Config.upgradeMax, id)
		local okCost, cost = pcall(Config.upgradeCost, id, lvl)
		if okMax and okCost and lvl < max and cost <= st.Cash and not benched("up" .. id) then
			out[#out + 1] = id
		end
	end
	return out
end

local function tierPlan(st)
	local tier = player:GetAttribute("TreadmillTier") or 1
	local okP, price = pcall(TreadmillConfig.nextPrice, { TreadmillTier = tier })
	if okP and price and price * TIER_MARGIN <= st.Cash and not benched("tier") then
		return price
	end
	return nil
end

local function atStand(pos, on)
	local ok = navTo(pos, STAND_TOL, WALK_CAP, function()
		return not on()
	end)
	task.wait(0.15)
	return ok
end

makeLoop("shop", SHOP_EVERY, function(on)
	local st = state()
	if not st or not alive() then
		return
	end
	local pole = bestPole(st)
	local ups = upgradePlan(st)
	local tier = tierPlan(st)
	if not (pole or #ups > 0 or tier) then
		waiting.shop = nil
		return
	end
	errand("shop", function()
		if pole then
			local sp = shopPos()
			if sp then
				step("shop", "to flippers " .. pole.Id)
				say("buying " .. pole.Name)
				if atStand(sp, on) then
					local before = state().Flipper
					Action:FireServer("Flipper", pole.Id)
					task.wait(0.8)
					if state().Flipper ~= before then
						stats.poles += 1
						first("pole", before, "->", state().Flipper, "cash", fmt(state().Cash))
					else
						bench["pole" .. pole.Id] = os.clock() + SHOP_BACKOFF
						first("pole-refused", pole.Id, pole.Price, st.Cash, pole.MinStage)
					end
				end
			end
		end
		if #ups > 0 and on() then
			local up = nearestStand("Upgrades")
			if up then
				step("shop", "to upgrades")
				if atStand(up, on) then
					for _, id in ipairs(ups) do
						if not on() then
							break
						end
						local before = (state().Upgrades or {})[id] or 0
						Action:FireServer("Upgrade", id)
						task.wait(0.7)
						local after = (state().Upgrades or {})[id] or 0
						if after > before then
							stats.ups += 1
							first("upgrade-" .. id, before, "->", after)
						else
							bench["up" .. id] = os.clock() + SHOP_BACKOFF
							first("upgrade-refused-" .. id, before, state().Cash)
						end
					end
				end
			end
		end
		if tier and on() then
			-- the sign is a few studs from the belt: bought from the belt (probed)
			goHome(function()
				return not on()
			end)
			local before = player:GetAttribute("TreadmillTier") or 1
			Action:FireServer("UpgradeTreadmill")
			task.wait(0.8)
			if (player:GetAttribute("TreadmillTier") or 1) > before then
				first("tier", before, "->", player:GetAttribute("TreadmillTier"), "price", fmt(tier))
			else
				bench["tier"] = os.clock() + SHOP_BACKOFF
				first("tier-refused", before, tier)
			end
		end
	end)
end)

-- eggs: plan -----------------------------------------------------------------
local specs = {}
do
	local okN, n = pcall(StageLadder.count)
	for s = 1, okN and n or 34 do
		local okS, sp = pcall(NestConfig.spec, s)
		specs[s] = okS and sp and sp.center and sp or false
	end
end

local layoutCache = { cycle = nil, eggs = {} }
local function nestEggs()
	local t = NestConfig.now()
	local cycle = NestConfig.cycleAt(t)
	if layoutCache.cycle ~= cycle then
		local eggs = {}
		for stage, sp in ipairs(specs) do
			if sp then
				local okL, lay = pcall(NestConfig.layout, Config.RarityNames, stage, cycle, sp)
				if okL then
					for _, e in ipairs(lay) do
						eggs[#eggs + 1] = e
					end
				end
			end
		end
		layoutCache.cycle, layoutCache.eggs = cycle, eggs
	end
	return layoutCache.eggs, cycle, NestConfig.live(t)
end

local function unlockedStage(level)
	local s = 0
	for i, lv in ipairs(Config.StageLevels) do
		if level >= lv then
			s = i
		end
	end
	return s
end
assert(unlockedStage(1) == 1 and unlockedStage(0) == 0 and unlockedStage(9) == 2, "unlockedStage")

local wantRarity = {} -- ticked rarity names (own copy; the dropdown's table is mutated in place)
local maxStageBox = 0 -- 0 = auto (every unlocked stage up to the ceiling)

local function weakestPlacedRank(st)
	local w
	for _, p in ipairs(st.Pets or {}) do
		if p.Placed and p.Rarity then
			local r = RANK[p.Rarity] or 0
			w = w and math.min(w, r) or r
		end
	end
	return w
end

local function penFull(st)
	local n = 0
	for _, p in ipairs(st.Pets or {}) do
		if p.Placed then
			n += 1
		end
	end
	return n >= (st.PenCapacity or 10)
end

local function eggTools()
	local out = {}
	local function scan(c)
		for _, t in ipairs(c and c:GetChildren() or {}) do
			if t:IsA("Tool") and t:GetAttribute("Kind") == "Egg" then
				out[#out + 1] = t
			end
		end
	end
	scan(player.Character)
	scan(player:FindFirstChildOfClass("Backpack"))
	table.sort(out, function(a, b)
		return (RANK[a:GetAttribute("Rarity")] or 0) > (RANK[b:GetAttribute("Rarity")] or 0)
	end)
	return out
end

-- Best egg: the highest ticked rarity of an unlocked, live, untaken egg, nearest stage on a tie.
local function pickEgg(st)
	local eggs, cycle, live = nestEggs()
	if not live then
		return nil, "nests reset"
	end
	local ceil = maxStageBox > 0 and maxStageBox or math.huge
	local maxStage = math.min(unlockedStage(st.Level or 1), EGG_STAGE_CEIL, ceil)
	local floorRank = penFull(st) and (weakestPlacedRank(st) or 0) or 0
	local best
	for _, e in ipairs(eggs) do
		-- a storm egg carries a _Bonus rarity above the layout's; _Taken is the boolean true (probed, not the cycle)
		local bonus = NestEggs and NestEggs:GetAttribute(e.id .. "_Bonus")
		local rarity = bonus and (RANK[bonus] or 0) > (RANK[e.rarity] or 0) and bonus or e.rarity
		local rk = RANK[rarity] or 0
		local taken = NestEggs and NestEggs:GetAttribute(e.id .. "_Taken") == true
		if e.stage <= maxStage and wantRarity[rarity] and rk > floorRank and not taken and not benched("egg" .. e.id .. "@" .. cycle) then
			if not best or rk > best.rk or (rk == best.rk and e.stage < best.e.stage) then
				best = { e = e, rk = rk, rarity = rarity }
			end
		end
	end
	return best and best.e, maxStage, best and best.rarity
end

-- eggs: steal ------------------------------------------------------------------
local carrying = function()
	return player:GetAttribute("CarryRarity") ~= nil
end

makeLoop("steal", 0.4, function(on)
	local st = state()
	if busy or next(waiting) ~= nil or not st or not alive() or #eggTools() >= EGG_BACKLOG then
		return
	end
	local e, info, rarity = pickEgg(st)
	if not e then
		if type(info) == "number" and not busy then
			say("no ticked egg at stages <= " .. info)
		end
		return -- the 10s blackout between nest cycles also lands here: nothing to say
	end
	claim(function()
		local cycle = layoutCache.cycle
		local key = "egg" .. e.id .. "@" .. cycle
		step("steal", "walk " .. e.id)
		say(("egg %s %s (stage %d)"):format(e.id, rarity, e.stage))
		local t0 = os.clock()
		local okW, why = navTo(e.pos, 4, WALK_CAP, function()
			return not on()
		end)
		if not okW then
			if why ~= "stopped" then
				bench[key] = os.clock() + EGG_BENCH
				first("walk-failed", e.id, why, root() and root().Position)
			end
			return
		end
		local tWalk = os.clock() - t0
		local d0 = os.clock()
		while on() and os.clock() - d0 < 1.5 and player:GetAttribute("SwimStage") ~= e.stage do
			task.wait(0.05)
		end
		first("stage-dwell", e.id, "SwimStage", player:GetAttribute("SwimStage"), "wanted", e.stage, os.clock() - d0)
		task.wait(GRAB_DWELL)
		step("steal", "grab " .. e.id)
		local got = false
		for try = 1, GRAB_TRIES do
			if not on() then
				return
			end
			local done, reply = callTimed(function()
				return EggGrab:InvokeServer(e.id)
			end, 3)
			if carrying() then
				got = true
				first("grab", e.id, rarity, "try", try, "reply", reply, "walk", ("%.1fs"):format(tWalk))
				break
			end
			first("grab-no", e.id, "try", try, "done", done, "reply", reply, "stage", player:GetAttribute("SwimStage"))
			task.wait(GRAB_GAP)
		end
		if not got then
			bench[key] = os.clock() + EGG_BENCH
			stats.lost += 1
			return
		end
		step("steal", "home " .. e.id)
		goHome(function()
			return false -- an egg in hand is carried home even if the toggle goes off
		end)
		local b0 = os.clock()
		while carrying() and os.clock() - b0 < BANK_WAIT do
			task.wait(0.1)
		end
		if carrying() then
			stats.lost += 1
			first("bank-failed", e.id, root() and root().Position)
		else
			stats.stolen += 1
			log(("banked %s %s stage %d: %.1fs walk out, %.1fs total"):format(e.id, rarity, e.stage, tWalk, os.clock() - t0))
		end
	end)
end)

-- eggs: place ------------------------------------------------------------------
local function spotFor(st)
	local c, size = penCenter()
	if not c or not size then
		return nil
	end
	local halfX, halfZ = size.X / 2 - SPOT_INSET, size.Z / 2 - SPOT_INSET
	local taken = {}
	for _, p in ipairs(st.Pets or {}) do
		if p.Placed and p.Pos then
			taken[#taken + 1] = Vector2.new(p.Pos.X, p.Pos.Z)
		end
	end
	local fallback
	local x = -halfX
	while x <= halfX do
		local z = -halfZ
		while z <= halfZ do
			local v = Vector2.new(x, z)
			fallback = fallback or v
			local free = true
			for _, t in ipairs(taken) do
				if (t - v).Magnitude < SPOT_CLEAR then
					free = false
					break
				end
			end
			if free then
				return Vector3.new(c.X + x, c.Y, c.Z + z)
			end
			z += SPOT_STEP
		end
		x += SPOT_STEP
	end
	return fallback and Vector3.new(c.X + fallback.X, c.Y, c.Z + fallback.Y)
end

makeLoop("place", PLACE_EVERY, function(on)
	local st = state()
	local tools = eggTools()
	if not st or #tools == 0 or not alive() or benched("place") then
		return
	end
	local c = penCenter()
	local r = root()
	if not c or not r or flat(r.Position, c) > PLACE_RANGE then
		return -- mid-trip: the egg waits in the bag until we are home
	end
	local tool = tools[1]
	local spot = spotFor(st)
	if not spot then
		return
	end
	step("place", "equip " .. tool.Name)
	local h = hum()
	if tool.Parent ~= player.Character then
		pcall(function()
			h:EquipTool(tool)
		end)
		task.wait(0.4)
	end
	step("place", "fire")
	Action:FireServer("Place", "Egg", spot)
	local t0 = os.clock()
	while os.clock() - t0 < PLACE_CONFIRM and tool.Parent ~= nil and (tool.Parent == player.Character or tool.Parent == player:FindFirstChildOfClass("Backpack")) do
		task.wait(0.1)
	end
	if tool.Parent == nil or (tool.Parent ~= player.Character and tool.Parent ~= player:FindFirstChildOfClass("Backpack")) then
		stats.placed += 1
		first("placed", tool.Name, "spot", spot)
	else
		bench["place"] = os.clock() + PLACE_BACKOFF
		first("place-refused", tool.Name, "spot", spot, "pets placed", (function()
			local n = 0
			for _, p in ipairs(st.Pets or {}) do
				if p.Placed then
					n += 1
				end
			end
			return n
		end)(), "cap", st.PenCapacity)
		say("place refused (pen full?)")
	end
end)

-- eggs: hatch ------------------------------------------------------------------
-- The Growing eggs panel's Open button sends OpenEgg(id): position-free (probed at z = -503 mid-trip, the egg
-- hatched). No walking, no body claim. The game spaces its own sends 0.2s apart, so does this.
makeLoop("hatch", HATCH_EVERY, function(on)
	local st = state()
	if not st then
		return
	end
	for _, p in ipairs(st.Pets or {}) do
		if not on() then
			return
		end
		if p.Hatching and not p.Opening and (p.Ready or (p.HatchAt and p.HatchAt <= now())) and not benched("hatch" .. p.Id) then
			step("hatch", "OpenEgg " .. p.Id)
			Action:FireServer("OpenEgg", p.Id)
			local t0 = os.clock()
			local gone = false
			while os.clock() - t0 < HATCH_CONFIRM and not gone do
				task.wait(0.2)
				gone = true
				for _, q in ipairs(state().Pets or {}) do
					if q.Id == p.Id and q.Hatching then
						gone = false
					end
				end
			end
			if gone then
				stats.hatched += 1
				first("hatched", p.Id, p.Species or p.EggSpecies)
			else
				bench["hatch" .. p.Id] = os.clock() + HATCH_BACKOFF
				first("hatch-refused", p.Id, p.EggSpecies, "ready", p.Ready)
			end
		end
	end
end)

-- pets: equip best -------------------------------------------------------------
local lastEquip = 0
makeLoop("equip", 2, function()
	local st = state()
	if not st or os.clock() - lastEquip < EQUIP_EVERY then
		return
	end
	local unplaced = 0
	for _, p in ipairs(st.Pets or {}) do
		if not p.Placed and not p.Hatching and p.Species then
			unplaced += 1
		end
	end
	if unplaced == 0 then
		return
	end
	lastEquip = os.clock()
	step("equip", "EquipBestPets")
	Action:FireServer("EquipBestPets")
	first("equip", "unplaced", unplaced)
end)

-- quests, boosts, claims -------------------------------------------------------
local lastDaily = 0
makeLoop("quests", QUEST_EVERY, function()
	local st = state()
	if not st then
		return
	end
	local qs = st.QuestState or {}
	for _, q in ipairs(QuestConfig.Quests) do
		local bucket = qs[q.Period]
		if bucket and (bucket.Counts or {})[q.Kind] and bucket.Counts[q.Kind] >= q.Goal and not (bucket.Claimed or {})[q.Id] and not benched("q" .. q.Id) then
			step("quests", "claim " .. q.Id)
			Action:FireServer("Quest", q.Id)
			task.wait(0.6)
			local nb = (state().QuestState or {})[q.Period]
			if nb and (nb.Claimed or {})[q.Id] then
				stats.quests += 1
				first("quest", q.Id, "tokens", state().Tokens)
			else
				bench["q" .. q.Id] = os.clock() + SHOP_BACKOFF
				first("quest-refused", q.Id, bucket.Counts[q.Kind], q.Goal)
			end
		end
	end
	st = state()
	local boost = (st.Boosts or {}).Strength
	local active = boost and boost.Until and boost.Until - now() > 20
	local tokens = st.Tokens or 0
	if not active and not benched("reward") then
		local pick = tokens >= QuestConfig.Rewards.Strength30.Cost and "Strength30" or (tokens >= QuestConfig.Rewards.Strength10.Cost and "Strength10")
		if pick then
			step("quests", "reward " .. pick)
			Action:FireServer("Reward", pick)
			task.wait(0.8)
			local after = (state().Boosts or {}).Strength
			if after and after.Until and after.Until - now() > 20 then
				stats.boosts += 1
				first("reward", pick, "tokens", tokens, "->", state().Tokens)
			else
				bench["reward"] = os.clock() + SHOP_BACKOFF
				first("reward-refused", pick, tokens)
			end
		end
	end
	st = state()
	if (st.OfflineStrength or 0) > 0 and not benched("offline") then
		Action:FireServer("ClaimOffline") -- never Offline4x: Robux
		bench["offline"] = os.clock() + 60
		first("offline", st.OfflineStrength)
	end
	if os.clock() - lastDaily > DAILY_EVERY then
		lastDaily = os.clock()
		local before = st.DailyClaims
		Action:FireServer("Daily")
		task.wait(0.8)
		first("daily", before, "->", state().DailyClaims)
	end
end)

-- rebirth ----------------------------------------------------------------------
makeLoop("rebirth", REBIRTH_EVERY, function()
	local st = state()
	if not st or benched("rebirth") then
		return
	end
	local okR, req = pcall(Progression.requiredLevel, st.Rebirths or 0)
	if not okR or (st.Level or 0) < req then
		return
	end
	step("rebirth", "Rebirth")
	local before = st.Rebirths or 0
	Action:FireServer("Rebirth") -- never SkipRebirth: Robux
	task.wait(1.5)
	if (state().Rebirths or 0) > before then
		stats.rebirths += 1
		first("rebirth", before, "->", state().Rebirths, "level", st.Level, "req", req)
	else
		bench["rebirth"] = os.clock() + REBIRTH_BACKOFF
		first("rebirth-refused", before, st.Level, req)
	end
end)

-- rangers ----------------------------------------------------------------------
makeLoop("rangers", RANGER_EVERY, function(on)
	local st = state()
	if not st or not st.Rangers or not st.Rangers.Unlocked or not alive() then
		return
	end
	local camps = workspace:FindFirstChild("MyRangerCamps")
	if not camps then
		return
	end
	local todo = {}
	local dust = st.RangerDust or st.Rangers.Dust or 0
	for i, slot in ipairs(st.Rangers.Slots or {}) do
		local cost = RangerConfig.BuildCosts[i] or math.huge
		if slot.Level == 0 and dust >= cost and not benched("camp" .. i) then
			todo[#todo + 1] = { i = i, verb = "RangerBuild" }
			dust -= cost
		elseif slot.Level > 0 and next(slot.Queue or {}) ~= nil and not benched("collect" .. i) then
			todo[#todo + 1] = { i = i, verb = "RangerCollect" }
		end
	end
	if #todo == 0 then
		waiting.rangers = nil
		return
	end
	errand("rangers", function()
		for _, job in ipairs(todo) do
			if not on() then
				return
			end
			local camp = camps:FindFirstChild("Camp" .. job.i)
			if camp then
				step("rangers", job.verb .. " " .. job.i)
				say(job.verb .. " " .. job.i)
				if navTo(camp:GetPivot().Position, RANGER_NEAR, WALK_CAP, function()
					return not on()
				end) then
					task.wait(0.2)
					local beforeDust = state().RangerDust
					local beforeLevel = (state().Rangers.Slots[job.i] or {}).Level
					Action:FireServer(job.verb, job.i)
					task.wait(0.8)
					local slotNow = state().Rangers.Slots[job.i] or {}
					if job.verb == "RangerBuild" and slotNow.Level ~= beforeLevel then
						stats.camps += 1
						first("camp-built", job.i, "dust", beforeDust, "->", state().RangerDust)
					elseif job.verb == "RangerCollect" and next(slotNow.Queue or {}) == nil then
						first("camp-collected", job.i)
					else
						bench[(job.verb == "RangerBuild" and "camp" or "collect") .. job.i] = os.clock() + 120
						first("camp-refused-" .. job.verb, job.i, "dust", beforeDust)
					end
				end
			end
		end
	end)
end)

-- watchdog -------------------------------------------------------------------
local watching = true
task.spawn(function()
	local lastStats = os.clock()
	while watching do
		task.wait(5)
		if os.clock() - lastStats > 60 then
			lastStats = os.clock()
			local parts = {}
			for k, v in pairs(stats) do
				parts[#parts + 1] = k .. "=" .. v
			end
			table.sort(parts)
			log("stats", table.concat(parts, " "))
		end
		for name, m in pairs(marks) do
			if loops[name] and loops[name].on and os.clock() - m[2] > WATCHDOG then
				warn(("[hike] %s stuck %ds at: %s"):format(name, os.clock() - m[2], m[1]))
				m[2] = os.clock()
			end
		end
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Hike for Eggs", statusBar = true })
if not Window then
	watching = false
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "mountain")
local Train = Tab:AddLeftGroupbox("Train", "dumbbell")
local Eggs = Tab:AddRightGroupbox("Eggs", "egg")
local Extra = Tab:AddLeftGroupbox("Claims", "gift")

local masters = {} -- every row the All toggle fans out to
local function toggle(box, idx, text, tip, loopName)
	local t = box:AddToggle(idx, {
		Text = text,
		Tooltip = tip,
		Default = false,
		Callback = function(state)
			loops[loopName].set(state)
		end,
	})
	masters[#masters + 1] = t
	return t
end

toggle(Train, "Train", "Stand on the treadmill", "Walks you onto your pen's belt and back after every errand. The server pays Strength only while you are on it", "train")
toggle(Train, "Click", "Auto click (~8/s)", "The Click remote at the rate the server credits. Adds about a third on top of the belt", "click")
toggle(Train, "Shop", "Auto buy poles + upgrades", "Walks to the Flipper stand and buys the best pole your Cash covers, then Agility / Pen capacity / Value at an Upgrade stand. A treadmill tier only with a wide Cash margin", "shop")
toggle(Train, "Rebirth", "Auto rebirth", "Rebirths as soon as your Level covers it. Resets Strength and Level, keeps poles, cash and pets. Level also gates which egg stages you can steal from", "rebirth")

toggle(Eggs, "Steal", "Auto steal eggs", "Walks to the best ticked rarity in an unlocked stage and carries it home. Long trips: the higher the stage, the further the walk", "steal")
Eggs:AddDropdown("Rarities", {
	Text = "Steal rarities",
	Values = Config.RarityNames,
	Default = Config.RarityNames,
	Multi = true,
	Callback = function(picked)
		table.clear(wantRarity)
		for name in pairs(ticked(picked)) do
			wantRarity[name] = true
		end
	end,
})
for _, name in ipairs(Config.RarityNames) do
	wantRarity[name] = true -- Default does not fire the callback
end
Eggs:AddInput("MaxStage", {
	Text = "Max stage (0 = auto)",
	Default = "0",
	Numeric = true,
	Finished = true,
	Tooltip = "Caps how far up the trail the steal walks. 0 steals from every stage your Level unlocks (up to 24)",
	Callback = function(text)
		maxStageBox = math.max(0, math.floor(tonumber(text) or 0))
	end,
})
toggle(Eggs, "Place", "Auto place eggs", "Puts the egg in your hand on a free spot of your pen floor", "place")
toggle(Eggs, "Hatch", "Auto hatch", "Walks to a finished egg and presses its prompt", "hatch")
toggle(Eggs, "Equip", "Auto equip best pets", "EquipBestPets whenever a pet sits unplaced", "equip")
toggle(Eggs, "Rangers", "Auto rangers", "Builds camps with Dust and collects finished queues", "rangers")

toggle(Extra, "Quests", "Quests, boosts, daily, offline", "Claims finished quests, spends Tokens on 2x Strength boosts, claims Daily and Offline (never the 4x, that is Robux)", "quests")

local allGuard = false
Extra:AddToggle("All", {
	Text = "Everything",
	Tooltip = "Turns every toggle above on or off",
	Default = false,
	Callback = function(state)
		if allGuard then
			return
		end
		allGuard = true
		for _, t in ipairs(masters) do
			pcall(function()
				t:SetValue(state)
			end)
		end
		allGuard = false
	end,
})

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
	local st = state()
	if not st then
		return
	end
	local placed = 0
	for _, p in ipairs(st.Pets or {}) do
		if p.Placed then
			placed += 1
		end
	end
	pcall(Window.SetStatus, Window, {
		{ "Cash", fmt(st.Cash) },
		{ "Str", fmt(st.Strength) },
		{ "Lvl", st.Level },
		{ "RB", st.Rebirths or 0 },
		{ "Pole", st.Flipper },
		{ "Pets", placed .. "/" .. (st.PenCapacity or 0) },
		{ "Eggs", stats.stolen .. "/" .. stats.placed .. "/" .. stats.hatched },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control; the master row would flip everything a second time on restore
Window:AddSettingsTab("HikeForEggs", { "All" })

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
	getgenv().hikeEggsStop = nil
end)

getgenv().hikeEggsStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().hikeEggsStop = nil
end
