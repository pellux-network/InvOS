-- Builds an emulated wired network for the InvOS controller to run against.
--
-- This is the emulator's stand-in for the Minecraft side of the deployment: a
-- wired modem, a set of named inventories, and whatever stock the caller asked
-- for. It is loaded by the harness before `startup.lua`, never deployed, and
-- never touches a live tree.
--
-- Two behaviours of CraftOS-PC's peripheral emulation shape this file:
--
--  * Named peripherals only appear in `peripheral.getNames()` once a modem
--    exists. That mirrors Minecraft, where containers are reachable because a
--    wired modem puts them on the network, and it means the modem must be
--    created first or discovery finds nothing.
--  * Emulated chests start empty and are seeded through `setItem(slot, item)`,
--    which is a CraftOS-PC extension rather than part of the ComputerCraft
--    inventory API. Nothing in the controller may ever call it.

local World = {}

local DEFAULT_STACK = 64

-- Stack limits for the few items where 64 is wrong. The controller learns real
-- limits from `getItemDetail`, so seeding them correctly is what makes the
-- learned-metadata paths behave the way they do in game.
local STACK_LIMITS = {
    ["minecraft:ender_pearl"] = 16,
    ["minecraft:snowball"] = 16,
    ["minecraft:egg"] = 16,
    ["minecraft:diamond_sword"] = 1,
    ["minecraft:diamond_pickaxe"] = 1,
}

local function displayNameFor(id)
    local name = id:match(":(.+)$") or id
    name = name:gsub("_", " ")
    return (name:gsub("(%a)([%w]*)", function(first, rest)
        return first:upper() .. rest
    end))
end

local function stackLimitFor(id)
    return STACK_LIMITS[id] or DEFAULT_STACK
end

-- Per-slot facts the emulated chest cannot store, remembered here and re-attached
-- when the controller reads a slot back.
--
-- LIMITATION: this is keyed by inventory and slot, and it does not follow items
-- through pushItems/pullItems. A seeded NBT variant reads back correctly for as
-- long as it sits where it was placed, which covers indexing, search and
-- planning; it does not survive being moved. Tests that move an NBT variant
-- between inventories would be asserting on this harness rather than on InvOS,
-- so they are not written.
local remembered = {}

function World.remember(name, slot, facts)
    remembered[name] = remembered[name] or {}
    remembered[name][slot] = facts
end

function World.recall(name, slot)
    local perInventory = remembered[name]
    if not perInventory then return {} end
    return perInventory[slot] or {}
end

--- Create the wired modem. Must run before any named inventory is created.
function World.createNetwork(side)
    periphemu.create(side or "back", "modem")
end

--- Create a named inventory on the network.
-- @param name peripheral name, e.g. "minecraft:chest_0"
-- @param double true for a 54-slot double chest
function World.createInventory(name, double)
    periphemu.create(name, "chest", double and true or false)
    return peripheral.wrap(name)
end

--- Fill an inventory with stacks, splitting counts across slots by stack limit.
-- @param name peripheral name
-- @param stock list of {id=..., count=..., nbt=...}
-- @return the number of slots written
function World.stock(name, stock)
    local chest = peripheral.wrap(name)
    if not chest then error("no such inventory: " .. tostring(name), 2) end
    local capacity = chest.size()
    local slot = 1
    for _, entry in ipairs(stock or {}) do
        local remaining = entry.count or 1
        local limit = entry.maxCount or stackLimitFor(entry.id)
        while remaining > 0 and slot <= capacity do
            local amount = math.min(remaining, limit)
            chest.setItem(slot, {
                name = entry.id,
                count = amount,
                displayName = entry.displayName or displayNameFor(entry.id),
                maxCount = limit,
                nbt = entry.nbt,
            })
            -- CraftOS-PC accepts `nbt` on setItem and then never reports it back
            -- from list or getItemDetail, so the seeded value is remembered here
            -- and re-attached by the shims below. Without that the emulator
            -- cannot represent an NBT variant at all, and every NBT-aware path
            -- in the controller would go permanently untested.
            World.remember(name, slot, {
                nbt = entry.nbt,
                displayName = entry.displayName,
            })
            remaining = remaining - amount
            slot = slot + 1
        end
        if slot > capacity and remaining > 0 then
            error(("inventory %s overflowed: %d of %s did not fit")
                :format(name, remaining, entry.id), 2)
        end
    end
    return slot - 1
end

--- Make `getItemDetail` return what CC:Tweaked returns, not what CraftOS-PC does.
--
-- This is a fidelity fix, not a convenience. In Minecraft, `getItemDetail`
-- answers with `displayName`, `maxCount`, `tags` and `nbt` alongside the name
-- and count; CraftOS-PC's emulated chest answers with only `name` and `count`.
-- The controller learns display names and stack limits from exactly those extra
-- fields, so without this the emulator would exercise a code path that cannot
-- happen in game -- every item permanently unnamed -- and hide the paths that can.
--
-- It patches the peripheral API seen by the emulated computer only. The
-- controller is never aware of it and must never depend on it.
function World.enrichItemDetails(catalogue)
    catalogue = catalogue or {}
    local realWrap = peripheral.wrap
    local realCall = peripheral.call

    -- `list` carries only name, count and nbt in ComputerCraft; the richer
    -- fields appear on `getItemDetail`. Keeping that split matters, because the
    -- controller budgets per-slot detail calls precisely because they are the
    -- expensive ones -- a `list` that already answered everything would hide
    -- the cost model the scanner is built around.
    local function enrichListed(name, slot, item)
        if type(item) ~= "table" or not item.name then return item end
        local remembered = World.recall(name, slot)
        if item.nbt == nil then item.nbt = remembered.nbt end
        return item
    end

    local function enrichDetail(name, slot, item)
        if type(item) ~= "table" or not item.name then return item end
        local remembered = World.recall(name, slot)
        local entry = catalogue[item.name] or {}
        if item.nbt == nil then item.nbt = remembered.nbt end
        item.displayName = item.displayName or remembered.displayName
            or entry.displayName or displayNameFor(item.name)
        item.maxCount = item.maxCount or entry.maxCount or stackLimitFor(item.name)
        item.tags = item.tags or entry.tags or {}
        return item
    end

    peripheral.wrap = function(name)
        local wrapped = realWrap(name)
        if type(wrapped) ~= "table" then return wrapped end
        if wrapped.getItemDetail then
            local inner = wrapped.getItemDetail
            wrapped.getItemDetail = function(slot, ...)
                return enrichDetail(name, slot, inner(slot, ...))
            end
        end
        if wrapped.list then
            local inner = wrapped.list
            wrapped.list = function(...)
                local listed = inner(...)
                if type(listed) ~= "table" then return listed end
                for slot, item in pairs(listed) do enrichListed(name, slot, item) end
                return listed
            end
        end
        return wrapped
    end

    peripheral.call = function(name, method, ...)
        local result = realCall(name, method, ...)
        if method == "getItemDetail" then
            local slot = ...
            return enrichDetail(name, slot, result)
        elseif method == "list" and type(result) == "table" then
            for slot, item in pairs(result) do enrichListed(name, slot, item) end
        end
        return result
    end
end

--- Count peripheral calls, the unit of work that actually costs server ticks.
--
-- AGENTS.md is specific that every peripheral call yields for about a server
-- tick while pure Lua between yields is comparatively free, so the number that
-- matters when tuning a scan is the call count, not the loop count. In
-- Minecraft that number can only be inferred from wall-clock timings; here it
-- can be counted exactly.
--
-- Counts are written to `/profile.lua` so the host harness can read them back
-- after a run.
function World.profilePeripherals()
    local counts, total = {}, 0
    local realCall = peripheral.call
    local realWrap = peripheral.wrap

    local function record(method)
        counts[method] = (counts[method] or 0) + 1
        total = total + 1
    end

    peripheral.call = function(name, method, ...)
        record(method)
        return realCall(name, method, ...)
    end

    peripheral.wrap = function(name)
        local wrapped = realWrap(name)
        if type(wrapped) ~= "table" then return wrapped end
        local proxy = {}
        for key, value in pairs(wrapped) do
            if type(value) == "function" then
                proxy[key] = function(...) record(key) return value(...) end
            else
                proxy[key] = value
            end
        end
        return proxy
    end

    World.flushProfile = function()
        local handle = fs.open("/profile.lua", "w")
        handle.write(textutils.serialize({ total = total, calls = counts },
            { compact = true }))
        handle.close()
        return total
    end
    return World
end

--- Build a whole network in one call from a declarative description.
-- @param spec {modem=side, inventories={{name=..., double=..., stock={...}}}}
function World.build(spec)
    World.createNetwork(spec.modem)
    for _, inventory in ipairs(spec.inventories or {}) do
        World.createInventory(inventory.name, inventory.double)
        if inventory.stock then World.stock(inventory.name, inventory.stock) end
    end
    -- Order matters: each of these wraps the peripheral API the previous one
    -- installed, so profiling must go on last to see the calls the controller
    -- actually makes rather than the enrichment shim's inner calls.
    if spec.enrich ~= false then World.enrichItemDetails(spec.catalogue) end
    if spec.profile then World.profilePeripherals() end
    return World
end

return World
