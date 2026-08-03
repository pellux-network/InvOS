local Transfer = {}
Transfer.__index = Transfer

local phases = { PREPARED=true, CALLING=true, CALLED=true, VERIFIED=true, FAILED=true }

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function reason(code, message, ambiguous)
    return { code=code, message=tostring(message), ambiguous=ambiguous == true }
end

local function rescanFor(operation, step)
    if not step then return nil end
    if operation and operation.kind == "request" then return { step.source_name } end
    return { step.source_name, step.destination_name }
end

local function failed(code, message, ambiguous, operation, step)
    local result = { state="FAILED", moved=0, reason=reason(code, message, ambiguous) }
    result.rescan = rescanFor(operation, step)
    return result
end

function Transfer.validateJournal(value)
    if type(value) ~= "table" or value.schema ~= 1 then return nil, "journal schema must be 1" end
    if type(value.operation) ~= "table" or type(value.operation.id) ~= "string" or
        type(value.operation.kind) ~= "string" or type(value.operation.state) ~= "string" then
        return nil, "journal operation is invalid"
    end
    local step = value.step
    if type(step) ~= "table" or type(step.id) ~= "string" or not phases[step.phase] then
        return nil, "journal step is invalid"
    end
    local requiredStrings = { "source_name", "destination_name", "identity_key" }
    for _, field in ipairs(requiredStrings) do
        if type(step[field]) ~= "string" then return nil, "journal step " .. field .. " is invalid" end
    end
    local requiredNumbers = {
        "source_slot", "source_epoch", "source_pre_count", "limit", "actual_moved",
    }
    if value.operation.kind ~= "request" then
        requiredNumbers[#requiredNumbers + 1] = "destination_slot"
        requiredNumbers[#requiredNumbers + 1] = "destination_epoch"
        requiredNumbers[#requiredNumbers + 1] = "destination_pre_count"
    end
    for _, field in ipairs(requiredNumbers) do
        if type(step[field]) ~= "number" then return nil, "journal step " .. field .. " is invalid" end
    end
    if step.limit < 0 or step.actual_moved < 0 or step.actual_moved > step.limit then
        return nil, "journal movement quantities are invalid"
    end
    if type(value.updated_at) ~= "number" then return nil, "journal timestamp is invalid" end
    return true
end

function Transfer.new(deps)
    assert(type(deps) == "table", "transfer dependencies are required")
    assert(type(deps.store) == "table", "transfer store is required")
    assert(type(deps.adapter) == "table", "inventory adapter is required")
    assert(type(deps.clock) == "function", "transfer clock is required")
    return setmetatable({ store=deps.store, adapter=deps.adapter, clock=deps.clock }, Transfer)
end

function Transfer:_inspect(name, slot)
    if type(self.adapter.inspect) ~= "function" then
        return nil, "inventory adapter cannot inspect slots"
    end
    local callOk, ok, observed = pcall(self.adapter.inspect, self.adapter, name, slot)
    if not callOk then return nil, tostring(ok) end
    if not ok or type(observed) ~= "table" then return nil, tostring(observed) end
    return observed
end

function Transfer:_preflight(operation, step)
    local source, sourceReason = self:_inspect(step.source_name, step.source_slot)
    if not source then return nil, reason("SOURCE_UNAVAILABLE", sourceReason, false) end
    if source.identity_key ~= step.identity_key or source.count ~= step.source_pre_count or
        source.count < step.limit then
        return nil, reason("SOURCE_CHANGED", "source changed: generation "..tostring(source.generation)..
            "/"..tostring(step.source_epoch)..", identity "..tostring(source.identity_key)..
            "/"..tostring(step.identity_key)..", count "..tostring(source.count)..
            "/"..tostring(step.source_pre_count), false)
    end
    if operation.kind == "request" then return true end

    local destination, destinationReason = self:_inspect(
        step.destination_name, step.destination_slot)
    if not destination then
        return nil, reason("DESTINATION_UNAVAILABLE", destinationReason, false)
    end
    local identityMatches = step.destination_pre_count == 0 and
        (destination.identity_key == nil or destination.count == 0) or
        destination.identity_key == step.identity_key
    if not identityMatches or destination.count ~= step.destination_pre_count then
        return nil, reason("DESTINATION_CHANGED",
            "destination no longer matches the planned snapshot", false)
    end
    return true
end

local function makeJournal(operation, step, now)
    return {
        schema = 1,
        operation = {
            id = operation.id,
            kind = operation.kind,
            state = operation.state,
            moved = operation.moved or 0,
        },
        step = {
            id = operation.id .. ":" .. tostring(operation.next_step or 1),
            phase = "PREPARED",
            source_name = step.source_name,
            source_slot = step.source_slot,
            source_epoch = step.source_epoch,
            source_pre_count = step.source_pre_count,
            destination_name = step.destination_name,
            destination_slot = step.destination_slot,
            destination_epoch = step.destination_epoch,
            destination_pre_count = step.destination_pre_count,
            identity_key = step.identity_key,
            limit = step.limit,
            actual_moved = 0,
        },
        updated_at = now,
    }
end

function Transfer:execute(operation, step)
    if type(operation) ~= "table" or type(operation.id) ~= "string" or
        type(operation.kind) ~= "string" or type(operation.state) ~= "string" or
        type(step) ~= "table" then
        return failed("INVALID_OPERATION", "operation and transfer step are required", false)
    end
    local ready, preflightReason = self:_preflight(operation, step)
    if not ready then
        return { state="FAILED", moved=0, reason=preflightReason,
            rescan=rescanFor(operation, step) }
    end

    local journal = makeJournal(operation, step, self.clock())
    local saved, saveReason = self.store:write("journal", journal, Transfer.validateJournal)
    if not saved then return failed("JOURNAL_WRITE", saveReason, false, operation, step) end

    journal.step.phase = "CALLING"
    journal.updated_at = self.clock()
    saved, saveReason = self.store:write("journal", journal, Transfer.validateJournal)
    if not saved then return failed("JOURNAL_WRITE", saveReason, false, operation, step) end

    local destinationSlot=operation.kind == "request" and nil or step.destination_slot
    local callOk, ok, moved = pcall(self.adapter.push, self.adapter,
        step.source_name, step.destination_name, step.source_slot, step.limit,
        destinationSlot)
    if not callOk then return failed("TRANSFER_EXCEPTION", ok, true, operation, step) end
    if not ok then return failed("TRANSFER_EXCEPTION", moved, true, operation, step) end
    if type(moved) ~= "number" or moved % 1 ~= 0 or moved < 0 or moved > step.limit then
        return failed("INVALID_MOVED_COUNT", "inventory returned " .. tostring(moved), true,
            operation, step)
    end

    journal.step.phase = "CALLED"
    journal.step.actual_moved = moved
    journal.updated_at = self.clock()
    saved, saveReason = self.store:write("journal", journal, Transfer.validateJournal)
    if not saved then
        return failed("JOURNAL_WRITE_AFTER_CALL", saveReason, true, operation, step)
    end
    return {
        state = "VERIFYING",
        moved = moved,
        journal = copy(journal),
        rescan = rescanFor(operation, step),
    }
end

local function observedMatches(journal, observed)
    if type(observed) ~= "table" or type(observed.source) ~= "table" then return false end
    local step=journal.step
    local sourceExpected = step.source_pre_count - step.actual_moved
    local sourceIdentityOk = sourceExpected == 0 and
        (observed.source.identity_key == nil or observed.source.count == 0) or
        observed.source.identity_key == step.identity_key
    local sourceMatches=sourceIdentityOk and observed.source.count == sourceExpected
    if journal.operation.kind=="request" then return sourceMatches end
    if type(observed.destination) ~= "table" then return false end
    local destinationExpected = step.destination_pre_count + step.actual_moved
    local destinationIdentityOk = destinationExpected == 0 and
        (observed.destination.identity_key == nil or observed.destination.count == 0) or
        observed.destination.identity_key == step.identity_key
    return sourceMatches and destinationIdentityOk and
        observed.destination.count == destinationExpected
end

function Transfer:verify(journal, observed)
    local valid, validationReason = Transfer.validateJournal(journal)
    if not valid then return failed("INVALID_JOURNAL", validationReason, false) end
    if journal.step.phase ~= "CALLED" then
        return failed("INVALID_VERIFY_PHASE", "journal step is not awaiting verification", false,
            journal.operation, journal.step)
    end
    if not observedMatches(journal, observed) then
        local failedJournal = copy(journal)
        failedJournal.step.phase = "FAILED"
        failedJournal.step.observed = copy(observed)
        failedJournal.updated_at = self.clock()
        self.store:write("journal", failedJournal, Transfer.validateJournal)
        local message=journal.operation.kind=="request" and
            "observed source count does not match the recorded move" or
            "observed source and destination counts do not conserve the recorded move"
        local result = failed("VERIFY_MISMATCH", message, false,
            journal.operation, journal.step)
        result.observed = copy(observed)
        return result
    end

    local verified = copy(journal)
    verified.step.phase = "VERIFIED"
    verified.updated_at = self.clock()
    local saved, saveReason = self.store:write("journal", verified, Transfer.validateJournal)
    if not saved then
        return failed("JOURNAL_WRITE", saveReason, false, journal.operation, journal.step)
    end
    return { state="COMPLETE", moved=verified.step.actual_moved, journal=verified }
end

function Transfer:recover(journal, observed)
    local valid, validationReason = Transfer.validateJournal(journal)
    if not valid then return failed("INVALID_JOURNAL", validationReason, false) end
    local phase = journal.step.phase
    if phase == "PREPARED" then
        return { state="PLANNING", moved=0, replay_safe=true, journal=copy(journal) }
    end
    if phase == "CALLING" then
        local result = failed("AMBIGUOUS_IN_FLIGHT",
            "the controller restarted while an inventory call may have been active",
            true, journal.operation, journal.step)
        result.observed = copy(observed or {})
        return result
    end
    if phase == "CALLED" then return self:verify(journal, observed) end
    if phase == "VERIFIED" then
        return { state="COMPLETE", moved=journal.step.actual_moved, journal=copy(journal) }
    end
    if phase == "FAILED" and journal.operation.kind == "request" then
        local retry=copy(journal);retry.step.phase="CALLED"
        return self:verify(retry,observed)
    end
    return failed("JOURNALED_FAILURE", "journal records a failed transfer step", false,
        journal.operation, journal.step)
end

return Transfer