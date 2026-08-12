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
    { name = "ui.lua has no private copy of the shared drawing helpers", run = function()
        local file = io.open("colossal/app/ui.lua")
        T.equal(file ~= nil, true, "run the suite from controller/, not colossal/")
        local source = file:read("a"); file:close()
        for _, banned in ipairs({"writeClipped", "stateColor", "local palette"}) do
            T.equal(source:find(banned, 1, true), nil,
                banned .. " is still in ui.lua; app/draw.lua and app/theme.lua own it now")
        end
        -- `fill` is a common word; pin the call shape the old private helper used.
        T.equal(source:find("fill(surface,", 1, true), nil,
            "the private row-fill is still in ui.lua; Draw.band owns it now")
    end },
}
