--[[ Become a Brainrot -- skip the run, loot the deepest base on repeat

     The honest loop is: morph into a brainrot, sprint down the corridor, get grabbed by
     a guard, and while you're held in his base you pick his brainrots up and run out.
     Which base you end up in is decided by how far you got before the catch.

     Only it isn't decided by the server. GuardClient.lua does the whole thing on the
     client: it notices the guard is within 18 studs, teleports you to that location's
     SpawnPosition and then fires

         ReplicatedStorage.Events.SummonBrainrots:FireServer(<the location folder>)

     The location is an ARGUMENT. So the run is skippable -- fire that with the folder
     you want and the base fills up with loot you never earned the distance for.

     BASE      : dropdown over workspace.Locations, DEEPEST FIRST. Depth is the
                 location's CatchHitbox Z (loc 1 sits at -60, End at -1791), so the
                 order is literally how far down the corridor you'd have had to run.
                 Defaults to the deepest one, which is the point of this.
     AUTO LOOT : toggle. Per cycle:

                     Summon -> rank what spawned by $/s -> grab the best `Carry` of them
                     -> TP out -> ClearBrainrots

                 ClearBrainrots is safe and is NOT what loses loot: GuardClient fires it
                 from Restart(), which runs on the SUCCESS path (escaped, keeps
                 everything) exactly as much as on the caught one. DropBrainrot is the
                 one that takes them off you, and nothing here ever fires it.
     RANK      : off the billboard's own "N$/s" label, which is the number the game puts
                 over each brainrot's head -- same value you'd read before deciding which
                 one to carry out. One that won't parse sorts last but still gets taken
                 if there's carry room left.
     ROBUX     : every base puts out an OP brainrot that only comes out for
                 DevProducts.StealOPBrainrot (239 R$), and it sorts FIRST because it's
                 the best thing in the room -- that's the upsell.

                 It carries NO marker. The dialog is the server's doing: hold the prompt,
                 and it fires Events.PromptProductPurchase back at you, which
                 MarketplacePrompt.lua turns into "Buy Robux and item". So there is
                 nothing to detect in advance, and this works in two halves:

                     mute that one client handler   -> the dialog cannot open, ever
                     listen on the event ourselves  -> whatever we were holding when it
                                                       fired IS the paid one; mark it,
                                                       drop it mid-grab, move on

                 Costs one aborted grab per summon (one server round trip, not the whole
                 GRAB_TIME) and nothing after that. Marker-based detection is still tried
                 first in case another world does tag them -- it just isn't what saves
                 you here. The haul line and the Live row count what got skipped, and F9
                 gets a one-shot dump of the paid one's shape.

                 Untick and the mute goes with it: it blocks ALL purchase dialogs, which
                 is right while farming and wrong when you meant to buy something.
     CARRY     : player.Carry (IntValue, starts at 1, bought with the Carry gamepass /
                 upgrades). Held ones are Models parented straight to your Character --
                 that's what GuardClient counts, and it's the grab confirming.

     No guard ever chases: GuardClient's chase loop only runs while _G.CurrentState ==
     "Running", and this never starts a run. Don't hand-start one while it's looping.

     The Passive tab is three loops that run whether or not the loot loop is on, and
     don't touch your character, so they all stack with it and with each other:

     CASH      : the stands on your plot pay into player.AnimalStands.<n>.Deposited, and
                 walking over a Collect pad runs a CLIENT handler that ends in
                 CollectCash:FireServer(<that StringValue>). This fires it directly --
                 no walking the plot, no per-pad cooldown. Same two gates the game's own
                 handler uses (a brainrot is placed, and something is owed), so a sweep
                 is only ever as many remotes as there are stands actually paying.
     SELL      : SellAllBrainrots:FireServer(<array of tools>) over every Backpack tool
                 with an AnimalTable child -- exactly what the shop's Sell All button
                 sends. Sells the loot, NOT what's placed on your stands: those are the
                 plot's and the cash sweep is what harvests them. It sells everything
                 loose, best included, so leave it off while you're hunting a keeper.
     SPEED     : the treadmill without the treadmill. Equipping the Treadmill tool is
                 what starts training -- TrainingController watches Character.ChildAdded
                 for it and fires StartTraining. The visuals are the SERVER's reply,
                 TrainingStateUpdate, which the controller turns into a treadmill model,
                 a locked camera, disabled controls and a running animation.

                 So: mute that one client handler with getconnections, then equip. The
                 server trains you; the client never finds out it should put you on a
                 treadmill. You keep your controls, the model never spawns, and the tool
                 is RequiresHandle=false so your hands stay empty.

                 TapBonus is the x2 popup you'd click every 3-5s while training; there's
                 no popup with the UI muted, so it's fired on the same jittered beat.
                 Watch TrainedSpeed in the row -- if it's flat, the server is gating on
                 something the mute hides, and that's the tell.

     Executor only: the UI is WindUI, pulled in with HttpGet, which Studio blocks.
     RightControl minimises and expands -- the body rolls up to a bare Zegion pill, and
     the minus button does the same by mouse. RightAlt hides the window outright, for a
     screenshot. Everything keeps running under either.
     Stop for good: getgenv().becomeRotStop() ]]

-- config ---------------------------------------------------------------------
local SUMMON_WAIT = 5 -- max seconds to wait for a summoned base to fill; the spawn is a
-- server round trip plus streaming, and an empty folder at 1s means nothing yet
local POLL = 0.1 -- beat for "has anything spawned / has it gone" polls
local GRAB_OFFSET = Vector3.new(0, 4, 0) -- above the brainrot's pivot; must land in prompt range
-- How far you may drift from that aim point before grab() hops you back. Landing and
-- settling is normal and must NOT re-teleport -- that was the stutter. Keep it under the
-- prompt's MaxActivationDistance (10 in this game) and above the fall from GRAB_OFFSET.
local GRAB_REACH = 8
local GRAB_TIME = 2 -- seconds hammering one brainrot before writing it off
local FIRE_STEP = 0.05 -- between prompt fires
-- The two dead waits per haul, and the first knobs to touch if it still feels slow.
-- SETTLE is the only thing between arriving home and ClearBrainrots, so it's the beat
-- the server gets to see the move; CYCLE is pure breathing room before the next summon.
-- Below about 0.1 each you're racing the round trip you're waiting for.
local SETTLE = 0.25
local CYCLE = 0.15
local IDLE = 3 -- parked after a summon that spawned nothing, rather than spamming it
local CASH_POLL = 5 -- seconds between cash sweeps; the game's own pad handler self-limits
-- to one collect per stand per second, so anything under ~2 is remotes it won't answer
local SELL_POLL = 10 -- seconds between sells. Slower than the loot loop on purpose: one
-- call sells the whole backpack, so hurrying it just sends more empty ones
local TRAIN_POLL = 5 -- seconds between re-arming training. Covers a respawn or a server
-- that dropped you; the equip itself is a no-op when the tool is already on
local TAP_MIN, TAP_MAX = 3, 5 -- TapBonus beat, jittered. Verbatim from TrainingController's
-- own `t = { 3, 5 }` -- that's the cadence a real player's popup appears on
-- Cap on the GameplayPaused wait after a long hop, and nothing more -- see tp(), which
-- deliberately does NOT ask the server to stream. This is a ceiling on a wait that
-- normally ends in a frame or doesn't happen at all, not a delay anything pays up front.
local STREAM_TIMEOUT = 3
local KEY_TOGGLE = Enum.KeyCode.RightControl

-- UIFramework.KNumber's suffix ladder, verbatim, because the billboard is rendered with
-- it -- so this is the exact set of strings that can appear. Anything past 1e36 comes
-- out as plain e-notation, which tonumber already reads.
local SUFFIX = {
	K = 1e3,
	M = 1e6,
	B = 1e9,
	T = 1e12,
	Qa = 1e15,
	Qi = 1e18,
	Sx = 1e21,
	Sp = 1e24,
	Oc = 1e27,
	No = 1e30,
	Dc = 1e33,
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

-- Hides the "Gameplay Paused" toast, nothing more -- it does NOT unpause anything, and
-- tp() still waits out player.GameplayPaused. Worth it purely because a loop that jumps
-- 1800 studs every few seconds otherwise flashes that banner all day. pcall'd: it's a
-- newer GuiService method and an old client shouldn't take the panel down over a toast.
pcall(function()
	game:GetService("GuiService"):SetGameplayPausedNotificationEnabled(false)
end)

if getgenv and getgenv().becomeRotStop then
	getgenv().becomeRotStop() -- re-running must not stack a second window/loop
end

-- One lookup each, all optional but summon: a missing remote should grey out its own
-- feature and let the rest run, not take the panel down with it.
local Events = ReplicatedStorage:WaitForChild("Events", 10)
local function event(name)
	return Events and Events:FindFirstChild(name)
end

local summonRemote = event("SummonBrainrots")
local clearRemote = event("ClearBrainrots")
local cashRemote = event("CollectCash")
local sellRemote = event("SellAllBrainrots")
local trainStart, trainStop = event("StartTraining"), event("StopTraining")
local trainState, tapRemote = event("TrainingStateUpdate"), event("TapBonus")
if not summonRemote then
	warn("[BecomeRot] no Events.SummonBrainrots -- wrong game, or it was renamed")
end

-- world ----------------------------------------------------------------------
local function hrp()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- No offset means "use this CFrame exactly". With an offset we take position only: a
-- brainrot's own rotation would tilt the character with it.
--
-- No RequestStreamAroundAsync. It YIELDS -- the full STREAM_TIMEOUT when it can't tell
-- you the region arrived, longer once Roblox throttles repeat callers -- and it was the
-- 3-5 seconds of standing in the safe zone doing nothing between hauls. It also has
-- nothing to do here: the whole corridor, all seventeen bases and every plot came back
-- in one client's dump, and the game's own Restart() flings you the same 1800 studs with
-- a bare CFrame assignment and no streaming handling at all.
--
-- What's left is the pause poll, which costs nothing when there is no pause and exits
-- the frame the world arrives when there is. Deadlined so a region that never comes
-- costs one timeout rather than the loop.
local function tp(cf, offset, settle)
	if not cf then
		return false
	end
	local target = offset and CFrame.new(cf.Position + offset) or cf
	local char = player.Character
	if not char or not hrp() then
		return false
	end
	char:PivotTo(target)
	if settle then
		local deadline = os.clock() + STREAM_TIMEOUT
		while player.GameplayPaused and os.clock() < deadline do
			task.wait()
		end
	end
	return true
end

-- Where to sit between hauls: out of the base, so nothing there is holding a reference
-- to us when the next summon lands. ShopTP is where the game's own Restart() puts you;
-- RunStart is the fallback because it's the one part in this map that never moves.
local function home()
	local map = workspace:FindFirstChild("Map")
	local shop = map and map:FindFirstChild("ShopTP")
	local part = shop or workspace:FindFirstChild("RunStart")
	return part and (part:IsA("Model") and part:GetPivot() or part.CFrame)
end

-- Depth down the corridor, which IS the location's rank -- loc 1's CatchHitbox sits at
-- Z -60 and End's at -1791, so "deepest" and "hardest to reach honestly" are one number.
-- Read off the world rather than a hardcoded order, so a world with a different set of
-- locations (Mystic Forest, World3) still sorts correctly with nothing to edit.
local function depthOf(loc)
	local box = loc:FindFirstChild("CatchHitbox")
	if box then
		return -box.Position.Z
	end
	local guard = loc:FindFirstChild("GuardTemplate")
	return guard and -guard:GetPivot().Position.Z or 0
end

local function locations()
	local folder = workspace:FindFirstChild("Locations")
	if not folder then
		return {}
	end
	local out = {}
	for _, loc in ipairs(folder:GetChildren()) do
		if loc:FindFirstChild("Brainrots") then
			table.insert(out, {
				name = loc.Name,
				depth = depthOf(loc),
				tier = tostring(loc:GetAttribute("LocationName") or "?"),
				guard = tostring(loc:GetAttribute("GuardName") or "?"),
				luck = tostring(loc:GetAttribute("LuckMultiplier") or "?"),
			})
		end
	end
	table.sort(out, function(a, b)
		return a.depth > b.depth
	end)
	return out
end

-- "1.23K$/s" -> 1230. The billboard is the only place a wild brainrot's value is
-- written down in a form the client can read without recomputing CalculateMoney, and
-- it's the same number you'd be picking off in the Explorer.
local function parseMoney(text)
	if not text then
		return nil
	end
	local clean = tostring(text):gsub("[%s,%$]", ""):gsub("/s$", "")
	local plain = tonumber(clean) -- covers "9" and KNumber's "1.234e36" tail
	if plain then
		return plain
	end
	local num, suffix = clean:match("^(-?%d*%.?%d+)(%a+)$")
	local mult = num and SUFFIX[suffix]
	return mult and tonumber(num) * mult or nil
end

assert(parseMoney("9$/s") == 9, "plain values")
assert(parseMoney("1,234$/s") == 1234, "comma grouping")
assert(parseMoney("1.5K$/s") == 1500, "suffix ladder")
assert(parseMoney("2e12$/s") == 2e12, "KNumber's e-notation tail")
assert(parseMoney("???") == nil and parseMoney(nil) == nil, "unreadable sorts last, never errors")

-- The billboard is cloned in by AnimalModule.GenerateBillboard and parented to the
-- model, so a deep search finds it wherever the summoner chose to hang it.
local function billboard(model)
	local gui = model:FindFirstChild("AnimalBillboard", true)
	return gui and gui:FindFirstChild("Money") and gui or nil
end

local function valueOf(model)
	local gui = billboard(model)
	return gui and parseMoney(gui.Money.Text) or nil
end

local function rarityOf(model)
	local gui = billboard(model)
	local rarity = gui and gui:FindFirstChild("Rarity")
	return rarity and rarity.Text or "?"
end

-- Best first, unreadable last but still taken -- a value this script can't parse is
-- more likely a billboard that changed shape than a brainrot worth skipping.
-- The Robux ones. Every base puts out an OP brainrot you can only take by buying
-- DevProducts.StealOPBrainrot, and holding its prompt opens the purchase dialog -- so
-- without this the loop walks up to the best thing in the room and asks you for money,
-- every cycle.
--
-- Detected by the game's OWN markers rather than a name list, because the marker is what
-- makes it paid: AutoPriceHandler.lua reads a ProductId / GamepassId attribute off
-- anything tagged DynamicDevProductPrice / DynamicGamepassPrice and rewrites its text to
-- utf8.char(57346) .. price. That glyph is the Robux symbol, and it is the one thing a
-- paid label always ends up carrying whichever route the game took to build it.
local ROBUX = utf8.char(57346)

local function marksPaid(inst)
	if inst:GetAttribute("ProductId") or inst:GetAttribute("GamepassId") then
		return true
	end
	if inst:HasTag("DynamicDevProductPrice") or inst:HasTag("DynamicGamepassPrice") then
		return true
	end
	local text
	if inst:IsA("ProximityPrompt") then
		text = inst.ActionText .. " " .. inst.ObjectText -- where the price is worded
	elseif inst:IsA("TextLabel") or inst:IsA("TextButton") then
		text = inst.Text
	end
	if not text then
		return false
	end
	return text:find(ROBUX, 1, true) ~= nil or text:lower():find("robux") ~= nil or text:find("R%$") ~= nil
end

assert(not marksPaid(Instance.new("Model")), "a bare model is never paid")

-- Weak keys: a brainrot lives one summon, and the answer can't change inside that. This
-- is only here because the live row rescans every second and the walk is the whole model
-- -- bones, meshes and all.
local paidCache = setmetatable({}, { __mode = "k" })

local function isPaid(model)
	local cached = paidCache[model]
	if cached ~= nil then
		return cached
	end
	local paid = marksPaid(model)
	if not paid then
		for _, d in ipairs(model:GetDescendants()) do
			if marksPaid(d) then
				paid = true
				break
			end
		end
	end
	paidCache[model] = paid
	return paid
end

local function scanRots(loc)
	local folder = loc and loc:FindFirstChild("Brainrots")
	local out = {}
	if not folder then
		return out
	end
	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") and model.PrimaryPart then
			table.insert(out, { model = model, value = valueOf(model), paid = isPaid(model) })
		end
	end
	table.sort(out, function(a, b)
		return (a.value or -1) > (b.value or -1)
	end)
	return out
end

-- purchase -------------------------------------------------------------------
-- Why the marker hunt above wasn't enough: the OP brainrot carries NO marker. The whole
-- dialog is server-driven, and MarketplacePrompt.lua is the entire client half of it --
--
--     Events.PromptProductPurchase.OnClientEvent:Connect(function(id)
--         UIFramework.ProductPromth()
--         MarketplaceService:PromptProductPurchase(LocalPlayer, id)
--     end)
--
-- You hold the prompt, the SERVER decides it's the paid one and fires that event back,
-- and the client obediently opens "Buy Robux and item". Nothing on the model says so
-- beforehand, so there is nothing to detect until you've already touched it.
--
-- Hence two halves. Mute that one handler and the dialog cannot open whatever triggers
-- it -- that's the guarantee, and it's the same trick as the treadmill. Then connect our
-- OWN listener in its place: the event firing while grab() is holding a brainrot is the
-- server telling us which one is paid, so we mark it, abandon it mid-grab, and the next
-- scan sorts it out. The game teaches us its own answer.
--
-- Muting is strictly protective -- it stops purchase dialogs appearing, it can never buy
-- anything -- but it is ALL of them, including ones you meant to open. So it lives and
-- dies with the Skip Robux toggle rather than being on for the whole session.
local purchaseRemote = event("PromptProductPurchase")
local grabbing = nil -- the model grab() has in hand, so the listener knows who to blame
local purchaseMuted, ourListener, blocked = nil, nil, 0

-- One-shot, to F9. If the paid one turns out to carry something identifiable after all,
-- this is what finds it -- and then the skip costs nothing instead of one aborted grab.
local dumpedShape = false
local function dumpShape(model)
	if dumpedShape or not model then
		return
	end
	dumpedShape = true
	local bits = {}
	for k, v in pairs(model:GetAttributes()) do
		table.insert(bits, k .. "=" .. tostring(v))
	end
	local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt then
		table.insert(bits, ("prompt[%s] Action=%q Object=%q"):format(prompt.Name, prompt.ActionText, prompt.ObjectText))
	end
	warn(("[BecomeRot] paid brainrot shape -- %s | %s"):format(model.Name, table.concat(bits, "  ")))
end

local function blockPurchases()
	if purchaseMuted or not (getconnections and purchaseRemote) then
		return purchaseMuted ~= nil
	end
	local list = {}
	for _, c in ipairs(getconnections(purchaseRemote.OnClientEvent)) do
		pcall(function()
			c:Disable()
		end)
		table.insert(list, c)
	end
	purchaseMuted = list
	-- AFTER the mute, never before: getconnections would otherwise hand us our own
	-- listener on the next call and we'd disable ourselves along with the game's.
	ourListener = purchaseRemote.OnClientEvent:Connect(function(productId)
		blocked += 1
		local model = grabbing
		if model then
			paidCache[model] = true -- grab() watches this and gives up on the spot
			dumpShape(model)
		end
		warn(("[BecomeRot] blocked purchase prompt for product %s (%s)"):format(tostring(productId), model and model.Name or "not mid-grab"))
	end)
	return true
end

local function allowPurchases()
	if ourListener then
		ourListener:Disconnect()
		ourListener = nil
	end
	if not purchaseMuted then
		return
	end
	for _, c in ipairs(purchaseMuted) do
		pcall(function()
			c:Enable()
		end)
	end
	purchaseMuted = nil
end

-- Carried brainrots are Models parented straight to the Character, which is exactly what
-- GuardClient counts against player.Carry. The morph you'd wear on a real run is parented
-- to the HumanoidRootPart instead, so it never lands in this count.
local function heldCount()
	local char = player.Character
	if not char then
		return 0
	end
	local n = 0
	for _, child in ipairs(char:GetChildren()) do
		if child:IsA("Model") then
			n += 1
		end
	end
	return n
end

local function carryLimit()
	local carry = player:FindFirstChild("Carry")
	return carry and carry.Value or 1
end

local function stolen()
	local count = player:FindFirstChild("StolenBrainrots")
	return count and count.Value or 0
end

-- plot -----------------------------------------------------------------------
-- Each child of player.AnimalStands is the StringValue for one stand: its Value is the
-- JSON of the brainrot standing there ("" when the stand is empty) and its Deposited
-- child is what that brainrot has earned since the last collect. Walking onto the pad
-- runs PlotLocal's Touched handler, which ends in CollectCash:FireServer(thatValue) --
-- so the instance IS the argument, and firing it directly skips both the walk and the
-- handler's one-second-per-stand debounce.
--
-- Both gates are the game's own, and both are worth keeping: an empty stand or one with
-- nothing owed is a remote the server won't answer, and a full plot is ~90 of them.
local function collectCash()
	local stands = player:FindFirstChild("AnimalStands")
	if not (stands and cashRemote) then
		return 0
	end
	local n = 0
	for _, stand in ipairs(stands:GetChildren()) do
		local deposited = stand:FindFirstChild("Deposited")
		if stand.Value ~= "" and deposited and deposited.Value > 0 then
			cashRemote:FireServer(stand)
			n += 1
		end
	end
	return n
end

-- A brainrot you're carrying loose is a Tool with an AnimalTable child -- that child is
-- the JSON the server reads back, and it's what tells a brainrot apart from the
-- Treadmill tool sitting in the same Backpack. Same filter SellController.AllBrainrots
-- uses, including its one quirk: only the EQUIPPED tool counts off the character, so a
-- brainrot on your back and a treadmill in your hand means the brainrot waits a sweep.
local function looseRots()
	local out = {}
	for _, tool in ipairs(player.Backpack:GetChildren()) do
		if tool:FindFirstChild("AnimalTable") then
			table.insert(out, tool)
		end
	end
	local char = player.Character
	local held = char and char:FindFirstChildOfClass("Tool")
	if held and held:FindFirstChild("AnimalTable") then
		table.insert(out, held)
	end
	return out
end

-- The array goes over the wire as-is; that's what the shop's Sell All button sends.
-- Nothing placed on a stand is in it -- those live on the plot and the cash sweep is
-- what harvests them.
--
-- Returns sold, offered. The event returns nothing, so the confirm is the backpack
-- actually shrinking; anything still there after the deadline is a tool the server
-- refused, and that gap is the thing worth seeing in the row.
local function sellLoose()
	local tools = looseRots()
	if #tools == 0 or not sellRemote then
		return 0, #tools
	end
	sellRemote:FireServer(tools)
	local deadline = os.clock() + 2
	repeat
		task.wait(POLL)
	until #looseRots() < #tools or os.clock() > deadline
	return #tools - #looseRots(), #tools
end

-- speed ----------------------------------------------------------------------
-- The visuals are all downstream of ONE event. TrainingController connects to
-- TrainingStateUpdate and its handler is what spawns the treadmill model, disables the
-- controls, locks your facing and plays the run animation. Cut that connection and the
-- server still trains you -- it just never gets to tell the client to put you on a
-- treadmill. Restored on stop, or a hand-equipped treadmill afterwards leaves you
-- training with no way to see or stop it.
--
-- ponytail: needs getconnections. Without it the toggle says so and refuses rather than
-- starting a training session it can't hide -- which is the whole feature.
local muted = nil

local function muteTrainingUI()
	if muted or not (getconnections and trainState) then
		return muted ~= nil
	end
	local list = {}
	for _, c in ipairs(getconnections(trainState.OnClientEvent)) do
		pcall(function()
			c:Disable()
		end)
		table.insert(list, c)
	end
	muted = list
	return true
end

local function unmuteTrainingUI()
	if not muted then
		return
	end
	for _, c in ipairs(muted) do
		pcall(function()
			c:Enable()
		end)
	end
	muted = nil
end

-- Equipping is the whole start signal: TrainingController watches Character.ChildAdded
-- for a tool named Treadmill with an IsTreadmillTool child and fires StartTraining off
-- it. Re-fired here as well, because a tool that's ALREADY on fires no ChildAdded and
-- the re-arm poll would then do nothing.
local function armTraining()
	local char = player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false
	end
	local tool = char:FindFirstChild("Treadmill") or player.Backpack:FindFirstChild("Treadmill")
	if not tool then
		return false
	end
	if tool.Parent ~= char then
		pcall(function()
			humanoid:EquipTool(tool)
		end)
	end
	if trainStart then
		trainStart:FireServer()
	end
	return true
end

local function trainedSpeed()
	local raw = player:FindFirstChild("TrainedSpeed")
	local walk = player:FindFirstChild("Speed")
	return raw and raw.Value or 0, walk and walk.Value or 0
end

-- farm -----------------------------------------------------------------------
-- The shell is built below this, so the rows the loop writes to are declared here and
-- filled in there. say() no-ops until then, which is what makes the order legal.
local statusRow, lootToggle
local running = true

local function say(msg)
	if statusRow then
		statusRow:SetDesc(msg)
	end
end

local chosen -- location folder NAME, written by the dropdown callback
local skipPaid = true -- written by the toggle; the Robux OP brainrot is skipped by default
local looting, hauls, taken = false, 0, 0

-- Resolved per cycle rather than held: ChangeWorld swaps what's under workspace.Locations
-- and a cached folder would be a destroyed instance the moment the user changes world.
local function target()
	local folder = workspace:FindFirstChild("Locations")
	return folder and chosen and folder:FindFirstChild(chosen)
end

local function fire(prompt)
	prompt.RequiresLineOfSight = false -- client-side only, but the client is what gates it
	if fireproximityprompt then
		fireproximityprompt(prompt, 1)
	else
		-- ponytail: no executor globals -- the honest hold, which needs you in range.
		prompt:InputHoldBegin()
		task.wait(prompt.HoldDuration + 0.1)
		prompt:InputHoldEnd()
	end
end

-- The exit is the model LEAVING the Brainrots folder -- the server reparents it onto
-- your character, and that reparent is the only honest confirm. Return values lie and
-- the prompt stays enabled either way.
local function grab(model)
	local folder = model.Parent
	local deadline = os.clock() + GRAB_TIME
	-- Aim ONCE, then only when you've drifted out of reach.
	--
	-- PivotTo'ing every FIRE_STEP was twenty teleports a second, and that's the stutter:
	-- the humanoid is unanchored, so between two of them it falls part of GRAB_OFFSET's
	-- four studs and gets snapped back up, twenty times a second, while the server is
	-- replicating its own idea of where you are on top of that. Nothing needed re-aiming
	-- -- these brainrots stand still on their stands. The per-step re-aim was carried
	-- over from a game whose loot falls in from the sky and genuinely does move.
	--
	-- The reach check is the insurance: land badly, slide off a stand, and one hop puts
	-- you back rather than burning GRAB_TIME holding a prompt you're out of range of.
	local arriving = true
	grabbing = model -- so the purchase listener knows which brainrot the server refused
	repeat
		local root = hrp()
		local aim = model:GetPivot().Position + GRAB_OFFSET
		if arriving or not root or (root.Position - aim).Magnitude > GRAB_REACH then
			tp(model:GetPivot(), GRAB_OFFSET, arriving)
			arriving = false
		end
		local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
		if prompt then
			fire(prompt)
		end
		task.wait(FIRE_STEP)
		-- paidCache going true is the server having answered the hold with a purchase
		-- prompt instead of a brainrot. One round trip, not the whole GRAB_TIME.
	until paidCache[model] or model.Parent ~= folder or os.clock() > deadline
	grabbing = nil
	return model.Parent ~= folder
end

-- Wait for the summon to land. An empty folder isn't "nothing spawned" until the server
-- has had its round trip AND the region has streamed, which is the whole of SUMMON_WAIT.
local function awaitSpawn(loc)
	local deadline = os.clock() + SUMMON_WAIT
	repeat
		local rots = scanRots(loc)
		if #rots > 0 then
			return rots
		end
		task.wait(POLL)
	until os.clock() > deadline
	return {}
end

-- Returns true to ask the caller to stop. It must not write `looting` itself: a cycle
-- that outlives its own generation would switch off a loop that has since restarted.
local function runCycle()
	if not hrp() then
		say("no character -- waiting for respawn")
		repeat
			task.wait(0.2)
		until hrp() or not (looting and running)
		return
	end

	local loc = target()
	if not loc then
		say("base " .. tostring(chosen) .. " isn't in workspace.Locations")
		return true
	end

	-- The spoof, in one line: the location is just an argument to the remote, so this
	-- claims a catch at a base the run never reached.
	summonRemote:FireServer(loc)
	local rots = awaitSpawn(loc)
	if #rots == 0 then
		say(("nothing spawned at %s -- idling (%d hauls)"):format(loc.Name, hauls))
		task.wait(IDLE)
		return
	end

	local room = carryLimit() - heldCount()
	if room < 1 then
		-- Hands still full from the last haul means ClearBrainrots isn't landing, and
		-- every further hold is a refusal. Say it and stop rather than looping on it.
		say(("still carrying %d of %d -- clear them by hand, then flip this back on"):format(heldCount(), carryLimit()))
		return true
	end

	local got, skipped = 0, 0
	for _, entry in ipairs(rots) do
		if got >= room or not (looting and running) then
			break
		end
		local model = entry.model
		-- The paid one sorts near the top -- it's the best thing in the room, that's the
		-- upsell -- so this is checked per entry rather than filtered out of the scan,
		-- and the count goes in the status line where over-skipping would show up.
		-- entry.paid is what we knew at scan time; isPaid() after a failed grab is what
		-- the server has taught us since, and both count as skipped.
		if (entry.paid or isPaid(model)) and skipPaid then
			skipped += 1
		elseif model.Parent then
			local label = ("%s [%s]"):format(model.Name, rarityOf(model))
			say(("%s -- %s of %d, %d out there"):format(loc.Name, label, room, #rots))
			if grab(model) then
				got += 1
				taken += 1
			elseif isPaid(model) then
				skipped += 1 -- the hold came back as a purchase prompt; now it's cached
			end
		end
	end

	-- Out of the base, then end the run. ClearBrainrots is Restart()'s own call and runs
	-- on the game's success path too, so it does not cost you the haul; DropBrainrot is
	-- the one that would, and nothing here fires it.
	--
	-- The one hop long enough to be worth a pause check: home is ~1800 studs up the
	-- corridor from the deep bases. It normally clears in a frame.
	tp(home(), nil, true)
	task.wait(SETTLE)
	if clearRemote then
		clearRemote:FireServer()
	end
	hauls += 1
	say(
		("haul %d: took %d at %s%s (%d total, %d stolen)"):format(
			hauls,
			got,
			loc.Name,
			skipped > 0 and (", skipped " .. skipped .. " paid") or "",
			taken,
			stolen()
		)
	)
	task.wait(CYCLE)
end

local lootGen = 0

local function startLoot()
	looting = true
	lootGen += 1
	local mine = lootGen -- off-then-on shouldn't leave two loops driving one character
	task.spawn(function()
		while looting and running and lootGen == mine do
			-- A crash in here would kill the thread silently, leaving the toggle stuck ON
			-- with nothing happening. Name it and switch off cleanly instead.
			local ok, res = pcall(runCycle)
			if not ok then
				warn("[BecomeRot]", res)
				say("crashed -- see console (F9)")
				break
			end
			if res then
				break -- the cycle asked to stop; the tail below owns the switch
			end
		end
		if lootGen == mine then
			looting = false
			if lootToggle then
				lootToggle:Set(false)
			end
		end
	end)
end

-- shell ----------------------------------------------------------------------
-- ponytail: no hand-rolled widget kit. WindUI already ships the dropdown, toggles,
-- cards, drag, resize and the topbar, which is everything this panel is.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Become a Brainrot", -- fallback until the live name lands
	folder = "BecomeRot", -- renaming it later orphans configs already saved in-game
	size = UDim2.fromOffset(480, 400),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })

local function card(title, desc, icon)
	return Tab:Section({ Title = title, Desc = desc, Icon = icon, Box = true, BoxBorder = true, Opened = true })
end

local baseCard = card("Base", "Which guard's stash to raid", "solar:map-point-bold")
local lootCard = card("Loot", "Summon, take the best, get out, repeat", "solar:bag-heart-bold")
local liveCard = card("Live", "What's standing in the picked base right now", "solar:eye-bold")

local locs = locations()
local labels, byLabel = {}, {}
for _, loc in ipairs(locs) do
	local label = ("%s  --  %s / %s  (luck x%s)"):format(loc.name, loc.tier, loc.guard, loc.luck)
	table.insert(labels, label)
	byLabel[label] = loc.name
end

if #labels == 0 then
	baseCard:Paragraph({ Title = "No bases", Desc = "workspace.Locations is empty -- wrong game?" })
else
	chosen = byLabel[labels[1]] -- deepest, which is the whole point of the spoof
	baseCard:Dropdown({
		Title = "Base",
		Desc = "Deepest first -- top row is the one the run never gets you to",
		Values = labels,
		Value = labels[1],
		Callback = function(label)
			chosen = byLabel[label] or chosen
		end,
	})
end

lootToggle = lootCard:Toggle({
	Title = "Auto loot",
	Desc = "Highest $/s first, up to your Carry, then out",
	Value = false,
	Callback = function(state)
		-- Set() below fires this callback again, so the off branch has to be re-entrant.
		if not state then
			if looting then
				say(("stopped -- %d taken over %d hauls"):format(taken, hauls))
			end
			looting = false -- the loop exits on its own flag; nothing else to tear down
			return
		end
		if not (summonRemote and chosen) then
			lootToggle:Set(false)
			WindUI:Notify({ Title = "Become a Brainrot", Content = "No SummonBrainrots remote, or no base picked.", Image = "list" })
			return
		end
		startLoot()
	end,
})

-- On by default, and a toggle rather than a constant because it's a detection: if a game
-- update ever marks the free ones too, this is switched off in one click instead of the
-- farm quietly taking nothing. The haul line counts what it skipped, which is the tell.
lootCard:Toggle({
	Title = "Skip Robux brainrots",
	Desc = "Blocks the Buy dialog outright, and learns which one it was",
	Value = true,
	Callback = function(state)
		skipPaid = state
		if not state then
			allowPurchases()
			return
		end
		-- Muting is the only thing that actually stops the dialog: the server fires it,
		-- so there's nothing to detect in advance. Without getconnections we can still
		-- skip what we've learned, but the first hold of each summon pops the window.
		if not blockPurchases() then
			WindUI:Notify({
				Title = "Become a Brainrot",
				Content = "No getconnections -- the Buy dialog can't be blocked, only skipped after it shows.",
				Image = "triangle-alert",
			})
		end
	end,
})

-- On by default means it has to be armed at build time too: WindUI doesn't fire the
-- callback for a starting Value, so nothing would be muted until the first click.
blockPurchases()

statusRow = lootCard:Paragraph({ Title = "Status", Desc = "idle" })

-- Two manual presses, because the spoof has two halves that can fail separately: the
-- summon landing at all, and the grab being accepted. Pressing them one at a time is
-- how you tell which one a game update broke.
lootCard:Button({
	Title = "Summon once",
	Desc = "Fires SummonBrainrots at the picked base and stops there",
	Callback = function()
		local loc = target()
		if not (loc and summonRemote) then
			say("no base picked")
			return
		end
		summonRemote:FireServer(loc)
		say(("summoned at %s -- %d spawned"):format(loc.Name, #awaitSpawn(loc)))
	end,
})

lootCard:Button({
	Title = "End run",
	Desc = "ClearBrainrots + TP out, for unsticking a half-finished haul by hand",
	Callback = function()
		tp(home(), nil, true)
		task.wait(SETTLE)
		if clearRemote then
			clearRemote:FireServer()
		end
		say(("ended -- carrying %d, %d stolen"):format(heldCount(), stolen()))
	end,
})

local liveRow = liveCard:Paragraph({ Title = "Brainrots", Desc = "counting..." })

-- Its own row and its own thread rather than sharing the status line: the loop writes to
-- that one continuously, and a count that only appears between hauls is no count.
task.spawn(function()
	while running do
		local loc = target()
		local rots = scanRots(loc)
		if not loc then
			liveRow:SetDesc("no base picked")
		elseif #rots == 0 then
			liveRow:SetDesc(("%s is empty -- summon to fill it"):format(loc.Name))
		else
			-- "best" is the best one the loop would actually TAKE, so the row and the farm
			-- agree. The paid count is called out beside it: that's how you'd notice the
			-- detection over-reaching without watching the haul lines go by.
			local best, total, paid = nil, 0, 0
			for _, entry in ipairs(rots) do
				total += entry.value or 0
				if entry.paid then
					paid += 1
				end
				if not best and not (entry.paid and skipPaid) then
					best = entry
				end
			end
			liveRow:SetDesc(
				("%d in %s%s   best %s [%s] %s$/s   %s$/s on the floor   carry %d/%d"):format(
					#rots,
					loc.Name,
					-- Both numbers, because they mean different things: `paid` is what
					-- this base is holding back, `blocked` is Buy dialogs that never got
					-- to open. A rising blocked count with the toggle on is it working.
					(paid > 0 and (" (" .. paid .. " Robux)") or "")
						.. (blocked > 0 and (" [" .. blocked .. " blocked]") or ""),
					best and best.model.Name or "-- all paid",
					best and rarityOf(best.model) or "?",
					best and best.value and math.floor(best.value) or "?",
					math.floor(total),
					heldCount(),
					carryLimit()
				)
			)
		end
		task.wait(1)
	end
end)

-- passive --------------------------------------------------------------------
-- Three toggles with one shape between them: flip on and a thread runs `work` every
-- `every` seconds, writing whatever it returns into that card's own row; flip off and
-- the flag ends it. `every` may be a function, for the one beat that's jittered.
--
-- The generation counter is the thing worth copying: without it, off-then-on inside a
-- single interval leaves the sleeping thread alive next to the new one and the feature
-- quietly runs at double rate.
local PassiveTab = Window:Tab({ Title = "Passive", Icon = "solar:refresh-circle-bold" })
local stoppers = {} -- every toggle's off switch, so shutdown() doesn't name them one by one

local function pollToggle(card, cfg)
	local on, gen, row = false, 0, nil
	local toggle
	toggle = card:Toggle({
		Title = cfg.title,
		Desc = cfg.desc,
		Value = false,
		Callback = function(state)
			-- Set() below re-enters this, so the off branch has to be re-entrant and the
			-- message has to be guarded on `on` -- otherwise a refused switch-on reports
			-- a stop that never happened.
			if not state then
				if on then
					row:SetDesc("off")
					if cfg.stop then
						pcall(cfg.stop)
					end
				end
				on = false
				return
			end
			if cfg.start then
				local ok, why = cfg.start()
				if not ok then
					toggle:Set(false)
					row:SetDesc(why or "can't start")
					return
				end
			end
			on, gen = true, gen + 1
			local mine = gen
			task.spawn(function()
				while on and running and gen == mine do
					-- A crash here would kill the thread silently and leave the toggle
					-- stuck ON with nothing happening. Name it and switch off cleanly.
					local ok, msg = pcall(cfg.work)
					if not ok then
						warn("[BecomeRot]", cfg.title, msg)
						row:SetDesc("crashed -- see console (F9)")
						on = false
						toggle:Set(false)
						return
					end
					row:SetDesc(msg)
					task.wait(type(cfg.every) == "function" and cfg.every() or cfg.every)
				end
			end)
		end,
	})
	row = card:Paragraph({ Title = "Status", Desc = "off" })
	table.insert(stoppers, function()
		if on and cfg.stop then
			pcall(cfg.stop)
		end
		on = false
	end)
	return toggle
end

local cashCard = PassiveTab:Section({
	Title = "Cash",
	Desc = "Your own plot's stands, from wherever you are",
	Icon = "solar:wallet-money-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})

local sellCard = PassiveTab:Section({
	Title = "Sell",
	Desc = "Loose brainrots in your backpack -- not the placed ones",
	Icon = "solar:tag-price-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})

local speedCard = PassiveTab:Section({
	Title = "Speed",
	Desc = "Train on a treadmill that never appears",
	Icon = "solar:running-2-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})

local swept = 0

pollToggle(cashCard, {
	title = "Auto collect cash",
	desc = ("Every %ds, every stand that's actually owed something"):format(CASH_POLL),
	every = CASH_POLL,
	start = function()
		return cashRemote ~= nil, "no Events.CollectCash"
	end,
	work = function()
		local n = collectCash()
		swept += n
		if n == 0 then
			return "nothing owed yet -- place brainrots on your stands"
		end
		return ("%d stands collected (%d swept)"):format(n, swept)
	end,
})

local soldTotal = 0

pollToggle(sellCard, {
	title = "Auto sell backpack",
	desc = "Sells EVERY loose brainrot, best included -- off while hunting a keeper",
	every = SELL_POLL,
	start = function()
		return sellRemote ~= nil, "no Events.SellAllBrainrots"
	end,
	work = function()
		local sold, offered = sellLoose()
		soldTotal += sold
		if offered == 0 then
			return ("backpack empty (%d sold so far)"):format(soldTotal)
		end
		if sold < offered then
			return ("sold %d of %d -- the server kept the rest"):format(sold, offered)
		end
		return ("sold %d (%d total)"):format(sold, soldTotal)
	end,
})

sellCard:Button({
	Title = "Sell now",
	Desc = "One sweep by hand, whether or not the toggle is on",
	Callback = function()
		local sold, offered = sellLoose()
		soldTotal += sold
		WindUI:Notify({
			Title = "Become a Brainrot",
			Content = offered == 0 and "Nothing loose to sell." or ("Sold %d of %d."):format(sold, offered),
			Image = "tag",
		})
	end,
})

local trainBase, nextArm = nil, 0

pollToggle(speedCard, {
	title = "Auto treadmill (hidden)",
	desc = "Trains you without the model, the animation or the control lock",
	-- Jittered, because it's the TapBonus beat and that's what the popup does.
	every = function()
		return math.random(TAP_MIN * 100, TAP_MAX * 100) / 100
	end,
	start = function()
		if not (trainStart and trainState) then
			return false, "no StartTraining / TrainingStateUpdate"
		end
		-- Mute BEFORE arming. The other way round, the server's reply beats the mute and
		-- the controller puts you on a treadmill you then can't get off without
		-- restoring the very handler that would clean it up.
		if not muteTrainingUI() then
			return false, "no getconnections -- can't hide the treadmill, so not starting"
		end
		trainBase, nextArm = select(1, trainedSpeed()), os.clock() + TRAIN_POLL
		if not armTraining() then
			unmuteTrainingUI() -- muted for a session that never started; put it back
			return false, "no Treadmill tool in your backpack"
		end
		return true
	end,
	stop = function()
		if trainStop then
			trainStop:FireServer()
		end
		unmuteTrainingUI() -- or a hand-equipped treadmill later trains you invisibly
	end,
	work = function()
		-- Re-arm on its OWN slower beat, not the tap one: covers a respawn or a server
		-- that dropped the session, without firing StartTraining every three seconds at
		-- a handler that may well read a repeat as "start over".
		if os.clock() >= nextArm then
			armTraining()
			nextArm = os.clock() + TRAIN_POLL
		end
		if tapRemote then
			tapRemote:FireServer() -- the x2 popup you'd be clicking, on its own cadence
		end
		local raw, walk = trainedSpeed()
		return ("+%d trained (%d total, %d walkspeed)"):format(raw - (trainBase or raw), raw, walk)
	end,
})

-- close ----------------------------------------------------------------------
-- The red topbar button destroys the window after WindUI's own confirm dialog, so
-- teardown hangs off OnDestroy and both exits share it. ponytail: rerun to come back.
-- The passive toggles each pushed their own off switch into `stoppers`, so this doesn't
-- name them one at a time -- and the training one has real teardown behind it
-- (StopTraining, and restoring the client handler it muted), which must run on the red
-- button and on becomeRotStop just as much as on an unticked toggle.
local function shutdown()
	running, looting = false, false
	for _, stop in ipairs(stoppers) do
		pcall(stop)
	end
	-- Must outlive the panel: leaving PromptProductPurchase muted would silently swallow
	-- every purchase you meant to make for the rest of the session.
	allowPurchases()
end

Window:OnDestroy(shutdown)

if getgenv then
	getgenv().becomeRotStop = function()
		shutdown()
		Window:Destroy()
	end
end
