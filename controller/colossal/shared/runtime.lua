local M = {}

function M.safeCall(label, fn, ...)
    local result = { pcall(fn, ...) }
    local ok = table.remove(result, 1)
    if not ok then return nil, label .. ": " .. tostring(result[1]) end
    return true, table.unpack(result)
end

function M.verifyInstallation(osApi, installation)
    if not installation then return true end
    local id = osApi.getComputerID()
    local label = osApi.getComputerLabel()
    if id ~= installation.computer_id or label ~= installation.computer_label then
        return nil, ("identity mismatch: expected #%s %s, got #%s %s"):format(
            tostring(installation.computer_id), tostring(installation.computer_label),
            tostring(id), tostring(label))
    end
    return true
end

return M
