local UI = require("app.ui")
local Theme = require("app.theme")
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
        T.contains(surface.line(1),"INVOS")
        T.contains(surface.line(2),"1 SEARCH")
        -- The query sits below the nav rather than directly under it since the Panelled
        -- redesign put a blank row between the chrome and the content.
        T.contains(surface.line(4),"> sto")
        T.contains(surface.allText(),"Stone")
        T.contains(surface.allText(),"1,248")
        T.contains(surface.allText(),"All inventories healthy")
        T.truthy(#layout.hit_regions >= 2)
        T.equal(surface.writesOutsideBounds(),0)
    end },
    -- Was "compact search uses a full-width list and selected summary". The 51-column
    -- terminal used to get a full-width list and a two-line summary band, because the detail
    -- pane only appeared at 72 columns. The approved design shows a pane from 40 columns up,
    -- so this now pins what the summary band was *for* -- knowing what is selected and how to
    -- act on it -- rather than the band itself.
    { name = "search at 51 columns identifies the selection and how to act on it", run = function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState(); state.results=results(); state.result_count=2
        ui:render(state,view())
        local text=surface.allText()
        T.contains(text,"Stone")
        T.contains(text,"1,248")
        T.contains(text,"minecraft:stone","the pane now reaches down to 40 columns")
        T.contains(text,"RETRIEVE")
        T.equal(surface.writesOutsideBounds(),0)
    end },
    -- The original bug this guards: the list loop's last fill() left the highlight colour as
    -- the ambient background, which then bled into whatever was drawn next. Scrolling to the
    -- last row is what made it visible. The assertion is now "the pane is not wearing the
    -- selection colour" rather than "the pane is exactly black", because an untouched cell
    -- reads as nil, which is equally clean.
    { name = "the selection detail stays readable after scrolling to the last row", run = function()
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
        T.contains(surface.allText(),"Item 20")
        T.contains(surface.allText(),"minecraft:item20","the pane must name the selection")
        local paneColumn=34 -- inside the pane: at 51 columns the divider sits at 29
        for y=7,16 do
            T.equal(surface.backgroundAt(paneColumn,y)==Theme.role.focus, false,
                "the selection colour bled into the detail pane at row "..y)
        end
        T.equal(surface.writesOutsideBounds(),0)
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
        -- Same bleed guard as above, at the width where the pane is widest.
        for y=7,16 do
            T.equal(surface.backgroundAt(51,y)==Theme.role.focus, false,
                "the selection colour bled into the wide detail pane at row "..y)
        end
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "quantity overlay states the item availability and controls", run = function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState(); state.results=results(); state.result_count=2
        state=ui:reduce(state,{type="OPEN_QUANTITY"})
        ui:render(state,view())
        -- The prompt moved into the detail pane, which is 20 columns wide, so the item name
        -- now sits on its own line under the verb rather than beside it.
        T.contains(surface.allText(),"Retrieve")
        T.contains(surface.allText(),"Stone")
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
        -- The raw slot counts became a meter and a percentage: "420 / 3,075 slots" made you
        -- do the arithmetic, and 14% is the answer you wanted from it.
        T.contains(surface.allText(),"14%")
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
        T.contains(surface.line(18),"dismiss")
        state=UI.initialState(); state.page,state.mode="storage","page"
        ui:render(state,view())
        T.contains(surface.line(18),"scroll")
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "footer advertises Delete-to-clear on both search bars without clipping the word", run = function()
        for _, case in ipairs({
            {page="search", mode="search"},
            {page="crafting", mode="craft_search"},
        }) do
            for _, size in ipairs({{51,19},{30,12},{18,8}}) do
                local surface=T.recordingSurface(size[1], size[2])
                local ui=UI.new(surface)
                local state=UI.initialState()
                state.page, state.mode = case.page, case.mode
                ui:render(state, view())
                T.contains(surface.allText(), "Delete clear",
                    size[1].."x"..size[2].." on "..case.page..
                        " must show the whole hint, not a word clipped mid-way")
                T.equal(surface.writesOutsideBounds(), 0)
            end
        end
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
    { name = "in-progress metadata enrichment replaces the lifecycle reason in the footer", run = function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local model=view(); model.enrichment={learned=1200,total=3000}
        local state=UI.initialState()
        ui:render(state,model)
        T.contains(surface.line(19),"1,200")
        T.contains(surface.line(19),"3,000")
        T.equal(surface.allText():find("All inventories healthy",1,true),nil)
        T.equal(surface.writesOutsideBounds(),0)
    end },
    { name = "an operator notice still takes priority over enrichment progress in the footer", run = function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local model=view(); model.enrichment={learned=1200,total=3000}
        local state=UI.initialState(); state.notice="Queued 5 Stone"
        ui:render(state,model)
        T.contains(surface.line(19),"Queued 5 Stone")
        T.equal(surface.allText():find("1,200/3,000",1,true),nil)
        T.equal(surface.writesOutsideBounds(),0)
    end },
}
