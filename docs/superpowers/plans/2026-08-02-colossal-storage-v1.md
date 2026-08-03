# Colossal Storage v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a polished CC:Tweaked controller that pools any number of wired Colossal Chests, imports a dedicated Drop-off inventory, and fulfills exact searchable requests into a dedicated Pickup inventory without item loss or UI blocking.

**Architecture:** A single advanced computer runs cooperative controller loops over dependency-injected inventory, persistence, terminal, and monitor adapters. Immutable validated snapshots feed a derived pooled index; explicit state machines and a durable step journal govern all item movement. Search, setup, alerts, and monitor views consume coordinator snapshots and never call peripherals synchronously.

**Tech Stack:** CC:Tweaked CraftOS Lua, wired inventory peripherals (`size`, `list`, `getItemDetail`, `getItemLimit`, `pushItems`, `pullItems`), `parallel.waitForAny`, table-driven Lua tests, and Git.

## Global Constraints

- Runtime files must be Lua compatible with the target CC:Tweaked version and must not require desktop Lua libraries.
- Root `controller/startup.lua` is the automatic CraftOS entry point.
- One dedicated Drop-off inventory and one dedicated Pickup inventory are required and must be different peripherals.
- Any number of configured storage nodes are supported; exactly one interface per physical Colossal Chest may be configured.
- NBT fingerprints are part of exact item identity; incompatible variants are never merged.
- Inventory snapshots and counts are derived state and are never persisted as authoritative stock truth.
- The integer returned by `pushItems` or `pullItems` is the only authoritative moved quantity.
- Stale, offline, errored, disabled, or suspicious duplicate nodes are excluded from allocation.
- No peripheral call, scan, metadata lookup, transfer sequence, or monitor render may block terminal input indefinitely.
- An ambiguous in-flight transfer after reboot is never replayed automatically.
- The floppy contains configuration and aliases only; source, snapshots, counts, metadata cache, history, and journals are excluded.
- Crafting, recipe storage, turtles, GPS, routes, and fuel management are excluded from v1.
- Never run `controller/startup.lua` or `controller/colossal/main.lua` from the host shell.
- Never deploy tests, docs, Git data, host helpers, or local runtime data to a live ComputerCraft directory.
- Before a live deployment, verify the numeric computer ID, label, role, exact target directory, and shutdown state.

## File Map

```text
controller/
  startup.lua                         CraftOS entry point only
  colossal/
    main.lua                          dependency assembly and process loops
    app/
      alerts.lua                      condition-based deduplicated alerts
      backup.lua                      configuration-and-alias floppy backup
      coordinator.lua                 lifecycle, scheduling, snapshots, commands
      import_service.lua              Drop-off discovery and import operations
      keymap.lua                      keyboard and mouse command translation
      lifecycle.lua                   controller and operation transition tables
      monitor.lua                     responsive status-only renderer
      requests.lua                    request queue and retrieval execution
      search.lua                      ranked query and variant selection
      setup.lua                       setup model, discovery, validation, commit
      ui.lua                          terminal view model and renderer
    core/
      identity.lua                    exact name/NBT identity keys
      index.lua                       immutable pooled inventory index
      planner.lua                     import/retrieval slot allocation
      registry.lua                    role bindings and node health
      scanner.lua                     validated bounded inventory snapshots
      transfer.lua                    journaled transfer-step executor/recovery
    shared/
      codec.lua                       textutils serialization boundary
      store.lua                       schema-validated staged persistence
      runtime.lua                     installation identity and safe-call helpers
    tests/
      mock_cc.lua                     assertions, memory FS, inventories, surfaces
      run.lua                         deterministic suite runner
      test_*.lua                      focused unit/integration tests
docs/
  operations.md                       install, setup, recovery, and diagnostics
```

---

### Task 1: CraftOS-safe foundation and deterministic test harness

**Files:**
- Create: `controller/startup.lua`
- Create: `controller/colossal/main.lua`
- Create: `controller/colossal/shared/runtime.lua`
- Create: `controller/colossal/tests/mock_cc.lua`
- Create: `controller/colossal/tests/run.lua`
- Create: `controller/colossal/tests/test_startup.lua`
- Create: `controller/colossal/tests/test_runtime.lua`
- Modify: `README.md`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: CraftOS globals `shell`, `os`, `term`, and `printError`.
- Produces: `Runtime.safeCall(label, fn, ...) -> ok, value_or_reason`; `Runtime.verifyInstallation(osApi, installation) -> ok, reason`; table-driven test runner conventions used by every later task.

- [ ] **Step 1: Write failing startup and runtime tests**

```lua
-- controller/colossal/tests/test_runtime.lua
local Runtime = require("shared.runtime")
local T = require("tests.mock_cc")

return {
  { name = "safeCall converts exceptions to stable reasons", run = function()
      local ok, reason = Runtime.safeCall("scan main", function() error("cable gone") end)
      T.equal(ok, nil)
      T.contains(reason, "scan main")
      T.contains(reason, "cable gone")
    end },
  { name = "installation rejects a moved computer", run = function()
      local fake = { getComputerID = function() return 9 end,
        getComputerLabel = function() return "Other" end }
      local ok, reason = Runtime.verifyInstallation(fake,
        { computer_id = 4, computer_label = "ColossalStorage" })
      T.equal(ok, nil)
      T.contains(reason, "expected #4 ColossalStorage")
    end },
}
```

`test_startup.lua` must replace `shell.run` with a recorder, load `startup.lua`, and assert the sole target is `/colossal/main.lua`; it must also assert a false result prints `Colossal Storage stopped with an error`.

- [ ] **Step 2: Run the focused tests and verify red**

Run from `controller/`:

```powershell
lua colossal/tests/run.lua tests.test_startup tests.test_runtime
```

Expected: failure because `shared.runtime` and the startup entry point do not exist.

- [ ] **Step 3: Implement the minimal runtime and entry points**

```lua
-- controller/startup.lua
local ok = shell.run("/colossal/main.lua")
if not ok then printError("Colossal Storage stopped with an error") end
```

```lua
-- controller/colossal/shared/runtime.lua
local M = {}
function M.safeCall(label, fn, ...)
  local result = { pcall(fn, ...) }
  if not table.remove(result, 1) then
    return nil, label .. ": " .. tostring(result[1])
  end
  return true, table.unpack(result)
end
function M.verifyInstallation(osApi, installation)
  local id, label = osApi.getComputerID(), osApi.getComputerLabel()
  if installation and (id ~= installation.computer_id or label ~= installation.computer_label) then
    return nil, ("identity mismatch: expected #%s %s, got #%s %s"):format(
      tostring(installation.computer_id), tostring(installation.computer_label),
      tostring(id), tostring(label))
  end
  return true
end
return M
```

`main.lua` sets `package.path` to `/colossal/?.lua;/colossal/?/init.lua` before requiring application modules. `run.lua` accepts optional module names, executes each `{name, run}` test with `pcall`, prints `RESULT N passed, M failed`, and raises when `M > 0`. `mock_cc.lua` provides `equal`, `notEqual`, `truthy`, `contains`, `arrayEqual`, `fails`, `memoryFs`, deterministic clocks and inventories, and `recordingSurface`; the surface exposes `allText()` and `writesOutsideBounds()` so every later renderer test uses the same bounds checks. Replace `.gitignore` with exactly `.worktrees/`, `controller/colossal/data/`, and `*.tmp` entries.

- [ ] **Step 4: Run focused and complete foundation tests**

```powershell
lua colossal/tests/run.lua tests.test_startup tests.test_runtime
lua colossal/tests/run.lua
git diff --check
```

Expected: all tests pass, no file attempts to execute the application during host tests, and the diff check is clean.

- [ ] **Step 5: Commit the foundation**

```powershell
git add .gitignore controller README.md
git commit -m "feat: add colossal storage runtime foundation"
```

---

### Task 2: Versioned persistence, journal safety, and bounded backup

**Files:**
- Create: `controller/colossal/shared/codec.lua`
- Create: `controller/colossal/shared/store.lua`
- Create: `controller/colossal/app/backup.lua`
- Create: `controller/colossal/tests/test_store.lua`
- Create: `controller/colossal/tests/test_backup.lua`
- Modify: `controller/colossal/tests/run.lua`

**Interfaces:**
- Consumes: injected `fs`, `textutils`, and disk mount discovery.
- Produces: `Store.new(fsApi, codec, root)`; `store:read(name, validator)`; `store:write(name, value, validator)`; `store:recover(name, validator)`; `Backup.export(store, mount, config, aliases)`; `Backup.import(store, mount, validators)`.

- [ ] **Step 1: Write failing atomic-write and recovery tests**

```lua
local store = Store.new(fsApi, codec, "colossal/data")
T.truthy(store:write("config", { schema = 1, value = "old" }, validate))
fsApi.failMoveTo = "colossal/data/config.lua"
local ok = store:write("config", { schema = 1, value = "new" }, validate)
T.equal(ok, nil)
T.equal(store:recover("config", validate).value, "old")
```

Add cases for malformed primary with valid `.previous`, unsupported schema, codec exceptions, and loss of both journal copies returning `nil, "unsafe journal unavailable"` rather than creating an empty journal.

- [ ] **Step 2: Run persistence tests and verify red**

```powershell
lua colossal/tests/run.lua tests.test_store tests.test_backup
```

Expected: failure because store and backup modules are absent.

- [ ] **Step 3: Implement staged replacement and explicit backup allow-list**

```lua
function Store:write(name, value, validator)
  local valid, reason = validator(value)
  if not valid then return nil, "refusing invalid " .. name .. ": " .. tostring(reason) end
  local encodedOk, encoded = pcall(self.codec.encode, value)
  if not encodedOk then return nil, "encode " .. name .. ": " .. tostring(encoded) end
  -- write name..".staged", validate by decoding it, rotate current to
  -- name..".previous", then move staged to the active path.
  return self:_replaceValidated(name, encoded, validator)
end
```

The concrete `_replaceValidated` implementation must close every handle under `pcall`, retain a valid previous copy until the active move succeeds, and clean only its own staged file. `Backup.export` serializes exactly `{schema=1, config=config, aliases=aliases}` to `<mount>/colossal-backup.lua`; tests assert no `journal`, `history`, `metadata`, `snapshots`, or `counts` keys exist.

- [ ] **Step 4: Run persistence tests and inspect serialized backup**

```powershell
lua colossal/tests/run.lua tests.test_store tests.test_backup
lua colossal/tests/run.lua
git diff --check
```

Expected: interrupted writes recover the previous value and backup boundaries pass.

- [ ] **Step 5: Commit persistence**

```powershell
git add controller/colossal/shared controller/colossal/app/backup.lua controller/colossal/tests
git commit -m "feat: add durable colossal storage persistence"
```

---

### Task 3: Exact identities, role registry, and controller lifecycle

**Files:**
- Create: `controller/colossal/core/identity.lua`
- Create: `controller/colossal/core/registry.lua`
- Create: `controller/colossal/app/lifecycle.lua`
- Create: `controller/colossal/tests/test_identity.lua`
- Create: `controller/colossal/tests/test_registry.lua`
- Create: `controller/colossal/tests/test_lifecycle.lua`
- Modify: `controller/colossal/tests/run.lua`

**Interfaces:**
- Consumes: persisted bindings `{dropoff, pickup, storage[]}` and discovered peripheral descriptors.
- Produces: `Identity.key(name, nbt) -> string`; `Identity.fromItem(item) -> identity`; `Registry.new(config)`; `registry:reconcile(discovered, now) -> nodeStates`; `Lifecycle.derive(context) -> state, reason`; `Lifecycle.transition(kind, from, to) -> ok, reason`.

- [ ] **Step 1: Write failing identity, registry, and transition tests**

```lua
T.equal(Identity.key("minecraft:stone", nil), "minecraft:stone\0-")
T.notEqual(Identity.key("minecraft:potion", "abc"),
  Identity.key("minecraft:potion", "def"))

local states = Registry.new(config):reconcile({
  { name = "drop", methods = inventoryMethods },
  { name = "pickup", methods = inventoryMethods },
  { name = "big_0", methods = inventoryMethods },
}, 1000)
T.equal(states.storage.main.state, "DISCOVERED")

T.equal(Lifecycle.transition("request", "QUEUED", "TRANSFERRING"), nil)
T.truthy(Lifecycle.transition("request", "QUEUED", "PLANNING"))
```

Add role-collision tests, explicit rebind requirements, disabled-node exclusion, and lifecycle derivation for `SETUP_REQUIRED`, `RECOVERING`, `INDEXING`, `READY`, `DEGRADED`, `PAUSED`, and `ERROR`.

- [ ] **Step 2: Run focused tests and verify red**

```powershell
lua colossal/tests/run.lua tests.test_identity tests.test_registry tests.test_lifecycle
```

Expected: missing modules.

- [ ] **Step 3: Implement stable identity keys and table-driven state rules**

```lua
local allowed = {
  request = {
    DRAFT={QUEUED=true,CANCELLED=true}, QUEUED={PLANNING=true,CANCELLED=true},
    PLANNING={TRANSFERRING=true,BLOCKED=true,FAILED=true,CANCELLED=true},
    TRANSFERRING={VERIFYING=true,PARTIAL=true,FAILED=true},
    VERIFYING={COMPLETE=true,PARTIAL=true,BLOCKED=true,FAILED=true},
    BLOCKED={PLANNING=true,CANCELLED=true}, PARTIAL={PLANNING=true,CANCELLED=true},
    FAILED={PLANNING=true,CANCELLED=true},
  },
}
function M.transition(kind, from, to)
  if allowed[kind] and allowed[kind][from] and allowed[kind][from][to] then return true end
  return nil, ("forbidden %s transition %s -> %s"):format(kind, from, to)
end
```

Registry reconciliation preserves stable logical IDs and labels while treating peripheral names as explicit bindings. It never binds by matching contents. Lifecycle derivation has one precedence order: persistence/journal error, setup required, recovering, paused, indexing, degraded, ready.

- [ ] **Step 4: Run focused and full tests**

```powershell
lua colossal/tests/run.lua tests.test_identity tests.test_registry tests.test_lifecycle
lua colossal/tests/run.lua
git diff --check
```

Expected: forbidden transitions fail with stable reason codes and all lifecycle states are deterministic.

- [ ] **Step 5: Commit state contracts**

```powershell
git add controller/colossal/core controller/colossal/app/lifecycle.lua controller/colossal/tests
git commit -m "feat: define colossal storage state contracts"
```

---

### Task 4: Protected peripheral adapter and bounded scanner

**Files:**
- Create: `controller/colossal/core/scanner.lua`
- Extend: `controller/colossal/tests/mock_cc.lua`
- Create: `controller/colossal/tests/test_scanner.lua`
- Modify: `controller/colossal/tests/run.lua`

**Interfaces:**
- Consumes: `peripheral.wrap(name)`-compatible adapter, logical node, scan epoch, and a per-step slot budget.
- Produces: `Scanner.new(peripheralApi, clock)`; `scanner:begin(node) -> scan`; `scanner:step(scan, budget) -> done, snapshot_or_reason`; snapshot `{node_id, peripheral_name, epoch, size, slots, occupied, health="READY"}`.

- [ ] **Step 1: Write failing scanner tests with a 3,075-slot fake inventory**

```lua
local scan = scanner:begin({ id="main", peripheral_name="colossal_0" })
local done = scanner:step(scan, 32)
T.equal(done, false)
local callsBefore = fake.calls.list
while not done do done, snapshot = scanner:step(scan, 32) end
T.equal(fake.calls.list, callsBefore)
T.equal(snapshot.size, 3075)
T.equal(snapshot.slots[417].name, "minecraft:cobblestone")
```

Add tests for `list()` returning a sparse table, invalid slot/count/name values, detach during `size`, detach during `list`, exception text sanitization, and snapshot immutability after the fake inventory mutates. Metadata-detail disconnect behavior belongs to Task 5.

- [ ] **Step 2: Run scanner tests and verify red**

```powershell
lua colossal/tests/run.lua tests.test_scanner
```

Expected: scanner module missing.

- [ ] **Step 3: Implement one-call snapshots with bounded validation work**

```lua
function Scanner:begin(node)
  local wrapped, reason = self:_inventory(node.peripheral_name)
  if not wrapped then return { failed = reason, node = node } end
  local ok, listed = Runtime.safeCall("list " .. node.id, wrapped.list)
  if not ok or type(listed) ~= "table" then
    return { failed = listed or "invalid list response", node = node }
  end
  return { node=node, wrapped=wrapped, listed=listed, keys=sortedNumericKeys(listed),
    cursor=1, slots={}, occupied=0, epoch=self.clock() }
end
```

`step` validates at most `budget` occupied entries per call and yields control to the coordinator afterward. It copies item records, derives exact identities, and returns structured reasons `{code, message, node_id}` instead of throwing.

- [ ] **Step 4: Run scanner and full suites**

```powershell
lua colossal/tests/run.lua tests.test_scanner
lua colossal/tests/run.lua
git diff --check
```

Expected: scan work remains bounded and peripheral failures become node errors rather than suite errors.

- [ ] **Step 5: Commit scanner**

```powershell
git add controller/colossal/core/scanner.lua controller/colossal/tests
git commit -m "feat: add bounded inventory scanner"
```

---

### Task 5: Immutable pooled index and background metadata catalogue

**Files:**
- Create: `controller/colossal/core/index.lua`
- Create: `controller/colossal/tests/test_index.lua`
- Modify: `controller/colossal/tests/run.lua`

**Interfaces:**
- Consumes: fresh storage snapshots plus optional cached metadata/aliases.
- Produces: `Index.build(snapshots, metadata) -> snapshot`; `snapshot:quantity(identityKey)`; `snapshot:sources(identityKey)`; `snapshot:items()`; `Index.enrichStep(snapshot, registry, budget)`.

- [ ] **Step 1: Write failing aggregation and stale-exclusion tests**

```lua
local index = Index.build({
  ready("a", { [1]=item("minecraft:stone", nil, 64) }),
  ready("b", { [9]=item("minecraft:stone", nil, 12) }),
  stale("c", { [2]=item("minecraft:stone", nil, 99) }),
}, {})
T.equal(index:quantity(Identity.key("minecraft:stone", nil)), 76)
T.equal(#index:sources(Identity.key("minecraft:stone", nil)), 2)
```

Add NBT variant separation, stable source ordering by node priority/slot, old index immutability after rebuilding, representative detail caching, alias preservation, and metadata failure retaining registry-name searchability.

- [ ] **Step 2: Run index tests and verify red**

```powershell
lua colossal/tests/run.lua tests.test_index
```

Expected: index module missing.

- [ ] **Step 3: Implement rebuildable snapshot objects**

```lua
function M.build(snapshots, metadata)
  local byIdentity, ordered = {}, {}
  for _, snapshot in ipairs(snapshots) do
    if snapshot.health == "READY" then
      for slot, item in pairs(snapshot.slots) do
        local key = Identity.key(item.name, item.nbt)
        local aggregate = byIdentity[key] or newAggregate(key, item, metadata[key])
        aggregate.quantity = aggregate.quantity + item.count
        aggregate.sources[#aggregate.sources+1] = {
          node_id=snapshot.node_id, peripheral_name=snapshot.peripheral_name,
          slot=slot, count=item.count, epoch=snapshot.epoch,
        }
        byIdentity[key] = aggregate
      end
    end
  end
  return freezeIndex(byIdentity, ordered)
end
```

Copy every externally returned list so callers cannot mutate index truth. `enrichStep` performs at most `budget` detail calls and returns a new metadata table plus retryable failures.

- [ ] **Step 4: Run focused and complete tests**

```powershell
lua colossal/tests/run.lua tests.test_index
lua colossal/tests/run.lua
git diff --check
```

Expected: pooled quantities include only fresh nodes and variants remain distinct.

- [ ] **Step 5: Commit index**

```powershell
git add controller/colossal/core/index.lua controller/colossal/tests
git commit -m "feat: add pooled colossal inventory index"
```

---

### Task 6: Capacity-aware import and retrieval planners

**Files:**
- Create: `controller/colossal/core/planner.lua`
- Create: `controller/colossal/tests/test_planner.lua`
- Modify: `controller/colossal/tests/run.lua`

**Interfaces:**
- Consumes: immutable index, fresh Drop-off/Pickup snapshots, storage snapshots, node priorities, identity, and quantity.
- Produces: `Planner.planImport(sourceSlot, storageSnapshots) -> plan, remainder_or_reason`; `Planner.planRetrieval(identityKey, quantity, index, pickupSnapshot) -> plan, remainder_or_reason`; plan steps `{source_name, source_slot, destination_name, limit, identity_key, source_epoch, destination_epoch}`.

- [ ] **Step 1: Write failing multi-node allocation tests**

```lua
local plan, remainder = Planner.planRetrieval(key, 90, index, pickup)
T.equal(remainder, 0)
T.equal(plan[1].source_slot, 4)
T.equal(plan[1].limit, 64)
T.equal(plan[2].limit, 26)

local imports, left = Planner.planImport(dropSlot, {highPriority, lowPriority})
T.equal(imports[1].destination_slot, highPriorityMatchingSlot)
T.equal(left, 0)
```

Cover existing compatible stacks before empty capacity, node priority, pickup with incompatible occupied slots, per-slot `getItemLimit`, stale source rejection, full pool, full pickup, request larger than availability, and exact NBT matching.

- [ ] **Step 2: Run planner tests and verify red**

```powershell
lua colossal/tests/run.lua tests.test_planner
```

Expected: planner missing.

- [ ] **Step 3: Implement pure allocation functions**

```lua
function M.planRetrieval(key, requested, index, pickup)
  local free = compatibleCapacity(pickup, key)
  if free <= 0 then return {}, { code="PICKUP_FULL", retryable=true } end
  local remaining, plan = math.min(requested, free), {}
  for _, source in ipairs(index:sources(key)) do
    local amount = math.min(source.count, remaining)
    if amount > 0 then plan[#plan+1] = retrievalStep(source, pickup, key, amount) end
    remaining = remaining - amount
    if remaining == 0 then break end
  end
  return plan, requested - sumLimits(plan)
end
```

Planning is side-effect free. It never assumes a transfer will move the planned limit and never allocates stale epochs or already-owned slots.

- [ ] **Step 4: Run planner and complete suites**

```powershell
lua colossal/tests/run.lua tests.test_planner
lua colossal/tests/run.lua
git diff --check
```

Expected: deterministic plans and explicit capacity reasons.

- [ ] **Step 5: Commit planners**

```powershell
git add controller/colossal/core/planner.lua controller/colossal/tests
git commit -m "feat: plan pooled storage transfers"
```

---

### Task 7: Journaled transfer executor and conservative reboot reconciliation

**Files:**
- Create: `controller/colossal/core/transfer.lua`
- Create: `controller/colossal/tests/test_transfer.lua`
- Create: `controller/colossal/tests/test_recovery.lua`
- Modify: `controller/colossal/tests/run.lua`

**Interfaces:**
- Consumes: `Store`, peripheral adapter, scanner, allowed-transition function, clock, and one planned step.
- Produces: `Transfer.new(deps)`; `transfer:execute(operation, step) -> result`; `transfer:recover(journal, observed) -> resolution`; result `{moved, state, reason, rescan={source,destination}}`.

- [ ] **Step 1: Write failing exact-count and crash-window tests**

```lua
local result = transfer:execute(operation, stepWithLimit(64))
T.equal(fakeInventory.lastPush.limit, 64)
T.equal(result.moved, 17)
T.equal(result.state, "VERIFYING")
T.equal(store:lastJournal().step.actual_moved, 17)

local resolution = transfer:recover(journalWithState("CALLING"), observedChangedBothSides)
T.equal(resolution.state, "FAILED")
T.equal(resolution.reason.code, "AMBIGUOUS_IN_FLIGHT")
T.equal(fakeInventory.calls.pushItems, 0)
```

Cover exceptions before the peripheral call, exceptions during the call, zero/negative/oversized return validation, short transfers, source identity changed after planning, destination changed after planning, journal write failure preventing movement, and verified completed-step recovery without duplicate calls.

- [ ] **Step 2: Run transfer tests and verify red**

```powershell
lua colossal/tests/run.lua tests.test_transfer tests.test_recovery
```

Expected: transfer module missing.

- [ ] **Step 3: Implement write-ahead transfer steps**

```lua
function Transfer:execute(operation, step)
  local prepared = journalStep(operation, step, "PREPARED", 0)
  local saved, saveReason = self.store:write("journal", prepared, validateJournal)
  if not saved then return failed("JOURNAL_WRITE", saveReason) end
  prepared.step.phase = "CALLING"
  if not self.store:write("journal", prepared, validateJournal) then
    return failed("JOURNAL_WRITE", "could not record call boundary")
  end
  local ok, moved = self.adapter:push(step.source_name, step.destination_name,
    step.source_slot, step.limit, step.destination_slot)
  if not ok then return failed("TRANSFER_EXCEPTION", moved, true) end
  if type(moved) ~= "number" or moved < 0 or moved > step.limit then
    return failed("INVALID_MOVED_COUNT", tostring(moved), true)
  end
  return self:_recordActual(prepared, moved)
end
```

The ambiguous `CALLING` phase is never replayed. Recovery compares recorded preconditions with fresh source and destination observations; only `PREPARED` may safely return to planning without a call, and only a journaled `VERIFIED` step may finalize automatically.

- [ ] **Step 4: Run transfer, recovery, and full suites**

```powershell
lua colossal/tests/run.lua tests.test_transfer tests.test_recovery
lua colossal/tests/run.lua
git diff --check
```

Expected: no test can cause an unjournaled transfer and ambiguous recovery performs zero item movement.

- [ ] **Step 5: Commit transfer engine**

```powershell
git add controller/colossal/core/transfer.lua controller/colossal/tests
git commit -m "feat: add recoverable transfer engine"
```

---

### Task 8: Alerts, imports, and retrieval request services

**Files:**
- Create: `controller/colossal/app/alerts.lua`
- Create: `controller/colossal/app/import_service.lua`
- Create: `controller/colossal/app/requests.lua`
- Create: `controller/colossal/tests/test_alerts.lua`
- Create: `controller/colossal/tests/test_import_service.lua`
- Create: `controller/colossal/tests/test_requests.lua`
- Modify: `controller/colossal/tests/run.lua`

**Interfaces:**
- Consumes: planner, transfer executor, scanner snapshots, lifecycle transitions, clock.
- Produces: `Alerts:set(conditionKey, severity, message, details)`; `Alerts:resolve(conditionKey)`; `Alerts:acknowledge(conditionKey)`; `ImportService:tick(context) -> event`; `Requests:create(identity, quantity)`; `Requests:tick(context) -> event`; `Requests:cancel(id)`.

- [ ] **Step 1: Write failing service tests**

```lua
alerts:set("pickup_full", "warning", "Pickup is full")
alerts:acknowledge("pickup_full")
T.equal(alerts:active()[1].acknowledged, true)
alerts:set("pickup_full", "warning", "Pickup is full")
T.equal(#alerts:active(), 1)
alerts:resolve("pickup_full")
T.equal(#alerts:active(), 0)

local event = imports:tick(contextWithDropoffStack(100))
T.equal(event.state, "TRANSFERRING")
T.equal(fakeTransfer.calls, 1)
```

Add tests for remaining import items staying in Drop-off, blocked capacity recovery, retrieval spanning nodes, user cancellation stopping future steps, partial delivered quantity display, retry backoff, one transfer step per tick, and repeated identical failures creating one alert.

- [ ] **Step 2: Run service tests and verify red**

```powershell
lua colossal/tests/run.lua tests.test_alerts tests.test_import_service tests.test_requests
```

Expected: service modules missing.

- [ ] **Step 3: Implement bounded service ticks and condition alerts**

```lua
function Requests:tick(context)
  local request = self:_nextRunnable(context.now)
  if not request then return { kind="idle" } end
  if request.state == "QUEUED" or request.state == "BLOCKED" then
    return self:_planOne(request, context)
  end
  if request.state == "TRANSFERRING" then
    return self:_executeOneStep(request, context)
  end
  if request.state == "VERIFYING" then
    return self:_verifyOne(request, context)
  end
  return { kind="idle" }
end
```

Each tick performs at most one plan, transfer, or verification unit. `BLOCKED` retries only when a relevant inventory generation changes or its exponential-backoff deadline arrives. `FAILED` requires operator retry after affected snapshots refresh.

- [ ] **Step 4: Run service and complete suites**

```powershell
lua colossal/tests/run.lua tests.test_alerts tests.test_import_service tests.test_requests
lua colossal/tests/run.lua
git diff --check
```

Expected: imports and requests progress independently without loops that consume the event thread.

- [ ] **Step 5: Commit operation services**

```powershell
git add controller/colossal/app controller/colossal/tests
git commit -m "feat: add import and retrieval services"
```

---

### Task 9: Ranked search, aliases, variants, and quantity commands

**Files:**
- Create: `controller/colossal/app/search.lua`
- Create: `controller/colossal/app/keymap.lua`
- Create: `controller/colossal/tests/test_search.lua`
- Create: `controller/colossal/tests/test_keymap.lua`
- Modify: `controller/colossal/tests/run.lua`

**Interfaces:**
- Consumes: immutable index snapshot, metadata, aliases, and raw CraftOS input events.
- Produces: `Search.query(index, query, aliases, limit) -> results`; `Search.variants(result) -> variants`; `Keymap.command(event, uiState) -> command`; commands include `QUERY_APPEND`, `QUERY_BACKSPACE`, `MOVE`, `OPEN_QUANTITY`, `SET_QUANTITY`, `REQUEST`, `CANCEL`, `OPEN_PAGE`, and `ACTIVATE`.

- [ ] **Step 1: Write failing ranking and keyboard-flow tests**

```lua
local results = Search.query(index, "stone", { cobble="minecraft:cobblestone" }, 8)
T.equal(results[1].display_name, "Stone")
T.equal(results[2].display_name, "Cobblestone")

T.equal(Keymap.command({"key", keys.s}, {mode="quantity"}).quantity, "stack")
T.equal(Keymap.command({"key", keys.f10}, {mode="quantity"}).type, "CANCEL")
```

Cover exact display name, word prefix, registry/alias, substring, conservative edit-distance-one fuzzy ranking, stable ties, empty-query recent/frequent items, NBT variant chooser, Enter=1, S=stack, A=all, digit entry, Back/F10 cancel, mouse rows, scroll, and no dependency on metadata being complete.

- [ ] **Step 2: Run search tests and verify red**

```powershell
lua colossal/tests/run.lua tests.test_search tests.test_keymap
```

Expected: search and keymap modules missing.

- [ ] **Step 3: Implement deterministic scoring and command translation**

```lua
local function score(item, query, aliases)
  local display, registry = lower(item.display_name), lower(item.name)
  if display == query then return 500 end
  if wordPrefix(display, query) then return 400 end
  if registry == query or aliasMatches(item, query, aliases) then return 300 end
  if display:find(query, 1, true) or registry:find(query, 1, true) then return 200 end
  if #query >= 4 and editDistanceAtMostOne(display, query) then return 100 end
  return nil
end
```

Sort by score descending, live quantity descending, normalized display name ascending, then identity key ascending. Keymap translates only; it never mutates state or starts transfers.

- [ ] **Step 4: Run search and complete suites**

```powershell
lua colossal/tests/run.lua tests.test_search tests.test_keymap
lua colossal/tests/run.lua
git diff --check
```

Expected: all documented keyboard and mouse commands are deterministic.

- [ ] **Step 5: Commit search**

```powershell
git add controller/colossal/app/search.lua controller/colossal/app/keymap.lua controller/colossal/tests
git commit -m "feat: add responsive storage search"
```

---

### Task 10: Scratch-built terminal UI and responsive status monitor

**Files:**
- Create: `controller/colossal/app/ui.lua`
- Create: `controller/colossal/app/monitor.lua`
- Create: `controller/colossal/tests/test_ui.lua`
- Create: `controller/colossal/tests/test_ui_layout.lua`
- Create: `controller/colossal/tests/test_monitor.lua`
- Modify: `controller/colossal/tests/run.lua`

**Interfaces:**
- Consumes: read-only coordinator view model and commands from `keymap.lua`.
- Produces: `UI.new(surface)`; `ui:reduce(state, command) -> state, effect`; `ui:render(state, viewModel)`; `Monitor.render(surface, viewModel)`.

- [ ] **Step 1: Write failing rendering and interaction tests**

```lua
local surface = T.recordingSurface(51, 19)
UI.new(surface):render(searchState("sto"), viewModel)
T.contains(surface.line(1), "COLOSSAL STORAGE")
T.contains(surface.line(3), "> sto")
T.contains(surface:allText(), "Stone")
T.contains(surface:allText(), "1,248")
T.equal(surface:writesOutsideBounds(), 0)
```

Add golden-layout assertions for Search, quantity modal, variant chooser, Storage Nodes, Requests, Alerts, and Setup; empty states must say what to do next. Test 51x19 keyboard completion, mouse activation, query persistence after cancel, selection clamping after index changes, narrow terminal fallback, and no synchronous peripheral calls from render/reduce.

Monitor tests render small, medium, and representative 2x6 dimensions; they assert prominent overall state, highest alert, total available items, Drop-off/Pickup state, active request, node health, recent transfers on large displays, and safe rendering after `monitor_resize`.

- [ ] **Step 2: Run UI tests and verify red**

```powershell
lua colossal/tests/run.lua tests.test_ui tests.test_ui_layout tests.test_monitor
```

Expected: UI modules missing.

- [ ] **Step 3: Implement clipped primitives and pure view-state reduction**

```lua
local function writeClipped(surface, x, y, text, width)
  local sw, sh = surface.getSize()
  if y < 1 or y > sh or x > sw or width <= 0 then return end
  text = tostring(text):sub(1, math.min(width, sw - x + 1))
  if #text > 0 then surface.setCursorPos(math.max(1, x), y); surface.write(text) end
end

function UI:reduce(state, command)
  local nextState = copyState(state)
  if command.type == "QUERY_APPEND" then
    nextState.query = nextState.query .. command.text
    nextState.selection, nextState.scroll = 1, 1
  elseif command.type == "CANCEL" then
    nextState.mode = "search"
  elseif command.type == "REQUEST" then
    return nextState, { type="CREATE_REQUEST", identity=state.identity,
      quantity=command.quantity }
  end
  return nextState
end
```

Every page clears and redraws a controlled region, restores cursor blink intentionally, clips all text, and derives colors from semantic roles. Monitor breakpoints are based on `getSize()` on every render, not cached dimensions.

- [ ] **Step 4: Run UI, monitor, and complete suites**

```powershell
lua colossal/tests/run.lua tests.test_ui tests.test_ui_layout tests.test_monitor
lua colossal/tests/run.lua
git diff --check
```

Expected: zero out-of-bounds writes and every workflow remains keyboard-complete at 51x19.

- [ ] **Step 5: Commit UI and monitor**

```powershell
git add controller/colossal/app/ui.lua controller/colossal/app/monitor.lua controller/colossal/tests
git commit -m "feat: add polished colossal storage interface"
```

---

### Task 11: Full-screen setup, validation, rebinding, and recovery import

**Files:**
- Create: `controller/colossal/app/setup.lua`
- Create: `controller/colossal/tests/test_setup.lua`
- Create: `controller/colossal/tests/test_setup_validation.lua`
- Create: `controller/colossal/tests/test_setup_recovery.lua`
- Modify: `controller/colossal/app/ui.lua`
- Modify: `controller/colossal/app/keymap.lua`
- Modify: `controller/colossal/tests/run.lua`

**Interfaces:**
- Consumes: discovered peripherals, registry validation, store, backup import, current computer identity.
- Produces: `Setup.new(deps)`; `setup:discover()`; `setup:assign(role, peripheralName)`; `setup:addStorage(peripheralName, label, priority)`; `setup:validate() -> report`; `setup:commit(report)`; `setup:recoverBackup(mount)`.

- [ ] **Step 1: Write failing wizard and validation tests**

```lua
local setup = Setup.new(deps)
setup:assign("dropoff", "minecraft:chest_0")
setup:assign("pickup", "minecraft:chest_0")
local report = setup:validate()
T.equal(report.ok, false)
T.equal(report.issues[1].code, "ROLE_COLLISION")
T.equal(fakeInventory.calls.pushItems, 0)
```

Cover missing methods, missing storage node, duplicate logical binding, suspicious duplicate interface warning requiring explicit disable/rebind, labels/priorities, read-only validation, installation identity capture, backup recovery review before commit, edit-config entry from the main UI, and cancellation preserving the active configuration.

- [ ] **Step 2: Run setup tests and verify red**

```powershell
lua colossal/tests/run.lua tests.test_setup tests.test_setup_validation tests.test_setup_recovery
```

Expected: setup module missing or UI has no setup flow.

- [ ] **Step 3: Implement draft-only setup and explicit commit**

```lua
function Setup:validate()
  local issues = {}
  requireUniqueRole(self.draft, "dropoff", issues)
  requireUniqueRole(self.draft, "pickup", issues)
  requireDistinctIO(self.draft, issues)
  requireStorage(self.draft, issues)
  validateMethods(self.draft, self.peripheral, issues)
  detectSuspiciousDuplicates(self.draft, self.readOnlySnapshots, issues)
  return { ok = not hasBlocking(issues), issues = issues, draft = deepCopy(self.draft) }
end
function Setup:commit(report)
  if not report.ok then return nil, "validation has blocking issues" end
  return self.store:write("config", withInstallation(report.draft, self.os), validateConfig)
end
```

Setup keeps a separate draft until the review page confirms. Validation calls only read methods. The main application enters `SETUP_REQUIRED` when required bindings are absent and allows Setup to be reopened later without stopping scans of the current valid configuration.

- [ ] **Step 4: Run setup, UI, and complete suites**

```powershell
lua colossal/tests/run.lua tests.test_setup tests.test_setup_validation tests.test_setup_recovery tests.test_ui
lua colossal/tests/run.lua
git diff --check
```

Expected: setup cannot move items, cannot commit invalid roles, and backup recovery remains reviewable.

- [ ] **Step 5: Commit setup**

```powershell
git add controller/colossal/app controller/colossal/tests
git commit -m "feat: add colossal storage setup wizard"
```

---

### Task 12: Cooperative coordinator, event-loop integration, and recovery gates

**Files:**
- Create: `controller/colossal/app/coordinator.lua`
- Create: `controller/colossal/tests/test_coordinator.lua`
- Create: `controller/colossal/tests/test_responsiveness.lua`
- Create: `controller/colossal/tests/test_error_recovery.lua`
- Modify: `controller/colossal/main.lua`
- Modify: `controller/colossal/tests/run.lua`

**Interfaces:**
- Consumes: registry, scanner, index, imports, requests, alerts, setup, persistence, UI, monitor, OS event/timer APIs.
- Produces: `Coordinator.new(deps)`; `coordinator:tick(now)`; `coordinator:handle(event)`; `coordinator:viewModel()`; `coordinator:run()`.

- [ ] **Step 1: Write failing scheduling and first-boot recovery tests**

```lua
local coordinator = Coordinator.new(deps)
coordinator:handle({"char", "s"})
T.equal(coordinator:viewModel().ui.query, "s")
T.equal(fakeScanner.completedScans, 0)
coordinator:tick(1000)
T.equal(fakeScanner.stepCalls, 1)
T.equal(coordinator:viewModel().ui.query, "s")
```

Add tests that reproduce the prior filtered-receive timer loss: complete first-run setup, then advance deterministic events without reboot and assert scans/imports continue. Cover peripheral attach/detach, monitor resize, one failed scan not stopping input, journal recovery blocking new transfers, pause/resume, timer rearming independent of prior timer receipt, scan rotation fairness, targeted rescans after transfer, metadata budget, and view-model immutability.

- [ ] **Step 2: Run coordinator tests and verify red**

```powershell
lua colossal/tests/run.lua tests.test_coordinator tests.test_responsiveness tests.test_error_recovery
```

Expected: coordinator missing and first-boot event-flow assertions fail.

- [ ] **Step 3: Implement independent cooperative loops**

```lua
function Coordinator:run()
  local function events()
    while true do self:handle({ os.pullEventRaw() }) end
  end
  local function heartbeat()
    while true do
      sleep(self.intervals.heartbeat)
      self:tick(self.clock())
    end
  end
  local function worker()
    while true do
      self:workStep(self.clock())
      sleep(0)
    end
  end
  parallel.waitForAny(events, heartbeat, worker)
end
```

No loop filters out events needed by another loop. `workStep` performs one bounded scanner, enrichment, import, request, reconciliation, backup, or redraw unit using fair queues. Main assembles real adapters, validates persistence and installation identity, enters recovery before automation, and catches component errors at coordinator boundaries while leaving terminal input alive.

- [ ] **Step 4: Run coordinator and full suites**

```powershell
lua colossal/tests/run.lua tests.test_coordinator tests.test_responsiveness tests.test_error_recovery
lua colossal/tests/run.lua
git diff --check
```

Expected: the query changes immediately during active 3,075-slot scans and after first-run setup without reboot.

- [ ] **Step 5: Commit coordinator integration**

```powershell
git add controller/colossal/main.lua controller/colossal/app/coordinator.lua controller/colossal/tests
git commit -m "feat: integrate cooperative storage controller"
```

---

### Task 13: End-to-end acceptance tests, operations guide, and deployment manifest

**Files:**
- Create: `controller/colossal/tests/test_acceptance.lua`
- Create: `controller/colossal/tests/test_deployment.lua`
- Create: `docs/operations.md`
- Modify: `controller/colossal/tests/run.lua`
- Modify: `README.md`
**Interfaces:**
- Consumes: the complete controller composition through injected CC mocks.
- Produces: reproducible v1 acceptance evidence and an exact runtime-only deployment file list.

- [ ] **Step 1: Write failing end-to-end scenarios and deployment-boundary tests**

```lua
local app = Harness.new({ storageNodes=2, colossalSlots=3075 })
app:deposit("minecraft:stone", nil, 100)
app:runUntil(function(v) return v.index:quantity(stoneKey) == 100 end, 500)
app:typeQuery("stone")
app:requestSelected(70)
app:runUntil(function(v) return v.requests[1].state == "COMPLETE" end, 500)
T.equal(app:pickupCount(stoneKey), 70)
T.equal(app:storageCount(stoneKey), 30)
T.equal(app:totalCount(stoneKey), 100)
```

Define `Harness` locally in `test_acceptance.lua` by assembling the real `Coordinator`, scanner, planner, transfer, services, UI reducer, and in-memory CC adapters; `runUntil(predicate, maxTicks)` must fail with the final lifecycle and operation states when the bound is exhausted. Add acceptance scenarios for multi-node retrieval, full Drop-off/storage/Pickup alerts, node failure degrading capacity, reconnect recovery, exact NBT variants, short transfer, controller reboot at every journal phase, active UI typing during work, monitor resize, setup recovery, and configuration-only floppy contents.

`test_deployment.lua` recursively enumerates `controller/` and asserts the deployment allow-list contains only `startup.lua` and non-test `.lua` files under `colossal/`; it rejects `tests`, `data`, docs, Git files, plans, backups, and helper scripts.

- [ ] **Step 2: Run acceptance tests and verify any uncovered integration failures**

```powershell
lua colossal/tests/run.lua tests.test_acceptance tests.test_deployment
```

Expected before integration fixes: at least one scenario exposes an incomplete adapter or composition path; record the exact failing assertion in the task notes.

- [ ] **Step 3: Fix only the integration paths proven by acceptance tests and document operations**

`docs/operations.md` must give exact procedures for:

1. Physical wired topology and the one-interface-per-Colossal-Chest rule.
2. Fresh install and runtime-only file copy.
3. First boot, role assignment, node labels/priorities, and read-only validation.
4. Normal Drop-off and Pickup use.
5. READY, DEGRADED, PAUSED, RECOVERING, SETUP_REQUIRED, and ERROR meanings.
6. Full inventory, offline node, ambiguous journal, corrupted config, and failed metadata recovery.
7. Configuration/alias floppy export and recovery.
8. Safe upgrade and rollback without copying inventory snapshots or journals between machines.

Any acceptance fix must add a focused regression test in the owning module before changing production code.

- [ ] **Step 4: Run complete verification and inspect the runtime manifest**

```powershell
lua colossal/tests/run.lua
git diff --check
git status --short
git diff --stat
```

Expected: zero failed tests, clean whitespace, and only intentional source/tests/docs changes. Separately rerun the already-passed creative-world compatibility script against the target pack before live installation; it must finish with `ALL TESTS PASSED`.

- [ ] **Step 5: Commit the v1 implementation**

```powershell
git add README.md docs/operations.md controller
git commit -m "test: verify colossal storage v1 workflows"
```

---

## Live Deployment Gate

Implementation completion does not authorize deployment. Before copying files into the Minecraft server workspace:

- [ ] Confirm which numeric computer will host Colossal Storage and its exact label.
- [ ] Confirm that computer is shut down in game.
- [ ] Resolve and print the absolute source and destination paths.
- [ ] Compare the deployment manifest against the copy list.
- [ ] Copy only `controller/startup.lua` and runtime `.lua` files under `controller/colossal/`, excluding `tests/` and `data/`.
- [ ] Hash every copied file and compare source/destination.
- [ ] List the destination and confirm there are no Git, docs, test, helper, or planning files.
- [ ] Boot only after the user confirms the physical Drop-off, Pickup, storage interfaces, controller modem, and monitor are wired.
- [ ] Complete setup with read-only validation before enabling automation.
- [ ] Perform an item-conservation smoke test with a disposable stack, then verify Drop-off + Pickup + all storage counts equal the starting total.