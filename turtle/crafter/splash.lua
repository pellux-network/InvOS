local M = {}

-- Runs once, before the crafter's receive loop in startup.lua, so a cold boot gets the same
-- brief animated brand moment the controller gets. Adapted from controller/storage/app/splash.lua
-- rather than shared: see theme.lua for why the turtle tree cannot require controller files.
--
-- Unlike the controller's splash, this one has real boot facts to show -- computer id, label,
-- and which side the modem opened on -- so the tagline is followed by an identity line instead
-- of standing alone.

local Draw = require("crafter.draw")
local Theme = require("crafter.theme")

local WORD = "INVOS"
local TAGLINE = "CRAFTING TURTLE"
local GLYPH_WIDTH = 5
local WORDMARK_HEIGHT = 5
local WORDMARK_WIDTH = GLYPH_WIDTH * #WORD + (#WORD - 1)

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
-- `edgeFrom` onward in the accent. Each frame clears first, so this only ever draws.
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

local function identityLine(info)
    if type(info) ~= "table" then return nil end
    local parts = {}
    if info.id ~= nil then parts[#parts + 1] = "#" .. tostring(info.id) end
    if info.label then parts[#parts + 1] = tostring(info.label) end
    if info.side then parts[#parts + 1] = "modem:" .. tostring(info.side) end
    if #parts == 0 then return nil end
    return table.concat(parts, "  \183  ")
end

-- Wipes the wordmark in behind a brighter leading edge, pulses once when it lands, sweeps a
-- meter to signal the handoff, then names this specific turtle. One pulse, not a loop: a
-- looping splash reads as a hang rather than as a boot.
local function playWordmark(surface, sleepFn, width, height, info)
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

    local identity = identityLine(info)
    if identity and barY + 1 <= height then
        Draw.centerText(surface, math.floor(width / 2) + 1, barY + 1,
            identity, Theme.role.info, Theme.role.ground)
    end
    sleepFn(0.35)
end

-- A screen too small for the block wordmark gets a single centered line instead. Every
-- deployed turtle screen is 39x13, well above this floor, but nothing should crash on less.
local function playCompact(surface, sleepFn, width, height, info)
    local top = math.max(1, math.floor(height / 2) - 1)
    local center = math.floor(width / 2) + 1
    Draw.centerText(surface, center, top, "InvOS", Theme.role.brand, Theme.role.ground)
    local row = top
    if row + 1 <= height then
        row = row + 1
        Draw.centerText(surface, center, row, "CRAFTER", Theme.role.muted, Theme.role.ground)
    end
    local identity = identityLine(info)
    if identity and row + 1 <= height then
        Draw.centerText(surface, center, row + 1, identity, Theme.role.info, Theme.role.ground)
    end
    sleepFn(1.5)
end

function M.play(surface, sleepFn, info)
    sleepFn = sleepFn or sleep
    Theme.apply(surface)
    local width, height = surface.getSize()
    clear(surface)
    if width >= WORDMARK_WIDTH + 2 and height >= WORDMARK_HEIGHT + 5 then
        playWordmark(surface, sleepFn, width, height, info)
    else
        playCompact(surface, sleepFn, width, height, info)
    end
end

return M
