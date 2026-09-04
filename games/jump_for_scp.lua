--[[ Jump for SCP -- tick the Lucky Block rarities you want, it fetches and banks them

     RARITY    : multi-select over the twelve rarities that have a spawn zone in the
                 tower, named the way the GAME names them -- Ultimate, Oblivion. The
                 `rarity` attribute on the model says something else on nearly every row
                 (the Explorer's Mythic is the billboard's Legendary); the RARITY table
                 in config is where that mapping lives, and it's the only place it does.
                 Ticking only ticks; AUTO FARM is what acts on it, and it re-reads the
                 ticks every pass, so retick mid-farm lands without a restart.
     AUTO FARM : toggle. Rescans every pass, works the ticked rarities BEST FIRST:

                     TP onto the block -> hold StealPrompt -> TP to your plot -> banked

                 Nothing ticked is out? It parks you at base and waits, rather than
                 hovering wherever the last trip ended.

                 Banking is not a remote. Carrying a block onto your own plot is what
                 makes the server move it into Data.Inventory -- the same Inventory the
                 stands' Place prompts light up for. This script stops there: PLACING
                 and OPENING are yours to do.

                 A carried block is NOT removed from workspace.Live.Slimes and does NOT
                 become a Tool on your character. The model stays in the folder and
                 gains heldBy = the holder's UserId; that attribute is the grab
                 succeeding, the way to count what you're carrying, and the reason
                 blocks already in someone's hands get skipped when scanning.

                 Carry limit starts at 1, so every trip is exactly one block.

                 The in-game "Teleport to Base" button is a DEVELOPER PRODUCT, charged
                 every press. Nothing here touches it; the trip home is a PivotTo.

     SNIPE     : the tower's top five rarities spawn on a clock, and the board in the
                 map counts it down ("OBLIVION in 03:32"). That countdown is two
                 attributes on workspace -- NextSpecialLabel and NextSpecialLeft -- and
                 this reads them straight.

                 With HOLD FOR SPECIALS on, once a TICKED special is inside SNIPE_LEAD s
                 the farm stops taking anything ranked below it and idles at base with
                 empty hands. That's the whole snipe: at carry limit 1, being mid-trip
                 with a Common in your arms is the only way to actually miss the spawn.
                 The moment it lands, the normal best-first pass has it -- an Oblivion
                 outranks everything else on the map by construction.

     TIMERS    : every clock the server publishes, rebuilt once a second:

                     Next special   Ultimate   in 2:08   holds at 20s
                     On the map     Nightmare 0:47   Ultimate 1:52
                     Events         Cursed 4:31   Gold 11:07

                 NEXT SPECIAL is the board in the map. There is only one of these to
                 show: workspace carries NextSpecialLabel and NextSpecialLeft, singular,
                 and the game publishes no per-rarity schedule -- a row per special
                 would be five copies of one number. The last field is the half worth
                 reading ("not ticked" / "snipe off" / "holds at 20s" / "holding"),
                 since a countdown you aren't set up to act on looks exactly like one
                 you are.

                 ON THE MAP is each spawned special's DESPAWN clock: every block carries
                 a `timer` attribute, an absolute deadline ~120s after it spawned, and
                 that's the number on its own billboard. Time left to go get it.

                 EVENTS is the mutation and spawn events -- Cursed, Gold, Rainbow,
                 Volcanic, Taco, Alien, US -- each of which publishes its end time as a
                 workspace attribute named event_<Name>. Found by prefix, not from a
                 list, so one the game adds later shows up with no edit.

                 All three are read-only. Nothing here buys a "Spawn Now" -- those are
                 developer products, charged per press.

     CASH      : collects every paying stand on YOUR plot, every CASH_POLL seconds, from
                 wherever you happen to be standing -- the top of the tower included.
                 Touching a CollectPad runs a CLIENT handler that ends in
                 Collect Earnings(padName), so this fires that remote directly: no
                 walking the pads, and no 0.6s-per-pad cooldown. Runs whether or not
                 AUTO FARM is on.

                 Which stands to fire at comes from Data.PlotSlimes -- your own save
                 copy, the same table the game reads to decide which pads light up. It
                 has to be data and not instances: the farm parks you thousands of studs
                 up the tower, your plot streams out, and any gate built on the stand
                 Models in Live.PlayerSlimes then finds nothing and sweeps nothing
                 everywhere except standing at base. Live.PlayerSlimes is still the
                 fallback for an executor without getrenv.

                 A LUCKY BLOCK parked on a stand is skipped: it earns nothing until it's
                 opened, and SlimeRegistry gives every Lucky Block MoneyPerSecond = 0,
                 which is the same test the game makes before leaving those pads dark.
                 Without a gate a 90-pad plot is ~90 refused remotes a sweep.

                 Pads go out SWEEP_STEP apart, never as a burst. The server debounces
                 this remote PER PLAYER at the same 0.6s its own pad handler uses, so a
                 plot fired in one frame pays exactly one pad. That was measured, not
                 guessed: one frame paid 1 stand, 0.25s spacing paid 2 -- every other
                 fire, which is what a ~0.5s window does to a 0.25s cadence.

                 So a full 100-stand plot is a ~65s sweep, and the row counts up as it
                 goes. That's the server's rate, not ours, and nothing is lost to it --
                 earnings keep accruing while you work down the list.

                 AutoCollectPad, singular, is the gamepass upsell pad. Untouched.
     BASE      : where a grabbed block gets carried, found per trip: your plot in
                 workspace.Plots (owner == your name) and its Base.Teleport attachment,
                 so this needs no setup and works for whoever runs it. BASE_POS is the
                 fallback if no plot is yours yet. SET BASE overrides both with wherever
                 you're standing; GO TO BASE is a plain TP for getting out of trouble.
     LIVE      : recounts workspace.Live.Slimes every COUNT_EVERY seconds, by the raw
                 rarity attribute -- so a rarity this script has never heard of still
                 shows up here, which is the tell that RARITY below needs a row.

     STREAMING is the thing to know about this game. The tower is 4800 studs tall and
     streaming is on, so from your plot Spain is ~2900 studs away, Icons ~4000 and Japan
     ~4900 -- all outside the radius. Up there a block replicates as a MODEL only: name,
     rarity, timer and WorldPivot all arrive, its RootPart and StealPrompt do not. So
     the scan matches on the model and its pivot and never on PrimaryPart, and the grab
     hops there FIRST and then waits STREAM_TIMEOUT for the parts to show up. Gate the
     scan on PrimaryPart and every special is invisible until you have walked into its
     zone by hand -- which is the one case where you don't need this script.

     The same thing is visible in a dump taken from the ground: Map.SpawnParts.Japan,
     .Icons and .Spain are there with their attributes and no Part children at all,
     while Champions and everything below it has its two parts each.

     Blocks FALL in -- every one carries fallHeight / fallSpeed / Levitate / groundY --
     so the grab makes ONE real teleport onto the block and then re-aims off its LIVE
     pivot whenever it has drifted more than REAIM studs. Following it down is what
     makes a falling or levitating block grabbable without timing anything; only
     re-aiming when it has actually got away is what keeps that from reading as a
     stutter, since a PivotTo every FIRE_STEP is twenty of them a second.

     Executor only: the UI is WindUI, pulled in with HttpGet, which Studio blocks.
     The minus button rolls the panel up to a bare Zegion pill -- click it to come back.
     RightControl does the same from the keyboard, and RightAlt hides the window
     outright. Farming keeps running under either.
     Stop for good: getgenv().jumpSCPStop() ]]

-- config ---------------------------------------------------------------------
local GRAB_OFFSET = Vector3.new(0, 4, 0) -- above the block's pivot; must land inside the prompt's 10 studs
local GRAB_TIME = 0.9 -- seconds hammering one block before giving up. StealPrompt holds for 0.5
local FIRE_STEP = 0.05 -- between prompt fires
-- How far a block may drift before the grab re-aims at it. StealPrompt reaches 10 studs,
-- so 6 leaves room for a couple more fall steps before the hold would be refused.
-- Dropping this towards 0 re-teleports you every step, which is visible as a stutter;
-- raising it past 10 loses blocks on the way down.
local REAIM = 6
-- Close enough to base to count as "at base". Idling re-parks you every IDLE seconds,
-- and pivoting to a spot you're already standing on is the hop-on-the-spot; this is
-- what makes idle actually idle. Wider than the plot only if your bank stops landing.
local AT_BASE = 15
local BASE_WAIT = 0.6 -- at base before checking, so the server sees you arrive
local BANK_STEP = 0.2 -- between re-TPs while waiting for the bank to register
local BANK_TIMEOUT = 4 -- give up on a bank after this; FULL_MISSES then stops the farm
-- Failed banks in a row before stopping. Reached when the block can't go anywhere:
-- backpack at 50/50, or SET BASE points somewhere off your plot.
local FULL_MISSES = 2
-- Only used when your plot can't be found in workspace.Plots (you own none, or owner
-- hasn't replicated yet). Normally the plot's own Base.Teleport wins, which is what
-- makes this work for anyone; SET BASE overrides both.
local BASE_POS = Vector3.new(198, 3, 339)
local CASH_POLL = 5 -- seconds between cash sweeps of your own plot's collect pads
-- Gap between the individual pads in one sweep, and the whole reason the sweep is a
-- loop with a wait in it rather than one burst.
--
-- The server debounces Collect Earnings PER PLAYER, at the same 0.6s the game's own pad
-- handler uses. Measured, not guessed: firing every occupied stand in one frame paid
-- out exactly ONE pad, and spacing them 0.25s apart paid out exactly TWO -- every
-- other fire, which is what a ~0.5s window does to a 0.25s cadence. So this has to sit
-- just above the game's own number, not below it.
--
-- The price is real and unavoidable: a full 100-stand plot takes ~65s to sweep. That's
-- the server's rate, not ours. Nothing is lost by it -- earnings keep accruing while
-- you work down the list.
local SWEEP_STEP = 0.65
local IDLE = 3 -- parked at base after a pass that found nothing, rather than rescanning flat out
local COUNT_EVERY = 2 -- seconds between LIVE recounts
-- Max wait for a region to replicate: once before the jump, once after it while the
-- block's own parts arrive. The tower is 4800 studs tall and streaming is on, so a hop
-- from your plot to the Oblivion floor is a real load, not a nudge. Raise it if far
-- specials get abandoned the instant you land next to them.
local STREAM_TIMEOUT = 5
-- How early to stop taking lesser blocks and wait for a ticked special. One round trip
-- is ~3s; the rest is slack for a grab that misses and has to be retried.
local SNIPE_LEAD = 20
-- Settings.InventoryLimits.LuckyBlocks. Only used for the "banked n/50" readout -- the
-- farm stops on banks that don't land, not on this number, so a game that raises the
-- cap costs you a wrong label and nothing else.
local BAG_LIMIT = 50
local KEY_TOGGLE = Enum.KeyCode.RightControl

-- Best first, and this one array is display order, farm order and rank all at once, so
-- there is no second ordering to keep in sync.
--
-- First field is what the game shows you and the only thing the panel ever prints;
-- second is the `rarity` attribute on the model (also the folder name in
-- workspace.Map.SpawnParts), which is what everything here matches on. They disagree on
-- nearly every row -- Shared.RARITY_DISPLAY shifts the whole middle of the ladder down
-- one, so the Explorer's "Mythic" is the billboard's "Legendary". This table is the
-- only place that mapping lives; if a row ever looks wrong in the panel, it's wrong
-- here.
--
-- Ordered by SlimeRegistry.RARITY_MPS, not by Shared.RarityOrders: that table puts
-- LIMITED at 15, above Japan, while its money band is Exclusive's. Money is the honest
-- rank here.
--
-- Twelve rows because that's how many zones workspace.Map.SpawnParts has. Exclusive,
-- LIMITED and Divine exist in the registry but no zone spawns them -- they come out of
-- the shop straight into your bag -- so a row for them would never count. If one ever
-- turns up on the map the LIVE card is where you'll see it.
local RARITY = {
	{ "Oblivion", "Japan" }, -- 209M - 660M / sec
	{ "Meltdown", "Icons" }, -- 82.5M - 270M
	{ "Apocalypse", "Spain" }, -- 18.4M - 57.5M
	{ "Nightmare", "Champions" }, -- 5.25M - 15.75M
	{ "Ultimate", "OG" }, -- 1.1M - 3.6M   <- lowest of the five clocked specials
	{ "Godly", "Slime God" }, -- 95k - 312k
	{ "Secret", "Secret" }, -- 29k - 92k
	{ "Legendary", "Mythic" }, -- 8.5k - 27k
	{ "Epic", "Legendary" }, -- 2.5k - 8k
	{ "Rare", "Epic" }, -- 750 - 2.3k
	{ "Uncommon", "Rare" }, -- 220 - 700
	{ "Common", "Common" }, -- 5 - 200
}

-- Everything from this row up is a "special": the five the game puts on a clock, which
-- is exactly the five with a "Spawn Now" developer product in Settings. The countdown
-- board in the map is always announcing one of these, and they're the rows the SNIPE
-- card watches.
local SPECIAL_FLOOR = "OG"

local Players = game:GetService("Players")
local player = Players.LocalPlayer

if getgenv and getgenv().jumpSCPStop then
	getgenv().jumpSCPStop() -- re-running must not stack a second window/loop
end

-- Three views of the one table above: the dropdown's rows, row -> attribute, and the
-- rank the farm sorts on. Built rather than written out, so RARITY stays the only place
-- an order or a name lives.
local ROWS, ATTR, RANK, SHOWN = {}, {}, {}, {}
for i, pair in ipairs(RARITY) do
	ROWS[i] = pair[1]
	ATTR[pair[1]] = pair[2]
	RANK[pair[2]] = #RARITY - i
	SHOWN[pair[2]] = pair[1]
end
assert(RANK["Japan"] > RANK["Common"], "RARITY must run best first")

local SPECIAL_RANK = assert(RANK[SPECIAL_FLOOR], "SPECIAL_FLOOR must be one of RARITY's attributes")

-- world ----------------------------------------------------------------------
local function hrp()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- Re-found every scan rather than cached: the folder is emptied and refilled as blocks
-- spawn and get taken, and a stale reference to a destroyed one throws mid-farm.
local function slimeFolder()
	local live = workspace:FindFirstChild("Live")
	return live and live:FindFirstChild("Slimes")
end

-- Carrying is an attribute on the BLOCK, not a Tool on you: the model stays in
-- workspace.Live.Slimes and gets heldBy = the holder's UserId (the game's own
-- SlimesTimer reads exactly this to fly the stack behind whoever grabbed it). Nothing
-- appears in your character -- that's the slime-off-a-stand mechanic, a different one.
local function heldBy(model)
	local id = model:GetAttribute("heldBy")
	return typeof(id) == "number" and id or nil
end

-- Every wild block ships a `timer` attribute: an absolute deadline, ~120s after its
-- spawnTime, and the exact number its own billboard counts down. Read against
-- GetServerTimeNow, not os.time -- the game's SlimesTimer uses the former, and the two
-- are different clocks. A block that reaches it goes back where it came from.
local function despawnIn(model)
	local deadline = tonumber(model:GetAttribute("timer"))
	return deadline and math.max(0, deadline - workspace:GetServerTimeNow()) or nil
end

local function heldCount()
	local folder = slimeFolder()
	if not folder then
		return 0
	end
	local n = 0
	for _, model in ipairs(folder:GetChildren()) do
		if heldBy(model) == player.UserId then
			n += 1
		end
	end
	return n
end

-- want = set of attribute -> true, or nil for "everything" (that's the LIVE card's
-- call, which wants the unlisted rarities too).
local function scanBlocks(want)
	local out = {}
	local folder = slimeFolder()
	if not folder then
		return out
	end
	local root = hrp()
	local from = root and root.Position or Vector3.new()
	for _, model in ipairs(folder:GetChildren()) do
		-- rarity is the filter AND the identity: every wild block carries it, and it's
		-- what the grab sorts on. Anything already in someone's hands is skipped, yours
		-- included -- it isn't grabbable, and your own carried block flies with you, so
		-- it would otherwise be the nearest target on every single pass.
		--
		-- Deliberately NOT gated on PrimaryPart. This place has streaming on, and the
		-- tower is 4800 studs tall: from your plot, Spain is ~2900 studs away and Japan
		-- ~4900, well outside the radius. A block up there replicates as a MODEL --
		-- name, rarity, timer, WorldPivot, all of it -- while its RootPart does not, so
		-- PrimaryPart is nil. Requiring it made every special invisible until you had
		-- walked into its zone by hand, which is the one case where you don't need this
		-- script. Streaming the parts in is the grab's job, not the scan's.
		local rarity = model:IsA("Model") and model:GetAttribute("rarity")
		if rarity and not heldBy(model) then
			local pos = model:GetPivot().Position
			-- A Model with no parts AND no pivot ever written reports the origin. No
			-- zone is anywhere near it (x is ~198 across the whole tower), so this is a
			-- safe "position not replicated yet" sentinel -- and teleporting to 0,0,0 is
			-- worse than waiting a pass for the real one.
			if (not want or want[rarity]) and pos.Magnitude > 1 then
				table.insert(out, {
					model = model,
					rarity = rarity,
					rank = RANK[rarity] or 0,
					dist = (pos - from).Magnitude,
					streamed = model.PrimaryPart ~= nil,
				})
			end
		end
	end
	-- Rarity first, then whatever is closest inside it. Distance is only a tiebreak: an
	-- Oblivion block at the top of the tower still beats a Common at your feet.
	table.sort(out, function(a, b)
		if a.rank ~= b.rank then
			return a.rank > b.rank
		end
		return a.dist < b.dist
	end)
	return out
end

-- No offset means "use this CFrame exactly". With an offset we take position only,
-- because a block's own rotation would tilt the character with it.
local function targetOf(cf, offset)
	return offset and CFrame.new(cf.Position + offset) or cf
end

-- The bare jump, and nothing else. Both of the things tp() does around this one line
-- YIELD -- RequestStreamAroundAsync is a web-shaped call and the pause wait is a loop --
-- so doing them on every step of a grab is what turns following a falling block into a
-- stutter. Use this to re-aim inside a region you have already arrived in.
local function reaim(cf, offset)
	local char = player.Character
	if not (cf and char and hrp()) then
		return false
	end
	char:PivotTo(targetOf(cf, offset))
	return true
end

-- The real arrival: request the region, jump, then wait out the streaming pause.
-- GameplayPaused means you landed somewhere the client hasn't received yet, and every
-- prompt hold during a pause is refused on range.
local function tp(cf, offset)
	if not cf then
		return false
	end
	pcall(function()
		player:RequestStreamAroundAsync(targetOf(cf, offset).Position, STREAM_TIMEOUT)
	end)
	if not reaim(cf, offset) then
		return false
	end
	local deadline = os.clock() + STREAM_TIMEOUT
	while player.GameplayPaused and os.clock() < deadline do
		task.wait(0.05)
	end
	return true
end

local function fire(prompt)
	prompt.RequiresLineOfSight = false -- client-side only, but the client is what gates it
	if fireproximityprompt then
		fireproximityprompt(prompt, 1)
	else
		-- ponytail: no executor globals -- the honest hold, which needs you in range.
		prompt:InputHoldBegin()
		task.wait(prompt.HoldDuration + 0.1)
		prompt:InputHoldEnd()
	end
end

-- Every wild block ships a RootPart.StealPrompt, so touch() is only the fallback for
-- one that somehow doesn't. Left in because it costs two lines and a missing prompt
-- would otherwise stall the pass silently.
local function touch(part)
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	if not (firetouchinterest and head and part) then
		return
	end
	pcall(function()
		firetouchinterest(head, part, true)
		task.wait()
		firetouchinterest(head, part, false)
	end)
end

-- plot -----------------------------------------------------------------------
-- Your plot is the one in workspace.Plots whose owner StringValue is your name -- the
-- same scan the game's own GetMyPlot does. Re-found rather than cached: owner is
-- written after you join, and plots get reassigned as players leave.
local function myPlot()
	local plots = workspace:FindFirstChild("Plots")
	if not plots then
		return nil
	end
	for _, plot in ipairs(plots:GetChildren()) do
		local owner = plot:FindFirstChild("owner")
		if owner and owner:IsA("StringValue") and owner.Value == player.Name then
			return plot
		end
	end
	return nil
end

-- What's already banked, read off the client's own copy of your save. Only for the
-- readout -- the farm decides on banks that land, not on this -- so every step is
-- optional and a nil just prints nothing.
--
-- getrenv() because _Lib lives on the GAME's _G, which is a different table from the
-- executor's. Inventory holds slimes and blocks together, hence the Type filter.
local function banked()
	local ok, n = pcall(function()
		local lib = getrenv and getrenv()._G and getrenv()._G._Lib
		local data = lib and lib.Data and lib.Data:Get()
		local inv = data and data.Inventory
		local db = lib and lib.Database and lib.Database.Slimes
		if type(inv) ~= "table" or type(db) ~= "table" then
			return nil
		end
		local c = 0
		for _, entry in ipairs(inv) do
			local def = db[tostring(entry and entry.id)]
			if def and def.Type == "Lucky Block" then
				c += 1
			end
		end
		return c
	end)
	return ok and n or nil
end

-- cash -----------------------------------------------------------------------
-- Each CollectPads child is named for the stand it serves, and touching its Top runs a
-- CLIENT handler that ends in Collect Earnings:Fire(padName) -- so fire that directly
-- and skip both the walk and the handler's 0.6s per-pad cooldown.
--
-- MyPlot.AutoCollectPad, singular, is the gamepass upsell pad and a different thing
-- entirely. Untouched, like every other product in this game.
local collectEarnings
do
	local shared = game:GetService("ReplicatedStorage"):WaitForChild("SharedModules", 10)
	local network = shared and shared:WaitForChild("Network", 10)
	local remotes = network and network:WaitForChild("Remotes", 10)
	collectEarnings = remotes and remotes:FindFirstChild("Collect Earnings")
	if not collectEarnings then
		warn("[JumpSCP] no Collect Earnings remote -- the cash sweep will do nothing")
	end
end

-- Which stands are worth firing at. A 90-pad plot fired blind is ~90 refused remotes
-- every sweep, so there has to be a gate -- but it must not be one that streaming can
-- take away, and the obvious one is.
--
-- FIRST the client's own save copy: Data.PlotSlimes, keyed by stand name, the exact
-- table the game's own refreshCollectPadGuis reads to decide which pads light up. It is
-- DATA, not instances, so streaming cannot touch it. That is the whole point. This
-- started out gated on Live.PlayerSlimes[you][standName] and its MoneyPerSecond
-- attribute, which is correct and completely useless: those are Models, the farm parks
-- you thousands of studs up the tower, your plot streams out, and the gate then finds
-- nothing and sweeps nothing anywhere except standing at base.
--
-- An entry whose id is a LUCKY BLOCK is skipped: a block parked on a stand earns
-- nothing until it's opened, and SlimeRegistry gives every Lucky Block MoneyPerSecond
-- = 0. That's the same test the game makes before leaving those pads dark.
--
-- THEN the world, for an executor without getrenv -- same idea off Live.PlayerSlimes,
-- and right whenever your plot is loaded.
local function payingStands()
	local ok, names = pcall(function()
		local lib = getrenv and getrenv()._G and getrenv()._G._Lib
		local data = lib and lib.Data and lib.Data:Get()
		local placed = data and data.PlotSlimes
		local db = lib and lib.Database and lib.Database.Slimes
		if type(placed) ~= "table" then
			return nil
		end
		local out = {}
		for stand, entry in pairs(placed) do
			local def = db and entry and db[tostring(entry.id)]
			if not (def and def.Type == "Lucky Block") then
				table.insert(out, tostring(stand))
			end
		end
		return out
	end)
	if ok and names then
		return names
	end

	local out = {}
	local live = workspace:FindFirstChild("Live")
	local slimes = live and live:FindFirstChild("PlayerSlimes")
	local mine = slimes and slimes:FindFirstChild(player.Name)
	if not mine then
		return out
	end
	for _, stand in ipairs(mine:GetChildren()) do
		local mps = tonumber(stand:GetAttribute("MoneyPerSecond"))
		if mps and mps > 0 then
			table.insert(out, stand.Name)
		end
	end
	return out
end

-- No plot-ownership check: every name above came out of YOUR save or YOUR folder, so
-- there is nothing here that could point at someone else's pads.
--
-- `alive` is checked between pads because the sweep now yields: at SWEEP_STEP per stand
-- a full plot takes half a minute, and without this an off-click would keep firing to
-- the end of the list.
local function collectCash(alive, report)
	if not collectEarnings then
		return 0
	end
	local stands = payingStands()
	local n = 0
	for i, stand in ipairs(stands) do
		if alive and not alive() then
			break
		end
		collectEarnings:FireServer(stand)
		n = i
		if report then
			report(i, #stands)
		end
		task.wait(SWEEP_STEP)
	end
	return n
end

-- snipe ----------------------------------------------------------------------
-- The board in the map ("OBLIVION in 03:32") is these two attributes on workspace.
-- NextSpecialLeft is a one-shot number of seconds, not a ticking one, so the read is
-- stamped and counted down locally -- correct whether or not the server rewrites it.
local specialLabel, specialLeft, specialAt = nil, nil, 0

local function readSpecial()
	specialLabel = workspace:GetAttribute("NextSpecialLabel")
	specialLeft = tonumber(workspace:GetAttribute("NextSpecialLeft"))
	specialAt = os.clock()
end

local function specialIn()
	if not specialLeft then
		return nil
	end
	return math.max(0, specialLeft - (os.clock() - specialAt))
end

-- The label is the shown name, shouted ("ULTIMATE"), so match on the shown half of
-- RARITY rather than the attribute -- Ultimate is OG, Oblivion is Japan.
local function specialAttr()
	if type(specialLabel) ~= "string" then
		return nil
	end
	local want = specialLabel:upper()
	for _, pair in ipairs(RARITY) do
		if pair[1]:upper() == want then
			return pair[2]
		end
	end
	return nil
end

readSpecial()
local watchers = {} -- every load-time connection, dropped by shutdown
-- Held for teardown. They only write locals, so a leak costs nothing at runtime -- but
-- they outlive the window, and every re-paste arms another pair.
table.insert(watchers, workspace:GetAttributeChangedSignal("NextSpecialLabel"):Connect(readSpecial))
table.insert(watchers, workspace:GetAttributeChangedSignal("NextSpecialLeft"):Connect(readSpecial))

-- The server's mutation and spawn events -- Cursed, Gold, Rainbow, Volcanic, Taco,
-- Alien, US -- each publish their own end time as a workspace attribute called
-- event_<Name>. The game's own Hud.Events rows read exactly these.
--
-- Found by PREFIX rather than from a list of the eight in this dump: an event added
-- later then shows up here with no edit, and one that ends just stops matching. Unlike
-- NextSpecialLeft these are absolute deadlines, so they're compared against
-- GetServerTimeNow the same way a block's despawn timer is -- no local countdown needed.
local function events()
	local out = {}
	local now = workspace:GetServerTimeNow()
	for key, value in pairs(workspace:GetAttributes()) do
		local name = key:match("^event_(.+)$")
		local deadline = name and tonumber(value)
		if deadline and deadline - now > 0 then
			table.insert(out, { name = name, left = deadline - now })
		end
	end
	-- Soonest first: the one about to end is the one worth knowing about.
	table.sort(out, function(a, b)
		return a.left < b.left
	end)
	return out
end

-- NextSpecialLeft is a float; %d truncates it, which is what a countdown wants anyway.
local function clock(secs)
	return string.format("%d:%02d", secs // 60, secs % 60)
end

-- farm -----------------------------------------------------------------------
-- The shell is built below this, so the rows the loop writes to are declared here and
-- filled in there. say() no-ops until then, which is what makes the order legal.
local statusRow, farmToggle
local running = true

local function say(msg)
	if statusRow then
		statusRow:SetDesc(msg)
	end
end

local chosen = {} -- set: attribute -> true, written by the dropdown callback
local farming, taken, misses = false, 0, 0
local sniping = false
local cashing, cashGen = false, 0 -- the cash sweep runs on its own thread, farm or no farm
local baseOverride -- set by SET BASE; nil means "use the plot"

-- Resolved per trip, not once at paste: the plot's owner value is written after you
-- join, so a BASE captured too early is the fallback constant forever.
local function base()
	if baseOverride then
		return baseOverride
	end
	local plot = myPlot()
	local part = plot and plot:FindFirstChild("Base")
	local point = part and part:FindFirstChild("Teleport")
	-- Position only. The plot's Base part is laid on its side (its up axis points along
	-- world +X) and the attachment inherits that, so pivoting to the raw WorldCFrame
	-- drops you sideways and the humanoid slides while righting itself.
	return point and CFrame.new(point.WorldPosition) or CFrame.new(BASE_POS)
end

-- Go home, unless we're already there. The unconditional version pivoted you onto the
-- spot you were already standing on every IDLE seconds, which reads as hopping in place.
local function goBase()
	local root, cf = hrp(), base()
	if root and (root.Position - cf.Position).Magnitude <= AT_BASE then
		return true
	end
	return tp(cf)
end

-- Standing on your own plot is what banks a carried block -- there is no deposit
-- remote, the server watches where you are. So the exit is your hands emptying, and
-- the retry is just going home again: one PivotTo can land you a stud outside whatever
-- volume it watches, and that retry is worth the hop.
local function bank()
	if heldCount() == 0 then
		return true
	end
	goBase()
	task.wait(BASE_WAIT)
	local deadline = os.clock() + BANK_TIMEOUT
	while heldCount() > 0 and os.clock() < deadline do
		tp(base())
		task.wait(BANK_STEP)
	end
	return heldCount() == 0
end

-- Ticked rarities, best first. WindUI hands the callback its selections in CLICK order,
-- which is not farm order, so rank is re-applied here rather than trusted from there.
local function orderedWanted()
	local out = {}
	for _, pair in ipairs(RARITY) do
		if chosen[pair[2]] then
			table.insert(out, pair[2])
		end
	end
	return out
end

-- The exit is heldBy on THIS block turning into your UserId -- the server writing that
-- attribute is the grab. Not the folder shrinking: a carried block stays in
-- workspace.Live.Slimes, so the folder never tells you anything here. GRAB_TIME is the
-- other exit: a block that won't come (someone beat you to it, carry limit reached)
-- shouldn't stall the whole pass.
local function grab(model)
	local folder = model.Parent
	-- The one real hop, and also what pulls the region in: everything the scan saw of a
	-- far block was its Model, so its RootPart and StealPrompt only exist once you're
	-- standing there.
	tp(model:GetPivot(), GRAB_OFFSET)
	-- Budgeted separately from GRAB_TIME on purpose. A cross-map hop can take a second
	-- or two to replicate, and spending the whole grab window firing at a prompt that
	-- hasn't arrived yet is how a special gets abandoned right after you reach it.
	local ready = os.clock() + STREAM_TIMEOUT
	while not model.PrimaryPart and model.Parent == folder and os.clock() < ready do
		task.wait(0.05)
	end
	if not model.PrimaryPart then
		return false -- streamed out, or taken while we were in the air
	end
	-- Started only now. Set before the hop it would have been half spent on the
	-- teleport and all of it on a cross-map load, and the loop below would get one pass.
	local deadline = os.clock() + GRAB_TIME
	repeat
		-- Only when the block has actually got away from us. It re-aimed every single
		-- step before, which is a PivotTo twenty times a second on a character the
		-- humanoid is still trying to settle -- the stutter you could see. Blocks fall
		-- in at fallSpeed 25, so following one down is now a nudge every few steps.
		local root, pivot = hrp(), model:GetPivot()
		-- Measured against where the jump WOULD put you, not against the block itself:
		-- GRAB_OFFSET is 4 studs up, so measuring to the pivot would start every grab
		-- already 4 studs "off" and re-aim almost as often as before.
		if not root or (root.Position - targetOf(pivot, GRAB_OFFSET).Position).Magnitude > REAIM then
			reaim(pivot, GRAB_OFFSET)
		end
		local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
		if prompt then
			fire(prompt)
		else
			touch(model.PrimaryPart)
		end
		task.wait(FIRE_STEP)
	until heldBy(model) or model.Parent ~= folder or os.clock() > deadline
	return heldBy(model) == player.UserId
end

-- A bank that doesn't land is one of two things and the bag count tells them apart: a
-- full backpack, or a BASE that isn't actually on your plot. One miss is noise (you
-- died on the way, the plot hadn't replicated); FULL_MISSES in a row is the real thing,
-- and touring a map that will refuse every grab is worse than stopping. Returns true
-- when the caller should give up.
local function bankFailed()
	misses += 1
	if misses < FULL_MISSES then
		return false
	end
	local n = banked()
	say(
		n and n >= BAG_LIMIT and string.format("bag full (%d/%d) -- open or place some first", n, BAG_LIMIT)
			or "can't bank -- is BASE actually on your plot?"
	)
	return true
end

-- Returns true to ask the caller to stop. It must not write `farming` itself: a pass
-- that outlives its own generation would switch off a farm that has since restarted.
local function runPass(want)
	-- Dead, or between characters. tp() would quietly no-op and every hold below would
	-- be refused on range, so a death would otherwise burn passes until the respawn.
	if not hrp() then
		say("no character -- waiting for respawn")
		repeat
			task.wait(0.2)
		until hrp() or not (farming and running)
		if not hrp() then
			return
		end
	end

	-- A ticked special about to land trims the wanted set to itself and anything above
	-- it. At carry limit 1 the failure mode is arriving with full hands, so the point
	-- of the hold is empty ones -- which is what the bank below leaves you with.
	local hold, holdIn
	if sniping then
		local attr, left = specialAttr(), specialIn()
		if attr and want[attr] and left and left <= SNIPE_LEAD then
			hold, holdIn = attr, left
			local floor = RANK[attr]
			for rarity in pairs(want) do
				if (RANK[rarity] or 0) < floor then
					want[rarity] = nil
				end
			end
		end
	end

	-- Still holding something from a hand-grab or an interrupted run: nothing else is
	-- grabbable until it's banked, and every attempt would just be another refusal.
	if heldCount() > 0 then
		say("hands full -- banking first")
		if not bank() then
			return bankFailed() -- false reads as "keep going" to the caller
		end
		misses = 0
	end

	local targets = scanBlocks(want)
	if #targets == 0 then
		-- Park at base rather than wherever the last trip ended: it's where the next
		-- bank goes anyway, and it's the one spot that's yours. goBase, not tp -- once
		-- you're there this does nothing at all, which is the point of idling.
		goBase()
		if hold then
			say(string.format("holding for %s -- %s (%d banked)", SHOWN[hold], clock(holdIn), taken))
		else
			say(string.format("nothing ticked is out -- idling at base (%d banked)", taken))
		end
		task.wait(IDLE)
		return
	end

	local t = targets[1]
	say(
		string.format(
			"%s [%s]%s -- %d ticked out there",
			t.model.Name,
			SHOWN[t.rarity] or t.rarity,
			t.streamed and "" or ", streaming in",
			#targets
		)
	)
	if grab(t.model) then
		if bank() then
			misses = 0
			taken += 1
			local n = banked()
			say(
				string.format(
					"banked %s (%d this run%s)",
					SHOWN[t.rarity] or t.rarity,
					taken,
					n and string.format(", bag %d/%d", n, BAG_LIMIT) or ""
				)
			)
		elseif bankFailed() then
			return true
		end
	end
end

local farmGen = 0

local function startFarm()
	farming, misses = true, 0 -- a fresh switch-on is you saying your hands are free
	farmGen += 1
	local mine = farmGen -- off-then-on shouldn't leave two loops driving one character
	task.spawn(function()
		while farming and running and farmGen == mine do
			-- Re-read the ticks every pass, so untick and retick land without a restart.
			local want, any = {}, false
			for _, rarity in ipairs(orderedWanted()) do
				want[rarity], any = true, true
			end
			if not any then
				say("tick at least one rarity")
				break
			end
			-- A crash in here would kill the thread silently, leaving the toggle stuck
			-- ON with nothing happening. Name it and switch off cleanly instead.
			local ok, res = pcall(runPass, want)
			if not ok then
				warn("[JumpSCP]", res)
				say("crashed -- see console (F9)")
				break
			end
			if res then
				break -- the pass asked to stop; the tail below owns the switch
			end
		end
		-- Only the current generation owns the switch; an old thread finishing must not
		-- flip off a farm that has already been restarted.
		if farmGen == mine then
			farming = false
			if farmToggle then
				farmToggle:Set(false)
			end
		end
	end)
end

-- shell ----------------------------------------------------------------------
-- ponytail: no hand-rolled widget kit. Topbar, icon, bubble, live game name and the
-- shade live in panel.lua, so a restyle is one file and not eighteen. Fetched here
-- rather than installed by the loader, so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Jump for SCP", -- fallback until the live name lands
	folder = "JumpSCP", -- renaming it later orphans configs already saved in-game
	size = UDim2.fromOffset(500, 490),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })

-- Box + BoxBorder are what turn a bare header into a card: WindUI paints the surface
-- and hairline from its own theme tokens, so this tracks the active theme.
local function card(title, desc, icon)
	return Tab:Section({ Title = title, Desc = desc, Icon = icon, Box = true, BoxBorder = true, Opened = true })
end

local farmCard = card("Farm", "Pick rarities, then flip the switch", "solar:box-bold")
local snipeCard = card("Timers", "Everything on a clock, and the hold that acts on it", "solar:alarm-bold")
local cashCard = card("Cash", "Sweeps your own plot, wherever you are", "solar:wallet-money-bold")
local baseCard = card("Base", "Where grabbed blocks get banked", "solar:safe-2-bold")
local liveCard = card("Live", "What's in workspace.Live.Slimes right now", "solar:eye-bold")

farmCard:Dropdown({
	Title = "Rarities",
	Desc = "Named the way the game names them, best first",
	Values = ROWS,
	Value = {},
	Multi = true,
	AllowNone = true,
	Callback = function(picked)
		chosen = {}
		for _, row in ipairs(picked) do
			chosen[ATTR[row]] = true
		end
	end,
})

farmToggle = farmCard:Toggle({
	Title = "Auto farm",
	Desc = "Best rarity first, then nearest. Banks, never places",
	Value = false,
	Callback = function(state)
		-- Set() below fires this callback again, so the off branch has to be
		-- re-entrant. Guarding the message on `farming` is what keeps a rejected
		-- switch-on from reporting a stop that never happened.
		if not state then
			if farming then
				say("stopped -- " .. taken .. " banked")
			end
			farming = false -- the loop exits on its own flag; nothing else to tear down
			return
		end
		if #orderedWanted() == 0 then
			farmToggle:Set(false)
			WindUI:Notify({ Title = "Jump for SCP", Content = "Tick at least one rarity first.", Image = "list" })
			return
		end
		startFarm()
	end,
})

statusRow = farmCard:Paragraph({ Title = "Status", Desc = "idle" })

snipeCard:Toggle({
	Title = "Hold for specials",
	Desc = string.format("Inside %ds, stop taking anything ranked lower and wait empty-handed", SNIPE_LEAD),
	Value = false,
	Callback = function(state)
		sniping = state
	end,
})

-- Every clock the server actually publishes, in one place.
--
-- There is only ONE next-special countdown to show: workspace carries NextSpecialLabel
-- and NextSpecialLeft, singular, and that pair is the whole board in the map. The game
-- does not publish a per-rarity schedule, so a row per special would be five copies of
-- one number. What it does publish is the other two families below.
local nextRow = snipeCard:Paragraph({ Title = "Next special", Desc = "reading..." })
local outRow = snipeCard:Paragraph({ Title = "On the map", Desc = "counting..." })
local eventRow = snipeCard:Paragraph({ Title = "Events", Desc = "reading..." })

local cashRow = cashCard:Paragraph({ Title = "Collected", Desc = "off" })
local cashToggle

-- Deliberately independent of AUTO FARM: income accrues whether or not you're out
-- fetching blocks, and the sweep fires remotes rather than walking pads, so it works
-- from the top of the tower just as well as from your plot.
cashToggle = cashCard:Toggle({
	Title = "Auto collect cash",
	Desc = string.format("Every paying stand on your plot, %.2fs apart, then again in %ds", SWEEP_STEP, CASH_POLL),
	Value = false,
	Callback = function(state)
		if not state then
			if cashing then
				cashRow:SetDesc("off") -- guarded so a crash message survives Set(false)
			end
			cashing = false
			return
		end
		cashing = true
		cashGen += 1
		local mine = cashGen -- off-then-on inside one CASH_POLL must not leave two sweepers
		task.spawn(function()
			local alive = function()
				return cashing and running and cashGen == mine
			end
			-- A full plot is ~65s of sweeping at the server's rate, so the row counts up
			-- as it goes. Without it the panel looks frozen for a minute at a time.
			local report = function(done, total)
				cashRow:SetDesc(string.format("sweeping %d/%d", done, total))
			end
			while alive() do
				local ok, n = pcall(collectCash, alive, report)
				if not ok then
					warn("[JumpSCP] cash", n)
					cashing = false
					cashRow:SetDesc("crashed -- see console (F9)")
					cashToggle:Set(false)
					return
				end
				cashRow:SetDesc(n > 0 and (n .. " stands swept") or "no occupied stands -- place some slimes")
				task.wait(CASH_POLL)
			end
		end)
	end,
})

baseCard:Button({
	Title = "Set base",
	Desc = "Only if the plot lookup lands somewhere wrong -- stand there, press this",
	Callback = function()
		local root = hrp()
		if not root then
			say("no character")
			return
		end
		baseOverride = root.CFrame
		say(string.format("base set: %d, %d, %d", root.Position.X, root.Position.Y, root.Position.Z))
	end,
})

baseCard:Button({
	Title = "Go to base",
	Desc = "Plain TP, for getting out of trouble by hand",
	Callback = function()
		say(tp(base()) and "at base" or "no character")
	end,
})

local liveRow = liveCard:Paragraph({ Title = "Blocks", Desc = "counting..." })

-- Its own thread rather than sharing the status line: the farm writes to that one
-- continuously, and a count that only appears between grabs is no count.
task.spawn(function()
	while running do
		if not slimeFolder() then
			liveRow:SetDesc("workspace.Live.Slimes not found")
		else
			local counts, extra = {}, {}
			for _, t in ipairs(scanBlocks(nil)) do
				counts[t.rarity] = (counts[t.rarity] or 0) + 1
				if not RANK[t.rarity] then
					extra[t.rarity] = true
				end
			end
			local parts = {}
			for _, pair in ipairs(RARITY) do -- best first, same as everywhere else
				if counts[pair[2]] then
					table.insert(parts, pair[1] .. " " .. counts[pair[2]])
				end
			end
			-- Anything the RARITY table above doesn't list, named by its raw attribute.
			-- This is the only place a rarity the game added later becomes visible.
			for rarity in pairs(extra) do
				table.insert(parts, rarity .. "? " .. counts[rarity])
			end
			liveRow:SetDesc(#parts > 0 and table.concat(parts, "   ") or "none spawned")
		end
		task.wait(COUNT_EVERY)
	end
end)

-- Ticks once a second on its own: NextSpecialLeft is written in one lump, so a row
-- driven off AttributeChanged alone would sit on a stale number for minutes. All three
-- rows move on that same beat, so one thread writes all three.
task.spawn(function()
	while running do
		local attr, left = specialAttr(), specialIn()
		if not left then
			nextRow:SetDesc("workspace has no NextSpecialLeft -- nothing scheduled")
		elseif not attr then
			-- The label is a rarity RARITY doesn't list. Print it raw rather than
			-- swallowing it: that's the game having shipped a new tier.
			nextRow:SetDesc(string.format("%s   in %s   no row for it", tostring(specialLabel), clock(left)))
		else
			-- What it is, when, and what this panel is going to do about it -- the last
			-- part is the one worth reading, since a countdown you're not set up to act
			-- on looks identical to one you are.
			local parts = { SHOWN[attr] }
			table.insert(parts, left > 0 and ("in " .. clock(left)) or "due now")
			if not chosen[attr] then
				table.insert(parts, "not ticked")
			elseif not sniping then
				table.insert(parts, "snipe off")
			elseif left <= SNIPE_LEAD then
				table.insert(parts, "holding")
			else
				table.insert(parts, string.format("holds at %ds", SNIPE_LEAD))
			end
			nextRow:SetDesc(table.concat(parts, "   "))
		end

		-- Specials already spawned, with the time left before they despawn. Best first,
		-- because scanBlocks sorts. Blocks in someone's hands aren't here -- scanBlocks
		-- skips them, and one you can't reach isn't a countdown you can act on.
		--
		-- A trailing * means the block's parts haven't streamed to you yet, which is
		-- normal for anything more than a zone or two up. It's still a real target;
		-- the grab hops there and waits for it to arrive.
		local out = {}
		for _, t in ipairs(scanBlocks(nil)) do
			if (RANK[t.rarity] or -1) >= SPECIAL_RANK then
				local gone = despawnIn(t.model)
				table.insert(
					out,
					(SHOWN[t.rarity] or t.rarity) .. (gone and " " .. clock(gone) or "") .. (t.streamed and "" or "*")
				)
			end
		end
		outRow:SetDesc(#out > 0 and table.concat(out, "   ") or "no specials out")

		local live = {}
		for _, e in ipairs(events()) do
			table.insert(live, e.name .. " " .. clock(e.left))
		end
		eventRow:SetDesc(#live > 0 and table.concat(live, "   ") or "none running")

		task.wait(1)
	end
end)

-- close ----------------------------------------------------------------------
-- The red topbar button destroys the window after WindUI's own confirm dialog, so
-- teardown hangs off OnDestroy and both exits share it. ponytail: rerun to come back.
local function shutdown()
	running, farming, cashing = false, false, false
	for _, c in ipairs(watchers) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(watchers)
end

Window:OnDestroy(function()
	shutdown()
	if getgenv then
		getgenv().jumpSCPStop = nil -- both exits clear the slot, or the next paste calls
	end -- a stop closure whose Window is already destroyed
end)

if getgenv then
	getgenv().jumpSCPStop = function()
		shutdown()
		pcall(function()
			Window:Destroy()
		end)
		getgenv().jumpSCPStop = nil
	end
end
