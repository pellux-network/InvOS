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
                {id="minecraft:stick", output=3, count=4, shaped=false,
                 ingredients={"minecraft:planks","minecraft:planks"}},
            }},
            [2] = {schema=1, recipes={
                {id="minecraft:chest", output=2, count=1, shaped=true,
                 grid={"minecraft:planks","minecraft:planks","minecraft:planks",
                       "minecraft:planks",0,"minecraft:planks",
                       "minecraft:planks","minecraft:planks","minecraft:planks"}},
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
}
