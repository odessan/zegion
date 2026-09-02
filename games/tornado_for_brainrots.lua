	--[[ Tornado for Brainrots -- the fan/tornado game (72833051149233)

		FARM     : score every brainrot standing in every rarity zone, TP to the single
					best one on the whole map, grab it, TeleportHome. Then do it again.

					One per trip, though the carry holds four. Filling it costs a teleport
					per extra brainrot anyway, and every one after the first is picked off a
					list that's no longer sorted by what's best -- so a short trip is both
					quicker and greedier.

					"Best" is BaseMoney x mutation, both read out of the game's own
					ReplicatedStorage.BrainrotData. Spawned brainrots are all Level 1, so
					that product IS the number the billboard shows -- no parsing needed.

					The tornado itself is not automated and doesn't need to be: charging the
					fan is only how the game moves you down the +X corridor, and a CFrame
					does that for free. If a zone ever refuses a grab twice it gets
					blacklisted for the session and the loop drops to the next best -- which
					is how the script discovers your real reach without being told.

		COLLECT  : touches the MoneyCollect.Button of every slot on your plot on a timer.
					Runs on its own thread and never moves the character, so it doesn't
					fight the farm.
		HOLD BEST: keeps the highest-earning brainrot you own equipped. The game rebuilds
					every tool you own each time the inventory changes -- which is once per
					grab -- so this re-equips on a timer rather than once.
		UPGRADE  : BuyUpgrade on the ticked stats. None of them make this loop faster --
					it teleports and it banks after every brainrot -- so this is here for
					playing by hand.
		CHESTS   : opens every owned chest whose timer has run out, then buys the dearest
					chest your money covers. Chest #1 is free with no wait.
		SELL ALL : a button, not a toggle. Empties the inventory for cash -- the farm's
					whole output, so it isn't something to leave running by accident.

		Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
		RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
		Stop: getgenv().tornadoRotsStop() ]]

	-- config ---------------------------------------------------------------------
	local LIFT = 6 -- studs above a brainrot to land. The prompt reaches 10 and the models
	-- are a few studs tall, so this is "close enough to grab, not inside the mesh".
	local SETTLE = 4 -- ping multiples to wait after a TP. Raise if grabs fire but nothing
	-- lands: the prompt's range check runs against where the SERVER thinks you are.
	local GRAB_TIMEOUT = 2 -- give up on one brainrot. A grab that lands does so in 0.3-0.8s,
	-- so this is generous -- and it wants to stay small, because a refusal is ambiguous
	-- (full carry? lost race? gated zone?) and this is what each ambiguous one costs.
	local CONFIRM_GRACE = 0.6 -- seconds to let the inventory catch up after a brainrot
	-- vanishes. The model disappearing and the inventory entry appearing are two different
	-- round trips; read the count too early and your own grab looks like someone else's.
	local ZONE_STRIKES = 2 -- timeouts in one zone before it's skipped for the session
	local BANK_SETTLE = 0.8 -- seconds after TeleportHome before the next TP. The server
	-- moves you; teleporting straight back out races that and you land at home.
	local IDLE = 1 -- seconds between cycles when every zone came up empty

	local COLLECT_EVERY = 5 -- seconds between money sweeps of your plot
	local HOLD_EVERY = 1 -- seconds between re-equips of the best brainrot. It has to repeat:
	-- the game destroys and rebuilds every tool you own each time the inventory changes,
	-- which is once per grab, and that drops whatever was in your hand.
	local UPGRADE_EVERY = 3 -- seconds between upgrade rounds; this one spends money
	local CHEST_EVERY = 10 -- seconds between chest rounds; also spends money

	local STATS = { "CarrySlots", "BlowPower", "Speed" } -- keys BuyUpgrade accepts
	-- None of the three change how fast this script farms -- it teleports, and it banks
	-- after every single brainrot -- so the default is the cheap one. They're here for
	-- playing the game by hand, not for the loop.
	local DEFAULT_STATS = { "Speed" }
	local CHESTS = 6 -- ChestModule.Chests is 1..6, cheapest first
	local KEY_TOGGLE = Enum.KeyCode.RightControl

	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local player = Players.LocalPlayer
	local ping = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]

	if getgenv and getgenv().tornadoRotsStop then
		getgenv().tornadoRotsStop() -- re-running must not stack a second panel/loop
	end

	local TeleportHome = ReplicatedStorage:WaitForChild("TeleportHome")
	local BuyUpgrade = ReplicatedStorage:WaitForChild("UpgradeEvents"):WaitForChild("BuyUpgrade")
	local BuyChest = ReplicatedStorage:WaitForChild("BuyChest")
	local OpenChest = ReplicatedStorage:WaitForChild("OpenChest")
	local BrainrotSellEvent = ReplicatedStorage:WaitForChild("BrainrotSellEvent")
	local PlayerSaves = ReplicatedStorage:WaitForChild("PlayerSaves")
	local uid = tostring(player.UserId)

	-- The game's own price table. 100+ brainrots and every update adds more, so requiring
	-- it beats copying it; a name that isn't in it scores 0 and sorts last rather than
	-- blocking the sweep.
	local data
	pcall(function()
		data = require(ReplicatedStorage.BrainrotData)
	end)

	-- Verbatim from BrainrotData, and duplicated on purpose: it's seven numbers that decide
	-- the whole ranking, and the require above is the one thing here that can come back nil.
	-- The live table wins when it loads, so an update that adds a mutation still lands.
	local MUT = (data and data.MutationMultipliers)
		or { Normal = 1, Gold = 2, Diamond = 5, Rainbow = 10, Lava = 20, Galaxy = 40, Hacker = 250 }

	local BASE = {}
	for _, b in ipairs(data and data.Brainrots or {}) do
		BASE[b.Name] = b.BaseMoney
	end

	local say = function() end -- replaced by the panel below

	-- world ----------------------------------------------------------------------
	local function hrp()
		local char = player.Character or player.CharacterAdded:Wait()
		return char:WaitForChild("HumanoidRootPart", 10)
	end

	-- Teleport is instant client-side; the server needs a round trip or two before it
	-- agrees you're there, and streaming leaves you paused with nothing loaded around you.
	local function tp(pos)
		local root = hrp()
		if not root then
			return false
		end
		root.CFrame = typeof(pos) == "Vector3" and CFrame.new(pos) or pos
		task.wait((ping:GetValue() * SETTLE) / 1000)
		while player.GameplayPaused do
			task.wait(0.1)
		end
		return true
	end

	-- Found by shape, not by path: every rarity folder is workspace.Spawners.SpawnPlace<X>,
	-- so a new zone in an update joins the rotation with no edit here. Positions aren't
	-- written down anywhere in this file for the same reason -- we TP to the brainrot we
	-- picked, never to a zone centre.
	local function zones()
		local fold = workspace:FindFirstChild("Spawners")
		local out = {}
		if fold then
			for _, z in ipairs(fold:GetChildren()) do
				local rarity = z.Name:match("^SpawnPlace(.+)$")
				if rarity then
					table.insert(out, { name = rarity, fold = z })
				end
			end
		end
		return out
	end

	local function stats()
		local all = PlayerSaves:FindFirstChild("PlayerStats")
		return all and all:FindFirstChild(uid)
	end

	local function money()
		local mine = stats()
		local m = mine and mine:FindFirstChild("Money")
		return m and m.Value or 0
	end

	local function ownPlot()
		local plots = workspace:FindFirstChild("Plots")
		for _, plot in ipairs(plots and plots:GetChildren() or {}) do
			if tonumber(plot:GetAttribute("Owner")) == player.UserId then
				return plot
			end
		end
		return nil
	end

	-- farm -----------------------------------------------------------------------
	-- Mutation is a prefix on the model's own name -- "Gold Trippi Troppi", "Lava Tung
	-- Sahur" -- which is how the placed ones read in a dump and how the spawned ones read
	-- too. There's no Mutation attribute on these models to ask instead.
	--
	-- Spawned brainrots are all Level 1, so BaseMoney x mutation is exactly the number on
	-- their billboard. Nothing here needs the billboard to have streamed in.
	local function strip(name)
		for mutation, mult in pairs(MUT) do
			if mutation ~= "Normal" and name:sub(1, #mutation + 1) == mutation .. " " then
				return name:sub(#mutation + 2), mult
			end
		end
		return name, 1
	end

	do
		local plain, one = strip("Trippi Troppi")
		assert(plain == "Trippi Troppi" and one == 1, "a plain name is left alone")
		local base, mult = strip("Gold Trippi Troppi")
		assert(base == "Trippi Troppi" and mult == MUT.Gold, "a prefix comes off and brings its multiplier")
		assert(strip("Goldfish Gustavo") == "Goldfish Gustavo", "the prefix has to be a whole word")
	end

	local function worth(name)
		local base, mult = strip(name)
		return (BASE[base] or 0) * mult -- unknown name scores 0 and sorts last, never blocks
	end

	-- Every brainrot standing in every zone we're still allowed in, best first. One flat
	-- list on purpose: the point of the farm is "the best thing on the map", and a
	-- per-zone rotation would walk past a Galaxy in Rare to work an empty Ancient.
	local function candidates(skip)
		local out = {}
		for _, zone in ipairs(zones()) do
			if not skip[zone.name] then
				for _, model in ipairs(zone.fold:GetChildren()) do
					if model:IsA("Model") then
						-- home is kept so a stale entry can be told from a live one. "Still
						-- has a parent" is not the same question: a brainrot that's been
						-- picked up is reparented, not destroyed, so it stays truthy while
						-- being unpickable -- and firing at it costs the whole GRAB_TIMEOUT.
						table.insert(out, { model = model, home = zone.fold, zone = zone.name, worth = worth(model.Name) })
					end
				end
			end
		end
		-- Scored once up front, not inside the comparator: a sort calls its comparator far
		-- more often than it has elements.
		table.sort(out, function(a, b)
			return a.worth > b.worth
		end)
		return out
	end

	-- The prompt hangs off whichever part the model calls its own -- Mesh, a union, a plain
	-- Part -- so a recursive search beats naming the path, and it doubles as the streaming
	-- check: no prompt yet means the model hasn't loaded, not that it can't be picked up.
	-- How many brainrots you own. It only ever climbs -- this is the permanent inventory,
	-- not a carry -- which is exactly what makes it a clean confirmation: one more entry
	-- than a moment ago means the server awarded THIS grab to YOU.
	local function owned()
		local all = PlayerSaves:FindFirstChild("BrainrotsInventory")
		local mine = all and all:FindFirstChild(uid)
		return mine and #mine:GetChildren() or 0
	end

	-- Four outcomes. The trip ends on three of them -- only "skip" walks on to another
	-- brainrot -- because anything that could have put something in your hands has to be
	-- followed by a bank, whether or not we managed to prove it did.
	--
	--   "got"      the inventory grew. Ours, definitely.
	--   "gone"     the model left its folder but the count hasn't moved. Either someone
	--              beat us to it, or our own pickup just hasn't replicated yet -- and the
	--              two are indistinguishable, so it's treated as ours for banking purposes
	--              and as nobody's fault for blacklisting purposes.
	--   "refused"  timed out with the model still standing there. Nobody took it and we
	--              didn't get it: the server refused US. The only reading that earns a
	--              zone a strike.
	--   "skip"     no prompt or no part yet -- it hasn't streamed in. Try the next one.
	local function grab(entry, alive)
		local model = entry.model
		local part = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
		local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
		if not (part and prompt) then
			return "skip"
		end

		local home, started, before = entry.home, os.clock(), owned()
		tp(part.Position + Vector3.new(0, LIFT, 0))

		-- fireproximityprompt returns nothing useful, and the model leaving the folder only
		-- says SOMEONE got it. The inventory going up is the one signal that says we did.
		local deadline = os.clock() + GRAB_TIMEOUT
		repeat
			pcall(fireproximityprompt, prompt)
			task.wait()
		until owned() > before or model.Parent ~= home or os.clock() > deadline or not alive()

		-- The model disappears on the tick the server accepts the grab; the inventory child
		-- has to replicate before we can see it. Reading the count in that gap is how a
		-- perfectly good grab gets misread as a race we lost, so give it a moment.
		if model.Parent ~= home then
			local grace = os.clock() + CONFIRM_GRACE
			while owned() <= before and os.clock() < grace do
				task.wait()
			end
		end

		if owned() > before then
			print(("[tornado] %s in %.1fs"):format(model.Name, os.clock() - started))
			return "got"
		end
		return model.Parent == home and "refused" or "gone"
	end

	local function bank()
		TeleportHome:FireServer()
		task.wait(BANK_SETTLE)
	end

	local farming, gen = false, 0

	local function setFarming(on)
		if on == farming then
			return
		end
		farming = on
		if not on then
			say("idle")
			return
		end

		gen += 1
		local mine = gen
		-- Bumping gen retires the previous thread; alive() is how the cycle and the grab
		-- deep inside it find out, instead of running on against a loop we've turned off.
		local function alive()
			return farming and gen == mine
		end

		-- One brainrot per trip. The carry holds more, but filling it means a teleport per
		-- extra brainrot anyway plus a rescan that's no longer looking at the best one on
		-- the map -- so grab the best, go home, look again. Shorter loop, better picks.
		task.spawn(function()
			local strikes, skip, banked = {}, {}, 0

			while alive() do
				local ok, err = pcall(function()
					local list = candidates(skip)
					if #list == 0 then
						say(("nothing to grab - %d banked"):format(banked))
						task.wait(IDLE)
						return
					end

					for _, entry in ipairs(list) do
						if not alive() then
							return
						end
						-- Still where we found it? Other players are working the same zones,
						-- so an entry sorted a moment ago may already be gone. Skipping is
						-- free; not skipping costs a GRAB_TIMEOUT on a prompt nobody wins.
						if entry.model.Parent == entry.home then
							say(("%s - %s - %d banked"):format(entry.zone, entry.model.Name, banked))
							local got = grab(entry, alive)

							if got == "refused" then
								-- Nobody took it and we didn't get it, so it isn't a race --
								-- it's the zone. Two readings before writing a whole rarity
								-- tier off for the session.
								local n = (strikes[entry.zone] or 0) + 1
								strikes[entry.zone] = n
								if n >= ZONE_STRIKES then
									skip[entry.zone] = true
									warn(("[tornado] %s refuses grabs - skipping it"):format(entry.zone))
									say(("%s out of reach - dropping a tier"):format(entry.zone))
								end
								return -- rescan: the map moved on while we sat on a prompt
							elseif got ~= "skip" then
								-- "got" or "gone". Bank on both: "gone" may well BE ours with
								-- the confirmation still in flight, and going home with empty
								-- hands costs one teleport, while carrying on with full ones
								-- costs every grab after it. One brainrot per trip is the
								-- whole point, so the trip ends here either way.
								if got == "got" then
									strikes[entry.zone], banked = nil, banked + 1
								end
								bank()
								return -- rescan: the best on the map has changed by now
							end
							-- "skip": hasn't streamed in, nothing happened, nothing to bank.
							-- Fall through and take the next best instead.
						end
					end
				end)
				if not ok then
					warn("[tornado]", err) -- brainrots vanish mid-cycle; a dead model throws
				end
				task.wait()
			end
		end)
	end

	-- boosts ---------------------------------------------------------------------
	-- One generation counter per loop, same reason as the farm: toggling off and on inside
	-- a single interval otherwise leaves the sleeping thread alive next to the new one.
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

	local collector = { on = false, gen = 0 }
	local upgrader = { on = false, gen = 0 }
	local chester = { on = false, gen = 0 }
	local holder = { on = false, gen = 0 }
	local pickedStats = DEFAULT_STATS

	-- Your inventory, best first. FinalMoney is the server's own per-second figure for that
	-- exact brainrot -- level and mutation already in it -- so it beats re-deriving from
	-- ModelName, which is only the fallback for an entry the server hasn't filled in yet.
	local function bestOwned()
		local all = PlayerSaves:FindFirstChild("BrainrotsInventory")
		local mine = all and all:FindFirstChild(uid)
		local best, top = nil, -1
		for _, entry in ipairs(mine and mine:GetChildren() or {}) do
			local final = entry:FindFirstChild("FinalMoney")
			local model = entry:FindFirstChild("ModelName")
			local score = (final and final.Value) or (model and worth(model.Value)) or 0
			if score > top then
				best, top = entry, score
			end
		end
		return best, top
	end

	-- Tools are matched by the BrainrotID attribute the game stamps on them, not by name:
	-- two Gold Meowls are two different brainrots with the same tool name, and only the id
	-- says which one is the good one.
	local function holdBest()
		local char = player.Character
		local humanoid = char and char:FindFirstChildOfClass("Humanoid")
		local entry = bestOwned()
		if not (humanoid and entry) then
			return
		end
		for _, where in ipairs({ char, player:FindFirstChild("Backpack") }) do
			for _, tool in ipairs(where and where:GetChildren() or {}) do
				if tool:IsA("Tool") and tool:GetAttribute("BrainrotID") == entry.Name then
					if tool.Parent ~= char then -- already in hand: re-equipping only flickers it
						humanoid:EquipTool(tool)
					end
					return
				end
			end
		end
	end

	-- No remote for this one, so the touch has to be forged. The part that matters is
	-- Plots.<n>.<slot>.MoneyCollect.BUTTON, not MoneyCollect itself -- the dump flags the
	-- child as the one carrying a TouchTransmitter and the parent as carrying nothing, so
	-- touching the parent is a no-op that looks exactly like a broken toggle.
	--
	-- 0 is touch-began and 1 is touch-ended, in that order. firetouchinterest fires the
	-- server's handler directly and doesn't care where the character is, which is what lets
	-- this run while the farm is teleporting around the map.
	local function collect()
		local plot, char = ownPlot(), player.Character
		local head = char and char:FindFirstChild("Head")
		if not (plot and head and firetouchinterest) then
			return
		end
		for _, slot in ipairs(plot:GetChildren()) do
			local pad = tonumber(slot.Name) and slot:FindFirstChild("MoneyCollect")
			local button = pad and pad:FindFirstChild("Button")
			if button then
				pcall(function()
					firetouchinterest(head, button, 0)
					task.wait()
					firetouchinterest(head, button, 1)
				end)
			end
		end
	end

	-- Owned chests carry their own OpenTime, a unix timestamp, and open by instance name.
	-- Buying picks the dearest one the money covers: prices climb per purchase and live on
	-- PlayerStats as Price1..Price6, so this is always the best chest available right now.
	local function chests()
		local owned = PlayerSaves:FindFirstChild("Chests")
		owned = owned and owned:FindFirstChild(uid)
		for _, chest in ipairs(owned and owned:GetChildren() or {}) do
			local ready = chest:FindFirstChild("OpenTime")
			if ready and ready.Value <= os.time() then
				OpenChest:FireServer(chest.Name)
				task.wait(0.2)
			end
		end

		local mine, cash = stats(), money()
		for i = CHESTS, 1, -1 do
			local price = mine and mine:FindFirstChild("Price" .. i)
			if price and price.Value <= cash then
				BuyChest:FireServer(i) -- one arg only; a second one is the Robux path
				return
			end
		end
	end

	-- gui ------------------------------------------------------------------------
	-- Topbar, icon, bubble, live game name and the shade all live in panel.lua, so a
	-- restyle is one file and not seventeen. Fetched here rather than installed by the
	-- loader, so this file still pastes and runs on its own.
	local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
	local panel = loadstring(game:HttpGet(PANEL_URL))()

	local Window = panel({
		game = "Tornado for Brainrots", -- fallback until the live name lands
		folder = "TornadoRots", -- unchanged: renaming it orphans configs already saved in-game
		size = UDim2.fromOffset(440, 380),
		key = KEY_TOGGLE,
	})
	if not Window then
		return -- panel.lua already said why
	end

	local Tab = Window:Tab({ Title = "Main", Icon = "solar:tornado-bold" })
	local Farm = Tab:Section({ Title = "Farm", Icon = "solar:box-bold", Box = true, BoxBorder = true, Opened = true })
	local Extra = Tab:Section({ Title = "Extras", Icon = "solar:double-alt-arrow-up-bold", Box = true, BoxBorder = true, Opened = true })

	Farm:Toggle({
		Title = "Auto Farm",
		Desc = "Best brainrot on the map, then TeleportHome once the carry is full",
		Value = false,
		Callback = setFarming, -- :Set() re-fires this, and setFarming is re-entrant
	})

	Farm:Button({ Title = "TP to best", Callback = function()
		local best = candidates({})[1]
		if not best then
			say("no brainrots spawned")
			return
		end
		local part = best.model.PrimaryPart or best.model:FindFirstChildWhichIsA("BasePart", true)
		if part then
			say(("%s - %s"):format(best.zone, best.model.Name))
			tp(part.Position + Vector3.new(0, LIFT, 0))
		end
	end })

	Farm:Button({ Title = "Teleport Home", Callback = bank })

	Extra:Toggle({
		Title = "Auto Collect",
		Desc = "Touches every MoneyCollect on your plot; doesn't move you",
		Value = false,
		Callback = function(v)
			collector.on = v
			if v then
				every(collector, COLLECT_EVERY, collect)
			end
		end,
	})

	Extra:Toggle({
		Title = "Hold Best",
		Desc = "Keeps the highest FinalMoney brainrot you own equipped, and re-equips it",
		Value = false,
		Callback = function(v)
			holder.on = v
			if v then
				-- Only announced when the best actually changes: this ticks once a second and
				-- would otherwise sit on top of whatever the farm is saying.
				local held
				every(holder, HOLD_EVERY, function()
					local entry, score = bestOwned()
					if entry and entry.Name ~= held then
						local name = entry:FindFirstChild("DisplayName") or entry:FindFirstChild("ModelName")
						held = entry.Name
						say(("holding %s ($%d/s)"):format(name and name.Value or entry.Name, score))
					end
					holdBest()
				end)
			end
		end,
	})

	Extra:Dropdown({
		Title = "Stats",
		Desc = "What Auto Upgrade buys. None of them speed the farm up -- it always banks after one.",
		Values = STATS,
		Value = DEFAULT_STATS,
		Multi = true,
		AllowNone = true,
		Callback = function(values)
			pickedStats = values
		end,
	})

	Extra:Toggle({
		Title = "Auto Upgrade",
		Desc = "BuyUpgrade on the ticked stats; the server refuses what you can't afford",
		Value = false,
		Callback = function(v)
			upgrader.on = v
			if v then
				every(upgrader, UPGRADE_EVERY, function()
					for _, stat in ipairs(pickedStats) do
						BuyUpgrade:FireServer(stat, 1)
					end
				end)
			end
		end,
	})

	Extra:Toggle({
		Title = "Auto Chests",
		Desc = "Opens whatever's ready, then buys the dearest chest your money covers",
		Value = false,
		Callback = function(v)
			chester.on = v
			if v then
				every(chester, CHEST_EVERY, chests)
			end
		end,
	})

	Extra:Button({
		Title = "Sell All",
		Desc = "Empties the inventory for cash",
		Callback = function()
			BrainrotSellEvent:FireServer("SellAll")
			say("sold everything in the inventory")
		end,
	})

	local line = Farm:Paragraph({ Title = "Status", Desc = "idle" })
	say = function(msg)
		line:SetDesc(msg)
	end

	-- close ----------------------------------------------------------------------
	local function stopAll()
		collector.on, upgrader.on, chester.on, holder.on = false, false, false, false
		setFarming(false)
	end

	Window:OnDestroy(function()
		stopAll()
		getgenv().tornadoRotsStop = nil
	end)

	getgenv().tornadoRotsStop = function()
		stopAll()
		pcall(function()
			Window:Destroy()
		end)
		getgenv().tornadoRotsStop = nil
	end
