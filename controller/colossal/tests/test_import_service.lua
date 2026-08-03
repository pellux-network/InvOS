local Alerts = require("app.alerts")
local ImportService = require("app.import_service")
local Lifecycle = require("app.lifecycle")
local T = require("tests.mock_cc")

local stone = "minecraft:stone\0-"

local function dropoff(count)
    return {
        health="READY", peripheral_name="drop", epoch=10, generation=1,
        slots=count and { [1]={name="minecraft:stone",count=count,identity_key=stone} } or {},
    }
end

local function fakeTransfer(moves)
    local value = { execute_calls=0, verify_calls=0, moves=moves, cursor=1 }
    function value:execute(_, step)
        self.execute_calls = self.execute_calls + 1
        local moved = self.moves[self.cursor]
        self.cursor = self.cursor + 1
        return { state="VERIFYING", moved=moved, journal={ step=step },
            rescan={step.source_name,step.destination_name} }
    end
    function value:verify(journal, _)
        self.verify_calls = self.verify_calls + 1
        return { state="COMPLETE", moved=self.moves[self.cursor-1], journal=journal }
    end
    return value
end

local function step(limit)
    return { source_name="drop",source_slot=1,destination_name="store",destination_slot=1,
        source_epoch=10,destination_epoch=20,source_pre_count=limit,
        destination_pre_count=0,identity_key=stone,limit=limit }
end

local function service(plans, moves)
    local planCalls = 0
    local planner = {}
    function planner.planImport()
        planCalls = planCalls + 1
        local value = plans[planCalls]
        return value.plan, value.remainder, value.reason
    end
    local transfer = fakeTransfer(moves)
    local alerts = Alerts.new(function() return 0 end)
    return ImportService.new({ planner=planner, transfer=transfer, alerts=alerts,
        transition=Lifecycle.transition, clock=function() return 0 end }),
        transfer, alerts, function() return planCalls end
end

return {
    { name = "import performs at most one transfer step per tick", run = function()
        local imports, transfer = service({
            { plan={step(64),step(36)}, remainder=0 },
        }, {64})
        local context = { dropoff=dropoff(100), storage={}, generation=1, now=0,
            observed={source={},destination={}} }
        T.equal(imports:tick(context).state, "PLANNING")
        T.equal(imports:tick(context).state, "TRANSFERRING")
        T.equal(transfer.execute_calls, 0)
        T.equal(imports:tick(context).state, "VERIFYING")
        T.equal(transfer.execute_calls, 1)
        T.equal(imports:tick(context).state, "PARTIAL")
        T.equal(transfer.verify_calls, 1)
        T.equal(imports:status().moved, 64)
    end },
    { name = "import leaves a verified remainder for fresh replanning", run = function()
        local imports = service({
            { plan={step(64)}, remainder=36 },
            { plan={step(36)}, remainder=0 },
        }, {64,36})
        local context = { dropoff=dropoff(100), storage={}, generation=1, now=0,
            observed={source={},destination={}} }
        for _=1,4 do imports:tick(context) end
        T.equal(imports:status().state, "PARTIAL")
        context.dropoff = dropoff(36)
        context.generation = 2
        T.equal(imports:tick(context).state, "PLANNING")
        T.equal(imports:tick(context).state, "TRANSFERRING")
    end },
    { name = "blocked import retries only after relevant generation change", run = function()
        local imports, _, alerts, planCalls = service({
            { plan={}, remainder=32, reason={code="STORAGE_FULL",message="full",retryable=true} },
            { plan={step(32)}, remainder=0 },
        }, {32})
        local context = { dropoff=dropoff(32), storage={}, generation=5, now=0 }
        imports:tick(context)
        T.equal(imports:tick(context).state, "BLOCKED")
        T.equal(#alerts:active(), 1)
        T.equal(imports:tick(context).state, "BLOCKED")
        T.equal(planCalls(), 1)
        context.generation = 6
        T.equal(imports:tick(context).state, "PLANNING")
        T.equal(imports:tick(context).state, "TRANSFERRING")
        T.equal(planCalls(), 2)
    end },
    { name = "repeated blocked import keeps one condition alert", run = function()
        local blocked = { plan={},remainder=32,
            reason={code="STORAGE_FULL",message="full",retryable=true} }
        local imports, _, alerts = service({ blocked, blocked }, {0})
        local context = { dropoff=dropoff(32),storage={},generation=1,now=0 }
        imports:tick(context); imports:tick(context)
        context.generation=2; imports:tick(context); imports:tick(context)
        T.equal(#alerts:active(), 1)
        T.equal(alerts:active()[1].occurrences, 2)
    end },
}
