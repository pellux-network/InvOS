local Codec = require("shared.codec")
local Store = require("shared.store")
local T = require("tests.mock_cc")

local function tokenCodec()
    local values, nextId = {}, 0
    return {
        encode = function(value)
            if value.fail_encode then error("injected encode failure") end
            nextId = nextId + 1
            local token = "token-" .. nextId
            values[token] = value
            return token
        end,
        decode = function(token)
            if token == "malformed" then error("malformed payload") end
            if values[token] == nil then error("unknown token") end
            return values[token]
        end,
    }
end

local function validate(value)
    if type(value) ~= "table" or value.schema ~= 1 or type(value.value) ~= "string" then
        return nil, "expected schema 1 string value"
    end
    return true
end

return {
    { name = "codec delegates serialization and rejects undecodable content", run = function()
        local api = {
            serialize = function(value) return "encoded:" .. value.value end,
            unserialize = function(value)
                if value == "encoded:ok" then return { value = "ok" } end
                return nil
            end,
        }
        local codec = Codec.new(api)
        T.equal(codec.encode({ value = "ok" }), "encoded:ok")
        T.equal(codec.decode("encoded:ok").value, "ok")
        T.fails(function() codec.decode("broken") end, "could not decode")
    end },
    { name = "interrupted replacement recovers the previous valid value", run = function()
        local fsApi = T.memoryFs()
        local store = Store.new(fsApi, tokenCodec(), "colossal/data")
        T.truthy(store:write("config", { schema = 1, value = "old" }, validate))
        fsApi.failMoveTo = "colossal/data/config.lua"
        local ok, reason = store:write("config", { schema = 1, value = "new" }, validate)
        T.equal(ok, nil)
        T.contains(reason, "activate config")
        local recovered = store:recover("config", validate)
        T.equal(recovered.value, "old")
    end },
    { name = "recovery falls back from malformed active data", run = function()
        local codec = tokenCodec()
        local fsApi = T.memoryFs()
        local store = Store.new(fsApi, codec, "colossal/data")
        T.truthy(store:write("config", { schema = 1, value = "safe" }, validate))
        fsApi.files["colossal/data/config.previous.lua"] = fsApi.files["colossal/data/config.lua"]
        fsApi.files["colossal/data/config.lua"] = "malformed"
        local recovered, reason = store:recover("config", validate)
        T.equal(reason, "recovered previous config")
        T.equal(recovered.value, "safe")
    end },
    { name = "write rejects invalid values before touching active data", run = function()
        local fsApi = T.memoryFs()
        local store = Store.new(fsApi, tokenCodec(), "colossal/data")
        T.truthy(store:write("config", { schema = 1, value = "safe" }, validate))
        local active = fsApi.files["colossal/data/config.lua"]
        local ok, reason = store:write("config", { schema = 2, value = "bad" }, validate)
        T.equal(ok, nil)
        T.contains(reason, "refusing invalid config")
        T.equal(fsApi.files["colossal/data/config.lua"], active)
    end },
    { name = "encode failure leaves active data recoverable", run = function()
        local fsApi = T.memoryFs()
        local store = Store.new(fsApi, tokenCodec(), "colossal/data")
        T.truthy(store:write("config", { schema = 1, value = "safe" }, validate))
        local ok, reason = store:write("config",
            { schema = 1, value = "bad", fail_encode = true }, validate)
        T.equal(ok, nil)
        T.contains(reason, "encode config")
        T.equal(store:recover("config", validate).value, "safe")
    end },
    { name = "missing journal is reported as unsafe", run = function()
        local store = Store.new(T.memoryFs(), tokenCodec(), "colossal/data")
        local value, reason = store:recover("journal", validate)
        T.equal(value, nil)
        T.equal(reason, "unsafe journal unavailable")
    end },
    { name = "store can create a scoped writer without changing the original", run = function()
        local fsApi = T.memoryFs()
        local store = Store.new(fsApi, tokenCodec(), "colossal/data")
        local disk = store:at("disk")
        T.truthy(disk:write("backup", { schema = 1, value = "copy" }, validate))
        T.equal(fsApi.exists("disk/backup.lua"), true)
        T.equal(fsApi.exists("colossal/data/backup.lua"), false)
    end },
}
