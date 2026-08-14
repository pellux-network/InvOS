-- Trimmed copy of controller/storage/app/draw.lua's primitives for the turtle's own screen.
-- See theme.lua for why this is a copy rather than a shared module: the turtle tree cannot
-- require anything under controller/storage/app/.

local M = {}

-- The 2x3 subpixel characters live at 128-159; 149 (128 + 21) is the half-column and paints
-- its FOREGROUND on the left half of the cell, so a meter filling from the left passes the
-- fill as the foreground. See app/draw.lua for how this was established.
M.HALF = 149
M.subpixel = true

function M.text(surface, x, y, text, width, fg, bg)
    local surfaceWidth, surfaceHeight = surface.getSize()
    width = width or 0
    if y < 1 or y > surfaceHeight or x > surfaceWidth or width <= 0 then return end
    text = tostring(text or "")
    if x < 1 then
        local remove = 1 - x
        text = text:sub(remove + 1)
        width, x = width - remove, 1
    end
    if width <= 0 then return end
    text = text:sub(1, math.min(width, surfaceWidth - x + 1))
    if #text == 0 then return end
    if bg then surface.setBackgroundColor(bg) end
    if fg then surface.setTextColor(fg) end
    surface.setCursorPos(x, y)
    surface.write(text)
end

function M.centerText(surface, center, y, text, fg, bg)
    text = tostring(text or "")
    M.text(surface, math.floor(center - #text / 2 + 0.5), y, text, #text, fg, bg)
end

function M.rightText(surface, endX, y, text, fg, bg)
    text = tostring(text or "")
    M.text(surface, endX - #text + 1, y, text, #text, fg, bg)
end

-- A filled row, or a segment of one. The CC font has no box-drawing characters, so
-- structure is background colour or it is nothing.
function M.band(surface, y, bg, from, to)
    local surfaceWidth, surfaceHeight = surface.getSize()
    if y < 1 or y > surfaceHeight then return end
    from = math.max(1, from or 1)
    to = math.min(surfaceWidth, to or surfaceWidth)
    if to < from then return end
    surface.setBackgroundColor(bg)
    surface.setCursorPos(from, y)
    surface.write(string.rep(" ", to - from + 1))
end

-- A horizontal bar of `cells` columns, half-cell resolution via the subpixel character.
function M.meter(surface, x, y, cells, fraction, fill, track)
    fraction = math.max(0, math.min(1, tonumber(fraction) or 0))
    local halves
    if M.subpixel then
        halves = math.floor(fraction * cells * 2 + 0.5)
    else
        halves = math.floor(fraction * cells + 0.5) * 2
    end
    local whole = math.floor(halves / 2)
    local partial = halves % 2 == 1
    for index = 0, cells - 1 do
        local cellX = x + index
        if index < whole then
            M.band(surface, y, fill, cellX, cellX)
        elseif index == whole and partial then
            M.text(surface, cellX, y, string.char(M.HALF), 1, fill, track)
        else
            M.band(surface, y, track, cellX, cellX)
        end
    end
end

-- Five-row block glyphs, same set as the controller's splash uses for the wordmark, plus
-- digits for a hero number on the idle screen.
M.glyphs = {
    ["0"] = {" ### ", "#   #", "#   #", "#   #", " ### "},
    ["1"] = {"  #  ", " ##  ", "  #  ", "  #  ", " ### "},
    ["2"] = {" ### ", "#   #", "   # ", "  #  ", "#####"},
    ["3"] = {"#### ", "    #", " ### ", "    #", "#### "},
    ["4"] = {"#  # ", "#  # ", "#####", "   # ", "   # "},
    ["5"] = {"#####", "#    ", "#### ", "    #", "#### "},
    ["6"] = {" ### ", "#    ", "#### ", "#   #", " ### "},
    ["7"] = {"#####", "    #", "   # ", "  #  ", "  #  "},
    ["8"] = {" ### ", "#   #", " ### ", "#   #", " ### "},
    ["9"] = {" ### ", "#   #", " ####", "    #", " ### "},
    [","] = {"     ", "     ", "     ", "  #  ", " #   "},
    ["I"] = {"#####", "  #  ", "  #  ", "  #  ", "#####"},
    ["N"] = {"#   #", "##  #", "# # #", "#  ##", "#   #"},
    ["V"] = {"#   #", "#   #", "#   #", " # # ", "  #  "},
    ["O"] = {" ### ", "#   #", "#   #", "#   #", " ### "},
    ["S"] = {" ####", "#    ", " ### ", "    #", "#### "},
}

-- Returns the column after the text, so a caller can place something beside it without
-- recomputing the width. An unknown character advances three columns as a word space.
function M.blockText(surface, x, y, text, color)
    local cursor = x
    text = tostring(text or "")
    for index = 1, #text do
        local glyph = M.glyphs[text:sub(index, index)]
        if glyph then
            for row = 1, #glyph do
                local line = glyph[row]
                for column = 1, #line do
                    if line:sub(column, column) == "#" then
                        M.band(surface, y + row - 1, color,
                            cursor + column - 1, cursor + column - 1)
                    end
                end
            end
            cursor = cursor + #glyph[1] + 1
        else
            cursor = cursor + 3
        end
    end
    return cursor
end

return M
