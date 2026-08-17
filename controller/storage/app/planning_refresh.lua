local M = {}

local function canonical(values)
    assert(type(values) == "table", "planning node IDs are required")
    local result, seen = {}, {}
    for _, value in ipairs(values) do
        assert(type(value) == "string" and value ~= "", "planning node ID is invalid")
        if not seen[value] then
            seen[value] = true
            result[#result + 1] = value
        end
    end
    table.sort(result)
    return result
end

local function asSet(values)
    local result = {}
    for _, value in ipairs(values) do result[value] = true end
    return result
end

local function isSubset(values, superset)
    local available = asSet(superset)
    for _, value in ipairs(values) do
        if not available[value] then return false end
    end
    return true
end

local function union(left, right)
    local result = {}
    for _, value in ipairs(left) do result[#result + 1] = value end
    for _, value in ipairs(right) do result[#result + 1] = value end
    return canonical(result)
end

local function validateState(state)
    if type(state) ~= "table" or (state.mode ~= "targeted" and state.mode ~= "full") or
        type(state.retargets) ~= "number" or state.retargets < 0 or
        state.retargets % 1 ~= 0 then
        error("planning refresh state is invalid", 3)
    end
    canonical(state.storage_node_ids)
end

function M.advance(previous, candidateNodeIds, hasPlan)
    assert(type(hasPlan) == "boolean", "planning result flag is required")
    local candidate = canonical(candidateNodeIds)
    if previous then validateState(previous) end

    if not hasPlan then
        if previous and previous.mode == "full" then return "FINAL_NO_PLAN", previous end
        return "SCAN", {mode="full", storage_node_ids={},
            retargets=previous and previous.retargets or 0}
    end
    assert(#candidate > 0, "a viable plan requires storage nodes")

    if not previous then
        return "SCAN", {mode="targeted", storage_node_ids=candidate, retargets=0}
    end
    if previous.mode == "full" or isSubset(candidate, previous.storage_node_ids) then
        return "COMMIT", previous
    end
    if previous.retargets < 1 then
        return "SCAN", {mode="targeted",
            storage_node_ids=union(previous.storage_node_ids, candidate), retargets=1}
    end
    return "SCAN", {mode="full", storage_node_ids={}, retargets=previous.retargets}
end

local function failure(code, message, nodeId)
    return {code=code, message=message, node_id=nodeId}
end

function M.names(state, storageSnapshots, endpointSnapshot)
    local ok, problem = pcall(validateState, state)
    if not ok then return nil, failure("INVALID_PLANNING_SCOPE", tostring(problem)) end
    if type(storageSnapshots) ~= "table" or type(endpointSnapshot) ~= "table" or
        type(endpointSnapshot.node_id) ~= "string" or endpointSnapshot.node_id == "" then
        return nil, failure("INVALID_PLANNING_SCOPE", "planning snapshots are invalid")
    end

    local available, all = {}, {}
    for _, snapshot in ipairs(storageSnapshots) do
        local nodeId = type(snapshot) == "table" and snapshot.node_id
        if type(nodeId) ~= "string" or nodeId == "" or available[nodeId] then
            return nil, failure("INVALID_PLANNING_SCOPE", "storage snapshot IDs are invalid", nodeId)
        end
        available[nodeId] = true
        all[#all + 1] = nodeId
    end

    local names = state.mode == "full" and all or canonical(state.storage_node_ids)
    if state.mode == "targeted" then
        for _, nodeId in ipairs(names) do
            if not available[nodeId] then
                return nil, failure("PLANNING_SCOPE_MISSING",
                    "targeted storage node has no snapshot", nodeId)
            end
        end
    end
    names[#names + 1] = endpointSnapshot.node_id
    return canonical(names)
end

return M
