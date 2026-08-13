local M = {}

local forbidden = {
    journal = true,
    history = true,
    metadata = true,
    snapshots = true,
    counts = true,
}

function M.validate(value)
    if type(value) ~= "table" or value.schema ~= 1 then
        return nil, "backup schema must be 1"
    end
    if type(value.config) ~= "table" then return nil, "backup config is required" end
    if type(value.aliases) ~= "table" then return nil, "backup aliases are required" end
    for field in pairs(forbidden) do
        if value[field] ~= nil then return nil, "forbidden field " .. field end
    end
    for field in pairs(value) do
        if field ~= "schema" and field ~= "config" and field ~= "aliases" then
            return nil, "unexpected backup field " .. tostring(field)
        end
    end
    return true
end

function M.export(store, mount, config, aliases)
    local payload = { schema = 1, config = config, aliases = aliases }
    return store:at(mount):write("invos-backup", payload, M.validate)
end

function M.import(store, mount)
    return store:at(mount):recover("invos-backup", M.validate)
end

return M
