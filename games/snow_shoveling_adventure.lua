--[[ Snow Shoveling Adventure -- grab the best loot your Strength can dig, sell, buy shovels and auras, train (101893542756730)

     FARM   : loot is public and on timers (~2 min), spread over all 13 zones, and the server knows where every piece
              is (SnowNetwork Snapshot + the Loot Reveal / Remove events). A piece can be picked up once the ONE snow
              cell over it is dug in your own snow (else "LootBuried"), so the farm never clears a section: it walks
              straight at the best piece in the highest zone your Strength can dig, the server digs the cells in
              front of you as you push (one swing per tool interval), and the moment the game turns the piece's
              prompt on it holds it (0.75s). Probed: zone01 3s, zone02 2-3s a piece. The wall between sections is
              a client-side part (PersonalTraversalAssist); the farm turns its collision off while it walks.
              Zone reach = the zone's RecommendedStrength x "Zone push"; a zone where you stop making headway is
              parked until your Strength has grown by PARK_GROW.
     SELL   : bag full -> SnowNetwork "Base" (the game's own free return-home teleport) -> walk to the Sell Loot
              stand -> hold its prompt (opens a sell session) -> SellAll -> Close. Probed: 3 items, 885 cash.
     SHOVEL : ToolNetwork Buy for the strongest shovel (StrengthPerDig) you can afford, better than the one you
              hold. No range check (bought from the sell stand); the server equips it.
     AURA   : AuraNetwork Buy for the strongest aura you can afford, better than the equipped one. The call's
              shape is accepted (answered NotEnoughCash); not yet bought live.
     TRAIN  : TrainingNetwork Train, the tap. +StrengthPerDig a tap; the server keeps about 10 a second (a burst
              of 10, then OnCooldown), so the loop fires back to back and ignores OnCooldown. The seq must rise:
              after this has run, the game's own tap counter is behind it and your hand taps are refused until
              you rejoin.

     UPGRADE: UpgradeNetwork Purchase for the ticked rows (Capacity = bag slot, Mobility = walk speed 18 -> 48,
              Agility, Range, Magnet). SHOVEL, AURA and UPGRADE share one spend loop that buys the cheapest
              affordable candidate each pass.
     REBIRTH: RebirthNetwork Rebirth when the server's own `ready` is true (level 25 + 25 per rebirth). Resets
              Strength; +50% Strength and +20% cash per rebirth.

     Everything moves by walking. The only teleport is the game's own "Base".
     Probed and dead (do not re-probe):
       grab from afar / dig from afar   no dig remote exists (the server digs by your position, reach 3.2); the
                                        pickup is refused until the cell over the loot is dug, and range-checked
       teleport as a speed lever        single hops of 5/10/20 studs stick, 40 is reverted (no kick); chained hops
                                        at 20-32 studs/s were reverted 3 of 4 times. Walk; Mobility is the speed lever
     Not wired (Robux): the AutoClicker pass, Sell x2 credits, bag tiers, aura/shovel Robux rows, the Strength / Bag
     upgrade rows (closed), the rebirth skip.
     Not wired (not asked): quests, crafting, spin wheel, daily rewards.

     RightControl opens / closes the panel. Stop: getgenv().snowShovelStop() ]]

-- config ---------------------------------------------------------------------
local ARRIVE = 2.5 -- studs (flat) from a loot that count as standing on it
local PICK_RANGE = 8 -- hold the prompt from this close (the prompt reaches 9)
local STALL_SECS = 8 -- no headway toward a loot for this long = the snow in front is too hard: park the zone
local STALL_GAIN = 2 -- studs of headway that reset the stall clock
local PARK_GROW = 1.5 -- a parked zone opens again once Strength is this many times what it was
local TARGET_SECS = 60 -- give up on one loot after this long
local TTL_SLACK = 4 -- skip a loot that will expire before we can walk there plus this
local ZONE_SECS = 3 -- seconds a zone step costs in the target score, on top of the walk
local HOLD_SLACK = 0.2 -- held past the prompt's HoldDuration
local SELL_GAP = 1.1 -- the sell remote answers OnCooldown to calls closer than ~1s
local SPEND_EVERY = 3 -- shovel / aura / upgrade check beat when nothing was bought
local REBIRTH_EVERY = 3 -- rebirth readiness check beat
local UPGRADES = { "Capacity", "Mobility", "Agility", "Range", "Magnet" } -- the cash rows; Strength and Bag are Robux-only
local RESEED_EVERY = 30 -- re-read the whole loot list this often, in case an event was missed
local STUCK_AFTER = 40 -- the watchdog names the step the farm has sat in this long

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")
local player = Players.LocalPlayer

if getgenv and getgenv().snowShovelStop then
	getgenv().snowShovelStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[snow]", ...)
end

local seen = {}
local function first(name, ...) -- one console line per unproven branch
	if not seen[name] then
		seen[name] = true
		log(name, ...)
	end
end

-- The panel strip is drained from a Heartbeat; a loop thread writing to the window throws after its first wait.
local pending, lastSaid = {}, nil
local function say(msg)
	pending.now = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

local mark, markAt = "idle", os.clock()
local function step(s)
	mark, markAt = s, os.clock()
end

-- game -----------------------------------------------------------------------
local function net(name)
	local f = ReplicatedStorage:WaitForChild(name .. "Network", 15)
	return f and f:WaitForChild("Request", 10), f and f:FindFirstChild("Changed") -- FindFirstChild: .Changed is the Instance signal
end
local SnowR, SnowChanged = net("Snow")
local SellR = net("Sell")
local ToolR = net("Tool")
local AuraR = net("Aura")
local TrainR = net("Training")
local UpgradeR = net("Upgrade")
local RebirthR = net("Rebirth")
local okz, Zones = pcall(function()
	return require(ReplicatedStorage.Shared.Config.ZoneProgressionConfig)
end)
if not (SnowR and SellR and ToolR and AuraR and TrainR and UpgradeR and RebirthR and SnowChanged) or not okz then
	warn("[snow] the game's remotes or zone config did not load:", Zones)
	return
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

local function strength()
	return tonumber(player:GetAttribute("PublicStrength")) or 0 -- the numeric twin of the formatted leaderstat
end

-- an InvokeServer that cannot park the caller: nil on timeout
local function call(remote, args, timeout)
	local done, res = false, nil
	task.spawn(function()
		local ok, r = pcall(remote.InvokeServer, remote, args)
		done, res = true, ok and r or nil
	end)
	local t = os.clock()
	while not done and os.clock() - t < (timeout or 6) do
		task.wait(0.05)
	end
	return res
end

local function codeOf(r)
	return type(r) == "table" and (type(r.result) == "table" and r.result.code or r.code) or "no reply"
end

local function character()
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	local root = ch and ch:FindFirstChild("HumanoidRootPart")
	if hum and root and hum.Health > 0 then
		return hum, root
	end
	return nil, nil
end

local function flat(a, b)
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- loot mirror ----------------------------------------------------------------
-- Seeded from Snapshot, kept current off the same Loot events the game's own controller listens to.
local loot = {} -- [id] = item { id, name, value, zoneId, position, expiresAt, ... }
local world = "world01"
local lobbyPos = nil
local claimed = {} -- [id] = winner userId, from the Remove event
local seq = getgenv().snowSeq or { train = 0, base = 0 } -- kept across re-runs: the server wants these to rise
getgenv().snowSeq = seq

local function seed()
	local r = call(SnowR, { action = "Snapshot" })
	if type(r) ~= "table" or type(r.loot) ~= "table" then
		return false
	end
	table.clear(loot)
	for _, it in ipairs(r.loot.items or {}) do
		loot[it.id] = it
	end
	world = r.world or world
	if type(r.lobby) == "table" and typeof(r.lobby.CFrame) == "CFrame" then
		lobbyPos = r.lobby.CFrame.Position
	end
	return true
end

local function onSnow(p)
	if type(p) ~= "table" or p.kind ~= "Loot" or type(p.event) ~= "table" then
		return
	end
	local e = p.event
	if e.kind == "Reveal" and type(e.item) == "table" then
		loot[e.item.id] = e.item
	elseif e.kind == "Remove" then
		loot[e.id] = nil
		if e.reason == "Claimed" then
			claimed[e.id] = e.winner
		end
	elseif e.kind == "Timer" and loot[e.id] and e.expiresAt then
		loot[e.id].expiresAt = e.expiresAt
	end
end

-- zones ----------------------------------------------------------------------
local zoneRank, zoneRec = {}, {}
local function readZones()
	table.clear(zoneRank)
	local route = Zones.Routes and Zones.Routes[world] or Zones.Order
	for i, z in ipairs(route or {}) do
		zoneRank[z] = i
		zoneRec[z] = Zones.Zones[z] and Zones.Zones[z].RecommendedStrength or math.huge
	end
end

local push = 1
local parkedZone = {} -- [zoneId] = Strength it was parked at
-- the highest zone rank your Strength reaches, under any parked zone
local function reach(str)
	local best = 1
	for z, i in pairs(zoneRank) do
		local p = parkedZone[z]
		if p and str >= p * PARK_GROW then
			parkedZone[z] = nil
			p = nil
		end
		if zoneRec[z] <= str * push and not p and i > best then
			best = i
		end
	end
	for z, i in pairs(zoneRank) do -- a parked zone caps everything above it too
		if parkedZone[z] and i <= best then
			best = i - 1
		end
	end
	return math.max(best, 1)
end
do
	local saved = { zr = zoneRank, rec = zoneRec }
	zoneRank, zoneRec = { a = 1, b = 2, c = 3 }, { a = 10, b = 100, c = 1000 }
	assert(reach(150) == 2 and reach(5000) == 3 and reach(1) == 1, "reach")
	parkedZone.b = 150
	assert(reach(200) == 1, "a parked zone caps the ones above")
	assert(reach(300) == 2 and parkedZone.b == nil, "a parked zone reopens at PARK_GROW")
	zoneRank, zoneRec = saved.zr, saved.rec
end

local skip = setmetatable({}, { __mode = "k" }) -- item table -> retry-after, for one we gave up on

-- the best piece to go for: value per estimated second, inside reach, not expiring before we get there
local function pickTarget(root, cap, ws)
	local now = workspace:GetServerTimeNow()
	local best, bestScore
	for _, it in pairs(loot) do
		local rank = zoneRank[it.zoneId]
		if rank and rank <= cap and typeof(it.position) == "Vector3" and (skip[it] or 0) < os.clock() then
			local secs = flat(root.Position, it.position) / ws + rank * ZONE_SECS
			local ttl = (it.expiresAt or math.huge) - now
			if ttl > secs + TTL_SLACK then
				local score = (tonumber(it.value) or 0) / secs
				if not bestScore or score > bestScore then
					best, bestScore = it, score
				end
			end
		end
	end
	return best
end

-- the game's own prompt state: it turns a piece's prompt on once the cell over it is dug in our snow
local function promptOf(id)
	local f = workspace:FindFirstChild("PublicLoot")
	local m = f and f:FindFirstChild(id)
	return m and m:FindFirstChild("ClaimLoot")
end

local function hold(prompt)
	local ok = pcall(function()
		prompt:InputHoldBegin()
		task.wait(prompt.HoldDuration + HOLD_SLACK)
	end)
	pcall(function()
		prompt:InputHoldEnd() -- every exit: a leaked begin keeps the prompt held
	end)
	return ok
end

-- state ----------------------------------------------------------------------
local dead = false
local farmOn, sellOn, shovelOn, auraOn, trainOn = false, false, false, false, false
local gens = { farm = 0, train = 0, spend = 0, rebirth = 0 }
local conns = {}
local stats = {
	picked = 0,
	sold = 0,
	cash = 0,
	shovels = 0,
	auras = 0,
	upgrades = 0,
	rebirths = 0,
	taps = 0,
	parks = 0,
	startAt = os.clock(),
}
local bag, cap = 0, 3
local target = nil

local function readBag()
	local r = call(SellR, { action = "Snapshot" })
	local s = type(r) == "table" and r.state
	if type(s) == "table" then
		bag, cap = tonumber(s.bag) or bag, tonumber(s.capacity) or cap
		return s
	end
	return nil
end

-- the wall between sections is the client's own part; off while the farm walks
local wallOff = false
table.insert(conns, RunService.Heartbeat:Connect(function()
	if wallOff then
		local f = workspace:FindFirstChild("PersonalSnowPresentation")
		local w = f and f:FindFirstChild("PersonalTraversalAssist")
		if w and w.CanCollide then
			w.CanCollide = false
		end
	end
end))

-- sell -----------------------------------------------------------------------
local standPos, standPrompt = nil, nil
local function findStand()
	if standPrompt and standPrompt:IsDescendantOf(workspace) then
		return standPrompt
	end
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "SellLootInteraction" then
			standPrompt = d
			local part = d:FindFirstAncestorWhichIsA("BasePart")
			standPos = d.Parent:IsA("Attachment") and d.Parent.WorldPosition or (part and part.Position)
			return d
		end
	end
	return nil
end

local function walkNear(pos, within, alive, timeout)
	local t0 = os.clock()
	while alive() and os.clock() - t0 < timeout do
		local hum, root = character()
		if not hum then
			return false
		end
		if flat(root.Position, pos) <= within then
			return true
		end
		hum:MoveTo(pos)
		task.wait(0.25)
	end
	return false
end

local function goHome()
	seq.base += 1
	local r = call(SnowR, { action = "Base", seq = seq.base + 1000 })
	if codeOf(r) == "Success" then
		task.wait(1.5) -- the server moves us; the probe landed in ~1.5s
		return true
	end
	first("Base refused, walking home", codeOf(r))
	return false
end

local function sellNow(alive)
	step("sell / home")
	say(("bag %d/%d, selling"):format(bag, cap))
	wallOff = true
	if not goHome() and lobbyPos then
		walkNear(lobbyPos, 6, alive, 90)
	end
	step("sell / walk to stand")
	local prompt = findStand()
	if not prompt or not standPos then
		say("no Sell Loot stand found")
		return false
	end
	if not walkNear(standPos, prompt.MaxActivationDistance - 3, alive, 30) then
		say("could not reach the sell stand")
		return false
	end
	step("sell / open")
	hold(prompt)
	task.wait(0.6)
	local s = readBag()
	if not (s and s.session) then
		first("sell stand opened no session", s and s.status)
		return false
	end
	task.wait(SELL_GAP)
	step("sell / SellAll")
	local r = call(SellR, { action = "SellAll", token = s.session, seq = (s.sequence or 0) + 1, revision = s.revision })
	local res = type(r) == "table" and r.result
	if codeOf(r) == "Success" and type(res) == "table" then
		stats.sold += tonumber(res.sold) or 0
		stats.cash += tonumber(res.cash) or 0
		say(("sold %d for %s"):format(res.sold or 0, fmt(res.cash)))
	else
		log("SellAll refused", codeOf(r))
	end
	task.wait(SELL_GAP)
	local s2 = readBag()
	if s2 then
		call(SellR, { action = "Close", token = s.session, seq = (s2.sequence or 0) + 1, revision = s2.revision })
	end
	return codeOf(r) == "Success"
end

-- farm -----------------------------------------------------------------------
-- one piece: walk at it until its prompt opens, hold it, confirm on the Remove event naming us
local function fetch(it, alive)
	local t0, bestD, bestAt = os.clock(), math.huge, os.clock()
	step("loot " .. tostring(it.name) .. " / walk")
	while alive() and os.clock() - t0 < TARGET_SECS do
		if not loot[it.id] then
			return claimed[it.id] == player.UserId and "got" or "gone"
		end
		local hum, root = character()
		if not hum then
			return "no character"
		end
		local d = flat(root.Position, it.position)
		local prompt = promptOf(it.id)
		if prompt and prompt.Enabled and (root.Position - it.position).Magnitude <= PICK_RANGE then
			step("loot " .. tostring(it.name) .. " / hold")
			hold(prompt)
			local t1 = os.clock()
			while loot[it.id] and os.clock() - t1 < 1.5 do
				task.wait(0.05)
			end
			if claimed[it.id] == player.UserId then
				return "got"
			end
			if not loot[it.id] then
				return "gone"
			end
		end
		if d < bestD - STALL_GAIN then
			bestD, bestAt = d, os.clock()
		elseif d > ARRIVE and os.clock() - bestAt > STALL_SECS then
			return "stalled"
		end
		hum:MoveTo(it.position)
		task.wait(0.15)
	end
	return alive() and "timeout" or "stopped"
end

local function farmLoop(mine)
	local function alive()
		return farmOn and gens.farm == mine and not dead
	end
	local lastSeed = 0
	while alive() do
		local ok, err = pcall(function()
			if os.clock() - lastSeed > RESEED_EVERY then
				step("farm / seed")
				if seed() then
					lastSeed = os.clock()
					readZones()
				end
			end
			step("farm / bag")
			readBag()
			if bag >= cap then
				if sellOn then
					sellNow(alive)
				else
					say(("bag full (%d/%d): turn on Auto Sell"):format(bag, cap))
					task.wait(3)
				end
				return
			end
			local hum, root = character()
			if not hum then
				task.wait(1)
				return
			end
			local str = strength()
			local capRank = reach(str)
			local it = pickTarget(root, capRank, math.max(hum.WalkSpeed, 8))
			target = it
			if not it then
				step("farm / idle")
				say("no loot in reach yet, waiting")
				task.wait(1)
				return
			end
			wallOff = true
			say(("going for %s (%s, %s) in %s"):format(it.name, it.rarity or "?", fmt(it.value), it.zoneId))
			local res = fetch(it, alive)
			if res == "got" then
				stats.picked += 1
				bag += 1
				say(("picked %s (%s)"):format(it.name, fmt(it.value)))
			elseif res == "stalled" then
				parkedZone[it.zoneId] = str
				stats.parks += 1
				log(("parked %s at Strength %s: no headway for %ds at %s"):format(
					it.zoneId, fmt(str), STALL_SECS, tostring(character() and select(2, character()).Position)
				))
				skip[it] = os.clock() + 30
			elseif res ~= "stopped" then
				skip[it] = os.clock() + 15
				first("loot " .. res, it.name, it.zoneId)
			end
		end)
		if not ok then
			first("farm error " .. tostring(err), err)
			task.wait(2)
		end
		task.wait()
	end
	wallOff = false
	target = nil
end

local function setFarm(on)
	farmOn = on
	gens.farm += 1
	if on then
		task.spawn(farmLoop, gens.farm)
	else
		wallOff = false
		local hum, root = character()
		if hum then
			hum:MoveTo(root.Position) -- stop the last walk where it stands
		end
	end
end

-- train ----------------------------------------------------------------------
local function trainLoop(mine)
	local bumps = 0
	while trainOn and gens.train == mine and not dead do
		seq.train += 1
		local r = call(TrainR, { action = "Train", seq = seq.train }, 3)
		local c = codeOf(r)
		if c == "Success" then
			stats.taps += 1
			bumps = 0
			local s = r.result.seq
			if type(s) == "number" and s > seq.train then
				seq.train = s
			end
		elseif c == "ReplayRejected" or c == "InvalidRequest" then
			-- ReplayRejected: our seq is at or below the server's last (the game's own taps, an earlier run). InvalidRequest:
			-- too far ahead (probed: +100000 refused, +800 accepted). Walk toward the window from whichever side.
			bumps += 1
			seq.train += c == "ReplayRejected" and 100 or -50
			if bumps > 200 then
				say("Train keeps answering " .. c .. ", stopped")
				return
			end
		elseif c ~= "OnCooldown" then
			first("train " .. c, c)
			task.wait(0.5)
		end
		task.wait() -- the server's ~10/s cap paces it; OnCooldown is the cheap answer
	end
end

local function setTrain(on)
	trainOn = on
	gens.train += 1
	if on then
		task.spawn(trainLoop, gens.train)
	end
end

-- spend ----------------------------------------------------------------------
-- Every buy is the same call on its own network: { action, id, seq = state.sequence + 1, revision = state.revision }.
local upgradesOn = false
local upgradePick = {} -- [upgrade id] = true, from the dropdown
for _, id in ipairs(UPGRADES) do
	upgradePick[id] = true -- the dropdown's Default ticks them all, and Default fires no callback
end

local function snapshot(remote)
	local r = call(remote, { action = "Snapshot" })
	local s = type(r) == "table" and r.state
	return type(s) == "table" and s or nil
end

-- the strongest affordable shovel / aura that beats the equipped one, as a candidate
local function bestRow(remote, s, listKey, statKey, label)
	local have, best = 0, nil
	for _, row in ipairs(s[listKey] or {}) do
		if row.Equipped then
			have = math.max(have, tonumber(row[statKey]) or 0)
		end
	end
	for _, row in ipairs(s[listKey] or {}) do
		local v = tonumber(row[statKey]) or 0
		local buyable = row.Affordable and not row.Owned and not row.Locked and not row.LockReason
			and not row.LimitedQuest and tonumber(row.Price) and row.Price > 0
		if buyable and v > have and (not best or v > (tonumber(best[statKey]) or 0)) then
			best = row
		end
	end
	return best and {
		label = label,
		name = best.DisplayName,
		price = best.Price,
		remote = remote,
		state = s,
		args = { action = "Buy", id = best.Id },
	}
end

-- One buy per pass, the cheapest of everything ticked: upgrade prices climb by band, so the next shovel gets its turn
-- once the cheap levels are bought, instead of being starved by them forever.
local function spendOnce()
	local cands = {}
	if shovelOn then
		local s = snapshot(ToolR)
		table.insert(cands, s and bestRow(ToolR, s, "tools", "StrengthPerDig", "shovel"))
	end
	if auraOn then
		local s = snapshot(AuraR)
		table.insert(cands, s and bestRow(AuraR, s, "auras", "StrengthPercent", "aura"))
	end
	if upgradesOn and next(upgradePick) then
		local s = snapshot(UpgradeR)
		for _, row in ipairs(s and s.rows or {}) do
			-- closed = the Robux-only rows (Strength, Bag); premium likewise. Never those.
			if upgradePick[row.id] and row.affordable and not row.closed and not row.premium and not row.locked and tonumber(row.cost) then
				table.insert(cands, {
					label = "upgrade",
					name = ("%s %d"):format(row.id, (row.level or 0) + 1),
					price = row.cost,
					remote = UpgradeR,
					state = s,
					args = { action = "Purchase", id = row.id },
				})
			end
		end
	end
	local pick
	for _, c in pairs(cands) do
		if c and (not pick or c.price < pick.price) then
			pick = c
		end
	end
	if not pick then
		return false
	end
	step("buy " .. pick.label .. " " .. pick.name)
	pick.args.seq = (pick.state.sequence or 0) + 1
	pick.args.revision = pick.state.revision
	task.wait(0.6) -- the snapshot just now counts against the same 2-a-second budget
	local res = call(pick.remote, pick.args)
	if codeOf(res) == "Success" then
		stats[pick.label .. "s"] += 1
		say(("bought %s %s for %s"):format(pick.label, pick.name, fmt(pick.price)))
		return true
	end
	first(pick.label .. " buy refused " .. codeOf(res), pick.name, codeOf(res))
	return false
end

local function spendLoop(mine)
	while (shovelOn or auraOn or upgradesOn) and gens.spend == mine and not dead do
		local ok, bought = pcall(spendOnce)
		if not ok then
			first("spend error " .. tostring(bought), bought)
		end
		task.wait(ok and bought and 0.5 or SPEND_EVERY) -- straight round after a buy: there may be more to buy
	end
end

local function setSpend()
	gens.spend += 1
	task.spawn(spendLoop, gens.spend)
end

-- rebirth: the moment the server's own `ready` says so (level 25 + 25 per rebirth; resets Strength, +50% Strength gain)
local rebirthOn = false
local function rebirthLoop(mine)
	while rebirthOn and gens.rebirth == mine and not dead do
		local ok, err = pcall(function()
			local s = snapshot(RebirthR)
			if s and s.ready then
				task.wait(1.1) -- RequestsPerSecond 1
				step("rebirth")
				local before = s.rebirths or 0
				local res = call(RebirthR, { action = "Rebirth", seq = (s.sequence or 0) + 1, revision = s.revision })
				if codeOf(res) == "Success" then
					stats.rebirths += 1
					table.clear(parkedZone) -- parks were measured against the old Strength
					say(("rebirthed: %d -> %d"):format(before, before + 1))
				else
					first("rebirth refused " .. codeOf(res), "level", s.level, "need", s.requiredLevel)
				end
			end
		end)
		if not ok then
			first("rebirth error " .. tostring(err), err)
		end
		task.wait(REBIRTH_EVERY)
	end
end

local function setRebirth(on)
	rebirthOn = on
	gens.rebirth += 1
	if on then
		task.spawn(rebirthLoop, gens.rebirth)
	end
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Snow Shoveling Adventure", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "snowflake")
local Farm = Tab:AddLeftGroupbox("Farm", "shovel")
local Spend = Tab:AddRightGroupbox("Spend and train", "coins")

Farm:AddToggle("Farm", {
	Text = "Auto Farm loot",
	Tooltip = "Walks straight at the best loot in the highest zone your Strength can dig, digs only the cell over it, picks it up. Walks only",
	Default = false,
	Callback = function(state)
		pcall(setFarm, state)
		if not state then
			say("farm off")
		end
	end,
})
Farm:AddToggle("Sell", {
	Text = "Auto Sell when the bag is full",
	Tooltip = "The game's own Base teleport home, walk to the Sell Loot stand, Sell All. Only while Auto Farm runs",
	Default = false,
	Callback = function(state)
		sellOn = state
	end,
})
Farm:AddInput("Push", {
	Text = "Zone push (x Strength)",
	Tooltip = "Goes for zones whose recommended Strength is up to this many times yours. Raise to try deeper zones; a zone where it stops making headway is parked by itself",
	Default = "1",
	Numeric = true,
	Finished = true,
	Callback = function(text)
		local n = tonumber(text)
		if n and n > 0 then
			push = n
			table.clear(parkedZone)
		end
	end,
})
local farmLine = Farm:AddLabel("-", true)

Spend:AddToggle("Shovel", {
	Text = "Auto buy better shovel",
	Tooltip = "Buys the strongest shovel (Strength per dig) you can afford that beats the one you hold. Equipped by the game",
	Default = false,
	Callback = function(state)
		shovelOn = state
		pcall(setSpend)
	end,
})
Spend:AddToggle("Aura", {
	Text = "Auto buy better aura",
	Tooltip = "Buys the strongest aura (Strength %) you can afford that beats the equipped one. Never the Robux ones",
	Default = false,
	Callback = function(state)
		auraOn = state
		pcall(setSpend)
	end,
})
Spend:AddToggle("Upgrades", {
	Text = "Auto buy upgrades",
	Tooltip = "Buys the upgrades ticked below with cash. Each pass buys the cheapest affordable thing across shovel, aura and upgrades, so none starves the others. Never the Robux rows",
	Default = false,
	Callback = function(state)
		upgradesOn = state
		pcall(setSpend)
	end,
})
Spend:AddDropdown("UpgradeList", {
	Text = "Upgrades to buy",
	Tooltip = "Capacity = +1 bag slot. Mobility = walk speed (18 -> 48). Agility = faster swings. Range = dig reach. Magnet = pickup range (costs billions)",
	Values = UPGRADES,
	Default = UPGRADES,
	Multi = true,
	Callback = function(picked)
		table.clear(upgradePick)
		for k, v in pairs(picked) do
			if v == true then
				upgradePick[k] = true
			elseif type(k) == "number" then
				upgradePick[v] = true
			end
		end
	end,
})
Spend:AddToggle("Rebirth", {
	Text = "Auto Rebirth",
	Tooltip = "Rebirths the moment the game says you are ready (level 25, +25 a rebirth). Resets your Strength; each rebirth is +50% Strength and +20% cash",
	Default = false,
	Callback = function(state)
		pcall(setRebirth, state)
	end,
})
Spend:AddToggle("Train", {
	Text = "Auto Train (tap)",
	Tooltip = "Taps for Strength at the server's cap (~10 a second), anywhere, alongside the farm. Your own hand taps are refused until a rejoin afterwards",
	Default = false,
	Callback = function(state)
		pcall(setTrain, state)
	end,
})

table.insert(conns, SnowChanged.OnClientEvent:Connect(onSnow))

local note, nextStrip = "idle", 0
local lastStr, lastAt, rate = strength(), os.clock(), 0
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
		rate = (strength() - lastStr) / (now - lastAt)
		lastStr, lastAt = strength(), now
		if farmOn or trainOn then
			log(("rate: Strength +%s/s, picked %d, sold %d for %s, taps %d, reach %d"):format(
				fmt(rate), stats.picked, stats.sold, fmt(stats.cash), stats.taps, reach(strength())
			))
		end
	end
	local mins = math.max((now - stats.startAt) / 60, 1 / 60)
	pcall(farmLine.SetText, farmLine, ("reach zone %d, target %s, %d parked"):format(
		reach(strength()), target and (target.name .. " " .. fmt(target.value)) or "-", stats.parks
	))
	pcall(Window.SetStatus, Window, {
		{ "Strength", fmt(strength()) },
		{ "Str/s", fmt(rate) },
		{ "Bag", ("%d/%d"):format(bag, cap) },
		{ "Sold", fmt(stats.cash) },
		{ "Cash/min", fmt(stats.cash / mins) },
		{ "Rebirths", stats.rebirths },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("SnowShoveling", {})

table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

task.spawn(function() -- watchdog: a parked farm thread cannot report itself
	while not dead do
		task.wait(5)
		if farmOn and os.clock() - markAt > STUCK_AFTER then
			warn(("[snow] stuck %ds at: %s"):format(os.clock() - markAt, mark))
			markAt = os.clock()
		end
	end
end)

-- close ----------------------------------------------------------------------
local function stopAll()
	farmOn, sellOn, shovelOn, auraOn, trainOn, upgradesOn, rebirthOn = false, false, false, false, false, false, false
	for k in pairs(gens) do
		gens[k] += 1
	end
	wallOff = false
	dead = true
end

Library:OnUnload(function()
	stopAll()
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
	getgenv().snowShovelStop = nil
end)

getgenv().snowShovelStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().snowShovelStop = nil
end
