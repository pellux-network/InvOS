local RecipeRepo = {}
RecipeRepo.__index = RecipeRepo

-- The generated pack is deployed code under colossal/recipes/, not mutable data,
-- so it is required rather than read through shared/store.lua. A missing or broken
-- pack must never stop the controller booting: crafting simply reports nothing
-- craftable, exactly as a missing metadata cache degrades to re-learning.
local function defaultLoader(name)
    local ok, value = pcall(require, "recipes." .. name)
    if not ok or type(value) ~= "table" then return nil end
    return value
end

function RecipeRepo.new(deps)
    deps = deps or {}
    local self = setmetatable({
        loader = deps.loader or defaultLoader,
        shards = {}, custom = {}, customOutputs = {},
    }, RecipeRepo)
    -- Own the item arrays rather than aliasing them. defaultLoader returns require()'s
    -- cached module table, so interning a custom item straight into it would mutate
    -- state shared by every RecipeRepo and grow it on each construction.
    local loadedItems = self.loader("items") or {}
    self.items = {ids = {}, names = {}}
    for position, id in ipairs(loadedItems.ids or {}) do
        self.items.ids[position] = id
        self.items.names[position] = (loadedItems.names or {})[position]
    end
    self.index = self.loader("index") or {outputs={}, shard_count=1}
    self.tagData = self.loader("tags") or {tags={}}
    self.indexById = {}
    for position, id in ipairs(self.items.ids) do self.indexById[id] = position end
    -- Membership set rather than a scan of index.outputs. isCraftable is called once
    -- per search result across 639 outputs, so a linear scan would make the Crafting
    -- page quadratic in pack size on a computer where every tick is budgeted.
    self.outputSet = {}
    for _, position in ipairs(self.index.outputs or {}) do self.outputSet[position] = true end
    self:_loadCustom(deps.custom)
    return self
end

function RecipeRepo:indexOf(itemId) return self.indexById[itemId] end

function RecipeRepo:itemAt(position)
    return (self.items.ids or {})[position]
end

function RecipeRepo:displayName(itemId)
    local position = self.indexById[itemId]
    if not position then return itemId end
    return (self.items.names or {})[position] or itemId
end

function RecipeRepo:outputs()
    local seen, result = {}, {}
    local function add(id)
        if id and not seen[id] then
            seen[id] = true
            result[#result + 1] = {item=id, display_name=self:displayName(id)}
        end
    end
    for _, position in ipairs(self.index.outputs or {}) do add(self:itemAt(position)) end
    for _, id in ipairs(self.customOutputs) do add(id) end
    table.sort(result, function(left, right) return left.item < right.item end)
    return result
end

function RecipeRepo:isCraftable(itemId)
    if self.custom[itemId] then return true end
    local position = self.indexById[itemId]
    return position ~= nil and self.outputSet[position] == true
end

-- A recipe lives in shard 1 + (output_index % shard_count), so every recipe for one
-- output shares a shard and resolving an output costs exactly one file load.
-- math.floor keeps this Lua 5.2 safe; '//' does not exist there.
function RecipeRepo:_shardFor(position)
    local count = self.index.shard_count or 1
    if count < 1 then count = 1 end
    return 1 + (position - math.floor(position / count) * count)
end

function RecipeRepo:_shard(number)
    local cached = self.shards[number]
    if cached ~= nil then return cached end
    -- Zero-padded to two digits to match the filenames tools/recipe_pack.py emits
    -- ("pack_%02d.lua"). Unpadded names silently resolve to nothing: require fails,
    -- _shard degrades to an empty shard, and every output looks uncraftable while
    -- every unit test still passes, because the tests' loader is padding-agnostic.
    local loaded = self.loader(("pack_%02d"):format(number))
    if type(loaded) ~= "table" or type(loaded.recipes) ~= "table" then
        loaded = {recipes = {}}
    end
    self.shards[number] = loaded
    return loaded
end

function RecipeRepo:recipesFor(itemId)
    local overridden = self.custom[itemId]
    if overridden then return overridden end
    local position = self.indexById[itemId]
    if not position then return {} end
    local result = {}
    for _, body in ipairs(self:_shard(self:_shardFor(position)).recipes) do
        if body.output == position then result[#result + 1] = body end
    end
    return result
end

function RecipeRepo:expand(tagName)
    local members = (self.tagData.tags or {})[tagName]
    if type(members) ~= "table" then return {} end
    local result = {}
    for _, position in ipairs(members) do
        local id = self:itemAt(position)
        if id then result[#result + 1] = id end
    end
    return result
end

-- An ingredient reference is a tag name, an item index, or 0 for an empty cell.
-- Collapsing both forms here means the planner never branches on reference type.
function RecipeRepo:resolve(reference)
    if type(reference) == "string" then return self:expand(reference) end
    if type(reference) == "number" and reference > 0 then
        local id = self:itemAt(reference)
        if id then return {id} end
    end
    return {}
end

-- Custom recipes are hand-edited under colossal/data/, so they name items by ID and
-- tags with a leading '#'. Validation covers exactly the fields the loader will
-- dereference; anything looser would fail later, further from the mistake.
function RecipeRepo.validateCustom(value)
    if type(value) ~= "table" or value.schema ~= 1 or type(value.recipes) ~= "table" then
        return nil, "custom recipe schema is invalid"
    end
    for position, body in ipairs(value.recipes) do
        local label = "custom recipe " .. position
        if type(body) ~= "table" then return nil, label .. " must be a table" end
        if type(body.id) ~= "string" or body.id == "" then
            return nil, label .. " requires an id"
        end
        if type(body.output_item) ~= "string" or body.output_item == "" then
            return nil, label .. " requires an output_item"
        end
        if type(body.count) ~= "number" or body.count < 1 or body.count % 1 ~= 0 then
            return nil, label .. " requires a positive integer count"
        end
        local list = body.shaped and body.grid_items or body.ingredient_items
        if type(list) ~= "table" then
            return nil, label .. " requires grid_items or ingredient_items"
        end
    end
    return true
end

-- Interning an item the generated pack never mentioned extends this repo's own item
-- table. names has no entry for it, so displayName falls back to the raw ID, which is
-- correct: nothing knows a nicer name for it.
function RecipeRepo:_intern(itemId)
    local existing = self.indexById[itemId]
    if existing then return existing end
    self.items.ids[#self.items.ids + 1] = itemId
    local assigned = #self.items.ids
    self.indexById[itemId] = assigned
    return assigned
end

-- "#minecraft:planks" is a tag reference and stays a string minus the hash, because
-- that is how generated recipes encode a tag. Anything else is an item ID and becomes
-- an interned index. The result is the same shape a generated recipe has, so no
-- consumer ever branches on a recipe's origin.
function RecipeRepo:_customReference(entry)
    if type(entry) ~= "string" or entry == "" then return 0 end
    if entry:sub(1, 1) == "#" then return entry:sub(2) end
    return self:_intern(entry)
end

function RecipeRepo:_loadCustom(value)
    if value == nil then return end
    if not RecipeRepo.validateCustom(value) then return end
    for _, body in ipairs(value.recipes) do
        local target = body.output_item
        local normalised = {
            id = body.id, count = body.count, shaped = body.shaped == true,
            output = self:_intern(target),
        }
        if normalised.shaped then
            normalised.grid = {}
            for cell = 1, 9 do
                normalised.grid[cell] = self:_customReference((body.grid_items or {})[cell])
            end
        else
            normalised.ingredients = {}
            for position, entry in ipairs(body.ingredient_items or {}) do
                normalised.ingredients[position] = self:_customReference(entry)
            end
        end
        if not self.custom[target] then
            self.custom[target] = {}
            self.customOutputs[#self.customOutputs + 1] = target
        end
        self.custom[target][#self.custom[target] + 1] = normalised
    end
end

return RecipeRepo
