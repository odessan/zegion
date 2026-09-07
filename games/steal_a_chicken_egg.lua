--[[ Steal a Chicken Egg -- nest farm across all ten play zones (76503495566299)

     FARM   : scores every nest on the map at once -- getNestContents answers for
              every zone from anywhere, and the map key IS the nest position, so
              there is no zone to walk to and nothing to wait for streaming. Picks
              the best by your chosen priority, hops there, steals, carries home.
              Arriving at your base deposits the chicken by itself.
     CLAIM  : claims pen eggs the moment they ripen, read off the game's own store
              rather than polled off the world. Runs on its own thread.
     SELL   : teleports to the sell zone and empties the egg inventory once you
              are holding SELL_AT of them.

     Executor only: the panel is WindUI, fetched with HttpGet, which Studio blocks.
     RightControl rolls it up to a bare Zegion pill, RightAlt hides it outright.
     Stop: getgenv().stealChickenEggStop() ]]

-- config ---------------------------------------------------------------------
local CHUNK = 60 -- studs per teleport step. A single long hop can land you inside
-- terrain and get you ejected; 60 was measured covering 1759 studs in 39 hops with
-- nothing reverted. Raise for speed, lower if hops start coming up short.
local CHUNK_GAP = 0.25 -- seconds between hops. Not a rate limit -- three hops 0.1s
-- apart all stuck -- just time for the server to see each one.
local SETTLE = 0.35 -- seconds after arriving before firing. The server range-checks
-- against where it thinks you are, not where you are.
local SCAN_EVERY = 20 -- seconds between full zone rescans. Nests reroll on their own;
-- an inbound refreshNests also forces one, so this is only the backstop.
local PARK = 30 -- seconds a refused nest is skipped for
local MISS_STRIKES = 3 -- consecutive "could not get in range" before parking a target.
-- Separate from a refusal on purpose: an unreachable nest never refuses, so without
-- this it sits at the head of a best-first queue forever.
local GRAB_TIMEOUT = 8 -- seconds for one whole grab, watchdog only
local CLAIM_POLL = 5 -- seconds between ripe-egg checks
local SELL_AT = 10 -- eggs held before a sell trip. An Input, tunable live.
local INSANE_RANGE = 19 -- approach distance for an insane chicken. Its prompt reaches
-- 31-48, but that is a CLIENT gate and says nothing about the server's, so this stays
-- at the nest distance until someone measures it.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CS = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

if getgenv and getgenv().stealChickenEggStop then
	getgenv().stealChickenEggStop() -- re-running must not stack a second panel
end

local function say(fmt, ...)
	print("[chickenegg] " .. string.format(fmt, ...))
end

local function warnf(fmt, ...)
	warn("[chickenegg] " .. string.format(fmt, ...))
end

local ok, remotes = pcall(require, RS.shared.remotes)
if not ok then
	return warnf("cannot require shared.remotes (%s) -- game updated?", tostring(remotes))
end
local nestsIF = require(RS.shared.gameData.nests.nestsIF)
local insaneIF = require(RS.shared.gameData.nests.insaneEggsIF)
local nestUT = require(RS.shared.utils.nestUT)
local chickenUT = require(RS.shared.utils.chickenUT)
local penUT = require(RS.shared.utils.penUT)

local STEAL_RANGE = nestsIF.maxStealDistance -- 19 at time of writing; read, never typed

-- world ----------------------------------------------------------------------
-- travel ---------------------------------------------------------------------
-- farm -----------------------------------------------------------------------
-- base -----------------------------------------------------------------------
-- gui ------------------------------------------------------------------------
local PANEL_URL = "https://raw.githubusercontent.com/odessan/Zegion/main/panel.lua"
local panel = loadstring(game:HttpGet(PANEL_URL))()
local Window, WindUI = panel({
	game = "Steal a Chicken Egg",
	folder = "StealAChickenEgg", -- never rename: WindUI saves configs under this
	size = UDim2.fromOffset(520, 460),
})
if not Window then
	return -- panel.lua already said why
end

local Tab = Window:Tab({ Title = "Main", Icon = "solar:egg-bold" })

-- close ----------------------------------------------------------------------
local function stopAll()
	-- later tasks add their loop flags here
end

Window:OnDestroy(function()
	stopAll()
	getgenv().stealChickenEggStop = nil
end)

getgenv().stealChickenEggStop = function()
	stopAll()
	pcall(function()
		Window:Destroy()
	end)
	getgenv().stealChickenEggStop = nil
end

say("ready -- steal range %d, %d zones", STEAL_RANGE, (function()
	local n = 0
	for _ in pairs(nestsIF.zoneAreas) do
		n += 1
	end
	return n
end)())
