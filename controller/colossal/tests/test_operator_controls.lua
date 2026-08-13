keys = keys or {up=200, down=208, enter=28, f10=68, escape=1,
    one=2, two=3, three=4, four=5, five=6, r=19, c=46, a=30, p=25, x=45}

local Alerts = require("app.alerts")
local Coordinator = require("app.coordinator")
local Keymap = require("app.keymap")
local UI = require("app.ui")
local T = require("tests.mock_cc")

-- The nav tabs contribute hit regions too, and they come first, so a test that wants the
-- result row has to say so rather than taking whatever happens to be at index one.
local function regionFor(coordinator, kind)
    for _, region in ipairs(coordinator:viewModel().ui.hit_regions or {}) do
        if region.command and region.command.type == kind then return region end
    end
end

local function recordingRequests(list)
    local calls = {retry={}, cancel={}}
    return {
        list=function() return list end,
        retry=function(_, id) calls.retry[#calls.retry + 1] = id; return true end,
        cancel=function(_, id) calls.cancel[#calls.cancel + 1] = id; return true end,
        calls=calls,
    }
end

local function recordingAlerts(active)
    local calls = {acknowledge={}}
    return {
        active=function() return active end,
        acknowledge=function(_, key) calls.acknowledge[#calls.acknowledge + 1] = key; return true end,
        calls=calls,
    }
end

local function recordingRecovery()
    local calls = {resolve=0}
    return {
        status=function() return {state="BLOCKED"} end,
        resolve=function() calls.resolve = calls.resolve + 1; return true end,
        calls=calls,
    }
end

local function baseDeps()
    local scanner = {}
    function scanner:begin(node) return {node=node} end
    function scanner:step(scan)
        return true, {node_id=scan.node.id, peripheral_name=scan.node.peripheral_name,
            epoch=1, size=27, occupied=0, slots={}, health="READY"}
    end
    return {
        clock=function() return 1000 end, scanner=scanner,
        nodes={{id="storage_1", role="storage", peripheral_name="s1"}},
        ui=UI.new(T.recordingSurface(51, 19)), keymap=Keymap,
        initial_ui=UI.initialState(),
        build_index=function() return {items=function() return {} end} end,
        search=function() return {} end,
        lifecycle={derive=function() return "READY", "" end},
    }
end

return {
    {name="retrying the selected request calls the request service by id", run=function()
        local requests = recordingRequests({{id="request-1"}, {id="request-2"}, {id="request-3"}})
        local d = baseDeps(); d.requests = requests
        local coordinator = Coordinator.new(d)
        coordinator.uiState.page, coordinator.uiState.mode = "requests", "page"
        coordinator.uiState.request_selection = 2
        coordinator:command({type="RETRY_REQUEST"})
        T.arrayEqual(requests.calls.retry, {"request-2"})
    end},
    {name="cancelling the selected request calls the request service by id", run=function()
        -- The Requests page renders newest first, so selection 1 is the last entry
        -- Requests:list() returns (request-2), not the first.
        local requests = recordingRequests({{id="request-1"}, {id="request-2"}})
        local d = baseDeps(); d.requests = requests
        local coordinator = Coordinator.new(d)
        coordinator.uiState.page, coordinator.uiState.mode = "requests", "page"
        coordinator.uiState.request_selection = 1
        coordinator:command({type="CANCEL_REQUEST"})
        T.arrayEqual(requests.calls.cancel, {"request-2"})
    end},
    {name="an out of range request selection is a safe no-op", run=function()
        local requests = recordingRequests({{id="request-1"}})
        local d = baseDeps(); d.requests = requests
        local coordinator = Coordinator.new(d)
        coordinator.uiState.page, coordinator.uiState.mode = "requests", "page"
        coordinator.uiState.request_selection = 9
        coordinator:command({type="RETRY_REQUEST"})
        T.equal(#requests.calls.retry, 0)
    end},
    {name="acknowledging the selected alert calls the alert service by key", run=function()
        local alerts = recordingAlerts({{key="scanner_1"}, {key="scanner_2"}})
        local d = baseDeps(); d.alerts = alerts
        local coordinator = Coordinator.new(d)
        coordinator.uiState.page, coordinator.uiState.mode = "alerts", "page"
        coordinator.uiState.alert_selection = 2
        coordinator:command({type="ACKNOWLEDGE_ALERT"})
        T.arrayEqual(alerts.calls.acknowledge, {"scanner_2"})
    end},
    {name="confirming recovery release calls the recovery service", run=function()
        local recovery = recordingRecovery()
        local d = baseDeps(); d.recovery = recovery
        local coordinator = Coordinator.new(d)
        coordinator.uiState.page, coordinator.uiState.mode = "alerts", "page"
        coordinator:command({type="CONFIRM_RECOVERY_RELEASE"})
        T.equal(recovery.calls.resolve, 0, "an unarmed confirm must not release recovery")
        coordinator:command({type="ARM_RECOVERY_RELEASE"})
        coordinator:command({type="CONFIRM_RECOVERY_RELEASE"})
        T.equal(recovery.calls.resolve, 1)
    end},
    {name="an unarmed recovery release is refused by the reducer itself",run=function()
        local UI=require("app.ui")
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.page,state.mode="alerts","page"
        local reduced,effect=ui:reduce(state,{type="CONFIRM_RECOVERY_RELEASE"})
        T.equal(effect,nil,"releasing recovery must require an explicit arm first")
        T.equal(reduced.recovery_confirm_armed,false)
        local armed=ui:reduce(state,{type="ARM_RECOVERY_RELEASE"})
        T.equal(armed.recovery_confirm_armed,true)
        local _,confirmed=ui:reduce(armed,{type="CONFIRM_RECOVERY_RELEASE"})
        T.equal(confirmed and confirmed.type,"RESOLVE_RECOVERY")
    end},
    {name="toggling pause flips the coordinator pause state", run=function()
        local coordinator = Coordinator.new(baseDeps())
        T.equal(coordinator.paused, false)
        coordinator:command({type="TOGGLE_PAUSE"})
        T.equal(coordinator.paused, true)
        coordinator:command({type="TOGGLE_PAUSE"})
        T.equal(coordinator.paused, false)
    end},
    {name="redraw syncs live request and alert counts into UI state", run=function()
        local requests = recordingRequests({{id="a"}, {id="b"}, {id="c"}})
        local alerts = recordingAlerts({{key="x"}})
        local d = baseDeps(); d.requests, d.alerts = requests, alerts
        local coordinator = Coordinator.new(d)
        coordinator:redraw()
        T.equal(coordinator:viewModel().ui.request_count, 3)
        T.equal(coordinator:viewModel().ui.alert_count, 1)
    end},
    {name="rendered hit regions are fed back so mouse clicks work", run=function()
        local d = baseDeps()
        d.search = function() return {{identity_key="stone", name="minecraft:stone",
            display_name="Stone", quantity=10, max_count=64,
            variants={{identity_key="stone", display_name="Stone", quantity=10, max_count=64}}}} end
        local coordinator = Coordinator.new(d)
        coordinator:tick(1000)
        local region = regionFor(coordinator, "ACTIVATE")
        T.truthy(region, "no result row region was rendered")
        coordinator:handle({"mouse_click", 1, region.x1, region.y1})
        T.equal(coordinator:viewModel().ui.mode, "quantity")
    end},
    {name="pressing the stack quantity hotkey does not leak the character into the search query", run=function()
        local d = baseDeps()
        d.search = function() return {{identity_key="stone", name="minecraft:stone",
            display_name="Stone", quantity=10, max_count=64,
            variants={{identity_key="stone", display_name="Stone", quantity=10, max_count=64}}}} end
        local coordinator = Coordinator.new(d)
        coordinator:tick(1000)
        local region = regionFor(coordinator, "ACTIVATE")
        coordinator:handle({"mouse_click", 1, region.x1, region.y1})
        T.equal(coordinator:viewModel().ui.mode, "quantity")
        -- CC:Tweaked fires a "key" event, then a "char" event, for the same physical keypress.
        coordinator:handle({"key", keys.s})
        T.equal(coordinator:viewModel().ui.mode, "search")
        coordinator:handle({"char", "s"})
        T.equal(coordinator:viewModel().ui.query, "")
    end},
    {name="a coordinator without alerts still exposes hit regions", run=function()
        local d = baseDeps()
        local coordinator = Coordinator.new(d)
        coordinator:redraw()
        T.truthy(coordinator:viewModel().ui.hit_regions ~= nil)
    end},
    {name="repeated component failures coalesce into a single rising alert", run=function()
        local d = baseDeps()
        local scanner = {}
        function scanner:begin(node) return {node=node} end
        function scanner:step() error("chest disconnected") end
        d.scanner = scanner
        d.alerts = Alerts.new(function() return 100 end)
        local coordinator = Coordinator.new(d)
        coordinator:tick(1000); coordinator:tick(1001)
        local active = coordinator:viewModel().alerts
        T.equal(#active, 1)
        T.equal(active[1].occurrences, 2)
        T.equal(active[1].severity, "critical")
    end},
    {name="a tall terminal derives a search result limit far above the old fixed cap", run=function()
        local d = baseDeps()
        d.ui = UI.new(T.recordingSurface(51, 40))
        local seenLimit
        d.search = function(_, _, _, limit) seenLimit = limit; return {} end
        local coordinator = Coordinator.new(d)
        coordinator:tick(1000)
        T.truthy(seenLimit ~= nil)
        T.truthy(seenLimit > 10)
    end},
    {name="a short terminal still derives a limit that covers its own visible rows", run=function()
        local d = baseDeps()
        d.ui = UI.new(T.recordingSurface(51, 13))
        local seenLimit
        d.search = function(_, _, _, limit) seenLimit = limit; return {} end
        local coordinator = Coordinator.new(d)
        coordinator:tick(1000)
        T.truthy(seenLimit >= 13)
    end},
    {name="without a terminal surface the default limit is still far above 10", run=function()
        local d = baseDeps()
        local seenLimit
        d.search = function(_, _, _, limit) seenLimit = limit; return {} end
        local coordinator = Coordinator.new(d)
        coordinator:tick(1000)
        T.truthy(seenLimit >= 50)
    end},
    {name="the full keyboard path retries a request without touching internal state directly", run=function()
        -- Selection 2, newest first, lands on the oldest entry (request-1).
        local requests = recordingRequests({{id="request-1"}, {id="request-2"}})
        local d = baseDeps(); d.requests = requests
        local coordinator = Coordinator.new(d)
        coordinator:redraw()
        coordinator:handle({"key", keys.three})
        T.equal(coordinator:viewModel().ui.page, "requests")
        coordinator:handle({"key", keys.down})
        T.equal(coordinator:viewModel().ui.request_selection, 2)
        coordinator:handle({"key", keys.r})
        T.arrayEqual(requests.calls.retry, {"request-1"})
    end},
    {name="the requests page renders newest first", run=function()
        local requests = recordingRequests({{id="request-1"}, {id="request-2"}, {id="request-3"}})
        local d = baseDeps(); d.requests = requests
        local coordinator = Coordinator.new(d)
        local model = coordinator:viewModel()
        T.equal(model.requests[1].id, "request-3")
        T.equal(model.requests[2].id, "request-2")
        T.equal(model.requests[3].id, "request-1")
    end},
    {name="the full keyboard path acknowledges an alert after a two key recovery cancel", run=function()
        local alerts = recordingAlerts({{key="alert-1"}})
        local recovery = recordingRecovery()
        local d = baseDeps(); d.alerts, d.recovery = alerts, recovery
        local coordinator = Coordinator.new(d)
        coordinator:redraw()
        coordinator:handle({"key", keys.four})
        T.equal(coordinator:viewModel().ui.page, "alerts")
        coordinator:handle({"key", keys.x})
        T.equal(coordinator:viewModel().ui.recovery_confirm_armed, true)
        coordinator:handle({"key", keys.up})
        T.equal(coordinator:viewModel().ui.recovery_confirm_armed, false)
        T.equal(recovery.calls.resolve, 0)
        coordinator:handle({"key", keys.a})
        T.arrayEqual(alerts.calls.acknowledge, {"alert-1"})
    end},
    {name="the notices list is capped so it cannot grow without bound", run=function()
        local d = baseDeps()
        local scanner = {}
        function scanner:begin(node) return {node=node} end
        function scanner:step() error("chest disconnected") end
        d.scanner = scanner
        local coordinator = Coordinator.new(d)
        for tick = 1, 60 do coordinator:tick(1000 + tick) end
        local notices = coordinator:viewModel().notices
        T.truthy(#notices <= 50)
    end},
}
