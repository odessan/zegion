--[[ Fake an Egg -- grab real eggs, bank, hatch, place, feed (97289366402005)
     PlaceVersion 528

     GRAB   : glides to the best real egg you can pay for (ticked rarities, highest price first), buys it
              (EggEvent "Buy", through the egg's own BuyPrompt handler so the game supplies the id), and glides
              into the base's Collect volume. The server sets Carrying = <egg> on the buy and drops the egg into
              a free nest once you stand in Collect, so "place egg" needs nothing sent. The Spawn pad is just
              outside Collect: landing there clears Carrying too but the egg goes back to the floor, so a bank
              is confirmed by a nest's Egg appearing, never by Carrying. One egg at a time; no trip while every
              nest is full.
     FAKES  : a disguised player has Disguised = true and FakeLanded = true, and their body sits ~3 studs from
              the egg model they are faking. Any egg with a disguised player within FAKE_RADIUS is skipped.
     HATCH  : player.Nests.<n> holds Egg / HatchAt. When HatchAt has passed, glides beside the base's nest <n>
              and fires OpenBlockEvent(n): Hatches +1, the nest frees, the animal lands in the bag. Range-gated:
              the same call from ~100 studs did nothing.
     PLACE  : the game's own Equip Best (EquipBestEvent) whenever an animal sits in the bag.
     FEED   : buys the ticked foods while the shop has stock (FoodEvent "Buy" works from anywhere, probed at 62
              studs), then glides to your feeder and Fills (refused at 97 studs, taken at 5). A Fill raised
              FeederLevel 2 -> 3 and income +9%.

     Probed and dead (do not re-probe):
       OpenBlockEvent(nest) from ~100 studs    nothing happened
       FoodEvent "Fill" from 97 studs          nothing happened
       Buy while already Carrying              ignored
     Not wired (Robux): SkipBoxEvent (Skip Timer), FoodEvent "BuyRobux", ScannerEvent "BuyRobux".
     Movement: a per-Heartbeat glide at GLIDE_SPEED. A 10-stud CFrame jump was reverted; glides held to 3000
                studs/s on short legs, but 3000 was pulled back once on a 150-stud leg. 250 studs/s ran 7 egg
                trips clean, then a pulled-back trip home retried 3x at once and was KICKED ("unusual movements",
                2026-11-01). 120 studs/s and a 35 studs/s average with 400-stud bursts were kicked the same way,
                each at ~27s: the server averages movement over about half a minute. So trips glide at the
                game's own WalkSpeed (30), and a pull-back is never retried at once (PULL_REST).

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().fakeEggStop() ]]

-- config ---------------------------------------------------------------------
-- studs/s, the game's own WalkSpeed. "Unusual movements" kicked at ~27s three times: 250 and 120 studs/s
-- glides, and a 35 studs/s average with 400-stud bursts (~1400 studs in 28s). Raise only with a soak to prove it.
local GLIDE_SPEED = 30
local GLIDE_MIN = 20
local GLIDE_CAP = 20 -- one glide leg gives up after this long (the farthest egg is ~250 studs, ~8s)
local PULL_REST = 4 -- after a pull-back nothing moves the body for this long; retrying at once is what got kicked
local FAKE_RADIUS = 7 -- studs between an egg and a disguised player that marks it fake (seen at 3.3)
local EXPIRE_MARGIN = 3 -- skip an egg with fewer seconds than this left on its CountdownEnd
local BUY_CONFIRM = 1.2 -- Carrying must show up inside this after the buy, re-firing every BUY_GAP
local BUY_GAP = 0.25
local BANK_CONFIRM = 4 -- Carrying must clear inside this once home
local EGG_BENCH = 20 -- an egg the server refused sits out this long
local GRAB_BEAT = 0.3
local HATCH_BEAT = 1
local HATCH_CONFIRM = 2 -- the nest's Egg must clear inside this after OpenBlockEvent
local HATCH_BACKOFF = 5
local EQUIP_GAP = 3 -- between Equip Best presses
local FEED_BEAT = 5
local FEED_BACKOFF = 60 -- a Fill that ate nothing is not retried for this long (feeder full)
local FILL_GAP = 0.9 -- between Fills; a Fill right after the last was ignored, 0.85s apart was taken (hand play)
local FOOD_KEEP = 3 -- buy food only while fewer than this sit in the bag (a stuck feeder stacked 18 otherwise)
local NEST_SIDE = Vector3.new(4, 3, 0) -- stand here relative to a nest (OpenBlock prompt range is 10)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().fakeEggStop then
	getgenv().fakeEggStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[fakeegg]", ...)
end

local seen = {}
local function first(name, ...)
	if not seen[name] then
		seen[name] = true
		log("first", name, ...)
	end
end

-- The strip is drained from a Heartbeat (our own identity); a loop thread writing to the window
-- throws "lacking capability Plugin" after its first task.wait.
local note, lastSaid = "idle", nil
local function say(msg)
	note = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
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
	n = tonumber(n) or 0
	local i = 1
	while n >= 1000 and i < #SUFFIX do
		n /= 1000
		i += 1
	end
	return ("%.3g"):format(n) .. SUFFIX[i]
end
assert(fmt(25000) == "25K" and fmt(1500) == "1.5K" and fmt(100) == "100", "fmt")

-- game -----------------------------------------------------------------------
local ok, Eggs, Food = pcall(function()
	return require(ReplicatedStorage:WaitForChild("Eggs", 15)), require(ReplicatedStorage:WaitForChild("Food", 15))
end)
if not ok then
	warn("[fakeegg] the game's modules did not load:", Eggs)
	return
end
local RE = ReplicatedStorage:WaitForChild("RemoteEvents")
local OpenBlockEvent, EquipBestEvent, FoodEvent =
	RE:WaitForChild("OpenBlockEvent"), RE:WaitForChild("EquipBestEvent"), RE:WaitForChild("FoodEvent")
local cash = player:WaitForChild("leaderstats"):WaitForChild("Cash")
local nestData = player:WaitForChild("Nests")

local function root()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function myBase()
	local bases = workspace:FindFirstChild("Bases")
	local b = bases and bases:FindFirstChild(tostring(player:GetAttribute("Base")))
	return b
end

-- travel ----------------------------------------------------------------------
-- A per-Heartbeat lerp with the velocity zeroed: the server sees a steady speed instead of a jump (a 10-stud
-- CFrame jump was reverted). A pull-back (the body 10+ studs off the line we wrote, 3 frames running) lowers
-- the speed for the rest of the session.
local glideSpeed = GLIDE_SPEED
local function glideTo(pos, stopped)
	local t0, last, pulled = os.clock(), nil, 0
	while os.clock() - t0 < GLIDE_CAP do
		if stopped and stopped() then
			return false, "stopped"
		end
		local dt = RunService.Heartbeat:Wait()
		local r = root()
		if not r then
			return false, "dead"
		end
		local cur = r.Position
		if last then
			pulled = (cur - last).Magnitude > 10 and pulled + 1 or 0
			if pulled >= 3 then
				glideSpeed = math.max(GLIDE_MIN, glideSpeed * 0.7)
				log("glide pulled back, speed now", math.floor(glideSpeed))
				return false, "pulled"
			end
		end
		local d = pos - cur
		if d.Magnitude < 3 then
			r.AssemblyLinearVelocity = Vector3.zero
			return true
		end
		local nxt = cur + d.Unit * math.min(d.Magnitude, glideSpeed * dt)
		r.CFrame = CFrame.new(nxt) * (r.CFrame - r.CFrame.Position)
		r.AssemblyLinearVelocity = Vector3.zero
		last = nxt
	end
	return false, "timeout"
end

-- One leg, no retries: a pull-back means the server is already correcting us, so the body rests PULL_REST
-- (inside the caller's claim, so no other errand moves it either) and the errand comes round on its next beat.
local function goTo(pos, stopped)
	local arrived, why = glideTo(pos, stopped)
	if why == "pulled" or why == "timeout" then
		task.wait(PULL_REST)
	end
	return arrived, why
end

-- The character belongs to one errand at a time. Returns whether fn ran, not whether it worked;
-- released on every path including a throw.
local busy = false
local function claim(fn)
	if busy then
		return false
	end
	busy = true
	local okRun, err = pcall(fn)
	busy = false
	if not okRun then
		warn("[fakeegg] errand threw:", err)
	end
	return true
end

-- loops -----------------------------------------------------------------------
-- One row per toggle; the generation counter lives in the row, so off-then-on inside a beat never leaves two threads.
local loops = {}
local function makeLoop(name, beat, body)
	local row = { on = false, gen = 0 }
	loops[name] = row
	row.set = function(on)
		row.gen += 1
		local mine = row.gen
		row.on = on
		if not on then
			return
		end
		local function alive()
			return row.on and row.gen == mine
		end
		task.spawn(function()
			while alive() do
				local good, err = pcall(body, alive)
				if not good then
					warn("[fakeegg] " .. name .. " pass threw:", err)
				end
				task.wait(beat)
			end
		end)
	end
	return row
end

local stats = { grabbed = 0, refused = 0, hatched = 0, fed = 0, bought = 0 }

-- grab ------------------------------------------------------------------------
local rarityOn = {}
local RARITY_ORDER = {}
do
	local seenR = {}
	for _, cfg in pairs(Eggs.ByName) do
		if cfg.rarityType and not seenR[cfg.rarityType] then
			seenR[cfg.rarityType] = true
			RARITY_ORDER[#RARITY_ORDER + 1] = cfg.rarityType
		end
	end
	-- cheapest rarity first, by the cheapest egg of each
	local low = {}
	for _, cfg in pairs(Eggs.ByName) do
		low[cfg.rarityType] = math.min(low[cfg.rarityType] or math.huge, cfg.price or math.huge)
	end
	table.sort(RARITY_ORDER, function(a, b)
		return low[a] < low[b]
	end)
end

local maxPct = 100 -- an egg may cost at most this % of your cash
local skipFakes = true
local bench = {} -- egg model -> os.clock() it may be tried again

local function disguisedSpots()
	local spots = {}
	for _, pl in ipairs(Players:GetPlayers()) do
		local c = pl ~= player and pl:GetAttribute("Disguised") and pl.Character
		local r = c and c:FindFirstChild("HumanoidRootPart")
		if r then
			spots[#spots + 1] = r.Position
		end
	end
	return spots
end

local function isFake(pos, spots)
	for _, s in ipairs(spots) do
		if Vector3.new(pos.X - s.X, 0, pos.Z - s.Z).Magnitude < FAKE_RADIUS then
			return true
		end
	end
	return false
end
assert(isFake(Vector3.new(0, 10, 0), { Vector3.new(3, 13, 1) }) and not isFake(Vector3.new(0, 10, 0), { Vector3.new(20, 13, 0) }), "isFake")

-- live Price (the server re-sends it when an admin halves prices) over the config price
local function eggPrice(m)
	local cfg = Eggs.ByName[m:GetAttribute("BaseName") or m.Name]
	return m:GetAttribute("Price") or (cfg and cfg.price), cfg
end

local function pickEgg()
	local folder = workspace:FindFirstChild("ClientEggs")
	if not folder then
		return nil, "no ClientEggs"
	end
	local now, clock = workspace:GetServerTimeNow(), os.clock()
	local spots = skipFakes and disguisedSpots() or {}
	local budget = cash.Value * maxPct / 100
	local best, bestPrice, fakes, poor = nil, -1, 0, 0
	for _, m in ipairs(folder:GetChildren()) do
		if m:GetAttribute("IsEgg") and (bench[m] or 0) < clock then
			local price, cfg = eggPrice(m)
			local landed = (m:GetAttribute("LandT") or math.huge) <= now
			local fresh = (m:GetAttribute("CountdownEnd") or 0) > now + EXPIRE_MARGIN
			if price and cfg and landed and fresh and rarityOn[cfg.rarityType] then
				if isFake(m:GetPivot().Position, spots) then
					fakes += 1
				elseif price > budget then
					poor += 1
				elseif price > bestPrice then
					best, bestPrice = m, price
				end
			end
		end
	end
	if not best then
		return nil, ("no egg (%d fake, %d too dear)"):format(fakes, poor)
	end
	return best, bestPrice
end

-- Fire the egg's own BuyPrompt handler: it builds the Buy call with the egg's id, which lives only in the
-- Eggs controller's local table. It scans instead of buying while a scanner is held, so nothing is held.
local function pressBuy(m)
	local prompt = m:FindFirstChild("BuyPrompt", true)
	if not prompt then
		return false
	end
	local fired = false
	for _, c in ipairs(getconnections(prompt.Triggered)) do
		if c.Function then
			pcall(c.Function)
			fired = true
		end
	end
	return fired
end

local function carrying()
	return player:GetAttribute("Carrying")
end

-- The middle of the base's Collect volume, at standing height. The Spawn pad sits just OUTSIDE it: landing there
-- cleared Carrying too, but the egg went back to the floor instead of into a nest (4 trips, 0 nests filled).
local function homeSpot()
	local b = myBase()
	local c = b and b:FindFirstChild("Collect")
	local s = b and b:FindFirstChild("Spawn")
	return c and s and Vector3.new(c.Position.X, s.Position.Y + 3, c.Position.Z)
end

local function eggsInNests()
	local n = 0
	for _, nest in ipairs(nestData:GetChildren()) do
		if nest:GetAttribute("Egg") then
			n += 1
		end
	end
	return n
end

-- true only when a nest took the egg; Carrying clearing alone also happens when the egg is dropped
local function bankHome(alive)
	local home = homeSpot()
	if not home then
		return false
	end
	local before = eggsInNests()
	goTo(home, function()
		return not alive()
	end)
	local t0 = os.clock()
	while (carrying() or eggsInNests() <= before) and os.clock() - t0 < BANK_CONFIRM do
		task.wait(0.1)
	end
	return eggsInNests() > before
end

local grab = makeLoop("grab", GRAB_BEAT, function(alive)
	if busy then
		return
	end
	if carrying() then
		claim(function()
			say("carrying " .. tostring(carrying()) .. ", going home")
			bankHome(alive)
		end)
		return
	end
	if (player:GetAttribute("FreeNests") or 0) <= 0 then
		say("every nest is full")
		return
	end
	local m, price = pickEgg()
	if not m then
		say(price)
		return
	end
	claim(function()
		local name = m:GetAttribute("BaseName") or m.Name
		local variant = m:GetAttribute("Variant")
		say(("grab %s%s for %s"):format(variant and (variant .. " ") or "", name, fmt(price)))
		local stopped = function()
			return not alive() or not m.Parent
		end
		if not goTo(m:GetPivot().Position + Vector3.new(0, 3, 0), stopped) then
			bench[m] = os.clock() + EGG_BENCH
			return
		end
		local t0 = os.clock()
		while not carrying() and m.Parent and os.clock() - t0 < BUY_CONFIRM do
			local r = root()
			if r then -- eggs hop around; stay on top of it
				r.CFrame = CFrame.new(m:GetPivot().Position + Vector3.new(0, 3, 0)) * (r.CFrame - r.CFrame.Position)
			end
			if not pressBuy(m) then
				first("no-prompt", name)
				break
			end
			task.wait(BUY_GAP)
		end
		if not carrying() then
			stats.refused += 1
			bench[m] = os.clock() + EGG_BENCH
			log(("refused %s for %s (cash %s, egg %s)"):format(name, fmt(price), fmt(cash.Value), m.Parent and "still there" or "gone"))
			return
		end
		stats.bought += 1
		if bankHome(alive) then
			stats.grabbed += 1
			log(("banked %s%s (%s), %d grabbed"):format(variant and (variant .. " ") or "", name, fmt(price), stats.grabbed))
		else
			log(("WARN %s not banked (carrying %s, nests %d)"):format(name, tostring(carrying()), eggsInNests()))
		end
	end)
end)

-- hatch -----------------------------------------------------------------------
local nestBench = {}
local hatch = makeLoop("hatch", HATCH_BEAT, function(alive)
	local now = workspace:GetServerTimeNow()
	local ready = {}
	for _, n in ipairs(nestData:GetChildren()) do
		if n:GetAttribute("Egg") and (n:GetAttribute("HatchAt") or math.huge) <= now and (nestBench[n.Name] or 0) < os.clock() then
			ready[#ready + 1] = n
		end
	end
	if #ready == 0 then
		return
	end
	local b = myBase()
	local models = b and b:FindFirstChild("Nests")
	if not models then
		return
	end
	claim(function()
		for _, n in ipairs(ready) do
			local model = models:FindFirstChild(n.Name)
			if not alive() or not model then
				break
			end
			local egg = n:GetAttribute("Egg")
			if goTo(model:GetPivot().Position + NEST_SIDE, function()
				return not alive()
			end) then
				OpenBlockEvent:FireServer(n.Name)
				local t0 = os.clock()
				while n:GetAttribute("Egg") and os.clock() - t0 < HATCH_CONFIRM do
					task.wait(0.1)
				end
				if n:GetAttribute("Egg") then
					nestBench[n.Name] = os.clock() + HATCH_BACKOFF
					log("hatch refused: nest " .. n.Name .. " " .. tostring(egg))
				else
					stats.hatched += 1
					say("hatched " .. tostring(egg))
				end
			end
		end
	end)
end)

-- place -----------------------------------------------------------------------
local function animalsInBag()
	local n = 0
	for _, t in ipairs(player.Backpack:GetChildren()) do
		if t:GetAttribute("IsAnimal") then
			n += 1
		end
	end
	return n
end

local lastBagSig
local place = makeLoop("place", EQUIP_GAP, function()
	-- only when the bag changed: Equip Best on a bag it already sorted is a no-op round trip
	local sig = animalsInBag() .. ":" .. stats.hatched
	if animalsInBag() > 0 and sig ~= lastBagSig then
		lastBagSig = sig
		EquipBestEvent:FireServer()
		first("equip-best", sig)
	end
end)

-- feed ------------------------------------------------------------------------
local foodOn = {}
local FOOD_NAMES = {}
for _, f in ipairs(Food.List) do
	FOOD_NAMES[#FOOD_NAMES + 1] = f.name
end

-- food Tools stack: one Tool per kind with a Count attribute
local function foodTools()
	local out, n = {}, 0
	for _, holder in ipairs({ player.Character, player.Backpack }) do
		for _, t in ipairs(holder and holder:GetChildren() or {}) do
			if t:IsA("Tool") and t:GetAttribute("IsFood") then
				out[#out + 1] = t
				n += t:GetAttribute("Count") or 1
			end
		end
	end
	return out, n
end

local function foodInBag()
	local _, n = foodTools()
	return n
end

local feedBackoff = 0
local feed = makeLoop("feed", FEED_BEAT, function(alive)
	for _, f in ipairs(Food.List) do
		if
			foodOn[f.name]
			and foodInBag() < FOOD_KEEP
			and Food.unlocked(player, f)
			and Food.stock(player, f.name) > 0
			and cash.Value >= f.price
		then
			FoodEvent:FireServer("Buy", f.name)
			log("bought food " .. f.name .. " for " .. fmt(f.price))
			task.wait(0.4)
		end
	end
	if foodInBag() == 0 or os.clock() < feedBackoff then
		return
	end
	local anchor = workspace:FindFirstChild("FeederClient")
	anchor = anchor and anchor:FindFirstChild("FeederAnchor")
	if not anchor then
		first("no-feeder")
		return
	end
	claim(function()
		say("filling the feeder")
		if not goTo(anchor.Position + Vector3.new(0, 3, 5), function()
			return not alive()
		end) then
			return
		end
		-- The server fills with what is in hand (an animal held = nothing taken), and an accepted Fill rewrites
		-- FeederUpdated: that is the confirm, not the bag, whose stacks hide a single eaten item.
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		while alive() and hum do
			local tools = foodTools()
			if #tools == 0 then
				break
			end
			pcall(hum.EquipTool, hum, tools[1])
			task.wait(0.2)
			local before = player:GetAttribute("FeederUpdated")
			FoodEvent:FireServer("Fill")
			local t0 = os.clock()
			while player:GetAttribute("FeederUpdated") == before and os.clock() - t0 < 1.5 do
				task.wait(0.1)
			end
			if player:GetAttribute("FeederUpdated") == before then
				feedBackoff = os.clock() + FEED_BACKOFF
				log("feeder took nothing, calories " .. math.floor(Food.calories(player)))
				break
			end
			stats.fed += 1
			say("fed " .. tools[1].Name .. ", calories " .. math.floor(Food.calories(player)))
			task.wait(FILL_GAP)
		end
		pcall(hum.UnequipTools, hum)
	end)
end)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Fake an Egg", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "egg")
local EggBox = Tab:AddLeftGroupbox("Eggs", "egg")
local HomeBox = Tab:AddRightGroupbox("Base", "house")
local FeedBox = Tab:AddRightGroupbox("Feeder", "carrot")

EggBox:AddToggle("Grab", {
	Text = "Auto Grab Eggs",
	Tooltip = "Glides to the best real egg you can pay for, buys it and glides home; the server puts it in a free nest",
	Default = false,
	Callback = grab.set,
})
EggBox:AddToggle("SkipFakes", {
	Text = "Skip disguised players",
	Tooltip = "An egg with a disguised player sitting in it is a fake: never buy it",
	Default = true,
	Callback = function(v)
		skipFakes = v
	end,
})
EggBox:AddDropdown("Rarities", {
	Text = "Rarities to grab",
	Tooltip = "Among these, the most expensive egg you can pay for is grabbed first",
	Values = RARITY_ORDER,
	Default = RARITY_ORDER,
	Multi = true,
	Callback = function(picked)
		table.clear(rarityOn)
		for r in pairs(ticked(picked)) do
			rarityOn[r] = true
		end
	end,
})
for _, r in ipairs(RARITY_ORDER) do
	rarityOn[r] = true -- Default does not fire the callback, so arm by hand
end
EggBox:AddInput("MaxPct", {
	Text = "Max % of cash per egg",
	Default = tostring(maxPct),
	Numeric = true,
	Finished = true,
	Callback = function(text)
		maxPct = math.clamp(tonumber(text) or maxPct, 1, 100)
	end,
})

HomeBox:AddToggle("Hatch", {
	Text = "Auto Hatch",
	Tooltip = "Opens each nest the moment its timer is up (glides beside it: the server wants you close)",
	Default = false,
	Callback = hatch.set,
})
HomeBox:AddToggle("Place", {
	Text = "Auto Place Animals",
	Tooltip = "The game's Equip Best whenever a hatched animal is in your bag",
	Default = false,
	Callback = place.set,
})

FeedBox:AddToggle("Feed", {
	Text = "Auto Buy Feed + Fill",
	Tooltip = "Buys the ticked foods while the shop has stock and you can pay, then fills your feeder",
	Default = false,
	Callback = feed.set,
})
FeedBox:AddDropdown("Foods", {
	Text = "Foods to buy",
	Tooltip = "Locked foods (rebirths) are skipped until you unlock them",
	Values = FOOD_NAMES,
	Default = FOOD_NAMES,
	Multi = true,
	Callback = function(picked)
		table.clear(foodOn)
		for f in pairs(ticked(picked)) do
			foodOn[f] = true
		end
	end,
})
for _, f in ipairs(FOOD_NAMES) do
	foodOn[f] = true
end

local conns = {}
local nextStrip = 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	local used = 0
	for _, n in ipairs(nestData:GetChildren()) do
		if n:GetAttribute("Egg") then
			used += 1
		end
	end
	pcall(Window.SetStatus, Window, {
		{ "Cash", fmt(cash.Value) },
		{ "Nests", used .. " busy, " .. tostring(player:GetAttribute("FreeNests")) .. " free" },
		{ "Grabbed", stats.grabbed .. (stats.refused > 0 and (" (" .. stats.refused .. " refused)") or "") },
		{ "Hatched", stats.hatched },
		{ "Fed", stats.fed },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- last, so the autoload finds every control
Window:AddSettingsTab("FakeAnEgg", {})

-- close ----------------------------------------------------------------------
local function stopAll()
	for _, row in pairs(loops) do
		row.set(false)
	end
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().fakeEggStop = nil
end)

getgenv().fakeEggStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().fakeEggStop = nil
end
