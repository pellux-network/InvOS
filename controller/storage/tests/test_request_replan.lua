local Alerts=require("app.alerts")
local Lifecycle=require("app.lifecycle")
local Requests=require("app.requests")
local T=require("tests.mock_cc")

return {{name="changed storage source abandons the pre-call attempt and replans",run=function()
    local planner={planRetrieval=function() return {{source_name="store",source_slot=1,
        source_epoch=1,source_pre_count=4,destination_name="pickup",
        identity_key="minecraft:stone\0-",limit=4}},0 end}
    local transfer={executeMultiBatch=function() return {state="FAILED",moved=0,
        reason={code="SOURCE_CHANGED",message="Storage changed"},rescan={"store"}} end}
    local requests=Requests.new({planner=planner,transfer=transfer,
        alerts=Alerts.new(function() return 0 end),transition=Lifecycle.transition,
        clock=function() return 0 end,idGenerator=function() return "request" end})
    requests:create({key="minecraft:stone\0-",name="minecraft:stone"},4)
    local context={index={},pickup={node_id="pickup",peripheral_name="pickup",slots={}},
        storage={{node_id="storage",peripheral_name="store",health="READY",slots={}}},
        generation=1,now=0}
    requests:tick(context);requests:tick(context);requests:tick(context)
    local result=requests:tick(context)
    T.equal(result.state,"PLANNING")
    T.equal(result.reason,nil)
    T.equal(result.journal,nil)
end}}
