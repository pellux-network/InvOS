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
    { name = "CANCEL from a secondary page returns to the Search page", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state=ui:reduce(state,{type="OPEN_PAGE",page="requests"})
        T.equal(state.page,"requests")
        T.equal(state.mode,"page")
        state=ui:reduce(state,{type="CANCEL"})
        T.equal(state.mode,"search")
        T.equal(state.page,"search")
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
    { name = "acknowledging an alert dispatches the selected alert index", run = function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.page="alerts"
        state=ui:reduce(state,{type="SYNC_ALERTS",count=4})
        state=ui:reduce(state,{type="MOVE",delta=1})
        local _,effect=ui:reduce(state,{type="ACKNOWLEDGE_ALERT"})
        T.equal(effect.type,"ACKNOWLEDGE_ALERT")
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
}
