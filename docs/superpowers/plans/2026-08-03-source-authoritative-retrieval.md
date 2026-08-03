# Source-Authoritative Retrieval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make retrieval depend only on controlled storage state and the exact `pushItems` moved count, never on mutable Pickup contents.

**Architecture:** Retrieval plans identify source slots and a Pickup peripheral but omit destination-slot snapshot fields. The transfer layer branches by operation kind: requests inspect and verify only the source and push without `toSlot`, while imports retain strict source/destination slot validation. Coordinator recovery and request errors follow the same operation-specific boundary.

**Tech Stack:** Lua 5.2-compatible CC:Tweaked modules, wired inventory `pushItems`, repository Lua test harness.

## Global Constraints

- Runtime code must remain compatible with the target CC:Tweaked Lua environment.
- Never run `controller/startup.lua` or `controller/colossal/main.lua` from the host.
- Treat returned transfer quantities as authoritative.
- Preserve strict destination validation for imports.
- Do not write to live computer #4 until the user confirms it is shut down and labeled `StorageController`.
- Deploy only paths in `controller/colossal/deployment_manifest.lua` and preserve `colossal/data`.

---

### Task 1: Source-only retrieval planning

**Files:**
- Modify: `controller/colossal/core/planner.lua`
- Modify: `controller/colossal/tests/test_planner.lua`

**Interfaces:**
- Consumes: `index:sources(identityKey) -> source[]` and Pickup `{ peripheral_name: string, health: "READY" }`.
- Produces: `Planner.planRetrieval(identityKey, requested, index, pickup) -> plan, remainder, reason`; each retrieval step has `source_name`, `source_slot`, `source_epoch`, `source_pre_count`, `destination_name`, `identity_key`, and `limit`, with no destination snapshot fields.

- [ ] **Step 1: Replace Pickup-capacity assertions with source-authoritative planner tests**

Add tests that assert full Pickup slot data is ignored, sources are split only at source boundaries, and destination snapshot keys are absent:

```lua
local plan,remainder=Planner.planRetrieval(key,90,index,pickup(1,{
    [1]=item("minecraft:dirt",nil,64),
}))
T.equal(remainder,0)
T.equal(plan[1].destination_name,"pickup")
T.equal(plan[1].destination_slot,nil)
T.equal(plan[1].destination_epoch,nil)
T.equal(plan[1].destination_pre_count,nil)
T.equal(plan[1].limit,64)
T.equal(plan[2].limit,26)
```

Retain tests for invalid requests, unavailable Pickup binding, insufficient stock, priority ordering, and exact NBT variants. Remove expectations that planning predicts `PICKUP_FULL`.

- [ ] **Step 2: Run the planner tests and verify the old planner fails**

Run from `controller/`:

```text
lua colossal/tests/run.lua tests.test_planner
```

Expected: failures show destination slots are still allocated or full Pickup content prevents planning.

- [ ] **Step 3: Simplify `Planner.planRetrieval`**

Delete `pickupCapacities`. Keep Pickup availability validation, then allocate directly across unowned indexed sources:

```lua
local remaining,plan=requested,{}
for _,source in ipairs(index:sources(identityKey)) do
    if not source.owned and remaining>0 then
        local amount=math.min(remaining,source.count)
        plan[#plan+1]={
            source_name=source.peripheral_name,
            source_slot=source.slot,
            source_epoch=source.epoch,
            source_pre_count=source.count,
            destination_name=pickup.peripheral_name,
            identity_key=identityKey,
            limit=amount,
        }
        remaining=remaining-amount
    end
end
```

Return `INSUFFICIENT_STOCK` only when `remaining > 0`; never infer Pickup capacity from a snapshot.

- [ ] **Step 4: Run the planner tests and verify they pass**

Run: `lua colossal/tests/run.lua tests.test_planner`

Expected: all planner tests pass.

- [ ] **Step 5: Commit the planner change**

```text
git add controller/colossal/core/planner.lua controller/colossal/tests/test_planner.lua
git commit -m "fix: plan retrieval from storage sources only"
```

---

### Task 2: Operation-specific transfer contract

**Files:**
- Modify: `controller/colossal/core/inventory_adapter.lua`
- Modify: `controller/colossal/core/transfer.lua`
- Modify: `controller/colossal/tests/test_inventory_adapter.lua`
- Modify: `controller/colossal/tests/test_transfer.lua`
- Modify: `controller/colossal/tests/test_pickup_preflight.lua`
- Modify: `controller/colossal/tests/test_pickup_recovery.lua`
- Modify: `controller/colossal/tests/test_recovery.lua`

**Interfaces:**
- Consumes: retrieval steps from Task 1 and unchanged import steps from `Planner.planImport`.
- Produces: `Adapter:push(sourceName,destinationName,fromSlot,limit,toSlot?)`; `Transfer:execute(operation,step)` requests rescan only the source for requests and both endpoints for imports; request journals validate without destination slot snapshot fields.

- [ ] **Step 1: Add failing adapter tests for omitted `toSlot`**

Keep the existing five-argument import assertion and add:

```lua
local ok,moved=adapter:push("source","pickup",3,7,nil)
T.equal(ok,true)
T.equal(moved,7)
T.arrayEqual(called,{"pickup",3,7})
```

- [ ] **Step 2: Add failing transfer contract tests**

For a `kind="request"` step without `destination_slot`, `destination_epoch`, or `destination_pre_count`, assert:

```lua
T.equal(inventory.calls.inspect,1)
T.arrayEqual(inventory.pushed,{"store_a","pickup",4,64,nil})
T.arrayEqual(result.rescan,{"store_a"})
T.equal(Transfer.validateJournal(result.journal),true)
```

Verify request completion with only:

```lua
local verified=transfer:verify(result.journal,{
    source={identity_key=stone,count=47},
})
T.equal(verified.state,"COMPLETE")
```

Add or retain import tests proving destination inspection, explicit `toSlot`, two-endpoint rescans, and source-plus-destination conservation remain mandatory.

- [ ] **Step 3: Run focused adapter and transfer tests and verify failure**

Run:

```text
lua colossal/tests/run.lua tests.test_inventory_adapter tests.test_transfer tests.test_pickup_preflight tests.test_pickup_recovery tests.test_recovery
```

Expected: request journal validation, inspection count, unslotted push, or source-only observation assertions fail.

- [ ] **Step 4: Make adapter calls truly unslotted**

In `Adapter:push`, branch on `toSlot` so the CC method receives exactly three arguments for requests:

```lua
local ok,moved
if toSlot==nil then
    ok,moved=pcall(source.pushItems,destinationName,fromSlot,limit)
else
    ok,moved=pcall(source.pushItems,destinationName,fromSlot,limit,toSlot)
end
```

- [ ] **Step 5: Make journal validation operation-specific**

Keep common required fields numeric (`source_slot`, `source_epoch`, `source_pre_count`, `limit`, `actual_moved`). Require `destination_slot`, `destination_epoch`, and `destination_pre_count` only when `value.operation.kind ~= "request"`. Always require `destination_name` because requests still need the Pickup peripheral.

- [ ] **Step 6: Make preflight, transfer, rescans, and verification operation-specific**

Add one helper and use it in every failure/success result:

```lua
local function rescanFor(operation,step)
    if operation.kind=="request" then return {step.source_name} end
    return {step.source_name,step.destination_name}
end
```

After source validation, return immediately from `_preflight` for requests. In `execute`, pass `nil` as `toSlot` for requests. In `observedMatches`, require only `observed.source` for requests; require both observations for imports. Use a request-specific mismatch message such as `observed source count does not match the recorded move`.

- [ ] **Step 7: Run the focused transfer tests and verify they pass**

Run the command from Step 3.

Expected: all focused tests pass, including unchanged import strictness.

- [ ] **Step 8: Commit the transfer contract**

```text
git add controller/colossal/core/inventory_adapter.lua controller/colossal/core/transfer.lua controller/colossal/tests/test_inventory_adapter.lua controller/colossal/tests/test_transfer.lua controller/colossal/tests/test_pickup_preflight.lua controller/colossal/tests/test_pickup_recovery.lua controller/colossal/tests/test_recovery.lua
git commit -m "fix: verify retrieval from storage source"
```

---

### Task 3: Source-only scheduling, recovery, and Pickup-full state

**Files:**
- Modify: `controller/colossal/app/coordinator.lua`
- Modify: `controller/colossal/app/requests.lua`
- Modify: `controller/colossal/main.lua`
- Modify: `controller/colossal/tests/test_coordinator_transfers.lua`
- Modify: `controller/colossal/tests/test_requests.lua`
- Modify: `controller/colossal/tests/test_request_replan.lua`
- Modify: `controller/colossal/tests/test_main.lua`

**Interfaces:**
- Consumes: request `result.rescan={source_name}` and operation-specific journals from Task 2.
- Produces: request verification contexts containing only `observed.source`; `PICKUP_FULL` retryable block after an authoritative zero move; import scheduling remains two-endpoint.

- [ ] **Step 1: Add failing coordinator tests for a one-node request gate**

Build a request service that first returns `VERIFYING` with `rescan={"source"}`. Assert the coordinator scans `source`, resumes that request after the source revision advances, and does not wait for or promote Pickup. Keep the existing import test that waits for both endpoints.

- [ ] **Step 2: Add failing request tests for zero and partial results**

Drive a request through verification with a moved count of zero and assert:

```lua
T.equal(result.state,"BLOCKED")
T.equal(result.reason.code,"PICKUP_FULL")
T.equal(result.reason.retryable,true)
T.contains(result.reason.message,"Pickup")
```

Drive a partial move and assert only that moved quantity is credited before the remainder is replanned. Update request fixtures so retrieval steps and observations have no destination snapshot.

- [ ] **Step 3: Add failing startup recovery tests**

For a request `CALLED` journal without destination snapshot fields, provide an adapter whose Pickup inspection would error. Assert `Main.build` inspects only the source and does not enter recovery. Retain an import recovery case that inspects both endpoints.

- [ ] **Step 4: Run focused application tests and verify failure**

Run:

```text
lua colossal/tests/run.lua tests.test_coordinator_transfers tests.test_requests tests.test_request_replan tests.test_main
```

Expected: old observation or short-transfer behavior fails the new assertions.

- [ ] **Step 5: Remove Pickup from request observations**

In `Coordinator:_observed()` and `main.lua` `observedFor`, return early for request journals:

```lua
local observed={source=slot(step.source_name,step.source_slot)}
if journal.operation.kind~="request" then
    observed.destination=slot(step.destination_name,step.destination_slot)
end
return observed
```

Use the equivalent `inspect` implementation in `main.lua`.

- [ ] **Step 6: Replace the zero-move request error**

In `Requests:tick`, after successful source verification with `result.moved <= 0`, block with:

```lua
{code="PICKUP_FULL",message="Pickup accepted no items; make space and retry",retryable=true}
```

Remove `DESTINATION_CHANGED` from the request-specific replanning branch because retrieval no longer produces it. Preserve `SOURCE_CHANGED` rescan/replan behavior.

- [ ] **Step 7: Run the focused application tests and verify they pass**

Run the command from Step 4.

Expected: all focused tests pass; request gates and recovery use source only, while import tests remain strict.

- [ ] **Step 8: Commit application integration**

```text
git add controller/colossal/app/coordinator.lua controller/colossal/app/requests.lua controller/colossal/main.lua controller/colossal/tests/test_coordinator_transfers.lua controller/colossal/tests/test_requests.lua controller/colossal/tests/test_request_replan.lua controller/colossal/tests/test_main.lua
git commit -m "fix: isolate pickup from retrieval verification"
```

---

### Task 4: Regression and deployment readiness

**Files:**
- Modify if required by failures: affected `controller/colossal/tests/test_*.lua` fixtures only when they encode the obsolete request destination snapshot contract.
- Verify: `controller/colossal/deployment_manifest.lua`

**Interfaces:**
- Consumes: all implementation from Tasks 1-3.
- Produces: a clean branch whose complete Lua suite passes and whose live deployment remains manifest-scoped.

- [ ] **Step 1: Run the complete Lua suite**

Run from `controller/`:

```text
lua colossal/tests/run.lua
```

Expected: every test passes. If an old request fixture still requires Pickup destination fields, update it to the source-only contract; do not relax import assertions.

- [ ] **Step 2: Check repository integrity and deployment allow-list**

Run:

```text
git diff --check
git status --short
```

Confirm every modified runtime file is already named by `controller/colossal/deployment_manifest.lua`, and no tests, docs, data, or helper scripts appear in that manifest.

- [ ] **Step 3: Review behavior against the approved design**

Confirm all of these directly in code and tests:

```text
request planner ignores Pickup contents
request push omits toSlot
request preflight/verification/recovery observe source only
zero move becomes retryable PICKUP_FULL
partial move credits exact returned count
imports retain destination slot validation and conservation
```

- [ ] **Step 4: Commit any regression-fixture adjustments**

```text
git add controller/colossal/tests
git commit -m "test: cover source-authoritative retrieval"
```

Skip this commit when no additional files changed.

- [ ] **Step 5: Stop before live deployment**

Report the verified branch result and ask the user to shut down computer #4. Before any later copy, re-confirm label `StorageController`, exact target `C:\Servers\Wold's Vaults\world\computercraft\computer\4`, and shutdown state. Preserve all files under `colossal/data`.