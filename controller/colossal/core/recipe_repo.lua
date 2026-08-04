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
        shards = {}, byOutput = nil,
    }, RecipeRepo)
    self.items = self.loader("items") or {ids={}, names={}}
    self.index = self.loader("index") or {outputs={}, shard_count=1}
    self.tagData = self.loader("tags") or {tags={}}
    self.indexById = {}
    for position, id in ipairs(self.items.ids or {}) do self.indexById[id] = position end
    return self
end

function RecipeRepo:itemAt(position)
    return (self.items.ids or {})[position]
end

function RecipeRepo:displayName(itemId)
    local position = self.indexById[itemId]
    if not position then return itemId end
    return (self.items.names or {})[position] or itemId
end

function RecipeRepo:outputs()
    local result = {}
    for _, position in ipairs(self.index.outputs or {}) do
        local id = self:itemAt(position)
        if id then
            result[#result + 1] = {item=id, display_name=self:displayName(id)}
        end
    end
    table.sort(result, function(left, right) return left.item < right.item end)
    return result
end

function RecipeRepo:isCraftable(itemId)
    local position = self.indexById[itemId]
    if not position then return false end
    for _, output in ipairs(self.index.outputs or {}) do
        if output == position then return true end
    end
    return false
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

return RecipeRepo
