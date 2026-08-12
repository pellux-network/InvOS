# UI pages: shared list primitives, Search and Crafting

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the two pages you actually drive — Search and Crafting — onto the phase 1
foundation, in the approved Panelled composition, on top of list primitives the remaining pages
will reuse.

**Architecture:** Four shared helpers on `UI` (`_band`, `_list`, `_row`, `_strip`) absorb the
scrolling-selectable-list pattern that all six pages reimplement differently today. Search and
Crafting are then rebuilt on them. Nodes, Requests, Alerts and Setup follow in a second plan
and delete the last of the private helpers.

**Tech Stack:** Lua 5.2 target, tested on 5.4. `app/theme.lua`, `app/draw.lua`, `app/layout.lua`
from phase 1.

## Global Constraints

- **Scope: presentation only.** No diff may touch `coordinator.lua`, `requests.lua`,
  `craft_service.lua`, or anything under `core/`. In particular the meter strip reads occupancy
  from `model.nodes` by `role`, **not** from `model.dropoff` / `model.pickup` — those come from
  `Coordinator:_nodeForRole`, which returns the raw node without the snapshot's `size` and
  `occupied` merged in. Reading them there would return nil and tempt a coordinator change.
- **Run tests from `controller/`:** `lua colossal/tests/run.lua`. Starts at 636 passing, 0 failing.
- **Rendering must never mutate UI state** (`tests/test_ui_purity.lua`). Scroll offsets are
  computed and returned, never stored.
- **Pages name roles, never slots.** `Theme.role.focus`, never `colors.pink`.
- **Selection looks the same on every page:** a filled row in `Theme.role.focus` with inverted
  text. The pages currently disagree — Search fills red, Crafting fills grey — and that
  inconsistency is a thing this plan exists to remove.
- Commit messages end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

### Task 1: Shared list primitives

**Files:**
- Modify: `controller/colossal/app/ui.lua`
- Test: `controller/colossal/tests/test_ui_list.lua` (create)
- Modify: `controller/colossal/tests/run.lua`

**Interfaces:**
- Consumes: `Draw`, `Theme`, `Layout` from phase 1.
- Produces:
  - `UI:_band(y)` — fills row `y` in the panel colour.
  - `UI:_bandText(x, y, text, width)` — writes a band label in muted-on-panel.
  - `UI:_list(top, bottom, count, selection, render) -> scroll, visible` — calls
    `render(index, y, selected)` per visible row.
  - `UI:_row(y, selected, from, to, marker, markerColor, left, right, rightColor)`
  - `UI:_strip(regions, model)` — the chest-level strip; draws nothing when `regions.strip` is nil.

- [ ] **Step 1: Write the failing test**

Create `controller/colossal/tests/test_ui_list.lua`:

```lua
local UI = require("app.ui")
local Theme = require("app.theme")
local T = require("tests.mock_cc")

local function ui(width, height) return UI.new(T.recordingSurface(width or 51, height or 19)) end

return {
    { name = "a list shows the window that contains the selection", run = function()
        local screen, seen = ui(), {}
        local scroll = screen:_list(1, 5, 40, 30, function(index, y)
            seen[#seen + 1] = index
            T.truthy(y >= 1 and y <= 5, "row " .. index .. " drew at " .. y)
        end)
        T.equal(scroll, 26, "a five-row window ending on 30 starts at 26")
        T.equal(#seen, 5)
        T.equal(seen[5], 30, "the selection must be the last visible row")
    end },
    { name = "a list shorter than its window draws every row and no more", run = function()
        local screen, seen = ui(), 0
        screen:_list(1, 8, 3, 1, function() seen = seen + 1 end)
        T.equal(seen, 3, "an empty row must not be rendered")
    end },
    { name = "a list with no rows renders nothing and does not error", run = function()
        local screen, seen = ui(), 0
        screen:_list(1, 8, 0, 1, function() seen = seen + 1 end)
        T.equal(seen, 0)
    end },
    { name = "the selected row is filled in the focus colour everywhere", run = function()
        local screen = ui()
        screen:_row(4, true, 1, 20, "o", Theme.role.ok, "Iron Ingot", "1,284")
        local surface = screen.surface
        local filled = 0
        for x = 1, 20 do
            if surface.backgroundAt(x, 4) == Theme.role.focus then filled = filled + 1 end
        end
        T.equal(filled, 20, "the whole row segment must fill, not just the text")
        T.contains(surface.line(4), "Iron Ingot")
        T.contains(surface.line(4), "1,284")
    end },
    { name = "an unselected row leaves the ground alone", run = function()
        local screen = ui()
        screen:_row(4, false, 1, 20, nil, nil, "Iron Block", "96")
        local surface = screen.surface
        for x = 1, 20 do
            T.equal(surface.backgroundAt(x, 4), Theme.role.ground)
        end
    end },
    { name = "a row clips its name rather than overrunning its value", run = function()
        local screen = ui()
        screen:_row(4, false, 1, 20, nil, nil,
            "An Extremely Long Modded Item Name", "12,032")
        T.equal(screen.surface.writesOutsideBounds(), 0)
        T.contains(screen.surface.line(4), "12,032")
    end },
    { name = "the strip meters drop-off and pickup from the node list", run = function()
        local screen = ui()
        local Layout = require("app.layout")
        local regions = Layout.regions(51, 19)
        screen:_strip(regions, { nodes = {
            { id="dropoff", role="dropoff", occupied=9,  size=27 },
            { id="s1",      role="storage", occupied=40, size=54 },
            { id="pickup",  role="pickup",  occupied=0,  size=27 },
        }})
        local line = screen.surface.line(regions.strip)
        T.contains(line, "DROP-OFF")
        T.contains(line, "PICKUP")
        T.contains(line, "33%", "9 of 27 is 33 percent")
        T.contains(line, "0%")
    end },
    { name = "the strip is silent when the screen has no room for it", run = function()
        local screen = ui(51, 8)
        local Layout = require("app.layout")
        local regions = Layout.regions(51, 8)
        T.equal(regions.strip, nil)
        screen:_strip(regions, { nodes = {} })
        T.equal(screen.surface.writesOutsideBounds(), 0)
    end },
    { name = "the strip survives a model with no nodes at all", run = function()
        local screen = ui()
        local Layout = require("app.layout")
        screen:_strip(Layout.regions(51, 19), {})
        T.equal(screen.surface.writesOutsideBounds(), 0)
    end },
}
```

- [ ] **Step 2: Register the test module**

In `controller/colossal/tests/run.lua`, add `"tests.test_ui_list",` immediately after
`"tests.test_ui_layout",`.

- [ ] **Step 3: Run the test to verify it fails**

```bash
lua colossal/tests/run.lua tests.test_ui_list
```

Expected: FAIL, `attempt to call method '_list' (a nil value)`.

- [ ] **Step 4: Move `scrollFor` above the helpers and add the primitives**

`scrollFor` currently sits just above `UI:_crafting`. Move it up so it is defined before
`UI:_list`, immediately after the `formatNumber` helper near the top of the file. Its body is
unchanged.

Add these five methods immediately after `UI:_nav`:

```lua
-- A labelled section band. Structure in this UI is background colour or it is nothing: the
-- CC font has no box-drawing characters, so a heading is a filled row with text on it.
function UI:_band(y) Draw.band(self.surface, y, Theme.role.panel) end

function UI:_bandText(x, y, text, width)
    Draw.text(self.surface, x, y, text, width, Theme.role.muted, Theme.role.panel)
end

-- Draws a scrolling selectable list into rows `top` through `bottom`, calling
-- `render(index, y, selected)` for each visible row. Returns the scroll offset and the window
-- height so a caller can map a click back to an index. The offset is returned, never stored:
-- a render that mutates state is what tests/test_ui_purity.lua forbids.
function UI:_list(top, bottom, count, selection, render)
    local visible = math.max(0, bottom - top + 1)
    local scroll = scrollFor(selection, count, visible)
    for offset = 0, visible - 1 do
        local index = scroll + offset
        if index > (count or 0) then break end
        render(index, top + offset, index == selection)
    end
    return scroll, visible
end

-- One list row: an optional status marker, a name, and a right-aligned value. Selection is a
-- filled row in the focus colour with inverted text -- the same on every page. The pages used
-- to disagree, Search filling red and Crafting filling grey, which read as two products.
function UI:_row(y, selected, from, to, marker, markerColor, left, right, rightColor)
    local surface = self.surface
    local background = selected and Theme.role.focus or Theme.role.ground
    local primary = selected and Theme.role.ground or Theme.role.text
    Draw.band(surface, y, background, from, to)
    if marker then
        Draw.text(surface, from + 1, y, marker, 1,
            selected and Theme.role.ground or (markerColor or Theme.role.muted), background)
    end
    right = right and tostring(right) or nil
    local nameWidth = math.max(1, (to - from + 1) - #(right or "") - 4)
    Draw.text(surface, from + 3, y, left, nameWidth, primary, background)
    if right then
        Draw.rightText(surface, to - 1, y, right,
            selected and Theme.role.ground or (rightColor or Theme.role.muted), background)
    end
end

-- Drop-off and Pickup levels, on every page, because they are the two numbers you always want
-- and a page switch to read them is a page switch too many. Occupancy comes from model.nodes
-- by role: model.dropoff and model.pickup are built by Coordinator:_nodeForRole, which does
-- not merge the scan snapshot, so their size and occupied are nil.
local function nodeByRole(model, role)
    for _, node in ipairs((model or {}).nodes or {}) do
        if node.role == role then return node end
    end
end

function UI:_strip(regions, model)
    if not regions.strip then return end
    local surface = self.surface
    Draw.band(surface, regions.strip, Theme.role.panel)
    local half = math.floor(regions.width / 2)
    local function gauge(x, width, label, node)
        local size = (node or {}).size or 0
        local occupied = (node or {}).occupied or 0
        local fraction = size > 0 and (occupied / size) or 0
        local percent = tostring(math.floor(fraction * 100 + 0.5)) .. "%"
        Draw.text(surface, x, regions.strip, label, #label, Theme.role.muted, Theme.role.panel)
        local meterX = x + #label + 1
        local meterWidth = math.max(0, width - #label - #percent - 3)
        if meterWidth > 0 then
            local fill = fraction >= 0.9 and Theme.role.alert
                or (fraction >= 0.75 and Theme.role.warn or Theme.role.ok)
            Draw.meter(surface, meterX, regions.strip, meterWidth, fraction,
                fill, Theme.role.track)
        end
        Draw.text(surface, meterX + meterWidth + 1, regions.strip, percent, #percent,
            Theme.role.text, Theme.role.panel)
    end
    gauge(2, half - 2, "DROP-OFF", nodeByRole(model, "dropoff"))
    gauge(half + 1, half - 2, "PICKUP", nodeByRole(model, "pickup"))
end
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
lua colossal/tests/run.lua
```

Expected: `RESULT 645 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add controller/colossal/app/ui.lua controller/colossal/tests/test_ui_list.lua \
        controller/colossal/tests/run.lua
git commit -m "feat: add shared list, band and strip primitives

Six pages each reimplement a scrolling selectable list, with different
scroll logic and two different selection colours. These are the one
implementation they will all use.

The strip reads occupancy from model.nodes by role: model.dropoff and
model.pickup come from Coordinator:_nodeForRole, which does not merge
the scan snapshot, so their size and occupied are nil.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: The Search page

**Files:**
- Modify: `controller/colossal/app/ui.lua` (`UI:_search`)
- Test: `controller/colossal/tests/test_ui_search.lua` (create)
- Modify: `controller/colossal/tests/run.lua`

**Interfaces:**
- Consumes: `UI:_band`, `UI:_bandText`, `UI:_list`, `UI:_row`, `UI:_strip`, `Layout.regions`.
- Produces: nothing later tasks rely on.

**Target layout** at 51x19, matching the approved mockup:

```
row 1   header band          row 2   nav
row 4   > query_             row 6   band: ITEM ... STOCK | SELECTED
rows 7-16  list (left, columns 1..split-1) and detail pane (split+2..width-1)
row 17  strip                row 18  footer      row 19  status
```

- [ ] **Step 1: Write the failing test**

Create `controller/colossal/tests/test_ui_search.lua`:

```lua
local UI = require("app.ui")
local Theme = require("app.theme")
local T = require("tests.mock_cc")

local function result(key, name, quantity, variants)
    return {identity_key=key, name="minecraft:"..name:lower(), display_name=name,
        quantity=quantity, max_count=64, variants=variants or {{identity_key=key,
        display_name=name, quantity=quantity, max_count=64}}}
end

local function stateWith(count, selection)
    local state = UI.initialState()
    state.results = {}
    for index = 1, count do
        state.results[index] = result("i"..index, "Item"..index, index * 10)
    end
    state.result_count = count
    state.selection = selection or 1
    state.query = "ir"
    return state
end

local function render(width, height, state)
    local screen = UI.new(T.recordingSurface(width, height))
    screen:render(state, {lifecycle="READY", search_results=state.results, nodes={
        {id="dropoff", role="dropoff", occupied=9, size=27},
        {id="pickup", role="pickup", occupied=0, size=27},
    }})
    return screen.surface
end

return {
    { name = "the search page shows its query, list and detail pane", run = function()
        local surface = render(51, 19, stateWith(8, 1))
        local text = surface.allText()
        T.contains(text, "> ir")
        T.contains(text, "ITEM")
        T.contains(text, "STOCK")
        T.contains(text, "Item1")
        T.contains(text, "minecraft:item1", "the detail pane must show the exact id")
    end },
    { name = "the selected row is filled in focus, not in brand red", run = function()
        local surface = render(51, 19, stateWith(8, 1))
        local focusRows = 0
        for y = 1, 19 do
            if surface.backgroundAt(2, y) == Theme.role.focus then focusRows = focusRows + 1 end
        end
        T.truthy(focusRows >= 1, "the selection must be filled")
        T.equal(surface.backgroundAt(2, 6), Theme.role.panel, "row 6 is the section band")
    end },
    { name = "a long result list scrolls to keep the selection visible", run = function()
        local surface = render(51, 19, stateWith(40, 30))
        local text = surface.allText()
        T.contains(text, "Item30")
        T.equal(text:find("Item1 ", 1, true), nil)
    end },
    { name = "an empty query explains itself rather than showing a blank list", run = function()
        local state = UI.initialState()
        local screen = UI.new(T.recordingSurface(51, 19))
        screen:render(state, {lifecycle="READY", search_results={}})
        T.contains(screen.surface.allText(), "Start typing")
    end },
    { name = "a query with no matches says so", run = function()
        local state = stateWith(0, 1)
        local screen = UI.new(T.recordingSurface(51, 19))
        screen:render(state, {lifecycle="READY", search_results={}})
        T.contains(screen.surface.allText(), "No matching items")
    end },
    { name = "the chest strip appears on the search page", run = function()
        local surface = render(51, 19, stateWith(8, 1))
        T.contains(surface.line(17), "DROP-OFF")
        T.contains(surface.line(17), "33%")
    end },
    { name = "the detail pane collapses below 40 columns", run = function()
        local surface = render(30, 19, stateWith(8, 1))
        T.equal(surface.writesOutsideBounds(), 0)
        T.contains(surface.allText(), "Item1")
    end },
    { name = "the search page never draws outside its surface", run = function()
        for _, size in ipairs({{51,19},{80,24},{40,14},{26,12},{18,8}}) do
            local surface = render(size[1], size[2], stateWith(40, 30))
            T.equal(surface.writesOutsideBounds(), 0,
                size[1] .. "x" .. size[2] .. " drew outside")
        end
    end },
}
```

- [ ] **Step 2: Register the test module**

Add `"tests.test_ui_search",` after `"tests.test_ui_list",` in `run.lua`.

- [ ] **Step 3: Run the test to verify it fails**

```bash
lua colossal/tests/run.lua tests.test_ui_search
```

Expected: several FAIL — the current page draws no `ITEM`/`STOCK` band and no strip.

- [ ] **Step 4: Rebuild `UI:_search`**

Replace the whole of `UI:_search` with:

```lua
function UI:_search(state, model, hitRegions)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    local split = regions.split
    local listTo = split and (split - 1) or regions.width
    local paneFrom = split and (split + 2) or nil

    Draw.band(surface, regions.content.top + 1, Theme.role.ground)
    Draw.text(surface, 2, regions.content.top + 1, ">", 1, Theme.role.focus, Theme.role.ground)
    Draw.text(surface, 4, regions.content.top + 1,
        state.query .. (state.mode == "search" and "_" or ""),
        regions.width - 4, Theme.role.text, Theme.role.ground)

    local bandRow = regions.content.top + 3
    local bodyTop = bandRow + 1
    self:_band(bandRow)
    self:_bandText(2, bandRow, "ITEM", listTo - 2)
    Draw.rightText(surface, listTo - 1, bandRow, "STOCK", Theme.role.muted, Theme.role.panel)
    if paneFrom then
        self:_bandText(paneFrom, bandRow, "SELECTED", regions.width - paneFrom)
        Draw.divider(surface, split, bandRow, regions.content.bottom, Theme.role.panel)
    end

    local results = model.search_results or state.results or {}
    if #results == 0 then
        Draw.text(surface, 2, bodyTop,
            state.query == "" and "Start typing to search stored items" or "No matching items",
            regions.width - 3, Theme.role.muted, Theme.role.ground)
        self:_strip(regions, model)
        return
    end

    self:_list(bodyTop, regions.content.bottom, #results, state.selection,
        function(index, y, selected)
            local item = results[index]
            self:_row(y, selected, 1, listTo, selected and ">" or nil, nil,
                tostring(item.display_name or item.name), formatNumber(item.quantity))
            hitRegions[#hitRegions + 1] = {x1=1, y1=y, x2=listTo, y2=y,
                command={type="ACTIVATE", index=index}}
        end)

    local selected = results[state.selection]
    if paneFrom and selected then
        local paneWidth = regions.width - paneFrom
        Draw.text(surface, paneFrom, bodyTop, tostring(selected.display_name or selected.name),
            paneWidth, Theme.role.focus, Theme.role.ground)
        Draw.text(surface, paneFrom, bodyTop + 1, tostring(selected.name), paneWidth,
            Theme.role.muted, Theme.role.ground)
        Draw.text(surface, paneFrom, bodyTop + 3, "STOCK", paneWidth,
            Theme.role.muted, Theme.role.ground)
        local nodes = #(selected.variants or {})
        Draw.meter(surface, paneFrom, bodyTop + 4, math.max(1, paneWidth - 1),
            math.min(1, (selected.quantity or 0) / 2048), Theme.role.ok, Theme.role.track)
        Draw.text(surface, paneFrom, bodyTop + 5,
            formatNumber(selected.quantity) .. " stored", paneWidth,
            Theme.role.text, Theme.role.ground)
        if nodes > 1 then
            Draw.text(surface, paneFrom, bodyTop + 7, nodes .. " exact variants", paneWidth,
                Theme.role.muted, Theme.role.ground)
        end
        local button = "  ENTER  RETRIEVE "
        Draw.text(surface, paneFrom, math.min(regions.content.bottom, bodyTop + 9),
            button, math.min(#button, paneWidth), Theme.role.text, Theme.role.brand)
    end
    self:_strip(regions, model)
end
```

- [ ] **Step 5: Run the tests**

```bash
lua colossal/tests/run.lua
```

Expected: `RESULT 653 passed, 0 failed`. If `test_ui.lua` or `test_acceptance.lua` fail on a
changed string, read the assertion before changing it — some of them pin behaviour that must
not move, such as the query surviving a cancel.

- [ ] **Step 6: Commit**

```bash
git add controller/colossal/app/ui.lua controller/colossal/tests/test_ui_search.lua \
        controller/colossal/tests/run.lua
git commit -m "feat: rebuild the Search page in the Panelled composition

Labelled bands, a detail pane that now appears at 40 columns rather
than 72, a stock meter, and the shared chest strip.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: The Crafting page

**Files:**
- Modify: `controller/colossal/app/ui.lua` (`UI:_crafting`)
- Test: `controller/colossal/tests/test_craft_ui.lua`

**Interfaces:**
- Consumes: the Task 1 primitives.
- Produces: nothing later tasks rely on.

The four modes keep their current behaviour and gain the shared vocabulary. The plan view stops
printing raw item ids where a display name is available.

- [ ] **Step 1: Write the failing tests**

Add to `controller/colossal/tests/test_craft_ui.lua`, before the bounds test:

```lua
    {name="the crafting page uses the same selection colour as every other page",run=function()
        local Theme = require("app.theme")
        local surface = ui()
        surface:render(crafting({craft_selection=1}), {})
        local focus = 0
        for y = 1, 19 do
            if surface.surface.backgroundAt(2, y) == Theme.role.focus then focus = focus + 1 end
        end
        T.truthy(focus >= 1, "crafting used to fill grey while Search filled red")
    end},
    {name="the recipe list is labelled",run=function()
        local surface = ui()
        surface:render(crafting(), {})
        local text = surface.surface.allText()
        T.contains(text, "RECIPE")
        T.contains(text, "STOCK")
    end},
    {name="the plan names items rather than printing raw ids",run=function()
        local surface = ui()
        local plan = samplePlan()
        local state = crafting({mode="craft_plan", craft_plan=plan,
            craft_item={item="minecraft:chest", display_name="Chest"}})
        surface:render(state, {})
        T.contains(surface.surface.allText(), "Chest")
    end},
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
lua colossal/tests/run.lua tests.test_craft_ui
```

Expected: the colour and `RECIPE` tests FAIL.

- [ ] **Step 3: Rebuild `UI:_crafting`**

Replace the `craft_jobs` branch's row drawing with `self:_list` and `self:_row`, and the recipe
list at the end likewise. The jobs branch becomes:

```lua
    if state.mode == "craft_jobs" then
        local bandRow = regions.content.top
        self:_band(bandRow)
        self:_bandText(2, bandRow, "CRAFT JOBS", regions.width - 2)
        Draw.rightText(surface, regions.width - 1, bandRow, "STATE",
            Theme.role.muted, Theme.role.panel)
        local jobs = state.craft_jobs or {}
        if #jobs == 0 then
            Draw.text(surface, 2, bandRow + 1, "No craft jobs", regions.width - 2,
                Theme.role.muted, Theme.role.ground)
        end
        self:_list(bandRow + 1, regions.content.bottom, #jobs,
            state.craft_job_selection or 1, function(index, y, selected)
                local job = jobs[index]
                local label = tostring(job.state)
                if job.state == "QUEUED" then label = "QUEUED #" .. tostring(index - 1) end
                self:_row(y, selected, 1, regions.width, nil, nil,
                    tostring(job.display_name or job.item), label,
                    Theme.statusColor(job.state))
                hitRegions[#hitRegions + 1] = {x1=1, y1=y, x2=regions.width, y2=y,
                    command={type="MOVE", delta=index - (state.craft_job_selection or 1)}}
            end)
        self:_strip(regions, model)
        return
    end
```

and the recipe list becomes:

```lua
    local bandRow = regions.content.top + 1
    Draw.text(surface, 2, regions.content.top, ">", 1, Theme.role.focus, Theme.role.ground)
    Draw.text(surface, 4, regions.content.top,
        state.craft_query .. (state.mode == "craft_search" and "_" or ""),
        regions.width - 4, Theme.role.text, Theme.role.ground)
    self:_band(bandRow)
    self:_bandText(2, bandRow, "RECIPE", regions.width - 2)
    Draw.rightText(surface, regions.width - 1, bandRow, "STOCK",
        Theme.role.muted, Theme.role.panel)
    local results = state.craft_results or {}
    if #results == 0 then
        Draw.text(surface, 2, bandRow + 1, "No matching recipes", regions.width - 2,
            Theme.role.muted, Theme.role.ground)
    end
    self:_list(bandRow + 1, regions.content.bottom, #results, state.craft_selection or 1,
        function(index, y, selected)
            local entry = results[index]
            self:_row(y, selected, 1, regions.width, nil, nil,
                tostring(entry.display_name or entry.item),
                "have " .. formatNumber(entry.quantity or 0),
                (entry.quantity or 0) > 0 and Theme.role.ok or Theme.role.muted)
            hitRegions[#hitRegions + 1] = {x1=1, y1=y, x2=regions.width, y2=y,
                command={type="MOVE", delta=index - (state.craft_selection or 1)}}
        end)
    self:_strip(regions, model)
```

Add `local regions = Layout.regions(surface.getSize())` at the top of the function and replace
`bottom` with `regions.content.bottom` throughout. In the `craft_plan` branch, replace
`tostring(step.item)` and `tostring(draw.item)` with a lookup that prefers a display name:

```lua
    local function itemName(id)
        for _, entry in ipairs(state.craft_results or {}) do
            if entry.item == id then return tostring(entry.display_name or id) end
        end
        if state.craft_item and state.craft_item.item == id then
            return tostring(state.craft_item.display_name or id)
        end
        return tostring(id)
    end
```

- [ ] **Step 4: Run the tests**

```bash
lua colossal/tests/run.lua
```

Expected: `RESULT 656 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add controller/colossal/app/ui.lua controller/colossal/tests/test_craft_ui.lua
git commit -m "feat: rebuild the Crafting page on the shared primitives

It now selects in the same colour as every other page, labels its
list, and names items in the plan instead of printing raw ids.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Deploy and look at it

- [ ] **Step 1: Confirm both computers are shut down**

Ask the operator explicitly in the current conversation. A confirmation from an earlier
deployment never carries forward.

- [ ] **Step 2: Deploy**

```bash
python tools/deploy.py --computers "G:/world/computercraft/computer"
```

Expected: `TOTAL PROBLEMS: 0`.

- [ ] **Step 3: Look at the two pages**

Boot the controller. On Search: the band labels, the detail pane, the coral selection, the
chest strip along the bottom. Press `6` for Crafting and confirm the selection colour matches
and a long recipe list scrolls. Report anything that reads wrong — this is the first time the
composition exists outside a mockup.

---

## What this plan does not cover

Nodes, Requests, Alerts and Setup, and the deletion of the private `writeClipped`, `fill`,
`stateColor` and `palette` helpers from `ui.lua`. Those follow in a second plan; the helpers
cannot go until every page has stopped calling them.
