--[[ Zegion -- one paste for every game in this repo

     loadstring(game:HttpGet("https://raw.githubusercontent.com/odessan/Zegion/main/loader.lua"))()

     Paste this and nothing else. It looks up game.PlaceId, fetches that game's script
     and runs it. In a game with no script it says so and stops.

     Adding a game: one line in GAMES. When the loader tells you a game is unsupported
     it prints the exact line to add and puts the PlaceId on your clipboard, so the
     round trip is paste -> copy the warning -> add the line.

     Re-running is safe: every script here owns a getgenv().<name>Stop() that the next
     run calls before building a second panel. ]]

-- config ---------------------------------------------------------------------
-- Raw file host + the games folder, trailing slash included. Nothing else in this file
-- is host-specific, so moving the repo is a one-line change. This loader lives one
-- level up, at .../main/loader.lua -- that's the URL you paste.
local BASE = "https://raw.githubusercontent.com/odessan/Zegion/main/games/"

-- raw.githubusercontent caches ~5 min. A pushed edit that "didn't take" is this, not
-- the script -- flip this on while iterating, off when you just want the CDN copy.
local NOCACHE = false

-- PlaceId -> file. Only ids I could actually confirm are in here: a wrong id is worse
-- than a missing one, because the loader would quietly run the wrong game's script
-- instead of saying "not supported".
-- Comment is the game's CURRENT name on Roblox, which drifts -- 123822115505881 shipped
-- as "Steal an Animal" and is "Save Animals!" now. Trust the id, not the name.
local GAMES = {
	["84332574190497"] = "wings_for_brainrots.lua", -- +1 Wings for Brainrots
	["80234914611737"] = "jetpack_for_brainrots.lua", -- +1 Jetpack for Brainrots
	["123822115505881"] = "steal_an_animal.lua", -- Save Animals! (was Steal an Animal)
	["87810710637189"] = "poop_for_brainrots.lua", -- +1 Poop for Brainrots
	["115852335239914"] = "skate_for_brainrots.lua", -- +1 Skate for Brainrots
	["98916904742148"] = "surf_for_brainrots.lua", -- Surf for Lucky Blocks
	["139063887391814"] = "one_dropper_tycoon.lua", -- TBOD^2
	["104339804279870"] = "break_tape_for_brainrots.lua", -- Break Tape For Brainrots
	["137233438285284"] = "chicken_farm.lua", -- Chicken Farm
	["90086669327265"] = "cut_grass_adventure.lua", -- +1 Cut Grass Adventure
	["102602309625870"] = "dancing_animals.lua", -- My Dancing Animals!
	["86368783421928"] = "fall_for_brainrots.lua", -- Fall For Brainrots!
	["136066387156306"] = "flash_for_brainrots.lua", -- Be Flash For Brainrots!
	["72896199592423"] = "my_seafood_stand.lua", -- My Seafood Stand!
	["94702395375549"] = "run_for_brainrots.lua", -- Run For Brainrots!
	["119822977170203"] = "power_blast_lucky_block.lua", -- Power Blast Lucky Block
	["114640202062357"] = "swing_obby_for_brainrots.lua", -- Swing Obby for Brainrots!
	["88207898227053"] = "build_bridge_for_brainrots.lua", -- Build a Bridge for Brainrots

	-- Two soccer games fit this one and I couldn't tell them apart from the outside.
	-- The script scans for models named "Lucky Block" and carries them to a base, which
	-- is what "Jump To Steal Soccer Players" describes; "Jump for Soccer Players!"
	-- (122816304079935) matches the filename but spawns players, not blocks. Wrong one?
	-- Swap the id -- the panel opening in a game where nothing spawns is the tell.
	["133294838637122"] = "jump_for_soccer_players.lua", -- Jump To Steal Soccer Players

	-- Confirmed from its own dump, not guessed: SharedModules.SoccerPlayerRegistry,
	-- workspace.Live.Slimes and the Place Slime / Open Lucky Block remotes all match.
	["140417239274110"] = "run_for_soccer_players.lua", -- Run For Soccer Players

	-- Its own update board calls it "Fish an Anime! [v1.9.10416]"; it's listed as an
	-- anime RNG fishing game, so both names find it.
	["74729868188364"] = "fish_for_anime_rng.lua", -- Fish an Anime!

	-- Confirmed from its own dump: Events.SummonBrainrots, workspace.Locations 1..16+End
	-- and GuardClient's catch loop all match. The panel shows the live name on top.
	["99255447043899"] = "become_a_brainrot.lua", -- Become a Brainrot

	-- Confirmed from its own dump: workspace.ActiveItems, Shared.BrainrotConfig and the
	-- FakeSystem_StartFake remotes all match.
	["110627433764494"] = "fake_a_brainrot.lua", -- Fake a Brainrot

	-- Same engine as the two soccer games -- workspace.Live.Slimes, SlimeRegistry, the
	-- Drop Slime / Open Lucky Block remotes -- with an SCP skin and a vertical tower.
	-- Confirmed from its own dump.
	["123724279728430"] = "jump_for_scp.lua", -- Jump for SCP

	-- Confirmed from its own dump: workspace.GeneratedStages.Stage_N.Ores, the single
	-- Remotes.MessageBus dispatcher and Shared.Config.MineConfig all match.
	["119409763193569"] = "dig_into_secrets.lua", -- Dig Into Secrets

	-- Confirmed from its own dump: the TornadoRemotes trio, workspace.Spawners with its
	-- eighteen SpawnPlace<Rarity> folders and ReplicatedStorage.BrainrotData all match.
	["72833051149233"] = "tornado_for_brainrots.lua", -- Tornado for Brainrots

	-- Confirmed from its own dump: ReplicatedStorage.RemoteEvent (BridgeNet), the
	-- Manager_获取脑红 PickUpBrainrot/HitWall remotes, workspace.BrainrotFolder.data and
	-- Map.SafetyBase all match. Farms by grabbing brainrots by uid -- no character movement.
	["86259628805375"] = "strength_to_grow_arms.lua", -- Strength to Grow Arms

	-- dump / dump_v2 aren't here, and aren't in the repo at all: they're local tools you
	-- paste in when you want them, not things that should fire the moment you join.
}

-- loader ---------------------------------------------------------------------
if not game:IsLoaded() then
	game.Loaded:Wait() -- PlaceId is set before this, but HttpGet during join is flaky
end

-- The built-in toast, not WindUI: pulling a 1.3MB UI library down just to say "no
-- script for this game" is the one case where the panel isn't worth its own download.
local function notify(title, text)
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification", {
			Title = title,
			Text = text,
			Duration = 6,
		})
	end)
end

local id = tostring(game.PlaceId)
local file = GAMES[id]

if not file then
	notify("Not supported", "No script for PlaceId " .. id)
	-- The console gets the line to paste rather than just the id, so adding a game is
	-- copy-paste and not retyping. Clipboard too, when the executor has it.
	warn(("[zegion] %s is not supported. Add to GAMES:\n\t[\"%s\"] = \"your_script.lua\","):format(id, id))
	if setclipboard then
		pcall(setclipboard, id)
	end
	return
end

-- Both failures are worth telling apart on screen: a fetch that failed is the host or
-- the filename, a compile that failed is the script itself.
local url = BASE .. file .. (NOCACHE and ("?t=" .. tick()) or "")
local ok, source = pcall(game.HttpGet, game, url)
if not ok then
	notify("Zegion failed", "Couldn't fetch " .. file)
	warn("[zegion] HttpGet", url, source)
	return
end

local fn, err = loadstring(source)
if not fn then
	notify("Zegion failed", file .. " didn't compile")
	warn("[zegion] loadstring", err)
	return
end

notify("Zegion", file)
fn()
