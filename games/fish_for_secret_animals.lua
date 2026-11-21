--[[ Fish for Secret Animals -- instant perfect casts, training, upgrades, best beasts penned (107192230357786)

     FISH   : cast back to back from the ledge: every cast perfect, none of the throw / flight / reel /
              reveal sequence, ~40 casts a minute (the server's 1.5s cast cooldown is the cap)
     TRAIN  : stand on your plot's pull-up bar and train, pressing every 2x rep (the only XP / Power
              source: catches give none). Both on: fish FISH_FOR, train TRAIN_FOR, repeat
     PEN    : the Beasts panel's "Equip Best" every few seconds, so your best catch earns at once
     SELL   : storage holds 100; at SELL_AT the cheapest stored beasts are sold at the SELL stall
     BUY    : next rod / next pull-up bar as soon as cash covers it; keeps the best cash bait stocked
     EXTRAS : daily + index rewards, nest eggs once ready, every code in the game's Config, best pet

     How it works (probed live, v300): a cast is CastBegin() -> Cast(bar, power) -> ClaimCatch(id),
     all RemoteFunctions through PlayerScripts.Client.Net. Cast's first argument is the client's own
     power-bar point (1 = top = PERFECT; BarPoints clamps it to PowerBarMax 25), the second is clamped
     server-side (100 landed at a normal distance). The ~30s between Cast and ClaimCatch is all
     client animation: ClaimCatch 0.2s after Cast lands the catch. CastBegin refuses (bare false)
     outside the ledge box (Config.CastLineX..LedgeX, CastZ0..CastZ1) and for ~0.2s after a hop; the
     server sends you back to the hub after every claim, so each cast hops back (~110 studs).
     Distance (= luck and biome) comes from the Power stat, i.e. training. CastBegin's table return is
     a SECRET CAST's pre-roll; CastEnd + CastBegin keeps the same roll (no free reroll), and a begin
     spends no bait. Training: StartTraining is ignored away from Map.Gym.PullUpBar_<PlotIndex>; reps
     tick server-side, DoubleRep is a window the attribute of that name opens. FillPen, BuyTier("Bar"),
     Buy("Rod", id), Buy("Bait", id), RedeemCode, Claim, NestHatch all answer from anywhere.
     SellBeast(id) says "Walk up to the SELL stall to sell." away from Map.Stands.Sell (took at 7
     studs); it pays V x Config.SellSeconds. Sell() with no id sells only the beast you carry.
     PROBED AND DEAD: cast power > 1 (clamped), rerolling a secret cast, Sell() as a bulk sell.
     Not wired (Robux): NestInsta, AutoThrow pass, premium baits / rods' Robux route, Admin remote.
     Movement: hop, kept to 80 studs per jump, glide held to 3000 studs/s (Z.moves 2026-11-21, user's
     standing yes to teleports).

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().fishSecretStop() ]]

-- config ---------------------------------------------------------------------
local HOP_MAX = 80 -- studs per jump; the measured keep. Lower if hops start snapping back.
local HOP_SETTLE = 0.25 -- seconds after a hop before CastBegin; at 0 the server hasn't seen the move yet
local CAST_GAP = 1.5 -- Config.CastCooldown; seconds between CastBegins. Raise if begins get refused in a row.
local CALL_TIMEOUT = 8 -- seconds before a hung InvokeServer is abandoned
local RETRY = 2 -- seconds after a refused step
local FISH_FOR = 300 -- seconds of fishing per cycle when training is on too (panel input)
local TRAIN_FOR = 60 -- seconds of training per cycle when fishing is on too (panel input)
local SELL_AT = 90 -- beasts owned (Config.MaxBeasts is 100) that sends the fisher to the stall
local SELL_TO = 60 -- sell the cheapest stored ones down to this many
local PEN_EVERY = 5 -- seconds between Equip Best calls
local BUY_EVERY = 2 -- seconds between upgrade checks
local BAIT_MIN = 50 -- keep at least this many of the best cash bait (packs of 10)
local CLAIM_EVERY = 300 -- seconds between daily / index / nest / pet passes

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().fishSecretStop then
	getgenv().fishSecretStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[fishsecret]", ...)
end

local note, lastSaid, lastBeat = "idle", nil, os.clock()
local function say(msg)
	note = msg
	lastBeat = os.clock() -- the watchdog's breadcrumb: every step says something
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
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

-- world ----------------------------------------------------------------------
local okMods, Net, Config = pcall(function()
	return require(player:WaitForChild("PlayerScripts"):WaitForChild("Client"):WaitForChild("Net", 15)),
		require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config", 15))
end)
if not (okMods and type(Net) == "table" and type(Net.invoke) == "function") then
	warn("[fishsecret] the game's Net / Config modules did not load: wrong game?", Net)
	return
end

-- The game starts its own "CLICK TO CAST!" (WalkSpeed 0, you're stuck in it) whenever you stand idle
-- in the ledge box; Cast.hold is the hook its Eggs / Ride controllers chain to stop that, so we
-- chain it too while the farm runs.
local okCast, Cast = pcall(function()
	return require(player.PlayerScripts.Client:WaitForChild("Cast", 10))
end)
local castHoldPrev, castMuted = nil, false
local function muteAutoCast(on)
	if not (okCast and type(Cast) == "table") or castMuted == on then
		return
	end
	castMuted = on
	if on then
		castHoldPrev = Cast.hold
		Cast.hold = function(...)
			return true
		end
	else
		Cast.hold = castHoldPrev
	end
end

-- Net.invoke pcalls but has no timeout, and a parked InvokeServer is a farm that silently stops.
local function call(name, ...)
	local args = table.pack(...)
	local res, done = nil, false
	task.spawn(function()
		res = table.pack(Net.invoke(name, table.unpack(args, 1, args.n)))
		done = true
	end)
	local untilT = os.clock() + CALL_TIMEOUT
	while not done and os.clock() < untilT do
		task.wait()
	end
	if not done then
		log("timed out:", name)
		return nil, "timeout"
	end
	return table.unpack(res, 1, res.n)
end

local function fire(name, ...)
	pcall(Net.fire, name, ...)
end

-- The game's own save mirror (the State event), so nothing here depends on what is streamed in.
local function state()
	return type(Net.State) == "table" and Net.State or {}
end

local function beasts()
	local all, stored = 0, {}
	for _, b in pairs(state().Beasts or {}) do
		all += 1
		if b.S == "store" and not b.L then
			stored[#stored + 1] = b
		end
	end
	return all, stored
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function root()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- The cast box from the game's own numbers: between the cast line and the ledge, mid-lane.
local LEDGE = Vector3.new(
	((Config.CastLineX or -129.2) + (Config.LedgeX or -117.2)) / 2,
	87.2,
	((Config.CastZ0 or -6.8) + (Config.CastZ1 or 85.5)) / 2
)

local function barSpot()
	local gym = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Gym")
	local bar = gym and gym:FindFirstChild("PullUpBar_" .. tostring(player:GetAttribute("PlotIndex")))
	return bar and bar:GetPivot().Position + Vector3.new(0, 3, 0)
end

local function stallSpot()
	local stands = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Stands")
	local sell = stands and stands:FindFirstChild("Sell")
	local p = sell and sell:GetPivot().Position
	return p and Vector3.new(p.X - 7, 87.2, p.Z) -- 7 studs in front of the stall, hub side (took live)
end

local stopTraining -- below; a hop off the bar needs it

-- Teleport first, in jumps of at most HOP_MAX. A hop off the bar can be undone, and landing back in
-- the bar's circle makes the game's own controller start training again (seen live: the farm then sat
-- pinned for 15 min), so a revert stops training again and retries with a longer settle.
local function hopTo(spot)
	local r = root()
	if not (r and spot) then
		return false
	end
	for try = 1, 3 do
		stopTraining()
		local from = r.Position
		local dist = (flat(spot) - flat(from)).Magnitude
		if dist < 6 then
			return true
		end
		local legs = math.ceil(dist / HOP_MAX)
		for i = 1, legs do
			local p = from:Lerp(spot, i / legs)
			r.AssemblyLinearVelocity = Vector3.zero
			r.CFrame = CFrame.new(Vector3.new(p.X, spot.Y, p.Z))
			task.wait(i < legs and 0.05 or HOP_SETTLE * try)
		end
		if (flat(r.Position) - flat(spot)).Magnitude < 6 then
			return true
		end
		say(("hop reverted (try %d)"):format(try))
		task.wait(0.5 * try)
	end
	-- shortcut: walk is the only fallback, add a glide rung if hops ever keep reverting
	say("hops reverted, walking")
	stopTraining()
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	local untilT = os.clock() + 10 -- MoveToFinished never fires while the server pins you: bound it
	while hum and os.clock() < untilT and (flat(r.Position) - flat(spot)).Magnitude >= 6 do
		hum:MoveTo(spot)
		task.wait(0.5)
	end
	return (flat(r.Position) - flat(spot)).Magnitude < 6
end

-- fish / sell / train -------------------------------------------------------
local stats = { caught = 0, refused = 0, sold = 0, soldFor = 0, rods = 0, bars = 0, baits = 0, last = "-" }
local want = { fish = false, train = false, sell = false, pen = false }
local lastCast = 0

-- A hop fired while the server still has you on the bar is undone (seen live), so wait it out,
-- re-sending the stop each second in case one was dropped.
function stopTraining()
	local char = player.Character
	if not (char and char:GetAttribute("Training")) then
		return
	end
	local untilT = os.clock() + 4
	while char:GetAttribute("Training") and os.clock() < untilT do
		fire("StopTraining")
		local beat = os.clock() + 1
		while char:GetAttribute("Training") and os.clock() < beat do
			task.wait(0.05)
		end
	end
	task.wait(0.3)
end

local function sellDown(alive)
	local all, stored = beasts()
	if all < SELL_AT then
		return
	end
	if want.pen then
		fire("FillPen") -- the best go into the pen before anything is sold
		task.wait(0.5)
		all, stored = beasts()
	end
	table.sort(stored, function(a, b)
		return (a.V or 0) < (b.V or 0)
	end)
	if not hopTo(stallSpot()) then
		say("sell stall not reachable")
		task.wait(RETRY)
		return
	end
	local n = 0
	for _, b in ipairs(stored) do
		if all <= SELL_TO or not alive() then
			break
		end
		local def = Config.BeastById and Config.BeastById[b.K] or {}
		if not def.Exclusive and def.Rarity ~= "Secret" then
			local ok, got = call("SellBeast", b.Id)
			if ok then
				all -= 1
				n += 1
				stats.sold += 1
				stats.soldFor += tonumber(got) or 0
			else
				say("sell refused: " .. tostring(got))
				break
			end
		end
	end
	say(("sold %d, %d beasts left"):format(n, all))
end

local casting = false -- a cast in flight: leaveLedge waits for it, or it lands you back on the ledge
local function castOnceInner(alive)
	stopTraining()
	if want.sell then
		sellDown(alive)
	end
	local r = root()
	if not r then
		task.wait(RETRY)
		return
	end
	if (flat(r.Position) - flat(LEDGE)).Magnitude > 6 and not hopTo(LEDGE) then
		task.wait(RETRY)
		return
	end
	local w = CAST_GAP - (os.clock() - lastCast)
	if w > 0 then
		task.wait(w)
	end
	-- the server takes a moment to see the hop: retry a refused begin on a short ladder
	local ok
	for _, gap in ipairs({ 0, 0.35, 1, 2 }) do
		task.wait(gap)
		ok = call("CastBegin")
		if ok or not alive() then
			break
		end
	end
	if not ok then
		stats.refused += 1
		say("cast refused at " .. tostring(flat(r.Position)))
		task.wait(RETRY)
		return
	end
	lastCast = os.clock()
	local c = call("Cast", 1, player:GetAttribute("CastPower") or 1) -- 1 = top of the bar: PERFECT
	if type(c) ~= "table" or not c.Id then
		stats.refused += 1
		fire("CastEnd")
		say("cast returned " .. tostring(c))
		task.wait(0.3)
		return
	end
	local got, where = call("ClaimCatch", c.Id)
	if got then
		stats.caught += 1
		local what = ("%s %s%s"):format(tostring(c.Rarity), c.Mutation and c.Mutation ~= "" and (c.Mutation .. " ") or "", tostring(c.Name))
		stats.last = what .. " " .. fmt(c.Value) .. "/s"
		say(("caught %s in %s (%s)"):format(what, tostring(c.Biome), where == "pen" and "pen" or "storage"))
	else
		stats.refused += 1
		fire("CastEnd")
		say("claim refused: " .. tostring(where))
	end
end

local function castOnce(alive)
	casting = true
	local ok, err = pcall(castOnceInner, alive)
	casting = false
	if not ok then
		error(err, 0)
	end
end

-- Keeps training going for `seconds`, pressing every double-rep window.
local function trainFor(seconds, alive)
	local untilT = os.clock() + seconds
	while os.clock() < untilT and alive() do
		local char = player.Character
		if not (char and char:GetAttribute("Training")) then
			if not hopTo(barSpot()) then
				say("pull-up bar not found")
				task.wait(RETRY)
				continue
			end
			fire("StartTraining")
			task.wait(0.5)
			if not (player.Character and player.Character:GetAttribute("Training")) then
				say("training did not start")
				task.wait(RETRY)
				continue
			end
		end
		if player:GetAttribute("DoubleRep") == true then
			fire("DoubleRep")
			task.wait(0.3)
		end
		say(("training (level %s)"):format(tostring(player:GetAttribute("Level") or "?")))
		task.wait(0.1)
	end
end

-- One generation counter per toggle: off-then-on inside one wait must not leave the old thread alive.
local function makeLoop(pass)
	local L = { on = false, gen = 0 }
	function L.set(onNow)
		L.on = onNow
		L.gen += 1
		if not onNow then
			return
		end
		local mine = L.gen
		local function alive()
			return L.on and L.gen == mine
		end
		task.spawn(function()
			while alive() do
				local ok, err = pcall(pass, alive)
				if not ok then
					warn("[fishsecret] pass threw:", err)
					task.wait(RETRY)
				end
			end
		end)
	end
	return L
end

-- Fishing, selling and training share the character (the server refuses a cast while training), so
-- one loop owns all three and alternates when fishing and training are both on.
local body = makeLoop(function(alive)
	if want.fish and want.train then
		local untilT = os.clock() + FISH_FOR
		while os.clock() < untilT and alive() and want.fish do
			castOnce(alive)
		end
		if alive() and want.train then
			trainFor(TRAIN_FOR, function()
				return alive() and want.train
			end)
		end
	elseif want.fish then
		castOnce(alive)
	elseif want.train then
		trainFor(5, function()
			return alive() and want.train and not want.fish
		end)
	elseif want.sell then
		sellDown(alive)
		task.wait(RETRY)
	end
end)

local leaveLedge -- below: it needs the body loop's state
local function setBody(kind, on)
	want[kind] = on
	if kind == "train" and not on then
		task.spawn(stopTraining)
	end
	if want.fish or want.train or want.sell then
		muteAutoCast(true)
		if not body.on then
			body.set(true)
		end
	else
		body.set(false)
		say("stopped")
		task.spawn(leaveLedge)
	end
end

-- Step off the ledge before giving the game its auto-cast back, or it starts one on you at once.
function leaveLedge()
	local untilT = os.clock() + 8
	while casting and os.clock() < untilT do
		task.wait(0.1)
	end
	local r = root()
	local p = r and r.Position
	if p and p.X >= (Config.CastLineX or -129.2) - 1 and math.abs(p.Z - LEDGE.Z) < 60 then
		r.CFrame = CFrame.new(Vector3.new((Config.CastLineX or -129.2) - 6, p.Y, p.Z))
	end
	task.wait(0.3)
	muteAutoCast(false)
end

-- upgrades, pen and extras (remote from anywhere: none of these take the body) ---
local function sleep(seconds, alive)
	local untilT = os.clock() + seconds
	while os.clock() < untilT and alive() do
		task.wait(0.25)
	end
end

local penner = makeLoop(function(alive)
	fire("FillPen")
	sleep(PEN_EVERY, alive)
end)

local function nextRod()
	local cur = player:GetAttribute("Rod")
	local excl = {}
	for _, id in ipairs(Config.ExclusiveRods or {}) do
		excl[id] = true
	end
	for i, rod in ipairs(Config.Rods or {}) do
		if rod.Id == cur then
			local n = Config.Rods[i + 1]
			return n and not excl[n.Id] and (n.Price or 0) > 0 and n or nil
		end
	end
	return nil
end

-- The best bait cash can buy: the luckiest one with a cash price and no Robux route.
local BEST_BAIT
for _, b in ipairs(Config.Baits or {}) do
	if (b.Price or 0) > 0 and (b.Robux or 0) == 0 and (not BEST_BAIT or (b.Luck or 0) > (BEST_BAIT.Luck or 0)) then
		BEST_BAIT = b
	end
end

local buy = { rod = false, bar = false, bait = false }
local buyer = makeLoop(function(alive)
	local cash = tonumber(player:GetAttribute("Cash")) or 0
	local rod = buy.rod and nextRod()
	if rod and rod.Price <= cash then
		if call("Buy", "Rod", rod.Id) then
			stats.rods += 1
			log("bought rod", rod.Id, fmt(rod.Price))
			cash -= rod.Price
		end
	end
	local tier = (player:GetAttribute("BarTier") or 0) + 1
	local bar = buy.bar and Config.BarTiers and Config.BarTiers[tier]
	if bar and bar.Price <= cash then
		if call("BuyTier", "Bar") then
			stats.bars += 1
			log("bought bar", bar.Name, fmt(bar.Price))
			cash -= bar.Price
		end
	end
	if buy.bait and BEST_BAIT then
		local have = (state().Baits or {})[BEST_BAIT.Id] or 0
		if have < BAIT_MIN and BEST_BAIT.Price <= cash and call("Buy", "Bait", BEST_BAIT.Id) then
			stats.baits += BEST_BAIT.Pack or 10
		end
		-- only re-equip off the free fallback: a premium bait you picked by hand stays on
		local on = player:GetAttribute("Bait")
		if (on == nil or on == "Worm") and ((state().Baits or {})[BEST_BAIT.Id] or 0) > 0 then
			call("Equip", "Bait", BEST_BAIT.Id)
		end
	end
	sleep(BUY_EVERY, alive)
end)

local extras = { claims = false, nest = false, pet = false }
local claimer = makeLoop(function(alive)
	if extras.claims then
		call("Claim", "Daily")
		local done = state().IndexClaimed or {}
		for _, b in ipairs(Config.Biomes or {}) do
			if not alive() then
				break
			end
			if not done[b.Id] then
				local ok, msg = call("Claim", "Index", b.Id)
				if ok then
					log("index reward:", b.Id, tostring(msg))
				end
				task.wait(0.6)
			end
		end
	end
	if extras.nest then
		local now = workspace:GetServerTimeNow()
		for _, egg in ipairs(state().NestEggs or {}) do
			if (tonumber(egg.R) or math.huge) <= now then
				local res = call("NestHatch", egg.Id)
				log("nest hatch", egg.T, type(res) == "table" and "ok" or tostring(res))
			end
		end
	end
	if extras.pet then
		call("PetEquip", "Best")
	end
	sleep(extras.nest and 30 or CLAIM_EVERY, alive)
end)

local function redeemAll()
	for code, def in pairs(Config.Codes or {}) do
		if not def.Users then -- a code with a Users list is staff-only
			local ok, msg = call("RedeemCode", code)
			log("code", code, tostring(ok), tostring(msg))
			task.wait(2.5) -- the server says "Slow down a little!" under ~2s
		end
	end
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Fish for Secret Animals", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "fish")
local Farm = Tab:AddLeftGroupbox("Farm", "anchor")

Farm:AddToggle("AutoFish", {
	Text = "Auto perfect cast",
	Tooltip = "Cast back to back from the ledge: perfect every time, no animation (~40 a minute)",
	Default = false,
	Callback = function(on)
		pcall(setBody, "fish", on)
	end,
})

Farm:AddToggle("AutoTrain", {
	Text = "Auto train",
	Tooltip = "Train on your pull-up bar, pressing every 2x rep. With auto cast on too, it alternates",
	Default = false,
	Callback = function(on)
		pcall(setBody, "train", on)
	end,
})

Farm:AddInput("FishFor", {
	Text = "Fishing seconds per cycle",
	Tooltip = "With both on: fish this long, then train",
	Default = tostring(FISH_FOR),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		FISH_FOR = math.max(10, tonumber(text) or FISH_FOR)
	end,
})

Farm:AddInput("TrainFor", {
	Text = "Training seconds per cycle",
	Tooltip = "With both on: how long each training block lasts",
	Default = tostring(TRAIN_FOR),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		TRAIN_FOR = math.max(5, tonumber(text) or TRAIN_FOR)
	end,
})

Farm:AddToggle("AutoPen", {
	Text = "Auto equip best",
	Tooltip = "The Beasts panel's Equip Best every " .. PEN_EVERY .. "s: your best catches go in the pen",
	Default = false,
	Callback = function(on)
		want.pen = on
		pcall(penner.set, on)
	end,
})

Farm:AddToggle("AutoSell", {
	Text = "Auto sell storage",
	Tooltip = "At " .. SELL_AT .. " beasts (cap 100): sell the cheapest stored ones down to " .. SELL_TO .. " at the SELL stall. Never pen, locked, carried, exclusive or Secret",
	Default = false,
	Callback = function(on)
		pcall(setBody, "sell", on)
	end,
})

local Ups = Tab:AddRightGroupbox("Upgrades", "arrow-up")

local function buyRow(idx, key, text, tip)
	Ups:AddToggle(idx, {
		Text = text,
		Tooltip = tip,
		Default = false,
		Callback = function(on)
			buy[key] = on
			local any = buy.rod or buy.bar or buy.bait
			if any ~= buyer.on then -- set() on every row would start one buyer per row
				pcall(buyer.set, any)
			end
		end,
	})
end
buyRow("AutoRod", "rod", "Auto buy next rod", "Buys the next rod (cash) as soon as you can afford it")
buyRow("AutoBar", "bar", "Auto buy next pull-up bar", "Buys the next bar as soon as you can afford it: XP per rep doubles each tier")
buyRow("AutoBait", "bait", "Auto buy bait", "Keeps " .. BAIT_MIN .. "+ " .. (BEST_BAIT and BEST_BAIT.Name or "bait") .. " stocked. Premium baits are left alone")

local Ext = Tab:AddRightGroupbox("Extras", "gift")
local function extraRow(idx, key, text, tip)
	Ext:AddToggle(idx, {
		Text = text,
		Tooltip = tip,
		Default = false,
		Callback = function(on)
			extras[key] = on
			local any = extras.claims or extras.nest or extras.pet
			if any ~= claimer.on then
				pcall(claimer.set, any)
			end
		end,
	})
end
extraRow("AutoClaims", "claims", "Claim daily + index", "Daily reward and each finished biome's index reward")
extraRow("AutoNest", "nest", "Auto hatch nest eggs", "Hatches each nest egg once its timer is up (never the paid Insta Hatch)")
extraRow("AutoPet", "pet", "Equip best pet", "PetEquip Best every few minutes")
Ext:AddButton({
	Text = "Redeem all codes",
	Func = function()
		task.spawn(redeemAll)
	end,
})

local conns = {}
local nextStrip = 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	local all = beasts()
	pcall(Window.SetStatus, Window, {
		{ "Cash", fmt(player:GetAttribute("Cash")) },
		{ "Income", fmt(player:GetAttribute("Income")) .. "/s" },
		{ "Level", tostring(player:GetAttribute("Level") or "-") },
		{ "Caught", stats.caught .. (stats.refused > 0 and (" (" .. stats.refused .. " refused)") or "") },
		{ "Beasts", all .. "/" .. tostring(Config.MaxBeasts or 100) },
		{ "Sold", stats.sold .. " for " .. fmt(stats.soldFor) },
		{ "Bought", stats.rods .. " rods, " .. stats.bars .. " bars" },
		{ "Last", stats.last },
		{ "Now", note },
	})
end))

-- watchdog: a farm parked in a yield can't report, so a separate beat names where it stopped
table.insert(conns, RunService.Heartbeat:Connect(function()
	if body.on and os.clock() - lastBeat > 60 then
		lastBeat = os.clock()
		warn("[fishsecret] stuck 60s at: " .. tostring(note))
	end
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("FishForSecretAnimals", {})

local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- close ----------------------------------------------------------------------
local function stopAll()
	want.fish, want.train, want.sell, want.pen = false, false, false, false
	body.set(false)
	penner.set(false)
	buyer.set(false)
	claimer.set(false)
	task.spawn(function()
		stopTraining()
		leaveLedge()
	end)
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().fishSecretStop = nil
end)

getgenv().fishSecretStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().fishSecretStop = nil
end
