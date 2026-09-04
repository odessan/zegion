--[[ Soccer Jump -- tick the Lucky Block tiers you want, it goes and fetches them

     TIER      : multi-select dropdown over the Lucky Block rarities. Ticking only
                 ticks; AUTO FARM is what acts on it, and it re-reads the ticks every
                 pass, so retick mid-farm lands without a restart.
     AUTO FARM : toggle. Rescans every pass, works the ticked tiers BEST FIRST, and for
                 each block:

                     TP onto the block -> hold its prompt -> TP to BASE

     BASE      : where a grabbed block gets carried. Captured from wherever you were
                 standing when you pasted this. SET BASE re-captures it from where you
                 are now; GO TO BASE is a plain TP for getting out of trouble by hand.
     LIVE      : a card that recounts what's in workspace.Live.Slimes every COUNT_EVERY
                 seconds, so you can see a tier spawn before you tick it.

     Blocks FALL in -- every one carries fallHeight / fallSpeed / Levitate / groundY
     attributes -- so the grab loop re-TPs onto the block's LIVE pivot every FIRE_STEP
     instead of aiming once at where it was. Following it down is also what makes a
     levitating block grabbable without timing anything.

     Tier comes off the SlimeId attribute (1112 = Icons, 1023 = OG ...), matched against
     the table below. A Lucky Block whose id isn't in that table still gets farmed --
     it lands in the "?" row, and it's ranked ABOVE Japan, because an id this script has
     never heard of is a tier the game shipped after this was written.

     Executor only: the UI is WindUI, pulled in with HttpGet, which Studio blocks.
     The minus button rolls the panel up to a bare Zegion pill -- click it to come back.
     RightControl does the same from the keyboard, and RightAlt hides the window
     outright. Farming keeps running under either.
     Stop for good: getgenv().soccerJumpStop() ]]

-- config ---------------------------------------------------------------------
local GRAB_OFFSET = Vector3.new(0, 4, 0) -- above the block's pivot; must land in prompt range
local GRAB_TIME = 0.5 -- seconds to keep hammering one block before giving up on it
local FIRE_STEP = 0.05 -- between prompt fires; also how tightly we track a falling block
local BASE_WAIT = 0.6 -- at base after a grab, so the server sees the drop before we leave
local IDLE = 3 -- parked after a pass that found nothing, rather than rescanning flat out
local COUNT_EVERY = 2 -- seconds between LIVE recounts
local STREAM_TIMEOUT = 3 -- max wait for a region to stream before jumping in anyway
local KEY_TOGGLE = Enum.KeyCode.RightControl

-- Best first. This is display order, farm order and rank all at once -- one array, so
-- there is no second ordering to keep in sync with this one.
--
-- Ranges come from SoccerPlayerRegistry.RARITY_MPS: Slime God (95k-312k) really does sit
-- above Secret (29k-92k), and LIMITED/Exclusive share a range, so their relative order
-- is a coin flip -- swap them if you care. Divine is in RARITY_MPS but has no Lucky
-- Block of its own, so it isn't here.
local TIER_ORDER = {
	"?",
	"Japan",
	"Icons",
	"Spain",
	"Champions",
	"OG",
	"LIMITED",
	"Exclusive",
	"Slime God",
	"Secret",
	"Mythic",
	"Legendary",
	"Epic",
	"Rare",
	"Common",
}

-- SlimeId -> tier, verbatim from SoccerPlayerRegistry.LUCKY_BLOCKS. Only the rarity is
-- copied: the display name is already on the model, so a second copy of it here would
-- be a second thing to get wrong.
--
-- ponytail: a flat table beats requiring the game's module for this -- it's a constant,
-- and the "?" fallback already covers ids added later. Swap to
-- `require(ReplicatedStorage.SharedModules.SoccerPlayerRegistry).LUCKY_BLOCKS` if the
-- game ever starts shipping tiers faster than this list can be edited.
local ID_TIER = {
	["1001"] = "Common", -- Common
	["1015"] = "Common", -- Water / Waves
	["1002"] = "Rare", -- Rare
	["1016"] = "Rare", -- Volcanic
	["1003"] = "Epic", -- Epic
	["1004"] = "Epic", -- Ghost
	["1005"] = "Legendary", -- Legendary
	["1019"] = "Legendary", -- 67
	["1007"] = "Mythic", -- Mythic
	["1202"] = "Mythic", -- Poison
	["1009"] = "Secret", -- Secret
	["1203"] = "Secret", -- Cosmic / Planet
	["1010"] = "Slime God", -- Slime God / Soccer God
	["1011"] = "Slime God", -- Rainbow
	["1101"] = "Exclusive", -- Exclusive
	["1008"] = "Exclusive", -- US (disabled server-side, listed for completeness)
	["1102"] = "LIMITED", -- Limited
	["1023"] = "OG", -- OG
	["1103"] = "Champions", -- Champions
	["1111"] = "Spain", -- Spain
	["1112"] = "Icons", -- Icons
	["1113"] = "Japan", -- Japan
}

local Players = game:GetService("Players")
local player = Players.LocalPlayer

if getgenv and getgenv().soccerJumpStop then
	getgenv().soccerJumpStop() -- re-running must not stack a second window/loop
end

local TIER_RANK = {}
for i, tier in ipairs(TIER_ORDER) do
	TIER_RANK[tier] = #TIER_ORDER - i
end
assert(TIER_RANK["Japan"] > TIER_RANK["Common"], "TIER_ORDER must run best first")
assert(TIER_RANK["?"] > TIER_RANK["Japan"], "unknown ids outrank every known tier")

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
	local id = model:GetAttribute("SlimeId")
	local tier = id and ID_TIER[tostring(id)]
	if tier then
		return tier
	end
	-- The folder holds soccer players as well as blocks, and they carry a SlimeId too --
	-- theirs just isn't a Lucky Block id. The name is what separates the two, and it's
	-- also how an unrecognised block still gets picked up instead of silently ignored.
	return model.Name:find("Lucky Block") and "?" or nil
end

-- want = set of tier -> true, or nil for "everything" (that's the LIVE counter's call).
local function scanBlocks(want)
	local out = {}
	local folder = slimeFolder()
	if not folder then
		return out
	end
	local root = hrp()
	local from = root and root.Position or Vector3.new()
	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") and model.PrimaryPart then
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
	-- tiebreak: a Japan block across the map still beats a Common one at your feet.
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

-- ponytail: a block with no prompt is presumably picked up on contact. This is the
-- guess, not a spied fact -- if blocks never take, run spy.lua over a manual grab and
-- put the real remote here.
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

local BASE = hrp() and hrp().CFrame -- wherever you were standing; SET BASE re-takes it
local chosen = {} -- set: tier -> true, written by the dropdown callback
local farming, taken = false, 0

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

-- Return values lie about whether the server took the block, so the exit condition is
-- the block LEAVING the folder. GRAB_TIME is the other exit: a block that won't come
-- (someone else's, out of range, quota) shouldn't stall the whole pass.
local function grab(target)
	local model = target.model
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
	until model.Parent ~= folder or os.clock() > deadline
	return model.Parent ~= folder
end

local function runPass(want)
	local targets = scanBlocks(want)
	if #targets == 0 then
		say("nothing ticked is spawned -- idling (" .. taken .. " taken)")
		task.wait(IDLE)
		return
	end
	for i, t in ipairs(targets) do
		if not farming then
			break
		end
		-- Positions are a snapshot from before the trip to base; anything another player
		-- took while we were away is simply gone, and gets skipped.
		if t.model.Parent then
			say(string.format("%d/%d  %s  [%s]", i, #targets, t.model.Name, t.tier))
			if grab(t) then
				taken += 1
				say(string.format("got %s -- carrying to base (%d taken)", t.model.Name, taken))
				tp(BASE)
				task.wait(BASE_WAIT)
			end
		end
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
			local ok, err = pcall(runPass, want)
			if not ok then
				warn("[SoccerJump]", err)
				say("crashed -- see console (F9)")
				break
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
	game = "Soccer Jump", -- fallback until the live name lands
	folder = "SoccerJump", -- unchanged: renaming it orphans configs already saved in-game
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
local baseCard = card("Base", "Where grabbed blocks get carried", "solar:safe-2-bold")
local liveCard = card("Live", "What's in workspace.Live.Slimes right now", "solar:eye-bold")

farmCard:Dropdown({
	Title = "Tiers",
	Desc = '"?" is any Lucky Block whose SlimeId this script predates -- it farms first',
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
			WindUI:Notify({ Title = "Soccer Jump", Content = "Tick at least one tier first.", Image = "list" })
			return
		end
		if not BASE then
			farmToggle:Set(false)
			WindUI:Notify({ Title = "Soccer Jump", Content = "Stand on your base and hit SET BASE.", Image = "flag" })
			return
		end
		startFarm()
	end,
})

statusRow = farmCard:Paragraph({ Title = "Status", Desc = "idle" })

baseCard:Button({
	Title = "Set base",
	Desc = "Stand where blocks should be dropped, then press this",
	Callback = function()
		local root = hrp()
		if not root then
			say("no character")
			return
		end
		BASE = root.CFrame
		say(string.format("base set: %d, %d, %d", BASE.X, BASE.Y, BASE.Z))
	end,
})

baseCard:Button({
	Title = "Go to base",
	Desc = "Plain TP, for getting out of trouble by hand",
	Callback = function()
		if not BASE then
			say("no base set")
			return
		end
		say(tp(BASE) and "at base" or "no character")
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
	running, farming = false, false
end

Window:OnDestroy(function()
	shutdown()
	if getgenv then
		getgenv().soccerJumpStop = nil -- both exits clear the slot, or the next paste calls
	end -- a stop closure whose Window is already destroyed
end)

if getgenv then
	getgenv().soccerJumpStop = function()
		shutdown()
		pcall(function()
			Window:Destroy()
		end)
		getgenv().soccerJumpStop = nil
	end
end
