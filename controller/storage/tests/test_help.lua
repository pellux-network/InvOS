-- CC exposes `keys` as a global; this module needs its own copy for the same reason
-- test_craft_ui.lua does (load order is not guaranteed across the suite).
keys = keys or {}
for name, code in pairs({
    backspace=14, up=200, down=208, enter=28, tab=15, s=31, a=30, d=32, f10=68, f1=59,
    escape=1, one=2, two=3, three=4, four=5, five=6, six=7,
    r=19, c=46, p=25, left=203, right=205, delete=211,
}) do
    if keys[name] == nil then keys[name] = code end
end

local Help = require("app.help")
local Keymap = require("app.keymap")
local UI = require("app.ui")
local T = require("tests.mock_cc")

-- Maps a registry entry's display `key` to one synthetic input event keymap.command
-- accepts. Groups ("Up/Down", "0-9", "1-6") test one representative member -- the point is
-- that the binding exists and is not refused in this state, not that every member is tried.
local EVENTS = {
    ["F10"] = {"key", keys.f10}, ["F1"] = {"key", keys.f1}, ["P"] = {"key", keys.p},
    ["1-6"] = {"key", keys.two}, ["Delete"] = {"key", keys.delete},
    ["Enter"] = {"key", keys.enter}, ["Up/Down"] = {"key", keys.up}, ["S"] = {"key", keys.s},
    ["A"] = {"key", keys.a}, ["0-9"] = {"char", "5"}, ["C"] = {"key", keys.c},
    ["Tab"] = {"key", keys.tab}, ["D"] = {"key", keys.d}, ["Backspace"] = {"key", keys.backspace},
    ["Left"] = {"key", keys.left}, ["R"] = {"key", keys.r}, ["Right"] = {"key", keys.right},
}

-- Every distinct context an operator can be in when F1 opens Help, with whatever extra
-- state field that context's own `when` predicates key off (setup_step, recovery_confirm_armed).
local CONTEXTS = {
    {mode="search"}, {mode="quantity"}, {mode="variant"},
    {mode="craft_search"}, {mode="craft_quantity"}, {mode="craft_plan"},
    {mode="craft_jobs"}, {mode="setup", setup_step=4}, {mode="setup_rename"},
    {mode="page", page="storage"}, {mode="page", page="requests"},
    {mode="page", page="alerts"},
    {mode="page", page="alerts", recovery_confirm_armed=true},
    {mode="page", page="setup"},
}

return {
    -- The invariant that makes the registry trustworthy: everything it lists must be
    -- something keymap.command actually accepts in that state, or the modal confidently
    -- advertises a key that does nothing.
    {name="every registry entry a context can show is accepted by keymap.command there",
     run=function()
        for _, context in ipairs(CONTEXTS) do
            for _, section in ipairs(Help.modalSections(context)) do
                for _, entry in ipairs(section.entries) do
                    local event = EVENTS[entry.key]
                    T.truthy(event, "no synthetic event mapped for key " .. tostring(entry.key))
                    local command = Keymap.command(event, context)
                    T.truthy(command, entry.key .. " " .. tostring(entry.label) ..
                        " in mode=" .. tostring(context.mode) .. " page=" .. tostring(context.page) ..
                        " produced no command")
                end
            end
        end
    end},
    {name="the footer never lists a non-important entry", run=function()
        for _, context in ipairs(CONTEXTS) do
            for _, entry in ipairs(Help.footerEntries(context)) do
                T.equal(entry.important, true, entry.key .. " is not important but is in the footer")
            end
        end
    end},
    -- The specific drift this task was written to fix: craft_search's footer used to claim
    -- "F10 back" even though keymap.lua refuses CANCEL in craft_search (the same exclusion
    -- as the Search page itself, since letters are query characters in both). The registry
    -- must not repeat that mistake now that it is the source of truth.
    {name="craft_search's footer does not advertise F10, matching keymap's refusal", run=function()
        local text = Help.footerText({mode="craft_search"}, 200)
        T.equal(text:find("F10", 1, true), nil, "craft_search footer claims F10 back: " .. text)
        T.contains(text, "Delete clear")
    end},
    {name="search's footer never advertises P or F10, matching keymap's refusal", run=function()
        local text = Help.footerText({mode="search"}, 200)
        T.equal(text:find("F10", 1, true), nil, text)
        T.equal(text:find(" P ", 1, true), nil, text)
    end},
    -- Two controls keymap.lua has always accepted in these modes but the old hand-written
    -- footer never mentioned: pausing while choosing a craft quantity, and F10/pause while
    -- reviewing craft jobs.
    {name="craft_quantity and craft_jobs advertise pause now that the registry drives them",
     run=function()
        T.contains(Help.footerText({mode="craft_quantity"}, 200), "P pause")
        T.contains(Help.footerText({mode="craft_jobs"}, 200), "P pause")
        T.contains(Help.footerText({mode="craft_jobs"}, 200), "F10 back")
    end},
    {name="TOGGLE_HELP opens from any mode and closing restores the exact prior state",
     run=function()
        local ui = UI.new(T.recordingSurface(51, 19))
        local state = UI.initialState()
        state.query, state.selection = "diamond", 3
        local opened = ui:reduce(state, {type="TOGGLE_HELP"})
        T.equal(opened.mode, "help")
        T.equal(opened.help_return_mode, "search")
        T.equal(opened.query, "diamond")
        T.equal(opened.selection, 3)
        local closed = ui:reduce(opened, {type="TOGGLE_HELP"})
        T.equal(closed.mode, "search")
        T.equal(closed.query, "diamond")
        T.equal(closed.selection, 3)
        T.equal(closed.help_return_mode, nil)
    end},
    {name="F1 opens help from inside the search box without touching the query", run=function()
        local state = {mode="search", query="dia"}
        local command = Keymap.command({"key", keys.f1}, state)
        T.equal(command.type, "TOGGLE_HELP")
    end},
    {name="F1 does not open help while a recovery release is armed", run=function()
        local state = {mode="page", page="alerts", recovery_confirm_armed=true}
        local command = Keymap.command({"key", keys.f1}, state)
        T.equal(command.type, "CANCEL_RECOVERY_RELEASE")
    end},
    {name="every other key is inert while the help modal is open", run=function()
        local state = {mode="help", help_return_mode="craft_search"}
        T.equal(Keymap.command({"char", "a"}, state), nil)
        T.equal(Keymap.command({"key", keys.enter}, state), nil)
        T.equal(Keymap.command({"key", keys.two}, state), nil)
        T.equal(Keymap.command({"key", keys.f10}, state).type, "TOGGLE_HELP")
        T.equal(Keymap.command({"key", keys.f1}, state).type, "TOGGLE_HELP")
    end},
    {name="the modal renders both sections and degrades without overflow at every size",
     run=function()
        for _, size in ipairs({{51,19},{30,12},{18,8},{80,24}}) do
            local surface = T.recordingSurface(size[1], size[2])
            local ui = UI.new(surface)
            local state = UI.initialState()
            state.query, state.results, state.result_count = "sto", {}, 0
            state = ui:reduce(state, {type="TOGGLE_HELP"})
            local layout = ui:render(state, {lifecycle="READY"})
            T.contains(surface.allText(), "HELP")
            T.equal(surface.writesOutsideBounds(), 0)
            T.truthy(#layout.hit_regions >= 1)
        end
    end},
    {name="the modal at a comfortable size shows both sections and their controls",
     run=function()
        local surface = T.recordingSurface(51, 19)
        local ui = UI.new(surface)
        local state = UI.initialState()
        state = ui:reduce(state, {type="TOGGLE_HELP"})
        ui:render(state, {lifecycle="READY"})
        local text = surface.allText()
        T.contains(text, "THIS PAGE")
        T.contains(text, "EVERYWHERE")
        T.contains(text, "Delete")
        T.contains(text, "retrieve")
    end},
    {name="clicking the help modal closes it", run=function()
        local surface = T.recordingSurface(51, 19)
        local ui = UI.new(surface)
        local state = UI.initialState()
        state = ui:reduce(state, {type="TOGGLE_HELP"})
        local layout = ui:render(state, {lifecycle="READY"})
        state.hit_regions = layout.hit_regions
        local command = Keymap.command({"mouse_click", 1, 5, 5}, state)
        T.equal(command.type, "TOGGLE_HELP")
    end},
}
