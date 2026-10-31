--[[ Cut a Rock -- glide to the deepest room, fill the pocket with its best rocks, Home, sell, upgrade (113742027864370)

     FARM    : glides to the room picked in the dropdown (default Room 39, Supreme rocks) at ~2500 studs/s,
               grabs the best veins first and, if the pocket still has room, carries on one room up at a time.
               Then Home the way the game's Q button does it (its own TeleportTargets.TryLocal + BaseaIsinlanEvent),
               which empties the pocket into the backpack. A trip is a few seconds.
               The server does not gate a room by depth: MaximumRoom 4 grabbed in Room 10 and Room 39 (probed).
               Veins come back on their own (all enabled again a few minutes later), so the deepest room stays best.
     SELL    : SellEvent("SellAll") whenever the backpack holds something. Position-free (paid from 137 studs, probed).
               Every sale is x2 on this account (the reply's carpan). Rocks sitting in a machine are not in the backpack.
     UPGRADE : cheapest affordable first, across: Pocket (more rocks per trip), each owned machine's level
               (cut time / 5 per level), Eyesight. All remotes, nothing walks.
     PICKAXE : buys the best money pickaxe you can afford that beats the best one you own (buying equips it),
               then equips the best owned. Limited / Robux pickaxes are never touched.

     Movement (Z.moves 2026-11-01): a CFrame jump is undone (5 studs reverted), a glide held at 220 studs/s and later
     at 600 / 1500 / 3000 studs/s over 1500-2400 studs. The landing is the room floor (centre - 16) so you don't fall.
     Grab range: the server took a vein 25 studs away and refused 36, so most of a room is reached from its centre.
     fireproximityprompt skips the 0.75s hold. The core inside a rock is rolled at pickup (MalzemeAdi).
     Measured 2026-11-01, pocket 18-19: a trip is ~7s (Room 39 then 38, ~0.25s a grab, Home 0.3s), ~745Qi a minute
     with Sell on. Hand play from Room 2 had this account at 2.4K. Survives a death mid-trip and a full backpack.

     Probed and dead: InstantCutEvent "buy" / InstantBreakEvent "buy" are Robux (dev products). A cut has no free skip,
     only machine levels. PickaxeRobuxEvent, LimitedSatinAl, StarterPackSatinAl, DoublePowerSatinAl: Robux, unwired.
     Machine collect is range-gated (18 studs ok, 27 refused); auto cut was left out: +~5% on top of raw selling.
     Batch pickup: 4 veins fired together, 1 taken, so grabs stay one at a time.

     RightControl opens / closes the panel (so does the Zegion logo).
     Stop: getgenv().cutRockStop() ]]

-- config ---------------------------------------------------------------------
local GLIDE_SPEED = 2500 -- studs/s. 3000 held over 2400 studs; lower it if trips start landing short
local GLIDE_SLOW = 400 -- a leg that did not arrive is flown again at this speed
local ARRIVE = 25 -- a glide that ends this close counts as arrived (it is also the grab range)
local FLOOR_DROP = 16 -- a room's CenterPosition is this far above where you stand on its floor
local GRAB_RANGE = 22 -- veins further than this get a short glide first. The server took 25 and refused 36
local GRAB_OFFSET = 6 -- that glide stops this far from the vein, towards the room centre, so you don't land in the mesh
local GRAB_WAIT = 1.5 -- a pickup must show up in the pocket inside this
local PRESS_GAP = 0.05 -- between prompt fires while waiting for one pickup (a pickup lands in ~0.15s)
local STREAM_WAIT = 4 -- a room you just arrived at streams its veins in; wait at most this long
local MAX_ROOMS = 6 -- a trip tries at most this many rooms (the picked one, then upward) to fill the pocket
local HOME_WAIT = 4 -- after Home, the pocket must empty into the backpack inside this
local BAG_ROOM = 200 -- the backpack's cap (CantaAyarlari.KAPASITE); read live when it can be
local SELL_EVERY = 1 -- how often Auto Sell looks at the backpack
local UPGRADE_EVERY = 1 -- between upgrade passes
local STUCK_AFTER = 30 -- the watchdog says "stuck" when one step lasts longer than this

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().cutRockStop then
	getgenv().cutRockStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[cutrock]", ...)
end

-- Drained from a Heartbeat: a loop thread that writes to the window throws "lacking capability Plugin".
local pending, lastSaid = nil, nil
local function say(msg)
	pending = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- game -----------------------------------------------------------------------
local RockList = require(ReplicatedStorage:WaitForChild("ARockList"))
local UpgradePrice = require(ReplicatedStorage:WaitForChild("UpgradePrice"))
local MachineData = require(ReplicatedStorage:WaitForChild("MachineLevelData"))
local PickaxeList = require(ReplicatedStorage:WaitForChild("PickaxeList"))
local TeleportTargets = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TeleportTargets"))
local okFmt, FormatNumber = pcall(require, ReplicatedStorage:FindFirstChild("FormatNumber"))

local SellEvent = ReplicatedStorage:WaitForChild("SellEvent")
local HomeEvent = ReplicatedStorage:WaitForChild("BaseaIsinlanEvent")
local UpgradeEvent = ReplicatedStorage:WaitForChild("UpgradeEvent")
local LevelUpMachineEvent = ReplicatedStorage:WaitForChild("LevelUpMachineEvent")
local PickaxeBuyEvent = ReplicatedStorage:WaitForChild("PickaxeBuyEvent")
local PickaxeEquipEvent = ReplicatedStorage:WaitForChild("PickaxeEquipEvent")

local Cep = player:WaitForChild("Cep") -- the pocket: what a trip carries
local Envanter = player:WaitForChild("Envanter") -- the backpack: where Home puts it, what Sell sells
local money = player:WaitForChild("Statlar"):WaitForChild("Money")
local owned = player:WaitForChild("KazmaSahipligi") -- pickaxe levels owned, one child per level
local Rooms = workspace:WaitForChild("Rooms")

local function fmt(n)
	if okFmt and FormatNumber then
		local ok, s = pcall(FormatNumber.format_number, n)
		if ok then
			return s
		end
	end
	return tostring(math.floor(n))
end

-- rarity -> rank by raw price (ARockList order is cheapest first). Limited rocks share a rarity name's slot by price.
local rankOf = {}
for _, r in ipairs(RockList.All) do
	rankOf[r.Name] = r.Price
end
assert((rankOf.Supreme or 0) > (rankOf.Mythic or 0) and (rankOf.Mythic or 0) > (rankOf.Common or 0), "rarity rank order")

local function pocketCap()
	return (player:GetAttribute("PocketLevel") or 1) + (player:GetAttribute("is_bought_bag_bonus") == true and 1 or 0)
end
local function bagCap()
	return Envanter:GetAttribute("Kapasite") or BAG_ROOM
end
-- items the game counts: one being deleted carries _SilinmeBekliyor
local function count(folder)
	local n = 0
	for _, c in ipairs(folder:GetChildren()) do
		if c:GetAttribute("_SilinmeBekliyor") ~= true then
			n += c:GetAttribute("Agirlik") or 1
		end
	end
	return n
end

local function myBase()
	local bases = workspace:FindFirstChild("Models") and workspace.Models:FindFirstChild("Bases")
	for _, b in ipairs(bases and bases:GetChildren() or {}) do
		if b:GetAttribute("OwnerUserId") == player.UserId then
			return b
		end
	end
	return nil
end

local function root()
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	if not (hum and hum.Health > 0) then
		return nil
	end
	return ch:FindFirstChild("HumanoidRootPart")
end

-- breadcrumb + watchdog ------------------------------------------------------
local crumb, crumbAt = "idle", os.clock()
local function step(name)
	crumb, crumbAt = name, os.clock()
end

-- travel ---------------------------------------------------------------------
-- A jump is undone by the server, a glide is not: lerp the root along the line every Heartbeat with the velocity
-- zeroed, so gravity can't pull it off. Judged on where you end up, never on the loop finishing.
local function glide(pos, speed, alive)
	local r = root()
	if not r then
		return false
	end
	local from = r.Position
	local total = (pos - from).Magnitude
	local done = 0
	while done < total and alive() do
		local dt = RunService.Heartbeat:Wait()
		r = root()
		if not r then
			return false
		end
		done = math.min(total, done + speed * dt)
		r.CFrame = CFrame.new(from:Lerp(pos, total > 0 and done / total or 1))
		r.AssemblyLinearVelocity = Vector3.zero
	end
	r = root()
	return r ~= nil and (r.Position - pos).Magnitude < ARRIVE
end

local function travel(pos, alive)
	if glide(pos, GLIDE_SPEED, alive) then
		return true
	end
	return alive() and glide(pos, GLIDE_SLOW, alive)
end

-- The game's own Home (Q): it pivots you itself and tells the server, which keeps the move.
local function goHome()
	local ch, base = player.Character, myBase()
	if not (ch and base) then
		return false
	end
	local ok = TeleportTargets.TryLocal(ch, TeleportTargets.BaseEntryCFrame(base, ch))
	HomeEvent:FireServer(ok)
	local dl = os.clock() + HOME_WAIT
	while count(Cep) > 0 and os.clock() < dl do
		task.wait(0.1)
	end
	return count(Cep) == 0
end

-- farm -----------------------------------------------------------------------
local farm = { on = false, gen = 0, room = 39 }
local stats = { trips = 0, rocks = 0, sold = 0, earned = 0, ups = 0, picks = 0, startMoney = 0, startAt = os.clock() }

local function veinsIn(room)
	local out = {}
	local rocks = room:FindFirstChild("Rocks")
	for _, v in ipairs(rocks and rocks:GetChildren() or {}) do
		local pr = v:FindFirstChildWhichIsA("ProximityPrompt", true)
		if pr and pr.Enabled and pr.Parent:IsA("BasePart") then
			out[#out + 1] = { model = v, prompt = pr, part = pr.Parent, value = rankOf[v:GetAttribute("Rarity")] or 0 }
		end
	end
	table.sort(out, function(a, b)
		return a.value > b.value
	end)
	return out, rocks and #rocks:GetChildren() or 0
end

local function grab(v, floorY, centre, alive)
	local r = root()
	if not r then
		return false
	end
	if (v.part.Position - r.Position).Magnitude > GRAB_RANGE then
		local flat = Vector3.new(centre.X - v.part.Position.X, 0, centre.Z - v.part.Position.Z)
		local spot = Vector3.new(v.part.Position.X, floorY, v.part.Position.Z)
			+ (flat.Magnitude > 0 and flat.Unit * GRAB_OFFSET or Vector3.zero)
		if not travel(spot, alive) then
			return false
		end
	end
	local n0 = Cep:GetChildren()
	local dl = os.clock() + GRAB_WAIT
	repeat
		pcall(fireproximityprompt, v.prompt)
		task.wait(PRESS_GAP)
	until #Cep:GetChildren() > #n0 or os.clock() > dl or not alive()
	return #Cep:GetChildren() > #n0
end

local function trip(alive)
	local t0 = os.clock()
	local cap = pocketCap()
	local roomNo = farm.room
	for _ = 1, MAX_ROOMS do
		if count(Cep) >= cap or roomNo < 0 or not alive() then
			break
		end
		local room = Rooms:FindFirstChild("Room_" .. roomNo)
		local centre = room and room:GetAttribute("CenterPosition")
		if centre then
			local floorY = centre.Y - FLOOR_DROP
			step("glide to Room " .. roomNo)
			if travel(Vector3.new(centre.X, floorY, centre.Z), alive) then
				step("stream Room " .. roomNo)
				local veins, total = veinsIn(room)
				local dl = os.clock() + STREAM_WAIT
				while #veins < total and os.clock() < dl and alive() do
					task.wait(0.2)
					veins, total = veinsIn(room)
				end
				-- one at a time: fired at 4 veins together, the server took 1 (probed)
				for _, v in ipairs(veins) do
					if count(Cep) >= cap or not alive() then
						break
					end
					step("grab " .. tostring(v.model:GetAttribute("Rarity")) .. " in Room " .. roomNo)
					if grab(v, floorY, centre, alive) then
						stats.rocks += 1
					end
				end
			else
				say(("glide to Room %d did not arrive"):format(roomNo))
			end
		end
		roomNo -= 1
	end
	if count(Cep) == 0 then
		return false
	end
	step("home")
	local got, tHome = count(Cep), os.clock()
	if not goHome() then
		say("Home did not empty the pocket (backpack full?)")
		return false
	end
	stats.trips += 1
	say(("trip %d: %d rocks home in %.1fs (home %.1fs), bag %d/%d"):format(
		stats.trips,
		got,
		os.clock() - t0,
		os.clock() - tHome,
		count(Envanter),
		bagCap()
	))
	return true
end

local function setFarm(state)
	farm.on = state
	farm.gen += 1
	local mine = farm.gen
	if not state then
		step("idle")
		say("farm off")
		return
	end
	local function alive()
		return farm.on and farm.gen == mine
	end
	task.spawn(function()
		while alive() do
			if count(Envanter) + pocketCap() > bagCap() then
				step("bag full")
				say("backpack full: turn on Auto Sell or sell by hand")
				task.wait(1)
			elseif root() == nil then
				step("respawn")
				task.wait(1)
			else
				local ok, err = pcall(trip, alive)
				if not ok then
					say("trip error: " .. tostring(err))
					task.wait(1)
				elseif not err then
					task.wait(0.5)
				end
			end
			task.wait()
		end
	end)
end

-- sell -----------------------------------------------------------------------
local sell = { on = false, gen = 0 }
local sellCon = SellEvent.OnClientEvent:Connect(function(kind, info)
	if kind == "Satildi" and type(info) == "table" then
		stats.sold += info.adet or 0
		stats.earned += info.kazanc or 0
	end
end)

local function setSell(state)
	sell.on = state
	sell.gen += 1
	local mine = sell.gen
	if not state then
		return
	end
	task.spawn(function()
		while sell.on and sell.gen == mine do
			if count(Envanter) > 0 then
				pcall(SellEvent.FireServer, SellEvent, "SellAll")
			end
			task.wait(SELL_EVERY)
		end
	end)
end

-- upgrade --------------------------------------------------------------------
local up = { on = false, gen = 0, seq = 0 }

-- owned machines: their CutMachinePrompt is enabled (locked / unbought slots keep it off)
local function machines()
	local out, base = {}, myBase()
	for _, d in ipairs(base and base:GetDescendants() or {}) do
		if d:IsA("ProximityPrompt") and d.Name == "CutMachinePrompt" and d.Enabled then
			local node = d:FindFirstChild("MakineNode")
			if node and node.Value then
				out[#out + 1] = node.Value
			end
		end
	end
	return out
end

-- every upgrade on offer: { name, cost, buy }; the pass buys the cheapest affordable one
local function offers()
	local list = {}
	local pocket = player:GetAttribute("PocketLevel") or 1
	local pc = UpgradePrice.pocket_price[pocket + 1]
	if pc then
		list[#list + 1] = { "Pocket " .. (pocket + 1), pc, function(seq)
			UpgradeEvent:FireServer("Pocket", seq)
		end }
	end
	local sight = player:GetAttribute("Sight") or 1
	local sc = UpgradePrice.sight_price[sight + 1]
	if sc then
		list[#list + 1] = { "Eyesight " .. (sight + 1), sc, function(seq)
			UpgradeEvent:FireServer("Eyesight", seq)
		end }
	end
	for _, m in ipairs(machines()) do
		local lvl = m:GetAttribute("Seviye") or 1
		local cost = m:GetAttribute("SonrakiSeviyeFiyati") or MachineData.Fiyatlar[lvl + 1]
		if cost and lvl < (MachineData.MaksSeviye or 20) then
			list[#list + 1] = { ("Machine %s L%d"):format(tostring(m:GetAttribute("YuvaNo")), lvl + 1), cost, function(seq)
				LevelUpMachineEvent:FireServer(m, seq)
			end }
		end
	end
	table.sort(list, function(a, b)
		return a[2] < b[2]
	end)
	return list
end

local function setUpgrade(state)
	up.on = state
	up.gen += 1
	local mine = up.gen
	if not state then
		return
	end
	task.spawn(function()
		while up.on and up.gen == mine do
			local o = offers()[1]
			if o and o[2] <= money.Value then
				up.seq += 1
				local ok = pcall(o[3], up.seq)
				if ok then
					stats.ups += 1
					say(("bought %s for %s"):format(o[1], fmt(o[2])))
				end
				task.wait(0.3) -- let the attribute land before pricing the next level
			else
				task.wait(UPGRADE_EVERY)
			end
		end
	end)
end

-- pickaxe --------------------------------------------------------------------
local pick = { on = false, gen = 0, seq = 0 }

local function bestOwned()
	local best = 0
	for _, c in ipairs(owned:GetChildren()) do
		best = math.max(best, tonumber(c.Name) or 0)
	end
	return best
end

local function setPick(state)
	pick.on = state
	pick.gen += 1
	local mine = pick.gen
	if not state then
		return
	end
	task.spawn(function()
		while pick.on and pick.gen == mine do
			local best = bestOwned()
			local target
			for _, p in ipairs(PickaxeList.Normal) do
				if p.Seviye > best and (p.Price or 0) > 0 and p.Price <= money.Value then
					if not target or p.Seviye > target.Seviye then
						target = p
					end
				end
			end
			if target then
				pcall(PickaxeBuyEvent.FireServer, PickaxeBuyEvent, target.Seviye)
				local dl = os.clock() + 2
				while not owned:FindFirstChild(tostring(target.Seviye)) and os.clock() < dl do
					task.wait(0.1)
				end
				if owned:FindFirstChild(tostring(target.Seviye)) then
					stats.picks += 1
					say(("bought pickaxe %s for %s"):format(target.Name, fmt(target.Price)))
				end
			end
			-- buying equips what was bought; make sure the best owned is the one in hand
			best = bestOwned()
			if player:GetAttribute("KusanilanKazma") ~= best and best > 0 then
				pick.seq += 1
				pcall(PickaxeEquipEvent.FireServer, PickaxeEquipEvent, best, pick.seq)
			end
			task.wait(UPGRADE_EVERY)
		end
	end)
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Cut a Rock", statusBar = true })
if not Window then
	sellCon:Disconnect()
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "pickaxe")
local Farm = Tab:AddLeftGroupbox("Rooms", "gem")
local Shop = Tab:AddRightGroupbox("Sell & upgrade", "trending-up")

-- one label per room, deepest first, with the rarities seen there when the panel was built
local roomValues, roomByLabel = {}, {}
local deepest = 0
for _, r in ipairs(Rooms:GetChildren()) do
	local n = tonumber(r.Name:match("^Room_(%d+)$"))
	if n then
		deepest = math.max(deepest, n)
	end
end
for n = deepest, 0, -1 do
	local room = Rooms:FindFirstChild("Room_" .. n)
	local best, bv = nil, -1
	for _, v in ipairs(room and room:FindFirstChild("Rocks") and room.Rocks:GetChildren() or {}) do
		local rar = v:GetAttribute("Rarity")
		if rar and (rankOf[rar] or 0) > bv then
			best, bv = rar, rankOf[rar] or 0
		end
	end
	local label = ("Room %d%s"):format(n, best and (" (" .. best .. ")") or "")
	roomValues[#roomValues + 1] = label
	roomByLabel[label] = n
end
farm.room = deepest

Farm:AddDropdown("Room", {
	Text = "Room",
	Tooltip = "Where a trip starts. Deepest = best rocks. If the pocket isn't full after it, the trip carries on one room up",
	Values = roomValues,
	Default = roomValues[1],
	Callback = function(label)
		farm.room = roomByLabel[label] or farm.room
	end,
})
Farm:AddToggle("Farm", {
	Text = "Auto Farm Rooms",
	Tooltip = "Glide to the room, grab the best rocks until the pocket is full, then Home (Q). Repeats",
	Default = false,
	Callback = function(state)
		local ok, err = pcall(setFarm, state)
		if not ok then
			say("farm failed to start: " .. tostring(err))
		end
	end,
})
Farm:AddButton({
	Text = "Home now",
	Func = function()
		task.spawn(goHome)
	end,
})
Shop:AddToggle("Sell", {
	Text = "Auto Sell",
	Tooltip = "Sells the whole backpack (the game's Sell All) whenever it holds something. Works from anywhere. Locked rocks and rocks in a machine stay",
	Default = false,
	Callback = setSell,
})
Shop:AddToggle("Upgrade", {
	Text = "Auto Upgrade",
	Tooltip = "Buys the cheapest affordable of: next Pocket level, next level of each machine you own, next Eyesight",
	Default = false,
	Callback = setUpgrade,
})
Shop:AddToggle("Pickaxe", {
	Text = "Auto Buy Pickaxe",
	Tooltip = "Buys the best money pickaxe you can afford that beats yours and keeps the best one equipped. Robux and Limited pickaxes are never bought",
	Default = false,
	Callback = setPick,
})

local conns = { sellCon }
local note, nextStrip = "idle", 0
stats.startMoney = money.Value
table.insert(conns, RunService.Heartbeat:Connect(function()
	if pending then
		note, pending = pending, nil
	end
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	if farm.on and now - crumbAt > STUCK_AFTER then
		crumbAt = now
		log("WARN stuck at: " .. crumb)
	end
	local mins = math.max((now - stats.startAt) / 60, 1 / 60)
	pcall(Window.SetStatus, Window, {
		{ "Cash", fmt(money.Value) },
		{ "/min", fmt(stats.earned / mins) },
		{ "Pocket", ("%d/%d"):format(count(Cep), pocketCap()) },
		{ "Bag", ("%d/%d"):format(count(Envanter), bagCap()) },
		{ "Trips", stats.trips },
		{ "Sold", stats.sold },
		{ "Now", farm.on and crumb or note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("CutARock", {})

local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- close ----------------------------------------------------------------------
local function stopAll()
	setFarm(false)
	setSell(false)
	setUpgrade(false)
	setPick(false)
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().cutRockStop = nil
end)

getgenv().cutRockStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().cutRockStop = nil
end
