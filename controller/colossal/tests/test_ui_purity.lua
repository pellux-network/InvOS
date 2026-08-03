local UI = require("app.ui")
local T = require("tests.mock_cc")

return {
    { name = "rendering a scrolled result list never mutates UI state", run = function()
        local results={}
        for index=1,8 do results[index]={identity_key="item"..index,name="mod:item"..index,
            display_name="Item "..index,quantity=index,variants={{identity_key="item"..index,
            display_name="Item "..index,quantity=index}}} end
        local state=UI.initialState()
        state.results=results; state.result_count=#results; state.selection=7; state.scroll=1
        local ui=UI.new(T.recordingSurface(30,10))
        ui:render(state,{lifecycle="READY",lifecycle_reason="healthy",search_results=results})
        T.equal(state.scroll,1)
        T.equal(state.selection,7)
    end },
}
