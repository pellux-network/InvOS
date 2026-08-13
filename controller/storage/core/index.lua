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

-- Search groups items by registry name to collapse NBT variants under one entry.
-- Computed once here, at build time, instead of once per keystroke in app/search.lua.
local function buildGroups(ordered)
    local byName, groupList = {}, {}
    for _, aggregate in ipairs(ordered) do
        local group = byName[aggregate.name]
        if not group then
            group = {
                name = aggregate.name, display_name = aggregate.display_name or aggregate.name,
                quantity = 0, variants = {}, request_count = 0, last_requested = 0,
            }
            byName[aggregate.name] = group
            groupList[#groupList + 1] = group
        end
        local variant = {
            identity_key = aggregate.key, name = aggregate.name, nbt = aggregate.nbt,
            display_name = aggregate.display_name or aggregate.name, quantity = aggregate.quantity,
            max_count = aggregate.max_count, aliases = copy(aggregate.aliases or {}),
            request_count = aggregate.request_count, last_requested = aggregate.last_requested,
        }
        group.variants[#group.variants + 1] = variant
        group.quantity = group.quantity + (aggregate.quantity or 0)
        group.request_count = math.max(group.request_count, aggregate.request_count)
        group.last_requested = math.max(group.last_requested, aggregate.last_requested)
    end
    for _, group in ipairs(groupList) do
        if #group.variants == 1 then group.identity_key = group.variants[1].identity_key end
    end
    return groupList
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
                        request_count = details.request_count or 0,
                        last_requested = details.last_requested or 0,
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
        _metadata = metadataCopy, _groups = buildGroups(ordered) }, Index)
end

function Index:quantity(identityKey)
    local aggregate = self._byIdentity[identityKey]
    return aggregate and aggregate.quantity or 0
end

function Index:sources(identityKey)
    local aggregate = self._byIdentity[identityKey]
    return aggregate and copy(aggregate.sources) or {}
end

function Index:groups()
    return copy(self._groups)
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
            request_count = aggregate.request_count,
            last_requested = aggregate.last_requested,
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

-- The scanned inventory index is derived state and must never be persisted as
-- authoritative stock truth (AGENTS.md). This validator guards the on-disk metadata
-- cache so it can only ever hold learned display names and stack limits, never counts.
local forbiddenFields = { "quantity", "count", "slot", "slots", "sources" }

function M.validateMetadata(value)
    if type(value) ~= "table" or value.schema ~= 1 or type(value.items) ~= "table" then
        return nil, "metadata schema is invalid"
    end
    for key, details in pairs(value.items) do
        if type(key) ~= "string" then return nil, "metadata keys must be identity strings" end
        if type(details) ~= "table" then return nil, "metadata entry for " .. key .. " must be a table" end
        for _, field in ipairs(forbiddenFields) do
            if details[field] ~= nil then
                return nil, "metadata entry for " .. key .. " must not carry " .. field
            end
        end
        if type(details.display_name) ~= "string" or details.display_name == "" then
            return nil, "metadata entry for " .. key .. " requires a display_name"
        end
        if type(details.max_count) ~= "number" or details.max_count < 1 or details.max_count % 1 ~= 0 then
            return nil, "metadata entry for " .. key .. " requires a valid max_count"
        end
        if details.aliases ~= nil and type(details.aliases) ~= "table" then
            return nil, "metadata entry for " .. key .. " aliases must be a table"
        end
        if details.request_count ~= nil and (type(details.request_count) ~= "number" or
            details.request_count < 0 or details.request_count % 1 ~= 0) then
            return nil, "metadata entry for " .. key .. " request_count must be a non-negative integer"
        end
        if details.last_requested ~= nil and (type(details.last_requested) ~= "number" or
            details.last_requested < 0) then
            return nil, "metadata entry for " .. key .. " last_requested must be a non-negative number"
        end
    end
    return true
end

return M
