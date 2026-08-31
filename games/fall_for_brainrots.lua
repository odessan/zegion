--[[ Fall For Brainrots -- multi-zone rarity farm

     TP ZONES : multi-select over Workspace > "NEW Dropper", listed highest tier
                first. TELEPORT sends you to the highest one you ticked. These are the
                level models (CommonLevel1 ... TranscendentLevel13) and we stand on
                their WorldPivot -- NOT DropperParts.Guards, which are the NPCs that
                kill you for taking a brainrot.
     RARITY   : multi-select. Tick every tier you want; FARM grabs all of them. The
                spawner folder name is NOT the item rarity -- ItemSpawners.Eternal
                holds Divine/Celestial/Eternal -- so this is picked separately.
     FARM     : toggle. Cycles the ticked zones highest tier first. At each one it
                sweeps ItemSpawners for ticked rarities, TPs onto every match, holds
                the "Pick Up" prompt, and returns to BASE. A full cycle that grabs
                nothing parks at BASE for IDLE before going round again.
     SPEED    : toggle + an x1/x5/x10 chip. Fires PurchaseSpeed with the chip's value
                every BUY_EVERY. The chip cycles while the loop runs.
     REBIRTH  : toggle. Fires RequestRebirth every REBIRTH_EVERY. The server refuses
                until you actually qualify, which is the intended way to use it --
                leave it on and it goes through the moment you're eligible.

     Executor: paste and run.  Studio: LocalScript in StarterPlayerScripts.
     RightControl minimises and expands the panel; RightAlt hides it outright.
     Stop: getgenv().ffbStop() ]]

-- config ---------------------------------------------------------------------
local BASE = CFrame.new(120.48938, 14587.2314, -2621.0625, 1, 0, 0, 0, 1, 0, 0, 0, 1)
local HEIGHT_OFFSET = 5 -- studs above a pivot, so you don't spawn inside it

-- ponytail: these waits are the whole tuning surface. The prompt is server-side --
-- firing it before the server agrees you moved does nothing. Raise SETTLE if grabs
-- come back empty. Prompt reads: "Pick Up", E, HoldDuration 0.5, range 10.5.
local SETTLE = 0.35 -- after a TP, before touching the prompt or scanning
local HOLD = 1 -- seconds to hold E (only used on the no-executor path)
local AFTER_GRAB = 0.25 -- after the prompt, before TPing to base
-- The server has to actually see you standing at BASE for its drop-off check. Setting
-- the CFrame and leaving 0.35s later often beat the position replicating, so the deposit
-- silently didn't take. Lower this only if you can confirm banking still happens.
local AT_BASE = 1.5 -- at base, before the next item
local RESCAN = 1 -- retry beat when no zones are ticked
-- The knob for "it left before grabbing anything". On arrival the zone's spawners
-- have not streamed yet, so a single scan sees nothing and moves on. This is how
-- long to keep looking before calling a zone empty -- raise it if zones get skipped.
local ZONE_DWELL = 2.5
-- Looking for the NEXT item while already standing in the zone: everything has
-- streamed by then, so this only has to cover an item spawning under your feet.
local NEXT_DWELL = 0.5
local POLL = 0.2 -- how often to re-scan while dwelling
local IDLE = 5 -- seconds parked at BASE after a full cycle that grabbed nothing
local STREAM_TIMEOUT = 3 -- max seconds to wait for a region to stream before jumping in
local ZONE_RADIUS = 60 -- studs; inside this you count as "already at the zone"
-- Studs to a guard before we bail to BASE. Guards kill you for carrying a brainrot,
-- so this is the one distance worth being twitchy about -- raise it if you still die.
local GUARD_RADIUS = 30
local COLLECT_EVERY = 3 -- seconds between full sweeps of your plot's collect pads
local TOUCH_GAP = 0.05 -- between touch-begin and touch-end on a pad

-- The value PurchaseSpeed takes. The x1/x5/x10 chip cycles these; 10 is what the
-- game's own button sends on its largest step.
local SPEED_STEPS = { 1, 5, 10 }
local BUY_EVERY = 1 -- seconds between PurchaseSpeed fires while AUTO SPEED is on
local REBIRTH_EVERY = 5 -- seconds between RequestRebirth fires; the server rejects the rest

-- Both ladders are verbatim from ReplicatedStorage.BrainrotStorage.Modules, in their
-- declared order -- ascending tier, which an alphabetical sort would scramble. These
-- modules are dictionaries, so require() cannot recover the order.
local RARITIES = { -- RarityConfigurations
	"Common",
	"Uncommon",
	"Rare",
	"Epic",
	"Legendary",
	"Mythical",
	"Cosmic",
	"Secret",
	"Divine",
	"Celestial",
	"Eternal",
	"Abyssal",
	"Transcendent",
	"Exclusive",
}
local ZONE_TIERS = { -- ZoneConfigurations; no Exclusive zone exists
	"COMMON",
	"UNCOMMON",
	"RARE",
	"EPIC",
	"LEGENDARY",
	"MYTHICAL",
	"COSMIC",
	"SECRET",
	"DIVINE",
	"CELESTIAL",
	"ETERNAL",
	"ABYSSAL",
	"TRANSCENDENT",
}

local KEY_TOGGLE = Enum.KeyCode.RightControl

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local player = Players.LocalPlayer

if getgenv and getgenv().ffbStop then
	getgenv().ffbStop()
end

-- world ----------------------------------------------------------------------
-- Zones come from Workspace["NEW Dropper"], NOT from DropperParts.Guards. Guards are
-- the NPCs that kill you for taking a brainrot -- teleporting onto one put you inside
-- the exact thing you're stealing from. These are the level models themselves, named
-- <Tier>Level<rank> (CommonLevel1 ... TranscendentLevel13), and their WorldPivot is
-- the spot you actually want to stand on.
local zoneRoot = workspace:WaitForChild("NEW Dropper", 10)
if not zoneRoot then
	warn('[FallForBrainrots] Workspace["NEW Dropper"] not found')
	return
end

-- Still where the spawned items live; only the zone markers moved.
local droppers = workspace:FindFirstChild("DropperParts")

-- Resolved once, defensively. ReplicatedStorage is replicated before we run, so these
-- should be here -- but a missing Events folder has to disable a button, not kill the
-- whole script at load with an index-nil.
local events = ReplicatedStorage:FindFirstChild("BrainrotStorage")
events = events and events:FindFirstChild("Events")
local speedEvent = events and events:FindFirstChild("PurchaseSpeed")
local rebirthEvent = events and events:FindFirstChild("RequestRebirth")

-- The NPCs that kill you for taking a brainrot. Looked up per check rather than cached:
-- like ItemSpawners, Guards only streams in once you're standing at a zone.
local function guardNear(pos, radius)
	local folder = droppers and droppers:FindFirstChild("Guards")
	if not folder then
		return false
	end
	for _, g in ipairs(folder:GetChildren()) do
		if g:IsA("PVInstance") and (g:GetPivot().Position - pos).Magnitude <= radius then
			return true
		end
	end
	return false
end

-- Looked up per sweep, never cached: ItemSpawners only streams in once you're
-- standing at a zone, so it does not exist when this script first runs.
local function spawnerRoot()
	return (droppers and droppers:FindFirstChild("ItemSpawners")) or zoneRoot:FindFirstChild("ItemSpawners")
end

-- Row tint straight from the game's own gradients, so a dozen-plus tiers stay
-- scannable. Returns an empty table if the module ever moves, and rows render plain.
local function palette(moduleName)
	local out = {}
	pcall(function()
		local cfg = require(ReplicatedStorage.BrainrotStorage.Modules[moduleName])
		for name, def in pairs(cfg) do
			local seq = def.GradientColor
			if seq then
				local best, bestLum = nil, -1
				for _, kp in ipairs(seq.Keypoints) do
					local c = kp.Value
					local lum = c.R * 0.299 + c.G * 0.587 + c.B * 0.114
					if lum > bestLum then
						best, bestLum = c, lum
					end
				end
				-- Abyssal and Secret are near-black by design; lift them or they
				-- vanish against the panel.
				out[name] = bestLum < 0.45 and best:Lerp(Color3.new(1, 1, 1), 0.5) or best
			end
		end
	end)
	return out
end

local rarityColor = palette("RarityConfigurations")
local zoneColor = palette("ZoneConfigurations")

-- Guards children are named like "ETERNAL-GUARD", so the tier is a substring. Walk the
-- ladder top down and take the first hit -- COMMON is a substring of UNCOMMON, and the
-- higher tier has to win.
local function zoneTier(name)
	name = name:upper()
	for i = #ZONE_TIERS, 1, -1 do
		if name:find(ZONE_TIERS[i], 1, true) then
			return ZONE_TIERS[i], i
		end
	end
	return nil, 0
end

-- NEW Dropper also holds HomeTPs, JumpSigns and Plots. "Does the name carry a tier"
-- filters those out on its own, so there's no skip list to keep in sync.
local function collectZones()
	local out = {}
	for _, inst in ipairs(zoneRoot:GetChildren()) do
		if inst:IsA("PVInstance") and zoneTier(inst.Name) then
			table.insert(out, inst)
		end
	end
	-- Rank once per zone, not once per comparison: table.sort calls the comparator
	-- O(n log n) times and zoneTier allocates an uppercased string every call.
	local rank = {}
	for _, z in ipairs(out) do
		local _, r = zoneTier(z.Name)
		rank[z] = r
	end
	table.sort(out, function(a, b)
		if rank[a] ~= rank[b] then
			return rank[a] > rank[b] -- highest tier first
		end
		return a.Name < b.Name
	end)
	return out
end

local zones = collectZones()

-- Both selections are keyed by NAME, never by Instance. Guards repopulates mid-round
-- with fresh zone Instances, and a name survives that -- an Instance key would go
-- stale, keep the dead zone ticked forever, and never respond to an untick.
local selectedZones = {} -- set: zone name -> true
local selectedRarities = { Eternal = true } -- set: rarity name -> true
if zones[1] then
	selectedZones[zones[1].Name] = true -- default to the highest tier available
end

-- Rows are names, so de-dupe: two zones can share a name, and one row that ticks
-- both is what you want anyway.
local function zoneNames()
	local out, seen = {}, {}
	for _, z in ipairs(zones) do
		if not seen[z.Name] then
			seen[z.Name] = true
			out[#out + 1] = z.Name
		end
	end
	return out
end

local function summarize(set, all)
	local n, only = 0, nil
	for _, name in ipairs(all) do
		if set[name] then
			n += 1
			only = only or name
		end
	end
	if n == 0 then
		return "none selected"
	elseif n == 1 then
		return only
	elseif n == #all then
		return "all"
	end
	return n .. " selected"
end

-- Ticked zones, highest tier first. Rebuilt per cycle so a zone that despawns
-- mid-farm drops out instead of erroring.
local function orderedZones()
	local out = {}
	for _, z in ipairs(zones) do
		if selectedZones[z.Name] and z.Parent then
			table.insert(out, z)
		end
	end
	return out -- `zones` is already sorted highest tier first
end

local function hrp()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function nearCF(cf, radius)
	local root = hrp()
	return root ~= nil and (root.Position - cf.Position).Magnitude <= radius
end

-- "Gameplay Paused" is the streaming pause: you landed somewhere the client hasn't
-- received yet. Requesting the region first means there's nothing left to pause for.
-- It yields, so re-read the character afterwards -- you may have respawned mid-wait.
local function goTo(cf)
	pcall(function()
		player:RequestStreamAroundAsync(cf.Position, STREAM_TIMEOUT)
	end)
	local root = hrp()
	if not root then
		return false
	end
	root.CFrame = cf
	return true
end

local function zoneCF(zone)
	if not zone or not zone.Parent then
		return nil
	end
	return zone:GetPivot() + Vector3.new(0, HEIGHT_OFFSET, 0)
end

local function teleport(zone)
	local cf = zoneCF(zone)
	if not cf then
		return false, "no zone -- tick one"
	end
	if not goTo(cf) then
		return false, "no character"
	end
	return true, "at " .. zone.Name
end

-- farm -----------------------------------------------------------------------
-- Weak keys: a grabbed SpawnedItem gets destroyed, and this table shouldn't be the
-- one thing keeping it alive. Stops us re-teleporting to an item mid-despawn.
local tried = setmetatable({}, { __mode = "k" })

local farming = false
local grabbed = 0

-- Executor global; nil in Studio, where we fall back to a real 1s prompt hold.
local fireprompt = fireproximityprompt

local function matchingItems(zone)
	local root = spawnerRoot()
	if not root then
		return {} -- not streamed in yet; caller stands at the zone to force it
	end
	-- Scope by TIER, not by zone name: zones are named ETERNAL-GUARD and the spawner
	-- folders Eternal, so matching on the raw name never hit and every scan silently
	-- swept the whole root -- grabbing other zones' items and making the cycle pointless.
	local tier = zone and zoneTier(zone.Name)
	local scope = (tier and root:FindFirstChild(tier:sub(1, 1) .. tier:sub(2):lower())) or root
	local out = {}
	for _, d in ipairs(scope:GetDescendants()) do
		if d:GetAttribute("IsSpawnedItem") and selectedRarities[d:GetAttribute("Rarity")] and not tried[d] then
			local prompt = d:FindFirstChildWhichIsA("ProximityPrompt", true)
			if prompt and prompt.Enabled then
				table.insert(out, { model = d, prompt = prompt })
			end
		end
	end
	return out
end

-- Stand here and keep scanning until something matching shows up or we run out of
-- patience. Returns as soon as there's a hit, so a loaded zone costs no extra time.
local function waitForItems(zone, seconds)
	local deadline = os.clock() + seconds
	repeat
		local items = matchingItems(zone)
		if #items > 0 then
			return items
		end
		task.wait(POLL)
	until os.clock() >= deadline
	return {}
end

local function pickUp(prompt)
	if fireprompt then
		fireprompt(prompt, 1)
	else
		-- Plain Roblox API, no executor needed: this is a genuine held E.
		prompt:InputHoldBegin()
		task.wait(HOLD)
		if prompt.Parent then
			prompt:InputHoldEnd()
		end
	end
end

local function grab(entry)
	if not hrp() then
		return false
	end
	tried[entry.model] = true
	if not goTo(entry.model:GetPivot() + Vector3.new(0, HEIGHT_OFFSET, 0)) then
		tried[entry.model] = nil -- never actually attempted (respawn mid-TP); don't write it off
		return false
	end
	task.wait(SETTLE)
	if entry.prompt.Parent then
		pickUp(entry.prompt)
	end
	task.wait(AFTER_GRAB)
	-- A picked-up item gets destroyed. If it's still parented the grab didn't take
	-- (server refused, or we were out of range), so un-blacklist it and let the next
	-- sweep retry -- otherwise one hiccup writes off an Eternal permanently.
	local took = entry.model.Parent == nil
	if took then
		grabbed = grabbed + 1
	else
		tried[entry.model] = nil
	end
	return took
end

-- Bank what you're carrying. Deliberately NOT part of grab(): the BASE trip is what
-- unstreams the zone, so it happens once per load rather than once per item.
local function deposit()
	goTo(BASE)
	task.wait(AT_BASE)
end

-- collect --------------------------------------------------------------------
-- Dex path is Plot_<you> > FloorN > Slots > SlotN > CollectTouch, a BasePart with a
-- TouchInterest on it. Matching on the name means every floor and every slot is
-- picked up the moment it exists -- no per-floor list to maintain.
--
-- Scoped to YOUR plot: every plot on the server has the same pads, and other
-- people's pay you nothing.
local plot, pads = nil, nil

local function findPlot()
	local found = workspace:FindFirstChild("Plot_" .. player.Name, true)
	if not found then
		-- ponytail: name match only. If the game ever stops naming plots after the
		-- owner, read the owner value off the plot instead.
		for _, d in ipairs(workspace:GetDescendants()) do
			if d.Name:find("Plot_", 1, true) and d.Name:find(player.Name, 1, true) then
				found = d
				break
			end
		end
	end
	if found then
		-- Buying a floor adds pads. Drop the cache and let the next sweep rebuild it,
		-- so the steady state costs no plot walk at all.
		local function drop()
			pads = nil
		end
		found.DescendantAdded:Connect(drop)
		found.DescendantRemoving:Connect(drop)
	end
	return found
end

local function collectParts()
	if not plot or not plot.Parent then
		plot, pads = findPlot(), nil -- plot got rebuilt (rejoin, reset)
	end
	if not plot then
		return {}
	end
	if not pads then
		pads = {}
		for _, d in ipairs(plot:GetDescendants()) do
			if d.Name == "CollectTouch" and d:IsA("BasePart") then
				pads[#pads + 1] = d
			end
		end
	end
	return pads
end

-- Executor global. firetouchinterest reaches the server-side Touched handler without
-- moving you, which is the whole reason collecting can run while the farm loop is
-- driving your character somewhere else.
local firetouch = firetouchinterest

local collecting = false
local cashSweeps = 0

-- nil, not 0, when there's nothing to touch WITH -- a missing character isn't the
-- plot's fault and shouldn't print a plot error.
local function collectAll()
	local root = hrp()
	if not root or not firetouch then
		return nil
	end
	-- One gap for the whole sweep instead of one per pad: the server sees the same
	-- begin/end pairs, and 40 slots stop costing 2s of a 3s budget.
	local parts = collectParts()
	for _, part in ipairs(parts) do
		pcall(firetouch, root, part, 0)
	end
	task.wait(TOUCH_GAP)
	for _, part in ipairs(parts) do
		pcall(firetouch, root, part, 1)
	end
	return #parts
end

-- gui ------------------------------------------------------------------------
local BG = Color3.fromRGB(18, 19, 26)
local PANEL = Color3.fromRGB(27, 29, 38)
local ROW = Color3.fromRGB(35, 38, 50)
local ROW_HOVER = Color3.fromRGB(45, 49, 66)
local ROW_ON = Color3.fromRGB(52, 57, 80)
local ACCENT = Color3.fromRGB(124, 92, 255)
local ACCENT2 = Color3.fromRGB(0, 210, 255)
local ON_C = Color3.fromRGB(52, 168, 110)
local TXT = Color3.fromRGB(232, 234, 245)
local MUTED = Color3.fromRGB(122, 127, 146)
local GOOD = Color3.fromRGB(120, 220, 160)
local BAD = Color3.fromRGB(255, 130, 140)

local W = 268

-- ponytail: one constructor for the whole panel -- class, property table, parent. It
-- isn't fewer lines than the assignment blocks it replaces; it's that UICorner, UIStroke
-- and the hover pair stop being retyped at every widget and can't drift apart.
local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do
		o[k] = v
	end
	o.Parent = parent
	return o
end

local function corner(inst, r)
	new("UICorner", { CornerRadius = UDim.new(0, r) }, inst)
	return inst
end

-- Tweens were being built per mouse event; one shared TweenInfo, and the hover pair
-- written once instead of at four sites in three different styles.
local HOVER = TweenInfo.new(0.12)
local function hover(inst, from, to)
	inst.MouseEnter:Connect(function()
		TweenService:Create(inst, HOVER, { BackgroundColor3 = to }):Play()
	end)
	inst.MouseLeave:Connect(function()
		TweenService:Create(inst, HOVER, { BackgroundColor3 = from }):Play()
	end)
	return inst
end

-- Layout, top to bottom. Buttons sit ABOVE the dropdowns on purpose: the lists open
-- downward and float over whatever is below them, and when one covered TELEPORT/FARM
-- a click meant for a row could land on a button as the list tweened shut.
local BTN_Y = 52
local COLLECT_Y = 90
local SPEED_Y = 128
local REBIRTH_Y = 166
local STATUS_Y = 206
local ZONE_Y = 230
local RARITY_Y = 290
local PANEL_H = 354

local gui = new("ScreenGui", {
	Name = "FallForBrainrots",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, player:WaitForChild("PlayerGui"))

local panel = corner(
	new("Frame", {
		Size = UDim2.fromOffset(W, PANEL_H),
		Position = UDim2.new(0.5, -W / 2, 0, 60),
		BackgroundColor3 = BG,
		BorderSizePixel = 0,
		Active = true,
		Draggable = true, -- ponytail: deprecated but one line; swap for InputBegan drag if it breaks
	}, gui),
	12
)

local function outline(inst)
	return new("UIStroke", { Color = Color3.fromRGB(58, 62, 82), Thickness = 1, Transparency = 0.3 }, inst)
end
outline(panel)

local bar = corner(new("Frame", {
	Size = UDim2.new(1, -2, 0, 3),
	Position = UDim2.fromOffset(1, 1),
	BorderSizePixel = 0,
	BackgroundColor3 = ACCENT,
}, panel), 3)
new("UIGradient", { Color = ColorSequence.new(ACCENT, ACCENT2) }, bar)

local function label(props, parent)
	props.BackgroundTransparency = 1
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return new("TextLabel", props, parent)
end

label({
	Size = UDim2.new(1, -60, 0, 22),
	Position = UDim2.fromOffset(14, 12),
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	TextColor3 = TXT,
	Text = "FALL FOR BRAINROTS",
}, panel)

label({
	Size = UDim2.new(1, -60, 0, 14),
	Position = UDim2.fromOffset(14, 30),
	Font = Enum.Font.Gotham,
	TextSize = 10,
	TextColor3 = MUTED,
	Text = "multi-zone rarity farm",
}, panel)

local function iconButton(text, x, color)
	return hover(
		corner(
			new("TextButton", {
				Size = UDim2.fromOffset(22, 22),
				Position = UDim2.new(1, x, 0, 12),
				BackgroundColor3 = ROW,
				BorderSizePixel = 0,
				AutoButtonColor = false,
				Font = Enum.Font.GothamBold,
				TextSize = 12,
				TextColor3 = color,
				Text = text,
			}, panel),
			6
		),
		ROW,
		ROW_HOVER
	)
end

local refreshBtn = iconButton("\u{27F3}", -56, MUTED)
local closeBtn = iconButton("\u{00D7}", -30, BAD)

-- dropdowns ------------------------------------------------------------------
-- Both are multi-select and both hold plain name strings. `chosen` is the caller's own
-- selection set, edited in place -- no alias, no shadow copy, no re-sync on rebuild.
-- colorOf tints each row from the game's own palette.
local ROW_H = 28
local ROW_GAP = 2
local LIST_PAD = 4
local dropdowns = {}

local function makeDropdown(y, labelText, chosen, colorOf)
	local d = { items = {}, chosen = chosen, open = false, rows = {} }

	label({
		Size = UDim2.new(1, -28, 0, 14),
		Position = UDim2.fromOffset(14, y),
		Font = Enum.Font.GothamMedium,
		TextSize = 10,
		TextColor3 = MUTED,
		Text = labelText,
	}, panel)

	local btn = hover(
		corner(
			new("TextButton", {
				Size = UDim2.new(1, -28, 0, 34),
				Position = UDim2.fromOffset(14, y + 18),
				BackgroundColor3 = ROW,
				BorderSizePixel = 0,
				AutoButtonColor = false,
				Font = Enum.Font.GothamMedium,
				TextSize = 12,
				TextColor3 = TXT,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = "",
			}, panel),
			8
		),
		ROW,
		ROW_HOVER
	)
	new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 30) }, btn)

	local arrow = label({
		Size = UDim2.fromOffset(20, 34),
		Position = UDim2.new(1, -26, 0, y + 18),
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		TextColor3 = MUTED,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "\u{25BC}",
	}, panel)

	-- ponytail: the list floats over the panel instead of resizing it. One ZIndex
	-- bump beats reflowing every control below it every time the menu opens.
	local list = corner(
		new("ScrollingFrame", {
			Size = UDim2.new(1, -28, 0, 0),
			Position = UDim2.fromOffset(14, y + 56),
			BackgroundColor3 = PANEL,
			BorderSizePixel = 0,
			Visible = false,
			ZIndex = 5,
			ClipsDescendants = true,
			-- Absorb clicks that land on the list, so an open TP ZONES list can't leak
			-- a click through to the RARITY button sitting underneath it.
			Active = true,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = ACCENT,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
		}, panel),
		8
	)
	outline(list)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, ROW_GAP) }, list)
	new("UIPadding", {
		PaddingTop = UDim.new(0, LIST_PAD),
		PaddingBottom = UDim.new(0, LIST_PAD),
		PaddingLeft = UDim.new(0, LIST_PAD),
		PaddingRight = UDim.new(0, LIST_PAD),
	}, list)

	function d.setOpen(state)
		state = state and #d.items > 0
		if state == d.open then
			return -- closeMenus() runs on every click; don't tween shut what's already shut
		end
		d.open = state
		arrow.Text = state and "\u{25B2}" or "\u{25BC}"
		local rows = math.clamp(#d.items, 1, 6)
		list.Visible = true
		local tween = TweenService:Create(list, TweenInfo.new(0.16, Enum.EasingStyle.Quad), {
			Size = UDim2.new(1, -28, 0, state and (rows * (ROW_H + ROW_GAP) + LIST_PAD * 2) or 0),
		})
		tween:Play()
		if not state then
			tween.Completed:Connect(function()
				list.Visible = d.open
			end)
		end
	end

	local function paintRow(name)
		local row = d.rows[name]
		if not row then
			return
		end
		local on = chosen[name] == true
		row.BackgroundColor3 = on and ROW_ON or ROW
		row.Text = (on and "  \u{25A0}  " or "  \u{25A1}  ") .. name
	end

	function d.summary()
		return summarize(chosen, d.items)
	end

	local function refreshLabel()
		btn.Text = d.summary()
		btn.TextColor3 = next(chosen) and TXT or MUTED
	end

	function d.setChosen(name, on)
		chosen[name] = on or nil
		paintRow(name)
		refreshLabel()
	end

	function d.setItems(items)
		d.items = items
		d.rows = {}
		for _, c in ipairs(list:GetChildren()) do
			if c:IsA("TextButton") then
				c:Destroy()
			end
		end
		for i, name in ipairs(items) do
			local row = corner(
				new("TextButton", {
					Size = UDim2.new(1, 0, 0, ROW_H),
					LayoutOrder = i,
					BorderSizePixel = 0,
					AutoButtonColor = false,
					Font = Enum.Font.GothamMedium,
					TextSize = 11,
					TextColor3 = (colorOf and colorOf(name)) or TXT,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					ZIndex = 6,
				}, list),
				6
			)
			d.rows[name] = row
			paintRow(name)
			row.MouseEnter:Connect(function()
				row.BackgroundColor3 = ROW_HOVER
			end)
			row.MouseLeave:Connect(function()
				paintRow(name)
			end)
			row.MouseButton1Click:Connect(function()
				d.setChosen(name, not chosen[name])
			end)
		end
		refreshLabel()
	end

	btn.MouseButton1Click:Connect(function()
		local want = not d.open
		for _, other in ipairs(dropdowns) do
			if other ~= d then
				other.setOpen(false)
			end
		end
		d.setOpen(want)
	end)

	table.insert(dropdowns, d)
	return d
end

local zoneDrop = makeDropdown(ZONE_Y, "TP ZONES", selectedZones, function(name)
	return zoneColor[(zoneTier(name))]
end)

local rarityDrop = makeDropdown(RARITY_Y, "RARITY", selectedRarities, function(r)
	return rarityColor[r]
end)

local function closeMenus()
	for _, d in ipairs(dropdowns) do
		d.setOpen(false)
	end
end


-- buttons --------------------------------------------------------------------
local BTN_W = (W - 28 - 8) / 2

-- Hover fades rather than recolors: these carry gradients a color tween would flatten.
local function actionButton(x, y, w, text, bg)
	local b = corner(
		new("TextButton", {
			Size = UDim2.fromOffset(w, 34),
			Position = UDim2.fromOffset(x, y),
			BackgroundColor3 = bg,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Font = Enum.Font.GothamBold,
			TextSize = 12,
			TextColor3 = Color3.fromRGB(255, 255, 255),
			Text = text,
		}, panel),
		8
	)
	b.MouseEnter:Connect(function()
		TweenService:Create(b, HOVER, { BackgroundTransparency = 0.15 }):Play()
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(b, HOVER, { BackgroundTransparency = 0 }):Play()
	end)
	return b
end

local tpBtn = actionButton(14, BTN_Y, BTN_W, "TELEPORT", ACCENT)
new("UIGradient", { Color = ColorSequence.new(ACCENT, ACCENT2), Rotation = 15 }, tpBtn)

local farmBtn = actionButton(14 + BTN_W + 8, BTN_Y, BTN_W, "FARM", ROW)
local collectBtn = actionButton(14, COLLECT_Y, W - 28, "AUTO COLLECT CASH", ROW)

-- The chip cycles the amount PurchaseSpeed is fired with; the wide button toggles the
-- loop. Two controls rather than one that means both, so you can change the step
-- without stopping the buy.
local CHIP_W = 44
local speedIdx = #SPEED_STEPS -- default to the largest step
local stepBtn = actionButton(14, SPEED_Y, CHIP_W, "x" .. SPEED_STEPS[speedIdx], ROW_ON)
local speedBtn = actionButton(14 + CHIP_W + 8, SPEED_Y, W - 28 - CHIP_W - 8, "AUTO BUY SPEED", ROW)
local rebirthBtn = actionButton(14, REBIRTH_Y, W - 28, "AUTO REBIRTH", ROW)

local status = label({
	Size = UDim2.new(1, -28, 0, 14),
	Position = UDim2.fromOffset(14, STATUS_Y),
	Font = Enum.Font.Gotham,
	TextSize = 10,
	TextColor3 = MUTED,
	TextTruncate = Enum.TextTruncate.AtEnd,
	Text = "",
}, panel)

local function say(msg, color)
	status.Text = msg
	status.TextColor3 = color or MUTED
end

-- wiring ---------------------------------------------------------------------
-- Every switchable thing registers its setter here, so the close button and ffbStop
-- have one list to turn off instead of naming each loop.
local stoppers = {}

-- AUTO BUY SPEED and AUTO REBIRTH are the same trivial shape: fire one RemoteEvent on
-- an interval while lit. FARM and COLLECT deliberately don't share this shell -- they
-- carry guards, teleports and per-iteration status that would turn it into a config
-- table for two callers.
local function autoFire(btn, onText, offText, interval, fire)
	local on, gen = false, 0
	local function set(state)
		on = state
		-- Off-then-on inside one interval would otherwise leave the sleeping thread
		-- alive alongside the new one, and fire the remote at double rate.
		gen += 1
		local mine = gen
		btn.Text = on and onText or offText
		TweenService:Create(btn, HOVER, { BackgroundColor3 = on and ON_C or ROW }):Play()
		if not on then
			return
		end
		task.spawn(function()
			while on and gen == mine do
				-- pcall: the server rejects most of these (not enough cash, rebirth
				-- requirements unmet). That's the normal case, not an error worth
				-- killing the loop and leaving the button lit over.
				pcall(fire)
				task.wait(interval)
			end
		end)
	end
	btn.MouseButton1Click:Connect(function()
		closeMenus()
		if not fire then
			say(offText:lower() .. ": event not on this server", BAD)
			return
		end
		set(not on)
	end)
	table.insert(stoppers, set)
end

stepBtn.MouseButton1Click:Connect(function()
	closeMenus()
	speedIdx = speedIdx % #SPEED_STEPS + 1
	stepBtn.Text = "x" .. SPEED_STEPS[speedIdx]
end)

autoFire(
	speedBtn,
	"AUTO BUY SPEED: ON",
	"AUTO BUY SPEED",
	BUY_EVERY,
	speedEvent and function()
		speedEvent:FireServer(SPEED_STEPS[speedIdx])
	end
)

autoFire(
	rebirthBtn,
	"AUTO REBIRTH: ON",
	"AUTO REBIRTH",
	REBIRTH_EVERY,
	rebirthEvent and function()
		rebirthEvent:FireServer()
	end
)

-- Selection lives in selectedZones/selectedRarities, keyed by name, so a rebuild is
-- just "re-list the rows" -- the ticks come back on their own.
local function rebuild()
	zones = collectZones()
	zoneDrop.setItems(zoneNames())
	say(zoneDrop.summary() .. " zones, " .. rarityDrop.summary())
end

local collectGen = 0

local function setCollecting(state)
	collecting = state
	collectGen += 1
	local mine = collectGen -- see autoFire: don't leave a sleeping thread behind on off/on
	collectBtn.Text = state and "AUTO COLLECT: ON" or "AUTO COLLECT CASH"
	TweenService:Create(collectBtn, HOVER, { BackgroundColor3 = state and ON_C or ROW }):Play()
	if not state then
		return
	end
	-- Its own thread: firing a TouchInterest doesn't move you, so this keeps paying out
	-- while the farm loop is teleporting your character around. It exits when you
	-- toggle off, so an idle panel costs nothing (and ffbStop actually stops it).
	task.spawn(function()
		while collecting and collectGen == mine do
			local n = collectAll()
			cashSweeps += 1
			-- Don't stomp the farm's live status with a collect complaint.
			if n == 0 and not farming then
				say("collect: no pads found -- is your plot loaded?", BAD)
			end
			task.wait(COLLECT_EVERY)
		end
	end)
end

-- Bail to BASE if a guard is on top of us. Returns true if we ran, so the caller knows
-- it's no longer at the zone and is carrying nothing.
local function fleeGuard(zone)
	local root = hrp()
	if not root or not guardNear(root.Position, GUARD_RADIUS) then
		return false
	end
	say(zone.Name .. ": guard close -- bailing", BAD)
	deposit()
	return true
end

local function runCycle()
	local order = orderedZones()
	if #order == 0 then
		say("tick at least one zone", BAD)
		task.wait(RESCAN)
		return
	end

	local anyGrab = false
	for _, zone in ipairs(order) do
		if not farming then
			break
		end
		-- Grab back to back without leaving, and RE-SCAN between each rather than
		-- trusting a list: waitForItems returns on the FIRST hit, so on arrival the
		-- list is usually just the one item that had streamed in so far. (Carrying a
		-- list across a BASE trip was worse still -- the trip unstreams the zone and
		-- orphans every model in it, so items 2..N failed the .Parent check silently.)
		--
		-- The carry limit is never read anywhere, because it doesn't have to be: the
		-- server refusing a pickup IS the limit, whatever it happens to be today. Bank
		-- and come back. That also survives the limit changing on a rebirth.
		local got, fails, carried = 0, 0, 0
		-- Go to the zone pivot ONLY on first arrival and after banking. The old code
		-- re-checked nearCF every pass, and after a grab you're standing where the item
		-- was -- usually outside ZONE_RADIUS -- so it teleported you back to the pivot
		-- and then dwelled the full ZONE_DWELL there. That round trip is the couple of
		-- seconds of standing still that the guard was killing you during. Once we're
		-- in the zone the items are already streamed, so scan from wherever we landed.
		local needTrip = true
		while farming and fails < 3 do
			local dwell = NEXT_DWELL
			if needTrip then
				local cf = zoneCF(zone)
				if cf and not nearCF(cf, ZONE_RADIUS) then
					teleport(zone)
				end
				needTrip = false
				dwell = ZONE_DWELL -- just landed; give the zone time to stream in
			end

			if fleeGuard(zone) then
				-- A zone we can't stand in is a zone to move on from. Counting this as
				-- a failure means a guard parked on the spawner can't loop us forever.
				carried, needTrip, fails = 0, true, fails + 1
				continue
			end

			say(zone.Name .. ": looking...", MUTED)
			local entry = waitForItems(zone, dwell)[1]
			if not entry then
				break -- zone is dry; the dwell already gave streaming its chance
			end

			say(
				"grabbing #"
					.. (got + 1)
					.. " "
					.. (entry.model:GetAttribute("Rarity") or "?")
					.. " "
					.. (entry.model:GetAttribute("OriginalName") or "item"),
				GOOD
			)
			if grab(entry) then
				anyGrab, got, carried, fails = true, got + 1, carried + 1, 0
				-- Holding something is exactly when the guard cares. Check before we
				-- stand here for the next scan.
				if fleeGuard(zone) then
					carried, needTrip = 0, true
				end
			else
				-- Refused = full, or lag, or a bad range check, and there is no way to
				-- tell them apart from here. Bank UNCONDITIONALLY: gating this on
				-- carried > 0 deadlocked the loop, because a deposit that didn't take
				-- left carried at 0 while you were still full, every later refusal got
				-- filed as "broken item", and carried could only rise again via a
				-- successful grab that being full made impossible.
				-- A refused grab is un-blacklisted on purpose, so it comes straight back
				-- in the next scan. Bail after a few or we'd never leave this zone; a
				-- successful grab clears the counter, so a bank that fixes it costs nothing.
				say(zone.Name .. ": refused at " .. carried .. " -- banking", MUTED)
				deposit()
				carried, needTrip, fails = 0, true, fails + 1
			end
		end

		if carried > 0 then
			deposit() -- never leave a zone still holding the load
		end

		if got == 0 then
			say(zone.Name .. ": nothing -- next zone", MUTED)
		else
			say(zone.Name .. ": got " .. got .. " -- next zone", GOOD)
		end
	end

	-- A whole cycle with nothing to show for it: park rather than keep
	-- bouncing between empty zones. Raise IDLE for fewer round trips.
	if farming and not anyGrab then
		goTo(BASE)
		say("nothing anywhere -- idling (" .. grabbed .. " grabbed)", MUTED)
		task.wait(IDLE)
	end
end

local farmGen = 0

local function setFarming(state)
	farming = state
	farmGen += 1
	local mine = farmGen -- see autoFire; two runCycles driving one character is worse still
	farmBtn.Text = state and "FARM: ON" or "FARM"
	TweenService:Create(farmBtn, HOVER, { BackgroundColor3 = state and ON_C or ROW }):Play()
	if not state then
		return
	end
	task.spawn(function()
		while farming and farmGen == mine do
			-- A crash in here used to kill this thread silently, leaving FARM stuck ON
			-- with nothing happening. Now it names the error and switches off cleanly.
			local ok, err = pcall(runCycle)
			if not ok then
				warn("[FallForBrainrots] farm cycle failed: " .. tostring(err))
				say("crashed -- see console", BAD)
				setFarming(false)
			end
		end
	end)
end

table.insert(stoppers, setFarming)
table.insert(stoppers, setCollecting)

local function stopAll()
	for _, stop in ipairs(stoppers) do
		stop(false)
	end
end

tpBtn.MouseButton1Click:Connect(function()
	closeMenus()
	local ok, msg = teleport(orderedZones()[1]) -- highest tier you ticked
	say(msg, ok and GOOD or BAD)
end)

farmBtn.MouseButton1Click:Connect(function()
	closeMenus()
	-- Ask orderedZones, not the tick set: a ticked zone that despawned isn't a zone.
	local order = orderedZones()
	if not farming then
		if #order == 0 then
			say("tick at least one zone first", BAD)
			return
		end
		if next(selectedRarities) == nil then
			say("tick at least one rarity first", BAD)
			return
		end
	end
	setFarming(not farming)
	if farming then
		teleport(order[1]) -- don't make you press TELEPORT first; FARM implies going to the zone
		say("farming " .. rarityDrop.summary() .. " across " .. #order .. " zones", GOOD)
	else
		say("stopped -- " .. grabbed .. " grabbed", MUTED)
	end
end)

collectBtn.MouseButton1Click:Connect(function()
	closeMenus()
	if not collecting and not firetouch then
		say("no firetouchinterest -- executor can't collect", BAD)
		return
	end
	setCollecting(not collecting)
	if collecting then
		local n = #collectParts()
		say(
			"collecting " .. n .. " pads" .. (plot and (" on " .. plot.Name) or " -- no plot found"),
			n > 0 and GOOD or BAD
		)
	else
		say("collect off -- " .. cashSweeps .. " sweeps", MUTED)
	end
end)

refreshBtn.MouseButton1Click:Connect(function()
	closeMenus()
	rebuild()
end)

closeBtn.MouseButton1Click:Connect(function()
	stopAll()
	gui.Enabled = false
end)

UIS.InputBegan:Connect(function(input, typing)
	if not typing and input.KeyCode == KEY_TOGGLE then
		gui.Enabled = not gui.Enabled
	end
end)

-- Guards can repopulate mid-round; keep the list honest without a poll loop. Debounced,
-- because a repopulate fires one event PER ZONE and each one used to tear down and
-- rebuild every row in both lists -- including the row under your cursor mid-click.
local pendingRebuild = false
local function scheduleRebuild()
	if pendingRebuild then
		return
	end
	pendingRebuild = true
	task.delay(0.15, function()
		pendingRebuild = false
		rebuild()
	end)
end
zoneRoot.ChildAdded:Connect(scheduleRebuild)
zoneRoot.ChildRemoved:Connect(scheduleRebuild)

rarityDrop.setItems(RARITIES) -- static list; built once, never rebuilt
rebuild()

if getgenv then
	getgenv().ffbStop = function()
		stopAll() -- every loop exits on its own flag, so this really does stop them
		gui:Destroy()
	end
end
