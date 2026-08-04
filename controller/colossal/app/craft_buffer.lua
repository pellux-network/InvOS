local CraftBuffer = {}
CraftBuffer.__index = CraftBuffer

-- Moving items out of the buffer is exactly an import: storage is the destination and
-- gains items, which is the direction reconciliation already measures. So rather than
-- write a second transfer path, this drives the proven ImportService over a synthesised
-- context whose "dropoff" is the buffer, filtered to only the slots that should leave.
--
-- The spec ruled ImportService out because it drains its source continuously and would
-- fight staging for the same items. That objection does not survive the filtering: the
-- importer only ever sees the excess, so when a step's ingredients are all that remain
-- it sees an empty inventory and reports nothing to do.
function CraftBuffer.new(deps)
    assert(type(deps) == "table", "craft buffer dependencies are required")
    return setmetatable({
        imports = assert(deps.imports, "an import service is required"),
        adapter = assert(deps.adapter, "inventory adapter is required"),
    }, CraftBuffer)
end

local function bufferNode(context)
    local node = context and context.craft_buffer
    if type(node) ~= "table" then return nil end
    return node
end

-- Aggregated by plain item name, not by identity key. Recipes name items without NBT,
-- and ingredient matching is deliberately NBT-free, so an NBT-bearing variant that
-- somehow reached the buffer counts as its own thing and gets drained rather than used.
function CraftBuffer:snapshot(context)
    local node = bufferNode(context)
    if not node then return nil end
    local totals = {}
    for _, item in pairs(node.slots or {}) do
        if item and item.name and item.nbt == nil then
            totals[item.name] = (totals[item.name] or 0) + (item.count or 0)
        elseif item and item.name then
            totals[item.name] = totals[item.name] or 0
        end
    end
    return totals
end

function CraftBuffer:ordered(context)
    local node = bufferNode(context)
    if not node then return {} end
    local slots = {}
    for slot in pairs(node.slots or {}) do slots[#slots + 1] = slot end
    table.sort(slots)
    local result = {}
    for _, slot in ipairs(slots) do
        local item = node.slots[slot]
        result[#result + 1] = {slot=slot, name=item.name, count=item.count, nbt=item.nbt}
    end
    return result
end

-- Slots holding more than `keep` allows, lowest slot first. A slot is kept whole while
-- the keep budget for its item lasts, because splitting a slot buys nothing: the turtle
-- sucks whole stacks in slot order regardless.
function CraftBuffer:_excess(context, keep)
    local node = bufferNode(context)
    if not node then return {} end
    local budget = {}
    for item, count in pairs(keep or {}) do budget[item] = count end
    local excess = {}
    for _, entry in ipairs(self:ordered(context)) do
        local allowance = budget[entry.name] or 0
        if entry.nbt ~= nil or allowance <= 0 then
            excess[#excess + 1] = entry
        else
            budget[entry.name] = allowance - entry.count
        end
    end
    return excess
end

function CraftBuffer:_importContext(context, excess)
    local node = bufferNode(context)
    local slots = {}
    for _, entry in ipairs(excess) do
        slots[entry.slot] = {name=entry.name, nbt=entry.nbt, count=entry.count,
            identity_key=node.slots[entry.slot].identity_key,
            max_count=node.slots[entry.slot].max_count}
    end
    local synthetic = {}
    for key, value in pairs(context) do synthetic[key] = value end
    synthetic.dropoff = {node_id="craft_buffer", peripheral_name=node.peripheral_name,
        health=node.health, epoch=node.epoch, size=node.size, slots=slots,
        slot_limits=node.slot_limits, default_limit=node.default_limit}
    return synthetic
end

-- The state of the private importer that moves items out of the buffer.
--
-- The coordinator grants a service exclusive use of the transfer machinery while it is
-- TRANSFERRING or VERIFYING, and it reads that from the service's status(). A craft job
-- reports its own states, so a transfer running inside the drain was invisible: the main
-- Drop-off importer could be started alongside it, two transfers sharing one journal and
-- both measuring aggregate storage deltas. That surfaces as items being credited to the
-- wrong step.
function CraftBuffer:status()
    local imports = self.imports
    if type(imports) ~= "table" or type(imports.status) ~= "function" then
        return {state="IDLE"}
    end
    local ok, value = pcall(imports.status, imports)
    if not ok or type(value) ~= "table" then return {state="IDLE"} end
    return value
end

function CraftBuffer:drain(context, keep)
    local node = bufferNode(context)
    if not node then
        return {state="BLOCKED", reason={code="BUFFER_MISSING",
            message="No craft buffer is bound"}}
    end
    if node.health ~= "READY" then
        return {state="BLOCKED", reason={code="BUFFER_UNAVAILABLE",
            message="The craft buffer is not ready"}}
    end
    local excess = self:_excess(context, keep or {})
    if #excess == 0 then return {state="DONE"} end

    local ok, result = pcall(self.imports.tick, self.imports, self:_importContext(context, excess))
    if not ok then
        return {state="BLOCKED", reason={code="DRAIN_FAILED", message=tostring(result)}}
    end
    local status = type(result) == "table" and result.state or nil
    if status == "BLOCKED" or status == "FAILED" then
        return {state="BLOCKED", reason=(type(result) == "table" and result.reason) or
            {code="DRAIN_BLOCKED", message="The buffer could not be cleared"}}
    end
    -- Still items to move; the caller ticks again once the scan catches up.
    return {state="WORKING", rescan=type(result) == "table" and result.rescan or nil}
end

-- Delivery to storage is just a drain of that item. Delivery to Pickup is a plain push:
-- no storage total moves, so there is nothing for reconciliation to protect, and the
-- buffer is a scanned node so an interrupted push leaves items the controller can still
-- see rather than lose.
function CraftBuffer:deliver(context, itemId, count, destination)
    local node = bufferNode(context)
    if not node or node.health ~= "READY" then
        return {state="BLOCKED", reason={code="BUFFER_UNAVAILABLE",
            message="The craft buffer is not ready"}}
    end
    if destination == "storage" then
        local keep = {}
        for item, held in pairs(self:snapshot(context) or {}) do
            if item ~= itemId then keep[item] = held end
        end
        return self:drain(context, keep)
    end

    local pickup = context.pickup
    if type(pickup) ~= "table" or pickup.health ~= "READY" then
        return {state="BLOCKED", reason={code="PICKUP_UNAVAILABLE",
            message="Pickup is not ready"}}
    end

    local remaining, moved = count, 0
    for _, entry in ipairs(self:ordered(context)) do
        if remaining <= 0 then break end
        if entry.name == itemId then
            local limit = math.min(remaining, entry.count)
            local ok, pushed = self.adapter:push(node.peripheral_name,
                pickup.peripheral_name, entry.slot, limit)
            if not ok then
                return {state="BLOCKED", reason={code="DELIVERY_FAILED",
                    message=tostring(pushed)}}
            end
            moved = moved + pushed
            remaining = remaining - pushed
            if pushed < limit then break end
        end
    end
    if moved <= 0 then
        return {state="BLOCKED", reason={code="PICKUP_FULL",
            message="Pickup accepted no items; make space and retry"}}
    end
    return {state="DONE", moved=moved, rescan={node.peripheral_name, pickup.peripheral_name}}
end

return CraftBuffer
