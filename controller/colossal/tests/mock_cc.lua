local M = {}

local function render(value)
    if type(value) ~= "table" then return tostring(value) end
    local parts = { "{" }
    for key, item in pairs(value) do
        parts[#parts + 1] = tostring(key) .. "=" .. render(item)
        parts[#parts + 1] = ","
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

function M.equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. render(expected) ..
            ", got " .. render(actual), 2)
    end
end

function M.notEqual(actual, expected, message)
    if actual == expected then error((message or "values unexpectedly equal") .. ": " .. render(actual), 2) end
end

function M.truthy(value, message)
    if not value then error(message or "expected a truthy value", 2) end
end

function M.contains(value, expected, message)
    if not tostring(value):find(tostring(expected), 1, true) then
        error((message or "text not found") .. ": expected " .. tostring(expected) ..
            " in " .. tostring(value), 2)
    end
end

function M.arrayEqual(actual, expected, message)
    M.equal(type(actual), "table", message)
    M.equal(#actual, #expected, message)
    for index = 1, #expected do
        M.equal(actual[index], expected[index], (message or "arrays differ") .. " at " .. index)
    end
end

function M.fails(fn, expected)
    local ok, reason = pcall(fn)
    if ok then error("expected failure", 2) end
    if expected then M.contains(reason, expected, "wrong failure") end
end

function M.clock(start)
    local now = start or 0
    return {
        now = function() return now end,
        advance = function(amount) now = now + amount; return now end,
    }
end

function M.memoryFs(initial)
    local files = {}
    for path, value in pairs(initial or {}) do files[path] = value end
    local api = { files = files, failMoveTo = nil }
    function api.combine(left, right)
        if left == "" then return right end
        return left:gsub("/$", "") .. "/" .. right:gsub("^/", "")
    end
    function api.exists(path) return files[path] ~= nil end
    function api.makeDir(_) end
    function api.delete(path) files[path] = nil end
    function api.move(from, to)
        if api.failMoveTo == to then error("injected move failure") end
        if files[from] == nil then error("missing source: " .. from) end
        files[to], files[from] = files[from], nil
    end
    function api.open(path, mode)
        if mode == "r" then
            if files[path] == nil then return nil end
            return { readAll = function() return files[path] end, close = function() end }
        end
        if mode == "w" then
            local chunks = {}
            return {
                write = function(value) chunks[#chunks + 1] = tostring(value) end,
                close = function() files[path] = table.concat(chunks) end,
            }
        end
        error("unsupported mode: " .. tostring(mode))
    end
    return api
end

function M.recordingSurface(width, height)
    local cells, backgrounds, foregrounds, cursorX, cursorY = {}, {}, {}, 1, 1
    local outside, background, foreground = 0, 32768, 1
    for y = 1, height do cells[y], backgrounds[y], foregrounds[y] = {}, {}, {} end
    local surface = {}
    function surface.getSize() return width, height end
    function surface.clear()
        for y = 1, height do cells[y], backgrounds[y], foregrounds[y] = {}, {}, {} end
        cursorX, cursorY = 1, 1
    end
    function surface.setCursorPos(x, y)
        if x < 1 or x > width or y < 1 or y > height then outside = outside + 1 end
        cursorX, cursorY = x, y
    end
    function surface.getCursorPos() return cursorX, cursorY end
    function surface.setCursorBlink(_) end
    function surface.setTextColor(value) foreground=value end
    function surface.setBackgroundColor(value) background=value end
    function surface.setTextScale(_) end
    function surface.write(value)
        value = tostring(value)
        if cursorY < 1 or cursorY > height or cursorX < 1 or cursorX + #value - 1 > width then
            outside = outside + 1
            return
        end
        for index = 1, #value do
            cells[cursorY][cursorX + index - 1] = value:sub(index, index)
            backgrounds[cursorY][cursorX + index - 1] = background
            foregrounds[cursorY][cursorX + index - 1] = foreground
        end
        cursorX = cursorX + #value
    end
    function surface.line(y)
        local result = {}
        for x = 1, width do result[x] = cells[y][x] or " " end
        return table.concat(result)
    end
    function surface.allText()
        local lines = {}
        for y = 1, height do lines[y] = surface.line(y) end
        return table.concat(lines, "\n")
    end
    function surface.backgroundAt(x,y) return backgrounds[y] and backgrounds[y][x] end
    -- Foreground was untracked until a half-filled meter cell shipped with its fill on the
    -- wrong side of the character: every assertion available could only see the background,
    -- so nothing in the suite could tell which half was lit.
    function surface.foregroundAt(x,y) return foregrounds[y] and foregrounds[y][x] end
    function surface.writesOutsideBounds() return outside end
    return surface
end

return M
