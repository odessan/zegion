--[[ Soccer Run -- tick the Lucky Block tiers you want, it goes and fetches them

     TIER      : multi-select dropdown over the Lucky Block rarities. Ticking only
                 ticks; AUTO FARM is what acts on it, and it re-reads the ticks every
                 pass, so retick mid-farm lands without a restart.
     AUTO FARM : toggle. Rescans every pass, works the ticked tiers BEST FIRST, and for
                 each block:

                     TP onto the block -> hold StealPrompt -> TP to BASE -> Drop

                 It stops there: the blocks sit on the ground at your base and PLACING
                 them on stands is yours to do. Dropping is the game's own free red Drop
                 button, not the gamepass one -- and it's what makes this a loop at all,
                 since carry limit starts at 1 and a full load turns every further hold
                 into another "Carry limit reached" toast.

                 A carried block is NOT removed from workspace.Live.Slimes and does NOT
                 become a Tool on your character. The model stays in the folder and gains
                 heldBy = the holder's UserId; that attribute is the grab succeeding, the
                 way to count what you're carrying, and the reason blocks already in
                 someone's hands are skipped when scanning.

                 Dropped blocks keep their despawn timer (spawnTime + 120s, the number on
                 the billboard), so a pile left too long goes back where it came from.

                 The in-game "Teleport to Base" button is a DEVELOPER PRODUCT, charged
                 every press. Nothing here touches it; the trip home is a PivotTo.

     BASE      : where a grabbed block gets carried. Found per trip: your plot in
                 workspace.Plots (owner == your name) and its Base.Teleport attachment,
                 so this needs no setup and works for whoever runs it. BASE_POS
                 (198 3 273) is the fallback if no plot is yours yet. SET BASE overrides
                 both with wherever you're standing; GO TO BASE is a plain TP for
                 getting out of trouble by hand.
     CASH      : collects every stand on YOUR plot that has a slime on it, every
                 CASH_POLL seconds, from wherever you happen to be standing. Touching a
                 CollectPad runs a CLIENT handler that ends in Collect Earnings(padName),
                 so this fires that remote directly -- no walking the pads, and no
                 0.6s-per-pad cooldown. Two gates: the plot must be yours (owner value)
                 and the stand must actually hold a slime, or it's ~90 refused remotes a
                 sweep. Runs whether or not AUTO FARM is on. Nothing here touches
                 AutoCollectPad -- that singular pad is the gamepass upsell.
     LIVE      : a card that recounts what's in workspace.Live.Slimes every COUNT_EVERY
                 seconds, so you can see a tier spawn before you tick it.

     Blocks FALL in -- every one carries fallHeight / fallSpeed / Levitate / groundY
     attributes -- so the grab loop re-TPs onto the block's LIVE pivot every FIRE_STEP
     instead of aiming once at where it was. Following it down is also what makes a
     levitating block grabbable without timing anything.

     Tier comes off the model NAME first ("Player God Lucky Block" -> Player God), and
     off the SlimeId attribute only when the name is a variant that doesn't say its tier
     (Rainbow, Poison, Cosmic, "67" ...). Name first because that's the pair this game
     shows you in the Explorer, and it survives the registry gaining ids. A block that
     matches neither still gets farmed -- it lands in the "?" row, ranked above Champions,
     because a tier this script has never heard of is one the game shipped after it.

     Executor only: the UI is WindUI, pulled in with HttpGet, which Studio blocks.
     The minus button rolls the panel up to a bare Zegion pill -- click it to come back.
     RightControl does the same from the keyboard, and RightAlt hides the window
     outright. Farming keeps running under either.
     Stop for good: getgenv().soccerRunStop() ]]

-- config ---------------------------------------------------------------------
local GRAB_OFFSET = Vector3.new(0, 4, 0) -- above the block's pivot; must land in prompt range
local GRAB_TIME = 0.5 -- seconds to keep hammering one block before giving up on it
local FIRE_STEP = 0.05 -- between prompt fires; also how tightly we track a falling block
local BASE_WAIT = 0.6 -- at base after a grab, so the server sees the drop before we leave
-- Fallback drop point, only used when your plot can't be found in workspace.Plots (you
-- own none, or owner hasn't replicated yet). Normally the plot's own Base.Teleport wins,
-- which is what makes this work for anyone; SET BASE overrides both.
local BASE_POS = Vector3.new(198, 3, 273)
local DROP_STEP = 0.15 -- between Drop Slime presses while emptying your hands at base
local DROP_TIMEOUT = 2 -- give up on the drop after this and let FULL_MISSES catch it
-- Refused grabs in a row, while still carrying, before calling it a full load and
-- stopping. Reached only when dropping isn't working -- normally you leave base empty.
local FULL_MISSES = 2
local CASH_POLL = 5 -- seconds between cash sweeps of your own plot's collect pads
local IDLE = 3 -- parked after a pass that found nothing, rather than rescanning flat out
local COUNT_EVERY = 2 -- seconds between LIVE recounts
local STREAM_TIMEOUT = 3 -- max wait for a region to stream before jumping in anyway
local KEY_TOGGLE = Enum.KeyCode.RightControl

-- Best first. This is display order, farm order and rank all at once -- one array, so
-- there is no second ordering to keep in sync with this one.
--
-- Ordered by SharedModules.SoccerPlayerRegistry.RARITY_MPS in this place: Champions
-- (5M-15M) > OG (1.1M-3.6M) > LIMITED = Exclusive (330k-1.05M, identical ranges, so
-- their relative order is a coin flip) > Slime God (95k-312k) > Secret (29k-92k) > ...
-- Divine is in RARITY_MPS but no Lucky Block rolls it, so it isn't here.
--
-- The registry calls tier 1010 "Slime God" but gives it displayName "Player God", and
-- the displayName is what the model in workspace is named -- so "Player God" is the
-- label here. Its Rainbow variant (1011) is the same tier under a skin name.
--
-- Shorter than the jump game's list on purpose: Spain, Icons and Japan don't exist in
-- this registry. A tier added later lands in "?" and farms first, so a missing row
-- costs nothing; a dead row would just never count.
local TIER_ORDER = {
	"?",
	"Champions",
	"OG",
	"LIMITED",
	"Exclusive",
	"Player God",
	"Secret",
	"Mythic",
	"Legendary",
	"Epic",
	"Rare",
	"Common",
}

-- SlimeId -> tier, verbatim from SoccerPlayerRegistry.LUCKY_BLOCKS. Comment is the
-- model name, so a block you see in the Explorer maps straight to a row. Only the
-- skin-named ones (Water, Ghost, 67, Rainbow ...) actually need this -- the rest say
-- their tier in the name -- but the whole registry is cheap and checkable at a glance.
--
-- ponytail: a flat table beats requiring the game's module for this -- it's a constant,
-- and the "?" fallback already covers ids added later. Swap to
-- `require(ReplicatedStorage.SharedModules.SoccerPlayerRegistry).LUCKY_BLOCKS` if the
-- game ever starts shipping tiers faster than this list can be edited.
local ID_TIER = {
	["1001"] = "Common", -- Common Lucky Block
	["1015"] = "Common", -- Water Lucky Block
	["1002"] = "Rare", -- Rare Lucky Block
	["1016"] = "Rare", -- Volcanic Lucky Block
	["1003"] = "Epic", -- Epic Lucky Block
	["1004"] = "Epic", -- Ghost Lucky Block
	["1005"] = "Legendary", -- Legendary Lucky Block
	["1019"] = "Legendary", -- 67 Lucky Block
	["1007"] = "Mythic", -- Mythic Lucky Block
	["1202"] = "Mythic", -- Poison Lucky Block (event)
	["1009"] = "Secret", -- Secret Lucky Block
	["1203"] = "Secret", -- Cosmic Lucky Block
	["1010"] = "Player God", -- Player God Lucky Block (registry name: Slime God)
	["1011"] = "Player God", -- Rainbow Lucky Block
	["1101"] = "Exclusive", -- Exclusive Lucky Block
	["1102"] = "LIMITED", -- Limited Lucky Block
	["1023"] = "OG", -- OG Lucky Block
	["1103"] = "Champions", -- Champions Lucky Block
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

if getgenv and getgenv().soccerRunStop then
	getgenv().soccerRunStop() -- re-running must not stack a second window/loop
end

local TIER_RANK = {}
for i, tier in ipairs(TIER_ORDER) do
	TIER_RANK[tier] = #TIER_ORDER - i
end
assert(TIER_RANK["Champions"] > TIER_RANK["Common"], "TIER_ORDER must run best first")
assert(TIER_RANK["?"] > TIER_RANK["Champions"], "unknown ids outrank every known tier")

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

local function tierOf(model)
	local name = model.Name
	-- The folder holds soccer players as well as blocks, and they carry a SlimeId too --
	-- theirs just isn't a Lucky Block id. The name is what separates the two.
	if not name:find("Lucky Block") then
		return nil
	end
	-- Most blocks say their own tier ("Player God Lucky Block"). Variants don't --
	-- Rainbow, Poison, Cosmic, "67" are named for the skin -- so those fall through to
	-- the registry ids, and a block in neither lands in "?" and gets farmed first.
	local named = name:match("^(.*) Lucky Block$")
	if named and TIER_RANK[named] then
		return named
	end
	return ID_TIER[tostring(model:GetAttribute("SlimeId"))] or "?"
end

-- want = set of tier -> true, or nil for "everything" (that's the LIVE counter's call).
-- Carrying is an attribute on the BLOCK, not a Tool on you: the model stays in
-- workspace.Live.Slimes and gets heldBy = the holder's UserId (SlimesTimer reads exactly
-- this to fly the stack behind whoever grabbed it). Nothing appears in your character --
-- that's the slime-off-a-stand mechanic, a different one, and why counting Tools found
-- nothing while the server was answering every hold with "Carry limit reached".
local function heldBy(model)
	local id = model:GetAttribute("heldBy")
	return typeof(id) == "number" and id or nil
end

local function scanBlocks(want)
	local out = {}
	local folder = slimeFolder()
	if not folder then
		return out
	end
	local root = hrp()
	local from = root and root.Position or Vector3.new()
	for _, model in ipairs(folder:GetChildren()) do
		-- Skip anything already in someone's hands, yours included: it's not grabbable,
		-- and your own carried block flies with you, so it would otherwise be the
		-- nearest target on every single pass.
		if model:IsA("Model") and model.PrimaryPart and not heldBy(model) then
			local tier = tierOf(model)
			if tier and (not want or want[tier]) then
				table.insert(out, {
					model = model,
					tier = tier,
					rank = TIER_RANK[tier] or 0,
					dist = (model:GetPivot().Position - from).Magnitude,
				})
			end
		end
	end
	-- Tier first, then whatever is closest inside that tier. Distance is only a
	-- tiebreak: a Champions block across the map still beats a Common one at your feet.
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
--
-- "Gameplay Paused" is the streaming pause: you landed somewhere the client hasn't
-- received yet. Requesting the region first leaves nothing to pause for.
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

-- Every wild block ships a RootPart.StealPrompt, so touch() is only the fallback for one
-- that somehow doesn't. Left in because it costs two lines and a missing prompt would
-- otherwise stall the pass silently.
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

-- The free red Drop button, which is what makes a loop possible at carry limit 1: it
-- leaves the block on the ground where you're standing, so a run piles them up at your
-- base for you to place by hand. Fired until your hands are actually empty, since one
-- press may only drop one of a stack.
--
-- Blocks keep their despawn timer while they sit there (spawnTime + 120s, the countdown
-- on the billboard), so a pile left too long goes back to where it was found.
local dropSlime, collectEarnings
do
	local shared = ReplicatedStorage:WaitForChild("SharedModules", 10)
	local network = shared and shared:WaitForChild("Network", 10)
	local remotes = network and network:WaitForChild("Remotes", 10)
	dropSlime = remotes and remotes:FindFirstChild("Drop Slime")
	collectEarnings = remotes and remotes:FindFirstChild("Collect Earnings")
	if not dropSlime then
		warn("[SoccerRun] no Drop Slime remote -- blocks will pile up in your hands")
	end
	if not collectEarnings then
		warn("[SoccerRun] no Collect Earnings remote -- cash sweep will do nothing")
	end
end

local function drop()
	if not dropSlime or heldCount() == 0 then
		return heldCount() == 0
	end
	local deadline = os.clock() + DROP_TIMEOUT
	repeat
		dropSlime:FireServer()
		task.wait(DROP_STEP)
	until heldCount() == 0 or os.clock() > deadline
	return heldCount() == 0
end

-- Your plot is the one in workspace.Plots whose owner StringValue is your name -- the
-- same scan the game's own GetMyPlot does. Re-found rather than cached: owner is written
-- after you join, and plots get reassigned as players leave.
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

-- cash -----------------------------------------------------------------------
-- Each CollectPads child is named for the stand it serves, and touching its Top runs a
-- CLIENT handler that ends in Collect Earnings:Fire(padName) -- so we fire that directly
-- and skip both the touch and the handler's 0.6s per-pad cooldown. (MyPlot.AutoCollectPad,
-- singular, is the gamepass upsell pad and is a different thing entirely; untouched.)
--
-- Two gates, both required. Your plot only, found by owner value -- firing at someone
-- else's pads is at best refused. And only pads with a slime standing on them, which is
-- Live.PlayerSlimes[you][padName]: an empty stand has no earnings to pay out, so the
-- rest of a 90-pad plot is 90 refused remotes every sweep.
local function collectCash()
	local plot = myPlot()
	local pads = plot and plot:FindFirstChild("CollectPads")
	if not (pads and collectEarnings) then
		return 0
	end
	local live = workspace:FindFirstChild("Live")
	local slimes = live and live:FindFirstChild("PlayerSlimes")
	local mine = slimes and slimes:FindFirstChild(player.Name)
	if not mine then
		return 0
	end
	local n = 0
	for _, pad in ipairs(pads:GetChildren()) do
		if mine:FindFirstChild(pad.Name) then
			collectEarnings:FireServer(pad.Name)
			n += 1
		end
	end
	return n
end

-- farm -----------------------------------------------------------------------
-- The shell is built below this, so the two rows the loop writes to are declared here
-- and filled in there. say() no-ops until then, which is what makes the order legal.
local statusRow, farmToggle
local running = true

local function say(msg)
	if statusRow then
		statusRow:SetDesc(msg)
	end
end

local chosen = {} -- set: tier -> true, written by the dropdown callback
local farming, taken, misses = false, 0, 0
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
	-- Position only. Every plot's Base part is rotated 90 degrees about X, and the
	-- attachment inherits it, so pivoting to the raw WorldCFrame lays you on your side
	-- and the humanoid slides while righting itself -- same reason tp() drops rotation
	-- when it's given an offset.
	return point and CFrame.new(point.WorldPosition) or CFrame.new(BASE_POS)
end

-- Ticked tiers, best first. WindUI hands the callback its selections in CLICK order,
-- which is not farm order, so rank is re-applied here rather than trusted from there.
local function orderedTiers()
	local out = {}
	for _, tier in ipairs(TIER_ORDER) do
		if chosen[tier] then
			table.insert(out, tier)
		end
	end
	return out
end

-- The exit is heldBy on THIS block turning into your UserId -- the server writing that
-- attribute is the grab. Not the folder shrinking: a carried block stays in
-- workspace.Live.Slimes, so the folder never tells you anything here. GRAB_TIME is the
-- other exit: a block that won't come (someone beat you to it, carry limit reached)
-- shouldn't stall the whole pass, and every extra hold on a full load is one more
-- "Carry limit reached" toast on your screen.
local function grab(model)
	local folder = model.Parent
	local deadline = os.clock() + GRAB_TIME
	repeat
		tp(model:GetPivot(), GRAB_OFFSET) -- re-aimed every step: these things fall in
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
	-- Still holding something from a hand-grab or an interrupted run: nothing else is
	-- grabbable until it's down, and every attempt would just be another refusal toast.
	if heldCount() > 0 then
		say("hands full -- dropping at base first")
		tp(base())
		task.wait(BASE_WAIT)
		drop()
	end
	-- ONE block per pass, best-ranked first, and the caller loops us. Working a whole
	-- sorted snapshot would be fewer scans, but the rare tiers are exactly the ones you
	-- can't make wait: OG and Champions spawn seldom and despawn 120s after spawnTime,
	-- so an OG that appears while you're four Commons deep into a snapshot is gone
	-- before that list runs out. Rescanning per block costs one folder walk.
	local targets = scanBlocks(want)
	if #targets == 0 then
		say("nothing ticked is spawned -- idling (" .. taken .. " taken)")
		task.wait(IDLE)
		return
	end

	local t = targets[1]
	say(string.format("%s [%s] -- %d ticked out there", t.model.Name, t.tier, #targets))
	if grab(t.model) then
		misses = 0
		taken += 1
		tp(base())
		task.wait(BASE_WAIT) -- so the server sees you home before you let go
		drop()
		say(string.format("dropped %s at base (%d taken)", t.model.Name, taken))
	elseif heldCount() > 0 then
		-- Hands still full after a trip home means the drop isn't landing, and every
		-- further hold just earns another "Carry limit reached" toast. Say it and stop
		-- rather than touring a map that will refuse everything.
		misses += 1
		if misses >= FULL_MISSES then
			say(string.format("still carrying %d -- drop them by hand, then flip this back on", heldCount()))
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
			for _, tier in ipairs(orderedTiers()) do
				want[tier], any = true, true
			end
			if not any then
				say("tick at least one tier")
				break
			end
			-- A crash in here would kill the thread silently, leaving the toggle stuck ON
			-- with nothing happening. Name it and switch off cleanly instead.
			local ok, res = pcall(runPass, want)
			if not ok then
				warn("[SoccerRun]", res)
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
-- ponytail: no hand-rolled widget kit. WindUI already ships the multi-select dropdown,
-- toggles, cards, drag, resize and the topbar, which is everything this panel is.
-- Fetched at runtime; nothing to vendor.
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a
-- restyle is one file and not sixteen. Fetched here rather than installed by the loader,
-- so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Soccer Run", -- fallback until the live name lands
	folder = "SoccerRun", -- renaming it later orphans configs already saved in-game
	size = UDim2.fromOffset(480, 400),
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

local farmCard = card("Farm", "Pick tiers, then flip the switch", "solar:box-bold")
local cashCard = card("Cash", "Sweeps your own plot, wherever you are", "solar:wallet-money-bold")
local baseCard = card("Base", "Where grabbed blocks get carried", "solar:safe-2-bold")
local liveCard = card("Live", "What's in workspace.Live.Slimes right now", "solar:eye-bold")

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
	Desc = "Best tier first, then nearest",
	Value = false,
	Callback = function(state)
		-- Set() below fires this callback again, so the off branch has to be re-entrant.
		-- Guarding the message on `farming` is what keeps a rejected switch-on from
		-- reporting a stop that never happened.
		if not state then
			if farming then
				say("stopped -- " .. taken .. " taken")
			end
			farming = false -- the loop exits on its own flag; nothing else to tear down
			return
		end
		if #orderedTiers() == 0 then
			farmToggle:Set(false)
			WindUI:Notify({ Title = "Soccer Run", Content = "Tick at least one tier first.", Image = "list" })
			return
		end
		startFarm()
	end,
})

statusRow = farmCard:Paragraph({ Title = "Status", Desc = "idle" })

local cashRow = cashCard:Paragraph({ Title = "Collected", Desc = "off" })
local cashToggle

-- Deliberately independent of AUTO FARM: income accrues whether or not you're out
-- fetching blocks, and the farm parks you at base anyway.
cashToggle = cashCard:Toggle({
	Title = "Auto collect cash",
	Desc = string.format("Every %ds, every occupied stand on your plot", CASH_POLL),
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
			while cashing and running and cashGen == mine do
				local ok, n = pcall(collectCash)
				if not ok then
					warn("[SoccerRun] cash", n)
					cashing = false
					cashRow:SetDesc("crashed -- see console (F9)")
					cashToggle:Set(false)
					return
				end
				cashRow:SetDesc(n > 0 and (n .. " pads swept") or "no slimes placed yet")
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

-- Its own row and its own thread rather than sharing the status line: the farm writes
-- to that one continuously, and a count that only appears between grabs is no count.
task.spawn(function()
	while running do
		if not slimeFolder() then
			liveRow:SetDesc("workspace.Live.Slimes not found")
		else
			local counts = {}
			for _, t in ipairs(scanBlocks(nil)) do
				counts[t.tier] = (counts[t.tier] or 0) + 1
			end
			local parts = {}
			for _, tier in ipairs(TIER_ORDER) do -- best first, same as everywhere else
				if counts[tier] then
					table.insert(parts, tier .. " " .. counts[tier])
				end
			end
			liveRow:SetDesc(#parts > 0 and table.concat(parts, "   ") or "none spawned")
		end
		task.wait(COUNT_EVERY)
	end
end)

-- close ----------------------------------------------------------------------
-- The red topbar button destroys the window after WindUI's own confirm dialog, so
-- teardown hangs off OnDestroy and both exits share it. ponytail: rerun to come back.
local function shutdown()
	running, farming, cashing = false, false, false
end

Window:OnDestroy(function()
	shutdown()
	if getgenv then
		getgenv().soccerRunStop = nil -- both exits clear the slot, or the next paste calls
	end -- a stop closure whose Window is already destroyed
end)

if getgenv then
	getgenv().soccerRunStop = function()
		shutdown()
		pcall(function()
			Window:Destroy()
		end)
		getgenv().soccerRunStop = nil
	end
end
