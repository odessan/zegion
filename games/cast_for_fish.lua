--[[ Cast for Fish -- remote casts from the dock, best fish on the plot, gear and capacity buys, freebies (131424283721618)

     CAST     : glides you onto the dock once, then Cast(20) every 2.05s straight through the remote. The server
                rolls the fish on the call itself, so there is no meter, no reel, no cutscene; each cast also pays
                training XP (10 reps x your dumbbell's XP), about 3x what standing in the training circle pays.
                The game's aim screen opens by itself on the dock and is closed after every cast.
     TRAIN    : glides into your plot's training circle, Train(true), and presses the 2x bonus the moment the
                server offers it (only offered while training: 3.5s to press, 5s of double reps). The server ends
                training the moment you leave the circle, so with CAST on too the two alternate: "Cast for" seconds
                on the dock, "Train for" seconds in the circle. Measured 2026-11-22 (Magma dumbbell, zone 9):
                training 594 XP/s, casting 946 XP/s plus a fish per cast.
     LUCKY    : casts with useLucky while you have Lucky Casts (100x luck each). Off = they stay saved.
     SELL     : Equip Best (fills the plot slots with your best fish, works from anywhere), then Sell All on
                what is left in the backpack, every few casts. Sold fish still count in the index. Rebirth fish
                (Fish.endgame: Tidefather .. Khaos) are never sold: Rebirth needs one in the backpack or on the
                plot, so with one in the backpack the rest go one by one through SellFish instead.
     CAPACITY : UpgradeCapacity (no button calls it; the prompt on the sign does) the moment cash covers it.
     GEAR     : the best rod and bait you can afford (tiers can be skipped, buying equips), and the next dumbbell
                (one tier at a time). Dumbbells raise cast XP too.
     CLAIMS   : index rewards, playtime gifts, daily login, the free fish.
     REBIRTH  : Rebirth() the moment the fish the next rebirth needs (Progression.Rebirths[n].need) is in your
                backpack or on your plot, the game's own ownsFish check. Wipes cash, fish and gear; x2 cash,
                luck and strength each. Off by default. Order: Tidefather, Seraphion, Charybdis, Kronos, Khaos.

     Movement (measured 2026-11-22): a CFrame jump over 5 studs is reverted, a glide held to 3000 studs/s, so
     the one trip (plot -> dock) is a glide. Everything except Cast and Train works from anywhere.

     Probed and dead (do not re-probe):
       Cast meter above 20                 clamped server-side to 20 (METER_MAX)
       Cast faster than 2.0s               "Too fast" (1.9s refused, 2.05s taken; rod speed does not change it)
       Cast off the dock                   "Stand on the dock to cast" (|X| <= 58, Z -7..9.5, Y < 9)
       Train(true) from the dock           TrainState false: only inside your plot's TrainingSpot circle
       Train in the circle, glide to dock  the server ends training on leaving the circle (0 reps on the dock)
       TrainBonus fired unoffered          no effect, same 8 reps / 4s
     Not wired: AutoCast setting (OwnsAutoCast gamepass), lucky-cast packs, crates, gifts, potions (Robux);
       codes (the server wants group 944491240 joined first);
       Cosmic event drops (admin-started only); SetCastLimit
       (a power cap for parking in a lower zone); aquarium, eggs, trade.

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().castFishStop() ]]

-- config ---------------------------------------------------------------------
local CAST_GAP = 2.05 -- seconds between casts (server cooldown 2.0); raise if "Too fast" shows up
local TOO_FAST_WAIT = 0.4 -- after a "Too fast" refusal, before the next try
local METER = 20 -- the server clamps the meter to 20 (perfect)
local DOCK_POS = Vector3.new(0, 3, 2) -- middle of the dock; the cast check is |X| <= 58, Z -7..9.5
local GLIDE_SPEED = 600 -- studs/s (3000 held when measured); lower if the glide gets pulled back
local DOCK_SETTLE = 0.4 -- after arriving, before the first cast
local CAST_FOR = 30 -- default seconds of casting per cycle when Train is on too (panel box)
local TRAIN_FOR = 30 -- default seconds of training per cycle when Cast is on too (panel box)
local TRAIN_RETRY = 1 -- seconds between Train(true) calls while the server has not said TrainState true
local BONUS_DELAY = 0.2 -- after the 2x offer shows, before pressing it
local MANAGE_EVERY = 5 -- casts between Equip Best + Sell All
local BAG_HIGH = 80 -- manage at once when the backpack reaches this (limit 100)
local SPEND_EVERY = 3 -- seconds between buy passes
local SPEND_BACKOFF = 60 -- a buy the server refused is not retried for this long
local CLAIM_EVERY = 60
local REBIRTH_EVERY = 5 -- seconds between "do I hold the next rebirth fish" checks
local REBIRTH_BACKOFF = 60 -- after a refused rebirth
local DAILY_EVERY = 600
local INVOKE_TIMEOUT = 8 -- an InvokeServer that has not answered by now is abandoned
local STUCK_AFTER = 90 -- the watchdog prints a loop whose breadcrumb has not moved for this long

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().castFishStop then
	getgenv().castFishStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[castfish]", ...)
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
	local mods = player:WaitForChild("PlayerScripts"):WaitForChild("Client"):WaitForChild("Modules")
	local data = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data")
	return {
		DC = require(mods:WaitForChild("DataClient")),
		CC = require(mods:WaitForChild("CastController")),
		Game = require(ReplicatedStorage.Shared:WaitForChild("GameConfig")),
		Rods = require(data:WaitForChild("Rods")),
		Baits = require(data:WaitForChild("Baits")),
		Dumbbells = require(data:WaitForChild("Dumbbells")),
		Progression = require(data:WaitForChild("Progression")),
		Fish = require(data:WaitForChild("Fish")),
	}
end)
if not Remotes or not okM then
	warn("[castfish] the game's modules did not load:", M)
	return
end
local R = {}
for _, n in ipairs({ "Cast", "Train", "TrainState", "TrainRep", "TrainBonus", "EquipBest", "SellAll", "SellFish", "UpgradeCapacity", "BuyRod", "EquipRod", "BuyBait", "EquipBait", "BuyDumbbell", "ClaimIndexReward", "ClaimGift", "ClaimDaily", "ClaimFreeFish", "Rebirth" }) do
	R[n] = Remotes:WaitForChild(n, 15)
	if not R[n] then
		warn("[castfish] remote missing (game update?):", n)
		return
	end
end

-- Cash passes 1e57 within an hour of farming, so the list runs well past Dc.
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
assert(fmt(4.56e57) == "4.56Ocd", "fmt high")

-- InvokeServer has no timeout; a handler that never answers would park the loop forever.
-- Returns the reply as-is (this game answers true / false / a table), or nil plus why.
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
-- A reply counts as success when it is true or a table with ok = true.
local function succeeded(res)
	return res == true or (type(res) == "table" and res.ok == true)
end
local function why(res, err)
	if type(res) == "table" then
		return tostring(res.reason or res.message or "refused")
	end
	return tostring(err or res)
end

local function get(key)
	local ok, v = pcall(M.DC.Get, key)
	return ok and v or nil
end
local function cash()
	return tonumber(get("Cash")) or 0
end
local function bagCount()
	local b = get("Backpack")
	return type(b) == "table" and #b or 0
end

local stats = { casts = 0, lucky = 0, refused = 0, sold = 0, bought = 0, last = "-", zone = "-", reps = 0, bonuses = 0 }

-- world ----------------------------------------------------------------------
local function root()
	local c = player.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	local r = c and c:FindFirstChild("HumanoidRootPart")
	if r and h and h.Health > 0 then
		return r
	end
	return nil
end

-- The client's own dock test (CastController), which is also the server's.
local function onDock(p)
	return math.abs(p.X) <= M.Game.LANE_HALF_WIDTH - 2 and p.Z <= 9.5 and p.Z >= M.Game.DOCK_Z - 1 and p.Y < 9 and p.Y > -1
end

-- A CFrame jump over 5 studs is reverted; a glide is not. Velocity zeroed so gravity can't drag the line.
local function glideTo(pos)
	local r = root()
	if not r then
		return false
	end
	local from = r.Position
	local total = (pos - from).Magnitude
	local done = 0
	while done < total do
		local dt = RunService.Heartbeat:Wait()
		r = root()
		if not r then
			return false
		end
		done = math.min(total, done + GLIDE_SPEED * dt)
		r.CFrame = CFrame.new(from:Lerp(pos, total > 0 and done / total or 1))
		r.AssemblyLinearVelocity = Vector3.zero
	end
	task.wait(DOCK_SETTLE)
	r = root()
	return r ~= nil and (r.Position - pos).Magnitude < 6
end

local function closeAim()
	pcall(M.CC.Exit) -- the dock opens the game's aim screen (WalkSpeed 0) and our remote cast never closes it
end

-- The training circle on your own plot; the client's start check is within 4.3 studs flat, 12 up/down.
local function circlePos()
	local plots = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Plots")
	local plot = plots and plots:FindFirstChild("Plot" .. tostring(player:GetAttribute("PlotId")))
	local spot = plot and plot:FindFirstChild("TrainingSpot")
	if not spot then
		return nil
	end
	local c = spot:FindFirstChild("Center")
	local p = c and c.Position or spot:GetPivot().Position
	return Vector3.new(p.X, p.Y + 3, p.Z)
end
local function inCircle(p, c)
	return Vector2.new(p.X - c.X, p.Z - c.Z).Magnitude <= 4 and math.abs(p.Y - c.Y) < 10
end

-- fish -----------------------------------------------------------------------
local on = {}
local conns = {}
local running = true

-- Backpack -> uids to sell, names to keep. A fish whose config has `endgame` is rebirth material.
local function splitBag(bag, byId)
	local sell, keep = {}, {}
	for _, f in ipairs(type(bag) == "table" and bag or {}) do
		local def = byId[f.id]
		if def and (tonumber(def.endgame) or 0) > 0 then
			table.insert(keep, tostring(def.name or f.id))
		else
			table.insert(sell, f.uid)
		end
	end
	return sell, keep
end
do
	local byId = { tidefather = { name = "The Tidefather", endgame = 1 }, cod = { name = "Cod" } }
	local s, k = splitBag({ { uid = 1, id = "cod" }, { uid = 2, id = "tidefather" }, { uid = 3, id = "nope" } }, byId)
	assert(#s == 2 and s[1] == 1 and s[2] == 3 and #k == 1 and k[1] == "The Tidefather", "splitBag")
end

local function manage()
	step("fish", "equip best")
	local eb, ebErr = invoke(R.EquipBest)
	if not succeeded(eb) then
		first("equip best refused", why(eb, ebErr))
	end
	if bagCount() == 0 then
		return
	end
	local before = cash()
	local sell, keep = splitBag(get("Backpack"), M.Fish.ById)
	if #keep == 0 then
		step("fish", "sell all")
		local n = bagCount()
		local s, sErr = invoke(R.SellAll)
		if succeeded(s) then
			stats.sold += n
			say(("sold %d fish (+%s)"):format(n, fmt(cash() - before)))
		else
			say("sell all refused: " .. why(s, sErr))
		end
		return
	end
	first("rebirth fish kept", table.concat(keep, ", "))
	local n = 0
	for _, uid in ipairs(sell) do
		step("fish", "sell " .. tostring(uid))
		local s, sErr = invoke(R.SellFish, uid)
		if succeeded(s) then
			n += 1
		else
			say(("sell fish %s refused: %s"):format(tostring(uid), why(s, sErr)))
		end
	end
	stats.sold += n
	say(("sold %d fish (+%s), kept %s for rebirth"):format(n, fmt(cash() - before), table.concat(keep, ", ")))
end

local sinceManage = 0
local function castOnce()
	local r = root()
	if not r then
		step("fish", "no character")
		task.wait(1)
		return
	end
	if not onDock(r.Position) then
		step("fish", "glide to dock")
		say("gliding to the dock")
		if not glideTo(DOCK_POS) then
			local p = root() and root().Position
			say("glide did not land on the dock (at " .. tostring(p) .. ")")
			task.wait(2)
			return
		end
	end
	local useLucky = on.lucky and (tonumber(get("LuckyCasts")) or 0) > 0
	step("fish", "cast")
	local res, err = invoke(R.Cast, METER, useLucky)
	closeAim()
	if type(res) == "table" and res.ok then
		stats.casts += 1
		if res.lucky then
			stats.lucky += 1
		end
		stats.zone = tostring(res.zoneIndex or "-")
		stats.last = ("%s %s"):format(tostring(res.rarity or "?"), tostring(res.name or res.fishId or "?"))
		say(("%s%s, zone %s, power %s"):format(res.lucky and "LUCKY " or "", stats.last, stats.zone, fmt(res.power)))
		sinceManage += 1
		if on.sell and (sinceManage >= MANAGE_EVERY or bagCount() >= BAG_HIGH) then
			sinceManage = 0
			manage()
		end
		step("fish", "cooldown")
		task.wait(CAST_GAP)
	else
		stats.refused += 1
		local reason = why(res, err)
		if reason == "Too fast" then
			task.wait(TOO_FAST_WAIT)
		else
			say("cast refused: " .. reason)
			if bagCount() >= M.Game.BACKPACK_LIMIT and on.sell then
				manage()
			end
			task.wait(1)
		end
	end
end

-- train ----------------------------------------------------------------------
local training = false -- the server's last TrainState
local trainAsked = 0
local function trainTick()
	local c = circlePos()
	local r = root()
	if not c or not r then
		step("fish", "no circle / character")
		task.wait(1)
		return
	end
	if not inCircle(r.Position, c) then
		step("fish", "glide to circle")
		say("gliding to the training circle")
		if not glideTo(c) then
			say("glide did not land in the circle (at " .. tostring(root() and root().Position) .. ")")
			task.wait(2)
			return
		end
	end
	if not training and os.clock() - trainAsked > TRAIN_RETRY then
		trainAsked = os.clock()
		step("fish", "train start")
		R.Train:FireServer(true)
	end
	step("fish", "training")
	task.wait(0.25)
end

local function stopTraining()
	if training or trainAsked > 0 then
		trainAsked = 0
		pcall(R.Train.FireServer, R.Train, false)
	end
end

table.insert(
	conns,
	R.TrainState.OnClientEvent:Connect(function(state)
		training = state == true
	end)
)
table.insert(
	conns,
	R.TrainRep.OnClientEvent:Connect(function()
		stats.reps += 1
	end)
)
-- The 2x offer only comes while training; the button just fires TrainBonus, so press it for you.
table.insert(
	conns,
	R.TrainBonus.OnClientEvent:Connect(function(kind)
		if kind == "offer" and on.train and training then
			task.delay(BONUS_DELAY, function()
				pcall(R.TrainBonus.FireServer, R.TrainBonus)
			end)
		elseif kind == "active" then
			stats.bonuses += 1
			say("2x training bonus active")
		end
	end)
)

-- worker ---------------------------------------------------------------------
-- One thread owns the character. Both on: castFor seconds on the dock, then trainFor in the circle.
local castFor, trainFor = CAST_FOR, TRAIN_FOR
local phase, phaseEnds = "train", 0 -- flips to "cast" on the first pass
local mode = "off"

local function pickMode(now)
	if on.cast and on.train then
		if now >= phaseEnds then
			phase = phase == "cast" and "train" or "cast"
			phaseEnds = now + (phase == "cast" and castFor or trainFor)
		end
		return phase
	end
	return on.cast and "cast" or on.train and "train" or "off"
end

task.spawn(function()
	while running do
		local m = pickMode(os.clock())
		if m ~= mode then
			if mode == "train" then
				stopTraining()
			end
			mode = m
			if m ~= "off" then
				say("now " .. (m == "cast" and "casting" or "training"))
			end
		end
		if m == "cast" then
			castOnce()
		elseif m == "train" then
			trainTick()
		else
			step("fish", "off")
			task.wait(0.3)
		end
	end
	stopTraining()
end)

-- spend ----------------------------------------------------------------------
local parked = {} -- kind -> os.clock() before which a refused buy is not retried

local function buy(kind, remote, label, ...)
	if (parked[kind] or 0) > os.clock() then
		return false
	end
	local res, err = invoke(remote, ...)
	if succeeded(res) then
		stats.bought += 1
		say("bought " .. label)
		return true
	end
	parked[kind] = os.clock() + SPEND_BACKOFF
	say(("%s refused (%s): waiting %ds"):format(label, why(res, err), SPEND_BACKOFF))
	return false
end

-- The highest-order entry in `list` that is affordable and above the equipped one. Owned but not equipped
-- (bought earlier, or a better one from a gift) comes back too: it only needs an equip.
local function bestTier(list, equippedId, owned, money)
	local eqOrder = 0
	for _, d in ipairs(list) do
		if d.id == equippedId then
			eqOrder = d.order or 0
		end
	end
	local best
	for _, d in ipairs(list) do
		local mine = (owned and owned[d.id]) or (tonumber(d.price) or 0) <= 0
		if (d.order or 0) > eqOrder and (mine or (tonumber(d.price) or math.huge) <= money) then
			if not best or (d.order or 0) > (best.order or 0) then
				best = d
			end
		end
	end
	return best, best and ((owned and owned[best.id]) or (tonumber(best.price) or 0) <= 0)
end
do
	local L = { { id = "a", order = 1, price = 0 }, { id = "b", order = 2, price = 10 }, { id = "c", order = 3, price = 100 } }
	assert(bestTier(L, "a", {}, 50).id == "b", "bestTier affordable")
	assert(bestTier(L, "b", {}, 50) == nil, "bestTier none above")
	local b, owned = bestTier(L, "a", { c = true }, 0)
	assert(b.id == "c" and owned, "bestTier owned")
end

local function spendPass()
	if on.capacity then
		local lvl = tonumber(get("CapacityLevel")) or 1
		local price = M.Game.CAPACITY_PRICES[lvl]
		if price and cash() >= price then
			step("light", "capacity " .. lvl)
			buy("capacity", R.UpgradeCapacity, ("capacity level %d (%s)"):format(lvl + 1, fmt(price)))
		end
	end
	if on.gear then
		local rod, rodOwned = bestTier(M.Rods.List, get("EquippedRod"), get("RodsOwned"), cash())
		if rod then
			step("light", "rod " .. rod.id)
			if rodOwned then
				buy("rod", R.EquipRod, "equip " .. tostring(rod.name), rod.id)
			else
				buy("rod", R.BuyRod, ("%s (%s)"):format(tostring(rod.name), fmt(rod.price)), rod.id)
			end
		end
		local bait, baitOwned = bestTier(M.Baits.List, get("EquippedBait"), get("BaitsOwned"), cash())
		if bait then
			step("light", "bait " .. bait.id)
			if baitOwned then
				first("bait equip", bait.id)
				buy("bait", R.EquipBait, "equip " .. tostring(bait.name), bait.id)
			else
				buy("bait", R.BuyBait, ("%s (%s)"):format(tostring(bait.name), fmt(bait.price)), bait.id)
			end
		end
		local nextDb = M.Dumbbells.List[(tonumber(get("DumbbellTier")) or 0) + 1]
		if nextDb and cash() >= (tonumber(nextDb.price) or math.huge) then
			step("light", "dumbbell " .. nextDb.id)
			buy("dumbbell", R.BuyDumbbell, ("%s (%s)"):format(tostring(nextDb.name), fmt(nextDb.price)))
		end
	end
end

-- claims ---------------------------------------------------------------------
local claimed = { index = {}, gift = {} }
local freeFishTried = false
local nextDaily = 0

local function indexCount()
	local idx = get("Index")
	local n = 0
	if type(idx) == "table" then
		for k in pairs(idx) do
			if k ~= "_" then
				n += 1
			end
		end
	end
	return n
end

local function claimPass()
	local have = indexCount()
	for i, row in ipairs(M.Progression.IndexRewards or {}) do
		if not claimed.index[i] and (tonumber(row.at) or math.huge) <= have then
			step("light", "index reward " .. i)
			local res, err = invoke(R.ClaimIndexReward, i)
			local w = why(res, err)
			if succeeded(res) then
				claimed.index[i] = true
				say("index reward " .. i .. ": " .. tostring(type(res) == "table" and res.text or "claimed"))
			elseif w:lower():find("already") or w:lower():find("claimed") then
				claimed.index[i] = true
			else
				first("index reward refused", i, w)
			end
			task.wait(0.3)
		end
	end
	-- gifts unlock in order of playtime: walk forward past the opened ones, stop at the first not ready
	for i = 1, #(M.Progression.Gifts or {}) do
		if not claimed.gift[i] then
			step("light", "gift " .. i)
			local res, err = invoke(R.ClaimGift, i)
			local w = why(res, err)
			if succeeded(res) then
				claimed.gift[i] = true
				say("playtime gift " .. i .. " opened")
			elseif w:lower():find("already") then
				claimed.gift[i] = true
			else
				first("gift not ready", i, w)
				break
			end
			task.wait(0.3)
		end
	end
	if os.clock() >= nextDaily then
		nextDaily = os.clock() + DAILY_EVERY
		step("light", "daily")
		local res = invoke(R.ClaimDaily)
		if succeeded(res) then
			say("daily login claimed")
		end
	end
	if not freeFishTried and get("FreeFishClaimed") == false then
		freeFishTried = true
		step("light", "free fish")
		local res, err = invoke(R.ClaimFreeFish)
		say("free fish: " .. (succeeded(res) and "claimed" or why(res, err)))
	end
end

-- rebirth --------------------------------------------------------------------
-- The game's own test (ProgressionUI ownsFish): the needed fish in the backpack or on the plot.
local function ownsFish(id)
	for _, key in ipairs({ "Backpack", "Placed" }) do
		local list = get(key)
		for _, f in ipairs(type(list) == "table" and list or {}) do
			if f.id == id then
				return true
			end
		end
	end
	return false
end
local function nextRebirth()
	return M.Progression.Rebirths[(tonumber(get("Rebirths")) or 0) + 1]
end
local function rebirthName()
	local nxt = nextRebirth()
	local def = nxt and M.Fish.ById[nxt.need]
	return nxt and tostring(def and def.name or nxt.need) or "max"
end

local rebirthAt = 0
local function rebirthPass()
	local nxt = nextRebirth()
	if not nxt or os.clock() < rebirthAt or not ownsFish(nxt.need) then
		return
	end
	local n = (tonumber(get("Rebirths")) or 0) + 1
	step("light", "rebirth " .. n)
	first("rebirth", n, nxt.need)
	local res, err = invoke(R.Rebirth)
	if succeeded(res) then
		table.clear(parked) -- prices start over with the cash
		say(("REBIRTH %d done with %s: x%s cash / luck / strength"):format(n, tostring(nxt.need), tostring(nxt.cash)))
	else
		rebirthAt = os.clock() + REBIRTH_BACKOFF
		say(("rebirth %d refused (%s): waiting %ds"):format(n, why(res, err), REBIRTH_BACKOFF))
	end
end

-- light ----------------------------------------------------------------------
-- Things the server takes from anywhere: no character, so they run beside the cast loop.
task.spawn(function()
	local nextSpend, nextClaim, nextReb = 0, 0, 0
	while running do
		local now = os.clock()
		step("light", "tick")
		if on.rebirth and now >= nextReb then
			nextReb = now + REBIRTH_EVERY
			rebirthPass()
		end
		if (on.capacity or on.gear) and now >= nextSpend then
			nextSpend = now + SPEND_EVERY
			spendPass()
		end
		if on.claims and now >= nextClaim then
			nextClaim = now + CLAIM_EVERY
			claimPass()
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
			if age > STUCK_AFTER and told[loop] ~= c.at and c.mark ~= "off" then
				told[loop] = c.at
				warn(("[castfish] %s stuck %ds at: %s"):format(loop, math.floor(age), c.mark))
			end
		end
		task.wait(5)
	end
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Cast for Fish", statusBar = true })
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

Core:AddToggle("Cast", {
	Text = "Auto Cast",
	Tooltip = "Glides you onto the dock, then a perfect cast every 2.05s through the remote (no meter, no cutscene)",
	Default = false,
	Callback = flag("cast"),
})
Core:AddToggle("Train", {
	Text = "Auto Train",
	Tooltip = "Trains in your plot's circle and presses the 2x bonus. With Auto Cast on too, the two take turns",
	Default = false,
	Callback = flag("train"),
})
local function seconds(apply)
	return function(text)
		local v = tonumber(text)
		if v and v >= 5 then
			apply(v)
		end
	end
end
Core:AddInput("CastFor", {
	Text = "Cast for (s, when both on)",
	Default = tostring(CAST_FOR),
	Numeric = true,
	Finished = true,
	Callback = seconds(function(v)
		castFor = v
	end),
})
Core:AddInput("TrainFor", {
	Text = "Train for (s, when both on)",
	Default = tostring(TRAIN_FOR),
	Numeric = true,
	Finished = true,
	Callback = seconds(function(v)
		trainFor = v
	end),
})
Core:AddToggle("Sell", {
	Text = "Equip Best + Sell Rest",
	Tooltip = "Every 5 casts: Equip Best fills your plot with the best fish, then Sell All sells the backpack",
	Default = false,
	Callback = flag("sell"),
})
Core:AddToggle("Lucky", {
	Text = "Use Lucky Casts",
	Tooltip = "Casts with your Lucky Casts (100x luck) while you have any. Off keeps them saved",
	Default = false,
	Callback = flag("lucky"),
})
Spend:AddToggle("Capacity", {
	Text = "Auto Upgrade Capacity",
	Tooltip = "+2 plot slots per level, bought the moment cash covers it (works from anywhere)",
	Default = false,
	Callback = flag("capacity"),
})
Spend:AddToggle("Gear", {
	Text = "Auto Buy Rod / Bait / Dumbbell",
	Tooltip = "Best rod and bait you can afford (skips tiers, equips), and the next dumbbell. Dumbbells raise cast XP",
	Default = false,
	Callback = flag("gear"),
})
Spend:AddToggle("Rebirth", {
	Text = "Auto Rebirth",
	Tooltip = "Rebirths the moment you hold the fish it needs (backpack or plot). Wipes cash, fish and gear; x2 cash, luck, strength",
	Default = false,
	Callback = flag("rebirth"),
})
Extra:AddToggle("Claims", {
	Text = "Auto Claim Freebies",
	Tooltip = "Index rewards, playtime gifts, daily login, the free fish",
	Default = false,
	Callback = flag("claims"),
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
		pcall(Window.SetStatus, Window, {
			{ "Cash", fmt(cash()) },
			{ "Income", fmt(player:GetAttribute("IncomePerSecond")) .. "/s" },
			{ "Power", fmt(get("CastPower")) },
			{ "Zone", stats.zone },
			{ "Mode", mode == "off" and "off" or mode .. (on.cast and on.train and (" %ds"):format(math.max(0, phaseEnds - now)) or "") },
			{ "Casts", ("%d (%d lucky)"):format(stats.casts, stats.lucky) },
			{ "Reps", ("%d (%d x2)"):format(stats.reps, stats.bonuses) },
			{ "Lucky left", tostring(get("LuckyCasts") or 0) },
			{ "Rebirth", ("%d, next needs %s"):format(tonumber(get("Rebirths")) or 0, rebirthName()) },
			{ "Bag", ("%d/%d"):format(bagCount(), M.Game.BACKPACK_LIMIT) },
			{ "Now", note },
		})
	end)
)

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

Window:AddSettingsTab("CastForFish", {})

-- The game's AntiAfk asks the server to rejoin you after 18 idle minutes; a click on Idled resets the clock.
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
	stopTraining()
	closeAim()
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().castFishStop = nil
end)

getgenv().castFishStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().castFishStop = nil
end
