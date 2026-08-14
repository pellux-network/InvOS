# Error Handling, Recovery, and the Alerts Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a transient/expected error from taking down the whole
controller, make component alerts that are no longer true clear
themselves, and replace the confusing "acknowledge" + "release recovery"
pair on the Alerts page with one Dismiss action.

**Architecture:** All changes live in `controller/storage/app/` --
`coordinator.lua` (crash hardening, auto-clear, effect dispatch),
`alerts.lua` (drop the cosmetic acknowledge flag), `ui.lua` (reducer +
render), `keymap.lua` (key bindings). No new files, no new dependencies,
no change to any other subsystem (`import_service.lua`,
`craft_service.lua`, `requests.lua`, `recovery.lua` keep their current
behavior untouched).

**Tech Stack:** Lua 5.4 (host tests) / Lua 5.2 (CC:Tweaked runtime, not
exercised by these tests). Host suite: `lua storage/tests/run.lua`, run
from `controller/`.

**Spec:** `docs/superpowers/specs/2026-08-13-error-handling-alerts-design.md`

## Global Constraints

- Host Lua is 5.4, CC:Tweaked runs Lua 5.2 -- avoid host-only syntax
  (this plan uses none; every snippet below is plain `if`/`pcall`/table
  code already used elsewhere in these files).
- Run the **complete** host Lua suite (`lua storage/tests/run.lua` from
  `controller/`) before every commit in this plan, and check its exit
  code directly -- not a subset, per `CONTRIBUTING.md`.
- Match the existing compact, low-whitespace style of `app/*.lua` --
  don't reformat surrounding code.
- Never edit `controller/storage/recipes/` (not touched by this plan).
- This plan makes runtime behavior changes only; no live deployment
  (`tools/deploy.py`) is part of it or should be run for it.

---

## Task 1: Crash hardening -- `workStep` and `handle`

**Files:**
- Modify: `controller/storage/app/coordinator.lua:551-559` (`workStep`), `:673-710` (`handle`)
- Test: `controller/storage/tests/test_error_recovery.lua`

**Interfaces:**
- Consumes: existing `Coordinator:_recordError(component, reason)` (`coordinator.lua:98-108`, unchanged).
- Produces: no public API change. `workStep`/`handle` keep their existing signatures and return nothing (unchanged); the only observable difference is that a previously-fatal internal error now becomes a recorded notice/alert instead of an uncaught Lua error.

The bug: `Coordinator:redraw` (`coordinator.lua:1002-1004`) calls
`self:_model()` and `self:_syncPageCounts(model)` before its first
`pcall`. `_model()` aggregates live, concurrently-changing state
(nodes, requests, alerts, gauges); any error inside it currently
escapes `redraw` uncaught. `redraw()` is reached two ways, and both need
covering: from `workStep`'s dirty-check at the end of the tick loop, and
directly from `Coordinator:handle` on `term_resize`/`monitor_resize`
and after most commands (`coordinator.lua:686,708`). `Coordinator:run`'s
`events()` closure (`coordinator.lua:1029-1031`) also calls `handle`,
but it's an infinite loop with no way to unit-test it directly, so
wrapping `handle` itself (rather than that closure) is what makes both
paths verifiable.

- [ ] **Step 1: Write the failing tests**

Add to `controller/storage/tests/test_error_recovery.lua` (add `local
Alerts = require("app.alerts")` near the top alongside the existing
`local Coordinator = require("app.coordinator")` -- Task 2 needs it too,
so add it once now):

```lua
    {name="a redraw crash from the tick loop is caught and recorded instead of killing workStep",run=function()
        local d=dependencies()
        d.alerts={active=function() error("boom") end}
        local coordinator=Coordinator.new(d)
        coordinator:workStep(1)
        T.truthy(#coordinator.notices>0, "the crash must be recorded")
        T.contains(coordinator.notices[#coordinator.notices].message,"boom")
        coordinator:workStep(2)
        T.truthy(#coordinator.notices>0, "workStep must still be callable afterward")
    end},
    {name="a redraw crash reached through handle is caught and recorded",run=function()
        local d=dependencies()
        d.alerts={active=function() error("boom") end}
        local coordinator=Coordinator.new(d)
        coordinator:handle({"term_resize"})
        T.truthy(#coordinator.notices>0, "the crash must be recorded")
        T.contains(coordinator.notices[#coordinator.notices].message,"boom")
    end},
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd controller && lua storage/tests/run.lua tests.test_error_recovery`
Expected: both new tests FAIL with an uncaught Lua error ("boom"),
not a clean assertion failure -- this confirms the gap is real before
fixing it.

- [ ] **Step 3: Wrap `workStep`'s body**

In `controller/storage/app/coordinator.lua`, replace:

```lua
function Coordinator:workStep(now)
    now = now or self.clock()
    self:_scanStep(now)
    self:_enrichStep()
    self:_automationStep(now)
    self:_stallStep(now)
    self:_refreshLifecycle(now)
    if self.dirty then self:redraw() end
end
```

with:

```lua
function Coordinator:workStep(now)
    now = now or self.clock()
    local ok, reason = pcall(function()
        self:_scanStep(now)
        self:_enrichStep()
        self:_automationStep(now)
        self:_stallStep(now)
        self:_refreshLifecycle(now)
        if self.dirty then self:redraw() end
    end)
    if not ok then self:_recordError("coordinator", reason) end
end
```

- [ ] **Step 4: Wrap `handle`'s body**

Replace the existing `Coordinator:handle` (`coordinator.lua:673-710`):

```lua
function Coordinator:handle(event)
    if type(event) ~= "table" then return end
    local name, peripheralName = event[1], event[2]
    if name == "peripheral_detach" or name == "peripheral" then
        for _, node in ipairs(self.nodes) do
            if node.peripheral_name == peripheralName then
                self.snapshots[node.id] = nil
                node.state = name == "peripheral_detach" and "OFFLINE" or "SCANNING"
                if name == "peripheral" then self:requestRescan({peripheralName}) end
            end
        end
        self:_refreshLifecycle(); self.dirty=true
    elseif name == "monitor_resize" or name == "term_resize" then
        self.dirty=true; self:redraw()
    elseif name == "rednet_message" then
        local link = self.deps.turtle_link
        if link and type(link.deliver) == "function" then
            local ok, reason = pcall(link.deliver, link, event[2], event[3], event[4])
            if not ok then self:_recordError("turtle link", reason) end
            self.dirty = true
        end
    end
    local ok, command = pcall(self.keymap.command, event, self.uiState)
    if not ok then self:_recordError("keymap", command); return end
    if command then
        self:command(command)
        if command.type == "QUERY_APPEND" or command.type == "QUERY_BACKSPACE" or
            command.type == "QUERY_CLEAR" then self:_rebuildIndex() end
        if command.type == "CRAFT_QUERY_APPEND" or command.type == "CRAFT_QUERY_BACKSPACE" or
            command.type == "CRAFT_QUERY_CLEAR" or
            (command.type == "OPEN_PAGE" and command.page == "crafting") then
            self:_syncCraft()
        end
        self:redraw()
    end
end
```

with:

```lua
function Coordinator:handle(event)
    local ok, reason = pcall(function()
        if type(event) ~= "table" then return end
        local name, peripheralName = event[1], event[2]
        if name == "peripheral_detach" or name == "peripheral" then
            for _, node in ipairs(self.nodes) do
                if node.peripheral_name == peripheralName then
                    self.snapshots[node.id] = nil
                    node.state = name == "peripheral_detach" and "OFFLINE" or "SCANNING"
                    if name == "peripheral" then self:requestRescan({peripheralName}) end
                end
            end
            self:_refreshLifecycle(); self.dirty=true
        elseif name == "monitor_resize" or name == "term_resize" then
            self.dirty=true; self:redraw()
        elseif name == "rednet_message" then
            local link = self.deps.turtle_link
            if link and type(link.deliver) == "function" then
                local deliverOk, deliverReason = pcall(link.deliver, link, event[2], event[3], event[4])
                if not deliverOk then self:_recordError("turtle link", deliverReason) end
                self.dirty = true
            end
        end
        local commandOk, command = pcall(self.keymap.command, event, self.uiState)
        if not commandOk then self:_recordError("keymap", command); return end
        if command then
            self:command(command)
            if command.type == "QUERY_APPEND" or command.type == "QUERY_BACKSPACE" or
                command.type == "QUERY_CLEAR" then self:_rebuildIndex() end
            if command.type == "CRAFT_QUERY_APPEND" or command.type == "CRAFT_QUERY_BACKSPACE" or
                command.type == "CRAFT_QUERY_CLEAR" or
                (command.type == "OPEN_PAGE" and command.page == "crafting") then
                self:_syncCraft()
            end
            self:redraw()
        end
    end)
    if not ok then self:_recordError("input", reason) end
end
```

(Only the variable names `commandOk`/`deliverOk` changed from the
original `ok`/`ok` to avoid shadowing the outer `ok` -- behavior is
otherwise identical, just wrapped.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd controller && lua storage/tests/run.lua tests.test_error_recovery`
Expected: PASS. Then run the full suite once to catch any regression
from the `handle` rewrite: `lua storage/tests/run.lua` -- expect the
same pass count as before this task plus the 2 new tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add controller/storage/app/coordinator.lua controller/storage/tests/test_error_recovery.lua
git commit -m "fix: contain crashes in workStep and handle instead of killing the controller"
```

---

## Task 2: Alerts auto-clear on success

**Files:**
- Modify: `controller/storage/app/coordinator.lua` (`_recordError`'s
  neighborhood, `_scanStep`, `_rebuildIndex`, `_enrichStep`,
  `_automationStep`)
- Test: `controller/storage/tests/test_error_recovery.lua`

**Interfaces:**
- Consumes: `Alerts:resolve(key)` (`app/alerts.lua:51-55`, unchanged, already handles an unknown key by returning `nil, "unknown alert ..."` without throwing).
- Produces: `Coordinator:_clearError(component)` -- new private method, called only from within `coordinator.lua`. No public signature changes.

Scope is deliberately the four call sites that retry every tick without
any operator action -- `_scanStep` (component `"scanner"`),
`_rebuildIndex` (components `"index"` and `"search"`), `_enrichStep`
(component `"metadata"`), and `_automationStep`'s service tick
(component is whichever of `recovery`/`imports`/`requests`/`crafts` was
selected). Discrete UI-action alerts (`_dispatch`, `handle`'s keymap
dispatch, `redraw`'s render calls) are out of scope here -- Task 3 makes
every alert manually dismissable, which is what those need.

- [ ] **Step 1: Write the failing tests**

Add to `controller/storage/tests/test_error_recovery.lua` (uses the
`Alerts` require added in Task 1 step 1; if Task 1 hasn't landed yet in
your working copy, add `local Alerts = require("app.alerts")` near the
top now):

```lua
    {name="a scanner failure clears once the same node scans successfully",run=function()
        local d=dependencies()
        d.alerts=Alerts.new(function() return 100 end)
        local coordinator=Coordinator.new(d)
        coordinator:tick(1)
        T.equal(#coordinator:viewModel().alerts,1)
        T.equal(coordinator:viewModel().alerts[1].key,"component_error:scanner")
        coordinator:tick(2)
        T.equal(#coordinator:viewModel().alerts,0)
    end},
    {name="an index rebuild failure clears once rebuilding succeeds",run=function()
        local d=dependencies()
        d.alerts=Alerts.new(function() return 100 end)
        local calls=0
        d.build_index=function()
            calls=calls+1
            if calls==1 then error("index corrupt") end
            return {items=function() return {} end}
        end
        local coordinator=Coordinator.new(d)
        coordinator:_rebuildIndex()
        T.equal(coordinator:viewModel().alerts[1].key,"component_error:index")
        coordinator:_rebuildIndex()
        T.equal(#coordinator:viewModel().alerts,0)
    end},
    {name="a search failure clears once search succeeds",run=function()
        local d=dependencies()
        d.alerts=Alerts.new(function() return 100 end)
        local calls=0
        d.search=function()
            calls=calls+1
            if calls==1 then error("search index locked") end
            return {}
        end
        local coordinator=Coordinator.new(d)
        coordinator:_rebuildIndex()
        T.equal(coordinator:viewModel().alerts[1].key,"component_error:search")
        coordinator:_rebuildIndex()
        T.equal(#coordinator:viewModel().alerts,0)
    end},
    {name="a metadata enrichment failure clears once enrichment succeeds",run=function()
        local d=dependencies()
        d.alerts=Alerts.new(function() return 100 end)
        local calls=0
        d.enrich_step=function(_,_,_,state)
            calls=calls+1
            if calls==1 then error("registry unavailable") end
            return state or {done=true,metadata={}}
        end
        local coordinator=Coordinator.new(d)
        coordinator:_rebuildIndex()
        coordinator:_enrichStep()
        T.equal(coordinator:viewModel().alerts[1].key,"component_error:metadata")
        coordinator:_enrichStep()
        T.equal(#coordinator:viewModel().alerts,0)
    end},
    {name="an automation service failure clears once its next tick succeeds",run=function()
        local d=dependencies()
        d.alerts=Alerts.new(function() return 100 end)
        d.requests=nil
        local calls=0
        d.imports={status=function() return {state="IDLE"} end,
            tick=function()
                calls=calls+1
                if calls==1 then error("push failed") end
                return {state="IDLE"}
            end}
        local coordinator=Coordinator.new(d)
        coordinator:_automationStep(1000)
        T.equal(coordinator:viewModel().alerts[1].key,"component_error:imports")
        coordinator:_automationStep(1001)
        T.equal(#coordinator:viewModel().alerts,0)
    end},
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd controller && lua storage/tests/run.lua tests.test_error_recovery`
Expected: all 5 new tests FAIL on their second assertion (the alert is
still present after the "successful" call), since nothing clears it yet.

- [ ] **Step 3: Add the `_clearError` helper**

In `controller/storage/app/coordinator.lua`, immediately after
`Coordinator:_recordError` (ends at line 108), add:

```lua
function Coordinator:_clearError(component)
    if self.deps.alerts and type(self.deps.alerts.resolve) == "function" then
        pcall(self.deps.alerts.resolve, self.deps.alerts, "component_error:" .. tostring(component))
    end
end
```

- [ ] **Step 4: Clear on a successful scan**

In `Coordinator:_scanStep`, the `if done then ... end` block currently
reads:

```lua
    if done then
        self.activeScan = nil
        if snapshot then
            snapshot.priority = active.node.priority
            self.snapshots[active.node.id] = snapshot
            self.scanRevision[active.node.id]=(self.scanRevision[active.node.id] or 0)+1
            self.scanCompletedAt[active.node.id] = now
            active.node.state, active.node.reason = "READY", nil
            self.scanFailedAt[active.node.id] = nil
            self.scanFailures[active.node.id] = nil
            self.generation = self.generation + 1
            self:_rebuildIndex()
        else self:_noteScanFailure(active.node, reason and reason.message or reason, now) end
        self.dirty = true
    end
```

Add one line before `self:_rebuildIndex()`:

```lua
    if done then
        self.activeScan = nil
        if snapshot then
            snapshot.priority = active.node.priority
            self.snapshots[active.node.id] = snapshot
            self.scanRevision[active.node.id]=(self.scanRevision[active.node.id] or 0)+1
            self.scanCompletedAt[active.node.id] = now
            active.node.state, active.node.reason = "READY", nil
            self.scanFailedAt[active.node.id] = nil
            self.scanFailures[active.node.id] = nil
            self.generation = self.generation + 1
            self:_clearError("scanner")
            self:_rebuildIndex()
        else self:_noteScanFailure(active.node, reason and reason.message or reason, now) end
        self.dirty = true
    end
```

- [ ] **Step 5: Clear on successful index rebuild and search**

Replace `Coordinator:_rebuildIndex`:

```lua
function Coordinator:_rebuildIndex()
    local snapshots = {}
    for _, node in ipairs(self.nodes) do
        local snapshot = self.snapshots[node.id]
        if snapshot and node.role == "storage" and node.state=="READY" then
            snapshots[#snapshots + 1] = snapshot
        end
    end
    local ok, result = pcall(self.deps.build_index, snapshots, self.metadata)
    if ok then
        self.index, self.enrichment = result, nil
        local queryOk, results = pcall(self.deps.search, result, self.uiState.query or "",
            self.deps.aliases or {}, self.deps.search_limit or self:_defaultSearchLimit())
        if queryOk then
            local reduced, effect = self.ui:reduce(self.uiState,
                {type="SYNC_RESULTS",results=results or {}})
            self.uiState = reduced or self.uiState
            self:_dispatch(effect)
        else self:_recordError("search", results) end
    else self:_recordError("index", result) end
end
```

with:

```lua
function Coordinator:_rebuildIndex()
    local snapshots = {}
    for _, node in ipairs(self.nodes) do
        local snapshot = self.snapshots[node.id]
        if snapshot and node.role == "storage" and node.state=="READY" then
            snapshots[#snapshots + 1] = snapshot
        end
    end
    local ok, result = pcall(self.deps.build_index, snapshots, self.metadata)
    if ok then
        self:_clearError("index")
        self.index, self.enrichment = result, nil
        local queryOk, results = pcall(self.deps.search, result, self.uiState.query or "",
            self.deps.aliases or {}, self.deps.search_limit or self:_defaultSearchLimit())
        if queryOk then
            self:_clearError("search")
            local reduced, effect = self.ui:reduce(self.uiState,
                {type="SYNC_RESULTS",results=results or {}})
            self.uiState = reduced or self.uiState
            self:_dispatch(effect)
        else self:_recordError("search", results) end
    else self:_recordError("index", result) end
end
```

- [ ] **Step 6: Clear on successful enrichment**

Replace `Coordinator:_enrichStep`:

```lua
function Coordinator:_enrichStep()
    if not self.index or not self.deps.enrich_step or not self.deps.registry then return end
    local ok, state = pcall(self.deps.enrich_step, self.index, self.deps.registry,
        self.metadataBudget, self.enrichment)
    if not ok then self:_recordError("metadata", state); return end
    self.enrichment = state
    if state and state.metadata and self.metadata ~= state.metadata then
        self.metadata = state.metadata
        self.dirty = true
    end
end
```

with:

```lua
function Coordinator:_enrichStep()
    if not self.index or not self.deps.enrich_step or not self.deps.registry then return end
    local ok, state = pcall(self.deps.enrich_step, self.index, self.deps.registry,
        self.metadataBudget, self.enrichment)
    if not ok then self:_recordError("metadata", state); return end
    self:_clearError("metadata")
    self.enrichment = state
    if state and state.metadata and self.metadata ~= state.metadata then
        self.metadata = state.metadata
        self.dirty = true
    end
end
```

- [ ] **Step 7: Clear on a successful automation tick**

In `Coordinator:_automationStep`, the tail currently reads:

```lua
    local ok,result=pcall(selected[2].tick,selected[2],self:_context(now))
    -- Automation advancing is user-visible: request progress, node states, alerts.
    self.dirty=true
    if not ok then self:_recordError(selected[1],result)
    elseif type(result)=="table" and result.rescan and
        (result.state=="VERIFYING" or result.state=="BLOCKED" or selected[1]=="crafts") then
        -- Crafting asks for a rescan from its own states, not VERIFYING or BLOCKED: the
        -- turtle drops output into the buffer without anything telling the controller.
        --
        -- A gate can never open while the asking service is TRANSFERRING, because
        -- _scanStep refuses to scan then and the revision it waits on never advances --
        -- which stops the whole rotation, including the transfer the gate is waiting on.
        -- Queue the rescan instead and let it happen once the transfer settles.
        if serviceState(selected[1],selected[2])=="TRANSFERRING" then
            self:requestRescan(result.rescan)
        else
            self:_setVerificationGate(selected[1],result.rescan)
        end
    end
end
```

Replace with:

```lua
    local ok,result=pcall(selected[2].tick,selected[2],self:_context(now))
    -- Automation advancing is user-visible: request progress, node states, alerts.
    self.dirty=true
    if not ok then self:_recordError(selected[1],result)
    else
        self:_clearError(selected[1])
        if type(result)=="table" and result.rescan and
            (result.state=="VERIFYING" or result.state=="BLOCKED" or selected[1]=="crafts") then
            -- Crafting asks for a rescan from its own states, not VERIFYING or BLOCKED: the
            -- turtle drops output into the buffer without anything telling the controller.
            --
            -- A gate can never open while the asking service is TRANSFERRING, because
            -- _scanStep refuses to scan then and the revision it waits on never advances --
            -- which stops the whole rotation, including the transfer the gate is waiting on.
            -- Queue the rescan instead and let it happen once the transfer settles.
            if serviceState(selected[1],selected[2])=="TRANSFERRING" then
                self:requestRescan(result.rescan)
            else
                self:_setVerificationGate(selected[1],result.rescan)
            end
        end
    end
end
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `cd controller && lua storage/tests/run.lua tests.test_error_recovery`
Expected: PASS. Then run the full suite: `lua storage/tests/run.lua` --
expect 0 failures, including the pre-existing "repeated component
failures coalesce into a single rising alert" test in
`test_operator_controls.lua` (that scanner never succeeds, so it's
unaffected by auto-clear).

- [ ] **Step 9: Commit**

```bash
git add controller/storage/app/coordinator.lua controller/storage/tests/test_error_recovery.lua
git commit -m "fix: clear component alerts automatically once the failing step next succeeds"
```

---

## Task 3: One Dismiss action, not acknowledge-plus-release-recovery

**Files:**
- Modify: `controller/storage/app/alerts.lua`
- Modify: `controller/storage/app/coordinator.lua:583-588` (`_dispatch`'s alert handler)
- Modify: `controller/storage/app/ui.lua` (reducer `:120+`, `_alerts` render `:825-853`, footer `:616`)
- Modify: `controller/storage/app/keymap.lua:74-78,145-148`
- Test: `controller/storage/tests/test_alerts.lua`, `test_ui.lua`, `test_keymap.lua`, `test_operator_controls.lua`, `test_ui_layout.lua`

**Interfaces:**
- Consumes: `Alerts:resolve(key)` (unchanged), `Recovery:status()` / `Recovery:resolve()` (unchanged, via the existing `RESOLVE_RECOVERY` effect and `ARM_RECOVERY_RELEASE`/`CANCEL_RECOVERY_RELEASE`/`CONFIRM_RECOVERY_RELEASE` reducer cases, all untouched).
- Produces: reducer command `DISMISS_ALERT` (replaces `ACKNOWLEDGE_ALERT`) and dispatch effect `DISMISS_ALERT` (replaces `ACKNOWLEDGE_ALERT`), both `{type="DISMISS_ALERT", index=<selection>}`.

`UI:reduce(current, command)` (`ui.lua:120`) never receives the view
model -- only `state` and `command` (confirmed at the call site,
`Coordinator:command` in `coordinator.lua:661`: `self.ui.reduce(self.ui,
self.uiState, command)`). So the reducer cannot itself know whether the
selected alert needs confirmation; that decision has to live in
`_dispatch`, which already holds both `self.deps.alerts` and
`self.deps.recovery`. The reducer stays exactly as simple as the
`ACKNOWLEDGE_ALERT` case it replaces (index only, no lookup);
`_dispatch` looks up the alert, and for the one alert that needs
confirmation (`key == "journal_recovery"` while `recovery` is
`BLOCKED`), re-enters `Coordinator:command` with
`{type="ARM_RECOVERY_RELEASE"}` to reuse the existing, untouched confirm
flow instead of resolving directly.

- [ ] **Step 1: Update the failing/changing tests**

Replace the two acknowledge-related tests in
`controller/storage/tests/test_alerts.lua`:

```lua
    { name = "alerts deduplicate conditions and preserve acknowledgement", run = function()
        local alerts = Alerts.new(function() return 100 end)
        alerts:set("pickup_full", "warning", "Pickup is full", { slots=0 })
        alerts:acknowledge("pickup_full")
        alerts:set("pickup_full", "warning", "Pickup is full", { slots=0 })
        local active = alerts:active()
        T.equal(#active, 1)
        T.equal(active[1].acknowledged, true)
        T.equal(active[1].occurrences, 2)
    end },
```

with:

```lua
    { name = "setting an alert again bumps its occurrence count", run = function()
        local alerts = Alerts.new(function() return 100 end)
        alerts:set("pickup_full", "warning", "Pickup is full", { slots=0 })
        alerts:set("pickup_full", "warning", "Pickup is full", { slots=0 })
        local active = alerts:active()
        T.equal(#active, 1)
        T.equal(active[1].occurrences, 2)
    end },
```

(the other two tests in that file -- "resolving an alert removes the
active condition" and "alerts sort by severity and first occurrence" --
are unaffected and stay as-is).

In `controller/storage/tests/test_ui.lua`, replace:

```lua
    { name = "acknowledging an alert dispatches the selected alert index", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.page="alerts"
        state=ui:reduce(state,{type="SYNC_ALERTS",count=4})
        state=ui:reduce(state,{type="MOVE",delta=1})
        local _,effect=ui:reduce(state,{type="ACKNOWLEDGE_ALERT"})
        T.equal(effect.type,"ACKNOWLEDGE_ALERT")
        T.equal(effect.index,2)
    end },
```

with:

```lua
    { name = "dismissing an alert dispatches the selected alert index", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.page="alerts"
        state=ui:reduce(state,{type="SYNC_ALERTS",count=4})
        state=ui:reduce(state,{type="MOVE",delta=1})
        local _,effect=ui:reduce(state,{type="DISMISS_ALERT"})
        T.equal(effect.type,"DISMISS_ALERT")
        T.equal(effect.index,2)
    end },
```

In `controller/storage/tests/test_keymap.lua`, replace:

```lua
    { name = "alerts page supports selection movement and acknowledgement", run = function()
        local state={mode="page",page="alerts"}
        T.equal(Keymap.command({"key",keys.up},state).delta,-1)
        T.equal(Keymap.command({"key",keys.down},state).delta,1)
        T.equal(Keymap.command({"key",keys.a},state).type,"ACKNOWLEDGE_ALERT")
    end },
    { name = "storage page scrolls but has no retry or acknowledge shortcuts", run = function()
        local state={mode="page",page="storage"}
        T.equal(Keymap.command({"key",keys.up},state).delta,-1)
        T.equal(Keymap.command({"key",keys.down},state).delta,1)
        T.equal(Keymap.command({"key",keys.r},state),nil)
        T.equal(Keymap.command({"key",keys.a},state),nil)
    end },
    { name = "recovery release on the alerts page requires a deliberate two key confirm", run = function()
        local state={mode="page",page="alerts"}
        local armed=Keymap.command({"key",keys.x},state)
        T.equal(armed.type,"ARM_RECOVERY_RELEASE")
        local armedState={mode="page",page="alerts",recovery_confirm_armed=true}
        T.equal(Keymap.command({"key",keys.x},armedState).type,"ARM_RECOVERY_RELEASE")
        T.equal(Keymap.command({"key",keys.enter},armedState).type,"CONFIRM_RECOVERY_RELEASE")
        T.equal(Keymap.command({"key",keys.up},armedState).type,"CANCEL_RECOVERY_RELEASE")
        T.equal(Keymap.command({"key",keys.f10},armedState).type,"CANCEL_RECOVERY_RELEASE")
        T.equal(Keymap.command({"key",keys.a},armedState).type,"CANCEL_RECOVERY_RELEASE")
    end },
```

with:

```lua
    { name = "alerts page supports selection movement and dismiss", run = function()
        local state={mode="page",page="alerts"}
        T.equal(Keymap.command({"key",keys.up},state).delta,-1)
        T.equal(Keymap.command({"key",keys.down},state).delta,1)
        T.equal(Keymap.command({"key",keys.a},state).type,"DISMISS_ALERT")
        T.equal(Keymap.command({"key",keys.x},state),nil)
    end },
    { name = "storage page scrolls but has no retry or dismiss shortcuts", run = function()
        local state={mode="page",page="storage"}
        T.equal(Keymap.command({"key",keys.up},state).delta,-1)
        T.equal(Keymap.command({"key",keys.down},state).delta,1)
        T.equal(Keymap.command({"key",keys.r},state),nil)
        T.equal(Keymap.command({"key",keys.a},state),nil)
    end },
    { name = "recovery release on the alerts page requires a deliberate two key confirm", run = function()
        local armedState={mode="page",page="alerts",recovery_confirm_armed=true}
        T.equal(Keymap.command({"key",keys.a},armedState).type,"ARM_RECOVERY_RELEASE")
        T.equal(Keymap.command({"key",keys.enter},armedState).type,"CONFIRM_RECOVERY_RELEASE")
        T.equal(Keymap.command({"key",keys.up},armedState).type,"CANCEL_RECOVERY_RELEASE")
        T.equal(Keymap.command({"key",keys.f10},armedState).type,"CANCEL_RECOVERY_RELEASE")
        T.equal(Keymap.command({"key",keys.x},armedState).type,"CANCEL_RECOVERY_RELEASE")
    end },
```

In `controller/storage/tests/test_operator_controls.lua`, replace the
`recordingAlerts` helper:

```lua
local function recordingAlerts(active)
    local calls = {acknowledge={}}
    return {
        active=function() return active end,
        acknowledge=function(_, key) calls.acknowledge[#calls.acknowledge + 1] = key; return true end,
        calls=calls,
    }
end
```

with:

```lua
local function recordingAlerts(active)
    local calls = {resolve={}}
    return {
        active=function() return active end,
        resolve=function(_, key) calls.resolve[#calls.resolve + 1] = key; return true end,
        calls=calls,
    }
end
```

then replace the test that exercises it:

```lua
    {name="acknowledging the selected alert calls the alert service by key", run=function()
        local alerts = recordingAlerts({{key="scanner_1"}, {key="scanner_2"}})
        local d = baseDeps(); d.alerts = alerts
        local coordinator = Coordinator.new(d)
        coordinator.uiState.page, coordinator.uiState.mode = "alerts", "page"
        coordinator.uiState.alert_selection = 2
        coordinator:command({type="ACKNOWLEDGE_ALERT"})
        T.arrayEqual(alerts.calls.acknowledge, {"scanner_2"})
    end},
```

with:

```lua
    {name="dismissing the selected alert calls the alert service by key", run=function()
        local alerts = recordingAlerts({{key="scanner_1"}, {key="scanner_2"}})
        local d = baseDeps(); d.alerts = alerts
        local coordinator = Coordinator.new(d)
        coordinator.uiState.page, coordinator.uiState.mode = "alerts", "page"
        coordinator.uiState.alert_selection = 2
        coordinator:command({type="DISMISS_ALERT"})
        T.arrayEqual(alerts.calls.resolve, {"scanner_2"})
    end},
    {name="dismissing a blocked recovery alert arms the confirm flow instead of resolving it", run=function()
        local alerts = recordingAlerts({{key="journal_recovery"}})
        local recovery = recordingRecovery()
        local d = baseDeps(); d.alerts, d.recovery = alerts, recovery
        local coordinator = Coordinator.new(d)
        coordinator.uiState.page, coordinator.uiState.mode = "alerts", "page"
        coordinator.uiState.alert_selection = 1
        coordinator:command({type="DISMISS_ALERT"})
        T.equal(#alerts.calls.resolve, 0, "the alert must not resolve until confirmed")
        T.equal(coordinator:viewModel().ui.recovery_confirm_armed, true)
    end},
```

and replace the full-keyboard-path test:

```lua
    {name="the full keyboard path acknowledges an alert after a two key recovery cancel", run=function()
        local alerts = recordingAlerts({{key="alert-1"}})
        local recovery = recordingRecovery()
        local d = baseDeps(); d.alerts, d.recovery = alerts, recovery
        local coordinator = Coordinator.new(d)
        coordinator:redraw()
        coordinator:handle({"key", keys.four})
        T.equal(coordinator:viewModel().ui.page, "alerts")
        coordinator:handle({"key", keys.x})
        T.equal(coordinator:viewModel().ui.recovery_confirm_armed, true)
        coordinator:handle({"key", keys.up})
        T.equal(coordinator:viewModel().ui.recovery_confirm_armed, false)
        T.equal(recovery.calls.resolve, 0)
        coordinator:handle({"key", keys.a})
        T.arrayEqual(alerts.calls.acknowledge, {"alert-1"})
    end},
```

with:

```lua
    {name="the full keyboard path dismisses an ordinary alert", run=function()
        local alerts = recordingAlerts({{key="alert-1"}})
        local d = baseDeps(); d.alerts = alerts
        local coordinator = Coordinator.new(d)
        coordinator:redraw()
        coordinator:handle({"key", keys.four})
        T.equal(coordinator:viewModel().ui.page, "alerts")
        coordinator:handle({"key", keys.a})
        T.arrayEqual(alerts.calls.resolve, {"alert-1"})
    end},
    {name="the full keyboard path arms recovery release for a blocked recovery alert and confirms it", run=function()
        local alerts = recordingAlerts({{key="journal_recovery"}})
        local recovery = recordingRecovery()
        local d = baseDeps(); d.alerts, d.recovery = alerts, recovery
        local coordinator = Coordinator.new(d)
        coordinator:redraw()
        coordinator:handle({"key", keys.four})
        T.equal(coordinator:viewModel().ui.page, "alerts")
        coordinator:handle({"key", keys.a})
        T.equal(coordinator:viewModel().ui.recovery_confirm_armed, true)
        T.equal(#alerts.calls.resolve, 0, "arming must not resolve the alert directly")
        coordinator:handle({"key", keys.up})
        T.equal(coordinator:viewModel().ui.recovery_confirm_armed, false)
        T.equal(recovery.calls.resolve, 0)
        coordinator:handle({"key", keys.a})
        T.equal(coordinator:viewModel().ui.recovery_confirm_armed, true)
        coordinator:handle({"key", keys.enter})
        T.equal(recovery.calls.resolve, 1)
    end},
```

Finally, in `controller/storage/tests/test_ui_layout.lua`, replace:

```lua
        state=UI.initialState(); state.page,state.mode="alerts","page"
        ui:render(state,view())
        T.contains(surface.line(18),"acknowledge")
        T.contains(surface.line(18),"release recovery")
```

with:

```lua
        state=UI.initialState(); state.page,state.mode="alerts","page"
        ui:render(state,view())
        T.contains(surface.line(18),"dismiss")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd controller && lua storage/tests/run.lua tests.test_alerts tests.test_ui tests.test_keymap tests.test_operator_controls tests.test_ui_layout`
Expected: multiple FAILs -- `DISMISS_ALERT`/`recovery_confirm_armed` are not yet produced by the reducer, dispatch, or keymap; the footer still says "acknowledge".

- [ ] **Step 3: Remove `Alerts:acknowledge`**

In `controller/storage/app/alerts.lua`, remove the `acknowledged=false,`
field from the new-alert table in `Alerts:set` (`alerts.lua:36`) and
delete `Alerts:acknowledge` entirely (`alerts.lua:43-49`):

```lua
function Alerts:set(key, severity, message, details)
    assert(type(key) == "string" and key ~= "", "alert key is required")
    assert(severityRank[severity], "invalid alert severity")
    assert(type(message) == "string" and message ~= "", "alert message is required")
    local now = self.clock()
    local alert = self.conditions[key]
    if alert then
        alert.severity = severity
        alert.message = message
        alert.details = copy(details)
        alert.updated_at = now
        alert.occurrences = alert.occurrences + 1
    else
        alert = {
            key=key, severity=severity, message=message, details=copy(details),
            created_at=now, updated_at=now, occurrences=1,
        }
        self.conditions[key] = alert
    end
    return copy(alert)
end

function Alerts:resolve(key)
```

- [ ] **Step 4: Rename the reducer case**

In `controller/storage/app/ui.lua`, replace:

```lua
    elseif kind == "ACKNOWLEDGE_ALERT" then
        return state, {type="ACKNOWLEDGE_ALERT",index=state.alert_selection}
```

with:

```lua
    elseif kind == "DISMISS_ALERT" then
        return state, {type="DISMISS_ALERT",index=state.alert_selection}
```

- [ ] **Step 5: Replace the dispatch handler with confirm routing**

In `controller/storage/app/coordinator.lua`, replace:

```lua
    elseif effect.type == "ACKNOWLEDGE_ALERT" and self.deps.alerts then
        local target = self.deps.alerts.active and self.deps.alerts:active()[effect.index]
        if target then
            local ok, reason = pcall(self.deps.alerts.acknowledge, self.deps.alerts, target.key)
            if not ok then self:_recordError("alert", reason) end
        end
```

with:

```lua
    elseif effect.type == "DISMISS_ALERT" and self.deps.alerts then
        local target = self.deps.alerts.active and self.deps.alerts:active()[effect.index]
        if target then
            local recoveryBlocked = self.deps.recovery and
                serviceState("recovery", self.deps.recovery) == "BLOCKED"
            if recoveryBlocked and target.key == "journal_recovery" then
                self:command({type="ARM_RECOVERY_RELEASE"})
            else
                local ok, reason = pcall(self.deps.alerts.resolve, self.deps.alerts, target.key)
                if not ok then self:_recordError("alert", reason) end
            end
        end
```

- [ ] **Step 6: Rebind the keymap**

In `controller/storage/app/keymap.lua`, the armed-recovery block
(`keymap.lua:74-78`) currently reads:

```lua
    if state.mode == "page" and state.page == "alerts" and state.recovery_confirm_armed then
        if key == keys.enter then return {type="CONFIRM_RECOVERY_RELEASE"} end
        if key == keys.x then return {type="ARM_RECOVERY_RELEASE"} end
        return {type="CANCEL_RECOVERY_RELEASE"}
    end
```

Change the re-arm key from `x` to `a`:

```lua
    if state.mode == "page" and state.page == "alerts" and state.recovery_confirm_armed then
        if key == keys.enter then return {type="CONFIRM_RECOVERY_RELEASE"} end
        if key == keys.a then return {type="ARM_RECOVERY_RELEASE"} end
        return {type="CANCEL_RECOVERY_RELEASE"}
    end
```

Then replace the unarmed alerts-page bindings (`keymap.lua:145-148`):

```lua
    if state.mode == "page" and state.page == "alerts" then
        if key == keys.a then return {type="ACKNOWLEDGE_ALERT"} end
        if key == keys.x then return {type="ARM_RECOVERY_RELEASE"} end
    end
```

with:

```lua
    if state.mode == "page" and state.page == "alerts" then
        if key == keys.a then return {type="DISMISS_ALERT"} end
    end
```

- [ ] **Step 7: Update the alerts row rendering and footer**

In `controller/storage/app/ui.lua`, `UI:_alerts` currently has:

```lua
    self:_list(bandRow + 1, regions.content.bottom, #alerts,
        math.max(1, math.min(#alerts, (state or {}).alert_selection or 1)),
        function(index, y, selected)
            local alert = alerts[index]
            -- An acknowledged alert keeps its severity colour but loses its urgency marker:
            -- it is still true, it is just no longer asking for attention.
            local severity = alert.severity == "critical" and Theme.role.alert or Theme.role.warn
            self:_row(y, selected, 1, regions.width,
                alert.acknowledged and "-" or "!", severity, tostring(alert.message), nil)
            hitRegions[#hitRegions + 1] = {x1=1, y1=y, x2=regions.width, y2=y,
                command={type="MOVE", delta=index - (state.alert_selection or 1)}}
        end)
```

Replace with:

```lua
    self:_list(bandRow + 1, regions.content.bottom, #alerts,
        math.max(1, math.min(#alerts, (state or {}).alert_selection or 1)),
        function(index, y, selected)
            local alert = alerts[index]
            local severity = alert.severity == "critical" and Theme.role.alert or Theme.role.warn
            self:_row(y, selected, 1, regions.width,
                "!", severity, tostring(alert.message), nil)
            hitRegions[#hitRegions + 1] = {x1=1, y1=y, x2=regions.width, y2=y,
                command={type="MOVE", delta=index - (state.alert_selection or 1)}}
        end)
```

And the footer hint (`ui.lua:616`):

```lua
    if state.page == "alerts" then
        return "Up/Down  A acknowledge  X+Enter release recovery"
    end
```

becomes:

```lua
    if state.page == "alerts" then
        return "Up/Down  A dismiss"
    end
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `cd controller && lua storage/tests/run.lua tests.test_alerts tests.test_ui tests.test_keymap tests.test_operator_controls tests.test_ui_layout`
Expected: PASS. Then run the full suite: `lua storage/tests/run.lua` --
0 failures.

- [ ] **Step 9: Commit**

```bash
git add controller/storage/app/alerts.lua controller/storage/app/coordinator.lua controller/storage/app/ui.lua controller/storage/app/keymap.lua controller/storage/tests/test_alerts.lua controller/storage/tests/test_ui.lua controller/storage/tests/test_keymap.lua controller/storage/tests/test_operator_controls.lua controller/storage/tests/test_ui_layout.lua
git commit -m "feat: replace acknowledge and release-recovery with one Dismiss action"
```

---

## Task 4: Final regression pass

**Files:** none (verification only).

**Interfaces:** none.

- [ ] **Step 1: Run the complete host suite**

Run: `cd controller && lua storage/tests/run.lua`
Expected: every test passes, 0 failures. Check the interpreter's exit
code directly (`echo $?` after the run) rather than piping through
anything that could mask a nonzero exit, per `CONTRIBUTING.md`.

- [ ] **Step 2: Run `git diff --check`**

Run: `git diff --check` (from the repo root)
Expected: no output (no trailing whitespace or conflict markers
introduced across the three tasks).

- [ ] **Step 3: Confirm nothing outside the planned file list changed**

Run: `git diff --stat main...HEAD` (or the appropriate base ref)
Expected: only files listed in Tasks 1-3 above appear --
`app/coordinator.lua`, `app/alerts.lua`, `app/ui.lua`, `app/keymap.lua`,
and the test files listed in each task. No changes to
`import_service.lua`, `craft_service.lua`, `requests.lua`,
`recovery.lua`, `monitor.lua`, or anything under `recipes/` or `turtle/`.

No commit for this task -- it's verification of the three commits
already made.
