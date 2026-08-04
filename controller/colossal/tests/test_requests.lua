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
    function value:executeMultiBatch(_,step,storage)
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
local function service(plans,outcomes,extra)
    local planCalls=0;local planner={}
    function planner.planRetrieval()
        planCalls=planCalls+1;local value=plans[planCalls]
        return value.plan,value.remainder,value.reason
    end
    local transfer=worker(outcomes);local alerts=Alerts.new(function() return 0 end)
    local deps={planner=planner,transfer=transfer,alerts=alerts,
        transition=Lifecycle.transition,clock=function() return 100 end,
        idGenerator=function(counter) return "request-"..counter end}
    for key,value in pairs(extra or {}) do deps[key]=value end
    local requests=Requests.new(deps)
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
    {name="request display name prefers identity display_name over the raw name",run=function()
        local requests=select(1,service({{plan={planned(1)},remainder=0}},{}))
        local request=requests:create({key=stone,name="minecraft:stone",display_name="Stone"},1)
        T.equal(request.display_name,"Stone")
    end},
    {name="request display name falls back to the identity name when no display name is set",run=function()
        local requests=select(1,service({{plan={planned(1)},remainder=0}},{}))
        local request=requests:create({key=stone,name="minecraft:stone"},1)
        T.equal(request.display_name,"minecraft:stone")
    end},
    {name="create records item usage through the injected record_usage callback",run=function()
        local calls={}
        local requests=select(1,service({{plan={planned(1)},remainder=0}},{},
            {record_usage=function(key,timestamp) calls[#calls+1]={key=key,timestamp=timestamp} end}))
        local request=requests:create({key=stone,name="minecraft:stone"},1)
        T.equal(#calls,1)
        T.equal(calls[1].key,stone)
        T.equal(calls[1].timestamp,request.created_at)
    end},
    {name="a throwing record_usage callback does not prevent the request from being created",run=function()
        local requests=select(1,service({{plan={planned(1)},remainder=0}},{},
            {record_usage=function() error("disk detached") end}))
        local request=requests:create({key=stone,name="minecraft:stone"},1)
        T.truthy(request.id)
    end},
    {name="create is safe without a record_usage callback",run=function()
        local requests=select(1,service({{plan={planned(1)},remainder=0}},{}))
        local request=requests:create({key=stone,name="minecraft:stone"},1)
        T.truthy(request.id)
    end},
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
    {name="throwing journal retirement cannot apply a request result twice",run=function()
        local requests,transfer,alerts=service({{plan={planned(1)},remainder=0}},
            {{state="COMPLETE",moved=1,reported_moved=1}})
        function transfer:retire() self.retire_calls=self.retire_calls+1;error("disk detached") end
        local request=requests:create({key=stone},1);local ctx=context()
        local result=advance(requests,ctx)
        T.equal(result.state,"COMPLETE");T.equal(result.delivered,1)
        requests:tick(ctx);requests:tick(ctx)
        T.equal(requests:get(request.id).delivered,1)
        T.equal(transfer.execute_calls,1);T.equal(transfer.verify_calls,1)
        T.equal(alerts:active()[1].details.code,"JOURNAL_RETIRE")
    end},
    {name="zero movement waits for explicit Pickup retry despite background generations",run=function()
        local requests,transfer=service({{plan={planned(2)},remainder=0}},
            {{state="COMPLETE",moved=0,reported_moved=2}})
        local request=requests:create({key=stone},2);local ctx=context(1)
        T.equal(advance(requests,ctx).state,"BLOCKED")
        for generation=2,8 do ctx.generation=generation;ctx.now=100000+generation;requests:tick(ctx) end
        T.equal(requests:get(request.id).state,"BLOCKED");T.equal(transfer.execute_calls,1)
        T.truthy(requests:retry(request.id));T.equal(requests:get(request.id).state,"PLANNING")
    end},
    {name="opposite request delta raises a critical actionable alert",run=function()
        local requests,transfer,alerts=service({{plan={planned(2)},remainder=0}},
            {{state="WAITING",reason={code="RECONCILE_DIRECTION"},rescan={"storage"}}})
        requests:create({key=stone},2);T.equal(advance(requests,context()).state,"VERIFYING")
        T.equal(transfer.execute_calls,1);local active=alerts:active()
        T.equal(active[1].severity,"critical");T.equal(active[1].details.code,"RECONCILE_DIRECTION")
    end},
    {name="completed requests are capped, dropping the oldest terminal ones first, while queued requests are kept regardless of age",run=function()
        local requests=select(1,service({},{}))
        local ids={}
        for i=1,35 do
            local r=requests:create({key=stone},1)
            ids[i]=r.id
            requests:cancel(r.id)
        end
        local queued=requests:create({key=stone},1)
        T.equal(#requests:list(),31)
        T.equal(requests:get(ids[1]),nil)
        T.equal(requests:get(ids[5]),nil)
        T.equal(requests:get(ids[6]).state,"CANCELLED")
        T.equal(requests:get(ids[35]).state,"CANCELLED")
        T.truthy(requests:get(queued.id))
    end},
    {name="waiting reconciliation keeps the request in verification",run=function()
        local requests,transfer,alerts=service({{plan={planned(2)},remainder=0}},
            {{state="WAITING",reason={code="STORAGE_SCOPE_INCOMPLETE",retryable=true},rescan={"storage"}},
             {state="COMPLETE",moved=2,reported_moved=2}})
        requests:create({key=stone},2);local ctx=context()
        local result=advance(requests,ctx)
        T.equal(result.state,"VERIFYING");T.arrayEqual(result.rescan,{"storage"})
        T.equal(alerts:active()[1].details.code,"STORAGE_SCOPE_INCOMPLETE")
        result=requests:tick(ctx);T.equal(result.state,"COMPLETE")
        T.equal(transfer.execute_calls,1);T.equal(transfer.retire_calls,1)
    end},
    {name="a request defaults to Pickup exactly as before",run=function()
        local seen
        local requests=service({{plan={planned(1)}}},{{state="COMPLETE",moved=1}},{
            planner={planRetrieval=function(_,_,_,destination)
                seen=destination; return {planned(1)},0 end}})
        requests:create({key=stone},1)
        local ctx=context(); ctx.pickup={peripheral_name="pickup",health="READY"}
        advance(requests,ctx)
        T.equal(seen.peripheral_name,"pickup","the planner is handed the Pickup node")
    end},
    {name="a request can target the craft buffer instead",run=function()
        local seen
        local requests=service({{plan={planned(1)}}},{{state="COMPLETE",moved=1}},{
            planner={planRetrieval=function(_,_,_,destination)
                seen=destination; return {planned(1)},0 end}})
        requests:create({key=stone},1,{destination_role="craft_buffer",owner="craft-1"})
        local ctx=context()
        ctx.pickup={peripheral_name="pickup",health="READY"}
        ctx.craft_buffer={peripheral_name="buffer",health="READY"}
        advance(requests,ctx)
        T.equal(seen.peripheral_name,"buffer","the planner is handed the buffer node")
    end},
    {name="a craft-owned request records its owner and destination",run=function()
        local requests=service({{plan={planned(1)}}},{{state="COMPLETE",moved=1}})
        local created=requests:create({key=stone},1,{destination_role="craft_buffer",owner="craft-7"})
        T.equal(created.owner,"craft-7")
        T.equal(created.destination_role,"craft_buffer")
        local plain=requests:create({key=stone},1)
        T.equal(plain.owner,nil)
        T.equal(plain.destination_role,"pickup")
    end},
    {name="craft-owned requests do not pollute usage statistics",run=function()
        local recorded={}
        local requests=service({{plan={planned(1)}}},{{state="COMPLETE",moved=1}},{
            record_usage=function(key) recorded[#recorded+1]=key end})
        requests:create({key=stone},1,{destination_role="craft_buffer",owner="craft-1"})
        T.equal(#recorded,0,"a recipe consuming an item is not a person asking for it")
        requests:create({key=stone},1)
        T.equal(#recorded,1,"an operator request still counts")
    end},
    {name="zero movement into the buffer blocks with a buffer-specific code",run=function()
        local requests,_,alerts=service({{plan={planned(1)}}},{{state="COMPLETE",moved=0}},{})
        requests:create({key=stone},1,{destination_role="craft_buffer",owner="craft-1"})
        local ctx=context()
        ctx.craft_buffer={peripheral_name="buffer",health="READY"}
        local request=advance(requests,ctx)
        T.equal(request.state,"BLOCKED")
        T.equal(request.reason.code,"BUFFER_FULL")
        T.truthy(alerts:active()[1])
    end},
    {name="zero movement into Pickup still blocks with PICKUP_FULL",run=function()
        local requests=service({{plan={planned(1)}}},{{state="COMPLETE",moved=0}},{})
        requests:create({key=stone},1)
        local ctx=context(); ctx.pickup={peripheral_name="pickup",health="READY"}
        local request=advance(requests,ctx)
        T.equal(request.state,"BLOCKED")
        T.equal(request.reason.code,"PICKUP_FULL")
    end},
    {name="a full destination waits for explicit retry, not a generation change",run=function()
        local requests=service({{plan={planned(1)}},{plan={planned(1)}}},
            {{state="COMPLETE",moved=0}},{})
        requests:create({key=stone},1,{destination_role="craft_buffer",owner="craft-1"})
        local ctx=context()
        ctx.craft_buffer={peripheral_name="buffer",health="READY"}
        advance(requests,ctx)
        local later=context(99)
        later.craft_buffer={peripheral_name="buffer",health="READY"}
        later.now=10000000
        local request=requests:tick(later)
        T.equal(request.state,"BLOCKED","a scan is not evidence the buffer drained")
    end},

}