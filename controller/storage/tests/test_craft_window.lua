-- The Crafting page used to cap at CRAFT_SEARCH_LIMIT (60) matches, materializing a full
-- entry table with a `_craftStock` call for every one of them. On the live pack (22k+
-- outputs) that cap hid results and, if simply raised, would have made every keystroke do
-- thousands of stock lookups. These tests cover the windowing that replaced it: ranking now
-- produces the full match order as plain catalogue positions (app/coordinator.lua's
-- `_craftOrder`), and only the visible window around the current selection is ever
-- materialized into full rows (`_craftMaterializeWindow`). The catalogue here is synthetic
-- and large -- AGENTS.md is explicit that a live pack belongs in test_craft_integration.lua,
-- never in a unit test.
local Coordinator = require("app.coordinator")
local UI = require("app.ui")
local T = require("tests.mock_cc")

local CATALOGUE_SIZE = 4000

local function scanner()
    local api = {}
    function api:begin(node) return {node=node} end
    function api:step(scan)
        return true, {node_id=scan.node.id, peripheral_name=scan.node.peripheral_name,
            epoch=1, size=27, occupied=0, slots={}, health="READY"}
    end
    return api
end

local function syntheticOutputs()
    local outputs = {}
    for index = 1, CATALOGUE_SIZE do
        local id = string.format("%05d", index)
        outputs[index] = {item="synth:item_" .. id, display_name="Synth Item " .. id}
    end
    return outputs
end

-- Builds a coordinator wired to a synthetic catalogue and a `quantity` lookup that counts
-- its own calls, so a test can assert how many stock lookups a query actually costs. Returns
-- the coordinator and a closure reading the running call count.
local function build(overrides)
    local quantityCalls = 0
    local ui = UI.new(T.recordingSurface(51, 19))
    local deps = {
        clock=function() return 1000 end, scanner=scanner(), scan_budget=8,
        nodes={{id="storage_1", role="storage", peripheral_name="store1", priority=1}},
        ui=ui, keymap={command=function() end}, initial_ui=UI.initialState(),
        build_index=function() return {
            items=function() return {} end,
            quantity=function() quantityCalls = quantityCalls + 1; return 0 end,
        } end,
        search=function() return {} end,
        recipes={outputs=syntheticOutputs},
    }
    for key, value in pairs(overrides or {}) do deps[key] = value end
    local coordinator = Coordinator.new(deps)
    for _ = 1, 4 do coordinator:workStep(1000) end
    return coordinator, function() return quantityCalls end
end

-- Mirrors what Coordinator:handle does for MOVE/ACTIVATE on the crafting page: the reducer
-- moves the selection, then the coordinator re-windows around wherever it landed.
local function move(coordinator, delta)
    coordinator:command({type="MOVE", delta=delta})
    coordinator:_syncCraftWindow()
end

return {
    {name="the true total is the whole catalogue, not the materialized window", run=function()
        local coordinator = build()
        coordinator:command({type="OPEN_PAGE", page="crafting"})
        coordinator:_syncCraft()
        local state = coordinator:viewModel().ui
        T.equal(state.craft_result_count, CATALOGUE_SIZE,
            "an empty query must report the true count across the whole catalogue")
        T.truthy(#state.craft_results < CATALOGUE_SIZE,
            "only a window may be materialized into full rows")
    end},

    {name="materializing a query costs stock lookups proportional to the window, not the catalogue",
        run=function()
        local coordinator, calls = build()
        coordinator:command({type="OPEN_PAGE", page="crafting"})
        local before = calls()
        coordinator:_syncCraft()
        local used = calls() - before
        local visible = coordinator:_craftWindowVisible()
        T.truthy(used > 0, "the visible window must still be materialized")
        T.truthy(used <= visible,
            "expected at most " .. visible .. " stock lookups for one window, got " .. used)
        T.truthy(used < CATALOGUE_SIZE / 10,
            "materialization cost must not scale with catalogue size, got " .. used ..
            " lookups against a " .. CATALOGUE_SIZE .. "-entry catalogue")
    end},

    {name="scrolling all the way to the last entry re-windows instead of stopping at the old edge",
        run=function()
        local coordinator = build()
        coordinator:command({type="OPEN_PAGE", page="crafting"})
        coordinator:_syncCraft()
        -- One giant jump is exactly what holding the down arrow does over many ticks; the
        -- reducer clamps craft_selection to the true total (CATALOGUE_SIZE), so this lands
        -- on the very last entry in a single MOVE.
        move(coordinator, CATALOGUE_SIZE)
        local state = coordinator:viewModel().ui
        T.equal(state.craft_selection, CATALOGUE_SIZE,
            "the selection must be able to reach the true last position")
        coordinator:command({type="OPEN_CRAFT_QUANTITY"})
        local item = coordinator:viewModel().ui.craft_item
        T.truthy(item ~= nil,
            "the last entry must be selectable, proving the coordinator re-windowed to cover it")
        T.equal(item.item, "synth:item_" .. string.format("%05d", CATALOGUE_SIZE))
    end},

    {name="scrolling reaches the middle of a catalogue far larger than any window", run=function()
        local coordinator = build()
        coordinator:command({type="OPEN_PAGE", page="crafting"})
        coordinator:_syncCraft()
        local middle = math.floor(CATALOGUE_SIZE / 2)
        move(coordinator, middle - 1)
        coordinator:command({type="OPEN_CRAFT_QUANTITY"})
        local item = coordinator:viewModel().ui.craft_item
        T.truthy(item ~= nil, "the middle of the catalogue must be reachable and selectable")
        T.equal(item.item, "synth:item_" .. string.format("%05d", middle))
    end},

    {name="moving the selection does not re-rank: the cached order is reused", run=function()
        local coordinator = build()
        coordinator:command({type="OPEN_PAGE", page="crafting"})
        coordinator:command({type="CRAFT_QUERY_APPEND", text="item_0000"})
        coordinator:_syncCraft()
        local order = coordinator.craftOrder
        move(coordinator, 1)
        T.equal(coordinator.craftOrder, order,
            "a selection-only move must not recompute the ranked order")
    end},

    {name="ranking with a non-empty query is unchanged: exact, then prefix, then buried",
        run=function()
        -- Deliberately catalogued out of rank order, so a pass that only reflects
        -- catalogue order rather than relevance() would fail this.
        local recipes = {outputs=function() return {
            {item="mod:hardcore_item", display_name="Hardcore Item"}, -- "core" mid-word: 1
            {item="mod:other", display_name="Nothing Relevant"},      -- no match: excluded
            {item="mod:corebox", display_name="Core Box"},            -- prefix: 4
            {item="core", display_name="Something Core"},             -- exact id: 7
        } end}
        local coordinator = build({recipes=recipes})
        local order = coordinator:_craftOrder("core")
        local catalogue = coordinator:_craftCatalogue()
        local items = {}
        for _, position in ipairs(order) do items[#items + 1] = catalogue[position].item end
        T.equal(#items, 3, "exactly the three matching entries, no more")
        T.equal(items[1], "core", "an exact id match must rank first")
        T.equal(items[2], "mod:corebox", "a prefix match must rank second")
        T.equal(items[3], "mod:hardcore_item", "a buried mid-word match must rank last")
    end},
}
