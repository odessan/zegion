---
name: zegion-dump-to-script
description: Use when the user hands over a Roblox game dump (dump_v2 output, next.txt, remotes.txt, calls.txt, events.txt, manifest.txt, attrs.txt, tags.txt, scripts/ folder, a spy log, or a PlaceId) or asks for a script for a new game in this repo.
---

# Zegion: dump in, script out

CLAUDE.md is the long reference (idioms, panel, pitfalls). This is the procedure for the moment a dump lands. Files next to this one:
`games.md` (game shape -> reference script), `digest.sh` (first-pass scan of a dump), `hunt.md` (shortcut checklist), `probe-kit.lua` (probe scaffold that prints the clipboard block).

The goal is not a script that works; it is the most efficient automation the game's own mechanics allow. The obvious loop is the fallback, not the plan.

## Rules that decide everything

- **Never write the farm before one item is proven.** No `PROBE` result / events pairing that shows *your* synthetic input doing it once = build a probe first and ask for its output. Don't guess around this.
- **Verify when it is cheap.** A 30-line probe beats an assumption. Skip it only when the dump is overwhelming (a shared module the server itself requires, or an events row showing the exact call and its effect) and say why in one line.
- **Hunt shortcuts before building.** Every remote, timer, client-side check and argument space gets a verdict (proven / probe / dead) per `hunt.md`. Instant open/collect/upgrade/kill, skipped cooldowns, a bigger quantity argument, the highest-value pick instead of the first: if the dump hints at it, investigate it.
- **Read in this order:** `next.txt` -> `classes/attrs/tags` -> `remotes.txt` (grep `listeners=[1-9]`) -> `calls.txt` -> `events.txt` -> `scripts/ReplicatedStorage/*` -> `manifest.txt` (`+late`). `digest.sh` does the mechanical part of this; the tracing is still yours: read the handler, don't infer behavior from a name.
- **Missing file = ask for it, don't infer.** Empty `events.txt` while the user played = no-remote mechanic (prompt/occupancy/native Tool), not a broken dump. No `send` rows = `WATCH_SEND` was off.
- **Dump taken as spectator/lobby is incomplete.** Check next.txt's banner (team, character, in round). Ask for a re-dump mid-round.

## Procedure

1. **Scan.** `bash .claude/skills/zegion-dump-to-script/digest.sh <dump-dir>`. Then read what it points at: the handlers behind each remote, the config modules, the client-side gates. Note anything unused, redundant or already handled by a game system you can reuse (a built-in auto/bulk remote, a shared module).
2. **Identify the shape** (games.md). Say it in one line: "this is B / carry-best-first, closest ref `jump_for_scp.lua`".
3. **Extract into a findings block** (show the user; ~12 lines):
   - PlaceId (from dump folder name) - confirm it, never guess.
   - Core loop: which remote(s)/prompt, args, server reply, confirm signal (attribute, Tool, folder change).
   - Gates: range check, speed check, cooldown, carry cap, paid/Robux route (say which remote you will NOT wire).
   - Value source: config module in ReplicatedStorage to `require` (prices, income, rarity order) - prefer over copying numbers.
   - Client-simulated enforcement (guards, fights, cutscenes) = mute/skip candidates (archetype D).
   - **Shortcut verdicts** from `hunt.md`: each candidate as proven / probe / dead, one line each with the reason.
   - Unknowns the dump can't answer -> exactly what each probe tests.
4. **Kit check** if not done: 30s search for the game name + "kit/source".
5. **Probe** every "probe" verdict that changes the design, batched: as few pastes as possible, each testing several things in order. Build it from `probe-kit.lua` pasted at the top, write it with the Write tool to the executor workspace (`<dump>/../probe_<PlaceId>_<n>.lua`), lint with `luau-analyze`, and hand over `loadstring(readfile("probe_<PlaceId>_<n>.lua"))()`. The probe must end with `P.finish()`, which prints, copies and saves this exact block:

   ```text
   ========== PROBE 1 ==========
   <name>
   <what was tested>

   <every argument sent, every value returned, every event received, in time order>

   ========== END PROBE 1 ==========
   ```

   Never summarise or truncate what the probe logs. Several probes in one file are `P.begin(...)` blocks numbered `PROBE 1`, `PROBE 2` ... and `P.finish()` copies them all in one go; ask for all of them pasted back. Say what each outcome would mean before the user runs it. A probe that spends currency or fires a remote at speed says so first.
6. **Analyze** the pasted result against the findings block; update the verdicts; if a shortcut worked, the design changes now, not later.
7. **Write `games/<name>.lua`**: copy the closest ref, keep the skeleton (config block, one `getgenv().<name>Stop`, world/farm/gui/close banners, WindUI via panel.lua, tabs, `stopAll` on both `OnDestroy` and getgenv). Follow CLAUDE.md idioms; don't restate them here. Use the top rung of the efficiency ladder in `hunt.md` for every feature; pick the highest-*value* outcome from the config, not the first.
8. **Register**: `GAMES["<PlaceId>"] = "<name>.lua"` in `loader.lua` + README table row. Only with a confirmed id.
9. **Verify what you can offline**: `luau-analyze` / `stylua --check` if installed, and re-read for globals not defined, `Set` re-entrancy, duplicate loops or connections, teardown restoring every muted/edited/server-side-toggled thing. You cannot run it; say so and list what to check in F9.
10. **Sweep again.** Re-run `digest.sh` and the `hunt.md` questions against what is still unwired; propose (or probe) the next automation the dump supports. Ask before adding anything the dump doesn't back.
11. **Commit** one-line subject, no body, no trailer (user memory). Only when asked.

## Defaults when the user doesn't say

- Toggle per feature, each independent; one `gen` counter per toggle.
- Waits in a config block; `pcall` every remote; `InvokeServer` on `callTimed`.
- Prefer protocol replay over walking whenever `calls.txt`/`remotes.txt` show the remote takes ids and no position.
- Filter by shape/attribute/tag, not path. Hardcode a path only with a comment saying why.
- ASCII-only string literals (Opiumware mangles UTF-8); non-ASCII as `\ddd`.
- Anything on by default must be armed by hand after build (`Value=true` does not fire Callback).

## Red flags - stop and reconsider

| Thought | Reality |
|---|---|
| "Remote looks obvious, I'll write the whole thing" | Wrong id/arg fails identically to a refusal. Probe once. |
| "events.txt is empty, dump failed" | May be the finding (no remote). Say which. |
| "I'll copy numbers from the decompile" | `require` the config module; balance patches then cost nothing. |
| "Fire the Collect All / auto remote with the extra `true`" | Check store config: trailing arg / gamepass gate can open a Robux prompt every pass. |
| "Add the PlaceId, probably right" | Wrong id runs another game's script. Confirm or leave out. |
| "Copy `flash`/`break_tape`/`my_seafood_stand` skeleton" | Older vintage (own key binds, pre-panel). Copy a WindUI one. |
| "The timer is server-side, so wait it out" | The client's `if timeLeft > 0 then Skip else Open` is a client check. Probe firing the completing remote early. |
| "The UI only sends 1 or 5, so that's the range" | The UI's choices are not the server's limits. Probe a larger count. |
| "That remote is deprecated / has no listeners, ignore it" | Often still live. `digest.sh` lists the unused ones; one probe settles it. |
| "The client fires it once a swing, so that's the rate" | An animation is not a rate limit. Burst N, count what the server acknowledged. |
| "Take the first / default outcome" | Rank the outcomes from the config module and take the best; assert the ranking. |
| "Summarise the probe for the user" | Print the full `PROBE n` blocks; they paste them back as the next step's input. |
| "Fire the paid remote once to see if it's enforced" | A monetised route is noted, not wired or tested, unless the user asks. |

End every reply with the single next thing the user must do (paste probe, re-dump with X, or run script and paste F9).
