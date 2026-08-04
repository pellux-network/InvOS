local RecipeRepo = require("core.recipe_repo")
local T = require("tests.mock_cc")

local function pack()
    return {
        items = {schema=1, ids={"minecraft:oak_planks","minecraft:chest","minecraft:stick"},
            names={"Oak Planks","Chest","Stick"}},
        index = {schema=1, pack="test", shard_count=2, outputs={2,3}},
        tags  = {schema=1, tags={["minecraft:planks"]={1}}},
        shards = {
            [1] = {schema=1, recipes={
                {id="minecraft:chest", output=2, count=1, shaped=true,
                 grid={"minecraft:planks","minecraft:planks","minecraft:planks",
                       "minecraft:planks",0,"minecraft:planks",
                       "minecraft:planks","minecraft:planks","minecraft:planks"}},
            }},
            [2] = {schema=1, recipes={
                {id="minecraft:stick", output=3, count=4, shaped=false,
                 ingredients={"minecraft:planks","minecraft:planks"}},
            }},
        },
    }
end

local function loaderFor(value, counter)
    return function(name)
        if counter then counter[name] = (counter[name] or 0) + 1 end
        if name == "items" then return value.items end
        if name == "index" then return value.index end
        if name == "tags" then return value.tags end
        local shard = name:match("^pack_(%d+)$")
        if shard then return value.shards[tonumber(shard)] end
        return nil
    end
end

return {
    {name="repo lists every craftable output with its display name",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack())})
        local outputs = repo:outputs()
        T.equal(#outputs, 2)
        T.equal(outputs[1].item, "minecraft:chest")
        T.equal(outputs[1].display_name, "Chest")
        T.equal(outputs[2].item, "minecraft:stick")
    end},
    {name="repo reports whether an item is craftable",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack())})
        T.equal(repo:isCraftable("minecraft:chest"), true)
        T.equal(repo:isCraftable("minecraft:oak_planks"), false)
        T.equal(repo:isCraftable("minecraft:nonexistent"), false)
    end},
    {name="repo resolves an item id to its display name",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack())})
        T.equal(repo:displayName("minecraft:oak_planks"), "Oak Planks")
        T.equal(repo:displayName("minecraft:unknown"), "minecraft:unknown")
    end},
    {name="repo boots with an empty pack rather than failing",run=function()
        local repo = RecipeRepo.new({loader=function() return nil end})
        T.arrayEqual(repo:outputs(), {})
        T.equal(repo:isCraftable("minecraft:chest"), false)
    end},
    {name="repo returns recipe bodies for an output",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack())})
        local recipes = repo:recipesFor("minecraft:chest")
        T.equal(#recipes, 1)
        T.equal(recipes[1].id, "minecraft:chest")
        T.equal(recipes[1].shaped, true)
        T.equal(recipes[1].count, 1)
        T.equal(#recipes[1].grid, 9)
    end},
    {name="repo loads only the shard an output maps to, and caches it",run=function()
        local counter = {}
        local repo = RecipeRepo.new({loader=loaderFor(pack(), counter)})
        repo:recipesFor("minecraft:chest")
        repo:recipesFor("minecraft:chest")
        -- Names are asserted zero-padded on purpose. tools/recipe_pack.py emits
        -- pack_01.lua, so an unpadded request resolves to nothing, _shard degrades
        -- to an empty shard, and every output silently looks uncraftable in
        -- production while these tests still pass.
        T.equal(counter["pack_01"], 1, "shard should load once")
        T.equal(counter["pack_02"], nil, "unrelated shard must not load")
    end},
    {name="repo expands a tag reference to concrete item ids",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack())})
        T.arrayEqual(repo:expand("minecraft:planks"), {"minecraft:oak_planks"})
        T.arrayEqual(repo:expand("minecraft:missing"), {})
    end},
    {name="repo resolves an ingredient reference of either form",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack())})
        T.arrayEqual(repo:resolve("minecraft:planks"), {"minecraft:oak_planks"})
        T.arrayEqual(repo:resolve(2), {"minecraft:chest"})
        T.arrayEqual(repo:resolve(0), {})
    end},
    {name="repo returns nothing for an unknown output",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack())})
        T.arrayEqual(repo:recipesFor("minecraft:nonexistent"), {})
    end},
    {name="repo survives a shard that fails to load",run=function()
        local value = pack()
        value.shards[1] = nil
        local repo = RecipeRepo.new({loader=loaderFor(value)})
        T.arrayEqual(repo:recipesFor("minecraft:chest"), {})
    end},
}
