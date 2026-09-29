# Shortcut hunt: find the mechanic underneath before building the obvious loop

Run `bash digest.sh <dump-dir>` first; it lists the candidates below. Every candidate gets one of three
verdicts, written down in the findings block: **proven** (dump evidence, say why), **probe** (unknown, cheap to test),
**dead** (server-checked, paid, or already covered). A candidate with no verdict has not been investigated.

## The questions, per remote / mechanic

| Ask | Where it shows in the dump | Verdict route |
|---|---|---|
| Is there an instant or skip version? (open, hatch, craft, forge, train, finish, complete) | remote names with `Skip`/`Finish`/`Complete`/`Instant`/`Fast`; a timer attr (`PlacedAt`, `TimerDuration`, `ReadyAt`) | **probe**: fire the *completing* remote (`OpenCrate`) before the timer. The client's `if timeLeft > 0 then Skip else Open` is a client check; the server may not repeat it |
| Does the client test something before firing? | digest "CLIENT-SIDE GATES": `os.time()`, distance, cooldown, `Enabled` | **probe** the fire without the test. Prompt gates (`MaxActivationDistance`, line of sight) are always client-side |
| What is the argument space? | `calls.txt` shows the args the UI sends; the UI usually sends a few fixed values (`1` or `5`, `1|2|3`, an id) | **probe** other values: a bigger count, another id, another tier. Server cost still applies; that is fine, it is the point |
| Does the server pick the outcome, or does an argument? | remote takes `(id, rarity, index, slot)`; reply lists loot | read the reply shape; if the client chooses which reply row to take (`RandomizerPickup(slot)`), choose by value, not first |
| Is there a direct route past the normal step? | an old/"deprecated" handler still calling a remote (`PurchaseTurret`, `PurchaseBlockItem`); `Force*`, `Toggle*Request` with `listeners=0` and no caller | **probe** once. Unused-looking remotes are often still live on the server |
| Does the server hand out ids to collect? | inbound event with `Id` then a `*Collect(id)` remote (`StarShardCollect`, `TokenRushCollect`) | replay: collect on the event, no walking, no touch |
| Does the client mirror a number the server owns? | attribute written on your Player/plot | client writes stay local; the server only replicates a *change*. Read it, don't fight it |
| Is a big multiplier or rate a paid flag? | `Owns*`, `Has*`, `IsVIP`, `ProductID`, `PromptProductPurchase` | **dead by default**: note the remote in a comment, don't wire it. Probe only if the user asks |
| Is the server-side cadence faster than the client's? | `SetAutoX`, `AutoWave`, `AutoRoll` remotes | flip the game's own auto instead of looping; teardown must send `false` |
| Is a rate limit real or only the client's animation? | client fires on a swing / cutscene timer | **probe** the rate: fire N in a burst, count what the server acknowledged (`turret_defense.lua`: sword took 11/s, the swing animation does 1.4/s) |

## Calibration: what the server rechecked (turret_defense, round 2)
Expect most shortcuts to be dead, and value the probe for the *exact* facts it leaves you with:
- `OpenCrate` before the timer: refused ("Crate is not ready yet!"). The timer is the server's; the client check was just UI.
- `UpgradeTurret(model, 25|100)`: silently ignored. Only the UI's own 1 and 5 work. A refusal can be silent, so confirm on the attribute (`Level`), not on a toast.
- A deprecated shop remote (`PurchaseTurret`) and its stock read (`GetTurretShopStocks`) got no answer: dead handlers.
- Daily / offline / tutorial claims: deduped ("Already claimed today") or paid nothing on the repeat.
- What paid off: the client formula was exact (a 5-level upgrade cost 2014 as computed), so gates can be exact and no refusal has to be discovered; the Index turned out to pay permanent boosts, which reorders what is worth buying.
So a "probe" verdict costs one paste and ends as *dead*, *exact*, or *new lever*. Write the outcome into the script header under "Probed and dead" so nobody re-probes it.

## Highest value means highest value
When the game shows several outcomes (roll slots, crate contents, shop rows, quest rewards): rank them from the
config module, not the first row. Compute value with the game's own formula (`Damage / FireRate`, `Income x mutation`,
`Price x SellRatio`), keep the score function in one place, and assert its order on two known items right below it.
Modifiers and levels change value; say in a `ponytail:` comment when the ranking ignores them.

## Sweep after the requested feature ships
Re-run `digest.sh` and the questions above against what is still unwired. Candidates worth a verdict:
auto collect / claim (daily, offline, index, quests, codes), auto sell (filtered, never what is placed or equipped),
auto equip best, auto upgrade in cost order, auto rebirth (reserve its price), auto place, auto teleport to the best
zone, server-side auto-X toggles. Add only what the dump supports or a probe confirmed.

## Efficiency ladder (take the first rung that holds)
1. A direct server call that does the whole thing (one remote, no position).
2. The game's own auto / bulk remote.
3. A remote loop paced by the server's own answer (`callTimed`, adaptive gap).
4. Event-driven (`OnClientEvent`) over polling; a local mirror seeded once.
5. Client automation (walking, prompts, clicks) only when nothing above exists.
Never: a loop that re-fires an unchanged remote, a poll where an event exists, a wait where the confirm can be observed.
