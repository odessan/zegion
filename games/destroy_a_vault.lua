--[[ Destroy a Vault -- roll, buy, place, collect, upgrade, rewards, meteor cores (91034536684382)

     ROLL    : presses your Roll machine the moment the server is ready for the next roll
               (RollPrompt enabled and RollRevealReadyAt passed: 12 of 12 landed, ~3.2s a roll, ~10s
               after a rare one). Uses the free Lucky Roll instead when the daily reward has one pending.
     BUY     : after each reveal, buys best DPS first, within the price box: any robot you picked by
               name, plus offers whose rarity you ticked that (by default) beat your weakest placed
               robot or fill an empty holder. Stops at the owned-robot cap. Waits for
               RollRevealReadyAt: earlier is refused (probed).
     EQUIP   : fills every empty holder with your best inventory robot, then swaps the weakest placed
               robot for a stronger one from inventory. Uses the game's own EquipFirstRobotById so the
               hotbar keeps working; falls back to the probed InventorySelect path.
     COLLECT : picks up the gold pile and deposits it at the smelter from wherever you stand (both
               committed from 35 studs, probed); if the server does not answer, stands on the floor
               halfway between them (~30 studs from each) and does both from there.
     UPGRADE : cheapest affordable of what you tick: robot damage, robot battery, roll luck, roll spots,
               vault tier, next robot holder, per-robot damage up to the level-cap box (the game has
               no per-robot max; each level costs 1.3x the last). All remote, no walking (probed).
     REWARDS : daily, playtime milestones, the free wheel spin (needs a hop to the wheel: it is
               range-checked) and the free offline claim.
     CORES   : during a meteor event, hops to each of your landed core meteors and claims it.
     BOSS    : during the hourly boss fight, hops to each energy core that lands for you, picks it up
               and loads it into your strongest ground robot from where you stand (server reach 400).

     Probed and dead (do not re-probe):
       claim an offer before RollRevealReadyAt     no sequence change, no robot (3 of 3)
       roll from 35 studs                          no answer: stand within 11.5
       equip prompt from 35 studs                  no answer: stand within 16, Tool held
       upgrade with a stale level arg              "StateChanged", nothing spent: the arg is a guard, no skipping
       InventorySelect RequestGeneration=1         "StaleRequest": the generation must exceed the server's last
     UNPROVEN (log their first outcome to F9): core claim, boss core pickup + load, playtime claim, Lucky Roll press,
       EquipFirstRobotById, gold pickup/deposit from 45-60 studs.
     Not wired (Robux): auto-collect / fast-spin passes, offline "FiveTimes", paid wheel spins,
       StealOfferPrompt, skip offers, Lucky Roll credits purchase, island unlock (RobotHolderPurchaseRequest
       with a trailing true: unknown whether paid). Smelter speed is not wired either: deposits are instant
       (EconomyConfig.InstantSmelterCashEnabled), so it buys nothing.

     RightControl opens / closes the panel. Stop: getgenv().vaultStop() ]]

-- config ---------------------------------------------------------------------
local NEAR = 4 -- studs from a prompt when we stand at it (roll 11.5, claim 7.2, holder 16 are the limits)
local SETTLE = 0.25 -- after a hop, before the press: the server must see the new position
local PRESS_CONFIRM = 2.5 -- a press must move the prompt's feedback sequence inside this
local READY_PAD = 0.1 -- past RollRevealReadyAt before rolling / buying (0.1 bought 3 of 3)
local ROLL_WAIT_MAX = 15 -- longest wait for the machine to be ready (a rare roll holds it ~10s)
local EQUIP_EVERY = 3
local TOOL_WAIT = 4 -- after a select, the robot Tool must show up inside this
local COLLECT_EVERY = 3
local FAR_PROVEN = 35 -- pickup and deposit both committed from 35 studs (probed); from ~45 the deposit went unanswered
local COLLECT_REACH = 33 -- one floor spot serves both when pile and smelter are under 2x this apart
local GROUND_CAST = 40 -- how far below a standing spot to look for the floor
local UPGRADE_EVERY = 1
local UPGRADE_BACKOFF = 10 -- an upgrade the server did not take is not retried for this long
local REWARD_EVERY = 60
local CORE_SCAN = 1
local CORE_BENCH = 10 -- a core claim that did not land is retried after this
local MAX_PRICE_PCT = 50 -- an offer may cost at most this % of your cash (the box in the panel changes it)
local ROBOT_LEVEL_CAP = 25 -- per-robot upgrades stop at this level (the box in the panel changes it; the game has no max)
local REPLY_WAIT = 8 -- an InvokeServer that has not answered by now is given up on
local CLAIM_ENABLE_WAIT = 1.5 -- after the reveal, wait up to this long for an offer's claim prompt to switch on

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local player = Players.LocalPlayer

if getgenv and getgenv().vaultStop then
	getgenv().vaultStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[vault]", ...)
end

-- The panel strip is drained from a Heartbeat (our own identity); loop threads only write here.
local pending, lastSaid = {}, nil
local function say(msg, quiet)
	pending.now = msg
	if not quiet and msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- game -----------------------------------------------------------------------
local VR = ReplicatedStorage:WaitForChild("VaultRemotes", 15)
local Shared = ReplicatedStorage:WaitForChild("Shared", 15)
local ok, RobotDefinitions, RarityOddsConfig, EconomyConfig, RobotUpgradePolicy, RollLuckUpgradePolicy, RollPedestalUpgradePolicy, RobotHolderPricePolicy, InventoryPresentationPolicy, LimitedRobotPolicy, MeteorEventConfig, BossVaultConfig =
	pcall(function()
		return require(Shared.config.RobotDefinitions),
			require(Shared.config.RarityOddsConfig),
			require(Shared.config.EconomyConfig),
			require(Shared.economy.RobotUpgradePolicy),
			require(Shared.economy.RollLuckUpgradePolicy),
			require(Shared.economy.RollPedestalUpgradePolicy),
			require(Shared.economy.RobotHolderPricePolicy),
			require(Shared.presentation.InventoryPresentationPolicy),
			require(Shared.data.LimitedRobotPolicy),
			require(Shared.weather.MeteorEventConfig),
			require(Shared.boss.BossVaultConfig)
	end)
if not (VR and ok) then
	warn("[vault] the game's modules did not load:", RobotDefinitions)
	return
end
local function R(name)
	return VR:FindFirstChild(name)
end

-- The live session-data mirror is the PlayerScripts copy (probed: the StarterPlayer copy is never started).
local client = player:WaitForChild("PlayerScripts"):WaitForChild("Client", 15)
local SDC, Inventory
do
	local m = client and client:FindFirstChild("SessionDataClient")
	local good, mod = pcall(require, m)
	if good and type(mod) == "table" and pcall(mod.GetCash) then
		SDC = mod
	end
	local im = client and client:FindFirstChild("InventoryClient")
	local good2, mod2 = pcall(require, im)
	Inventory = good2 and type(mod2) == "table" and mod2 or nil
end
if not SDC then
	warn("[vault] the game's session data is not readable (PlayerScripts.Client.SessionDataClient)")
	return
end
local function sd(name, ...)
	local f = SDC[name]
	if type(f) ~= "function" then
		return nil
	end
	local good, v = pcall(f, ...)
	return good and v or nil
end
local function cash()
	return tonumber(tostring(sd("GetCash"))) or 0 -- the mirror hands cash over as a string
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
assert(fmt(25000) == "25K" and fmt("1500") == "1.5K" and fmt(100) == "100", "fmt")

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

-- InvokeServer has no timeout; a handler that never answers would park the loop forever.
local function invoke(remote, ...)
	if not remote then
		return nil
	end
	local args, done, out = table.pack(...), false, nil
	task.spawn(function()
		out = table.pack(pcall(remote.InvokeServer, remote, table.unpack(args, 1, args.n)))
		done = true
	end)
	local dl = os.clock() + REPLY_WAIT
	while not done and os.clock() < dl do
		task.wait()
	end
	if not (out and out[1]) then
		return nil
	end
	return out[2], out[3], out[4]
end

-- A robot's DPS by the game's own formula (InventoryClient.formatRobotDps). The global upgrade
-- multiplier is the same for every robot, so ranking passes level 1 for it.
-- ponytail: mutations are not counted; a mutated robot ranks as its plain self
local function dps(robotId, level)
	local d = RobotDefinitions.Get(robotId)
	if not d then
		return 0
	end
	local good, v = pcall(function()
		local base = LimitedRobotPolicy.BaseDamage(d, d.Rarity == "Limited" and sd("GetRobotInventory") or nil)
		return InventoryPresentationPolicy.ResolveDps(base, d.AttackInterval, 1, level or 1)
	end)
	return good and tonumber(v) or (d.Damage or 0)
end
assert(dps("r65", 1) > dps("r20", 1) and dps("r02", 1) > dps("common_tank", 1), "dps ranks stronger robots higher")

local RARITIES = {}
for _, b in ipairs(RarityOddsConfig.Bands) do
	RARITIES[#RARITIES + 1] = b.Rarity
end

-- world -----------------------------------------------------------------------
local function myPlot()
	local playable = workspace:FindFirstChild("playable")
	for _, m in ipairs(playable and playable:GetChildren() or {}) do
		if m:GetAttribute("OwnerUserId") == player.UserId then
			return m
		end
	end
	return nil
end

local function findPrompt(name, under)
	if not under then
		return nil
	end
	for _, d in ipairs(under:GetDescendants()) do
		if d.Name == name and d:IsA("ProximityPrompt") then
			return d
		end
	end
	return nil
end

local function machinery()
	local plot = myPlot()
	return plot and plot:FindFirstChild("Machinery")
end

local function ppos(p)
	local a = p and p.Parent
	if not a then
		return nil
	end
	if a:IsA("Attachment") then
		return a.WorldPosition
	end
	if a:IsA("BasePart") then
		return a.Position
	end
	local bp = p:FindFirstAncestorWhichIsA("BasePart")
	return bp and bp.Position
end

local function root()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function distTo(p)
	local r, q = root(), ppos(p)
	return (r and q) and (r.Position - q).Magnitude or math.huge
end

-- The server confirms every interaction by bumping a sequence attribute on the prompt itself.
local SEQ = {
	RollPrompt = { "RollFeedbackSequence", "RollResult" },
	LuckyRollPrompt = { "RollFeedbackSequence", "RollResult" },
	ClaimRobotPrompt = { "RobotClaimPurchaseFeedbackSequence", "PurchaseResult" },
	TreasurePickupPrompt = { "InteractionFeedbackSequence", "InteractionResult" },
	SmelterDepositPrompt = { "InteractionFeedbackSequence", "InteractionResult" },
	EquipRobotPrompt = { "EquipFeedbackSequence", "PlacementResult" },
}
local function seq(p)
	local s = SEQ[p.Name]
	if not s then
		return 0, nil
	end
	return p:GetAttribute(s[1]) or 0, p:GetAttribute(s[2])
end

-- Press and wait for the server's answer: returns true (sequence moved), the result code.
-- Prompts without a sequence (cores, wheel) return nil: the caller confirms on its own signal.
local function press(p)
	if not fireproximityprompt then
		return false, "no fireproximityprompt"
	end
	local a = seq(p)
	local good, err = pcall(fireproximityprompt, p)
	if not good then
		return false, tostring(err)
	end
	if not SEQ[p.Name] then
		return nil, nil
	end
	local dl = os.clock() + PRESS_CONFIRM
	while os.clock() < dl and seq(p) == a do
		task.wait()
	end
	local b, res = seq(p)
	return b ~= a, res
end

-- character: one claim, one pin ------------------------------------------------
-- Roll/buy, equip, the wheel and cores all need the character next to something. One busy flag;
-- whoever holds it may pin the root. Returns whether fn RAN (not whether it worked).
local busy, pinCF = false, nil
local function claim(fn)
	if busy then
		return false
	end
	busy = true
	local good, err = pcall(fn)
	pinCF = nil
	busy = false
	if not good then
		warn("[vault]", err)
	end
	return true
end

-- The roll loop re-claims a frame after it lets go, so everyone else queues: the roll loop
-- only claims while nobody is waiting.
local waiting = 0
local function claimWait(fn, timeout)
	waiting += 1
	local dl = os.clock() + (timeout or 20)
	while busy and os.clock() < dl do
		task.wait()
	end
	waiting -= 1
	return claim(fn)
end

-- Feet on the floor under pos: cast down past the prompt's own height (pile and smelter prompts hang
-- in the air), ignoring our character and anything you can walk through.
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true
local function ground(pos)
	local c = player.Character
	rayParams.FilterDescendantsInstances = c and { c } or {}
	local hit = workspace:Raycast(pos + Vector3.new(0, 2, 0), Vector3.new(0, -GROUND_CAST, 0), rayParams)
	if not hit then
		return pos
	end
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	local r = root()
	return Vector3.new(pos.X, hit.Position.Y + (hum and hum.HipHeight or 2) + (r and r.Size.Y / 2 or 1), pos.Z)
end

local function stand(pos)
	local p = ground(pos)
	local r = root()
	-- keep the way we face; only the position moves
	pinCF = r and (CFrame.new(p) * (r.CFrame - r.CFrame.Position)) or CFrame.new(p)
	task.wait(SETTLE)
end

-- a standing spot NEAR studs from the prompt, toward the plot's middle, a little above it
local function spot(p, d)
	local q = ppos(p)
	local plot = myPlot()
	local c = plot and plot:GetPivot().Position or q
	local dir = Vector3.new(c.X - q.X, 0, c.Z - q.Z)
	dir = dir.Magnitude > 0.5 and dir.Unit or Vector3.xAxis
	return q + dir * (d or NEAR) + Vector3.new(0, 3, 0)
end

-- robots ----------------------------------------------------------------------
local function holders()
	local out = {}
	local plot = myPlot()
	local islands = plot and plot:FindFirstChild("Islands")
	for _, d in ipairs(islands and islands:GetDescendants() or {}) do
		local n = d:IsA("Model") and tonumber(d.Name:match("^RobotHolder_(%d+)$"))
		if n then
			local state = d:GetAttribute("RobotHolderVisualState")
			if not state then
				for _, x in ipairs(d:GetDescendants()) do
					state = x:GetAttribute("RobotHolderVisualState")
					if state then
						break
					end
				end
			end
			out[#out + 1] = { n = n, id = "robot_holder_" .. n, prompt = findPrompt("EquipRobotPrompt", d), state = state }
		end
	end
	table.sort(out, function(a, b)
		return a.n < b.n
	end)
	return out
end

local function placed()
	local out = {}
	local plot = myPlot()
	local rr = plot and plot:FindFirstChild("RuntimeRobots")
	for _, m in ipairs(rr and rr:GetChildren() or {}) do
		local rt = m:FindFirstChild("RobotRuntimeRoot") or m
		local function a(k)
			local v = rt:GetAttribute(k)
			if v == nil then
				v = m:GetAttribute(k)
			end
			return v
		end
		local iid, rid, holder = a("RobotInstanceId"), a("RobotId"), a("RobotHolderId")
		if iid and rid and holder then
			local lvl = a("RobotDamageLevel") or 1
			out[#out + 1] = { iid = iid, rid = rid, holder = holder, lvl = lvl, score = dps(rid, lvl) }
		end
	end
	return out
end

local function inventory()
	local out = {}
	for _, r in ipairs(sd("GetRobotInventory") or {}) do
		out[#out + 1] = { iid = r.InstanceId, rid = r.RobotId, lvl = r.DamageLevel or 1, score = dps(r.RobotId, r.DamageLevel or 1) }
	end
	table.sort(out, function(a, b)
		return a.score > b.score
	end)
	return out
end

local function weakestPlaced(list)
	local w
	for _, r in ipairs(list or placed()) do
		if not w or r.score < w.score then
			w = r
		end
	end
	return w
end

local function emptyHolders()
	local out = {}
	for _, h in ipairs(holders()) do
		if h.state == "UnlockedEmpty" and h.prompt then
			out[#out + 1] = h
		end
	end
	return out
end

-- Owned cap: 200, or 1000 with the paid extension (EconomyConfig). The server's own "full" notice wins.
local fullUntil = 0
local function ownedCap(owned)
	return owned > EconomyConfig.MaximumOwnedRobots and EconomyConfig.MaximumPaidOwnedRobots or EconomyConfig.MaximumOwnedRobots
end

local stats = { rolls = 0, lucky = 0, bought = 0, placedN = 0, swaps = 0, banked = 0, upgrades = 0, cores = 0, bossCores = 0, rewards = 0 }
local firstSeen = {} -- UNPROVEN branches print their first outcome once
local function first(key, ...)
	if not firstSeen[key] then
		firstSeen[key] = true
		log("first " .. key .. ":", ...)
	end
end

-- roll + buy ---------------------------------------------------------------------
local rollOn, buyOn = false, false
local rarityOn = {}
local nameOn = {} -- robot ids picked by name in the panel
local robotCap = ROBOT_LEVEL_CAP
local onlyBetter = true
local maxPct = MAX_PRICE_PCT
local luckyPending = false -- refreshed by the reward pass (daily projection)

local function roler()
	local m = machinery()
	local p = findPrompt("RollPrompt", m)
	return p, p and (p.Parent:IsA("BasePart") and p.Parent or p:FindFirstAncestorWhichIsA("BasePart"))
end

local function readyIn(part)
	local ry = part and part:GetAttribute("RollRevealReadyAt")
	return ry and (ry - workspace:GetServerTimeNow()) or 0
end

local function offers()
	local out = {}
	local m = machinery()
	for _, ped in ipairs(m and m:GetChildren() or {}) do
		if ped.Name:match("^RollPedestal%d+$") then
			local id, carrier = ped:GetAttribute("RollRobotId"), ped
			if not id then
				for _, d in ipairs(ped:GetDescendants()) do
					id = d:GetAttribute("RollRobotId")
					if id then
						carrier = d
						break
					end
				end
			end
			local d = id and RobotDefinitions.Get(id)
			local p = findPrompt("ClaimRobotPrompt", ped)
			if d and p and d.PurchasePrice then
				out[#out + 1] = {
					id = id,
					def = d,
					prompt = p,
					carrier = carrier,
					offerId = carrier:GetAttribute("RollOfferId"),
					price = d.PurchasePrice,
					score = dps(id, 1),
				}
			end
		end
	end
	table.sort(out, function(a, b)
		return a.score > b.score
	end)
	return out
end

local function buyPass(alive)
	if os.clock() < fullUntil then
		return
	end
	local inv, pl = inventory(), placed()
	local owned = #inv + #pl
	local free = #emptyHolders()
	local weak = weakestPlaced(pl)
	for _, o in ipairs(offers()) do
		if not alive() then
			return
		end
		if owned >= ownedCap(owned) then
			say(("owned cap %d reached: not buying"):format(owned))
			return
		end
		local c = cash()
		-- a robot you named is bought whatever its rarity and whatever you have placed; the rest go
		-- through the rarity ticks and the "beats my weakest" rule
		local named = nameOn[o.id] == true
		local worth = o.price <= c * maxPct / 100
			and (named or (rarityOn[o.def.Rarity] and (not onlyBetter or free > 0 or not weak or o.score > weak.score)))
		if worth then
			stand(spot(o.prompt))
			local n0 = #(sd("GetRobotInventory") or {})
			-- The claim prompt can still be disabled on our client a moment after the reveal (all three
			-- early misses in probe 2 had it off): wait for it, and if the same offer is still there after
			-- an unanswered press, open it client-side and press once more.
			local dl = os.clock() + CLAIM_ENABLE_WAIT
			while not o.prompt.Enabled and os.clock() < dl do
				task.wait()
			end
			local en = o.prompt.Enabled
			local acked, res = press(o.prompt)
			if not acked and o.carrier.Parent and o.carrier:GetAttribute("RollOfferId") == o.offerId then
				o.prompt.Enabled = true
				acked, res = press(o.prompt)
				first("claim retry with prompt opened", acked, res)
			end
			task.wait(0.2)
			local n1 = #(sd("GetRobotInventory") or {})
			if acked and (n1 > n0 or res == "Purchased") then
				stats.bought += 1
				owned += 1
				if free > 0 then
					free -= 1
				end
				say(("bought %s (%s) for %s"):format(o.def.DisplayName or o.id, o.def.Rarity, fmt(o.price)))
			else
				-- no ack = the server never answered (the result shown would be the previous press's)
				local what = acked and ("refused: " .. tostring(res)) or "no answer"
				warn(("[vault] buy %s: %s %s price %s cash %s enabled %s offer still up %s dist %.1f readyIn %.2f"):format(
					what, o.id, o.def.Rarity, fmt(o.price), fmt(c), tostring(en),
					tostring(o.carrier.Parent ~= nil and o.carrier:GetAttribute("RollOfferId") == o.offerId), distTo(o.prompt), readyIn(select(2, roler()))))
			end
		end
	end
end

local genRoll = 0
local function rollLoop(mine)
	local function alive()
		return (rollOn or buyOn) and genRoll == mine
	end
	local lastBuyCheck = 0
	while alive() do
		local rp, part = roler()
		if not rp then
			say("Roll machine not found (is your plot loaded?)")
			task.wait(2)
		elseif waiting > 0 then
			task.wait() -- someone queued for the character: let them have it
		elseif rollOn then
			-- Every wait happens OUTSIDE the claim: a rare reveal holds the machine ~10s and a boss core
			-- lives 15s, so the character must stay free while we only wait.
			local dl = os.clock() + ROLL_WAIT_MAX
			while alive() and os.clock() < dl and not (rp.Enabled and readyIn(part) <= -READY_PAD) do
				task.wait()
			end
			local acked
			if alive() and waiting == 0 then
				claim(function()
					stand(spot(rp))
					local lucky = findPrompt("LuckyRollPrompt", machinery())
					local useLucky = luckyPending and lucky and lucky.Enabled
					local res
					acked, res = press(useLucky and lucky or rp)
					if useLucky then
						first("lucky roll", acked, res)
						if acked then
							stats.lucky += 1
							luckyPending = false
						end
					end
					if acked then
						stats.rolls += 1
					elseif distTo(rp) > rp.MaxActivationDistance then
						say(("roll not answered: %.0f studs from the machine"):format(distTo(rp)))
					end
				end)
			end
			if buyOn and acked then
				local dl2 = os.clock() + ROLL_WAIT_MAX
				while alive() and os.clock() < dl2 and readyIn(part) > -READY_PAD do
					task.wait()
				end
				if alive() then
					claimWait(function()
						buyPass(alive)
					end, 5)
				end
			end
			task.wait()
		else -- Buy alone: take what the machine shows, once its reveal is over
			if os.clock() - lastBuyCheck > 1 and readyIn(part) <= -READY_PAD then
				lastBuyCheck = os.clock()
				claim(function()
					buyPass(alive)
				end)
			end
			task.wait(0.2)
		end
	end
end

local function setRollBuy()
	genRoll += 1
	local mine = genRoll
	if rollOn or buyOn then
		task.spawn(function()
			local good, err = pcall(rollLoop, mine)
			if not good then
				warn("[vault] roll loop died:", err)
			end
		end)
	end
end

-- equip -----------------------------------------------------------------------
local equipOn, genEquip = false, 0
local selGen, selReply = 0, nil
local selCon = R("InventorySelect") and R("InventorySelect").OnClientEvent:Connect(function(t)
	selReply = t
	if type(t) == "table" and type(t.RequestGeneration) == "number" and t.Accepted then
		selGen = math.max(selGen, t.RequestGeneration)
	end
end)

local function robotTool(iid, rid)
	for _, c in ipairs({ player.Character, player:FindFirstChildOfClass("Backpack") }) do
		for _, t in ipairs(c and c:GetChildren() or {}) do
			if t:IsA("Tool") and t:GetAttribute("VaultGameRobotTool") == true
				and (t:GetAttribute("RobotInstanceId") == iid or (iid == nil and t:GetAttribute("RobotId") == rid)) then
				return t
			end
		end
	end
	return nil
end

-- Get the robot's Tool into your hands. The game's own EquipFirstRobotById keeps its select counter
-- in step with the server's; our raw InventorySelect has to jump past it (StaleRequest otherwise),
-- which leaves the hotbar's own selects stale until it catches up.
local function holdRobot(r)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not hum then
		return nil
	end
	pcall(hum.UnequipTools, hum)
	if Inventory and type(Inventory.EquipFirstRobotById) == "function" then
		local done, res = false, nil
		local good = pcall(Inventory.EquipFirstRobotById, r.rid, function(s, e)
			done, res = true, { s, e }
		end)
		local dl = os.clock() + TOOL_WAIT
		while good and not done and os.clock() < dl do
			task.wait()
		end
		local tool = robotTool(nil, r.rid)
		first("EquipFirstRobotById", good, res and res[1], res and res[2], tool and tool.Parent and tool.Parent.Name)
		if tool and tool.Parent == player.Character then
			return tool
		end
	end
	for _ = 1, 4 do
		selGen += 1
		selReply = nil
		pcall(function()
			R("InventorySelect"):FireServer({ RequestGeneration = selGen, RobotInstanceId = r.iid })
		end)
		local dl = os.clock() + 3
		while not selReply and os.clock() < dl do
			task.wait()
		end
		if not (selReply and selReply.Code == "StaleRequest") then
			break
		end
		selGen += 25
	end
	local tool
	local dl = os.clock() + TOOL_WAIT
	repeat
		tool = robotTool(r.iid)
		task.wait()
	until tool or os.clock() > dl
	if tool then
		pcall(hum.EquipTool, hum, tool)
		task.wait(0.2)
	end
	return tool and tool.Parent == player.Character and tool or nil
end

local function holderOf(iid)
	for _, x in ipairs(placed()) do
		if x.iid == iid then
			return x.holder
		end
	end
	return nil
end

local function placeInto(r, h)
	if not holdRobot(r) then
		warn(("[vault] could not get %s into your hands (select reply %s)"):format(r.rid, selReply and tostring(selReply.Code) or "none"))
		return false
	end
	stand(spot(h.prompt, NEAR + 1))
	-- Same as the claim prompt: a holder just emptied or never used can still be disabled on our
	-- client (seen: no answer at 6 studs, placed on the next pass). Wait for it, then open it once.
	local dl = os.clock() + CLAIM_ENABLE_WAIT
	while not h.prompt.Enabled and os.clock() < dl do
		task.wait()
	end
	local en = h.prompt.Enabled
	local acked, res = press(h.prompt)
	if not acked then
		h.prompt.Enabled = true
		acked, res = press(h.prompt)
		first("place retry with prompt opened", acked, res)
	end
	task.wait(0.3)
	local at = holderOf(r.iid)
	if at == h.id or (acked and res == "Placed") then
		return true
	end
	local what = acked and ("refused: " .. tostring(res)) or "no answer"
	local tool = robotTool(r.iid, r.rid)
	warn(("[vault] place %s: %s -> %s enabled %s held %s dist %.1f"):format(
		what, r.rid, h.id, tostring(en), tostring(tool ~= nil and tool.Parent == player.Character), distTo(h.prompt)))
	return false
end

local function equipPass(alive)
	local inv = inventory()
	if #inv == 0 then
		return
	end
	local byId = {}
	for _, h in ipairs(holders()) do
		byId[h.id] = h
	end
	local i = 1
	for _, h in ipairs(emptyHolders()) do
		if not alive() or not inv[i] then
			break
		end
		if placeInto(inv[i], h) then
			stats.placedN += 1
			say(("placed %s on %s"):format(inv[i].rid, h.id))
		end
		i += 1
	end
	while alive() and inv[i] do
		local weak = weakestPlaced()
		if not (weak and inv[i].score > weak.score) then
			break
		end
		local h = byId[weak.holder]
		if not (h and h.prompt) then
			break
		end
		local s, code = invoke(R("RobotHolderAction"), "Remove", weak.holder)
		if s ~= true then
			warn("[vault] remove refused:", weak.holder, weak.rid, tostring(code))
			break
		end
		task.wait(0.4)
		if placeInto(inv[i], h) then
			stats.swaps += 1
			say(("swapped %s -> %s on %s"):format(weak.rid, inv[i].rid, h.id))
		end
		i += 1
	end
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		pcall(hum.UnequipTools, hum)
	end
end

local function setEquip(on)
	genEquip += 1
	local mine = genEquip
	equipOn = on
	if not on then
		return
	end
	task.spawn(function()
		local function alive()
			return equipOn and genEquip == mine
		end
		while alive() do
			if #inventory() > 0 then -- nothing to place: don't queue for the character
				claimWait(function()
					equipPass(alive)
				end)
			end
			task.wait(EQUIP_EVERY)
		end
	end)
end

-- collect ---------------------------------------------------------------------
-- Pickup and deposit both committed from 35 studs (probed). First try from wherever we stand; if the
-- server does not answer, hop once to the floor spot halfway between pile and smelter (30 studs from
-- each on the probed plot) and do both from there, feet on the ground.
local collectOn, genCollect = false, 0

local function treasureNum(k)
	local t = sd("GetTreasureState")
	return t and tonumber(tostring(t[k])) or 0
end

local function collectSpot(pile, smelt)
	local a, b = ppos(pile), ppos(smelt)
	if a and b and (a - b).Magnitude / 2 <= COLLECT_REACH then
		return (a + b) / 2
	end
	return nil -- too far apart on this plot: stand next to each in turn
end

-- Press only what is within the proven reach (35 studs); a press from further was seen to go
-- unanswered, and that costs PRESS_CONFIRM for nothing. Returns true when nothing is left to do.
local function collectStep(pile, smelt, final)
	if treasureNum("PileGold") > 0 and treasureNum("CarriedGold") == 0 and distTo(pile) <= FAR_PROVEN then
		local acked = press(pile)
		if acked then -- the mirror's CarriedGold lands a moment after the prompt's sequence
			local dl = os.clock() + 1
			while treasureNum("CarriedGold") == 0 and os.clock() < dl do
				task.wait()
			end
		elseif final then
			warn(("[vault] gold pickup got no answer from %.1f studs"):format(distTo(pile)))
		end
	end
	if treasureNum("CarriedGold") > 0 and distTo(smelt) <= FAR_PROVEN then
		local c0 = cash()
		local acked = press(smelt)
		if acked then
			stats.banked += math.max(0, cash() - c0)
		elseif final then
			warn(("[vault] deposit got no answer from %.1f studs"):format(distTo(smelt)))
		end
	end
	local leftPile = treasureNum("PileGold") > 0 and treasureNum("CarriedGold") == 0
	return not leftPile and treasureNum("CarriedGold") == 0
end

local function collectPass()
	local m = machinery()
	local pile, smelt = findPrompt("TreasurePickupPrompt", m), findPrompt("SmelterDepositPrompt", m)
	if not (pile and smelt) then
		return
	end
	local wantPile = treasureNum("PileGold") > 0 and treasureNum("CarriedGold") == 0
	local wantSmelt = treasureNum("CarriedGold") > 0
	if not (wantPile or wantSmelt) then
		return
	end
	if collectStep(pile, smelt, false) then
		return -- everything was in reach from where we stand: no hop at all
	end
	claimWait(function()
		local mid = collectSpot(pile, smelt)
		if mid then
			stand(mid)
			collectStep(pile, smelt, true)
		else
			stand(spot(pile))
			collectStep(pile, smelt, false)
			stand(spot(smelt))
			collectStep(pile, smelt, true)
		end
	end)
end

local function setCollect(on)
	genCollect += 1
	local mine = genCollect
	collectOn = on
	if not on then
		return
	end
	task.spawn(function()
		while collectOn and genCollect == mine do
			local good, err = pcall(collectPass)
			if not good then
				warn("[vault] collect pass:", err)
			end
			task.wait(COLLECT_EVERY)
		end
	end)
end

-- upgrade ---------------------------------------------------------------------
local upgradeOn, genUpgrade = false, 0
local upOn = { Damage = true, Battery = true, Luck = true, Spots = true, Vault = true, Holders = true, Robots = true }
local backoff = {}

local function board(group, name)
	local T = ReplicatedStorage:FindFirstChild("SharedUpgradeBoardTemplates")
	local m = T and T:FindFirstChild(group)
	m = m and m:FindFirstChild(group)
	m = name and m and m:FindFirstChild(name) or m
	return m and m:FindFirstChild("BoardPart")
end

local function quotePrice(q)
	if type(q) ~= "table" or q.IsMaximum or type(q.Price) ~= "number" then
		return nil
	end
	return q.Price
end

-- every affordable-or-not upgrade you ticked, as { key, label, price, fire }
local function upgradeCandidates()
	local out = {}
	local function add(kind, key, label, price, fire)
		if upOn[kind] and price and (backoff[key] or 0) < os.clock() then
			out[#out + 1] = { key = key, label = label, price = price, fire = fire }
		end
	end
	-- ponytail: arm 1 only (one island in the probe); a second island's boards are unmapped
	local arm = sd("GetRobotUpgradesForArm", 1)
	if type(arm) == "table" then
		for _, k in ipairs({ { "Damage", "PurchaseRobotDamage", "RobotDamage", "DamageLevel" }, { "Battery", "PurchaseRobotBattery", "RobotBattery", "BatteryLevel" } }) do
			local lvl = arm[k[4]]
			if lvl then
				local good, q = pcall(RobotUpgradePolicy.GetGlobalUpgradeQuote, k[1], lvl, 1)
				add(k[1], k[2], "robot " .. k[1]:lower() .. " " .. (lvl + 1), good and quotePrice(q), function()
					return invoke(R("UpgradeBoardAction"), k[2], board("RobotUpgrades", k[3]), lvl)
				end)
			end
		end
	end
	local luck = sd("GetRollLuckLevel")
	if luck then
		local good, q = pcall(RollLuckUpgradePolicy.GetQuote, luck)
		add("Luck", "luck", "roll luck " .. (luck + 1), good and quotePrice(q), function()
			return invoke(R("UpgradeBoardAction"), "PurchaseRollLuck", board("RollUpgrades", "RobotLuck"), luck)
		end)
	end
	local peds = sd("GetRollPedestalCount")
	if peds then
		local good, q = pcall(RollPedestalUpgradePolicy.GetQuote, peds)
		add("Spots", "spots", "roll spot " .. (peds + 1), good and quotePrice(q), function()
			return invoke(R("UpgradeBoardAction"), "PurchaseRollSpots", board("RollUpgrades", "RobotRolls"), peds)
		end)
	end
	local tier = sd("GetVaultTierId")
	for i, t in ipairs(EconomyConfig.VaultTiers) do
		if t.Id == tier and EconomyConfig.VaultTiers[i + 1] then
			local nxt = EconomyConfig.VaultTiers[i + 1]
			add("Vault", "vault", "vault " .. nxt.Id, nxt.PurchasePrice, function()
				return invoke(R("UpgradeBoardAction"), "PurchaseVaultTier", board("UpgradeVault"), tier)
			end)
		end
	end
	local hs = holders()
	local unlocked = 0
	local nextLocked
	for _, h in ipairs(hs) do
		if h.state == "Locked" then
			nextLocked = nextLocked or h
		elseif h.state then
			unlocked += 1
		end
	end
	if nextLocked then
		local good, price = pcall(RobotHolderPricePolicy.GetNextPrice, unlocked)
		add("Holders", "holder", "holder " .. nextLocked.n, good and tonumber(price), function()
			return invoke(R("RobotHolderPurchaseRequest"), nextLocked.id)
		end)
	end
	-- The game has no per-robot maximum (GetIndividualUpgradeQuote always says IsMaximum = false; each
	-- level costs 1.3x the last), so the cap is yours: the "Robot level cap" box.
	for _, r in ipairs(placed()) do
		local good, q = false, nil
		if r.lvl < robotCap then
			good, q = pcall(RobotUpgradePolicy.GetIndividualUpgradeQuote, r.lvl, r.rid)
		end
		add("Robots", "robot " .. r.iid, ("%s lvl %d"):format(r.rid, r.lvl + 1), good and quotePrice(q), function()
			return invoke(R("RobotHolderAction"), "Upgrade", r.holder, r.lvl)
		end)
	end
	table.sort(out, function(a, b)
		return a.price < b.price
	end)
	return out
end

-- A reply of InsufficientCashPrompt makes the GAME's client open a Robux prompt; called from here
-- nothing opens, but the cash gate keeps those calls from happening at all.
local function upgradePass()
	local c = cash()
	local u = upgradeCandidates()[1]
	if not u or u.price > c then
		return false
	end
	local s, code = u.fire()
	if s == true then
		stats.upgrades += 1
		say(("bought %s for %s"):format(u.label, fmt(u.price)), stats.upgrades % 10 ~= 1)
		return true
	end
	backoff[u.key] = os.clock() + UPGRADE_BACKOFF
	warn(("[vault] upgrade refused: %s price %s cash %s -> %s"):format(u.label, fmt(u.price), fmt(c), tostring(code)))
	return false
end

local function setUpgrade(on)
	genUpgrade += 1
	local mine = genUpgrade
	upgradeOn = on
	if not on then
		return
	end
	task.spawn(function()
		while upgradeOn and genUpgrade == mine do
			local good, did = pcall(upgradePass)
			if not good then
				warn("[vault] upgrade pass:", did)
			end
			task.wait(did == true and 0.2 or UPGRADE_EVERY) -- a pass that bought something goes again soon
		end
	end)
end

-- rewards ---------------------------------------------------------------------
local rewardOn, genReward = false, 0

local function wheelPrompt()
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "SpinWheelPrompt" then
			return d
		end
	end
	return nil
end

local function wheelReady()
	local w = sd("GetSpinWheelState")
	if type(w) ~= "table" then
		first("wheel mirror unreadable", typeof(w)) -- then the wheel is never hopped to
		return false
	end
	local accrued = math.floor(math.max(0, workspace:GetServerTimeNow() - (w.AccrualUnix or 0)) / 86400) -- SpinWheelPolicy.Interval
	return (w.Free or 0) + accrued >= 1
end

local function rewardPass(alive)
	local s, rep = invoke(R("DailyRewardsAction"), "Get")
	local proj = type(s) == "table" and s.Projection or (type(rep) == "table" and rep.Projection)
	if type(proj) == "table" then
		luckyPending = proj.LuckyRollPending == true
		if proj.Claimable then
			local r = invoke(R("DailyRewardsAction"), "Claim")
			first("daily claim", type(r) == "table" and r.Code or r)
			stats.rewards += 1
		end
	end
	local pt = invoke(R("PlaytimeRewardsAction"), "Get")
	local rewards = type(pt) == "table" and type(pt.Projection) == "table" and pt.Projection.Rewards
	for i, r in pairs(type(rewards) == "table" and rewards or {}) do
		if alive() and type(r) == "table" and r.Status == "Claimable" then
			local c = invoke(R("PlaytimeRewardsAction"), "Claim", i)
			first("playtime claim", i, type(c) == "table" and c.Code or c)
			stats.rewards += 1
		end
	end
	if alive() and wheelReady() then
		local wp = wheelPrompt()
		if wp then
			claimWait(function()
				stand(spot(wp))
				local st = invoke(R("SpinWheelAction"), "State")
				local state = type(st) == "table" and st.State
				if type(state) == "table" and (state.Free or 0) >= 1 then
					local sp = invoke(R("SpinWheelAction"), "Spin", state.Sequence)
					say("wheel: " .. tostring(type(sp) == "table" and sp.Code or sp))
					stats.rewards += 1
				end
			end)
		end
	end
end

local function setRewards(on)
	genReward += 1
	local mine = genReward
	rewardOn = on
	if not on then
		return
	end
	task.spawn(function()
		local function alive()
			return rewardOn and genReward == mine
		end
		local r = invoke(R("OfflineEarningsAction"), "Claim", "Free") -- "FiveTimes" is the paid one
		if type(r) == "table" and r.Claimed then
			log("offline earnings claimed:", tostring(r.CashGranted))
		end
		while alive() do
			local good, err = pcall(rewardPass, alive)
			if not good then
				warn("[vault] reward pass:", err)
			end
			task.wait(REWARD_EVERY)
		end
	end)
end

-- cores -----------------------------------------------------------------------
-- MeteorEventState.<id> carries the meteor (CoreId, PersonalUserId, LaunchServerTime, FlightSeconds,
-- Outcome); Workspace.MeteorClaimAnchors.<id> carries its claim prompt. Server reach: ClaimReachStuds.
local coresOn, genCores = false, 0
local coreBench = setmetatable({}, { __mode = "k" })

local function coreClaimable(anchor)
	local stateRoot = ReplicatedStorage:FindFirstChild(MeteorEventConfig.StateName)
	local st = stateRoot and stateRoot:FindFirstChild(anchor.Name)
	if not st or st:GetAttribute("Outcome") ~= nil then
		return nil
	end
	local who = st:GetAttribute("PersonalUserId")
	if who ~= nil and who ~= player.UserId then
		return nil
	end
	local launch, flight = st:GetAttribute("LaunchServerTime"), st:GetAttribute("FlightSeconds")
	if type(launch) == "number" and workspace:GetServerTimeNow() < launch + (flight or 0) then
		return nil
	end
	return st
end

local function corePass(alive)
	local anchors = workspace:FindFirstChild("MeteorClaimAnchors")
	for _, a in ipairs(anchors and anchors:GetChildren() or {}) do
		if not alive() then
			return
		end
		local st = coreClaimable(a)
		local p = a:FindFirstChildWhichIsA("ProximityPrompt", true)
		if st and p and (coreBench[a] or 0) < os.clock() then
			claimWait(function()
				local pos = a:IsA("BasePart") and a.Position or ppos(p) or st:GetAttribute("Landing")
				if typeof(pos) ~= "Vector3" then
					return
				end
				stand(pos + Vector3.new(0, 3, 0))
				press(p)
				local dl = os.clock() + PRESS_CONFIRM
				while os.clock() < dl and st:GetAttribute("Outcome") == nil do
					task.wait()
				end
				local outcome, by = st:GetAttribute("Outcome"), st:GetAttribute("ClaimedByUserId")
				first("core claim", st:GetAttribute("CoreId"), tostring(outcome), tostring(by), ("dist %.1f reach %s"):format(distTo(p), tostring(MeteorEventConfig.ClaimReachStuds)))
				if outcome == "Claimed" and by == player.UserId then
					stats.cores += 1
					say("claimed a " .. tostring(st:GetAttribute("CoreId")))
				else
					coreBench[a] = os.clock() + CORE_BENCH
				end
			end)
		end
	end
end

local function setCores(on)
	genCores += 1
	local mine = genCores
	coresOn = on
	if not on then
		return
	end
	task.spawn(function()
		local function alive()
			return coresOn and genCores == mine
		end
		while alive() do
			local good, err = pcall(corePass, alive)
			if not good then
				warn("[vault] core pass:", err)
			end
			task.wait(CORE_SCAN)
		end
	end)
end

-- boss ------------------------------------------------------------------------
-- Hourly boss fight (BossVaultConfig: 240s). Every 10s a core of yours lands in
-- Workspace.BossVaultEnergyCores (OwnerUserId = you, lives 15s); BossPickupCorePrompt picks it up
-- (server reach CorePickupStuds = 12) as a Tool flagged BossEnergyCoreTool. BossLoadCorePrompt on one
-- of your robots loads it: a 0.75s hold, server reach LoadPromptServerReach = 400, so no walk back.
-- The game's client picks the target (top-3 damage ground robots, not stunned, nearest attacking:
-- BossVaultClient.lua:380-443); the server's rule is unknown, so we take the strongest that qualifies.
-- 7 cores kill the boss, 5 qualify you for the reward. No remotes: prompts only.
local bossOn, genBoss = false, 0

local function bossCoreTool()
	for _, c in ipairs({ player.Character, player:FindFirstChildOfClass("Backpack") }) do
		for _, t in ipairs(c and c:GetChildren() or {}) do
			if t:IsA("Tool") and t:GetAttribute(BossVaultConfig.EnergyToolAttribute) == true then
				return t
			end
		end
	end
	return nil
end

local function myBossCore()
	local folder = workspace:FindFirstChild("BossVaultEnergyCores")
	local now = workspace:GetServerTimeNow()
	for _, m in ipairs(folder and folder:GetChildren() or {}) do
		local strike = m:GetAttribute("StrikeAt")
		if m:IsA("Model") and m:GetAttribute("OwnerUserId") == player.UserId and (type(strike) ~= "number" or strike + 0.3 <= now) then
			return m
		end
	end
	return nil
end

local function loadTarget()
	local best, bestScore
	for _, p in ipairs(CollectionService:GetTagged(BossVaultConfig.PromptTag)) do
		if p:IsA("ProximityPrompt") and p.Name == BossVaultConfig.LoadPromptName and p:GetAttribute("OwnerUserId") == player.UserId then
			local model = p:FindFirstAncestorOfClass("Model")
			local rid = model and model:GetAttribute("RobotId")
			if model and rid and model:GetAttribute("RobotMovementType") ~= "Aerial" and not CollectionService:HasTag(model, BossVaultConfig.StunTag) then
				local s = dps(rid, model:GetAttribute("RobotDamageLevel") or 1) * (model:GetAttribute("RobotState") == "Attacking" and 1 or 0.5)
				if not bestScore or s > bestScore then
					best, bestScore = p, s
				end
			end
		end
	end
	return best
end

-- The game's client keeps these prompts disabled except the one it wants pressed; Enabled is a
-- client-side property here, so open it before pressing (the server's copy decides).
local function holdPress(p, reach)
	p.Enabled = true
	p.MaxActivationDistance = math.max(p.MaxActivationDistance, reach)
	local good = pcall(function()
		p:InputHoldBegin()
		task.wait(p.HoldDuration + 0.1)
		p:InputHoldEnd()
	end)
	if not good then
		pcall(function()
			p:InputHoldEnd() -- a leaked begin leaves the prompt held
		end)
	end
end

local function bossPass(alive)
	if not bossCoreTool() then
		local core = myBossCore()
		local p = core and core:FindFirstChildWhichIsA("ProximityPrompt", true)
		if not (p and p.Name == BossVaultConfig.PickupPromptName) then
			p = core and core:FindFirstChild(BossVaultConfig.PickupPromptName, true)
		end
		if not (core and p) then
			return
		end
		claimWait(function()
			local part = core:FindFirstChild("Core") or core:FindFirstChildWhichIsA("BasePart", true)
			if not part then
				return
			end
			stand(part.Position + Vector3.new(0, 3, 0))
			p.Enabled = true
			pcall(fireproximityprompt, p)
			local dl = os.clock() + PRESS_CONFIRM
			while os.clock() < dl and not bossCoreTool() do
				task.wait()
			end
			if not bossCoreTool() then -- the real input path, in case fpp does not reach this prompt
				holdPress(p, BossVaultConfig.CorePickupStuds)
				dl = os.clock() + PRESS_CONFIRM
				while os.clock() < dl and not bossCoreTool() do
					task.wait()
				end
			end
			first("boss core pickup", bossCoreTool() ~= nil, ("dist %.1f"):format((root() and (root().Position - part.Position).Magnitude) or -1))
		end, 8)
	end
	local tool = bossCoreTool()
	if not (tool and alive()) then
		return
	end
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum and tool.Parent ~= player.Character then
		pcall(hum.EquipTool, hum, tool)
		task.wait(0.1)
	end
	local target = loadTarget()
	if not target then
		say("boss: holding a core, no robot to load it into")
		return
	end
	holdPress(target, BossVaultConfig.LoadPromptServerReach - 10)
	local dl = os.clock() + PRESS_CONFIRM
	while os.clock() < dl and bossCoreTool() do
		task.wait()
	end
	local loaded = bossCoreTool() == nil
	first("boss core load", loaded, target:GetFullName(), ("dist %.1f"):format(distTo(target)))
	if loaded then
		stats.bossCores += 1
		say(("boss: loaded core %d"):format(stats.bossCores))
	elseif fireproximityprompt then
		pcall(fireproximityprompt, target) -- second method before the next pass
	end
end

local function setBoss(on)
	genBoss += 1
	local mine = genBoss
	bossOn = on
	if not on then
		return
	end
	task.spawn(function()
		local function alive()
			return bossOn and genBoss == mine
		end
		while alive() do
			local good, err = pcall(bossPass, alive)
			if not good then
				warn("[vault] boss pass:", err)
			end
			task.wait(0.25)
		end
	end)
end

-- pin: the claim holder's spot, rewritten every frame so nothing drifts or falls ---------
local conns = {}
table.insert(conns, RunService.Heartbeat:Connect(function()
	local r = root()
	if pinCF and r then
		r.CFrame = pinCF
		r.AssemblyLinearVelocity = Vector3.zero
	end
end))
if R("InventoryFullNotification") then
	table.insert(conns, R("InventoryFullNotification").OnClientEvent:Connect(function()
		fullUntil = os.clock() + 30
		say("inventory full: buying paused 30s")
	end))
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Destroy a Vault", statusBar = true })
if not Window then
	if selCon then
		selCon:Disconnect()
	end
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "bot")
local Rolls = Tab:AddLeftGroupbox("Roll & Buy", "dices")
local Robots = Tab:AddLeftGroupbox("Robots & Gold", "bot")
local Up = Tab:AddRightGroupbox("Upgrades", "trending-up")
local Free = Tab:AddRightGroupbox("Rewards & Cores", "gift")

Rolls:AddToggle("Roll", {
	Text = "Auto Roll",
	Tooltip = "Presses your Roll machine the moment it is ready for the next roll (~3s, ~10s after a rare one). Uses the free Lucky Roll when the daily reward has one pending. Rolling is free",
	Default = false,
	Callback = function(state)
		rollOn = state
		setRollBuy()
	end,
})
Rolls:AddToggle("Buy", {
	Text = "Auto Buy Robots",
	Tooltip = "After each reveal, buys the offers you want, best DPS first. With Auto Roll off it buys whatever the machine shows",
	Default = false,
	Callback = function(state)
		buyOn = state
		setRollBuy()
	end,
})
for _, r in ipairs(RARITIES) do
	rarityOn[r] = true -- Default does not fire the callback, so arm by hand
end
Rolls:AddDropdown("BuyRarity", {
	Text = "Rarities to buy",
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
-- Every robot the machine can roll, weakest first, "Name (Rarity)". From RobotDefinitions, so a new
-- robot in a game update shows up here on its own.
local rarityRank = {}
for i, r in ipairs(RARITIES) do
	rarityRank[r] = i
end
local rollable = RobotDefinitions.GetRollable()
table.sort(rollable, function(a, b)
	local ra, rb = rarityRank[a.Rarity] or 99, rarityRank[b.Rarity] or 99
	if ra ~= rb then
		return ra < rb
	end
	return (a.Damage or 0) < (b.Damage or 0)
end)
local nameValues, idByLabel = {}, {}
for _, d in ipairs(rollable) do
	local label = ("%s (%s)"):format(d.DisplayName or d.Id, d.Rarity or "?")
	if idByLabel[label] then
		label = label .. " " .. d.Id -- two robots sharing a display name
	end
	idByLabel[label] = d.Id
	nameValues[#nameValues + 1] = label
end
Rolls:AddDropdown("BuyNames", {
	Text = "Robots to always buy",
	Tooltip = "Bought whenever one is offered and fits the price box, whatever its rarity and whatever you have placed. To buy ONLY these, also press Remove all on Rarities to buy",
	Values = nameValues,
	Default = {},
	Multi = true,
	Searchable = true,
	Callback = function(picked)
		table.clear(nameOn)
		for label in pairs(ticked(picked)) do
			if idByLabel[label] then
				nameOn[idByLabel[label]] = true
			end
		end
	end,
})
Rolls:AddToggle("OnlyBetter", {
	Text = "Only robots that beat my weakest",
	Tooltip = "Skip an offer unless a holder is empty or it out-damages your weakest placed robot. Off buys every ticked rarity you can afford (fills the inventory)",
	Default = true,
	Callback = function(state)
		onlyBetter = state
	end,
})
Rolls:AddInput("MaxPct", {
	Text = "Max robot price (% of cash)",
	Tooltip = "An offer dearer than this share of your cash is skipped, leaving cash for upgrades",
	Default = tostring(MAX_PRICE_PCT),
	Numeric = true,
	Finished = true,
	Placeholder = tostring(MAX_PRICE_PCT),
	Callback = function(v)
		local n = tonumber(v)
		maxPct = (n and n > 0) and math.min(n, 100) or MAX_PRICE_PCT
	end,
})

Robots:AddToggle("Equip", {
	Text = "Auto Equip Best Robots",
	Tooltip = "Fills empty holders with your strongest inventory robots, then swaps your weakest placed robot for a stronger one",
	Default = false,
	Callback = setEquip,
})
Robots:AddToggle("Collect", {
	Text = "Auto Collect Gold",
	Tooltip = "Picks up the gold pile and smelts it into cash, from wherever you stand when the server allows it",
	Default = false,
	Callback = setCollect,
})

Up:AddToggle("Upgrade", {
	Text = "Auto Upgrade",
	Tooltip = "Buys the cheapest affordable of the upgrades ticked below. Robux routes are never touched",
	Default = false,
	Callback = setUpgrade,
})
local UP_LABELS = {
	{ "Damage", "Robot damage" },
	{ "Battery", "Robot battery" },
	{ "Luck", "Roll luck" },
	{ "Spots", "Roll spots" },
	{ "Vault", "Vault tier" },
	{ "Holders", "Robot holders" },
	{ "Robots", "Per-robot damage" },
}
local upValues, upByLabel = {}, {}
for _, u in ipairs(UP_LABELS) do
	upValues[#upValues + 1] = u[2]
	upByLabel[u[2]] = u[1]
end
Up:AddDropdown("UpgradeKinds", {
	Text = "Upgrades to buy",
	Values = upValues,
	Default = upValues,
	Multi = true,
	Callback = function(picked)
		table.clear(upOn)
		for label in pairs(ticked(picked)) do
			if upByLabel[label] then
				upOn[upByLabel[label]] = true
			end
		end
	end,
})
Up:AddInput("RobotCap", {
	Text = "Robot level cap",
	Tooltip = "Per-robot damage upgrades stop at this level. The game has no maximum: each level costs 1.3x the last, +12% damage a level up to 10, +8% after",
	Default = tostring(ROBOT_LEVEL_CAP),
	Numeric = true,
	Finished = true,
	Placeholder = tostring(ROBOT_LEVEL_CAP),
	Callback = function(v)
		local n = tonumber(v)
		robotCap = (n and n >= 1) and math.floor(n) or ROBOT_LEVEL_CAP
	end,
})

Free:AddToggle("Rewards", {
	Text = "Auto Claim Rewards",
	Tooltip = "Daily reward, playtime milestones, the free wheel spin (hops to the wheel) and free offline earnings",
	Default = false,
	Callback = setRewards,
})
Free:AddToggle("Cores", {
	Text = "Auto Pick Up Cores",
	Tooltip = "During a meteor event, hops to each of your landed core meteors and claims it",
	Default = false,
	Callback = setCores,
})
Free:AddToggle("Boss", {
	Text = "Auto Boss Cores",
	Tooltip = "During the hourly boss fight, picks up each energy core that lands for you and loads it into your strongest ground robot (5 qualify you for the reward, 7 kill the boss)",
	Default = false,
	Callback = setBoss,
})

-- Status text is computed on a plain thread (it calls game modules); the Heartbeat only copies it.
local strip = { cash = "-", placed = "-" }
local stripAlive = true
task.spawn(function()
	while stripAlive do
		pcall(function()
			strip.cash = fmt(cash())
			strip.placed = ("%d/%d"):format(#placed(), sd("GetUnlockedRobotHolderCount") or 0)
		end)
		task.wait(0.5)
	end
end)
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
	Window:SetStatus({
		{ "Cash", strip.cash },
		{ "Rolls", stats.rolls },
		{ "Bought", stats.bought },
		{ "Placed", strip.placed },
		{ "Banked", fmt(stats.banked) },
		{ "Upgrades", stats.upgrades },
		{ "Cores", stats.cores },
		{ "Boss", stats.bossCores },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("DestroyAVault", {})

local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- close ----------------------------------------------------------------------
local function stopAll()
	rollOn, buyOn = false, false
	setRollBuy()
	setEquip(false)
	setCollect(false)
	setUpgrade(false)
	setRewards(false)
	setCores(false)
	setBoss(false)
	stripAlive = false
	pinCF = nil
	if selCon then
		selCon:Disconnect()
		selCon = nil
	end
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().vaultStop = nil
end)

getgenv().vaultStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().vaultStop = nil
end
