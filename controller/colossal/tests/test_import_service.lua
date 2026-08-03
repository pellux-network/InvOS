local Alerts=require("app.alerts")
local ImportService=require("app.import_service")
local Lifecycle=require("app.lifecycle")
local T=require("tests.mock_cc")

local stone="minecraft:stone\0-"
local function dropoff(count)
    return {health="READY",peripheral_name="drop",epoch=10,
        slots=count and {[1]={name="minecraft:stone",count=count,identity_key=stone}} or {}}
end
local function step(limit)
    return {source_name="drop",source_slot=1,destination_name="store",destination_slot=1,
        source_epoch=10,destination_epoch=20,source_pre_count=limit,destination_pre_count=0,
        identity_key=stone,limit=limit}
end
local function service(plans,outcomes)
    local calls=0;local planner={}
    function planner.planImport() calls=calls+1;local value=plans[calls];return value.plan,value.remainder,value.reason end
    local transfer={execute_calls=0,verify_calls=0,retire_calls=0,cursor=1}
    function transfer:execute(_,planned,storage)
        self.execute_calls=self.execute_calls+1;T.truthy(storage)
        return {state="VERIFYING",journal={step=planned},rescan={"storage","drop"}}
    end
    function transfer:verify(_,storage)
        self.verify_calls=self.verify_calls+1;T.truthy(storage)
        local result=outcomes[self.cursor];self.cursor=self.cursor+1;return result
    end
    function transfer:retire() self.retire_calls=self.retire_calls+1;return true end
    local alerts=Alerts.new(function() return 0 end)
    return ImportService.new({planner=planner,transfer=transfer,alerts=alerts,
        transition=Lifecycle.transition,clock=function() return 0 end}),transfer,alerts
end
local function context(count,generation)
    return {dropoff=dropoff(count),storage={{node_id="storage",health="READY",slots={}}},
        generation=generation or 1,now=0}
end

return {
    {name="import credits measured aggregate increase rather than reported count",run=function()
        local imports,transfer=service({{plan={step(5)},remainder=0}},
            {{state="COMPLETE",moved=5,reported_moved=2}})
        local ctx=context(5)
        imports:tick(ctx);imports:tick(ctx);imports:tick(ctx)
        local result=imports:tick(ctx)
        T.equal(result.state,"COMPLETE");T.equal(result.moved,5)
        T.equal(transfer.execute_calls,1);T.equal(transfer.retire_calls,1)
    end},
    {name="partial import replans from a fresh Drop-off scan",run=function()
        local imports,transfer=service({{plan={step(5)},remainder=0},{plan={step(3)},remainder=0}},
            {{state="COMPLETE",moved=2,reported_moved=5},{state="COMPLETE",moved=3,reported_moved=3}})
        local ctx=context(5,1)
        imports:tick(ctx);imports:tick(ctx);imports:tick(ctx)
        T.equal(imports:tick(ctx).state,"PARTIAL")
        ctx=context(3,2);T.equal(imports:tick(ctx).state,"PLANNING")
        T.equal(imports:tick(ctx).state,"TRANSFERRING")
        T.equal(transfer.retire_calls,1)
    end},
    {name="throwing journal retirement cannot apply an import result twice",run=function()
        local imports,transfer,alerts=service({{plan={step(5)},remainder=0}},
            {{state="COMPLETE",moved=5,reported_moved=5}})
        function transfer:retire() self.retire_calls=self.retire_calls+1;error("disk detached") end
        local ctx=context(5);imports:tick(ctx);imports:tick(ctx);imports:tick(ctx)
        local result=imports:tick(ctx);T.equal(result.state,"COMPLETE");T.equal(result.moved,5)
        T.equal(imports:status().moved,5)
        T.equal(transfer.execute_calls,1);T.equal(transfer.verify_calls,1)
        T.equal(alerts:active()[1].details.code,"JOURNAL_RETIRE")
    end},
    {name="zero import waits for explicit retry despite background generations",run=function()
        local imports,transfer=service({{plan={step(5)},remainder=0}},
            {{state="COMPLETE",moved=0,reported_moved=0}})
        local ctx=context(5,1);imports:tick(ctx);imports:tick(ctx);imports:tick(ctx)
        T.equal(imports:tick(ctx).state,"BLOCKED")
        for generation=2,8 do ctx.generation=generation;ctx.now=100000+generation;imports:tick(ctx) end
        T.equal(imports:status().state,"BLOCKED");T.equal(transfer.execute_calls,1)
        T.truthy(imports:retry());T.equal(imports:status().state,"PLANNING")
    end},
    {name="opposite import delta raises a critical actionable alert",run=function()
        local imports,transfer,alerts=service({{plan={step(5)},remainder=0}},
            {{state="WAITING",reason={code="RECONCILE_DIRECTION"},rescan={"storage"}}})
        local ctx=context(5);imports:tick(ctx);imports:tick(ctx);imports:tick(ctx)
        T.equal(imports:tick(ctx).state,"VERIFYING");T.equal(transfer.execute_calls,1)
        local active=alerts:active();T.equal(active[1].severity,"critical")
        T.equal(active[1].details.code,"RECONCILE_DIRECTION")
    end},
    {name="waiting import reconciliation keeps one call in flight",run=function()
        local imports,transfer,alerts=service({{plan={step(5)},remainder=0}},
            {{state="WAITING",reason={code="STORAGE_SCOPE_INCOMPLETE"},rescan={"storage"}},
             {state="COMPLETE",moved=5,reported_moved=5}})
        local ctx=context(5);imports:tick(ctx);imports:tick(ctx);imports:tick(ctx)
        local result=imports:tick(ctx);T.equal(result.state,"VERIFYING")
        T.arrayEqual(result.rescan,{"storage"})
        T.equal(alerts:active()[1].details.code,"STORAGE_SCOPE_INCOMPLETE")
        result=imports:tick(ctx);T.equal(result.state,"COMPLETE")
        T.equal(transfer.execute_calls,1)
    end},
}