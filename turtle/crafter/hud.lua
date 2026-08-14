local M = {}

-- The turtle's own status screen, shown between jobs and live during one. It renders a
-- `status` table that startup.lua owns and updates from executor notify events -- this
-- module never touches rednet, turtle, or executor state directly, so it can be rendered
-- and tested as a pure function of (surface, status).
--
-- Modeled on controller/storage/app/craft_monitor.lua's shape (colour-coded state word,
-- a progress meter, a trimmed item name) but this is the turtle's only screen rather than
-- one tier among several, so it gets the turtle's full 39x13 rather than a monitor tile.

local Draw = require("crafter.draw")
local Theme = require("crafter.theme")

local function write(surface, width, x, y, text, color)
    Draw.text(surface, x, y, text, math.max(0, width - x + 1), color or Theme.role.text, Theme.role.ground)
end

-- Trim from the left of a namespaced ID so the meaningful part survives a narrow screen:
-- "minecraft:oak_planks" reads better clipped to "oak_planks" than to "minecraft:oak".
local function shortName(value, width)
    local text = tostring(value or "")
    local stripped = text:match("^[%w_]+:(.+)$") or text
    if #stripped <= width then return stripped end
    return stripped:sub(1, width)
end

local function formatUptime(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    if hours > 0 then return string.format("%d:%02d:%02d", hours, minutes, secs) end
    return string.format("%d:%02d", minutes, secs)
end

local function renderTiny(surface, status, width, height)
    write(surface, width, 1, 1, "CRAFTER", Theme.role.text)
    local state = status.state or "IDLE"
    write(surface, width, 1, 2, state, Theme.statusColor(state))
    if status.job and height >= 3 then
        write(surface, width, 1, 3, shortName(status.job.item, width), Theme.role.muted)
    elseif status.last and height >= 3 then
        local color = status.last.ok and Theme.role.ok or Theme.role.alert
        write(surface, width, 1, 3, shortName(status.last.item, width), color)
    end
end

local function header(surface, width, status)
    write(surface, width, 1, 1, "CRAFTER", Theme.role.text)
    local id = status.id ~= nil and ("#" .. tostring(status.id)) or nil
    local label = status.label and tostring(status.label) or nil
    local right = id and label and (id .. " " .. label) or (label or id)
    if right then Draw.rightText(surface, width, 1, right, Theme.role.muted, Theme.role.ground) end
    Draw.band(surface, 2, Theme.role.panel, 1, width)
end

-- A full-width banner rather than a plain line: the state is the one thing an operator
-- glancing at the turtle needs fastest, so it gets the loudest treatment on the screen.
local function banner(surface, width, y, state)
    local color = Theme.statusColor(state)
    Draw.band(surface, y, color, 1, width)
    Draw.centerText(surface, math.floor(width / 2) + 1, y, state, Theme.role.ground, color)
end

local function renderJob(surface, width, y, job)
    local label = shortName(job.item or "?", width)
    if job.quantity and job.quantity > 0 then label = label .. "  x" .. tostring(job.quantity) end
    write(surface, width, 1, y, label, Theme.role.text)
    y = y + 1
    if job.total and job.total > 0 then
        local barWidth = math.max(1, width)
        Draw.meter(surface, 1, y, barWidth, (job.filled or 0) / job.total,
            Theme.role.craft, Theme.role.track)
        y = y + 1
        write(surface, width, 1, y,
            tostring(job.filled or 0) .. " / " .. tostring(job.total) .. " ingredients staged",
            Theme.role.muted)
        y = y + 1
    end
    return y
end

local function renderIdle(surface, width, y, status)
    write(surface, width, 1, y, "UPTIME " .. formatUptime(status.now), Theme.role.muted)
    y = y + 1
    write(surface, width, 1, y, "JOBS COMPLETE " .. tostring(status.jobs_done or 0), Theme.role.muted)
    y = y + 1
    return y
end

local function renderLast(surface, width, y, last)
    if not last then return y end
    local color = last.ok and Theme.role.ok or Theme.role.alert
    local mark = last.ok and "OK   " or "FAIL "
    local detail = last.ok and shortName(last.item, width - #mark)
        or shortName(last.message or last.code or "unknown error", width - #mark)
    write(surface, width, 1, y, mark .. detail, color)
    return y + 1
end

local function renderFull(surface, width, height, status)
    header(surface, width, status)
    local state = status.state or "IDLE"
    banner(surface, width, 4, state)

    local y = 6
    if status.job then
        y = renderJob(surface, width, y, status.job)
    else
        y = renderIdle(surface, width, y, status)
    end
    y = y + 1
    if y <= height then y = renderLast(surface, width, y, status.last) end

    if y <= height and not status.job then
        write(surface, width, 1, height, "listening for jobs", Theme.role.muted)
    end
end

local function frame(surface, status)
    local width, height = surface.getSize()
    surface.setBackgroundColor(Theme.role.ground)
    surface.setTextColor(Theme.role.text)
    surface.clear()
    if width < 20 or height < 8 then
        renderTiny(surface, status, width, height)
    else
        renderFull(surface, width, height, status)
    end
    surface.setBackgroundColor(Theme.role.ground)
    surface.setTextColor(Theme.role.text)
    if surface.setCursorBlink then surface.setCursorBlink(false) end
end

-- Single entry and exit, so a frame begun is always ended even when a renderer returns
-- early or throws -- see app/craft_monitor.lua's M.render for the same reasoning.
function M.render(surface, status)
    if surface.beginFrame then surface.beginFrame() end
    local ok, reason = pcall(frame, surface, status or {})
    if surface.endFrame then surface.endFrame() end
    if not ok then error(reason, 0) end
end

return M
