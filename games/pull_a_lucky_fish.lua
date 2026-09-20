--[[ Pull a Lucky Fish -- auto fish with none of the cast sequence (112781315318195)

     FISH   : casts, waits out the server's timer, collects. No charge bar, no flight,
              no camera takeover, no chase, no clicking. Your character stands still and
              stays yours -- unanchored, walkable, camera untouched.
              "Minimum rarity" rerolls the cast until the fish is one you want. The fish
              is decided when ThrowData answers, each call replaces the pending one, and
              none of them restarts the server's timer -- so the script keeps rolling
              through the wait it has to sit out anyway, and a filter costs nothing
              unless the wait ends before it hits.
              "Fast casts" rerolls the slow ones instead: every bonus row on a roll is
              ~3.8s more the server makes you wait, and a reroll costs one round trip.
     TRAIN  : fires Train on the server's own cooldown. The server acts on the dumbbell
              you HOLD, so the script equips it for you -- and clears the anchor that
              equipping normally puts on you, which is the part that made holding it
              cost anything. You keep walking and keep fishing; teardown puts it away.
     X2     : claims the x2 / x4 click bonus the moment it pops, by firing the game's
              own button. Works whether you train by hand or with TRAIN on.
     PLOT   : collect cash off every stand you own (the game's own Owner check, not a
              hardcoded path), fire Equip Best whenever the game's own plan differs from
              what's placed, level placed fish by fastest payback, and sell everything
              under a rarity floor -- through the game's server-side auto-sell if you
              own the unlock, by hand if you don't.

     The whole fishing loop is client-authoritative: ThrowData rolls the fish server-side
     and hands you the result up front, the sequence you normally sit through is your own
     client animating that result, and GetFishToRecive is what actually banks it. So the
     script is three calls and a sleep.

     The sleep is not optional. Probed: collecting immediately never pays, and re-asking
     for 21s does not help either -- the server times the cast and a "done" broadcast that
     arrives early voids it, so this script sends no stage broadcasts at all. Waiting ~12s
     and collecting once pays every time. That is roughly double doing it by hand, and it
     shrinks as you buy Throw/Roll speed: the wait is computed per cast from the game's own
     getExpectedFishTime, then tuned against what the server actually accepts.

     AFK    : on by default -- nudges the idle kick away, rejoins on a disconnect.

     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().luckyFishStop() ]]

-- config ---------------------------------------------------------------------
-- Throw accuracy, 0..1. ThrowAccuracy.rate() calls >= 0.93 PERFECT, and the rating is
-- read off this number alone -- there is no bar to hit, so there is no reason to send
-- anything else. Exposed in the panel only because a game update could start checking
-- the distribution and a run of 1.00s would be the tell.
local POWER = 0.97
-- Added to whatever getExpectedFishTime says. The server's clock started before ours did
-- (it rolled the fish during the round trip), so a wait measured from our side is always
-- a little short. Raise it if casts start needing a second collect.
local MARGIN = 0.75
-- Never wait less than this however low the estimate goes. A rod fast enough to make the
-- estimate silly is a rod the server still times.
local WAIT_MIN = 3
-- Used when getExpectedFishTime can't be reached (a game update moved it). Measured
-- floor on a starter rod was ~12s.
local WAIT_FALLBACK = 13
-- Not ripe yet: keep asking on this beat for up to RIPEN_CAP seconds before writing the
-- cast off. A nil from GetFishToRecive is "too early", not a refusal -- the probe took a
-- fish at t+14.2 after the same call returned nil at t+12. An undershoot costs up to one
-- POLL of dead time, so keep it short; 1.5 was wasting ~0.75s on every miss.
local POLL = 0.5
local RIPEN_CAP = 12
-- A boss gets a countdown and a fight on the client that getExpectedFishTime doesn't
-- count, so if the server times that too the normal cap gives up on it. A boss is worth
-- the extra wait; a boss that doesn't pay by then says so in the console.
local BOSS_RIPEN_CAP = 40
-- The tuner. Paid on the first ask -> the wait was long enough, try 3% less next time.
-- Needed extra polls -> we undershot, give the estimate back what it cost us. Descending
-- from above costs one slow cast to find the floor; climbing from below costs a voided
-- cast per step.
local SHRINK, FACTOR_MIN = 0.97, 0.6
-- Red's :Await() has no timeout. A handler that never returns parks the thread forever,
-- and a parked farm thread looks exactly like a dead one.
local CALL_TIMEOUT = 10
local STUCK_AFTER = 45 -- watchdog: no progress for this long prints where it stopped

-- Re-rolling. ThrowData hands back the fish and its mutation up front, costs ~0.06s, and
-- replaces whatever was pending -- nothing is spent until you wait and collect. So a
-- filter is free: roll until the fish is one you want, and only then pay the 12s. The cap
-- exists because a filter nobody can satisfy would otherwise never cast at all; hitting
-- it takes whatever is pending, since an earlier roll cannot be got back.
-- Rolls inside the wait are free (probed: a reroll doesn't restart the server's timer),
-- so they're paced rather than capped: FREE_ROLL_GAP apart, stopping FREE_ROLL_STOP
-- before the collect so the last reply is in. 0.1 is ~120 rolls on a 20s cast; lower it
-- for more tries, raise it if the server starts refusing ThrowData mid-cast.
local FREE_ROLL_GAP = 0.1
local FREE_ROLL_STOP = 0.3
-- Once the wait is up with no match, each further roll costs its round trip (~0.06s).
-- This caps those; the panel's "Max rerolls" writes it live.
local REROLL_CAP = 25
-- Extra pause between rolls on top of the round trip. 0 = back to back, which halves a
-- filter's cost against the old 0.1. Raise it if rerolls start ending in "stopped
-- answering mid-reroll" -- that is the server throttling, and it is the only tell.
local REROLL_GAP = 0

-- Fast casts. The server's timer (getExpectedFishTime) adds SpinDurationMin / rollSpeed^2
-- (~3.8s on no upgrades) per slot row and 1.9s per mutation row, and every roll arrives
-- with its rows attached -- so the wait is known before you pay it. With no rarity filter,
-- reroll anything slower than the one-row floor by more than FAST_SLACK, free inside the
-- wait and up to FAST_CAP past it. Unproven half: the probe only saw two rolls with the
-- same wait, so whether the server times the PENDING roll or the first one is open -- if
-- it's the first, this buys nothing and the collect's poll absorbs the difference.
-- The rows are bonus drops (luck, gem packs), so this trades those for fish/min; a
-- mutated, beast, boss or golden roll is always kept.
local FAST_CAP = 8
local FAST_SLACK = 0.5

-- Auto upgrade. A level pays for itself in ~5 * 1.2^L / (mutation x cash multiplier)
-- seconds whatever the fish (the base earnings cancel out), so this is the one knob: stop
-- when payback passes it, and cash goes to rods/rebirth instead. Seconds; the panel
-- takes minutes.
local UPGRADE_PAYBACK = 30 * 60
-- Never level a fish past this. The panel's slider writes it live (1-75). 20 is where
-- payback is still ~3 min before multipliers; past it each level costs 1.5x the last.
local UPGRADE_MAX_LEVEL = 20
local UPGRADE_GAP = 0.2 -- between fires; the profile needs a beat to show the new level
local UPGRADE_POLL = 1 -- nothing affordable: look again after this

-- Anti-AFK: a synthetic click this often. Roblox's idle kick is at 20 min and Idled fires
-- at ~2, so anything under a few minutes is plenty; the beat only covers clients where
-- Idled doesn't fire.
local AFK_BEAT = 60
-- After an ErrorPrompt (kick, disconnect, server shutdown), wait this long before rejoining
-- so the prompt's own teardown doesn't race the teleport.
local REJOIN_DELAY = 3

-- Equip best: how often to compare the game's own plan against the plot. Cheap -- it's
-- local data -- and it is what places a new catch within seconds instead of on a 10s beat.
local EQUIP_CHECK = 2

-- Plot. Collecting is one remote per stand with cash on it; three seconds is far below
-- any stand's fill time and keeps the sweep cheap. The gap between fires is there because
-- a server that debounces per player pays once for a whole plot fired in one frame.
local COLLECT_POLL = 3
local COLLECT_GAP = 0.05
-- Selling by hand (no auto-sell unlock): one remote per inventory entry, paced so a long
-- inventory doesn't arrive as one burst.
local SELL_POLL = 5
local SELL_GAP = 0.1

-- Training. The server sets the cadence through LastTrained, and once the dumbbell is in
-- hand the game's own Equipped loop fires Train every frame anyway -- so this poll can't
-- make reps faster; it only keeps the tool held and the anchor off. Don't lower it: at 0
-- the fires during one round trip count as "ignored" and trip TRAIN_DEAF.
local TRAIN_POLL = 0.1
-- Gym events. TrainingHandler multiplies a rep by the buff while you stand within 40
-- studs of a GymEventTrainingZone (x1.5 up to x5), or x1.5 within 25 of a Mini Gym
-- (one rises every ~15 min for 5 min). Aim well inside both.
local GYM_REACH = 15
-- Fires against a LastTrained that never moves this many times before saying so. The
-- server ignoring us is the one failure that looks exactly like working.
local TRAIN_DEAF = 30

-- setup ----------------------------------------------------------------------
if getgenv and getgenv().luckyFishStop then
	getgenv().luckyFishStop() -- a re-paste must not stack a second panel and loop
end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

-- Every game module behind a pcall: an update that moves one should say so in the panel
-- rather than throw a stack trace with none of our code in it.
local function grab(path)
	local ok, mod = pcall(function()
		return require(path)
	end)
	return ok and mod or nil
end

local Remotes = grab(RS.shared.Remotes)
local CPD = grab(RS.client.ClientPlayerData)
local InvCfg = grab(RS.shared.config.InventoryConfig)
local expectedFishTime = grab(RS.shared.util.getExpectedFishTime)
local FishConfig = grab(RS.shared.config.FishConfig)
local rarityConfig = grab(RS.shared.config.rarityConfig)
local TrainToolConfig = grab(RS.shared.config.TrainToolConfig)
local EquipBestConfig = grab(RS.shared.config.EquipBestConfig)
local ConvertValue = grab(RS.shared.util.ConvertValue)
local FishEarnings = grab(RS.shared.util.FishEarnings)
local getBossPool = grab(RS.shared.util.getBossPool)
local getPlayerPoolLuck = grab(RS.shared.util.getPlayerPoolLuck)
local getRodEnchantBonus = grab(RS.shared.util.getRodEnchantBonus)
-- The client's mirror of the gym event (buff + Mini Gym). Start() is guarded by the module
-- itself, so calling it when the game already has is a no-op, not a second listener.
local GymEventState = grab(RS.client.GymEventState)
if GymEventState and GymEventState.Start then
	pcall(GymEventState.Start)
end
local EquipBestPlan = grab(RS.shared.util.EquipBestPlan)
-- InitSystems writes the live UECS instance onto every system module, so requiring one is
-- how you get at the component registry without a getgc scan. Any system would do; this
-- is the one whose components we want.
local CollectCashDetector = grab(RS.shared.UECS.Systems.Client.CollectCashDetector)
local ecs = CollectCashDetector and CollectCashDetector.UECS or nil

if not Remotes or not Remotes.ThrowData or not Remotes.GetFishToRecive then
	warn("[fish] Remotes.ThrowData / GetFishToRecive missing -- the game moved its net layer")
	return
end

local running = true -- cleared by stopAll, so a re-paste does not stack watchdogs

-- world ----------------------------------------------------------------------
-- Red's :Call():Await() returns (ok, value) and yields unbounded. Run it on its own
-- thread and give up on a clock: the abandoned thread is harmless, it writes to locals
-- nobody reads.
local function callTimed(fn, timeout)
	local done, a, b = false, nil, nil
	task.spawn(function()
		local ok, r1, r2 = pcall(fn)
		if ok then
			a, b = r1, r2
		end
		done = true
	end)
	local dead = os.clock() + (timeout or CALL_TIMEOUT)
	while not done and os.clock() < dead do
		task.wait()
	end
	if not done then
		return nil, nil
	end
	return a, b
end

local function throwData(power)
	return callTimed(function()
		return Remotes.ThrowData:Call(power, nil):Await()
	end)
end

local function collect()
	return callTimed(function()
		return Remotes.GetFishToRecive:Call():Await()
	end)
end

-- Reports whether it could READ, not just the number. Failing open to 0 would read as
-- "inventory empty" and quietly invert the full-inventory gate.
local function fishCount()
	if not CPD or not CPD.isPlayerDataLoaded or not CPD.serverProfile or not InvCfg then
		return nil
	end
	local ok, n = pcall(function()
		return InvCfg.countFish(CPD.serverProfile:getState())
	end)
	return ok and n or nil
end

local function profile()
	if not CPD or not CPD.serverProfile then
		return nil
	end
	local ok, state = pcall(function()
		return CPD.serverProfile:getState()
	end)
	return ok and state or nil
end

-- The server almost certainly gates on this same function -- it lives in shared and
-- nothing on the client requires it. Fed with the roll the server just handed us, so it
-- picks up rod, floats, potions and speed upgrades without knowing any of them exist.
-- bare = the same throw with no slot rows: the one-row floor a fast roll is judged against.
local function expectedFor(data, bare)
	if not expectedFishTime or type(data) ~= "table" then
		return WAIT_FALLBACK
	end
	local info = type(data.ThrowInfo) == "table" and data.ThrowInfo or data
	local state = profile()
	local ok, secs = pcall(function()
		return expectedFishTime({
			player = player,
			throwSpeed = state and state.throwSpeed or nil,
			throwDistance = info.ThrowDistance,
			biomeId = type(info.DestinationBiom) == "table" and info.DestinationBiom.id or nil,
			fishName = data.FishDropName,
			-- firstDiscovery is the server's to know; leaving it nil picks the slower
			-- roll tier, which errs towards waiting long enough.
			slots = not bare and (data.SlotDrops or info.SlotDrops) or nil,
			bonusSlots = not bare and (data.BonusSlotDrops or info.BonusSlotDrops) or nil,
		})
	end)
	if ok and type(secs) == "number" and secs > 0 then
		return secs
	end
	return WAIT_FALLBACK
end

-- filter ------------------------------------------------------------------------
-- Built from the game's own configs, so a balance patch that adds a rarity or renames a
-- fish is picked up without an edit here.
local RARITIES = {}
if rarityConfig then
	for id, r in pairs(rarityConfig) do
		if type(r) == "table" and r.id then
			table.insert(RARITIES, { id = r.id, power = tonumber(r.power) or 0 })
		end
	end
	table.sort(RARITIES, function(a, b)
		return a.power < b.power
	end)
end

local ANY = "Any" -- first row of the dropdown, and the off switch

local function rarityNames()
	local out = { ANY }
	for _, r in ipairs(RARITIES) do
		table.insert(out, r.id)
	end
	return out
end

-- The floor, as a power number rather than a name: rarity ids are a set, but power is an
-- order, and "this tier and anything rarer" is the only ranking anyone actually wants.
-- 0 means no floor -- take the first roll.
local minPower = 0
local keepMutated = false

local function powerOf(rarityId)
	for _, r in ipairs(RARITIES) do
		if r.id == rarityId then
			return r.power
		end
	end
	return nil
end

local function rarityOf(fishName)
	if not FishConfig or type(fishName) ~= "string" then
		return nil
	end
	local entry = FishConfig[fishName]
	local r = entry and entry.Rarity
	return type(r) == "table" and r.id or nil
end

local function mutationOf(data)
	local info = type(data.ThrowInfo) == "table" and data.ThrowInfo or data
	local m = info.Mutation or data.Mutation
	return type(m) == "string" and m ~= "" and m or nil
end

-- No floor and mutations not wanted -> everything matches and the reroll loop never runs.
-- That is the off switch: "Any" means no filtering, not "filter everything out".
local function filtering()
	return keepMutated or minPower > 0
end

local function matches(data)
	if type(data) ~= "table" then
		return true
	end
	-- Bosses and beasts are always a match. They roll 1 in ~1M / (luck x 0.75) and a boss
	-- also spends the server's shared stock (RollClass.rollBoss -> BossFishStockModule),
	-- so rerolling one away -- which "keep mutated" alone used to do to every unmutated
	-- boss -- throws out the rarest thing in the game.
	if data.IsBoss == true or data.IsBeast == true then
		return true
	end
	if keepMutated and mutationOf(data) then
		return true -- a mutated fish is taken whatever tier it is
	end
	if minPower <= 0 then
		return not keepMutated -- mutations-only: a plain fish is not a match
	end
	local power = powerOf(rarityOf(data.FishDropName))
	-- A fish the config doesn't know is taken rather than rerolled forever: an unknown
	-- name is far more likely to be a game update than a fish you didn't want.
	return power == nil or power >= minPower
end

local fastCasts = false

-- Worth keeping whatever it costs in wait: the extra rows ARE the prize.
local function precious(data)
	return mutationOf(data) ~= nil or data.IsBeast == true or data.IsBoss == true or data.IsGolden == true
end

-- Should the reroll loop stop on this roll? A filter decides alone when one is set --
-- speed never throws away a match. Otherwise Fast casts keeps anything near the floor.
local function keep(data)
	if type(data) ~= "table" then
		return true
	end
	if filtering() then
		return matches(data)
	end
	if not fastCasts or precious(data) then
		return true
	end
	return expectedFor(data) <= expectedFor(data, true) + FAST_SLACK
end

-- Your odds per roll and what's left in stock, the same way the game's Inspect panel
-- works them out: getBossPool with your pool luck + BossHunter enchant, stock from the
-- fishStocks JSON the server keeps on ReplicatedStorage. Stock 0 = no boss for anyone
-- until it restocks (BossFishConfig: 10 every 15h), however much you roll.
local function bossOdds()
	if not (getBossPool and getPlayerPoolLuck) then
		return nil
	end
	local ok, pool = pcall(function()
		local hunter = getRodEnchantBonus and getRodEnchantBonus(player, "BossHunter") or 0
		return getBossPool(getPlayerPoolLuck(player), hunter)
	end)
	if not ok or type(pool) ~= "table" then
		return nil
	end
	local stocks = {}
	pcall(function()
		stocks = game:GetService("HttpService"):JSONDecode(RS:GetAttribute("fishStocks"))
	end)
	local parts = {}
	for _, b in ipairs(pool) do
		local stock = type(stocks) == "table" and tonumber(stocks[b.Name]) or nil
		table.insert(
			parts,
			("%s 1 in %s, stock %s"):format(tostring(b.DisplayName or b.Name), tostring(b.OneIn), tostring(stock or "?"))
		)
	end
	return #parts > 0 and table.concat(parts, " | ") or "no bosses in the pool"
end

-- farm ------------------------------------------------------------------------
-- Loop threads never write to the panel. A resumed thread comes back with reduced
-- capability, so the first write lands and every one after a task.wait throws "lacking
-- capability Plugin" -- the window lives in the hidden GUI, which is the part that needs
-- it. A Heartbeat connection drains this instead; the engine calls that with our own
-- identity.
local pending, pendingQuiet = nil, false

local function post(msg) -- worth a console line
	pending, pendingQuiet = msg, false
end

local function status(msg) -- panel only; anything a loop says every pass
	pending, pendingQuiet = msg, true
end

local mark, markAt = "idle", os.clock()
local function step(where)
	mark, markAt = where, os.clock()
end

local farm =
	{ on = false, gen = 0, power = POWER, cap = REROLL_CAP, factor = 1, casts = 0, caught = 0, rolls = 0, last = "-" }

-- Forward-declared: the loop switches the toggle off when it gives up, and a row built
-- further down cannot be an upvalue of a function written above it otherwise.
local fishToggle

local function inventoryFull()
	local n, limit = fishCount(), InvCfg and InvCfg.FishLimit or nil
	if not n or not limit then
		return false -- can't read: fail open, the server refuses for us
	end
	return n >= limit
end

local function sleepAlive(secs, alive)
	local dead = os.clock() + secs
	while os.clock() < dead do
		if not alive() then
			return false
		end
		local left = dead - os.clock()
		status(("waiting %.1fs -- %s"):format(left, farm.last))
		task.wait(math.min(0.25, left))
	end
	return true
end

-- One cast, start to bank. Returns false when the loop should stop.
local function oneCast(alive)
	if inventoryFull() then
		farm.stopReason =
			("inventory full (%d/%d) -- sell or deposit, then start again"):format(fishCount() or 0, InvCfg.FishLimit)
		return false
	end

	-- Client-authoritative, both of them: this is the same pair the game's own controller
	-- fires when you walk onto the pier and start a cast.
	pcall(function()
		Remotes.SetThrowZoneState:Fire(true)
	end)
	pcall(function()
		Remotes.SetFishState:Fire(true)
	end)

	step("cast / ThrowData")
	local t0 = os.clock() -- the server's timer starts on this roll, and no reroll restarts it
	local ok, data = throwData(farm.power)
	if not ok or type(data) ~= "table" then
		pcall(function()
			Remotes.SetFishState:Fire(false)
		end)
		post("ThrowData refused or timed out -- are you in a fishing zone?")
		task.wait(3)
		return true
	end

	-- Rerolls. Each ThrowData replaces the pending fish, so this has to stop ON a match:
	-- there is no going back to a roll you passed over. Probed: a reroll does NOT restart
	-- the server's timer -- a fish rolled 6s into a 20.8s cast paid at +21.7 from the
	-- first roll -- so every roll made inside the wait is free. Only the ones past it cost.
	local rolls, stalled = 1, false
	local function due()
		return t0 + math.max(WAIT_MIN, expectedFor(data) * farm.factor + MARGIN)
	end
	local function reroll()
		local ok2, next_ = throwData(farm.power)
		if not ok2 or type(next_) ~= "table" then
			-- Refused or timed out. Whatever the last accepted roll was is still the
			-- pending one, so keep it rather than rolling into a rate limit.
			post("ThrowData stopped answering mid-reroll -- taking what's pending")
			return false
		end
		data = next_
		rolls += 1
		return true
	end
	-- Free: inside the wait, stopping early enough that the last reply lands first.
	while alive() and not stalled and not keep(data) do
		if os.clock() + FREE_ROLL_GAP + FREE_ROLL_STOP >= due() then
			break
		end
		status(
			("rolling %d -- %.1fs left -- last %s"):format(rolls, due() - os.clock(), tostring(data.FishDropName))
		)
		task.wait(FREE_ROLL_GAP)
		stalled = not reroll()
	end
	-- Paid: the wait is up and each roll now costs its round trip, so it's capped.
	local cap, extraRolls = filtering() and farm.cap or FAST_CAP, 0
	while alive() and not stalled and extraRolls < cap and not keep(data) do
		status(("rerolling %d/%d past the wait -- last %s"):format(extraRolls, cap, tostring(data.FishDropName)))
		if REROLL_GAP > 0 then
			task.wait(REROLL_GAP)
		end
		stalled = not reroll()
		extraRolls += 1
	end
	if filtering() and not matches(data) then
		post(("no match in %d rolls -- taking %s"):format(rolls, tostring(data.FishDropName)))
	end
	farm.rolls += rolls

	farm.casts += 1
	local rolled = tostring(data.FishDropName or "?")
	local info = type(data.ThrowInfo) == "table" and data.ThrowInfo or data
	local mutation = info.Mutation or data.Mutation
	farm.last = mutation and (mutation .. " " .. rolled) or rolled
	local isBoss = data.IsBoss == true
	if isBoss or data.IsBeast == true then
		-- Rare enough that every one deserves a console line, paid or not.
		post(("%s rolled: %s -- waiting it out"):format(isBoss and "BOSS" or "BEAST", farm.last))
	end

	local base = expectedFor(data)
	local wait = math.max(due(), os.clock()) - t0 -- from the first roll, which is the server's clock
	step("cast / waiting " .. rolled)
	if not sleepAlive(math.max(0, due() - os.clock()), alive) then
		-- Toggled off mid-wait. The roll stays pending server-side and the next cast's
		-- collect picks it up, so there is nothing to rescue here -- just don't leave the
		-- server thinking we are still mid-cast.
		pcall(function()
			Remotes.SetFishState:Fire(false)
		end)
		return false
	end

	step("cast / collect " .. rolled)
	local before = fishCount()
	local extra, tries = 0, 0
	while alive() do
		tries += 1
		local ok2, got = collect()
		local paid = type(got) == "table" and got.Fish ~= nil
		if not paid and before then
			local now = fishCount()
			paid = now ~= nil and now > before -- belt and braces: the count is the truth
		end
		if paid then
			farm.caught += 1
			if tries == 1 then
				farm.factor = math.max(FACTOR_MIN, farm.factor * SHRINK)
			end
			post(
				("caught %s  (%d/%d casts, %d rolls, wait %.1fs)"):format(
					farm.last,
					farm.caught,
					farm.casts,
					farm.rolls,
					wait + extra
				)
			)
			break
		end
		if not ok2 and got == nil and tries > 1 then
			-- the call itself is failing, not the timing
			farm.stopReason = "GetFishToRecive stopped answering -- stopped"
			pcall(function()
				Remotes.SetFishState:Fire(false)
			end)
			return false
		end
		if isBoss and extra >= BOSS_RIPEN_CAP then
			-- Not the estimate's fault, so the tuner is left alone.
			warn(("[fish] BOSS %s never paid after %.0fs -- the server wants more than a wait"):format(rolled, wait + extra))
			break
		elseif not isBoss and extra >= RIPEN_CAP then
			-- Never ripened. Either the roll was voided or the estimate is badly short;
			-- give the wait back what this cast cost and move on rather than spinning.
			farm.factor = math.min(2.5, farm.factor + RIPEN_CAP / math.max(base, 1))
			post(("cast did not pay after %.0fs -- lengthening the wait"):format(wait + extra))
			break
		end
		status(("ripening %.0fs over -- %s"):format(extra, farm.last))
		task.wait(POLL)
		extra += POLL
	end

	pcall(function()
		Remotes.SetFishState:Fire(false)
	end)
	return true
end

local function setFarm(state)
	farm.gen += 1
	local mine = farm.gen
	farm.on = state
	if not state then
		post(("stopped -- %d caught in %d casts"):format(farm.caught, farm.casts))
		return
	end
	if not CPD or not CPD.isPlayerDataLoaded then
		farm.on = false
		post("player data hasn't loaded yet -- wait a few seconds and try again")
		return
	end
	post("fishing")
	task.spawn(function()
		local function alive()
			return farm.on and farm.gen == mine and running
		end
		while alive() do
			if not oneCast(alive) then
				break
			end
		end
		-- Only the current generation may flip the switch off: an old thread finishing
		-- must not kill a run that has since been restarted.
		if farm.gen == mine then
			farm.on = false
			step("idle")
			local reason = farm.stopReason
			farm.stopReason = nil
			-- Set() re-enters the callback, whose off branch posts "stopped" -- so the
			-- reason has to be written after it, or it gets overwritten a frame later.
			pcall(function()
				fishToggle:Set(false)
			end)
			if reason then
				post(reason)
			end
		end
	end)
end

-- training ---------------------------------------------------------------------
-- Equipping a dumbbell does two things: it anchors your HumanoidRootPart, and it starts a
-- client loop that fires Train whenever the server's LastTrained cooldown has expired.
--
-- Firing Train with the tool in the backpack was the plan and the server ignores it --
-- it acts on what you HOLD, like every other place remote in these games. So the tool
-- goes into your hand, and the half that actually costs you (the anchor) is undone: the
-- Equipped handler writes Anchored once and nothing re-asserts it, so clearing it sticks.
-- You keep walking, keep fishing, and never touch the hotbar.
local trainer = { on = false, gen = 0, fired = 0, gym = false, home = nil }

local function strengthOf(name)
	local cfg = TrainToolConfig and TrainToolConfig[name]
	return type(cfg) == "table" and tonumber(cfg.AddStrength) or nil
end

-- By name against the game's own config, so a dumbbell added in a patch is found without
-- an edit here. The strongest one wins -- a rep is worth its AddStrength, so holding the
-- first one found could be training at a fraction of what you own.
local function trainTool()
	local char = player.Character
	local bp = player:FindFirstChildOfClass("Backpack")
	local best, bestStr
	for _, where in ipairs({ char, bp }) do
		if where then
			for _, tool in ipairs(where:GetChildren()) do
				if tool:IsA("Tool") then
					local str = strengthOf(tool.Name)
					-- No config (a game update moved it): fall back on the naming, which
					-- every one of the seventeen follows.
					if not TrainToolConfig and (tool.Name:match("Dumbbell") or tool.Name:match("TrainTool")) then
						str = 0
					end
					if str and (not bestStr or str > bestStr) then
						best, bestStr = tool, str
					end
				end
			end
		end
	end
	return best
end

-- Only the ACTIVE dumbbell (profile.trainingTool) exists as a Tool; the rest wait in the
-- inventory as Category "TrainingTool" rows, which is why the one in your backpack can be
-- the weak one. EquipTrainingTool swaps (secureChangeTrainingTool) -- free, no cost.
-- Returns the name it asked for, or nil when you already hold the best.
local function equipBestDumbbell()
	local state = profile()
	if not state or not Remotes.EquipTrainingTool then
		return nil
	end
	local best, bestStr = state.trainingTool, strengthOf(state.trainingTool) or -1
	for key, entry in pairs(state.inventory or {}) do
		if type(entry) == "table" and entry.Category == "TrainingTool" then
			local name = entry.ConfigName or key
			local str = strengthOf(name)
			if str and str > bestStr then
				best, bestStr = name, str
			end
		end
	end
	if best == state.trainingTool or type(best) ~= "string" or best == "" then
		return nil
	end
	pcall(function()
		Remotes.EquipTrainingTool:Fire(best)
	end)
	return best
end

-- Where a rep is worth the most right now: the gym-event zone while its buff is up, the
-- Mini Gym while one has risen, whichever multiplies more. Read the way TrainingHandler's
-- estimateGymMultiplier reads it, so it's the same answer the game gives.
local function gymSpot()
	local state = GymEventState and GymEventState.Get and GymEventState.Get()
	if type(state) ~= "table" then
		return nil
	end
	local pos, mult = nil, 1
	local buff = state.buff
	if type(buff) == "table" and (tonumber(buff.multiplier) or 1) > mult then
		-- Nearest zone part: a far one may not be streamed in, a near one always is.
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		local bestD
		for _, p in ipairs(game:GetService("CollectionService"):GetTagged("GymEventTrainingZone")) do
			if p:IsA("BasePart") then
				local d = hrp and (hrp.Position - p.Position).Magnitude or 0
				if not bestD or d < bestD then
					pos, bestD, mult = p.Position, d, tonumber(buff.multiplier)
				end
			end
		end
	end
	local mini = state.miniGym
	if type(mini) == "table" and (tonumber(mini.multiplier) or 1) > mult then
		local p = mini.pivot
		local at = typeof(p) == "CFrame" and p.Position
			or typeof(p) == "Vector3" and p
			or typeof(p) == "Instance" and p:IsA("BasePart") and p.Position
			or nil
		if at then
			pos, mult = at, tonumber(mini.multiplier)
		end
	end
	return pos, mult
end

-- Back to where you were before the gym pulled you away. Called when the buff ends and
-- on every way out, so training never strands you at a gym.
local function goHome()
	local char = player.Character
	if trainer.home and char then
		pcall(function()
			char:PivotTo(trainer.home)
		end)
	end
	trainer.home = nil
end

-- Puts the dumbbell in hand and takes the anchor back off. Returns the tool, or nil if
-- there is nothing to hold -- which is a real answer: you may not own one yet.
local function holdTool()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local tool = trainTool()
	if not (char and hum and tool) then
		return nil
	end
	if tool.Parent ~= char then
		pcall(function()
			hum:EquipTool(tool)
		end)
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp.Anchored then
		hrp.Anchored = false
	end
	return tool
end

-- Put it away again on stop. The game's Unequipped handler tears down its own loop but
-- does not clear the anchor it set, so leaving without this can strand you standing still.
local function dropTool()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		pcall(function()
			hum:UnequipTools()
		end)
	end
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp.Anchored then
		hrp.Anchored = false
	end
end

local function setTrain(state)
	trainer.gen += 1
	local mine = trainer.gen
	trainer.on = state
	if not state then
		dropTool()
		goHome()
		post(("training off -- %d reps"):format(trainer.fired))
		return
	end
	if not Remotes.Train then
		trainer.on = false
		post("this build has no Train remote -- the game moved it")
		return
	end
	local swapped = equipBestDumbbell()
	if not trainTool() and not swapped then
		trainer.on = false
		post("no dumbbell in your backpack -- buy one first")
		return
	end
	post(swapped and ("training -- switched to %s, your strongest"):format(swapped) or "training")
	task.spawn(function()
		local seen, deaf = nil, 0
		local told = false
		local nextBest = os.clock() + 10
		while trainer.on and trainer.gen == mine and running do
			-- A dumbbell bought mid-session lands in the inventory, not in your hand.
			if os.clock() >= nextBest then
				nextBest = os.clock() + 10
				local name = equipBestDumbbell()
				if name then
					post("switched to " .. name .. ", your strongest dumbbell")
				end
			end
			if trainer.gym then
				local pos, mult = gymSpot()
				local char = player.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				if pos and hrp then
					-- Paced: if the server snaps the hop back, this is one retry every 2s,
					-- not a teleport every frame.
					if (hrp.Position - pos).Magnitude > GYM_REACH and os.clock() >= (trainer.nextHop or 0) then
						trainer.nextHop = os.clock() + 2
						trainer.home = trainer.home or hrp.CFrame
						pcall(function()
							char:PivotTo(CFrame.new(pos + Vector3.new(0, 3, 0)))
						end)
						post(("gym x%s is up -- training there"):format(tostring(mult)))
					end
				elseif trainer.home then
					goHome()
					post("gym buff over -- back where you were")
				end
			end
			-- Re-checked every tick rather than once: a respawn hands you a fresh
			-- character with the tool back in the backpack and the anchor gone with it.
			local tool = holdTool()
			local char = player.Character
			local at = char and char:GetAttribute("LastTrained")
			if char and tool and (not at or at <= workspace:GetServerTimeNow()) then
				pcall(function()
					Remotes.Train:Fire()
				end)
				trainer.fired += 1
				-- LastTrained is the server's answer: it only moves when a rep counted.
				-- Firing into a server that wants the tool in hand looks identical to
				-- working from here, so watch the attribute rather than the counter.
				if at == seen then
					deaf += 1
					if deaf >= TRAIN_DEAF and not told then
						told = true
						post(("Train ignored %d times while holding %s -- the server wants something else"):format(deaf, tool.Name))
					end
				else
					seen, deaf, told = at, 0, false
					status(("training -- %d reps"):format(trainer.fired))
				end
			end
			task.wait(TRAIN_POLL)
		end
	end)
end

-- The x2 button's id lives in the closure that built it, not on the instance, so there
-- is nothing to read and re-send. Firing the button's own Activated connection claims
-- with the right id and leaves the game's streak, VFX and counters consistent -- the
-- same idiom as calling a Touched handler instead of faking the touch.
local bonus = { on = false, conn = nil, claimed = 0 }

local function pressBonus(gui)
	if not gui or not gui.Parent then
		return false
	end
	local btn = gui:IsA("GuiButton") and gui or gui:FindFirstChildWhichIsA("GuiButton", true)
	if not btn then
		return false
	end
	local fired = false
	for _, c in ipairs(getconnections(btn.Activated)) do
		-- Executors disagree on the shape: some hand back a :Fire(), all have .Function.
		if typeof(c.Fire) == "function" then
			pcall(function()
				c:Fire()
			end)
			fired = true
		elseif typeof(c.Function) == "function" then
			pcall(c.Function)
			fired = true
		end
	end
	return fired
end

local function isBonus(child)
	return child:IsA("GuiObject") and child.Name:match("^ClickBonus")
end

local function setBonus(state)
	bonus.on = state
	if bonus.conn then
		pcall(function()
			bonus.conn:Disconnect()
		end)
		bonus.conn = nil
	end
	if not state then
		post(("x2 off -- %d claimed"):format(bonus.claimed))
		return
	end
	if type(getconnections) ~= "function" then
		bonus.on = false
		post("this executor has no getconnections -- can't claim the bonus for you")
		return
	end
	local gui = player:FindFirstChild("PlayerGui")
	local main = gui and gui:FindFirstChild("MainUI")
	if not main then
		bonus.on = false
		post("MainUI isn't there yet -- try again once the HUD has loaded")
		return
	end

	local function claim(child)
		if not bonus.on or not isBonus(child) then
			return
		end
		-- The clone is parented before its tween finishes; a couple of frames of grace
		-- costs nothing against a button that lives for seconds.
		task.wait(0.1)
		if pressBonus(child) then
			bonus.claimed += 1
			post(("claimed a %s bonus (%d)"):format(child.Name == "ClickBonusExtra" and "x4" or "x2", bonus.claimed))
		end
	end

	bonus.conn = main.ChildAdded:Connect(function(child)
		task.spawn(claim, child)
	end)
	-- One already on screen when the toggle went on.
	for _, child in ipairs(main:GetChildren()) do
		if isBonus(child) then
			task.spawn(claim, child)
		end
	end
	post("x2 on")
end

-- plot ---------------------------------------------------------------------------
-- Both unlocks live on the profile, and the client's own UI gates on exactly these two
-- flags. Reading them beats inferring ownership from a refusal, and lets a toggle say
-- "you don't own this" instead of firing a remote the server drops on the floor.
local function owns(flag)
	local state = profile()
	return state ~= nil and state[flag] == true
end

-- equip best ---------------------------------------------------------------------
-- The three modes, read out of the game's own EquipBestPlan (shared, so the server runs
-- the same code). Each sorts every scanned fish you own by one score and fills your slots
-- top-down:
--   BestNow      perFish at its current level and mutation -- income right now
--   BestPossible perFish at Lv 75 -- every fish gets the same 1.25^74 (~15M x), so this is
--                really "base earnings x mutation", blind to the levels you already bought
--   BestFlat     perFish at Lv 1, no mutation -- base earnings only
-- BestPossible is a trap without leveling: it swaps a Lv 30 fish for a Lv 1 rarer one that
-- earns a fraction of it today. With Auto upgrade on it's the right long-run pick,
-- because a level pays back in the same time on any fish -- so the rarer base wins once
-- the cheap levels are bought, and those are bought in minutes.
local equipper = { on = false, gen = 0, mode = "BestNow", done = 0 }

local function fishKey(name, level, mutation)
	return ("%s|%s|%s"):format(tostring(name), tostring(level or 1), tostring(mutation or ""))
end

-- True when the plot already holds exactly the plan the server would apply. Firing then
-- is a no-op that still burns the cooldown. Can't compute -> false, i.e. fire anyway.
local function planPlaced(mode)
	local state = profile()
	if not EquipBestPlan or not state then
		return false
	end
	local ok, plan = pcall(EquipBestPlan.compute, player, state, mode)
	if not ok or type(plan) ~= "table" or type(plan.Desired) ~= "table" then
		return false
	end
	local want = {}
	for _, c in ipairs(plan.Desired) do
		local k = fishKey(c.ConfigName, c.Level, c.Mutation)
		want[k] = (want[k] or 0) + 1
	end
	for _, s in pairs(state.baseSlots or {}) do
		if FishConfig and FishConfig[s.FishPlaced] then
			local k = fishKey(s.FishPlaced, s.Level, s.Mutation)
			if not want[k] then
				return false
			end
			want[k] -= 1
			if want[k] == 0 then
				want[k] = nil
			end
		end
	end
	return next(want) == nil
end

local function setEquip(state)
	equipper.gen += 1
	local mine = equipper.gen
	equipper.on = state
	if not state then
		post(("equip best off -- %d passes"):format(equipper.done))
		return
	end
	if not Remotes.RequestEquipBest then
		equipper.on = false
		post("this build has no RequestEquipBest")
		return
	end
	if not owns("hasEquipBest") then
		equipper.on = false
		post("Equip Best isn't unlocked -- $500k, use the button below")
		return
	end
	-- The game's own cooldown, read from its config rather than guessed: firing faster
	-- earns a "resting" notification and nothing else.
	local gap = (EquipBestConfig and tonumber(EquipBestConfig.Cooldown) or 10) + 0.5
	post(("equipping best (%s) whenever the plot falls behind"):format(equipper.mode))
	task.spawn(function()
		local last = -math.huge
		while equipper.on and equipper.gen == mine and running do
			-- Mode is read live, so a dropdown change applies on the next check.
			if os.clock() - last >= gap and not planPlaced(equipper.mode) then
				pcall(function()
					Remotes.RequestEquipBest:Fire(equipper.mode)
				end)
				last = os.clock()
				equipper.done += 1
				status(("equip best (%s) -- %d swaps"):format(equipper.mode, equipper.done))
			end
			task.wait(EQUIP_CHECK)
		end
	end)
end

-- auto upgrade -------------------------------------------------------------------
-- RequestUpgradeFish(slot) is cash only: the server's secureUpgradeFish reducer checks
-- money and does nothing when short (the "open Store" is the client's UI, not a charge).
-- Cost Earnings * 1.5^L, gain a quarter of the fish's income at 1.25^(L-1) -- so payback
-- ~ 5 * 1.2^L / (mutation x multiplier) seconds, and the best buy is always the lowest,
-- most-mutated level on the plot. Under a minute to ~Lv 10; hours past Lv 40.
local upgrader = { on = false, gen = 0, done = 0, maxPayback = UPGRADE_PAYBACK, maxLevel = UPGRADE_MAX_LEVEL }

-- Best affordable upgrade under the payback cap: slot, payback seconds. Computed with the
-- game's own FishEarnings, so rebirth, friend boost and mutations are all in the number.
local function bestUpgrade(state)
	local money = tonumber(state.money) or 0
	local slot, best
	for name, s in pairs(state.baseSlots or {}) do
		local cfg = FishConfig and FishConfig[s.FishPlaced]
		local lvl = s.Level or 1
		-- EarningsPercent fish have no Earnings to price a level from -- the server's
		-- reducer can't either, so skip rather than fire something it drops.
		local cap = math.min(upgrader.maxLevel, FishEarnings.FISH_MAX_LEVEL)
		if cfg and type(cfg.Earnings) == "number" and lvl < cap then
			local cost = FishEarnings.upgradeCost(s.FishPlaced, lvl)
			local gain = FishEarnings.perFish(player, s.FishPlaced, false, lvl + 1, s.Mutation)
				- FishEarnings.perFish(player, s.FishPlaced, false, lvl, s.Mutation)
			if gain > 0 and cost <= money then
				local payback = cost / gain
				if payback <= upgrader.maxPayback and (not best or payback < best) then
					slot, best = name, payback
				end
			end
		end
	end
	return slot, best
end

local function setUpgrade(state)
	upgrader.gen += 1
	local mine = upgrader.gen
	upgrader.on = state
	if not state then
		post(("auto upgrade off -- %d levels"):format(upgrader.done))
		return
	end
	if not Remotes.RequestUpgradeFish or not FishEarnings or not FishConfig then
		upgrader.on = false
		post("can't reach RequestUpgradeFish / FishEarnings -- the game moved them")
		return
	end
	post(("upgrading anything that pays back inside %.0f min"):format(upgrader.maxPayback / 60))
	task.spawn(function()
		while upgrader.on and upgrader.gen == mine and running do
			local st = profile()
			local ok, slot, payback = pcall(bestUpgrade, st or {})
			if ok and slot then
				pcall(function()
					Remotes.RequestUpgradeFish:Fire(slot)
				end)
				upgrader.done += 1
				status(("levelled slot %s (pays back in %.0fs) -- %d levels"):format(slot, payback, upgrader.done))
				task.wait(UPGRADE_GAP)
			else
				task.wait(UPGRADE_POLL)
			end
		end
	end)
end

-- auto sell ----------------------------------------------------------------------
-- Two ways to do this and they are not equivalent. With the unlock, the game's own
-- auto-sell runs server-side forever -- so it is a SETTING, not a loop, it costs nothing
-- per tick, and it keeps running after this panel is gone. Without it, we sell by hand.
local seller = { on = false, gen = 0, floor = 0, sold = 0, server = false }

local function applyServerAutoSell(enable)
	local n = 0
	for _, r in ipairs(RARITIES) do
		local want = enable and r.power < seller.floor
		pcall(function()
			Remotes.ToggleAutoSellRarity:Fire({ rarityId = r.id, enabled = want })
		end)
		if want then
			n += 1
		end
		task.wait(0.05)
	end
	return n
end

-- One pass of the manual seller. Keys are collected before firing: the inventory table is
-- the live profile state and it changes under you as the sells land.
local function sellPass()
	local state = profile()
	if not state or type(state.inventory) ~= "table" then
		return nil
	end
	local favourites = type(state.favorites) == "table" and state.favorites or {}
	local doomed = {}
	for key, entry in pairs(state.inventory) do
		if type(entry) == "table" and entry.Category == "Fish" and not favourites[key] then
			local power = powerOf(rarityOf(entry.ConfigName))
			if power and power < seller.floor then
				table.insert(doomed, key)
			end
		end
	end
	for _, key in ipairs(doomed) do
		if not seller.on then
			break
		end
		pcall(function()
			Remotes.SellFish:Fire(key)
		end)
		seller.sold += 1
		task.wait(SELL_GAP)
	end
	return #doomed
end

local function setSell(state)
	seller.gen += 1
	local mine = seller.gen
	seller.on = state
	if not state then
		if seller.server then
			-- Server state outlives the panel, so switching off has to actually turn it
			-- off -- otherwise a closed window keeps selling your fish.
			task.spawn(applyServerAutoSell, false)
			seller.server = false
		end
		post(("auto sell off -- %d sold"):format(seller.sold))
		return
	end
	if seller.floor <= 0 then
		seller.on = false
		post("pick a rarity to sell below first")
		return
	end
	if owns("hasAutoSell") and Remotes.ToggleAutoSellRarity then
		seller.server = true
		task.spawn(function()
			local n = applyServerAutoSell(true)
			post(("server auto-sell on for %d tiers -- it keeps running after this panel closes"):format(n))
		end)
		return
	end
	post("no auto-sell unlock -- selling by hand instead")
	task.spawn(function()
		while seller.on and seller.gen == mine and running do
			local n = sellPass()
			if n == nil then
				post("can't read your inventory -- stopping the seller")
				seller.on = false
				break
			end
			status(("auto sell -- %d sold"):format(seller.sold))
			task.wait(SELL_POLL)
		end
	end)
end

-- collect cash --------------------------------------------------------------------
local collector = { on = false, gen = 0, fired = 0 }

local function myStands()
	local out = {}
	if not ecs then
		return out
	end
	local ok, list = pcall(function()
		return ecs:GetComponents("TycoonStand")
	end)
	if not ok or type(list) ~= "table" then
		return out
	end
	for _, stand in pairs(list) do
		local mine = false
		pcall(function()
			mine = stand.Owner:Get() == player
		end)
		if mine then
			table.insert(out, stand)
		end
	end
	return out
end

-- DisplayedCash arrives as a number or as the label's own "$1.4K", which is why the
-- game's detector parses it the same way.
local function cashOn(stand)
	local ok, v = pcall(function()
		return stand.DisplayedCash:Get()
	end)
	if not ok then
		return 0
	end
	if type(v) == "number" then
		return v
	end
	if type(v) == "string" and ConvertValue then
		local ok2, n = pcall(function()
			return ConvertValue.parseSuffix((v:gsub("^%$", "")))
		end)
		return ok2 and tonumber(n) or 0
	end
	return 0
end

local function setCollect(state)
	collector.gen += 1
	local mine = collector.gen
	collector.on = state
	if not state then
		post(("collect off -- %d collected"):format(collector.fired))
		return
	end
	if not ecs or not Remotes.RequestCollectCash then
		collector.on = false
		post("can't reach the tycoon components -- collect unavailable")
		return
	end
	post("collecting cash")
	task.spawn(function()
		local warned = false
		while collector.on and collector.gen == mine and running do
			local stands, hits = myStands(), 0
			if #stands == 0 and not warned then
				warned = true
				post("no stands owned by you are loaded -- stand on your plot once")
			end
			for _, stand in ipairs(stands) do
				if not collector.on then
					break
				end
				if cashOn(stand) > 0 then
					local slot
					pcall(function()
						slot = stand.BaseSlotIndexName:Get()
					end)
					if type(slot) == "string" then
						pcall(function()
							Remotes.RequestCollectCash:Fire(slot)
						end)
						collector.fired += 1
						hits += 1
						task.wait(COLLECT_GAP)
					end
				end
			end
			if hits > 0 then
				status(("collected %d stands (%d total)"):format(hits, collector.fired))
			end
			task.wait(COLLECT_POLL)
		end
	end)
end

-- gui -------------------------------------------------------------------------
-- anti-afk -------------------------------------------------------------------------
-- Two layers. The nudge stops the idle kick: VirtualUser on Idled and on a beat, plus
-- VirtualInputManager because some clients ignore VirtualUser. The rejoin covers the
-- disconnects a nudge can't (server restart, network drop) -- an ErrorPrompt is the one
-- thing all of those share. Both are CoreGui/Player connections teardown can't reach
-- through the panel, so they live in afk.conns and every handler checks afk.on too.
local afk = { on = false, gen = 0, conns = {} }

local function nudge()
	pcall(function()
		local vu = game:GetService("VirtualUser")
		vu:CaptureController()
		vu:ClickButton2(Vector2.new())
	end)
	pcall(function()
		local vim = game:GetService("VirtualInputManager")
		vim:SendMouseButtonEvent(0, 0, 1, true, game, 0)
		vim:SendMouseButtonEvent(0, 0, 1, false, game, 0)
	end)
end

local function dropAfkConns()
	for _, c in ipairs(afk.conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(afk.conns)
end

local function setAfk(state)
	afk.gen += 1
	local mine = afk.gen
	afk.on = state
	dropAfkConns()
	if not state then
		post("anti-afk off")
		return
	end
	table.insert(afk.conns, player.Idled:Connect(nudge))
	task.spawn(function()
		-- WaitForChild yields, so it runs here rather than on the toggle's callback.
		local overlay
		pcall(function()
			overlay = game:GetService("CoreGui")
				:WaitForChild("RobloxPromptGui", 10)
				:WaitForChild("promptOverlay", 10)
		end)
		if overlay and afk.on and afk.gen == mine then
			table.insert(
				afk.conns,
				overlay.ChildAdded:Connect(function(child)
					if child.Name ~= "ErrorPrompt" or not (afk.on and running) then
						return
					end
					warn("[fish] disconnected -- rejoining in " .. REJOIN_DELAY .. "s")
					task.wait(REJOIN_DELAY)
					pcall(function()
						game:GetService("TeleportService"):Teleport(game.PlaceId, player)
					end)
				end)
			)
		elseif not overlay then
			warn("[fish] no promptOverlay -- anti-afk will nudge but can't rejoin")
		end
		while afk.on and afk.gen == mine and running do
			task.wait(AFK_BEAT)
			if afk.on and afk.gen == mine and running then
				nudge()
			end
		end
	end)
	post("anti-afk on")
end

local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Pull a Lucky Fish", -- fallback until the live name lands
	folder = "PullALuckyFish", -- unchanged: renaming it orphans configs already saved in-game
	size = UDim2.fromOffset(460, 380),
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })

-- Status sits at the top: it is the row you read while everything below it is running,
-- and at the bottom of a scrolling tab it was the first thing to go off screen.
local line = Tab:Paragraph({ Title = "Status", Desc = "idle" })

local Sec = Tab:Section({ Title = "Fishing", Icon = "solar:water-bold", Box = true, BoxBorder = true, Opened = true })

fishToggle = Sec:Toggle({
	Title = "Auto fish",
	Desc = "Cast, wait out the server's timer, collect. No animation. Don't cast by hand while this is on.",
	Value = false,
	Callback = setFarm,
})

Sec:Input({
	Title = "Cast power",
	Desc = "0 to 1. 0.93 and up is PERFECT.",
	Value = tostring(POWER),
	Placeholder = "0.97",
	Callback = function(text)
		local n = tonumber(text)
		if not n or n < 0 or n > 1 then
			post("cast power has to be a number between 0 and 1")
			return
		end
		farm.power = n
		post(("cast power %.2f"):format(n))
	end,
})

Sec:Dropdown({
	Title = "Minimum rarity",
	Desc = "Rerolls the cast until it hits this tier or rarer, then pays the wait. Any = keep the first roll.",
	Values = rarityNames(),
	Value = ANY,
	Callback = function(picked)
		local id = type(picked) == "table" and picked.Title or picked
		if id == ANY or id == nil or id == "" then
			minPower = 0
			post("filter off -- keeping the first roll")
			return
		end
		local power = powerOf(id)
		if not power then
			return -- a Refresh re-firing with something we don't know; leave the pick alone
		end
		minPower = power
		post(("keeping %s and above"):format(id))
	end,
})

Sec:Input({
	Title = "Max rerolls",
	Desc = "Rolls during the wait are free. This caps the extra ones after it (~0.06s each) before it takes what's pending.",
	Value = tostring(REROLL_CAP),
	Placeholder = "25",
	Callback = function(text)
		local n = tonumber(text)
		if not n or n < 1 then
			post("max rerolls has to be a number of at least 1")
			return
		end
		farm.cap = math.floor(n)
		post(("max rerolls %d -- up to %.1fs per cast"):format(farm.cap, farm.cap * REROLL_GAP))
	end,
})

Sec:Toggle({
	Title = "Always keep mutated",
	Desc = "A mutated fish is taken whatever its rarity. On its own, this rerolls until something is mutated.",
	Value = false,
	Callback = function(state)
		keepMutated = state
		post(state and "keeping mutated fish" or "ignoring mutations")
	end,
})

Sec:Toggle({
	Title = "Fast casts",
	Desc = "With no rarity filter: rerolls casts with extra slot rows (~3.8s each) for a one-row one. Trades luck/gem-pack rows for fish per minute; mutated, beast, boss and golden rolls are always kept.",
	Value = false,
	Callback = function(state)
		fastCasts = state
		post(state and ("fast casts on -- up to %d rerolls for a one-row cast"):format(FAST_CAP) or "fast casts off")
	end,
})

Sec:Button({
	Title = "Boss odds",
	Desc = "Your chance per roll and the server's boss stock. Stock 0 = nobody catches one until it restocks.",
	Callback = function()
		post(bossOdds() or "can't read the boss pool -- the game moved getBossPool")
	end,
})

local Gym =
	Tab:Section({ Title = "Training", Icon = "solar:dumbbell-large-bold", Box = true, BoxBorder = true, Opened = true })

Gym:Toggle({
	Title = "Auto train",
	Desc = "Equips your dumbbell, clears the anchor it puts on you, and trains on the server's cooldown. Walk and fish as normal; it's put away when you switch this off.",
	Value = false,
	Callback = setTrain,
})

Gym:Toggle({
	Title = "Train at gym events",
	Desc = "While Auto train is on: moves you into the gym-event zone (x1.5 to x5) or onto a Mini Gym (x1.5) while one is up, and back when it ends. Fishing may refuse while you're away from the pier.",
	Value = false,
	Callback = function(state)
		trainer.gym = state
		if not state then
			goHome()
		end
		post(state and "chasing gym buffs while training" or "gym chase off")
	end,
})

Gym:Toggle({
	Title = "Auto x2",
	Desc = "Claims the x2 / x4 click bonus the instant it appears, by pressing the game's own button.",
	Value = false,
	Callback = setBonus,
})

local Session =
	Tab:Section({ Title = "Session", Icon = "solar:shield-check-bold", Box = true, BoxBorder = true, Opened = true })

Session:Toggle({
	Title = "Anti-AFK",
	Desc = "Clicks for you so the idle kick never lands, and rejoins this game if you get disconnected anyway.",
	Value = true,
	Callback = setAfk,
})
-- A starting Value doesn't fire the callback, so on-by-default has to be armed by hand.
setAfk(true)

-- Its own tab rather than a third card on Main: nothing here shares state with the
-- fishing or training loops, and Main was long enough to scroll.
local PlotTab = Window:Tab({ Title = "Plot", Icon = "solar:wallet-money-bold" })
local Plot =
	PlotTab:Section({ Title = "Plot", Icon = "solar:wallet-money-bold", Box = true, BoxBorder = true, Opened = true })

Plot:Toggle({
	Title = "Auto collect cash",
	Desc = "Sweeps every stand whose Owner is you and fires the collect remote. No walking over buttons.",
	Value = false,
	Callback = setCollect,
})

Plot:Toggle({
	Title = "Auto equip best",
	Desc = "Fires the game's Equip Best whenever its plan differs from your plot (10s cooldown). Needs the $500k unlock.",
	Value = false,
	Callback = setEquip,
})

Plot:Dropdown({
	Title = "Equip best mode",
	Desc = "Now: most cash/s today. Possible: best at Lv 75, i.e. rarity x mutation, ignoring levels -- only pair it with Auto upgrade. Flat: base earnings only.",
	Values = { "BestNow", "BestPossible", "BestFlat" },
	Value = "BestNow",
	Callback = function(picked)
		local id = type(picked) == "table" and picked.Title or picked
		if type(id) == "string" and id ~= "" then
			equipper.mode = id
			post("equip best mode: " .. id)
		end
	end,
})

Plot:Toggle({
	Title = "Auto upgrade",
	Desc = "Levels placed fish, fastest payback first, with your cash. Stops at the level and payback caps below.",
	Value = false,
	Callback = setUpgrade,
})

Plot:Slider({
	Title = "Upgrade up to level",
	Desc = "No placed fish is levelled past this.",
	Step = 1,
	Value = { Min = 1, Max = 75, Default = UPGRADE_MAX_LEVEL },
	Callback = function(v)
		upgrader.maxLevel = math.clamp(math.floor(tonumber(v) or UPGRADE_MAX_LEVEL), 1, 75)
	end,
})

Plot:Input({
	Title = "Max payback (min)",
	Desc = "Only buy a level that earns its cost back within this many minutes. Lower it to save cash for rods/rebirth.",
	Value = tostring(UPGRADE_PAYBACK / 60),
	Placeholder = "30",
	Callback = function(text)
		local n = tonumber(text)
		if not n or n <= 0 then
			post("max payback has to be a number of minutes above 0")
			return
		end
		upgrader.maxPayback = n * 60
		post(("upgrading anything that pays back inside %.0f min"):format(n))
	end,
})

Plot:Button({
	Title = "Buy Equip Best ($500k)",
	Desc = "One-off unlock, paid in cash. Never fired automatically.",
	Callback = function()
		if owns("hasEquipBest") then
			post("you already own Equip Best")
			return
		end
		Window:Dialog({
			Title = "Buy Equip Best",
			Content = "Spend $500,000 to unlock Equip Best? This is your in-game cash.",
			Buttons = {
				{ Title = "Cancel", Variant = "Secondary" },
				{
					Title = "Buy",
					Variant = "Primary",
					Callback = function()
						pcall(function()
							Remotes.RequestBuyEquipBest:Fire()
						end)
						post("asked the server to unlock Equip Best")
					end,
				},
			},
		})
	end,
})

Plot:Dropdown({
	Title = "Sell below",
	Desc = "Everything under this tier gets sold. Uses the game's own auto-sell if you own it, otherwise sells by hand.",
	Values = rarityNames(),
	Value = ANY,
	Callback = function(picked)
		local id = type(picked) == "table" and picked.Title or picked
		if id == ANY or id == nil or id == "" then
			seller.floor = 0
			post("auto sell floor cleared")
			return
		end
		local power = powerOf(id)
		if not power then
			return
		end
		seller.floor = power
		post(("selling everything below %s"):format(id))
		-- The manual loop reads the floor live, but the server-side one was configured
		-- once when the toggle went on -- so a floor change has to be pushed again.
		if seller.on and seller.server then
			task.spawn(applyServerAutoSell, true)
		end
	end,
})

Plot:Toggle({
	Title = "Auto sell",
	Desc = "Set the floor above first.",
	Value = false,
	Callback = setSell,
})

-- Drains whatever the loop last left. pcall'd anyway: if even this cannot write the
-- panel the run carries on with the status going nowhere, rather than taking the loop
-- down with it. Held in an upvalue and disconnected by stopAll -- it outlives
-- Window:Destroy otherwise, re-pcalling into a destroyed row every frame.
local drain, lastPrinted
drain = RunService.Heartbeat:Connect(function()
	if pending == nil then
		return
	end
	local msg, quiet = pending, pendingQuiet
	pending = nil
	pcall(function()
		line:SetDesc(msg)
	end)
	if not quiet and msg ~= lastPrinted then
		lastPrinted = msg
		print("[fish]", msg)
	end
end)

-- A farm thread parked in a yield cannot report anything, so the watchdog is its own
-- thread. Names the half of the step, not just the step: "collect" and "waiting" stop
-- for completely different reasons.
task.spawn(function()
	local told
	while running do
		task.wait(5)
		if farm.on and os.clock() - markAt > STUCK_AFTER and told ~= mark then
			told = mark
			warn(("[fish] stuck %ds at: %s"):format(math.floor(os.clock() - markAt), mark))
		end
	end
end)

local n = fishCount()
post(n and ("ready -- %d/%d fish in inventory"):format(n, InvCfg and InvCfg.FishLimit or 0) or "ready")

-- close ------------------------------------------------------------------------
local function stopAll()
	running = false
	farm.on = false
	farm.gen += 1
	trainer.on = false
	trainer.gen += 1
	dropTool() -- never leave the player holding a dumbbell we equipped, or anchored
	goHome() -- or parked at a gym
	equipper.on = false
	equipper.gen += 1
	upgrader.on = false
	upgrader.gen += 1
	afk.on = false
	afk.gen += 1
	dropAfkConns() -- a stopped script must not rejoin you
	collector.on = false
	collector.gen += 1
	seller.on = false
	seller.gen += 1
	-- The one piece of state that outlives us: the game's own auto-sell is server-side,
	-- so leaving it on would keep selling fish with no panel to switch it off from.
	if seller.server then
		seller.server = false
		task.spawn(applyServerAutoSell, false)
	end
	bonus.on = false
	if bonus.conn then
		pcall(function()
			bonus.conn:Disconnect()
		end)
		bonus.conn = nil
	end
	-- Leaving this true strands the server thinking you are mid-cast, which is what
	-- makes the next manual cast do nothing.
	pcall(function()
		Remotes.SetFishState:Fire(false)
	end)
	pcall(function()
		drain:Disconnect()
	end)
end

Window:OnDestroy(function()
	stopAll()
	getgenv().luckyFishStop = nil
end)

getgenv().luckyFishStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().luckyFishStop = nil
end
