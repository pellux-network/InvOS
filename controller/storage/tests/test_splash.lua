local Splash = require("app.splash")
local Theme = require("app.theme")
local T = require("tests.mock_cc")

-- How many cells anywhere on the surface carry `color` as their background. The wordmark is
-- painted rather than written since it moved onto Draw.blockText, so it is counted, not found.
local function paintedCells(surface, color, width, height)
    local count = 0
    for y = 1, height do
        for x = 1, width do
            if surface.backgroundAt(x, y) == color then count = count + 1 end
        end
    end
    return count
end

local function fakeSleep()
    local calls = {}
    return function(seconds) calls[#calls + 1] = seconds end, calls
end

return {
    {name="the wordmark is drawn on a full-size terminal",run=function()
        local surface = T.recordingSurface(51, 19)
        local sleepFn = fakeSleep()
        Splash.play(surface, sleepFn)
        local text = surface.allText()
        -- The wordmark used to be written as literal '#' characters. Draw.blockText paints
        -- background cells instead, so it is solid rather than hatched and there is no text
        -- to search for -- only colour.
        local painted = paintedCells(surface, Theme.role.brand, 51, 19)
        T.truthy(painted > 40, "expected a wordmark painted in brand colour, got " .. painted)
        T.contains(text, "INVENTORY OPERATING SYSTEM")
        T.equal(surface.writesOutsideBounds(), 0)
    end},
    {name="every frame stays within the surface on a small terminal",run=function()
        for _, size in ipairs({{51,19},{26,19},{20,10},{10,5}}) do
            local surface = T.recordingSurface(size[1], size[2])
            Splash.play(surface, fakeSleep())
            T.equal(surface.writesOutsideBounds(), 0,
                ("%dx%d surface"):format(size[1], size[2]))
        end
    end},
    {name="a terminal too small for the block wordmark still names the product",run=function()
        local surface = T.recordingSurface(10, 5)
        Splash.play(surface, fakeSleep())
        T.contains(surface.allText(), "InvOS")
    end},
    {name="the animation sleeps between frames but finishes in about 1.5 seconds",run=function()
        local surface = T.recordingSurface(51, 19)
        local sleepFn, calls = fakeSleep()
        Splash.play(surface, sleepFn)
        T.truthy(#calls > 1, "expected more than one animation frame")
        local total = 0
        for _, seconds in ipairs(calls) do total = total + seconds end
        T.truthy(total > 1 and total < 2.5,
            "expected roughly 1.5-2s of animation, got " .. total)
    end},
    {name="the wordmark wipes in rather than appearing all at once",run=function()
        local surface = T.recordingSurface(51, 19)
        local widths, frames = {}, 0
        Splash.play(surface, function()
            frames = frames + 1
            local rightmost = 0
            for y = 1, 19 do
                for x = 1, 51 do
                    local background = surface.backgroundAt(x, y)
                    if (background == Theme.role.brand or background == Theme.role.focus)
                        and x > rightmost then rightmost = x end
                end
            end
            widths[#widths + 1] = rightmost
        end)
        T.truthy(frames > 1, "expected more than one frame")
        local grew = false
        for index = 2, #widths do
            if widths[index] > widths[index - 1] then grew = true end
        end
        T.truthy(grew, "the wordmark must wipe in, not appear all at once")
    end},
    {name="the wipe has a leading edge and the landing pulses once",run=function()
        local surface = T.recordingSurface(51, 19)
        local coralFrames, frames = 0, 0
        Splash.play(surface, function()
            frames = frames + 1
            if paintedCells(surface, Theme.role.focus, 51, 19) > 0 then
                coralFrames = coralFrames + 1
            end
        end)
        T.truthy(coralFrames > 0,
            "the leading edge and the pulse are both coral; neither appeared")
        T.truthy(coralFrames < frames,
            "coral on every frame means the wordmark never settles to brand crimson")
    end},
    {name="play defaults to the global sleep when no sleep function is given",run=function()
        local previousSleep = sleep
        local calls = {}
        sleep = function(seconds) calls[#calls + 1] = seconds end
        local ok, reason = pcall(Splash.play, T.recordingSurface(51, 19))
        sleep = previousSleep
        if not ok then error(reason, 0) end
        T.truthy(#calls > 1, "expected the global sleep to be used as a fallback")
    end},
}
