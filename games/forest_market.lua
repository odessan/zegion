--[[ Forest Market -- farm, stock the stall by day and night, forage, cook (108679402300081)

     FARM    : plants the seeds you tick on your field, all on ONE spot (the server lets plants stack, so
               one stand waters and harvests every one of them), waters them with the can and harvests each
               the moment it is Ready. Growth runs on the plant's own timer once watered (Kentang 15s);
               more water does not speed it up, so there is no instant harvest. 10 plants per field at
               plot level 1 (probed: the 11th is refused).
     SEEDS   : buys packs of the ticked seeds from anywhere on the map (ShopBuy is position-free,
               probed at 275 studs) whenever you hold fewer than "Keep seeds".
     RACK    : day buyers (villagers) take crops; night buyers (ghosts) take forage and cooked food and
               nothing else. Each phase the rack takes back what nobody will buy and fills every slot with
               the best-paying thing you hold that this phase sells. Works from anywhere (probed at 149).
     DUPA    : buys one Dupa Pemikat each night (50 coins, more ghosts at your stall until morning;
               buying it is using it).
     FORAGE  : once a minute, hops to the nearest ready spawn of the items you tick, takes the ready
               spawns around it for up to 25s, then hops home (30s respawn per spawn).
     PROCESS : Meja Pengolahan, for the recipes you tick (Crow -> Crow Meat). Output lands in the bag.
     KITCHEN : keeps the stove's 3-slot queue full with the menus you tick, best-paying first.
     UPGRADE : Upgrade Toko when you can pay (answers the game's confirm itself), Upgrade Plot likewise.
     QUESTS  : claims finished daily quests.

     MOVEMENT: hops (300 per jump, 0.5s apart), and only when out of reach of the target. Forage is the
     throttled part: one trip a minute. Single hops up to 320 studs held in the ladder (2026-10-07),
     but foraging nonstop got the account kicked three times (267 "Unusual activity or a data error")
     after 6-10 minutes each: the server counts something over time, not per hop. Do not raise the
     trip rate to test the limit; each test is a kick.

     Probed and dead (do not re-probe):
       Tanam from 51 studs              nothing planted; works from ~27 with the seed held
       Panen from 26 studs              refused; the client gate is 18
       more Siram after the bed is Wet  growth rate unchanged (Prog +1/growTime per second)
       fireproximityprompt on a forage  nothing; InputHoldBegin/End takes it
       OlahMulai / CookStove from range "Dekati ... dulu"; fine from 3 studs of pPemotongan / pKompor
     Not wired (Robux): instant cook (product 3610302404), coin/shard boosts, server boost.
     Not wired (not owned yet): chicken coop, cow barn, pigs -- probe them once bought.

     RightControl opens / closes the panel. Stop: getgenv().forestMarketStop() ]]

-- config ---------------------------------------------------------------------
local HOP_MAX = 300 -- longest single jump; the ladder held 320, so chains are made of these
local HOP_SETTLE = 0.25 -- after a hop, before acting where you landed
local HOP_GAP = 0.5 -- at least this long between any two hops, chained legs included
-- One forage trip a minute: three 267 kicks ("Unusual activity") came after 6-10 minutes of nonstop
-- foraging, while each single hop up to 320 had held in the ladder.
local FORAGE_CYCLE = 60 -- one trip (hop out, walk the cluster, hop home) per this many seconds
local CLUSTER_WALK = 80 -- on a trip, walk on to the next ready spawn only if it is this close
local CYCLE_TIME = 25 -- ...and stop walking the cluster after this long
local PLANT_GAP = 1.1 -- the server takes a plant about once a second; faster fires alternate refused
local PLANT_CONFIRM = 1.5 -- the bed must appear inside this
local SPRAY_TICKS = 6 -- Siram fires (0.2s apart) per watering; one landed tick fills the bed
local HARVEST_CONFIRM = 1.5
local FARM_IDLE = 1 -- between farm passes when nothing is ready
local RACK_EVERY = 3 -- rack sweep; no movement, so it runs alongside everything
local RACK_GAP = 0.6 -- between RakAksi calls; 0.25 was answered "cepat" (too fast)
local SEED_EVERY = 5
local SEED_KEEP_DEFAULT = 15 -- seeds held per ticked kind before Auto Buy stops
local COIN_RESERVE = 50 -- nothing that spends (seeds, dupa, upgrades) takes coins below this
local FORAGE_KEEP_DEFAULT = 40 -- stop taking a forage item once you hold this many
local FORAGE_BENCH = 35 -- a spawn that gave nothing is skipped for this long (respawn is 30)
local STATION_EVERY = 3
local UPGRADE_EVERY = 10
local QUEST_EVERY = 30
local INVOKE_TIMEOUT = 8 -- InvokeServer has no timeout of its own; give up on a reply after this
local STUCK_AFTER = 60 -- watchdog: a breadcrumb that has not moved for this long is printed

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().forestMarketStop then
	getgenv().forestMarketStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[forest]", ...)
end
local seen = {}
local function first(key, ...)
	if not seen[key] then
		seen[key] = true
		log("first:", key, ...)
	end
end

-- The breadcrumb doubles as the strip's "Now": a Heartbeat drains it, because a loop thread
-- writing to the window throws "lacking capability Plugin" after its first task.wait.
local pending = {}
local mark, markAt = "start", os.clock()
local function step(s)
	mark, markAt = s, os.clock()
	pending.now = s
end

-- game -----------------------------------------------------------------------
local ok, GameConfig, ShopConfig, PlantCatalog = pcall(function()
	return require(ReplicatedStorage.GameConfig), require(ReplicatedStorage.ShopConfig), require(ReplicatedStorage.PlantCatalog)
end)
if not ok then
	warn("[forest] the game's config modules did not load:", GameConfig)
	return
end
local Items = GameConfig.Items
local Stove = GameConfig.Cooking.Stove

-- Remotes are renamed to GUIDs at server start; each keeps its logical name in the LID attribute.
local remoteCache = {}
local function R(lid)
	local r = remoteCache[lid]
	if r and r.Parent then
		return r
	end
	for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
		if (d:IsA("RemoteEvent") or d:IsA("RemoteFunction")) and d:GetAttribute("LID") == lid then
			remoteCache[lid] = d
			return d
		end
	end
	return nil
end

-- InvokeServer never times out by itself; a parked farm thread looks exactly like a dead one.
local function invoke(lid, ...)
	local r = R(lid)
	if not r then
		return nil
	end
	local args, box = table.pack(...), nil
	task.spawn(function()
		local okc, res = pcall(function()
			return r:InvokeServer(table.unpack(args, 1, args.n))
		end)
		box = { okc and res or nil }
	end)
	local dl = os.clock() + INVOKE_TIMEOUT
	while not box and os.clock() < dl do
		task.wait()
	end
	return box and box[1]
end

local function coins()
	local ls = player:FindFirstChild("leaderstats")
	local k = ls and ls:FindFirstChild("Koin")
	return k and k.Value or 0
end
local function level()
	local ls = player:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild("Lv")
	return v and v.Value or 1
end
local function phase()
	return workspace:GetAttribute("Phase") or "Siang"
end

local SUFFIX = { "", "K", "M", "B" }
local function fmt(n)
	local i = 1
	while n >= 1000 and i < #SUFFIX do
		n /= 1000
		i += 1
	end
	return ("%.3g"):format(n) .. SUFFIX[i]
end
assert(fmt(758) == "758" and fmt(2500) == "2.5K", "fmt")

local function ticked(values)
	local set = {}
	for k, v in pairs(values) do
		if type(v) == "string" then
			set[v] = true
		elseif v then
			set[k] = true
		end
	end
	return set
end
assert(ticked({ "a" }).a and ticked({ b = true }).b and not ticked({ c = false }).c, "ticked")

-- bag ------------------------------------------------------------------------
local function tools()
	local out = {}
	for _, holder in ipairs({ player:FindFirstChildOfClass("Backpack"), player.Character }) do
		for _, t in ipairs(holder and holder:GetChildren() or {}) do
			if t:IsA("Tool") then
				out[#out + 1] = t
			end
		end
	end
	return out
end
local function held(itemId)
	local n = 0
	for _, t in ipairs(tools()) do
		if t:GetAttribute("ItemId") == itemId then
			n += t:GetAttribute("Count") or 1
		end
	end
	return n
end
local function seedTool(plantKey)
	for _, t in ipairs(tools()) do
		if t:GetAttribute("IsSeed") and t:GetAttribute("PlantType") == plantKey and (t:GetAttribute("Count") or 1) > 0 then
			return t
		end
	end
	return nil
end
local function seedsHeld(plantKey)
	local t = seedTool(plantKey)
	return t and (t:GetAttribute("Count") or 1) or 0
end

-- world ----------------------------------------------------------------------
local function myKiosk()
	local f = workspace:FindFirstChild(GameConfig.Plot.KiosFolderName or "KiosAktif")
	for _, k in ipairs(f and f:GetChildren() or {}) do
		if k:GetAttribute("OwnerUserId") == player.UserId then
			return k
		end
	end
	return nil
end

-- Your fields: Plot.<n>.Lahan<k> parts carrying Owner = your UserId, each with a Tanaman folder of beds.
local function myFields()
	local out = {}
	local root = workspace:FindFirstChild("Plot")
	for _, plot in ipairs(root and root:GetChildren() or {}) do
		for _, c in ipairs(plot:GetChildren()) do
			if c:IsA("BasePart") and c.Name:match("^Lahan%d+$") and c:GetAttribute("Owner") == player.UserId and c:FindFirstChild("Tanaman") then
				out[#out + 1] = c
			end
		end
	end
	return out
end
local function beds(field)
	local out = {}
	for _, b in ipairs(field.Tanaman:GetChildren()) do
		if b:IsA("BasePart") and b:GetAttribute("OwnerId") == player.UserId then
			out[#out + 1] = b
		end
	end
	return out
end

local function root()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart"), c and c:FindFirstChildOfClass("Humanoid")
end

-- Returns true (there), false (the server put us back), nil (no character). Chains jumps over HOP_MAX.
-- Cleared by stopAll. A stopped copy must never move you again: a re-paste once left the old copy's
-- forage hop in flight while the new copy hopped to the field, and the server kicked (267) seconds later.
local running = true
local lastHop = 0

local function tp(pos)
	local hrp = root()
	if not hrp or not running then
		return nil
	end
	-- ponytail: fixed floor between hops; raise HOP_GAP if the server's 267 speed kick comes back
	local wait = lastHop + HOP_GAP - os.clock()
	if wait > 0 then
		task.wait(wait)
	end
	lastHop = os.clock()
	local guard = 0
	while (hrp.Position - pos).Magnitude > HOP_MAX and guard < 10 do
		guard += 1
		local dir = (pos - hrp.Position).Unit
		hrp.CFrame = CFrame.new(hrp.Position + dir * HOP_MAX)
		task.wait(HOP_GAP)
		hrp = root()
		if not hrp or not running then
			return nil
		end
	end
	hrp.CFrame = CFrame.new(pos)
	hrp.AssemblyLinearVelocity = Vector3.zero
	task.wait(HOP_SETTLE)
	hrp = root()
	if not hrp then
		return nil
	end
	return (hrp.Position - pos).Magnitude < 8
end

-- Hop to a spot only when you are not already within reach of it: the farm, stall and stove passes run
-- every few seconds, and re-hopping onto the spot you stand on would be a teleport for nothing.
-- Returns tp's answer (true there / false put back / nil no character or stopped).
local function go(pos, within)
	local hrp = root()
	if not hrp or not running then
		return nil
	end
	if (Vector3.new(hrp.Position.X, 0, hrp.Position.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude <= (within or 3) then
		return true
	end
	return tp(pos + Vector3.new(0, 3, 0))
end

local busy = false
-- Everything that moves the character goes through here; returns whether it RAN.
local function claim(fn)
	if busy then
		return false
	end
	busy = true
	local okc, err = pcall(fn)
	busy = false
	local _, hum = root()
	if hum then
		pcall(hum.UnequipTools, hum)
	end
	if not okc then
		warn("[forest]", err)
	end
	return true
end
-- Forage grabs the claim again the frame it lets go, so everything else waits its turn here instead of
-- giving up; forage leaves a gap between picks for these to land in.
local function claimWait(fn)
	local dl = os.clock() + 30
	while busy and os.clock() < dl do
		task.wait()
	end
	return claim(fn)
end

local function hold(prompt)
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = math.max(prompt.MaxActivationDistance, 15)
	prompt:InputHoldBegin()
	task.wait(prompt.HoldDuration + 0.15)
	prompt:InputHoldEnd()
end

-- state read by the loops -----------------------------------------------------
local stats = { planted = 0, harvested = 0, bought = 0, foraged = 0, cooked = 0, processed = 0, racked = 0, quests = 0, upgrades = 0 }
local seedOn, forageOn, recipeOn, menuOn = {}, {}, {}, {}
local seedKeep, forageKeep = SEED_KEEP_DEFAULT, FORAGE_KEEP_DEFAULT
local cookOn, processOn = false, false -- the rack keeps their ingredients back while these run
local fieldNote = "-"

-- seeds, ranked by coins per second of growth (harvest value / grow time)
local SEEDS = {}
for key, p in pairs(PlantCatalog.Plants) do
	local shop = ShopConfig.Items["Bibit" .. key]
	local it = Items[key]
	if shop and it then
		SEEDS[#SEEDS + 1] = {
			key = key,
			shopId = "Bibit" .. key,
			price = shop.Price or 0,
			lvl = shop.LevelRequirement or p.minLevel or 1,
			rate = (it.harga or 0) * (p.harvestAmount or 1) / math.max(1, p.growTime or 1),
			grow = p.growTime or 0,
			bigOnly = p.potType ~= "PotKecil",
		}
	end
end
table.sort(SEEDS, function(a, b)
	return a.rate > b.rate
end)

-- farm -----------------------------------------------------------------------
local benchSeed = {} -- plantKey -> true once the field refuses it at zero beds (needs a bigger plot)
local fieldCap = {} -- field -> beds it took before refusing

-- A bed off the stack (planted by hand, or before a respawn) is out of the can's and Panen's reach from
-- the spot, so step over to it first.
local function reach(b, within)
	local hrp = root()
	if hrp and (hrp.Position - b.Position).Magnitude > within then
		go(b.Position, math.min(within, 3))
	end
end

-- Siram and Tanam are tool remotes: the server expects them only while that tool is in hand. Two 267
-- kicks each followed a stretch of them fired with the tool gone (you equipping a Keris mid-spray; a
-- stopped copy unequipping during a re-paste): "beds stay dry" was logged 10s before the second.
-- So: never fire unless the tool is in the character's hand, and stop the pass the moment it is not.
local function inHand(tool)
	return tool ~= nil and player.Character ~= nil and tool.Parent == player.Character
end
local function wield(tool)
	local _, hum = root()
	if not hum or not tool then
		return false
	end
	if not inHand(tool) then
		pcall(hum.EquipTool, hum, tool)
		local dl = os.clock() + 0.6
		while not inHand(tool) and os.clock() < dl do
			task.wait()
		end
	end
	if not inHand(tool) then
		local other = player.Character and player.Character:FindFirstChildWhichIsA("Tool")
		step("farm waits: you are holding " .. (other and other.Name or "something else"))
		first("farm waits for your hands", other and other.Name)
		return false
	end
	return true
end

local function water(field)
	local dry
	for _, b in ipairs(beds(field)) do
		if b:GetAttribute("Wet") ~= true then
			dry = b
		end
	end
	if not dry then
		return
	end
	local can
	for _, t in ipairs(tools()) do
		if t.Name == "PenyiramTanaman" then
			can = t
		end
	end
	local _, hum = root()
	if not can or not hum then
		first("no watering can", "PenyiramTanaman not in the bag")
		return
	end
	step("farm / water")
	local siram = R("Siram")
	-- one spray covers a few studs (6 wet, 28 not): one stand per cluster of dry beds
	for _ = 1, 3 do
		reach(dry, 4)
		for _ = 1, SPRAY_TICKS do
			if not wield(can) then
				return
			end
			siram:FireServer()
			task.wait(0.2)
		end
		dry = nil
		for _, b in ipairs(beds(field)) do
			if b:GetAttribute("Wet") ~= true then
				dry = b
			end
		end
		if not dry then
			return
		end
	end
	first("beds stay dry", field:GetFullName())
end

local function harvest(field)
	local panen = R("Panen")
	for _, b in ipairs(beds(field)) do
		if b:GetAttribute("Ready") and not b:GetAttribute("Harvested") then
			step("farm / harvest " .. tostring(b:GetAttribute("PlantKey")))
			reach(b, 12) -- Panen's gate is 18
			panen:FireServer(b)
			local dl = os.clock() + HARVEST_CONFIRM
			while b.Parent and os.clock() < dl do
				task.wait(0.05)
			end
			if not b.Parent then
				stats.harvested += 1
			else
				first("harvest refused", b:GetAttribute("PlantKey"))
			end
		end
	end
end

local function plant(field, spot)
	local tanam = R("Tanam")
	for _, s in ipairs(SEEDS) do
		if seedOn[s.key] and not benchSeed[s.key] and s.lvl <= level() then
			while seedsHeld(s.key) > 0 do
				local n0 = #beds(field)
				if fieldCap[field] and n0 >= fieldCap[field] then
					return
				end
				local tool = seedTool(s.key)
				if not wield(tool) then
					return
				end
				step("farm / plant " .. s.key)
				tanam:FireServer(spot)
				local dl = os.clock() + PLANT_CONFIRM
				while #beds(field) == n0 and os.clock() < dl do
					task.wait(0.05)
				end
				if #beds(field) > n0 then
					stats.planted += 1
					task.wait(PLANT_GAP - 0.3)
				else
					-- one refusal can be the server's own pacing; a second in a row is the field full
					task.wait(PLANT_GAP)
					if not wield(tool) then
						return
					end
					tanam:FireServer(spot)
					task.wait(PLANT_CONFIRM)
					if #beds(field) > n0 then
						stats.planted += 1
					else
						if n0 == 0 then
							benchSeed[s.key] = true
							log(("%s refused on an empty field: benched (a bigger plot / Lahan Besar?)"):format(s.key))
						else
							fieldCap[field] = n0
							first("field cap", field:GetFullName(), n0)
						end
						return
					end
				end
			end
		end
	end
end

local function farmPass()
	for _, field in ipairs(myFields()) do
		local spot = field.Position + Vector3.new(0, field.Size.Y / 2, 0)
		local list = beds(field)
		local ready, dry = 0, 0
		for _, b in ipairs(list) do
			if b:GetAttribute("Ready") then
				ready += 1
			end
			if b:GetAttribute("Wet") ~= true then
				dry += 1
			end
		end
		local canPlant = false
		if not fieldCap[field] or #list < fieldCap[field] then
			for _, s in ipairs(SEEDS) do
				if seedOn[s.key] and not benchSeed[s.key] and s.lvl <= level() and seedsHeld(s.key) > 0 then
					canPlant = true
				end
			end
		end
		fieldNote = ("%d planted, %d ready"):format(#list, ready)
		if ready > 0 or dry > 0 or canPlant then
			claimWait(function()
				step("farm / hop")
				if not go(spot, 4) then
					return
				end
				harvest(field)
				go(spot, 4)
				plant(field, spot)
				water(field)
			end)
		end
	end
end

local genFarm = 0
local function setFarm(on)
	genFarm += 1
	local mine = genFarm
	if not on then
		return
	end
	task.spawn(function()
		while genFarm == mine do
			local okp, err = pcall(farmPass)
			if not okp then
				warn("[forest] farm:", err)
			end
			task.wait(FARM_IDLE)
		end
	end)
end

-- seeds ------------------------------------------------------------------------
local genSeeds = 0
local function setSeeds(on)
	genSeeds += 1
	local mine = genSeeds
	if not on then
		return
	end
	task.spawn(function()
		while genSeeds == mine do
			step("seeds / pass")
			local stock = {}
			local poll = invoke("ShopPoll")
			if type(poll) == "table" and type(poll.stock) == "table" then
				stock = poll.stock
			end
			for _, s in ipairs(SEEDS) do
				if genSeeds ~= mine then
					break
				end
				local have = seedsHeld(s.key)
				if seedOn[s.key] and not benchSeed[s.key] and s.lvl <= level() and have < seedKeep then
					local packs = math.ceil((seedKeep - have) / 5)
					packs = math.min(packs, math.floor((coins() - COIN_RESERVE) / math.max(1, s.price)))
					if stock[s.shopId] then
						packs = math.min(packs, stock[s.shopId])
					end
					if packs > 0 then
						step("seeds / buy " .. s.shopId)
						local res = invoke("ShopBuy", s.shopId, packs)
						first("ShopBuy qty " .. packs, type(res) == "table" and res.ok, type(res) == "table" and res.reason)
						if type(res) == "table" and res.ok then
							stats.bought += packs
							log(("bought %d x %s (held %d)"):format(packs, s.shopId, have))
						elseif packs > 1 then
							res = invoke("ShopBuy", s.shopId, 1) -- a bulk the server would not take: one pack
							if type(res) == "table" and res.ok then
								stats.bought += 1
							end
						end
						task.wait(0.8) -- ShopConfig BuyCooldown 0.75
					end
				end
			end
			task.wait(SEED_EVERY)
		end
	end)
end

-- dupa -------------------------------------------------------------------------
local genDupa = 0
local dupaNight = nil
local function setDupa(on)
	genDupa += 1
	local mine = genDupa
	if not on then
		return
	end
	task.spawn(function()
		while genDupa == mine do
			local night = workspace:GetAttribute("PhaseEndsAt")
			if phase() == "Malam" and dupaNight ~= night and coins() >= (ShopConfig.Items.Pengelaris.Price or 50) + COIN_RESERVE then
				step("dupa / buy")
				local res = invoke("ShopBuy", "Pengelaris", 1)
				if type(res) == "table" and res.ok then
					dupaNight = night
					log("Dupa Pemikat burning until morning")
				else
					first("dupa refused", type(res) == "table" and res.reason)
					dupaNight = night -- once per night, refused or not
				end
			end
			task.wait(10)
		end
	end)
end

-- rack -------------------------------------------------------------------------
-- Who buys what, from the game's own Ghost config: villagers (day) only take Warga.only; ghosts (night)
-- take everything sellable except the crops that are villager-only. DuaFase items sell in both.
local wargaOnly, duaFase = {}, {}
for _, id in ipairs(GameConfig.Ghost.Types.Warga.only or {}) do
	wargaOnly[id] = true
end
for _, id in ipairs(GameConfig.Ghost.DuaFase or {}) do
	duaFase[id] = true
end
local function sellsNow(id)
	local it = Items[id]
	if not it or not it.jual then
		return false
	end
	if phase() == "Malam" then
		return not wargaOnly[id] or duaFase[id] == true
	end
	return wargaOnly[id] == true
end
assert(Items.Kentang and wargaOnly.Kentang and not duaFase.Kentang, "Kentang is a villager crop")

-- How many of an item the rack may sell: what you hold minus what the kitchen can actually cook with
-- it (40 Dupa against 15 crabs keeps 5 back, not 40) and everything a ticked recipe processes.
local function spare(id)
	local have = held(id)
	if processOn then
		for _, r in ipairs(GameConfig.Pengolahan.Resep) do
			if recipeOn[r.id] and r.input == id then
				return 0
			end
		end
	end
	if cookOn then
		for _, m in ipairs(Stove.Menus) do
			local uses = 0
			for _, ing in ipairs(m.ingredients) do
				if ing.item == id then
					uses = ing.qty or 1
				end
			end
			if menuOn[m.id] and uses > 0 then
				local times = math.huge
				for _, ing in ipairs(m.ingredients) do
					times = math.min(times, math.floor(held(ing.item) / (ing.qty or 1)))
				end
				have -= times * uses
			end
		end
	end
	return math.max(0, have)
end

local function slotsOf(k)
	local out = {}
	for _, a in ipairs(k:GetChildren()) do
		if a:IsA("Attachment") and a.Name:match("^slot%d+$") then
			out[#out + 1] = a
		end
	end
	table.sort(out, function(a, b)
		return tonumber(a.Name:match("%d+")) < tonumber(b.Name:match("%d+"))
	end)
	return out
end
local function stockOf(slot)
	local f = slot:FindFirstChild("Stok")
	local v = f and f:FindFirstChildWhichIsA("IntValue")
	return v and v.Value or 0
end

local rackCap, capAt = { rak = nil, nampan = nil }, 0
local function rackPass()
	local k = myKiosk()
	if not k then
		first("no kiosk", "Workspace.KiosAktif has none with your OwnerUserId")
		return
	end
	-- the caps grow with level and stall upgrades; until "info" answers, no top-ups at all
	if os.clock() - capAt > 30 then
		local info = invoke("RakAksi", "info")
		if type(info) == "table" and info.ok then
			rackCap.rak, rackCap.nampan, capAt = info.capRak, info.capNampan, os.clock()
		end
	end
	local onRack = {}
	local slots = slotsOf(k)
	for _, s in ipairs(slots) do
		local id = s:GetAttribute("Item")
		if id and stockOf(s) > 0 then
			onRack[id] = (onRack[id] or 0) + 1
		end
	end
	for _, s in ipairs(slots) do
		local id = s:GetAttribute("Item")
		local n = stockOf(s)
		if id and n > 0 and not sellsNow(id) then
			step("rack / take back " .. id)
			local res = invoke("RakAksi", "ambil", s.Name)
			if type(res) == "table" and res.ok then
				log(("took %d %s back (%s buyers do not want it)"):format(res.n or 0, id, phase()))
				onRack[id] = (onRack[id] or 1) - 1
				id, n = nil, 0
			end
			task.wait(RACK_GAP)
		end
		-- a top-up of a full slot is answered with a "rack is full" toast: only below the cap
		local cap = id and Items[id] and (Items[id].jenis == "rak" and rackCap.rak or rackCap.nampan)
		if id and n > 0 and cap and n < cap and spare(id) > 0 then
			local res = invoke("RakAksi", "isi", s.Name)
			if type(res) == "table" and res.ok and (res.n or 0) > 0 then
				stats.racked += res.n
			end
			task.wait(RACK_GAP)
		elseif not id or n <= 0 then
			-- best-paying sellable thing in the bag, preferring one not already on another slot
			local best, bestScore
			for _, t in ipairs(tools()) do
				local tid = t:GetAttribute("ItemId")
				if tid and sellsNow(tid) and spare(tid) > 0 then
					local score = (Items[tid].harga or 0) - (onRack[tid] or 0) * 1000
					if not bestScore or score > bestScore then
						best, bestScore = tid, score
					end
				end
			end
			if best then
				step("rack / place " .. best)
				local res = invoke("RakAksi", "taruh", s.Name, best)
				if type(res) == "table" and res.ok then
					stats.racked += res.n or 0
					onRack[best] = (onRack[best] or 0) + 1
				else
					first("taruh refused " .. best, type(res) == "table" and res.reason)
				end
				task.wait(RACK_GAP)
			end
		end
	end
end

-- Slots only refill when they empty, so a full rack of 5-coin Melati would keep a 45-coin Sate Kepiting
-- in the bag all phase. One swap per pass: the best spare item not on the rack replaces the cheapest
-- slot when it pays at least double.
local function rackSwap()
	local k = myKiosk()
	if not k then
		return
	end
	local onRack, cheap, cheapPrice = {}, nil, math.huge
	for _, s in ipairs(slotsOf(k)) do
		local id = s:GetAttribute("Item")
		if id and stockOf(s) > 0 then
			onRack[id] = true
			local price = Items[id] and Items[id].harga or 0
			if price < cheapPrice then
				cheap, cheapPrice = s, price
			end
		end
	end
	local best, bestPrice = nil, 0
	for _, t in ipairs(tools()) do
		local tid = t:GetAttribute("ItemId")
		local price = tid and Items[tid] and Items[tid].harga or 0
		if tid and not onRack[tid] and price > bestPrice and sellsNow(tid) and spare(tid) > 0 then
			best, bestPrice = tid, price
		end
	end
	if cheap and best and bestPrice >= cheapPrice * 2 then
		local old = tostring(cheap:GetAttribute("Item"))
		step("rack / swap " .. old .. " -> " .. best)
		local res = invoke("RakAksi", "ambil", cheap.Name)
		task.wait(RACK_GAP)
		if type(res) == "table" and res.ok then
			res = invoke("RakAksi", "taruh", cheap.Name, best)
			if type(res) == "table" and res.ok then
				log(("swapped %s (%d) for %s (%d) on %s"):format(old, cheapPrice, best, bestPrice, cheap.Name))
			end
			task.wait(RACK_GAP)
		end
	end
end

local genRack = 0
local function setRack(on)
	genRack += 1
	local mine = genRack
	if not on then
		return
	end
	task.spawn(function()
		while genRack == mine do
			local okp, err = pcall(rackPass)
			if okp then
				okp, err = pcall(rackSwap)
			end
			if not okp then
				warn("[forest] rack:", err)
			end
			task.wait(RACK_EVERY)
		end
	end)
end

-- forage -----------------------------------------------------------------------
local FORAGE = {}
for id, it in pairs(Items) do
	if type(it) == "table" and it.forage then
		FORAGE[#FORAGE + 1] = id
	end
end
table.sort(FORAGE)
local forageBench = setmetatable({}, { __mode = "k" })

local function nearestSpawn()
	local hrp = root()
	local folder = workspace:FindFirstChild(GameConfig.Forage.SpawnFolder or "SpawnBahan")
	if not hrp or not folder then
		return nil
	end
	local best, bd
	for _, s in ipairs(folder:GetChildren()) do
		local id = s:GetAttribute("ItemId")
		local pr = s:FindFirstChildWhichIsA("ProximityPrompt", true)
		if id and forageOn[id] and held(id) < forageKeep and (Items[id].minLevel or 1) <= level() and pr and pr.Enabled and (forageBench[s] or 0) < os.clock() then
			local d = (s:GetPivot().Position - hrp.Position).Magnitude
			if not bd or d < bd then
				best, bd = s, d
			end
		end
	end
	return best
end

local genForage = 0
local function setForage(on)
	genForage += 1
	local mine = genForage
	if not on then
		return
	end
	-- take one spawn you are standing at; true when the item landed in the bag
	local function take(s)
		local id = s:GetAttribute("ItemId")
		local pr = s:FindFirstChildWhichIsA("ProximityPrompt", true)
		if not pr or not pr.Enabled then
			return false
		end
		local n0 = held(id)
		step("forage / take " .. id)
		hold(pr)
		local dl = os.clock() + 1.5
		while held(id) == n0 and os.clock() < dl do
			task.wait(0.05)
		end
		if held(id) > n0 then
			stats.foraged += 1
			return true
		end
		forageBench[s] = os.clock() + FORAGE_BENCH
		first("forage gave nothing", id, "daily cap " .. tostring(GameConfig.Forage.BatasHarian) .. "?")
		return false
	end
	local function spawnPos(s)
		local pr = s:FindFirstChildWhichIsA("ProximityPrompt", true)
		local part = pr and pr:FindFirstAncestorWhichIsA("BasePart")
		return part and part.Position
	end

	task.spawn(function()
		local nextTrip = 0
		while genForage == mine do
			local s = os.clock() >= nextTrip and nearestSpawn()
			if not s then
				task.wait(2)
			else
				nextTrip = os.clock() + FORAGE_CYCLE
				claimWait(function()
					local hrp = root()
					local fields = myFields()
					-- home is the field spot, so the farm needs no walk back from wherever the trip began
					local home = fields[1] and fields[1].Position + Vector3.new(0, fields[1].Size.Y / 2 + 3, 0) or (hrp and hrp.Position)
					local pos = spawnPos(s)
					if not home or not pos then
						return
					end
					step("forage / hop out to " .. tostring(s:GetAttribute("ItemId")))
					if not tp(pos + Vector3.new(0, 3, 0)) then
						forageBench[s] = os.clock() + FORAGE_BENCH
					else
						local got = take(s) and 1 or 0
						-- spawns come in clusters: short hops on to ready neighbours, inside this one trip
						local stopAt = os.clock() + CYCLE_TIME
						while running and os.clock() < stopAt do
							local n = nearestSpawn()
							local np = n and spawnPos(n)
							hrp = root()
							if not np or not hrp or (np - hrp.Position).Magnitude > CLUSTER_WALK then
								break
							end
							if go(np, 3) and take(n) then
								got += 1
							elseif n then
								forageBench[n] = os.clock() + FORAGE_BENCH
							end
						end
						log(("forage trip: %d items, next trip in %ds"):format(got, math.max(0, math.floor(nextTrip - os.clock()))))
					end
					step("forage / hop home")
					tp(home)
				end)
			end
		end
	end)
end

-- stations -----------------------------------------------------------------------
local menuBench = {}
local function canCook(m)
	for _, ing in ipairs(m.ingredients) do
		if held(ing.item) < (ing.qty or 1) then
			return false
		end
	end
	return true
end

local function stationPass()
	local k = myKiosk()
	if not k then
		return
	end
	if processOn then
		local poll = invoke("OlahPoll")
		if type(poll) == "table" and poll.ok and not poll.proses then
			for _, r in ipairs(GameConfig.Pengolahan.Resep) do
				local have = held(r.input)
				if recipeOn[r.id] and have > 0 and k:FindFirstChild("pPemotongan") then
					claimWait(function()
						step("process / hop")
						go(k.pPemotongan.WorldPosition, 4)
						local qty = math.min(have, poll.maksBatch or 100)
						local res = invoke("OlahMulai", r.id, qty)
						if type(res) == "table" and res.ok then
							stats.processed += qty
							log(("processing %d %s -> %s (%ds)"):format(qty, r.input, r.output, res.totalDetik or 0))
						else
							first("OlahMulai refused " .. r.id, type(res) == "table" and res.reason)
						end
					end)
					break
				end
			end
		end
	end
	if cookOn and k:FindFirstChild("pKompor") then
		local poll = invoke("CookQueuePoll")
		if type(poll) == "table" and poll.ok then
			local queued = #(poll.slots or {})
			local menus = {}
			for _, m in ipairs(Stove.Menus) do
				if menuOn[m.id] and (menuBench[m.id] or 0) < os.clock() then
					menus[#menus + 1] = m
				end
			end
			table.sort(menus, function(a, b)
				return (Items[a.output] and Items[a.output].harga or 0) > (Items[b.output] and Items[b.output].harga or 0)
			end)
			local room = (poll.maxQueue or Stove.MaxQueue or 3) - queued
			local any = false
			for _, m in ipairs(menus) do
				if canCook(m) then
					any = true
				end
			end
			if room > 0 and any then
				claimWait(function()
					step("kitchen / hop")
					go(k.pKompor.WorldPosition, 4)
					for _, m in ipairs(menus) do
						while room > 0 and canCook(m) do
							step("kitchen / cook " .. m.id)
							local res = invoke("CookStove", m.id)
							if type(res) == "table" and res.ok then
								room -= 1
								stats.cooked += 1
								-- the ingredients leave the bag a beat after the reply
								local dl = os.clock() + 1
								while canCook(m) and os.clock() < dl do
									task.wait(0.05)
								end
							else
								-- "Antrian penuh" (queue full) and "Sabar dulu" (pacing) are not the menu's fault
								menuBench[m.id] = os.clock() + 10
								first("CookStove refused " .. m.id, type(res) == "table" and res.reason)
								room = 0
								break
							end
							task.wait(0.35)
						end
					end
				end)
			end
		end
	end
end

local genStation = 0
local function setStations()
	genStation += 1
	local mine = genStation
	if not (cookOn or processOn) then
		return
	end
	task.spawn(function()
		while genStation == mine do
			local okp, err = pcall(stationPass)
			if not okp then
				warn("[forest] stations:", err)
			end
			task.wait(STATION_EVERY)
		end
	end)
end

-- upgrades -----------------------------------------------------------------------
local upShop, upPlot = false, false
local mutedConfirm = nil
local confirmCon = nil

-- The server asks "upgrade for X?" through MarketUpgradeConfirm and waits for {confirm = bool}. The game's
-- own dialog is muted while we answer, and handed back on stop.
local function armShopConfirm()
	local r = R("MarketUpgradeConfirm")
	if not r or confirmCon then
		return confirmCon ~= nil
	end
	if not getconnections then
		first("no getconnections", "Upgrade Toko needs it to answer the confirm")
		return false
	end
	mutedConfirm = {}
	for _, c in ipairs(getconnections(r.OnClientEvent)) do
		if pcall(function()
			c:Disable()
		end) then
			mutedConfirm[#mutedConfirm + 1] = c
		end
	end
	confirmCon = r.OnClientEvent:Connect(function(payload)
		local yes = type(payload) == "table" and type(payload.cost) == "number" and payload.cost + COIN_RESERVE <= coins()
		if type(payload) == "table" then
			for _, part in ipairs(payload.costParts or {}) do
				if part.nama ~= "Koin" then
					yes = false -- shards / Coin Pasar Setan: leave that one to you
				end
			end
		end
		log("Upgrade Toko offered:", type(payload) == "table" and payload.costText, "->", yes and "yes" or "no")
		r:FireServer({ confirm = yes })
	end)
	return true
end
local function disarmShopConfirm()
	if confirmCon then
		confirmCon:Disconnect()
		confirmCon = nil
	end
	for _, c in ipairs(mutedConfirm or {}) do
		pcall(function()
			c:Enable()
		end)
	end
	mutedConfirm = nil
end

local function upgradePass()
	local k = myKiosk()
	if upShop and k and armShopConfirm() then
		local lv = k:GetAttribute("MarketLevel") or 1
		local cost = GameConfig.MarketUpgrade.Cost[lv]
		local up = k:FindFirstChild("pShopUpgrade")
		local pr = up and up:FindFirstChildWhichIsA("ProximityPrompt")
		if type(cost) == "number" and cost + COIN_RESERVE <= coins() and pr and pr.Enabled then
			claimWait(function()
				step("upgrade / shop")
				go(up.WorldPosition, 4)
				hold(pr)
				local dl = os.clock() + 4
				while (k:GetAttribute("MarketLevel") or 1) == lv and os.clock() < dl do
					task.wait(0.1)
				end
				if (k:GetAttribute("MarketLevel") or 1) > lv then
					stats.upgrades += 1
					log("shop upgraded to level", k:GetAttribute("MarketLevel"))
				end
			end)
		end
	end
	if upPlot then
		for _, field in ipairs(myFields()) do
			local pr = field:FindFirstChild("Label") and field.Label:FindFirstChildWhichIsA("ProximityPrompt")
			local price = pr and tonumber((pr.ActionText or ""):match("(%d+)"))
			if pr and pr.Enabled and price and price + COIN_RESERVE <= coins() then
				claimWait(function()
					local lv = field:GetAttribute("Level")
					step("upgrade / plot")
					go(field.Label.Position, 6)
					hold(pr)
					task.wait(2)
					if field:GetAttribute("Level") ~= lv then
						stats.upgrades += 1
						fieldCap[field] = nil -- a bigger field takes more beds: find the cap again
						log("plot upgraded to level", field:GetAttribute("Level"))
					else
						first("plot upgrade did not take", pr.ActionText)
					end
				end)
			end
		end
	end
end

local genUpgrade = 0
local function setUpgrades()
	genUpgrade += 1
	local mine = genUpgrade
	if not upShop then
		disarmShopConfirm()
	end
	if not (upShop or upPlot) then
		return
	end
	task.spawn(function()
		while genUpgrade == mine do
			local okp, err = pcall(upgradePass)
			if not okp then
				warn("[forest] upgrade:", err)
			end
			task.wait(UPGRADE_EVERY)
		end
	end)
end

-- quests -------------------------------------------------------------------------
local genQuest = 0
local function setQuests(on)
	genQuest += 1
	local mine = genQuest
	if not on then
		return
	end
	task.spawn(function()
		while genQuest == mine do
			local q = invoke("QuestFetch")
			for _, quest in ipairs(type(q) == "table" and q.quests or {}) do
				if not quest.claimed and (quest.progress or 0) >= (quest.target or 1) then
					local res = invoke("QuestClaim", quest.id)
					if type(res) == "table" and res.ok then
						stats.quests += 1
						log("quest claimed:", quest.text)
					else
						first("QuestClaim refused " .. tostring(quest.id), type(res) == "table" and res.reason)
					end
				end
			end
			task.wait(QUEST_EVERY)
		end
	end)
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Forest Market", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "sprout")
local Farm = Tab:AddLeftGroupbox("Farm", "sprout")
local Stall = Tab:AddLeftGroupbox("Stall", "store")
local Forage = Tab:AddRightGroupbox("Forage", "leaf")
local Kitchen = Tab:AddRightGroupbox("Kitchen", "cooking-pot")
local More = Tab:AddRightGroupbox("Upgrades & quests", "trending-up")

local seedValues, seedByLabel, seedDefault = {}, {}, {}
for _, s in ipairs(SEEDS) do
	local label = ("%s (%d, Lv%d)"):format(s.key, s.price, s.lvl)
	seedValues[#seedValues + 1] = label
	seedByLabel[label] = s.key
	if s.key == "Kentang" then
		seedDefault[#seedDefault + 1] = label
		seedOn[s.key] = true -- Default does not fire the callback
	end
end

Farm:AddToggle("Farm", {
	Text = "Auto Plant + Water + Harvest",
	Tooltip = "Plants the ticked seeds you hold, all on one spot of your field, waters them and harvests each one the moment it is ready",
	Default = false,
	Callback = setFarm,
})
Farm:AddDropdown("Seeds", {
	Text = "Seeds",
	Tooltip = "What to plant and to buy. Price per 5-pack and level in brackets; listed best coins-per-second first",
	Values = seedValues,
	Default = seedDefault,
	Multi = true,
	Callback = function(picked)
		table.clear(seedOn)
		for label in pairs(ticked(picked)) do
			if seedByLabel[label] then
				seedOn[seedByLabel[label]] = true
			end
		end
	end,
})
Farm:AddToggle("BuySeeds", {
	Text = "Auto Buy Seeds",
	Tooltip = "Buys packs of the ticked seeds (from anywhere) whenever you hold fewer than the number below",
	Default = false,
	Callback = setSeeds,
})
Farm:AddInput("SeedKeep", {
	Text = "Keep seeds",
	Default = tostring(SEED_KEEP_DEFAULT),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		seedKeep = tonumber(text) or SEED_KEEP_DEFAULT
	end,
})

Stall:AddToggle("Rack", {
	Text = "Auto Rack (day / night)",
	Tooltip = "Fills every rack slot with the best-paying thing you hold that this phase's buyers want, tops slots up, and takes back what nobody will buy (crops at night). Keeps kitchen / processing ingredients back while those run",
	Default = false,
	Callback = setRack,
})
Stall:AddToggle("Dupa", {
	Text = "Auto Dupa Pemikat (night)",
	Tooltip = "Buys one Dupa Pemikat each night: 50 coins, more ghosts at your stall until morning",
	Default = false,
	Callback = setDupa,
})

Forage:AddToggle("Forage", {
	Text = "Auto Forage",
	Tooltip = "Hops to the nearest ready spawn of the ticked items and takes it. Spawns come back after 30s",
	Default = false,
	Callback = setForage,
})
local forageDefault = {}
for _, id in ipairs(FORAGE) do
	forageDefault[#forageDefault + 1] = id
	forageOn[id] = true
end
Forage:AddDropdown("ForageItems", {
	Text = "Items",
	Tooltip = "Melati, Kemenyan and Dupa sell at night; Gagak and Jamur Kuburan feed the kitchen",
	Values = FORAGE,
	Default = forageDefault,
	Multi = true,
	Callback = function(picked)
		table.clear(forageOn)
		for id in pairs(ticked(picked)) do
			forageOn[id] = true
		end
	end,
})
Forage:AddInput("ForageKeep", {
	Text = "Stop at (each)",
	Default = tostring(FORAGE_KEEP_DEFAULT),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		forageKeep = tonumber(text) or FORAGE_KEEP_DEFAULT
	end,
})

local recipeValues, recipeDefault = {}, {}
for _, r in ipairs(GameConfig.Pengolahan.Resep) do
	recipeValues[#recipeValues + 1] = r.id
	if not r.input:match("^Ayam") then -- live chickens lay eggs: chopping them is your call
		recipeDefault[#recipeDefault + 1] = r.id
		recipeOn[r.id] = true
	end
end
Kitchen:AddToggle("Process", {
	Text = "Auto Processing Table",
	Tooltip = "Runs the ticked recipes on everything you hold for them, a batch at a time (Crow -> Crow Meat)",
	Default = false,
	Callback = function(state)
		processOn = state
		setStations()
	end,
})
Kitchen:AddDropdown("Recipes", {
	Text = "Recipes",
	Tooltip = "Chicken recipes start unticked: a live chicken lays eggs",
	Values = recipeValues,
	Default = recipeDefault,
	Multi = true,
	Callback = function(picked)
		table.clear(recipeOn)
		for id in pairs(ticked(picked)) do
			recipeOn[id] = true
		end
	end,
})
local menuValues, menuByLabel, menuDefault = {}, {}, {}
for _, m in ipairs(Stove.Menus) do
	local label = ("%s (%s)"):format(m.label, tostring(Items[m.output] and Items[m.output].harga or "?"))
	menuValues[#menuValues + 1] = label
	menuByLabel[label] = m.id
	menuDefault[#menuDefault + 1] = label
	menuOn[m.id] = true
end
Kitchen:AddToggle("Cook", {
	Text = "Auto Kitchen",
	Tooltip = "Keeps the stove's queue full with the ticked menus you have ingredients for, best-paying first. Dishes land in the bag",
	Default = false,
	Callback = function(state)
		cookOn = state
		setStations()
	end,
})
Kitchen:AddDropdown("Menus", {
	Text = "Menus",
	Tooltip = "Sale price in brackets",
	Values = menuValues,
	Default = menuDefault,
	Multi = true,
	Callback = function(picked)
		table.clear(menuOn)
		for label in pairs(ticked(picked)) do
			if menuByLabel[label] then
				menuOn[menuByLabel[label]] = true
			end
		end
	end,
})

More:AddToggle("UpShop", {
	Text = "Auto Upgrade Toko",
	Tooltip = "Upgrades the stall (more rack) when you can pay in coins. The level 6 one costs shards and items: left to you",
	Default = false,
	Callback = function(state)
		upShop = state
		setUpgrades()
	end,
})
More:AddToggle("UpPlot", {
	Text = "Auto Upgrade Plot",
	Tooltip = "Presses Upgrade Plot when you can pay its coin price",
	Default = false,
	Callback = function(state)
		upPlot = state
		setUpgrades()
	end,
})
More:AddToggle("Quests", {
	Text = "Auto Claim Quests",
	Tooltip = "Claims finished daily quests",
	Default = false,
	Callback = setQuests,
})

local conns = {}
local note = "idle"
local nextStrip = 0
local c0 = coins()
table.insert(conns, RunService.Heartbeat:Connect(function()
	if pending.now then
		note, pending.now = pending.now, nil
	end
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	pcall(Window.SetStatus, Window, {
		{ "Coins", fmt(coins()) .. (" (%+d)"):format(coins() - c0) },
		{ "Phase", phase() == "Malam" and "night" or "day" },
		{ "Field", fieldNote },
		{ "Harvested", stats.harvested },
		{ "Racked", stats.racked },
		{ "Foraged", stats.foraged },
		{ "Cooked", stats.cooked },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("ForestMarket", {})

task.spawn(function()
	local lastMark, said = mark, false
	while running do
		task.wait(5)
		if mark ~= lastMark then
			lastMark, said = mark, false
		elseif not said and os.clock() - markAt > STUCK_AFTER and busy then
			said = true
			warn(("[forest] stuck %ds at: %s"):format(os.clock() - markAt, mark))
		end
	end
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
	running = false
	setFarm(false)
	setSeeds(false)
	setDupa(false)
	setRack(false)
	setForage(false)
	cookOn, processOn = false, false
	setStations()
	upShop, upPlot = false, false
	setUpgrades() -- hands the game's upgrade dialog back
	setQuests(false)
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().forestMarketStop = nil
end)

getgenv().forestMarketStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().forestMarketStop = nil
end

log("loaded; " .. #SEEDS .. " seeds, " .. #FORAGE .. " forage items, phase " .. phase())
