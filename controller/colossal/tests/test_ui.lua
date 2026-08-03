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
}
