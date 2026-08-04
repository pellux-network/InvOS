local CraftPrefs = {}
CraftPrefs.__index = CraftPrefs

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

function CraftPrefs.default()
    return {schema=1, tags={}, recipes={}}
end

local function validateMap(map, label)
    if type(map) ~= "table" then return nil, label .. " must be a table" end
    for key, value in pairs(map) do
        if type(key) ~= "string" or key == "" then
            return nil, label .. " keys must be non-empty strings"
        end
        if type(value) ~= "string" or value == "" then
            return nil, label .. " values must be non-empty strings"
        end
    end
    return true
end

function CraftPrefs.validate(value)
    if type(value) ~= "table" or value.schema ~= 1 then
        return nil, "craft preference schema is invalid"
    end
    local tagsOk, tagsReason = validateMap(value.tags, "tag preferences")
    if not tagsOk then return nil, tagsReason end
    local recipesOk, recipesReason = validateMap(value.recipes, "recipe preferences")
    if not recipesOk then return nil, recipesReason end
    return true
end

-- Preferences are operator convenience, never correctness, so a corrupt or missing
-- file must degrade to "no pins" rather than block crafting. Same treatment the
-- learned metadata cache gets: re-pinnable, never authoritative.
--
-- The stored table is copied in and copied out. Sharing it would let a caller mutate
-- pins through a value() result, or let whatever was read off disk keep changing
-- underneath the store.
function CraftPrefs.new(value)
    local stored = value
    if not CraftPrefs.validate(stored) then stored = CraftPrefs.default() end
    return setmetatable({value_ = copy(stored)}, CraftPrefs)
end

function CraftPrefs:value() return copy(self.value_) end

function CraftPrefs:tagChoice(tagName) return self.value_.tags[tagName] end
function CraftPrefs:recipeChoice(itemId) return self.value_.recipes[itemId] end

function CraftPrefs:pinTag(tagName, itemId) self.value_.tags[tagName] = itemId end
function CraftPrefs:unpinTag(tagName) self.value_.tags[tagName] = nil end

function CraftPrefs:pinRecipe(itemId, recipeId) self.value_.recipes[itemId] = recipeId end
function CraftPrefs:unpinRecipe(itemId) self.value_.recipes[itemId] = nil end

return CraftPrefs
