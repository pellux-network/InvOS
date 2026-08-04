local CraftPlanner = require("core.craft_planner")
local RecipeRepo = require("core.recipe_repo")
local CraftPrefs = require("core.craft_prefs")
local T = require("tests.mock_cc")

-- A hand-built pack, so the planner is tested against a shape we control rather than
-- the 726-recipe generated one. Item indices are 1-based in declaration order.
local ITEMS = {
    "minecraft:oak_log",      -- 1
    "minecraft:oak_planks",   -- 2
    "minecraft:birch_planks", -- 3
    "minecraft:stick",        -- 4
    "minecraft:chest",        -- 5
    "minecraft:iron_ingot",   -- 6
    "minecraft:iron_block",   -- 7
    "minecraft:bucket",       -- 8
}

local function packFor(recipes, tags)
    local outputs, byShard = {}, {}
    for _, body in ipairs(recipes) do
        outputs[#outputs + 1] = body.output
        byShard[#byShard + 1] = body
    end
    table.sort(outputs)
    return {
        items = {schema=1, ids=ITEMS, names={}},
        index = {schema=1, shard_count=1, outputs=outputs},
        tags  = {schema=1, tags=tags or {}},
        shards = {[1] = {schema=1, recipes=byShard}},
    }
end

local function loaderFor(value)
    return function(name)
        if name == "items" then return value.items end
        if name == "index" then return value.index end
        if name == "tags" then return value.tags end
        local shard = name:match("^pack_(%d+)$")
        if shard then return value.shards[tonumber(shard)] end
        return nil
    end
end

-- planks from a log (shapeless, 1 log -> 4 planks)
-- sticks from planks (shapeless, 2 planks -> 4 sticks)
-- chest from 8 planks in a ring (shaped, tag ingredient)
-- iron_block <-> iron_ingot, deliberately cyclic
local function standardRepo(extra)
    local recipes = {
        {id="r:oak_planks", output=2, count=4, shaped=false, ingredients={1}},
        {id="r:stick", output=4, count=4, shaped=false, ingredients={"t:planks","t:planks"}},
        {id="r:chest", output=5, count=1, shaped=true,
         grid={"t:planks","t:planks","t:planks","t:planks",0,
               "t:planks","t:planks","t:planks","t:planks"}},
        {id="r:iron_block", output=7, count=1, shaped=false,
         ingredients={6,6,6,6,6,6,6,6,6}},
        {id="r:iron_ingot", output=6, count=9, shaped=false, ingredients={7}},
    }
    for _, body in ipairs(extra or {}) do recipes[#recipes + 1] = body end
    return RecipeRepo.new({loader=loaderFor(packFor(recipes, {["t:planks"]={2,3}}))})
end

local function context(stock, overrides)
    local ctx = {
        repo = standardRepo(),
        available = function(itemId) return (stock or {})[itemId] or 0 end,
        stack_limit = function(itemId)
            if itemId == "minecraft:bucket" then return 16 end
            return 64
        end,
    }
    for key, value in pairs(overrides or {}) do ctx[key] = value end
    return ctx
end

-- The real generated pack, loaded once. Deliberately not the fixture: a test double
-- that is more permissive than the real artifact hides exactly this module's bugs.
local realRepo = RecipeRepo.new({})

local function realContext(stock)
    return {
        repo = realRepo,
        available = function(itemId) return (stock or {})[itemId] or 0 end,
        stack_limit = function() return 64 end,
    }
end

local function withdrawalOf(plan, itemId)
    for _, entry in ipairs(plan.withdrawals) do
        if entry.item == itemId then return entry.count end
    end
    return 0
end

local function stepFor(plan, itemId)
    for _, step in ipairs(plan.steps) do
        if step.item == itemId then return step end
    end
end

local function consumedBy(step, itemId)
    for _, entry in ipairs(step.consumes) do
        if entry.item == itemId then return entry.count end
    end
    return 0
end

return {
    {name="existing stock of the requested item is not counted toward it",run=function()
        -- "craft 2 chests" means make 2, even with 5 already on the shelf. Topping up to
        -- a total lives on the Search page's shortfall shortcut instead.
        local plan = CraftPlanner.plan({item="minecraft:chest", quantity=2},
            context({["minecraft:chest"]=5, ["minecraft:oak_planks"]=64}))
        T.equal(plan.ok, true)
        T.equal(#plan.steps, 1, "it crafts rather than drawing on the five already held")
        T.equal(stepFor(plan, "minecraft:chest").produced, 2)
        T.equal(withdrawalOf(plan, "minecraft:chest"), 0, "the existing chests are untouched")
        T.equal(withdrawalOf(plan, "minecraft:oak_planks"), 16)
    end},
    {name="a single craft withdraws its ingredients and records one step",run=function()
        local plan = CraftPlanner.plan({item="minecraft:chest", quantity=1},
            context({["minecraft:oak_planks"]=64}))
        T.equal(plan.ok, true)
        T.equal(#plan.steps, 1)
        local step = plan.steps[1]
        T.equal(step.item, "minecraft:chest")
        T.equal(step.recipe_id, "r:chest")
        T.equal(step.crafts, 1)
        T.equal(step.produced, 1)
        T.equal(consumedBy(step, "minecraft:oak_planks"), 8)
        T.equal(withdrawalOf(plan, "minecraft:oak_planks"), 8)
    end},
    {name="ingredient stock is still used before crafting more of it",run=function()
        -- The rule covers the requested item only. Ingredients behave as before.
        local plan = CraftPlanner.plan({item="minecraft:chest", quantity=1},
            context({["minecraft:oak_planks"]=8, ["minecraft:oak_log"]=64}))
        T.equal(plan.ok, true)
        T.equal(withdrawalOf(plan, "minecraft:oak_planks"), 8, "planks on hand are used")
        T.equal(withdrawalOf(plan, "minecraft:oak_log"), 0, "so no logs are needed")
        T.equal(#plan.steps, 1, "only the chest is crafted")
    end},
    {name="a multistep tree resolves leaf-first",run=function()
        -- no planks, only logs: chest needs planks, planks need logs
        local plan = CraftPlanner.plan({item="minecraft:chest", quantity=1},
            context({["minecraft:oak_log"]=64}))
        T.equal(plan.ok, true)
        T.equal(#plan.steps, 2)
        T.equal(plan.steps[1].item, "minecraft:oak_planks", "leaf craft comes first")
        T.equal(plan.steps[2].item, "minecraft:chest")
        T.equal(withdrawalOf(plan, "minecraft:oak_log"), 2, "8 planks needs 2 logs")
    end},
    {name="surplus from a craft is reused instead of crafting twice",run=function()
        -- 2 logs make 8 planks; a chest needs 8, sticks need 2 more
        local plan = CraftPlanner.plan({item="minecraft:stick", quantity=4},
            context({["minecraft:oak_log"]=64}))
        local planks = stepFor(plan, "minecraft:oak_planks")
        T.equal(planks.produced, 4, "one log's worth covers 2 planks with surplus")
        T.equal(withdrawalOf(plan, "minecraft:oak_log"), 1)
    end},
    {name="a tag ingredient resolves to the most-stocked member",run=function()
        local plan = CraftPlanner.plan({item="minecraft:chest", quantity=1},
            context({["minecraft:oak_planks"]=8, ["minecraft:birch_planks"]=64}))
        T.equal(withdrawalOf(plan, "minecraft:birch_planks"), 8)
        T.equal(withdrawalOf(plan, "minecraft:oak_planks"), 0)
        T.equal(plan.chosen[1].tag, "t:planks")
        T.equal(plan.chosen[1].item, "minecraft:birch_planks")
    end},
    {name="a pinned tag preference wins over the most-stocked member",run=function()
        local prefs = CraftPrefs.new(CraftPrefs.default())
        prefs:pinTag("t:planks", "minecraft:oak_planks")
        local plan = CraftPlanner.plan({item="minecraft:chest", quantity=1},
            context({["minecraft:oak_planks"]=8, ["minecraft:birch_planks"]=64}, {prefs=prefs}))
        T.equal(withdrawalOf(plan, "minecraft:oak_planks"), 8)
        T.equal(withdrawalOf(plan, "minecraft:birch_planks"), 0)
    end},
    {name="a pinned tag preference is ignored when that item is out of stock",run=function()
        local prefs = CraftPrefs.new(CraftPrefs.default())
        prefs:pinTag("t:planks", "minecraft:oak_planks")
        local plan = CraftPlanner.plan({item="minecraft:chest", quantity=1},
            context({["minecraft:birch_planks"]=64}, {prefs=prefs}))
        T.equal(withdrawalOf(plan, "minecraft:birch_planks"), 8)
    end},
    {name="the reservation ledger stops two branches claiming the same stock",run=function()
        -- 8 planks in stock; a chest needs all 8 and sticks need 2 more.
        -- Without a ledger both branches would see 8 available.
        local plan = CraftPlanner.plan({item="minecraft:chest", quantity=1},
            context({["minecraft:oak_planks"]=8, ["minecraft:oak_log"]=64}))
        T.equal(withdrawalOf(plan, "minecraft:oak_planks"), 8)
        T.equal(#plan.steps, 1, "planks were sufficient, nothing else to craft")

        -- now demand more chests than the planks cover, so the rest must be crafted
        local bigger = CraftPlanner.plan({item="minecraft:chest", quantity=2},
            context({["minecraft:oak_planks"]=8, ["minecraft:oak_log"]=64}))
        T.equal(withdrawalOf(bigger, "minecraft:oak_planks"), 8, "existing planks used once")
        T.equal(withdrawalOf(bigger, "minecraft:oak_log"), 2, "remaining 8 planks from logs")
    end},
    {name="batch size is bounded by the tightest ingredient stack limit",run=function()
        local repo = standardRepo({
            {id="r:bucketed", output=1, count=1, shaped=false, ingredients={8}},
        })
        local plan = CraftPlanner.plan({item="minecraft:oak_log", quantity=64},
            context({["minecraft:bucket"]=64}, {repo=repo}))
        -- Steps are one turtle call each, so 64 crafts at batch 16 is four steps.
        local steps, total = {}, 0
        for _, entry in ipairs(plan.steps) do
            if entry.item == "minecraft:oak_log" then
                steps[#steps + 1] = entry
                total = total + entry.crafts
                T.equal(entry.batch, 16, "bucket stacks to 16, so a call can batch 16")
                T.equal(entry.calls, 1, "every step is exactly one turtle call")
                T.truthy(entry.crafts <= 16, "a step never asks for more than one call")
            end
        end
        T.equal(#steps, 4, "64 crafts at 16 per call is four steps")
        T.equal(total, 64)
    end},
    {name="batch size is capped at 64 even for large stacks",run=function()
        local plan = CraftPlanner.plan({item="minecraft:chest", quantity=200},
            context({["minecraft:oak_planks"]=99999}))
        local steps, total, produced = {}, 0, 0
        for _, entry in ipairs(plan.steps) do
            if entry.item == "minecraft:chest" then
                steps[#steps + 1] = entry
                total = total + entry.crafts
                produced = produced + entry.produced
                T.equal(entry.batch, 64)
                T.truthy(entry.crafts <= 64, "a step never exceeds one call")
            end
        end
        T.equal(#steps, 4, "200 crafts at 64 per call is four steps")
        T.equal(total, 200, "the split preserves the total craft count")
        T.equal(produced, 200, "and the total produced")
    end},
    {name="a cyclic recipe pair terminates instead of recursing forever",run=function()
        local plan = CraftPlanner.plan({item="minecraft:iron_block", quantity=1},
            context({}))
        T.equal(plan.ok, false)
        T.truthy(#plan.shortfalls > 0, "a cycle must surface as a shortfall")
    end},
    {name="depth is bounded",run=function()
        local plan = CraftPlanner.plan({item="minecraft:chest", quantity=1},
            context({["minecraft:oak_log"]=64}, {depth_limit=1}))
        T.equal(plan.ok, false, "chest needs planks needs logs, deeper than the limit")
    end},
    {name="every missing material is reported, not just the first",run=function()
        local repo = standardRepo({
            {id="r:combo", output=8, count=1, shaped=false, ingredients={6, 1}},
        })
        local plan = CraftPlanner.plan({item="minecraft:bucket", quantity=1},
            context({}, {repo=repo}))
        T.equal(plan.ok, false)
        T.equal(#plan.shortfalls, 2, "both missing ingredients are listed")
    end},
    {name="an item with no recipe and no stock is a clean shortfall",run=function()
        local plan = CraftPlanner.plan({item="minecraft:oak_log", quantity=5}, context({}))
        T.equal(plan.ok, false)
        T.equal(plan.shortfalls[1].item, "minecraft:oak_log")
        T.equal(plan.shortfalls[1].missing, 5)
        T.equal(#plan.steps, 0)
    end},
    {name="a shortfall deep in the tree fails the whole plan",run=function()
        local plan = CraftPlanner.plan({item="minecraft:chest", quantity=1}, context({}))
        T.equal(plan.ok, false)
        T.truthy(#plan.shortfalls > 0)
    end},
    {name="invalid requests are rejected rather than planned",run=function()
        for _, bad in ipairs({
            {item="minecraft:chest", quantity=0},
            {item="minecraft:chest", quantity=-1},
            {item="minecraft:chest", quantity=1.5},
            {item="", quantity=1},
        }) do
            local plan = CraftPlanner.plan(bad, context({}))
            T.equal(plan.ok, false, "must refuse")
            T.truthy(plan.reason ~= nil, "must say why")
        end
    end},
    {name="planning is pure: the same inputs give the same plan twice",run=function()
        local stock = {["minecraft:oak_log"]=64, ["minecraft:birch_planks"]=3}
        local first = CraftPlanner.plan({item="minecraft:chest", quantity=2}, context(stock))
        local second = CraftPlanner.plan({item="minecraft:chest", quantity=2}, context(stock))
        T.equal(#first.steps, #second.steps)
        for index, step in ipairs(first.steps) do
            T.equal(step.item, second.steps[index].item)
            T.equal(step.crafts, second.steps[index].crafts)
        end
        T.equal(withdrawalOf(first, "minecraft:oak_log"),
                withdrawalOf(second, "minecraft:oak_log"))
    end},
    {name="withdrawals, shortfalls and choices are sorted for a stable display",run=function()
        local plan = CraftPlanner.plan({item="minecraft:chest", quantity=1},
            context({["minecraft:oak_planks"]=8}))
        local previous
        for _, entry in ipairs(plan.withdrawals) do
            if previous then T.truthy(previous < entry.item, "withdrawals must be sorted") end
            previous = entry.item
        end
    end},
    {name="maxCraftable reports how many the current stock supports",run=function()
        local howMany = CraftPlanner.maxCraftable("minecraft:chest",
            context({["minecraft:oak_planks"]=24}))
        T.equal(howMany, 3, "24 planks makes 3 chests")
    end},
    {name="maxCraftable counts sub-crafts but not stock of the item itself",run=function()
        local howMany = CraftPlanner.maxCraftable("minecraft:chest",
            context({["minecraft:chest"]=2, ["minecraft:oak_log"]=4}))
        T.equal(howMany, 2, "4 logs makes 16 planks, which makes 2 chests")
    end},
    {name="maxCraftable is zero when nothing can be made",run=function()
        T.equal(CraftPlanner.maxCraftable("minecraft:chest", context({})), 0)
    end},

    -- Integration against the real generated pack. The hand-built fixture above cannot
    -- catch tag-choice bugs, because it has two plank types and only one is craftable.
    -- The real pack has eight, all craftable, so a rank-only choice picks acacia_planks
    -- and fails with oak logs on the shelf. Every one of these passed against the mock
    -- while the real pack was broken.
    {name="real pack: a chest resolves from logs through planks",run=function()
        local plan = CraftPlanner.plan({item="minecraft:chest", quantity=1},
            realContext({["minecraft:oak_log"]=64}))
        T.equal(plan.ok, true, "oak logs must be enough to reach a chest")
        T.equal(#plan.steps, 2)
        T.equal(plan.steps[1].item, "minecraft:oak_planks")
        T.equal(plan.steps[2].item, "minecraft:chest")
        T.equal(withdrawalOf(plan, "minecraft:oak_log"), 2)
    end},
    {name="real pack: a tag picks the wood type actually in stock",run=function()
        local plan = CraftPlanner.plan({item="minecraft:stick", quantity=8},
            realContext({["minecraft:spruce_log"]=2}))
        T.equal(plan.ok, true)
        T.equal(plan.steps[1].item, "minecraft:spruce_planks",
            "must not pick an alphabetically earlier wood it has none of")
        T.equal(withdrawalOf(plan, "minecraft:spruce_log"), 1)
    end},
    {name="real pack: a multi-ingredient recipe resolves every branch",run=function()
        local plan = CraftPlanner.plan({item="minecraft:piston", quantity=1},
            realContext({["minecraft:oak_log"]=64, ["minecraft:cobblestone"]=64,
                         ["minecraft:iron_ingot"]=64, ["minecraft:redstone"]=64}))
        T.equal(plan.ok, true)
        T.equal(withdrawalOf(plan, "minecraft:cobblestone"), 4)
        T.equal(withdrawalOf(plan, "minecraft:iron_ingot"), 1)
        T.equal(withdrawalOf(plan, "minecraft:redstone"), 1)
        T.equal(withdrawalOf(plan, "minecraft:oak_log"), 1)
    end},
    {name="real pack: an empty inventory crafts nothing and says what is missing",run=function()
        local plan = CraftPlanner.plan({item="minecraft:chest", quantity=1}, realContext({}))
        T.equal(plan.ok, false)
        T.equal(#plan.steps, 0)
        T.truthy(#plan.shortfalls > 0, "must name what is missing")
    end},
}
