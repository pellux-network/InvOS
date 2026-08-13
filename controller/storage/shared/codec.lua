local M = {}

function M.new(textutilsApi)
    assert(type(textutilsApi) == "table", "textutils API is required")
    assert(type(textutilsApi.serialize) == "function", "textutils.serialize is required")
    assert(type(textutilsApi.unserialize) == "function", "textutils.unserialize is required")

    return {
        encode = function(value)
            local encoded = textutilsApi.serialize(value, { compact = true })
            if type(encoded) ~= "string" then error("serialize returned non-string content", 0) end
            return encoded
        end,
        decode = function(encoded)
            if type(encoded) ~= "string" then error("encoded content must be a string", 0) end
            local value = textutilsApi.unserialize(encoded)
            if value == nil then error("could not decode serialized content", 0) end
            return value
        end,
    }
end

return M
