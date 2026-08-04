local Identity = require("core.identity")

local CraftService = {}
CraftService.__index = CraftService

local TERMINAL = {COMPLETE=true, CANCELLED=true, FAILED=true}
local TERMINAL_LIMIT = 30
local DEFAULT_TURTLE_TIMEOUT = 10000

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

function CraftService.new(deps)
    assert(type(deps) == "table", "craft dependencies are required")
    return setmetatable({
        planner=assert(deps.planner, "craft planner is required"),
        repo=assert(deps.repo, "recipe repo is required"),
        requests=assert(deps.requests, "request service is required"),
        buffer=assert(deps.buffer, "craft buffer is required"),
        link=assert(deps.link, "turtle link is required"),
        alerts=assert(deps.alerts, "alerts service is required"),
        transition=assert(deps.transition, "transition function is required"),
        clock=assert(deps.clock, "craft clock is required"),
        idGenerator=assert(deps.idGenerator, "craft ID generator is required"),
        prefs=deps.prefs,
        stackLimit=deps.stack_limit or function() return 64 end,
        turtleTimeout=deps.turtle_timeout or DEFAULT_TURTLE_TIMEOUT,
        counter=0, ordered={}, byId={}, strandedReported=false,
    }, CraftService)
end

function CraftService:_state(job, to)
    local ok, reason = self.transition("craft", job.state, to)
    if not ok then error(reason, 2) end
    job.state = to
    job.updated_at = self.clock()
    if TERMINAL[to] then self:_prune() end
end

-- Terminal jobs accumulate forever otherwise, and every redraw pays to deep-copy the
-- list. Non-terminal jobs are never dropped no matter how old: they still need either
-- automation or an operator.
function CraftService:_prune()
    local terminalCount = 0
    for _, job in ipairs(self.ordered) do
        if TERMINAL[job.state] then terminalCount = terminalCount + 1 end
    end
    local excess = terminalCount - TERMINAL_LIMIT
    if excess <= 0 then return end
    local kept = {}
    for _, job in ipairs(self.ordered) do
        if excess > 0 and TERMINAL[job.state] then
            self.byId[job.id] = nil
            excess = excess - 1
        else
            kept[#kept + 1] = job
        end
    end
    self.ordered = kept
end

function CraftService:enqueue(itemId, quantity, options)
    assert(type(itemId) == "string" and itemId ~= "", "a craft needs an item")
    assert(type(quantity) == "number" and quantity >= 1 and quantity % 1 == 0,
        "craft quantity must be a positive integer")
    options = options or {}
    self.counter = self.counter + 1
    local job = {
        id=self.idGenerator(self.counter), kind="craft", state="QUEUED",
        item=itemId, quantity=quantity,
        destination=options.destination == "storage" and "storage" or "pickup",
        confirmed=copy(options.confirmed), step_index=0, requests={},
        created_at=self.clock(), updated_at=self.clock(),
    }
    self.ordered[#self.ordered + 1] = job
    self.byId[job.id] = job
    return copy(job)
end

function CraftService:get(id) return self.byId[id] and copy(self.byId[id]) or nil end
function CraftService:list() return copy(self.ordered) end

-- Exactly one job runs at a time. There is one buffer and one turtle, so two concurrent
-- jobs would interleave ingredients in the same chest and break the invariant that the
-- buffer holds exactly the active step's ingredients.
function CraftService:_active()
    for _, job in ipairs(self.ordered) do
        if not TERMINAL[job.state] then return job end
    end
    return nil
end

function CraftService:status()
    local job = self:_active()
    if not job then return {state="IDLE"} end
    return {state=job.state, job_id=job.id, item=job.item}
end

function CraftService:_block(job, reason)
    job.reason = copy(reason)
    self:_state(job, "BLOCKED")
    self.alerts:set("craft_blocked:" .. job.id, "warning", reason.message,
        {job_id=job.id, code=reason.code})
end

function CraftService:_cancelRequests(job)
    for _, id in ipairs(job.requests) do pcall(self.requests.cancel, self.requests, id) end
    job.requests = {}
end

function CraftService:cancel(id)
    local job = self.byId[id]
    if not job or TERMINAL[job.state] then return nil, "job cannot be cancelled" end
    self:_cancelRequests(job)
    if job.state == "QUEUED" or job.state == "CONFIRMING" or job.state == "BLOCKED" then
        -- Nothing has moved for a queued job, and a blocked one has already stopped.
        self:_state(job, "CANCELLED")
        self.alerts:resolve("craft_blocked:" .. job.id)
        return true
    end
    job.cancel_requested = true
    job.updated_at = self.clock()
    return true
end

function CraftService:confirm(id)
    local job = self.byId[id]
    if not job or job.state ~= "CONFIRMING" then return nil, "job is not awaiting confirmation" end
    job.confirmed = copy(job.plan)
    job.divergence = nil
    self:_state(job, "PLANNING")
    return true
end

function CraftService:retry(id)
    local job = self.byId[id]
    if not job or (job.state ~= "BLOCKED" and job.state ~= "FAILED") then
        return nil, "job is not retryable"
    end
    job.reason, job.shortfalls = nil, nil
    self.alerts:resolve("craft_blocked:" .. job.id)
    self:_state(job, "PLANNING")
    return true
end

function CraftService:_planContext(context)
    local index = context.index
    return {
        repo = self.repo, prefs = self.prefs, stack_limit = self.stackLimit,
        available = function(itemId)
            if not index or type(index.quantity) ~= "function" then return 0 end
            local ok, quantity = pcall(index.quantity, index, Identity.key(itemId, nil))
            if not ok or type(quantity) ~= "number" then return 0 end
            return quantity
        end,
    }
end

-- Two plans differ materially when they would consume different things or do different
-- work: a different concrete item for a tag, or a different set of craft steps. Drawing
-- the same items from different storage slots is not material.
local function divergence(confirmed, fresh)
    if not confirmed then return nil end
    local before = {}
    for _, entry in ipairs(confirmed.chosen or {}) do before[entry.tag] = entry.item end
    for _, entry in ipairs(fresh.chosen or {}) do
        if before[entry.tag] ~= entry.item then
            return {code="TAG_CHANGED", tag=entry.tag,
                was=before[entry.tag], now=entry.item,
                message="Ingredient choice changed for " .. entry.tag}
        end
    end
    local previous = {}
    for _, step in ipairs(confirmed.steps or {}) do previous[step.item] = true end
    for _, step in ipairs(fresh.steps or {}) do
        if not previous[step.item] then
            return {code="STEP_ADDED", item=step.item,
                message="Now also needs to craft " .. step.item}
        end
    end
    if #(fresh.steps or {}) ~= #(confirmed.steps or {}) then
        return {code="STEPS_CHANGED", message="The craft steps changed"}
    end
    return nil
end

local function requiredFor(step)
    local required = {}
    for _, entry in ipairs(step.consumes or {}) do
        required[entry.item] = (required[entry.item] or 0) + entry.count
    end
    return required
end

-- A recipe's cells are 3x3 positions 1-9. A turtle's crafting grid is inventory slots
-- 1-3, 5-7 and 9-11, because slots 4, 8 and 12-16 sit outside it. Only positions 1-3
-- map to themselves, so passing a position straight through as a slot puts most of a
-- recipe in the wrong place -- and anything landing in slot 4, 8 or 12+ is not in the
-- grid at all, so turtle.craft() sees an incomplete recipe and refuses.
local function turtleSlot(position)
    local row = math.floor((position - 1) / 3)
    local column = (position - 1) % 3
    return row * 4 + column + 1
end

-- Group the resolved cells by item, in the order the cells appear.
--
-- per_cell is how many crafts THIS call performs, not the step's maximum batch. Every
-- vanilla grid cell consumes exactly one item per craft, so a call that crafts 2 needs 2
-- items per cell. Sending the maximum instead told the turtle to stage 64 logs for a
-- two-craft step, which it could not satisfy.
local function turtleSteps(step, runs)
    local order, byItem = {}, {}
    for position, itemId in ipairs(step.cells or {}) do
        if itemId then
            if not byItem[itemId] then
                byItem[itemId] = {expect=itemId, cells={}, per_cell=runs}
                order[#order + 1] = byItem[itemId]
            end
            local target = byItem[itemId].cells
            target[#target + 1] = turtleSlot(position)
        end
    end
    return order
end

CraftService._turtleSlot = turtleSlot

function CraftService:_advancePlanning(job, context)
    -- Between steps the plan is already resolved; re-planning here would restart the
    -- whole tree and lose the steps already crafted.
    if job.plan and job.step_index >= 1 and job.step_index <= #job.plan.steps then
        self:_state(job, "STAGING")
        return
    end
    local ok, plan = pcall(self.planner.plan,
        {item=job.item, quantity=job.quantity}, self:_planContext(context))
    if not ok then
        self:_block(job, {code="PLAN_FAILED", message="Craft planning failed: " .. tostring(plan)})
        return
    end
    if not plan.ok then
        job.shortfalls = copy(plan.shortfalls)
        self:_block(job, plan.reason or
            {code="INSUFFICIENT_MATERIALS", message="Materials are missing"})
        return
    end
    if #plan.steps == 0 then
        self:_block(job, {code="NOTHING_TO_CRAFT",
            message="Stock already covers this; retrieve it instead"})
        return
    end
    local changed = divergence(job.confirmed, plan)
    if changed then
        job.plan, job.divergence = plan, changed
        self:_state(job, "CONFIRMING")
        return
    end
    job.plan, job.step_index, job.divergence = plan, 1, nil
    self:_state(job, "STAGING")
end

function CraftService:_advanceStaging(job, context)
    local step = job.plan.steps[job.step_index]
    local required = requiredFor(step)

    -- Purge first: anything in the buffer this step does not need goes back to storage,
    -- so the invariant below can hold even when a previous step left an intermediate.
    local drained = self.buffer:drain(context, required)
    if drained.state == "BLOCKED" then
        self:_block(job, drained.reason or {code="DRAIN_FAILED", message="Could not clear the buffer"})
        return
    end
    if drained.state ~= "DONE" then return end

    local held = self.buffer:snapshot(context) or {}
    if not job.staged then
        job.requests = {}
        for _, entry in ipairs(step.consumes or {}) do
            local deficit = entry.count - (held[entry.item] or 0)
            if deficit > 0 then
                local created = self.requests:create({key=Identity.key(entry.item, nil),
                    name=entry.item, display_name=entry.item}, deficit,
                    {destination_role="craft_buffer", owner=job.id})
                job.requests[#job.requests + 1] = created.id
            end
        end
        job.staged = true
        return
    end

    for _, id in ipairs(job.requests) do
        local request = self.requests:get(id)
        if not request then
            self:_block(job, {code="WITHDRAWAL_LOST", message="An ingredient withdrawal vanished"})
            return
        end
        if request.state == "FAILED" or request.state == "CANCELLED" then
            self:_block(job, {code="WITHDRAWAL_FAILED",
                message="An ingredient withdrawal did not complete"})
            return
        end
        if request.state ~= "COMPLETE" then return end
    end

    -- AGENTS.md: when a design argues a bad state cannot arise, assert it anyway. If the
    -- buffer holds anything beyond this step's ingredients, the turtle's suck order no
    -- longer matches what the controller observed and it would craft the wrong thing.
    local contents = self.buffer:snapshot(context) or {}
    for itemId in pairs(contents) do
        assert(required[itemId], "craft buffer holds " .. tostring(itemId) ..
            " which step " .. tostring(job.step_index) .. " does not use")
    end

    job.staged = nil
    self:_state(job, "CRAFTING")
end

-- One turtle command per step: the planner splits a large craft into one step per call,
-- so each command is preceded by its own staging and the buffer holds exactly that
-- call's ingredients when it runs.
function CraftService:_advanceCrafting(job, context)
    local step = job.plan.steps[job.step_index]
    if not job.sent_at then
        local command = {
            op="craft", job=job.id, steps=turtleSteps(step, step.crafts),
            result={name=step.item, count=step.produced},
        }
        local sent = self.link:send(command)
        if not sent then
            self:_block(job, {code="TURTLE_UNREACHABLE",
                message="The crafting turtle did not accept the job"})
            return
        end
        job.sent_at = self.clock()
        return
    end

    local reply = self.link:poll()
    if not reply then
        if (self.clock() - job.sent_at) > self.turtleTimeout then
            job.sent_at = nil
            self:_block(job, {code="TURTLE_UNREACHABLE",
                message="The crafting turtle stopped responding"})
        end
        return
    end
    job.sent_at = nil
    if not reply.ok then
        self:_block(job, {code=reply.code or "CRAFT_FAILED",
            message=reply.message or "The turtle could not complete the craft"})
        return
    end
    self:_state(job, "COLLECTING")
end

function CraftService:_advanceCollecting(job)
    job.step_index = job.step_index + 1
    if job.step_index > #job.plan.steps then
        self:_state(job, "DELIVERING")
    else
        self:_state(job, "PLANNING")
    end
end

-- The result does not sit waiting in the buffer. Each step's staging purges whatever the
-- next call does not need, so output produced by an earlier call is already in storage by
-- the time the last call runs. Delivery therefore empties the buffer first and then, if
-- the operator wants it in Pickup, moves it there as an ordinary retrieval -- the same
-- pipeline any other request uses, and the only one that can see the whole amount.
function CraftService:_advanceDelivering(job, context)
    -- Drained once, not on every tick. The delivery request plans against a storage
    -- snapshot and then executes against live inventories; a drain running underneath it
    -- moves the very slots it planned from, which surfaces as SOURCE_CHANGED and blocks
    -- a craft that had already succeeded.
    if not job.buffer_cleared then
        local cleared = self.buffer:drain(context, {})
        if cleared.state == "BLOCKED" then
            self:_block(job, cleared.reason or
                {code="DRAIN_FAILED", message="The buffer could not be emptied to storage"})
            return
        end
        if cleared.state ~= "DONE" then return end
        job.buffer_cleared = true
        -- Return without creating the request, so the storage rescan that the request's
        -- own planning gate forces happens after the output has landed.
        return
    end

    if job.destination == "storage" then
        self.alerts:resolve("craft_blocked:" .. job.id)
        self:_state(job, "COMPLETE")
        return
    end

    if not job.delivery_request then
        local created = self.requests:create({key=Identity.key(job.item, nil),
            name=job.item, display_name=job.item}, job.quantity,
            {owner=job.id})
        job.delivery_request = created.id
        return
    end
    local request = self.requests:get(job.delivery_request)
    if not request then
        self:_block(job, {code="DELIVERY_LOST", message="The delivery request vanished"})
        return
    end
    if request.state == "FAILED" or request.state == "CANCELLED" then
        self:_block(job, {code="DELIVERY_FAILED",
            message="The result could not be delivered to Pickup"})
        return
    end
    if request.state ~= "COMPLETE" then return end
    self.alerts:resolve("craft_blocked:" .. job.id)
    self:_state(job, "COMPLETE")
end

function CraftService:tick(context)
    context = context or {}
    local job = self:_active()
    if not job then
        -- Nothing is running, so anything in the buffer is stranded: an interrupted job
        -- from before a restart, since craft jobs are deliberately not durable.
        local contents = self.buffer:snapshot(context)
        if contents and next(contents) ~= nil then
            if not self.strandedReported then
                self.alerts:set("craft_buffer_stranded", "warning",
                    "The craft buffer holds items with no active job; return them to storage",
                    {code="BUFFER_NOT_EMPTY"})
                self.strandedReported = true
            end
        elseif self.strandedReported then
            self.alerts:resolve("craft_buffer_stranded")
            self.strandedReported = false
        end
        return {state="IDLE"}
    end

    if job.cancel_requested and job.state ~= "CRAFTING" then
        self:_cancelRequests(job)
        self.buffer:drain(context, {})
        self:_state(job, "CANCELLED")
        return copy(job)
    end

    if job.state == "QUEUED" then self:_state(job, "PLANNING")
    elseif job.state == "PLANNING" then self:_advancePlanning(job, context)
    elseif job.state == "STAGING" then self:_advanceStaging(job, context)
    elseif job.state == "CRAFTING" then self:_advanceCrafting(job, context)
    elseif job.state == "COLLECTING" then self:_advanceCollecting(job)
    elseif job.state == "DELIVERING" then self:_advanceDelivering(job, context)
    end
    return copy(job)
end

return CraftService
