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

local function firstSlot(slots)
    local selected
    for slot in pairs(slots or {}) do
        if type(slot) == "number" and (not selected or slot < selected) then selected = slot end
    end
    return selected
end

function ImportService.new(deps)
    assert(type(deps) == "table", "import dependencies are required")
    return setmetatable({
        planner=assert(deps.planner, "import planner is required"),
        transfer=assert(deps.transfer, "transfer service is required"),
        alerts=assert(deps.alerts, "alerts service is required"),
        transition=assert(deps.transition, "transition function is required"),
        clock=assert(deps.clock, "import clock is required"),
        counter=0,
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
    if not self.active or self.active.state ~= "FAILED" then
        return nil, "import is not awaiting operator retry"
    end
    self.active.reason = nil
    self:_state("PLANNING")
    return true
end

function ImportService:_discover(context)
    if type(context.dropoff) ~= "table" or context.dropoff.health ~= "READY" then return nil end
    local slot = firstSlot(context.dropoff.slots)
    if not slot then return nil end
    local item = context.dropoff.slots[slot]
    self.counter = self.counter + 1
    self.active = {
        id="import-" .. self.counter,
        kind="import",
        state="PENDING",
        moved=0,
        original_count=item.count,
        attempts=0,
        source={
            peripheral_name=context.dropoff.peripheral_name,
            slot=slot,
            epoch=context.dropoff.epoch,
            name=item.name,
            nbt=item.nbt,
            count=item.count,
            identity_key=item.identity_key,
            max_count=item.max_count,
        },
        created_at=self.clock(),
        updated_at=self.clock(),
    }
    return true
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
        local plan, remainder, planReason = self.planner.planImport(active.source,
            context.storage or {})
        active.plan_remainder = remainder
        if #plan == 0 then
            self:_block(context, planReason)
        else
            active.step = copy(plan[1])
            active.reason = nil
            self:_state("TRANSFERRING")
        end
    elseif active.state == "TRANSFERRING" then
        local result = self.transfer:execute(active, active.step)
        if result.state == "VERIFYING" then
            active.journal = result.journal
            active.pending_moved = result.moved
            active.rescan = copy(result.rescan)
            self:_state("VERIFYING")
        else
            active.reason = copy(result.reason)
            self:_state("FAILED")
            self.alerts:set("import_failed:" .. active.source.identity_key,
                "critical", active.reason.message, {code=active.reason.code})
        end
    elseif active.state == "VERIFYING" then
        local result = self.transfer:verify(active.journal, context.observed or {})
        if result.state ~= "COMPLETE" then
            active.reason = copy(result.reason)
            self:_state("FAILED")
            self.alerts:set("import_failed:" .. active.source.identity_key,
                "critical", active.reason.message, {code=active.reason.code})
        elseif result.moved <= 0 then
            self:_block(context, {code="SHORT_TRANSFER",
                message="Storage accepted no items",retryable=true})
        else
            active.moved = active.moved + result.moved
            active.step, active.journal, active.pending_moved = nil, nil, nil
            self.alerts:resolve("import_blocked:" .. active.source.identity_key)
            if active.moved >= active.original_count then
                self:_state("COMPLETE")
            else
                self:_state("PARTIAL")
            end
        end
    elseif active.state == "PARTIAL" then
        local current = context.dropoff and context.dropoff.slots and
            context.dropoff.slots[active.source.slot]
        if not current or current.identity_key ~= active.source.identity_key then
            active.reason = {code="SOURCE_CHANGED",message="Drop-off source changed during import"}
            self:_state("FAILED")
        else
            active.source.count = current.count
            active.source.epoch = context.dropoff.epoch
            self:_state("PLANNING")
        end
    elseif active.state == "BLOCKED" then
        local generationChanged = context.generation ~= active.blocked_generation
        local retryDue = (context.now or self.clock()) >= active.next_retry_at
        if generationChanged or retryDue then self:_state("PLANNING") end
    end
    return self:_event()
end

return ImportService
