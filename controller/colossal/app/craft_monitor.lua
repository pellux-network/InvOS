local M = {}

-- A separate module from app/monitor.lua rather than a fourth size tier in it, because
-- this renders a different model -- the active craft job -- not a smaller view of the
-- storage model.
--
-- monitor_0 is a 1x1 monitor: 7x5 characters at text scale 1, 15x10 at scale 0.5. The
-- design targets 0.5, and degrades to a two-line summary if it is left at scale 1.

local palette = colors or {
    white=1, yellow=16, lime=32, gray=128, lightGray=256, cyan=512,
    red=16384, black=32768,
}

local function colorFor(state)
    if state=="COMPLETE" then return palette.lime end
    if state=="BLOCKED" or state=="CONFIRMING" then return palette.yellow end
    if state=="FAILED" or state=="CANCELLED" then return palette.red end
    if state=="IDLE" then return palette.lightGray end
    return palette.cyan
end

local function write(surface,width,height,x,y,text,color)
    if y<1 or y>height or x<1 or x>width then return end
    text=tostring(text or ""):sub(1,width-x+1)
    if #text==0 then return end
    surface.setTextColor(color or palette.white)
    surface.setCursorPos(x,y)
    surface.write(text)
end

-- Trim from the left of a namespaced ID so the meaningful part survives a narrow screen:
-- "minecraft:oak_planks" reads better clipped to "oak_planks" than to "minecraft:oak".
local function shortName(value,width)
    local text=tostring(value or "")
    local stripped=text:match("^[%w_]+:(.+)$") or text
    if #stripped<=width then return stripped end
    return stripped:sub(1,width)
end

local function bar(width,done,total)
    if not total or total<1 then return nil end
    local inner=math.max(1,width-2)
    local filled=math.floor(inner*math.max(0,math.min(done,total))/total)
    return "["..string.rep("#",filled)..string.rep(" ",inner-filled).."]"
end

local function renderTiny(surface,model,width,height)
    local active=model.active
    write(surface,width,height,1,1,"CRAFT",palette.white)
    if not active then
        write(surface,width,height,1,2,"IDLE",palette.lightGray)
        return
    end
    write(surface,width,height,1,2,shortName(active.display_name or active.item,width),palette.white)
    write(surface,width,height,1,3,tostring(active.state),colorFor(active.state))
end

local function renderFull(surface,model,width,height)
    local active=model.active
    if not active then
        write(surface,width,height,1,1,"CRAFTING",palette.white)
        write(surface,width,height,1,3,"IDLE",palette.lightGray)
        if model.craftable_types then
            write(surface,width,height,1,5,tostring(model.craftable_types),palette.cyan)
            write(surface,width,height,1,6,"recipes",palette.lightGray)
        end
        return
    end

    write(surface,width,height,1,1,"CRAFTING",palette.white)
    write(surface,width,height,1,2,shortName(active.display_name or active.item,width),palette.white)
    write(surface,width,height,1,3,tostring(active.produced or 0).." / "..tostring(active.quantity or 0),
        palette.cyan)

    local row=4
    if active.steps and active.steps>0 then
        write(surface,width,height,1,row,"STEP "..tostring(active.step or 1).."/"..tostring(active.steps),
            palette.lightGray)
        row=row+1
        local drawn=bar(width,(active.step or 1)-1,active.steps)
        if drawn then write(surface,width,height,1,row,drawn,palette.cyan); row=row+1 end
    end
    if active.current_item then
        write(surface,width,height,1,row,shortName(active.current_item,width),palette.lightGray)
        row=row+1
    end
    write(surface,width,height,1,row,tostring(active.state),colorFor(active.state))
    row=row+1

    -- Omitted entirely when nothing is waiting. On a 15x10 surface every line counts.
    if (model.queued or 0)>0 then
        write(surface,width,height,1,row,"+"..tostring(model.queued).." queued",palette.lightGray)
        row=row+1
    end
    if active.state=="BLOCKED" and active.reason then
        write(surface,width,height,1,height,shortName(active.reason,width),palette.red)
    end
end

function M.render(surface,model)
    model=model or {}
    local width,height=surface.getSize()
    surface.setBackgroundColor(palette.black)
    surface.setTextColor(palette.white)
    surface.clear()
    if width<12 or height<6 then renderTiny(surface,model,width,height)
    else renderFull(surface,model,width,height) end
    surface.setBackgroundColor(palette.black)
    surface.setTextColor(palette.white)
    surface.setCursorBlink(false)
end

return M
