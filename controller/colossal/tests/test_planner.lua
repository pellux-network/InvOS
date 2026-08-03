local Identity = require("core.identity")
local Index = require("core.index")
local Planner = require("core.planner")
local T = require("tests.mock_cc")

local function item(name, nbt, count)
    return { name=name, nbt=nbt, count=count, identity_key=Identity.key(name, nbt) }
end

local function storage(id, priority, size, slots, options)
    options = options or {}
    return {
        node_id=id, peripheral_name="store_"..id, priority=priority, size=size,
        slots=slots or {}, slot_limits=options.slot_limits or {},
        default_limit=options.default_limit or 64, epoch=options.epoch or 10,
        health=options.health or "READY", owned_slots=options.owned_slots or {},
    }
end

local function pickup(size, slots, options)
    local value = storage("pickup", 0, size, slots, options)
    value.peripheral_name = "pickup"
    return value
end

local function indexFrom(nodes)
    return Index.build(nodes, {})
end

return {
    { name = "retrieval spans source slots and exact pickup capacity", run = function()
        local key = Identity.key("minecraft:stone", nil)
        local index = indexFrom({
            storage("a", 1, 3, { [4] = item("minecraft:stone", nil, 64) }),
            storage("b", 2, 3, { [7] = item("minecraft:stone", nil, 50) }),
        })
        local plan, remainder = Planner.planRetrieval(key, 90, index, pickup(4, {}))
        T.equal(remainder, 0)
        T.equal(plan[1].source_slot, 4)
        T.equal(plan[1].destination_slot, 1)
        T.equal(plan[1].limit, 64)
        T.equal(plan[2].source_slot, 7)
        T.equal(plan[2].destination_slot, 2)
        T.equal(plan[2].limit, 26)
    end },
    { name = "import fills exact matching stacks before empty priority capacity", run = function()
        local source = {
            peripheral_name="drop", slot=2, epoch=20,
            name="minecraft:stone", nbt=nil, count=70,
            identity_key=Identity.key("minecraft:stone", nil), max_count=64,
        }
        local high = storage("high", 1, 3, {
            [1] = item("minecraft:stone", nil, 60),
            [2] = item("minecraft:dirt", nil, 64),
        })
        local low = storage("low", 2, 3, {})
        local plan, remainder = Planner.planImport(source, { low, high })
        T.equal(remainder, 0)
        T.equal(plan[1].destination_name, "store_high")
        T.equal(plan[1].destination_slot, 1)
        T.equal(plan[1].limit, 4)
        T.equal(plan[2].destination_name, "store_high")
        T.equal(plan[2].destination_slot, 3)
        T.equal(plan[2].limit, 64)
        T.equal(plan[3].destination_name, "store_low")
        T.equal(plan[3].destination_slot, 1)
        T.equal(plan[3].limit, 2)
    end },
    { name = "retrieval respects incompatible pickup slots and per-slot limits", run = function()
        local key = Identity.key("minecraft:ender_pearl", nil)
        local index = indexFrom({ storage("a", 1, 2,
            { [1] = item("minecraft:ender_pearl", nil, 32) }) })
        local target = pickup(3, {
            [1] = item("minecraft:dirt", nil, 64),
            [2] = item("minecraft:ender_pearl", nil, 12),
        }, { slot_limits = { [2]=16, [3]=16 }, default_limit=16 })
        local plan, remainder = Planner.planRetrieval(key, 20, index, target)
        T.equal(remainder, 0)
        T.equal(plan[1].destination_slot, 2)
        T.equal(plan[1].limit, 4)
        T.equal(plan[2].destination_slot, 3)
        T.equal(plan[2].limit, 16)
    end },
    { name = "retrieval reports full pickup without planning movement", run = function()
        local key = Identity.key("minecraft:stone", nil)
        local index = indexFrom({ storage("a", 1, 1,
            { [1] = item("minecraft:stone", nil, 64) }) })
        local plan, remainder, reason = Planner.planRetrieval(key, 1, index,
            pickup(1, { [1] = item("minecraft:dirt", nil, 64) }))
        T.equal(#plan, 0)
        T.equal(remainder, 1)
        T.equal(reason.code, "PICKUP_FULL")
        T.equal(reason.retryable, true)
    end },
    { name = "retrieval reports unavailable stock after planning only what exists", run = function()
        local key = Identity.key("minecraft:stone", nil)
        local index = indexFrom({ storage("a", 1, 1,
            { [1] = item("minecraft:stone", nil, 12) }) })
        local plan, remainder, reason = Planner.planRetrieval(key, 20, index, pickup(2, {}))
        T.equal(#plan, 1)
        T.equal(plan[1].limit, 12)
        T.equal(remainder, 8)
        T.equal(reason.code, "INSUFFICIENT_STOCK")
    end },
    { name = "import excludes stale and owned destinations", run = function()
        local source = {
            peripheral_name="drop", slot=1, epoch=1,
            name="minecraft:stone", count=32,
            identity_key=Identity.key("minecraft:stone", nil), max_count=64,
        }
        local stale = storage("stale", 1, 2, {}, { health="STALE" })
        local ready = storage("ready", 2, 2, {}, { owned_slots={ [1]=true } })
        local plan, remainder = Planner.planImport(source, { stale, ready })
        T.equal(remainder, 0)
        T.equal(#plan, 1)
        T.equal(plan[1].destination_name, "store_ready")
        T.equal(plan[1].destination_slot, 2)
    end },
    { name = "import reports full healthy pool and preserves remainder", run = function()
        local source = {
            peripheral_name="drop", slot=1, epoch=1,
            name="minecraft:stone", count=16,
            identity_key=Identity.key("minecraft:stone", nil), max_count=64,
        }
        local full = storage("full", 1, 1, { [1] = item("minecraft:dirt", nil, 64) })
        local plan, remainder, reason = Planner.planImport(source, { full })
        T.equal(#plan, 0)
        T.equal(remainder, 16)
        T.equal(reason.code, "STORAGE_FULL")
    end },
    { name = "planner never mixes NBT variants", run = function()
        local healing = Identity.key("minecraft:potion", "healing")
        local index = indexFrom({ storage("a", 1, 2, {
            [1] = item("minecraft:potion", "strength", 5),
            [2] = item("minecraft:potion", "healing", 3),
        }) })
        local plan = Planner.planRetrieval(healing, 3, index, pickup(1, {}))
        T.equal(#plan, 1)
        T.equal(plan[1].source_slot, 2)
        T.equal(plan[1].identity_key, healing)
    end },
}
