# UI pages: Nodes, Requests, Alerts, Setup — and deleting the old helpers

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the last four pages onto the shared foundation, then delete the private
`writeClipped`, `fill`, `stateColor` and `palette` helpers from `ui.lua` — the deduplication
the whole visual system exists to reach.

**Architecture:** Each page is rewritten against `UI:_band`, `UI:_list`, `UI:_row`, `UI:_strip`
and `Layout.regions`. A new `UI:_windowed` splits the windowing out of `_list`, because the
Nodes page scrolls by an explicit offset rather than by a selection. The final task is a
deletion with a test that fails if any of the old helpers survive.

**Tech Stack:** Lua 5.2 target, tested on 5.4. `theme`, `draw`, `layout`, `buffer` from phase 1.

## Global Constraints

- **Scope: presentation only.** No diff may touch `coordinator.lua`, `requests.lua`,
  `craft_service.lua`, or anything under `core/`.
- **Run tests from `controller/`:** `lua colossal/tests/run.lua`. Starts at 665 passing, 0 failing.
- **Rendering must never mutate UI state** (`tests/test_ui_purity.lua`).
- **Pages name roles, never slots.**
- **Selection is `Theme.role.focus`, filled, with inverted text** — the same on every page.
- **Anything written to the live tree must unlink before writing.** The sshfs mount does not
  truncate on `open("wb")`; see `AGENTS.md`.
- Commit messages end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

### Task 1: Split windowing out of `_list`, and rebuild the Nodes page

The Nodes page scrolls by `state.storage_scroll`, not by a selection, so it cannot use `_list`
as it stands. `_windowed` is the half of `_list` that does not care where the offset came from.

**Files:**
- Modify: `controller/colossal/app/ui.lua` (`UI:_list`, `UI:_storage`)
- Test: `controller/colossal/tests/test_ui_list.lua`, `controller/colossal/tests/test_ui_pages.lua` (create)
- Modify: `controller/colossal/tests/run.lua`

**Interfaces:**
- Produces: `UI:_windowed(top, bottom, count, scroll, render) -> scroll, visible`, calling
  `render(index, y)`. `UI:_list` keeps its existing signature and delegates to it.

- [ ] **Step 1: Write the failing tests**

Add to `controller/colossal/tests/test_ui_list.lua`:

```lua
    { name = "a windowed list honours an explicit scroll offset", run = function()
        local screen, seen = UI.new(T.recordingSurface(51, 19)), {}
        local scroll = screen:_windowed(1, 5, 20, 8, function(index) seen[#seen + 1] = index end)
        T.equal(scroll, 8)
        T.equal(seen[1], 8)
        T.equal(#seen, 5)
    end },
    { name = "a windowed list clamps a scroll past the end back onto the last page", run = function()
        local screen, seen = UI.new(T.recordingSurface(51, 19)), {}
        local scroll = screen:_windowed(1, 5, 20, 99, function(index) seen[#seen + 1] = index end)
        T.equal(scroll, 16, "twenty rows in a five-row window ends at sixteen")
        T.equal(seen[#seen], 20, "the last row must be reachable")
    end },
```

Create `controller/colossal/tests/test_ui_pages.lua`:

```lua
local UI = require("app.ui")
local Theme = require("app.theme")
local T = require("tests.mock_cc")

local function nodes(count)
    local list = {{id="dropoff", role="dropoff", label="Drop-off", state="READY",
        occupied=9, size=27}}
    for index = 1, (count or 3) do
        list[#list + 1] = {id="s"..index, role="storage", label="Vault "..index,
            state="READY", occupied=index * 20, size=100}
    end
    list[#list + 1] = {id="pickup", role="pickup", label="Pickup", state="READY",
        occupied=0, size=27}
    return list
end

local function render(page, model, mutate)
    local surface = T.recordingSurface(51, 19)
    local screen = UI.new(surface)
    local state = UI.initialState()
    state.page, state.mode = page, "page"
    if mutate then mutate(state) end
    screen:render(state, model)
    return surface
end

return {
    { name = "the nodes page meters each node's fill", run = function()
        local surface = render("storage", {lifecycle="READY", nodes=nodes(3)})
        local text = surface.allText()
        T.contains(text, "Vault 1")
        T.contains(text, "NODE")
        T.contains(text, "20%", "a node at 20 of 100 must say so")
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "a node near capacity is metered in the warning colour", run = function()
        local full = nodes(1)
        full[2].occupied, full[2].size = 95, 100
        local surface = render("storage", {lifecycle="READY", nodes=full})
        local alerted = 0
        for y = 1, 19 do
            for x = 1, 51 do
                if surface.backgroundAt(x, y) == Theme.role.alert then alerted = alerted + 1 end
            end
        end
        T.truthy(alerted > 0, "a node at 95 percent must not be metered in the healthy colour")
    end },
    { name = "the requests page meters delivery progress", run = function()
        local surface = render("requests", {lifecycle="READY", nodes=nodes(1), requests={
            {id="r1", display_name="Iron Ingot", state="TRANSFERRING", delivered=16, requested=64},
        }})
        local text = surface.allText()
        T.contains(text, "Iron Ingot")
        T.contains(text, "16 / 64")
        T.contains(text, "REQUEST")
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "the alerts page separates critical from warning", run = function()
        local surface = render("alerts", {lifecycle="DEGRADED", nodes=nodes(1), alerts={
            {key="a1", severity="critical", message="Pickup is full", acknowledged=false},
            {key="a2", severity="warning", message="Vault 1 is filling", acknowledged=true},
        }}, function(state) state.alert_selection = 2 end)
        local text = surface.allText()
        T.contains(text, "Pickup is full")
        T.contains(text, "Vault 1 is filling")
        T.contains(text, "ALERT")
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "empty states still explain themselves", run = function()
        local cases = {
            {page="requests", text="No requests yet"},
            {page="alerts", text="No active alerts"},
            {page="setup", text="Review or change inventory roles"},
        }
        for _, case in ipairs(cases) do
            local surface = render(case.page, {lifecycle="READY", nodes=nodes(1)})
            T.contains(surface.allText(), case.text)
            T.equal(surface.writesOutsideBounds(), 0)
        end
    end },
    { name = "every page draws inside its surface at every size", run = function()
        for _, page in ipairs({"storage", "requests", "alerts", "setup"}) do
            for _, size in ipairs({{51,19},{80,24},{40,14},{26,12},{18,8}}) do
                local surface = T.recordingSurface(size[1], size[2])
                local screen = UI.new(surface)
                local state = UI.initialState()
                state.page, state.mode = page, "page"
                screen:render(state, {lifecycle="READY", nodes=nodes(20), requests={
                    {id="r1", display_name="Iron", state="QUEUED", delivered=0, requested=9},
                }, alerts={{key="a", severity="critical", message="Full", acknowledged=false}}})
                T.equal(surface.writesOutsideBounds(), 0,
                    page .. " at " .. size[1] .. "x" .. size[2])
            end
        end
    end },
}
```

- [ ] **Step 2: Register the module**

Add `"tests.test_ui_pages",` after `"tests.test_ui_search",` in `run.lua`.

- [ ] **Step 3: Run to verify they fail**

```bash
lua colossal/tests/run.lua tests.test_ui_list tests.test_ui_pages
```

Expected: `_windowed` is nil, and the Nodes page shows no `NODE` band or percentage.

- [ ] **Step 4: Split `_list` and rebuild `_storage`**

Replace `UI:_list` with the pair:

```lua
-- The windowing half, for a list that scrolls by an explicit offset rather than by a
-- selection. The Nodes page has no selection: it scrolls with the arrow keys directly.
function UI:_windowed(top, bottom, count, scroll, render)
    local visible = math.max(0, bottom - top + 1)
    scroll = math.max(1, math.min(scroll or 1, math.max(1, (count or 0) - visible + 1)))
    for offset = 0, visible - 1 do
        local index = scroll + offset
        if index > (count or 0) then break end
        render(index, top + offset)
    end
    return scroll, visible
end

function UI:_list(top, bottom, count, selection, render)
    local visible = math.max(0, bottom - top + 1)
    return self:_windowed(top, bottom, count, scrollFor(selection, count, visible),
        function(index, y) render(index, y, index == selection) end)
end
```

Replace `UI:_storage` with:

```lua
function UI:_storage(state, model)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    local bandRow = regions.content.top
    self:_band(bandRow)
    self:_bandText(2, bandRow, "NODE", regions.width - 2)
    Draw.rightText(surface, regions.width - 1, bandRow, "USED", Theme.role.muted, Theme.role.panel)
    local nodes = model.nodes or {}
    if #nodes == 0 then
        Draw.text(surface, 2, bandRow + 1, "No storage nodes configured", regions.width - 3,
            Theme.role.muted, Theme.role.ground)
        Draw.text(surface, 2, bandRow + 2, "Open Setup to add a Colossal Chest",
            regions.width - 3, Theme.role.muted, Theme.role.ground)
        return
    end
    -- A meter is worth more than the raw slot counts here: "62%" answers the question, and
    -- "420 / 3,075 slots" makes you do the arithmetic yourself.
    local meterWidth = math.max(0, math.min(10, regions.width - 26))
    local meterX = regions.width - meterWidth - 6
    self:_windowed(bandRow + 1, regions.content.bottom, #nodes,
        (state or {}).storage_scroll or 1, function(index, y)
            local node = nodes[index]
            local size = node.size or 0
            local fraction = size > 0 and ((node.occupied or 0) / size) or 0
            local percent = tostring(math.floor(fraction * 100 + 0.5)) .. "%"
            Draw.band(surface, y, Theme.role.ground)
            Draw.text(surface, 2, y, "o", 1, Theme.statusColor(node.state), Theme.role.ground)
            Draw.text(surface, 4, y, tostring(node.label or node.id),
                math.max(1, meterX - 5), Theme.role.text, Theme.role.ground)
            if meterWidth > 0 then
                local fill = fraction >= 0.9 and Theme.role.alert
                    or (fraction >= 0.75 and Theme.role.warn or Theme.role.ok)
                Draw.meter(surface, meterX, y, meterWidth, fraction, fill, Theme.role.track)
            end
            Draw.rightText(surface, regions.width - 1, y, percent,
                Theme.role.muted, Theme.role.ground)
        end)
    self:_strip(regions, model)
end
```

- [ ] **Step 5: Run the suite**

```bash
lua colossal/tests/run.lua
```

Expected: green. `test_ui_layout`'s "storage page renders nodes as separate readable rows"
asserts `"420 / 3,075 slots"`, which this replaces with a meter and a percentage — update that
assertion to `T.contains(surface.allText(),"Main Vault")` plus a percentage check, and say so
in the commit.

- [ ] **Step 6: Commit**

```bash
git add controller/colossal/app/ui.lua controller/colossal/tests/test_ui_list.lua \
        controller/colossal/tests/test_ui_pages.lua controller/colossal/tests/test_ui_layout.lua \
        controller/colossal/tests/run.lua
git commit -m "feat: meter the Nodes page and split windowing out of the list helper"
```

---

### Task 2: Requests and Alerts

**Files:**
- Modify: `controller/colossal/app/ui.lua` (`UI:_requests`, `UI:_alerts`)
- Test: `controller/colossal/tests/test_ui_pages.lua`

- [ ] **Step 1: Run the Task 1 tests that cover these pages**

```bash
lua colossal/tests/run.lua tests.test_ui_pages
```

Expected: the requests and alerts tests FAIL — no `REQUEST` or `ALERT` band exists yet.

- [ ] **Step 2: Rebuild both**

```lua
function UI:_requests(state, model)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    local bandRow = regions.content.top
    self:_band(bandRow)
    self:_bandText(2, bandRow, "REQUEST", regions.width - 2)
    Draw.rightText(surface, regions.width - 1, bandRow, "PROGRESS",
        Theme.role.muted, Theme.role.panel)
    local requests = model.requests or {}
    if #requests == 0 then
        Draw.text(surface, 2, bandRow + 1, "No requests yet", regions.width - 3,
            Theme.role.muted, Theme.role.ground)
        Draw.text(surface, 2, bandRow + 2, "Press 1 and search for an item to retrieve",
            regions.width - 3, Theme.role.muted, Theme.role.ground)
        self:_strip(regions, model)
        return
    end
    self:_list(bandRow + 1, regions.content.bottom, #requests,
        math.max(1, math.min(#requests, (state or {}).request_selection or 1)),
        function(index, y, selected)
            local request = requests[index]
            local progress = formatNumber(request.delivered or 0) .. " / " ..
                formatNumber(request.requested or 0)
            self:_row(y, selected, 1, regions.width, "o", Theme.statusColor(request.state),
                tostring(request.display_name or request.id), progress)
        end)
    self:_strip(regions, model)
end

function UI:_alerts(state, model)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    local bandRow = regions.content.top
    self:_band(bandRow)
    self:_bandText(2, bandRow, "ALERT", regions.width - 2)
    local alerts = model.alerts or {}
    if #alerts == 0 then
        Draw.text(surface, 2, bandRow + 1, "No active alerts", regions.width - 3,
            Theme.role.ok, Theme.role.ground)
        Draw.text(surface, 2, bandRow + 2, "Storage conditions are healthy",
            regions.width - 3, Theme.role.muted, Theme.role.ground)
        self:_strip(regions, model)
        return
    end
    self:_list(bandRow + 1, regions.content.bottom, #alerts,
        math.max(1, math.min(#alerts, (state or {}).alert_selection or 1)),
        function(index, y, selected)
            local alert = alerts[index]
            -- An acknowledged alert keeps its severity colour but loses its urgency marker:
            -- it is still true, it is just no longer asking for attention.
            local severity = alert.severity == "critical" and Theme.role.alert or Theme.role.warn
            self:_row(y, selected, 1, regions.width,
                alert.acknowledged and "-" or "!", severity,
                tostring(alert.message), nil)
        end)
    self:_strip(regions, model)
end
```

- [ ] **Step 3: Run the suite and commit**

```bash
lua colossal/tests/run.lua
git add controller/colossal/app/ui.lua controller/colossal/tests/test_ui_pages.lua
git commit -m "feat: rebuild the Requests and Alerts pages on the shared primitives"
```

---

### Task 3: Setup page and wizard

**Files:**
- Modify: `controller/colossal/app/ui.lua` (`UI:_setup`, `UI:_setupWizard`)
- Test: `controller/colossal/tests/test_setup_ui.lua`

- [ ] **Step 1: Write the failing test**

Add to `controller/colossal/tests/test_setup_ui.lua`:

```lua
    { name = "the wizard shows its progress and current step in the header", run = function()
        local surface = T.recordingSurface(51, 19)
        local screen = UI.new(surface)
        local state = UI.initialState()
        state.page, state.mode, state.setup_step = "setup", "setup", 3
        state.setup_choices = {{label="chest_1", detail="27 slots"}}
        screen:render(state, {})
        local text = surface.allText()
        T.contains(text, "SETUP")
        T.contains(text, "3 / 10")
        T.contains(text, "Assign Pickup")
        T.equal(surface.writesOutsideBounds(), 0)
    end },
```

- [ ] **Step 2: Run to verify it fails**

```bash
lua colossal/tests/run.lua tests.test_setup_ui
```

- [ ] **Step 3: Rebuild both**

`UI:_setup` becomes a banded summary:

```lua
function UI:_setup(model)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    local bandRow = regions.content.top
    self:_band(bandRow)
    self:_bandText(2, bandRow, "SETUP", regions.width - 2)
    Draw.text(surface, 2, bandRow + 2, "Review or change inventory roles", regions.width - 3,
        Theme.role.text, Theme.role.ground)
    local function roleLine(y, label, node)
        local state = (node or {}).state or "unassigned"
        Draw.text(surface, 2, y, label, 12, Theme.role.muted, Theme.role.ground)
        Draw.text(surface, 14, y, tostring(state), regions.width - 15,
            Theme.statusColor(state), Theme.role.ground)
    end
    roleLine(bandRow + 4, "Drop-off", model.dropoff)
    roleLine(bandRow + 5, "Pickup", model.pickup)
    Draw.text(surface, 2, bandRow + 7, "Enter opens the full setup wizard", regions.width - 3,
        Theme.role.muted, Theme.role.ground)
end
```

`UI:_setupWizard` keeps its `names` and `prompts` tables verbatim and swaps its drawing:

```lua
    local regions = Layout.regions(surface.getSize())
    Draw.band(surface, regions.header, Theme.role.panel)
    Draw.text(surface, 2, regions.header, "SETUP WIZARD", 20, Theme.role.brand, Theme.role.panel)
    local progress = tostring(state.setup_step or 1) .. " / " .. #names
    Draw.rightText(surface, regions.width - 1, regions.header, progress,
        Theme.role.text, Theme.role.panel)
    Draw.text(surface, 2, regions.content.top, names[state.setup_step or 1] or "Setup",
        regions.width - 3, Theme.role.focus, Theme.role.ground)
    Draw.text(surface, 2, regions.content.top + 1, prompts[state.setup_step or 1] or
        "Select the exact wired peripheral for this role.", regions.width - 3,
        Theme.role.muted, Theme.role.ground)
    local choices = state.setup_choices or {}
    if #choices == 0 then
        Draw.text(surface, 2, regions.content.top + 3, "No choices on this step",
            regions.width - 3, Theme.role.muted, Theme.role.ground)
    end
    self:_list(regions.content.top + 3, regions.content.bottom - 1, #choices, state.selection,
        function(index, y, selected)
            local choice = choices[index]
            self:_row(y, selected, 1, regions.width, nil, nil,
                tostring(choice.label or choice.name), choice.detail)
        end)
    local issues = state.setup_issues or (model.setup and model.setup.issues) or {}
    if #issues > 0 then
        Draw.text(surface, 2, regions.content.bottom, "! " .. tostring(issues[1].message),
            regions.width - 3, Theme.role.warn, Theme.role.ground)
    end
    Draw.band(surface, regions.footer, Theme.role.panel)
    Draw.text(surface, 2, regions.footer, "Up/Down  Enter select  Left back  Right next",
        regions.width - 3, Theme.role.text, Theme.role.panel)
    Draw.band(surface, regions.status, Theme.role.ground)
    Draw.text(surface, 2, regions.status, "F10 cancel", regions.width - 3,
        Theme.role.muted, Theme.role.ground)
```

- [ ] **Step 4: Run the suite and commit**

```bash
lua colossal/tests/run.lua
git add controller/colossal/app/ui.lua controller/colossal/tests/test_setup_ui.lua
git commit -m "feat: rebuild the Setup page and wizard on the shared foundation"
```

---

### Task 4: Delete the old helpers

**Files:**
- Modify: `controller/colossal/app/ui.lua`
- Test: `controller/colossal/tests/test_ui_purity.lua`

- [ ] **Step 1: Write the failing test**

Add to `controller/colossal/tests/test_ui_purity.lua`:

```lua
    { name = "ui.lua has no private copy of the shared drawing helpers", run = function()
        local file = io.open("colossal/app/ui.lua")
        T.equal(file ~= nil, true, "run the suite from controller/, not colossal/")
        local source = file:read("a"); file:close()
        for _, banned in ipairs({"writeClipped", "stateColor", "local palette"}) do
            T.equal(source:find(banned, 1, true), nil,
                banned .. " is still in ui.lua; app/draw.lua and app/theme.lua own it now")
        end
        -- `fill` is a common word; pin the call shape the old helper used.
        T.equal(source:find("fill(surface,", 1, true), nil,
            "the private row-fill is still in ui.lua; Draw.band owns it now")
    end },
```

- [ ] **Step 2: Run to verify it fails**

```bash
lua colossal/tests/run.lua tests.test_ui_purity
```

- [ ] **Step 3: Delete the helpers**

Remove the local `palette` table, `writeClipped`, `fill` and `stateColor` from the top of
`ui.lua`. Every remaining call site is a compile-time-visible error; run `luac -p` after each
removal. `formatNumber`, `copy` and `scrollFor` stay — they are not duplicated anywhere.

- [ ] **Step 4: Verify and commit**

```bash
luac -p colossal/app/ui.lua
lua colossal/tests/run.lua
git add controller/colossal/app/ui.lua controller/colossal/tests/test_ui_purity.lua
git commit -m "refactor: delete ui.lua's private drawing helpers

Four renderers each carried a copy of clipped-write and row-fill, and
three carried their own stateColor. This removes the last of ui.lua's,
and a test now fails if any of them come back."
```

---

### Task 5: Deploy

- [ ] **Step 1:** Confirm both computers are shut down, explicitly, in the current conversation.
- [ ] **Step 2:** `python tools/deploy.py --computers "G:/world/computercraft/computer"`, expect
  `TOTAL PROBLEMS: 0`.
- [ ] **Step 3:** Boot and check all four pages, then report.

## What this plan does not cover

`monitor.lua` and `craft_monitor.lua` still carry their own `write`, `writeCentered` and
`colorFor`. Those go in phase 4, when the monitors are rebuilt. Phase 3 is terminal clicking.
