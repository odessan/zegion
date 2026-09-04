--[[ Steal a Brainrot Base -- value-first stealing from the NPC bases (103050497819513)

     FARM     : scans every Bases.BaseN.Slots.SlotM for a spawned brainrot, keeps the ones
                wearing a rarity you ticked, and goes for the RICHEST one rather than the
                first one it trips over. Teleports to the base, presses the prompt, carries
                it home, and the item lands in your Backpack. Bases you haven't unlocked
                are skipped unless you turn LOCKED on.
     RARITY   : multi-select over the game's own ladder. Note it is MYTHICAL, not Mythic,
                and Secret ranks BELOW Godly -- that's the game's order, not a typo.
     LUCKY    : the server announces every lucky drop ("A GODLY item spawned at Pot
                Hotspot's Base!"). This reads them, works out which base that is, and sends
                the farm there first. Its own rarity list, so you can farm Rare all day and
                still drop everything for a Godly.
     GUARDS   : each base's guard is simulated on YOUR client -- it chases you and then
                tells the server it caught you. The game sells "Freeze Guards" for Robux;
                this writes the same flag locally, for nothing. Leave it on. It is undone
                when you stop, so the game's own feature still works afterwards.
     CASH     : touches every CollectButton on your plot that has money on it. It never
                moves you, so it keeps paying while the farm is off at a base.
     PLACE    : sorts your Backpack by income and fills your plot bottom floor first, slot
                1 first. With SWAP on it will also evict a placed brainrot that your
                inventory beats -- which hands the weak one back to you, so keep an eye on
                inventory space or use SELL.
     PROBE    : one press, prints to F9 what the farm is about to do and whether it works.
                Run it first in a new server. Everything it prints is what the loop acts on.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().stealBaseStop() ]]

-- config ---------------------------------------------------------------------
-- Prompt reads: ActionText "Steal <name>", E, HoldDuration 0, range 12, and Enabled is
-- parked false on a base you don't own. All three of those gates are enforced by the
-- CLIENT, so all three can be opened -- and out of range there is no press at all, which
-- reads as a refusal rather than a miss.
local REACH = 60 -- MaxActivationDistance we force. Big and finite: math.huge THROWS, and
-- it throws inside the pcall around the press, which is a grab that fails with an empty
-- console. Kept modest so the screen doesn't carpet with E prompts.

-- There is deliberately NO fixed settle before a press. The prompt is server-side, so an
-- early press does nothing -- but the press loop below re-fires on a beat and the confirm
-- (Character.Carrying) is a LOCAL attribute, so the first press the server accepts is
-- noticed the same frame. A fixed sleep can only ever be too long or too short; the retry
-- loop is the settle, and it costs nothing when the server was already ready.
local PRESS_GAP = 0.1 -- between re-fires of the prompt inside one grab window
local ARRIVE = 3 -- seconds to wait for a model's Part/ProximityPrompt to stream in. This,
-- not a stream request, is what covers a target whose parts haven't arrived.
local PAUSE_WAIT = 2 -- cap on waiting out a GameplayPaused after a hop
local ARRIVE_RADIUS = 25 -- studs; further than this from where we aimed means the server
-- reverted the hop, not that we drifted
local GRAB_WINDOW = 2.5 -- how long one press method gets before we try the next one
local SECURE_TIMEOUT = 10 -- give up waiting for Carrying to clear back at the plot
local TOOL_WAIT = 1 -- cap on waiting for the Tool to land after Carrying clears. Polled,
-- not slept: the trace has it arriving on the same tick as the Secured notification.
local IDLE = 1 -- retry beat when nothing is ticked or nothing is spawned. A pass that DID
-- something goes straight round again -- an idle beat between grabs is pure dead time.
local BASE_RADIUS = 300 -- studs; inside this you count as already at the base. Bases are
-- far apart, so this is generous on purpose.
local TP_WAIT = 1.5 -- seconds to give the travel remote before calling it a no-op. A real
-- teleport lands well inside this; 3s just made every failure cost 3s.
local TP_STRIKES = 3 -- hops the server reverted before we stop teleporting ourselves and
-- ask the remote to do it instead
local BASE_STRIKES = 3 -- refusals at one base before it's written off for the session.
-- This is how the script discovers what it can actually reach without being told.
local RETRY_AFTER = 20 -- seconds a refused item is parked for. Not zero: the farm takes
-- the highest-value item first, so un-parking instantly means re-picking the same
-- unreachable thing forever.
local DROP_TTL = 30 -- seconds a lucky drop stays worth chasing. Items despawn and other
-- players are running for the same one.
local NOTE_WINDOW = 4 -- a server notification older than this isn't about the grab we're in
local CONFIRM_GRACE = 0.6 -- the model vanishing and Carrying arriving are two round trips.
-- Reading Carrying on the tick the model disappears makes our own success look like a race
-- we lost, so it gets this long to show up before we call the item gone.

local COLLECT_EVERY = 3 -- seconds between full sweeps of your plot's collect buttons
local TOUCH_GAP = 0.05 -- between touch-begin and touch-end. One gap for the WHOLE sweep,
-- not one per slot: 130 slots would otherwise cost 6.5s of a 3s budget.
local PLACE_EVERY = 5 -- seconds between placement passes; each one moves your character
local PLACE_BATCH = 5 -- placements per pass. One per pass would take eleven minutes to
-- fill a thirteen-floor plot; the whole batch holds the claim, so the farm waits that long.
local WATCHDOG = 20 -- seconds a single step may take before the console says where we are
local PROBE_WINDOW = 2 -- seconds each press method gets during the probe

-- Verbatim from ReplicatedStorage.Modules.NumberFormatter, in ITS order -- the labels we
-- parse are formatted by it, so this is the only table that reads them correctly. Note the
-- lowercase k: "+2.8k/s" and "+2.8M/s" are different numbers.
local SUFFIX_ORDER = { "k", "M", "B", "T", "Qd", "Qn", "Sx", "Sp", "Oc", "No", "De", "Ud" }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().stealBaseStop then
	getgenv().stealBaseStop() -- re-running must not stack a second panel/loop
end

local function log(...)
	print("[steal_base]", ...)
end

local say = function() end -- replaced by the panel below

-- A breadcrumb, because "it stopped and there was nothing in the console" cannot be
-- debugged after the fact. Every slow step names itself here and the watchdog -- a
-- separate thread, because a farm thread parked in a yield can't report anything -- is the
-- one thing still running that knows where we were. Costs two assignments.
local mark, markAt = "idle", os.clock()
local function step(what)
	mark, markAt = what, os.clock()
end

-- Every connection made outside a toggle, so teardown can reach them. Without this they
-- outlive Window:Destroy and keep firing against destroyed rows, one more set per paste.
local conns = {}
local function track(c)
	table.insert(conns, c)
	return c
end

local stoppers = {} -- every loop's "switch yourself off", called by stopAll

-- world ----------------------------------------------------------------------
local events = ReplicatedStorage:WaitForChild("Events", 10)
local basesRoot = workspace:WaitForChild("Bases", 10)
if not (events and basesRoot) then
	warn("[steal_base] ReplicatedStorage.Events or workspace.Bases not found -- wrong game?")
	return
end

local RequestTeleport = events:WaitForChild("RequestTeleport", 5)
local RequestSell = events:WaitForChild("RequestSell", 5)
local ShowNotification = events:WaitForChild("ShowNotification", 5)

local function mod(name)
	local ok, m = pcall(function()
		return require(ReplicatedStorage.Modules[name])
	end)
	return ok and m or nil
end

local baseConf = mod("BaseConfigurations") or {}
local rarityConf = mod("RarityConfigurations") or {}
local itemConf = mod("ItemConfigurations")

-- The ladder, built from the game's own module rather than typed out here: Order is a
-- number on each entry, so a rarity added in a patch shows up in the dropdown for free.
-- Alphabetical would scramble it and hash order isn't stable between runs.
local RARITIES, RANK = {}, {}
do
	for name, cfg in pairs(rarityConf) do
		if type(cfg) == "table" and tonumber(cfg.Order) then
			table.insert(RARITIES, name)
		end
	end
	table.sort(RARITIES, function(a, b)
		return rarityConf[a].Order < rarityConf[b].Order
	end)
	for i, name in ipairs(RARITIES) do
		RANK[name] = i
	end
	if #RARITIES == 0 then -- module wouldn't require; a filter with no options filters everything
		RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical", "Secret", "Godly", "Exclusive", "Celestial", "Divine", "Og", "Eternal" }
		for i, name in ipairs(RARITIES) do
			RANK[name] = i
		end
		warn("[steal_base] RarityConfigurations wouldn't require -- using the dumped ladder")
	end
end

-- NPCName -> BaseN, which is the only way to turn "Pot Hotspot's Base" from a notification
-- into a folder we can scan.
local BASE_OF_NPC, BASE_NAMES = {}, {}
for name, cfg in pairs(baseConf) do
	if type(cfg) == "table" and cfg.NPCName then
		BASE_OF_NPC[cfg.NPCName:upper()] = name
		table.insert(BASE_NAMES, name)
	end
end
table.sort(BASE_NAMES, function(a, b)
	return (tonumber(a:match("%d+")) or 0) < (tonumber(b:match("%d+")) or 0)
end)

local SUFFIX = {}
for i, s in ipairs(SUFFIX_ORDER) do
	SUFFIX[s] = 1000 ^ i
end

-- "+4.5M/s" -> 4500000. The label is server-written with level and mutation already baked
-- in, which is why it beats any arithmetic we could do from ItemConfigurations alone.
local function parseWorth(text)
	if type(text) ~= "string" then
		return nil
	end
	local body = (text:gsub("/s%s*$", ""))
	body = (body:gsub("[%+%$,%s]", ""))
	local num, suf = body:match("^(%-?%d*%.?%d+)(%a*)$")
	if not num then
		return nil
	end
	local mult = suf == "" and 1 or SUFFIX[suf]
	if not mult then
		return nil -- a suffix past our table: better to fall back than to score it as 1x
	end
	return tonumber(num) * mult
end
assert(parseWorth("+4.5M/s") == 4.5e6, "the Earnings label parses with its suffix")
assert(parseWorth("+2.8k/s") == 2800, "lowercase k is thousands, not millions")
assert(parseWorth("+12/s") == 12, "a bare number needs no suffix")
assert(parseWorth("Level 10") == nil, "a label that isn't a number is rejected, not guessed")

-- One scorer for all three shapes: a base's SpawnedItem, a plot slot's VisualItem, and a
-- Backpack Tool all carry the same attributes and the same InfoGUI.
local function score(inst)
	-- Searched from the model, not from a known InfoGUI path: the same template split that
	-- renames Part -> Handle on the high tiers is not something to bet a value read on.
	local label = inst:FindFirstChild("Earnings", true)
	if label and label:IsA("TextLabel") then
		local n = parseWorth(label.Text)
		if n and n > 0 then
			return n
		end
	end
	local items = itemConf and itemConf.Items
	local data = items and items[inst:GetAttribute("OriginalName") or inst.Name]
	return data and tonumber(data.Income) or 0
end

local function hrp()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function carrying()
	local char = player.Character
	return char ~= nil and char:GetAttribute("Carrying") == true
end

-- Nil for a few frames around a respawn, and every count taken off it would read 0 and
-- look like an empty bag.
local function backpack()
	return player:FindFirstChildOfClass("Backpack")
end

local function unlocked(base)
	return player:GetAttribute(base .. "_Unlocked") == true
end

local function numOf(name)
	return tonumber(name:match("(%d+)%s*$")) or math.huge
end
assert(numOf("Slot10") == 10, "a trailing number is the sort key")
assert(numOf("Floor1") == 1, "single digits sort as numbers, not strings")

-- Slot -> the prompt that steals from it. Deliberately tolerant: a far model replicates as
-- a Model with its attributes and pivot and nothing else, so the Part and the prompt may
-- not exist yet. That's the grab's problem, not the scan's.
-- Recursive, and NOT via a child named "Part". The normal brainrots hang their prompt on a
-- MeshPart called Part, but the Exclusive-and-up templates are built from Roblox tool
-- assets and theirs is called "Handle" -- or, for Evil Piggini, "Meshes/PİGGY_Sphere.002".
-- Waiting on "Part" made every Exclusive time out as "not streamed yet", which parked it for
-- two seconds and then picked it again, because Exclusive outranks everything below it: a
-- silent livelock with nothing in the console. The prompt is the thing we want, so look for
-- the prompt.
local function promptOf(model)
	return model:FindFirstChildWhichIsA("ProximityPrompt", true)
end

-- Same shape rule, with a deadline: a model that has only just replicated arrives with its
-- attributes and pivot and none of its parts, so the prompt shows up a moment later.
local function waitForPrompt(model, seconds)
	local deadline = os.clock() + seconds
	repeat
		local prompt = promptOf(model)
		if prompt then
			return prompt
		end
		task.wait()
	until os.clock() > deadline or not model.Parent
	return nil
end

-- The prompt carries the base it belongs to, and BaseController's own gate is built on it.
-- Cheap integrity check: if it names a different base than the folder we walked, the tree
-- moved under us and pressing it would be a guess.
local function promptBase(prompt)
	return prompt:GetAttribute("RequiredBase")
end

local function open(prompt)
	-- ponytail: never restored. Opening it only ever helps us, the model is destroyed on a
	-- successful steal, and a refused prompt left at REACH costs nothing but a visible E.
	pcall(function()
		prompt.Enabled = true
		prompt.RequiresLineOfSight = false
		prompt.MaxActivationDistance = REACH
	end)
end

-- Bases.BaseN.Lasers bounce you off a base you don't own -- but that is a CLIENT Touched
-- handler gated on `part.Transparency == 0`, so making them invisible locally is the whole
-- bypass. Kept in a list because a muted client feature has to be restored on stop.
local lasered = {}
local function openLasers(base)
	local folder = basesRoot:FindFirstChild(base)
	folder = folder and folder:FindFirstChild("Lasers")
	if not folder then
		return
	end
	for _, part in ipairs(folder:GetDescendants()) do
		if part:IsA("BasePart") and part.Transparency == 0 then
			table.insert(lasered, { part = part, t = part.Transparency, c = part.CanCollide })
			part.Transparency = 1
			part.CanCollide = false
		end
	end
end
local function restoreLasers()
	for _, row in ipairs(lasered) do
		pcall(function()
			row.part.Transparency = row.t
			row.part.CanCollide = row.c
		end)
	end
	table.clear(lasered)
end

-- Refusals, keyed by the model so a despawn drops the entry on its own. Weak keys are the
-- whole mechanism -- a strong table here would pin every brainrot we ever failed at.
local parked = setmetatable({}, { __mode = "k" })
-- Consecutive "couldn't even try" results per model. A short park is right for a target
-- that is genuinely still streaming, and catastrophic for one we can never reach: it comes
-- straight back to the top of the sort and blocks everything under it, forever, in silence.
-- That is exactly what a hardcoded child name did to every Exclusive. Three in a row and it
-- gets the full refusal park and says so once.
local misses = setmetatable({}, { __mode = "k" })
local MISS_STRIKES = 3
local strikes = {} -- base -> refusals; BASE_STRIKES of them writes it off for the session

local wanted = {} -- rarity -> true, read live by the sweep (held as an upvalue: clear it,
-- never replace it, or the loop keeps reading the copy nobody ticks any more)
local dropWanted = {}
local sortMode = "rarity" -- "rarity" (rank then value) or "value" (value only)
local allowLocked = false

-- Every spawned brainrot worth going for, richest first. `only` restricts it to one base,
-- which is how a lucky drop jumps the queue.
local function scan(only)
	local out, now = {}, os.clock()
	for _, folder in ipairs(basesRoot:GetChildren()) do
		local base = folder.Name
		local skip = (only and base ~= only)
			or not baseConf[base]
			or (strikes[base] or 0) >= BASE_STRIKES
			or not (unlocked(base) or allowLocked)
		if not skip then
			local slots = folder:FindFirstChild("Slots")
			for _, slot in ipairs(slots and slots:GetChildren() or {}) do
				local spawn = slot:FindFirstChild("Spawn")
				local model = spawn and spawn:FindFirstChild("SpawnedItem")
				local rarity = model and model:GetAttribute("Rarity")
				if rarity and wanted[rarity] and (parked[model] or 0) < now then
					table.insert(out, {
						base = base,
						slot = slot.Name,
						model = model,
						rarity = rarity,
						rank = RANK[rarity] or 0,
						worth = score(model),
					})
				end
			end
		end
	end
	table.sort(out, function(a, b)
		if sortMode == "rarity" and a.rank ~= b.rank then
			return a.rank > b.rank
		end
		if a.worth ~= b.worth then
			return a.worth > b.worth
		end
		return a.base < b.base
	end)
	return out
end

-- travel ---------------------------------------------------------------------
local tpStrikes = 0

-- The bare hop, and the fast path -- a CFrame write is instant.
--
-- There is deliberately no RequestStreamAroundAsync in front of it. Everything this script
-- hops to was found by WALKING the tree (a SpawnedItem under Bases, a slot under our own
-- plot), which means it is already replicated by definition -- so the request can only
-- fetch what we have. It YIELDS, and neither pcall nor its own timeOut argument reliably
-- bounds that yield, so it was costing up to two seconds per grab for nothing. What a
-- far target actually needs is the WaitForChild on its Part, which the grab already does
-- on its own budget.
--
-- ponytail: if a future target is ever found by name rather than by walking, that one gets
-- its own requesting variant -- don't put the yield back on this path.
--
-- Returns whether we ACTUALLY got there: a server that reverts the write leaves every later
-- step behaving as though we arrived, which is how a run spends its life pressing a prompt
-- from three hundred studs away and calling it a refusal.
-- true arrived / false the server reverted us / nil there was no character to move. The
-- third answer matters: a respawn counted as a revert would eventually convince travel()
-- that this game snap-backs and retire the fast path over nothing.
local function hop(cf)
	local root = hrp()
	if not root then
		return nil
	end
	root.CFrame = cf
	local deadline = os.clock() + PAUSE_WAIT
	while player.GameplayPaused and os.clock() < deadline do
		task.wait() -- the streaming pause: you landed somewhere the client hasn't got yet
	end
	root = hrp() -- may have respawned while paused
	if not root then
		return nil
	end
	return (root.Position - cf.Position).Magnitude <= ARRIVE_RADIUS
end

-- The game's own travel, which every teleport prompt in the base uses. Free, server-side,
-- and immune to the snap-back a raw CFrame write can earn -- so it is the FALLBACK, and it
-- is never retired: tpStrikes retires the hop, and this is what the hop falls back to.
local function serverTo(where, arg)
	if not RequestTeleport then
		return false
	end
	local before = hrp()
	before = before and before.Position
	pcall(function()
		RequestTeleport:FireServer(where, arg)
	end)
	local deadline = os.clock() + TP_WAIT
	repeat
		task.wait() -- per frame, so a teleport that lands in 200ms costs 200ms
		local now = hrp()
		if before and now and (now.Position - before).Magnitude > 50 then
			return true
		end
	until os.clock() > deadline
	return false
end

-- Hop there ourselves and only ask the server if it reverted us. That order round --
-- fast path first -- is what makes a cycle one round trip instead of three, and it is
-- justified by the press loop below: it rewrites the root CFrame every beat and the grabs
-- land, which is proof the server accepts our writes in this game.
--
-- Reverts are counted rather than assumed either way: TP_STRIKES of them and we stop
-- trying the fast path at all, which is the behaviour a server that snap-backs needs.
local function travel(cf, where, arg)
	if tpStrikes < TP_STRIKES then
		local landed = hop(cf)
		if landed then
			return true
		end
		if landed == nil then
			return false -- no character; not the server's fault, so no strike
		end
		tpStrikes += 1
		if tpStrikes == TP_STRIKES then
			log(("the server reverted %d hops -- using RequestTeleport from here on"):format(TP_STRIKES))
		end
	end
	if not serverTo(where, arg) then
		return false
	end
	-- The remote drops us at the base's own spawn, not on the slot, so try to close the gap
	-- -- but a failure there is not a failure to travel. We are in the right place, and the
	-- prompt is opened to REACH studs, so the grab is worth attempting: it reports honestly
	-- if it turns out we're still too far.
	hop(cf)
	return true
end

local function atBase(base)
	local folder = basesRoot:FindFirstChild(base)
	local anchor = folder and (folder:FindFirstChild("Spawn") or folder.PrimaryPart)
	local root = hrp()
	if not (anchor and root) then
		return false
	end
	return (root.Position - anchor.Position).Magnitude <= BASE_RADIUS
end

local function myPlot()
	local direct = workspace:FindFirstChild("Plot_" .. player.Name)
	if direct then
		return direct
	end
	-- Fallback for a renamed plot: the game stamps a PlotOwner on each one. Scanned rather
	-- than assumed, because a plot found by name is the only thing the rest of this reads.
	for _, child in ipairs(workspace:GetChildren()) do
		if child.Name:match("^Plot_") then
			local owner = child:FindFirstChild("PlotOwner")
			local val = owner and (owner.Value or owner:GetAttribute("Owner"))
			if val == player or val == player.Name or val == player.UserId then
				return child
			end
		end
	end
	return nil
end

local function goHome()
	local plot = myPlot()
	local spawn = plot and plot:FindFirstChild("Spawn")
	if spawn and spawn:IsA("BasePart") then
		-- Our own plot spawn is a part we walked to, so the hop is instant and the remote
		-- is the fallback -- the same order as travel(), for the same reason.
		return travel(spawn.CFrame + Vector3.new(0, 4, 0), "ToPlot")
	end
	return serverTo("ToPlot")
end

-- notify ---------------------------------------------------------------------
-- The game's notification remote is the only place the server's real reason is ever
-- worded, and it is also the grab confirm ("Stole X!") and the deposit confirm
-- ("X Secured!"). Mirrored into an upvalue rather than polled.
local lastNote = { text = "", kind = "", at = 0 }
local drops = {} -- { base =, rarity =, expires = }, drained by the farm before its own scan
local lastDrop = "none yet"

local function noteSince(t, kind)
	if lastNote.at > t and (kind == nil or lastNote.kind == kind) then
		return lastNote.text
	end
	return nil
end

local DROP_PATTERN = "^LUCKY DROP! A (%u+) item spawned at (.+)'s Base!$"

-- Returns the base and the ladder-cased rarity, or nil. Pure, so it gets a self-check.
local function dropFrom(text)
	if type(text) ~= "string" then
		return nil
	end
	local shout, npc = text:match(DROP_PATTERN)
	if not (shout and npc) then
		return nil
	end
	local base = BASE_OF_NPC[npc:upper()]
	if not base then
		return nil
	end
	for _, name in ipairs(RARITIES) do
		-- The shout is upper-cased and the display name may be too ("GODLY", "OG"), so
		-- match on the ladder key rather than on RarityConfigurations.DisplayName.
		if name:upper() == shout then
			return base, name
		end
	end
	return nil
end

local detectDrops, stealDrops = false, false

if ShowNotification then
	track(ShowNotification.OnClientEvent:Connect(function(text, kind)
		lastNote = { text = tostring(text), kind = tostring(kind), at = os.clock() }
		if not detectDrops then
			return
		end
		local base, rarity = dropFrom(text)
		if not base then
			return
		end
		lastDrop = rarity .. " @ " .. base
		if stealDrops and dropWanted[rarity] then
			table.insert(drops, { base = base, rarity = rarity, expires = os.clock() + DROP_TTL })
			strikes[base] = nil -- a fresh drop is worth re-trying a base we'd written off
			say("lucky drop: " .. lastDrop)
			log("lucky drop -> " .. lastDrop)
		end
	end))
else
	warn("[steal_base] Events.ShowNotification missing -- no lucky drops, and grabs confirm on Carrying alone")
end

local function nextDrop()
	local now = os.clock()
	while #drops > 0 do
		local d = table.remove(drops, 1)
		if d.expires > now then
			return d.base
		end
	end
	return nil
end

-- guards ---------------------------------------------------------------------
-- ClientNPCController simulates every base guard on OUR client: it chases, it catches, and
-- then it reports us with NPCInteraction:FireServer("PlayerCaught", ...). Its whole update
-- body is short-circuited by this one attribute -- which the game sells as a Robux
-- product. Attributes written on the client stay on the client, so writing it is free.
local freeze = false
local freezeConn, freezeChar = nil, nil

local function assertFreeze()
	if freeze then
		pcall(function()
			player:SetAttribute("FreezeGuardsActive", true)
		end)
	end
end

local function setFreeze(on)
	freeze = on
	if on then
		assertFreeze()
		-- The server owns this attribute too (it's what the product sets), so a write from
		-- its side would otherwise switch the guards back on mid-carry.
		freezeConn = freezeConn
			or player:GetAttributeChangedSignal("FreezeGuardsActive"):Connect(function()
				if freeze and player:GetAttribute("FreezeGuardsActive") ~= true then
					assertFreeze()
				end
			end)
		freezeChar = freezeChar or player.CharacterAdded:Connect(function()
			task.wait(0.5)
			assertFreeze()
		end)
	else
		-- Restored, not just abandoned: leaving it set keeps the game's own guards broken
		-- for the rest of the session, including for a player who then stops the script.
		pcall(function()
			player:SetAttribute("FreezeGuardsActive", nil)
		end)
	end
end
table.insert(stoppers, function()
	setFreeze(false)
	if freezeConn then
		freezeConn:Disconnect()
		freezeConn = nil
	end
	if freezeChar then
		freezeChar:Disconnect()
		freezeChar = nil
	end
	restoreLasers()
end)

-- farm -----------------------------------------------------------------------
local busy = false

-- Two loops that both drive the character will teleport each other mid-prompt and both
-- time out. Returns whether it RAN, not whether it succeeded, and releases on every path
-- including a throw. Anything that doesn't move you must NOT take this.
local function claim(fn)
	if busy then
		return false
	end
	busy = true
	local ok, err = pcall(fn)
	busy = false
	if not ok then
		warn("[steal_base]", err)
	end
	return true
end

local hasFPP = type(fireproximityprompt) == "function"
local hasVIM = pcall(function()
	return game:GetService("VirtualInputManager")
end)
local vim = hasVIM and game:GetService("VirtualInputManager") or nil

-- Three ways to press E and they are NOT equivalent, so all three are kept and the winner
-- is remembered for the session.
--   fireproximityprompt : triggers the prompt server-side. Fastest, and correct here --
--                         the server is what listens to Triggered on these.
--   InputHoldBegin      : plain Roblox API down the real input path, so the client's own
--                         Triggered fires too. Needs you genuinely in range, which is
--                         what open() just saw to.
--   VirtualInputManager : an actual key press. Slowest, wants focus, and the only one the
--                         game cannot tell from your hands.
local METHODS = {
	{
		name = "fireproximityprompt",
		ok = hasFPP,
		run = function(prompt)
			pcall(fireproximityprompt, prompt)
		end,
	},
	{
		name = "InputHoldBegin",
		ok = true,
		run = function(prompt)
			pcall(function()
				prompt:InputHoldBegin()
				task.wait(prompt.HoldDuration + 0.1)
				if prompt.Parent then
					prompt:InputHoldEnd()
				end
			end)
		end,
	},
	{
		name = "VirtualInputManager",
		ok = hasVIM,
		run = function(prompt)
			local key = prompt.KeyboardKeyCode
			pcall(function()
				vim:SendKeyEvent(true, key, false, game)
				task.wait(0.15)
				vim:SendKeyEvent(false, key, false, game)
			end)
		end,
	},
}
local winner = nil -- index into METHODS, once one of them has actually worked

-- The winner alone once we have one, otherwise all of them in order. Built rather than
-- written out, so adding a fourth method doesn't leave it unreachable.
local function pressOrder()
	if winner then
		return { winner }
	end
	local all = {}
	for i = 1, #METHODS do
		all[i] = i
	end
	return all
end

-- true  the server gave it to us (Carrying went true)
-- false fired for the whole window and it didn't -- a refusal, count it
-- nil   nothing to fire at, i.e. the prompt never streamed in -- do NOT count it.
--       Conflating those last two makes a streaming hiccup read as a hard refusal and
--       writes off a base that was fine.
local function grab(target, alive)
	local model = target.model
	if not (model and model.Parent) then
		return nil
	end

	-- Aim twice. A model this far out replicates with its pivot and nothing else, so the
	-- first hop can only target the bare model; the parts arrive once we're standing there.
	local pivot = model:GetPivot()
	if pivot.Position.Magnitude <= 1 then
		return nil -- a Model with no parts reports the origin: not replicated yet
	end
	step("grab " .. target.base .. "/" .. target.slot .. " / hop")
	if not travel(pivot + Vector3.new(0, 4, 0), "ToBase", target.base) then
		return nil
	end

	local prompt = waitForPrompt(model, ARRIVE)
	if not prompt then
		return nil -- streaming, not a refusal
	end
	local owns = promptBase(prompt)
	if owns and owns ~= target.base then
		log(("prompt at %s/%s says RequiredBase=%s -- skipping it"):format(target.base, target.slot, owns))
		return nil
	end
	open(prompt)

	-- Re-aim at the part the prompt actually hangs off, now that it exists. The model pivot
	-- was the best we had from a distance, but on a rig-shaped model (the Exclusive tiers
	-- are built from tool assets) the pivot can sit well away from the prompt, and the
	-- prompt's own parent is exactly what the range check measures from.
	local anchor = prompt:FindFirstAncestorWhichIsA("BasePart")
	if anchor then
		pivot = anchor.CFrame
	end

	-- The model leaving is NOT the confirm here: every slot carries a respawn Timer, so an
	-- expiry and a successful steal look identical from the folder's side. Give Carrying the
	-- grace window to arrive, then call it gone -- gone is `nil`, not a refusal, because
	-- striking a base for someone else's grab is how a fine base gets written off.
	local function gone()
		local deadline = os.clock() + CONFIRM_GRACE
		repeat
			if carrying() then
				return false
			end
			task.wait(0.05)
		until os.clock() > deadline
		return true
	end

	for _, i in ipairs(pressOrder()) do
		local method = METHODS[i]
		if method and method.ok then
			step("grab " .. target.base .. "/" .. target.slot .. " / press " .. method.name)
			local deadline = os.clock() + GRAB_WINDOW
			local nextPress = 0 -- 0, so the first press happens immediately rather than
			-- after a fixed settle: the server may already have seen us arrive.
			repeat
				if not (model.Parent and prompt.Parent) then
					if gone() then
						return nil -- despawned, or another player beat us to it
					end
					winner = winner or i
					return true
				end
				-- Hold position through the press: one hop drifts and the range check
				-- starts failing mid-window. Pinned to the spot read BEFORE the loop --
				-- re-reading the live pivot is a rocket once the item is on your shoulders.
				local root = hrp()
				if root then
					root.CFrame = pivot + Vector3.new(0, 4, 0)
				end
				if os.clock() >= nextPress then
					nextPress = os.clock() + PRESS_GAP
					method.run(prompt)
				end
				if carrying() then
					if winner ~= i then
						winner = i
						log("press method: " .. method.name)
					end
					return true
				end
				-- Per frame. Carrying is a local attribute, so this is the difference
				-- between noticing a success in 16ms and noticing it in 100ms -- on every
				-- grab, forever. The press rate is paced separately by PRESS_GAP.
				task.wait()
			until os.clock() > deadline or not alive()
			if not alive() then
				return nil
			end
		end
	end

	local why = noteSince(os.clock() - NOTE_WINDOW, "Error")
	if why then
		log("refused at " .. target.base .. "/" .. target.slot .. ": " .. why)
	end
	return false
end

-- Carrying clears when the server takes the item off you, and the Tool lands in the
-- Backpack on the same tick. Waiting for BOTH is what tells a secure apart from a guard.
local function secure(alive)
	step("secure / travel")
	local bag = backpack()
	local before = bag and #bag:GetChildren() or 0
	goHome()
	local deadline = os.clock() + SECURE_TIMEOUT
	local reissue = os.clock() + SECURE_TIMEOUT / 2
	step("secure / wait")
	repeat
		task.wait() -- per frame; Carrying clearing is the one thing we're here for
		if not carrying() then
			-- Polled rather than slept. The trace has the Tool arriving on the same tick as
			-- the Secured notification, so this almost always returns on the first frame --
			-- but it is a separate round trip from Carrying clearing, so it needs a window.
			local until_ = os.clock() + TOOL_WAIT
			repeat
				bag = backpack()
				if bag and #bag:GetChildren() > before then
					return true, noteSince(os.clock() - NOTE_WINDOW)
				end
				task.wait()
			until os.clock() > until_
			-- Carrying cleared with nothing to show for it: a guard, or a full inventory.
			return false, noteSince(os.clock() - NOTE_WINDOW) or "carrying cleared but nothing arrived"
		end
		-- Re-issued once, because a respawn or a stream-out silently drops us elsewhere.
		if os.clock() > reissue then
			reissue = math.huge
			goHome()
		end
	until os.clock() > deadline or not alive()
	return false, "still carrying after " .. SECURE_TIMEOUT .. "s"
end

local farming, farmGen = false, 0
local farmToggle

-- One pass. Returns a status line, or nil to keep going quietly.
local function farmPass(alive)
	if carrying() then
		step("secure (already carrying)")
		local ok, why = secure(alive)
		return ok and "secured" or ("lost it: " .. tostring(why))
	end

	local only = nextDrop()
	local list = scan(only)
	if #list == 0 and only then
		list = scan(nil) -- the drop hasn't streamed, or someone else got there first
	end
	if #list == 0 then
		return next(wanted) == nil and "tick a rarity" or "nothing ticked is spawned"
	end

	local target = list[1]
	-- Read before the grab: a successful steal destroys the model, and building the status
	-- line off a dead instance is a throw in the one place we're reporting success.
	local itemName = target.model:GetAttribute("OriginalName") or "?"
	step("go " .. target.base .. "/" .. target.slot)
	-- No travel here: grab() hops straight onto the slot, which lands us inside the base
	-- anyway. Going to the base spawn first and then to the slot was two teleports for one
	-- destination. The lasers still have to be opened before we arrive, though.
	if allowLocked and not unlocked(target.base) and not atBase(target.base) then
		openLasers(target.base)
	end

	local got = grab(target, alive)
	if got == nil then
		local n = (misses[target.model] or 0) + 1
		misses[target.model] = n
		if n >= MISS_STRIKES then
			parked[target.model] = os.clock() + RETRY_AFTER
			log(("couldn't reach %s %s at %s/%s after %d tries -- parking it for %ds"):format(
				target.rarity,
				itemName,
				target.base,
				target.slot,
				n,
				RETRY_AFTER
			))
		else
			parked[target.model] = os.clock() + 2 -- streaming; worth another look shortly
		end
		return nil
	end
	if got == false then
		parked[target.model] = os.clock() + RETRY_AFTER
		strikes[target.base] = (strikes[target.base] or 0) + 1
		if strikes[target.base] >= BASE_STRIKES then
			log(target.base .. " refused " .. BASE_STRIKES .. "x -- skipping it this session")
		end
		return "refused at " .. target.base
	end

	strikes[target.base] = nil
	misses[target.model] = nil -- consecutive, so one success clears the count
	local ok, why = secure(alive)
	if ok then
		return ("got %s %s (%s)"):format(target.rarity, itemName, why or "secured")
	end
	return "lost it: " .. tostring(why)
end

local function setFarming(on)
	farming = on
	farmGen += 1
	local mine = farmGen
	if not on then
		return
	end

	-- Its own thread, and that is the entire point: if the farm thread is parked in a
	-- yield it cannot report anything, and everything goes quiet at once. This one is
	-- still running and it knows the last step that started.
	task.spawn(function()
		while farming and farmGen == mine do
			task.wait(WATCHDOG)
			if farming and farmGen == mine and os.clock() - markAt > WATCHDOG then
				log(("stuck %.0fs at: %s"):format(os.clock() - markAt, mark))
			end
		end
	end)

	task.spawn(function()
		local alive = function()
			return farming and farmGen == mine
		end
		-- Passes in a row that never got the claim at all. Placement legitimately holds it
		-- for a batch of teleports, so a handful of misses is normal -- but a claim that is
		-- never released again is a jam, and spinning silently on it is exactly the "it
		-- stopped and there was nothing in the console" this whole file is built to avoid.
		local starved = 0
		while alive() do
			local worked = false
			local ran = claim(function()
				local msg = farmPass(alive)
				worked = msg == nil or not (msg == "tick a rarity" or msg == "nothing ticked is spawned")
				if msg then
					say(msg)
				end
			end)
			if ran then
				starved = 0
				-- A pass that actually did something goes straight round again: an idle beat
				-- between grabs is dead time on every single item. IDLE is only for a pass
				-- that found nothing, where spinning per frame would be a busy loop.
				if worked then
					task.wait()
				else
					task.wait(IDLE)
				end
			else
				starved += 1
				if starved > 200 then -- ~60s of never getting a turn
					say("never got the character -- see console (F9)")
					log("starved for 200 passes; last step was: " .. mark)
					break
				end
				task.wait(0.3)
			end
		end
		-- Only the current generation may flip the switch, or an old thread finishing kills
		-- a farm that has since been restarted.
		if farmGen == mine and farming then
			farming = false
			pcall(function()
				farmToggle:Set(false)
			end)
		end
	end)
end
table.insert(stoppers, function()
	setFarming(false)
end)

-- cash -----------------------------------------------------------------------
-- Every slot with money on it, in one batch: fire every begin, wait ONE gap, fire every
-- end. Takes no claim, so it keeps paying out while the farm is a thousand studs away.
--
-- Events.RequestCollectAll exists and would do this in one call, but SlotController gates
-- it on Pass_CollectAll and the server answers a player without the pass with a Robux
-- prompt -- on a loop that reopens the dialog forever. Deliberately not wired.
local function collectPass()
	local root = hrp()
	local plot = myPlot()
	if not (root and plot) then
		return "no plot"
	end
	local pads, cash = {}, 0
	for _, floor in ipairs(plot:GetChildren()) do
		if floor.Name:match("^Floor%d+$") then
			local slots = floor:FindFirstChild("Slots")
			for _, slot in ipairs(slots and slots:GetChildren() or {}) do
				local amount = tonumber(slot:GetAttribute("StoredAmount")) or 0
				local button = slot:FindFirstChild("CollectButton")
				local touch = button and button:FindFirstChild("Touch")
				if amount > 0 and touch and touch:IsA("BasePart") then
					table.insert(pads, touch)
					cash += amount
				end
			end
		end
	end
	if #pads == 0 then
		return "nothing to collect"
	end
	for _, pad in ipairs(pads) do
		pcall(firetouchinterest, root, pad, true)
	end
	task.wait(TOUCH_GAP)
	for _, pad in ipairs(pads) do
		pcall(firetouchinterest, root, pad, false)
	end
	return ("collected %d slot%s"):format(#pads, #pads == 1 and "" or "s")
end

-- place ----------------------------------------------------------------------
-- Backpack Tools carry the same attributes as anything else, so score() reads them too.
-- IsTemporary items are the game's own loaners and are not worth a slot.
local function inventory()
	local out = {}
	local bag = backpack()
	for _, tool in ipairs(bag and bag:GetChildren() or {}) do
		if tool:IsA("Tool") and tool:GetAttribute("Rarity") and tool:GetAttribute("IsTemporary") ~= true then
			table.insert(out, { tool = tool, worth = score(tool) })
		end
	end
	table.sort(out, function(a, b)
		return a.worth > b.worth
	end)
	return out
end

-- Bottom floor first, slot 1 first -- the placement order the plot pays out in.
local function slotsInOrder()
	local plot = myPlot()
	if not plot then
		return {}
	end
	local floors = {}
	for _, floor in ipairs(plot:GetChildren()) do
		if floor.Name:match("^Floor%d+$") and (floor.Name == "Floor1" or player:GetAttribute(floor.Name .. "_Unlocked") == true) then
			table.insert(floors, floor)
		end
	end
	table.sort(floors, function(a, b)
		return numOf(a.Name) < numOf(b.Name)
	end)

	local out = {}
	for _, floor in ipairs(floors) do
		local slots = {}
		for _, slot in ipairs(floor:FindFirstChild("Slots") and floor.Slots:GetChildren() or {}) do
			if slot:IsA("Model") and slot:GetAttribute("IsUnlocked") ~= false then
				table.insert(slots, slot)
			end
		end
		table.sort(slots, function(a, b)
			return numOf(a.Name) < numOf(b.Name)
		end)
		for _, slot in ipairs(slots) do
			local spawn = slot:FindFirstChild("Spawn")
			if spawn and spawn:IsA("BasePart") then
				local held = spawn:FindFirstChild("VisualItem")
				table.insert(out, {
					slot = slot,
					spawn = spawn,
					occupied = spawn:GetAttribute("IsOccupied") == true,
					worth = held and score(held) or 0,
				})
			end
		end
	end
	return out
end

-- The server acts on what you HOLD -- the slot prompt ignores arguments and takes whatever
-- Tool is equipped. EquipTool puts away whatever is held first, so a swap is one call.
local function placeInto(entry, tool)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return false, "no character"
	end
	pcall(function()
		hum:EquipTool(tool)
	end)
	local prompt = entry.spawn:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		return false, "slot has no prompt"
	end
	open(prompt)
	if not hop(entry.spawn.CFrame + Vector3.new(0, 4, 0)) then
		return false, "couldn't reach the slot"
	end

	local name = tool.Name
	local deadline = os.clock() + GRAB_WINDOW
	local order = pressOrder()
	local nextPress = 0 -- press on arrival, not after a settle
	repeat
		if os.clock() >= nextPress then
			nextPress = os.clock() + PRESS_GAP
			for _, i in ipairs(order) do
				local method = METHODS[i]
				if method and method.ok and prompt.Parent then
					method.run(prompt)
				end
			end
		end
		task.wait()
		-- Both halves: the slot filling AND the Tool leaving us. Either one alone can be a
		-- swap in progress rather than a placement that landed.
		if entry.spawn:GetAttribute("IsOccupied") == true and not (tool.Parent == backpack() or tool.Parent == player.Character) then
			return true, name
		end
	until os.clock() > deadline
	return false, noteSince(os.clock() - NOTE_WINDOW, "Error") or "prompt didn't take"
end

local swapWeaker = true

local function placePass()
	local inv = inventory()
	if #inv == 0 then
		return "inventory empty"
	end
	local slots = slotsInOrder()
	if #slots == 0 then
		return "no plot slots"
	end

	-- Pass 1: fill the empties, best item into the earliest slot, up to PLACE_BATCH of them
	-- while we hold the claim. A failure ends the batch rather than grinding through the
	-- whole plot against whatever is wrong.
	local done, failed = 0, nil
	for _, entry in ipairs(slots) do
		if done >= PLACE_BATCH or #inv == 0 then
			break
		end
		if not entry.occupied then
			local pick = table.remove(inv, 1)
			step("place " .. pick.tool.Name)
			local ok, why = placeInto(entry, pick.tool)
			if not ok then
				failed = why
				break
			end
			done += 1
		end
	end
	if failed then
		return ("placed %d, then: %s"):format(done, tostring(failed))
	end
	if done > 0 then
		return ("placed %d"):format(done)
	end

	if not swapWeaker then
		return "plot full"
	end

	-- Pass 2: swap up. One press does pick-up-and-place ("Pick Up / Swap"), so the weak one
	-- comes back to us as a Tool. Terminates the moment nothing in the bag wins.
	local weakest, weakAt = nil, nil
	for _, entry in ipairs(slots) do
		if entry.occupied and (weakest == nil or entry.worth < weakest) then
			weakest, weakAt = entry.worth, entry
		end
	end
	if not (weakAt and inv[1] and inv[1].worth > weakest) then
		return "plot full, nothing better in the bag"
	end
	step("swap " .. inv[1].tool.Name)
	local ok, why = placeInto(weakAt, inv[1].tool)
	if ok then
		return "swapped in " .. why
	end
	return "couldn't swap: " .. tostring(why)
end

-- gui ------------------------------------------------------------------------
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a restyle
-- is one file and not thirty. Fetched here rather than installed by the loader, so this
-- file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Steal a Brainrot Base", -- fallback until the live name lands
	folder = "StealABrainrotBase", -- never rename: configs saved in-game orphan
	size = UDim2.fromOffset(520, 430),
})
if not Window then
	return -- panel.lua already said why
end

-- The farm loop never writes to the panel, it leaves a line here. Executors hand a RESUMED
-- thread back with reduced capability, so the first status write lands and every one after
-- a task.wait throws "cannot access 'Instance' (lacking capability Plugin)" -- the panel
-- lives in the hidden GUI, which is the part that needs it. Uncaught, that kills the farm
-- on its second lap with the toggle stuck ON.
local pending = nil
say = function(msg)
	pending = msg
end

-- An empty tick set filters EVERYTHING out, which is exactly what "the rarity filter does
-- nothing" looks like. Which of three shapes a Multi dropdown hands back depends on the
-- WindUI build panel.lua fetched, not on our code -- so take whichever side is the string.
local function ticked(values)
	local set = {}
	for k, v in pairs(values or {}) do
		if type(v) == "string" then
			set[v] = true -- list form: 1 -> "Godly"
		elseif type(v) == "table" and type(v.Title) == "string" then
			set[v.Title] = true -- row form: the whole {Title=, Desc=} table comes back
		elseif v then
			set[k] = true -- map form: "Godly" -> true
		end
	end
	return set
end
assert(ticked({ "Godly", "Secret" }).Secret, "the list form ticks its names")
assert(ticked({ Godly = true }).Godly, "the map form ticks its keys")
assert(not ticked({ Godly = false }).Godly, "an unticked key in the map form stays off")
assert(ticked({ { Title = "Godly" } }).Godly, "the row form ticks its titles")

-- Fill `set` from a callback's values, dropping anything not on the ladder. A Refresh
-- re-fires the callback with whatever Value the dropdown still holds -- often "" -- and
-- assigning that would wipe a good selection from a thread we don't control.
local function adopt(set, values)
	local picked = ticked(values)
	table.clear(set) -- held live by the loop as an upvalue; replacing it orphans the loop's copy
	for name in pairs(picked) do
		if RANK[name] then
			set[name] = true
		end
	end
end
do
	local probe = { Stale = true }
	adopt(probe, { "Common", "" })
	assert(probe.Common and not probe.Stale and not probe[""], "adopt keeps known picks and drops the rest")
end

-- In ladder order rather than hash order, so the status line reads the same way twice.
local function summarize(set)
	local n, only = 0, nil
	for _, name in ipairs(RARITIES) do
		if set[name] then
			n += 1
			only = only or name
		end
	end
	if n == 0 then
		return "none"
	elseif n == 1 then
		return only
	elseif n == #RARITIES then
		return "all"
	end
	return n .. " of " .. #RARITIES
end

local function fmt(n)
	for _, s in ipairs({ { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
		if n >= s[1] then
			return string.format("%.1f%s", n / s[1], s[2])
		end
	end
	return string.format("%d", n)
end
assert(fmt(1500) == "1.5K", "thousands get a suffix")
assert(fmt(12) == "12", "small numbers stay literal")
assert(fmt(2.4e9) == "2.4B", "billions pick the right suffix, not the first one over")

local FarmTab = Window:Tab({ Title = "Farm", Icon = "solar:magnet-bold" })
local PlotTab = Window:Tab({ Title = "Plot", Icon = "solar:buildings-2-bold" })
local ToolTab = Window:Tab({ Title = "Tools", Icon = "solar:settings-bold" })

local Target = FarmTab:Section({ Title = "Target", Icon = "solar:filter-bold", Box = true, BoxBorder = true, Opened = true })
local Run = FarmTab:Section({ Title = "Run", Icon = "solar:play-bold", Box = true, BoxBorder = true, Opened = true })
local Lucky = FarmTab:Section({ Title = "Lucky drops", Icon = "solar:star-fall-bold", Box = true, BoxBorder = true, Opened = true })

local Cash = PlotTab:Section({ Title = "Cash", Icon = "solar:dollar-minimalistic-bold", Box = true, BoxBorder = true, Opened = true })
local Place = PlotTab:Section({ Title = "Placement", Icon = "solar:layers-bold", Box = true, BoxBorder = true, Opened = true })

local Travel = ToolTab:Section({ Title = "Travel", Icon = "solar:map-point-bold", Box = true, BoxBorder = true, Opened = true })
local Debug = ToolTab:Section({ Title = "Debug", Icon = "solar:bug-bold", Box = true, BoxBorder = true, Opened = true })

local line = Run:Paragraph({ Title = "Status", Desc = "idle" })

Target:Dropdown({
	Title = "Rarities",
	Desc = "What the farm will steal. Order is the game's: Secret ranks below Godly.",
	Values = RARITIES,
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		adopt(wanted, values)
		say(summarize(wanted) .. " rarities")
	end,
})

Target:Dropdown({
	Title = "Sort",
	Desc = "Rarity first is the safe default; value only chases the biggest number anywhere.",
	Values = { "Rarity then value", "Value only" },
	Value = "Rarity then value",
	Callback = function(v)
		sortMode = (v == "Value only") and "value" or "rarity"
	end,
})

Target:Toggle({
	Title = "Include locked bases",
	Desc = "Forces the prompt open and hides the lasers locally. The server probably checks too -- a base that refuses is dropped after "
		.. BASE_STRIKES
		.. " tries.",
	Value = false,
	Callback = function(state)
		allowLocked = state
		if not state then
			restoreLasers()
		end
		table.clear(strikes)
	end,
})

farmToggle = Run:Toggle({
	Title = "Auto Farm",
	Desc = "Richest ticked brainrot first, carry it home, repeat",
	Value = false,
	Callback = function(state)
		if state and next(wanted) == nil then
			say("tick a rarity first")
			pcall(function()
				farmToggle:Set(false)
			end)
			return
		end
		setFarming(state)
		-- Written AFTER the Set above, or a rejected switch-on has its reason overwritten
		-- by the off branch's "stopped" a frame later.
		say(state and "farming" or "stopped")
	end,
})

Lucky:Toggle({
	Title = "Detect drops",
	Desc = "Reads the server's own LUCKY DROP announcements",
	Value = false,
	Callback = function(state)
		detectDrops = state
		say(state and ("watching for drops (last: " .. lastDrop .. ")") or "not watching drops")
	end,
})

Lucky:Toggle({
	Title = "Auto-steal drops",
	Desc = "A matching drop jumps the farm queue for " .. DROP_TTL .. "s",
	Value = false,
	Callback = function(state)
		stealDrops = state
		if state and not detectDrops then
			say("turn Detect drops on too")
		end
	end,
})

-- Secret and up: the tiers a drop is actually worth abandoning a farm cycle for. Seeded
-- into dropWanted by hand as well as passed as Value, because a starting Value fires no
-- callback and the set would otherwise be empty -- which filters every drop out.
local DROP_DEFAULT = {}
do
	local floor = RANK.Secret or 1
	for _, name in ipairs(RARITIES) do
		if (RANK[name] or 0) >= floor then
			table.insert(DROP_DEFAULT, name)
			dropWanted[name] = true
		end
	end
end

Lucky:Dropdown({
	Title = "Drop rarities",
	Desc = "Separate from the farm's list, so you can farm anything and still drop it all for a Godly",
	Values = RARITIES,
	Value = DROP_DEFAULT,
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		adopt(dropWanted, values)
	end,
})

local collecting, collectGen = false, 0
local collectRow
collectRow = Cash:Toggle({
	Title = "Auto Collect Cash",
	Desc = "Touches every collect button with money on it. Never moves you.",
	Value = false,
	Callback = function(state)
		collecting = state
		collectGen += 1
		local mine = collectGen
		if not state then
			pcall(function()
				collectRow:SetDesc("stopped")
			end)
			return
		end
		task.spawn(function()
			while collecting and collectGen == mine do
				local ok, msg = pcall(collectPass)
				-- pcall'd: a loop thread that lost capability must not take the sweep down.
				pcall(function()
					collectRow:SetDesc(ok and tostring(msg) or "error -- see console (F9)")
				end)
				if not ok then
					warn("[steal_base] collect:", msg)
				end
				task.wait(COLLECT_EVERY)
			end
		end)
	end,
})
table.insert(stoppers, function()
	collecting = false
	collectGen += 1
end)

local placing, placeGen = false, 0
local placeRow
placeRow = Place:Toggle({
	Title = "Auto Place Best",
	Desc = "Highest income into the earliest slot: floor 1 slot 1, then upward",
	Value = false,
	Callback = function(state)
		placing = state
		placeGen += 1
		local mine = placeGen
		if not state then
			pcall(function()
				placeRow:SetDesc("stopped")
			end)
			return
		end
		task.spawn(function()
			while placing and placeGen == mine do
				local ran = claim(function()
					local ok, msg = pcall(placePass)
					pcall(function()
						placeRow:SetDesc(ok and tostring(msg) or "error -- see console (F9)")
					end)
					if not ok then
						warn("[steal_base] place:", msg)
					end
				end)
				task.wait(ran and PLACE_EVERY or 0.5)
			end
		end)
	end,
})
table.insert(stoppers, function()
	placing = false
	placeGen += 1
end)

-- Starts on, and needs no hand-arming: swapWeaker is declared true, so the row and the
-- variable already agree. (The guards toggle below DOES need arming -- it has a side effect
-- to run, not just a flag to match.)
Place:Toggle({
	Title = "Swap out weaker",
	Desc = "With the plot full, evict the weakest placed brainrot when the bag beats it. The weak one comes back to you.",
	Value = true,
	Callback = function(state)
		swapWeaker = state
	end,
})

Place:Button({
	Title = "Sell Inventory",
	Desc = "RequestSell(\"Inventory\"). Swapping produces junk and a full bag is how securing starts failing quietly.",
	Callback = function()
		if not RequestSell then
			say("RequestSell missing")
			return
		end
		pcall(function()
			RequestSell:FireServer("Inventory")
		end)
		say("sold inventory")
	end,
})

ToolTab:Section({ Title = "Guards", Icon = "solar:shield-cross-bold", Box = true, BoxBorder = true, Opened = true }):Toggle({
	Title = "Freeze guards",
	Desc = "The guards are simulated on your client and report you themselves. This writes the same flag the Robux product does, locally. Undone on stop.",
	Value = true,
	Callback = function(state)
		setFreeze(state)
	end,
})
setFreeze(true) -- a starting Value = true fires no callback, so arm it by hand

local travelTo = BASE_NAMES[1]
Travel:Dropdown({
	Title = "Base",
	Values = (function()
		local out = {}
		for _, b in ipairs(BASE_NAMES) do
			table.insert(out, b .. " -- " .. (baseConf[b].NPCName or "?"))
		end
		return out
	end)(),
	Value = BASE_NAMES[1] and (BASE_NAMES[1] .. " -- " .. (baseConf[BASE_NAMES[1]].NPCName or "?")) or "",
	Callback = function(v)
		travelTo = tostring(v):match("^(Base%d+)") or travelTo
	end,
})

Travel:Button({
	Title = "Teleport to base",
	Callback = function()
		if farming then
			say("turn Auto Farm off first") -- refuse rather than block: a lock that waits reads as broken
			return
		end
		claim(function()
			local folder = basesRoot:FindFirstChild(travelTo)
			local anchor = folder and folder:FindFirstChild("Spawn")
			local ok = anchor and anchor:IsA("BasePart")
					and travel(anchor.CFrame + Vector3.new(0, 4, 0), "ToBase", travelTo)
				or serverTo("ToBase", travelTo)
			say(ok and ("went to " .. travelTo) or ("couldn't reach " .. travelTo))
		end)
	end,
})

Travel:Button({
	Title = "Return to my base",
	Callback = function()
		if farming then
			say("turn Auto Farm off first")
			return
		end
		claim(function()
			say(goHome() and "home" or "couldn't find your plot")
		end)
	end,
})

-- The probe. Everything it prints is what the farm loop acts on, so a farm that "does
-- nothing" is one button from an answer rather than a guess.
Debug:Button({
	Title = "Probe",
	Desc = "One steal, narrated to F9: which press works, whether it secures, whether the guard bites",
	Callback = function()
		if farming then
			say("turn Auto Farm off first")
			return
		end
		task.spawn(function()
			claim(function()
				log("---- probe ----")
				log(("executor: fireproximityprompt=%s VirtualInputManager=%s"):format(tostring(hasFPP), tostring(hasVIM)))
				log(("modules: BaseConfigurations=%s RarityConfigurations=%s ItemConfigurations=%s"):format(
					tostring(next(baseConf) ~= nil),
					tostring(#RARITIES),
					tostring(itemConf ~= nil)
				))
				local un = {}
				for _, b in ipairs(BASE_NAMES) do
					if unlocked(b) then
						table.insert(un, b)
					end
				end
				log("unlocked bases: " .. (#un > 0 and table.concat(un, ", ") or "NONE"))
				local plot = myPlot()
				log("my plot: " .. (plot and plot.Name or "NOT FOUND"))
				log("freeze guards attribute reads: " .. tostring(player:GetAttribute("FreezeGuardsActive")))

				-- Score everything spawned, ticked or not, so the probe still says something
				-- useful when the rarity filter is empty.
				local saved = {}
				for name in pairs(wanted) do
					saved[name] = true
				end
				for _, name in ipairs(RARITIES) do
					wanted[name] = true
				end
				local list = scan(nil)
				table.clear(wanted)
				for name in pairs(saved) do
					wanted[name] = true
				end

				log(("%d brainrots spawned across the bases we may touch"):format(#list))
				for i = 1, math.min(5, #list) do
					local t = list[i]
					log(("  %d. %s/%s  %s %s  %s/s%s"):format(
						i,
						t.base,
						t.slot,
						t.rarity,
						t.model:GetAttribute("OriginalName") or "?",
						fmt(t.worth),
						promptOf(t.model) and "" or "   (parts not streamed yet)"
					))
				end
				if #list == 0 then
					log("nothing to probe against -- wait for a spawn, or unlock a base")
					log("---- probe end ----")
					return
				end

				local target = list[1]
				log(("trying %s/%s -- each method gets %ds"):format(target.base, target.slot, PROBE_WINDOW))
				local aim = target.model:GetPivot() + Vector3.new(0, 4, 0)
				-- Reported separately, because "the hop stuck" and "we needed the remote" are
				-- the two different worlds this script's speed depends on.
				local direct = hop(aim)
				log("direct CFrame hop stuck: " .. tostring(direct) .. (direct and "" or "  (server reverted it -- travel falls back to RequestTeleport)"))
				if not direct then
					log("travel: RequestTeleport(ToBase) -> " .. tostring(serverTo("ToBase", target.base)))
					hop(aim)
				end
				local prompt = waitForPrompt(target.model, ARRIVE)
				if not prompt then
					local kids = {}
					for _, c in ipairs(target.model:GetChildren()) do
						table.insert(kids, c.ClassName .. " " .. c.Name)
					end
					log("no ProximityPrompt anywhere under the model. Its children are:")
					log("  " .. (#kids > 0 and table.concat(kids, ", ") or "(none -- not streamed in)"))
					log("---- probe end ----")
					return
				end
				log(("prompt: %s / hold %.1f / range %.0f / enabled %s / on a %s named %q"):format(
					prompt.ActionText,
					prompt.HoldDuration,
					prompt.MaxActivationDistance,
					tostring(prompt.Enabled),
					prompt.Parent and prompt.Parent.ClassName or "?",
					prompt.Parent and prompt.Parent.Name or "?"
				))
				open(prompt)

				local won = nil
				for i, method in ipairs(METHODS) do
					if method.ok and not won then
						local deadline = os.clock() + PROBE_WINDOW
						repeat
							local root = hrp()
							if root then
								root.CFrame = target.model:GetPivot() + Vector3.new(0, 4, 0)
							end
							method.run(prompt)
							task.wait(0.1)
						until carrying() or os.clock() > deadline
						log(("  %s -> %s"):format(method.name, carrying() and "CARRYING" or "nothing"))
						if carrying() then
							won = i
						end
					end
				end
				if not won then
					log("no press method got it. Last notification: " .. lastNote.text .. " (" .. lastNote.kind .. ")")
					log("---- probe end ----")
					return
				end
				winner = won
				log("winner: " .. METHODS[won].name)
				log("CarriedItem_SourceBase = " .. tostring(player.Character and player.Character:GetAttribute("CarriedItem_SourceBase")))

				local ok, why = secure(function()
					return true
				end)
				log(("secure -> %s (%s)"):format(tostring(ok), tostring(why)))
				log("last notification: " .. lastNote.text .. " (" .. lastNote.kind .. ")")
				log("If that said 'confiscated', the freeze isn't holding -- check the attribute line above.")
				log("---- probe end ----")
				say("probe done -- see F9")
			end)
		end)
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
		log(msg)
	end
end)

say(#BASE_NAMES .. " bases, " .. #RARITIES .. " rarities -- tick some and run Probe first")

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
	getgenv().stealBaseStop = nil
end)

getgenv().stealBaseStop = function()
	stopAll() -- every loop exits on its own flag, so this really does stop them
	disconnectAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().stealBaseStop = nil -- or the next paste calls a stop for a destroyed window
end
