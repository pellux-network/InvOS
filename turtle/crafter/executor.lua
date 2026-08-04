-- The crafting turtle's entire brain.
--
-- It knows nothing about recipes, tags, planning or storage. The controller resolves
-- all of that and hands over a list of steps already in the order suckDown will
-- encounter them, because suckDown always takes from the buffer's lowest occupied slot
-- and the controller has just scanned the buffer to see what that order is.
--
-- The turtle's only item knowledge is one string comparison per step, which exists so a
-- staging mistake becomes a clean refusal instead of a wrong craft.
--
-- Every operation ends with the turtle empty. It holds no state between jobs, so a
-- reboot mid-job strands nothing: whatever it was holding is dropped into the buffer,
-- which the controller scans.

local Executor = {}
Executor.__index = Executor

-- turtle.craft() reads slots 1-3, 5-7 and 9-11 as the 3x3 grid. Slots 4, 8 and 12-16
-- are free, and the craft result lands wherever there is room, which is why a purge has
-- to sweep all sixteen rather than the grid alone.
local SLOT_COUNT = 16

function Executor.new(deps)
    assert(type(deps) == "table", "executor dependencies are required")
    return setmetatable({
        turtle = assert(deps.turtle, "turtle API is required"),
        label = deps.label or "crafter",
    }, Executor)
end

local function reply(code, message)
    return {ok = false, code = code, message = message}
end

-- Drop everything down into the buffer. This is both the normal end of a job and the
-- response to any failure: the controller can see the buffer, so returning items there
-- is always better than holding them where nothing can account for them.
function Executor:purge()
    local api = self.turtle
    local dropped = 0
    for slot = 1, SLOT_COUNT do
        api.select(slot)
        if api.getItemCount(slot) > 0 then
            if api.dropDown() then dropped = dropped + 1 end
        end
    end
    api.select(1)
    return dropped
end

function Executor:_stage(step)
    local api = self.turtle
    local cells = step.cells or {}
    if #cells == 0 then return reply("EMPTY_STEP", "a craft step named no cells") end
    local perCell = step.per_cell or 1
    local wanted = perCell * #cells

    api.select(cells[1])
    if not api.suckDown(wanted) then
        return reply("BUFFER_EMPTY", "the buffer did not yield " .. tostring(step.expect))
    end

    local detail = api.getItemDetail(cells[1])
    if type(detail) ~= "table" or detail.name ~= step.expect then
        return reply("INGREDIENT_MISMATCH", "expected " .. tostring(step.expect) ..
            " but got " .. tostring(type(detail) == "table" and detail.name or "nothing"))
    end
    if api.getItemCount(cells[1]) < wanted then
        return reply("INGREDIENT_SHORT", "the buffer held too little " .. tostring(step.expect))
    end

    -- Everything for this ingredient arrived in the first of its cells; spread the rest.
    for index = 2, #cells do
        if not api.transferTo(cells[index], perCell) then
            return reply("TRANSFER_FAILED", "could not place " .. tostring(step.expect))
        end
    end
    return nil
end

function Executor:craft(command)
    local api = self.turtle
    if type(command.steps) ~= "table" or #command.steps == 0 then
        return reply("EMPTY_COMMAND", "a craft command needs at least one step")
    end

    for _, step in ipairs(command.steps) do
        local failure = self:_stage(step)
        if failure then
            self:purge()
            return failure
        end
    end

    local ok = api.craft()
    if not ok then
        self:purge()
        return reply("CRAFT_FAILED", "the grid did not form a valid recipe")
    end

    local dropped = self:purge()
    return {ok = true, job = command.job, dropped = dropped}
end

function Executor:handle(command)
    if type(command) ~= "table" or type(command.op) ~= "string" then
        return reply("BAD_COMMAND", "a command needs an op")
    end
    if command.op == "ping" then
        return {ok = true, label = self.label}
    end
    if command.op == "purge" then
        return {ok = true, dropped = self:purge()}
    end
    if command.op == "craft" then
        local ok, result = pcall(function() return self:craft(command) end)
        if not ok then
            -- Never leave items in the turtle because of an unexpected error.
            pcall(function() self:purge() end)
            return reply("EXECUTOR_ERROR", tostring(result))
        end
        return result
    end
    return reply("UNKNOWN_OP", "unknown op " .. tostring(command.op))
end

return Executor
