local Draw = require("app.draw")
local T = require("tests.mock_cc")

local function surfaceOf(width, height) return T.recordingSurface(width, height) end

-- How many cells of row `y` carry `color` as their background.
local function filled(surface, y, color, width)
    local count = 0
    for x = 1, width do
        if surface.backgroundAt(x, y) == color then count = count + 1 end
    end
    return count
end

local FILL, TRACK = 32, 2048

return {
    { name = "text clips at every edge instead of writing outside the surface", run = function()
        local surface = surfaceOf(10, 4)
        Draw.text(surface, 8, 2, "overlong", 20)
        Draw.text(surface, -3, 3, "negative start", 20)
        Draw.text(surface, 1, 99, "below", 10)
        Draw.text(surface, 1, -1, "above", 10)
        Draw.text(surface, 99, 1, "right", 10)
        T.equal(surface.writesOutsideBounds(), 0)
        T.equal(surface.line(2), "       ove")
    end },
    { name = "rightText ends on the column it is given", run = function()
        local surface = surfaceOf(20, 3)
        Draw.rightText(surface, 19, 1, "1,284")
        T.equal(surface.line(1), "              1,284 ")
    end },
    { name = "centerText centres on the column it is given", run = function()
        local surface = surfaceOf(21, 3)
        Draw.centerText(surface, 11, 1, "INVOS")
        -- 5 characters centred on column 11 occupy 9 through 13. monitor.lua's existing
        -- helper floors to 8 and sits one column left of centre; this one rounds.
        T.equal(surface.line(1):find("INVOS", 1, true), 9)
    end },
    { name = "band fills a whole row, or the segment it is given", run = function()
        local surface = surfaceOf(12, 3)
        Draw.band(surface, 1, FILL)
        T.equal(filled(surface, 1, FILL, 12), 12)
        Draw.band(surface, 2, FILL, 4, 6)
        T.equal(filled(surface, 2, FILL, 12), 3)
    end },
    { name = "band and divider refuse rows and columns outside the surface", run = function()
        local surface = surfaceOf(12, 3)
        Draw.band(surface, 0, FILL)
        Draw.band(surface, 9, FILL)
        Draw.band(surface, 1, FILL, 10, 40)
        Draw.divider(surface, 6, 1, 99, FILL)
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "a meter fills whole cells in proportion to its fraction", run = function()
        local surface = surfaceOf(20, 6)
        Draw.meter(surface, 1, 1, 10, 0, FILL, TRACK)
        T.equal(filled(surface, 1, FILL, 20), 0)
        Draw.meter(surface, 1, 2, 10, 0.5, FILL, TRACK)
        T.equal(filled(surface, 2, FILL, 20), 5)
        Draw.meter(surface, 1, 3, 10, 1, FILL, TRACK)
        T.equal(filled(surface, 3, FILL, 20), 10)
        T.equal(filled(surface, 3, TRACK, 20), 0)
    end },
    { name = "a meter clamps a fraction outside zero to one", run = function()
        local surface = surfaceOf(20, 4)
        Draw.meter(surface, 1, 1, 10, -3, FILL, TRACK)
        T.equal(filled(surface, 1, FILL, 20), 0)
        Draw.meter(surface, 1, 2, 10, 7, FILL, TRACK)
        T.equal(filled(surface, 2, FILL, 20), 10)
        Draw.meter(surface, 1, 3, 10, nil, FILL, TRACK)
        T.equal(filled(surface, 3, FILL, 20), 0)
    end },
    { name = "a half-full cell continues the run instead of leaving a gap", run = function()
        local surface = surfaceOf(20, 3)
        Draw.meter(surface, 1, 1, 10, 0.55, FILL, TRACK)
        T.equal(surface.line(1):sub(6, 6), string.char(Draw.HALF), "cell six must be the half")
        -- Character 149 lights its FOREGROUND on the left half of the cell. Passing the fill
        -- as the background instead put it on the right, which left a one-cell dark gap
        -- between the solid run and the partial cell -- visible in world as a floating
        -- sliver. The foreground is the assertion that catches it; the background cannot.
        T.equal(surface.foregroundAt(6, 1), FILL, "the lit half must continue the solid run")
        T.equal(surface.backgroundAt(6, 1), TRACK)
        T.equal(filled(surface, 1, FILL, 20), 5, "five whole cells; the half is not a fill")
        T.equal(filled(surface, 1, TRACK, 20), 5)
    end },
    { name = "subpixel off rounds to whole cells and draws no partial character", run = function()
        local surface = surfaceOf(20, 3)
        Draw.subpixel = false
        Draw.meter(surface, 1, 1, 10, 0.55, FILL, TRACK)
        Draw.subpixel = true
        T.equal(filled(surface, 1, FILL, 20), 6, "0.55 rounds up to six whole cells")
        T.equal(surface.line(1):find(string.char(Draw.HALF), 1, true), nil)
    end },
    { name = "a meter never draws outside the surface", run = function()
        local surface = surfaceOf(8, 3)
        Draw.meter(surface, 5, 1, 20, 0.75, FILL, TRACK)
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "blockText draws five-row glyphs and reports where it ended", run = function()
        local surface = surfaceOf(30, 7)
        local nextX = Draw.blockText(surface, 1, 1, "10", FILL)
        T.equal(nextX, 13, "two glyphs, each five wide with a one-column gap")
        T.equal(filled(surface, 3, FILL, 30) > 0, true)
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "blockText covers every digit and the wordmark letters", run = function()
        for character in ("0123456789,INVOS"):gmatch(".") do
            T.equal(Draw.glyphs[character] ~= nil, true, "no glyph for " .. character)
            T.equal(#Draw.glyphs[character], 5, character .. " must have five rows")
            for _, row in ipairs(Draw.glyphs[character]) do
                T.equal(#row, 5, character .. " rows must be five columns wide")
            end
        end
    end },
    { name = "blockText clips rather than drawing past the edge", run = function()
        local surface = surfaceOf(8, 4)
        Draw.blockText(surface, 6, 3, "148,302", FILL)
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "marqueeText draws text that fits exactly like a plain clipped write", run = function()
        local surface = surfaceOf(20, 3)
        local scrolling = Draw.marqueeText(surface, 1, 1, "short", 10, nil, nil, 999999)
        T.equal(scrolling, false)
        T.equal(surface.line(1):sub(1, 10), "short     ")
    end },
    { name = "marqueeText holds on the first `width` columns at now = 0", run = function()
        local surface = surfaceOf(20, 3)
        local scrolling = Draw.marqueeText(surface, 1, 1, "ABCDEFGH", 5, nil, nil, 0)
        T.equal(scrolling, true)
        T.equal(surface.line(1):sub(1, 5), "ABCDE")
    end },
    { name = "marqueeText with no `now` behaves like a static clipped write", run = function()
        local surface = surfaceOf(20, 3)
        Draw.marqueeText(surface, 1, 1, "ABCDEFGH", 5)
        T.equal(surface.line(1):sub(1, 5), "ABCDE")
    end },
    { name = "marqueeText scrolls one column per step and holds at the far end", run = function()
        local surface = surfaceOf(20, 3)
        local overflow = #"ABCDEFGH" - 5
        local hold, step = Draw.MARQUEE_HOLD_STEPS, Draw.MARQUEE_STEP_MS
        -- One step in: still the same first column the hold has not finished yet.
        Draw.marqueeText(surface, 1, 1, "ABCDEFGH", 5, nil, nil, step)
        T.equal(surface.line(1):sub(1, 5), "ABCDE")
        -- Just past the hold: the window has started sliding right by one column.
        Draw.marqueeText(surface, 1, 2, "ABCDEFGH", 5, nil, nil, (hold + 1) * step)
        T.equal(surface.line(2):sub(1, 5), "BCDEF")
        -- Long past the hold and the slide: parked on the last `width` columns.
        Draw.marqueeText(surface, 1, 3, "ABCDEFGH", 5, nil, nil, (hold + overflow) * step)
        T.equal(surface.line(3):sub(1, 5), "DEFGH")
    end },
    { name = "marqueeText's offset is periodic: a full span returns to the start", run = function()
        local surface = surfaceOf(20, 3)
        local overflow = #"ABCDEFGH" - 5
        local hold, step = Draw.MARQUEE_HOLD_STEPS, Draw.MARQUEE_STEP_MS
        local span = (hold * 2 + overflow * 2) * step
        Draw.marqueeText(surface, 1, 1, "ABCDEFGH", 5, nil, nil, span)
        T.equal(surface.line(1):sub(1, 5), "ABCDE")
        Draw.marqueeText(surface, 1, 2, "ABCDEFGH", 5, nil, nil, span * 3 + (hold + 1) * step)
        T.equal(surface.line(2):sub(1, 5), "BCDEF")
    end },
}
