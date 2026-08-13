local Alerts=require("app.alerts")
local Imports=require("app.import_service")
local Lifecycle=require("app.lifecycle")
local T=require("tests.mock_cc")

return {{name="import planning refreshes a still-matching source scan epoch",run=function()
    local plannedEpoch
    local planner={planImport=function(source) plannedEpoch=source.epoch;return {},source.count,
        {code="FULL",message="full",retryable=true} end}
    local service=Imports.new({planner=planner,transfer={},alerts=Alerts.new(function() return 0 end),
        transition=Lifecycle.transition,clock=function() return 0 end})
    local item={name="minecraft:stone",count=12,identity_key="minecraft:stone\0-"}
    local context={dropoff={health="READY",peripheral_name="drop",epoch=1,slots={[1]=item}},
        storage={},generation=1,now=0}
    service:tick(context)
    context.dropoff.epoch=2;context.generation=2
    service:tick(context);service:tick(context)
    T.equal(plannedEpoch,2)
end}}
