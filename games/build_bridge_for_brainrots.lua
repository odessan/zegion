--[[ Build a Bridge for Brainrots -- fill up on brainrots, carry them home, repeat

     FARM : take brainrots until you're carrying a full load, tp to BASE, go again. The
            load size is the game's own min(Carry, 6), so it fills whatever your carry
            upgrade allows. Standing on BASE is the whole deposit -- nothing here fires
            a place remote, so if arriving doesn't empty you the status line says so
            rather than looping on a full load forever.
     DOOR : anything past your first uncleared door is SKIPPED, because its pickup
            prompt is switched off until you clear the door. That gate is why an
            unfiltered "richest on the map" farm sits still: the richest brainrot is
            almost always behind a door you haven't built to yet.
     RARITY: the only filter. Tick what you want; the richest ticked one that's
            reachable is what gets taken, so rarity narrows the field and income picks
            out of it. Untick everything and the farm idles at BASE.
     BLOCK: Lucky blocks are brainrots that pay after a timer. Ranked by what they'll
            pay, same as anything else. Untick to leave them.
     CASH : the $ piles, on the button only. It teleports round them, so it wants the
            farm off -- one thread drives the character and they'd fight over it.

     Read out of the game's own client scripts rather than guessed at, which is what the
     first two passes got wrong:

       * Carrying is NOT a weld and the model does NOT leave workspace.Brainrots --
         Carriable stays true the whole way home. The player's own CarryCount attribute
         is the counter, so a grab is confirmed when CarryCount goes up. (PickupPrompts)
       * A brainrot past FirstUnclearedDoorZ has its prompt disabled, so firing at it
         does nothing at all, forever. (PickupPrompts)
       * Pin the grab spot BEFORE the loop. Re-reading the pivot each frame flies you
         into the sky: once grabbed, the brainrot rides on you, so pinning to its pivot
         moves you up, which moves it up, which moves you up.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill and back; RightAlt hides it outright.
     Stop: getgenv().bridgeRotsStop() ]]

-- config ---------------------------------------------------------------------
local BASE = Vector3.new(-129, 12, -120) -- where a load is carried to. Grabbed by hand
-- with pivot_tp, which is one constant instead of matching the Owner attribute.
--
-- ponytail: it's YOUR plot's spot, so it's wrong the moment the server hands you a
-- different base -- re-grab it if the farm starts coming home to nowhere.

local TAKE_BLOCKS = true -- include Lucky Blocks in the pick
local CASH_MAX = 20 -- cash piles per press of the button. A cap, not a target: at up to
-- TOUCH_TIMEOUT each this is already ~20s of teleporting, and the rest keep.

local SETTLE = 4 -- ping multiples to wait after a tp. Raise if grabs fire but nothing
-- lands: the pickup's range check runs against where the SERVER thinks you are.
local GRAB_TIMEOUT = 4 -- give up on one brainrot. One you can't win blocks the load.
local BENCH_TIME = 20 -- seconds a brainrot we've already tried is skipped for, whether
-- the grab worked or not. best() is deterministic, so without this the loop re-picks the
-- same winner forever: one we can't have is an infinite stall, and one we CAN have is
-- still the richest thing in the folder while it's riding on our own back.
local HELD_NEAR = 12 -- studs. A brainrot this close to another player's root is on their
-- back. Nothing marks a carried brainrot -- no attribute, no weld, it doesn't leave the
-- folder -- so proximity is the signal. A free one someone happens to stand next to gets
-- skipped, which costs one brainrot; the other way round costs a whole GRAB_TIMEOUT.
local DEPOSIT = 0.5 -- seconds parked on BASE before heading out again. Arriving is the
-- whole deposit, so this is the server's window to notice you're standing there.
local TOUCH_TIMEOUT = 1.5 -- give up on one cash pile. The touch that collects is the
-- physical one, and a probe against the live game needed most of a second for it -- 0.6
-- was cutting piles off before they registered.
local DWELL = 1.5 -- seconds between looks when nothing is takeable

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
local ping = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]

if getgenv and getgenv().bridgeRotsStop then
	getgenv().bridgeRotsStop() -- re-running must not stack a second panel/loop
end

local say = function() end -- replaced by the panel below

local UNITS = { "", "K", "M", "B", "T", "Qa", "Qi" }
local function money(n)
	local i = 1
	while n >= 1000 and i < #UNITS do
		n, i = n / 1000, i + 1
	end
	return ("%.4g%s"):format(n, UNITS[i])
end
assert(money(0) == "0", "no suffix below a thousand")
assert(money(10000000) == "10M", "millions read as M")
assert(money(2.5e18) == "2.5Qi", "the table goes as far as Qi")

-- world ----------------------------------------------------------------------
-- BrainrotsModule is the price list the game renders from: name -> CashPerSecond, with
-- every variant prefix already folded in ("Gold Six Seven" is its own key at 1.5x).
-- Requiring it beats copying 90 rows that go stale on the next brainrot they add.
local INFO = {}
do
	local ok, mod = pcall(function()
		return require(ReplicatedStorage:WaitForChild("BrainrotsModule", 10))
	end)
	if ok and type(mod) == "table" then
		INFO = mod
	else
		warn("[bridgerots] no BrainrotsModule -- ranking by rarity only:", mod)
	end
end

-- The RarityType strings the server writes onto each brainrot, low to high -- the same
-- order the game's own SlotPrompts uses. This list is the dropdown AND the fallback
-- sort, so there's one place to add a tier if they ship one.
local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret", "God", "OG" }

-- Fallback sort only, and deliberately coarse: it can't tell two Secrets apart, which
-- is exactly why INFO is the primary.
local RARITY = {}
for i, name in ipairs(RARITIES) do
	RARITY[name] = i
end

local function hrp()
	local char = player.Character or player.CharacterAdded:Wait()
	return char:WaitForChild("HumanoidRootPart", 10)
end

-- Teleport is instant client-side; the server needs a round trip or two before it
-- agrees you're there, and it agrees with the pickup's range check, not with you.
local function tp(pos)
	local root = hrp()
	if not root then
		return false
	end
	root.CFrame = typeof(pos) == "Vector3" and CFrame.new(pos) or pos
	task.wait((ping:GetValue() * SETTLE) / 1000)
	while player.GameplayPaused do -- streaming pause: nothing around you exists yet
		task.wait(0.1)
	end
	return true
end

-- carry ----------------------------------------------------------------------
-- The three numbers PickupPrompts.updatePrompts runs on. Carry is the upgrade, 6 is the
-- game's own hard cap, CarryCount is how many are on your back right now -- so this is
-- the same "can I still pick up" test the game uses to enable the prompts.
local function capacity()
	return math.min(player:GetAttribute("Carry") or 1, 6)
end

local function carried()
	return player:GetAttribute("CarryCount") or 0
end

local function full()
	return carried() >= capacity()
end

-- The door gate, straight out of updatePrompts: a brainrot deeper than your first
-- uncleared door has its prompt switched off, so firing at it is a guaranteed
-- GRAB_TIMEOUT. DisableDoors is a timed window where they all open regardless.
local function reachable(model)
	if (player:GetAttribute("DisableDoors") or 0) > workspace:GetServerTimeNow() then
		return true
	end
	local limit = player:GetAttribute("FirstUnclearedDoorZ")
	local part = model.PrimaryPart
	if not limit or not part then
		return true -- the game enables the prompt in both of these cases too
	end
	return limit >= part.Position.Z
end

-- farm -----------------------------------------------------------------------
-- WindUI hands a multi-select back as a LIST of names in some builds and as a
-- name -> true MAP in others, and which one you get depends on the library the panel
-- fetched, not on anything here. Reading it as a list when it's a map leaves the set
-- empty, and an empty set takes nothing at all -- which is exactly what it looks like
-- when "the rarity filter doesn't work". Take whichever side of the pair is the string.
local function ticked(values)
	local set = {}
	for k, v in pairs(values) do
		if type(v) == "string" then
			set[v] = true -- list form: 1 -> "Secret"
		elseif v then
			set[k] = true -- map form: "Secret" -> true
		end
	end
	return set
end
assert(ticked({ "Secret", "OG" }).OG, "the list form ticks its names")
assert(ticked({ Secret = true }).Secret, "the map form ticks its keys")
assert(not ticked({ Secret = false }).Secret, "an unticked key in the map form stays off")

-- In tier order rather than hash order, so the status line reads the same way twice.
local function label(set)
	local out = {}
	for _, name in ipairs(RARITIES) do
		if set[name] then
			table.insert(out, name)
		end
	end
	return #out > 0 and table.concat(out, ", ") or "nothing"
end
assert(label({ OG = true, Common = true }) == "Common, OG", "listed low to high")
assert(label({}) == "nothing", "an empty tick set says so rather than reading blank")

local wanted = ticked(RARITIES) -- live: the Rarity dropdown writes this. Everything on
-- by default, so the farm behaves the same until you actually narrow it.
local blocks = TAKE_BLOCKS -- live: the Lucky Blocks toggle writes this
local farming, gen = false, 0

local function entry(model)
	return INFO[model.Name]
end

-- What one brainrot is worth per second. Lucky blocks pay the same way once their timer
-- is up, so they sort in the same list -- the UnlockTime is a delay, not a discount.
local function worth(model)
	local row = entry(model)
	if row and row.CashPerSecond then
		return row.CashPerSecond
	end
	return RARITY[model:GetAttribute("RarityType")] or 0
end

-- Nothing in the game marks a brainrot as carried: no attribute (no client script even
-- reads Carriable), no weld, and it stays in workspace.Brainrots the whole way home. It
-- does move with whoever has it, so that's the check -- and without it the richest
-- brainrot on the server is somebody's backpack and every lap chases it.
local function heldBySomeone(model)
	local part = model.PrimaryPart
	if not part then
		return false
	end
	for _, other in ipairs(Players:GetPlayers()) do
		local char = other ~= player and other.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and (root.Position - part.Position).Magnitude <= HELD_NEAR then
			return true
		end
	end
	return false
end

-- model -> when we're willing to try it again. Weak keys so a despawned brainrot falls
-- out on its own instead of pinning the model forever.
local cooldown = setmetatable({}, { __mode = "k" })

-- TweeningOut is the model on its way out; the game kills its prompt too. Carriable
-- isn't the "someone has this" flag it looks like -- it reads true on one being carried
-- home -- but it costs a comparison and covers an update that starts using it.
local function takeable(model)
	if model:GetAttribute("TweeningOut") or model:GetAttribute("Carriable") == false then
		return false
	end
	local until_ = cooldown[model]
	if until_ and os.clock() < until_ then
		return false
	end
	if heldBySomeone(model) then
		return false
	end
	if not reachable(model) then
		return false
	end
	-- The attribute is the truth, but a variant the server spawned without one still has
	-- a tier in the module ("Gold Six Seven" -> Legendary), and skipping those silently
	-- would look like the dropdown dropping brainrots at random.
	local row = entry(model)
	if not wanted[model:GetAttribute("RarityType") or (row and row.RarityType)] then
		return false
	end
	if not blocks then
		if (row and row.Type == "LuckyBlock") or model.Name:find("Lucky Block") then
			return false -- the name check covers a block the module doesn't list yet
		end
	end
	return true
end

local function best(fold)
	local top, topWorth
	for _, model in ipairs(fold:GetChildren()) do
		if takeable(model) then
			local w = worth(model)
			if not topWorth or w > topWorth then
				top, topWorth = model, w
			end
		end
	end
	return top, topWorth or 0
end

-- CarryCount going up is the server saying yes, and it's the only signal that does:
-- the model stays in workspace.Brainrots with Carriable still true, so watching either
-- of those is what left the last two versions standing on a plank for the full timeout.
local function grab(model)
	local before = carried()
	-- Read ONCE, before the loop. Re-reading the pivot each frame is a rocket: the
	-- instant the grab lands the brainrot rides above your shoulders, so pinning
	-- yourself to its pivot moves you up, which moves it up, which moves you up. That
	-- feedback is what flies the character into the clouds. A carried brainrot is also
	-- still a candidate for the rest of the load, so this fires even on a clean grab.
	local spot = model:GetPivot()
	if not tp(spot) then
		return false
	end

	local deadline = os.clock() + GRAB_TIMEOUT
	repeat
		local root = hrp()
		root.CFrame = spot -- re-pin: without it you drift off the platform and the
		-- range check starts failing halfway through the timeout
		local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
		if prompt then
			pcall(fireproximityprompt, prompt)
		end
		task.wait()
	until carried() > before or os.clock() > deadline or not farming

	-- Benched either way. Failed: someone got it first, it's server-gated, it despawned
	-- mid-reach -- all the same to the loop, and all fixed by moving on. Succeeded: it's
	-- on your back and STILL the richest thing in the folder, so without this the next
	-- pick of the same load is the brainrot you're already carrying.
	cooldown[model] = os.clock() + BENCH_TIME
	return carried() > before
end

-- cash -----------------------------------------------------------------------
-- Each pile's own Touched handler fires CollectCashEvent, so standing on it is the whole
-- interaction. Runs on the farm's thread because a second loop would be teleporting the
-- same character somewhere else at the same time.
-- workspace.Cash is not the game's folder -- ZoneCash.lua does Instance.new("Model") on
-- the CLIENT and clones ReplicatedStorage.CashTemp into it, so every pile is local and
-- the server has never heard of it. That's why firetouchinterest alone did nothing:
-- there's no server-side touch to drive. What actually collects is a plain client
-- connection on part.Touched, which fires CollectCashEvent with the pile's id -- an id
-- kept in a local table we can't read. So let the game's own handler supply it.
--
-- Standing in the pile is what actually collects, confirmed against the live game: a
-- plain teleport in and a wait takes it, no executor touch API involved. Calling the
-- handler directly is kept only because it's one line and takes the pile on the first
-- frame instead of the third. The :Fire and firetouchinterest branches that used to be
-- here are gone -- neither was ever shown to collect anything, and the one that
-- reported success without collecting is what made this look broken.
local function nudge(part, root)
	if not getconnections then
		return
	end
	for _, con in ipairs(getconnections(part.Touched)) do
		if typeof(con.Function) == "function" then
			pcall(con.Function, root) -- the handler wants the part that touched it: it
			-- does Players:GetPlayerFromCharacter(hit.Parent) and bails unless that's us
		end
	end
end

local function sweepCash()
	local fold = workspace:FindFirstChild("Cash")
	if not fold then
		return 0, 0
	end
	local got, missed = 0, 0
	for _, part in ipairs(fold:GetChildren()) do
		if got + missed >= CASH_MAX then
			break
		end
		if part:IsA("BasePart") and part.Parent then
			tp(part.Position) -- the server still range-checks CollectCashEvent
			local deadline = os.clock() + TOUCH_TIMEOUT
			repeat
				nudge(part, hrp())
				task.wait()
			until not part.Parent or part.Parent ~= fold or os.clock() > deadline
			-- The handler Destroys the pile, so a pile still parented is one that did
			-- NOT collect. Counting attempts instead of collections is what let this
			-- report "swept 20" while banking nothing.
			if not part.Parent or part.Parent ~= fold then
				got += 1
			else
				missed += 1
			end
		end
	end
	if missed > 0 then
		warn(("[bridgerots] cash: %d collected, %d left"):format(got, missed))
	end
	return got, missed
end

-- lap ------------------------------------------------------------------------
-- Fill up, then carry it home. One trip per LOAD rather than per brainrot -- with Carry at 6
-- that's a sixth of the teleporting for the same haul, and the game's own cap is what
-- ends the filling half.
local function lap()
	local fold = workspace:FindFirstChild("Brainrots")
	if not fold then
		say("no workspace.Brainrots -- wrong game?")
		return false
	end

	while not full() and farming do
		local target, w = best(fold)
		if not target then
			break -- nothing left we're allowed to take; go bank what we have
		end
		say(("%s ($%s/s) - %d/%d"):format(target.Name, money(w), carried(), capacity()))
		if not grab(target) then
			-- Not a reason to end the load: grab() has benched this one, so the next
			-- best() returns a different brainrot. Once everything reachable is benched
			-- best() comes back nil and the loop above ends on its own.
			say("lost " .. target.Name)
		end
	end

	if carried() == 0 then
		-- Naming the filter that came up empty is the difference between "waiting for a
		-- spawn" and "you asked for something that never spawns", which look identical
		-- from the outside and have completely different fixes.
		say("no " .. label(wanted) .. " reachable")
		tp(BASE) -- idle at home until one spawns
		return false
	end

	local load = carried()
	say(("banking %d"):format(load))
	tp(BASE)
	task.wait(DEPOSIT)

	-- Nothing in here empties you any more, so if standing on BASE isn't what does it,
	-- the next lap can't pick anything up and the farm looks dead with no reason given.
	-- Say it once per lap instead.
	if carried() >= load and full() then
		say(("still carrying %d -- base isn't taking them"):format(carried()))
		return false
	end
	return true
end

local function setFarming(on)
	if on == farming then
		return
	end
	farming = on
	if not on then
		say("returning to base") -- the loop below does the tp on its way out
		return
	end

	gen += 1
	local mine = gen -- off-then-on inside one wait would otherwise leave two loops running
	task.spawn(function()
		local total = 0
		while farming and gen == mine do
			local ok, got = pcall(lap)
			if not ok then
				warn("[bridgerots]", got) -- brainrots vanish mid-lap; a dead model throws
			elseif got then
				total += 1
				say(("farming - %d loads banked"):format(total))
			end
			if not (ok and got) then
				task.wait(DWELL)
			end
		end
		-- Going home happens here, not in the off branch, so it can't fight a lap that's
		-- still mid-teleport. gen check: a re-toggle already owns the character.
		if gen == mine then
			tp(BASE)
			say(("idle - %d loads banked"):format(total))
		end
	end)
end

-- gui ------------------------------------------------------------------------
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a
-- restyle is one file and not seventeen. Fetched here rather than installed by the
-- loader, so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Build a Bridge for Brainrots", -- fallback until the live name lands
	folder = "BridgeRots",
	size = UDim2.fromOffset(420, 360),
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local Section = Tab:Section({ Title = "Farm", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })

-- Declared first: the all/none shortcut below closes over the handle.
local rarityDrop

-- WindUI's Dropdown:Select() sets the value and redraws, but does NOT fire the
-- Callback (dist/main.lua as.Select) -- so `wanted` has to be set here as well. It is
-- the source of truth; Select only makes the ticks agree with it.
local function setRarities(set, value)
	wanted = set
	pcall(function()
		rarityDrop:Select(value) -- nil clears every tick on a Multi dropdown
	end)
	say(farming and ("hunting " .. label(wanted)) or ("rarity: " .. label(wanted)))
end

rarityDrop = Section:Dropdown({
	Title = "Rarity",
	Desc = "What to take. Richest of the ticked ones wins, not the rarest.",
	Values = RARITIES,
	Value = RARITIES,
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		-- Rebuilt rather than patched: the callback hands over the whole selection, and
		-- the loop reads `wanted` live, so a re-tick lands on the next grab on its own.
		wanted = ticked(values)
		if farming then
			say("hunting " .. label(wanted)) -- the tick is only visible here
		end
	end,
})

-- All/none, sat inside the dropdown's own row. WindUI only stacks whole rows, so this
-- reaches into the row frame: the value box is right-anchored inside DropdownFrame's
-- Main, so shift it left and take the space it gave up.
--
-- ponytail: internals, not API. If a WindUI update renames these the pcall leaves the
-- dropdown fully working and only the shortcut goes missing -- which is the right way
-- round for a convenience button.
pcall(function()
	local main = rarityDrop.DropdownFrame.UIElements.Main
	local box = rarityDrop.UIElements.Dropdown
	local SIZE, GAP = 28, 6

	box.Position = UDim2.new(1, -(SIZE + GAP), box.Position.Y.Scale, box.Position.Y.Offset)

	local btn = Instance.new("TextButton")
	btn.Size = UDim2.fromOffset(SIZE, SIZE)
	btn.AnchorPoint = Vector2.new(1, 0.5)
	btn.Position = UDim2.new(1, 0, 0.5, 0)
	btn.BackgroundColor3 = Color3.fromRGB(48, 48, 52)
	btn.AutoButtonColor = true
	btn.Text = "\226\156\147" -- check mark; no icon pack to resolve, no id to go stale
	btn.TextColor3 = Color3.fromRGB(225, 225, 230)
	btn.TextSize = 15
	btn.Font = Enum.Font.GothamMedium
	btn.ZIndex = box.ZIndex + 1
	btn.Parent = main

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0, 8)
	round.Parent = btn

	-- Flips: everything ticked means the only useful action is a clear, and from any
	-- other state you want the lot.
	btn.MouseButton1Click:Connect(function()
		local n = 0
		for _, name in ipairs(RARITIES) do
			n += wanted[name] and 1 or 0
		end
		if n == #RARITIES then
			setRarities({}, nil)
		else
			setRarities(ticked(RARITIES), RARITIES)
		end
	end)
end)

Section:Toggle({
	Title = "Auto Farm Rarity",
	Desc = "Fill up on the richest ticked brainrots you can reach, carry them home, repeat",
	Value = false,
	Callback = setFarming,
})

Section:Toggle({
	Title = "Lucky Blocks",
	Desc = "Take lucky blocks too, ranked by what they'll pay once their timer is up",
	Value = TAKE_BLOCKS,
	Callback = function(v)
		blocks = v
	end,
})

Section:Button({
	Title = "Collect cash now",
	Desc = "Teleports round the $ piles. Turn the farm off first -- one thread drives the character",
	Callback = function()
		if farming then
			say("turn Auto Farm off first")
			return -- one thread drives the character; see sweepCash
		end
		local got, missed = sweepCash()
		say(("swept %d, %d refused"):format(got, missed))
	end,
})

local line = Section:Paragraph({ Title = "Status", Desc = "idle" })
say = function(msg)
	line:SetDesc(msg)
end

-- close ----------------------------------------------------------------------
local function stopAll()
	farming = false
end

Window:OnDestroy(function()
	stopAll()
	getgenv().bridgeRotsStop = nil
end)

getgenv().bridgeRotsStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().bridgeRotsStop = nil
end
