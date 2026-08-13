local Requests = {}
Requests.__index = Requests

local terminal = { COMPLETE=true, CANCELLED=true }
local TERMINAL_LIMIT = 30

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

function Requests.new(deps)
    assert(type(deps) == "table", "request dependencies are required")
    return setmetatable({
        planner=assert(deps.planner, "request planner is required"),
        transfer=assert(deps.transfer, "transfer service is required"),
        alerts=assert(deps.alerts, "alerts service is required"),
        transition=assert(deps.transition, "transition function is required"),
        clock=assert(deps.clock, "request clock is required"),
        idGenerator=assert(deps.idGenerator, "request ID generator is required"),
        batchLimit=deps.batch_limit or 8, recordUsage=deps.record_usage,
        counter=0, ordered={}, byId={},
    }, Requests)
end

function Requests:_state(request, to)
    local ok, reason = self.transition("request", request.state, to)
    if not ok then error(reason, 2) end
    request.state = to
    request.updated_at = self.clock()
    if terminal[to] then self:_prune() end
end

-- Terminal requests accumulate forever otherwise, growing the list every
-- redraw pays to deep-copy. Non-terminal requests are never dropped, no
-- matter how old, since they still need operator attention or automation.
function Requests:_prune()
    local terminalCount = 0
    for _, request in ipairs(self.ordered) do
        if terminal[request.state] then terminalCount = terminalCount + 1 end
    end
    local excess = terminalCount - TERMINAL_LIMIT
    if excess <= 0 then return end
    local kept = {}
    for _, request in ipairs(self.ordered) do
        if excess > 0 and terminal[request.state] then
            self.byId[request.id] = nil
            excess = excess - 1
        else
            kept[#kept + 1] = request
        end
    end
    self.ordered = kept
end

-- A retrieval delivers to Pickup unless told otherwise. Crafting reuses this same
-- pipeline with the buffer as the destination, so there is one storage-withdrawal path
-- rather than two that can drift apart. Omitting options reproduces prior behaviour
-- exactly.
function Requests:create(identity, quantity, options)
    assert(type(identity) == "table" and type(identity.key) == "string",
        "exact item identity is required")
    assert(type(quantity) == "number" and quantity >= 1 and quantity % 1 == 0,
        "request quantity must be a positive integer")
    options = options or {}
    self.counter = self.counter + 1
    local request = {
        id=self.idGenerator(self.counter), kind="request", state="QUEUED",
        identity=copy(identity), requested=quantity, delivered=0, moved=0,
        display_name=identity.display_name or identity.name,
        destination_role=options.destination_role or "pickup", owner=options.owner,
        attempts=0, created_at=self.clock(), updated_at=self.clock(),
    }
    self.ordered[#self.ordered + 1] = request
    self.byId[request.id] = request
    -- Usage stats rank search results by what people ask for. A recipe consuming an
    -- ingredient is not a person asking for it, so craft-owned requests are excluded.
    -- Stats are a re-learnable cache, not core correctness, so a failure here must
    -- never stop the request itself from being created.
    if self.recordUsage and not request.owner then
        pcall(self.recordUsage, identity.key, request.created_at)
    end
    return copy(request)
end

function Requests:get(id)
    return self.byId[id] and copy(self.byId[id]) or nil
end

function Requests:list()
    return copy(self.ordered)
end

function Requests:_next()
    for _, request in ipairs(self.ordered) do
        if not terminal[request.state] and request.state ~= "FAILED" then return request end
    end
    return nil
end

function Requests:_block(request, context, blockReason)
    request.reason = copy(blockReason or {code="BLOCKED",message="Request is blocked",retryable=true})
    request.blocked_generation = context.generation
    request.attempts = request.attempts + 1
    request.next_retry_at = (context.now or self.clock()) +
        math.min(60000, 1000 * (2 ^ math.min(request.attempts - 1, 6)))
    self:_state(request, "BLOCKED")
    self.alerts:set("request_blocked:" .. request.id, "warning", request.reason.message,
        {request_id=request.id,code=request.reason.code})
end

function Requests:cancel(id)
    local request = self.byId[id]
    if not request or terminal[request.state] then return nil, "request cannot be cancelled" end
    if request.state == "TRANSFERRING" or request.state == "VERIFYING" then
        request.cancel_requested = true
        request.updated_at = self.clock()
        return true
    end
    self:_state(request, "CANCELLED")
    self.alerts:resolve("request_blocked:" .. request.id)
    return true
end

function Requests:retry(id)
    local request = self.byId[id]
    if not request or (request.state ~= "FAILED" and request.state ~= "BLOCKED" and
        request.state ~= "PARTIAL") then return nil, "request is not retryable" end
    request.reason = nil
    self:_state(request, "PLANNING")
    return true
end

function Requests:tick(context)
    context = context or {}
    local request = self:_next()
    if not request then return {state="IDLE"} end

    if request.state == "QUEUED" then
        self:_state(request, "PLANNING")
    elseif request.state == "PLANNING" then
        local remaining = request.requested - request.delivered
        local destination = context[request.destination_role or "pickup"]
        local plan, remainder, planReason = self.planner.planRetrieval(
            request.identity.key, remaining, context.index, destination)
        request.plan_remainder = remainder
        if #plan == 0 then
            self:_block(request, context, planReason)
        else
            -- One gate cycle per batch instead of per step, bounded so a single ambiguous
            -- window can never span an unbounded number of issued calls.
            request.steps = {}
            for index = 1, math.min(#plan, self.batchLimit) do
                request.steps[index] = copy(plan[index])
            end
            request.step = request.steps[1]
            request.reason = nil
            self:_state(request, "TRANSFERRING")
        end
    elseif request.state == "TRANSFERRING" then
        local result = self.transfer:executeMultiBatch(request, request.steps, context.storage or {})
        if result.state == "VERIFYING" then
            request.journal = result.journal
            request.pending_moved = result.moved
            request.rescan = copy(result.rescan)
            self:_state(request, "VERIFYING")
        elseif result.reason and (result.reason.code=="SOURCE_CHANGED" or result.reason.retryable) then
            request.rescan=copy(result.rescan)
            self:_block(request,context,result.reason)
        else
            request.reason = copy(result.reason)
            self:_state(request, "FAILED")
            self.alerts:set("request_failed:" .. request.id, "critical",
                request.reason.message, {request_id=request.id,code=request.reason.code})
        end
    elseif request.state == "VERIFYING" then
        local result = self.transfer:verify(request.journal, context.storage or {})
        if result.state == "WAITING" then
            request.rescan=copy(result.rescan)
            request.reason=copy(result.reason)
            if result.reason and result.reason.code=="RECONCILE_DIRECTION" then
                self.alerts:set("request_reconciliation:"..request.id,"critical",
                    "Storage changed opposite the request; review manual inventory changes",
                    {code="RECONCILE_DIRECTION",request_id=request.id})
            elseif result.reason and result.reason.code=="STORAGE_SCOPE_INCOMPLETE" then
                self.alerts:set("request_reconciliation:"..request.id,"warning",
                    "Request is waiting for every recorded storage node to come online",
                    {code="STORAGE_SCOPE_INCOMPLETE",request_id=request.id})
            end
        elseif result.state ~= "COMPLETE" then
            request.reason = copy(result.reason)
            self:_state(request, "FAILED")
            self.alerts:set("request_failed:" .. request.id, "critical",
                request.reason.message, {request_id=request.id,code=request.reason.code})
        else
            local stepLimit=0
            for _,planned in ipairs(request.steps or {request.step}) do
                stepLimit=stepLimit+planned.limit
            end
            request.delivered = request.delivered + result.moved
            request.moved = request.delivered
            request.reported_moved=result.reported_moved
            if result.moved>stepLimit then
                self.alerts:set("request_overdelivery:"..request.id,"critical",
                    "Storage moved "..result.moved.." items for a "..stepLimit.." item step",
                    {code="OVER_DELIVERY",requested=stepLimit,measured=result.moved,
                        reported=result.reported_moved,request_id=request.id})
            end
            request.step, request.steps = nil, nil
            request.journal, request.pending_moved, request.rescan = nil, nil, nil
            local callOk,retired,retireReason=pcall(self.transfer.retire,self.transfer)
            if not callOk then retired,retireReason=nil,retired end
            if not retired then self.alerts:set("journal_retire:"..request.id,"warning",
                "Completed transfer journal could not be retired: "..tostring(retireReason),
                {code="JOURNAL_RETIRE",request_id=request.id}) end
            request.reason=nil
            self.alerts:resolve("request_blocked:" .. request.id)
            self.alerts:resolve("request_failed:" .. request.id)
            self.alerts:resolve("request_reconciliation:" .. request.id)
            if request.cancel_requested then
                self:_state(request, "PARTIAL")
                self:_state(request, "CANCELLED")
            elseif request.delivered >= request.requested then
                self:_state(request, "COMPLETE")
            elseif result.moved <= 0 then
                -- Zero movement is a deliberate stop awaiting operator retry, whichever
                -- destination it was: `generation` advances on every scan and is never
                -- evidence that the destination drained.
                local full = {code="PICKUP_FULL",
                    message="Pickup accepted no items; make space and retry", retryable=true}
                if request.destination_role == "craft_buffer" then
                    full = {code="BUFFER_FULL",
                        message="Craft buffer accepted no items; clear it and retry",
                        retryable=true}
                end
                self:_block(request, context, full)
            else
                self:_state(request, "PARTIAL")
            end
        end
    elseif request.state == "PARTIAL" then
        self:_state(request, "PLANNING")
    elseif request.state == "BLOCKED" then
        -- A full destination never auto-retries, whichever destination it was.
        local code = request.reason and request.reason.code
        if code ~= "PICKUP_FULL" and code ~= "BUFFER_FULL" then
            local generationChanged = context.generation ~= request.blocked_generation
            local retryDue = (context.now or self.clock()) >= request.next_retry_at
            if generationChanged or retryDue then self:_state(request, "PLANNING") end
        end
    end
    return copy(request)
end

return Requests
