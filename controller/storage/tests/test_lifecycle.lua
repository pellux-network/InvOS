local Lifecycle = require("app.lifecycle")
local T = require("tests.mock_cc")

local function readyContext()
    return {
        configured = true,
        persistence_error = nil,
        journal_error = nil,
        recovering = false,
        paused = false,
        initial_index_complete = true,
        dropoff_ready = true,
        pickup_ready = true,
        ready_storage = 2,
        unhealthy_nodes = 0,
    }
end

return {
    { name = "lifecycle forbids skipped request transitions", run = function()
        local ok, reason = Lifecycle.transition("request", "QUEUED", "TRANSFERRING")
        T.equal(ok, nil)
        T.contains(reason, "forbidden request transition")
        T.truthy(Lifecycle.transition("request", "QUEUED", "PLANNING"))
    end },
    { name = "lifecycle allows bounded import recovery", run = function()
        T.truthy(Lifecycle.transition("import", "BLOCKED", "PLANNING"))
        T.truthy(Lifecycle.transition("import", "TRANSFERRING", "VERIFYING"))
        T.equal(Lifecycle.transition("import", "FAILED", "COMPLETE"), nil)
    end },
    { name = "request preflight changes may return to planning", run = function()
        T.truthy(Lifecycle.transition("request", "TRANSFERRING", "PLANNING"))
    end },
    { name = "controller lifecycle follows safety precedence", run = function()
        local cases = {
            { change = { persistence_error = "bad config" }, state = "ERROR" },
            { change = { configured = false }, state = "SETUP_REQUIRED" },
            { change = { recovering = true }, state = "RECOVERING" },
            { change = { paused = true }, state = "PAUSED" },
            { change = { initial_index_complete = false }, state = "INDEXING" },
            { change = { unhealthy_nodes = 1 }, state = "DEGRADED" },
            { change = {}, state = "READY" },
        }
        for _, case in ipairs(cases) do
            local context = readyContext()
            for key, value in pairs(case.change) do context[key] = value end
            local state = Lifecycle.derive(context)
            T.equal(state, case.state, "wrong lifecycle for " .. case.state)
        end
    end },
    { name = "missing IO or healthy storage degrades without claiming offline", run = function()
        local context = readyContext()
        context.dropoff_ready = false
        context.pickup_ready = false
        context.ready_storage = 0
        local state, reason = Lifecycle.derive(context)
        T.equal(state, "DEGRADED")
        T.contains(reason, "no healthy storage")
        T.contains(reason, "Drop-off unavailable")
        T.contains(reason, "Pickup unavailable")
    end },
    { name = "journal failure outranks setup and pause", run = function()
        local context = readyContext()
        context.journal_error = "unsafe journal unavailable"
        context.configured = false
        context.paused = true
        local state, reason = Lifecycle.derive(context)
        T.equal(state, "ERROR")
        T.contains(reason, "unsafe journal unavailable")
    end },
}
