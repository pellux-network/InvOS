# Inventory-Authoritative Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace slot-based transfer verification with one-call aggregate storage reconciliation that survives Colossal Chest compaction, incorrect peripheral return counts, and controller restarts.

**Architecture:** A pure reconciler captures and compares exact-identity totals across a recorded storage-node scope. Transfer schema 2 journals persist that baseline around exactly one `pushItems` call; request/import services credit the measured aggregate delta, while a small startup recovery worker reconciles or retires unfinished journals without globally freezing the UI.

**Tech Stack:** Lua compatible with CC:Tweaked, wired generic-inventory peripherals, cooperative bounded scans, repository Lua test harness.

## Global Constraints

- Live container contents are authoritative; indexes and journals are derived coordination state.
- Never repeat a transfer call before its saved baseline has been reconciled.
- Reconciliation uses exact name-and-NBT identity totals across the recorded storage-node scope.
- Pickup and Drop-off contents are not post-transfer evidence.
- Keep terminal input, monitor rendering, search, and status responsive during scans.
- Do not run `controller/startup.lua` or `controller/colossal/main.lua` on the host.
- Do not write to live computer #4 until it is reconfirmed shut down and labeled `StorageController`.
- Deploy only allow-listed Lua runtime files and preserve live configuration/aliases; legacy journal retirement must be an explicit tested migration.

---

### Task 1: Pure aggregate reconciliation

**Files:**
- Create: `controller/colossal/core/reconciliation.lua`
- Create: `controller/colossal/tests/test_reconciliation.lua`
- Modify: `controller/colossal/tests/run.lua`

**Interfaces:**
- Consumes: exact identity keys and scanner snapshots `{node_id, health, slots}`.
- Produces: `Reconciliation.capture(identityKey, snapshots) -> baseline|nil, reason`; `baseline={identity_key,total,node_ids}`. Produces `Reconciliation.measure(kind, baseline, snapshots) -> result`, where result is `{state="READY",before_total,after_total,moved}` or `{state="WAITING",reason,rescan}`.

- [ ] **Step 1: Write failing aggregate tests**

Add literal fixtures proving pooled totals, exact NBT separation, and required scope health:

```lua
local baseline=assert(Reconciliation.capture(echo,{
    snapshot("a",{[7]={identity_key=echo,count=3}}),
    snapshot("b",{[2]={identity_key=echo,count=4},[3]={identity_key=wutodie,count=29}}),
}))
T.equal(baseline.total,7)
T.arrayEqual(baseline.node_ids,{"a","b"})

local result=Reconciliation.measure("request",baseline,{
    snapshot("a",{[7]={identity_key=wutodie,count=29}}),
    snapshot("b",{[2]={identity_key=echo,count=4}}),
})
T.equal(result.state,"READY")
T.equal(result.moved,3)
```

Add a missing-node test expecting `WAITING` with `rescan={"a","b"}`, and an import test where total 4 becomes 9 and `moved==5`.

- [ ] **Step 2: Run the new test and verify RED**

Run from `controller/`:

```text
lua colossal/tests/run.lua tests.test_reconciliation
```

Expected: module load fails because `core.reconciliation` does not exist.

- [ ] **Step 3: Implement the pure reconciler**

Implement deterministic sorted scope capture and measurement:

```lua
function M.capture(identityKey,snapshots)
    local total,nodeIds=0,{}
    for _,snapshot in ipairs(snapshots or {}) do
        if snapshot.health=="READY" and type(snapshot.node_id)=="string" then
            nodeIds[#nodeIds+1]=snapshot.node_id
            total=total+identityTotal(identityKey,snapshot.slots)
        end
    end
    table.sort(nodeIds)
    if #nodeIds==0 then return nil,reason("NO_STORAGE_SCOPE","No healthy storage scope",true) end
    return {identity_key=identityKey,total=total,node_ids=nodeIds}
end

function M.measure(kind,baseline,snapshots)
    local byId=indexSnapshots(snapshots)
    local after=0
    for _,nodeId in ipairs(baseline.node_ids) do
        local snapshot=byId[nodeId]
        if not snapshot or snapshot.health~="READY" then
            return {state="WAITING",reason=reason("STORAGE_SCOPE_INCOMPLETE",
                "Waiting for every baseline storage node",true),rescan=copy(baseline.node_ids)}
        end
        after=after+identityTotal(baseline.identity_key,snapshot.slots)
    end
    local moved=kind=="request" and baseline.total-after or after-baseline.total
    return {state="READY",before_total=baseline.total,after_total=after,moved=moved}
end
```

Reject malformed identities, counts, node IDs, duplicate scope IDs, and unknown operation kinds with structured non-retryable reasons.

- [ ] **Step 4: Run the reconciliation tests and verify GREEN**

Run: `lua colossal/tests/run.lua tests.test_reconciliation`

Expected: all aggregate tests pass.

- [ ] **Step 5: Commit the reconciler**

```text
git add controller/colossal/core/reconciliation.lua controller/colossal/tests/test_reconciliation.lua controller/colossal/tests/run.lua
git commit -m "feat: reconcile transfers from pooled storage totals"
```

---

### Task 2: Schema-2 transfer journal and retirement

**Files:**
- Modify: `controller/colossal/shared/store.lua`
- Modify: `controller/colossal/core/transfer.lua`
- Modify: `controller/colossal/tests/test_store.lua`
- Modify: `controller/colossal/tests/test_transfer.lua`
- Modify: `controller/colossal/tests/test_recovery.lua`
- Modify: `controller/colossal/tests/test_pickup_recovery.lua`

**Interfaces:**
- Consumes: `Reconciliation.capture/measure` from Task 1, operation/step data, and current storage snapshots.
- Produces: `Store:delete(name) -> true|nil,reason`; `Transfer:execute(operation,step,storageSnapshots)` writes schema 2 and calls the adapter once; `Transfer:verify(journal,storageSnapshots)` measures aggregate movement; `Transfer:recover(journal,storageSnapshots)` never invokes the adapter; `Transfer:retire() -> true|nil,reason` removes journal variants.

- [ ] **Step 1: Write failing Store retirement tests**

Write active, previous, and staged journal files in `T.memoryFs()`, call `store:delete("journal")`, and assert all three paths are absent while unrelated `config.lua` remains.

- [ ] **Step 2: Write failing schema-2 transfer tests**

Use three Echo Gems in the baseline and a fake adapter that reports one. Assert one adapter call, journal phase `CALLED`, `reported_moved==1`, baseline total 3, and reconciliation against a compacted Wutodie slot returns measured movement 3:

```lua
local result=transfer:execute(operation("request"),requestStep(2),beforeSnapshots)
T.equal(result.state,"VERIFYING")
T.equal(inventory.calls.push,1)
T.equal(result.journal.schema,2)
T.equal(result.journal.step.storage_pre_count,3)

local verified=transfer:verify(result.journal,afterCompactionSnapshots)
T.equal(verified.state,"COMPLETE")
T.equal(verified.moved,3)
T.equal(verified.reported_moved,1)
```

Add tests that partial and zero deltas ignore the reported count, a missing baseline node returns `WAITING` without another push, imports use aggregate increases, and `retire` removes journal variants.

- [ ] **Step 3: Run focused persistence/transfer tests and verify RED**

Run:

```text
lua colossal/tests/run.lua tests.test_store tests.test_transfer tests.test_recovery tests.test_pickup_recovery
```

Expected: missing `Store:delete`, schema remains 1, or slot-based verification fails the assertions.

- [ ] **Step 4: Implement exact journal deletion**

In `Store:delete`, derive only `<name>.lua`, `<name>.staged.lua`, and `<name>.previous.lua` through the existing scoped `combine` helper. Delete each existing path inside `pcall`; return a stable error without touching other names.

- [ ] **Step 5: Upgrade Transfer to schema 2**

Inject `deps.reconciliation`, capture the baseline before writing `INTENT`, then preserve the call boundary:

```lua
local baseline,baselineReason=self.reconciliation.capture(step.identity_key,storageSnapshots)
if not baseline then return failed(baselineReason.code,baselineReason.message,false,operation,step) end
local journal=makeJournalV2(operation,step,baseline,self.clock())
writePhase("INTENT")
writePhase("CALLING")
local ok,moved=self.adapter:push(...)
journal.step.reported_moved=moved
writePhase("CALLED")
return {state="VERIFYING",journal=copy(journal),rescan=copy(baseline.node_ids)}
```

For imports append the Drop-off peripheral to `rescan` for fresh source planning, but never use it in `verify`.

`Transfer:verify` calls `Reconciliation.measure`. `WAITING` is returned without changing the journal; `READY` writes phase `RECONCILED`, stores `actual_moved=result.moved`, and returns `COMPLETE`. A negative measured delta returns `RECONCILE_DIRECTION` and does not replay.

Keep `Transfer.validateJournal` capable of reading schema 1 legacy journals. Schema 2 requires `storage_pre_count`, sorted unique `storage_node_ids`, `reported_moved`, and `actual_moved` only when reconciled.

- [ ] **Step 6: Implement recovery without replay**

`Transfer:recover` behavior:

```lua
schema 1              -> {state="LEGACY",reason=...}
schema 2 INTENT       -> {state="DISCARD_SAFE",moved=0}
schema 2 CALLING      -> verify from aggregate snapshots
schema 2 CALLED       -> verify from aggregate snapshots
schema 2 RECONCILED   -> {state="COMPLETE",moved=actual_moved,...}
```

No recovery branch calls `adapter.push`.

- [ ] **Step 7: Run focused persistence/transfer tests and verify GREEN**

Run the command from Step 3.

Expected: all focused tests pass.

- [ ] **Step 8: Commit the transfer boundary**

```text
git add controller/colossal/shared/store.lua controller/colossal/core/transfer.lua controller/colossal/tests/test_store.lua controller/colossal/tests/test_transfer.lua controller/colossal/tests/test_recovery.lua controller/colossal/tests/test_pickup_recovery.lua
git commit -m "fix: journal aggregate transfer reconciliation"
```

---

### Task 3: Request and import measured-result integration

**Files:**
- Modify: `controller/colossal/app/requests.lua`
- Modify: `controller/colossal/app/import_service.lua`
- Modify: `controller/colossal/app/coordinator.lua`
- Modify: `controller/colossal/tests/test_requests.lua`
- Modify: `controller/colossal/tests/test_import_service.lua`
- Modify: `controller/colossal/tests/test_coordinator_transfers.lua`
- Modify: `controller/colossal/tests/test_transfer_rescan_race.lua`

**Interfaces:**
- Consumes: Task 2 `execute(operation,step,storage)` and `verify(journal,storage)` results.
- Produces: request/import progress based only on measured `result.moved`; critical over-delivery alerts; journal retirement after applying a reconciled result; coordinator verification gates over the recorded storage scope.

- [ ] **Step 1: Write failing Echo over-delivery service test**

Build a request for 2 whose transfer result is `{moved=3,reported_moved=1}`. Assert request state `COMPLETE`, delivered 3, one critical alert with code `OVER_DELIVERY`, and no second execute call.

- [ ] **Step 2: Write failing partial/zero/import tests**

Assert retrieval measured 1 credits one and replans one only after reconciliation; measured zero becomes `PICKUP_FULL`. For imports, measured storage increase credits the import even when the adapter reported a different number. Assert `transfer:retire()` occurs once after each applied completion.

- [ ] **Step 3: Run focused service tests and verify RED**

Run:

```text
lua colossal/tests/run.lua tests.test_requests tests.test_import_service tests.test_coordinator_transfers tests.test_transfer_rescan_race
```

Expected: old services pass observations instead of storage snapshots, do not retire journals, or fail over-delivery assertions.

- [ ] **Step 4: Pass storage snapshots through services**

Change both services to call:

```lua
self.transfer:execute(active,active.step,context.storage or {})
self.transfer:verify(active.journal,context.storage or {})
```

Handle `WAITING` by retaining `VERIFYING`, returning its `rescan`, and leaving the journal untouched. Remove `context.observed` and `Coordinator:_observed` because slot observations no longer participate.

- [ ] **Step 5: Apply measured progress and retire journals**

After `COMPLETE`, credit `result.moved`, then call `transfer:retire()`. A retirement failure creates a warning but does not undo measured inventory truth. For `result.moved > step.limit`, emit:

```lua
self.alerts:set("request_overdelivery:"..request.id,"critical",
    "Storage moved "..result.moved.." items for a "..request.step.limit.." item step",
    {code="OVER_DELIVERY",requested=request.step.limit,
     measured=result.moved,reported=result.reported_moved})
```

Complete rather than retry when delivered meets or exceeds the request.

- [ ] **Step 6: Run focused service tests and verify GREEN**

Run the command from Step 3.

Expected: all service and scan-gate tests pass with one transfer call per reconciled step.

- [ ] **Step 7: Commit service integration**

```text
git add controller/colossal/app/requests.lua controller/colossal/app/import_service.lua controller/colossal/app/coordinator.lua controller/colossal/tests/test_requests.lua controller/colossal/tests/test_import_service.lua controller/colossal/tests/test_coordinator_transfers.lua controller/colossal/tests/test_transfer_rescan_race.lua
git commit -m "fix: apply measured inventory transfer results"
```

---

### Task 4: Non-blocking startup reconciliation and legacy retirement

**Files:**
- Create: `controller/colossal/app/recovery.lua`
- Create: `controller/colossal/tests/test_recovery_service.lua`
- Modify: `controller/colossal/main.lua`
- Modify: `controller/colossal/app/coordinator.lua`
- Modify: `controller/colossal/deployment_manifest.lua`
- Modify: `controller/colossal/tests/run.lua`
- Modify: `controller/colossal/tests/test_main.lua`
- Modify: `controller/colossal/tests/test_error_recovery.lua`
- Modify: `controller/colossal/tests/test_deployment.lua`

**Interfaces:**
- Consumes: recovered schema-1/schema-2 journal, Task 2 Transfer recovery/retirement, current `context.storage`, Store, and Alerts.
- Produces: `Recovery.new(deps)` with `status()` and `tick(context)`; terminal input/UI remain active; legacy/invalid journals warn and retire without setting global `recovering`.

- [ ] **Step 1: Write failing recovery-worker tests**

Cover these literal behaviors:

```lua
legacy schema 1  -> warning + retire + COMPLETE, push calls 0
schema 2 INTENT  -> retire + COMPLETE, push calls 0
CALLING/CALLED   -> WAITING until complete baseline scope scan
RECONCILED       -> result summary warning/info + retire + COMPLETE
```

For a temporarily missing node, assert UI coordinator ticks and redraws continue while recovery returns `VERIFYING`; when the node snapshot returns, recovery completes without replay.

- [ ] **Step 2: Run recovery/main tests and verify RED**

Run:

```text
lua colossal/tests/run.lua tests.test_recovery_service tests.test_main tests.test_error_recovery tests.test_deployment
```

Expected: missing recovery module or existing global `RECOVERING` behavior fails.

- [ ] **Step 3: Implement the recovery worker**

`Recovery:tick(context)` calls `transfer:recover(journal,context.storage or {})`. It returns scan requests for `WAITING`; otherwise it emits a one-time alert/result summary, calls `transfer:retire()`, and becomes `COMPLETE`. It never exposes a method that can invoke `pushItems`.

- [ ] **Step 4: Assemble recovery without global freeze**

In `Main.build`, recover the journal as data and construct `Recovery` when one exists. If active/previous decoding fails, create a warning and delete the unusable journal variants; do not call `coordinator:setRecovering(true)`.

Add recovery as the first automation service in Coordinator so it receives completed storage scans before new mutations. Keep `paused`, setup, search, rendering, and input behavior unchanged. Remove `observedFor`.

- [ ] **Step 5: Add runtime files to the manifest**

Add exactly:

```lua
"colossal/app/recovery.lua",
"colossal/core/reconciliation.lua",
```

Keep tests, docs, and data excluded.

- [ ] **Step 6: Run recovery/main tests and verify GREEN**

Run the command from Step 2.

Expected: legacy live-style failed journal no longer produces lifecycle `RECOVERING`; no recovery path calls the adapter; deployment policy passes.

- [ ] **Step 7: Commit startup recovery**

```text
git add controller/colossal/app/recovery.lua controller/colossal/core/reconciliation.lua controller/colossal/main.lua controller/colossal/app/coordinator.lua controller/colossal/deployment_manifest.lua controller/colossal/tests/test_recovery_service.lua controller/colossal/tests/run.lua controller/colossal/tests/test_main.lua controller/colossal/tests/test_error_recovery.lua controller/colossal/tests/test_deployment.lua
git commit -m "fix: recover transfers without freezing startup"
```

---

### Task 5: Exact live-failure acceptance and full verification

**Files:**
- Modify: `controller/colossal/tests/test_acceptance.lua`
- Modify if required by obsolete fixtures: `controller/colossal/tests/test_*.lua`

**Interfaces:**
- Consumes: Tasks 1-4.
- Produces: end-to-end proof of one-call compaction-safe reconciliation and a clean deployable branch.

- [ ] **Step 1: Add the exact Echo/Wutodie acceptance test**

Extend the fake inventory so one configured call can remove all 3 Echo Gems, return 1, and compact Wutodie into slot 7. Request 2 and assert:

```lua
T.equal(pushCalls,1)
T.equal(app:count("pickup",echo),3)
T.equal(app:storageCount(echo),0)
T.equal(model.requests[1].state,"COMPLETE")
T.equal(model.requests[1].delivered,3)
T.equal(activeAlert.code,"OVER_DELIVERY")
```

- [ ] **Step 2: Run the acceptance test and verify it passes only with aggregate reconciliation**

Run: `lua colossal/tests/run.lua tests.test_acceptance`

Expected: all acceptance tests pass, including the one-call over-delivery reproduction.

- [ ] **Step 3: Run the complete Lua suite**

Run: `lua colossal/tests/run.lua`

Expected: every test passes. Update only obsolete schema-1/slot-observation fixtures; do not weaken import, NBT, responsiveness, or deployment assertions.

- [ ] **Step 4: Run repository and manifest checks**

Run:

```text
git diff --check
git status --short
```

Confirm every changed runtime file appears in `controller/colossal/deployment_manifest.lua`, and the manifest contains no tests, docs, helpers, or `colossal/data` paths.

- [ ] **Step 5: Commit acceptance/regression adjustments**

```text
git add controller/colossal/tests
git commit -m "test: reproduce colossal slot compaction transfer"
```

Skip this commit if Task 5 creates no uncommitted changes.

- [ ] **Step 6: Stop before live deployment**

Report the verified branch result. Reconfirm computer #4 is shut down and labeled `StorageController` before copying manifest files. Hash-check all runtime destinations. Preserve config and aliases; record and explicitly report the tested retirement of the legacy journal files.