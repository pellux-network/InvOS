local M = {}

-- Runs once, before the supervisor loop in startup.lua, so a cold boot gets a brief
-- animated brand moment without slowing down an automatic crash-restart. Never call this
-- from anywhere else.

local palette = colors or {
    white=1, lightGray=256, red=16384, black=32768,
}

local GLYPHS = {
    I = {"#####","  #  ","  #  ","  #  ","#####"},
    N = {"#   #","##  #","# # #","#  ##","#   #"},
    V = {"#   #","#   #","#   #"," # # ","  #  "},
    O = {" ### ","#   #","#   #","#   #"," ### "},
    S = {" ####","#    "," ### ","    #","#### "},
}

local WORD = "INVOS"
local TAGLINE = "INVENTORY OPERATING SYSTEM"
local WORDMARK_HEIGHT = 5
local WORDMARK_WIDTH = 5 * #WORD + (#WORD - 1) -- letters plus one-space gaps

local function wordmarkRows()
    local rows = {"", "", "", "", ""}
    for index = 1, #WORD do
        local glyph = GLYPHS[WORD:sub(index, index)]
        local gap = index < #WORD and " " or ""
        for row = 1, WORDMARK_HEIGHT do rows[row] = rows[row] .. glyph[row] .. gap end
    end
    return rows
end

local function centerX(width, contentWidth) return math.max(1, math.floor((width - contentWidth) / 2) + 1) end

local function safeWrite(surface, x, y, text, color)
    local width, height = surface.getSize()
    if y < 1 or y > height or x > width or #text == 0 then return end
    if x < 1 then text = text:sub(2 - x); x = 1 end
    text = text:sub(1, width - x + 1)
    if #text == 0 then return end
    surface.setBackgroundColor(palette.black)
    surface.setTextColor(color)
    surface.setCursorPos(x, y)
    surface.write(text)
end

local function clear(surface)
    surface.setBackgroundColor(palette.black)
    surface.setTextColor(palette.white)
    surface.clear()
end

-- Wipes the block wordmark in from the left, holds it with its tagline, then sweeps a
-- short loading bar to signal the handoff into the application.
local function playWordmark(surface, sleepFn, width, height)
    local rows = wordmarkRows()
    local top = math.max(1, math.floor((height - (WORDMARK_HEIGHT + 2)) / 2))
    local left = centerX(width, WORDMARK_WIDTH)

    local wipeSteps = 6
    for step = 1, wipeSteps do
        clear(surface)
        local reveal = math.ceil(WORDMARK_WIDTH * step / wipeSteps)
        for row = 1, WORDMARK_HEIGHT do
            safeWrite(surface, left, top + row - 1, rows[row]:sub(1, reveal), palette.red)
        end
        sleepFn(0.06)
    end

    safeWrite(surface, centerX(width, #TAGLINE), top + WORDMARK_HEIGHT + 1, TAGLINE, palette.lightGray)
    sleepFn(0.5)

    local barWidth = math.min(24, width - 2)
    local barX, barY = centerX(width, barWidth), top + WORDMARK_HEIGHT + 3
    local barSteps = 10
    for step = 1, barSteps do
        local filled = math.ceil(barWidth * step / barSteps)
        safeWrite(surface, barX, barY, string.rep("#", filled) .. string.rep("-", barWidth - filled), palette.red)
        sleepFn(0.04)
    end
    sleepFn(0.2)
end

-- A screen too small for the block wordmark (nothing deployed ships this small, but
-- nothing should crash on it either) gets a single centered line instead.
local function playCompact(surface, sleepFn, width, height)
    safeWrite(surface, centerX(width, 5), math.max(1, math.floor(height / 2)), "InvOS", palette.red)
    sleepFn(1.5)
end

function M.play(surface, sleepFn)
    sleepFn = sleepFn or sleep
    local width, height = surface.getSize()
    clear(surface)
    if width >= WORDMARK_WIDTH + 2 and height >= WORDMARK_HEIGHT + 5 then
        playWordmark(surface, sleepFn, width, height)
    else
        playCompact(surface, sleepFn, width, height)
    end
end

return M
