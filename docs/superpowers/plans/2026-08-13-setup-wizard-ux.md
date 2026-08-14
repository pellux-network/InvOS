# Setup Wizard UX Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the setup wizard's confusion points and one real dead end — unclear Right-arrow semantics, a Validate step that hides all but one issue, a Review step with nothing to review, an unreachable duplicate-node confirmation, and storage nodes stuck with raw peripheral names — without changing any model-layer behavior.

**Architecture:** `app/setup.lua` (the wizard's model) already supports everything this needs (`Setup:updateStorage`'s `label` field, `Setup:confirmDistinct`). Every change here is in the wiring/interaction/rendering layer: `main.lua` (`setupChoices`, `syncSetup`, the `onEffect` closure), `app/ui.lua` (`UI:reduce`, `UI:_setupWizard`, a new `UI:_setupRename`), and `app/keymap.lua` (a new `setup_rename` mode). Existing steps 1, 4 (its multi-add mechanic), 5–8 keep their current interaction model; only steps 2, 3, 4 (new rename), 9, and 10 change behavior.

**Tech Stack:** Lua (CC:Tweaked), the repo's own `tests/mock_cc.lua` test doubles and `tests/run.lua` runner. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-13-setup-wizard-ux-design.md`

## Global Constraints

- No changes to `app/setup.lua`'s public behavior, `Setup.validateConfig`, or the issue codes/shapes `Setup:validate()` returns.
- No new wizard steps or pages — all changes are within the existing 10-step flow plus one new sub-mode (`setup_rename`).
- Every new interaction must be reachable with the wizard's existing key set (arrows, Enter, Left, Right, F10) plus one new key (`R`, storage step only) — no mouse-only paths, matching the wizard's current "no Escape, full keyboard nav" contract (`tests/test_setup_ui.lua`'s "complete keyboard navigation" test).
- `lua storage/tests/run.lua` (run from `controller/`) must pass with 0 failures before any task is considered done.

---

## Task 1: Selection resets on step change, not on same-step re-sync

**Files:**
- Modify: `controller/storage/app/ui.lua:317-323` (the `SYNC_SETUP` branch of `UI:reduce`)
- Test: `controller/storage/tests/test_setup_ui.lua`

**Interfaces:**
- Consumes: `UI:reduce(state, command)` where `command = {type="SYNC_SETUP", step=N, choices={...}, issues={...}}` (existing shape, unchanged).
- Produces: `state.selection` behavior later tasks depend on — resets to `1` whenever `command.step` differs from the state's current `setup_step`; is clamped (not reset) when it's the same step. Task 4 will extend this same branch with a step-10-specific override.

- [ ] **Step 1: Write the failing test**

Add to `controller/storage/tests/test_setup_ui.lua` (append to the returned array, before the closing `}`):

```lua
    {name="setup selection resets when the step changes but is kept within the same step",run=function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",4
        state.setup_choices={{label="a"},{label="b"},{label="c"}}
        state.setup_choice_count=3
        state.selection=3
        -- Re-syncing the same step (e.g. after toggling a storage node) keeps the highlight.
        state=ui:reduce(state,{type="SYNC_SETUP",step=4,
            choices={{label="a"},{label="b"},{label="c"},{label="d"}}})
        T.equal(state.selection,3)
        -- Advancing to a different step resets to the first row.
        state=ui:reduce(state,{type="SYNC_SETUP",step=5,
            choices={{label="Skip"},{label="e"}}})
        T.equal(state.selection,1)
    end},
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua storage/tests/run.lua tests.test_setup_ui` (from `controller/`)
Expected: FAIL on `"setup selection resets when the step changes but is kept within the same step"` — after the step-4→5 sync, `state.selection` is `2` (clamped from the stale `3`) instead of the expected `1`.

- [ ] **Step 3: Write minimal implementation**

Replace `controller/storage/app/ui.lua:317-323`:

```lua
    elseif kind == "SYNC_SETUP" then
        local newStep = command.step or state.setup_step or 1
        local changedStep = newStep ~= state.setup_step
        state.setup_step = newStep
        state.setup_choices = copy(command.choices or {})
        state.setup_choice_count = #state.setup_choices
        state.setup_issues = copy(command.issues or {})
        if changedStep then
            state.selection = 1
        else
            state.selection = math.max(1, math.min(state.selection,
                math.max(1, state.setup_choice_count)))
        end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua storage/tests/run.lua tests.test_setup_ui` (from `controller/`)
Expected: PASS, all tests in the file green (this touches shared reducer code — confirm no other test in the file regressed).

- [ ] **Step 5: Commit**

```bash
git add controller/storage/app/ui.lua controller/storage/tests/test_setup_ui.lua
git commit -m "fix: reset setup wizard selection on step change, keep it within a step"
```

---

## Task 2: Right-arrow no longer skips a required role or Validate unnoticed

**Files:**
- Modify: `controller/storage/main.lua:333-337` (the `SETUP_NEXT` branch of `onEffect`)
- Test: `controller/storage/tests/test_setup_wizard_flow.lua` (new file)
- Modify: `controller/storage/tests/run.lua:55` (register the new test module)

**Interfaces:**
- Consumes: `Setup:draft()` (existing, returns a copy of the in-progress config), `Setup:validate()` (existing, returns `{ok, issues, draft, fingerprint, aliases}`), `syncSetup(coordinator, service, step, issues)` (existing local function in `main.lua`).
- Produces: no new effect or command types. Behavior only: `SETUP_NEXT` at step 2/3 without an assigned role re-syncs the same step with a hint instead of advancing; at step 9 it runs validation instead of blind-advancing.

- [ ] **Step 1: Write the failing test**

Create `controller/storage/tests/test_setup_wizard_flow.lua`:

```lua
keys = keys or {}
keys.up=keys.up or 200; keys.down=keys.down or 208; keys.enter=keys.enter or 28
keys.left=keys.left or 203; keys.right=keys.right or 205
keys.f10=keys.f10 or 68; keys.r=keys.r or 19; keys.backspace=keys.backspace or 14
keys.delete=keys.delete or 211

local Main = require("main")
local T = require("tests.mock_cc")

local function chestInventory(size)
    return {
        size=function() return size end,
        list=function() return {} end,
        getItemLimit=function() return 64 end,
        getItemDetail=function() return nil end,
        pushItems=function() return 0 end,
        pullItems=function() return 0 end,
    }
end

-- Two discoverable inventories (drop, pick) is enough for the Drop-off/Pickup guard
-- tests; storage/rename tests add a third (a).
local function environment(inventories)
    inventories = inventories or {drop=chestInventory(27), pick=chestInventory(27)}
    local surface = T.recordingSurface(51, 19)
    return {
        fs=T.memoryFs(), data_root="data",
        peripheral={
            getNames=function() local n={}; for name in pairs(inventories) do n[#n+1]=name end; return n end,
            hasType=function(name,kind) return inventories[name]~=nil and kind=="inventory" end,
            getMethods=function() return {"size","list","getItemDetail","getItemLimit","pushItems","pullItems"} end,
            wrap=function(name) return inventories[name] end,
            find=function() return nil end,
        },
        os={getComputerID=function() return 17 end,getComputerLabel=function() return "Test" end,
            epoch=function() return 1000 end},
        term={current=function() return surface end}, clock=function() return 1000 end,
        textutils={serialize=function() return "{}" end, unserialize=function() return {} end},
        surface=surface,
    }
end

return {
    {name="Right on Drop-off does not advance without a selection, and shows a hint",run=function()
        local coordinator = Main.build(environment())
        T.equal(coordinator:viewModel().ui.setup_step, 1)
        coordinator:handle({"key", keys.right}) -- discovery -> step 2
        T.equal(coordinator:viewModel().ui.setup_step, 2)
        coordinator:handle({"key", keys.right}) -- no dropoff chosen yet
        local model = coordinator:viewModel()
        T.equal(model.ui.setup_step, 2, "must not advance past an unassigned Drop-off")
        T.truthy(model.ui.setup_issues[1])
        T.contains(model.ui.setup_issues[1].message, "Drop-off")
    end},
    {name="Right after selecting Drop-off with Enter advances normally",run=function()
        local coordinator = Main.build(environment())
        coordinator:handle({"key", keys.right}) -- step 2
        coordinator:handle({"key", keys.enter}) -- assigns first discovered inventory, advances to 3
        T.equal(coordinator:viewModel().ui.setup_step, 3)
        coordinator:handle({"key", keys.right}) -- no pickup chosen yet
        T.equal(coordinator:viewModel().ui.setup_step, 3, "must not advance past an unassigned Pickup")
    end},
    {name="Right on Validate runs validation instead of skipping straight to Review",run=function()
        local coordinator = Main.build(environment())
        -- Walk to step 9 without ever assigning dropoff/pickup, using Right the whole way
        -- except where a guard (this task) blocks it -- so drive it explicitly via Enter
        -- on dropoff/pickup so we reach 9 with a config that is otherwise incomplete
        -- (no storage nodes), which keeps validate() blocking.
        coordinator:handle({"key", keys.right}) -- 1 -> 2
        coordinator:handle({"key", keys.enter}) -- assign dropoff, -> 3
        coordinator:handle({"key", keys.enter}) -- assign pickup, -> 4
        coordinator:handle({"key", keys.right}) -- 4 -> 5 (no storage added: MISSING_STORAGE)
        coordinator:handle({"key", keys.right}) -- 5 -> 6
        coordinator:handle({"key", keys.right}) -- 6 -> 7
        coordinator:handle({"key", keys.right}) -- 7 -> 8
        coordinator:handle({"key", keys.right}) -- 8 -> 9 (auto-validates on arrival)
        T.equal(coordinator:viewModel().ui.setup_step, 9)
        coordinator:handle({"key", keys.right}) -- must re-validate, not jump to 10
        local model = coordinator:viewModel()
        T.equal(model.ui.setup_step, 9, "blocking issues must keep Right from reaching Review")
        local sawMissingStorage = false
        for _, issue in ipairs(model.ui.setup_issues) do
            if issue.message and issue.message:find("storage", 1, true) then sawMissingStorage = true end
        end
        T.truthy(sawMissingStorage)
    end},
}
```

- [ ] **Step 2: Register the new module and run to verify it fails**

Add `"tests.test_setup_wizard_flow",` to `controller/storage/tests/run.lua`'s `defaultModules`, immediately after `"tests.test_setup_ui",` (line 55).

Run: `lua storage/tests/run.lua tests.test_setup_wizard_flow` (from `controller/`)
Expected: FAIL on all three tests — today's `SETUP_NEXT` advances past steps 2/3 unconditionally and jumps 9→10 without re-validating.

- [ ] **Step 3: Write minimal implementation**

Replace `controller/storage/main.lua:333-337`:

```lua
        elseif effect.type=="SETUP_BACK" then syncSetup(active,setup,(effect.step or 1)-1)
        elseif effect.type=="SETUP_NEXT" then
            local step=effect.step or 1
            local draft=setup:draft()
            if step==2 and not draft.dropoff then
                syncSetup(active,setup,2,
                    {{message="Select a Drop-off inventory, then press Enter",blocking=true}})
            elseif step==3 and not draft.pickup then
                syncSetup(active,setup,3,
                    {{message="Select a Pickup inventory, then press Enter",blocking=true}})
            elseif step==9 then
                report=setup:validate()
                syncSetup(active,setup,report.ok and 10 or 9,report.issues)
            else
                local nextStep=math.min(10,step+1)
                if nextStep==9 then report=setup:validate() end
                syncSetup(active,setup,nextStep,report and report.issues)
            end
```

This keeps `report.issues` flowing into the bottom-line `setup_issues` hint for step 9, exactly as it did before this task — Task 3 is what moves issue display into `setup_choices` and changes this particular call to pass `{}` instead.

- [ ] **Step 4: Run test to verify it passes**

Run: `lua storage/tests/run.lua tests.test_setup_wizard_flow` (from `controller/`)
Expected: PASS, all three tests green.

- [ ] **Step 5: Run the full suite**

Run: `lua storage/tests/run.lua` (from `controller/`)
Expected: `RESULT N passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add controller/storage/main.lua controller/storage/tests/run.lua controller/storage/tests/test_setup_wizard_flow.lua
git commit -m "fix: setup wizard Right no longer skips required roles or Validate"
```

---

## Task 3: Validate step lists every issue, with jump-to-step and in-place duplicate confirm

**Files:**
- Modify: `controller/storage/main.lua:128-205` (`setupChoices`, step-9 branch) and `main.lua:360-362` (`SETUP_SELECT` step-9 branch)
- Modify: `controller/storage/app/ui.lua:916-921` (the choices-list render callback in `UI:_setupWizard`)
- Modify: `controller/storage/tests/test_setup_wizard_flow.lua` (fix the Task 2 assertion, add new tests)
- Test: `controller/storage/tests/test_setup_ui.lua` (render-only assertions)

**Interfaces:**
- Consumes: `Setup:validate()` (existing — `issue.code`, `issue.message`, `issue.blocking`, `issue.details`), `Setup:confirmDistinct(a, b)` (existing, untested-by-UI-until-now).
- Produces: `setupChoices(service, 9)` returns choice rows shaped `{label=string, detail=string|nil, blocking=bool|nil, jump_step=number|nil, confirm_nodes={id,id}|nil}` — `blocking` is only present on issue rows (the "Run validation" row has none of these fields, same shape as every other step's choices). `UI:_row`'s existing `marker`/`markerColor` parameters are what later render this; no new UI primitive.

- [ ] **Step 1: Write the failing tests**

First, fix the Task 2 test that anticipated this task (`controller/storage/tests/test_setup_wizard_flow.lua`, the "Right on Validate runs validation instead of skipping straight to Review" test) — replace its final assertion block:

```lua
        local model = coordinator:viewModel()
        T.equal(model.ui.setup_step, 9, "blocking issues must keep Right from reaching Review")
        local sawMissingStorage = false
        for _, choice in ipairs(model.ui.setup_choices) do
            if choice.label and choice.label:find("storage", 1, true) then sawMissingStorage = true end
        end
        T.truthy(sawMissingStorage)
```

Then append new tests to the same file, before the closing `}`:

```lua
    {name="Validate lists every issue and jumps to the step that fixes it",run=function()
        local coordinator = Main.build(environment())
        coordinator:handle({"key", keys.right}) -- 1 -> 2
        coordinator:handle({"key", keys.enter}) -- assign dropoff, -> 3
        coordinator:handle({"key", keys.enter}) -- assign pickup, -> 4
        for _ = 4, 8 do coordinator:handle({"key", keys.right}) end -- -> 9, auto-validates
        local model = coordinator:viewModel()
        T.equal(model.ui.setup_step, 9)
        local jumpIndex
        for index, choice in ipairs(model.ui.setup_choices) do
            if choice.jump_step == 4 then jumpIndex = index end
        end
        T.truthy(jumpIndex, "MISSING_STORAGE should offer a jump to step 4")
        for _ = 2, jumpIndex do coordinator:handle({"key", keys.down}) end
        coordinator:handle({"key", keys.enter})
        T.equal(coordinator:viewModel().ui.setup_step, 4)
    end},
    {name="Validate resolves a suspected duplicate in place via confirm_nodes",run=function()
        local inventories = {drop=chestInventory(27), pick=chestInventory(27),
            a=chestInventory(3075), b=chestInventory(3075)}
        local coordinator, services = Main.build(environment(inventories))
        local setup = services.setup
        setup:assign("dropoff", "drop")
        setup:assign("pickup", "pick")
        setup:addStorage("a", "Vault A", 1)
        setup:addStorage("b", "Vault B", 2)
        coordinator:command({type="SYNC_SETUP", step=9, choices={}, issues={}})
        coordinator:handle({"key", keys.enter}) -- run validation
        local model = coordinator:viewModel()
        T.equal(model.ui.setup_step, 9)
        local confirmIndex
        for index, choice in ipairs(model.ui.setup_choices) do
            if choice.confirm_nodes then confirmIndex = index end
        end
        T.truthy(confirmIndex, "identical empty chests should surface a duplicate-confirm row")
        for _ = 2, confirmIndex do coordinator:handle({"key", keys.down}) end
        coordinator:handle({"key", keys.enter})
        model = coordinator:viewModel()
        T.equal(model.ui.setup_step, 9, "confirming stays on Validate")
        local stillSuspected = false
        for _, choice in ipairs(model.ui.setup_choices) do
            if choice.confirm_nodes then stillSuspected = true end
        end
        T.equal(stillSuspected, false, "the pair is no longer flagged as suspected after confirming")
    end},
}
```

Also add to `controller/storage/tests/test_setup_ui.lua` a render-only check that issue rows get a marker:

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
        T.equal(surface.foregroundAt(2, 5), Theme.role.alert)
        T.equal(surface.writesOutsideBounds(), 0)
    end},
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua storage/tests/run.lua tests.test_setup_wizard_flow tests.test_setup_ui` (from `controller/`)
Expected: FAIL — `setupChoices` step 9 today returns a single static choice with no `jump_step`/`confirm_nodes`/`blocking` fields, and `_setupWizard` never passes a marker to `_row`.

- [ ] **Step 3: Write minimal implementation**

In `controller/storage/main.lua`, add a mapping table above `setupChoices` (near line 128):

```lua
-- Only codes with one unambiguous fix location get a jump. PERIPHERAL_MISSING,
-- MISSING_METHOD, DUPLICATE_BINDING, and DUPLICATE_CONFIRMED name a peripheral or role in
-- their own message instead; showing the full message is enough context without guessing.
local SETUP_ISSUE_STEP = {
    MISSING_DROPOFF=2, ROLE_COLLISION=2,
    MISSING_PICKUP=3,
    MISSING_STORAGE=4,
    BUFFER_COLLISION=5, TURTLE_WITHOUT_BUFFER=5,
}
```

Replace the step-9 line in `setupChoices` (`main.lua:202`, currently
`elseif step==9 then choices={{label="Run read-only validation",detail="moves no items"}}`):

```lua
    elseif step==9 then
        choices={{label="Run validation and continue",detail="moves no items"}}
        local report=service:validate()
        for _,iss in ipairs(report.issues) do
            local row={label=iss.message,blocking=iss.blocking}
            if iss.code=="DUPLICATE_SUSPECTED" and iss.details and iss.details.nodes then
                row.confirm_nodes=iss.details.nodes
                row.detail="Enter confirms these are two different containers"
            elseif SETUP_ISSUE_STEP[iss.code] then
                row.jump_step=SETUP_ISSUE_STEP[iss.code]
                row.detail="Enter jumps to step "..row.jump_step
            end
            choices[#choices+1]=row
        end
```

Replace the step-9 branch of `SETUP_SELECT` (`main.lua:360-362`):

```lua
            elseif step==9 then
                if choice and choice.confirm_nodes then
                    setup:confirmDistinct(choice.confirm_nodes[1],choice.confirm_nodes[2])
                    syncSetup(active,setup,9,{})
                elseif choice and choice.jump_step then
                    syncSetup(active,setup,choice.jump_step,{})
                else
                    report=setup:validate()
                    syncSetup(active,setup,report.ok and 10 or 9,{})
                end
```

In `controller/storage/app/ui.lua`, replace the choices-list render call inside `UI:_setupWizard` (lines 916-921):

```lua
    self:_list(regions.content.top + 3, regions.content.bottom - 1, #choices, state.selection,
        function(index, y, selected)
            local choice = choices[index]
            local marker, markerColor
            if choice.blocking ~= nil then
                marker = choice.blocking and "!" or "i"
                markerColor = choice.blocking and Theme.role.alert or Theme.role.warn
            end
            self:_row(y, selected, 1, regions.width, marker, markerColor,
                tostring(choice.label or choice.name), choice.detail)
        end)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `lua storage/tests/run.lua tests.test_setup_wizard_flow tests.test_setup_ui` (from `controller/`)
Expected: PASS, all green.

- [ ] **Step 5: Run the full suite**

Run: `lua storage/tests/run.lua` (from `controller/`)
Expected: `RESULT N passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add controller/storage/main.lua controller/storage/app/ui.lua controller/storage/tests/test_setup_wizard_flow.lua controller/storage/tests/test_setup_ui.lua
git commit -m "feat: setup wizard Validate step lists every issue with jump-to-step and duplicate confirm"
```

---

## Task 4: Review step shows a real summary before saving

**Files:**
- Modify: `controller/storage/main.lua` (new `setupSummary` helper, `syncSetup`'s call site around line 207-211)
- Modify: `controller/storage/app/ui.lua:317-330` (SYNC_SETUP reducer: `setup_summary` field, step-10 selection default) and `app/ui.lua:900-911` (`_setupWizard` render, summary block + list offset)
- Test: `controller/storage/tests/test_setup_wizard_flow.lua`, `controller/storage/tests/test_setup_ui.lua`

**Interfaces:**
- Consumes: `Setup:draft()` (existing).
- Produces: `state.setup_summary` — an array of `{label, detail}` rows, populated only when `state.setup_step == 10`, empty otherwise. No change to the Task 1 selection rule: step 10's choice list is always exactly the one "Save" row, so "reset to 1 on step change" already leaves it highlighted — no step-10-specific case needed.

- [ ] **Step 1: Write the failing tests**

Append to `controller/storage/tests/test_setup_ui.lua`:

```lua
    {name="SYNC_SETUP carries the review summary alongside the step-10 choices",run=function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",9
        state=ui:reduce(state,{type="SYNC_SETUP",step=10,
            choices={{label="Save configuration and enable"}},
            summary={{label="Drop-off",detail="drop"},{label="Pickup",detail="pick"}}})
        T.equal(state.setup_step,10)
        T.equal(state.selection,1) -- the only choice, still highlighted by Task 1's reset-on-change rule
        T.equal(#state.setup_summary,2)
        T.equal(state.setup_summary[1].label,"Drop-off")
    end},
    {name="Review step renders the bound roles before the Save choice",run=function()
        local surface = T.recordingSurface(51, 19)
        local ui = UI.new(surface)
        local state = UI.initialState()
        state.mode, state.page, state.setup_step = "setup", "setup", 10
        state.setup_choices = {{label="Save configuration and enable", detail="starts immediately"}}
        state.setup_choice_count = 1
        state.selection = 1
        state.setup_summary = {
            {label="Drop-off", detail="drop"},
            {label="Pickup", detail="pick"},
            {label="Storage nodes", detail="2 enabled / 2 total"},
        }
        ui:render(state, {})
        local text = surface.allText()
        T.contains(text, "Drop-off: drop")
        T.contains(text, "Pickup: pick")
        T.contains(text, "Storage nodes: 2 enabled / 2 total")
        T.contains(text, "Save configuration and enable")
        T.equal(surface.writesOutsideBounds(), 0)
    end},
```

Append to `controller/storage/tests/test_setup_wizard_flow.lua`:

```lua
    {name="Review summarizes the bound roles before save",run=function()
        local inventories = {drop=chestInventory(27), pick=chestInventory(27), a=chestInventory(3075)}
        local coordinator, services = Main.build(environment(inventories))
        local setup = services.setup
        setup:assign("dropoff", "drop")
        setup:assign("pickup", "pick")
        setup:addStorage("a", "Vault A", 1)
        coordinator:command({type="SYNC_SETUP", step=9, choices={}, issues={}})
        coordinator:handle({"key", keys.enter}) -- run validation, advances to 10 (ok)
        local model = coordinator:viewModel()
        T.equal(model.ui.setup_step, 10)
        local byLabel = {}
        for _, row in ipairs(model.ui.setup_summary) do byLabel[row.label] = row.detail end
        T.equal(byLabel["Drop-off"], "drop")
        T.equal(byLabel["Pickup"], "pick")
        T.equal(byLabel["Storage nodes"], "1 enabled / 1 total")
        T.equal(byLabel["Craft buffer"], "not set")
    end},
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua storage/tests/run.lua tests.test_setup_ui tests.test_setup_wizard_flow` (from `controller/`)
Expected: FAIL — `state.setup_summary` doesn't exist yet, step-10 selection isn't special-cased, and nothing renders the summary block.

- [ ] **Step 3: Write minimal implementation**

In `controller/storage/main.lua`, add above `syncSetup` (near line 207):

```lua
local function setupSummary(service)
    local draft=service:draft()
    local function role(label,binding)
        return {label=label,detail=binding and binding.peripheral_name or "not set"}
    end
    local enabled,total=0,0
    for _,node in ipairs(draft.storage or {}) do
        total=total+1
        if node.enabled~=false then enabled=enabled+1 end
    end
    local monitors=draft.monitors or {}
    return {
        role("Drop-off",draft.dropoff),
        role("Pickup",draft.pickup),
        {label="Storage nodes",detail=enabled.." enabled / "..total.." total"},
        role("Craft buffer",draft.craft_buffer),
        role("Crafting turtle",draft.turtle),
        {label="Main monitor",detail=monitors.main or "auto-detect"},
        {label="Crafting monitor",detail=monitors.crafting or "not set"},
    }
end
```

Replace `syncSetup` itself:

```lua
local function syncSetup(coordinator,service,step,issues)
    local clamped=math.max(1,math.min(10,step))
    coordinator:command({type="SYNC_SETUP",step=clamped,
        choices=setupChoices(service,clamped),issues=issues or {},
        summary=clamped==10 and setupSummary(service) or nil})
    coordinator:redraw()
end
```

In `controller/storage/app/ui.lua`, extend the `SYNC_SETUP` branch (the one Task 1 wrote) to also carry `summary` — the selection rule itself is unchanged from Task 1:

```lua
    elseif kind == "SYNC_SETUP" then
        local newStep = command.step or state.setup_step or 1
        local changedStep = newStep ~= state.setup_step
        state.setup_step = newStep
        state.setup_choices = copy(command.choices or {})
        state.setup_choice_count = #state.setup_choices
        state.setup_issues = copy(command.issues or {})
        state.setup_summary = copy(command.summary or {})
        if changedStep then
            state.selection = 1
        else
            state.selection = math.max(1, math.min(state.selection,
                math.max(1, state.setup_choice_count)))
        end
```

In `controller/storage/app/ui.lua`'s `UI:_setupWizard`, insert a summary block between the prompt (`content.top + 1`) and the choices list, and shift the list down to make room. Replace lines 911-921 (the choices/list block) with:

```lua
    local summary = (state.setup_step == 10) and (state.setup_summary or {}) or {}
    for index, row in ipairs(summary) do
        Draw.text(surface, 2, regions.content.top + 3 + index - 1,
            tostring(row.label) .. ": " .. tostring(row.detail), regions.width - 3,
            Theme.role.text, Theme.role.ground)
    end
    local listTop = regions.content.top + 3 + #summary + (#summary > 0 and 1 or 0)
    local choices = state.setup_choices or {}
    if #choices == 0 then
        Draw.text(surface, 2, listTop, "No choices on this step",
            regions.width - 3, Theme.role.muted, Theme.role.ground)
    end
    self:_list(listTop, regions.content.bottom - 1, #choices, state.selection,
        function(index, y, selected)
            local choice = choices[index]
            local marker, markerColor
            if choice.blocking ~= nil then
                marker = choice.blocking and "!" or "i"
                markerColor = choice.blocking and Theme.role.alert or Theme.role.warn
            end
            self:_row(y, selected, 1, regions.width, marker, markerColor,
                tostring(choice.label or choice.name), choice.detail)
        end)
```

(This subsumes the render change Task 3 made — same list body, just parameterized on `listTop` instead of the hardcoded `regions.content.top + 3`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `lua storage/tests/run.lua tests.test_setup_ui tests.test_setup_wizard_flow` (from `controller/`)
Expected: PASS, all green.

- [ ] **Step 5: Run the full suite**

Run: `lua storage/tests/run.lua` (from `controller/`)
Expected: `RESULT N passed, 0 failed`. Pay particular attention to `tests.test_setup_ui`'s existing "every wizard step has its own title and prompt" and "the wizard shows its progress" tests (steps 1-10 loop, step 3 foreground-color check) — the `listTop` change must not move anything for steps other than 10, where `summary` is always `{}`.

- [ ] **Step 6: Commit**

```bash
git add controller/storage/main.lua controller/storage/app/ui.lua controller/storage/tests/test_setup_ui.lua controller/storage/tests/test_setup_wizard_flow.lua
git commit -m "feat: setup wizard Review step shows a bound-roles summary before saving"
```

---

## Task 5: Inline rename when adding a storage node

**Files:**
- Modify: `controller/storage/app/keymap.lua` (new `char`/`paste`/`setup_rename` key handling)
- Modify: `controller/storage/app/ui.lua` (`UI:reduce`: `OPEN_RENAME`, `RENAME_APPEND`, `RENAME_BACKSPACE`, `RENAME_CLEAR`, `RENAME_CONFIRM`, `RENAME_CANCEL`; new `UI:_setupRename`; `UI:_frame` dispatch; `SYNC_SETUP` sets `state.mode="setup"`)
- Modify: `controller/storage/main.lua:346-353` (`SETUP_SELECT` step-4 add branch), `onEffect` (new `RENAME_CONFIRM`/`RENAME_CANCEL` branches), `setupChoices` step-4 branch (show custom labels)
- Test: `controller/storage/tests/test_keymap.lua`, `controller/storage/tests/test_setup_ui.lua`, `controller/storage/tests/test_setup_wizard_flow.lua`

**Interfaces:**
- Consumes: `Setup:addStorage(peripheralName, label, priority)` (existing, unchanged call), `Setup:updateStorage(id, {label=...})` (existing).
- Produces: UI mode `"setup_rename"` with state fields `setup_rename_id` (string) and `setup_rename_text` (string). Effects `RENAME_CONFIRM {node_id, text}` and `RENAME_CANCEL {}`. Coordinator command `OPEN_RENAME {node_id, text}` (main.lua → ui.lua, entering the mode). Task 6 reuses all of this and adds only its own trigger path.

- [ ] **Step 1: Write the failing tests**

`controller/storage/tests/test_keymap.lua`'s own `keys` table (line 1-5) doesn't define
`left` — only `test_setup_ui.lua` adds that, later in load order, and this file must stay
runnable standalone (`lua storage/tests/run.lua tests.test_keymap`). Add it to the literal
table at the top of `controller/storage/tests/test_keymap.lua`:

```lua
keys = {
    backspace=14, up=200, down=208, enter=28, s=31, a=30, f10=68,
    escape=1, one=2, two=3, three=4, four=5, five=6,
    r=19, c=46, p=25, x=45, delete=211, left=203,
}
```

Then append to the same file:

```lua
    { name = "setup_rename mode captures typing and confirm/cancel", run = function()
        local state = {mode="setup_rename"}
        T.equal(Keymap.command({"char","V"},state).type,"RENAME_APPEND")
        T.equal(Keymap.command({"char","V"},state).text,"V")
        T.equal(Keymap.command({"paste","Vault"},state).type,"RENAME_APPEND")
        T.equal(Keymap.command({"key",keys.backspace},state).type,"RENAME_BACKSPACE")
        T.equal(Keymap.command({"key",keys.delete},state).type,"RENAME_CLEAR")
        T.equal(Keymap.command({"key",keys.enter},state).type,"RENAME_CONFIRM")
        T.equal(Keymap.command({"key",keys.left},state).type,"RENAME_CANCEL")
        T.equal(Keymap.command({"key",keys.f10},state).type,"RENAME_CANCEL")
    end },
```

Append to `controller/storage/tests/test_setup_ui.lua`:

```lua
    {name="OPEN_RENAME enters setup_rename mode pre-filled with the given text",run=function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",4
        state=ui:reduce(state,{type="OPEN_RENAME",node_id="storage_1",text="chest_3"})
        T.equal(state.mode,"setup_rename")
        T.equal(state.setup_rename_id,"storage_1")
        T.equal(state.setup_rename_text,"chest_3")
    end},
    {name="typing and confirming in rename mode produces the effect and clears on cancel",run=function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state=ui:reduce(state,{type="OPEN_RENAME",node_id="storage_1",text="chest_3"})
        state=ui:reduce(state,{type="RENAME_BACKSPACE"})
        T.equal(state.setup_rename_text,"chest_")
        state=ui:reduce(state,{type="RENAME_APPEND",text="9"})
        T.equal(state.setup_rename_text,"chest_9")
        local nextState,effect=ui:reduce(state,{type="RENAME_CONFIRM"})
        T.equal(effect.type,"RENAME_CONFIRM")
        T.equal(effect.node_id,"storage_1")
        T.equal(effect.text,"chest_9")
        local cancelState,cancelEffect=ui:reduce(state,{type="RENAME_CANCEL"})
        T.equal(cancelEffect.type,"RENAME_CANCEL")
        T.truthy(cancelState)
    end},
    {name="setup_rename renders a text prompt and its own footer",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup_rename","setup",4
        state.setup_rename_id,state.setup_rename_text="storage_1","chest_3"
        ui:render(state,{})
        local text=surface.allText()
        T.contains(text,"Name this storage node")
        T.contains(text,"chest_3")
        T.contains(text,"Enter save")
        T.equal(surface.writesOutsideBounds(),0)
    end},
    {name="SYNC_SETUP returns the wizard to setup mode, exiting any rename in progress",run=function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state=ui:reduce(state,{type="OPEN_RENAME",node_id="storage_1",text="chest_3"})
        T.equal(state.mode,"setup_rename")
        state=ui:reduce(state,{type="SYNC_SETUP",step=4,choices={}})
        T.equal(state.mode,"setup")
    end},
```

Append to `controller/storage/tests/test_setup_wizard_flow.lua`:

```lua
    {name="adding a storage node opens a rename prompt pre-filled with its default label",run=function()
        local inventories = {drop=chestInventory(27), pick=chestInventory(27), a=chestInventory(3075)}
        local coordinator = Main.build(environment(inventories))
        coordinator:handle({"key", keys.right}) -- 1 -> 2
        coordinator:handle({"key", keys.enter}) -- assign dropoff, -> 3
        coordinator:handle({"key", keys.enter}) -- assign pickup, -> 4
        coordinator:handle({"key", keys.enter}) -- add the only remaining discovered inventory ("a")
        local model = coordinator:viewModel()
        T.equal(model.ui.mode, "setup_rename")
        T.equal(model.ui.setup_rename_text, "a")
        coordinator:handle({"char", "!"}) -- would-be typed name suffix, e.g. renaming to "a!"... 
        coordinator:handle({"key", keys.enter}) -- confirm
        model = coordinator:viewModel()
        T.equal(model.ui.mode, "setup")
        T.equal(model.ui.setup_step, 4)
        local sawCustomLabel = false
        for _, choice in ipairs(model.ui.setup_choices) do
            if choice.detail and choice.detail:find("a!", 1, true) then sawCustomLabel = true end
        end
        T.truthy(sawCustomLabel, "the storage step should show the custom label once set")
    end},
    {name="cancelling a rename keeps the node with its default label",run=function()
        local inventories = {drop=chestInventory(27), pick=chestInventory(27), a=chestInventory(3075)}
        local coordinator, services = Main.build(environment(inventories))
        coordinator:handle({"key", keys.right})
        coordinator:handle({"key", keys.enter})
        coordinator:handle({"key", keys.enter})
        coordinator:handle({"key", keys.enter}) -- add "a", opens rename
        coordinator:handle({"key", keys.f10}) -- cancel
        local model = coordinator:viewModel()
        T.equal(model.ui.mode, "setup")
        T.equal(services.setup:draft().storage[1].label, "a")
    end},
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua storage/tests/run.lua tests.test_keymap tests.test_setup_ui tests.test_setup_wizard_flow` (from `controller/`)
Expected: FAIL — none of `RENAME_*`/`OPEN_RENAME`/`setup_rename` exist yet.

- [ ] **Step 3: Write minimal implementation**

In `controller/storage/app/keymap.lua`, add rename-mode `char`/`paste` handling next to the existing search-mode checks (after line 30, before the `if name == "char" then` block's body ends around line 44):

```lua
    if name == "paste" and state.mode == "setup_rename" then
        return {type="RENAME_APPEND",text=tostring(event[2] or "")}
    end
```

(placed alongside the two existing `paste` checks, lines 25-30) and inside the existing `if name == "char" then ... end` block, add one more mode check next to the `search`/`craft_search` ones:

```lua
        if state.mode == "setup_rename" then return {type="RENAME_APPEND",text=character} end
```

Add a new `setup_rename` key block right after the existing `setup` mode block (after line 58, `if state.mode == "setup" then ... end`):

```lua
    if state.mode == "setup_rename" then
        if key == keys.enter then return {type="RENAME_CONFIRM"} end
        if key == keys.backspace then return {type="RENAME_BACKSPACE"} end
        if key == keys.delete then return {type="RENAME_CLEAR"} end
        if key == keys.left or key == keys.f10 then return {type="RENAME_CANCEL"} end
        return nil
    end
```

In `controller/storage/app/ui.lua`, add to `UI:reduce`'s dispatch chain (anywhere alongside the other `SYNC_*`/mode-entry branches, e.g. right after the `SYNC_SETUP` branch):

```lua
    elseif kind == "OPEN_RENAME" then
        state.mode = "setup_rename"
        state.setup_rename_id = command.node_id
        state.setup_rename_text = tostring(command.text or "")
    elseif kind == "RENAME_APPEND" then
        state.setup_rename_text = (state.setup_rename_text or "") .. tostring(command.text or "")
    elseif kind == "RENAME_BACKSPACE" then
        local current = state.setup_rename_text or ""
        state.setup_rename_text = current:sub(1, math.max(0, #current - 1))
    elseif kind == "RENAME_CLEAR" then
        state.setup_rename_text = ""
    elseif kind == "RENAME_CONFIRM" then
        return state, {type="RENAME_CONFIRM", node_id=state.setup_rename_id,
            text=state.setup_rename_text}
    elseif kind == "RENAME_CANCEL" then
        return state, {type="RENAME_CANCEL"}
```

Also add `state.mode = "setup"` as the first line inside the existing `SYNC_SETUP` branch (from Task 1/4), immediately after `elseif kind == "SYNC_SETUP" then`.

Add a new render function in `controller/storage/app/ui.lua`, near `UI:_setupWizard` (after it, e.g. after line 935):

```lua
function UI:_setupRename(state, model)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    Draw.band(surface, regions.header, Theme.role.panel)
    Draw.text(surface, 2, regions.header, "SETUP WIZARD", 20, Theme.role.brand, Theme.role.panel)
    Draw.text(surface, 2, regions.content.top, "Name this storage node", regions.width - 3,
        Theme.role.focus, Theme.role.ground)
    Draw.text(surface, 2, regions.content.top + 1,
        "Shown on the Storage page instead of the peripheral name.", regions.width - 3,
        Theme.role.muted, Theme.role.ground)
    Draw.text(surface, 2, regions.content.top + 3, ">", 1, Theme.role.focus, Theme.role.ground)
    Draw.text(surface, 4, regions.content.top + 3, (state.setup_rename_text or "") .. "_",
        regions.width - 4, Theme.role.text, Theme.role.ground)
    Draw.band(surface, regions.footer, Theme.role.panel)
    Draw.text(surface, 2, regions.footer, "Enter save   Left/F10 cancel", regions.width - 3,
        Theme.role.text, Theme.role.panel)
    surface.setCursorBlink(false)
    return {hit_regions={}}
end
```

Add the dispatch in `UI:_frame` (`app/ui.lua`, immediately before the existing `if state.mode == "setup" then return self:_setupWizard(state, model) end` line):

```lua
    if state.mode == "setup_rename" then return self:_setupRename(state, model) end
```

In `controller/storage/main.lua`, replace the step-4 add branch inside `SETUP_SELECT` (lines 346-353):

```lua
            elseif step==4 and choice then
                local found
                for _,node in ipairs(setup:draft().storage or {}) do
                    if node.peripheral_name==choice.name then found=node; break end
                end
                if found then
                    setup:removeStorage(found.id)
                    syncSetup(active,setup,4)
                else
                    local node=setup:addStorage(choice.name,choice.name)
                    active:command({type="OPEN_RENAME",node_id=node.id,text=node.label})
                    active:redraw()
                end
```

Add two new `onEffect` branches, alongside the other `SETUP_*` ones (after the `SETUP_NEXT` branch is a natural spot):

```lua
        elseif effect.type=="RENAME_CONFIRM" then
            local text=tostring(effect.text or "")
            setup:updateStorage(effect.node_id,{label=text~="" and text or nil})
            syncSetup(active,setup,4)
        elseif effect.type=="RENAME_CANCEL" then
            syncSetup(active,setup,4)
```

Update `setupChoices`'s step-4 branch (`main.lua`, inside the `elseif step==4 then` body) to show a custom label once set — replace the inner marking loop:

```lua
        for _,choice in ipairs(choices) do
            for _,node in ipairs(draft.storage or {}) do
                if node.peripheral_name==choice.name then
                    choice.label="[added] "..choice.label
                    if node.label ~= node.peripheral_name then
                        choice.detail = "as \""..node.label.."\""
                    end
                end
            end
        end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `lua storage/tests/run.lua tests.test_keymap tests.test_setup_ui tests.test_setup_wizard_flow` (from `controller/`)
Expected: PASS, all green.

- [ ] **Step 5: Run the full suite**

Run: `lua storage/tests/run.lua` (from `controller/`)
Expected: `RESULT N passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add controller/storage/app/keymap.lua controller/storage/app/ui.lua controller/storage/main.lua controller/storage/tests/test_keymap.lua controller/storage/tests/test_setup_ui.lua controller/storage/tests/test_setup_wizard_flow.lua
git commit -m "feat: setup wizard prompts to name a storage node right after adding it"
```

---

## Task 6: Rename an already-added storage node with R

**Files:**
- Modify: `controller/storage/app/keymap.lua` (the `setup` mode block, new `r` key)
- Modify: `controller/storage/app/ui.lua` (`UI:reduce`: `RENAME_STORAGE_REQUEST`; `_setupWizard` footer hint)
- Modify: `controller/storage/main.lua` (`onEffect`: new `RENAME_STORAGE_REQUEST` branch)
- Test: `controller/storage/tests/test_keymap.lua`, `controller/storage/tests/test_setup_ui.lua`, `controller/storage/tests/test_setup_wizard_flow.lua`

**Interfaces:**
- Consumes: everything Task 5 produced (`OPEN_RENAME` command, `setupChoices(service, 4)`'s `choice.name`).
- Produces: effect `RENAME_STORAGE_REQUEST {step, index}`, no new state fields.

- [ ] **Step 1: Write the failing tests**

Append to `controller/storage/tests/test_keymap.lua`:

```lua
    { name = "R requests a rename only on the storage step", run = function()
        T.equal(Keymap.command({"key",keys.r},{mode="setup",setup_step=4}).type,"RENAME_STORAGE_REQUEST")
        T.equal(Keymap.command({"key",keys.r},{mode="setup",setup_step=2}),nil)
    end },
```

Append to `controller/storage/tests/test_setup_ui.lua`:

```lua
    {name="RENAME_STORAGE_REQUEST carries the current step and selection as an effect",run=function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.mode,state.page,state.setup_step,state.selection="setup","setup",4,2
        local nextState,effect=ui:reduce(state,{type="RENAME_STORAGE_REQUEST"})
        T.equal(effect.type,"RENAME_STORAGE_REQUEST")
        T.equal(effect.step,4)
        T.equal(effect.index,2)
    end},
    {name="the storage step footer hints at R once choices exist",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",4
        state.setup_choices={{label="[added] a",detail="as \"Vault A\""}}
        state.setup_choice_count=1
        ui:render(state,{})
        T.contains(surface.allText(),"R rename")
    end},
```

Append to `controller/storage/tests/test_setup_wizard_flow.lua`:

```lua
    {name="R renames an already-added storage node",run=function()
        local inventories = {drop=chestInventory(27), pick=chestInventory(27), a=chestInventory(3075)}
        local coordinator, services = Main.build(environment(inventories))
        coordinator:handle({"key", keys.right})
        coordinator:handle({"key", keys.enter})
        coordinator:handle({"key", keys.enter})
        coordinator:handle({"key", keys.enter}) -- add "a"
        coordinator:handle({"key", keys.enter}) -- confirm default label "a"
        T.equal(coordinator:viewModel().ui.mode, "setup")
        coordinator:handle({"key", keys.r}) -- re-open rename for the now-highlighted "a" row
        local model = coordinator:viewModel()
        T.equal(model.ui.mode, "setup_rename")
        T.equal(model.ui.setup_rename_text, "a")
        coordinator:handle({"key", keys.backspace})
        coordinator:handle({"char", "z"})
        coordinator:handle({"key", keys.enter})
        T.equal(services.setup:draft().storage[1].label, "z")
    end},
    {name="R does nothing on a peripheral that hasn't been added yet",run=function()
        local inventories = {drop=chestInventory(27), pick=chestInventory(27), a=chestInventory(3075)}
        local coordinator = Main.build(environment(inventories))
        coordinator:handle({"key", keys.right})
        coordinator:handle({"key", keys.enter})
        coordinator:handle({"key", keys.enter})
        -- now on step 4 with "a" highlighted but not yet added
        coordinator:handle({"key", keys.r})
        T.equal(coordinator:viewModel().ui.mode, "setup")
    end},
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua storage/tests/run.lua tests.test_keymap tests.test_setup_ui tests.test_setup_wizard_flow` (from `controller/`)
Expected: FAIL — `keys.r` in setup mode returns `nil` today, no footer hint, no `RENAME_STORAGE_REQUEST` handling anywhere.

- [ ] **Step 3: Write minimal implementation**

In `controller/storage/app/keymap.lua`, inside the existing `if state.mode == "setup" then ... end` block (lines 50-58), add before its final `return nil`:

```lua
        if key == keys.r and state.setup_step == 4 then return {type="RENAME_STORAGE_REQUEST"} end
```

In `controller/storage/app/ui.lua`'s `UI:reduce`, add:

```lua
    elseif kind == "RENAME_STORAGE_REQUEST" then
        return state, {type="RENAME_STORAGE_REQUEST", step=state.setup_step, index=state.selection}
```

In `UI:_setupWizard`, change the footer line (originally lines 927-929, already touched by earlier tasks only if their edits happened to land here — locate the `Draw.text(surface, 2, regions.footer, "Up/Down  Enter select  Left back  Right next", ...)` line):

```lua
    Draw.band(surface, regions.footer, Theme.role.panel)
    local footerHint = "Up/Down  Enter select  Left back  Right next"
    if state.setup_step == 4 then footerHint = footerHint .. "   R rename" end
    Draw.text(surface, 2, regions.footer, footerHint, regions.width - 3, Theme.role.text, Theme.role.panel)
```

In `controller/storage/main.lua`'s `onEffect`, add a new branch (alongside `RENAME_CONFIRM`/`RENAME_CANCEL` from Task 5):

```lua
        elseif effect.type=="RENAME_STORAGE_REQUEST" then
            local choices=setupChoices(setup,4)
            local choice=choices[effect.index or 1]
            local found
            if choice then
                for _,node in ipairs(setup:draft().storage or {}) do
                    if node.peripheral_name==choice.name then found=node; break end
                end
            end
            if found then
                active:command({type="OPEN_RENAME",node_id=found.id,text=found.label})
                active:redraw()
            end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `lua storage/tests/run.lua tests.test_keymap tests.test_setup_ui tests.test_setup_wizard_flow` (from `controller/`)
Expected: PASS, all green.

- [ ] **Step 5: Run the full suite**

Run: `lua storage/tests/run.lua` (from `controller/`)
Expected: `RESULT N passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add controller/storage/app/keymap.lua controller/storage/app/ui.lua controller/storage/main.lua controller/storage/tests/test_keymap.lua controller/storage/tests/test_setup_ui.lua controller/storage/tests/test_setup_wizard_flow.lua
git commit -m "feat: setup wizard supports renaming an already-added storage node with R"
```

---

## Task 7: Docs and backlog cleanup, final regression pass

**Files:**
- Modify: `docs/operations.md:30`
- Modify: `docs/backlog.md:87-89`
- Test: full suite

**Interfaces:** none (documentation only).

- [ ] **Step 1: Update the wizard key list in the operator guide**

In `docs/operations.md`, replace line 30:

```markdown
Use `5 SETUP` from the main interface to review or change configuration later. Arrow keys, Enter, Left/Right, `R` (rename, on the storage step), and F10 control the wizard; Escape is intentionally not captured because Minecraft uses it to close the computer screen.
```

- [ ] **Step 2: Remove the now-fixed backlog entry**

In `docs/backlog.md`, remove lines 87-89 (the "Storage node labels default to the peripheral name" bullet — this pass adds the rename step that bullet said was missing):

```markdown
- **Storage node labels default to the peripheral name.** Setup writes the peripheral name as
  the label, so the Nodes page reads `chest_0` rather than anything a person chose.
  The wizard has no rename step.
```

Delete this block entirely (including the blank line separating it from neighboring bullets, so the list stays evenly spaced — check the surrounding bullets after editing).

- [ ] **Step 3: Run the full suite one last time**

Run: `lua storage/tests/run.lua` (from `controller/`)
Expected: `RESULT N passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add docs/operations.md docs/backlog.md
git commit -m "docs: document the setup wizard rename key, close the rename-step backlog item"
```
