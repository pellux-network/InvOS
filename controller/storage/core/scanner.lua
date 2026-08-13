local Identity = require("core.identity")
local Runtime = require("shared.runtime")

local Scanner = {}
Scanner.__index = Scanner

local function clean(message)
    return tostring(message):gsub("[%c]+", " "):sub(1, 240)
end

local function failure(code, message, node)
    return { code = code, message = clean(message), node_id = node and node.id or nil }
end

function Scanner.new(peripheralApi, clock)
    assert(type(peripheralApi) == "table", "peripheral API is required")
    assert(type(clock) == "function", "clock is required")
    return setmetatable({ peripheral = peripheralApi, clock = clock }, Scanner)
end

function Scanner:begin(node)
    if type(node) ~= "table" or type(node.id) ~= "string" or
        type(node.peripheral_name) ~= "string" then
        return { failed = failure("INVALID_NODE", "scan node binding is invalid", node), node = node }
    end

    local wrappedOk, inventory = pcall(self.peripheral.wrap, node.peripheral_name)
    if not wrappedOk then
        return { failed = failure("PERIPHERAL_ERROR", inventory, node), node = node }
    end
    if type(inventory) ~= "table" then
        return { failed = failure("PERIPHERAL_MISSING",
            "peripheral " .. node.peripheral_name .. " is unavailable", node), node = node }
    end
    if type(inventory.size) ~= "function" or type(inventory.list) ~= "function" then
        return { failed = failure("PERIPHERAL_INVALID",
            "peripheral does not provide size and list", node), node = node }
    end

    local sizeOk, size = Runtime.safeCall("size " .. node.id, inventory.size)
    if not sizeOk then
        return { failed = failure("PERIPHERAL_ERROR", size, node), node = node }
    end
    if type(size) ~= "number" or size < 1 or size % 1 ~= 0 then
        return { failed = failure("INVALID_SIZE", "size returned " .. tostring(size), node), node = node }
    end

    local listOk, listed = Runtime.safeCall("list " .. node.id, inventory.list)
    if not listOk then
        return { failed = failure("PERIPHERAL_ERROR", listed, node), node = node }
    end
    if type(listed) ~= "table" then
        return { failed = failure("INVALID_LIST", "list returned " .. type(listed), node), node = node }
    end

    -- The import service consumes the lowest occupied Drop-off slot, so that is the only
    -- slot whose stack limit is ever read. Detailing the rest costs one peripheral call
    -- each and nothing reads the result.
    local detailSlot
    for slot in pairs(listed) do
        if type(slot) == "number" and (not detailSlot or slot < detailSlot) then detailSlot = slot end
    end

    return {
        node = node,
        inventory = inventory,
        listed = listed,
        size = size,
        epoch = self.clock(),
        next_key = nil,
        detail_slot = detailSlot,
        slots = {},
        occupied = 0,
    }
end

local function stackLimit(scan, slot, listed)
    if scan.node.role ~= "dropoff" then return true end
    if slot ~= scan.detail_slot then return true end
    if type(scan.inventory.getItemDetail) ~= "function" then
        return nil, failure("PERIPHERAL_INVALID",
            "Drop-off does not provide getItemDetail", scan.node)
    end
    local detailOk, detail = Runtime.safeCall("detail " .. scan.node.id .. " slot " .. slot,
        scan.inventory.getItemDetail, slot)
    if not detailOk then return nil, failure("PERIPHERAL_ERROR", detail, scan.node) end
    if type(detail) ~= "table" then
        return nil, failure("DETAIL_MISSING",
            "Drop-off slot " .. slot .. " no longer has item details", scan.node)
    end
    if detail.name ~= listed.name or detail.count ~= listed.count or detail.nbt ~= listed.nbt then
        return nil, failure("DETAIL_MISMATCH",
            "Drop-off slot " .. slot .. " changed during its scan", scan.node)
    end
    if type(detail.maxCount) ~= "number" or detail.maxCount < 1 or detail.maxCount % 1 ~= 0 then
        return nil, failure("INVALID_MAX_COUNT",
            "Drop-off slot " .. slot .. " returned invalid maxCount", scan.node)
    end
    return true, detail.maxCount
end

function Scanner:step(scan, budget)
    if type(scan) ~= "table" then
        return true, nil, failure("INVALID_SCAN", "scan state is required")
    end
    if scan.failed then return true, nil, scan.failed end
    if type(budget) ~= "number" or budget < 1 or budget % 1 ~= 0 then
        return true, nil, failure("INVALID_BUDGET", "scan budget must be a positive integer", scan.node)
    end

    for _ = 1, budget do
        local slot, item = next(scan.listed, scan.next_key)
        if slot == nil then
            return true, {
                node_id = scan.node.id,
                peripheral_name = scan.node.peripheral_name,
                epoch = scan.epoch,
                size = scan.size,
                slots = scan.slots,
                occupied = scan.occupied,
                health = "READY",
            }
        end
        scan.next_key = slot
        if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 1 or slot > scan.size then
            return true, nil, failure("INVALID_SLOT", "invalid inventory slot " .. tostring(slot), scan.node)
        end
        if type(item) ~= "table" or type(item.name) ~= "string" or item.name == "" then
            return true, nil, failure("INVALID_ITEM", "slot " .. slot .. " has no item name", scan.node)
        end
        if type(item.count) ~= "number" or item.count % 1 ~= 0 or item.count < 1 then
            return true, nil, failure("INVALID_COUNT", "slot " .. slot .. " has count " ..
                tostring(item.count), scan.node)
        end
        if item.nbt ~= nil and type(item.nbt) ~= "string" then
            return true, nil, failure("INVALID_NBT", "slot " .. slot .. " has invalid NBT", scan.node)
        end
        local detailOk, maxCount = stackLimit(scan, slot, item)
        if not detailOk then return true, nil, maxCount end
        scan.slots[slot] = {
            name = item.name,
            nbt = item.nbt,
            count = item.count,
            identity_key = Identity.key(item.name, item.nbt),
            max_count = maxCount,
        }
        scan.occupied = scan.occupied + 1
    end
    return false
end

return Scanner
