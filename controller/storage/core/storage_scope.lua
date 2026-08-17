local M = {}

local function failure(code, message, peripheralName)
    return {
        code = code,
        message = message,
        peripheral_name = peripheralName,
    }
end

function M.select(kind, steps, snapshots)
    local endpoint
    if kind == "request" then
        endpoint = "source_name"
    elseif kind == "import" then
        endpoint = "destination_name"
    else
        return nil, nil, failure("INVALID_STORAGE_SCOPE", "unknown operation kind")
    end
    if type(steps) ~= "table" or type(snapshots) ~= "table" then
        return nil, nil, failure("INVALID_STORAGE_SCOPE", "steps and snapshots are required")
    end

    local byPeripheral, nodeIds = {}, {}
    for _, snapshot in ipairs(snapshots) do
        if type(snapshot) ~= "table" or type(snapshot.node_id) ~= "string" or
            snapshot.node_id == "" or type(snapshot.peripheral_name) ~= "string" or
            snapshot.peripheral_name == "" then
            return nil, nil, failure("INVALID_STORAGE_SCOPE", "storage snapshot is malformed")
        end
        if byPeripheral[snapshot.peripheral_name] or nodeIds[snapshot.node_id] then
            return nil, nil, failure("DUPLICATE_STORAGE_PERIPHERAL",
                "storage snapshots contain a duplicate mapping", snapshot.peripheral_name)
        end
        byPeripheral[snapshot.peripheral_name] = snapshot
        nodeIds[snapshot.node_id] = true
    end

    local touched, seen = {}, {}
    for _, step in ipairs(steps) do
        local name = type(step) == "table" and step[endpoint]
        if type(name) ~= "string" or name == "" then
            return nil, nil, failure("INVALID_STORAGE_SCOPE",
                "transfer step has no storage endpoint")
        end
        local snapshot = byPeripheral[name]
        if not snapshot then
            return nil, nil, failure("STORAGE_SCOPE_MISSING",
                "touched storage peripheral has no snapshot", name)
        end
        if not seen[snapshot.node_id] then
            seen[snapshot.node_id] = true
            touched[#touched + 1] = snapshot
        end
    end
    if #touched == 0 then
        return nil, nil, failure("INVALID_STORAGE_SCOPE", "storage scope is empty")
    end

    table.sort(touched, function(left, right) return left.node_id < right.node_id end)
    local ids = {}
    for index, snapshot in ipairs(touched) do ids[index] = snapshot.node_id end
    return touched, ids
end

return M
