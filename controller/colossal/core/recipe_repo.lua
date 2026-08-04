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

return RecipeRepo
