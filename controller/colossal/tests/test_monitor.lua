local Monitor = require("app.monitor")
local T = require("tests.mock_cc")

local function view()
    return {lifecycle="READY",total_items=98765,total_types=412,
        highest_alert=nil,dropoff={state="READY",occupied=2},pickup={state="READY",occupied=0},
        nodes={{label="Main Vault",state="READY"},{label="Archive",state="DEGRADED"}},
        active_request={display_name="Stone",delivered=32,requested=64,state="TRANSFERRING"},
        recent_transfers={{label="64 Stone to Pickup"},{label="12 Dirt imported"}}}
end

return {
    { name = "small monitor shows essential state and stock", run = function()
        local surface=T.recordingSurface(18,6)
        Monitor.render(surface,view())
        T.contains(surface.allText(),"STORAGE")
        T.contains(surface.allText(),"READY")
        T.contains(surface.allText(),"98,765")
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "medium monitor shows IO and active request", run = function()
        local surface=T.recordingSurface(34,11)
        Monitor.render(surface,view())
        T.contains(surface.allText(),"DROP-OFF")
        T.contains(surface.allText(),"PICKUP")
        T.contains(surface.allText(),"Stone")
        T.contains(surface.allText(),"32 / 64")
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "large wall monitor uses the storage flow rail and node overview", run = function()
        local surface=T.recordingSurface(58,18)
        Monitor.render(surface,view())
        T.contains(surface.allText(),"DROP-OFF")
        T.contains(surface.allText(),"> STORAGE >")
        T.contains(surface.allText(),"Main Vault")
        T.contains(surface.allText(),"Archive")
        T.contains(surface.allText(),"RECENT MOVEMENT")
        T.contains(surface.allText(),"64 Stone to Pickup")
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "monitor redraw reads new dimensions after resize", run = function()
        local small=T.recordingSurface(18,6)
        local large=T.recordingSurface(58,18)
        Monitor.render(small,view())
        Monitor.render(large,view())
        T.contains(large.allText(),"RECENT MOVEMENT")
        T.equal(small.writesOutsideBounds(),0)
        T.equal(large.writesOutsideBounds(),0)
    end },
    { name = "monitor makes the highest alert prominent", run = function()
        local model=view(); model.lifecycle="DEGRADED"
        model.highest_alert={severity="critical",message="Pickup is full"}
        local surface=T.recordingSurface(34,11)
        Monitor.render(surface,model)
        T.contains(surface.allText(),"Pickup is full")
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "large monitor has clean columns and physical chest markers", run = function()
        local model=view(); model.active_request=nil
        model.nodes={{label=string.rep("X",48),state="READY"}}
        local surface=T.recordingSurface(58,18)
        Monitor.render(surface,model)
        T.contains(surface.line(17),"DROP-OFF")
        T.contains(surface.line(17),"PICKUP")
        T.truthy(surface.line(18):match("v.*v"))
        T.equal(surface.backgroundAt(2,3),32768)
        local activityX=math.max(30,math.floor(58*0.56))
        T.equal(surface.line(8):sub(activityX):find("READY",1,true),nil)
        T.contains(surface.line(8):sub(activityX),"No active request")
        T.equal(surface.writesOutsideBounds(),0)
    end },
}
