--[[ Drill Ores -- the ore roller / crate hauler (122572082932179)

     CRATES  : your CrateMaker fills with crates on its own. When enough are waiting
               this hops to the spawn point, picks them all up, hops to the seller
               table and sells them. Two prompts, ~38 studs apart, about two seconds
               a round trip.

               "Send to Furnace" puts two more stops in the middle: Place ORES at the
               furnace, wait out the smelt, pick the metal crates back up, then sell
               those instead. Metal is worth several times the raw load. Both are
               ordinary prompts, and metal rides in the same CarryingCrates state as
               ore -- which is exactly why only crates THIS run picked up go to the
               furnace: a run that starts already carrying cannot tell the two apart,
               and would try to smelt metal.
     ROLL    : pulls the Roller's lever. What the two ticked lists MEAN depends on
               whether Auto Buy is on: with it on they are a shopping list and rolling
               continues; with it off they are a stop condition -- the first match ends
               the rolling and is left sat on its pedestal for you. Tick nothing and it
               just rolls forever. It does not guess an interval --
               the server announces the roller locking and unlocking on
               RollerRollEvent, so the next pull goes out the moment the last
               animation finishes and never a beat before.
     AUTO BUY: one lever pull rolls EVERY pedestal at once and the server hands you
               the whole list -- {pedestalName, oreName} per pedestal -- on the same
               event. So buying is not a scan and not a prompt: it is
               RollerPurchaseEvent:FireServer(pedestal, ore), fired from wherever you
               happen to be standing, for the rolled ores you ticked -- by rarity, by
               name, or both. The two lists OR together: a rarity is your broad net and
               a name is an exception you always want, and neither can ever narrow the
               other. It never fires a purchase it cannot pay for, because the server
               answers those with a Robux prompt rather than an error. Everything you
               don't buy is overwritten by the next pull, so an unticked ore costs
               nothing but the roll it came on.

     TUNNELS : BaseBuildTunnelAction:InvokeServer(base, 1, "Tunnel1", "EquipBest") and
               the same shape with "ApplyBestGrowthGems". Both are the game's own
               commands, so the SERVER picks the best ore and the best gem placement --
               there is no ranking to get wrong on this side.

               The floor and tunnel arguments are vestigial. The game's own button
               hardcodes 1 / "Tunnel1" and the server does the WHOLE BASE, replying
               with result.equipped -- a list of every tunnel it touched. So this is
               one call each, not one per tunnel; an earlier pass of this script swept
               all 105 and was doing the same base-wide job 105 times over.

               Equip first, gems second: gems boost whatever is currently in the
               tunnel, so gemming before the swap boosts the ore about to be replaced.
               Both re-run on a timer and immediately after a purchase, which is the
               only thing that moves "best".

     Read off a dump and then off two probes rather than guessed at:

       * The prompts' MaxActivationDistance (7.5 on the lever, 10 on pickup and sell)
         is enforced by the SERVER against its own copy. Writing that property on the
         client does not replicate, so opening the gate wide changes nothing at all --
         the only way in is to actually be there. Hence PARK.
       * Ground-level CFrame writes stick here: no anti-cheat, no snap-back. A hop
         straight UP does not, but that is gravity, not the server -- you simply fall
         back down. So every hop lands on the floor beside its prompt.
       * fireproximityprompt wins on all three prompts, first try, at 4-6 studs.
         HoldDuration is 0 everywhere: these are taps, not holds.
       * The game ships an AutoRollerPanel with a rarity sidebar and a PremiumAutoBuy
         Robux product, but no controller script and no remote behind it -- it is
         unreleased. There is no server-side auto-roller to switch on, so this rolls
         the lever by hand, and the buying half is free.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().drillOresStop() ]]

-- config ---------------------------------------------------------------------
local PARK = 4 -- studs to stand off a prompt's own part. Every gate here is 7.5-10
-- and the server checks its own copy, so this is "comfortably inside" rather than
-- "as close as possible". Raise it and the lever (7.5) starts refusing first.
local ROLL_PARK = 5.5 -- the lever swings ~70 degrees when it is pulled and would sweep
-- through anyone stood at PARK, so the roller gets its own, further standoff. It cannot
-- go much further: with LIFT the real distance is sqrt(5.5^2 + 3^2) = 6.3 studs against
-- the lever's 7.5 gate, and the server measures the one it computes, not the one here.
local LIFT = 3 -- studs up, so the hop lands on the floor instead of inside it
local SETTLE = 0.6 -- seconds after a hop before the first press. The range check runs
-- against where the SERVER thinks you are, and it has not seen the move yet.
local PRESS_GAP = 0.15 -- seconds between re-fires while waiting for the world to change
local CONFIRM = 4 -- seconds of pressing before calling it a refusal rather than a miss
local EQUIP_EVERY = 30 -- seconds between full tunnel sweeps. A sweep also runs early
-- whenever a purchase lands, which is the only moment "best" can actually change --
-- the timer is just the backstop for ores arriving some other way.
local EQUIP_TIMEOUT = 3 -- seconds to wait on one InvokeServer before abandoning it
local FURNACE_WAIT = 25 -- seconds to keep pressing the metal pickup while the furnace
-- smelts. The smelt time is not in the dump and scales with the furnace's level, so
-- this is a ceiling rather than a measurement: the press loop lands the instant the
-- prompt arms, and the constant only decides when to give up and sell raw.
local ROLL_WAIT = 20 -- seconds to wait for the roller to announce itself ready again.
-- Generous on purpose: it is a cutscene, not a cooldown, and a long reveal on a rare
-- ore is exactly when you least want the loop to give up and re-pull.
local BUY_GAP = 0.12 -- seconds between purchases -- one pull rolls several pedestals,
-- and firing the whole batch in one frame is how a per-player debounce eats all but one
local BUY_STRIKES = 3 -- refused purchases in a row before auto buy pauses itself
local BUY_BACKOFF = 20 -- seconds to sit out after that. The usual reason is "broke",
-- which fixes itself as the crate loop sells, so this waits rather than switching off.
local ROLL_STRIKES = 3 -- lever pulls the server ignored before auto roll gives up
local IDLE = 1 -- seconds between passes when there was nothing to do
local STUCK_AFTER = 30 -- seconds on one step before the watchdog says where it parked

local KEY_TOGGLE = Enum.KeyCode.RightControl

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().drillOresStop then
	getgenv().drillOresStop() -- re-running must not stack a second panel/loop
end

local Bases = workspace:WaitForChild("Bases", 10)
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not (Bases and Remotes) then
	return warn("[drill] no workspace.Bases / ReplicatedStorage.Remotes -- wrong game?")
end

local BaseCrateAction = Remotes:WaitForChild("BaseCrateAction", 10)
local BaseCrateStateChanged = Remotes:WaitForChild("BaseCrateStateChanged", 10)
local BaseBuildTunnelAction = Remotes:WaitForChild("BaseBuildTunnelAction", 10)
local RollerRollEvent = ReplicatedStorage:WaitForChild("RollerRollEvent", 10)
local RollerPurchaseEvent = ReplicatedStorage:WaitForChild("RollerPurchaseEvent", 10)

-- The game's own rarity table: 13 rungs, and GetOre() is what turns a rolled ore's
-- name into one of them. Requiring it beats copying the list -- an update that adds a
-- rarity lands here for free -- but it is also the one thing that can come back nil,
-- so the rarity filter degrades to "buy nothing" rather than to "buy everything".
local meta
pcall(function()
	meta = require(ReplicatedStorage:WaitForChild("OreMetadata", 5))
end)
local RARITIES = (meta and meta.Rarities) or {}
if #RARITIES == 0 then
	warn("[drill] OreMetadata would not load -- auto buy cannot rank rarities and will stay off")
end

-- world ----------------------------------------------------------------------
local function hrp()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- Shape, not path: this is the same pair of attributes the game's own RollerClient
-- resolves your base with, and it re-resolves every call because BaseAssignmentChanged
-- is a thing that happens.
local function myBase()
	local n = player:GetAttribute("AssignedBaseName") or player:GetAttribute("BaseName")
	if type(n) == "string" and Bases:FindFirstChild(n) then
		return Bases:FindFirstChild(n)
	end
	for _, b in ipairs(Bases:GetChildren()) do
		if b:GetAttribute("OwnerUserId") == player.UserId or b:GetAttribute("OwnerName") == player.Name then
			return b
		end
	end
end

-- Reached by name from the base root rather than by full path: the seller prompt hangs
-- off a MeshPart called `Meshes/SellerTable_TableBoard (1)`, which is not a name worth
-- writing down twice.
local function leverPrompt()
	local base = myBase()
	local lever = base and base:FindFirstChild("Roller")
	lever = lever and lever:FindFirstChild("Lever")
	return lever and lever:FindFirstChildWhichIsA("ProximityPrompt")
end

local function pickupPrompt()
	local base = myBase()
	return base and base:FindFirstChild("PickUpOresPrompt", true)
end

local function sellPrompt()
	local base = myBase()
	return base and base:FindFirstChild("SellOresPrompt", true)
end

-- Scoped to the Furnace rather than searched from the base root: "PickUpCratesPrompt"
-- (metal, at the furnace) and "PickUpOresPrompt" (raw, at the crate maker) are one word
-- apart, and picking the wrong one sends the loop to the wrong end of the base.
local function furnacePrompt(name)
	local base = myBase()
	local f = base and base:FindFirstChild("Furnace")
	return f and f:FindFirstChild(name, true)
end

-- The furnace is a purchase. The attribute sits on both the Player and the Furnace
-- model, and either saying false is enough -- but neither being readable is NOT a
-- reason to refuse, or a renamed attribute silently disables the whole route.
local function furnaceOwned()
	local base = myBase()
	local f = base and base:FindFirstChild("Furnace")
	if not f then
		return false
	end
	if f:GetAttribute("FurnacePurchased") == false or player:GetAttribute("FurnacePurchased") == false then
		return false
	end
	return true
end

-- These all ship Enabled=false and only the game's own controller turns them on, near
-- you, when it feels like it. Opening the gate is a client-side decision the server
-- never sees, so it is free -- but it has to be undone at teardown or the player is
-- left with prompts the game thinks it is hiding.
local opened = {}
local function openGate(p)
	if opened[p] then
		return
	end
	opened[p] = { p.Enabled, p.RequiresLineOfSight }
	p.Enabled, p.RequiresLineOfSight = true, false
end

local function restoreGates()
	for p, was in pairs(opened) do
		pcall(function()
			p.Enabled, p.RequiresLineOfSight = was[1], was[2]
		end)
	end
	table.clear(opened)
end

-- The prompt's range check measures from the part the prompt hangs off, which on a
-- rig-shaped model is nowhere near the pivot -- so aim at the ancestor BasePart, never
-- at the model.
local function anchorOf(p)
	return p:FindFirstAncestorWhichIsA("BasePart") or (p.Parent and p.Parent:IsA("BasePart") and p.Parent or nil)
end

-- Ground-level writes stick here (probed), so this is a plain CFrame write and a
-- settle. It reports whether we actually arrived, because a hop that silently did not
-- makes every press after it look like a refusal.
-- ponytail: fixed +Z offset. Landed clean on all three stations; if a base skin ever
-- parks you inside a wall, sample a couple of compass directions instead.
local function hop(pos, faceAt)
	local root = hrp()
	if not root then
		return false
	end
	-- Level the aim with our own Y or the character leans back to look up at a prompt
	-- that sits above head height.
	root.CFrame = faceAt and CFrame.lookAt(pos, Vector3.new(faceAt.X, pos.Y, faceAt.Z)) or CFrame.new(pos)
	task.wait(SETTLE)
	local t0 = os.clock()
	while player.GameplayPaused and os.clock() - t0 < 3 do
		task.wait(0.1)
	end
	root = hrp() -- may have respawned out from under us
	return root ~= nil and (root.Position - pos).Magnitude < 15
end

-- Stand where a player would stand: out along the part's OWN front face, looking back
-- at it. A fixed compass offset puts you behind the lever as often as in front of it,
-- which reads as the script standing inside the mechanism -- and the range check does
-- not care which side you approach from, so facing it costs nothing.
local function goTo(prompt, park)
	local a = prompt and anchorOf(prompt)
	if not a then
		return false
	end

	-- Already close enough? Then don't move. Teleporting a player who is stood at the
	-- lever anyway is pure cost: a hop, a SETTLE, and their camera yanked round every
	-- pull. The prompt's own MaxActivationDistance is the honest threshold -- the
	-- client's copy is the value the server started with -- less a stud, because what
	-- the server range-checks is where it thinks you are, not where you are.
	local root = hrp()
	if root and (root.Position - a.Position).Magnitude <= math.max(prompt.MaxActivationDistance - 1, 1) then
		return true
	end

	local dir = a.CFrame.LookVector
	dir = Vector3.new(dir.X, 0, dir.Z) -- a part lying flat fronts at the sky; flatten it
	dir = dir.Magnitude > 0.01 and dir.Unit or Vector3.new(0, 0, 1)
	return hop(a.Position + dir * (park or PARK) + Vector3.new(0, LIFT, 0), a.Position)
end

local function firePress(p)
	if fireproximityprompt then
		fireproximityprompt(p, p.HoldDuration)
	else
		-- Same key, down the real input path. Slower, and it wants you genuinely in
		-- range -- which the hop just saw to.
		p:InputHoldBegin()
		task.wait(p.HoldDuration + 0.1)
		p:InputHoldEnd()
	end
end

-- Three answers, not two. true: the world changed. false: fired for the whole window
-- and it did not, which is a refusal worth counting. nil: there was nothing to fire at,
-- which is a streaming hiccup and must NOT be counted as one.
local function press(prompt, done, timeout)
	if not prompt then
		return nil
	end
	openGate(prompt)
	local t0 = os.clock()
	repeat
		pcall(firePress, prompt)
		task.wait(PRESS_GAP)
		if done() then
			return true
		end
	until os.clock() - t0 > (timeout or CONFIRM)
	return false
end

-- one character, two loops that move it ---------------------------------------
local busy = false
local function claim(fn)
	if busy then
		return false
	end
	busy = true
	local ok, err = pcall(fn)
	busy = false
	if not ok then
		warn("[drill]", err)
	end
	return true
end

-- breadcrumb + watchdog: a farm thread parked in a yield cannot report anything, so
-- the reporting lives on a thread of its own.
local mark, markAt = "idle", os.clock()
local function step(name)
	mark, markAt = name, os.clock()
end

local running = true -- cleared by stopAll, so a re-paste does not stack watchdogs

task.spawn(function()
	local told
	while running do
		task.wait(5)
		if os.clock() - markAt > STUCK_AFTER and told ~= mark then
			told = mark
			warn(("[drill] stuck %ds at: %s"):format(math.floor(os.clock() - markAt), mark))
		end
	end
end)

-- the server's answer ---------------------------------------------------------
-- CarriedCrateCount is a dead field -- it is 0 in every payload the dump caught.
-- CarryingCrates and CrateCount are the two that actually move.
local state = {}
local conns = {}

table.insert(
	conns,
	BaseCrateStateChanged.OnClientEvent:Connect(function(s)
		if type(s) == "table" then
			state = s
		end
	end)
)

-- The push only arrives when something changes, so a script that has just started
-- knows nothing. The game's own CrateClient seeds itself exactly this way.
local function refreshState()
	local base = myBase()
	if not base then
		return false
	end
	local ok, res = pcall(function()
		return BaseCrateAction:InvokeServer(base.Name, "GetState")
	end)
	if ok and type(res) == "table" and res.success and type(res.result) == "table" then
		state = res.result
		return true
	end
	return false
end

-- Your spendable balance. MoneyCents is the exact one -- Money is it rounded, and
-- leaderstats.Money is a StringValue ("$13"), which is for reading, not arithmetic.
-- Returns nil for "could not read it", never 0: failing open to 0 would read as
-- "broke" and silently switch auto buy off forever.
local function money(): number?
	local cents = tonumber(player:GetAttribute("MoneyCents"))
	if cents then
		return cents / 100
	end
	return tonumber(player:GetAttribute("Money"))
end

local function crateCount()
	return tonumber(state.CrateCount) or 0
end

local function carrying()
	return state.CarryingCrates == true
end

-- What is in your arms right now, in dollars. Cents arrive as a STRING (the values run
-- past what a float holds cleanly), and this is the number worth reporting after a
-- sale -- StoredMoney is the crate maker's store, which is zero the moment you sell.
local function carriedValue()
	return (tonumber(state.CarriedValueCents) or 0) / 100
end

-- rarity filter ---------------------------------------------------------------
local wanted = {} -- rarity -> true, read live by the buy handler
local wantedOres = {} -- ore name -> true. ORs with the rarities above, never narrows
-- them: a ticked thing must never be able to reduce what gets bought, or the panel is
-- lying about what it is doing.

-- Every ore the game knows, rarest first and alphabetical within a rarity, so the end
-- of the list you actually care about is together at the top.
local ORE_NAMES = {}
do
	local rank = (meta and meta.RarityRank) or {}
	local entries = {}
	for _, o in ipairs((meta and meta.Ores) or {}) do
		if type(o) == "table" and type(o.name) == "string" and o.name ~= "" then
			table.insert(entries, o)
		end
	end
	table.sort(entries, function(a, b)
		local ra, rb = rank[a.rarity] or 0, rank[b.rarity] or 0
		if ra ~= rb then
			return ra > rb
		end
		return a.name < b.name
	end)
	for _, o in ipairs(entries) do
		table.insert(ORE_NAMES, o.name)
	end
end

-- The multi dropdown hands its callback a list on some WindUI builds and a map on
-- others, and which one depends on the build panel.lua fetched, not on this file.
local function ticked(values)
	local set = {}
	for k, v in pairs(values) do
		if type(v) == "string" then
			set[v] = true -- list form: 1 -> "Legendary"
		elseif v then
			set[k] = true -- map form: "Legendary" -> true
		end
	end
	return set
end
assert(ticked({ "Divine", "Exotic" }).Exotic, "the list form ticks its names")
assert(ticked({ Divine = true }).Divine, "the map form ticks its keys")
assert(not ticked({ Divine = false }).Divine, "an unticked key in the map form stays off")

-- A Mega roll comes back as "Mega Nebula Ore" -- a name that is in no dropdown, because
-- the list is built from t.Ores and the Mega variants are a prefix rather than entries.
-- Ticking "Nebula Ore" has to catch its Mega, which is the one you actually wanted.
local function baseNameOf(oreName): string?
	if not (meta and meta.GetBaseOreName) then
		return nil
	end
	local ok, n = pcall(meta.GetBaseOreName, oreName)
	if ok and type(n) == "string" and n ~= "" and n ~= oreName then
		return n
	end
	return nil
end

local function rarityOf(oreName): string?
	if not (meta and meta.GetOre) then
		return nil
	end
	local ok, entry = pcall(meta.GetOre, oreName)
	if ok and type(entry) == "table" and type(entry.rarity) == "string" then
		return entry.rarity
	end
	return nil
end

-- farm ------------------------------------------------------------------------
-- Loop threads never write to the panel. An executor hands a RESUMED thread back with
-- reduced capability, so the first status write lands and every one after a task.wait
-- throws "lacking capability Plugin" -- the window lives in the hidden GUI, which is
-- the part that needs it. The panel drains this from a Heartbeat instead, which the
-- engine calls with our own identity.
local pending, pendingQuiet = nil, false

-- Something worth a console line: an event, a refusal, a decision.
local function post(msg)
	pending, pendingQuiet = msg, false
end

-- Panel only, never printed. For anything a loop says on every pass -- a countdown, a
-- "still waiting" -- where the panel wants it live but F9 does not want it once a
-- second forever. Console spam is not free: the log grows without bound and the client
-- hitches on it, which reads as the script lagging the game.
local function status(msg)
	pending, pendingQuiet = msg, true
end

-- crates ----------------------------------------------------------------------
local crates = { on = false, gen = 0, min = 1, sold = 0, smelt = false }

-- Pick up, then sell. Split so a run that arrives already carrying (a respawn, a
-- previous run cut off half way) finishes the job instead of standing on a full crate
-- maker pressing at nothing.
local function sellRun()
	-- `fresh` is the whole reason the furnace leg is safe. Ore crates and metal crates
	-- ride in the SAME CarryingCrates/CarriedValueCents state, so a run that starts
	-- already carrying cannot tell which it is holding -- and walking metal back into
	-- the furnace is not something to find out by trying. Only crates this run picked
	-- up go to the furnace; anything inherited goes straight to the seller.
	local fresh = false

	if not carrying() then
		step("crates / pickup")
		local p = pickupPrompt()
		if not goTo(p) then
			return post("could not reach the crate maker")
		end
		local got = press(p, carrying)
		if got == nil then
			return post("crate maker prompt not streamed in yet")
		elseif got == false then
			return post("pickup refused -- crates may have been taken already")
		end
		fresh = true
	end

	if fresh and crates.smelt then
		if not furnaceOwned() then
			post("no furnace on this base -- selling raw")
		else
			step("crates / furnace")
			local place = furnacePrompt("PlaceCratesPrompt")
			if goTo(place) and press(place, function()
				return not carrying()
			end) then
				-- The press loop IS the wait for the smelt: firing at a prompt the
				-- furnace has not armed yet costs nothing, and the moment it arms, the
				-- next fire lands. A fixed sleep would either be too short or waste the
				-- difference on every single load.
				step("crates / metal")
				local pick = furnacePrompt("PickUpCratesPrompt")
				if goTo(pick) and press(pick, carrying, FURNACE_WAIT) then
					post(("smelted -- carrying $%d of metal"):format(carriedValue()))
				else
					post("the furnace took the crates but the metal never came")
					return -- nothing in hand; next pass starts clean rather than
					-- pressing at a seller with empty arms
				end
			else
				post("the furnace would not take the crates -- selling raw")
			end
		end
	end

	step("crates / sell")
	local s = sellPrompt()
	if not goTo(s) then
		return post("could not reach the seller table")
	end
	-- Read the worth BEFORE the press: selling zeroes CarriedValueCents, so asking
	-- afterwards always reports $0 -- which is what the first run of this printed.
	local worth = carriedValue()
	local sold = press(s, function()
		return not carrying()
	end)
	if sold then
		crates.sold += 1
		post(("sold a load for $%d (%d so far)"):format(worth, crates.sold))
	else
		post("the seller table did not take it")
	end
end

local function setCrates(on)
	crates.on = on
	crates.gen += 1
	local mine = crates.gen
	if not on then
		return post("crate hauling off")
	end
	task.spawn(function()
		refreshState()
		while crates.on and crates.gen == mine do
			if carrying() or crateCount() >= crates.min then
				claim(sellRun)
				refreshState()
			else
				step("crates / waiting")
				status(("waiting for crates (%d of %d)"):format(crateCount(), crates.min))
			end
			task.wait(IDLE)
		end
	end)
end

-- auto buy --------------------------------------------------------------------
-- No movement and no claim: this is one FireServer, so it runs flat out alongside
-- whatever the character happens to be doing.
local buyer = { on = false, bought = 0, strikes = 0, until_ = 0, blind = 0 }
-- Declared up here rather than in the tunnels section below, because the purchase
-- handler sets its `dirty` flag and is built before it.
local equipper = { on = false, gems = false, gen = 0, dirty = false }

-- price: the server hands `seedCost` back on the roll event, right beside the ore it
-- rolled. The startup sweep has only the prompt's attributes, so it falls back to the
-- metadata table for the same number.
local function priceOf(oreName, given)
	local n = tonumber(given)
	if n then
		return n
	end
	if meta and meta.GetSeedCost then
		local ok, cost = pcall(meta.GetSeedCost, oreName)
		if ok then
			return tonumber(cost)
		end
	end
	return nil
end

-- The one place the two lists are read. Auto Buy and Auto Roll's stop condition both
-- go through it, so "what counts as a match" cannot drift between the thing that buys
-- an ore and the thing that stops for one.
-- Returns whether it matched, plus the rarity for the message -- rarity is allowed to
-- be nil: a named ore the metadata cannot rank is still an ore you ticked by name.
local function matches(oreName): (boolean, string?)
	if type(oreName) ~= "string" or oreName == "" then
		return false, nil
	end
	local rarity = rarityOf(oreName)
	local base = baseNameOf(oreName)
	local byRarity = rarity ~= nil and wanted[rarity] == true
	local byName = wantedOres[oreName] == true or (base ~= nil and wantedOres[base] == true)
	return byRarity or byName, rarity
end

local function anythingTicked()
	return next(wanted) ~= nil or next(wantedOres) ~= nil
end

local function buy(pedestalName, oreName, seedCost)
	if not buyer.on or os.clock() < buyer.until_ then
		return
	end
	if type(pedestalName) ~= "string" or type(oreName) ~= "string" then
		return
	end
	if oreName == "" then
		return -- an empty pedestal: rolled, nothing on it yet
	end
	local hit, rarity = matches(oreName)
	if not hit then
		return
	end

	-- Do NOT fire a purchase you cannot pay for. The server does not answer that with
	-- an error, it answers it with a Robux prompt -- and on a loop that reopens the
	-- prompt forever. Both halves have to be readable to skip safely: an unknown price
	-- or an unreadable balance means we do not know, and not knowing is a reason to
	-- hold off rather than to gamble a purchase dialog.
	local have, cost = money(), priceOf(oreName, seedCost)
	if not have or not cost then
		buyer.blind += 1
		if buyer.blind <= 1 then
			post("cannot read your balance or the ore's price -- holding off, no purchases")
		end
		return
	end
	buyer.blind = 0
	if have < cost then
		post(("skipping " .. oreName .. " -- $%d, you have $%d"):format(cost, have))
		return
	end

	pcall(function()
		RollerPurchaseEvent:FireServer(pedestalName, oreName)
	end)
	post("buying " .. oreName .. " (" .. (rarity or "unranked") .. ")")
end

table.insert(
	conns,
	RollerPurchaseEvent.OnClientEvent:Connect(function(reply)
		if type(reply) ~= "table" then
			return
		end
		if reply.success == true then
			buyer.bought += 1
			buyer.strikes = 0
			equipper.dirty = true -- a new ore is the only thing that moves "best"
			post(("bought %s (%d total)"):format(tostring(reply.oreName), buyer.bought))
		else
			-- No reason field on the wire, and the usual one is "broke" -- which the
			-- crate loop fixes on its own -- so this waits rather than switching off.
			buyer.strikes += 1
			if buyer.strikes >= BUY_STRIKES then
				buyer.until_ = os.clock() + BUY_BACKOFF
				buyer.strikes = 0
				post(("purchases refused %dx -- pausing auto buy %ds (out of money?)"):format(BUY_STRIKES, BUY_BACKOFF))
			end
		end
	end)
)

-- Whatever is already sat on the pedestals when you switch the toggle on. After that
-- the roll event feeds the buyer directly and nothing here scans anything.
local function sweepPedestals()
	local base = myBase()
	local peds = base and base:FindFirstChild("OrePedestals")
	if not peds then
		return
	end
	for _, ped in ipairs(peds:GetChildren()) do
		local disp = ped:FindFirstChild("LocalRollingOreDisplay")
		local p = disp and disp:FindFirstChildWhichIsA("ProximityPrompt", true)
		if p and disp:GetAttribute("PurchasePromptReady") == true then
			buy(p:GetAttribute("PedestalName"), p:GetAttribute("OreName"))
			task.wait(BUY_GAP)
		end
	end
end

-- What is already sat on the pedestals, looked at but not touched. "Roll until"
-- refuses to start when the thing you are waiting for is already there: the first pull
-- would overwrite it, silently, which is the one outcome the feature exists to prevent.
local function matchAlreadyOnPedestals(): string?
	local base = myBase()
	local peds = base and base:FindFirstChild("OrePedestals")
	if not peds then
		return nil
	end
	for _, ped in ipairs(peds:GetChildren()) do
		local disp = ped:FindFirstChild("LocalRollingOreDisplay")
		local p = disp and disp:FindFirstChildWhichIsA("ProximityPrompt", true)
		if p and disp:GetAttribute("PurchasePromptReady") == true then
			local ore = p:GetAttribute("OreName")
			local hit, rarity = matches(ore)
			if hit then
				return ("%s (%s) on %s"):format(
					tostring(ore),
					rarity or "unranked",
					tostring(p:GetAttribute("PedestalName"))
				)
			end
		end
	end
	return nil
end

-- roll ------------------------------------------------------------------------
-- rollReady is the server's own word for it. The roll event arrives twice per pull:
-- once with rollUnlocked ~= true carrying the results (the roller is busy playing the
-- reveal) and once with rollUnlocked == true when it is free again. Waiting on that
-- beats any interval this script could pick, and it absorbs a cooldown for free.
local roller = { on = false, gen = 0, pulls = 0, strikes = 0 }
local rollReady = true
-- "Roll until": with Auto Buy OFF, the same two lists stop the roller instead of
-- buying from it. Set by the roll event, read and cleared by the loop -- the handler
-- must not switch the toggle off itself, because it runs on the remote's thread and
-- the panel lives in the hidden GUI.
local stopOn = nil
local rollToggle -- assigned by the panel; the loop switches it off when it gives up

table.insert(
	conns,
	RollerRollEvent.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		local base = myBase()
		if base and payload.baseName ~= base.Name then
			return -- someone else's roller
		end
		if payload.rollUnlocked == true then
			rollReady = true
			return
		end
		rollReady = false
		-- One pull rolls every pedestal, and the server names each one it filled.
		task.spawn(function()
			for _, r in ipairs(payload.results or {}) do
				if buyer.on then
					buy(r.pedestalName, r.oreName, r.seedCost)
					task.wait(BUY_GAP)
				elseif roller.on and anythingTicked() and not stopOn then
					-- Auto Buy is off, so a match is not something to purchase, it is
					-- something to stop for -- and it sits on its pedestal until the
					-- next pull, which is the pull this prevents.
					local hit, rarity = matches(r.oreName)
					if hit then
						stopOn = ("%s (%s) on %s"):format(
							tostring(r.oreName),
							rarity or "unranked",
							tostring(r.pedestalName)
						)
					end
				end
			end
		end)
	end)
)

local function pullLever()
	step("roll / travel")
	local p = leverPrompt()
	if not goTo(p, ROLL_PARK) then
		return post("could not reach the lever")
	end

	step("roll / press")
	-- The confirm is the roller going BUSY, not the roll finishing: that is the first
	-- thing the server says back, and waiting for the reveal instead would hold the
	-- character hostage through the whole cutscene.
	local pulled = press(p, function()
		return not rollReady
	end)
	if pulled == nil then
		return post("lever prompt not streamed in yet")
	elseif pulled == false then
		roller.strikes += 1
		post(("lever ignored (%d/%d)"):format(roller.strikes, ROLL_STRIKES))
		return
	end
	roller.strikes = 0
	roller.pulls += 1
	post(("pulled the lever (%d)"):format(roller.pulls))
end

local function setRoll(on)
	roller.on = on
	roller.gen += 1
	local mine = roller.gen
	if not on then
		return post("auto roll off")
	end
	roller.strikes = 0
	stopOn = nil

	-- Auto Buy off with something ticked means "roll until one of these shows up". If
	-- one already has, starting would destroy it on the first pull.
	if not buyer.on and anythingTicked() then
		local already = matchAlreadyOnPedestals()
		if already then
			roller.on = false
			pcall(function()
				rollToggle:Set(false, false)
			end)
			return post("not rolling -- " .. already .. " is already sat there")
		end
	end

	task.spawn(function()
		while roller.on and roller.gen == mine do
			-- Checked before the pull, never after: the ore we stopped for is sat on a
			-- pedestal and the next pull is what would overwrite it.
			if stopOn then
				local what = stopOn
				stopOn = nil
				if roller.gen == mine then
					roller.on = false
					pcall(function()
						rollToggle:Set(false, false)
					end)
				end
				post("stopped rolling: " .. what)
				break
			end

			if roller.strikes >= ROLL_STRIKES then
				post("the lever is not answering -- auto roll stopped")
				if roller.gen == mine then -- only this generation may flip the switch
					roller.on = false
					-- and the switch has to LOOK off too: a lit toggle over a dead
					-- loop is the bug report that never gets filed. pcall'd because
					-- this is a resumed thread writing to the hidden GUI.
					pcall(function()
						rollToggle:Set(false, false)
					end)
				end
				break
			end
			if rollReady then
				claim(pullLever)
			else
				-- The reveal is playing. The character is free -- the claim was
				-- released the moment the roller went busy -- so the crate loop can
				-- have it while we wait.
				step("roll / waiting for the reveal")
				local t0 = os.clock()
				while not rollReady and roller.on and roller.gen == mine and os.clock() - t0 < ROLL_WAIT do
					task.wait(0.2)
				end
				if not rollReady then
					rollReady = true -- the unlock never came; try a pull anyway
				end
			end
			task.wait(0.2)
		end
	end)
end

-- tunnels ---------------------------------------------------------------------
-- "EquipBest" is the game's own command: the server picks the best ore you own for
-- that tunnel, so there is nothing to rank here and nothing to get wrong. No movement
-- and no prompts, which means no claim -- this runs flat out beside everything else.

-- pcall does NOT bound a yield. InvokeServer has no timeout, so one handler that
-- errors or never returns parks this thread forever -- and a parked sweep looks
-- exactly like a finished one: no error, no log line, toggle still lit. There is
-- nothing to catch, so stop waiting instead. The abandoned thread is harmless.
local function callTimed(fn, timeout)
	local done, ok = false, false
	task.spawn(function()
		ok = pcall(fn)
		done = true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < timeout do
		task.wait(0.05)
	end
	return done and ok
end

-- Both commands take (base, 1, "Tunnel1", cmd) and the literals are VESTIGIAL: the
-- game's own button hardcodes floor 1 / Tunnel1 and the server does the whole base,
-- handing back result.equipped -- a list of every tunnel it touched. So this is one
-- call, not one per tunnel.
local function tunnelCall(cmd)
	local base = myBase()
	if not base then
		return nil
	end
	local reply
	local ok = callTimed(function()
		reply = BaseBuildTunnelAction:InvokeServer(base.Name, 1, "Tunnel1", cmd)
	end, EQUIP_TIMEOUT)
	if not ok or type(reply) ~= "table" then
		return nil
	end
	return reply
end

local function equipBest()
	-- The game's own client refuses before the tutorial is done, and the server will
	-- too; checking here turns a silent refusal into a line you can read.
	if player:GetAttribute("TutorialComplete") ~= true then
		return post("equip best: the game wants the tutorial finished first")
	end
	local reply = tunnelCall("EquipBest")
	if not reply then
		return post("equip best: no answer from the server")
	end
	if reply.success ~= true then
		return post("equip best refused: " .. tostring(reply.result))
	end
	local list = type(reply.result) == "table" and reply.result.equipped or nil
	post(("equipped best ore in %d tunnels"):format(type(list) == "table" and #list or 0))
end

-- Gems are spent, so this reads the count first -- exactly as the game's own button
-- does, which hides itself at zero rather than firing. The reply carries what is left,
-- so the loop can stop asking once the bag is empty instead of calling forever.
local function applyGems()
	local have = tonumber(player:GetAttribute("GrowthGemInventoryCount")) or 0
	if have <= 0 then
		return false -- nothing to spend; not an error, just nothing to do
	end
	local reply = tunnelCall("ApplyBestGrowthGems")
	if not reply then
		post("apply gems: no answer from the server")
		return false
	end
	if reply.success ~= true then
		post("apply gems refused: " .. tostring(reply.result))
		return false
	end
	local left = type(reply.result) == "table" and tonumber(reply.result.remainingGemCount) or nil
	post(("applied growth gems (%s left)"):format(left and tostring(left) or "?"))
	return true
end

-- One loop for both, because they are two calls against the same base and the order
-- between them matters: equip the ore FIRST, then gem it. Gems boost whatever is
-- currently in the tunnel, so applying them before the swap boosts the ore that is
-- about to be replaced.
local function runTunnels()
	equipper.gen += 1
	local mine = equipper.gen
	if not (equipper.on or equipper.gems) then
		return
	end
	task.spawn(function()
		local function alive()
			return (equipper.on or equipper.gems) and equipper.gen == mine
		end
		while alive() do
			equipper.dirty = false
			if equipper.on then
				step("tunnels / equip best")
				equipBest()
			end
			if equipper.gems and alive() then
				step("tunnels / gems")
				applyGems()
			end
			-- Wake early on a purchase rather than sitting out the rest of the timer:
			-- the ore you just bought is the only thing that moves "best".
			step("tunnels / waiting")
			local t0 = os.clock()
			while alive() and not equipper.dirty and os.clock() - t0 < EQUIP_EVERY do
				task.wait(0.5)
			end
		end
	end)
end

-- gui ------------------------------------------------------------------------
-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a
-- restyle is one file and not thirty. Fetched here rather than installed by the loader,
-- so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Drill Ores", -- fallback until the live name lands
	folder = "DrillOres", -- unchanged: renaming it orphans configs already saved in-game
	size = UDim2.fromOffset(460, 440),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })

-- Rolling and buying share a card because they are one feature with two halves: the
-- lever fills the pedestals, the filter decides what comes off them. Splitting them
-- put the rarity list a card away from the toggle it governs.
local Roll =
	Tab:Section({ Title = "Roller", Icon = "solar:dice-bold", Box = true, BoxBorder = true, Opened = true })
local Crate = Tab:Section({ Title = "Crates", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })
local Tunnel =
	Tab:Section({ Title = "Tunnels", Icon = "solar:pickaxe-bold", Box = true, BoxBorder = true, Opened = true })

rollToggle = Roll:Toggle({
	Title = "Auto Roll",
	Desc = "Pulls the lever on repeat. With Auto Buy off, stops on the first ticked match.",
	Value = false,
	Callback = setRoll,
})

local buyToggle
buyToggle = Roll:Toggle({
	Title = "Auto Buy",
	Desc = "Buys the rolled ores whose rarity you ticked, if you can afford them",
	Value = false,
	Callback = function(v)
		if v and not anythingTicked() then
			-- An empty set filters everything out, which reads on-screen exactly like
			-- a broken toggle. Refuse, and say so AFTER the Set -- the off branch runs
			-- a frame later and would otherwise overwrite the reason.
			pcall(function()
				buyToggle:Set(false, false)
			end)
			buyer.on = false
			return post("tick a rarity or a named ore first")
		end
		buyer.on = v
		if v then
			buyer.strikes, buyer.until_, buyer.blind = 0, 0, 0
			post("auto buy on")
			task.spawn(sweepPedestals) -- whatever is already sat on the pedestals
		else
			post("auto buy off")
		end
	end,
})

-- table.clear, never `= {}`: the buy handler holds both sets as upvalues, so replacing
-- one leaves it reading the copy nobody ticks any more.
local function retick(into, values)
	local set = ticked(values)
	table.clear(into)
	for k in pairs(set) do
		into[k] = true
	end
end

local rarityDrop = Roll:Dropdown({
	Title = "Rarities to buy",
	Desc = "Anything unticked is left on its pedestal and overwritten by the next pull",
	Values = RARITIES,
	Value = {},
	Multi = true,
	AllowNone = true,
	Callback = function(values)
		retick(wanted, values)
	end,
})

local oreDrop = Roll:Dropdown({
	Title = "Ores to buy",
	Desc = "Named ores, bought whatever their rarity. Adds to the rarities above.",
	Values = ORE_NAMES,
	Value = {},
	Multi = true,
	AllowNone = true,
	-- WindUI defaults this off, and 160-odd names without one is a scroll, not a picker
	SearchBarEnabled = true,
	Callback = function(values)
		retick(wantedOres, values)
	end,
})

-- One button rather than two: empty means "tick everything", anything else means
-- "clear it", so the next press always undoes the last. :Select() writes the ticks and
-- redraws but fires nothing, which is why the set is updated by hand alongside it.
Roll:Button({
	Title = "All / None rarities",
	Desc = "Tick every rarity, or clear them",
	Callback = function()
		local picked = next(wanted) == nil and RARITIES or {}
		pcall(function()
			rarityDrop:Select(picked)
		end)
		retick(wanted, picked)
		post(next(wanted) == nil and "no rarities ticked" or ("buying %d rarities"):format(#RARITIES))
	end,
})

-- No "all ores" counterpart: ticking all 160-odd is what the rarity list already does,
-- and unpicking them one at a time is the thing worth a button.
Roll:Button({
	Title = "Clear ores",
	Desc = "Unticks the named ores, leaving the rarities alone",
	Callback = function()
		pcall(function()
			oreDrop:Select({})
		end)
		table.clear(wantedOres)
		post("named ores cleared")
	end,
})

Crate:Toggle({
	Title = "Auto Sell Crates",
	Desc = "Hops to the crate maker, picks up everything waiting, hops to the seller",
	Value = false,
	Callback = setCrates,
})

Crate:Toggle({
	Title = "Send to Furnace",
	Desc = "Smelt each load into metal crates before selling. Falls back to raw if it can't.",
	Value = false,
	Callback = function(v)
		crates.smelt = v
		if v and not furnaceOwned() then
			post("furnace route on -- but this base has no furnace yet, so loads sell raw")
		else
			post(v and "furnace route on" or "selling raw")
		end
	end,
})

Crate:Input({
	Title = "Sell at",
	Desc = "Crates waiting before a round trip is worth making",
	Value = tostring(crates.min),
	Placeholder = "1",
	Callback = function(text)
		local n = tonumber((text or ""):match("%d+"))
		if n and n > 0 then
			crates.min = n
			post(("selling once %d crates are waiting"):format(n))
		end
	end,
})

Tunnel:Toggle({
	Title = "Auto Equip Best Ore",
	Desc = "The game's own EquipBest, base-wide. Re-runs on a timer and on each buy.",
	Value = false,
	Callback = function(v)
		equipper.on = v
		runTunnels()
		post(v and "auto equip on" or "auto equip off")
	end,
})

Tunnel:Toggle({
	Title = "Auto Apply Growth Gems",
	Desc = "Spends growth gems on the equipped ore. Skips itself when you have none left.",
	Value = false,
	Callback = function(v)
		equipper.gems = v
		runTunnels()
		if v then
			local have = tonumber(player:GetAttribute("GrowthGemInventoryCount")) or 0
			post(have > 0 and ("auto gems on (%d in the bag)"):format(have) or "auto gems on -- but you have none")
		else
			post("auto gems off")
		end
	end,
})

local line = Tab:Paragraph({ Title = "Status", Desc = "idle" })

-- Drains whatever a loop thread last left. pcall'd anyway: if even this cannot write
-- the panel, the run carries on with the status going nowhere rather than taking the
-- loop down with it. Held in an upvalue and disconnected by stopAll -- it outlives
-- Window:Destroy otherwise, re-pcalling into a destroyed row every frame.
local drain
local lastPrinted
drain = RunService.Heartbeat:Connect(function()
	if pending == nil then
		return
	end
	local msg, quiet = pending, pendingQuiet
	pending = nil
	pcall(function()
		line:SetDesc(msg)
	end)
	-- Belt and braces on top of status(): even a post() that repeats itself only
	-- reaches the console once.
	if not quiet and msg ~= lastPrinted then
		lastPrinted = msg
		print("[drill]", msg)
	end
end)

refreshState()
post(("ready -- %d crates waiting, $%s banked"):format(crateCount(), tostring(state.StoredMoney or "?")))

-- close ----------------------------------------------------------------------
local function stopAll()
	running = false
	crates.on, roller.on, buyer.on = false, false, false
	equipper.on, equipper.gems = false, false
	crates.gen += 1
	roller.gen += 1
	equipper.gen += 1
	-- The prompts are the game's to hide; leaving them forced on strands the player
	-- with a crate maker that offers to be picked up from across the room.
	restoreGates()
	for _, c in ipairs(conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(conns)
	pcall(function()
		drain:Disconnect()
	end)
end

Window:OnDestroy(function()
	stopAll()
	getgenv().drillOresStop = nil
end)

getgenv().drillOresStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().drillOresStop = nil
end
