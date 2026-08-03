local Alerts = require("app.alerts")
local ImportService = require("app.import_service")
local Lifecycle = require("app.lifecycle")
local T = require("tests.mock_cc")

local stone = "minecraft:stone\0-"

return {
    { name = "failed import requires and accepts explicit operator retry", run = function()
        local planner = { planImport=function() return {{
            source_name="drop",source_slot=1,source_epoch=1,source_pre_count=1,
            destination_name="store",destination_slot=1,destination_epoch=2,
            destination_pre_count=0,identity_key=stone,limit=1,
        }},0 end }
        local transfer = { execute=function() return {state="FAILED",
            reason={code="TRANSFER_EXCEPTION",message="cable gone"}} end }
        local imports = ImportService.new({planner=planner,transfer=transfer,
            alerts=Alerts.new(function() return 0 end),transition=Lifecycle.transition,
            clock=function() return 0 end})
        local context={dropoff={health="READY",peripheral_name="drop",epoch=1,
            slots={[1]={name="minecraft:stone",count=1,identity_key=stone}}},
            storage={},generation=1,now=0}
        imports:tick(context)
        imports:tick(context)
        imports:tick(context)
        T.equal(imports:status().state,"FAILED")
        T.truthy(imports:retry())
        T.equal(imports:status().state,"PLANNING")
    end },
}
