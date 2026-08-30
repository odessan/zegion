--[[ Power Blast Lucky Block -- auto blast, no cutscene

     BLAST        : start -> release -> grant the reward -> return, on a loop.
                    Everything between the release and the payout is a client-side
                    cutscene -- windup, flight, landing, grab animation, ~20s of it --
                    so we cut BlastController off BlastSequence and answer the event
                    ourselves. That skip IS the speed; the server's own cooldown is
                    the floor underneath it.
     FULL CHARGE  : actually sit through the charge before releasing, instead of
                    claiming the full 2.67s the instant we start. Off by default --
                    the first two blasts probe which one the server accepts.
     AUTO X2      : answers the aura multiplier prompt the moment the server offers it,
                    instead of hunting the circle it drops on screen. Independent of
                    the blast loop, and worth leaving on -- Power is what gates which
                    zone your blast reaches, so this is upstream of your rarity.
     PLOT CASH    : collects every slot on your lot from wherever you happen to be.
                    The game only collects the slot you are standing on, and the blast
                    pad is not your plot, so a farm left alone earns nothing from the
                    brainrots you already own.
     SEAT BEST    : hands the brainrots the blast wins you to the server to place. One
                    remote, no arguments, no walking -- and the only thing that turns a
                    reward into income, since an unplaced brainrot earns nothing.
     KEEP AURA    : takes the aura back off whatever the server put in your hands -- it
                    equips each blast reward for you, and a brainrot in hand is an aura
                    that is not, which is power you are not making. Power accrues
                    passively for as long as it is held -- no click to spam, no place to
                    stand -- so with the unequip suppressed (see below) it farms straight
                    through the blast loop rather than between blasts.
     FIX HOTBAR   : respawns you. Only needed now if you blasted by hand before pasting
                    this: that strands the controller's tool-unequip handler and every
                    equip afterwards is undone. A fresh character clears it for good.

     Rarity is a function of flight distance, and distance is gated by your Power
     (BlastConfig.Zones: Common at MinPower 0 ... Godly at 12e12), not by charge.
     Charge only decides how much of your reach you actually get, so we always claim
     the maximum and there is no charge knob worth putting on the panel.

     Executor only: WindUI for the panel, getconnections for the cutscene skip.
     Stop: getgenv().powerBlastStop() ]]

-- config ---------------------------------------------------------------------
-- The real client sends whatever os.clock() handed it, which overshoots -- the spy log
-- reads 2.7922602083418 against a CHARGE_FULL_SECONDS of 2.67. We add this to the game's
-- own number rather than hardcoding the sum, so a balance patch moves us with it. Never
-- subtract: undershooting costs flight distance and distance is the rarity roll.
local CHARGE_OVER = 0.12
-- Added instead in full-charge mode, where we actually sit through the charge: just
-- enough that the server's own timer has certainly elapsed. Raise it if full-charge
-- blasts still come back short.
local CHARGE_EXTRA = 0.05
-- Only if Modules.BlastConfig has gone; it read 2.67 at the time of writing.
local CHARGE_FULL_FALLBACK = 2.67
-- The pause between one blast and the next start. Self-tuning: it starts at GAP_MAX and
-- shortens by GAP_STEP after every blast that works, and the first refusal steps it back
-- up and freezes there.
-- Walking down rather than up because the cost is measured in refusals: from 0.05
-- upwards a 2.5s cooldown takes ~17 refused starts and 17 "Blast is cooling down"
-- toasts to find. Downwards it costs exactly one, and every blast before it counted.
-- GAP_MAX has to start ABOVE the real floor or the descent has nowhere to settle and the
-- farm stops itself. BlastConfig.COOLDOWN says 2.5, but a measured back-to-back run only
-- held at 2.9 -- so 2.5 was below the floor, every start was refused, and the run ended
-- on "refused even at the full cooldown". 3.2 walks down through 3.05 to 2.9 and sticks.
-- ponytail: freezes on the first refusal instead of hunting around the boundary.
-- Toggling off and on starts the descent again.
local GAP_MIN = 0.05
local GAP_STEP = 0.15
local GAP_MAX = 3.2
-- Split, because they fail for different reasons. A refused start is the normal way we
-- find the cooldown floor and has to be cheap; a missing fire after the server already
-- accepted the start is a real fault and worth waiting on.
local BEGIN_TIMEOUT = 1.5
local FIRE_TIMEOUT = 5
-- Nothing that hangs may park the loop it runs in: this game ships at least one
-- RemoteFunction that never returns at all (GetPlayerData), and InvokeServer has no
-- timeout of its own.
local INVOKE_TIMEOUT = 8
-- After teleporting back onto the pad, how long the server needs to see us there.
local SETTLE = 0.35
-- Calibration: how much further a full-charge blast must fly before we call the
-- instant one clamped. Distance has natural spread, so this is not zero.
local CALIB_TOL = 0.15
-- Consecutive bad blasts -- no reward, no reply, no zone -- before we stop and say so.
-- The server quietly paying nothing looks exactly like the server paying, without this.
local MAX_MISSES = 3
-- Plot cash: how often to sweep the slots. The game's own per-slot cooldown is 0.6s, so
-- anything above that is only a question of how much cash you are happy to leave sitting
-- there. Income is per-second and uncapped, so sweeping rarely costs nothing.
local CASH_POLL = 3
-- How long to give the server to zero SlotCash before reading it back. Below a round
-- trip this reports collections as failures.
local CASH_SETTLE = 0.6
-- How often to hand the server the brainrots waiting in the backpack. Slower than the
-- cash sweep on purpose: it only has anything to do once a blast has paid out.
local SEAT_POLL = 10
-- How long you may be left holding a blast reward before the aura goes back in your hand.
-- Straight off your power rate, so it is a fraction of a blast, not of a second: at 1s
-- against a ~3s cycle you spent a third of the farm holding a brainrot.
local AURA_POLL = 0.25

-- setup ----------------------------------------------------------------------
if getgenv and getgenv().powerBlastStop then
	getgenv().powerBlastStop() -- re-running must not stack a second panel/loop
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
	warn("[PowerBlast] no ReplicatedStorage.Remotes -- wrong game?")
	return
end

local function remote(name)
	local r = Remotes:WaitForChild(name, 5)
	if not r then
		warn("[PowerBlast] missing remote " .. name)
	end
	return r
end

local RequestBlastStart = remote("RequestBlastStart")
local RequestBlastRelease = remote("RequestBlastRelease")
local RequestBlastRewardGrant = remote("RequestBlastRewardGrant")
local RequestBlastReturn = remote("RequestBlastReturn")
local BlastSequence = remote("BlastSequence")
local BlastProgressSync = Remotes:FindFirstChild("BlastProgressSync")

if not (RequestBlastStart and RequestBlastRelease and RequestBlastReturn and BlastSequence) then
	warn("[PowerBlast] the blast remotes are not all here -- nothing started")
	return
end

-- The game's own numbers, so a balance patch moves us with it instead of leaving us
-- sending a stale charge. Its GetZoneForPower is worth having for its own sake: the top
-- zones are behind release feature flags, and a plain scan of BlastConfig.Zones would
-- name a zone the server has switched off.
local BlastConfig
pcall(function()
	BlastConfig = require(ReplicatedStorage:WaitForChild("Modules", 5):WaitForChild("BlastConfig", 5))
end)

local CHARGE_FULL = BlastConfig and tonumber(BlastConfig.CHARGE_FULL_SECONDS) or CHARGE_FULL_FALLBACK
local CHARGE_SEND = CHARGE_FULL + CHARGE_OVER
local CHARGE_HOLD = CHARGE_FULL + CHARGE_EXTRA

-- InvokeServer has no timeout, so every one of ours is run on a thread we can walk away
-- from. Returns nil on a hang, which every caller already treats as "the server said no".
local function invoke(rf, ...)
	local args = table.pack(...)
	local done, reply
	task.spawn(function()
		local ok, r = pcall(function()
			return rf:InvokeServer(table.unpack(args, 1, args.n))
		end)
		done, reply = true, ok and r or nil
	end)
	local deadline = os.clock() + INVOKE_TIMEOUT
	while not done and os.clock() < deadline do
		task.wait(0.1)
	end
	return reply
end

-- Cash and Power both run to 1e15 and past it, and a raw number that long is unreadable
-- in a one-line status.
local UNITS = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx" }
local function short(n)
	n = tonumber(n) or 0
	local i = 1
	while n >= 1000 and i < #UNITS do
		n, i = n / 1000, i + 1
	end
	return ("%.2f%s"):format(n, UNITS[i])
end

do
	assert(short(0) == "0.00")
	assert(short(1500) == "1.50K")
	assert(short(2.5e12) == "2.50T")
	assert(short(1e21) == "1.00Sx")
	assert(short(1e24) == "1000.00Sx", "past the table it stops scaling rather than indexing nil")
end

-- world ----------------------------------------------------------------------
-- BlastController's own isInsidePart, same slack: +2 studs on X/Z, +24 on Y, because
-- the pad sits well below where you stand. Pure, so it gets its check inline.
local function insideBox(cf, size, pos)
	local o = cf:PointToObjectSpace(pos)
	return math.abs(o.X) <= size.X * 0.5 + 2
		and math.abs(o.Y) <= size.Y * 0.5 + 24
		and math.abs(o.Z) <= size.Z * 0.5 + 2
end

do
	local cf, size = CFrame.new(0, 0, 0), Vector3.new(10, 1, 10)
	assert(insideBox(cf, size, Vector3.new(0, 0, 0)))
	assert(insideBox(cf, size, Vector3.new(6.9, 0, 0)), "the +2 slack on X")
	assert(not insideBox(cf, size, Vector3.new(7.1, 0, 0)))
	assert(insideBox(cf, size, Vector3.new(0, 24, 0)), "the +24 slack on Y")
	assert(not insideBox(cf, size, Vector3.new(0, 25, 0)))
end

-- Two things in this place are named BlastCourse: the live pad at workspace level and
-- the map geometry under workspace.Season1Map. FindFirstChild on workspace only sees
-- the first, which is the one the game's own canStartBlastFromCurrentPosition uses.
local function blastZone()
	local course = workspace:FindFirstChild("BlastCourse")
	local zone = course and course:FindFirstChild("BlastZone")
	return (zone and zone:IsA("BasePart")) and zone or nil
end

local function waitFor(fn, timeout)
	local deadline = os.clock() + timeout
	repeat
		local v = fn()
		if v ~= nil then
			return v
		end
		task.wait()
	until os.clock() > deadline
	return nil
end

-- cutscene -------------------------------------------------------------------
-- BlastSequence has exactly one listener in the whole game: BlastController, which
-- turns "begin"/"fire" into camera takeover, movement lock, the flight and the grab
-- animation. Cutting it off the event is the entire "no animation" feature.
-- Two rules, both learned in flash_for_brainrots and roll_cases: mute BEFORE
-- connecting our own handler, or getconnections hands us our own listener and we
-- switch ourselves off along with the controller; and restore on stop, or a manual
-- blast afterwards strands you in a cutscene the controller can no longer clean up.
-- ponytail: needs getconnections. Without it we say so and farm with the animation
-- rather than refusing to start.
local muted = {}

local function mute(remote)
	if not (getconnections and remote) or muted[remote] then
		return false
	end
	local list = {}
	for _, c in ipairs(getconnections(remote.OnClientEvent)) do
		pcall(function()
			c:Disable()
		end)
		table.insert(list, c)
	end
	muted[remote] = list
	return true
end

local function unmute(remote)
	local list = remote and muted[remote]
	if not list then
		return
	end
	for _, c in ipairs(list) do
		pcall(function()
			c:Enable()
		end)
	end
	muted[remote] = nil
end

-- Never mute mid-cutscene. cleanupCutscene is the only thing that disconnects the
-- controller's tool-unequip handler -- BlastController.lua:781 installs a
-- Character.ChildAdded that unequips every Tool as it appears, :869 tears it down --
-- so cutting the controller off the event between those two strands it, and every
-- equip you make for the rest of the session is silently undone. The game's own
-- BlastCutsceneActive attribute says when it is safe; on a normal start it is already
-- clear and this costs one frame.
-- If it is already stranded, reset your character: the handler lives on the old one.
waitFor(function()
	return player:GetAttribute("BlastCutsceneActive") ~= true or nil
end, 10)

local quiet = mute(BlastSequence)

-- unequip --------------------------------------------------------------------
-- Muting the event is not enough on its own. BlastController also hangs a bare Heartbeat
-- (:6010) that runs lockCharacterMovement + lockCutsceneEquipment every frame that either
-- of two attributes is true:
--     if v_u_30 or v_u_31 or BlastCutsceneActive == true or BlastBusy == true then
-- and lockCutsceneEquipment (:762) is Humanoid:UnequipTools(). BlastBusy is the SERVER's,
-- set for the whole blast, so that loop fires whether or not we cut the controller off the
-- sequence -- and Power only accrues while the aura is in your hand. That, not the
-- cutscene, is why a blast farm and an aura farm looked mutually exclusive.
-- Attributes written on the client stay on the client, and the server only replicates a
-- CHANGE, so writing false back the instant one lands holds that branch shut. The cost is
-- that BlastBusy stops being a readiness signal for us as well, which is why the loop
-- leans on the self-tuning gap instead.
-- Arming it BEFORE the first blast is the part that matters: that same branch installs the
-- Character.ChildAdded handler that unequips every tool as it arrives, and the only thing
-- that removes it is cleanupCutscene -- reachable solely through the event we just muted.
-- Never let it run and it is never stranded, which is Fix hotbar's whole job.
local function hush(name)
	if player:GetAttribute(name) == true then
		player:SetAttribute(name, false)
	end
end

local hushConns = {}
for _, name in ipairs({ "BlastBusy", "BlastCutsceneActive" }) do
	hush(name)
	hushConns[#hushConns + 1] = player:GetAttributeChangedSignal(name):Connect(function()
		hush(name)
	end)
end

-- The server refuses an early start with a notification rather than silence, so we can
-- react in a round trip instead of sitting out BEGIN_TIMEOUT. Matching server-authored
-- text is fragile, so this only ever makes the backoff faster -- the timeout still
-- catches a refusal whose wording changed.
local cooldownNotice = false
local Events = ReplicatedStorage:FindFirstChild("Events")
local ShowNotification = Events and Events:FindFirstChild("ShowNotification")
local noticeConn = ShowNotification
	and ShowNotification.OnClientEvent:Connect(function(msg)
		if type(msg) == "string" and string.find(string.lower(msg), "cooling down", 1, true) then
			cooldownNotice = true
		end
	end)

local beginPayload, firePayload
local seqConn = BlastSequence.OnClientEvent:Connect(function(p)
	if type(p) ~= "table" then
		return
	end
	if p.state == "begin" then
		beginPayload = p
	elseif p.state == "fire" then
		firePayload = p
	end
end)

-- The token the server is waiting on to un-busy us, whichever half of the sequence
-- carried it. Kept outside the blast so the stop path can settle a blast we abandoned.
local function liveReturnToken()
	local p = firePayload or beginPayload
	return p and p.blastReturnToken or nil
end

-- blast ----------------------------------------------------------------------
-- One full cycle. Returns a result table, or nil plus the reason it went nowhere.
-- Every wait here is on a world observation -- the server's own reply, its BlastBusy
-- attribute -- because the remotes return nothing worth trusting.
local function oneBlast(hold)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return nil, "no character"
	end

	local zone = blastZone()
	if not zone then
		return nil, "no BlastZone -- event over?"
	end
	-- The flight is camera-only, so your body never leaves the pad and this is almost
	-- always a no-op. It earns its keep on respawn, which would otherwise leave the
	-- loop spinning on starts the server keeps refusing.
	if not insideBox(zone.CFrame, zone.Size, hrp.Position) then
		char:PivotTo(zone.CFrame * CFrame.new(0, zone.Size.Y * 0.5 + 4, 0))
		task.wait(SETTLE)
	end

	beginPayload, firePayload = nil, nil
	cooldownNotice = false
	RequestBlastStart:FireServer()
	-- No begin means the server would not start one: almost always we came back too
	-- soon. The third return says so, and the loop widens the gap instead of counting
	-- it against MAX_MISSES -- this is how the floor gets found, not a failure.
	local began = waitFor(function()
		if beginPayload then
			return "began"
		end
		return cooldownNotice and "cooling" or nil
	end, BEGIN_TIMEOUT)
	if began ~= "began" then
		return nil, began == "cooling" and "cooling down" or "no reply to the start", true
	end

	if hold > 0 then
		task.wait(hold)
	end
	RequestBlastRelease:FireServer(CHARGE_SEND)

	local fired = waitFor(function()
		return firePayload
	end, FIRE_TIMEOUT)
	if not fired then
		return nil, "server never fired"
	end

	local reward = fired.reward
	local token = reward and reward.rewardToken
	if token then
		RequestBlastRewardGrant:FireServer({ rewardToken = token })
	end
	-- The return is what clears BlastBusy. Fire it even when nothing paid out, or the
	-- next start is refused and the loop stalls with no reason given.
	if fired.blastReturnToken then
		RequestBlastReturn:FireServer({ token = fired.blastReturnToken, reason = "normal_return" })
	end

	return {
		distance = tonumber(fired.distance) or 0,
		rarity = reward and (reward.rarity or reward.Rarity) or "?",
		paid = token ~= nil,
	}
end

-- BlastBusy used to be the "you may blast again" signal here. We hold it false on purpose
-- now (see the unequip block), so the gap is all there is -- which is fine, because the
-- gap is the thing that was tuned against the server's refusals in the first place, and
-- BlastBusy only ever told us what the gap already had to discover.
local function waitReady(gap)
	task.wait(gap)
end

-- ui -------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window = panel({
	game = "Power Blast Lucky Block", -- fallback until the live name lands
	folder = "PowerBlast",
	size = UDim2.fromOffset(460, 340),
})
if not Window then
	unmute(BlastSequence)
	seqConn:Disconnect()
	if noticeConn then
		noticeConn:Disconnect()
	end
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:bolt-bold" })
local Card = Tab:Section({
	Title = "Blast",
	Desc = "Fires the whole sequence and skips the cutscene",
	Icon = "solar:bolt-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})

local farmToggle -- forward: stopFarm flips it back when the loop quits on its own
local status = Card:Paragraph({ Title = "Status", Desc = "idle" })

local function say(msg)
	status:SetDesc(msg)
end

-- farm -----------------------------------------------------------------------
local on, fullCharge = false, false
local gen = 0 -- toggling off then on inside one interval must not leave two loops
local count, misses = 0, 0
local gap = GAP_MAX -- shortens toward whatever the server allows; see the config
local gapFrozen = false -- set by the first refusal: we found the floor, stop descending

-- Calibration is two probes and a comparison, not a distance threshold: the distance
-- you should reach moves with your Power, so any hardcoded number goes stale. Probe 1
-- claims the full charge instantly, probe 2 actually waits it out. Same distance means
-- the server took our word for it; a materially longer probe 2 means it runs its own
-- timer and instant blasts are being clamped to nothing.
local mode = nil -- nil = still probing, "instant" = server trusts the sent value
local probe = {}

-- Flip the switch first, say why second: Set fires the toggle's own callback, which
-- writes "stopped after N" over the status. Ours has to land last or the reason we
-- stopped -- the whole point of stopping instead of carrying on -- scrolls away unseen.
local function stopFarm(msg)
	on = false
	gen = gen + 1
	if farmToggle then
		farmToggle:Set(false)
	end
	say(msg)
	warn("[PowerBlast] " .. msg)
end

local function holdFor()
	if fullCharge then
		return CHARGE_HOLD
	end
	if mode == "instant" then
		return 0
	end
	return #probe == 0 and 0 or CHARGE_HOLD -- probe 1 instant, probe 2 full
end

-- Returns false when the run should stop. Calibration only runs while Full charge is
-- off; flipping it on is you overriding the probe, so we skip straight to farming.
local function calibrate(distance)
	if fullCharge or mode ~= nil then
		return true
	end
	probe[#probe + 1] = distance
	if #probe == 1 then
		say(("probe 1 (instant): %d studs"):format(distance))
		return true
	end
	local d1, d2 = probe[1], probe[2]
	if d2 > d1 * (1 + CALIB_TOL) then
		stopFarm(
			("server times the charge: %d studs instant vs %d full. Flip Full charge and start again."):format(d1, d2)
		)
		return false
	end
	mode = "instant"
	say(("calibrated: instant (%d vs %d studs)"):format(d1, d2))
	return true
end

local function loop(mine)
	while on and gen == mine do
		local t0 = os.clock()
		local ok, r, why, refused = pcall(oneBlast, holdFor())
		if not ok then
			r, why = nil, tostring(r) -- pcall put the error where the result goes
		end

		if r and r.paid then
			misses = 0
			count = count + 1
			-- Cycle seconds is the number to watch: it is what "quicker" means, and it
			-- is the only way to tell a gap that found the floor from one still walking.
			say(("#%d  %d studs  %s  %.2fs  gap %.2f%s"):format(
				count,
				r.distance,
				r.rarity,
				os.clock() - t0,
				gap,
				gapFrozen and "" or " v"
			))
			-- Shorten only after a blast that actually worked, so the descent is paid
			-- for by results rather than by refusals.
			if not gapFrozen then
				gap = math.max(GAP_MIN, gap - GAP_STEP)
			end
			if not calibrate(r.distance) then
				return
			end
		elseif refused then
			-- We went one step too far. Step back and stay -- that step was the floor.
			gap = math.min(GAP_MAX, gap + GAP_STEP)
			gapFrozen = true
			say(("%s -- settled at gap %.2f"):format(why, gap))
			if gap >= GAP_MAX then
				misses = misses + 1 -- at the ceiling it stops being a tuning problem
				if misses >= MAX_MISSES then
					stopFarm("starts refused even at the full cooldown -- stopped")
					return
				end
			end
		else
			misses = misses + 1
			local reason = why or "blast paid nothing"
			if misses >= MAX_MISSES then
				stopFarm(("gave up after %d: %s"):format(misses, reason))
				return
			end
			say(("%s (x%d)"):format(reason, misses))
			task.wait(1)
		end

		if on and gen == mine then
			waitReady(gap)
		end
	end
end

-- wiring ---------------------------------------------------------------------
farmToggle = Card:Toggle({
	Title = "Auto Blast",
	Desc = "start -> release -> grant -> return, on a loop",
	Value = false,
	Callback = function(state)
		on = state
		gen = gen + 1
		if not state then
			say(("stopped after %d"):format(count))
			return
		end
		-- Start the descent over. Without this a run that froze early would keep the
		-- slow gap for the rest of the session even after the cause passed.
		gap, gapFrozen, misses = GAP_MAX, false, 0
		local mine = gen
		task.spawn(loop, mine)
	end,
})

Card:Toggle({
	Title = "Full charge",
	Desc = "Hold the real " .. CHARGE_HOLD .. "s before releasing, and skip the probe",
	Value = false,
	Callback = function(state)
		fullCharge = state
		-- The probe measured the other mode; it says nothing about this one.
		mode, probe = nil, {}
	end,
})

-- x2 power -------------------------------------------------------------------
-- Archetype C, and about as pure as it gets: the server offers a token, and the only
-- thing standing between it and the multiplier is clicking a circle. AuraHudController
-- drops that circle at a random spot on screen with an expiresIn on it and answers with
-- AuraMultiplierClicked(token); there is nothing else in the round trip to reproduce.
-- Muting the HUD's listener means the circle is never drawn -- answer it without muting
-- and it still appears, then sits there until it times out and reports itself missed.
-- Worth having on while farming: Power is what gates the blast zones, so this feeds the
-- thing that decides your rarity rather than just running alongside it.
-- Its own card: both of these feed Power, which is upstream of the blast rather than
-- part of it, and both keep a status line that would otherwise fight the blast's.
local Power = Tab:Section({
	Title = "Power",
	Desc = "Feeds the stat that decides which zone your blast reaches",
	Icon = "solar:bolt-circle-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})

local AuraMultiplierPrompt = Remotes:FindFirstChild("AuraMultiplierPrompt")
local AuraMultiplierClicked = Remotes:FindFirstChild("AuraMultiplierClicked")
local x2Conn, x2Count = nil, 0
local x2Row = Power:Paragraph({ Title = "x2 power", Desc = "off" })

Power:Toggle({
	Title = "Auto x2 power",
	Desc = "Answers the multiplier prompt the instant it lands",
	Value = false,
	Callback = function(state)
		if not (AuraMultiplierPrompt and AuraMultiplierClicked) then
			x2Row:SetDesc("no multiplier prompt in this game")
			return
		end
		if not state then
			if x2Conn then
				x2Conn:Disconnect()
				x2Conn = nil
			end
			unmute(AuraMultiplierPrompt)
			x2Row:SetDesc(("off after %d"):format(x2Count))
			return
		end
		mute(AuraMultiplierPrompt) -- before connecting ours, same rule as the cutscene
		x2Conn = AuraMultiplierPrompt.OnClientEvent:Connect(function(p)
			if type(p) == "table" and p.token then
				AuraMultiplierClicked:FireServer(p.token)
				x2Count = x2Count + 1
				x2Row:SetDesc(("%d taken"):format(x2Count))
			end
		end)
		x2Row:SetDesc(x2Count > 0 and ("armed, %d taken"):format(x2Count) or "armed")
	end,
})

-- aura ----------------------------------------------------------------------
-- There is nothing to spam here. AuraPulse and AuraPowerGain are both OnClientEvent,
-- the only outbound aura remotes buy things, and AuraEquipped -- like BlastBusy -- is
-- only ever read on the client, so the server owns it. Power accrues on its own for as
-- long as the tool is equipped, and AuraStageController's "Stage" is just the glowing
-- platform it draws under you, so there is no place you have to stand either.
-- Which makes the whole feature: keep the tool equipped. It composes with the blast
-- loop for free, because neither one wants anything from the other.
-- Found by shape, per the usual rule -- the tool carries AuraTool=true and an AuraId,
-- so this survives it being renamed or moved between backpack and character.
local function auraTool()
	for _, where in ipairs({ player:FindFirstChildOfClass("Backpack"), player.Character }) do
		for _, v in ipairs(where and where:GetChildren() or {}) do
			if v:IsA("Tool") and v:GetAttribute("AuraTool") == true then
				return v
			end
		end
	end
	return nil
end

local auraRow = Power:Paragraph({ Title = "Aura", Desc = "off" })
local auraOn, auraGen = false, 0

-- What the next blast will actually roll from, and what it takes to move up a tier. Both
-- go through the game's own functions: the top zones sit behind release feature flags, so
-- a raw scan of BlastConfig.Zones would name one the server has switched off.
-- This is also the readout that answers "is the aura farming while I blast" -- with the
-- unequip suppressed the number climbs during a blast, not only between blasts.
local function powerLine()
	local p = tonumber(player:GetAttribute("Power") or player:GetAttribute("Strength")) or 0
	if not (BlastConfig and BlastConfig.GetZoneForPower) then
		return ("power %s"):format(short(p))
	end
	local okZone, zone = pcall(BlastConfig.GetZoneForPower, p)
	local okAll, zones = pcall(BlastConfig.GetActiveZones)

	local nextName, nextAt
	for _, z in ipairs(okAll and zones or {}) do
		local m = tonumber(z.MinPower) or 0
		if m > p and (not nextAt or m < nextAt) then
			nextName, nextAt = z.Name, m
		end
	end

	return ("power %s  |  %s%s"):format(
		short(p),
		okZone and zone and tostring(zone.Name) or "?",
		nextAt and (" -> %s at %s"):format(nextName, short(nextAt)) or " (top zone)"
	)
end

-- Something else wants your hands: every blast reward arrives as a Tool and ends up
-- equipped without anyone asking. The one client path that does that -- BlastRewardEquip,
-- through BlastController:4808 -- sits inside the finale we mute, so this is the server,
-- which means it cannot be switched off, only answered. It used to be invisible because
-- the controller's own ChildAdded handler stripped every tool as it arrived; suppressing
-- that is what let the brainrot stay in your hand.
-- Answered against the world rather than the attribute: the tool's Parent is the truth on
-- this client already, where AuraEquipped is the server's opinion arriving a ping later
-- and reads "equipped" through the whole window we are trying to close. EquipTool takes
-- whatever is held out first, so the swap is the one call.
local function holdAura()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local tool = auraTool()
	if not (hum and tool) then
		return tool
	end
	if tool.Parent ~= char then
		pcall(function()
			hum:EquipTool(tool)
		end)
	end
	return tool
end

-- ponytail: a poll rather than a Character.ChildAdded hook that answers the tool the frame
-- it lands. The poll survives respawns for free where the hook needs re-arming on every
-- character, and 0.25s of a brainrot costs ~8% of the rate. Swap if that 8% ever matters.
Power:Toggle({
	Title = "Keep aura equipped",
	Desc = "Takes the aura back off the blast rewards the server equips for you",
	Value = false,
	Callback = function(state)
		auraOn = state
		auraGen = auraGen + 1
		if not state then
			auraRow:SetDesc("off")
			return
		end
		local mine = auraGen
		task.spawn(function()
			while auraOn and auraGen == mine do
				local tool = holdAura()
				if not tool then
					auraRow:SetDesc("no aura tool in the backpack")
				else
					-- The attribute, not the parent, for the readout: this line is about
					-- whether the SERVER is paying you, and that is the thing it says.
					auraRow:SetDesc(
						("%s %s  |  %s"):format(
							tostring(tool:GetAttribute("AuraId") or "aura"),
							player:GetAttribute("AuraEquipped") == true and "on" or "off",
							powerLine()
						)
					)
				end
				task.wait(AURA_POLL)
			end
		end)
	end,
})

-- plot cash ------------------------------------------------------------------
-- CollectButtonController collects on a Heartbeat, but only the slot whose
-- CollectBtn.TouchPart you are within 4.5 studs of (:924) -- and the blast pad is not
-- your plot, so cash sits there for the whole farm. We fire the same remote it fires,
-- for every slot, without the walk. CollectAllSlots is the one-call version but the
-- client gates it on IsVIP (:549), so it goes out only as a free extra.
-- SlotCash is the server's own pending figure on the slot part, which makes it both the
-- thing we are collecting and the only honest proof it landed -- CollectSlot is an event
-- and tells us nothing. If the server range-checks us as well, that shows up as cash
-- that never drops, and the status says so instead of counting money we never got.
local CollectSlot = Remotes:FindFirstChild("CollectSlot")
local CollectAllSlots = Remotes:FindFirstChild("CollectAllSlots")

local function money(n)
	return "$" .. short(n)
end

-- By owner attribute, not by lot name: which Lot_N you get is per-server.
local function myLot()
	local lots = workspace:FindFirstChild("Lots")
	for _, lot in ipairs(lots and lots:GetChildren() or {}) do
		if lot:GetAttribute("OwnerId") == player.UserId then
			return lot
		end
	end
	return nil
end

-- The same shape test the game uses: a BasePart named Slot_<n> inside a PlacementGrid.
-- Descendants rather than children because each unlocked floor brings its own grid
-- (Lot.Floor2.PlacementGrid...), and SlotIndex is offset per floor -- Floor2's Slot_10 is
-- 210 -- so the index on its own is all the server needs.
local function slotsOf(lot)
	local out = {}
	for _, v in ipairs(lot:GetDescendants()) do
		if v:IsA("BasePart") and v.Name:match("^Slot_%d+$") and v.Parent and v.Parent.Name == "PlacementGrid" then
			out[#out + 1] = v
		end
	end
	return out
end

local function pendingCash(list)
	local sum = 0
	for _, s in ipairs(list) do
		sum = sum + (tonumber(s:GetAttribute("SlotCash")) or 0)
	end
	return sum
end

local Plot = Tab:Section({
	Title = "Plot",
	Desc = "The cash your placed brainrots make while you are on the pad",
	Icon = "solar:wallet-money-bold",
	Box = true,
	BoxBorder = true,
	Opened = true,
})
local cashRow = Plot:Paragraph({ Title = "Plot cash", Desc = "off" })
local cashOn, cashGen, cashTotal, cashDead = false, 0, 0, 0

Plot:Toggle({
	Title = "Auto collect plot cash",
	Desc = "Collects every slot on your lot, from wherever you are standing",
	Value = false,
	Callback = function(state)
		cashOn = state
		cashGen = cashGen + 1
		if not state then
			cashRow:SetDesc(("off after %s"):format(money(cashTotal)))
			return
		end
		if not CollectSlot then
			cashRow:SetDesc("no CollectSlot remote in this game")
			return
		end
		local mine = cashGen
		task.spawn(function()
			while cashOn and cashGen == mine do
				local lot = myLot()
				if not lot then
					cashRow:SetDesc("no lot here with your OwnerId")
				else
					local list = slotsOf(lot)
					local before = pendingCash(list)
					if before <= 0 then
						cashRow:SetDesc(("idle, %s collected"):format(money(cashTotal)))
					else
						for _, s in ipairs(list) do
							if (tonumber(s:GetAttribute("SlotCash")) or 0) > 0 then
								CollectSlot:FireServer(s:GetAttribute("SlotIndex"))
							end
						end
						if CollectAllSlots and player:GetAttribute("IsVIP") == true then
							CollectAllSlots:FireServer()
						end
						task.wait(CASH_SETTLE)
						local got = before - pendingCash(list)
						if got > 0 then
							cashTotal, cashDead = cashTotal + got, 0
							cashRow:SetDesc(("+%s  (%s total)"):format(money(got), money(cashTotal)))
						else
							cashDead = cashDead + 1
							cashRow:SetDesc(
								cashDead >= MAX_MISSES
										and ("%s pending and none of it lands -- the server wants you on your plot"):format(
											money(before)
										)
									or ("%s pending, waiting on the server"):format(money(before))
							)
						end
					end
				end
				task.wait(CASH_POLL)
			end
		end)
	end,
})

-- A blast reward arrives as a Tool in the backpack, and a brainrot in the backpack earns
-- nothing -- so without this the collector above sweeps a plot that never grows.
-- RequestEquipBestBrainrots is a RemoteFunction taking no arguments at all: the server
-- picks the slots itself, and it is not position gated, so the whole feature is one call.
-- Its own switch rather than riding along with the collector, because it also pulls WORSE
-- brainrots off slots they are already on -- a plot you arranged by hand is yours to keep.
local RequestEquipBestBrainrots = Remotes:FindFirstChild("RequestEquipBestBrainrots")

-- Gated on the backpack, since that is the only thing the call can act on: with nothing
-- waiting it is a round trip for a no-op.
local function waitingBrainrots()
	local pack = player:FindFirstChildOfClass("Backpack")
	local n = 0
	for _, v in ipairs(pack and pack:GetChildren() or {}) do
		if v:GetAttribute("BrainrotId") then
			n = n + 1
		end
	end
	return n
end

local seatRow = Plot:Paragraph({ Title = "Seat brainrots", Desc = "off" })
local seatOn, seatGen, seatTotal = false, 0, 0

Plot:Toggle({
	Title = "Auto seat best brainrots",
	Desc = "Hands the blast's winnings to the server to place. Replaces weaker ones",
	Value = false,
	Callback = function(state)
		seatOn = state
		seatGen = seatGen + 1
		if not state then
			seatRow:SetDesc(("off after %d seated"):format(seatTotal))
			return
		end
		if not RequestEquipBestBrainrots then
			seatRow:SetDesc("no RequestEquipBestBrainrots remote in this game")
			return
		end
		local mine = seatGen
		task.spawn(function()
			while seatOn and seatGen == mine do
				local waiting = waitingBrainrots()
				if waiting > 0 then
					local reply = invoke(RequestEquipBestBrainrots)
					local changed = type(reply) == "table" and (tonumber(reply.changed) or 0) or nil
					if changed == nil then
						seatRow:SetDesc(("%d waiting, no reply from the server"):format(waiting))
					elseif changed > 0 then
						seatTotal = seatTotal + changed
						seatRow:SetDesc(("seated %d  (%d this session)"):format(changed, seatTotal))
					else
						-- Every slot already holds something better, so the backpack is
						-- just where the losing rolls live. Not a fault.
						seatRow:SetDesc(("%d waiting, none of them beat what is placed"):format(waiting))
					end
				else
					seatRow:SetDesc(("idle, %d seated"):format(seatTotal))
				end
				task.wait(SEAT_POLL)
			end
		end)
	end,
})

-- BlastController.lua:781 hangs a Character.ChildAdded on you that unequips every Tool
-- as it arrives, and only cleanupCutscene (:869) takes it off. Mute the controller
-- between those two and it is stranded: tools bounce straight back to the backpack for
-- the rest of the session. The guard above catches the post-release window, but
-- lockCutsceneEquipment runs a whole charge phase before BlastCutsceneActive is set, so
-- enabling this mid-charge still strands one and there is no attribute that says so.
-- The connection belongs to the character, so a fresh character is the whole cure.
-- ponytail: respawn rather than hunting the connection. getconnections gives 15 on
-- ChildAdded with no way to tell which is the controller's; picking it out means
-- reading debug.info off each one, which not every executor allows. Swap to that if
-- respawning ever costs something here.
Card:Button({
	Title = "Fix hotbar",
	Desc = "Respawns you. Use if equipped tools jump back to the backpack",
	Callback = function()
		if farmToggle then
			farmToggle:Set(false) -- the loop would fight the respawn for the pad
		end
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not hum then
			say("no character to respawn")
			return
		end
		say("respawning -- the stranded unequip handler dies with the old character")
		hum.Health = 0
	end,
})

-- close ----------------------------------------------------------------------
local function stopAll()
	on = false
	gen = gen + 1
	-- Stopping mid-blast leaves the server thinking we are still in one. The return is
	-- what clears that; without it the next blast, ours or a manual one, is refused.
	local token = liveReturnToken()
	if token then
		pcall(function()
			RequestBlastReturn:FireServer({ token = token, reason = "normal_return" })
		end)
	end
	-- Only ever clears a progress bar stranded by a manual blast -- we suppress the
	-- controller before it shows one of its own.
	if BlastProgressSync then
		pcall(function()
			BlastProgressSync:FireServer({ action = "hide" })
		end)
	end
	unmute(BlastSequence)
	seqConn:Disconnect()
	if noticeConn then
		noticeConn:Disconnect()
	end
	if x2Conn then
		x2Conn:Disconnect()
		x2Conn = nil
	end
	unmute(AuraMultiplierPrompt)
	auraOn = false
	auraGen = auraGen + 1
	cashOn = false
	cashGen = cashGen + 1
	seatOn = false
	seatGen = seatGen + 1
	-- Hand BlastBusy back to the server. Leaving these connected would keep the game's own
	-- blast, after we are gone, from ever locking the camera or the hotbar.
	for _, c in ipairs(hushConns) do
		c:Disconnect()
	end
end

Window:OnDestroy(function()
	stopAll()
	getgenv().powerBlastStop = nil
end)

getgenv().powerBlastStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().powerBlastStop = nil
end

print("[PowerBlast] loaded -- cutscene skip:", quiet and "on" or "NO getconnections, animation stays")
if not quiet then
	say("no getconnections -- the cutscene stays, but the loop still runs")
end
