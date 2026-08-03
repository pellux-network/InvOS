local Identity = require("core.identity")
local T = require("tests.mock_cc")

return {
    { name = "identity key separates registry name and absent NBT", run = function()
        T.equal(Identity.key("minecraft:stone", nil), "minecraft:stone\0-")
    end },
    { name = "identity key keeps NBT variants distinct", run = function()
        T.notEqual(Identity.key("minecraft:potion", "abc"),
            Identity.key("minecraft:potion", "def"))
    end },
    { name = "identity rejects malformed inventory items", run = function()
        T.fails(function() Identity.fromItem({ count = 3 }) end, "item name is required")
        T.fails(function() Identity.fromItem({ name = "minecraft:stone", nbt = 7 }) end,
            "item NBT must be a string or nil")
    end },
    { name = "identity copies only stable identity fields", run = function()
        local result = Identity.fromItem({
            name = "minecraft:stone", nbt = "hash", count = 64, displayName = "Stone",
        })
        T.equal(result.name, "minecraft:stone")
        T.equal(result.nbt, "hash")
        T.equal(result.key, Identity.key("minecraft:stone", "hash"))
        T.equal(result.count, nil)
    end },
}
