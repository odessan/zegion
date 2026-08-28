--[[ Island Farm -- tick some zones, loop them against the finish line

     ZONE      : multi-select over Workspace > Map > Islands (1-8, Frenzy), listed by
                 number with Frenzy last. Ticking only ticks -- TELEPORT goes to the
                 first one ticked, AUTO FARM visits them all.
     AUTO FARM : toggle. Cycles the ticked zones. At each one it TPs in, waits for
                 Brainrots to stream, and works the list BEST FIRST:

                     brainrot -> StealPrompt -> walk the line -> next brainrot

                 PRIORITY_ZONE (Frenzy) goes first every cycle and REPEATS while it
                 keeps yielding, so an active event gets worked to empty before the
                 other zones get a turn. There is no event detection: Brainrots streams
                 by chunk, so standing there IS the check -- inactive costs one TP.
                 A whole rotation that finds nothing parks for IDLE rather than
                 bouncing between empty zones.

     Targets are whatever is in workspace.Brainrots with a StealPrompt inside and
     within RADIUS of the island pivot. That prompt check is also the zone filter for
     free: the base plots (0,0,0 and -2,0,0) hold brainrots with no StealPrompt, so
     they never make the list.

     Ordering, both read off the billboard because that is the ONLY place this game puts
     either -- no attributes, no value objects. Income comes from the "$2.98B/s" label,
     rarity from its own label matched against the BrainrotsInfo ladder:

         PRIORITY_ZONE : rarity, then income, then distance
         everywhere else : income, then rarity, then distance

     Anything whose billboard hasn't streamed scores 0 on both and goes last.

     LINE      : cross once, on foot. The line is WALKED, never teleported through --
                 a PivotTo from one side to the other never touches the part in
                 between, so a Touched-based finish line never fires. That is why
                 teleporting to BASE did nothing. Crossing banks the carry into your
                 BACKPACK; putting brainrots into base slots is a separate job you do
                 from the inventory, and it is not what this loop is for.
     BASE      : plain TP, kept for getting out of trouble by hand. Not in the loop.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl hides/shows it. Stop: getgenv().islandTpStop() ]]

-- config ---------------------------------------------------------------------
local BASE = CFrame.new(26.7890625, 58.0223694, 74.3964844, -1, 0, 0, 0, 1, 0, 0, 0, -1)
local LINE = CFrame.new(-93.2106934, 55.2238808, -58.6269531, -1, 0, -0, 0, 0, -1, 0, -1, -0)

-- Size 260 x 1.994 x 1 under that rotation: local X -> world X (260 long), local Y ->
-- world Z (~2 studs WIDE), local Z -> world Y (1 tall). A narrow floor strip with lava
-- either side of it, so the crossing runs along Z and there is almost no room to stand.
-- Its UpVector is (0,0,-1); negated because +Z is the base side and you come at it from
-- the islands. Flip if you end up walking away from base.
local CROSS_FLIP = false
local CROSS_LIFT = 4 -- studs above the strip to land, so you drop onto it, not through it
local CROSS_BACK = 0 -- studs back from center to land. The strip is 2 wide -- 1 is already off it
local CROSS_FWD = 3 -- studs to walk forward; just enough to get the whole character over
local CROSS_SETTLE = 0.3 -- after landing, before walking

-- ponytail: the rest are guesses until you run it once. These waits are latency and
-- streaming, which no amount of code can work out from here.
local TP_OFFSET = Vector3.new(0, 10, 0) -- above an island pivot (model center, not surface)
local GRAB_OFFSET = Vector3.new(0, 3, 0) -- above a brainrot pivot; must land in prompt range
local RADIUS = 500 -- how far from the island pivot still counts as "this zone"
local PICK_RADIUS = 25 -- re-finding the brainrot after landing on its old spot
local STREAM_WAIT = 2 -- after landing on the island, before brainrots have streamed in
local APPROACH_WAIT = 0.35 -- after landing on a brainrot, before the prompt is live
local GRAB_WAIT = 0.6 -- after firing, before the carry has attached
local CROSS_WAIT = 0.5 -- after crossing, before the drop registers
local STREAM_TIMEOUT = 3 -- max seconds to wait for a region to stream before jumping in anyway
local IDLE = 5 -- seconds parked after a full cycle that found nothing in any zone
local PRIORITY_ZONE = "Frenzy" -- worked first and repeated while it pays; "" for a flat rotation
local KEY_TOGGLE = Enum.KeyCode.RightControl

-- Verbatim from ReplicatedStorage.Source.Info.BrainrotsInfo.byRarity, in its DECLARED
-- order -- ascending tier, which an alphabetical sort would scramble. Note this game
-- puts divine above celestial, the opposite of the ladder in fall_for_brainrots.
--
-- Only the order is needed, never the name lists: each brainrot's billboard prints its
-- own rarity as a label, so a hundred-name lookup table would be a second copy of a
-- fact already on screen.
local RARITY_ORDER = {
	"common",
	"uncommon",
	"rare",
	"epic",
	"legendary",
	"mythical",
	"cosmic",
	"secret",
	"celestial",
	"divine",
}

-- Cash suffixes, as the billboards spell them. Keys are lowercased at lookup, so Qa and
-- Qi can't collide with a plain Q -- the match is exact, not first-letter.
local SUFFIX = {
	k = 1e3,
	m = 1e6,
	b = 1e9,
	t = 1e12,
	qa = 1e15,
	qi = 1e18,
	sx = 1e21,
	sp = 1e24,
	oc = 1e27,
	no = 1e30,
	dc = 1e33,
}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService") -- only the status drain uses this
local player = Players.LocalPlayer

if getgenv and getgenv().islandTpStop then
	getgenv().islandTpStop()
end

local CROSS_DIR = LINE.UpVector * (CROSS_FLIP and 1 or -1)

-- world ----------------------------------------------------------------------
-- The numbered folders each hold a Model that carries the pivot, but a folder being
-- the model itself is one line to cover, so cover it.
local function pivotOf(inst)
	if inst:IsA("Model") or inst:IsA("BasePart") then
		return inst:GetPivot()
	end
	local child = inst:FindFirstChildWhichIsA("Model") or inst:FindFirstChildWhichIsA("BasePart")
	return child and child:GetPivot()
end

local function scanIslands()
	local out = {}
	local map = workspace:FindFirstChild("Map")
	local islands = map and map:FindFirstChild("Islands")
	if not islands then
		return out
	end
	for i, child in ipairs(islands:GetChildren()) do
		local cf = pivotOf(child)
		if cf then
			table.insert(out, { name = child.Name, cf = cf, order = i })
		end
	end
	-- Islands 7 and 8 each appear twice, so the name alone can't identify a row --
	-- sort numerically, keep explorer order as the tiebreak, and let the coordinates
	-- on the row tell the duplicates apart. Frenzy sorts last, being unnumbered.
	table.sort(out, function(a, b)
		local na, nb = tonumber(a.name), tonumber(b.name)
		if na and nb and na ~= nb then
			return na < nb
		end
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.order < b.order
	end)
	return out
end

-- The income is only ever billboard TEXT -- these models carry no attributes and no
-- value objects at all. It reads "$2.98B/s", or "$8/s" with no suffix, and is usually
-- wrapped in rich-text font tags, so we match the number and its suffix wherever they
-- sit in the string. Anchoring on "/s" keeps it off the level and price labels.
local function parseCash(text)
	local num, suffix = text:match("%$([%d%.,]+)(%a*)/s")
	if not num then
		return nil
	end
	local n = tonumber((num:gsub(",", "")))
	return n and n * (SUFFIX[suffix:lower()] or 1) or nil
end

assert(parseCash("$2.98B/s") == 2.98e9)
assert(parseCash("$8/s") == 8)
assert(parseCash("Lv.22") == nil)

local RARITY_RANK = {}
for i, name in ipairs(RARITY_ORDER) do
	RARITY_RANK[name] = i
end

-- One walk for both facts, since they come off the same set of labels. Rich-text tags
-- are stripped first: the income label is wrapped in them, and the rarity label has to
-- match the ladder exactly -- exactly is what keeps "Secret Lucky Block" from counting
-- as Secret, while the plain "Secret" label on the same billboard still does.
--
-- Zeroes mean the billboard hasn't streamed yet, which sorts last rather than wrong.
local function infoOf(model)
	local value, rarity = 0, 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("TextLabel") then
			local clean = d.Text:gsub("<[^>]*>", ""):match("^%s*(.-)%s*$")
			if value == 0 then
				value = parseCash(clean) or 0
			end
			if rarity == 0 then
				rarity = RARITY_RANK[clean:lower()] or 0
			end
		end
	end
	return value, rarity
end

-- Brainrots is a chunk grid: folders named "<x>,<y>,<z>" on a 100-stud step, only a
-- few of which hold anything. Rather than decode the names we just measure distance
-- from the island pivot, which is the same answer without a grid constant to get wrong.
local function scanBrainrots(pos, radius, rarityFirst)
	local out = {}
	local root = workspace:FindFirstChild("Brainrots")
	if not root then
		return out
	end
	for _, folder in ipairs(root:GetChildren()) do
		for _, model in ipairs(folder:GetChildren()) do
			local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
			local ok, cf = pcall(model.GetPivot, model)
			if prompt and ok then
				local dist = (cf.Position - pos).Magnitude
				if dist <= radius then
					local value, rarity = infoOf(model)
					table.insert(out, {
						model = model,
						prompt = prompt,
						cf = cf,
						dist = dist,
						value = value,
						rarity = rarity,
					})
				end
			end
		end
	end
	-- Best first, nearest to break ties. rarityFirst swaps the top two keys: rarity and
	-- income mostly agree, but level and mutations move income within a tier, so a
	-- levelled Cosmic can out-earn a fresh Divine. Both keys stay in play either way.
	table.sort(out, function(a, b)
		if rarityFirst and a.rarity ~= b.rarity then
			return a.rarity > b.rarity
		end
		if a.value ~= b.value then
			return a.value > b.value
		end
		if a.rarity ~= b.rarity then
			return a.rarity > b.rarity
		end
		return a.dist < b.dist
	end)
	return out
end

local function hrp()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- No offset means "use this CFrame exactly". With an offset we take position only,
-- because an island's own rotation would tilt the character with it.
--
-- "Gameplay Paused" is the streaming pause: you landed somewhere the client hasn't
-- received yet. StreamingEnabled belongs to the server and can't be switched off from
-- here, but requesting the region first leaves nothing to pause for. It yields, so the
-- character is re-read afterwards -- you may have respawned during the wait.
local function tp(cf, offset)
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
	prompt.RequiresLineOfSight = false -- client-side only, but the client is what gates the prompt
	if fireproximityprompt then
		fireproximityprompt(prompt, 1)
	else
		-- ponytail: no executor globals -- the honest hold, which needs you in range.
		prompt:InputHoldBegin()
		task.wait(prompt.HoldDuration + 0.1)
		prompt:InputHoldEnd()
	end
end

-- Land ON the strip, walk the couple of studs that take you across, then leave at once.
-- Landing short of it and walking well past it is what dropped us in the lava: there is
-- only about a stud of solid ground either side of center. Standing on it already counts
-- as a touch; the short walk is what makes it a crossing.
local function crossLine()
	if not tp(CFrame.new(LINE.Position - CROSS_DIR * CROSS_BACK + Vector3.new(0, CROSS_LIFT, 0))) then
		return false
	end
	task.wait(CROSS_SETTLE)
	local char = player.Character
	local hum = char and char:FindFirstChildWhichIsA("Humanoid")
	if not hum then
		return false
	end
	hum:MoveTo(LINE.Position + CROSS_DIR * CROSS_FWD)
	hum.MoveToFinished:Wait() -- self-times-out at 8s if the walk is blocked
	-- Straight back onto the strip rather than waiting out CROSS_WAIT wherever the walk
	-- ended. The touch has already registered by now, and the strip is the only ground
	-- here we know holds -- everything either side of it is lava.
	tp(CFrame.new(LINE.Position + Vector3.new(0, CROSS_LIFT, 0)))
	task.wait(CROSS_WAIT)
	return true
end

-- zones ----------------------------------------------------------------------
-- Held as island ENTRIES rather than names: two islands are both called 7 and two more
-- are both called 8, so a name can't identify a row. The dropdown carries a numbered
-- label per entry to keep WindUI's rows unique, and byLabel maps back.
local zoneItems, byLabel, chosen = {}, {}, {}

local function rowLabel(i, entry)
	return ("%d. %s"):format(i, entry.name)
end

-- Ticked zones in list order. Read fresh per cycle, so a zone that stops existing drops
-- out on its own instead of erroring mid-farm.
local function orderedZones()
	local out = {}
	for _, entry in ipairs(zoneItems) do
		if chosen[entry] then
			table.insert(out, entry)
		end
	end
	return out
end

-- farm -----------------------------------------------------------------------
local farming, stolen = false, 0

-- The farm loop never writes to the panel, it leaves a line here. Executors hand a
-- RESUMED thread back with reduced capability, so the first status write in a loop
-- lands and every one after a task.wait throws "cannot access 'Instance' (lacking
-- capability Plugin)" -- the panel lives in the hidden GUI, which is the part that
-- needs the capability. Uncaught, that kills the farm thread on its second lap.
-- The panel drains this from a Heartbeat, which the engine calls with our own identity.
local pending = nil
local function say(msg)
	pending = msg
end

-- Returns how many it took, so the cycle can tell an empty rotation from a working one.
local function runZone(island, rarityFirst)
	tp(island.cf, TP_OFFSET)
	task.wait(STREAM_WAIT)

	local targets = scanBrainrots(island.cf.Position, RADIUS, rarityFirst)
	if #targets == 0 then
		-- This is also the whole of the Frenzy handling. Frenzy only fills during its
		-- event, and an empty zone is an empty zone -- skip it, come back next cycle.
		-- Detecting the event itself would be a second thing to keep in sync with a
		-- fact the scan already tells us.
		say(island.name .. ": empty -- next zone")
		return 0
	end

	-- Positions are a snapshot: the models unstream while we're away at the line, so
	-- each trip returns to the remembered spot and re-finds whatever is standing there
	-- now. Anything already taken is simply gone, and gets skipped.
	local got = 0
	for i, t in ipairs(targets) do
		if not farming then
			break
		end
		say(
			string.format(
				"%s: %d/%d %s [%s $%.3g/s]",
				island.name,
				i,
				#targets,
				t.model.Name,
				RARITY_ORDER[t.rarity] or "?",
				t.value
			)
		)
		tp(t.cf, GRAB_OFFSET)
		task.wait(APPROACH_WAIT)
		local here = scanBrainrots(t.cf.Position, PICK_RADIUS)[1]
		if here then
			fire(here.prompt)
			task.wait(GRAB_WAIT)
			got += 1
			stolen += 1
			say(string.format("%s: crossing with %s", island.name, here.model.Name))
			crossLine()
		end
	end
	return got
end

local function runCycle(zones)
	local any = false

	-- Whether Frenzy is active can't be seen from anywhere else: Brainrots streams by
	-- chunk, so the only way to know is to stand there. So we don't detect the event at
	-- all -- we go there FIRST and stay while it keeps paying. An inactive Frenzy costs
	-- one wasted TP; an active one gets worked to empty before any other zone gets a
	-- turn, and the cycle comes straight back to it.
	local priority, rest = nil, {}
	for _, island in ipairs(zones) do
		if not priority and PRIORITY_ZONE ~= "" and island.name:lower() == PRIORITY_ZONE:lower() then
			priority = island
		else
			table.insert(rest, island)
		end
	end

	while farming and priority do
		local got = runZone(priority, true) -- rarity first while the event is up
		any = got > 0 or any
		if got == 0 then
			break -- not active (or picked clean); let the other zones have their turn
		end
	end

	for _, island in ipairs(rest) do
		if not farming then
			break
		end
		any = runZone(island) > 0 or any
	end
	-- A whole rotation with nothing to show for it: park rather than keep bouncing
	-- between empty zones. Raise IDLE for fewer round trips while waiting on Frenzy.
	if farming and not any then
		say("nothing in any zone -- idling (" .. stolen .. " taken)")
		task.wait(IDLE)
	end
end

local farmGen = 0
local farmToggle -- assigned by the panel; the off path has to move the switch too
local setFarming -- forward: the thread's own exit calls back into it

local function startFarm()
	farmGen += 1
	local mine = farmGen -- off-then-on shouldn't leave two loops driving one character
	task.spawn(function()
		while farming and farmGen == mine do
			-- Re-read the ticks every cycle, so untick and retick land without a restart.
			local zones = orderedZones()
			if #zones == 0 then
				say("tick at least one zone")
				break
			end
			-- A crash in here used to kill the thread silently, leaving FARM stuck ON
			-- with nothing happening. Name it and switch off cleanly instead.
			local ok, err = pcall(runCycle, zones)
			if not ok then
				warn("[IslandFarm]", err)
				say("crashed -- see console (F9)")
				break
			end
		end
		if farmGen == mine then
			setFarming(false)
		end
	end)
end

setFarming = function(state)
	if farming == state then
		return
	end
	farming = state
	if farmToggle then
		-- Same capability trap as the status line: this runs on the farm thread when the
		-- loop exits on its own. The flag above is what actually stops it, so a switch
		-- that won't move is cosmetic, not fatal.
		pcall(function()
			farmToggle:Set(state) -- re-enters here, which the equality guard absorbs
		end)
	end
	if state then
		startFarm()
	else
		say("stopped -- " .. stolen .. " taken")
	end
end

-- gui ------------------------------------------------------------------------
-- ponytail: the hand-rolled widget kit is gone. WindUI already ships rows, toggles,
-- multi-select dropdowns, drag, resize and the topbar buttons, so there is nothing here
-- worth owning. Fetched at runtime; nothing to vendor.
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a
-- restyle is one file and not sixteen. Fetched here rather than installed by the loader,
-- so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Island Farm", -- fallback until the live name lands
	folder = "IslandFarm", -- unchanged: renaming it orphans configs already saved in-game
	size = UDim2.fromOffset(440, 360),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local Farm = Tab:Section({ Title = "Farm", Icon = "solar:magic-stick-3-bold", Box = true, BoxBorder = true, Opened = true })

farmToggle = Farm:Toggle({
	Title = "Auto farm",
	Desc = "Cycle the ticked zones, best first, crossing the line after each grab",
	Value = false,
	Callback = setFarming, -- :Set() re-fires this, so setFarming has to be re-entrant
})

local zoneDrop = Farm:Dropdown({
	Title = "Zones",
	Desc = "Ticking only ticks -- TELEPORT goes to the first, AUTO FARM visits them all",
	Values = {},
	Value = {},
	Multi = true,
	AllowNone = true,
	Callback = function(picked)
		chosen = {}
		for _, name in ipairs(picked) do
			local entry = byLabel[name]
			if entry then
				chosen[entry] = true
			end
		end
		say(#orderedZones() .. " zones ticked")
	end,
})

local line = Farm:Paragraph({ Title = "Status", Desc = "idle" })

-- Drains whatever the farm thread last left. pcall'd anyway: if even this can't write
-- the panel, the run carries on with the status going to the console instead of taking
-- the loop down with it.
RunService.Heartbeat:Connect(function()
	if pending == nil then
		return
	end
	local msg = pending
	pending = nil
	if not pcall(function()
		line:SetDesc(msg)
	end) then
		print("[IslandFarm]", msg)
	end
end)

-- wiring ---------------------------------------------------------------------
-- Rebuilding drops the ticks, because the entries they point at are new objects. That's
-- the honest outcome: the list you re-read is not the list you ticked.
local function refresh()
	zoneItems, byLabel, chosen = scanIslands(), {}, {}
	local values = {}
	for i, entry in ipairs(zoneItems) do
		local label = rowLabel(i, entry)
		byLabel[label] = entry
		table.insert(values, {
			Title = label,
			Desc = ("%d, %d, %d"):format(entry.cf.X, entry.cf.Y, entry.cf.Z),
		})
	end
	zoneDrop:Refresh(values)
	say(#zoneItems .. " islands found -- tick the ones to farm")
end

local Manual = Tab:Section({ Title = "Manual", Icon = "solar:cursor-bold", Box = true, BoxBorder = true, Opened = true })

Manual:Button({
	Title = "Teleport to first ticked zone",
	Callback = function()
		local first = orderedZones()[1] -- first ticked; FARM is what visits the rest
		if not first then
			say("tick a zone first")
			return
		end
		task.spawn(function()
			say(tp(first.cf, TP_OFFSET) and ("at " .. first.name) or "no character")
		end)
	end,
})

Manual:Button({
	Title = "Cross line",
	Callback = function()
		task.spawn(function()
			say(crossLine() and "crossed" or "no character")
		end)
	end,
})

Manual:Button({
	Title = "TP to base",
	Callback = function()
		task.spawn(function()
			say(tp(BASE) and "at base" or "no character")
		end)
	end,
})

Manual:Button({
	Title = "Rescan islands",
	Desc = "Rebuilds the zone list. Clears your ticks.",
	Callback = refresh,
})

refresh()

-- close ----------------------------------------------------------------------
-- The loop exits on its own flag, so this really does stop it.
-- ponytail: rerun the script to come back.
local function stop()
	farming = false
	getgenv().islandTpStop = nil
	pcall(function()
		Window:Destroy()
	end)
end

Window:OnDestroy(stop)
getgenv().islandTpStop = stop
