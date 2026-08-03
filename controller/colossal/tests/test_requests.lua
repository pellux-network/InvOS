local Alerts = require("app.alerts")
local Lifecycle = require("app.lifecycle")
local Requests = require("app.requests")
local T = require("tests.mock_cc")

local stone = "minecraft:stone\0-"

local function transfer(moves)
    local value = { cursor=1, execute_calls=0, verify_calls=0 }
    function value:execute(_, planned)
        self.execute_calls=self.execute_calls+1
        local moved=moves[self.cursor]; self.cursor=self.cursor+1
        return {state="VERIFYING",moved=moved,journal={step=planned},rescan={"store"}}
    end
    function value:verify(journal, _)
        self.verify_calls=self.verify_calls+1
        return {state="COMPLETE",moved=moves[self.cursor-1],journal=journal}
    end
    return value
end

local function planned(limit)
    return {source_name="store",source_slot=1,destination_name="pickup",
        source_epoch=1,source_pre_count=limit,identity_key=stone,limit=limit}
end

local function service(plans, moves)
    local calls=0
    local planner={}
    function planner.planRetrieval()
        calls=calls+1
        local value=plans[calls]
        return value.plan,value.remainder,value.reason
    end
    local worker=transfer(moves)
    local alerts=Alerts.new(function() return 0 end)
    local requests=Requests.new({planner=planner,transfer=worker,alerts=alerts,
        transition=Lifecycle.transition,clock=function() return 100 end,
        idGenerator=function(counter) return "request-"..counter end})
    return requests,worker,alerts,function() return calls end
end

local function context(generation)
    return {index={},pickup={},generation=generation or 1,now=100,
        observed={source={}}}
end

return {
    { name = "request spans replanned transfer steps and records exact delivery", run = function()
        local requests,worker = service({
            {plan={planned(64)},remainder=26},
            {plan={planned(26)},remainder=0},
        }, {64,26})
        local request=requests:create({key=stone,name="minecraft:stone"},90)
        local ctx=context(1)
        requests:tick(ctx); requests:tick(ctx); requests:tick(ctx); requests:tick(ctx)
        T.equal(requests:get(request.id).state,"PARTIAL")
        T.equal(requests:get(request.id).delivered,64)
        ctx.generation=2
        requests:tick(ctx); requests:tick(ctx); requests:tick(ctx); requests:tick(ctx)
        T.equal(requests:get(request.id).state,"COMPLETE")
        T.equal(requests:get(request.id).delivered,90)
        T.equal(worker.execute_calls,2)
    end },
    { name = "zero move blocks as retryable Pickup full after verification", run = function()
        local requests=service({{plan={planned(5)},remainder=0}},{0})
        local request=requests:create({key=stone},5)
        local ctx=context()
        requests:tick(ctx);requests:tick(ctx);requests:tick(ctx)
        local result=requests:tick(ctx)
        T.equal(result.state,"BLOCKED")
        T.equal(result.delivered,0)
        T.equal(result.reason.code,"PICKUP_FULL")
        T.equal(result.reason.retryable,true)
        T.contains(result.reason.message,"Pickup")
        T.equal(result.rescan,nil)
    end },
    { name = "cancellation during verification stops future steps but keeps moved count", run = function()
        local requests = service({{plan={planned(20)},remainder=30}}, {20})
        local request=requests:create({key=stone},50)
        local ctx=context()
        requests:tick(ctx); requests:tick(ctx); requests:tick(ctx)
        T.equal(requests:get(request.id).state,"VERIFYING")
        T.truthy(requests:cancel(request.id))
        requests:tick(ctx)
        local result=requests:get(request.id)
        T.equal(result.state,"CANCELLED")
        T.equal(result.delivered,20)
    end },
    { name = "blocked request waits for generation change instead of busy retrying", run = function()
        local blocked={plan={},remainder=5,
            reason={code="PICKUP_UNAVAILABLE",message="offline",retryable=true}}
        local requests,_,alerts,planCalls=service({blocked,{plan={planned(5)},remainder=0}},{5})
        local request=requests:create({key=stone},5)
        local ctx=context(7)
        requests:tick(ctx); requests:tick(ctx)
        T.equal(requests:get(request.id).state,"BLOCKED")
        requests:tick(ctx)
        T.equal(planCalls(),1)
        T.equal(#alerts:active(),1)
        ctx.generation=8
        T.equal(requests:tick(ctx).state,"PLANNING")
        T.equal(requests:tick(ctx).state,"TRANSFERRING")
        T.equal(planCalls(),2)
    end },
    { name = "queued cancellation starts no transfer", run = function()
        local requests,worker=service({},{})
        local request=requests:create({key=stone},1)
        T.truthy(requests:cancel(request.id))
        T.equal(requests:get(request.id).state,"CANCELLED")
        requests:tick(context())
        T.equal(worker.execute_calls,0)
    end },
}