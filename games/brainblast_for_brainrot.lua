--[[ Brainblast for Brainrot -- charge, blast, keep the brainrot (102990893659741)

     BLAST    : the whole loop, with the theater cut out. TP to the pad, RequestBlastCharge,
                FireBlast claiming a perfect 1.0, answer the reveal the instant it lands,
                and teleport home ahead of the zombie. ~12s a cycle, every one a Perfect.

                What it can NOT skip is the flight. FireBlast to BlastLanded is ten seconds
                of server-side timer -- the client sends nothing during it but optional
                steering, so there is no message that lands you early. What the script
                removes is the throw animation, the flight camera, the reveal card and the
                chase; the ten seconds you now spend standing on the pad with your camera
                free, which is also why Auto Train runs happily underneath it.

     TRAIN    : fires Training.EquipBook on a timer. The server never checks whether the
                tool is actually in your hand -- brain power ticks ~1/s from anywhere,
                blast zone included -- so this needs no book out and no training spot.
     PLACE    : PlaceBest when the bag fills, which empties it into your base slots.
                Without it a full bag stops the farm dead: BlastClient hides the blast
                button at InventoryCount >= InventoryMax and the server agrees.
     COLLECT  : CollectCash on every slot of your base that has cash stored.

     Severing is one-way. Turning Auto Blast on disables the game's own handlers for the
     throw, flight, reveal and chase, and Roblox has no re-enable -- rejoin to get the
     normal game back. Everything else here leaves the client alone.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().brainBlastStop() ]]

-- config ---------------------------------------------------------------------
local ACCURACY = 1 -- what FireBlast claims your charge timing was, 0..1. The client
-- computes this itself and the server takes it on faith -- 1 came back "Perfect 1 1.5".
-- Lower it only if a future update starts rejecting a suspiciously perfect run.
local POWER_CAP = -1 -- second FireBlast argument, the game's own power cap. -1 is uncapped:
-- max distance, best zone, longest flight. A positive number lands you shorter and sooner,
-- so this is the one throughput dial there is -- fewer studs, worse rarity, faster cycles.
local SETTLE = 1 -- seconds after the TP to the pad before the server agrees you're on it.
-- Raise it if cycles start failing with "never entered the zone".
local ZONE_WAIT = 8 -- seconds to wait for the server's ShowBlastButton after arriving
local CHARGE_TIMEOUT = 5 -- seconds to wait for the charge nonce. It came back in 0.18s.
local CYCLE_DEADLINE = 45 -- seconds for a whole blast to resolve before we give up and
-- start over. The flight alone is ~10s; this is generous on purpose, because a cycle that
-- restarts early fires a second RequestBlastCharge into a server that is still busy.
local CHASE_GRACE = 1.5 -- seconds to wait after the reveal for a zombie that may never come.
-- BalanceConfig has ZombieChase.ChanceAfterBlast = 50 and SpawnDelay = 1: half your blasts
-- get no zombie at all, and the ones that do announce it within a second. Waiting 4s here
-- was costing ~2.5 idle seconds on every second cycle.
local TRAIN_EVERY = 10 -- seconds between EquipBook re-fires. Once was enough for the 15s
-- the probe watched; re-firing is a free remote and covers the server forgetting on death.
local UNFREEZE_EVERY = 0.25 -- seconds between putting your WalkSpeed back while training.
-- Training freezes you on purpose -- that's the pose -- and it's done server-side, so this
-- is a fight rather than a fix. Lower it if walking still feels sticky.
local COLLECT_EVERY = 5 -- seconds between cash sweeps of your base
local PLACE_EVERY = 3 -- seconds between full-bag checks
local IDLE = 0.3 -- seconds between cycles

local KEY_TOGGLE = Enum.KeyCode.RightControl

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

if getgenv and getgenv().brainBlastStop then
	getgenv().brainBlastStop() -- re-running must not stack a second panel/loop
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Blast = Remotes:WaitForChild("Blast")
local Zombie = Remotes:WaitForChild("Zombie")
local Training = Remotes:WaitForChild("Training")
local Bases = Remotes:WaitForChild("Bases")
local Totem = Remotes:WaitForChild("Totem")

local uid = tostring(player.UserId)
local say = function() end -- replaced by the panel below

-- world ----------------------------------------------------------------------
local function hrp()
	local char = player.Character or player.CharacterAdded:Wait()
	return char:WaitForChild("HumanoidRootPart", 10)
end

-- Both parts live under one model and neither moves, so this resolves once. The pad is
-- where the server decides you're allowed to blast; SafeArea is the only safe area in the
-- game (ChaseClient/World.lua getSafeAreaPart hardcodes this exact path), which is why the
-- chase is a run home rather than a run anywhere.
local function zoneParts()
	local zones = workspace:FindFirstChild("Zones")
	local bz = zones and zones:FindFirstChild("BlastZone")
	if not bz then
		return nil, nil
	end
	return bz:FindFirstChild("BlastArea"), bz:FindFirstChild("SafeArea")
end

local function tp(pos)
	local root = hrp()
	if not root then
		return false
	end
	root.CFrame = CFrame.new(pos + Vector3.new(0, 4, 0))
	while player.GameplayPaused do
		task.wait(0.1)
	end
	return true
end

local function full()
	local count = tonumber(player:GetAttribute("InventoryCount")) or 0
	local max = tonumber(player:GetAttribute("InventoryMax")) or 0
	return max > 0 and count >= max, count, max
end

-- Training freezes you, and it is the SERVER doing it: BookTrainingClient never touches
-- your Humanoid, so there is nothing client-side to switch off. What there is instead is
-- network ownership -- your client owns your own character's physics, so writing the
-- numbers back locally sticks even though the server keeps zeroing them.
--
-- ponytail: a fight, not a fix, hence the 0.25s beat. The clean version would be whatever
-- the server checks before applying the freeze, and we cannot see the server.
local baseSpeed, thawed = 16, false
local function thaw()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local what
	if hum and hum.WalkSpeed < 1 then
		hum.WalkSpeed = baseSpeed
		what = "WalkSpeed"
	end
	if hum and hum.UseJumpPower and hum.JumpPower < 1 then
		hum.JumpPower = 50
	end
	if root and root.Anchored then
		root.Anchored = false
		what = what and (what .. "+Anchored") or "Anchored"
	end
	-- Said once, not every quarter second: the point is to know WHICH lever the server
	-- pulled, so an update that starts freezing you a different way is visible.
	if what and not thawed then
		thawed = true
		print("[brainblast] training froze you via " .. what .. " -- restoring it locally")
	end
end

-- Any Tool the game marks as a book, wherever it currently lives. The BookId attribute is
-- the only thing EquipBook wants, and the tool never has to leave the backpack.
local function books()
	local out = {}
	for _, where in ipairs({ player:FindFirstChild("Backpack"), player.Character }) do
		for _, t in ipairs(where and where:GetChildren() or {}) do
			if t:IsA("Tool") and t:GetAttribute("IsBookTool") and t:GetAttribute("BookId") then
				out[#out + 1] = t:GetAttribute("BookId")
			end
		end
	end
	return out
end

-- sever ------------------------------------------------------------------------
-- Everything the game plays between pressing blast and holding the brainrot is a handler
-- on one of these events. Disable() them and the animations simply never start -- which
-- also disposes of the camera hijack, the movement lock and the HRP anchor that came with
-- them. The handshakes those handlers used to send are re-sent below, by us.
--
-- ponytail: one-way. Roblox has no Enable(), so the off branch cannot put the game back
-- and the header says "rejoin". Reconnecting the originals would mean holding their
-- closures, which getconnections does not hand out.
local SEVER = {
	{ Blast, "ShowBlastButton" }, -- grab animation + the lucky block that appears in your hands
	{ Blast, "BlastChargeStarted" }, -- charge camera, character freeze, the charge bar
	{ Blast, "BlastResult" }, -- the PERFECT! label
	{ Blast, "BlastLaunched" }, -- the throw
	{ Blast, "BlastFlightUpdate" }, -- the flight camera, per frame
	{ Blast, "BlastLanded" }, -- landing zoom, explosion, dust
	{ Blast, "BlastReveal" }, -- DropController's reveal card and its tap-to-continue
	{ Zombie, "ZombieSpawn" }, -- the whole chase: camera pin, zombie, run-home UI
	{ Totem, "DropPlay" }, -- totem drop showcase
}

local wired = false
local inZone, cyc = false, nil
local conns = {}

local function wire()
	if wired then
		return
	end
	wired = true

	if not getconnections then
		say("no getconnections: animations stay, the loop still runs")
		warn("[brainblast] executor has no getconnections -- nothing severed, expect the full show")
	else
		local n = 0
		for _, pair in ipairs(SEVER) do
			local remote = pair[1]:FindFirstChild(pair[2])
			if remote then
				local ok, list = pcall(getconnections, remote.OnClientEvent)
				for _, c in ipairs(ok and list or {}) do
					pcall(function()
						c:Disable()
						n += 1
					end)
				end
			end
		end
		print(("[brainblast] severed %d handlers"):format(n))
	end

	-- Ours go on AFTER the severing, never before: getconnections hands back every handler
	-- on the event, ours included, and disabling our own listener is a silent way to build
	-- a loop that fires once and then waits forever.
	local function on(remote, fn)
		conns[#conns + 1] = remote.OnClientEvent:Connect(fn)
	end

	on(Blast.ShowBlastButton, function()
		inZone = true
	end)
	on(Blast.HideBlastButton, function()
		inZone = false
	end)
	on(Blast.BlastChargeStarted, function(nonce)
		if cyc then
			cyc.nonce = nonce
		end
	end)
	on(Blast.BlastLanded, function(zone, _, mult)
		if cyc then
			cyc.zone, cyc.mult = zone, mult
		end
	end)

	-- The reward is already decided by the time BlastReveal arrives -- the payload carries
	-- the rolled brainrot -- so answering it immediately costs nothing and skips the card.
	on(Blast.BlastReveal, function(payload)
		if cyc then
			cyc.rarity = type(payload) == "table" and ((payload.rollResult or {}).rarity or payload.finalRarity)
			cyc.revealedAt = os.clock()
		end
		pcall(function()
			Blast.RevealComplete:FireServer()
		end)
	end)

	-- Your character never actually flies -- the HRP stays by the pad while the visuals go
	-- to the landing zone -- so "running home" is a hop of a few dozen studs and the server
	-- accepts it without a rubber-band. ChaseReady first: the server waits for it.
	on(Zombie.ZombieSpawn, function()
		pcall(function()
			Zombie.ChaseReady:FireServer()
		end)
		local _, safe = zoneParts()
		if safe then
			tp(safe.Position)
		end
	end)

	on(Zombie.PlayerRestore, function(ok)
		if cyc then
			cyc.done = ok ~= false
		end
	end)

	on(Totem.DropPlay, function()
		pcall(function()
			Totem.DropClaimed:FireServer()
		end)
	end)
end

-- farm -------------------------------------------------------------------------
local function waitFor(pred, timeout)
	local deadline = os.clock() + timeout
	while not pred() and os.clock() < deadline do
		task.wait(0.1)
	end
	return pred()
end

local blasting, blastGen = false, 0
local cycles = 0

local function oneBlast()
	local pad = zoneParts()
	if not pad then
		say("no BlastZone in workspace")
		return false
	end

	local isFull, count, max = full()
	if isFull then
		say(("inventory full (%d/%d)"):format(count, max))
		return false
	end

	tp(pad.Position)
	task.wait(SETTLE)
	if not waitFor(function()
		return inZone
	end, ZONE_WAIT) then
		say("not in the blast zone -- raise SETTLE?")
		return false
	end

	cyc = {}
	Blast.RequestBlastCharge:FireServer()
	if not waitFor(function()
		return cyc.nonce ~= nil
	end, CHARGE_TIMEOUT) then
		say("no charge nonce -- server refused")
		return false
	end

	Blast.FireBlast:FireServer(ACCURACY, POWER_CAP, cyc.nonce)

	-- Done is PlayerRestore, the server's own "you made it" -- but a landing that spawns no
	-- zombie never sends one, so a revealed cycle also ages out after CHASE_GRACE.
	local ok = waitFor(function()
		return cyc.done or (cyc.revealedAt and os.clock() - cyc.revealedAt > CHASE_GRACE)
	end, CYCLE_DEADLINE)

	if ok then
		cycles += 1
		local _, now, cap = full()
		say(("#%d %s x%s  bag %d/%d"):format(cycles, tostring(cyc.rarity or cyc.zone or "?"), tostring(cyc.mult or "?"), now, cap))
	else
		say("cycle timed out, restarting")
	end
	cyc = nil
	return ok
end

local function setBlasting(v)
	blasting = v
	if not v then
		return
	end
	wire()
	blastGen += 1
	local mine = blastGen
	task.spawn(function()
		while blasting and blastGen == mine do
			local ok = pcall(oneBlast) -- a refusal is the normal case, not a reason to stop
			task.wait(ok and IDLE or 1)
		end
	end)
end

-- One generation counter per timer loop: toggling off and on inside a single interval
-- otherwise leaves the sleeping thread alive next to the new one, firing at double rate.
local function every(state, interval, body)
	state.gen += 1
	local mine = state.gen
	task.spawn(function()
		while state.on and state.gen == mine do
			pcall(body)
			task.wait(interval)
		end
	end)
end

local trainer = { on = false, gen = 0 }
local placer = { on = false, gen = 0 }
local collector = { on = false, gen = 0 }
local pickedBook = books()[1]

local function collect()
	local bases = workspace:FindFirstChild("ActiveBases")
	local mine = bases and bases:FindFirstChild(uid)
	for _, slot in ipairs(mine and mine:GetDescendants() or {}) do
		-- ponytail: found by attribute, not by the Piso1.Slot_1_N path, so an extra floor
		-- joins the sweep on its own. If the server ever refuses these, the fix is to TP
		-- home first -- the game's own version fires them from a touch on the slot.
		local key = slot:GetAttribute("SlotKey")
		if key and (slot:GetAttribute("CashStored") or 0) > 0 then
			pcall(function()
				Bases.CollectCash:FireServer(key)
			end)
		end
	end
end

-- gui ---------------------------------------------------------------------------
-- Everything brand-shaped lives in panel.lua: topbar, icon, shade, keys. Fetched here
-- rather than installed by the loader, so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Brainblast for Brainrot", -- fallback until the live name lands
	folder = "BrainBlast", -- unchanged: renaming it orphans configs already saved in-game
	size = UDim2.fromOffset(460, 400),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:bolt-circle-bold" })
local Farm = Tab:Section({ Title = "Blast", Icon = "solar:bomb-emoji-bold", Box = true, BoxBorder = true, Opened = true })
local Base = Tab:Section({ Title = "Base", Icon = "solar:home-2-bold", Box = true, BoxBorder = true, Opened = true })

Farm:Toggle({
	Title = "Auto Blast",
	Desc = "Perfect charge, no animations, home before the zombie. ~12s a cycle",
	Value = false,
	Callback = setBlasting,
})

Farm:Toggle({
	Title = "Auto Train",
	Desc = "Brain power ticks with no book in hand, anywhere -- runs during blasting",
	Value = false,
	Callback = function(v)
		trainer.on = v
		if not v then
			return
		end
		if not pickedBook then
			pickedBook = books()[1]
		end
		if not pickedBook then
			say("no book owned -- buy one first")
			return
		end
		-- Capture the speed BEFORE the first EquipBook, or we memorise the frozen 0 and
		-- spend the session restoring you to standing still.
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum and hum.WalkSpeed > 1 then
			baseSpeed = hum.WalkSpeed
		end
		-- One loop, two jobs: the thaw needs a fast beat, the remote does not, so the
		-- remote rides the same thread on a timer rather than owning a second one.
		local lastEquip = 0
		every(trainer, UNFREEZE_EVERY, function()
			thaw()
			if os.clock() - lastEquip >= TRAIN_EVERY then
				lastEquip = os.clock()
				Training.EquipBook:FireServer(pickedBook)
			end
		end)
	end,
})

local owned = books()
Farm:Dropdown({
	Title = "Book",
	Desc = "Which book to train with. Highest tier you own is the one worth picking",
	Values = #owned > 0 and owned or { "none owned" },
	Value = pickedBook or "none owned",
	Callback = function(v)
		pickedBook = v ~= "none owned" and v or nil
	end,
})

Farm:Input({
	Title = "Power cap",
	Desc = "-1 is uncapped: farthest zone, best rarity, ~10s flight. Lower lands you sooner",
	Value = tostring(POWER_CAP),
	Placeholder = "-1",
	Callback = function(v)
		POWER_CAP = tonumber(v) or -1
	end,
})

Base:Toggle({
	Title = "Auto Place",
	Desc = "PlaceBest when the bag is full -- a full bag is what stops the blast loop",
	Value = false,
	Callback = function(v)
		placer.on = v
		if v then
			every(placer, PLACE_EVERY, function()
				if full() then
					Bases.PlaceBest:FireServer()
				end
			end)
		end
	end,
})

Base:Toggle({
	Title = "Auto Collect",
	Desc = "CollectCash on every slot holding cash",
	Value = false,
	Callback = function(v)
		collector.on = v
		if v then
			every(collector, COLLECT_EVERY, collect)
		end
	end,
})

Base:Button({
	Title = "Place best now",
	Callback = function()
		Bases.PlaceBest:FireServer()
		say("placed")
	end,
})

local line = Farm:Paragraph({ Title = "Status", Desc = "idle" })
say = function(msg)
	line:SetDesc(msg)
	print("[brainblast] " .. msg)
end

-- close ---------------------------------------------------------------------------
local function stopAll()
	trainer.on, placer.on, collector.on = false, false, false
	setBlasting(false)
	for _, c in ipairs(conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(conns)
	wired = false -- a later re-run re-wires; the game's handlers stay severed either way
end

Window:OnDestroy(function()
	stopAll()
	getgenv().brainBlastStop = nil
end)

getgenv().brainBlastStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().brainBlastStop = nil
end
