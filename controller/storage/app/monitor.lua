local M = {}

local Draw = require("app.draw")
local Theme = require("app.theme")

local function formatNumber(value)
    local text=tostring(math.floor(tonumber(value) or 0))
    while true do local changed; text,changed=text:gsub("^(%-?%d+)(%d%d%d)","%1,%2"); if changed==0 then break end end
    return text
end

local function enrichmentText(enrichment)
    if not enrichment then return nil end
    return "Learning item names: "..formatNumber(enrichment.learned).."/"..formatNumber(enrichment.total)
end

-- Trim from the left of a namespaced id so the meaningful part survives a narrow column:
-- "ironchests:diamond_chest_1" reads as "diamond_chest_1", never "ironchests:d".
local function shortName(value)
    local text=tostring(value or "")
    return text:match("^[%w_]+:(.+)$") or text
end

-- Set false at the top of every frame and raised by any row that actually scrolls; M.render
-- reports it back so the coordinator only keeps re-requesting animation frames while
-- something on the wall monitor is genuinely too long for its column. Module-local rather
-- than passed through every render* function -- CC is single-threaded, so one frame always
-- finishes before the next starts.
local animating = false

local function nodeByRole(model,role)
    for _,node in ipairs(model.nodes or {}) do if node.role==role then return node end end
end

local function fraction(node)
    local size=(node or {}).size or 0
    if size<=0 then return 0 end
    return math.max(0,math.min(1,((node or {}).occupied or 0)/size))
end

-- The same three thresholds the terminal uses, so a node that reads as filling on one screen
-- reads as filling on the other.
local function fillColor(value)
    if value>=0.9 then return Theme.role.alert end
    if value>=0.75 then return Theme.role.warn end
    return Theme.role.ok
end

local function gauge(surface,x,y,width,label,node)
    local value=fraction(node)
    local percent=tostring(math.floor(value*100+0.5)).."%"
    Draw.text(surface,x,y,label,#label,Theme.role.muted,Theme.role.ground)
    local meterX=x+#label+1
    local meterWidth=math.max(0,width-#label-#percent-3)
    if meterWidth>0 then
        Draw.meter(surface,meterX,y,meterWidth,value,fillColor(value),Theme.role.track)
    end
    Draw.text(surface,meterX+meterWidth+1,y,percent,#percent,Theme.role.text,Theme.role.ground)
end

-- Block glyphs are five columns wide with a one-column gap, so a number's painted width is
-- known before it is drawn. Measuring first is what stops the second total running off the
-- right edge on a monitor narrower than the one this was designed against.
local function blockWidth(text) return #text * 6 - 1 end

-- The point of a wall monitor is a number readable from across the base, so the totals are
-- drawn as five-row block glyphs rather than as text. Everything else is supporting detail.
--
-- Every row here is derived from the real height. An earlier version hardcoded them for a
-- 79x24 monitor, and since this tier starts at 14 rows, every shorter monitor computed a
-- node band that ended above where it began and silently listed no nodes at all.
local function renderLarge(surface,model,width,height)
    Draw.band(surface,1,Theme.role.panel)
    Draw.text(surface,2,1,"INVOS",9,Theme.role.brand,Theme.role.panel)
    if width>=40 then
        Draw.text(surface,9,1,"INVENTORY OPERATING SYSTEM",30,Theme.role.muted,Theme.role.panel)
    end
    local lifecycle=model.lifecycle or "BOOTING"
    Draw.rightText(surface,width-1,1,lifecycle,Theme.statusColor(lifecycle),Theme.role.panel)

    local items=formatNumber(model.total_items)
    local types=formatNumber(model.total_types)
    local top
    if height>=16 and blockWidth(items)+4<=width-2 then
        Draw.blockText(surface,3,3,items,Theme.role.focus)
        -- Row 8 stays clear. The glyphs run 3 to 7 and their descenders touch a caption
        -- placed directly beneath them.
        Draw.text(surface,3,9,"ITEMS STORED",22,Theme.role.muted,Theme.role.ground)
        local typesX=3+blockWidth(items)+4
        if typesX+blockWidth(types)<=width-1 and typesX+14<=width-1 then
            Draw.blockText(surface,typesX,3,types,Theme.role.text)
            Draw.text(surface,typesX,9,"DISTINCT TYPES",width-typesX,
                Theme.role.muted,Theme.role.ground)
        else
            -- No room for a second block number. The count still has to appear, so it goes
            -- beside the items label as ordinary text rather than being clipped mid-glyph.
            Draw.rightText(surface,width-1,9,types.." DISTINCT TYPES",
                Theme.role.muted,Theme.role.ground)
        end
        top=11
    else
        Draw.text(surface,2,3,items.." ITEMS",width-2,Theme.role.focus,Theme.role.ground)
        Draw.text(surface,2,4,types.." DISTINCT TYPES",width-2,
            Theme.role.muted,Theme.role.ground)
        top=6
    end

    -- Reserved bottom-up, each section dropped if the screen cannot afford it, so the node
    -- band always gets whatever is left rather than a band computed for a taller screen.
    --
    -- The bottom two rows are signposts: the monitor hangs above the real chests and the
    -- arrows point at them. They label the world rather than the model, which is why they
    -- outrank everything else here and why the abstract DROP-OFF > STORAGE > PICKUP band
    -- that replaced them was a poor trade -- it said the same thing without saying which
    -- chest is which.
    local signRow,arrowRow
    local bottom=height
    if height>=12 then
        arrowRow,signRow=height,height-1
        bottom=height-2
    end
    local gaugeRow
    if bottom-top>=2 then gaugeRow=bottom; bottom=bottom-1 end
    local alertRow=model.highest_alert and bottom or nil
    if alertRow then bottom=bottom-1 end
    local statusRow=bottom
    local nodesBottom=statusRow-1

    -- The activity column needs only enough for a request name; the node column has to fit
    -- a name, a meter and a percentage, so the split favours it.
    local right=math.max(24,math.floor(width*0.62))
    Draw.band(surface,top,Theme.role.panel)
    Draw.text(surface,2,top,"STORAGE NODES",right-3,Theme.role.muted,Theme.role.panel)
    Draw.text(surface,right,top,"CURRENT ACTIVITY",width-right,Theme.role.muted,Theme.role.panel)

    local row=top+1
    for _,node in ipairs(model.nodes or {}) do
        if row>nodesBottom then break end
        if node.role=="storage" then
            local value=fraction(node)
            local percent=tostring(math.floor(value*100+0.5)).."%"
            local leftEnd=right-2
            Draw.text(surface,2,row,"o",1,Theme.statusColor(node.state),Theme.role.ground)
            local meterWidth=math.max(0,math.min(8,leftEnd-20))
            -- The meter already says how full it is, so on a narrow column the percentage
            -- gives up its space to the name rather than the other way round.
            local showPercent=leftEnd-meterWidth-#percent-6>=12
            local percentWidth=showPercent and (#percent+1) or 0
            local meterX=leftEnd-percentWidth-meterWidth+1
            if Draw.marqueeText(surface,4,row,shortName(node.label or node.id),
                math.max(1,meterX-5),Theme.role.text,Theme.role.ground,model.now) then
                animating=true
            end
            if meterWidth>0 then
                Draw.meter(surface,meterX,row,meterWidth,value,fillColor(value),Theme.role.track)
            end
            if showPercent then
                Draw.rightText(surface,leftEnd,row,percent,Theme.role.muted,Theme.role.ground)
            end
            row=row+1
        end
    end

    local active=model.active_request
    if active then
        if Draw.marqueeText(surface,right,top+1,tostring(active.display_name or active.id),width-right,
            Theme.role.text,Theme.role.ground,model.now) then
            animating=true
        end
        local requested=active.requested or 0
        Draw.text(surface,right,top+2,formatNumber(active.delivered or 0).." / "..
            formatNumber(requested),width-right,Theme.role.muted,Theme.role.ground)
        local meterWidth=math.max(0,width-right-14)
        if meterWidth>0 and top+3<=nodesBottom then
            Draw.meter(surface,right,top+3,meterWidth,
                requested>0 and ((active.delivered or 0)/requested) or 0,
                Theme.role.working,Theme.role.track)
            Draw.rightText(surface,width-1,top+3,tostring(active.state or ""),
                Theme.statusColor(active.state),Theme.role.ground)
        end
    else
        Draw.text(surface,right,top+1,"No active request",width-right,
            Theme.role.muted,Theme.role.ground)
    end

    if gaugeRow then
        local half=math.floor(width/2)
        gauge(surface,2,gaugeRow,half-3,"DROP-OFF",nodeByRole(model,"dropoff"))
        gauge(surface,half+2,gaugeRow,half-3,"PICKUP",nodeByRole(model,"pickup"))
    end

    if alertRow then
        Draw.band(surface,alertRow,Theme.role.alert)
        Draw.text(surface,2,alertRow,tostring(model.highest_alert.message),width-2,
            Theme.role.text,Theme.role.alert)
    end
    Draw.text(surface,2,statusRow,
        enrichmentText(model.enrichment) or model.lifecycle_reason or "",width-2,
        Theme.role.muted,Theme.role.ground)

    if signRow then
        Draw.band(surface,signRow,Theme.role.panel)
        Draw.band(surface,arrowRow,Theme.role.ground)
        local dropCenter=math.floor(width*0.30)
        local pickupCenter=math.floor(width*0.70)
        Draw.centerText(surface,dropCenter,signRow,"DROP-OFF",Theme.role.brand,Theme.role.panel)
        Draw.centerText(surface,pickupCenter,signRow,"PICKUP",Theme.role.brand,Theme.role.panel)
        Draw.centerText(surface,dropCenter,arrowRow,"v",Theme.role.text,Theme.role.ground)
        Draw.centerText(surface,pickupCenter,arrowRow,"v",Theme.role.text,Theme.role.ground)
    end
end

local function renderMedium(surface,model,width,height)
    Draw.band(surface,1,Theme.role.panel)
    Draw.text(surface,2,1,"INVOS",9,Theme.role.brand,Theme.role.panel)
    local lifecycle=model.lifecycle or "BOOTING"
    Draw.rightText(surface,width-1,1,lifecycle,Theme.statusColor(lifecycle),Theme.role.panel)
    Draw.text(surface,2,3,formatNumber(model.total_items).." items  "..
        formatNumber(model.total_types).." types",width-2,Theme.role.focus,Theme.role.ground)
    local enriching=enrichmentText(model.enrichment)
    if enriching then
        Draw.text(surface,2,4,enriching,width-2,Theme.role.muted,Theme.role.ground)
    end
    local half=math.floor(width/2)
    gauge(surface,2,6,half-3,"DROP",nodeByRole(model,"dropoff"))
    gauge(surface,half+1,6,half-3,"PICK",nodeByRole(model,"pickup"))
    local active=model.active_request
    if active and height>=9 then
        if Draw.marqueeText(surface,2,8,tostring(active.display_name or active.id),width-2,
            Theme.role.text,Theme.role.ground,model.now) then
            animating=true
        end
        Draw.text(surface,2,9,formatNumber(active.delivered or 0).." / "..
            formatNumber(active.requested or 0).."  "..tostring(active.state or ""),
            width-2,Theme.statusColor(active.state),Theme.role.ground)
    end
    if model.highest_alert then
        Draw.text(surface,2,height,tostring(model.highest_alert.message),width-2,
            Theme.role.alert,Theme.role.ground)
    end
end

local function renderSmall(surface,model,width,height)
    Draw.band(surface,1,Theme.role.panel)
    Draw.text(surface,2,1,"INVOS",9,Theme.role.brand,Theme.role.panel)
    local lifecycle=model.lifecycle or "BOOTING"
    Draw.rightText(surface,width,1,lifecycle,Theme.statusColor(lifecycle),Theme.role.panel)
    Draw.text(surface,2,3,formatNumber(model.total_items).." items",width-2,
        Theme.role.focus,Theme.role.ground)
    Draw.text(surface,2,4,formatNumber(model.total_types).." types",width-2,
        Theme.role.muted,Theme.role.ground)
    if model.highest_alert then
        Draw.text(surface,2,height,tostring(model.highest_alert.message),width-2,
            Theme.role.alert,Theme.role.ground)
    end
end

local function frame(surface,model)
    animating=false
    local width,height=surface.getSize()
    surface.setBackgroundColor(Theme.role.ground)
    surface.setTextColor(Theme.role.text)
    surface.clear()
    if width<24 or height<8 then renderSmall(surface,model,width,height)
    elseif width<45 or height<14 then renderMedium(surface,model,width,height)
    else renderLarge(surface,model,width,height) end
    surface.setBackgroundColor(Theme.role.ground)
    surface.setTextColor(Theme.role.text)
    surface.setCursorBlink(false)
end

-- Single entry and exit, so a frame begun is always ended. A frame left un-ended leaves a
-- buffered window hidden and the screen frozen on the last thing shown -- the same shape as
-- UI:render, and for the same reason.
function M.render(surface,model)
    if surface.beginFrame then surface.beginFrame() end
    local ok,reason=pcall(frame,surface,model or {})
    if surface.endFrame then surface.endFrame() end
    if not ok then error(reason,0) end
    return animating
end

return M
