# Import Stack Limits Design

## Problem

CC:Tweaked inventory `list()` returns basic item data but not `maxCount`. The scanner currently copies only that basic data into Drop-off snapshots. Import planning therefore defaults every source item to a stack limit of 64.

For a non-stackable item already present in storage, the planner incorrectly treats its occupied slot as having 63 free spaces. The attempted transfer moves zero items and blocks before the planner considers an empty slot. The same capacity error affects items whose maximum stack size is below 64.

## Design

When scanning an occupied Drop-off slot, the scanner calls `getItemDetail(slot)` and records its positive integer `maxCount` as snapshot field `max_count`. Other inventory roles continue using `list()` data only, so large Colossal Chest scans do not gain per-stack detail calls.

The existing Import Service already copies `max_count` from the Drop-off snapshot into its source model, and the planner already caps matching-stack and empty-slot capacity with that value. Those components remain unchanged.

If `getItemDetail` throws, returns no item, returns a different basic identity/count than `list()`, or lacks a valid positive integer `maxCount`, the Drop-off scan fails with a structured scanner error. The controller never substitutes 64 when the authoritative stack limit was requested but unavailable.

## Resulting behavior

- A second identical non-stackable item skips the occupied item slot and uses an empty storage slot.
- Reduced-stack items fill matching stacks only to their true item maximum, then continue into empty slots.
- Normal 64-stack items retain current behavior.
- Storage, Pickup, and large Colossal Chest scans retain their current call count and performance.

## Verification

Scanner tests cover successful Drop-off detail enrichment, detail exceptions, missing detail, mismatched detail, invalid `maxCount`, and no detail calls for storage nodes. Planner tests cover stack limits of 1 and 16. An import integration test proves two sequential non-stackable deposits select different storage slots without a zero-movement block.
