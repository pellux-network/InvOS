keys = keys or {}
keys.enter = keys.enter or 28

local UI = require("app.ui")
local Keymap = require("app.keymap")
local T = require("tests.mock_cc")

local function results(count)
    local list = {}
    for index = 1, count do
        list[index] = {identity_key="i"..index, name="minecraft:item"..index,
            display_name="Item "..index, quantity=index * 10, max_count=64,
            variants={{identity_key="i"..index, display_name="Item "..index,
                quantity=index * 10}}}
    end
    return list
end

local function model()
    return {lifecycle="READY", search_results=results(8), nodes={
        {id="dropoff", role="dropoff", label="Drop-off", state="READY", occupied=9, size=27},
        {id="s1", role="storage", label="Main Vault", state="READY", occupied=420, size=3075},
        {id="pickup", role="pickup", label="Pickup", state="READY", occupied=0, size=27},
    }, requests={{id="r1", display_name="Iron Ingot", state="QUEUED", delivered=0, requested=64}},
        alerts={{key="a", severity="warning", message="Vault filling"}}}
end

-- Renders, then resolves a click the way the coordinator does: the regions render returned
-- become state.hit_regions, and keymap matches the click against them.
local function screen(page, mutate)
    local surface = T.recordingSurface(51, 19)
    local ui = UI.new(surface)
    local state = UI.initialState()
    state.page, state.mode = page, page == "search" and "search" or "page"
    if mutate then mutate(state) end
    local layout = ui:render(state, model())
    state.hit_regions = layout.hit_regions
    return state, surface
end

local function clickAt(state, x, y)
    return Keymap.command({"mouse_click", 1, x, y}, state)
end

-- Where a label starts on a given row, so a test names what it clicks rather than a column.
local function columnOf(surface, row, text)
    return surface.line(row):find(text, 1, true)
end

return {
    {name="clicking a navigation tab opens that page",run=function()
        local state, surface = screen("search")
        -- The short labels: at 51 columns the nav has already given up its long ones.
        for _, entry in ipairs({{"NODES","storage"},{"REQS","requests"},
            {"ALERTS","alerts"},{"SETUP","setup"},{"CRAFT","crafting"}}) do
            local column = columnOf(surface, 2, entry[1])
            T.truthy(column ~= nil, entry[1] .. " is not on the nav row")
            local command = clickAt(state, column, 2)
            T.truthy(command ~= nil, "clicking " .. entry[1] .. " did nothing")
            T.equal(command.type, "OPEN_PAGE")
            T.equal(command.page, entry[2])
        end
    end},
    {name="a clicked tab does not suppress a character nobody typed",run=function()
        local state, surface = screen("search")
        local command = clickAt(state, columnOf(surface, 2, "NODES"), 2)
        T.equal(command.suppress_char, nil,
            "suppress_char exists to swallow a digit key's char event; a click has none")
    end},
    {name="clicking a search result selects it",run=function()
        local state, surface = screen("search")
        local row = nil
        for y = 1, 19 do if columnOf(surface, y, "Item 3") then row = y end end
        T.truthy(row ~= nil, "Item 3 is not on screen")
        local command = clickAt(state, 5, row)
        T.truthy(command ~= nil, "clicking a result did nothing")
        T.equal(command.type, "ACTIVATE")
        T.equal(command.index, 3)
    end},
    {name="clicking the retrieve button asks for a quantity",run=function()
        local state, surface = screen("search")
        local row, column
        for y = 1, 19 do
            local found = columnOf(surface, y, "RETRIEVE")
            if found then row, column = y, found end
        end
        T.truthy(row ~= nil, "the retrieve button is not on screen")
        local command = clickAt(state, column, row)
        T.truthy(command ~= nil, "clicking the button did nothing")
        T.equal(command.type, "OPEN_QUANTITY")
    end},
    {name="clicking a row on the secondary pages selects it",run=function()
        for _, case in ipairs({{"requests","Iron Ingot"},{"alerts","Vault filling"},
            {"storage","Main Vault"}}) do
            local state, surface = screen(case[1])
            local row
            for y = 1, 19 do if columnOf(surface, y, case[2]) then row = y end end
            T.truthy(row ~= nil, case[2] .. " is not on the " .. case[1] .. " page")
            local command = clickAt(state, 5, row)
            T.truthy(command ~= nil, "clicking a row on " .. case[1] .. " did nothing")
        end
    end},
    {name="clicking empty space does nothing at all",run=function()
        local state = screen("search")
        T.equal(clickAt(state, 50, 5), nil, "a click on blank chrome must not act")
    end},
    {name="rendering does not store the regions on the state it was given",run=function()
        local surface = T.recordingSurface(51, 19)
        local ui = UI.new(surface)
        local state = UI.initialState()
        state.results, state.result_count = results(8), 8
        ui:render(state, model())
        T.equal(#(state.hit_regions or {}), 0,
            "render must return the regions, never write them onto state")
    end},
}
