local UI = require("app.ui")
local Theme = require("app.theme")
local Layout = require("app.layout")
local T = require("tests.mock_cc")

local function ui(width, height) return UI.new(T.recordingSurface(width or 51, height or 19)) end

return {
    { name = "a list shows the window that contains the selection", run = function()
        local screen, seen = ui(), {}
        local scroll = screen:_list(1, 5, 40, 30, function(index, y)
            seen[#seen + 1] = index
            T.truthy(y >= 1 and y <= 5, "row " .. index .. " drew at " .. y)
        end)
        T.equal(scroll, 26, "a five-row window ending on 30 starts at 26")
        T.equal(#seen, 5)
        T.equal(seen[5], 30, "the selection must be the last visible row")
    end },
    { name = "a list shorter than its window draws every row and no more", run = function()
        local screen, seen = ui(), 0
        screen:_list(1, 8, 3, 1, function() seen = seen + 1 end)
        T.equal(seen, 3, "an empty row must not be rendered")
    end },
    { name = "a list with no rows renders nothing and does not error", run = function()
        local screen, seen = ui(), 0
        screen:_list(1, 8, 0, 1, function() seen = seen + 1 end)
        T.equal(seen, 0)
    end },
    { name = "a windowed list honours an explicit scroll offset", run = function()
        local screen, seen = ui(), {}
        local scroll = screen:_windowed(1, 5, 20, 8, function(index) seen[#seen + 1] = index end)
        T.equal(scroll, 8)
        T.equal(seen[1], 8)
        T.equal(#seen, 5)
    end },
    { name = "a windowed list clamps a scroll past the end back onto the last page", run = function()
        local screen, seen = ui(), {}
        local scroll = screen:_windowed(1, 5, 20, 99, function(index) seen[#seen + 1] = index end)
        T.equal(scroll, 16, "twenty rows in a five-row window ends at sixteen")
        T.equal(seen[#seen], 20, "the last row must be reachable")
    end },
    { name = "the selected row is filled in the focus colour everywhere", run = function()
        local screen = ui()
        screen:_row(4, true, 1, 20, "o", Theme.role.ok, "Iron Ingot", "1,284")
        local surface = screen.surface
        local filled = 0
        for x = 1, 20 do
            if surface.backgroundAt(x, 4) == Theme.role.focus then filled = filled + 1 end
        end
        T.equal(filled, 20, "the whole row segment must fill, not just the text")
        T.contains(surface.line(4), "Iron Ingot")
        T.contains(surface.line(4), "1,284")
    end },
    { name = "an unselected row leaves the ground alone", run = function()
        local screen = ui()
        screen:_row(4, false, 1, 20, nil, nil, "Iron Block", "96")
        local surface = screen.surface
        for x = 1, 20 do
            T.equal(surface.backgroundAt(x, 4), Theme.role.ground)
        end
    end },
    { name = "a row clips its name rather than overrunning its value", run = function()
        local screen = ui()
        screen:_row(4, false, 1, 20, nil, nil,
            "An Extremely Long Modded Item Name", "12,032")
        T.equal(screen.surface.writesOutsideBounds(), 0)
        T.contains(screen.surface.line(4), "12,032")
    end },
    { name = "the strip meters drop-off and pickup from the node list", run = function()
        local screen = ui()
        local regions = Layout.regions(51, 19)
        screen:_strip(regions, { nodes = {
            { id="dropoff", role="dropoff", occupied=9,  size=27 },
            { id="s1",      role="storage", occupied=40, size=54 },
            { id="pickup",  role="pickup",  occupied=0,  size=27 },
        }})
        local line = screen.surface.line(regions.strip)
        T.contains(line, "DROP-OFF")
        T.contains(line, "PICKUP")
        T.contains(line, "33%", "9 of 27 is 33 percent")
        T.contains(line, "0%")
    end },
    { name = "the strip is silent when the screen has no room for it", run = function()
        local screen = ui(51, 8)
        local regions = Layout.regions(51, 8)
        T.equal(regions.strip, nil)
        screen:_strip(regions, { nodes = {} })
        T.equal(screen.surface.writesOutsideBounds(), 0)
    end },
    { name = "the strip survives a model with no nodes at all", run = function()
        local screen = ui()
        screen:_strip(Layout.regions(51, 19), {})
        T.equal(screen.surface.writesOutsideBounds(), 0)
    end },
}
