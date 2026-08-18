# Operation-Scoped Storage Scans

## Problem

Drop-off imports and retrievals currently slow down with the number of configured storage
nodes, even when an operation touches only one of them. A storage scan makes one `size()` and
one `list()` peripheral call per node. Those calls yield in CC:Tweaked, while walking the slots
returned by `list()` is comparatively cheap. This is why ten 50-slot nodes are slower than one
500-slot node.

Each transfer batch currently pays for two broad gates:

1. Before planning, the coordinator scans every storage node plus the relevant endpoint
   (Drop-off, Pickup, or craft buffer).
2. Before reconciliation, the transfer journal records every storage snapshot it was given,
   so verification scans every storage node again. Imports also rescan Drop-off.

An emulator retrieval of one iron ingot measured 0.72 seconds with one storage node and 2.75
seconds with twenty. The fixed work is approximately `2N` storage scans for `N` configured
nodes, regardless of how few nodes the plan uses.

A previous change (`a3f851a`) narrowed retrieval planning from the old index and was quickly
reverted (`5fb51a5`). It did not revalidate that the plan still used the same nodes after its
targeted scan, and it left reconciliation scoped to every storage node. This design does not
restore that change.

## Goals

- Make the normal import and retrieval path scale with the number of storage nodes the batch
  touches, not the number configured.
- Preserve measured-delta reconciliation, one-call transfer behavior, exact NBT identity,
  bounded batches, and restart recovery.
- Fall back to a complete pool refresh when a narrow plan cannot be established confidently.
- Keep old schemas 1, 2, 3, and 4 recoverable without migration.
- Keep crafting plan freshness unchanged; a craft can depend on many identities spread over
  the entire pool.
- Keep deposit discovery responsive when many storage nodes are overdue for background scans.

## Non-goals

- Do not infer successful movement from `pushItems` return values.
- Do not mutate snapshots or the index optimistically after a transfer.
- Do not run scanners or automation loops concurrently.
- Do not change batching limits or the planner's storage priority and placement policy over
  the snapshots it is given.
- Do not weaken exact slot preflight or ambiguous-call recovery.

## Invariants

The implementation must preserve these rules:

- No inventory call is issued until every endpoint in the final plan has a fresh scan.
- Every source and import destination slot is inspected immediately before the first push.
- A change detected before any push is non-ambiguous and causes replanning, never recovery.
- Once any push may have run, only measured storage deltas settle the journal.
- A journal's storage scope includes every storage node the batch can change.
- A recovery uses the exact scope persisted in the journal. Existing broad-scope journals stay
  broad; new narrow-scope journals stay narrow.
- One coordinator work loop remains the only loop that scans or advances automation.
- Unrelated storage nodes are outside a transfer's proof because the controller did not issue
  a call that could change them. Storage remains controlled during the ambiguity window, as
  required by the existing reconciliation design.

Targeted planning deliberately does not promise globally freshest placement. For example, an
unrelated higher-priority node that became empty after its last background scan may be missed
while the tentative plan uses a lower-priority node that is known to have room. The same
planner ordering still applies to all known snapshots, safety is unaffected, and background
refresh discovers the newer capacity. Requiring proof that no unscanned node has preferable
capacity would itself require scanning the whole pool and would make the stated performance
goal impossible. A no-plan or unstable-plan path still refreshes the complete pool before it
blocks.

## Design

### 1. Service-owned tentative planning

Requests and imports will own their planning scopes because they understand which endpoint of
a transfer is storage. The coordinator will only execute a requested gate.

On the first `PLANNING` tick, the service plans against the current derived index and snapshots.
The plan is tentative: no state advances to `TRANSFERRING` and no inventory call occurs.

If the tentative plan has steps, the service maps their storage peripheral names back to node
IDs and requests a targeted rescan:

- Retrieval: every selected storage source plus the request destination (Pickup or craft
  buffer).
- Import: Drop-off plus every selected storage destination.

The service stores the targeted storage-node set and the fact that one targeted gate was
requested. The coordinator waits for every requested node's scan revision to advance before
ticking that service again.

### 2. Post-gate replanning

When the service resumes in `PLANNING`, it runs the planner again from the refreshed context.
It does not execute the tentative steps.

- If all storage endpoints in the new plan are members of the refreshed set, those new steps
  become final and the service advances to `TRANSFERRING`.
- If the new plan selects different storage endpoints, the service requests one more targeted
  gate for the new set and remains in `PLANNING`.
- If the plan changes again, mapping is incomplete, a selected node is unhealthy, or the
  planner has no steps, the service requests one complete relevant-pool refresh.
- After that complete refresh, the service either commits a valid plan or uses its existing
  blocked/deferred behavior. It does not start an unbounded rescan loop.

The full relevant pool is all enabled storage nodes plus Drop-off for imports or the actual
request destination for retrievals. Planning refresh bookkeeping is cleared when a plan is
committed, abandoned, completed, cancelled, or explicitly retried.

### 3. Coordinator gating

The coordinator's current automatic complete-pool planning gate will remain for crafting but
will be removed for the import and request services. Those services instead return `rescan`
while remaining in `PLANNING`.

The coordinator will treat a `PLANNING` result carrying `rescan` as a planning gate. Its
existing revision-based gate supplies the necessary guarantee: the same service cannot resume
until every requested scan completed after the request was made.

Transfer exclusivity is unchanged. A service in `TRANSFERRING` or `VERIFYING` still prevents
another service from planning, and scanning remains forbidden while a service is
`TRANSFERRING`.

### 4. Pre-call plan invalidation

The transfer layer keeps exact live inspection of all grouped sources and all import
destinations. If inspection returns `SOURCE_CHANGED` or `DESTINATION_CHANGED`, no push has run.
The service clears its final steps, returns from `TRANSFERRING` to `PLANNING`, and requests a
targeted refresh. This transition is permitted only for those preflight failures and only when
the result contains no journal.

Unknown call outcomes and failures after journal phase `CALLING` continue directly to
`VERIFYING`; they are never replanned or replayed.

### 5. Operation-scoped reconciliation

Before capturing a baseline, `core/transfer.lua` will derive the storage footprint from the
final steps:

- Retrieval footprint: unique `source_name` values.
- Import footprint: unique `destination_name` values.

It will select the matching configured storage snapshots, including an unhealthy matching
snapshot so reconciliation can return `STORAGE_SCOPE_INCOMPLETE`. A missing or duplicate
mapping fails closed before journaling or pushing.

`capture` and `captureMany` receive only that footprint. Existing journal schemas already
accept any non-empty, sorted `storage_node_ids` list, so no schema change is needed. The
journal then naturally drives a targeted verification gate and targeted restart recovery.

For a batch spanning several nodes or identities, the footprint is the union of all storage
endpoints. Each identity is still measured independently across that complete union. Slot
compaction inside a touched node remains harmless because reconciliation uses aggregate exact
identity totals, not slot positions.

### 6. Responsive Drop-off discovery

The idle stale-node selector currently always chooses the oldest node. With enough storage
nodes, an overdue Drop-off can remain behind a long storage rotation even though the refresh
interval is meant to bound deposit discovery.

When Drop-off is past `scanRefreshInterval`, it will be selected ahead of ordinary stale
storage nodes after the current scan finishes. This does not interrupt a scan, bypass failure
backoff, or alter targeted transfer gates. Other nodes continue to rotate by age, so one
Drop-off scan per interval cannot starve storage refreshes.

## Failure Handling

- **No tentative plan:** request one full relevant-pool refresh. If no plan exists afterward,
  use the current `INSUFFICIENT_STOCK`, `STORAGE_FULL`, or deferral path.
- **Plan shifts once:** gate the new targeted scope and replan.
- **Plan shifts repeatedly:** widen to one full relevant-pool refresh.
- **Node mapping missing or duplicated:** widen while planning; fail closed in transfer if a
  final endpoint still cannot map uniquely.
- **Selected node unhealthy:** the gate retries through existing scanner backoff; transfer
  capture also refuses an incomplete footprint.
- **Source or destination changes during final preflight:** discard the uncalled attempt and
  replan.
- **Call outcome unknown:** leave the journal at `CALLING`, stop issuing the batch, scan the
  journal footprint, and reconcile exactly as today.
- **Restart:** schemas 2-4 reconcile their recorded scope; schema 1 keeps its existing legacy
  handling. No startup migration rewrites a journal.

## Testing

### Host tests

- Coordinator tests prove a one-node request/import scans the same targeted count when one or
  many unrelated storage nodes are configured.
- Service tests cover tentative planning, post-gate replanning, one retarget, complete-pool
  fallback, no-plan fallback, unhealthy nodes, and reset of refresh bookkeeping.
- A drift reproduction changes the preferred node during the targeted scan and proves no push
  uses an endpoint that was not refreshed.
- Transfer tests pass touched and unrelated snapshots and assert that new journals record only
  request sources or import destinations.
- Multi-node and multi-identity batches record the union of touched nodes and conserve every
  identity independently.
- Existing broad-scope schema 2, 3, and 4 journals still wait for and reconcile every recorded
  node.
- Exact NBT variants, negative deltas, ambiguous calls, destination collisions, and recovery
  retain their existing behavior.
- Stale-node scheduling tests prove an overdue Drop-off is promoted without starving ordinary
  storage rotation or bypassing backoff.

### Emulator tests and measurements

- Add or extend a configured scenario so storage node count can vary while stock and requested
  work remain constant.
- Exercise an actual one-item retrieval through the terminal at 1, 5, 10, and 20 storage nodes.
- Exercise a boot-time Drop-off import into one destination over the same node counts.
- Use peripheral profiling to compare `size`, `list`, and `pushItems` calls, with background
  refresh noise excluded or bounded explicitly.
- The normal one-node-footprint retrieval should require two planning scans (source and
  destination) plus one storage verification scan, independent of unrelated node count.
- The normal one-node-footprint import should require two planning scans (Drop-off and
  destination) plus two verification/continuation scans, independent of unrelated node count.
- Run the complete host Lua suite and `python tools/emulator/run_tests.py all` after focused
  tests pass.

## Success Criteria

- For a request touching one storage node, targeted transaction scan count is constant as
  unrelated storage nodes are added.
- For an import touching one storage node, targeted transaction scan count is constant as
  unrelated storage nodes are added.
- Work scales with the union of nodes actually used when a batch legitimately spans several
  nodes.
- The complete-pool fallback is bounded to one refresh per planning attempt.
- All conservation, preflight, journal, recovery, responsiveness, host Lua 5.4, and emulator
  Lua 5.2 tests pass.
- No runtime file outside the deployment manifest is introduced.
