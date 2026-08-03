# Batch limit tuning

Status: pending. Small, measurement-driven; no design work needed.

## Why

After raising `slot_batch_limit` to 8, live measurement showed **6 of 7 batches hitting
exactly `steps=8`**. `batch_limit` (total moves issued per batch), not `slot_batch_limit`
(Drop-off slots selected per batch), is now the binding constraint.

Measured on controller 4, 2026-08-03:

| | `slot_batch_limit=1` | `slot_batch_limit=8` |
|---|---|---|
| batches | 59 | 7 |
| mean steps/batch | 1.9 | 7.7 |
| mean cycle | 1.58 s | 2.56 s |
| time per step | 0.83 s | 0.33 s |

A gate cycle costs roughly the same regardless of what it carries, so more steps per batch
keeps amortising the fixed overhead.

## The tradeoff

`batch_limit` bounds how many `pushItems` calls a single ambiguous window can span. If the
controller stops mid-batch, reconciliation still proves exactly what moved — aggregate
per-identity deltas do not care how many pushes produced them — but more items sit inside one
unproven window until the next boot reconciles it.

This is a judgement call about blast radius, not correctness.

## Steps

1. Raise `batch_limit` in `main.lua` (currently defaulted in `ImportService.new` and
   `Requests.new`, both `deps.batch_limit or 8`). Try 16.
2. Update the assertion in `tests/test_main.lua` that pins the shipped limits, and the cap
   test in `tests/test_import_service.lua` ("a batch is capped so one ambiguous window stays
   bounded").
3. Deploy per `AGENTS.md`, then measure with `scratchpad/probe.sh` against the numbers above.
   Compare **time per step**, never seconds per cycle: amortising fixed overhead correctly
   makes each individual cycle slower.
4. Keep it only if time per step actually improves. If batches stop hitting the cap, the
   constraint has moved back to `slot_batch_limit` or to how much the Drop-off holds, and
   further raising `batch_limit` buys nothing.

## Note

`slot_batch_limit` may also want raising in the same pass, since with `batch_limit=16` a
batch could usefully draw from more than 8 Drop-off slots. Change one at a time and measure
between, or the attribution is lost.
