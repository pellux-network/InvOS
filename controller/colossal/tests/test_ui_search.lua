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
    -- Quantities chosen so the old formula and the new one disagree loudly. Against the old
    -- fixed 2048 denominator, 50 reads as 2% -- indistinguishable from empty. Against the
    -- largest item actually on screen it reads as half, which is the true relationship.
    { name = "the stock meter compares against the largest item in view", run = function()
        local function barCells(selection)
            local state = UI.initialState()
            state.results = {result("big", "Big", 100), result("small", "Small", 50)}
            state.result_count, state.selection = 2, selection
            local screen = UI.new(T.recordingSurface(51, 19))
            screen:render(state, {lifecycle="READY", search_results=state.results})
            local lit = 0
            for y = 1, 19 do
                for x = 31, 50 do
                    if screen.surface.backgroundAt(x, y) == Theme.role.ok then lit = lit + 1 end
                end
            end
            return lit
        end
        local half, whole = barCells(2), barCells(1)
        T.truthy(whole >= 15, "the largest item must fill its own bar, got " .. whole)
        T.truthy(half > 4 and half < whole - 2,
            "50 of a 100 maximum must read as about half, got " .. half .. " of " .. whole)
    end },
    { name = "the pane reports stacks, which is the unit players think in", run = function()
        local surface = render(51, 19, stateWith(8, 1))
        T.contains(surface.allText(), "stacks")
    end },
    { name = "the retrieve prompt uses the pane, not a box over the list", run = function()
        local state = stateWith(8, 3)
        local screen = UI.new(T.recordingSurface(51, 19))
        state = screen:reduce(state, {type="OPEN_QUANTITY"})
        screen:render(state, {lifecycle="READY", search_results=state.results})
        local text = screen.surface.allText()
        T.contains(text, "Retrieve")
        T.contains(text, "Amount")
        T.contains(text, "Item1", "the list must stay visible behind the prompt")
        T.contains(text, "Item8")
        -- The old overlay filled banded rows straight across the divider column. Row 12 is an
        -- unselected list row -- row 9 holds the selection and is legitimately filled.
        T.equal(screen.surface.backgroundAt(10, 12), Theme.role.ground,
            "the prompt must not paint over the list")
    end },
    { name = "a terminal too narrow for a pane still gets a usable prompt", run = function()
        local state = stateWith(8, 3)
        local screen = UI.new(T.recordingSurface(30, 19))
        state = screen:reduce(state, {type="OPEN_QUANTITY"})
        screen:render(state, {lifecycle="READY", search_results=state.results})
        T.contains(screen.surface.allText(), "Retrieve")
        T.contains(screen.surface.allText(), "A all")
        T.equal(screen.surface.writesOutsideBounds(), 0)
    end },
    { name = "the search page never draws outside its surface", run = function()
        for _, size in ipairs({{51,19},{80,24},{40,14},{26,12},{18,8}}) do
            local surface = render(size[1], size[2], stateWith(40, 30))
            T.equal(surface.writesOutsideBounds(), 0,
                size[1] .. "x" .. size[2] .. " drew outside")
        end
    end },
}
