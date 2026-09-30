--[[ Tap Buttons -- press the zone's button flat out, claim its drops, spend the coins (77404766588393)

     CLICK  : drives the game's own button:click(), so every combo / clickSeed / zone rule is
              the game's. The gap is learned: the server refuses a click that lands too soon
              after the last (comboCorrected, delta < 0, server seq BEHIND ours), so the gap
              grows 25% on such a refusal and creeps down 1% on every accepted click, settling
              just above the real floor. Probed: 0.13s and up is clean, 0.12s refuses most.
              Yellow is buried about a quarter of the time: click() says no, we retry next frame.
              A luck-clover target (0.5% per click, a chain worth up to 1024x luck) is clicked
              with its chainId/step, the same way the game's own input does it.
              Refusals are healed, not just counted (all seen live):
                - the game only resets its click sequence when the corrected seq equals its
                  CURRENT one; on a ping above the gap it never does, and every click after is
                  refused. We resync to the server's seq ourselves and pause 0.2s.
                - orange swaps its live target every N clicks and the client counts every click
                  it SENDS. A refused click is undone in that counter, and two target refusals in
                  a row (server seq caught up, clicks still refused) switch the target.
     LOOT   : spawnLoot ids are claimed with requestClaimLoot, one call per item type, every
              0.35s, so the drops land without walking to them. Probed: refused at age 0.05s
              (not landed yet), paid from 5s, and only for the button you stand at (paid at
              <=26 studs from its root, refused at 88+). So the claim retries until it pays,
              and ZONE keeps you next to the button. Status "banked" is what the server credited.
     ZONE   : hops to the highest button your level opens (or the one you pick). Probed: the
              server keeps the position, and setActiveButton is range-checked (from 113 studs
              it is refused), so the hop IS the zone change. The floor is waited for with the
              character anchored, or a hop onto unstreamed ground is a fall.
              Pink (quadrant) only accepts clicks while you stand in its active wedge; the
              script re-seats you in it. UNTESTED -- pink is level 8, watch F9.
     TREE   : cheapest affordable upgrade first, across every button you can open. Collector
              upgrades are skipped: a cart captures loot before the claim gets it and its
              contents need a walk-up prompt. Probed: requestUpgradePurchase -> {xpAwarded}.
     ITEMS  : InventoryService.upgradeAll (probed: {upgradesPurchased, coinsSpent, xpAwarded}),
              then equip-best when the set changes. Coins buy XP, XP is your level, level opens
              the next zone, so spending is what moves ZONE. "Tree first" holds item upgrades
              while a tree upgrade is being saved for. Note both spend the coins (and merge
              duplicate items into levels) as fast as they arrive: turn them off to watch coins pile up.
     INDEX  : requestClaimReward once the game says one is claimable.
     BONUS  : presses a world bonus button the moment it lands (hops next to it and back when out
              of range). UNPROVEN -- nothing spawned during the dump; watch F9 for the first one.
     CUTS   : sets Rare item cutscenes to Off (a cutscene freezes clicking); restored on stop.

     Not wired: the Teleporter purchase (unprobed), cart collection, bonus-consumable arming,
     Robux products, boosts.

     RightControl rolls it up to a bare Zegion bar, RightAlt hides it outright.
     Stop: getgenv().tapButtonsStop() (or the Unload button) ]]

-- config ---------------------------------------------------------------------
local GAP_START = 0.15 -- first click gap. The floor measured near 0.125s
local GAP_MIN = 0.11 -- never below this; the game's own client gate is 0.1s
local GAP_MAX = 0.25 -- ceiling after a run of refusals (0.4 once left orange at 3 clicks/s)
local GAP_UP = 1.25 -- gap multiplier on a rate refusal. Raise it if refusals cluster
local GAP_DOWN = 0.99 -- gap multiplier per accepted click. Lower it to reach the floor faster
local REFUSAL_PAUSE = 0.2 -- after a refusal, no click for this long so the ones in flight drain. Raise it on a high ping
local WRONG_TARGET_STREAK = 2 -- target refusals in a row (inside 1s) before orange's target is switched
local CLAIM_EVERY = 0.35 -- seconds between loot claims
local CLAIM_MIN_AGE = 0.5 -- a drop younger than this is refused (not landed); we don't ask yet
local CLAIM_TTL = 20 -- stop retrying a drop after this long
local CLAIM_BATCH = 60 -- ids per claim call
local TREE_GAP = 1.5 -- seconds between tree passes
local TREE_PER_PASS = 5 -- purchases per pass before re-reading coins
local PARK = 30 -- a refused tree upgrade sits out this long
local ITEM_GAP = 2 -- seconds between upgradeAll tries
local EQUIP_GAP = 6 -- seconds between equip-best checks
local INDEX_GAP = 10 -- seconds between index-reward checks
local ZONE_GAP = 2 -- seconds between zone checks
local ZONE_NEAR = 60 -- studs from the button's root that count as "at the zone"
local STREAM_TIMEOUT = 4 -- RequestStreamAroundAsync hint before a hop
local FLOOR_WAIT = 4 -- how long a hop waits for ground under it before going back
local HOLD_CHECK = 1.5 -- after a hop, how long before judging whether the position held
local HOP_FAILS = 3 -- reverted hops in a row before Auto zone turns itself off
local CALL_TIMEOUT = 6 -- InvokeServer has none of its own
local STAND_Z = 8 -- studs past the button's radius that a hop stands at
local BONUS_GAP = 0.25 -- seconds between bonus-button checks
local BONUS_RANGE = 36 -- press from where we stand inside this; the game's own client cap (the server's is 44)
local BONUS_SETTLE = 0.3 -- after hopping next to one, how long the server gets to see us before the press
local BONUS_HOLD = 0.8 -- after the press, how long before hopping back

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().tapButtonsStop then
	getgenv().tapButtonsStop() -- re-running must not stack a second panel/loop
end

-- world ----------------------------------------------------------------------
local function req(path)
	local ok, m = pcall(require, path)
	return ok and m or nil
end
local Src = RS:WaitForChild("Source", 10)
if not Src then
	warn("[tapbuttons] ReplicatedStorage.Source missing -- wrong game, or it was updated. Nothing started.")
	return
end
local F = Src:WaitForChild("Features")
local SBC = req(F.Buttons.ButtonServiceClient)
local dataMod = req(Src.Game.Data)
local client = dataMod and dataMod.client
local ButtonInfo = req(Src.Game.Items.ButtonInfo)
local UT = req(F.Upgrades.Modules.UpgradeTrees)
local IU = req(F.Inventory.InventoryServiceUtils)
local IC = req(F.Inventory.InventoryServiceClient)
local IRU = req(F.Index.IndexRewardUtils)
local QU = req(F.Buttons.Mechanics.QuadrantButtonMechanicUtils)
local BBC = req(F.BonusButtons.BonusButtonServiceClient)
local BBU = req(F.BonusButtons.BonusButtonUtils)
if not (SBC and client and ButtonInfo and UT and IU and IRU) then
	warn("[tapbuttons] a game module would not load -- the game was updated. Nothing started.")
	return
end

local remotes
for _, c in ipairs(RS.Packages._Index:GetChildren()) do
	if c.Name:lower():find("networker") then
		local n = c:FindFirstChild("networker")
		remotes = n and n:FindFirstChild("_remotes")
		if remotes then
			break
		end
	end
end
if not remotes then
	warn("[tapbuttons] networker remotes not found. Nothing started.")
	return
end
local function RE(svc)
	local s = remotes:FindFirstChild(svc)
	return s and s:FindFirstChild("RemoteEvent")
end
local function RF(svc)
	local s = remotes:FindFirstChild(svc)
	return s and s:FindFirstChild("RemoteFunction")
end
local BUTTON_RE, LOOT_RE, LOOT_RF = RE("ButtonService"), RE("LootService"), RF("LootService")
local UPGRADE_RF, INVENTORY_RF, INDEX_RF = RF("UpgradeService"), RF("InventoryService"), RF("IndexService")
if not (BUTTON_RE and LOOT_RE and LOOT_RF and UPGRADE_RF and INVENTORY_RF and INDEX_RF) then
	warn("[tapbuttons] a remote is missing -- the game was updated. Nothing started.")
	return
end

local conns = {}
local seen = {}
local function note(msg)
	if not seen[msg] then
		seen[msg] = true
		print("[tapbuttons] " .. msg)
	end
end

-- InvokeServer has no timeout: fire it on its own thread and give up on a clock
local function callTimed(remote, ...)
	local args, n = { ... }, select("#", ...)
	local done, out = false, nil
	task.spawn(function()
		out = table.pack(pcall(remote.InvokeServer, remote, table.unpack(args, 1, n)))
		done = true
	end)
	local dl = os.clock() + CALL_TIMEOUT
	while not done and os.clock() < dl do
		task.wait()
	end
	if not done or not out[1] then
		return nil
	end
	return out[2], out[3]
end

local function hrp()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function coinsNow()
	return tonumber(client.coins()) or 0
end
local function levelNow()
	return tonumber(client.level()) or 1
end

-- AIMD for the click gap: pure, so it can assert its own direction
local function nextGap(gap, refused)
	if refused then
		return math.min(GAP_MAX, gap * GAP_UP)
	end
	return math.max(GAP_MIN, gap * GAP_DOWN)
end
assert(nextGap(0.15, true) > 0.15 and nextGap(0.15, false) < 0.15 and nextGap(GAP_MIN, false) == GAP_MIN)

-- zone -----------------------------------------------------------------------
local zonePick, zoneOn = "Auto", false
local function accessible(id)
	return ButtonInfo[id] ~= nil and ButtonInfo[id].levelReq <= levelNow()
end
local function bestZone()
	local best, top
	for id, info in pairs(ButtonInfo) do
		if info.levelReq <= levelNow() and (not top or info.levelReq > top) then
			best, top = id, info.levelReq
		end
	end
	return best
end
local function targetZone()
	if zonePick ~= "Auto" and accessible(zonePick) then
		return zonePick
	end
	return bestZone()
end
local function atZone(id)
	local o, h = SBC.buttonOrigins[id], hrp()
	return o ~= nil and h ~= nil and (h.Position - o.Position).Magnitude <= ZONE_NEAR
end
-- which button the click and loot loops work on: the zone we were told to be at, else wherever the game has us
local function workZone()
	return zoneOn and targetZone() or client.activeButton()
end

local hopFails = 0
local stats = { clicks = 0, refused = 0, claimed = 0, claimCoins = 0, claimItems = 0, tree = 0, items = 0, equip = 0, index = 0, hops = 0, bonus = 0 }
local zoneToggle

local function hop(id)
	local o, root = SBC.buttonOrigins[id], hrp()
	if not (o and root) then
		return false
	end
	local home = root.CFrame
	local dest = o.Position + Vector3.new(0, 5, ButtonInfo[id].radius + STAND_Z)
	task.spawn(function()
		pcall(player.RequestStreamAroundAsync, player, dest, STREAM_TIMEOUT)
	end)
	task.wait(0.3)
	root = hrp()
	if not root then
		return false
	end
	player.Character:PivotTo(CFrame.new(dest))
	root.Anchored = true -- hold still until there is ground, or a hop onto unstreamed map is a fall
	local dl, floor = os.clock() + FLOOR_WAIT, nil
	while not floor and os.clock() < dl do
		floor = workspace:Raycast(dest, Vector3.new(0, -40, 0))
		if not floor then
			task.wait(0.1)
		end
	end
	root = hrp() or root
	root.Anchored = false
	if not floor then
		pcall(function()
			player.Character:PivotTo(home)
		end)
		note("hop to " .. id .. ": no ground streamed in " .. FLOOR_WAIT .. "s, went back")
		return false
	end
	task.wait(HOLD_CHECK)
	root = hrp()
	local held = root ~= nil and (root.Position - dest).Magnitude < 25
	if held then
		hopFails = 0
		stats.hops += 1
	else
		hopFails += 1
		note(("hop to %s: position did not hold (%d/%d)"):format(id, hopFails, HOP_FAILS))
	end
	return held
end

-- click ----------------------------------------------------------------------
local rejected = 0 -- rate refusals only: comboCorrected with delta < 0 and the server's seq behind ours
local refusalLogs = 0
local gap = GAP_START -- the live click gap, adapted in clickStep below
local nextClick, lastRejected = 0, 0
local wrongStreak, wrongAt = 0, 0

-- Orange swaps its live target every N clicks, and the game's client counts every click we
-- SEND, refused or not, so one refusal leaves it a click ahead of the server. Undo the refused click.
local function undoAlternation(m)
	if m.clicksSinceAlternation > 0 then
		m.clicksSinceAlternation -= 1
	else
		m.clicksSinceAlternation = math.max(0, m.config.clicksPerAlternation - 1)
		m.activeTargetIndex = (m.activeTargetIndex - 2) % #m.targetIds + 1
		pcall(m.updateVisuals, m)
	end
end

table.insert(conns, BUTTON_RE.OnClientEvent:Connect(function(name, buttonId, cseq, sseq, combo, dur, delta)
	if name == "comboCorrected" and type(delta) == "number" and delta < 0 then
		-- server seq BEHIND ours = too soon / out of order (a rate refusal, the gap reacts);
		-- server seq caught up but the clicks still refused = the click aimed at the wrong target
		local wrong = type(cseq) == "number" and type(sseq) == "number" and sseq >= cseq
		if not wrong then
			rejected += 1
		end
		stats.refused += 1
		local btn = SBC.buttons[buttonId]
		-- The game only resets its sequence when the corrected seq equals its CURRENT one; on a
		-- ping above the click gap it has already sent the next seq, the reset never applies, and
		-- every click after is refused (seen: server stuck at 932, client sending 933..938).
		-- Resync to the server's numbers ourselves, then let what is in flight drain.
		if btn then
			pcall(btn.correctCombo, btn, btn.clickSequence, sseq, combo, dur)
		end
		nextClick = math.max(nextClick, os.clock() + REFUSAL_PAUSE)
		local m = btn and btn.mechanicController and btn.mechanicController.mechanic
		local alt = m ~= nil and m.clicksSinceAlternation ~= nil and m.targetIds ~= nil
		if alt then
			pcall(undoAlternation, m)
			if wrong then
				-- The client's swap counter and the server's disagree, so we aim at the dead target and
				-- every click is refused (undoing each one keeps the count from ever reaching the swap).
				-- Switch target with count 0: if the server had swapped first this is exactly in step; if
				-- we had swapped early we land back on its live target, the server swaps a few clicks
				-- later, the same rule fires again and the second pass is exact.
				local now = os.clock()
				wrongStreak = (now - wrongAt < 1) and wrongStreak + 1 or 1
				wrongAt = now
				if wrongStreak >= WRONG_TARGET_STREAK then
					wrongStreak = 0
					m.activeTargetIndex = m.activeTargetIndex % #m.targetIds + 1
					m.clicksSinceAlternation = 0
					pcall(m.updateVisuals, m)
					print("[tapbuttons] " .. tostring(buttonId) .. ": target out of step with the server, switched")
				end
			end
		end
		if refusalLogs < 6 then
			refusalLogs += 1
			print(("[tapbuttons] refused %s seq %s->%s combo %s delta %s gap %.3f%s"):format(
				tostring(buttonId), tostring(cseq), tostring(sseq), tostring(combo), tostring(delta), gap,
				alt and (" | alternating: target #%s, %s clicks into it"):format(tostring(m.activeTargetIndex), tostring(m.clicksSinceAlternation)) or ""
			))
		end
	end
end))

-- pink only clicks while we stand in the active wedge; the button object holds the mechanic
local function seatInQuadrant(btn)
	local m = btn.mechanicController and btn.mechanicController.mechanic
	local root = hrp()
	if not (QU and m and m.basePivot and m.config and m.config.holdDuration and root) then
		return
	end
	local now = workspace:GetServerTimeNow() + 0.15
	local st = QU.getState(m.config, now)
	if st.canInteract and not QU.isPositionInActiveQuadrant(m.basePivot, m.config, now, root.Position) then
		local p = (m.basePivot * CFrame.Angles(0, st.angle, 0)):PointToWorldSpace(Vector3.new(-6, 5, 6))
		player.Character:PivotTo(CFrame.new(p))
	end
end

local function clickStep()
	local now = os.clock()
	if now < nextClick then
		return
	end
	local id = workZone()
	local btn = id and SBC.buttons[id]
	if not (btn and client.activeButton() == id and atZone(id)) then
		nextClick = now + 0.2 -- mid-hop, or the game has not switched its active button yet
		return
	end
	if ButtonInfo[id].mechanic and ButtonInfo[id].mechanic.id == "quadrant" then
		seatInQuadrant(btn)
	end
	local lc = SBC.luckClover
	local tg = lc and lc.target
	local ok
	if tg and tg.buttonId == id then
		ok = btn:click(btn:getActiveTargetId(), tg.chainId, tg.step)
		if ok then
			pcall(lc.hit, lc)
		end
	else
		ok = btn:click(btn:getActiveTargetId())
	end
	if not ok then
		return -- buried / cutscene / wrong target: try again next frame, no gap spent
	end
	stats.clicks += 1
	gap = nextGap(gap, rejected ~= lastRejected)
	lastRejected = rejected
	nextClick = os.clock() + gap
end

-- loot -----------------------------------------------------------------------
local pending = {} -- uniqueId -> { at = spawn time, key = "<item id>:<variant>" }
table.insert(conns, LOOT_RE.OnClientEvent:Connect(function(name, data)
	if name == "spawnLoot" and type(data) == "table" and data.uniqueId and data.buttonId == client.activeButton() then
		pending[data.uniqueId] = { at = os.clock(), key = tostring(data.id) .. ":" .. tostring(data.variantId) }
	elseif name == "despawnLoot" and type(data) == "table" then
		for _, uid in pairs(data) do
			pending[uid] = nil
		end
	end
end))

local function claimStep()
	local id = workZone()
	if not (id and atZone(id)) then
		return
	end
	-- one call per item type: the game's own claim only ever sends one stack's ids, and a
	-- mixed batch is untested (the reply carries a single id/amt)
	local now, groups = os.clock(), {}
	for uid, p in pairs(pending) do
		local age = now - p.at
		if age > CLAIM_TTL then
			pending[uid] = nil
		elseif age >= CLAIM_MIN_AGE then
			local g = groups[p.key]
			if not g then
				g = {}
				groups[p.key] = g
			end
			if #g < CLAIM_BATCH then
				g[#g + 1] = uid
			end
		end
	end
	for key, ids in pairs(groups) do
		local reply = callTimed(LOOT_RF, "requestClaimLoot", ids)
		if type(reply) == "table" and type(reply.claimedUniqueIds) == "table" then
			for _, uid in pairs(reply.claimedUniqueIds) do
				pending[uid] = nil
				stats.claimed += 1
			end
			if type(reply.amt) == "number" then
				if reply.id == "coin" then
					stats.claimCoins += reply.amt
				else
					stats.claimItems += reply.amt
				end
			end
			if #reply.claimedUniqueIds ~= #ids then
				note(("claim %s: sent %d, server took %d (the rest retry until %ds)"):format(key, #ids, #reply.claimedUniqueIds, CLAIM_TTL))
			end
		end
	end
end

-- spend ----------------------------------------------------------------------
local treeNext -- cost of the cheapest pending tree upgrade, what "Tree first" saves for
local parked = {}
local function owned(b, u)
	return client.buttons[b].upgrades[u]() == true
end
local function byCost(a, c)
	if a.cost == c.cost then
		return a.b .. a.u < c.b .. c.u
	end
	return a.cost < c.cost
end
do
	local t = { { cost = 5, b = "x", u = "b" }, { cost = 5, b = "x", u = "a" }, { cost = 2, b = "y", u = "z" } }
	table.sort(t, byCost)
	assert(t[1].cost == 2 and t[2].u == "a")
end
local function candidates()
	local list = {}
	for id, info in pairs(ButtonInfo) do
		if info.levelReq <= levelNow() then
			for uid, up in pairs(UT.lookup[id] or {}) do
				local collectorOnly = up.effects ~= nil and #up.effects > 0
				for _, e in ipairs(up.effects or {}) do
					if not tostring(e.type):find("^collector") then
						collectorOnly = false
					end
				end
				local gd = up.globalDependency
				if
					up.cost
					and up.cost.currency == "coins"
					and not collectorOnly
					and not owned(id, uid)
					and (up.dependency == UT.enums.rootUpgrade or owned(id, up.dependency))
					and (gd == nil or owned(gd.buttonId, gd.upgradeId))
				then
					list[#list + 1] = { b = id, u = uid, cost = up.cost.amount }
				end
			end
		end
	end
	table.sort(list, byCost)
	return list
end

local function treeStep()
	local list, coins, bought = candidates(), coinsNow(), 0
	treeNext = list[1] and list[1].cost or nil
	for _, c in ipairs(list) do
		local key = c.b .. ":" .. c.u
		if c.cost > coins or bought >= TREE_PER_PASS then
			break
		end
		if not (parked[key] and os.clock() < parked[key]) then
			local reply = callTimed(UPGRADE_RF, "requestUpgradePurchase", c.b, c.u)
			if type(reply) == "table" and type(reply.xpAwarded) == "number" then
				stats.tree += 1
				bought += 1
				coins -= c.cost
				parked[key] = os.clock() + 3 -- the mirror lags one beat; do not buy it twice
			else
				parked[key] = os.clock() + PARK
			end
		end
	end
end

local treeFirst, treeActive = true, false
local function itemStep()
	local coins = coinsNow()
	if treeFirst and treeActive and treeNext and coins < treeNext then
		return -- saving for a tree upgrade
	end
	local preview = IU.getUpgradeAllPreview(client.inventory(), coins)
	if preview.upgradeCount > 0 then
		local reply = callTimed(INVENTORY_RF, "upgradeAll")
		if type(reply) == "table" and type(reply.upgradesPurchased) == "number" then
			stats.items += reply.upgradesPurchased
		end
	end
end

local function sameSet(a, b)
	if #a ~= #b then
		return false
	end
	local s = {}
	for _, v in ipairs(a) do
		s[v] = true
	end
	for _, v in ipairs(b) do
		if not s[v] then
			return false
		end
	end
	return true
end
assert(sameSet({ "a", "b" }, { "b", "a" }) and not sameSet({ "a" }, { "b" }))

local function equipStep()
	local slots = IU.getUnlockedSlotCount(client.level(), client.monetization.gamepasses())
	local best = IU.getBestEquippedItemIds(client.inventory(), slots)
	if #best > 0 and not sameSet(best, client.equipped()) then
		if IC and IC.equipBest then
			IC:equipBest()
		else
			client.equipped(best)
			local re = RE("InventoryService")
			if re then
				re:FireServer("setEquippedItems", best)
			end
		end
		stats.equip += 1
	end
end

local function indexStep()
	for _ = 1, 10 do
		if not IRU.isClaimable(client.index()) then
			return
		end
		local ok = callTimed(INDEX_RF, "requestClaimReward")
		if not ok then
			return
		end
		stats.index += 1
	end
end

-- bonus button ---------------------------------------------------------------
-- A world bonus button (0.0001 per click) pays a stack of items and chains into a bigger one.
-- Pressed through the game's own activate() (requestPress + the press animation). Out of
-- range we snap next to it and straight back: the server only range-checks the press.
-- ponytail: UNPROVEN, the dump never caught a spawn. Every spawn and its outcome prints to F9;
-- requestArm (spending a held bonus consumable) is not wired until its reply has been seen.
local bonusSeen = {}
local function bonusStep()
	local root = hrp()
	if not (BBC and root) then
		return
	end
	for id, b in pairs(BBC.buttons) do
		if b:canPress() then
			local dist = (root.Position - b.position).Magnitude
			if not bonusSeen[id] then
				bonusSeen[id] = true
				print(("[tapbuttons] bonus button %s stage %s at %.0f studs"):format(tostring(id), tostring(b.depth), dist))
				task.delay(BONUS_SETTLE + BONUS_HOLD + 1, function()
					if BBC.buttons[id] then
						print("[tapbuttons] bonus button " .. tostring(id) .. " is still there: the press was refused (or it expired)")
					else
						stats.bonus += 1
						print("[tapbuttons] bonus button " .. tostring(id) .. " consumed")
					end
				end)
			end
			local home
			if dist > BONUS_RANGE then
				home = root.CFrame
				player.Character:PivotTo(CFrame.new(b.position + Vector3.new(4, 3, 0)))
				task.wait(BONUS_SETTLE)
			end
			BBC:activate(b)
			if home then
				task.wait(BONUS_HOLD)
				pcall(function()
					player.Character:PivotTo(home)
				end)
			end
			return -- one per pass; the next pass re-reads the world
		end
	end
end

-- cutscenes ------------------------------------------------------------------
local cutPrev
local function setCuts(state)
	if state then
		if cutPrev == nil then
			cutPrev = client.settings.rareItemCutscenes()
		end
		client.settings.rareItemCutscenes("off")
	elseif cutPrev ~= nil then
		client.settings.rareItemCutscenes(cutPrev)
		cutPrev = nil
	end
end

-- loops ----------------------------------------------------------------------
-- one generation counter per toggle: off-then-on inside one wait must not leave a second thread alive
local function loop(label, gapOf, step)
	local gen, running = 0, false
	return function(state)
		running = state
		gen += 1
		local mine = gen
		if not state then
			return
		end
		task.spawn(function()
			while running and gen == mine do
				local ok, err = pcall(step)
				if not ok then
					note(label .. ": " .. tostring(err))
					task.wait(1)
				end
				task.wait(gapOf)
			end
		end)
	end
end

local setClick = loop("click", 0, clickStep)
local setLoot = loop("loot", CLAIM_EVERY, claimStep)
local setTree = loop("tree", TREE_GAP, treeStep)
local setItems = loop("items", ITEM_GAP, itemStep)
local setEquip = loop("equip", EQUIP_GAP, equipStep)
local setIndex = loop("index", INDEX_GAP, indexStep)
local setBonus = loop("bonus", BONUS_GAP, bonusStep)
local setZoneLoop = loop("zone", ZONE_GAP, function()
	local id = targetZone()
	if id and not atZone(id) then
		hop(id)
		if hopFails >= HOP_FAILS then
			hopFails = 0
			note("Auto zone: the server keeps reverting the hop; switched off. Walk to the button yourself")
			if zoneToggle then
				pcall(zoneToggle.SetValue, zoneToggle, false) -- re-enters setZone(false)
			end
		end
	end
end)
local function setZone(state)
	zoneOn = state
	setZoneLoop(state)
end
local function setTreeToggle(state)
	treeActive = state
	if not state then
		treeNext = nil
	end
	setTree(state)
end

-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel_obsidian.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, Library = panel({ game = "Tap Buttons", size = UDim2.fromOffset(460, 380) })
if not Window then
	return -- panel_obsidian.lua already said why
end

local Tab = Window:AddTab("Main", "house")
local Farm = Tab:AddLeftGroupbox("Farm", "mouse-pointer-click")
local Spend = Tab:AddLeftGroupbox("Spend", "coins")
local Info = Tab:AddRightGroupbox("Status", "activity")

local toggles = {}
local function tog(box, idx, text, tip, cb)
	local t = box:AddToggle(idx, { Text = text, Tooltip = tip, Default = false, Callback = cb })
	toggles[#toggles + 1] = t
	return t
end

tog(Farm, "Click", "Auto Click", "Presses the zone's button through the game's own click(). The gap is learned from the server's refusals", setClick)
tog(Farm, "Loot", "Auto Collect", "Claims every drop and coin of the zone you stand at, no walking to it", setLoot)
zoneToggle = tog(Farm, "Zone", "Auto Zone", "Hops next to the best button your level opens. Turns itself off if the server reverts the hop", setZone)
local zoneValues = { "Auto" }
do
	local rows = {}
	for id, info in pairs(ButtonInfo) do
		rows[#rows + 1] = { id = id, req = info.levelReq }
	end
	table.sort(rows, function(a, b)
		return a.req < b.req
	end)
	for _, r in ipairs(rows) do
		zoneValues[#zoneValues + 1] = r.id
	end
end
Farm:AddDropdown("ZonePick", {
	Text = "Zone",
	Tooltip = "Auto = the highest button your level opens. A locked pick falls back to Auto",
	Values = zoneValues,
	Default = "Auto",
	Callback = function(v)
		if table.find(zoneValues, v) then
			zonePick = v
		end
	end,
})
if BBC and BBU then
	tog(Farm, "Bonus", "Auto Bonus Button", "Presses any bonus button that drops, hopping next to it and back if it is out of range. Unproven: every spawn prints to F9", setBonus)
end
tog(Farm, "Cuts", "Skip rare cutscenes", "Sets Rare item cutscenes to Off in the game's settings (a cutscene blocks clicking). Restored when you stop", setCuts)

tog(Spend, "Tree", "Auto Tree upgrade", "Cheapest affordable skill-tree upgrade first, on every button you can open. Skips collector carts", setTreeToggle)
tog(Spend, "Items", "Auto Item upgrade", "upgradeAll: upgrades every item you hold enough copies of", setItems)
Spend:AddDropdown("Priority", {
	Text = "Coins go to",
	Tooltip = "Tree first: item upgrades wait while a tree upgrade is being saved for. Both: items spend as soon as they can",
	Values = { "Tree first", "Both" },
	Default = "Tree first",
	Callback = function(v)
		treeFirst = v == "Tree first"
	end,
})
tog(Spend, "Equip", "Auto Equip best", "Re-equips the strongest items whenever the best set changes", setEquip)
tog(Spend, "Index", "Auto Index reward", "Claims index rewards as soon as the game says one is ready", setIndex)

Farm:AddToggle("All", {
	Text = "Everything",
	Tooltip = "Flips every switch above together",
	Default = false,
	Callback = function(v)
		for _, t in ipairs(toggles) do
			pcall(t.SetValue, t, v)
		end
	end,
})

local line = Info:AddLabel("Status: idle", true)
local statsLine = Info:AddLabel("-", true)
-- a resumed thread lacks the capability to write the hidden GUI; Heartbeat (engine identity) does it
local last, nextStats = { clicks = 0, claimCoins = 0 }, 0
table.insert(conns, RunService.Heartbeat:Connect(function()
	local now = os.clock()
	if now < nextStats then
		return
	end
	nextStats = now + 1
	local cps, cc = stats.clicks - last.clicks, stats.claimCoins - last.claimCoins
	last.clicks, last.claimCoins = stats.clicks, stats.claimCoins
	local waiting = 0
	for _ in pairs(pending) do
		waiting += 1
	end
	line:SetText(("Zone %s | level %d | coins %s"):format(tostring(client.activeButton()), levelNow(), tostring(math.floor(coinsNow()))))
	statsLine:SetText(
		("clicks %d/s | gap %.3fs | refused %d\nloot claimed %d | +%d coins/s | pending %d\nbanked: %d coins, %d items\ntree %d | items %d | equip %d | index %d | hops %d | bonus %d"):format(
			cps, gap, stats.refused, stats.claimed, math.floor(cc), waiting, stats.claimCoins, stats.claimItems,
			stats.tree, stats.items, stats.equip, stats.index, stats.hops, stats.bonus
		)
	)
end))

Info:AddButton({ Text = "Unload", Risky = true, Func = function()
	Library:Unload()
end })

local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

-- close ----------------------------------------------------------------------
local function stopAll()
	setClick(false)
	setLoot(false)
	setZone(false)
	setTreeToggle(false)
	setItems(false)
	setEquip(false)
	setIndex(false)
	setBonus(false)
	setCuts(false) -- puts the game's cutscene setting back
	local r = hrp()
	if r then
		r.Anchored = false
	end
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

Library:OnUnload(function()
	stopAll()
	getgenv().tapButtonsStop = nil
end)

getgenv().tapButtonsStop = function()
	stopAll()
	pcall(function()
		Library:Unload()
	end)
	getgenv().tapButtonsStop = nil
end
