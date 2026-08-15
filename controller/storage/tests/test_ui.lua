local UI = require("app.ui")
local T = require("tests.mock_cc")

local function result(key, name, quantity, variants)
    return {identity_key=key,name="minecraft:"..name:lower(),display_name=name,
        quantity=quantity,max_count=64,variants=variants or {{identity_key=key,
            display_name=name,quantity=quantity,max_count=64}}}
end

return {
    { name = "UI reducer preserves query while opening and cancelling quantity", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.results={result("stone","Stone",128)}
        state.result_count=1
        state=ui:reduce(state,{type="QUERY_APPEND",text="sto"})
        T.equal(state.query,"sto")
        state=ui:reduce(state,{type="OPEN_QUANTITY"})
        T.equal(state.mode,"quantity")
        T.equal(state.identity.identity_key,"stone")
        state=ui:reduce(state,{type="CANCEL"})
        T.equal(state.mode,"search")
        T.equal(state.query,"sto")
    end },
    { name = "QUERY_CLEAR empties the search query and resets selection", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state=ui:reduce(state,{type="QUERY_APPEND",text="sto"})
        state.selection=3
        state=ui:reduce(state,{type="QUERY_CLEAR"})
        T.equal(state.query,"")
        T.equal(state.selection,1)
    end },
    { name = "CRAFT_QUERY_CLEAR empties the recipe query without touching retrieval search", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state=ui:reduce(state,{type="QUERY_APPEND",text="sto"})
        state=ui:reduce(state,{type="CRAFT_QUERY_APPEND",text="ch"})
        state.craft_selection=3
        state=ui:reduce(state,{type="CRAFT_QUERY_CLEAR"})
        T.equal(state.craft_query,"")
        T.equal(state.craft_selection,1)
        T.equal(state.query,"sto","clearing the recipe search must not touch the retrieval search")
    end },
    { name = "CANCEL on a plain page is a no-op: '1' is the only way to Search", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state=ui:reduce(state,{type="OPEN_PAGE",page="requests"})
        T.equal(state.page,"requests")
        T.equal(state.mode,"page")
        state=ui:reduce(state,{type="CANCEL"})
        T.equal(state.mode,"page","F10 has no level to pop from a plain page")
        T.equal(state.page,"requests")
    end },
    { name = "CANCEL on the Search page itself is a no-op", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        T.equal(state.mode,"search")
        state=ui:reduce(state,{type="CANCEL"})
        T.equal(state.mode,"search")
        T.equal(state.page,"search")
    end },
    { name = "CANCEL from the variant overlay pops to search", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.mode="variant"
        state.variants={{identity_key="a",display_name="A"}}
        state=ui:reduce(state,{type="CANCEL"})
        T.equal(state.mode,"search")
        T.equal(state.variants,nil)
    end },
    { name = "UI reducer converts quantity shortcuts into exact request effects", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.results={result("stone","Stone",20)}; state.result_count=1
        state=ui:reduce(state,{type="OPEN_QUANTITY"})
        local nextState,effect=ui:reduce(state,{type="REQUEST",quantity="stack"})
        T.equal(effect.type,"CREATE_REQUEST")
        T.equal(effect.identity.identity_key,"stone")
        T.equal(effect.quantity,20)
        T.equal(nextState.mode,"search")
        T.contains(nextState.notice,"20")
    end },
    { name = "REQUEST from a quantity hotkey suppresses the matching char event", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.results={result("stone","Stone",20)}; state.result_count=1
        state=ui:reduce(state,{type="OPEN_QUANTITY"})
        state=ui:reduce(state,{type="REQUEST",quantity="stack",char="s"})
        T.equal(state.mode,"search")
        T.equal(state.suppress_char,"s")
        state=ui:reduce(state,{type="CONSUME_CHAR",text="s"})
        T.equal(state.query,"")
        T.equal(state.suppress_char,nil)
    end },
    { name = "UI reducer supports exact typed quantities", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.results={result("stone","Stone",128)}; state.result_count=1
        state=ui:reduce(state,{type="OPEN_QUANTITY"})
        state=ui:reduce(state,{type="SET_QUANTITY",digit="4"})
        state=ui:reduce(state,{type="SET_QUANTITY",digit="2"})
        T.equal(state.quantity_text,"42")
        local _,effect=ui:reduce(state,{type="REQUEST",quantity=42})
        T.equal(effect.quantity,42)
    end },
    { name = "UI reducer requires exact selection for NBT variants", run = function()
        local variants={
            {identity_key="heal",display_name="Potion of Healing",quantity=3,max_count=1},
            {identity_key="strong",display_name="Potion of Strength",quantity=5,max_count=1},
        }
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.results={result(nil,"Potion",8,variants)}; state.result_count=1
        state=ui:reduce(state,{type="OPEN_QUANTITY"})
        T.equal(state.mode,"variant")
        state=ui:reduce(state,{type="MOVE",delta=1})
        state=ui:reduce(state,{type="ACTIVATE"})
        T.equal(state.mode,"quantity")
        T.equal(state.identity.identity_key,"strong")
    end },
    { name = "clicking a search result twice opens quantity; once only selects it", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.results={result("stone","Stone",128),result("dirt","Dirt",64)}
        state.result_count=2
        state=ui:reduce(state,{type="ACTIVATE",index=2})
        T.equal(state.selection,2)
        T.equal(state.mode,"search","the first click must only highlight, not open quantity")
        state=ui:reduce(state,{type="ACTIVATE",index=2})
        T.equal(state.mode,"quantity","a second click on the same result opens quantity")
        T.equal(state.identity.identity_key,"dirt")
    end },
    { name = "typing after a search click re-arms it so the next click only selects again",
        run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.results={result("stone","Stone",128)}
        state.result_count=1
        state=ui:reduce(state,{type="ACTIVATE",index=1})
        state=ui:reduce(state,{type="QUERY_APPEND",text="s"})
        state.results={result("stone","Stone",128)}
        state.result_count=1
        state=ui:reduce(state,{type="ACTIVATE",index=1})
        T.equal(state.mode,"search","typing must re-arm the click so the next one only selects")
    end },
    { name = "UI selection clamps when live results shrink", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.selection=8; state.result_count=2
        state=ui:reduce(state,{type="SYNC_RESULTS",results={result("a","A",1),result("b","B",1)}})
        T.equal(state.selection,2)
    end },
    { name = "requests page tracks a selection clamped to the synced count", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state=ui:reduce(state,{type="SYNC_REQUESTS",count=3})
        T.equal(state.request_selection,1)
        state.page="requests"
        state=ui:reduce(state,{type="MOVE",delta=1})
        T.equal(state.request_selection,2)
        state=ui:reduce(state,{type="MOVE",delta=5})
        T.equal(state.request_selection,3)
        state=ui:reduce(state,{type="MOVE",delta=-9})
        T.equal(state.request_selection,1)
        state=ui:reduce(state,{type="SYNC_REQUESTS",count=1})
        T.equal(state.request_selection,1)
    end },
    { name = "alerts page tracks a selection clamped to the synced count", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.page="alerts"
        state=ui:reduce(state,{type="SYNC_ALERTS",count=2})
        state=ui:reduce(state,{type="MOVE",delta=1})
        T.equal(state.alert_selection,2)
        state=ui:reduce(state,{type="MOVE",delta=5})
        T.equal(state.alert_selection,2)
    end },
    { name = "storage page scrolling never goes negative", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.page="storage"
        state=ui:reduce(state,{type="MOVE",delta=-5})
        T.equal(state.storage_scroll,1)
        state=ui:reduce(state,{type="MOVE",delta=3})
        T.equal(state.storage_scroll,4)
    end },
    { name = "retry and cancel requests dispatch the selected request index", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.page="requests"
        state=ui:reduce(state,{type="SYNC_REQUESTS",count=4})
        state=ui:reduce(state,{type="MOVE",delta=2})
        local _,retryEffect=ui:reduce(state,{type="RETRY_REQUEST"})
        T.equal(retryEffect.type,"RETRY_REQUEST")
        T.equal(retryEffect.index,3)
        local _,cancelEffect=ui:reduce(state,{type="CANCEL_REQUEST"})
        T.equal(cancelEffect.type,"CANCEL_REQUEST")
        T.equal(cancelEffect.index,3)
    end },
    { name = "dismissing an alert dispatches the selected alert index", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.page="alerts"
        state=ui:reduce(state,{type="SYNC_ALERTS",count=4})
        state=ui:reduce(state,{type="MOVE",delta=1})
        local _,effect=ui:reduce(state,{type="DISMISS_ALERT"})
        T.equal(effect.type,"DISMISS_ALERT")
        T.equal(effect.index,2)
    end },
    { name = "toggling pause emits an effect for the coordinator", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local _,effect=ui:reduce(UI.initialState(),{type="TOGGLE_PAUSE"})
        T.equal(effect.type,"TOGGLE_PAUSE")
    end },
    { name = "recovery release requires an explicit arm and confirm, and states what is lost", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state=ui:reduce(state,{type="ARM_RECOVERY_RELEASE"})
        T.equal(state.recovery_confirm_armed,true)
        T.contains(state.notice,"proof")
        local cancelled=ui:reduce(state,{type="CANCEL_RECOVERY_RELEASE"})
        T.equal(cancelled.recovery_confirm_armed,false)
        local confirmedState,effect=ui:reduce(state,{type="CONFIRM_RECOVERY_RELEASE"})
        T.equal(confirmedState.recovery_confirm_armed,false)
        T.equal(effect.type,"RESOLVE_RECOVERY")
    end },
    { name = "update confirm requires an explicit arm and confirm", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state=ui:reduce(state,{type="ARM_UPDATE_CONFIRM"})
        T.equal(state.update_confirm_armed,true)
        T.contains(state.notice,"reboots")
        local cancelled,cancelEffect=ui:reduce(state,{type="CANCEL_UPDATE_CONFIRM"})
        T.equal(cancelled.update_confirm_armed,false)
        T.equal(cancelled.notice,nil)
        T.equal(cancelEffect.type,"CANCEL_UPDATE")
        local confirmedState,effect=ui:reduce(state,{type="CONFIRM_UPDATE"})
        T.equal(confirmedState.update_confirm_armed,false)
        T.equal(effect.type,"TRIGGER_UPDATE")
    end },
    { name = "CONFIRM_UPDATE does nothing unless armed", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local _,effect=ui:reduce(UI.initialState(),{type="CONFIRM_UPDATE"})
        T.equal(effect,nil)
    end },
    { name = "PROCEED_WITHOUT_TURTLE clears turtle_unreachable and produces its own effect", run=function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.update_turtle_unreachable=true
        local nextState,effect=ui:reduce(state,{type="PROCEED_WITHOUT_TURTLE"})
        T.equal(nextState.update_turtle_unreachable,false)
        T.equal(effect.type,"PROCEED_WITHOUT_TURTLE")
    end },
    { name = "UI consumes a page shortcut character exactly once", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state=ui:reduce(state,{type="OPEN_PAGE",page="search",suppress_char="1"})
        T.equal(state.suppress_char,"1")
        state=ui:reduce(state,{type="CONSUME_CHAR",text="1"})
        T.equal(state.query,"")
        T.equal(state.suppress_char,nil)
        state=ui:reduce(state,{type="QUERY_APPEND",text="1"})
        T.equal(state.query,"1")
    end },
    { name = "the active page is marked in the navigation bar", run = function()
        local Theme=require("app.theme")
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        ui:render(UI.initialState(),{lifecycle="READY"})
        local function markedCells()
            local count=0
            for x=1,51 do
                if surface.backgroundAt(x,2)==Theme.role.focus then count=count+1 end
            end
            return count
        end
        T.truthy(markedCells()>0,
            "the page you are on must be distinguishable from the five you are not")
        T.truthy(markedCells()<20,"only the active tab should be filled, not the whole bar")
        local onCrafting=ui:reduce(UI.initialState(),{type="OPEN_PAGE",page="crafting"})
        surface.clear()
        ui:render(onCrafting,{lifecycle="READY"})
        T.truthy(surface.line(2):find("CRAFT",1,true)~=nil,"crafting must still be listed")
    end },
    { name = "the navigation bar still lists every page after restyling", run = function()
        local ui=UI.new(T.recordingSurface(80,19))
        ui:render(UI.initialState(),{lifecycle="READY"})
        local nav=ui.surface.line(2)
        for _,label in ipairs({"SEARCH","NODES","REQUESTS","ALERTS","SETUP","CRAFTING"}) do
            T.contains(nav,label)
        end
    end },
}
