--[[ Rescue a Fish -- break ice on the belt, fill the tank, buy every upgrade (126826719421373)

     SWING   : fires Pickaxe.Strike at your swing speed whenever a block is in reach. The server takes one tap
               per swing interval and drops the rest (probed: 73 strikes in 4s landed 8 at level 0), so faster
               firing gains nothing. Damage is the server's: pickaxe Power x crit x boosts. No instant break.
     FOLLOW  : walks beside the most valuable block you can still break before it leaves the belt (HP from
               the game's IceHp and live Health events, your damage from PickaxeDamage, value from
               PetInstance.GetSpawnIncome). Walk only (Humanoid:MoveTo); the belt runs 6.7 studs/s, you 30.
     PLACE   : Aquarium.PlaceBest, the game's own button (probed: placed 12, a repeat is a no-op).
     LEVEL   : Aquarium.LevelUp on the cheapest placed fish while cash stays above the reserve (probed 1 -> 2).
     UPGRADE : Shop.Upgrade(key), cheapest ticked row first, costs from UpgradeConfig (probed Crit 10 -> 11).
     PICKAXE : Shop.Buy(next tier) once affordable and unlocked by rebirths; buying equips it (probed 18 -> 19).
     TANK    : Tank.Upgrade on the equipped tank (probed Lagoon 1 -> 2, max 5) or Tank.Buy + Equip of the next
               tank, whichever is cheaper. Never BuyRobux.
     REBIRTH : Rebirth.Request() when Cash covers RebirthConfig.GetCost (ran live: 3 -> 4 at 2.2T, 4 -> 5 at 33T).
     WORLD   : walks onto this world's portal Pad (the server answers World.Prompt; Travel is refused silently
               off the pad), then World.Travel to your best open world; probed there and back, 0.3s a hop.
               Pays for the next world once its RebirthGate and price are met (ran live: Forge, 1.9T). Paying
               drops you at that world's obby, and the obby is still yours to cross: the server counts
               checkpoints by position (no touch parts), 11+ of them over ~730 studs above a kill floor.
     MUTATE  : buys every ticked mutation in stock this rotation (MutationShopStock.For is seeded, so stock is
               known without asking) and applies held ones to the tank fish they raise most, biggest gain
               first. Applying costs about 5 minutes of the gain, so it may take a quarter of your cash.
     REWARDS : playtime gifts (probed), offline earnings (free claim only, never the paid x2), and the reward
               track: its server wants you within the stand's 12-stud prompt (refused from 70 studs), so the
               script walks there when it is ready and nothing else is moving you.
     HATCH   : FishEgg.Hatch(uid) once an egg's HatchAt has passed. SkipHatch is the paid route, not wired.
     AUTOSELL: the game's own AutoSell setting, put back the way you had it on unload.

     SPENDING: upgrades, pickaxe, tank, rebirth and the next world each post the price of what they want
               next; fish levels only spend above the cheapest of them, or they eat every coin first.

     Probed and dead: instant break / Strike spam (server rate cap, see SWING). ClaimTrack from afar.
     World.Travel off the portal pad. Not run live: Hatch (no egg in the tank during testing).
     The belt only spawns while you stand at it: from the plot area 0 blocks came in 2 minutes. Follow walks
     back from up to 300 studs and otherwise says how far your belt is.
     Placed fish and eggs are read from the game's own Plot.Fish handler (its first upvalue, [plot].Instances);
     tank levels from the TankShopUI's Tank.Owned handler. Both have our own listener as the fallback.
     Movement: walk only, at the game's WalkSpeed. The dossier rates teleports KICK-WEIGHTED; no hop was tried.

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().rescueFishStop() ]]

-- config ---------------------------------------------------------------------
local SWING_SLACK = 0.03 -- added to the game's own swing interval; raise if the taps per second drop
local SWING_TICK = 0.05 -- how often the swing loop looks for a block in reach
local FOLLOW_TICK = 0.15 -- how often Follow re-aims the walk at its block
local BREAK_MARGIN = 3 -- seconds of slack a block must leave beyond the time it needs; raise if blocks escape
local MIN_LEFT = 4 -- a block with less than this left on the belt is not worth walking to
local PLACE_EVERY = 5
local LEVEL_EVERY = 0.4
local BUY_EVERY = 1 -- upgrade shop, pickaxe, tank, rebirth: one look this often
local BUY_BACKOFF = 10 -- a purchase the server did not take is not retried for this long
local HATCH_EVERY = 2
local WORLD_EVERY = 5
local MUTATION_EVERY = 2
local APPLY_SHARE = 0.25 -- one mutation apply may cost up to this share of your cash; it pays back in ~5 min
local PAD_WAIT = 20 -- seconds to stand on the portal pad waiting for the server's World.Prompt
local REWARD_EVERY = 20
local TRACK_REACH = 8 -- studs from the reward-track stand to fire the claim from (prompt range is 12)
local TRACK_MAX_WALK = 250 -- the stand is in the first world; from another world it is ~12000 studs away
local BELT_MAX_WALK = 300 -- Follow walks back to your world's belt from this close; worlds sit 8000 studs apart
local WALK_TIMEOUT = 25
local WATCHDOG = 30

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().rescueFishStop then
	getgenv().rescueFishStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[rescuefish]", ...)
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
local R = ReplicatedStorage:WaitForChild("Remotes", 15)
local Sh = ReplicatedStorage:WaitForChild("Shared", 15)
local ok, M = pcall(function()
	local Client = player:WaitForChild("PlayerScripts"):WaitForChild("Client")
	return {
		cc = require(Client.Conveyor.ConveyorController),
		CPath = require(Sh.Conveyor.ConveyorPath),
		IceHp = require(Sh.Conveyor.IceHp),
		AxeOrbit = require(Sh.Pickaxe.AxeOrbit),
		PC = require(Sh.Pickaxe.PickaxeConfig),
		PD = require(Sh.Pickaxe.PickaxeDamage),
		PI = require(Sh.Pets.PetInstance),
		UC = require(Sh.Shop.UpgradeConfig),
		PP = require(Sh.Shop.PickaxePrice),
		PU = require(Sh.Pickaxe.PickaxeUnlocks),
		PReg = require(Sh.Pickaxe.PickaxeRegistry),
		TC = require(Sh.Tank.TankConfig),
		WC = require(Sh.World.WorldConfig),
		MSC = require(Sh.Restock.MutationShopConfig),
		MSS = require(Sh.Restock.MutationShopStock),
		RSt = require(Client.Restock.RestockState),
		TUC = require(Sh.Tank.TankUpgradeConfig),
		RC = require(Sh.Rebirth.RebirthConfig),
		PRC = require(Sh.Rewards.PlaytimeRewardConfig),
		SC = require(Sh.Settings.SettingsConfig),
	}
end)
if not ok then
	warn("[rescuefish] the game's modules did not load:", M)
	return
end

local function attr(name, default)
	local v = player:GetAttribute(name)
	if v == nil then
		return default
	end
	return v
end

local function cash()
	return attr("Cash", 0)
end

local function now()
	return workspace:GetServerTimeNow()
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
assert(ticked({ "a" }).a and ticked({ a = true }).a and not ticked({ a = false }).a, "ticked reads both shapes")

local reserve = 0 -- cash every spending loop leaves alone
local function spendable()
	return cash() - reserve
end

-- Fish levels cost little and never run out, so on their own they eat every coin before an upgrade,
-- pickaxe or tank can be saved for. Each of those loops posts the price of what it wants next, and
-- levels only spend what is left above the cheapest of them.
local want = {} -- loop name -> price of its next purchase
local function surplus()
	local floor = 0
	for _, price in pairs(want) do
		if floor == 0 or price < floor then
			floor = price
		end
	end
	return spendable() - floor
end

local stats = { strikes = 0, broken = 0, placed = 0, levels = 0, upgrades = 0, pickaxes = 0, tanks = 0, rebirths = 0, hatched = 0, claims = 0, mutations = 0 }

-- breadcrumbs: every loop marks its step, a watchdog names the one that stopped moving
local marks = {}
local function step(loop, what)
	marks[loop] = { what, os.clock() }
end

-- character ------------------------------------------------------------------
local function body()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if hum and root and hum.Health > 0 then
		return char, hum, root
	end
	return nil
end

-- One owner of the walk at a time: Follow takes it per block, the reward track per trip.
local busy = nil
local function claim(who, fn)
	if busy and busy ~= who then
		return false
	end
	busy = who
	local okRun, err = pcall(fn)
	busy = nil
	if not okRun then
		warn("[rescuefish]", who, "threw:", err)
	end
	return true
end

local function pickaxeTool()
	local char = player.Character
	local held = char and char:FindFirstChildWhichIsA("Tool")
	if held and held:GetAttribute("PickaxeTool") == true then
		return held
	end
	for _, t in player.Backpack:GetChildren() do
		if t:IsA("Tool") and t:GetAttribute("PickaxeTool") == true then
			return t
		end
	end
	return nil
end

-- the server hits with what you hold
local function holdPickaxe()
	local _, hum = body()
	local tool = pickaxeTool()
	if hum and tool and tool.Parent ~= player.Character then
		pcall(hum.EquipTool, hum, tool)
	end
	return tool
end

local function walkTo(pos, near, alive)
	local t0, lastIssue = os.clock(), 0
	while alive() and os.clock() - t0 < WALK_TIMEOUT do
		local _, hum, root = body()
		if not hum then
			return false
		end
		if (root.Position - pos).Magnitude <= near then
			return true
		end
		if os.clock() - lastIssue > 1 then -- MoveTo gives up after ~8s, so re-issue it
			hum:MoveTo(pos)
			lastIssue = os.clock()
		end
		task.wait(0.1)
	end
	return false
end

-- belt -----------------------------------------------------------------------
local hp = {} -- block id -> health the server last reported
local gone = {} -- block id -> true once broken or removed
local conns = {}
table.insert(conns, R.Conveyor.Health.OnClientEvent:Connect(function(t)
	if type(t) == "table" then
		for _, v in t do
			hp[v[1]] = v[2]
		end
	end
end))
table.insert(conns, R.Conveyor.Broken.OnClientEvent:Connect(function(id)
	gone[id] = true
	hp[id] = nil
	stats.broken += 1
end))
table.insert(conns, R.Conveyor.Removed.OnClientEvent:Connect(function(id)
	gone[id] = true
	hp[id] = nil
end))
local spawned = 0
table.insert(conns, R.Conveyor.Spawn.OnClientEvent:Connect(function()
	spawned += 1
end))

local function swingSeconds()
	return M.PC.SwingSecondsAt(attr("AttackSpeedLevel", 0))
end

-- damage per second: the orbiting axes (PickaxeDamage.Mirrored) plus one tap per swing
local function dps()
	local orbit = M.PD.Mirrored(player)
	local axes = math.max(attr("AxeCount", 1), 1) * M.PC.RevolutionsPerSecond
	return orbit + orbit / axes * (M.PC.TapDamageScale or 1) / swingSeconds()
end

local function reach()
	local tool = pickaxeTool()
	local name = tool and tool:GetAttribute("PickaxeName")
	return (type(name) == "string" and M.AxeOrbit.GetReach(name) or 3) + M.PC.TapReachBonus
end

-- a block your swing touches right now (the server picks which; any one in reach is enough)
local function blockInReach()
	local _, _, root = body()
	if not root then
		return nil
	end
	local r, found = reach(), nil
	M.cc.ForEachBlock(function(id, _, _, broken)
		if found or broken or gone[id] then
			return
		end
		local cf, size = M.cc.GetBlockFrame(id)
		if cf and size and M.AxeOrbit.SphereTouchesBox(root.Position, r, cf, size) then
			found = id
		end
	end)
	return found
end

local function valueOf(id, pet)
	local _, _, _, _, weight = M.cc.GetBlock(id)
	-- shortcut: ignores trait and weather on the block, add them when the payload's shape is known
	local okV, v = pcall(M.PI.GetSpawnIncome, pet.Id, weight or 1)
	return okV and v or 0
end

-- best block you can still break before it leaves; nil, reason when there is none
local function pickBlock()
	local _, hum, root = body()
	if not root then
		return nil, "no character"
	end
	local d, speed = dps(), math.max(hum.WalkSpeed, 1)
	local best, bestScore, why = nil, nil, "no block on the belt"
	M.cc.ForEachBlock(function(id, pet, pos, broken, left)
		if broken or gone[id] or not pet or (left or 0) < MIN_LEFT then
			return
		end
		local health = hp[id] or M.IceHp.For(pet)
		local eta = (pos - root.Position).Magnitude / speed
		if health / d + eta + BREAK_MARGIN > left then
			why = "nothing breakable in time (dps " .. fmt(d) .. ")"
			return
		end
		local score = valueOf(id, pet)
		if not bestScore or score > bestScore then
			best, bestScore = id, score
		end
	end)
	return best, why
end
assert(M.PD.SecondsToBreak(10, 5) == 2, "SecondsToBreak shape changed")

-- the nearest point on your world's main belt, and how far it is; the server spawns nothing for you
-- while you stand away from it (0 spawns in 2 minutes measured from the plot area)
local function nearestBelt()
	local _, _, root = body()
	local s, e = M.CPath.Resolve("Main", attr("World", nil))
	if not (root and s and e) then
		return nil, math.huge
	end
	local a, b, p = s.Position, e.Position, root.Position
	local ab = b - a
	local t = math.clamp((p - a):Dot(ab) / ab:Dot(ab), 0, 1)
	local point = a + ab * t
	return point, (Vector3.new(point.X, p.Y, point.Z) - p).Magnitude
end

-- loops ----------------------------------------------------------------------
-- One generation counter per toggle: off-then-on inside one interval must not leave the old thread alive.
local loops = {}
local function makeLoop(name, every, pass, onStop)
	local L = { on = false, gen = 0 }
	function L.set(state)
		local was = L.on
		L.on = state
		L.gen += 1
		if not state then
			marks[name] = nil
			want[name] = nil -- a switched-off loop no longer holds money back
			if was and onStop then
				pcall(onStop)
			end
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
					warn("[rescuefish]", name, "pass threw:", err)
				end
				task.wait(type(every) == "function" and every() or every)
			end
		end)
	end
	loops[name] = L
	return L
end

-- swing ----------------------------------------------------------------------
local lastStrike = 0
makeLoop("swing", SWING_TICK, function()
	if attr("InTraining", false) == true then
		return
	end
	if os.clock() - lastStrike < swingSeconds() + SWING_SLACK then
		return
	end
	if not blockInReach() then
		return
	end
	if not holdPickaxe() then
		say("swing: no pickaxe in the backpack")
		return
	end
	lastStrike = os.clock()
	R.Pickaxe.Strike:FireServer()
	stats.strikes += 1
	first("strike")
end)

-- follow ---------------------------------------------------------------------
-- One block per claim, so the reward-track walk gets the character between blocks.
local target = nil
makeLoop("follow", FOLLOW_TICK, function(alive)
	claim("follow", function()
		step("follow", "pick")
		local id, why = pickBlock()
		if not id then
			target = nil
			local point, far = nearestBelt()
			if point and far > 30 and far <= BELT_MAX_WALK then
				step("follow", "back to the belt")
				say(("follow: walking back to the belt (%d studs)"):format(far))
				walkTo(point, 12, alive)
			elseif far > BELT_MAX_WALK then
				note = far == math.huge and "follow: can't find your world's belt"
					or ("follow: your belt is %d studs away, stand near it"):format(far)
				first("belt too far", far)
			else
				note = "follow: " .. why -- every few seconds while blocks die on spawn: strip only, no log line
			end
			return
		end
		if id ~= target then
			target = id
			local pet = M.cc.GetBlock(id)
			say(("follow: %s (%s)"):format(pet and pet.Name or "?", pet and pet.Rarity or "?"))
		end
		-- stay on this block until it breaks, leaves, or stops being breakable in time
		while alive() and not gone[id] do
			local _, hum, root = body()
			local pet, broken, left = M.cc.GetBlock(id)
			if not hum or not pet or broken or (left or 0) <= 0.5 then
				return
			end
			local cf = M.cc.GetBlockFrame(id)
			if not cf then
				return
			end
			local to = cf.Position - root.Position
			to = Vector3.new(to.X, 0, to.Z)
			local stand = cf.Position - (to.Magnitude > 0.1 and to.Unit or Vector3.zero) * reach() * 0.6
			step("follow", "walk " .. pet.Name)
			hum:MoveTo(Vector3.new(stand.X, root.Position.Y, stand.Z))
			task.wait(FOLLOW_TICK)
			local health = hp[id] or M.IceHp.For(pet)
			if health / dps() > left then
				return -- it will leave first; a better one may be breakable
			end
		end
	end)
end, function()
	target = nil
	local _, hum, root = body()
	if hum then
		hum:MoveTo(root.Position) -- stop where you are
	end
end)

-- tank -----------------------------------------------------------------------
local function myPlot()
	for _, p in workspace:WaitForChild("Plots"):GetChildren() do
		if p:GetAttribute("Owner") == player.UserId then
			return tonumber(p.Name:match("%d+"))
		end
	end
	return nil
end

-- the game's own per-plot cache (Plot.Fish handler, first upvalue); our listener is the fallback
local ownTank = { Instances = {}, Eggs = {} }
table.insert(conns, R.Plot.Fish.OnClientEvent:Connect(function(idx, fish, eggs)
	if idx == myPlot() then
		ownTank.Instances = type(fish) == "table" and fish or {}
		ownTank.Eggs = type(eggs) == "table" and eggs or ownTank.Eggs
	end
end))
local function tank()
	local okT, t = pcall(function()
		for _, c in getconnections(R.Plot.Fish.OnClientEvent) do
			local up = c.Function and debug.getupvalues(c.Function)[1]
			local mine = type(up) == "table" and up[myPlot()]
			if type(mine) == "table" and type(mine.Instances) == "table" then
				return mine
			end
		end
		return nil
	end)
	if okT and t then
		first("tank cache", "game's own")
		return t
	end
	first("tank cache", "own listener")
	return ownTank
end

makeLoop("place", PLACE_EVERY, function()
	local before = #tank().Instances
	R.Aquarium.PlaceBest:FireServer()
	task.wait(1)
	if #tank().Instances ~= before then
		stats.placed += 1
		say(("placed best: %d in the tank"):format(#tank().Instances))
	end
end)

makeLoop("level", LEVEL_EVERY, function()
	local best, bestCost
	local budget = surplus()
	for _, f in tank().Instances do
		local c = M.PI.GetUpgradeCost(f)
		if c and c <= budget and (not bestCost or c < bestCost) then
			best, bestCost = f, c
		end
	end
	if not best then
		return
	end
	local uid, lvl = best.Uid, best.Level or 1
	step("level", "level " .. uid)
	R.Aquarium.LevelUp:FireServer(uid)
	local t0 = os.clock()
	while os.clock() - t0 < 1.5 do
		for _, f in tank().Instances do
			if f.Uid == uid and (f.Level or 1) > lvl then
				stats.levels += 1
				say(("levelled fish to %d (%s)"):format(f.Level, fmt(bestCost)))
				return
			end
		end
		task.wait(0.05)
	end
	first("level not confirmed", uid, lvl, fmt(bestCost))
end)

makeLoop("hatch", HATCH_EVERY, function()
	for _, e in tank().Eggs do
		local at = M.PI.GetHatchAt(e)
		if at and now() >= at then
			R.FishEgg.Hatch:FireServer(e.Uid)
			stats.hatched += 1
			first("hatch", e.Uid)
		end
	end
end)

-- upgrades -------------------------------------------------------------------
local refused = {} -- key -> os.clock() before which it is not retried
local function tryBuy(key, fire, done)
	if (refused[key] or 0) > os.clock() then
		return false
	end
	fire()
	local t0 = os.clock()
	while not done() and os.clock() - t0 < 1.5 do
		task.wait()
	end
	if done() then
		return true
	end
	refused[key] = os.clock() + BUY_BACKOFF
	first("refused " .. key, "backing off", BUY_BACKOFF)
	return false
end

local upgradeOn = {}
makeLoop("upgrade", BUY_EVERY, function()
	local reb = attr("Rebirths", 0)
	local best, bestCost, bestLvl
	for _, u in M.UC.Upgrades do
		if upgradeOn[u.Key] then
			local lvl = M.UC.GetLevel(u, attr(u.Attribute, u.Base), false)
			local cost = not M.UC.IsMaxed(u, lvl, false) and M.UC.GetCost(u, lvl, false, reb)
			if cost and (not bestCost or cost < bestCost) then
				best, bestCost, bestLvl = u, cost, lvl
			end
		end
	end
	want.upgrade = bestCost or nil
	if not best or bestCost > spendable() then
		return
	end
	local before = attr(best.Attribute, best.Base)
	step("upgrade", "upgrade " .. best.Key)
	if
		tryBuy("upgrade " .. best.Key, function()
			R.Shop.Upgrade:FireServer(best.Key)
		end, function()
			return attr(best.Attribute, best.Base) ~= before
		end)
	then
		stats.upgrades += 1
		say(("upgrade %s -> %d (%s)"):format(best.DisplayName or best.Key, bestLvl + 1, fmt(bestCost)))
	end
end)

makeLoop("pickaxe", BUY_EVERY, function()
	local tier, reb = attr("PickaxeTier", 1), attr("Rebirths", 0)
	local nxt = tier + 1
	if nxt > M.PReg.MaxTier or not M.PU.IsUnlocked(nxt, reb) then
		want.pickaxe = nil
		return
	end
	local price = M.PP.Get(nxt, reb)
	want.pickaxe = price
	if not price or price > spendable() then
		return
	end
	step("pickaxe", "buy " .. nxt)
	if
		tryBuy("pickaxe " .. nxt, function()
			R.Shop.Buy:FireServer(nxt)
		end, function()
			return attr("PickaxeTier", 1) >= nxt
		end)
	then
		stats.pickaxes += 1
		say(("pickaxe tier %d (%s)"):format(nxt, fmt(price)))
	end
end)

-- tanks owned and their levels: TankShopUI keeps them in its Tank.Owned handler; our listener is the fallback
local tankOwned, tankLevels = { [M.TC.DefaultKey or "Default"] = true }, {}
table.insert(conns, R.Tank.Owned.OnClientEvent:Connect(function(owned, _, levels)
	tankOwned = { [M.TC.DefaultKey or "Default"] = true }
	for _, k in type(owned) == "table" and owned or {} do
		tankOwned[k] = true
	end
	tankLevels = type(levels) == "table" and levels or {}
end))
-- only the game's own handler: it is the one holding TankConfig. Listeners left by an earlier paste
-- carry stale levels, and a stale level fires an upgrade the server refuses.
pcall(function()
	for _, c in getconnections(R.Tank.Owned.OnClientEvent) do
		local ups = debug.getupvalues(c.Function or function() end)
		local isGame = false
		for _, v in ups do
			isGame = isGame or (type(v) == "table" and v == M.TC)
		end
		if isGame then
			for _, v in ups do
				if type(v) == "table" and v.Default == true then
					for k in v do
						tankOwned[k] = true
					end
				elseif type(v) == "table" and v ~= M.TC and v ~= M.TUC and type(select(2, next(v))) == "number" then
					tankLevels = table.clone(v)
				end
			end
			first("tank levels", "from the game's handler")
		end
	end
end)

makeLoop("tank", BUY_EVERY, function()
	local key = attr("Tank", "Default")
	local cur = M.TC.GetOrDefault(key)
	local lvl = M.TUC.Clamp(tankLevels[key])
	local upCost = lvl < M.TUC.MaxLevel and M.TUC.PriceFor(cur.Price, lvl) or nil
	local nextTank -- the first tank after the equipped one you don't own yet
	local passed = false
	for _, t in M.TC.Tanks do
		if passed and not tankOwned[t.Key] and type(t.Price) == "number" and t.Price > 0 then
			nextTank = t
			break
		end
		passed = passed or t.Key == cur.Key
	end
	want.tank = math.min(upCost or math.huge, nextTank and nextTank.Price or math.huge)
	if want.tank == math.huge then
		want.tank = nil
	end
	if nextTank and nextTank.Price <= spendable() and (not upCost or nextTank.Price <= upCost) then
		step("tank", "buy " .. nextTank.Key)
		if
			tryBuy("tank " .. nextTank.Key, function()
				R.Tank.Buy:FireServer(nextTank.Key)
			end, function()
				return tankOwned[nextTank.Key] == true
			end)
		then
			R.Tank.Equip:FireServer(nextTank.Key)
			stats.tanks += 1
			say(("tank %s bought (%s)"):format(nextTank.Name, fmt(nextTank.Price)))
		end
		return
	end
	if upCost and upCost <= spendable() then
		step("tank", "upgrade " .. key)
		if
			tryBuy("tank up " .. key, function()
				R.Tank.Upgrade:FireServer(key)
			end, function()
				return M.TUC.Clamp(tankLevels[key]) > lvl
			end)
		then
			stats.tanks += 1
			say(("tank %s -> level %d (%s)"):format(cur.Name, lvl + 1, fmt(upCost)))
		end
	end
end)

makeLoop("rebirth", BUY_EVERY, function()
	local reb = attr("Rebirths", 0)
	if reb >= M.RC.Config.MaxRebirths then
		return
	end
	local cost = M.RC.GetCost(reb)
	want.rebirth = cost
	if not cost or cash() < cost then
		return
	end
	step("rebirth", "request")
	if
		tryBuy("rebirth", function()
			R.Rebirth.Request:FireServer()
		end, function()
			return attr("Rebirths", 0) > reb
		end)
	then
		stats.rebirths += 1
		say(("rebirth %d -> %d (%s)"):format(reb, reb + 1, fmt(cost)))
	end
end)

-- rewards --------------------------------------------------------------------
local function trackStand()
	local tagged = game:GetService("CollectionService"):GetTagged("RewardTrack")
	local stand = tagged[1] or workspace:FindFirstChild("RewardTrack")
	local prompt = stand and stand:FindFirstChildWhichIsA("ProximityPrompt", true)
	local part = prompt and prompt:FindFirstAncestorWhichIsA("BasePart")
	return part and part.Position or (stand and stand:GetPivot().Position)
end

makeLoop("rewards", REWARD_EVERY, function(alive)
	local played = now() - attr("PlaytimeStart", now())
	local claimed = M.PRC.ParseClaimed(attr(M.PRC.ClaimedAttribute, ""))
	for _, g in M.PRC.Gifts do
		if g.Seconds <= played and not claimed[g.Id] then
			R.Rewards.ClaimPlaytime:FireServer(g.Id)
			stats.claims += 1
			first("playtime", g.Id)
			task.wait(0.5)
		end
	end
	R.OfflineEarnings.Claim:FireServer(false) -- false = the free claim; true is the paid x2
	local ready = attr("RewardTrackReadyAt", math.huge)
	local pos = trackStand()
	if not (pos and type(ready) == "number" and now() >= ready) then
		return
	end
	local _, _, here = body()
	if not here or (here.Position - pos).Magnitude > TRACK_MAX_WALK then
		first("track too far", here and math.floor((here.Position - pos).Magnitude), "studs; claimed when you are near it")
		return
	end
	-- the walk waits while Follow holds the character; it gets its turn between blocks
	claim("track", function()
		local _, _, root = body()
		if not root then
			return
		end
		local home = root.Position
		say("rewards: walking to the reward track")
		if walkTo(pos, TRACK_REACH, alive) then
			local step0 = attr("RewardTrackStep", 0)
			R.Rewards.ClaimTrack:FireServer()
			task.wait(1)
			if attr("RewardTrackStep", 0) ~= step0 or attr("RewardTrackReadyAt", 0) ~= ready then
				stats.claims += 1
				say("rewards: reward track claimed")
			else
				local _, _, r = body()
				first("track refused", "at", r and math.floor((r.Position - pos).Magnitude), "studs")
			end
		end
		walkTo(home, 4, alive)
	end)
end)

-- mutations ------------------------------------------------------------------
-- The shop's stock is seeded per rotation (MutationShopStock.For), so what is left to buy is
-- RestockState.Left minus nothing we have to ask for. Buying is cheap and stock-limited, so it spends
-- from the reserve line. Applying costs income x (mult - 1) x minutes (a ~5 minute payback) and is
-- limited by what you hold, so it is not held back for upgrades the way fish levels are: it may take
-- APPLY_SHARE of your cash per apply (measured: the surplus rule left it at -51.8T and idle).
local mutationOn = {}
makeLoop("mutbuy", MUTATION_EVERY, function()
	local rot = M.RSt.Rotation()
	local stock = M.MSS.For(rot)
	for _, m in M.MSC.List do
		local price = M.MSC.GetBuyPrice(m.Name)
		if mutationOn[m.Name] and M.RSt.Left("Mutation", m.Name, stock[m.Name] or 0) > 0 and price <= spendable() then
			local held = M.RSt.Held(m.Name)
			step("mutbuy", "buy " .. m.Name)
			if
				tryBuy("mutation " .. m.Name .. rot, function()
					R.Restock.BuyMutation:FireServer(rot, m.Name)
				end, function()
					return M.RSt.Held(m.Name) > held
				end)
			then
				stats.mutations += 1
				say(("bought mutation %s x%s (%s)"):format(m.Name, m.Multiplier, fmt(price)))
				return -- re-read stock and cash next pass
			end
		end
	end
end)

makeLoop("mutapply", MUTATION_EVERY, function()
	local budget = spendable() * APPLY_SHARE
	local best, bestName, gain, cost
	for name, n in pairs(M.RSt.AllHeld()) do
		if type(n) == "number" and n > 0 then
			for _, f in tank().Instances do
				if M.MSC.CanApply(f, name) then
					local a, b = M.MSC.Preview(f, name)
					local c = M.MSC.GetApplyPrice(name, f)
					if a and b and b > a and c <= budget and (not gain or b - a > gain) then
						best, bestName, gain, cost = f, name, b - a, c
					end
				end
			end
		end
	end
	if not best then
		local kinds, fish = 0, #tank().Instances
		for _, n in pairs(M.RSt.AllHeld()) do
			kinds += (type(n) == "number" and n > 0) and 1 or 0
		end
		first("apply idle", "held kinds", kinds, "tank fish", fish, "budget", fmt(budget))
		return
	end
	local held = M.RSt.Held(bestName)
	step("mutapply", "apply " .. bestName)
	if
		tryBuy("apply " .. bestName .. best.Uid, function()
			R.Restock.ApplyMutation:FireServer(bestName, best.Uid)
		end, function()
			return M.RSt.Held(bestName) < held
		end)
	then
		stats.mutations += 1
		say(("applied %s: +%s/s (%s)"):format(bestName, fmt(gain), fmt(cost)))
	end
end)

-- worlds ---------------------------------------------------------------------
-- Travel is accepted only while the server sees you on this world's portal Pad (it answers with
-- World.Prompt first; probed there and back, 0.3s per hop). Paying for a locked world is the same
-- Travel on the pad, unproven: the next world needed 5 rebirths when this was written. A paid world
-- opens for good only after its obby is crossed, which stays yours to do.
local prompted = 0
table.insert(conns, R.World.Prompt.OnClientEvent:Connect(function()
	prompted += 1
end))

local function worldState(w)
	if w.Order == 1 then
		return M.WC.Open
	end
	return attr(M.WC.StateAttributePrefix .. w.Key, nil)
end

local function portalPad()
	local here = workspace:FindFirstChild("Worlds") and workspace.Worlds:FindFirstChild(attr("World", ""))
	for _, p in game:GetService("CollectionService"):GetTagged(M.WC.PortalTag) do
		if not here or p:IsDescendantOf(here) then
			local pad = p:FindFirstChild(M.WC.PortalPadName, true)
			if pad and pad:IsA("BasePart") then
				return pad
			end
		end
	end
	return nil
end

-- walk onto the pad, wait for the server's Prompt, Travel; true once World says we arrived
local function portalTo(key, alive)
	local pad = portalPad()
	local _, _, root = body()
	if not (pad and root) then
		return false, "no portal pad in this world"
	end
	if (pad.Position - root.Position).Magnitude > BELT_MAX_WALK then
		return false, ("the portal is %d studs away"):format((pad.Position - root.Position).Magnitude)
	end
	local p0, t0 = prompted, os.clock()
	while alive() and prompted == p0 and os.clock() - t0 < PAD_WAIT do
		local _, hum = body()
		if hum then
			hum:MoveTo(pad.Position)
		end
		task.wait(0.3)
	end
	if prompted == p0 then
		return false, "no prompt from the pad"
	end
	local before = attr(M.WC.StateAttributePrefix .. key, nil)
	R.World.Travel:FireServer(key)
	local t1 = os.clock()
	while os.clock() - t1 < 3 do
		if attr("World", "") == key or attr(M.WC.StateAttributePrefix .. key, nil) ~= before then
			return true
		end
		task.wait(0.1)
	end
	return false, "travel not taken"
end

makeLoop("world", WORLD_EVERY, function(alive)
	local reb, best, nextW = attr("Rebirths", 0), nil, nil
	for _, w in M.WC.Worlds do
		local st = worldState(w)
		if st == M.WC.Open then
			if not best or w.Order > best.Order then
				best = w
			end
		elseif not nextW or w.Order < nextW.Order then
			nextW = w
		end
	end
	local price = nextW and M.WC.PortalPrice(nextW)
	want.world = nextW and worldState(nextW) == nil and reb >= nextW.RebirthGate and price or nil
	if nextW and worldState(nextW) == M.WC.Paid then
		note = ("world: %s is paid, cross its obby (%s) to open it"):format(nextW.DisplayName or nextW.Key, nextW.Obby and nextW.Obby.Title or "?")
		first("world paid", nextW.Key)
	elseif want.world and price <= spendable() then
		claim("world", function()
			step("world", "pay " .. nextW.Key)
			local okPay, why = portalTo(nextW.Key, alive)
			first("world pay " .. nextW.Key, okPay, why, "state now", tostring(worldState(nextW)))
			say(("world: paying for %s (%s): %s"):format(nextW.Key, fmt(price), okPay and "taken" or why))
		end)
		return
	end
	if best and attr("World", "") ~= best.Key then
		claim("world", function()
			step("world", "travel " .. best.Key)
			local okGo, why = portalTo(best.Key, alive)
			say(("world: to %s: %s"):format(best.Key, okGo and "arrived" or why))
		end)
	end
end)

-- autosell: the game's own setting, server-side; restored on unload
local autoSellWas = nil
local function setAutoSell(state)
	if autoSellWas == nil then
		autoSellWas = M.SC.IsOn(player, "AutoSell")
	end
	R.Settings.Set:FireServer("AutoSell", state)
end

-- watchdog -------------------------------------------------------------------
local watching = true
task.spawn(function()
	local lastMin, b0, s0, t0 = os.clock(), 0, 0, 0
	while watching do
		task.wait(5)
		if os.clock() - lastMin >= 60 and (loops.swing.on or loops.follow.on) then
			-- predicted: one block every ConveyorConfig.SpawnInterval (4s) = 15 a minute
			log(("minute: spawned %d broken %d taps %d dps %s"):format(spawned - s0, stats.broken - b0, stats.strikes - t0, fmt(dps())))
			lastMin, b0, s0, t0 = os.clock(), stats.broken, spawned, stats.strikes
		end
		for name, m in pairs(marks) do
			if loops[name] and loops[name].on and os.clock() - m[2] > WATCHDOG then
				warn(("[rescuefish] %s stuck %ds at: %s"):format(name, os.clock() - m[2], m[1]))
				m[2] = os.clock()
			end
		end
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Rescue a Fish", statusBar = true })
if not Window then
	watching = false
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "fish")
local Farm = Tab:AddLeftGroupbox("Belt", "pickaxe")
local Tank = Tab:AddLeftGroupbox("Tank", "fish")
local Up = Tab:AddRightGroupbox("Upgrades", "trending-up")
local Misc = Tab:AddRightGroupbox("Extras", "gift")

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

toggle(Farm, "Swing", "Auto Swing", "Strikes at your swing speed whenever a block is in reach. On its own it swings where you stand", "swing")
toggle(Farm, "Follow", "Follow Best Block", "Walks beside the most valuable block you can still break before it leaves the belt. Turn Auto Swing on too", "follow")

toggle(Tank, "Place", "Auto Place Best", "The game's own Place Best, every few seconds", "place")
toggle(Tank, "Level", "Auto Level Fish", "Levels the cheapest placed fish while cash stays above the reserve", "level")
toggle(Tank, "Hatch", "Auto Hatch Eggs", "Hatches every egg in your tank once its timer is up", "hatch")

local upgradeKeys = {}
for _, u in M.UC.Upgrades do
	upgradeKeys[#upgradeKeys + 1] = u.Key
	upgradeOn[u.Key] = true -- Default does not fire the callback
end
toggle(Up, "Upgrade", "Auto Upgrade Shop", "Buys the cheapest ticked upgrade you can afford above the reserve", "upgrade")
Up:AddDropdown("UpgradeKeys", {
	Text = "Upgrades to buy",
	Values = upgradeKeys,
	Default = upgradeKeys,
	Multi = true,
	Callback = function(picked)
		table.clear(upgradeOn)
		for k in pairs(ticked(picked)) do
			upgradeOn[k] = true
		end
	end,
})
toggle(Up, "Pickaxe", "Auto Buy Pickaxe", "Buys the next pickaxe tier once affordable and unlocked; buying equips it", "pickaxe")
toggle(Up, "Tank", "Auto Tank", "Upgrades the equipped tank, or buys and equips the next one when that is cheaper. Cash only", "tank")
toggle(Up, "Rebirth", "Auto Rebirth", "Rebirths as soon as the cash covers it. Resets your progress", "rebirth")
toggle(Up, "World", "Auto New World", "Walks to the portal pad and travels to your best open world; pays for the next one once its rebirths and cash are met. The obby that opens it is yours to cross", "world")
Up:AddInput("Reserve", {
	Text = "Keep this much cash",
	Default = "0",
	Numeric = true,
	Finished = true,
	Callback = function(text)
		reserve = tonumber(text) or 0
	end,
})

local Mut = Tab:AddLeftGroupbox("Mutations", "sparkles")
local mutationNames = {}
for _, m in M.MSC.List do
	mutationNames[#mutationNames + 1] = m.Name
	mutationOn[m.Name] = true -- Default does not fire the callback
end
toggle(Mut, "MutBuy", "Auto Buy Mutations", "Buys every ticked mutation the shop has in stock this rotation, when you can pay", "mutbuy")
Mut:AddDropdown("MutNames", {
	Text = "Mutations to buy",
	Values = mutationNames,
	Default = mutationNames,
	Multi = true,
	Callback = function(picked)
		table.clear(mutationOn)
		for k in pairs(ticked(picked)) do
			mutationOn[k] = true
		end
	end,
})
toggle(Mut, "MutApply", "Auto Apply Mutations", "Puts each held mutation on the tank fish it raises most, paid from cash above what upgrades are saving for", "mutapply")

toggle(Misc, "Rewards", "Auto Claim Rewards", "Playtime gifts, free offline earnings, and the reward track (walks to its stand when ready)", "rewards")
Misc:AddToggle("AutoSell", {
	Text = "Game's Auto Sell",
	Tooltip = "Flips the game's own Auto Sell setting; your old setting comes back on unload",
	Default = false,
	Callback = function(state)
		pcall(setAutoSell, state)
	end,
})

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
	pcall(Window.SetStatus, Window, {
		{ "Cash", fmt(cash()) },
		{ "Tier", tostring(attr("PickaxeTier", 1)) },
		{ "Broken", stats.broken },
		{ "Taps", stats.strikes },
		{ "Bought", stats.upgrades + stats.pickaxes + stats.tanks + stats.levels + stats.mutations },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("RescueAFish", {})

-- close ----------------------------------------------------------------------
local function stopAll()
	for _, L in pairs(loops) do
		L.set(false)
	end
	watching = false
	if autoSellWas ~= nil then
		pcall(function()
			R.Settings.Set:FireServer("AutoSell", autoSellWas)
		end)
		autoSellWas = nil
	end
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().rescueFishStop = nil
end)

getgenv().rescueFishStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().rescueFishStop = nil
end
