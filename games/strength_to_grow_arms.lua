--[[ Strength to Grow Arms -- brainrot autofarm without moving (86259628805375)

     FARM     : grab a spawned brainrot by its uid, bank it at SafetyBase, repeat. The
                character never walks the wall corridor, so the server's teleport-back
                (which drops your carry and resets you the instant you're past an un-broken
                wall) never fires. The game's PickUpBrainrot has no position check -- it
                moves the brainrot to your CarryFolder from anywhere -- which is the whole
                trick. Carry holds ONE at a time (MaxCarryNum=1), so it's strictly
                grab -> bank -> grab.

     TARGET   : "Best available" ranks every live brainrot by the game's own
                getBrainrotGoldPerSecond (base value x mutation) and takes the richest;
                or pick a single AreaN to farm just that zone. "Min $/s" skips anything
                cheaper in Best mode. Areas 1-12 are map 1, 13-21 map 2; by default only
                the map you're on is farmed (a toggle opens the rest).

     COLLECT  : "Auto collect cash" banks the income from every brainrot on your plot on a
                timer. No gamepass -- it fires the game's own collect-all remote, which has
                no gamepass check (the pass only sells the convenience pad).
     PLACE    : "Auto place best" hands the game its own PlaceMaxBrainrot, which sorts your
                inventory by $/s and fills empty slots + replaces weaker placed ones with
                your best. Only fires when the inventory changed, so it doesn't churn.

     HEADS UP : re-arming each deposit requires one punch at your CURRENT front wall
                (there is no server path to clear the deposit guard without a punch), so
                the farm also slowly advances you up the walls. It never moves your
                character, so it can't trigger the teleport-back. If you don't want any
                wall progress, this game can't be farmed without it.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().growArmsStop() ]]

-- config ---------------------------------------------------------------------
local CYCLE_WAIT = 0.2 -- beat between grab cycles when there's nothing to do
local GRAB_TIMEOUT = 2 -- give up on a pickup whose uid never lands in CarryFolder
-- (expired mid-flight, another player took it, or carry was somehow full)
local BANK_TIMEOUT = 2 -- give up on a deposit whose carry never clears / inventory never grows
local MIN_LIFE = 3 -- skip brainrots with fewer than this many seconds of life left, so the
-- one you pick survives the round trip to the server (it destroys expired data every 1s)
local SETTLE = 0.1 -- wait between the firetouchinterest begin/end pair
local CLEAR_CD = 0.6 -- min age of the replicated HitWallTime before firing the guard-clearing
-- HitWall (server HitWallCD is 0.5; the margin covers clock skew). A manual punch right
-- before farming would otherwise get the clear rejected and stall the next deposit.
local CLEAR_TIMEOUT = 1 -- how long to wait for ResetWallInfo to replicate back to nil
local CLEAR_RETRIES = 3 -- clear attempts before pausing in a terminal clear_failed state

local COLLECT_EVERY = 3 -- seconds between cash sweeps. Collecting resets each brainrot's
-- accrual, so a short interval just banks income smoothly and keeps you under any storage cap
local PLACE_EVERY = 2 -- seconds between auto-place passes. Spends nothing; only does work
-- when the farm has added a new brainrot to your inventory

local KEY_TOGGLE = Enum.KeyCode.RightControl

-- The two game modules that own the remotes, by their real (Chinese) names:
--   获取脑红 : PickUpBrainrot / HitWall (fires BridgeNet on ReplicatedStorage.RemoteEvent)
--   脑红     : GetBrainrotConfigInfo / getBrainrotGoldPerSecond (pure config, client-safe)
local GRAB_MOD = "Manager_\232\142\183\229\143\150\232\132\145\231\186\162"
local VALUE_MOD = "Manager_\232\132\145\231\186\162"

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer

if getgenv and getgenv().growArmsStop then
	getgenv().growArmsStop() -- re-running must not stack a second panel/loop
end

-- world ----------------------------------------------------------------------
-- A game LocalScript's _G is not the executor's; the game's synced clock lives on its own.
local gEnv = (getrenv and getrenv()._G) or _G
local function clientTime()
	if gEnv and gEnv.GetClientTime then
		local ok, t = pcall(gEnv.GetClientTime)
		if ok and t then
			return t
		end
	end
	return time() -- fallback; MIN_LIFE / CLEAR_CD margins absorb the skew
end

local firetouch = firetouchinterest

-- require the module and hand back its returned table; nil (not error) if unavailable so
-- the raw fallback can take over.
local function tryRequire(name)
	local inst = ReplicatedStorage:WaitForChild("ModuleScripts", 10)
	inst = inst and inst:FindFirstChild(name)
	if not inst then
		return nil
	end
	local ok, mod = pcall(require, inst)
	return ok and mod or nil
end

local grabMgr = tryRequire(GRAB_MOD)
local valueMgr = tryRequire(VALUE_MOD)
local rawEvent = ReplicatedStorage:FindFirstChild("RemoteEvent") -- BridgeNet's one socket
-- \24 == \x18: the captured BridgeNet compressed id for the 获取脑红 bridge. DUMP-VERSION
-- ONLY -- this id can shift on any game update, so it's a last resort behind the require,
-- and a FireServer here is never trusted as success: a raw grab only "counts" once the uid
-- actually lands in CarryFolder (see cycle()).
local rawActive = false
local function usingRaw()
	return not (grabMgr and grabMgr.PickUpBrainrot)
end

local function pickup(uid)
	if grabMgr and grabMgr.PickUpBrainrot then
		grabMgr:PickUpBrainrot(player, { uid = uid })
	elseif rawEvent then
		rawEvent:FireServer({ { "\24", { "PickUpBrainrot", { uid = uid } } } })
	end
end

local function hitWall(wall)
	if grabMgr and grabMgr.HitWall then
		grabMgr:HitWall(player, wall)
	elseif rawEvent then
		rawEvent:FireServer({ { "\24", { "HitWall", wall } } })
	end
end

-- Static, safe to cache: these don't get rebuilt on respawn.
local dataFolder = (function()
	local bf = workspace:WaitForChild("BrainrotFolder", 10)
	return bf and bf:WaitForChild("data", 10)
end)()
local safety = (function()
	local map = workspace:WaitForChild("Map", 10)
	return map and map:WaitForChild("SafetyBase", 10)
end)()

local pdata = player:WaitForChild("PlayerData", 10)
local ownBrainrot = pdata and pdata:WaitForChild("OwnBrainrot", 10)
local statistics = pdata and pdata:WaitForChild("statistics", 10)
local mapStat = pdata and pdata:WaitForChild("MapStat", 10)

-- CarryFolder is rebuilt on respawn, so it's reacquired every cycle rather than cached.
local function carryData()
	local tf = workspace:FindFirstChild("TerritoryFolder")
	local mine = tf and tf:FindFirstChild(player.Name)
	local cf = mine and mine:FindFirstChild("CarryFolder")
	return cf and cf:FindFirstChild("data")
end

-- farm -----------------------------------------------------------------------
-- Value = the game's own math. Spawned brainrots carry only name + mutates (no
-- goldPerSecond, no level), so the base has to come from the config; passing {name,mutates}
-- alone scores every one 0.
local function brainrotValue(name, mutates)
	if not (valueMgr and name) then
		return nil
	end
	local ok, info = pcall(function()
		return valueMgr:GetBrainrotConfigInfo(name)
	end)
	if not ok or not info or not info.goldPerSecond then
		return nil
	end
	local ok2, v = pcall(function()
		return valueMgr:getBrainrotGoldPerSecond({ goldPerSecond = info.goldPerSecond, mutates = mutates })
	end)
	return ok2 and v or nil
end

local function decodeMutates(raw)
	if not raw then
		return nil
	end
	local ok, v = pcall(HttpService.JSONDecode, HttpService, raw)
	return ok and v or nil
end

-- Every live brainrot in the data tree, filtered to the current map unless crossMaps.
local function listBrainrots(target, minPerSec, crossMaps)
	local out = {}
	if not dataFolder then
		return out
	end
	local now = clientTime()
	local mapVal = mapStat and mapStat.Value or 1
	for _, areaFolder in ipairs(dataFolder:GetChildren()) do
		local areaName = areaFolder.Name
		local areaIdx = tonumber(areaName:match("Area(%d+)")) or 0
		local onThisMap = (areaIdx <= 12 and mapVal == 1) or (areaIdx > 12 and mapVal == 2)
		if crossMaps or onThisMap then
			for _, sv in ipairs(areaFolder:GetChildren()) do
				if sv:IsA("StringValue") then
					local exp = sv:GetAttribute("ExpTime")
					if exp and (exp - now) >= MIN_LIFE then
						local name = sv:GetAttribute("brainrot")
						local mutates = decodeMutates(sv:GetAttribute("mutates"))
						local value = brainrotValue(name, mutates) or areaIdx -- fallback: rank by zone
						if target ~= "Best available" or value >= minPerSec then
							out[#out + 1] = {
								uid = sv.Name,
								area = areaName,
								areaIdx = areaIdx,
								name = name,
								mutates = mutates,
								value = value,
							}
						end
					end
				end
			end
		end
	end
	return out
end

local function pickTarget(list, target)
	if target == "Best available" then
		local best
		for _, b in ipairs(list) do
			if not best or b.value > best.value or (b.value == best.value and b.areaIdx > best.areaIdx) then
				best = b
			end
		end
		return best
	end
	for _, b in ipairs(list) do
		if b.area == target then
			return b
		end
	end
	return nil
end

-- The front wall to punch when re-arming a deposit. Derived from progression, NOT from the
-- freshly-reset WallInfo (whose lowest live wall is always the first one and never
-- advances). The server's HitWall takes the id directly.
local function frontWall()
	local mapVal = mapStat and mapStat.Value or 1
	local maxId = 0
	if statistics then
		local ok, s = pcall(function()
			return HttpService:JSONDecode(statistics.Value)
		end)
		if ok and s and s.MaxWallId then
			maxId = s.MaxWallId
		end
	end
	local id = maxId + 1
	if mapVal == 2 then
		id = math.clamp(id, 13, 21)
	else
		id = math.clamp(id, 1, 12)
	end
	return "BlockWall" .. id
end

-- Fire HitWall (clears the ResetWallInfo deposit guard at its top, before wall validation),
-- gated on the replicated HitWallTime so the server doesn't reject it, then confirm the
-- guard actually dropped. Returns false only after CLEAR_RETRIES.
local function clearGuard()
	for _ = 1, CLEAR_RETRIES do
		local waited = 0
		while clientTime() - (player:GetAttribute("HitWallTime") or 0) < CLEAR_CD do
			task.wait(0.05)
			waited = waited + 0.05
			if waited > CLEAR_CD + 0.5 then
				break -- attribute never advanced; fire anyway and let the confirm decide
			end
		end
		hitWall(frontWall())
		local t0 = os.clock()
		repeat
			task.wait()
		until player:GetAttribute("ResetWallInfo") == nil or (os.clock() - t0) > CLEAR_TIMEOUT
		if player:GetAttribute("ResetWallInfo") == nil then
			return true
		end
	end
	return false
end

-- SafetyBase.Touched returns early while ResetWallInfo is set, so a leftover guard (a prior
-- clear_failed, or ordinary play) must be dropped before a deposit will register at all.
local function ensureCleared()
	if player:GetAttribute("ResetWallInfo") == nil then
		return true
	end
	return clearGuard()
end

-- Deposit the one carried brainrot and re-arm for the next one. Returns (banked, cleared,
-- why): banked is the thing worth counting, and it's reported even when the re-arm clear
-- fails, so a real deposit is never lost from the total. Confirms by the world: carry empties
-- AND the inventory string changes. hopFallback is the R2 escape if firetouchinterest can't
-- reach SafetyBase.Touched -- SafetyBase (z ~= -898) is behind every wall, so a hop there
-- crosses nothing and can't trip the teleport-back; the pre-hop pivot is restored after.
local function bankAndClear(cd, hopFallback)
	if not (cd and safety and ownBrainrot) then
		return false, false, "no_handles"
	end
	-- A pre-existing guard would swallow the touch silently; clear it first (finding: rerun
	-- after clear_failed couldn't recover a carry).
	if not ensureCleared() then
		return false, false, "clear_failed"
	end

	-- Reacquire per action: a respawn mid-cycle invalidates head. Returns (ok, reason) so a
	-- respawn reads as the transient no_head, not a terminal bank_failed.
	local function touchAndConfirm(doTouch)
		local char = player.Character
		local head = char and char:FindFirstChild("Head")
		if not head then
			return false, "no_head"
		end
		local before = ownBrainrot.Value
		local ok = pcall(doTouch, char, head) -- PivotTo/firetouch on a dying character can throw
		if not ok then
			return false, "no_head" -- the character went away under us; retry on the fresh one
		end
		local t0 = os.clock()
		repeat
			task.wait()
		until (#cd:GetChildren() == 0 and ownBrainrot.Value ~= before) or (os.clock() - t0) > BANK_TIMEOUT
		if #cd:GetChildren() == 0 and ownBrainrot.Value ~= before then
			return true, "ok"
		end
		return false, "bank_failed"
	end

	local banked, why = false, "bank_failed"
	if firetouch then
		banked, why = touchAndConfirm(function(_, head)
			firetouch(head, safety, 0)
			task.wait(SETTLE)
			firetouch(head, safety, 1)
		end)
	end
	if not banked and why ~= "no_head" and hopFallback then
		banked, why = touchAndConfirm(function(char)
			local orig = char:GetPivot()
			char:PivotTo(CFrame.new(safety.Position + Vector3.new(0, 5, 0)))
			task.delay(SETTLE + 0.1, function()
				-- Restore only the SAME character we hopped; a respawn during the confirm wait
				-- would otherwise fling the fresh character to the old one's spot.
				if player.Character == char then
					pcall(function()
						char:PivotTo(orig)
					end)
				end
			end)
		end)
	end
	if not banked then
		return false, false, why -- no_head -> transient retry; bank_failed -> handled by caller
	end

	-- The bank set ResetWallInfo=true server-side; wait to actually SEE it before clearing.
	-- If it never shows within the window, don't fire a phantom HitWall -- ensureCleared() at
	-- the next bank is the backstop for a late-arriving guard.
	local t0 = os.clock()
	repeat
		task.wait()
	until player:GetAttribute("ResetWallInfo") ~= nil or (os.clock() - t0) > CLEAR_TIMEOUT
	if player:GetAttribute("ResetWallInfo") == nil then
		return true, true, "ok"
	end
	local cleared = clearGuard()
	return true, cleared, cleared and "ok" or "clear_failed"
end

-- gui ------------------------------------------------------------------------
-- ponytail: no hand-rolled widget kit. Topbar, icon, bubble, live game name and the shade
-- live in panel.lua, so a restyle is one file. Fetched here rather than installed by the
-- loader, so this file still pastes and runs on its own.
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()

local Window, WindUI = panel({
	game = "Strength to Grow Arms", -- fallback until the live name lands
	folder = "GrowArms", -- renaming it later orphans configs already saved in-game
	size = UDim2.fromOffset(460, 400),
	key = KEY_TOGGLE,
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:home-2-bold" })
local farmCard =
	Tab:Section({ Title = "Farm", Desc = "Grab by uid, bank at base", Icon = "solar:magnet-bold", Box = true, BoxBorder = true, Opened = true })

-- state written by the controls
local target = "Best available"
local minPerSec = 0
local crossMaps = false
local hopFallback = false
local farming = false
local gen = 0
local count = 0

local statusRow, lastRow, countRow

local function say(msg)
	if statusRow then
		statusRow:SetDesc(msg)
	end
end

-- F9 is where "it does nothing" gets answered, so mirror the panel status there -- throttled,
-- because it's called every cycle.
local lastLog = 0
local function logf(reason)
	if os.clock() - lastLog >= 5 then
		lastLog = os.clock()
		print(("[growarms] %s | banked=%d target=%s"):format(reason, count, tostring(target)))
	end
end

-- no_head / no_handles are a respawn in progress, not a real refusal -- retry, don't stop.
local function isTransient(why)
	return why == "no_head" or why == "no_handles"
end

-- Target = Best available, or a single zone. Areas 1-12 map 1, 13-21 map 2.
local zoneValues = { "Best available" }
for i = 1, 21 do
	zoneValues[#zoneValues + 1] = "Area" .. i
end

farmCard:Dropdown({
	Title = "Target",
	Desc = "Best $/s anywhere, or one specific zone",
	Values = zoneValues,
	Value = "Best available",
	Callback = function(picked)
		target = picked
	end,
})

farmCard:Input({
	Title = "Min $/s",
	Desc = "Best mode only: skip brainrots worth less than this",
	Value = "0",
	Placeholder = "0",
	Callback = function(v)
		minPerSec = tonumber((v or ""):gsub("[%$,%s]", "")) or 0
	end,
})

farmCard:Toggle({
	Title = "Farm across both maps",
	Desc = "Off = only your current map. On = grab from every zone (may not bank cross-map)",
	Value = false,
	Callback = function(state)
		crossMaps = state
	end,
})

farmCard:Toggle({
	Title = "Bank hop fallback",
	Desc = "If firetouch can't bank, briefly drop onto SafetyBase instead (behind all walls, safe)",
	Value = false,
	Callback = function(state)
		hopFallback = state
	end,
})

-- The one moving part. Generation counter so off-then-on inside one interval can't leave
-- the old thread running alongside the new one.
local farmToggle
farmToggle = farmCard:Toggle({
	Title = "Farm Brainrots",
	Desc = "grab -> bank -> repeat",
	Value = false,
	Callback = function(state)
		farming = state
		if not state then
			return -- off-click: the running loop sees farming=false and exits
		end
		if not ((grabMgr and grabMgr.PickUpBrainrot) or rawEvent) or not dataFolder or not safety then
			farmToggle:Set(false)
			WindUI:Notify({ Title = "Strength to Grow Arms", Content = "Couldn't resolve the game's remotes/folders -- see F9.", Image = "x" })
			warn("[growarms] missing: grabMgr/rawEvent/BrainrotFolder/SafetyBase -- cannot farm")
			return
		end

		gen = gen + 1
		local mine = gen
		rawActive = usingRaw()
		local validated = false -- first confirmed bank proves the deposit path works live
		local rawProven = false -- first confirmed GRAB proves the raw \x18 id is still right
		say(rawActive and "started (raw \\x18 fallback -- unverified until first grab)" or "started")

		task.spawn(function()
			local rawFails = 0
			local function bumpCount()
				count = count + 1
				if countRow then
					countRow:SetDesc(tostring(count))
				end
			end

			while farming and gen == mine do
				local stop, wait = false, CYCLE_WAIT
				-- One pcall around the whole cycle: a respawn can invalidate a handle mid-wait
				-- and indexing it throws; that must pause-and-retry, not kill the worker with
				-- the toggle stuck on.
				local ok, err = pcall(function()
					local cd = carryData()
					if not cd then
						say("paused: no CarryFolder yet (respawning?)")
						wait = 0.5
						return
					end

					-- preflight: a leftover carry makes every pickup fail at MaxCarryNum=1
					if #cd:GetChildren() > 0 then
						local banked, cleared, why = bankAndClear(cd, hopFallback)
						if banked then
							bumpCount()
						end
						if not (banked and cleared) then
							if isTransient(why) then
								wait = 0.5
								return
							end
							say(("stopped: couldn't re-arm a leftover carry (%s) -- %d banked"):format(why, count))
							logf("preflight " .. why)
							stop = true
							return
						end
					end

					local tgt = pickTarget(listBrainrots(target, minPerSec, crossMaps), target)
					if not tgt then
						say(("idle -- no brainrot (%d banked)"):format(count))
						logf("idle")
						return
					end

					pickup(tgt.uid)
					local t0 = os.clock()
					repeat
						task.wait()
					until (carryData() and carryData():FindFirstChild(tgt.uid)) or (os.clock() - t0) > GRAB_TIMEOUT

					local nowCd = carryData()
					if not (nowCd and nowCd:FindFirstChild(tgt.uid)) then
						-- a raw fallback that can't even grab = the \x18 id has almost certainly
						-- moved; the grab (not the bank) is what proves it, so gate on rawProven.
						if rawActive and not rawProven then
							rawFails = rawFails + 1
							if rawFails >= 3 then
								say("stopped: raw \\x18 fallback isn't landing grabs -- the game's remote id likely changed.")
								WindUI:Notify({ Title = "Strength to Grow Arms", Content = "Raw fallback failed -- needs a fresh spy of the RemoteEvent id.", Image = "x" })
								logf("raw grab_failed x" .. rawFails)
								stop = true
								return
							end
						end
						say(("grab_failed on %s -- retrying (%d banked)"):format(tostring(tgt.name), count))
						logf("grab_failed " .. tostring(tgt.name))
						return
					end
					rawProven, rawFails = true, 0 -- the grab landed: the dispatch path is good

					local banked, cleared, why = bankAndClear(nowCd, hopFallback)
					if banked then
						validated = true
						bumpCount()
						if lastRow then
							local mut = tgt.mutates and (" [" .. table.concat(tgt.mutates, ",") .. "]") or ""
							lastRow:SetDesc(("%s%s @ %s = $%s"):format(tostring(tgt.name), mut, tgt.area, tostring(tgt.value)))
						end
						say(("banked %s (%d total)"):format(tostring(tgt.name), count))
						logf("banked " .. tostring(tgt.name))
						if not cleared then
							say(("stopped: banked but the guard wouldn't re-arm (clear_failed) -- %d banked"):format(count))
							stop = true
						end
					elseif isTransient(why) then
						wait = 0.5
					elseif why == "bank_failed" and not validated then
						-- the live self-test failed on the very first deposit
						say("stopped: bank not confirmed. Try enabling 'Bank hop fallback'.")
						WindUI:Notify({ Title = "Strength to Grow Arms", Content = "SafetyBase touch didn't bank -- enable the hop fallback and retry.", Image = "x" })
						logf("bank_failed (first)")
						stop = true
					elseif why == "clear_failed" then
						say(("stopped: deposit guard wouldn't clear (clear_failed) -- %d banked"):format(count))
						logf("clear_failed")
						stop = true
					else
						say(("%s on %s -- retrying (%d banked)"):format(why, tostring(tgt.name), count))
						logf(why .. " " .. tostring(tgt.name))
					end
				end)

				if not ok then
					say("cycle error (respawn?) -- see F9")
					warn("[growarms] cycle error:", err)
					wait = 0.5
				end
				if stop then
					farmToggle:Set(false)
					break
				end
				task.wait(wait)
			end

			if gen == mine then
				say(("stopped -- %d banked"):format(count))
			end
		end)
	end,
})

statusRow = farmCard:Paragraph({ Title = "Status", Desc = "idle" })
lastRow = farmCard:Paragraph({ Title = "Last grab", Desc = "nothing yet" })
countRow = farmCard:Paragraph({ Title = "Banked", Desc = "0" })

if not firetouch then
	WindUI:Notify({ Title = "Strength to Grow Arms", Content = "No firetouchinterest -- banking needs the hop fallback toggle.", Image = "x" })
end

-- plot -----------------------------------------------------------------------
-- Two independent remote-spam loops on valueMgr (脑红). Both are gamepass-free: the server's
-- OneClickGetAllBrainrotIncomeGold and PlaceMaxBrainrot handlers have no gamepass check and
-- no cooldown -- the gamepass only sells the convenience pad in the UI. Own generation
-- counters so off-then-on inside one interval can't leave a second thread running.
local plotCard =
	Tab:Section({ Title = "Plot", Desc = "Collect income + place your best", Icon = "solar:home-smile-bold", Box = true, BoxBorder = true, Opened = true })

local collecting, collectGen = false, 0
local placing, placeGen = false, 0
local MAX_FAILS = 5 -- consecutive pcall failures before a loop gives up and untoggles itself

-- Both methods must exist on the module, not just the module -- a game update could rename
-- or drop one, and an unguarded call would then fail silently forever inside the pcall.
local function needValueMgr(toggle, method)
	if valueMgr and type(valueMgr[method]) == "function" then
		return true
	end
	toggle:Set(false)
	WindUI:Notify({ Title = "Strength to Grow Arms", Content = "The game's plot module changed -- " .. method .. " unavailable (see F9).", Image = "x" })
	warn("[growarms] valueMgr." .. method .. " missing -- feature unavailable")
	return false
end

-- Shared loop body: fire on a beat, auto-disable after MAX_FAILS consecutive errors so a
-- broken remote surfaces instead of retrying in silence. `fire` returns true if it did work.
local function spamLoop(isOn, myGen, genOf, interval, toggle, label, fire)
	task.spawn(function()
		local fails = 0
		while isOn() and genOf() == myGen do
			local ok = pcall(fire)
			if ok then
				fails = 0
			else
				fails = fails + 1
				if fails >= MAX_FAILS then
					warn("[growarms] " .. label .. " disabled after " .. fails .. " errors")
					toggle:Set(false)
					break
				end
			end
			task.wait(interval)
		end
	end)
end

local collectToggle
collectToggle = plotCard:Toggle({
	Title = "Auto collect cash",
	Desc = "Banks all placed-brainrot income every " .. COLLECT_EVERY .. "s (no gamepass needed)",
	Value = false,
	Callback = function(state)
		collectGen = collectGen + 1 -- bump on every call so a stale sleeping loop dies on off too
		collecting = state
		if not state or not needValueMgr(collectToggle, "OneClickGetAllBrainrotIncomeGold") then
			return
		end
		local mine = collectGen
		spamLoop(function()
			return collecting
		end, mine, function()
			return collectGen
		end, COLLECT_EVERY, collectToggle, "auto collect", function()
			valueMgr:OneClickGetAllBrainrotIncomeGold(player)
		end)
	end,
})

local placeToggle
placeToggle = plotCard:Toggle({
	Title = "Auto place best",
	Desc = "Fills empty slots and replaces weaker ones with your highest $/s brainrots",
	Value = false,
	Callback = function(state)
		placeGen = placeGen + 1
		placing = state
		if not state or not needValueMgr(placeToggle, "PlaceMaxBrainrot") then
			return
		end
		local mine = placeGen
		-- PlaceMaxBrainrot re-settles every slot on each call, so only fire when the inventory
		-- actually changed (a new brainrot was banked) -- otherwise it churns server state and
		-- spams the tutorial warning every interval for nothing.
		local lastInv
		spamLoop(function()
			return placing
		end, mine, function()
			return placeGen
		end, PLACE_EVERY, placeToggle, "auto place", function()
			local inv = ownBrainrot and ownBrainrot.Value
			if inv and inv ~= lastInv then
				lastInv = inv
				valueMgr:PlaceMaxBrainrot(player)
			end
		end)
	end,
})

-- close ----------------------------------------------------------------------
-- The red topbar button destroys the window after WindUI's own confirm; teardown hangs off
-- OnDestroy, and the stop hook shares it. ponytail: rerun to come back.
local function shutdown()
	farming, collecting, placing = false, false, false
	gen, collectGen, placeGen = gen + 1, collectGen + 1, placeGen + 1 -- orphan any running loop
end

Window:OnDestroy(function()
	shutdown()
	if getgenv then
		getgenv().growArmsStop = nil
	end
end)

if getgenv then
	getgenv().growArmsStop = function()
		shutdown()
		pcall(function()
			Window:Destroy()
		end)
		getgenv().growArmsStop = nil
	end
end
