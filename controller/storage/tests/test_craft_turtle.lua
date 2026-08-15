-- Loaded by explicit path rather than by extending package.path. Prepending the
-- turtle's tree would shadow the controller's own modules for every test that runs
-- after this one -- deployment_manifest exists under both roots.
local Executor = dofile("../turtle/crafter/executor.lua")
local T = require("tests.mock_cc")

-- A turtle inventory model: 16 slots, plus a buffer beneath it that suckDown draws from
-- in ascending slot order, which is the ordering the whole protocol depends on.
local function fakeTurtle(bufferSlots, options)
    options = options or {}
    local api = {slots = {}, selected = 1, dropped = {}, crafts = 0}
    api.buffer = bufferSlots or {}

    function api.select(slot) api.selected = slot; return true end
    function api.getItemCount(slot) local e = api.slots[slot or api.selected]; return e and e.count or 0 end
    function api.getItemDetail(slot)
        local entry = api.slots[slot or api.selected]
        if not entry then return nil end
        return {name = entry.name, count = entry.count}
    end
    -- A turtle slot holds at most one stack. Modelling that matters: without it the fake
    -- accepts 128 planks in one slot and a real turtle does not, which is exactly the
    -- kind of gap that lets a batching bug reach the game.
    local STACK = 64
    function api.suckDown(limit)
        -- Takes from the lowest occupied buffer slot, from one slot per call, exactly as
        -- CC does, and never beyond what the selected slot can still hold.
        local target = api.slots[api.selected]
        local space = STACK - (target and target.count or 0)
        if space <= 0 then return false end
        for index, entry in ipairs(api.buffer) do
            if entry and entry.count > 0 then
                if target and target.name ~= entry.name then return false end
                local taken = math.min(limit or entry.count, entry.count, space)
                if taken <= 0 then return false end
                entry.count = entry.count - taken
                if entry.count == 0 then api.buffer[index] = false end
                if target then target.count = target.count + taken
                else api.slots[api.selected] = {name = entry.name, count = taken} end
                return true
            end
        end
        return false
    end
    function api.transferTo(slot, count)
        local from = api.slots[api.selected]
        if not from or from.count < count then return false end
        from.count = from.count - count
        local target = api.slots[slot]
        if target and target.name ~= from.name then return false end
        if (target and target.count or 0) + count > STACK then return false end
        if target then target.count = target.count + count
        else api.slots[slot] = {name = from.name, count = count} end
        if from.count == 0 then api.slots[api.selected] = nil end
        return true
    end
    function api.dropDown()
        local entry = api.slots[api.selected]
        if not entry then return false end
        api.dropped[#api.dropped + 1] = {name = entry.name, count = entry.count}
        api.slots[api.selected] = nil
        return true
    end
    function api.craft()
        api.crafts = api.crafts + 1
        if options.craftFails then return false end
        -- Consume one from each occupied grid cell and place a result.
        for _, slot in ipairs({1,2,3,5,6,7,9,10,11}) do
            local entry = api.slots[slot]
            if entry then
                entry.count = entry.count - 1
                if entry.count <= 0 then api.slots[slot] = nil end
            end
        end
        api.slots[16] = {name = options.result or "minecraft:chest", count = 1}
        return true
    end
    return api
end

local function chestCommand()
    return {op="craft", job="craft-1",
        steps={{expect="minecraft:oak_planks", cells={1,2,3,5,7,9,10,11}, per_cell=1}},
        result={name="minecraft:chest", count=1}}
end

local function held(api)
    local total = 0
    for _ = 1, 16 do end
    for slot = 1, 16 do
        local entry = api.slots[slot]
        if entry then total = total + entry.count end
    end
    return total
end

return {
    {name="a craft stages the grid, crafts, and returns everything",run=function()
        local api = fakeTurtle({{name="minecraft:oak_planks", count=8}})
        local result = Executor.new({turtle=api}):handle(chestCommand())
        T.equal(result.ok, true)
        T.equal(api.crafts, 1)
        T.equal(held(api), 0, "the turtle must end every job empty")
        T.equal(api.dropped[1].name, "minecraft:chest")
    end},
    {name="an ingredient is spread across every cell that uses it",run=function()
        local api = fakeTurtle({{name="minecraft:oak_planks", count=8}})
        local executor = Executor.new({turtle=api})
        -- Stop before crafting so placement can be inspected.
        local failure = executor:_stage(chestCommand())
        T.equal(failure, nil)
        for _, cell in ipairs({1,2,3,5,7,9,10,11}) do
            T.equal(api.slots[cell].count, 1, "cell " .. cell)
        end
        T.equal(api.slots[6], nil, "the empty centre cell stays empty")
    end},
    {name="the wrong ingredient is refused and everything is returned",run=function()
        local api = fakeTurtle({{name="minecraft:cobblestone", count=8}})
        local result = Executor.new({turtle=api}):handle(chestCommand())
        T.equal(result.ok, false)
        T.equal(result.code, "INGREDIENT_MISMATCH")
        T.equal(api.crafts, 0, "nothing is crafted from the wrong item")
        T.equal(held(api), 0, "a refusal still leaves the turtle empty")
        T.equal(api.dropped[1].name, "minecraft:cobblestone", "the item goes back to the buffer")
    end},
    {name="an empty buffer is refused rather than crafting nothing",run=function()
        local api = fakeTurtle({})
        local result = Executor.new({turtle=api}):handle(chestCommand())
        T.equal(result.ok, false)
        T.equal(result.code, "BUFFER_EMPTY")
        T.equal(api.crafts, 0)
    end},
    {name="too little of an ingredient is refused",run=function()
        local api = fakeTurtle({{name="minecraft:oak_planks", count=3}})
        local result = Executor.new({turtle=api}):handle(chestCommand())
        T.equal(result.ok, false)
        T.equal(result.code, "INGREDIENT_SHORT")
        T.equal(held(api), 0)
    end},
    {name="a failed craft returns the ingredients",run=function()
        local api = fakeTurtle({{name="minecraft:oak_planks", count=8}}, {craftFails=true})
        local result = Executor.new({turtle=api}):handle(chestCommand())
        T.equal(result.ok, false)
        T.equal(result.code, "CRAFT_FAILED")
        T.equal(held(api), 0, "a failed craft must not strand ingredients in the turtle")
    end},
    {name="multiple ingredients are staged in the order the buffer presents them",run=function()
        local api = fakeTurtle({
            {name="minecraft:coal", count=1},
            {name="minecraft:stick", count=1},
        })
        local result = Executor.new({turtle=api}):handle({op="craft", job="craft-2",
            steps={
                {expect="minecraft:coal", cells={1}, per_cell=1},
                {expect="minecraft:stick", cells={5}, per_cell=1},
            },
            result={name="minecraft:torch", count=4}})
        T.equal(result.ok, true)
        T.equal(held(api), 0)
    end},
    {name="a batched craft pulls per_cell copies into every cell",run=function()
        local api = fakeTurtle({{name="minecraft:oak_planks", count=64}})
        local executor = Executor.new({turtle=api})
        local failure = executor:_stage({steps={{expect="minecraft:oak_planks",
            cells={1,2,3,5}, per_cell=8}}})
        T.equal(failure, nil)
        for _, cell in ipairs({1,2,3,5}) do
            T.equal(api.slots[cell].count, 8, "cell " .. cell .. " holds the batch")
        end
    end},
    {name="purge empties every slot, not just the grid",run=function()
        local api = fakeTurtle({})
        api.slots[4] = {name="minecraft:bucket", count=1}
        api.slots[16] = {name="minecraft:chest", count=1}
        api.slots[2] = {name="minecraft:oak_planks", count=3}
        local dropped = Executor.new({turtle=api}):purge()
        T.equal(dropped, 3, "byproducts outside the grid must come back too")
        T.equal(held(api), 0)
    end},
    {name="ping answers without touching the inventory",run=function()
        local api = fakeTurtle({{name="minecraft:oak_planks", count=8}})
        local result = Executor.new({turtle=api, label="crafter"}):handle({op="ping"})
        T.equal(result.ok, true)
        T.equal(result.label, "crafter")
        T.equal(#api.dropped, 0)
    end},
    {name="update is acked without touching the inventory",run=function()
        local api = fakeTurtle({{name="minecraft:oak_planks", count=8}})
        local result = Executor.new({turtle=api}):handle({op="update", ref="v1.2.3"})
        T.equal(result.ok, true)
        T.equal(#api.dropped, 0)
    end},
    {name="purge is available as its own command",run=function()
        local api = fakeTurtle({})
        api.slots[1] = {name="minecraft:oak_planks", count=4}
        local result = Executor.new({turtle=api}):handle({op="purge"})
        T.equal(result.ok, true)
        T.equal(result.dropped, 1)
    end},
    {name="an unknown or malformed command is refused, not guessed at",run=function()
        local api = fakeTurtle({})
        local executor = Executor.new({turtle=api})
        T.equal(executor:handle({op="explode"}).code, "UNKNOWN_OP")
        T.equal(executor:handle({}).code, "BAD_COMMAND")
        T.equal(executor:handle("nonsense").code, "BAD_COMMAND")
        T.equal(executor:handle({op="craft", steps={}}).code, "EMPTY_COMMAND")
    end},
    {name="an unexpected error still empties the turtle",run=function()
        local api = fakeTurtle({{name="minecraft:oak_planks", count=8}})
        local real = api.getItemDetail
        local calls = 0
        api.getItemDetail = function(slot)
            calls = calls + 1
            if calls > 2 then error("peripheral exploded") end
            return real(slot)
        end
        local result = Executor.new({turtle=api}):handle(chestCommand())
        T.equal(result.ok, false)
        T.equal(result.code, "EXECUTOR_ERROR")
        T.equal(held(api), 0, "items must never be stranded where nothing can see them")
    end},
    {name="a full-stack batch across several cells does not overflow one slot",run=function()
        -- 500 sticks plans as batch=64 over two plank cells, so the step asks for 128
        -- planks. Staging them into one slot first cannot work: a slot holds 64.
        local api = fakeTurtle({{name="minecraft:oak_planks", count=128}})
        local result = Executor.new({turtle=api}):handle({op="craft", job="craft-1",
            steps={{expect="minecraft:oak_planks", cells={1,2}, per_cell=64}},
            result={name="minecraft:stick", count=256}})
        T.equal(result.ok, true, "a full batch must stage without overflowing a slot")
        T.equal(api.crafts, 1)
    end},
    {name="each cell is filled to the batch size",run=function()
        local api = fakeTurtle({{name="minecraft:oak_planks", count=128}})
        local executor = Executor.new({turtle=api})
        local failure = executor:_stage({steps={{expect="minecraft:oak_planks", cells={1,2}, per_cell=64}}})
        T.equal(failure, nil)
        T.equal(api.slots[1].count, 64)
        T.equal(api.slots[2].count, 64)
    end},
    {name="an ingredient spread across several buffer slots is still gathered",run=function()
        -- The buffer holds one item across several stacks, which is what 250 planks
        -- actually looks like in a chest.
        local api = fakeTurtle({
            {name="minecraft:oak_planks", count=64},
            {name="minecraft:oak_planks", count=64},
        })
        local executor = Executor.new({turtle=api})
        local failure = executor:_stage({steps={{expect="minecraft:oak_planks", cells={1,2}, per_cell=64}}})
        T.equal(failure, nil, "a cell must be filled from more than one buffer stack")
        T.equal(api.slots[1].count, 64)
        T.equal(api.slots[2].count, 64)
    end},
    {name="every cell is verified, not just the first",run=function()
        local api = fakeTurtle({
            {name="minecraft:oak_planks", count=1},
            {name="minecraft:cobblestone", count=1},
        })
        local result = Executor.new({turtle=api}):handle({op="craft", job="craft-1",
            steps={{expect="minecraft:oak_planks", cells={1,2}, per_cell=1}},
            result={name="minecraft:stick", count=4}})
        T.equal(result.ok, false, "the second cell got the wrong item")
        T.equal(result.code, "INGREDIENT_MISMATCH")
        T.equal(held(api), 0)
    end},

    {name="a multi-ingredient recipe stages whatever order the buffer is in",run=function()
        -- suckDown always takes the buffer's lowest occupied slot, so filling cells in
        -- recipe order only works when the buffer happens to agree. The buffer is filled
        -- by one withdrawal per ingredient and those land wherever there is room, so it
        -- routinely does not. Every craft tested before this had a single ingredient,
        -- which is why it never showed: with one item type any order is the right order.
        local api = fakeTurtle({
            {name="the_vault:vault_essence", count=2},
            {name="minecraft:gold_ingot", count=2},
        })
        local failure = Executor.new({turtle=api}):_stage({steps={
            {expect="minecraft:gold_ingot", cells={1, 3}, per_cell=1},
            {expect="the_vault:vault_essence", cells={5, 7}, per_cell=1},
        }})
        T.equal(failure, nil, "the buffer holds exactly what the step needs")
        T.equal(api.getItemDetail(1).name, "minecraft:gold_ingot")
        T.equal(api.getItemDetail(3).name, "minecraft:gold_ingot")
        T.equal(api.getItemDetail(5).name, "the_vault:vault_essence")
        T.equal(api.getItemDetail(7).name, "the_vault:vault_essence")
    end},
    {name="interleaved stacks of the same ingredient still land together",run=function()
        -- Two withdrawals of one item can be split across slots with another item between
        -- them, so a cell's ingredient is not necessarily contiguous in the buffer.
        local api = fakeTurtle({
            {name="minecraft:gold_ingot", count=1},
            {name="the_vault:vault_essence", count=2},
            {name="minecraft:gold_ingot", count=1},
        })
        local failure = Executor.new({turtle=api}):_stage({steps={
            {expect="minecraft:gold_ingot", cells={1, 3}, per_cell=1},
            {expect="the_vault:vault_essence", cells={5, 7}, per_cell=1},
        }})
        T.equal(failure, nil)
        T.equal(api.getItemDetail(1).name, "minecraft:gold_ingot")
        T.equal(api.getItemDetail(3).name, "minecraft:gold_ingot")
        T.equal(api.getItemDetail(5).name, "the_vault:vault_essence")
    end},
    {name="an item no cell wants is still a clean refusal",run=function()
        local api = fakeTurtle({
            {name="minecraft:dirt", count=1},
            {name="minecraft:gold_ingot", count=1},
        })
        local result = Executor.new({turtle=api}):handle({op="craft", job="craft-1",
            steps={{expect="minecraft:gold_ingot", cells={1}, per_cell=1}},
            result={name="mod:thing", count=1}})
        T.equal(result.ok, false)
        T.equal(result.code, "INGREDIENT_MISMATCH")
        T.equal(held(api), 0, "and the turtle keeps nothing")
    end},
    {name="a short buffer reports what is missing rather than crafting",run=function()
        local api = fakeTurtle({{name="minecraft:gold_ingot", count=1}})
        local failure = Executor.new({turtle=api}):_stage({steps={
            {expect="minecraft:gold_ingot", cells={1, 3}, per_cell=1},
        }})
        T.truthy(failure ~= nil, "two cells needed, one ingot available")
        T.equal(failure.code, "INGREDIENT_SHORT")
    end},

}
