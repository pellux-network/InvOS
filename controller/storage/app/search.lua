local Match = require("app.match")

local M = {}

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function normalize(value)
    return tostring(value or ""):lower():match("^%s*(.-)%s*$")
end

local function aliasMatches(group, query, aliases)
    for alias, target in pairs(aliases or {}) do
        if type(alias) == "string" and normalize(alias) == query then
            if target == group.name then return true end
            for _, variant in ipairs(group.variants) do
                if target == variant.identity_key then return true end
                for _, localAlias in ipairs(variant.aliases or {}) do
                    if target == localAlias then return true end
                end
            end
        end
    end
    for _, variant in ipairs(group.variants) do
        for _, alias in ipairs(variant.aliases or {}) do
            if normalize(alias) == query then return true end
        end
    end
    return false
end

local function variantScore(variant, group, query, tokens, aliases)
    local display = normalize(variant.display_name or variant.name)
    local registry = normalize(variant.name)
    local displayWords = Match.words(display)
    if display == query then return 500 end
    if Match.abbreviationMatch(displayWords, tokens) then return 400 end
    if registry == query or aliasMatches(group, query, aliases) then return 300 end
    if display:find(query, 1, true) or registry:find(query, 1, true) then return 200 end
    if #query >= 4 then
        if Match.editDistanceAtMostOne(display, query) then return 100 end
        for _, word in ipairs(displayWords) do
            if Match.editDistanceAtMostOne(word, query) then return 100 end
        end
        if Match.abbreviationFuzzyMatch(displayWords, tokens) then return 100 end
    end
    return nil
end

local function groups(index)
    -- core/index.lua precomputes and caches this grouping once per index build.
    -- Fall back to computing it here only for test doubles that lack the accessor.
    if type(index.groups) == "function" then return index:groups() end
    local byName, ordered = {}, {}
    for _, item in ipairs(index:items()) do
        local group = byName[item.name]
        if not group then
            group = {
                name=item.name, display_name=item.display_name or item.name,
                quantity=0, variants={}, request_count=0, last_requested=0,
            }
            byName[item.name] = group
            ordered[#ordered + 1] = group
        end
        local variant = {
            identity_key=item.key, name=item.name, nbt=item.nbt,
            display_name=item.display_name or item.name, quantity=item.quantity,
            max_count=item.max_count, aliases=copy(item.aliases or {}),
            request_count=item.request_count or 0,
            last_requested=item.last_requested or 0,
        }
        group.variants[#group.variants + 1] = variant
        group.quantity = group.quantity + (item.quantity or 0)
        group.request_count = math.max(group.request_count, item.request_count or 0)
        group.last_requested = math.max(group.last_requested, item.last_requested or 0)
    end
    for _, group in ipairs(ordered) do
        if #group.variants == 1 then group.identity_key = group.variants[1].identity_key end
    end
    return ordered
end

-- limit is optional: the Search page is bounded only by the number of distinct stocked
-- item groups (hundreds, not thousands), so its UI path leaves limit unset and gets every
-- match back. Passing a number still truncates, for any caller or test that wants a page.
function M.query(index, rawQuery, aliases, limit)
    local query = normalize(rawQuery)
    local tokens = Match.words(rawQuery)
    if limit ~= nil then limit = math.max(1, math.floor(limit)) end
    local results = {}
    for _, group in ipairs(groups(index)) do
        local score
        if query == "" then
            score = 0
        else
            for _, variant in ipairs(group.variants) do
                score = math.max(score or 0, variantScore(variant, group, query, tokens, aliases) or 0)
            end
            if score == 0 then score = nil end
        end
        if score then
            local result = copy(group)
            result.score = score
            results[#results + 1] = result
        end
    end
    table.sort(results, function(left, right)
        if query == "" then
            if left.request_count ~= right.request_count then
                return left.request_count > right.request_count
            end
            if left.last_requested ~= right.last_requested then
                return left.last_requested > right.last_requested
            end
            -- Once usage stats tie (often 0/0, never requested), alphabetical is a more
            -- useful default than quantity: it makes the list scannable and stable.
        else
            if left.score ~= right.score then return left.score > right.score end
            if left.quantity ~= right.quantity then return left.quantity > right.quantity end
        end
        local leftName, rightName = normalize(left.display_name), normalize(right.display_name)
        if leftName ~= rightName then return leftName < rightName end
        return left.name < right.name
    end)
    if limit then while #results > limit do table.remove(results) end end
    return results
end

function M.variants(result)
    local variants = copy(result and result.variants or {})
    table.sort(variants, function(left, right)
        local leftName, rightName = normalize(left.display_name), normalize(right.display_name)
        if leftName ~= rightName then return leftName < rightName end
        return tostring(left.nbt or "") < tostring(right.nbt or "")
    end)
    return variants
end

return M
