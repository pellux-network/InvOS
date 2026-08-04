local Alerts = require("app.alerts")
local CraftPlanner = require("core.craft_planner")
local CraftService = require("app.craft_service")
local Lifecycle = require("app.lifecycle")
local RecipeRepo = require("core.recipe_repo")
local T = require("tests.mock_cc")

-- The real turtle executor, loaded by path so the turtle tree never shadows controller
-- modules for tests that run after this one.
local Executor = dofile("../turtle/crafter/executor.lua")

-- Everything below the craft service is real: the generated recipe pack, the planner,
-- the service, and the turtle executor. Only the inventories are modelled, and they are
-- modelled with stack limits, because a fake without them is what let a batching bug
-- reach the game.
local STACK = 64
local realRepo = RecipeRepo.new({})

local function newBuffer()
    -- Slot-based, so the turtle draws from it the way suckDown really does.
    local buffer = {slots = {}}
    function buffer:add(name, count)
        local left = count
        while left > 0 do
            local placed = false
            for _, slot in ipairs(self.slots) do
                if slot.name == name and slot.count < STACK then
                    local take = math.min(left, STACK - slot.count)
                    slot.count = slot.count + take
                    left = left - take
                    placed = true
                    break
                end
            end
            if not placed then
                local take = math.min(left, STACK)
                self.slots[#self.slots + 1] = {name = name, count = take}
                left = left - take
            end
        end
    end
    function buffer:totals()
        local totals = {}
        for _, slot in ipairs(self.slots) do
            totals[slot.name] = (totals[slot.name] or 0) + slot.count
        end
        return totals
    end
    function buffer:compact()
        local kept = {}
        for _, slot in ipairs(self.slots) do
            if slot.count > 0 then kept[#kept + 1] = slot end
        end
        self.slots = kept
    end
    return buffer
end

-- A turtle whose "inventory below" is the craft buffer, with real slot limits.
local function newTurtle(buffer)
    local api = {slots = {}, selected = 1, crafted = {}}
    function api.select(slot) api.selected = slot; return true end
    function api.getItemCount(slot)
        local entry = api.slots[slot or api.selected]
        return entry and entry.count or 0
    end
    function api.getItemDetail(slot)
        local entry = api.slots[slot or api.selected]
        if not entry then return nil end
        return {name = entry.name, count = entry.count}
    end
    function api.suckDown(limit)
        local target = api.slots[api.selected]
        local space = STACK - (target and target.count or 0)
        if space <= 0 then return false end
        for _, slot in ipairs(buffer.slots) do
            if slot.count > 0 then
                if target and target.name ~= slot.name then return false end
                local take = math.min(limit or slot.count, slot.count, space)
                if take <= 0 then return false end
                slot.count = slot.count - take
                if target then target.count = target.count + take
                else api.slots[api.selected] = {name = slot.name, count = take} end
                buffer:compact()
                return true
            end
        end
        return false
    end
    function api.transferTo(slot, count)
        local from = api.slots[api.selected]
        if not from or from.count < count then return false end
        local target = api.slots[slot]
        if target and target.name ~= from.name then return false end
        if (target and target.count or 0) + count > STACK then return false end
        from.count = from.count - count
        if target then target.count = target.count + count
        else api.slots[slot] = {name = from.name, count = count} end
        if from.count == 0 then api.slots[api.selected] = nil end
        return true
    end
    function api.dropDown()
        local entry = api.slots[api.selected]
        if not entry then return false end
        buffer:add(entry.name, entry.count)
        api.slots[api.selected] = nil
        return true
    end
    -- Crafts as many times as the smallest occupied grid cell allows, capped at 64,
    -- which is what turtle.craft() does.
    function api.craft()
        local grid = {1,2,3,5,6,7,9,10,11}
        local runs, occupied = STACK, 0
        for _, cell in ipairs(grid) do
            local entry = api.slots[cell]
            if entry then
                occupied = occupied + 1
                runs = math.min(runs, entry.count)
            end
        end
        if occupied == 0 then return false end
        local recipe = api.recipe
        if not recipe then return false end
        for _, cell in ipairs(grid) do
            local entry = api.slots[cell]
            if entry then
                entry.count = entry.count - runs
                if entry.count <= 0 then api.slots[cell] = nil end
            end
        end
        api.crafted[#api.crafted + 1] = {item = recipe.item, count = runs * recipe.per}
        local left, slot = runs * recipe.per, 1
        while left > 0 and slot <= 16 do
            if not api.slots[slot] then
                local take = math.min(left, STACK)
                api.slots[slot] = {name = recipe.item, count = take}
                left = left - take
            end
            slot = slot + 1
        end
        return true
    end
    return api
end

-- Routes the service's turtle commands into the real executor.
local function newLink(turtle, recipes)
    local link = {sent = {}, reply = nil}
    function link:send(command)
        self.sent[#self.sent + 1] = command
        turtle.recipe = recipes[command.result.name]
        self.reply = Executor.new({turtle = turtle}):handle(command)
        return true
    end
    function link:poll()
        local reply = self.reply
        self.reply = nil
        return reply
    end
    return link
end

local function newRequests(buffer, storage, delivered)
    local requests = {byId = {}, counter = 0}
    function requests:create(identity, quantity, options)
        self.counter = self.counter + 1
        local id = "request-" .. self.counter
        local name = identity.name
        local held = storage[name] or 0
        local moved = math.min(held, quantity)
        storage[name] = held - moved
        if options and options.destination_role == "craft_buffer" then
            buffer:add(name, moved)
        else
            -- Delivery to Pickup, which is where a finished craft ends up.
            delivered[name] = (delivered[name] or 0) + moved
        end
        self.byId[id] = {id = id, state = moved == quantity and "COMPLETE" or "FAILED"}
        return self.byId[id]
    end
    function requests:get(id) return self.byId[id] end
    function requests:cancel(id)
        if self.byId[id] then self.byId[id].state = "CANCELLED" end
        return true
    end
    return requests
end

local function run(item, quantity, storage)
    local buffer = newBuffer()
    local turtle = newTurtle(buffer)
    local link = newLink(turtle, {
        ["minecraft:oak_planks"] = {item = "minecraft:oak_planks", per = 4},
        ["minecraft:stick"] = {item = "minecraft:stick", per = 4},
        ["minecraft:chest"] = {item = "minecraft:chest", per = 1},
    })
    local delivered = {}
    local requests = newRequests(buffer, storage, delivered)
    local craftBuffer = {}
    function craftBuffer:snapshot() return buffer:totals() end
    function craftBuffer:drain(_, keep)
        local kept = newBuffer()
        local budget = {}
        for name, count in pairs(keep or {}) do budget[name] = count end
        for _, slot in ipairs(buffer.slots) do
            local allow = budget[slot.name] or 0
            if allow >= slot.count then
                budget[slot.name] = allow - slot.count
                kept:add(slot.name, slot.count)
            else
                storage[slot.name] = (storage[slot.name] or 0) + slot.count
            end
        end
        buffer.slots = kept.slots
        return {state = "DONE"}
    end
    -- Refuses to deliver more than was actually produced. A fake that reports success
    -- regardless would hide under-production, which is exactly what it did hide.
    function craftBuffer:deliver(_, name, count)
        local available = 0
        for _, slot in ipairs(buffer.slots) do
            if slot.name == name then available = available + slot.count end
        end
        if available < count then
            return {state = "BLOCKED", reason = {code = "UNDER_PRODUCED",
                message = "only " .. available .. " of " .. count .. " were made"}}
        end
        delivered[name] = (delivered[name] or 0) + count
        local left = count
        for _, slot in ipairs(buffer.slots) do
            if slot.name == name and left > 0 then
                local take = math.min(left, slot.count)
                slot.count = slot.count - take
                left = left - take
            end
        end
        buffer:compact()
        return {state = "DONE"}
    end

    local service = CraftService.new({
        planner = CraftPlanner, repo = realRepo, requests = requests,
        buffer = craftBuffer, link = link, alerts = Alerts.new(function() return 0 end),
        transition = Lifecycle.transition, clock = function() return 100 end,
        idGenerator = function(counter) return "craft-" .. counter end,
        stack_limit = function() return STACK end,
    })
    local job = service:enqueue(item, quantity)
    local index = {quantity = function(_, key)
        local name = tostring(key):gsub("%z%-$", "")
        return storage[name] or 0
    end}
    local context = {index = index, storage = {},
        craft_buffer = {peripheral_name = "buffer", health = "READY", slots = {}},
        pickup = {peripheral_name = "pickup", health = "READY"}, generation = 1, now = 100}
    for _ = 1, 200 do service:tick(context) end
    return service:get(job.id), delivered, link, turtle, buffer
end

return {
    {name="500 sticks completes through the real turtle executor",run=function()
        local storage = {["minecraft:oak_log"] = 256}
        local job, delivered, link = run("minecraft:stick", 500, storage)
        T.equal(job.state, "COMPLETE",
            "the job stalled at " .. job.state .. " " ..
            (job.reason and job.reason.code or ""))
        T.equal(delivered["minecraft:stick"], 500)
        T.truthy(#link.sent >= 2, "a two-step tree needs at least two turtle commands")
    end},
    {name="a full 64 batch across two cells stages without overflowing a slot",run=function()
        -- This is the exact shape that failed in game: batch 64 over the stick recipe's
        -- two plank cells asks for 128 planks, which no single turtle slot can hold.
        local storage = {["minecraft:oak_planks"] = 256}
        local job, delivered = run("minecraft:stick", 500, storage)
        T.equal(job.state, "COMPLETE", "batched staging must not overflow a slot")
        T.equal(delivered["minecraft:stick"], 500)
    end},
    {name="the turtle ends empty and the buffer is left clean",run=function()
        local storage = {["minecraft:oak_log"] = 256}
        local _, _, _, turtle, buffer = run("minecraft:stick", 500, storage)
        local held = 0
        for slot = 1, 16 do held = held + turtle.getItemCount(slot) end
        T.equal(held, 0, "the turtle must not keep stock between jobs")
        T.equal(#buffer.slots, 0, "leftovers go back to storage, not the buffer")
    end},
    {name="a single small craft still works",run=function()
        local storage = {["minecraft:oak_log"] = 8}
        local job, delivered = run("minecraft:chest", 1, storage)
        T.equal(job.state, "COMPLETE")
        T.equal(delivered["minecraft:chest"], 1)
    end},
    {name="insufficient materials block rather than half-crafting",run=function()
        local storage = {["minecraft:oak_log"] = 1}
        local job, delivered = run("minecraft:stick", 500, storage)
        T.equal(job.state, "BLOCKED")
        T.equal(delivered["minecraft:stick"], nil, "nothing is delivered from a blocked job")
    end},
}
