--[[ Steal an Animal (123822115505881) -- grab base animals and run them home

     STEAL     : sweep workspace.EntitiesFolder, take the richest animal whose
                 BaseNumber you own, carry it to your plot, repeat. The grab is a
                 plain ProximityPrompt -- no client script binds it, so the server
                 owns Triggered and fireproximityprompt IS the whole action.
     NO GUARDS : the base defenders are CLIENT-side clones -- FollowerHandler.lua
                 does `defender.Parent = workspace` locally, and it is the CLIENT
                 that fires DropEntity when one catches you. Delete them and a
                 carry can never be taken off you. Turn this on before STEAL.
     BUY BASES : "You don't own this base" is a SERVER check against the entity's
                 BaseNumber attribute. There is no client bypass -- the only fix is
                 owning it, so this walks 1..N through TryPurchaseBase.
     RANCH     : the other steal, off other players' ranches. Separate mechanic.
     CASH      : touches each animal on your plot. Nothing here calls a remote that
                 the server answers with a Robux prompt -- see the note by collectCash.

     Executor only (the UI is WindUI over HttpGet). Stop: getgenv().stealAnimalStop()

     Untested against a live server -- everything here was read out of the
     123822115505881 dump, not off a spy log. If a toggle does nothing, check F9. ]]

-- config ---------------------------------------------------------------------
local SETTLE = 0.25 -- floor on the post-teleport wait; the real wait is ping-derived below
local GRAB_TIMEOUT = 3.0 -- give up on a prompt that never sets Carrying (someone beat you to it)
local CARRY_TIMEOUT = 8.0 -- sitting on your own plot this long without a PlacedEntity = stuck, re-teleport
local STEAL_WAIT = 0.3 -- between carries. The round trip already paces this; this is just breathing room
local RANCH_WAIT = 0.6 -- between ranch steals. Server rate-limits StealStand; raise if it returns false
local PLACE_WAIT = 0.4 -- between placements
local PLACE_TIMEOUT = 4.0 -- how long to wait for the server to take a placed animal
local CASH_WAIT = 1.0 -- between collect sweeps. One sweep touches every animal on your plot
local GUARD_WAIT = 0.5 -- how often to sweep workspace for respawned defenders
local BASE_WAIT = 3.0 -- spends cash, so slow. One pass = one attempt at every base
local MIN_MPS = 0 -- ignore animals earning less than this per second. 0 = take everything

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Stats = game:GetService("Stats")
local player = Players.LocalPlayer

if getgenv and getgenv().stealAnimalStop then
	getgenv().stealAnimalStop() -- re-running must not stack a second panel or a second set of loops
end

-- The game keeps every remote in one table, so there is no path-guessing to do here.
local RemoteBank = require(ReplicatedStorage:WaitForChild("RemoteBank"))
local Entities = require(ReplicatedStorage.DataModules.Entities)
local Bases = require(ReplicatedStorage.DataModules.Bases)
-- Which bases you own, live. FollowerHandler reads the same key to decide whether
-- to draw a PurchaseZone, so it is the client's own copy of the server's answer.
local DataService = require(ReplicatedStorage.Utilities.DataService)
-- GetValueFromId does the whole valuation: species x mutation x upgradeLevel x
-- rebirth x index bonus. Reimplementing that would be four modules of arithmetic
-- that goes stale on the next balance patch.
local SharedFunctions = require(ReplicatedStorage.DataModules.SharedFunctions)
local GlobalConfiguration = require(ReplicatedStorage.DataModules.GlobalConfiguration)

local running = true -- flipped by Close; every loop watches it

local function send(remote, method, ...)
	-- The server rejecting a steal (too far, no product, cooldown) is the normal
	-- case in a farm loop, not a reason to kill the thread.
	local ok, res = pcall(remote[method], remote, ...)
	if not ok then
		warn("[StealAnimal]", res)
		return false
	end
	return res ~= false
end

-- world ----------------------------------------------------------------------
-- Ranch animals are found by tag, never by path: RanchPickupPrompts.lua watches
-- CollectionService "RanchEntity" and the three attributes below are the entire
-- contract it uses. Survives any workspace reshuffle.
local function rank(entityName)
	local e = Entities[entityName]
	return e and e.MoneyPerSecond or 0
end
assert(rank("Chicken") == 50, "Entities.Chicken.MoneyPerSecond moved")
assert(rank("not a real animal") == 0, "unknown names must sort last, not error")

local ping = Stats.Network.ServerStatsItem["Data Ping"]

-- After a teleport the server has not seen you move yet, and a steal fired in that
-- window is judged from your OLD position. Wait a round trip, then wait out any
-- streaming pause. This is why a steal "silently doesn't take".
local function tpTo(cf)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return false
	end
	hrp.CFrame = cf
	task.wait(math.max(SETTLE, (ping:GetValue() * 4) / 1000))
	while running and player.GameplayPaused do
		task.wait(0.1)
	end
	return true
end

-- Base animals live flat in workspace.EntitiesFolder, one Model per animal named
-- after its species ("Giraffe"), with the prompt buried on whatever the rig calls
-- its root MeshPart (A_20, A_35, ...). Never name that part -- it differs per
-- species. BaseNumber is the only attribute that matters: it is what the server
-- checks before it lets you have the animal.
local entitiesFolder = workspace:WaitForChild("EntitiesFolder")

local function ownedBases()
	local ok, list = pcall(function()
		return DataService.client:get("bases")
	end)
	return ok and list or {}
end

local function baseTargets()
	local owned = ownedBases()
	local out = {}
	for _, m in ipairs(entitiesFolder:GetChildren()) do
		local n = m:GetAttribute("BaseNumber")
		-- Skipping unowned bases client-side is not a bypass, it is politeness:
		-- firing those prompts just earns you "You don't own this base" 88 times
		-- a sweep and buries anything useful in the console.
		if typeof(n) == "number" and table.find(owned, n) then
			local mps = rank(m.Name)
			local prompt = m:FindFirstChildWhichIsA("ProximityPrompt", true)
			if prompt and mps >= MIN_MPS then
				table.insert(out, { model = m, prompt = prompt, mps = mps })
			end
		end
	end
	table.sort(out, function(a, b)
		return a.mps > b.mps -- richest first; the cheap ones respawn either way
	end)
	return out
end

-- Grab, then run it home. Both halves confirm against the world rather than a
-- return value: Carrying goes to the base number on a successful grab and back to
-- nil when the server accepts the animal onto your plot (the same moment it fires
-- PlacedEntity). Watching the attribute means one check covers both events.
local function carryHome(plot)
	local deadline = os.clock() + CARRY_TIMEOUT
	while running and player:GetAttribute("Carrying") do
		if os.clock() > deadline then
			return false -- re-teleport rather than stand there; usually a streaming stall
		end
		tpTo(plot:GetPivot())
		task.wait(0.2)
	end
	return true
end

local function grabOne(t, plot)
	local part = t.prompt.Parent
	if not part or not part:IsA("BasePart") or not part.Parent then
		return false -- streamed out between the scan and now
	end
	if not tpTo(part.CFrame) then
		return false
	end
	local deadline = os.clock() + GRAB_TIMEOUT
	repeat
		pcall(fireproximityprompt, t.prompt)
		task.wait()
	until not running
		or player:GetAttribute("Carrying")
		or t.model.Parent ~= entitiesFolder
		or os.clock() > deadline
	if not player:GetAttribute("Carrying") then
		return false
	end
	return carryHome(plot)
end

local function baseLoop(alive)
	local plot = RemoteBank.GetPlot:InvokeServer()
	if not plot then
		warn("[StealAnimal] GetPlot returned nothing - no plot to carry to")
		return
	end
	-- A carry left over from a previous run blocks the first grab.
	if player:GetAttribute("Carrying") then
		carryHome(plot)
	end
	while alive() and running do
		local list = baseTargets()
		if #list == 0 then
			task.wait(1) -- everything taken, or you own no bases yet
		end
		for _, t in ipairs(list) do
			if not (alive() and running) then
				break
			end
			grabOne(t, plot)
			task.wait(STEAL_WAIT)
		end
		task.wait(0.1)
	end
end

local function ranchTargets()
	local out = {}
	for _, m in ipairs(CollectionService:GetTagged("RanchEntity")) do
		local owner = m:GetAttribute("RanchOwnerUserId")
		local slot = m:GetAttribute("RanchSlotNumber")
		-- typeof checks mirror the game's own -- these attributes are nil for a
		-- beat while an animal is being placed.
		if typeof(owner) == "number" and typeof(slot) == "number" and owner ~= player.UserId then
			local victim = Players:GetPlayerByUserId(owner)
			local mps = rank(m:GetAttribute("EntityName") or m.Name)
			if victim and mps >= MIN_MPS then
				table.insert(out, { model = m, victim = victim, slot = slot, mps = mps })
			end
		end
	end
	table.sort(out, function(a, b)
		return a.mps > b.mps -- richest first, so a rate-limit costs you the cheap ones
	end)
	return out
end

-- farm -----------------------------------------------------------------------
local function ranchSteal(t)
	local part = t.model.PrimaryPart or t.model:FindFirstChildWhichIsA("BasePart", true)
	if not part or not part.Parent then
		return false -- streamed out between the scan and now
	end
	if not tpTo(part.CFrame) then
		return false
	end
	-- StealStand is a RemoteFunction returning a boolean. The client's own
	-- ProximityPrompt is gated on a paid dev product (DevProducts.GetStealProductId),
	-- but that gate only decides whether the PROMPT is drawn -- calling the remote
	-- skips it. Whether the server re-checks the product is the open question; a
	-- steady stream of `false` here is the answer being no.
	return send(RemoteBank.StealStand, "InvokeServer", t.victim, t.slot)
end

local function ranchLoop(alive)
	while alive() and running do
		local list = ranchTargets()
		if #list == 0 then
			task.wait(1) -- nothing in the server right now; don't spin
		end
		for _, t in ipairs(list) do
			if not (alive() and running) then
				break
			end
			ranchSteal(t)
			task.wait(RANCH_WAIT)
		end
		task.wait(0.1)
	end
end

-- place ----------------------------------------------------------------------
-- Placing an animal fires NO remote -- a spy hook over FireServer/InvokeServer logs
-- nothing during a manual place. It is native Tool.Activated replication, which the
-- engine drives from real input. Tool:Activate() from a script fires Activated on
-- the CLIENT only and never reaches the server, so a click has to be synthesised.
-- ponytail: also used by the anti-afk nudge below, which is why it lives up here.
local hasVU, vu = pcall(game.GetService, game, "VirtualUser")

local function clickOnce()
	if not hasVU then
		return false
	end
	local cf = workspace.CurrentCamera and workspace.CurrentCamera.CFrame or CFrame.new()
	-- ponytail: (0,0) is top-left. If the WindUI panel ever sits there it will eat
	-- the click -- move the coordinate rather than hiding the window.
	return pcall(function()
		vu:CaptureController()
		vu:Button1Down(Vector2.new(0, 0), cf)
		task.wait(0.05)
		vu:Button1Up(Vector2.new(0, 0), cf)
	end)
end

-- Inventory animals are Tools tagged "Entity" carrying an Id attribute; the hotbar
-- is just the Tool sitting in Character instead of Backpack, so both are scanned.
-- Tool.Name is display text ("Diamond Hampster") -- never key off it. The Id is what
-- the game's own inventory table is keyed by.
local function inventoryTools()
	local out = {}
	for _, src in ipairs({ player.Backpack, player.Character }) do
		if src then
			for _, tool in ipairs(src:GetChildren()) do
				if tool:IsA("Tool") and tool:HasTag("Entity") then
					local id = tool:GetAttribute("Id")
					if id then
						local ok, value = pcall(SharedFunctions.GetValueFromId, id)
						table.insert(out, { tool = tool, value = (ok and value) or 0 })
					end
				end
			end
		end
	end
	table.sort(out, function(a, b)
		return a.value > b.value
	end)
	return out
end

local function ranchFull(plot)
	local folder = plot:FindFirstChild("RanchEntities")
	if not folder then
		return false -- can't see the folder, so don't refuse to place
	end
	local limits = GlobalConfiguration.RanchAnimalLimits
	local level = math.clamp(DataService.client:get("ranchLevel") or GlobalConfiguration.StarterRanchLevel or 1, 1, #limits)
	return #folder:GetChildren() >= (limits[level] or limits[#limits])
end

-- Equip, click, wait for the tool to leave your inventory -- that last part is the
-- server confirming, the same way every other confirm in this file works.
-- Tool:Activate() is kept only as the degraded path for a client with no
-- VirtualUser; on its own it does not replicate.
local function placeOne(entry, plot)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or not entry.tool.Parent then
		return false
	end
	tpTo(plot:GetPivot()) -- placing anywhere but your own plot is not a thing
	hum:EquipTool(entry.tool)
	task.wait(0.2) -- the server has to see the equip before the click means anything
	if not clickOnce() then
		pcall(function()
			entry.tool:Activate()
		end)
	end
	local deadline = os.clock() + PLACE_TIMEOUT
	repeat
		task.wait(0.1)
	until not entry.tool.Parent or os.clock() > deadline
	return entry.tool.Parent == nil
end

local function placeLoop(alive)
	local plot = RemoteBank.GetPlot:InvokeServer()
	if not plot then
		warn("[StealAnimal] GetPlot returned nothing - nowhere to place")
		return
	end
	while alive() and running do
		if ranchFull(plot) then
			task.wait(2) -- nothing to do until you sell or a steal takes one off you
		else
			local list = inventoryTools()
			if #list == 0 then
				task.wait(1)
			end
			for _, entry in ipairs(list) do
				if not (alive() and running) or ranchFull(plot) then
					break
				end
				if not placeOne(entry, plot) then
					-- One failure is a streaming hiccup; every animal failing means
					-- Activate is the wrong channel. Say so once per sweep, not once
					-- per animal.
					warn("[StealAnimal] place did not take:", entry.tool.Name)
					break
				end
				task.wait(PLACE_WAIT)
			end
		end
		task.wait(0.2)
	end
end

-- CollectAllCash is NOT free: it is the "Collect All Button (PERMANENT)" dev product
-- (4 Robux). GuiController.lua binds the button straight to the remote with no
-- ownership check of its own, so the server answers an un-owned invoke by opening a
-- purchase prompt -- and on a loop it reopens it forever. Don't call it.
--
-- Every ranch animal carries its own TouchTransmitter instead, so touching them one
-- at a time is the same cash for nothing. CashBillboard is the marker to scan for:
-- the folder name (RanchEntities) is a detail of the plot template, the billboard is
-- the thing that means "this animal is holding money".
local function collectCash(plot)
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	if not head then
		return
	end
	for _, d in ipairs(plot:GetDescendants()) do
		if d:IsA("BasePart") and d:FindFirstChild("CashBillboard") then
			-- 0 = touch begin, 1 = touch end. Both halves, or the server never sees
			-- a completed touch.
			pcall(firetouchinterest, head, d, 0)
			task.wait()
			pcall(firetouchinterest, head, d, 1)
		end
	end
end

-- The chase is a lie: FollowerHandler clones BaseDefender locally and FollowerClass
-- fires DropEntity from the CLIENT when the guard closes on you. Destroying the
-- model ends that thread (`while model.Parent and Humanoid.Parent do`) so nothing
-- is ever left to report you as caught.
local function guardLoop(alive)
	while alive() and running do
		for _, m in ipairs(workspace:GetChildren()) do
			if m:GetAttribute("IsBaseDefender") then
				pcall(game.Destroy, m)
			end
		end
		task.wait(GUARD_WAIT)
	end
end

-- gui ------------------------------------------------------------------------
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a
-- restyle is one file and not sixteen. Fetched here rather than installed by the loader,
-- so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Steal an Animal", -- fallback until the live name lands
	folder = "StealAnimal", -- unchanged: renaming it orphans configs already saved in-game
	size = UDim2.fromOffset(520, 400),
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })

local Steal = Tab:Section({
	Title = "Steal",
	Desc = "Takes animals off other players' ranches",
	Icon = "solar:hand-money-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})
local Money = Tab:Section({
	Title = "Money",
	Icon = "solar:wallet-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})
local Advanced = Tab:Section({
	Title = "Advanced",
	Desc = "Spends cash or wipes progress",
	Icon = "solar:settings-bold",
	Box = true,
	BoxBorder = true,
	Opened = false,
})

-- Every toggle owns one generation counter. Off-then-on inside a single task.wait
-- would otherwise leave the sleeping thread alive next to the new one, farming at
-- double rate; `alive()` closes over the generation this thread was born with.
local function loopToggle(section, opts, body)
	local gen, on = 0, false
	section:Toggle({
		Title = opts.title,
		Desc = opts.desc,
		Value = false,
		Callback = function(state)
			gen += 1
			on = state
			if not state then
				return -- the old thread's alive() is already false
			end
			local mine = gen
			task.spawn(body, function()
				return on and gen == mine
			end)
		end,
	})
end

-- Guards first in the list because turning it on second means the carries you have
-- already started were the ones a defender could still take off you.
loopToggle(Steal, { title = "Kill Base Guards", desc = "Client-side NPCs; you can never be caught" }, guardLoop)
loopToggle(Steal, { title = "Steal from Bases", desc = "EntitiesFolder -> your plot, richest first" }, baseLoop)
loopToggle(Steal, { title = "Steal from Ranches", desc = "Other players' animals. Different mechanic" }, ranchLoop)

loopToggle(
	Steal,
	{ title = "Place Best Animals", desc = "Backpack + hotbar -> ranch, highest value first" },
	placeLoop
)

Steal:Input({
	Title = "Min $/s",
	Desc = "Skip animals earning less than this",
	Value = tostring(MIN_MPS),
	Placeholder = "0",
	Callback = function(v)
		MIN_MPS = tonumber(v) or 0
	end,
})

loopToggle(Money, { title = "Collect Cash", desc = "Touches each animal. Free; the Collect All button is 4 Robux" }, function(alive)
	local plot = RemoteBank.GetPlot:InvokeServer()
	if not plot then
		warn("[StealAnimal] GetPlot returned nothing - nothing to collect from")
		return
	end
	while alive() and running do
		-- ponytail: no teleport home first. It would fight the steal loop, which is
		-- teleporting constantly; the deposit trip already puts you on the plot
		-- often enough. If the server distance-checks the touch, that trip is when
		-- this lands.
		collectCash(plot)
		task.wait(CASH_WAIT)
	end
end)

loopToggle(Money, { title = "Upgrade Ranch", desc = "Buys a stand slot whenever you can afford one" }, function(alive)
	while alive() and running do
		send(RemoteBank.PurchaseUpgrade, "FireServer", "StandUpgrade")
		task.wait(BASE_WAIT)
	end
end)

-- One-shot, never looped: ClaimOfflineCash takes a "doubled" flag that maps to a
-- Robux product, so it is passed false. PurchaseOfflineDouble and CollectAllCash are
-- deliberately absent -- both open a purchase prompt when you don't own them.
Money:Button({
	Title = "Claim Offline + Daily",
	Callback = function()
		send(RemoteBank.ClaimOfflineCash, "InvokeServer", false)
		send(RemoteBank.ClaimDailyReward, "InvokeServer")
	end,
})

-- This is the "You don't own this base" fix. The check lives on the server, so the
-- only way past it is to actually buy the base. Firing every id on a loop means the
-- next one is bought the moment you can afford it -- no walking into PurchaseZone.
loopToggle(Advanced, { title = "Buy All Bases", desc = "Fires TryPurchaseBase 1.." .. #Bases .. " on a loop" }, function(alive)
	while alive() and running do
		for n = 1, #Bases do
			if not (alive() and running) then
				break
			end
			send(RemoteBank.TryPurchaseBase, "InvokeServer", n)
		end
		task.wait(BASE_WAIT)
	end
end)

Advanced:Button({
	Title = "Rebirth",
	Callback = function()
		Window:Dialog({
			Title = "Rebirth",
			Content = "Wipes your cash and animals. This cannot be undone.",
			Buttons = {
				{ Title = "Cancel", Variant = "Secondary" },
				{
					Title = "Rebirth",
					Variant = "Primary",
					Callback = function()
						send(RemoteBank.Rebirth, "InvokeServer")
					end,
				},
			},
		})
	end,
})

-- anti-afk -------------------------------------------------------------------
-- Two triggers, because relying on Idled alone means one missed event costs the
-- session: a 60s nudge keeps the timer far from 20 min, and Idled is the last
-- warning before the kick. ponytail: always on, no toggle.
-- hasVU / vu come from the place section; right-click, so it can never be mistaken
-- for the left-click that activates a tool.
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
local afk = player.Idled:Connect(nudge)
task.spawn(function()
	while running do
		task.wait(60)
		nudge()
	end
end)

-- Whatever the disconnect reason, the error prompt lands in CoreGui. Rejoin on sight.
task.spawn(function()
	local ok, overlay = pcall(function()
		local gui = game:GetService("CoreGui"):WaitForChild("RobloxPromptGui", 10)
		return gui and gui:WaitForChild("promptOverlay", 10)
	end)
	if not ok or not overlay then
		warn("[StealAnimal] rejoin-on-disconnect NOT armed")
		return
	end
	overlay.ChildAdded:Connect(function(child)
		if child.Name:find("ErrorPrompt") and running then
			warn("[StealAnimal] disconnected - rejoining")
			pcall(function()
				game:GetService("TeleportService"):Teleport(game.PlaceId, player)
			end)
		end
	end)
end)

-- close ----------------------------------------------------------------------
-- One flag ends every loop; each toggle's own alive() is already false once its
-- generation moves. ponytail: rerun the script to come back.
local function stop()
	running = false
	afk:Disconnect()
	getgenv().stealAnimalStop = nil
	pcall(function()
		Window:Destroy()
	end)
end

Window:OnDestroy(stop)
getgenv().stealAnimalStop = stop
