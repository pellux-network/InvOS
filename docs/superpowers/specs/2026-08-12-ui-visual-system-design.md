# UI visual system

Status: **approved, not yet built.**

InvOS renders correctly and reads as a prototype. This redesigns the presentation layer around
a deliberate palette, a shared drawing vocabulary, and one layout grammar that every page and
both monitors follow. No behaviour changes: no new commands, no new effects, no change to what
the controller does with items.

The visual direction was chosen from three rendered alternatives. The approved one is
**"Panelled"**: labelled bands mark each region, a divider splits a list from a detail pane, and
a strip along the bottom keeps drop-off and pickup levels on screen. Structure comes from
filled bands rather than frames, because the CC font has no box-drawing characters — only ASCII
and the 2x3 subpixel blocks at 128-159.

## Why the current UI resists polish

Four renderers exist: `app/ui.lua`, `app/monitor.lua`, `app/craft_monitor.lua`, `app/splash.lua`.
Each carries a private copy of clipped-write and row-fill, and three carry their own
`stateColor`. Any visual idea has to be implemented up to four times and drift between them is
invisible until someone looks at two screens side by side. `app/splash.lua` additionally has its
own 5-row block-glyph table that nothing else can reach.

Geometry is scattered the same way. `ui.lua` alone contains `bodyTop = 5`, `height - 4`,
`height - 3`, `summaryTop - 2`, `listBand(height)`, and `width >= 72`, each a separate decision
about the same grid. Pages disagree in ways that read as carelessness: the Search page has a
detail pane, a wide/narrow breakpoint and mouse hit regions; the Crafting page has none of
these, highlights with grey where Search highlights with red, and truncates its list instead of
scrolling it.

The palette is the clearest case. Eight of the sixteen colour slots are used — `red`, `white`,
`lightGray`, `black`, `gray`, `yellow`, `lime`, `orange` — and `red` alone does branding,
selection, section headings and errors. The other eight slots are untouched, so half the palette
can be claimed with no risk to anything that renders today.

## The palette

CC lets a program redefine the RGB behind each of the sixteen slots with `setPaletteColour`.
The brand is already fixed by `docs/assets/wordmark.svg`: crimson `#B91C2E`, coral `#FF5F5F`,
cool grey `#8A8F98`. The redefinition below builds outward from those three, separates brand
colour from selection colour from alert colour, and gives status its own ramp.

| Slot | Value | Role |
|---|---|---|
| `black` | `#0B0C10` | page ground |
| `gray` | `#1C1F26` | band and panel fill |
| `blue` | `#2A3441` | meter track |
| `lightGray` | `#8A8F98` | secondary text |
| `white` | `#E8E9EC` | primary text |
| `red` | `#B91C2E` | brand, chrome |
| `pink` | `#FF5F5F` | selection, focus |
| `orange` | `#E8833A` | in progress |
| `yellow` | `#E5B33A` | warning |
| `lime` | `#4FB477` | healthy, complete |
| `green` | `#2E7D52` | meter fill, dim |
| `lightBlue` | `#6FC3DE` | informational |
| `cyan` | `#3E9BB5` | informational, dim |
| `purple` | `#6E5AA8` | crafting |
| `magenta` | `#E0454F` | alert, failure |

`brown` is left at its default; nothing needs it and claiming a slot with no use for it only
makes a later decision harder.

`magenta` exists because brand and alert cannot be the same red. The header draws the wordmark
in brand crimson and an alert band may sit four rows below it; if both are `#B91C2E` the failure
does not separate from the chrome, which defeats the point of splitting the roles at all. Alert
is the brighter, higher-urgency red and is reserved for `ERROR`, `FAILED`, `OFFLINE` and
critical alert bands. Brand red never signals state.

Pages must never name a slot directly. They name a role — `theme.role.focus`, not `colors.pink` —
so that changing what selection looks like is one edit rather than a search across five files.

### The palette is terminal state, not program state

This is the part with teeth, and it is the reason the palette work is its own phase.
`setPaletteColour` mutates the surface, not the program. Three consequences:

**Restore on every exit.** If InvOS exits without restoring, the player's CraftOS shell keeps
InvOS colours until the computer reboots — a bug that looks like a corrupted computer rather
than a program that forgot to clean up. Restore belongs in `main.lua`'s existing `xpcall`
wrapper, and again in `startup.lua` after the supervisor loop exits, because the loop can be
broken by the operator during backoff.

**Apply per surface.** The terminal, the wall monitor and the craft monitor each hold their own
palette. A monitor bound after startup fires a `peripheral` event, which `Coordinator:handle`
already receives; that is where a late-attached monitor gets its palette.

**Degrade, never crash.** A non-advanced computer or monitor has no `setPaletteColour`. `apply`
returns false and every screen renders in stock colours, correctly if less handsomely.

## Modules

### `app/theme.lua`

Data plus two side-effecting functions.

- `Theme.slots` — the RGB table above, keyed by slot name.
- `Theme.role` — semantic name to slot: `ground`, `panel`, `track`, `muted`, `text`, `brand`,
  `focus`, `working`, `warn`, `ok`, `okDim`, `info`, `infoDim`, `craft`.
- `Theme.apply(surface)` / `Theme.restore(surface)` — returns false when the surface has no
  palette API.
- `Theme.statusColor(state)` — the single implementation of the mapping currently duplicated in
  `ui.lua`, `monitor.lua` and `craft_monitor.lua`.

### `app/draw.lua`

The shared vocabulary. Replaces four private copies of the same two functions.

- `Draw.text(surface, x, y, text, width, fg, bg)` — the clipped write. One implementation.
- `Draw.rightText(surface, endX, y, text, fg, bg)` — right-aligned, which currently appears as
  hand-computed `math.max(2, width - #text - 1)` in a dozen places.
- `Draw.centerText(surface, center, y, text, fg, bg)`
- `Draw.band(surface, y, bg, from, to)` — filled row or row segment.
- `Draw.divider(surface, x, top, bottom, bg)` — the vertical rule between list and detail pane.
- `Draw.meter(surface, x, y, cells, fraction, fill, track)` — horizontal bar, half-cell precision.
- `Draw.blockText(surface, x, y, text, color)` — 5-row block glyphs, digits and the letters the
  wordmark needs. `splash.lua`'s private table moves here and `splash.lua` calls this instead.

### `app/layout.lua`

`Layout.regions(width, height)` returns the named bands every page shares:

```
header  = 1                        nav    = 2
content = {top=3, bottom=<...>}    split  = <x> or nil
strip   = height-2 or nil          footer = height-1
status  = height
```

`content` is the band a page carves its own rows from; the shared chrome above and below it is
fixed so pages cannot disagree about it.

`split` is nil below 40 columns. This is **not** the 72-column breakpoint `ui.lua` uses today:
the approved mockup shows a detail pane on the 51-column terminal, so the pane has to appear far
earlier than the current wide layout does. 72 stays only as the point where the pane gets
generous rather than merely present.

`strip` is nil below 12 rows, and `content` claims the row back when it is absent — the bottom
meter strip is a luxury, and a screen that small needs its rows for content.

This replaces every magic row number in `ui.lua`, including `listBand`.

## What each screen becomes

**Search** keeps its structure and gains labelled bands, a stock meter in the detail pane, and
the bottom strip. **Crafting** changes most: it gains the scrolling its list currently lacks
(today a long recipe list is truncated and the selection can move off-screen), the same
selection colour as every other page, display names instead of raw item ids in the plan view,
and the detail pane. **Requests** and **Alerts** gain progress meters and severity colour that
is no longer the same red as the brand. **Nodes** gains a fill meter per node. **Setup** gains
step numbering in the header band and consistent choice highlighting.

**Wall monitor** is where the extra room pays: the stored-item count in block digits readable
across a base, per-node fill meters, an activity pane and an alert band, all in the same
vocabulary as the terminal rather than a second design. **Craft monitor** follows the same
grammar at its smaller size.

## Input

`monitor_touch` is `{name, side, x, y}` — the same x/y slots `mouse_click` uses — so wiring it
would be one line in `keymap.lua`. It is deliberately **not** wired.

The wall monitor renders a different layout from `monitor.lua`, so a touch there would be
matched against the terminal's hit regions and select whatever happened to be at those
coordinates. Making it real means a second region set and tracking which surface an event came
from, for the privilege of walking across a base to drive a search that the terminal drives
better. The wall monitor stays passive.

On the terminal, hit regions extend from the Search list to nav tabs, every list row, action
buttons, and the strip (clicking a chest level opens Nodes). `mouse_scroll` becomes page-aware
so it scrolls the list actually on screen.

## Half-cell meters, and the one thing that cannot be verified from the host

A meter drawn in whole cells quantises badly: at ten cells, 14% and 24% look identical. The
subpixel characters at 128-159 each encode a 2x3 grid, which buys horizontal half-cells.

The character is `128 + mask`. Character 149 (`128 + 21`, three stacked subpixels) is the
half-column.

**Checked in world on 2026-08-12, and the prediction was half wrong.** The index was right; the
colour roles were inverted. Character 149 paints its **foreground on the right half** of the
cell and its **background on the left**. The design had assumed the opposite.

So a meter cell is one of three things: filled (a space with the fill colour as background),
half (character 149 with the pair **inverted** — fill as background, track as foreground — so
that it fills from the left), or empty (a space with track as background).

This is the class of thing the host suite structurally cannot catch. A test pins which
character the module emits; nothing on the host knows which pixels CC lights up for it. The
glyph sheet that settled it took one deployment and one screenshot, and it is the reason phase
1 ends with a deployment rather than a green suite. `Draw.subpixel = false` remains as the
whole-cell fallback, but it was not needed.

## Testing

Every phase is test-first.

- **theme** — restore writes back exactly the CC defaults; `apply` on a surface with no
  `setPaletteColour` returns false and raises nothing; every role in `Theme.role` resolves to a
  real slot.
- **draw** — meter cell counts at 0, 25, 50, 75 and 100 percent, and that a half cell emits
  character 149; `blockText` renders known glyph patterns; every primitive clips at all four
  bounds rather than writing outside the surface.
- **pages** — the existing "never draws outside its surface" test, currently on the Crafting
  page only, extends to every page and both monitors at 51x19, 26x12 and 18x8.
- **hit regions** — a click at a nav tab's coordinates yields `OPEN_PAGE` for that page; a click
  on a row selects that index; a click on a button yields that button's command.

The suite is 602 tests today and must stay green at every step.

## Build order

1. **Foundation.** `theme`, `draw`, `layout`; header, footer and splash adopt them. Only colours
   change on screen. Deploy, and confirm the subpixel mapping in world.
2. **Terminal pages.** Search, Crafting, Requests, Alerts, Nodes, Setup rebuilt on the
   foundation. Crafting gains scrolling.
3. **Terminal input.** Hit regions for nav, rows and buttons; page-aware scroll.
4. **Monitors.** Wall monitor and craft monitor in the same vocabulary; block digits.

Each phase is independently deployable and independently useful, so the work can stop after any
of them without leaving the UI half-restyled.

## Constraints for whoever builds this

- **No behaviour changes.** If a diff touches `coordinator.lua`'s dispatch, `requests.lua`,
  `craft_service.lua`, or anything under `core/`, it has left this spec.
- **Host Lua is 5.4; CC runs 5.2.** A green suite does not prove CC compatibility.
- **Never name a colour slot in a page.** Name a role.
- **The palette must be restored on every exit path**, including the operator breaking the
  supervisor loop during backoff.
- The four private clipped-write implementations are deleted, not left beside the shared one.
  Two implementations of the same primitive is the state this spec exists to end.
