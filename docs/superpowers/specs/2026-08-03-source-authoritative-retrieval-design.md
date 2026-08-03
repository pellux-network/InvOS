# Source-Authoritative Retrieval Design

## Goal

Make item retrieval reliable while players freely add, remove, or rearrange items in the Pickup chest. A successful retrieval is proven by what left controlled storage, not by a snapshot of the player-facing output chest.

## Selected approach

Retrieval uses an unslotted wired-inventory transfer:

1. Plan the requested quantity from one or more storage source slots.
2. Immediately before each transfer, validate only the selected source slot's item identity and count.
3. Call `pushItems(pickupName, sourceSlot, limit)` without a destination slot. Minecraft chooses a compatible Pickup slot.
4. Persist the returned moved count before continuing.
5. Rescan and verify only the storage source. The expected source decrease proves the result.

This replaces Pickup snapshot validation and Pickup-slot reservations. Background Pickup scans may remain for display and health information, but they never participate in retrieval correctness.

## Why this approach

The Pickup chest is intentionally player-controlled, so its slot layout can change at any moment. Treating that layout as transactional state creates false failures after transfers that actually succeeded. Storage nodes are controlled by the application and provide the stable side of the transfer.

Alternatives rejected:

- Reinspect and replan around Pickup changes: still races with player interaction and adds complexity without improving proof of delivery.
- Reserve fixed Pickup slots: imposes artificial limits and conflicts with normal chest use.

## Operation boundaries

Retrieval and import deliberately use different validation rules:

- Retrieval (storage to Pickup): source-only preflight and verification; no destination slot or destination snapshot.
- Import (Drop-off to storage): retain exact destination planning, source and destination preflight, rescans, and conservation checks because the system controls both sides.

The planner and journal represent those differences explicitly. Retrieval steps contain the Pickup peripheral name but omit destination slot, epoch, and pre-count fields. Import steps continue requiring them.

## State, recovery, and errors

The actual count returned by `pushItems` is authoritative and is journaled before verification.

- Full move: verify the matching source decrease, then complete or continue the request.
- Partial move: verify that decrease, credit only the moved amount, then replan the remainder.
- Zero move with an unchanged source: block the request as `PICKUP_FULL`, keep it retryable, and explain that Pickup needs space.
- Source changed before the call: do not transfer; refresh storage and replan.
- Source does not reflect the journaled moved count: enter the existing explicit recovery path rather than guessing.
- Restart during an ambiguous call boundary: preserve the existing operator-safe recovery behavior.

Pickup changes can no longer turn a successful retrieval into a failure.

## User experience

Requests continue to show requested, delivered, and remaining quantities. A full Pickup chest produces a clear actionable state instead of a snapshot-mismatch error. Removing items from Pickup allows retry without rebuilding the request.

## Verification

Tests will prove:

- Retrieval planning does not depend on Pickup contents or capacity.
- Retrieval calls `pushItems` without a destination slot.
- Retrieval preflight and post-transfer verification never inspect or rescan Pickup.
- Empty, rearranged, and concurrently emptied Pickup states cannot cause false failure.
- Zero and partial transfer counts produce correct progress and retryable errors.
- Import behavior retains strict destination validation.
- Restart recovery remains source-authoritative for retrieval.

Before live deployment, the full Lua suite and formatting/diff checks must pass. Deployment requires re-confirming that live computer #4 is shut down and labeled `StorageController`; only manifest runtime files are copied, and existing `colossal/data` is preserved.