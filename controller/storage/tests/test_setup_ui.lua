keys = keys or {}
keys.up=keys.up or 200;keys.down=keys.down or 208;keys.enter=keys.enter or 28
keys.left=203;keys.right=205;keys.f10=keys.f10 or 68;keys.escape=keys.escape or 1

local Keymap=require("app.keymap")
local UI=require("app.ui")
local Theme=require("app.theme")
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
    {name="every wizard step has its own title and prompt",run=function()
        -- A step with no entry falls back to a generic inventory line, which is wrong on
        -- the turtle and monitor steps and reads as if it is asking for a chest again.
        local generic = "wired peripheral for this role"
        for step = 1, 10 do
            local surface = T.recordingSurface(51, 19)
            local ui = UI.new(surface)
            local state = UI.initialState()
            state.mode, state.page, state.setup_step = "setup", "setup", step
            state.setup_choices = {{label="something", detail="x"}}
            state.setup_choice_count = 1
            ui:render(state, {})
            local text = surface.allText()
            T.equal(text:find(generic, 1, true), nil, "step " .. step .. " has no prompt")
            T.contains(text, tostring(step) .. " / 10", "step " .. step .. " progress")
            T.equal(surface.writesOutsideBounds(), 0, "step " .. step .. " bounds")
        end
    end},
    {name="the monitor steps do not call themselves inventories",run=function()
        for _, step in ipairs({6, 7, 8}) do
            local surface = T.recordingSurface(51, 19)
            local ui = UI.new(surface)
            local state = UI.initialState()
            state.mode, state.page, state.setup_step = "setup", "setup", step
            state.setup_choices = {{label="Skip", detail="leave unbound"}}
            state.setup_choice_count = 1
            ui:render(state, {})
            T.equal(surface.allText():find("inventory", 1, true), nil,
                "step " .. step .. " is not an inventory step")
        end
    end},

    { name = "the wizard shows its progress and current step in the header", run = function()
        local surface = T.recordingSurface(51, 19)
        local screen = UI.new(surface)
        local state = UI.initialState()
        state.page, state.mode, state.setup_step = "setup", "setup", 3
        state.setup_choices = {{label="chest_1", detail="27 slots"}}
        screen:render(state, {})
        local text = surface.allText()
        T.contains(text, "SETUP")
        T.contains(text, "3 / 10")
        T.contains(text, "Assign Pickup")
        -- The step title is the focus colour, not the brand red the chrome uses. Brand red
        -- never signals state or position; that separation is the point of the palette.
        T.equal(surface.foregroundAt(2, 3), Theme.role.focus)
        T.equal(surface.writesOutsideBounds(), 0)
    end},

    {name="setup selection resets when the step changes but is kept within the same step",run=function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",4
        state.setup_choices={{label="a"},{label="b"},{label="c"}}
        state.setup_choice_count=3
        state.selection=3
        -- Re-syncing the same step (e.g. after toggling a storage node) keeps the highlight.
        state=ui:reduce(state,{type="SYNC_SETUP",step=4,
            choices={{label="a"},{label="b"},{label="c"},{label="d"}}})
        T.equal(state.selection,3)
        -- Advancing to a different step resets to the first row.
        state=ui:reduce(state,{type="SYNC_SETUP",step=5,
            choices={{label="Skip"},{label="e"}}})
        T.equal(state.selection,1)
    end},

    {name="Validate step renders a blocking issue with an alert marker",run=function()
        local surface = T.recordingSurface(51, 19)
        local ui = UI.new(surface)
        local state = UI.initialState()
        state.mode, state.page, state.setup_step = "setup", "setup", 9
        state.setup_choices = {
            {label="Run validation and continue", detail="moves no items"},
            {label="Assign a Drop-off inventory", blocking=true},
        }
        state.setup_choice_count = 2
        state.selection = 1
        ui:render(state, {})
        local markerRow
        for y = 1, 19 do
            if surface.line(y):find("Assign a Drop-off inventory", 1, true) then markerRow = y end
        end
        T.truthy(markerRow, "expected the blocking issue's row to be found")
        T.equal(surface.foregroundAt(3, markerRow), Theme.role.alert)
        T.equal(surface.writesOutsideBounds(), 0)
    end},

    {name="SYNC_SETUP carries the review summary alongside the step-10 choices",run=function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",9
        state=ui:reduce(state,{type="SYNC_SETUP",step=10,
            choices={{label="Save configuration and enable"}},
            summary={{label="Drop-off",detail="drop"},{label="Pickup",detail="pick"}}})
        T.equal(state.setup_step,10)
        T.equal(state.selection,1) -- the only choice, still highlighted by Task 1's reset-on-change rule
        T.equal(#state.setup_summary,2)
        T.equal(state.setup_summary[1].label,"Drop-off")
    end},
    {name="Review step renders the bound roles before the Save choice",run=function()
        local surface = T.recordingSurface(51, 19)
        local ui = UI.new(surface)
        local state = UI.initialState()
        state.mode, state.page, state.setup_step = "setup", "setup", 10
        state.setup_choices = {{label="Save configuration and enable", detail="starts immediately"}}
        state.setup_choice_count = 1
        state.selection = 1
        state.setup_summary = {
            {label="Drop-off", detail="drop"},
            {label="Pickup", detail="pick"},
            {label="Storage nodes", detail="2 enabled / 2 total"},
        }
        ui:render(state, {})
        -- Label and value render as a table row (label left, value right-aligned), not a
        -- joined "label: value" string, matching the same left/right convention every card
        -- and every other page's rows already use.
        local text = surface.allText()
        T.contains(text, "Drop-off")
        T.contains(text, "drop")
        T.contains(text, "Pickup")
        T.contains(text, "pick")
        T.contains(text, "Storage nodes")
        T.contains(text, "2 enabled / 2 total")
        T.contains(text, "Save configuration and enable")
        T.equal(surface.writesOutsideBounds(), 0)
    end},

    {name="OPEN_RENAME enters setup_rename mode pre-filled with the given text",run=function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",4
        state=ui:reduce(state,{type="OPEN_RENAME",node_id="storage_1",text="chest_3"})
        T.equal(state.mode,"setup_rename")
        T.equal(state.setup_rename_id,"storage_1")
        T.equal(state.setup_rename_text,"chest_3")
    end},
    {name="typing and confirming in rename mode produces the effect and clears on cancel",run=function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state=ui:reduce(state,{type="OPEN_RENAME",node_id="storage_1",text="chest_3"})
        state=ui:reduce(state,{type="RENAME_BACKSPACE"})
        T.equal(state.setup_rename_text,"chest_")
        state=ui:reduce(state,{type="RENAME_APPEND",text="9"})
        T.equal(state.setup_rename_text,"chest_9")
        local nextState,effect=ui:reduce(state,{type="RENAME_CONFIRM"})
        T.equal(effect.type,"RENAME_CONFIRM")
        T.equal(effect.node_id,"storage_1")
        T.equal(effect.text,"chest_9")
        local cancelState,cancelEffect=ui:reduce(state,{type="RENAME_CANCEL"})
        T.equal(cancelEffect.type,"RENAME_CANCEL")
        T.truthy(cancelState)
    end},
    {name="setup_rename renders a text prompt and its own footer",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup_rename","setup",4
        state.setup_rename_id,state.setup_rename_text="storage_1","chest_3"
        ui:render(state,{})
        local text=surface.allText()
        T.contains(text,"Name this storage node")
        T.contains(text,"chest_3")
        T.contains(text,"Enter save")
        T.equal(surface.writesOutsideBounds(),0)
    end},
    {name="SYNC_SETUP returns the wizard to setup mode, exiting any rename in progress",run=function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state=ui:reduce(state,{type="OPEN_RENAME",node_id="storage_1",text="chest_3"})
        T.equal(state.mode,"setup_rename")
        state=ui:reduce(state,{type="SYNC_SETUP",step=4,choices={}})
        T.equal(state.mode,"setup")
    end},

    {name="RENAME_STORAGE_REQUEST carries the current step and selection as an effect",run=function()
        local ui=UI.new(T.recordingSurface(51,19))
        local state=UI.initialState()
        state.mode,state.page,state.setup_step,state.selection="setup","setup",4,2
        local nextState,effect=ui:reduce(state,{type="RENAME_STORAGE_REQUEST"})
        T.equal(effect.type,"RENAME_STORAGE_REQUEST")
        T.equal(effect.step,4)
        T.equal(effect.index,2)
    end},
    {name="the storage step footer hints at R once choices exist",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",4
        state.setup_choices={{label="[added] a",detail="as \"Vault A\""}}
        state.setup_choice_count=1
        ui:render(state,{})
        T.contains(surface.allText(),"R rename")
    end},

    {name="UI:_row defaults to the ground background and accepts a custom one",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        ui:_row(5,false,1,51,nil,nil,"label",nil)
        T.equal(surface.backgroundAt(2,5),Theme.role.ground)
        ui:_row(6,false,1,51,nil,nil,"label",nil,nil,Theme.role.panel)
        T.equal(surface.backgroundAt(2,6),Theme.role.panel)
        ui:_row(7,true,1,51,nil,nil,"label",nil,nil,Theme.role.panel)
        T.equal(surface.backgroundAt(2,7),Theme.role.focus)
    end},

    {name="a long prompt wraps to multiple lines instead of being cut off",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        -- step 1's real prompt is 60 characters, well past the ~45-character card width.
        state.mode,state.page,state.setup_step="setup","setup",1
        state.setup_choices={{label="Continue with 3 inventories",detail="read-only discovery"}}
        state.setup_choice_count=1
        ui:render(state,{})
        local text=surface.allText()
        T.contains(text,"Read-only discovery of the wired inventories on")
        T.contains(text,"the network.")
        T.equal(surface.writesOutsideBounds(),0)
    end},
    {name="a long validation message wraps across both lines of its card",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",9
        state.setup_choices={
            {label="Run validation and continue",detail="moves no items"},
            {label="chest_4 and chest_6 may expose the same storage container",
                blocking=true,detail="Enter confirms distinct"},
        }
        state.setup_choice_count=2
        state.selection=1
        ui:render(state,{})
        local text=surface.allText()
        T.contains(text,"chest_4 and chest_6 may expose the same")
        T.contains(text,"storage container")
        T.equal(surface.writesOutsideBounds(),0)
    end},
    {name="the wizard content band is a panel-coloured card inset from the ground",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",2
        state.setup_choices={{name="drop",label="drop",detail="27 slots"}}
        state.setup_choice_count=1
        ui:render(state,{})
        -- Column 1 is the card's margin and is never drawn to; column 2 is inside the card.
        T.equal(surface.backgroundAt(1,5),nil)
        T.equal(surface.backgroundAt(2,5),Theme.role.panel)
        T.equal(surface.writesOutsideBounds(),0)
    end},
    {name="the section band inside the card uses the track colour",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",2
        state.setup_choices={{name="drop",label="drop",detail="27 slots"}}
        state.setup_choice_count=1
        ui:render(state,{})
        local bandRow
        for y=1,19 do if surface.line(y):find("INVENTORY",1,true) then bandRow=y end end
        T.truthy(bandRow,"expected an INVENTORY band somewhere on screen")
        T.equal(surface.backgroundAt(3,bandRow),Theme.role.track)
    end},
    {name="a selected card fills both its title and detail row",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",4
        state.setup_choices={{name="chest_0",label="[added] chest_0",detail="as \"Vault A\""}}
        state.setup_choice_count=1
        state.selection=1
        ui:render(state,{})
        -- "Vault A" is the detail text (card row 2); its title sits one row above it.
        local detailRow
        for y=1,19 do if surface.line(y):find("Vault A",1,true) then detailRow=y end end
        T.truthy(detailRow)
        T.equal(surface.backgroundAt(3,detailRow-1),Theme.role.focus)
        T.equal(surface.backgroundAt(3,detailRow),Theme.role.focus)
    end},
    {name="Review lists each bound role as label/value before the Save card",run=function()
        local surface=T.recordingSurface(51,19)
        local ui=UI.new(surface)
        local state=UI.initialState()
        state.mode,state.page,state.setup_step="setup","setup",10
        state.setup_choices={{label="Save configuration and enable",detail="starts immediately"}}
        state.setup_choice_count=1
        state.selection=1
        state.setup_summary={
            {label="Drop-off",detail="chest_0"},{label="Pickup",detail="chest_5"},
            {label="Storage nodes",detail="3 enabled / 3 total"},
        }
        ui:render(state,{})
        local text=surface.allText()
        T.contains(text,"Drop-off")
        T.contains(text,"chest_0")
        T.contains(text,"Save configuration and enable")
        T.equal(surface.writesOutsideBounds(),0)
    end},
}
