local Monitor = require("app.monitor")
local T = require("tests.mock_cc")

local function view()
    return {lifecycle="READY",total_items=98765,total_types=412,
        highest_alert=nil,dropoff={state="READY",occupied=2},pickup={state="READY",occupied=0},
        nodes={{label="Main Vault",state="READY"},{label="Archive",state="DEGRADED"}},
        active_request={display_name="Stone",delivered=32,requested=64,state="TRANSFERRING"}}
end

local function countedSurface(width,height)
    local surface=T.recordingSurface(width,height)
    local calls=0
    local original=surface.getSize
    surface.getSize=function() calls=calls+1; return original() end
    return surface,function() return calls end
end

return {
    { name = "small monitor shows essential state and stock", run = function()
        local surface=T.recordingSurface(18,6)
        Monitor.render(surface,view())
        T.contains(surface.allText(),"PELLSTORE")
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
        T.equal(surface.allText():find("RECENT MOVEMENT",1,true),nil)
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "monitor redraw reads new dimensions after resize", run = function()
        local small=T.recordingSurface(18,6)
        local large=T.recordingSurface(58,18)
        Monitor.render(small,view())
        Monitor.render(large,view())
        T.contains(large.allText(),"> STORAGE >")
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
    { name = "medium and large monitors show enrichment progress while learning item names", run = function()
        local model=view(); model.enrichment={learned=1200,total=3000}
        local mediumSurface=T.recordingSurface(34,11)
        Monitor.render(mediumSurface,model)
        T.contains(mediumSurface.allText(),"1,200")
        T.contains(mediumSurface.allText(),"3,000")
        T.equal(mediumSurface.writesOutsideBounds(),0)

        local largeSurface=T.recordingSurface(58,18)
        Monitor.render(largeSurface,model)
        T.contains(largeSurface.allText(),"1,200")
        T.contains(largeSurface.allText(),"3,000")
        T.equal(largeSurface.writesOutsideBounds(),0)
    end },
    { name = "enrichment progress does not show once learning finishes", run = function()
        local surface=T.recordingSurface(58,18)
        Monitor.render(surface,view())
        T.equal(surface.allText():find("Learning",1,true),nil)
    end },
    { name = "large monitor frame looks up the surface size exactly once", run = function()
        local surface,calls=countedSurface(58,18)
        Monitor.render(surface,view())
        T.equal(calls(),1)
    end },
    { name = "medium monitor frame looks up the surface size exactly once", run = function()
        local surface,calls=countedSurface(34,11)
        Monitor.render(surface,view())
        T.equal(calls(),1)
    end },
    { name = "small monitor frame looks up the surface size exactly once", run = function()
        local surface,calls=countedSurface(18,6)
        Monitor.render(surface,view())
        T.equal(calls(),1)
    end },
}
