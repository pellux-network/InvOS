# Remaining UX gaps

Status: done. All three items landed on `fix/remaining-ux-gaps` (2026-08-03). Small,
independent items left from the 2026-08-03 audit. Each is self-contained and suits a
focused session; none touch reconciliation or the journal.

## 1. Empty-query result ordering is a no-op

`app/search.lua` sorts results with no query by `request_count` then `last_requested`:

```lua
if query == "" then
    if left.request_count ~= right.request_count then ...
    if left.last_requested ~= right.last_requested then ...
```

Nothing ever populates either field, so both are always 0 and the sort falls through to
quantity. `core/index.lua` reads `item.request_count or 0` when building variants, so the
plumbing is already there — only the recording is missing.

**Do:** count retrievals per identity and record the last time each was requested, then
persist alongside the learned metadata cache. `Requests:create` in `app/requests.lua` is the
natural place to record, since it already receives the exact identity.

**Constraint:** this is usage history, not stock truth, so it belongs in the same
re-learnable-cache category as display names. Persist counts and timestamps only, never
quantities or slots, and boot fine when the file is missing. `Index.validateMetadata` already
rejects `quantity`, `count`, `slot`, `slots` and `sources`; extend it rather than adding a
second store.

**Value:** the default search view becomes genuinely useful — your most-used items first
instead of whatever happens to be most numerous.

## 2. Completed requests are never pruned

`app/requests.lua` appends to `self.ordered` and never removes. `Requests:list()` deep-copies
the whole list, and `Coordinator:_model()` calls it on every redraw. So a long-running
controller accumulates request history without bound, and pays to copy all of it each frame.

The requests page also renders from the start of the list, so once it overflows the screen
the newest requests are the ones pushed off.

**Do:** cap retained terminal requests (a few dozen), dropping oldest first, and render
newest first. Keep any non-terminal request regardless of age.

**Careful:** `Coordinator:_dispatch` resolves the retry/cancel selection index against the
live list, so changing list order means updating that mapping — see the operator-control
tests in `tests/test_operator_controls.lua`.

## 3. F10 from a secondary page does not return to Search

`app/ui.lua`, `CANCEL` sets `state.mode = "search"` but leaves `state.page` unchanged, so
pressing F10 on the Nodes or Alerts page leaves you on that page in search mode. The
documented way back is the `1` digit key.

Flagged during the operator-controls work and deliberately not fixed then, because it was
out of scope and touching mode/page transitions risked side effects elsewhere.

**Do:** decide whether F10 should return to Search or do nothing outside overlays, then make
`CANCEL` consistent with it. `docs/operations.md` describes the key behaviour and should
match whichever is chosen.

## Not included

`app/monitor.lua` once rendered a "RECENT MOVEMENT" section from `model.recent_transfers`,
which nothing ever populated. The dead section was removed rather than implemented. If the
feature is wanted, `app/coordinator.lua` would need to record a short transfer history and
expose it on the model.
