--[[ Dancing Animals -- roll eggs, collect crates, cash them in

     RARITY : the floor. "Legendary" means Legendary and everything above it.
     ROLL   : spams the egg dispenser, and STOPS while an egg at/above RARITY is
              sitting on the belt -- rolling again would throw it away
     BUY    : buys that egg, which clears the belt and lets ROLL carry on
     GRAB   : walks to the crate stack on your plot and picks up the crate
     SELL   : carries it to the sell area and cashes it in

     PLACE  : an egg only cooks once it is in a slot -- puts them in the nursery
     HATCH  : cracks one the moment the server flags it ready
     EQUIP  : sorts the slots above the nursery, strongest animal in slot 1

     Big Pet tab -- FOOD buys from the shop's stock, FEED walks it to the dance floor.
     Both need the Giant Pet unlocked ($10M prompt on the BigDanceFloor).

     Everything on is the whole chain: roll to your rarity floor, buy, cook, hatch,
     sort by earnings, and sell crates to pay for it. Anti-afk is always on.

     Two things take turns rather than run free: the loops that MOVE you (grab, sell,
     feed) and the ones that talk to PlacementService (equip, place, hatch). Both are
     shared resources -- one body, one server rate limit.

     Executor only (WindUI comes in over HttpGet). Stop: getgenv().dancingAnimalsStop()
     or the red button. ]]

-- config ---------------------------------------------------------------------
local ROLL_MIN = 0.1 -- floor for the roll rate; the game itself clamps to [0.1, 1]
local SETTLE = 0.35 -- seconds after a teleport before a prompt counts. Raise if a
-- grab/sell "silently doesn't take" -- that is the server still
-- seeing you at the old position.
local POLL = 0.1 -- beat while holding a prompt down
local CRATE_WAIT = 1 -- seconds between grab/sell cycles, and the slider's default
local CRATE_WAIT_MAX = 5 -- top of the slider. Past this you are just idling on a full plot.
local GRAB_TIMEOUT = 3 -- give up on a grab after this; the stack was probably empty
local SELL_TIMEOUT = 5 -- selling plays an animation, so it needs longer than a grab
local NEAR = 8 -- already this close? skip the teleport, we are in prompt range
local BIGPET_WAIT = 1 -- between food buys and feeds. Buying spends cash; feeding is free
-- but the server may rate-limit it, so they share one interval.
local EQUIP_WAIT = 1 -- between equip passes. A pass now sorts the whole floor, so this
-- is idle time once sorted, not per-slot cost.
local NURSERY = 2 -- slider default: slots held back at the weak end for eggs to hatch in
local NURSERY_MAX = 5 -- top of that slider
local SELL_BATCH = 20 -- uuids per Sell call; keeps one mistake from dumping everything
local SELL_WAIT = 5 -- between sell passes. Destructive, so it runs lazily.
local GAP_MIN = 0.25 -- placement calls self-tune between these two. The server rate-limits
local GAP_MAX = 3 -- them and says "Interacting too fast"; rather than guess its
-- threshold, back off on that answer and creep back down after.

local Players = game:GetService("Players")
local Stats = game:GetService("Stats")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService") -- only the shade uses this
local player = Players.LocalPlayer
local ping = Stats.Network.ServerStatsItem["Data Ping"]

if getgenv and getgenv().dancingAnimalsStop then
	getgenv().dancingAnimalsStop() -- re-running must not stack a second panel/loop
end

local running = true
local conns = {} -- every live connection; stop() walks this

if not fireproximityprompt then
	warn("[DancingAnimals] no fireproximityprompt -- GRAB and SELL will do nothing")
end

-- anti-afk -------------------------------------------------------------------
-- Roblox kicks after ~20 min without input, which is exactly how an overnight run ends.
-- A right-click through VirtualUser counts as input without touching the game. Two
-- triggers, because relying on Idled alone means one missed event costs the session:
--   * every 60s regardless, so the idle timer never gets near 20 min
--   * on Idled, which is the last warning before the kick
local hasVU, vu = pcall(game.GetService, game, "VirtualUser")
local hasVIM, vim = pcall(game.GetService, game, "VirtualInputManager")

-- Two input paths: a client that ignores one may still honour the other.
local function nudge(why)
	if hasVU then
		-- Down+Up beats ClickButton2: some clients ignore the one-shot version.
		local cf = workspace.CurrentCamera and workspace.CurrentCamera.CFrame or CFrame.new()
		pcall(function()
			vu:CaptureController()
			vu:Button2Down(Vector2.new(0, 0), cf)
			task.wait(0.05)
			vu:Button2Up(Vector2.new(0, 0), cf)
		end)
	end
	if hasVIM then
		pcall(function()
			vim:SendMouseButtonEvent(0, 0, 1, true, game, 0) -- right button, harmless
			vim:SendMouseButtonEvent(0, 0, 1, false, game, 0)
		end)
	end
	print(("[DancingAnimals] anti-afk nudge (%s) at %ds uptime"):format(why, math.floor(os.clock())))
end

table.insert(conns, player.Idled:Connect(function()
	nudge("Idled") -- Roblox's own idle warning: ~20 min without input it accepted
end))

task.spawn(function()
	while running do
		task.wait(60)
		if running then
			nudge("timer")
		end
	end
end)

-- Last line of defence. Whatever the disconnect reason -- idle kick, the game's own AFK
-- check, a network drop -- the error prompt shows up in CoreGui. Rejoin on sight.
-- ponytail: covers every cause at once instead of diagnosing which one fired.
task.spawn(function()
	local ok, overlay = pcall(function()
		local gui = game:GetService("CoreGui"):WaitForChild("RobloxPromptGui", 10)
		return gui and gui:WaitForChild("promptOverlay", 10)
	end)
	if not (ok and overlay) then
		-- Timeout rather than block forever, so a missing prompt GUI is visible, not silent.
		warn("[DancingAnimals] rejoin-on-disconnect NOT armed (no CoreGui.RobloxPromptGui.promptOverlay)")
		return
	end
	print("[DancingAnimals] anti-afk armed | VirtualUser", hasVU and "ok" or "MISSING", "| rejoin ok")
	table.insert(conns, overlay.ChildAdded:Connect(function(child)
		if child.Name:find("ErrorPrompt") then
			warn("[DancingAnimals] disconnected - rejoining")
			pcall(function()
				game:GetService("TeleportService"):Teleport(game.PlaceId, player)
			end)
		end
	end))
end)

-- world ----------------------------------------------------------------------
-- Every part we need lives under LocalPlayer.Plot, an ObjectValue the game keeps
-- pointed at your plot. That beats scanning PlotsContainer for OwnerUserId, and it
-- re-resolves for free after a rebirth or a plot swap.
local function plot()
	local ov = player:FindFirstChild("Plot")
	return ov and ov:IsA("ObjectValue") and ov.Value or nil
end

-- Recursive by name rather than the full path (Plot.Container.Components.SellCrates):
-- the names are what the game's own controllers look up, the nesting is not.
local function part(name)
	local p = plot()
	return p and p:FindFirstChild(name, true) or nil
end

local function tpTo(pos)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return false
	end
	if (hrp.Position - pos).Magnitude > NEAR then
		hrp.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
		-- Round trip, doubled: the server has to receive the move AND have replied
		-- before it will credit a prompt at the new position.
		task.wait(math.max(SETTLE, ping:GetValue() * 4 / 1000))
	end
	while player.GameplayPaused do -- streaming: the plot is not loaded yet
		task.wait(0.1)
	end
	return player.Character ~= nil
end

-- Grab, Sell and Feed each teleport somewhere different and then hold a prompt down. Run
-- loose they yank the character out from under each other mid-hold, and every one of them
-- burns its timeout. There is one body, so they take turns using it.
local moving = false

local function exclusive(fn)
	return function(alive)
		while moving do
			task.wait()
		end
		moving = true
		local ok, err = pcall(fn, alive) -- release on every path, thrown ones included
		moving = false
		if not ok then
			warn("[DancingAnimals]", err)
		end
	end
end

-- The crate is a Tool carrying its cash value in a TotalValue attribute. Matching the
-- attribute rather than the name "Crates" also skips eggs, food and potions, which are
-- Tools too.
local function crate()
	for _, holder in ipairs({ player.Character, player:FindFirstChildOfClass("Backpack") }) do
		if holder then
			for _, t in ipairs(holder:GetChildren()) do
				if t:IsA("Tool") and t:GetAttribute("TotalValue") then
					return t
				end
			end
		end
	end
	return nil
end

-- remotes --------------------------------------------------------------------
-- Knit: ReplicatedStorage.Knit.Services.<Service>.RE|RF.<Name>
local function remote(service, kind, name)
	local node = ReplicatedStorage:FindFirstChild("Knit")
	for _, step in ipairs({ "Services", service, kind, name }) do
		node = node and node:FindFirstChild(step)
	end
	if not node then
		warn(("[DancingAnimals] %s.%s.%s is gone -- re-run spy.lua"):format(service, kind, name))
	end
	return node
end

-- Knit's client wrapper is Ser.Serialize + FireServer, and Ser is the identity for the
-- strings and plain tables these remotes carry -- so talking to the raw RemoteEvent /
-- RemoteFunction is exactly what the game's own controllers do.

-- eggs -----------------------------------------------------------------------

-- The game's own data, rather than a copy of it that goes stale on the next update.
-- Rarities entries carry a Rank (Common 1 .. Exclusive 9), which is what makes
-- "Legendary or better" a comparison instead of a hardcoded list.
-- Indexing inside the closure, not as the pcall argument: `ReplicatedStorage.Data` on a
-- game that moved it throws before pcall ever runs.
local okEggs, Eggs = pcall(function()
	return require(ReplicatedStorage.Data.Eggs)
end)
local okRar, Rarities = pcall(function()
	return require(ReplicatedStorage.Data.Rarities)
end)
if not (okEggs and okRar) then
	warn("[DancingAnimals] ReplicatedStorage.Data.Eggs/Rarities missing -- rarity filter is off")
	Eggs, Rarities = {}, {}
end

-- Dropdown values built from Rarities itself, so a rarity added by an update shows up
-- here without touching this file.
local RARITIES = { "Any" }
do
	local ranked = {}
	for name, r in pairs(Rarities) do
		if type(r) == "table" and tonumber(r.Rank) then
			table.insert(ranked, { name = name, rank = r.Rank })
		end
	end
	table.sort(ranked, function(a, b)
		return a.rank < b.rank
	end)
	for _, r in ipairs(ranked) do
		table.insert(RARITIES, r.name)
	end
end

local function rankOf(name)
	local r = Rarities[name]
	return type(r) == "table" and tonumber(r.Rank) or 0
end

-- What is on the belt right now. Seeded once from the server, then kept current off
-- the same two events the game's own conveyor listens to -- so the check below costs
-- nothing per tick, and reacts before the roll-reveal animation has finished playing.
local currentEgg = nil
do
	local get = remote("EggConveyorService", "RF", "GetCurrentEgg")
	if get then
		local ok, info = pcall(get.InvokeServer, get)
		currentEgg = ok and type(info) == "table" and info or nil
	end
	local spawned, removed = remote("EggConveyorService", "RE", "EggSpawned"), remote("EggConveyorService", "RE", "RemoveEgg")
	if spawned then
		table.insert(
			conns,
			spawned.OnClientEvent:Connect(function(info)
				if type(info) == "table" then
					currentEgg = info
				end
			end)
		)
	end
	if removed then
		table.insert(
			conns,
			removed.OnClientEvent:Connect(function(uuid)
				if currentEgg and currentEgg.UUID == uuid then
					currentEgg = nil -- bought, by us or by whoever
				end
			end)
		)
	end
end

-- Rank of the egg on the belt, 0 when the belt is empty or the id is unknown.
local function currentRank()
	local egg = currentEgg and Eggs[currentEgg.Id]
	local r = egg and egg.Rarity
	return type(r) == "table" and tonumber(r.Rank) or 0
end

-- animals --------------------------------------------------------------------
-- The game's own scoring: (Earnings + Level * IncreasePerLevel) * mutations * cash
-- multiplier. It is named ForTool but it only reads attributes, and a pet Tool in your
-- bag and a PlacedModel on a dance floor carry the SAME four (PetId, Level, UUID,
-- Mutation) -- so one function ranks the bench and the floor on the same scale.
local okEarn, PetEarnings = pcall(function()
	return require(ReplicatedStorage.Shared.Helpers.PetEarnings)
end)
if not okEarn then
	warn("[DancingAnimals] PetEarnings helper missing -- Auto Equip is off")
	PetEarnings = nil
end

-- Pets carries the rarity, which is what keeps Auto Sell off the irreplaceable ones.
local okPets, Pets = pcall(function()
	return require(ReplicatedStorage.Data.Pets)
end)
if not okPets then
	warn("[DancingAnimals] Data.Pets missing -- Auto Sell is off, it cannot check rarity")
	Pets = nil
end

-- Rarity entries are sometimes the table and sometimes just its name; the game's own
-- collectors normalise the same way.
local function petRarity(inst)
	local d = Pets and Pets[inst:GetAttribute("PetId")]
	local r = d and d.Rarity
	if type(r) == "table" then
		return r.Name
	end
	return type(r) == "string" and r or nil
end

-- Equal scores land next to each other by definition, and among them the one already
-- standing in the lowest slot wins -- so a tie stays exactly where it is and costs no
-- interactions. (Benched animals carry slot = huge, so they queue behind anything already
-- down.) Sorting ties by uuid instead, as this used to, reshuffles equal animals for no
-- gain and turns one new best pet into a cascade of pointless swaps down the whole floor.
-- uuid survives only as the last resort between two benched animals, to keep the order
-- deterministic across passes.
local function strongestFirst(a, b)
	if a.score ~= b.score then
		return a.score > b.score
	end
	if a.slot ~= b.slot then
		return a.slot < b.slot
	end
	return tostring(a.uuid) < tostring(b.uuid)
end

-- The slot's own Unlocked attribute is authored false on every floor above the first and
-- stays that way -- the game never reads it. Unlocking is RebirthLevelRequired <= your
-- RebirthLevel, which is what this helper answers.
local okReb, RebirthHelper = pcall(function()
	return require(ReplicatedStorage.Shared.Modules.RebirthHelper)
end)
if not okReb then
	warn("[DancingAnimals] RebirthHelper missing -- falling back to the Unlocked attribute")
	RebirthHelper = nil
end

-- Held items are tagged, which is what the game's own prompts switch on: "Egg" gets you
-- "Place Egg", "Pet" gets "Place Pet"/"Swap". Cheaper and truer than sniffing attributes.
-- A hotbarred item is still a Tool in the Backpack -- the hotbar is a UI over it, and
-- its slots are just UUIDs -- so scanning Backpack + Character already covers the hotbar.
local function bagged(tag)
	local out = {}
	for _, holder in ipairs({ player.Character, player:FindFirstChildOfClass("Backpack") }) do
		if holder then
			for _, t in ipairs(holder:GetChildren()) do
				if t:IsA("Tool") and CollectionService:HasTag(t, tag) then
					table.insert(out, t)
				end
			end
		end
	end
	return out
end

local function benchPets()
	return bagged("Pet")
end

-- The profile is the only place that says whether a slot's egg has finished cooking.
-- Seeded once, then kept live off the same Updated event every controller listens to,
-- so no RemoteFunction round trip per pass.
local profile = nil
do
	local rf = remote("ProfileService", "RF", "GetProfile")
	if rf then
		local ok, p = pcall(rf.InvokeServer, rf)
		profile = ok and type(p) == "table" and p or nil
	end
	local updated = remote("ProfileService", "RE", "Updated")
	if updated then
		table.insert(
			conns,
			updated.OnClientEvent:Connect(function(p)
				if type(p) == "table" then
					profile = p
				end
			end)
		)
	end
end

-- PlacedObjects is keyed by the slot number as a STRING, and each entry is
-- { Type = "Egg" | "Pet", IsReady = bool, Id, Level }.
local function placedIn(n)
	local objs = profile and profile.PlacedObjects
	return type(objs) == "table" and objs[tostring(n)] or nil
end

-- Tagged lookup rather than walking the plot: a plot has thousands of descendants and
-- this runs every pass. BigDanceFloor is not tagged (Slot -1, it is the giant pet), so
-- the tag alone keeps the food pet out of the swap.
local function unlocked(m, n)
	if placedIn(n) then
		return true -- something is standing in it, so it is plainly usable
	end
	if RebirthHelper then
		return RebirthHelper.IsSlotUnlocked(profile and profile.RebirthLevel or 0, m) == true
	end
	return m:GetAttribute("Unlocked") == true -- fallback; floor 1 only
end

local function slots(p)
	local out = {}
	for _, m in ipairs(CollectionService:GetTagged("DANCE_FLOOR")) do
		local n = tonumber(m:GetAttribute("Slot"))
		if n and n >= 0 and m:IsDescendantOf(p) and unlocked(m, n) then
			table.insert(out, m)
		end
	end
	-- Ascending Slot is "first slot first" across every floor: the numbering runs 1-10 on
	-- floor 1, 11-20 on floor 2, 21-30 on floor 3, 31-40 on floor 4. Locked slots are
	-- already filtered out, so unlocking floor 2 just makes the list longer.
	table.sort(out, function(a, b)
		return tonumber(a:GetAttribute("Slot")) < tonumber(b:GetAttribute("Slot"))
	end)
	return out
end

-- big pet --------------------------------------------------------------------
-- Foods is keyed by Id and carries Name/Price/XP/Order -- the same table the in-game
-- food shop builds its list from, so the dropdown matches the shop row for row.
local okFood, Foods = pcall(function()
	return require(ReplicatedStorage.Data.Foods)
end)
if not okFood then
	warn("[DancingAnimals] ReplicatedStorage.Data.Foods missing -- food list is empty")
	Foods = {}
end

-- Ordered by the shop's own Order field, which runs cheapest first. That also happens
-- to be best-XP-per-dollar first: Watermelon is 0.2 XP/$ against Dragon Dinner's
-- 0.0001, so the only reason to buy up the ladder is that stock runs out.
local FOOD_NAMES, FOOD_ID = {}, {}
do
	local list = {}
	for id, f in pairs(Foods) do
		if type(f) == "table" then
			table.insert(list, { id = id, name = f.Name or id, order = tonumber(f.Order) or 0 })
		end
	end
	table.sort(list, function(a, b)
		return a.order < b.order
	end)
	for _, f in ipairs(list) do
		table.insert(FOOD_NAMES, f.name)
		FOOD_ID[f.name] = f.id
	end
end

-- The shop holds a limited quantity per restock. Firing PurchaseItem at an empty shelf
-- is not harmless: the server answers every one with an "Out of Stock!" banner, and at
-- one call a second they stack up and cover the screen. So keep a local count and only
-- spend a call when there is something to buy.
local foodStock = {}

local function refreshStock()
	local rf = remote("StockService", "RF", "GetStock")
	if not rf then
		return
	end
	local ok, stock = pcall(rf.InvokeServer, rf, "Food")
	if not ok or type(stock) ~= "table" then
		return
	end
	local fresh = {}
	for _, item in ipairs(stock.Items or {}) do
		if type(item) == "table" and item.Id then
			fresh[item.Id] = tonumber(item.Quantity) or 0
		end
	end
	foodStock = fresh
end

do
	refreshStock()
	-- StockUpdated is the restock bell -- the same event the game's own food shop
	-- re-reads on. Connected whether or not Auto Buy is on, so when the shelf refills
	-- the next pass already knows.
	local updated = remote("StockService", "RE", "StockUpdated")
	if updated then
		table.insert(conns, updated.OnClientEvent:Connect(refreshStock))
	end
end

-- Food arrives as one Tool per type with an Amount attribute, so a stack is a single
-- Tool you feed from repeatedly. Prefer the selected food, but fall back to anything
-- edible rather than idling on a stack you already own.
local function foodTool(want)
	local any = nil
	for _, holder in ipairs({ player.Character, player:FindFirstChildOfClass("Backpack") }) do
		if holder then
			for _, t in ipairs(holder:GetChildren()) do
				if t:IsA("Tool") and t:GetAttribute("ItemType") == "Food" then
					if t:GetAttribute("Id") == want then
						return t
					end
					any = any or t
				end
			end
		end
	end
	return any
end

-- farm -----------------------------------------------------------------------
-- Both read live off their controls, so a change lands on the next cycle rather than
-- needing the toggle flipped off and on.
local minRank = 0 -- from the dropdown; 0 = Any
local crateWait = CRATE_WAIT -- from the slider, seconds between grab/sell cycles
local foodId = FOOD_NAMES[1] and FOOD_ID[FOOD_NAMES[1]] or "Watermelon" -- cheapest by default
local nursery = NURSERY -- from the slider; slots held back at the weak end for hatching
local sellRarities = {} -- name -> true, from the multi-select. Empty means sell nothing.

local function roll()
	-- The whole point of "roll until": a keeper on the belt is thrown away by the
	-- next roll, so stop and let Auto Buy clear it.
	if minRank > 0 and currentRank() >= minRank then
		return
	end
	local rf = remote("EggConveyorService", "RF", "RequestEgg")
	if not rf then
		return
	end
	-- The server refuses a roll you cannot afford, or one while a reveal is playing.
	-- That is the normal case, not a reason to kill the loop.
	pcall(rf.InvokeServer, rf)
end

local function buy()
	if not (currentEgg and currentEgg.UUID) then
		return
	end
	if currentRank() < minRank then
		return -- below the floor; leave it for the next roll to overwrite
	end
	local re = remote("EggConveyorService", "RE", "PurchaseEgg")
	if re then
		-- No confirmation to wait on: RemoveEgg clears currentEgg when it lands, and
		-- until then a retry each tick is exactly what you want if you were short on cash.
		pcall(re.FireServer, re, currentEgg.UUID)
	end
end

-- Same cooldown the game's own button applies to itself. Firing faster just gets the
-- extra calls dropped, so there is nothing to win by ignoring it.
local function rollWait()
	return math.clamp(tonumber(player:GetAttribute("SkillTreeSkipCooldown")) or 1, ROLL_MIN, 1)
end

local function grab()
	if crate() then
		return -- hands full; SELL owns it from here
	end
	local anchor = part("CratePromptAnchor")
	local prompt = anchor and anchor:FindFirstChildWhichIsA("ProximityPrompt")
	if not (prompt and prompt.Enabled) then
		return
	end
	-- The prompt's ActionText IS the pending value ("$5.32T"). No non-zero digit means
	-- the stack is empty, so skip the teleport and the timeout entirely.
	if not (prompt.ActionText or ""):match("[1-9]") then
		return
	end
	if not tpTo(anchor.Position) then
		return
	end
	local t0 = os.clock()
	repeat -- wait for the Tool to exist, not for a return value
		fireproximityprompt(prompt)
		task.wait(POLL)
	until crate() or os.clock() - t0 > GRAB_TIMEOUT
end

local function sell()
	local tool = crate()
	if not tool then
		return
	end
	local target = part("SellCrates")
	if not target then
		return
	end
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		pcall(hum.EquipTool, hum, tool) -- the sell area wants it in your hands, not your bag
	end
	-- SellCrates is a sign mounted in the air; SellCratesSpawn is the floor under it,
	-- ~5 studs away and well inside the prompt's 10 stud range.
	local stand = part("SellCratesSpawn") or target
	if not tpTo(stand.Position) then
		return
	end
	local prompt = target:FindFirstChildWhichIsA("ProximityPrompt")
	local t0 = os.clock()
	repeat -- the Tool being destroyed is the server confirming the sale
		if prompt then
			fireproximityprompt(prompt)
		end
		task.wait(POLL)
	until not tool.Parent or os.clock() - t0 > SELL_TIMEOUT
end

local function buyFood()
	if (foodStock[foodId] or 0) <= 0 then
		return -- empty shelf: no call, so no "Out of Stock!" banner. Waits for StockUpdated.
	end
	local rf = remote("StockService", "RF", "PurchaseItem")
	if not rf then
		return
	end
	pcall(rf.InvokeServer, rf, "Food", foodId)
	-- Re-read rather than decrementing a guess. A purchase that failed for some other
	-- reason (short on cash) leaves the quantity alone, and decrementing would have
	-- stopped us buying until the next restock over a shortfall that lasted one second.
	refreshStock()
end

local function feed()
	local tool = foodTool(foodId)
	if not tool then
		return
	end
	-- The game's own FEED ANIMAL prompt does nothing but read the held Tool's Id and
	-- fire this remote, so the prompt is skippable -- but the Tool really must be held.
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		pcall(hum.EquipTool, hum, tool)
	end
	-- ponytail: the remote takes only an Id and the client does no position check, so
	-- this teleport is insurance against a server-side range check I could not confirm
	-- from the dump. If spy.lua shows Feed lands from anywhere, drop these three lines
	-- and Auto Feed stops fighting the crate loops over where you stand.
	local floor = part("BigDanceFloor")
	local spot = floor and floor:FindFirstChild("Alignment")
	if spot and not tpTo(spot.Position) then
		return
	end
	local re = remote("BigPetService", "RE", "Feed")
	if re then
		pcall(re.FireServer, re, tool:GetAttribute("Id"))
	end
end

-- PlacementService rate-limits per player and answers "Interacting too fast", so every
-- pickup and place goes through one gate. Spacing lives here rather than in the pass
-- interval because a single swap can be three interactions -- pacing the passes alone
-- still lets the calls inside one pass run back to back, which is what tripped it.
local lastInteract, lastEquipWarn = -math.huge, -math.huge
local gap = GAP_MIN

local function pause()
	local left = gap - (os.clock() - lastInteract)
	if left > 0 then
		task.wait(left)
	end
end

-- Auto Equip, Auto Place Eggs and Auto Hatch all come through here on their own threads.
-- A timestamp alone does not gate them: all three can clear pause() during the same idle
-- window and fire together, which is "Interacting too fast" all over again. The flag is a
-- real lock -- nothing yields between the check and the set, so the pass is atomic.
local busy = false

local function interact(rf, ...)
	while busy do
		task.wait()
	end
	busy = true
	pause()
	lastInteract = os.clock()
	local ok, done, why = pcall(rf.InvokeServer, rf, ...)
	busy = false
	-- The server names its own limit, so tune to it instead of hardcoding a guess: back
	-- off hard when it complains, ease back down while it keeps saying yes. Settles just
	-- above whatever the real threshold is, which is as quick as it can legally go.
	if ok and done == false and type(why) == "string" and why:find("too fast") then
		gap = math.min(GAP_MAX, gap * 1.5)
		return false
	end
	gap = math.max(GAP_MIN, gap * 0.97)
	if ok and done == false and os.clock() - lastEquipWarn > 5 then
		lastEquipWarn = os.clock()
		warn("[DancingAnimals] placement refused:", why) -- throttled; the reason is the useful part
	end
	return ok and done ~= false
end

local function toolFor(uuid)
	for _, t in ipairs(benchPets()) do
		if t:GetAttribute("UUID") == uuid then
			return t
		end
	end
	return nil
end

-- A hatching egg sits in a slot as a PlacedModel with no PetId -- that is the whole
-- difference from a placed pet, which always carries PetId/Level/UUID/Mutation.
local function isEgg(placed)
	return placed ~= nil and placed:GetAttribute("PetId") == nil
end

-- Which slot currently holds this animal, if any. Looked up fresh at move time rather
-- than remembered: the pass moves pets around, and a reference taken before the first
-- swap is wrong by the third.
local function slotHolding(floor, uuid)
	for _, m in ipairs(floor) do
		local placed = m:FindFirstChild("PlacedModel")
		if placed and placed:GetAttribute("UUID") == uuid then
			return m
		end
	end
	return nil
end

-- Slot 1 gets your strongest animal, slot 2 the next, and so on down. One pass sorts
-- the whole floor -- the interaction gate paces it, so there is nothing to gain by
-- spending a whole pass interval per slot. A pass with nothing to fix is the "already
-- sorted" signal: no plan to keep, nothing to invalidate when a pet hatches mid-sweep.
local function autoEquip(alive)
	local p = plot()
	if not (p and PetEarnings) then
		return
	end
	local best = PetEarnings.GetBest(player) -- needed by pets priced as a % of your best
	local function score(inst)
		return inst and PetEarnings.ForTool(inst, best) or -1
	end

	-- Ascending Slot is "first slot first" across every floor: the numbering runs 1-10
	-- on floor 1, 11-20 on floor 2, 21-30 on floor 3, 31-40 on floor 4. Locked slots are
	-- already filtered out, so unlocking floor 2 just makes the list longer.
	--
	-- Egg slots are dropped outright. The server will neither pick the egg up nor place
	-- into the slot, so an egg slot is not a slot to fill -- leaving it in meant every
	-- pass stalled on it and the sort never reached the slots below.
	local all = slots(p)
	local floor = {}
	for i = 1, math.max(0, #all - nursery) do -- the tail is the nursery; leave it for eggs
		if not isEgg(all[i]:FindFirstChild("PlacedModel")) then
			table.insert(floor, all[i])
		end
	end
	if #floor == 0 then
		return
	end

	-- Every animal you own ranked together -- the ones already down on the floor and the
	-- ones on the bench compete for the same slots, or slot 1 could never be beaten.
	local roster = {}
	for _, m in ipairs(floor) do
		local placed = m:FindFirstChild("PlacedModel")
		if placed then
			table.insert(roster, { uuid = placed:GetAttribute("UUID"), score = score(placed), slot = tonumber(m:GetAttribute("Slot")) })
		end
	end
	for _, t in ipairs(benchPets()) do
		table.insert(roster, { uuid = t:GetAttribute("UUID"), score = score(t), slot = math.huge })
	end
	table.sort(roster, strongestFirst)

	local pick = remote("PlacementService", "RF", "PickupItem")
	local place = remote("PlacementService", "RF", "PlaceItem")
	if not (pick and place) then
		return
	end

	for i, m in ipairs(floor) do
		if alive and not alive() then
			return -- toggled off mid-sort; do not keep placing
		end
		local want = roster[i]
		if not want then
			return -- fewer animals than slots; leave the tail empty
		end
		local placed = m:FindFirstChild("PlacedModel")
		if (placed and placed:GetAttribute("UUID")) ~= want.uuid then
			-- No evict call: placing onto a slot that already holds a PET is a swap --
			-- that is what the game's own prompt reads when you walk up holding one --
			-- and the occupant comes back to your bag by itself. Egg-held slots are the
			-- ones that genuinely refuse, and they were filtered out above.
			local at = slotHolding(floor, want.uuid)
			if at and not interact(pick, at:GetAttribute("Slot")) then
				return -- it was down on another slot and would not come up
			end
			-- Waiting out the gate before placing doubles as time for a just-picked-up
			-- Tool to replicate back into the Backpack so it can be held.
			pause()
			local tool = toolFor(want.uuid)
			local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if hum and tool then
				pcall(hum.EquipTool, hum, tool) -- the game places what you hold; match it
			end
			if not interact(place, m:GetAttribute("Slot"), want.uuid) then
				return
			end
		end
	end
end

-- An egg only starts cooking once it is in a slot -- nothing hatches in your bag. Fill
-- the nursery from the weak end up, one egg per free slot.
local function placeEggs(alive)
	local p = plot()
	if not (p and nursery > 0) then
		return
	end
	local place = remote("PlacementService", "RF", "PlaceItem")
	if not place then
		return
	end
	local all = slots(p)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	for i = math.max(1, #all - nursery + 1), #all do
		if alive and not alive() then
			return
		end
		local m = all[i]
		if not m:FindFirstChild("PlacedModel") then -- free crib
			local egg = bagged("Egg")[1]
			if not egg then
				return -- no eggs left to place
			end
			if hum then
				pcall(hum.EquipTool, hum, egg)
			end
			if not interact(place, m:GetAttribute("Slot"), egg:GetAttribute("UUID")) then
				return
			end
		end
	end
end

-- IsReady is the server's own hatch flag; the prompt the game draws switches on exactly
-- this. Anything not ready is still cooking, so leave it alone.
local function autoHatch(alive)
	local p = plot()
	if not p then
		return
	end
	local hatch = remote("PlacementService", "RF", "HatchEgg")
	if not hatch then
		return
	end
	for _, m in ipairs(slots(p)) do
		if alive and not alive() then
			return
		end
		local n = m:GetAttribute("Slot")
		local o = placedIn(n)
		if o and o.Type == "Egg" and o.IsReady then
			interact(hatch, n)
		end
	end
end

-- Sells the animals piling up in your bag, by rarity. Naming a rarity in the dropdown is
-- the whole safety model: an animal is sold because you ticked its rarity, never because
-- a ranking decided it was surplus. Selling cannot be undone, so nothing is implicit.
local lastSellWarn = -math.huge
local function autoSell(alive)
	local sell = remote("SellService", "RE", "Sell")
	if not (sell and Pets and next(sellRarities)) then
		return -- nothing ticked is the safe default, and it means nothing gets sold
	end

	-- benchPets() is the "Pet" tag, so eggs are not reachable from here at all -- they
	-- carry "Egg" and are the nursery's business. Placed animals are in use, so the bag
	-- is the only thing this touches.
	local doomed, probe = {}, nil
	for _, t in ipairs(benchPets()) do
		if sellRarities[petRarity(t) or ""] then
			table.insert(doomed, t:GetAttribute("UUID"))
			probe = probe or t
			if #doomed >= SELL_BATCH then
				break
			end
		end
	end
	if #doomed == 0 then
		return
	end

	-- The booth is one shared part in the world, not something on your plot.
	local booth = workspace:FindFirstChild("Scripted")
	booth = booth and booth:FindFirstChild("SellInteractionPart")
	if booth and not tpTo(booth.Position) then
		return
	end
	if alive and not alive() then
		return
	end
	pcall(sell.FireServer, sell, doomed)

	-- Sell is a RemoteEvent, so there is no answer to read -- watch the bag instead. The
	-- Tool going away is the server agreeing; still there after 3s means it refused, and
	-- standing somewhere other than the booth is the first thing to suspect.
	local t0 = os.clock()
	repeat
		task.wait(0.2)
	until not probe.Parent or os.clock() - t0 > 3
	if probe.Parent and os.clock() - lastSellWarn > 10 then
		lastSellWarn = os.clock()
		warn(("[DancingAnimals] sold %d animals but nothing left the bag -- did the booth move?"):format(#doomed))
	end
end

-- gui ------------------------------------------------------------------------
local WindUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()

local Window = WindUI:CreateWindow({
	Title = "Dancing Animals",
	Icon = "solar:music-note-2-bold",
	Folder = "DancingAnimals",
	Size = UDim2.fromOffset(420, 300),
	Topbar = { Height = 44, ButtonsType = "Mac" },
	OpenButton = { Title = "Dancing Animals", Enabled = true, Draggable = true },
})

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local EggSec =
	Tab:Section({ Title = "Eggs", Icon = "solar:planet-bold", Box = true, BoxBorder = true, Opened = true })
local Crates =
	Tab:Section({ Title = "Crates", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })

-- wiring ---------------------------------------------------------------------
-- gen guards against off-then-on inside one interval: without it the sleeping thread
-- wakes up alongside the new one and the loop runs at double rate.
--
-- It is PER TOGGLE, and must stay that way. A single shared counter looks like it
-- works and does not: every toggle's callback bumps it, so switching one loop on
-- orphans every loop already running -- only the most recent survives.
local function loopToggle(section, title, desc, body, wait)
	local gen = 0
	section:Toggle({
		Title = title,
		Desc = desc,
		Value = false,
		Callback = function(state)
			gen = gen + 1
			if not state then
				return
			end
			local mine = gen
			task.spawn(function()
				-- Handed to the body so a long pass can bail the moment the switch flips.
				-- Bodies that finish quickly just ignore the argument.
				local function alive()
					return running and gen == mine
				end
				while alive() do
					pcall(body, alive) -- a model dying mid-sweep throws; restart, do not crash
					task.wait(wait and wait() or POLL)
				end
			end)
		end,
	})
end

-- Above the toggles it gates, so the floor is set before anything starts running.
EggSec:Dropdown({
	Title = "Min rarity",
	Desc = "The floor for both Auto Roll and Auto Buy. Any = never stop, buy everything.",
	Values = RARITIES,
	Value = "Any",
	Callback = function(name)
		minRank = rankOf(name) -- "Any" is not in Rarities, so it lands on 0
	end,
})

loopToggle(EggSec, "Auto Roll", "Rolls until Min rarity shows up, then holds", roll, rollWait)
loopToggle(EggSec, "Auto Buy Egg", "Buys the egg on the belt once it clears Min rarity", buy)
-- Above its toggles, same reason as Min rarity. Step 0.1 puts WindUI in fractional
-- mode, so the readout is 1.00 rather than a rounded integer.
Crates:Slider({
	Title = "Cycle delay",
	Desc = "Seconds between grab/sell passes",
	Step = 0.1,
	Value = { Min = 0.1, Max = CRATE_WAIT_MAX, Default = CRATE_WAIT },
	Callback = function(v)
		crateWait = tonumber(v) or CRATE_WAIT
	end,
})

local function crateDelay()
	return crateWait
end

loopToggle(Crates, "Auto Grab Crates", "Picks up the crate on your plot", exclusive(grab), crateDelay)
loopToggle(Crates, "Auto Sell Crates", "Carries it to the sell area", exclusive(sell), crateDelay)

local Animals =
	Tab:Section({ Title = "Animals", Icon = "solar:bone-bold", Box = true, BoxBorder = true, Opened = true })

local function equipDelay()
	return EQUIP_WAIT
end

-- Above the toggles it gates, same as the other two dropdowns.
Animals:Slider({
	Title = "Nursery slots",
	Desc = "Slots held back at the weak end for eggs. 0 = none, and eggs never get placed",
	Step = 1,
	Value = { Min = 0, Max = NURSERY_MAX, Default = NURSERY },
	Callback = function(v)
		nursery = tonumber(v) or NURSERY
	end,
})

loopToggle(Animals, "Auto Equip Best", "Sorts the slots above the nursery, strongest first", autoEquip, equipDelay)
loopToggle(Animals, "Auto Place Eggs", "Puts bought eggs into free nursery slots to cook", placeEggs, equipDelay)
loopToggle(Animals, "Auto Hatch", "Cracks a nursery egg the moment the server says it is ready", autoHatch, equipDelay)

-- Ticking a rarity IS the consent, which is why there is no separate safety net: nothing
-- is sold that you did not name, and an empty list sells nothing at all. "Any" is dropped
-- from the list here -- as a sell rule it would mean "everything", which is never a thing
-- you want one misclick away.
local SELLABLE = {}
for i = 2, #RARITIES do
	table.insert(SELLABLE, RARITIES[i])
end

Animals:Dropdown({
	Title = "Sell rarities",
	Desc = "Auto Sell drops every spare animal of these rarities. Cannot be undone.",
	Values = SELLABLE,
	Multi = true,
	AllowNone = true,
	Value = {},
	Callback = function(picked)
		-- Copied into a set rather than held by reference: WindUI mutates that table in
		-- place, and a lookup beats scanning it once per animal in the bag.
		local set = {}
		for _, name in ipairs(picked or {}) do
			set[name] = true
		end
		sellRarities = set
	end,
})

loopToggle(Animals, "Auto Sell Spares", "Sells every bagged animal of the ticked rarities", exclusive(autoSell), function()
	return SELL_WAIT
end)

-- big pet tab ----------------------------------------------------------------
local PetTab = Window:Tab({ Title = "Big Pet", Icon = "solar:paw-bold" })
local FoodSec = PetTab:Section({
	Title = "Food",
	Desc = "Needs the Giant Pet unlocked ($10M at the dance floor)",
	Icon = "solar:cart-large-2-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})

FoodSec:Dropdown({
	Title = "Food",
	Desc = "What Auto Buy purchases, and what Auto Feed reaches for first",
	Values = FOOD_NAMES,
	Value = FOOD_NAMES[1],
	Callback = function(name)
		foodId = FOOD_ID[name] or foodId
	end,
})

loopToggle(FoodSec, "Auto Buy Food", "Buys one per pass until the shop runs dry", buyFood, function()
	return BIGPET_WAIT
end)
loopToggle(FoodSec, "Auto Feed", "Feeds the Giant Pet from whatever stack you hold", exclusive(feed), function()
	return BIGPET_WAIT
end)

-- minimize -------------------------------------------------------------------
-- Same swap as buy_chickens.lua. WindUI's own Minimize hides the whole window and
-- leaves nothing but the floating open button, which it only draws on touch devices --
-- on a PC the panel is gone with nothing left to click. This collapses the body to a
-- bare title bar instead, and the same button rolls it back down. Loops keep farming.
--
-- Main is anchored at its CENTRE, so resizing alone moves all four edges and the shade
-- lands mid-screen. Every resize is paired with a position nudge of half the delta,
-- which pins the TOP-LEFT corner: the bar collapses where it stands.
local SHADE_W = 280 -- traffic lights + icon + "Dancing Animals" + this button
-- (20 wider than buy_chickens: the title is three characters longer)
local SHADE_PAD = 10 -- topbar height + window chrome; nudge if the shade clips

Window:DisableTopbarButtons({ "Minimize" }) -- before ours, it reuses the same slot

local SHADE_SIZE = UDim2.fromOffset(SHADE_W, Window.Topbar.Height + SHADE_PAD)
local SHADE_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local shaded, fullSize = false, nil
Window:CreateTopbarButton("Shade", "minus", function()
	local main = Window.UIElements.Main
	shaded = not shaded

	if shaded then
		fullSize = main.Size -- read live, so a resized window comes back its own size
	end
	-- By name rather than by index, so a WindUI reshuffle of the body frames is harmless.
	for _, child in ipairs(main.Main:GetChildren()) do
		if child:IsA("GuiObject") and child.Name ~= "Topbar" then
			child.Visible = not shaded
		end
	end

	-- Both ends are known, so the delta is computed rather than read back off a frame
	-- that is still mid-tween from the last click.
	local from, to = shaded and fullSize or SHADE_SIZE, shaded and SHADE_SIZE or fullSize
	local p = main.Position
	Window:SetSize(to)
	-- Matched to SetSize's own tween, or the corner slides while the size catches up.
	TweenService:Create(main, SHADE_TWEEN, {
		Position = UDim2.new(
			p.X.Scale,
			p.X.Offset + (to.X.Offset - from.X.Offset) / 2,
			p.Y.Scale,
			p.Y.Offset + (to.Y.Offset - from.Y.Offset) / 2
		),
	}):Play()
end, 998, nil, Color3.fromHex("#F4C948")) -- same yellow the real Minimize used

-- close ----------------------------------------------------------------------
local function stop()
	running = false -- every loop checks this alongside its own gen, so one flag stops them all
	for _, c in ipairs(conns) do
		-- Belt trackers, stock, profile, and the anti-afk hooks -- everything `running`
		-- does not cover, including the rejoin watcher. Closing the panel means stop.
		pcall(c.Disconnect, c)
	end
	if getgenv then
		getgenv().dancingAnimalsStop = nil
	end
end

Window:OnDestroy(stop)
if getgenv then
	getgenv().dancingAnimalsStop = function()
		stop()
		pcall(function()
			Window:Destroy()
		end)
	end
end

print(
	"[DancingAnimals] loaded -- plot:",
	plot() and plot():GetFullName() or "NOT FOUND (rejoin?)",
	"| giant pet:",
	player:GetAttribute("GiantPetUnlocked") == true and "unlocked" or "LOCKED (Auto Feed will do nothing)"
)
