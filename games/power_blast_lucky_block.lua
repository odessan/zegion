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
     KEEP AURA    : re-equips the aura tool whenever anything drops it. That is the
                    whole of "farm the aura" -- power accrues passively while it is
                    equipped, with no click to spam and no place to stand, so it runs
                    alongside the blast loop without either noticing the other.
     FIX HOTBAR   : respawns you. Enabling the farm during a manual blast's charge
                    phase strands the controller's tool-unequip handler and every
                    equip afterwards is undone; a fresh character clears it.

     Rarity is a function of flight distance, and distance is gated by your Power
     (BlastConfig.Zones: Common at MinPower 0 ... Godly at 12e12), not by charge.
     Charge only decides how much of your reach you actually get, so we always claim
     the maximum and there is no charge knob worth putting on the panel.

     Executor only: WindUI for the panel, getconnections for the cutscene skip.
     Stop: getgenv().powerBlastStop() ]]

-- config ---------------------------------------------------------------------
-- BlastConfig.CHARGE_FULL_SECONDS is 2.67, and the real client sends whatever
-- os.clock() handed it, which overshoots -- the spy log reads 2.7922602083418. Send
-- the same shape: a hair over full, never under. Undershooting costs flight distance
-- and distance is the rarity roll.
local CHARGE_SEND = 2.79
-- What we actually wait in full-charge mode. Just over CHARGE_FULL_SECONDS so the
-- server's own timer has certainly elapsed. Raise it if full-charge blasts still come
-- back short.
local CHARGE_HOLD = 2.72
-- The pause after BlastBusy clears, before the next start. Self-tuning, and it starts
-- at GAP_MAX -- BlastConfig.COOLDOWN, the client's own number and therefore known-good
-- -- then shortens by GAP_STEP after every blast that works. The first refusal steps
-- back up and freezes there.
-- Walking down rather than up because the cost is measured in refusals: from 0.05
-- upwards a 2.5s cooldown takes ~17 refused starts and 17 "Blast is cooling down"
-- toasts to find. Downwards it costs exactly one, and every blast before it counted.
-- ponytail: freezes on the first refusal instead of hunting around the boundary.
-- Toggling off and on starts the descent again.
local GAP_MIN = 0.05
local GAP_STEP = 0.15
local GAP_MAX = 2.5
-- Split, because they fail for different reasons. A refused start is the normal way we
-- find the cooldown floor and has to be cheap; a missing fire after the server already
-- accepted the start is a real fault and worth waiting on.
local BEGIN_TIMEOUT = 1.5
local FIRE_TIMEOUT = 5
-- How long to wait for BlastBusy to drop before blasting anyway.
local BUSY_TIMEOUT = 6
-- After teleporting back onto the pad, how long the server needs to see us there.
local SETTLE = 0.35
-- Calibration: how much further a full-charge blast must fly before we call the
-- instant one clamped. Distance has natural spread, so this is not zero.
local CALIB_TOL = 0.15
-- Consecutive bad blasts -- no reward, no reply, no zone -- before we stop and say so.
-- The server quietly paying nothing looks exactly like the server paying, without this.
local MAX_MISSES = 3

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

-- BlastBusy is set by the server and only ever read on the client, so it is the one
-- honest "you may blast again" signal available to us. Wait on it, then gap.
local function waitReady(gap)
	waitFor(function()
		return player:GetAttribute("BlastBusy") ~= true or nil
	end, BUSY_TIMEOUT)
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

-- ponytail: a 1s poll rather than GetAttributeChangedSignal("AuraEquipped"). The signal
-- only fires on a change, so it never tells us about the state we started in, and the
-- poll would still be needed as the backstop. One loop beats a signal plus a loop.
Power:Toggle({
	Title = "Keep aura equipped",
	Desc = "Re-equips the aura whenever anything drops it",
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
				local tool = auraTool()
				if not tool then
					auraRow:SetDesc("no aura tool in the backpack")
				elseif player:GetAttribute("AuraEquipped") == true then
					auraRow:SetDesc(("equipped (%s)"):format(tostring(tool:GetAttribute("AuraId") or "?")))
				else
					local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
					if hum then
						pcall(function()
							hum:EquipTool(tool)
						end)
						auraRow:SetDesc("re-equipping")
					end
				end
				task.wait(1)
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
