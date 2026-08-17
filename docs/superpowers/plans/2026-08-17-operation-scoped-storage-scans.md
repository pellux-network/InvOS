# Operation-Scoped Storage Scans Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make normal Drop-off imports and retrievals scan only the storage nodes their final transfer steps can change, with a bounded complete-pool fallback when a targeted plan is stale or incomplete.

**Architecture:** Requests and imports tentatively plan from current snapshots, ask the coordinator to refresh the tentative endpoints, then re-plan before entering `TRANSFERRING`. A pure storage-scope module supplies the same touched-node definition to planning and transfer reconciliation, while existing journal schemas persist that narrowed scope for verification and recovery.

**Tech Stack:** Lua 5.2-compatible runtime code, Lua 5.4 host tests, Python 3 emulator harness, CraftOS-PC.

**Spec:** `docs/superpowers/specs/2026-08-17-operation-scoped-storage-scans-design.md`

## Global Constraints

- No inventory call may run until every endpoint in the final plan has a fresh scan.
- Exact source and import-destination preflight remains immediately before the first push.
- Pre-call changes replan; post-call uncertainty reconciles and is never replayed.
- Journal schemas 1, 2, 3, and 4 remain valid and recoverable without migration.
- The coordinator retains exactly one scanner/automation work loop.
- Planning fallback performs at most one complete relevant-pool refresh per attempt.
- Runtime Lua must remain compatible with CC:Tweaked's Lua 5.2.
- Runtime paths must be added to `controller/storage/deployment_manifest.lua`; tests and emulator helpers must not be deployed.
- The planner's priority policy over known snapshots remains unchanged; globally freshest placement is not promised on the narrow path.

---

### Task 1: Define the shared touched-storage scope

**Files:**
- Create: `controller/storage/core/storage_scope.lua`
- Create: `controller/storage/tests/test_storage_scope.lua`
- Modify: `controller/storage/tests/run.lua`
- Modify: `controller/storage/deployment_manifest.lua`

**Interfaces:**
- Produces: `StorageScope.select(kind, steps, snapshots) -> selectedSnapshots, nodeIds` on success.
- Produces: `nil, nil, reason` on failure, where `reason` has `code`, `message`, and `retryable=false`.
- `kind` is exactly `"request"` or `"import"`; requests select `step.source_name`, imports select `step.destination_name`.
- `nodeIds` and `selectedSnapshots` are sorted by `snapshot.node_id` and contain each touched storage node once.

- [ ] **Step 1: Register the new failing test module**

Add `"tests.test_storage_scope"` beside the reconciliation and transfer modules in `controller/storage/tests/run.lua`. Add tests that use two touched nodes and one unrelated node:

```lua
local Scope=require("core.storage_scope")
local T=require("tests.mock_cc")

local function snapshot(id,name,health)
    return {node_id=id,peripheral_name=name,health=health or "READY",slots={}}
end

return {
    {name="request scope contains only unique source storage nodes",run=function()
        local selected,ids=Scope.select("request",{
            {source_name="store_b",destination_name="pickup"},
            {source_name="store_a",destination_name="pickup"},
            {source_name="store_a",destination_name="pickup"},
        },{snapshot("c","unused"),snapshot("b","store_b"),snapshot("a","store_a")})
        T.arrayEqual(ids,{"a","b"})
        T.equal(#selected,2)
        T.equal(selected[1].node_id,"a")
    end},
    {name="import scope contains only destination storage nodes",run=function()
        local _,ids=Scope.select("import",{
            {source_name="drop",destination_name="store_b"},
        },{snapshot("a","unused"),snapshot("b","store_b")})
        T.arrayEqual(ids,{"b"})
    end},
    {name="an unhealthy touched node remains in scope",run=function()
        local selected,ids=Scope.select("request",{{source_name="store_a"}},
            {snapshot("a","store_a","ERROR")})
        T.arrayEqual(ids,{"a"})
        T.equal(selected[1].health,"ERROR")
    end},
    {name="missing and duplicate mappings fail closed",run=function()
        local selected,_,reason=Scope.select("request",{{source_name="missing"}},
            {snapshot("a","store_a")})
        T.equal(selected,nil);T.equal(reason.code,"STORAGE_SCOPE_MISSING")
        selected,_,reason=Scope.select("request",{{source_name="store"}},
            {snapshot("a","store"),snapshot("b","store")})
        T.equal(selected,nil);T.equal(reason.code,"DUPLICATE_STORAGE_BINDING")
    end},
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run from `controller/`:

```powershell
lua storage/tests/run.lua tests.test_storage_scope
```

Expected: FAIL because `core.storage_scope` is not found.

- [ ] **Step 3: Implement the pure scope selector**

Create `controller/storage/core/storage_scope.lua` with this structure:

```lua
local M={}

local function failure(code,message)
    return {code=code,message=message,retryable=false}
end

function M.select(kind,steps,snapshots)
    local field=kind=="request" and "source_name" or
        kind=="import" and "destination_name" or nil
    if not field or type(steps)~="table" or #steps<1 then
        return nil,nil,failure("INVALID_STORAGE_SCOPE","Transfer steps and direction are required")
    end
    local wanted={}
    for _,step in ipairs(steps) do
        local name=type(step)=="table" and step[field]
        if type(name)~="string" or name=="" then
            return nil,nil,failure("INVALID_STORAGE_SCOPE","Every transfer step needs a storage endpoint")
        end
        wanted[name]=true
    end
    -- Validate node_id/peripheral_name, reject duplicate ids and bindings, select wanted,
    -- prove every wanted binding was found, then sort selected by node_id and derive nodeIds.
end

return M
```

Do not filter on `health`; reconciliation must see an unhealthy touched node and report an incomplete scope.

- [ ] **Step 4: Add the runtime module to the deployment allow-list**

Add `"storage/core/storage_scope.lua"` next to `storage/core/scanner.lua` and `storage/core/transfer.lua` in `controller/storage/deployment_manifest.lua`.

- [ ] **Step 5: Run focused and deployment tests and verify GREEN**

```powershell
lua storage/tests/run.lua tests.test_storage_scope
lua storage/tests/run.lua tests.test_deployment
```

Expected: both modules report only PASS lines and exit 0.

- [ ] **Step 6: Commit**

```powershell
git add controller/storage/core/storage_scope.lua controller/storage/tests/test_storage_scope.lua controller/storage/tests/run.lua controller/storage/deployment_manifest.lua
git commit -m "feat(core): define touched storage scopes"
```

---

### Task 2: Persist and verify only the touched storage footprint

**Files:**
- Modify: `controller/storage/core/transfer.lua`
- Modify: `controller/storage/tests/test_transfer.lua`
- Modify: `controller/storage/tests/test_transfer_batch.lua`
- Modify: `controller/storage/tests/test_transfer_multibatch.lua`

**Interfaces:**
- Consumes: `StorageScope.select(kind, steps, storageSnapshots)` from Task 1.
- Produces: new journals whose `storage_node_ids` are the union of storage endpoints selected from final steps.
- Existing `Transfer:verify(journal, allStorageSnapshots)` and `Transfer:recover(...)` signatures remain unchanged.

- [ ] **Step 1: Add failing footprint tests**

Add an unrelated snapshot to each transfer family and assert it is absent from new journals:

```lua
local function unrelated()
    return {node_id="unused",peripheral_name="unused",health="READY",slots={}}
end

-- Retrieval: source storage is selected.
local result=transfer:executeMultiBatch(requestOperation,requestSteps(),
    {sourceSnapshot(20),unrelated()})
T.arrayEqual(result.journal.batch.storage_node_ids,{"source"})

-- Import: destination storage is selected.
local result=transfer:executeMultiBatch(importOperation,mixedSteps(),
    {storage(20,10)[1],unrelated()})
T.arrayEqual(result.journal.batch.storage_node_ids,{"store"})
```

Add a two-destination case asserting the sorted union, and verify the journal successfully without passing the unrelated node afterward. Keep the existing schema-2 broad-scope fixture and add an assertion that it still waits when one recorded node is absent.

- [ ] **Step 2: Run transfer tests and verify RED**

```powershell
lua storage/tests/run.lua tests.test_transfer
lua storage/tests/run.lua tests.test_transfer_batch
lua storage/tests/run.lua tests.test_transfer_multibatch
```

Expected: new journal scope assertions fail because the baseline still captures every supplied snapshot.

- [ ] **Step 3: Apply scope selection before every baseline capture**

At the top of `core/transfer.lua` require the new module:

```lua
local StorageScope=require("core.storage_scope")
```

Add one internal adapter used by `execute`, `executeBatch`, and `executeMultiBatch`:

```lua
local function scopedSnapshots(operation,steps,storageSnapshots)
    local selected,_,scopeReason=StorageScope.select(operation.kind,steps,storageSnapshots)
    if not selected then return nil,scopeReason end
    return selected
end
```

Before `reconciliation.capture` or `captureMany`, call it with `{step}` or `steps`. On failure, return `FAILED`, issue no journal write or push, preserve the scope reason's code/message, and mark the failure non-ambiguous. Pass only `selected` to baseline capture. Do not change `verify`, `recover`, journal validators, or schema numbers.

- [ ] **Step 4: Run focused transfer and recovery tests and verify GREEN**

```powershell
lua storage/tests/run.lua tests.test_transfer
lua storage/tests/run.lua tests.test_transfer_batch
lua storage/tests/run.lua tests.test_transfer_multibatch
lua storage/tests/run.lua tests.test_recovery
lua storage/tests/run.lua tests.test_reconciliation
```

Expected: all pass. Existing broad journals still use every ID already persisted in the journal.

- [ ] **Step 5: Commit**

```powershell
git add controller/storage/core/transfer.lua controller/storage/tests/test_transfer.lua controller/storage/tests/test_transfer_batch.lua controller/storage/tests/test_transfer_multibatch.lua
git commit -m "perf(transfer): reconcile touched storage nodes"
```

---

### Task 3: Implement the bounded planning-refresh decision helper

**Files:**
- Create: `controller/storage/app/planning_refresh.lua`
- Create: `controller/storage/tests/test_planning_refresh.lua`
- Modify: `controller/storage/tests/run.lua`
- Modify: `controller/storage/deployment_manifest.lua`

**Interfaces:**
- Produces: `PlanningRefresh.advance(previous, candidateNodeIds, hasPlan) -> action, nextState`.
- `action` is exactly `"SCAN"`, `"COMMIT"`, or `"FINAL_NO_PLAN"`.
- Produces: `PlanningRefresh.names(state, storageSnapshots, endpointSnapshot) -> names` or `nil, reason`.
- State shape: `{mode="targeted"|"full", storage_node_ids={...}, retargets=0|1}`.

- [ ] **Step 1: Write the decision-table tests**

Create cases for every transition:

```lua
local Refresh=require("app.planning_refresh")
local T=require("tests.mock_cc")

local action,state=Refresh.advance(nil,{"a"},true)
T.equal(action,"SCAN");T.equal(state.mode,"targeted")
action=Refresh.advance(state,{"a"},true)
T.equal(action,"COMMIT")
action,state=Refresh.advance({mode="targeted",storage_node_ids={"a"},retargets=0},{"b"},true)
T.equal(action,"SCAN");T.equal(state.retargets,1)
action,state=Refresh.advance(state,{"c"},true)
T.equal(action,"SCAN");T.equal(state.mode,"full")
action=Refresh.advance(state,{"c"},true)
T.equal(action,"COMMIT")
action,state=Refresh.advance(nil,{},false)
T.equal(action,"SCAN");T.equal(state.mode,"full")
action=Refresh.advance(state,{},false)
T.equal(action,"FINAL_NO_PLAN")
```

Test that `names` returns sorted unique targeted IDs plus the endpoint ID, while full mode returns every storage `node_id` plus the endpoint. Missing endpoint IDs and malformed storage snapshots return a structured error.

- [ ] **Step 2: Run the focused test and verify RED**

```powershell
lua storage/tests/run.lua tests.test_planning_refresh
```

Expected: FAIL because `app.planning_refresh` is not found.

- [ ] **Step 3: Implement the pure helper**

Use array equality, not table identity, to compare scopes. Sort and de-duplicate every returned array. The central decision must be:

```lua
function M.advance(previous,candidateNodeIds,hasPlan)
    local candidate=sortedUnique(candidateNodeIds)
    if not hasPlan then
        if previous and previous.mode=="full" then return "FINAL_NO_PLAN" end
        return "SCAN",{mode="full",storage_node_ids={},retargets=0}
    end
    if not previous then
        return "SCAN",{mode="targeted",storage_node_ids=candidate,retargets=0}
    end
    if previous.mode=="full" or arraysEqual(previous.storage_node_ids,candidate) then
        return "COMMIT"
    end
    if previous.retargets<1 then
        return "SCAN",{mode="targeted",storage_node_ids=candidate,retargets=1}
    end
    return "SCAN",{mode="full",storage_node_ids={},retargets=previous.retargets}
end
```

- [ ] **Step 4: Register and deploy the helper**

Add `tests.test_planning_refresh` to `tests/run.lua` and `storage/app/planning_refresh.lua` to `deployment_manifest.lua`.

- [ ] **Step 5: Run helper and deployment tests and verify GREEN**

```powershell
lua storage/tests/run.lua tests.test_planning_refresh
lua storage/tests/run.lua tests.test_deployment
```

- [ ] **Step 6: Commit**

```powershell
git add controller/storage/app/planning_refresh.lua controller/storage/tests/test_planning_refresh.lua controller/storage/tests/run.lua controller/storage/deployment_manifest.lua
git commit -m "feat(app): bound targeted planning refreshes"
```

---

### Task 4: Let services drive planning gates through the coordinator

**Files:**
- Modify: `controller/storage/app/coordinator.lua`
- Modify: `controller/storage/tests/test_coordinator_transfers.lua`
- Modify: `controller/storage/tests/test_craft_coordination.lua`

**Interfaces:**
- Consumes: a service tick result `{state="PLANNING", rescan={node IDs...}}`.
- Produces: the existing revision gate for that service, tagged with phase `"planning"`.
- Produces: role context placeholders with `node_id`, `peripheral_name`, `slots={}`, and live `health` before a role's first successful scan.

- [ ] **Step 1: Replace the old complete-pool planning expectation with failing protocol tests**

Add coordinator tests proving:

```lua
-- The first PLANNING tick is allowed to run without an automatic all-storage gate.
-- If it returns rescan={"source"}, the coordinator scans source before ticking it again.
-- Unrelated storage is not scanned by that targeted gate.
-- A PLANNING result from imports adds no implicit Pickup scan.
-- Craft PLANNING still receives the existing full storage + craft_buffer gate.
```

Add a context test where Drop-off or Pickup has not completed its first scan and assert the service still receives a placeholder carrying its configured `node_id`, peripheral name, empty slots, and non-READY health.

- [ ] **Step 2: Run coordinator-focused tests and verify RED**

```powershell
lua storage/tests/run.lua tests.test_coordinator_transfers
lua storage/tests/run.lua tests.test_craft_coordination
```

Expected: request/import ticks remain blocked behind the old complete-pool planning gate, and role placeholders are absent.

- [ ] **Step 3: Implement role placeholders in `_context`**

Add a context-only role accessor that mirrors storage placeholder construction:

```lua
function Coordinator:_contextForRole(role)
    for _,node in ipairs(self.nodes) do
        if node.role==role then
            local snapshot=copy(self.snapshots[node.id] or {
                node_id=node.id,peripheral_name=node.peripheral_name,slots={}})
            snapshot.health=node.state
            return snapshot
        end
    end
end
```

Use it for `dropoff`, `pickup`, and `craft_buffer` in `_context`. Do not change `_snapshotForRole`, which other read paths may use.

- [ ] **Step 4: Change planning-gate ownership**

In `_automationStep`, retain the automatic `_preflightNames` gate only when `crafts` reports `PLANNING`. Requests and imports must be selected and ticked normally while planning.

Extend result handling so a table with `result.state=="PLANNING"` and a non-empty `result.rescan` calls:

```lua
self:_setVerificationGate(selected[1],result.rescan,"planning")
```

Keep the existing `TRANSFERRING` deadlock guard and verification/block/craft rescan behavior unchanged.

- [ ] **Step 5: Run coordinator, craft, and transfer-race tests and verify GREEN**

```powershell
lua storage/tests/run.lua tests.test_coordinator_transfers
lua storage/tests/run.lua tests.test_craft_coordination
lua storage/tests/run.lua tests.test_transfer_rescan_race
```

- [ ] **Step 6: Commit**

```powershell
git add controller/storage/app/coordinator.lua controller/storage/tests/test_coordinator_transfers.lua controller/storage/tests/test_craft_coordination.lua
git commit -m "feat(coordinator): accept service planning gates"
```

---

### Task 5: Give retrievals a targeted plan-refresh cycle

**Files:**
- Modify: `controller/storage/app/requests.lua`
- Modify: `controller/storage/app/lifecycle.lua`
- Modify: `controller/storage/tests/test_requests.lua`
- Modify: `controller/storage/tests/test_acceptance.lua`

**Interfaces:**
- Consumes: `StorageScope.select("request", plan, context.storage)` and `PlanningRefresh.advance/names`.
- Stores: `request.planning_refresh` only while planning freshness is unresolved.
- Produces: `{state="PLANNING",rescan={source node IDs..., destination node ID}}` without issuing a transfer.

- [ ] **Step 1: Add failing request state-machine tests**

Use a planner fake with controlled plans and a transfer fake counting calls. Cover:

```lua
-- First PLANNING tick with source a: returns PLANNING/rescan {a,pickup}; transfer calls = 0.
-- Second tick with the same source a: commits steps and transitions to TRANSFERRING.
-- Plan shifts a -> b once: returns a second targeted gate for b and does not transfer.
-- Plan shifts again b -> c: returns one full storage + pickup gate.
-- No plan initially: returns one full gate; no plan after that uses existing block behavior.
-- SOURCE_CHANGED with no journal returns to PLANNING; no push is retried blindly.
-- COMPLETE, CANCELLED, explicit retry, and a committed plan clear planning_refresh.
```

Add an acceptance assertion that unrelated storage scan counts do not grow between a one-node and many-node request whose item is stored in one node.

- [ ] **Step 2: Run request tests and verify RED**

```powershell
lua storage/tests/run.lua tests.test_requests
lua storage/tests/run.lua tests.test_acceptance
```

Expected: planning advances directly to `TRANSFERRING` and never returns a targeted planning rescan.

- [ ] **Step 3: Implement tentative and post-gate request planning**

Require the two helpers at the top of `requests.lua`. Refactor the current `PLANNING` body so it always computes `plan`, maps its touched nodes with `StorageScope.select`, and asks `PlanningRefresh.advance` what to do.

```lua
local action,nextRefresh=PlanningRefresh.advance(request.planning_refresh,nodeIds,#plan>0)
if action=="SCAN" then
    request.planning_refresh=nextRefresh
    request.rescan=assert(PlanningRefresh.names(nextRefresh,context.storage,destination))
    return copy(request)
elseif action=="FINAL_NO_PLAN" then
    request.planning_refresh,request.rescan=nil,nil
    self:_block(request,context,planReason)
elseif action=="COMMIT" then
    request.planning_refresh,request.rescan=nil,nil
    -- copy the existing batch-limited final steps, then transition to TRANSFERRING
end
```

If scope mapping fails, treat it like an unstable candidate and request the full refresh rather than committing. Preserve `batchLimit` and destination-role behavior.

- [ ] **Step 4: Replan cleanly after pre-call invalidation**

Allow `request` transition `TRANSFERRING -> PLANNING` in `lifecycle.lua`. Use it only when `Transfer:executeMultiBatch` returns `SOURCE_CHANGED` or `DESTINATION_CHANGED` with no journal. Clear steps and refresh bookkeeping; do not increment delivered count, retire a journal, or call `verify`.

- [ ] **Step 5: Run focused request, lifecycle, and acceptance tests and verify GREEN**

```powershell
lua storage/tests/run.lua tests.test_requests
lua storage/tests/run.lua tests.test_lifecycle
lua storage/tests/run.lua tests.test_acceptance
lua storage/tests/run.lua tests.test_coordinator_transfers
```

- [ ] **Step 6: Commit**

```powershell
git add controller/storage/app/requests.lua controller/storage/app/lifecycle.lua controller/storage/tests/test_requests.lua controller/storage/tests/test_acceptance.lua
git commit -m "perf(requests): refresh only planned endpoints"
```

---

### Task 6: Give imports the same targeted plan-refresh cycle

**Files:**
- Modify: `controller/storage/app/import_service.lua`
- Modify: `controller/storage/app/lifecycle.lua`
- Modify: `controller/storage/tests/test_import_service.lua`
- Modify: `controller/storage/tests/test_import_freshness.lua`
- Modify: `controller/storage/tests/test_import_multisource.lua`
- Modify: `controller/storage/tests/test_acceptance.lua`

**Interfaces:**
- Consumes: `StorageScope.select("import", steps, context.storage)` and `PlanningRefresh.advance/names`.
- Stores: `active.planning_refresh` only while planning freshness is unresolved.
- Produces: `{state="PLANNING",rescan={dropoff node ID, destination node IDs...}}`.

- [ ] **Step 1: Add failing import state-machine tests**

Mirror the request coverage with import-specific safety:

```lua
-- Tentative destinations are rescanned with Drop-off before TRANSFERRING.
-- A destination change retargets once, then widens once.
-- No capacity triggers one full storage + Drop-off scan before deferral.
-- Multi-source/multi-identity plans union every destination node once.
-- SOURCE_CHANGED or DESTINATION_CHANGED before journaling returns to PLANNING.
-- A source that changed during the gate is refreshed/dropped by _refreshSources.
-- Complete, abandon, retry, and commit paths clear planning_refresh.
```

In acceptance, compare imports with one and many unrelated empty storage nodes and assert the targeted transaction scans touch only Drop-off and the selected destination.

- [ ] **Step 2: Run import tests and verify RED**

```powershell
lua storage/tests/run.lua tests.test_import_service
lua storage/tests/run.lua tests.test_import_freshness
lua storage/tests/run.lua tests.test_import_multisource
lua storage/tests/run.lua tests.test_acceptance
```

- [ ] **Step 3: Implement import planning refreshes**

Keep `_refreshSources`, owned-slot reservation, `slotBatchLimit`, and `batchLimit` unchanged. After building candidate `steps`, derive destination node IDs and apply the same action table as requests. For `SCAN`, add `context.dropoff` as the endpoint passed to `PlanningRefresh.names`. For `FINAL_NO_PLAN`, run the existing deferral and `_abandon("NO_PLAN", ...)` behavior.

Do not write `active.steps` or transition to `TRANSFERRING` until action `COMMIT` is returned.

- [ ] **Step 4: Replan cleanly after strict import preflight rejects an endpoint**

Allow `import` transition `TRANSFERRING -> PLANNING` in `lifecycle.lua`. Only take it for pre-call `SOURCE_CHANGED` or `DESTINATION_CHANGED` results without a journal. Clear final steps and planning state; the next planning tick rebuilds sources and requests the proper gate.

- [ ] **Step 5: Run focused import, transfer, and acceptance tests and verify GREEN**

```powershell
lua storage/tests/run.lua tests.test_import_service
lua storage/tests/run.lua tests.test_import_freshness
lua storage/tests/run.lua tests.test_import_multisource
lua storage/tests/run.lua tests.test_transfer_multibatch
lua storage/tests/run.lua tests.test_acceptance
```

- [ ] **Step 6: Commit**

```powershell
git add controller/storage/app/import_service.lua controller/storage/app/lifecycle.lua controller/storage/tests/test_import_service.lua controller/storage/tests/test_import_freshness.lua controller/storage/tests/test_import_multisource.lua controller/storage/tests/test_acceptance.lua
git commit -m "perf(imports): refresh only planned endpoints"
```

---

### Task 7: Prioritize overdue Drop-off discovery

**Files:**
- Modify: `controller/storage/app/coordinator.lua`
- Modify: `controller/storage/tests/test_coordinator.lua`
- Modify: `controller/storage/tests/test_scan_backoff.lua`

**Interfaces:**
- Changes only idle `_staleNodeId(now)` ordering.
- Targeted queue ordering, active scans, scan failure backoff, and storage age rotation stay unchanged.

- [ ] **Step 1: Add failing scheduling tests**

Construct snapshots where ten storage nodes are much older than Drop-off, but Drop-off has just crossed `scanRefreshInterval`. Assert Drop-off begins next. Also assert:

```lua
-- A Drop-off still inside the interval does not jump the queue.
-- A backing-off Drop-off does not bypass backoff.
-- After Drop-off completes, the oldest storage node resumes the ordinary rotation.
-- Explicit requestRescan remains ahead of all idle scheduling.
```

- [ ] **Step 2: Run scanner scheduling tests and verify RED**

```powershell
lua storage/tests/run.lua tests.test_coordinator
lua storage/tests/run.lua tests.test_scan_backoff
```

- [ ] **Step 3: Implement a two-tier stale choice**

In `_staleNodeId`, compute the existing age and backoff eligibility once per node. Track the oldest eligible Drop-off separately from the oldest other node, then return:

```lua
return overdueDropoffId or oldestOtherId
```

Only consider Drop-off overdue when it has no snapshot or its age is at least `scanRefreshInterval`. Do not include Pickup or storage nodes in the priority tier.

- [ ] **Step 4: Run scheduling and responsiveness tests and verify GREEN**

```powershell
lua storage/tests/run.lua tests.test_coordinator
lua storage/tests/run.lua tests.test_scan_backoff
lua storage/tests/run.lua tests.test_responsiveness
```

- [ ] **Step 5: Commit**

```powershell
git add controller/storage/app/coordinator.lua controller/storage/tests/test_coordinator.lua controller/storage/tests/test_scan_backoff.lua
git commit -m "perf(scanning): prioritize overdue drop-off scans"
```

---

### Task 8: Add an exact emulator regression for node-count-independent retrievals

**Files:**
- Modify: `tools/emulator/scenario.py`
- Modify: `tools/emulator/smoke/boot.lua`
- Modify: `tools/emulator/smoke/world.lua`
- Create: `tools/emulator/test_scan_scaling.py`

**Interfaces:**
- `Scenario(..., environment=None)` serializes a table of primitive `Main.run` overrides.
- A profiled emulator watches `/profile-reset`; consuming it resets counters before the next profile flush.
- `profile.lua` remains a serialized table containing `total` and per-method `calls`.

- [ ] **Step 1: Write the failing emulator test**

Create a helper that boots stock in one source node with `storage_count` set to 1 and 20, sets `environment={"scan_refresh_interval":1000000}`, and enables profiling. After READY:

```python
reset = os.path.join(harness.computer_dir, "profile-reset")
open(reset, "w", encoding="utf-8").close()
wait_until_removed(reset)
queue_one_iron_ingot_through_the_terminal(active)
active.press("three")
active.wait_for_text("1 / 1", timeout=30)
calls = read_profile(harness.computer_dir)
self.assertEqual(calls["pushItems"], 1)
self.assertEqual(calls["size"], 3)
self.assertEqual(calls["list"], 3)
```

Assert both node counts produce the same three transaction scans: source and Pickup planning scans, then source verification.

- [ ] **Step 2: Run the emulator test and verify RED**

From `tools/emulator/`:

```powershell
python -m unittest test_scan_scaling
```

Expected: FAIL because scenario environment overrides and profile reset do not exist, and current all-node gates exceed three scans.

- [ ] **Step 3: Add scenario environment injection**

Store `environment` on `Scenario` and serialize it beside `world`. In `smoke/boot.lua`, when an environment exists, load `storage/main.lua` as a module by passing a non-nil sentinel to its chunk, then call:

```lua
local chunk=assert(loadfile("/storage/main.lua"))
local Main=chunk("emulator")
Main.run(scenario.environment)
```

Retain the existing `shell.run` path when no environment is configured so all current scenarios boot identically.

- [ ] **Step 4: Add profile reset support**

In `World.profilePeripherals`, keep counters in mutable upvalues and expose:

```lua
World.resetProfile=function()
    counts,total={},0
end
```

In `flushProfileForever`, if `/profile-reset` exists, call `world.resetProfile()`, delete the marker, then flush. This is emulator-only control state in a scratch computer directory; controller runtime never sees it.

- [ ] **Step 5: Run the new emulator test and existing smoke tests and verify GREEN**

```powershell
python -m unittest test_scan_scaling
python -m unittest test_smoke
```

Expected: the new test reports identical `size/list/pushItems` counts at 1 and 20 nodes, and existing smoke tests pass.

- [ ] **Step 6: Commit**

```powershell
git add tools/emulator/scenario.py tools/emulator/smoke/boot.lua tools/emulator/smoke/world.lua tools/emulator/test_scan_scaling.py
git commit -m "test(emulator): lock operation-scoped scan counts"
```

---

### Task 9: Measure the result, document it, and run all gates

**Files:**
- Modify: `docs/backlog.md`
- Modify if measurements require correction: `docs/superpowers/specs/2026-08-17-operation-scoped-storage-scans-design.md`

**Interfaces:**
- No runtime interface changes.
- Produces fresh before/after measurements and final repository verification evidence.

- [ ] **Step 1: Run focused host tests as one regression group**

```powershell
Set-Location controller
lua storage/tests/run.lua tests.test_storage_scope
lua storage/tests/run.lua tests.test_planning_refresh
lua storage/tests/run.lua tests.test_coordinator_transfers
lua storage/tests/run.lua tests.test_requests
lua storage/tests/run.lua tests.test_import_service
lua storage/tests/run.lua tests.test_transfer_multibatch
lua storage/tests/run.lua tests.test_acceptance
```

Expected: every command exits 0.

- [ ] **Step 2: Re-run the 1/5/10/20-node emulator measurements**

Use `scenario.configured(stock=[{"id":"minecraft:iron_ingot","count":64}], storage_count=N)` for retrieval and a Drop-off-preseeded empty-storage scenario for import. Record wall times and exact profiled operation counts. Confirm:

```text
retrieval size/list calls: independent of unrelated node count
import targeted scan count: independent of unrelated node count when one destination is used
pushItems calls: unchanged for the same work
```

If counts grow with unrelated nodes, stop and return to the relevant task; do not weaken the assertion.

- [ ] **Step 3: Update the performance backlog with measured facts**

Replace the generic scanner-only note in `docs/backlog.md` with the before/after node-count result, the three-scan retrieval/four-scan import model, and the bounded full-refresh fallback. Do not claim Minecraft wall-clock figures from emulator timings.

- [ ] **Step 4: Run the complete host Lua suite**

From `controller/`:

```powershell
lua storage/tests/run.lua
```

Expected: `RESULT <count> passed, 0 failed`, exit 0.

- [ ] **Step 5: Run host-side tool tests**

From `tools/`:

```powershell
python -m unittest test_recipe_pack test_recipe_import test_deploy
```

Expected: `OK`, exit 0.

- [ ] **Step 6: Run the complete CraftOS-PC emulator suite**

From the repository root:

```powershell
python tools/emulator/run_tests.py all
```

Expected: every category passes and the command exits 0.

- [ ] **Step 7: Verify the final diff**

```powershell
git diff --check
git status --short
git diff --stat 15a6c9f..HEAD
```

Expected: no whitespace errors; only planned runtime, test, emulator, spec/plan, and performance-documentation files are changed.

- [ ] **Step 8: Commit final measurements/documentation**

```powershell
git add docs/backlog.md docs/superpowers/specs/2026-08-17-operation-scoped-storage-scans-design.md
git commit -m "docs(perf): record operation-scoped scan results"
```

- [ ] **Step 9: Request code review**

Review the full range from base `15a6c9f` through branch HEAD against the approved spec. Fix every Critical or Important finding, rerun the affected focused tests, then repeat Tasks 9.4-9.7 before declaring completion.
