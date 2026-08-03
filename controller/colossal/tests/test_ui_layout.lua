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
        T.contains(surface.line(1),"COLOSSAL STORAGE")
        T.contains(surface.line(2),"1 SEARCH")
        T.contains(surface.line(3),"> sto")
        T.contains(surface.allText(),"Stone")
        T.contains(surface.allText(),"1,248")
        T.contains(surface.allText(),"All inventories healthy")
        T.truthy(#layout.hit_regions >= 2)
        T.equal(surface.writesOutsideBounds(),0)
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
}
