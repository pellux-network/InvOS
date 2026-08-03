# Colossal Storage UI Polish Design

## Scope

Polish the controller's resizable wall monitor and 51-column advanced-computer interface without changing storage, transfer, or recovery behavior.

## Wall monitor

The large monitor uses a black canvas. Background bands are reserved for full-width structural elements or critical alerts; ordinary labels always restore the black background before drawing. The title and lifecycle state occupy separate bounded regions.

The content area has two non-overlapping columns: Storage Nodes on the left and Current Activity on the right. Node labels clip at the left-column boundary, and node state is right-aligned inside that same column. Recent movement remains below the columns.

The bottom two rows are permanent physical markers. `DROP-OFF` is centered over the second fifth of the display and `PICKUP` over the fourth fifth, each with a downward arrow beneath it. Alerts render immediately above these markers so the physical labels remain visible.

Small and medium monitor layouts retain their responsive fallbacks and must never draw outside their current dimensions.

## Controller search page

At normal 51-column advanced-computer width, search results use the full content width. Names are left-aligned, quantities are right-aligned, and the selected row remains visually distinct. A compact summary below the list shows the selected display name, available quantity, and the Enter action. Internal item IDs are omitted from the default compact view.

A two-column list/detail layout is allowed only when the terminal is at least 72 columns wide. Narrow terminals retain the existing safe fallback.

## Number-tab input

Number keys 1 through 5 continue to switch pages. The printable character event emitted for the same physical keypress is consumed once, preventing a tab shortcut from entering a digit into Search. Later independently typed digits remain valid search characters.

## Verification

Tests cover the 5x3-class large monitor, non-overlapping node/activity columns, black ordinary text backgrounds, physical Drop-off/Pickup markers, compact 51-column search layout, wide-terminal fallback, resize bounds, and one-shot number-character suppression.
