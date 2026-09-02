# Zegion

Roblox automation scripts, one per game, served by a loader. Paste this and nothing else:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/odessan/Zegion/main/loader.lua"))()
```

The loader reads `game.PlaceId`, fetches that game's script and runs it. In a game with
no script it says so and stops.

## How it fits together

```
loader.lua      PlaceId -> games/<file>.lua, fetch, run
panel.lua       the window every script builds its UI in (WindUI, topbar, shade, keys)
games/*.lua     one self-contained script per game
```

Three files deep, on purpose. A game script fetches `panel.lua` itself rather than
relying on the loader to have installed it, so **any script here also pastes and runs on
its own** — handy when you're iterating on one and don't want the loader's cache in the
way.

## Using the panel

| Key | What |
|---|---|
| `RightControl` | minimise / expand — the body rolls up to a bare Zegion pill |
| `RightAlt` | hide the window outright, for a screenshot |

Loops keep running under either. The red topbar button unloads the script; re-paste to
bring it back. Every script also owns a `getgenv().<name>Stop()`, and re-running one
calls the previous copy's stop first, so you never stack two panels or two loops.

Diagnostics go to the F9 console — `warn` for problems, `[name]` prefixed prints for
progress. When a script "does nothing", the answer is in there.

## Supported games

Names drift on Roblox; trust the id. The panel shows the live name on its topbar.

| Game | PlaceId | Script |
|---|---|---|
| +1 Cut Grass Adventure | `90086669327265` | `cut_grass_adventure.lua` |
| +1 Jetpack for Brainrots | `80234914611737` | `jetpack_for_brainrots.lua` |
| +1 Poop for Brainrots | `87810710637189` | `poop_for_brainrots.lua` |
| +1 Skate for Brainrots | `115852335239914` | `skate_for_brainrots.lua` |
| +1 Wings for Brainrots | `84332574190497` | `wings_for_brainrots.lua` |
| Be Flash For Brainrots! | `136066387156306` | `flash_for_brainrots.lua` |
| Become a Brainrot | `99255447043899` | `become_a_brainrot.lua` |
| Break Tape For Brainrots | `104339804279870` | `break_tape_for_brainrots.lua` |
| Build a Bridge for Brainrots | `88207898227053` | `build_bridge_for_brainrots.lua` |
| Chicken Farm | `137233438285284` | `chicken_farm.lua` |
| Dig Into Secrets | `119409763193569` | `dig_into_secrets.lua` |
| Fake a Brainrot | `110627433764494` | `fake_a_brainrot.lua` |
| Fall For Brainrots! | `86368783421928` | `fall_for_brainrots.lua` |
| Fish an Anime! | `74729868188364` | `fish_for_anime_rng.lua` |
| Jump for SCP | `123724279728430` | `jump_for_scp.lua` |
| Jump To Steal Soccer Players | `133294838637122` | `jump_for_soccer_players.lua` |
| My Dancing Animals! | `102602309625870` | `dancing_animals.lua` |
| My Seafood Stand! | `72896199592423` | `my_seafood_stand.lua` |
| Power Blast Lucky Block | `119822977170203` | `power_blast_lucky_block.lua` |
| Run For Brainrots! | `94702395375549` | `run_for_brainrots.lua` |
| Run For Soccer Players | `140417239274110` | `run_for_soccer_players.lua` |
| Save Animals! (was Steal an Animal) | `123822115505881` | `steal_an_animal.lua` |
| Strength to Grow Arms | `86259628805375` | `strength_to_grow_arms.lua` |
| Surf for Lucky Blocks | `98916904742148` | `surf_for_brainrots.lua` |
| Swing Obby for Brainrots! | `114640202062357` | `swing_obby_for_brainrots.lua` |
| TBOD^2 | `139063887391814` | `one_dropper_tycoon.lua` |
| Tornado for Brainrots | `72833051149233` | `tornado_for_brainrots.lua` |
| Violence District | `93978595733734` | `violence_district.lua` |

`GAMES` in `loader.lua` is the source of truth. Only ids that were actually confirmed
are in it — a wrong id is worse than a missing one, because the loader would quietly run
another game's script instead of saying "not supported".

## Adding a game

Run the loader in the new game first. It prints the exact line to add and puts the
PlaceId on your clipboard, so the round trip is paste → copy the warning → add the line:

```lua
["<PlaceId>"] = "your_script.lua",
```

Then write `games/your_script.lua`. The quickest way in is to copy the closest existing
script — they're all the same skeleton — and replace the middle:

```
header      what each control does, in the words of someone using it
config      every tunable as a named local, with why you'd change it
world       finding things, moving around
<feature>   the actual loops
shell       panel.lua -> Window -> tabs, cards, toggles
close       one shutdown(), hung off Window:OnDestroy and getgenv().<name>Stop
```

Two habits that decide whether a script survives a game update:

- **Find things by shape, not by path.** Walk services by `ClassName`, pattern-match
  remote names, filter on an attribute — a hardcoded path is a bet that the game never
  moves anything. Hardcode only when you've checked there's no stable shape, and say so
  in a comment.
- **Never trust a return value for "did it work".** Wait for the world to change instead:
  the item left the folder, a Tool appeared on your character, the prompt went dark.

`CLAUDE.md` has the long version — the full skeleton, the recurring gameplay idioms, the
remote-path shapes worth recognising, and the streaming pitfalls. It's local-only and not
served by the loader.

## Finding the remotes

Two tools live outside this repo — you paste them by hand when you want them, and nothing
fetches them, so they're deliberately not served:

- **`spy.lua`** — hooks `__namecall` and logs the game's own remote traffic. Play one loop
  of whatever you want to automate by hand and read F9; `[spy →]` gives you the exact
  remote path, method and arguments. Almost every script here started as a spy log.
- **`dump.lua`** / **`dump_v2.lua`** — one pass over the whole DataModel into
  `dump/<PlaceId>/`: the place file, every script, and a `manifest.txt` you can grep for
  `ProximityPrompt`, a zone name, an attribute, whatever — path and CFrame included,
  without ever opening Dex. `dump_v2` adds a focus pattern for when a full dump is
  minutes you don't want to spend.

## Notes

Executor only. The UI is [WindUI](https://github.com/Footagesus/WindUI), pulled in with
`HttpGet`, which Studio blocks — and a launch is four requests to
raw.githubusercontent (the library plus three icon packs), so a failure there is usually
a rate limit, not a broken script. `panel.lua` retries five times and says which of the
two failed, fetch or compile.

`raw.githubusercontent` caches for about five minutes. A pushed edit that "didn't take"
is that, not your script — flip `NOCACHE` in `loader.lua` while you're iterating.
