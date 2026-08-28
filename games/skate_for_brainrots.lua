--[[ Skate for Brainrots -- Skate for a Brainrot (115852335239914)

     RARITY     : tick which rarities are worth picking up, and that's the whole farm.
                  All 11 zones are scanned, richest find first, and it only teleports
                  where one already is -- never on the chance something spawns. With
                  nothing matching anywhere it waits on your plot instead of in a zone,
                  which is what you want with only Exclusive/Celestial ticked.
     CAMP ZONES : optional, and the narrower mode. Tick zones and it stops hunting: it
                  works those HIGHEST FIRST, re-sweeping a zone that just paid out
                  before dropping to the next one down, and stands in the zone between
                  spawns rather than arriving after one. Worth it for volume on low
                  tiers where being present wins the race; wrong for anything rare,
                  which can spawn in any of the 11. Rarity still gates what it picks up.
     FARM ZONE  : TP into the zone, grab brainrots BEST FIRST until the carry won't take
                  another, then cross workspace.Line, which is what turns the stack on
                  your head into Tools in your Backpack. That's the bank.
     PLACE BEST : drains the Backpack into your plot. Best brainrot into the best empty
                  slot; once the unlocked slots are full it swaps out the worst one
                  placed, but only when the thing it's holding actually beats it.
     COLLECT    : touches the CollectTouch cash pad of every OCCUPIED slot on a 5s beat.
                  Fired through firetouchinterest, so it reaches all 7 floors without
                  moving you -- it costs nothing to leave on next to the farm.
     UPGRADE    : RequestSlotUpgrade over your occupied slots, best earner first, so the
                  server spends your cash where it compounds instead of on Floor1/Slot1.
     FLOORS     : RequestBaseUpgrade -- unlocks the next 10 slots. PLACE BEST is capped
                  by unlocked slots, so without this the placer runs out of room.
     CARRY      : PurchaseCarry -- +1 brainrot per round trip. The farm's multiplier.
     REBIRTH    : off by default, and leave it off while you're farming -- it wipes the
                  plot the moment the server accepts it.

     "Best" is income per second, worked out the way the game does it:

         ItemConfigurations.Items[name].Income * MUTATION_MULT[mut] * GROWTH^(Level-1)

     The mutation multipliers are read straight off the Earnings billboards in a dump
     against ItemConfigurations.Income -- Golden x2 (18 items agree), Diamond x3, Ruby
     x4. MutationConfigurations holds only colours, so there is no table to copy.
     Every brainrot in that dump was Level 1, so GROWTH is the one number nothing here
     pins down -- see the comment on it.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl hides/shows it. Stop: getgenv().skateRotsStop() ]]

-- config ---------------------------------------------------------------------
-- workspace.ItemSpawns.<n>, straight off a dump. Written down rather than read off the
-- parts so the panel has a fixed target even for a zone that hasn't replicated yet, and
-- so the list exists before the first scan does.
-- The tier note is what that zone was actually spawning in one dump: indicative, not a
-- rule the game enforces, so don't trust it further than picking a zone to tick.
local ZONES = {
	{ "1", Vector3.new(0, -0.17, 105.91), "Common" },
	{ "2", Vector3.new(0, 10.83, 245.91), "Common / Uncommon" },
	{ "3", Vector3.new(0, 40.44, 390.91), "Uncommon / Rare" },
	{ "4", Vector3.new(0, 84.44, 551.91), "Rare / Epic" },
	{ "5", Vector3.new(0, 163.70, 724.91), "Epic / Legendary" },
	{ "6", Vector3.new(0, 255.49, 930.90), "Legendary / Mythical" },
	{ "7", Vector3.new(0, 400.61, 1146.79), "Mythical / Secret" },
	{ "8", Vector3.new(0, 670.71, 1386.79), "Mythical / Godly" },
	{ "9", Vector3.new(0, 930.87, 1635.79), "Mythical / Secret" },
	{ "10", Vector3.new(0, 1675.76, 1911.79), "Secret / Godly" },
	{ "11", Vector3.new(0, 3293.18, 2289.66), "Secret / Godly" },
}
-- Empty on purpose: rarity alone already sweeps all 11, richest first. Ticking a zone
-- is the narrower mode -- camp there and re-sweep it -- so it shouldn't be the default.
local DEFAULT_ZONES = {}
local LIFT = 5 -- the anchor part sits under the floor; brainrots spawn about this high

-- Order 1-10 of ReplicatedStorage.Modules.RarityConfigurations, which is also ascending
-- income, so this doubles as the tier order.
local RARITIES =
	{ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical", "Secret", "Godly", "Exclusive", "Celestial" }

-- Derived from the Earnings billboards against ItemConfigurations.Income, all at Level 1.
-- Neon never appears in the dump: 5 continues the descending run of the other three in
-- the order MutationConfigurations lists them. If a Neon sorts wrong, fix it here.
local MUTATION_MULT = { Normal = 1, Golden = 2, Diamond = 3, Ruby = 4, Neon = 5 }

-- Income per level. Nothing in the client computes it and every brainrot in the dump was
-- Level 1, so there is nothing to derive it from -- this is the value that held in
-- wings_for_brainrots.lua. One upgraded brainrot's Earnings billboard pins it exactly:
-- divide what it reads by (Income * mutation) and take the (Level-1)th root.
local INCOME_GROWTH = 1.125

local SETTLE = 4 -- ping multiples to wait after a TP before trusting the new position;
-- raise it if grabs time out on a zone you've only just arrived at
local POLL = 0.2 -- beat between re-reads while waiting on the world
local DWELL = 1 -- seconds between sweeps of the same zone
local GRAB_TIMEOUT = 3 -- seconds of firing one Pick Up prompt before calling it refused
local GRAB_FAILS = 2 -- refusals in a row that mean the carry is full, not that we're
-- unlucky. There's no readable carry capacity anywhere, so a refused grab IS the check

-- workspace.Line sits at z = 45.87. Crossing it is what converts the stack on your head
-- into Backpack Tools, so the bank is two teleports: one either side of it.
-- ponytail: assumes the server decides by where you are, not by a Touched on the part.
-- If the stack never converts, walk the last leg instead -- Humanoid:MoveTo(LINE_CROSS)
-- from LINE_APPROACH and wait on MoveToFinished.
local LINE_APPROACH = Vector3.new(0, 6, 60)
local LINE_CROSS = Vector3.new(0, 6, 32)
local BANK_TIMEOUT = 8 -- seconds of re-crossing before giving up and saying so

local PLACE_TIMEOUT = 4 -- seconds firing a slot prompt before calling the placement dead
local PLACE_EVERY = 2 -- seconds between placement passes
local COLLECT_EVERY = 5 -- seconds between cash pad sweeps
local UPGRADE_EVERY = 1 -- seconds between upgrade rounds; the server refuses when broke
local FLOOR_EVERY = 5 -- seconds between floor unlock attempts; this one spends money
local CARRY_EVERY = 5 -- seconds between carry upgrade attempts; so does this one
local REBIRTH_EVERY = 5 -- seconds between rebirth attempts
local KEY_TOGGLE = Enum.KeyCode.RightControl

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
local ping = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]

if getgenv and getgenv().skateRotsStop then
	getgenv().skateRotsStop() -- re-running must not stack a second panel/loop
end

local Events = ReplicatedStorage:WaitForChild("Events")
local RequestSlotUpgrade = Events:WaitForChild("RequestSlotUpgrade")
local RequestBaseUpgrade = Events:WaitForChild("RequestBaseUpgrade")
local PurchaseCarry = Events:WaitForChild("PurchaseCarry")
local RequestRebirth = Events:WaitForChild("RequestRebirth")

-- The game's own income table and number formatter. Requiring beats copying: the item
-- list is 100+ entries and every update adds to it.
local itemConfigs, numbers
pcall(function()
	itemConfigs = require(ReplicatedStorage.Modules.ItemConfigurations)
	numbers = require(ReplicatedStorage.Modules.NumberFormatter)
end)

local say = function() end -- replaced by the panel below

local function money(n)
	return numbers and numbers.Format(n) or tostring(math.floor(n))
end

-- world ----------------------------------------------------------------------
local anchor, tierOf = {}, {}
for _, z in ipairs(ZONES) do
	anchor[z[1]] = z[2] + Vector3.new(0, LIFT, 0)
	tierOf[z[1]] = z[3]
end

local function hrp()
	local char = player.Character or player.CharacterAdded:Wait()
	return char:WaitForChild("HumanoidRootPart", 10)
end

-- Teleport is instant client-side; the server needs a round trip or two before it
-- agrees you're there, and streaming leaves you paused with nothing loaded around you.
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

local function zoneFolder(zone)
	local spawns = workspace:FindFirstChild("ItemSpawns")
	return spawns and spawns:FindFirstChild(zone)
end

-- The one client-side fact about the carry. There is no readable capacity anywhere --
-- the +1 Carry upgrade writes it server-side -- so this is deliberately a boolean:
-- "have I got anything to bank", never "how many more will fit". The game's own
-- DropController asks exactly this question the same way.
local function holding()
	local char = player.Character
	return char ~= nil and char:FindFirstChild("HeadStackItem") ~= nil
end

local function plot()
	return workspace:FindFirstChild("Plot_" .. player.Name)
end

-- Where the "TP to plot" button lands you, and where the hunt idles when nothing it
-- wants is out anywhere. False means the plot hasn't replicated yet -- the caller
-- retries rather than parking somewhere it didn't choose.
local function tpPlot()
	local mine = plot()
	if not mine then
		say("no plot found")
		return false
	end
	return tp(mine:GetPivot().Position + Vector3.new(0, 3, 0))
end

-- value ----------------------------------------------------------------------
-- Income per second, as the game computes it. Reads only attributes the server has
-- already written onto the model, and a world brainrot, a Backpack Tool and a placed
-- VisualItem carry the identical set -- so this one function scores all three.
-- Anything missing from ItemConfigurations scores 0 and sorts last rather than blocking
-- the sweep: a brainrot added by an update is still worth grabbing, just last.
local function worth(item)
	local data = itemConfigs and itemConfigs.GetItemData(item:GetAttribute("OriginalName") or item.Name)
	if not data or not data.Income then
		return 0
	end
	local level = item:GetAttribute("Level") or 1
	local mult = MUTATION_MULT[item:GetAttribute("Mutation") or "Normal"] or 1
	return data.Income * INCOME_GROWTH ^ (level - 1) * mult
end

-- Every slot on your plot, whether it's unlocked, and what's sat in it. Occupancy is
-- read as "is there a VisualItem" rather than off the prompt's IsOccupied attribute --
-- same answer, and it hands back the model the value comes from in the same pass.
local function slots()
	local mine = plot()
	if not mine then
		return {}
	end
	local out = {}
	for _, floor in ipairs(mine:GetChildren()) do
		if floor.Name:match("^Floor%d+$") then
			local list = floor:FindFirstChild("Slots")
			for _, slot in ipairs(list and list:GetChildren() or {}) do
				local spawn = slot:FindFirstChild("Spawn")
				local prompt = spawn and spawn:FindFirstChildWhichIsA("ProximityPrompt")
				if prompt then
					local item = spawn:FindFirstChild("VisualItem")
					table.insert(out, {
						floor = floor.Name,
						slot = slot.Name,
						prompt = prompt,
						at = spawn.Position,
						-- The cash pad. Every slot carries two of these: CollectTouch,
						-- the lit one with the running total on its CollectGUI and a
						-- TouchInterest under it, and CollectDark, the unlit backdrop
						-- with neither. Naming CollectTouch is the whole filter.
						pad = slot:FindFirstChild("CollectTouch"),
						unlocked = slot:GetAttribute("IsUnlocked") == true,
						item = item,
						worth = item and worth(item) or 0,
						-- GetChildren hands these back in creation order, which for a
						-- plot cloned from the template is Floor7,6,5,4,1,2,3 and
						-- Slot5,4,3,2,1,6... -- i.e. no order at all. Anything that
						-- wants "Floor1 Slot1 first" has to sort on this.
						order = (tonumber(floor.Name:match("%d+")) or 0) * 100
							+ (tonumber(slot.Name:match("%d+")) or 0),
					})
				end
			end
		end
	end
	return out
end

-- Banked brainrots. Crossing the line turns each one into a Tool with an OriginalName
-- attribute -- the plain Tools (RainbowCarpet and friends) have no such attribute, which
-- is the same test the game's own onboarding uses. The Character is checked too because
-- the one currently equipped lives there, not in the Backpack.
local function banked()
	local out = {}
	for _, src in ipairs({ player:FindFirstChild("Backpack"), player.Character }) do
		for _, tool in ipairs(src and src:GetChildren() or {}) do
			if tool:IsA("Tool") and tool:GetAttribute("OriginalName") then
				table.insert(out, { tool = tool, worth = worth(tool) })
			end
		end
	end
	return out
end

-- FARM and PLACE BEST both drive the character; let them run at once unclaimed and they
-- teleport each other mid-prompt and both time out. Taken per zone sweep and per place
-- pass, so the placer lands in the gap between two zones rather than being starved.
-- Returns whether it RAN, not whether it succeeded: a throw mid-sweep is the normal case
-- (brainrots vanish and indexing a dead model errors) and the caller should carry on,
-- while a refused claim means try the same thing again in a moment.
local busy = false

local function claim(fn)
	if busy then
		return false
	end
	busy = true
	local ok, err = pcall(fn)
	busy = false
	if not ok then
		warn("[skaterots]", err)
	end
	return true
end

-- farm -----------------------------------------------------------------------
local wanted = {} -- rarity -> true, live-read by the sweep

-- Best first. What the carry holds is small and unknowable, so the order here is the
-- whole farm: the difference between coming home with a Godly and coming home with
-- three Commons that happened to be nearer.
local function spawnedIn(fold)
	local out = {}
	for _, item in ipairs(fold:GetChildren()) do
		if item:GetAttribute("IsSpawnedItem") and wanted[item:GetAttribute("Rarity") or ""] then
			table.insert(out, { item = item, worth = worth(item) })
		end
	end
	-- Scored once up front, not inside the comparator: worth() reads three attributes and
	-- a sort calls its comparator far more often than it has elements.
	table.sort(out, function(a, b)
		return a.worth > b.worth
	end)
	return out
end

-- Returns true when the server took it, false when it fired for the full timeout and
-- the brainrot is still sat there, and nil when there was nothing to fire at. The
-- caller counts only the false: a missing prompt means the model hasn't streamed in,
-- which is not the same signal as a full carry.
local function grab(item, alive)
	local prompt = item:FindFirstChildWhichIsA("ProximityPrompt", true)
	if not prompt or not prompt.Enabled then
		return nil
	end

	local home = item.Parent
	tp(item:GetPivot())

	-- fireproximityprompt returns nothing useful. The brainrot leaving the zone folder
	-- is the server telling you it accepted the grab.
	local deadline = os.clock() + GRAB_TIMEOUT
	repeat
		pcall(fireproximityprompt, prompt)
		task.wait()
	until item.Parent ~= home or os.clock() > deadline or not alive()

	return item.Parent ~= home
end

-- The bank. Crossing workspace.Line is the whole mechanic -- the stack on your head
-- becomes Tools in your Backpack, safe from being stolen and ready for PLACE BEST.
local function bank()
	if not holding() then
		return
	end
	say("banking")
	local deadline = os.clock() + BANK_TIMEOUT
	repeat
		tp(LINE_APPROACH)
		tp(LINE_CROSS)
	until not holding() or os.clock() > deadline
	if holding() then
		say("still holding - the line didn't take")
	end
end

local function sweep(zone, alive)
	local fold = zoneFolder(zone)
	if not fold then
		tp(anchor[zone]) -- the zone hasn't streamed in, or we drifted out of it
		return 0
	end

	local got, misses = 0, 0
	for _, entry in ipairs(spawnedIn(fold)) do
		if not alive() then
			break
		end
		-- The list was sorted before the first grab and a bank costs two teleports --
		-- plenty of time for someone else to take one. Skipping is free; not skipping
		-- costs the whole GRAB_TIMEOUT firing at a prompt nobody can win.
		if entry.item.Parent == fold then
			say(("zone %s - %s ($%s/s)"):format(zone, entry.item:GetAttribute("OriginalName") or "?", money(entry.worth)))
			local took = grab(entry.item, alive)
			if took == true then
				got, misses = got + 1, 0
			elseif took == false then
				misses += 1
				if misses >= GRAB_FAILS then
					break -- carry is full: nothing else in this zone will fit either
				end
			end
		end
	end

	bank()
	return got
end

-- Which zones to work this cycle, best first. ZONES is written in ascending tier, so
-- walking it backwards is "highest first" without a second ordering to keep in sync.
--
-- Tick nothing and the list stops being a choice and becomes a search: every zone that
-- right now holds a brainrot of a rarity you ticked, richest find first, and nowhere
-- else. That's the "rarity only" mode -- it never teleports you somewhere on the chance
-- something spawns, only where one already is.
--
-- The search reads all 11 folders from wherever you're stood. StreamingEnabled is on
-- for this place, but a dump taken from (-8, 365, 327) still held every brainrot in
-- zone 11 at (0, 3293, 2290) -- 3.5k studs out -- so the whole map is replicated in
-- practice. A zone that somehow hasn't replicated reads as empty and is skipped, which
-- costs a wasted cycle rather than breaking the hunt.
local ticked = {}

local function order()
	local list = {}
	for i = #ZONES, 1, -1 do
		local name = ZONES[i][1]
		if ticked[name] then
			table.insert(list, name)
		end
	end
	if #list > 0 then
		return list
	end

	-- spawnedIn is already rarity-filtered and sorted, so its first entry is this
	-- zone's best matching brainrot -- and nil is "nothing here I'd stop for".
	local found = {}
	for _, z in ipairs(ZONES) do
		local fold = zoneFolder(z[1])
		local best = fold and spawnedIn(fold)[1]
		if best then
			table.insert(found, { zone = z[1], worth = best.worth })
		end
	end
	table.sort(found, function(a, b)
		return a.worth > b.worth
	end)
	for _, entry in ipairs(found) do
		table.insert(list, entry.zone)
	end
	return list
end

local gen, running = 0, false

local function setRunning(on)
	if on == running then
		return
	end
	running = on
	if not on then
		say("idle")
		return
	end

	gen += 1
	local mine = gen
	-- Bumping gen retires the previous thread; alive() is how the sweep and the grab
	-- deep inside it find out, instead of running on to the end of a zone we've left.
	local function alive()
		return running and gen == mine
	end

	task.spawn(function()
		local total, parked = 0, false
		while alive() do
			local list = order()
			if #list == 0 then
				-- Either every rarity is unticked, or nothing you want has spawned
				-- anywhere yet. Both are "wait and look again", not an error.
				-- A ticked zone always gives a list, so this is hunt mode: idle on the
				-- plot -- same spot as the TP to plot button -- rather than in whatever
				-- zone we just emptied. With only Exclusive/Celestial ticked that wait
				-- is most of the session, and standing in a zone is where you get
				-- stolen from. Once, not per beat.
				if not parked then
					parked = tpPlot()
				end
				say("nothing matching - waiting at base")
				task.wait(DWELL)
			else
				parked = false
			end
			for _, zone in ipairs(list) do
				if not alive() then
					break
				end
				-- Work a paying zone again before dropping to the next one down. A zone
				-- that came up empty gets one look and we move on. A refused claim is
				-- the placer holding the character: wait it out on this zone rather
				-- than burning through the whole list doing nothing.
				repeat
					local got = 0
					local ran = claim(function()
						tp(anchor[zone])
						got = sweep(zone, alive)
					end)
					if ran then
						total += got
						say(("zone %s - %d banked"):format(zone, total))
					end
					task.wait(DWELL)
					if ran and got == 0 then
						break
					end
				until not alive()
			end
		end
		if gen == mine then
			say(("idle - %d banked"):format(total))
		end
	end)
end

-- place ----------------------------------------------------------------------
local function put(entry, target)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return false
	end
	hum:EquipTool(entry.tool) -- the slot prompt takes what you're holding
	tp(target.at + Vector3.new(0, 3, 0))

	-- The tool losing its parent altogether is the server consuming it. Equipping only
	-- moves it from the Backpack to the Character, so this can't fire early.
	local deadline = os.clock() + PLACE_TIMEOUT
	repeat
		pcall(fireproximityprompt, target.prompt)
		task.wait()
	until not entry.tool.Parent or os.clock() > deadline
	return not entry.tool.Parent
end

-- One pass: best brainrot into the best home available to it. Empty unlocked slots get
-- filled first; after that it swaps against the worst thing placed, and only while it's
-- actually holding something better. Each list is walked once, so a swapped-out brainrot
-- -- which lands back in the Backpack -- can't be re-placed into the slot it just left.
local function placePass()
	local held = banked()
	if #held == 0 then
		return
	end

	local empty, filled = {}, {}
	for _, s in ipairs(slots()) do
		if s.item then
			table.insert(filled, s)
		elseif s.unlocked then
			table.insert(empty, s)
		end
	end
	table.sort(held, function(a, b)
		return a.worth > b.worth
	end)
	table.sort(empty, function(a, b)
		return a.order < b.order -- Floor1 Slot1 up; see the note on `order` in slots()
	end)
	table.sort(filled, function(a, b)
		return a.worth < b.worth -- worst first: that's the one worth displacing
	end)

	local e, f, done = 1, 1, 0
	for _, entry in ipairs(held) do
		local target
		if empty[e] then
			target = empty[e]
			e += 1
		elseif filled[f] and entry.worth > filled[f].worth then
			target = filled[f]
			f += 1
		end
		if not target then
			break -- nothing left it can improve on; the rest are worse still
		end
		say(("placing %s ($%s/s)"):format(entry.tool:GetAttribute("OriginalName") or "?", money(entry.worth)))
		if put(entry, target) then
			done += 1
		end
	end
	if done > 0 then
		say(("placed %d"):format(done))
	end
end

-- Empty-handed, your own occupied slot's prompt is "Pick Up" rather than "Swap", so
-- unequipping first is what turns the same prompt into a retrieval. The VisualItem
-- leaving the slot is the server confirming it.
local function take(s)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local item = s.item
	if not (hum and item) then
		return false
	end
	hum:UnequipTools()
	tp(s.at + Vector3.new(0, 3, 0))

	local deadline = os.clock() + PLACE_TIMEOUT
	repeat
		pcall(fireproximityprompt, s.prompt)
		task.wait()
	until not item.Parent or os.clock() > deadline
	return not item.Parent
end

-- Rearrange the plot so the richest brainrot sits at Floor1/Slot1 and it descends from
-- there. Worth saying plainly: this pays NOTHING. A brainrot earns the same on
-- Floor7/Slot10 as on Floor1/Slot1 -- checked against the Earnings billboards, where
-- the same item and mutation reads the same +/s on every floor it appears on. This is
-- for reading your own plot at a glance.
--
-- Clear the whole plot into the Backpack, then let placePass lay it back out: with
-- every unlocked slot empty its existing "best first, lowest slot first" rule IS the
-- sort, so there's no second ordering to write or keep in step. Costs a teleport per
-- brainrot each way; a cycle sort would save a third of the moves and cost far more
-- code than the saving is worth.
-- ponytail: the plot earns nothing between the clear and the re-place, and if the run
-- dies in the gap the brainrots sit safely in your Backpack for Place Best to restore.
local function sortPlot()
	for _, s in ipairs(slots()) do
		if s.item then
			say(("clearing %s %s"):format(s.floor, s.slot))
			take(s)
		end
	end
	placePass()
end

-- cash -----------------------------------------------------------------------
-- firetouchinterest fires the pad's TouchInterest directly, so this reaches all 70
-- pads on all 7 floors from wherever you're stood. No teleporting, which is why it
-- doesn't take claim() and can run flat out next to the farm.
local hasFTI = typeof(firetouchinterest) == "function"

local function collectPass()
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	if not (hasFTI and head) then
		return
	end
	for _, s in ipairs(slots()) do
		-- Occupied only. An empty slot earns nothing, so its pad has nothing to give,
		-- and occupied implies unlocked -- one test covers both. On a full plot that's
		-- 70 touches a pass; on a fresh one it's however many brainrots you've placed.
		if s.pad and s.item then
			-- 0 begins the touch, 1 ends it; the server's handler runs on the begin.
			pcall(firetouchinterest, head, s.pad, 0)
			task.wait()
			pcall(firetouchinterest, head, s.pad, 1)
		end
	end
end

-- upgrade --------------------------------------------------------------------
-- Best earner first. The server spends whatever cash you have on the calls it gets to
-- first, so the order IS the policy -- fired blind, Floor1/Slot1's Commons soak up the
-- upgrades your Godly should have had. No character movement, so no claim() needed.
local function upgradePass()
	local occupied = {}
	for _, s in ipairs(slots()) do
		if s.item then
			table.insert(occupied, s)
		end
	end
	table.sort(occupied, function(a, b)
		return a.worth > b.worth
	end)
	for _, s in ipairs(occupied) do
		RequestSlotUpgrade:FireServer(s.floor, s.slot)
	end
end

-- One generation counter per loop, same reason as the farm: toggling off and on inside
-- a single interval otherwise leaves the sleeping thread alive next to the new one.
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

local placer = { on = false, gen = 0 }
local collector = { on = false, gen = 0 }
local upgrader = { on = false, gen = 0 }
local floorer = { on = false, gen = 0 }
local carrier = { on = false, gen = 0 }
local rebirther = { on = false, gen = 0 }

-- gui ------------------------------------------------------------------------
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a
-- restyle is one file and not sixteen. Fetched here rather than installed by the loader,
-- so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Skate for Brainrots", -- fallback until the live name lands
	folder = "SkateRots", -- unchanged: renaming it orphans configs already saved in-game
	size = UDim2.fromOffset(440, 460),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local Farm = Tab:Section({ Title = "Farm", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })
local Plot = Tab:Section({ Title = "Plot", Icon = "solar:buildings-2-bold", Box = true, BoxBorder = true, Opened = true })
local Boost =
	Tab:Section({ Title = "Boosts", Icon = "solar:double-alt-arrow-up-bold", Box = true, BoxBorder = true, Opened = true })

-- The dropdown hands back whatever strings it was given, so the label carries the tier
-- hint and this maps it back to the folder name under workspace.ItemSpawns.
local zoneLabels, zoneOf, labelOf = {}, {}, {}
for _, z in ipairs(ZONES) do
	local label = ("Zone %s - %s"):format(z[1], z[3])
	table.insert(zoneLabels, label)
	zoneOf[label] = z[1]
	labelOf[z[1]] = label
end

local defaultLabels = {}
for _, name in ipairs(DEFAULT_ZONES) do
	ticked[name] = true
	table.insert(defaultLabels, labelOf[name])
end
for _, rarity in ipairs(RARITIES) do
	wanted[rarity] = true
end

-- table.clear, never `= {}`: the farm thread holds these tables as upvalues, so
-- replacing one leaves the loop reading the copy nobody ticks any more.
local function retick(into, values, keyOf)
	table.clear(into)
	for _, v in ipairs(values) do
		into[keyOf(v)] = true
	end
end

local function itself(v)
	return v
end

-- One button per list rather than two: empty means "tick everything", anything else
-- means "clear it", so the next press always does the opposite of the last one.
-- :Select() writes the selection and redraws the menu but deliberately does NOT fire
-- the Callback, which is why retick has to be called by hand alongside it.
local function allOrNone(drop, values, into, keyOf)
	local picked = next(into) == nil and values or {}
	drop:Select(picked)
	retick(into, picked, keyOf)
end

local zoneDrop = Farm:Dropdown({
	Title = "Camp Zones (optional)",
	Desc = "Leave empty: rarity hunts all 11, richest first. Ticked: camp those instead.",
	Values = zoneLabels,
	Value = defaultLabels,
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		-- The callback hands over the whole selection, and the loop reads `ticked`
		-- live, so a re-tick lands at the next zone without restarting anything.
		retick(ticked, values, function(label)
			return zoneOf[label]
		end)
	end,
})

Farm:Button({ Title = "Camp zones: all / none", Callback = function()
	allOrNone(zoneDrop, zoneLabels, ticked, function(label)
		return zoneOf[label]
	end)
end })

local rarityDrop = Farm:Dropdown({
	Title = "Rarity",
	Desc = "A hard gate. An unticked rarity is skipped even in an otherwise empty zone.",
	Values = RARITIES,
	Value = RARITIES,
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		retick(wanted, values, itself)
	end,
})

Farm:Button({ Title = "Rarity: all / none", Callback = function()
	allOrNone(rarityDrop, RARITIES, wanted, itself)
end })

Farm:Toggle({
	Title = "Auto Farm Zone",
	Desc = "Grab best first until the carry is full, then cross the line to bank it",
	Value = false,
	Callback = function(v)
		setRunning(v)
	end,
})

Farm:Button({ Title = "TP to zone", Callback = function()
	local list = order()
	tp(anchor[list[1] or DEFAULT_ZONES[1]]) -- the one the farm would work first
end })
Farm:Button({ Title = "Bank now", Callback = function()
	claim(bank)
end })

Plot:Toggle({
	Title = "Place Best",
	Desc = "Backpack into your plot, best first; swaps out the worst placed when full",
	Value = false,
	Callback = function(v)
		placer.on = v
		if v then
			every(placer, PLACE_EVERY, function()
				claim(placePass)
			end)
		end
	end,
})

Plot:Toggle({
	Title = "Collect All Cash",
	Desc = "Touches the cash pad of every occupied slot, from wherever you are, every 5s",
	Value = false,
	Callback = function(v)
		collector.on = v
		if v then
			every(collector, COLLECT_EVERY, collectPass)
		end
	end,
})

Plot:Toggle({
	Title = "Auto Upgrade",
	Desc = "RequestSlotUpgrade over your occupied slots, best earner first",
	Value = false,
	Callback = function(v)
		upgrader.on = v
		if v then
			every(upgrader, UPGRADE_EVERY, upgradePass)
		end
	end,
})

-- A button, not a toggle: once sorted it stays sorted until Place Best drops something
-- new in, and re-running it on a timer would thrash the plot and hold the character
-- away from the farm for a tidiness that pays no cash. Press it when you want it neat.
Plot:Button({ Title = "Sort Plot (best first)", Callback = function()
	claim(function()
		sortPlot()
		say("sorted")
	end)
end })

Plot:Button({ Title = "TP to plot", Callback = tpPlot })

Boost:Toggle({
	Title = "Auto Unlock Floor",
	Desc = "RequestBaseUpgrade on a timer -- 10 more slots for Place Best to fill",
	Value = false,
	Callback = function(v)
		floorer.on = v
		if v then
			every(floorer, FLOOR_EVERY, function()
				RequestBaseUpgrade:FireServer()
			end)
		end
	end,
})

Boost:Toggle({
	Title = "Auto Carry Upgrade",
	Desc = "PurchaseCarry on a timer -- one more brainrot per trip to the line",
	Value = false,
	Callback = function(v)
		carrier.on = v
		if v then
			every(carrier, CARRY_EVERY, function()
				PurchaseCarry:FireServer()
			end)
		end
	end,
})

Boost:Toggle({
	Title = "Auto Rebirth",
	Desc = "WIPES YOUR PLOT when the server accepts. Leave off while farming.",
	Value = false,
	Callback = function(v)
		rebirther.on = v
		if v then
			every(rebirther, REBIRTH_EVERY, function()
				RequestRebirth:FireServer()
			end)
		end
	end,
})

local line = Farm:Paragraph({ Title = "Status", Desc = "idle" })
say = function(msg)
	line:SetDesc(msg)
end

-- close ----------------------------------------------------------------------
local function stopAll()
	placer.on, collector.on, upgrader.on = false, false, false
	floorer.on, carrier.on, rebirther.on = false, false, false
	setRunning(false)
end

Window:OnDestroy(function()
	stopAll()
	getgenv().skateRotsStop = nil
end)

getgenv().skateRotsStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().skateRotsStop = nil
end
