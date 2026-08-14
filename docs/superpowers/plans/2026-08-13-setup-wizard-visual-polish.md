# Setup Wizard Visual Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the setup wizard's rendering (`UI:_setupWizard`, `UI:_setupRename`) so nothing is ever text-truncated, every card and control is mouse-clickable, and the wizard reads as a boxed-card dialog built from the same primitives (`Draw.band`, `UI:_row`, section bands) every other InvOS page already uses.

**Architecture:** Four additive pieces on top of the existing wizard data flow (`state.setup_choices`/`setup_issues`/`setup_summary`, unchanged from the prior UX pass): a private `wrapText` helper, a new `UI:_cardWindow`/`UI:_cardDetail` pair for two-row card lists (parallel to, not a rewrite of, `UI:_windowed`/`UI:_list`), a `baseBg` parameter added to `UI:_row` (defaults preserve every other page's behavior), and real `hit_regions` returned from the wizard's two render functions instead of the hardcoded empty table today. No changes to `app/setup.lua`, `main.lua`, or `app/keymap.lua` — mouse clicks already route generically through `keymap.lua`'s existing `hitCommand`, and the new click command reduces to the exact same `SETUP_SELECT` effect Enter already produces.

**Tech Stack:** Lua (CC:Tweaked), `tests/mock_cc.lua`, `tests/run.lua`.

**Spec:** `docs/superpowers/specs/2026-08-13-setup-wizard-visual-polish-design.md`

## Global Constraints

- No change to `app/setup.lua`, `main.lua`'s `setupChoices`/`syncSetup`/`onEffect`, or `app/keymap.lua` — this plan is `app/ui.lua` only, plus its tests.
- `UI:_row`'s new `baseBg` parameter must default to `Theme.role.ground` when omitted — every existing call site (Search, Storage, Requests, Alerts, Crafting) must render identically to before.
- `UI:_windowed`/`UI:_list` are untouched — the new `UI:_cardWindow` is a parallel method, not a modification.
- Nothing may write outside the terminal bounds (`surface.writesOutsideBounds() == 0` in every render test) at 51×19, the size used throughout the test suite.
- `lua storage/tests/run.lua` (run from `controller/`) must pass with 0 failures before any task is considered done.

---

## Task 1: `UI:_row` gains an optional base background

**Files:**
- Modify: `controller/storage/app/ui.lua:465-481` (`UI:_row`)
- Test: `controller/storage/tests/test_setup_ui.lua`

**Interfaces:**
- Produces: `UI:_row(y, selected, from, to, marker, markerColor, left, right, rightColor, baseBg)` — `baseBg` is the 10th, optional parameter. When selected, the row still fills `Theme.role.focus` exactly as before; when not selected, it fills `baseBg` if given, else `Theme.role.ground` (today's hardcoded behavior). Task 2 depends on this to draw cards on a panel background instead of ground.

- [ ] **Step 1: Write the failing test**

Append to `controller/storage/tests/test_setup_ui.lua` (this file already `require`s `Theme`):

```lua
    {name="UI:_row defaults to the ground background and accepts a custom one",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        ui:_row(5,false,1,51,nil,nil,"label",nil)
        T.equal(surface.backgroundAt(2,5),Theme.role.ground)
        ui:_row(6,false,1,51,nil,nil,"label",nil,nil,Theme.role.panel)
        T.equal(surface.backgroundAt(2,6),Theme.role.panel)
        ui:_row(7,true,1,51,nil,nil,"label",nil,nil,Theme.role.panel)
        T.equal(surface.backgroundAt(2,7),Theme.role.focus)
    end},
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua storage/tests/run.lua tests.test_setup_ui` (from `controller/`)
Expected: FAIL — `UI:_row` today has no 10th parameter, so row 6's background stays `Theme.role.ground` instead of `Theme.role.panel`.

- [ ] **Step 3: Write minimal implementation**

Replace `controller/storage/app/ui.lua:465-481`:

```lua
-- One list row: an optional status marker, a name, and a right-aligned value. Selection is a
-- filled row in the focus colour with inverted text -- the same on every page. The pages used
-- to disagree, Search filling red and Crafting filling grey, which read as two products.
-- `baseBg` lets a caller draw on something other than the ground colour (the setup wizard's
-- panel-toned card) without changing the four pages that don't pass it.
function UI:_row(y, selected, from, to, marker, markerColor, left, right, rightColor, baseBg)
    local surface = self.surface
    local background = selected and Theme.role.focus or (baseBg or Theme.role.ground)
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua storage/tests/run.lua tests.test_setup_ui` (from `controller/`)
Expected: PASS, all tests in the file green.

- [ ] **Step 5: Run the full suite**

Run: `lua storage/tests/run.lua` (from `controller/`)
Expected: `RESULT N passed, 0 failed` — confirms Search/Storage/Requests/Alerts/Crafting, which all call `UI:_row` without a 10th argument, are unaffected.

- [ ] **Step 6: Commit**

```bash
git add controller/storage/app/ui.lua controller/storage/tests/test_setup_ui.lua
git commit -m "feat: UI:_row accepts a custom base background"
```

---

## Task 2: Boxed-card chrome, wrapping, and two-row card list

**Files:**
- Modify: `controller/storage/app/ui.lua` (new local `wrapText`; new `UI:_cardWindow`, `UI:_cardDetail`; full rewrite of `UI:_setupWizard`, `controller/storage/app/ui.lua:901-976` today)
- Test: `controller/storage/tests/test_setup_ui.lua`

**Interfaces:**
- Consumes: `UI:_row(..., baseBg)` from Task 1.
- Produces: local `wrapText(text, width, maxLines)` returning an array of strings (always at least one, possibly empty), greedy word wrap, hard-cuts a single overlong word, drops content past `maxLines` when given. `UI:_cardWindow(top, bottom, count, selection, rows, render)` — like `UI:_windowed` but each item occupies `rows` physical rows; calls `render(index, y)` for each visible item's starting row. `UI:_cardDetail(y, selected, from, to, text, baseBg)` — draws a card's second physical row with the same selection-state fill `UI:_row` uses. This task does **not** yet populate real hit regions — `_setupWizard` still returns `{hit_regions={}}` at the end of this task; Task 3 adds mouse.

- [ ] **Step 1: Write the failing tests**

Append to `controller/storage/tests/test_setup_ui.lua`, replacing nothing yet (Step 3 below also *fixes* one existing test that hardcodes a now-stale coordinate — that edit is called out separately):

```lua
    {name="a long prompt wraps to multiple lines instead of being cut off",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        -- step 1's real prompt is 60 characters, well past the ~45-character card width.
        state.mode,state.page,state.setup_step="setup","setup",1
        state.setup_choices={{label="Continue with 3 inventories",detail="read-only discovery"}}
        state.setup_choice_count=1
        ui:render(state,{})
        local text=surface.allText()
        T.contains(text,"Read-only discovery of the wired")
        T.contains(text,"inventories on the network.")
        T.equal(surface.writesOutsideBounds(),0)
    end},
    {name="a long validation message wraps across both lines of its card",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",9
        state.setup_choices={
            {label="Run validation and continue",detail="moves no items"},
            {label="chest_4 and chest_6 may expose the same storage container",
                blocking=true,detail="Enter confirms distinct"},
        }
        state.setup_choice_count=2
        state.selection=1
        ui:render(state,{})
        local text=surface.allText()
        T.contains(text,"chest_4 and chest_6 may expose the same")
        T.contains(text,"storage container")
        T.equal(surface.writesOutsideBounds(),0)
    end},
    {name="the wizard content band is a panel-coloured card inset from the ground",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",2
        state.setup_choices={{name="drop",label="drop",detail="27 slots"}}
        state.setup_choice_count=1
        ui:render(state,{})
        -- Column 1 stays ground (the card's margin); column 2 is inside the card.
        T.equal(surface.backgroundAt(1,5),Theme.role.ground)
        T.equal(surface.backgroundAt(2,5),Theme.role.panel)
        T.equal(surface.writesOutsideBounds(),0)
    end},
    {name="the section band inside the card uses the track colour",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",2
        state.setup_choices={{name="drop",label="drop",detail="27 slots"}}
        state.setup_choice_count=1
        ui:render(state,{})
        local bandRow
        for y=1,19 do if surface.line(y):find("INVENTORY",1,true) then bandRow=y end end
        T.truthy(bandRow,"expected an INVENTORY band somewhere on screen")
        T.equal(surface.backgroundAt(3,bandRow),Theme.role.track)
    end},
    {name="a selected card fills both its title and detail row",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",4
        state.setup_choices={{name="chest_0",label="[added] chest_0",detail="as \"Vault A\""}}
        state.setup_choice_count=1
        state.selection=1
        ui:render(state,{})
        -- "Vault A" is the detail text (card row 2); its title sits one row above it.
        local detailRow
        for y=1,19 do if surface.line(y):find("Vault A",1,true) then detailRow=y end end
        T.truthy(detailRow)
        T.equal(surface.backgroundAt(3,detailRow-1),Theme.role.focus)
        T.equal(surface.backgroundAt(3,detailRow),Theme.role.focus)
    end},
    {name="Review lists each bound role as label/value before the Save card",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",10
        state.setup_choices={{label="Save configuration and enable",detail="starts immediately"}}
        state.setup_choice_count=1
        state.selection=1
        state.setup_summary={
            {label="Drop-off",detail="chest_0"},{label="Pickup",detail="chest_5"},
            {label="Storage nodes",detail="3 enabled / 3 total"},
        }
        ui:render(state,{})
        local text=surface.allText()
        T.contains(text,"Drop-off")
        T.contains(text,"chest_0")
        T.contains(text,"Save configuration and enable")
        T.equal(surface.writesOutsideBounds(),0)
    end},
```

Now fix the one existing test that hardcodes a coordinate the new dynamic layout invalidates — find it in `controller/storage/tests/test_setup_ui.lua` (added in the prior pass, named `"Validate step renders a blocking issue with an alert marker"`) and replace its body:

```lua
    {name="Validate step renders a blocking issue with an alert marker",run=function()
        local surface = T.recordingSurface(51, 19)
        local ui = UI.new(surface)
        local state = UI.initialState()
        state.mode, state.page, state.setup_step = "setup", "setup", 9
        state.setup_choices = {
            {label="Run validation and continue", detail="moves no items"},
            {label="Assign a Drop-off inventory", blocking=true},
        }
        state.setup_choice_count = 2
        state.selection = 1
        ui:render(state, {})
        local markerRow
        for y = 1, 19 do
            if surface.line(y):find("Assign a Drop%-off inventory", 1, true) then markerRow = y end
        end
        T.truthy(markerRow, "expected the blocking issue's row to be found")
        T.equal(surface.foregroundAt(3, markerRow), Theme.role.alert)
        T.equal(surface.writesOutsideBounds(), 0)
    end},
```

(The marker moved from column 2 to column 3 because cards start at `cardFrom = 2` and `UI:_row` draws its marker at `from + 1`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua storage/tests/run.lua tests.test_setup_ui` (from `controller/`)
Expected: FAIL on every new test, and the updated marker test fails against the still-unmodified renderer.

- [ ] **Step 3: Write minimal implementation**

Add `wrapText` near the other private text helpers in `controller/storage/app/ui.lua` (by `fittedLabel`, around line 36):

```lua
-- Greedy word wrap. A word longer than `width` is hard-cut rather than left to overflow --
-- today's vocabulary (peripheral names, short prose) never produces one, but a future long
-- identifier must not corrupt the layout. `maxLines`, when given, caps the return; content
-- past it is simply dropped, and the caller decides whether that's acceptable (the wizard's
-- card renderer prefers the wrapped message over its detail hint when both can't fit).
local function wrapText(text, width, maxLines)
    text = tostring(text or "")
    width = math.max(1, width or 1)
    local lines = {}
    local current = ""
    local capped = false
    for word in text:gmatch("%S+") do
        if maxLines and #lines >= maxLines then capped = true; break end
        local candidate = current == "" and word or (current .. " " .. word)
        if #candidate <= width then
            current = candidate
        else
            if current ~= "" then lines[#lines + 1] = current end
            while #word > width do
                if maxLines and #lines >= maxLines then capped = true; break end
                lines[#lines + 1] = word:sub(1, width)
                word = word:sub(width + 1)
            end
            current = capped and "" or word
        end
    end
    if not capped and current ~= "" then lines[#lines + 1] = current end
    if maxLines then
        for index = #lines, maxLines + 1, -1 do lines[index] = nil end
    end
    if #lines == 0 then lines[1] = "" end
    return lines
end
```

Add `UI:_cardWindow` and `UI:_cardDetail` directly after `UI:_row` (`controller/storage/app/ui.lua`, after the function Task 1 just edited):

```lua
-- Like _windowed, but each item occupies `rows` physical rows instead of one -- the
-- wizard's cards need a second line for detail text or a wrapped continuation. _list and
-- _windowed themselves are untouched; every other page keeps its one-row-per-item math.
function UI:_cardWindow(top, bottom, count, selection, rows, render)
    local visible = math.max(0, math.floor((bottom - top + 1) / rows))
    local scroll = scrollFor(selection, count, visible)
    for offset = 0, visible - 1 do
        local index = scroll + offset
        if index > count then break end
        render(index, top + offset * rows)
    end
    return scroll, visible
end

-- A card's second physical row: fills with the same selection-state background UI:_row
-- uses, so a selected card highlights as one solid two-row block, not a highlighted title
-- over a plain detail line.
function UI:_cardDetail(y, selected, from, to, text, baseBg)
    local surface = self.surface
    local background = selected and Theme.role.focus or (baseBg or Theme.role.ground)
    Draw.band(surface, y, background, from, to)
    if text and text ~= "" then
        Draw.text(surface, from + 3, y, tostring(text), math.max(1, (to - from + 1) - 4),
            selected and Theme.role.ground or Theme.role.muted, background)
    end
end
```

Replace all of `controller/storage/app/ui.lua:901-976` (the current `UI:_setupWizard`, from `function UI:_setupWizard(state, model)` through its closing `end`) with:

```lua
function UI:_setupWizard(state, model)
    local surface = self.surface
    -- One title and one prompt per step. Both lists must cover every step: a missing
    -- entry falls back to a generic "select an inventory" line, which is actively wrong
    -- on the turtle and monitor steps and reads as if the wizard is asking again for a
    -- chest it already has.
    local names = {
        "Discover inventories", "Assign Drop-off", "Assign Pickup", "Storage nodes",
        "Craft buffer (optional)", "Crafting turtle (optional)",
        "Main monitor (optional)", "Crafting monitor (optional)",
        "Validate layout", "Review and enable",
    }
    local prompts = {
        "Read-only discovery of the wired inventories on the network.",
        "The inventory players deposit into, for importing.",
        "The inventory retrievals are delivered to, for collecting.",
        "Toggle which inventories pool together as storage.",
        "The chest directly beneath the crafting turtle. Not Pickup.",
        "The crafting turtle itself, not a chest.",
        "The large status monitor. Skip to auto-detect.",
        "The small monitor showing craft progress. Not a chest.",
        "Read-only validation. Moves no items.",
        "Save the configuration and start.",
    }
    -- A band adds nothing on a single-choice step (Discover, Review's lone Save card), so
    -- those stay nil.
    local bandLabels = {
        nil, "INVENTORY", "INVENTORY", "INVENTORY",
        "INVENTORY", "TURTLE", "MONITOR", "MONITOR",
        "CHECKS", nil,
    }
    local step = state.setup_step or 1
    local regions = Layout.regions(surface.getSize())

    Draw.band(surface, regions.header, Theme.role.panel)
    Draw.text(surface, 2, regions.header, "SETUP WIZARD", 20, Theme.role.brand, Theme.role.panel)
    local progress = tostring(step) .. " / " .. #names
    Draw.rightText(surface, regions.width - 1, regions.header, progress, Theme.role.text, Theme.role.panel)

    -- The card reclaims the nav row and strip row the wizard never used, as pure top/bottom
    -- padding, and never grows into the header or footer regardless of terminal height.
    local cardFrom, cardTo = 2, regions.width - 1
    local cardTop = math.max(regions.header + 1, regions.content.top - 1)
    local cardBottom = math.min(regions.footer - 1, regions.content.bottom + 1)
    for y = cardTop, cardBottom do Draw.band(surface, y, Theme.role.panel, cardFrom, cardTo) end

    local promptWidth = math.max(10, cardTo - cardFrom - 1)
    local cardTextWidth = math.max(6, (cardTo - cardFrom + 1) - 4)

    Draw.text(surface, 2, regions.content.top, names[step] or "Setup", regions.width - 3,
        Theme.role.focus, Theme.role.panel)
    local promptLines = wrapText(prompts[step] or
        "Select the exact wired peripheral for this role.", promptWidth, 3)
    for index, line in ipairs(promptLines) do
        Draw.text(surface, 2, regions.content.top + index, line, regions.width - 3,
            Theme.role.muted, Theme.role.panel)
    end

    local y = regions.content.top + #promptLines + 2
    if step == 10 then
        for _, row in ipairs(state.setup_summary or {}) do
            if y > cardBottom then break end
            Draw.text(surface, cardFrom + 1, y, tostring(row.label), 20, Theme.role.muted, Theme.role.panel)
            Draw.rightText(surface, cardTo - 1, y, tostring(row.detail), Theme.role.text, Theme.role.panel)
            y = y + 1
        end
        y = y + 1
    end

    local bandLabel = bandLabels[step]
    if bandLabel then
        Draw.band(surface, y, Theme.role.track, cardFrom, cardTo)
        Draw.text(surface, cardFrom + 1, y, bandLabel, 30, Theme.role.muted, Theme.role.track)
        y = y + 1
    end

    local choices = state.setup_choices or {}
    if #choices == 0 then
        Draw.text(surface, cardFrom + 1, y, "No choices on this step", cardTextWidth,
            Theme.role.muted, Theme.role.panel)
    end
    self:_cardWindow(y, cardBottom, #choices, state.selection, 2,
        function(index, cardY)
            local choice = choices[index]
            local selected = index == state.selection
            local marker, markerColor
            if choice.blocking ~= nil then
                marker = choice.blocking and "!" or "i"
                markerColor = choice.blocking and Theme.role.alert or Theme.role.warn
            end
            local labelLines = wrapText(tostring(choice.label or choice.name or ""), cardTextWidth, 2)
            local secondLine = (#labelLines > 1) and labelLines[2] or choice.detail
            self:_row(cardY, selected, cardFrom, cardTo, marker, markerColor,
                labelLines[1], nil, nil, Theme.role.panel)
            self:_cardDetail(cardY + 1, selected, cardFrom, cardTo, secondLine, Theme.role.panel)
        end)

    Draw.band(surface, regions.footer, Theme.role.panel)
    local footerX = 2
    local function footerSegment(text)
        Draw.text(surface, footerX, regions.footer, text, #text, Theme.role.text, Theme.role.panel)
        footerX = footerX + #text + 2
    end
    if step == 4 then
        footerSegment("Up/Down Enter")
        footerSegment("Left back")
        footerSegment("Right next")
        footerSegment("R rename")
    else
        footerSegment("Up/Down")
        footerSegment("Enter select")
        footerSegment("Left back")
        footerSegment("Right next")
    end

    Draw.band(surface, regions.status, Theme.role.ground)
    Draw.text(surface, 2, regions.status, "F10 cancel", regions.width - 3,
        Theme.role.muted, Theme.role.ground)
    surface.setCursorBlink(false)
    return {hit_regions = {}}
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `lua storage/tests/run.lua tests.test_setup_ui` (from `controller/`)
Expected: PASS, all green.

- [ ] **Step 5: Run the full suite**

Run: `lua storage/tests/run.lua` (from `controller/`)
Expected: `RESULT N passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add controller/storage/app/ui.lua controller/storage/tests/test_setup_ui.lua
git commit -m "feat: setup wizard uses a boxed panel card with wrapped, two-line cards"
```

---

## Task 3: Mouse support for the wizard

**Files:**
- Modify: `controller/storage/app/ui.lua` (`UI:reduce`: new `SETUP_ACTIVATE` branch; `UI:_setupWizard`: real `hitRegions`)
- Test: `controller/storage/tests/test_setup_ui.lua`, `controller/storage/tests/test_setup_wizard_flow.lua`

**Interfaces:**
- Produces: command `SETUP_ACTIVATE {index}` (UI-local — sets `state.selection` to `index`, then returns the *same* `SETUP_SELECT` effect Enter already produces, so `main.lua`'s `onEffect` needs no new branch). `_setupWizard` now returns real hit regions: one per card (spanning both its physical rows) firing `SETUP_ACTIVATE`, one each for the footer's "Left back"/"Right next"/(step 4 only) "R rename" segments firing `SETUP_BACK`/`SETUP_NEXT`/`RENAME_STORAGE_REQUEST`, and one for the status line's "F10 cancel" firing `CANCEL_SETUP`.

- [ ] **Step 1: Write the failing tests**

Append to `controller/storage/tests/test_setup_ui.lua`:

```lua
    {name="SETUP_ACTIVATE selects the clicked card and produces the same effect as Enter",run=function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",4
        state.setup_choices={{label="a"},{label="b"},{label="c"}}
        state.setup_choice_count=3
        state.selection=1
        local nextState,effect=ui:reduce(state,{type="SETUP_ACTIVATE",index=3})
        T.equal(nextState.selection,3)
        T.equal(effect.type,"SETUP_SELECT")
        T.equal(effect.step,4)
        T.equal(effect.index,3)
    end},
    {name="every wizard card and footer control is clickable",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",4
        state.setup_choices={{name="chest_0",label="chest_0",detail="27 slots"},
            {name="chest_3",label="chest_3",detail="27 slots"}}
        state.setup_choice_count=2
        state.selection=1
        local layout=ui:render(state,{})
        local kinds={}
        for _,region in ipairs(layout.hit_regions) do kinds[region.command.type]=true end
        T.truthy(kinds.SETUP_ACTIVATE)
        T.truthy(kinds.SETUP_BACK)
        T.truthy(kinds.SETUP_NEXT)
        T.truthy(kinds.RENAME_STORAGE_REQUEST)
        T.truthy(kinds.CANCEL_SETUP)
    end},
```

Append to `controller/storage/tests/test_setup_wizard_flow.lua`:

```lua
    {name="clicking a card does what pressing Enter on it would do",run=function()
        local coordinator = Main.build(environment())
        coordinator:handle({"key", keys.right}) -- 1 -> 2
        local model = coordinator:viewModel()
        local cardRegion
        for _, region in ipairs(model.ui.hit_regions or {}) do
            if region.command.type == "SETUP_ACTIVATE" then cardRegion = region end
        end
        T.truthy(cardRegion, "expected at least one clickable card on step 2")
        coordinator:handle({"mouse_click", 1, cardRegion.x1, cardRegion.y1})
        T.equal(coordinator:viewModel().ui.setup_step, 3)
    end},
    {name="clicking F10 cancels setup the same as pressing it",run=function()
        local coordinator = Main.build(environment())
        local model = coordinator:viewModel()
        local cancelRegion
        for _, region in ipairs(model.ui.hit_regions or {}) do
            if region.command.type == "CANCEL_SETUP" then cancelRegion = region end
        end
        T.truthy(cancelRegion)
        coordinator:handle({"mouse_click", 1, cancelRegion.x1, cancelRegion.y1})
        T.equal(coordinator:viewModel().ui.mode, "page")
    end},
}
```

(That closing `}` replaces the file's existing closing `}` — this is the last test in the file.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua storage/tests/run.lua tests.test_setup_ui tests.test_setup_wizard_flow` (from `controller/`)
Expected: FAIL — `SETUP_ACTIVATE` doesn't exist yet, and `_setupWizard` still returns an empty `hit_regions` table.

- [ ] **Step 3: Write minimal implementation**

In `controller/storage/app/ui.lua`'s `UI:reduce`, add a new branch next to `SETUP_SELECT`:

```lua
    elseif kind == "SETUP_ACTIVATE" then
        state.selection = math.max(1, math.min(math.max(1, state.setup_choice_count or 0),
            command.index or 1))
        return state, {type="SETUP_SELECT", step=state.setup_step, index=state.selection}
```

In `UI:_setupWizard` (from Task 2), add a `local hitRegions = {}` near the top (right after `local regions = Layout.regions(surface.getSize())`), register one hit region per card inside the `_cardWindow` callback, register one per footer segment via `footerSegment`, register one for the status line, and change the final return. Concretely:

- After `local regions = Layout.regions(surface.getSize())`: add `local hitRegions = {}`.
- Inside the `_cardWindow` callback, after drawing the card (after the `self:_cardDetail(...)` call), add:
  ```lua
            hitRegions[#hitRegions + 1] = {x1=cardFrom, y1=cardY, x2=cardTo, y2=cardY + 1,
                command={type="SETUP_ACTIVATE", index=index}}
  ```
- Change `footerSegment` to optionally take a command and register it:
  ```lua
    local function footerSegment(text, command)
        Draw.text(surface, footerX, regions.footer, text, #text, Theme.role.text, Theme.role.panel)
        if command then
            hitRegions[#hitRegions + 1] = {x1=footerX, y1=regions.footer,
                x2=footerX + #text - 1, y2=regions.footer, command=command}
        end
        footerX = footerX + #text + 2
    end
    if step == 4 then
        footerSegment("Up/Down Enter")
        footerSegment("Left back", {type="SETUP_BACK"})
        footerSegment("Right next", {type="SETUP_NEXT"})
        footerSegment("R rename", {type="RENAME_STORAGE_REQUEST"})
    else
        footerSegment("Up/Down")
        footerSegment("Enter select")
        footerSegment("Left back", {type="SETUP_BACK"})
        footerSegment("Right next", {type="SETUP_NEXT"})
    end
  ```
- Replace the status-line block:
  ```lua
    Draw.band(surface, regions.status, Theme.role.ground)
    local cancelText = "F10 cancel"
    Draw.text(surface, 2, regions.status, cancelText, regions.width - 3,
        Theme.role.muted, Theme.role.ground)
    hitRegions[#hitRegions + 1] = {x1=2, y1=regions.status, x2=1 + #cancelText,
        y2=regions.status, command={type="CANCEL_SETUP"}}
    surface.setCursorBlink(false)
    return {hit_regions = hitRegions}
  end
  ```

- [ ] **Step 4: Run tests to verify they pass**

Run: `lua storage/tests/run.lua tests.test_setup_ui tests.test_setup_wizard_flow` (from `controller/`)
Expected: PASS, all green.

- [ ] **Step 5: Run the full suite**

Run: `lua storage/tests/run.lua` (from `controller/`)
Expected: `RESULT N passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add controller/storage/app/ui.lua controller/storage/tests/test_setup_ui.lua controller/storage/tests/test_setup_wizard_flow.lua
git commit -m "feat: setup wizard cards, back/next, rename, and cancel are clickable"
```

---

## Task 4: Boxed chrome, wrapping, and mouse for the rename screen

**Files:**
- Modify: `controller/storage/app/ui.lua` (full rewrite of `UI:_setupRename`, `controller/storage/app/ui.lua:978-996` today)
- Test: `controller/storage/tests/test_setup_ui.lua`, `controller/storage/tests/test_setup_wizard_flow.lua`

**Interfaces:**
- Consumes: `wrapText`, the boxed-card fill technique, and the `footerSegment` pattern, all from Tasks 2-3.
- Produces: `_setupRename` returns real hit regions for "Enter save" (`RENAME_CONFIRM`) and "Left/F10 cancel" (`RENAME_CANCEL`).

- [ ] **Step 1: Write the failing tests**

Append to `controller/storage/tests/test_setup_ui.lua`:

```lua
    {name="the rename screen is boxed, wraps its hint text, and is clickable",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup_rename","setup",4
        state.setup_rename_id,state.setup_rename_text="storage_1","chest_3"
        local layout=ui:render(state,{})
        T.equal(surface.backgroundAt(1,5),Theme.role.ground)
        T.equal(surface.backgroundAt(2,5),Theme.role.panel)
        local text=surface.allText()
        T.contains(text,"Shown on the Storage page")
        T.contains(text,"instead of the peripheral name.")
        T.equal(surface.writesOutsideBounds(),0)
        local kinds={}
        for _,region in ipairs(layout.hit_regions) do kinds[region.command.type]=true end
        T.truthy(kinds.RENAME_CONFIRM)
        T.truthy(kinds.RENAME_CANCEL)
    end},
```

Append to `controller/storage/tests/test_setup_wizard_flow.lua` (before the file's final closing `}`):

```lua
    {name="clicking Enter save on the rename screen confirms the new label",run=function()
        local inventories = {drop=chestInventory(27), pick=chestInventory(27), vault=chestInventory(3075)}
        local coordinator, services = Main.build(environment(inventories))
        coordinator:handle({"key", keys.right})
        coordinator:handle({"key", keys.enter})
        coordinator:handle({"key", keys.down})
        coordinator:handle({"key", keys.enter})
        coordinator:handle({"key", keys.enter}) -- add "vault", opens rename
        coordinator:handle({"char", "!"})
        local model = coordinator:viewModel()
        T.equal(model.ui.mode, "setup_rename")
        local saveRegion
        for _, region in ipairs(model.ui.hit_regions or {}) do
            if region.command.type == "RENAME_CONFIRM" then saveRegion = region end
        end
        T.truthy(saveRegion)
        coordinator:handle({"mouse_click", 1, saveRegion.x1, saveRegion.y1})
        T.equal(coordinator:viewModel().ui.mode, "setup")
        T.equal(services.setup:draft().storage[1].label, "vault!")
    end},
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua storage/tests/run.lua tests.test_setup_ui tests.test_setup_wizard_flow` (from `controller/`)
Expected: FAIL — `_setupRename` still draws on the ground colour with an empty `hit_regions` table.

- [ ] **Step 3: Write minimal implementation**

Replace all of `controller/storage/app/ui.lua:978-996` (the current `UI:_setupRename`) with:

```lua
function UI:_setupRename(state, model)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    local hitRegions = {}

    Draw.band(surface, regions.header, Theme.role.panel)
    Draw.text(surface, 2, regions.header, "SETUP WIZARD", 20, Theme.role.brand, Theme.role.panel)

    local cardFrom, cardTo = 2, regions.width - 1
    local cardTop = math.max(regions.header + 1, regions.content.top - 1)
    local cardBottom = math.min(regions.footer - 1, regions.content.bottom + 1)
    for y = cardTop, cardBottom do Draw.band(surface, y, Theme.role.panel, cardFrom, cardTo) end

    Draw.text(surface, 2, regions.content.top, "Name this storage node", regions.width - 3,
        Theme.role.focus, Theme.role.panel)
    local promptLines = wrapText("Shown on the Storage page instead of the peripheral name.",
        math.max(10, cardTo - cardFrom - 1), 2)
    for index, line in ipairs(promptLines) do
        Draw.text(surface, 2, regions.content.top + index, line, regions.width - 3,
            Theme.role.muted, Theme.role.panel)
    end

    local inputRow = regions.content.top + #promptLines + 2
    Draw.text(surface, 2, inputRow, ">", 1, Theme.role.focus, Theme.role.panel)
    Draw.text(surface, 4, inputRow, (state.setup_rename_text or "") .. "_", regions.width - 4,
        Theme.role.text, Theme.role.panel)

    Draw.band(surface, regions.footer, Theme.role.panel)
    local footerX = 2
    local function footerSegment(text, command)
        Draw.text(surface, footerX, regions.footer, text, #text, Theme.role.text, Theme.role.panel)
        hitRegions[#hitRegions + 1] = {x1=footerX, y1=regions.footer,
            x2=footerX + #text - 1, y2=regions.footer, command=command}
        footerX = footerX + #text + 3
    end
    footerSegment("Enter save", {type="RENAME_CONFIRM"})
    footerSegment("Left/F10 cancel", {type="RENAME_CANCEL"})

    surface.setCursorBlink(false)
    return {hit_regions = hitRegions}
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `lua storage/tests/run.lua tests.test_setup_ui tests.test_setup_wizard_flow` (from `controller/`)
Expected: PASS, all green.

- [ ] **Step 5: Run the full suite**

Run: `lua storage/tests/run.lua` (from `controller/`)
Expected: `RESULT N passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add controller/storage/app/ui.lua controller/storage/tests/test_setup_ui.lua controller/storage/tests/test_setup_wizard_flow.lua
git commit -m "feat: rename screen gets the boxed card treatment and mouse support"
```

---

## Task 5: Final regression pass

**Files:** none modified — verification only.

- [ ] **Step 1: Run the full suite**

Run: `lua storage/tests/run.lua` (from `controller/`)
Expected: `RESULT N passed, 0 failed`.

- [ ] **Step 2: Spot-check no other page regressed**

Run: `lua storage/tests/run.lua tests.test_ui tests.test_ui_layout tests.test_ui_list tests.test_ui_search tests.test_ui_pages tests.test_ui_sections tests.test_ui_click tests.test_ui_purity` (from `controller/`)
Expected: `RESULT N passed, 0 failed` — confirms the `UI:_row` `baseBg` addition and the new `UI:_cardWindow` method left every other page's rendering and click behavior unchanged.

- [ ] **Step 3: Commit (only if Step 1 or 2 required a fix)**

If everything already passed, there is nothing to commit for this task.
