-- Task: list sorting, F3-cycled and session-only per page. Search's own sort-mode/
-- frequency_priority behavior lives in tests/test_search.lua; F3's keymap suppression lives in
-- tests/test_keymap.lua (and its footer/help registry coverage in tests/test_help.lua). This
-- module covers the rest: the UI reducer's CYCLE_SORT case (cycling, wrapping, per-page
-- independence, selection reset, session-only lifetime), the sort indicator actually
-- rendering, and the coordinator wiring that makes a sort change re-rank and re-window --
-- including Crafting's name sort staying stock-lookup free on a large synthetic catalogue,
-- exactly like tests/test_craft_window.lua already proves for plain windowing.
keys = keys or {}
for name, code in pairs({f3=61, up=200, down=208, one=2, six=7}) do
    if keys[name] == nil then keys[name] = code end
end

local Coordinator = require("app.coordinator")
local UI = require("app.ui")
local T = require("tests.mock_cc")

local function result(key, name, quantity)
    return {identity_key=key, name="minecraft:" .. name:lower(), display_name=name,
        quantity=quantity, max_count=64,
        variants={{identity_key=key, display_name=name, quantity=quantity, max_count=64}}}
end

return {
    -- --- UI reducer: cycling, wrapping, independence, selection reset ---------------------

    {name="CYCLE_SORT cycles through every Search mode and wraps back to the first",
     run=function()
        local ui = UI.new(T.recordingSurface(51, 19))
        local state = UI.initialState()
        T.equal(state.sort_mode, "name", "Search must start on Name A-Z")
        local seen = {state.sort_mode}
        for _ = 1, #UI.SEARCH_SORT_MODES do
            state = ui:reduce(state, {type="CYCLE_SORT"})
            seen[#seen + 1] = state.sort_mode
        end
        T.equal(#seen, #UI.SEARCH_SORT_MODES + 1)
        T.equal(seen[#seen], "name", "cycling all the way around must land back on the start")
        -- No mode repeats before the wrap.
        local unique = {}
        for index = 1, #UI.SEARCH_SORT_MODES do unique[seen[index]] = true end
        local count = 0
        for _ in pairs(unique) do count = count + 1 end
        T.equal(count, #UI.SEARCH_SORT_MODES, "every mode must appear exactly once before wrapping")
    end},

    {name="CYCLE_SORT cycles through every Crafting mode and wraps", run=function()
        local ui = UI.new(T.recordingSurface(51, 19))
        local state = UI.initialState()
        state.page, state.mode = "crafting", "craft_search"
        T.equal(state.craft_sort_mode, "default")
        state = ui:reduce(state, {type="CYCLE_SORT"})
        T.equal(state.craft_sort_mode, "name")
        state = ui:reduce(state, {type="CYCLE_SORT"})
        T.equal(state.craft_sort_mode, "default", "Crafting's two modes must wrap after both")
    end},

    {name="Crafting never offers a third mode: only default and name", run=function()
        T.equal(#UI.CRAFT_SORT_MODES, 2)
        local hasQuantity = false
        for _, mode in ipairs(UI.CRAFT_SORT_MODES) do
            if mode == "quantity" or mode == "recent" or mode == "requests" then
                hasQuantity = true
            end
        end
        T.equal(hasQuantity, false,
            "Crafting has no usage stats and must never offer a usage-based sort")
    end},

    {name="Search and Crafting sort modes cycle independently of each other", run=function()
        local ui = UI.new(T.recordingSurface(51, 19))
        local state = UI.initialState()
        state = ui:reduce(state, {type="CYCLE_SORT"}) -- search: name -> quantity
        T.equal(state.sort_mode, "quantity")
        T.equal(state.craft_sort_mode, "default", "cycling Search must not touch Crafting")
        state.page, state.mode = "crafting", "craft_search"
        state = ui:reduce(state, {type="CYCLE_SORT"}) -- crafting: default -> name
        T.equal(state.craft_sort_mode, "name")
        T.equal(state.sort_mode, "quantity", "cycling Crafting must not touch Search's own mode")
    end},

    {name="CYCLE_SORT does nothing outside the two list-viewing modes", run=function()
        local ui = UI.new(T.recordingSurface(51, 19))
        for _, mode in ipairs({"quantity", "variant", "craft_quantity", "craft_plan",
            "craft_jobs", "page"}) do
            local state = UI.initialState()
            state.mode = mode
            local before = {sort_mode=state.sort_mode, craft_sort_mode=state.craft_sort_mode}
            local after = ui:reduce(state, {type="CYCLE_SORT"})
            T.equal(after.sort_mode, before.sort_mode, "sort_mode changed in mode=" .. mode)
            T.equal(after.craft_sort_mode, before.craft_sort_mode,
                "craft_sort_mode changed in mode=" .. mode)
        end
    end},

    {name="a sort change resets the selection to 1", run=function()
        local ui = UI.new(T.recordingSurface(51, 19))
        local state = UI.initialState()
        state.results = {result("a","A",1), result("b","B",2), result("c","C",3)}
        state.result_count, state.selection, state.scroll = 3, 3, 2
        state = ui:reduce(state, {type="CYCLE_SORT"})
        T.equal(state.selection, 1,
            "a re-sort can move the old selection anywhere, so it must not stay pointed at " ..
            "an unrelated row")
        T.equal(state.scroll, 1)

        local craftState = UI.initialState()
        craftState.page, craftState.mode = "crafting", "craft_search"
        craftState.craft_selection, craftState.craft_scroll = 40, 12
        craftState = ui:reduce(craftState, {type="CYCLE_SORT"})
        T.equal(craftState.craft_selection, 1)
        T.equal(craftState.craft_scroll, 1)
    end},

    {name="sort mode survives a page switch but resets to default on a fresh session",
     run=function()
        local ui = UI.new(T.recordingSurface(51, 19))
        local state = UI.initialState()
        state = ui:reduce(state, {type="CYCLE_SORT"}) -- name -> quantity
        T.equal(state.sort_mode, "quantity")
        state = ui:reduce(state, {type="OPEN_PAGE", page="storage"})
        state = ui:reduce(state, {type="OPEN_PAGE", page="search"})
        T.equal(state.sort_mode, "quantity",
            "switching pages and back must not reset an already-chosen sort mode")
        -- Session-only: nothing persists it, so a fresh boot (a fresh UI.initialState()) is
        -- always back at the default -- the only place either field is ever assigned besides
        -- CYCLE_SORT itself.
        T.equal(UI.initialState().sort_mode, "name")
        T.equal(UI.initialState().craft_sort_mode, "default")
    end},

    -- --- Rendering: the indicator actually shows up, and degrades rather than overlapping --

    {name="the sort indicator names the current Search mode in the list band", run=function()
        local screen = UI.new(T.recordingSurface(51, 19))
        local state = UI.initialState()
        state.results, state.result_count, state.query = {result("a","Apple",1)}, 1, "a"
        state = screen:reduce(state, {type="CYCLE_SORT"}) -- name -> quantity
        screen:render(state, {lifecycle="READY", search_results=state.results})
        T.contains(screen.surface.allText(), "SORT")
        T.contains(screen.surface.allText(), "Stock")
        T.equal(screen.surface.writesOutsideBounds(), 0)
    end},

    {name="the sort indicator names the current Crafting mode in the list band", run=function()
        local screen = UI.new(T.recordingSurface(51, 19))
        local state = UI.initialState()
        state.page, state.mode = "crafting", "craft_search"
        state.craft_results = {{item="minecraft:stick", display_name="Stick", quantity=1}}
        state.craft_result_count = 1
        state = screen:reduce(state, {type="CYCLE_SORT"}) -- default -> name
        screen:render(state, {lifecycle="READY"})
        T.contains(screen.surface.allText(), "SORT")
        T.contains(screen.surface.allText(), "Name")
        T.equal(screen.surface.writesOutsideBounds(), 0)
    end},

    {name="the sort indicator never overlaps the column labels or writes outside the surface, " ..
        "at every size", run=function()
        for _, size in ipairs({{51,19},{40,14},{30,12},{18,8}}) do
            local screen = UI.new(T.recordingSurface(size[1], size[2]))
            local state = UI.initialState()
            state.results, state.result_count, state.query = {result("a","Apple",1)}, 1, "a"
            state = screen:reduce(state, {type="CYCLE_SORT"})
            state = screen:reduce(state, {type="CYCLE_SORT"})
            state = screen:reduce(state, {type="CYCLE_SORT"}) -- land on "requests", a long label
            screen:render(state, {lifecycle="READY", search_results=state.results})
            T.equal(screen.surface.writesOutsideBounds(), 0,
                size[1] .. "x" .. size[2] .. " drew outside")
            T.contains(screen.surface.allText(), "ITEM",
                size[1] .. "x" .. size[2] .. " lost its column header")
        end
    end},

    -- The bounds test above proves a long label never overlaps anything; this proves it never
    -- solves that by disappearing. "Recently requested" was 23 characters against a 23-column
    -- band on the 51-wide terminal, so the indicator silently vanished in the two longest
    -- modes -- cycling sort then gave no feedback at all about which mode you had landed in.
    {name="every sort mode's indicator still fits the 51-column list band", run=function()
        for _, mode in ipairs(UI.SEARCH_SORT_MODES) do
            local screen = UI.new(T.recordingSurface(51, 19))
            local state = UI.initialState()
            state.results, state.result_count, state.query = {result("a","Apple",1)}, 1, "a"
            state.sort_mode = mode
            screen:render(state, {lifecycle="READY", search_results=state.results})
            T.contains(screen.surface.allText(), "SORT",
                "sort mode " .. mode .. " lost its indicator at 51 columns")
            T.contains(screen.surface.allText(), UI.SORT_MODE_LABELS[mode],
                "sort mode " .. mode .. " lost its label at 51 columns")
        end
    end},

    -- --- Coordinator wiring: F3 re-ranks and re-windows, Crafting name sort stays cheap ----

    {name="CYCLE_SORT on the Search page re-sorts through deps.search with the new mode",
     run=function()
        local seenOptions = {}
        local ui = UI.new(T.recordingSurface(51, 19))
        local deps = {
            clock=function() return 1000 end,
            scanner={begin=function() end, step=function() return true, {} end},
            nodes={}, ui=ui, keymap=require("app.keymap"),
            initial_ui=UI.initialState(),
            build_index=function() return {items=function() return {} end} end,
            search=function(_, _, _, _, options)
                seenOptions[#seenOptions + 1] = options
                return {}
            end,
        }
        local coordinator = Coordinator.new(deps)
        coordinator:handle({"key", keys.f3})
        T.truthy(#seenOptions >= 1, "CYCLE_SORT must trigger a fresh search")
        T.equal(seenOptions[#seenOptions].sort_mode, "quantity",
            "the coordinator must hand the newly cycled mode to deps.search")
    end},

    {name="CYCLE_SORT on the Crafting page re-ranks and re-windows without extra stock calls " ..
        "beyond the window, on a large catalogue", run=function()
        local CATALOGUE_SIZE = 3000
        local quantityCalls = 0
        local ui = UI.new(T.recordingSurface(51, 19))
        local outputs = {}
        for index = 1, CATALOGUE_SIZE do
            local id = string.format("%05d", index)
            -- Reverse-alphabetical display names, so a name-sorted order is provably not
            -- catalogue order.
            outputs[index] = {item="synth:item_" .. id,
                display_name="Synth " .. string.format("%05d", CATALOGUE_SIZE - index)}
        end
        local deps = {
            clock=function() return 1000 end,
            scanner={begin=function(_, node) return {node=node} end,
                step=function(_, scan) return true, {node_id=scan.node.id,
                    peripheral_name=scan.node.peripheral_name, epoch=1, size=27, occupied=0,
                    slots={}, health="READY"} end},
            nodes={{id="storage_1", role="storage", peripheral_name="store1", priority=1}},
            ui=ui, keymap=require("app.keymap"), initial_ui=UI.initialState(),
            build_index=function() return {
                items=function() return {} end,
                quantity=function() quantityCalls = quantityCalls + 1; return 0 end,
            } end,
            search=function() return {} end,
            recipes={outputs=function() return outputs end},
        }
        local coordinator = Coordinator.new(deps)
        for _ = 1, 4 do coordinator:workStep(1000) end
        coordinator:handle({"key", keys.six}) -- open Crafting
        coordinator:_syncCraft()
        local before = quantityCalls
        coordinator:handle({"key", keys.f3}) -- default -> name
        local used = quantityCalls - before
        local visible = coordinator:_craftWindowVisible()
        T.truthy(used > 0, "the visible window must still be materialized")
        T.truthy(used <= visible,
            "expected at most " .. visible .. " stock lookups for the re-sorted window, got " ..
            used)
        local state = coordinator:viewModel().ui
        T.equal(state.craft_sort_mode, "name")
        T.equal(state.craft_result_count, CATALOGUE_SIZE,
            "the true count must still be the whole catalogue after a re-sort")
        T.equal(state.craft_results[1].display_name, "Synth 00000",
            "the first visible row must be the alphabetically-first name, proving the " ..
            "positions were actually re-sorted by name, not left in catalogue order")
    end},

    {name="Crafting's name sort orders positions without any _craftStock calls of its own",
     run=function()
        local quantityCalls = 0
        local ui = UI.new(T.recordingSurface(51, 19))
        local outputs = {
            {item="mod:zebra", display_name="Zebra"},
            {item="mod:apple", display_name="Apple"},
            {item="mod:mango", display_name="Mango"},
        }
        local deps = {
            clock=function() return 1000 end,
            scanner={begin=function() end, step=function() return true, {} end},
            nodes={}, ui=ui, keymap=require("app.keymap"), initial_ui=UI.initialState(),
            build_index=function() return {
                items=function() return {} end,
                quantity=function() quantityCalls = quantityCalls + 1; return 0 end,
            } end,
            search=function() return {} end,
            recipes={outputs=function() return outputs end},
        }
        local coordinator = Coordinator.new(deps)
        local before = quantityCalls
        local order = coordinator:_craftOrder("", "name")
        T.equal(quantityCalls, before, "_craftOrder itself must never call _craftStock")
        local catalogue = coordinator:_craftCatalogue()
        T.equal(catalogue[order[1]].display_name, "Apple")
        T.equal(catalogue[order[2]].display_name, "Mango")
        T.equal(catalogue[order[3]].display_name, "Zebra")
    end},

    {name="relevance bucketing stays the outer key on Crafting: name only orders within a " ..
        "bucket, never across one", run=function()
        local ui = UI.new(T.recordingSurface(51, 19))
        local outputs = {
            -- "core" the exact id (top bucket) but named to sort last alphabetically; the two
            -- mid-word matches (lower bucket) are named to sort before it. A pass that let
            -- name override relevance would put one of the mid-word matches first.
            {item="core", display_name="Zzz Exact"},
            {item="mod:hardcore_item", display_name="Aaa Buried"},
            {item="mod:corebox", display_name="Bbb Prefix"},
        }
        local deps = {
            clock=function() return 1000 end,
            scanner={begin=function() end, step=function() return true, {} end},
            nodes={}, ui=ui, keymap=require("app.keymap"), initial_ui=UI.initialState(),
            build_index=function() return {items=function() return {} end} end,
            search=function() return {} end,
            recipes={outputs=function() return outputs end},
        }
        local coordinator = Coordinator.new(deps)
        local order = coordinator:_craftOrder("core", "name")
        local catalogue = coordinator:_craftCatalogue()
        local items = {}
        for _, position in ipairs(order) do items[#items + 1] = catalogue[position].item end
        T.equal(items[1], "core", "the exact id match must still rank first despite its name")
        T.equal(items[2], "mod:corebox", "the prefix match must still rank second")
        T.equal(items[3], "mod:hardcore_item", "the buried match must still rank last")
    end},

    {name="a stale cached craft order is discarded when only the sort mode changes",
     run=function()
        local ui = UI.new(T.recordingSurface(51, 19))
        local outputs = {
            {item="mod:zebra", display_name="Zebra"}, {item="mod:apple", display_name="Apple"},
        }
        local deps = {
            clock=function() return 1000 end,
            scanner={begin=function() end, step=function() return true, {} end},
            nodes={}, ui=ui, keymap=require("app.keymap"), initial_ui=UI.initialState(),
            build_index=function() return {items=function() return {} end} end,
            search=function() return {} end,
            recipes={outputs=function() return outputs end},
        }
        local coordinator = Coordinator.new(deps)
        local defaultOrder = coordinator:_craftOrder("", "default")
        local nameOrder = coordinator:_craftOrder("", "name")
        T.notEqual(defaultOrder[1], nameOrder[1],
            "the same query with a different sort mode must not reuse the other mode's cache")
        -- And asking for the original mode again must not still be holding the other mode's
        -- result either.
        local backToDefault = coordinator:_craftOrder("", "default")
        T.equal(backToDefault[1], defaultOrder[1])
    end},
}
