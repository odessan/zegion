--[[ Roll a Fisherman -- fishes, rolls, hires, places, collects, upgrades and sells (90920025162454)

     AUTO FISH  : casts at full power from your dock, shakes until the bite, then wins the
                  reel with an input list solved from the seed the bite carries -- the same
                  replay the server runs to judge you. Instant if the server takes it,
                  real time (~5s) if it doesn't; the first refusal decides for the session.
                  Also reels in your dock fishermen's hooks (every 2-5 min), in real time
     AUTO ROLL  : walks to your Roll button and rolls. With Auto Buy off it pauses while a
                  stand shows the threshold rarity or better, and rolls again once you've
                  hired it -- the toggle stays on
     AUTO BUY   : hires the rolled fishermen whose rarity you ticked -- cash only, never a
                  stand the game offers for Robux
     EQUIP BEST : the game's own EquipBest (best fishermen onto the dock, empty spots first;
                  best fish onto the stands) plus your best owned rod
     COLLECT    : every dock crate (EquipBest collects them as it goes) and every stand's
                  cash pad, touched from wherever you are
     UPGRADE    : buys each ticked upgrade the moment its next level is affordable
     CLAIMS     : daily reward, achievements and finished quests, each the moment it's ready;
                  Auto Rebirth (off by default -- it resets cash and spends fish) when the
                  game's own requirement check passes. Never the Robux skip products
     SELL       : sells inventory fish below the keep rarity, after EquipBest has moved the
                  good ones onto your stands. Favorites and "% BEST" fish are never sold

     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().rollFishermanStop() ]]

-- config ---------------------------------------------------------------------
-- The delays are also editable live in the Settings tab; these are the defaults.
local DELAY = {
	equip = 5, -- EquipBest is a "heavy" call: the server refills those at 1.5/s, 4 max
	collect = 3, -- stand cash pads; the dock crates ride on EquipBest
	sell = 10, -- inventory only fills as fast as the dock and your rod catch
	upgrade = 1, -- gated on your cash locally, so a pass that can't afford sends nothing
	roll = 0.8, -- floor between rolls; grows by ROLL_BACKOFF each time the server refuses
	claim = 20, -- daily / achievements / quests / rebirth; all gated locally, so slow is fine
}
local EQUIP_MIN_GAP = 2 -- collect and sell also call EquipBest; never closer than this
local ROLL_BACKOFF, ROLL_GAP_MAX = 0.5, 5
local ROLL_CONFIRM = 1.5 -- Data.Stats.Rolls moves ~0.1s after a good press (probed)
local HIRE_CONFIRM = 2
local HIRE_REACH = 4.5 -- studs in front of a stand's fisherman; the Hire prompt reaches ~6
local ROLL_REACH = 10 -- the Roll prompt reaches 12 (accepted at 8.5, refused at 36)
local WALK_TIMEOUT = 8
local ARRIVE = 2.5
local DOCK_SPOT = CFrame.new(0, 2.5, 33) -- plot-relative; where the probe cast from
local DOCK_RADIUS = 5
local ROD_KEY = "@Rod" -- Casting.Key: the hotbar key SelectSlot takes for your rod
local CHARGE_HOLD = 0.05 -- the server takes the fill we send (0.05s hold claiming 1 -> power 1)
local SHAKE_FIRST = 2.5 -- Casting.ShakeFirst: the game shows Shake this long after landing
local SHAKE_GAP = 0.7 -- Casting.ShakeGap 0.5 + the pop tween; raise if bites stop coming
local LAUNCH_TIMEOUT = 5
local BITE_TIMEOUT = 40 -- no bite by then: cancel and cast again
local RESULT_TIMEOUT = 12
local REEL_PAD = 0.25 -- real-time mode waits the simulated length plus this
local TOUCH_GAP = 0.1
local PAD_MIN = 1 -- a stand owing less than this isn't worth a touch
local PAY_CONFIRM = 0.6 -- how long a pad gets to pay before it counts as a miss
local TOUCH_STRIKES = 2 -- touch passes that paid nothing before the pads get walked instead
local WALK_COLLECT_EVERY = 20 -- walking takes you off the dock, so it waits for cash to pile up
local AFK_EVERY = 60

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer
local Data = player:WaitForChild("Data")

if getgenv and getgenv().rollFishermanStop then
	getgenv().rollFishermanStop() -- re-running must not stack a second panel/loop
end

-- world ----------------------------------------------------------------------
-- The game's Loader gives every module a metatable whose __index is the table of ALL
-- its modules and controllers. From an executor, require() shares the game's cache
-- (probed: "live, 183 modules"), so Reel, Fishermen, Upgrades and the controllers are
-- the game's own live tables, not copies.
local lib = getmetatable(require(RS.Modules.Gameplay.Content.Rarities))
lib = lib and lib.__index
if type(lib) ~= "table" or not lib.Reel then
	warn("[RollFisherman] the game's modules aren't reachable -- this executor's require() returns fresh copies")
	return
end

-- Every action goes through one remote, net_channel, as a scrambled table signed with a
-- per-session key and a sequence number. Net:Event(name):FireServer(...) is the game's own
-- send path and builds all of that for us; a hand-built packet would be one bad hash away
-- from a strike.
local NetFolder = RS.Modules.Util.Net
local Net = require(NetFolder)
local running = true
local warned = {}

local function fire(name, ...)
	-- Net:Event WaitForChild()s with no timeout; a renamed event would park the caller
	if not NetFolder:FindFirstChild(name) then
		if not warned[name] then
			warned[name] = true
			warn("[RollFisherman] no Net event '" .. name .. "' -- the game renamed it")
		end
		return false
	end
	return (pcall(function(...)
		Net:Event(name):FireServer(...)
	end, ...))
end

local pending -- drained into the Status row on Heartbeat (see gui)
local function say(msg)
	pending = msg
	print("[RollFisherman] " .. msg)
end

-- The server words its refusals ("Buy a fisherman first!", "Must be on a dock to fish!")
-- only in this popup, so it's kept for whoever wants to explain a failure.
local popup = { text = "", at = 0 }
local conns = {}
table.insert(
	conns,
	NetFolder:WaitForChild("Popup").OnClientEvent:Connect(function(kind, text)
		if kind == "Error" then
			popup.text, popup.at = tostring(text), os.clock()
		end
	end)
)
local function recentError(since)
	return popup.at >= since and popup.text or nil
end

local function root()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function humanoid()
	local c = player.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

local function myPlot()
	local plots = workspace:FindFirstChild("Scriptable")
	plots = plots and plots:FindFirstChild("Plots")
	plots = plots and plots:FindFirstChild("Buildings")
	for _, m in ipairs(plots and plots:GetChildren() or {}) do
		if tonumber(m:GetAttribute("Owner")) == player.UserId then
			return m
		end
	end
	return nil
end

local function posOf(x)
	if not x then
		return nil
	elseif x:IsA("ProximityPrompt") then
		return posOf(x.Parent)
	elseif x:IsA("Attachment") then
		return x.WorldPosition
	elseif x:IsA("BasePart") then
		return x.Position
	elseif x:IsA("Model") then
		return x:GetPivot().Position
	end
	return nil
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function distTo(x)
	local r, p = root(), posOf(x)
	return (r and p) and (r.Position - p).Magnitude or math.huge
end

-- The game ships a client anti-cheat (ReplicatedFirst.CRYABOUTIT) that snaps you back
-- and reports any move over 8 studs your velocity doesn't explain, so nothing here
-- teleports: every leg is walked. MoveTo only steers and gives up after ~8s, so it is
-- re-issued each beat.
local function walkTo(pos, alive)
	local deadline = os.clock() + WALK_TIMEOUT
	while os.clock() < deadline and alive() do
		local r, h = root(), humanoid()
		if not (r and h) or h.Health <= 0 then
			return false
		end
		if flat(pos - r.Position).Magnitude < ARRIVE then
			return true
		end
		h:MoveTo(pos)
		task.wait(0.25)
	end
	return false
end

-- Fishing parks you on the dock for a whole cast; rolling walks you to the Roll button.
-- One of them at a time, released on every path. Returns whether fn RAN.
local busy = false
local function claim(fn, alive)
	while busy do
		if not alive() then
			return false
		end
		task.wait(0.1)
	end
	busy = true
	local ok, err = pcall(fn)
	busy = false
	if not ok then
		warn("[RollFisherman] " .. tostring(err))
	end
	return true
end

local function rarityOrder(rarity)
	return lib.Rarities:Order(rarity)
end

local function ticked(values)
	local set = {}
	for k, v in pairs(values) do
		if type(v) == "string" then
			set[v] = true -- list form: 1 -> "Common"
		elseif type(v) == "table" and v.Title then
			set[v.Title] = true -- row form
		elseif v then
			set[k] = true -- map form: "Common" -> true
		end
	end
	return set
end
assert(ticked({ "Common", "Rare" }).Rare, "the list form ticks its names")
assert(ticked({ Common = true }).Common, "the map form ticks its keys")
assert(not ticked({ Common = false }).Common, "an unticked key in the map form stays off")

-- reel -----------------------------------------------------------------------
-- Reel.lua is a seeded simulation, and the server judges a catch by replaying your
-- inputs (Reel:Judge) from the seed the Bite hands you. So the winning input list is
-- found here, offline, and checked with that same Judge before it is sent. PD on the
-- bar's left edge; a few damping values, the shortest win kept. Offline over 400 seeds:
-- every one a judged win in 5.08s of game time (the design floor is 4.0s).
local Reel = lib.Reel
local function solve(seed, shape, width, sure)
	local best
	for _, kd in ipairs({ 0.2, 0.35, 0.5, 0.8 }) do
		local s = Reel:Begin(seed, shape, width, false)
		local lim, won = Reel:Limit(sure), nil
		while s.Steps < lim do
			local err = (Reel:FishAt(s) - s.Width / 2) - s.Left
			Reel:Frame(s, err - s.Velocity * kd > 0)
			won = Reel:Result(s, sure)
			if won ~= nil then
				break
			end
		end
		if won and (not best or s.Steps < best.Steps) then
			best = s
		end
	end
	return best
end

local reelWorks = pcall(function()
	local shape = Reel:Shape(8)
	local s = solve(7919, shape, Reel.Width, false)
	assert(s and Reel:Judge(7919, shape, Reel.Width, { Held = false, Flips = s.Flips, Steps = s.Steps }, false))
end)
if not reelWorks then
	warn("[RollFisherman] the reel solver no longer wins against the game's Reel module -- Auto Fish is off")
end

-- The game's own reel panel would open on a reel we answer and, with nobody holding,
-- submit a LOSS ~2.7s in -- ahead of a real-time answer. It also declines any reel that
-- arrives while another is open. So while Auto Fish runs it stays shut for every seeded
-- reel -- rod bites and dock hooks alike -- and this script answers them all.
local RC = lib.ReelController
local rcOpen0 = RC and rawget(RC, "Open")
local fishing = false
if rcOpen0 then
	RC.Open = function(self, p, ...)
		if fishing and reelWorks and type(p) == "table" and p.Seed then
			return
		end
		return rcOpen0(self, p, ...)
	end
end

-- Shape, width and cap the way ReelController:Open reads a reel payload. The width
-- must match the server's, or the replay drifts: the payload's when it names one,
-- else the panel's measured Capture width, as Open does.
local function reelParams(rl)
	local shape = (rl.Hop and rl.Rest) and { Hop = rl.Hop, Rest = rl.Rest } or Reel:Shape(rarityOrder(rl.Rarity))
	local width = type(rl.Width) == "number" and rl.Width or nil
	if not width then
		local ok, w = pcall(function()
			return RC:Width()
		end)
		width = ok and tonumber(w) or Reel.Width
	end
	return shape, width, rl.Sure == true
end

-- A dock fisherman's hook ("<Fisher> hooked onto a <fish>! ... help reel it in") comes
-- on Net.Reel every 2-5 min and waits minutes for you (Reel.Deadline 240-360s), so
-- there's nothing to win by racing it: always answered in real time, on its own thread
-- -- it needs no character, so it never waits on a cast. Hooks count as reeled catches,
-- so they roll for gold piles and contracts like a rod catch does.
local hooks = 0
table.insert(
	conns,
	NetFolder:WaitForChild("Reel").OnClientEvent:Connect(function(rl)
		if not (fishing and reelWorks and type(rl) == "table" and rl.Seed) then
			return
		end
		task.spawn(function()
			local shape, width, sure = reelParams(rl)
			local s = solve(rl.Seed, shape, width, sure)
			if not s then
				say("no winning reel for " .. tostring(rl.Fisher or "a dock") .. "'s hook")
				return
			end
			task.wait(s.Steps * Reel.Tick + REEL_PAD)
			-- sent even if Auto Fish went off meanwhile: the panel was shut when it came
			local source = type(rl.Source) == "string" and rl.Source or "Reel"
			fire(source, { Held = false, Flips = s.Flips, Steps = s.Steps }) -- Net: Reel({Held, Flips, Steps})
			hooks += 1
			say(
				string.format(
					"answered %s's hook on %s -- %d this session",
					tostring(rl.Fisher or "a fisherman"),
					tostring(rl.Named or rl.Id or "a fish"),
					hooks
				)
			)
		end)
	end)
)

-- fish -----------------------------------------------------------------------
-- Net.RAFCast: Charge -> Launch -> Landed -> Bite{Reel=...} -> Result{Won, Cooldown},
-- or Abort{reason}. Queued so a Launch and Landed arriving between polls both count.
local castQ = {}
table.insert(
	conns,
	NetFolder:WaitForChild("RAFCast").OnClientEvent:Connect(function(kind, id, x)
		if fishing then
			table.insert(castQ, { kind = kind, id = id, x = x })
		end
	end)
)

local function nextCast(timeout, alive)
	local deadline = os.clock() + timeout
	while alive() and os.clock() < deadline do
		local e = table.remove(castQ, 1)
		if e then
			return e
		end
		task.wait()
	end
	return nil
end

local reelAsap, asapWins, caught = true, 0, 0

-- one full cast; returns a reason when it ends without a result
local function castOnce(alive)
	local plot = myPlot()
	if not plot then
		return "you don't own a plot yet"
	end
	local spot = (plot:GetPivot() * DOCK_SPOT).Position
	local r = root()
	if not r or flat(spot - r.Position).Magnitude > DOCK_RADIUS then
		walkTo(spot, alive)
	end
	if Data.Held.Value ~= ROD_KEY then
		fire("SelectSlot", ROD_KEY) -- Net: SelectSlot(key)
		local t = os.clock() + 2
		repeat
			task.wait(0.1)
		until Data.Held.Value == ROD_KEY or os.clock() > t
	end

	table.clear(castQ)
	local t0 = os.clock()
	fire("RAFCastCharge") -- Net: RAFCastCharge()
	task.wait(CHARGE_HOLD)
	fire("RAFCastRelease", 1) -- Net: RAFCastRelease(fill); 1 is PERFECT, x2 catch luck

	repeat
		local e = nextCast(LAUNCH_TIMEOUT, alive)
		if not e then
			return alive() and ("no cast reply" .. (recentError(t0) and (": " .. recentError(t0)) or "")) or nil
		elseif e.kind == "Abort" then
			return "cast aborted: " .. tostring(e.x)
		end
	until e.kind == "Landed"

	-- A bite never came in 11s with nobody shaking, and came right after the 8th shake
	-- by hand: shaking is what earns it. Net: Shake()
	local nextShake, deadline, bite = os.clock() + SHAKE_FIRST, os.clock() + BITE_TIMEOUT, nil
	while alive() and os.clock() < deadline do
		local e = table.remove(castQ, 1)
		if e and e.kind == "Bite" then
			bite = e.x
			break
		elseif e and (e.kind == "Abort" or e.kind == "Result") then
			return "cast ended early: " .. tostring(e.x)
		end
		if os.clock() >= nextShake then
			fire("Shake")
			nextShake = os.clock() + SHAKE_GAP
		end
		task.wait()
	end
	if not bite then
		fire("RAFCastCancel") -- Net: RAFCastCancel()
		return alive() and ("no bite in " .. BITE_TIMEOUT .. "s -- raise SHAKE_GAP") or nil
	end

	local rl = type(bite) == "table" and bite.Reel
	if type(rl) ~= "table" or not rl.Seed then
		return "bite without a reel seed"
	end
	local shape, width, sure = reelParams(rl)
	local biteAt = os.clock()
	local s = solve(rl.Seed, shape, width, sure)
	if not s then
		return "no winning reel for seed " .. tostring(rl.Seed)
	end
	local asap = reelAsap
	if not asap then
		task.wait(math.max(s.Steps * Reel.Tick + REEL_PAD - (os.clock() - biteAt), 0))
	end
	-- Net: CastReel({Held, Flips, Steps}) -- the server replays it from the seed
	fire(rl.Source or "CastReel", { Held = false, Flips = s.Flips, Steps = s.Steps })

	local e
	repeat
		e = nextCast(RESULT_TIMEOUT, alive)
	until not e or e.kind == "Result" or e.kind == "Abort"
	if not (e and e.kind == "Result" and type(e.x) == "table") then
		return "no result for the reel"
	end
	if e.x.Won then
		caught += 1
		asapWins += asap and 1 or 0
		say(string.format("caught %s (%s) -- %d this session", tostring(e.x.Name or e.x.Fish), tostring(e.x.Rarity), caught))
	elseif asap and asapWins == 0 then
		-- never won instantly, so the server times the reel: wait it out from now on
		reelAsap = false
		say(string.format("instant reel refused -- reeling in real time (~%.1fs) from now on", s.Steps * Reel.Tick))
	else
		say("lost a reel (" .. tostring(e.x.Fish) .. ")")
	end
	task.wait(tonumber(e.x.Cooldown) or 1)
	return nil
end

-- roll & hire ----------------------------------------------------------------
local wantedBuy = {} -- rarity -> true
local rollStopAt = "Legendary"
local buyOn = false
local rollGap = DELAY.roll

local function rolled()
	-- Data.Rolled: {"G":guarantee,"R":[{"I":fisherId,"C":stock}, x3]}; "" = hired/empty
	local ok, t = pcall(HttpService.JSONDecode, HttpService, Data.Rolled.Value)
	return ok and type(t) == "table" and type(t.R) == "table" and t.R or {}
end

local function hirePrompt(plot, i)
	local stand = plot:FindFirstChild("RollStands")
	stand = stand and stand:FindFirstChild(tostring(i))
	for _, d in ipairs(stand and stand:GetDescendants() or {}) do
		if d:IsA("ProximityPrompt") and d.Name == "Hire" then
			return d
		end
	end
	return nil
end

-- Spot in front of a stand, on the Roll button's side: within Hire reach of the
-- fisherman and within Roll reach of the button, so a roll-and-hire pass never
-- walks back.
local function hireSpot(prompt, button)
	local p, b = posOf(prompt), button.Position
	local dir = flat(b - p)
	dir = dir.Magnitude > 0.1 and dir.Unit or Vector3.new(0, 0, -1)
	return Vector3.new(p.X, b.Y, p.Z) + dir * HIRE_REACH
end

-- Hire prompts: fireproximityprompt, in range. Two ways it could bill you, both refused:
-- the stand the game sells for Robux ("Buy with Robux"), and a fisherman you can't
-- afford, which the game answers with the same Robux offer.
local function hire(plot, button, i, def, alive)
	local prompt = hirePrompt(plot, i)
	if not prompt or not prompt.Enabled or prompt.ActionText:lower():find("robux") then
		return false
	end
	local price = lib.Fishermen:Price(def, Data)
	if price > Data.Cash.Value then
		say(string.format("can't afford %s (%s$)", def.Name, tostring(price)))
		return false
	end
	walkTo(hireSpot(prompt, button), alive)
	if distTo(prompt) > prompt.MaxActivationDistance then
		say("couldn't get in reach of stand " .. i)
		return false
	end
	local before = Data.Stats.Hired.Value
	pcall(fireproximityprompt, prompt)
	local t = os.clock() + HIRE_CONFIRM
	repeat
		task.wait(0.1)
	until Data.Stats.Hired.Value ~= before or os.clock() > t
	if Data.Stats.Hired.Value ~= before then
		say(string.format("hired %s (%s)", def.Name, def.Rarity))
		return true
	end
	return false
end

-- The stand holding the best rolled fisherman at or above the stop rarity, as a message.
local function worthStopping(list)
	local best, bestI
	for i, entry in ipairs(list) do
		local def = entry.I and entry.I ~= "" and lib.Fishermen:Find(entry.I)
		if def and rarityOrder(def.Rarity) >= rarityOrder(rollStopAt) and (not best or rarityOrder(def.Rarity) > rarityOrder(best.Rarity)) then
			best, bestI = def, i
		end
	end
	return best and string.format("%s (%s) on stand %d", best.Name, best.Rarity, bestI) or nil
end

-- The Rolls counter and the Rolled result are two values, and reading Rolled the moment
-- the counter moved could read the PREVIOUS roll -- which is how a Mythical got rolled
-- over with the stop set at Legendary. rollSeen counts Rolled writes so a press waits
-- for its own result, and the stands are judged from the live value before every press.
local rollSeen = 0
table.insert(
	conns,
	Data.Rolled.Changed:Connect(function()
		rollSeen += 1
	end)
)

-- one roll, then the hires it earned. Returns a reason to stop Auto Roll, or nil.
local lastHold -- the hold message last shown, so a paused roll says it once
local function rollOnce(alive)
	-- With Auto Buy off, a stand at or above the stop rarity pauses rolling rather than
	-- ending it: the next roll would throw that stand away. Hire it by hand and the
	-- stand empties, this clears, and rolling picks up on the next pass.
	local hold = not buyOn and worthStopping(rolled())
	if hold then
		if hold ~= lastHold then
			lastHold = hold
			say(hold .. " -- paused; hire it and rolling resumes")
		end
		return nil
	elseif lastHold then
		lastHold = nil
		say("stand cleared -- rolling again")
	end
	local plot = myPlot()
	local button = plot and plot:FindFirstChild("RollButton")
	local prompt = button and button:FindFirstChild("Roll")
	if not prompt then
		return "no Roll button on your plot"
	end
	if distTo(button) > ROLL_REACH then
		local s1 = hirePrompt(plot, 1)
		walkTo(s1 and hireSpot(s1, button) or button.Position, alive)
	end
	local before, seen, t0 = Data.Stats.Rolls.Value, rollSeen, os.clock()
	pcall(fireproximityprompt, prompt) -- the Roll prompt; no remote behind it
	repeat
		task.wait(0.05)
	until rollSeen ~= seen or os.clock() - t0 > ROLL_CONFIRM
	-- The counter moved but Rolled didn't: identical result string (three commons over
	-- three commons) or a late write. Give the write a moment before deciding on stale data.
	if rollSeen == seen and Data.Stats.Rolls.Value ~= before then
		task.wait(0.3)
	end
	if Data.Stats.Rolls.Value == before and rollSeen == seen then
		local why = recentError(t0)
		if why and why:lower():find("first") then
			return why -- "Buy a fisherman first!": the next roll needs a hire
		end
		rollGap = math.min(ROLL_GAP_MAX, rollGap + ROLL_BACKOFF)
		return nil
	end

	if not buyOn then
		return nil -- the next pass judges this roll before pressing again
	end
	for i, entry in ipairs(rolled()) do
		local def = entry.I and entry.I ~= "" and lib.Fishermen:Find(entry.I)
		if def and wantedBuy[def.Rarity] then
			hire(plot, button, i, def, alive)
		end
	end
	return nil
end

-- base -----------------------------------------------------------------------
-- Net: EquipBest() -- probed from 36 studs off: "Placed 4 fish and 5 fishermen -
-- Collected 7 fish!". It is the game's own best-first placement (dock and stands, empty
-- spots first) AND the only free collect-all for the dock crates. Shared by three
-- toggles, so it's gated here rather than in each loop.
local lastEquip = -math.huge
local function equipBest()
	if os.clock() - lastEquip < EQUIP_MIN_GAP then
		return
	end
	lastEquip = os.clock()
	fire("EquipBest")
end

local function bestRod()
	-- Rods.List runs weakest to strongest (Distance 30 .. 360); Data.Rods holds what you own
	local best
	for _, r in ipairs(lib.Rods.List) do
		local owned = Data.Rods:FindFirstChild(r.Id)
		if owned and owned.Value == true and (not best or (r.Distance or 0) > (best.Distance or 0)) then
			best = r
		end
	end
	return best
end

local function equipPass()
	equipBest()
	local rod = bestRod()
	if rod and Data.EquippedRod.Value ~= rod.Id then
		fire("EquipRod", rod.Id) -- Net: EquipRod(id)
		say("equipped " .. tostring(rod.Name))
	end
end

-- What a stand owes you. Data.Stands.<n>.Banked is NOT it: Banked only moves when the
-- stand is re-seated (EquipBest folds the accrued cash into it and resets Since), and
-- in between the money accrues from Since at the fish's rate -- Stands:Pending. So
-- Banked + Pending is what a pad pays, it survives an EquipBest unchanged, and it only
-- drops when you're paid.
local function owed(stand)
	local banked, since, id = stand:FindFirstChild("Banked"), stand:FindFirstChild("Since"), stand:FindFirstChild("Id")
	local variant = stand:FindFirstChild("Variant")
	local pend = 0
	if since and id and id.Value ~= "" then
		local ok, x = pcall(
			lib.Stands.Pending,
			lib.Stands,
			id.Value,
			since.Value,
			math.floor(workspace:GetServerTimeNow()),
			variant and variant.Value,
			Data
		)
		pend = ok and tonumber(x) or 0
	end
	return (banked and banked.Value or 0) + pend
end

-- Stand money is paid by stepping on that stand's pad (MoneyButtons.TopPart.<n>, a
-- server Touched -- no client script handles it). A touch from afar is tried first; if
-- the server wants you actually on the pad, those pay nothing and the pads get walked.
local padMode, touchStrikes, lastWalk = "touch", 0, -math.huge

local function padsOwing(plot)
	local pads = plot:FindFirstChild("MoneyButtons")
	pads = pads and pads:FindFirstChild("TopPart")
	local list = {}
	for _, stand in ipairs(Data.Stands:GetChildren()) do
		local pad = pads and pads:FindFirstChild(stand.Name)
		local due = owed(stand)
		if pad and due >= PAD_MIN then
			list[#list + 1] = { pad = pad, stand = stand, before = due }
		end
	end
	return list
end

local function paid(p)
	return owed(p.stand) < p.before * 0.5
end

local function touchPads(list)
	local r = root()
	if not r then
		return 0
	end
	for _, p in ipairs(list) do
		firetouchinterest(r, p.pad, 0)
	end
	task.wait(TOUCH_GAP)
	for _, p in ipairs(list) do
		firetouchinterest(r, p.pad, 1)
	end
	task.wait(PAY_CONFIRM)
	local n = 0
	for _, p in ipairs(list) do
		n += paid(p) and 1 or 0
	end
	return n
end

local function walkPads(list, alive)
	local n = 0
	while #list > 0 and alive() do
		-- always the nearest pad left, so a row is walked end to end once
		table.sort(list, function(a, b)
			return distTo(a.pad) < distTo(b.pad)
		end)
		local p = table.remove(list, 1)
		walkTo(p.pad.Position, alive)
		local t = os.clock() + PAY_CONFIRM
		repeat
			task.wait(0.05)
		until paid(p) or os.clock() > t
		n += paid(p) and 1 or 0
	end
	return n
end

local function collectPass(alive)
	equipBest() -- the dock crates
	local plot = myPlot()
	local list = plot and padsOwing(plot) or {}
	if #list == 0 then
		return
	end
	if padMode == "touch" and firetouchinterest then
		if touchPads(list) > 0 then
			touchStrikes = 0
			return
		end
		touchStrikes += 1
		if touchStrikes < TOUCH_STRIKES then
			return
		end
		padMode = "walk"
		say("touching stand pads from afar pays nothing here -- walking over them instead")
	end
	if os.clock() - lastWalk < WALK_COLLECT_EVERY then
		return
	end
	lastWalk = os.clock()
	local n = 0
	claim(function()
		n = walkPads(list, alive)
	end, alive)
	say(
		n > 0 and string.format("collected %d stand%s", n, n == 1 and "" or "s")
			or "walked the stand pads and nothing paid -- tell me what the pads do by hand"
	)
end

local wantedUpgrades = {} -- upgrade key -> true
local function upgradePass(alive)
	for _, u in ipairs(lib.Upgrades:Visible()) do
		if not alive() then
			return
		end
		local cost = wantedUpgrades[u.Key] and lib.Upgrades:Next(Data, u)
		if cost and cost <= Data.Cash.Value then
			local lvl = lib.Upgrades:Level(Data, u.Key)
			fire("BuyUpgrade", u.Key) -- Net: BuyUpgrade(key)
			local t = os.clock() + 1.5
			repeat
				task.wait(0.1)
			until lib.Upgrades:Level(Data, u.Key) ~= lvl or os.clock() > t
			if lib.Upgrades:Level(Data, u.Key) ~= lvl then
				say(string.format("%s -> level %d", u.Name, lib.Upgrades:Level(Data, u.Key)))
			end
		end
	end
end

local keepFrom = "Legendary" -- "None" sells every rarity the game lets you sell
local function sellPass(alive)
	-- move the best fish onto the stands first, so what's left in the bag is the rest
	equipBest()
	task.wait(1)
	local favs = Data:FindFirstChild("Favorites")
	local keep = keepFrom ~= "None" and rarityOrder(keepFrom) or math.huge
	for _, stack in ipairs(Data.Inventory.Fish:GetChildren()) do
		if not alive() then
			return
		end
		local id = lib.Stacks:Split(stack.Name)
		local def = lib.Fish:Find(id)
		local fav = favs and favs:FindFirstChild(stack.Name)
		if
			def
			and not (fav and fav.Value == true)
			and lib.Rarities:Sellable(def.Rarity)
			and not lib.Fish:Percent(def)
			and rarityOrder(def.Rarity) < keep
		then
			fire("SellStack", stack.Name) -- Net: SellStack(key); works from anywhere (probed)
			task.wait(0.15)
		end
	end
end

-- claims ---------------------------------------------------------------------
-- Free progression remotes. Each pass is gated on the game's own modules reading Data, so
-- a pass with nothing to claim sends nothing. Never wired: SkipRebirth / ResetQuests /
-- MutationRerolls -- those are Robux products (Rebirth.SkipProducts, Quests.Product).
local function dailyPass()
	local lc = Data:FindFirstChild("Daily") and Data.Daily:FindFirstChild("LastClaim")
	-- no LastClaim row: can't tell, the server refuses a too-early claim for free
	if lc and lib.Daily and lib.Daily:Remaining(lc.Value) > 0 then
		return
	end
	local before = lc and lc.Value
	fire("ClaimDaily")
	if lc then
		local t = os.clock() + 1.5
		repeat
			task.wait(0.1)
		until lc.Value ~= before or os.clock() > t
		if lc.Value ~= before then
			say("claimed the daily reward")
		end
	end
end

local function achievementPass()
	local ctl = lib.AchievementController
	local ready = true -- ponytail: no controller to ask -> fire on the beat, server ignores an empty claim
	if ctl and ctl.Achievements and ctl.Look then
		ready = false
		for _, a in ipairs(ctl.Achievements.List) do
			if ctl:Look(a) == "Done" then
				ready = true
				break
			end
		end
	end
	if ready then
		fire("AchievementClaimAll")
	end
end

local function questPass(alive)
	local Q = lib.Quests
	if not Q then
		return
	end
	for _, id in ipairs(Q:Ids(Data)) do
		if not alive() then
			return
		end
		local def = Q:Find(id)
		if def and not Q:Claimed(Data, id) and Q:Progress(Data, id) >= def.Target then
			fire(Q.ClaimEvent, id) -- Net: QuestClaim(id)
			say("claimed quest " .. def.Name)
			task.wait(0.5)
		end
	end
end

local function rebirthPass()
	local R = lib.Rebirth
	if not R then
		return
	end
	local lvl = R:Level(Data)
	if R:Maxed(lvl) or not R:Check(Data) then
		return
	end
	fire("Rebirth")
	local t = os.clock() + 3
	repeat
		task.wait(0.2)
	until R:Level(Data) ~= lvl or os.clock() > t
	if R:Level(Data) ~= lvl then
		say("rebirthed -> " .. R:Level(Data))
	end
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window = panel({ game = "Roll a Fisherman", folder = "RollAFisherman", size = UDim2.fromOffset(520, 460) })
if not Window then
	running = false
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	if rcOpen0 then
		RC.Open = rcOpen0
	end
	return
end

local stoppers = {}

-- A looping toggle with its own generation counter: off-then-on inside one delay can't
-- leave the old thread alive, and only the current generation may switch the row off.
local function loopToggle(sec, opts)
	local on, gen, row = false, 0, nil
	local function kill()
		on = false
		gen += 1
		if opts.off then
			opts.off()
		end
	end
	row = sec:Toggle({
		Title = opts.title,
		Desc = opts.desc,
		Value = false,
		Callback = function(state)
			if not state then
				kill()
				return
			end
			local refusal = opts.check and opts.check()
			if refusal then
				say(refusal)
				task.defer(function()
					pcall(row.Set, row, false)
				end)
				return
			end
			on = true
			gen += 1
			local mine = gen
			if opts.on then
				opts.on()
			end
			local function alive()
				return running and on and gen == mine
			end
			task.spawn(function()
				while alive() do
					local ok, why = pcall(opts.body, alive)
					if not ok then
						warn("[RollFisherman] " .. opts.title .. ": " .. tostring(why))
					elseif why and alive() then
						-- the loop asked to stop, with a reason the user should read
						kill()
						pcall(row.Set, row, false)
						say(why)
						return
					end
					task.wait(opts.delay())
				end
			end)
		end,
	})
	table.insert(stoppers, kill)
	return row
end

local rarityKeys, rollRarities = {}, {}
for _, r in ipairs(lib.Rarities.List) do
	if lib.Fish:Exists(r.Key) then
		table.insert(rarityKeys, r.Key)
	end
	if lib.Rolling:Exists(r.Key) then
		table.insert(rollRarities, r.Key)
	end
end

local Farm = Window:Tab({ Title = "Farm", Icon = "solar:home-2-bold" })
local line = Farm:Paragraph({ Title = "Status", Desc = "idle" })

local fishSec = Farm:Section({ Title = "Fishing", Icon = "solar:bolt-circle-bold", Box = true, BoxBorder = true, Opened = true })
loopToggle(fishSec, {
	title = "Auto Fish",
	desc = "Walks to your dock and casts, shakes and reels on its own, and reels in your dock fishermen's hooks",
	check = function()
		return not reelWorks and "the reel solver is broken for this game version" or nil
	end,
	on = function()
		fishing = true
	end,
	off = function()
		fishing = false
	end,
	body = function(alive)
		local why
		claim(function()
			why = castOnce(alive)
		end, alive)
		if not alive() then
			fire("RAFCastCancel") -- switched off mid-cast: don't leave the line in the water
		elseif why then
			say(why)
			if why:find("plot") then
				return why
			end
			task.wait(1)
		end
		return nil
	end,
	delay = function()
		return 0
	end,
})

local rollSec = Farm:Section({ Title = "Rolling", Icon = "solar:refresh-circle-bold", Box = true, BoxBorder = true, Opened = true })
rollSec:Dropdown({
	Title = "Auto Roll pauses at",
	Desc = "With Auto Buy off, a stand showing this rarity or better pauses rolling until you hire it",
	Values = rollRarities,
	Value = rollStopAt,
	Callback = function(v)
		if table.find(rollRarities, v) then
			rollStopAt = v
		end
	end,
})
rollSec:Dropdown({
	Title = "Auto Buy rarities",
	Desc = "Hired as they roll, cash only",
	Values = rollRarities,
	Value = {},
	Multi = true,
	AllowNone = true,
	Callback = function(picked)
		table.clear(wantedBuy)
		for k in pairs(ticked(picked)) do
			wantedBuy[k] = true
		end
	end,
})
loopToggle(rollSec, {
	title = "Auto Roll",
	desc = "Walks to your Roll button and keeps rolling",
	check = function()
		return not fireproximityprompt and "this executor has no fireproximityprompt -- can't press Roll" or nil
	end,
	on = function()
		rollGap, lastHold = DELAY.roll, nil
	end,
	body = function(alive)
		local why
		claim(function()
			why = rollOnce(alive)
		end, alive)
		return why
	end,
	delay = function()
		return rollGap
	end,
})
rollSec:Toggle({
	Title = "Auto Buy",
	Desc = "Auto Roll hires the ticked rarities instead of stopping on them",
	Value = false,
	Callback = function(state)
		buyOn = state
		if state and next(wantedBuy) == nil then
			say("Auto Buy is on but no rarity is ticked -- nothing will be hired")
		end
	end,
})

local Base = Window:Tab({ Title = "Base", Icon = "solar:box-bold" })
local baseSec = Base:Section({ Title = "Dock and stands", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })
loopToggle(baseSec, {
	title = "Equip best",
	desc = "Best fishermen onto the dock (empty spots first), best fish onto the stands, best owned rod",
	body = function()
		equipPass()
	end,
	delay = function()
		return DELAY.equip
	end,
})
loopToggle(baseSec, {
	title = "Auto Collect",
	desc = "Dock crates and stand cash; walks over the cash pads if touching them from afar doesn't pay",
	body = collectPass,
	delay = function()
		return DELAY.collect
	end,
})

local upSec = Base:Section({ Title = "Upgrades", Icon = "solar:arrow-up-bold", Box = true, BoxBorder = true, Opened = true })
local upNames = {}
for _, u in ipairs(lib.Upgrades:Visible()) do
	table.insert(upNames, u.Key)
	wantedUpgrades[u.Key] = true
end
upSec:Dropdown({
	Title = "Upgrades to buy",
	Values = upNames,
	Value = upNames,
	Multi = true,
	AllowNone = true,
	Callback = function(picked)
		table.clear(wantedUpgrades)
		for k in pairs(ticked(picked)) do
			wantedUpgrades[k] = true
		end
	end,
})
loopToggle(upSec, {
	title = "Auto Upgrade",
	desc = "Buys the next level of each ticked upgrade as soon as you can afford it",
	body = upgradePass,
	delay = function()
		return DELAY.upgrade
	end,
})

local sellSec = Base:Section({ Title = "Selling", Icon = "solar:dollar-bold", Box = true, BoxBorder = true, Opened = true })
local keepValues = { "None" }
for _, k in ipairs(rarityKeys) do
	table.insert(keepValues, k)
end
sellSec:Dropdown({
	Title = "Keep this rarity and up",
	Values = keepValues,
	Value = keepFrom,
	Callback = function(v)
		if table.find(keepValues, v) then
			keepFrom = v
		end
	end,
})
loopToggle(sellSec, {
	title = "Auto Sell",
	desc = "Sells fish below the keep rarity, after the best go onto your stands",
	body = sellPass,
	delay = function()
		return DELAY.sell
	end,
})

local Claims = Window:Tab({ Title = "Claims", Icon = "solar:gift-bold" })
local claimSec = Claims:Section({ Title = "Free rewards", Icon = "solar:gift-bold", Box = true, BoxBorder = true, Opened = true })
for _, spec in ipairs({
	{ "Auto Daily", "Claims the daily reward the moment its cooldown ends", dailyPass },
	{ "Auto Achievements", "Claim All whenever one is done", achievementPass },
	{ "Auto Quests", "Claims each of today's quests once its target is met", questPass },
}) do
	loopToggle(claimSec, {
		title = spec[1],
		desc = spec[2],
		body = spec[3],
		delay = function()
			return DELAY.claim
		end,
	})
end
local rebSec = Claims:Section({ Title = "Rebirth", Icon = "solar:refresh-bold", Box = true, BoxBorder = true, Opened = true })
loopToggle(rebSec, {
	title = "Auto Rebirth",
	desc = "Rebirths as soon as the game says you meet the requirements. It resets your cash and spends the required fish -- leave off until you want that. Never buys the Robux skip",
	check = function()
		return not lib.Rebirth and "the game's Rebirth module isn't reachable" or nil
	end,
	body = rebirthPass,
	delay = function()
		return DELAY.claim
	end,
})

local Settings = Window:Tab({ Title = "Settings", Icon = "solar:settings-bold" })
local delaySec = Settings:Section({ Title = "Delays (seconds)", Icon = "solar:clock-circle-bold", Box = true, BoxBorder = true, Opened = true })
for _, spec in ipairs({
	{ "equip", "Equip best", 2 },
	{ "collect", "Auto Collect", 1 },
	{ "sell", "Auto Sell", 2 },
	{ "upgrade", "Auto Upgrade", 0.5 },
	{ "roll", "Auto Roll floor", 0.3 },
	{ "claim", "Claims (daily, quests, rebirth)", 5 },
}) do
	local key, title, floor = spec[1], spec[2], spec[3]
	delaySec:Input({
		Title = title,
		Desc = "at least " .. floor,
		Value = tostring(DELAY[key]),
		Placeholder = tostring(DELAY[key]),
		Callback = function(v)
			local n = tonumber(v)
			if n then
				DELAY[key] = math.max(n, floor)
				if key == "roll" then
					rollGap = DELAY.roll
				end
			end
		end,
	})
end
delaySec:Input({
	Title = "Shake gap",
	Desc = "between Shake clicks while waiting for a bite; raise it if bites stop coming",
	Value = tostring(SHAKE_GAP),
	Placeholder = tostring(SHAKE_GAP),
	Callback = function(v)
		SHAKE_GAP = math.max(tonumber(v) or SHAKE_GAP, 0.3)
	end,
})

-- Drains whatever a loop thread last left: a resumed thread loses the capability to
-- write the panel, the Heartbeat doesn't.
table.insert(
	conns,
	RunService.Heartbeat:Connect(function()
		if pending == nil then
			return
		end
		local msg = pending
		pending = nil
		pcall(function()
			line:SetDesc(msg)
		end)
	end)
)

-- anti-afk -------------------------------------------------------------------
-- Idled is the last warning before the 20-minute kick; the 60s nudge keeps the timer
-- far from it in case one Idled is missed. ponytail: always on, no toggle.
local hasVU, vu = pcall(game.GetService, game, "VirtualUser")
local function nudge()
	if not hasVU then
		return
	end
	local cf = workspace.CurrentCamera and workspace.CurrentCamera.CFrame or CFrame.new()
	pcall(function()
		vu:CaptureController()
		vu:Button2Down(Vector2.new(0, 0), cf)
		task.wait(0.05)
		vu:Button2Up(Vector2.new(0, 0), cf)
	end)
end
table.insert(conns, player.Idled:Connect(nudge))
task.spawn(function()
	while running do
		task.wait(AFK_EVERY)
		nudge()
	end
end)

-- close ----------------------------------------------------------------------
local function stopAll()
	running = false
	for _, kill in ipairs(stoppers) do
		kill()
	end
	if rcOpen0 then
		RC.Open = rcOpen0 -- the game's reel panel opens for rod casts again
	end
	for _, c in ipairs(conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(conns)
end

Window:OnDestroy(function()
	stopAll()
	getgenv().rollFishermanStop = nil
end)
getgenv().rollFishermanStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().rollFishermanStop = nil
end

say("ready")
