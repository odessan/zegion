--[[ Poop for Brainrots -- Poop for a Brainrot (87810710637189)

     POOP     : the charge bar and the flight are client visuals. The server only ever
                sees BeginKick, SubmitKickAlpha(alpha), ClaimKickReward(id) and
                ReturnFromKick, so this fires those and skips the animation.
                Two things the server does still check, and both cost a move:
                  * the claim is distance-checked against where the poop landed, so
                    the cycle teleports to the node's landingPosition first. That
                    teleport is fine -- the game's own landing handler does it too.
                  * OUTSIDE a kick session it speed-checks you, so the leg from the
                    base spawn back to the throw zone is walked, not teleported.
                    That walk is the slow part of a cycle, about five seconds.
     POWER    : the alpha the charge bar would have been at. It is a plain 0-1 number
                the client picks, the server just clamps it, and higher is always
                farther, so 1 is the perfect kick every time. Left as a box because
                it is the one number worth arguing with.
     BEST     : you cannot pick WHICH brainrots get rolled -- the server rolls 15-20 of
                them from a luck band set by the landing distance before the client
                hears about any of it. What you can do is take the best one out of that
                roll, which is what this does: rarity first, income second. Distance is
                the only lever on the roll itself, and it is fat x alpha, so the fat
                loops below are the real "get better brainrots" switch.
     CLAIMS   : one per kick, three with the VIP pass. The panel claims that many, best
                first, then Returns without waiting for the poop to land.
     FRENZY   : the x2 circle spawns client-side and reports back how much of its 2s
                window was left. Claiming at 1 is a perfect hit, and ten of them opens
                a x2 fat frenzy. Needs food equipped -- that is what FOOD is for.
     FOOD     : buys every food it can afford, worst to best (the server refuses the
                ones you cannot), then holds the best you own, which is what eating is.
                Note EquipFood(key) does NOT do that on its own -- it writes the
                `foodEquipped` player-data key, which is only which food is SELECTED in
                the shop. Eating means the food Tool being on your character, since
                Tool.lua:93 is the one place equippedItemType is set and it reads it off
                that Tool. So food is held through the same AddToolToBackpack +
                EquipTool path the placer uses for brainrots.
                Anything that puts something else in your hands therefore stops the
                eating -- a claimed kick reward does, and so does placing one -- so both
                of those re-hold the food before they finish.
                The chewing animation is stopped as it replays: it is a local visual
                that reports nothing back, so losing it costs no fat.
     COINS    : claimed at the crater BEFORE the brainrot -- taking the last claim ends
                the session and sends you home, which leaves nothing for a coin claim
                to land in.
     PLACE    : what the paid Equip Best pad does, without paying for it. That pad is
                the `equipBest` dev product, but the free path is the one the game hands
                you anyway: hold a brainrot, stand on a slot, press E. Both PlacePrompt
                and SwapPrompt are server-handled, so fireproximityprompt is the whole
                trick. Best spare into the first empty slot, and it stops there: it will
                not displace anything already placed. Deciding a swap needs the income/s
                of the brainrot on the slot, and the client is never told it -- the only
                number a slot wears is unclaimed cash, not a rate. Anything you have
                LOCKED is left alone either way.
     SELL     : the backlog valve, since a kick farm fills the plot in about a minute
                and then PLACE just sits at "plot full". Sells spare brainrots earning
                less than the "Sell under" box, worst first, through the stand's
                per-item prompt. Blank or 0 sells nothing -- the safe default for
                something destructive is off, so it does nothing until you type a number.
                Locked items are never touched, and neither is anything on the plot.
                Note the stand also carries a ProximityPromptSellInventory that would
                empty the backlog in one press. Nothing in the client touches it, so
                there is no evidence either way about whether it respects locks, and
                that is the wrong thing to guess about. One at a time is auditable.
     PLOT     : ClaimEarnings and UpgradeBrainrot over all ten slots by name, plus the
                base and speed upgrades, all as remotes -- nothing here needs you to be
                standing anywhere.

     No row in this panel can open a Robux prompt, and that took some care: PickupAllCash
     and EquipBest are a gamepass and a dev product that the SERVER turns into a purchase
     prompt when you don't own them, and UpgradeSpeed, Rebirth and ClaimOfflineEarnings
     each take an optional second argument that is the paid route. If you add a call
     here, check Info/Store/GamepassesInfo and MiscellaneousDevProductsInfo first.
     REWARDS  : quests, dailies and playtime claims, brute-forced over their index
                ranges. The server refuses the ones that are not ready.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl hides/shows it. Stop: getgenv().poopRotsStop() ]]

-- config ---------------------------------------------------------------------
local POWER = 1 -- SubmitKickAlpha. 0-1, >0.9 is a "perfect", 1 is the longest kick
local POLL = 0.05 -- seconds between node re-reads while waiting on the server
local STEP_TIMEOUT = 4 -- seconds waiting for a kick to change state before giving up
local SETTLE = 4 -- ping multiplier after a teleport; raise if the claim keeps missing
local WALK_TIMEOUT = 12 -- seconds walking back to the throw zone before giving up and
-- teleporting anyway. The walk is there because the server speed-checks you outside a
-- kick session -- "You're going too fast" is that check, not a rate limit
local ARRIVE = 8 -- studs from the throw zone that count as arrived
local KICK_EVERY = 0.1 -- pause between kick cycles; the cycle is already round-trip bound
local FRENZY_EVERY = 0.25 -- seconds between x2 circle claims. The real game respawns a
-- circle the instant you hit one, so the ceiling here is reaction time, not a cooldown
local FOOD_EVERY = 10 -- seconds between food buy/equip passes; each pass spends cash
local EAT_EVERY = 0.5 -- seconds between eating-animation stops; the game replays the
-- track on every equip and on any fat change big enough to reweight it
local PLACE_EVERY = 2 -- seconds between placements. One brainrot per pass, so ten empty
-- slots take about twenty seconds plus the walking
local SELL_EVERY = 3 -- seconds between sell batches. The stand does not move, so one
-- walk covers the whole batch and this is really just the gap between batches
local COLLECT_EVERY = 5 -- seconds between plot earnings sweeps
local UPGRADE_EVERY = 1 -- seconds between brainrot upgrade rounds; server refuses when broke
local SPEND_EVERY = 5 -- seconds between base/speed upgrade attempts; these drain cash
local REWARDS_EVERY = 30 -- seconds between reward claim sweeps; nothing here is urgent
local REBIRTH_EVERY = 10 -- seconds between rebirth attempts
local HOTBAR_SLOTS = 9 -- Configs/HotbarConfigs.HOTBAR_SLOTS, copied because it is one number
local KEY_TOGGLE = Enum.KeyCode.RightControl

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService") -- only the shade uses this
local player = Players.LocalPlayer
local ping = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]
local uid = tostring(player.UserId)

if getgenv and getgenv().poopRotsStop then
	getgenv().poopRotsStop() -- re-running must not stack a second panel/loop
end

-- Knit, vendored under _Index. Quoted rather than indexed because of the @ in the name.
local Services = ReplicatedStorage
	:WaitForChild("Packages")
	:WaitForChild("_Index")
	:WaitForChild("sleitnick_knit@1.7.0")
	:WaitForChild("knit")
	:WaitForChild("Services")
local GameRF = Services:WaitForChild("Game"):WaitForChild("RF")
local RewardRF = Services:WaitForChild("Reward"):WaitForChild("RF")

-- The game's own tables. Requiring beats copying: the brainrot list is hundreds of
-- entries, the rarity order is the thing every ranking here leans on, and BigNum is
-- the only way to compare two incomes that are both past 2^53.
-- ponytail: one pcall around the lot. If any of it moves the ranking degrades to
-- "first reward the roll happened to hand back", which is still a working farm.
local Nodes, PlayerData, BigNum, Rarities, Brainrots, LuckyBlocks, Foods, Poops, BrainrotConfigs
pcall(function()
	local Source = ReplicatedStorage:WaitForChild("Source")
	local Engine = Source.PlaywooEngine
	Nodes = require(Engine.BaseHandlers.ReplicatedNodeHandler)
	PlayerData = require(Engine.BaseHandlers.PlayerDataHandler)
	BigNum = require(Engine.Utils.BigNum)
	Rarities = require(Source.Info.RaritiesInfo)
	Brainrots = require(Source.Info.BrainrotsInfo)
	LuckyBlocks = require(Source.Info.LuckyBlocksInfo)
	Foods = require(Source.Info.FoodsInfo)
	Poops = require(Source.Info.PoopsInfo)
	BrainrotConfigs = require(Source.Configs.BrainrotConfigs)
end)
if not Nodes then
	warn("[PoopRots] could not require ReplicatedStorage.Source -- reward ranking is off")
end

local say = function() end -- replaced by the panel below

-- The server rejecting you (broke, not ready, wrong state) is the normal case in every
-- loop here, so a failed call is data, not a reason to stop. Only a thrown error is
-- worth the console.
local function invoke(rf, ...)
	if not rf then
		return nil
	end
	local ok, res = pcall(rf.InvokeServer, rf, ...)
	if not ok then
		warn("[PoopRots]", rf.Name, res)
		return nil
	end
	return res
end

local function pathValue(...)
	if not PlayerData then
		return nil
	end
	local ok, v = pcall(PlayerData.GetPathValue, { ... })
	return ok and v or nil
end

-- world ----------------------------------------------------------------------
local function hrp()
	local char = player.Character or player.CharacterAdded:Wait()
	return char:WaitForChild("HumanoidRootPart", 10)
end

local function humanoid()
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

-- Teleport is instant client-side; the server needs a round trip or two before it
-- agrees you moved, and both the kick's throw-zone check and its claim distance check
-- read that position. Streaming leaves you paused with nothing loaded, so wait it out.
local function tp(pos)
	local root = hrp()
	if not root then
		return false
	end
	root.CFrame = typeof(pos) == "Vector3" and CFrame.new(pos) or pos
	task.wait((ping:GetValue() * SETTLE) / 1000)
	while player.GameplayPaused do
		task.wait(POLL)
	end
	return true
end

-- Outside a kick session the server runs a movement speed check, so the leg from the
-- base spawn back to the throw zone has to be walked -- roughly 110 studs, five
-- seconds. Inside a session it does not: the game's own landing handler pivots your
-- character straight to the crater, which is why the claim teleport below is a
-- teleport. ponytail: falls back to a teleport on timeout rather than stalling the
-- farm, so a walk blocked by geometry shows up as the speed warning and not silence.
local function walkTo(pos)
	local hum, root = humanoid(), hrp()
	if not (hum and root) then
		return false
	end
	local t0 = os.clock()
	while os.clock() - t0 < WALK_TIMEOUT do
		if (root.Position - pos).Magnitude < ARRIVE then
			return true
		end
		hum:MoveTo(pos)
		hum.MoveToFinished:Wait() -- times out on its own after 8s of no progress
	end
	if (root.Position - pos).Magnitude < ARRIVE then
		return true
	end
	say("walk back timed out -- teleporting, expect a speed warning")
	return tp(pos)
end

-- Equipping is the Tool/Backpack system, not a remote of its own: AddToolToBackpack
-- makes the Tool, Humanoid:EquipTool puts it in your hands. Straight out of
-- GameModules/Tool.lua's own Equip, minus requiring that stateful singleton.
--
-- With one addition it does not have. Tool:Equip has exactly one caller in the whole
-- game (Hotbar.lua's slot select) and it is only ever handed a HOTBAR entry, so the
-- server has never been asked to build a Tool for a loose backpack item and may well
-- refuse to. If no Tool appears, stage the item into a free hotbar slot with
-- SwapStorage and ask again. Returns (ok, reason) so the caller can say which step lost.
local function equipItem(id)
	local hum = humanoid()
	if not hum then
		return false, "no humanoid"
	end
	if player:GetAttribute("equippedItemId") == id then
		return true
	end
	hum:UnequipTools()
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return false, "no Backpack"
	end

	local function toolFor()
		return backpack:FindFirstChild(id)
	end

	local tool = toolFor()
	if not tool then
		invoke(GameRF.AddToolToBackpack, { id = id })
		tool = waitFor(toolFor, STEP_TIMEOUT)
	end

	if not tool then
		local hotbar = pathValue("hotbar") or {}
		local free
		for i = 1, HOTBAR_SLOTS do
			if not hotbar["hotbar" .. i] then
				free = "hotbar" .. i
				break
			end
		end
		if not free then
			return false, "no Tool and no free hotbar slot to stage it in"
		end
		-- SwapStorage fills in the destination's current occupant itself, so naming the
		-- key is enough; a free slot means nothing comes back the other way.
		invoke(GameRF.SwapStorage, { location = "backpack", itemId = id }, { location = "hotbar", key = free })
		invoke(GameRF.AddToolToBackpack, { id = id })
		tool = waitFor(toolFor, STEP_TIMEOUT)
	end
	if not tool then
		return false, "AddToolToBackpack never produced a Tool"
	end

	hum:EquipTool(tool)
	if waitFor(function()
		return player:GetAttribute("equippedItemId") == id
	end, STEP_TIMEOUT) then
		return true
	end
	return false, "EquipTool didn't stick"
end

-- Everything on your plot hangs off the base number the server teleported you to, so
-- nothing below hardcodes a coordinate: the same code works on all eight bases.
local function playArea()
	local n = player:GetAttribute("baseNumberTeleportedTo") or player:GetAttribute("baseNumber")
	if not n then
		return nil
	end
	local map = workspace:FindFirstChild("Map")
	local bases = map and map:FindFirstChild("PlayerBases")
	local base = bases and bases:FindFirstChild(tostring(n))
	return base and base:FindFirstChild("PlayArea")
end

local function throwZone()
	local area = playArea()
	local triggers = area and area:FindFirstChild("AreaTriggers")
	return triggers and triggers:FindFirstChild("ThrowZone")
end

-- Slot models. Their own names ("1".."10") are exactly what ClaimEarnings and
-- UpgradeBrainrot want, and the models carry the hasBrainrot attribute and the place /
-- swap prompts the placer needs, so one scan serves all three.
-- ponytail: Base.BrainrotSlots only, which is what the game's own PlayerBase binds
-- (_SetBase watches Base for a child named BrainrotSlots and nothing else). The
-- Base.Floors.FloorN.BrainrotSlots folders sit empty on a live base; if a floor unlock
-- ever starts filling them, scan those too -- but note the names repeat per floor, so
-- the slot id stops being unique at that point.
local function slotModels()
	local area = playArea()
	local base = area and area:FindFirstChild("Base")
	local folder = base and base:FindFirstChild("BrainrotSlots")
	return folder and folder:GetChildren() or {}
end

local function waitFor(pred, timeout)
	local t0 = os.clock()
	repeat
		local v = pred()
		if v then
			return v
		end
		task.wait(POLL)
	until os.clock() - t0 > timeout
	return nil
end

-- ranking --------------------------------------------------------------------
-- Rarity first: it is the axis the kick's luck roll actually moves, and a Divine at
-- level 1 beats a maxed Legendary. Income breaks the tie, and it already folds in
-- tier and level so nothing else needs comparing.
local function betterThan(a, b)
	if a.rarity ~= b.rarity then
		return a.rarity > b.rarity
	end
	return a.rps > b.rps
end
assert(betterThan({ rarity = 9, rps = 0 }, { rarity = 8, rps = 1e9 }), "rarity outranks income")
assert(betterThan({ rarity = 5, rps = 2 }, { rarity = 5, rps = 1 }), "income breaks a rarity tie")
assert(not betterThan({ rarity = 5, rps = 1 }, { rarity = 5, rps = 1 }), "a tie is not better")

-- A rolled reward is {type, key, tier, level, revenuePerSecond}. Lucky blocks have no
-- income, so they rank on rarity alone and lose every tie to a brainrot of the same
-- rarity -- which is the right call, since the block still has to be opened.
local function grade(reward)
	local info
	if reward.type == "brainrot" then
		info = Brainrots and Brainrots.byKey[reward.key]
	else
		info = LuckyBlocks and LuckyBlocks.byKey[reward.key]
	end
	local rarity = 0
	if info and Rarities then
		rarity = Rarities.rarityIndexByKey[info.rarity] or 0
	end
	local rps = 0
	if BigNum and reward.revenuePerSecond then
		local ok, n = pcall(BigNum.ToNumber, reward.revenuePerSecond)
		rps = ok and n or 0
	end
	return { rarity = rarity, rps = rps }
end

local function label(reward)
	local info = reward.type == "brainrot" and Brainrots and Brainrots.byKey[reward.key]
		or LuckyBlocks and LuckyBlocks.byKey[reward.key]
	local name = info and info.name or reward.key or "?"
	if reward.type == "brainrot" and reward.level then
		return ("%s Lv.%d"):format(name, reward.level)
	end
	return name
end

-- kick -----------------------------------------------------------------------
-- The whole session lives in one replicated node keyed by user id. status walks
-- aiming -> claiming -> ended, and the rewards land on it the moment the server has
-- rolled them, which is well before the client finishes animating the flight.
local function kickEntry()
	local all = Nodes and Nodes.Get("footballKicks")
	return type(all) == "table" and all[uid] or nil
end

local power = POWER
local grabCoins = false
local keepFood = false
local selling = false
local sellFloor = 0 -- income/s under which a spare gets sold. 0 = sell nothing, and it
-- stays 0 until you type a number, because the safe default for "destroy things" is off
local sellFloorText = "0"
local refood = function() end -- filled in by the fat section below; kickOnce is first

-- Mutation coins scatter around the crater on their own node, one entry per coin id,
-- so they only claim while you're standing there -- hence a flag the kick cycle reads
-- rather than a loop of its own.
--
-- Where the coins physically ARE is client-side randomness (GameModules/MutationCoins
-- rolls the scatter with its own Random on the landing signal), so the server has no
-- per-coin position to distance-check you against -- standing on the landing point is
-- as close as it can ask for. Returns how many ids the node HELD, not how many the
-- server accepted -- ClaimMutationCoin answers with nothing, so there is no confirming
-- it. That still separates "no coins rolled this kick" from "coins rolled and none of
-- them landed", which are the two things worth telling apart in the status line.
local function coinsOnce()
	local coins = Nodes and Nodes.Get("mutationCoins[" .. uid .. "]")
	if type(coins) ~= "table" then
		return 0
	end
	local seen = 0
	for id in pairs(coins) do
		invoke(GameRF.ClaimMutationCoin, id)
		seen += 1
	end
	return seen
end

local function kickOnce()
	local zone = throwZone()
	if not zone then
		say("no throw zone -- are you at your own base?")
		return false
	end

	-- isInThrowZone is the client's own AreaTrigger flag: the world telling us we're
	-- standing in the right place, rather than a distance guess against a trigger
	-- volume. It also means a cycle that never left skips the walk entirely.
	if not player:GetAttribute("isInThrowZone") then
		if not walkTo(zone.Position) then
			say("couldn't reach the throw zone")
			return false
		end
	end

	invoke(GameRF.BeginKick)
	-- Waiting for "aiming" rather than sleeping a fixed amount: an alpha submitted
	-- against a session the server has not opened yet is silently dropped, and that
	-- reads as "the farm does nothing" with no error anywhere.
	if
		not waitFor(function()
			local e = kickEntry()
			return e and e.status == "aiming"
		end, STEP_TIMEOUT)
	then
		invoke(GameRF.CancelKick)
		say("kick never started -- not in the throw zone?")
		return false
	end

	invoke(GameRF.SubmitKickAlpha, math.clamp(tonumber(power) or POWER, 0, 1))

	local entry = waitFor(function()
		local e = kickEntry()
		if e and e.status == "claiming" and type(e.rewards) == "table" and next(e.rewards) then
			return e
		end
		return nil
	end, STEP_TIMEOUT)
	if not entry then
		invoke(GameRF.ReturnFromKick)
		say("no rewards rolled")
		return false
	end

	-- The claim is distance-checked against where the poop landed -- "You are too far
	-- from the claim area" is that check, and it's the one thing skipping the flight
	-- costs you. The node carries the authoritative landing position, so go stand on
	-- it. Same +3 Y the game's own landing handler uses, so you don't land inside the
	-- floor. Mutation coins scatter around the same point, which is why they get
	-- collected here rather than on a loop of their own.
	local landing = entry.landingPosition
	if typeof(landing) == "Vector3" then
		tp(landing + Vector3.new(0, 3, 0))
	end

	-- Coins BEFORE the brainrot, on purpose. Taking the last claim (claimsLeft hits 0)
	-- appears to end the session server-side and send you home, and a coin claim after
	-- that has nothing to land in. Costs nothing to do it in this order either way.
	local coins = grabCoins and coinsOnce() or 0

	local picks = {}
	for id, reward in pairs(entry.rewards) do
		local g = grade(reward)
		g.id, g.reward = id, reward
		table.insert(picks, g)
	end
	table.sort(picks, betterThan)

	-- claimsLeft is 1 without the VIP pass and 3 with it, and it does not roll over.
	local left = tonumber(entry.claimsLeft) or 1
	local taken = {}
	for i = 1, math.min(left, #picks) do
		if invoke(GameRF.ClaimKickReward, picks[i].id) then
			table.insert(taken, label(picks[i].reward))
		end
	end

	-- ReturnFromKick is what teleports you home, and it is a server teleport, so it
	-- never trips the speed check the way walking yourself back out would.
	invoke(GameRF.ReturnFromKick)

	-- Do this every cycle rather than leaving it to the 10s food pass: the brainrot is
	-- in your hands the whole time in between, and that is time not spent eating.
	if keepFood then
		refood()
	end

	local coinNote = coins > 0 and (" +%d coins"):format(coins) or ""
	if #taken > 0 then
		say(("took %s -- best of %d%s"):format(table.concat(taken, ", "), #picks, coinNote))
		return true
	end
	say(("claimed nothing out of %d rolled%s"):format(#picks, coinNote))
	return false
end

-- fat ------------------------------------------------------------------------
-- Alpha 1 is a circle hit with its whole 2s window still on the clock, which is the
-- most progress a claim can be worth. Ten of them opens the x2 frenzy.
local function frenzyOnce()
	invoke(GameRF.ClaimX2FatCircle, 1)
end

-- Buy worst-to-best so a pass that can only afford the cheap upgrade still takes it,
-- then equip the best owned. PurchaseFood on something you cannot afford is a no-op
-- server-side, which is cheaper than reading the cash balance and comparing BigNums.
local function bestFood()
	if not Foods then
		return nil
	end
	local owned = pathValue("ownedFoods") or {}
	local best
	for _, key in ipairs(Foods.keys) do
		if owned[key] or (Foods.byKey[key] and Foods.byKey[key].isDefault) then
			best = key -- keys are listed worst-first, so the last match is the best
		end
	end
	return best
end

-- Food is an ordinary inventory item with an id, exactly like a brainrot, so it has to
-- be found by (type, key) before it can be held.
local function foodItemId(key)
	for id, item in pairs(pathValue("inventory") or {}) do
		if type(item) == "table" and item.type == "food" and item.key == key then
			return id
		end
	end
	return nil
end

-- EquipFood and "holding the food" are two different things, and getting that wrong is
-- what left this eating nothing. EquipFood(key) writes the `foodEquipped` player-data
-- key -- which food is SELECTED, the tick in the food shop. What the game means by
-- eating is the food Tool being on your character: Tool.lua:93 is the only place
-- equippedItemType is ever set, and it sets it from that Tool appearing. So select it,
-- then actually equip it, same Tool path the placer uses for brainrots.
--
-- Assignment, not `local function`: kickOnce is defined above this and holds the
-- forward-declared upvalue.
refood = function()
	local key = bestFood()
	if not key then
		return false
	end
	invoke(GameRF.EquipFood, key) -- selects it, and is what creates the item if you just bought it
	local id = foodItemId(key)
	if not id then
		say("no food item to hold -- buy one first")
		return false
	end
	if equipItem(id) then
		return true
	end
	say("couldn't get the food back into your hands")
	return false
end

local function foodOnce()
	if not Foods then
		return
	end
	for _, key in ipairs(Foods.keys) do
		invoke(GameRF.PurchaseFood, key)
	end
	refood()
end

-- Equipped food ticks fat server-side on a timer; the chewing loop is pure client
-- visual (GameModules/Tool/Food.lua plays two blended tracks and reports nothing back),
-- so stopping the tracks costs the wobble and nothing else. Ids copied out of
-- Configs/FoodConfigs -- if an update changes them the animation just comes back.
-- Has to be a loop: the game replays both tracks on every equip and whenever your fat
-- moves far enough to reweight the fat/skinny blend.
local EAT_ANIMS = {
	["rbxassetid://74122692525028"] = true, -- EATING_ANIMATION
	["rbxassetid://100092424073993"] = true, -- EATING_ANIMATION_SKINNY
}

local function stopEatAnimation()
	local hum = humanoid()
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		if EAT_ANIMS[track.Animation.AnimationId] then
			track:Stop(0)
		end
	end
end

-- Poops are a flat luck bonus on the roll (+30/60/90%), gamepass-gated, so this is
-- an equip and never a purchase.
local function equipBestPoop()
	if not Poops then
		say("poop list unavailable")
		return
	end
	local owned = pathValue("ownedPoops") or {}
	local passes = pathValue("gamepasses") or {}
	local best, bestBoost
	for _, key in ipairs(Poops.keys) do
		if owned[key] or passes[key] or Poops.byKey[key].isDefault then
			local boost = Poops.byKey[key].luckBoostPercent or 0
			if not bestBoost or boost > bestBoost then
				best, bestBoost = key, boost
			end
		end
	end
	if best then
		invoke(GameRF.EquipPoop, best)
		say(("equipped %s (+%d%% luck)"):format(Poops.byKey[best].name, bestBoost))
	end
end

-- place ----------------------------------------------------------------------
-- What the paid EquipBest pad does, done with the prompts instead. The pad is the
-- `equipBest` dev product; the free path is the one the game gives you by hand --
-- hold a brainrot, stand on a slot, press E -- and both PlacePrompt and SwapPrompt are
-- server-handled, so fireproximityprompt is the whole mechanism.

-- The revenue label the slot wears, e.g. "$11.3k" or "$42.93 M/s", sometimes wrapped in
-- the <font> tags CashConfigs.GetText adds. Split only -- the suffix maths is BigNum's.
local function splitCash(text)
	if type(text) ~= "string" then
		return nil
	end
	local body = text:gsub("<[^>]->", ""):gsub(",", "")
	local num, suffix = body:match("(%d+%.?%d*)%s*(%a*)")
	if not num then
		return nil
	end
	-- BigNum's table is "K" "M" "B" "T" "Qa" "Qi" ... "Nod" -- first letter up, rest
	-- down, which is exactly what the two different formatters in this game disagree on.
	return num, suffix:sub(1, 1):upper() .. suffix:sub(2):lower()
end
assert(select(2, splitCash("$11.3k")) == "K", "lowercase suffix is normalised")
assert(splitCash("$11.3k") == "11.3", "the $ is not part of the number")
assert(select(2, splitCash("$42.93 M/s")) == "M", "a space before the suffix is allowed")
assert(select(2, splitCash("<font color='rgb(1,2,3)'>$1.2Qa</font>")) == "Qa", "tags stripped")
assert(splitCash("$1,250") == "1250", "thousands separators dropped")
assert(select(2, splitCash("$500")) == "", "a bare number has no suffix")
assert(splitCash("no digits here") == nil, "unparseable text is nil, not zero")

-- NOT a rate. TextLabelRevenue is the unclaimed cash sitting on the slot waiting to be
-- collected -- no "/s" on it, unlike the base's RebirthInfoSign TextLabelIncome which
-- reads "$42.81K/s". Diagnostics only; see the note on swapping in placeOnce.
-- Any suffixed cash string to a plain number, through the game's own suffix table
-- rather than a copy of it. Serves both the slot labels and whatever you type in the
-- sell box, so "500M" and "$500 M" and "500000000" all land in the same place.
local function toNumber(text)
	local num, suffix = splitCash(text)
	if not num then
		return nil
	end
	if not BigNum then
		return tonumber(num)
	end
	local ok, n = pcall(function()
		return BigNum.ToNumber(BigNum.fromString(num .. suffix))
	end)
	return ok and n or nil
end

local function slotPending(slot)
	local gui = slot:FindFirstChild("SurfaceGuiCollectEarnings")
	local label = gui and gui:FindFirstChild("TextLabelRevenue")
	return label and toNumber(label.Text) or nil
end

local function income(item)
	if not (BrainrotConfigs and BigNum) then
		return 0
	end
	local ok, n = pcall(function()
		return BigNum.ToNumber(BrainrotConfigs.GetRevenuePerSecond(item))
	end)
	return ok and n or 0
end

-- A brainrot sitting in your backpack or hotbar is by definition not placed -- those
-- two are the only containers that hold loose items. That sidesteps having to work out
-- which inventory entries are already on the plot, which the client is never told.
-- Locked items are left alone: locking one is you saying don't touch it.
local function spares()
	local inv = pathValue("inventory") or {}
	local ids = {}
	for _, entry in pairs(pathValue("backpack") or {}) do
		if type(entry) == "table" and entry.id then
			ids[entry.id] = true
		end
	end
	for _, entry in pairs(pathValue("hotbar") or {}) do
		if type(entry) == "table" and entry.id then
			ids[entry.id] = true
		end
	end
	local out = {}
	for id in pairs(ids) do
		local item = inv[id]
		if type(item) == "table" and item.type == "brainrot" and not item.locked then
			table.insert(out, { id = id, item = item, rps = income(item) })
		end
	end
	table.sort(out, function(a, b)
		return a.rps > b.rps
	end)
	return out
end

-- Every exit from here says WHY, to the panel and once to the console. Nine different
-- things can stop a placement -- no spares, no slots, plot full, tool wouldn't equip,
-- couldn't walk there, prompt missing, prompt disabled, server refused -- and "it
-- doesn't work" is unanswerable without knowing which. ponytail: printing only on a
-- CHANGE of message, since this runs every couple of seconds.
local lastWhy = ""
local function why(msg)
	say(msg)
	if msg ~= lastWhy then
		lastWhy = msg
		print("[PoopRots] place:", msg)
	end
	return false
end

-- One placement per pass, re-reading the world each time. A swap hands you the brainrot
-- it displaced, which invalidates both the candidate list and the slot table, so doing
-- a batch would mean rebuilding them mid-loop anyway. This converges on its own: it
-- only ever swaps for a strict improvement.
local function placeOnce()
	if not fireproximityprompt then
		return why("placing needs an executor (no fireproximityprompt)")
	end
	local cands = spares()
	local slots = slotModels()
	if #slots == 0 then
		return why("no BrainrotSlots found under your base")
	end
	if #cands == 0 then
		return why("nothing spare to place -- no unlocked brainrots in backpack or hotbar")
	end
	local best = cands[1]

	local target, promptName
	for _, slot in ipairs(slots) do
		if slot:GetAttribute("hasBrainrot") ~= true then
			target, promptName = slot, "PlacePrompt"
			break
		end
	end

	-- ponytail: empty slots only, no swapping out. Deciding a swap needs the income/s of
	-- the brainrot ALREADY on the slot, and the client is never told it -- the slot's
	-- only number is TextLabelRevenue, which is unclaimed cash, not a rate. Comparing a
	-- spare's income/s against that is a unit mismatch that would happily displace a
	-- 155B/s brainrot because its pending pile had just been collected. To do swaps
	-- properly you would need the placed brainrot's key and level, which means reading
	-- them off the slot's BrainrotPart model rather than any label.
	if not target then
		return why(("plot full -- all %d slots occupied, %d spare waiting"):format(#slots, #cands))
	end

	local held, reason = equipItem(best.id)
	if not held then
		return why(("couldn't hold %s -- %s"):format(label(best.item), reason or "?"))
	end
	if not walkTo(target:GetPivot().Position) then
		return why(("couldn't reach slot %s"):format(target.Name))
	end

	local attachment = target:FindFirstChild("AttachmentProximityPrompt")
	local prompt = attachment and attachment:FindFirstChild(promptName)
	if not prompt then
		return why(("slot %s has no %s"):format(target.Name, promptName))
	end

	-- Enabled is driven by hasBrainrotEquipped, which the client's own Tool module sets a
	-- frame or two after the tool lands, so wait for it rather than firing into a prompt
	-- that is still off.
	if not waitFor(function()
		return prompt.Enabled
	end, STEP_TIMEOUT) then
		return why(("slot %s's %s stayed disabled"):format(target.Name, promptName))
	end

	-- Both of these prompts are HoldDuration 0.5, unlike the UpgradePrompt next to them.
	-- Zeroing it locally turns the hold into a tap: the hold is evaluated on the client
	-- and only the finished Triggered reaches the server, so nothing downstream can tell.
	local hold = prompt.HoldDuration
	prompt.HoldDuration = 0

	-- Wait for the world, never the return value: hasBrainrot flipping (or the held id
	-- changing, for a swap) is the server confirming it took.
	local before = player:GetAttribute("equippedItemId")
	local done = waitFor(function()
		fireproximityprompt(prompt)
		if promptName == "PlacePrompt" then
			return target:GetAttribute("hasBrainrot") == true
		end
		return player:GetAttribute("equippedItemId") ~= before
	end, STEP_TIMEOUT)

	pcall(function()
		prompt.HoldDuration = hold
	end)

	-- Placing needed the brainrot in hand, so the food came out to make room. Put it
	-- back before this pass ends, or the gap until the next kick is time not eating.
	if keepFood then
		refood()
	end

	if not done then
		return why(("slot %s wouldn't take it -- server refused the %s"):format(target.Name, promptName))
	end
	lastWhy = ""
	say(
		("%s slot %s (%s) -- %d spare left"):format(
			promptName == "SwapPrompt" and "swapped into" or "placed in",
			target.Name,
			label(best.item),
			#cands - 1
		)
	)
	return true
end

-- sell -----------------------------------------------------------------------
-- Same shape as the placer -- hold it, stand there, fire the prompt -- but the stand
-- does not move, so one walk covers a whole batch instead of one item.
--
-- ponytail: the per-item ProximityPromptSellEquippedItem, deliberately, even though
-- ProximityPromptSellInventory is sitting right next to it and would clear the backlog
-- in one press. Nothing in the client touches that second prompt, so there is no
-- readable evidence of whether it spares locked items, and "sells your entire
-- inventory" is the wrong thing to be wrong about. One at a time is auditable.
local function sellStand()
	local area = playArea()
	local stands = area and area:FindFirstChild("Stands")
	local stand = stands and stands:FindFirstChild("SellStand")
	if not stand then
		return nil, nil
	end
	local att = stand:FindFirstChild("Attachment")
	return att and att:FindFirstChild("ProximityPromptSellEquippedItem"), stand
end

local lastSellWhy = ""
local function whySell(msg)
	say(msg)
	if msg ~= lastSellWhy then
		lastSellWhy = msg
		print("[PoopRots] sell:", msg)
	end
	return false
end

local function sellOnce()
	if not fireproximityprompt then
		return whySell("selling needs an executor (no fireproximityprompt)")
	end
	if sellFloor <= 0 then
		return whySell("sell threshold is 0 -- nothing qualifies. Set it to e.g. 100M")
	end
	local prompt, stand = sellStand()
	if not prompt then
		return whySell("no SellStand under your base's Stands folder")
	end

	-- spares() already drops anything locked, which is the safety net that matters here.
	local junk = {}
	for _, c in ipairs(spares()) do
		if c.rps < sellFloor then
			table.insert(junk, c)
		end
	end
	if #junk == 0 then
		return whySell(("nothing under %s/s to sell"):format(sellFloorText))
	end
	table.sort(junk, function(a, b)
		return a.rps < b.rps -- worst first, so a stopped batch has sold the right ones
	end)

	if not walkTo(stand:GetPivot().Position) then
		return whySell("couldn't reach the sell stand")
	end

	local hold = prompt.HoldDuration
	prompt.HoldDuration = 0

	local sold, failed = 0, nil
	for _, c in ipairs(junk) do
		if not selling then
			break -- toggled off mid-batch; stop between items, never mid-sale
		end
		local ok, reason = equipItem(c.id)
		if not ok then
			failed = reason
			break
		end
		-- The item vanishing from the inventory is the server confirming the sale.
		local gone = waitFor(function()
			fireproximityprompt(prompt)
			return pathValue("inventory", c.id) == nil
		end, STEP_TIMEOUT)
		if not gone then
			failed = "the stand refused it"
			break
		end
		sold += 1
	end

	pcall(function()
		prompt.HoldDuration = hold
	end)
	if keepFood then
		refood()
	end

	if sold == 0 then
		return whySell(("sold nothing -- %s"):format(failed or "batch stopped"))
	end
	lastSellWhy = ""
	say(("sold %d of %d under %s/s"):format(sold, #junk, sellFloorText))
	return true
end

-- plot -----------------------------------------------------------------------
-- ClaimEarnings per slot is the free path and does the same job. PickupAllCash is the
-- 29 R$ pickupAllCash gamepass: fire it without owning it and the server answers with
-- a Robux purchase prompt, once every pass. So it only goes out when you already own
-- it, where it's a single call instead of ten.
local function collectOnce()
	local passes = pathValue("gamepasses") or {}
	if passes.pickupAllCash then
		invoke(GameRF.PickupAllCash)
		return
	end
	for _, slot in ipairs(slotModels()) do
		invoke(GameRF.ClaimEarnings, slot.Name)
	end
end

local function upgradeSlotsOnce()
	for _, slot in ipairs(slotModels()) do
		invoke(GameRF.UpgradeBrainrot, slot.Name)
	end
end

-- The omitted second argument is the point: UpgradeSpeed(n, true) is the Robux route
-- the game's own UI falls back to when you can't afford the cash one, and the same
-- trick hides in Rebirth(true) (skipRebirth) and ClaimOfflineEarnings(true) (the x10).
-- Every call in this file passes cash-only args on purpose.
local function spendOnce()
	invoke(GameRF.UpgradeBase)
	invoke(GameRF.UpgradeSpeed, 1)
end

-- Open every lucky block sitting in the inventory. Ids are the inventory keys.
local function openBlocksOnce()
	local inv = pathValue("inventory")
	if type(inv) ~= "table" then
		return
	end
	for id, item in pairs(inv) do
		if type(item) == "table" and item.type == "luckyBlock" and not item.locked then
			invoke(GameRF.OpenLuckyBlock, id)
		end
	end
end

-- Quest slots, daily days and playtime tiers are all small dense integer ranges and
-- the server refuses anything not ready, so brute-forcing the range beats reading
-- three different progress tables to work out which one is claimable.
local function rewardsOnce()
	invoke(RewardRF.ClaimFreeReward)
	invoke(RewardRF.ClaimGroupReward)
	invoke(RewardRF.CheckPlayTimeExpired)
	invoke(GameRF.ClaimOfflineEarnings)
	for i = 1, 8 do
		invoke(RewardRF.ClaimQuest, i)
	end
	for i = 1, 7 do
		invoke(RewardRF.ClaimDailyReward, i)
	end
	for i = 1, 12 do
		invoke(RewardRF.ClaimPlayTimeReward, i)
	end
end

-- loops ----------------------------------------------------------------------
-- Two loops walk the character around -- the kick cycle and the placer -- and one
-- dragging you off mid-walk would break the other. So they take turns: whoever is
-- already moving keeps the body, the other skips this pass and tries again next tick.
-- ponytail: a plain boolean, not a queue. Skipping a 2s tick costs nothing.
local moving = false
local function withCharacter(body)
	return function()
		if moving then
			return
		end
		moving = true
		local ok, err = pcall(body)
		moving = false
		if not ok then
			warn("[PoopRots]", err)
		end
	end
end

-- One generation counter per loop: toggling off and on inside a single interval
-- otherwise leaves the sleeping thread alive next to the new one, firing at double rate.
local function every(state, interval, body)
	state.gen += 1
	local mine = state.gen
	task.spawn(function()
		while state.on and state.gen == mine do
			pcall(body)
			task.wait(interval)
		end
	end)
end

local kicker = { on = false, gen = 0 }
local placer = { on = false, gen = 0 }
local seller = { on = false, gen = 0 }
local frenzy = { on = false, gen = 0 }
local feeder = { on = false, gen = 0 }
local chewer = { on = false, gen = 0 }
local collector = { on = false, gen = 0 }
local upgrader = { on = false, gen = 0 }
local spender = { on = false, gen = 0 }
local opener = { on = false, gen = 0 }
local rewarder = { on = false, gen = 0 }
local rebirther = { on = false, gen = 0 }

local ALL =
	{ kicker, placer, seller, frenzy, feeder, chewer, collector, upgrader, spender, opener, rewarder, rebirther }

-- anti-afk -------------------------------------------------------------------
-- Roblox kicks after ~20 min without input, which a remote-only farm never produces.
-- A right-click through VirtualUser counts as input and does nothing in the game.
local running = true
local hasVU, vu = pcall(game.GetService, game, "VirtualUser")
local afk = player.Idled:Connect(function()
	if hasVU then
		pcall(function()
			vu:CaptureController()
			vu:ClickButton2(Vector2.new())
		end)
	end
end)
task.spawn(function()
	while running do
		task.wait(60)
		if hasVU then
			pcall(function()
				vu:CaptureController()
				vu:ClickButton2(Vector2.new())
			end)
		end
	end
end)

-- gui ------------------------------------------------------------------------
local WindUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()

local Window = WindUI:CreateWindow({
	Title = "Poop for Brainrots",
	Icon = "solar:waterdrops-bold",
	Folder = "PoopRots",
	Size = UDim2.fromOffset(460, 480),
	Topbar = { Height = 44, ButtonsType = "Mac" },
	OpenButton = { Title = "Poop for Brainrots", Enabled = true, Draggable = true },
})
Window:SetToggleKey(KEY_TOGGLE)

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local Farm = Tab:Section({ Title = "Farm", Icon = "solar:magic-stick-3-bold", Box = true, BoxBorder = true, Opened = true })
local Fat = Tab:Section({
	Title = "Fat",
	Desc = "Fat x alpha is the kick distance, and distance is the reward luck",
	Icon = "solar:double-alt-arrow-up-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})
local Plot = Tab:Section({ Title = "Plot", Icon = "solar:buildings-2-bold", Box = true, BoxBorder = true, Opened = true })
local Extra = Tab:Section({
	Title = "Extras",
	Desc = "Spends cash or wipes progress",
	Icon = "solar:settings-bold",
	Box = true,
	BoxBorder = true,
	Opened = false,
})

Farm:Toggle({
	Title = "Auto Poop",
	Desc = "BeginKick, submit the alpha, claim the best of the roll, Return",
	Value = false,
	Callback = function(state)
		kicker.on = state
		if state then
			every(kicker, KICK_EVERY, withCharacter(kickOnce))
		end
	end,
})

Farm:Input({
	Title = "Power",
	Desc = "Charge bar alpha, 0-1. Above 0.9 is a perfect; 1 is the longest kick.",
	Value = tostring(POWER),
	Placeholder = "1",
	Callback = function(v)
		power = tonumber(v) or POWER
	end,
})

Farm:Toggle({
	Title = "Grab Mutation Coins",
	Desc = "Claims the coins around the crater while the kick is already standing there",
	Value = false,
	Callback = function(state)
		grabCoins = state
	end,
})

Fat:Toggle({
	Title = "Auto x2 Circle",
	Desc = "Perfect-hits the frenzy circle. Needs food equipped to count.",
	Value = false,
	Callback = function(state)
		frenzy.on = state
		if state then
			every(frenzy, FRENZY_EVERY, frenzyOnce)
		end
	end,
})

-- One toggle, two loops: the buy/equip pass is slow and spends cash, the animation
-- stopper is fast and free. Splitting them into two switches would only ever be flipped
-- together.
Fat:Toggle({
	Title = "Auto Buy + Eat Food",
	Desc = "Buys what it can afford, equips the best you own, and hides the chewing animation",
	Value = false,
	Callback = function(state)
		feeder.on, chewer.on, keepFood = state, state, state
		if state then
			every(feeder, FOOD_EVERY, foodOnce)
			every(chewer, EAT_EVERY, stopEatAnimation)
		end
	end,
})

Fat:Button({
	Title = "Equip Best Poop",
	Desc = "Flat luck bonus on the reward roll, if you own one",
	Callback = equipBestPoop,
})

Plot:Toggle({
	Title = "Auto Place Best",
	Desc = "The paid Equip Best pad, done free: best brainrot into the best free slot, then swaps out the weakest one it beats",
	Value = false,
	Callback = function(state)
		placer.on = state
		if state then
			every(placer, PLACE_EVERY, withCharacter(placeOnce))
		end
	end,
})

Plot:Input({
	Title = "Sell under",
	Desc = "Income per second. Anything spare below this gets sold; blank or 0 sells nothing.",
	Value = "0",
	Placeholder = "100M",
	Callback = function(v)
		sellFloor = toNumber(v) or 0
		sellFloorText = sellFloor > 0 and v or "0"
	end,
})

Plot:Toggle({
	Title = "Auto Sell Spares",
	Desc = "Walks to the SellStand and sells backpack brainrots under the threshold, worst first. Locked items are never touched.",
	Value = false,
	Callback = function(state)
		seller.on, selling = state, state
		if state then
			every(seller, SELL_EVERY, withCharacter(sellOnce))
		end
	end,
})

-- One press dumps every input the placer reads. Each line answers one of the exits in
-- placeOnce, so "it does nothing" turns into a specific line instead of another guess.
Plot:Button({
	Title = "Diagnose Place",
	Desc = "Prints what Auto Place Best can see to the console (F9)",
	Callback = function()
		local cands, slots = spares(), slotModels()
		print("[PoopRots] --- place diagnosis ---")
		print(("  executor : fireproximityprompt=%s  data=%s"):format(tostring(fireproximityprompt ~= nil), tostring(PlayerData ~= nil)))
		print(
			("  holding  : id=%s type=%s hasBrainrotEquipped=%s"):format(
				tostring(player:GetAttribute("equippedItemId")),
				tostring(player:GetAttribute("equippedItemType")),
				tostring(player:GetAttribute("hasBrainrotEquipped"))
			)
		)
		local inv, bp, hb = pathValue("inventory") or {}, pathValue("backpack") or {}, pathValue("hotbar") or {}
		local function count(t)
			local n = 0
			for _ in pairs(t) do
				n += 1
			end
			return n
		end
		print(("  data     : inventory=%d backpack=%d hotbar=%d"):format(count(inv), count(bp), count(hb)))
		print(("  spares   : %d placeable brainrot(s)"):format(#cands))
		for i = 1, math.min(#cands, 5) do
			print(("    %d. %s  %.0f/s  id=%s"):format(i, label(cands[i].item), cands[i].rps, cands[i].id))
		end
		print(("  slots    : %d under Base.BrainrotSlots"):format(#slots))
		for _, slot in ipairs(slots) do
			local gui = slot:FindFirstChild("SurfaceGuiCollectEarnings")
			local labelText = gui and gui:FindFirstChild("TextLabelRevenue")
			local att = slot:FindFirstChild("AttachmentProximityPrompt")
			print(
				("    slot %-3s hasBrainrot=%-5s pending=%-12s parsed=%-12s prompts=%s"):format(
					slot.Name,
					tostring(slot:GetAttribute("hasBrainrot")),
					labelText and labelText.Text or "<none>",
					tostring(slotPending(slot)),
					att and #att:GetChildren() or 0
				)
			)
		end
		say("place diagnosis printed to the console (F9)")
	end,
})

Plot:Toggle({
	Title = "Auto Collect",
	Desc = "ClaimEarnings on every slot, on a " .. COLLECT_EVERY .. "s beat. Never buys anything.",
	Value = false,
	Callback = function(state)
		collector.on = state
		if state then
			every(collector, COLLECT_EVERY, collectOnce)
		end
	end,
})

Plot:Toggle({
	Title = "Auto Upgrade Brainrots",
	Desc = "UpgradeBrainrot over every slot; the server refuses when you are broke",
	Value = false,
	Callback = function(state)
		upgrader.on = state
		if state then
			every(upgrader, UPGRADE_EVERY, upgradeSlotsOnce)
		end
	end,
})

-- ponytail: no Equip Best row. The pad looks free but EquipBest is the `equipBest` dev
-- product, so the server bills Robux on every press -- a button that charges money is
-- not worth the convenience. Walk over the pad yourself if you want it.

Extra:Toggle({
	Title = "Auto Upgrade Base + Speed",
	Desc = "Unlocks slots and walk speed. Drains cash.",
	Value = false,
	Callback = function(state)
		spender.on = state
		if state then
			every(spender, SPEND_EVERY, spendOnce)
		end
	end,
})

Extra:Toggle({
	Title = "Auto Open Lucky Blocks",
	Desc = "Opens every unlocked lucky block in your inventory",
	Value = false,
	Callback = function(state)
		opener.on = state
		if state then
			every(opener, SPEND_EVERY, openBlocksOnce)
		end
	end,
})

Extra:Toggle({
	Title = "Auto Claim Rewards",
	Desc = "Quests, dailies, playtime, free, group and offline earnings",
	Value = false,
	Callback = function(state)
		rewarder.on = state
		if state then
			every(rewarder, REWARDS_EVERY, rewardsOnce)
		end
	end,
})

Extra:Toggle({
	Title = "Auto Rebirth",
	Desc = "Wipes the plot the moment the fat requirement is met. Leave off while farming.",
	Value = false,
	Callback = function(state)
		rebirther.on = state
		if state then
			every(rebirther, REBIRTH_EVERY, function()
				invoke(GameRF.Rebirth)
			end)
		end
	end,
})

local line = Farm:Paragraph({ Title = "Status", Desc = "idle" })
say = function(msg)
	line:SetDesc(msg)
end

-- minimize -------------------------------------------------------------------
-- WindUI's own Minimize hides the whole window and leaves nothing but the floating
-- open button, which it only draws on touch devices -- on a PC the window would be
-- gone with nothing left to click. Swapped for a shade: the body collapses to a bare
-- title bar and the same button rolls it back down. Loops keep farming either way.
--
-- The shade is sized to its CONTENT, not to the window: keeping the full width just
-- leaves a 460-wide black slab with a title in the corner of it.
--
-- Main is anchored at its CENTRE, so a resize on its own moves all four edges: the
-- shade would land mid-screen, and rolling it back down near the top of the screen
-- pushed the title bar off it with nothing left to click. Every resize is paired with
-- a position nudge of half the delta, pinning the TOP-LEFT corner instead, so the bar
-- collapses where it stands and grows back down and right from the same spot.
local SHADE_TRIM = 8 -- Topbar's own PaddingRight -- the breathing room after the title
local SHADE_MIN = 160 -- never shade narrower than the traffic lights + this button, or
-- there is nothing left to click to get the window back
local SHADE_PAD = 10 -- topbar height + window chrome; nudge if the shade clips

Window:DisableTopbarButtons({ "Minimize" }) -- before ours, it reuses the same slot

-- Measured, not guessed, so the bar fits whatever the title happens to be. WindUI lays
-- the topbar out as three frames: Left (icon + title, AutomaticSize "X"), Right (the
-- traffic lights and this button), and Center. With ButtonsType "Mac" it positions Left
-- after Right, so the right-hand edge of the widest child IS the end of the content.
-- AbsoluteSize is post-UIScale while Size offsets are pre-scale, hence the divide.
local function shadeSize(fullWidth)
	local topbar = Window.UIElements.Main.Main.Topbar
	local scale = tonumber(WindUI.UIScale) or 1
	if scale <= 0 then
		scale = 1
	end

	local edge = 0
	for _, child in ipairs(topbar:GetChildren()) do
		-- Center is the tab-strip slot: unused and invisible here, but when it IS used
		-- it's sized to fill the window, which would defeat the whole measurement.
		if child:IsA("GuiObject") and child.Visible and child.Name ~= "Center" then
			edge = math.max(edge, child.AbsolutePosition.X + child.AbsoluteSize.X - topbar.AbsolutePosition.X)
		end
	end

	local w = math.clamp(edge / scale + SHADE_TRIM, SHADE_MIN, fullWidth)
	return UDim2.fromOffset(w, Window.Topbar.Height + SHADE_PAD)
end

local SHADE_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local shaded, fullSize, shadeTo = false, nil, nil
Window:CreateTopbarButton("Shade", "minus", function()
	local main = Window.UIElements.Main
	shaded = not shaded

	-- Both read live on the way down: a window the user resized comes back its own size,
	-- and the bar is re-measured each time in case the title, the buttons or the UIScale
	-- have changed since. Kept in upvalues so the way back up doesn't have to re-derive
	-- either end -- see the note on mid-tween reads below.
	if shaded then
		fullSize = main.Size
		shadeTo = shadeSize(fullSize.X.Offset)
	end
	-- Topbar is the one child that stays. Going by name rather than by index keeps
	-- this working if WindUI reshuffles the body frames.
	for _, child in ipairs(main.Main:GetChildren()) do
		if child:IsA("GuiObject") and child.Name ~= "Topbar" then
			child.Visible = not shaded
		end
	end

	-- Both ends are known, so the delta is computed rather than read back off a frame
	-- that is still mid-tween from the last click.
	local from, to = shaded and fullSize or shadeTo, shaded and shadeTo or fullSize
	local p = main.Position
	Window:SetSize(to)
	-- Matched to SetSize's own tween, or the corner visibly slides while the size catches up.
	TweenService:Create(main, SHADE_TWEEN, {
		Position = UDim2.new(
			p.X.Scale,
			p.X.Offset + (to.X.Offset - from.X.Offset) / 2,
			p.Y.Scale,
			p.Y.Offset + (to.Y.Offset - from.Y.Offset) / 2
		),
	}):Play()
end, 998, nil, Color3.fromHex("#F4C948")) -- same yellow the real Minimize used

-- close ----------------------------------------------------------------------
local function stopAll()
	running, selling = false, false
	for _, state in ipairs(ALL) do
		state.on = false
	end
	afk:Disconnect()
end

Window:OnDestroy(function()
	stopAll()
	getgenv().poopRotsStop = nil
end)

getgenv().poopRotsStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().poopRotsStop = nil
end
