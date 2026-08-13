local Coordinator = require("app.coordinator")
local T = require("tests.mock_cc")

-- A node whose peripheral has been removed from the world -- a multiblock reformed, a chest
-- broken -- can never be scanned again. It also never gets a snapshot, which made it
-- permanently the stalest node and therefore permanently the next one to try.
local function vanishedNode()
    local attempts, notices = 0, 0
    local scanner = {}
    function scanner.begin()
        attempts = attempts + 1
        error("no such peripheral: minecraft:chest_0")
    end
    function scanner.step() return true, nil, "unreachable" end
    local ui = {}
    function ui:reduce(state) return state end
    function ui:render() end
    local alerts = {set=function() notices = notices + 1 end, active=function() return {} end,
        resolve=function() end}
    local now = 0
    return {
        configured = true,
        clock = function() return now end,
        setClock = function(value) now = value end,
        scanner = scanner,
        nodes = {{id="storage", role="storage", peripheral_name="minecraft:chest_0"}},
        ui = ui,
        initial_ui = {mode="page", page="search", results={}, hit_regions={}},
        keymap = {command = function() end},
        build_index = function() return {items = function() return {} end} end,
        search = function() return {} end,
        lifecycle = {derive = function() return "DEGRADED", "" end},
        alerts = alerts,
        registry = {},
        metadata_budget = 1,
        scan_refresh_interval = 2000,
        counts = function() return attempts, notices end,
    }
end

return {
    {name="a vanished node is not retried at the full work-loop rate",run=function()
        local deps = vanishedNode()
        local coordinator = Coordinator.new(deps)
        -- Twenty ticks inside one second, which is what the 0.05s worker loop actually does.
        for tick = 1, 20 do coordinator:tick(1000 + tick * 50) end
        local attempts = deps.counts()
        T.truthy(attempts <= 4,
            "expected the failure to back off, got " .. attempts .. " scan attempts in a second")
    end},
    {name="a vanished node is retried once the backoff has elapsed",run=function()
        local deps = vanishedNode()
        local coordinator = Coordinator.new(deps)
        coordinator:tick(1000)
        local first = deps.counts()
        T.equal(first, 1, "the first attempt must happen immediately")
        coordinator:tick(1000 + 60000)
        local second = deps.counts()
        T.truthy(second > first,
            "a chest that is put back must be picked up again without a restart")
    end},
    {name="a repeated identical failure does not repaint the screen every tick",run=function()
        local deps = vanishedNode()
        local renders = 0
        deps.ui.render = function() renders = renders + 1 end
        local coordinator = Coordinator.new(deps)
        coordinator:redraw()
        renders = 0
        for tick = 1, 20 do coordinator:tick(1000 + tick * 50) end
        T.truthy(renders <= 4,
            "expected the screen to settle, got " .. renders .. " repaints in a second")
    end},
    {name="an explicit rescan request still bypasses the backoff",run=function()
        local deps = vanishedNode()
        local coordinator = Coordinator.new(deps)
        coordinator:tick(1000)
        local before = deps.counts()
        -- The peripheral event fires when a player re-forms the multiblock. Waiting out a
        -- backoff before believing them would be the wrong call.
        coordinator:requestRescan({"storage"})
        coordinator:tick(1050)
        T.truthy(deps.counts() > before, "an explicit rescan must be honoured immediately")
    end},
}
