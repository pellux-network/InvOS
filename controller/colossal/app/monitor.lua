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

-- The point of a wall monitor is a number readable from across the base, so the totals are
-- drawn as five-row block glyphs rather than as text. Everything else is supporting detail.
local function renderLarge(surface,model,width,height)
    Draw.band(surface,1,Theme.role.panel)
    Draw.text(surface,2,1,"INVOS",9,Theme.role.brand,Theme.role.panel)
    Draw.text(surface,9,1,"INVENTORY OPERATING SYSTEM",30,Theme.role.muted,Theme.role.panel)
    local lifecycle=model.lifecycle or "BOOTING"
    Draw.rightText(surface,width-1,1,lifecycle,Theme.statusColor(lifecycle),Theme.role.panel)

    local afterItems=Draw.blockText(surface,3,3,formatNumber(model.total_items),Theme.role.focus)
    Draw.text(surface,3,8,"ITEMS STORED",30,Theme.role.muted,Theme.role.ground)
    local typesAt=math.max(afterItems+4,math.floor(width*0.62))
    if typesAt+6<width then
        Draw.blockText(surface,typesAt,3,formatNumber(model.total_types),Theme.role.text)
        Draw.text(surface,typesAt,8,"DISTINCT TYPES",width-typesAt,Theme.role.muted,Theme.role.ground)
    end

    local right=math.max(30,math.floor(width*0.56))
    Draw.band(surface,10,Theme.role.panel)
    Draw.text(surface,2,10,"STORAGE NODES",right-3,Theme.role.muted,Theme.role.panel)
    Draw.text(surface,right,10,"CURRENT ACTIVITY",width-right,Theme.role.muted,Theme.role.panel)

    local row,bottom=11,math.min(14,height-9)
    for _,node in ipairs(model.nodes or {}) do
        if row>bottom then break end
        if node.role=="storage" then
            local value=fraction(node)
            Draw.text(surface,2,row,"o",1,Theme.statusColor(node.state),Theme.role.ground)
            local meterWidth=math.max(0,math.min(12,right-24))
            local meterX=right-meterWidth-7
            Draw.text(surface,4,row,tostring(node.label or node.id),
                math.max(1,meterX-5),Theme.role.text,Theme.role.ground)
            if meterWidth>0 then
                Draw.meter(surface,meterX,row,meterWidth,value,fillColor(value),Theme.role.track)
            end
            Draw.rightText(surface,right-3,row,tostring(math.floor(value*100+0.5)).."%",
                Theme.role.muted,Theme.role.ground)
            row=row+1
        end
    end

    local active=model.active_request
    if active then
        Draw.text(surface,right,11,tostring(active.display_name or active.id),width-right,
            Theme.role.text,Theme.role.ground)
        local requested=active.requested or 0
        Draw.text(surface,right,12,formatNumber(active.delivered or 0).." / "..
            formatNumber(requested),width-right,Theme.role.muted,Theme.role.ground)
        local meterWidth=math.max(0,width-right-14)
        if meterWidth>0 then
            Draw.meter(surface,right,13,meterWidth,
                requested>0 and ((active.delivered or 0)/requested) or 0,
                Theme.role.working,Theme.role.track)
        end
        Draw.rightText(surface,width-1,13,tostring(active.state or ""),
            Theme.statusColor(active.state),Theme.role.ground)
    else
        Draw.text(surface,right,11,"No active request",width-right,
            Theme.role.muted,Theme.role.ground)
    end

    if height>=18 then
        Draw.band(surface,16,Theme.role.panel)
        local flow="DROP-OFF   >   STORAGE   >   PICKUP"
        Draw.centerText(surface,math.floor(width/2)+1,16,flow,Theme.role.text,Theme.role.panel)
        local half=math.floor(width/2)
        gauge(surface,2,18,half-3,"DROP-OFF",nodeByRole(model,"dropoff"))
        gauge(surface,half+2,18,half-3,"PICKUP",nodeByRole(model,"pickup"))
    end

    if model.highest_alert and height>=21 then
        Draw.band(surface,height-2,Theme.role.alert)
        Draw.text(surface,2,height-2,tostring(model.highest_alert.message),width-2,
            Theme.role.text,Theme.role.alert)
    end
    Draw.text(surface,2,height,
        enrichmentText(model.enrichment) or model.lifecycle_reason or "",width-2,
        Theme.role.muted,Theme.role.ground)
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
        Draw.text(surface,2,8,tostring(active.display_name or active.id),width-2,
            Theme.role.text,Theme.role.ground)
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
end

return M
