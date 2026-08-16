-- What the emulated world knows how to craft.
--
-- This is the harness's stand-in for Minecraft's own recipe resolution: given the
-- nine grid cells a turtle is holding, does that form a recipe, and what does it
-- yield? It is deliberately NOT derived from the controller's recipe pack. An
-- oracle built from the same data the planner planned from can never disagree
-- with it, and disagreement is exactly the failure worth reproducing -- a modded
-- pack describes recipes a running game does not have, and the controller then
-- consumes real materials and blocks on OUTPUT_MISSING.
--
-- The cost of independence is coverage: an item outside this table is uncraftable
-- in the emulator no matter what the pack says. That is recorded in
-- docs/emulator.md, because a green run must not be read as more than it is.
--
-- Nothing here touches a peripheral or a global, so it can be exercised on its
-- own -- see test_craft.py's OracleTests.

local Oracle = {}
Oracle.__index = Oracle

-- turtle.craft() reads inventory slots 1-3, 5-7 and 9-11 as the 3x3 grid. Slots
-- 4, 8 and 12-16 sit outside it. Only positions 1-3 map to themselves, which is
-- why passing a grid position straight through as a slot puts most of a recipe in
-- the wrong place. Written out rather than computed, so it cannot drift silently
-- along with the controller's own arithmetic in app/craft_service.lua.
Oracle.GRID_SLOTS = {1, 2, 3, 5, 6, 7, 9, 10, 11}

local LOG, PLANK = "minecraft:oak_log", "minecraft:oak_planks"
local COAL, STICK = "minecraft:coal", "minecraft:stick"

-- Vanilla shapes, matching the fixture recipe pack the emulated controller plans
-- against. The torch earns its place: two ingredients is the smallest recipe that
-- can put the wrong item in a cell, and every craft that ran before a live
-- installation found that bug had a single ingredient, where any order is right.
--
-- Outputs are written as literals rather than through the locals above, so the
-- ids this world can produce can be read straight out of the file --
-- test_craft.py's OraclePackAgreementTests does exactly that to check every one
-- of them exists in the recipe pack the controller plans against.
Oracle.DEFAULT_RECIPES = {
    {output = "minecraft:oak_planks", count = 4, shapeless = {LOG}},
    {output = "minecraft:stick", count = 4, shaped = {[1] = PLANK, [4] = PLANK}},
    {output = "minecraft:torch", count = 4, shaped = {[1] = COAL, [4] = STICK}},
    {output = "minecraft:crafting_table", count = 1,
     shaped = {[1] = PLANK, [2] = PLANK, [4] = PLANK, [5] = PLANK}},
    {output = "minecraft:chest", count = 1,
     shaped = {[1] = PLANK, [2] = PLANK, [3] = PLANK, [4] = PLANK,
               [6] = PLANK, [7] = PLANK, [8] = PLANK, [9] = PLANK}},
}

function Oracle.new(recipes)
    return setmetatable({recipes = recipes or Oracle.DEFAULT_RECIPES}, Oracle)
end

-- Shaped recipes match on exact positions. Minecraft would let a 2x2 pattern sit
-- anywhere in the 3x3 grid; this deliberately will not, because the controller
-- always emits absolute positions from the pack, so a grid that does not land
-- where the recipe says is the defect being hunted rather than a variation to
-- tolerate.
local function shapedMatches(pattern, grid)
    for position = 1, 9 do
        if pattern[position] ~= grid[position] then return false end
    end
    return true
end

local function shapelessMatches(ingredients, grid)
    local wanted = {}
    for _, id in ipairs(ingredients) do wanted[id] = (wanted[id] or 0) + 1 end
    for position = 1, 9 do
        local id = grid[position]
        if id then
            if not wanted[id] or wanted[id] == 0 then return false end
            wanted[id] = wanted[id] - 1
        end
    end
    for _, remaining in pairs(wanted) do
        if remaining ~= 0 then return false end
    end
    return true
end

--- Match a staged grid. Returns the recipe, or nil when nothing matches.
-- @param grid positions 1-9 to item id (nil for an empty cell)
function Oracle:match(grid)
    for _, recipe in ipairs(self.recipes) do
        if recipe.shaped then
            if shapedMatches(recipe.shaped, grid) then return recipe end
        elseif recipe.shapeless then
            if shapelessMatches(recipe.shapeless, grid) then return recipe end
        end
    end
    return nil
end

return Oracle
