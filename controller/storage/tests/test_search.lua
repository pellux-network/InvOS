local Identity = require("core.identity")
local Index = require("core.index")
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
    { name = "search matches multi-word abbreviations in order", run = function()
        local mushrooms = {
            {key="red",name="minecraft:red_mushroom",display_name="Red Mushroom",quantity=4},
            {key="brown",name="minecraft:brown_mushroom",display_name="Brown Mushroom",quantity=2},
        }
        local results = Search.query(index(mushrooms), "re mush", {}, 8)
        T.equal(#results, 1)
        T.equal(results[1].display_name, "Red Mushroom")
        T.equal(results[1].score, 400)
    end },
    { name = "search abbreviations require query word order", run = function()
        local mushrooms = {
            {key="red",name="minecraft:red_mushroom",display_name="Red Mushroom",quantity=4},
        }
        T.equal(#Search.query(index(mushrooms), "mush re", {}, 8), 0)
    end },
    { name = "search abbreviations tolerate a typo in either word", run = function()
        -- Each word carries its own typo ("goldn"/"golden", "aople"/"apple"), so the
        -- combined query differs from the display name by two edits overall -- only a
        -- per-token fuzzy check, not a whole-string one, can still find this.
        local fruit = {
            {key="apple",name="minecraft:golden_apple",display_name="Golden Apple",quantity=1},
        }
        local results = Search.query(index(fruit), "goldn aople", {}, 8)
        T.equal(#results, 1)
        T.equal(results[1].display_name, "Golden Apple")
        T.equal(results[1].score, 100)
    end },
    { name = "empty search with sort mode requests ranks most-requested first, ties by name",
        run = function()
        local recent = {
            {key="a",name="mod:a",display_name="A",quantity=1,request_count=2,last_requested=50},
            {key="b",name="mod:b",display_name="B",quantity=1,request_count=5,last_requested=10},
            {key="c",name="mod:c",display_name="C",quantity=1,request_count=5,last_requested=20},
        }
        local results = Search.query(index(recent), "", {}, 8, {sort_mode="requests"})
        T.equal(results[1].name, "mod:b", "tied request_count falls through to name, not " ..
            "last_requested")
        T.equal(results[2].name, "mod:c")
        T.equal(results[3].name, "mod:a")
    end },
    { name = "empty search falls back to alphabetical order after usage stats, not quantity", run = function()
        local items = {
            {key="z",name="mod:zebra",display_name="Zebra",quantity=999},
            {key="a",name="mod:apple",display_name="Apple",quantity=1},
            {key="m",name="mod:mango",display_name="Mango",quantity=50},
        }
        local results = Search.query(index(items), "", {}, 8)
        T.equal(results[1].name, "mod:apple")
        T.equal(results[2].name, "mod:mango")
        T.equal(results[3].name, "mod:zebra")
    end },
    { name = "an unset limit returns every match, past the old fixed cap, still correctly ordered",
        run = function()
        -- The Search page used to hand M.query a limit of max(50, height*4), around 96 rows
        -- on a 24-row terminal. The list is bounded only by the number of distinct stocked
        -- item groups -- hundreds, not thousands -- so the UI path now passes no limit at
        -- all and must get every match back, in the same order it would have used to
        -- truncate.
        local many = {}
        for index = 1, 150 do
            local id = string.format("%03d", index)
            many[index] = {key="i" .. id, name="mod:item" .. id,
                display_name="Item " .. id, quantity=1}
        end
        local results = Search.query(index(many), "", {})
        T.equal(#results, 150,
            "every stocked group must be reachable, not just the old ~96-row cap")
        T.equal(results[1].name, "mod:item001")
        T.equal(results[150].name, "mod:item150")
    end },
    { name = "a limit is still honored when a caller passes one explicitly", run = function()
        local many = {}
        for index = 1, 20 do
            many[index] = {key="i" .. index, name="mod:item" .. index,
                display_name="Item " .. index, quantity=1}
        end
        T.equal(#Search.query(index(many), "", {}, 5), 5,
            "an explicit limit must still truncate, for any caller that wants a page")
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
    -- Task: list sorting. The four Search sort modes, each isolated from the others by
    -- giving every item the same request_count/last_requested (0/0, always tied) so only the
    -- chosen mode's own key can be moving the order.
    { name = "sort mode name orders alphabetically by display name", run = function()
        local results = Search.query(index(items), "", {}, nil, {sort_mode="name"})
        T.equal(results[1].display_name, "Cobblestone")
        T.equal(results[2].display_name, "Smooth Stone")
        T.equal(results[3].display_name, "Stone")
    end },
    { name = "sort mode quantity orders most stock first", run = function()
        local results = Search.query(index(items), "", {}, nil, {sort_mode="quantity"})
        T.equal(results[1].display_name, "Cobblestone") -- 256
        T.equal(results[2].display_name, "Stone")        -- 128
        T.equal(results[3].display_name, "Smooth Stone")  -- 32
    end },
    { name = "sort mode recent orders by last_requested, most recent first", run = function()
        local recent = {
            {key="a", name="mod:a", display_name="A", quantity=1, last_requested=10},
            {key="b", name="mod:b", display_name="B", quantity=1, last_requested=30},
            {key="c", name="mod:c", display_name="C", quantity=1, last_requested=20},
        }
        local results = Search.query(index(recent), "", {}, nil, {sort_mode="recent"})
        T.equal(results[1].name, "mod:b")
        T.equal(results[2].name, "mod:c")
        T.equal(results[3].name, "mod:a")
    end },
    { name = "sort mode requests orders by request_count, most requested first", run = function()
        local requested = {
            {key="a", name="mod:a", display_name="A", quantity=1, request_count=1},
            {key="b", name="mod:b", display_name="B", quantity=1, request_count=9},
            {key="c", name="mod:c", display_name="C", quantity=1, request_count=4},
        }
        local results = Search.query(index(requested), "", {}, nil, {sort_mode="requests"})
        T.equal(results[1].name, "mod:b")
        T.equal(results[2].name, "mod:c")
        T.equal(results[3].name, "mod:a")
    end },
    { name = "sort modes apply to a non-empty query too, once match score ties", run = function()
        -- Score is still the outer key ahead of sort_mode. These two both match "stone" as a
        -- plain mid-string substring (the same 200-point tier: neither is an exact/prefix/
        -- abbreviation match), so their scores tie and the chosen sort mode is what breaks it.
        local tied = {
            {key="a", name="mod:a_stone_item", display_name="Very Stone Item", quantity=1},
            {key="b", name="mod:b_stone_item", display_name="Another Stone Item", quantity=1},
        }
        local first = Search.query(index(tied), "stone", {}, nil, {sort_mode="name"})
        T.equal(first[1].score, first[2].score, "the fixture must tie on score for this test to prove anything")
        T.equal(first[1].display_name, "Another Stone Item")
        T.equal(first[2].display_name, "Very Stone Item")
    end },
    -- There used to be a frequency_priority layer that ranked every sort mode by request
    -- history first and its own key only as a tiebreak, so "name" (or any other mode) didn't
    -- actually sort by its own key except among equally-requested items. That layer is gone: a
    -- non-"requests" mode must ignore request history entirely, even when it would have
    -- reordered the result.
    { name = "sort mode name ignores request history entirely", run = function()
        local ranked = {
            {key="a", name="mod:a", display_name="Aaa", quantity=1, request_count=5},
            {key="b", name="mod:b", display_name="Zzz", quantity=1, request_count=0},
        }
        local results = Search.query(index(ranked), "", {}, nil, {sort_mode="name"})
        T.equal(results[1].display_name, "Aaa",
            "name must sort alphabetically even though Zzz has been requested more")
    end },
    { name = "sort mode quantity ignores request history entirely", run = function()
        local ranked = {
            {key="a", name="mod:a", display_name="A", quantity=1, request_count=5},
            {key="b", name="mod:b", display_name="B", quantity=9, request_count=0},
        }
        local results = Search.query(index(ranked), "", {}, nil, {sort_mode="quantity"})
        T.equal(results[1].display_name, "B",
            "quantity must sort by stock even though A has been requested more")
    end },
    { name = "omitting options behaves exactly as the pre-sort-modes default", run = function()
        -- Locks in that sort_mode defaults to "name" (a no-op past score), matching every
        -- pre-existing caller above that never passes a 5th argument at all.
        local results = Search.query(index(items), "stone", {}, 8)
        T.equal(results[1].display_name, "Stone")
        T.equal(results[2].display_name, "Smooth Stone")
        T.equal(results[3].display_name, "Cobblestone")
    end },
    { name = "search reuses the index's precomputed groups instead of regrouping per query", run = function()
        local built = Index.build({
            { node_id="a", peripheral_name="inventory_a", epoch=1, health="READY", priority=1, slots={
                [1] = {name="minecraft:stone", nbt=nil, count=64, identity_key=Identity.key("minecraft:stone", nil)},
                [2] = {name="minecraft:dirt", nbt=nil, count=32, identity_key=Identity.key("minecraft:dirt", nil)},
            } },
        }, {})
        local calls = 0
        local original = built.items
        built.items = function(...) calls = calls + 1; return original(...) end
        Search.query(built, "stone", {}, 8)
        Search.query(built, "sto", {}, 8)
        Search.query(built, "", {}, 8)
        T.equal(calls, 0, "search must not rebuild groups from items() when a cache is available")
    end },
}
