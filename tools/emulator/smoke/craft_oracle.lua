-- What the emulated world knows how to craft.
--
-- This is the harness's stand-in for Minecraft's own recipe resolution: given the
-- nine grid cells a turtle is holding, does that form a recipe, and what does it
-- yield?
--
-- There are two sources for that, and which one a scenario picks is a real
-- trade-off:
--
--  * `Oracle.fromPack` reads the recipe pack the controller itself plans against
--    -- every recipe, tags and all. This is the default, because modded items and
--    modded crafting are where the defects actually come from, and a world that
--    only knows five vanilla recipes cannot test any of them. Loading the whole
--    pack costs about 50ms for 26,000 recipes, so there is no reason to be
--    parsimonious about it.
--  * `Oracle.new(recipes)` takes an explicit table. Nothing derived, so the world
--    can be made to *disagree* with the pack -- which is what a `conditions`-gated
--    modded recipe does in game, and the failure that reaches a live installation.
--
-- The pack-backed oracle cannot catch "the pack claims a recipe the game does not
-- have", because it believes the same file. It does independently check the
-- *arrangement*: which cell holds what, how many, and whether an ingredient
-- really is a member of the tag the recipe asked for. That is the class the
-- turtle's slot mapping, `per_cell` and staging order defects all live in, and it
-- is checked here by a different implementation from the planner's.
--
-- Nothing here touches a peripheral, so it can be exercised on its own -- see
-- test_craft.py's OracleTests.

local Oracle = {}
Oracle.__index = Oracle

-- turtle.craft() reads inventory slots 1-3, 5-7 and 9-11 as the 3x3 grid. Slots
-- 4, 8 and 12-16 sit outside it. Only positions 1-3 map to themselves, which is
-- why passing a grid position straight through as a slot puts most of a recipe in
-- the wrong place. Written out rather than computed, so it cannot drift silently
-- along with the controller's own arithmetic in app/craft_service.lua.
Oracle.GRID_SLOTS = {1, 2, 3, 5, 6, 7, 9, 10, 11}

Oracle.DEFAULT_PACK_DIR = "/storage/recipes/"

local LOG, PLANK = "minecraft:oak_log", "minecraft:oak_planks"
local COAL, STICK = "minecraft:coal", "minecraft:stick"

-- A handful of vanilla shapes for scenarios that want a world knowing exactly
-- this much and no more. Outputs are written as literals so the ids this table
-- can produce are greppable from the host without a Lua interpreter.
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

-- -- explicit tables ---------------------------------------------------------

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

function Oracle.new(recipes)
    return setmetatable({recipes = recipes or Oracle.DEFAULT_RECIPES}, Oracle)
end

-- -- the generated pack -------------------------------------------------------

local function loadChunk(path)
    if not fs.exists(path) then return nil end
    local chunk = loadfile(path)
    if not chunk then return nil end
    local ok, value = pcall(chunk)
    if not ok or type(value) ~= "table" then return nil end
    return value
end

--- Build an oracle from a generated recipe pack.
--
-- Every shard is loaded eagerly. The controller loads them lazily because it runs
-- on a computer where each tick is budgeted; this runs beside it in the emulator
-- with no such constraint, and measuring beat guessing: 26,087 recipes across 24
-- shards parse in about 50ms and cost roughly 11MB of heap.
--
-- Returns nil when there is no pack, so the caller can fall back rather than
-- booting a world that can craft nothing.
function Oracle.fromPack(dir)
    dir = dir or Oracle.DEFAULT_PACK_DIR
    local items = loadChunk(dir .. "items.lua")
    local index = loadChunk(dir .. "index.lua")
    if not items or type(items.ids) ~= "table" or not index then return nil end
    local tagData = loadChunk(dir .. "tags.lua") or {tags = {}}

    local self = setmetatable({
        ids = items.ids,
        positionOf = {},
        tagMembers = {},
        tagsOf = {},
        shapedByCell = {},
        shapelessByRef = {},
        recipeCount = 0,
    }, Oracle)

    for position, id in ipairs(items.ids) do self.positionOf[id] = position end

    -- Tag membership both ways: as a set for verifying a cell, and inverted so a
    -- concrete item can name the tags that would accept it when choosing
    -- candidates.
    for name, members in pairs(tagData.tags or {}) do
        local set = {}
        for _, position in ipairs(members) do
            set[position] = true
            local owners = self.tagsOf[position]
            if not owners then
                owners = {}
                self.tagsOf[position] = owners
            end
            owners[#owners + 1] = name
        end
        self.tagMembers[name] = set
    end

    local function bucket(store, key, recipe)
        if key == nil or key == 0 then return end
        local list = store[key]
        if not list then
            list = {}
            store[key] = list
        end
        list[#list + 1] = recipe
    end

    for shard = 1, (index.shard_count or 1) do
        local loaded = loadChunk(dir .. ("pack_%02d.lua"):format(shard))
        for _, recipe in ipairs(loaded and loaded.recipes or {}) do
            self.recipeCount = self.recipeCount + 1
            if recipe.shaped and type(recipe.grid) == "table" then
                -- Keyed by the recipe's FIRST occupied cell. A grid can only match
                -- if its own first occupied cell is that same position, so this
                -- narrows 26,000 recipes to a handful without missing any.
                for position = 1, 9 do
                    local reference = recipe.grid[position]
                    if reference and reference ~= 0 then
                        bucket(self.shapedByCell, position .. "\0" .. tostring(reference), recipe)
                        break
                    end
                end
            elseif type(recipe.ingredients) == "table" then
                -- Position means nothing here, so the recipe is filed under every
                -- ingredient it names and deduplicated at match time.
                local seen = {}
                for _, reference in ipairs(recipe.ingredients) do
                    if reference and reference ~= 0 and not seen[reference] then
                        seen[reference] = true
                        bucket(self.shapelessByRef, reference, recipe)
                    end
                end
            end
        end
    end
    return self
end

function Oracle:_referenceMatches(reference, position)
    if reference == nil or reference == 0 then return position == nil end
    if position == nil then return false end
    if type(reference) == "number" then return reference == position end
    local members = self.tagMembers[reference]
    return members ~= nil and members[position] == true
end

function Oracle:_shapedPackMatches(recipe, positions)
    for cell = 1, 9 do
        if not self:_referenceMatches(recipe.grid[cell], positions[cell]) then
            return false
        end
    end
    return true
end

-- A shapeless recipe with tags is a bipartite matching problem: one ingredient
-- may accept several of the staged items and vice versa. Nine cells at most, so
-- backtracking is both correct and instant -- and greedy is not, because taking
-- the first item a tag accepts can strand a later ingredient that only that item
-- could satisfy.
function Oracle:_shapelessPackMatches(recipe, items)
    local ingredients = recipe.ingredients
    if #ingredients ~= #items then return false end
    local used = {}
    local function assign(nth)
        if nth > #ingredients then return true end
        for candidate = 1, #items do
            if not used[candidate]
                and self:_referenceMatches(ingredients[nth], items[candidate]) then
                used[candidate] = true
                if assign(nth + 1) then return true end
                used[candidate] = false
            end
        end
        return false
    end
    return assign(1)
end

function Oracle:_matchPack(grid)
    local positions, items, first = {}, {}, nil
    for cell = 1, 9 do
        local id = grid[cell]
        if id then
            local position = self.positionOf[id]
            -- An item the pack has never heard of cannot be in any recipe, and
            -- leaving it nil would read as an empty cell.
            if not position then return nil end
            positions[cell] = position
            items[#items + 1] = position
            if not first then first = cell end
        end
    end
    if not first then return nil end

    local candidates, seen = {}, {}
    local function offer(list)
        for _, recipe in ipairs(list or {}) do
            if not seen[recipe] then
                seen[recipe] = true
                candidates[#candidates + 1] = recipe
            end
        end
    end

    local firstPosition = positions[first]
    offer(self.shapedByCell[first .. "\0" .. tostring(firstPosition)])
    offer(self.shapelessByRef[firstPosition])
    for _, name in ipairs(self.tagsOf[firstPosition] or {}) do
        offer(self.shapedByCell[first .. "\0" .. name])
        offer(self.shapelessByRef[name])
    end

    for _, recipe in ipairs(candidates) do
        local matched
        if recipe.shaped then
            matched = self:_shapedPackMatches(recipe, positions)
        else
            matched = self:_shapelessPackMatches(recipe, items)
        end
        if matched then
            local output = self.ids[recipe.output]
            if output then
                return {output = output, count = recipe.count or 1, id = recipe.id}
            end
        end
    end
    return nil
end

--- Match a staged grid. Returns {output=id, count=n}, or nil when nothing matches.
-- @param grid positions 1-9 to item id (nil for an empty cell)
function Oracle:match(grid)
    if self.recipes then
        for _, recipe in ipairs(self.recipes) do
            if recipe.shaped then
                if shapedMatches(recipe.shaped, grid) then return recipe end
            elseif recipe.shapeless then
                if shapelessMatches(recipe.shapeless, grid) then return recipe end
            end
        end
        return nil
    end
    return self:_matchPack(grid)
end

--- The oracle a world spec asks for.
--
-- An explicit table means exactly that table, including an empty one -- that is
-- how a scenario makes the world know nothing. Otherwise the generated pack is
-- used, falling back to the small vanilla table when no pack is installed.
function Oracle.forSpec(recipes, dir)
    if type(recipes) == "table" then return Oracle.new(recipes) end
    return Oracle.fromPack(dir) or Oracle.new(Oracle.DEFAULT_RECIPES)
end

return Oracle
