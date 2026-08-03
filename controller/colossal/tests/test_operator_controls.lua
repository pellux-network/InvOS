local Alerts = require("app.alerts")
local Coordinator = require("app.coordinator")
local Keymap = require("app.keymap")
local UI = require("app.ui")
local T = require("tests.mock_cc")

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
        local requests = recordingRequests({{id="request-1"}, {id="request-2"}})
        local d = baseDeps(); d.requests = requests
        local coordinator = Coordinator.new(d)
        coordinator.uiState.page, coordinator.uiState.mode = "requests", "page"
        coordinator.uiState.request_selection = 1
        coordinator:command({type="CANCEL_REQUEST"})
        T.arrayEqual(requests.calls.cancel, {"request-1"})
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
        T.equal(recovery.calls.resolve, 1)
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
        local region = coordinator:viewModel().ui.hit_regions[1]
        T.truthy(region)
        T.equal(region.command.type, "ACTIVATE")
        coordinator:handle({"mouse_click", 1, region.x1, region.y1})
        T.equal(coordinator:viewModel().ui.mode, "quantity")
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
