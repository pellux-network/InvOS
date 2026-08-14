local M = {}

-- A separate module from app/monitor.lua rather than a fourth size tier in it, because
-- this renders a different model -- the active craft job -- not a smaller view of the
-- storage model.
--
-- Three tiers: a 7x5 unscaled monitor gets a bare two-line summary; a 1x1 monitor at scale
-- 0.5 (15x10) is the design target; a 2x2-or-bigger array gets the large tier below, in the
-- same panelled language monitor.lua uses -- a header band rather than text painted onto
-- the bare background.

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

-- Set false at the top of every frame and raised by any write that actually scrolls; M.render
-- reports it back so the coordinator only keeps asking for animation frames while something
-- on this monitor is genuinely too long for its column. Module-local rather than threaded
-- through every render* function -- CC is single-threaded, so one frame always finishes
-- before the next starts. See app/monitor.lua, which does the same.
local animating = false

local function write(surface,width,height,x,y,text,color,now)
    if Draw.marqueeText(surface,x,y,text,math.max(0,width-x+1),
        color or Theme.role.text,Theme.role.ground,now) then
        animating=true
    end
end

-- Trim from the left of a namespaced ID so the meaningful part survives a narrow screen:
-- "minecraft:oak_planks" reads better as "oak_planks" than as "minecraft:oak". Width-clipping
-- used to happen here too, but that raced Draw.marqueeText's own clipping and defeated
-- scrolling -- this only ever trims the namespace now.
local function shortName(value)
    local text=tostring(value or "")
    return text:match("^[%w_]+:(.+)$") or text
end

-- Five-row block glyphs are six columns wide per character (five painted, one gap), so the
-- painted width is known before drawing -- the same measure-first move monitor.lua makes
-- before it paints its item total, and for the same reason: a wider count must not run off
-- the right edge of a narrower monitor than the one this was designed against.
local function blockWidth(text) return #text*6-1 end

-- The header every other InvOS screen uses -- a panel band rather than text on the bare
-- background -- shared by the full and large tiers. The tiny tier skips it: at 7x5 there is
-- no row to spare for a band that says nothing the two lines beneath it don't already say.
local function header(surface,width,state)
    Draw.band(surface,1,Theme.role.panel)
    Draw.text(surface,2,1,"CRAFTING",math.max(0,width-2),Theme.role.brand,Theme.role.panel)
    if state and width>=18 then
        Draw.rightText(surface,width-1,1,tostring(state),colorFor(state),Theme.role.panel)
    end
end

local function renderTiny(surface,model,width,height)
    local active=model.active
    write(surface,width,height,1,1,"CRAFT",Theme.role.brand,model.now)
    if not active then
        write(surface,width,height,1,2,"IDLE",Theme.role.muted,model.now)
        return
    end
    write(surface,width,height,1,2,shortName(active.display_name or active.item),Theme.role.text,model.now)
    write(surface,width,height,1,3,tostring(active.state),colorFor(active.state),model.now)
end

local function renderFull(surface,model,width,height)
    local active=model.active
    header(surface,width,active and active.state or nil)
    if not active then
        write(surface,width,height,1,3,"IDLE",Theme.role.muted,model.now)
        if model.craftable_types then
            write(surface,width,height,1,5,tostring(model.craftable_types),Theme.role.focus,model.now)
            write(surface,width,height,1,6,"recipes",Theme.role.muted,model.now)
        end
        return
    end

    write(surface,width,height,1,2,shortName(active.display_name or active.item),Theme.role.text,model.now)
    write(surface,width,height,1,3,tostring(active.produced or 0).." / "..tostring(active.quantity or 0),
        Theme.role.focus,model.now)

    local row=4
    if active.steps and active.steps>0 then
        write(surface,width,height,1,row,"STEP "..tostring(active.step or 1).."/"..tostring(active.steps),
            Theme.role.muted,model.now)
        row=row+1
        Draw.meter(surface,1,row,math.max(1,width-1),
            ((active.step or 1)-1)/active.steps,Theme.role.craft,Theme.role.track)
        row=row+1
    end
    if active.current_item then
        write(surface,width,height,1,row,shortName(active.current_item),Theme.role.muted,model.now)
        row=row+1
    end
    write(surface,width,height,1,row,tostring(active.state),colorFor(active.state),model.now)
    row=row+1

    -- Omitted entirely when nothing is waiting. On a 15x10 surface every line counts.
    if (model.queued or 0)>0 then
        write(surface,width,height,1,row,"+"..tostring(model.queued).." queued",Theme.role.muted,model.now)
        row=row+1
    end
    if active.state=="BLOCKED" and active.reason then
        write(surface,width,height,1,height,shortName(active.reason),Theme.role.focus,model.now)
    end
end

-- The large tier: a 2x2-or-bigger monitor array has room to show the job the way the wall
-- monitor shows a delivery -- name, a metered fraction with its percent, and the craft-specific
-- detail (step, staged ingredient) that has no equivalent there. Idle gets the same "readable
-- from a distance" treatment the wall monitor gives its item total, rather than small text
-- lost in a mostly empty screen.
local function renderLarge(surface,model,width,height)
    local active=model.active
    header(surface,width,active and active.state or nil)
    if not active then
        local count=tostring(model.craftable_types or 0)
        if height>=9 and blockWidth(count)+4<=width-2 then
            Draw.blockText(surface,3,3,count,Theme.role.focus)
            -- Row 8 stays clear, same as the wall monitor's item total: the glyphs run 3 to 7
            -- and their descenders touch a caption placed directly beneath them.
            Draw.text(surface,3,9,"RECIPES AVAILABLE",width-4,Theme.role.muted,Theme.role.ground)
        else
            Draw.text(surface,2,3,count.." RECIPES AVAILABLE",width-2,
                Theme.role.focus,Theme.role.ground)
        end
        return
    end

    if Draw.marqueeText(surface,2,3,shortName(active.display_name or active.item),width-3,
        Theme.role.text,Theme.role.ground,model.now) then
        animating=true
    end

    local produced,quantity=active.produced or 0,active.quantity or 0
    Draw.text(surface,2,5,tostring(produced).." / "..tostring(quantity),width-2,
        Theme.role.focus,Theme.role.ground)
    local fraction=quantity>0 and math.max(0,math.min(1,produced/quantity)) or 0
    local percent=tostring(math.floor(fraction*100+0.5)).."%"
    local meterWidth=math.max(1,width-4-#percent)
    Draw.meter(surface,2,6,meterWidth,fraction,Theme.role.craft,Theme.role.track)
    Draw.rightText(surface,width-1,6,percent,Theme.role.muted,Theme.role.ground)

    local row=8
    if active.steps and active.steps>0 then
        Draw.text(surface,2,row,"STEP "..tostring(active.step or 1).."/"..tostring(active.steps),
            width-2,Theme.role.muted,Theme.role.ground)
        row=row+1
        Draw.meter(surface,2,row,math.max(1,width-3),
            ((active.step or 1)-1)/active.steps,Theme.role.craft,Theme.role.track)
        row=row+1
    end
    if active.current_item then
        -- "Staging " stays put -- only the name after it scrolls -- rather than folding the
        -- prefix into one marqueed string, which would carry "Staging " off-screen with it.
        local prefix="Staging "
        Draw.text(surface,2,row,prefix,#prefix,Theme.role.muted,Theme.role.ground)
        if Draw.marqueeText(surface,2+#prefix,row,shortName(active.current_item),
            math.max(1,width-2-#prefix),Theme.role.muted,Theme.role.ground,model.now) then
            animating=true
        end
        row=row+1
    end

    -- Follows the content directly with a one-row gap rather than pinning to the last row of
    -- the surface: on a tall monitor that would strand it below a wide band of empty space,
    -- looking unfinished rather than spacious.
    if active.state=="BLOCKED" and active.reason then
        row=row+1
        if Draw.marqueeText(surface,2,row,shortName(active.reason),width-2,
            Theme.role.warn,Theme.role.ground,model.now) then
            animating=true
        end
        row=row+1
    end
    if (model.queued or 0)>0 then
        row=row+1
        Draw.text(surface,2,row,"+"..tostring(model.queued).." queued",width-2,
            Theme.role.muted,Theme.role.ground)
    end
end

local function frame(surface,model)
    animating=false
    local width,height=surface.getSize()
    surface.setBackgroundColor(Theme.role.ground)
    surface.setTextColor(Theme.role.text)
    surface.clear()
    if width<12 or height<6 then renderTiny(surface,model,width,height)
    elseif width<30 or height<14 then renderFull(surface,model,width,height)
    else renderLarge(surface,model,width,height) end
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
    return animating
end

return M
