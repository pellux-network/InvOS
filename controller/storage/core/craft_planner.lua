local CraftPlanner = {}

-- turtle.craft() crafts repeatedly until a grid cell empties, so one call can yield up
-- to 64x the recipe output. Batching is what keeps a large craft to a handful of turtle
-- round trips instead of hundreds.
local BATCH_CAP = 64
local DEFAULT_STACK_LIMIT = 64
-- Crafting depth of the requested item is 1, so this permits five levels of sub-craft.
local DEFAULT_DEPTH_LIMIT = 6
-- Bounds the probe in maxCraftable so a recipe with a free ingredient cannot spin.
local MAX_CRAFTABLE_CAP = 100000
-- How many alternatives a single decision may actually try before settling for its
-- top-ranked option. Both searches roll the ledger back between attempts, so their cost
-- multiplies: on the live modpack minecraft:planks has 412 members and minecraft:stick
-- has 7 recipes. An exhaustive search does terminate, but it took minutes for a single
-- plan on host Lua -- and planning runs inline on a keypress, on a computer that is far
-- slower than the host, so minutes is no better than never here.
--
-- Ranking is what makes small caps safe. Members and recipes that are already in stock
-- sort first, so the case that matters succeeds on the first attempt; the cap only bites
-- when nothing on hand fits, and trying the 400th plank type would not have helped.
local MAX_TAG_TRIALS = 8
local MAX_RECIPE_TRIALS = 4
-- A backstop for pathological trees, where each bounded decision is cheap but there are
-- very many of them. Counts attempted resolutions across the whole plan.
local RESOLVE_BUDGET = 20000

local function ceilDiv(numerator, denominator)
    local whole = math.floor(numerator / denominator)
    if whole * denominator < numerator then whole = whole + 1 end
    return whole
end

local function failure(code, message)
    return {ok=false, reason={code=code, message=message},
        steps={}, withdrawals={}, shortfalls={}, chosen={}}
end

-- Distinct ingredient references in first-appearance order, with how many grid cells
-- each occupies. Order matters: it is what makes a plan reproducible.
local function cellDemand(body)
    local cells = body.shaped and body.grid or body.ingredients
    local order, counts = {}, {}
    for _, reference in ipairs(cells or {}) do
        if reference ~= 0 then
            if counts[reference] == nil then
                counts[reference] = 0
                order[#order + 1] = reference
            end
            counts[reference] = counts[reference] + 1
        end
    end
    return order, counts
end

-- Crafted surplus sits in the buffer and costs nothing to reuse, so it counts toward
-- availability alongside unreserved storage stock.
local function availableTo(state, itemId)
    local free = (state.available(itemId) or 0) - (state.reserved[itemId] or 0)
    if free < 0 then free = 0 end
    return free + (state.surplus[itemId] or 0)
end

-- Every recipe for an item, best first. Committing to one choice was fine while the pack
-- was vanilla and nearly every output had a single recipe. A modpack breaks that: in the
-- live pack minecraft:stick has seven recipes and the two that sort first want a modded
-- wood nobody stocks, so a single choice reported INSUFFICIENT_MATERIALS with usable
-- planks on the shelf. The caller tries these in order and rolls back between attempts,
-- exactly as tag candidates already worked.
--
-- Ranking exists so the search normally stops at the first attempt: a recipe whose
-- ingredients are already in stock is tried before one that merely could be crafted.
local function orderedRecipes(state, itemId)
    local recipes = state.repo:recipesFor(itemId)
    if #recipes <= 1 then return recipes end
    local pinned = state.prefs and state.prefs:recipeChoice(itemId)
    local ranked = {}
    for index, body in ipairs(recipes) do
        local order = cellDemand(body)
        local stocked = 0
        for _, reference in ipairs(order) do
            if type(reference) == "number" and reference > 0 then
                local ingredient = state.repo:itemAt(reference)
                if ingredient and availableTo(state, ingredient) > 0 then
                    stocked = stocked + 1
                end
            elseif type(reference) == "string" then
                for _, member in ipairs(state.repo:expand(reference)) do
                    if availableTo(state, member) > 0 then stocked = stocked + 1; break end
                end
            end
        end
        ranked[#ranked + 1] = {body=body, index=index, stocked=stocked,
            kinds=#order, pinned=(pinned ~= nil and body.id == pinned) and 1 or 0}
    end
    table.sort(ranked, function(left, right)
        if left.pinned ~= right.pinned then return left.pinned > right.pinned end
        if left.stocked ~= right.stocked then return left.stocked > right.stocked end
        if left.kinds ~= right.kinds then return left.kinds < right.kinds end
        return tostring(left.body.id) < tostring(right.body.id)
    end)
    local order = {}
    for index, entry in ipairs(ranked) do order[index] = entry.body end
    return order
end

-- Is anything satisfying this reference already on hand? Tag answers are memoised for
-- the life of the plan: minecraft:planks has 412 members on the live pack, and this is
-- asked once per candidate per recipe while ranking.
local function stockedReference(state, reference)
    if type(reference) == "number" and reference > 0 then
        local ingredient = state.repo:itemAt(reference)
        return ingredient ~= nil and availableTo(state, ingredient) > 0
    end
    if type(reference) ~= "string" then return false end
    local cached = state.tagStocked[reference]
    if cached ~= nil then return cached end
    local found = false
    for _, member in ipairs(state.repo:expand(reference)) do
        if availableTo(state, member) > 0 then found = true; break end
    end
    state.tagStocked[reference] = found
    return found
end

-- One level of lookahead: does some recipe for this item have every ingredient in stock?
--
-- Without it, ranking sees only what is directly on hand. With spruce logs and no planks
-- at all, every one of the 412 plank types scores identically and the trial order falls
-- back to item id, so the search spends its whole budget on woods that cannot be made
-- from the stock present. Lookahead puts spruce_planks first, where it belongs.
--
-- Memoised, and deliberately not invalidated as the ledger moves: this only decides trial
-- order, and every attempt is still verified and rolled back.
local function craftableFromStock(state, itemId)
    local cached = state.reachable[itemId]
    if cached ~= nil then return cached end
    state.reachable[itemId] = 0
    local score = 0
    for _, body in ipairs(state.repo:recipesFor(itemId)) do
        local order = cellDemand(body)
        if #order > 0 then
            local complete = true
            for _, reference in ipairs(order) do
                if not stockedReference(state, reference) then complete = false; break end
            end
            if complete then score = 1; break end
        end
    end
    state.reachable[itemId] = score
    return score
end

-- Preference order for a tag's members: a pin that is actually available, then most
-- stocked, then craftable at all, then item ID so the result is reproducible.
local function orderedCandidates(state, tagName)
    local members = state.repo:expand(tagName)
    if #members == 0 then return {} end
    local ranked = {}
    for _, itemId in ipairs(members) do
        ranked[#ranked + 1] = {
            item = itemId,
            available = availableTo(state, itemId),
            reachable = craftableFromStock(state, itemId),
            craftable = state.repo:isCraftable(itemId) and 1 or 0,
        }
    end
    local pinned = state.prefs and state.prefs:tagChoice(tagName)
    table.sort(ranked, function(left, right)
        if pinned and left.available > 0 and right.available > 0 then
            if (left.item == pinned) ~= (right.item == pinned) then
                return left.item == pinned
            end
        end
        if left.available ~= right.available then return left.available > right.available end
        if left.reachable ~= right.reachable then return left.reachable > right.reachable end
        if left.craftable ~= right.craftable then return left.craftable > right.craftable end
        return left.item < right.item
    end)
    local order = {}
    for index, entry in ipairs(ranked) do order[index] = entry.item end
    return order
end

local function copyMap(source)
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    return result
end

-- Ranking alone is not enough to choose a tag member. Every plank type is craftable, so
-- with only oak logs in storage a rank-ordered choice picks acacia_planks and the whole
-- craft fails while oak_planks was reachable the entire time. Ranking cannot see that,
-- because it only knows what is craftable in principle, not what is craftable from the
-- stock actually on hand.
--
-- So try candidates in rank order and keep the first that genuinely resolves, rolling
-- the ledger back between attempts. Rank order still decides ties, so a member that is
-- already in stock is tried first and succeeds immediately -- the search only does real
-- work in the case that was previously broken.
local function snapshot(state)
    return {
        reserved = copyMap(state.reserved), surplus = copyMap(state.surplus),
        withdrawals = copyMap(state.withdrawals), shortfalls = copyMap(state.shortfalls),
        chosen = copyMap(state.chosen), steps = #state.steps,
    }
end

local function restore(state, saved)
    state.reserved, state.surplus = saved.reserved, saved.surplus
    state.withdrawals, state.shortfalls = saved.withdrawals, saved.shortfalls
    state.chosen = saved.chosen
    for index = #state.steps, saved.steps + 1, -1 do state.steps[index] = nil end
end

local function recordShortfall(state, key, amount)
    state.shortfalls[key] = (state.shortfalls[key] or 0) + amount
end

-- Forward declarations: resolve, resolveIngredient and tryRecipe are mutually recursive.
local resolve
local tryRecipe

-- Turn one ingredient reference into a concrete item and resolve it. A plain item index
-- has no choice to make. A tag tries its candidates in rank order and keeps the first
-- that genuinely resolves.
local function resolveIngredient(state, reference, amount, depth)
    if type(reference) == "number" and reference > 0 then
        local itemId = state.repo:itemAt(reference)
        if not itemId then return nil, false end
        return itemId, resolve(state, itemId, amount, depth)
    end
    if type(reference) ~= "string" then return nil, false end

    local candidates = orderedCandidates(state, reference)
    if #candidates == 0 then return nil, false end
    for index, candidate in ipairs(candidates) do
        if index > MAX_TAG_TRIALS or state.budget <= 0 then break end
        state.budget = state.budget - 1
        local saved = snapshot(state)
        state.chosen[reference] = candidate
        if resolve(state, candidate, amount, depth) then return candidate, true end
        restore(state, saved)
    end
    -- Nothing worked. Commit to the top-ranked candidate and resolve it once more, so
    -- the shortfall names a concrete item the operator can go and get.
    local fallback = candidates[1]
    state.chosen[reference] = fallback
    resolve(state, fallback, amount, depth)
    return fallback, false
end

function resolve(state, itemId, needed, depth)
    -- Reuse surplus already produced by an earlier step before touching storage.
    local fromSurplus = math.min(state.surplus[itemId] or 0, needed)
    if fromSurplus > 0 then
        state.surplus[itemId] = state.surplus[itemId] - fromSurplus
        needed = needed - fromSurplus
    end
    if needed <= 0 then return true end

    -- Ingredients come from storage where possible, but the requested item itself does
    -- not: "craft 250 sticks" means make 250, not top the shelf up to 250. Drawing on
    -- existing stock would deliver mostly what was already there and craft a handful.
    -- The Search page's shortfall shortcut is where "get me up to N" lives.
    if depth > 1 then
        -- Reserve against the ledger, not against raw stock. Two branches of one tree
        -- must never both claim the same items.
        local free = (state.available(itemId) or 0) - (state.reserved[itemId] or 0)
        if free < 0 then free = 0 end
        local fromStorage = math.min(free, needed)
        if fromStorage > 0 then
            state.reserved[itemId] = (state.reserved[itemId] or 0) + fromStorage
            state.withdrawals[itemId] = (state.withdrawals[itemId] or 0) + fromStorage
            needed = needed - fromStorage
        end
        if needed <= 0 then return true end
    end

    if depth > state.depthLimit or state.seen[itemId] then
        recordShortfall(state, itemId, needed)
        return false
    end
    local recipes = orderedRecipes(state, itemId)
    if #recipes == 0 then
        recordShortfall(state, itemId, needed)
        return false
    end

    -- Try each recipe and keep the first that genuinely resolves, rolling the ledger back
    -- between attempts. Ranking means a recipe whose ingredients are in stock is tried
    -- first, so the common case still stops immediately.
    for index, candidate in ipairs(recipes) do
        if index > MAX_RECIPE_TRIALS or state.budget <= 0 then break end
        state.budget = state.budget - 1
        local saved = snapshot(state)
        if tryRecipe(state, itemId, needed, depth, candidate) then return true end
        restore(state, saved)
    end
    -- Nothing worked. Resolve the top-ranked recipe once more so the shortfall names
    -- concrete items the operator can go and get, rather than nothing at all.
    tryRecipe(state, itemId, needed, depth, recipes[1])
    return false
end

function tryRecipe(state, itemId, needed, depth, body)
    local perCraft = body.count or 1
    if perCraft < 1 then
        recordShortfall(state, itemId, needed)
        return false
    end
    local order, counts = cellDemand(body)
    if #order == 0 then
        recordShortfall(state, itemId, needed)
        return false
    end

    local crafts = ceilDiv(needed, perCraft)
    state.seen[itemId] = true
    local satisfied, consumes, batch = true, {}, BATCH_CAP
    -- Which concrete item each reference resolved to, so the step can carry the actual
    -- grid placement. The turtle needs cells, and this is the only place that knows how
    -- a tag was resolved.
    local chosenFor = {}
    for _, reference in ipairs(order) do
        local amount = crafts * counts[reference]
        local ingredient, resolved = resolveIngredient(state, reference, amount, depth + 1)
        chosenFor[reference] = ingredient
        if not ingredient then
            -- An unresolvable tag has no concrete item to name, so report the tag.
            recordShortfall(state, tostring(reference), amount)
            satisfied = false
        else
            -- Keep resolving after a failure: the operator needs the whole missing
            -- list at once, not one item per attempt.
            if not resolved then satisfied = false end
            consumes[#consumes + 1] = {item=ingredient, count=amount}
            local limit = state.stackLimit(ingredient) or DEFAULT_STACK_LIMIT
            -- Each cell holds `batch` copies of its item, so the tightest stack limit
            -- across cells caps the whole call.
            if limit < batch then batch = limit end
        end
    end
    state.seen[itemId] = nil
    if not satisfied then return false end

    if batch < 1 then batch = 1 end
    local produced = crafts * perCraft
    state.surplus[itemId] = (state.surplus[itemId] or 0) + (produced - needed)

    -- Resolved grid placement. For a shaped recipe the index is the 3x3 cell, with
    -- false for an empty one; for a shapeless recipe it is just the ingredient order.
    -- turtle.craft() reads turtle slots 1-3, 5-7 and 9-11 as the grid, so carrying
    -- position here means the turtle never has to know a recipe.
    local sourceCells = body.shaped and body.grid or body.ingredients
    local cells = {}
    for index, reference in ipairs(sourceCells or {}) do
        cells[index] = reference ~= 0 and chosenFor[reference] or false
    end

    -- One step per turtle call, rather than one step per output with a call count.
    --
    -- turtle.craft() runs at most `batch` times per call, and every call has to start
    -- from a buffer holding only that call's ingredients: suckDown takes from the
    -- buffer's lowest occupied slot, so anything else in there -- including the previous
    -- call's own output -- gets sucked into the grid instead of the ingredient. Splitting
    -- here means each step gets its own staging, which is what keeps that true.
    local remaining = crafts
    while remaining > 0 do
        local runs = math.min(batch, remaining)
        local perStep = {}
        for index, entry in ipairs(consumes) do
            -- consumes was accumulated over the whole run of crafts, so scale it back
            -- to this call. Integer by construction: it is runs * cells-per-ingredient.
            perStep[index] = {item=entry.item,
                count=math.floor(entry.count / crafts + 0.5) * runs}
        end
        state.steps[#state.steps + 1] = {
            item=itemId, recipe_id=body.id, shaped=body.shaped == true,
            crafts=runs, batch=batch, calls=1,
            produced=runs * perCraft, per_craft=perCraft, consumes=perStep, cells=cells,
        }
        remaining = remaining - runs
    end
    return true
end

local function sortedPairs(map, keyName, valueName)
    local keys = {}
    for key in pairs(map) do keys[#keys + 1] = key end
    table.sort(keys)
    local result = {}
    for _, key in ipairs(keys) do
        if map[key] ~= 0 then
            result[#result + 1] = {[keyName]=key, [valueName]=map[key]}
        end
    end
    return result
end

function CraftPlanner.plan(request, context)
    if type(request) ~= "table" then
        return failure("INVALID_REQUEST", "a craft request is required")
    end
    if type(request.item) ~= "string" or request.item == "" then
        return failure("INVALID_REQUEST", "a craft request needs an item")
    end
    local quantity = request.quantity
    if type(quantity) ~= "number" or quantity < 1 or quantity % 1 ~= 0 then
        return failure("INVALID_REQUEST", "craft quantity must be a positive integer")
    end
    if type(context) ~= "table" or type(context.repo) ~= "table" or
        type(context.available) ~= "function" then
        return failure("INVALID_CONTEXT", "planning needs a recipe repo and a stock lookup")
    end

    local state = {
        repo = context.repo,
        available = context.available,
        stackLimit = context.stack_limit or function() return DEFAULT_STACK_LIMIT end,
        prefs = context.prefs,
        depthLimit = context.depth_limit or DEFAULT_DEPTH_LIMIT,
        budget = context.resolve_budget or RESOLVE_BUDGET,
        tagStocked = {}, reachable = {},
        reserved = {}, surplus = {}, withdrawals = {}, shortfalls = {},
        chosen = {}, steps = {}, seen = {},
    }

    local ok = resolve(state, request.item, quantity, 1)
    local plan = {
        ok = ok,
        item = request.item,
        quantity = quantity,
        steps = state.steps,
        withdrawals = sortedPairs(state.withdrawals, "item", "count"),
        shortfalls = sortedPairs(state.shortfalls, "item", "missing"),
        chosen = sortedPairs(state.chosen, "tag", "item"),
    }
    if not ok then
        plan.reason = {code="INSUFFICIENT_MATERIALS",
            message="Some materials are neither in stock nor craftable"}
    end
    return plan
end

-- How many of an item the current stock supports, counting sub-crafts and what is
-- already on the shelf. Probes by doubling and then bisects, so the cost is logarithmic
-- in the answer rather than linear.
function CraftPlanner.maxCraftable(itemId, context)
    local function feasible(quantity)
        return CraftPlanner.plan({item=itemId, quantity=quantity}, context).ok
    end
    if not feasible(1) then return 0 end
    local low, high = 1, 2
    while high <= MAX_CRAFTABLE_CAP and feasible(high) do
        low, high = high, high * 2
    end
    if high > MAX_CRAFTABLE_CAP then return low end
    while low + 1 < high do
        local middle = math.floor((low + high) / 2)
        if feasible(middle) then low = middle else high = middle end
    end
    return low
end

return CraftPlanner
