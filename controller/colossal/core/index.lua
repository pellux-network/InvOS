local Identity = require("core.identity")

local M = {}
local Index = {}
Index.__index = Index

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function sourceLess(left, right)
    if left.priority ~= right.priority then return left.priority < right.priority end
    if left.node_id ~= right.node_id then return left.node_id < right.node_id end
    return left.slot < right.slot
end

local function itemLess(left, right)
    local leftName = (left.display_name or left.name):lower()
    local rightName = (right.display_name or right.name):lower()
    if leftName ~= rightName then return leftName < rightName end
    return left.key < right.key
end

function M.build(snapshots, metadata)
    local byIdentity = {}
    local metadataCopy = copy(metadata or {})
    for _, snapshot in ipairs(snapshots or {}) do
        if snapshot.health == "READY" then
            for slot, item in pairs(snapshot.slots or {}) do
                local key = item.identity_key or Identity.key(item.name, item.nbt)
                local aggregate = byIdentity[key]
                if not aggregate then
                    local details = metadataCopy[key] or {}
                    aggregate = {
                        key = key,
                        name = item.name,
                        nbt = item.nbt,
                        quantity = 0,
                        display_name = details.display_name or item.name,
                        max_count = details.max_count,
                        aliases = copy(details.aliases or {}),
                        sources = {},
                    }
                    byIdentity[key] = aggregate
                end
                aggregate.quantity = aggregate.quantity + item.count
                aggregate.sources[#aggregate.sources + 1] = {
                    node_id = snapshot.node_id,
                    peripheral_name = snapshot.peripheral_name,
                    slot = slot,
                    count = item.count,
                    epoch = snapshot.epoch,
                    priority = snapshot.priority or math.huge,
                    identity_key = key,
                }
            end
        end
    end

    local ordered = {}
    for _, aggregate in pairs(byIdentity) do
        table.sort(aggregate.sources, sourceLess)
        ordered[#ordered + 1] = aggregate
    end
    table.sort(ordered, itemLess)
    return setmetatable({ _byIdentity = byIdentity, _ordered = ordered,
        _metadata = metadataCopy }, Index)
end

function Index:quantity(identityKey)
    local aggregate = self._byIdentity[identityKey]
    return aggregate and aggregate.quantity or 0
end

function Index:sources(identityKey)
    local aggregate = self._byIdentity[identityKey]
    return aggregate and copy(aggregate.sources) or {}
end

function Index:items()
    local result = {}
    for index, aggregate in ipairs(self._ordered) do
        result[index] = {
            key = aggregate.key,
            name = aggregate.name,
            nbt = aggregate.nbt,
            quantity = aggregate.quantity,
            display_name = aggregate.display_name,
            max_count = aggregate.max_count,
            aliases = copy(aggregate.aliases),
        }
    end
    return result
end

local function newEnrichmentState(index)
    local keys = {}
    for _, item in ipairs(index:items()) do
        local details = index._metadata[item.key]
        if not details or type(details.display_name) ~= "string" or
            type(details.max_count) ~= "number" then
            keys[#keys + 1] = item.key
        end
    end
    return {
        cursor = 1,
        keys = keys,
        metadata = copy(index._metadata),
        failures = {},
        done = #keys == 0,
    }
end

function M.enrichStep(index, registry, budget, state)
    assert(getmetatable(index) == Index, "index snapshot is required")
    assert(type(registry) == "table" and type(registry.getItemDetail) == "function",
        "metadata registry is required")
    assert(type(budget) == "number" and budget >= 1 and budget % 1 == 0,
        "metadata budget must be a positive integer")
    state = state or newEnrichmentState(index)
    if state.done then return state end

    for _ = 1, budget do
        local key = state.keys[state.cursor]
        if not key then state.done = true; break end
        local sources = index:sources(key)
        local source = sources[1]
        local callOk, ok, detail = pcall(registry.getItemDetail, registry,
            source.peripheral_name, source.slot)
        if callOk and ok and type(detail) == "table" and
            type(detail.displayName) == "string" and type(detail.maxCount) == "number" then
            local prior = state.metadata[key] or {}
            state.metadata[key] = {
                display_name = detail.displayName,
                max_count = detail.maxCount,
                aliases = copy(prior.aliases or {}),
            }
        else
            local reason = callOk and detail or ok
            state.failures[#state.failures + 1] = {
                identity_key = key,
                code = "METADATA_UNAVAILABLE",
                message = tostring(reason or "invalid item detail"),
                retryable = true,
            }
        end
        state.cursor = state.cursor + 1
        if state.cursor > #state.keys then state.done = true; break end
    end
    return state
end

return M
