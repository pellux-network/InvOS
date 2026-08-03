local M = {}

local palette = colors or {
    white=1, yellow=16, lime=32, gray=128, lightGray=256, cyan=512,
    red=16384, black=32768,
}

local function formatNumber(value)
    local text=tostring(math.floor(tonumber(value) or 0))
    while true do local changed; text,changed=text:gsub("^(%-?%d+)(%d%d%d)","%1,%2"); if changed==0 then break end end
    return text
end

local function colorFor(state)
    if state=="READY" or state=="COMPLETE" then return palette.lime end
    if state=="DEGRADED" or state=="BLOCKED" or state=="PARTIAL" then return palette.yellow end
    if state=="ERROR" or state=="FAILED" or state=="OFFLINE" then return palette.red end
    return palette.cyan
end

local function write(surface,x,y,text,width,color,background)
    local sw,sh=surface.getSize()
    if y<1 or y>sh or x<1 or x>sw or width<=0 then return end
    text=tostring(text or ""):sub(1,math.min(width,sw-x+1))
    if #text>0 then
        surface.setBackgroundColor(background or palette.black)
        surface.setTextColor(color or palette.white)
        surface.setCursorPos(x,y)
        surface.write(text)
    end
end

local function writeCentered(surface,center,y,text,color,background)
    text=tostring(text or "")
    local width=surface.getSize()
    local x=math.max(1,math.min(width-#text+1,math.floor(center-#text/2)))
    write(surface,x,y,text,#text,color,background)
end

local function line(surface,y,color)
    local width,height=surface.getSize(); if y<1 or y>height then return end
    surface.setBackgroundColor(color); surface.setCursorPos(1,y); surface.write(string.rep(" ",width))
end

local function renderSmall(surface,model,width,height)
    line(surface,1,palette.gray)
    write(surface,2,1,"STORAGE",8,palette.white)
    local state=model.lifecycle or "BOOTING"
    write(surface,math.max(2,width-#state),1,state,#state,colorFor(state))
    write(surface,2,3,formatNumber(model.total_items).." items",width-2,palette.cyan)
    write(surface,2,4,formatNumber(model.total_types).." types",width-2,palette.lightGray)
    if model.highest_alert then write(surface,2,height,model.highest_alert.message,width-2,palette.red) end
end

local function renderMedium(surface,model,width,height)
    line(surface,1,palette.gray)
    write(surface,2,1,"COLOSSAL STORAGE",18,palette.white)
    local state=model.lifecycle or "BOOTING"
    write(surface,math.max(2,width-#state),1,state,#state,colorFor(state))
    write(surface,2,3,formatNumber(model.total_items).." items  "..
        formatNumber(model.total_types).." types",width-2,palette.cyan)
    write(surface,2,5,"DROP-OFF > STORAGE > PICKUP",width-2,palette.lightGray)
    write(surface,2,6,tostring(model.dropoff and model.dropoff.state or "OFFLINE"),9,
        colorFor(model.dropoff and model.dropoff.state))
    write(surface,math.max(2,width-8),6,tostring(model.pickup and model.pickup.state or "OFFLINE"),8,
        colorFor(model.pickup and model.pickup.state))
    if model.active_request then
        write(surface,2,8,model.active_request.display_name,width-2,palette.white)
        write(surface,2,9,formatNumber(model.active_request.delivered).." / "..
            formatNumber(model.active_request.requested).."  "..model.active_request.state,
            width-2,colorFor(model.active_request.state))
    end
    if model.highest_alert then write(surface,2,height,model.highest_alert.message,width-2,palette.red) end
end

local function renderLarge(surface,model,width,height)
    line(surface,1,palette.gray)
    write(surface,2,1,"COLOSSAL STORAGE NETWORK",26,palette.white,palette.gray)
    local state=model.lifecycle or "BOOTING"
    write(surface,math.max(2,width-#state-1),1,state,#state,colorFor(state),palette.gray)
    write(surface,2,3,formatNumber(model.total_items).." ITEMS",18,palette.cyan)
    write(surface,22,3,formatNumber(model.total_types).." TYPES",16,palette.lightGray)
    line(surface,5,palette.gray)
    local flow="DROP-OFF  > STORAGE >  PICKUP"
    write(surface,math.max(2,math.floor((width-#flow)/2)),5,flow,#flow,palette.white,palette.gray)

    local right=math.max(30,math.floor(width*0.56))
    local leftEnd=right-2
    write(surface,2,7,"STORAGE NODES",leftEnd-1,palette.cyan)
    write(surface,right,7,"CURRENT ACTIVITY",width-right+1,palette.cyan)
    local row,nodeBottom=8,math.min(11,height-5)
    for _,node in ipairs(model.nodes or {}) do
        if row>nodeBottom then break end
        local nodeState=tostring(node.state or "")
        local stateX=math.max(5,leftEnd-#nodeState+1)
        write(surface,2,row,"o",1,colorFor(nodeState))
        write(surface,4,row,node.label,math.max(1,stateX-5),palette.white)
        write(surface,stateX,row,nodeState,#nodeState,colorFor(nodeState))
        row=row+1
    end
    if model.active_request then
        write(surface,right,8,model.active_request.display_name,width-right+1,palette.white)
        write(surface,right,9,formatNumber(model.active_request.delivered).." / "..
            formatNumber(model.active_request.requested).."  "..model.active_request.state,
            width-right+1,colorFor(model.active_request.state))
    else write(surface,right,8,"No active request",width-right+1,palette.lightGray) end

    if height>=17 then
        local recentTop=height-6
        write(surface,2,recentTop,"RECENT MOVEMENT",leftEnd-1,palette.cyan)
        for index,item in ipairs(model.recent_transfers or {}) do
            if index>2 or recentTop+index>=height-2 then break end
            write(surface,2,recentTop+index,item.label,leftEnd-1,palette.lightGray)
        end
    end
    if model.highest_alert then
        line(surface,height-2,palette.red)
        write(surface,2,height-2,model.highest_alert.message,width-2,palette.white,palette.red)
    end

    local dropCenter=math.floor(width*0.30)
    local pickupCenter=math.floor(width*0.70)
    writeCentered(surface,dropCenter,height-1,"DROP-OFF",palette.cyan)
    writeCentered(surface,pickupCenter,height-1,"PICKUP",palette.cyan)
    writeCentered(surface,dropCenter,height,"v",palette.white)
    writeCentered(surface,pickupCenter,height,"v",palette.white)
end

function M.render(surface,model)
    local width,height=surface.getSize()
    surface.setBackgroundColor(palette.black); surface.setTextColor(palette.white); surface.clear()
    if width<24 or height<8 then renderSmall(surface,model,width,height)
    elseif width<45 or height<14 then renderMedium(surface,model,width,height)
    else renderLarge(surface,model,width,height) end
    surface.setBackgroundColor(palette.black); surface.setTextColor(palette.white); surface.setCursorBlink(false)
end

return M
