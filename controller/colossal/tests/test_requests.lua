local Alerts=require("app.alerts")
local Lifecycle=require("app.lifecycle")
local Requests=require("app.requests")
local T=require("tests.mock_cc")

local stone="minecraft:stone\0-"
local function planned(limit)
    return {source_name="store",source_slot=1,destination_name="pickup",
        source_epoch=1,source_pre_count=limit,identity_key=stone,limit=limit}
end
local function worker(outcomes)
    local value={execute_calls=0,verify_calls=0,retire_calls=0,cursor=1}
    function value:execute(_,step,storage)
        self.execute_calls=self.execute_calls+1;T.truthy(storage)
        return {state="VERIFYING",journal={step=step},rescan={"storage"},moved=99}
    end
    function value:verify(_,storage)
        self.verify_calls=self.verify_calls+1;T.truthy(storage)
        local result=outcomes[self.cursor];self.cursor=self.cursor+1;return result
    end
    function value:retire() self.retire_calls=self.retire_calls+1;return true end
    return value
end
local function service(plans,outcomes)
    local planCalls=0;local planner={}
    function planner.planRetrieval()
        planCalls=planCalls+1;local value=plans[planCalls]
        return value.plan,value.remainder,value.reason
    end
    local transfer=worker(outcomes);local alerts=Alerts.new(function() return 0 end)
    local requests=Requests.new({planner=planner,transfer=transfer,alerts=alerts,
        transition=Lifecycle.transition,clock=function() return 100 end,
        idGenerator=function(counter) return "request-"..counter end})
    return requests,transfer,alerts,function() return planCalls end
end
local function context(generation)
    return {index={},pickup={},storage={{node_id="storage",health="READY",slots={}}},
        generation=generation or 1,now=100}
end
local function advance(requests,ctx)
    requests:tick(ctx);requests:tick(ctx);requests:tick(ctx);return requests:tick(ctx)
end

return {
    {name="over-delivery credits measured stock delta once and never retries",run=function()
        local requests,transfer,alerts=service({{plan={planned(2)},remainder=0}},
            {{state="COMPLETE",moved=3,reported_moved=1}})
        local request=requests:create({key=stone,name="minecraft:stone"},2)
        local result=advance(requests,context())
        T.equal(result.state,"COMPLETE");T.equal(result.delivered,3)
        T.equal(transfer.execute_calls,1);T.equal(transfer.retire_calls,1)
        local active=alerts:active();T.equal(#active,1);T.equal(active[1].severity,"critical")
        T.equal(active[1].details.code,"OVER_DELIVERY")
        T.equal(active[1].details.requested,2);T.equal(active[1].details.measured,3)
        requests:tick(context());T.equal(transfer.execute_calls,1)
        T.equal(requests:get(request.id).delivered,3)
    end},
    {name="partial measured delivery replans only the remaining quantity",run=function()
        local requests,transfer=service({{plan={planned(2)},remainder=0},
            {plan={planned(1)},remainder=0}},{{state="COMPLETE",moved=1,reported_moved=2},
            {state="COMPLETE",moved=1,reported_moved=1}})
        local request=requests:create({key=stone},2);local ctx=context(1)
        T.equal(advance(requests,ctx).state,"PARTIAL")
        T.equal(requests:get(request.id).delivered,1)
        ctx.generation=2;requests:tick(ctx);requests:tick(ctx);requests:tick(ctx)
        local result=requests:tick(ctx)
        T.equal(result.state,"COMPLETE");T.equal(result.delivered,2)
        T.equal(transfer.execute_calls,2);T.equal(transfer.retire_calls,2)
    end},
    {name="zero measured delivery becomes retryable Pickup full",run=function()
        local requests,transfer=service({{plan={planned(2)},remainder=0}},
            {{state="COMPLETE",moved=0,reported_moved=2}})
        requests:create({key=stone},2);local result=advance(requests,context())
        T.equal(result.state,"BLOCKED");T.equal(result.reason.code,"PICKUP_FULL")
        T.equal(transfer.retire_calls,1)
    end},
    {name="waiting reconciliation keeps the request in verification",run=function()
        local requests,transfer=service({{plan={planned(2)},remainder=0}},
            {{state="WAITING",reason={code="STORAGE_SCOPE_INCOMPLETE",retryable=true},rescan={"storage"}},
             {state="COMPLETE",moved=2,reported_moved=2}})
        requests:create({key=stone},2);local ctx=context()
        local result=advance(requests,ctx)
        T.equal(result.state,"VERIFYING");T.arrayEqual(result.rescan,{"storage"})
        result=requests:tick(ctx);T.equal(result.state,"COMPLETE")
        T.equal(transfer.execute_calls,1);T.equal(transfer.retire_calls,1)
    end},
}