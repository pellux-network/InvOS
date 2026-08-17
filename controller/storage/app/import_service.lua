local PlanningRefresh = require("app.planning_refresh")
local StorageScope = require("core.storage_scope")

local ImportService = {}
ImportService.__index = ImportService

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function orderedSlots(slots)
    local result = {}
    for slot in pairs(slots or {}) do
        if type(slot) == "number" then result[#result + 1] = slot end
    end
    table.sort(result)
    return result
end

function ImportService.new(deps)
    assert(type(deps) == "table", "import dependencies are required")
    return setmetatable({
        planner=assert(deps.planner, "import planner is required"),
        transfer=assert(deps.transfer, "transfer service is required"),
        alerts=assert(deps.alerts, "alerts service is required"),
        transition=assert(deps.transition, "transition function is required"),
        clock=assert(deps.clock, "import clock is required"),
        batchLimit=deps.batch_limit or 8,
        slotBatchLimit=deps.slot_batch_limit or 1,
        counter=0, deferred={},
    }, ImportService)
end

function ImportService:_state(to)
    local ok, reason = self.transition("import", self.active.state, to)
    if not ok then error(reason, 2) end
    self.active.state = to
    self.active.updated_at = self.clock()
end

function ImportService:_event()
    return self.active and copy(self.active) or { state="IDLE", moved=0 }
end

function ImportService:status()
    return self:_event()
end

function ImportService:retry()
    if not self.active or (self.active.state ~= "FAILED" and self.active.state ~= "BLOCKED") then
        return nil, "import is not awaiting operator retry"
    end
    self.active.reason = nil
    self.active.planning_refresh,self.active.rescan=nil,nil
    self:_state("PLANNING")
    return true
end

-- `source` stays an alias for the first entry so alert keys and single-source callers keep
-- reading the same field whether the batch spans one Drop-off slot or several.
local function bindSources(active, sources)
    active.sources = sources
    active.source = sources[1]
    local total = 0
    for _, source in ipairs(sources) do total = total + source.count end
    active.original_count = total
    return total
end

-- An item type that currently cannot be placed is set aside for a while rather than kept at
-- the front of the queue. Selection takes the lowest occupied slots, so without this a few
-- unplaceable stacks low in the Drop-off hide every importable slot behind them.
function ImportService:_defer(source, context, reason)
    local entry = self.deferred[source.identity_key] or {attempts=0}
    entry.attempts = entry.attempts + 1
    entry.until_at = (context.now or self.clock()) +
        math.min(60000, 1000 * (2 ^ math.min(entry.attempts - 1, 6)))
    self.deferred[source.identity_key] = entry
    local cause = reason or {code="BLOCKED", message="Import is blocked"}
    self.alerts:set("import_blocked:" .. source.identity_key, "warning",
        cause.message, {code=cause.code})
end

function ImportService:_deferred(identityKey, context)
    local entry = self.deferred[identityKey]
    if not entry then return false end
    if (context.now or self.clock()) >= entry.until_at then return false end
    return true
end

function ImportService:_clearDeferral(identityKey)
    if not self.deferred[identityKey] then return end
    self.deferred[identityKey] = nil
    self.alerts:resolve("import_blocked:" .. identityKey)
end

function ImportService:_discover(context)
    if type(context.dropoff) ~= "table" or context.dropoff.health ~= "READY" then return nil end
    local sources = {}
    for _, slot in ipairs(orderedSlots(context.dropoff.slots)) do
        if #sources >= self.slotBatchLimit then break end
        local item = context.dropoff.slots[slot]
        if self:_deferred(item.identity_key, context) then item = nil end
        if item then
        sources[#sources + 1] = {
            peripheral_name=context.dropoff.peripheral_name,
            slot=slot,
            epoch=context.dropoff.epoch,
            name=item.name,
            nbt=item.nbt,
            count=item.count,
            identity_key=item.identity_key,
            max_count=item.max_count,
        }
        end
    end
    if #sources == 0 then return nil end
    self.counter = self.counter + 1
    self.active = {
        id="import-" .. self.counter,
        kind="import",
        state="PENDING",
        moved=0,
        attempts=0,
        created_at=self.clock(),
        updated_at=self.clock(),
    }
    bindSources(self.active, sources)
    return true
end

-- Re-read every source against the live Drop-off. A source that vanished or changed before
-- any call is not ambiguous, so it simply leaves the batch; the survivors still import.
function ImportService:_refreshSources(context)
    local slots = context.dropoff and context.dropoff.slots or {}
    local survivors = {}
    for _, source in ipairs(self.active.sources) do
        local current = slots[source.slot]
        if current and current.identity_key == source.identity_key then
            source.count = current.count
            source.epoch = context.dropoff.epoch
            source.max_count = current.max_count or source.max_count
            survivors[#survivors + 1] = source
        end
    end
    if #survivors == 0 then return nil end
    bindSources(self.active, survivors)
    return true
end

-- A Drop-off change noticed before any inventory call is not ambiguous: nothing was
-- issued, so there is nothing to prove. Abandon the stale attempt and let the next tick
-- rediscover whatever the Drop-off holds now. Anything that happens after a call still
-- settles into an explicit blocked or failed state awaiting operator retry.
function ImportService:_abandon(code, message)
    local previous = self.active
    self.active = nil
    self.abandoned = {code=code, message=message,
        moved=previous and previous.moved or 0,
        identity_key=previous and previous.source and previous.source.identity_key}
    -- A deferred type keeps its alert: it explains why those items are sitting untouched.
    if previous and previous.source and not self.deferred[previous.source.identity_key] then
        self.alerts:resolve("import_blocked:" .. previous.source.identity_key)
    end
end

function ImportService:_block(context, reason)
    self.active.reason = copy(reason or {code="BLOCKED",message="Import is blocked",retryable=true})
    self.active.blocked_generation = context.generation
    self.active.attempts = self.active.attempts + 1
    self.active.next_retry_at = (context.now or self.clock()) +
        math.min(60000, 1000 * (2 ^ math.min(self.active.attempts - 1, 6)))
    self:_state("BLOCKED")
    self.alerts:set("import_blocked:" .. self.active.source.identity_key,
        "warning", self.active.reason.message, { code=self.active.reason.code })
end

function ImportService:tick(context)
    context = context or {}
    if not self.active or self.active.state == "COMPLETE" then
        if not self:_discover(context) then return { state="IDLE", moved=0 } end
    end

    local active = self.active
    if active.state == "PENDING" then
        self:_state("PLANNING")
    elseif active.state == "PLANNING" then
        if not self:_refreshSources(context) then
            self:_abandon("SOURCE_CHANGED","Drop-off source changed before planning")
            return self:_event()
        end
        -- One gate cycle per batch instead of per step, and one batch across several
        -- Drop-off slots. Capped so a single ambiguous window can never span an unbounded
        -- number of issued calls.
        -- Every source is planned against the same storage snapshot, so a slot one source
        -- claims must be reserved before the next source is planned. Without this, two item
        -- types both pick the first empty slot. owned_slots is the planner's existing
        -- reservation hook.
        local byName = {}
        for _, snapshot in ipairs(context.storage or {}) do
            snapshot.owned_slots = {}
            if type(snapshot.peripheral_name) == "string" then
                byName[snapshot.peripheral_name] = snapshot
            end
        end
        local steps, remainder, planReason = {}, 0, nil
        for _, source in ipairs(active.sources) do
            if #steps >= self.batchLimit then break end
            local plan, sourceRemainder, sourceReason = self.planner.planImport(source,
                context.storage or {})
            if #plan == 0 then planReason = planReason or sourceReason end
            remainder = remainder + (sourceRemainder or 0)
            for _, planned in ipairs(plan) do
                if #steps >= self.batchLimit then break end
                steps[#steps + 1] = copy(planned)
                local snapshot = planned.destination_name and byName[planned.destination_name]
                if snapshot and planned.destination_slot then
                    snapshot.owned_slots[planned.destination_slot] = true
                end
            end
        end
        active.plan_remainder = remainder
        local candidateIds,scopeReason={},nil
        if #steps>0 then
            local _,selectedIds
            _,selectedIds,scopeReason=StorageScope.select("import",steps,context.storage or {})
            candidateIds=selectedIds or {}
        end
        if scopeReason then
            active.reason=copy(scopeReason)
            self:_state("FAILED")
            self.alerts:set("import_failed:"..active.source.identity_key,"critical",
                scopeReason.message,{code=scopeReason.code})
        else
            local action,refresh=PlanningRefresh.advance(active.planning_refresh,
                candidateIds,#steps>0)
            if action=="SCAN" then
                active.planning_refresh=refresh
                local names,refreshReason=PlanningRefresh.names(refresh,
                    context.storage or {},context.dropoff)
                if not names then
                    active.reason=copy(refreshReason)
                    self:_state("FAILED")
                    self.alerts:set("import_failed:"..active.source.identity_key,"critical",
                        refreshReason.message,{code=refreshReason.code})
                else
                    active.rescan=names
                end
            elseif action=="FINAL_NO_PLAN" then
                active.planning_refresh,active.rescan=nil,nil
                -- Nothing in this batch can be placed after a full-pool refresh. Blocking
                -- would replan the same sources forever, so defer their types and rediscover.
                for _, source in ipairs(active.sources) do
                    self:_defer(source, context, planReason)
                end
                self:_abandon("NO_PLAN",
                    planReason and planReason.message or "No storage can accept these items")
                return self:_event()
            else
                active.steps=steps
                active.step=steps[1]
                active.reason,active.rescan,active.planning_refresh=nil,nil,nil
                self:_state("TRANSFERRING")
            end
        end
    elseif active.state == "TRANSFERRING" then
        local result = self.transfer:executeMultiBatch(active, active.steps, context.storage or {})
        if result.state == "VERIFYING" then
            active.journal = result.journal
            active.pending_moved = result.moved
            active.rescan = copy(result.rescan)
            self:_state("VERIFYING")
        elseif result.reason and not result.journal and
            (result.reason.code=="SOURCE_CHANGED" or result.reason.code=="DESTINATION_CHANGED") then
            -- The inventory call was never issued. Discard the stale plan and rediscover;
            -- a result carrying a journal must always reconcile instead of taking this path.
            active.step,active.steps,active.journal=nil,nil,nil
            active.pending_moved,active.rescan,active.reason=nil,nil,nil
            active.planning_refresh=nil
            self:_state("PLANNING")
        elseif result.reason and result.reason.retryable then
            active.rescan=copy(result.rescan)
            self:_block(context,result.reason)
        else
            active.reason = copy(result.reason)
            self:_state("FAILED")
            self.alerts:set("import_failed:" .. active.source.identity_key,
                "critical", active.reason.message, {code=active.reason.code})
        end
    elseif active.state == "VERIFYING" then
        local result = self.transfer:verify(active.journal, context.storage or {})
        if result.state == "WAITING" then
            active.rescan=copy(result.rescan)
            active.reason=copy(result.reason)
            if result.reason and result.reason.code=="RECONCILE_DIRECTION" then
                self.alerts:set("import_reconciliation:"..active.id,"critical",
                    "Storage changed opposite the import; review manual inventory changes",
                    {code="RECONCILE_DIRECTION",import_id=active.id})
            elseif result.reason and result.reason.code=="STORAGE_SCOPE_INCOMPLETE" then
                self.alerts:set("import_reconciliation:"..active.id,"warning",
                    "Import is waiting for every recorded storage node to come online",
                    {code="STORAGE_SCOPE_INCOMPLETE",import_id=active.id})
            end
        elseif result.state ~= "COMPLETE" then
            active.reason = copy(result.reason)
            self:_state("FAILED")
            self.alerts:set("import_failed:" .. active.source.identity_key,
                "critical", active.reason.message, {code=active.reason.code})
        else
            local stepLimit=0
            for _,planned in ipairs(active.steps or {active.step}) do
                stepLimit=stepLimit+planned.limit
            end
            active.moved = active.moved + result.moved
            active.reported_moved=result.reported_moved
            active.moved_by_identity=copy(result.moved_by_identity)
            if result.moved>stepLimit then
                self.alerts:set("import_overdelivery:"..active.id,"critical",
                    "Storage received "..result.moved.." items for a "..stepLimit.." item step",
                    {code="OVER_DELIVERY",requested=stepLimit,measured=result.moved,
                        reported=result.reported_moved,import_id=active.id})
            end
            active.step,active.steps=nil,nil
            active.journal,active.pending_moved,active.rescan=nil,nil,nil
            local callOk,retired,retireReason=pcall(self.transfer.retire,self.transfer)
            if not callOk then retired,retireReason=nil,retired end
            if not retired then self.alerts:set("journal_retire:"..active.id,"warning",
                "Completed transfer journal could not be retired: "..tostring(retireReason),
                {code="JOURNAL_RETIRE",import_id=active.id}) end
            active.reason=nil
            -- Anything that just moved is placeable again, so stop setting it aside.
            for _, source in ipairs(active.sources or {}) do
                self:_clearDeferral(source.identity_key)
            end
            self.alerts:resolve("import_blocked:" .. active.source.identity_key)
            self.alerts:resolve("import_reconciliation:" .. active.id)
            if result.moved<=0 then
                self:_block(context,{code="SHORT_TRANSFER",
                    message="Storage accepted no items",retryable=true})
            elseif active.moved >= active.original_count then
                self:_state("COMPLETE")
            else
                self:_state("PARTIAL")
            end
        end
    elseif active.state == "PARTIAL" then
        if not self:_refreshSources(context) then
            self:_abandon("SOURCE_CHANGED","Drop-off source changed during import")
        else
            self:_state("PLANNING")
        end
    elseif active.state == "BLOCKED" then
        if not active.reason or active.reason.code~="SHORT_TRANSFER" then
            local generationChanged = context.generation ~= active.blocked_generation
            local retryDue = (context.now or self.clock()) >= active.next_retry_at
            if generationChanged or retryDue then self:_state("PLANNING") end
        end
    end
    return self:_event()
end

return ImportService
