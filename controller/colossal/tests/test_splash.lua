local Splash = require("app.splash")
local T = require("tests.mock_cc")

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
        T.contains(text, "#####")
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
