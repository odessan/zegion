--[[ Steal a Chicken Egg -- nest farm across all ten play zones (76503495566299)

     FARM   : scores every nest on the map at once -- getNestContents answers for
              every zone from anywhere, and the map key IS the nest position, so
              there is no zone to walk to and nothing to wait for streaming. Picks
              the best by your chosen priority, hops there, steals, carries home.
              Arriving at your base deposits the chicken by itself.
     CLAIM  : claims pen eggs the moment they ripen, read off the game's own store
              rather than polled off the world. Runs on its own thread.
     SELL   : teleports to the sell zone and empties the egg inventory once you
              are holding SELL_AT of them.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().stealChickenEggStop() ]]

-- config ---------------------------------------------------------------------
local CHUNK = 60 -- studs per teleport step. A single long hop can land you inside
-- terrain and get you ejected; 60 was measured covering 1759 studs in 39 hops with
-- nothing reverted. Raise for speed, lower if hops start coming up short.
local CHUNK_GAP = 0.25 -- seconds between hops. Not a rate limit -- three hops 0.1s
-- apart all stuck -- just time for the server to see each one.
local SETTLE = 0.35 -- seconds after arriving before firing. The server range-checks
-- against where it thinks you are, not where you are.
local SCAN_EVERY = 20 -- seconds between full zone rescans. Nests reroll on their own;
-- an inbound refreshNests also forces one, so this is only the backstop.
local PARK = 30 -- seconds a refused nest is skipped for
local MISS_STRIKES = 3 -- consecutive "could not get in range" before parking a target.
-- Separate from a refusal on purpose: an unreachable nest never refuses, so without
-- this it sits at the head of a best-first queue forever.
local GRAB_TIMEOUT = 8 -- seconds for one whole grab, watchdog only
local CLAIM_POLL = 5 -- seconds between ripe-egg checks
local SELL_AT = 10 -- eggs held before a sell trip. An Input, tunable live.
local INSANE_RANGE = 19 -- approach distance for an insane chicken. Its prompt reaches
-- 31-48, but that is a CLIENT gate and says nothing about the server's, so this stays
-- at the nest distance until someone measures it.
local ARRIVE_TOLERANCE = 12 -- studs from target position to confirm arrival. hop() and
-- goTo() both use this; they must agree, or one reports arrival while the other keeps
-- trying. Raise if you get stuck on terrain spikes; lower if you pass through targets.
local LAND_OFFSET = Vector3.new(0, 3, 0) -- vertical offset when landing. Prevents
-- landing inside terrain on a Top surface. Used in hop() and goTo().
local FALLBACK_HOPS = 200 -- max iterations in goTo's chunked fallback. Bounded to
-- prevent spinning forever on an unreachable spot. Raise if distance is regularly
-- longer than this many CHUNK-sized steps; lower to abort faster on bad spots.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CS = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().stealChickenEggStop then
	getgenv().stealChickenEggStop() -- re-running must not stack a second panel
end

local function say(fmt, ...)
	print("[chickenegg] " .. string.format(fmt, ...))
end

local function warnf(fmt, ...)
	warn("[chickenegg] " .. string.format(fmt, ...))
end

local ok, remotes = pcall(require, RS.shared.remotes)
if not ok then
	return warnf("cannot require shared.remotes (%s) -- game updated?", tostring(remotes))
end
local nestsIF = require(RS.shared.gameData.nests.nestsIF)
local insaneIF = require(RS.shared.gameData.nests.insaneEggsIF)
local chickenUT = require(RS.shared.utils.chickenUT)
local penUT = require(RS.shared.utils.penUT)

local STEAL_RANGE = nestsIF.maxStealDistance -- 19 at time of writing; read, never typed

-- world ----------------------------------------------------------------------
-- getNestContents answers for EVERY zone from anywhere on the map, and its map key
-- is nestUT.nestKey(zone, origin) -- literally "zone:x:y:z" of the rounded nest
-- origin. So the nest's position is IN the key: no walking a zone to see it, no
-- waiting for a model to stream, and a steal lands on a nest that never streamed in.
local function zones()
	local t = {}
	for z in pairs(nestsIF.zoneAreas) do
		table.insert(t, z)
	end
	table.sort(t)
	return t
end

local function parseKey(key)
	local zone, x, y, z = key:match("^(.-):(-?%d+):(-?%d+):(-?%d+)$")
	if not zone then
		return nil, nil
	end
	return zone, Vector3.new(tonumber(x), tonumber(y), tonumber(z))
end

do -- self-check: the key format is the one thing everything else is built on
	local z, p = parseKey("forest:25:32:-299")
	assert(z == "forest", "parseKey zone")
	assert(p == Vector3.new(25, 32, -299), "parseKey position")
	assert(select(1, parseKey("crystal:3511:30:-334")) == "crystal", "parseKey negative Z")
	assert(parseKey("not a key") == nil, "parseKey rejects junk")
	assert(parseKey("") == nil, "parseKey rejects empty")
end

-- getNestContents gives {name, variant, size} and nothing else. Value and rarity
-- come from the game's own struct, so a balance patch lands for free.
-- getSellValue already folds weight in, which is why Value and Weight are different
-- orderings rather than independent axes.
local function describe(name, variant, size, kind)
	local def = chickenUT.getChicken(name, variant) -- NOT chickensIF[name]
	if not def then
		return nil
	end
	local okV, value = pcall(def.getSellValue, def, size)
	local rar = def:getRarity()
	local mult = (kind == "insane") and (insaneIF.eggValueMultiplier or 1) or 1
	return {
		label = def:getName() .. (kind == "insane" and " (INSANE)" or ""),
		value = (okV and value or 0) * mult,
		weight = size,
		rarity = rar and rar:getOrder() or 0,
	}
end

local PRIORITIES = {
	{ label = "Highest Value", score = function(d)
		return d.value
	end },
	{ label = "Highest Weight", score = function(d)
		return d.weight
	end },
	-- rarity ties are common (a whole zone shares one), so value breaks them
	{ label = "Highest Rarity", score = function(d)
		return d.rarity * 1e12 + d.value
	end },
}

local function priorityByLabel(label)
	for _, p in ipairs(PRIORITIES) do
		if p.label == label then
			return p
		end
	end
	return PRIORITIES[1]
end

do -- self-check: rarity must dominate value, and value must still break ties
	local rare = { value = 1, weight = 1, rarity = 9 }
	local rich = { value = 5e11, weight = 1, rarity = 8 }
	local s = priorityByLabel("Highest Rarity").score
	assert(s(rare) > s(rich), "rarity outranks value")
	local a = { value = 2, weight = 1, rarity = 8 }
	local b = { value = 1, weight = 1, rarity = 8 }
	assert(s(a) > s(b), "value breaks a rarity tie")
end

local wanted = {} -- {[zone] = true}; the gui writes it, the loop reads it live.
-- Held as an upvalue, so the gui must table.clear + refill, never reassign.
local parked = {} -- {[key] = retryAfter}. Plain table: the keys are strings, so weak
-- keys would do nothing. Rebuilt against the live candidate list on each scan, which
-- is what drops nests that rerolled out of existence.

local function req(promise, timeout)
	local done, ok, val = false, false, nil
	promise:andThen(function(v)
		ok, val, done = true, v, true
	end):catch(function(e)
		ok, val, done = false, e, true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < (timeout or 6) do
		task.wait()
	end
	if not done then
		return nil, "timeout" -- pcall does not bound a yield; a clock does
	end
	return ok, val
end

local function scan()
	local out, any = {}, false
	local seen = {}
	local answeredZones = {} -- track which zones actually answered, to distinguish
	-- a request failure (must not prune parked nests) from a nest reroll (may prune)
	for _, z in ipairs(zones()) do
		local ok, map = req(remotes.game.nests.getNestContents:request(z))
		if ok and type(map) == "table" then
			any = true
			answeredZones[z] = true
			for key, v in pairs(map) do
				local zone, pos = parseKey(key)
				if pos and v.name then
					seen[key] = true
					table.insert(out, {
						kind = "nest",
						zone = zone or z,
						key = key,
						pos = pos,
						name = v.name,
						variant = v.variant,
						size = v.size,
					})
				end
			end
		end
		task.wait(0.3) -- bucket is 20 per 5s across ten zones
	end
	for key in pairs(parked) do
		if not seen[key] then
			local zone, _ = parseKey(key)
			-- prune only if this zone answered and the key was absent from its reply.
			-- if the zone did not answer, a request failure is not evidence the nest is gone.
			if answeredZones[zone] then
				parked[key] = nil -- rerolled away; stop remembering it
			end
		end
	end
	return out, any
end

local preferInsane = false -- batch 2 wires the toggle to this; declared here because best reads it

-- One InsaneEgg per zone, a direct child of the zone folder rather than of Nests,
-- so getNestContents never sees it. Everything needed is on the model as attributes.
-- Strictly better than any ordinary nest in the same zone: eggValueMultiplier 2,
-- species drawn from the rarest three of the zone roster, weight pinned to the top
-- of the band instead of rolled within it.
local function scanInsane()
	local out = {}
	for _, m in ipairs(CS:GetTagged("InsaneEgg")) do
		local zone = m:GetAttribute("insaneZone")
		local name = m:GetAttribute("chickenName")
		local size = m:GetAttribute("chickenSize")
		-- only "idle" -- once a guard picks it up its position is a lerp along a
		-- trip, so a cached pivot sends you where it WAS
		if m:IsDescendantOf(workspace) and zone and name and size and m:GetAttribute("insaneState") == "idle" then
			table.insert(out, {
				kind = "insane",
				zone = zone,
				key = "insane:" .. zone,
				model = m,
				name = name,
				variant = m:GetAttribute("chickenVariant") or "normal",
				size = size,
			})
		end
	end
	return out
end

local function best(cands, label)
	local score = priorityByLabel(label).score
	local now = os.clock()
	if preferInsane then
		local top, topScore = nil, -math.huge
		for _, c in ipairs(scanInsane()) do
			if wanted[c.zone] and (parked[c.key] or 0) <= now then
				local d = describe(c.name, c.variant, c.size, c.kind)
				if d and score(d) > topScore then
					top, topScore, c.desc = c, score(d), d
				end
			end
		end
		if top then
			return top
		end
	end
	local top, topScore = nil, -math.huge
	for _, c in ipairs(cands) do
		if wanted[c.zone] and (parked[c.key] or 0) <= now then
			local d = describe(c.name, c.variant, c.size, c.kind)
			if d then
				local s = score(d)
				if s > topScore then
					top, topScore, c.desc = c, s, d
				end
			end
		end
	end
	return top
end

-- travel ---------------------------------------------------------------------
-- There is no teleport cap and no post-steal lock: hops of 40/80/150/600 studs all
-- stuck, and three 60-stud hops 0.1s apart all stuck. What DOES fail is a long hop
-- that lands inside terrain, which physics then ejects you from. So: try the direct
-- hop, and fall back to chunks, which covered 1759 studs in 39 hops with none lost.
local function root()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function hop(pos)
	local c = player.Character
	local r = root()
	if not (c and r) then
		return false
	end
	pcall(function()
		c:PivotTo(CFrame.new(pos + LAND_OFFSET))
	end)
	task.wait(CHUNK_GAP)
	local now = root()
	return now ~= nil and (now.Position - pos).Magnitude < ARRIVE_TOLERANCE
end

local function goTo(pos, alive)
	if hop(pos) then
		return true
	end
	for _ = 1, FALLBACK_HOPS do -- bounded: never spin forever on a spot we cannot reach
		if alive and not alive() then
			return false
		end
		local r = root()
		if not r then
			task.wait(0.2) -- respawning
		else
			local left = (pos - r.Position).Magnitude
			if left < ARRIVE_TOLERANCE then
				return true
			end
			local step = (pos - r.Position).Unit * math.min(CHUNK, left)
			pcall(function()
				player.Character:PivotTo(CFrame.new(r.Position + step + LAND_OFFSET))
			end)
			task.wait(CHUNK_GAP)
		end
	end
	return false
end

-- The BaseBillb title reads "YOUR BASE" on every UNCLAIMED slot too, so it cannot
-- identify yours. The store knows; the pens confirm it.
local function producer()
	local ok, p = pcall(function()
		return require(player.PlayerScripts.modules.state.producer)
	end)
	return ok and p or nil
end

local function myBase()
	local bases = {}
	for _, b in ipairs(CS:GetTagged("Base")) do
		if b:IsDescendantOf(workspace) then
			table.insert(bases, b)
		end
	end

	local idx
	local p = producer()
	if p then
		local okS, sel = pcall(require, RS.shared.state.selectors.sessionSelectors.baseSelectors)
		if okS then
			local okG, v = pcall(function()
				return p:getState(sel.selectPlayerBase(player.Name))
			end)
			idx = okG and v or nil
		end
	end

	if not idx then -- fallback: my pens sit inside my base
		local pens = workspace:FindFirstChild("PenEggs")
		local bestN = 0
		for _, b in ipairs(bases) do
			local n = 0
			for _, pen in ipairs(pens and pens:GetChildren() or {}) do
				if penUT.isInside(b, pen:GetPivot().Position) then
					n += 1
				end
			end
			if n > bestN then
				idx, bestN = b:GetAttribute("index"), n
			end
		end
	end

	for _, b in ipairs(bases) do
		if idx and b:GetAttribute("index") == idx then
			local cf = penUT.getBounds(b)
			return b, cf and cf.Position or b:GetPivot().Position
		end
	end
	return nil, nil
end

-- Two things drive the character: the farm and the sell trip. One lock, taken per
-- sweep. Returns whether fn RAN, not whether it succeeded, and releases on a throw.
local busy = false
local function claim(fn)
	if busy then
		return false
	end
	busy = true
	local ok, err = pcall(fn)
	busy = false
	if not ok then
		warnf("claimed body errored: %s", tostring(err))
	end
	return true
end

-- farm -----------------------------------------------------------------------
-- "You need ..." strings exist in NO client script -- the notification remote is the
-- only place the server's real reason is ever worded. A refusal is also proof the
-- press reached the server, which rules out a whole class of bug in one line.
local lastNote, noteAt = nil, 0
local noteConn = remotes.game.notifications.showNotification:connect(function(a, b)
	lastNote, noteAt = string.format("%s %s", tostring(a), tostring(b)), os.clock()
end)

local function freshNote()
	if lastNote and os.clock() - noteAt < 3 then
		return lastNote
	end
	return nil
end

local misses = {} -- {[key] = consecutive nils}

-- An insane has no key to parse -- its position is read live from the model each
-- pass, since a guard may be walking it along a trip between our scan and our grab.
local function targetPos(c)
	if c.kind == "insane" then
		if not (c.model and c.model.Parent) then
			return nil
		end
		local p = c.model:GetPivot().Position
		return p.Magnitude > 1 and p or nil -- a partless model reports the origin
	end
	return c.pos
end

-- Three answers, not two. Conflating "refused" with "could not reach" makes a
-- streaming hiccup look like a server refusal, and an unreachable target then sits
-- at the head of a best-first queue blocking everything under it, silently.
local function grab(c, alive)
	local pos = targetPos(c)
	if not pos then
		return nil
	end
	if not goTo(pos, alive) then
		return nil
	end
	task.wait(SETTLE)
	local r = root()
	local live = targetPos(c) or pos -- an insane may have moved while we travelled
	local d = r and (r.Position - live).Magnitude or math.huge
	local range = (c.kind == "insane") and INSANE_RANGE or STEAL_RANGE
	if d > range then
		return nil -- firing from out of range returns false and reads as a refusal
	end
	lastNote = nil
	local ok, res
	if c.kind == "insane" then
		ok, res = req(remotes.game.nests.takeInsaneEgg:request(c.zone))
	else
		ok, res = req(remotes.game.nests.stealEgg:request(c.zone, c.pos))
	end
	if ok and res == true then
		return true
	end
	return false
end

-- Arriving at the base deposits by itself -- no dropChicken, no placeChicken.
-- equipBestChickens then places anything sitting in the backpack, which is the
-- game's own auto-place button and knows your slot count better than we would.
local function deposit(alive)
	local _, pos = myBase()
	if not pos then
		warnf("no base found, cannot deposit")
		return false
	end
	if not goTo(pos, alive) then
		return false
	end
	task.wait(SETTLE)
	pcall(function()
		remotes.data.base.equipBestChickens:fire()
	end)
	return true
end

local status = { target = "-", value = "-", weight = "-", rarity = "-", zone = "-", nest = "-", note = "-" }
local farm = { on = false, gen = 0 }
local priority = PRIORITIES[1].label
-- preferInsane is declared in the world section, above best(), since best() reads it

local mark, markAt = "idle", os.clock()
local function step(s)
	mark, markAt = s, os.clock()
end

local function setFarming(state)
	farm.on = state
	if not state then
		step("idle")
		return
	end
	farm.gen += 1
	local mine = farm.gen
	task.spawn(function()
		local cands, lastScan = {}, 0
		local function alive()
			return farm.on and farm.gen == mine
		end
		while alive() do
			if os.clock() - lastScan > SCAN_EVERY or #cands == 0 then
				step("scan")
				cands = scan()
				lastScan = os.clock()
			end
			local c = best(cands, priority)
			if not c then
				step("no target")
				task.wait(1)
			else
				status.target, status.zone, status.nest = c.desc.label, c.zone, c.key
				status.value = string.format("%d", c.desc.value)
				status.weight = string.format("%.1f", c.desc.weight)
				status.rarity = string.format("%d", c.desc.rarity)
				local ran = claim(function()
					step("grab " .. c.key .. " / press")
					local got = grab(c, alive)
					if got == true then
						misses[c.key] = nil
						status.note = "stole " .. c.desc.label
						step("grab " .. c.key .. " / home")
						deposit(alive)
					elseif got == false then
						misses[c.key] = nil
						parked[c.key] = os.clock() + PARK
						status.note = freshNote() or "refused"
					else
						misses[c.key] = (misses[c.key] or 0) + 1
						if misses[c.key] >= MISS_STRIKES then
							parked[c.key] = os.clock() + PARK
							misses[c.key] = nil
							say("parking %s -- could not reach it %d times", c.key, MISS_STRIKES)
						end
					end
				end)
				if not ran then
					task.wait(0.2)
				end
			end
		end
		if farm.gen == mine then -- only the current generation may switch it off
			farm.on = false
		end
	end)
end

-- A parked farm thread is indistinguishable from a dead one -- no error, no log,
-- toggle still lit. A separate thread is the only thing that can report it.
task.spawn(function()
	while true do
		task.wait(5)
		if farm.on and os.clock() - markAt > GRAB_TIMEOUT * 4 then
			warnf("stuck %.0fs at: %s", os.clock() - markAt, mark)
		end
	end
end)

-- base -----------------------------------------------------------------------
-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, WindUI = panel({
	game = "Steal a Chicken Egg",
	folder = "StealAChickenEgg", -- never rename: WindUI saves configs under this
	size = UDim2.fromOffset(520, 460),
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:egg-bold" })

local secFarm = Tab:Section({ Title = "Egg Farming", Icon = "solar:egg-bold", Box = true, Opened = true })

secFarm:Toggle({ Title = "Auto Farm Egg", Value = false, Callback = function(state)
	setFarming(state)
end })

-- takeInsaneEgg has never actually been fired -- it is dump-derived -- so it stays
-- off until proven. INSANE_RANGE is still unmeasured (see config comment at top);
-- this cannot be verified without a live session, so it ships at the nest distance
-- until someone with a running game raises it and records the working value.
secFarm:Toggle({
	Title = "Prefer Insane Chickens",
	Desc = "Untested remote -- watch F9 the first time",
	Value = false,
	Callback = function(state)
		preferInsane = state
	end,
})

local prioLabels = {}
for _, p in ipairs(PRIORITIES) do
	table.insert(prioLabels, p.label)
end
secFarm:Dropdown({
	Title = "Egg Priority",
	Values = prioLabels,
	Value = PRIORITIES[1].label,
	Callback = function(v)
		if priorityByLabel(v).label == v then
			priority = v -- ignore unknowns: Refresh re-fires this with "" on its own thread
		end
	end,
})

-- WindUI hands a Multi callback a list, a map, or the row tables back, depending on
-- the build panel.lua fetched. Reading a map as a list leaves the set empty, and an
-- empty set filters EVERYTHING out -- which is exactly what "the zone filter does
-- nothing" looks like.
local function ticked(v)
	local out = {}
	if type(v) ~= "table" then
		return out
	end
	for k, val in pairs(v) do
		if type(k) == "string" and val == true then
			out[k] = true -- map shape
		elseif type(val) == "string" then
			out[val] = true -- list shape
		elseif type(val) == "table" and type(val.Title) == "string" then
			out[val.Title] = true -- row shape
		end
	end
	return out
end

do -- self-check: all three shapes must produce the same set
	assert(ticked({ "forest", "abyss" }).forest, "list shape")
	assert(ticked({ forest = true }).forest, "map shape")
	assert(ticked({ { Title = "forest" } }).forest, "row shape")
	assert(next(ticked(nil)) == nil, "nil is empty, not everything")
end

local allZones = zones()
for _, z in ipairs(allZones) do
	wanted[z] = true -- default: the whole map
end
secFarm:Dropdown({
	Title = "Zones",
	Values = allZones,
	Value = allZones,
	Multi = true,
	Callback = function(v)
		local set = ticked(v)
		if next(set) == nil then
			return -- a cleared dropdown means "no targets ever"; keep the old set
		end
		table.clear(wanted) -- the loop holds `wanted` as an upvalue; never reassign
		for z in pairs(set) do
			wanted[z] = true
		end
	end,
})

local secDebug = Tab:Section({ Title = "Debug", Box = true, Opened = true })
secDebug:Button({ Title = "Scan now", Callback = function()
	for _, z in ipairs(zones()) do
		wanted[z] = true
	end
	local t0 = os.clock()
	local cands, ok = scan()
	say("scan ok=%s %d candidates in %.1fs", tostring(ok), #cands, os.clock() - t0)
	for _, label in ipairs({ "Highest Value", "Highest Weight", "Highest Rarity" }) do
		local b = best(cands, label)
		if b then
			say("  %-16s %s %s size=%.1f value=%d rarity=%d  %s",
				label, b.zone, b.desc.label, b.desc.weight, b.desc.value, b.desc.rarity, b.key)
		end
	end
end })

secDebug:Button({ Title = "Go to best", Callback = function()
	for _, z in ipairs(zones()) do
		wanted[z] = true
	end
	local cands = scan()
	local b = best(cands, "Highest Value")
	if not b then
		return say("no target")
	end
	local pos = targetPos(b) -- b.pos is nil for an insane candidate; it carries .model instead
	if not pos then
		return say("target %s has no position (not streamed in?)", b.key)
	end
	local ran = claim(function()
		local t0 = os.clock()
		local got = goTo(pos)
		local r = root()
		say("goTo %s -> %s in %.1fs, %.1f studs off", b.key, tostring(got), os.clock() - t0,
			r and (r.Position - pos).Magnitude or -1)
	end)
	if not ran then
		say("busy")
	end
end })

secDebug:Button({ Title = "Where is my base", Callback = function()
	local b, pos = myBase()
	say("base=%s at %s", b and tostring(b:GetAttribute("index")) or "NOT FOUND", tostring(pos))
end })

-- close ----------------------------------------------------------------------
local function stopAll()
	setFarming(false)
	pcall(function()
		noteConn()
	end)
end

Window:OnDestroy(function()
	stopAll()
	getgenv().stealChickenEggStop = nil
end)

getgenv().stealChickenEggStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().stealChickenEggStop = nil
end

say("ready -- steal range %d, %d zones", STEAL_RANGE, (function()
	local n = 0
	for _ in pairs(nestsIF.zoneAreas) do
		n += 1
	end
	return n
end)())
