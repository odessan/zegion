# Fall For Brainrots — rewrite design

Place `86368783421928`. Rewrites `games/fall_for_brainrots.lua` in full.
Source of facts: the dump at `/Users/xedw/Opiumware/workspace/dump/86368783421928`
(2026-09-04), plus the current script.

## Why

Four things are wrong or missing today:

1. The script is one of four left on the hand-rolled GUI kit. The other 26 use
   `panel.lua` + WindUI. ~350 lines of widget code exist only because they predate it.
2. The farm picks the *first* item matching a ticked rarity. Item value is computable
   client-side — `ItemConfigurations.Items[OriginalName].Income` times
   `MutationMultipliers.Get(name, Mutation)` — and mutations run 1x to 11x, with `67`
   overridden up to 112x. So the farm currently walks past a Rainbow Cosmic to grab a
   plain Eternal, and treats a Golden and a Normal of the same item as identical.
3. "Full" is discovered by eating a refused grab, when
   `HumanoidRootPart.CarryGUI.CarryLimit.Text` is `"N/M"` and free to read. Deposit is a
   flat 1.5s wait when `Player:GetAttribute("IsInCollectionZone")` says when you arrived.
4. Both hardcoded ladders are stale: `RarityConfigurations` has `Supreme`,
   `ZoneConfigurations` has `SUPREME`, and neither list has it. A SUPREME zone does not
   appear in the dropdown at all, and `DropperParts.Guards` in the dump has a live
   `SUPREME-GUARD`.

   (`attrs.txt` also samples `Rarity = "OG"`, but that traces to a lone `StringValue` in
   the manifest, not to a spawned item — no item in `ItemConfigurations` carries it. So
   it's covered by a runtime warning rather than by putting a guess in the ladder.)

## Scope

In: value-scored best-first farming, mutation filter, carry-aware banking, guard bail on
the server's own signal, the WindUI port, auto collect (port of what exists), auto
max-upgrade slots, auto +1 carry, and the stale-ladder fixes.

Out, deliberately: claims (daily / group / index), codes, wheel spins, lucky blocks, ESP,
a minimum-value threshold input. Each is a live remote in the dump and each can be added
later as one row; none of them feed the farm.

## File shape

Full rewrite, following the `tornado_for_brainrots.lua` skeleton:

```
header docstring   what each toggle does, in the words of someone using it
config             every tunable a named local with why-you'd-change-it
world              zone scan, remote resolution, streaming helpers
value              the module requires and value()
farm               grab / deposit / runCycle
collect            plot pads + slot upgrades
gui                panel.lua -> Window -> three tabs
close              stopAll, OnDestroy, getgenv().ffbStop
```

The ~350-line widget kit goes; the value scoring, carry reading, notification channel,
guard handling, plot upgrades and three tabs come in. Net, expect the file to stay around
the size it is — this is not a shrink, it's a swap of GUI code for behaviour.

## Value scoring

```lua
local ITEMS = require(...Modules.ItemConfigurations)   -- .Items[name].Income
local MULT  = require(...Modules.MutationMultipliers)  -- .Get(name, mutation)

local function value(model)
	local n = model:GetAttribute("OriginalName")
	local cfg = n and ITEMS.Items[n]
	return (cfg and cfg.Income or 0) * MULT.Get(n, model:GetAttribute("Mutation") or "Normal")
end
```

Both requires go in one `pcall` at load. If either module moves, `value` degrades to
rarity ladder rank, and the script warns once in the console rather than dying — the farm
still works, it just stops ordering by money.

A sweep scores every eligible item in the zone and takes the highest.

**Consequence that cannot be skipped.** Today a refused grab is un-blacklisted
immediately. Under best-first ordering that is a deadlock: the same unreachable
top-value item is re-picked forever. So `tried` changes from `model -> true` to
`model -> retry-after clock`, still with weak keys so despawned models drop out on their
own. A refusal parks that model for `RETRY_AFTER` seconds; a success is permanent
(the model is destroyed anyway).

## Filters

Rarity and Mutation dropdown values are built as **ladder ∪ module keys**: the hardcoded
ladder supplies the order (the modules are dictionaries and `require` cannot recover it),
and any key the module has that the ladder does not is appended at the end rather than
being invisible. That covers `Supreme` without guessing where it ranks, and covers the
next update for free. `RarityConfigurations` and the set of `Rarity` values present in
`ItemConfigurations.Items` are both unioned in, since either one can carry a tier the
other doesn't. An item wearing a rarity neither list has warns once in the console —
that's the one case the union can't fix, because a rarity that exists only on an instance
has no rank to give it.

The zone ladder gets the same union, for a different reason: zone dropdown values are
Workspace model names, but `zoneTier(name)` recognises a zone by finding a ladder entry as
a substring. `SUPREME` missing from the ladder is why `SUPREME-GUARD` — which the dump
shows live in `DropperParts.Guards` — is filtered out of the list entirely. The ladder is
still walked top down so the higher tier wins (`COMMON` is a substring of `UNCOMMON`).

Mutation values order by their `MutationMultipliers.Default` value, ascending.

Rarity and Mutation AND together to decide eligibility. `value()` orders within that.
Zones stay as they are: ticked zones cycled highest tier first.

Selection sets stay keyed by **name**, never by Instance — zones repopulate mid-round.

Multi-dropdown callbacks are normalised through one `ticked()` helper: WindUI hands back
a list, a map, or the row tables depending on the build `panel.lua` fetched, and reading
a map as a list yields an empty set, which filters everything out.

## Carry and banking

```lua
-- HumanoidRootPart.CarryGUI.CarryLimit.Text is "N/M".
-- Reports whether it could read, not just the number: failing open to 0 reads as
-- "empty" and silently inverts every gate built on it.
local function carry() -- -> held, cap   (nil when unreadable)
```

The farm banks when `held >= cap`. The refusal path stays as the fallback for when
`carry()` returns nil (no character, GUI not built yet).

Deposit confirms rather than waiting a flat interval: `goTo(BASE)`, then poll until
`Player:GetAttribute("IsInCollectionZone")` is true and `carry()` reads 0, capped at
`DEPOSIT_TIMEOUT`. If either signal is unreadable, fall back to the existing fixed
`AT_BASE` wait.

`ponytail:` `RequestDropItem` is deliberately not wired. The HUD binds it to a "Drop"
button visible only in the collection zone with a carry, which is most likely deposit —
but "drop" could equally mean dropping items on the floor, and finding out costs a real
carry. Confirm-only until someone probes it in game.

## Guards

`LocalPlayer:GetAttribute("IsGuardTargetting")` is the primary bail signal — the server
sets it when a guard locks on, and `RunAlert.lua` is the game's own client reading exactly
that. Death drops the carry and offers a paid teleport-back, so this is the one thing
worth being twitchy about.

The existing 30-stud distance check stays as insurance for guards that have not targeted
yet. Bail behaviour is unchanged: run to BASE, count a strike against the zone so a guard
parked on a spawner cannot loop the farm forever.

## Plot tab

**Auto collect cash** — the existing `firetouchinterest` batch sweep, unchanged, moved
into a WindUI toggle. Pads are found by name (`CollectTouch`) under `Plot_<you>`, cached,
and the cache is dropped on plot descendant churn so buying a floor picks up its pads.

**Auto max-upgrade slots** — same plot walk, fires
`RequestSlotMaxUpgrade:FireServer(FloorName, SlotName)` with the names derived from
ancestry. Only for slots whose `UpgradePart.UpgradeGUI.UpgradeButtonMax` is `Visible`:
the game's own client maintains that flag, so gating on it skips the calls the server
would refuse, instead of stacking "not enough money" banners. Calls spaced within a
sweep, sweeps on `UPGRADE_EVERY`.

## Boosts tab

- Auto buy speed — `PurchaseSpeed:FireServer(n)` on `BUY_EVERY`, with the x1/x5/x10 step
  as a dropdown rather than a cycling chip.
- Auto +1 carry — `PurchaseCarry:FireServer()` on `CARRY_EVERY`.
- Auto rebirth — `RequestRebirth:FireServer()` on `REBIRTH_EVERY`.

Both purchase remotes fire the **cash** path: the Robux route in the game's own
controllers is a separate `MarketplaceService:PromptProductPurchase`. But the server can
push `PromptSpeedProduct` / `PromptCarryProduct` at you, and the game's controller opens
a Robux dialog when one lands. So each loop carries a kill switch: that event firing
while the loop is on switches the toggle off and says why, rather than stacking purchase
popups once you run out of money.

## Diagnostics

`ShowNotification` gets a listener keeping the last message and its arrival clock. A
refusal inside the grab window puts the server's own wording into the status line instead
of "refused at 3" — and it is proof the press reached the server at all, which rules out
a whole class of bug in one line. Only a message that arrived inside the window is
trusted.

Status writes drain through a `RunService.Heartbeat` connection: a farm thread loses
capability to touch the panel after its first `task.wait`, and uncaught that kills the
farm on its second lap with the toggle stuck on. Any `Toggle:Set` a loop thread makes on
its way out is `pcall`'d.

Counters kept and shown: items grabbed, total value banked, collect sweeps.

## UI

`panel.lua` at the usual raw URL; `if not Window then return end`.
`{ game = "Fall For Brainrots", folder = "FallForBrainrots", size = UDim2.fromOffset(520, 400) }`.
The folder name is fixed for the life of the script — renaming it orphans saved configs.

- **Farm** tab — Section "Target": Zones (multi), Rarity (multi), Mutation (multi).
  Section "Run": Teleport button, Farm toggle, status paragraph.
- **Plot** tab — Auto collect cash, Auto max-upgrade slots.
- **Boosts** tab — Auto buy speed + step dropdown, Auto +1 carry, Auto rebirth.

The zone dropdown refreshes on `zoneRoot` child churn, gated on a signature of the zone
names and throttled: `Dropdown:Refresh` registers connections WindUI only clears on
`Destroy`, so an ungated rebuild on streaming churn grows for the length of the run, and a
dropdown rebuilding under the cursor is unusable. `Refresh` also drops the selection and
re-fires the callback with whatever `Value` the dropdown still holds, so the callback
ignores unknown values rather than assigning them.

Toggles starting at `Value = true` do not fire their callback; anything on by default is
armed by hand after the row is built. Both branches of every callback are re-entrant,
because `Toggle:Set(v)` re-enters.

## Teardown

One `stopAll()` flipping every loop flag off, hung off **both** `Window:OnDestroy` and
`getgenv().ffbStop`, each clearing the getgenv slot. `ffbStop` additionally `pcall`s
`Window:Destroy()`. Every connection made outside a toggle — the `ShowNotification`
listener, the two purchase kill-switch listeners, the zone churn watchers, the plot
descendant watchers, the Heartbeat status drain — is tracked and disconnected on real
teardown, or a re-paste stacks a second set.

## Registration

Already registered: `loader.lua` line 42 and the README row. Neither changes.

## Verification

No test framework here. The check is in game, in this order — each one fails visibly if
the step above it is broken:

1. Console prints the resolved rarity and mutation ladders at load, including `Supreme`
   and `OG`. Wrong ladder means the module requires failed.
2. With one zone and one rarity ticked, the status line names the item it is going for
   with its rarity, mutation and computed value. A value of 0 on everything means
   `ItemConfigurations` did not resolve.
3. Two eligible items in a zone, one mutated: the mutated one is taken first.
4. The status line shows `held/cap` from `CarryGUI` and the run banks on reaching cap,
   not on a refusal.
5. Standing in a zone until a guard locks on: the run bails within a beat of
   `IsGuardTargetting` going true, and does not die.
6. Auto +1 carry with no money: the toggle switches itself off naming the Robux prompt,
   and no purchase dialog is left open.
