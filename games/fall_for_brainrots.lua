--[[ Fall For Brainrots -- value-scored multi-zone farm (86368783421928)

     ZONES    : multi-select over Workspace > "NEW Dropper", highest tier first. These are
                the level models (CommonLevel1 ... SupremeLevel13) and we stand on their
                WorldPivot -- NOT DropperParts.Guards, which are the NPCs that kill you
                for taking a brainrot. TELEPORT sends you to the highest one you ticked.
     RARITY   : multi-select. The spawner folder name is NOT the item rarity --
                ItemSpawners.Eternal holds Divine/Celestial/Eternal -- so this is picked
                separately from the zone.
     MUTATION : multi-select. A mutation multiplies an item's income: 1x Normal up to 11x
                Hacked, and "67" has its own table topping out at 112x. Leave them all
                ticked unless you only want the shiny ones.
     FARM     : cycles the ticked zones highest tier first. In each one it scores every
                ticked item by Income x Mutation and goes for the RICHEST one, not the
                first one it trips over. Banks when the carry reads full, moves on when
                the zone is dry, parks at BASE for IDLE after a cycle that got nothing.
     COLLECT  : touches every CollectTouch pad on your plot on a timer. It never moves
                you, so it keeps paying out while the farm drives your character.
     UPGRADE  : RequestSlotMaxUpgrade on every slot whose Max button is lit. Firing only
                at lit buttons is what keeps this from stacking "not enough money" banners.
     SPEED    : PurchaseSpeed with the ticked step, on a timer.
     CARRY    : PurchaseCarry (+1 carry) on a timer. Fewer trips to base is the single
                biggest thing you can do for the farm's rate.
     REBIRTH  : RequestRebirth on a timer. The server refuses until you qualify, which is
                the intended way to use it -- leave it on and it goes through by itself.

     SPEED and CARRY fire the CASH buttons, never Robux. But the server answers a
     purchase you can't afford by pushing a product prompt at the game's own controller,
     which opens a Robux dialog -- so each of those toggles switches itself off the first
     time that happens instead of stacking popups.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().ffbStop() ]]

-- config ---------------------------------------------------------------------
local BASE = CFrame.new(120.48938, 14587.2314, -2621.0625, 1, 0, 0, 0, 1, 0, 0, 0, 1)
local HEIGHT_OFFSET = 5 -- studs above a pivot, so you don't spawn inside it

-- These waits are the whole tuning surface. The prompt is server-side -- firing it
-- before the server agrees you moved does nothing. Prompt reads: "Pick Up", E,
-- HoldDuration 0.5, range 10.5.
local SETTLE = 0.35 -- after a TP, before touching the prompt
local HOLD = 1 -- seconds to hold E (only used on the no-executor path)
local AFTER_GRAB = 0.25 -- after the prompt, before deciding whether it took
local AT_BASE = 1.5 -- fallback dwell at base when the carry label can't be read
local DEPOSIT_TIMEOUT = 4 -- give up waiting for the carry to empty at base
local RESCAN = 1 -- retry beat when no zones are ticked
-- The knob for "it left before grabbing anything". On arrival the zone's spawners have
-- not streamed yet, so a single scan sees nothing and moves on.
local ZONE_DWELL = 2.5
-- Looking for the NEXT item while already standing in the zone: everything has streamed
-- by then, so this only has to cover an item spawning under your feet.
local NEXT_DWELL = 0.5
local POLL = 0.2 -- how often to re-scan while dwelling
local IDLE = 5 -- seconds parked at BASE after a full cycle that grabbed nothing
local STREAM_TIMEOUT = 3 -- max seconds to wait for a region to stream before jumping in
local ZONE_RADIUS = 60 -- studs; inside this you count as "already at the zone"
-- Studs to a guard before we bail to BASE. This is the backstop; IsGuardTargetting is
-- the real signal. Raise it if you still die to a guard that never locked on.
local GUARD_RADIUS = 30
-- Seconds a refused item is parked for. It cannot be zero: the farm now takes the
-- HIGHEST-VALUE item first, so un-parking a refusal immediately means re-picking the
-- same unreachable item forever. It cannot be huge either -- a refusal is usually a
-- full carry, and after banking that same item is the one you want.
local RETRY_AFTER = 20
local ZONE_STRIKES = 3 -- refusals in one zone before moving on
local NOTE_WINDOW = 3 -- seconds; a server notification older than this isn't about us

local COLLECT_EVERY = 3 -- seconds between full sweeps of your plot's collect pads
local TOUCH_GAP = 0.05 -- between touch-begin and touch-end on a pad
local UPGRADE_EVERY = 5 -- seconds between upgrade sweeps; this one spends cash
local UPGRADE_GAP = 0.1 -- between slots in one sweep, so a plot isn't one burst

local SPEED_STEPS = { 1, 5, 10 } -- what PurchaseSpeed takes; 10 is the game's largest step
local BUY_EVERY = 1 -- seconds between PurchaseSpeed fires
local CARRY_EVERY = 5 -- seconds between PurchaseCarry fires; +1 carry gets dear fast
local REBIRTH_EVERY = 5 -- seconds between RequestRebirth fires

-- Verbatim from ReplicatedStorage.BrainrotStorage.Modules, in their DECLARED order --
-- ascending tier, which an alphabetical sort would scramble. The modules are
-- dictionaries, so require() cannot recover that order and this is the only place it
-- lives. Anything the live module has that these don't gets APPENDED at runtime rather
-- than going missing, which is how Supreme was invisible for the whole of the last
-- version: it exists in both modules and in neither list.
local RARITY_ORDER = {
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
	"Supreme",
	"Exclusive",
}
local ZONE_ORDER = { -- ZoneConfigurations; no Exclusive zone exists
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
	"SUPREME",
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().ffbStop then
	getgenv().ffbStop() -- re-running must not stack a second panel/loop
end

local say = function() end -- replaced by the panel below

-- world ----------------------------------------------------------------------
-- Zones come from Workspace["NEW Dropper"], NOT from DropperParts.Guards. Guards are the
-- NPCs that kill you for taking a brainrot -- teleporting onto one puts you inside the
-- exact thing you're stealing from.
local zoneRoot = workspace:WaitForChild("NEW Dropper", 10)
if not zoneRoot then
	warn('[FallForBrainrots] Workspace["NEW Dropper"] not found')
	return
end

-- Still where the spawned items live; only the zone markers moved.
local droppers = workspace:FindFirstChild("DropperParts")

-- Resolved once, defensively. A missing Events folder has to disable a toggle, not kill
-- the whole script at load with an index-nil.
local events = ReplicatedStorage:FindFirstChild("BrainrotStorage")
local modules = events and events:FindFirstChild("Modules")
events = events and events:FindFirstChild("Events")
local function event(name)
	return events and events:FindFirstChild(name)
end

local speedEvent = event("PurchaseSpeed")
local carryEvent = event("PurchaseCarry")
local rebirthEvent = event("RequestRebirth")
local slotMaxEvent = event("RequestSlotMaxUpgrade")
local notifyEvent = event("ShowNotification")
local speedPrompt = event("PromptSpeedProduct")
local carryPrompt = event("PromptCarryProduct")

-- Every connection made outside a toggle, so teardown can reach them. Without this they
-- outlive Window:Destroy and keep firing against destroyed rows, one more set per paste.
local conns = {}
local function track(c)
	table.insert(conns, c)
	return c
end

local function mod(name)
	local ok, m = pcall(function()
		return require(modules[name])
	end)
	return ok and m or nil
end

local function hrp()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- "Gameplay Paused" is the streaming pause: you landed somewhere the client hasn't
-- received yet. Requesting the region first means there's less left to pause for. It
-- YIELDS, so re-read the character afterwards -- you may have respawned mid-wait.
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

local function nearCF(cf, radius)
	local root = hrp()
	return root ~= nil and (root.Position - cf.Position).Magnitude <= radius
end

-- ladders --------------------------------------------------------------------
-- The declared order first, then anything the live module added. A name we've never
-- heard of ranks last rather than not existing -- the failure we're fixing is a tier
-- that silently can't be ticked, not one that's ranked slightly wrong.
local function ladder(order, ...)
	local out, extra, seen = {}, {}, {}
	for _, name in ipairs(order) do
		out[#out + 1], seen[name] = name, true
	end
	for _, keys in ipairs({ ... }) do
		for name in pairs(keys or {}) do
			if type(name) == "string" and not seen[name] then
				extra[#extra + 1], seen[name] = name, true
			end
		end
	end
	table.sort(extra) -- pairs() order isn't stable; the tail has to read the same twice
	table.move(extra, 1, #extra, #out + 1, out)
	return out
end
assert(ladder({ "A", "B" }, { B = 1, C = 1 })[3] == "C", "an unknown key lands after the ladder")
assert(ladder({ "A", "B" }, { B = 1 })[2] == "B", "known keys keep their declared order")

local ITEMS = mod("ItemConfigurations")
local MULT = mod("MutationMultipliers")

-- ItemConfigurations is the second opinion on which rarities exist: RarityConfigurations
-- is the palette table and an item's Rarity string is what actually gets filtered on, so
-- a tier present in one and not the other still has to be tickable.
local itemRarities = {}
for _, def in pairs(ITEMS and ITEMS.Items or {}) do
	if def.Rarity then
		itemRarities[def.Rarity] = true
	end
end

local RARITIES = ladder(RARITY_ORDER, mod("RarityConfigurations"), itemRarities)
local ZONE_TIERS = ladder(ZONE_ORDER, mod("ZoneConfigurations"))

-- Mutations need no hardcoded order at all: the multiplier table IS the ranking, and it
-- is the same table the value below is computed from.
local MUTATIONS = {}
for name in pairs(mod("MutationConfigurations") or (MULT and MULT.Default) or { Normal = 1 }) do
	MUTATIONS[#MUTATIONS + 1] = name
end
table.sort(MUTATIONS, function(a, b)
	local ma, mb = (MULT and MULT.Default[a]) or 0, (MULT and MULT.Default[b]) or 0
	if ma ~= mb then
		return ma < mb
	end
	return a < b
end)

if not ITEMS then
	warn("[FallForBrainrots] ItemConfigurations didn't load -- ranking falls back to rarity tier")
end

-- value ----------------------------------------------------------------------
-- Income x mutation multiplier, both out of the game's own modules. Spawned items are
-- what the billboard shows, so this product IS the number you're choosing between.
local rarityRank = {}
for i, name in ipairs(RARITIES) do
	rarityRank[name] = i
end

-- What an item the price table has never heard of is worth: the best its own rarity
-- pays. An update that adds a Transcendent shouldn't sort it behind a Common, and
-- scoring it 0 would do exactly that.
local tierIncome = {}
for _, def in pairs(ITEMS and ITEMS.Items or {}) do
	if def.Rarity and (tierIncome[def.Rarity] or 0) < (def.Income or 0) then
		tierIncome[def.Rarity] = def.Income
	end
end

local function mutationOf(model)
	return model:GetAttribute("Mutation") or "Normal"
end

local function value(model)
	local name = model:GetAttribute("OriginalName")
	local rarity = model:GetAttribute("Rarity")
	local def = name and ITEMS and ITEMS.Items and ITEMS.Items[name]
	local income = (def and def.Income) or tierIncome[rarity]
	if not income then
		-- No price table at all: rank by tier so the sort still means something.
		return (rarityRank[rarity] or 0)
	end
	return income * ((MULT and MULT.Get(name, mutationOf(model))) or 1)
end

-- Reading the tier out of a name that carries it, rather than a folder path. Walk the
-- ladder TOP DOWN and take the first hit -- COMMON is a substring of UNCOMMON, and the
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
assert(zoneTier("UncommonLevel3") == "UNCOMMON", "the longer tier wins over its substring")
assert(zoneTier("HomeTPs") == nil, "a name with no tier in it isn't a zone")

-- zones ----------------------------------------------------------------------
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

-- Selections are keyed by NAME, never by Instance: zones repopulate mid-round with fresh
-- Instances, and an Instance key would go stale, keep the dead zone ticked forever, and
-- never respond to an untick.
local wantZone, wantRarity, wantMutation = {}, {}, {}
if zones[1] then
	wantZone[zones[1].Name] = true -- default to the highest tier available
end
for _, name in ipairs(RARITIES) do
	wantRarity[name] = true
end
for _, name in ipairs(MUTATIONS) do
	wantMutation[name] = true
end

-- Rows are names, so de-dupe: two zones can share a name, and one row that ticks both is
-- what you want anyway.
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

-- Ticked zones, highest tier first. Rebuilt per cycle so a zone that despawns mid-farm
-- drops out instead of erroring.
local function orderedZones()
	local out = {}
	for _, z in ipairs(zones) do
		if wantZone[z.Name] and z.Parent then
			table.insert(out, z)
		end
	end
	return out -- `zones` is already sorted highest tier first
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

-- notifications --------------------------------------------------------------
-- ShowNotification is where the server's real refusal wording lives -- "your carry is
-- full", "you can't take this yet". Those strings are in no client script, so this is
-- the only place the reason is ever put into words, and a message arriving at all is
-- proof the press reached the server.
local lastNote, lastNoteAt = nil, -math.huge

if notifyEvent then
	track(notifyEvent.OnClientEvent:Connect(function(msg)
		if type(msg) == "table" then
			msg = msg.Text or msg.Message or msg.Title or msg[1]
		end
		if type(msg) == "string" and msg ~= "" then
			lastNote, lastNoteAt = msg, os.clock()
		end
	end))
end

-- Only a message that landed inside the window is about the thing we just did.
local function noteSince(t)
	if lastNote and lastNoteAt >= t and (os.clock() - lastNoteAt) <= NOTE_WINDOW then
		return lastNote
	end
	return nil
end

-- carry ----------------------------------------------------------------------
-- HumanoidRootPart.CarryGUI.CarryLimit.Text is "N/M" -- the game's own DropController
-- reads the same label. Knowing the cap is what turns banking from "fire and see if the
-- server refuses" into a decision.
local function parseCarry(text)
	local held, cap = text:match("^%s*(%d+)%s*/%s*(%d+)")
	return tonumber(held), tonumber(cap)
end
assert(select(2, parseCarry("3/5")) == 5, "reads the cap off N/M")
assert(parseCarry("--") == nil, "an unparsed label reads as unknown, not as zero")

-- Returns nil when it could not READ, never 0. Failing open to 0 reads as "empty", which
-- silently inverts every gate built on it.
local function carry()
	local root = hrp()
	local gui = root and root:FindFirstChild("CarryGUI")
	local label = gui and gui:FindFirstChild("CarryLimit")
	if not (label and label:IsA("TextLabel")) then
		return nil
	end
	return parseCarry(label.Text)
end

-- guards ---------------------------------------------------------------------
-- The server sets IsGuardTargetting when a guard locks on -- RunAlert.lua is the game's
-- own client reading exactly this. Death drops your whole carry and offers you a PAID
-- teleport back, so this is the one thing worth being twitchy about. The distance check
-- stays as a backstop for a guard that hasn't targeted yet.
local function guardsFolder()
	-- Looked up per check, never cached: like ItemSpawners, Guards only streams in once
	-- you're standing at a zone.
	return droppers and droppers:FindFirstChild("Guards")
end

local function guardOn()
	if player:GetAttribute("IsGuardTargetting") == true then
		return true, "locked on"
	end
	local root = hrp()
	local folder = root and guardsFolder()
	if not folder then
		return false
	end
	for _, g in ipairs(folder:GetChildren()) do
		if g:IsA("PVInstance") and (g:GetPivot().Position - root.Position).Magnitude <= GUARD_RADIUS then
			return true, "too close"
		end
	end
	return false
end

-- farm -----------------------------------------------------------------------
-- Weak keys: a grabbed item gets destroyed, and this table shouldn't be the one thing
-- keeping it alive. The value is the clock a refused item comes back at.
local tried = setmetatable({}, { __mode = "k" })

local farming = false
local grabbed, banked = 0, 0

-- Executor global; nil in Studio, where we fall back to a real 1s prompt hold.
local fireprompt = fireproximityprompt

-- Looked up per sweep, never cached: ItemSpawners only streams in once you're standing
-- at a zone, so it does not exist when this script first runs.
local function spawnerRoot()
	return (droppers and droppers:FindFirstChild("ItemSpawners")) or zoneRoot:FindFirstChild("ItemSpawners")
end

-- An item wearing a rarity the ladder has never heard of can't be ticked, so it can't be
-- farmed. Said once, in the console, rather than every scan.
local warned = {}
local function noteRarity(rarity)
	if rarity and not rarityRank[rarity] and not warned[rarity] then
		warned[rarity] = true
		warn("[FallForBrainrots] items are spawning with rarity '" .. rarity .. "', which is in no module list")
	end
end

-- Every ticked item in the zone, richest first.
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
	local now, out = os.clock(), {}
	for _, d in ipairs(scope:GetDescendants()) do
		if d:GetAttribute("IsSpawnedItem") then
			local rarity, mutation = d:GetAttribute("Rarity"), mutationOf(d)
			noteRarity(rarity)
			if wantRarity[rarity] and wantMutation[mutation] and (tried[d] or 0) <= now then
				local prompt = d:FindFirstChildWhichIsA("ProximityPrompt", true)
				if prompt and prompt.Enabled then
					table.insert(out, {
						model = d,
						prompt = prompt,
						score = value(d),
						rarity = rarity or "?",
						mutation = mutation,
					})
				end
			end
		end
	end
	table.sort(out, function(a, b)
		return a.score > b.score
	end)
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

-- Returns whether the world changed, and the server's own words if it refused.
local function grab(entry)
	if not hrp() then
		return false
	end
	-- Parked BEFORE the attempt, not after. The sweep now takes the highest-value item
	-- first, so a refusal that un-parks immediately re-picks the same unreachable item on
	-- the very next pass, forever.
	tried[entry.model] = os.clock() + RETRY_AFTER
	if not goTo(entry.model:GetPivot() + Vector3.new(0, HEIGHT_OFFSET, 0)) then
		tried[entry.model] = nil -- never actually attempted (respawn mid-TP)
		return false
	end
	task.wait(SETTLE)
	local fired = os.clock()
	if entry.prompt.Parent then
		pickUp(entry.prompt)
	end
	task.wait(AFTER_GRAB)
	-- A picked-up item gets destroyed. Still parented means the grab didn't take.
	if entry.model.Parent == nil then
		grabbed, banked = grabbed + 1, banked + entry.score
		return true
	end
	return false, noteSince(fired)
end

-- Bank what you're carrying. Deliberately NOT part of grab(): the BASE trip is what
-- unstreams the zone, so it happens once per load rather than once per item.
local function deposit()
	goTo(BASE)
	local held = carry()
	if held == nil then
		task.wait(AT_BASE) -- can't read the label; the old fixed wait is the fallback
		return true
	end
	local deadline = os.clock() + DEPOSIT_TIMEOUT
	while held and held > 0 and os.clock() < deadline do
		task.wait(POLL)
		held = carry()
	end
	if held == 0 then
		return true
	end
	-- Two different failures, and they get fixed in opposite ways.
	if player:GetAttribute("IsInCollectionZone") then
		say("at base but still holding " .. tostring(held) .. " -- BASE may be off the drop-off")
	else
		say("didn't reach the collection zone -- BASE looks wrong")
	end
	return false
end

-- collect --------------------------------------------------------------------
-- Dex path is Plot_<you> > FloorN > Slots > SlotN > CollectTouch, a BasePart with a
-- TouchInterest on it. Matching on the name picks up every floor and every slot the
-- moment it exists -- no per-floor list to maintain.
--
-- Scoped to YOUR plot: every plot on the server has the same pads, and other people's
-- pay you nothing.
local plot, pads = nil, nil
local plotConns = {}

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
		-- Buying a floor adds pads. Drop the cache and let the next sweep rebuild it, so
		-- the steady state costs no plot walk at all.
		local function drop()
			pads = nil
		end
		for _, c in ipairs(plotConns) do
			pcall(function()
				c:Disconnect()
			end)
		end
		plotConns = {
			track(found.DescendantAdded:Connect(drop)),
			track(found.DescendantRemoving:Connect(drop)),
		}
	end
	return found
end

local function plotRoot()
	if not plot or not plot.Parent then
		plot, pads = findPlot(), nil -- plot got rebuilt (rejoin, reset)
	end
	return plot
end

local function collectParts()
	if not plotRoot() then
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

-- Executor global. firetouchinterest reaches the server-side Touched handler WITHOUT
-- moving you, which is the whole reason collecting can run while the farm loop is
-- driving your character somewhere else.
local firetouch = firetouchinterest

-- nil, not 0, when there's nothing to touch WITH -- a missing character isn't the plot's
-- fault and shouldn't print a plot error.
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

-- upgrade --------------------------------------------------------------------
-- RequestSlotMaxUpgrade wants (FloorName, SlotName), and the SurfaceGui carries both as
-- ATTRIBUTES -- the game's own UpgradesController reads them off the same instance, so
-- there's no ancestry to walk and no path to hardcode.
--
-- Only lit buttons get fired at. A slot the server would refuse answers with a banner,
-- and a sweep of 40 refused slots is 40 banners a beat -- gating on the flag the client
-- already maintains costs nothing and skips all of them.
local function upgradeAll(alive)
	if not slotMaxEvent or not plotRoot() then
		return nil
	end
	local n = 0
	for _, d in ipairs(plot:GetDescendants()) do
		if not alive() then
			break
		end
		if d.Name == "UpgradeButtonMax" and d:IsA("GuiObject") and d.Visible then
			local gui = d.Parent
			local floor = gui and gui:GetAttribute("FloorName")
			local slot = gui and gui:GetAttribute("SlotName")
			if floor and slot then
				pcall(function()
					slotMaxEvent:FireServer(floor, slot)
				end)
				n += 1
				task.wait(UPGRADE_GAP)
			end
		end
	end
	return n
end

-- helpers --------------------------------------------------------------------
-- Pure, and deliberately ABOVE the panel fetch: their self-checks are the only tests
-- this file has, and they'd never run if WindUI failed to load and the script returned.

-- WindUI hands a multi-select back as a LIST of names in some builds and as a
-- name -> true MAP in others, and which one you get depends on the library the panel
-- fetched, not on anything here. Reading a map as a list leaves the set empty, and an
-- empty set filters EVERYTHING out -- which is exactly what "the rarity filter does
-- nothing" looks like. Take whichever side of the pair is the string.
local function ticked(values)
	local set = {}
	for k, v in pairs(values or {}) do
		if type(v) == "string" then
			set[v] = true -- list form: 1 -> "Secret"
		elseif type(v) == "table" and type(v.Title) == "string" then
			set[v.Title] = true -- row form: the whole {Title=, Desc=} table comes back
		elseif v then
			set[k] = true -- map form: "Secret" -> true
		end
	end
	return set
end
assert(ticked({ "Secret", "Eternal" }).Eternal, "the list form ticks its names")
assert(ticked({ Secret = true }).Secret, "the map form ticks its keys")
assert(not ticked({ Secret = false }).Secret, "an unticked key in the map form stays off")
assert(ticked({ { Title = "Eternal" } }).Eternal, "the row form ticks its titles")

-- Fill `set` from a callback's values, dropping anything not on the row list. A Refresh
-- re-fires the callback with whatever Value the dropdown still holds -- often "" -- and
-- assigning that would wipe a good selection from a thread we don't control.
local function adopt(set, values, known)
	local picked = ticked(values)
	table.clear(set) -- held live by the loop as an upvalue; replacing the table orphans it
	for name in pairs(picked) do
		if known[name] then
			set[name] = true
		end
	end
end
local probe = { Old = true }
adopt(probe, { "Eternal", "" }, { Eternal = true })
assert(probe.Eternal and not probe.Old and not probe[""], "adopt keeps known picks and drops the rest")

-- In ladder order rather than hash order, so the status line reads the same way twice.
local function summarize(set, all)
	local n, only = 0, nil
	for _, name in ipairs(all) do
		if set[name] then
			n += 1
			only = only or name
		end
	end
	if n == 0 then
		return "none"
	elseif n == 1 then
		return only
	elseif n == #all then
		return "all"
	end
	return n .. " of " .. #all
end
assert(summarize({}, { "A" }) == "none", "an empty tick set says so rather than reading blank")
assert(summarize({ A = true, B = true }, { "A", "B" }) == "all", "everything ticked reads as all")
assert(summarize({ A = true }, { "A", "B", "C" }) == "A", "one ticked names itself")
assert(summarize({ A = true, B = true }, { "A", "B", "C" }) == "2 of 3", "several are counted")

-- Incomes here run to 1e15 and beyond, so a status line needs a suffix or it's a wall.
local function fmt(n)
	for _, step in ipairs({ { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
		if n >= step[1] then
			return string.format("%.1f%s", n / step[1], step[2])
		end
	end
	return string.format("%d", n)
end
assert(fmt(1500) == "1.5K", "thousands get a suffix")
assert(fmt(12) == "12", "small numbers stay literal")
assert(fmt(2.4e9) == "2.4B", "billions pick the right suffix, not the first one over")

-- gui ------------------------------------------------------------------------
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a
-- restyle is one file and not thirty. Fetched here rather than installed by the loader,
-- so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Fall For Brainrots", -- fallback until the live name lands
	folder = "FallForBrainrots", -- unchanged: renaming it orphans configs saved in-game
	size = UDim2.fromOffset(520, 420),
})
if not Window then
	return -- panel.lua already said why
end

-- The farm loop never writes to the panel, it leaves a line here. Executors hand a
-- RESUMED thread back with reduced capability, so the first status write in a loop lands
-- and every one after a task.wait throws "cannot access 'Instance' (lacking capability
-- Plugin)" -- the panel lives in the hidden GUI, which is the part that needs it.
-- Uncaught, that kills the farm thread on its second lap with the toggle stuck ON.
local pending = nil
say = function(msg)
	pending = msg
end

local FarmTab = Window:Tab({ Title = "Farm", Icon = "solar:magnet-bold" })
local PlotTab = Window:Tab({ Title = "Plot", Icon = "solar:buildings-2-bold" })
local BoostTab = Window:Tab({ Title = "Boosts", Icon = "solar:bolt-circle-bold" })

local Target = FarmTab:Section({ Title = "Target", Icon = "solar:filter-bold", Box = true, BoxBorder = true, Opened = true })
local Run = FarmTab:Section({ Title = "Run", Icon = "solar:play-bold", Box = true, BoxBorder = true, Opened = true })

local knownZones = {}
for _, name in ipairs(zoneNames()) do
	knownZones[name] = true
end

local zoneDrop = Target:Dropdown({
	Title = "Zones",
	Desc = "Cycled highest tier first. TELEPORT goes to the highest one ticked.",
	Values = zoneNames(),
	Value = zoneNames()[1] and { zoneNames()[1] } or {},
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		adopt(wantZone, values, knownZones)
	end,
})

local knownRarities, knownMutations = {}, {}
for _, name in ipairs(RARITIES) do
	knownRarities[name] = true
end
for _, name in ipairs(MUTATIONS) do
	knownMutations[name] = true
end

Target:Dropdown({
	Title = "Rarity",
	Desc = "What's eligible. The richest eligible item wins, not the rarest.",
	Values = RARITIES,
	Value = RARITIES,
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		adopt(wantRarity, values, knownRarities)
	end,
})

Target:Dropdown({
	Title = "Mutation",
	Desc = "Listed dullest to shiniest. A mutation multiplies income up to 11x.",
	Values = MUTATIONS,
	Value = MUTATIONS,
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		adopt(wantMutation, values, knownMutations)
	end,
})

Run:Button({
	Title = "Teleport",
	Desc = "To the highest tier zone you've ticked",
	Callback = function()
		local ok, msg = teleport(orderedZones()[1])
		say(msg)
		if not ok then
			warn("[FallForBrainrots] " .. msg)
		end
	end,
})

local line = Run:Paragraph({ Title = "Status", Desc = "idle" })

-- farm loop ------------------------------------------------------------------
-- Every switchable thing registers its setter here, so teardown has one list to turn off
-- instead of naming each loop.
local stoppers = {}

-- One shape for every "do this on a beat while lit" toggle -- collect, upgrade and all
-- three purchases. The FARM doesn't share it: it carries teleports, guards and
-- per-item status that would turn this into a config table for one extra caller.
--   guard/guardMsg  refuse to switch on and say why -- a missing executor global, a
--                   remote that isn't on this server
--   prompt          a RemoteEvent the server pushes when it would rather sell you this
--                   for Robux. The game's own controller turns that into a purchase
--                   dialog, so we switch off instead of stacking one popup a beat.
--   run(alive)      the body. alive() lets a slow sweep bail mid-list.
-- The generation counter lives in THIS closure, one per toggle: a shared one works right
-- up until there are two loops, because every callback bumps it and only the most recent
-- thread survives.
local function everyTick(section, opts)
	local on, gen = false, 0
	local toggle
	-- Flags first, then the switch, then the message. Set(v, false) suppresses the
	-- callback, so the loop has to already be dead when the row goes dark -- and anything
	-- the user needs to read has to be written AFTER the Set, or a re-entered off branch
	-- overwrites the reason with its own line a frame later.
	local function stop(msg)
		on = false
		gen += 1
		pcall(function()
			toggle:Set(false, false)
		end)
		if msg then
			say(msg)
		end
	end
	toggle = section:Toggle({
		Title = opts.Title,
		Desc = opts.Desc,
		Value = false,
		Callback = function(state)
			if state and opts.guard and not opts.guard() then
				stop(opts.Title .. ": " .. opts.guardMsg)
				return
			end
			on = state
			gen += 1
			local mine = gen
			if not on then
				return
			end
			task.spawn(function()
				local function alive()
					return on and gen == mine
				end
				while alive() do
					opts.run(alive)
					task.wait(opts.interval)
				end
			end)
		end,
	})
	if opts.prompt then
		track(opts.prompt.OnClientEvent:Connect(function()
			if on then
				stop(opts.Title .. " off -- the server wants Robux for the next one")
			end
		end))
	end
	table.insert(stoppers, function()
		stop()
	end)
	return toggle
end

-- Run to base and say why. Returns true if we ran, so the caller knows it's no longer at
-- the zone and is carrying nothing.
local function fleeGuard(zone)
	local on, why = guardOn()
	if not on then
		return false
	end
	say(zone.Name .. ": guard " .. why .. " -- bailing")
	deposit()
	return true
end

local function runCycle()
	local order = orderedZones()
	if #order == 0 then
		say("tick at least one zone")
		task.wait(RESCAN)
		return
	end

	local anyGrab = false
	for _, zone in ipairs(order) do
		if not farming then
			break
		end
		-- Grab back to back without leaving, and RE-SCAN between each rather than
		-- trusting a list: the list goes stale the moment anything spawns, and carrying
		-- one across a BASE trip is worse still -- the trip unstreams the zone and
		-- orphans every model in it.
		local got, fails, carried = 0, 0, 0
		-- Go to the zone pivot ONLY on first arrival and after banking. Re-checking
		-- nearCF every pass teleports you back to the pivot after each grab (you're
		-- standing where the item was, usually outside ZONE_RADIUS) and then dwells the
		-- full ZONE_DWELL there -- which is the couple of seconds the guard kills you in.
		local needTrip = true
		while farming and fails < ZONE_STRIKES do
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
				-- A zone we can't stand in is a zone to move on from. Counting this as a
				-- failure means a guard parked on the spawner can't loop us forever.
				carried, needTrip, fails = 0, true, fails + 1
				continue
			end

			say(zone.Name .. ": looking...")
			local entry = waitForItems(zone, dwell)[1]
			if not entry then
				break -- zone is dry; the dwell already gave streaming its chance
			end

			say(
				"going for "
					.. (entry.model:GetAttribute("OriginalName") or "item")
					.. " ("
					.. entry.mutation
					.. " "
					.. entry.rarity
					.. ", "
					.. fmt(entry.score)
					.. ")"
			)
			local took, why = grab(entry)
			if took then
				anyGrab, got, carried, fails = true, got + 1, carried + 1, 0
				-- Holding something is exactly when the guard cares. Check before we
				-- stand here for the next scan.
				if fleeGuard(zone) then
					carried, needTrip = 0, true
				else
					-- The carry label is the honest cap. Banking on it beats banking on a
					-- refusal: a refusal costs a whole grab attempt to discover, and the
					-- attempt is what the guard notices.
					local held, cap = carry()
					if held and cap and held >= cap then
						say(zone.Name .. ": full at " .. held .. "/" .. cap .. " -- banking")
						deposit()
						carried, needTrip = 0, true
					end
				end
			else
				-- Refused. The server's own words beat any guess we'd make here, and a
				-- message arriving at all proves the press reached it. Bank
				-- UNCONDITIONALLY: gating this on carried > 0 deadlocked the loop,
				-- because a deposit that didn't take left carried at 0 while you were
				-- still full, and carried could only rise again via a successful grab
				-- that being full made impossible.
				say(zone.Name .. ": " .. (why or ("refused at " .. carried)) .. " -- banking")
				deposit()
				carried, needTrip, fails = 0, true, fails + 1
			end
		end

		if carried > 0 then
			deposit() -- never leave a zone still holding the load
		end
		say(zone.Name .. (got == 0 and ": nothing -- next zone" or (": got " .. got .. " -- next zone")))
	end

	-- A whole cycle with nothing to show for it: park rather than keep bouncing between
	-- empty zones. Raise IDLE for fewer round trips.
	if farming and not anyGrab then
		goTo(BASE)
		say("nothing anywhere -- idling (" .. grabbed .. " grabbed, " .. fmt(banked) .. " banked)")
		task.wait(IDLE)
	end
end

local farmGen = 0
local farmToggle

local function setFarming(state)
	farming = state
	-- Off-then-on inside one cycle would otherwise leave the sleeping thread alive
	-- alongside the new one, and two runCycles driving one character is worse than two of
	-- anything else here.
	farmGen += 1
	local mine = farmGen
	if not state then
		return
	end
	task.spawn(function()
		while farming and farmGen == mine do
			-- A crash in here used to kill the thread silently, leaving FARM stuck ON
			-- with nothing happening. Now it names the error and switches off cleanly.
			local ok, err = pcall(runCycle)
			if not ok then
				-- Only the current generation may flip the switch: an old thread finishing
				-- must not kill a farm that has since been restarted.
				if farmGen == mine then
					farming = false
					farmGen += 1
					-- Set(v, false) so the off branch doesn't re-fire and overwrite the
					-- reason below with its own "stopped" a frame later.
					pcall(function()
						farmToggle:Set(false, false)
					end)
				end
				warn("[FallForBrainrots] farm cycle failed: " .. tostring(err))
				say("crashed -- see console")
				return
			end
		end
	end)
end

farmToggle = Run:Toggle({
	Title = "Farm",
	Desc = "Score every ticked item in the zone, take the richest, bank when full",
	Value = false,
	Callback = function(state)
		if state and next(wantZone) == nil then
			say("tick at least one zone first")
			pcall(function()
				farmToggle:Set(false, false) -- no re-fire; the reason above must survive
			end)
			return
		end
		if state and next(wantRarity) == nil then
			say("tick at least one rarity first")
			pcall(function()
				farmToggle:Set(false, false)
			end)
			return
		end
		setFarming(state)
		if state then
			-- Don't make you press Teleport first; turning the farm on implies going.
			teleport(orderedZones()[1])
			say("farming " .. summarize(wantRarity, RARITIES) .. " across " .. #orderedZones() .. " zones")
		else
			say("stopped -- " .. grabbed .. " grabbed, " .. fmt(banked) .. " banked")
		end
	end,
})
table.insert(stoppers, function()
	farming = false
	farmGen += 1
	pcall(function()
		farmToggle:Set(false, false)
	end)
end)

-- plot tab -------------------------------------------------------------------
local PlotSec =
	PlotTab:Section({ Title = "Your plot", Icon = "solar:home-2-bold", Box = true, BoxBorder = true, Opened = true })

everyTick(PlotSec, {
	Title = "Auto collect cash",
	Desc = "Touches every CollectTouch pad on your plot. Doesn't move you.",
	interval = COLLECT_EVERY,
	guard = function()
		return firetouch ~= nil
	end,
	guardMsg = "no firetouchinterest -- this executor can't collect",
	run = function()
		local n = collectAll()
		-- Don't stomp the farm's live status with a collect complaint.
		if n == 0 and not farming then
			say("collect: no pads found -- is your plot loaded?")
		end
	end,
})

everyTick(PlotSec, {
	Title = "Auto max-upgrade slots",
	Desc = "RequestSlotMaxUpgrade on every slot whose Max button is lit. Spends cash.",
	interval = UPGRADE_EVERY,
	guard = function()
		return slotMaxEvent ~= nil
	end,
	guardMsg = "RequestSlotMaxUpgrade isn't on this server",
	run = function(alive)
		local n = upgradeAll(alive)
		if n == 0 and not farming then
			say("upgrade: nothing lit -- every slot is maxed or you're short")
		end
	end,
})

-- boosts tab -----------------------------------------------------------------
local BoostSec =
	BoostTab:Section({ Title = "Purchases", Icon = "solar:cart-large-bold", Box = true, BoxBorder = true, Opened = true })

-- A purchase is just everyTick with a one-call body.
local function autoBuy(opts)
	return everyTick(BoostSec, {
		Title = opts.Title,
		Desc = opts.Desc,
		interval = opts.interval,
		prompt = opts.prompt,
		guard = function()
			return opts.fire ~= nil
		end,
		guardMsg = "that event isn't on this server",
		-- pcall: the server rejects most of these (not enough cash, rebirth requirements
		-- unmet). That's the normal case, not an error worth killing the loop and leaving
		-- the toggle lit over.
		run = function()
			pcall(opts.fire)
		end,
	})
end

local speedStep = SPEED_STEPS[#SPEED_STEPS] -- default to the largest
local stepValues = {}
for _, n in ipairs(SPEED_STEPS) do
	stepValues[#stepValues + 1] = "x" .. n
end
BoostSec:Dropdown({
	Title = "Speed step",
	Desc = "What PurchaseSpeed is fired with",
	Values = stepValues,
	Value = "x" .. speedStep,
	Callback = function(v)
		-- Same shape problem as the multi-selects: a single Dropdown hands back the string
		-- in most builds and the whole row table in others. Keep the old step rather than
		-- assigning nonsense if it's neither.
		if type(v) == "table" then
			v = v.Title or v[1]
		end
		speedStep = tonumber(tostring(v):match("%d+")) or speedStep
	end,
})

autoBuy({
	Title = "Auto buy speed",
	Desc = "Cash button only. Fall speed is how fast you get back down.",
	interval = BUY_EVERY,
	prompt = speedPrompt,
	fire = speedEvent and function()
		speedEvent:FireServer(speedStep)
	end,
})

autoBuy({
	Title = "Auto +1 carry",
	Desc = "Cash button only. Fewer trips to base is the biggest lever on the farm.",
	interval = CARRY_EVERY,
	prompt = carryPrompt,
	fire = carryEvent and function()
		carryEvent:FireServer()
	end,
})

autoBuy({
	Title = "Auto rebirth",
	Desc = "The server refuses until you qualify. Leave it on and it goes through.",
	interval = REBIRTH_EVERY,
	fire = rebirthEvent and function()
		rebirthEvent:FireServer()
	end,
})

-- live wiring ----------------------------------------------------------------
-- Drains whatever a loop thread last left. pcall'd anyway: if even this can't write the
-- panel, the run carries on with the status going to the console instead of taking the
-- loop down with it.
local drain
drain = RunService.Heartbeat:Connect(function()
	if pending == nil then
		return
	end
	local msg = pending
	pending = nil
	if not pcall(function()
		line:SetDesc(msg)
	end) then
		print("[FallForBrainrots]", msg)
	end
end)

-- Zones repopulate mid-round. Gated on a signature of the NAMES and debounced, because a
-- repopulate fires one event per zone, and Dropdown:Refresh registers connections WindUI
-- only clears on Destroy -- an ungated rebuild grows for the length of the run, and a
-- dropdown rebuilding under the cursor is unusable.
local lastSig, pendingRebuild = table.concat(zoneNames(), "|"), false

local function rebuildZones()
	zones = collectZones()
	local names = zoneNames()
	local sig = table.concat(names, "|")
	if sig == lastSig then
		return
	end
	lastSig = sig
	knownZones = {}
	for _, name in ipairs(names) do
		knownZones[name] = true
	end
	-- Refresh drops the ticks and re-fires the Callback with whatever Value the dropdown
	-- still holds, so snapshot our own set and put it back afterwards. Select() writes
	-- the ticks and redraws but fires nothing, which is why the set has to be restored
	-- here rather than left to the callback.
	local keep = {}
	for name in pairs(wantZone) do
		if knownZones[name] then
			keep[#keep + 1] = name
		end
	end
	pcall(function()
		zoneDrop:Refresh(names)
		zoneDrop:Select(keep)
	end)
	table.clear(wantZone)
	for _, name in ipairs(keep) do
		wantZone[name] = true
	end
end

local function scheduleRebuild()
	if pendingRebuild then
		return
	end
	pendingRebuild = true
	task.delay(0.3, function()
		pendingRebuild = false
		rebuildZones()
	end)
end
track(zoneRoot.ChildAdded:Connect(scheduleRebuild))
track(zoneRoot.ChildRemoved:Connect(scheduleRebuild))

say(#zoneNames() .. " zones, " .. summarize(wantRarity, RARITIES) .. " rarities")

-- close ----------------------------------------------------------------------
local function stopAll()
	for _, stop in ipairs(stoppers) do
		pcall(stop)
	end
end

-- Only the real teardown drops these: the toggles keep working after a stop, and the
-- status drain is what makes them legible.
local function disconnectAll()
	pcall(function()
		drain:Disconnect()
	end)
	for _, c in ipairs(conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(conns)
end

Window:OnDestroy(function()
	stopAll()
	disconnectAll()
	getgenv().ffbStop = nil
end)

getgenv().ffbStop = function()
	stopAll() -- every loop exits on its own flag, so this really does stop them
	disconnectAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().ffbStop = nil -- or the next paste calls a stop for a destroyed window
end
