--[[ One Dropper Tycoon -- the wheat/bread tycoon (139063887391814)

     The game only ships SEVEN gameplay remotes, and exactly one of them is worth
     firing (FarmPlant). Everything else -- buying upgrades, harvesting, buying bits,
     rebirthing -- is a Touched or a ClickDetector, so this panel is mostly
     firetouchinterest and fireclickdetector rather than remote spam.

     BUY     : touches every Button part in YOUR tycoon (the one whose OwnerId
               attribute is your UserId), cheapest included, on a loop. No price
               parsing: the server refuses what you cannot afford, so a blind sweep
               buys exactly the affordable set and costs one pass. Leave it off while
               you are saving for a rebirth, or it will spend the bank.
     FARM    : the wheat side-loop, as the game itself plays it.
                 * seeds come from the Box (Seeds/MaxSeeds attributes, one touchPart)
                 * planting is FarmPlant:FireServer(plot). The game's own Farm.lua
                   only gates it on holding the Wheat Seeds tool and the plot's
                   IsFarmPlot attribute, so that is all this reproduces.
                 * harvesting is the plot's own ClickDetector. It sits at
                   MaxActivationDistance = 0 and the server raises it when the plot
                   goes Harvestable -- fireclickdetector does not care either way.
               Plots carry everything the decision needs as attributes:
               FarmUnlocked / Harvestable / PlantedCrops / RequiredCrops / GrowTime.
     BITS    : clicks every card in the merchant's stand. Bits are a permanent +10%
               cash each and stack multiplicatively with Essence, so there is no card
               worth skipping -- but they are bought with CASH, so this and Auto Buy
               are pulling from the same wallet. Run one at a time.
     REBIRTH : the Obelisk button, behind a confirm. Wipes cash and the tycoon for
               Essence (+0.4% cash each, permanent).
     TOTEM   : the Weather Totem prompt, once you own it. Free multiplier, one press.
     SPEED   : Stuff.lua reads your BaseSpeed ATTRIBUTE on its own change signal and
               writes Humanoid.WalkSpeed itself, so setting the attribute locally is
               enough -- their loop then keeps the value instead of fighting it.

     NOT WIRED: where harvested Wheat gets delivered. Harvest fills your backpack with
     Wheat tools and nothing in the client, the remotes or the dumped instance tree
     touches them again -- the drop-off is created server-side at runtime, so it is
     not in the dump. Run spy.lua, deliver one wheat by hand, and it is a five-line
     addition to farmPass.

     Every action here is a touch or a click, which normally implies you were standing
     there. If a sweep silently does nothing, that is the server distance-checking:
     stand in your tycoon and try again before assuming it is broken.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl hides/shows it. Stop: getgenv().dropperTycoonStop() ]]

-- config ---------------------------------------------------------------------
local BUY_EVERY = 1 -- seconds between button sweeps. One sweep is already ~1s of
-- touch pairs, so this is really just the gap between them
local FARM_EVERY = 3 -- seconds between farm passes. The fastest plot is GrowTime 240,
-- so nothing here is urgent; this rate is for catching a harvest promptly
local BITS_EVERY = 5 -- seconds between card sweeps; each one spends cash
local PLANT_GAP = 0.2 -- pause after each seed. One FarmPlant = one seed consumed, and
-- firing the next before the server has taken the last one wastes the call
local KEY_TOGGLE = Enum.KeyCode.RightControl

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService") -- only the shade uses this
local player = Players.LocalPlayer

if getgenv and getgenv().dropperTycoonStop then
	getgenv().dropperTycoonStop() -- re-running must not stack a second panel/loop
end

local FarmPlant = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("FarmPlant")

-- Executors all ship these, but a missing one should read as one dead row and a line
-- in the console, not a stack trace out of the middle of a farm pass.
local touchFn, clickFn, promptFn = firetouchinterest, fireclickdetector, fireproximityprompt
for name, fn in pairs({ firetouchinterest = touchFn, fireclickdetector = clickFn, fireproximityprompt = promptFn }) do
	if not fn then
		warn("[Dropper] missing " .. name .. " -- the rows that need it will do nothing")
	end
end

local say = function() end -- replaced by the panel below

-- world ----------------------------------------------------------------------
local function hrp()
	local char = player.Character or player.CharacterAdded:Wait()
	return char:WaitForChild("HumanoidRootPart", 10)
end

local function humanoid()
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

-- All six tycoons are Models literally named "Tycoon"; the only thing separating
-- yours from the neighbours' is the OwnerId attribute. Re-resolved rather than
-- cached at startup, because it is only stamped once the server assigns you a plot.
local mine = nil
local function myTycoon()
	if mine and mine.Parent and mine:GetAttribute("OwnerId") == player.UserId then
		return mine
	end
	mine = nil
	local folder = workspace:FindFirstChild("Tycoons")
	if not folder then
		return nil
	end
	for _, t in ipairs(folder:GetChildren()) do
		if t:GetAttribute("OwnerId") == player.UserId then
			mine = t
			return t
		end
	end
	return nil
end

-- A Touched the server can see, from wherever you happen to be standing.
local function touch(part)
	local root = hrp()
	if not (root and part and part:IsA("BasePart") and touchFn) then
		return false
	end
	touchFn(root, part, 0)
	task.wait()
	touchFn(root, part, 1)
	return true
end

local function click(detector)
	if not (detector and clickFn) then
		return false
	end
	clickFn(detector)
	return true
end

-- Tools sit in the Backpack until equipped and on the Character after, so both
-- containers count as "you have one".
local function countTool(name)
	local n = 0
	for _, where in ipairs({ player:FindFirstChildOfClass("Backpack"), player.Character }) do
		if where then
			for _, t in ipairs(where:GetChildren()) do
				if t:IsA("Tool") and t.Name == name then
					n += 1
				end
			end
		end
	end
	return n
end

local function equip(name)
	local char, hum = player.Character, humanoid()
	if not (char and hum) then
		return nil
	end
	local held = char:FindFirstChild(name)
	if held then
		return held -- already in your hands
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	local tool = backpack and backpack:FindFirstChild(name)
	if not tool then
		return nil
	end
	hum:EquipTool(tool)
	return char:FindFirstChild(name)
end

-- farm -----------------------------------------------------------------------
-- Plots are tagged, not pathed: they live under four differently-named upgrade items
-- ("Farm Plots", "More Farm Plots", "Even More Farm Plots", "Large Farm Plot") and
-- the tag is the one thing all four share. Filtered to your tycoon so a sweep never
-- reaches into a neighbour's.
local function myPlots(tycoon)
	local out = {}
	for _, p in ipairs(CollectionService:GetTagged("IsFarmPlot")) do
		if p:IsDescendantOf(tycoon) then
			table.insert(out, p)
		end
	end
	return out
end

local function buyPass()
	local tycoon = myTycoon()
	if not tycoon then
		say("no tycoon claimed yet")
		return
	end
	local buttons = tycoon:FindFirstChild("Buttons")
	if not buttons then
		return
	end
	local n = 0
	for _, b in ipairs(buttons:GetChildren()) do
		if b:IsA("BasePart") then
			touch(b)
			n += 1
		end
	end
	say(("swept %d buttons"):format(n))
end

local function farmPass()
	local tycoon = myTycoon()
	if not tycoon then
		say("no tycoon claimed yet")
		return
	end
	local plots = myPlots(tycoon)
	if #plots == 0 then
		say("no farm plots -- buy one in the tycoon first")
		return
	end

	-- Harvest first: it empties plots that the plant pass below can then refill in
	-- the same tick, instead of waiting a whole interval for the next one.
	local harvested = 0
	for _, plot in ipairs(plots) do
		if plot:GetAttribute("Harvestable") then
			local cd = plot:FindFirstChildOfClass("ClickDetector")
			if cd and click(cd) then
				harvested += 1
			end
		end
	end

	-- The Box is the seed dispenser: it holds up to MaxSeeds and its touchPart hands
	-- you the tool. Touched unconditionally when you are empty -- an empty box just
	-- gives you nothing, which is cheaper than reading its Seeds attribute and being
	-- wrong about what it counts.
	if countTool("Wheat Seeds") == 0 then
		local items = tycoon:FindFirstChild("Items")
		local box = items and items:FindFirstChild("Box")
		local pad = box and box:FindFirstChild("touchPart")
		if pad then
			touch(pad)
		end
	end

	local planted = 0
	if equip("Wheat Seeds") then
		for _, plot in ipairs(plots) do
			-- Growing is the game's own "this one is busy" flag, but the count is the
			-- condition that actually decides whether another seed fits: a plot wants
			-- RequiredCrops seeds before it starts growing at all.
			local want = plot:GetAttribute("RequiredCrops") or 1
			local has = plot:GetAttribute("PlantedCrops") or 0
			if plot:GetAttribute("FarmUnlocked") and not plot:GetAttribute("Harvestable") and has < want then
				FarmPlant:FireServer(plot)
				planted += 1
				task.wait(PLANT_GAP)
				if countTool("Wheat Seeds") == 0 then
					break -- out of seeds; the next pass refills from the Box
				end
			end
		end
	end

	say(("harvested %d, planted %d, %d wheat held"):format(harvested, planted, countTool("Wheat")))
end

-- Cards restock and change colour, so nothing is addressed by name: every
-- ClickDetector under BitsShops is a card buy, and there is nothing else in there.
local function bitsPass()
	local shops = workspace:FindFirstChild("BitsShops")
	if not shops then
		say("no merchant stand in this server")
		return
	end
	local n = 0
	for _, d in ipairs(shops:GetDescendants()) do
		if d:IsA("ClickDetector") and click(d) then
			n += 1
		end
	end
	say(("clicked %d cards"):format(n))
end

-- loops ----------------------------------------------------------------------
-- One generation counter per loop: toggling off and on inside a single interval
-- otherwise leaves the sleeping thread alive next to the new one, firing at double rate.
local function every(state, interval, body)
	state.gen += 1
	local mine2 = state.gen
	task.spawn(function()
		while state.on and state.gen == mine2 do
			local ok, err = pcall(body)
			if not ok then
				warn("[Dropper]", err) -- a plot that streamed out mid-pass, usually
			end
			task.wait(interval)
		end
	end)
end

local buyer = { on = false, gen = 0 }
local farmer = { on = false, gen = 0 }
local bitser = { on = false, gen = 0 }
local ALL = { buyer, farmer, bitser }

-- anti-afk -------------------------------------------------------------------
-- Roblox kicks after ~20 min without input, which an unattended tycoon never produces.
-- A right-click through VirtualUser counts as input and does nothing in the game.
local hasVU, vu = pcall(game.GetService, game, "VirtualUser")
local afk = player.Idled:Connect(function()
	if hasVU then
		pcall(function()
			vu:CaptureController()
			vu:ClickButton2(Vector2.new())
		end)
	end
end)

-- gui ------------------------------------------------------------------------
-- WindUI is fetched, not vendored, and one launch is FOUR requests to
-- raw.githubusercontent: the library, then the lucide, solar and craft icon packs that
-- its own bootstrap pulls. Any one of them coming back empty ends the same way --
-- WindUI hands the nil straight to loadstring (dist/main.lua:24496) and Opiumware
-- reports it as "missing argument #3 to 'loadstring' (string expected)" from inside a
-- stack with no line of this file in it. Nothing here is broken when that happens; the
-- host rate-limited, and the fix is to ask again.
--
-- ponytail: the retry wraps the whole load, not just the fetch above it -- three of the
-- four requests happen inside WindUI where there is nothing to guard.
local WINDUI_URL = "https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"

local function loadWindUI()
	if not game:IsLoaded() then
		game.Loaded:Wait() -- HttpGet during the join is flaky; don't burn tries on it
	end
	local last
	for attempt = 1, 5 do
		local ok, lib = pcall(function()
			return loadstring(game:HttpGet(WINDUI_URL))()
		end)
		if ok and lib then
			return lib
		end
		last = tostring(lib)
		warn(("[Dropper] WindUI load %d/5 failed: %s"):format(attempt, last))
		task.wait(2) -- long enough for a rate limit to clear, short enough to not sit here
	end
	return nil, last
end

local WindUI, why = loadWindUI()
if not WindUI then
	warn("[Dropper] WindUI would not load (" .. tostring(why) .. ") -- no panel, nothing started.")
	return
end

local Window = WindUI:CreateWindow({
	Title = "One Dropper Tycoon",
	Icon = "solar:wheel-bold",
	Folder = "DropperTycoon",
	Size = UDim2.fromOffset(440, 420),
	Topbar = { Height = 44, ButtonsType = "Mac" },
	OpenButton = { Title = "One Dropper Tycoon", Enabled = true, Draggable = true },
})
Window:SetToggleKey(KEY_TOGGLE)

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local Tycoon = Tab:Section({
	Title = "Tycoon",
	Desc = "Buttons and the wheat plots on your own plot",
	Icon = "solar:buildings-2-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})
local Bits = Tab:Section({
	Title = "Bits",
	Desc = "+10% cash each, bought with cash -- same wallet as Auto Buy",
	Icon = "solar:card-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})
local Extra = Tab:Section({
	Title = "Extras",
	Desc = "Wipes progress or changes your character",
	Icon = "solar:settings-bold",
	Box = true,
	BoxBorder = true,
	Opened = false,
})

Tycoon:Toggle({
	Title = "Auto Buy",
	Desc = "Touches every upgrade button; the server refuses what you cannot afford",
	Value = false,
	Callback = function(state)
		buyer.on = state
		if state then
			every(buyer, BUY_EVERY, buyPass)
		end
	end,
})

Tycoon:Toggle({
	Title = "Auto Farm",
	Desc = "Seeds from the Box, plant every free plot, harvest whatever is ready",
	Value = false,
	Callback = function(state)
		farmer.on = state
		if state then
			every(farmer, FARM_EVERY, farmPass)
		end
	end,
})

local line = Tycoon:Paragraph({ Title = "Status", Desc = "idle" })
say = function(msg)
	line:SetDesc(msg)
end

Bits:Toggle({
	Title = "Auto Buy Bits",
	Desc = "Clicks every card on the merchant stand",
	Value = false,
	Callback = function(state)
		bitser.on = state
		if state then
			every(bitser, BITS_EVERY, bitsPass)
		end
	end,
})

Extra:Button({
	Title = "Rebirth",
	Desc = "Resets cash and the tycoon for permanent Essence",
	Callback = function()
		Window:Dialog({
			Title = "Rebirth",
			Content = "This wipes your cash and every upgrade you have bought. Continue?",
			Buttons = {
				{ Title = "Cancel", Variant = "Secondary" },
				{
					Title = "Rebirth",
					Variant = "Primary",
					Callback = function()
						local obelisk = workspace:FindFirstChild("Obelisk")
						local button = obelisk and obelisk:FindFirstChild("RebirthButton")
						-- FindFirstChildWhichIsA over the button rather than the whole
						-- Obelisk: the model is mostly decoration and this is the only
						-- detector under it that should ever be fired.
						local cd = button and button:FindFirstChildWhichIsA("ClickDetector", true)
						if click(cd) then
							say("rebirth fired")
						else
							say("no Obelisk rebirth button found")
						end
					end,
				},
			},
		})
	end,
})

Extra:Button({
	Title = "Weather Totem",
	Desc = "One press on the totem prompt, once you own it",
	Callback = function()
		local tycoon = myTycoon()
		local items = tycoon and tycoon:FindFirstChild("Items")
		local totem = items and items:FindFirstChild("Weather Totem")
		local prompt = totem and totem:FindFirstChildWhichIsA("ProximityPrompt", true)
		if prompt and promptFn then
			promptFn(prompt)
			say("totem pressed")
		else
			say("no Weather Totem -- buy it in the tycoon first")
		end
	end,
})

Extra:Input({
	Title = "Walk speed",
	Desc = "Sets the BaseSpeed attribute the game's own script reads. 16 is default.",
	Value = "16",
	Placeholder = "16",
	Callback = function(v)
		local n = tonumber(v)
		if not n then
			return
		end
		-- Their Stuff.lua re-asserts WalkSpeed from this attribute every heartbeat, so
		-- writing WalkSpeed directly gets overwritten and writing the attribute sticks.
		-- Client-side only: the server never sees the attribute, just the movement.
		player:SetAttribute("BaseSpeed", n)
		say("walk speed " .. n)
	end,
})

-- minimize -------------------------------------------------------------------
-- WindUI's own Minimize hides the whole window and leaves nothing but the floating
-- open button, which it only draws on touch devices -- on a PC the window would be
-- gone with nothing left to click. Swapped for a shade: the body collapses to a bare
-- title bar and the same button rolls it back down. Loops keep farming either way.
--
-- The shade is sized to its CONTENT, not to the window: keeping the full width just
-- leaves a 440-wide black slab with a title in the corner of it.
--
-- Main is anchored at its CENTRE, so a resize on its own moves all four edges: the
-- shade would land mid-screen, and rolling it back down near the top of the screen
-- pushed the title bar off it with nothing left to click. Every resize is paired with
-- a position nudge of half the delta, pinning the TOP-LEFT corner instead, so the bar
-- collapses where it stands and grows back down and right from the same spot.
local SHADE_TRIM = 8 -- Topbar's own PaddingRight -- the breathing room after the title
local SHADE_MIN = 160 -- never shade narrower than the traffic lights + this button, or
-- there is nothing left to click to get the window back
local SHADE_PAD = 10 -- topbar height + window chrome; nudge if the shade clips

Window:DisableTopbarButtons({ "Minimize" }) -- before ours, it reuses the same slot

-- Measured, not guessed, so the bar fits whatever the title happens to be. WindUI lays
-- the topbar out as three frames: Left (icon + title, AutomaticSize "X"), Right (the
-- traffic lights and this button), and Center. With ButtonsType "Mac" it positions Left
-- after Right, so the right-hand edge of the widest child IS the end of the content.
-- AbsoluteSize is post-UIScale while Size offsets are pre-scale, hence the divide.
local function shadeSize(fullWidth)
	local topbar = Window.UIElements.Main.Main.Topbar
	local scale = tonumber(WindUI.UIScale) or 1
	if scale <= 0 then
		scale = 1
	end

	local edge = 0
	for _, child in ipairs(topbar:GetChildren()) do
		-- Center is the tab-strip slot: unused and invisible here, but when it IS used
		-- it's sized to fill the window, which would defeat the whole measurement.
		if child:IsA("GuiObject") and child.Visible and child.Name ~= "Center" then
			edge = math.max(edge, child.AbsolutePosition.X + child.AbsoluteSize.X - topbar.AbsolutePosition.X)
		end
	end

	local w = math.clamp(edge / scale + SHADE_TRIM, SHADE_MIN, fullWidth)
	return UDim2.fromOffset(w, Window.Topbar.Height + SHADE_PAD)
end

local SHADE_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local shaded, fullSize, shadeTo = false, nil, nil
Window:CreateTopbarButton("Shade", "minus", function()
	local main = Window.UIElements.Main
	shaded = not shaded

	-- Both read live on the way down: a window the user resized comes back its own size,
	-- and the bar is re-measured each time in case the title, the buttons or the UIScale
	-- have changed since. Kept in upvalues so the way back up doesn't have to re-derive
	-- either end -- see the note on mid-tween reads below.
	if shaded then
		fullSize = main.Size
		shadeTo = shadeSize(fullSize.X.Offset)
	end
	-- Topbar is the one child that stays. Going by name rather than by index keeps
	-- this working if WindUI reshuffles the body frames.
	for _, child in ipairs(main.Main:GetChildren()) do
		if child:IsA("GuiObject") and child.Name ~= "Topbar" then
			child.Visible = not shaded
		end
	end

	-- Both ends are known, so the delta is computed rather than read back off a frame
	-- that is still mid-tween from the last click.
	local from, to = shaded and fullSize or shadeTo, shaded and shadeTo or fullSize
	local p = main.Position
	Window:SetSize(to)
	-- Matched to SetSize's own tween, or the corner visibly slides while the size catches up.
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
local function stopAll()
	for _, state in ipairs(ALL) do
		state.on = false
	end
	afk:Disconnect()
end

Window:OnDestroy(function()
	stopAll()
	getgenv().dropperTycoonStop = nil
end)

getgenv().dropperTycoonStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().dropperTycoonStop = nil
end
