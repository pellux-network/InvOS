local Alerts = require("app.alerts")
local T = require("tests.mock_cc")

return {
    { name = "setting an alert again bumps its occurrence count", run = function()
        local alerts = Alerts.new(function() return 100 end)
        alerts:set("pickup_full", "warning", "Pickup is full", { slots=0 })
        alerts:set("pickup_full", "warning", "Pickup is full", { slots=0 })
        local active = alerts:active()
        T.equal(#active, 1)
        T.equal(active[1].occurrences, 2)
    end },
    { name = "resolving an alert removes the active condition", run = function()
        local alerts = Alerts.new(function() return 100 end)
        alerts:set("storage_full", "critical", "Storage is full")
        T.truthy(alerts:resolve("storage_full"))
        T.equal(#alerts:active(), 0)
    end },
    { name = "alerts sort by severity and first occurrence", run = function()
        local now = 10
        local alerts = Alerts.new(function() now=now+1; return now end)
        alerts:set("info", "info", "Information")
        alerts:set("warn", "warning", "Warning")
        alerts:set("critical", "critical", "Critical")
        local active = alerts:active()
        T.equal(active[1].key, "critical")
        T.equal(active[2].key, "warn")
        T.equal(active[3].key, "info")
    end },
}
