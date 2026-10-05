--[[ Bite for Items -- bite the walls, grab the loot behind them, sell it, buy better bites (124731807130219)

     FARM    : one run = break every wall of the rooms before the target room, hop to the loot in the rooms
               behind them, fill the bag, hop to the Sell stand, sell. Probed: the server only lets you pick
               up in room N once every wall of rooms 1..N-1 is broken (clearing room 3 alone did not open
               room 4, clearing 1-3 did), and walls grow back the moment you sell, so every run clears again.
               The target room is the deepest one whose walls fit the "Wall-breaking time per run" at your current
               strength (a bite hits for your BiteStrength and spills over into the next wall); type a
               number in "Max room" to cap it. Hops are verified and retried (the server reverts about one
               in three), and nothing walks.
     SELL    : "Auto Sell" (on by default). Off = the farm clears and loots only, then waits with a full bag; sell by hand
               (selling resets the walls, so the next run clears again).
     BITE    : fires Bite at the server's cooldown (~7/s) from wherever you stand. Every bite adds the
               equipped bite's strength to BiteStrength, which is also the damage of the next bite.
     BUY     : BuyBite for the best cash bite you can afford (accepted from anywhere, auto-equips), then
               carry space when it is small next to the next bite. Walkspeed is optional (useless: nothing walks).
     REBIRTH : Rebirth the moment the game's own level check passes. Resets your bite -- off by default.
     CLAIM   : daily reward, playtime rewards, offline earnings. Quest Tokens are credited by the server;
               QUEST REWARDS spends them on the Bite / Cash / Speed ladders.

     Not wired (Robux): ClaimOfflineEarnings' "2X" button, Claim All (daily), lucky-block and aura Token items,
     the AutoClick pass (Bite(true)). Not built: Quality machine and relic crafting (server timers unseen, and
     a craft wants ~34 ingredient items while the bag holds 3).

     RightControl opens / closes the panel. Stop: getgenv().biteItemsStop() ]]

-- config ---------------------------------------------------------------------
local BITE_GAP = 0.14 -- between Bite calls. The server's cooldown is ~0.13s: 0.12 landed 5 of 6, 0.06 landed 3 of 6. Raise if bites go missing
local HOP_SETTLE = 0.35 -- after a CFrame hop, before anything is fired: the server must see you there
local HOP_TOL = 8 -- a hop counts as arrived inside this many studs
local HOP_TRIES = 6 -- reverted hops are retried this often (about one in three is undone)
local STAND = 2.5 -- studs in front of a wall's face while biting it (the server's reach is ~5.7 from the face)
local WALL_CONFIRM = 1.5 -- a wall's HP must move inside this or the hop is assumed reverted and redone
local WALL_RETRY = 4 -- re-hops per wall before the run is cut short at the room before it
local PICK_TIMEOUT = 2 -- an item must vanish inside this of pressing it
local PICK_GAP = 0.15 -- between presses
local ITEM_STRIKES = 2 -- an item that did not come after this many tries is skipped for the run
local SELL_CONFIRM = 2.5 -- the bag must empty inside this after SellItems
local SELL_TRIES = 3
local BUDGET_DEFAULT = 45 -- seconds of wall clearing a run may spend. Raise for deeper (richer) rooms, lower for quicker laps
local HOP_COST = 0.55 -- planning only: one hop and its settle
local UPGRADE_EVERY = 2
local UPGRADE_BACKOFF = 15 -- a purchase the server refused is not retried for this long
local CARRY_VS_BITE = 0.5 -- carry space is bought only when it costs under this fraction of the next bite
local CLAIM_EVERY = 15
local QUEST_EVERY = 20
local REBIRTH_EVERY = 3
local STUCK_AFTER = 30 -- the watchdog names the step a loop has sat in this long

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().biteItemsStop then
	getgenv().biteItemsStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[bite]", ...)
end

local seen = {}
local function first(name, ...) -- one console line per unproven branch
	if not seen[name] then
		seen[name] = true
		log(name, ...)
	end
end

-- The panel strip is drained from a Heartbeat, which the engine calls with our own identity.
-- A loop thread that writes to the window directly throws "lacking capability Plugin" after
-- its first task.wait.
local pending, lastSaid = {}, nil
local function say(msg, quiet, slot)
	pending[slot or "now"] = msg
	if not quiet and msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- breadcrumb: the watchdog thread (separate, so a parked farm thread can still be reported)
local mark, markAt = "idle", os.clock()
local function step(s)
	mark, markAt = s, os.clock()
end

-- game -----------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
local ok, BiteConfig, WallConfig, CarryConfig, WalkConfig, WorldPortal, LevelConfig, RebirthBonus, PlaytimeConfig, QuestRewards, CodesConfig =
	pcall(function()
		local S = ReplicatedStorage.Shared
		return require(S.BiteConfig),
			require(S.WallConfig),
			require(S.CarryUpgradeConfig),
			require(S.WalkspeedUpgradeConfig),
			require(S.WorldPortalConfig),
			require(S.LevelConfig),
			require(S.RebirthBonus),
			require(S.PlaytimeRewardConfig),
			require(S.QuestRewardConfig),
			require(S.CodesConfig)
	end)
if not Remotes or not ok then
	warn("[bite] the game's modules did not load:", BiteConfig)
	return
end
local R = {}
for _, name in ipairs({
	"Bite", "SellItems", "BuyBite", "BuyUpgrade", "Rebirth", "AutoPlayRoute", "AutoPlayTeleport", "ClaimDailyReward",
	"ClaimPlaytimeReward", "GetOfflineEarnings", "ClaimOfflineEarnings", "BuyQuestReward", "RedeemCode",
}) do
	R[name] = Remotes:WaitForChild(name, 10)
end
local strengthStat = player:WaitForChild("stats"):WaitForChild("BiteStrength")
local cash = player:WaitForChild("leaderstats"):WaitForChild("Cash")
local rebirths = player.leaderstats:WaitForChild("Rebirths")

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

-- InvokeServer has no timeout, so a handler that never answers parks the thread for good.
local function callTimed(remote, timeout, ...)
	local done, r1, r2 = false, nil, nil
	local args = table.pack(...)
	task.spawn(function()
		local good, a, b = pcall(remote.InvokeServer, remote, table.unpack(args, 1, args.n))
		if good then
			r1, r2 = a, b
		end
		done = true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < timeout do
		task.wait()
	end
	return done, r1, r2
end

-- pure planning: how deep a run can go. hps[i] is the total wall HP of the i-th room of the route; a run
-- to room n has to clear rooms 1..n-1 (the loot behind room n's own walls is open once those are down).
local function clearCost(hp, strength)
	return HOP_COST + math.ceil(hp / strength) * BITE_GAP + (hp > strength and 2 * HOP_COST or 0)
end
local function planTarget(hps, strength, budget, cap)
	local total, best = 0, 1
	for n = 2, math.min(#hps, cap or #hps) do
		total += clearCost(hps[n - 1], strength)
		if total > budget then
			break
		end
		best = n
	end
	return best
end
assert(planTarget({ 1, 5, 15, 100 }, 1000, 10) == 4, "plan: everything fits")
assert(planTarget({ 1, 1e12, 1 }, 10, 5) == 2, "plan: a wall that never fits stops the run before it")
assert(planTarget({ 1, 5, 15, 100 }, 1000, 10, 2) == 2, "plan: the cap holds")
assert(planTarget({ 1 }, 1000, 10) == 1, "plan: one room")

-- state ----------------------------------------------------------------------
local stats = { runs = 0, reverts = 0, items = 0, earned = 0, bought = 0 }
local conns = {}
local farmOn, inRun = false, false

local function root()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

-- A CFrame hop: the server undoes about a third of them, so confirm on where we actually are.
local function hop(pos, alive)
	for _ = 1, HOP_TRIES do
		if alive and not alive() then
			return false
		end
		local r = root()
		if not r then
			return false
		end
		r.CFrame = CFrame.new(pos)
		r.AssemblyLinearVelocity = Vector3.zero
		task.wait(HOP_SETTLE)
		r = root()
		if r and (r.Position - pos).Magnitude < HOP_TOL then
			return true
		end
		stats.reverts += 1
	end
	return false
end

-- bite -----------------------------------------------------------------------
local lastBite = 0
local function biteOnce() -- shared gate, so the Bite toggle and a wall clear never double-fire inside the cooldown
	local now = os.clock()
	if now - lastBite >= BITE_GAP then
		lastBite = now
		pcall(R.Bite.FireServer, R.Bite)
	end
end

local function runner(body) -- toggle setter: one thread per switch-on, a generation counter so off-then-on cannot double up
	local gen, on = 0, false
	return function(state)
		on = state
		gen += 1
		if not state then
			return
		end
		local mine = gen
		task.spawn(function()
			local function alive()
				return on and gen == mine
			end
			body(alive)
		end)
	end
end

local setBite = runner(function(alive)
	while alive() do
		biteOnce()
		task.wait(BITE_GAP)
	end
end)

-- world ----------------------------------------------------------------------
local route -- { start, rooms = { { room, position } } } from the server, the same one the game's AutoPlay walks
local function getRoute()
	if route then
		return route
	end
	local done, r = callTimed(R.AutoPlayRoute, 5)
	if done and type(r) == "table" and r.rooms and #r.rooms > 0 then
		route = r
		first("route", #r.rooms, "rooms from", r.rooms[1].room, "start", r.start)
	end
	return route
end

local function wallAttr(room, k)
	local got, name = pcall(WallConfig.attributeName, room, k)
	return got and name or ("R%dWall%dHP"):format(room, k)
end
local function wallHP(room, k)
	return player:GetAttribute(wallAttr(room, k)) or 0
end
local function roomHP(room)
	local hp = 0
	for k = 1, 8 do
		hp += wallHP(room, k)
	end
	return hp
end

local function roomWalls(room)
	local folder = workspace:FindFirstChild("Rooms")
	folder = folder and folder:FindFirstChild("Room" .. room)
	folder = folder and folder:FindFirstChild("Walls")
	local list = {}
	if folder then
		for _, w in ipairs(folder:GetChildren()) do
			local k = tonumber(w.Name:match("^Wall(%d+)$"))
			if k and w:IsA("BasePart") then
				list[#list + 1] = { k = k, part = w }
			end
		end
	end
	table.sort(list, function(a, b)
		return a.k < b.k
	end)
	return list
end

local function corridorDir() -- the way the rooms run, flat: -Z in world 1
	local r = route
	if r and #r.rooms >= 2 then
		local d = r.rooms[2].position - r.rooms[1].position
		d = Vector3.new(d.X, 0, d.Z)
		if d.Magnitude > 1 then
			return d.Unit
		end
	end
	return Vector3.new(0, 0, -1)
end

local function standPoint(wall)
	local thick = math.min(wall.Size.X, wall.Size.Z)
	local p = wall.Position - corridorDir() * (thick / 2 + STAND)
	return Vector3.new(p.X, wall.Position.Y - wall.Size.Y / 2 + 3, p.Z)
end

-- Break every wall of one room. false = cut short (reverted hops, respawn, switched off).
local function clearRoom(room, alive)
	for _, w in ipairs(roomWalls(room)) do
		local tries = 0
		while alive() and wallHP(room, w.k) > 0 do
			tries += 1
			if tries > WALL_RETRY then
				first("wall-stuck", "room", room, "wall", w.k, "hp", wallHP(room, w.k))
				return false
			end
			step(("clear room %d wall %d"):format(room, w.k))
			if not hop(standPoint(w.part), alive) then
				return false
			end
			local last, lastT = wallHP(room, w.k), os.clock()
			while alive() and wallHP(room, w.k) > 0 do
				biteOnce()
				task.wait(BITE_GAP)
				local hp = wallHP(room, w.k)
				if hp < last then
					last, lastT = hp, os.clock()
				elseif os.clock() - lastT > WALL_CONFIRM then
					break -- nothing landed: the hop was undone after we checked
				end
			end
		end
		if not alive() then
			return false
		end
	end
	return true
end

-- loot -----------------------------------------------------------------------
local function roomOf(inst)
	local n = inst
	while n and n ~= workspace do
		local num = n.Name:match("^Room(%d+)$")
		if num then
			return tonumber(num)
		end
		n = n.Parent
	end
	return nil
end

local function carried() -- loot Tools in hand and bag, stacks counted
	local total = 0
	for _, holder in ipairs({ player.Backpack, player.Character }) do
		if holder then
			for _, t in ipairs(holder:GetChildren()) do
				if t:IsA("Tool") and t:GetAttribute("Rarity") ~= nil then
					total += math.max(1, t:GetAttribute("Count") or 1)
				end
			end
		end
	end
	return total
end

local function capacity()
	return player:GetAttribute("CarrySpace") or 3
end

-- items open to us in rooms first..last, deepest room first (deeper pays more)
local function lootList(first_, last, skip)
	local list = {}
	for _, it in ipairs(CollectionService:GetTagged("FloatingItem")) do
		local owner = it:GetAttribute("OwnerUserId")
		local room = it.Parent and roomOf(it)
		if room and room >= first_ and room <= last and (owner == nil or owner == player.UserId) and not skip[it] then
			list[#list + 1] = { inst = it, room = room }
		end
	end
	table.sort(list, function(a, b)
		return a.room > b.room
	end)
	return list
end

local function grab(item, alive)
	local prompt = item:FindFirstChildWhichIsA("ProximityPrompt", true)
	if not prompt then
		return nil -- not streamed in
	end
	step("grab " .. item.Name .. " / hop")
	if not hop(item:GetPivot().Position + Vector3.new(0, 3, 3), alive) then
		return false
	end
	step("grab " .. item.Name .. " / press")
	local t0 = os.clock()
	while alive() and item.Parent and os.clock() - t0 < PICK_TIMEOUT do
		pcall(fireproximityprompt, prompt)
		task.wait(PICK_GAP)
	end
	return item.Parent == nil
end

-- The stand is in the lobby, so it streams out while the farm is deep in the rooms: remember where it was,
-- and when we have never seen it, take the game's own trip back to the lobby so it streams in.
local sellPos
local function scanSellStand()
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.ActionText == "Sell Items" then
			local part = d:FindFirstAncestorWhichIsA("BasePart")
			if part then
				sellPos = part.Position + Vector3.new(0, 3, 5)
				return true
			end
		end
	end
	return false
end
local function sellSpot()
	if not sellPos and not scanSellStand() then
		step("sell / back to the lobby to find the stand")
		pcall(R.AutoPlayTeleport.FireServer, R.AutoPlayTeleport)
		for _ = 1, 8 do
			task.wait(0.5)
			if scanSellStand() then
				break
			end
		end
	end
	return sellPos
end

local function sell(alive)
	local spot = sellSpot()
	if not spot then
		say("no Sell stand found")
		return false
	end
	step("sell / hop")
	if not hop(spot, alive) then
		return false
	end
	local c0 = cash.Value
	for try = 1, SELL_TRIES do
		local r = root()
		if try > 1 and not (r and (r.Position - spot).Magnitude < HOP_TOL) then
			first("sell-rehop", "was", r and (r.Position - spot).Magnitude)
			if not hop(spot, alive) then
				return false
			end
		end
		step("sell / fire")
		pcall(R.SellItems.FireServer, R.SellItems)
		local t0 = os.clock()
		while alive() and carried() > 0 and os.clock() - t0 < SELL_CONFIRM do
			task.wait(0.1)
		end
		if carried() == 0 then
			break
		end
	end
	task.wait(0.2)
	local got = cash.Value - c0
	stats.earned += math.max(0, got)
	if carried() == 0 then
		first("first-sale", "+" .. fmt(math.max(0, got)))
		return true
	end
	local r = root()
	log("sell failed: still carrying", carried(), "distance to stand", r and math.floor((r.Position - spot).Magnitude))
	return false
end

-- farm -----------------------------------------------------------------------
local maxRoom, budget = 0, BUDGET_DEFAULT
local sellOn = true -- Auto Sell: off = clear and loot only, the bag is kept (Default = true does not fire the callback, so it is set here)

local function farmRun(alive)
	local rt = getRoute()
	if not rt then
		say("no route from the server, retrying")
		task.wait(2)
		return
	end
	if not sellOn and carried() >= capacity() then
		say(("bag full (%d/%d), Auto Sell is off"):format(carried(), capacity()))
		task.wait(1) -- nothing more can be picked up and nothing sells: do not clear walls for loot we cannot take
		return
	end
	local rooms = rt.rooms
	local hps = {}
	for i, r in ipairs(rooms) do
		hps[i] = roomHP(r.room)
	end
	local target = planTarget(hps, math.max(1, strengthStat.Value), budget, maxRoom > 0 and maxRoom or nil)
	say(("run: clear %d, loot room %d (str %s)"):format(target - 1, rooms[target].room, fmt(strengthStat.Value)))
	local reach = 1
	local t0, picked = os.clock(), 0
	-- A bite spills into the next walls, and standing on the lobby side of room 1 undoes the other rooms, so
	-- a room can be found regrown after the pass: check every room we count on and go round again (3 passes).
	for pass = 1, 3 do
		reach = 1
		for i = 1, target - 1 do
			if not alive() then
				return
			end
			if not clearRoom(rooms[i].room, alive) then
				break
			end
			reach = i + 1
		end
		local bad = {}
		for i = 1, reach - 1 do
			if roomHP(rooms[i].room) > 0 then
				bad[#bad + 1] = i
			end
		end
		if #bad == 0 then
			break
		end
		log(("pass %d: route rooms %s regrew, clearing again"):format(pass, table.concat(bad, ",")))
		if pass == 3 then
			reach = bad[1] -- give up on the rooms that will not stay down: loot only what is open
		end
	end
	if not alive() then
		return
	end
	local lastRoom = rooms[reach].room
	local tClear = os.clock()
	local skip, strikes = {}, {}
	local rescan = 0
	while alive() and carried() < capacity() do
		local list = lootList(rooms[1].room, lastRoom, skip)
		if #list == 0 then
			rescan += 1
			if rescan > 3 then
				break -- nothing left that we can reach; sell what we hold
			end
			task.wait(1)
		else
			local item = list[1].inst
			local got = grab(item, alive)
			if got then
				stats.items += 1
				picked += 1
			elseif got == false then
				strikes[item] = (strikes[item] or 0) + 1
				if strikes[item] >= ITEM_STRIKES then
					skip[item] = true
					first("item-skipped", item.Name, "room", list[1].room)
				end
			else
				skip[item] = true
			end
		end
	end
	local tLoot = os.clock()
	if alive() and carried() > 0 and not sellOn then
		say(("looted %d, bag %d/%d, Auto Sell is off"):format(picked, carried(), capacity()))
		task.wait(1)
	elseif alive() and carried() > 0 then
		local c0 = stats.earned
		if not sell(alive) then
			task.wait(1) -- a failed sell must not spin: the bag is still full and the next run would just come back here
			return
		end
		stats.runs += 1
		log(("run %d: reached room %d, clear %.0fs, loot %.0fs (%d items), sell %.0fs, +%s, hops lost %d"):format(
			stats.runs, lastRoom, tClear - t0, tLoot - tClear, picked, os.clock() - tLoot, fmt(stats.earned - c0), stats.reverts
		))
	elseif alive() then
		task.wait(1)
	end
end

local setFarm = runner(function(alive)
	farmOn = true
	while alive() do
		inRun = true
		local good, err = pcall(farmRun, alive)
		inRun = false
		if not good then
			warn("[bite] run errored:", err)
			task.wait(1)
		end
		task.wait(0.1)
	end
	farmOn, inRun = false, false
	step("idle")
end)

-- buy ------------------------------------------------------------------------
local refused = {} -- name -> retry-after
local function ownedSet()
	local set = {}
	for name in tostring(player:GetAttribute("OwnedBites") or ""):gmatch("[^,]+") do
		set[name] = true
	end
	return set
end

local strengthByName = {}
for _, b in ipairs(BiteConfig.BITES) do
	strengthByName[b.name] = b.strength
end

local walkOn = false
local function upgradePass()
	local world = WorldPortal.unlockedWorldFromAttributes(player)
	local owned = ownedSet()
	local bestOwned = 0
	local list = BiteConfig.forWorld(world)
	for _, b in ipairs(list) do
		strengthByName[b.name] = b.strength
	end
	for name in pairs(owned) do
		bestOwned = math.max(bestOwned, strengthByName[name] or 0)
	end
	local now = os.clock()
	local money = cash.Value
	local pick, nextPrice
	for _, b in ipairs(list) do
		-- cash bites only: a bite with no cashPrice or a limited / special one is a Robux route
		if b.cashPrice and not b.special and not b.limitedId and not owned[b.name] and b.strength > bestOwned then
			if not nextPrice or b.cashPrice < nextPrice then
				nextPrice = b.cashPrice
			end
			if b.cashPrice <= money and (refused[b.name] or 0) <= now and (not pick or b.strength > pick.strength) then
				pick = b
			end
		end
	end
	if pick then
		step("buy bite " .. pick.name)
		local done, res = callTimed(R.BuyBite, 5, pick.name)
		if done and res then
			stats.bought += 1
			say(("bought %s (+%s per bite)"):format(pick.name, fmt(pick.strength)))
			return
		end
		refused[pick.name] = now + UPGRADE_BACKOFF
		first("buy-refused", pick.name, tostring(res))
		return
	end
	local carryCost = CarryConfig.nextCost(player:GetAttribute("CarrySpace") or CarryConfig.BASE_CAPACITY, world)
	if carryCost and carryCost <= money and (refused.carry or 0) <= now and (not nextPrice or carryCost <= nextPrice * CARRY_VS_BITE) then
		step("buy carry")
		local done, res = callTimed(R.BuyUpgrade, 5, "CarrySpace")
		if done and res then
			stats.bought += 1
			say("carry space +1")
		else
			refused.carry = now + UPGRADE_BACKOFF
		end
		return
	end
	if walkOn then
		local cost = WalkConfig.nextCost(player:GetAttribute("WalkSpeed") or WalkConfig.BASE_WALKSPEED)
		if cost and cost <= money and (refused.walk or 0) <= now then
			local done, res = callTimed(R.BuyUpgrade, 5, "Walkspeed")
			if not (done and res) then
				refused.walk = now + UPGRADE_BACKOFF
			end
		end
	end
end

local setBuy = runner(function(alive)
	while alive() do
		local good, err = pcall(upgradePass)
		if not good then
			warn("[bite] buy pass errored:", err)
		end
		task.wait(UPGRADE_EVERY)
	end
end)

-- rebirth --------------------------------------------------------------------
local setRebirth = runner(function(alive)
	while alive() do
		task.wait(REBIRTH_EVERY)
		if alive() and not inRun then
			local level = LevelConfig.getProgress(strengthStat.Value)
			if level >= RebirthBonus.requiredLevel(rebirths.Value) then
				local before = rebirths.Value
				step("rebirth")
				local done = callTimed(R.Rebirth, 8)
				task.wait(0.5)
				say(done and rebirths.Value > before and ("rebirthed (%d)"):format(rebirths.Value) or "rebirth refused", false, "now")
			end
		end
	end
end)

-- claim ----------------------------------------------------------------------
local function claimPass(state)
	if player:GetAttribute("DailyRewardReady") == true then
		local done, res = callTimed(R.ClaimDailyReward, 5)
		if done then
			first("daily", tostring(res))
		end
	end
	local mask = player:GetAttribute("PlaytimeClaimed") or 0
	local secs = player:GetAttribute("PlaytimeSeconds") or 0
	for i, rw in ipairs(PlaytimeConfig.REWARDS) do
		if bit32.band(bit32.rshift(mask, i - 1), 1) == 0 and secs >= rw.seconds then
			local _, res = callTimed(R.ClaimPlaytimeReward, 5, i)
			first("playtime", i, tostring(res))
			break -- the mask moves, so re-read it next pass
		end
	end
	if not state.offline then
		state.offline = true
		local done, owed = callTimed(R.GetOfflineEarnings, 5)
		if done and type(owed) == "table" and ((owed.bite or 0) > 0 or (owed.cash or 0) > 0) then
			callTimed(R.ClaimOfflineEarnings, 5) -- no argument: the "2X" button is a Robux product
			first("offline", "bite", owed.bite, "cash", owed.cash)
		end
	end
end

local setClaim = runner(function(alive)
	local state = {}
	while alive() do
		local good, err = pcall(claimPass, state)
		if not good then
			warn("[bite] claim pass errored:", err)
		end
		task.wait(CLAIM_EVERY)
	end
end)

local function questPass()
	local tokens = player:GetAttribute("Tokens") or 0
	local pick
	for _, ladder in ipairs(QuestRewards.LADDERS) do
		for _, rung in ipairs(ladder) do
			if rung.mode ~= "set" then
				break -- lucky blocks and auras are not ours to spend on
			end
			if player:GetAttribute("QuestRewardOwned_" .. rung.id) ~= true then
				local gate = rung.requires == nil or player:GetAttribute("QuestRewardOwned_" .. rung.requires) == true
				if gate and rung.cost <= tokens and (not pick or rung.cost < pick.cost) then
					pick = rung
				end
				break -- the ladder's next rung is the only one buyable
			end
		end
	end
	if pick then
		local done, res = callTimed(R.BuyQuestReward, 5, pick.id)
		say(("quest reward %s: %s"):format(pick.id, tostring(done and res)))
	end
end

local setQuest = runner(function(alive)
	while alive() do
		local good, err = pcall(questPass)
		if not good then
			warn("[bite] quest pass errored:", err)
		end
		task.wait(QUEST_EVERY)
	end
end)

local function redeemCodes()
	task.spawn(function()
		for code, info in pairs(CodesConfig.CODES) do
			if not (type(info) == "table" and info.expired) then
				local done, res, label = callTimed(R.RedeemCode, 5, tostring(code))
				log("code", code, done and tostring(res) or "no answer", label or "")
				task.wait(1.2) -- "TooFast" otherwise
			end
		end
	end)
end

-- watchdog -------------------------------------------------------------------
local dead = false
task.spawn(function()
	while not dead do
		task.wait(5)
		if (farmOn or inRun) and os.clock() - markAt > STUCK_AFTER then
			warn(("[bite] stuck %ds at: %s"):format(os.clock() - markAt, mark))
			markAt = os.clock()
		end
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Bite for Items", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "swords")
local Farm = Tab:AddLeftGroupbox("Farm", "swords")
local Spend = Tab:AddLeftGroupbox("Spend", "coins")
local Free = Tab:AddRightGroupbox("Free stuff", "gift")

Farm:AddToggle("Farm", {
	Text = "Auto Farm (clear + loot)",
	Tooltip = "Breaks the walls of every room before the target room and hops to the loot behind them until the bag is full. With Auto Sell on it then sells at the stand (walls grow back when you sell, so each run clears again). Nothing walks",
	Default = false,
	Callback = function(state)
		setFarm(state)
		if not state then
			say("farm off")
		end
	end,
})
Farm:AddToggle("Sell", {
	Text = "Auto Sell",
	Tooltip = "On: the farm sells the bag at the stand after each loot trip. Off: it clears and loots only, then waits with a full bag so you can sell by hand (selling resets the walls)",
	Default = true,
	Callback = function(state)
		sellOn = state
		say(state and "Auto Sell on" or "Auto Sell off: farm will clear and loot only")
	end,
})
Farm:AddToggle("Bite", {
	Text = "Auto Bite",
	Tooltip = "Bites at the server's cooldown from wherever you stand. Every bite adds your equipped bite's strength to BiteStrength. Costs nothing and runs fine alongside Farm",
	Default = false,
	Callback = setBite,
})
Farm:AddInput("MaxRoom", {
	Text = "Deepest room allowed (0 = auto)",
	Tooltip = "Hard cap on how deep a run goes, counted along the route (1 = loot room 1 only). Leave at 0 and the time limit below decides",
	Default = "0",
	Numeric = true,
	Finished = true,
	Callback = function(text)
		maxRoom = math.max(0, math.floor(tonumber(text) or 0))
	end,
})
Farm:AddInput("Budget", {
	Text = "Wall-breaking time per run (sec)",
	Tooltip = "Each run has to break every wall before the loot room. Auto aims for the deepest room whose walls it expects to break in this many seconds at your current strength. Higher = deeper rooms, richer loot, longer runs. Real runs take about 1.4x this",
	Default = tostring(BUDGET_DEFAULT),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		budget = math.max(5, tonumber(text) or BUDGET_DEFAULT)
	end,
})
local planLine = Farm:AddLabel("-", true)

Spend:AddToggle("Buy", {
	Text = "Auto Buy bites + carry",
	Tooltip = "BuyBite for the best cash bite you can afford (it auto-equips), then +1 carry space when that costs under half of the next bite. Robux bites and limited ones are never touched",
	Default = false,
	Callback = setBuy,
})
Spend:AddToggle("Walk", {
	Text = "Also buy Walkspeed",
	Tooltip = "Nothing here walks (hops), so this only matters if you run around yourself",
	Default = false,
	Callback = function(state)
		walkOn = state
	end,
})
Spend:AddToggle("Rebirth", {
	Text = "Auto Rebirth",
	Tooltip = "Rebirths as soon as the game's own level check passes, between runs. A rebirth resets your bite: leave it off if you are not sure",
	Default = false,
	Callback = setRebirth,
})

Free:AddToggle("Claim", {
	Text = "Auto Claim rewards",
	Tooltip = "Daily reward, playtime rewards, and offline earnings once. Never the Robux 2X or Claim All buttons",
	Default = false,
	Callback = setClaim,
})
Free:AddToggle("Quest", {
	Text = "Auto Quest rewards",
	Tooltip = "Quests pay Tokens by themselves. This spends them on the Bite, Cash and Speed multiplier ladders, cheapest first. Lucky blocks and auras are skipped",
	Default = false,
	Callback = setQuest,
})
Free:AddButton({
	Text = "Redeem codes",
	Tooltip = "Tries every code in the game's list that is not marked expired. Results land in the F9 console",
	Func = redeemCodes,
})

local note, nextStrip = "idle", 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	if pending.now then
		note, pending.now = pending.now, nil
	end
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	local plan = "-"
	if route then
		local hps = {}
		for i, r in ipairs(route.rooms) do
			hps[i] = roomHP(r.room)
		end
		plan = ("room %d"):format(route.rooms[planTarget(hps, math.max(1, strengthStat.Value), budget, maxRoom > 0 and maxRoom or nil)].room)
	end
	pcall(planLine.SetText, planLine, "Next run reaches: " .. plan)
	pcall(Window.SetStatus, Window, { -- ponytail: thrown "lacking capability Plugin" when loaded through the bridge; silence, not fix
		{ "Cash", fmt(cash.Value) },
		{ "Strength", fmt(strengthStat.Value) },
		{ "Bite", tostring(player:GetAttribute("EquippedBite") or "-") },
		{ "Bag", ("%d/%d"):format(carried(), capacity()) },
		{ "Runs", stats.runs },
		{ "Sold", fmt(stats.earned) },
		{ "Hops lost", stats.reverts },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("BiteForItems", {})

-- Hops flash the "Gameplay Paused" banner every few seconds. This hides the banner only: Player.GameplayPaused
-- still goes true, so every wait above stays. pcall'd because older clients error on the index.
pcall(function()
	game:GetService("GuiService"):SetGameplayPausedNotificationEnabled(false)
end)

local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- close ----------------------------------------------------------------------
local function stopAll()
	setFarm(false)
	setBite(false)
	setBuy(false)
	setRebirth(false)
	setClaim(false)
	setQuest(false)
	pcall(function()
		game:GetService("GuiService"):SetGameplayPausedNotificationEnabled(true)
	end)
	dead = true
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().biteItemsStop = nil
end)

getgenv().biteItemsStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().biteItemsStop = nil
end
