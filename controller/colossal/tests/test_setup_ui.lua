keys = keys or {}
keys.up=keys.up or 200;keys.down=keys.down or 208;keys.enter=keys.enter or 28
keys.left=203;keys.right=205;keys.f10=keys.f10 or 68;keys.escape=keys.escape or 1

local Keymap=require("app.keymap")
local UI=require("app.ui")
local T=require("tests.mock_cc")

return {
    {name="Setup page opens a full-screen wizard from Enter",run=function()
        local command=Keymap.command({"key",keys.enter},{mode="page",page="setup"})
        T.equal(command.type,"OPEN_SETUP")
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState();state.page="setup";state.mode="page"
        state=ui:reduce(state,command)
        T.equal(state.mode,"setup")
        T.equal(state.setup_step,1)
    end},
    {name="Setup wizard has complete keyboard navigation without Escape",run=function()
        local state={mode="setup",page="setup",selection=2}
        T.equal(Keymap.command({"key",keys.up},state).delta,-1)
        T.equal(Keymap.command({"key",keys.down},state).delta,1)
        T.equal(Keymap.command({"key",keys.enter},state).type,"SETUP_SELECT")
        T.equal(Keymap.command({"key",keys.left},state).type,"SETUP_BACK")
        T.equal(Keymap.command({"key",keys.right},state).type,"SETUP_NEXT")
        T.equal(Keymap.command({"key",keys.f10},state).type,"CANCEL_SETUP")
        T.equal(Keymap.command({"key",keys.escape},state),nil)
    end},
    {name="Setup wizard renderer controls every screen region",run=function()
        local surface=T.recordingSurface(51,19);local ui=UI.new(surface)
        local state=UI.initialState();state.page="setup";state.mode="setup";state.setup_step=2
        state.setup_choices={{label="drop",detail="27 slots"},{label="barrel",detail="27 slots"}}
        state.setup_choice_count=2;state.selection=1
        ui:render(state,{lifecycle="SETUP_REQUIRED",setup={issues={}}})
        T.contains(surface.line(1),"SETUP WIZARD")
        T.contains(surface.allText(),"Assign Drop-off")
        T.contains(surface.allText(),"drop")
        T.contains(surface.allText(),"27 slots")
        T.contains(surface.allText(),"Left back")
        T.contains(surface.allText(),"F10 cancel")
        T.equal(surface.writesOutsideBounds(),0)
    end},
    {name="Setup selection produces an effect without changing persisted configuration",run=function()
        local ui=UI.new(T.recordingSurface(51,19));local state=UI.initialState()
        state.mode="setup";state.page="setup";state.setup_step=3;state.selection=2
        local nextState,effect=ui:reduce(state,{type="SETUP_SELECT"})
        T.equal(nextState.mode,"setup")
        T.equal(effect.type,"SETUP_SELECT")
        T.equal(effect.step,3)
        T.equal(effect.index,2)
    end},
    {name="cancelling Setup returns to the main Setup page",run=function()
        local ui=UI.new(T.recordingSurface(51,19));local state=UI.initialState()
        state.mode="setup";state.page="setup";state.query="stone"
        local nextState,effect=ui:reduce(state,{type="CANCEL_SETUP"})
        T.equal(nextState.mode,"page")
        T.equal(nextState.page,"setup")
        T.equal(nextState.query,"stone")
        T.equal(effect.type,"CANCEL_SETUP")
    end},
}
