# UI visual foundation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the crafting list's missing scroll, then build the palette, drawing and layout
modules that every screen in `specs/2026-08-12-ui-visual-system-design.md` depends on.

**Architecture:** Three new modules under `controller/colossal/app/` — `theme.lua` (colour
slots and semantic roles), `draw.lua` (one clipped-write, bands, meters, block glyphs) and
`layout.lua` (named screen regions). The header, footer and splash adopt them so the foundation
is exercised by real screens rather than only by tests. The four private copies of
clipped-write in `ui.lua`, `monitor.lua`, `craft_monitor.lua` and `splash.lua` are deleted as
each renderer moves over.

**Tech Stack:** Lua. Host runs 5.4, CC:Tweaked runs 5.2 — write for 5.2. No dependencies. Tests
are plain Lua tables run by `colossal/tests/run.lua`.

## Global Constraints

- **Scope: presentation only.** No diff may touch `coordinator.lua`'s dispatch, `requests.lua`,
  `craft_service.lua`, or anything under `core/`. Touching them means the change has left the spec.
- **Run tests from `controller/`,** never from `colossal/`: `lua colossal/tests/run.lua`. The
  deployment and startup tests resolve paths relative to `controller/` and fail spuriously otherwise.
- **The suite is 602 passing, 0 failing** at the start of this plan and must be green at every commit.
- **Host Lua is 5.4; CC:Tweaked is 5.2.** No integer division `//`, no `goto`, no bitwise
  operators. A green host suite does not prove CC compatibility.
- **Pages name roles, never slots.** `theme.role.focus`, never `colors.pink`.
- **Every new module must be added to `controller/colossal/deployment_manifest.lua`.**
  `tests/test_deployment.lua` fails if a manifest path does not exist, and the deployment gate
  refuses to copy any file the manifest does not list.
- **Rendering must never mutate UI state.** `tests/test_ui_purity.lua` enforces this. Scroll
  offsets are computed at render time from `selection` and discarded; they are not written back.
- **Every new test module must be added to `defaultModules` in `colossal/tests/run.lua`,**
  or it silently never runs.
- Commit messages end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

### Task 1: Crafting list scrolling

The crafting recipe list and the craft jobs list both render from index 1 and `break` when they
hit the bottom of the screen. `state.craft_scroll` exists and is maintained by the reducer but
is never read by the renderer, so moving the selection past the last visible row makes it
disappear off the bottom with no way to see what is selected. The Search page already solves
this; this task applies the same solution.

**Files:**
- Modify: `controller/colossal/app/ui.lua:725-842` (`UI:_crafting`)
- Test: `controller/colossal/tests/test_craft_ui.lua`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing later tasks rely on. This task is independently deployable.

- [ ] **Step 1: Write the failing tests**

Add these two tests to `controller/colossal/tests/test_craft_ui.lua`, immediately before the
existing `"the crafting page never draws outside its surface"` entry:

```lua
    {name="a long recipe list scrolls to keep the selection visible",run=function()
        local results = {}
        for index = 1, 40 do
            results[index] = {item="minecraft:item"..index,
                display_name="Recipe "..index, quantity=index}
        end
        local surface = ui()
        surface:render(crafting({craft_results=results, craft_result_count=40,
            craft_selection=30}), {})
        local text = surface.surface.allText()
        T.contains(text, "Recipe 30", "the selected recipe must stay on screen")
        T.equal(text:find("Recipe 1 ", 1, true), nil,
            "the list must scroll rather than always starting at the top")
    end},
    {name="a long craft job list scrolls to keep the selection visible",run=function()
        local jobs = {}
        for index = 1, 40 do
            jobs[index] = {item="minecraft:item"..index,
                display_name="Job "..index, state="QUEUED"}
        end
        local surface = ui()
        surface:render(crafting({mode="craft_jobs", craft_jobs=jobs, craft_job_count=40,
            craft_job_selection=30}), {})
        local text = surface.surface.allText()
        T.contains(text, "Job 30", "the selected job must stay on screen")
        T.equal(text:find("Job 1 ", 1, true), nil,
            "the list must scroll rather than always starting at the top")
    end},
    {name="rendering a scrolled crafting list never mutates UI state",run=function()
        local results = {}
        for index = 1, 40 do
            results[index] = {item="minecraft:item"..index,
                display_name="Recipe "..index, quantity=index}
        end
        local state = crafting({craft_results=results, craft_result_count=40,
            craft_selection=30, craft_scroll=1})
        ui():render(state, {})
        T.equal(state.craft_scroll, 1, "render must not write a scroll offset back to state")
        T.equal(state.craft_selection, 30)
    end},
```

- [ ] **Step 2: Run the tests to verify they fail**

Run from `controller/`:

```bash
lua colossal/tests/run.lua tests.test_craft_ui
```

Expected: the first two FAIL (`expected Recipe 30 in ...` — the list renders Recipe 1 through
Recipe 13 and stops). The third PASSES already, because the current renderer never writes back;
it is there to keep that true once scrolling is added.

- [ ] **Step 3: Add a scroll helper and use it in both lists**

In `controller/colossal/app/ui.lua`, add this local function immediately above
`function UI:_crafting` (just below the existing `-- Crafting page.` comment block):

```lua
-- Where a list of `count` items must start so that `selection` is on screen, given `visible`
-- rows. Computed at render time and discarded: writing a scroll offset back into state during
-- a render would make rendering impure, which tests/test_ui_purity.lua forbids.
local function scrollFor(selection, count, visible)
    if visible < 1 then return 1 end
    local scroll = math.max(1, math.min(selection or 1, math.max(1, (count or 0) - visible + 1)))
    if (selection or 1) < scroll then scroll = selection end
    if (selection or 1) >= scroll + visible then scroll = selection - visible + 1 end
    return math.max(1, scroll)
end
```

In the `craft_jobs` branch, replace:

```lua
        local row = 4
        for index, job in ipairs(state.craft_jobs or {}) do
            if row > bottom then break end
```

with:

```lua
        local row = 4
        local jobs = state.craft_jobs or {}
        local scroll = scrollFor(state.craft_job_selection or 1, #jobs, bottom - 4 + 1)
        for offset = 0, bottom - 4 do
            local index = scroll + offset
            local job = jobs[index]
            if not job then break end
```

The loop body is unchanged except that `job` and `index` now come from the two lines above
rather than from `ipairs`. The `if row > bottom then break end` line inside the body is now
redundant and must be deleted; the `for offset` bound already stops at the bottom.

In the recipe list at the end of the function, replace:

```lua
    local row = 4
    for index, entry in ipairs(state.craft_results or {}) do
        if row > bottom then break end
```

with:

```lua
    local row = 4
    local results = state.craft_results or {}
    local scroll = scrollFor(state.craft_selection or 1, #results, bottom - 4 + 1)
    for offset = 0, bottom - 4 do
        local index = scroll + offset
        local entry = results[index]
        if not entry then break end
```

Again delete the now-redundant `if row > bottom then break end` from the body.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
lua colossal/tests/run.lua tests.test_craft_ui
```

Expected: PASS, all tests in the module.

- [ ] **Step 5: Run the whole suite**

```bash
lua colossal/tests/run.lua
```

Expected: `RESULT 605 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add controller/colossal/app/ui.lua controller/colossal/tests/test_craft_ui.lua
git commit -m "fix: scroll the crafting lists so the selection stays on screen

Both crafting lists rendered from index 1 and stopped at the bottom of
the screen, so moving the selection past the last visible row made it
vanish with no way to see what was selected. state.craft_scroll existed
and was maintained by the reducer but no renderer ever read it.

The offset is computed at render time and discarded rather than written
back, because test_ui_purity forbids a render that mutates state.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `app/theme.lua`

**Files:**
- Create: `controller/colossal/app/theme.lua`
- Modify: `controller/colossal/deployment_manifest.lua`
- Modify: `controller/colossal/tests/run.lua`
- Test: `controller/colossal/tests/test_theme.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Theme.slots` — table, slot name string to 24-bit integer.
  - `Theme.defaults` — table, all sixteen CC stock values, same shape.
  - `Theme.palette` — table, slot name to CC colour value. This is exported specifically so
    tests can resolve slot names **without** the `colors` global, which does not exist on the
    host: only `test_craft_ui.lua` defines a CC global, and it defines `keys`, not `colors`.
  - `Theme.role` — table of semantic name to CC colour value: `ground`, `panel`, `track`,
    `muted`, `text`, `brand`, `focus`, `working`, `warn`, `ok`, `okDim`, `info`, `infoDim`,
    `craft`, `alert`.
  - `Theme.apply(surface) -> boolean`
  - `Theme.restore(surface) -> boolean`
  - `Theme.statusColor(state) -> colour value`

- [ ] **Step 1: Write the failing test**

Create `controller/colossal/tests/test_theme.lua`:

```lua
local Theme = require("app.theme")
local T = require("tests.mock_cc")

-- A surface that records palette writes. mock_cc's recordingSurface has no palette API,
-- which is deliberately also the case this module must survive.
local function paletteSurface()
    local writes = {}
    return {
        getSize = function() return 51, 19 end,
        setPaletteColour = function(slot, value) writes[slot] = value end,
        writes = writes,
    }
end

return {
    { name = "every role resolves to a real colour slot", run = function()
        -- Theme.palette, not the `colors` global: the host test environment has no CC
        -- globals at all beyond the `keys` table test_craft_ui defines for itself.
        local slots = {}
        for _, value in pairs(Theme.palette) do slots[value] = true end
        local count = 0
        for name, value in pairs(Theme.role) do
            T.equal(type(value), "number", name .. " must be a colour value")
            T.equal(slots[value], true, name .. " must be one of the sixteen CC slots")
            count = count + 1
        end
        T.equal(count, 15, "a role added without a test is a role nothing checks")
    end },
    { name = "brand and alert are different reds", run = function()
        T.equal(Theme.role.brand ~= Theme.role.alert, true,
            "an alert that is the same colour as the chrome does not read as an alert")
    end },
    { name = "apply writes every InvOS slot value", run = function()
        local surface = paletteSurface()
        T.equal(Theme.apply(surface), true)
        for name, value in pairs(Theme.slots) do
            T.equal(surface.writes[Theme.palette[name]], value, name .. " was not applied")
        end
    end },
    { name = "restore puts back the CC defaults exactly", run = function()
        local surface = paletteSurface()
        Theme.apply(surface)
        T.equal(Theme.restore(surface), true)
        for name, value in pairs(Theme.defaults) do
            T.equal(surface.writes[Theme.palette[name]], value, name .. " was not restored")
        end
    end },
    { name = "restore covers every slot apply touches", run = function()
        for name in pairs(Theme.slots) do
            T.equal(Theme.defaults[name] ~= nil, true,
                name .. " is applied but has no default to restore, so it would stay changed")
        end
    end },
    { name = "a surface with no palette API is refused, not crashed on", run = function()
        T.equal(Theme.apply(T.recordingSurface(51, 19)), false)
        T.equal(Theme.restore(T.recordingSurface(51, 19)), false)
        T.equal(Theme.apply(nil), false)
    end },
    { name = "status colours separate healthy, degraded and failed", run = function()
        T.equal(Theme.statusColor("READY"), Theme.role.ok)
        T.equal(Theme.statusColor("COMPLETE"), Theme.role.ok)
        T.equal(Theme.statusColor("DEGRADED"), Theme.role.warn)
        T.equal(Theme.statusColor("BLOCKED"), Theme.role.warn)
        T.equal(Theme.statusColor("PARTIAL"), Theme.role.warn)
        T.equal(Theme.statusColor("ERROR"), Theme.role.alert)
        T.equal(Theme.statusColor("FAILED"), Theme.role.alert)
        T.equal(Theme.statusColor("OFFLINE"), Theme.role.alert)
        T.equal(Theme.statusColor("TRANSFERRING"), Theme.role.working)
        T.equal(Theme.statusColor(nil), Theme.role.working)
    end },
}
```

- [ ] **Step 2: Register the test module**

In `controller/colossal/tests/run.lua`, add `"tests.test_theme",` to `defaultModules`
immediately after `"tests.test_lifecycle",`.

- [ ] **Step 3: Run the test to verify it fails**

```bash
lua colossal/tests/run.lua tests.test_theme
```

Expected: `FAIL tests.test_theme load: module 'app.theme' not found`.

- [ ] **Step 4: Write the implementation**

Create `controller/colossal/app/theme.lua`:

```lua
local M = {}

-- CC exposes `colors` as a global; the fallback keeps this module loadable on the host, where
-- the tests run with no CC environment at all. Exported as M.palette because tests need to
-- resolve a slot name to a value and cannot reach the global to do it.
local palette = colors or {
    white=1, orange=2, magenta=4, lightBlue=8, yellow=16, lime=32,
    pink=64, gray=128, lightGray=256, cyan=512, purple=1024, blue=2048,
    brown=4096, green=8192, red=16384, black=32768,
}
M.palette = palette

-- What InvOS installs over the stock palette. Built outward from the three wordmark colours
-- in docs/assets/wordmark.svg: crimson #B91C2E, coral #FF5F5F, cool grey #8A8F98.
-- `brown` is deliberately absent: nothing needs it, and claiming a slot with no use for it
-- only makes a later decision harder.
M.slots = {
    black     = 0x0B0C10,
    gray      = 0x1C1F26,
    blue      = 0x2A3441,
    lightGray = 0x8A8F98,
    white     = 0xE8E9EC,
    red       = 0xB91C2E,
    pink      = 0xFF5F5F,
    orange    = 0xE8833A,
    yellow    = 0xE5B33A,
    lime      = 0x4FB477,
    green     = 0x2E7D52,
    lightBlue = 0x6FC3DE,
    cyan      = 0x3E9BB5,
    purple    = 0x6E5AA8,
    magenta   = 0xE0454F,
}

-- The stock CC:Tweaked values. Restoring is not optional: setPaletteColour changes the
-- terminal, not the program, so an InvOS that exits without putting these back leaves the
-- player's shell in InvOS colours until the computer reboots.
M.defaults = {
    white=0xF0F0F0, orange=0xF2B233, magenta=0xE57FD8, lightBlue=0x99B2F2,
    yellow=0xDEDE6C, lime=0x7FCC19, pink=0xF2B2CC, gray=0x4C4C4C,
    lightGray=0x999999, cyan=0x4C99B2, purple=0xB266E5, blue=0x3366CC,
    brown=0x7F664C, green=0x57A64E, red=0xCC4C4C, black=0x111111,
}

-- Screens name a role, never a slot, so that changing what selection looks like is one edit
-- here rather than a search across five renderers.
M.role = {
    ground  = palette.black,
    panel   = palette.gray,
    track   = palette.blue,
    muted   = palette.lightGray,
    text    = palette.white,
    brand   = palette.red,
    focus   = palette.pink,
    working = palette.orange,
    warn    = palette.yellow,
    ok      = palette.lime,
    okDim   = palette.green,
    info    = palette.lightBlue,
    infoDim = palette.cyan,
    craft   = palette.purple,
    alert   = palette.magenta,
}

-- CC spells this both ways depending on version; a monitor that has neither is a basic
-- monitor, which has no palette at all and must render in stock colours rather than error.
local function writeAll(surface, values)
    if type(surface) ~= "table" then return false end
    local set = surface.setPaletteColour or surface.setPaletteColor
    if type(set) ~= "function" then return false end
    for name, value in pairs(values) do
        local slot = palette[name]
        if slot then pcall(set, slot, value) end
    end
    return true
end

function M.apply(surface) return writeAll(surface, M.slots) end
function M.restore(surface) return writeAll(surface, M.defaults) end

-- The single implementation of a mapping that exists three times today, in ui.lua,
-- monitor.lua and craft_monitor.lua. Failure uses `alert`, never `brand`: brand red is
-- chrome and must never signal state.
function M.statusColor(state)
    if state == "READY" or state == "COMPLETE" then return M.role.ok end
    if state == "DEGRADED" or state == "BLOCKED" or state == "PARTIAL" then return M.role.warn end
    if state == "ERROR" or state == "FAILED" or state == "OFFLINE" then return M.role.alert end
    return M.role.working
end

return M
```

- [ ] **Step 5: Add the module to the deployment manifest**

In `controller/colossal/deployment_manifest.lua`, add `"colossal/app/theme.lua",` to the
`files` list, keeping the existing alphabetical-ish grouping of `colossal/app/` entries.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
lua colossal/tests/run.lua
```

Expected: `RESULT 612 passed, 0 failed`. `tests.test_deployment` must stay green — it fails if
the manifest lists a file that does not exist.

- [ ] **Step 7: Commit**

```bash
git add controller/colossal/app/theme.lua controller/colossal/tests/test_theme.lua \
        controller/colossal/tests/run.lua controller/colossal/deployment_manifest.lua
git commit -m "feat: add the InvOS palette and semantic colour roles

Eight of the sixteen CC slots were used and red alone did branding,
selection, headings and errors. This claims seven more slots and gives
each role its own colour, including a separate alert red so a failure
does not render in the same colour as the chrome above it.

Nothing renders through this yet; adoption follows.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: `app/draw.lua`

**Files:**
- Create: `controller/colossal/app/draw.lua`
- Modify: `controller/colossal/deployment_manifest.lua`
- Modify: `controller/colossal/tests/run.lua`
- Test: `controller/colossal/tests/test_draw.lua`

**Interfaces:**
- Consumes: nothing. `draw.lua` must not require `theme.lua` — callers pass colours in, which
  keeps the drawing primitives testable without a palette.
- Produces:
  - `Draw.text(surface, x, y, text, width, fg, bg)`
  - `Draw.rightText(surface, endX, y, text, fg, bg)`
  - `Draw.centerText(surface, center, y, text, fg, bg)`
  - `Draw.band(surface, y, bg, from, to)`
  - `Draw.divider(surface, x, top, bottom, bg)`
  - `Draw.meter(surface, x, y, cells, fraction, fill, track)`
  - `Draw.blockText(surface, x, y, text, color) -> next x`
  - `Draw.glyphs` — table, character to five 5-wide pattern strings.
  - `Draw.subpixel` — boolean, default true. Set false to fall back to whole-cell meters.
  - `Draw.HALF` — number, 149. The left-half-column subpixel character.

- [ ] **Step 1: Write the failing test**

Create `controller/colossal/tests/test_draw.lua`:

```lua
local Draw = require("app.draw")
local T = require("tests.mock_cc")

local function surfaceOf(width, height) return T.recordingSurface(width, height) end

-- How many cells of row `y` carry `color` as their background.
local function filled(surface, y, color, width)
    local count = 0
    for x = 1, width do
        if surface.backgroundAt(x, y) == color then count = count + 1 end
    end
    return count
end

local FILL, TRACK = 32, 2048

return {
    { name = "text clips at every edge instead of writing outside the surface", run = function()
        local surface = surfaceOf(10, 4)
        Draw.text(surface, 8, 2, "overlong", 20)
        Draw.text(surface, -3, 3, "negative start", 20)
        Draw.text(surface, 1, 99, "below", 10)
        Draw.text(surface, 1, -1, "above", 10)
        Draw.text(surface, 99, 1, "right", 10)
        T.equal(surface.writesOutsideBounds(), 0)
        T.equal(surface.line(2), "       ove")
    end },
    { name = "rightText ends on the column it is given", run = function()
        local surface = surfaceOf(20, 3)
        Draw.rightText(surface, 19, 1, "1,284")
        T.equal(surface.line(1), "              1,284 ")
    end },
    { name = "centerText centres on the column it is given", run = function()
        local surface = surfaceOf(21, 3)
        Draw.centerText(surface, 11, 1, "INVOS")
        -- 5 characters centred on column 11 occupy 9 through 13. monitor.lua's existing
        -- helper floors to 8 and sits one column left of centre; this one rounds.
        T.equal(surface.line(1):find("INVOS", 1, true), 9)
    end },
    { name = "band fills a whole row, or the segment it is given", run = function()
        local surface = surfaceOf(12, 3)
        Draw.band(surface, 1, FILL)
        T.equal(filled(surface, 1, FILL, 12), 12)
        Draw.band(surface, 2, FILL, 4, 6)
        T.equal(filled(surface, 2, FILL, 12), 3)
    end },
    { name = "band and divider refuse rows and columns outside the surface", run = function()
        local surface = surfaceOf(12, 3)
        Draw.band(surface, 0, FILL)
        Draw.band(surface, 9, FILL)
        Draw.band(surface, 1, FILL, 10, 40)
        Draw.divider(surface, 6, 1, 99, FILL)
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "a meter fills whole cells in proportion to its fraction", run = function()
        local surface = surfaceOf(20, 6)
        Draw.meter(surface, 1, 1, 10, 0, FILL, TRACK)
        T.equal(filled(surface, 1, FILL, 20), 0)
        Draw.meter(surface, 1, 2, 10, 0.5, FILL, TRACK)
        T.equal(filled(surface, 1, FILL, 20), 5)
        Draw.meter(surface, 1, 3, 10, 1, FILL, TRACK)
        T.equal(filled(surface, 1, FILL, 20), 10)
        T.equal(filled(surface, 1, TRACK, 20), 0)
    end },
    { name = "a meter clamps a fraction outside zero to one", run = function()
        local surface = surfaceOf(20, 4)
        Draw.meter(surface, 1, 1, 10, -3, FILL, TRACK)
        T.equal(filled(surface, 1, FILL, 20), 0)
        Draw.meter(surface, 1, 2, 10, 7, FILL, TRACK)
        T.equal(filled(surface, 1, FILL, 20), 10)
        Draw.meter(surface, 1, 3, 10, nil, FILL, TRACK)
        T.equal(filled(surface, 1, FILL, 20), 0)
    end },
    { name = "a half-full cell is drawn with the left-half subpixel character", run = function()
        local surface = surfaceOf(20, 3)
        Draw.meter(surface, 1, 1, 10, 0.55, FILL, TRACK)
        T.equal(filled(surface, 1, FILL, 20), 5, "five whole cells, then a half")
        T.equal(surface.line(1):sub(6, 6), string.char(Draw.HALF))
    end },
    { name = "subpixel off rounds to whole cells and draws no partial character", run = function()
        local surface = surfaceOf(20, 3)
        Draw.subpixel = false
        Draw.meter(surface, 1, 1, 10, 0.55, FILL, TRACK)
        Draw.subpixel = true
        T.equal(filled(surface, 1, FILL, 20), 6, "0.55 rounds up to six whole cells")
        T.equal(surface.line(1):find(string.char(Draw.HALF), 1, true), nil)
    end },
    { name = "a meter never draws outside the surface", run = function()
        local surface = surfaceOf(8, 3)
        Draw.meter(surface, 5, 1, 20, 0.75, FILL, TRACK)
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "blockText draws five-row glyphs and reports where it ended", run = function()
        local surface = surfaceOf(30, 7)
        local nextX = Draw.blockText(surface, 1, 1, "10", FILL)
        T.equal(nextX, 13, "two glyphs, each five wide with a one-column gap")
        T.equal(filled(surface, 3, FILL, 30) > 0, true)
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "blockText covers every digit and the wordmark letters", run = function()
        for character in ("0123456789,INVOS"):gmatch(".") do
            T.equal(Draw.glyphs[character] ~= nil, true, "no glyph for " .. character)
            T.equal(#Draw.glyphs[character], 5, character .. " must have five rows")
            for _, row in ipairs(Draw.glyphs[character]) do
                T.equal(#row, 5, character .. " rows must be five columns wide")
            end
        end
    end },
    { name = "blockText clips rather than drawing past the edge", run = function()
        local surface = surfaceOf(8, 4)
        Draw.blockText(surface, 6, 3, "148,302", FILL)
        T.equal(surface.writesOutsideBounds(), 0)
    end },
}
```

- [ ] **Step 2: Register the test module**

In `controller/colossal/tests/run.lua`, add `"tests.test_draw",` immediately after
`"tests.test_theme",`.

- [ ] **Step 3: Run the test to verify it fails**

```bash
lua colossal/tests/run.lua tests.test_draw
```

Expected: `FAIL tests.test_draw load: module 'app.draw' not found`.

- [ ] **Step 4: Write the implementation**

Create `controller/colossal/app/draw.lua`:

```lua
local M = {}

-- The 2x3 subpixel characters live at 128-159. The index is 128 + a five-bit mask whose bits
-- are, in order, top-left, top-right, middle-left, middle-right, bottom-left; the sixth
-- subpixel is expressed by setting the complement of the other five and swapping the
-- foreground with the background. A left half-column is therefore bits 0, 2 and 4:
-- 1 + 4 + 16 = 21, so 128 + 21 = 149.
--
-- That bit order cannot be proven from the host suite. The test below pins the behaviour
-- against regression but cannot prove 149 is what CC draws; that is confirmed in world by
-- the glyph sheet in Task 6. If it is wrong, set M.subpixel = false and every meter falls
-- back to whole cells with no other change.
M.HALF = 149
M.subpixel = true

-- One clipped write, replacing the four private copies in ui.lua, monitor.lua,
-- craft_monitor.lua and splash.lua. Colours are optional so a caller that has already set
-- them does not pay to set them again.
function M.text(surface, x, y, text, width, fg, bg)
    local surfaceWidth, surfaceHeight = surface.getSize()
    width = width or 0
    if y < 1 or y > surfaceHeight or x > surfaceWidth or width <= 0 then return end
    text = tostring(text or "")
    if x < 1 then
        local remove = 1 - x
        text = text:sub(remove + 1)
        width, x = width - remove, 1
    end
    if width <= 0 then return end
    text = text:sub(1, math.min(width, surfaceWidth - x + 1))
    if #text == 0 then return end
    if bg then surface.setBackgroundColor(bg) end
    if fg then surface.setTextColor(fg) end
    surface.setCursorPos(x, y)
    surface.write(text)
end

function M.rightText(surface, endX, y, text, fg, bg)
    text = tostring(text or "")
    M.text(surface, endX - #text + 1, y, text, #text, fg, bg)
end

-- Rounds rather than floors. monitor.lua's existing centring helper floors, which puts odd-
-- length text one column left of the centre it was given.
function M.centerText(surface, center, y, text, fg, bg)
    text = tostring(text or "")
    M.text(surface, math.floor(center - #text / 2 + 0.5), y, text, #text, fg, bg)
end

-- A filled row, or a segment of one. This is how InvOS draws every solid shape: the CC font
-- has no box-drawing characters, so structure is background colour or it is nothing.
function M.band(surface, y, bg, from, to)
    local surfaceWidth, surfaceHeight = surface.getSize()
    if y < 1 or y > surfaceHeight then return end
    from = math.max(1, from or 1)
    to = math.min(surfaceWidth, to or surfaceWidth)
    if to < from then return end
    surface.setBackgroundColor(bg)
    surface.setCursorPos(from, y)
    surface.write(string.rep(" ", to - from + 1))
end

function M.divider(surface, x, top, bottom, bg)
    for y = top, bottom do M.band(surface, y, bg, x, x) end
end

-- A horizontal bar of `cells` columns. With subpixel drawing on, the cell where the fill ends
-- can be half filled, which doubles the resolution: at ten cells the difference between 14%
-- and 24% stops being invisible.
function M.meter(surface, x, y, cells, fraction, fill, track)
    fraction = math.max(0, math.min(1, tonumber(fraction) or 0))
    local halves
    if M.subpixel then
        halves = math.floor(fraction * cells * 2 + 0.5)
    else
        halves = math.floor(fraction * cells + 0.5) * 2
    end
    local whole = math.floor(halves / 2)
    local partial = halves % 2 == 1
    for index = 0, cells - 1 do
        local cellX = x + index
        if index < whole then
            M.band(surface, y, fill, cellX, cellX)
        elseif index == whole and partial then
            M.text(surface, cellX, y, string.char(M.HALF), 1, fill, track)
        else
            M.band(surface, y, track, cellX, cellX)
        end
    end
end

-- Five-row block glyphs. The letters were splash.lua's private table; the digits and comma are
-- new, for the wall monitor's item count.
M.glyphs = {
    ["0"] = {" ### ", "#   #", "#   #", "#   #", " ### "},
    ["1"] = {"  #  ", " ##  ", "  #  ", "  #  ", " ### "},
    ["2"] = {" ### ", "#   #", "   # ", "  #  ", "#####"},
    ["3"] = {"#### ", "    #", " ### ", "    #", "#### "},
    ["4"] = {"#  # ", "#  # ", "#####", "   # ", "   # "},
    ["5"] = {"#####", "#    ", "#### ", "    #", "#### "},
    ["6"] = {" ### ", "#    ", "#### ", "#   #", " ### "},
    ["7"] = {"#####", "    #", "   # ", "  #  ", "  #  "},
    ["8"] = {" ### ", "#   #", " ### ", "#   #", " ### "},
    ["9"] = {" ### ", "#   #", " ####", "    #", " ### "},
    [","] = {"     ", "     ", "     ", "  #  ", " #   "},
    ["I"] = {"#####", "  #  ", "  #  ", "  #  ", "#####"},
    ["N"] = {"#   #", "##  #", "# # #", "#  ##", "#   #"},
    ["V"] = {"#   #", "#   #", "#   #", " # # ", "  #  "},
    ["O"] = {" ### ", "#   #", "#   #", "#   #", " ### "},
    ["S"] = {" ####", "#    ", " ### ", "    #", "#### "},
}

-- Returns the column after the text, so a caller can place something beside it without
-- recomputing the width. An unknown character advances three columns as a word space.
function M.blockText(surface, x, y, text, color)
    local cursor = x
    text = tostring(text or "")
    for index = 1, #text do
        local glyph = M.glyphs[text:sub(index, index)]
        if glyph then
            for row = 1, #glyph do
                local line = glyph[row]
                for column = 1, #line do
                    if line:sub(column, column) == "#" then
                        M.band(surface, y + row - 1, color,
                            cursor + column - 1, cursor + column - 1)
                    end
                end
            end
            cursor = cursor + #glyph[1] + 1
        else
            cursor = cursor + 3
        end
    end
    return cursor
end

return M
```

- [ ] **Step 5: Add the module to the deployment manifest**

In `controller/colossal/deployment_manifest.lua`, add `"colossal/app/draw.lua",` to the
`files` list beside the other `colossal/app/` entries.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
lua colossal/tests/run.lua
```

Expected: `RESULT 625 passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add controller/colossal/app/draw.lua controller/colossal/tests/test_draw.lua \
        controller/colossal/tests/run.lua controller/colossal/deployment_manifest.lua
git commit -m "feat: add shared drawing primitives

One clipped write, bands, meters and block glyphs, to replace the four
private copies of the same two functions in ui, monitor, craft_monitor
and splash.

Meters use the left-half subpixel character for the cell where the fill
ends, which doubles their resolution. The bit order behind that
character cannot be proven from the host suite, so Draw.subpixel turns
it off in one edit if the in-world check disagrees.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `app/layout.lua`

**Files:**
- Create: `controller/colossal/app/layout.lua`
- Modify: `controller/colossal/deployment_manifest.lua`
- Modify: `controller/colossal/tests/run.lua`
- Test: `controller/colossal/tests/test_layout.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Layout.SPLIT_MIN` — number, 40.
  - `Layout.WIDE` — number, 72.
  - `Layout.STRIP_MIN_HEIGHT` — number, 12.
  - `Layout.regions(width, height) -> table` with keys `width`, `height`, `wide`, `header`,
    `nav`, `content` (a table of `top` and `bottom`), `split`, `strip`, `footer`, `status`.

- [ ] **Step 1: Write the failing test**

Create `controller/colossal/tests/test_layout.lua`:

```lua
local Layout = require("app.layout")
local T = require("tests.mock_cc")

return {
    { name = "the standard terminal gets every region", run = function()
        local regions = Layout.regions(51, 19)
        T.equal(regions.header, 1)
        T.equal(regions.nav, 2)
        T.equal(regions.content.top, 3)
        T.equal(regions.content.bottom, 16)
        T.equal(regions.strip, 17)
        T.equal(regions.footer, 18)
        T.equal(regions.status, 19)
    end },
    { name = "regions never overlap and never leave a gap", run = function()
        for _, size in ipairs({{51,19},{79,24},{26,12},{18,8},{40,10}}) do
            local regions = Layout.regions(size[1], size[2])
            local label = size[1] .. "x" .. size[2]
            T.equal(regions.content.top > regions.nav, true, label .. " content overlaps nav")
            local below = regions.strip or regions.footer
            T.equal(regions.content.bottom, below - 1, label .. " leaves a gap or overlaps")
            T.equal(regions.footer, regions.status - 1, label .. " footer overlaps status")
            T.equal(regions.status, size[2], label .. " status is not the last row")
        end
    end },
    { name = "the detail pane appears at 40 columns, not at 72", run = function()
        T.equal(Layout.regions(39, 19).split, nil)
        T.equal(Layout.regions(51, 19).split ~= nil, true,
            "the approved design shows a detail pane on the 51-column terminal")
        T.equal(Layout.regions(51, 19).split < 51, true)
    end },
    { name = "wide is a separate, larger threshold than the pane", run = function()
        T.equal(Layout.regions(51, 19).wide, false)
        T.equal(Layout.regions(79, 24).wide, true)
    end },
    { name = "a short screen drops the strip and gives the row back to content", run = function()
        local short = Layout.regions(51, 8)
        T.equal(short.strip, nil, "a screen this small needs its rows for content")
        T.equal(short.content.bottom, 6)
        T.equal(short.footer, 7)
        T.equal(short.status, 8)
    end },
    { name = "content is never inverted, even on an absurd screen", run = function()
        for _, size in ipairs({{51,6},{10,5},{8,4}}) do
            local regions = Layout.regions(size[1], size[2])
            T.equal(regions.content.bottom >= regions.content.top - 1, true,
                size[1] .. "x" .. size[2] .. " produced an inverted content band")
        end
    end },
}
```

- [ ] **Step 2: Register the test module**

In `controller/colossal/tests/run.lua`, add `"tests.test_layout",` immediately after
`"tests.test_draw",`.

- [ ] **Step 3: Run the test to verify it fails**

```bash
lua colossal/tests/run.lua tests.test_layout
```

Expected: `FAIL tests.test_layout load: module 'app.layout' not found`.

- [ ] **Step 4: Write the implementation**

Create `controller/colossal/app/layout.lua`:

```lua
local M = {}

-- The detail pane appears far earlier than the old wide layout did: the approved design shows
-- one on the 51-column terminal, so 72 no longer gates whether the pane exists, only whether
-- it is generous.
M.SPLIT_MIN = 40
M.WIDE = 72

-- Below this the bottom meter strip is dropped. It is a luxury, and a screen this small needs
-- its rows for content.
M.STRIP_MIN_HEIGHT = 12

-- One description of the screen that every page and both monitors share, so pages cannot
-- disagree about where the chrome is. `content` is the band a page carves its own rows from.
function M.regions(width, height)
    local strip = height >= M.STRIP_MIN_HEIGHT and (height - 2) or nil
    local footer = height - 1
    local contentBottom = (strip or footer) - 1
    return {
        width = width,
        height = height,
        wide = width >= M.WIDE,
        header = 1,
        nav = 2,
        content = { top = 3, bottom = math.max(2, contentBottom) },
        split = width >= M.SPLIT_MIN and math.floor(width * 0.57) or nil,
        strip = strip,
        footer = footer,
        status = height,
    }
end

return M
```

- [ ] **Step 5: Add the module to the deployment manifest**

In `controller/colossal/deployment_manifest.lua`, add `"colossal/app/layout.lua",` beside the
other `colossal/app/` entries.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
lua colossal/tests/run.lua
```

Expected: `RESULT 631 passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add controller/colossal/app/layout.lua controller/colossal/tests/test_layout.lua \
        controller/colossal/tests/run.lua controller/colossal/deployment_manifest.lua
git commit -m "feat: add one shared description of the screen regions

ui.lua contained bodyTop=5, height-4, height-3, summaryTop-2, listBand
and width>=72, each a separate decision about the same grid, which is
why the pages disagree with each other. This is the single description
they will all read from.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Adopt the foundation in the splash, the header and the footer

This is where the foundation stops being theoretical. The splash moves onto `Draw`, losing its
private glyph table; the header and footer move onto `Theme` and `Layout` and gain the active
nav tab; and the palette gets applied and — critically — restored.

**Files:**
- Modify: `controller/colossal/app/splash.lua`
- Modify: `controller/colossal/app/ui.lua` (`UI:_header`, `UI:_footer`, `navigationBar`)
- Modify: `controller/colossal/main.lua:288-297,400-411`
- Modify: `controller/startup.lua`
- Test: `controller/colossal/tests/test_splash.lua`, `controller/colossal/tests/test_ui.lua`,
  `controller/colossal/tests/test_theme.lua`

**Interfaces:**
- Consumes: `Theme.apply`, `Theme.restore`, `Theme.role`, `Draw.blockText`, `Draw.band`,
  `Draw.text`, `Draw.centerText`, `Layout.regions`.
- Produces: nothing later tasks in this plan rely on. Phase 2 will build pages on the same
  three modules.

- [ ] **Step 1: Write the failing tests**

Add to `controller/colossal/tests/test_ui.lua`, at the end of the returned table:

```lua
    { name = "the active page is marked in the navigation bar", run = function()
        local Theme=require("app.theme")
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        ui:render(UI.initialState(),{lifecycle="READY"})
        local function markedCells()
            local count=0
            for x=1,51 do
                if surface.backgroundAt(x,2)==Theme.role.focus then count=count+1 end
            end
            return count
        end
        T.truthy(markedCells()>0,
            "the page you are on must be distinguishable from the five you are not")
        T.truthy(markedCells()<20,"only the active tab should be filled, not the whole bar")
        local onCrafting=UI.new(surface):reduce(UI.initialState(),
            {type="OPEN_PAGE",page="crafting"})
        surface.clear()
        ui:render(onCrafting,{lifecycle="READY"})
        T.truthy(surface.line(2):find("CRAFT",1,true)~=nil,"crafting must still be listed")
    end },
    { name = "the navigation bar still lists every page after restyling", run = function()
        local ui=UI.new(T.recordingSurface(80,19))
        ui:render(UI.initialState(),{lifecycle="READY"})
        local nav=ui.surface.line(2)
        for _,label in ipairs({"SEARCH","NODES","REQUESTS","ALERTS","SETUP","CRAFTING"}) do
            T.contains(nav,label)
        end
    end },
```

In `controller/colossal/tests/test_splash.lua`, the existing test
`"the wordmark is drawn on a full-size terminal"` asserts `T.contains(text, "#####")`. That
passes today only because the splash writes its glyph patterns as literal `#` characters.
`Draw.blockText` paints background cells instead, which is why the wordmark will look solid
rather than hatched — so this assertion must change, not be worked around. Replace the line:

```lua
        T.contains(text, "#####")
```

with:

```lua
        local painted = 0
        for y = 1, 19 do
            for x = 1, 51 do
                if surface.backgroundAt(x, y) == Theme.role.brand then painted = painted + 1 end
            end
        end
        T.truthy(painted > 40, "expected a wordmark painted in brand colour, got " .. painted)
```

and add `local Theme = require("app.theme")` to the top of the file.

Then add this new test at the end of the returned table:

```lua
    {name="the splash reveals the wordmark progressively",run=function()
        local widths = {}
        local surface = T.recordingSurface(51, 19)
        local Theme = require("app.theme")
        local frames = 0
        Splash.play(surface, function()
            frames = frames + 1
            local rightmost = 0
            for y = 1, 19 do
                for x = 1, 51 do
                    if surface.backgroundAt(x, y) == Theme.role.brand and x > rightmost then
                        rightmost = x
                    end
                end
            end
            widths[#widths + 1] = rightmost
        end)
        T.truthy(frames > 1, "expected more than one frame")
        local grew = false
        for index = 2, #widths do
            if widths[index] > widths[index - 1] then grew = true end
        end
        T.truthy(grew, "the wordmark must wipe in, not appear all at once")
    end},
```

Add to `controller/colossal/tests/test_theme.lua`, at the end of the returned table:

```lua
    { name = "restore is reachable from every exit path", run = function()
        local startup = io.open("startup.lua")
        T.equal(startup ~= nil, true, "run the suite from controller/, not colossal/")
        local text = startup:read("a"); startup:close()
        T.contains(text, "restore",
            "an InvOS that exits without restoring leaves the shell in InvOS colours")
        local main = io.open("colossal/main.lua")
        local mainText = main:read("a"); main:close()
        T.contains(mainText, "Theme.restore")
    end },
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
lua colossal/tests/run.lua tests.test_ui tests.test_splash tests.test_theme
```

Expected: the nav-marking test FAILS (no cell in row 2 uses `role.focus`), the splash test
FAILS (`Splash.GLYPHS` still exists), and the restore test FAILS (`startup.lua` contains no
`restore`).

- [ ] **Step 3: Move the splash onto Draw**

In `controller/colossal/app/splash.lua`, delete the local `GLYPHS` table and the
`wordmarkRows` function entirely.

The wipe currently reveals column by column, by substringing each rendered row. `blockText`
paints whole glyphs, so keep the column-level wipe by drawing the whole wordmark and then
painting the not-yet-revealed columns back to the ground colour. Replace the
`for row = 1, WORDMARK_HEIGHT do safeWrite(...) end` loop inside the wipe with:

```lua
        Draw.blockText(surface, left, top, WORD, Theme.role.brand)
        local reveal = math.ceil(WORDMARK_WIDTH * step / wipeSteps)
        for row = 0, WORDMARK_HEIGHT - 1 do
            Draw.band(surface, top + row, Theme.role.ground,
                left + reveal, left + WORDMARK_WIDTH - 1)
        end
```

Add at the top of the file, after the `local M = {}` line:

```lua
local Draw = require("app.draw")
local Theme = require("app.theme")
```

Delete the local `palette` table and replace all five of its uses: `Theme.role.brand` for the
wordmark and the loading bar, `Theme.role.muted` for the tagline, and `Theme.role.ground` /
`Theme.role.text` for the two references inside `safeWrite` and `clear` — those two are easy to
miss because they are not part of the visible design, and leaving them behind is what makes the
`palette` local look still-needed. Keep `WORDMARK_WIDTH` and `WORDMARK_HEIGHT`, which the wipe
and the small-screen fallback both still need.

At the top of `M.play`, before `clear(surface)`, add:

```lua
    Theme.apply(surface)
```

- [ ] **Step 4: Restyle the header and footer**

In `controller/colossal/app/ui.lua`, add near the other requires at the top:

```lua
local Draw = require("app.draw")
local Layout = require("app.layout")
local Theme = require("app.theme")
```

Replace the body of `UI:_header` with:

```lua
function UI:_header(state, model)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    Draw.band(surface, regions.header, Theme.role.panel)
    Draw.text(surface, 2, regions.header, "INVOS", 20, Theme.role.brand, Theme.role.panel)
    local lifecycle = model.lifecycle or "BOOTING"
    Draw.rightText(surface, regions.width - 1, regions.header, lifecycle,
        Theme.statusColor(lifecycle), Theme.role.panel)
    Draw.band(surface, regions.nav, Theme.role.ground)
    self:_nav(state, regions)
end
```

Add `UI:_nav` immediately below it, replacing the standalone `navigationBar` function. It keeps
the existing degrade-by-spacing-then-labels behaviour and adds the active fill:

```lua
-- Six pages no longer fit a narrow monitor at full width, so the bar gives up its spacing
-- first and only then its longer labels. Every page keeps its digit visible: a shortcut the
-- header does not advertise is a shortcut nobody presses. The page you are on is filled,
-- because a bar where every entry looks identical tells you nothing about where you are.
function UI:_nav(state, regions)
    local surface = self.surface
    local page = state.page
    for _, label in ipairs({"long", "short"}) do
        for _, gap in ipairs({2, 1}) do
            local total = 0
            for _, entry in ipairs(NAV_PAGES) do
                total = total + #entry.digit + 1 + #entry[label] + gap
            end
            total = total - gap
            if total <= regions.width - 2 then
                local x = 2
                for _, entry in ipairs(NAV_PAGES) do
                    local text = entry.digit .. " " .. entry[label]
                    local active = entry.page == page
                    Draw.text(surface, x, regions.nav, text, #text,
                        active and Theme.role.ground or Theme.role.muted,
                        active and Theme.role.focus or Theme.role.ground)
                    x = x + #text + gap
                end
                return
            end
        end
    end
end
```

Extend `NAV_PAGES` so each entry carries the page it opens, matching the ids `OPEN_PAGE` uses:

```lua
local NAV_PAGES = {
    {digit="1", long="SEARCH",   short="SEARCH", page="search"},
    {digit="2", long="NODES",    short="NODES",  page="storage"},
    {digit="3", long="REQUESTS", short="REQS",   page="requests"},
    {digit="4", long="ALERTS",   short="ALERTS", page="alerts"},
    {digit="5", long="SETUP",    short="SETUP",  page="setup"},
    {digit="6", long="CRAFTING", short="CRAFT",  page="crafting"},
}
```

Replace the body of `UI:_footer` with:

```lua
function UI:_footer(state, model)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    if regions.height < 2 then return end
    Draw.band(surface, regions.footer, Theme.role.panel)
    Draw.text(surface, 2, regions.footer, footerHelp(state), regions.width - 2,
        Theme.role.text, Theme.role.panel)
    Draw.band(surface, regions.status, Theme.role.ground)
    Draw.text(surface, 2, regions.status,
        state.notice or enrichmentText(model.enrichment) or model.lifecycle_reason or "",
        regions.width - 2,
        state.notice and Theme.role.alert or Theme.role.muted, Theme.role.ground)
end
```

- [ ] **Step 5: Apply and restore the palette**

In `controller/colossal/main.lua`, add `local Theme = require("app.theme")` beside the other
`app.` requires. After the three surfaces are resolved — immediately after the
`craftMonitorSurface` assignment around line 297 — add:

```lua
    -- The palette is per surface, and a monitor bound after startup gets its own when the
    -- peripheral event lands. A surface with no palette API renders in stock colours.
    Theme.apply(termApi.current and termApi.current() or termApi)
    Theme.apply(monitorSurface)
    Theme.apply(craftMonitorSurface)
```

Replace the entry block at the bottom of the file with one that restores on the way out:

```lua
if ...==nil then
    local ok,reason=xpcall(function() Main.run() end,function(value)
        return debug and debug.traceback and debug.traceback(value,2) or tostring(value)
    end)
    -- setPaletteColour changes the terminal, not the program. Leaving InvOS colours behind
    -- looks like a corrupted computer rather than a program that forgot to tidy up.
    pcall(Theme.restore, term.current and term.current() or term)
    if not ok then printError("InvOS failed: "..tostring(reason)) end
end
```

In `controller/startup.lua`, add after the `package.path` line:

```lua
local Theme = require("app.theme")
```

and immediately after the `while true do ... end` supervisor loop, add:

```lua
-- The loop above exits when the application stops cleanly or the operator interrupts the
-- backoff. Either way the terminal must not be left in InvOS colours.
pcall(Theme.restore, term.current and term.current() or term)
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
lua colossal/tests/run.lua
```

Expected: `RESULT 635 passed, 0 failed` — two new tests in `test_ui`, one in `test_splash`, one
in `test_theme`. If the count is 634, the modified assertion inside the existing splash test was
replaced with something that no longer runs; check step 1.

- [ ] **Step 7: Commit**

```bash
git add controller/colossal/app/splash.lua controller/colossal/app/ui.lua \
        controller/colossal/main.lua controller/startup.lua \
        controller/colossal/tests/test_ui.lua controller/colossal/tests/test_splash.lua \
        controller/colossal/tests/test_theme.lua
git commit -m "feat: put the splash, header and footer on the new foundation

The palette is applied to all three surfaces at build and restored on
every exit path, including the operator interrupting the supervisor
backoff -- otherwise quitting InvOS leaves the shell in InvOS colours
until the computer reboots.

The nav bar now fills the page you are on. A bar where all six entries
look identical does not tell you where you are.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Deploy, and confirm the subpixel mapping in world

The half-cell meter character is the one thing in this plan that the host suite cannot verify.
This task settles it before any page depends on it.

**Files:**
- Create: `controller/colossal/tools_glyphsheet.lua` (temporary; deleted in step 6)

**Interfaces:**
- Consumes: `Draw.HALF`, `Draw.subpixel`.
- Produces: a confirmed answer to whether character 149 is a left half-column. Phase 2's meters
  depend on it.

- [ ] **Step 1: Write the glyph sheet**

Create `controller/colossal/tools_glyphsheet.lua`. It is a throwaway diagnostic, not part of
the application, and is deliberately not added to the deployment manifest — copy it by hand.

```lua
-- Throwaway: prints the 32 subpixel characters with their indices so the bit order in
-- draw.lua can be confirmed by looking at it. Character 149 should be a left half-column.
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
term.write("subpixel glyphs 128-159")
for index = 0, 31 do
    local x = 1 + (index % 8) * 6
    local y = 3 + math.floor(index / 8) * 2
    term.setCursorPos(x, y)
    term.setTextColor(colors.white)
    term.write(tostring(128 + index))
    term.setCursorPos(x, y + 1)
    term.setTextColor(colors.lime)
    term.setBackgroundColor(colors.gray)
    term.write(string.char(128 + index))
    term.setBackgroundColor(colors.black)
end
term.setCursorPos(1, 12)
term.setTextColor(colors.white)
term.write("149 should be a LEFT HALF column")
```

- [ ] **Step 2: Confirm both computers are shut down**

Ask the operator directly and get an explicit answer in the current conversation. A confirmation
from an earlier deployment never carries forward. Do not infer quiescence from file mtimes.

- [ ] **Step 3: Deploy**

```bash
python tools/deploy.py --computers "G:/world/computercraft/computer"
```

Expected: `TOTAL PROBLEMS: 0`. On any problem the live tree is in an unknown state; restore
from the printed backup path before booting.

- [ ] **Step 4: Confirm the glyph in world**

Copy `tools_glyphsheet.lua` to `G:/world/computercraft/computer/4/` by hand, boot the
controller, and run it. Look at the cell under `149`.

- If it is a **left half-column**, the mapping in `draw.lua` is right. Nothing to change.
- If it is anything else, find the index that *is* a left half-column, set `M.HALF` to it in
  `draw.lua`, and update the comment above it with what was actually observed. If no index is a
  clean left half-column, set `M.subpixel = false` and open a backlog entry; meters fall back to
  whole cells and everything else is unaffected.

- [ ] **Step 5: Confirm the palette restores**

Still on the controller: exit InvOS with `Ctrl+T`, then run `ls` at the CraftOS prompt. The
shell must be in stock CC colours, not InvOS colours. If it is not, the restore path is wrong
and must be fixed before phase 2 — this is the failure that looks like a broken computer.

- [ ] **Step 6: Remove the diagnostic and record the result**

```bash
rm controller/colossal/tools_glyphsheet.lua
```

Delete the copy on computer 4 as well. Then, if `M.HALF` or `M.subpixel` changed, commit:

```bash
git add controller/colossal/app/draw.lua
git commit -m "fix: correct the subpixel character from the in-world glyph sheet

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 7: Report**

Report to the operator: the deployment result, what character 149 actually rendered as, and
whether the palette restored cleanly. Phase 2 is planned separately and starts from these
answers.

---

## What this plan does not cover

Phases 2 through 4 of the spec — the terminal pages, terminal input, and the two monitors — are
deliberately not planned here.

Phase 2's meters, panes and bands all rest on the subpixel mapping that Task 6 confirms, and the
detail-pane geometry rests on `Layout.regions` surviving contact with six real pages. Writing
those tasks now would mean writing them against two unverified assumptions. Each remaining phase
gets its own plan once this one has been deployed and the answers are in hand.
