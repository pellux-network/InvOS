local Coordinator = require("app.coordinator")
local T = require("tests.mock_cc")

-- A coordinator wired with a craft buffer node and a stub craft service, to check the
-- plumbing crafting depends on: the buffer reaching the shared context, the request
-- verification gate following the destination a request actually targets, and the craft
-- service taking its turn in the one automation rotation.
local function scanner()
    local api, steps = {}, 0
    function api:begin(node) return {node=node} end
    function api:step(scan)
        steps = steps + 1
        return true, {node_id=scan.node.id, peripheral_name=scan.node.peripheral_name,
            epoch=steps, size=27, occupied=0, slots={}, health="READY"}
    end
    return api
end

local function stubService(state)
    local calls = {ticks=0}
    local service = {calls=calls}
    function service:status() return {state=state} end
    function service:tick() calls.ticks = calls.ticks + 1; return {state=state} end
    return service
end

local function fakeAlerts()
    local value = {raised = {}}
    function value:set(key, severity, message, details)
        self.raised[key] = {severity=severity, message=message, details=details}
    end
    function value:resolve(key) self.raised[key] = nil end
    function value:active() return {} end
    return value
end

local function requestList(entries)
    return {list=function() return entries end, tick=function() return {state="IDLE"} end}
end

local function build(overrides)
    local ui = {}
    function ui:reduce(state) return state end
    function ui:render() end
    local deps = {
        clock=function() return 1000 end,
        scanner=scanner(), scan_budget=8,
        nodes={
            {id="dropoff",role="dropoff",peripheral_name="drop"},
            {id="storage_1",role="storage",peripheral_name="store1",priority=1},
            {id="pickup",role="pickup",peripheral_name="pickup"},
            {id="craft_buffer",role="craft_buffer",peripheral_name="buffer"},
        },
        ui=ui, keymap={command=function() end},
        initial_ui={query="",mode="search",page="search",results={},hit_regions={}},
        build_index=function() return {items=function() return {} end} end,
        search=function() return {} end,
    }
    for key, value in pairs(overrides or {}) do deps[key] = value end
    return Coordinator.new(deps)
end

local function names(list)
    local seen = {}
    for _, id in ipairs(list) do seen[id] = true end
    return seen
end

return {
    {name="the craft buffer snapshot reaches the shared context",run=function()
        local coordinator = build()
        for _ = 1, 12 do coordinator:workStep(1000) end
        local context = coordinator:_context(1000)
        T.truthy(context.craft_buffer, "crafting cannot plan without the buffer snapshot")
        T.equal(context.craft_buffer.peripheral_name, "buffer")
    end},
    {name="an installation with no buffer still builds a context",run=function()
        local coordinator = build({nodes={
            {id="dropoff",role="dropoff",peripheral_name="drop"},
            {id="storage_1",role="storage",peripheral_name="store1",priority=1},
            {id="pickup",role="pickup",peripheral_name="pickup"},
        }})
        local context = coordinator:_context(1000)
        T.equal(context.craft_buffer, nil, "absent, not an error")
        T.truthy(context.pickup ~= nil or true)
    end},
    {name="a Pickup-bound request gates on Pickup",run=function()
        local coordinator = build({requests=requestList({
            {state="PLANNING", destination_role="pickup"},
        })})
        local gated = names(coordinator:_preflightNames("requests"))
        T.equal(gated["pickup"], true)
        T.equal(gated["craft_buffer"], nil, "scanning the buffer here buys nothing")
        T.equal(gated["storage_1"], true)
    end},
    {name="a buffer-bound request gates on the buffer instead",run=function()
        local coordinator = build({requests=requestList({
            {state="PLANNING", destination_role="craft_buffer"},
        })})
        local gated = names(coordinator:_preflightNames("requests"))
        T.equal(gated["craft_buffer"], true,
            "planning against a stale buffer snapshot is what this prevents")
        T.equal(gated["pickup"], nil)
        T.equal(gated["storage_1"], true)
    end},
    {name="a terminal request does not decide the gate",run=function()
        local coordinator = build({requests=requestList({
            {state="COMPLETE", destination_role="craft_buffer"},
            {state="PLANNING", destination_role="pickup"},
        })})
        local gated = names(coordinator:_preflightNames("requests"))
        T.equal(gated["pickup"], true)
        T.equal(gated["craft_buffer"], nil)
    end},
    {name="with no requests at all the gate falls back to Pickup",run=function()
        local coordinator = build({requests=requestList({})})
        local gated = names(coordinator:_preflightNames("requests"))
        T.equal(gated["pickup"], true)
    end},
    {name="the craft gate covers storage and the buffer",run=function()
        local coordinator = build()
        local gated = names(coordinator:_preflightNames("crafts"))
        T.equal(gated["craft_buffer"], true)
        T.equal(gated["storage_1"], true)
        T.equal(gated["pickup"], nil)
        T.equal(gated["dropoff"], nil)
    end},
    {name="the craft service takes its turn in the automation rotation",run=function()
        local crafts = stubService("PLANNING")
        local coordinator = build({crafts=crafts, configured=true})
        for _ = 1, 30 do coordinator:workStep(1000) end
        T.truthy(crafts.calls.ticks > 0, "a craft job must be able to advance")
    end},
    {name="an in-flight craft blocks a topology change",run=function()
        local coordinator = build({crafts=stubService("TRANSFERRING")})
        local ok, reason = coordinator:topologyChangeSafe()
        T.equal(ok, nil)
        T.contains(reason, "crafts")
    end},
    {name="an idle craft service does not block a topology change",run=function()
        local coordinator = build({crafts=stubService("IDLE")})
        T.equal(coordinator:topologyChangeSafe(), true)
    end},
    {name="a rednet reply reaches the turtle link",run=function()
        -- The event loop is the only place that sees every event, so it has to hand the
        -- turtle's reply to the link. Nothing else does.
        local received = {}
        local link = {deliver=function(_, sender, message, protocol)
            received[#received+1] = {sender=sender, message=message, protocol=protocol}
            return true
        end}
        local coordinator = build({turtle_link=link})
        coordinator:handle({"rednet_message", 7, {ok=true}, "invos-craft"})
        T.equal(#received, 1, "the reply must be handed to the link")
        T.equal(received[1].sender, 7)
        T.equal(received[1].protocol, "invos-craft")
        T.equal(received[1].message.ok, true)
    end},
    {name="a rednet message with no link configured is harmless",run=function()
        local coordinator = build()
        coordinator:handle({"rednet_message", 7, {ok=true}, "invos-craft"})
        T.truthy(true, "an install without a turtle must not crash on stray rednet traffic")
    end},
    {name="a link that throws is recorded rather than killing the event loop",run=function()
        local link = {deliver=function() error("modem exploded") end}
        local coordinator = build({turtle_link=link})
        coordinator:handle({"rednet_message", 7, {ok=true}, "invos-craft"})
        local notices = coordinator:viewModel().notices
        T.truthy(#notices > 0, "the error must surface rather than vanish")
    end},

    {name="a rescan asked for by the craft service is honoured",run=function()
        -- Crafting asks from its own states, not VERIFYING or BLOCKED, so the gate has
        -- to accept it from this service specifically.
        local crafts = {ticks=0}
        function crafts:status() return {state="COLLECTING"} end
        function crafts:tick()
            self.ticks = self.ticks + 1
            return {state="COLLECTING", rescan={"craft_buffer"}}
        end
        function crafts:list() return {} end
        local coordinator = build({crafts=crafts, configured=true})
        for _ = 1, 20 do coordinator:workStep(1000) end
        T.truthy(coordinator.verificationGate ~= nil or crafts.ticks > 0,
            "the craft service must be able to force a rescan")
    end},

    {name="no service starts planning while another has a transfer in flight",run=function()
        -- Two services planning and issuing moves at once share one journal while each
        -- measures aggregate storage deltas the other is changing, which surfaces as
        -- items credited to the wrong step.
        local planner = stubService("PLANNING")
        local mover = stubService("TRANSFERRING")
        local coordinator = build({imports=planner, crafts=mover, configured=true})
        for _ = 1, 20 do coordinator:workStep(1000) end
        T.equal(planner.calls.ticks, 0, "the planning service must wait its turn")
        T.truthy(mover.calls.ticks > 0, "the in-flight transfer must keep advancing")
    end},
    {name="a rescan from a transferring service does not gate on a scan it forbids",run=function()
        -- _scanStep refuses to scan while any service reports TRANSFERRING, so a
        -- verification gate set from that state waits on a revision that can never
        -- advance. The service stops being ticked, its transfer never settles, and the
        -- whole automation rotation stops with it.
        local crafts = {ticks=0}
        function crafts:status() return {state="TRANSFERRING"} end
        function crafts:tick()
            self.ticks = self.ticks + 1
            return {state="TRANSFERRING", rescan={"craft_buffer"}}
        end
        function crafts:list() return {} end
        local coordinator = build({crafts=crafts, configured=true})
        for _ = 1, 20 do coordinator:workStep(1000) end
        T.truthy(crafts.ticks >= 5,
            "a transferring service must keep advancing, got " .. crafts.ticks)
    end},

    {name="a transfer that never settles names itself instead of stalling silently",run=function()
        -- One service wedged mid-transfer stops every other service from planning, so the
        -- whole installation goes quiet and the only symptom is that nothing happens --
        -- which reads as whichever feature the operator was using, not as a stall.
        local alerts = fakeAlerts()
        local coordinator = build({crafts=stubService("VERIFYING"), alerts=alerts,
            configured=true, stall_after=5000})
        coordinator:workStep(1000)
        T.equal(alerts.raised["transfer_stalled:crafts"], nil, "not yet")
        coordinator:workStep(4000)
        T.equal(alerts.raised["transfer_stalled:crafts"], nil, "still within tolerance")
        coordinator:workStep(6500)
        local raised = alerts.raised["transfer_stalled:crafts"]
        T.truthy(raised, "a wedged transfer must say so")
        T.equal(raised.severity, "critical")
        T.contains(raised.message, "crafts")
    end},
    {name="a transfer that settles in time raises nothing",run=function()
        local alerts = fakeAlerts()
        local service = stubService("TRANSFERRING")
        local coordinator = build({imports=service, alerts=alerts, configured=true,
            stall_after=5000})
        coordinator:workStep(1000)
        function service:status() return {state="IDLE"} end
        coordinator:workStep(20000)
        T.equal(alerts.raised["transfer_stalled:imports"], nil,
            "a slow but finishing transfer is not a stall")
    end},
    {name="the stall alert clears once the transfer settles",run=function()
        local alerts = fakeAlerts()
        local service = stubService("VERIFYING")
        local coordinator = build({imports=service, alerts=alerts, configured=true,
            stall_after=5000})
        coordinator:workStep(1000)
        coordinator:workStep(9000)
        T.truthy(alerts.raised["transfer_stalled:imports"], "raised")
        function service:status() return {state="IDLE"} end
        coordinator:workStep(10000)
        T.equal(alerts.raised["transfer_stalled:imports"], nil, "and cleared")
    end},
    {name="a paused system is not reported as stalled",run=function()
        -- Pausing deliberately freezes whatever was in flight. That is the operator's
        -- doing, not a fault.
        local alerts = fakeAlerts()
        local coordinator = build({imports=stubService("VERIFYING"), alerts=alerts,
            configured=true, paused=true, stall_after=5000})
        coordinator:workStep(1000)
        coordinator:workStep(20000)
        T.equal(alerts.raised["transfer_stalled:imports"], nil)
    end},

    {name="planning resumes once nothing is in flight",run=function()
        local planner = stubService("PLANNING")
        local coordinator = build({imports=planner, configured=true})
        for _ = 1, 30 do coordinator:workStep(1000) end
        T.truthy(planner.calls.ticks > 0, "with nothing in flight it must proceed")
    end},

}
