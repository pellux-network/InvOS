local Identity = require("core.identity")
local Index = require("core.index")
local T = require("tests.mock_cc")

local function item(name, nbt, count)
    return { name = name, nbt = nbt, count = count, identity_key = Identity.key(name, nbt) }
end

local function snapshot(id, health, priority, slots)
    return {
        node_id = id,
        peripheral_name = "inventory_" .. id,
        epoch = 100,
        health = health,
        priority = priority,
        slots = slots,
    }
end

return {
    { name = "index pools ready nodes and excludes stale quantities", run = function()
        local stone = Identity.key("minecraft:stone", nil)
        local index = Index.build({
            snapshot("a", "READY", 1, { [1] = item("minecraft:stone", nil, 64) }),
            snapshot("b", "READY", 2, { [9] = item("minecraft:stone", nil, 12) }),
            snapshot("c", "STALE", 3, { [2] = item("minecraft:stone", nil, 99) }),
        }, {})
        T.equal(index:quantity(stone), 76)
        T.equal(#index:sources(stone), 2)
        T.equal(index:sources(stone)[1].node_id, "a")
    end },
    { name = "index keeps NBT variants as separate identities", run = function()
        local index = Index.build({ snapshot("a", "READY", 1, {
            [1] = item("minecraft:potion", "healing", 3),
            [2] = item("minecraft:potion", "strength", 5),
        }) }, {})
        T.equal(index:quantity(Identity.key("minecraft:potion", "healing")), 3)
        T.equal(index:quantity(Identity.key("minecraft:potion", "strength")), 5)
        T.equal(#index:items(), 2)
    end },
    { name = "index orders sources by priority node and slot", run = function()
        local key = Identity.key("minecraft:stone", nil)
        local index = Index.build({
            snapshot("z", "READY", 2, { [2] = item("minecraft:stone", nil, 1) }),
            snapshot("b", "READY", 1, { [8] = item("minecraft:stone", nil, 1) }),
            snapshot("a", "READY", 1, {
                [9] = item("minecraft:stone", nil, 1),
                [3] = item("minecraft:stone", nil, 1),
            }),
        }, {})
        local sources = index:sources(key)
        T.equal(sources[1].node_id, "a")
        T.equal(sources[1].slot, 3)
        T.equal(sources[2].node_id, "a")
        T.equal(sources[2].slot, 9)
        T.equal(sources[3].node_id, "b")
        T.equal(sources[4].node_id, "z")
    end },
    { name = "index accessors do not expose mutable stock truth", run = function()
        local key = Identity.key("minecraft:stone", nil)
        local sourceSnapshot = snapshot("a", "READY", 1,
            { [1] = item("minecraft:stone", nil, 64) })
        local index = Index.build({ sourceSnapshot }, {})
        local sources = index:sources(key)
        local items = index:items()
        sources[1].count = 1
        items[1].quantity = 2
        sourceSnapshot.slots[1].count = 3
        T.equal(index:quantity(key), 64)
        T.equal(index:sources(key)[1].count, 64)
        T.equal(index:items()[1].quantity, 64)
    end },
    { name = "index applies cached display metadata and aliases", run = function()
        local key = Identity.key("minecraft:cobblestone", nil)
        local index = Index.build({ snapshot("a", "READY", 1,
            { [1] = item("minecraft:cobblestone", nil, 64) }) }, {
            [key] = { display_name = "Cobblestone", max_count = 64, aliases = { "cobble" } },
        })
        local value = index:items()[1]
        T.equal(value.display_name, "Cobblestone")
        T.equal(value.max_count, 64)
        T.arrayEqual(value.aliases, { "cobble" })
    end },
    { name = "metadata enrichment is budgeted and uses one representative per identity", run = function()
        local index = Index.build({ snapshot("a", "READY", 1, {
            [1] = item("minecraft:stone", nil, 64),
            [2] = item("minecraft:dirt", nil, 32),
        }) }, {})
        local calls = {}
        local registry = {
            getItemDetail = function(_, peripheralName, slot)
                calls[#calls + 1] = peripheralName .. ":" .. slot
                if slot == 1 then return true, { displayName = "Stone", maxCount = 64 } end
                return nil, "detail unavailable"
            end,
        }
        local state = Index.enrichStep(index, registry, 1)
        T.equal(#calls, 1)
        T.equal(state.done, false)
        state = Index.enrichStep(index, registry, 1, state)
        T.equal(#calls, 2)
        T.equal(state.done, true)
        T.equal(state.metadata[Identity.key("minecraft:stone", nil)].display_name, "Stone")
        T.equal(#state.failures, 1)
        T.equal(state.failures[1].retryable, true)
        T.equal(index:quantity(Identity.key("minecraft:dirt", nil)), 32)
    end },
}
