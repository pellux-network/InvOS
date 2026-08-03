# Inventory-Authoritative Reconciliation Design

## Problem

The current transfer journal treats individual inventory slots as durable truth. That assumption is false for Colossal Chests: removing an item can compact or reorder the inventory.

The live failure demonstrates the issue. A request for two Echo Gems recorded source slot 7 with three Echo Gems before the call. The player received all three gems, `pushItems` recorded one moved item, and the post-transfer scan found 29 Wutodie Gems in slot 7. Slot-based verification then marked the operation failed and blocked startup recovery even though the inventories still contained all relevant truth.

## Principle

Live container contents are authoritative. The inventory index and journal are derived coordination state. A journal may tell the controller what comparison to perform after interruption, but it must never contradict or outrank a complete inventory scan.

## Normal transfer flow

Every inventory mutation follows one small state machine:

1. Scan the storage pool and record the exact identity's aggregate quantity.
2. Select a current source and destination from that scan.
3. Persist a transfer intent containing the operation ID, direction, exact identity, desired quantity, and aggregate storage baseline.
4. Invoke `pushItems` exactly once.
5. Persist that the call returned, including its reported moved count for diagnostics.
6. Rescan the storage pool.
7. Reconcile the operation from the aggregate storage delta.
8. Record the result, update request/import progress, and retire the journal.

The second scan is a normal short-lived phase, not an exceptional unresolved state. No second transfer call for that operation is permitted before reconciliation finishes.

The controller remains cooperative while scanning: terminal input, monitor rendering, search, and status updates continue between bounded scan steps.

## Aggregate reconciliation

Reconciliation uses an exact name-and-NBT identity across the storage-node scope recorded with the baseline. Every node in that scope must have a complete healthy post-transfer scan before a delta is accepted. A missing node cannot be mistaken for removed items, and a newly configured node cannot distort an in-flight comparison.

For retrieval:

```text
actual moved = storage total before - storage total after
```

For import:

```text
actual moved = storage total after - storage total before
```

Slot numbers, slot contents after the call, Pickup contents, and Drop-off contents are not evidence of the result. The value returned by `pushItems` is retained for diagnostics but does not override the aggregate delta.

Results are handled directly:

- Exact movement completes the requested step.
- Partial movement credits only the measured delta and replans the remainder from a fresh index.
- Zero movement produces the appropriate capacity or availability state without retrying blindly.
- Movement greater than requested completes without another call, credits the measured amount, and raises a critical over-delivery alert containing requested, measured, and reported quantities.
- A negative or directionally impossible delta raises a reconciliation alert and waits for a complete healthy storage scan; it never repeats the transfer automatically.

## Scheduling and future work

V1 performs inventory mutation calls sequentially through its cooperative event loop. This reflects how ComputerCraft executes peripheral calls and keeps aggregate comparisons unambiguous. It is not a permanent global-lock API or a restriction on future crafting.

Requests may still be entered and queued while another operation is scanning or reconciling. Future crafting can extend the scheduler and reconciliation records without replacing the inventory-authoritative model.

## Restart and infrastructure failure

An unfinished intent never causes the transfer call to be replayed.

- Intent saved, call not started: the operation is safe to discard or replan because no call crossed the boundary.
- Call started or returned, reconciliation unfinished: rescan the storage pool and compare it with the saved aggregate baseline.
- Storage temporarily unavailable: keep only that operation pending, show the infrastructure problem, and retry the scan when storage returns. Do not freeze search, setup, status, or unrelated UI.
- Fully reconciled terminal journal: retire it so it cannot affect later boots.

Existing legacy journals do not contain an aggregate baseline and cannot be reconstructed reliably. They are retired without replaying a transfer, and a visible warning explains that the previous result must be reviewed. They do not leave the controller in global `RECOVERING` state.

## Durable data

The journal contains only the minimum recovery facts:

- schema version
- operation and transfer IDs
- operation kind/direction
- exact identity key
- desired quantity
- aggregate storage baseline
- the storage node IDs included in that baseline
- phase (`INTENT`, `CALLING`, `CALLED`, `RECONCILED`)
- diagnostic `pushItems` return count when available
- measured aggregate delta after reconciliation

The inventory index is never persisted as stock truth. Completed journals are removed along with their previous/staged copies after their result has been applied.

## User-visible behavior

Normal requests show moving and brief reconciling progress, then complete. Slot compaction is invisible to the user. Pickup interaction cannot create a false failure.

Alerts are reserved for actionable conditions: unavailable storage, no capacity, over-delivery, impossible aggregate direction, or a retired legacy/ambiguous operation. A recovery warning does not disable the entire controller.

## Tests

The regression suite must cover:

- The observed failure: three Echo Gems in source slot 7, request two, the transfer reports one but removes all three, and compaction replaces slot 7 with Wutodie Gems. Exactly one call occurs; the measured delivery is three; an over-delivery alert is raised; no retry occurs.
- Exact, partial, and zero retrieval deltas.
- Exact and partial imports using aggregate storage increases.
- Multiple storage nodes contributing to one exact-identity total.
- A missing baseline node postpones reconciliation instead of appearing as removed stock.
- NBT variants remaining independent.
- Reboot after `CALLING` and `CALLED` reconciles from the saved baseline without replay.
- Temporary storage detachment delays reconciliation without freezing the UI.
- Completed journals are retired.
- Legacy slot-based journals produce a warning and do not block startup.
- Existing search, monitor, setup, backup, responsiveness, and deployment tests remain green.

## Live deployment safety

Implementation and tests occur only in the isolated repository worktree. Before deployment, computer #4 must again be confirmed shut down and labeled `StorageController`. Only allow-listed runtime Lua files may be copied, every runtime hash must be verified, and all files under `colossal/data` must be preserved unless a deliberate migration is part of the verified implementation.