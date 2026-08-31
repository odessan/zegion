--[[ Fake a Brainrot -- buy the best REAL brainrot in the field, ignore the fakes

     The field is full of brainrots and some of them are other players wearing one. The
     tell is structural, not visual: a real one is a Model under workspace.ActiveItems
     with IsBrainrot set, and a faker is workspace.<username>.FakeBrainrot hanging off a
     character. Nothing that isn't a child of ActiveItems is ever touched here, which is
     the same test the game's own OnboardingClient uses to point new players at one.

     BUY      : toggle. Ranks everything in ActiveItems by what it's worth, drops
                anything you can't pay for, walks to the best one left and holds its
                PickupPrompt until it's in your hands.
     WORTH    : ReplicatedStorage.Shared.BrainrotConfig, required rather than
                reimplemented -- it's the table the game itself prices off:

                    value = Items[name].IncomePerSecond * Mutations[mut].Multiplier
                    cost  = BrainrotConfig.GetPickupCost(name, mut)

                Cost is that same income times the rarity's own PickupCost multiplier
                (0 for Common, 150000 for OG), so a Gold Secret is worth twice a plain
                one and costs twice as much. Affordable means <= leaderstats.Cash.
     RARITY   : floor, so a rich account stops walking across the map for Commons.
     REBIRTH  : the "Needs for Rebirth" board over your plot, read off the same two
                sources the game's own RebirthHUD reads:

                    RebirthConfig.Levels[RebirthLevel + 1].RequiredBrainrots
                    Events.GetRebirthOwnership:InvokeServer()   -- ID -> how many you have

                On by default, and it only ever REORDERS -- it never makes the loop wait:

                    a missing one is out and you can pay for it   -> buy that
                    it's out but you're short                     -> best $/s you can
                    none of them is out                           -> best $/s you can

                Missing ones also ignore the rarity floor, because level 1 wants a
                Noobini Pizzanini -- a Common -- and a floor set for income would skip
                the one thing you're actually blocked on.

                Worth knowing it does NOT ring-fence cash: the fallback will happily
                spend on a Legendary while you're short of the level's RequiredCash,
                which pushes the rebirth further away, not closer. Untick it, or set a
                rarity floor, if you're saving.
     PLACE    : OFF by default -- it decides where your brainrots go, and that's yours to
                make. CarryCapacity is 1 though, so it is the only thing that lets the
                loop run unattended: with it off, one buy fills your hands and the loop
                parks until you place by hand.

                Ticked on, it takes the lowest free slot on your plot and holds its
                SlotPrompt until the Tool leaves your Character. Both "is this slot
                usable" tests are TycoonInteractions.refreshSlot's own: Transparency
                > 0.9 is a slot your rebirth level hasn't unlocked, and a PlacedBrainrot
                child is an occupied one. Which slot doesn't matter -- they all pay the
                same, PositionMultipliers scales a brainrot by its place in its RARITY
                ROSTER, not by where it stands.

                Placing is also what ticks a rebirth requirement. Buying doesn't.

                There is no stash-it-and-carry-on alternative: the place prompt only
                turns on while the Tool is in your Character (refreshSlot tests
                FindFirstChildWhichIsA("Tool")), so parking it in the Backpack would
                make it unplaceable -- and the game keeps the Backpack CoreGui switched
                off anyway.
     PLOT     : with auto place off, a buy drops you on your plot's SpawnLocation
                instead, so the thing in your hands is one prompt from a slot.
     CASH     : every occupied slot has its own SlotN_Collector pad, and walking one pays
                that slot out. firetouchinterest reaches the server's Touched handler
                without moving you, so a sweep is all thirty pads at once from wherever
                you're standing -- it stacks with the buy loop rather than interrupting
                it. CollectAllZone is swept too; that one is the COLLECT_ALL gamepass
                version and does nothing without the pass, which costs nothing to try.
                The row shows the cash delta per sweep, which is the only honest check
                that the server accepted a touch you weren't standing on.
     CONFIRM  : a Tool named after the brainrot appearing in your Character. NOT the
                model leaving ActiveItems -- everything out there carries a TimeLeft and
                despawns on its own, so "it's gone" and "you bought it" look identical
                from the folder's side.

     No stealing and no faking: this buys, places and collects on your own plot only.

     Executor only: the UI is WindUI, pulled in with HttpGet, which Studio blocks.
     RightControl minimises and expands -- the body rolls up to a bare Zegion pill, and
     the minus button does the same by mouse. RightAlt hides the window outright, for a
     screenshot. Everything keeps running under either.
     Stop for good: getgenv().fakeRotStop() ]]

-- config ---------------------------------------------------------------------
local POLL = 0.5 -- beat for the field row when the buy loop isn't running
-- Seconds between rebirth-ownership checks. This one is a server round trip, unlike
-- everything else here, and the answer only moves when you place a brainrot -- so it
-- runs on its own slow beat rather than inside the field row.
local NEED_POLL = 10
local CYCLE = 0.2 -- breathing room between buys; the whole cycle is one server round trip
local IDLE = 2 -- parked when nothing in the field is affordable, rather than re-scanning flat out
-- Seconds between cash sweeps. The pads pay out what a slot has banked since the last
-- touch, so hurrying this just sends more touches for smaller amounts.
local COLLECT_POLL = 5
local GRAB_OFFSET = Vector3.new(0, 4, 0) -- above the brainrot; must land inside prompt range (10)
-- How far you may drift before buy() hops you back. These wander -- WFrom to WTo over
-- WDur, which works out around 5 studs/s -- so unlike a brainrot standing on a stand
-- this genuinely does need re-aiming. Keep it under the prompt's MaxActivationDistance
-- and above the fall from GRAB_OFFSET, or you re-teleport every frame on the way down.
local GRAB_REACH = 8
local GRAB_TIME = 4 -- seconds holding one prompt before writing it off and re-ranking
local PLACE_TIME = 4 -- same, for the slot prompt on the way back
local FIRE_STEP = 0.05 -- between prompt fires
local STREAM_TIMEOUT = 3 -- ceiling on the GameplayPaused wait after a hop, not a delay paid up front
local KEY_TOGGLE = Enum.KeyCode.RightControl

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

if getgenv and getgenv().fakeRotStop then
	getgenv().fakeRotStop() -- re-running must not stack a second panel and a second loop
end

-- world ----------------------------------------------------------------------
-- The game's own pricing table and its own number formatter. Requiring beats
-- reimplementing: the rarity ladder, the mutation multipliers and GetPickupCost are all
-- in here already, and a balance patch moves them without touching this file.
--
-- ponytail: no fallback if it's missing. The billboard over each brainrot does show
-- "$N/s" and a price, so ranking off text is possible -- but it's a parser and a whole
-- second code path for a module that ships in ReplicatedStorage of every server. If the
-- require fails the toggle refuses to arm and says so, which is the honest outcome.
local Cfg, Fmt, Reb, Ownership
do
	local shared = ReplicatedStorage:WaitForChild("Shared", 10)
	local function grab(name)
		local ok, res = pcall(require, shared and shared:FindFirstChild(name))
		return ok and res or nil, res
	end
	local why
	Cfg, why = grab("BrainrotConfig")
	if not Cfg then
		warn("[fakerot] ReplicatedStorage.Shared.BrainrotConfig didn't load:", why)
	end
	Fmt = grab("FormatNumber")
	-- Optional: without it the rebirth toggle greys out and the rest still works.
	Reb = grab("RebirthConfig")
	local events = ReplicatedStorage:FindFirstChild("Events")
	Ownership = events and events:FindFirstChild("GetRebirthOwnership")
end

local function money(n)
	if Fmt then
		return "$" .. Fmt.Abbreviate(n)
	end
	return ("$%.3g"):format(n) -- only reached if FormatNumber moved; readable enough
end

local function hrp()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- Position only, never the brainrot's own CFrame: these are rotated by their
-- WImportedRot attribute and pivoting onto one tips the character over with it.
local function tp(pos, settle)
	local char = player.Character
	if not pos or not char or not hrp() then
		return false
	end
	char:PivotTo(CFrame.new(pos + GRAB_OFFSET))
	if settle then
		local deadline = os.clock() + STREAM_TIMEOUT
		while player.GameplayPaused and os.clock() < deadline do
			task.wait()
		end
	end
	return true
end

local function cash()
	local stats = player:FindFirstChild("leaderstats")
	local c = stats and stats:FindFirstChild("Cash")
	return c and c.Value or 0
end

-- What you're already carrying. The bought brainrot arrives as a Tool parented straight
-- to the Character (RequiresHandle=false, so your hands look empty) -- that Tool is the
-- only thing that says the server took your money.
local function held()
	local char = player.Character
	if not char then
		return 0, nil
	end
	local n, first = 0, nil
	for _, inst in ipairs(char:GetChildren()) do
		if inst:IsA("Tool") and inst:GetAttribute("IsBrainrot") then
			n += 1
			first = first or inst
		end
	end
	return n, first
end

local function carryCap()
	return player:GetAttribute("CarryCapacity") or 1
end

-- Found by attribute, not by index: which PlotN you get is whatever was free when you
-- joined, and the game's own getMyPlot does exactly this.
local function myPlot()
	local plots = workspace:FindFirstChild("Plots")
	for _, plot in ipairs(plots and plots:GetChildren() or {}) do
		if plot:GetAttribute("OwnerUserId") == player.UserId then
			return plot
		end
	end
	return nil
end

-- Where to land. SpawnLocation is the plot's own front door -- it's where the game
-- respawns you -- and CollectAllZone is the backup because every plot has one. A Plot is
-- a Folder, so there is no pivot to fall back to past that: nil means "say so".
local function plotSpot()
	local plot = myPlot()
	local part = plot and (plot:FindFirstChild("SpawnLocation") or plot:FindFirstChild("CollectAllZone"))
	return part and part:IsA("BasePart") and part.Position or nil
end

-- Rarity floor list, built off the config's own ladder rather than a hardcoded order --
-- a new tier between Celestial and OG shows up here with nothing to edit.
local RARITIES, RANK = { "Any" }, {}
if Cfg then
	local sorted = table.clone(Cfg.Rarities)
	table.sort(sorted, function(a, b)
		return a.Rank < b.Rank
	end)
	for _, r in ipairs(sorted) do
		table.insert(RARITIES, r.Name)
		RANK[r.Name] = r.Rank
	end
end

-- rebirth --------------------------------------------------------------------
-- What the NEXT rebirth still wants, as name -> how many short. Refreshed on its own
-- slow beat below; the loop and the panel both just read `needs`.
-- `needs` is the lookup the sort uses; `needList` is the same set in the config's own
-- order, because the row is rebuilt twice a second and pairs() order would make it
-- shuffle its own words in front of you.
local needs, needList, needsLine = {}, {}, "..."

local function refreshNeeds()
	local level = player:GetAttribute("RebirthLevel") or 0
	local lvl = Reb and Reb.Levels[level + 1]
	if not lvl then
		needs, needList = {}, {}
		needsLine = Reb and "nothing left to rebirth into" or "RebirthConfig didn't load"
		return
	end

	-- The server's own tally, not a guess off what's on the plot: it's the number the
	-- rebirth button itself gates on, so it's the only one worth believing.
	local owned = {}
	if Ownership then
		local ok, res = pcall(function()
			return Ownership:InvokeServer()
		end)
		if ok and type(res) == "table" then
			owned = res
		end
	end

	local out, missing = {}, {}
	for _, req in ipairs(lvl.RequiredBrainrots or {}) do
		local short = (req.Count or 1) - (owned[req.ID] or 0)
		if short > 0 then
			out[req.ID] = short
			table.insert(missing, req.ID)
		end
	end
	needs, needList = out, missing

	local gap = (lvl.RequiredCash or 0) - cash()
	local cashPart = gap > 0 and (money(gap) .. " short") or "cash is there"
	needsLine = ("%d -> %d: %s -- %s"):format(
		level,
		level + 1,
		#missing == 0 and "every brainrot placed" or ("still wants " .. table.concat(missing, ", ")),
		cashPart
	)
end

-- rank -----------------------------------------------------------------------
-- One pass over the field. Everything the panel wants to show and everything the loop
-- wants to decide on comes out of here, so there's one place that knows the shape.
-- On by default: the rebirth blockers are the only buys that unlock anything, so
-- "clear those, otherwise take the best $/s I can pay for" is the sane standing order.
-- Costs nothing when RebirthConfig didn't load -- `needs` stays empty and no entry is
-- ever flagged, which is the same list as off.
local rebirthFirst = true -- written by the rebirth toggle

local function scan()
	local out, unknown = {}, 0
	local folder = workspace:FindFirstChild("ActiveItems")
	if not (folder and Cfg) then
		return out, unknown
	end
	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") and model:GetAttribute("IsBrainrot") and model.PrimaryPart then
			local mut = model:GetAttribute("Mutation") or "Normal"
			local info = Cfg.Items[model.Name]
			if info then
				local mult = Cfg.GetMutationInfo(mut).Multiplier or 1
				table.insert(out, {
					model = model,
					name = model.Name,
					mut = mut,
					rarity = info.Rarity,
					rank = RANK[info.Rarity] or 0,
					value = info.IncomePerSecond * mult,
					cost = Cfg.GetPickupCost(model.Name, mut),
					left = model:GetAttribute("TimeLeft"),
					need = needs[model.Name] ~= nil,
				})
			else
				unknown += 1 -- a brainrot the shipped config doesn't price; never picked
			end
		end
	end
	table.sort(out, function(a, b)
		-- Rebirth blockers first when asked for, best-value inside each group. A needed
		-- one is worth a walk that its $/s alone would never justify -- level 1 wants a
		-- Common -- and this is the whole of that preference.
		if rebirthFirst and a.need ~= b.need then
			return a.need
		end
		return a.value > b.value
	end)
	return out, unknown
end

-- Which of the missing rebirth brainrots are standing in the field RIGHT NOW, and
-- whether you could pay for them -- built off the same scan the field row uses rather
-- than a second pass, and appended to the line refreshNeeds already wrote.
local function fieldNeeds(field, wallet)
	if #needList == 0 then
		return ""
	end
	local out = {}
	for _, e in ipairs(field) do
		if e.need then
			out[e.name] = e
		end
	end
	local here = {}
	for _, name in ipairs(needList) do
		local e = out[name]
		if e then
			table.insert(here, e.cost <= wallet and name or ("%s (%s, can't pay)"):format(name, money(e.cost)))
		end
	end
	if #here == 0 then
		return " -- none of them out right now"
	end
	return " -- OUT NOW: " .. table.concat(here, ", ")
end

local function label(e)
	local tag = e.mut ~= "Normal" and (e.mut .. " ") or ""
	local flag = (rebirthFirst and e.need) and "[rebirth] " or ""
	return ("%s%s%s (%s, %s/s)"):format(flag, tag, e.name, e.rarity, money(e.value))
end

-- farm -----------------------------------------------------------------------
-- The shell is built below, so the rows the loop writes to are declared here and filled
-- in there. say() no-ops until then, which is what makes the order legal.
local statusRow, fieldRow, lastRow, needsRow, buyToggle
local running = true
local buying, bought, placed = false, 0, 0
-- Off by default. It works, but it decides where your brainrots go, and that's a call
-- worth leaving with the person whose plot it is -- turn it on for an unattended run.
local autoPlace = false
local minRank = 0 -- 0 is "Any"; written by the dropdown
local grabTime = GRAB_TIME
local goHome = true -- ride back to the plot after each buy; written by its toggle

local function say(msg)
	if statusRow then
		statusRow:SetDesc(msg)
	end
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

-- The prompt is reparented every frame onto _ClientUIAnchor, a bare part the wander
-- client keeps at the brainrot's untilted position -- so that anchor, when it exists, is
-- both where the prompt is and the cleanest thing to aim at.
local function aimAt(model)
	local anchor = model:FindFirstChild("_ClientUIAnchor")
	if anchor and anchor:IsA("BasePart") then
		return anchor.Position
	end
	return model:GetPivot().Position
end

-- A slot you can actually put something in. Both tests are the game's own, lifted from
-- TycoonInteractions.refreshSlot: Transparency > 0.9 is how it recognises a slot your
-- rebirth level hasn't unlocked (it disables the prompt on exactly that), and a
-- PlacedBrainrot child is how it recognises an occupied one.
--
-- Lowest free number wins, and that's not a preference -- every slot pays the same.
-- PositionMultipliers scales a brainrot by its place in its RARITY ROSTER, which is
-- baked into Items[name].IncomePerSecond long before a slot is involved.
local function freeSlot()
	local plot = myPlot()
	local slots = plot and plot:FindFirstChild("Slots")
	if not slots then
		return nil
	end
	local best, bestN
	for _, slot in ipairs(slots:GetChildren()) do
		local n = tonumber(tostring(slot.Name):match("^Slot(%d+)$"))
		if
			n
			and slot:IsA("BasePart")
			and slot.Transparency <= 0.9
			and not slot:FindFirstChild("PlacedBrainrot")
			and slot:FindFirstChild("SlotPrompt")
			and (not bestN or n < bestN)
		then
			best, bestN = slot, n
		end
	end
	return best, bestN
end

-- Confirmed by the Tool leaving your Character, which is the mirror of the buy: the
-- server moving it is the only thing that means it took.
local function place(tool)
	local slot, n = freeSlot()
	if not slot then
		return false, "every unlocked slot is full"
	end
	local prompt = slot:FindFirstChild("SlotPrompt")
	-- refreshSlot turns this on when it notices you're carrying, off a ChildAdded it may
	-- not have seen yet. Enabled is a client-side gate on a client-side fire, so setting
	-- it ourselves costs nothing and removes the race.
	prompt.Enabled = true
	local char = player.Character
	local deadline = os.clock() + PLACE_TIME
	local arriving = true
	repeat
		local root = hrp()
		if arriving or not root or (root.Position - slot.Position).Magnitude > GRAB_REACH then
			tp(slot.Position, arriving)
			arriving = false
		end
		fire(prompt)
		task.wait(FIRE_STEP)
	until tool.Parent ~= char or os.clock() > deadline
	return tool.Parent ~= char, "slot " .. tostring(n) .. " wouldn't take it"
end

-- Returns true only when a Tool actually landed. The model leaving ActiveItems is NOT
-- the confirm: TimeLeft runs these out from under you and an expiry looks exactly like a
-- purchase from the folder's side.
local function buy(entry)
	local model = entry.model
	local before = held()
	local deadline = os.clock() + grabTime
	local arriving = true
	repeat
		if not model.Parent then
			return false -- despawned mid-approach; the caller re-ranks
		end
		local root = hrp()
		local aim = aimAt(model)
		if arriving or not root or (root.Position - aim).Magnitude > GRAB_REACH then
			tp(aim, arriving)
			arriving = false
		end
		local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
		if prompt then
			fire(prompt)
		end
		task.wait(FIRE_STEP)
	until held() > before or os.clock() > deadline
	return held() > before
end

local function cycle()
	if not hrp() then
		say("no character -- waiting for respawn")
		repeat
			task.wait(0.2)
		until hrp() or not (buying and running)
		return
	end

	local carried, tool = held()
	if carried >= carryCap() then
		-- Emptying your hands IS the loop -- CarryCapacity is 1, so every buy after the
		-- first is blocked until this lands. Handled here rather than tacked onto the buy
		-- path so it also recovers a brainrot you were already holding when you armed it.
		if autoPlace and tool then
			local name = tool.Name -- read it before the server takes the Tool away
			local ok, why = place(tool)
			if ok then
				placed += 1
				say(("placed %s -- %d placed"):format(name, placed))
				refreshNeeds() -- placing is what ticks a rebirth requirement, not buying
			else
				say("can't place " .. name .. " -- " .. why)
				task.wait(IDLE)
			end
			return
		end
		say(("hands full -- carrying %s. Place it, then this picks up again"):format(tool and tool.Name or "one"))
		task.wait(IDLE)
		return
	end

	local field = scan()
	local wallet = cash()
	local best, blocked
	for _, e in ipairs(field) do
		-- A rebirth blocker is exempt from the floor: the thing you're stuck on is
		-- routinely far below the rarity you'd otherwise bother with.
		if e.rank >= minRank or (rebirthFirst and e.need) then
			if e.cost <= wallet then
				best = e
				break
			end
			blocked = blocked or e -- the best thing you're short for, worth naming
		end
	end

	if not best then
		if blocked then
			say(("nothing affordable -- best is %s at %s, you have %s"):format(label(blocked), money(blocked.cost), money(wallet)))
		elseif #field == 0 then
			say("field is empty -- waiting for a spawn")
		else
			say(("%d out, none at %s or above"):format(#field, RARITIES[minRank + 1] or "that rarity"))
		end
		task.wait(IDLE)
		return
	end

	say("going for " .. label(best))
	if buy(best) then
		bought += 1
		if lastRow then
			lastRow:SetDesc(("%s for %s -- %d bought, %d placed"):format(label(best), money(best.cost), bought, placed))
		end
		if autoPlace then
			-- No trip to the plot spawn: the next cycle's hands-full branch teleports
			-- straight to the slot, and stopping halfway is a hop for nothing.
			say("got it -- placing")
		elseif goHome then
			local spot = plotSpot()
			if spot then
				tp(spot, true)
				say("got it -- at your plot, hold a free slot's prompt to place it")
			else
				say("got it -- no plot found under your UserId, place it yourself")
			end
		else
			say("got it -- place it on your plot")
		end
	else
		say("missed " .. best.name .. " -- it expired, or the server refused the buy")
	end
	task.wait(CYCLE)
end

local function startBuying()
	if buying then
		return
	end
	buying = true
	bought = 0
	task.spawn(function()
		while buying and running do
			local ok, err = pcall(cycle)
			if not ok then
				-- A model can die between the scan and the reach for it, and indexing the
				-- corpse throws. Restart the sweep rather than killing the loop.
				warn("[fakerot]", err)
				task.wait(CYCLE)
			end
		end
	end)
end

-- collect --------------------------------------------------------------------
-- Every occupied slot has its own SlotN_Collector pad beside it, and walking over one
-- pays that slot out. firetouchinterest reaches the server's Touched handler without
-- moving you, so a sweep is every pad at once from wherever you happen to be standing --
-- no lap of the plot, and it stacks with the buy loop driving your character elsewhere.
--
-- CollectAllZone is swept too. It's the gamepass version of the same thing (COLLECT_ALL,
-- player attribute OwnsCollectAllPass) and costs nothing to touch without the pass.
--
-- ponytail: begin every pad, ONE gap, then end every pad -- the server sees the same
-- begin/end pairs it would from a walk, and thirty slots stop costing thirty gaps.
local firetouch = firetouchinterest
local collecting, collectRow, collected = false, nil, 0
local TOUCH_GAP = 0.05
local SETTLE_CREDIT = 0.3 -- let the payout land before reading Cash back

local function collectPads()
	local plot = myPlot()
	if not plot then
		return {}
	end
	local pads = {}
	local slots = plot:FindFirstChild("Slots")
	for _, p in ipairs(slots and slots:GetChildren() or {}) do
		if p:IsA("BasePart") and p.Name:match("_Collector$") then
			table.insert(pads, p)
		end
	end
	local zone = plot:FindFirstChild("CollectAllZone")
	if zone and zone:IsA("BasePart") then
		table.insert(pads, zone)
	end
	return pads
end

-- Returns cash gained and pads touched, or nil when there was nothing to touch WITH --
-- a missing character isn't the plot's fault and shouldn't read as a plot error.
local function collect()
	local root = hrp()
	if not (root and firetouch) then
		return nil
	end
	local pads = collectPads()
	if #pads == 0 then
		return nil
	end
	local before = cash()
	for _, pad in ipairs(pads) do
		pcall(firetouch, root, pad, 0)
	end
	task.wait(TOUCH_GAP)
	for _, pad in ipairs(pads) do
		pcall(firetouch, root, pad, 1)
	end
	-- The credit is a server round trip, so the delta is only readable after it lands.
	-- It's also the ONLY honest check that any of this worked: if the server distance-
	-- checks these pads, every sweep reads 0 and the row says so instead of lying.
	task.wait(SETTLE_CREDIT)
	-- Clamped, because the buy loop can spend inside this window and a purchase would
	-- otherwise read as a negative take. A sweep that genuinely collected nothing and
	-- one that was outspent both land on 0, which is the right amount of precision for
	-- a status row -- Cash itself is the real number.
	return math.max(0, cash() - before), #pads
end

-- The field row runs whether or not the loop does -- it's the "what's out there right
-- now" readout, and it's how you tell an empty field from a broken scan.
task.spawn(function()
	while running do
		local field, unknown = scan()
		local wallet = cash()

		-- needsLine is the slow half (a server round trip, written below and by cycle()
		-- after a buy); fieldNeeds is the fast half off the scan we just did. Joining
		-- them here means the row answers "is the thing I'm stuck on actually out there"
		-- twice a second without a second round trip.
		if needsRow then
			needsRow:SetDesc(needsLine .. fieldNeeds(field, wallet))
		end

		if fieldRow then
			if #field == 0 then
				fieldRow:SetDesc(Cfg and "field is empty" or "BrainrotConfig didn't load -- see F9")
			else
				local top = field[1]
				local afford = 0
				for _, e in ipairs(field) do
					if e.cost <= wallet then
						afford += 1
					end
				end
				fieldRow:SetDesc(
					("%d out, %d affordable%s -- best is %s at %s, you have %s"):format(
						#field,
						afford,
						unknown > 0 and (", " .. unknown .. " unpriced") or "",
						label(top),
						money(top.cost),
						money(wallet)
					)
				)
			end
		end
		task.wait(POLL)
	end
end)

-- The one server round trip in this script, on its own slow beat. Runs whether or not
-- the rebirth toggle is on: knowing what you're blocked on is worth showing either way.
task.spawn(function()
	while running do
		pcall(refreshNeeds)
		task.wait(NEED_POLL)
	end
end)

-- Its own thread, so collecting never waits on a buy and a buy never waits on a sweep.
task.spawn(function()
	while running do
		if collecting then
			local ok, gained, pads = pcall(collect)
			if not ok then
				warn("[fakerot] collect", gained)
			elseif collectRow then
				if gained == nil then
					collectRow:SetDesc(
						firetouch and "nothing to sweep -- no character, or no plot under your UserId"
							or "your executor has no firetouchinterest, so this can't work"
					)
				else
					collected += gained
					collectRow:SetDesc(
						gained > 0
								and ("+%s off %d pads -- %s collected"):format(money(gained), pads, money(collected))
							or ("nothing owed off %d pads -- %s collected so far"):format(pads, money(collected))
					)
				end
			end
		end
		task.wait(COLLECT_POLL)
	end
end)

-- shell ----------------------------------------------------------------------
-- ponytail: no hand-rolled widget kit. Topbar, icon, bubble, live game name and the
-- shade live in panel.lua, so a restyle is one file and not seventeen. Fetched here
-- rather than installed by the loader, so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Fake a Brainrot", -- fallback until the live name lands
	folder = "FakeRot", -- renaming it later orphans configs already saved in-game
	size = UDim2.fromOffset(480, 380),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })

local function card(title, desc, icon)
	return Tab:Section({ Title = title, Desc = desc, Icon = icon, Box = true, BoxBorder = true, Opened = true })
end

local buyCard = card("Buy", "Best real brainrot you can afford, one at a time", "solar:cart-large-4-bold")
local rebirthCard = card("Rebirth", "The board over your plot, as a shopping list", "solar:restart-bold")
local cashCard = card("Cash", "Your plot's slot pads, touched from wherever you are", "solar:dollar-minimalistic-bold")
local tuneCard = card("Tuning", "Where you land, and how long to hold one prompt", "solar:tuning-2-bold")

-- Above the toggle on purpose: it's the setting you pick BEFORE arming the loop, and
-- reading the panel top-to-bottom should read as the order you use it in.
buyCard:Dropdown({
	Title = "Minimum rarity",
	Desc = "Skips anything below this, so a rich account stops crossing the map for Commons",
	Values = RARITIES,
	Value = "Any",
	Callback = function(picked)
		minRank = RANK[picked] or 0
	end,
})

buyToggle = buyCard:Toggle({
	Title = "Auto buy",
	Desc = "Ranks workspace.ActiveItems by $/s and buys the best one your cash covers",
	Value = false,
	Callback = function(state)
		-- Set() below fires this callback again, so the off branch has to be re-entrant.
		if not state then
			if buying then
				say("stopped -- " .. bought .. " bought")
			end
			buying = false
			return
		end
		if not Cfg then
			buyToggle:Set(false)
			WindUI:Notify({ Title = "Fake a Brainrot", Content = "BrainrotConfig didn't load -- see F9.", Image = "x" })
			return
		end
		startBuying()
	end,
})

buyCard:Toggle({
	Title = "Auto place",
	Desc = "Off, the loop stops with it in your hands. On, it takes the lowest free slot and keeps going",
	Value = false,
	Callback = function(state)
		autoPlace = state
	end,
})

statusRow = buyCard:Paragraph({ Title = "Status", Desc = "idle" })
fieldRow = buyCard:Paragraph({ Title = "Field", Desc = "..." })
lastRow = buyCard:Paragraph({ Title = "Last buy", Desc = "nothing yet" })

buyCard:Button({
	Title = "Buy best now",
	Desc = "One pass, without arming the loop",
	Callback = function()
		if buying then
			say("the loop already has it")
			return
		end
		task.spawn(function()
			local ok, err = pcall(cycle)
			if not ok then
				warn("[fakerot]", err)
				say("that pass errored -- see F9")
			end
		end)
	end,
})

rebirthCard:Toggle({
	Title = "Rebirth first",
	Desc = "Wants it, can pay for it -> buy that. Otherwise the best $/s you can afford",
	Value = true,
	Callback = function(state)
		rebirthFirst = state and Reb ~= nil
		if state and not Reb then
			WindUI:Notify({ Title = "Fake a Brainrot", Content = "RebirthConfig didn't load -- see F9.", Image = "x" })
		end
	end,
})

needsRow = rebirthCard:Paragraph({ Title = "Needs", Desc = "..." })

cashCard:Toggle({
	Title = "Auto collect",
	Desc = "Sweeps every slot pad on your plot every " .. COLLECT_POLL .. "s. Runs alongside the buy loop",
	Value = false,
	Callback = function(state)
		collecting = state
		if state and not firetouch then
			WindUI:Notify({
				Title = "Fake a Brainrot",
				Content = "No firetouchinterest -- your executor can't do this.",
				Image = "x",
			})
		end
	end,
})

cashCard:Button({
	Title = "Collect now",
	Desc = "One sweep, without arming the loop",
	Callback = function()
		task.spawn(function()
			local ok, gained, pads = pcall(collect)
			if not ok or gained == nil then
				say("nothing to sweep -- no character, no plot, or no firetouchinterest")
				return
			end
			collected += gained
			say(("swept %d pads for %s"):format(pads, money(gained)))
		end)
	end,
})

collectRow = cashCard:Paragraph({ Title = "Collected", Desc = "nothing yet" })

tuneCard:Toggle({
	Title = "Go to plot after buying",
	Desc = "Drops you on your plot's spawn with it in hand, so placing is one prompt away",
	Value = true,
	Callback = function(state)
		goHome = state
	end,
})

tuneCard:Button({
	Title = "Go to my plot",
	Desc = "Same hop, on demand",
	Callback = function()
		local spot = plotSpot()
		if not spot then
			say("no plot in workspace.Plots carries your UserId")
			return
		end
		say(tp(spot, true) and "at your plot" or "no character")
	end,
})

tuneCard:Slider({
	Title = "Hold time",
	Desc = "Seconds on one prompt before giving up and re-ranking. Raise it if buys keep missing",
	Value = { Min = 1, Max = 10, Default = GRAB_TIME },
	Step = 0.5,
	Callback = function(v)
		grabTime = tonumber(v) or GRAB_TIME
	end,
})

-- close ----------------------------------------------------------------------
-- The red topbar button destroys the window after WindUI's own confirm dialog, so
-- teardown hangs off OnDestroy and both exits share it. ponytail: rerun to come back.
local function shutdown()
	running, buying = false, false
end

Window:OnDestroy(shutdown)

if getgenv then
	getgenv().fakeRotStop = function()
		shutdown()
		Window:Destroy()
	end
end
