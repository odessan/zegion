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
	["102990893659741"] = "brainblast_for_brainrot.lua", -- Brainblast for Brainrot
	["133294838637122"] = "jump_for_soccer_players.lua", -- Jump To Steal Soccer Players
	["140417239274110"] = "run_for_soccer_players.lua", -- Run For Soccer Players
	["74729868188364"] = "fish_for_anime_rng.lua", -- Fish an Anime RNG!
	["99255447043899"] = "become_a_brainrot.lua", -- Become a Brainrot
	["110627433764494"] = "fake_a_brainrot.lua", -- Fake a Brainrot
	["123724279728430"] = "jump_for_scp.lua", -- Jump for SCP
	["119409763193569"] = "dig_into_secrets.lua", -- Dig Into Secrets
	["72833051149233"] = "tornado_for_brainrots.lua", -- Tornado for Brainrots
	["86259628805375"] = "strength_to_grow_arms.lua", -- Strength to Grow Arms
	["93978595733734"] = "violence_district.lua", -- Violence District
	["80861715191104"] = "pull_a_lucky_block.lua", -- Pull a Lucky Block
	["103050497819513"] = "steal_a_brainrot_base.lua", -- Steal a Brainrot Base
	["86943068337855"] = "drill_block_for_dumpling_squishy.lua", -- Drill Block for Dumpling Squishy
	["122572082932179"] = "drill_ores.lua", -- Drill Ores
	["112781315318195"] = "pull_a_lucky_fish.lua", -- Pull a Lucky Fish
<<<<<<< HEAD
	["70640255604878"] = "pull_an_egg.lua", -- Pull an Egg
	["120135584963579"] = "dont_steal_a_bobo.lua", -- Don't Steal a Bobo
	["76503495566299"] = "steal_a_chicken_egg.lua", -- Steal a Chicken Egg
=======
	["99183404085821"] = "steal_a_fish_egg.lua", -- Steal a Fish Egg
>>>>>>> 03105d0 (Add new script 'steal_a_fish_egg' for PlaceId 99183404085821 and update loader and README.md to include it.)

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
