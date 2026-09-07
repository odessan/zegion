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
local nestUT = require(RS.shared.utils.nestUT)
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
local function describe(name, variant, size)
	local def = chickenUT.getChicken(name, variant) -- NOT chickensIF[name]
	if not def then
		return nil
	end
	local okV, value = pcall(def.getSellValue, def, size)
	local rar = def:getRarity()
	return {
		label = def:getName(),
		value = okV and value or 0,
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
	for _, z in ipairs(zones()) do
		local ok, map = req(remotes.game.nests.getNestContents:request(z))
		if ok and type(map) == "table" then
			any = true
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
			parked[key] = nil -- rerolled away; stop remembering it
		end
	end
	return out, any
end

local preferInsane = false -- batch 2 wires the toggle to this; declared here because best reads it

local function best(cands, label)
	local score = priorityByLabel(label).score
	local now, top, topScore = os.clock(), nil, -math.huge
	for _, c in ipairs(cands) do
		if wanted[c.zone] and (parked[c.key] or 0) <= now then
			local d = describe(c.name, c.variant, c.size)
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
		c:PivotTo(CFrame.new(pos + Vector3.new(0, 3, 0)))
	end)
	task.wait(CHUNK_GAP)
	local now = root()
	return now ~= nil and (now.Position - pos).Magnitude < 12
end

local function goTo(pos, alive)
	if hop(pos) then
		return true
	end
	for _ = 1, 200 do -- bounded: never spin forever on a spot we cannot reach
		if alive and not alive() then
			return false
		end
		local r = root()
		if not r then
			task.wait(0.2) -- respawning
		else
			local left = (pos - r.Position).Magnitude
			if left < 12 then
				return true
			end
			local step = (pos - r.Position).Unit * math.min(CHUNK, left)
			pcall(function()
				player.Character:PivotTo(CFrame.new(r.Position + step + Vector3.new(0, 3, 0)))
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
		if b:GetAttribute("index") == idx then
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
	local ran = claim(function()
		local t0 = os.clock()
		local got = goTo(b.pos)
		local r = root()
		say("goTo %s -> %s in %.1fs, %.1f studs off", b.key, tostring(got), os.clock() - t0,
			r and (r.Position - b.pos).Magnitude or -1)
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
	-- later tasks add their loop flags here
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
