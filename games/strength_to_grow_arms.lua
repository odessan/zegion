--[[ Strength to Grow Arms -- brainrot autofarm (86259628805375)

     FARM     : punch the walls open remotely, hop onto a spawned brainrot, grab it by uid,
                hop back to where you started, bank it at SafetyBase, repeat. Start it from
                your base. PickUpBrainrot is range-checked server-side now (20 studs from the
                brainrot), so the hop is unavoidable; the server also sweeps every second and
                returns anyone standing past an un-broken wall (dropping their carry). HitWall
                has no position check and carries its damage forward wall to wall, so one
                punch on the map's first wall from base clears the whole path -- the hop only
                ever lands behind broken walls. Carry holds ONE at a time (MaxCarryNum=1), so
                it's strictly grab -> bank -> grab.

     TARGET   : "Best available" ranks every live brainrot by the game's own
                getBrainrotGoldPerSecond (base value x mutation) and takes the richest;
                or pick a single AreaN to farm just that zone. "Min $/s" skips anything
                cheaper in Best mode. Areas 1-12 are map 1, 13-21 map 2, 22-30 map 3; only
                the map you're on can be picked up (the server refuses the others). An area
                that needs more than "Max punches" to open is benched for a minute -- the
                count comes from the damage your last punch actually did.

     CRYSTALS : "Collect crystals" makes every punch release the shards it earned and picks
                up everything in your drop folder from wherever you are. Each bank resets the
                walls, so the farm's re-punching pays crystals every cycle.

     COLLECT  : "Auto collect cash" banks the income from every brainrot on your plot on a
                timer. No gamepass -- it fires the game's own collect-all remote, which has
                no gamepass check (the pass only sells the convenience pad).
     TRAIN    : "Auto train" runs your best owned treadmill from wherever you are, hands
                empty. SetTreadmill/SetRunState have no position or tool check and the
                server pays strength every 0.5s off the two attributes alone (probed: +3.9e25
                per 4s on Treadmill_1, vs +4.5e25 holding a dumbbell), so it runs alongside
                the farm -- which unequips tools on every grab and would break a dumbbell.
     PLACE    : "Auto place best" hands the game its own PlaceMaxBrainrot, which sorts your
                inventory by $/s and fills empty slots + replaces weaker placed ones with
                your best. Only fires when the inventory changed, so it doesn't churn.

     HEADS UP : every bank resets all walls to full HP, so every cycle re-punches the path
                (0.5s server cooldown per punch). Deep areas need the strength to break
                their walls; the farm tells you when it can't.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().growArmsStop() ]]

-- config ---------------------------------------------------------------------
local CYCLE_WAIT = 0.2 -- beat between grab cycles when there's nothing to do
local GRAB_TIMEOUT = 3 -- give up on a pickup whose uid never lands in CarryFolder
-- (expired mid-flight, another player took it, or the server never saw you arrive)
local PRESS_GAP = 0.25 -- between pickup re-fires while parked on the brainrot. The first
-- fire waits this long too, so the server has your new position before it range-checks
local HOP_UP = 3 -- studs above the brainrot's spot to land the root
local PUNCH_MAX = 12 -- default for the "Max punches" box: punches (~0.5s apart) to open an
-- area's walls before benching it. Raise it to farm a deep area at ~0.5s a punch per cycle
local PUNCH_SPAM = 0.05 -- HitWall re-fire gap while waiting out the server's 0.5s punch
-- cooldown. Lower = lands closer to the 0.5s mark, at more wasted (harmless) calls
local BENCH = 60 -- seconds an area you couldn't punch open is skipped
local SHARD_BLOCKS = 500 -- mini-blocks reported per DropShard. The server pays one drop per
-- 20 and never more than the damage earned, so this just means "release all of it"
local SHARD_EVERY = 0.5 -- seconds between crystal pickup sweeps
local BANK_TIMEOUT = 2 -- give up on a deposit whose carry never clears / inventory never grows
local MIN_LIFE = 3 -- skip brainrots with fewer than this many seconds of life left, so the
-- one you pick survives the round trip to the server (it destroys expired data every 1s)
local SETTLE = 0.1 -- wait between the firetouchinterest begin/end pair
local CLEAR_CD = 0.6 -- server HitWallCD (0.5) plus margin: how long punch() keeps re-firing
-- before it starts counting CLEAR_TIMEOUT against a punch that never lands
local CLEAR_TIMEOUT = 1 -- how long to wait for a punch's HitWallTime / a bank's guard to replicate
local CLEAR_RETRIES = 3 -- clear attempts before pausing in a terminal clear_failed state
local MAP_FIRST = { 1, 13, 22 } -- first wall id per map; the game's Config derives the maps
-- from these exact ranges (1-12, 13-21, 22-30)

local COLLECT_EVERY = 3 -- seconds between cash sweeps. Collecting resets each brainrot's
-- accrual, so a short interval just banks income smoothly and keeps you under any storage cap
local PLACE_EVERY = 2 -- seconds between auto-place passes. Spends nothing; only does work
-- when the farm has added a new brainrot to your inventory
local TRAIN_CHECK = 3 -- seconds between re-asserting the treadmill run (stepping on/off a real
-- treadmill clears it) and re-picking your best owned treadmill

local KEY_TOGGLE = Enum.KeyCode.RightControl

-- The two game modules that own the remotes, by their real (Chinese) names:
--   获取脑红 : PickUpBrainrot / HitWall (fires BridgeNet on ReplicatedStorage.RemoteEvent)
--   脑红     : GetBrainrotConfigInfo / getBrainrotGoldPerSecond (pure config, client-safe)
local GRAB_MOD = "Manager_\232\142\183\229\143\150\232\132\145\231\186\162"
local VALUE_MOD = "Manager_\232\132\145\231\186\162"
--   跑步机   : SetTreadmill / SetRunState / GetTreadmillInfo / CheckTreadmill (treadmill)
local TREAD_MOD = "Manager_\232\183\145\230\173\165\230\156\186"

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local player = Players.LocalPlayer

if getgenv and getgenv().growArmsStop then
	getgenv().growArmsStop() -- re-running must not stack a second panel/loop
end

-- world ----------------------------------------------------------------------
-- A game LocalScript's _G is not the executor's; the game's synced clock lives on its own.
local gEnv = (getrenv and getrenv()._G) or _G
local function clientTime()
	if gEnv and gEnv.GetClientTime then
		local ok, t = pcall(gEnv.GetClientTime)
		if ok and t then
			return t
		end
	end
	return time() -- fallback; MIN_LIFE / CLEAR_CD margins absorb the skew
end

local firetouch = firetouchinterest

-- require the module and hand back its returned table; nil (not error) if unavailable so
-- the raw fallback can take over.
local function tryRequire(name)
	local inst = ReplicatedStorage:WaitForChild("ModuleScripts", 10)
	inst = inst and inst:FindFirstChild(name)
	if not inst then
		return nil
	end
	local ok, mod = pcall(require, inst)
	return ok and mod or nil
end

local grabMgr = tryRequire(GRAB_MOD)
local valueMgr = tryRequire(VALUE_MOD)
local treadMgr = tryRequire(TREAD_MOD)
local rawEvent = ReplicatedStorage:FindFirstChild("RemoteEvent") -- BridgeNet's one socket
-- \14 == \x0E: the captured BridgeNet compressed id for the 获取脑红 bridge (was \x18 in the
-- first dump). DUMP-VERSION ONLY -- it shifts on game updates, so it's a last resort behind the require,
-- and a FireServer here is never trusted as success: a raw grab only "counts" once the uid
-- actually lands in CarryFolder (see cycle()).
local rawActive = false
local function usingRaw()
	return not (grabMgr and grabMgr.PickUpBrainrot)
end

local function pickup(uid)
	if grabMgr and grabMgr.PickUpBrainrot then
		grabMgr:PickUpBrainrot(player, { uid = uid })
	elseif rawEvent then
		rawEvent:FireServer({ { "\14", { "PickUpBrainrot", { uid = uid } } } })
	end
end

local function hitWall(wall)
	if grabMgr and grabMgr.HitWall then
		grabMgr:HitWall(player, wall)
	elseif rawEvent then
		rawEvent:FireServer({ { "\14", { "HitWall", wall } } })
	end
end

-- Static, safe to cache: these don't get rebuilt on respawn.
local dataFolder = (function()
	local bf = workspace:WaitForChild("BrainrotFolder", 10)
	return bf and bf:WaitForChild("data", 10)
end)()
local safety = (function()
	local map = workspace:WaitForChild("Map", 10)
	return map and map:WaitForChild("SafetyBase", 10)
end)()

local pdata = player:WaitForChild("PlayerData", 10)
local ownBrainrot = pdata and pdata:WaitForChild("OwnBrainrot", 10)
local mapStat = pdata and pdata:WaitForChild("MapStat", 10)

-- CarryFolder is rebuilt on respawn, so it's reacquired every cycle rather than cached.
local function carryData()
	local tf = workspace:FindFirstChild("TerritoryFolder")
	local mine = tf and tf:FindFirstChild(player.Name)
	local cf = mine and mine:FindFirstChild("CarryFolder")
	return cf and cf:FindFirstChild("data")
end

-- farm -----------------------------------------------------------------------
-- Value = the game's own math. Spawned brainrots carry only name + mutates (no
-- goldPerSecond, no level), so the base has to come from the config; passing {name,mutates}
-- alone scores every one 0.
local function brainrotValue(name, mutates)
	if not (valueMgr and name) then
		return nil
	end
	local ok, info = pcall(function()
		return valueMgr:GetBrainrotConfigInfo(name)
	end)
	if not ok or not info or not info.goldPerSecond then
		return nil
	end
	local ok2, v = pcall(function()
		return valueMgr:getBrainrotGoldPerSecond({ goldPerSecond = info.goldPerSecond, mutates = mutates })
	end)
	return ok2 and v or nil
end

local function decodeMutates(raw)
	if not raw then
		return nil
	end
	local ok, v = pcall(HttpService.JSONDecode, HttpService, raw)
	return ok and v or nil
end

local function mapNow()
	return mapStat and mapStat.Value or 1
end

local function mapOf(areaIdx)
	return areaIdx <= 12 and 1 or areaIdx <= 21 and 2 or 3
end

-- A spawn's pos attribute is relative to its AreaBox (tagged, named AreaN) -- the same sum the
-- game's own client uses to place the model you'd walk up to.
-- Remembered per map, never re-read as an Instance: a far AreaBox streams out while you stand
-- at base, and requiring the live part made every brainrot in it vanish from the list after
-- the first few grabs. Keyed by map because the client parks the maps it isn't showing.
local boxPos = {} -- "map:AreaN" -> Vector3
local function areaPos(areaName)
	local m = mapNow()
	for _, box in ipairs(CollectionService:GetTagged("AreaBox")) do
		if box:IsA("BasePart") then
			boxPos[m .. ":" .. box.Name] = box.Position
		end
	end
	return boxPos[m .. ":" .. areaName]
end

-- Every live brainrot on the current map (the server refuses a pickup from any other), plus
-- a tally of why the rest were dropped -- the idle line prints it.
local function listBrainrots(target, minPerSec, benched)
	local out, skip = {}, { map = 0, pos = 0, bench = 0, dying = 0, cheap = 0 }
	if not dataFolder then
		return out, skip
	end
	local now = clientTime()
	local mapVal = mapNow()
	for _, areaFolder in ipairs(dataFolder:GetChildren()) do
		local areaName = areaFolder.Name
		local areaIdx = tonumber(areaName:match("Area(%d+)")) or 0
		local n = #areaFolder:GetChildren()
		local base = mapOf(areaIdx) == mapVal and areaPos(areaName)
		if mapOf(areaIdx) ~= mapVal then
			skip.map = skip.map + n
		elseif not base then
			skip.pos = skip.pos + n
		elseif (benched[areaName] or 0) > os.clock() then
			skip.bench = skip.bench + n
		else
			for _, sv in ipairs(areaFolder:GetChildren()) do
				local exp = sv:IsA("StringValue") and sv:GetAttribute("ExpTime")
				local rel = sv:GetAttribute("pos")
				if not (exp and (exp - now) >= MIN_LIFE and typeof(rel) == "Vector3") then
					skip.dying = skip.dying + 1
				else
					local name = sv:GetAttribute("brainrot")
					local mutates = decodeMutates(sv:GetAttribute("mutates"))
					local value = brainrotValue(name, mutates) or areaIdx -- fallback: rank by zone
					if target ~= "Best available" or value >= minPerSec then
						out[#out + 1] = {
							uid = sv.Name,
							area = areaName,
							areaIdx = areaIdx,
							pos = base + rel,
							name = name,
							mutates = mutates,
							value = value,
						}
					else
						skip.cheap = skip.cheap + 1
					end
				end
			end
		end
	end
	return out, skip
end

local function pickTarget(list, target)
	if target == "Best available" then
		local best
		for _, b in ipairs(list) do
			if not best or b.value > best.value or (b.value == best.value and b.areaIdx > best.areaIdx) then
				best = b
			end
		end
		return best
	end
	for _, b in ipairs(list) do
		if b.area == target then
			return b
		end
	end
	return nil
end

-- Your per-player wall state, replicated under Player.WallInfo as JSON. A wall that isn't
-- listed is another map's, which the server's sweep skips too.
local function wallHp(id)
	local wi = player:FindFirstChild("WallInfo")
	local sv = wi and wi:FindFirstChild("BlockWall" .. id)
	if not sv then
		return 0
	end
	local ok, w = pcall(HttpService.JSONDecode, HttpService, sv.Value)
	return ok and type(w) == "table" and tonumber(w.hp) or 0
end

-- One HitWall on the current map's first wall. The server clears the ResetWallInfo deposit
-- guard, then spends your strength on the first standing wall and carries what's left into
-- the next, with no position check. Gated on the replicated HitWallTime (server CD 0.5) so it
-- isn't dropped; true once the server stamped a new HitWallTime.
local function mapWalls()
	local m = mapNow()
	return MAP_FIRST[m] or 1, (MAP_FIRST[m + 1] or 31) - 1
end

-- Crystals. The server only spawns a wall's shards when the CLIENT reports broken mini-blocks
-- (DropShard: wall, count, pos), and caps the payout by the wall's real damage in 20% steps --
-- so over-reporting the count just releases everything your punches already earned, and a
-- remote punch that the client never animated still pays. Each bank resets the walls, so
-- every cycle's punches pay again. PickUpShard(uid) has no position check.
local crystals = false -- set by the Crystals toggle
local lastDmg -- damage one punch did, measured; nil until a punch left a wall standing

local function dropShards(wall)
	local char = player.Character
	local pos = char and char:GetPivot().Position or Vector3.zero -- only where the shards draw
	if grabMgr and grabMgr.DropShard then
		grabMgr:DropShard(player, wall, SHARD_BLOCKS, pos)
	elseif rawEvent then
		rawEvent:FireServer({ { "\14", { "DropShard", wall, SHARD_BLOCKS, pos } } })
	end
end

local function pickShard(uid)
	if grabMgr and grabMgr.PickUpShard then
		grabMgr:PickUpShard(player, uid)
	elseif rawEvent then
		rawEvent:FireServer({ { "\14", { "PickUpShard", uid } } })
	end
end

-- Fired every PUNCH_SPAM until the server stamps a new HitWallTime, rather than timed off the
-- last stamp: the server drops an early HitWall with a bare return (no toast, no penalty), so
-- spamming lands each punch on the first server frame past the 0.5s cooldown -- where waiting
-- out CLEAR_CD then a round trip ran ~0.7s a punch.
local function punch()
	local first, last = mapWalls()
	local hpBefore = {}
	for id = first, last do
		hpBefore[id] = wallHp(id)
	end
	local before = player:GetAttribute("HitWallTime")
	local t0, fired = os.clock(), -math.huge
	repeat
		if os.clock() - fired >= PUNCH_SPAM then
			fired = os.clock()
			hitWall("BlockWall" .. first)
		end
		task.wait()
	until player:GetAttribute("HitWallTime") ~= before or (os.clock() - t0) > CLEAR_CD + CLEAR_TIMEOUT
	if player:GetAttribute("HitWallTime") == before then
		return false
	end
	task.wait() -- the WallInfo values land with (or just behind) the attribute
	local dmg, standing = 0, false
	for id = first, last do
		local now = wallHp(id)
		if now < hpBefore[id] then
			dmg = dmg + (hpBefore[id] - now)
			if crystals then
				dropShards("BlockWall" .. id)
			end
		end
		standing = standing or now > 0
	end
	if standing and dmg > 0 then
		lastDmg = dmg -- a punch that broke everything left under-reports, so only trust these
	end
	return true
end

local function clearGuard()
	for _ = 1, CLEAR_RETRIES do
		if player:GetAttribute("ResetWallInfo") == nil then
			return true
		end
		punch()
	end
	return player:GetAttribute("ResetWallInfo") == nil
end

-- AreaN sits just past BlockWallN, so reaching it needs every wall from the map's first to N
-- down -- otherwise the server's 1s sweep returns you to base and drops the carry.
local function pathOpen(areaIdx)
	for id = MAP_FIRST[mapNow()] or 1, areaIdx do
		if wallHp(id) > 0 then
			return false
		end
	end
	return true
end

-- Punches still needed, from the measured damage; nil until a punch has been measured.
local function punchesNeeded(areaIdx)
	if not lastDmg then
		return nil
	end
	local hp = 0
	for id = MAP_FIRST[mapNow()] or 1, areaIdx do
		hp = hp + wallHp(id)
	end
	return math.ceil(hp / lastDmg)
end

-- Returns (open, punchesNeeded). Refuses up front, without spending the punches, when the
-- measured damage says it can't make it inside maxPunches.
local function openPath(areaIdx, maxPunches)
	for _ = 1, maxPunches do
		if pathOpen(areaIdx) then
			return true
		end
		local need = punchesNeeded(areaIdx)
		if need and need > maxPunches then
			return false, need
		end
		punch()
	end
	return pathOpen(areaIdx), punchesNeeded(areaIdx)
end

-- SafetyBase.Touched returns early while ResetWallInfo is set, so a leftover guard (a prior
-- clear_failed, or ordinary play) must be dropped before a deposit will register at all.
local function ensureCleared()
	if player:GetAttribute("ResetWallInfo") == nil then
		return true
	end
	return clearGuard()
end

-- Deposit the one carried brainrot. Returns (banked, why). Confirms by the world: carry
-- empties AND the inventory string changes. hopFallback is the R2 escape if firetouchinterest can't
-- reach SafetyBase.Touched -- SafetyBase (z ~= -898) is behind every wall, so a hop there
-- crosses nothing and can't trip the teleport-back; the pre-hop pivot is restored after.
local function bank(cd, hopFallback)
	if not (cd and safety and ownBrainrot) then
		return false, "no_handles"
	end
	-- A pre-existing guard would swallow the touch silently; clear it first (finding: rerun
	-- after clear_failed couldn't recover a carry).
	if not ensureCleared() then
		return false, "clear_failed"
	end

	-- Reacquire per action: a respawn mid-cycle invalidates head. Returns (ok, reason) so a
	-- respawn reads as the transient no_head, not a terminal bank_failed.
	local function touchAndConfirm(doTouch)
		local char = player.Character
		local head = char and char:FindFirstChild("Head")
		if not head then
			return false, "no_head"
		end
		local before = ownBrainrot.Value
		local ok = pcall(doTouch, char, head) -- PivotTo/firetouch on a dying character can throw
		if not ok then
			return false, "no_head" -- the character went away under us; retry on the fresh one
		end
		local t0 = os.clock()
		repeat
			task.wait()
		until (#cd:GetChildren() == 0 and ownBrainrot.Value ~= before) or (os.clock() - t0) > BANK_TIMEOUT
		if #cd:GetChildren() == 0 and ownBrainrot.Value ~= before then
			return true, "ok"
		end
		return false, "bank_failed"
	end

	local banked, why = false, "bank_failed"
	if firetouch then
		banked, why = touchAndConfirm(function(_, head)
			firetouch(head, safety, 0)
			task.wait(SETTLE)
			firetouch(head, safety, 1)
		end)
	end
	if not banked and why ~= "no_head" and hopFallback then
		banked, why = touchAndConfirm(function(char)
			local orig = char:GetPivot()
			char:PivotTo(CFrame.new(safety.Position + Vector3.new(0, 5, 0)))
			task.delay(SETTLE + 0.1, function()
				-- Restore only the SAME character we hopped; a respawn during the confirm wait
				-- would otherwise fling the fresh character to the old one's spot.
				if player.Character == char then
					pcall(function()
						char:PivotTo(orig)
					end)
				end
			end)
		end)
	end
	-- no_head -> transient retry; bank_failed -> handled by caller. The guard the bank just set
	-- is cleared by the next cycle's openPath punch, which it needs anyway (walls reset too).
	return banked, why
end

-- gui ------------------------------------------------------------------------
-- ponytail: no hand-rolled widget kit. Topbar, icon, bubble, live game name and the shade
-- live in panel.lua, so a restyle is one file. Fetched here rather than installed by the
-- loader, so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Strength to Grow Arms", -- fallback until the live name lands
	folder = "GrowArms", -- renaming it later orphans configs already saved in-game
	size = UDim2.fromOffset(460, 400),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local farmCard =
	Tab:Section({ Title = "Farm", Desc = "Grab by uid, bank at base", Icon = "solar:magnet-bold", Box = true, BoxBorder = true, Opened = true })

-- state written by the controls
local target = "Best available"
local minPerSec = 0
local hopFallback = false
local maxPunches = PUNCH_MAX
local farming = false
local gen = 0
local count = 0

local statusRow, lastRow, countRow

local function say(msg)
	if statusRow then
		statusRow:SetDesc(msg)
	end
end

-- F9 is where "it does nothing" gets answered, so mirror the panel status there -- throttled,
-- because it's called every cycle.
local lastLog = 0
local function logf(reason)
	if os.clock() - lastLog >= 5 then
		lastLog = os.clock()
		print(("[growarms] %s | banked=%d target=%s"):format(reason, count, tostring(target)))
	end
end

-- no_head / no_handles are a respawn in progress, not a real refusal -- retry, don't stop.
local function isTransient(why)
	return why == "no_head" or why == "no_handles"
end

-- Target = Best available, or a single zone. Areas 1-12 map 1, 13-21 map 2, 22-30 map 3.
local zoneValues = { "Best available" }
for i = 1, 30 do
	zoneValues[#zoneValues + 1] = "Area" .. i
end

farmCard:Dropdown({
	Title = "Target",
	Desc = "Best $/s anywhere, or one specific zone",
	Values = zoneValues,
	Value = "Best available",
	Callback = function(picked)
		target = picked
	end,
})

farmCard:Input({
	Title = "Min $/s",
	Desc = "Best mode only: skip brainrots worth less than this",
	Value = "0",
	Placeholder = "0",
	Callback = function(v)
		minPerSec = tonumber((v or ""):gsub("[%$,%s]", "")) or 0
	end,
})

farmCard:Input({
	Title = "Max punches",
	Desc = "Per grab, ~0.5s each. An area needing more is skipped; raise it to farm deeper",
	Value = tostring(PUNCH_MAX),
	Placeholder = tostring(PUNCH_MAX),
	Callback = function(v)
		maxPunches = math.max(1, math.floor(tonumber(v) or PUNCH_MAX))
	end,
})

-- Sweeps DropFolder/<you> on a beat, and makes every punch (the farm's included) release the
-- shards it earned. Punches of your own by hand drop them too; this just picks them up.
local shardGen = 0
farmCard:Toggle({
	Title = "Collect crystals",
	Desc = "Grab the shards walls drop when punched -- from anywhere",
	Value = false,
	Callback = function(state)
		shardGen = shardGen + 1
		crystals = state
		if not state then
			return
		end
		local mine = shardGen
		task.spawn(function()
			while crystals and shardGen == mine do
				pcall(function()
					local df = workspace:FindFirstChild("DropFolder")
					local mineF = df and df:FindFirstChild(player.Name)
					for _, v in ipairs(mineF and mineF:GetChildren() or {}) do
						pickShard(v.Name)
					end
				end)
				task.wait(SHARD_EVERY)
			end
		end)
	end,
})

farmCard:Toggle({
	Title = "Bank hop fallback",
	Desc = "If firetouch can't bank, briefly drop onto SafetyBase instead (behind all walls, safe)",
	Value = false,
	Callback = function(state)
		hopFallback = state
	end,
})

-- The one moving part. Generation counter so off-then-on inside one interval can't leave
-- the old thread running alongside the new one.
local farmToggle
farmToggle = farmCard:Toggle({
	Title = "Farm Brainrots",
	Desc = "punch path, hop, grab, hop home, bank. Start at your base",
	Value = false,
	Callback = function(state)
		farming = state
		if not state then
			return -- off-click: the running loop sees farming=false and exits
		end
		if not ((grabMgr and grabMgr.PickUpBrainrot) or rawEvent) or not dataFolder or not safety then
			farmToggle:Set(false)
			WindUI:Notify({ Title = "Strength to Grow Arms", Content = "Couldn't resolve the game's remotes/folders -- see F9.", Image = "x" })
			warn("[growarms] missing: grabMgr/rawEvent/BrainrotFolder/SafetyBase -- cannot farm")
			return
		end

		local char = player.Character
		if not char then
			farmToggle:Set(false)
			say("no character yet -- try again after you spawn")
			return
		end

		gen = gen + 1
		local mine = gen
		-- ponytail: home is wherever you stood when you switched it on; add a "set home" button
		-- if people start it from past a wall
		local home = char:GetPivot()
		local benched = {} -- area -> os.clock() it may be tried again
		rawActive = usingRaw()
		local validated = false -- first confirmed bank proves the deposit path works live
		local rawProven = false -- first confirmed GRAB proves the raw \x0E id is still right
		say(rawActive and "started (raw \\x0E fallback -- unverified until first grab)" or "started")

		task.spawn(function()
			local rawFails = 0
			local function bumpCount()
				count = count + 1
				if countRow then
					countRow:SetDesc(tostring(count))
				end
			end

			while farming and gen == mine do
				local stop, wait = false, CYCLE_WAIT
				-- One pcall around the whole cycle: a respawn can invalidate a handle mid-wait
				-- and indexing it throws; that must pause-and-retry, not kill the worker with
				-- the toggle stuck on.
				local ok, err = pcall(function()
					local cd = carryData()
					if not cd then
						say("paused: no CarryFolder yet (respawning?)")
						wait = 0.5
						return
					end

					-- preflight: a leftover carry makes every pickup fail at MaxCarryNum=1
					if #cd:GetChildren() > 0 then
						local banked, why = bank(cd, hopFallback)
						if banked then
							bumpCount()
						elseif isTransient(why) then
							wait = 0.5
							return
						else
							say(("stopped: couldn't bank a leftover carry (%s) -- %d banked"):format(why, count))
							logf("preflight " .. why)
							stop = true
							return
						end
					end

					local list, skip = listBrainrots(target, minPerSec, benched)
					local tgt = pickTarget(list, target)
					if not tgt then
						local why = ("%d ok (none in %s), %d other map, %d area unseen, %d benched, %d expiring, %d under min $/s"):format(
							#list, tostring(target), skip.map, skip.pos, skip.bench, skip.dying, skip.cheap)
						say(("idle -- %s (%d banked)"):format(why, count))
						logf("idle: " .. why)
						return
					end

					local open, need = openPath(tgt.areaIdx, maxPunches)
					if not open then
						benched[tgt.area] = os.clock() + BENCH
						local why = need and ("needs ~%d punches, max is %d"):format(need, maxPunches) or "punches aren't landing"
						say(("%s: %s -- skipping it %ds"):format(tgt.area, why, BENCH))
						logf("walls closed to " .. tgt.area .. " (" .. why .. ")")
						return
					end

					-- Park on it and re-fire on a beat: the server range-checks against where it
					-- last saw you, so the first press waits PRESS_GAP for the hop to replicate.
					local spot = CFrame.new(tgt.pos + Vector3.new(0, HOP_UP, 0))
					local t0, pressed = os.clock(), os.clock()
					local got
					repeat
						local char = player.Character
						if char then
							char:PivotTo(spot)
						end
						if os.clock() - pressed >= PRESS_GAP then
							pressed = os.clock()
							pickup(tgt.uid)
						end
						task.wait()
						local c = carryData()
						got = c and c:FindFirstChild(tgt.uid)
					until got or (os.clock() - t0) > GRAB_TIMEOUT
					-- Home before banking, hit or miss: the bank resets every wall, and the 1s sweep
					-- returns anyone left standing past one.
					if player.Character then
						player.Character:PivotTo(home)
					end

					local nowCd = carryData()
					if not (nowCd and nowCd:FindFirstChild(tgt.uid)) then
						-- a raw fallback that can't even grab = the \x0E id has almost certainly
						-- moved; the grab (not the bank) is what proves it, so gate on rawProven.
						if rawActive and not rawProven then
							rawFails = rawFails + 1
							if rawFails >= 3 then
								say("stopped: raw \\x0E fallback isn't landing grabs -- the game's remote id likely changed.")
								WindUI:Notify({ Title = "Strength to Grow Arms", Content = "Raw fallback failed -- needs a fresh spy of the RemoteEvent id.", Image = "x" })
								logf("raw grab_failed x" .. rawFails)
								stop = true
								return
							end
						end
						say(("grab_failed on %s -- retrying (%d banked)"):format(tostring(tgt.name), count))
						logf("grab_failed " .. tostring(tgt.name))
						return
					end
					rawProven, rawFails = true, 0 -- the grab landed: the dispatch path is good

					local banked, why = bank(nowCd, hopFallback)
					if banked then
						validated = true
						bumpCount()
						if lastRow then
							local mut = tgt.mutates and (" [" .. table.concat(tgt.mutates, ",") .. "]") or ""
							lastRow:SetDesc(("%s%s @ %s = $%s"):format(tostring(tgt.name), mut, tgt.area, tostring(tgt.value)))
						end
						say(("banked %s (%d total)"):format(tostring(tgt.name), count))
						logf("banked " .. tostring(tgt.name))
					elseif isTransient(why) then
						wait = 0.5
					elseif why == "bank_failed" and not validated then
						-- the live self-test failed on the very first deposit
						say("stopped: bank not confirmed. Try enabling 'Bank hop fallback'.")
						WindUI:Notify({ Title = "Strength to Grow Arms", Content = "SafetyBase touch didn't bank -- enable the hop fallback and retry.", Image = "x" })
						logf("bank_failed (first)")
						stop = true
					elseif why == "clear_failed" then
						say(("stopped: deposit guard wouldn't clear (clear_failed) -- %d banked"):format(count))
						logf("clear_failed")
						stop = true
					else
						say(("%s on %s -- retrying (%d banked)"):format(why, tostring(tgt.name), count))
						logf(why .. " " .. tostring(tgt.name))
					end
				end)

				if not ok then
					say("cycle error (respawn?) -- see F9")
					warn("[growarms] cycle error:", err)
					wait = 0.5
				end
				if stop then
					farmToggle:Set(false)
					break
				end
				task.wait(wait)
			end

			if gen == mine then
				say(("stopped -- %d banked"):format(count))
			end
		end)
	end,
})

statusRow = farmCard:Paragraph({ Title = "Status", Desc = "idle" })
lastRow = farmCard:Paragraph({ Title = "Last grab", Desc = "nothing yet" })
countRow = farmCard:Paragraph({ Title = "Banked", Desc = "0" })

if not firetouch then
	WindUI:Notify({ Title = "Strength to Grow Arms", Content = "No firetouchinterest -- banking needs the hop fallback toggle.", Image = "x" })
end

-- plot -----------------------------------------------------------------------
-- Two independent remote-spam loops on valueMgr (脑红). Both are gamepass-free: the server's
-- OneClickGetAllBrainrotIncomeGold and PlaceMaxBrainrot handlers have no gamepass check and
-- no cooldown -- the gamepass only sells the convenience pad in the UI. Own generation
-- counters so off-then-on inside one interval can't leave a second thread running.
local plotCard =
	Tab:Section({ Title = "Plot", Desc = "Collect income + place your best", Icon = "solar:home-smile-bold", Box = true, BoxBorder = true, Opened = true })

local collecting, collectGen = false, 0
local placing, placeGen = false, 0
local MAX_FAILS = 5 -- consecutive pcall failures before a loop gives up and untoggles itself

-- Both methods must exist on the module, not just the module -- a game update could rename
-- or drop one, and an unguarded call would then fail silently forever inside the pcall.
local function needValueMgr(toggle, method)
	if valueMgr and type(valueMgr[method]) == "function" then
		return true
	end
	toggle:Set(false)
	WindUI:Notify({ Title = "Strength to Grow Arms", Content = "The game's plot module changed -- " .. method .. " unavailable (see F9).", Image = "x" })
	warn("[growarms] valueMgr." .. method .. " missing -- feature unavailable")
	return false
end

-- Shared loop body: fire on a beat, auto-disable after MAX_FAILS consecutive errors so a
-- broken remote surfaces instead of retrying in silence. `fire` returns true if it did work.
local function spamLoop(isOn, myGen, genOf, interval, toggle, label, fire)
	task.spawn(function()
		local fails = 0
		while isOn() and genOf() == myGen do
			local ok = pcall(fire)
			if ok then
				fails = 0
			else
				fails = fails + 1
				if fails >= MAX_FAILS then
					warn("[growarms] " .. label .. " disabled after " .. fails .. " errors")
					toggle:Set(false)
					break
				end
			end
			task.wait(interval)
		end
	end)
end

local collectToggle
collectToggle = plotCard:Toggle({
	Title = "Auto collect cash",
	Desc = "Banks all placed-brainrot income every " .. COLLECT_EVERY .. "s (no gamepass needed)",
	Value = false,
	Callback = function(state)
		collectGen = collectGen + 1 -- bump on every call so a stale sleeping loop dies on off too
		collecting = state
		if not state or not needValueMgr(collectToggle, "OneClickGetAllBrainrotIncomeGold") then
			return
		end
		local mine = collectGen
		spamLoop(function()
			return collecting
		end, mine, function()
			return collectGen
		end, COLLECT_EVERY, collectToggle, "auto collect", function()
			valueMgr:OneClickGetAllBrainrotIncomeGold(player)
		end)
	end,
})

local placeToggle
placeToggle = plotCard:Toggle({
	Title = "Auto place best",
	Desc = "Fills empty slots and replaces weaker ones with your highest $/s brainrots",
	Value = false,
	Callback = function(state)
		placeGen = placeGen + 1
		placing = state
		if not state or not needValueMgr(placeToggle, "PlaceMaxBrainrot") then
			return
		end
		local mine = placeGen
		-- PlaceMaxBrainrot re-settles every slot on each call, so only fire when the inventory
		-- actually changed (a new brainrot was banked) -- otherwise it churns server state and
		-- spams the tutorial warning every interval for nothing.
		local lastInv
		spamLoop(function()
			return placing
		end, mine, function()
			return placeGen
		end, PLACE_EVERY, placeToggle, "auto place", function()
			local inv = ownBrainrot and ownBrainrot.Value
			if inv and inv ~= lastInv then
				lastInv = inv
				valueMgr:PlaceMaxBrainrot(player)
			end
		end)
	end,
})

-- train ----------------------------------------------------------------------
-- Server state, not a loop of calls: the two attributes ARE the training, so teardown has to
-- clear them or a closed panel keeps you "running" (harmless, but not what off means).
local trainCard =
	Tab:Section({ Title = "Train", Desc = "Treadmill strength, from anywhere", Icon = "solar:dumbbell-large-bold", Box = true, BoxBorder = true, Opened = true })

local training, trainGen = false, 0
local trainRow

-- Highest-Add treadmill CheckTreadmill says you may use (owned, or VIP for Treadmill_Vip).
-- An unowned one would still "run" but at x1, so ownership is the filter, not the name.
local function bestTreadmill()
	local best, bestAdd
	local ok, all = pcall(treadMgr.GetTreadmillInfo, treadMgr)
	for name, info in pairs(ok and type(all) == "table" and all or {}) do
		local okOwn, own = pcall(treadMgr.CheckTreadmill, treadMgr, player, name)
		local add = type(info) == "table" and tonumber(info.Add) or 0
		if okOwn and own and (not bestAdd or add > bestAdd) then
			best, bestAdd = name, add
		end
	end
	return best or "Treadmill_1", bestAdd or 1
end

local function stopTraining()
	if treadMgr and player:GetAttribute("RunState") then
		pcall(treadMgr.SetTreadmill, treadMgr, player, nil)
		pcall(treadMgr.SetRunState, treadMgr, player, nil)
	end
end

local trainToggle
trainToggle = trainCard:Toggle({
	Title = "Auto train",
	Desc = "Runs your best treadmill without standing on it or holding anything",
	Value = false,
	Callback = function(state)
		trainGen = trainGen + 1
		training = state
		if not state then
			stopTraining()
			return
		end
		if not (treadMgr and type(treadMgr.SetRunState) == "function") then
			trainToggle:Set(false)
			WindUI:Notify({ Title = "Strength to Grow Arms", Content = "The game's treadmill module changed -- see F9.", Image = "x" })
			warn("[growarms] treadMgr.SetRunState missing -- auto train unavailable")
			return
		end
		local mine = trainGen
		task.spawn(function()
			while training and trainGen == mine do
				pcall(function()
					local name, add = bestTreadmill()
					if player:GetAttribute("Treadmill") ~= name or not player:GetAttribute("RunState") then
						treadMgr:SetTreadmill(player, name)
						treadMgr:SetRunState(player, true)
						print(("[growarms] training on %s (x%s)"):format(name, tostring(add)))
					end
					if trainRow then
						trainRow:SetDesc(("%s (x%s)"):format(name, tostring(add)))
					end
				end)
				task.wait(TRAIN_CHECK)
			end
		end)
	end,
})
trainRow = trainCard:Paragraph({ Title = "Treadmill", Desc = "off" })

-- close ----------------------------------------------------------------------
-- The red topbar button destroys the window after WindUI's own confirm; teardown hangs off
-- OnDestroy, and the stop hook shares it. ponytail: rerun to come back.
local function shutdown()
	if training then
		stopTraining()
	end
	farming, collecting, placing, crystals, training = false, false, false, false, false
	gen, collectGen, placeGen, shardGen, trainGen = gen + 1, collectGen + 1, placeGen + 1, shardGen + 1, trainGen + 1 -- orphan any running loop
end

Window:OnDestroy(function()
	shutdown()
	if getgenv then
		getgenv().growArmsStop = nil
	end
end)

if getgenv then
	getgenv().growArmsStop = function()
		shutdown()
		pcall(function()
			Window:Destroy()
		end)
		getgenv().growArmsStop = nil
	end
end
