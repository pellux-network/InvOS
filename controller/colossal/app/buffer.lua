local M = {}

-- CC draws every terminal call straight to the screen, so a render that clears and then
-- repaints shows a genuinely blank screen in between. The work loop redraws whenever
-- anything is marked dirty -- which enrichment does every time it learns an item name -- so
-- during a scan that blank-then-repaint cycle happens many times a second and reads as
-- constant flicker.
--
-- A window is an off-screen buffer over the same surface. Hide it, draw the whole frame into
-- it, show it, and the frame reaches the screen in one blit with no blank in between.
--
-- Returns the surface untouched when there is no window API, which is the case in the host
-- test suite and on any surface CC will not give a window for. Callers therefore have to
-- treat beginFrame and endFrame as optional.
function M.wrap(surface, windowApi)
    if windowApi == nil and type(window) == "table" then windowApi = window end
    if type(surface) ~= "table" or type(surface.getSize) ~= "function" then return surface end
    if type(windowApi) ~= "table" or type(windowApi.create) ~= "function" then return surface end

    local width, height = surface.getSize()
    local ok, buffer = pcall(windowApi.create, surface, 1, 1, width, height, true)
    if not ok or type(buffer) ~= "table" or type(buffer.setVisible) ~= "function" then
        return surface
    end

    local proxy = {}
    for key, value in pairs(buffer) do
        if type(value) == "function" then proxy[key] = value end
    end

    -- A monitor changes size when blocks are added to it. Checking here rather than reacting
    -- to the resize event keeps the buffer self-healing: whatever the surface is now, the
    -- next frame matches it.
    function proxy.beginFrame()
        local currentWidth, currentHeight = surface.getSize()
        local bufferWidth, bufferHeight = buffer.getSize()
        if currentWidth ~= bufferWidth or currentHeight ~= bufferHeight then
            pcall(buffer.reposition, 1, 1, currentWidth, currentHeight)
        end
        buffer.setVisible(false)
    end

    function proxy.endFrame() buffer.setVisible(true) end

    return proxy
end

return M
