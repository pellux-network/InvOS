local M = {}

-- A separate module from app/monitor.lua rather than a fourth size tier in it, because
-- this renders a different model -- the active craft job -- not a smaller view of the
-- storage model.
--
-- monitor_0 is a 1x1 monitor: 7x5 characters at text scale 1, 15x10 at scale 0.5. The
-- design targets 0.5, and degrades to a two-line summary if it is left at scale 1.

local Draw = require("app.draw")
local Theme = require("app.theme")

-- This module has its own state vocabulary -- STAGING, CONFIRMING, DELIVERING -- that the
-- storage lifecycle does not share, so it keeps its own mapping rather than using
-- Theme.statusColor. The colours themselves are the shared roles.
local function colorFor(state)
    if state=="COMPLETE" then return Theme.role.ok end
    if state=="BLOCKED" or state=="CONFIRMING" then return Theme.role.warn end
    if state=="FAILED" or state=="CANCELLED" then return Theme.role.alert end
    if state=="IDLE" then return Theme.role.muted end
    return Theme.role.working
end

local function write(surface,width,height,x,y,text,color)
    Draw.text(surface,x,y,text,math.max(0,width-x+1),color or Theme.role.text,Theme.role.ground)
end

-- Trim from the left of a namespaced ID so the meaningful part survives a narrow screen:
-- "minecraft:oak_planks" reads better clipped to "oak_planks" than to "minecraft:oak".
local function shortName(value,width)
    local text=tostring(value or "")
    local stripped=text:match("^[%w_]+:(.+)$") or text
    if #stripped<=width then return stripped end
    return stripped:sub(1,width)
end

local function renderTiny(surface,model,width,height)
    local active=model.active
    write(surface,width,height,1,1,"CRAFT",Theme.role.text)
    if not active then
        write(surface,width,height,1,2,"IDLE",Theme.role.muted)
        return
    end
    write(surface,width,height,1,2,shortName(active.display_name or active.item,width),Theme.role.text)
    write(surface,width,height,1,3,tostring(active.state),colorFor(active.state))
end

local function renderFull(surface,model,width,height)
    local active=model.active
    if not active then
        write(surface,width,height,1,1,"CRAFTING",Theme.role.text)
        write(surface,width,height,1,3,"IDLE",Theme.role.muted)
        if model.craftable_types then
            write(surface,width,height,1,5,tostring(model.craftable_types),Theme.role.focus)
            write(surface,width,height,1,6,"recipes",Theme.role.muted)
        end
        return
    end

    write(surface,width,height,1,1,"CRAFTING",Theme.role.text)
    write(surface,width,height,1,2,shortName(active.display_name or active.item,width),Theme.role.text)
    write(surface,width,height,1,3,tostring(active.produced or 0).." / "..tostring(active.quantity or 0),
        Theme.role.focus)

    local row=4
    if active.steps and active.steps>0 then
        write(surface,width,height,1,row,"STEP "..tostring(active.step or 1).."/"..tostring(active.steps),
            Theme.role.muted)
        row=row+1
        Draw.meter(surface,1,row,math.max(1,width-1),
            ((active.step or 1)-1)/active.steps,Theme.role.craft,Theme.role.track)
        row=row+1
    end
    if active.current_item then
        write(surface,width,height,1,row,shortName(active.current_item,width),Theme.role.muted)
        row=row+1
    end
    write(surface,width,height,1,row,tostring(active.state),colorFor(active.state))
    row=row+1

    -- Omitted entirely when nothing is waiting. On a 15x10 surface every line counts.
    if (model.queued or 0)>0 then
        write(surface,width,height,1,row,"+"..tostring(model.queued).." queued",Theme.role.muted)
        row=row+1
    end
    if active.state=="BLOCKED" and active.reason then
        write(surface,width,height,1,height,shortName(active.reason,width),Theme.role.focus)
    end
end

local function frame(surface,model)
    local width,height=surface.getSize()
    surface.setBackgroundColor(Theme.role.ground)
    surface.setTextColor(Theme.role.text)
    surface.clear()
    if width<12 or height<6 then renderTiny(surface,model,width,height)
    else renderFull(surface,model,width,height) end
    surface.setBackgroundColor(Theme.role.ground)
    surface.setTextColor(Theme.role.text)
    surface.setCursorBlink(false)
end

-- Single entry and exit, so a frame begun is always ended even when a renderer returns early
-- or throws. See UI:render.
function M.render(surface,model)
    if surface.beginFrame then surface.beginFrame() end
    local ok,reason=pcall(frame,surface,model or {})
    if surface.endFrame then surface.endFrame() end
    if not ok then error(reason,0) end
end

return M
