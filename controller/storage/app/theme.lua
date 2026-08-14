local M = {}

-- CC exposes `colors` as a global; the fallback keeps this module loadable on the host, where
-- the tests run with no CC environment at all. Exported as M.palette because tests need to
-- resolve a slot name to a value and cannot reach the global to do it.
local palette = colors or {
    white=1, orange=2, magenta=4, lightBlue=8, yellow=16, lime=32,
    pink=64, gray=128, lightGray=256, cyan=512, purple=1024, blue=2048,
    brown=4096, green=8192, red=16384, black=32768,
}
M.palette = palette

-- What InvOS installs over the stock palette. Built outward from the three wordmark colours
-- in docs/assets/wordmark.svg: crimson #B91C2E, coral #FF5F5F, cool grey #8A8F98.
-- `brown` is deliberately absent: nothing needs it, and claiming a slot with no use for it
-- only makes a later decision harder.
M.slots = {
    black     = 0x0B0C10,
    gray      = 0x1C1F26,
    blue      = 0x2A3441,
    lightGray = 0x8A8F98,
    white     = 0xE8E9EC,
    red       = 0xB91C2E,
    pink      = 0xFF5F5F,
    orange    = 0xE8833A,
    yellow    = 0xE5B33A,
    lime      = 0x4FB477,
    green     = 0x2E7D52,
    lightBlue = 0x6FC3DE,
    cyan      = 0x3E9BB5,
    purple    = 0x6E5AA8,
    magenta   = 0xE0454F,
}

-- The stock CC:Tweaked values. Restoring is not optional: setPaletteColour changes the
-- terminal, not the program, so an InvOS that exits without putting these back leaves the
-- player's shell in InvOS colours until the computer reboots.
M.defaults = {
    white=0xF0F0F0, orange=0xF2B233, magenta=0xE57FD8, lightBlue=0x99B2F2,
    yellow=0xDEDE6C, lime=0x7FCC19, pink=0xF2B2CC, gray=0x4C4C4C,
    lightGray=0x999999, cyan=0x4C99B2, purple=0xB266E5, blue=0x3366CC,
    brown=0x7F664C, green=0x57A64E, red=0xCC4C4C, black=0x111111,
}

-- Screens name a role, never a slot, so that changing what selection looks like is one edit
-- here rather than a search across five renderers.
M.role = {
    ground  = palette.black,
    panel   = palette.gray,
    track   = palette.blue,
    muted   = palette.lightGray,
    ghost   = palette.lightGray,
    text    = palette.white,
    brand   = palette.red,
    focus   = palette.pink,
    working = palette.orange,
    warn    = palette.yellow,
    ok      = palette.lime,
    okDim   = palette.green,
    info    = palette.lightBlue,
    infoDim = palette.cyan,
    craft   = palette.purple,
    alert   = palette.magenta,
}

-- CC spells this both ways depending on version; a monitor that has neither is a basic
-- monitor, which has no palette at all and must render in stock colours rather than error.
local function writeAll(surface, values)
    if type(surface) ~= "table" then return false end
    local set = surface.setPaletteColour or surface.setPaletteColor
    if type(set) ~= "function" then return false end
    for name, value in pairs(values) do
        local slot = palette[name]
        if slot then pcall(set, slot, value) end
    end
    return true
end

function M.apply(surface) return writeAll(surface, M.slots) end
function M.restore(surface) return writeAll(surface, M.defaults) end

-- The single implementation of a mapping that exists three times today, in ui.lua,
-- monitor.lua and craft_monitor.lua. Failure uses `alert`, never `brand`: brand red is
-- chrome and must never signal state.
function M.statusColor(state)
    if state == "READY" or state == "COMPLETE" then return M.role.ok end
    if state == "DEGRADED" or state == "BLOCKED" or state == "PARTIAL" then return M.role.warn end
    if state == "ERROR" or state == "FAILED" or state == "OFFLINE" then return M.role.alert end
    return M.role.working
end

return M
