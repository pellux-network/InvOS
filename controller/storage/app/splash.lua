local M = {}

-- Runs once, before the supervisor loop in startup.lua, so a cold boot gets a brief
-- animated brand moment without slowing down an automatic crash-restart. Never call this
-- from anywhere else.

local Draw = require("app.draw")
local Theme = require("app.theme")

local WORD = "INVOS"
local TAGLINE = "INVENTORY OPERATING SYSTEM"
local GLYPH_WIDTH = 5
local WORDMARK_HEIGHT = 5
local WORDMARK_WIDTH = GLYPH_WIDTH * #WORD + (#WORD - 1) -- letters plus one-space gaps

-- How many columns at the head of the wipe are drawn in the brighter accent. Two reads as a
-- moving edge; one is too thin to see at this cell size and three looks like a second colour.
local EDGE_WIDTH = 2

local function centerX(width, contentWidth)
    return math.max(1, math.floor((width - contentWidth) / 2) + 1)
end

local function clear(surface)
    surface.setBackgroundColor(Theme.role.ground)
    surface.setTextColor(Theme.role.text)
    surface.clear()
end

-- Paints the wordmark one column at a time, up to `reveal` columns, colouring anything from
-- `edgeFrom` onward in the accent. Reads Draw.glyphs directly rather than calling blockText,
-- because the leading edge falls mid-glyph and blockText paints whole glyphs. Each frame
-- clears first, so this only ever draws -- it never has to mask anything back out, and it
-- never reads the surface back, which no real CC surface supports.
local function paintWordmark(surface, left, top, reveal, edgeFrom)
    local column = 0
    for index = 1, #WORD do
        local glyph = Draw.glyphs[WORD:sub(index, index)]
        for offset = 1, GLYPH_WIDTH do
            if column >= reveal then return end
            local color = column >= edgeFrom and Theme.role.focus or Theme.role.brand
            for row = 1, WORDMARK_HEIGHT do
                if glyph[row]:sub(offset, offset) == "#" then
                    Draw.band(surface, top + row - 1, color, left + column, left + column)
                end
            end
            column = column + 1
        end
        column = column + 1 -- the one-column gap between letters
    end
end

-- Wipes the wordmark in behind a brighter leading edge, pulses once when it lands, then
-- sweeps a meter to signal the handoff into the application. One pulse, not a loop: a
-- looping splash reads as a hang rather than as a boot.
local function playWordmark(surface, sleepFn, width, height)
    local top = math.max(1, math.floor((height - (WORDMARK_HEIGHT + 2)) / 2))
    local left = centerX(width, WORDMARK_WIDTH)

    local wipeSteps = 6
    for step = 1, wipeSteps do
        clear(surface)
        local reveal = math.ceil(WORDMARK_WIDTH * step / wipeSteps)
        paintWordmark(surface, left, top, reveal, reveal - EDGE_WIDTH)
        sleepFn(0.06)
    end

    clear(surface)
    paintWordmark(surface, left, top, WORDMARK_WIDTH, 0)
    sleepFn(0.09)

    clear(surface)
    paintWordmark(surface, left, top, WORDMARK_WIDTH, WORDMARK_WIDTH)
    Draw.centerText(surface, math.floor(width / 2) + 1, top + WORDMARK_HEIGHT + 1,
        TAGLINE, Theme.role.muted, Theme.role.ground)
    sleepFn(0.4)

    local barWidth = math.min(24, width - 2)
    local barX = centerX(width, barWidth)
    local barY = top + WORDMARK_HEIGHT + 3
    local barSteps = 10
    for step = 1, barSteps do
        Draw.meter(surface, barX, barY, barWidth, step / barSteps,
            Theme.role.brand, Theme.role.track)
        sleepFn(0.04)
    end
    sleepFn(0.2)
end

-- A screen too small for the block wordmark (nothing deployed ships this small, but
-- nothing should crash on it either) gets a single centered line instead.
local function playCompact(surface, sleepFn, width, height)
    Draw.text(surface, centerX(width, 5), math.max(1, math.floor(height / 2)), "InvOS", 5,
        Theme.role.brand, Theme.role.ground)
    sleepFn(1.5)
end

function M.play(surface, sleepFn)
    sleepFn = sleepFn or sleep
    Theme.apply(surface)
    local width, height = surface.getSize()
    clear(surface)
    if width >= WORDMARK_WIDTH + 2 and height >= WORDMARK_HEIGHT + 5 then
        playWordmark(surface, sleepFn, width, height)
    else
        playCompact(surface, sleepFn, width, height)
    end
end

return M
