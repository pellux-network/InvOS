# UI monitors: the wall dashboard and the craft monitor

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild both monitors in the Panelled language the terminal already uses, and delete
the last two private copies of the drawing helpers.

**Architecture:** `monitor.lua` and `craft_monitor.lua` move onto `theme`, `draw` and `layout`.
The large wall layout gains block-digit totals, per-node fill meters, an activity pane and an
alert band. The small and medium tiers keep degrading as they do now. Their private `write`,
`writeCentered`, `bar` and `colorFor` are deleted.

**Tech Stack:** Lua 5.2 target, tested on 5.4.

## Global Constraints

- **Presentation only.** No diff may touch `coordinator.lua`, `requests.lua`, `craft_service.lua`
  or anything under `core/`. The monitors receive a model and draw it.
- **Run tests from `controller/`:** `lua colossal/tests/run.lua`. Starts at 688 passing.
- **Both monitors are output-only.** No hit regions, no input. The wall monitor stays passive.
- **A monitor may be a basic (non-advanced) one**, so every colour must degrade rather than
  assume a palette. `Theme.apply` already returns false on such a surface.
- **Every render must end the frame it begins**, including early returns — see `UI:render`.
  A frame begun and never ended leaves the buffered window hidden and the screen frozen.
- Commit messages end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

### Task 1: The wall monitor

**Files:**
- Modify: `controller/colossal/app/monitor.lua`
- Test: `controller/colossal/tests/test_monitor.lua`

**Interfaces:**
- Consumes: `Draw`, `Theme`, `Layout`, and the model built by `Coordinator:_model`.
- Produces: nothing other modules call. `M.render(surface, model)` keeps its signature.

**Target large layout** at 79×24:

```
row 1      header band: INVOS | INVENTORY OPERATING SYSTEM | lifecycle
rows 3-7   block digits: total items          block digits: total types
row 8      labels under each
row 10     band: STORAGE NODES | CURRENT ACTIVITY
rows 11-14 node rows with fill meters | active request + craft
row 16     band: DROP-OFF > STORAGE > PICKUP
rows 17-19 drop-off and pickup meters
row 22     alert band, when there is an alert
row 24     enrichment or lifecycle reason
```

- [ ] **Step 1: Write the failing test**

Replace the body of `controller/colossal/tests/test_monitor.lua` with tests that pin the new
layout while keeping every existing assertion about *content* that still holds:

```lua
local Monitor = require("app.monitor")
local Theme = require("app.theme")
local T = require("tests.mock_cc")

local function model(overrides)
    local value = {
        lifecycle="READY", lifecycle_reason="all required inventories healthy",
        total_items=148302, total_types=2204,
        nodes={
            {id="dropoff", role="dropoff", label="Drop-off", state="READY", occupied=9, size=27},
            {id="s1", role="storage", label="Main Vault", state="READY", occupied=420, size=3075},
            {id="pickup", role="pickup", label="Pickup", state="READY", occupied=0, size=27},
        },
        alerts={}, requests={},
    }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

local function render(width, height, value)
    local surface = T.recordingSurface(width, height)
    Monitor.render(surface, value or model())
    return surface
end

return {
    { name = "the wall monitor leads with the number you read from a distance", run = function()
        local surface = render(79, 24)
        -- The total is drawn as block glyphs, so it is painted, not written: there is no
        -- "148,302" to search for, only a lot of brand-coloured cells in the top band.
        local painted = 0
        for y = 3, 8 do
            for x = 1, 79 do
                if surface.backgroundAt(x, y) == Theme.role.focus then painted = painted + 1 end
            end
        end
        T.truthy(painted > 100, "expected block digits, got " .. painted .. " painted cells")
        T.contains(surface.allText(), "ITEMS")
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "each node is metered, and a full one is coloured for it", run = function()
        local full = model()
        full.nodes[2].occupied, full.nodes[2].size = 2950, 3075
        local surface = render(79, 24, full)
        T.contains(surface.allText(), "Main Vault")
        local alerted = 0
        for y = 1, 24 do
            for x = 1, 79 do
                if surface.backgroundAt(x, y) == Theme.role.alert then alerted = alerted + 1 end
            end
        end
        T.truthy(alerted > 0, "a node at 96 percent must not be metered in the healthy colour")
    end },
    { name = "the active request is shown with its progress", run = function()
        local surface = render(79, 24, model({requests={
            {id="r1", display_name="Iron Ingot", state="TRANSFERRING", delivered=16, requested=64},
        }, active_request={id="r1", display_name="Iron Ingot", state="TRANSFERRING",
            delivered=16, requested=64}}))
        local text = surface.allText()
        T.contains(text, "Iron Ingot")
        T.contains(text, "16 / 64")
    end },
    { name = "no activity says so rather than leaving a hole", run = function()
        T.contains(render(79, 24).allText(), "No active request")
    end },
    { name = "the highest alert gets a band of its own", run = function()
        local surface = render(79, 24, model({alerts={
            {key="a", severity="critical", message="Pickup is full", acknowledged=false},
        }, highest_alert={key="a", severity="critical", message="Pickup is full"}}))
        T.contains(surface.allText(), "Pickup is full")
    end },
    { name = "the medium tier keeps the totals and the flow", run = function()
        local surface = render(40, 13)
        local text = surface.allText()
        T.contains(text, "INVOS")
        T.contains(text, "148,302")
        T.contains(text, "READY")
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "the small tier still names the product and the totals", run = function()
        local surface = render(20, 7)
        local text = surface.allText()
        T.contains(text, "INVOS")
        T.contains(text, "148,302")
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "the monitor never draws outside its surface at any size", run = function()
        for _, size in ipairs({{79,24},{57,20},{45,14},{40,13},{24,8},{20,7},{15,5},{8,3}}) do
            local surface = render(size[1], size[2], model({alerts={
                {key="a", severity="critical", message="Pickup is full"}},
                highest_alert={key="a", severity="critical", message="Pickup is full"}}))
            T.equal(surface.writesOutsideBounds(), 0,
                size[1] .. "x" .. size[2] .. " drew outside")
        end
    end },
    { name = "enrichment progress replaces the lifecycle reason while learning", run = function()
        local surface = render(79, 24, model({enrichment={learned=1200, total=3000}}))
        local text = surface.allText()
        T.contains(text, "1,200")
        T.equal(text:find("all required inventories healthy", 1, true), nil)
    end },
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
lua colossal/tests/run.lua tests.test_monitor
```

Expected: the block-digit, node meter and alert band tests FAIL.

- [ ] **Step 3: Rebuild `monitor.lua`**

Delete the private `palette`, `colorFor`, `write`, `writeCentered` and `line`, and require
`app/draw.lua` and `app/theme.lua` instead. `formatNumber` stays — it is not duplicated.

`renderLarge(surface, model, width, height)` becomes, in order: a header band with the
wordmark in `Theme.role.brand` and the lifecycle right-aligned in `Theme.statusColor`; the item
total via `Draw.blockText` in `Theme.role.focus` starting at row 3, with `Draw.blockText`
returning the column after it so the type total can be placed beside it; labels beneath both; a
`STORAGE NODES` / `CURRENT ACTIVITY` band; one row per node with `Draw.meter`, using
`Theme.role.alert` at 90 percent, `Theme.role.warn` at 75, otherwise `Theme.role.ok`; the
active request with a delivery meter or `No active request`; a centred
`DROP-OFF  >  STORAGE  >  PICKUP` band; drop-off and pickup meters; an alert band in
`Theme.role.alert` when `model.highest_alert` exists; and the enrichment line or lifecycle
reason on the last row.

`renderMedium` and `renderSmall` keep their current content and move onto `Draw.text`,
`Draw.band` and `Theme.role`.

Frame the render exactly as `UI:render` does — single entry and exit, so `beginFrame` and
`endFrame` always pair:

```lua
function M.render(surface, model)
    if surface.beginFrame then surface.beginFrame() end
    local ok, reason = pcall(renderFrame, surface, model or {})
    if surface.endFrame then surface.endFrame() end
    if not ok then error(reason, 0) end
end
```

- [ ] **Step 4: Run the suite and commit**

```bash
lua colossal/tests/run.lua
git add controller/colossal/app/monitor.lua controller/colossal/tests/test_monitor.lua
git commit -m "feat: rebuild the wall monitor in the Panelled language"
```

---

### Task 2: The craft monitor

**Files:**
- Modify: `controller/colossal/app/craft_monitor.lua`
- Test: `controller/colossal/tests/test_craft_monitor.lua`

- [ ] **Step 1: Write the failing test**

Add to `controller/colossal/tests/test_craft_monitor.lua`:

```lua
    {name="the craft monitor uses the shared palette and meter",run=function()
        local Theme = require("app.theme")
        local surface = T.recordingSurface(15, 10)
        CraftMonitor.render(surface, {active={item="minecraft:chest",
            display_name="Chest", state="STAGING", done=2, total=8}, queued=1})
        local metered = 0
        for y = 1, 10 do
            for x = 1, 15 do
                if surface.backgroundAt(x, y) == Theme.role.track
                    or surface.backgroundAt(x, y) == Theme.role.craft then metered = metered + 1 end
            end
        end
        T.truthy(metered > 0, "progress must be a meter, not a bracketed ASCII bar")
        T.contains(surface.allText(), "Chest")
    end},
    {name="the craft monitor ends every frame it begins",run=function()
        local frames = {begun=0, ended=0}
        local surface = T.recordingSurface(15, 10)
        surface.beginFrame = function() frames.begun = frames.begun + 1 end
        surface.endFrame = function() frames.ended = frames.ended + 1 end
        CraftMonitor.render(surface, {})
        CraftMonitor.render(surface, {active={item="x", state="STAGING"}})
        T.equal(frames.ended, frames.begun)
    end},
```

- [ ] **Step 2: Run to verify it fails, then rebuild**

Delete the private `palette`, `colorFor`, `write` and `bar`. `shortName` stays — it is specific
to this module and not duplicated. Replace the bracketed ASCII bar with `Draw.meter` in
`Theme.role.craft` over `Theme.role.track`, and frame the render with the same single
entry and exit as Task 1.

- [ ] **Step 3: Run the suite and commit**

```bash
lua colossal/tests/run.lua
git add controller/colossal/app/craft_monitor.lua controller/colossal/tests/test_craft_monitor.lua
git commit -m "feat: rebuild the craft monitor on the shared foundation"
```

---

### Task 3: Delete the last private helpers

- [ ] **Step 1: Extend the guard test**

In `controller/colossal/tests/test_ui_purity.lua`, extend the helper check to cover all three
renderers:

```lua
    { name = "no renderer keeps a private copy of the shared helpers", run = function()
        for _, module in ipairs({"ui", "monitor", "craft_monitor"}) do
            local file = io.open("colossal/app/" .. module .. ".lua")
            T.equal(file ~= nil, true, "run the suite from controller/")
            local source = file:read("a"); file:close()
            for _, banned in ipairs({"local palette", "local function colorFor",
                "local function writeCentered", "local function writeClipped"}) do
                T.equal(source:find(banned, 1, true), nil,
                    banned .. " is still in " .. module .. ".lua")
            end
        end
    end },
```

- [ ] **Step 2: Run, confirm green, commit**

```bash
lua colossal/tests/run.lua
git add controller/colossal/tests/test_ui_purity.lua
git commit -m "test: fail if any renderer grows its own drawing helpers again"
```

---

### Task 4: Deploy

- [ ] **Step 1:** Confirm both computers are shut down, explicitly, in the current conversation.
- [ ] **Step 2:** `python tools/deploy.py --computers "G:/world/computercraft/computer"`.
- [ ] **Step 3:** Boot and look at both monitors. The wall monitor is the surface this whole
  visual system was aimed at; report anything that reads wrong at a distance.

## What remains after this

Phase 3, terminal clicking: nav tabs and action buttons. Search and Crafting list rows already
emit hit regions, so this is the smallest phase left.
