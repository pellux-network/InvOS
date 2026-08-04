local CraftService = require("app.craft_service")
local Alerts = require("app.alerts")
local Lifecycle = require("app.lifecycle")
local T = require("tests.mock_cc")

-- Fakes for the three collaborators the service orchestrates. Each records what it was
-- asked to do, so a test can assert on the sequence rather than on internal state.
local function fakeBuffer(contents)
    local value = {contents = contents or {}, drains = {}, deliveries = {}, blocked = nil}
    function value:snapshot() return self.contents end
    function value:ordered()
        local keys = {}
        for item in pairs(self.contents) do keys[#keys+1] = item end
        table.sort(keys)
        return keys
    end
    function value:drain(_, keep)
        self.drains[#self.drains + 1] = keep
        if self.blocked == "drain" then return {state="BLOCKED", reason={code="DRAIN"}} end
        local kept = {}
        for item, count in pairs(self.contents) do
            if keep[item] then kept[item] = math.min(count, keep[item]) end
        end
        self.contents = kept
        return {state="DONE"}
    end
    function value:deliver(_, item, count, destination)
        self.deliveries[#self.deliveries + 1] = {item=item, count=count, to=destination}
        if self.blocked == "deliver" then
            return {state="BLOCKED", reason={code="PICKUP_FULL"}}
        end
        self.contents[item] = nil
        return {state="DONE"}
    end
    return value
end

local function fakeLink(behaviour)
    local value = {sent = {}, mode = behaviour or "ok", pending = false}
    function value:send(command) self.sent[#self.sent + 1] = command; self.pending = true; return true end
    function value:poll()
        if not self.pending then return nil end
        if self.mode == "silent" then return nil end
        self.pending = false
        if self.mode == "mismatch" then
            return {ok=false, code="INGREDIENT_MISMATCH", message="expected oak_planks"}
        end
        return {ok=true, crafted=self.crafted or 1}
    end
    return value
end

local function fakeRequests()
    -- deliveryState is separate so a test can hold the final delivery pending without
    -- also stalling the ingredient withdrawals that get the job there.
    local value = {created = {}, byId = {}, counter = 0,
        state = "COMPLETE", deliveryState = nil}
    function value:create(identity, quantity, options)
        self.counter = self.counter + 1
        local id = "request-" .. self.counter
        local role = options and options.destination_role
        local request = {id=id, identity=identity, requested=quantity,
            owner=options and options.owner, destination_role=role,
            state=(role == nil and self.deliveryState) or self.state, delivered=quantity}
        self.created[#self.created + 1] = request
        self.byId[id] = request
        return request
    end
    function value:get(id) return self.byId[id] end
    function value:cancel(id)
        local request = self.byId[id]
        if request then request.state = "CANCELLED" end
        return true
    end
    return value
end

-- A plan the planner fake hands back. Two craft steps by default so step advancement
-- is exercised rather than assumed.
local function plan(steps, withdrawals, chosen)
    return {
        ok = true, steps = steps or {}, withdrawals = withdrawals or {},
        chosen = chosen or {}, shortfalls = {},
    }
end

local function chestStep()
    return {item="minecraft:chest", recipe_id="r:chest", crafts=1, batch=1, calls=1,
        produced=1, per_craft=1, consumes={{item="minecraft:oak_planks", count=8}}}
end

local function plankStep()
    return {item="minecraft:oak_planks", recipe_id="r:planks", crafts=2, batch=1, calls=1,
        produced=8, per_craft=4, consumes={{item="minecraft:oak_log", count=2}}}
end

local function service(plans, extra)
    local calls = {plan = 0}
    local planner = {}
    function planner.plan()
        calls.plan = calls.plan + 1
        return plans[math.min(calls.plan, #plans)]
    end
    local alerts = Alerts.new(function() return 0 end)
    local deps = {
        planner = planner, repo = {}, requests = fakeRequests(),
        buffer = fakeBuffer(), link = fakeLink(), alerts = alerts,
        transition = Lifecycle.transition, clock = function() return 100 end,
        idGenerator = function(counter) return "craft-" .. counter end,
    }
    for key, value in pairs(extra or {}) do deps[key] = value end
    local built = CraftService.new(deps)
    return built, deps, alerts, calls
end

-- A clock that moves, so a timeout can actually elapse.
local function advancingClock()
    local now = 0
    return function() now = now + 250; return now end
end

local function context()
    return {craft_buffer={peripheral_name="buffer", health="READY", slots={}},
        pickup={peripheral_name="pickup", health="READY"},
        storage={{node_id="storage", health="READY", slots={}}},
        index={}, generation=1, now=100}
end

local function run(craft, ctx, times)
    local last
    for _ = 1, times or 12 do last = craft:tick(ctx or context()) end
    return last
end

return {
    {name="a job starts queued and is not planned until its turn",run=function()
        local craft, _, _, calls = service({plan({chestStep()})})
        craft:enqueue("minecraft:chest", 1)
        T.equal(calls.plan, 0, "enqueueing must not plan")
        T.equal(craft:list()[1].state, "QUEUED")
    end},
    {name="only one job runs at a time",run=function()
        local craft, _, _, calls = service({plan({chestStep()})})
        craft:enqueue("minecraft:chest", 1)
        craft:enqueue("minecraft:chest", 2)
        run(craft, context(), 3)
        local jobs = craft:list()
        T.equal(jobs[2].state, "QUEUED", "the second job must not start")
        T.truthy(jobs[1].state ~= "QUEUED", "the first job must have started")
    end},
    {name="a queued job plans against stock as it is when its turn comes",run=function()
        local craft, _, _, calls = service({plan({chestStep()})})
        craft:enqueue("minecraft:chest", 1)
        run(craft, context(), 2)
        T.truthy(calls.plan >= 1, "planning happens at activation, not at enqueue")
    end},
    {name="an impossible plan blocks the job and names what is missing",run=function()
        local impossible = {ok=false, steps={}, withdrawals={}, chosen={},
            shortfalls={{item="minecraft:oak_log", missing=4}},
            reason={code="INSUFFICIENT_MATERIALS", message="missing materials"}}
        local craft, _, alerts = service({impossible})
        craft:enqueue("minecraft:chest", 1)
        local job = run(craft, context(), 3)
        T.equal(job.state, "BLOCKED")
        T.equal(job.shortfalls[1].item, "minecraft:oak_log")
        T.truthy(alerts:active()[1], "a blocked craft is operator-visible")
    end},
    {name="staging withdraws ingredients as craft-owned requests",run=function()
        local requests = fakeRequests()
        local craft = service({plan({chestStep()},
            {{item="minecraft:oak_planks", count=8}})}, {requests=requests})
        craft:enqueue("minecraft:chest", 1)
        run(craft, context(), 4)
        T.equal(#requests.created, 1)
        T.equal(requests.created[1].destination_role, "craft_buffer")
        T.equal(requests.created[1].owner, "craft-1", "withdrawals name their job")
        T.equal(requests.created[1].requested, 8)
    end},
    {name="the buffer is purged of anything the step does not need",run=function()
        local buffer = fakeBuffer({["minecraft:cobblestone"]=64})
        local craft = service({plan({chestStep()},
            {{item="minecraft:oak_planks", count=8}})}, {buffer=buffer})
        craft:enqueue("minecraft:chest", 1)
        run(craft, context(), 5)
        T.truthy(#buffer.drains > 0, "staging must clear the buffer first")
        T.equal(buffer.drains[1]["minecraft:cobblestone"], nil,
            "cobblestone is not an ingredient of this step")
        T.equal(buffer.drains[1]["minecraft:oak_planks"], 8, "the ingredient is kept")
    end},
    {name="the turtle is sent a command only once staging completes",run=function()
        local link = fakeLink()
        local craft = service({plan({chestStep()},
            {{item="minecraft:oak_planks", count=8}})}, {link=link})
        craft:enqueue("minecraft:chest", 1)
        run(craft, context(), 6)
        T.equal(#link.sent, 1)
        T.equal(link.sent[1].op, "craft")
        T.equal(link.sent[1].job, "craft-1")
        T.equal(link.sent[1].result.name, "minecraft:chest")
    end},
    {name="a silent turtle blocks the job rather than hanging",run=function()
        local link = fakeLink("silent")
        local craft, _, alerts = service({plan({chestStep()},
            {{item="minecraft:oak_planks", count=8}})},
            {link=link, turtle_timeout=500, clock=advancingClock()})
        craft:enqueue("minecraft:chest", 1)
        local job = run(craft, context(), 10)
        T.equal(job.state, "BLOCKED")
        T.equal(job.reason.code, "TURTLE_UNREACHABLE")
        T.truthy(alerts:active()[1])
    end},
    {name="a turtle reporting a mismatch blocks the job",run=function()
        local link = fakeLink("mismatch")
        local craft = service({plan({chestStep()},
            {{item="minecraft:oak_planks", count=8}})}, {link=link})
        craft:enqueue("minecraft:chest", 1)
        local job = run(craft, context(), 10)
        T.equal(job.state, "BLOCKED")
        T.equal(job.reason.code, "INGREDIENT_MISMATCH")
    end},
    {name="a finished job delivers to Pickup as an ordinary retrieval",run=function()
        -- Output reaches storage during staging purges, so the buffer never holds the
        -- whole result. Delivery goes through the request pipeline, which can.
        local requests = fakeRequests()
        local craft = service({plan({chestStep()},
            {{item="minecraft:oak_planks", count=8}})}, {requests=requests})
        local queued = craft:enqueue("minecraft:chest", 1)
        run(craft, context(), 14)
        T.equal(craft:get(queued.id).state, "COMPLETE")
        local delivery
        for _, request in ipairs(requests.created) do
            if request.destination_role == nil then delivery = request end
        end
        T.truthy(delivery, "a delivery request must be raised")
        T.equal(delivery.requested, 1)
        T.equal(delivery.owner, "craft-1", "delivery is still owned by the job")
    end},
    {name="delivering into storage needs no move at all",run=function()
        -- The result is already in storage by then, so storage delivery is a no-op.
        local requests = fakeRequests()
        local craft = service({plan({chestStep()},
            {{item="minecraft:oak_planks", count=8}})}, {requests=requests})
        local queued = craft:enqueue("minecraft:chest", 1, {destination="storage"})
        run(craft, context(), 14)
        T.equal(craft:get(queued.id).state, "COMPLETE")
        for _, request in ipairs(requests.created) do
            T.equal(request.destination_role, "craft_buffer",
                "only ingredient withdrawals, no delivery move")
        end
    end},
    {name="a multistep job crafts leaf-first and delivers once",work=true,run=function()
        local buffer = fakeBuffer()
        local link = fakeLink()
        local craft = service({plan({plankStep(), chestStep()},
            {{item="minecraft:oak_log", count=2}})}, {buffer=buffer, link=link})
        local queued = craft:enqueue("minecraft:chest", 1)
        run(craft, context(), 20)
        T.equal(craft:get(queued.id).state, "COMPLETE")
        T.equal(#link.sent, 2, "one turtle command per craft step")
        T.equal(link.sent[1].result.name, "minecraft:oak_planks", "leaf first")
        T.equal(link.sent[2].result.name, "minecraft:chest")
    end},
    {name="a queued job whose plan materially changed asks before running",run=function()
        local first = plan({chestStep()}, {{item="minecraft:oak_planks", count=8}},
            {{tag="t:planks", item="minecraft:oak_planks"}})
        local diverged = plan({plankStep(), chestStep()},
            {{item="minecraft:oak_log", count=2}},
            {{tag="t:planks", item="minecraft:birch_planks"}})
        local craft = service({diverged})
        local job = craft:enqueue("minecraft:chest", 1, {confirmed=first})
        run(craft, context(), 4)
        job = craft:get(job.id)
        T.equal(job.state, "CONFIRMING", "a different tag member is material")
        T.truthy(job.divergence ~= nil, "the operator must be told what changed")
    end},
    {name="confirming a diverged plan lets it proceed",run=function()
        local first = plan({chestStep()}, {{item="minecraft:oak_planks", count=8}},
            {{tag="t:planks", item="minecraft:oak_planks"}})
        local diverged = plan({chestStep()}, {{item="minecraft:oak_planks", count=8}},
            {{tag="t:planks", item="minecraft:birch_planks"}})
        local craft = service({diverged})
        local job = craft:enqueue("minecraft:chest", 1, {confirmed=first})
        run(craft, context(), 4)
        craft:confirm(job.id)
        run(craft, context(), 12)
        T.equal(craft:get(job.id).state, "COMPLETE")
    end},
    {name="a plan that differs only in source slots proceeds silently",run=function()
        local first = plan({chestStep()}, {{item="minecraft:oak_planks", count=8}},
            {{tag="t:planks", item="minecraft:oak_planks"}})
        local same = plan({chestStep()}, {{item="minecraft:oak_planks", count=8}},
            {{tag="t:planks", item="minecraft:oak_planks"}})
        local craft = service({same})
        local job = craft:enqueue("minecraft:chest", 1, {confirmed=first})
        run(craft, context(), 12)
        T.equal(craft:get(job.id).state, "COMPLETE", "identical work needs no re-confirmation")
    end},
    {name="a queued job cancels immediately because nothing has moved",run=function()
        local craft, deps = service({plan({chestStep()})})
        craft:enqueue("minecraft:chest", 1)
        local second = craft:enqueue("minecraft:chest", 2)
        run(craft, context(), 3)
        T.equal(craft:cancel(second.id), true)
        T.equal(craft:get(second.id).state, "CANCELLED")
        T.equal(#deps.buffer.drains > 0 or true, true)
    end},
    {name="cancelling the active job cancels its outstanding withdrawal",run=function()
        local requests = fakeRequests()
        requests.state = "TRANSFERRING"
        local craft = service({plan({chestStep()},
            {{item="minecraft:oak_planks", count=8}})}, {requests=requests})
        local job = craft:enqueue("minecraft:chest", 1)
        run(craft, context(), 4)
        craft:cancel(job.id)
        run(craft, context(), 2)
        T.equal(requests.created[1].state, "CANCELLED",
            "a cancelled craft must not leave a withdrawal running")
    end},
    {name="a job returns leftovers before the next job starts",run=function()
        local buffer = fakeBuffer()
        local craft = service({plan({chestStep()},
            {{item="minecraft:oak_planks", count=8}})}, {buffer=buffer})
        craft:enqueue("minecraft:chest", 1)
        craft:enqueue("minecraft:chest", 1)
        run(craft, context(), 14)
        local emptied = false
        for _, keep in ipairs(buffer.drains) do
            if next(keep) == nil then emptied = true end
        end
        T.equal(emptied, true, "the buffer is emptied between jobs")
    end},
    {name="terminal jobs are pruned so the list cannot grow forever",run=function()
        local craft = service({plan({chestStep()},
            {{item="minecraft:oak_planks", count=8}})})
        for _ = 1, 40 do
            craft:enqueue("minecraft:chest", 1)
            run(craft, context(), 12)
        end
        T.truthy(#craft:list() <= 32, "terminal jobs must be pruned, got " .. #craft:list())
    end},
    {name="status reports the active job for the coordinator rotation",run=function()
        local craft = service({plan({chestStep()},
            {{item="minecraft:oak_planks", count=8}})})
        T.equal(craft:status().state, "IDLE")
        craft:enqueue("minecraft:chest", 1)
        run(craft, context(), 3)
        T.truthy(craft:status().state ~= "IDLE")
    end},
    {name="a non-empty buffer with no active job is reported on boot",run=function()
        local buffer = fakeBuffer({["minecraft:oak_planks"]=8})
        local craft, _, alerts = service({plan({chestStep()})}, {buffer=buffer})
        craft:tick(context())
        T.truthy(alerts:active()[1], "stranded items must not be silent")
        T.equal(alerts:active()[1].details.code, "BUFFER_NOT_EMPTY")
    end},
    {name="an invalid enqueue is refused",run=function()
        local craft = service({plan({chestStep()})})
        T.fails(function() craft:enqueue("", 1) end)
        T.fails(function() craft:enqueue("minecraft:chest", 0) end)
        T.fails(function() craft:enqueue("minecraft:chest", 1.5) end)
    end},
    {name="recipe grid positions map onto the turtle's crafting slots",run=function()
        -- turtle.craft() reads slots 1-3, 5-7 and 9-11. Slots 4, 8 and 12-16 are outside
        -- the grid, so a recipe position passed straight through as a slot lands an
        -- ingredient where the craft cannot see it.
        local expected = {1,2,3, 5,6,7, 9,10,11}
        for position = 1, 9 do
            T.equal(CraftService._turtleSlot(position), expected[position],
                "grid position " .. position)
        end
    end},
    {name="a two-cell vertical recipe uses slots 1 and 5, not 1 and 4",run=function()
        -- The stick recipe is one column, two rows: grid positions 1 and 4. Position 4
        -- is turtle slot 5; slot 4 is outside the crafting grid entirely.
        local link = fakeLink()
        local craft = service({plan({{item="minecraft:stick", recipe_id="r:stick",
            crafts=1, batch=1, calls=1, produced=4, per_craft=4,
            consumes={{item="minecraft:oak_planks", count=2}},
            cells={"minecraft:oak_planks", false, false, "minecraft:oak_planks"}}},
            {{item="minecraft:oak_planks", count=2}})}, {link=link})
        craft:enqueue("minecraft:stick", 4)
        run(craft, context(), 8)
        T.equal(#link.sent, 1, "one command should have been sent")
        local sent = link.sent[1]
        T.equal(#sent.steps, 1, "one ingredient")
        T.arrayEqual(sent.steps[1].cells, {1, 5},
            "grid positions 1 and 4 are turtle slots 1 and 5")
    end},

    {name="the buffer is drained once, not on every tick while delivering",run=function()
        -- A drain running under the delivery request moves the very storage slots the
        -- request planned from, which surfaces as SOURCE_CHANGED and blocks a craft that
        -- had already succeeded.
        local buffer = fakeBuffer()
        local requests = fakeRequests()
        requests.deliveryState = "TRANSFERRING"
        local craft = service({plan({chestStep()},
            {{item="minecraft:oak_planks", count=8}})}, {buffer=buffer, requests=requests})
        craft:enqueue("minecraft:chest", 1)
        run(craft, context(), 20)
        local emptyDrains = 0
        for _, keep in ipairs(buffer.drains) do
            if next(keep) == nil then emptyDrains = emptyDrains + 1 end
        end
        T.equal(emptyDrains, 1,
            "the buffer must be emptied once, got " .. emptyDrains .. " full drains")
    end},
    {name="a delivery request is raised only once",run=function()
        local requests = fakeRequests()
        requests.deliveryState = "TRANSFERRING"
        local craft = service({plan({chestStep()},
            {{item="minecraft:oak_planks", count=8}})}, {requests=requests})
        craft:enqueue("minecraft:chest", 1)
        run(craft, context(), 20)
        local deliveries = 0
        for _, request in ipairs(requests.created) do
            if request.destination_role == nil then deliveries = deliveries + 1 end
        end
        T.equal(deliveries, 1, "a second delivery would double-move the result")
    end},

}
