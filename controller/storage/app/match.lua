-- Shared text-matching helpers for the Search and Crafting pages: a query tokenizer,
-- Cisco-style multi-word abbreviation matching, and conservative one-edit fuzzy matching.
local M = {}

function M.words(text)
    local list = {}
    for word in tostring(text or ""):lower():gmatch("[%w_]+") do
        list[#list + 1] = word
    end
    return list
end

-- Cisco-style abbreviation matching: each query token must prefix-match a target word,
-- in order, skipping non-matching words in between. A single-token query behaves exactly
-- like a plain word-prefix check. "re mush" matches "red mushroom"; "plank oak" does not
-- match "oak planks" since the tokens are out of order.
function M.abbreviationMatch(words, tokens)
    if #tokens == 0 then return false end
    local wordIndex = 1
    for _, token in ipairs(tokens) do
        local matched = false
        while wordIndex <= #words do
            local word = words[wordIndex]
            wordIndex = wordIndex + 1
            if word:sub(1, #token) == token then
                matched = true
                break
            end
        end
        if not matched then return false end
    end
    return true
end

function M.editDistanceAtMostOne(value, query)
    if math.abs(#value - #query) > 1 then return false end
    local left, right, differences = 1, 1, 0
    while left <= #value and right <= #query do
        if value:sub(left, left) == query:sub(right, right) then
            left, right = left + 1, right + 1
        else
            differences = differences + 1
            if differences > 1 then return false end
            if #value > #query then left = left + 1
            elseif #query > #value then right = right + 1
            else left, right = left + 1, right + 1 end
        end
    end
    if left <= #value or right <= #query then differences = differences + 1 end
    return differences <= 1
end

-- Like abbreviationMatch, but each token may also match a word within one edit of its
-- prefix length, so a typo in one word of a multi-word query still finds the item.
-- Bounded to tokens of at least 4 characters, matching the single-word fuzzy threshold.
function M.abbreviationFuzzyMatch(words, tokens)
    if #tokens == 0 then return false end
    local wordIndex = 1
    for _, token in ipairs(tokens) do
        local matched = false
        while wordIndex <= #words do
            local word = words[wordIndex]
            wordIndex = wordIndex + 1
            if word:sub(1, #token) == token then
                matched = true
                break
            elseif #token >= 4 and M.editDistanceAtMostOne(word:sub(1, #token + 1), token) then
                matched = true
                break
            end
        end
        if not matched then return false end
    end
    return true
end

return M
