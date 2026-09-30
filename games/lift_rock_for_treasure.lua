--[[ Lift Rock for Treasure -- lift the stones in order, take the best treasure, bank it (102555956950143)

     FARM  : one run = hop to spawn (banks + resets the run), hop into each stone's LiftZone
             in order and stand there until it lifts, then hop next to the best treasures of
             the stages you cleared, take them, hop back to spawn. No walking, no prompt hold.
             The server sends every slot's item the moment a stone starts, so rarity is known
             before anything is touched; each run re-rolls it, and "Min rarity" skips a run's
             pickups (straight back to spawn) when nothing in it is good enough.
     STAGE : Auto = the deepest stage whose stones lift within "Max lift seconds" at your
             Strength (lift time is Weight / Strength, so it deepens as you grow). Stones lift
             on their own while you stand in the zone; the game's own controller sends the
             training taps that grow Strength.
     TRAIN : Auto Tap fires TrainingTap at the server's ~30/s cap (it pays 300 a tap at 4 rebirths,
             from anywhere, never moves you) so it runs under the farm. Train at station stands you
             in the best non-gamepass station your rebirths allow (Train_4 x10 at 4 rebirths, ~3000
             per 0.55s); it stacks with the taps but needs the character, so it and the farm take
             turns. The x15/x25/x100 stations are gamepasses and are not used; PerformRebirth is
             not wired (a rebirth resets progress, that call is yours).
     BASE  : Auto place best Luck fires PlaceBestLuck when your inventory beats your weakest
             pedestal (probed: reseats all 12 in 0.9s from anywhere, Luck 902 -> 960). Auto
             upgrade base fires UpgradePlot when the next slot is affordable and unlocked (each
             plot level past 10 needs more rebirths; untested). Auto rebirth fires PerformRebirth
             when Level reaches the next Rebirth.Levels entry: irreversible, opt-in, and it
             prints before/after in F9 because what it resets is not in the dump.
     SELL  : SellItems on everything banked below a rarity you choose. Non-Normal variants and
             favourites are never sold. Off by default.
     PACK  : PurchaseUpgrade("Backpack") with cash, at most every 20s. Off by default. The
             Robux route (PrepareUpgradePurchase) and the SkipStage products are not wired.

     Probed: the server enforces stage order (no lift session until the stage before is
     cleared), enforces pickup range ("Move closer to the treasure.") and refuses a pickup
     until the stone is lifted ("Treasure is unavailable."), so stage 15 by skipping is not
     possible. Stage weights 1..15 run 100 .. 7.5e14, and lift time is Weight / Strength, so
     Strength (training) is what moves the Auto stage deeper.

     RightControl rolls it up to a bare Zegion bar, RightAlt hides it outright.
     Stop: getgenv().liftRockStop() (or the Unload button) ]]

-- config ---------------------------------------------------------------------
local MAX_LIFT = 12 -- seconds a run may spend standing in stones. Raise it to reach deeper stages per run
local ZONE_WAIT = 3 -- how long to wait for Started after hopping into a zone before hopping again
local ENTER_TRIES = 3 -- hops into one zone before the run gives up on that stage
local PICK_TRIES = 6 -- re-hops at one treasure while the server still says "Move closer"
local PICK_GAP = 0.12 -- wait between those. Raise it if range refusals keep repeating
local STALL_TIME = 1.5 -- seconds in a slow stone's zone with no Progress before we step out and back in
local REENTER_TRIES = 3 -- step-out/step-in attempts per stone
local REENTER_OUT = 25 -- studs to step back along z; the zone is 15 wide, so this is clear of it
local REENTER_DX = 12 -- studs along x between re-entry spots (the zone is 90 long in x)
local REENTER_SETTLE = 0.5 -- wait outside so the client's zone check registers the exit. Raise it if stalls repeat
local TAP_GAP = 1 / 30 -- seconds between taps. The server pays ~30/s sustained (+30 burst); probed: 422 sent in 3s paid 119, 86 sent paid 86. Faster is wasted
local STATION_SETTLE = 2 -- how long to wait for TrainingStation to take after hopping into a station before benching it
local BANK_WAIT = 2.5 -- how long to wait for the run to reset after hopping to spawn
local FLOOR_WAIT = 3 -- how long a hop waits for the floor to stream in before giving up (falling = death = lost backpack)
local CALL_TIMEOUT = 6 -- InvokeServer has none of its own; a parked pickup would park the farm
local UPGRADE_GAP = 20 -- seconds between backpack upgrade attempts
local RUN_GAP = 0.15 -- pause between runs
local FALL_DROP = 8 -- studs below the stage floor that count as "fell through the map"
-- ponytail: stage geometry measured from the manifest (Stage1 pivot z=-678.7, Stage15 z=684.9);
-- only used until the stage Model itself has streamed in, then its own pivot wins
local STAGE_X, STAGE_Y, STAGE1_Z, STAGE_DZ = 81.8385, 118.986, -678.7, 97.4
local ZONE_DZ = -48.8 -- LiftZone centre relative to the stage pivot (z)
-- ponytail: copy of Treasures' rarity order; a new rarity needs a line here
local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret", "Celestial", "Divine" }

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().liftRockStop then
	getgenv().liftRockStop() -- re-running must not stack a second panel/loop
end

local TR = RS:WaitForChild("Shared"):WaitForChild("Packages"):WaitForChild("TypedRemote")
local Feedback = TR:WaitForChild("RockLiftingFeedback", 10)
local Pickup = TR:WaitForChild("PickupStageTreasure", 10)
local Banked = TR:WaitForChild("StageTreasuresBanked", 10)
local SellItems = TR:WaitForChild("SellItems", 10)
local PurchaseUpgrade = TR:WaitForChild("PurchaseUpgrade", 10)
local TrainingTap = TR:WaitForChild("TrainingTap", 10)
local TrainingFeedback = TR:WaitForChild("TrainingFeedback", 10)
if not (Feedback and Pickup and Banked and SellItems and PurchaseUpgrade) then
	warn("[liftrock] remotes missing -- wrong game, or it was updated. Nothing started.")
	return
end
local Cfg = require(RS.Shared:WaitForChild("Config"))
local ITEMS, STONES = Cfg.Treasures.Items, Cfg.Stones
local stages = workspace:WaitForChild("Map"):WaitForChild("Stages")

local RANKOF = {}
for i, r in ipairs(RARITIES) do
	RANKOF[r] = i
end
assert(RANKOF.Divine > RANKOF.Mythic and RANKOF.Common == 1)

-- world ----------------------------------------------------------------------
local maxLift, stagePick, minRank, keepRank = MAX_LIFT, "Auto", 1, RANKOF.Legendary
local sellOn, packOn = false, false
local counts = { runs = 0, picked = 0, banked = 0, sold = 0, skipped = 0 }
local powerEst = 0 -- Rate * Weight of the last Started: the Strength the server really lifts with
local run = { started = {}, done = {}, stopped = {}, progress = {} } -- this run's Started payloads, cleared stages and last Stopped/Progress times, by StageId
local runStart, resetAt, bankedAt = 0, 0, 0
local backpackCap -- learned: successes before the server first refused a live treasure
local lastUpgrade = 0
local status = function() end -- replaced by the panel below

local seen = {}
local function note(msg)
	if not seen[msg] then
		seen[msg] = true
		print("[liftrock] " .. msg)
	end
end

local function strength()
	local ls = player:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild("Strength")
	return v and tonumber(v.Value) or 0
end

local function rankItems(items)
	local rows = {}
	for slot, it in pairs(items or {}) do
		local cfg = ITEMS[it.Key] or {}
		-- Exclusive (Robux-only) items carry no Value/Rarity in the config: they sort last, rank 0
		rows[#rows + 1] = { slot = slot, key = it.Key, rar = cfg.Rarity or "?", rank = RANKOF[cfg.Rarity] or 0, val = cfg.Value or 0, uuid = it.UUID }
	end
	table.sort(rows, function(a, b)
		return a.val > b.val
	end)
	return rows
end
do
	local t = rankItems({ a = { Key = "Rock", UUID = "x" }, b = { Key = "Crown", UUID = "y" } })
	assert(#t == 2 and t[1].key == "Crown" and t[1].rank > t[2].rank)
end

-- One stage's lift session is over once the server says Completed; Reset is the run ending
-- (hop to spawn, or a respawn); Banked is the temporary backpack landing in the inventory.
local conns = {}
table.insert(conns, Feedback.OnClientEvent:Connect(function(kind, p)
	if kind == "Started" and type(p) == "table" and p.StageId then
		run.started[p.StageId] = { p = p, t = os.clock() }
	elseif kind == "Completed" and type(p) == "table" and p.StageId then
		run.done[p.StageId] = true
	elseif kind == "Stopped" and type(p) == "table" and p.StageId then
		run.stopped[p.StageId] = os.clock()
	elseif kind == "Progress" and type(p) == "table" and p.StageId then
		run.progress[p.StageId] = os.clock()
	elseif kind == "Reset" then
		resetAt = os.clock()
	end
end))
table.insert(conns, Banked.OnClientEvent:Connect(function()
	bankedAt = os.clock()
end))

-- What the server actually paid for training: taps carry a screenPosition, station ticks don't.
local train = { sent = 0, paid = 0, station = 0, gained = 0 }
if TrainingFeedback then
	table.insert(conns, TrainingFeedback.OnClientEvent:Connect(function(kind, p)
		if kind == "Gain" and type(p) == "table" then
			train.gained += tonumber(p.gain) or 0
			if p.screenPosition ~= nil then
				train.paid += 1
			else
				train.station += 1
			end
		end
	end))
end

-- Below every stage floor (they all sit at STAGE_Y): we went through the map. Not a state any
-- lift can recover from, so it ends the run and the bank hop puts us back on spawn.
local function fell()
	local r = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if r and r.Position.Y < STAGE_Y - FALL_DROP then
		note(("fell below the map at (%.0f, %.0f, %.0f) -- ending the run, back to spawn"):format(r.Position.X, r.Position.Y, r.Position.Z))
		return true
	end
	return false
end

local function aborted()
	return resetAt > runStart or fell() -- the server ended the run under us (death, respawn), or we fell out of the world
end

-- movement: a hop only counts if there is floor under it -------------------
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true -- a streamed decal or sign is not a floor; only something we can stand on counts
local function hasFloor(pos)
	rayParams.FilterDescendantsInstances = { player.Character }
	return workspace:Raycast(pos + Vector3.new(0, 3, 0), Vector3.new(0, -25, 0), rayParams) ~= nil
end
local function stream(pos)
	local done = false
	task.spawn(function()
		pcall(function()
			player:RequestStreamAroundAsync(pos, 3)
		end)
		done = true
	end)
	local dl = os.clock() + 4 -- the request yields and its own timeout doesn't bound it
	while not done and os.clock() < dl do
		task.wait(0.1)
	end
end
local function tp(pos)
	local c = player.Character
	if not (c and c:FindFirstChild("HumanoidRootPart")) then
		return false
	end
	if not hasFloor(pos) then
		stream(pos)
		local dl = os.clock() + FLOOR_WAIT
		while not hasFloor(pos) and os.clock() < dl do
			task.wait(0.1)
		end
		if not hasFloor(pos) then
			return false
		end
		c = player.Character
		if not c then
			return false
		end
	end
	c:PivotTo(CFrame.new(pos))
	local r = c:FindFirstChild("HumanoidRootPart")
	if r then
		r.AssemblyLinearVelocity = Vector3.zero -- don't carry a fall or a walk into the new spot
	end
	return true
end
local function waitChar(alive)
	local dl = os.clock() + 10
	while alive() and os.clock() < dl and not (player.Character and player.Character:FindFirstChild("HumanoidRootPart")) do
		task.wait(0.2)
	end
end

local function stagePivot(s)
	local st = stages:FindFirstChild("Stage" .. s)
	local pv = st and st:GetPivot().Position
	if not pv or pv.Magnitude < 1 then -- a far Model replicates without parts; its pivot is the origin
		pv = Vector3.new(STAGE_X, STAGE_Y, STAGE1_Z + STAGE_DZ * (s - 1))
	end
	return pv
end
local spots = {}
local function zoneSpot(s)
	if not spots[s] then
		local pv = stagePivot(s)
		spots[s] = Vector3.new(pv.X, pv.Y + 4, pv.Z + ZONE_DZ) -- +4: stand on the floor inside the zone
	end
	return spots[s]
end
local homePos
local function spawnPos()
	local sp = workspace:FindFirstChild("SpawnLocation")
	if sp then
		homePos = sp.Position + Vector3.new(0, 3, 0)
	end
	return homePos
end

local function callTimed(remote, ...)
	local args, n = { ... }, select("#", ...)
	local done, out = false, nil
	task.spawn(function()
		out = table.pack(pcall(remote.InvokeServer, remote, table.unpack(args, 1, n)))
		done = true
	end)
	local dl = os.clock() + CALL_TIMEOUT
	while not done and os.clock() < dl do
		task.wait()
	end
	if not done then
		return false
	end
	return table.unpack(out, 1, out.n)
end

-- farm -----------------------------------------------------------------------
-- The deepest stage whose stones (all of them, cumulatively) lift inside maxLift seconds.
local function targetStage()
	if stagePick ~= "Auto" then
		return tonumber(stagePick) or 1
	end
	local p = math.max(powerEst, strength(), 1)
	local total, k = 0, 0
	while STONES["Stone" .. (k + 1)] do
		total += STONES["Stone" .. (k + 1)].Weight / p
		if total > maxLift and k >= 1 then
			break
		end
		k += 1
	end
	return math.max(k, 1)
end

local function enterStage(s, alive, dx)
	local pos = zoneSpot(s) + Vector3.new(dx or 0, 0, 0)
	for _ = 1, ENTER_TRIES do
		if not alive() or aborted() then
			return nil
		end
		local t0 = os.clock()
		if tp(pos) then
			while alive() and os.clock() < t0 + ZONE_WAIT and not aborted() do
				local rec = run.started[s]
				if rec then
					return rec.p
				end
				task.wait()
			end
		else
			task.wait(0.5)
		end
	end
	return nil
end

local function liftStage(s, st, alive)
	if run.done[s] then
		return true -- instant stones report Completed in the same breath as Started
	end
	local rate = st.Rate or 0
	local eta = rate > 0 and (1 - (st.Progress or 0)) / rate or math.huge
	if eta > maxLift * 1.5 then
		return false, ("stage %d needs %.0fs, over the %ds cap"):format(s, eta, maxLift)
	end
	local pos = zoneSpot(s)
	local spot = pos -- where we are standing now; each re-entry tries a different x along the zone's 90-stud length
	local entered, reentries = os.clock(), 0
	local dl = entered + eta * 1.5 + 3
	while alive() and not run.done[s] and os.clock() < dl do
		if aborted() then
			return false, "run reset"
		end
		-- The game's own controller sends Stop when the server's Started lands before ITS zone
		-- check has seen us arrive (RockLiftingController beginLift). The server then only
		-- starts a new session on a fresh entry, so a stalled stone means: step out, step in.
		local stopped = run.stopped[s] and run.stopped[s] >= entered
		local silent = os.clock() - entered > STALL_TIME and not (run.progress[s] and run.progress[s] >= entered)
		if (stopped or silent) and reentries < REENTER_TRIES then
			reentries += 1
			local r0 = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			note(("stage %d lift stalled (%s) at %s, spot %s; re-entering the zone"):format(
				s, stopped and "stopped" or "no progress", r0 and tostring(r0.Position) or "no root", tostring(spot)))
			run.started[s], run.stopped[s] = nil, nil
			tp(spot + Vector3.new(0, 0, -REENTER_OUT)) -- out of the 15-stud-wide zone
			task.wait(REENTER_SETTLE) -- the client's zone check has to see us leave before it will notice the next entry
			-- a different x each time: if a spot is somehow inside the stone's geometry, the next one isn't
			local dx = ({ REENTER_DX, -REENTER_DX, 2 * REENTER_DX })[reentries] or 0
			spot = pos + Vector3.new(dx, 0, 0)
			if not enterStage(s, alive, dx) then
				break
			end
			entered = os.clock()
			dl = entered + eta * 1.5 + 3
		else
			local r = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if r and (r.Position - spot).Magnitude > 5 then -- shoved out of the zone: put us back
				tp(spot)
			end
			task.wait(0.1)
		end
	end
	return run.done[s] == true, ("stage %d did not complete in time"):format(s)
end

-- true = taken, false = refused (msg), nil = treasure part not streamed in
local function slotPart(s, slot)
	local st = stages:FindFirstChild("Stage" .. s)
	if not st then
		stream(stagePivot(s))
		st = stages:WaitForChild("Stage" .. s, 2)
	end
	local folder = st and (st:FindFirstChild("ItemSpawns") or st:WaitForChild("ItemSpawns", 2))
	return folder and (folder:FindFirstChild(slot) or folder:WaitForChild(slot, 2))
end

local function pickRow(s, row, alive)
	local sp = slotPart(s, row.slot)
	if not sp then
		return nil
	end
	local msg
	for _ = 1, PICK_TRIES do
		if not alive() then
			return nil
		end
		tp(sp.Position + Vector3.new(0, 3, 0))
		local ok, res, why = callTimed(Pickup, s, row.slot, row.uuid)
		if ok and res then
			return true
		end
		msg = why
		if type(why) == "string" and why:lower():find("closer") then
			task.wait(PICK_GAP) -- our new position hasn't replicated yet: the retry IS the settle
		else
			return false, tostring(why or "no reply")
		end
	end
	return false, tostring(msg)
end

local function collect(doneStages, itemsBy, alive)
	local rows = {}
	for _, s in ipairs(doneStages) do
		for _, r in ipairs(itemsBy[s]) do
			if r.rank >= minRank then
				rows[#rows + 1] = { s = s, r = r }
			end
		end
	end
	table.sort(rows, function(a, b)
		return a.r.val > b.r.val
	end)
	local picked, strikes = {}, 0
	for _, e in ipairs(rows) do
		if not alive() or aborted() or strikes >= 2 then
			break
		end
		if backpackCap and #picked >= backpackCap then
			break
		end
		local ok, why = pickRow(e.s, e.r, alive)
		if ok then
			picked[#picked + 1] = e.r
			strikes = 0
		elseif ok == false then
			strikes += 1
			note("pickup refused: " .. why)
			if strikes == 1 and #picked > 0 and not why:lower():find("closer") then
				backpackCap = #picked -- the first live refusal after N takes is the cap
			end
		end
	end
	return picked, #rows
end

local function bank(alive)
	local sp = spawnPos()
	if not sp then
		return false
	end
	local t0 = os.clock()
	if not tp(sp) then
		return false
	end
	while alive() and os.clock() < t0 + BANK_WAIT and resetAt < t0 do
		task.wait(0.05)
	end
	task.wait(0.15) -- Banked trails Reset by a frame or two
	return resetAt >= t0
end

local DA
do
	local ok, mod = pcall(function()
		return require(game:GetService("StarterPlayer").StarterPlayerScripts.ClientModules.DataAggregation)
	end)
	DA = ok and mod or nil
end
local function sellBelow()
	local rep = DA and DA.GetReplica()
	local inv = rep and rep.Data and rep.Data.Inventory
	if not inv then
		note("no inventory replica -- auto sell can't see your items")
		return
	end
	local list = {}
	for _, it in pairs(inv) do
		local cfg = it.ItemType == "Treasure" and ITEMS[it.Key]
		local r = cfg and RANKOF[cfg.Rarity]
		if r and r < keepRank and it.Variant == "Normal" and not it.IsFavorite then
			list[#list + 1] = it
		end
	end
	if #list > 0 then
		pcall(SellItems.FireServer, SellItems, list)
		counts.sold += #list
	end
end

local function runOnce(alive)
	waitChar(alive)
	runStart = os.clock()
	run = { started = {}, done = {}, stopped = {}, progress = {} }
	local K = targetStage()
	local doneStages, itemsBy = {}, {}
	local t0 = os.clock()
	for s = 1, K do
		if not alive() or aborted() then
			break
		end
		status(("stage %d/%d: lifting"):format(s, K))
		local st = enterStage(s, alive)
		if not st then
			note(("stage %d never started (server order/streaming)"):format(s))
			break
		end
		local w = STONES["Stone" .. s] and STONES["Stone" .. s].Weight
		if w and st.Rate and st.Rate > 0 then
			powerEst = st.Rate * w
		end
		itemsBy[s] = rankItems(st.Items)
		local ok, why = liftStage(s, st, alive)
		if not ok then
			if alive() and why then
				note(why)
			end
			break
		end
		doneStages[#doneStages + 1] = s
	end

	local picked, offered = {}, 0
	if #doneStages > 0 and alive() and not aborted() then
		status("taking treasure")
		picked, offered = collect(doneStages, itemsBy, alive)
		if offered == 0 then
			counts.skipped += 1
		end
	end
	if not alive() then
		return
	end
	status("banking")
	bank(alive)
	if bankedAt >= runStart and #picked > 0 then
		counts.banked += #picked
	end
	counts.runs += 1
	counts.picked += #picked
	local names = {}
	for _, r in ipairs(picked) do
		names[#names + 1] = r.key .. "/" .. r.rar
	end
	print(("[liftrock] run %d: stages 1-%d, took %s, %.1fs"):format(counts.runs, #doneStages, #names > 0 and table.concat(names, ", ") or "nothing", os.clock() - t0))

	if sellOn and bankedAt >= runStart then
		task.wait(0.3) -- let the Inventory replica land
		sellBelow()
	end
	if packOn and os.clock() - lastUpgrade >= UPGRADE_GAP then
		lastUpgrade = os.clock()
		local ok, res = callTimed(PurchaseUpgrade, "Backpack")
		if ok and res then
			backpackCap = nil -- capacity changed: relearn it
			note("backpack upgraded")
		end
	end
	status("idle between runs")
end

local gen, on = 0, false
local farmToggle, stationToggle, stationOn -- the farm and the station both need the character: one at a time
local function setFarm(state)
	on = state
	gen += 1
	if not state then
		return
	end
	if stationOn and stationToggle then
		pcall(stationToggle.SetValue, stationToggle, false) -- re-enters setStation(false), which ends its loop
	end
	local mine = gen
	task.spawn(function()
		local function alive()
			return on and gen == mine
		end
		waitChar(alive)
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		homePos = homePos or (hrp and hrp.Position)
		bank(alive) -- fresh run: a half-lifted or already-cleared one would never send Started
		while alive() do
			-- pcall so one bad run (a streamed-out model, a respawn mid-hop) costs a run, not the farm
			local ok, err = pcall(runOnce, alive)
			if not ok then
				warn("[liftrock] run failed: " .. tostring(err))
				task.wait(1)
			end
			task.wait(RUN_GAP)
		end
		if not on then
			status("stopped") -- a restart owns the status line itself
		end
	end)
end

-- train ----------------------------------------------------------------------
-- Two independent sources of Strength, and they stack (probed): TrainingTap pays a flat gain
-- per tap from anywhere at ~30/s, and a station pays a tick every ~0.55s while you stand in
-- its TrainZone. Taps never move you, so they run under the farm; a station needs the
-- character, so it and the farm take turns.
local tapOn, tapGen, tapGap = false, 0, TAP_GAP
local function setTap(state)
	tapOn = state
	tapGen += 1
	if not state or not TrainingTap then
		return
	end
	local mine = tapGen
	task.spawn(function()
		while tapOn and tapGen == mine do
			train.sent += 1
			pcall(TrainingTap.FireServer, TrainingTap, Vector2.new(0.5, 0.5))
			task.wait(tapGap)
		end
	end)
end

-- Stations near spawn, best multiplier first. Gamepass stations (7-9) are deliberately not
-- used: the server refuses them without the pass and the game answers with a purchase prompt.
local stations = {}
do
	local area = workspace:WaitForChild("Map"):WaitForChild("TrainingArea", 5)
	for _, m in ipairs(area and area:GetChildren() or {}) do
		local cfg = m:GetAttribute("Id") and Cfg.Training[m:GetAttribute("Id")]
		local zone = cfg and not cfg.Gamepass and m:FindFirstChild("TrainZone", true)
		if zone then
			stations[#stations + 1] = { id = m:GetAttribute("Id"), mult = cfg.Multiplier, rebirths = cfg.RequiredRebirths or 0, pos = zone.Position + Vector3.new(0, 3, 0) }
		end
	end
	table.sort(stations, function(a, b)
		return a.mult > b.mult
	end)
end

local function rebirths()
	local rep = DA and DA.GetReplica()
	return rep and rep.Data and tonumber(rep.Data.Rebirths)
end

local stBenched = {}
local function bestStation()
	local rb = rebirths() -- unreadable: try them all, best first, and let the server's answer bench the refused
	for _, s in ipairs(stations) do
		if not stBenched[s.id] and (not rb or s.rebirths <= rb) then
			return s
		end
	end
	return nil
end

local stGen = 0
local function setStation(state)
	stationOn = state
	stGen += 1
	if not state then
		return
	end
	if on and farmToggle then
		pcall(farmToggle.SetValue, farmToggle, false) -- re-enters setFarm(false)
	end
	table.clear(stBenched)
	local mine = stGen
	task.spawn(function()
		local function alive()
			return stationOn and stGen == mine
		end
		waitChar(alive)
		status("training: looking for a station")
		while alive() do
			local s = bestStation()
			if not s then
				status("training: no station available to you")
				task.wait(2)
			elseif player:GetAttribute("TrainingStation") == s.id then
				status(("training: station %d (x%s)"):format(s.id, tostring(s.mult)))
				task.wait(0.5)
			else
				tp(s.pos)
				local dl = os.clock() + STATION_SETTLE
				while alive() and player:GetAttribute("TrainingStation") ~= s.id and os.clock() < dl do
					task.wait(0.1)
				end
				if alive() and player:GetAttribute("TrainingStation") ~= s.id then
					stBenched[s.id] = true -- the server said no (rebirths): step down to the next
					note(("station %d refused, trying the next"):format(s.id))
				end
			end
		end
	end)
end

-- base -----------------------------------------------------------------------
-- Three things that need no character: the pedestals, the plot's slot upgrade and the rebirth.
local function replicaData()
	local rep = DA and DA.GetReplica()
	return rep and rep.Data
end
local function loopOn(flag, gap, body)
	-- generation-counted toggle thread: off-then-on inside one gap must not leave two loops
	local mine = flag.gen + 1
	flag.gen = mine
	if not flag.on then
		return
	end
	task.spawn(function()
		while flag.on and flag.gen == mine do
			local ok, err = pcall(body)
			if not ok then
				warn("[liftrock] " .. tostring(err))
			end
			task.wait(gap)
		end
	end)
end

-- PlaceBestLuck: one call re-seats every pedestal with your best Luck items, from anywhere
-- (probed: 10 of 12 slots swapped in 0.9s, Luck 902 -> 960). The client-side gate below only
-- asks when your inventory holds something luckier than your weakest pedestal, plus a slow
-- refresh in case a variant's luck isn't visible from the base config.
local place = { on = false, gen = 0 }
local lastPlace = 0
local function pedestalFloorLuck()
	local d = replicaData()
	local plot = d and d.Plot
	if type(plot) ~= "table" then
		return nil
	end
	local lowest = math.huge
	for _, floor in pairs(plot) do
		if type(floor) == "table" then
			for name, slot in pairs(floor) do
				if type(name) == "string" and name:match("^Slot%d+$") and type(slot) == "table" then
					local it = slot.Item
					lowest = math.min(lowest, it and ((ITEMS[it.Key] or {}).LuckBonus or 0) or -1)
				end
			end
		end
	end
	return lowest ~= math.huge and lowest or nil
end
local function placeBest()
	local d = replicaData()
	local best = 0
	for _, it in pairs(d and d.Inventory or {}) do
		if it.ItemType == "Treasure" then
			best = math.max(best, (ITEMS[it.Key] or {}).LuckBonus or 0)
		end
	end
	local lowest = pedestalFloorLuck()
	if (not lowest or best > lowest + 1e-9 or os.clock() - lastPlace > 60) and os.clock() - lastPlace > 3 then
		lastPlace = os.clock()
		pcall(TR.PlaceBestLuck.FireServer, TR.PlaceBestLuck)
	end
end
local function setPlace(state)
	place.on = state
	loopOn(place, 5, placeBest)
end

-- UpgradePlot: the plot's next slot. Price, level and the rebirth lock are attributes on
-- BaseUpgrade.GUIPart, the same ones the game's own button reads. Fired from wherever we
-- stand; if the level doesn't move the console says so (the server may want us at the pad).
local base = { on = false, gen = 0 }
local function myGui()
	local map = workspace:FindFirstChild("Map")
	local plot = map and map:FindFirstChild("Plot_" .. player.UserId, true) -- by shape: the Plot1/Plot2 container isn't ours to name
	local bu = plot and plot:FindFirstChild("BaseUpgrade")
	return bu and bu:FindFirstChild("GUIPart")
end
local function upgradeBase()
	local gui, d = myGui(), replicaData()
	if not (gui and d) then
		return
	end
	local price, need, cur, max = tonumber(gui:GetAttribute("Price")), tonumber(gui:GetAttribute("RequiredRebirths")) or 0, tonumber(gui:GetAttribute("CurrentLevel")), tonumber(gui:GetAttribute("MaxLevel")) or Cfg.Plot.MaxLevel
	if not (price and cur) or price <= 0 or cur >= max or price > (tonumber(d.Cash) or 0) or need > (tonumber(d.Rebirths) or 0) then
		return
	end
	pcall(TR.UpgradePlot.FireServer, TR.UpgradePlot)
	task.wait(2)
	if tonumber(gui:GetAttribute("CurrentLevel")) == cur then
		note("UpgradePlot from where you stand did nothing (level still " .. cur .. ") -- the server may want you at the pad")
	else
		print(("[liftrock] plot upgraded: slots %d -> %d"):format(cur, tonumber(gui:GetAttribute("CurrentLevel")) or -1))
	end
end
local function setBase(state)
	base.on = state
	loopOn(base, 5, upgradeBase)
end

-- PerformRebirth: allowed when Data.Level reaches Rebirth.Levels[Rebirths+1].LevelRequired
-- (the game's own RebirthFrame test). What it resets isn't in the dump, so this is opt-in and
-- prints every number before and after the first time.
local reb = { on = false, gen = 0 }
local function rebirthNow()
	local d = replicaData()
	local rb, lvl = d and tonumber(d.Rebirths), d and tonumber(d.Level)
	local req = rb and Cfg.Rebirth.Levels[rb + 1]
	if not (req and lvl and lvl >= req.LevelRequired) then
		return
	end
	local before = { power = d.Power, level = lvl, cash = d.Cash, rebirths = rb }
	print(("[liftrock] rebirth #%d: Level %d, Power %s, Cash %s -- firing PerformRebirth"):format(rb + 1, lvl, tostring(d.Power), tostring(d.Cash)))
	pcall(TR.PerformRebirth.FireServer, TR.PerformRebirth)
	local dl = os.clock() + 4
	while os.clock() < dl and (tonumber(replicaData().Rebirths) or 0) <= rb do
		task.wait(0.2)
	end
	local a = replicaData()
	if (tonumber(a.Rebirths) or 0) > rb then
		print(("[liftrock] rebirthed: Rebirths %d -> %d | Power %s -> %s | Level %s -> %s | Cash %s -> %s"):format(
			rb, a.Rebirths, tostring(before.power), tostring(a.Power), tostring(before.level), tostring(a.Level), tostring(before.cash), tostring(a.Cash)))
	else
		note("PerformRebirth did nothing (Rebirths still " .. rb .. ")")
		task.wait(10) -- don't hammer a refusal
	end
end
local function setRebirth(state)
	reb.on = state
	loopOn(reb, 3, rebirthNow)
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Lift Rock for Treasure", size = UDim2.fromOffset(460, 360) })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "house")
local Farm = Tab:AddLeftGroupbox("Farm", "box")
local Info = Tab:AddRightGroupbox("Status", "activity")
local Extra = Tab:AddRightGroupbox("Sell and upgrades", "coins")

farmToggle = Farm:AddToggle("Farm", {
	Text = "Auto Farm",
	Tooltip = "Lift stones in order, take the best treasure, bank it. Hops, never walks. Turns the station off",
	Default = false,
	Callback = setFarm,
})

local stageValues = { "Auto" }
for i = 1, 15 do
	stageValues[#stageValues + 1] = tostring(i)
end
Farm:AddDropdown("Stage", {
	Text = "Deepest stage",
	Tooltip = "Auto = deepest whose stones lift within Max lift seconds at your Strength",
	Values = stageValues,
	Default = "Auto",
	Callback = function(v)
		if table.find(stageValues, v) then
			stagePick = v
		end
	end,
})
Farm:AddInput("MaxLift", {
	Text = "Max lift seconds",
	Tooltip = "Per run, all stones added up. Higher reaches deeper stages, slower runs",
	Default = tostring(MAX_LIFT),
	Numeric = true,
	Finished = true,
	Placeholder = "12",
	Callback = function(v)
		maxLift = math.max(1, tonumber(v) or MAX_LIFT)
	end,
})
Farm:AddDropdown("MinRarity", {
	Text = "Min rarity to take",
	Tooltip = "Anything below is left; a run with nothing this good goes straight back to spawn",
	Values = RARITIES,
	Default = "Common",
	Callback = function(v)
		minRank = RANKOF[v] or minRank
	end,
})

if TrainingTap then
	local Train = Tab:AddLeftGroupbox("Train", "dumbbell")
	Train:AddToggle("Tap", {
		Text = "Auto Tap",
		Tooltip = "TrainingTap at the server's ~30/s cap. Works from anywhere and never moves you, so it runs under the farm",
		Default = false,
		Callback = setTap,
	})
	stationToggle = Train:AddToggle("Station", {
		Text = "Train at station",
		Tooltip = "Stands in the best station your rebirths allow. Stacks with Auto Tap. Turns the farm off",
		Default = false,
		Callback = setStation,
	})
	Train:AddInput("TapGap", {
		Text = "Tap gap (s)",
		Tooltip = "Seconds between taps. Under 0.033 the server drops the extras; watch 'paid' in the status box",
		Default = string.format("%.3f", TAP_GAP),
		Numeric = true,
		Finished = true,
		Placeholder = "0.033",
		Callback = function(v)
			tapGap = math.max(0.01, tonumber(v) or TAP_GAP)
		end,
	})
end

local Base = Tab:AddLeftGroupbox("Base and rebirth", "castle")
Base:AddToggle("Place", {
	Text = "Auto place best Luck",
	Tooltip = "PlaceBestLuck whenever your inventory holds something luckier than your weakest pedestal. Works from anywhere",
	Default = false,
	Callback = setPlace,
})
Base:AddToggle("Base", {
	Text = "Auto upgrade base",
	Tooltip = "UpgradePlot when the next slot is affordable and your rebirths allow it. Spends Cash. Untested: watch F9",
	Default = false,
	Callback = setBase,
})
Base:AddToggle("Rebirth", {
	Text = "Auto rebirth",
	Tooltip = "PerformRebirth the moment your Level allows. IRREVERSIBLE and what it resets is not known -- prints before/after in F9",
	Default = false,
	Callback = setRebirth,
})

Extra:AddToggle("Sell", {
	Text = "Auto Sell",
	Tooltip = "Sells banked treasure below the rarity picked. Keeps favourites and non-Normal variants",
	Default = false,
	Callback = function(v)
		sellOn = v
	end,
})
Extra:AddDropdown("SellBelow", {
	Text = "Sell below",
	Values = { "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret", "Celestial", "Divine" },
	Default = "Legendary",
	Callback = function(v)
		keepRank = RANKOF[v] or keepRank
	end,
})
Extra:AddToggle("Pack", {
	Text = "Auto backpack upgrade",
	Tooltip = "Buys the next Backpack level with cash every 20s. The Robux route is not wired",
	Default = false,
	Callback = function(v)
		packOn = v
	end,
})

local line = Info:AddLabel("Status: idle", true)
local statsLine = Info:AddLabel("-", true)
-- The farm thread has been through task.wait, and a resumed thread lacks the capability to
-- write into the hidden GUI: the loop leaves the message in an upvalue and Heartbeat
-- (engine identity) writes it.
local pending
status = function(msg)
	pending = msg
end
local nextStats, lastSent, lastPaid, lastStation, lastGain = 0, 0, 0, 0, 0
Library:GiveSignal(RunService.Heartbeat:Connect(function()
	if pending then
		local msg = pending
		pending = nil
		line:SetText("Status: " .. msg)
	end
	local now = os.clock()
	if now >= nextStats then
		nextStats = now + 1
		-- Once a second: the numbers are mirrors the events keep, so this reads, never asks.
		local sent, paid, ticks, gain = train.sent - lastSent, train.paid - lastPaid, train.station - lastStation, train.gained - lastGain
		lastSent, lastPaid, lastStation, lastGain = train.sent, train.paid, train.station, train.gained
		statsLine:SetText(("Strength %s | stage %s\nruns %d | took %d | banked %d | sold %d | skipped %d%s\ntrain: taps sent %d/s, paid %d/s | station ticks %d/s | +%s/s"):format(
			tostring(math.floor(math.max(powerEst, strength()))),
			tostring(targetStage()),
			counts.runs,
			counts.picked,
			counts.banked,
			counts.sold,
			counts.skipped,
			backpackCap and (" | cap " .. backpackCap) or "",
			sent,
			paid,
			ticks,
			tostring(math.floor(gain))
		))
	end
end))

Info:AddButton({ Text = "Unload", Risky = true, Func = function()
	Library:Unload()
end })

-- Some clients still idle-kick a character that only teleports.
local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- close ----------------------------------------------------------------------
-- Nothing here mutes or edits the game, so stopping is: end the loop, drop the listeners.
local function stopAll()
	setFarm(false)
	setTap(false)
	setStation(false)
	setPlace(false)
	setBase(false)
	setRebirth(false)
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().liftRockStop = nil
end)

getgenv().liftRockStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().liftRockStop = nil
end
