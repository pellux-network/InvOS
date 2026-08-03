local M = {}

local function reason(code, message, retryable)
    return { code = code, message = message, retryable = retryable == true }
end

local function slotLimit(snapshot, slot, itemMaximum)
    local inventoryLimit = snapshot.slot_limits and snapshot.slot_limits[slot] or
        snapshot.default_limit or 64
    if itemMaximum then return math.min(inventoryLimit, itemMaximum) end
    return inventoryLimit
end

local function nodeLess(left, right)
    local leftPriority, rightPriority = left.priority or math.huge, right.priority or math.huge
    if leftPriority ~= rightPriority then return leftPriority < rightPriority end
    return tostring(left.node_id) < tostring(right.node_id)
end

local function exact(item, key)
    return item and item.identity_key == key
end

function M.planImport(source, storageSnapshots)
    if type(source) ~= "table" or type(source.count) ~= "number" or source.count < 1 or
        source.count % 1 ~= 0 or type(source.identity_key) ~= "string" then
        return {}, source and source.count or 0,
            reason("INVALID_SOURCE", "Drop-off source slot is invalid", false)
    end

    local nodes = {}
    for _, snapshot in ipairs(storageSnapshots or {}) do
        if snapshot.health == "READY" then nodes[#nodes + 1] = snapshot end
    end
    table.sort(nodes, nodeLess)
    if #nodes == 0 then
        return {}, source.count,
            reason("NO_HEALTHY_STORAGE", "No healthy storage node can accept items", true)
    end

    local remaining, plan = source.count, {}
    local moved = 0
    local function addStep(node, slot, capacity, preCount)
        if remaining <= 0 or capacity <= 0 then return end
        local amount = math.min(remaining, capacity)
        plan[#plan + 1] = {
            source_name = source.peripheral_name,
            source_slot = source.slot,
            source_epoch = source.epoch,
            source_pre_count = source.count - moved,
            destination_name = node.peripheral_name,
            destination_slot = slot,
            destination_epoch = node.epoch,
            destination_pre_count = preCount,
            identity_key = source.identity_key,
            limit = amount,
        }
        moved, remaining = moved + amount, remaining - amount
    end

    for _, node in ipairs(nodes) do
        local slots = {}
        for slot, item in pairs(node.slots or {}) do
            if exact(item, source.identity_key) and not (node.owned_slots and node.owned_slots[slot]) then
                slots[#slots + 1] = slot
            end
        end
        table.sort(slots)
        for _, slot in ipairs(slots) do
            local item = node.slots[slot]
            local capacity = slotLimit(node, slot, source.max_count) - item.count
            addStep(node, slot, capacity, item.count)
            if remaining == 0 then return plan, 0 end
        end
    end

    for _, node in ipairs(nodes) do
        for slot = 1, node.size do
            if not node.slots[slot] and not (node.owned_slots and node.owned_slots[slot]) then
                addStep(node, slot, slotLimit(node, slot, source.max_count), 0)
                if remaining == 0 then return plan, 0 end
            end
        end
    end
    return plan, remaining,
        reason("STORAGE_FULL", "Healthy storage capacity is full for this item", true)
end

function M.planRetrieval(identityKey, requested, index, pickup)
    if type(identityKey) ~= "string" or type(requested) ~= "number" or requested < 1 or
        requested % 1 ~= 0 then
        return {}, requested or 0, reason("INVALID_REQUEST", "Requested quantity is invalid", false)
    end
    if type(pickup) ~= "table" or pickup.health ~= "READY" then
        return {}, requested, reason("PICKUP_UNAVAILABLE", "Pickup is not ready", true)
    end

    local remaining, plan = requested, {}
    for _, source in ipairs(index:sources(identityKey)) do
        if not source.owned and remaining > 0 then
            local amount = math.min(remaining, source.count)
            plan[#plan + 1] = {
                source_name = source.peripheral_name,
                source_slot = source.slot,
                source_epoch = source.epoch,
                source_pre_count = source.count,
                destination_name = pickup.peripheral_name,
                identity_key = identityKey,
                limit = amount,
            }
            remaining = remaining - amount
        end
    end

    if remaining == 0 then return plan, 0 end
    return plan, remaining,
        reason("INSUFFICIENT_STOCK", "Live storage has less than the requested quantity", true)
end

return M
