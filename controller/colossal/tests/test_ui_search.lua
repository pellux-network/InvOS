local UI = require("app.ui")
local Theme = require("app.theme")
local T = require("tests.mock_cc")

local function result(key, name, quantity, variants)
    return {identity_key=key, name="minecraft:"..name:lower(), display_name=name,
        quantity=quantity, max_count=64, variants=variants or {{identity_key=key,
        display_name=name, quantity=quantity, max_count=64}}}
end

local function stateWith(count, selection)
    local state = UI.initialState()
    state.results = {}
    for index = 1, count do
        state.results[index] = result("i"..index, "Item"..index, index * 10)
    end
    state.result_count = count
    state.selection = selection or 1
    state.query = "ir"
    return state
end

local function render(width, height, state)
    local screen = UI.new(T.recordingSurface(width, height))
    screen:render(state, {lifecycle="READY", search_results=state.results, nodes={
        {id="dropoff", role="dropoff", occupied=9, size=27},
        {id="pickup", role="pickup", occupied=0, size=27},
    }})
    return screen.surface
end

return {
    { name = "the search page shows its query, list and detail pane", run = function()
        local surface = render(51, 19, stateWith(8, 1))
        local text = surface.allText()
        T.contains(text, "> ir")
        T.contains(text, "ITEM")
        T.contains(text, "STOCK")
        T.contains(text, "Item1")
        T.contains(text, "minecraft:item1", "the detail pane must show the exact id")
    end },
    { name = "the selected row is filled in focus, not in brand red", run = function()
        local surface = render(51, 19, stateWith(8, 1))
        local focusRows = 0
        for y = 1, 19 do
            if surface.backgroundAt(2, y) == Theme.role.focus then focusRows = focusRows + 1 end
        end
        T.truthy(focusRows >= 1, "the selection must be filled")
    end },
    { name = "a long result list scrolls to keep the selection visible", run = function()
        local surface = render(51, 19, stateWith(40, 30))
        local text = surface.allText()
        T.contains(text, "Item30")
        T.equal(text:find("Item1 ", 1, true), nil)
    end },
    { name = "an empty query explains itself rather than showing a blank list", run = function()
        local state = UI.initialState()
        local screen = UI.new(T.recordingSurface(51, 19))
        screen:render(state, {lifecycle="READY", search_results={}})
        T.contains(screen.surface.allText(), "Start typing")
    end },
    { name = "a query with no matches says so", run = function()
        local state = stateWith(0, 1)
        local screen = UI.new(T.recordingSurface(51, 19))
        screen:render(state, {lifecycle="READY", search_results={}})
        T.contains(screen.surface.allText(), "No matching items")
    end },
    { name = "the chest strip appears on the search page", run = function()
        local surface = render(51, 19, stateWith(8, 1))
        T.contains(surface.line(17), "DROP-OFF")
        T.contains(surface.line(17), "33%")
    end },
    { name = "the detail pane collapses below 40 columns", run = function()
        local surface = render(30, 19, stateWith(8, 1))
        T.equal(surface.writesOutsideBounds(), 0)
        T.contains(surface.allText(), "Item1")
    end },
    { name = "the search page never draws outside its surface", run = function()
        for _, size in ipairs({{51,19},{80,24},{40,14},{26,12},{18,8}}) do
            local surface = render(size[1], size[2], stateWith(40, 30))
            T.equal(surface.writesOutsideBounds(), 0,
                size[1] .. "x" .. size[2] .. " drew outside")
        end
    end },
}
