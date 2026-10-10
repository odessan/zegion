--[[ Assassins Leveling -- hop-run every stage for Wins, train on the best zone, buy blades and auras (120731410233153)

     WIN     : the game's win pad pays Wins by stage (3 worlds, 48 stages, up to 22.8B x2 for the last). The server wants every
               stage cleared in order, and the mobs are CLIENT clones, so a clear is a Humanoid at 0 Health: the script sets it,
               the game's own controller reports Limpio(stage, true), and a hop of 40 studs every 0.15s down the stage lane
               clears the lot in about 6s. At the last pad the game pays and the server sends you back to the hub. World 1
               stage 18 = 500k per run, World 2 stage 33 = 250M, World 3 stage 48 = 22.8B (all x2). Always the top world you
               have unlocked (Mundo "viajar" from the portal zone; a world opens by clearing the last stage of the one before).
     TRAIN   : the best AFK zone your rebirths open (x1.5 at 0, x3 at 2, x5 at 5, x8 at 9, x11 at 14, World 2 x12 at 14 ...).
               The server pays Strength for standing on it, so the script just hops onto it and stays.
     TAP     : Click:FireServer() at 5 a second. The server caps it there: 5/s tripled a zone's Strength, 10 and 20 a second
               paid the same.
     BLADES  : the next blade by Wins, pressed on its pad (hop next to it, fireproximityprompt, confirm on Daga_N). It
               equips itself. Blades 1-13 sit in World 1's hub, 14-26 in World 2's, 27-39 in World 3's.
     AURAS   : Aura_Equip(id) BUYS an aura you can afford (reqWins is the price) and equips it; the script buys the best
               multiplier it can pay for and keeps the best one equipped.
     QUESTS  : Misiones "pedir" lists them; every one with progress >= goal is claimed ("reclamar", tab, index), plus the
               all-done bonus.
     ITEMS   : pick the stat to maximise (strength, damage, crit, crit damage, health, speed, trophies): the script clears
               the slots and equips the owned items with the highest percentage for it ("limpiar" + "equipar" id). "Game's
               best" leaves it to the game's own "mejores".
     REBIRTH : Rebirth the moment the level meets RebirthMeta. Probed: Strength drops (297M -> 12M) and the level with it;
               Wins, blades and auras stay; MultRebirth +1 and the zone row after it opens.

     World 4 (stages 49-63) exists but the server stopped crediting Limpio at stage 52 with 1.4e19 Strength (51, recommended
     1.1e21, was credited; 52, 1.7e21, was not; 20s lingering changed nothing). A run that hops the whole lane and ends short of
     the last stage parks that world until Strength doubles and runs the world below (World 3: +22.8B in 7s). The Strength
     rule itself is a guess: the server side is not visible.

     Probed and dead: Limpio or WinPadToque fired from the lobby or from afar (silent); standing on a win pad without the
     stage clears (silent, 80s); Click above 5/s (no gain). Not wired (Robux): the x2 win pads, Aura_BuyRobux, the skip
     products, Offline x2.

     Hops: 40 studs/0.15s chains held in all three worlds with no revert and no kick (the lobby also took single hops of
     80). Slash per Click kicked a 300-stud one, so legs stay at 40.

     RightControl opens / closes the panel. Stop: getgenv().assassinsLevelingStop() ]]

-- config ---------------------------------------------------------------------
local HOP_STEP = 40 -- studs per hop in a win run. Held for 18/33/48 stages at 0.15s; raise only after a clean run
local HOP_GAP = 0.15 -- seconds between win-run hops; the mobs need a beat to spawn and die before the barrier
local LEG = 40 -- longest single hop outside a run (portal, blade pad, zone). Lobby hops of 80 held; 300 is a kick elsewhere
local LEG_GAP = 0.12
local TAP_GAP = 0.19 -- the server takes 5 clicks a second; faster pays nothing
local RUN_MAX_HOPS = 140 -- a run that is not paid by then gave up (a lane is under 80 hops)
local RUN_TIMEOUT = 60
local SPEND_EVERY = 3 -- aura and rebirth beat
local CLAIM_EVERY = 20 -- quest beat
local ITEMS_EVERY = 30
local ZONE_CHECK = 1
local PARK = 60 -- a blade or aura that was refused is left alone this long
local STUCK_AFTER = 40

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local VirtualUser = game:GetService("VirtualUser")
local player = Players.LocalPlayer

if getgenv and getgenv().assassinsLevelingStop then
	getgenv().assassinsLevelingStop() -- re-running must not stack a second panel or loop
end

local function log(...)
	print("[assassins]", ...)
end

local seen = {}
local function first(name, ...) -- one console line per unproven branch
	if not seen[name] then
		seen[name] = true
		log(name, ...)
	end
end

-- The panel strip is drained from a Heartbeat, which the engine calls with our own identity.
local pending, lastSaid = {}, nil
local function say(msg)
	pending.now = msg
	if msg ~= lastSaid then
		lastSaid = msg
		log(msg)
	end
end

-- breadcrumb: the watchdog thread (separate, so a parked director can still be reported)
local mark, markAt = "idle", os.clock()
local function step(s)
	mark, markAt = s, os.clock()
end

-- game -----------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
local Shared = ReplicatedStorage:WaitForChild("Shared", 15)
local function req(name)
	local m = Shared and Shared:WaitForChild(name, 15)
	local ok, v = pcall(require, m)
	return ok and v or nil
end
local Mundos, Armas, AuraData, Areas, Objetos, Pases = req("Mundos"), req("Armas"), req("AuraData"), req("Areas"), req("Objetos"), req("Pases")
if not (Remotes and Mundos and Armas and AuraData and Areas and Objetos and Pases) then
	warn("[assassins] the game's modules did not load")
	return
end
local R = {}
for _, name in ipairs({ "Click", "Rebirth", "Mundo", "Misiones", "Objetos", "Aura_Equip" }) do
	R[name] = Remotes:WaitForChild(name, 10)
end

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function fmt(n)
	n = tonumber(n) or 0
	local i = 1
	while n >= 1000 and i < #SUFFIX do
		n /= 1000
		i += 1
	end
	return ("%.3g"):format(n) .. SUFFIX[i]
end
assert(fmt(25000) == "25K" and fmt(1500) == "1.5K" and fmt(260e9) == "260B" and fmt(100) == "100", "fmt")

local function attr(name, default)
	return tonumber(player:GetAttribute(name)) or default
end
local function wins()
	return attr("Wins", 0)
end
local function worldNow()
	return attr("Mundo", 1)
end
-- A world whose run stalled short of its last stage (the server stopped taking Limpio: World 4 at stage 52 with 1.4e19
-- Strength) is left alone until Strength has grown by WORLD_RETRY, and the run goes to the next world down.
local WORLD_RETRY = 2
local worldCap = {} -- [world] = Strength it stalled at
local function topWorld()
	local fuerza = attr("Fuerza", 0)
	for w = math.min(attr("MundoMax", 1), #Mundos.LISTA), 2, -1 do
		if not (worldCap[w] and fuerza < worldCap[w] * WORLD_RETRY) then
			return w
		end
	end
	return 1
end

-- state ----------------------------------------------------------------------
local dead, gen = false, 0
local winOn, trainOn, tapOn, bladesOn, aurasOn, questsOn, itemsOn, rebirthOn = false, false, false, false, false, false, false, false
local itemStat = "Auto"
local conns = {} -- RBXScriptConnections, disconnected on unload
local tokens = {} -- side-loop generation tokens; clearing the table ends the loops
local parked = {} -- [key] = os.clock() it may be tried again
local stats = { runs = 0, won = 0, blades = 0, auras = 0, rebirths = 0, claims = 0 }
local lastRun = 0

local function isParked(key)
	return (parked[key] or 0) > os.clock()
end

local function waitFor(cond, secs)
	local t = os.clock()
	while not cond() and os.clock() - t < secs do
		task.wait(0.1)
	end
	return cond()
end

-- movement: hops, legs only (see header) -----------------------------------------
local function character()
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	local root = ch and ch:FindFirstChild("HumanoidRootPart")
	if hum and root and hum.Health > 0 then
		return hum, root
	end
	return nil, nil
end

-- true when we ended within 8 studs of pos
local function hopTo(pos)
	local _, root = character()
	if not root then
		return false
	end
	local from = root.Position
	local n = math.max(1, math.ceil((from - pos).Magnitude / LEG))
	for i = 1, n do
		local _, r = character()
		if not r then
			return false
		end
		r.CFrame = CFrame.new(from:Lerp(pos, i / n))
		r.AssemblyLinearVelocity = Vector3.zero
		task.wait(LEG_GAP)
	end
	task.wait(0.15)
	local _, r = character()
	return r ~= nil and (r.Position - pos).Magnitude < 8
end

-- the portal's own zone part: standing in it is what lets "viajar" through
local function portalPart()
	local _, root = character()
	if not root then
		return nil
	end
	local best, bd
	for _, p in ipairs(CollectionService:GetTagged("PortalMundo")) do
		local zp = p:FindFirstChild("ZonaPortal")
		local part = zp and zp:FindFirstChildWhichIsA("BasePart", true)
		if part then
			local d = (part.Position - root.Position).Magnitude
			if not bd or d < bd then
				best, bd = part, d
			end
		end
	end
	return best
end

local function lobby()
	return player:GetAttribute("EnLobby") == true
end
local backToHub -- defined with the win run, which owns the lane lookup

-- Every errand starts in the hub (the portal, the blade pads and the zones are all there): a run that was cut short
-- (a toggle restarts the director) leaves us mid-lane, where none of them is streamed in.
local function ensureWorld(w, alive)
	if not lobby() then
		backToHub(worldNow(), alive or function()
			return not dead
		end)
	end
	if worldNow() == w then
		return true
	end
	if attr("MundoMax", 1) < w then
		return false
	end
	for _ = 1, 3 do
		step("travel to world " .. w)
		local part = portalPart()
		if part and hopTo(part.Position + Vector3.new(0, 3, 0)) then
			task.wait(0.8)
			pcall(R.Mundo.FireServer, R.Mundo, "viajar", w)
			if waitFor(function()
				return worldNow() == w
			end, 6) then
				task.wait(2.5) -- the fade, then the hub streams in
				return true
			end
		end
		task.wait(1)
	end
	return false
end

-- win run --------------------------------------------------------------------
-- the lane is the first stage's arena z plus 9 (the pads sit 16 off the centre, so z+9 passes beside them), floor y plus 4.9
local function laneOf(w)
	local info = Mundos.get(w) -- any streamed arena of this world will do: every stage of a world sits on one line
	for _, p in ipairs(CollectionService:GetTagged("ArenaPieza")) do
		local s = p:GetAttribute("Stage")
		if s and s >= info.primero and s <= info.ultimo and p:GetAttribute("Pieza") == "arena" then
			return p.Position.Z + 9, p.Position.Y + 4.9
		end
	end
	return nil, nil
end

local function findPad(w, stage)
	local root = Mundos.raiz(w)
	local st = root and root:FindFirstChild("STAGES")
	if not st then
		return nil
	end
	local name = ("Stage%02d_WinPad"):format(stage)
	for _, d in ipairs(st:GetDescendants()) do
		if d.Name == name and d:IsA("Model") then
			return d:FindFirstChild("Touch")
		end
	end
	return nil
end

-- clones live in workspace._MobsLocal on OUR client; at 0 Health the game's own controller opens the barrier and reports Limpio
local function killMobs()
	local f = workspace:FindFirstChild("_MobsLocal")
	if not f then
		return
	end
	for _, h in ipairs(f:GetDescendants()) do
		if h:IsA("Humanoid") and h.Health > 0 then
			h.Health = 0
		end
	end
end

-- a run that did not get paid leaves us mid-lane with LimpioHasta set; hopping back west to the hub resets it
function backToHub(w, alive)
	local lane, y = laneOf(w)
	local _, root = character()
	if not (root and lane) then
		return
	end
	local x = root.Position.X
	while alive() and not lobby() and x > -40 do
		x = math.max(x - HOP_STEP, -36)
		local _, r = character()
		if not r then
			return
		end
		r.CFrame = CFrame.new(x, y, lane)
		task.wait(HOP_GAP)
	end
	task.wait(1)
end

local function winRun(w, alive)
	local info = Mundos.get(w)
	local top = info.ultimo
	local lane, y = laneOf(w)
	if not lane then
		return false, "lane not streamed"
	end
	local _, root = character()
	if not root then
		return false, "no character"
	end
	if not lobby() then
		backToHub(w, alive)
	end
	step(("win run %d / start"):format(w))
	local con = RunService.Heartbeat:Connect(killMobs)
	local w0, t0 = wins(), os.clock()
	local x, started, back, hops, pad, nextSearch = root.Position.X, false, 0, 0, nil, 0
	local paid, why = false, "timeout"
	local ok, err = pcall(function()
		while alive() and os.clock() - t0 < RUN_TIMEOUT and hops < RUN_MAX_HOPS do
			local _, r = character()
			if not r then
				why = "no character"
				return
			end
			if not pad and os.clock() >= nextSearch then
				pad = findPad(w, top)
				nextSearch = os.clock() + 0.4
			end
			local tx, tz
			if pad and pad.Position.X - x < 25 then
				tx, tz = pad.Position.X, pad.Position.Z
			else
				tx, tz = math.min(x + HOP_STEP, pad and (pad.Position.X - 15) or math.huge), lane
			end
			local tgt = Vector3.new(tx, y, tz)
			r.CFrame = CFrame.new(tgt)
			r.AssemblyLinearVelocity = Vector3.zero
			hops += 1
			step(("win run %d / hop %d x=%d lim=%s"):format(w, hops, tx, tostring(player:GetAttribute("LimpioHasta"))))
			task.wait(HOP_GAP)
			if not lobby() then
				started = true
			end
			if started and lobby() then
				paid = true -- the pad paid and the server sent us back to the hub
				return
			end
			local _, r2 = character()
			if not r2 then
				why = "no character"
				return
			end
			if r2.Position.X < tgt.X - 25 then -- pulled backward by more than a barrier bump
				-- the pad's payout sends us to the hub a beat before EnLobby flips: that is a win, not a pull-back
				if started and waitFor(lobby, 1.5) then
					paid = true
					return
				end
				back += 1
				first("run pulled back", ("wanted x=%.0f got x=%.0f"):format(tgt.X, r2.Position.X))
				if back >= 3 then
					why = "pulled back 3 times"
					return
				end
				x = r2.Position.X
			else
				x = math.max(tx, r2.Position.X)
			end
		end
	end)
	con:Disconnect()
	if not ok then
		first("win run error " .. tostring(err), err)
		why = tostring(err)
	end
	if paid then
		task.wait(0.4)
		local got = wins() - w0
		stats.runs += 1
		stats.won += got
		lastRun = os.clock() - t0
		say(("run %d: +%s Wins in %.1fs (world %d, stage %d)"):format(stats.runs, fmt(got), lastRun, w, top))
		first("run paid", "world", w, "stage", top, "hops", hops, "wins", got)
		return true
	end
	local lim = attr("LimpioHasta", 0)
	log("run not paid", why, "world", w, "hops", hops, "limpio", lim)
	if why == "timeout" and w > 1 and lim < top then -- hopped the whole lane and the server stopped crediting stages
		worldCap[w] = attr("Fuerza", 0)
		say(("world %d stalls at stage %d: running world %d until Strength doubles"):format(w, lim + 1, topWorld()))
	end
	backToHub(w, alive)
	return false, why
end

-- blades ---------------------------------------------------------------------
local function nextBlade()
	local n = Armas.siguiente(player)
	if not n then
		return nil, math.huge, 0
	end
	return n, Armas.precio(n), Armas.mundo(n)
end

local function bladePad(n)
	local pads = workspace:FindFirstChild("PADS")
	pads = pads and pads:FindFirstChild("Pads")
	if not pads then
		return nil
	end
	for _, p in ipairs(pads:GetChildren()) do
		if p:GetAttribute("Index") == n then
			local led = p:FindFirstChild("Led")
			local eq = led and led:FindFirstChild("Equipar")
			local prompt = eq and eq:FindFirstChild("Prompt")
			if prompt then
				return led, prompt
			end
		end
	end
	return nil
end

local function errandBlade(n, w, alive)
	local key = "blade" .. n
	step("blade " .. n .. " / world")
	if not ensureWorld(w, alive) then
		parked[key] = os.clock() + PARK
		first("blade world refused", n, w)
		return
	end
	local led, prompt
	waitFor(function()
		led, prompt = bladePad(n)
		return led ~= nil or not alive()
	end, 4)
	if not led then -- the pads stream with the hub: go to its spawn and look again
		local spawn = Mundos.losaSpawn(w)
		if spawn then
			hopTo(spawn.Position + Vector3.new(0, 4, 0))
		end
		waitFor(function()
			led, prompt = bladePad(n)
			return led ~= nil or not alive()
		end, 4)
	end
	if not led then
		parked[key] = os.clock() + PARK
		first("blade pad not found", n, w)
		return
	end
	step("blade " .. n .. " / hop")
	if not hopTo(led.Position + Vector3.new(0, 3, 4)) then
		parked[key] = os.clock() + PARK
		first("blade hop failed", n)
		return
	end
	prompt.RequiresLineOfSight = false
	step("blade " .. n .. " / press")
	local owned = function()
		return player:GetAttribute("Daga_" .. n) == true
	end
	local t = os.clock()
	while not owned() and os.clock() - t < 3 and alive() do
		pcall(fireproximityprompt, prompt)
		task.wait(0.15)
	end
	if owned() then
		stats.blades += 1
		say(("bought blade %d (%s Wins)"):format(n, fmt(Armas.precio(n))))
	else
		parked[key] = os.clock() + PARK
		first("blade refused", n, "wins", wins(), "price", Armas.precio(n))
	end
end

-- auras ----------------------------------------------------------------------
local function auraBody()
	local owned = player:GetAttribute("OwnedAuras") or 0
	local cur = attr("AuraMult", 1)
	local have = wins()
	local buy, buyMult
	local bestOwned, bestOwnedMult
	for id, a in pairs(AuraData.Auras) do
		local isOwned = AuraData.hasAura(owned, id) or a.reqWins == 0
		if isOwned then
			if not bestOwnedMult or a.mult > bestOwnedMult then
				bestOwned, bestOwnedMult = id, a.mult
			end
		elseif not a.exclusiva and not a.soloRegalo and a.reqWins < math.huge and a.reqWins <= have and a.mult > (buyMult or cur) and not isParked("aura" .. id) then
			buy, buyMult = id, a.mult
		end
	end
	if buy then
		step("aura " .. buy)
		pcall(R.Aura_Equip.FireServer, R.Aura_Equip, buy) -- buys and equips; never Aura_BuyRobux
		if waitFor(function()
			return AuraData.hasAura(player:GetAttribute("OwnedAuras") or 0, buy)
		end, 2.5) then
			stats.auras += 1
			say(("bought aura %s (x%s)"):format(buy, tostring(buyMult)))
		else
			parked["aura" .. buy] = os.clock() + PARK
			first("aura refused", buy, "wins", have, "price", AuraData.Auras[buy].reqWins)
		end
	elseif bestOwned and bestOwnedMult > cur then
		pcall(R.Aura_Equip.FireServer, R.Aura_Equip, bestOwned) -- an owned one is only equipped
	end
end

-- the cheapest thing still ahead (blade or aura), what Wins have to reach before TRAIN may take over
local function needWins()
	local need = math.huge
	if bladesOn then
		local n, price, w = nextBlade()
		if n and not isParked("blade" .. n) and attr("MundoMax", 1) >= w then
			need = math.min(need, price)
		end
	end
	if aurasOn then
		local owned, cur = player:GetAttribute("OwnedAuras") or 0, attr("AuraMult", 1)
		for id, a in pairs(AuraData.Auras) do
			if not AuraData.hasAura(owned, id) and not a.exclusiva and not a.soloRegalo and a.reqWins < math.huge and a.mult > cur and not isParked("aura" .. id) then
				need = math.min(need, a.reqWins)
			end
		end
	end
	return need
end

-- rebirth --------------------------------------------------------------------
local function rebirthBody()
	if attr("Nivel", 0) >= attr("RebirthMeta", math.huge) then
		step("rebirth")
		local before = attr("Rebirths", 0)
		pcall(R.Rebirth.FireServer, R.Rebirth)
		if waitFor(function()
			return attr("Rebirths", 0) > before
		end, 4) then
			stats.rebirths += attr("Rebirths", 0) - before
			say(("rebirthed to %d"):format(attr("Rebirths", 0)))
		else
			first("rebirth refused", "nivel", attr("Nivel", 0), "meta", attr("RebirthMeta", 0))
		end
	end
end

-- quests ---------------------------------------------------------------------
local questState
table.insert(conns, R.Misiones.OnClientEvent:Connect(function(kind, data)
	if kind == "estado" then
		questState = data
	end
end))

local function questBody()
	step("quests")
	questState = nil
	pcall(R.Misiones.FireServer, R.Misiones, "pedir")
	if not waitFor(function()
		return questState ~= nil
	end, 3) then
		first("quests: no estado")
		return
	end
	local st = questState
	for _, tab in ipairs({ "d", "s" }) do
		for i, q in ipairs(st[tab] or {}) do
			if not q.c and q.p >= q.meta then
				pcall(R.Misiones.FireServer, R.Misiones, "reclamar", tab, i)
				stats.claims += 1
				first("quest claimed", tab, i, q.k)
				task.wait(0.5)
			end
		end
	end
	if st.todas and not st.bonusCobrado then
		pcall(R.Misiones.FireServer, R.Misiones, "reclamar", "b", nil)
		stats.claims += 1
		first("quest bonus claimed")
	end
end

-- items ----------------------------------------------------------------------
-- The owned items with the highest percentage for `stat` first, then the best of the rest to fill what is left.
local function pickItems(list, inv, stat, slots)
	local chosen, used = {}, {}
	local function take(pred)
		local c = {}
		for _, it in ipairs(list) do
			if (inv[tostring(it.id)] or inv[it.id]) and not used[it.id] and pred(it) then
				c[#c + 1] = it
			end
		end
		table.sort(c, function(a, b)
			if a.valor ~= b.valor then
				return a.valor > b.valor
			end
			return a.id < b.id
		end)
		for _, it in ipairs(c) do
			if #chosen < slots then
				chosen[#chosen + 1] = it.id
				used[it.id] = true
			end
		end
	end
	take(function(it)
		return it.stat == stat
	end)
	take(function()
		return true
	end)
	return chosen
end
do
	local list = { { id = 1, stat = "a", valor = 3 }, { id = 2, stat = "b", valor = 9 }, { id = 3, stat = "a", valor = 5 } }
	local inv = { ["1"] = 1, ["2"] = 1, ["3"] = 1 }
	local p = pickItems(list, inv, "a", 2)
	assert(p[1] == 3 and p[2] == 1 and #p == 2, "pickItems stat first")
	p = pickItems(list, inv, "a", 3)
	assert(p[1] == 3 and p[2] == 1 and p[3] == 2, "pickItems fills with the rest")
	assert(#pickItems(list, { [2] = 1 }, "a", 3) == 1, "pickItems numeric keys, nothing of the stat")
end

local STAT_OF = { -- dropdown text -> the stat key in Shared.Objetos
	["Strength"] = "strength",
	["Damage"] = "damage",
	["Crit chance"] = "crit",
	["Crit damage"] = "critdamage",
	["Health"] = "health",
	["Speed"] = "speed",
	["Trophies"] = "trophies",
}

local itemState
table.insert(conns, R.Objetos.OnClientEvent:Connect(function(kind, data)
	if kind == "estado" then
		itemState = data
	end
end))

local function itemsBody()
	if itemStat == "Auto" then
		pcall(R.Objetos.FireServer, R.Objetos, "mejores", nil) -- the game's own pick
		return
	end
	step("items")
	itemState = nil
	pcall(R.Objetos.FireServer, R.Objetos, "pedir")
	if not waitFor(function()
		return itemState ~= nil
	end, 3) then
		first("items: no estado")
		return
	end
	local slots = 0
	for i = 1, Objetos.ESPACIOS + Objetos.ESPACIOS_PASE do
		if Pases.casillaObjeto(player, i) then
			slots += 1
		end
	end
	local want = pickItems(Objetos.LISTA, itemState.inv or {}, STAT_OF[itemStat] or itemStat, slots)
	local have = {}
	for _, id in ipairs(itemState.eq or {}) do
		if id ~= 0 then
			have[#have + 1] = id
		end
	end
	local a, b = table.clone(want), table.clone(have)
	table.sort(a)
	table.sort(b)
	if table.concat(a, ",") == table.concat(b, ",") then
		return
	end
	pcall(R.Objetos.FireServer, R.Objetos, "limpiar", nil)
	task.wait(0.5)
	for _, id in ipairs(want) do
		pcall(R.Objetos.FireServer, R.Objetos, "equipar", id)
		task.wait(0.5)
	end
	say(("items for %s: %s"):format(itemStat, table.concat(want, ",")))
end

-- training -------------------------------------------------------------------
local function bestZone()
	local reb = attr("Rebirths", 0)
	local best
	for _, a in ipairs(Areas.LISTA) do
		if Areas.abierta(player, a, reb) and (not best or a.mult > best.mult) then
			best = a
		end
	end
	return best
end

local function trainStep(alive)
	local a = bestZone()
	if not a then
		return
	end
	local w = a.mundo or 1
	step("train / world " .. w)
	if not ensureWorld(w, alive) then
		first("train world refused", a.nombre, w)
		task.wait(2)
		return
	end
	local suelo
	waitFor(function()
		suelo = Areas.suelo(a)
		return suelo ~= nil or not alive()
	end, 4)
	if not suelo then
		first("zone not streamed", a.nombre)
		task.wait(1)
		return
	end
	local _, root = character()
	if not root then
		return
	end
	local stand = suelo.Position + Vector3.new(0, suelo.Size.Y / 2 + 3, 0)
	if player:GetAttribute("Zona") ~= a.nombre or (root.Position - stand).Magnitude > 12 then
		step("train / hop onto " .. a.nombre)
		hopTo(stand)
		if waitFor(function()
			return player:GetAttribute("Zona") == a.nombre
		end, 3) then
			first("on zone", a.nombre, "rebirths", attr("Rebirths", 0))
		else
			first("zone not entered", a.nombre, "at", tostring(root.Position))
		end
	end
	say(("training on %s"):format(a.nombre))
	task.wait(ZONE_CHECK)
end

-- director -------------------------------------------------------------------
local function director(mine)
	local function alive()
		return gen == mine and not dead and (winOn or trainOn or bladesOn)
	end
	local fails = 0
	while alive() do
		local ok, err = pcall(function()
			if bladesOn then
				local n, price, w = nextBlade()
				if n and wins() >= price and attr("MundoMax", 1) >= w and not isParked("blade" .. n) then
					errandBlade(n, w, alive)
					return
				end
			end
			local need = needWins()
			-- both on: Wins until the next blade and aura are paid for, then Strength; nothing left to buy means Strength
			local wantWin = winOn and (not trainOn or (need < math.huge and wins() < need))
			if wantWin then
				local w = topWorld()
				if not ensureWorld(w, alive) then
					first("win world refused", w)
					task.wait(2)
					return
				end
				local done, why = winRun(w, alive)
				if done then
					fails = 0
				else
					fails += 1
					say("run failed: " .. tostring(why))
					task.wait(math.min(10, fails * 2))
				end
			elseif trainOn then
				trainStep(alive)
			else
				step("director / idle")
				task.wait(1)
			end
		end)
		if not ok then
			first("director error " .. tostring(err), err)
			task.wait(2)
		end
		step("director / idle")
		task.wait(0.1)
	end
end

local function refreshDirector()
	gen += 1
	if (winOn or trainOn or bladesOn) and not dead then
		local mine = gen
		task.spawn(director, mine)
	end
end

local function loopFlag(name, flagGet, every, body)
	return function(on)
		if on then
			local token = {} -- a re-toggle inside one beat must not leave the old thread running
			tokens[name] = token
			task.spawn(function()
				while flagGet() and not dead and tokens[name] == token do
					local ok, err = pcall(body)
					if not ok then
						first(name .. " error " .. tostring(err), err)
					end
					task.wait(every)
				end
			end)
		else
			tokens[name] = nil
		end
	end
end

local setTap = loopFlag("tap", function()
	return tapOn
end, TAP_GAP, function()
	pcall(R.Click.FireServer, R.Click)
end)
local setRebirth = loopFlag("rebirth", function()
	return rebirthOn
end, SPEND_EVERY, rebirthBody)
local setAuras = loopFlag("auras", function()
	return aurasOn
end, SPEND_EVERY, auraBody)
local setQuests = loopFlag("quests", function()
	return questsOn
end, CLAIM_EVERY, questBody)
local setItems = loopFlag("items", function()
	return itemsOn
end, ITEMS_EVERY, itemsBody)

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Assassins Leveling", statusBar = true })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "swords")
local Farm = Tab:AddLeftGroupbox("Farm", "swords")
local Spend = Tab:AddRightGroupbox("Spend and claim", "coins")

Farm:AddToggle("Win", {
	Text = "Auto Win",
	Tooltip = "Hop-runs the stage lane of the highest world you have unlocked: clears every stage's mobs on your side, steps on the last pad for its Wins (up to 22.8B x2 per run in World 3), and the server sends you back. About 6s a run",
	Default = false,
	Callback = function(state)
		winOn = state
		pcall(refreshDirector)
		if not state then
			say("win off")
		end
	end,
})
Farm:AddToggle("Train", {
	Text = "Auto Train",
	Tooltip = "Stands on the best AFK zone your rebirths open and keeps you there (the server pays Strength for standing on it). With Auto Win also on, it trains whenever Wins are enough for the next blade and aura, and runs for Wins otherwise",
	Default = false,
	Callback = function(state)
		trainOn = state
		pcall(refreshDirector)
		if not state then
			say("train off")
		end
	end,
})
Farm:AddToggle("Tap", {
	Text = "Auto Tap",
	Tooltip = "Click 5 times a second, the most the server counts (it tripled a zone's Strength in the probe; 10 and 20 a second paid the same)",
	Default = false,
	Callback = function(state)
		tapOn = state
		pcall(setTap, state)
	end,
})
local farmLine = Farm:AddLabel("-", true)

Spend:AddToggle("Rebirth", {
	Text = "Auto Rebirth",
	Tooltip = "Rebirths as soon as your level meets the game's requirement. Cuts Strength and level, keeps Wins, blades and auras, and adds a Strength multiplier and the next zone row",
	Default = false,
	Callback = function(state)
		rebirthOn = state
		pcall(setRebirth, state)
	end,
})
Spend:AddToggle("Blades", {
	Text = "Auto buy blades",
	Tooltip = "Hops to the pad of the next blade once Wins can pay for it (traveling to its world if needed) and presses it. It equips itself",
	Default = false,
	Callback = function(state)
		bladesOn = state
		pcall(refreshDirector)
	end,
})
Spend:AddToggle("Auras", {
	Text = "Auto buy auras",
	Tooltip = "Buys the aura with the best multiplier your Wins can pay for and keeps the best one equipped. Never the Robux button",
	Default = false,
	Callback = function(state)
		aurasOn = state
		pcall(setAuras, state)
	end,
})
Spend:AddToggle("Quests", {
	Text = "Auto claim quests",
	Tooltip = "Claims every daily and weekly quest that is finished, and the all-done bonus. Some rewards open a pet or egg window",
	Default = false,
	Callback = function(state)
		questsOn = state
		pcall(setQuests, state)
	end,
})
Spend:AddToggle("Items", {
	Text = "Auto equip best items",
	Tooltip = "Keeps your item slots on the owned items with the highest percentage for the stat chosen below",
	Default = false,
	Callback = function(state)
		itemsOn = state
		pcall(setItems, state)
	end,
})
Spend:AddDropdown("ItemStat", {
	Text = "Item priority",
	Tooltip = "The stat to maximise. Game's best leaves the choice to the game's own equip-best button",
	Values = { "Game's best", "Strength", "Damage", "Crit chance", "Crit damage", "Health", "Speed", "Trophies" },
	Default = "Game's best",
	Multi = false,
	Callback = function(value)
		if value == "Game's best" then
			itemStat = "Auto"
		elseif value then
			itemStat = value
		end
	end,
})

local note, nextStrip = "idle", 0
local lastW, lastS, lastAt, rateW, rateS = wins(), attr("Fuerza", 0), os.clock(), 0, 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	if pending.now then
		note, pending.now = pending.now, nil
	end
	local now = os.clock()
	if now < nextStrip then
		return
	end
	nextStrip = now + 0.5
	if now - lastAt >= 10 then -- measured rate over the last 10s
		rateW, rateS = (wins() - lastW) / (now - lastAt), (attr("Fuerza", 0) - lastS) / (now - lastAt)
		lastW, lastS, lastAt = wins(), attr("Fuerza", 0), now
	end
	pcall(farmLine.SetText, farmLine, ("world %d, %d runs (last %.1fs), %s Wins won"):format(worldNow(), stats.runs, lastRun, fmt(stats.won)))
	pcall(Window.SetStatus, Window, { -- ponytail: thrown "lacking capability Plugin" when loaded through the bridge; silence, not fix
		{ "Wins", fmt(wins()) },
		{ "Strength", fmt(attr("Fuerza", 0)) },
		{ "Rebirths", attr("Rebirths", 0) },
		{ "Blade", attr("ArmaPad", 1) },
		{ "Aura", "x" .. tostring(attr("AuraMult", 1)) },
		{ "Wins/s", fmt(rateW) },
		{ "Str/s", fmt(rateS) },
		{ "Now", note },
	})
end))

Window:SetStatusAction("Unload", function()
	Library:Unload()
end, true)

-- last, so the autoload finds every control
Window:AddSettingsTab("AssassinsLeveling", {})

table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- watchdog: a parked director cannot report itself
task.spawn(function()
	while not dead do
		task.wait(5)
		if (winOn or trainOn or bladesOn) and os.clock() - markAt > STUCK_AFTER and mark ~= "director / idle" then
			warn(("[assassins] stuck %ds at: %s"):format(os.clock() - markAt, mark))
			markAt = os.clock()
		end
	end
end)

-- close ----------------------------------------------------------------------
local function stopAll()
	winOn, trainOn, tapOn, bladesOn, aurasOn, questsOn, itemsOn, rebirthOn = false, false, false, false, false, false, false, false
	gen += 1
	table.clear(tokens) -- the loops compare their own token against this table and end
	dead = true
	-- no server-side state to switch back: the game's own auto-click is not used and nothing is muted
end

Library:OnUnload(function()
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
	stopAll()
	getgenv().assassinsLevelingStop = nil
end)

getgenv().assassinsLevelingStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().assassinsLevelingStop = nil
end
