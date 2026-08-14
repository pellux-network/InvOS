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

local Draw = require("app.draw")
local Help = require("app.help")
local Keymap = require("app.keymap")
local UI = require("app.ui")
local T = require("tests.mock_cc")

-- Maps a registry entry's display `key` to one synthetic input event keymap.command
-- accepts. Groups ("Up/Down", "0-9", "1-6", "Left/Backspace", "Left/F10") test one
-- representative member -- the point is that the binding exists and is not refused in this
-- state, not that every member is tried.
local EVENTS = {
    ["F10"] = {"key", keys.f10}, ["F1"] = {"key", keys.f1}, ["P"] = {"key", keys.p},
    ["1-6"] = {"key", keys.two}, ["Delete"] = {"key", keys.delete},
    ["Enter"] = {"key", keys.enter}, ["Up/Down"] = {"key", keys.up}, ["S"] = {"key", keys.s},
    ["A"] = {"key", keys.a}, ["0-9"] = {"char", "5"}, ["C"] = {"key", keys.c},
    ["Tab"] = {"key", keys.tab}, ["D"] = {"key", keys.d}, ["Backspace"] = {"key", keys.backspace},
    ["F2"] = {"key", keys.f2},
    ["Left"] = {"key", keys.left}, ["R"] = {"key", keys.r}, ["Right"] = {"key", keys.right},
    ["Left/Backspace"] = {"key", keys.left}, ["Left/F10"] = {"key", keys.left},
}

-- Every distinct context an operator can be in when F1 opens Help, with whatever extra
-- state field that context's own `when` predicates key off (setup_step, recovery_confirm_armed).
-- "help" itself is included: TOGGLE_HELP can fire from any mode, so being inside Help is
-- itself a context an operator reaches, and its own registry entries deserve the same
-- keymap.command scrutiny as every other mode's.
local CONTEXTS = {
    {mode="search"}, {mode="quantity"}, {mode="variant"},
    {mode="craft_search"}, {mode="craft_quantity"}, {mode="craft_plan"},
    {mode="craft_jobs"}, {mode="setup", setup_step=4}, {mode="setup_rename"},
    {mode="page", page="storage"}, {mode="page", page="requests"},
    {mode="page", page="alerts"},
    {mode="page", page="alerts", recovery_confirm_armed=true},
    {mode="page", page="setup"},
    {mode="help"},
}

-- Every mode/page state.mode or state.page can actually take on, per ui.lua's reducer
-- (TOGGLE_HELP, OPEN_PAGE, OPEN_QUANTITY, OPEN_CRAFT_QUANTITY, CANCEL, SETUP_*, RENAME_*).
-- Kept separate from CONTEXTS above (which also carries `when`-predicate fields like
-- setup_step) so this list stays a plain inventory of reachable modes to check registry
-- coverage against, independent of any particular predicate state.
local REACHABLE_MODES = {
    "search", "quantity", "variant", "craft_search", "craft_quantity", "craft_plan",
    "craft_jobs", "setup", "setup_rename", "help",
}
local REACHABLE_PAGES = {"storage", "requests", "alerts", "setup"}

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

    -- Draw.wrap: the fix for defect (a), a long detail sentence hard-truncated mid-word
    -- because UI:_help drew it on exactly one row. Tested directly here rather than in
    -- tests/test_draw.lua, which this task does not own.
    {name="Draw.wrap: empty string yields one empty line", run=function()
        T.arrayEqual(Draw.wrap("", 10), {""})
        T.arrayEqual(Draw.wrap(nil, 10), {""})
    end},
    {name="Draw.wrap: a single word longer than width is hard-broken", run=function()
        T.arrayEqual(Draw.wrap("abcdefghij", 4), {"abcd", "efgh", "ij"})
    end},
    {name="Draw.wrap: exact-fit boundaries never split early", run=function()
        T.arrayEqual(Draw.wrap("ab cd", 5), {"ab cd"})
        T.arrayEqual(Draw.wrap("abcde", 5), {"abcde"})
        T.arrayEqual(Draw.wrap("abcdef", 5), {"abcde", "f"})
    end},
    {name="Draw.wrap: multiple spaces between words collapse to one", run=function()
        T.arrayEqual(Draw.wrap("one    two", 20), {"one two"})
    end},
    {name="Draw.wrap: width of 1 puts one character per line", run=function()
        T.arrayEqual(Draw.wrap("hi", 1), {"h", "i"})
    end},
    {name="Draw.wrap breaks only on whitespace and never drops a character", run=function()
        local text = "Give up proof of what an interrupted transfer moved and release recovery"
        local lines = Draw.wrap(text, 20)
        for _, line in ipairs(lines) do T.truthy(#line <= 20, "line exceeds width: " .. line) end
        T.equal(table.concat(lines, " "), text)
    end},

    -- Reproduces defect (a) directly: this is the exact detail string that used to be
    -- hard-truncated mid-sentence by a single Draw.text call at the remaining width. Scroll
    -- through a short terminal and confirm the whole sentence shows up somewhere, unclipped.
    {name="a long detail sentence is never truncated, only wrapped across rows", run=function()
        local surface = T.recordingSurface(30, 8)
        local ui = UI.new(surface)
        local state = UI.initialState()
        state.page, state.mode, state.recovery_confirm_armed = "alerts", "page", true
        state = ui:reduce(state, {type="TOGGLE_HELP"})
        local seen = {}
        for scroll = 1, 30 do
            state.help_scroll = scroll
            ui:render(state, {lifecycle="READY"})
            seen[#seen + 1] = surface.allText()
        end
        local all = table.concat(seen, "\n")
        local labelWidth = math.max(1, math.min(18, 30 - 3))
        local detailWidth = 30 - (3 + labelWidth)
        for _, line in ipairs(Draw.wrap(
            "Give up proof of what an interrupted transfer moved and release recovery",
            detailWidth)) do
            T.contains(all, line, "wrapped line missing or truncated: " .. line)
        end
    end},

    -- The flatten-then-window approach must never drop a row: every wrapped detail line and
    -- every section header has to appear somewhere as the operator scrolls, even at a height
    -- so small that no single section fits whole -- the old "show a section whole or not at
    -- all, else break" degradation is exactly what this replaces.
    {name="scrolling the help modal reveals every row without dropping any, even at a tiny height",
     run=function()
        for _, size in ipairs({{30, 8}, {30, 6}, {20, 8}}) do
            local width, height = size[1], size[2]
            local surface = T.recordingSurface(width, height)
            local ui = UI.new(surface)
            local state = UI.initialState()
            state = ui:reduce(state, {type="TOGGLE_HELP"})
            local seen = {}
            for scroll = 1, 60 do
                state.help_scroll = scroll
                ui:render(state, {lifecycle="READY"})
                seen[#seen + 1] = surface.allText()
                T.equal(surface.writesOutsideBounds(), 0)
            end
            local all = table.concat(seen, "\n")

            local labelWidth = math.max(1, math.min(18, width - 3))
            local detailWidth = width - (3 + labelWidth)
            local showDetail = detailWidth >= 6
            local sections = Help.modalSections({mode="search"})
            sections[#sections + 1] = {title = "This modal", entries = Help.per_mode.help}
            for _, section in ipairs(sections) do
                T.contains(all, section.title:upper(),
                    ("%dx%d dropped section header %q"):format(width, height, section.title))
                for _, entry in ipairs(section.entries) do
                    local label = entry.key .. (entry.label and (" " .. entry.label) or "")
                    T.contains(all, label,
                        ("%dx%d dropped entry label %q"):format(width, height, label))
                    if showDetail then
                        for _, line in ipairs(Draw.wrap(entry.detail, detailWidth)) do
                            T.contains(all, line, ("%dx%d dropped detail line %q"):
                                format(width, height, line))
                        end
                    end
                end
            end
        end
    end},

    -- Task 4: the modal must document its own controls, not just the page underneath it.
    -- Help mode accepts exactly two things -- close, and scroll -- so every registry entry
    -- must map to one of them and nothing else may slip through.
    {name="the help mode's own registry entries close or scroll the modal, nothing else",
     run=function()
        local entries = Help.per_mode.help
        T.truthy(#entries > 0, "help mode has no registry entries")
        local expected = {["Up/Down"]="MOVE", ["F1"]="TOGGLE_HELP", ["F10"]="TOGGLE_HELP"}
        for _, entry in ipairs(entries) do
            local event = EVENTS[entry.key]
            T.truthy(event, "no synthetic event mapped for key " .. tostring(entry.key))
            local command = Keymap.command(event, {mode="help"})
            T.truthy(command, entry.key .. " in help mode was refused outright")
            T.equal(command.type, expected[entry.key] or "TOGGLE_HELP",
                entry.key .. " in help mode produced the wrong command")
        end
    end},

    -- The modal scrolls, so both ways of asking it to must actually reach help_scroll. The
    -- keyboard half did not exist at all until the registry advertised it.
    {name="Up and Down scroll the help modal", run=function()
        local up = Keymap.command({"key", keys.up}, {mode="help"})
        local down = Keymap.command({"key", keys.down}, {mode="help"})
        T.equal(up.type, "MOVE", "Up in help mode is not a MOVE")
        T.equal(up.delta, -1, "Up in help mode scrolls the wrong way")
        T.equal(down.type, "MOVE", "Down in help mode is not a MOVE")
        T.equal(down.delta, 1, "Down in help mode scrolls the wrong way")

        local ui = UI.new(T.recordingSurface(51, 19))
        local state = UI.initialState()
        state.results, state.result_count, state.selection = {{}, {}, {}}, 3, 2
        state = ui:reduce(state, {type="TOGGLE_HELP"})
        state = ui:reduce(state, {type="MOVE", delta=1})
        T.equal(state.help_scroll, 2, "MOVE in help mode did not advance help_scroll")
    end},

    -- The live bug this fixes: mouse_scroll produces MOVE before keymap.command ever reaches
    -- its state.mode == "help" block, so with the modal open a wheel scroll used to fall
    -- through the reducer to the Search page's own branch and move a selection the operator
    -- could not see, under a modal that gave no sign anything had happened.
    {name="scrolling the help modal never moves the selection underneath it", run=function()
        local ui = UI.new(T.recordingSurface(51, 19))
        local state = UI.initialState()
        state.results, state.result_count, state.selection = {{}, {}, {}, {}}, 4, 2
        state = ui:reduce(state, {type="TOGGLE_HELP"})
        for _ = 1, 5 do state = ui:reduce(state, {type="MOVE", delta=1}) end
        T.equal(state.selection, 2, "help scrolling moved the hidden search selection")
        state = ui:reduce(state, {type="TOGGLE_HELP"})
        T.equal(state.mode, "search", "closing help did not restore the interrupted mode")
        T.equal(state.selection, 2, "the selection did not survive the help modal")
    end},

    -- Different modes have very different numbers of controls, so a stale offset from a long
    -- page's help would open a short page's help scrolled past everything it has to say.
    {name="opening help always starts at the top", run=function()
        local ui = UI.new(T.recordingSurface(51, 19))
        local state = UI.initialState()
        state = ui:reduce(state, {type="TOGGLE_HELP"})
        for _ = 1, 4 do state = ui:reduce(state, {type="MOVE", delta=1}) end
        T.truthy(state.help_scroll > 1, "help_scroll never advanced")
        state = ui:reduce(state, {type="TOGGLE_HELP"})
        state = ui:reduce(state, {type="TOGGLE_HELP"})
        T.equal(state.help_scroll, 1, "reopening help kept a stale scroll offset")
    end},

    -- help_scroll must never go below 1: _windowed clamps the top end against the row count
    -- it just built, but a negative offset is the reducer's own to prevent.
    {name="scrolling up past the top of the help modal clamps", run=function()
        local ui = UI.new(T.recordingSurface(51, 19))
        local state = UI.initialState()
        state = ui:reduce(state, {type="TOGGLE_HELP"})
        for _ = 1, 5 do state = ui:reduce(state, {type="MOVE", delta=-1}) end
        T.equal(state.help_scroll, 1, "help_scroll fell below the first row")
    end},

    -- Catches a mode ui.lua's reducer can reach that nobody ever added to help.lua: without
    -- this, a forgotten mode silently falls back to Help.contextEntries' empty-table
    -- default and the modal just shows nothing for it, with no test failure anywhere.
    {name="every mode and page reachable in the UI has a registry section", run=function()
        for _, mode in ipairs(REACHABLE_MODES) do
            T.truthy(Help.per_mode[mode], "no per_mode entry for mode=" .. mode)
        end
        for _, page in ipairs(REACHABLE_PAGES) do
            T.truthy(Help.per_mode.page[page], "no per_mode.page entry for page=" .. page)
        end
    end},
}
