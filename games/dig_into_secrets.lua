--[[ Dig Into Secrets -- 119409763193569

     ZONE   : one stage out of workspace.GeneratedStages, or ALL STAGES, which works
              the whole mine richest first -- the stage holding the most valuable
              spawn, then the next, and so on down. Deeper is usually richer but not
              reliably (a dump run had Stage 91 at $2.5T and Stage 92 at $1.8T), which
              is why the route sorts by value and not by depth.

              With three backpack slots the aim is to fill them from the best stage on
              the map rather than the nearest, so every lap restarts at the top of that
              route: only when the richest stage is picked clean does it drop to the
              next one down.
     LIST   : the mine STREAMS. A stage you haven't been near isn't replicated to you
              at all, so the list starts as whatever is around you -- twenty-odd
              stages, not the whole mine -- and there is no trick that loads the rest.
              RequestStreamingAround is a HINT the server may ignore, and past some
              distance it does; flying down the shaft to read every stage works but
              costs a minute up front, every session. Both were tried and dropped.

              So the list is EARNED instead. Standing in a stage streams its neighbours
              in for free, and the farm is standing in stages all day: every time it
              arrives somewhere it records what's now resident. Take the richest known
              stage, work it, notice what turned up while you were there, re-sort. The
              route walks itself deeper, the list grows as you mine, and nothing is
              paid for up front. A stage that later streams back out is still on the
              list -- its pivot is remembered, and teleporting there brings it back.
     COLLECT: the Ores folder is not only ores. Every spawn in it carries a SpawnType
              attribute -- Ore, Egg, LuckyBox, MysteryEntrance -- and tick-boxes decide
              which ones the sweep takes. Eggs and lucky boxes are the "rare loot
              timers" board out on the surface: they're on a countdown, one at a time,
              and everyone on the server is racing you, so they're taken FIRST and
              ores are worked afterwards by value.
     FARM   : sweep the stage BEST FIRST -- teleport onto a spawn, hold its Collect
              prompt until the server takes it, move to the next. Highest value goes
              in the backpack first, which matters because the backpack holds three.
     FULL   : the backpack is three slots by default (MineConfig.DefaultBackpackCapacity)
              and MineBackpackCapacity once you've upgraded it. When it fills, the
              script fires Mine_Return -- the game's own Surface button -- rather than
              walking, then sweeps again once the ores are gone. Eggs are exempt: they
              pay out a pet, not an ore, so a full backpack doesn't block one.
     SELL   : optional, and the loop needs it: back at the surface with a full
              backpack there is nothing left to collect.

              Two inventories, and this is the one thing to get right. The backpack is
              MineInventory (3 slots, what you carry underground). Surfacing empties it
              into VoidChestInventory, the surface chest, and Mine_Sell sells THAT --
              SellPop's own list is built from VoidChestInventory and nothing else. So
              the sell is done when the CHEST stops shrinking, not when the backpack
              reads empty; the backpack is already empty before the first fire.
              Favourited ores are skipped by the server, so the chest need never hit
              zero and "it stopped going down" is the only honest stop condition.

     Everything the client sends goes through ONE remote: ReplicatedStorage.Remotes.
     MessageBus, with the message name as the first argument (Shared/Net/MessageNames
     is the whole list). So there is no remote to find here -- the names are the API.

     Names and value ranking come from the game's own MineConfig.getSpawnDisplayInfo,
     which covers all four spawn types, so anything an update adds is named and priced
     correctly the moment the module updates.

     MysteryEntrance is deliberately NOT collectable here: taking it teleports you into
     a separate timed mine with its own stages, which is a different farm, not a step
     in this one.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().digSecretsStop() ]]

-- config ---------------------------------------------------------------------
-- The server decides where you are, and it finds out a round trip after you do. Every
-- wait below is that gap. Raise SETTLE first if prompts fire but nothing is collected:
-- the prompt's 10-stud range check runs against where the SERVER thinks you stand.
local SETTLE = 4 -- ping multiples to wait after a teleport
local GRAB_TIMEOUT = 4 -- seconds on one ore before giving up. A prompt someone else won
-- looks exactly like a prompt that isn't loaded, and both cost the same to skip.
local DWELL = 1.5 -- seconds between sweeps of the same stage. Ores live 90-120s and
-- respawn on their own, so an empty stage is a wait, not a reason to leave.
local SELL_RETRY = 0.4 -- seconds between Mine_Sell fires while the inventory drains
local SELL_TIMEOUT = 6 -- give up selling. Not standing on the pad looks like this.
local DEPOSIT_WAIT = 3 -- seconds to let surfacing move the backpack into the chest
-- before reading the chest. Snapshotting mid-deposit makes every test in sell() wrong.
local ARRIVE = 3 -- seconds to wait for a stage to replicate after teleporting into it.
-- Raise it if the route reports stages it can't reach; this place streams, and a stage
-- that has been away for a while takes longer to come back than one nearby.
local RELIST = 4 -- seconds between redraws of the zone list while the farm is running.
-- The list grows as you mine and it's worth seeing, but rebuilding it every time a
-- stage streams in would have the dropdown flickering under your cursor.
local RETURN_SETTLE = 1 -- seconds after Mine_Return before touching anything: the
-- server moves you, so the character is somewhere else for a moment.

-- MineConfig.DefaultBackpackCapacity. Only used when PlayerData hasn't landed yet --
-- underestimating just means an early trip to the surface, which is harmless.
local DEFAULT_CAP = 3

local KEY_TOGGLE = Enum.KeyCode.RightControl

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local player = Players.LocalPlayer
local ping = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]

if getgenv and getgenv().digSecretsStop then
	getgenv().digSecretsStop() -- re-running must not stack a second panel/loop
end

-- Kills the "Gameplay Paused" banner, which this farm otherwise flashes on screen every
-- few seconds: every teleport into a stage that hasn't replicated pauses the client.
--
-- The NOTIFICATION is all it turns off. Player.GameplayPaused still goes true, the
-- character is still frozen while the region loads, and tp() must still wait it out --
-- see the loop there. Hiding the banner and skipping that wait would just move the
-- symptom from "annoying overlay" to "grabs fire while the world is still empty".
--
-- pcall'd: it's a newer GuiService method and an older client errors on the index.
pcall(function()
	game:GetService("GuiService"):SetGameplayPausedNotificationEnabled(false)
end)

-- net ------------------------------------------------------------------------
-- One RemoteEvent for the entire game. ClientNet.send is `MessageBus:FireServer(name,
-- payload)` and nothing else, so this is the whole client protocol reimplemented.
local MessageBus = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("MessageBus")

local function send(name, payload)
	local ok, err = pcall(MessageBus.FireServer, MessageBus, name, payload)
	if not ok then
		warn("[DigSecrets] send " .. name, err)
	end
end

-- The game's own ore table -- name, value and rarity for every id. Requiring beats
-- copying: it's 25+ entries and every update adds a tier on the bottom.
local MineConfig
pcall(function()
	MineConfig = require(ReplicatedStorage.Shared.Config.MineConfig)
end)
if not MineConfig then
	warn("[DigSecrets] no MineConfig -- ranking ores by OreId instead of value")
end

local say = function() end -- replaced by the panel below

local function money(n)
	for _, unit in ipairs({ { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
		if n >= unit[1] then
			return ("$%.1f%s"):format(n / unit[1], unit[2])
		end
	end
	return "$" .. math.floor(n)
end

-- carry ----------------------------------------------------------------------
-- _G.PlayerData is the game's own client-side mirror of your save, kept up to date by
-- PlayerData_ChangeValue. MineInventory is the literal list of carried ores and
-- MineBackpackCapacity the limit, which is what the HUD's own "2/3" reads.
--
-- getrenv, not getgenv: a LocalScript's _G is the GAME's global table, and the
-- executor hands you a different one. Reading the executor's finds nothing at all.
local function playerData()
	local ok, data = pcall(function()
		local env = getrenv and getrenv()._G or _G
		return env.PlayerData
	end)
	return ok and data or nil
end

-- Returns the count AND whether it could actually be read. The second value matters:
-- failing open to 0 reads as "backpack empty", which would override the server's own
-- full verdict and leave the farm surfacing and descending forever. Callers that only
-- want the number can ignore it -- Lua truncates the extra return in every position
-- except the tail of an argument list, and no caller here passes it somewhere that
-- would misread a stray boolean.
local function carrying()
	local ok, n = pcall(function()
		local inv = playerData().MineInventory
		return type(inv) == "table" and #inv or 0
	end)
	return ok and n or 0, ok
end

-- The OTHER inventory. Surfacing moves the backpack into this one, and Mine_Sell is
-- the only thing that empties it -- see the note over sell(). Unbounded, so there is
-- no capacity twin for it.
local function chest()
	local ok, n = pcall(function()
		local inv = playerData().VoidChestInventory
		return type(inv) == "table" and #inv or 0
	end)
	return ok and n or 0
end

local function capacity()
	local ok, n = pcall(function()
		return tonumber(playerData().MineBackpackCapacity) or 0
	end)
	return (ok and n and n > 0) and n or DEFAULT_CAP
end

-- The server's own answer to "did that land", straight off the same message the game's
-- MineController listens to. ok=false with reason "full" is what makes the client pop
-- the buy-a-bigger-backpack dialog, so it IS the full signal -- no capacity arithmetic
-- to get wrong, and it covers the temp backpack bonus we can't see from here.
local full, collected = false, 0
local receipt = MessageBus.OnClientEvent:Connect(function(name, payload)
	if name ~= "Mine_CollectResult" or type(payload) ~= "table" then
		return
	end
	if payload.ok then
		collected = collected + 1
	elseif payload.reason == "full" then
		full = true
	end
end)

-- world ----------------------------------------------------------------------
local function hrp()
	local char = player.Character or player.CharacterAdded:Wait()
	return char:WaitForChild("HumanoidRootPart", 10)
end

-- Teleport is instant client-side; the server needs a round trip or two before it
-- agrees, and streaming leaves you paused with nothing loaded around you. A stage you
-- have just dropped into is the worst case for both.
local function tp(cf)
	local root = hrp()
	if not root then
		return false
	end
	root.CFrame = typeof(cf) == "Vector3" and CFrame.new(cf) or cf
	task.wait((ping:GetValue() * SETTLE) / 1000)
	while player.GameplayPaused do
		task.wait(0.1)
	end
	return true
end

-- Attributes sit on the ore Model, and on its handle part as well. Read the model,
-- fall back to a descendant, so a shape change on either side still resolves.
local function attr(inst, key)
	local v = inst:GetAttribute(key)
	if v ~= nil then
		return v
	end
	for _, d in ipairs(inst:GetDescendants()) do
		v = d:GetAttribute(key)
		if v ~= nil then
			return v
		end
	end
	return nil
end

-- One call names and prices every spawn type -- ore, egg, lucky box, mystery entrance.
-- Eggs and boxes come back with no value, which is honest: what they're worth is
-- whatever they roll. Falls back to the raw id so a missing module still reads sanely.
local function spawnInfo(spawnType, id)
	local info = MineConfig
		and MineConfig.getSpawnDisplayInfo
		and MineConfig.getSpawnDisplayInfo(spawnType, id)
	return info or { name = tostring(id), rarity = 1, value = nil }
end

-- Stage_23 is depth 23 -- the number in the name is the StageDepth attribute its ores
-- carry. Sorted numerically because a string sort puts Stage_10 in front of Stage_2.
local function stages()
	local fold = workspace:FindFirstChild("GeneratedStages")
	if not fold then
		return {}
	end
	local out = {}
	for _, stage in ipairs(fold:GetChildren()) do
		local depth = tonumber(stage.Name:match("^Stage_(%d+)$"))
		if depth then
			table.insert(out, { name = stage.Name, depth = depth, model = stage })
		end
	end
	table.sort(out, function(a, b)
		return a.depth < b.depth
	end)
	return out
end

-- known ----------------------------------------------------------------------
-- This place streams: a stage you haven't been near is not replicated to your client
-- at all, which is why the list starts at whatever is around you -- twenty-odd stages,
-- not the whole mine.
--
-- There is no trick that loads the rest. Asking the server for them with
-- RequestStreamingAround is a HINT it may ignore, and past some distance it does.
-- Flying down the shaft to read each one works but costs a minute up front, every
-- session. So neither: the farm just REMEMBERS what it has seen, and mining a stage
-- streams its neighbours in for free. Take the richest known stage, work it, notice
-- the stages that arrived while you were standing there, and the route walks itself
-- deeper on its own -- no scan, and the list is worth more every lap.
--
-- depth -> { name, pos, loot, seen }. `pos` is the remembered pivot, so a stage that
-- has since streamed out can still be travelled to; `loot` is what it held when last
-- read, used only for ordering. The sweep re-reads the real stage on arrival.
local known = {}

-- Assigned by the panel: "the list grew, redraw it". A no-op until then, so the farm
-- never has to know whether a panel exists.
local stagesChanged = function() end

-- The dropdown row that means "the whole mine", not one stage. A sentinel rather than
-- a nil `picked`, so "nothing chosen yet" stays distinguishable from "chose all".
local ALL = "*all*"

-- The Ores folder holds more than ores: Egg_*, LuckyBox_* and the mystery entrance all
-- live in it with their own Collect-shaped prompts, told apart by SpawnType. `wanted`
-- is the live tick set from the panel, so anything an update adds is left alone rather
-- than farmed by accident.
--
-- Order IS the farm, because the backpack holds three. Two levels:
--   1. eggs and lucky boxes first -- they're the surface board's "rare loot timers",
--      one at a time on a countdown, and the whole server is racing you for them.
--      Ores are still there in a minute; the egg is not.
--   2. then ores by value. Within the timed loot, by rarity.
local wanted = { Ore = true, Egg = true, LuckyBox = true }

local function lootIn(stage)
	local fold = stage:FindFirstChild("Ores")
	if not fold then
		return nil
	end
	local out = {}
	for _, model in ipairs(fold:GetChildren()) do
		local kind = attr(model, "SpawnType")
		if kind and wanted[kind] then
			local id = tonumber(attr(model, "OreId")) or 0
			local info = spawnInfo(kind, id)
			table.insert(out, {
				model = model,
				home = fold,
				id = id,
				kind = kind,
				name = info.name,
				value = info.value,
				-- Ores missing from OreDefs score their own id, which sorts right:
				-- ids climb with tier, so it lands above every cheaper ore.
				rank = kind == "Ore" and (info.value or id) or info.rarity,
				timed = kind ~= "Ore",
				-- An egg pays out a pet, so a full backpack is no reason to skip one.
				-- A lucky box rolls an ore and does need a free slot.
				usesBackpack = kind ~= "Egg",
			})
		end
	end
	table.sort(out, function(a, b)
		if a.timed ~= b.timed then
			return a.timed
		end
		return a.rank > b.rank
	end)
	return out, fold
end

-- Everything resident right now, written into `known`. Cheap -- a folder scan and an
-- attribute read per spawn -- so the farm calls it every time it arrives somewhere,
-- which is what makes the route grow as you mine. Returns true when a stage we'd never
-- seen turned up, which is the panel's cue to redraw the list.
local function observe()
	local fresh = false
	for _, stage in ipairs(stages()) do
		-- nil, not empty: the Model replicates a beat before its Ores folder, so a stage
		-- read in that window has no loot yet. Recording it would cache it as empty --
		-- which scores 0, which sorts it last, which means the route never goes back to
		-- it, which means it is never re-read. Skip and catch it on a later lap.
		local loot = lootIn(stage.model)
		if loot then
			if not known[stage.depth] then
				fresh = true
			end
			known[stage.depth] = {
				depth = stage.depth,
				name = stage.name,
				-- Somewhere standable, not the Model pivot: that is the middle of the
				-- room and solid slate until it's been mined. An ore sits on the floor.
				pos = (loot[1] and loot[1].model or stage.model):GetPivot().Position,
				loot = loot,
				seen = true,
			}
		end
	end
	return fresh
end

-- farm -----------------------------------------------------------------------
-- fireproximityprompt returns nothing useful and the ore is destroyed server-side, so
-- the model leaving its folder is the receipt. `full` breaks out too: once the server
-- has refused one ore for space, every other prompt in the stage refuses the same way.
local function grab(entry, alive)
	local prompt = entry.model:FindFirstChildWhichIsA("ProximityPrompt", true)
	if not prompt or not prompt.Enabled then
		return false -- not loaded yet, or already being taken by someone else
	end
	tp(entry.model:GetPivot())

	local deadline = os.clock() + GRAB_TIMEOUT
	repeat
		pcall(fireproximityprompt, prompt)
		task.wait()
	until entry.model.Parent ~= entry.home or full or os.clock() > deadline or not alive()

	return entry.model.Parent ~= entry.home
end

-- Mine_Return is the Surface button in the HUD: the server moves you, which is why
-- there's no coordinate here and why the character is elsewhere for a moment after.
local function surface()
	send("Mine_Return")
	task.wait(RETURN_SETTLE)
end

-- Going the other way. Mine_EnterOreLayer is what the client sends the moment you fall
-- through a stage floor -- it's the only thing that tells the server which layer you're
-- on, and the client decides it, so sending it for a stage we teleported into is the
-- same claim made a different way. Without it the server's phase stays "slate" and the
-- HUD sits a stage behind; whether the collect handler cares, only the server knows.
local function descend(stage)
	local depth = tonumber(stage.Name:match("(%d+)$"))
	if depth then
		send("Mine_EnterOreLayer", { depth = depth, tierId = depth })
	end
	-- Land on an ore, not on the stage pivot: a stage Model's pivot is the middle of
	-- the whole room, which is solid slate until you've mined it. The ore floor is the
	-- one spot in there guaranteed to be standable.
	local loot = lootIn(stage)
	local at = loot and loot[1] and loot[1].model:GetPivot() or stage:GetPivot()
	tp(at)
end

-- The sell counter is a CollectionService tag, not a path, so it's found the same way
-- the game's own SceneTriggerController finds it. Standing on it is what opens SellPop
-- and, as far as we can tell from the client, what the server checks.
--
-- Watch the CHEST, not the backpack. Mine_Sell is SellPop's Sell All button, and
-- SellPop's list is getSellableVoidOreList() -- VoidChestInventory, minus favourites.
-- The backpack is already empty by the time we get here (surfacing deposits it), so
-- the old "wait for MineInventory to hit 0" test passed instantly and sold nothing.
--
-- Favourites are skipped server-side, so the chest can stop above zero and still be
-- fully sold. A pass that moves nothing is the stop condition, not an empty chest.
local function sell()
	local pad = CollectionService:GetTagged("Sell")[1]
	if pad then
		tp(pad:GetPivot())
	else
		warn("[DigSecrets] nothing tagged Sell -- firing Mine_Sell where we stand")
	end

	-- Wait for the deposit before snapshotting. Surfacing moves the backpack into the
	-- chest as a server round trip, and RETURN_SETTLE is a fixed guess at it. Snapshot
	-- too early and `before` is the PRE-deposit count: the chest then grows instead of
	-- shrinking, the drain test never fires, and -- because the failure branch is gated
	-- on before > 0 -- a sell that genuinely didn't take reports success.
	local drop = os.clock() + DEPOSIT_WAIT
	while carrying() > 0 and os.clock() < drop do
		task.wait(0.1)
	end

	local before = chest()
	local deadline = os.clock() + SELL_TIMEOUT
	local last = before
	repeat
		send("Mine_Sell")
		task.wait(SELL_RETRY)
		local now = chest()
		if now == last and now > 0 and now < before then
			break -- drained as far as it goes; the rest is favourited
		end
		last = now
	until last == 0 or os.clock() > deadline

	-- The backpack emptying is what lets the farm collect again, so that's what clears
	-- the full flag -- selling the chest is the separate half. Only when the backpack
	-- could actually be READ, though: carrying() fails open to 0, and treating that as
	-- "empty" would overrule the server's own full verdict and leave the farm surfacing
	-- and descending forever, collecting nothing and never saying why.
	local held, readable = carrying()
	if readable then
		full = held > 0
	end
	if last >= before and before > 0 then
		say(("sell didn't take -- %d still in the chest, is the counter on this surface?"):format(last))
		return false
	end
	return not full
end

-- One generation counter, the way every loop in this repo does it: toggling off and on
-- inside a single DWELL otherwise leaves the sleeping thread alive next to the new one
-- and the character gets yanked between two sweeps at once.
local farmOn, gen, autoSell = false, 0, true
local picked = nil -- stage name; the loop re-resolves it every sweep, see below
local laps = 0

-- The loop can decide to stop itself, and when it does the panel has to agree -- a
-- toggle still reading ON over a dead loop is indistinguishable from a working farm.
-- Replaced by the real one once the toggle exists.
local offSwitch = function() end

-- The richest thing a stage is holding, as a number, for ordering stages against each
-- other. Zero for one we've never seen -- unknown sorts last, which is right: a stage
-- we've never reached is a worse bet than one we've counted ore in.
--
-- The WHOLE list, not loot[1]. loot[1] is whatever lootIn ranked first, and that is
-- deliberately the timed loot -- and every EggDefs and LuckyBoxDefs entry in MineConfig
-- carries value = 0. Reading only the head therefore scored any stage holding an egg or
-- a lucky box at zero, which sorted the richest stage in the mine below a stage of $5
-- coal and meant the route never went there. The panel showed it plainly: "Stage 90 --
-- 8 spawns, best Lucky Box $0" sitting under a stage worth $2.5T.
local function stageValue(entry)
	local best = 0
	for _, item in ipairs(entry and entry.loot or {}) do
		best = math.max(best, item.value or 0)
	end
	return best
end

-- Where the farm goes next, best first. One zone means a list of one. ALL means every
-- stage we've seen so far, ordered by the value of the best thing in it -- which is the
-- point: with three backpack slots you want them filled from the richest stage on the
-- map, not the nearest. Deeper is usually richer but not reliably so (a dump run had
-- Stage 91 at $2.5T and Stage 92 at $1.8T), which is exactly why this sorts by value
-- and not by depth.
--
-- Rebuilt every lap, because every lap knows about more stages than the last. What's
-- remembered is a plan; the sweep re-reads the real stage on arrival, so one that has
-- emptied since we saw it just comes back with nothing.
local function plan()
	local out = {}
	for _, entry in pairs(known) do
		if picked == ALL or entry.name == picked then
			-- Scored once up front, not inside the comparator: stageValue walks the
			-- whole loot list and a sort calls its comparator far more often than it
			-- has elements.
			table.insert(out, { entry = entry, value = stageValue(entry) })
		end
	end
	-- Depth breaks ties, or the route would be a different order every lap: `known` is
	-- iterated with pairs (arbitrary order) and table.sort is not stable, so equal-value
	-- stages -- of which there are plenty, a whole tier shares one ore -- would shuffle.
	-- Deeper wins the tie because deeper trends richer even when this lap can't tell.
	table.sort(out, function(a, b)
		if a.value ~= b.value then
			return a.value > b.value
		end
		return a.entry.depth > b.entry.depth
	end)

	local route = {}
	for _, scored in ipairs(out) do
		table.insert(route, scored.entry)
	end
	return route
end

-- One stage, top to bottom. Returns how many it actually took, which is what tells the
-- caller whether to move on or wait for a respawn.
local function sweep(stage, alive)
	local loot, fold = lootIn(stage)
	if not fold then
		return 0, false -- not replicated yet; the caller decides whether to go stand in it
	end

	local got = 0
	for _, entry in ipairs(loot) do
		if not alive() then
			break
		end
		-- The list was ranked before the first grab and a grab takes seconds. Skipping
		-- one that's already gone is free; not skipping costs the whole GRAB_TIMEOUT
		-- firing at a prompt nobody can win.
		if entry.model.Parent ~= entry.home then
			continue
		end
		-- A full backpack blocks anything that lands IN it. An egg doesn't -- it pays
		-- out a pet -- and eggs are the one thing worth taking on a countdown, so
		-- they're still fair game with three ores on your back.
		if entry.usesBackpack and (full or carrying() >= capacity()) then
			if entry.timed then
				continue -- a lucky box; try the next thing, don't end the sweep
			end
			break -- ores from here down, and there's no room for any of them
		end
		say(("%s  %s  (%d/%d)"):format(
			entry.name,
			entry.value and money(entry.value) or entry.kind,
			carrying(),
			capacity()
		))
		if grab(entry, alive) then
			got = got + 1
		end
	end
	return got, true
end

local function setFarm(on)
	farmOn = on
	gen = gen + 1
	local mine = gen
	if not on then
		say(("idle -- %d taken, %d laps"):format(collected, laps))
		return
	end

	task.spawn(function()
		local function alive()
			return farmOn and gen == mine
		end

		while alive() do
			-- Surface FIRST, before looking at any stage: with a full backpack there
			-- is nothing to collect anywhere, so which stage is richest doesn't matter.
			-- Bound to a local rather than called inline: carrying() returns two values
			-- now, and at the tail of an argument list Lua expands both.
			local held = carrying()
			if full or held >= capacity() then
				say(("full (%d) -- surfacing"):format(held))
				surface()
				if autoSell then
					-- A sell that doesn't take leaves the backpack full, and the next
					-- pass would surface again with nothing changed. Stop instead of
					-- teleporting up and down forever; sell() has already said why.
					if not sell() then
						offSwitch() -- says "idle", so the reason goes after it
						say("stopped -- the backpack is full and the sell didn't take")
						return
					end
				else
					-- Nothing to collect with a full backpack, and no permission to
					-- empty it. Stop rather than teleport back and forth for nothing.
					offSwitch()
					say("full and Auto Sell is off -- stopped at the surface")
					return
				end
				laps = laps + 1
				continue
			end

			-- Read the world before deciding where to go. Standing anywhere in the mine
			-- streams its neighbours in, so this is where the route grows: stages that
			-- arrived while we were working the last one get recorded here and are on
			-- the list by the time it's sorted, a few lines down.
			if observe() then
				stagesChanged()
			end

			local route = plan()
			if #route == 0 then
				say(picked == ALL and "no stages loaded yet" or "pick a zone first")
				task.wait(DWELL)
				continue
			end

			local got = 0
			for _, entry in ipairs(route) do
				if not alive() or full or carrying() >= capacity() then
					break -- full: back to the top of the loop, which surfaces
				end
				-- Re-resolved every lap, never cached: streaming takes stages away
				-- entirely, so a stale Model reference is a sweep that finds nothing
				-- and never says why. `pos` is how we get back to one that's gone --
				-- teleporting there is what makes the server replicate it again.
				local fold = workspace:FindFirstChild("GeneratedStages")
				local stage = fold and fold:FindFirstChild(entry.name)
				if not stage then
					tp(entry.pos)
					stage = fold and (fold:FindFirstChild(entry.name) or fold:WaitForChild(entry.name, ARRIVE))
				end
				if stage then
					descend(stage) -- go there, and tell the server which layer that is
					local took, loaded = sweep(stage, alive)
					got = got + took
					if not loaded then
						task.wait(DWELL) -- arrived before the Ores folder did
					end
				end
			end

			-- Nothing anywhere on the route. Ores respawn on their own timer, so this
			-- is a wait, not a reason to stop.
			if got == 0 and not full then
				say(("nothing up -- %d taken, %d laps"):format(collected, laps))
				task.wait(DWELL)
			end
		end
	end)
end

-- gui ------------------------------------------------------------------------
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a
-- restyle is one file and not sixteen. Fetched here rather than installed by the loader,
-- so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Dig Into Secrets", -- fallback until the live name lands
	folder = "DigSecrets",
	size = UDim2.fromOffset(440, 400),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local Farm = Tab:Section({ Title = "Farm", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })

local byLabel, stageDrop = {}, nil

-- What a stage is holding, off what we remember rather than off the workspace: by the
-- time you open the dropdown most of those stages have been streamed back out, and
-- reading them live would report the whole mine as empty.
local function describe(entry)
	local loot = entry.loot
	if not loot or #loot == 0 then
		return entry.seen and "empty" or "not seen yet"
	end
	-- Richest by value, not loot[1]. loot[1] is the sweep's first TARGET, which is the
	-- timed loot, and eggs and lucky boxes are all priced 0 -- so this row used to read
	-- "best Lucky Box $0" for a stage full of trillion-dollar ore. It's the number the
	-- route sorts on, so the panel should show the same one.
	local best = loot[1]
	for _, item in ipairs(loot) do
		if (item.value or 0) > (best.value or 0) then
			best = item
		end
	end
	return ("%d spawn%s, best %s%s"):format(
		#loot,
		#loot == 1 and "" or "s",
		best.name,
		best.value and best.value > 0 and (" " .. money(best.value)) or ""
	)
end

-- Rebuilding clears what the dropdown shows as selected -- the rows it pointed at are
-- new objects. The FARM doesn't care: `picked` is a stage name, re-resolved every lap,
-- so a refresh mid-run doesn't interrupt anything.
local function refresh()
	byLabel = {}
	observe() -- everything resident, read fresh; the rest is what we remember

	local depths = {}
	for depth in pairs(known) do
		table.insert(depths, depth)
	end
	table.sort(depths)

	-- "All stages" first, because it is the row you want in almost every case,
	-- and a dropdown of ninety stages is a scroll otherwise.
	local values = { {
		Title = "All stages",
		Desc = ("%d known, worked richest first"):format(#depths),
	} }
	byLabel["All stages"] = ALL
	for _, depth in ipairs(depths) do
		local entry = known[depth]
		local label = ("Stage %d"):format(entry.depth)
		byLabel[label] = entry.name
		table.insert(values, { Title = label, Desc = describe(entry) })
	end

	if stageDrop then
		stageDrop:Refresh(values)
		-- Refresh rebuilds the rows but does NOT select one -- it re-fires the Callback
		-- with whatever Value the dropdown still held, which is "" until something is
		-- picked. The row it draws is a placeholder, so without this the panel shows a
		-- zone while `picked` is nil and Auto Mine refuses against a panel that looks
		-- ready. Select() is what actually sets the value, and it re-fires the callback.
		if values[1] and not picked then
			stageDrop:Select(values[1].Title)
		end
	end
	say((#values - 1) .. " stages known")
	return values
end

-- The farm redraws the list as it discovers stages, but not on every discovery -- a
-- dropdown that rebuilds under your cursor is unusable. Throttled to RELIST, and only
-- ever fired when observe() actually found something new.
local lastList = 0
stagesChanged = function()
	if os.clock() - lastList < RELIST then
		return
	end
	lastList = os.clock()
	refresh()
end

stageDrop = Farm:Dropdown({
	Title = "Zone",
	Desc = "All stages works every stage found so far, richest first. Grows as you mine.",
	Values = {}, -- filled by refresh() below, once the panel exists to hold them
	Value = "",
	-- Two shapes arrive here and neither is the label you'd expect: clicking a row hands
	-- back the whole {Title=, Desc=} entry, and Refresh() re-fires with the dropdown's
	-- stored Value, which is "" before anything is picked. Unknown values are IGNORED
	-- rather than assigned -- the callback runs on its own thread, so a Refresh landing
	-- after a Select would otherwise wipe a good pick a frame later.
	Callback = function(choice)
		local name = byLabel[typeof(choice) == "table" and choice.Title or choice]
		if not name then
			return
		end
		picked = name
		say("zone: " .. picked)
	end,
})

-- The SpawnType filter, as tick-boxes. Titles are the readable half; the SpawnType
-- attribute they map to is the other. MysteryEntrance isn't offered -- see the header.
local KINDS = { { "Ores", "Ore" }, { "Eggs", "Egg" }, { "Lucky Boxes", "LuckyBox" } }

Farm:Dropdown({
	Title = "Collect",
	Desc = "Eggs and lucky boxes are taken first -- they're the timed loot on the board",
	Values = (function()
		local names = {}
		for _, k in ipairs(KINDS) do
			table.insert(names, k[1])
		end
		return names
	end)(),
	Value = { "Ores", "Eggs", "Lucky Boxes" },
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		-- Rebuilt rather than patched: the callback hands over the whole selection, and
		-- the sweep reads `wanted` live, so a re-tick lands on the next pass on its own.
		local ticked = {}
		for _, name in ipairs(values) do
			ticked[typeof(name) == "table" and name.Title or name] = true
		end
		wanted = {}
		for _, k in ipairs(KINDS) do
			wanted[k[2]] = ticked[k[1]] or false
		end
	end,
})

-- Declared first so the callback can flip its own switch back: refusing to start while
-- leaving the toggle reading ON is the one failure that looks like a working farm.
local mineToggle
mineToggle = Farm:Toggle({
	Title = "Auto Mine",
	Desc = "Work the route richest first, surface when the backpack fills",
	Value = false,
	Callback = function(v) -- :Set() re-fires this, so both branches have to be re-entrant
		if v and not picked then
			mineToggle:Set(false) -- re-fires this with false, which says "idle"...
			say("pick a zone first") -- ...so the real reason has to go after it
			return
		end
		setFarm(v)
	end,
})

-- :Set(false) re-fires the callback, which lands in setFarm(false) -- one stop path,
-- whether it came from a click, a key or the loop giving up.
offSwitch = function()
	mineToggle:Set(false)
end

Farm:Toggle({
	Title = "Auto Sell",
	Desc = "At the surface, teleport to the Sell counter and sell everything",
	Value = true,
	Callback = function(v)
		autoSell = v
	end,
})

Farm:Button({ Title = "Refresh zones", Callback = refresh })

-- Both buttons below move the character, and so does the farm loop. Two threads writing
-- HumanoidRootPart.CFrame every frame means neither wins: a grab times out against a
-- prompt whose range the server keeps re-checking against a position that won't hold
-- still. A refusal is the whole fix -- a lock would just make the button hang for as
-- long as a sweep takes, which reads as broken.
local function handsOff()
	if farmOn then
		say("turn Auto Mine off first")
		return true
	end
	return false
end

Farm:Button({ Title = "TP to zone", Callback = function()
	task.spawn(function()
		if handsOff() then
			return
		end
		if not picked or picked == ALL then
			say("pick a single zone for this one")
			return
		end
		local fold = workspace:FindFirstChild("GeneratedStages")
		local stage = fold and fold:FindFirstChild(picked)
		if not stage then
			-- Streamed out since we last saw it. Teleporting to where it was is what
			-- makes the server replicate it again -- the same trick the farm uses.
			local entry
			for _, e in pairs(known) do
				if e.name == picked then
					entry = e
				end
			end
			if entry then
				tp(entry.pos)
				stage = fold and fold:WaitForChild(picked, ARRIVE)
			end
		end
		if not stage then
			say(picked .. " wouldn't load")
			return
		end
		descend(stage)
		say("at " .. picked)
	end)
end })

Farm:Button({ Title = "Surface + sell", Callback = function()
	task.spawn(function()
		if handsOff() then
			return
		end
		surface()
		say(sell() and "sold" or ("still carrying " .. carrying()))
	end)
end })

local line = Farm:Paragraph({ Title = "Status", Desc = "idle" })
say = function(msg)
	pcall(function()
		line:SetDesc(msg)
	end)
end

refresh()

-- close ----------------------------------------------------------------------
local function stopAll()
	farmOn = false
	gen = gen + 1 -- orphans whatever sweep is mid-flight, same as a toggle off
	receipt:Disconnect()
end

Window:OnDestroy(function()
	stopAll()
	getgenv().digSecretsStop = nil
end)

getgenv().digSecretsStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().digSecretsStop = nil
end
