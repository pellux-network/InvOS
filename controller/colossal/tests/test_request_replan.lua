local Alerts=require("app.alerts")
local Lifecycle=require("app.lifecycle")
local Requests=require("app.requests")
local T=require("tests.mock_cc")

return {{name="changed Pickup preflight blocks for rescan instead of failing request",run=function()
    local planner={planRetrieval=function() return {{source_name="store",source_slot=1,
        source_epoch=1,source_pre_count=4,destination_name="pickup",destination_slot=1,
        destination_epoch=1,destination_pre_count=0,identity_key="minecraft:stone\0-",limit=4}},0 end}
    local transfer={execute=function() return {state="FAILED",moved=0,
        reason={code="DESTINATION_CHANGED",message="Pickup changed"},rescan={"store","pickup"}} end}
    local requests=Requests.new({planner=planner,transfer=transfer,
        alerts=Alerts.new(function() return 0 end),transition=Lifecycle.transition,
        clock=function() return 0 end,idGenerator=function() return "request" end})
    requests:create({key="minecraft:stone\0-",name="minecraft:stone"},4)
    local context={index={},pickup={},generation=1,now=0}
    requests:tick(context);requests:tick(context)
    local result=requests:tick(context)
    T.equal(result.state,"BLOCKED")
    T.equal(result.reason.code,"DESTINATION_CHANGED")
    T.arrayEqual(result.rescan,{"store","pickup"})
end}}