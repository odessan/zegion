--[[ Cut Grass -- tick zones, farm the highest one that has loot, bank when full

     Zone      : multi-select over workspace.Zones, which nests one level per world:

                     Zones.W5.Zone_47.SpawnZone["86_Guardian_Scarab"]

                 Listed by world highest-first, then by zone index -- Zone_22 above
                 Zone_5, which plain alphabetical inverts. scanZones works this out by
                 SHAPE (a SpawnZone means zone, children without one mean container), so
                 the old flat Zones.Zone_NN layout still reads correctly and World 6 will
                 need no change. The list rebuilds itself when anything at either of
                 those two levels appears, so a world streaming in fills it on its own.

                 Ticks are remembered by zone NAME, which stays unique across worlds --
                 the indexes run straight through, World 5 picking up at Zone_47.

                 Only the world you are STANDING IN is listed. The folder holds every
                 unlocked world's zones and the rest are unreachable clutter: farming one
                 means being teleported out of the world you were in, which is exactly the
                 bug where World 4 kept ending up back in World 1. The list follows you,
                 watching the CurrentWorld attribute -- a world change need not touch the
                 Zones folder at all, since every unlocked world can already be loaded.

                 Zones that read "empty" are NOT dropped, and shouldn't be: under
                 streaming a zone you aren't standing in has no loot client-side, so
                 "empty" is what nearly every zone says from anywhere else on the map.
                 Filtering on it would leave you the two zones you happen to be next to.

     Loot      : multi-select over ReplicatedStorage.Loot -- the TEMPLATE folder, so the
                 list is every loot type in the game, not just whatever happens to be on
                 the ground right now. Only Farm loot reads these ticks.

     Farm zone : every cycle walks the ticked zones from the top down and works the
                 FIRST one holding loot, then starts the walk again from the top. Lower
                 zones only get worked while the higher ones are dry, and the moment the
                 top one respawns anything it goes back.

                 Inside a zone, items sort by LootSellPrice descending -- the exact
                 number off the item's own attribute, no billboard scraping. Everything
                 gets taken, best first.

     Farm loot : the same walk, except a zone only counts as holding loot if it holds one
                 of the ticked Loot types, and only those get taken -- everything else is
                 walked past. With no zone ticked it searches every zone there is, which
                 makes it "go find me this item" rather than "farm here" -- and every zone
                 there is means this world's, because scanZones lists no others.

                 It also CLIMBS, and it sweeps: lowest ticked zone first, up to the
                 highest, then round again -- working a zone doesn't end the walk, it
                 carries on to the next one. Farm zone's top-down restart is about
                 value (higher zone, better loot) and hunting a named type has no such
                 ranking, so re-walking the top every pass would just mean the bottom
                 zones never got reached.

                 The two are mutually exclusive: turning one on turns the other off.

                 A walk that comes back empty names the ticked types it never laid eyes
                 on -- those are picks no ticked zone spawns, and waiting won't help.
                 Anything NOT named did exist and was just gone when we got there, which
                 waiting does fix. Only zones you actually stood in count: under
                 streaming, a zone you never entered has no loot client-side to see.

     Auto sell : on by default. It decides what a bank trip does once it gets there --
                 OFF deposits the loot at base and stops, so it's in your inventory to
                 craft with; ON sells it on the way in. The TRIP happens either way, and
                 has to: a full bag can't pick anything up.

     Auto click: spams StrengthService.ClickRequested, on its own thread and its own
                 flag -- it runs alongside either farm or on its own, wherever you are.
                 The slider sets the beat, 0.1s to 1s, and lands mid-run.

     Full carry is READ when the server offers it. DataService.GetBackpackSlotsState
     answers with load and capacity, and BackpackSlotsUpdated pushes the same numbers
     after every pickup and every sale -- so the check is exact, it costs no round trip
     after the first, and the bag is checked BEFORE the next press rather than proven
     full by pressing. That matters here: this game answers a full-bag pickup with a
     Robux upsell, so every press spent proving what we could have read is a popup.

     Everything below is the fallback, for the update that moves those remotes.

     Full carry is otherwise INFERRED: a grab that leaves the item sitting there means
     the server refused it, and FULL_STREAK of those in a row means the bag is full. So
     the same vanish-check is both the per-item confirmation and the full detector, and
     nothing here has to know your capacity or survive you upgrading it. A walk that ends
     with a refusal still outstanding banks too -- the streak can be split across zones,
     and filling up on a zone's last item never reaches it anywhere at all.

     Except when the game just SAYS so. It puts "You can't carry more items" on screen,
     and a refusal carrying that notice skips the whole streak. Checked only after a
     refusal, and only ever an accelerator: if the notice never turns up, the streak
     still decides.

     Banking is a DEPOSIT and it is not automatic. TeleportToSpawn alone does nothing to
     the bag -- what empties it is ResetBackpackLoadAtBase, which the CLIENT has to ask
     for, and which the server refuses while GD_IsInsideGrassZone is still true on you.
     The game's own controller fires it when that attribute clears and gives up after
     three tries 0.25s apart; the farm was teleporting back into a zone inside that
     window, so the deposit landed in the grass and was refused, and the bag sat at
     20/20 through trip after trip. So: teleport, WAIT for the server to clear the
     attribute, sell if Auto sell says so, then ask for the deposit ourselves.

     A refused item is retried once first: a pickup cooldown and a full bag both refuse
     the first press, and only the cooldown lets the second one through.

     The press itself is three methods tried in order until one actually removes the
     item, then that one is used alone -- see METHODS. They differ in WHO hears them,
     which is the point: fireproximityprompt triggers the prompt server-side and a
     pickup written as a LocalScript on PickupPrompt.Triggered never notices. Which one
     wins is not stable between runs, so all three stay.

     How long to stand on an item before pressing tunes itself (see ARRIVE_WAIT). Press
     too early and it costs a whole retry cycle -- about 1.5s an item, which was most of
     the run before it did this.

     Two things this script does not know yet and works out at runtime, both printed to
     the console (F9):

       1. Whether Knit exposes a zone-travel remote. If one turns up it is tried, then
          VERIFIED by whether you actually ended up near the zone; if you didn't, it is
          written off for the session and everything falls back to PivotTo.
       2. What a loot model is made of. A ProximityPrompt anywhere inside gets held;
          the first target also dumps its whole child tree so the next run can be
          written against facts instead of guesses.

     Startup also prints every Knit service and its remotes. Read that once -- if
     there's a Sell or a Collect remote in there, most of this file becomes unnecessary.

     Executor only: the UI is WindUI, pulled in with HttpGet, which Studio blocks.

     The minus button SHADES the window -- body collapses to a bare Zegion pill, click
     it again to roll back down. That's there instead of WindUI's real Minimize, which on
     a PC hides the window and leaves nothing to click to get it back. RightControl does
     the same shade from the keyboard; RightAlt is the hide-outright one, for a
     screenshot. Red closes it for good; rerun the script to come back,
     or stop everything without touching the UI with getgenv().cutGrassStop() ]]

-- config ---------------------------------------------------------------------
-- Land ON the item, not above it. A prompt has a MaxActivationDistance and a pivot is a
-- model's CENTER, so every stud of lift here spent range we needed -- 4 was enough to
-- put the press out of reach and grab nothing at all.
local HEIGHT_OFFSET = 0
local GRAB_REACH = 200 -- forced onto each prompt; the range check is the client's own
local ZONE_LIFT = 8 -- studs above a zone's pivot, which is its center, not its floor
local ZONE_SETTLE = 0.35 -- after arriving, before anything is trusted to have streamed
local STREAM_TIMEOUT = 3 -- max seconds waiting for a zone's loot to stream in
local PROMPT_WAIT = 1 -- max seconds waiting for a just-streamed model to grow its prompt
local POLL = 0.15
local GRAB_WAIT = 0.5 -- max seconds waiting for a grabbed item to disappear
-- Items that refused even a retry before we call the carry full. grabItem already presses
-- twice per item, so 2 here means four refused presses -- and in a game that answers a
-- full-backpack pickup with a Robux upsell, that's four popups. Drop to 1 if you'd rather
-- bank a little early than see them; the cost is mistaking a pickup cooldown for a full bag.
local FULL_STREAK = 2
local RETRY_WAIT = 0.6 -- before re-trying the SAME item, to tell a cooldown from a full bag
-- The game's own full-bag notice, matched loosely against any on-screen text. It says "You
-- can't carry more items"; match a fragment so a reword doesn't silently turn this off.
local FULL_NOTICE = "carry more"
local RECHECK = 10 -- trips between re-measuring the carry, so an upgraded bag is noticed
-- How long to stand on an item before pressing. Starts at ARRIVE_WAIT and finds its own
-- level: up a step whenever the first press misses and the retry lands, gently back down
-- whenever the first press works. From out here there is no telling arrival lag from a
-- server-side pickup cooldown, and this doesn't need to know which it is -- only how
-- long the wait has to be. Pressing too early costs a whole retry cycle, ~1.5s an item.
local ARRIVE_WAIT = 0.2
local SETTLE_STEP = 0.15
local SETTLE_MAX = 1.5
-- Where the Auto sell toggle starts. It only decides whether a bank trip SELLS -- the trip
-- itself always happens, because a full bag can't pick anything up.
local AUTO_SELL = true
local BANK_WAIT = 1 -- longest wait for the server to agree we've left the zone
local ZONE_RADIUS = 250 -- how near the zone counts as "the travel remote worked"
-- Studs from an item that still counts as standing on it. The prompt's real range is the
-- server's, not the one we force onto it, so this wants to stay small -- it is the check
-- that says "we're actually here" before pressing.
local ARRIVE_NEAR = 25
-- Longest any single RemoteFunction gets to answer before the farm walks away from it. See
-- callTimed: without this a silent server parks the whole run in a yield.
local REMOTE_TIMEOUT = 5
-- How long a single step may take before the watchdog says so in the console. Longer than
-- the slowest legitimate step (a bank trip) and short enough to catch a hang while you're
-- still looking at it.
local WATCHDOG = 30
local IDLE = 3 -- parked after a full walk that found loot in no ticked zone
-- Laps that ended in an error, in a row, before the farm gives up. One is a hiccup worth
-- restarting the walk over; this many means the fault isn't going to clear on its own.
local ERR_GIVEUP = 5
-- Same idea for banking: a trip that didn't empty the bag can be a respawn landing badly,
-- but this many in a row means the deposit isn't reaching the server and nothing can be
-- picked up until it does -- which is worth stopping for rather than spinning full.
local BANK_GIVEUP = 3
-- How long to wait for a character to come back before giving up on the trip. Respawn is
-- a few seconds; raise it if a death in a far zone still costs you a wasted walk.
local CHAR_WAIT = 6
-- How long the Zones watcher sits on a burst of streaming events before looking. Raise it
-- if switching World takes noticeably long to show up in the dropdown.
local WATCH_DEBOUNCE = 2
-- Starting beat for Auto click, and the slider's floor. Raise it if the server starts
-- ignoring clicks or the game notices the rate; the slider tops out at 1s.
local CLICK_RATE = 0.1
local KEY_TOGGLE = Enum.KeyCode.RightControl

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

if getgenv and getgenv().cutGrassStop then
	getgenv().cutGrassStop() -- re-running must not stack a second panel/loop
end

-- Every :Connect() goes through track() so one stopAll() can drop them all. Without it a
-- re-paste (or a close) leaves the old panel's listeners live -- CARRY_UPD, the Zones
-- watchers, CurrentWorld -- and a debounced refresh then fires against a destroyed UI.
local conns = {}
local function track(c)
	conns[#conns + 1] = c
	return c
end
local stopped = false -- flips true on teardown; delayed callbacks bail on it

local function log(...)
	print("[cut_grass]", ...)
end

-- A breadcrumb, because "it stopped and there was nothing in the console" is not something
-- you can debug after the fact. Every slow step names itself here; the watchdog in
-- startFarm reads it and, if the farm thread is parked, is the one thing still running to
-- say WHERE. Costs two assignments per step.
local mark, markAt = "idle", os.clock()
local function step(what)
	mark, markAt = what, os.clock()
end

local function hrp()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- Nothing in this file works without a live character, and a death, a fall or a server-side
-- teleport takes one away for several seconds. Waiting is the whole fix: without it every
-- grab in that window returns false, workZone reads false as "the server refused it", two
-- of those bank, and two banks that grab nothing stop the farm for good. That is the
-- "stuck, then never works again" -- it was never the loot, it was the respawn.
--
-- Returns immediately when the character is fine, so this is free to call per item.
local function waitForChar(seconds)
	local deadline = os.clock() + (seconds or CHAR_WAIT)
	repeat
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		-- No Humanoid at all is somebody else's game, not a dead character -- take the root
		-- and go, the same way the rest of this file degrades instead of erroring.
		if char and char:FindFirstChild("HumanoidRootPart") and (not hum or hum.Health > 0) then
			return true
		end
		task.wait(0.1)
	until os.clock() >= deadline
	return false
end

-- knit ------------------------------------------------------------------------
-- The version is in the folder name (acceteer_knit@1.7.2), so matching on "knit"
-- instead of the literal survives the game bumping its dependency.
local function knitServices()
	local pkgs = ReplicatedStorage:FindFirstChild("Packages")
	local index = pkgs and pkgs:FindFirstChild("_Index")
	if not index then
		return nil
	end
	for _, child in ipairs(index:GetChildren()) do
		if child.Name:lower():find("knit") then
			local knit = child:FindFirstChild("knit")
			local services = knit and knit:FindFirstChild("Services")
			if services then
				return services
			end
		end
	end
	return nil
end

local SERVICES = knitServices()

-- The probe. Everything below guesses at remote names; this is what tells you the real
-- ones, so read it once and the guessing can be replaced with the actual paths.
local function dumpKnit()
	if not SERVICES then
		log("no Knit Services found -- remotes unavailable, PivotTo only")
		return
	end
	log("--- Knit services ---")
	for _, svc in ipairs(SERVICES:GetChildren()) do
		local out = {}
		for _, folder in ipairs(svc:GetChildren()) do
			for _, remote in ipairs(folder:GetChildren()) do
				table.insert(out, folder.Name .. "." .. remote.Name)
			end
		end
		log(svc.Name .. " -> " .. (#out > 0 and table.concat(out, ", ") or "(none)"))
	end
	log("--- end ---")
end

-- Exact name first, and the CLASS has to be the one we intend to call. Both halves are
-- load-bearing: Knit publishes its past-tense notifications (RE.TeleportedToSpawn, a
-- RemoteEvent the server fires AT you) in the same service as the call you want, so a
-- loose search for "spawn" finds the notification and every bank trip dies on
-- "InvokeServer is not a valid member of RemoteEvent".
local function findRemote(servicePattern, namePattern, class)
	if not SERVICES then
		return nil
	end
	local loose
	for _, svc in ipairs(SERVICES:GetChildren()) do
		if svc.Name:lower():find(servicePattern) then
			for _, folder in ipairs(svc:GetChildren()) do
				for _, remote in ipairs(folder:GetChildren()) do
					if remote:IsA(class) then
						local name = remote.Name:lower()
						if name == namePattern then
							return remote
						elseif not loose and name:find(namePattern) then
							loose = remote
						end
					end
				end
			end
		end
	end
	return loose
end

-- RemoteFunction is what these are, but fall back to the event of the same name rather
-- than losing the feature if a game wires it the other way.
local TP_SPAWN = findRemote("teleport", "teleporttospawn", "RemoteFunction")
	or findRemote("teleport", "teleporttospawn", "RemoteEvent")
local TP_ZONE = findRemote("teleport", "teleporttozone", "RemoteFunction")
	or findRemote("teleport", "zone", "RemoteFunction")
-- StrengthService.RE.ClickRequested. Found by shape rather than written out, so it
-- survives the game bumping acecateer_knit's version in the folder name.
local CLICK = findRemote("strength", "clickrequested", "RemoteEvent")

local function call(remote, ...)
	if remote:IsA("RemoteFunction") then
		return remote:InvokeServer(...)
	end
	remote:FireServer(...)
	return nil
end

-- InvokeServer has no timeout. If the server's handler errors, or is throttling you, or
-- simply never returns, the calling thread yields FOREVER -- and a farm thread parked in a
-- yield is indistinguishable from one that died: no error, no log line, no movement, the
-- toggle still lit. That is the "it just stops and there's nothing in the console".
--
-- pcall does not help; there is no error to catch. The only fix is to stop waiting, so the
-- invoke goes on its own thread and this one gives up on a clock. The abandoned thread
-- stays parked and is harmless -- it writes to locals nobody reads any more.
--
-- Returns ok, result -- ok false on both a thrown error and a timeout, which the callers
-- already treat the same way.
local function callTimed(remote, seconds, ...)
	if not remote:IsA("RemoteFunction") then
		local ok = pcall(call, remote, ...)
		return ok, nil
	end
	local args = table.pack(...)
	local done, result
	task.spawn(function()
		local ok, res = pcall(function()
			return remote:InvokeServer(table.unpack(args, 1, args.n))
		end)
		done, result = ok, res
	end)
	local deadline = os.clock() + seconds
	while done == nil and os.clock() < deadline do
		task.wait()
	end
	if done == nil then
		log(("%s never answered in %ds -- carrying on without it"):format(remote.Name, seconds))
		return false, nil
	end
	return done, result
end

-- carry ------------------------------------------------------------------------
-- The bag's fill level is a number the server will just hand you. DataService answers
-- GetBackpackSlotsState with {Count|BackpackLoad, Capacity, Revision} and pushes the same
-- table on BackpackSlotsUpdated after every pickup and every sale -- BackpackController
-- does nothing else to draw the "3/5" on screen.
--
-- So everything below that proves a full carry by pressing until the server refuses is
-- now the FALLBACK, for a game update that moves these. Prefer the read: each refused
-- press is a Robux upsell popup, and the inference pays FULL_STREAK of them per trip.
local CARRY = findRemote("data", "getbackpackslotsstate", "RemoteFunction")
local CARRY_UPD = findRemote("data", "backpackslotsupdated", "RemoteEvent")
-- Banking is a DEPOSIT and selling is a separate call, which is the whole reason the bag
-- sat at 20/20 through trip after trip: TeleportToSpawn does not hand the loot in. The
-- game's own LootInventoryController does, by calling ResetBackpackLoadAtBase the moment
-- the server clears GD_IsInsideGrassZone off you -- and it gives up after three tries
-- 0.25s apart. The farm was teleporting back into a zone inside that window, so the
-- deposit landed with the player standing in grass again and was refused. Fire it
-- ourselves, on our own schedule, and the race is gone.
local DEPOSIT = findRemote("lootinventory", "resetbackpackloadatbase", "RemoteFunction")
local IN_ZONE_ATTR = "GD_IsInsideGrassZone" -- Attack config's GrassZoneStateAttributeName
-- Sells what's in the bag. Only ever called when Auto sell is on -- a deposit alone keeps
-- the loot, which is what you want when you're crafting with it.
local SELL_ALL = findRemote("data", "sellallbackpackloot", "RemoteFunction")

-- Read by bank(), set by the Auto sell toggle far below. Declared up here because banking
-- is the thing that has to know.
local autoSell = AUTO_SELL

local carryLoad, carryCap, carryRev = nil, nil, -1
-- trusted means "this is the answer to a question we just asked", which outranks the
-- revision check: a synchronous reply is the newest thing there is, and dropping it because
-- it came back without a Revision field would be the same stuck-full bug wearing a hat.
local function readCarry(state, trusted)
	if type(state) ~= "table" then
		return
	end
	-- Pushes can land out of order, and one stale table arriving after a sale is enough to
	-- leave the bag looking full for good. BackpackController drops them by Revision; so do
	-- we, for the same reason.
	local rev = tonumber(state.Revision) or 0
	if rev < carryRev and not trusted then
		return
	end
	carryRev = math.max(rev, carryRev)
	-- Two names for the same number, and a MISSING one means zero -- which is what the
	-- game's own controller does with this table. Carrying the previous value over instead
	-- is a one-way door: a single push without a count and the script is certain the bag is
	-- full for the rest of the session, banking on every trip and grabbing nothing.
	carryLoad = tonumber(state.BackpackLoad) or tonumber(state.Count) or 0
	carryCap = tonumber(state.Capacity) or carryCap
end

if CARRY_UPD then
	track(CARRY_UPD.OnClientEvent:Connect(readCarry))
end

-- true, false, or nil meaning "no remote -- go back to guessing". Free to call per item
-- once the push channel is connected; pass fresh to force a round trip.
local function carryFull(fresh)
	if not CARRY then
		return nil
	end
	if fresh or not carryCap or not CARRY_UPD then
		local ok, state = callTimed(CARRY, REMOTE_TIMEOUT)
		if not ok then
			return nil
		end
		readCarry(state, true)
	end
	if not (carryLoad and carryCap and carryCap > 0) then
		return nil
	end
	return carryLoad >= carryCap
end

-- zones -----------------------------------------------------------------------
local function zonesFolder()
	return workspace:FindFirstChild("Zones")
end

-- Zone_22 -> 22. Sorting on this rather than the name is the whole point: a plain
-- alphabetical sort puts Zone_5 above Zone_22, which is backwards from what "highest
-- zone first" means.
local function zoneIndex(name)
	return tonumber(name:match("(%d+)%s*$")) or 0
end

-- worlds ----------------------------------------------------------------------
-- workspace.Zones holds every UNLOCKED world's zones, not only the one you're standing in.
-- That is why Farm loot with nothing ticked hauled you out of World 4: it climbs from the
-- lowest zone up, and the lowest zone in the folder is Zone_1, in World 1.
--
-- Neither fact here costs a remote. The zone-to-world ranges are a plain config module the
-- client already has, and the world you're in is an attribute the server puts on you --
-- WorldsController reads exactly these two when its own GetState call doesn't answer.
local Worlds
pcall(function()
	Worlds = require(ReplicatedStorage.Shared.Configs.Worlds)
end)

-- nil means "can't tell", and every caller treats that as no filter rather than no zones:
-- a missing config must not empty the walk.
local function worldOfZone(index)
	if not (Worlds and Worlds.GetWorldIdForZone) then
		return nil
	end
	local ok, id = pcall(Worlds.GetWorldIdForZone, index)
	return ok and id or nil
end

local function scanZones()
	local folder = zonesFolder()
	local out = {}
	if not folder then
		return out
	end
	-- Every zone, SpawnZone or not. A streamed-out zone replicates as an empty model, so
	-- requiring the child here dropped the far ones out of the list AND out of the walk --
	-- 24 zones in the world, 19 in the dropdown. zoneSpawn resolves it later.
	local function take(inst, world)
		table.insert(out, {
			name = inst.Name,
			zone = inst,
			spawn = inst:FindFirstChild("SpawnZone"),
			index = zoneIndex(inst.Name),
			-- Taken from the container it was found in when there is one. That beats
			-- deriving it from the index: the folder name is the game telling us directly,
			-- and it stays right when the game adds World 6 to a config we haven't re-read.
			world = world,
		})
	end

	-- This folder was reshuffled when World 5 shipped: it used to hold Zone_NN models
	-- directly and now holds W1..W5 containers with the zones inside. Told apart by SHAPE,
	-- not by version, so both layouts work and neither is named in a path:
	--
	--   named W<n>, no SpawnZone   -> a world container: descend into its zones. Empty just
	--                                 means it hasn't streamed yet -- take nothing and let
	--                                 watchZones refill when its zones arrive; the container's
	--                                 own origin is not a zone to teleport to.
	--   has a SpawnZone            -> a zone, whatever it's called
	--   nothing at all, not W<n>   -> a real zone streamed as a bare model; take it so you land
	--                                 in roughly the right place instead of dropping it
	for _, child in ipairs(folder:GetChildren()) do
		local w = tonumber(child.Name:match("^[Ww](%d+)$"))
		if w and not child:FindFirstChild("SpawnZone") then
			for _, zone in ipairs(child:GetChildren()) do
				take(zone, w)
			end
		else
			take(child, w)
		end
	end

	-- Only the world you're standing in. The folder holds every unlocked world's zones, and
	-- the rest are unreachable clutter -- farming one means being teleported out of the
	-- world you were in. Filtered HERE rather than in the dropdown, so the walk reads the
	-- same list you're looking at instead of the two disagreeing.
	--
	-- The cost: ticking a zone is no longer a way to visit another world on purpose. That
	-- was a capability nobody asked for and it is what dragged World 4 back to World 1.
	local here = tonumber(player:GetAttribute("CurrentWorld"))
	if here then
		local mine = {}
		for _, entry in ipairs(out) do
			if (entry.world or worldOfZone(entry.index)) == here then
				table.insert(mine, entry)
			end
		end
		-- Unless it leaves nothing. An unrecognised world is not a reason to show an empty
		-- list and refuse to farm -- better to show all of them than none.
		if #mine > 0 then
			out = mine
		end
	end

	-- World first, so the list groups by world instead of interleaving two worlds' zones
	-- that happen to share an index.
	table.sort(out, function(a, b)
		local aw, bw = a.world or 0, b.world or 0
		if aw ~= bw then
			return aw > bw
		end
		if a.index == b.index then
			return a.name < b.name
		end
		return a.index > b.index
	end)
	return out
end

-- The TEMPLATE folder, not the ground: the dropdown should list every loot type in the
-- game, including ones no zone has spawned yet. Names are zero-padded (01_Button, 10_Key)
-- so a plain alphabetical sort is already cheapest-first.
local function scanLoot()
	local folder = ReplicatedStorage:FindFirstChild("Loot")
	local out = {}
	if not folder then
		return out
	end
	for _, item in ipairs(folder:GetChildren()) do
		table.insert(out, { name = item.Name, price = item:GetAttribute("LootSellPrice") })
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

-- Resolved on demand and cached, because streaming hands the zone over before its children:
-- a zone that was empty when we scanned from base has its SpawnZone by the time we're
-- standing in it. Re-checks Parent so a re-streamed zone doesn't keep a destroyed handle.
local function zoneSpawn(entry)
	if entry.spawn and entry.spawn.Parent then
		return entry.spawn
	end
	entry.spawn = entry.zone.Parent and entry.zone:FindFirstChild("SpawnZone") or nil
	return entry.spawn
end

-- The zone model itself is the fallback target: it's replicated even when SpawnZone isn't,
-- and getting near it is what makes SpawnZone stream in.
local function zoneTarget(entry)
	local spawn = zoneSpawn(entry)
	local pv = (spawn and spawn:IsA("PVInstance")) and spawn or entry.zone
	local ok, pivot = pcall(function()
		return pv:GetPivot()
	end)
	return ok and pivot.Position or Vector3.new()
end

-- loot ------------------------------------------------------------------------
-- LootId is what separates the loot from the scenery: SpawnZone also holds things like
-- Zone_Particles, which has no attributes and no business being teleported to.
-- Diagnostic only. An item another player picked up first vanishes exactly like one we
-- took, so vanish-means-success can't tell those apart -- the money can. Any numeric
-- leaderstat serves; what it's called doesn't matter.
local function cash()
	local stats = player:FindFirstChild("leaderstats")
	if not stats then
		return nil
	end
	for _, v in ipairs(stats:GetChildren()) do
		if v:IsA("IntValue") or v:IsA("NumberValue") then
			return v.Value
		end
	end
	return nil
end

local dumped, probes = false, 0 -- the tree once, then three attempts reported in full

local function dumpModel(item)
	if dumped then
		return
	end
	dumped = true
	log("--- first target: " .. item:GetFullName() .. " ---")
	local n = 0
	for _, d in ipairs(item:GetDescendants()) do
		n = n + 1
		if n > 40 then
			log("... (" .. (#item:GetDescendants() - 40) .. " more)")
			break
		end
		log("  " .. d.ClassName .. "  " .. d:GetFullName():sub(#item:GetFullName() + 2))
	end
	if n == 0 then
		log("  (empty -- no children at all)")
	end
	log("--- end ---")
end

-- Reported AFTER the attempt, for the first few items only. Before the fact all it
-- could say was what was in the model; after it, it separates the three ways a grab
-- fails -- no prompt at all, prompt fired but out of reach, prompt fired in reach and
-- the server still said no (which is the one that really means "carry full").
local function probe(item, prompt, got, earned)
	if probes >= 3 then
		return
	end
	probes = probes + 1
	local root = hrp()
	local dist = root and (root.Position - item:GetPivot().Position).Magnitude or -1
	-- "gone but no money" means someone else took it and we learned nothing.
	local money = earned == nil and "cash n/a" or (earned > 0 and ("+" .. earned) or "no cash change")
	if prompt then
		log(
			("probe %d: %s -> %s | %s | dist %.1f | %s hold=%.2f"):format(
				probes,
				item.Name,
				got and "GRABBED" or "still there",
				money,
				dist,
				-- Parent.Name, not GetFullName: a grabbed item is already out of the
				-- tree by now, and its full name comes back as a bare stub.
				(prompt.Parent and prompt.Parent.Name or "?") .. "." .. prompt.Name,
				prompt.HoldDuration
			)
		)
	else
		log(("probe %d: %s -> %s | %s | dist %.1f | NO ProximityPrompt anywhere inside"):format(
			probes,
			item.Name,
			got and "GRABBED" or "still there",
			money,
			dist
		))
	end
end

-- nil when idle, "zone" or "loot" while farming. It gates the filter below, which is the
-- entire difference between the two farm buttons: same walk, one of them ignores
-- everything you didn't tick.
local farmMode = nil
local farming = false -- up here because the dropdown rebuild below has to know about it
local lootDrop -- forward declared; the filter reads its ticks, the widget is built later

-- ponytail: matches on Name, which is what ReplicatedStorage.Loot gives us. If a spawned
-- clone turns out to be renamed, key on its LootId attribute instead.
local function wanted(item)
	return farmMode ~= "loot" or lootDrop.chosen[item.Name] == true
end

local function lootIn(entry)
	local out = {}
	local spawn = zoneSpawn(entry) -- nil until the zone streams in; waitForLoot keeps asking
	if not spawn then
		return out
	end
	for _, item in ipairs(spawn:GetChildren()) do
		if item:GetAttribute("LootId") and item:IsA("PVInstance") and wanted(item) then
			table.insert(out, item)
		end
	end
	table.sort(out, function(a, b)
		return (a:GetAttribute("LootSellPrice") or 0) > (b:GetAttribute("LootSellPrice") or 0)
	end)
	return out
end

-- Every loot NAME standing in a zone, ticked or not -- the same scan as lootIn without the
-- filter, so a walk can tell "you didn't tick this" apart from "this isn't here". Only
-- meaningful while you are IN the zone, for the streaming reason below.
local function namesIn(entry)
	local out = {}
	local spawn = zoneSpawn(entry)
	if not spawn then
		return out
	end
	for _, item in ipairs(spawn:GetChildren()) do
		if item:GetAttribute("LootId") then
			out[item.Name] = true
		end
	end
	return out
end

-- Standing in the zone IS the check for whether it has anything: under streaming the
-- items don't exist client-side until you're near them, so an empty result from far
-- away means nothing.
local function waitForLoot(entry, seconds)
	local deadline = os.clock() + seconds
	repeat
		local loot = lootIn(entry)
		if #loot > 0 then
			return loot
		end
		-- The timeout is there to wait for STREAMING, not for loot to spawn. Once the zone
		-- has handed us items, "none of them are ticked" is a final answer and the rest of
		-- the timeout is pure standing around. That case is rare in Farm zone, which wants
		-- everything, and it is MOST OF THE SWEEP in Farm loot -- three seconds a zone,
		-- every zone, every pass, waiting for a type that zone isn't holding.
		if next(namesIn(entry)) then
			return {}
		end
		task.wait(POLL)
	until os.clock() >= deadline
	return {}
end

-- movement ---------------------------------------------------------------------
-- stream is for JUMPING somewhere the client hasn't loaded -- a zone across the map. An item
-- we found by walking the tree is already streamed in by definition, so asking the server to
-- stream around it again buys nothing, and it is a yielding engine call made dozens of times
-- per zone. RequestStreamAroundAsync is throttled: ask too often and it stops returning.
--
-- That is what parked the run mid-grab with the watchdog printing "stuck 216s at: grab
-- 89_Colossus_Helm". Not the press, not the prompt -- the stream request in front of them.
-- pcall does not bound a yield, and neither, reliably, does the timeOut argument.
local function goTo(cf, stream)
	-- Before the stream request, not after: asking the server to stream around a character
	-- that doesn't exist is a wasted STREAM_TIMEOUT.
	if not waitForChar() then
		return false
	end
	if stream then
		-- Bounded from the outside, the same way every InvokeServer here is. An abandoned
		-- request is harmless; a farm thread waiting on one forever is the whole bug.
		local done = false
		task.spawn(function()
			pcall(function()
				player:RequestStreamAroundAsync(cf.Position, STREAM_TIMEOUT)
			end)
			done = true
		end)
		local deadline = os.clock() + STREAM_TIMEOUT
		while not done and os.clock() < deadline do
			task.wait()
		end
	end
	local char = player.Character
	if not char or not hrp() then
		return false
	end
	char:PivotTo(cf)
	return true
end

-- Tries the remote once per session and believes the result, not the call: InvokeServer
-- returning without erroring proves nothing (a wrong argument type is a perfectly
-- successful call that does nothing), so the test is whether you ended up there.
local zoneRemoteDead = false

-- Two hops, not one. The first can only aim at what has already replicated, and a zone that
-- was streamed out gives us nothing but the bare model -- whose pivot is wherever the
-- importer left it, which on the big high zones is nowhere near SpawnZone. Loot hundreds of
-- studs from where we land never streams in, so the zone reads empty however long we poll:
-- that is why Zone_35 looked loot-free with loot plainly sitting in it.
--
-- Being in the zone is what makes SpawnZone replicate, so once it exists, aim again.
local function travelToZone(entry)
	local blind = zoneSpawn(entry) == nil -- nothing to aim at yet but the zone model
	local target = zoneTarget(entry)
	local arrived = false

	if TP_ZONE and not zoneRemoteDead then
		local ok = callTimed(TP_ZONE, REMOTE_TIMEOUT, entry.zone.Name)
		if not ok then
			ok = callTimed(TP_ZONE, REMOTE_TIMEOUT, entry.index)
		end
		if ok then
			task.wait(ZONE_SETTLE)
			local root = hrp()
			arrived = root ~= nil and (root.Position - target).Magnitude < ZONE_RADIUS
		end
		-- Only condemn the remote when we had a REAL target to check against. When blind
		-- (SpawnZone not streamed) the target is the bare model pivot, which on the big zones
		-- is nowhere near where the remote actually drops you -- failing that check would write
		-- off a working remote forever. Fall through to PivotTo for this zone, keep the remote.
		if not arrived and not blind then
			zoneRemoteDead = true
			log(("%s didn't put me in %s -- PivotTo for the rest of the session"):format(TP_ZONE.Name, entry.name))
		end
	end

	if not arrived then
		arrived = goTo(CFrame.new(target + Vector3.new(0, ZONE_LIFT, 0)), true)
		if arrived then
			-- goTo reports that PivotTo was CALLED, which is not the same as having moved.
			-- A teleport is a request: the server can put the character straight back, and
			-- a client paused for streaming never applies it at all. The farm then works a
			-- zone it isn't standing in and presses at nothing -- which from outside looks
			-- exactly like it stopped teleporting and sat down. The remote path above has
			-- always been checked this way; the fallback never was.
			-- Bounded, because a pause that never lifts would park the run here silently --
			-- the same trap as a hanging InvokeServer. If it outlasts this, fall through
			-- and let the distance check below fail honestly.
			local unpause = os.clock() + STREAM_TIMEOUT
			while player.GameplayPaused and os.clock() < unpause do
				task.wait(POLL)
			end
			task.wait(ZONE_SETTLE)
			local root = hrp()
			arrived = root ~= nil and (root.Position - target).Magnitude < ZONE_RADIUS
			if not arrived then
				log(("PivotTo didn't stick for %s -- something is putting the character back"):format(entry.name))
			end
		end
	end

	if arrived and blind then
		local deadline = os.clock() + STREAM_TIMEOUT -- give it the beat it needs to replicate
		while not zoneSpawn(entry) and os.clock() < deadline do
			task.wait(POLL)
		end
		if zoneSpawn(entry) then
			-- Re-verify the second hop the same way as the first: goTo only reports that
			-- PivotTo was CALLED, and the server can bounce this hop too.
			local target2 = zoneTarget(entry)
			arrived = goTo(CFrame.new(target2 + Vector3.new(0, ZONE_LIFT, 0)), true)
			if arrived then
				task.wait(ZONE_SETTLE)
				local root = hrp()
				arrived = root ~= nil and (root.Position - target2).Magnitude < ZONE_RADIUS
			end
		end
	end
	return arrived
end

-- grabbing ----------------------------------------------------------------------
-- Every one of these gates is enforced by the CLIENT, which is us, so every one can be
-- opened. Range is the one that cost us a whole run: out of it there is no press to
-- fire at all, and InputHoldBegin on an out-of-range prompt is a no-op that reports
-- nothing back.
local function openGates(prompt)
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = math.max(prompt.MaxActivationDistance, GRAB_REACH)
	prompt.Enabled = true
end

-- Gone from the tree = the server took it. Someone else taking it first reads as a
-- success too, which costs nothing here: the count is off by one but the loop only
-- cares about the failures.
local function vanished(item, seconds)
	local deadline = os.clock() + seconds
	repeat
		if item.Parent == nil then
			return true
		end
		task.wait(0.05)
	until os.clock() >= deadline
	return item.Parent == nil
end

-- Asked only after a grab was refused, which is the one moment the answer matters -- so it
-- walks the tree a couple of times a trip, not on a beat. No connections to leak, and no
-- guessing at a path: any visible on-screen text saying it will do.
--
-- This is what turns the full-carry guess into a fact. Without it the script proves the bag
-- is full by pressing until the server has refused FULL_STREAK items, and in a game that
-- answers a full-bag pickup with a Robux upsell, every one of those presses is a popup.
local function sawFullNotice()
	local gui = player:FindFirstChild("PlayerGui")
	if not gui then
		return false
	end
	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("TextLabel") and d.Visible and d.TextTransparency < 1 and d.Text:lower():find(FULL_NOTICE) then
			return true
		end
	end
	return false
end

local hasFPP = typeof(fireproximityprompt) == "function"
local hasVIM, vim = pcall(game.GetService, game, "VirtualInputManager")

-- Three ways to press E, escalating. They are NOT equivalent, which is the whole
-- reason for trying more than one:
--
--   fireproximityprompt : executor-only, instant, ignores HoldDuration. It triggers the
--                         prompt SERVER-side -- so a game whose pickup lives in a
--                         LocalScript watching PickupPrompt.Triggered never hears it.
--   InputHoldBegin/End  : plain Roblox API, and it drives the real input path, so the
--                         client's own Triggered fires too. Needs you in range, which
--                         openGates() has just seen to.
--   VirtualInputManager : an actual key press. Slowest, wants the window focused, and
--                         the only one a game cannot tell from you doing it by hand.
local METHODS = {
	{
		name = "fireproximityprompt",
		ok = hasFPP,
		run = function(prompt)
			pcall(fireproximityprompt, prompt, 1)
		end,
	},
	{
		name = "InputHoldBegin",
		ok = true,
		run = function(prompt)
			prompt:InputHoldBegin()
			task.wait(prompt.HoldDuration + 0.1)
			if prompt.Parent then
				prompt:InputHoldEnd()
			end
		end,
	},
	{
		name = "VirtualInputManager",
		ok = hasVIM,
		run = function(prompt)
			local key = prompt.KeyboardKeyCode
			pcall(function()
				vim:SendKeyEvent(true, key, false, game)
				task.wait(prompt.HoldDuration + 0.2)
				vim:SendKeyEvent(false, key, false, game)
			end)
		end,
	},
}

-- Learned once, then used alone. Until then every item costs one GRAB_WAIT per method,
-- which is the price of finding out and is paid only for the first item or two.
local grabMethod
local settle = ARRIVE_WAIT
local lastLandLog = 0 -- throttle for the "teleport isn't landing" line below

local function grabItem(item)
	-- Three marks, not one: "stuck at: grab X" told us the item but not which half of the
	-- grab, and the two halves have completely different causes.
	step("grab " .. item.Name .. " / move")
	if not goTo(item:GetPivot() + Vector3.new(0, HEIGHT_OFFSET, 0)) then
		return false
	end
	step("grab " .. item.Name .. " / prompt")
	dumpModel(item)
	local prompt = item:FindFirstChildWhichIsA("ProximityPrompt", true)
	-- A model streams in shell-first, so on a zone we only just arrived at the prompt can be
	-- a beat behind the part we teleported onto. Worth polling rather than deciding on one
	-- look: no prompt reads as a refusal, and refusals are what the full-carry detector
	-- counts -- two of them and we'd bank on a bag that isn't full.
	if not prompt then
		local deadline = os.clock() + PROMPT_WAIT
		repeat
			task.wait(POLL)
			prompt = item:FindFirstChildWhichIsA("ProximityPrompt", true)
		until prompt or not item.Parent or os.clock() >= deadline
	end
	if not prompt then
		-- Still waits: if the pickup is a Touched volume, standing on it IS the grab,
		-- and the vanish-check reports that just as well.
		local got = vanished(item, GRAB_WAIT)
		probe(item, nil, got)
		return got
	end
	openGates(prompt) -- before any of them, including one we already know works
	local before = cash()
	local function earned()
		local after = cash()
		return after and before and (after - before) or nil
	end

	-- Hoisted out of both press paths, because what follows it has to happen after the wait
	-- and before the press either way.
	task.wait(settle)
	-- The same "a teleport is a REQUEST" check travelToZone does, one level down. Costs
	-- nothing here -- the settle wait has just happened -- and it separates "the server
	-- refused this item" from "we never got there", which are the two things this script
	-- must never confuse: refusals are what the full-carry detector counts.
	local root = hrp()
	local pivotOk, pivot = pcall(item.GetPivot, item)
	if not root or not pivotOk or (root.Position - pivot.Position).Magnitude > ARRIVE_NEAR then
		-- Per item, so throttled: when this fires it fires for everything, and a hundred
		-- identical lines is a worse diagnostic than one every five seconds.
		if os.clock() - lastLandLog > 5 then
			lastLandLog = os.clock()
			log("teleport isn't landing (" .. item.Name .. ") -- skipping rather than pressing at nothing")
		end
		return false
	end

	step("grab " .. item.Name .. " / press")
	if grabMethod then
		grabMethod.run(prompt)
		local got = vanished(item, GRAB_WAIT)
		if got then
			-- Down a quarter step, so the wait keeps drifting back toward the shortest
			-- one that still works instead of parking at whatever the worst item needed.
			settle = math.max(ARRIVE_WAIT, settle - SETTLE_STEP / 4)
		elseif item.Parent then
			-- The retry below exists only to tell a pickup cooldown from a full bag. If the
			-- game has just said on screen which it is, spending a second press to find out
			-- is another "buy a bigger backpack" popup for information we already have.
			if sawFullNotice() then
				probe(item, prompt, false, earned())
				return false
			end
			-- One more go at the SAME item. A pickup cooldown and a full bag both refuse
			-- the first press; only the cooldown lets the second one through, and taking
			-- the wrong one for the other is a trip to spawn we didn't need.
			task.wait(RETRY_WAIT)
			grabMethod.run(prompt)
			got = vanished(item, GRAB_WAIT)
			if got and settle < SETTLE_MAX then
				settle = math.min(settle + SETTLE_STEP, SETTLE_MAX)
				log(("first press missed -- standing %.2fs before pressing from now on"):format(settle))
			end
		end
		probe(item, prompt, got, earned())
		return got
	end

	for _, method in ipairs(METHODS) do
		if method.ok then
			method.run(prompt)
			if vanished(item, GRAB_WAIT) then
				grabMethod = method
				log("grab method: " .. method.name .. " -- using that from here on")
				probe(item, prompt, true, earned())
				return true
			end
		end
	end
	probe(item, prompt, false, earned())
	return false
end

-- Go to base, hand the loot in, and only then sell it if you asked for that. Three steps
-- in that order for a reason: selling reads the BACKPACK, so a deposit first would leave
-- nothing to sell -- and with Auto sell off, stopping after the deposit is exactly the
-- "bank it, don't sell it" the crafting case wants.
local function bank()
	step("bank")
	if not TP_SPAWN then
		log("no TeleportToSpawn remote -- nothing to bank with")
		return false
	end
	local ok = callTimed(TP_SPAWN, REMOTE_TIMEOUT)
	if not ok then
		log(TP_SPAWN.Name .. " didn't take -- banking anyway, the deposit is the part that matters")
	end

	-- Wait for the SERVER to agree we've left, not for a fixed second. The deposit is
	-- refused while this attribute is still true, and it is the server that clears it --
	-- so this is the one wait in the trip that actually gates anything.
	local deadline = os.clock() + BANK_WAIT
	while player:GetAttribute(IN_ZONE_ATTR) == true and os.clock() < deadline do
		task.wait(POLL)
	end

	if autoSell and SELL_ALL then
		callTimed(SELL_ALL, REMOTE_TIMEOUT) -- before the deposit: it sells out of the backpack
	end

	if DEPOSIT then
		-- The controller's own retry count and beat. It answers true when the loot went in.
		for _ = 1, 3 do
			local sent, res = callTimed(DEPOSIT, REMOTE_TIMEOUT)
			if sent and res == true then
				break
			end
			task.wait(0.25)
		end
	else
		log("no ResetBackpackLoadAtBase remote -- relying on the game's own deposit")
		task.wait(BANK_WAIT) -- give its retry chain the room it needs
	end

	-- Whether the BAG EMPTIED, not whether a remote accepted the call. Every remote here
	-- accepts; handing the loot over is the thing we were actually asking for.
	if carryFull(true) ~= nil then
		return carryLoad == 0
	end
	return ok
end

-- ui ---------------------------------------------------------------------------
-- ponytail: the hand-rolled widget kit is gone. WindUI already ships rows, toggles,
-- dropdowns, drag, resize and topbar buttons, so there is nothing here worth owning.
-- Fetched at runtime, nothing vendored -- which does make this file executor-only now,
-- because Studio blocks HttpGet.
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a
-- restyle is one file and not sixteen. Fetched here rather than installed by the loader,
-- so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Cut Grass", -- fallback until the live name lands
	folder = "CutGrass", -- unchanged: renaming it orphans configs already saved in-game
	size = UDim2.fromOffset(520, 400),
	key = KEY_TOGGLE,
	hideSearchBar = true,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Farm", Icon = "solar:leaf-bold" })

-- Box + BoxBorder are what turn a bare header into a card: WindUI paints the surface from
-- its SectionBox theme tokens, so this tracks the active theme instead of pinning colors.
local farm = Tab:Section({
	Title = "Farm",
	Desc = "Pick where and what, then flip it on",
	Icon = "solar:leaf-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})

local extras = Tab:Section({
	Title = "Extras",
	Desc = "One-shot moves and the click loop",
	Icon = "solar:widget-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})

-- The one status line, same as before, now a Paragraph whose Desc gets rewritten. WindUI
-- has no per-row color, so the old GOOD/BAD tinting is gone and the wording carries it.
local status = Tab:Paragraph({ Title = "Status", Desc = "idle" })

local function say(text)
	status:SetDesc(text)
end

-- dropdown -----------------------------------------------------------------------
-- Both lists are multi-select and both are rebuilt from the world rather than typed in, so
-- ticks are stored by NAME: keying on the entry tables would silently drop every tick each
-- time a list rebuilds.
--
-- `items` stays a separate ordered array because the order is load-bearing -- zones are
-- highest-first and the farm walks them in that order, which the dropdown's own selection
-- order does not preserve.
local zoneDrop = { items = {}, chosen = {} }
lootDrop = { items = {}, chosen = {} }

-- Values are {Title=, Desc=} tables so a row can carry its hint (how much loot is standing
-- in a zone, what a loot type sells for), which means the callback hands those tables back
-- and the Title is the name.
local function picked(d, values)
	table.clear(d.chosen)
	for _, v in ipairs(values) do
		d.chosen[typeof(v) == "table" and v.Title or v] = true
	end
end

-- Ticked entries in list order. Rebuilt per cycle so a zone that stops existing drops out
-- on its own instead of erroring mid-farm.
local function ordered(d)
	local out = {}
	for _, entry in ipairs(d.items) do
		if d.chosen[entry.name] then
			table.insert(out, entry)
		end
	end
	return out
end

-- Each farm toggle sits directly under the list it reads. startFarm is the loop and lives
-- in the farm section far below, so it is forward declared -- these callbacks only ever
-- run on a click, long after it is assigned.
local startFarm
local zoneToggle, lootToggle

zoneDrop.ui = farm:Dropdown({
	Title = "Zone",
	Desc = "Walked highest first; the top one holding loot gets worked",
	Values = {},
	Value = {},
	Multi = true,
	AllowNone = true,
	SearchBarEnabled = true,
	Callback = function(values)
		picked(zoneDrop, values)
	end,
})

zoneToggle = farm:Toggle({
	Title = "Farm zone",
	Desc = "Take everything in the ticked zones",
	Value = false,
	Callback = function(state)
		startFarm("zone", state)
	end,
})

lootDrop.ui = farm:Dropdown({
	Title = "Loot",
	Desc = "Only Farm loot reads these",
	Values = {},
	Value = {},
	Multi = true,
	AllowNone = true,
	SearchBarEnabled = true,
	Callback = function(values)
		picked(lootDrop, values)
	end,
})

-- Untick everything in one click. The list is long enough that clearing it by hand is a
-- chore, and it's the one you re-pick most: a hunt is per-item, not a standing setting.
--
-- Select() with no argument resets a Multi dropdown to {} -- but it does NOT run the
-- Callback, so `chosen` has to be cleared here too. That table is what the walk actually
-- reads; the tick marks are what you look at. They have to be cleared together or the two
-- disagree, which is the bug where a cleared list keeps farming the old picks.
farm:Button({
	Title = "Clear loot picks",
	Desc = "Untick every loot type",
	Icon = "solar:eraser-bold",
	Callback = function()
		local n = 0
		for _ in pairs(lootDrop.chosen) do
			n = n + 1
		end
		table.clear(lootDrop.chosen)
		lootDrop.ui:Select()
		-- startFarm refuses to START Farm loot with nothing ticked; clearing mid-run makes
		-- exactly that state, and wanted() then matches nothing -- so the sweep would walk
		-- every zone forever and take nothing, looking busy the whole time. Same guard,
		-- applied at the other end.
		if farmMode == "loot" then
			startFarm("loot", false)
			say(("cleared %d loot pick(s) -- Farm loot stopped, nothing left to hunt"):format(n))
			return
		end
		say(n > 0 and ("cleared %d loot pick(s)"):format(n) or "nothing was ticked")
	end,
})

lootToggle = farm:Toggle({
	Title = "Farm loot",
	Desc = "Take only the ticked loot types, and walk past the rest",
	Value = false,
	Callback = function(state)
		startFarm("loot", state)
	end,
})

-- Off is "keep it, I'm crafting with it": the farm still banks -- it has to, or the bag
-- fills and nothing else can be picked up -- it just deposits the loot at base and stops
-- there instead of selling it on. Bank now does whatever this says too.
farm:Toggle({
	Title = "Auto sell",
	Desc = "Off: still banks at base, but keeps the loot instead of selling it",
	Value = AUTO_SELL,
	Callback = function(state)
		autoSell = state
	end,
})

-- WindUI's Refresh rebuilds the menu rows, reassigns Values, and re-derives each row's
-- selected state by matching the still-ticked Titles against the new names -- so a rebuild
-- keeps your picks as long as the names survive it.
--
-- It is also expensive: every row is a fresh frame, icon, tween and signal, and under
-- streaming the Zones folder churns the whole time the farm is teleporting around, so
-- watchZones would fire that rebuild every half second for the length of a run. That is
-- where the frame drops came from. The items array is the part the walk actually reads, so
-- that always updates; the menus are only for looking at, and they redraw once the farm
-- stops.
local menusStale = false

-- Streaming re-adds the SAME zones over and over, and a rebuild for a list that came back
-- identical is the entire cost with none of the benefit. Worse than wasted work: WindUI
-- registers every row's connections in a table it only ever clears when the window is
-- destroyed, so an hour of pointless rebuilds is an hour of growth. That is what made a
-- long run get progressively slower.
--
-- The names are the list. Hints (loot counts) are a snapshot either way, so they aren't
-- worth a rebuild on their own -- Rescan forces one when you want them fresh.
local function fill(d, items, hint, force)
	d.items = items -- always: this is the array the walk reads
	local names = {}
	for _, entry in ipairs(items) do
		table.insert(names, entry.name)
	end
	local sig = table.concat(names, "\0")
	if sig == d.sig and not force then
		return
	end
	if farming then
		menusStale = true -- redraw once the farm stops; the walk doesn't need the menu
		return
	end
	d.sig = sig
	local values = {}
	for _, entry in ipairs(items) do
		table.insert(values, { Title = entry.name, Desc = hint(entry) })
	end
	d.ui:Refresh(values)
end

local function refresh(force)
	menusStale = false
	fill(zoneDrop, scanZones(), function(entry)
		-- Only ever a snapshot: under streaming, a zone you aren't standing in has no loot
		-- client-side, so a big list of "empty" from base means nothing.
		local n = #lootIn(entry)
		local hint = n > 0 and (n .. " loot") or "empty"
		-- Only worth saying when it ISN'T the world you're in, which after the filter in
		-- scanZones only happens when we couldn't tell which world that is. Otherwise it's
		-- the same six characters on every row.
		local w = entry.world or worldOfZone(entry.index)
		local here = tonumber(player:GetAttribute("CurrentWorld"))
		return (w and w ~= here) and ("World " .. w .. " -- " .. hint) or hint
	end, force)
	-- ReplicatedStorage.Loot is a static template folder, so this settles on the first call
	-- and the signature check makes every later one free. It has the most rows of the two.
	fill(lootDrop, scanLoot(), function(entry)
		return entry.price and ("$" .. entry.price) or nil
	end, force)
	local here = tonumber(player:GetAttribute("CurrentWorld"))
	say(("%d zones, %d loot types%s"):format(
		#zoneDrop.items,
		#lootDrop.items,
		here and (" -- in World " .. here) or ""
	))
end

farm:Button({
	Title = "Rescan",
	Desc = "Rebuild both lists and re-count the loot standing in each zone",
	Icon = "solar:refresh-bold",
	Callback = function()
		refresh(true) -- the one place that redraws even when the names haven't changed
	end,
})

-- The Zones folder swapping its children IS a world change, so this is all the world
-- handling there is. Debounced, because a world load adds them one at a time.
local pendingRefresh = false
local function bump()
	if pendingRefresh or stopped then
		return
	end
	pendingRefresh = true
	-- Coalesce hard. Streaming fires these in bursts and every one of them used to cost
	-- a scan; the signature check downstream makes the usual case free anyway.
	task.delay(WATCH_DEBOUNCE, function()
		pendingRefresh = false
		if not stopped then -- the window may have closed during the debounce
			refresh()
		end
	end)
end

local watchedFolder
local function watchZones()
	-- Attach to a Zones folder, once. Re-callable: if the folder streams in after startup or
	-- is swapped wholesale, the workspace watcher below calls this again with the new one --
	-- without it a streaming client that joined before Zones existed would sit empty forever.
	local function attach(folder)
		if not folder or folder == watchedFolder then
			return
		end
		watchedFolder = folder
		-- Descendant, not Child. In the old flat layout the zones WERE this folder's children;
		-- now they stream in one level down, inside the W containers, and a ChildAdded watcher
		-- on the top folder never hears about them. WATCH_DEBOUNCE makes the wider net
		-- affordable: a world load fires these by the hundred and they coalesce into one scan.
		-- ...but only for the two levels that can BE a zone: a child of the Zones folder, or a
		-- child of a W container. Everything deeper is a zone's own parts streaming in, and
		-- there are thousands of those -- this check is what keeps the wider net cheap.
		local function maybeZone(inst)
			local p = inst.Parent
			if p == folder or (p and p.Parent == folder) then
				bump()
			end
		end
		track(folder.DescendantAdded:Connect(maybeZone))
		track(folder.DescendantRemoving:Connect(maybeZone))
		bump() -- the folder may have arrived already full
	end

	attach(zonesFolder())
	track(workspace.ChildAdded:Connect(function(child)
		if child.Name == "Zones" then
			attach(child)
		end
	end))
	-- A world change swaps which zones are YOURS without necessarily touching the folder:
	-- every unlocked world's zones can already be sitting there loaded. So the list has to
	-- follow the attribute the server sets on you, not just the tree.
	track(player:GetAttributeChangedSignal("CurrentWorld"):Connect(bump))
end

-- farm ----------------------------------------------------------------------------
local grabbed, deadBanks = 0, 0
-- A refusal we haven't banked on yet. Lives out here rather than inside workZone because
-- the streak that proves "full" can be split across zones, and the trip that fills the
-- carry on a zone's LAST item never reaches FULL_STREAK anywhere at all.
local refusedSinceBank = false
local carrySize, trips = nil, 0 -- capacity is measured on the first full trip, not set here
-- Bumped on every start, so switching modes retires the running thread instead of leaving
-- two farms teleporting the same character in opposite directions.
local farmGen = 0
local lastMissing -- last "these never turned up" list printed, so it prints on change only

-- Takes the mode, not a boolean -- nil is off. The two toggles are mutually exclusive, so
-- whichever one isn't the mode gets pushed off here. Set(value, false) suppresses that
-- toggle's callback, which is what stops the push from bouncing straight back in.
local function setFarming(mode)
	farmMode = mode or nil
	farming = farmMode ~= nil
	zoneToggle:Set(farmMode == "zone", false)
	lootToggle:Set(farmMode == "loot", false)
	if not farming and menusStale then
		refresh() -- catch the menus up on whatever the world did while we were busy
	end
end

-- Every bank goes through here, so the "is banking even working" question is asked in one
-- place and asked the right way: did the BAG EMPTY. It used to be "did the next trip grab
-- anything", which is a different question with the same answer most of the time -- but not
-- in Farm loot, where the sweep banks and then climbs into a zone holding none of your
-- ticked types. Two of those and the farm switched itself off mid-sweep, which is the
-- "it just stops" -- the bank had worked fine both times.
local function bankNow(reason)
	say(reason)
	refusedSinceBank = false
	deadBanks = bank() and 0 or deadBanks + 1
	if deadBanks >= BANK_GIVEUP then
		say("banking isn't emptying the bag -- stopped, flip it back on to retry")
		log(
			("%d banks and the bag never emptied. Check the deposit remote in the startup lines above -- "):format(
				BANK_GIVEUP
			) .. "if it says NOT FOUND, that's the whole problem."
		)
		setFarming(nil)
		return false
	end
	return true
end

-- Returns how many it actually got, which is what makes the banking check possible:
-- a trip to spawn followed by another zero means the loot never sold.
local function workZone(entry, loot, mine)
	local got, streak = 0, 0
	trips = trips + 1
	-- Every RECHECK-th trip forgets the measured capacity and proves it the slow way
	-- again, so a bag upgrade is noticed instead of us banking early forever.
	local trustCarry = carrySize and trips % RECHECK ~= 0
	-- Arriving full is the case the per-item check can't cover: it only ever runs after a
	-- successful grab, so a trip that starts full presses first and asks afterwards -- one
	-- refusal, one upsell popup, and a "carry filled after 0 grab(s)" line every zone.
	-- Ask on the way in instead.
	if carryFull() and not bankNow("bag was full on arrival -- banking") then
		return got
	end
	for _, item in ipairs(loot) do
		if not farming or farmGen ~= mine then
			return got
		end
		if item.Parent then
			-- "Couldn't even try" is not "the server said no", and conflating them is what
			-- walked the farm into stopping itself. Hand the trip back instead; the walk
			-- restarts against whatever the world looks like once we're alive again.
			if not waitForChar() then
				say("no character -- waiting for respawn")
				return got
			end
			if grabItem(item) then
				got, streak, grabbed = got + 1, 0, grabbed + 1
				say(("%s  --  %d grabbed"):format(entry.name, grabbed))
				-- Read it when the server offers, count it when it doesn't. Either way
				-- the point is to bank BEFORE a press that would be refused: proving it
				-- the slow way costs two items, their retries and two upsell popups
				-- EVERY trip, which on a one-item carry is most of the run.
				local full = carryFull()
				if full == nil then
					full = trustCarry and got >= carrySize
				end
				if full then
					bankNow(("carry full (%d/%d) -- banking"):format(carryLoad or got, carryCap or carrySize))
					return got
				end
			else
				refusedSinceBank = true -- cycle banks on this if the zones run out first
				-- The slot count is the server's own answer and the notice is its wording
				-- of the same thing, so either one is worth the whole streak. FULL_STREAK
				-- stays for when neither is available.
				streak = (carryFull() or sawFullNotice()) and FULL_STREAK or streak + 1
				if streak >= FULL_STREAK then
					if got > 0 then
						carrySize = got -- measured, never configured
					end
					log(("carry filled after %d grab(s) this trip"):format(got))
					bankNow("carry full -- banking")
					return got
				end
			end
		end
	end
	return got
end

-- One walk down the ticked zones, highest first. What happens on a zone that HAS loot is
-- the difference between the modes: Farm zone works it and hands back so the next walk
-- restarts at the top, Farm loot works it and keeps going down.
local function cycle(mine)
	local walk = ordered(zoneDrop)
	-- Hunting a specific loot type with no zone ticked means "wherever it is" -- and the
	-- list is already only this world's zones, filtered in scanZones, so this is the whole
	-- of it. That filter is also what stops the climb starting at Zone_1 and hauling you
	-- out of World 5.
	if #walk == 0 and farmMode == "loot" then
		walk = zoneDrop.items
	end
	-- Farm loot CLIMBS: lowest ticked zone first, up to the highest, then round again.
	-- ordered() hands back the value ordering Farm zone wants, and the two want opposite
	-- things, so this is the one place the walks differ. Built as a reversed copy, never
	-- reversed in place -- `walk` may BE zoneDrop.items.
	if farmMode == "loot" then
		local up = {}
		for i = #walk, 1, -1 do
			table.insert(up, walk[i])
		end
		walk = up
	end
	-- Nothing to walk. This used to switch the farm off, which is wrong twice over: the
	-- Zones folder empties and refills on its own under streaming and on a world change, so
	-- the condition is usually temporary -- and a farm that turns itself off can't notice
	-- when it stops being true. Wait and walk again; the status line says why it's idle.
	if #walk == 0 then
		say("tick a zone first")
		task.wait(IDLE)
		return
	end
	-- Everything the walk laid eyes on. Only a zone we actually stood in contributes, which
	-- is the honest scope: a type missing from here is missing from the zones you ticked,
	-- not from the game.
	local seen = {}
	local took = 0 -- items this walk actually got, which only a sweep can accumulate
	for _, entry in ipairs(walk) do
		if not farming or farmGen ~= mine then
			return
		end
		if not entry.zone.Parent then
			refresh() -- world changed under us; the walk restarts on the new list
			return
		end
		if not waitForChar() then
			say("no character -- waiting for respawn")
			return -- the walk restarts from the top; nothing here is worth doing dead
		end
		say("entering " .. entry.name)
		step("travel to " .. entry.name)
		-- Working a zone we never reached is the whole failure: every item is out of range,
		-- every press misses, and the run looks alive while doing nothing. Skip it and try
		-- the next one -- the walk comes round again in a few seconds anyway.
		if not travelToZone(entry) then
			say("couldn't reach " .. entry.name .. " -- moving on")
			continue
		end
		task.wait(ZONE_SETTLE)
		step("scan " .. entry.name)
		local loot = waitForLoot(entry, STREAM_TIMEOUT)
		-- After waitForLoot, not before: it has already spent STREAM_TIMEOUT letting the
		-- zone load, so this is the most the client will ever know about what's here.
		for name in pairs(namesIn(entry)) do
			seen[name] = true
		end
		if #loot > 0 then
			local got = workZone(entry, loot, mine)
			took = took + got
			-- Farm zone hands back here so the next walk restarts at the top: higher zones
			-- hold better loot, so the moment one respawns anything it should be taken, and
			-- the lower zones are only ever a fallback. Farm loot has no such ranking --
			-- you're hunting types, not value -- so it climbs on to the next zone and sweeps
			-- the lot before starting over. Banking mid-sweep just resumes at the next zone;
			-- whatever was left behind is taken on the following pass.
			if farmMode ~= "loot" then
				if got == 0 then
					task.wait(IDLE) -- a zone full of loot that won't come off the ground;
				end -- park instead of hammering it at TP speed
				return
			end
		end
	end
	-- A refusal still outstanding at the end of a walk means the carry is full and the zones
	-- ran out before FULL_STREAK did -- which used to leave us wandering full forever,
	-- pressing E at loot the server won't hand over and collecting one "buy a bigger
	-- backpack" prompt per press.
	if refusedSinceBank then
		bankNow("carry looks full -- banking")
		return
	end
	if farmMode ~= "loot" then
		say("all ticked zones empty -- waiting")
		task.wait(IDLE)
		return
	end
	-- A finished sweep, productive or not. Which ticked types never turned up in ANY zone is
	-- the useful half: those are picks no ticked zone spawns, and no amount of waiting will
	-- produce one. The rest did exist and were simply gone by the time we got there, which
	-- waiting DOES fix. Only worth trusting now that the sweep visits every zone -- while
	-- the walk stopped at the first zone with loot, this never looked past it.
	local missing = {}
	for _, entry in ipairs(ordered(lootDrop)) do
		if not seen[entry.name] then
			table.insert(missing, entry.name)
		end
	end
	if #missing == 0 then
		say(took > 0 and ("swept %d zones -- %d grabbed"):format(#walk, grabbed) or "ticked loot all gone -- waiting")
	else
		local shown = table.concat(missing, ", ", 1, math.min(#missing, 4))
		if #missing > 4 then
			shown = shown .. " +" .. (#missing - 4) .. " more"
		end
		say("not in any ticked zone: " .. shown)
		local all = table.concat(missing, ", ")
		if all ~= lastMissing then -- every sweep says it; the console only needs the change
			lastMissing = all
			log("none of these spawned anywhere on the walk: " .. all)
		end
	end
	if took == 0 then
		task.wait(IDLE) -- nothing to take anywhere; don't re-sweep at teleport speed
	end
end

-- Both toggles run the same loop; the mode is the whole difference and lives in farmMode,
-- which is what the loot filter reads. Flipping one on flips the other off, so switching
-- mode is a single click.
function startFarm(mode, state)
	if not state then
		-- setFarming's own Set() calls are silent, so an off-click that reaches here for a
		-- mode that isn't running is a stale event and has nothing to stop.
		if farmMode == mode then
			setFarming(nil)
			say(("stopped -- %d grabbed"):format(grabbed))
		end
		return
	end
	if mode == "loot" and #ordered(lootDrop) == 0 then
		setFarming(farmMode) -- refused: put the toggles back the way they were
		say("tick some loot first")
		return
	end
	setFarming(mode)
	deadBanks = 0
	farmGen = farmGen + 1
	local mine = farmGen
	-- Its own thread, which is the entire point: if the farm thread is parked in a yield it
	-- cannot report anything, and everything about this script's output goes quiet at once.
	-- This one is still running, and it knows the last step that started.
	task.spawn(function()
		while farming and farmGen == mine do
			task.wait(WATCHDOG)
			if farming and farmGen == mine and os.clock() - markAt > WATCHDOG then
				log(("stuck %.0fs at: %s"):format(os.clock() - markAt, mark))
			end
		end
	end)

	task.spawn(function()
		-- One bad lap is not a reason to end the run. A zone destroyed mid-walk, a model
		-- that streamed out from under a scan, a remote that timed out -- all of those are
		-- fixed by starting the walk again against whatever the world looks like now, which
		-- is what the loop does anyway. Only a fault that repeats every single lap is
		-- actually fatal, and that one still stops rather than spinning in your face.
		local errs = 0
		while farming and farmGen == mine do
			local ok, err = pcall(cycle, mine)
			if ok then
				errs = 0
			else
				errs = errs + 1
				log(("cycle error (%d of %d): %s"):format(errs, ERR_GIVEUP, tostring(err)))
				if errs >= ERR_GIVEUP then
					-- Only this generation may pull the plug: a newer farm may have started
					-- while this retiring one was mid-cycle, and setFarming(nil) here would
					-- shut IT down instead.
					if farmGen == mine then
						setFarming(nil)
						say("erroring every lap -- stopped, see console (F9)")
					end
					return
				end
				say("hiccup -- restarting the walk")
				task.wait(IDLE)
			end
			task.wait(0.1)
		end
	end)
end

-- wiring ---------------------------------------------------------------------------
-- The two farm toggles are built up with their dropdowns; what's left is the one-shots.
extras:Button({
	Title = "Teleport to top zone",
	Icon = "solar:map-arrow-up-bold",
	Callback = function()
		local first = ordered(zoneDrop)[1] -- highest ticked; the farm toggles visit the rest
		if not first then
			say("tick a zone first")
			return
		end
		say(travelToZone(first) and ("at " .. first.name) or "teleport failed")
	end,
})

extras:Button({
	Title = "Bank now",
	Icon = "solar:safe-2-bold",
	Callback = function()
		say(bank() and "at base" or "banking failed -- see console (F9)")
	end,
})

-- auto click -------------------------------------------------------------------------
-- Independent of the farm: strength clicks don't care where you are, so this gets its own
-- flag and its own generation counter rather than riding farmMode. Locked outright when
-- the remote isn't there, which beats a toggle that flips on and does nothing.
local clicking, clickGen, clickRate = false, 0, CLICK_RATE

extras:Toggle({
	Title = "Auto click",
	Desc = "Fires StrengthService.ClickRequested on a beat",
	Value = false,
	Locked = CLICK == nil,
	LockedTitle = "No ClickRequested remote in this game",
	Callback = function(state)
		clicking = state
		if not state then
			return
		end
		-- gen, so flipping off and back on inside one interval doesn't leave the sleeping
		-- thread alive alongside the new one, firing at double rate.
		clickGen = clickGen + 1
		local mine = clickGen
		task.spawn(function()
			while clicking and clickGen == mine do
				pcall(call, CLICK) -- the server refusing is the normal case, not a reason to stop
				task.wait(clickRate) -- read live, so the slider lands mid-run
			end
		end)
	end,
})

extras:Slider({
	Title = "Click every",
	Desc = "Seconds between clicks",
	Value = { Min = 0.1, Max = 1, Default = CLICK_RATE },
	Step = 0.1,
	Callback = function(v)
		clickRate = v
	end,
})

dumpKnit()
local function describe(remote, missing)
	return remote and (remote.ClassName .. " " .. remote:GetFullName()) or missing
end

-- The deposit is the one that decides whether banking works at all, so it gets named here
-- rather than discovered by watching the bag sit at 20/20.
log(("remotes -- deposit: %s   carry: %s   sell: %s"):format(
	describe(DEPOSIT, "NOT FOUND (banking will not empty the bag)"),
	describe(CARRY, "NOT FOUND (falling back to counting refusals)"),
	describe(SELL_ALL, "NOT FOUND (Auto sell does nothing)")
))
log(("remotes -- spawn: %s   zone: %s   click: %s"):format(
	describe(TP_SPAWN, "NOT FOUND (can't bank)"),
	describe(TP_ZONE, "NOT FOUND (PivotTo only)"),
	describe(CLICK, "NOT FOUND (Auto click locked)")
))
local available = {}
for _, method in ipairs(METHODS) do
	table.insert(available, method.name .. (method.ok and "" or " (unavailable)"))
end
log("grab methods, in order: " .. table.concat(available, " -> "))
log("auto sell " .. (autoSell and "ON" or "OFF -- Bank now still sells by hand"))

refresh()
watchZones()

-- close ----------------------------------------------------------------------------
-- The red button destroys the window after WindUI's own confirm dialog, so teardown hangs
-- off OnDestroy rather than a close handler of our own. ponytail: rerun the script to come
-- back.
-- One idempotent teardown, shared by the red button and the getgenv stop. Flags stop the
-- loops (each checks its own), `stopped` bails the debounced refresh, and disconnecting the
-- tracked connections is what stops a re-paste stacking listeners on the old panel.
local function stopAll()
	stopped = true
	-- Set directly rather than through setFarming: the toggles are on their way out.
	farming, farmMode, clicking = false, nil, false
	for _, c in ipairs(conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(conns)
end

Window:OnDestroy(stopAll)

if getgenv then
	getgenv().cutGrassStop = function()
		stopAll()
		pcall(function()
			Window:Destroy()
		end)
		getgenv().cutGrassStop = nil
	end
end
