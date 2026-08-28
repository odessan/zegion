--[[ Dump -- one pass over the whole DataModel: place file, scripts, pivots.

     Why this doesn't care that every map is laid out differently: it never names a
     path. It starts at the services, walks down, and decides what to do from
     ClassName alone -- GetFullName() becomes the output path. A different game
     changes the shape of the output folder, not a line of this script. There is
     nothing to port per map, so there is nothing to keep in sync.

     Output, under the executor's workspace folder:

         dump/<PlaceId>/place.rbxlx     whole game: models, meshes, textures
         dump/<PlaceId>/scripts/...     one .lua per script, mirroring the tree
         dump/<PlaceId>/tp.txt          pivots, paste a whole line into pivot_tp.lua
         dump/<PlaceId>/manifest.txt    every instance: class, path, pivot, facts
         dump/<PlaceId>/remotes.txt     just the remotes, one per line
         dump/<PlaceId>/classes.txt     class census, commonest first

     manifest.txt is the part that replaces per-map knowledge -- grep it for
     "SpawnLocation", "ProximityPrompt", a boss name, whatever, and you have the
     path and the CFrame without ever having opened Dex. The fourth column is
     attributes/tags plus the handful of real properties a filter ever branches on
     (a prompt's ActionText, a Model's PrimaryPart, a Sound's id), so
     `grep Rarity=OG` hands you the filter and the path together -- that column is
     what the collect loops actually key off.

     classes.txt answers "what is even in this game" in one screen, and hands you
     the exact ClassName to grep the manifest for.

     tp.txt puts the CFrame first and the path after, because pivot_tp.lua reads the
     first 12 numbers on the line -- a path like Zone1.Pad2 would otherwise donate
     its digits to the front of the parse.

     Paths prefixed "nil!" came from getnilinstances(): Parent is nil, so the
     path is a name, not a route. You reach them by holding the reference.

     Progress goes to F9: a `[dump]` line every TICK seconds while it walks, and one
     per phase. If the last line you see is "saveinstance", it isn't hung -- that call
     is single-threaded inside the executor and can freeze the client for a minute.

     Executor only (needs writefile/makefolder). saveinstance and decompile are both
     optional; whichever is missing gets skipped with a note instead of erroring. ]]

-- config ---------------------------------------------------------------------
local DO_PLACE = true -- saveinstance the whole place
local DO_SCRIPTS = true -- decompile every script to its own file
local DO_PIVOTS = true -- manifest + tp.txt
local DO_COREGUI = false -- Roblox's own UI: tens of thousands of rows, occasionally
-- the answer (the rejoin scripts key off CoreGui.RobloxPromptGui.promptOverlay)

local ROOTS = { -- services worth walking; missing ones are skipped
	"Workspace",
	"ReplicatedStorage",
	"ReplicatedFirst",
	"Lighting",
	"StarterGui",
	"StarterPack",
	"StarterPlayer",
	"SoundService",
	"Teams",
	"MaterialService",
	"Players", -- Player objects hang leaderstats/attributes off themselves, not the character
	"TextChatService",
}

local YIELD_EVERY = 2000 -- instances per frame; lower it if the client hitches
local MAX_SEG = 40 -- truncate each path segment, OS limit is 255
local TICK = 2 -- seconds between F9 progress lines; 0 spams, this loop is hot

-- Names that usually mean "somewhere you'd want to stand". Add the game's own
-- vocabulary here once you've skimmed manifest.txt -- that's the only per-game knob.
local NAME_HINTS = { "spawn", "checkpoint", "teleport", "portal", "pad", "shop", "base" }

-- setup ----------------------------------------------------------------------
assert(writefile and makefolder, "executor only: needs writefile + makefolder")

local Players = game:GetService("Players")
local base = "dump/" .. tostring(game.PlaceId)

local t0 = os.clock()
local lastTick = 0
-- One printer for every progress line, so the throttle can't be forgotten at a call
-- site inside the walk. Phase lines call print directly -- they fire a handful of
-- times and must not be swallowed by a tick that just happened.
local function tick(fmt, ...)
	if os.clock() - lastTick < TICK then
		return
	end
	lastTick = os.clock()
	print("[dump] " .. string.format(fmt, ...))
end

local madeFolders = {}
local function ensure(dir)
	if madeFolders[dir] then
		return
	end
	madeFolders[dir] = true
	local acc = ""
	for seg in dir:gmatch("[^/]+") do
		acc = acc == "" and seg or (acc .. "/" .. seg)
		pcall(makefolder, acc) -- already-exists is not worth an isfolder call
	end
end

ensure(base)

-- paths ----------------------------------------------------------------------
-- ponytail: segment truncation only. Deep enough trees can still blow the total
-- path limit; switch to a flat name + a lookup column in the manifest if that bites.
local function sanitize(name)
	return (name:gsub("[^%w%._%- ]", "_"):sub(1, MAX_SEG))
end

local usedPaths = {}
local function pathOf(inst, ext)
	local segs = {}
	local node = inst
	while node and node ~= game do
		table.insert(segs, 1, sanitize(node.Name))
		node = node.Parent
	end
	local p = base .. "/scripts/" .. table.concat(segs, "/")
	-- Siblings are allowed to share a name in Roblox; files are not.
	local unique, i = p, 1
	while usedPaths[unique] do
		i += 1
		unique = p .. "~" .. i
	end
	usedPaths[unique] = true
	return unique .. ext
end

local function hasHint(name)
	name = name:lower()
	for _, hint in ipairs(NAME_HINTS) do
		if name:find(hint, 1, true) then
			return true
		end
	end
	return false
end

local function fmtCF(cf)
	local out = {}
	for _, v in ipairs({ cf:GetComponents() }) do
		out[#out + 1] = string.format("%.6g", v)
	end
	return table.concat(out, ", ")
end

-- Not every game moved its facts into attributes. The older ones leave them in real
-- properties, and a few of those are exactly what a loop branches on: whether a
-- prompt is the paid-steal variant (ActionText), whether a Model is safe to MoveTo
-- (PrimaryPart), which asset a Sound/Animation actually plays. Keyed by exact
-- ClassName -- inheritance would drag in every BasePart and double the file.
-- ponytail: hand-picked list; add a class when you find yourself opening Dex for it.
local PROPS = {
	ProximityPrompt = { "ActionText", "ObjectText", "HoldDuration", "MaxActivationDistance", "Enabled" },
	ClickDetector = { "MaxActivationDistance" },
	Sound = { "SoundId" },
	Animation = { "AnimationId" },
	MeshPart = { "MeshId" },
	SpecialMesh = { "MeshId" },
	Decal = { "Texture" },
	ImageLabel = { "Image" },
	ImageButton = { "Image" },
	Humanoid = { "Health", "MaxHealth", "WalkSpeed", "JumpPower" },
	Tool = { "RequiresHandle" },
	Model = { "PrimaryPart" },
	BillboardGui = { "Adornee" },
	TextBox = { "PlaceholderText" },
}

-- Attributes and tags are where the modern games keep Rarity/CashPerSec/Zone --
-- the exact fields every filter greps for. Class + path can't answer "which one".
local function extra(inst)
	local out = {}
	local ok, attrs = pcall(inst.GetAttributes, inst)
	if ok then
		for k, v in pairs(attrs) do
			out[#out + 1] = k .. "=" .. tostring(v)
		end
	end
	local ok2, tags = pcall(inst.GetTags, inst) -- older clients have no GetTags
	if ok2 then
		for _, t in ipairs(tags) do
			out[#out + 1] = "#" .. t
		end
	end
	for _, prop in ipairs(PROPS[inst.ClassName] or {}) do
		local ok3, v = pcall(function()
			return inst[prop]
		end)
		-- Skip the defaults: an empty SoundId or a nil PrimaryPart is the absence of
		-- a fact, and printing it on every row is what makes a column unreadable.
		if ok3 and v ~= nil and v ~= "" then
			out[#out + 1] = prop .. "=" .. tostring(typeof(v) == "Instance" and v.Name or v):gsub("%s+", " ")
		end
	end
	if inst:IsA("ValueBase") then
		out[#out + 1] = "Value=" .. tostring(inst.Value)
	elseif inst:IsA("TextLabel") or inst:IsA("TextButton") then
		out[#out + 1] = "Text=" .. inst.Text:gsub("%s+", " ") -- overhead GUI text is a filter
	end
	return table.concat(out, " ")
end

do -- the whole point of the column is that it's greppable; check it stays that way
	local probe = Instance.new("StringValue")
	probe.Value = "v"
	probe:SetAttribute("Rarity", "OG")
	local col = extra(probe)
	assert(col:find("Rarity=OG", 1, true) and col:find("Value=v", 1, true), "extra() broken")
	probe:Destroy()

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Steal  for 500"
	local pcol = extra(prompt)
	assert(pcol:find("ActionText=Steal for 500", 1, true), "PROPS lookup broken")
	assert(not pcol:find("ObjectText", 1, true), "empty props must not print")
	prompt:Destroy()
end

-- walk -----------------------------------------------------------------------
local stack = {}
for _, name in ipairs(ROOTS) do
	local ok, svc = pcall(game.GetService, game, name)
	if ok and svc then
		stack[#stack + 1] = svc
	end
end
if Players.LocalPlayer then
	stack[#stack + 1] = Players.LocalPlayer -- PlayerGui holds what StarterGui became
end
if DO_COREGUI then
	pcall(function()
		stack[#stack + 1] = game:GetService("CoreGui")
	end)
end

-- Games park remotes and modules at Parent = nil precisely so a tree walk misses
-- them. Their descendants come along for free once the root is on the stack.
if getnilinstances then
	local ok, nils = pcall(getnilinstances)
	if ok then
		table.move(nils, 1, #nils, #stack + 1, stack)
	end
end

-- A module that was required and then had its Parent cleared is invisible to both
-- the walk and (on some executors) getnilinstances, and required modules are where
-- the game keeps the config tables worth requiring yourself.
if getloadedmodules then
	local ok, mods = pcall(getloadedmodules)
	if ok then
		table.move(mods, 1, #mods, #stack + 1, stack)
	end
end

-- Half the map not being in the dump is streaming, not a bug in the walk.
if workspace.StreamingEnabled then
	warn("[dump] StreamingEnabled: only the region loaded around you is here. Fly the map and re-run to fill it in.")
end

print(string.format(
	"[dump] place %d, %s | %d roots queued | place=%s scripts=%s pivots=%s coregui=%s",
	game.PlaceId,
	identifyexecutor and identifyexecutor() or "unknown executor", -- and/or drops the version
	#stack,
	tostring(DO_PLACE),
	tostring(DO_SCRIPTS),
	tostring(DO_PIVOTS),
	tostring(DO_COREGUI)
))

local manifest, tps, remotes = {}, {}, {}
local tpSeen, classCount = {}, {}
local count, scriptCount, failCount = 0, 0, 0

-- A prompt or a spawn is the useful marker, but the CFrame lives on the part or
-- model holding it, so walk up to the nearest thing that has a pivot.
local function markTp(inst, why)
	local pv = inst
	while pv and not pv:IsA("PVInstance") do
		pv = pv.Parent
	end
	if not pv or tpSeen[pv] then
		return
	end
	tpSeen[pv] = true
	local ok, cf = pcall(pv.GetPivot, pv)
	if ok then
		-- CFrame first: pivot_tp.lua takes the first 12 numbers on whatever you paste,
		-- and a path is free to contain digits.
		tps[#tps + 1] = string.format("CFrame.new(%s)\t[%s]\t%s", fmtCF(cf), why, pv:GetFullName())
	end
end

local seen = {} -- Opiumware's getnilinstances() hands back the whole instance cache, not
-- just the orphans, so without this every instance gets walked twice: two manifest rows,
-- two remote rows, and every script written again as Name~2.lua.

while #stack > 0 do
	local inst = table.remove(stack)
	if seen[inst] then
		continue
	end
	seen[inst] = true
	count += 1
	classCount[inst.ClassName] = (classCount[inst.ClassName] or 0) + 1
	if count % YIELD_EVERY == 0 then
		task.wait()
		-- #stack is the honest progress bar: it climbs while the walk finds new
		-- branches and drains once it's only descending. There's no total to divide by.
		tick("walking: %d seen, %d queued, %d scripts, %d remotes", count, #stack, scriptCount, #remotes)
	end

	local ok, kids = pcall(inst.GetChildren, inst)
	if ok then
		table.move(kids, 1, #kids, #stack + 1, stack)
	end

	if DO_PIVOTS then
		local pivot = ""
		if inst:IsA("PVInstance") then
			local ok2, cf = pcall(inst.GetPivot, inst)
			pivot = ok2 and fmtCF(cf) or ""
		end
		local full = inst:GetFullName()
		if not inst:IsDescendantOf(game) then
			full = "nil!" .. full
		end
		manifest[#manifest + 1] = table.concat({ inst.ClassName, full, pivot, extra(inst) }, "\t")

		if inst:IsA("SpawnLocation") then
			markTp(inst, "spawn")
		elseif inst:IsA("ProximityPrompt") or inst:IsA("ClickDetector") then
			markTp(inst, inst.ClassName)
		elseif hasHint(inst.Name) then
			markTp(inst, "name")
		elseif inst:IsA("Model") and inst.Parent == workspace then
			markTp(inst, "top-level")
		end
	end

	-- The remotes are what you end up scripting against, and manifest.txt buries
	-- them under a hundred thousand parts. BaseRemoteEvent covers the unreliable one.
	if
		inst:IsA("BaseRemoteEvent")
		or inst:IsA("RemoteFunction")
		or inst:IsA("BindableEvent")
		or inst:IsA("BindableFunction")
	then
		remotes[#remotes + 1] = inst.ClassName .. "\t" .. inst:GetFullName()
	end

	if DO_SCRIPTS and inst:IsA("LuaSourceContainer") then
		local src, readable
		local ok2, res = pcall(function()
			return inst.Source
		end)
		if ok2 and res ~= "" then -- Studio, or an executor with source access
			src, readable = res, true
		elseif decompile then
			local ok3, out = pcall(decompile, inst)
			-- Write the failure note anyway: knowing a script exists and refuses to
			-- decompile beats it silently missing from the tree. It just isn't a win.
			src, readable = ok3 and out or ("-- decompile failed: " .. tostring(out)), ok3
			task.wait() -- decompiling a few hundred scripts back to back freezes the client
		end
		if src then
			local p = pathOf(inst, ".lua")
			ensure(p:match("(.*)/"))
			if pcall(writefile, p, src) and readable then
				scriptCount += 1
			else
				failCount += 1
			end
			-- Decompiling task.waits per script, so the walk tick above can stay silent
			-- for minutes here. Name the file: a decompiler that hangs hangs on one
			-- specific script, and this line is how you learn which one.
			tick("scripts: %d written, %d unreadable (%s)", scriptCount, failCount, inst.Name)
		else
			failCount += 1
		end
	end
end

-- write ----------------------------------------------------------------------
print(string.format("[dump] walk done in %.1fs: %d instances -- writing txt files", os.clock() - t0, count))

if DO_PIVOTS then
	writefile(base .. "/manifest.txt", table.concat(manifest, "\n"))
	writefile(base .. "/tp.txt", table.concat(tps, "\n"))
end

table.sort(remotes) -- groups Knit/Net folders together, which is how you read them
writefile(base .. "/remotes.txt", table.concat(remotes, "\n"))

-- Commonest first, because the tail is the interesting part: the one Seat, the three
-- ProximityPrompts, the class you didn't know the game used and can now grep for.
local classN = 0
do
	local rows = {}
	for class, n in pairs(classCount) do
		rows[#rows + 1] = { class, n }
	end
	classN = #rows
	table.sort(rows, function(a, b)
		return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1])
	end)
	for i, r in ipairs(rows) do
		rows[i] = r[2] .. "\t" .. r[1]
	end
	writefile(base .. "/classes.txt", table.concat(rows, "\n"))
end

if DO_PLACE then
	-- Signatures differ across executors, so try the modern one and fall back to
	-- the bare call, which drops the file wherever that executor defaults to.
	-- No saveinstance? Grab one yourself and run it before this script:
	--   loadstring(game:HttpGet("<UniversalSynSaveInstance raw url>"))()
	local si = saveinstance or synsaveinstance
	if si then
		-- Last line before a minute-long client freeze; say so or it reads as a hang.
		print("[dump] saveinstance: serializing the place, the client will freeze here")
		if not pcall(si, { FilePath = base .. "/place.rbxlx" }) then
			pcall(si)
		end
		print("[dump] saveinstance returned")
	else
		warn("[dump] no saveinstance -- place file skipped")
	end
end

print(string.format(
	"[dump] done in %.1fs | %d instances | %d classes | %d scripts (%d unreadable) | %d remotes | %d tp points -> %s",
	os.clock() - t0,
	count,
	classN,
	scriptCount,
	failCount,
	#remotes,
	#tps,
	base
))
