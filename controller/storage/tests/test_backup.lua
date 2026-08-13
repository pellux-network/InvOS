local Backup = require("app.backup")
local Store = require("shared.store")
local T = require("tests.mock_cc")

local function tokenCodec()
    local values, nextId = {}, 0
    return {
        encode = function(value)
            nextId = nextId + 1
            local token = "backup-token-" .. nextId
            values[token] = value
            return token
        end,
        decode = function(token)
            if not values[token] then error("invalid backup token") end
            return values[token]
        end,
    }
end

return {
    { name = "backup exports configuration and aliases only", run = function()
        local fsApi, codec = T.memoryFs(), tokenCodec()
        local store = Store.new(fsApi, codec, "storage/data")
        local config = { schema = 1, dropoff = "chest_0", journal = { unsafe = true } }
        local aliases = { schema = 1, items = { rock = "minecraft:stone" } }
        T.truthy(Backup.export(store, "disk", config, aliases))
        local payload = store:at("disk"):recover("invos-backup", Backup.validate)
        T.equal(payload.schema, 1)
        T.equal(payload.config, config)
        T.equal(payload.aliases, aliases)
        T.equal(payload.journal, nil)
        T.equal(payload.history, nil)
        T.equal(payload.metadata, nil)
        T.equal(payload.snapshots, nil)
        T.equal(payload.counts, nil)
    end },
    { name = "backup import validates the envelope before returning it", run = function()
        local fsApi, codec = T.memoryFs(), tokenCodec()
        local store = Store.new(fsApi, codec, "storage/data")
        T.truthy(store:at("disk"):write("invos-backup", {
            schema = 1,
            config = { schema = 1 },
            aliases = { schema = 1, items = {} },
        }, Backup.validate))
        local payload = Backup.import(store, "disk")
        T.equal(payload.config.schema, 1)
        T.equal(payload.aliases.schema, 1)
    end },
    { name = "backup rejects forbidden runtime state", run = function()
        local ok, reason = Backup.validate({
            schema = 1,
            config = { schema = 1 },
            aliases = { schema = 1, items = {} },
            journal = {},
        })
        T.equal(ok, nil)
        T.contains(reason, "forbidden field journal")
    end },
    { name = "missing backup is a recoverable import error", run = function()
        local store = Store.new(T.memoryFs(), tokenCodec(), "storage/data")
        local payload, reason = Backup.import(store, "disk")
        T.equal(payload, nil)
        T.contains(reason, "no valid invos-backup")
    end },
}
