local Registry = require("core.registry")

local Setup = {}
Setup.__index = Setup

local requiredMethods = {
    "size", "list", "getItemDetail", "getItemLimit", "pushItems", "pullItems",
}

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function defaults()
    return { schema=2, configured=false, installation=nil, dropoff=nil, pickup=nil,
        storage={}, craft_buffer=nil, turtle=nil, monitors=nil }
end

local function stable(value)
    if type(value) ~= "table" then return type(value) .. ":" .. tostring(value) end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
    local parts = { "{" }
    for _, key in ipairs(keys) do
        parts[#parts + 1] = stable(key)
        parts[#parts + 1] = "="
        parts[#parts + 1] = stable(value[key])
        parts[#parts + 1] = ";"
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

local function methodSet(value)
    local result = {}
    for key, method in pairs(value or {}) do
        if type(key) == "number" then result[method] = true
        elseif method == true then result[key] = true end
    end
    return result
end

local function issue(code, message, blocking, details)
    return { code=code, message=message, blocking=blocking ~= false, details=copy(details) }
end

function Setup.validateAliases(value)
    if type(value) ~= "table" or value.schema ~= 1 or type(value.items) ~= "table" then
        return nil, "aliases must use schema 1 with an items table"
    end
    for alias, target in pairs(value.items) do
        if type(alias) ~= "string" or type(target) ~= "string" then
            return nil, "alias names and targets must be strings"
        end
    end
    return true
end

-- Schema 2 adds the crafting bindings (craft_buffer, turtle, monitors). Schema 1 stays
-- valid rather than being migrated on read: the live install is a schema 1 file, and a
-- config that fails to load drops the controller to SETUP_REQUIRED with its storage
-- bindings gone. A schema 1 config simply has no crafting bindings, which is exactly
-- what an installation without a turtle looks like. Setup writes schema 2 on next save.
function Setup.validateConfig(value)
    if type(value) ~= "table" or (value.schema ~= 1 and value.schema ~= 2) or
        type(value.configured) ~= "boolean" or
        type(value.storage) ~= "table" then return nil, "configuration schema is invalid" end
    if value.monitors ~= nil then
        if type(value.monitors) ~= "table" then return nil, "monitor bindings are invalid" end
        for _, key in ipairs({"main", "crafting"}) do
            local name = value.monitors[key]
            if name ~= nil and (type(name) ~= "string" or name == "") then
                return nil, "monitor binding " .. key .. " is invalid"
            end
        end
    end
    if value.turtle ~= nil then
        if type(value.turtle) ~= "table" or type(value.turtle.peripheral_name) ~= "string" or
            value.turtle.peripheral_name == "" then
            return nil, "crafting turtle binding is invalid"
        end
    end
    if not value.configured then return true end
    if type(value.installation) ~= "table" or type(value.installation.computer_id) ~= "number" or
        type(value.installation.computer_label) ~= "string" then
        return nil, "configured installation identity is invalid"
    end
    local valid, reason = Registry.validate(value)
    if not valid then return nil, reason.message end
    local enabled = 0
    for _, node in ipairs(value.storage) do if node.enabled ~= false then enabled = enabled + 1 end end
    if enabled == 0 then return nil, "at least one enabled storage node is required" end
    return true
end

function Setup.new(deps, current)
    assert(type(deps) == "table", "setup dependencies are required")
    local active = copy(current or defaults())
    local highest = 0
    for _, node in ipairs(active.storage or {}) do
        highest = math.max(highest, tonumber(tostring(node.id):match("storage_(%d+)$")) or 0)
    end
    return setmetatable({
        peripheral=assert(deps.peripheral, "peripheral API is required"),
        store=assert(deps.store, "setup store is required"),
        backup=assert(deps.backup, "backup service is required"),
        os=assert(deps.os, "OS API is required"),
        clock=assert(deps.clock, "setup clock is required"),
        active=active, value=copy(active), storageCounter=highest,
    }, Setup)
end

function Setup:draft() return copy(self.value) end

function Setup:cancel()
    self.value = copy(self.active)
    self.pendingAliases = nil
    return true
end

local REQUIRED_ROLES = {dropoff=true, pickup=true}
local OPTIONAL_ROLES = {craft_buffer=true, turtle=true}
local MONITOR_ROLES = {monitor_main="main", monitor_crafting="crafting"}

-- Passing nil clears an optional binding, which is how the wizard's Skip choice works.
-- Drop-off and Pickup cannot be cleared: the controller has nothing to do without them.
function Setup:assign(role, peripheralName)
    local monitorKey = MONITOR_ROLES[role]
    if monitorKey then
        self.value.monitors = self.value.monitors or {}
        if peripheralName == nil then
            self.value.monitors[monitorKey] = nil
        elseif type(peripheralName) ~= "string" or peripheralName == "" then
            return nil, "peripheral name is required"
        else
            self.value.monitors[monitorKey] = peripheralName
        end
        if next(self.value.monitors) == nil then self.value.monitors = nil end
        return true
    end
    if not REQUIRED_ROLES[role] and not OPTIONAL_ROLES[role] then
        return nil, "unknown role " .. tostring(role)
    end
    if peripheralName == nil then
        if REQUIRED_ROLES[role] then return nil, "role " .. role .. " cannot be cleared" end
        self.value[role] = nil
        return true
    end
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return nil, "peripheral name is required"
    end
    self.value[role] = { peripheral_name=peripheralName }
    return true
end

function Setup:addStorage(peripheralName, label, priority)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return nil, "storage peripheral is required"
    end
    self.storageCounter = self.storageCounter + 1
    local node = { id="storage_" .. self.storageCounter, peripheral_name=peripheralName,
        label=label or ("Storage " .. self.storageCounter), priority=priority or self.storageCounter,
        enabled=true }
    self.value.storage[#self.value.storage + 1] = node
    return copy(node)
end

function Setup:updateStorage(id, changes)
    for _, node in ipairs(self.value.storage) do
        if node.id == id then
            for _, field in ipairs({"peripheral_name","label","priority","enabled"}) do
                if changes[field] ~= nil then node[field] = changes[field] end
            end
            return true
        end
    end
    return nil, "unknown storage node " .. tostring(id)
end

function Setup:removeStorage(id)
    for index, node in ipairs(self.value.storage) do
        if node.id == id then table.remove(self.value.storage, index); return true end
    end
    return nil, "unknown storage node " .. tostring(id)
end

local function pairKey(first, second)
    if tostring(first) > tostring(second) then first, second = second, first end
    return tostring(first) .. "|" .. tostring(second)
end

function Setup:confirmDistinct(firstId, secondId)
    if firstId == secondId then return nil, "two different node IDs are required" end
    local found = {}
    for _, node in ipairs(self.value.storage) do
        if node.id == firstId or node.id == secondId then found[node.id] = true end
    end
    if not found[firstId] or not found[secondId] then return nil, "unknown storage node" end
    self.value.confirmed_distinct = self.value.confirmed_distinct or {}
    self.value.confirmed_distinct[pairKey(firstId, secondId)] = true
    return true
end

function Setup:discover()
    local namesOk, names = pcall(self.peripheral.getNames)
    if not namesOk or type(names) ~= "table" then return {} end
    local discovered = {}
    for _, name in ipairs(names) do
        local typeOk, isInventory = pcall(self.peripheral.hasType, name, "inventory")
        if typeOk and isInventory then
            local methodsOk, methods = pcall(self.peripheral.getMethods, name)
            local wrappedOk, wrapped = pcall(self.peripheral.wrap, name)
            local size
            if wrappedOk and type(wrapped) == "table" and type(wrapped.size) == "function" then
                local sizeOk, result = pcall(wrapped.size)
                if sizeOk then size = result end
            end
            discovered[#discovered + 1] = {name=name,inventory=true,size=size,
                methods=methodsOk and methodSet(methods) or {},wrapped=wrappedOk and wrapped or nil}
        end
    end
    table.sort(discovered, function(left, right) return left.name < right.name end)
    self.discovered = discovered
    return copy(discovered)
end

-- The crafting turtle and the monitors are not inventories, so discover() never sees
-- them. Binding them needs a lookup by peripheral type instead.
function Setup:discoverByType(kind)
    if type(kind) ~= "string" or kind == "" then return {} end
    local namesOk, names = pcall(self.peripheral.getNames)
    if not namesOk or type(names) ~= "table" then return {} end
    local found = {}
    for _, name in ipairs(names) do
        local ok, matches = pcall(self.peripheral.hasType, name, kind)
        if ok and matches then found[#found + 1] = {name=name, kind=kind} end
    end
    table.sort(found, function(left, right) return left.name < right.name end)
    return found
end

local function snapshotFingerprint(descriptor)
    if not descriptor or type(descriptor.wrapped) ~= "table" or
        type(descriptor.wrapped.list) ~= "function" then return nil end
    local ok, listed = pcall(descriptor.wrapped.list)
    if not ok or type(listed) ~= "table" then return nil end
    local slots = {}
    for slot, item in pairs(listed) do
        slots[#slots + 1] = tostring(slot) .. ":" .. tostring(item.name) .. ":" ..
            tostring(item.nbt or "-") .. ":" .. tostring(item.count)
    end
    table.sort(slots)
    return tostring(descriptor.size) .. "|" .. table.concat(slots, ",")
end

function Setup:validate()
    local discovered = self:discover()
    local byName = {}
    for _, descriptor in ipairs(discovered) do byName[descriptor.name] = descriptor end
    local issues = {}
    local function add(value) issues[#issues + 1] = value end

    if not self.value.dropoff then add(issue("MISSING_DROPOFF", "Assign a Drop-off inventory")) end
    if not self.value.pickup then add(issue("MISSING_PICKUP", "Assign a Pickup inventory")) end
    if self.value.dropoff and self.value.pickup and
        self.value.dropoff.peripheral_name == self.value.pickup.peripheral_name then
        add(issue("ROLE_COLLISION", "Drop-off and Pickup must be different inventories"))
    end
    -- Checked here as well as at commit so the operator sees it on the validation step
    -- rather than after pressing save. It matters concretely on this installation: the
    -- buffer and Pickup are both ironchests:diamond_chest and differ only by index, so a
    -- mis-picked buffer would stage crafting ingredients into the chest players collect
    -- from.
    if self.value.craft_buffer then
        local buffer = self.value.craft_buffer.peripheral_name
        local clash
        if self.value.dropoff and buffer == self.value.dropoff.peripheral_name then
            clash = "Drop-off"
        elseif self.value.pickup and buffer == self.value.pickup.peripheral_name then
            clash = "Pickup"
        else
            for _, node in ipairs(self.value.storage or {}) do
                if node.peripheral_name == buffer then clash = "storage " .. node.id end
            end
        end
        if clash then
            add(issue("BUFFER_COLLISION",
                "The craft buffer is already bound as " .. clash))
        end
    end
    if self.value.turtle and self.value.craft_buffer == nil then
        add(issue("TURTLE_WITHOUT_BUFFER",
            "A crafting turtle needs a craft buffer beneath it", false))
    end
    local enabled = {}
    for _, node in ipairs(self.value.storage) do if node.enabled ~= false then enabled[#enabled + 1] = node end end
    if #enabled == 0 then add(issue("MISSING_STORAGE", "Add at least one enabled storage node")) end

    local bindings = {}
    local roles = {}
    if self.value.dropoff then roles[#roles + 1] = {label="Drop-off",binding=self.value.dropoff} end
    if self.value.pickup then roles[#roles + 1] = {label="Pickup",binding=self.value.pickup} end
    for _, node in ipairs(enabled) do roles[#roles + 1] = {label=node.label,binding=node} end
    for _, role in ipairs(roles) do
        local name = role.binding.peripheral_name
        if bindings[name] then
            add(issue("DUPLICATE_BINDING", name .. " is assigned to both " ..
                bindings[name] .. " and " .. role.label))
        else bindings[name] = role.label end
        local descriptor = byName[name]
        if not descriptor then
            add(issue("PERIPHERAL_MISSING", role.label .. " peripheral " .. name .. " is unavailable"))
        else
            local missing = {}
            for _, method in ipairs(requiredMethods) do
                if not descriptor.methods[method] then missing[#missing + 1] = method end
            end
            if #missing > 0 then
                add(issue("MISSING_METHOD", role.label .. " is missing: " .. table.concat(missing, ", "),
                    true, {peripheral_name=name,methods=missing}))
            end
        end
    end

    local fingerprints = {}
    for _, node in ipairs(enabled) do
        local fingerprint = snapshotFingerprint(byName[node.peripheral_name])
        if fingerprint then
            if fingerprints[fingerprint] then
                local first = fingerprints[fingerprint]
                local confirmed = self.value.confirmed_distinct and
                    self.value.confirmed_distinct[pairKey(first.id, node.id)]
                if confirmed then
                    add(issue("DUPLICATE_CONFIRMED", node.label .. " and " .. first.label ..
                        " were confirmed as physically distinct", false,
                        {nodes={first.id,node.id}}))
                else
                    add(issue("DUPLICATE_SUSPECTED", node.label .. " and " .. first.label ..
                        " may expose the same Colossal Chest", true,
                        {nodes={first.id,node.id}}))
                end
            else fingerprints[fingerprint] = node end
        end
    end

    local ok = true
    for _, value in ipairs(issues) do if value.blocking then ok = false; break end end
    return {ok=ok,issues=issues,draft=copy(self.value),fingerprint=stable(self.value),
        aliases=copy(self.pendingAliases)}
end

function Setup:commit(report)
    if type(report) ~= "table" or not report.ok then return nil, "validation has blocking issues" end
    if report.fingerprint ~= stable(self.value) then return nil, "setup draft changed after validation" end
    local config = copy(report.draft)
    -- Always saved as schema 2. A schema 1 file still loads, so an existing install is
    -- never forced through Setup, but anything Setup writes carries the newer shape.
    config.schema, config.configured = 2, true
    config.installation = {computer_id=self.os.getComputerID(),
        computer_label=self.os.getComputerLabel() or ""}
    local valid, reason = Setup.validateConfig(config)
    if not valid then return nil, reason end
    local aliases = copy(report.aliases or self.pendingAliases or {schema=1,items={}})
    local aliasOk, aliasReason = self.store:write("aliases", aliases, Setup.validateAliases)
    if not aliasOk then return nil, "could not save aliases: " .. tostring(aliasReason) end
    local saved, saveReason = self.store:write("config", config, Setup.validateConfig)
    if not saved then return nil, "could not save configuration: " .. tostring(saveReason) end
    self.active, self.value, self.pendingAliases = copy(config), copy(config), nil
    return true
end

function Setup:recoverBackup(mount)
    local payload, reason = self.backup.import(self.store, mount)
    if not payload then return nil, reason end
    local valid, configReason = Setup.validateConfig(payload.config)
    if not valid then return nil, "backup configuration invalid: " .. tostring(configReason) end
    local aliasesOk, aliasesReason = Setup.validateAliases(payload.aliases)
    if not aliasesOk then return nil, "backup aliases invalid: " .. tostring(aliasesReason) end
    self.value = copy(payload.config)
    self.value.configured = false
    self.value.installation = nil
    self.pendingAliases = copy(payload.aliases)
    return {requires_confirmation=true,draft=copy(self.value),aliases=copy(self.pendingAliases)}
end

return Setup
