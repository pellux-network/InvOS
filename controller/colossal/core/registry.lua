local Registry = {}
Registry.__index = Registry

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function problem(code, message)
    return nil, { code = code, message = message }
end

function Registry.validate(config)
    if type(config) ~= "table" then return problem("INVALID_CONFIG", "registry config is required") end
    if type(config.dropoff) ~= "table" or type(config.dropoff.peripheral_name) ~= "string" then
        return problem("MISSING_DROPOFF", "Drop-off binding is required")
    end
    if type(config.pickup) ~= "table" or type(config.pickup.peripheral_name) ~= "string" then
        return problem("MISSING_PICKUP", "Pickup binding is required")
    end
    if config.dropoff.peripheral_name == config.pickup.peripheral_name then
        return problem("ROLE_COLLISION", "Drop-off and Pickup must be different inventories")
    end
    if type(config.storage) ~= "table" then
        return problem("MISSING_STORAGE", "storage bindings are required")
    end

    local bindings = {
        [config.dropoff.peripheral_name] = "dropoff",
        [config.pickup.peripheral_name] = "pickup",
    }
    local ids = {}
    for index, node in ipairs(config.storage) do
        if type(node.id) ~= "string" or node.id == "" then
            return problem("INVALID_STORAGE", "storage node " .. index .. " requires an ID")
        end
        if ids[node.id] then return problem("DUPLICATE_ID", "duplicate storage ID " .. node.id) end
        ids[node.id] = true
        if type(node.peripheral_name) ~= "string" or node.peripheral_name == "" then
            return problem("INVALID_STORAGE", "storage node " .. node.id .. " requires a peripheral")
        end
        if bindings[node.peripheral_name] then
            return problem("DUPLICATE_BINDING", "peripheral " .. node.peripheral_name ..
                " is already bound as " .. bindings[node.peripheral_name])
        end
        bindings[node.peripheral_name] = "storage " .. node.id
    end
    return true
end

function Registry.new(config)
    local valid, reason = Registry.validate(config)
    if not valid then error(reason.message, 2) end
    return setmetatable({ value = copy(config) }, Registry)
end

function Registry:config()
    return copy(self.value)
end

function Registry:rebind(role, id, peripheralName)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return nil, { code = "INVALID_BINDING", message = "peripheral name is required" }
    end
    local candidate = copy(self.value)
    if role == "dropoff" or role == "pickup" then
        candidate[role].peripheral_name = peripheralName
    elseif role == "storage" then
        local found = false
        for _, node in ipairs(candidate.storage) do
            if node.id == id then node.peripheral_name, found = peripheralName, true; break end
        end
        if not found then return problem("UNKNOWN_NODE", "unknown storage node " .. tostring(id)) end
    else
        return problem("UNKNOWN_ROLE", "unknown role " .. tostring(role))
    end
    local valid, reason = Registry.validate(candidate)
    if not valid then return nil, reason end
    self.value = candidate
    return true
end

function Registry:reconcile(discovered, now)
    local byName = {}
    for _, descriptor in ipairs(discovered or {}) do byName[descriptor.name] = descriptor end
    local bound = {}

    local function roleState(role, binding)
        bound[binding.peripheral_name] = true
        local descriptor = byName[binding.peripheral_name]
        return {
            role = role,
            peripheral_name = binding.peripheral_name,
            state = descriptor and "SCANNING" or "OFFLINE",
            methods = descriptor and descriptor.methods or nil,
            last_seen = descriptor and now or nil,
        }
    end

    local result = {
        dropoff = roleState("dropoff", self.value.dropoff),
        pickup = roleState("pickup", self.value.pickup),
        storage = {},
        discovered = {},
    }
    for _, node in ipairs(self.value.storage) do
        bound[node.peripheral_name] = true
        local descriptor = byName[node.peripheral_name]
        result.storage[node.id] = {
            id = node.id,
            label = node.label or node.id,
            priority = node.priority or 0,
            peripheral_name = node.peripheral_name,
            state = node.enabled == false and "DISABLED" or
                (descriptor and "SCANNING" or "OFFLINE"),
            methods = descriptor and descriptor.methods or nil,
            last_seen = descriptor and now or nil,
        }
    end
    for name, descriptor in pairs(byName) do
        if not bound[name] then
            result.discovered[name] = {
                peripheral_name = name,
                state = "DISCOVERED",
                methods = descriptor.methods,
                size = descriptor.size,
                last_seen = now,
            }
        end
    end
    return result
end

return Registry
