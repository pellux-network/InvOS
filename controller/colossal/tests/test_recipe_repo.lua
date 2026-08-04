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
    {name="custom recipes take precedence over the generated pack",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack()), custom={
            schema=1, recipes={
                {id="custom:chest", output_item="minecraft:chest", count=2, shaped=false,
                 ingredient_items={"minecraft:oak_planks"}},
            }}})
        local recipes = repo:recipesFor("minecraft:chest")
        T.equal(#recipes, 1, "generated recipe must be replaced, not appended")
        T.equal(recipes[1].id, "custom:chest")
        T.equal(recipes[1].count, 2)
    end},
    {name="a custom recipe is normalised into generated-recipe shape",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack()), custom={
            schema=1, recipes={
                {id="custom:chest", output_item="minecraft:chest", count=2, shaped=false,
                 ingredient_items={"minecraft:oak_planks","#minecraft:planks"}},
            }}})
        local body = repo:recipesFor("minecraft:chest")[1]
        T.equal(body.output_item, nil, "raw hand-written fields must not survive")
        T.equal(body.ingredient_items, nil)
        T.equal(body.output, repo:indexOf("minecraft:chest"))
        T.arrayEqual(repo:resolve(body.ingredients[1]), {"minecraft:oak_planks"})
        T.arrayEqual(repo:resolve(body.ingredients[2]), {"minecraft:oak_planks"})
    end},
    {name="a custom shaped recipe normalises its grid to nine cells",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack()), custom={
            schema=1, recipes={
                {id="custom:torch", output_item="minecraft:torch", count=4, shaped=true,
                 grid_items={"minecraft:stick"}},
            }}})
        local body = repo:recipesFor("minecraft:torch")[1]
        T.equal(#body.grid, 9)
        T.arrayEqual(repo:resolve(body.grid[1]), {"minecraft:stick"})
        T.equal(body.grid[2], 0)
        T.equal(body.grid[9], 0)
    end},
    {name="custom recipes add outputs the generated pack lacks",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack()), custom={
            schema=1, recipes={
                {id="custom:widget", output_item="minecraft:widget", count=1, shaped=false,
                 ingredient_items={"minecraft:stick"}},
            }}})
        T.equal(repo:isCraftable("minecraft:widget"), true)
        T.equal(#repo:recipesFor("minecraft:widget"), 1)
        local found=false
        for _,entry in ipairs(repo:outputs()) do
            if entry.item=="minecraft:widget" then found=true end
        end
        T.equal(found, true, "new output must appear in the search corpus")
    end},
    {name="an output untouched by custom recipes still resolves from its shard",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack()), custom={
            schema=1, recipes={
                {id="custom:widget", output_item="minecraft:widget", count=1, shaped=false,
                 ingredient_items={"minecraft:stick"}},
            }}})
        T.equal(#repo:recipesFor("minecraft:stick"), 1)
        T.equal(repo:recipesFor("minecraft:stick")[1].id, "minecraft:stick")
    end},
    {name="an invalid custom file is ignored rather than fatal",run=function()
        for _, bad in ipairs({{schema=2, recipes={}}, {schema=1}, "nonsense",
            {schema=1, recipes="no"}, {schema=1, recipes={{id="x"}}}}) do
            local repo = RecipeRepo.new({loader=loaderFor(pack()), custom=bad})
            T.equal(repo:isCraftable("minecraft:chest"), true)
            T.equal(repo:recipesFor("minecraft:chest")[1].id, "minecraft:chest")
        end
    end},
    {name="custom recipe validation names the field that is wrong",run=function()
        local ok, reason = RecipeRepo.validateCustom({schema=1, recipes={{id="x"}}})
        T.equal(ok, nil)
        T.contains(reason, "output_item")
        T.equal(RecipeRepo.validateCustom({schema=1, recipes={}}), true)
    end},
}
