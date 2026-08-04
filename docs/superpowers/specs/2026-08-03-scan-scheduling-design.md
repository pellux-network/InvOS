# On-demand scan scheduling

Status: implemented 2026-08-04, default lowered to 2s the same day. `Coordinator:_scanStep`
now selects the requested node, else the stalest node past `scanRefreshInterval`
(never-scanned nodes count as infinitely stale), else does nothing. `scanCompletedAt` tracks
completions; `scan_refresh_interval` is injectable via `main.lua`.

The initial 30s default made Drop-off discovery, not the verification-gate scan itself, the
dominant delay: nothing tells the coordinator when an item physically lands in Drop-off, so
an idle controller only learns about it on the next staleness rescan. 30s read as "the whole
system got slow" even though the storage scan itself was unaffected. 2s keeps Drop-off
responsive without reverting to unconditional continuous rescanning.

## Problem

`Coordinator:_scanStep` refills the scan queue as soon as it empties:

```lua
local id = table.remove(self.scanQueue, 1)
if not id then
    for _, node in ipairs(self.nodes) do
        if node.state ~= "DISABLED" then self.scanQueue[#self.scanQueue + 1] = node.id end
    end
    id = table.remove(self.scanQueue, 1)
end
```

So every node is rescanned forever, whether or not anything changed. Each completed scan
also calls `_rebuildIndex`, which runs `Index.build` over every snapshot and then re-runs
`Search.query` over every item type. On the live controller that is ~440 occupied slots and
200+ item types, continuously, while the system sits idle.

This is also why the controller still repaints steadily after the dirty-flag work in
`e258527`: a scan genuinely completes most ticks, so the index genuinely changes, so marking
dirty is correct. Precise redraws cannot help until the scanning itself stops churning.

Two peripheral calls per scan (`size`, `list`) are also paid per node per cycle, and each
yields for about a server tick.

## Goal

Scan when there is reason to, not continuously. Idle CPU and idle peripheral traffic should
fall to near zero while leaving every correctness guarantee intact.

## What must not change

Reconciliation depends on scan freshness in two specific places, and both must keep working:

1. **The planning gate.** `Coordinator:_automationStep` sets a gate before planning and waits
   for a fresh scan of storage and the relevant I/O node. `Transfer:executeMultiBatch`
   captures its reconciliation baseline from those snapshots. A stale baseline silently
   corrupts every measurement, so this gate must still force a real rescan.
2. **The verification gate.** Set from `result.rescan` after a transfer. Same requirement.

Both work through `requestRescan`, which promotes nodes to the front of the queue and
discards an in-progress scan of a wanted node. That mechanism stays; only the *idle* refill
behaviour changes.

Also unchanged: `peripheral` / `peripheral_detach` events must still trigger a targeted
rescan, and the initial index must still complete on boot.

## Design

Replace the unconditional refill with three triggers:

- **Requested** — `requestRescan`, from gates and peripheral events. Highest priority,
  behaviour identical to today.
- **Stale** — a node whose last completed scan is older than `scan_refresh_interval`
  (suggested default 30 s, injectable). Catches manual chest edits by players, which the
  system otherwise learns about only via reconciliation surprises.
- **Never scanned** — no snapshot yet, so the initial index still completes promptly.

Track `self.scanCompletedAt[nodeId]` on scan completion and select the stalest eligible node.
When nothing qualifies, `_scanStep` returns without work, which lets the work loop go quiet.

`Lifecycle` already defines a `STALE` storage state that is never used. Consider surfacing a
node whose refresh is overdue, but only if it does not make `DEGRADED` flap.

## Files

| File | Change |
|---|---|
| `app/coordinator.lua` | scan selection, `scanCompletedAt`, refresh interval dep |
| `main.lua` | pass `scan_refresh_interval` |
| `docs/operations.md` | describe when scans happen and how stale data can be |

## Tests

- An idle coordinator with fresh snapshots performs no scan for the whole interval, then
  scans once when it lapses.
- `requestRescan` still forces an immediate scan regardless of freshness.
- A planning or verification gate still opens, i.e. `scanRevision` still advances. The
  existing `test_coordinator_epoch_gate.lua` and `test_transfer_rescan_race.lua` cover the
  hazard and must stay green.
- A never-scanned node is scanned promptly so the initial index completes.
- A `peripheral` attach event still triggers a targeted scan.
- Redraw count over an idle window falls, which is the assertion
  `tests/test_hot_paths.lua` could not make while scanning churned.

## Risk

Medium. The failure mode is planning from stale storage, which corrupts a reconciliation
baseline rather than producing a visible error. Mitigate by leaving the gate path completely
untouched and changing only idle refill, and by verifying live that a transfer still forces
its rescans: watch `colossal/data/journal.lua` phases with `scratchpad/probe.sh` and confirm
cycles still show the two gate pauses.

Measure before and after with `scratchpad/bench.lua`, which reports steady work-loop cost per
tick; that benchmark could not show the redraw work because it models neither a monitor
peripheral nor a realistic item-type count, but it does model index rebuilding, which is the
dominant cost here.
