local Registry = require("core.registry")
local T = require("tests.mock_cc")

local inventoryMethods = {
    size = true, list = true, getItemDetail = true, getItemLimit = true,
    pushItems = true, pullItems = true,
}

local function config()
    return {
        dropoff = { peripheral_name = "drop" },
        pickup = { peripheral_name = "pickup" },
        storage = {
            { id = "main", peripheral_name = "big_0", label = "Main", priority = 1, enabled = true },
            { id = "reserve", peripheral_name = "big_1", label = "Reserve", priority = 2, enabled = false },
        },
    }
end

return {
    { name = "registry reconciles configured and unconfigured inventories", run = function()
        local states = Registry.new(config()):reconcile({
            { name = "drop", methods = inventoryMethods },
            { name = "pickup", methods = inventoryMethods },
            { name = "big_0", methods = inventoryMethods },
            { name = "big_1", methods = inventoryMethods },
            { name = "spare", methods = inventoryMethods },
        }, 1000)
        T.equal(states.dropoff.state, "SCANNING")
        T.equal(states.pickup.state, "SCANNING")
        T.equal(states.storage.main.state, "SCANNING")
        T.equal(states.storage.main.label, "Main")
        T.equal(states.storage.reserve.state, "DISABLED")
        T.equal(states.discovered.spare.state, "DISCOVERED")
    end },
    { name = "registry keeps missing bindings offline without guessing a replacement", run = function()
        local states = Registry.new(config()):reconcile({
            { name = "drop", methods = inventoryMethods },
            { name = "pickup", methods = inventoryMethods },
            { name = "renamed_big_0", methods = inventoryMethods, size = 3075 },
        }, 2000)
        T.equal(states.storage.main.state, "OFFLINE")
        T.equal(states.storage.main.peripheral_name, "big_0")
        T.equal(states.discovered.renamed_big_0.state, "DISCOVERED")
    end },
    { name = "registry validation rejects role collisions", run = function()
        local value = config()
        value.pickup.peripheral_name = value.dropoff.peripheral_name
        local ok, reason = Registry.validate(value)
        T.equal(ok, nil)
        T.equal(reason.code, "ROLE_COLLISION")
    end },
    { name = "registry validation rejects duplicate storage bindings", run = function()
        local value = config()
        value.storage[2].enabled = true
        value.storage[2].peripheral_name = "big_0"
        local ok, reason = Registry.validate(value)
        T.equal(ok, nil)
        T.equal(reason.code, "DUPLICATE_BINDING")
    end },
    { name = "registry rebind changes only the requested logical node", run = function()
        local registry = Registry.new(config())
        T.truthy(registry:rebind("storage", "main", "renamed_big_0"))
        local value = registry:config()
        T.equal(value.storage[1].peripheral_name, "renamed_big_0")
        T.equal(value.storage[2].peripheral_name, "big_1")
        T.equal(value.dropoff.peripheral_name, "drop")
    end },
    { name = "registry accepts an optional craft buffer binding", run = function()
        local value = config()
        value.craft_buffer = { peripheral_name = "buffer" }
        T.equal(Registry.validate(value), true)
        local states = Registry.new(value):reconcile({
            { name = "drop", methods = inventoryMethods },
            { name = "pickup", methods = inventoryMethods },
            { name = "buffer", methods = inventoryMethods },
            { name = "big_0", methods = inventoryMethods },
        }, 3000)
        T.equal(states.craft_buffer.state, "SCANNING")
        T.equal(states.craft_buffer.role, "craft_buffer")
        T.equal(states.discovered.buffer, nil, "a bound buffer is not also discovered")
    end },
    { name = "a configuration without a craft buffer stays valid", run = function()
        T.equal(Registry.validate(config()), true)
        local states = Registry.new(config()):reconcile({}, 1000)
        T.equal(states.craft_buffer, nil)
    end },
    { name = "the craft buffer cannot collide with another role", run = function()
        for _, taken in ipairs({ "drop", "pickup", "big_0" }) do
            local value = config()
            value.craft_buffer = { peripheral_name = taken }
            local ok, reason = Registry.validate(value)
            T.equal(ok, nil, taken)
            T.equal(reason.code, "DUPLICATE_BINDING", taken)
        end
    end },
    { name = "a malformed craft buffer binding is rejected", run = function()
        for _, binding in ipairs({ {}, { peripheral_name = "" }, { peripheral_name = 7 } }) do
            local value = config()
            value.craft_buffer = binding
            T.equal(Registry.validate(value), nil)
        end
    end },
    { name = "an offline craft buffer reports OFFLINE rather than vanishing", run = function()
        local value = config()
        value.craft_buffer = { peripheral_name = "buffer" }
        local states = Registry.new(value):reconcile({
            { name = "drop", methods = inventoryMethods },
        }, 1000)
        T.equal(states.craft_buffer.state, "OFFLINE")
        T.equal(states.craft_buffer.peripheral_name, "buffer")
    end },

}
