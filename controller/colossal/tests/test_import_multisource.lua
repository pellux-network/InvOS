local Alerts = require("app.alerts")
local ImportService = require("app.import_service")
local Lifecycle = require("app.lifecycle")
local Planner = require("core.planner")
local T = require("tests.mock_cc")

local function key(name) return name .. "\0-" end

-- A Drop-off holding several different item types, one per slot.
local function dropoff(spec)
    local slots = {}
    for slot, entry in pairs(spec) do
        slots[slot] = {name=entry[1], count=entry[2], identity_key=key(entry[1]), max_count=64}
    end
    return {health="READY", peripheral_name="drop", epoch=10, slots=slots}
end

local function storage(size)
    return {{node_id="store", peripheral_name="store", health="READY", epoch=20,
        size=size or 200, slots={}}}
end

local function service(options)
    options = options or {}
    local transfer = {calls=0, verify_calls=0, submitted=nil}
    function transfer:executeMultiBatch(operation, steps, snapshots)
        self.calls = self.calls + 1
        self.submitted = steps
        T.truthy(snapshots)
        return {state="VERIFYING", journal={steps=steps}, rescan={"store","drop"}}
    end
    function transfer:verify()
        self.verify_calls = self.verify_calls + 1
        return options.outcome or {state="COMPLETE", moved=options.moved or 0,
            reported_moved=options.moved or 0, moved_by_identity=options.byIdentity or {}}
    end
    function transfer:retire() return true end
    local alerts = Alerts.new(function() return 0 end)
    local imports = ImportService.new({planner=Planner, transfer=transfer, alerts=alerts,
        transition=Lifecycle.transition, clock=function() return 0 end,
        slot_batch_limit=options.slotLimit, batch_limit=options.batchLimit})
    return imports, transfer, alerts
end

local function context(dropoffSpec)
    return {dropoff=dropoff(dropoffSpec), storage=storage(), generation=1, now=0}
end

return {
    {name="several Drop-off slots of different types move in one gate cycle", run=function()
        local imports, transfer = service({slotLimit=8, moved=100,
            byIdentity={[key("minecraft:stone")]=64, [key("minecraft:coal")]=20,
                [key("minecraft:dirt")]=16}})
        local ctx = context({[1]={"minecraft:stone",64}, [4]={"minecraft:coal",20},
            [9]={"minecraft:dirt",16}})
        imports:tick(ctx); imports:tick(ctx); imports:tick(ctx)
        T.equal(transfer.calls, 1, "one batch serves every Drop-off slot")
        local identities = {}
        for _, step in ipairs(transfer.submitted) do identities[step.identity_key] = true end
        T.truthy(identities[key("minecraft:stone")])
        T.truthy(identities[key("minecraft:coal")])
        T.truthy(identities[key("minecraft:dirt")])
        T.equal(imports:status().state, "VERIFYING",
            "the batch is issued once and awaits a single verification")
    end},

    {name="the slot batch limit bounds how many Drop-off slots join a batch", run=function()
        local imports, transfer = service({slotLimit=2})
        local ctx = context({[1]={"minecraft:stone",10}, [2]={"minecraft:coal",10},
            [3]={"minecraft:dirt",10}, [4]={"minecraft:sand",10}})
        imports:tick(ctx); imports:tick(ctx); imports:tick(ctx)
        local identities = {}
        for _, step in ipairs(transfer.submitted) do identities[step.identity_key] = true end
        local count = 0
        for _ in pairs(identities) do count = count + 1 end
        T.equal(count, 2, "only two slots may join the batch")
        T.equal(#imports:status().sources, 2)
    end},

    {name="a slot batch limit of one reproduces single slot behaviour", run=function()
        local imports, transfer = service({slotLimit=1})
        local ctx = context({[1]={"minecraft:stone",10}, [2]={"minecraft:coal",10}})
        imports:tick(ctx); imports:tick(ctx); imports:tick(ctx)
        T.equal(#imports:status().sources, 1)
        T.equal(imports:status().source.identity_key, key("minecraft:stone"),
            "the lowest occupied slot is still chosen")
        for _, step in ipairs(transfer.submitted) do
            T.equal(step.identity_key, key("minecraft:stone"))
        end
    end},

    {name="two item types never plan into the same empty storage slot", run=function()
        -- Each source is planned against the same storage snapshot, so without reserving
        -- slots between plans both would claim the first empty slot.
        local imports, transfer = service({slotLimit=8})
        local ctx = context({[1]={"minecraft:stone",64}, [2]={"minecraft:coal",64},
            [3]={"minecraft:dirt",64}})
        imports:tick(ctx); imports:tick(ctx); imports:tick(ctx)
        T.equal(imports:status().state, "VERIFYING",
            "a mixed Drop-off must plan without colliding")
        local claimed = {}
        for _, step in ipairs(transfer.submitted) do
            local slotKey = step.destination_name .. ":" .. tostring(step.destination_slot)
            T.equal(claimed[slotKey], nil,
                "two steps both claimed " .. slotKey)
            claimed[slotKey] = true
        end
    end},

    {name="un-plannable low slots cannot hide importable ones behind them", run=function()
        -- Storage has room for cobblestone only. The two lower Drop-off slots hold a type
        -- that cannot be placed, and selection must still reach the slot that can.
        local imports, transfer = service({slotLimit=2})
        local ctx = context({[1]={"minecraft:stone",10}, [2]={"minecraft:stone",10},
            [3]={"minecraft:cobblestone",10}})
        ctx.storage = {{node_id="store", peripheral_name="store", health="READY", epoch=20,
            size=1, slots={[1]={identity_key=key("minecraft:cobblestone"), count=1}}}}
        for _ = 1, 12 do imports:tick(ctx) end
        T.truthy(transfer.submitted, "the importable slot must eventually be planned")
        for _, step in ipairs(transfer.submitted) do
            T.equal(step.identity_key, key("minecraft:cobblestone"),
                "only the placeable type can be planned")
        end
    end},

    {name="sources are chosen in ascending slot order", run=function()
        local imports = service({slotLimit=3})
        local ctx = context({[17]={"minecraft:stone",1}, [2]={"minecraft:coal",1},
            [9]={"minecraft:dirt",1}, [40]={"minecraft:sand",1}})
        imports:tick(ctx)
        local sources = imports:status().sources
        T.arrayEqual({sources[1].slot, sources[2].slot, sources[3].slot}, {2, 9, 17})
    end},

    {name="a pre-call change to one source drops only that source", run=function()
        local imports, transfer = service({slotLimit=3})
        local ctx = context({[1]={"minecraft:stone",10}, [2]={"minecraft:coal",10},
            [3]={"minecraft:dirt",10}})
        imports:tick(ctx)
        T.equal(#imports:status().sources, 3)
        -- a player takes the coal back out before anything was issued
        ctx.dropoff.slots[2] = nil
        imports:tick(ctx); imports:tick(ctx)
        T.equal(imports:status().state, "VERIFYING",
            "the surviving sources still import")
        local identities = {}
        for _, step in ipairs(transfer.submitted) do identities[step.identity_key] = true end
        T.equal(identities[key("minecraft:coal")], nil, "the vanished source is dropped")
        T.truthy(identities[key("minecraft:stone")])
        T.truthy(identities[key("minecraft:dirt")])
    end},

    {name="losing every source before any call abandons rather than wedging", run=function()
        local imports, transfer = service({slotLimit=3})
        local ctx = context({[1]={"minecraft:stone",10}, [2]={"minecraft:coal",10}})
        imports:tick(ctx)
        ctx.dropoff.slots[1], ctx.dropoff.slots[2] = nil, nil
        imports:tick(ctx)
        T.equal(imports:status().state, "IDLE")
        T.equal(transfer.calls, 0, "nothing may be issued for vanished sources")
        ctx.dropoff.slots[5] = {name="minecraft:sand", count=4,
            identity_key=key("minecraft:sand"), max_count=64}
        imports:tick(ctx)
        T.equal(imports:status().state, "PLANNING", "later Drop-off contents still import")
    end},

    {name="a completed multi source batch credits the measured total", run=function()
        local imports, transfer, alerts = service({slotLimit=3, moved=30,
            byIdentity={[key("minecraft:stone")]=10, [key("minecraft:coal")]=20}})
        local ctx = context({[1]={"minecraft:stone",10}, [2]={"minecraft:coal",20}})
        imports:tick(ctx); imports:tick(ctx); imports:tick(ctx)
        local result = imports:tick(ctx)
        T.equal(result.state, "COMPLETE")
        T.equal(result.moved, 30, "every source's measured movement is credited")
        T.equal(transfer.verify_calls, 1, "one verification served the whole batch")
        T.equal(#alerts:active(), 0, "a clean batch raises no alerts")
    end},

    {name="over-delivery is judged against the whole batch total", run=function()
        local imports, _, alerts = service({slotLimit=3, moved=999,
            byIdentity={[key("minecraft:stone")]=999}})
        local ctx = context({[1]={"minecraft:stone",10}, [2]={"minecraft:coal",20}})
        imports:tick(ctx); imports:tick(ctx); imports:tick(ctx); imports:tick(ctx)
        local active = alerts:active()
        T.equal(active[1].details.code, "OVER_DELIVERY")
        T.equal(active[1].severity, "critical")
    end},
}
