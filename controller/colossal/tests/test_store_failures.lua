local Store = require("shared.store")
local T = require("tests.mock_cc")

local codec = {
    encode = function(value) return value.value end,
    decode = function(value) return { schema = 1, value = value } end,
}

local function validate(value)
    if type(value) ~= "table" or value.schema ~= 1 or type(value.value) ~= "string" then
        return nil, "invalid value"
    end
    return true
end

return {
    { name = "directory failure is returned instead of escaping", run = function()
        local fsApi = T.memoryFs()
        fsApi.makeDir = function() error("disk removed") end
        local store = Store.new(fsApi, codec, "colossal/data")
        local callOk, written, reason = pcall(store.write, store,
            "config", { schema = 1, value = "safe" }, validate)
        T.equal(callOk, true)
        T.equal(written, nil)
        T.contains(reason, "create store directory")
        T.contains(reason, "disk removed")
    end },
    { name = "open failure is returned during recovery", run = function()
        local fsApi = T.memoryFs()
        fsApi.open = function() error("drive detached") end
        local store = Store.new(fsApi, codec, "colossal/data")
        local callOk, value, reason = pcall(store.recover, store, "config", validate)
        T.equal(callOk, true)
        T.equal(value, nil)
        T.equal(reason, "no valid config available")
    end },
}
