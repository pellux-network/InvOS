local M = {}

-- The detail pane appears far earlier than the old wide layout did: the approved design shows
-- one on the 51-column terminal, so 72 no longer gates whether the pane exists, only whether
-- it is generous.
M.SPLIT_MIN = 40
M.WIDE = 72

-- Below this the bottom meter strip is dropped. It is a luxury, and a screen this small needs
-- its rows for content.
M.STRIP_MIN_HEIGHT = 12

-- One description of the screen that every page and both monitors share, so pages cannot
-- disagree about where the chrome is. `content` is the band a page carves its own rows from.
function M.regions(width, height)
    local strip = height >= M.STRIP_MIN_HEIGHT and (height - 2) or nil
    local footer = height - 1
    local contentBottom = (strip or footer) - 1
    return {
        width = width,
        height = height,
        wide = width >= M.WIDE,
        header = 1,
        nav = 2,
        content = { top = 3, bottom = math.max(2, contentBottom) },
        split = width >= M.SPLIT_MIN and math.floor(width * 0.57) or nil,
        strip = strip,
        footer = footer,
        status = height,
    }
end

return M
