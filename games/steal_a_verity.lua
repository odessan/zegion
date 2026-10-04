--[[ Steal A Verity! -- walked box stealing, place, open, pets, treadmill, upgrades (107164765081465)

     STEAL     : walks to the biggest loose box you can reach (ticked box types, in areas your Speed has
                 unlocked; size first, then the pet's income, then distance), holds Steal the real 1.6s
                 and walks back out of the stealing area, where the server banks it as a box Tool. It
                 does not go home per box: it goes home after HOME_AFTER boxes, or when nothing is left
                 to steal. Never teleports: the server kicks for hops (AutoKickConfig, 6 points / 300s).
     PLACE     : at home, banked boxes go into your pen (PlaceBox), best first, up to the box cap.
     OPEN      : opens every planted box the moment its UnboxAt passes (ManageBoxes OPEN). No movement.
     PETS      : at home, pets in your hands/backpack are placed in the pen (PlacePet), best first.
     SELL      : at home, held pets of the ticked rarities that did not fit are sold at the Sell Shop.
     TREADMILL : stands on your treadmill (~200 Speed/s at tier 3) whenever nothing else needs you.
     UPGRADE   : walks to your treadmill / pet-slot sign and buys the next level once you can afford it.
     CLAIMS    : index rewards every CLAIM_EVERY, offline cash once.

     One thread drives the character for every walking feature, so they never fight over it.

     Probed with this script's own input (zbridge, 2026-10-04):
       steal  : stop, wait InStealingArea, open the prompt's client gate, InputHoldBegin 1.75s -> CarryChanged
       bank   : leaving the stealing area turns the carry into a box Tool (BoxUid attr), CarryChanged nil
       place  : PlaceBox(groundPos) with the box Tool held, inside PetBounds -> BoxPlaced. Outside: PLACE_INSIDE_PEN
       open   : ManageBoxes("OPEN", uid) on a ready box -> UnboxPlayed, the pet lands in your hand
       pets   : PlacePet(groundPos) with the pet Tool held, inside the pen -> Tool consumed
       index  : ClaimAllIndexRewards -> IndexAllClaimed
       tread  : on in ~1.3s by walking onto the belt; walking or jumping does NOT release you, a velocity shove does
       farm   : 2 min run, noclip on: 4 banked, 1 lost, 1 refused, no anti-cheat message, no kick.
                Every box spawns 12-33 studs from its area's monster, which wakes ~0.8s after the carry and chases
                across areas until you reach the spawn (x ~130). The lane (z ~ -65) runs straight away from it.
                Losses: a far-area monster outrunning you (area4 bursts to ~133 vs walk ~92), ocean waves
                (KnockLaunch mid-hold -> ACTION_FAILED). Pets at the slot cap answer PEN_FULL.
                Lava pads (area5) launch you on the lane edge: walks steer round every tagged Lava /
                EruptionVent. A launch with noclip on fell through the floor (death): noclip pauses 3.5s.
                Every later knock pushed west = the chasing monster from behind (area3 bursts ~112,
                area5 ~154 vs walk ~100, slower carrying a big box). Lost boxes are benched; 3 in a row
                writes the area off for 5 min.
       sell   : SellPets({uid...}) after walking to the Sell Shop pad -> PETS_SOLD {Count, Amount}
       upgrade: standing by the sign, UpgradeTreadmill / UpgradeBase -> TREADMILL_UPGRADED / BASE_UPGRADED
                (from across the map: MOVE_CLOSER)
     UNPROVEN (first outcome printed to F9): offline claim, the night sweep, noclip against the server's
       Barrier check over a long run.
     Not wired: free gift (needs the group: JOIN_GROUP), FINISH_ALL and every Robux upgrade prompt, boss
       (the fight is another place; investigate it there), teleports of any kind.

     RightControl opens / closes the panel. Stop: getgenv().stealVerityStop() ]]

-- config ---------------------------------------------------------------------
local WALK_TICK = 0.1 -- MoveTo is re-issued this often; it only steers
local ARRIVE = 5 -- studs from the box before stopping to press (prompt range is 16)
local LEG_CAP = 45 -- give up a walk after this long (stuck on geometry, a fence, the treadmill)
local AREA_WAIT = 3 -- after stopping, wait this long for the server to set InStealingArea
local HOLD_PAD = 0.15 -- held past HoldDuration; the server wants at least half of it
local CARRY_WAIT = 3 -- CarryChanged must arrive inside this after the hold
local BANK_CAP = 45 -- walking back out of the area: give up after this long
local HOME_AFTER = 6 -- go home and place after this many banked boxes (the box in the panel changes it)
local BENCH = 20 -- a box we failed on is skipped this long, doubled per repeat
local NIGHT_MARGIN = 8 -- seconds: do not start a trip this close to the night sweep
local GATE_OUT = 35 -- studs past the pen edge to walk before heading for a box
local TREADMILL_AVOID = 13 -- legs are routed around your treadmill (it captures at 7, releases at 10)
local PLACE_GAP = 0.35 -- between Place calls
local PLACE_CONFIRM = 1.5
local PLACE_NEAR = 15 -- walk this close to a spot before placing on it (the server's limit is 60)
local SPOT_STEP = 7 -- studs between candidate spots in the pen
local OPEN_EVERY = 1
local OPEN_RETRY = 4 -- a box we asked to open that is still planted is asked again after this
local CLAIM_EVERY = 120
local UPGRADE_BACKOFF = 30 -- an upgrade the server did not take is not retried for this long
local TREAD_SLICE = 2 -- on the treadmill, look up for other work this often
local STATUS_EVERY = 0.5
local STALL = 3 -- a walk that has not closed STALL_STUDS in this long is stuck (a wall, water, a fence)
local STALL_STUDS = 3
local STUCK_AFTER = 30 -- the watchdog prints the step the farm is parked on after this long
local HAZARD_PAD = 5 -- extra studs kept from a lava pad's corner / a vent's hit radius
local PLAYER_AVOID = 14 -- studs kept from other players on a walk (bats and slaps knock the box off you)
local CONTEST_R = 15 -- a box with another player this close is left to them
local BANK_X = 135 -- probed: a carry turns into a banked Tool at x 120-142, entering the spawn
local OUTRUN_MARGIN = 1.2 -- the monster must need this many times your escape time to catch you. Raise to play safer
local AREA_DROPS = 3 -- this many boxes lost in a row in one area writes it off for AREA_BENCH
local AREA_BENCH = 300
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local player = Players.LocalPlayer

if getgenv and getgenv().stealVerityStop then
	getgenv().stealVerityStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[verity]", ...)
end

-- The status strip is drained from a Heartbeat; a loop thread that writes to the window throws
-- "lacking capability Plugin" after its first task.wait.
local pending, lastSaid = nil, nil
local function say(msg, quiet)
	pending = msg
	if not quiet and msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- breadcrumb: every slow step names itself; a separate watchdog thread reports a mark that stops moving
local mark, markAt = "start", os.clock()
local function step(m)
	mark, markAt = m, os.clock()
end

local firsts = {}
local function first(name, ...)
	if not firsts[name] then
		firsts[name] = true
		log("first " .. name .. ":", ...)
	end
end

-- game -----------------------------------------------------------------------
local Shared = ReplicatedStorage:WaitForChild("Shared", 15)
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
local Client = player:WaitForChild("PlayerScripts"):WaitForChild("Client", 15)
local ok, AreaConfig, BoxConfig, VerityConfig, IncomeConfig, RarityConfig, SellConfig, PetConfig, NightConfig, ProfileView =
	pcall(function()
		return require(Shared.AreaConfig),
			require(Shared.BoxConfig),
			require(Shared.VerityConfig),
			require(Shared.IncomeConfig),
			require(Shared.RarityConfig),
			require(Shared.SellConfig),
			require(Shared.PetConfig),
			require(Shared.NightConfig),
			require(Client.ProfileView)
	end)
if not (Remotes and ok) then
	warn("[verity] the game's modules did not load:", AreaConfig)
	return
end
-- only the outrun filter needs these; without them it lets everything through
local okMon, MonsterConfig, MutationConfig, Progression = pcall(function()
	return require(Shared.MonsterConfig), require(Shared.MutationConfig), require(Shared.Progression)
end)
if not okMon then
	warn("[verity] MonsterConfig did not load, the outrun filter is off:", MonsterConfig)
end
local R = {}
for _, n in
	{
		"CarryChanged",
		"ErrorMessage",
		"BoxPlaced",
		"PlaceBox",
		"PlacePet",
		"ManageBoxes",
		"UnboxPlayed",
		"SellPets",
		"UpgradeTreadmill",
		"UpgradeBase",
		"ClaimAllIndexRewards",
		"ClaimOfflineReward",
		"HitReceived",
	}
do
	R[n] = Remotes:WaitForChild(n, 10)
end

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function fmt(n)
	n = tonumber(n) or 0
	local i = 1
	while n >= 1000 and i < #SUFFIX do
		n /= 1000
		i += 1
	end
	return ("%.3g"):format(n) .. SUFFIX[i]
end
assert(fmt(25000) == "25K" and fmt(1500) == "1.5K" and fmt(100) == "100", "fmt")

local function ticked(values)
	local set = {}
	for k, v in pairs(values) do
		if type(v) == "string" then
			set[v] = true
		elseif v then
			set[k] = true
		end
	end
	return set
end
assert(ticked({ "a" }).a and ticked({ a = true }).a and not ticked({ a = false }).a, "ticked reads both shapes")

local function prof()
	return ProfileView.Get() or {}
end

local function body()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hum and hrp and hum.Health > 0 then
		return hum, hrp, char
	end
	return nil
end

local FLAT = Vector3.new(1, 0, 1)
local function flat(v)
	return (v * FLAT).Magnitude
end

-- distance from p to segment a-b, on the ground plane
local function segDist(p, a, b)
	p, a, b = p * FLAT, a * FLAT, b * FLAT
	local ab = b - a
	local len2 = ab:Dot(ab)
	local t = len2 > 0 and math.clamp((p - a):Dot(ab) / len2, 0, 1) or 0
	return (p - (a + ab * t)).Magnitude
end
assert(
	math.abs(segDist(Vector3.new(0, 0, 5), Vector3.new(-10, 0, 0), Vector3.new(10, 0, 0)) - 5) < 1e-6,
	"segDist mid"
)
assert(
	math.abs(segDist(Vector3.new(20, 0, 0), Vector3.new(-10, 0, 0), Vector3.new(10, 0, 0)) - 10) < 1e-6,
	"segDist end"
)

-- world ----------------------------------------------------------------------
local function myBaseName()
	local rt = workspace:FindFirstChild("BaseRuntime")
	for _, s in ipairs(rt and rt:GetChildren() or {}) do
		if s:GetAttribute("OwnerUserId") == player.UserId then
			return (s.Name:gsub("^BaseUpgradeSign_", ""))
		end
	end
	return nil
end

local function pen()
	local name = myBaseName()
	local base = name and workspace:FindFirstChild("Bases") and workspace.Bases:FindFirstChild(name)
	return base and base:FindFirstChild("PetBounds"), name
end

local function inPen(pos)
	local pb = pen()
	if not pb then
		return false
	end
	local o = pb.CFrame:PointToObjectSpace(pos)
	return math.abs(o.X) < pb.Size.X / 2 - 2 and math.abs(o.Z) < pb.Size.Z / 2 - 2
end

-- The pens open on the side that faces the areas (+X, where every area sits). ponytail: probed on
-- Base5 only; if a walk out of another base stalls, the gate needs reading from the Fence instead.
local function gates()
	local pb = pen()
	if not pb then
		return nil
	end
	local g = pb.Position + Vector3.new(pb.Size.X / 2 + 2, 0, 0)
	return g, g + Vector3.new(GATE_OUT, 0, 0)
end

local function myTreadmill()
	local _, name = pen()
	local rt = workspace:FindFirstChild("TreadmillRuntime")
	return name and rt and rt:FindFirstChild("Treadmill_" .. name)
end

local function treadmillPos()
	local tm = myTreadmill()
	local belt = tm and tm:FindFirstChild("Conveyor", true)
	return belt and belt.Position or (tm and tm:GetPivot().Position)
end

local floors
local function areaOf(pos)
	if not floors then
		floors = {}
		for _, a in ipairs(workspace.Areas:GetChildren()) do
			local id = a:GetAttribute("AreaId")
			local def = id and AreaConfig.Get(id)
			local floor = def and a:FindFirstChild(def.FloorPart, true)
			if floor and floor:IsA("BasePart") then
				floors[#floors + 1] = { id = id, req = def.RequiredSpeed or 0, f = floor }
			end
		end
	end
	for _, a in ipairs(floors) do
		local o = a.f.CFrame:PointToObjectSpace(pos)
		if math.abs(o.X) <= a.f.Size.X / 2 and math.abs(o.Z) <= a.f.Size.Z / 2 then
			return a
		end
	end
	return nil
end

-- the box's face image is the only thing on a loose box that names its type
local boxByFace = {}
for _, d in ipairs(BoxConfig.Definitions) do
	boxByFace[d.Face] = boxByFace[d.Face] or d.Id -- secret and up share one face; they rank top either way
end

local function boxIdOf(box)
	local face = box:FindFirstChild("Face", true)
	local img = face and (face:IsA("ImageLabel") and face.Image or face:IsA("Decal") and face.Texture)
	return img and boxByFace[img]
end

-- A size mutation scales the whole box: Core.Size.Y is 1.875 at 1x and N times that for "sizeN"
-- (probed: 7.5 -> size4 ... 28.1 -> size15). It is the only thing on a loose box that names its mutation.
local CORE_Y = 1.875
local function sizeOf(coreY)
	return math.max(1, math.floor(coreY / CORE_Y + 0.5))
end
assert(sizeOf(1.875) == 1 and sizeOf(7.5) == 4 and sizeOf(24.375) == 13 and sizeOf(28.125) == 15, "sizeOf")

local function rateOf(boxId, areaId, mutation)
	local ok2, r = pcall(function()
		return IncomeConfig.RateFor(VerityConfig.ForBox(boxId), areaId, mutation or "")
	end)
	return ok2 and tonumber(r) or 0
end

local function rarityOrder(rarityId)
	local r = rarityId and RarityConfig.Get(rarityId)
	return r and r.Order or 0
end

-- Hazards that launch you and drop the box (probed: every area5 carry died on one lava pad's edge).
-- Lava pads are squares (LavaConfig: knock 40 studs, reaches 6 past the edge); vents hit a 9.5 radius.
-- Both are tagged, which is what the game's own controllers read. Kept as circles.
local hazards
local function hazardList()
	if hazards then
		return hazards
	end
	hazards = {}
	for _, p in ipairs(CollectionService:GetTagged("Lava")) do
		if p:IsA("BasePart") then
			local r = math.max(p.Size.X, p.Size.Z) / 2 * math.sqrt(2) + 6 + HAZARD_PAD
			hazards[#hazards + 1] = { c = p.Position * FLAT, r = r }
		end
	end
	for _, v in ipairs(CollectionService:GetTagged("EruptionVent")) do
		local pos = v:IsA("Model") and v:GetPivot().Position or (v:IsA("BasePart") and v.Position)
		if pos then
			hazards[#hazards + 1] = { c = pos * FLAT, r = 9.5 + HAZARD_PAD }
		end
	end
	log(("%d hazards to walk around"):format(#hazards))
	return hazards
end

-- Other players are the moving half: their landmines (LandmineConfig.BLAST_RADIUS 13, knock 30) and their
-- bats/slaps (SlapConfig.DropsCarriedBox). Both are read fresh on every steer.
local function obstacles()
	local out = table.clone(hazardList())
	local lr = workspace:FindFirstChild("LandmineRuntime")
	for _, m in ipairs(lr and lr:GetChildren() or {}) do
		local p = m:IsA("Model") and m:GetPivot().Position or (m:IsA("BasePart") and m.Position)
		if p and m:GetAttribute("LandmineOwner") ~= player.UserId then
			out[#out + 1] = { c = p * FLAT, r = 13 + HAZARD_PAD }
		end
	end
	for _, pl in ipairs(Players:GetPlayers()) do
		local root = pl ~= player and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
		if root then
			out[#out + 1] = { c = root.Position * FLAT, r = PLAYER_AVOID }
		end
	end
	return out
end

-- someone standing on a box is about to take it, or waiting to bat whoever does
local function contested(pos)
	for _, pl in ipairs(Players:GetPlayers()) do
		local root = pl ~= player and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
		if root and flat(root.Position - pos) < CONTEST_R then
			return true
		end
	end
	return false
end

-- where to aim from `from` toward `to`: beside the first obstacle in the way, else `to` itself.
-- A target inside an obstacle's circle (a box by the lava) is let through.
local function steer(from, to, list)
	local f, t = from * FLAT, to * FLAT
	local dir = t - f
	local len = dir.Magnitude
	if len < 1 then
		return to
	end
	dir = dir / len
	local hit, along
	for _, h in ipairs(list or obstacles()) do
		local a = (h.c - f):Dot(dir)
		if a > 0 and a < len and segDist(h.c, f, t) < h.r and (t - h.c).Magnitude > h.r then
			if not along or a < along then
				hit, along = h, a
			end
		end
	end
	if not hit then
		return to
	end
	local side = (f + dir * along) - hit.c
	side = side.Magnitude > 0.1 and side.Unit or Vector3.new(-dir.Z, 0, dir.X)
	local p = hit.c + side * (hit.r + 3)
	return Vector3.new(p.X, to.Y, p.Z)
end
do
	local one = { { c = Vector3.new(0, 0, 0), r = 10 } }
	local s = steer(Vector3.new(-50, 0, 2), Vector3.new(50, 0, 2), one)
	assert(math.abs(s.X) < 1e-6 and s.Z > 10, "steer goes round on the near side")
	assert(steer(Vector3.new(-50, 0, 40), Vector3.new(50, 0, 40), one).X == 50, "steer leaves a clear line alone")
	assert(steer(Vector3.new(-50, 0, 0), Vector3.new(3, 0, 0), one).X == 3, "a target inside is let through")
end

-- the areas' middle line: the monsters sit near its edges (z ~ -5 and -118 against -65)
local function laneZ()
	local spawn = workspace.Areas:FindFirstChild("Spawn")
	return spawn and spawn:GetPivot().Position.Z or -65
end

local function nightSoon()
	local now = workspace:GetServerTimeNow()
	for k = 0, NIGHT_MARGIN do
		local okP, phase = pcall(NightConfig.PhaseAt, now + k)
		if okP and phase ~= nil and phase ~= "DAY" then
			return true
		end
	end
	return false
end

local function tools(attr)
	local out = {}
	for _, holder in ipairs({ player.Backpack, player.Character }) do
		for _, t in ipairs(holder and holder:GetChildren() or {}) do
			if t:IsA("Tool") and t:GetAttribute(attr) ~= nil then
				out[#out + 1] = t
			end
		end
	end
	return out
end

local function plantedList()
	local out = {}
	for _, x in pairs(prof().Planted or {}) do
		out[#out + 1] = x
	end
	return out
end

local function myPetCount()
	local n = 0
	for _, p in ipairs(workspace.PetRuntime:GetChildren()) do
		if p:GetAttribute("OwnerUserId") == player.UserId then
			n += 1
		end
	end
	return n
end

-- state read by the loops -----------------------------------------------------
local flags = { steal = false, place = false, pets = false, sell = false, tread = false, upgrade = false }
local boxOn, sellRarity = {}, {}
local homeAfter = HOME_AFTER
local stats = { stolen = 0, failed = 0, dropped = 0, placed = 0, opened = 0, pets = 0, sold = 0, upgrades = 0 }
local bench = setmetatable({}, { __mode = "k" }) -- box model -> { until, wait }
local areaDrops, areaBenchUntil = {}, {} -- area id -> boxes lost in a row / skipped until
local carry = nil -- the CarryChanged table while the server says we carry something
local lastErr, lastErrAt = nil, 0
local conns = {}

table.insert(
	conns,
	R.CarryChanged.OnClientEvent:Connect(function(p)
		carry = typeof(p) == "table" and p or nil
	end)
)
table.insert(
	conns,
	R.ErrorMessage.OnClientEvent:Connect(function(code)
		lastErr, lastErrAt = tostring(code), os.clock()
	end)
)
table.insert(
	conns,
	R.HitReceived.OnClientEvent:Connect(function()
		first("hit", "HitReceived while", carry and "carrying" or "empty-handed")
	end)
)

-- noclip: parts stop colliding while the farm walks (not on the treadmill, which holds you anyway).
-- Speed stays at walk speed, so the teleport/carry checks see nothing new. UNPROVEN against the
-- server's Barrier check (AutoKickConfig weight 2); the farm never targets a locked area or walks at night.
local noclip = false
local collided = {} -- part -> its CanCollide before we touched it
local carriedBox = nil -- the box we carry stays its own model in BoxRuntime, welded to us, and collides
-- probed: a knock launch with collisions off drops you through the floor into the void. Off while launched.
local noclipPausedUntil = 0
local KNOCK_PAUSE = 3.5 -- RagdollSeconds is 2-2.5 across monsters, lava and slaps
local anyWalker
local function restoreCollision()
	for part, was in pairs(collided) do
		if part.Parent then
			part.CanCollide = was
		end
	end
	table.clear(collided)
end
table.insert(
	conns,
	RunService.Stepped:Connect(function()
		if
			not (noclip and anyWalker and anyWalker())
			or player:GetAttribute("OnTreadmill")
			or os.clock() < noclipPausedUntil
		then
			if next(collided) then
				restoreCollision()
			end
			return
		end
		for _, model in ipairs({ player.Character, carriedBox and carriedBox.Parent and carriedBox or nil }) do
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("BasePart") and part.CanCollide then
					if collided[part] == nil then
						collided[part] = true
					end
					part.CanCollide = false
				end
			end
		end
	end)
)

table.insert(
	conns,
	Remotes:WaitForChild("KnockLaunch").OnClientEvent:Connect(function()
		noclipPausedUntil = os.clock() + KNOCK_PAUSE
	end)
)

-- the server words what it did on SuccessMessage (TREADMILL_UPGRADED, PETS_SOLD, BOX_STOLEN ...)
local lastOk, lastOkAt = nil, 0
table.insert(
	conns,
	Remotes:WaitForChild("SuccessMessage").OnClientEvent:Connect(function(code)
		lastOk, lastOkAt = tostring(code), os.clock()
	end)
)

local function errSince(t)
	return lastErrAt >= t and lastErr or nil
end

local function benchBox(box)
	local b = bench[box]
	local wait = b and b.wait * 2 or BENCH
	bench[box] = { untilT = os.clock() + wait, wait = wait }
end

-- walking ----------------------------------------------------------------------
-- Walking or jumping does not get you off a treadmill; a shove does (probed: free in 0.3s).
local function leaveTreadmill()
	local t = os.clock()
	while player:GetAttribute("OnTreadmill") and os.clock() - t < 3 do
		local hum, hrp = body()
		local pb = pen()
		if not (hum and pb) then
			return
		end
		local away = flat(pb.Position - hrp.Position) > 1 and ((pb.Position - hrp.Position) * FLAT).Unit
			or Vector3.new(-1, 0, 0)
		hum.Sit = false
		hum:ChangeState(Enum.HumanoidStateType.Jumping)
		hrp.AssemblyLinearVelocity = away * 60 + Vector3.new(0, 40, 0)
		task.wait(0.3)
	end
end

-- remembers the closest we got; a walk that stops closing in is stuck, not slow
local function stallWatch()
	local best, bestAt = math.huge, os.clock()
	return function(d)
		if d < best - STALL_STUDS then
			best, bestAt = d, os.clock()
		end
		return os.clock() - bestAt > STALL
	end
end

local function walkTo(pos, within, cap, alive)
	local t = os.clock()
	local stuck, hopped = stallWatch(), false
	while os.clock() - t < cap do
		if not alive() then
			return false
		end
		local hum, hrp = body()
		if not hum then
			return false
		end
		local d = flat(hrp.Position - pos)
		if d < within then
			return true
		end
		if stuck(d) and not player:GetAttribute("OnTreadmill") then
			if hopped then
				return false
			end
			hopped, stuck = true, stallWatch()
			hum.Jump = true -- a lip or a fence post: one hop, then the next stall gives up
		end
		if player:GetAttribute("OnTreadmill") then
			leaveTreadmill()
		end
		hum:MoveTo(steer(hrp.Position, pos))
		task.wait(WALK_TICK)
	end
	return false
end

-- a leg that passes the treadmill goes round it
local function walkLeg(pos, within, cap, alive)
	local _, hrp = body()
	local tm = treadmillPos()
	if hrp and tm and segDist(tm, hrp.Position, pos) < TREADMILL_AVOID then
		local side = ((hrp.Position - tm) * FLAT)
		side = side.Magnitude > 0.1 and side.Unit or Vector3.new(0, 0, 1)
		walkTo(tm + side * TREADMILL_AVOID * 1.4, 4, 10, alive)
	end
	return walkTo(pos, within, cap, alive)
end

local function leavePen(alive)
	local _, hrp = body()
	local g1, g2 = gates()
	if hrp and g1 and (inPen(hrp.Position) or flat(hrp.Position - g1) < GATE_OUT) then
		walkLeg(g1, 4, 10, alive)
		walkLeg(g2, 4, 10, alive)
	end
end

local function goHome(alive)
	local g1, g2 = gates()
	local pb = pen()
	if not g1 then
		return false
	end
	local _, hrp = body()
	if hrp and inPen(hrp.Position) then
		return true
	end
	walkLeg(g2, 4, LEG_CAP, alive)
	walkLeg(g1, 4, 10, alive)
	return walkLeg((pb.CFrame * CFrame.new(-pb.Size.X / 4, 0, 0)).Position, 4, 10, alive)
end

-- steal ------------------------------------------------------------------------
-- The monster of the area you steal from chases you to the spawn. Model, fitted to the knocks logged
-- in the probe runs: its top speed is ChaseSpeed * 3.5 (burst) * EnragedMultiplier, and its head start is
-- its distance to the box plus AggroDelay seconds of you running. Area1 (84) never caught a ~100 walker,
-- area2 (109) rarely, area3 (134) inside 3s.
local outrunOn = true
local function catchTime(gap, burst, carrySpeed)
	if burst <= carrySpeed then
		return math.huge
	end
	return gap / (burst - carrySpeed)
end
assert(catchTime(90, 84, 100) == math.huge, "a slower monster never catches")
assert(math.abs(catchTime(90, 134, 100) - 90 / 34) < 1e-9, "catchTime")

local monsterCache = {}
local function monsterStats(areaId)
	if not okMon then
		return nil
	end
	if monsterCache[areaId] == nil then
		local def = AreaConfig.Get(areaId)
		local m = def and def.MonsterId and MonsterConfig.Get(def.MonsterId)
		monsterCache[areaId] = m
				and {
					burst = MonsterConfig.BurstSpeedFor(m.ChaseSpeed) * (m.EnragedMultiplier or 1),
					aggro = m.AggroDelay or 0,
				}
			or false
	end
	return monsterCache[areaId] or nil
end

-- can this box reach the spawn before its monster reaches us?
local function outruns(c, walkSpeed)
	local m = monsterStats(c.area)
	if not (outrunOn and m) then
		return true
	end
	local carrySpeed = walkSpeed * MutationConfig.CarryFactor(c.size >= 4 and ("size" .. c.size) or "")
	local mon = workspace.MonsterRuntime:FindFirstChild("WildMonster_" .. c.area)
	local gap = (mon and flat(mon:GetPivot().Position - c.core.Position) or 15) + carrySpeed * m.aggro
	local escape = math.abs(c.core.Position.X - BANK_X) + math.abs(c.core.Position.Z - laneZ())
	return catchTime(gap, m.burst, carrySpeed) > OUTRUN_MARGIN * escape / carrySpeed
end

local skippedLast = 0 -- boxes the outrun filter turned down on the last pick, for the status line

local function pickBox()
	local hum, hrp = body()
	if not hum then
		return nil
	end
	local speed = tonumber(prof().Speed) or 0
	-- the server's walk speed for your Speed stat: Humanoid.WalkSpeed reads 0 while a menu or the treadmill holds you
	local walkSpeed = okMon and Progression.WalkSpeedFor(speed) or math.max(hum.WalkSpeed, 16)
	-- biggest box first (asked for), then the richer pet, then the nearer one
	local best
	local skipped = 0
	for _, b in ipairs(workspace.BoxRuntime:GetChildren()) do
		local core = b:FindFirstChild("Core")
		local prompt = core and core:FindFirstChild("Steal")
		local bb = bench[b]
		if prompt and not core:GetAttribute("PromptOwnerUserId") and not (bb and os.clock() < bb.untilT) then
			local a = areaOf(core.Position)
			local id = boxIdOf(b)
			-- no monster filter: every box spawns 12-33 studs from its area's monster (probed), it guards them
			if a and a.req <= speed and id and boxOn[id] and os.clock() >= (areaBenchUntil[a.id] or 0) then
				local size = sizeOf(core.Size.Y)
				local c = {
					box = b,
					core = core,
					prompt = prompt,
					id = id,
					area = a.id,
					size = size,
					rate = rateOf(id, a.id, size >= 4 and ("size" .. size) or ""),
					dist = flat(core.Position - hrp.Position),
				}
				if not outruns(c, walkSpeed) then
					skipped += 1
				elseif outrunOn and contested(core.Position) then
					skipped += 1
				elseif
					not best
					or c.size > best.size
					or (c.size == best.size and (c.rate > best.rate or (c.rate == best.rate and c.dist < best.dist)))
				then
					best = c
				end
			end
		end
	end
	skippedLast = skipped
	return best
end

-- one trip: returns "banked", "none", "night" or a failure word
local function stealOne(alive)
	if nightSoon() then
		return "night"
	end
	local tgt = pickBox()
	if not tgt then
		return "none"
	end
	local hum = body()
	if not hum then
		return "dead"
	end
	step("steal: leave base")
	hum:UnequipTools() -- the Steal prompt needs free hands
	if player:GetAttribute("OnTreadmill") then
		leaveTreadmill()
	end
	leavePen(alive)
	say(("stealing %s x%d in %s"):format(tgt.id, tgt.size, tgt.area), true)

	-- in along the lane, then straight across to the box: never past a monster
	step("steal: lane to " .. tgt.area)
	local lz = laneZ()
	local _, hrp0 = body()
	if hrp0 and math.abs(hrp0.Position.Z - lz) > 10 then
		walkTo(Vector3.new(hrp0.Position.X, hrp0.Position.Y, lz), 6, 15, alive)
	end
	walkTo(Vector3.new(tgt.core.Position.X, tgt.core.Position.Y, lz), 6, LEG_CAP, alive)

	-- walk to it; the box can be taken under us, then pick again
	local arrived = false
	for _ = 1, 3 do
		step("steal: walk to " .. tgt.id .. " in " .. tgt.area)
		local t = os.clock()
		local stuck, hopped = stallWatch(), false
		while alive() and os.clock() - t < LEG_CAP and tgt.box.Parent and tgt.core:FindFirstChild("Steal") do
			local h, hrp = body()
			if not h then
				return "dead"
			end
			local d = flat(hrp.Position - tgt.core.Position)
			if d < ARRIVE then
				arrived = true
				break
			end
			if stuck(d) then
				if hopped then
					break
				end
				hopped, stuck = true, stallWatch()
				h.Jump = true
			end
			h:MoveTo(steer(hrp.Position, tgt.core.Position))
			task.wait(WALK_TICK)
		end
		if arrived or not alive() then
			break
		end
		if tgt.box.Parent and tgt.core:FindFirstChild("Steal") then
			benchBox(tgt.box) -- still there and we never reached it: geometry
			log(("walk gave up on %s in %s after %.0fs"):format(tgt.id, tgt.area, os.clock() - t))
		end
		tgt = pickBox()
		if not tgt then
			return "none"
		end
	end
	if not arrived then
		return alive() and "lost" or "stopped"
	end

	local h, hrp = body()
	if not h then
		return "dead"
	end
	h:MoveTo(hrp.Position) -- stand still: the server times the hold
	step("steal: wait InStealingArea at " .. tgt.id)
	local t = os.clock()
	while os.clock() - t < AREA_WAIT and player:GetAttribute("InStealingArea") ~= true do
		task.wait()
	end
	if player:GetAttribute("InStealingArea") ~= true then
		benchBox(tgt.box)
		first("not in stealing area", tgt.id, tgt.area, hrp.Position)
		return "area"
	end
	task.wait(0.15)
	local prompt = tgt.prompt
	if prompt.MaxActivationDistance <= 0 then
		prompt.MaxActivationDistance = prompt:GetAttribute("PromptSuppressedRange") or 16
	end
	local t0 = os.clock()
	step("steal: hold " .. tgt.id)
	local held = pcall(function()
		prompt:InputHoldBegin()
		task.wait(prompt.HoldDuration + HOLD_PAD)
	end)
	step("steal: release " .. tgt.id)
	pcall(function()
		prompt:InputHoldEnd() -- every exit: a leaked begin sticks the prompt held
	end)
	step("steal: wait carry " .. tgt.id)
	t = os.clock()
	while held and not carry and os.clock() - t < CARRY_WAIT do
		task.wait()
	end
	if not carry then
		benchBox(tgt.box)
		stats.failed += 1
		log(
			("steal refused: %s in %s, dist %.1f, gone=%s, err=%s, carry steals so far %d"):format(
				tgt.id,
				tgt.area,
				flat(hrp.Position - tgt.core.Position),
				tostring(tgt.box.Parent == nil),
				tostring(errSince(t0)),
				stats.stolen
			)
		)
		return "refused"
	end
	first("carry", carry.BoxId, carry.AreaId)
	carriedBox = tgt.box -- noclip it too; the director clears it when the trip ends

	-- walk back out of the stealing area; the server banks the box as a Tool there
	local before = #tools("BoxUid")
	local g1, g2 = gates()
	local out = g2 or g1
	local onLane = false
	step("steal: bank walk " .. tgt.id)
	t = os.clock()
	-- a lost box is benched, and an area that keeps taking them is written off for a while
	local function lost(why, where)
		stats.dropped += 1
		benchBox(tgt.box)
		areaDrops[tgt.area] = (areaDrops[tgt.area] or 0) + 1
		log(("box lost (%s): %s x%d in %s at %s, %d in a row here"):format(why, tgt.id, tgt.size, tgt.area, where, areaDrops[tgt.area]))
		if areaDrops[tgt.area] >= AREA_DROPS then
			areaBenchUntil[tgt.area] = os.clock() + AREA_BENCH
			areaDrops[tgt.area] = 0
			log(("skipping %s for %ds"):format(tgt.area, AREA_BENCH))
		end
		return why
	end
	while os.clock() - t < BANK_CAP and alive() do
		if not carry and #tools("BoxUid") > before then
			stats.stolen += 1
			areaDrops[tgt.area] = 0
			return "banked"
		end
		local hh, hp = body()
		if not hh then
			return lost("died", "?")
		end
		local here = ("(%.0f, %.0f)"):format(hp.Position.X, hp.Position.Z)
		if not carry and player:GetAttribute("InStealingArea") then
			return lost("knocked", here)
		end
		-- back to the lane first, then down it toward home
		onLane = onLane or math.abs(hp.Position.Z - lz) < 8
		local aim = onLane and Vector3.new(out.X, hp.Position.Y, lz) or Vector3.new(hp.Position.X, hp.Position.Y, lz)
		hh:MoveTo(steer(hp.Position, aim))
		task.wait(WALK_TICK)
	end
	if not carry and #tools("BoxUid") > before then
		stats.stolen += 1
		areaDrops[tgt.area] = 0
		return "banked"
	end
	return alive() and lost("bank timeout", "?") or "stopped"
end

-- home: place boxes, place pets, sell ---------------------------------------------
local function penSpots()
	local pb = pen()
	local out = {}
	if not pb then
		return out
	end
	local hx, hz = pb.Size.X / 2 - 5, pb.Size.Z / 2 - 5
	for x = -hx, hx, SPOT_STEP do
		for z = -hz, hz, SPOT_STEP do
			out[#out + 1] = (pb.CFrame * CFrame.new(x, 0, z)).Position
		end
	end
	return out
end

local function occupied(pos)
	for _, x in ipairs(plantedList()) do
		-- Planted X/Z are relative to the base's Origin part
		local name = myBaseName()
		local origin = name and workspace.Bases[name]:FindFirstChild("Origin")
		if origin and flat((origin.CFrame * CFrame.new(x.X, 0, x.Z)).Position - pos) < SPOT_STEP - 1 then
			return true
		end
	end
	for _, p in ipairs(workspace.PetRuntime:GetChildren()) do
		if p:GetAttribute("OwnerUserId") == player.UserId and flat(p:GetPivot().Position - pos) < SPOT_STEP - 1 then
			return true
		end
	end
	return false
end

local spotIdx = 0
local function nextSpot()
	local spots = penSpots()
	for _ = 1, #spots do
		spotIdx = spotIdx % #spots + 1
		local p = spots[spotIdx]
		if not occupied(p) then
			local _, _, char = body()
			local rp = RaycastParams.new()
			rp.FilterType = Enum.RaycastFilterType.Exclude
			rp.FilterDescendantsInstances = { char, workspace.BoxRuntime, workspace.PetRuntime }
			local hit = workspace:Raycast(p + Vector3.new(0, 10, 0), Vector3.new(0, -30, 0), rp)
			return hit and hit.Position or p
		end
	end
	return nil
end

-- equip, fire at a free spot, confirm on the Tool leaving us. Returns true, or false + the server's word
local function placeTool(tool, remote, alive)
	for _ = 1, 3 do
		if not alive() then
			return false
		end
		local spot = nextSpot()
		if not spot then
			return false, "no spot"
		end
		-- BoxConfig.MAX_PLACE_RANGE is 60 and the pen is 92 wide: probed MOVE_CLOSER from its far edge
		walkTo(spot, PLACE_NEAR, 8, alive)
		local hum = body()
		if not hum then
			return false, "dead"
		end
		pcall(hum.EquipTool, hum, tool)
		task.wait(0.2)
		local t0 = os.clock()
		remote:FireServer(spot)
		while tool.Parent and os.clock() - t0 < PLACE_CONFIRM and not errSince(t0) do
			task.wait()
		end
		task.wait(PLACE_GAP)
		if not tool.Parent then
			return true
		end
		local e = errSince(t0)
		first(remote.Name .. " refused", e, spot)
		if e ~= "PLACE_INSIDE_PEN" and e ~= nil and not e:find("SPACE") and not e:find("CLOSE") then
			return false, e -- a cap, not a bad spot: stop trying
		end
	end
	return false, "spots"
end

local function boxValue(t)
	return rateOf(t:GetAttribute("BoxId"), t:GetAttribute("AreaId") or "area1")
end

local function petValue(t)
	local ok2, v = pcall(SellConfig.ValueOfIds, t:GetAttribute("VerityId"), t:GetAttribute("AreaId"), t:GetAttribute("MutationId"))
	return ok2 and tonumber(v) or 0
end

local function sellPad()
	local shop = workspace:FindFirstChild(SellConfig.STALL_NAME)
	local pad = shop and shop:FindFirstChild(SellConfig.PAD_NAME, true)
	return pad and pad:IsA("BasePart") and pad or nil
end

-- PEN_FULL (probed: pets at the slot cap) is remembered so the farm stops walking home to hear it again
local fullUntil = { box = 0, pet = 0 }
local FULL_RECHECK = 30

local function sellable(t)
	if t:GetAttribute("Favorited") == true then
		return false
	end
	local okR, rar = pcall(VerityConfig.RarityOf, VerityConfig.Get(t:GetAttribute("VerityId")))
	rar = okR and (type(rar) == "table" and rar.Id or rar) or nil
	return rar ~= nil and sellRarity[rar] == true
end

-- returns whether anything was placed or sold
local function homePass(alive)
	local now = os.clock()
	local boxes = (flags.place and now >= fullUntil.box) and tools("BoxUid") or {}
	local pets = (flags.pets and now >= fullUntil.pet) and tools("PetUid") or {}
	local toSell = 0
	if flags.sell then
		for _, t in ipairs(tools("PetUid")) do
			toSell += sellable(t) and 1 or 0
		end
	end
	-- with free slots a sellable pet is placed first; it is only sold once the pen says full
	if #boxes == 0 and #pets == 0 and (toSell == 0 or (flags.pets and now >= fullUntil.pet)) then
		return false
	end
	say("home: placing", true)
	step("home: walk")
	if not goHome(alive) then
		first("home walk failed", "check the pen gate for your base")
		return false
	end
	local hum, hrp = body()
	if hum then
		hum:MoveTo(hrp.Position)
	end
	local did = false

	table.sort(boxes, function(a, b)
		return boxValue(a) > boxValue(b)
	end)
	local cap = BoxConfig.MAX_PLANTED or 40
	for _, t in ipairs(boxes) do
		if #plantedList() >= cap or not alive() then
			break
		end
		step("home: place box " .. tostring(t:GetAttribute("BoxId")))
		local okP, why = placeTool(t, R.PlaceBox, alive)
		if okP then
			stats.placed += 1
			did = true
		elseif why then
			if why == "PEN_FULL" then
				fullUntil.box = os.clock() + FULL_RECHECK
			end
			say("box not placed: " .. tostring(why))
			break
		end
	end

	table.sort(pets, function(a, b)
		return petValue(a) > petValue(b)
	end)
	for _, t in ipairs(pets) do
		if not alive() then
			break
		end
		step("home: place pet " .. tostring(t:GetAttribute("VerityId")))
		local okP, why = placeTool(t, R.PlacePet, alive)
		if okP then
			stats.pets += 1
			did = true
		else
			if why == "PEN_FULL" then
				fullUntil.pet = os.clock() + FULL_RECHECK
			end
			say("pet not placed: " .. tostring(why))
			break
		end
	end

	if flags.sell and alive() and not (flags.pets and os.clock() >= fullUntil.pet) then
		local uids, gain = {}, 0
		for _, t in ipairs(tools("PetUid")) do
			if sellable(t) then
				uids[#uids + 1] = t:GetAttribute("PetUid")
				gain += petValue(t)
			end
		end
		if #uids > 0 then
			local pad = sellPad()
			if pad then
				walkLeg(pad.Position, 3, LEG_CAP, alive)
			end
			local cash0, t0 = tonumber(prof().Cash) or 0, os.clock()
			step("home: sell " .. #uids)
			R.SellPets:FireServer(uids)
			task.wait(1.5)
			local got = (tonumber(prof().Cash) or 0) - cash0
			first("sell", #uids, "pets, expected ~" .. fmt(gain), "cash moved", fmt(got), "err", tostring(errSince(t0)))
			if got > 0 then
				stats.sold += #uids
				did = true
			end
		end
	end
	return did
end

-- upgrades -----------------------------------------------------------------------
local upgradeAfter = { tread = 0, base = 0 }

local function signButton(kind)
	local _, name = pen()
	if not name then
		return nil
	end
	local tag = kind == "tread" and "TreadmillUpgradeButton" or "BaseUpgradeButton"
	local owner = kind == "tread" and myTreadmill() or workspace.BaseRuntime:FindFirstChild("BaseUpgradeSign_" .. name)
	for _, b in ipairs(CollectionService:GetTagged(tag)) do
		if owner and b:IsDescendantOf(owner) then
			return b
		end
	end
	return nil
end

local function upgradePass(alive)
	local cash = tonumber(prof().Cash) or 0
	for _, kind in ipairs({ "tread", "base" }) do
		local b = signButton(kind)
		local price = b and b:GetAttribute("UpgradePrice")
		if b and type(price) == "number" and cash >= price and os.clock() >= upgradeAfter[kind] and alive() then
			local part = b:FindFirstAncestorWhichIsA("BasePart")
			local tm = treadmillPos()
			if part then
				-- stand by the sign on the side away from the treadmill, or it captures you
				local away = tm and ((part.Position - tm) * FLAT) or Vector3.new(0, 0, 1)
				away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
				walkLeg(part.Position + away * 5, 3, LEG_CAP, alive)
			end
			local t0 = os.clock()
			local remote = kind == "tread" and R.UpgradeTreadmill or R.UpgradeBase
			step("upgrade " .. kind)
			remote:FireServer()
			local tt = os.clock()
			-- probed: the server answers TREADMILL_UPGRADED / BASE_UPGRADED; the treadmill sign is rebuilt
			-- with the model, so the old button's price never changes and is no confirm
			local want = kind == "tread" and "TREADMILL_UPGRADED" or "BASE_UPGRADED"
			while not (lastOkAt >= t0 and lastOk == want) and not errSince(t0) and os.clock() - tt < 2 do
				task.wait(0.1)
			end
			local took = lastOkAt >= t0 and lastOk == want
			first("upgrade " .. kind, took and "bought" or "refused", fmt(price), "err", tostring(errSince(t0)))
			if took then
				stats.upgrades += 1
				say(("upgraded %s for %s"):format(kind == "tread" and "treadmill" or "pet slots", fmt(price)))
			else
				upgradeAfter[kind] = os.clock() + UPGRADE_BACKOFF
			end
			return true
		end
	end
	return false
end

-- treadmill ----------------------------------------------------------------------
local function treadPass(alive, wanted)
	local spot = treadmillPos()
	if not spot then
		first("no treadmill", "TreadmillRuntime has no Treadmill_<base>")
		return false
	end
	if not player:GetAttribute("OnTreadmill") then
		say("walking to the treadmill", true)
		step("treadmill: walk on")
		local t = os.clock()
		while alive() and os.clock() - t < 10 and not player:GetAttribute("OnTreadmill") do
			local hum = body()
			if not hum then
				return false
			end
			hum:MoveTo(spot)
			task.wait(WALK_TICK)
		end
	end
	local s0, t0 = tonumber(prof().Speed) or 0, os.clock()
	while alive() and player:GetAttribute("OnTreadmill") and not wanted() do
		step("treadmill: running") -- a legit long stay, not a stall
		say(("treadmill: +%s Speed/s"):format(fmt(((tonumber(prof().Speed) or 0) - s0) / math.max(os.clock() - t0, 1))), true)
		task.wait(TREAD_SLICE)
	end
	return true
end

-- director: the one thread that drives the character ----------------------------------
local genDir = 0

function anyWalker() -- forward-declared above for the noclip step
	return flags.steal or flags.place or flags.pets or flags.sell or flags.tread or flags.upgrade
end

local function director(mine)
	local alive = function()
		return genDir == mine and anyWalker()
	end
	local banked, lastNone = 0, 0
	-- something other than the treadmill could use the character now
	local function wanted()
		if flags.steal and #tools("BoxUid") < homeAfter and os.clock() - lastNone > 5 and not nightSoon() and pickBox() then
			return true
		end
		if flags.upgrade then
			local cash = tonumber(prof().Cash) or 0
			for _, kind in ipairs({ "tread", "base" }) do
				local b = signButton(kind)
				local price = b and b:GetAttribute("UpgradePrice")
				if type(price) == "number" and cash >= price and os.clock() >= upgradeAfter[kind] then
					return true
				end
			end
		end
		return false
	end
	while alive() do
		local good, err = pcall(function()
			step("director: pass")
			local did = false
			banked = #tools("BoxUid")
			if flags.steal and banked < homeAfter then
				local r = stealOne(function()
					return alive() and flags.steal
				end)
				carriedBox = nil
				if r == "banked" then
					say(("banked %d (%d stolen)"):format(#tools("BoxUid"), stats.stolen), true)
					did = true
				elseif r == "none" or r == "night" then
					lastNone = os.clock()
					say(
						r == "night" and "waiting out the night sweep"
							or ("no box worth stealing in reach (%d you can't outrun or contested)"):format(skippedLast),
						true
					)
				else
					did = true
				end
			end
			if not did or #tools("BoxUid") >= homeAfter or not flags.steal then
				if homePass(alive) then
					did = true
				end
			end
			if flags.upgrade and upgradePass(alive) then
				did = true
			end
			if not did and flags.tread then
				did = treadPass(alive, wanted)
			end
			if not did then
				if player:GetAttribute("OnTreadmill") and not flags.tread then
					leaveTreadmill()
				end
				task.wait(1)
			end
		end)
		if not good then
			warn("[verity] pass failed:", err)
			task.wait(1)
		end
	end
	if genDir == mine then
		local hum, hrp = body()
		if hum then
			hum:MoveTo(hrp.Position)
		end
	end
end

-- separate thread: a farm thread parked in a yield cannot report itself
local genDog = 0
local function watchdog(mine)
	local told = nil
	while genDog == mine do
		task.wait(5)
		if anyWalker() and os.clock() - markAt > STUCK_AFTER and told ~= markAt then
			told = markAt
			warn(("[verity] stuck %ds at: %s"):format(os.clock() - markAt, mark))
		end
	end
end
genDog += 1
task.spawn(watchdog, genDog)

local function setFlag(name, on)
	local was = anyWalker()
	flags[name] = on
	if anyWalker() and not was then
		genDir += 1
		task.spawn(director, genDir)
	elseif not anyWalker() then
		genDir += 1
	end
end

-- open (no movement) -----------------------------------------------------------------
local genOpen = 0
local asked = {}
table.insert(
	conns,
	R.UnboxPlayed.OnClientEvent:Connect(function(_, verityId, areaId, who)
		if who == player then
			stats.opened += 1
			first("unbox", verityId, areaId)
		end
	end)
)

local function openLoop(mine)
	while genOpen == mine do
		pcall(function()
			local now = workspace:GetServerTimeNow()
			for _, x in ipairs(plantedList()) do
				if type(x.UnboxAt) == "number" and x.UnboxAt <= now and os.clock() - (asked[x.Uid] or -99) > OPEN_RETRY then
					asked[x.Uid] = os.clock()
					R.ManageBoxes:FireServer("OPEN", x.Uid)
					task.wait(0.2)
				end
			end
		end)
		task.wait(OPEN_EVERY)
	end
end

local function setOpen(on)
	genOpen += 1
	if on then
		task.spawn(openLoop, genOpen)
	end
end

-- claims ---------------------------------------------------------------------------
local genClaim = 0
local function claimLoop(mine)
	local cash0 = tonumber(prof().Cash) or 0
	pcall(function()
		R.ClaimOfflineReward:FireServer()
	end)
	task.delay(2, function()
		first("offline claim", "cash moved", fmt((tonumber(prof().Cash) or 0) - cash0), "(income counts too)")
	end)
	while genClaim == mine do
		pcall(function()
			R.ClaimAllIndexRewards:FireServer()
		end)
		task.wait(CLAIM_EVERY)
	end
end

local function setClaims(on)
	genClaim += 1
	if on then
		task.spawn(claimLoop, genClaim)
	end
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Steal A Verity!", statusBar = true })
if not Window then
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "package")
local Steal = Tab:AddLeftGroupbox("Steal", "package")
local Home = Tab:AddRightGroupbox("Base", "house")
local Grow = Tab:AddRightGroupbox("Grow", "trending-up")

local boxValues, boxByLabel, boxDefault = {}, {}, {}
local defs = table.clone(BoxConfig.Definitions)
table.sort(defs, function(a, b)
	return rarityOrder(a.RarityId) < rarityOrder(b.RarityId)
end)
for _, d in ipairs(defs) do
	local label = ("%s (%s)"):format(d.DisplayName or d.Id, d.RarityId or "?")
	boxValues[#boxValues + 1] = label
	boxByLabel[label] = d.Id
	boxDefault[#boxDefault + 1] = label
	boxOn[d.Id] = true -- Default does not fire the callback, so arm by hand
end

local rarityValues = {}
for _, r in ipairs(RarityConfig.Definitions) do
	rarityValues[#rarityValues + 1] = r.Id
end

Steal:AddToggle("Steal", {
	Text = "Auto Steal (walked)",
	Tooltip = "Walks to the best box you can reach, holds Steal, walks back out of the area to bank it. Goes home to place after the number below. Never teleports",
	Default = false,
	Callback = function(s)
		setFlag("steal", s)
	end,
})
Steal:AddToggle("Outrun", {
	Text = "Only boxes I can outrun",
	Tooltip = "Skips a box whose area monster would catch you before the spawn (its burst speed against your speed carrying that box), and a box another player is standing by. Beats biggest-first when they disagree",
	Default = true, -- outrunOn starts true: Default does not fire the callback
	Callback = function(s)
		outrunOn = s
	end,
})
Steal:AddToggle("Noclip", {
	Text = "Noclip while walking",
	Tooltip = "Walls and props stop blocking the farm's walks. Speed stays normal, so the anti-teleport check sees nothing; the server's barrier check is untested",
	Default = false,
	Callback = function(s)
		noclip = s
	end,
})
Steal:AddDropdown("Boxes", {
	Text = "Boxes to steal",
	Tooltip = "Only these types are walked to. Read off the box's face; secret and up share one face and all count as the top pick",
	Values = boxValues,
	Default = boxDefault,
	Multi = true,
	Callback = function(picked)
		table.clear(boxOn)
		for label in pairs(ticked(picked)) do
			local id = boxByLabel[label]
			if id then
				boxOn[id] = true
			end
		end
	end,
})
Steal:AddInput("HomeAfter", {
	Text = "Go home after N boxes",
	Tooltip = "Banked boxes wait in your backpack (up to 200). Higher = fewer walks home, placed later",
	Default = tostring(HOME_AFTER),
	Numeric = true,
	Finished = true,
	Callback = function(v)
		local n = tonumber(v)
		homeAfter = (n and n >= 1) and math.floor(n) or HOME_AFTER
	end,
})

Home:AddToggle("Place", {
	Text = "Auto Place Boxes",
	Tooltip = "At home, banked boxes go into your pen, best first",
	Default = false,
	Callback = function(s)
		setFlag("place", s)
	end,
})
Home:AddToggle("Open", {
	Text = "Auto Open Boxes",
	Tooltip = "Opens each planted box the moment its timer is up. Does not move you",
	Default = false,
	Callback = setOpen,
})
Home:AddToggle("Pets", {
	Text = "Auto Place Pets",
	Tooltip = "At home, pets in your backpack go into the pen, best first, until the slots are full",
	Default = false,
	Callback = function(s)
		setFlag("pets", s)
	end,
})
Home:AddToggle("Sell", {
	Text = "Auto Sell Pets",
	Tooltip = "At home, held pets of the ticked rarities that did not fit in the pen are sold at the Sell Shop. Favorited pets are never sold",
	Default = false,
	Callback = function(s)
		setFlag("sell", s)
	end,
})
Home:AddDropdown("SellRarity", {
	Text = "Rarities to sell",
	Tooltip = "Nothing ticked to start with",
	Values = rarityValues,
	Default = {},
	Multi = true,
	Callback = function(picked)
		table.clear(sellRarity)
		for id in pairs(ticked(picked)) do
			sellRarity[id] = true
		end
	end,
})

Grow:AddToggle("Treadmill", {
	Text = "Auto Treadmill",
	Tooltip = "Stands on your treadmill whenever nothing else needs you. Speed unlocks the further areas",
	Default = false,
	Callback = function(s)
		setFlag("tread", s)
	end,
})
Grow:AddToggle("Upgrade", {
	Text = "Auto Upgrade",
	Tooltip = "Walks to your treadmill / pet-slot sign and buys the next level once you can afford it. Robux buttons are never touched",
	Default = false,
	Callback = function(s)
		setFlag("upgrade", s)
	end,
})
Grow:AddToggle("Claims", {
	Text = "Auto Claims",
	Tooltip = "Index rewards every 2 min, offline cash once. The free gift needs the group and is left alone",
	Default = false,
	Callback = setClaims,
})

local note = "idle"
local nextStrip = 0
table.insert(
	conns,
	RunService.Heartbeat:Connect(function()
		if pending then
			note, pending = pending, nil
		end
		local now = os.clock()
		if now < nextStrip then
			return
		end
		nextStrip = now + STATUS_EVERY
		local p = prof()
		Window:SetStatus({
			{ "Cash", fmt(p.Cash) },
			{ "Speed", fmt(p.Speed) },
			{ "Stolen", stats.stolen .. (stats.failed + stats.dropped > 0 and (" (" .. stats.failed .. " refused, " .. stats.dropped .. " lost)") or "") },
			{ "Bank", #tools("BoxUid") },
			{ "Planted", #plantedList() },
			{ "Pets", myPetCount() .. "/" .. tostring(select(2, pcall(PetConfig.SlotsFor, p.ExtraPetSlots))) },
			{ "Now", note },
		})
	end)
)

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("StealAVerity", {})

local VirtualUser = game:GetService("VirtualUser")
table.insert(
	conns,
	player.Idled:Connect(function()
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end)
)

-- close ----------------------------------------------------------------------
local function stopAll()
	for k in pairs(flags) do
		flags[k] = false
	end
	genDir += 1
	genDog += 1
	noclip = false
	carriedBox = nil
	setOpen(false)
	setClaims(false)
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
	restoreCollision()
end

Library:OnUnload(function()
	stopAll()
	getgenv().stealVerityStop = nil
end)

getgenv().stealVerityStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().stealVerityStop = nil
end
