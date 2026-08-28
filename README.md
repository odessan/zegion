# Chicken Farm GUI

Single-file Roblox script: `buy_chickens.lua`. Paste into an executor, or drop it in
`StarterPlayer > StarterPlayerScripts` as a LocalScript.

One file on purpose — an executor pastes one file, so splitting into modules would
need a bundle step or a `loadstring(game:HttpGet(...))` per module. Split when it
passes ~500 lines, not before.

## Layout

| Section in the file | What lives there |
|---|---|
| `anti-afk` | 60s nudge + `Idled` → VirtualUser right-click, always on |
| `fire` | `send()` — the one place a remote is called |
| `ACTIONS` | one table entry per feature. **Edit this to add things.** |
| `spy` | `__namecall` hook that logs the game's own remote calls |
| `widgets` | colors + `rowFrame` / `rowLabel` / `switch` helpers |
| `shell` | panel, title bar, close button |
| `build` | loops ACTIONS, makes one row per action |
| `close` | ✕ — stops loops, silences spy, destroys the GUI |

## Adding a feature

One entry in `ACTIONS`. The button, textbox, and Auto toggle appear on their own.

```lua
{ label = "Sell Eggs", remote = rf, method = "InvokeServer", cmd = "Sell Eggs" }
```

For an inline control add `input = { cycle = {1, 5, 25, 100}, default = 25 }` (tap to
cycle) or `input = { text = "1.4" }` (typed). Its current value is passed to `run`.

Fields: `label`, `remote` (`rf` = RemoteFunction, `re` = RemoteEvent), `method`,
`cmd`, optional `input = {default, placeholder}` for an inline box, optional
`run(self, text)` when the default no-arg call isn't enough.

Each row is one line: label, optional small input, ON/OFF switch. ON runs the action
every `INTERVAL` seconds until switched off. An action with `once = true` gets an
arm-then-fire button instead — for anything destructive that must never loop. There is no status line — errors go to
the console (F9) via `warn`.

## Current actions

- **Buy + Merge** — `rf:InvokeServer("Buy Chickens", n)` with n from the cycle button
  (1 / 5 / 25 / 100 — the bundles the shop sells), then `rf:InvokeServer("Merge Chickens")`.
  The merge call is harmless when the 100 bundle already auto-merged: the server has
  nothing left to merge.
- **Collect Eggs** — scans `workspace` for UUID-shaped names/attributes (see below) and fires
  `re:FireServer("Collect Egg", id)` for each, then destroys the model locally (the
  game's LocalScript would normally do that; firing the remote directly skips it).
  That destroy is cosmetic — the server already granted the egg — but it also stops
  the scan re-firing the same id every tick. If the scan finds nothing, use Spy.
- **Collect Cash** — `rf:InvokeServer("Collect Cash")`. No args.
- **Lucky Blocks** — the game's own three-step flow per tick:
  `rf:InvokeServer("Collect Lucky Block", uuid)` for each block found, then
  `rf:InvokeServer("Open Lucky Block")`, then `re:FireServer("Claim Opened Chicken")`
  after a 0.3s pause so the open resolves first. Open and Claim are no-ops when there's
  nothing to open, so the chain runs unconditionally.
- **Upgrade Process** — `rf:InvokeServer("Upgrade Process Level")`. No args. Runs on its
  own 5s interval (`interval = 5` on the action) instead of the 0.2s default, since every
  hit spends cash. Change that number to retune it.
- **Upgrade Buy Tier** — `rf:InvokeServer("Upgrade Buy Tier Level")`. No args, 5s
  interval, same cash-spending reasoning as Upgrade Process.
- **Rebirth** — `rf:InvokeServer("Rebirth")`. Not a switch: it wipes progress, so it
  gets a press-to-fire button. First click arms it (`SURE?`, red), second click within
  3 seconds fires. It disarms itself if you walk away.
- **Deposit @** — `rf:InvokeServer("Deposit Eggs")`, gated on the egg multiplier.
  Only fires when the multiplier is at or above the number in the box (default 1.4).

## UUID scanning

Eggs and lucky blocks are both addressed by a uuid the client already knows. `uuids(keyword)`
walks `workspace` and treats an instance as a candidate when its **name** or any of its
**attributes** is uuid-shaped.

The keyword ("egg", "luck") is meant to stop egg ids being fired at the lucky-block remote
and vice versa: an id matches when that word appears in its own name or in an ancestor's,
up to 4 levels.

In practice nothing in this place carries those words, so what matters is the fallback:

- `uuids("egg")` — falls back to **every** uuid found. Collect Eggs is the catch-all
  collector, and that fallback is the only reason it collects anything at all.
- `uuids("luck", true)` — **strict**: collects nothing rather than firing egg ids at the
  lucky-block remote. Without this, switching Lucky Blocks ON also claimed every egg.

If the game ever names its blocks so "luck" matches, the strict scan starts working with
no code change. Use Spy to check what's actually going out.

## The multiplier gate

The in-game HUD shows `Egg Multiplier: 1.04x` and rerolls every ~30s. The script finds
that label by **searching for text containing "Multiplier"**, not by a hardcoded path,
so the game reshuffling its UI doesn't break it. It checks the known path first —
`Workspace.Map.EggMultiplierPart.UI.Multi`, a label on a part out in the world — then
falls back to scanning `PlayerGui`, `workspace`, and the executor's hidden gui container. On a hit it prints the full path once — check that it found the label you
meant and not some other "Multiplier". Re-scans at most every 2s if the label vanishes.

Deposit fires **once per multiplier window**, not once per tick: it only acts when the
parsed value differs from the last one it saw (or 28s have passed, covering a window
that rolls the same number twice). At 0.2s ticks that's 1 call per window instead
of ~150.

If the console says `no 'Multiplier' text found`, the label is somewhere none of those
three roots reach, or it isn't a `TextLabel` (a `TextButton` or a 3D `TextLabel` under a
model that's streamed out). That warning is throttled to once per 5s.

## Anti-AFK

Always on, no switch. Three layers, because a client that ignores one may honor another:

1. **Every 60s**, so the idle timer never gets near the ~20 min kick.
2. **On `Idled`**, the last warning before the kick.
3. **Rejoin on disconnect** — whatever the cause, the error prompt appears in
   `CoreGui.RobloxPromptGui.promptOverlay`; a `ChildAdded` watcher sees an `ErrorPrompt`
   and calls `TeleportService:Teleport(game.PlaceId, player)`.

A nudge is a right-click sent two ways: `VirtualUser` `Button2Down`/`Button2Up` at the
camera CFrame, and `VirtualInputManager:SendMouseButtonEvent`. Neither does anything
in-game. Startup prints which services are available.

The console (F9) is the diagnostic. Startup says whether each service exists and whether
the rejoin watcher armed; every nudge prints `nudge #N (timer|Idled)`. Read it after a kick:

* **No `nudge` lines at all** — the script died before the loop, or the executor blocks `print`.
* **Only `(timer)` lines, then kicked** — synthetic input isn't resetting the timer. `Idled`
  never fired, so this wasn't Roblox's idle kick; it's the game's own AFK check.
* **A `(Idled)` line ~20 min in, then kicked anyway** — it is the idle kick, and the nudge
  isn't counting as input.
* **`rejoin-on-disconnect NOT armed`** — layer 3 is off, which is why the session ends
  instead of coming back.

If `VirtualUser` says ok and you still get kicked, synthetic input isn't resetting your
client's idle timer — or it's not the idle kick at all, but the game's own AFK check.
Layer 3 is what saves the session either way. Read the disconnect message before it
rejoins: the wording says which one it was.

## Closing it

The ✕ in the title bar unloads the script: every auto loop stops (they all watch
`running`), the spy goes quiet, the anti-AFK handler disconnects, the GUI is destroyed. No rejoin needed — rerun the
script to bring it back.

The `__namecall` hook stays installed after close, since executors give you no way to
unhook. It's a plain passthrough once `spy` is false.

## spy.lua

Standalone. Paste and run on its own — nothing to do with the farm GUI, it just watches
traffic. `[spy →]` is client-to-server (`FireServer` / `InvokeServer`, with the value an
`InvokeServer` got back), `[spy ←]` is server-to-client (`OnClientEvent`). Every remote in
the game, plus any created later.

Stop it with `getgenv().spyStop()`. Re-running the file stops the previous spy first.

Busy games fire remotes constantly — put the noisy names in the `IGNORE` list at the top.
RemoteFunctions in the server-to-client direction aren't covered; `OnClientInvoke` holds
one callback and taking it breaks the game.
