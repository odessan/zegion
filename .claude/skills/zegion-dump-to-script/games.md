# Game shapes -> what to look for -> script to copy

Read from every header in `games/` (53 scripts). Pick the row the dump matches; open only that reference.

| Shape | Dump tell | Copy | Gotcha it already solved |
|---|---|---|---|
| **Carry best-first, tick rarities** (lucky blocks, brainrots, eggs, seeds) | folder of spawned models, `Rarity`/`Income` attrs, `StealPrompt`/`PickupPrompt`, config module with income/mutation | `jump_for_scp`, `pull_a_lucky_block` (range recheck + snap-back), `surf_for_brainrots` (rarity = zone), `wings_for_brainrots`, `tornado_for_brainrots` (config `require`), `fall_for_brainrots` (Income x mutation) | server re-checks range and reverts TP; confirm on Tool/attribute not folder |
| **Same, zones by number / camp** | `Zones.W5.Zone_47` nesting, streaming | `cut_grass_adventure`, `jetpack_for_brainrots`, `skate_for_brainrots`, `swing_obby_for_brainrots` | list zones by shape; rebuild dropdown on signature |
| **Same, steal from bases/NPCs** | Bases.BaseN.Slots, guards under `LocalNPCs`, `Carrier` attr | `steal_a_brainrot_base`, `steal_an_animal` (client-side guards), `dont_steal_a_bobo`, `fake_a_brainrot` | guard skip flag on client; bench targets you failed |
| **Same, bank by touch from afar** | `TheLine`/base `Touched`, no return trip | `steal_a_fish_egg`, `drill_block_for_dumpling_squishy` | `firetouchinterest` on the bank part |
| **Egg/nest** | `getNestContents`-style getter answering for every zone | `steal_a_chicken_egg`, `steal_a_mysterious_egg`, `ride_a_pet`, `dancing_animals` | score from the getter, not from streamed world |
| **Server position-free remotes (replay)** | remote takes an id, reply lists loot, no position arg | `chop_a_tree`, `loot_to_forge`, `strength_to_grow_arms`, `split_sea_for_animals` | ask -> pick best-priced -> bank from anywhere |
| **Dispatcher / ECS socket** | one RemoteEvent, command string | `build_an_ant_empire`, `chicken_farm` (ACTIONS table) | data-driven rows; build UI from a table |
| **Tycoon buy/upgrade/rebirth** | `Purchase` RF per button or Touched buttons | `sell_lemons`, `sell_lemons_w2` (order from `Balance`), `one_dropper_tycoon`, `break_tape_for_brainrots` (older) | blind sweep buys exactly the affordable set; don't spend the rebirth bank |
| **Roll / gacha / conveyor** | Roll remote + cooldown, inventory cap | `anime_dice`, `blue_lock_farm`, `build_an_ant_empire` | stop before cap; server-side auto-roll = teardown must fire `false` |
| **Fishing** | Start/Hooked/Click/Completed states, seeds, ThrowData | `deep_fishing`, `pull_a_lucky_fish`, `fish_for_anime_rng`, `roll_a_fisherman` | flight/timer is server-side floor; reroll to filter |
| **Cutscene game (mute controller)** | `OnClientEvent` listeners on reveal/flight remotes | `brainblast_for_brainrot`, `power_blast_lucky_block`, `flash_for_brainrots` (older), `become_a_brainrot` | mute BEFORE own handler; restore in `stopAll`; never mute mid-sequence |
| **Kick/throw with alpha** | Begin/SubmitAlpha/Claim/Return | `poop_for_brainrots` | claim distance-checked, base->zone leg speed-checked: walk it |
| **Mining / drilling** | client mine state, TNT/drill, crates | `plus_one_tnt_mining`, `drill_ores` | claim drops by id right after blast |
| **Drive / physics** | vehicle stepped off `Humanoid.MoveDirection` | `build_to_kill_zombie` | real input, server speed validator strikes |
| **Cook / stand loops** | `SlotState`, `CookProgress`, held Tool | `my_seafood_stand` (older) | equip before every remote |
| **PvP / ESP / aim** | Killer vs Survivors, tags, no anti-cheat hooks | `violence_district`, `sniper_arena` | `Highlight` budget ~31; tag-based lookup; skill-check band is past `Goal.Rotation` |
| **Crate hauler** | CarryingCrates state, two prompts | `drill_ores` | only crates this run picked up go to furnace |

## Recurring facts worth checking in any dump

- Config module under `ReplicatedStorage` (`Balance`, `BrainrotConfig`, `ItemConfigurations`, `*Data`) - `require` it.
- Paid shapes: trailing `true` arg, gamepass-gated remote, "Collect All" dev product. Note the unwired remote in a comment.
- Timer attrs (`TimeLeft`, `ExpTime`): absolute server time, never a confirm signal.
- `GameplayPaused` waits, `RequestStreamAroundAsync` only ahead of the hop, model streams as pivot-only.
- Round-based games (`steal_a_seed`): idle between rounds and say so.
