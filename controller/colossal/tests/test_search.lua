local Search = require("app.search")
local T = require("tests.mock_cc")

local function index(items)
    return { items=function() return items end }
end

local items = {
    {key="stone",name="minecraft:stone",display_name="Stone",quantity=128,max_count=64,aliases={}},
    {key="cobble",name="minecraft:cobblestone",display_name="Cobblestone",quantity=256,
        max_count=64,aliases={"cobble"}},
    {key="smooth",name="minecraft:smooth_stone",display_name="Smooth Stone",quantity=32,
        max_count=64,aliases={}},
}

return {
    { name = "search ranks exact display then prefix then substring", run = function()
        local results = Search.query(index(items), "stone", {}, 8)
        T.equal(results[1].display_name, "Stone")
        T.equal(results[2].display_name, "Smooth Stone")
        T.equal(results[3].display_name, "Cobblestone")
        T.truthy(results[1].score > results[2].score)
        T.truthy(results[2].score > results[3].score)
    end },
    { name = "search accepts user aliases and registry names", run = function()
        local aliases = { rock="minecraft:stone", pebbles="cobble" }
        T.equal(Search.query(index(items), "rock", aliases, 8)[1].name, "minecraft:stone")
        T.equal(Search.query(index(items), "minecraft:smooth_stone", aliases, 8)[1].name,
            "minecraft:smooth_stone")
        T.equal(Search.query(index(items), "pebbles", aliases, 8)[1].name,
            "minecraft:cobblestone")
    end },
    { name = "search uses conservative one-edit fuzzy matching", run = function()
        local results = Search.query(index(items), "cobblestome", {}, 8)
        T.equal(#results, 1)
        T.equal(results[1].name, "minecraft:cobblestone")
        T.equal(results[1].score, 100)
        T.equal(#Search.query(index(items), "cbblstn", {}, 8), 0)
    end },
    { name = "empty search ranks frequent and recent requests", run = function()
        local recent = {
            {key="a",name="mod:a",display_name="A",quantity=1,request_count=2,last_requested=50},
            {key="b",name="mod:b",display_name="B",quantity=1,request_count=5,last_requested=10},
            {key="c",name="mod:c",display_name="C",quantity=1,request_count=5,last_requested=20},
        }
        local results = Search.query(index(recent), "", {}, 8)
        T.equal(results[1].name, "mod:c")
        T.equal(results[2].name, "mod:b")
        T.equal(results[3].name, "mod:a")
    end },
    { name = "search groups NBT identities and exposes exact variants", run = function()
        local potions = {
            {key="heal",name="minecraft:potion",nbt="healing",display_name="Potion of Healing",quantity=3},
            {key="strong",name="minecraft:potion",nbt="strength",display_name="Potion of Strength",quantity=5},
        }
        local result = Search.query(index(potions), "potion", {}, 8)[1]
        T.equal(result.quantity, 8)
        T.equal(result.identity_key, nil)
        local variants = Search.variants(result)
        T.equal(#variants, 2)
        T.equal(variants[1].identity_key, "heal")
        T.equal(variants[2].identity_key, "strong")
    end },
    { name = "search remains useful before metadata enrichment", run = function()
        local raw = {{key="raw",name="ars_nouveau:source_gem",quantity=12}}
        local result = Search.query(index(raw), "source_gem", {}, 8)[1]
        T.equal(result.name,"ars_nouveau:source_gem")
        T.equal(result.quantity,12)
    end },
}
