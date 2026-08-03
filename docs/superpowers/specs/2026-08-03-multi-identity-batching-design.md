# Multi-identity import batching (schema 4)

Status: implemented on `perf/multi-identity-batch`, shipped with `slot_batch_limit=1` so
deployed behaviour matches single-slot importing until the limit is raised. Builds on the
schema 3 batch work (`c95b67d`, `6ceb9be`).

Head-of-line blocking, listed under "Import service" below, was deliberately left out of the
first implementation so the batching change stayed reviewable on its own. A source whose plan
comes back empty still blocks the batch rather than being deferred and skipped.

## Problem

Live measurement on controller 4 (2026-08-03, ~3k slot Colossal Chest, ~440 occupied,
12k items over 200+ types):

```
batches=55   mean items/batch=22.6   mean cycle=1.54s
batch composition:  51 x steps=1   ·   3 x steps=2
batches moving <=8 items:   28  (51%)
batches moving >=60 items:  10  (18%)
```

The controller pays **one full gate cycle per Drop-off slot**, about 1.54 s, regardless of
whether that slot holds 1 item or 64. Half of all cycles move 8 items or fewer.

Schema 3 batching (already shipped) collapses the steps *within* one Drop-off slot's plan.
That turned out to be 6% of this workload: the planner only emits multiple steps when a
partial stack of the same identity already exists to top up, and after an item type has been
imported once there is usually at most one such stack. 94% of plans are a single step.

The granularity that matters is **across Drop-off slots**, not within one slot's plan.

## Goal

Process up to N Drop-off slots per gate cycle. At N=8 the measured workload goes from ~55
cycles to ~7. Even allowing for longer cycles from more pushes, that is roughly 5-6x, and it
specifically eliminates the 51% of cycles that move almost nothing.

## Why this is still provable

`core/reconciliation.lua` measures an aggregate delta **per identity key** across the whole
storage pool. Two different item types are independent conserved quantities: pushing
cobblestone cannot change the measured total of ender pearls.

So the existing argument extends directly. Capture a baseline **per distinct identity** from
one fresh scan, issue every push, then measure **each identity independently** against its own
baseline from one post-scan. Each identity is proven exactly as it is today. Nothing about
"never replay an uncertain call" changes.

This is the same reasoning that made schema 3 sound, lifted from one identity to a map.

## Invariants that must survive

Carried forward from `AGENTS.md` and the existing suite. Every one of these has a test today
and must still have one after:

1. Aggregate exact-identity storage deltas are authoritative. A `pushItems` return value is
   diagnostic only and must never override measured storage truth.
2. Journal transfer intent before the inventory call. Never replay an uncertain or
   already-issued call.
3. A zero-movement or ambiguous operation settles into an explicit blocked state awaiting
   operator retry, never an automatic retry from unrelated background scan generations.
   (`SHORT_TRANSFER` / `PICKUP_FULL`.)
4. Retrieval verification depends on controlled Storage state, never on mutable Pickup
   contents. Requests must not inspect Pickup.
5. Imports retain strict destination-slot preflight.
6. Schema 1, 2 and 3 journals must still validate, verify and recover unchanged, so an
   upgrade cannot orphan a journal that is in flight when the controller stops.
7. One coordinator work loop. Peripheral calls yield, so concurrent loops can duplicate
   transfers.

## Design

### Journal schema 4

```lua
{
  schema=4,
  operation={id, kind, state, moved},
  batch={
    id="import-12:1",
    phase="INTENT"|"CALLING"|"CALLED"|"RECONCILED",
    storage_node_ids={...},            -- sorted, shared scope for every identity
    identities={                        -- one entry per distinct identity in the batch
      {identity_key="...", storage_pre_count=N, limit_total=M,
       reported_total=R?, actual_moved=A?},
      ...
    },
    steps={
      {identity_key="...", source_name, source_slot, source_epoch,
       destination_name, destination_slot, destination_epoch,
       destination_pre_count, limit},
      ...
    },
  },
  updated_at=...,
}
```

`identities` is sorted by `identity_key` for deterministic validation, mirroring how
`storage_node_ids` is already sorted in `validateScope`.

### Reconciliation

Add to `core/reconciliation.lua`:

- `M.captureMany(identityKeys, snapshots)` -> `{node_ids=..., totals={[key]=n}}` or
  `nil, reason`. Must reuse the existing scope validation: every configured node present and
  `READY`, no duplicates, otherwise `STORAGE_SCOPE_INCOMPLETE` with `rescan`.
  **Single pass over slots**, accumulating all requested keys at once - do not call
  `capture` per identity, that is O(identities x slots).
- `M.measureMany(kind, baseline, snapshots)` -> `{state="READY", moved={[key]=n},
  before={[key]=n}, after={[key]=n}}`, or `WAITING` / `FAILED` exactly as `measure` does.
  Direction rule per identity is unchanged: `request` is `before-after`, `import` is
  `after-before`.

Keep `capture` and `measure` as they are; schema 2 and 3 journals still use them.

### Transfer

Add `Transfer:executeMultiBatch(operation, steps, storageSnapshots)`:

1. Group steps by `identity_key`, preserving first-seen order for deterministic preflight.
2. `captureMany` over the distinct keys - one baseline set, one scan.
3. Preflight: each distinct source slot once (identity match, `count >= sum of its limits`),
   then every destination slot. All before any push. Planner destination slots are distinct
   *within one plan*; across plans for different identities they are also distinct because
   each plan only claims empty slots or slots already holding its own identity. Assert this
   and fail `DESTINATION_COLLISION` if two steps target the same `(name, slot)`.
4. Write `INTENT`, then `CALLING`.
5. Push every step in order. On an unknown outcome, stop and leave the journal at `CALLING`.
   Accumulate `reported_total` per identity.
6. Write `CALLED` only if every issued call returned a count.
7. `verify` measures with `measureMany`, writes `RECONCILED` with per-identity
   `actual_moved`, returns `moved` as a per-identity map plus a scalar total.

A negative delta for **any** identity is `RECONCILE_DIRECTION` for the whole batch. Do not
partially accept: the operator needs to see one coherent alert.

### Import service

This is the hard part. `app/import_service.lua` currently assumes a single active source slot
throughout: `source.count`, `original_count`, and the `PARTIAL` -> `PLANNING` replan all read
`context.dropoff.slots[active.source.slot]`.

Restructure `self.active` to hold a list:

```lua
active = {
  id, kind="import", state, moved=0, attempts=0,
  sources = {                       -- up to batch_limit entries
    {slot, identity_key, name, nbt, count, max_count, original_count, moved=0},
    ...
  },
  steps = {...}, journal=..., ...
}
```

- `_discover` selects up to `slot_batch_limit` (default 8) occupied Drop-off slots in
  ascending slot order. **Skip a slot whose identity currently has a blocked import**, which
  also fixes today's head-of-line blocking where one un-importable item stalls everything.
- `PLANNING` calls `planner.planImport` once per source and concatenates, capped at
  `batch_limit` total steps. If a source's plan is empty, record its block reason and drop
  that source from the batch rather than blocking the whole batch.
- `VERIFYING` credits each source from its own measured delta.
- `PARTIAL` re-discovers rather than assuming the same slots.
- A pre-call source change abandons **only the affected source**, not the batch. Keep the
  `_abandon` semantics added in `83ecbbf`.

### Requests

Retrieval already plans multiple source slots for one identity, so it gains less. Wire it to
`executeMultiBatch` for a single identity so there is one code path, but do not attempt to
merge distinct requests into one batch in this change.

## Files

| File | Change |
|---|---|
| `core/reconciliation.lua` | add `captureMany`, `measureMany`; single-pass accumulation |
| `core/transfer.lua` | schema 4 validation, `executeMultiBatch`, generalise `record`/`reportedOf` |
| `app/import_service.lua` | multi-source active state, per-source crediting, slot selection |
| `app/requests.lua` | route through `executeMultiBatch` |
| `main.lua` | pass `slot_batch_limit` / `batch_limit` |
| `docs/operations.md` | describe multi-slot batching and its cap |

## Tests

New (`tests/test_transfer_multibatch.lua`, `tests/test_reconciliation_many.lua`):

- Two identities in one batch each measure against their own baseline.
- A delta in identity A does not affect the measured result for identity B.
- One negative delta blocks the whole batch as `RECONCILE_DIRECTION`.
- Destination collision across plans is refused.
- Unknown call outcome mid-batch leaves `CALLING`, remaining steps abandoned.
- `captureMany` walks slots once for N identities (assert slot visit count).
- Schema 1/2/3 journals still validate, verify and recover.

Import service:

- 8 Drop-off slots of different types import in one gate cycle.
- A blocked identity is skipped and the other slots still import (head-of-line).
- A pre-call change to one source abandons only that source.
- Per-source partial crediting is correct when identities move different amounts.

Regression: the whole existing suite must stay green. It was 222 passed / 0 failed at
`6ceb9be`.

## Rollout

1. Implement behind the existing `batch_limit`, with `slot_batch_limit=1` reproducing today's
   behaviour exactly. Ship with 1, confirm no change live, then raise to 8.
2. Deploy per `AGENTS.md`: confirm shutdown in conversation, re-read `colossal/data/config.lua`
   for id 4 / `StorageController`, deploy only manifest paths with LF endings, preserve
   `colossal/data/`, then SHA-256 compare all 26 files and `luac -p` each.
3. Measure with `scratchpad/probe.sh`, which records `schema`, `steps=N`, `limit_total` and
   `reported_total` per journal state change. Compare against the 55 cycles / 1.54 s / 22.6
   items-per-batch baseline above.

## Risk

Highest-risk change in this project so far. It touches the reconciliation core and the import
state machine simultaneously. Mitigations: `slot_batch_limit=1` is an exact behavioural
fallback; schema 1-3 paths stay untouched; per-identity measurement is the same proof already
trusted, just applied N times.

Do not hand this to a subagent. The correctness argument depends on invariants that are hard
to state completely in a prompt.
