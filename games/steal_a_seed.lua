--[[ Steal a Seed -- value-first stealing from the eight zones (122216176958450)

     FARM   : reads the client's own list of every seed on the map, picks the RICHEST one
              rather than the nearest, teleports to it, fires the steal, then carries it
              back over the zone's red line to bank it. One seed at a time -- the game
              only lets you hold one -- so a lap is grab, bank, repeat.
     ZONE   : lowest zone worth stealing from, by name -- Garden, Forest, Desert, up to
              Hell. A seed's rarity is its zone, so this is the value floor too. Read
              live, so raising it mid-run takes effect on the next lap.

     The seeds only exist while a round is running (the timer above the zone). Between
     rounds this idles and says so; it does not need restarting.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().stealSeedStop() ]]

-- config ---------------------------------------------------------------------
-- The E prompt you press by hand is a client shim (BusinessModules/拾取奖励0D): every
-- 0.1s it re-targets the nearest seed within 12 studs XZ and, on Triggered, calls
-- StealEnemyEgg(gid). So the prompt is not the mechanism -- the remote is -- and there
-- is nothing to fire a prompt at. What we cannot skip is the 12: the shim's copy of that
-- check is client-side, but the server keeps its own. So there is no reach constant here
-- -- the answer isn't to open a gate, it's to stand on the seed, which is what the press
-- loop's per-pass CFrame rewrite does.
local LIFT = 4 -- studs above the seed we park at. It sits on the ground; landing exactly
-- on its CFrame puts our feet through it and the character bounces.

-- ServerCD.Source.Universal is 250ms and StealEnemyEgg is a Universal command, so this
-- sits just above the server's own gate: a refusal at this spacing is a real refusal and
-- not the cooldown answering for it.
local STEAL_GAP = 0.3
local GRAB_WINDOW = 3 -- seconds of re-firing before one seed counts as refused

-- There is deliberately no fixed settle before the first fire. The confirm
-- (TempEnemyEggGid) is an attribute the server writes onto US, so the retry loop below IS
-- the settle: it costs nothing when the server was already ready, and it cannot be tuned
-- wrong the way a constant can.
local PAUSE_WAIT = 2 -- cap on waiting out a GameplayPaused after a hop
local ARRIVE_RADIUS = 25 -- studs; further than this from where we aimed means the server
-- reverted the hop rather than that we drifted

local BANK_WAIT = 2 -- seconds at the red line for the carry to clear
local PLOT_WAIT = 4 -- same, back at the plot. Longer because the trip is the point.
local LINE_MARGIN = 15 -- studs past the divider's Z, on the home side

local TP_STRIKES = 3 -- hops the server reverted before we stop teleporting and walk
local WALK_TIMEOUT = 20 -- seconds a walked leg gets before we give up on it
local SEED_STRIKES = 3 -- refusals on one seed before it's parked
local RETRY_AFTER = 20 -- seconds a parked seed is skipped for. Not zero: the farm takes
-- the highest-value seed first, so un-parking instantly means re-picking the same
-- unreachable one forever.

local IDLE = 1 -- beat when nothing is stealable. A lap that DID something goes straight
-- round again -- an idle beat between seeds is dead time on every single one.
local WATCHDOG = 25 -- seconds without the breadcrumb moving before we say where we are

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().stealSeedStop then
	getgenv().stealSeedStop() -- re-running must not stack a second panel or a second loop
end

local function log(msg)
	print("[seed] " .. msg)
end

local pending -- last thing a loop thread wanted on the status row; drained on Heartbeat
local function say(msg)
	pending = msg
end

-- A breadcrumb, because "it stopped and there was nothing in the console" cannot be
-- debugged after the fact. Every slow step names itself here and the watchdog -- a
-- separate thread, because a farm thread parked in a yield can't report anything -- is
-- the one thing still running that knows where we were.
local mark, markAt = "idle", os.clock()
local function step(what)
	mark, markAt = what, os.clock()
end

-- world ----------------------------------------------------------------------
-- Everything below comes out of the game's own modules rather than a workspace scan. The
-- seed models under Workspace.创建 are the CLIENT's pooled models, pivoted from the table
-- we're about to read -- scanning them would be reading our own mirror the long way round.
local function grab(path, root)
	local node = root
	for _, name in ipairs(path) do
		node = node and node:FindFirstChild(name)
	end
	return node
end

-- There are TWO copies of every client module: the StarterPlayerScripts original and the
-- clone Roblox drops into PlayerScripts at spawn. Only one of them is ever initialised,
-- and it is not the one you'd guess -- all 240 of this game's own call sites require
-- `game.StarterPlayer.StarterPlayerScripts.Business.C_Data`, so THAT is the instance
-- holding the live data. The PlayerScripts clone is a module nobody ever linked, and its
-- GetData() asserts on a nil upvalue. Both are tried below and whichever actually hands
-- back data wins, because being wrong about this looks exactly like joining too early.
local starterBiz = grab({ "StarterPlayerScripts", "Business" }, game:GetService("StarterPlayer"))
local playerBiz = grab({ "Business" }, player:WaitForChild("PlayerScripts", 10))
local GameEvent = grab({ "Business", "OnClientGameEvent" }, ReplicatedStorage)
local ConfigMod = grab({ "Data", "PlayConfig" }, ReplicatedStorage)
local InstanceMod = grab({ "Data", "X1100", "ServerInstanceData" }, ReplicatedStorage)
local ServerRemote = grab({ "RemoteEvent", "ServerRemoteEvent" }, ReplicatedStorage)
-- workspace.系统.ServerInfo -- the round clock. 系统 quoted, not decoded: it's the game's
-- name for the folder and typing it any other way is a rename waiting to happen.
local ServerInfo = grab({ "\231\179\187\231\187\159", "ServerInfo" }, workspace)

if not ((starterBiz or playerBiz) and GameEvent and ConfigMod and InstanceMod and ServerInfo) then
	warn("[seed] this game's modules aren't where they should be -- wrong game, or it updated")
	return
end

local okE, Events = pcall(require, GameEvent)
local okP, Config = pcall(require, ConfigMod)
local okI, Instances = pcall(require, InstanceMod)
if not (okE and okP and okI) then
	warn("[seed] a game module wouldn't load -- nothing to farm without it")
	return
end

-- Ask both copies, and keep asking for a few seconds: the framework links C_Data from its
-- own bootstrap, so a paste during the join can beat it there. Retrying is the difference
-- between "paste it again in five seconds" and a script that just works on a fresh join.
local function readData()
	for _, biz in ipairs({ starterBiz, playerBiz }) do
		local mod = biz and biz:FindFirstChild("C_Data")
		local ok, C_Data = pcall(require, mod)
		if ok and type(C_Data) == "table" and type(C_Data.GetData) == "function" then
			local got, d = pcall(C_Data.GetData)
			if got and type(d) == "table" and type(d.onlyData) == "table" then
				return d
			end
		end
	end
	return nil
end

local data
local deadline = os.clock() + 15
repeat
	data = readData()
	if not data then
		task.wait(0.5)
	end
until data or os.clock() > deadline

if not data then
	warn("[seed] the client's data never turned up -- rejoin, or wait for the game to finish loading")
	return
end

local seeds = data.onlyData.enemyEggItemByGid -- gid -> live seed; the game keeps it current
local chunkZ = Instances.enemyChunk_Z -- zone -> the Z of that zone's red line
local sourceCF = Instances.enemySource_CFrame -- zone -> a known-good spot inside it
local GpState = ServerInfo:FindFirstChild("Gp_State")
local GpTime = ServerInfo:FindFirstChild("Gp_Time")

local function hrp()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function carrying()
	local gid = player:GetAttribute("TempEnemyEggGid")
	return type(gid) == "number" and gid or 0
end

-- The trap other players throw at you. While it's live the server refuses the steal, and
-- the game's own shim refuses to even show the prompt -- so a lap spent inside one is a
-- lap of refusals that look like the seed's fault.
local function trapped()
	local until_ = player:GetAttribute("UseItemTrapEndTime")
	return type(until_) == "number" and workspace:GetServerTimeNow() < until_
end

local function roundOn()
	return not GpState or GpState.Value == 1
end

-- Which zone a Z sits in. Straight out of the game's own CheckEnemyChunkIndex: the lines
-- run from zone 1 nearest home out to zone 8, Z decreasing, so the deepest line you are
-- past is the zone you're standing in. 0 means home side of all of them.
local function zoneOfZ(z)
	for n = #chunkZ, 1, -1 do
		if z < chunkZ[n] then
			return n
		end
	end
	return 0
end

local function seedName(item)
	local cfg = Config.allRollEgg[item.data and item.data.cfgId]
	return cfg and cfg.name or ("seed " .. tostring(item.data and item.data.gid))
end

-- Rarity first, size as the tiebreak, both read from the game's own config -- so a
-- balance patch is picked up for free rather than from a list copied out of a dump.
-- Which zone a seed came from. The live seed carries it as enemyId, which is the only
-- honest source: `rarity` LOOKS like the zone for the first seven and then stops -- every
-- zone-8 (Inferno) seed is rarity 7, same as Void, so the ladder tops out one short and
-- rarity can neither separate the two nor express "Inferno only". A dropped seed belongs
-- to no enemy, so it's placed by where it lies.
local function zoneOf(item)
	local id = item.enemyId
	if type(id) == "number" and id > 0 then
		return id
	end
	return zoneOfZ(item.cf.Position.Z)
end

-- Zone first, size as the tiebreak. Both read off the game's own state, so a balance patch
-- is picked up for free rather than from a list copied out of a dump.
local function score(item)
	if not (item.data and Config.allRollEgg[item.data.cfgId]) then
		return nil -- a seed the config doesn't know; nothing sane to rank it by
	end
	local zone = zoneOf(item)
	local size = Config.allEggSizeProbability[item.data.sizeLevel]
	return zone * 1000 + (size and size.size or 0), zone
end

-- travel ---------------------------------------------------------------------
local tpStrikes = 0

-- true arrived / false the server reverted us / nil there was no character to move. The
-- third answer matters on its own: a respawn counted as a revert would eventually
-- convince travel() this game snap-backs and retire the fast path over nothing.
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

-- The fallback when the server won't take our writes. MoveTo only steers and gives up
-- after 6-8s, so it gets re-issued on a beat until we're there or the budget is gone.
local function walkTo(cf)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return nil
	end
	local deadline = os.clock() + WALK_TIMEOUT
	repeat
		hum:MoveTo(cf.Position)
		hum.MoveToFinished:Wait()
		local root = hrp()
		if not root then
			return nil
		end
		if (root.Position - cf.Position).Magnitude <= ARRIVE_RADIUS then
			return true
		end
	until os.clock() > deadline
	return false
end

-- Hop first, walk only once the server has proved it reverts us. The order matters: a hop
-- is one frame and a walk across a zone is twenty seconds, so paying for the walk before
-- there is evidence would cost every lap of the run.
local function travel(cf)
	if tpStrikes < TP_STRIKES then
		local landed = hop(cf)
		if landed ~= false then
			return landed -- true, or nil for no character
		end
		tpStrikes += 1
		if tpStrikes == TP_STRIKES then
			log(("the server reverted %d hops -- walking from here on, which is much slower"):format(TP_STRIKES))
		end
		return false
	end
	return walkTo(cf)
end

-- farm -----------------------------------------------------------------------
local farming, farmGen = false, 0
local parked = {} -- gid -> os.clock() it may be tried again
local strikes = {} -- gid -> refusals so far
local minZone = 1
local lineBanks = nil -- nil not tried yet / true the red line banks / false it doesn't

local function eligible(item, now)
	if not item or item.isDropping then
		return nil -- still in the air after someone dropped it; nothing to take yet
	end
	local gid = item.data and item.data.gid
	if not gid or (parked[gid] or 0) > now then
		return nil
	end
	local total, zone = score(item)
	if not total or zone < minZone then
		return nil
	end
	return total
end

local function best()
	local now, root = os.clock(), hrp()
	local here = root and root.Position or Vector3.new()
	local pick, pickScore, pickDist
	for _, item in pairs(seeds) do
		local total = eligible(item, now)
		if total then
			local dist = (item.cf.Position - here).Magnitude
			-- Distance only breaks a tie. Two seeds of the same rarity and size are worth
			-- the same, and then the near one is strictly better.
			if not pick or total > pickScore or (total == pickScore and dist < pickDist) then
				pick, pickScore, pickDist = item, total, dist
			end
		end
	end
	return pick
end

-- Fire the steal. The module is the send path -- ClientEvent.InitOnEvent has already
-- rewritten every method on it into a FireServer -- so calling it is exactly what the
-- game's own shim does. The raw remote is the fallback, and it is only a fallback because
-- a hand-written command string is the thing most likely to be wrong.
local function fireSteal(gid)
	if pcall(function()
		Events:StealEnemyEgg(gid)
	end) then
		return true
	end
	if not ServerRemote then
		return false
	end
	return (pcall(function()
		ServerRemote:FireServer("StealEnemyEgg", gid)
	end))
end

-- true got it / false fired for the whole window and it's still there (a refusal, worth a
-- strike) / nil the seed left the table while we were on it -- someone else took it, or
-- the round ended. The third is not our failure and must not be counted as one.
local function takeSeed(gid, cf)
	local deadline = os.clock() + GRAB_WINDOW
	repeat
		if seeds[gid] == nil then
			return nil
		end
		local root = hrp()
		if not root then
			return nil
		end
		-- Rewritten every pass: a single MoveTo drifts, and drifting out of the 12 studs
		-- mid-window turns a good grab into a timeout with nothing in the console.
		root.CFrame = cf
		fireSteal(gid)
		if carrying() == gid then
			return true
		end
		task.wait(STEAL_GAP)
	until os.clock() > deadline
	return carrying() == gid
end

-- "The carry cleared" is not the same as "we banked it". A trap clears it too -- the
-- timeline has TempEnemyEggGid going to 0 and UseItemTrapEndTime going to a future time on
-- the same tick -- and a lost seed read as a success would teach lineBanks the wrong
-- lesson and keep it. So the trap flag is the discriminator, and it is the only one there
-- is: nothing else on the player says which of the two happened.
local function waitClear(seconds)
	local deadline = os.clock() + seconds
	repeat
		if carrying() == 0 then
			return not trapped()
		end
		task.wait()
	until os.clock() > deadline
	return false
end

-- Home, in the game's own words: while you're carrying, the tutorial arrow re-points at
-- "plant the seed", which is your plot.
local function homeCF()
	local zone = data.onlyData.zone
	local part = zone and zone.tpPart
	if part then
		return part.CFrame
	end
	local slots = data.onlyData.incubationChunk_CFrame
	return slots and slots[1]
end

-- Just past the red line of the zone we stole from, on the home side.
local function lineCF(zone)
	if not (zone and chunkZ[zone]) then
		return nil
	end
	local root = hrp()
	local src = sourceCF[zone]
	local x = root and root.Position.X or (src and src.Position.X) or 0
	local y = (src and src.Position.Y or 0) + LIFT
	return CFrame.new(x, y, chunkZ[zone] + LINE_MARGIN)
end

-- The one thing the client never does itself is bank, so it is server-side and
-- positional, and which position is the unknown this loop measures. The line is tried
-- first because it's next door; the plot is the answer that always works but costs the
-- length of the map. Once one of them has paid out we stop asking.
local function bank(zone, name)
	if lineBanks ~= false then
		local cf = lineCF(zone)
		if cf then
			step("bank " .. name .. " / line")
			say("banking " .. name .. " at the red line")
			travel(cf)
			if waitClear(BANK_WAIT) then
				if lineBanks == nil then
					lineBanks = true
					log("the red line banks -- staying with it")
				end
				return true
			end
		end
	end

	local home = homeCF()
	if not home then
		return false
	end
	step("bank " .. name .. " / plot")
	say("banking " .. name .. " at the plot")
	travel(home)
	if not waitClear(PLOT_WAIT) then
		return false
	end
	-- Only the first answer is allowed to set this. Once the line has paid out, a single
	-- miss is a trap or a race, not evidence that the line stopped working -- retiring it
	-- on one bad lap would cost the length of the map on every lap after.
	if lineBanks == nil then
		lineBanks = false
		log("the red line does not bank -- going all the way home from here on")
	end
	return true
end

local function lap()
	if not roundOn() then
		local left = GpTime and GpTime.Value or 0
		say(("waiting for the round -- %ds"):format(math.max(left, 0)))
		return false
	end
	if trapped() then
		say("trapped -- waiting it out")
		return false
	end

	-- A carry left over from a lap that lost the race, or from a manual grab. Bank it
	-- before looking for anything else; the game only lets you hold one.
	if carrying() > 0 then
		local root = hrp()
		bank(root and zoneOfZ(root.Position.Z) or 1, "the seed you're holding")
		return true
	end

	step("pick")
	local item = best()
	if not item then
		say("nothing worth taking -- wait for the round or lower Min zone")
		return false
	end

	local gid, cf, zone = item.data.gid, item.cf, zoneOf(item)
	local name = seedName(item)

	step("grab " .. name .. " / travel")
	say("going for " .. name)
	if travel(cf * CFrame.new(0, LIFT, 0)) == nil then
		return false -- no character; not the seed's fault, so no strike
	end

	step("grab " .. name .. " / press")
	local got = takeSeed(gid, cf * CFrame.new(0, LIFT, 0))
	if got == nil then
		return true -- gone from under us; go straight round rather than waiting a beat
	end
	if not got then
		strikes[gid] = (strikes[gid] or 0) + 1
		if strikes[gid] >= SEED_STRIKES then
			parked[gid] = os.clock() + RETRY_AFTER
			strikes[gid] = nil
			log(("%s refused %d times -- parked for %ds"):format(name, SEED_STRIKES, RETRY_AFTER))
		end
		say("refused: " .. name)
		return true
	end

	strikes[gid] = nil
	log("got " .. name)
	if not bank(zone, name) then
		say("lost " .. name .. " on the way back")
	end
	return true
end

local function setFarming(on)
	farming = on
	if not on then
		step("idle")
		say("stopped")
		return
	end

	farmGen += 1
	local mine = farmGen
	table.clear(parked)
	table.clear(strikes)

	task.spawn(function()
		while farming and farmGen == mine do
			if os.clock() - markAt > WATCHDOG then
				log(("stuck %.0fs at: %s"):format(os.clock() - markAt, mark))
				markAt = os.clock()
			end
			task.wait(5)
		end
	end)

	task.spawn(function()
		while farming and farmGen == mine do
			local did
			local ok, err = pcall(function()
				did = lap()
			end)
			if not ok then
				log("lap failed: " .. tostring(err))
			end
			if not did then
				task.wait(IDLE)
			else
				task.wait() -- a lap that did something goes straight round
			end
		end
		step("idle")
	end)
end

-- gui ------------------------------------------------------------------------
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a restyle
-- is one file and not seventeen. Fetched here rather than installed by the loader, so
-- this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Steal a Seed", -- fallback until the live name lands
	folder = "StealSeed", -- unchanged: renaming it orphans configs already saved in-game
	size = UDim2.fromOffset(440, 320),
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:leaf-bold" })
local Farm = Tab:Section({ Title = "Farm", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })

Farm:Toggle({
	Title = "Auto Farm",
	Desc = "Richest seed on the map, steal it, carry it back over the red line",
	Value = false,
	Callback = setFarming, -- :Set() re-fires this, and setFarming is re-entrant
})

-- The zone names come out of PlayConfig.allEnemy rather than a list typed in here, so a
-- rename or a ninth zone is picked up without an edit. The dropdown's value is the zone
-- ID, NOT the seed's rarity: allEnemy[8] (Inferno) is rarity 7, the same as Void, so the
-- rarity ladder tops out one short and a rarity filter can neither reach Inferno nor keep
-- Void out of it. zoneOf() is the axis; this row just picks a floor on it.
local ZONES, ZONE_ID = {}, {}
for id = 1, #Config.allEnemy do
	local cfg = Config.allEnemy[id]
	local label = (cfg and cfg.name) or ("Zone " .. id)
	ZONES[id] = label
	ZONE_ID[label] = id
end

Farm:Dropdown({
	Title = "Min zone",
	Desc = "Seeds from zones below this are skipped. Read live -- raising it takes effect next lap.",
	Values = ZONES,
	Value = ZONES[1],
	Callback = function(pick)
		-- Ignore anything we don't recognise rather than assigning it: this runs on its own
		-- thread and a rebuild re-fires it with whatever the row is holding, "" included.
		local id = ZONE_ID[pick]
		if id then
			minZone = id
			say("min zone " .. pick)
		end
	end,
})

Farm:Button({
	Title = "TP to base",
	Desc = "Drops you on your own plot -- the same spot the farm banks at",
	Callback = function()
		-- Refuses rather than blocking. The farm drives the character too, so a hop taken
		-- mid-lap is yanked back within the second and reads as a button that does nothing.
		if farming then
			say("turn Auto Farm off first -- it would teleport you straight back")
			return
		end
		local home = homeCF()
		if not home then
			say("can't find your plot -- are you assigned one yet?")
			return
		end
		say(travel(home) and "at your base" or "the server wouldn't let us move")
	end,
})

local line = Farm:Paragraph({ Title = "Status", Desc = "idle" })

-- Drains whatever a loop thread last left. A resumed thread has lost the capability the
-- hidden GUI needs, so a loop writing the row directly gets away with its first write and
-- throws on every one after a wait -- which kills the farm with the toggle still lit. The
-- engine calls Heartbeat with our own identity, so this write is the one that's allowed.
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

say("ready -- flip Auto Farm on during a round")

-- close ----------------------------------------------------------------------
local function stopAll()
	setFarming(false)
end

local function disconnectAll()
	pcall(function()
		drain:Disconnect()
	end)
end

Window:OnDestroy(function()
	stopAll()
	disconnectAll()
	getgenv().stealSeedStop = nil
end)

getgenv().stealSeedStop = function()
	stopAll() -- the loop exits on its own flag, so this really does stop it
	disconnectAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().stealSeedStop = nil -- or the next paste calls a stop for a destroyed window
end
