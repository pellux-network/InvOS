# Setup Wizard Visual Polish

## Context

The setup wizard (`app/ui.lua`'s `UI:_setupWizard` / `UI:_setupRename`) is the first
screen a new install shows, and it currently looks and behaves like a different, older
product than the rest of InvOS:

- **Text is cut off, not wrapped.** Prompts and Validate issue messages are drawn as a
  single `Draw.text` call with no wrapping. Several prompts run 50-60 characters against a
  ~48-character budget (`Read-only discovery of the wired inventories on the network.` is
  60; `The inventory retrievals are delivered to, for collecting.` is 58), and the longest
  Validate issue messages run to 61 characters. All of them are silently clipped.
- **Mouse input does nothing.** `_setupWizard` and `_setupRename` both
  `return {hit_regions={}}` unconditionally — no card, button, or footer hint is ever
  clickable, unlike every other page in the app.
- **It skips the section-band convention every other list page uses.** Search has an
  `ITEM / STOCK` band, Storage has `NODE / USED`, Requests has `REQUEST / PROGRESS`. The
  wizard's choice list has no band at all, and its rows are single dense lines rather than
  the breathing-room card style the rest of this pass already asked for elsewhere.

Two layout directions were mocked up with the real palette (`app/theme.lua`) on the real
51×19 grid and reviewed side by side. The chosen direction: the wizard's content becomes
one panel-toned card inset from the dark ground, closer to a guided-dialog feel than the
flat full-bleed pages — a deliberate, distinct treatment for "you are in a guided flow."

This is a rendering/interaction pass only. No change to `app/setup.lua`, `main.lua`'s
`setupChoices`/`syncSetup`/`onEffect`, or any effect/command *shape* already established —
those were finished in the prior UX pass. This spec adds wrapping, mouse hit regions, and
the boxed-card visual treatment on top of that existing data flow.

## Goals

- Nothing in the wizard or rename screen is ever truncated — prompts and issue messages
  wrap to as many lines as they need (capped, generously, so a pathological string can't
  blow out the layout).
- Every clickable thing a keyboard user can reach is also clickable with the mouse: choice
  cards, Back/Next, storage-step rename, F10 cancel, and the rename screen's save/cancel.
- The wizard reads as part of the same app as Search/Storage/Requests: a labeled section
  band above its list, and a consistent card format for every step instead of dense
  single-line rows on most steps and only Validate getting special treatment.
- No regression to the four other pages that already share `UI:_row`/`UI:_list` — this
  stays additive to those, never a rewrite of them.

## Non-goals

- No change to what data the wizard receives (`state.setup_choices`, `state.setup_issues`,
  `state.setup_summary` keep their existing shapes from the prior pass).
- No change to keyboard behavior already shipped (Up/Down/Enter/Left/Right/F10/R)  — mouse
  is additive, not a replacement.
- No attempt to reproduce CC:Tweaked's bitmap font pixel-for-pixel in any preview tooling;
  that ended with the mockup step once the direction was chosen.

## Design

### 1. Word wrap

A small, pure local helper in `app/ui.lua` (alongside `fittedLabel`, `scrollFor` — this file
already keeps its private text-layout helpers as local functions rather than in `Draw`,
which stays surface-writing primitives only):

```lua
local function wrapText(text, width, maxLines)
```

Greedy word wrap: builds lines up to `width` characters, breaking on spaces. A single word
longer than `width` (never happens with today's vocabulary — peripheral names and short
prose — but must not corrupt layout if it ever did) is hard-cut rather than left to
overflow. `maxLines`, when given, caps the returned line count; content beyond it is simply
not returned (the caller decides whether that's acceptable — see the per-card wrapping rule
below, where it is: the second line already prefers the wrapped message over the hint).
Always returns at least one line (possibly empty).

### 2. Boxed-card chrome

`_setupWizard` and `_setupRename` fill the whole content band as one panel-toned card
instead of drawing directly on the ground color:

- Rows `regions.content.top - 1` through `regions.content.bottom + 1` (this reclaims the
  currently-dead nav row and strip row the wizard never used), columns 2 through
  `regions.width - 1`, filled with `Theme.role.panel` — a one-column ground-colored margin
  survives on both sides, and one blank row of padding top and bottom inside the card.
  Actual content still lives at `regions.content.top`..`regions.content.bottom`, unchanged
  budget from today; the reclaimed rows are pure padding.
- The section band above the choice list (new — see part 3) fills with `Theme.role.track`
  instead of `Theme.role.panel`, so it reads as a distinct header against the card's own
  panel-colored background rather than blending into it.
- Every row/card drawn inside the box uses `panel` as its *unselected* background instead
  of `ground` — see part 4 for how that's threaded through the shared `UI:_row`.
- The header row (1) and footer/status rows (18, 19) are unchanged from today — the card is
  strictly the middle content band; header and footer keep reading as the same chrome every
  other page has.

### 3. Section band

Each step gains one labeled band above its list, matching Search/Storage/Requests exactly
(`self:_bandText` left, `Draw.rightText` right), recolored to `track` per part 2. Left
label is step-appropriate ("INVENTORY" for role/storage steps, "CHECKS" for Validate); right
label is the short column header where one applies ("SIZE" on inventory steps), omitted
where it doesn't (Validate, Review, the single-choice steps).

### 4. Card list

Every choice and issue renders as a two-physical-row card: title line, then a detail line
(muted) directly beneath it. This is one format for every step, not a special case for
Validate — short items just have a short or blank second line.

`UI:_row` gains one new, optional, trailing parameter: `baseBg` (defaults to
`Theme.role.ground` when omitted, so every existing call site in Search/Storage/Requests/
Alerts/Crafting is untouched). The wizard passes `Theme.role.panel`. A new `UI:_cardDetail`
method fills a card's second physical row the same way — `focus` fill when selected
(so the *whole* two-row card highlights together, not just its title line), `baseBg`
otherwise — with the detail text in muted/ground-on-focus color.

Per-card text resolution:

```
labelLines = wrapText(item.label, innerWidth, 2)
line1 = labelLines[1]  (+ item.right, inline right-aligned, when present — e.g. "27 slots")
line2 = labelLines[2] if the label itself needed two lines, otherwise item.detail
```

This is why a wrapped 61-character Validate message doesn't lose its "Enter jumps to step
4" hint by accident — it loses it *only* when the message itself filled both lines, which
is the only case where there's nowhere left to put it. Short items (most choices on most
steps) show their existing one-line detail exactly as before, just with a real second row
of visual space around them instead of being crammed edge-to-edge.

List scrolling can't reuse `UI:_windowed`/`UI:_list` as-is (both assume one row per item).
A new `UI:_cardWindow(top, bottom, count, selection, rows, render)` mirrors `_windowed`'s
scroll-math but divides available space by `rows` (2) instead of 1. `UI:_list` and
`UI:_windowed` themselves are untouched — this is a new, parallel method, not a rewrite of
the one four other pages depend on.

### 5. Review step

Summary rows (`state.setup_summary`) render as label/value lines directly inside the card —
these are informational, not selectable, so no card-fill treatment. The one real action —
"Save configuration and enable" — renders as a genuine card in the same format as every
other step's choices (title + detail line, focus-fills when selected), rather than a bare
text button. This was already the plan from the prior pass; this spec just brings its
visual format in line with part 4.

### 6. Mouse

`_setupWizard` and `_setupRename` build a real local `hitRegions` table during rendering and
return it (`{hit_regions = hitRegions}`) instead of the current hardcoded `{hit_regions={}}`.

- **Every card** (both its physical rows) is one hit region. Its command is a new
  `SETUP_ACTIVATE` kind carrying the clicked index — `UI:reduce`'s handler sets
  `state.selection` to that index and returns the *same* `SETUP_SELECT` effect Enter
  already produces, so main.lua's `onEffect` needs no new branch. This mirrors exactly how
  Search's and Crafting's row clicks already work (`{type="ACTIVATE", index=...}`): one
  click both selects and activates, it doesn't require a select-then-separate-click.
- **Footer segments** ("Left back", "Right next", and — storage step only — "R rename") are
  drawn through a small local `footerSegment` helper that both draws the text and registers
  its exact column span as a hit region (`SETUP_BACK` / `SETUP_NEXT` /
  `RENAME_STORAGE_REQUEST`), the same technique `UI:_nav`'s tab clicks already use for the
  page-switch bar.
- **Status line** "F10 cancel" is one hit region → `CANCEL_SETUP`.
- **Rename screen** footer: "Enter save" → `RENAME_CONFIRM`, "Left/F10 cancel" →
  `RENAME_CANCEL`.

No new keyboard behavior — every one of these commands already exists and is already
handled by `main.lua`'s `onEffect` or `UI:reduce` from the prior pass; this only adds a
second way to produce them.

## Testing

- `tests/test_setup_ui.lua`: wrapping (long prompt/issue text produces multiple rendered
  lines, nothing past the terminal width per `writesOutsideBounds()`), card-list rendering
  (detail line present/absent, focus-fill spans both rows of a selected card), the boxed
  card fill itself (`foregroundAt`/background assertions), `UI:_row`'s new `baseBg` default
  staying `ground` when omitted (regression guard for the four pages that don't pass it).
- `tests/test_setup_wizard_flow.lua`: clicking a card via `coordinator:handle({"mouse_click",...})`
  produces the same state change as arrowing to it and pressing Enter; footer/status clicks
  drive `SETUP_BACK`/`SETUP_NEXT`/`RENAME_STORAGE_REQUEST`/`CANCEL_SETUP`; rename-screen
  clicks drive `RENAME_CONFIRM`/`RENAME_CANCEL`.
- `tests/test_ui.lua` / existing Search/Storage/Requests/Alerts/Crafting tests: full suite
  must stay green unmodified — the `baseBg` addition to `UI:_row` and the new
  `UI:_cardWindow` are additive, not edits to the shared list path those pages use.
- `lua storage/tests/run.lua` (full suite) before calling this done.

## Risks

- **Card rows double the vertical cost of a long list.** A step with many discovered
  peripherals now shows half as many per screen before scrolling. Scrolling already exists
  and this matches the "not cramped" goal directly, but it's a real, deliberate trade-off:
  more clicks/arrow-presses to reach the bottom of a long discovery list, in exchange for
  every card being legible without truncation.
- **`UI:_row`'s new parameter is additive but touches a function four other pages call.**
  Mitigated by defaulting to today's exact behavior (`Theme.role.ground`) when the new
  argument is omitted, and by the full-suite regression run being part of done, not optional.
