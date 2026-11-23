--[[ Fish for Sea Animals -- instant catches on the dock, lifting for strength, best animals on the pen, buys, freebies (90296841634441)

     FISH     : walks onto the dock (the game's own controller enters fishing mode and parks you on the spot), then
                Cast(1) + Land(true) straight through the remotes: a perfect cast and a won reel with no meter, no
                cutscene and no clicking. The server's line cooldown is ~3.1s per catch. "Too strong" fish (fight
                ratio over 2 against your rod) land the same, so the rod tier does not matter. The game's aim meter
                is hidden once the dock starts (our casts never stop it), and each catch pops the game's own toast
                ("Caught Rare Megalodon (1 in 25K)") since the reveal cutscene never plays.
     LIFT     : walks into your plot's LiftZone; the game starts lifting by itself (~1 rep/s, x2 kept on: the
                Boost remote behind the "2x" bubble is taken unoffered and lasts 3s, so it is re-fired as it ends;
                4 -> 7 reps per 4s when probed). Each rep is XP ->
                levels -> Strength). Strength is the cast distance, the distance is the biome, and every biome is
                ~3.5x the odds. Measured 2026-11-23: +60 Strength in 20s at Strength 75, barbell tier 3. With FISH on
                too the two take turns: "Fish for" seconds on the dock, "Lift for" seconds on the bar (walk ~3s).
     PEN      : EquipBest (the pen keeps your top earners; took income $32 -> $37K/s on the first call) plus
                ClaimIndex("all") (new species pay cash + XP: 11 cards paid $11.8M) after every few catches.
     UPGRADES : the next barbell, the next pen level (then tank boosts), the best bait you can afford (buying
                equips it). All three work from anywhere. Rods are not bought: the tier does not change a catch.
     PLAYTIME : each playtime reward as it unlocks, and the free gift when its timer is up.
     POTIONS  : drinks stored potions (cash, strength) whose effect is not already running.
     REBIRTH  : Rebirth() once cash and Strength cover Config.rebirthCost ($500M x 45^n) / rebirthStrength.
                Probed 2026-11-23: resets cash (22T -> 340B), Level (-> 1) and Strength (4065 -> 840); KEEPS every
                animal (pen and inventory), barbell tier, pen level and bait; StrengthRate x1.5, +0.5x cash.

     Movement (measured 2026-11-23): hops over 20 studs are reverted and a 30 studs/s glide is pulled back, so
     every trip WALKS (Humanoid:MoveTo). Fishing and lifting both lock the character (WalkSpeed 0): the script
     leaves the dock with the controller's own leaveDock() and the bar with Controls.unlock("Lift").

     Probed and dead (do not re-probe):
       Cast off the dock          "Walk onto the dock to fish!" / "Go to the Fishing Spot to cast!"
       Cast faster than ~3s       "Your line is still out!" (CastDone does not reset it)
       Lift(true) from the dock   0 reps: only inside your plot's LiftZone
       ClaimFreeGift early        silently refused, the server keeps FreeGiftReady
       World2Trip("Unlock")       silently refused below 2.5e19 cash
       MiniGameScore              leaderboard only, no reward
       SellAll off the sell pad   no effect; on World1.SellStand.SellPad it works, but 80 leftovers sold for $36B
                                  = 0.3s of income ($113B/s) for a ~10s walk. Not wired (inventory has no cap:
                                  Config.MaxInventory = inf)
     Not wired: Auto Clicker / Auto Train / Rebirth Skip / Robux pens (gamepasses), ShopTest and Admin (dev
       remotes), Diamond and Rainbow baits (Robux), bosses and the World 2 trip (events / 2.5e19), trading;
       BuyRod / EquipRod (rod tier proven irrelevant to a catch); PlaceAnimal / SellAnimal / SellPlaced
       (EquipBest places, SellAll sells: the per-uid versions add nothing).

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().seaAnimalsStop() ]]

-- config ---------------------------------------------------------------------
local CAST_QUALITY = 1 -- 1 - |meter|; 1 is a perfect cast, and the server takes it as sent
local CAST_GAP = 2.8 -- after a catch, before the next try (server line cooldown measured 3.07-3.16s)
local LINE_RETRY = 0.25 -- after "Your line is still out!", before the next try
local FISH_FOR = 30 -- default seconds on the dock per cycle when Lift is on too (panel box)
local LIFT_FOR = 30 -- default seconds on the bar per cycle when Fish is on too (panel box)
local MANAGE_EVERY = 8 -- catches between EquipBest + ClaimIndex (+ SellAll)
local WALK_TIMEOUT = 20 -- a walk that has not arrived by now is given up and retried
local WALK_BEAT = 0.4 -- MoveTo only steers for a few seconds: re-issue it this often
local BOOST_RETRY = 0.5 -- x2 lasts 3s; after firing Boost, how long before trying again if BoostUntil did not move
local ENTER_WAIT = 4 -- after reaching the dock / bar, how long the game's controller gets to start
local DOCK_SETTLE = 0.3 -- after fishing mode starts, before the first cast
local LEAVE_WAIT = 3 -- leaveDock() fades out; wait this long for Idle
local SPEND_EVERY = 3 -- seconds between buy passes
local SPEND_BACKOFF = 60 -- a buy that did not take is not retried for this long
local CLAIM_EVERY = 30
local REBIRTH_BACKOFF = 60
local INVOKE_TIMEOUT = 8 -- an InvokeServer that has not answered by now is abandoned
local STUCK_AFTER = 60 -- the watchdog prints a loop whose breadcrumb has not moved for this long

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer

if getgenv and getgenv().seaAnimalsStop then
	getgenv().seaAnimalsStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[seafish]", ...)
end

-- The strip is drained from a Heartbeat: a loop thread writing to the window throws after a task.wait.
local pending, lastSaid = {}, nil
local function say(msg)
	pending.now = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

local firsts = {}
local function first(name, ...) -- one console line the first time an unproven branch runs
	if not firsts[name] then
		firsts[name] = true
		log("first " .. name, ...)
	end
end

local crumbs = {}
local function step(loop, mark)
	crumbs[loop] = { mark = mark, at = os.clock() }
end

-- game -----------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
local okM, M = pcall(function()
	local client = player:WaitForChild("PlayerScripts"):WaitForChild("Client")
	local shared = ReplicatedStorage:WaitForChild("Shared")
	return {
		Config = require(shared:WaitForChild("Config")),
		Economy = require(shared:WaitForChild("Economy")),
		Animals = require(shared:WaitForChild("Animals")),
		PowerMeter = require(client:WaitForChild("Fishing"):WaitForChild("PowerMeter")),
		UIUtil = require(client:WaitForChild("UI"):WaitForChild("UIUtil")),
		Playtime = require(shared:WaitForChild("Playtime")),
		Ctl = require(client:WaitForChild("Fishing"):WaitForChild("Controller")),
		Lift = require(client:WaitForChild("World"):WaitForChild("Lift")),
		Controls = require(client:WaitForChild("Character"):WaitForChild("Controls")),
	}
end)
if not Remotes or not okM then
	warn("[seafish] the game's modules did not load:", M)
	return
end
local R = {}
for _, n in ipairs({ "Cast", "Land", "CastDone", "Rep", "Boost", "Notify", "EquipBest", "ClaimIndex", "ClaimPlaytime", "ClaimFreeGift", "UpgradeBarbell", "UpgradePen", "BuyBait", "EquipBait", "UsePotion", "Rebirth", "Lift" }) do
	R[n] = Remotes:WaitForChild(n, 15)
	if not R[n] then
		warn("[seafish] remote missing (game update?):", n)
		return
	end
end

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc", "Ud", "Dd", "Td", "Qad", "Qid", "Sxd", "Spd", "Ocd", "Nod", "Vg" }
local function fmt(n)
	n = tonumber(n) or 0
	local i = 1
	while math.abs(n) >= 1000 and i < #SUFFIX do
		n /= 1000
		i += 1
	end
	return ("%.3g"):format(n) .. SUFFIX[i]
end
assert(fmt(25000) == "25K" and fmt(1500) == "1.5K" and fmt(100) == "100", "fmt")

-- InvokeServer has no timeout; a handler that never answers would park the loop forever.
local function invoke(r, ...)
	local args, done, ok, res = table.pack(...), false, false, nil
	task.spawn(function()
		ok, res = pcall(function()
			return r:InvokeServer(table.unpack(args, 1, args.n))
		end)
		done = true
	end)
	local dl = os.clock() + INVOKE_TIMEOUT
	while not done and os.clock() < dl do
		task.wait()
	end
	if not done then
		return nil, "no answer"
	end
	if not ok then
		return nil, tostring(res)
	end
	return res
end
local function why(res, err)
	if type(res) == "table" then
		return tostring(res.msg or res.message or "refused")
	end
	return tostring(err or res)
end

local function attr(key)
	return player:GetAttribute(key)
end
local function money()
	return tonumber(attr("Money")) or 0
end
local legacy = function()
	return attr("LegacyPrices") == true
end

-- Waits up to `secs` for pred(); the server's answer to a FireServer is an attribute change.
local function waitFor(secs, pred)
	local dl = os.clock() + secs
	while os.clock() < dl do
		if pred() then
			return true
		end
		task.wait(0.1)
	end
	return pred()
end

local stats = { caught = 0, refused = 0, reps = 0, boosts = 0, bought = 0, biome = "-", last = "-" }

-- world ----------------------------------------------------------------------
local function root()
	local c = player.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	local r = c and c:FindFirstChild("HumanoidRootPart")
	if r and h and h.Health > 0 then
		return r, h
	end
	return nil, nil
end

local function world()
	local ok, w = pcall(M.Config.playerWorld, player)
	return ok and w or 1
end
local function castZone()
	local map = workspace:FindFirstChild("Map")
	local w = map and (map:FindFirstChild("World" .. tostring(world())) or map:FindFirstChild("World1"))
	local dock = w and w:FindFirstChild("FishingDock")
	return dock and dock:FindFirstChild("CastZone")
end
local function liftCenter()
	local ok, plot = pcall(M.Config.plotOf, player.UserId, world())
	local zone = ok and plot and plot:FindFirstChild("LiftZone")
	local c = zone and zone:FindFirstChild("Center")
	return c and c.Position
end

local function state()
	local ok, s = pcall(M.Ctl.stateName)
	return ok and s or "?"
end
local function lifting()
	local ok, a = pcall(M.Lift.isActive)
	return ok and a == true
end
local function atDock()
	local c = player.Character
	return state() == "Aiming" and c ~= nil and c:GetAttribute("Fishing") == true
end

-- The zone test is the controller's own (object space, flat): inside the box = it enters.
local function inZone(zone, p)
	local o = zone.CFrame:PointToObjectSpace(p)
	return math.abs(o.X) <= zone.Size.X / 2 and math.abs(o.Z) <= zone.Size.Z / 2
end
-- The point of the zone nearest to p, pulled 3 studs inside.
local function zonePoint(zone, p)
	local o = zone.CFrame:PointToObjectSpace(p)
	local hx, hz = zone.Size.X / 2, zone.Size.Z / 2
	local x = math.clamp(o.X, -hx + 3, hx - 3)
	local z = math.clamp(o.Z, -hz + 3, hz - 3)
	return zone.CFrame:PointToWorldSpace(Vector3.new(x, 0, z))
end
do
	local z = { CFrame = CFrame.new(0, 5, 6), Size = Vector3.new(92, 10, 12) }
	local p = zonePoint(z, Vector3.new(-71, 3, 41))
	assert(math.abs(p.X + 43) < 0.01 and math.abs(p.Z - 9) < 0.01 and inZone(z, p), "zonePoint inside")
end

-- Hops over 20 studs revert and glides are pulled back: walking is the only move that holds.
local function walkTo(pos, done)
	local dl = os.clock() + WALK_TIMEOUT
	while os.clock() < dl do
		if done() then
			return true
		end
		local r, h = root()
		if not r then
			return false
		end
		h:MoveTo(pos)
		task.wait(WALK_BEAT)
	end
	return done()
end

local function leaveDock()
	if state() == "Aiming" then
		pcall(M.Ctl.leaveDock)
		waitFor(LEAVE_WAIT, function()
			return state() == "Idle"
		end)
	end
end
local function leaveLift()
	if lifting() then
		-- The bar holds WalkSpeed at 0; unlocked, walking off the bar makes the Lift module stop() itself.
		pcall(M.Controls.unlock, "Lift")
	end
end

-- fish -----------------------------------------------------------------------
local on = {}
local conns = {}
local running = true

local function manage()
	step("fish", "manage")
	pcall(R.EquipBest.FireServer, R.EquipBest)
	pcall(R.ClaimIndex.FireServer, R.ClaimIndex, "all")
end

local sinceManage = 0
local function goDock()
	local zone = castZone()
	local r = root()
	if not zone or not r then
		step("fish", "no dock / character")
		task.wait(1)
		return false
	end
	leaveLift()
	-- The controller only enters on the way IN: standing in the zone while Idle needs a step out first,
	-- toward your plot (the other side of the dock is the water).
	local home = liftCenter()
	if home and inZone(zone, r.Position) and state() == "Idle" then
		step("fish", "step off the dock")
		walkTo(home, function()
			local rr = root()
			return rr ~= nil and not inZone(zone, rr.Position)
		end)
	end
	step("fish", "walk to dock")
	say("walking to the dock")
	r = root()
	if not r or not walkTo(zonePoint(zone, r.Position), function()
		local rr = root()
		return atDock() or (rr ~= nil and inZone(zone, rr.Position))
	end) then
		say("walk did not reach the dock (at " .. tostring(root() and root().Position) .. ")")
		task.wait(1)
		return false
	end
	step("fish", "enter dock")
	if not waitFor(ENTER_WAIT, atDock) then
		say("on the dock but fishing did not start (state " .. state() .. ")")
		task.wait(1)
		return false
	end
	task.wait(DOCK_SETTLE)
	pcall(M.PowerMeter.cancel) -- the aim meter is the game's, our casts never stop it: hide it, the dock view stays
	return true
end

-- The game's own toast (HUD, still drawn on the dock): the reveal cutscene is skipped, so this is the catch.
local function showCatch(res)
	local def = M.Animals.get(res.Id)
	local rarity = def and def.Rarity and (tostring(def.Rarity) .. " ") or ""
	local name = M.Animals.displayName and M.Animals.displayName(res) or tostring(res.Id)
	M.UIUtil.toast(("Caught %s%s  (1 in %s)"):format(rarity, tostring(name), fmt(res.Odds)), "success")
end

local function fishOnce()
	if not atDock() then
		if state() == "Casting" or state() == "Entering" or state() == "Leaving" then
			step("fish", "game busy: " .. state())
			task.wait(0.5) -- the player clicked, or the controller is mid-fade: let it finish
			return
		end
		if not goDock() then
			return
		end
	end
	step("fish", "cast")
	local res, err = invoke(R.Cast, CAST_QUALITY)
	if type(res) == "table" and res.ok then
		step("fish", "land")
		local land, lerr = invoke(R.Land, true)
		pcall(R.CastDone.FireServer, R.CastDone)
		local biome = M.Config.Biomes[tonumber(res.Biome) or 0]
		stats.biome = biome and tostring(biome.Name) or tostring(res.Biome or "-")
		if type(land) == "table" and land.Uid then
			stats.caught += 1
			stats.last = ("%s (1 in %s)"):format(tostring(res.Id), fmt(res.Odds))
			say(("caught %s, %s, %d studs"):format(stats.last, stats.biome, math.floor(tonumber(res.Distance) or 0)))
			local tok, terr = pcall(showCatch, res)
			if not tok then
				first("catch toast failed", terr)
			end
			if res.Fight and (tonumber(res.Fight.Ratio) or 0) >= M.Config.TooStrongRatio then
				first("too strong landed", res.Id, res.Fight.Ratio)
			end
			sinceManage += 1
			if on.manage and sinceManage >= MANAGE_EVERY then
				sinceManage = 0
				manage()
			end
		else
			stats.refused += 1
			say(("land refused on %s: %s"):format(tostring(res.Id), why(land, lerr)))
		end
		step("fish", "line cooldown")
		task.wait(CAST_GAP)
		return
	end
	local reason = why(res, err)
	if reason:lower():find("line is still out") then
		task.wait(LINE_RETRY)
		return
	end
	stats.refused += 1
	say("cast refused: " .. reason)
	if not atDock() then
		return -- the next pass walks back
	end
	task.wait(1)
end

-- lift -----------------------------------------------------------------------
-- The x2 bubble is the client's own (random, every 3-5s); pressing it only fires Boost, which the server takes
-- unoffered. So it is re-fired the moment the last one runs out: x2 reps for the whole leg.
local function boostLeft()
	local c = player.Character
	local u = c and tonumber(c:GetAttribute("BoostUntil"))
	return u and u - workspace:GetServerTimeNow() or 0
end
local boostAsked = 0
local function liftTick()
	if lifting() then
		step("fish", "lifting")
		if boostLeft() <= 0 and os.clock() - boostAsked > BOOST_RETRY then
			boostAsked = os.clock()
			pcall(R.Boost.FireServer, R.Boost)
			stats.boosts += 1
		end
		task.wait(0.1)
		return
	end
	local c = liftCenter()
	local r = root()
	if not c or not r then
		step("fish", "no lift zone / character")
		task.wait(1)
		return
	end
	leaveDock()
	step("fish", "walk to bar")
	say("walking to the bar")
	if not walkTo(Vector3.new(c.X, r.Position.Y, c.Z), function()
		local rr = root()
		return lifting() or (rr ~= nil and Vector2.new(rr.Position.X - c.X, rr.Position.Z - c.Z).Magnitude < 2)
	end) then
		say("walk did not reach the bar (at " .. tostring(root() and root().Position) .. ")")
		task.wait(1)
		return
	end
	step("fish", "start lift")
	if not waitFor(ENTER_WAIT, lifting) then
		first("lift did not start by itself, firing Lift(true)")
		pcall(R.Lift.FireServer, R.Lift, true)
		task.wait(1)
	end
end

table.insert(
	conns,
	R.Rep.OnClientEvent:Connect(function()
		stats.reps += 1
	end)
)
table.insert(
	conns,
	R.Notify.OnClientEvent:Connect(function(...)
		local parts = {}
		for _, v in ipairs({ ... }) do
			table.insert(parts, tostring(v))
		end
		log("notify: " .. table.concat(parts, " | "))
	end)
)

-- worker ---------------------------------------------------------------------
-- One thread owns the character. Both on: fishFor seconds on the dock, then liftFor on the bar.
local fishFor, liftFor = FISH_FOR, LIFT_FOR
local phase, phaseEnds = "lift", 0 -- flips to "fish" on the first pass
local mode = "off"

local function pickMode(now)
	if on.fish and on.lift then
		if now >= phaseEnds then
			phase = phase == "fish" and "lift" or "fish"
			phaseEnds = now + (phase == "fish" and fishFor or liftFor)
		end
		return phase
	end
	return on.fish and "fish" or on.lift and "lift" or "off"
end

task.spawn(function()
	while running do
		local m = pickMode(os.clock())
		if m ~= mode then
			if mode == "fish" and on.manage then
				manage() -- the pen takes this leg's catches before the walk
			end
			mode = m
			if m ~= "off" then
				say("now " .. (m == "fish" and "fishing" or "lifting"))
			end
		end
		local ok, e = pcall(function()
			if m == "fish" then
				fishOnce()
			elseif m == "lift" then
				liftTick()
			else
				step("fish", "off")
				task.wait(0.3)
			end
		end)
		if not ok then
			warn("[seafish] worker error:", e)
			task.wait(1)
		end
	end
end)

-- spend ----------------------------------------------------------------------
local parked = {} -- kind -> os.clock() before which a buy that did not take is not retried

-- Fires `remote`, then waits for `moved()` (the server's attribute change) as the confirm.
local function buy(kind, label, moved, remote, ...)
	if (parked[kind] or 0) > os.clock() then
		return false
	end
	step("light", "buy " .. label)
	pcall(remote.FireServer, remote, ...)
	if waitFor(2, moved) then
		stats.bought += 1
		say("bought " .. label)
		return true
	end
	parked[kind] = os.clock() + SPEND_BACKOFF
	say(("%s did not take: waiting %ds"):format(label, SPEND_BACKOFF))
	return false
end

-- The highest-luck bait above `curLuck` that is owned or affordable; Robux baits have no Price and are skipped.
local function bestBait(baits, curLuck, owned, cash)
	local best
	for _, b in ipairs(baits) do
		local price = tonumber(b.Price)
		local mine = owned[b.Key] == true
		if price and (tonumber(b.Luck) or 0) > curLuck and (mine or price <= cash) then
			if not best or b.Luck > best.Luck then
				best = b
			end
		end
	end
	return best, best and owned[best.Key] == true
end
do
	local L = { { Key = "a", Luck = 1.2, Price = 10 }, { Key = "b", Luck = 1.5, Price = 100 }, { Key = "r", Luck = 4 } }
	assert(bestBait(L, 1, {}, 50).Key == "a", "bestBait affordable")
	assert(bestBait(L, 1.2, {}, 50) == nil, "bestBait none above")
	local b, owned = bestBait(L, 1, { b = true }, 0)
	assert(b.Key == "b" and owned, "bestBait owned")
	assert(bestBait(L, 1, { r = true }, 1e30).Key == "b", "bestBait skips robux")
end

local function ownedSet(csv)
	local s = {}
	for k in tostring(csv or ""):gmatch("[^,]+") do
		s[k] = true
	end
	return s
end

-- ponytail: no payback ranking; each kind buys the moment cash covers it (barbell, then pen, then bait).
-- Income doubled every few minutes when measured, so order barely moved anything. Rank by cost/gain if it starts to.
local function spendPass()
	local tier = tonumber(attr("BarbellTier")) or 1
	if M.Config.Barbells[tier + 1] then
		local price = M.Config.barbellPrice(tier + 1, legacy())
		if price and money() >= price then
			buy("barbell", ("barbell tier %d (%s)"):format(tier + 1, fmt(price)), function()
				return (tonumber(attr("BarbellTier")) or 0) > tier
			end, R.UpgradeBarbell)
		end
	end
	local lvl, boost = tonumber(attr("PenLevel")) or 1, tonumber(attr("TankBoost")) or 0
	local penPrice = M.Config.penNextPrice(lvl, boost, legacy())
	if penPrice and money() >= penPrice then
		buy("pen", ("pen level %d (%s)"):format(lvl + 1, fmt(penPrice)), function()
			return (tonumber(attr("PenLevel")) or 0) > lvl or (tonumber(attr("TankBoost")) or 0) > boost
		end, R.UpgradePen)
	end
	local cur = tostring(attr("Bait") or "")
	local bait, owned = bestBait(M.Economy.Baits, M.Config.baitLuck(cur ~= "" and cur or nil), ownedSet(attr("BaitsOwned")), money())
	if bait then
		local moved = function()
			return attr("Bait") == bait.Key
		end
		if owned then
			buy("bait", "equip " .. bait.Key, moved, R.EquipBait, bait.Key)
		else
			buy("bait", ("%s bait (%s)"):format(bait.Key, fmt(bait.Price)), moved, R.BuyBait, bait.Key)
		end
	end
end

-- claims ---------------------------------------------------------------------
local function claimPass()
	local claimed = ownedSet(attr("PlayClaimed"))
	local played = tonumber(attr("PlaySeconds")) or 0
	for i, rw in ipairs(M.Playtime.Rewards) do
		if not claimed[tostring(i)] and played >= (tonumber(rw.At) or math.huge) * 60 then
			step("light", "playtime " .. i)
			pcall(R.ClaimPlaytime.FireServer, R.ClaimPlaytime, i)
			if waitFor(2, function()
				return ownedSet(attr("PlayClaimed"))[tostring(i)] == true
			end) then
				say(("playtime reward %d (%d min, %s) claimed"):format(i, rw.At, tostring(rw.Kind)))
			else
				first("playtime claim did not take", i)
			end
		end
	end
	local ready = tonumber(attr("FreeGiftReady"))
	if ready and workspace:GetServerTimeNow() >= ready then
		step("light", "free gift")
		pcall(R.ClaimFreeGift.FireServer, R.ClaimFreeGift)
		if waitFor(2, function()
			return (tonumber(attr("FreeGiftReady")) or 0) > ready
		end) then
			say("free gift claimed")
		else
			first("free gift did not take", ready)
		end
	end
end

-- PotionStock is JSON: {"Cash:120": 1} (stat:seconds -> count), or "[]" when empty.
local function potionKeys(raw)
	local ok, t = pcall(HttpService.JSONDecode, HttpService, tostring(raw or "[]"))
	local keys = {}
	if ok and type(t) == "table" then
		for k, n in pairs(t) do
			if type(k) == "string" and (tonumber(n) or 0) > 0 then
				table.insert(keys, k)
			end
		end
	end
	table.sort(keys)
	return keys
end
assert(#potionKeys("[]") == 0 and potionKeys('{"Cash:120":1,"Strength:180":0}')[1] == "Cash:120", "potionKeys")

local function potionPass()
	for _, key in ipairs(potionKeys(attr("PotionStock"))) do
		local stat = key:match("^(%a+)")
		if stat and (tonumber(attr("Potion_" .. stat)) or 0) <= 0 then
			step("light", "potion " .. key)
			pcall(R.UsePotion.FireServer, R.UsePotion, key)
			if waitFor(2, function()
				return (tonumber(attr("Potion_" .. stat)) or 0) > 0
			end) then
				say("drank " .. key)
			else
				first("potion did not take", key)
			end
		end
	end
end

-- rebirth --------------------------------------------------------------------
local rebirthAt = 0
local function rebirthNeeds()
	local n = tonumber(attr("Rebirths")) or 0
	return n, M.Config.rebirthCost(n), M.Config.rebirthStrength(n)
end
local function rebirthPass()
	local n, cost, need = rebirthNeeds()
	if os.clock() < rebirthAt or money() < cost or (tonumber(attr("Strength")) or 0) < need then
		return
	end
	step("light", "rebirth " .. (n + 1))
	first("rebirth", n + 1, "money", money(), "strength", attr("Strength"), "barbell", attr("BarbellTier"), "pen", attr("PenLevel"))
	pcall(R.Rebirth.FireServer, R.Rebirth)
	if waitFor(3, function()
		return (tonumber(attr("Rebirths")) or 0) > n
	end) then
		table.clear(parked)
		say(("REBIRTH %d: now x%s cash"):format(n + 1, tostring(M.Config.rebirthMultiplier(n + 1))))
		log("after rebirth: money", money(), "strength", attr("Strength"), "barbell", attr("BarbellTier"), "pen", attr("PenLevel"))
	else
		rebirthAt = os.clock() + REBIRTH_BACKOFF
		say(("rebirth %d did not take: waiting %ds"):format(n + 1, REBIRTH_BACKOFF))
	end
end

-- light ----------------------------------------------------------------------
-- Everything the server takes from anywhere: no character, so it runs beside the fish/lift loop.
task.spawn(function()
	local nextSpend, nextClaim = 0, 0
	while running do
		local now = os.clock()
		step("light", "tick")
		local ok, e = pcall(function()
			if on.rebirth then
				rebirthPass()
			end
			if on.upgrades and now >= nextSpend then
				nextSpend = now + SPEND_EVERY
				spendPass()
			end
			if now >= nextClaim then
				nextClaim = now + CLAIM_EVERY
				if on.playtime then
					claimPass()
				end
				if on.potions then
					potionPass()
				end
			end
		end)
		if not ok then
			warn("[seafish] light error:", e)
		end
		task.wait(0.5)
	end
end)

-- watchdog -------------------------------------------------------------------
task.spawn(function()
	local told = {}
	while running do
		for loop, c in pairs(crumbs) do
			local age = os.clock() - c.at
			if age > STUCK_AFTER and told[loop] ~= c.at and c.mark ~= "off" and c.mark ~= "lifting" then
				told[loop] = c.at
				warn(("[seafish] %s stuck %ds at: %s"):format(loop, math.floor(age), c.mark))
			end
		end
		task.wait(5)
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Fish for Sea Animals", statusBar = true })
if not Window then
	running = false
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "fish")
local Core = Tab:AddLeftGroupbox("Fishing", "anchor")
local Spend = Tab:AddRightGroupbox("Spending", "trending-up")
local Extra = Tab:AddRightGroupbox("Extras", "gift")

local function flag(key)
	return function(state)
		on[key] = state == true
	end
end
local function seconds(apply)
	return function(text)
		local v = tonumber(text)
		if v and v >= 5 then
			apply(v)
		end
	end
end

Core:AddToggle("Fish", {
	Text = "Auto Fish",
	Tooltip = "Walks onto the dock, then a perfect cast + instant catch every ~3.1s (no meter, no reel, no cutscene)",
	Default = false,
	Callback = flag("fish"),
})
Core:AddToggle("Lift", {
	Text = "Auto Lift",
	Tooltip = "Lifts on your plot's bar for Strength (= cast distance = biome). With Auto Fish on too, the two take turns",
	Default = false,
	Callback = flag("lift"),
})
Core:AddInput("FishFor", {
	Text = "Fish for (s, when both on)",
	Default = tostring(FISH_FOR),
	Numeric = true,
	Finished = true,
	Callback = seconds(function(v)
		fishFor = v
	end),
})
Core:AddInput("LiftFor", {
	Text = "Lift for (s, when both on)",
	Default = tostring(LIFT_FOR),
	Numeric = true,
	Finished = true,
	Callback = seconds(function(v)
		liftFor = v
	end),
})
Core:AddToggle("Manage", {
	Text = "Equip Best + Claim Index",
	Tooltip = "Every 8 catches and after each fishing leg: Equip Best fills the pen with your top earners, Claim Index pays for new species",
	Default = false,
	Callback = flag("manage"),
})
Spend:AddToggle("Upgrades", {
	Text = "Auto Upgrades",
	Tooltip = "Next barbell, next pen level (then tank boosts), best affordable bait; the moment cash covers each. Works from anywhere",
	Default = false,
	Callback = flag("upgrades"),
})
Spend:AddToggle("Rebirth", {
	Text = "Auto Rebirth",
	Tooltip = "Rebirths once cash and Strength cover it: +0.5x cash, x1.5 strength rate. Resets cash, level, Strength; keeps animals, barbell, pen, bait",
	Default = false,
	Callback = flag("rebirth"),
})
Extra:AddToggle("Playtime", {
	Text = "Claim Playtime + Gift",
	Tooltip = "Each playtime reward as it unlocks, and the free gift when its timer is up",
	Default = false,
	Callback = flag("playtime"),
})
Extra:AddToggle("Potions", {
	Text = "Use Potions",
	Tooltip = "Drinks stored potions (cash, strength) whose effect is not already running",
	Default = false,
	Callback = flag("potions"),
})

local note = "idle"
local nextStrip = 0
table.insert(
	conns,
	RunService.Heartbeat:Connect(function()
		if pending.now then
			note, pending.now = pending.now, nil
		end
		local now = os.clock()
		if now < nextStrip then
			return
		end
		nextStrip = now + 0.5
		local n, cost, need = rebirthNeeds()
		pcall(Window.SetStatus, Window, {
			{ "Cash", fmt(money()) },
			{ "Income", fmt(attr("Income")) .. "/s" },
			{ "Strength", fmt(attr("Strength")) },
			{ "Biome", stats.biome },
			{ "Mode", mode == "off" and "off" or mode .. (on.fish and on.lift and (" %ds"):format(math.max(0, phaseEnds - now)) or "") },
			{ "Catches", ("%d (%d refused)"):format(stats.caught, stats.refused) },
			{ "Reps", ("%d (%d x2)"):format(stats.reps, stats.boosts) },
			{ "Pen", tostring(attr("PenCapacity") or "-") },
			{ "Rebirth", ("%d, next %s + %s str"):format(n, fmt(cost), fmt(need)) },
			{ "Last", stats.last },
			{ "Now", note },
		})
	end)
)

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

Window:AddSettingsTab("FishForSeaAnimals", {})

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
	for k in pairs(on) do
		on[k] = false
	end
	running = false
	leaveDock() -- hand the character back: the dock and the bar both hold WalkSpeed at 0
	leaveLift()
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().seaAnimalsStop = nil
end)

getgenv().seaAnimalsStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().seaAnimalsStop = nil
end
