local UI = require("app.ui")
local T = require("tests.mock_cc")

local function results()
    return {
        {identity_key="stone",name="minecraft:stone",display_name="Stone",quantity=1248,
            max_count=64,variants={{identity_key="stone",display_name="Stone",quantity=1248}}},
        {identity_key="dirt",name="minecraft:dirt",display_name="Dirt",quantity=320,
            max_count=64,variants={{identity_key="dirt",display_name="Dirt",quantity=320}}},
    }
end

local function view()
    return {lifecycle="READY",lifecycle_reason="All inventories healthy",total_items=1568,
        total_types=2,search_results=results(),alerts={},nodes={{label="Main Vault",state="READY",
        occupied=420,size=3075}},requests={},dropoff={state="READY",occupied=0},
        pickup={state="READY",occupied=0}}
end

return {
    { name = "search page has a clear hierarchy at 51 by 19", run = function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState(); state.query="sto"; state.results=results(); state.result_count=2
        local layout=ui:render(state,view())
        T.contains(surface.line(1),"PELLSTORE")
        T.contains(surface.line(2),"1 SEARCH")
        T.contains(surface.line(3),"> sto")
        T.contains(surface.allText(),"Stone")
        T.contains(surface.allText(),"1,248")
        T.contains(surface.allText(),"All inventories healthy")
        T.truthy(#layout.hit_regions >= 2)
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "compact search uses a full-width list and selected summary", run = function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState(); state.results=results(); state.result_count=2
        ui:render(state,view())
        T.contains(surface.line(5),"Stone")
        T.contains(surface.line(5),"1,248")
        T.contains(surface.allText(),"Selected: Stone")
        T.contains(surface.allText(),"Enter to retrieve")
        T.equal(surface.allText():find("minecraft:stone",1,true),nil)
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "the Selected summary stays readable after scrolling the list to its last row", run = function()
        -- ui.lua's fallback palette (no `colors` global in tests): cyan=512, black=32768.
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local items={}
        for i=1,20 do
            items[i]={identity_key="item"..i,name="minecraft:item"..i,display_name="Item "..i,
                quantity=i,max_count=64,
                variants={{identity_key="item"..i,display_name="Item "..i,quantity=i,max_count=64}}}
        end
        local state=UI.initialState()
        state.results=items; state.result_count=#items; state.selection=#items
        local model=view(); model.search_results=items
        ui:render(state,model)
        T.contains(surface.allText(),"Selected: Item 20")
        T.equal(surface.backgroundAt(2,15), 32768)
    end },
    { name = "wide search retains a separate identity detail panel", run = function()
        local surface=T.recordingSurface(72,19)
        local ui=UI.new(surface)
        local state=UI.initialState(); state.results=results(); state.result_count=2
        ui:render(state,view())
        T.contains(surface.allText(),"minecraft:stone")
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "the wide detail panel stays readable after scrolling the list to its last row", run = function()
        local surface=T.recordingSurface(80,19)
        local ui=UI.new(surface)
        local items={}
        for i=1,20 do
            items[i]={identity_key="item"..i,name="minecraft:item"..i,display_name="Item "..i,
                quantity=i,max_count=64,
                variants={{identity_key="item"..i,display_name="Item "..i,quantity=i,max_count=64}}}
        end
        local state=UI.initialState()
        state.results=items; state.result_count=#items; state.selection=#items
        local model=view(); model.search_results=items
        ui:render(state,model)
        T.contains(surface.allText(),"Item 20")
        T.equal(surface.backgroundAt(51,5), 32768)
    end },
    { name = "quantity overlay states the item availability and controls", run = function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState(); state.results=results(); state.result_count=2
        state=ui:reduce(state,{type="OPEN_QUANTITY"})
        ui:render(state,view())
        T.contains(surface.allText(),"Retrieve Stone")
        T.contains(surface.allText(),"1,248 available")
        T.contains(surface.allText(),"Enter 1")
        T.contains(surface.allText(),"S stack")
        T.contains(surface.allText(),"A all")
        T.contains(surface.allText(),"F10 back")
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "secondary pages give useful empty states", run = function()
        local cases={
            {page="requests",text="No requests yet"},
            {page="alerts",text="No active alerts"},
            {page="setup",text="Review or change inventory roles"},
        }
        for _,case in ipairs(cases) do
            local surface=T.recordingSurface(51,19)
            local ui=UI.new(surface)
            local state=UI.initialState(); state.page=case.page
            ui:render(state,view())
            T.contains(surface.allText(),case.text)
            T.equal(surface.writesOutsideBounds(),0)
        end
    end },
    { name = "storage page renders nodes as separate readable rows", run = function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState(); state.page="storage"
        ui:render(state,view())
        T.contains(surface.allText(),"Main Vault")
        T.contains(surface.allText(),"READY")
        T.contains(surface.allText(),"420 / 3,075 slots")
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "narrow terminals fall back without clipping", run = function()
        local surface=T.recordingSurface(30,12)
        local ui=UI.new(surface)
        local state=UI.initialState(); state.results=results(); state.result_count=2
        ui:render(state,view())
        T.contains(surface.allText(),"Stone")
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "storage page scrolls to reach nodes past the fold", run = function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local nodes={}
        for index=1,20 do nodes[index]={label="Vault"..string.char(64+index),state="READY",
            occupied=0,size=10} end
        local model=view(); model.nodes=nodes
        local state=UI.initialState(); state.page="storage"
        ui:render(state,model)
        T.equal(surface.allText():find("VaultT",1,true),nil)
        T.equal(surface.writesOutsideBounds(),0)
        state.storage_scroll=10
        ui:render(state,model)
        T.contains(surface.allText(),"VaultT")
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "requests page highlights the selected request and scrolls past the fold", run = function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local requests={}
        for index=1,20 do requests[index]={id="request-"..index,display_name="Item"..string.char(64+index),
            state="QUEUED",delivered=0,requested=1} end
        local model=view(); model.requests=requests
        local state=UI.initialState(); state.page="requests"; state.request_selection=1
        ui:render(state,model)
        T.equal(surface.allText():find("ItemT",1,true),nil)
        state.request_selection=20
        ui:render(state,model)
        T.contains(surface.allText(),"ItemT")
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "alerts page highlights the selected alert and scrolls past the fold", run = function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local alerts={}
        for index=1,20 do alerts[index]={key="alert-"..index,severity="warning",
            message="Warning"..string.char(64+index),acknowledged=false} end
        local model=view(); model.alerts=alerts
        local state=UI.initialState(); state.page="alerts"; state.alert_selection=1
        ui:render(state,model)
        T.equal(surface.allText():find("WarningT",1,true),nil)
        state.alert_selection=20
        ui:render(state,model)
        T.contains(surface.allText(),"WarningT")
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "footer shows page specific operator control hints", run = function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState(); state.page,state.mode="requests","page"
        ui:render(state,view())
        T.contains(surface.line(18),"retry")
        T.contains(surface.line(18),"cancel")
        state=UI.initialState(); state.page,state.mode="alerts","page"
        ui:render(state,view())
        T.contains(surface.line(18),"acknowledge")
        T.contains(surface.line(18),"release recovery")
        state=UI.initialState(); state.page,state.mode="storage","page"
        ui:render(state,view())
        T.contains(surface.line(18),"scroll")
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "arming recovery release states what proof is given up in the notice line", run = function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState(); state.page,state.mode="alerts","page"
        state=ui:reduce(state,{type="ARM_RECOVERY_RELEASE"})
        ui:render(state,view())
        T.contains(surface.allText(),"proof")
        T.equal(surface.writesOutsideBounds(),0)
    end },
}
