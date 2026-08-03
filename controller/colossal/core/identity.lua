local M = {}

function M.key(name, nbt)
    if type(name) ~= "string" or name == "" then error("item name is required", 2) end
    if nbt ~= nil and type(nbt) ~= "string" then error("item NBT must be a string or nil", 2) end
    return name .. "\0" .. (nbt or "-")
end

function M.fromItem(item)
    if type(item) ~= "table" then error("item table is required", 2) end
    local key = M.key(item.name, item.nbt)
    return { key = key, name = item.name, nbt = item.nbt }
end

return M
