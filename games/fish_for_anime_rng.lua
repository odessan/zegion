--[[ Fish an Anime -- auto fishing, with the click half spammed instead of paced

     AUTO FISH : cast -> wait for the hook -> spam clicks -> recast, forever. It drives
                 the same three remotes the game's own Auto Fish drives, so none of this
                 needs the 500-gem unlock:

                     FishingRequestStart(pondPart, targetPos)
                        -> FishingState "Started"    the server rolled a catch time
                        -> FishingState "Hooked"     from here, clicks count
                     FishingClick()  x requiredClicks
                        -> FishingState "Completed"  rewards land -- recast

                 Half a cast is server-timed and no client shortens it: the wait for the
                 hook is PondCatchTime, rolled per cast (5-10s on the starter rod, 1-7s
                 on the good ones, capped at 12). The click half IS ours. The game paces
                 its own auto-clicker at 0.274s a click, so the starter rod's 11 clicks
                 is ~3s of standing there; per frame it's ~0.2s.

                 Measured on a Ruby Rod, though, the server sends requiredClicks=1 and
                 Hooked -> Completed takes 0.07s -- so on a rod past the first few, the
                 click half has already collapsed and what's left over the game's own
                 Auto Fish is its 0.2s restart delay and not paying 500 gems for it.
                 The wait is the cycle; see SPEED.

                 There is no instant catch to find -- Quick Fish, the button that
                 actually shortens the wait, is a 30k-gem flag the SERVER owns, and
                 casting twice to run two waits at once is answered with Denied/BUSY:
                 one fishing session per player, confirmed by fish_probe.lua.

     SPEED     : the hook wait is PondCatchTime divided by your catch-speed multiplier,
                 and that multiplier is the only lever on it. Nothing client-side moves
                 it -- the attributes it's built from are server-set and don't replicate
                 upward -- but it's farmable: the Faster Catch upgrade (UpgFasterCatch,
                 store slot T3O3) is +200% for cash, and each sacrifice is a permanent
                 +1.5x. Both beat the Quick Fish purchase, which is +1.0x.

     POND      : ponds are the PONDAREA* parts in workspace.Scripted.PondAreas, and
                 PONDAREA1 is five of them, one per island. "Nearest" picks by distance
                 to the pond SURFACE, which is the same measure the server's TOO_FAR
                 check uses. PONDAREA2 wants a rod of Strength 2000 and answers TOO_WEAK
                 below that, so it's a pick and not the default.

                 You have to be within 50 studs of the pond to cast, and moving 20 studs
                 mid-cast makes the game's own client cancel it -- so this stands still
                 and fishes from wherever you are. GO TO POND is a button rather than
                 something the loop does behind you: the pond parts are volumes, TPing
                 into one drops you wherever the water's floor happens to be, and on the
                 island ponds that floor is 200 studs up.

     SELL      : a full backpack answers every cast with MAX_BACKPACK, which is the one
                 thing that ends a long run. JUNK RARITIES is the list that fixes it, and
                 it drives whichever of the game's two sell paths you actually have:

                     BackpackSellRarityRequest(rarity)   free. Sells what you're holding
                                                         of that rarity, right now.
                     RarityAutoSellSet(rarity, true)     needs the SELL ALL GAMEPASS
                                                         (GP_SellAll). Standing order --
                                                         the server keeps selling with
                                                         the game closed.

                 Without the pass the second one is refused on every row, so the ticks
                 run the first: a sweep between casts every 30s, and again the moment the
                 server says MAX_BACKPACK -- which turns the one fatal refusal into a
                 pause. With the pass, both. SELLING says which is carrying it, and names
                 anything the server turned down.

                 The offered list is read off the game's own picker (Common..Ancient) and
                 God, Omniscient and Transcendent are never in it -- SellGuiClient
                 answers those with "Cannot be auto sold!" and fires nothing.

                 Ticking sells nothing by itself: the sweep runs while the farm does, or
                 when you press SELL TICKED NOW. SELL ALL NOW is the game's own sell-all
                 and ignores the ticks entirely.

     Executor only: the UI is WindUI, pulled in with HttpGet, which Studio blocks.
     The minus button rolls the panel up to a bare Zegion pill -- click it to come back.
     RightControl does the same from the keyboard, and RightAlt hides the window
     outright. Fishing keeps running under either.
     Stop for good: getgenv().fishAnimeStop() ]]

-- config ---------------------------------------------------------------------
-- Seconds between FishingClick calls once hooked. 0 is task.wait(), a click a frame,
-- which is what makes the catch instant -- the server counts clicks and nothing here
-- was rate-limited in testing. Raise it if a future update starts dropping them; the
-- Click delay slider is the same number, live.
local CLICK_STEP = 0
-- Between a cast finishing and the next one going out. 0.5 is the game's own floor
-- (tryStartFishingAt refuses a start inside 0.5s of the last), kept because a start the
-- server refuses costs a whole round trip anyway. Drop it if yours accepts faster.
local CAST_GAP = 0.5
local DENY_WAIT = 1 -- after a refused cast, before trying again
-- No state change for this long means the cast is lost -- the server dropped it, or a
-- Completed never arrived. Cancel and recast rather than sit there forever. Well clear
-- of the worst real case: a 12s wait plus a God catch's reveal.
local STUCK = 35
-- Its own, much shorter timeout: a start the server answers at all answers immediately,
-- so 35s of silence between firing and "Started" would just read as a dead panel.
local CAST_TIMEOUT = 3
-- Switching off with a fish already hooked keeps clicking for up to this long. The
-- server rolled that catch; cancelling it to save a second is the wrong trade.
local FINISH = 3
local MAX_RANGE = 50 -- Constants.Fishing.Distances.MaxStartDistance; read live when it's there
local STREAM_TIMEOUT = 3 -- max wait for a region to stream in before TPing anyway
-- Between sweeps of the ticked rarities while fishing. One remote per ticked rarity, so
-- this is not a thing to run every second; the MAX_BACKPACK handler is what catches the
-- backpack filling up between two sweeps anyway.
local SELL_EVERY = 30
local KEY_TOGGLE = Enum.KeyCode.RightControl

-- What SellGUI's rarity pickers offer today, worst first -- which is also the order you'd
-- tick them off in. Deliberately NOT Constants.RarityOrder: that runs on through
-- Transcendent and Exclusive, which no picker in the game has a row for.
--
-- Only the fallback. sellableRarities() reads the picker itself, so a rarity the game
-- adds a button for shows up here without editing this.
local RARITY_FALLBACK = {
	"Common",
	"Uncommon",
	"Rare",
	"Epic",
	"Legendary",
	"Mythical",
	"Cosmic",
	"Secret",
	"Rainbow",
	"Ascended",
	"Divine",
	"Supreme",
	"Celestial",
	"Ancient",
	-- Stops here, like SellRarityPick does. God and Omniscient have rows in the PAID
	-- picker but are in NEVER_SELL, so they'd be refused on either path.
}

-- Every reason FishingState answers a cast with that there's no point retrying on.
local FATAL = {
	NO_ROD = "no fishing rod -- buy one at the shop, then flip this back on",
	TOO_WEAK = "rod too weak for this pond -- PONDAREA2 needs Strength 2000",
	TUTORIAL_LOCK = "finish the tutorial first",
	-- MAX_BACKPACK is deliberately NOT here: it's the one refusal with a way out, and the
	-- sweep is it. Only if that sells nothing does the farm stop.
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

if getgenv and getgenv().fishAnimeStop then
	getgenv().fishAnimeStop() -- re-running must not stack a second window/loop
end

-- The game's own config module, for the two lists that grow with updates: the rarities
-- the sell dropdown offers and the cast range. Fetched rather than copied so a new
-- rarity shows up without editing this file; the fallbacks above cover it not loading.
local Constants
do
	local ok, mod = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Constants", 10))
	end)
	Constants = ok and type(mod) == "table" and mod or nil
	if not Constants then
		warn("[FishAnime] Constants wouldn't load -- using the built-in rarity list")
	end
end

do
	local dist = Constants and Constants.Fishing and Constants.Fishing.Distances
	MAX_RANGE = dist and tonumber(dist.MaxStartDistance) or MAX_RANGE
end

-- world ----------------------------------------------------------------------
local function hrp()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- Point-to-box, the same math the game's distanceFromPointToPondSurface runs: the range
-- check is against the pond's SURFACE, and these parts are big enough that measuring to
-- the centre instead would call a pond you're standing in "too far".
local function boxClamp(pond, pos)
	local o = pond.CFrame:PointToObjectSpace(pos)
	local h = pond.Size * 0.5
	local c = Vector3.new(math.clamp(o.X, -h.X, h.X), math.clamp(o.Y, -h.Y, h.Y), math.clamp(o.Z, -h.Z, h.Z))
	return c, o, h
end

local function pondDist(pos, pond)
	local c, o = boxClamp(pond, pos)
	return (o - c).Magnitude
end

-- Where the bobber goes: the point on the pond's TOP face nearest you, which is what
-- the game passes after raying your mouse at the water. Anywhere inside the part works
-- -- the server takes the pond from the part, not from this -- but casting at the far
-- end of a 300-stud pond looks wrong and reads wrong in the F9 log.
local function pondTarget(pond, from)
	local c, _, h = boxClamp(pond, from)
	return pond.CFrame:PointToWorldSpace(Vector3.new(c.X, h.Y, c.Z))
end

-- A 10-cube at the origin: 5 studs off one face is 5 from the surface, and any point
-- inside the box is 0. Both are what the range check hinges on.
do
	local probe = Instance.new("Part")
	probe.Size = Vector3.new(10, 10, 10)
	probe.CFrame = CFrame.new()
	assert(math.abs(pondDist(Vector3.new(10, 0, 0), probe) - 5) < 1e-3, "pondDist: outside the box")
	assert(pondDist(Vector3.new(1, 1, 1), probe) == 0, "pondDist: inside is zero")
	assert((pondTarget(probe, Vector3.new(0, 99, 0)) - Vector3.new(0, 5, 0)).Magnitude < 1e-3, "pondTarget: top face")
	probe:Destroy()
end

-- Ponds are BaseParts named for a key of Constants.Fishing.Ponds. Matching the PONDAREA
-- prefix rather than that table on purpose: it holds PONDAREA7..12 (the guaranteed-God,
-- -Rainbow, -Secret ponds) which are config with no part in the map, and a name-shaped
-- match picks up a pond a future update adds without needing this list. Anchored so the
-- TPPONDAREA* travel pads next door don't come back as ponds.
local function ponds()
	local out = {}
	local scripted = workspace:FindFirstChild("Scripted")
	local folder = scripted and scripted:FindFirstChild("PondAreas")
	-- ponytail: the fallback walks all of workspace, which is slow and only runs if the
	-- folder was renamed. Cache it if that ever becomes the normal path.
	for _, p in ipairs(folder and folder:GetChildren() or workspace:GetDescendants()) do
		if p:IsA("BasePart") and p.Name:match("^PONDAREA") then
			table.insert(out, p)
		end
	end
	return out
end

-- A Tool with the IsFishingRod attribute, equipped or not -- the same two passes
-- getHeldRod makes, name-matched against the rod table second so an update that stops
-- setting the attribute still finds one. Equips it if it's sitting in the backpack,
-- because the server answers a cast without one with NO_ROD.
local function rod()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not (char and hum) then
		return nil
	end
	local rods = Constants and Constants.Fishing and Constants.Fishing.Rods or {}
	for _, where in ipairs({ char, player:FindFirstChildOfClass("Backpack") }) do
		for _, tool in ipairs(where and where:GetChildren() or {}) do
			if tool:IsA("Tool") and (tool:GetAttribute("IsFishingRod") == true or rods[tool.Name]) then
				if tool.Parent ~= char then
					pcall(function()
						hum:EquipTool(tool)
					end)
				end
				return tool
			end
		end
	end
	return nil
end

local function tp(pos)
	pcall(function()
		player:RequestStreamAroundAsync(pos, STREAM_TIMEOUT)
	end)
	local char = player.Character
	if not (char and hrp()) then
		return false
	end
	char:PivotTo(CFrame.new(pos))
	return true
end

-- fishing --------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)

local function remote(name)
	-- Timed, never bare: a name the game renames would otherwise hang the paste on an
	-- infinite yield with nothing on screen to say why.
	local r = Remotes and Remotes:WaitForChild(name, 5)
	if not r then
		warn("[FishAnime] no Remotes." .. name)
	end
	return r
end

local RequestStart = remote("FishingRequestStart")
local Click = remote("FishingClick")
local Cancel = remote("FishingCancel")
local State = remote("FishingState")
local AutoSellSet = remote("RarityAutoSellSet")
local AutoSellGet = remote("RarityAutoSellGetState")
local SellAll = remote("BackpackSellAllRequest")
local SellRarity = remote("BackpackSellRarityRequest")

-- The panel is built below, so the rows the loop writes to are declared here and filled
-- in there. say() no-ops until then, which is what makes the order legal.
local statusRow, catchRow, sellRow, fishToggle
-- The sell section is below this one as well: the loop calls into it whenever the
-- backpack fills, and it needs the remotes opened just above. Forward declared rather
-- than moved up, so each section still reads in one piece.
local sweep, showSell
local running = true

local function say(msg)
	if statusRow then
		statusRow:SetDesc(msg)
	end
end

-- phase is the whole state machine: idle (nothing cast) -> casting (fired, no answer
-- yet) -> waiting (server rolling its catch time) -> hooked (clicks count now) -> idle.
-- Every transition after the cast comes from the server on FishingState, so the loop
-- below only ever reads this; the one exception is the STUCK watchdog.
local phase, phaseAt = "idle", os.clock()
local denied, catches, lastCatch = nil, 0, "nothing yet"
local clickStep, pondChoice = CLICK_STEP, "Nearest"
-- Starts a full interval in the past, so switching the farm on sweeps once up front
-- rather than fishing for 30 seconds into a backpack that was already nearly full.
local lastSweep = os.clock() - SELL_EVERY

local function setPhase(p)
	phase, phaseAt = p, os.clock()
end

local stateConn
if State then
	stateConn = State.OnClientEvent:Connect(function(msg)
		if type(msg) ~= "table" then
			return
		end
		local kind = tostring(msg.kind or "")
		if kind == "Started" then
			setPhase("waiting")
		elseif kind == "Hooked" then
			setPhase("hooked")
		elseif kind == "Denied" then
			-- Held rather than handled here: this runs on the remote's own thread, and
			-- the reasons that need a sell or a stop belong in the loop's pass.
			denied = tostring(msg.reason or "?")
			setPhase("idle")
		elseif kind == "Completed" then
			-- One cast can land several characters -- that's the rod's MultiPullChances
			-- and every extra hook you've unlocked -- so the count is per reward, not
			-- per cast, and the row names all of them.
			local got = {}
			for _, r in ipairs(msg.rewards or {}) do
				if type(r) == "table" then
					table.insert(got, string.format("%s (%s)", tostring(r.name or "?"), tostring(r.rarity or "?")))
				end
			end
			catches += math.max(1, #got)
			lastCatch = #got > 0 and table.concat(got, ", ") or "something the server didn't name"
			if catchRow then
				catchRow:SetDesc(string.format("%d caught -- last: %s", catches, lastCatch))
			end
			setPhase("idle")
		elseif kind == "Stopped" then
			-- COMPLETED arrives here too, a beat after the Completed above; idle is
			-- already idle, so both landing is fine.
			setPhase("idle")
		end
	end)
end

-- Nearest pond, or the one picked in the dropdown -- and PONDAREA1 is five parts, so
-- "PONDAREA1" still means the nearest of those five.
local function pickPond()
	local root = hrp()
	local from = root and root.Position or Vector3.new()
	local best, bestDist
	for _, p in ipairs(ponds()) do
		if pondChoice == "Nearest" or p.Name == pondChoice then
			local d = pondDist(from, p)
			if not bestDist or d < bestDist then
				best, bestDist = p, d
			end
		end
	end
	return best, bestDist
end

-- One turn of the loop. Returns how long to wait before the next one, or nil to ask the
-- caller to switch off -- it must not write the toggle itself, or a pass that outlived
-- its own generation would stop a farm that has since restarted.
local function pass()
	if denied then
		local why = denied
		denied = nil
		if FATAL[why] then
			say(FATAL[why])
			return nil
		end
		if why == "TOO_FAR" then
			-- Not TPd behind your back: see the POND note up top. The next pass
			-- re-measures, so walking over is enough to get going again.
			say("too far from the pond -- walk over, or press Go to pond")
			return DENY_WAIT
		end
		if why == "MAX_BACKPACK" then
			-- The one refusal with a way out. Sweeping nothing means either nothing is
			-- ticked or everything ticked is already gone, and both mean the next cast
			-- is refused for the same reason -- so stop rather than spin.
			local sold = sweep()
			lastSweep = os.clock()
			showSell(nil, sold)
			if sold > 0 then
				say(string.format("backpack was full -- sold %d, carrying on", sold))
				return DENY_WAIT
			end
			say("backpack full and nothing ticked to sell -- pick rarities under Sell")
			return nil
		end
		say("cast refused: " .. why)
		return DENY_WAIT
	end

	if phase == "hooked" then
		Click:FireServer()
		return clickStep
	end

	if phase ~= "idle" then
		-- The server's own timer is running. Nothing to do but watch it: a cast that
		-- never answers is the one case worth acting on.
		if os.clock() - phaseAt > (phase == "casting" and CAST_TIMEOUT or STUCK) then
			pcall(function()
				Cancel:FireServer()
			end)
			setPhase("idle")
			say("cast went nowhere -- cancelled, recasting")
		end
		return 0.1
	end

	if not hrp() then
		say("no character -- waiting for respawn")
		return 0.5
	end
	if not rod() then
		say(FATAL.NO_ROD)
		return nil
	end
	local pond, dist = pickPond()
	if not pond then
		-- Retried rather than fatal: with streaming on, a pond you're walking towards
		-- hasn't replicated yet, and that's indistinguishable from there being none.
		say("no pond in range yet -- walk towards one")
		return DENY_WAIT
	end
	if dist > MAX_RANGE then
		say(string.format("%.0f studs from %s -- the server only casts inside %d", dist, pond.Name, MAX_RANGE))
		return DENY_WAIT
	end

	-- Between casts, never mid-cast: a sell is a round trip per ticked rarity, and doing
	-- it while a fish is on the hook is how you drop clicks. With the gamepass the server
	-- is already selling these as they land, so this only ever finds a leftover.
	if os.clock() - lastSweep > SELL_EVERY then
		lastSweep = os.clock()
		local sold = sweep()
		if sold > 0 then
			showSell(nil, sold)
		end
	end

	setPhase("casting")
	RequestStart:FireServer(pond, pondTarget(pond, hrp().Position))
	say(string.format("fishing %s -- %d caught", pond.Name, catches))
	return CAST_GAP
end

local fishing, fishGen = false, 0

local function startFishing()
	fishing = true
	fishGen += 1
	local mine = fishGen -- off-then-on shouldn't leave two loops firing at one session
	task.spawn(function()
		while fishing and running and fishGen == mine do
			local ok, hold = pcall(pass)
			if not ok then
				warn("[FishAnime]", hold)
				say("crashed -- see console (F9)")
				break
			end
			if hold == nil then
				break -- the pass asked to stop; the tail below owns the switch
			end
			task.wait(hold)
		end
		-- Only the current generation owns the switch: an old thread finishing must not
		-- flip off a farm that has already been restarted.
		if fishGen ~= mine then
			return
		end
		fishing = false
		-- A fish already on the hook is worth the extra second: the server rolled that
		-- catch, and cancelling it to switch off a beat sooner throws it away. The
		-- generation is re-checked because this window is long enough to switch back on
		-- inside, and the restarted loop owns the switch from that moment.
		if phase == "hooked" and Click then
			local deadline = os.clock() + FINISH
			repeat
				Click:FireServer()
				task.wait(clickStep)
			until phase ~= "hooked" or os.clock() > deadline or fishGen ~= mine
		end
		if fishGen ~= mine then
			return
		end
		-- A cast left mid-flight would otherwise hold the rod out until the server times
		-- it out on its own.
		if phase ~= "idle" and Cancel then
			pcall(function()
				Cancel:FireServer()
			end)
			setPhase("idle")
		end
		if fishToggle then
			fishToggle:Set(false)
		end
	end)
end

-- sell -----------------------------------------------------------------------
-- WindUI hands a multi-select callback its ticks in EITHER form depending on the row --
-- {1 = "Common"} or {Common = true} -- so reading it with ipairs alone gets you an empty
-- loop and a dropdown that visibly ticks while nothing is sent. Same helper the other
-- scripts in here use, asserts and all.
local function ticked(values)
	local set = {}
	for k, v in pairs(values) do
		if type(v) == "string" then
			set[v] = true -- list form: 1 -> "Common"
		elseif v then
			set[k] = true -- map form: "Common" -> true
		end
	end
	return set
end
assert(ticked({ "Common", "Rare" }).Rare, "the list form ticks its names")
assert(ticked({ Common = true }).Common, "the map form ticks its keys")
assert(not ticked({ Common = false }).Common, "an unticked key in the map form stays off")

-- The rarities either sell path will take, read off the game's own pickers so one added
-- later needs no edit here. RarityOrder is the wrong list to offer -- see RARITY_FALLBACK
-- -- and NEVER_SELL is the game's own refusal list on top of that: SellGuiClient answers
-- a click on one of these with "<rarity> Cannot be auto sold!" and never fires anything.
local NEVER_SELL = { God = true, Omniscient = true, Transcendent = true }

local function sellableRarities()
	local gui = player:FindFirstChildOfClass("PlayerGui")
	local main = gui and gui:FindFirstChild("MainGui")
	local sell = main and main:FindFirstChild("SellGUI")
	-- SellRarityPick is the free path's own picker and already stops at Ancient;
	-- RarityAutoSell is the paid one and goes two rows further, into NEVER_SELL.
	local picker = sell and (sell:FindFirstChild("SellRarityPick") or sell:FindFirstChild("RarityAutoSell"))
	if not picker then
		return RARITY_FALLBACK
	end
	local have = {}
	for _, row in ipairs(picker:GetChildren()) do
		if row:IsA("GuiButton") and not NEVER_SELL[row.Name] then
			have[row.Name] = true
		end
	end
	-- Walked in RarityOrder rather than in GetChildren order: the picker is a scrolling
	-- frame and its children come back in whatever order it was built, which is not
	-- worst-first and is not the order you want to read down a dropdown.
	local out = {}
	for _, r in ipairs(Constants and Constants.RarityOrder or RARITY_FALLBACK) do
		if have[r] then
			table.insert(out, r)
		end
	end
	return #out > 0 and out or RARITY_FALLBACK
end

local RARITIES = sellableRarities()

-- The standing order (RarityAutoSellSet) is GAMEPASS GATED -- SellGuiClient won't even
-- fire it without GP_SellAll, and the server refuses it the same way, which is what
-- "server refused: Common, Uncommon, ..." on every row was. So the pass decides which of
-- the two paths the ticks drive, and the sweep below is the one that works for everyone.
local SELL_PASS = ((Constants and Constants.Gamepasses or {}).Effects or {}).SellAll
SELL_PASS = type(SELL_PASS) == "table" and SELL_PASS.ServerAttribute or "GP_SellAll"

local function hasSellPass()
	return player:GetAttribute(SELL_PASS) == true
end

-- What the server already has switched on, so the dropdown opens showing the truth
-- rather than empty. One yielding call at paste; failure just means it opens empty.
local autoSell = {}
do
	local ok, res = pcall(function()
		return AutoSellGet and AutoSellGet:InvokeServer()
	end)
	if ok and type(res) == "table" and type(res.rarities) == "table" then
		for name, on in pairs(res.rarities) do
			if on == true then
				autoSell[tostring(name)] = true
			end
		end
	end
end

-- The ticks, in list order. One set drives both paths: what you'd have the server sell
-- standing is exactly what you'd have the sweep sell, so there's no second list to keep
-- in step. Seeded from the server's own standing order when there is one.
local junk = {}
for r in pairs(autoSell) do
	junk[r] = true
end

local function junkList()
	local out = {}
	for _, r in ipairs(RARITIES) do
		if junk[r] then
			table.insert(out, r)
		end
	end
	return out
end

-- The free path: BackpackSellRarityRequest sells everything of one rarity you're
-- holding, with no gamepass anywhere near it -- it's the "Sell Rarity" button, minus its
-- three-second are-you-sure. Called on a beat while fishing and the moment the server
-- says MAX_BACKPACK, which is what keeps a long run from ending on a full backpack.
function sweep()
	if not SellRarity then
		return 0
	end
	local sold = 0
	for _, r in ipairs(junkList()) do
		local ok, res = pcall(function()
			return SellRarity:InvokeServer(r)
		end)
		if ok and type(res) == "table" and res.ok == true then
			sold += tonumber(res.sold) or 0
		end
	end
	return sold
end

-- The paid path, when the pass is there: same ticks, but the server keeps selling them
-- with the panel shut and the game closed. Diffed against what it already has, not
-- pushed wholesale -- unticking has to send its own false, and re-sending the ones
-- already on is a remote per row per click.
local function pushStandingOrder()
	if not (AutoSellSet and hasSellPass()) then
		return {}
	end
	local refused = {}
	for _, r in ipairs(RARITIES) do
		if (junk[r] or false) ~= (autoSell[r] or false) then
			local ok, res = pcall(function()
				return AutoSellSet:InvokeServer(r, junk[r] == true)
			end)
			if ok and type(res) == "table" and res.ok == true then
				autoSell[r] = junk[r] or nil
			else
				-- autoSell keeps the OLD value, so the next tick re-sends this one
				-- rather than deciding it's already in a state it never reached.
				table.insert(refused, r)
			end
		end
	end
	return refused
end

-- Neither path shows anything in this panel on its own, so a tick that didn't land looks
-- exactly like one that did. This row is how you tell, and it names which of the two is
-- actually carrying the ticks.
function showSell(refused, sold)
	if not sellRow then
		return
	end
	local on = junkList()
	if #on == 0 then
		sellRow:SetDesc("nothing ticked -- a full backpack is what ends a long run")
		return
	end
	local msg = table.concat(on, ", ")
		.. (hasSellPass() and "   |   standing order set (sells with the panel shut)" or string.format(
			"   |   swept every %ds while fishing -- the standing order needs the Sell All gamepass",
			SELL_EVERY
		))
	if refused and #refused > 0 then
		msg = msg .. "   |   server refused: " .. table.concat(refused, ", ")
	end
	if sold and sold > 0 then
		msg = msg .. string.format("   |   sold %d just now", sold)
	end
	sellRow:SetDesc(msg)
end

-- shell ----------------------------------------------------------------------
-- ponytail: no hand-rolled widget kit. WindUI already ships the multi-select dropdown,
-- toggles, sliders, cards, drag and the topbar, which is everything this panel is.
-- Topbar, icon, bubble, live game name and the shade live in panel.lua, so a restyle is
-- one file and not seventeen. Fetched here rather than installed by the loader, so this
-- file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Fish an Anime", -- fallback until the live name lands
	folder = "FishAnime", -- renaming it later orphans configs already saved in-game
	size = UDim2.fromOffset(480, 400),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })

-- Box + BoxBorder are what turn a bare header into a card: WindUI paints the surface
-- and hairline from its own theme tokens, so this tracks the active theme.
local function card(title, desc, icon)
	return Tab:Section({ Title = title, Desc = desc, Icon = icon, Box = true, BoxBorder = true, Opened = true })
end

local fishCard = card("Fish", "Cast, hook, spam, recast", "solar:water-bold")
local pondCard = card("Pond", "Where to cast, and how to get there", "solar:map-point-wave-bold")
local sellCard = card("Sell", "The game's own auto-sell, so the backpack never fills", "solar:tag-price-bold")
local tuneCard = card("Tuning", "The two waits that decide the cycle", "solar:tuning-2-bold")

fishToggle = fishCard:Toggle({
	Title = "Auto fish",
	Desc = "Stands where you are and fishes the nearest pond",
	Value = false,
	Callback = function(state)
		-- Set() below fires this callback again, so the off branch has to be re-entrant.
		if not state then
			if fishing then
				say("stopped -- " .. catches .. " caught")
			end
			fishing = false -- the loop exits on its own flag and cancels the live cast
			return
		end
		if not (RequestStart and Click and State) then
			fishToggle:Set(false)
			WindUI:Notify({ Title = "Fish an Anime", Content = "Fishing remotes missing -- see F9.", Image = "x" })
			return
		end
		startFishing()
	end,
})

statusRow = fishCard:Paragraph({ Title = "Status", Desc = "idle" })
catchRow = fishCard:Paragraph({ Title = "Caught", Desc = "nothing yet" })

-- Built from what's actually in the map, deduped: PONDAREA1 is five parts and one row.
local pondValues = { "Nearest" }
do
	local seen = {}
	for _, p in ipairs(ponds()) do
		if not seen[p.Name] then
			seen[p.Name] = true
			table.insert(pondValues, p.Name)
		end
	end
end

pondCard:Dropdown({
	Title = "Pond",
	Desc = "PONDAREA2 needs a Strength 2000 rod -- under that it answers TOO_WEAK",
	Values = pondValues,
	Value = "Nearest",
	Callback = function(picked)
		pondChoice = picked
	end,
})

pondCard:Button({
	Title = "Go to pond",
	Desc = "TPs onto the picked pond. These parts are volumes -- you may land in the water",
	Callback = function()
		local root = hrp()
		local pond = pickPond()
		if not (root and pond) then
			say("no character, or no pond to go to")
			return
		end
		say(tp(pondTarget(pond, root.Position)) and ("at " .. pond.Name) or "no character")
	end,
})

sellCard:Dropdown({
	Title = "Junk rarities",
	Desc = "Swept while fishing, and the moment the backpack fills. Ticking sells nothing on its own",
	Values = RARITIES,
	Value = junkList(),
	Multi = true,
	AllowNone = true,
	Callback = function(picked)
		junk = ticked(picked)
		-- With the gamepass this also becomes a standing order the server keeps after
		-- you close the game; without it, the ticks still drive the sweep.
		showSell(pushStandingOrder())
	end,
})

sellCard:Button({
	Title = "Sell ticked now",
	Desc = "One pass of the ticked rarities, without waiting for the sweep",
	Callback = function()
		lastSweep = os.clock()
		local sold = sweep()
		showSell(nil, sold)
		say(sold > 0 and ("sold " .. sold) or "nothing ticked was in the backpack")
	end,
})

sellCard:Button({
	Title = "Sell all now",
	Desc = "Everything in the backpack that isn't favorited, ticked or not. There is no undo",
	Callback = function()
		if not SellAll then
			say("no sell remote")
			return
		end
		local ok, res = pcall(function()
			return SellAll:InvokeServer()
		end)
		say(ok and type(res) == "table" and res.ok == true and "backpack sold" or "the server refused the sell")
	end,
})

sellRow = sellCard:Paragraph({ Title = "Selling", Desc = "..." })
showSell() -- seeded from the server's own standing order, not from the dropdown

tuneCard:Slider({
	Title = "Click delay",
	Desc = "Seconds between clicks once hooked. 0 is one a frame -- the game's own is 0.27",
	Value = { Min = 0, Max = 0.3, Default = CLICK_STEP },
	Step = 0.01,
	Callback = function(v)
		clickStep = tonumber(v) or CLICK_STEP
	end,
})

tuneCard:Slider({
	Title = "Recast gap",
	Desc = "Seconds after a catch before the next cast. The game's own floor is 0.5",
	Value = { Min = 0, Max = 2, Default = CAST_GAP },
	Step = 0.05,
	Callback = function(v)
		CAST_GAP = tonumber(v) or CAST_GAP
	end,
})

-- close ----------------------------------------------------------------------
-- The red topbar button destroys the window after WindUI's own confirm dialog, so
-- teardown hangs off OnDestroy and both exits share it. ponytail: rerun to come back.
local function shutdown()
	running, fishing = false, false
	if stateConn then
		stateConn:Disconnect() -- or every panel opened this session still tracks phase
		stateConn = nil
	end
	if phase ~= "idle" and Cancel then
		pcall(function()
			Cancel:FireServer() -- don't leave the rod out with nobody clicking
		end)
	end
end

Window:OnDestroy(function()
	shutdown()
	if getgenv then
		getgenv().fishAnimeStop = nil -- both exits clear the slot, or the next paste calls
	end -- a stop closure whose Window is already destroyed
end)

if getgenv then
	getgenv().fishAnimeStop = function()
		shutdown()
		pcall(function()
			Window:Destroy()
		end)
		getgenv().fishAnimeStop = nil
	end
end
