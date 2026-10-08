--[[ Sword Loot -- clear stages, loot, forge, sell, buy weapons and upgrades, tap, rebirth, claim (93239606899307)

     FARM   : the sword is the server's: stand inside a stage's LevelArea and the game's own StageController asks the
              server to spawn it, the sword engages anything within 45 studs and pulls you onto it. So the farm only
              hops: lobby -> stage (RunMaxClear + 1) -> wait for RunMaxClear to pass it -> next stage, in legs of
              HOP_LEG studs (110 held in the lobby, the server never moved us back). A cleared stage respawns only on a
              server sweep every ~31s after its 30s timer (30-62s), so a trip never turns back: it goes as deep as it
              clears and banks there. A fight that drops you under FLEE_HP runs home (a death throws the carry away)
              and parks that stage until your Level has grown by PARK_LEVELS or PARK_SECS pass; the next trip waits
              in the lobby until HEAL_TO.
     LOOT   : DropPickup(uid) for every drop in workspace.DropsClient near the stage, after a hop next to it. The
              server range-checks it (14 studs accepted, 20 refused). The carry is TripCarry / TripCap; once full,
              only drops that beat the worst carried piece (the game's own beatsWorst) are picked, and the server
              swaps them in.
     TRAVEL : StageTeleport(n) from the lobby's teleport station sets RunMaxClear = n and puts you past stage n
              (n in 4, 8, 13, 18, ...; "TooFar" away from the station). A stage past RunMaxClear + 1 never spawns,
              even when asked (StageSpawnRequest(5) at RunMaxClear 0: nothing), so this is the only skip.
     SWAP   : off = bank the moment the carry is full; on = keep clearing and swap (above).
     BANK   : the last stage you reach -> StageReturnTown, the game's own free trip home, which banks the carry
              (also mid-fight). Then forge, then sell, in that order.
     FORGE  : ForgeCraft { tab = "Spirit", mats } at the anvil (NotAtForge from 46 studs, so it hops there), the
              materials chosen by the game's own AutoFill plan, repeated while 4 materials are left. Gear over
              GEAR_SELL_AT is sold (never the equipped or locked pieces).
     SELL   : SellMaterial { all = true }, from the lobby (accepted 59 studs from the stand).
     WEAPON : ShopBuy(Weapon, id) for the best shop weapon you can afford that beats the equipped one (the server
              equips it). Position-free.
     UPGRADE: UpgradeBuy(key, true), the game's Max button, cheapest affordable ticked upgrade first. Weapon and
              upgrades share one spend pass, cheapest first.
     REBIRTH: PlayerRebirth once Level >= 25 x (rebirths + 1). Resets Level only; coins, weapons and gear stay.
     TAP    : TrainManualClick at TAP_RATE. The server keeps 14/s and drops a whole burst at 20/s. A tap pays nothing
              while you stand in a training zone.
     ZONE   : TrainZoneUpdate(zone) for the best zone your rebirths unlock. Pays 17 studs off the pad, pays 0 while
              you are out in a stage. With Tap on too, both are sampled for SAMPLE_SECS and the better one runs:
              taps 170k/s vs zone x2 42k/s at rebirth 3; tap 32.9B/s vs zone x6 32.6B/s at rebirth 8.
     CLAIM  : index (IndexClaimGear "all" per tab, IndexClaimLevel, IndexClaimReward per material milestone),
              rewards (PlaytimeClaim "all", ClaimDailyAward, OfflineRewardClaim), InvEquipBest, CompanionTeam "Best".
     SKILLS : SetSkillSlot(slot, id) for your strongest unlocked skills: Skills config SumRate x (1 + Forge
              GradeDamageBonus[your grade of it]). Slot 3 only with the SkillSlot3 gamepass.

     KICK   : the server kicks (267, "Abnormal behaviour detected") for more than 10 different message kinds in 5s
              (Tuning.Net.DistinctMessageBurstThreshold). Hit once, right after a bank; every call now goes through
              gate(), at most DISTINCT_MAX kinds per DISTINCT_WINDOW. Keep it when adding a feature.

     Probed and dead (do not re-probe):
       DropPickup from afar      refused at 20-23 studs, accepted at 8 and 14
       ForgeCraft from afar      "NotAtForge" from 46 studs
       taps above ~15/s          20/s and 30/s bursts were dropped whole; 14/s all paid
       taps inside a zone        0 paid while TrainZoneUpdate(3) was set
     Not probed: StageTeleport fast travel (4, 8, 13, ...), loot swaps when full (LootSwapped), Weapon/Armor forge
     tabs (Weapon needs the last shop weapon and a coin fee).
     Not wired (Robux): SkipRebirth, gamepass training zones (7, 9, 10, 11), Robux weapon rows, the SellAnywhere perk.
     Not wired (dev only): every AdminCommand / SkillLabCommand ("givecoins", "nocd", ...).

     RightControl opens / closes the panel. Stop: getgenv().swordLootStop() ]]

-- config ---------------------------------------------------------------------
local HOP_LEG = 100 -- studs per teleport leg (110 held in a probe; lower it if you get moved back)
local LEG_GAP = 0.12 -- between legs of one hop
local CLEAR_SECS = 25 -- a stage that spawned but is not cleared in this long is too strong for you
local SPAWN_SECS = 70 -- a cleared stage respawns 30-62s later (a server sweep every ~31s); wait this long for it
local FLEE_HP = 0.55 -- below this share of your health, run home mid-fight: a death throws the whole carry away (a boss hit took 40% -> 3% in one go)
local HEAL_TO = 0.8 -- leave the lobby only above this share of your health (regen is ~1%/s); else the next fight flees at once
local FAST_MIN = 2 -- fast travel lands at least this many stages below the deepest one you clear, so the trip has fights
local PARK_LEVELS = 15 -- a parked stage is tried again once your Level has grown by this
local PARK_SECS = 180 -- ...or after this long, whichever comes first
local AREA_WAIT = 4 -- seconds to wait for a stage's LevelArea to stream in after hopping near it
local DROP_LAND = 1.6 -- after a clear, wait this long for the drops to land before picking up
local DROP_REACH = 95 -- drops within this many studs of the stage centre belong to it
local PICK_OFFSET = 2 -- hop this close to a drop (the server accepts 14)
local PICK_CONFIRM = 0.6 -- a pickup must remove the drop inside this
local RETURN_WAIT = 4 -- the trip home must land inside this
local TAP_RATE = 14 -- taps a second; the server dropped every tap of a 20/s burst
local SAMPLE_SECS = 4 -- tap vs zone measurement, each
local RESAMPLE_SECS = 300 -- re-measure tap vs zone this often (and after every rebirth)
local ZONE_REFIRE = 10 -- re-send the zone this often (a respawn or the game's own pad check can reset it)
local ECON_EVERY = 3 -- weapon / upgrade / rebirth check beat
local CLAIM_EVERY = 30 -- index / equip-best / team-best beat
local REWARD_EVERY = 60 -- playtime / daily / offline beat
local FORGE_MAX = 25 -- forges per bank, at most
local GEAR_SELL_AT = 130 -- sell spare gear past this many pieces (the cap is 150)
local STUCK_AFTER = 60 -- the watchdog names the step the farm has sat in this long
-- Tuning.Net.DistinctMessageBurstThreshold = 10 in DistinctMessageWindow = 5s: past that the server kicks (267,
-- "Abnormal behaviour detected", hit right after a bank fired forge + sell + rebirth + upgrade + index + rewards).
-- Our own calls get at most DISTINCT_MAX kinds per DISTINCT_WINDOW, leaving the rest for the game's own client.
local DISTINCT_MAX = 5 -- taps and pickups hold two of these nearly always
local DISTINCT_WINDOW = 6
local UPGRADES = { "Bag", "Power", "Luck", "Magnet" }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")
local player = Players.LocalPlayer

if getgenv and getgenv().swordLootStop then
	getgenv().swordLootStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[sword]", ...)
end

local seen = {}
local function first(name, ...) -- one console line per unproven branch
	if not seen[name] then
		seen[name] = true
		log(name, ...)
	end
end

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
local okm, mods = pcall(function()
	local Shared = ReplicatedStorage:WaitForChild("Shared", 15)
	return {
		Net = require(Shared.Net.Net),
		Msg = require(Shared.Net.Protocol).Msg,
		Tuning = require(Shared.Config.Tuning),
		Weapons = require(Shared.Config.Weapons),
		Upgrades = require(Shared.Config.Upgrades),
		IndexBonus = require(Shared.Config.IndexBonus),
		Inventory = require(Shared.Util.Inventory),
		Materials = require(Shared.Config.Materials),
		Skills = require(Shared.Config.Skills),
		Forge = require(Shared.Config.Forge),
		Perks = require(Shared.Util.Perks),
		ClientData = require(player:WaitForChild("PlayerScripts"):WaitForChild("Client"):WaitForChild("ClientData", 15)),
	}
end)
if not okm then
	warn("[sword] the game's modules did not load:", mods)
	return
end
local Net, Msg, Tuning, Weapons, Upgrades, Inventory, ClientData =
	mods.Net, mods.Msg, mods.Tuning, mods.Weapons, mods.Upgrades, mods.Inventory, mods.ClientData
local WEAPON_KIND = 7 -- Enums.ItemType.Weapon

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
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

local function data()
	return ClientData.Get() or {}
end
local function attr(name)
	return tonumber(player:GetAttribute(name)) or 0
end
local function lifetime()
	local r = data().Records
	return type(r) == "table" and tonumber(r.LifetimePower) or 0
end

-- the distinct-kinds budget: wait until message `id` fits in the window. A kind already sent in the window is free.
local sentAt = {} -- [message id] = last os.clock() we sent it
local function kinds(now)
	local n = 0
	for id, t in pairs(sentAt) do
		if now - t > DISTINCT_WINDOW then
			sentAt[id] = nil
		else
			n += 1
		end
	end
	return n
end
local function gate(id)
	while true do
		local now = os.clock()
		if (sentAt[id] and now - sentAt[id] <= DISTINCT_WINDOW) or kinds(now) < DISTINCT_MAX then
			sentAt[id] = now -- no yield between the check and the set, so two threads cannot both take the last slot
			return
		end
		task.wait(0.1)
	end
end
do
	local saved = sentAt
	sentAt = {}
	for i = 1, DISTINCT_MAX do
		sentAt[i] = os.clock()
	end
	assert(kinds(os.clock()) == DISTINCT_MAX, "kinds counts the window")
	sentAt[1] = os.clock() - DISTINCT_WINDOW - 1
	assert(kinds(os.clock()) == DISTINCT_MAX - 1 and sentAt[1] == nil, "an old kind leaves the window")
	sentAt = saved
end

-- an InvokeServer that cannot park the caller: nil on timeout
local function call(timeout, ...)
	gate((...))
	local args = table.pack(...)
	local done, res = false, nil
	task.spawn(function()
		local ok, r = pcall(Net.InvokeServer, table.unpack(args, 1, args.n))
		done, res = true, ok and r or nil
	end)
	local t = os.clock()
	while not done and os.clock() - t < timeout do
		task.wait(0.05)
	end
	return res
end
local function fire(...)
	gate((...))
	pcall(Net.FireServer, ...)
end
local function errOf(r)
	return type(r) == "table" and (r.ok and "ok" or tostring(r.err)) or "no reply"
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

-- hop in legs of HOP_LEG; true once we stand within `tol` of pos, nil with no character
local function hop(pos, tol, alive)
	local _, root = character()
	if not root then
		return nil
	end
	local from = root.Position
	local d = (pos - from).Magnitude
	local legs = math.max(1, math.ceil(d / HOP_LEG))
	for i = 1, legs do
		if alive and not alive() then
			return false
		end
		_, root = character()
		if not root then
			return nil
		end
		root.AssemblyLinearVelocity = Vector3.zero
		root.CFrame = CFrame.new(from:Lerp(pos, i / legs))
		if i < legs then
			task.wait(LEG_GAP)
		end
	end
	task.wait(0.05)
	_, root = character()
	return root and (root.Position - pos).Magnitude <= (tol or 6) or nil
end

-- world ----------------------------------------------------------------------
local function stagesFolder()
	local map = workspace:FindFirstChild("Map")
	return map and map:FindFirstChild("Stages")
end

local areaCache = {} -- [stage] = { centre, size }: cached once seen, streaming drops the part later
local function stageArea(s)
	local c = areaCache[s]
	if c then
		return c
	end
	local f = stagesFolder()
	local m = f and f:FindFirstChild(tostring(s))
	local a = m and (m:FindFirstChild("LevelArea") or m:FindFirstChild("BattleArea"))
	if a and a:IsA("BasePart") then
		c = { centre = a.Position, size = a.Size }
		areaCache[s] = c
	end
	return c
end

local function winPos(s)
	local f = stagesFolder()
	local m = f and f:FindFirstChild(tostring(s))
	local w = m and m:FindFirstChild("WinArea")
	local p = w and w:GetPivot().Position
	return p and p.Magnitude > 1 and p or nil
end

-- where to stand in a stage: its area's centre at floor height
local function standIn(s, alive)
	local a = stageArea(s)
	if not a then
		local near = winPos(s - 1) or winPos(s)
		if not near then
			return nil
		end
		step(("stage %d / stream"):format(s))
		hop(near + Vector3.new(0, 4, 0), 10, alive)
		pcall(function()
			player:RequestStreamAroundAsync(near, AREA_WAIT)
		end)
		local t = os.clock()
		while not a and os.clock() - t < AREA_WAIT do
			task.wait(0.2)
			a = stageArea(s)
		end
		if not a then
			return nil
		end
	end
	return Vector3.new(a.centre.X, a.centre.Y - a.size.Y / 2 + 4, a.centre.Z)
end

-- cached once seen: right after the trip home the lobby has not streamed in yet ("no forge anvil found")
local anvilAt
local function anvilPos()
	if anvilAt then
		return anvilAt
	end
	local map = workspace:FindFirstChild("Map")
	local lobby = map and map:FindFirstChild("Lobby")
	local forge = lobby and lobby:FindFirstChild("Forge")
	local prompt = forge and forge:FindFirstChildWhichIsA("ProximityPrompt", true)
	local part = prompt and prompt:FindFirstAncestorWhichIsA("BasePart")
	anvilAt = part and part.Position
	return anvilAt
end
anvilPos()

local function inLobby()
	return attr("RunMaxClear") == 0 and attr("InChallenge") == 0
end

-- state ----------------------------------------------------------------------
local dead = false
local on = {
	farm = false,
	loot = false,
	sell = false,
	forge = false,
	weapon = false,
	upgrades = false,
	rebirth = false,
	tap = false,
	zone = false,
	index = false,
	rewards = false,
	equip = false,
	team = false,
	skills = false,
	swap = false,
	travel = false,
}
local gens = { farm = 0, train = 0, econ = 0, loot = 0 }
local conns = {}
local maxStage = 35
local upgradePick = {}
for _, k in ipairs(UPGRADES) do
	upgradePick[k] = true -- the dropdown's Default ticks them all, and Default fires no callback
end
local stats = {
	clears = 0,
	picked = 0,
	banks = 0,
	sold = 0,
	coins = 0,
	forged = 0,
	weapons = 0,
	upgrades = 0,
	rebirths = 0,
	claims = 0,
	startAt = os.clock(),
}
local park = {} -- [stage] = { level, at }
local stageNow = 0
local trainMode = "-" -- what the train loop is running: "tap" / "zone"

local function capStage()
	local cap = maxStage
	local lvl = data().Level or 0
	for s, p in pairs(park) do
		if lvl >= p.level + PARK_LEVELS or os.clock() - p.at > PARK_SECS then
			park[s] = nil
		elseif s <= cap then
			cap = s - 1
		end
	end
	return cap
end
do
	local saved = park
	park = { [5] = { level = 1e9, at = os.clock() } }
	assert(capStage() == 4, "a parked stage caps the farm below it")
	park = saved
end

-- bank: forge, then sell ----------------------------------------------------
-- the game's own AutoFill plan (ForgeWindow.planWithMain): a main material plus fillers, 4 in all
local function forgePlan()
	local entries = Inventory.MaterialEntries(data())
	local MIN, TYPES = 4, 4
	for i = 1, #entries do
		local main = entries[i]
		if not main.locked then
			local c = math.min(main.count, MIN)
			local plan = { [tostring(main.id)] = c }
			local need, kinds = MIN - c, 1
			for j, e in ipairs(entries) do
				if need <= 0 or kinds >= TYPES then
					break
				end
				if j ~= i and not e.locked then
					local k = math.min(need, e.count, c)
					if k > 0 then
						plan[tostring(e.id)] = k
						need -= k
						kinds += 1
					end
				end
			end
			if need <= 0 then
				return plan
			end
		end
	end
	return nil
end

local function sellGear()
	local d = data()
	if Inventory.GearCount(d) < GEAR_SELL_AT then
		return
	end
	local keep = {}
	for _, v in pairs(type(d.Equipment) == "table" and d.Equipment or {}) do
		keep[v] = true
	end
	local uids = {}
	for uid, g in pairs(type(d.Gear) == "table" and d.Gear or {}) do
		if not keep[uid] and not (type(g) == "table" and g.locked) then
			table.insert(uids, uid)
		end
	end
	if #uids > 0 then
		local r = call(6, Msg.InvSellGear, uids)
		say(("sold %d spare gear: %s"):format(#uids, errOf(r)))
	end
end

local function forgeAll(alive)
	if not forgePlan() then
		return
	end
	local pos = anvilPos()
	local t = os.clock()
	while not pos and alive() and os.clock() - t < AREA_WAIT do
		task.wait(0.25)
		pos = anvilPos()
	end
	if not pos then
		first("no forge anvil found")
		return
	end
	step("bank / forge hop")
	if not hop(pos + Vector3.new(0, 3, 3), 8, alive) then
		first("could not reach the anvil")
		return
	end
	task.wait(0.3)
	local n = 0
	while alive() and n < FORGE_MAX do
		local plan = forgePlan()
		if not plan then
			break
		end
		step("bank / forge " .. n)
		local r = call(8, Msg.ForgeCraft, { tab = "Spirit", ember = false, mats = plan })
		if not (type(r) == "table" and r.ok) then
			first("forge refused " .. errOf(r), errOf(r))
			if errOf(r) ~= "Busy" then
				break
			end
			task.wait(1)
		else
			n += 1
			stats.forged += 1
		end
		task.wait(0.55) -- ForgeCraft is limited to 8 per 4s
	end
	if n > 0 then
		say(("forged %d"):format(n))
		if on.equip then
			call(5, Msg.InvEquipBest)
		end
		sellGear()
	end
end

local function sellAll()
	local r = call(6, Msg.SellMaterial, { all = true })
	if type(r) == "table" and r.ok then
		stats.sold += tonumber(r.sold) or 0
		stats.coins += tonumber(r.coins) or 0 -- r.coins is what this sale paid, not the balance
		if (tonumber(r.sold) or 0) > 0 then
			say(("sold %d materials for %s"):format(r.sold, fmt(r.coins)))
		end
	elseif errOf(r) ~= "NothingToSell" then
		first("sell refused " .. errOf(r), errOf(r))
	end
end

local function bank(alive)
	if on.forge then
		forgeAll(alive)
	end
	if on.sell then
		step("bank / sell")
		sellAll()
	end
end

-- farm -----------------------------------------------------------------------
local function goHome(alive)
	step("home")
	fire(Msg.StageReturnTown)
	local t = os.clock()
	while alive() and os.clock() - t < RETURN_WAIT and not inLobby() do
		task.wait(0.1)
	end
	stats.banks += 1
	task.wait(0.3)
end

local function dropsNear(centre)
	local f = workspace:FindFirstChild("DropsClient")
	local out = {}
	for _, p in ipairs(f and f:GetChildren() or {}) do
		if p:IsA("BasePart") and p:FindFirstChild("PickupPrompt") and (p.Position - centre).Magnitude <= DROP_REACH then
			table.insert(out, p)
		end
	end
	return out
end

local function full()
	local cap = attr("TripCap")
	return cap > 0 and attr("TripCarry") >= cap
end

-- uid -> material id, from DropSpawn: the drop part carries neither
local dropMat = {}
local function onMain(id, _, list)
	if id == Msg.DropSpawn and type(list) == "table" then
		for _, row in ipairs(list) do
			if type(row) == "table" and row[1] then
				dropMat[row[1]] = row[2]
			end
		end
	end
end

-- the game's own beatsWorst (DropRenderer): with the carry full, the server swaps your worst piece for a better one
local function wanted(uid)
	if not full() then
		return true
	end
	if not on.swap then
		return false
	end
	local worst = player:GetAttribute("TripWorstRarity")
	local row = dropMat[uid] and mods.Materials.Any(dropMat[uid])
	if type(worst) ~= "number" or not row then
		return false
	end
	if row.Rarity ~= worst then
		return row.Rarity > worst
	end
	return (row.SellValue or 0) > attr("TripWorstValue")
end

-- hop onto every drop near `centre` worth having and pick it up (with the carry full: only the ones that beat the worst)
local function lootStage(centre, alive)
	local last = 0
	for pass = 1, 3 do
		local list = {}
		for _, p in ipairs(dropsNear(centre)) do
			if wanted(p.Name) then
				table.insert(list, p)
			end
		end
		if #list == 0 then
			return
		end
		for _, p in ipairs(list) do
			if not alive() then
				return
			end
			if p.Parent and wanted(p.Name) then
				step("loot " .. p.Name .. " / hop")
				local _, root = character()
				if root and (root.Position - p.Position).Magnitude > 12 then
					hop(p.Position + Vector3.new(0, PICK_OFFSET, 0), 4, alive)
				end
				local wait = 1 / 14 - (os.clock() - last) -- DropPickup is limited to 15 a second
				if wait > 0 then
					task.wait(wait)
				end
				last = os.clock()
				step("loot " .. p.Name .. " / pick")
				fire(Msg.DropPickup, p.Name)
				local t = os.clock()
				while p.Parent and os.clock() - t < PICK_CONFIRM do
					task.wait(0.03)
				end
				if not p.Parent then
					stats.picked += 1
				else
					first("pickup refused", p.Name, "pass", pass)
				end
			end
		end
	end
end

-- one stage: stand in it, wait for the clear, loot it. "cleared" / "parked" / "no area" / "stopped" / "died"
local function runStage(s, alive)
	step(("stage %d / hop"):format(s))
	local pos = standIn(s, alive)
	if not pos then
		return "no area"
	end
	local before = attr("RunMaxClear")
	local ok = hop(pos, 8, alive)
	if ok == nil then
		return "died"
	end
	step(("stage %d / wait spawn"):format(s))
	local t, fightAt = os.clock(), nil
	while alive() and attr("RunMaxClear") < s do
		local hum = character()
		if not hum then
			return "died"
		end
		if hum.Health < hum.MaxHealth * FLEE_HP then
			park[s] = { level = data().Level or 0, at = os.clock() }
			log(("fled stage %d at %d%% health (Level %s), parked"):format(s, math.floor(hum.Health / hum.MaxHealth * 100), tostring(data().Level)))
			return "parked" -- the caller runs home, which banks the carry
		end
		if not fightAt and attr("InChallenge") == s then
			fightAt = os.clock()
			step(("stage %d / fight"):format(s))
		end
		if fightAt and os.clock() - fightAt > CLEAR_SECS then
			park[s] = { level = data().Level or 0, at = os.clock() }
			log(("parked stage %d at Level %s: fought %ds without a clear"):format(s, tostring(data().Level), CLEAR_SECS))
			return "parked"
		end
		if not fightAt and os.clock() - t > SPAWN_SECS then
			first("stage never spawned", s, "RunMaxClear", attr("RunMaxClear"))
			return "no spawn"
		end
		task.wait() -- every frame: a boss hit is big
	end
	if not alive() then
		return "stopped"
	end
	stats.clears += 1
	first("first clear", s, ("%.1fs"):format(os.clock() - t), "was", before)
	if on.loot then
		task.wait(DROP_LAND)
		lootStage(stageArea(s) and stageArea(s).centre or pos, alive)
	end
	return "cleared"
end

-- the game's fast travel: from the lobby station, StageTeleport(n) lands you past stage n with RunMaxClear = n
-- (probed: 4 from the station ok, from 600 studs "TooFar"). Only the Tuning.Stage.FastTravelStages, up to your best.
local function fastTravel(cap, alive)
	local best = 0
	for _, n in ipairs(Tuning.Stage.FastTravelStages or {}) do
		if n <= (data().CareerMaxStage or 0) and n <= cap - FAST_MIN and n > best then
			best = n
		end
	end
	if best <= attr("RunMaxClear") then
		return
	end
	local station = workspace:FindFirstChild("StationPrompt_Teleport")
	local pos = station and station:GetPivot().Position
	if not pos then
		first("no teleport station")
		return
	end
	step("travel / hop " .. best)
	if not hop(pos + Vector3.new(0, 3, 4), 8, alive) then
		return
	end
	task.wait(0.5) -- the server must see us at the station first: called on arrival it answered TooFar
	step("travel / teleport " .. best)
	local r = call(6, Msg.StageTeleport, best)
	if type(r) == "table" and r.ok then
		say(("fast travel to stage %d"):format(best))
		task.wait(1.5) -- the server moves us
	else
		first("fast travel refused " .. errOf(r), best)
	end
end

local function farmLoop(mine)
	local function alive()
		return on.farm and gens.farm == mine and not dead
	end
	while alive() do
		local ok, err = pcall(function()
			if not character() then
				step("farm / respawn")
				task.wait(1)
				return
			end
			local s = attr("RunMaxClear") + 1
			local cap = capStage()
			stageNow = s
			-- with Swap on, a full carry keeps going: deeper stages drop better loot, and the server swaps the worst piece
			if s > cap or (full() and not on.swap) then
				say(s > cap and ("stage %d is the last you clear, banking %d/%d"):format(cap, attr("TripCarry"), attr("TripCap"))
					or ("carry %d/%d full, banking"):format(attr("TripCarry"), attr("TripCap")))
				if not inLobby() then
					goHome(alive)
				end
				bank(alive)
				if s > cap and cap < 1 then
					say("stage 1 is parked: waiting for Level")
					task.wait(5)
				end
				return
			end
			local hum = character()
			if inLobby() and hum.Health < hum.MaxHealth * HEAL_TO then
				step("farm / heal")
				say(("healing in the lobby: %d%%"):format(math.floor(hum.Health / hum.MaxHealth * 100)))
				task.wait(1)
				return
			end
			if on.travel and inLobby() then
				fastTravel(cap, alive)
				s = attr("RunMaxClear") + 1
				stageNow = s
			end
			say(("stage %d (carry %d/%d)"):format(s, attr("TripCarry"), attr("TripCap")))
			local res = runStage(s, alive)
			if res == "died" then
				park[s] = { level = data().Level or 0, at = os.clock() }
				log(("died in stage %d, parked"):format(s))
				task.wait(2)
			elseif res == "parked" or res == "no spawn" then
				goHome(alive)
				bank(alive)
			elseif res == "no area" then
				first("stage " .. s .. " has no area", s)
				park[s] = { level = data().Level or 0, at = os.clock() }
			end
		end)
		if not ok then
			first("farm error " .. tostring(err), err)
			task.wait(2)
		end
		task.wait()
	end
	stageNow = 0
end

local function setFarm(state)
	on.farm = state
	gens.farm += 1
	if state then
		task.spawn(farmLoop, gens.farm)
	end
end

-- with the farm off, Auto Loot picks up whatever lands within reach of where you stand
local function lootLoop(mine)
	while on.loot and gens.loot == mine and not dead do
		if not on.farm and not full() then
			local _, root = character()
			if root then
				for _, p in ipairs(dropsNear(root.Position)) do
					if (p.Position - root.Position).Magnitude <= 13 then
						fire(Msg.DropPickup, p.Name)
						task.wait(1 / 14)
					end
				end
			end
		end
		task.wait(0.25)
	end
end

local function setLoot(state)
	on.loot = state
	gens.loot += 1
	if state then
		task.spawn(lootLoop, gens.loot)
	end
end

-- train ----------------------------------------------------------------------
local zoneMult = 0
local function bestZone()
	local reb = data().Rebirth or 0
	local best, mult = 0, 0
	for i, z in ipairs(Tuning.TrainingGrounds or {}) do
		local open = z.gate == "none" or (z.gate == "rebirth" and reb >= (z.value or math.huge))
		if open and (z.multiplier or 0) >= mult then
			best, mult = i, z.multiplier or 0
		end
	end
	return best, mult
end

local function tapFor(secs, alive)
	local nextAt = os.clock()
	local stopAt = os.clock() + secs
	while alive() and os.clock() < stopAt do
		fire(Msg.TrainManualClick)
		nextAt += 1 / TAP_RATE
		local w = nextAt - os.clock()
		if w > 0 then
			task.wait(w)
		else
			nextAt = os.clock() -- fell behind: never catch up with a burst, the server drops those whole
			task.wait()
		end
	end
end

local function trainLoop(mine)
	local function alive()
		return (on.tap or on.zone) and gens.train == mine and not dead
	end
	local mode, decidedAt, decidedReb, zoneSent = nil, 0, -1, 0
	while alive() do
		local zone, mult = bestZone()
		zoneMult = mult
		local reb = data().Rebirth or 0
		if on.tap and on.zone and zone > 0 and (not mode or reb ~= decidedReb or os.clock() - decidedAt > RESAMPLE_SECS) then
			step("train / sample")
			fire(Msg.TrainZoneUpdate, zone)
			task.wait(0.6)
			local p0 = lifetime()
			task.wait(SAMPLE_SECS)
			local zoneRate = (lifetime() - p0) / SAMPLE_SECS
			fire(Msg.TrainZoneUpdate, 0)
			task.wait(0.6)
			p0 = lifetime()
			tapFor(SAMPLE_SECS, alive)
			local tapRate = (lifetime() - p0) / SAMPLE_SECS
			mode = zoneRate > tapRate and "zone" or "tap"
			decidedAt, decidedReb, zoneSent = os.clock(), reb, 0
			log(("train: zone %d (x%s) %s/s vs tap %s/s -> %s"):format(zone, tostring(mult), fmt(zoneRate), fmt(tapRate), mode))
		elseif not (on.tap and on.zone) then
			mode = on.zone and zone > 0 and "zone" or on.tap and "tap" or nil
		end
		trainMode = mode or "-"
		if mode == "zone" then
			if os.clock() - zoneSent > ZONE_REFIRE then
				fire(Msg.TrainZoneUpdate, zone)
				zoneSent = os.clock()
			end
			task.wait(0.5)
		elseif mode == "tap" then
			if zoneSent > 0 then
				fire(Msg.TrainZoneUpdate, 0) -- a tap pays nothing inside a zone
				zoneSent = 0
			end
			tapFor(1, alive)
		else
			task.wait(1)
		end
	end
	trainMode = "-"
	fire(Msg.TrainZoneUpdate, 0)
end

local function setTrain()
	gens.train += 1
	if on.tap or on.zone then
		task.spawn(trainLoop, gens.train)
	end
end

-- economy --------------------------------------------------------------------
-- one buy per pass, the cheapest of the weapon and the ticked upgrades, so neither starves the other
local function spendOnce()
	local d = data()
	local coins = tonumber(d.Coins) or 0
	local cands = {}
	if on.weapon then
		local eq = type(d.Equipment) == "table" and d.Equipment.Weapon or 0
		local have = Weapons.Get(eq) and Weapons.Get(eq).PowerPct or 0
		local best
		for _, w in ipairs(Weapons.Rows) do
			if w.Enabled and not w.ForgeOnly and not w.Premium and w.PowerPct > have and w.Price <= coins
				and not Inventory.OwnsWeapon(d, w.Id) and (not best or w.PowerPct > best.PowerPct) then
				best = w
			end
		end
		if best then
			table.insert(cands, { price = best.Price, label = "weapon " .. best.Name, args = { Msg.ShopBuy, WEAPON_KIND, best.Id }, kind = "weapons" })
		end
	end
	if on.upgrades then
		local reb = d.Rebirth or 0
		for key in pairs(upgradePick) do
			local lvl = Upgrades.LevelOf(d, key)
			local cost = Upgrades.Cost(key, lvl + 1)
			if lvl < Upgrades.MaxLevel(key, reb) and cost <= coins then
				table.insert(cands, { price = cost, label = ("upgrade %s %d+"):format(key, lvl + 1), args = { Msg.UpgradeBuy, key, true }, kind = "upgrades" })
			end
		end
	end
	local pick
	for _, c in ipairs(cands) do
		if not pick or c.price < pick.price then
			pick = c
		end
	end
	if not pick then
		return false
	end
	local r = call(6, table.unpack(pick.args))
	if type(r) == "table" and r.ok then
		stats[pick.kind] += 1
		say(("bought %s for %s"):format(pick.label, fmt(pick.price)))
		return true
	end
	first("buy refused " .. pick.label .. " " .. errOf(r), errOf(r))
	return false
end

local function rebirthOnce()
	local d = data()
	local reb, lvl = d.Rebirth or 0, d.Level or 0
	local need = Tuning.Formulas.RebirthLevelRequired(reb + 1)
	if reb >= Tuning.Rebirth.MaxTier or lvl < need then
		return
	end
	local r = call(6, Msg.PlayerRebirth)
	if type(r) == "table" and r.ok then
		stats.rebirths += 1
		table.clear(park) -- parks were measured against the old Level
		say(("rebirthed: %d -> %d (Level %d)"):format(reb, reb + 1, lvl))
	else
		first("rebirth refused " .. errOf(r), "level", lvl, "need", need)
	end
end

local materialDone = {} -- [milestone index] = true once the server says AlreadyClaimed
local function claimIndex()
	for _, tab in ipairs(mods.IndexBonus.Tabs or {}) do
		local r = call(5, Msg.IndexClaimGear, tab, "all")
		if type(r) == "table" and r.ok then
			stats.claims += 1
			say(("index: claimed %s gear (+%s xp)"):format(tab, tostring(r.xp)))
		end
	end
	for _ = 1, 10 do
		local r = call(5, Msg.IndexClaimLevel)
		if not (type(r) == "table" and r.ok) then
			break
		end
		stats.claims += 1
		say("index level up")
	end
	local milestones = Tuning.Index and Tuning.Index.MaterialMilestones or {}
	for i = 1, #milestones do
		if not materialDone[i] then
			local r = call(5, Msg.IndexClaimReward, "Material", i)
			if type(r) == "table" and r.ok then
				stats.claims += 1
				materialDone[i] = true
				say(("index: material milestone %d claimed"):format(i))
			elseif errOf(r) == "AlreadyClaimed" then
				materialDone[i] = true
			end
		end
	end
end

local function claimRewards()
	local r = call(5, Msg.PlaytimeClaim, "all")
	if type(r) == "table" and r.ok then
		stats.claims += 1
		say("claimed playtime rewards")
	end
	r = call(5, Msg.ClaimDailyAward)
	if type(r) == "table" and r.ok then
		stats.claims += 1
		say("claimed the daily reward")
	end
	r = call(5, Msg.OfflineRewardClaim)
	if type(r) == "table" and r.ok then
		stats.claims += 1
		say("claimed the offline reward")
	end
end

-- the skill tier list is the config's own: SumRate (total damage, 4.5 for Cinder Arc .. 650 for Ragnarok) scaled by
-- the forge grade you own it at (Forge.GradeDamageBonus, +0 .. +75%)
local function skillScore(id, grades)
	local row = mods.Skills.ById[tonumber(id)]
	local bonus = mods.Forge.GradeDamageBonus[tonumber(grades[tostring(id)]) or 1] or 0
	return row and (row.SumRate or 0) * (1 + bonus) or 0
end

local function equipSkills()
	local d = data()
	local unlocked, grades = d.UnlockedSkills, d.SkillGrades or {}
	if type(unlocked) ~= "table" then
		return
	end
	local slots = mods.Perks.OwnsFromAttributes(player)("SkillSlot3") and 3 or 2 -- slot 3 is a gamepass
	local ranked = {}
	for id, yes in pairs(unlocked) do
		if yes then
			table.insert(ranked, tonumber(id))
		end
	end
	table.sort(ranked, function(a, b)
		return skillScore(a, grades) > skillScore(b, grades)
	end)
	local want = {}
	for i = 1, math.min(slots, #ranked) do
		want[ranked[i]] = true
	end
	local have = {}
	for i = 1, slots do
		have[i] = attr("SkillId_" .. i)
	end
	for i = 1, slots do
		if not want[have[i]] then
			for _, id in ipairs(ranked) do
				if want[id] and not table.find(have, id) then
					local r = call(5, Msg.SetSkillSlot, i, id)
					if type(r) == "table" and r.ok then
						have[i] = id
						say(("skill slot %d: %s"):format(i, mods.Skills.ById[id] and mods.Skills.ById[id].Name or tostring(id)))
					else
						first("skill slot refused " .. errOf(r), i, id)
					end
					break
				end
			end
		end
	end
end

local function econLoop(mine)
	local claimAt, rewardAt = 0, 0
	while gens.econ == mine and not dead do
		local ok, err = pcall(function() -- never calls step(): the watchdog's breadcrumb belongs to the farm
			if on.rebirth then
				rebirthOnce()
			end
			local bought = (on.weapon or on.upgrades) and spendOnce()
			if not on.farm and (on.forge or on.sell) then
				bank(function()
					return not on.farm and not dead
				end) -- with the farm off nothing else moves you, so the bank runs from here
			end
			if os.clock() - claimAt > CLAIM_EVERY then
				claimAt = os.clock()
				if on.index then
					claimIndex()
				end
				if on.equip then
					call(5, Msg.InvEquipBest)
				end
				if on.team then
					call(5, Msg.CompanionTeam, "Best")
				end
				if on.skills then
					equipSkills()
				end
			end
			if on.rewards and os.clock() - rewardAt > REWARD_EVERY then
				rewardAt = os.clock()
				claimRewards()
			end
			if bought then
				task.wait(0.3) -- straight round: there may be more to buy
			else
				task.wait(ECON_EVERY)
			end
		end)
		if not ok then
			first("economy error " .. tostring(err), err)
			task.wait(ECON_EVERY)
		end
	end
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Sword Loot", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "sword")
local Farm = Tab:AddLeftGroupbox("Farm", "swords")
local Train = Tab:AddLeftGroupbox("Train", "dumbbell")
local Spend = Tab:AddRightGroupbox("Spend", "coins")
local Claim = Tab:AddRightGroupbox("Claim and equip", "gift")

local function flag(key)
	return function(state)
		on[key] = state
	end
end

Farm:AddToggle("Farm", {
	Text = "Auto Farm stages",
	Tooltip = "Hops into the next stage, lets the sword clear it, moves on; banks with the game's own trip home when the carry is full or the next stage is too strong",
	Default = false,
	Callback = function(state)
		pcall(setFarm, state)
		if not state then
			say("farm off")
		end
	end,
})
Farm:AddToggle("Loot", {
	Text = "Auto Loot",
	Tooltip = "The farm hops onto every drop of a cleared stage and picks it up. With the farm off, picks up whatever lands within reach",
	Default = false,
	Callback = function(state)
		pcall(setLoot, state)
	end,
})
Farm:AddToggle("Travel", {
	Text = "Fast travel to the deepest stage",
	Tooltip = "Each trip starts with the game's own fast travel (stages 4, 8, 13, 18 ...) to the deepest one at least 2 stages below where you stop clearing, skipping the cheap stages",
	Default = false,
	Callback = flag("travel"),
})
Farm:AddToggle("Swap", {
	Text = "Keep going when the carry is full",
	Tooltip = "On: a full carry keeps clearing deeper and swaps your worst piece for every better drop (more pickups, more index finds). Off: banks the moment the carry is full",
	Default = false,
	Callback = flag("swap"),
})
Farm:AddToggle("Forge", {
	Text = "Auto Forge",
	Tooltip = "At every bank: hops to the anvil and forges (Spirit tab) with the game's own AutoFill pick, while 4 materials are left. Runs before Auto Sell",
	Default = false,
	Callback = flag("forge"),
})
Farm:AddToggle("Sell", {
	Text = "Auto Sell materials",
	Tooltip = "At every bank: Sell All. With Auto Forge on too, sells what the forge left",
	Default = false,
	Callback = flag("sell"),
})
Farm:AddInput("MaxStage", {
	Text = "Highest stage",
	Tooltip = "The farm never goes past this stage. A stage it cannot clear in time is skipped by itself until your Level grows",
	Default = "35",
	Numeric = true,
	Finished = true,
	Callback = function(text)
		local n = tonumber(text)
		if n and n >= 1 then
			maxStage = math.floor(n)
			table.clear(park)
		end
	end,
})
local farmLine = Farm:AddLabel("-", true)

Train:AddToggle("Tap", {
	Text = "Auto Tap",
	Tooltip = "Taps for Power at 14 a second (the server drops faster bursts whole), anywhere, alongside the farm",
	Default = false,
	Callback = function(state)
		on.tap = state
		pcall(setTrain)
	end,
})
Train:AddToggle("Zone", {
	Text = "Auto Train zone",
	Tooltip = "Trains in the best zone your rebirths unlock, from anywhere. With Auto Tap on too, measures both and runs the better one (taps win until about the x15 zone)",
	Default = false,
	Callback = function(state)
		on.zone = state
		pcall(setTrain)
	end,
})
Train:AddToggle("Rebirth", {
	Text = "Auto Rebirth",
	Tooltip = "Rebirths at Level 25 x (rebirths + 1). Resets Level only; each rebirth is +50% Power and +20% coins",
	Default = false,
	Callback = flag("rebirth"),
})
local trainLine = Train:AddLabel("-", true)

Spend:AddToggle("Weapon", {
	Text = "Auto buy better weapon",
	Tooltip = "Buys the best shop weapon you can afford that beats the equipped one. The game equips it. Never the Robux or forge-only ones",
	Default = false,
	Callback = flag("weapon"),
})
Spend:AddToggle("Upgrades", {
	Text = "Auto max upgrades",
	Tooltip = "The game's Max button on the ticked upgrades, cheapest first. Shares the coins with the weapon buy, cheapest first",
	Default = false,
	Callback = flag("upgrades"),
})
Spend:AddDropdown("UpgradeList", {
	Text = "Upgrades to buy",
	Tooltip = "Bag = carry slots. Power = Power per tap. Luck = rarer drops and forges. Magnet = loot flies to you",
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

Claim:AddToggle("Index", {
	Text = "Auto claim index",
	Tooltip = "Every 30s: claim all gear per index tab, level the index, claim every reached material milestone",
	Default = false,
	Callback = flag("index"),
})
Claim:AddToggle("Rewards", {
	Text = "Auto claim playtime / daily / offline",
	Tooltip = "Every 60s: Claim All playtime rewards, the daily reward and the offline reward",
	Default = false,
	Callback = flag("rewards"),
})
Claim:AddToggle("EquipBest", {
	Text = "Auto equip best gear",
	Tooltip = "The game's own Equip Best, every 30s and after every forge",
	Default = false,
	Callback = flag("equip"),
})
Claim:AddToggle("TeamBest", {
	Text = "Auto equip best summons",
	Tooltip = "The game's own Equip Best team, every 30s",
	Default = false,
	Callback = flag("team"),
})
Claim:AddToggle("Skills", {
	Text = "Auto equip best skills",
	Tooltip = "Every 30s: puts your strongest unlocked skills in the slots (damage x forge grade bonus, from the game's own skill table). Slot 3 only with its gamepass",
	Default = false,
	Callback = flag("skills"),
})

-- the raw event, not Net.OnClientEvent: that one may hold a single handler per message and push the game's out
local MainEvent = ReplicatedStorage:FindFirstChild("MainEvent", true)
if MainEvent and MainEvent:IsA("RemoteEvent") then
	table.insert(conns, MainEvent.OnClientEvent:Connect(onMain))
else
	warn("[sword] no MainEvent: with the carry full, the farm will not swap for better loot")
end

local note, nextStrip = "idle", 0
local lastP, lastAt, rate = lifetime(), os.clock(), 0
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
		local p = lifetime()
		rate = (p - lastP) / (now - lastAt)
		lastP, lastAt = p, now
		if on.farm or on.tap or on.zone then
			log(("rate: Power +%s/s, clears %d, picked %d, banks %d, forged %d, sold %d for %s (%s/min), coins %s, Level %s, kinds %d"):format(
				fmt(rate), stats.clears, stats.picked, stats.banks, stats.forged, stats.sold, fmt(stats.coins),
				fmt(stats.coins / math.max((now - stats.startAt) / 60, 1 / 60)), fmt(data().Coins), tostring(data().Level), kinds(now)
			))
		end
	end
	local d = data()
	local parked = {}
	for s in pairs(park) do
		table.insert(parked, s)
	end
	table.sort(parked)
	pcall(farmLine.SetText, farmLine, ("stage %d, cap %d, parked %s, clears %d, picked %d"):format(
		stageNow, capStage(), #parked > 0 and table.concat(parked, ",") or "-", stats.clears, stats.picked
	))
	pcall(trainLine.SetText, trainLine, ("running %s, best zone x%s, rebirth %s"):format(trainMode, tostring(zoneMult), tostring(d.Rebirth)))
	pcall(Window.SetStatus, Window, {
		{ "Power/s", fmt(rate) },
		{ "Level", tostring(d.Level or "?") },
		{ "Rebirth", tostring(d.Rebirth or "?") },
		{ "Coins", fmt(d.Coins) },
		{ "Carry", ("%d/%d"):format(attr("TripCarry"), attr("TripCap")) },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("SwordLoot", {})

table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

gens.econ += 1
task.spawn(econLoop, gens.econ)

task.spawn(function() -- watchdog: a parked farm thread cannot report itself
	while not dead do
		task.wait(5)
		if on.farm and os.clock() - markAt > STUCK_AFTER then
			warn(("[sword] stuck %ds at: %s"):format(os.clock() - markAt, mark))
			markAt = os.clock()
		end
	end
end)

-- close ----------------------------------------------------------------------
local function stopAll()
	for k in pairs(on) do
		on[k] = false
	end
	for k in pairs(gens) do
		gens[k] += 1
	end
	dead = true
	task.spawn(fire, Msg.TrainZoneUpdate, 0) -- the gate may make it wait; teardown must not
end

Library:OnUnload(function()
	stopAll()
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
	getgenv().swordLootStop = nil
end)

getgenv().swordLootStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().swordLootStop = nil
end
