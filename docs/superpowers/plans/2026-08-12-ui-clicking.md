# UI: clicking the terminal

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the controller terminal clickable — nav tabs, list rows on every page, and the
action buttons — and close the test gap that let two monitor sections silently vanish.

**Architecture:** `UI:render` already collects `hitRegions` and the coordinator already stores
them in `state.hit_regions`, where `keymap.hitCommand` matches a `mouse_click` against them.
Only Search and Crafting emit any. This extends emission to the nav bar, the remaining pages
and the buttons. No new command types: every region carries a command the reducer already
handles.

**Tech Stack:** Lua 5.2 target, tested on 5.4.

## Global Constraints

- **The wall monitor stays passive.** No `monitor_touch`, no regions on either monitor. It
  renders a different layout, so terminal regions would match the wrong coordinates.
- **Presentation only.** No diff may touch `coordinator.lua`, `requests.lua`, `craft_service.lua`
  or anything under `core/`.
- **Run tests from `controller/`:** `lua colossal/tests/run.lua`. Starts at 696 passing.
- **Rendering must not mutate state.** Regions are returned from render, never stored on it.
- **No new command types.** A region whose command the reducer does not handle is a dead click.
- Commit messages end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

### Task 1: Section coverage at every size

Two monitor sections vanished silently on short screens while the suite stayed green, because
the tests checked bounds and content presence but never "this section exists at this size".

**Files:**
- Test: `controller/colossal/tests/test_ui_sections.lua` (create)
- Modify: `controller/colossal/tests/run.lua`

- [ ] **Step 1: Write the test**

Create `controller/colossal/tests/test_ui_sections.lua`, asserting that each screen still shows
its defining sections at every size the tier covers. Register it after `tests.test_ui_pages`.

- [ ] **Step 2: Run it, fix whatever it finds, commit**

If it finds a section missing at a size, that is a real defect — fix the renderer, not the test.

---

### Task 2: Clickable nav and rows

**Files:**
- Modify: `controller/colossal/app/ui.lua`
- Test: `controller/colossal/tests/test_ui_click.lua` (create)
- Modify: `controller/colossal/tests/run.lua`

**Interfaces:**
- `UI:_nav(state, regions, hitRegions)` gains the region list.
- `UI:_requests`, `UI:_alerts`, `UI:_storage`, `UI:_setupWizard` gain a `hitRegions` argument.
- Every region is `{x1, y1, x2, y2, command=<existing command>}`.

- [ ] **Step 1: Write the failing test**

Create `controller/colossal/tests/test_ui_click.lua`. It renders a page, finds the region under
a coordinate the way `keymap` does, and asserts the command.

```lua
local UI = require("app.ui")
local Keymap = require("app.keymap")
local T = require("tests.mock_cc")

local function clickAt(state, layout, x, y)
    return Keymap.command({"mouse_click", 1, x, y},
        {mode=state.mode, page=state.page, hit_regions=layout.hit_regions})
end
```

Assert: clicking a nav tab yields `OPEN_PAGE` for that page; clicking a list row selects that
row; clicking the retrieve button yields `OPEN_QUANTITY`; clicking empty space yields nothing.

- [ ] **Step 2: Emit the regions**

In `UI:_nav`, add one region per tab covering its label, command
`{type="OPEN_PAGE", page=entry.page}`. Note there is deliberately **no** `suppress_char`: that
field exists to swallow the `char` event a digit key produces, and a mouse click produces none.

In `_requests`, `_alerts` and `_storage`, add a region per row selecting that index, using the
same `MOVE` delta shape the crafting list already uses. In `_setupWizard`, add a region per
choice with `{type="SETUP_SELECT"}` after moving the selection.

In `_search` and `_crafting`, add a region over the `ENTER RETRIEVE` / `ENTER CHOOSE` button
with `{type="OPEN_QUANTITY"}` and `{type="OPEN_CRAFT_QUANTITY"}`.

- [ ] **Step 3: Run the suite and commit**

---

### Task 3: Deploy

- [ ] Confirm both computers are shut down, explicitly, in the current conversation.
- [ ] `python tools/deploy.py --computers "G:/world/computercraft/computer"`.
- [ ] Boot and click: the nav tabs, a few rows, the retrieve button.

## After this

The visual system in `specs/2026-08-12-ui-visual-system-design.md` is complete. The branch has
never been merged and the repository has no remote configured.
