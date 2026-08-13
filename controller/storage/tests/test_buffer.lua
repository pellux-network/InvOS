local Buffer = require("app.buffer")
local T = require("tests.mock_cc")

-- A stand-in for CC's window API. Records visibility flips and repositions so a test can see
-- that a frame was drawn hidden and shown exactly once.
local function fakeWindowApi(width, height)
    local api, log = {}, {visible = {}, repositions = {}}
    function api.create(parent, x, y, w, h)
        local size = {w = w, h = h}
        local win = {}
        function win.getSize() return size.w, size.h end
        function win.setVisible(value) log.visible[#log.visible + 1] = value end
        function win.reposition(_, _, newWidth, newHeight)
            size.w, size.h = newWidth, newHeight
            log.repositions[#log.repositions + 1] = {newWidth, newHeight}
        end
        function win.write(value) log.lastWrite = value end
        function win.clear() log.cleared = true end
        function win.setCursorPos() end
        function win.setBackgroundColor() end
        function win.setTextColor() end
        return win
    end
    return api, log
end

return {
    { name = "a surface with no window API is handed back untouched", run = function()
        local surface = T.recordingSurface(51, 19)
        T.equal(Buffer.wrap(surface, nil), surface,
            "the host suite has no window API and must render exactly as before")
        T.equal(Buffer.wrap(surface, {}), surface)
    end },
    { name = "a frame is drawn hidden and shown once", run = function()
        local api, log = fakeWindowApi(51, 19)
        local buffered = Buffer.wrap(T.recordingSurface(51, 19), api)
        buffered.beginFrame()
        buffered.write("something")
        buffered.endFrame()
        T.equal(#log.visible, 2)
        T.equal(log.visible[1], false, "the frame must be drawn while hidden")
        T.equal(log.visible[2], true, "and shown once it is complete")
    end },
    { name = "the buffer follows the surface when the screen is resized", run = function()
        local api, log = fakeWindowApi(51, 19)
        -- A monitor changes size when blocks are added to it, and the buffer has to follow or
        -- it keeps painting the old rectangle. A resizable parent, since recordingSurface is
        -- fixed at construction.
        local size = {w = 51, h = 19}
        local parent = {getSize = function() return size.w, size.h end}
        local buffered = Buffer.wrap(parent, api)
        buffered.beginFrame()
        T.equal(#log.repositions, 0, "an unchanged size must not reposition")
        size.w, size.h = 80, 24
        buffered.beginFrame()
        T.equal(#log.repositions, 1)
        T.equal(log.repositions[1][1], 80)
        T.equal(log.repositions[1][2], 24)
    end },
    { name = "the wrapped surface still behaves like a surface", run = function()
        local api = fakeWindowApi(51, 19)
        local buffered = Buffer.wrap(T.recordingSurface(51, 19), api)
        T.equal(type(buffered.getSize), "function")
        T.equal(type(buffered.write), "function")
        T.equal(type(buffered.clear), "function")
        local width, height = buffered.getSize()
        T.equal(width, 51)
        T.equal(height, 19)
    end },
    { name = "a window API that refuses to create one falls back to the surface", run = function()
        local surface = T.recordingSurface(51, 19)
        local api = {create = function() error("no windows here") end}
        T.equal(Buffer.wrap(surface, api), surface)
    end },
    { name = "every render path ends the frame it began", run = function()
        local UI = require("app.ui")
        -- A frame begun and never ended leaves the buffered window hidden forever: the
        -- application keeps running perfectly and the screen freezes on the last good frame.
        local frames = {begun = 0, ended = 0}
        local surface = T.recordingSurface(51, 19)
        surface.beginFrame = function() frames.begun = frames.begun + 1 end
        surface.endFrame = function() frames.ended = frames.ended + 1 end
        local screen = UI.new(surface)
        for _, page in ipairs({"search", "storage", "requests", "alerts", "crafting", "setup"}) do
            local state = UI.initialState()
            state.page, state.mode = page, "page"
            screen:render(state, {lifecycle="READY"})
        end
        -- The setup wizard is the one render path that returns early.
        local wizard = UI.initialState()
        wizard.page, wizard.mode, wizard.setup_step = "setup", "setup", 1
        screen:render(wizard, {lifecycle="READY"})
        T.equal(frames.ended, frames.begun,
            "began " .. frames.begun .. " frames but ended " .. frames.ended)
    end },
    { name = "a render that throws still ends its frame", run = function()
        local UI = require("app.ui")
        local frames = {begun = 0, ended = 0}
        local surface = T.recordingSurface(51, 19)
        surface.beginFrame = function() frames.begun = frames.begun + 1 end
        surface.endFrame = function() frames.ended = frames.ended + 1 end
        local screen = UI.new(surface)
        -- A model shaped wrongly enough to break a page renderer.
        local state = UI.initialState()
        state.page, state.mode = "requests", "page"
        pcall(screen.render, screen, state, {lifecycle="READY", requests="not a table"})
        T.equal(frames.begun, 1)
        T.equal(frames.ended, 1, "an error must not leave the window hidden forever")
    end },
}
