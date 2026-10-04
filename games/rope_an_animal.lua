--[[ Rope an Animal -- lasso, ride home, equip, sell, upgrade, train (140067658687251)

     CATCH   : teleports next to the best wild animal you allow, throws the lasso (the game's
               MonsterCatch/Lasso remote; the server mounts you at once), then holds a real W key
               with the camera aimed down the road until you cross the start line and the animal is
               yours. About 2s an animal. Probed: Lasso needs the Lasso Tool held; a teleport while
               mounted is undone by the server, so the ride itself cannot be skipped.
               Pick by rarity and/or by name. A zone whose guardian is too fast for your Speed is
               skipped (the config's GuardianRequiredSpeedByZone), and a zone that knocks you off
               twice is parked for a while.
     EQUIP   : the game's own Equip Best (PenAction). After a catch, and every EQUIP_EVERY.
     SELL    : spare animals of the rarities you tick, only once every pad is full and never one
               better than your weakest pad.
     UPGRADE : cheapest affordable of the next pen level or the next treadmill (cash route only).
     TRAIN   : holds your treadmill on its mat so Speed grows. Pauses while Catch is on (the lasso
               needs your hand).
     CLAIM   : daily reward, playtime rewards, Index rewards, free daily egg.

     Probed and dead (do not re-probe):
       Humanoid:Move while mounted     overwritten every frame by the control script; use a W key press
       PivotTo across the line mounted the server snaps you back to the animal
       Pad coins                       accrue on their own (~no claim needed)
     Not wired: Robux (MoreSpeed, BuyTreadmillRobux, paid random), Dragon event (needs a trace of the boss).

     RightControl opens / closes the panel. Stop: getgenv().ropeAnimalStop() ]]

-- config ---------------------------------------------------------------------
local SETTLE = 0.5 -- after a teleport, before the throw. Lower and the server may not see you in range yet
local TP_TRIES = 3 -- a teleport that did not land is repeated this many times before the animal is given up on
local TP_SIDE = 20 -- land this far on the base side of the animal; the ride then runs straight at the line
local MOUNT_WAIT = 2 -- the lasso must mount you inside this
local RIDE_MAX = 20 -- a ride still running after this is released
local PICK_GAP = 0.25 -- idle beat when nothing is worth catching
local PARK_REFUSED = 20 -- an animal that refused the lasso is left alone this long
local PARK_USED = 120 -- an animal already ridden is not picked again for this long
local RESULT_WAIT = 0.8 -- after the ride, how long to wait for the server's Captured before calling it lost
local ZONE_STRIKES = 2 -- guardian knock-offs in one zone before it is parked
local ZONE_PARK = 90 -- ...for this long
local EQUIP_GAP = 2 -- at least this long between Equip Best presses
local EQUIP_EVERY = 30 -- press anyway this often
local SELL_EVERY = 3
local UPGRADE_EVERY = 2
local UPGRADE_BACKOFF = 15 -- a purchase the server did not take is not retried for this long
local CLAIM_EVERY = 30
local INDEX_EVERY = 90
local DATA_AGE = 1.5 -- cached profile reads are reused this long
local CALL_WAIT = 4 -- an InvokeServer is given up on after this
local STUCK_AFTER = 40 -- the watchdog names the step the script has been in this long

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser = game:GetService("VirtualUser")
local player = Players.LocalPlayer

if getgenv and getgenv().ropeAnimalStop then
	getgenv().ropeAnimalStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[rope]", ...)
end

local seen = {}
local function first(name, ...) -- one line per unproven branch, the first time it is reached
	if not seen[name] then
		seen[name] = true
		log("first:", name, ...)
	end
end

-- The panel strip is drained from a Heartbeat (a resumed thread loses capability and throws on
-- its second write to the window).
local pending = {}
local function say(msg, slot)
	pending[slot or "now"] = msg
end

-- breadcrumb + watchdog: a parked yield leaves no error, only a step name that stops moving
local mark, markAt = "start", os.clock()
local function step(name)
	mark, markAt = name, os.clock()
end

-- game -----------------------------------------------------------------------
local Link = ReplicatedStorage:WaitForChild("ConsPackages", 15) and ReplicatedStorage.ConsPackages:WaitForChild("Link", 15)
local ok, MonsterCatchConfig, AnimalData, IslandConfig, PadIncome, BaseUpgradeConfig, TreadmillData, Rewards = pcall(function()
	return require(ReplicatedStorage.Configs.MonsterCatchConfig),
		require(ReplicatedStorage.Data.AnimalData),
		require(ReplicatedStorage.Configs.IslandConfig),
		require(ReplicatedStorage.Modules.PadIncome),
		require(ReplicatedStorage.Configs.BaseUpgradeConfig),
		require(ReplicatedStorage.Data.TreadmillData),
		require(ReplicatedStorage.Balance.Rewards)
end)
if not Link or not ok then
	warn("[rope] the game's modules did not load:", MonsterCatchConfig)
	return
end
local RE, RF = Link:WaitForChild("RemoteEvents"), Link:WaitForChild("RemoteFunctions")
local Lasso, Release, PenAction = RE["MonsterCatch/Lasso"], RE["MonsterCatch/Release"], RE.PenAction
local Sell, UpgradeBase = RE.SellAnimals, RE.UpgradeBase
local BuyTreadmill, EquipTreadmill = RE.BuyTreadmillCash, RE.EquipTreadmill
local ProfileData = ReplicatedStorage:WaitForChild("__SincyRemotes__"):WaitForChild(player.Name):WaitForChild("GetData")
local CHECKPOINT = workspace:WaitForChild("RoadMap"):WaitForChild(MonsterCatchConfig.CheckpointName)

local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret", "Cosmic", "Divine", "Alien", "Exclusive" }

-- an InvokeServer has no timeout and a parked thread looks exactly like a dead farm, so give up on a clock
local function callTimed(fn, ...)
	local args, n = { ... }, select("#", ...)
	local done, res = false, nil
	task.spawn(function()
		local good, r = pcall(function()
			return fn(table.unpack(args, 1, n))
		end)
		res = good and r or nil
		done = true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < CALL_WAIT do
		task.wait(0.05)
	end
	return done and res or nil
end

local profile, profileAt = nil, 0
local function getData(maxAge)
	if profile and os.clock() - profileAt < (maxAge or DATA_AGE) then
		return profile
	end
	local d = callTimed(function()
		return ProfileData:InvokeServer()
	end)
	if type(d) == "table" then
		profile, profileAt = d, os.clock()
	end
	return profile
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
	local i = 1
	while n >= 1000 and i < #SUFFIX do
		n /= 1000
		i += 1
	end
	return ("%.3g"):format(n) .. SUFFIX[i]
end
assert(fmt(25000) == "25K" and fmt(1500) == "1.5K" and fmt(100) == "100", "fmt")

-- the species the zones spawn, for the name picker
local SPECIES = {}
for _, island in ipairs(IslandConfig.Order) do
	for _, name in ipairs(IslandConfig.Rosters[island] or {}) do
		SPECIES[#SPECIES + 1] = name
	end
end

local function character()
	local c = player.Character
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	if hum and hrp and hum.Health > 0 then
		return c, hum, hrp
	end
	return nil
end

local function toolOfKind(kind)
	for _, holder in ipairs({ player.Character, player:FindFirstChildOfClass("Backpack") }) do
		if holder then
			for _, t in ipairs(holder:GetChildren()) do
				if t:IsA("Tool") and t:GetAttribute("Kind") == kind then
					return t
				end
			end
		end
	end
	return nil
end

local function equip(kind)
	local t = toolOfKind(kind)
	local _, hum = character()
	if not t or not hum then
		return false
	end
	if t.Parent ~= player.Character then
		pcall(hum.EquipTool, hum, t)
		task.wait(0.3)
	end
	return t.Parent == player.Character
end

-- Two loops move your character (Catch, and the Claim loop's trip to the daily egg), so one claims
-- it at a time. A real flag with nothing yielding between the check and the set.
local moving = false
local function withCharacter(fn, ...)
	while moving do
		task.wait()
	end
	moving = true
	local good, err = pcall(fn, ...)
	moving = false
	if not good then
		warn("[rope] character task failed:", err)
	end
end

-- catch ----------------------------------------------------------------------
local stats = { caught = 0, lost = 0, refused = 0 }
local genCatch, catchOn = 0, false
local rarityOn, nameOn, respectSpeed = {}, {}, true
local parked, zoneStrikes, zonePark = {}, {}, {}
local lastResult, resultSeq = nil, 0
local caughtSeq = 0 -- bumped on every Captured, so Equip knows to run

local resultCon = RE["MonsterCatch/Result"].OnClientEvent:Connect(function(kind, arg)
	resultSeq += 1
	lastResult = { kind = kind, arg = arg, seq = resultSeq }
	if kind == "Captured" then
		caughtSeq += 1
	end
end)

local function busy()
	return player:GetAttribute("MonsterCatchBusy") == true
end

local function targetInfo(m)
	local name = m.Name
	local island = IslandConfig.GetSpeciesIslandIndex(name) or 1
	local rarity = AnimalData:GetRarity(name) or "Common"
	local weight = m:GetAttribute("WeightKg")
	local income = PadIncome.GetTotal(name, 1, nil, 1, weight)
	return name, island, rarity, income
end

local function pickTarget(hrpPos, speed)
	local best, bestScore = nil, -1
	local line = CHECKPOINT.Position.X
	local now = os.clock()
	local anyName = next(nameOn) ~= nil
	for _, m in ipairs(workspace:GetChildren()) do
		local key = m:IsA("Model") and m:GetAttribute("MonsterCatchKey")
		if key and not m:GetAttribute("MonsterGuardian") and not m.Name:find("Egg", 1, true) and (parked[key] or 0) < now then
			local pos = m:GetPivot().Position
			if pos.X < line - 4 and pos.Magnitude > 1 then
				local name, island, rarity, income = targetInfo(m)
				local need = MonsterCatchConfig.GuardianRequiredSpeedByZone[island] or 0
				local allowed = rarityOn[rarity] and (not anyName or nameOn[name]) and (zonePark[island] or 0) < now and (not respectSpeed or not speed or speed >= need)
				if allowed then
					local score = income - (hrpPos - pos).Magnitude * 1e-6 -- income first, nearer on a tie
					if score > bestScore then
						best, bestScore = m, score
					end
				end
			end
		end
	end
	return best
end

local aimBound = false
local function aim(on, hrp)
	if on and not aimBound then
		aimBound = true
		RunService:BindToRenderStep("ropeAnimalAim", Enum.RenderPriority.Camera.Value + 1, function()
			local _, _, r = character()
			if r then
				workspace.CurrentCamera.CFrame = CFrame.lookAt(r.Position + Vector3.new(-12, 8, 0), r.Position + Vector3.new(10, 0, 0))
			end
		end)
	elseif not on and aimBound then
		aimBound = false
		pcall(RunService.UnbindFromRenderStep, RunService, "ropeAnimalAim")
	end
end

local function ride(mine)
	local t0 = os.clock()
	step("ride")
	aim(true)
	VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.W, false, game)
	while genCatch == mine and busy() and os.clock() - t0 < RIDE_MAX do
		task.wait()
	end
	VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.W, false, game)
	aim(false)
	if busy() then
		first("ride timeout", os.clock() - t0)
		Release:FireServer()
		task.wait(0.5)
	end
end

local function catchOne(mine)
	local c, _, hrp = character()
	if not c or busy() then
		task.wait(0.3)
		return
	end
	local d = getData()
	local m = pickTarget(hrp.Position, d and d.Speed)
	if not m then
		say("nothing to catch")
		task.wait(PICK_GAP)
		return
	end
	local key = m:GetAttribute("MonsterCatchKey")
	local name, island, rarity, income = targetInfo(m)
	step("equip lasso")
	if not equip("Lasso") then
		say("no lasso tool")
		task.wait(1)
		return
	end
	step("tp " .. name)
	-- the first hop into ground that has not streamed in yet sometimes does not land: try again
	local now
	for try = 1, TP_TRIES do
		local pos = m:GetPivot().Position
		c:PivotTo(CFrame.new(pos + Vector3.new(TP_SIDE, 3, 0)))
		task.wait(SETTLE)
		if genCatch ~= mine or not m.Parent then
			return
		end
		_, _, now = character()
		if now and (now.Position - m:GetPivot().Position).Magnitude <= MonsterCatchConfig.LassoRange - 5 then
			if try > 1 then
				first("tp needed retries", try)
			end
			break
		end
	end
	if not now or (now.Position - m:GetPivot().Position).Magnitude > MonsterCatchConfig.LassoRange - 5 then
		local pos = m:GetPivot().Position
		stats.refused += 1
		parked[key] = os.clock() + PARK_REFUSED
		first("tp did not land", name, now and now.Position, pos)
		return
	end
	step("lasso " .. name)
	say(("%s (%s, $%s/s)"):format(name, rarity, fmt(income)))
	local seq = resultSeq
	Lasso:FireServer(key)
	local t0 = os.clock()
	while not busy() and os.clock() - t0 < MOUNT_WAIT do
		task.wait(0.05)
	end
	if not busy() then
		local why = lastResult and lastResult.seq > seq and lastResult.kind or "no reply"
		stats.refused += 1
		parked[key] = os.clock() + PARK_REFUSED
		first("lasso refused", name, why, "dist", (now.Position - m:GetPivot().Position).Magnitude)
		return
	end
	local before = caughtSeq
	ride(mine)
	-- Captured lands a beat after the busy flag drops, so give it a moment before calling it lost
	local wait0 = os.clock()
	while caughtSeq == before and os.clock() - wait0 < RESULT_WAIT do
		task.wait(0.05)
	end
	parked[key] = os.clock() + PARK_USED -- the animal lingers a moment after the catch; a second lasso on it is Invalid
	local res = lastResult
	if caughtSeq > before then
		stats.caught += 1
	else
		stats.lost += 1
		local kind = res and res.kind or "?"
		first("lost", name, island, kind)
		if kind == "GuardianHit" then
			zoneStrikes[island] = (zoneStrikes[island] or 0) + 1
			if zoneStrikes[island] >= ZONE_STRIKES then
				zoneStrikes[island] = 0
				zonePark[island] = os.clock() + ZONE_PARK
				log("zone", island, "parked", ZONE_PARK, "s: the guardian keeps catching you")
			end
		end
	end
	-- parked keys of animals that are gone
	for k, t in pairs(parked) do
		if t < os.clock() then
			parked[k] = nil
		end
	end
end

local function catchLoop(mine)
	while genCatch == mine do
		withCharacter(catchOne, mine)
		task.wait()
	end
	aim(false)
	pcall(function()
		VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.W, false, game)
	end)
end

local catchToggle, trainToggle
local function setCatch(on)
	genCatch += 1
	catchOn = on
	if on then
		if trainToggle and trainToggle.Value then
			pcall(function()
				trainToggle:SetValue(false) -- both want your hand
			end)
		end
		task.spawn(catchLoop, genCatch)
	else
		say("catch off")
	end
end

-- equip + sell ---------------------------------------------------------------
local genEquip, genSell = 0, 0
local sellOn = {}
local stat = { sold = 0 }

local function equipLoop(mine)
	local lastSeq, lastPress = -1, 0
	while genEquip == mine do
		local now = os.clock()
		if (caughtSeq ~= lastSeq and now - lastPress >= EQUIP_GAP) or now - lastPress >= EQUIP_EVERY then
			lastSeq, lastPress = caughtSeq, now
			step("equip best")
			local before = getData(0)
			PenAction:FireServer("EquipBest")
			first("equip best sent")
			task.wait(1)
			profileAt = 0
			local after = getData(0)
			if before and after then
				local function income(d)
					local sum = 0
					for _, p in pairs(d.Pads or {}) do
						sum += PadIncome.GetTotal(p.AnimalName, p.Level, p.Mutation, 1, p.WeightKg)
					end
					return sum
				end
				local a, b = income(before), income(after)
				if b > a then
					log(("equip best: pad income %s -> %s /s"):format(fmt(a), fmt(b)))
				end
			end
		end
		task.wait(0.5)
	end
end

local function setEquip(on)
	genEquip += 1
	if on then
		task.spawn(equipLoop, genEquip)
	end
end

local function sellPass()
	local d = getData(0)
	if not d or type(d.Animals) ~= "table" or not next(d.Animals) then
		return
	end
	local pads, weakest = 0, math.huge
	for _, p in pairs(d.Pads or {}) do
		pads += 1
		weakest = math.min(weakest, PadIncome.GetTotal(p.AnimalName, p.Level, p.Mutation, 1, p.WeightKg))
	end
	if pads < BaseUpgradeConfig.CapacityForLevel(d.BaseLevel or 0) then
		return -- a free pad: Equip Best places them
	end
	local uids = {}
	for uid, a in pairs(d.Animals) do
		local rarity = AnimalData:GetRarity(a.Name) or "Common"
		local income = PadIncome.GetTotal(a.Name, a.Level, a.Mutation, 1, a.WeightKg)
		if sellOn[rarity] and income <= weakest then
			uids[#uids + 1] = uid
		end
	end
	if #uids == 0 then
		return
	end
	step("sell " .. #uids)
	local coins = d.Coins
	Sell:FireServer(uids)
	first("sell sent", #uids)
	task.wait(1)
	profileAt = 0
	local after = getData(0)
	if after and type(after.Animals) == "table" then
		local gone = 0
		for _, uid in ipairs(uids) do
			if not after.Animals[uid] then
				gone += 1
			end
		end
		stat.sold += gone
		log(("sold %d of %d, coins %s -> %s"):format(gone, #uids, fmt(coins or 0), fmt(after.Coins or 0)))
	end
end

local function sellLoop(mine)
	while genSell == mine do
		local good, err = pcall(sellPass)
		if not good then
			warn("[rope] sell pass failed:", err)
		end
		task.wait(SELL_EVERY)
	end
end

local function setSell(on)
	genSell += 1
	if on then
		task.spawn(sellLoop, genSell)
	end
end

-- upgrade --------------------------------------------------------------------
local genUpgrade = 0
local cool = {}

local function nextTreadmill(d)
	local best
	for name, t in pairs(TreadmillData.Treadmills) do
		if not (d.OwnedTreadmills or {})[name] and (not best or t.Order < best.t.Order) then
			best = { name = name, t = t }
		end
	end
	return best
end

local function upgradePass()
	local d = getData(0.5)
	if not d then
		return false
	end
	local coins = d.Coins or 0
	local cands = {}
	local level = d.BaseLevel or 0
	if level < BaseUpgradeConfig.MaxLevel and (cool.base or 0) < os.clock() then
		local cost = BaseUpgradeConfig.CostFor(level)
		if cost > 0 and coins >= cost then
			cands[#cands + 1] = { cost = cost, label = "pen level " .. (level + 1), key = "base", do_ = function()
				UpgradeBase:FireServer()
				task.wait(1)
				profileAt = 0
				local after = getData(0)
				return after and (after.BaseLevel or 0) > level
			end }
		end
	end
	local tm = nextTreadmill(d)
	if tm and (cool[tm.name] or 0) < os.clock() and tm.t.Price <= coins then
		cands[#cands + 1] = { cost = tm.t.Price, label = tm.t.DisplayName, key = tm.name, do_ = function()
			BuyTreadmill:FireServer(tm.name) -- cash route; BuyTreadmillRobux is never touched
			task.wait(1)
			profileAt = 0
			local after = getData(0)
			local got = after and (after.OwnedTreadmills or {})[tm.name]
			if got then
				EquipTreadmill:FireServer(tm.name)
			end
			return got
		end }
	end
	table.sort(cands, function(a, b)
		return a.cost < b.cost
	end)
	local c = cands[1]
	if not c then
		return false
	end
	step("buy " .. c.label)
	local bought = c.do_()
	log(bought and ("bought %s for %s"):format(c.label, fmt(c.cost)) or ("%s was not taken"):format(c.label))
	if not bought then
		cool[c.key] = os.clock() + UPGRADE_BACKOFF
	end
	return bought
end

local function upgradeLoop(mine)
	while genUpgrade == mine do
		local good, did = pcall(upgradePass)
		if not good then
			warn("[rope] upgrade pass failed:", did)
		end
		task.wait(did and 0.3 or UPGRADE_EVERY)
	end
end

local function setUpgrade(on)
	genUpgrade += 1
	if on then
		task.spawn(upgradeLoop, genUpgrade)
	end
end

-- train ----------------------------------------------------------------------
local genTrain = 0

local function myMat()
	local folder = workspace:FindFirstChild("LocalBaseTreadmills")
	local m = folder and folder:FindFirstChild("BaseTreadmill_" .. player.UserId)
	return m and m:FindFirstChild("WalkZone")
end

local function trainLoop(mine)
	while genTrain == mine do
		if catchOn then
			say("train paused: catching")
			task.wait(1)
		else
			local c, _, hrp = character()
			local mat = myMat()
			if c and mat then
				step("train")
				if equip("Treadmill") and (hrp.Position - mat.Position).Magnitude > 4 then
					c:PivotTo(mat.CFrame + Vector3.new(0, 3, 0))
				end
				say(player:GetAttribute("SpeedTrainingActive") and "training" or "treadmill not active")
				first("train state", "active", player:GetAttribute("SpeedTrainingActive"), "mult", player:GetAttribute("SpeedTrainingMultiplier"))
			end
			task.wait(1)
		end
	end
end

local function setTrain(on)
	genTrain += 1
	if on then
		if catchOn and catchToggle then
			pcall(function()
				catchToggle:SetValue(false)
			end)
		end
		task.spawn(trainLoop, genTrain)
	end
end

-- claim ----------------------------------------------------------------------
local genClaim = 0
local eggBlocked = false

local function claimPass(lastIndex)
	local st = callTimed(function()
		return RF.GetRewardsState:InvokeServer()
	end)
	if type(st) == "table" and st.ok then
		if st.daily and not st.daily.alreadyClaimedToday then
			local r = callTimed(function()
				return RF.ClaimDailyReward:InvokeServer()
			end)
			first("daily reward", r and r.ok, r and r.reason)
			log("daily reward:", r and (r.ok and "claimed" or r.reason))
		end
		for i, r in ipairs(Rewards.Playtime) do
			if not (st.playtime.claimed or {})[i] and st.now - st.playtime.sessionStartedAt >= r.Time then
				local res = callTimed(function()
					return RF.ClaimPlaytimeReward:InvokeServer(i)
				end)
				first("playtime reward", i, res and res.ok, res and res.reason)
				log("playtime reward", i, res and (res.ok and "claimed" or res.reason))
			end
		end
	end
	local egg = callTimed(function()
		return RF["DailyEgg/GetState"]:InvokeServer()
	end)
	if not eggBlocked and type(egg) == "table" and egg.ok and (egg.unlockAt or 0) <= workspace:GetServerTimeNow() then
		-- the server answers ok even when you are too far, so success is claimCount going up
		local spot = workspace:FindFirstChild("Important") and workspace.Important:FindFirstChild("FreeDailyEgg")
		if spot then
			withCharacter(function()
				local c, _, hrp = character()
				if not c then
					return
				end
				step("daily egg")
				local home = hrp.CFrame
				c:PivotTo(CFrame.new(spot:GetPivot().Position + Vector3.new(0, 6, 8)))
				task.wait(SETTLE)
				local r = callTimed(function()
					return RF["DailyEgg/Claim"]:InvokeServer()
				end)
				if r and r.joinGroup then
					eggBlocked = true -- the game wants a group joined; that is yours to do
					log("daily egg needs a group join, skipped")
				elseif r and r.claimCount and r.claimCount > (egg.claimCount or 0) then
					log("daily egg claimed")
				else
					first("daily egg refused", r and r.ok, r and r.reason, r and r.claimCount)
				end
				local _, _, now = character()
				if now then
					c:PivotTo(home)
				end
			end)
		end
	end
	if os.clock() - lastIndex >= INDEX_EVERY then
		local r = callTimed(function()
			return RF.ClaimAllIndexRewards:InvokeServer()
		end)
		first("index rewards", r)
		return os.clock()
	end
	return lastIndex
end

local function claimLoop(mine)
	local lastIndex = -INDEX_EVERY
	while genClaim == mine do
		local good, res = pcall(claimPass, lastIndex)
		if good then
			lastIndex = res
		else
			warn("[rope] claim pass failed:", res)
		end
		task.wait(CLAIM_EVERY)
	end
end

local function setClaim(on)
	genClaim += 1
	if on then
		task.spawn(claimLoop, genClaim)
	end
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Rope an Animal", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "lasso")
local Catch = Tab:AddLeftGroupbox("Catch", "target")
local Pen = Tab:AddRightGroupbox("Pen", "layout-grid")
local Grow = Tab:AddRightGroupbox("Grow", "trending-up")

for _, r in ipairs(RARITIES) do
	rarityOn[r] = true -- Default does not fire the callback, so arm by hand
end
local sellDefault = { "Common" }
for _, r in ipairs(sellDefault) do
	sellOn[r] = true
end

catchToggle = Catch:AddToggle("Catch", {
	Text = "Auto Catch",
	Tooltip = "Teleports next to the best animal you allow, lassos it and rides it over the start line. Holds the lasso, so Train pauses",
	Default = false,
	Callback = setCatch,
})
Catch:AddDropdown("Rarities", {
	Text = "Rarities to catch",
	Tooltip = "Only animals of these rarities. The best income among them is taken first",
	Values = RARITIES,
	Default = RARITIES,
	Multi = true,
	Callback = function(picked)
		table.clear(rarityOn)
		for name in pairs(ticked(picked)) do
			rarityOn[name] = true
		end
	end,
})
Catch:AddDropdown("Names", {
	Text = "Only these animals",
	Tooltip = "Leave empty for any. Ticking some limits the catch to those species (and the rarities above)",
	Values = SPECIES,
	Default = {},
	Multi = true,
	Callback = function(picked)
		table.clear(nameOn)
		for name in pairs(ticked(picked)) do
			nameOn[name] = true
		end
	end,
})
Catch:AddToggle("RespectSpeed", {
	Text = "Skip zones too fast for me",
	Tooltip = "A zone whose guardian needs more Speed than you have is left alone. Off: try anyway (the guardian knocks you off and you lose the animal)",
	Default = true,
	Callback = function(state)
		respectSpeed = state
	end,
})
Pen:AddToggle("Equip", {
	Text = "Auto Equip Best",
	Tooltip = "The game's own Equip Best, after each catch and every 30s",
	Default = false,
	Callback = setEquip,
})
Pen:AddToggle("Sell", {
	Text = "Auto Sell Spares",
	Tooltip = "Sells spare animals of the rarities below, only when every pad is full and never one better than your weakest pad",
	Default = false,
	Callback = setSell,
})
Pen:AddDropdown("SellRarity", {
	Text = "Rarities to sell",
	Tooltip = "Spares of these rarities are sold for coins",
	Values = RARITIES,
	Default = sellDefault,
	Multi = true,
	Callback = function(picked)
		table.clear(sellOn)
		for name in pairs(ticked(picked)) do
			sellOn[name] = true
		end
	end,
})
Grow:AddToggle("Upgrade", {
	Text = "Auto Upgrade",
	Tooltip = "Buys the cheapest affordable of the next pen level or the next treadmill, with coins only. Robux routes are never touched",
	Default = false,
	Callback = setUpgrade,
})
trainToggle = Grow:AddToggle("Train", {
	Text = "Auto Train Speed",
	Tooltip = "Stands on your treadmill holding it so Speed grows. Pauses while Auto Catch is on, since the lasso needs your hand",
	Default = false,
	Callback = setTrain,
})
Grow:AddToggle("Claim", {
	Text = "Auto Claim Free Rewards",
	Tooltip = "Daily reward, playtime rewards, the free daily egg and the Index rewards. No Robux options",
	Default = false,
	Callback = setClaim,
})

local conns = {}
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
	local d = profile or {}
	Window:SetStatus({
		{ "Coins", fmt(d.Coins or 0) },
		{ "Speed", fmt(d.Speed or 0) },
		{ "Caught", stats.caught .. (stats.lost > 0 and (" (" .. stats.lost .. " lost)") or "") },
		{ "Sold", stat.sold },
		{ "Now", note },
	})
	if catchOn or genEquip > 0 or genUpgrade > 0 then
		task.spawn(getData) -- keep the strip's numbers fresh
	end
end))

-- watchdog: a separate thread, because a farm thread parked in a yield cannot report itself
task.spawn(function()
	local warned = 0
	while Window do
		task.wait(5)
		if catchOn and os.clock() - markAt > STUCK_AFTER and markAt ~= warned then
			warned = markAt
			warn(("[rope] stuck %ds at: %s"):format(os.clock() - markAt, mark))
		end
	end
end)

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("RopeAnAnimal", {})

table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- close ----------------------------------------------------------------------
local function stopAll()
	setCatch(false)
	setEquip(false)
	setSell(false)
	setUpgrade(false)
	setTrain(false)
	setClaim(false)
	aim(false)
	pcall(function()
		VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.W, false, game)
	end)
	resultCon:Disconnect()
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
	Window = nil
end

Library:OnUnload(function()
	stopAll()
	getgenv().ropeAnimalStop = nil
end)

getgenv().ropeAnimalStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().ropeAnimalStop = nil
end
