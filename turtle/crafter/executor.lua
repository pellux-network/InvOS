-- The crafting turtle's entire brain.
--
-- It knows nothing about recipes, tags, planning or storage. The controller resolves all
-- of that and hands over which grid cells want which item, and how many.
--
-- It does not assume the buffer is in any particular order. It used to: the steps were
-- meant to arrive in the order suckDown would encounter them, since suckDown always takes
-- the buffer's lowest occupied slot. Nothing established that order, and while every
-- recipe crafted had a single ingredient it did not matter, because with one item type
-- any order is the right order. The first two-ingredient recipe put the wrong item in a
-- cell. Staging now identifies each stack before placing it.
--
-- The turtle's item knowledge is one string comparison per stack, which exists so a
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

-- Bounds the gather loop so a buffer that keeps returning nothing cannot spin. A stack
-- is 64 and suckDown takes from one buffer slot per call, so a cell can never honestly
-- need more calls than this.
local MAX_SUCKS_PER_CELL = 64

function Executor.new(deps)
    assert(type(deps) == "table", "executor dependencies are required")
    return setmetatable({
        turtle = assert(deps.turtle, "turtle API is required"),
        label = deps.label or "crafter",
        -- Optional and dependency-injected so every existing caller and test is unaffected:
        -- a status screen can watch progress without the executor knowing anything about
        -- screens, and a caller that passes nothing gets a silent no-op.
        notify = type(deps.notify) == "function" and deps.notify or function() end,
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

-- Every ingredient is staged in one pass, routed by what each buffer stack turns out to
-- be rather than by the order the recipe lists its cells.
--
-- suckDown always takes the buffer's lowest occupied slot, so filling cells in recipe
-- order is only correct when the buffer happens to agree. It routinely does not: the
-- buffer is filled by one withdrawal per ingredient and those land wherever there is
-- room, and two withdrawals of the same item can end up either side of a third. Every
-- craft before this had a single ingredient type, where any order is the right order,
-- which is why a two-ingredient recipe was the first to put the wrong item in a cell.
--
-- So each stack is drawn into a scratch slot, identified, and transferred to the cells
-- that actually want it. A turtle slot holds one stack, so an ingredient still cannot be
-- gathered in one cell and spread from there -- per_cell * #cells routinely exceeds 64 --
-- which is why this fills each cell directly rather than hoarding first.
local SCRATCH_SLOT = 16

function Executor:_stage(command)
    local api = self.turtle
    local steps = command.steps or {}

    -- cell -> what it wants. Built once so a stack can be matched against every cell.
    local want, order = {}, {}
    for _, step in ipairs(steps) do
        for _, cell in ipairs(step.cells or {}) do
            if cell ~= SCRATCH_SLOT then
                want[cell] = {expect = step.expect, need = step.per_cell or 1}
                order[#order + 1] = cell
            end
        end
    end
    if #order == 0 then return reply("EMPTY_STEP", "a craft step named no cells") end

    local needTotal = 0
    for _, cell in ipairs(order) do needTotal = needTotal + want[cell].need end

    -- Item counts rather than cell counts, so a batched step (per_cell > 1) still reports
    -- smooth progress instead of jumping straight from 0 to "done" on the last cell.
    local function reportProgress()
        local have = 0
        for _, cell in ipairs(order) do
            have = have + math.min(api.getItemCount(cell), want[cell].need)
        end
        self.notify("stage_progress", {filled = have, total = needTotal})
    end

    local function outstanding()
        for _, cell in ipairs(order) do
            if api.getItemCount(cell) < want[cell].need then return true end
        end
        return false
    end

    reportProgress()
    local guard = 0
    while outstanding() do
        guard = guard + 1
        if guard > MAX_SUCKS_PER_CELL * #order then break end

        api.select(SCRATCH_SLOT)
        if not api.suckDown() then break end
        local detail = api.getItemDetail(SCRATCH_SLOT)
        if type(detail) ~= "table" then break end

        local wanted, placed = false, false
        for _, cell in ipairs(order) do
            if want[cell].expect == detail.name then
                wanted = true
                local short = want[cell].need - api.getItemCount(cell)
                local available = api.getItemCount(SCRATCH_SLOT)
                if short > 0 and available > 0 then
                    api.select(SCRATCH_SLOT)
                    if api.transferTo(cell, math.min(short, available)) then placed = true end
                end
            end
        end
        if placed then reportProgress() end

        -- The controller asserts the buffer holds only this step's ingredients, so an
        -- item no cell names means that assertion was wrong. Refuse rather than craft.
        if not wanted then
            return reply("INGREDIENT_MISMATCH", "the buffer held " ..
                tostring(detail.name) .. " which this craft does not use")
        end
        if api.getItemCount(SCRATCH_SLOT) > 0 then
            -- Surplus of an ingredient whose cells are already full. Give it back, and
            -- stop if this pass placed nothing, since the next one would draw it again.
            api.select(SCRATCH_SLOT)
            api.dropDown()
            if not placed then break end
        end
    end

    -- Yielded nothing at all of an ingredient is a different thing for an operator to go
    -- and fix than yielded some but not enough, so the two keep separate codes.
    local anyOf = {}
    for _, cell in ipairs(order) do
        if api.getItemCount(cell) > 0 then anyOf[want[cell].expect] = true end
    end
    for _, cell in ipairs(order) do
        local entry = want[cell]
        local held = api.getItemCount(cell)
        if held == 0 then
            if anyOf[entry.expect] then
                return reply("INGREDIENT_SHORT", "the buffer held too little " ..
                    tostring(entry.expect))
            end
            return reply("BUFFER_EMPTY", "the buffer did not yield " .. tostring(entry.expect))
        end
        local detail = api.getItemDetail(cell)
        if type(detail) ~= "table" or detail.name ~= entry.expect then
            return reply("INGREDIENT_MISMATCH", "expected " .. tostring(entry.expect) ..
                " in slot " .. tostring(cell) .. " but got " ..
                tostring(type(detail) == "table" and detail.name or "nothing"))
        end
        if held < entry.need then
            return reply("INGREDIENT_SHORT", "the buffer held too little " ..
                tostring(entry.expect))
        end
    end
    return nil
end

-- Notifies at each phase boundary only -- staging, crafting, purging -- rather than trying
-- to describe the outcome here too. handle() already returns the outcome to the caller, and
-- a status screen driven by the rednet reply cannot fall out of sync with one driven by a
-- notify call that a mid-stage error might skip.
function Executor:craft(command)
    local api = self.turtle
    if type(command.steps) ~= "table" or #command.steps == 0 then
        return reply("EMPTY_COMMAND", "a craft command needs at least one step")
    end

    self.notify("staging", {job = command.job, item = command.result and command.result.name,
        quantity = command.result and command.result.count})

    local failure = self:_stage(command)
    if failure then
        self.notify("purging", {job = command.job})
        self:purge()
        return failure
    end

    self.notify("crafting", {job = command.job, item = command.result and command.result.name,
        quantity = command.result and command.result.count})
    local ok = api.craft()
    if not ok then
        self.notify("purging", {job = command.job})
        self:purge()
        return reply("CRAFT_FAILED", "the grid did not form a valid recipe")
    end

    self.notify("purging", {job = command.job})
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
