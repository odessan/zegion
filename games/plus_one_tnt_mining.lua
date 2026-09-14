--[[ +1 TNT Mining -- blow up the best ore in the mine, train damage with no bomb in hand (101304595834078)

     MINE  : stand in a mine and flip it on. Every round it scores each block the game has
             in its local copy of the mine (MineStateService) by sell value per bomb it
             would take -- its own health over your Damage, plus the shaft down to it when
             it's buried -- and only counts ore it can reach on the TNT in hand, because a
             refill resets the mine and fills the shaft back in. Out of reach, it blasts the
             column above the ore open from the top; in reach, it goes to the nearest empty
             cell inside blast radius and drops only as many TNT as the block needs.
             Out of TNT it refills on the spot (no lobby trip). Drops are claimed by id right
             after each blast, so teleporting away doesn't leave them behind.
     TRAIN : 25 clicks a second, the server's whole allowance (a 25-token bucket refilling at
             25/s in PlayerSession.ApplyClicks), in one call. "Hold a bomb, not in a mine, no
             menu open" is only the client's click handler asking -- the server doesn't.
     SELL  : sells every non-favourited block on a timer, from wherever you are.

     Everything goes through the game's own client session (PlayerSession.GetClient()), so
     the prediction, the ignite-after-placement-ack and the explosion digest are the game's
     code, not a copy of it.

     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().tntMiningStop() ]]

-- config ---------------------------------------------------------------------
local FUSE_CAP = 4 -- max seconds to wait for a round of bombs to be gone. Fuse is 1s; raise on a laggy server.
local PICKUP = 0.25 -- seconds after the blast before claiming its drops. Raise if "drops claimed" lags what you break.
local LAYERS_PER_BOMB = 3 -- layers one blast clears (probe: fell 12 studs = 3 blocks). Lower if shafts run dry short of the ore.
local DIG_CANDIDATES = 60 -- best blocks per round that get a shaft costed
local CLAIM_TRIES = 3 -- rounds an unclaimed drop id is retried before it's given up on
local CLAIM_BATCH = 64 -- MineConfig.Collectible.PickupBatchSize; the server refuses bigger lists
local COLLECT_GRACE = 0.6 -- before a refill. The server's LeaveMine drops uncollected pickups; raise if blocks go missing.
local BENCH = 8 -- seconds a target sits out after a round that didn't hurt it (unreachable, stale mirror)
local EGG_SHARD_VALUE = 0 -- EggShard has no SellValue; give it one to make the miner chase shards
local STAND = 3 -- HumanoidRootPart height above the bomb (the probe's bomb at root - 3 worked)
local SETTLE = 0.1 -- plus 2x ping, after moving to a target. Raise if rounds keep benching good ore.
local TRAIN_BATCH = 25 -- the server bucket size; more is just refused
local TRAIN_GAP = 1 -- the bucket refills 25/s, so one batch a second is the cap
local SELL_GAP = 10
local REMOTE_TIMEOUT = 5 -- an InvokeServer with no answer would otherwise park a loop forever
local WATCHDOG = 20

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
-- Stats:GetValue needs capability a loop thread loses after its first yield, so Heartbeat
-- (which runs as us) samples it and the loop reads the number.
local pingMs = 150
local pinger = game:GetService("RunService").Heartbeat:Connect(function()
	pcall(function()
		pingMs = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
	end)
end)

if getgenv and getgenv().tntMiningStop then
	getgenv().tntMiningStop() -- re-running must not stack a second panel/loop
end

-- world ----------------------------------------------------------------------
local ClientAction = RS:WaitForChild("Logic"):WaitForChild("Network"):WaitForChild("Remotes"):WaitForChild("ClientAction")

local function need(path)
	local ok, mod = pcall(function()
		local node = RS
		for part in path:gmatch("[^.]+") do
			node = node:WaitForChild(part, 5)
		end
		return require(node)
	end)
	if not ok then
		warn("[tnt] couldn't require " .. path .. ": " .. tostring(mod))
	end
	return ok and mod or nil
end

local PlayerSession = need("Logic.Classes.PlayerSession")
local MineState = need("ClientLogic.Services.MineStateService")
local MineGenerator = need("Logic.Mines.MineGenerator")
local BlocksConfig = need("Logic.Configs.BlocksConfig") or {}

local function session()
	return PlayerSession and PlayerSession.GetClient()
end

local function root()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- Raw invoke for ApplyClicks: the game's client method only exists behind its own click
-- handler's gates, and the server answers with the numbers we need anyway.
local function invoke(cmd, args)
	local done, result
	task.spawn(function()
		local ok, res = pcall(ClientAction.InvokeServer, ClientAction, { cmd, args })
		done, result = ok, res
	end)
	local deadline = os.clock() + REMOTE_TIMEOUT
	while done == nil and os.clock() < deadline do
		task.wait()
	end
	if done == nil then
		print("[tnt] " .. cmd .. " never answered -- carrying on")
	end
	return done and result or nil
end

local function pending(s)
	return next(s.ActiveBombs or {}) ~= nil
end

local function valueOf(block)
	if block.BlockType == "EggShard" then
		return EGG_SHARD_VALUE
	end
	local cfg = BlocksConfig[block.BlockType]
	return cfg and cfg.SellValue or 0
end

-- Grid Y counts DOWN from the surface (MineGrid.IsExposed treats GridY < 1 as open sky),
-- so Y = 0 is the air layer above the top and is a legal place to stand a bomb.
local function isAir(grid, x, y, z)
	return x >= 1 and x <= grid.GridSize.X and z >= 1 and z <= grid.GridSize.Z and y >= 0 and y <= grid.GridSize.Y and not grid:GetBlockAt(x, y, z)
end

local function cellPos(grid, x, y, z)
	return MineGenerator.GetBlockCFrame(grid.Area, grid.GridSize, grid.BlockSize, x, y, z, 0, 0, 0).Position
end

-- The best target this round and the air cells around it that can reach it, nearest first.
-- Every bomb lands full Damage on every block in radius (MineDamageEngine.predict), so a
-- block's cost in bombs is just its health over your damage.
local bench = setmetatable({}, { __mode = "k" })

local function pickTarget(s)
	local grid = MineState and MineState.IsLoaded() and MineState.GetGrid()
	if not (grid and MineGenerator) then
		return nil
	end
	local dmg = math.max(s.Damage or 1, 1)
	local now = os.clock()
	local ranked = {}
	for _, b in pairs(grid.Blocks) do
		if b.Alive and (bench[b] or 0) < now then
			ranked[#ranked + 1] = { b = b, score = valueOf(b) / math.ceil(b.Health / dmg) }
		end
	end
	table.sort(ranked, function(a, b)
		return a.score > b.score
	end)

	local bs = grid.BlockSize.X
	local radius = s:GetBombExplosionRadius(s.EquippedBomb, false) * bs
	local reach = math.max(1, math.floor(radius / bs))
	-- the air cells a bomb could sit in and still reach b, nearest first
	local function cellsFor(b)
		local at = cellPos(grid, b.GridX, b.GridY, b.GridZ)
		local cells = {}
		for dx = -reach, reach do
			for dy = -reach, reach do
				for dz = -reach, reach do
					local x, y, z = b.GridX + dx, b.GridY + dy, b.GridZ + dz
					if isAir(grid, x, y, z) then
						local p = cellPos(grid, x, y, z)
						-- the blast is centred on the bomb, which sits half a block below the cell centre
						local d = (p - Vector3.new(0, bs / 2, 0) - at).Magnitude
						if d < radius then
							cells[#cells + 1] = { pos = p, d = d }
						end
					end
				end
			end
		end
		table.sort(cells, function(p, q)
			return p.d < q.d
		end)
		return cells
	end

	-- Go for the best block in the whole mine, buried or not. Out of reach, blast
	-- the topmost block still standing in its column instead -- that one always has open
	-- sky above it -- and the shaft deepens until the goal is in reach. Grid Y counts down,
	-- so "topmost above the goal" is the smallest GridY below the goal's.
	--
	-- A refill resets the mine (every LeaveMine in the dump is followed by a MineResult that
	-- respawns blocks into the holes), so a shaft is only worth starting if it can be
	-- finished on the TNT in hand. Cost = the shaft + the ore itself, in bombs: one bomb
	-- clears about LAYERS_PER_BOMB layers, as deep as the toughest block in them allows, and
	-- the last `reach` layers above the ore don't need clearing at all. Re-planned every
	-- round, so the same goal stays on top as its shaft gets cheaper.
	local left = s.HeldBombs or 0
	local goal
	-- ponytail: only the top DIG_CANDIDATES by per-bomb score get a shaft costed; a column
	-- walk per block for the whole mine is ~80k grid lookups a round
	for i = 1, math.min(#ranked, DIG_CANDIDATES) do
		local b = ranked[i].b
		local cost, chunkMax, inChunk = math.ceil(b.Health / dmg), 0, 0
		for y = 1, b.GridY - reach - 1 do
			local above = grid:GetBlockAt(b.GridX, y, b.GridZ)
			if above and above.Alive then
				chunkMax = math.max(chunkMax, math.ceil(above.Health / dmg))
			end
			inChunk += 1
			if inChunk == LAYERS_PER_BOMB then
				cost, chunkMax, inChunk = cost + chunkMax, 0, 0
			end
		end
		cost += chunkMax
		local score = valueOf(b) / cost
		if cost <= left and (not goal or score > goal.score) then
			goal = { b = b, score = score }
		end
	end
	if goal then
		local b = goal.b
		local cells = cellsFor(b)
		if #cells > 0 then
			return b, cells, grid, goal.score, b
		end
		for y = 1, b.GridY - 1 do
			local above = grid:GetBlockAt(b.GridX, y, b.GridZ)
			if above and above.Alive then
				if (bench[above] or 0) < now then
					cells = cellsFor(above)
					if #cells > 0 then
						return above, cells, grid, goal.score, b
					end
				end
				break -- only the topmost one is open from above
			end
		end
		-- shaft blocked (benched): fall through to whatever is reachable right now
	end

	for _, r in ipairs(ranked) do
		local cells = cellsFor(r.b)
		if #cells > 0 then
			return r.b, cells, grid, r.score, r.b
		end
		-- buried: no air within reach yet, so try the next best (it opens up as we dig)
	end
	return nil
end

-- farm -----------------------------------------------------------------------
local miner = { on = false, gen = 0, mark = "", at = 0 }
local trainer = { on = false, gen = 0 }
local seller = { on = false, gen = 0 }
local status = { mine = "idle", train = "idle", sell = "idle" } -- drained into the panel on Heartbeat

local function step(name)
	miner.mark, miner.at = name, os.clock()
end

-- Ignite while the id is still "P<n>": the game then ignites + confirms on the placement ack
-- by itself. Waiting first is wrong -- the ack renames the bomb to its server id and the
-- "P<n>" lookup finds nothing (probe 1: place true, ignite false, bomb stuck 1/1 placed).
local function placeAt(s, positions, want)
	local placed = 0
	for _, pos in ipairs(positions) do
		if placed >= want or not s:CanPlaceBomb() then
			break
		end
		local r = s:PlaceBomb(CFrame.new(pos), nil, s.EquippedBomb)
		if r and r.Success then
			s:IgniteBomb(r.Id)
			placed += 1
		end
	end
	return placed
end

local function waitBlast(s, stand)
	local t = os.clock() + FUSE_CAP
	while pending(s) and os.clock() < t do
		local hrp = stand and root()
		if hrp then -- hold the spot: an air cell has nothing under it to stop you falling off
			hrp.CFrame = stand
			hrp.AssemblyLinearVelocity = Vector3.zero
		end
		task.wait()
	end
end

-- Drops by id instead of by standing next to them. The server's CollectBlocks has no range
-- check, only its PendingCollectibles list (PlayerSession.lua:1890), and a drop's id is the
-- dead block's CollectibleId ("Forest:6_1_11" in the dump). So every dead block in the
-- mirror gets claimed once we've blown it, while the loop is already off to the next target.
-- An id the server didn't hand back (not registered yet, or the game's own pickup got it
-- first) is retried a couple of times, then dropped.
local claim = { grid = nil, tries = {}, inflight = 0 }
local claimStats = { got = 0 }
local HotbarEngine = need("ClientLogic.Engines.HotbarEngine")

local function claimDrops(s)
	local grid = MineState and MineState.IsLoaded() and MineState.GetGrid()
	if not grid then
		return
	end
	if claim.grid ~= grid then -- a refill/regeneration swaps the grid; old ids are dead
		claim.grid, claim.tries = grid, {}
	end
	local ids = {}
	for _, b in pairs(grid.Blocks) do
		local id = not b.Alive and b.CollectibleId
		if id and claim.tries[id] ~= true and (claim.tries[id] or 0) < CLAIM_TRIES then
			claim.tries[id] = (claim.tries[id] or 0) + 1
			ids[#ids + 1] = id
		end
	end
	local limit = HotbarEngine and select(2, pcall(HotbarEngine.GetBlockSlotLimit)) or 4
	for i = 1, #ids, CLAIM_BATCH do
		local batch = table.move(ids, i, math.min(i + CLAIM_BATCH - 1, #ids), 1, {})
		claim.inflight += 1
		task.spawn(function()
			local ok, r = pcall(s.CollectBlocks, s, batch, false, tonumber(limit) or 4)
			for _, id in ipairs(ok and type(r) == "table" and r.CollectedIds or {}) do
				claim.tries[id] = true
				claimStats.got += 1
			end
			claim.inflight -= 1
		end)
	end
end

local function mineOnce(s, tally)
	local hrp = root()
	if not hrp then
		step("waiting for character")
		task.wait(1)
		return
	end
	if s.HeldBombs <= 0 and not pending(s) then
		step("refill")
		task.wait(COLLECT_GRACE)
		claimDrops(s) -- the server's LeaveMine clears every pickup not yet claimed
		local c = os.clock() + REMOTE_TIMEOUT
		while claim.inflight > 0 and os.clock() < c do
			task.wait()
		end
		s:LeaveMine() -- client method: refills the session too, a raw invoke left it at 0
		local t = os.clock() + REMOTE_TIMEOUT
		while s._LeaveMinePending and os.clock() < t do
			task.wait()
		end
		return
	end
	if pending(s) then
		step("old bomb still out")
		waitBlast(s)
		return
	end

	step("pick target")
	local target, cells, grid, score, goal = pickTarget(s)
	local positions, stand
	if target then
		local half = Vector3.new(0, grid.BlockSize.Y / 2, 0)
		positions = {}
		for _, c in ipairs(cells) do
			positions[#positions + 1] = c.pos - half -- floor of the cell
		end
		stand = CFrame.new(positions[1] + Vector3.new(0, STAND, 0))
		hrp.CFrame = stand
		hrp.AssemblyLinearVelocity = Vector3.zero
		-- the server's CanPlaceBomb checks where IT thinks you are; placing first is a refusal
		task.wait(SETTLE + pingMs * 2 / 1000)
		hrp.CFrame = stand
	elseif s:GetMineAreaName() then
		positions = { hrp.Position - Vector3.new(0, STAND, 0) } -- no mirror loaded: dig at feet
	else
		status.mine = "walk into a mine first"
		task.wait(1)
		return
	end

	step("place" .. (target and (" " .. target.BlockType) or ""))
	local hpBefore = target and target.Health
	-- every bomb in radius lands full Damage on the target, so more than it takes to kill it
	-- is TNT the next target doesn't get (and a refill resets the mine)
	local want = target and math.ceil(target.Health / math.max(s.Damage or 1, 1)) or 1
	if placeAt(s, positions, want) == 0 then
		if target then
			bench[target] = os.clock() + BENCH
		end
		task.wait(0.2) -- refused; don't spin
		return
	end
	step("fuse")
	waitBlast(s, stand)
	task.wait(PICKUP)
	claimDrops(s)

	tally.bombs += 1
	if target then
		if target.Alive and target.Health >= hpBefore then
			bench[target] = os.clock() + BENCH -- the blast never reached it
		elseif not target.Alive then
			tally.ores[target.BlockType] = (tally.ores[target.BlockType] or 0) + 1
		end
	end
	local aim = not target and "feet"
		or goal ~= target and ("shaft to %s (%d deep)"):format(goal.BlockType, goal.GridY)
		or ("%s (%.0f/bomb)"):format(target.BlockType, score or 0)
	status.mine = ("%d rounds | %d drops claimed | %s | %d/%d TNT"):format(tally.bombs, claimStats.got, aim, s.HeldBombs, s.MaxHeldBombs)
end

local function setMining(on)
	miner.on = on
	if not on then
		status.mine = "stopped"
		return
	end
	local s = session()
	if not (s and s:GetMineAreaName()) then
		status.mine = "walk into a mine first, then turn this on"
		miner.on = false
		return
	end
	miner.gen += 1
	local mine = miner.gen
	task.spawn(function()
		local tally = { bombs = 0, ores = {} }
		while miner.on and miner.gen == mine do
			local ok, err = pcall(mineOnce, s, tally)
			if not ok then
				warn("[tnt] mine:", err)
				task.wait(1)
			end
		end
	end)
	-- separate thread: a parked mine loop can't report that it's parked
	task.spawn(function()
		while miner.on and miner.gen == mine do
			task.wait(5)
			local idle = os.clock() - miner.at
			if miner.at > 0 and idle > WATCHDOG then
				warn(("[tnt] stuck %ds at: %s"):format(idle, miner.mark))
			end
		end
	end)
end

local function setTraining(on)
	trainer.on = on
	if not on then
		status.train = "stopped"
		return
	end
	trainer.gen += 1
	local mine = trainer.gen
	task.spawn(function()
		local gained = 0
		while trainer.on and trainer.gen == mine do
			local r = invoke("ApplyClicks", { TRAIN_BATCH })
			if type(r) == "table" and r.Success then
				gained += r.DamageGained or 0
				-- the same {Damage, Level} shape PlayerDataUpdated carries, so the HUD keeps up
				local s = session()
				if s then
					pcall(s.ApplyDataUpdate, s, { Damage = r.Damage, Level = r.Level })
				end
				status.train = ("+%d damage (%d/s)"):format(gained, (r.AcceptedClicks or 0) * (r.DamagePerClick or 0))
			elseif type(r) == "table" then
				status.train = "refused -- standing on a training plot?"
			end
			task.wait(TRAIN_GAP)
		end
	end)
end

local function setSelling(on)
	seller.on = on
	if not on then
		status.sell = "stopped"
		return
	end
	seller.gen += 1
	local mine = seller.gen
	task.spawn(function()
		local earned = 0
		while seller.on and seller.gen == mine do
			local s = session()
			local ok, r = pcall(function()
				return s and s:SellBlocks()
			end)
			if ok and type(r) == "table" and r.Success then
				earned += r.Payout or 0
				status.sell = ("sold for $%d total"):format(earned)
			end
			-- ponytail: selling away from the stand is unprobed; if "sold" never moves while
			-- the bag fills, the server wants you at Map.Lobby.SellStand
			task.wait(SELL_GAP)
		end
	end)
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({ game = "+1 TNT Mining", folder = "TNTMining", size = UDim2.fromOffset(440, 360) })
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local sec = Tab:Section({ Title = "Farm", Icon = "solar:bolt-circle-bold", Box = true, BoxBorder = true, Opened = true })

sec:Toggle({ Title = "Auto Mine", Desc = "Best ore first. Stand in a mine, then turn on", Value = false, Callback = setMining })
sec:Toggle({ Title = "Auto Train", Desc = "25 clicks/s, no TNT in hand", Value = false, Callback = setTraining })
sec:Toggle({ Title = "Auto Sell", Desc = ("Every %ds, favourites kept"):format(SELL_GAP), Value = false, Callback = setSelling })

local line = sec:Paragraph({ Title = "Status", Desc = "idle" })
-- loop threads lose the capability the panel needs after a yield; Heartbeat runs as us
local shown = ""
local drain = game:GetService("RunService").Heartbeat:Connect(function()
	local text = ("mine: %s\ntrain: %s\nsell: %s"):format(status.mine, status.train, status.sell)
	if text ~= shown then
		shown = text
		pcall(line.SetDesc, line, text)
	end
end)

-- close ----------------------------------------------------------------------
local function stopAll()
	miner.on, trainer.on, seller.on = false, false, false
	drain:Disconnect()
	pinger:Disconnect()
end

Window:OnDestroy(function()
	stopAll()
	getgenv().tntMiningStop = nil
end)

getgenv().tntMiningStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().tntMiningStop = nil
end
