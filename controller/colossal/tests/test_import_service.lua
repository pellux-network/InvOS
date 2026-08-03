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
    function transfer:executeBatch(_,planned,storage)
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
    {name="Drop-off change before any call abandons the import instead of wedging",run=function()
        local imports=service({{plan={step(5)},remainder=0}},{})
        local ctx=context(5)
        T.equal(imports:tick(ctx).state,"PLANNING")
        ctx.dropoff.slots[1]={name="minecraft:dirt",count=3,identity_key="minecraft:dirt\0-"}
        imports:tick(ctx)
        T.equal(imports:status().state,"IDLE","a pre-call Drop-off change must not be terminal")
        T.equal(imports:tick(ctx).state,"PLANNING","the new Drop-off contents import normally")
        T.equal(imports:status().source.identity_key,"minecraft:dirt\0-")
    end},
    {name="emptied Drop-off slot during a partial import abandons without wedging",run=function()
        local imports,transfer=service({{plan={step(5)},remainder=0}},
            {{state="COMPLETE",moved=2,reported_moved=2}})
        local ctx=context(5)
        imports:tick(ctx);imports:tick(ctx);imports:tick(ctx)
        T.equal(imports:tick(ctx).state,"PARTIAL")
        ctx.dropoff.slots[1]=nil
        imports:tick(ctx)
        T.equal(imports:status().state,"IDLE")
        T.equal(transfer.execute_calls,1,"no further call is issued for the vanished source")
        ctx.dropoff.slots[1]={name="minecraft:stone",count=4,identity_key=stone}
        T.equal(imports:tick(ctx).state,"PLANNING","later Drop-off contents still import")
    end},
    {name="a multi step plan is issued as one batch under one verification",run=function()
        local submitted
        local plan={step(4),step(1),step(59)}
        for index,planned in ipairs(plan) do planned.destination_slot=index end
        local imports,transfer=service({{plan=plan,remainder=0}},
            {{state="COMPLETE",moved=64,reported_moved=64}})
        function transfer:executeBatch(_,steps,storage)
            self.execute_calls=self.execute_calls+1;T.truthy(storage);submitted=steps
            return {state="VERIFYING",journal={step=steps},rescan={"storage","drop"}}
        end
        local ctx=context(64)
        imports:tick(ctx);imports:tick(ctx);imports:tick(ctx)
        T.equal(#submitted,3,"the whole plan goes out together")
        T.arrayEqual({submitted[1].limit,submitted[2].limit,submitted[3].limit},{4,1,59})
        local result=imports:tick(ctx)
        T.equal(result.state,"COMPLETE")
        T.equal(result.moved,64)
        T.equal(transfer.execute_calls,1,"one gate cycle served every step")
        T.equal(transfer.verify_calls,1,"one verification served every step")
    end},
    {name="a batch is capped so one ambiguous window stays bounded",run=function()
        local submitted
        local plan={}
        for index=1,20 do plan[index]=step(1);plan[index].destination_slot=index end
        local imports,transfer=service({{plan=plan,remainder=0}},{})
        function transfer:executeBatch(_,steps) submitted=steps
            return {state="VERIFYING",journal={},rescan={}} end
        local ctx=context(20)
        imports:tick(ctx);imports:tick(ctx);imports:tick(ctx)
        T.equal(#submitted,8,"the default cap bounds a single batch")
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