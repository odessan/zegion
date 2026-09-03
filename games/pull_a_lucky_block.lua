--[[ Pull a Lucky Block -- tick the tiers you want, it pulls them into your bank (80861715191104)

     TIERS  : multi-select over the Lucky Block rarities. Ticking only ticks; AUTO FARM is
              what acts on it, and it re-reads the ticks every pass, so reticking mid-farm
              lands without a restart. "?" is any block id this script predates -- it farms
              first, because a tier the game shipped after this file is one you want.

     FARM   : per block, hold its RootPart.StealPrompt until a Tool with a friendUID shows
              up on you, then bank it.

              GETTING THERE is the hard part, not the press. Measured in game: the
              StealPrompt's HoldDuration is 0.1 and the hold reports began+triggered every
              time, so the prompt side was never the problem -- but the server RE-CHECKS
              RANGE (a completed hold from 360 studs gets you nothing) and it also UNDOES
              TELEPORTS. Both were invisible for three rounds because the script assumed a
              PivotTo had landed. It doesn't assume any more: tp() confirms arrival and
              reports a revert, and approach() falls back to walking -- which is how this
              game expects a zone to be reached. After a few reverted teleports it stops
              issuing them and just walks.

              During a pull, drifting out of range means the server moved you off the block,
              so the hold is closed, the approach repeated, and the hold reopened. That is a
              re-arm on an observed condition -- not a press on a beat, which is a different
              thing and was its own bug: pressing every 50ms opens a pull and cancels it,
              forever, which from outside looks exactly like the E button being spammed.

              Two openers are tried until one produces a Tool -- a sustained hold, then
              instant fireproximityprompt -- and the winner is named in F9 and used alone
              from then on. Each grab watches the prompt's OWN PromptButtonHoldBegan / Ended
              / Triggered events, so a miss reports whether the hold registered at all, at
              what distance, rather than leaving you to guess. That instrumentation is what
              found the two facts above; leave it in.

              Two ways to reach the block, and the script picks between them by WHAT
              ACTUALLY HAPPENS on the first one:

                REACH  the range gate on a ProximityPrompt is the client's own, so it gets
                       opened (RequiresLineOfSight off, MaxActivationDistance huge) and the
                       prompt is fired from wherever you're standing. Every block in the
                       server is replicated to you -- including the ones four thousand studs
                       out in the other worlds -- so nothing has to stream and nothing has
                       to move. You never leave your plot.
                TP     if the server re-checks range and REACH grabs nothing, the first
                       miss writes REACH off for the session and every later block is
                       PivotTo'd onto and held the ordinary way.

              Which one it settled into is in the status row and in F9.

              BANKING is a four-rung ladder, tried in order until your hands are empty, and
              the rung that works is remembered and put first from then on: the Place to
              Bank remote, then carrying it home to the plot (the mechanic the game
              documents -- cross the safezone and it banks itself), then the bank machine's
              own prompt down in the basement, then Teleport To Spawn last, because that one
              may simply be refused while you're carrying. If every rung fails you are
              either bank-full or the plot lookup found nothing, and F9 says which rungs
              were even available.

     STRENGTH : every block has a strength requirement, and it is decided SERVER-side --
              it appears in no client table, and your Strength is player data the server
              owns, so there is nothing here to fake. "You need more strength to pull this"
              is that check refusing you. What is automatable is earning it: AUTO TRAIN
              fires the game's own Activate Dumbell on the same 0.5s beat the game uses,
              and pauses while you're carrying, because the game refuses to train then.

              The farm LEARNS the requirement instead of guessing it. Every refusal in this
              game arrives as a Send Notification from the server, so a grab that comes back
              "more strength" parks that TIER against the strength you had at the time --
              no more replaying the toast -- and re-opens it by itself the moment training
              beats that number. A refusal is also proof the press reached the server, so it
              can never be mistaken for reach mode failing.

     CASH   : fires Collect Earnings for every occupied stand on your plot on a timer, from
              wherever you are -- touching a CollectPad runs a CLIENT handler that ends in
              that same remote, so this skips the walk and its 0.6s-per-pad cooldown. Two
              gates or it's forty refused remotes a sweep: the stand must hold something,
              and that something must not be a Lucky Block (those earn $0).

     PLACE  : fills EMPTY stands from your bank, best first (rarity order, then $/s -- the
              same sort the game's own Bank UI uses), and fires Open Lucky Block on anything
              it places that is one. Never touches a stand that already earns, and only runs
              while your hands are free, so it can't fight the farm over the Tool.

     Bank has a limit. Once it's full the farm has nowhere to put a block and stops with
     "bank full" -- AUTO PLACE BEST is what drains it, so running both is the working
     configuration.

     WORLDS : workspace.Live.Friends holds EVERY world's blocks at once, and the server
              refuses one from a world you aren't standing in -- that's the "You are not in
              the Atlantian World" toast. No mode gets around it. Those rarities also
              outrank everything, so a single unreachable Sci Fi block would otherwise be
              target #1 on every pass and nothing else would ever be farmed. Blocks more
              than WORLD_RADIUS studs from YOU are skipped for that reason, and the LIVE
              row says how many were set aside. CHASE OTHER WORLDS turns the filter off.

              TRAVEL is the game's own world teleport, so go to a world and its blocks
              become farmable. One catch: if banking ever falls back to the trip home, that
              is Teleport To Spawn -- it pulls you back to the Spawn world and the farm
              will then only see Spawn-world blocks.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().pullBlockStop() ]]

-- config ---------------------------------------------------------------------
-- How long to KEEP HOLDING one block before giving up. Wall-clock on purpose: it is not
-- derived from prompt.HoldDuration, because trusting that number is what turned the pull
-- into a 0.2s tap. It exits the instant a Tool appears, so the full window only elapses on
-- a genuine failure. Also the window the REACH self-test gets.
local PULL_MAX = 12
local POLL_STEP = 0.1 -- how often to check whether the pull has landed. Polling only --
-- nothing presses the prompt again once the hold is open.
local TOOL_WAIT = 0.75 -- extra grace after a block leaves the folder, for the Tool to
-- replicate. Without it a grab that worked reads as a miss and kills REACH mode.
local GRAB_OFFSET = Vector3.new(0, 4, 0) -- TP mode only: above the pivot, inside prompt range
local SETTLE = 0.35 -- after arriving, before the hold starts, so the server sees you standing there
-- How far you may drift from a block before TP mode re-aims. Anything under the prompt's
-- own MaxActivationDistance (10 here) means falling off the block costs nothing -- and NOT
-- re-aiming is the point: a PivotTo cancels a hold in progress, so re-aiming on a beat
-- restarts the pull forever and you just bounce on the block.
local REAIM_AT = 8
local ARRIVED_WITHIN = 15 -- studs from the target that counts as "the teleport stuck"
local SNAP_NOTICE = 3 -- reverted teleports before saying so once in F9
-- Walking is the fallback when teleports are reverted, and it is how this game expects you
-- to reach a zone. WALK_STEP is how long to walk before re-checking; WALK_GIVEUP caps the
-- trip so an unreachable block can't park the farm forever.
local WALK_STEP = 0.5
local WALK_GIVEUP = 30
local MIN_LIFE = 3 -- skip blocks with less than this left on their despawn timer, so the
-- one you pick survives the round trip
local BANK_TIMEOUT = 2 -- wait for Place to Bank to clear your hands before trying the trip home
local TRIP_TIMEOUT = 4 -- wait at your plot for the safezone to take it
local BASE_WAIT = 0.5 -- at base before the safezone is trusted to have seen you

-- Training beat. The game's own Dumbells script debounces itself at 0.5s and refuses to
-- train at all while you're carrying a block, so this matches both -- a tighter beat is
-- just refused presses. One press is your equipped dumbell's Strength times whatever
-- multipliers you own; the script doesn't recompute that, the game already shows it.
local TRAIN_STEP = 0.5
local CASH_POLL = 5 -- seconds between cash sweeps of your own plot
local PLACE_POLL = 4 -- seconds between auto-place passes
local PULL_TIMEOUT = 2 -- wait for Remove from Bank to put a block in your hands
-- workspace.Live.Friends holds EVERY world's blocks at once, and the server refuses a
-- block from a world you aren't standing in ("You are not in the Atlantian World"). Those
-- rarities also outrank everything, so without this one unreachable Sci Fi block would be
-- target #1 on every pass forever and nothing else would ever get farmed. Measured from
-- YOU, not your plot, so it follows you when you change worlds -- your plot doesn't.
-- 2500 clears the whole main map (plots at z 338, the deepest zone around z -810) with
-- room to spare, and the other worlds sit thousands of studs off.
local WORLD_RADIUS = 2500
local IDLE = 3 -- parked after a pass that found nothing, rather than rescanning flat out
local COUNT_EVERY = 2 -- seconds between LIVE recounts
local STREAM_TIMEOUT = 3 -- max wait for a region to stream before jumping in anyway
local KEY_TOGGLE = Enum.KeyCode.RightControl

-- Best first, and derived from the game's own RarityOrders below rather than typed out --
-- a rarity added by an update joins the list in the right place with no edit here.
-- Fallback copy, verbatim from SharedModules.Shared.SharedVariables (8 is genuinely
-- missing from the game's table; nothing maps to it).
local RARITY_FALLBACK = {
	Common = 1,
	Rare = 2,
	Epic = 3,
	Legendary = 4,
	Mythic = 5,
	Secret = 6,
	["Brainrot God"] = 7,
	OG = 9,
	Divine = 10,
	Transcendent = 11,
	Celestial = 12,
	Ancient = 13,
	Cosmic = 14,
	Atlantian = 15,
	["Sci Fi"] = 16,
	Exclusive = 17,
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

if getgenv and getgenv().pullBlockStop then
	getgenv().pullBlockStop() -- re-running must not stack a second panel/loop
end

-- world ----------------------------------------------------------------------
local function hrp()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- Re-found every scan rather than cached: the folder is emptied and refilled as blocks
-- spawn and get taken, and a stale reference to a destroyed one throws mid-farm.
local function friendsFolder()
	local live = workspace:FindFirstChild("Live")
	return live and live:FindFirstChild("Friends")
end

-- The one hardcoded path in the file, and it's the game's own Network module: every
-- remote in this place lives in a plain folder under it, named in English with spaces.
-- Nothing here is shaped in a way a scan could find more reliably than the path.
local Remotes = (function()
	local shared = ReplicatedStorage:WaitForChild("SharedModules", 10)
	local network = shared and shared:WaitForChild("Network", 10)
	return network and network:WaitForChild("Remotes", 10)
end)()

local function remote(name, why)
	local r = Remotes and Remotes:FindFirstChild(name)
	if not r then
		warn(("[PullBlock] no %s remote -- %s"):format(name, why))
	end
	return r
end

local placeToBank = remote("Place to Bank", "banking will fall back to the trip home")
local removeFromBank = remote("Remove from Bank", "auto place best will do nothing")
local placeFriend = remote("Place Friend", "auto place best will do nothing")
local openLucky = remote("Open Lucky Block", "placed blocks won't be opened")
local collectEarnings = remote("Collect Earnings", "cash sweep will do nothing")
local tpToSpawn = remote("Teleport To Spawn", "the trip home falls back to a PivotTo")
local tpToWorld = remote("Teleport To World", "world travel will do nothing")
local activateDumbell = remote("Activate Dumbell", "auto train will do nothing")
local dataGet = Remotes and Remotes:FindFirstChild("Data: Get")
local sendNotify = Remotes and Remotes:FindFirstChild("Send Notification")

-- The item registry. Every block in the world carries an ID attribute and nothing else
-- worth reading -- rarity, name and "is this even a Lucky Block" all come from here.
local DB = (function()
	local shared = ReplicatedStorage:FindFirstChild("SharedModules")
	local db = shared and shared:FindFirstChild("Database")
	local friends = db and db:FindFirstChild("Friends")
	if not friends then
		warn("[PullBlock] no Database.Friends -- falling back to reading tiers off model names")
		return nil
	end
	local ok, mod = pcall(require, friends)
	return ok and mod or nil
end)()

local RARITY_ORDER = (function()
	local shared = ReplicatedStorage:FindFirstChild("SharedModules")
	local sh = shared and shared:FindFirstChild("Shared")
	local vars = sh and sh:FindFirstChild("SharedVariables")
	if vars then
		local ok, mod = pcall(require, vars)
		if ok and type(mod) == "table" and type(mod.RarityOrders) == "table" then
			return mod.RarityOrders
		end
	end
	return RARITY_FALLBACK
end)()

-- Display order, farm order and rank, all one array so there is no second ordering to
-- keep in sync. "?" outranks everything for the reason in the header.
local TIER_ORDER = { "?" }
do
	local tiers = {}
	for name, order in pairs(RARITY_ORDER) do
		table.insert(tiers, { name = name, order = order })
	end
	table.sort(tiers, function(a, b)
		return a.order > b.order
	end)
	for _, t in ipairs(tiers) do
		table.insert(TIER_ORDER, t.name)
	end
end

local TIER_RANK = {}
for i, tier in ipairs(TIER_ORDER) do
	TIER_RANK[tier] = #TIER_ORDER - i
end
assert(TIER_RANK["?"] > (TIER_RANK["Common"] or 0), "unknown ids must outrank every known tier")
assert((TIER_RANK["Mythic"] or 0) > (TIER_RANK["Common"] or 0), "TIER_ORDER must run best first")

-- Your data: bank contents, what's on each stand, base level, rebirths. _Lib is the
-- game's own client cache, so this is free and always current -- but a game LocalScript's
-- _G is not the executor's, hence getrenv. The remote is the fallback and costs a round
-- trip, so nothing calls this on a tight beat.
local gEnv = (getrenv and getrenv()._G) or _G

local function data()
	local lib = gEnv and gEnv._Lib
	if lib and lib.Data then
		local ok, d = pcall(function()
			return lib.Data:Get()
		end)
		if ok and type(d) == "table" then
			return d
		end
	end
	if dataGet then
		local ok, d = pcall(function()
			return dataGet:InvokeServer(player)
		end)
		if ok and type(d) == "table" then
			return d
		end
	end
	return nil
end

-- Every refusal in this game arrives as a Send Notification from the SERVER -- "You need
-- more strength to pull this", "You are not in the Atlantian World". None of those strings
-- exist in any client script, so this remote is the only place the real reason shows up,
-- and hearing it is what turns a miss from a guess into a fact.
local lastRefusal, lastRefusalAt = nil, 0
local notifyConn
if sendNotify then
	notifyConn = sendNotify.OnClientEvent:Connect(function(text)
		if typeof(text) == "string" then
			lastRefusal, lastRefusalAt = text, os.clock()
		end
	end)
end

-- Only a notification that arrived DURING the grab window says anything about that grab.
local function refusalSince(t0)
	if lastRefusal and lastRefusalAt >= t0 then
		return lastRefusal
	end
	return nil
end

-- The game's own abbreviator, so a strength readout matches what's on your screen.
local function shorten(n)
	local lib = gEnv and gEnv._Lib
	local fn = lib and lib.Functions and lib.Functions.Abbreviate
	if fn and fn.Shorten then
		local ok, s = pcall(fn.Shorten, n)
		if ok and s then
			return s
		end
	end
	return tostring(math.floor(tonumber(n) or 0))
end

-- Carrying a block is a Tool with a friendUID attribute -- that uid is what every bank
-- and place remote wants, and its presence is the only honest answer to "did the grab
-- land". Backpack too: a Tool can sit there for a frame after the server hands it over.
local function holdingUID()
	local char = player.Character
	local tool = char and char:FindFirstChildWhichIsA("Tool")
	if not tool then
		tool = player:FindFirstChild("Backpack")
		tool = tool and tool:FindFirstChildWhichIsA("Tool")
	end
	return tool and tool:GetAttribute("friendUID") or nil
end

-- Your plot is the one whose owner StringValue is your name -- the same scan the game's
-- own Get My Plot does. Re-found rather than cached: owner is written after you join, and
-- plots get reassigned as players leave.
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

-- How many teleports the server has undone. Counted rather than assumed: it decides
-- whether this script can jump to blocks or has to walk to them.
local snapBacks = 0

-- "Gameplay Paused" is the streaming pause: you landed somewhere the client hasn't
-- received yet. Requesting the region first leaves nothing to pause for.
-- Returns whether you ACTUALLY ended up there, not whether a PivotTo was issued.
local function tp(cf, offset)
	if not cf then
		return false
	end
	local target = offset and CFrame.new(cf.Position + offset) or cf
	pcall(function()
		player:RequestStreamAroundAsync(target.Position, STREAM_TIMEOUT)
	end)
	local char = player.Character
	if not char or not hrp() then
		return false
	end
	char:PivotTo(target)
	-- Bounded: a client that stays paused would otherwise hang the farm thread outright,
	-- and starting a pull a beat early costs one PULL_MAX window at worst.
	local deadline = os.clock() + STREAM_TIMEOUT
	while player.GameplayPaused and os.clock() < deadline do
		task.wait(0.1)
	end

	-- ARRIVAL IS NOT ASSUMED. A PivotTo that the server undoes leaves you exactly where you
	-- started while every later step behaves as though you're standing on the block -- which
	-- is how this script spent three rounds holding a prompt from 360 studs away and calling
	-- the result a miss. Confirm the move actually stuck, and say so when it doesn't.
	task.wait()
	local root = hrp()
	local off = root and (root.Position - target.Position).Magnitude or math.huge
	if off > ARRIVED_WITHIN then
		snapBacks += 1
		if snapBacks == SNAP_NOTICE then
			warn(
				("[PullBlock] teleports are being reverted (%d studs off after a PivotTo x%d) -- this server resets your position, so blocks have to be walked to")
					:format(math.floor(off), snapBacks)
			)
		end
		return false
	end
	return true
end

-- Every gate on a prompt is enforced by the CLIENT, which is us, so every one can be
-- opened. Range is the whole REACH bet: out of it there is no press to fire at all, and
-- an out-of-range hold is a no-op that reports nothing back.
--
-- GRAB_REACH is finite ON PURPOSE. math.huge here is rejected by the engine, the
-- assignment throws, and since the press is wrapped in a pcall the throw ate every grab
-- silently -- 100% misses in both modes with nothing in the console. Finite, always.
local GRAB_REACH = 500

-- HoldDuration is deliberately NOT touched here. The whole mechanic of this game is
-- SUSTAINING a pull -- that's what the highlight script's five-second camera tween is
-- timing, and what the strength check gates -- so a zeroed hold asks the server for a pull
-- that never happened. One of the presses below zeroes it as an experiment; the gates
-- don't, or every press would be that experiment.
local gatesFailed = false
local function openGates(prompt)
	local ok, err = pcall(function()
		prompt.RequiresLineOfSight = false
		prompt.MaxActivationDistance = math.max(prompt.MaxActivationDistance, GRAB_REACH)
		prompt.Enabled = true
	end)
	if not ok and not gatesFailed then
		gatesFailed = true
		warn("[PullBlock] couldn't open the prompt gates:", err)
	end
	return ok
end

-- THE PULL IS ONE CONTINUOUS HOLD, NOT A PRESS ON A BEAT.
--
-- This is the opposite of every other prompt script in this repo, and copying them is what
-- broke it twice. The 21 scripts that spam fireproximityprompt on a 0.05s beat are farming
-- games where a prompt is an instant pickup. Here the mechanic IS the sustained hold -- the
-- highlight script tweens the camera over five seconds against it, and the strength check
-- gates it -- so pressing repeatedly opens a pull and cancels it 50ms later, forever. That
-- is exactly what "it just spams the E button" looks like from outside: begin, cancel,
-- begin, cancel, with PromptButtonHoldEnded firing twenty times a second, which is the one
-- thing a server would read as "they let go".
--
-- So: begin ONCE, then poll -- never press again -- until the Tool shows up.
--
-- Two ways to open a pull. The hold is tried first because it's the only one that can
-- express "still pulling"; fireproximityprompt is an instant trigger and stays only as the
-- fallback for a server that wants a single trigger after all. Whichever produces a Tool is
-- remembered and used alone from then on.
local HOLDS = {
	{
		name = "sustained hold",
		ok = true,
		-- InputHoldBegin with no matching End until the caller says so. HoldDuration is
		-- deliberately NOT touched: if the server measures held time from its own
		-- PromptButtonHoldBegan, zeroing it locally asks for an impossibly fast pull.
		open = function(prompt)
			prompt:InputHoldBegin()
		end,
		close = function(prompt)
			prompt:InputHoldEnd()
		end,
	},
	{
		name = "fireproximityprompt",
		ok = typeof(fireproximityprompt) == "function",
		open = function(prompt)
			fireproximityprompt(prompt)
		end,
		close = function() end,
		-- An instant trigger either landed or it didn't; waiting the full PULL_MAX on one
		-- would just burn twelve seconds per block proving the same thing.
		window = 3,
	},
}
local holdPick -- index of the opener that has actually produced a Tool
local holdTurn = 0

-- farm -----------------------------------------------------------------------
local function entryFor(model)
	local id = model:GetAttribute("ID")
	return DB and id and DB[tostring(id)] or nil
end

-- Live.Friends holds brainrots as well as blocks, so this doubles as the filter: nil
-- means "not a Lucky Block, leave it alone". An id the registry has never heard of still
-- gets farmed, but only if the model NAME says it's a block -- otherwise an unknown
-- brainrot would land in "?" and get chased first, which is exactly backwards.
local function tierOf(model)
	local entry = entryFor(model)
	if entry then
		if entry.Type ~= "Lucky Block" then
			return nil
		end
		return TIER_RANK[entry.Rarity] and entry.Rarity or "?"
	end
	if not model.Name:find("Lucky Block") then
		return nil
	end
	-- No registry (or an id added after it): most blocks say their own tier in the name.
	local named = model.Name:match("^(.*) Lucky Block$")
	return (named and TIER_RANK[named]) and named or "?"
end

-- The billboard countdown, in seconds. timer is an absolute server clock deadline, so it
-- has to be compared against the same clock the game's own Friends Timer uses.
local function lifeLeft(model)
	local t = model:GetAttribute("timer")
	if not t then
		return math.huge -- no timer means nothing to expire out from under us
	end
	return t - workspace:GetServerTimeNow()
end

-- Set true by the CHASE toggle; blocks outside WORLD_RADIUS are otherwise skipped.
local chaseFar = false

-- want = set of tier -> true, or nil for "everything" (that's the LIVE counter's call).
-- Second return is how many were skipped for being in another world, which is the LIVE
-- row's business: a tier you ticked showing zero here should say WHY.
local function scanBlocks(want)
	local out, far = {}, 0
	local folder = friendsFolder()
	if not folder then
		return out, far
	end
	local root = hrp()
	local from = root and root.Position or Vector3.new()
	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") then
			local tier = tierOf(model)
			if tier and (not want or want[tier]) then
				local rootPart = model:FindFirstChild("RootPart")
				local prompt = rootPart and rootPart:FindFirstChildWhichIsA("ProximityPrompt")
					or model:FindFirstChildWhichIsA("ProximityPrompt", true)
				local dist = (model:GetPivot().Position - from).Magnitude
				-- The pull takes the prompt's whole HoldDuration, so a block has to outlive
				-- that or you spend five seconds on one that despawns in your hands. The
				-- billboard countdown is the number being read here.
				local needs = prompt and math.max(MIN_LIFE, prompt.HoldDuration + 1) or MIN_LIFE
				if prompt and lifeLeft(model) < needs then
					prompt = nil -- too little left on the clock to finish the pull
				end
				if prompt and not chaseFar and dist > WORLD_RADIUS then
					far += 1
				elseif prompt then
					table.insert(out, {
						model = model,
						prompt = prompt,
						tier = tier,
						rank = TIER_RANK[tier] or 0,
						dist = dist,
					})
				end
			end
		end
	end
	-- Tier first, then whatever is closest inside that tier. Distance is only a tiebreak,
	-- and in REACH mode it costs nothing anyway: a Divine block across the map still beats
	-- a Common one at your feet.
	table.sort(out, function(a, b)
		if a.rank ~= b.rank then
			return a.rank > b.rank
		end
		return a.dist < b.dist
	end)
	return out, far
end

-- The two runtime findings, each written exactly once. `proven` guards them: only a miss
-- BEFORE anything has ever worked is evidence about the method -- after that, a miss is
-- just someone beating you to a block.
local reachMode, reachProven = true, false
local baseOverride -- set by SET BASE; nil means "use the plot"

-- Declared here, defined down in the gui section next to the panel rows it mirrors. The
-- farm layer logs long before that section runs, and without this the call sites below
-- would resolve to a GLOBAL logf -- nil at runtime, and a thrown error the moment a
-- deposit rung turned out to be unavailable.
local logf

local function strengthNow()
	local d = data()
	return (d and tonumber(d.Strength)) or 0
end

-- Learned, not read: the strength a block needs is decided server-side and appears in no
-- client table, so the only honest source is the server refusing you. tier -> the strength
-- you HAD when it said no, which is also the number to beat before trying that tier again.
local tooHeavy = {}

local function tooHeavyNow(tier)
	local at = tooHeavy[tier]
	return at ~= nil and strengthNow() <= at
end

local function base()
	if baseOverride then
		return baseOverride
	end
	local plot = myPlot()
	local part = plot and plot:FindFirstChild("Base")
	if part then
		-- Position only, lifted clear: the Base part is laid flat and pivoting to its raw
		-- CFrame puts you on your side while the humanoid rights itself.
		return CFrame.new(part:GetPivot().Position + Vector3.new(0, 5, 0))
	end
	return plot and plot:GetPivot() or nil
end

-- Exits on the Tool appearing -- the server handing you the block is the grab, and no
-- return value says so. The model leaving the folder is the other exit, and it needs the
-- TOOL_WAIT grace after it: the block is gone from the folder a beat before the Tool
-- lands, and calling that a miss is what would wrongly kill REACH mode.
-- Watch the prompt's OWN events for one grab. These fire on the client too, so they answer
-- the question two wrong guesses couldn't: did our synthetic input register as a hold at
-- all, did the engine ever call it complete, and how long did the game think we held. Costs
-- three connections per block and it is the difference between evidence and a third guess.
local function watchPrompt(prompt, seen)
	local conns = {
		prompt.PromptButtonHoldBegan:Connect(function()
			seen.began = os.clock()
		end),
		prompt.PromptButtonHoldEnded:Connect(function()
			seen.ended = os.clock()
		end),
		prompt.Triggered:Connect(function()
			seen.triggered = os.clock()
		end),
	}
	return function()
		for _, c in ipairs(conns) do
			c:Disconnect()
		end
	end
end

-- How far we are from a block right now.
local function distTo(model)
	local root = hrp()
	return root and (root.Position - model:GetPivot().Position).Magnitude or math.huge
end

-- Walk there, because the server put us back. Humanoid:MoveTo only steers toward a point
-- and gives up after ~6s on its own, so it's re-issued on a beat until we're in range or
-- WALK_GIVEUP says the block isn't reachable on foot.
local function walkTo(model)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return false
	end
	local deadline = os.clock() + WALK_GIVEUP
	while distTo(model) > REAIM_AT and os.clock() < deadline do
		if model.Parent == nil then
			return false -- taken or despawned while we were still on our way
		end
		pcall(function()
			hum:MoveTo(model:GetPivot().Position)
		end)
		logf(("walking to %s -- %d studs to go"):format(model.Name, math.floor(distTo(model))))
		task.wait(WALK_STEP)
	end
	return distTo(model) <= REAIM_AT
end

-- Get within range of a block, whichever way this server allows. Teleport first because
-- it's instant; walk when the teleport gets reverted. tp() reports arrival honestly now,
-- so this can tell the two apart instead of assuming the jump worked.
local function approach(model)
	if distTo(model) <= REAIM_AT then
		return true
	end
	-- Once the server has undone enough teleports to be sure about it, stop issuing them:
	-- a PivotTo that gets reverted every time is a wasted round trip per block.
	if snapBacks < SNAP_NOTICE and tp(model:GetPivot(), GRAB_OFFSET) then
		task.wait(SETTLE) -- let the server see you standing there before the hold starts
		if distTo(model) <= REAIM_AT then
			return true
		end
	end
	return walkTo(model)
end

local function grab(t, useTP)
	local model, prompt = t.model, t.prompt
	local folder = model.Parent

	if useTP and not approach(model) then
		t.seen, t.method = {}, "never got there"
		return nil -- couldn't get near it; holding from here is what wasted three rounds
	end
	if not (prompt.Parent and openGates(prompt)) then
		return nil
	end

	local idx = holdPick
	if not idx then
		-- Nothing has worked yet: take the next opener that this executor actually has, so
		-- one grab spends its whole window on ONE method rather than flickering between them.
		for _ = 1, #HOLDS do
			holdTurn = holdTurn % #HOLDS + 1
			if HOLDS[holdTurn].ok then
				idx = holdTurn
				break
			end
		end
	end
	if not idx then
		return nil
	end
	local method = HOLDS[idx]

	local seen = {}
	local unwatch = watchPrompt(prompt, seen)
	local opened = os.clock()
	pcall(method.open, prompt)

	-- Poll, never press. PULL_MAX is wall-clock and deliberately NOT derived from
	-- prompt.HoldDuration -- trusting that number is what produced a 0.2s "hold".
	--
	-- The one thing that DOES re-act mid-window is drifting out of range, because on this
	-- server that means you were moved off the block rather than that you wandered. Re-close
	-- the hold, get back, re-open it. That is a re-arm on an observed condition, not a press
	-- on a beat -- the distinction the earlier E-spam got wrong.
	local deadline = opened + (method.window or PULL_MAX)
	repeat
		task.wait(POLL_STEP)
		if useTP and not holdingUID() and distTo(model) > REAIM_AT and model.Parent == folder then
			pcall(method.close, prompt)
			if approach(model) then
				pcall(method.open, prompt)
			end
		end
	until holdingUID() or model.Parent ~= folder or refusalSince(opened) or os.clock() > deadline

	-- Unconditional: a leaked InputHoldBegin leaves the prompt stuck held and poisons every
	-- later grab, so the close runs on every exit including a thrown error.
	pcall(method.close, prompt)

	if not holdingUID() and model.Parent ~= folder then
		local grace = os.clock() + TOOL_WAIT
		repeat
			task.wait()
		until holdingUID() or os.clock() > grace
	end
	unwatch()

	local uid = holdingUID()
	if uid and not holdPick then
		holdPick = idx -- the opener that actually produced a Tool; the only one used now
		print(("[PullBlock] pull method: %s"):format(method.name))
	end
	t.seen, t.method = seen, method.name -- handed to the miss log, which is the whole point
	return uid
end

-- Place to Bank first: it's a plain remote and costs no movement, which is the whole
-- point of REACH mode. The trip home is the fallback and also the thing the game itself
-- does -- carrying a block into your plot banks it -- so it works even if the remote is
-- position-checked. Teleport To Spawn is the game's own free teleport; the paid
-- "Teleport to Base" button is a developer product and nothing here touches it.
-- Hold any prompt until something in the world says we're done. Same lesson as the pull:
-- open once, then poll -- never press on a beat.
local function holdFor(prompt, seconds, done)
	if not (prompt and prompt.Parent and openGates(prompt)) then
		return false
	end
	pcall(function()
		prompt:InputHoldBegin()
	end)
	local deadline = os.clock() + seconds
	repeat
		task.wait(POLL_STEP)
	until done() or os.clock() > deadline
	pcall(function()
		prompt:InputHoldEnd()
	end)
	return done()
end

-- The bank machine's own Place prompt, down in the basement. This is the deposit the
-- game's Bank UI performs, so it's the one rung guaranteed to be a real deposit path.
local function bankPrompt()
	local plot = myPlot()
	local stuff = plot and plot:FindFirstChild("BasementStuff")
	local machine = stuff and stuff:FindFirstChild("BankMachine")
	local model = machine and machine:FindFirstChild("BankModel")
	local place = model and model:FindFirstChild("Place")
	return place and place:FindFirstChildWhichIsA("ProximityPrompt")
end

-- Four ways to put a block away, tried in order until your hands are empty, and the one
-- that works is remembered for the session. Ordered cheapest-first, but the ORDER matters
-- for a second reason: the old code fired Teleport To Spawn and never walked home, so when
-- the server refused that teleport -- which it may well do while you're carrying, since
-- this game sells a paid Teleport to Base product -- the character simply never moved and
-- the farm stopped with nothing to show. Carrying it home is the mechanic the game actually
-- documents, so it sits above the teleport now, not below it.
local DEPOSITS = {
	{
		name = "Place to Bank remote",
		ready = function()
			return placeToBank ~= nil
		end,
		run = function(uid)
			placeToBank:FireServer(uid)
			return BANK_TIMEOUT
		end,
	},
	{
		name = "carry it home",
		ready = function()
			return base() ~= nil
		end,
		run = function()
			tp(base())
			task.wait(BASE_WAIT)
			-- A few steps on top of the teleport: some servers only credit a safezone you
			-- were seen WALKING into, and a PivotTo alone never moves the humanoid.
			local char = player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			local root = hrp()
			if hum and root then
				hum:MoveTo(root.Position + Vector3.new(0, 0, -6))
			end
			return TRIP_TIMEOUT
		end,
	},
	{
		name = "bank machine prompt",
		ready = function()
			return bankPrompt() ~= nil
		end,
		run = function()
			local prompt = bankPrompt()
			tp(prompt.Parent:GetPivot())
			task.wait(SETTLE)
			holdFor(prompt, TRIP_TIMEOUT, function()
				return holdingUID() == nil
			end)
			return 0.5
		end,
	},
	{
		name = "Teleport To Spawn",
		ready = function()
			return tpToSpawn ~= nil
		end,
		run = function()
			tpToSpawn:FireServer()
			return TRIP_TIMEOUT
		end,
	},
}
local bankPick -- index of the deposit that has actually emptied your hands

local function bank(uid)
	local order = {}
	if bankPick then
		table.insert(order, bankPick) -- the known-good rung first; the rest stay as backup
	end
	for i = 1, #DEPOSITS do
		if i ~= bankPick then
			table.insert(order, i)
		end
	end

	for _, i in ipairs(order) do
		local rung = DEPOSITS[i]
		if rung.ready() then
			local ok, wait = pcall(rung.run, uid)
			local deadline = os.clock() + ((ok and tonumber(wait)) or 1)
			repeat
				task.wait(POLL_STEP)
			until not holdingUID() or os.clock() > deadline
			if not holdingUID() then
				if bankPick ~= i then
					bankPick = i
					print(("[PullBlock] deposit method: %s"):format(rung.name))
				end
				return true
			end
		elseif not bankPick then
			-- Says WHY a rung was skipped, which is the difference between "the plot lookup
			-- failed" and "the remote is missing" -- both of which used to read as silence.
			logf(("deposit rung unavailable: %s"):format(rung.name))
		end
	end
	return false
end

-- cash -----------------------------------------------------------------------
-- Two gates, both required. Your plot only, found by owner value -- firing at someone
-- else's pads is at best refused. And only stands that actually hold an earner: an empty
-- stand has nothing to pay out, and a Lucky Block sitting on one earns $0 by design, so
-- the rest of the plot is that many refused remotes every sweep.
local function collectCash()
	local plot = myPlot()
	local pads = plot and plot:FindFirstChild("CollectPads")
	if not (pads and collectEarnings) then
		return 0
	end
	local d = data()
	local placed = d and d.PlotFriends
	local live = workspace:FindFirstChild("Live")
	local rendered = live and live:FindFirstChild("PlayerFriends")
	rendered = rendered and rendered:FindFirstChild(player.Name)
	if not (placed or rendered) then
		return 0
	end
	local n = 0
	for _, pad in ipairs(pads:GetChildren()) do
		local occupied, isBlock = false, false
		if placed then
			local entry = placed[pad.Name]
			if entry then
				occupied = true
				local info = DB and entry.id and DB[tostring(entry.id)]
				isBlock = info and info.Type == "Lucky Block" or false
			end
		elseif rendered then
			-- No data: the rendered model is the only occupancy signal available, and it
			-- can't tell a block from a brainrot. One refused remote per block beats
			-- skipping the sweep entirely.
			occupied = rendered:FindFirstChild(pad.Name) ~= nil
		end
		if occupied and not isBlock then
			pcall(function()
				collectEarnings:FireServer(pad.Name)
			end)
			n += 1
		end
	end
	return n
end

-- place ----------------------------------------------------------------------
-- Stands past 10 are floor purchases: the game gates stand n>10 on BaseLevel >= n-10, and
-- firing at one you haven't bought is a refused remote and a purchase popup.
local function standUsable(name, baseLevel)
	local n = tonumber(name)
	if not n then
		return false
	end
	return n <= 10 or (n - 10) <= (baseLevel or 0)
end

local placeAnchored = false -- set true after a pull from the bank fails from range

-- Best first: rarity order, then $/s -- the same sort the game's own Bank UI applies to
-- this exact list, so "best" here means what it means in game.
local function bankSorted(d)
	local out = {}
	for _, entry in ipairs(d.Bank and d.Bank.PlacedBrainrots or {}) do
		local info = DB and entry.id and DB[tostring(entry.id)]
		if info then
			table.insert(out, {
				uid = entry.uid,
				name = info.Name,
				isBlock = info.Type == "Lucky Block",
				rank = RARITY_ORDER[info.Rarity] or 0,
				mps = info.MoneyPerSecond or 0,
			})
		end
	end
	table.sort(out, function(a, b)
		if a.rank ~= b.rank then
			return a.rank > b.rank
		end
		return a.mps > b.mps
	end)
	return out
end

-- Returns (placed, why). Empty stands only -- a stand that already earns is left alone.
local function placeBest()
	if holdingUID() then
		return 0, "hands full"
	end
	if not (removeFromBank and placeFriend) then
		return 0, "no place remotes"
	end
	local d = data()
	if not d then
		return 0, "no data"
	end
	local plot = myPlot()
	local stands = plot and plot:FindFirstChild("Stands")
	if not stands then
		return 0, "no plot"
	end

	local empty = {}
	for _, stand in ipairs(stands:GetChildren()) do
		if standUsable(stand.Name, d.BaseLevel) and not (d.PlotFriends or {})[stand.Name] then
			table.insert(empty, stand.Name)
		end
	end
	if #empty == 0 then
		return 0, "no empty stands"
	end
	local items = bankSorted(d)
	if #items == 0 then
		return 0, "bank empty"
	end
	if placeAnchored then
		tp(base()) -- the pull was refused from range once; park on the plot and stay there
		task.wait(BASE_WAIT)
	end

	local n = 0
	for i, stand in ipairs(empty) do
		local item = items[i]
		if not item then
			break
		end
		pcall(function()
			removeFromBank:FireServer(item.uid)
		end)
		local deadline = os.clock() + PULL_TIMEOUT
		repeat
			task.wait(0.05)
		until holdingUID() == item.uid or os.clock() > deadline
		if holdingUID() ~= item.uid then
			if not placeAnchored then
				-- Same finding as REACH, on the other side: the pull may be position
				-- checked. Park on the plot next pass rather than giving up on the feature.
				placeAnchored = true
				warn("[PullBlock] couldn't pull from the bank from here -- parking on your plot for placing")
			end
			return n, "bank pull refused"
		end
		pcall(function()
			placeFriend:FireServer(stand, item.uid)
		end)
		local d2 = os.clock() + PULL_TIMEOUT
		repeat
			task.wait(0.05)
		until not holdingUID() or os.clock() > d2
		if holdingUID() then
			return n, "place refused"
		end
		n += 1
		-- A block on a stand earns nothing and exists only to be opened, so open it.
		if item.isBlock and openLucky then
			task.wait(0.2)
			pcall(function()
				openLucky:FireServer(stand)
			end)
		end
	end
	return n, nil
end

-- gui ------------------------------------------------------------------------
-- ponytail: no hand-rolled widget kit. WindUI already ships the multi-select dropdown,
-- toggles, cards, drag, resize and the topbar, which is everything this panel is.
-- Topbar, icon, bubble, live game name and the shade live in panel.lua, so a restyle is
-- one file. Fetched here rather than installed by the loader, so this file still pastes
-- and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Pull a Lucky Block", -- fallback until the live name lands
	folder = "PullALuckyBlock", -- renaming it later orphans configs already saved in-game
	size = UDim2.fromOffset(500, 400),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })

-- Box + BoxBorder are what turn a bare header into a card: WindUI paints the surface and
-- hairline from its own theme tokens, so this tracks the active theme.
local function card(title, desc, icon)
	return Tab:Section({ Title = title, Desc = desc, Icon = icon, Box = true, BoxBorder = true, Opened = true })
end

local farmCard = card("Farm", "Pick tiers, then flip the switch", "solar:box-bold")
local trainCard = card("Strength", "Train it up -- the pull requirement is server-side", "solar:dumbbell-large-bold")
local plotCard = card("Plot", "Cash and stands, wherever you are", "solar:home-smile-bold")
local travelCard = card("Travel", "The game's own world teleports", "solar:map-point-bold")
local liveCard = card("Live", "What's in workspace.Live.Friends right now", "solar:eye-bold")

local statusRow, farmToggle
local running = true

local function say(msg)
	if statusRow then
		statusRow:SetDesc(msg)
	end
end

-- F9 is where "it does nothing" gets answered, so the status line is mirrored there --
-- throttled, because the farm writes it every pass.
local lastLog = 0
logf = function(msg) -- forward-declared up in the farm section, which logs before this runs
	if os.clock() - lastLog >= 5 then
		lastLog = os.clock()
		print(("[PullBlock] %s"):format(msg))
	end
end

local chosen = {} -- set: tier -> true, written by the dropdown callback
local farming, taken = false, 0
local cashing, cashGen = false, 0
local placing, placeGen = false, 0

-- WindUI hands the callback its selections in CLICK order, which is not farm order, so
-- rank is re-applied here rather than trusted from there.
local function orderedTiers()
	local out = {}
	for _, tier in ipairs(TIER_ORDER) do
		if chosen[tier] then
			table.insert(out, tier)
		end
	end
	return out
end

local function modeLabel()
	return reachMode and "reach" or "TP"
end

-- Returns true to ask the caller to stop. It must not write `farming` itself: a pass that
-- outlives its own generation would switch off a farm that has since restarted.
local function runPass(want)
	if not hrp() then
		say("no character -- waiting for respawn")
		repeat
			task.wait(0.2)
		until hrp() or not (farming and running)
		if not hrp() then
			return
		end
	end
	-- Still carrying from a hand-grab or an interrupted run. Nothing else is grabbable
	-- until it's down, so bank it before anything else.
	local held = holdingUID()
	if held then
		say("hands full -- banking that first")
		if not bank(held) then
			say("bank full -- turn on Auto place best to drain it, then flip this back on")
			return true
		end
	end

	-- ONE block per pass, best-ranked first, and the caller loops us. Working a whole
	-- sorted snapshot would be fewer scans, but the rare tiers are exactly the ones that
	-- can't wait: they spawn seldom and despawn on their own timer, so a Divine that
	-- appears while you're four Commons deep into a stale list is gone before you reach it.
	local targets, far = scanBlocks(want)
	if #targets == 0 then
		if far > 0 then
			say(("%d ticked, but all in other worlds -- idling (%d banked)"):format(far, taken))
			logf(("idle -- %d ticked blocks are in worlds you're not in"):format(far))
			task.wait(IDLE)
			return
		end
		say(("nothing ticked is spawned -- idling (%d banked, %s mode)"):format(taken, modeLabel()))
		logf("idle")
		if not reachMode then
			tp(base()) -- TP mode wanders; park on the plot rather than idling in a zone
		end
		task.wait(IDLE)
		return
	end

	local t = targets[1]
	say(("%s [%s] -- %d ticked out there"):format(t.model.Name, t.tier, #targets))
	local began = os.clock()
	local uid = grab(t, not reachMode)

	-- The server said why. "You need more strength to pull this" is not a miss to retry --
	-- it's a fact about this tier, and hammering it just replays the toast. Park the tier
	-- against the strength you had, and it comes back the moment training beats that.
	local refusal = refusalSince(began)
	-- Any refusal at all is proof the press REACHED the server -- it had to hear you to
	-- turn you down. So a refused grab must never be read as "reach doesn't work" and
	-- must never cost you the no-move mode.
	if refusal and reachMode then
		reachProven = true
	end
	if not uid and refusal and refusal:lower():find("strength") then
		local at = strengthNow()
		tooHeavy[t.tier] = at
		say(("%s needs more strength than %s -- skipping that tier until training beats it"):format(t.tier, shorten(at)))
		print(("[PullBlock] %s refused at %s strength: %s"):format(t.tier, shorten(at), refusal))
		return
	end

	-- The self-test, and the `still in the folder` clause is the whole of its honesty: a
	-- block that VANISHED during the hold was taken by someone else, which says nothing
	-- about whether reach works. Only a block that sat there ignoring you is evidence.
	if not uid and reachMode and not reachProven and t.model.Parent == friendsFolder() then
		-- One miss before anything has ever worked is the answer: this server re-checks
		-- prompt range, so every later block gets TP'd to.
		reachMode = false
		say("reach grab refused -- switching to TP mode for this session")
		print("[PullBlock] reach mode failed on the first block -- the server re-checks prompt range. TP mode from here.")
		uid = grab(t, true)
	end

	if not uid then
		-- A bare "missed" says nothing you can act on. Everything that decides a grab goes
		-- on one line: how far away you were, whether the prompt was even open, and whether
		-- the block was still there to take when the window closed.
		local root = hrp()
		local seen = t.seen or {}
		-- What the PROMPT ITSELF reported, which is the only way to tell a pull the server
		-- refused from one that never started. began+no triggered = we held and the engine
		-- never called it complete; no began at all = the synthetic input isn't registering.
		local heard = seen.began and (seen.triggered and "began+triggered" or "began, never triggered")
			or "no hold events at all"
		logf(
			("missed %s [%s] -- %s mode via %s, %d studs, prompt %s hold=%.1f range=%d, %s, %s"):format(
				t.model.Name,
				t.tier,
				modeLabel(),
				t.method or "?",
				root and (t.model:GetPivot().Position - root.Position).Magnitude or -1,
				t.prompt.Enabled and "on" or "OFF",
				t.prompt.HoldDuration,
				t.prompt.MaxActivationDistance,
				heard,
				t.model.Parent == friendsFolder() and "still there" or "someone else took it"
			)
		)
		return
	end
	if reachMode then
		reachProven = true -- from here a miss is just someone beating you to a block
	end

	if bank(uid) then
		taken += 1
		say(("banked %s [%s] -- %d total, %s mode"):format(t.model.Name, t.tier, taken, modeLabel()))
		logf("banked " .. t.model.Name)
	else
		-- Every deposit path was tried and your hands are still full. Two real causes and
		-- they need different fixes, so say both rather than guessing at one.
		say(("still holding it after every deposit path (%d banked) -- bank full, or no plot found"):format(taken))
		print("[PullBlock] deposit failed on all rungs: remote, carry home, bank machine prompt, Teleport To Spawn. Bank full? Plot owned?")
		return true
	end
end

local farmGen = 0

local function startFarm()
	farming = true
	farmGen += 1
	local mine = farmGen -- off-then-on shouldn't leave two loops driving one character
	task.spawn(function()
		while farming and running and farmGen == mine do
			-- Re-read the ticks every pass, so untick and retick land without a restart.
			local ticked = orderedTiers()
			if #ticked == 0 then
				say("tick at least one tier")
				break
			end
			local want, any = {}, false
			for _, tier in ipairs(ticked) do
				if not tooHeavyNow(tier) then
					want[tier], any = true, true
				end
			end
			-- Everything ticked is currently out of your league. That's a wait, not a stop:
			-- training raises strength and tooHeavyNow re-opens the tier on its own.
			if not any then
				say(("every ticked tier needs more strength than %s -- turn on Auto train"):format(shorten(strengthNow())))
				task.wait(IDLE)
				continue
			end
			-- A crash in here would kill the thread silently, leaving the toggle stuck ON
			-- with nothing happening. Name it and switch off cleanly instead.
			local ok, res = pcall(runPass, want)
			if not ok then
				warn("[PullBlock]", res)
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

farmCard:Dropdown({
	Title = "Tiers",
	Desc = '"?" is any Lucky Block this script predates -- it farms first',
	Values = TIER_ORDER,
	Value = {},
	Multi = true,
	AllowNone = true,
	Callback = function(picked)
		chosen = {}
		for _, tier in ipairs(picked) do
			chosen[tier] = true
		end
	end,
})

farmToggle = farmCard:Toggle({
	Title = "Auto farm",
	Desc = "Best tier first; stands still unless the server makes it move",
	Value = false,
	Callback = function(state)
		-- Set() below fires this callback again, so the off branch has to be re-entrant.
		if not state then
			if farming then
				say(("stopped -- %d banked"):format(taken))
			end
			farming = false -- the loop exits on its own flag; nothing else to tear down
			return
		end
		if #orderedTiers() == 0 then
			farmToggle:Set(false)
			WindUI:Notify({ Title = "Pull a Lucky Block", Content = "Tick at least one tier first.", Image = "list" })
			return
		end
		if not friendsFolder() then
			farmToggle:Set(false)
			WindUI:Notify({ Title = "Pull a Lucky Block", Content = "workspace.Live.Friends not found -- see F9.", Image = "x" })
			warn("[PullBlock] no workspace.Live.Friends -- wrong game, or it hasn't replicated yet")
			return
		end
		startFarm()
	end,
})

farmCard:Toggle({
	Title = "Chase other worlds",
	Desc = "Off = only blocks in the world you're standing in. On = every block, refusals and all",
	Value = false,
	Callback = function(state)
		chaseFar = state
	end,
})

statusRow = farmCard:Paragraph({ Title = "Status", Desc = "idle" })

-- strength -------------------------------------------------------------------
-- What a block needs to be pulled is server-side and in no client table, so there is
-- nothing here to fake -- your Strength is player data the server owns. What CAN be
-- automated is earning it: training is one argument-less remote on a 0.5s beat, which is
-- exactly the loop the game runs when you hold the dumbell yourself.
local trainRow = trainCard:Paragraph({ Title = "Strength", Desc = "off" })
local trainToggle
local training, trainGen = false, 0

trainToggle = trainCard:Toggle({
	Title = "Auto train",
	Desc = ("Fires the game's own Activate Dumbell every %.1fs; pauses while you're carrying"):format(TRAIN_STEP),
	Value = false,
	Callback = function(state)
		trainGen += 1
		if not state then
			if training then
				trainRow:SetDesc("off")
			end
			training = false
			return
		end
		if not activateDumbell then
			trainToggle:Set(false)
			WindUI:Notify({ Title = "Pull a Lucky Block", Content = "No Activate Dumbell remote -- see F9.", Image = "x" })
			return
		end
		training = true
		local mine = trainGen
		task.spawn(function()
			local started, presses = strengthNow(), 0
			while training and running and trainGen == mine do
				-- The game refuses to train while you're carrying, so pressing then is just
				-- a refused remote and a toast. holdingFriend is the server's own flag for it.
				if not (player:GetAttribute("holdingFriend") or holdingUID()) then
					pcall(function()
						activateDumbell:FireServer()
					end)
					presses += 1
				end
				local now = strengthNow()
				-- A self-check, not a feature: if twenty presses move nothing, the remote is
				-- landing nowhere and the usual reason is no dumbell equipped. Say so once
				-- rather than training invisibly forever.
				if presses == 20 and now <= started then
					trainRow:SetDesc("no strength gained in 20 presses -- equip a dumbell?")
					warn("[PullBlock] Activate Dumbell isn't raising Strength -- equip a dumbell and retry")
				else
					trainRow:SetDesc(("%s  (+%s this run)"):format(shorten(now), shorten(now - started)))
				end
				task.wait(TRAIN_STEP)
			end
		end)
	end,
})

local cashRow = plotCard:Paragraph({ Title = "Cash", Desc = "off" })
local cashToggle

-- Deliberately independent of AUTO FARM: income accrues whether or not you're out
-- fetching blocks, and in reach mode you're standing on your plot the whole time anyway.
cashToggle = plotCard:Toggle({
	Title = "Auto collect cash",
	Desc = ("Every %ds, every occupied stand on your plot"):format(CASH_POLL),
	Value = false,
	Callback = function(state)
		cashGen += 1 -- bumped on every call so a stale sleeping loop dies on off too
		if not state then
			if cashing then
				cashRow:SetDesc("off")
			end
			cashing = false
			return
		end
		cashing = true
		local mine = cashGen
		task.spawn(function()
			while cashing and running and cashGen == mine do
				local ok, n = pcall(collectCash)
				if not ok then
					warn("[PullBlock] cash", n)
					cashing = false
					cashRow:SetDesc("crashed -- see console (F9)")
					cashToggle:Set(false)
					return
				end
				cashRow:SetDesc(n > 0 and (n .. " stands swept") or "nothing placed to collect from")
				task.wait(CASH_POLL)
			end
		end)
	end,
})

local placeRow = plotCard:Paragraph({ Title = "Placed", Desc = "off" })
local placeToggle

placeToggle = plotCard:Toggle({
	Title = "Auto place best",
	Desc = "Fills EMPTY stands from the bank, best first, and opens any block it places",
	Value = false,
	Callback = function(state)
		placeGen += 1
		if not state then
			if placing then
				placeRow:SetDesc("off")
			end
			placing = false
			return
		end
		placing = true
		local mine = placeGen
		local total = 0
		task.spawn(function()
			while placing and running and placeGen == mine do
				local ok, n, why = pcall(placeBest)
				if not ok then
					warn("[PullBlock] place", n)
					placing = false
					placeRow:SetDesc("crashed -- see console (F9)")
					placeToggle:Set(false)
					return
				end
				total += (n or 0)
				placeRow:SetDesc(why and ("%d placed -- %s"):format(total, why) or ("%d placed"):format(total))
				task.wait(PLACE_POLL)
			end
		end)
	end,
})

-- Travel is the game's own remotes, so it costs nothing and can't get you stuck: a world
-- you haven't rebirthed enough for is simply refused. In reach mode you don't need this
-- at all -- blocks in every world are already in range -- but in TP mode you have to
-- actually be standing in the world whose blocks you want.
do
	local worlds, names = {}, { "Spawn" }
	local shared = ReplicatedStorage:FindFirstChild("SharedModules")
	local db = shared and shared:FindFirstChild("Database")
	local wmod = db and db:FindFirstChild("Worlds")
	if wmod then
		local ok, mod = pcall(require, wmod)
		if ok and type(mod) == "table" then
			for name, info in pairs(mod) do
				table.insert(worlds, { name = name, index = info.Index or 99 })
			end
			table.sort(worlds, function(a, b)
				return a.index < b.index
			end)
			for _, w in ipairs(worlds) do
				table.insert(names, w.name)
			end
		end
	end

	travelCard:Dropdown({
		Title = "Go to world",
		Desc = "Refused if you're short on rebirths -- that's the game's own check",
		Values = names,
		Value = "Spawn",
		Callback = function(pickedWorld)
			local r = pickedWorld == "Spawn" and tpToSpawn or tpToWorld
			if not r then
				say("no teleport remote -- see F9")
				return
			end
			pcall(function()
				if pickedWorld == "Spawn" then
					r:FireServer()
				else
					r:FireServer(pickedWorld)
				end
			end)
			-- The farm re-measures from wherever you end up, so arriving is all it takes for
			-- that world's blocks to become farmable -- and the Spawn world's to stop being.
			say("sent to " .. pickedWorld .. " -- ticked tiers now mean that world's blocks")
			print(("[PullBlock] teleport to %s fired"):format(pickedWorld))
		end,
	})

	travelCard:Button({
		Title = "Set base",
		Desc = "Only if the plot lookup lands somewhere wrong -- stand there, press this",
		Callback = function()
			local root = hrp()
			if not root then
				say("no character")
				return
			end
			baseOverride = root.CFrame
			say(("base set: %d, %d, %d"):format(root.Position.X, root.Position.Y, root.Position.Z))
		end,
	})
end

local liveRow = liveCard:Paragraph({ Title = "Blocks", Desc = "counting..." })

-- Its own row and its own thread rather than sharing the status line: the farm writes to
-- that one continuously, and a count that only appears between grabs is no count.
task.spawn(function()
	while running do
		if not friendsFolder() then
			liveRow:SetDesc("workspace.Live.Friends not found")
		else
			local counts = {}
			local all, far = scanBlocks(nil)
			for _, t in ipairs(all) do
				counts[t.tier] = (counts[t.tier] or 0) + 1
			end
			local parts = {}
			for _, tier in ipairs(TIER_ORDER) do -- best first, same as everywhere else
				if counts[tier] then
					table.insert(parts, tier .. " " .. counts[tier])
				end
			end
			-- Counting only what's actually farmable would hide the reason a ticked tier
			-- shows nothing, so the other worlds get their own tail rather than silence.
			local line = #parts > 0 and table.concat(parts, "   ") or "none in this world"
			if far > 0 then
				line = line .. ("   (+%d in other worlds)"):format(far)
			end
			liveRow:SetDesc(line)
		end
		task.wait(COUNT_EVERY)
	end
end)

if not fireproximityprompt then
	WindUI:Notify({
		Title = "Pull a Lucky Block",
		Content = "No fireproximityprompt -- grabbing falls back to a real hold, so TP mode only.",
		Image = "x",
	})
end

-- close ----------------------------------------------------------------------
-- The red topbar button destroys the window after WindUI's own confirm; teardown hangs
-- off OnDestroy, and the stop hook shares it. ponytail: rerun to come back.
local function stopAll()
	running, farming, cashing, placing, training = false, false, false, false, false
	-- Orphan any running loop: a sleeping thread wakes, sees its generation is stale, exits.
	farmGen, cashGen, placeGen, trainGen = farmGen + 1, cashGen + 1, placeGen + 1, trainGen + 1
	-- The one real connection in the file, and the one thing a flag can't switch off.
	if notifyConn then
		notifyConn:Disconnect()
		notifyConn = nil
	end
end

Window:OnDestroy(function()
	stopAll()
	if getgenv then
		getgenv().pullBlockStop = nil
	end
end)

if getgenv then
	getgenv().pullBlockStop = function()
		stopAll()
		pcall(function()
			Window:Destroy()
		end)
		getgenv().pullBlockStop = nil
	end
end
