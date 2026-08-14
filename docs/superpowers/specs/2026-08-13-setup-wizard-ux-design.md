# Setup Wizard UX Pass

## Context

`app/setup.lua` is the setup wizard's model: discovery, role assignment,
storage node management, validation, and commit. It is solid and already
supports more than the wizard UI exposes — `Setup:updateStorage` accepts a
`label` field, and `Setup:confirmDistinct` resolves a suspected-duplicate
storage pair. The wizard's UI (`main.lua`'s `setupChoices`/`syncSetup`/
`onEffect`, `app/ui.lua`'s `_setupWizard`, `app/keymap.lua`'s setup-mode
key handling) is functional but has several concrete confusion points and
one outright dead end, found by tracing the step-by-step flow:

1. **Right-arrow ("next") silently skips assignment.** `SETUP_NEXT` always
   advances the step counter regardless of whether anything was selected.
   On the Drop-off/Pickup steps this leaves the role unbound with no
   feedback. On the Validate step, pressing → instead of Enter jumps
   straight to Review without re-running validation — if the draft has
   blocking issues, Review's Enter then does nothing at all, because its
   handler only acts when a `report.ok == true` from an earlier validation
   run is still in scope.
2. **Validate shows only the first issue.** `state.setup_issues[1]` is the
   only one rendered; the rest are invisible until that one is fixed and
   validation is re-run.
3. **"Review and enable" has no review.** It is a single "Save
   configuration and enable" button with no summary of what is bound.
4. **Duplicate-node confirmation is unreachable from the UI.**
   `Setup:confirmDistinct` is tested at the model layer (two nodes with
   identical fingerprints — e.g. two visually identical chests) but no
   key or command anywhere calls it. If `DUPLICATE_SUSPECTED` fires, the
   wizard cannot be completed without deleting one of the nodes, even when
   they are legitimately distinct.
5. **Storage nodes are labeled with the raw peripheral name** (e.g.
   `chest_0`) with no way to rename them, a known gap (`docs/backlog.md`).

A secondary bug underlies #1 and #3: the highlighted row index
(`state.selection`) currently carries over between *different* wizard
steps rather than resetting, so a row highlighted near the bottom of one
step's list can land on an unrelated row of the next step's list.

This is a UX/interaction pass over an existing subsystem: no new pages,
no schema changes, no behavior change to the model layer.

## Goals

- Right/Enter can no longer produce a state the operator didn't choose
  (skip a required role unnoticed, or skip validation unnoticed).
- Every current validation issue is visible at once, not just the first.
- Issues that map unambiguously to a step offer a direct jump there.
- The duplicate-node dead end is closed: confirming two nodes are
  distinct is a normal action available where the issue is shown.
- Review actually reviews: every bound role is visible before the final
  save.
- Storage nodes can be given a real name, both right after adding one and
  later by revisiting it.

## Non-goals

- No change to `Setup.validateConfig`, `Setup:validate`'s issue set, or
  any other model-layer behavior — `app/setup.lua` already supports
  everything this pass needs.
- No full-screen "confirm before save" page — the review stays inline on
  step 10, not a new step.
- No jump-to-step for issues that don't map to a single step
  unambiguously (e.g. `PERIPHERAL_MISSING`, which can be any role). These
  still show with their full message, just without a shortcut.
- No change to the digit-key page shortcuts (1–6) or any navigation
  outside setup mode.

## Design

### 1. Selection resets on step change, not on step re-sync

`UI`'s `SYNC_SETUP` reducer currently clamps `state.selection` to the new
choice count but never resets it, so a stale index can highlight the
wrong row after a step change. Fix: track the previous `setup_step`; if
the new step differs, reset `state.selection` to `1` (or, for step 10
specifically, to the last row — see part 3). If the step is the same
(e.g. re-syncing step 4 after toggling a storage node, or step 9 after
resolving one issue), keep the existing clamped selection so multi-step
interactions like storage add/remove don't lose their place.

This is what makes it safe for later parts to rely on "the highlighted
row is a sane default when you arrive at a step" (e.g. "Skip" highlighted
by default on optional binding steps).

### 2. Right no longer discards an unmade decision

In `main.lua`'s `SETUP_NEXT` handler:

- On step 2 (Drop-off) or step 3 (Pickup), if the role isn't yet assigned
  in the draft, → does not advance. It re-syncs the same step with an
  inline hint ("Select a Drop-off inventory, then press Enter or →"),
  using the existing single-line issue-hint rendering.
- On step 9 (Validate), → now runs validation (the same action as
  Enter on the "Run validation" row) instead of blindly advancing to 10.
- Every other step's → is unchanged — it was already safe to skip
  (discovery is a single confirm, storage is multi-add/remove with no
  "current" selection to lose, optional binds default to unbound, and
  step 10 has nothing to lose by *not* advancing further since it's the
  last step).

### 3. Validate step: full issue list, jump-to-step, duplicate confirm

`setupChoices`'s step-9 branch changes from a single static choice to:

- Row 1: "Run validation and continue" (unchanged action).
- One row per current issue, computed by calling `setup:validate()`
  directly inside `setupChoices` (read-only, matches the step's own
  "moves no items" description). Blocking issues render with an alert
  marker/color, informational ones (e.g. `DUPLICATE_CONFIRMED`) with a
  muted/warn marker — reusing `UI:_row`'s existing marker/color
  parameters, no new rendering primitive needed.
- Where a `code` maps unambiguously to a step (`MISSING_DROPOFF`→2,
  `MISSING_PICKUP`→3, `ROLE_COLLISION`→2, `MISSING_STORAGE`→4,
  `BUFFER_COLLISION`→5, `TURTLE_WITHOUT_BUFFER`→5), the row carries a
  `jump_step` field. Selecting it re-syncs directly to that step.
- `DUPLICATE_SUSPECTED` rows carry `confirm_nodes = issue.details.nodes`
  (already populated by `Setup:validate`) instead of a `jump_step`.
  Selecting the row calls `setup:confirmDistinct(a, b)`, re-validates, and
  re-syncs step 9 in place — so confirming distinctness happens right
  where the issue is shown, no navigation required.
- Selecting row 1 (or any row without `jump_step`/`confirm_nodes`) keeps
  today's behavior: re-validate, advance to 10 if `ok`, otherwise stay on
  9 with the refreshed issue rows.

Because issues now render as ordinary choice rows, the old single-line
`state.setup_issues` render at the bottom of the step is no longer used
for step 9 (it's passed `{}` when syncing that step); it still exists for
the new step 2/3 hints from part 2, and any other step that wants a
lightweight hint later.

### 4. Review summary at step 10

`_setupWizard` gains a step-10-only render branch: a static (not
selectable) summary block between the prompt and the choice list —
Drop-off, Pickup, storage nodes (`N enabled / M total`, not one line per
node, so it stays bounded regardless of node count), craft buffer,
turtle, main monitor, crafting monitor — each showing what's bound or
"not set". The data comes from a small `setupSummary(service)` helper in
`main.lua` (mirrors `setupChoices`), threaded through `syncSetup` as a
new `summary` field on the `SYNC_SETUP` command, stored as
`state.setup_summary`, consumed only by the step-10 render branch. The
choice list underneath is unchanged: a single "Save configuration and
enable" row, now with actual context above it. Per part 1's selection
rule, step 10 highlights that row by default (last row, not first) since
there's nothing else to select.

### 5. Inline rename for storage nodes

New UI mode `setup_rename`, entered two ways, both while `setup_step ==
4`:

- **Fresh add** (existing behavior today): selecting an unbound
  peripheral still calls `setup:addStorage` immediately with the default
  label (peripheral name), exactly as now. It then transitions into
  rename mode pre-filled with that default label instead of returning
  straight to the list.
- **Rename existing**: a new `R` key, while a node's row is highlighted at
  step 4, opens the same rename mode pre-filled with that node's current
  label. `R` on a peripheral that hasn't been added does nothing (nothing
  to rename yet — adding it already opens the rename prompt).

Rename mode reuses the Search box's existing text-entry pattern
(`char`/`paste` append, backspace, delete-to-clear), added to
`Keymap.command` under a `state.mode == "setup_rename"` branch:
`RENAME_APPEND`, `RENAME_BACKSPACE`, `RENAME_CLEAR` handled locally by
`UI:reduce` against `state.setup_rename_text`; `Enter` produces a
`RENAME_CONFIRM` effect (`node_id`, `text`), `Left`/`F10` produce
`RENAME_CANCEL`. `main.lua`'s `onEffect` handles `RENAME_CONFIRM` by
calling `setup:updateStorage(node_id, {label = text ~= "" and text or
nil})` (empty text leaves the existing label untouched rather than
blanking it) and `RENAME_CANCEL` by doing nothing; both re-sync step 4
and return `state.mode` to `"setup"` (added to the `SYNC_SETUP` reducer,
which currently never touches `mode`).

The step-4 choice list is updated so an added node whose label differs
from its peripheral name shows that label (e.g. `[added] chest_3 — as
"Vault A"`) instead of only ever showing the peripheral name — otherwise
a rename would be invisible until leaving the wizard. The step's footer
hint gains `R rename` when `setup_step == 4`.

## Testing

- TDD per module, following existing test file boundaries:
  `tests/test_setup_ui.lua` (keymap + render behavior for parts 1–4),
  `tests/test_setup.lua` / a new `tests/test_setup_rename.lua`-style
  addition for the rename effects, `tests/test_main.lua` for the
  `onEffect` wiring (guard on required steps, validate-on-Right,
  jump-to-step, confirm-distinct wiring, rename confirm/cancel).
- `lua storage/tests/run.lua` (full suite) from `controller/` before
  calling this done.
- Manual walkthrough in-repo isn't possible (no live CC:Tweaked runtime
  here); the test doubles in `tests/mock_cc.lua` are the verification
  surface, consistent with how the rest of this app is tested.

## Risks

- **Step-9 choices now call `setup:validate()` on every render of that
  step**, not just on explicit "Run validation" presses (e.g. also when
  `setupChoices` is invoked while merely rendering). This is read-only
  and matches the step's own description ("moves no items"), but it does
  mean discovery (`peripheral.getNames`/`hasType`/`wrap` calls) runs more
  often while sitting on that step than before — acceptable on
  CC:Tweaked's discovery cost, consistent with how `discover()` is
  already called freely elsewhere in this file.
- **Rename mode adds a fourth text-entry surface** (after Search,
  Crafting search, and quantity boxes) with its own small state slice —
  kept as narrow as possible (one string, one target id) to avoid
  cross-contaminating the existing search/quantity state machines.
