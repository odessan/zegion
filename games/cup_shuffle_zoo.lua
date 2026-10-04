--[[ Cup Shuffle Zoo -- roll, buy, place, hatch, upgrade, feed the Chomper (79226825467411)

     BUY     : the dealer's cup game with no cup game. Rolls the dealer's egg (Select, free, ~0.3s each)
               until it is one you ticked and you can pay for it (no budget cap: it buys until the cash is
               gone), then Play -> StartShuffle -> PickCup on the right cup and the egg lands in your hands.
               About 0.3s per egg and nothing walks. The right cup is worked out from the shuffle the
               server sends (the six shuffles are fixed swaps, probed 8 of 8). Eggs of tier 1 and 2 win on
               any cup. The dealer's pick stays put between rounds, so once it rolls what you want it just
               keeps buying it. While Place is on it steps out of the dealer now and then (the server
               refuses PlaceEgg inside the cup game) so free slots get filled.
               Needs getconnections: it mutes the game's own cup controller, which would otherwise
               play the animation and restart the game itself after every reveal.
     INFESTED: "Infested eggs only" makes BUY wait for the dealer's offer to carry the Infested flag (player
               attr OfferInfested, 4% of rolls, probed 10 of 250). Those eggs are food for the Chomper and are
               never placed. Buying pauses at INFESTED_KEEP held, since the dealer repeats the same offer.
     FEED    : the Chomper event. FeedChomper takes no arguments, needs an Infested egg HELD, and is accepted
               from across the map (probed at 221 studs); the server paces it at ~2.4s. 10 feeds fill the bar
               and pay out a tree egg (7 in 163s). Mutes the feed / payout cutscene.
     CLAIM   : own all three trees (cut / ruined / haunted, from hatching tree eggs, 6 min) and the Chomper
               animal (Spirit) can be claimed. Fires ClaimChomperEvent when the event status says Have >= Need.
     PLACE   : puts held eggs on free ground of your plot, best tier first.
     HATCH   : OpenEgg the moment an egg's timer is up (earlier is refused). Mutes the hatch cutscene.
     EQUIP   : the game's own Equip Best button (EquipBestAnimals). Fired when your animal count or slot
               count changes, and every EQUIP_EVERY as a backstop. The log says how much income it gained.
     SELL    : stored animals of the rarities you tick (SellAnimal, one per call), only while the plot is
               full and never one rarer than your weakest placed animal. Nothing is ticked to start with.
     UPGRADE : cheapest affordable of: next Tourist (zoo) level, a better cup, a better dealer. A bought
               cup or dealer is equipped straight away.

     Probed and dead (do not re-probe):
       OpenEgg before HatchAt         refused silently at 5s, 3s and 1s left
       Select back to back            dropped; 0.2s apart all answered
       cup tracking via LOCATIONS     the cups never move on the client; the animation is cosmetic
       FeedChomper without the egg held   refused ("Hold an Infested egg, then press E to feed it")
     Not wired (Robux): SkipEgg (ShopConfig.SkipProducts), Claim All, offline x10, pass-only cups/dealers.
     Not wired (not asked): Base upgrade (+1 animal slot), the free claims (daily, playtime, quests, index).

     RightControl opens / closes the panel. Stop: getgenv().cupZooStop() ]]

-- config ---------------------------------------------------------------------
local ROLL_GAP = 0.3 -- between Selects. 0.2 was answered, back to back is dropped. Raise if rolls time out
local REPLY_WAIT = 1.5 -- a Select / StartShuffle / PickCup reply must land inside this
local PLAY_WAIT = 1.5 -- Play must flip Game.CanSkip inside this
local YIELD_EVERY = 4 -- buying has no cap, so step out of the dealer this often and let Place fill free slots (the server refuses PlaceEgg while you are in the cup game)
local YIELD_MAX = 3 -- ...and stay out at most this long
local EGG_ARRIVE = 1 -- after a win, wait up to this long for the egg Tool to show up in your hands
local INFESTED_KEEP = 25 -- Infested-only buying pauses at this many held: the dealer keeps the same offer, so it would otherwise buy ~3 a second while the Chomper eats one per EatTime
local STALE_ROLLS = 60 -- this many rejects in a row and the strip says why nothing is being bought
local PLACE_GAP = 0.3 -- between PlaceEgg calls
local PLACE_CONFIRM = 1.5 -- the egg must show up in Plot.Eggs inside this
local SPOT_STEP = 6 -- studs between candidate egg spots
local SPOT_CLEAR = 6.5 -- the server wants 5 between eggs; a little extra
local SPOT_INSET = 7 -- keep spots this far from the plot floor's edge
local HATCH_GAP = 0.15 -- between OpenEgg calls
local HATCH_RETRY = 1.5 -- an egg that was opened but is still there is tried again after this
local SELL_GAP = 0.3 -- between SellAnimal calls
local SELL_CONFIRM = 1.5 -- the sold animal must leave your inventory inside this
local SELL_EVERY = 2 -- how often to look for something to sell
local EQUIP_GAP = 2 -- at least this long between Equip Best presses
local EQUIP_EVERY = 30 -- press anyway this often, in case a change was missed
local UPGRADE_EVERY = 1.5
local UPGRADE_BACKOFF = 10 -- a purchase the server did not take is not retried for this long
local MIN_TIER_DEFAULT = 3 -- eggs of this tier and up start ticked

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().cupZooStop then
	getgenv().cupZooStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[cupzoo]", ...)
end

-- The panel strip is drained from a Heartbeat, which the engine calls with our own identity.
-- A loop thread that writes to the window directly throws "lacking capability Plugin" after
-- its first task.wait.
-- Two strip slots, so the buy loop's reason is not overwritten by Place's chatter: "buy" and "now".
local pending, lastSaid = {}, nil
local function say(msg, quiet, slot)
	pending[slot or "now"] = msg
	if not quiet and msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- game -----------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
local ok, EggsConfig, UpgradesConfig, DealersConfig, CupsConfig, Mutations, AnimalsConfig, InfestedBug = pcall(function()
	return require(ReplicatedStorage.Configs.EggsConfig),
		require(ReplicatedStorage.Configs.UpgradesConfig),
		require(ReplicatedStorage.Configs.DealersConfig),
		require(ReplicatedStorage.Assets.CupSkins.Cups),
		require(ReplicatedStorage.Shared.WeightSystem.Mutations),
		require(ReplicatedStorage.Configs.AnimalsConfig),
		require(ReplicatedStorage.Shared.Util.InfestedBug) -- the game's own "is this Tool Infested" test
end)
if not Remotes or not ok then
	warn("[cupzoo] the game's modules did not load:", EggsConfig)
	return
end
local GHS = Remotes:WaitForChild("GameHandShake")
local PlaceEgg, OpenEgg = Remotes:WaitForChild("PlaceEgg"), Remotes:WaitForChild("OpenEgg")
local Game = player:WaitForChild("Game")
local money = player:WaitForChild("leaderstats"):WaitForChild("Money")

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
assert(fmt(25000) == "25K" and fmt(1500) == "1.5K" and fmt(260e9) == "260B" and fmt(100) == "100", "fmt")

-- The six shuffles are fixed swaps of the three cups; p[position] = where the egg goes. Probed:
-- solved from 24 rounds (one consistent assignment out of 6^6) and then 8 of 8 predicted wins.
-- The egg starts under cup 2.
local SHUFFLE = {
	Shuffle1 = { 1, 3, 2 },
	Shuffle2 = { 1, 3, 2 },
	Shuffle3 = { 2, 1, 3 },
	Shuffle4 = { 2, 1, 3 },
	Shuffle5 = { 3, 2, 1 },
	Shuffle6 = { 3, 2, 1 },
}
local function correctCup(seq)
	local pos = 2
	for _, name in ipairs(seq) do
		local p = SHUFFLE[name]
		if not p then
			return nil -- a shuffle added by an update: caller guesses
		end
		pos = p[pos]
	end
	return pos
end
assert(correctCup({ "Shuffle3", "Shuffle4", "Shuffle2", "Shuffle5" }) == 1, "probe round: predicted 1, won")
assert(correctCup({ "Shuffle6", "Shuffle5", "Shuffle6", "Shuffle6", "Shuffle5" }) == 2, "probe round: predicted 2, won")
assert(correctCup({ "Shuffle9" }) == nil, "unknown shuffle")

local function myBase()
	local root = workspace:FindFirstChild("Base")
	for _, b in ipairs(root and root:GetChildren() or {}) do
		if b:GetAttribute("Owner") == player.Name then
			return b
		end
	end
	return nil
end

-- Every egg Tool in the Backpack or in hand; the Tool's name is the egg id. An Infested egg is food for
-- the Chomper, not for the plot, so Place and its rank never see it (infestedTools has them).
local function eggTools(infested)
	local out = {}
	for _, holder in ipairs({ player.Backpack, player.Character }) do
		for _, t in ipairs(holder and holder:GetChildren() or {}) do
			if t:IsA("Tool") and EggsConfig.Get(t.Name) and (InfestedBug.OnTool(t) == true) == (infested == true) then
				out[#out + 1] = t
			end
		end
	end
	return out
end
local function infestedTools()
	return eggTools(true)
end

local mutIndex = {}
for i, name in ipairs(Mutations.ORDER) do
	mutIndex[name] = i
end

-- mute ------------------------------------------------------------------------
-- A game controller listening on a remote can be switched off with the executor's getconnections.
-- Mute BEFORE connecting our own handler, or getconnections hands back ours too. Restore on stop.
local muted = {}
local function mute(remote)
	if muted[remote] then
		return true
	end
	if not getconnections then
		return false
	end
	local list = {}
	for _, c in ipairs(getconnections(remote.OnClientEvent)) do
		if pcall(function()
			c:Disable()
		end) then
			list[#list + 1] = c
		end
	end
	muted[remote] = list
	return true
end
local function unmute(remote)
	for _, c in ipairs(muted[remote] or {}) do
		pcall(function()
			c:Enable()
		end)
	end
	muted[remote] = nil
end

-- state read by the loops -----------------------------------------------------
local eggOn, mutOn = {}, {}
local infestedOnly = false -- Auto Buy rolls until the dealer's offer is Infested (the Chomper's food)
local stats = { rolls = 0, bought = 0, lost = 0, hatched = 0, upgrades = 0, sold = 0, fed = 0, trees = 0 }

local function heldCount()
	return #eggTools() + #infestedTools()
end

-- buy -------------------------------------------------------------------------
local buyCon
local genBuy = 0
local inGame = false
local placeOn = false -- the place loop is running (set by setPlace)
local buyOn = false -- the buy loop is running (set by setBuy; Place waits for it to leave the dealer)
local sel = { n = 0, animal = nil, price = 0, mut = "Normal" }
local shuf = { n = 0, seq = nil }
local rev = { n = 0, won = false }

local function waitN(box, n0, timeout)
	local dl = os.clock() + timeout
	while box.n == n0 and os.clock() < dl do
		task.wait()
	end
	return box.n > n0
end

local function seedSelection()
	sel.animal = Game.Selected.Value ~= "" and Game.Selected.Value or nil
	sel.price = Game.Price.Value
	sel.mut = Game.Mutation.Value ~= "" and Game.Mutation.Value or "Normal"
end

local function offerInfested()
	return player:GetAttribute("OfferInfested") == true
end

-- No budget guard: buy every ticked egg until the cash is gone. Only an egg we cannot pay for is skipped,
-- because StartShuffle on it is refused and costs a round trip.
local function wanted()
	local cfg = sel.animal and EggsConfig.Get(sel.animal)
	if not cfg or not eggOn[cfg.id] or not mutOn[Mutations.Name(sel.mut)] then
		return false
	end
	if infestedOnly and not offerInfested() then
		return false
	end
	return cfg.price <= money.Value
end

local function ensurePlay()
	if Game.CanSkip.Value then
		return true
	end
	GHS:FireServer("Play")
	local dl = os.clock() + PLAY_WAIT
	while not Game.CanSkip.Value and os.clock() < dl do
		task.wait()
	end
	inGame = Game.CanSkip.Value
	return inGame
end

local function leaveDealer()
	if Game.CanSkip.Value then
		pcall(function()
			GHS:FireServer("ExitGame")
		end)
	end
	inGame = false
end

-- a free egg slot on the plot that Place could fill right now
local function plotHasRoom()
	local base = myBase()
	local eggs = base and base:FindFirstChild("Eggs")
	return eggs ~= nil and #eggs:GetChildren() < (base:GetAttribute("EggCapacity") or 10)
end

local function buyLoop(mine)
	local rejects = 0
	local lastYield = os.clock()
	while genBuy == mine do
		local held = heldCount()
		-- PlaceEgg is refused while we sit in the dealer, and buying has no cap, so free slots would stay
		-- empty for as long as the cash lasts. Step out now and then and let Place fill them.
		if placeOn and #eggTools() > 0 and os.clock() - lastYield > YIELD_EVERY and plotHasRoom() then
			leaveDealer()
			local dl = os.clock() + YIELD_MAX
			while genBuy == mine and plotHasRoom() and #eggTools() > 0 and os.clock() < dl do
				task.wait(0.2)
			end
			lastYield = os.clock()
		end
		if infestedOnly and #infestedTools() >= INFESTED_KEEP then
			leaveDealer() -- lets PlaceEgg through while the Chomper eats its way down
			say(("%d Infested eggs held, buying resumes when Feed has eaten some"):format(#infestedTools()), true, "buy")
			task.wait(0.5)
		elseif not ensurePlay() then
			say("Play did not open the dealer", false, "buy")
			task.wait(1)
		elseif not wanted() then
			-- reroll: free, one Select per ROLL_GAP
			if infestedOnly and offerInfested() then
				warn("[cupzoo] infested offer skipped:", sel.animal, "mut", sel.mut, "price", sel.price, "ticked egg", eggOn[sel.animal] == true, "ticked mut", mutOn[Mutations.Name(sel.mut)] == true, "cash", money.Value)
			end
			local n0 = sel.n
			GHS:FireServer("Select", { SpeedMultiplier = 2, StartTime = tick() })
			stats.rolls += 1
			rejects += 1
			waitN(sel, n0, REPLY_WAIT)
			if rejects >= STALE_ROLLS then
				say(("%d rolls, none ticked%s and affordable (cash %s) -- tick more eggs"):format(rejects, infestedOnly and " + Infested" or "", fmt(money.Value)), false, "buy")
				rejects = 0
			else
				say(("rolling: %s %s"):format(tostring(sel.animal), sel.price and fmt(sel.price) or "?"), true, "buy") -- 3 a second: strip only
			end
			task.wait(ROLL_GAP)
		else
			rejects = 0
			local s0, r0, h0 = shuf.n, rev.n, held
			GHS:FireServer("StartShuffle")
			if not waitN(shuf, s0, REPLY_WAIT) then
				-- the server did not start it (cash short, state out of step): roll again
				sel.animal = nil
				say("StartShuffle was not answered, rolling again", false, "buy")
				task.wait(ROLL_GAP)
			else
				GHS:FireServer("PickCup", correctCup(shuf.seq) or math.random(3))
				if waitN(rev, r0, REPLY_WAIT) then
					if rev.won then
						-- the Tool lands a beat after the reveal; count it before the next buy or the hold cap overshoots
						local dl = os.clock() + EGG_ARRIVE
						while heldCount() <= h0 and os.clock() < dl do
							task.wait()
						end
						stats.bought += 1
						say(("bought %s for %s (%d total)"):format(tostring(sel.animal), fmt(sel.price), stats.bought), stats.bought % 10 ~= 1, "buy")
					else
						stats.lost += 1
						warn("[cupzoo] lost a round -- the shuffle table is out of date?", sel.animal, shuf.seq)
					end
				end
			end
		end
	end
end

local function setBuy(on)
	genBuy += 1
	local mine = genBuy
	buyOn = on
	if buyCon then
		buyCon:Disconnect()
		buyCon = nil
	end
	if on then
		if not mute(GHS) then
			say("Auto Buy needs getconnections (this executor has none)", false, "buy")
			return
		end
		buyCon = GHS.OnClientEvent:Connect(function(kind, d)
			if type(d) ~= "table" then
				return
			end
			if kind == "SelectResult" then
				sel.animal, sel.price, sel.mut = d.Animal, d.Price, d.Mutation or "Normal"
				sel.n += 1
			elseif kind == "ShuffleSequence" then
				shuf.seq = d.Sequence
				shuf.n += 1
			elseif kind == "RevealResult" then
				rev.won = d.Won == true
				rev.n += 1
			end
		end)
		seedSelection()
		local ticks = 0
		for _ in pairs(eggOn) do
			ticks += 1
		end
		log(("buy on: %d eggs held, dealer shows %s at %s, cash %s, infested only %s, %d egg types ticked"):format(
			heldCount(), tostring(sel.animal), fmt(sel.price or 0), fmt(money.Value), tostring(infestedOnly), ticks))
		task.spawn(function()
			local good, err = pcall(buyLoop, mine)
			if not good then
				warn("[cupzoo] buy loop died:", err)
			end
		end)
	else
		leaveDealer()
		unmute(GHS)
	end
end

-- place -----------------------------------------------------------------------
local genPlace = 0
local badSpots = {} -- "x,z" rounded: a spot the server did not take this session

local function spotKey(v)
	return ("%d,%d"):format(math.floor(v.X + 0.5), math.floor(v.Z + 0.5))
end

local function freeSpot(base)
	local floor = base:FindFirstChild("Plot") and base.Plot:FindFirstChild("Floor")
	local eggs = base:FindFirstChild("Eggs")
	if not floor or not eggs then
		return nil
	end
	local y = floor.Position.Y + floor.Size.Y / 2
	local hx, hz = floor.Size.X / 2 - SPOT_INSET, floor.Size.Z / 2 - SPOT_INSET
	local placed = {}
	for _, e in ipairs(eggs:GetChildren()) do
		placed[#placed + 1] = e.Position
	end
	local cands = {}
	for lx = -hx, hx, SPOT_STEP do
		for lz = -hz, hz, SPOT_STEP do
			cands[#cands + 1] = Vector3.new(lx, 0, lz)
		end
	end
	table.sort(cands, function(a, b)
		return a.Magnitude < b.Magnitude
	end)
	for _, c in ipairs(cands) do
		local w = floor.CFrame:PointToWorldSpace(c)
		w = Vector3.new(w.X, y, w.Z)
		local clear = not badSpots[spotKey(w)]
		for _, p in ipairs(placed) do
			if clear and Vector3.new(p.X - w.X, 0, p.Z - w.Z).Magnitude < SPOT_CLEAR then
				clear = false
			end
		end
		if clear then
			return w
		end
	end
	return nil
end

-- best first: higher tier, then the better mutation (a Gold egg hatches a Gold animal)
local function eggRank(tool)
	local cfg = EggsConfig.Get(tool.Name)
	local m = tool:FindFirstChild("Mutation")
	return cfg.tier * 10 + (m and mutIndex[Mutations.Name(m.Value)] or 1)
end

-- The server's own reason for a refusal is only ever worded on the Notification remote.
local lastNote, lastNoteAt = nil, -99
local noteCon = Remotes:WaitForChild("Notification").OnClientEvent:Connect(function(msg)
	lastNote, lastNoteAt = tostring(msg), os.clock()
end)
local function placeOne(eggs, tool, spot)
	local before = {}
	for _, e in ipairs(eggs:GetChildren()) do
		before[e] = true
	end
	local uid = tool:FindFirstChild("UID")
	PlaceEgg:FireServer(tool.Name, spot, uid and uid.Value or nil)
	local dl = os.clock() + PLACE_CONFIRM
	while os.clock() < dl do
		for _, e in ipairs(eggs:GetChildren()) do
			if not before[e] then
				return true
			end
		end
		task.wait()
	end
	return false
end

local failedTool = setmetatable({}, { __mode = "k" }) -- Tool -> refusals

-- one pass: returns whether an egg went down
local function placePass()
	local base = myBase()
	local eggs = base and base:FindFirstChild("Eggs")
	if not eggs then
		return false
	end
	local tools = eggTools()
	if #tools == 0 then
		return false
	end
	local cap = base:GetAttribute("EggCapacity") or 10
	if #eggs:GetChildren() >= cap then
		say(("plot full (%d/%d), %d held"):format(#eggs:GetChildren(), cap, #tools), true)
		return false
	end
	-- the server refuses PlaceEgg while you are in the dealer's game (CanSkip on)
	if Game.CanSkip.Value then
		if buyOn then
			say("waiting for the dealer to be left", true)
			return false
		end
		leaveDealer()
		task.wait(0.3)
	end
	table.sort(tools, function(a, b)
		return eggRank(a) > eggRank(b)
	end)
	local spot = freeSpot(base)
	if not spot then
		say("no free ground on the plot", true)
		return false
	end
	local failed = 0
	for _, tool in ipairs(tools) do
		if (failedTool[tool] or 0) < 2 then
			if placeOne(eggs, tool, spot) then
				say(("placed %s (%d/%d)"):format(tool.Name, #eggs:GetChildren(), cap), true)
				task.wait(PLACE_GAP)
				return true
			end
			failedTool[tool] = (failedTool[tool] or 0) + 1
			failed += 1
			warn("[cupzoo] PlaceEgg not taken:", tool.Name, spot, "inGame", Game.CanSkip.Value, "last notice:", lastNote, os.clock() - lastNoteAt < 3 and "(fresh)" or "(old)")
			if failed >= 2 then
				break
			end
		end
	end
	if failed > 0 then
		badSpots[spotKey(spot)] = true -- two different eggs both bounced off it
	end
	return false
end

local function placeLoop(mine)
	while genPlace == mine do
		local good, did = pcall(placePass)
		if not good then
			warn("[cupzoo] place pass failed:", did)
			task.wait(1)
		elseif not did then
			task.wait(0.4)
		end
	end
end

local function setPlace(on)
	genPlace += 1
	placeOn = on
	if on then
		task.spawn(placeLoop, genPlace)
	end
end

-- hatch -----------------------------------------------------------------------
local genHatch = 0
local opened = setmetatable({}, { __mode = "k" }) -- marker -> when we last asked

local function hatchPass(mine)
	local base = myBase()
	local eggs = base and base:FindFirstChild("Eggs")
	local did = false
	for _, marker in ipairs(eggs and eggs:GetChildren() or {}) do
		if genHatch ~= mine then
			break
		end
		local at = marker:GetAttribute("HatchAt")
		if at and os.time() >= at and os.clock() - (opened[marker] or -9) > HATCH_RETRY then
			opened[marker] = os.clock()
			OpenEgg:FireServer(marker.Name)
			stats.hatched += 1
			did = true
			task.wait(HATCH_GAP)
		end
	end
	if not did then
		task.wait(0.25)
	end
end

local function hatchLoop(mine)
	while genHatch == mine do
		local good, err = pcall(hatchPass, mine)
		if not good then
			warn("[cupzoo] hatch pass failed:", err)
			task.wait(1)
		end
	end
end

local function setHatch(on)
	genHatch += 1
	if on then
		-- the hatch cutscene is client-only; the server removes the egg and adds the animal on its own
		mute(Remotes:WaitForChild("EggHatched"))
		task.spawn(hatchLoop, genHatch)
	else
		unmute(Remotes:WaitForChild("EggHatched"))
	end
end

-- equip -----------------------------------------------------------------------
local genEquip = 0
local EquipBest = Remotes:WaitForChild("EquipBestAnimals")

-- stored animals, placed animals and slot count: any change means Equip Best may have work to do
local function animalSig()
	local inv = player:FindFirstChild("AnimalInventory")
	local base = myBase()
	local animals = base and base:FindFirstChild("Animals")
	return ("%d|%d|%s"):format(inv and #inv:GetChildren() or 0, animals and #animals:GetChildren() or 0, tostring(base and base:GetAttribute("Capacity")))
end

local function placedRate()
	local base = myBase()
	local animals = base and base:FindFirstChild("Animals")
	local sum = 0
	for _, a in ipairs(animals and animals:GetChildren() or {}) do
		sum += (a:GetAttribute("CashPerSec") or 0) * (a:GetAttribute("Mult") or 1)
	end
	return sum
end

local function equipPass(state)
	local sig, now = animalSig(), os.clock()
	if (sig ~= state.sig and now - state.at >= EQUIP_GAP) or now - state.at >= EQUIP_EVERY then
		local before = placedRate()
		state.sig, state.at = sig, now
		EquipBest:FireServer()
		task.wait(0.8)
		local after = placedRate()
		if after > before + 1e-6 then
			say(("equip best: %s/s -> %s/s"):format(fmt(before), fmt(after)))
		end
	end
	task.wait(0.5)
end

local function equipLoop(mine)
	local state = { sig = nil, at = -99 }
	while genEquip == mine do
		local good, err = pcall(equipPass, state)
		if not good then
			warn("[cupzoo] equip pass failed:", err)
			task.wait(1)
		end
	end
end

local function setEquip(on)
	genEquip += 1
	if on then
		task.spawn(equipLoop, genEquip)
	end
end

-- sell ------------------------------------------------------------------------
local genSell = 0
local SellAnimal = Remotes:WaitForChild("SellAnimal")
local RARITIES = DealersConfig.RarityOrder -- Common .. Exclusive, the game's own order
local rarityIdx = {}
for i, r in ipairs(RARITIES) do
	rarityIdx[r] = i
end
local sellOn = {}
local failedSell = setmetatable({}, { __mode = "k" }) -- stored animal -> refused once

local function rarityIndexOf(inst)
	local cfg = AnimalsConfig.Get(inst:GetAttribute("Animal"))
	return cfg and rarityIdx[cfg.rarity]
end

-- Sells one stored animal of a ticked rarity per call. ponytail: guards by rarity only, not by income.
-- It sells only while the plot is full (a free slot means Equip Best will place it) and never an animal of
-- a higher rarity than the weakest placed one (it could take that slot). A rarer-but-weaker animal of the same
-- rarity can still go; add a rate comparison if that ever costs you.
local function sellPass()
	local inv = player:FindFirstChild("AnimalInventory")
	local base = myBase()
	local animals = base and base:FindFirstChild("Animals")
	if not inv or not animals then
		return false
	end
	if #animals:GetChildren() < (base:GetAttribute("Capacity") or 0) then
		return false
	end
	local worst = math.huge
	for _, a in ipairs(animals:GetChildren()) do
		worst = math.min(worst, rarityIndexOf(a) or math.huge)
	end
	for _, s in ipairs(inv:GetChildren()) do
		local r = rarityIndexOf(s)
		if r and sellOn[RARITIES[r]] and r <= worst and not failedSell[s] then
			local cfg = AnimalsConfig.Get(s:GetAttribute("Animal"))
			local value = EggsConfig.SellValue(s:GetAttribute("Animal"), s:GetAttribute("Weight") or 1, s:GetAttribute("Mutation"))
			SellAnimal:FireServer("SellAnimal", s.Name)
			local dl = os.clock() + SELL_CONFIRM
			while s.Parent and os.clock() < dl do
				task.wait()
			end
			if s.Parent then
				failedSell[s] = true
				warn("[cupzoo] SellAnimal not taken:", cfg.name, "last notice:", lastNote)
			else
				stats.sold += 1
				say(("sold %s %s for %s"):format(cfg.rarity, cfg.name, fmt(value)))
			end
			task.wait(SELL_GAP)
			return true
		end
	end
	return false
end

local function sellLoop(mine)
	while genSell == mine do
		local good, did = pcall(sellPass)
		if not good then
			warn("[cupzoo] sell pass failed:", did)
			task.wait(1)
		elseif not did then
			task.wait(SELL_EVERY)
		end
	end
end

local function setSell(on)
	genSell += 1
	if on then
		task.spawn(sellLoop, genSell)
	end
end

-- upgrade ---------------------------------------------------------------------
local genUpgrade = 0
local cool = {} -- kind -> os.clock() before which it is not retried

local function bestSkin(cfg, owned, equipped)
	local floor = cfg.Skins[equipped] and cfg.Skins[equipped].Luck or 0
	local pick
	for name, s in pairs(cfg.Skins) do
		local o = owned:FindFirstChild(name)
		if not (o and o.Value) and not s.PassRequired and (s.Price or 0) > 0 and s.Luck > floor then
			if s.Price <= money.Value and (not pick or s.Luck > cfg.Skins[pick].Luck) then
				pick = name
			end
		end
	end
	return pick
end

local function buySkin(kind, cfg, owned, buyRemote, equipRemote, equippedValue)
	local name = bestSkin(cfg, owned, equippedValue.Value)
	if not name then
		return false
	end
	local price = cfg.Skins[name].Price
	buyRemote:FireServer(name)
	local dl = os.clock() + 2
	local got = false
	while os.clock() < dl and not got do
		local o = owned:FindFirstChild(name)
		got = o and o.Value
		task.wait()
	end
	if not got then
		cool[kind] = os.clock() + UPGRADE_BACKOFF
		return false
	end
	equipRemote:FireServer(name)
	stats.upgrades += 1
	say(("bought %s %s for %s"):format(kind, name, fmt(price)))
	return true
end

local function upgradePass()
	local up = player:FindFirstChild("Upgrades")
	-- candidates: {kind, cost, buy}; cheapest affordable goes first
	local cands = {}
	if up and up:FindFirstChild("Tourist") and (cool.Tourist or 0) < os.clock() then
		local lvl = up.Tourist.Value
		local cost = UpgradesConfig.Tourist[lvl + 1]
		if cost and cost <= money.Value then
			cands[#cands + 1] = { cost = cost, buy = function()
				Remotes.Upgrade:FireServer("Tourist")
				local dl = os.clock() + 2
				while os.clock() < dl and up.Tourist.Value == lvl do
					task.wait()
				end
				if up.Tourist.Value == lvl then
					cool.Tourist = os.clock() + UPGRADE_BACKOFF
					return false
				end
				stats.upgrades += 1
				say(("Tourist level %d for %s"):format(up.Tourist.Value, fmt(cost)))
				return true
			end }
		end
	end
	if (cool.Cup or 0) < os.clock() then
		local name = bestSkin(CupsConfig, player.Cups, player.EquippedCup.Value)
		if name then
			cands[#cands + 1] = { cost = CupsConfig.Skins[name].Price, buy = function()
				return buySkin("Cup", CupsConfig, player.Cups, Remotes.BuyCup, Remotes.EquipCup, player.EquippedCup)
			end }
		end
	end
	if (cool.Dealer or 0) < os.clock() then
		local name = bestSkin(DealersConfig, player.OwnedDealers, player.EquippedDealer.Value)
		if name then
			cands[#cands + 1] = { cost = DealersConfig.Skins[name].Price, buy = function()
				return buySkin("Dealer", DealersConfig, player.OwnedDealers, Remotes.BuyDealer, Remotes.EquipDealer, player.EquippedDealer)
			end }
		end
	end
	table.sort(cands, function(a, b)
		return a.cost < b.cost
	end)
	if cands[1] then
		return cands[1].buy()
	end
	return false
end

local function upgradeLoop(mine)
	while genUpgrade == mine do
		local good, did = pcall(upgradePass)
		if not good then
			warn("[cupzoo] upgrade pass failed:", did)
		end
		task.wait(did and 0.2 or UPGRADE_EVERY)
	end
end

local function setUpgrade(on)
	genUpgrade += 1
	if on then
		task.spawn(upgradeLoop, genUpgrade)
	end
end

-- chomper ---------------------------------------------------------------------
-- Feed the Chomper Infested eggs: 10 feeds fill its bar and the server pays out a tree egg. Own all three
-- trees (cut / ruined / haunted, from tree eggs) and ClaimChomperEvent gives the Chomper animal.
-- The prompt's 16 studs are a client gate: the remote takes no arguments and was accepted from 221 studs
-- away (probed). The server wants the egg HELD ("Hold an Infested egg, then press E to feed it") and paces
-- feeds at ChomperConfig.EatTime, so the loop waits that long after each one.
local FEED_CONFIRM = 2 -- a feed must take an Infested egg off you inside this
local EQUIP_WAIT = 0.15 -- after EquipTool, before the feed
local CLAIM_EVERY = 5 -- how often the event status is read
local FeedChomper = Remotes:WaitForChild("FeedChomper")
local ChomperPayout = Remotes:WaitForChild("ChomperPayout")
local ClaimChomper = Remotes:WaitForChild("ClaimChomperEvent")
local GetChomperStatus = Remotes:WaitForChild("GetChomperEventStatus")
local okCfg, ChomperCfg = pcall(require, ReplicatedStorage.Configs.ChomperConfig)
local feedGap = (okCfg and ChomperCfg.EatTime or 2.05) + 0.1
local genFeed, genClaim = 0, 0
local payoutCon

local function feedLoop(mine)
	local misses = 0
	while genFeed == mine do
		local tool = infestedTools()[1]
		if not tool then
			say("no Infested egg held", true, "chomp")
			task.wait(0.5)
		else
			local char = player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hum and tool.Parent ~= char then
				pcall(hum.EquipTool, hum, tool)
				task.wait(EQUIP_WAIT)
			end
			local left, before = #infestedTools(), player:GetAttribute("ChomperFill") or 0
			FeedChomper:FireServer()
			local dl = os.clock() + FEED_CONFIRM
			while genFeed == mine and os.clock() < dl and #infestedTools() >= left do
				task.wait()
			end
			if #infestedTools() < left then
				misses = 0
				stats.fed += 1
				say(("fed %d (bar %d%%), %d Infested left"):format(stats.fed, math.floor((player:GetAttribute("ChomperFill") or 0) * 100 + 0.5), #infestedTools()), true, "chomp")
				task.wait(feedGap)
			else
				misses += 1
				warn("[cupzoo] feed not taken:", tool.Name, "fill", before, "last notice:", lastNote, os.clock() - lastNoteAt < 3 and "(fresh)" or "(old)")
				task.wait(math.min(5, feedGap * (1 + misses)))
			end
		end
	end
end

local function setFeed(on)
	genFeed += 1
	if payoutCon then
		payoutCon:Disconnect()
		payoutCon = nil
	end
	if on then
		-- the game's own listeners play the throw / spit cutscene and a reveal card on every feed and payout.
		-- Mute BEFORE connecting ours; they only draw, nothing is sent back to the server.
		mute(FeedChomper)
		mute(ChomperPayout)
		payoutCon = ChomperPayout.OnClientEvent:Connect(function(id)
			stats.trees += 1
			log("Chomper paid out", tostring(id), "(" .. stats.trees .. " this run)")
		end)
		log("feed on:", #infestedTools(), "Infested eggs held, bar", player:GetAttribute("ChomperFill"))
		local mine = genFeed
		task.spawn(function()
			local good, err = pcall(feedLoop, mine)
			if not good then
				warn("[cupzoo] feed loop died:", err)
			end
		end)
	else
		unmute(FeedChomper)
		unmute(ChomperPayout)
	end
end

-- {Need, Have, Claimed}; the reply may or may not carry a leading true, so take the first table
local function chomperStatus()
	local box
	task.spawn(function()
		local good, a, b = pcall(GetChomperStatus.InvokeServer, GetChomperStatus)
		box = good and (type(a) == "table" and a or type(b) == "table" and b) or false
	end)
	local dl = os.clock() + REPLY_WAIT * 2
	while box == nil and os.clock() < dl do
		task.wait()
	end
	return box or nil
end

local function claimLoop(mine)
	local tries = 0
	while genClaim == mine do
		local st = chomperStatus()
		if st then
			say(("trees %s/%s%s"):format(tostring(st.Have), tostring(st.Need), st.Claimed and ", claimed" or ""), true, "chomp")
			if not st.Claimed and (st.Have or 0) >= (st.Need or 1) then
				tries += 1
				-- ponytail: no client script calls this, so the argument shape is a guess (none). Log what comes back.
				ClaimChomper:FireServer()
				task.wait(2)
				local after = chomperStatus()
				log("ClaimChomperEvent fired, status after:", after and after.Claimed, "last notice:", lastNote)
				if tries >= 3 and not (after and after.Claimed) then
					warn("[cupzoo] claim not taken after 3 tries -- needs a look at the arguments")
					return
				end
			end
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
local Window, Library = panel({ game = "Cup Shuffle Zoo", size = UDim2.fromOffset(560, 430), statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "egg")
local Buy = Tab:AddLeftGroupbox("Eggs", "egg")
local Zoo = Tab:AddLeftGroupbox("Animals", "paw-print")
local Hands = Tab:AddRightGroupbox("Plot", "layout-grid")
local Up = Tab:AddRightGroupbox("Upgrades", "trending-up")
local Chomp = Tab:AddRightGroupbox("Chomper event", "bug")

local obtainable = EggsConfig.Obtainable()
local eggValues, eggByLabel, eggDefault = {}, {}, {}
for _, cfg in ipairs(obtainable) do
	local label = ("%s (%s)"):format(cfg.name, fmt(cfg.price))
	eggValues[#eggValues + 1] = label
	eggByLabel[label] = cfg.id
	if cfg.tier >= MIN_TIER_DEFAULT then
		eggDefault[#eggDefault + 1] = label
		eggOn[cfg.id] = true -- Value / Default does not fire the callback, so arm by hand
	end
end
for _, m in ipairs(Mutations.ORDER) do
	mutOn[m] = true
end

local buyToggle
buyToggle = Buy:AddToggle("Buy", {
	Text = "Auto Roll + Buy Egg",
	Tooltip = "Rerolls the dealer's egg until it is one you ticked and within the price box, then buys it with the right cup picked at once. Mutes the game's cup controller while on",
	Default = false,
	Callback = function(state)
		setBuy(state)
		if state and not muted[GHS] then
			buyToggle:Set(false)
		end
	end,
})
Buy:AddDropdown("Eggs", {
	Text = "Eggs to buy",
	Tooltip = "Reroll until the dealer shows one of these. Price in brackets. Ticking only the top one you can afford buys fewer, better eggs",
	Values = eggValues,
	Default = eggDefault,
	Multi = true,
	Callback = function(picked)
		table.clear(eggOn)
		for label in pairs(ticked(picked)) do
			local id = eggByLabel[label]
			if id then
				eggOn[id] = true
			end
		end
	end,
})
Buy:AddDropdown("Mutations", {
	Text = "Mutations to buy",
	Tooltip = "A mutated egg hatches a mutated animal (Gold 1.25x income up to Rainbow 2x). Untick Normal to roll until a mutated one shows",
	Values = Mutations.ORDER,
	Default = Mutations.ORDER,
	Multi = true,
	Callback = function(picked)
		table.clear(mutOn)
		for name in pairs(ticked(picked)) do
			mutOn[name] = true
		end
	end,
})
Buy:AddToggle("InfestedOnly", {
	Text = "Infested eggs only (Chomper food)",
	Tooltip = "Rerolls until the dealer's offer carries the Infested flag (about 4% of rolls) on a ticked egg, then buys it. Infested eggs are kept for the Chomper, never placed. Tick only cheap eggs: a pricey Infested egg is just as good food",
	Default = false,
	Callback = function(state)
		infestedOnly = state
	end,
})
Hands:AddToggle("Place", {
	Text = "Auto Place Egg",
	Tooltip = "Puts held eggs on free ground of your plot, best tier first, up to the plot's egg cap. No need to hold them",
	Default = false,
	Callback = setPlace,
})
Hands:AddToggle("Hatch", {
	Text = "Auto Hatch Egg",
	Tooltip = "Opens each egg the moment its timer is up (earlier is refused) and skips the hatch cutscene",
	Default = false,
	Callback = setHatch,
})
Zoo:AddToggle("Sell", {
	Text = "Auto Sell Animals",
	Tooltip = "Sells stored animals of the rarities ticked below, one at a time. Only while the plot is full (a free slot means Equip Best places them) and never an animal rarer than your weakest placed one. Mutations are not looked at: untick a rarity you want to keep Rainbows from",
	Default = false,
	Callback = setSell,
})
Zoo:AddDropdown("SellRarity", {
	Text = "Rarities to sell",
	Tooltip = "Nothing is ticked to start with. A sale pays the animal's sell value",
	Values = RARITIES,
	Default = {},
	Multi = true,
	Callback = function(picked)
		table.clear(sellOn)
		for name in pairs(ticked(picked)) do
			sellOn[name] = true
		end
	end,
})
Hands:AddToggle("Equip", {
	Text = "Auto Equip Best Animals",
	Tooltip = "Presses the game's Equip Best button whenever your animal or slot count changes, so hatched animals that beat a placed one take its slot",
	Default = false,
	Callback = setEquip,
})
Up:AddToggle("Upgrade", {
	Text = "Auto Upgrade",
	Tooltip = "Buys the cheapest affordable of: next Tourist (zoo) level, a better cup, a better dealer. Bought cups and dealers are equipped. Pass-only skins and Robux routes are never touched",
	Default = false,
	Callback = setUpgrade,
})

Chomp:AddToggle("Feed", {
	Text = "Auto Feed Chomper",
	Tooltip = "Feeds the Infested eggs you hold to the Chomper from wherever you stand: 10 feeds = one tree egg. Turn on Infested eggs only above to buy them. Mutes the feed / payout cutscene while on",
	Default = false,
	Callback = setFeed,
})
Chomp:AddToggle("Claim", {
	Text = "Auto Claim Chomper",
	Tooltip = "Claims the Chomper animal the moment you own all three trees (cut, ruined, haunted). Tree eggs come from feeding, and Auto Place + Auto Hatch turn them into trees",
	Default = false,
	Callback = setClaim,
})

local function eggStatus()
	local base = myBase()
	local eggs = base and base:FindFirstChild("Eggs")
	return ("%d held, %d/%d placed"):format(heldCount(), eggs and #eggs:GetChildren() or 0, base and base:GetAttribute("EggCapacity") or 0)
end

local conns = {}
local note, buyNote, chompNote = "idle", "off", "off"
local nextStrip = 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	if pending.now then
		note, pending.now = pending.now, nil
	end
	if pending.buy then
		buyNote, pending.buy = pending.buy, nil
	end
	if pending.chomp then
		chompNote, pending.chomp = pending.chomp, nil
	end
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	pcall(Window.SetStatus, Window, { -- ponytail: thrown "lacking capability Plugin" when loaded through the bridge; silence, not fix
		{ "Cash", fmt(money.Value) },
		{ "Eggs", eggStatus() },
		{ "Bought", stats.bought .. (stats.lost > 0 and (" (" .. stats.lost .. " lost)") or "") },
		{ "Rolls", stats.rolls },
		{ "Opened", stats.hatched },
		{ "Sold", stats.sold },
		{ "Fed", stats.fed .. " (" .. stats.trees .. " tree eggs)" },
		{ "Buy", buyNote },
		{ "Chomper", chompNote },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("CupShuffleZoo", {})

local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- close ----------------------------------------------------------------------
local function stopAll()
	setBuy(false) -- ExitGame + hands the game's cup controller back
	setPlace(false)
	setHatch(false) -- hands the hatch cutscene back
	setEquip(false)
	setSell(false)
	setUpgrade(false)
	setFeed(false) -- hands the feed / payout cutscene back
	setClaim(false)
	noteCon:Disconnect()
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().cupZooStop = nil
end)

getgenv().cupZooStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().cupZooStop = nil
end
