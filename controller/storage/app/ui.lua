local Draw = require("app.draw")
local Layout = require("app.layout")
local Theme = require("app.theme")
local Help = require("app.help")

local UI = {}
UI.__index = UI

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function formatNumber(value)
    local text = tostring(math.floor(tonumber(value) or 0))
    local sign, digits = text:match("^(-?)(%d+)$")
    if not digits then return text end
    local result = digits
    while true do
        local changed
        result, changed = result:gsub("^(%d+)(%d%d%d)", "%1,%2")
        if changed == 0 then break end
    end
    return sign .. result
end

-- Where a list of `count` items must start so that `selection` is on screen, given `visible`
-- rows. Computed at render time and discarded: writing a scroll offset back into state during
-- a render would make rendering impure, which tests/test_ui_purity.lua forbids.
-- Picks the widest label that fits rather than clipping one. A button reading "RETRIEV" is
-- worse than a narrower button that reads "RETRIEVE".
local function fittedLabel(width, options)
    for _, text in ipairs(options) do
        if #text <= width then return text end
    end
    return options[#options]:sub(1, math.max(0, width))
end

-- Greedy word wrap. A word longer than `width` is hard-cut rather than left to overflow --
-- today's vocabulary (peripheral names, short prose) never produces one, but a future long
-- identifier must not corrupt the layout. `maxLines`, when given, caps the return; content
-- past it is simply dropped, and the caller decides whether that's acceptable (the wizard's
-- card renderer prefers the wrapped message over its detail hint when both can't fit).
local function wrapText(text, width, maxLines)
    text = tostring(text or "")
    width = math.max(1, width or 1)
    local lines = {}
    local current = ""
    local capped = false
    for word in text:gmatch("%S+") do
        if maxLines and #lines >= maxLines then capped = true; break end
        local candidate = current == "" and word or (current .. " " .. word)
        if #candidate <= width then
            current = candidate
        else
            if current ~= "" then lines[#lines + 1] = current end
            while #word > width do
                if maxLines and #lines >= maxLines then capped = true; break end
                lines[#lines + 1] = word:sub(1, width)
                word = word:sub(width + 1)
            end
            current = capped and "" or word
        end
    end
    if not capped and current ~= "" then lines[#lines + 1] = current end
    if maxLines then
        for index = #lines, maxLines + 1, -1 do lines[index] = nil end
    end
    if #lines == 0 then lines[1] = "" end
    return lines
end

-- The window ends on the selection rather than starting on it, so arrowing down the list
-- scrolls under a cursor that stays put. Starting the window on the selection instead makes
-- the cursor jump to the top of a fresh page every time it reaches the bottom of one.
local function scrollFor(selection, count, visible)
    if visible < 1 then return 1 end
    selection = math.max(1, selection or 1)
    local maxScroll = math.max(1, (count or 0) - visible + 1)
    return math.max(1, math.min(selection - visible + 1, maxScroll))
end

function UI.new(surface)
    assert(type(surface) == "table" and type(surface.getSize) == "function",
        "terminal surface is required")
    return setmetatable({ surface=surface }, UI)
end

function UI.initialState()
    return {
        page="search", mode="search", query="", selection=1, scroll=1,
        quantity_text="", variant_selection=1, results={}, result_count=0,
        notice=nil, hit_regions={}, armed_selection=nil,
        request_selection=1, request_count=0, alert_selection=1, alert_count=0,
        storage_scroll=1, recovery_confirm_armed=false,
        craft_query="", craft_results={}, craft_result_count=0, craft_selection=1,
        craft_armed_selection=nil,
        craft_scroll=1, craft_quantity_text="", craft_item=nil, craft_plan=nil,
        craft_destination="pickup", craft_plan_selection=1,
        craft_jobs={}, craft_job_count=0, craft_job_selection=1,
    }
end

local function selectedResult(state)
    return state.results and state.results[state.selection] or nil
end

-- The autocomplete ghost is computed fresh every frame from the query and the highlighted
-- result, never stashed on state -- same discipline as scroll offsets. Only a literal
-- case-insensitive prefix gets a tail: search.lua/match.lua also match on abbreviation,
-- alias, registry name and edit distance, and none of those routes has a sensible tail to
-- show, so a highlighted row reached through one of them simply gets no ghost.
local function ghostTail(query, name)
    if query == "" or not name or name == "" then return nil end
    local queryLower, nameLower = query:lower(), name:lower()
    if nameLower:sub(1, #queryLower) ~= queryLower then return nil end
    local tail = name:sub(#query + 1)
    if tail == "" then return nil end
    return tail
end

local function enterQuantity(state, variant, parent)
    state.mode = "quantity"
    state.quantity_text = ""
    state.identity = copy(variant)
    state.identity.available = variant.quantity or parent.quantity or 0
    state.identity.max_count = variant.max_count or parent.max_count or 64
end

function UI:reduce(current, command)
    local state = copy(current)
    if type(command) ~= "table" then return state end
    local kind = command.type
    if kind == "SYNC_RESULTS" then
        state.results = copy(command.results or {})
        state.result_count = #state.results
        state.selection = math.max(1, math.min(state.selection, math.max(1, state.result_count)))
        state.scroll = math.min(state.scroll, state.selection)
    elseif kind == "QUERY_APPEND" then
        state.query = state.query .. tostring(command.text or "")
        state.selection, state.scroll, state.notice, state.suppress_char = 1, 1, nil, nil
        state.armed_selection = nil
    elseif kind == "CONSUME_CHAR" then
        state.suppress_char = nil
    elseif kind == "QUERY_BACKSPACE" then
        state.query = state.query:sub(1, math.max(0, #state.query - 1))
        state.selection, state.scroll, state.notice = 1, 1, nil
        state.armed_selection = nil
    elseif kind == "QUERY_CLEAR" then
        state.query = ""
        state.selection, state.scroll, state.notice = 1, 1, nil
        state.armed_selection = nil
    elseif kind == "MOVE" then
        if state.mode == "craft_search" then
            state.craft_selection = math.max(1, math.min(math.max(1, state.craft_result_count or 0),
                (state.craft_selection or 1) + command.delta))
        elseif state.mode == "craft_jobs" then
            state.craft_job_selection = math.max(1, math.min(math.max(1, state.craft_job_count or 0),
                (state.craft_job_selection or 1) + command.delta))
        elseif state.mode == "craft_plan" then
            local total = state.craft_plan and #(state.craft_plan.chosen or {}) or 0
            state.craft_plan_selection = math.max(1, math.min(math.max(1, total),
                (state.craft_plan_selection or 1) + command.delta))
        elseif state.mode == "variant" then
            state.variant_selection = math.max(1,
                math.min(#(state.variants or {}), state.variant_selection + command.delta))
        elseif state.page == "requests" then
            state.request_selection = math.max(1, math.min(math.max(1, state.request_count or 0),
                (state.request_selection or 1) + command.delta))
        elseif state.page == "alerts" then
            state.alert_selection = math.max(1, math.min(math.max(1, state.alert_count or 0),
                (state.alert_selection or 1) + command.delta))
        elseif state.page == "storage" then
            state.storage_scroll = math.max(1, (state.storage_scroll or 1) + command.delta)
        else
            state.selection = math.max(1,
                math.min(math.max(1, state.result_count or 0), state.selection + command.delta))
        end
    elseif kind == "SYNC_REQUESTS" then
        state.request_count = command.count or 0
        state.request_selection = math.max(1, math.min(state.request_selection or 1,
            math.max(1, state.request_count)))
    elseif kind == "SYNC_ALERTS" then
        state.alert_count = command.count or 0
        state.alert_selection = math.max(1, math.min(state.alert_selection or 1,
            math.max(1, state.alert_count)))
    elseif kind == "CRAFT_QUERY_APPEND" then
        state.craft_query = state.craft_query .. tostring(command.text or "")
        state.craft_selection, state.craft_scroll, state.suppress_char = 1, 1, nil
        state.craft_armed_selection = nil
    elseif kind == "CRAFT_QUERY_BACKSPACE" then
        state.craft_query = state.craft_query:sub(1, math.max(0, #state.craft_query - 1))
        state.craft_selection, state.craft_scroll = 1, 1
        state.craft_armed_selection = nil
    elseif kind == "CRAFT_QUERY_CLEAR" then
        state.craft_query = ""
        state.craft_selection, state.craft_scroll = 1, 1
        state.craft_armed_selection = nil
    elseif kind == "SYNC_CRAFT_RESULTS" then
        state.craft_results = copy(command.results or {})
        state.craft_result_count = #state.craft_results
        state.craft_selection = math.max(1,
            math.min(state.craft_selection, math.max(1, state.craft_result_count)))
        state.craft_scroll = math.min(state.craft_scroll, state.craft_selection)
    elseif kind == "SYNC_CRAFT_JOBS" then
        state.craft_jobs = copy(command.jobs or {})
        state.craft_job_count = #state.craft_jobs
        state.craft_job_selection = math.max(1,
            math.min(state.craft_job_selection or 1, math.max(1, state.craft_job_count)))
    elseif kind == "OPEN_CRAFT_QUANTITY" then
        local selected = state.craft_results and state.craft_results[state.craft_selection]
        if selected then
            state.craft_item = copy(selected)
            state.craft_quantity_text, state.mode = "", "craft_quantity"
        end
    elseif kind == "CRAFT_AUTOCOMPLETE" then
        -- Same reasoning as AUTOCOMPLETE on the Search page: Tab accepts the highlighted
        -- recipe exactly as Enter does, ghost or no ghost.
        local selected = state.craft_results and state.craft_results[state.craft_selection]
        if selected then
            state.craft_query = tostring(selected.display_name or selected.item)
            return self:reduce(state, {type="OPEN_CRAFT_QUANTITY"})
        end
    elseif kind == "SET_CRAFT_QUANTITY" then
        if #state.craft_quantity_text < 6 then
            state.craft_quantity_text = state.craft_quantity_text .. command.digit
        end
    elseif kind == "CRAFT_QUANTITY_BACKSPACE" then
        state.craft_quantity_text = state.craft_quantity_text:sub(1,
            math.max(0, #state.craft_quantity_text - 1))
    elseif kind == "CRAFT_QUANTITY_MAX" then
        state.suppress_char = command.char
        return state, {type="PLAN_CRAFT", item=state.craft_item and state.craft_item.item,
            quantity="max"}
    elseif kind == "PLAN_CRAFT" then
        local quantity = tonumber(state.craft_quantity_text)
        if state.craft_quantity_text == "" then quantity = 1 end
        if quantity and quantity >= 1 and quantity % 1 == 0 then
            return state, {type="PLAN_CRAFT",
                item=state.craft_item and state.craft_item.item, quantity=quantity}
        end
    elseif kind == "SYNC_CRAFT_PLAN" then
        state.craft_plan = copy(command.plan)
        state.craft_plan_selection = 1
        state.mode = "craft_plan"
        if command.item then state.craft_item = copy(command.item) end
    elseif kind == "TOGGLE_CRAFT_DESTINATION" then
        state.craft_destination = state.craft_destination == "storage" and "pickup" or "storage"
    elseif kind == "PIN_CRAFT_CHOICE" then
        local plan = state.craft_plan
        local chosen = plan and plan.chosen and plan.chosen[state.craft_plan_selection]
        if chosen then return state, {type="PIN_CRAFT_CHOICE", tag=chosen.tag, item=chosen.item} end
    elseif kind == "COMMIT_CRAFT" then
        local plan = state.craft_plan
        if plan and plan.ok then
            state.mode = "craft_jobs"
            return state, {type="COMMIT_CRAFT", item=plan.item, quantity=plan.quantity,
                destination=state.craft_destination, plan=copy(plan)}
        end
    elseif kind == "OPEN_CRAFT_JOBS" then
        state.mode = "craft_jobs"
    elseif kind == "OPEN_CRAFT_SEARCH" then
        state.mode, state.craft_plan = "craft_search", nil
    elseif kind == "RETRY_CRAFT" then
        return state, {type="RETRY_CRAFT", index=state.craft_job_selection}
    elseif kind == "CANCEL_CRAFT" then
        return state, {type="CANCEL_CRAFT", index=state.craft_job_selection}
    elseif kind == "CONFIRM_CRAFT" then
        return state, {type="CONFIRM_CRAFT", index=state.craft_job_selection}
    elseif kind == "OPEN_CRAFT_FOR_SELECTION" then
        -- Reached from the retrieval quantity prompt. Plan only the part storage cannot
        -- fill, so pressing C after asking for 64 with 10 in stock plans 54, not 64.
        local selected = selectedResult(state)
        state.suppress_char = command.char
        if selected then
            local wanted = tonumber(state.quantity_text) or 1
            local shortfall = math.max(1, wanted - (selected.quantity or 0))
            state.page, state.mode = "crafting", "craft_quantity"
            state.craft_item = {item=selected.name, display_name=selected.display_name}
            state.craft_quantity_text = tostring(shortfall)
            state.craft_plan = nil
            return state, {type="PLAN_CRAFT", item=selected.name, quantity=shortfall}
        end
    elseif kind == "OPEN_CRAFT_FOR" then
        -- The Search page shortcut: plan the shortfall for the highlighted item.
        state.page, state.mode = "crafting", "craft_quantity"
        state.craft_item = {item=command.item, display_name=command.display_name}
        state.craft_quantity_text = tostring(command.quantity or "")
        state.craft_plan = nil
        return state, {type="PLAN_CRAFT", item=command.item, quantity=command.quantity or 1}
    elseif kind == "RETRY_REQUEST" then
        return state, {type="RETRY_REQUEST",index=state.request_selection}
    elseif kind == "CANCEL_REQUEST" then
        return state, {type="CANCEL_REQUEST",index=state.request_selection}
    elseif kind == "DISMISS_ALERT" then
        return state, {type="DISMISS_ALERT",index=state.alert_selection}
    elseif kind == "TOGGLE_PAUSE" then
        return state, {type="TOGGLE_PAUSE"}
    elseif kind == "ARM_RECOVERY_RELEASE" then
        state.recovery_confirm_armed = true
        state.notice = "Press Enter to release recovery: gives up proof of what the " ..
            "interrupted transfer moved. Any other key cancels."
    elseif kind == "CANCEL_RECOVERY_RELEASE" then
        state.recovery_confirm_armed = false
        state.notice = nil
    elseif kind == "CONFIRM_RECOVERY_RELEASE" then
        -- Releasing recovery abandons proof of what an interrupted transfer moved, so the
        -- reducer enforces the arm itself rather than trusting whoever dispatched this.
        if not state.recovery_confirm_armed then return state end
        state.recovery_confirm_armed = false
        state.notice = "Recovery released"
        return state, {type="RESOLVE_RECOVERY"}
    elseif kind == "OPEN_QUANTITY" then
        local selected = selectedResult(state)
        if selected then
            if #(selected.variants or {}) > 1 then
                state.mode, state.variants, state.variant_selection =
                    "variant", copy(selected.variants), 1
            else
                enterQuantity(state, (selected.variants or {})[1] or selected, selected)
            end
        end
    elseif kind == "AUTOCOMPLETE" then
        -- Tab accepts the highlighted row exactly as Enter does: same target, same mode,
        -- same fresh quantity text. The ghost is only a display affordance -- this fires
        -- whether or not one is showing, so the fuzzy/alias/abbreviation case still works.
        local selected = selectedResult(state)
        if selected then
            state.query = tostring(selected.display_name or selected.name)
            return self:reduce(state, {type="OPEN_QUANTITY"})
        end
    elseif kind == "ACTIVATE" then
        if state.mode == "craft_jobs" then
            state.craft_job_selection = math.max(1, math.min(math.max(1, state.craft_job_count or 0),
                (state.craft_job_selection or 1) + command.delta))
        elseif state.mode == "craft_plan" then
            local total = state.craft_plan and #(state.craft_plan.chosen or {}) or 0
            state.craft_plan_selection = math.max(1, math.min(math.max(1, total),
                (state.craft_plan_selection or 1) + command.delta))
        elseif state.mode == "variant" then
            local selected = state.variants[state.variant_selection]
            if selected then enterQuantity(state, selected, selectedResult(state) or selected) end
        elseif state.mode == "search" and command.index then
            -- A click only highlights a row it isn't already armed on; clicking the same
            -- row again is what opens quantity, so the first click of a fresh selection
            -- never jumps ahead of the user.
            if command.index == state.armed_selection then
                return self:reduce(state, {type="OPEN_QUANTITY"})
            end
            state.selection, state.armed_selection = command.index, command.index
        elseif state.mode == "craft_search" and command.index then
            if command.index == state.craft_armed_selection then
                return self:reduce(state, {type="OPEN_CRAFT_QUANTITY"})
            end
            state.craft_selection, state.craft_armed_selection = command.index, command.index
        end
    elseif kind == "SET_QUANTITY" and state.mode == "quantity" then
        if #state.quantity_text < 9 then state.quantity_text = state.quantity_text .. command.digit end
    elseif kind == "QUANTITY_BACKSPACE" and state.mode == "quantity" then
        state.quantity_text = state.quantity_text:sub(1, math.max(0, #state.quantity_text - 1))
    elseif kind == "REQUEST" and state.mode == "quantity" then
        local available = state.identity.available or 0
        local quantity = command.quantity
        if quantity == "one" then quantity = math.min(1, available)
        elseif quantity == "stack" then quantity = math.min(state.identity.max_count or 64, available)
        elseif quantity == "all" then quantity = available end
        if type(quantity) == "number" and quantity >= 1 and quantity % 1 == 0 then
            state.mode, state.quantity_text = "search", ""
            state.suppress_char = command.char
            state.notice = "Queued " .. formatNumber(quantity) .. " " ..
                tostring(state.identity.display_name or state.identity.name or "item")
            return state, {type="CREATE_REQUEST",identity=copy(state.identity),quantity=quantity}
        end
        state.notice = "No available quantity to request"
    elseif kind == "OPEN_SETUP" then
        state.page, state.mode, state.setup_step = "setup", "setup", 1
        state.selection, state.setup_choices, state.setup_choice_count = 1, {}, 0
    elseif kind == "SYNC_SETUP" then
        state.mode = "setup"
        local newStep = command.step or state.setup_step or 1
        local changedStep = newStep ~= state.setup_step
        state.setup_step = newStep
        state.setup_choices = copy(command.choices or {})
        state.setup_choice_count = #state.setup_choices
        state.setup_issues = copy(command.issues or {})
        state.setup_summary = copy(command.summary or {})
        if changedStep then
            state.selection = 1
        else
            state.selection = math.max(1, math.min(state.selection,
                math.max(1, state.setup_choice_count)))
        end
    elseif kind == "OPEN_RENAME" then
        state.mode = "setup_rename"
        state.setup_rename_id = command.node_id
        state.setup_rename_text = tostring(command.text or "")
    elseif kind == "RENAME_APPEND" then
        state.setup_rename_text = (state.setup_rename_text or "") .. tostring(command.text or "")
    elseif kind == "RENAME_BACKSPACE" then
        local current = state.setup_rename_text or ""
        state.setup_rename_text = current:sub(1, math.max(0, #current - 1))
    elseif kind == "RENAME_CLEAR" then
        state.setup_rename_text = ""
    elseif kind == "RENAME_CONFIRM" then
        return state, {type="RENAME_CONFIRM", node_id=state.setup_rename_id,
            text=state.setup_rename_text}
    elseif kind == "RENAME_CANCEL" then
        return state, {type="RENAME_CANCEL"}
    elseif kind == "RENAME_STORAGE_REQUEST" then
        return state, {type="RENAME_STORAGE_REQUEST", step=state.setup_step, index=state.selection}
    elseif kind == "SETUP_MOVE" then
        state.selection = math.max(1, math.min(math.max(1, state.setup_choice_count or 0),
            state.selection + command.delta))
    elseif kind == "SETUP_SELECT" then
        return state, {type="SETUP_SELECT",step=state.setup_step,index=state.selection}
    elseif kind == "SETUP_ACTIVATE" then
        state.selection = math.max(1, math.min(math.max(1, state.setup_choice_count or 0),
            command.index or 1))
        return state, {type="SETUP_SELECT", step=state.setup_step, index=state.selection}
    elseif kind == "SETUP_NEXT" or kind == "SETUP_BACK" then
        return state, {type=kind,step=state.setup_step}
    elseif kind == "CANCEL_SETUP" then
        state.mode, state.page = "page", "setup"
        return state, {type="CANCEL_SETUP"}
    elseif kind == "CANCEL" then
        -- F10 pops exactly one level of the page it is pressed on rather than jumping
        -- anywhere else, so backing out of a plan (or a quantity/variant prompt) never
        -- loses the search that found it. At a root -- a plain page, or the Search/
        -- Crafting search box itself -- there is no level left to pop, so F10 is a no-op:
        -- pressing "1" is the only way to reach the Search page.
        if state.mode == "craft_plan" then
            state.mode, state.craft_plan = "craft_quantity", nil
        elseif state.mode == "craft_quantity" then
            state.mode, state.craft_quantity_text = "craft_search", ""
        elseif state.mode == "craft_jobs" then
            state.mode = "craft_search"
        elseif state.mode == "quantity" or state.mode == "variant" then
            state.mode, state.quantity_text, state.variants = "search", "", nil
        end
    elseif kind == "TOGGLE_HELP" then
        -- F1 opens Help from wherever the operator is and closing it must land back on the
        -- exact same screen, not just the same page -- a search mid-query or a craft plan
        -- half chosen must still be there, so the mode being interrupted is stashed rather
        -- than reconstructed.
        if state.mode == "help" then
            state.mode = state.help_return_mode or "search"
            state.help_return_mode = nil
        else
            state.help_return_mode = state.mode
            state.mode = "help"
        end
    elseif kind == "OPEN_PAGE" then
        state.page = command.page
        state.mode = command.page == "search" and "search" or "page"
        if command.page == "crafting" then
            -- The Crafting page is search-first: typing filters recipes immediately,
            -- exactly as the Search page does.
            state.mode = "craft_search"
            state.craft_plan, state.craft_item = nil, nil
        end
        state.notice, state.suppress_char = nil, command.suppress_char
    end
    return state
end

-- Six pages no longer fit a narrow monitor at full width, so the bar gives up its
-- spacing first and only then its longer labels. Every page keeps its digit visible:
-- a shortcut the header does not advertise is a shortcut nobody presses.
local NAV_PAGES = {
    {digit="1", long="SEARCH", short="SEARCH", page="search"},
    {digit="2", long="NODES", short="NODES", page="storage"},
    {digit="3", long="REQUESTS", short="REQS", page="requests"},
    {digit="4", long="ALERTS", short="ALERTS", page="alerts"},
    {digit="5", long="SETUP", short="SETUP", page="setup"},
    {digit="6", long="CRAFTING", short="CRAFT", page="crafting"},
}

-- The page you are on is filled, because a bar whose six entries all look identical tells
-- you nothing about where you are.
function UI:_nav(state, regions, hitRegions)
    local surface = self.surface
    for _, label in ipairs({"long", "short"}) do
        for _, gap in ipairs({2, 1}) do
            local total = -gap
            for _, entry in ipairs(NAV_PAGES) do
                total = total + #entry.digit + 1 + #entry[label] + gap
            end
            if total <= regions.width - 2 then
                local x = 2
                for _, entry in ipairs(NAV_PAGES) do
                    local text = entry.digit .. " " .. entry[label]
                    local active = entry.page == state.page
                    Draw.text(surface, x, regions.nav, text, #text,
                        active and Theme.role.ground or Theme.role.muted,
                        active and Theme.role.focus or Theme.role.ground)
                    if hitRegions then
                        -- No suppress_char: that field exists to swallow the char event a
                        -- digit key produces, and a mouse click produces none.
                        hitRegions[#hitRegions + 1] = {x1=x, y1=regions.nav,
                            x2=x + #text - 1, y2=regions.nav,
                            command={type="OPEN_PAGE", page=entry.page}}
                    end
                    x = x + #text + gap
                end
                return
            end
        end
    end
end

-- A labelled section band. Structure in this UI is background colour or it is nothing: the
-- CC font has no box-drawing characters, so a heading is a filled row with text on it.
function UI:_band(y) Draw.band(self.surface, y, Theme.role.panel) end

function UI:_bandText(x, y, text, width)
    Draw.text(self.surface, x, y, text, width, Theme.role.muted, Theme.role.panel)
end

-- Draws a scrolling selectable list into rows `top` through `bottom`, calling
-- `render(index, y, selected)` for each visible row. Returns the scroll offset and the window
-- height so a caller can map a click back to an index. The offset is returned, never stored:
-- a render that mutates state is what tests/test_ui_purity.lua forbids.
-- The windowing half, for a list that scrolls by an explicit offset rather than by a
-- selection. The Nodes page has no selection: it scrolls with the arrow keys directly.
function UI:_windowed(top, bottom, count, scroll, render)
    local visible = math.max(0, bottom - top + 1)
    scroll = math.max(1, math.min(scroll or 1, math.max(1, (count or 0) - visible + 1)))
    for offset = 0, visible - 1 do
        local index = scroll + offset
        if index > (count or 0) then break end
        render(index, top + offset)
    end
    return scroll, visible
end

function UI:_list(top, bottom, count, selection, render)
    local visible = math.max(0, bottom - top + 1)
    return self:_windowed(top, bottom, count, scrollFor(selection, count, visible),
        function(index, y) render(index, y, index == selection) end)
end

-- One list row: an optional status marker, a name, and a right-aligned value. Selection is a
-- filled row in the focus colour with inverted text -- the same on every page. The pages used
-- to disagree, Search filling red and Crafting filling grey, which read as two products.
-- `baseBg` lets a caller draw on something other than the ground colour (the setup wizard's
-- panel-toned card) without changing the four pages that don't pass it.
--
-- `scrollOnlySelected` restricts marqueeing to the highlighted row: on Search and Craft, a
-- whole screen of long names all sliding at once is noisy to read and every row wants your
-- eye at a different moment. Every other list (Requests, Alerts, Nodes, craft jobs/plan,
-- variant pickers) leaves it unset, so every row keeps scrolling regardless of selection --
-- there is no "current" row on those pages the way there is on a search result.
function UI:_row(y, selected, from, to, marker, markerColor, left, right, rightColor, baseBg,
    scrollOnlySelected)
    local surface = self.surface
    local background = selected and Theme.role.focus or (baseBg or Theme.role.ground)
    local primary = selected and Theme.role.ground or Theme.role.text
    Draw.band(surface, y, background, from, to)
    if marker then
        Draw.text(surface, from + 1, y, marker, 1,
            selected and Theme.role.ground or (markerColor or Theme.role.muted), background)
    end
    right = right and tostring(right) or nil
    local nameWidth = math.max(1, (to - from + 1) - #(right or "") - 4)
    if scrollOnlySelected and not selected then
        Draw.text(surface, from + 3, y, left, nameWidth, primary, background)
    elseif Draw.marqueeText(surface, from + 3, y, left, nameWidth, primary, background, self._now) then
        self._animating = true
    end
    if right then
        Draw.rightText(surface, to - 1, y, right,
            selected and Theme.role.ground or (rightColor or Theme.role.muted), background)
    end
end

-- Like _windowed, but each item occupies `rows` physical rows instead of one -- the
-- wizard's cards need a second line for detail text or a wrapped continuation. _list and
-- _windowed themselves are untouched; every other page keeps its one-row-per-item math.
function UI:_cardWindow(top, bottom, count, selection, rows, render)
    local visible = math.max(0, math.floor((bottom - top + 1) / rows))
    local scroll = scrollFor(selection, count, visible)
    for offset = 0, visible - 1 do
        local index = scroll + offset
        if index > count then break end
        render(index, top + offset * rows)
    end
    return scroll, visible
end

-- A card's second physical row: fills with the same selection-state background UI:_row
-- uses, so a selected card highlights as one solid two-row block, not a highlighted title
-- over a plain detail line.
function UI:_cardDetail(y, selected, from, to, text, baseBg)
    local surface = self.surface
    local background = selected and Theme.role.focus or (baseBg or Theme.role.ground)
    Draw.band(surface, y, background, from, to)
    if text and text ~= "" then
        Draw.text(surface, from + 3, y, tostring(text), math.max(1, (to - from + 1) - 4),
            selected and Theme.role.ground or Theme.role.muted, background)
    end
end

-- Drop-off and Pickup levels, on every page, because they are the two numbers you always want
-- and a page switch to read them is a page switch too many. Occupancy comes from model.nodes
-- by role: model.dropoff and model.pickup are built by Coordinator:_nodeForRole, which does
-- not merge the scan snapshot, so their size and occupied are nil.
local function nodeByRole(model, role)
    for _, node in ipairs((model or {}).nodes or {}) do
        if node.role == role then return node end
    end
end

function UI:_strip(regions, model)
    if not regions.strip then return end
    local surface = self.surface
    Draw.band(surface, regions.strip, Theme.role.panel)
    local half = math.floor(regions.width / 2)
    local function gauge(x, width, label, node)
        local size = (node or {}).size or 0
        local occupied = (node or {}).occupied or 0
        local fraction = size > 0 and (occupied / size) or 0
        local percent = tostring(math.floor(fraction * 100 + 0.5)) .. "%"
        Draw.text(surface, x, regions.strip, label, #label, Theme.role.muted, Theme.role.panel)
        local meterX = x + #label + 1
        local meterWidth = math.max(0, width - #label - #percent - 3)
        if meterWidth > 0 then
            local fill = fraction >= 0.9 and Theme.role.alert
                or (fraction >= 0.75 and Theme.role.warn or Theme.role.ok)
            Draw.meter(surface, meterX, regions.strip, meterWidth, fraction,
                fill, Theme.role.track)
        end
        Draw.text(surface, meterX + meterWidth + 1, regions.strip, percent, #percent,
            Theme.role.text, Theme.role.panel)
    end
    gauge(2, half - 2, "DROP-OFF", nodeByRole(model, "dropoff"))
    gauge(half + 1, half - 2, "PICKUP", nodeByRole(model, "pickup"))
end

function UI:_header(state, model, hitRegions)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    Draw.band(surface, regions.header, Theme.role.panel)
    Draw.text(surface, 2, regions.header, "INVOS", 20, Theme.role.brand, Theme.role.panel)
    local lifecycle = model.lifecycle or "BOOTING"
    Draw.rightText(surface, regions.width - 1, regions.header, lifecycle,
        Theme.statusColor(lifecycle), Theme.role.panel)
    Draw.band(surface, regions.nav, Theme.role.ground)
    self:_nav(state, regions, hitRegions)
end

local function enrichmentText(enrichment)
    if not enrichment then return nil end
    return "Learning item names: " .. formatNumber(enrichment.learned) .. "/" .. formatNumber(enrichment.total)
end

function UI:_footer(state, model)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    if regions.height < 2 then return end
    Draw.band(surface, regions.footer, Theme.role.panel)
    Draw.text(surface, 2, regions.footer, Help.footerText(state, regions.width - 2), regions.width - 2,
        Theme.role.text, Theme.role.panel)
    Draw.band(surface, regions.status, Theme.role.ground)
    Draw.text(surface, 2, regions.status,
        state.notice or enrichmentText(model.enrichment) or model.lifecycle_reason or "",
        regions.width - 2,
        state.notice and Theme.role.alert or Theme.role.muted, Theme.role.ground)
end

function UI:_search(state, model, hitRegions)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    local split = regions.split
    local listTo = split and (split - 1) or regions.width
    local paneFrom = split and (split + 2) or nil

    local results = model.search_results or state.results or {}

    local queryRow = regions.content.top + 1
    local queryBoxWidth = regions.width - 4
    local queryText = state.query .. (state.mode == "search" and "_" or "")
    Draw.band(surface, queryRow, Theme.role.ground)
    Draw.text(surface, 2, queryRow, ">", 1, Theme.role.focus, Theme.role.ground)
    Draw.text(surface, 4, queryRow, queryText, queryBoxWidth, Theme.role.text, Theme.role.ground)
    if state.mode == "search" then
        local highlighted = results[state.selection]
        local tail = highlighted and
            ghostTail(state.query, tostring(highlighted.display_name or highlighted.name))
        local ghostWidth = queryBoxWidth - #queryText
        if tail and ghostWidth > 0 then
            Draw.text(surface, 4 + #queryText, queryRow, tail, ghostWidth,
                Theme.role.ghost, Theme.role.ground)
        end
    end

    local bandRow = queryRow + 2
    local bodyTop = bandRow + 1
    self:_band(bandRow)
    self:_bandText(2, bandRow, "ITEM", math.max(1, listTo - 2))
    Draw.rightText(surface, listTo - 1, bandRow, "STOCK", Theme.role.muted, Theme.role.panel)
    if paneFrom then
        self:_bandText(paneFrom, bandRow, "SELECTED", regions.width - paneFrom)
        Draw.divider(surface, split, bandRow, regions.content.bottom, Theme.role.panel)
    end

    if #results == 0 then
        Draw.text(surface, 2, bodyTop,
            state.query == "" and "Start typing to search stored items" or "No matching items",
            regions.width - 3, Theme.role.muted, Theme.role.ground)
        self:_strip(regions, model)
        return
    end

    self:_list(bodyTop, regions.content.bottom, #results, state.selection,
        function(index, y, selected)
            local item = results[index]
            self:_row(y, selected, 1, listTo, selected and ">" or nil, nil,
                tostring(item.display_name or item.name), formatNumber(item.quantity),
                nil, nil, true)
            hitRegions[#hitRegions + 1] = {x1=1, y1=y, x2=listTo, y2=y,
                command={type="ACTIVATE", index=index}}
        end)

    local selected = results[state.selection]
    if paneFrom and selected then
        local paneWidth = regions.width - paneFrom
        if Draw.marqueeText(surface, paneFrom, bodyTop, tostring(selected.display_name or selected.name),
            paneWidth, Theme.role.focus, Theme.role.ground, self._now) then
            self._animating = true
        end
        if Draw.marqueeText(surface, paneFrom, bodyTop + 1, tostring(selected.name), paneWidth,
            Theme.role.muted, Theme.role.ground, self._now) then
            self._animating = true
        end
        Draw.text(surface, paneFrom, bodyTop + 3, "STOCK", paneWidth,
            Theme.role.muted, Theme.role.ground)
        -- Measured against the largest item currently on screen, not against a fixed
        -- constant. Nothing here has a real ceiling -- an item can always be stored more of
        -- -- so an absolute bar can only be arbitrary. Relative to what you are looking at,
        -- the bar answers a question you actually have: is this a lot, or is it a little?
        local largest = 0
        for _, item in ipairs(results) do largest = math.max(largest, item.quantity or 0) end
        Draw.meter(surface, paneFrom, bodyTop + 4, math.max(1, paneWidth - 1),
            largest > 0 and ((selected.quantity or 0) / largest) or 0,
            Theme.role.ok, Theme.role.track)
        Draw.text(surface, paneFrom, bodyTop + 5, formatNumber(selected.quantity) .. " stored",
            paneWidth, Theme.role.text, Theme.role.ground)
        local perStack = selected.max_count or 64
        if perStack > 1 then
            local stacks = math.floor((selected.quantity or 0) / perStack)
            local loose = (selected.quantity or 0) % perStack
            local text = formatNumber(stacks) .. " stacks"
            if loose > 0 then text = text .. " + " .. loose end
            Draw.text(surface, paneFrom, bodyTop + 6, text, paneWidth,
                Theme.role.muted, Theme.role.ground)
        end
        local variants = #(selected.variants or {})
        if variants > 1 then
            Draw.text(surface, paneFrom, bodyTop + 8, variants .. " exact variants", paneWidth,
                Theme.role.muted, Theme.role.ground)
        end
        local button = fittedLabel(paneWidth,
            {"  ENTER  RETRIEVE ", " ENTER RETRIEVE ", " RETRIEVE ", "RETRIEVE"})
        local buttonRow = math.min(regions.content.bottom, bodyTop + 10)
        Draw.text(surface, paneFrom, buttonRow, button,
            math.min(#button, paneWidth), Theme.role.text, Theme.role.brand)
        hitRegions[#hitRegions + 1] = {x1=paneFrom, y1=buttonRow,
            x2=paneFrom + #button - 1, y2=buttonRow, command={type="OPEN_QUANTITY"}}
    end
    self:_strip(regions, model)
end

-- Nodes, requests and alerts share one fixed content band (row 5 through height-2).
-- Keeping the geometry in one place keeps their scrolling consistent with each other.
local function listBand(height)
    local bodyTop, bodyBottom = 5, height - 2
    return bodyTop, math.max(0, bodyBottom - bodyTop + 1)
end

function UI:_storage(state, model, hitRegions)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    local bandRow = regions.content.top
    self:_band(bandRow)
    self:_bandText(2, bandRow, "NODE", regions.width - 2)
    Draw.rightText(surface, regions.width - 1, bandRow, "USED", Theme.role.muted, Theme.role.panel)
    local nodes = model.nodes or {}
    if #nodes == 0 then
        Draw.text(surface, 2, bandRow + 1, "No storage nodes configured", regions.width - 3,
            Theme.role.muted, Theme.role.ground)
        Draw.text(surface, 2, bandRow + 2, "Open Setup to add a storage node",
            regions.width - 3, Theme.role.muted, Theme.role.ground)
        return
    end
    -- A meter is worth more than the raw slot counts here: "62%" answers the question, and
    -- "420 / 3,075 slots" makes you do the arithmetic yourself.
    local meterWidth = math.max(0, math.min(10, regions.width - 26))
    local meterX = regions.width - meterWidth - 6
    self:_windowed(bandRow + 1, regions.content.bottom, #nodes,
        (state or {}).storage_scroll or 1, function(index, y)
            local node = nodes[index]
            local size = node.size or 0
            local fraction = size > 0 and ((node.occupied or 0) / size) or 0
            local percent = tostring(math.floor(fraction * 100 + 0.5)) .. "%"
            Draw.band(surface, y, Theme.role.ground)
            Draw.text(surface, 2, y, "o", 1, Theme.statusColor(node.state), Theme.role.ground)
            Draw.text(surface, 4, y, tostring(node.label or node.id),
                math.max(1, meterX - 5), Theme.role.text, Theme.role.ground)
            if meterWidth > 0 then
                local fill = fraction >= 0.9 and Theme.role.alert
                    or (fraction >= 0.75 and Theme.role.warn or Theme.role.ok)
                Draw.meter(surface, meterX, y, meterWidth, fraction, fill, Theme.role.track)
            end
            Draw.rightText(surface, regions.width - 1, y, percent,
                Theme.role.muted, Theme.role.ground)
            -- The Nodes page scrolls by offset rather than selection, so a click scrolls to
            -- put the clicked row at the top rather than selecting it.
            hitRegions[#hitRegions + 1] = {x1=1, y1=y, x2=regions.width, y2=y,
                command={type="MOVE", delta=index - ((state or {}).storage_scroll or 1)}}
        end)
    self:_strip(regions, model)
end

function UI:_requests(state, model, hitRegions)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    local bandRow = regions.content.top
    self:_band(bandRow)
    self:_bandText(2, bandRow, "REQUEST", regions.width - 2)
    Draw.rightText(surface, regions.width - 1, bandRow, "PROGRESS",
        Theme.role.muted, Theme.role.panel)
    local requests = model.requests or {}
    if #requests == 0 then
        Draw.text(surface, 2, bandRow + 1, "No requests yet", regions.width - 3,
            Theme.role.muted, Theme.role.ground)
        Draw.text(surface, 2, bandRow + 2, "Press 1 and search for an item to retrieve",
            regions.width - 3, Theme.role.muted, Theme.role.ground)
        self:_strip(regions, model)
        return
    end
    self:_list(bandRow + 1, regions.content.bottom, #requests,
        math.max(1, math.min(#requests, (state or {}).request_selection or 1)),
        function(index, y, selected)
            local request = requests[index]
            local progress = formatNumber(request.delivered or 0) .. " / " ..
                formatNumber(request.requested or 0)
            self:_row(y, selected, 1, regions.width, "o", Theme.statusColor(request.state),
                tostring(request.display_name or request.id), progress)
            hitRegions[#hitRegions + 1] = {x1=1, y1=y, x2=regions.width, y2=y,
                command={type="MOVE", delta=index - (state.request_selection or 1)}}
        end)
    self:_strip(regions, model)
end

function UI:_alerts(state, model, hitRegions)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    local bandRow = regions.content.top
    self:_band(bandRow)
    self:_bandText(2, bandRow, "ALERT", regions.width - 2)
    local alerts = model.alerts or {}
    if #alerts == 0 then
        Draw.text(surface, 2, bandRow + 1, "No active alerts", regions.width - 3,
            Theme.role.ok, Theme.role.ground)
        Draw.text(surface, 2, bandRow + 2, "Storage conditions are healthy",
            regions.width - 3, Theme.role.muted, Theme.role.ground)
        self:_strip(regions, model)
        return
    end
    self:_list(bandRow + 1, regions.content.bottom, #alerts,
        math.max(1, math.min(#alerts, (state or {}).alert_selection or 1)),
        function(index, y, selected)
            local alert = alerts[index]
            local severity = alert.severity == "critical" and Theme.role.alert or Theme.role.warn
            self:_row(y, selected, 1, regions.width,
                "!", severity, tostring(alert.message), nil)
            hitRegions[#hitRegions + 1] = {x1=1, y1=y, x2=regions.width, y2=y,
                command={type="MOVE", delta=index - (state.alert_selection or 1)}}
        end)
    self:_strip(regions, model)
end

function UI:_setup(model)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    local bandRow = regions.content.top
    self:_band(bandRow)
    self:_bandText(2, bandRow, "SETUP", regions.width - 2)
    Draw.text(surface, 2, bandRow + 2, "Review or change inventory roles", regions.width - 3,
        Theme.role.text, Theme.role.ground)
    local function roleLine(y, label, node)
        local state = (node or {}).state or "unassigned"
        Draw.text(surface, 2, y, label, 12, Theme.role.muted, Theme.role.ground)
        Draw.text(surface, 14, y, tostring(state), regions.width - 15,
            Theme.statusColor(state), Theme.role.ground)
    end
    roleLine(bandRow + 4, "Drop-off", model.dropoff)
    roleLine(bandRow + 5, "Pickup", model.pickup)
    Draw.text(surface, 2, bandRow + 7, "Enter opens the full setup wizard", regions.width - 3,
        Theme.role.muted, Theme.role.ground)
end

function UI:_overlay(state)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    if regions.split then
        self:_panePrompt(state, regions)
    else
        self:_boxPrompt(state, regions)
    end
end

function UI:_panePrompt(state, regions)
    local surface = self.surface
    local paneFrom = regions.split + 2
    local paneWidth = regions.width - paneFrom
    local top = regions.content.top + 4
    for y = top, regions.content.bottom do
        Draw.band(surface, y, Theme.role.ground, paneFrom, regions.width)
    end
    if state.mode == "quantity" then
        Draw.text(surface, paneFrom, top, "Retrieve", paneWidth,
            Theme.role.focus, Theme.role.ground)
        Draw.text(surface, paneFrom, top + 1,
            tostring(state.identity.display_name or state.identity.name), paneWidth,
            Theme.role.text, Theme.role.ground)
        Draw.text(surface, paneFrom, top + 2,
            formatNumber(state.identity.available) .. " available", paneWidth,
            Theme.role.muted, Theme.role.ground)
        Draw.text(surface, paneFrom, top + 4,
            "Amount: " .. (state.quantity_text ~= "" and state.quantity_text or "_"), paneWidth,
            Theme.role.text, Theme.role.ground)
        Draw.text(surface, paneFrom, top + 6, "Enter 1   S stack", paneWidth,
            Theme.role.muted, Theme.role.ground)
        Draw.text(surface, paneFrom, top + 7, "A all   F10 back", paneWidth,
            Theme.role.muted, Theme.role.ground)
    elseif state.mode == "variant" then
        Draw.text(surface, paneFrom, top, "Exact variant", paneWidth,
            Theme.role.focus, Theme.role.ground)
        local variants = state.variants or {}
        self:_list(top + 1, math.min(regions.content.bottom - 1, top + 6), #variants,
            state.variant_selection, function(index, y, selected)
                self:_row(y, selected, paneFrom - 1, regions.width, nil, nil,
                    tostring(variants[index].display_name), nil)
            end)
        Draw.text(surface, paneFrom, regions.content.bottom, "Enter select   F10 back",
            paneWidth, Theme.role.muted, Theme.role.ground)
    end
end

function UI:_boxPrompt(state, regions)
    local surface = self.surface
    local boxWidth = math.min(40, regions.width - 4)
    if boxWidth < 18 then return end
    local left = math.floor((regions.width - boxWidth) / 2) + 1
    local top = math.max(regions.content.top, math.floor((regions.height - 7) / 2))
    for y = top, math.min(regions.content.bottom, top + 6) do
        Draw.band(surface, y, Theme.role.panel, left, left + boxWidth - 1)
    end
    if state.mode == "quantity" then
        Draw.text(surface, left + 2, top, "Retrieve " ..
            tostring(state.identity.display_name or state.identity.name), boxWidth - 4,
            Theme.role.focus, Theme.role.panel)
        Draw.text(surface, left + 2, top + 1,
            formatNumber(state.identity.available) .. " available", boxWidth - 4,
            Theme.role.text, Theme.role.panel)
        Draw.text(surface, left + 2, top + 2,
            "Amount: " .. (state.quantity_text ~= "" and state.quantity_text or "_"),
            boxWidth - 4, Theme.role.text, Theme.role.panel)
        Draw.text(surface, left + 2, top + 4, "Enter 1   S stack   A all", boxWidth - 4,
            Theme.role.muted, Theme.role.panel)
        Draw.text(surface, left + 2, top + 5, "Digits exact   F10 back", boxWidth - 4,
            Theme.role.muted, Theme.role.panel)
        if boxWidth - 4 < 25 then
            -- 25 characters of hint do not fit a 30-column terminal, and the clipped
            -- remainder silently dropped "A all" -- the one shortcut worth knowing.
            Draw.text(surface, left + 2, top + 4, "Enter 1   S stack", boxWidth - 4,
                Theme.role.muted, Theme.role.panel)
            Draw.text(surface, left + 2, top + 5, "A all   F10 back", boxWidth - 4,
                Theme.role.muted, Theme.role.panel)
        end
    elseif state.mode == "variant" then
        Draw.text(surface, left + 2, top, "Choose exact variant", boxWidth - 4,
            Theme.role.focus, Theme.role.panel)
        for index, variant in ipairs(state.variants or {}) do
            if index > 4 then break end
            local selected = index == state.variant_selection
            self:_row(top + index, selected, left, left + boxWidth - 1, nil, nil,
                tostring(variant.display_name), nil)
        end
        Draw.text(surface, left + 2, top + 5, "Enter select   F10 back", boxWidth - 4,
            Theme.role.muted, Theme.role.panel)
    end
end

function UI:_setupWizard(state, model)
    local surface = self.surface
    -- One title and one prompt per step. Both lists must cover every step: a missing
    -- entry falls back to a generic "select an inventory" line, which is actively wrong
    -- on the turtle and monitor steps and reads as if the wizard is asking again for a
    -- chest it already has.
    local names = {
        "Discover inventories", "Assign Drop-off", "Assign Pickup", "Storage nodes",
        "Craft buffer (optional)", "Crafting turtle (optional)",
        "Main monitor (optional)", "Crafting monitor (optional)",
        "Validate layout", "Review and enable",
    }
    local prompts = {
        "Read-only discovery of the wired inventories on the network.",
        "The inventory players deposit into, for importing.",
        "The inventory retrievals are delivered to, for collecting.",
        "Toggle which inventories pool together as storage.",
        "The chest directly beneath the crafting turtle. Not Pickup.",
        "The crafting turtle itself, not a chest.",
        "The large status monitor. Skip to auto-detect.",
        "The small monitor showing craft progress. Not a chest.",
        "Read-only validation. Moves no items.",
        "Save the configuration and start.",
    }
    -- A band adds nothing on a single-choice step (Discover, Review's lone Save card), so
    -- those stay nil.
    local bandLabels = {
        nil, "INVENTORY", "INVENTORY", "INVENTORY",
        "INVENTORY", "TURTLE", "MONITOR", "MONITOR",
        "CHECKS", nil,
    }
    local step = state.setup_step or 1
    local regions = Layout.regions(surface.getSize())
    local hitRegions = {}

    Draw.band(surface, regions.header, Theme.role.panel)
    Draw.text(surface, 2, regions.header, "SETUP WIZARD", 20, Theme.role.brand, Theme.role.panel)
    local progress = tostring(step) .. " / " .. #names
    Draw.rightText(surface, regions.width - 1, regions.header, progress, Theme.role.text, Theme.role.panel)

    -- Stops one row short of the header and footer on purpose: both are already panel-
    -- coloured, so a card that touched them fused into one undifferentiated block instead
    -- of reading as its own section. The untouched row above and below stays ground colour
    -- (surface.clear() already painted it), giving the card a visible gap on every side.
    local cardFrom, cardTo = 2, regions.width - 1
    local cardTop = regions.content.top
    local cardBottom = regions.content.bottom
    for y = cardTop, cardBottom do Draw.band(surface, y, Theme.role.panel, cardFrom, cardTo) end

    local promptWidth = math.max(10, cardTo - cardFrom - 1)
    local cardTextWidth = math.max(6, (cardTo - cardFrom + 1) - 4)

    Draw.text(surface, 2, regions.content.top, names[step] or "Setup", regions.width - 3,
        Theme.role.focus, Theme.role.panel)
    local promptLines = wrapText(prompts[step] or
        "Select the exact wired peripheral for this role.", promptWidth, 3)
    for index, line in ipairs(promptLines) do
        Draw.text(surface, 2, regions.content.top + index, line, regions.width - 3,
            Theme.role.muted, Theme.role.panel)
    end

    local y = regions.content.top + #promptLines + 2
    if step == 10 then
        for _, row in ipairs(state.setup_summary or {}) do
            if y > cardBottom then break end
            Draw.text(surface, cardFrom + 1, y, tostring(row.label), 20, Theme.role.muted, Theme.role.panel)
            Draw.rightText(surface, cardTo - 1, y, tostring(row.detail), Theme.role.text, Theme.role.panel)
            y = y + 1
        end
        y = y + 1
    end

    local bandLabel = bandLabels[step]
    if bandLabel then
        Draw.band(surface, y, Theme.role.track, cardFrom, cardTo)
        Draw.text(surface, cardFrom + 1, y, bandLabel, 30, Theme.role.muted, Theme.role.track)
        y = y + 1
    end

    local choices = state.setup_choices or {}
    if #choices == 0 then
        Draw.text(surface, cardFrom + 1, y, "No choices on this step", cardTextWidth,
            Theme.role.muted, Theme.role.panel)
    end
    self:_cardWindow(y, cardBottom, #choices, state.selection, 2,
        function(index, cardY)
            local choice = choices[index]
            local selected = index == state.selection
            local marker, markerColor
            if choice.blocking ~= nil then
                marker = choice.blocking and "!" or "i"
                markerColor = choice.blocking and Theme.role.alert or Theme.role.warn
            end
            local labelLines = wrapText(tostring(choice.label or choice.name or ""), cardTextWidth, 2)
            local secondLine = (#labelLines > 1) and labelLines[2] or choice.detail
            self:_row(cardY, selected, cardFrom, cardTo, marker, markerColor,
                labelLines[1], nil, nil, Theme.role.panel)
            self:_cardDetail(cardY + 1, selected, cardFrom, cardTo, secondLine, Theme.role.panel)
            hitRegions[#hitRegions + 1] = {x1=cardFrom, y1=cardY, x2=cardTo, y2=cardY + 1,
                command={type="SETUP_ACTIVATE", index=index}}
        end)

    Draw.band(surface, regions.footer, Theme.role.panel)
    local footerX = 2
    local function footerSegment(text, command)
        Draw.text(surface, footerX, regions.footer, text, #text, Theme.role.text, Theme.role.panel)
        if command then
            hitRegions[#hitRegions + 1] = {x1=footerX, y1=regions.footer,
                x2=footerX + #text - 1, y2=regions.footer, command=command}
        end
        footerX = footerX + #text + 2
    end
    if step == 4 then
        footerSegment("Up/Down Enter")
        footerSegment("Left back", {type="SETUP_BACK"})
        footerSegment("Right next", {type="SETUP_NEXT"})
        footerSegment("R rename", {type="RENAME_STORAGE_REQUEST"})
    else
        footerSegment("Up/Down")
        footerSegment("Enter select")
        footerSegment("Left back", {type="SETUP_BACK"})
        footerSegment("Right next", {type="SETUP_NEXT"})
    end

    Draw.band(surface, regions.status, Theme.role.ground)
    local cancelText = "F10 cancel"
    Draw.text(surface, 2, regions.status, cancelText, regions.width - 3,
        Theme.role.muted, Theme.role.ground)
    hitRegions[#hitRegions + 1] = {x1=2, y1=regions.status, x2=1 + #cancelText,
        y2=regions.status, command={type="CANCEL_SETUP"}}
    surface.setCursorBlink(false)
    return {hit_regions = hitRegions}
end

function UI:_setupRename(state, model)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    local hitRegions = {}

    Draw.band(surface, regions.header, Theme.role.panel)
    Draw.text(surface, 2, regions.header, "SETUP WIZARD", 20, Theme.role.brand, Theme.role.panel)

    local cardFrom, cardTo = 2, regions.width - 1
    local cardTop = regions.content.top
    local cardBottom = regions.content.bottom
    for y = cardTop, cardBottom do Draw.band(surface, y, Theme.role.panel, cardFrom, cardTo) end

    Draw.text(surface, 2, regions.content.top, "Name this storage node", regions.width - 3,
        Theme.role.focus, Theme.role.panel)
    local promptLines = wrapText("Shown on the Storage page instead of the peripheral name.",
        math.max(10, cardTo - cardFrom - 1), 2)
    for index, line in ipairs(promptLines) do
        Draw.text(surface, 2, regions.content.top + index, line, regions.width - 3,
            Theme.role.muted, Theme.role.panel)
    end

    local inputRow = regions.content.top + #promptLines + 2
    Draw.text(surface, 2, inputRow, ">", 1, Theme.role.focus, Theme.role.panel)
    Draw.text(surface, 4, inputRow, (state.setup_rename_text or "") .. "_", regions.width - 4,
        Theme.role.text, Theme.role.panel)

    Draw.band(surface, regions.footer, Theme.role.panel)
    local footerX = 2
    local function footerSegment(text, command)
        Draw.text(surface, footerX, regions.footer, text, #text, Theme.role.text, Theme.role.panel)
        hitRegions[#hitRegions + 1] = {x1=footerX, y1=regions.footer,
            x2=footerX + #text - 1, y2=regions.footer, command=command}
        footerX = footerX + #text + 3
    end
    footerSegment("Enter save", {type="RENAME_CONFIRM"})
    footerSegment("Left/F10 cancel", {type="RENAME_CANCEL"})

    surface.setCursorBlink(false)
    return {hit_regions = hitRegions}
end

-- Crafting page. Four views behind one page, because they are steps of one task and
-- swapping pages between them would lose the search that found the item.
function UI:_crafting(state, model, hitRegions)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    local bottom = regions.content.bottom

    -- The plan view is handed raw item ids. Anything the recipe list or the chosen item can
    -- name gets named: "craft 8 x minecraft:oak_planks" is a line nobody reads twice.
    local function itemName(id)
        for _, entry in ipairs(state.craft_results or {}) do
            if entry.item == id then return tostring(entry.display_name or id) end
        end
        if state.craft_item and state.craft_item.item == id then
            return tostring(state.craft_item.display_name or id)
        end
        return tostring(id)
    end

    if state.mode == "craft_jobs" then
        local bandRow = regions.content.top
        self:_band(bandRow)
        self:_bandText(2, bandRow, "CRAFT JOBS", regions.width - 2)
        Draw.rightText(surface, regions.width - 1, bandRow, "STATE",
            Theme.role.muted, Theme.role.panel)
        local jobs = state.craft_jobs or {}
        if #jobs == 0 then
            Draw.text(surface, 2, bandRow + 1, "No craft jobs", regions.width - 2,
                Theme.role.muted, Theme.role.ground)
        end
        self:_list(bandRow + 1, bottom, #jobs, state.craft_job_selection or 1,
            function(index, y, selected)
                local job = jobs[index]
                local label = tostring(job.state)
                if job.state == "QUEUED" then label = "QUEUED #" .. tostring(index - 1) end
                self:_row(y, selected, 1, regions.width, nil, nil,
                    tostring(job.display_name or job.item), label, Theme.statusColor(job.state))
                hitRegions[#hitRegions + 1] = {x1=1, y1=y, x2=regions.width, y2=y,
                    command={type="MOVE", delta=index - (state.craft_job_selection or 1)}}
            end)
        self:_strip(regions, model)
        return
    end

    if state.mode == "craft_plan" then
        local plan = state.craft_plan
        if not plan then
            Draw.text(surface, 2, regions.content.top, "Planning...", regions.width - 2,
                Theme.role.muted, Theme.role.ground)
            return
        end
        local bandRow = regions.content.top
        self:_band(bandRow)
        self:_bandText(2, bandRow, "PLAN  " .. formatNumber(plan.quantity or 0) .. " x " ..
            tostring((state.craft_item and state.craft_item.display_name) or itemName(plan.item)),
            regions.width - 2)
        local row = bandRow + 1
        if not plan.ok then
            Draw.text(surface, 2, row, "Cannot craft: missing", regions.width - 2,
                Theme.role.alert, Theme.role.ground)
            row = row + 1
            for _, missing in ipairs(plan.shortfalls or {}) do
                if row > bottom then break end
                Draw.text(surface, 4, row, formatNumber(missing.missing) .. " x " ..
                    itemName(missing.item), regions.width - 4, Theme.role.text, Theme.role.ground)
                row = row + 1
            end
            self:_strip(regions, model)
            return
        end
        for index, choice in ipairs(plan.chosen or {}) do
            if row > bottom then break end
            local selected = index == (state.craft_plan_selection or 1)
            self:_row(row, selected, 1, regions.width, nil, nil,
                itemName(choice.item), tostring(choice.tag), Theme.role.warn)
            row = row + 1
        end
        for _, step in ipairs(plan.steps or {}) do
            if row > bottom then break end
            Draw.text(surface, 2, row, "craft " .. formatNumber(step.produced) .. " x " ..
                itemName(step.item), regions.width - 2, Theme.role.craft, Theme.role.ground)
            row = row + 1
        end
        for _, withdrawal in ipairs(plan.withdrawals or {}) do
            if row > bottom then break end
            Draw.text(surface, 2, row, "use " .. formatNumber(withdrawal.count) .. " x " ..
                itemName(withdrawal.item), regions.width - 2,
                Theme.role.muted, Theme.role.ground)
            row = row + 1
        end
        if row <= bottom then
            Draw.text(surface, 2, row, "deliver to " .. tostring(state.craft_destination),
                regions.width - 2, Theme.role.text, Theme.role.ground)
        end
        self:_strip(regions, model)
        return
    end

    -- craft_search and craft_quantity share the recipe list, laid out exactly like Search:
    -- the same split, the same bands, and the quantity prompt in the pane rather than a band
    -- across the bottom, so the list you were reading stays where you were reading it.
    local split = regions.split
    local listTo = split and (split - 1) or regions.width
    local paneFrom = split and (split + 2) or nil
    local results = state.craft_results or {}
    local queryRow = regions.content.top
    local queryBoxWidth = regions.width - 4
    local queryText = state.craft_query .. (state.mode == "craft_search" and "_" or "")
    Draw.text(surface, 2, queryRow, ">", 1, Theme.role.focus, Theme.role.ground)
    Draw.text(surface, 4, queryRow, queryText, queryBoxWidth, Theme.role.text, Theme.role.ground)
    if state.mode == "craft_search" then
        local highlighted = results[state.craft_selection or 1]
        local tail = highlighted and
            ghostTail(state.craft_query, tostring(highlighted.display_name or highlighted.item))
        local ghostWidth = queryBoxWidth - #queryText
        if tail and ghostWidth > 0 then
            Draw.text(surface, 4 + #queryText, queryRow, tail, ghostWidth,
                Theme.role.ghost, Theme.role.ground)
        end
    end
    local bandRow = queryRow + 1
    self:_band(bandRow)
    self:_bandText(2, bandRow, "RECIPE", math.max(1, listTo - 2))
    Draw.rightText(surface, listTo - 1, bandRow, "STOCK", Theme.role.muted, Theme.role.panel)
    if paneFrom then
        self:_bandText(paneFrom, bandRow, "SELECTED", regions.width - paneFrom)
        Draw.divider(surface, split, bandRow, bottom, Theme.role.panel)
    end
    if #results == 0 then
        Draw.text(surface, 2, bandRow + 1, "No matching recipes", math.max(1, listTo - 2),
            Theme.role.muted, Theme.role.ground)
    end
    self:_list(bandRow + 1, bottom, #results, state.craft_selection or 1,
        function(index, y, selected)
            local entry = results[index]
            self:_row(y, selected, 1, listTo, selected and ">" or nil, nil,
                tostring(entry.display_name or entry.item),
                formatNumber(entry.quantity or 0),
                (entry.quantity or 0) > 0 and Theme.role.ok or Theme.role.muted,
                nil, true)
            hitRegions[#hitRegions + 1] = {x1=1, y1=y, x2=listTo, y2=y,
                command={type="ACTIVATE", index=index}}
        end)

    local chosen = results[state.craft_selection or 1]
    if paneFrom and state.mode == "craft_quantity" then
        local paneWidth = regions.width - paneFrom
        local item = state.craft_item or {}
        Draw.text(surface, paneFrom, bandRow + 1, "How many?", paneWidth,
            Theme.role.focus, Theme.role.ground)
        if Draw.marqueeText(surface, paneFrom, bandRow + 2,
            tostring(item.display_name or item.item or ""), paneWidth,
            Theme.role.text, Theme.role.ground, self._now) then
            self._animating = true
        end
        Draw.text(surface, paneFrom, bandRow + 4,
            (state.craft_quantity_text ~= "" and state.craft_quantity_text or "_"), paneWidth,
            Theme.role.text, Theme.role.ground)
        Draw.text(surface, paneFrom, bandRow + 6, "Enter plan", paneWidth,
            Theme.role.muted, Theme.role.ground)
        Draw.text(surface, paneFrom, bandRow + 7, "A max   F10 back", paneWidth,
            Theme.role.muted, Theme.role.ground)
    elseif paneFrom and chosen then
        local paneWidth = regions.width - paneFrom
        if Draw.marqueeText(surface, paneFrom, bandRow + 1,
            tostring(chosen.display_name or chosen.item), paneWidth,
            Theme.role.focus, Theme.role.ground, self._now) then
            self._animating = true
        end
        if Draw.marqueeText(surface, paneFrom, bandRow + 2, tostring(chosen.item), paneWidth,
            Theme.role.muted, Theme.role.ground, self._now) then
            self._animating = true
        end
        Draw.text(surface, paneFrom, bandRow + 4, "IN STOCK", paneWidth,
            Theme.role.muted, Theme.role.ground)
        Draw.text(surface, paneFrom, bandRow + 5, formatNumber(chosen.quantity or 0), paneWidth,
            (chosen.quantity or 0) > 0 and Theme.role.ok or Theme.role.muted, Theme.role.ground)
        local button = fittedLabel(paneWidth,
            {"  ENTER  CHOOSE  ", " ENTER CHOOSE ", " CHOOSE ", "CHOOSE"})
        local buttonRow = math.min(bottom, bandRow + 8)
        Draw.text(surface, paneFrom, buttonRow, button,
            math.min(#button, paneWidth), Theme.role.text, Theme.role.brand)
        hitRegions[#hitRegions + 1] = {x1=paneFrom, y1=buttonRow,
            x2=paneFrom + #button - 1, y2=buttonRow,
            command={type="OPEN_CRAFT_QUANTITY"}}
    elseif state.mode == "craft_quantity" then
        -- No pane to put it in, so the narrow layout keeps the band it always had.
        Draw.band(surface, bottom, Theme.role.panel)
        Draw.text(surface, 2, bottom, "How many? " .. state.craft_quantity_text,
            regions.width - 2, Theme.role.text, Theme.role.panel)
    end
    if state.mode ~= "craft_quantity" then self:_strip(regions, model) end
end

-- Every path through a render must end the frame it began. A frame begun and never ended
-- leaves the buffered window hidden forever: the application carries on working perfectly --
-- reading keys, scanning, transferring -- while the screen stays frozen on the last frame
-- that was shown. That is indistinguishable from a hang, and it is what the setup wizard's
-- early return caused. Hence the single entry and exit here, and the pcall: an error inside a
-- page renderer must not be able to hide the display either.
function UI:render(state, model)
    local surface = self.surface
    -- Transient, reset every render: not part of `state`, so this does not touch anything
    -- test_ui_purity.lua checks. `_now` drives Draw.marqueeText; `_animating` reports back
    -- whether any row actually used it, so the caller only keeps asking for animation frames
    -- while something on screen is genuinely scrolling.
    self._now = (model or {}).now
    self._animating = false
    if surface.beginFrame then surface.beginFrame() end
    local ok, result = pcall(self._frame, self, state, model)
    if surface.endFrame then surface.endFrame() end
    if not ok then error(result, 0) end
    if type(result) == "table" then result.animating = self._animating end
    return result
end

-- Flattens the modal's sections into one list of rows -- a header, a blank spacer, and one
-- row per wrapped detail line -- so `UI:_windowed` can scroll across a section boundary for
-- free instead of the old "show a section whole or not at all, else stop" degradation. That
-- degradation is what this replaces: with wrapping in place a long section like Everywhere
-- would essentially never fit whole on a 24-row terminal, so dropping it outright would mean
-- it almost never rendered at all. The label sits only on an entry's first row, matching the
-- approved mockup, so "Enter retrieve" prints once even though its detail wraps to two rows.
local function helpRows(sections, width)
    local labelWidth = math.max(1, math.min(18, width - 3))
    local detailX = 3 + labelWidth
    local detailWidth = width - detailX
    local showDetail = detailWidth >= 6
    local rows = {}
    for _, section in ipairs(sections) do
        local entries = section.entries
        if #entries > 0 then
            rows[#rows + 1] = {kind = "header", text = section.title:upper()}
            for _, entry in ipairs(entries) do
                local label = entry.key .. (entry.label and (" " .. entry.label) or "")
                local lines = showDetail and Draw.wrap(entry.detail, detailWidth) or {}
                if #lines == 0 then
                    rows[#rows + 1] = {kind = "entry", label = label, labelWidth = labelWidth}
                else
                    for index, line in ipairs(lines) do
                        rows[#rows + 1] = {kind = "entry", label = (index == 1) and label or nil,
                            labelWidth = labelWidth, detail = line, detailX = detailX,
                            detailWidth = detailWidth}
                    end
                end
            end
            rows[#rows + 1] = {kind = "blank"}
        end
    end
    return rows
end

-- F1 toggles this from any mode, including from inside a search box, since letters and
-- digits are query characters there and only the function row is free. Closing must restore
-- the exact prior screen, so this never touches anything but state.mode/help_return_mode --
-- the interrupted mode's own fields (query text, craft plan, selection...) are untouched and
-- still there when TOGGLE_HELP flips mode back.
--
-- Scrolling reads `state.help_scroll` and clamps it locally through `_windowed`; it is never
-- written back here, matching the same rule every other renderer follows (see
-- tests/test_ui_purity.lua). The reducer is responsible for advancing help_scroll on MOVE
-- while state.mode == "help" -- this render side only needs a number to clamp.
function UI:_help(state, model)
    local surface = self.surface
    local width, height = surface.getSize()
    Draw.band(surface, 1, Theme.role.panel)
    Draw.text(surface, 2, 1, "HELP", math.max(1, width - 3), Theme.role.brand, Theme.role.panel)
    local closeHint = "F1/F10/click closes"
    if width - 3 >= #closeHint then
        Draw.rightText(surface, width - 1, 1, closeHint, Theme.role.muted, Theme.role.panel)
    end

    -- Closing on a click anywhere, not just on some button, because the whole screen is the
    -- modal -- there is no "outside" to distinguish it from.
    local hitRegions = {{x1 = 1, y1 = 1, x2 = width, y2 = math.max(1, height),
        command = {type = "TOGGLE_HELP"}}}

    local contextState = copy(state)
    contextState.mode = state.help_return_mode or "search"
    local sections = Help.modalSections(contextState)
    -- Appended, not folded into "Everywhere": those are the interrupted screen's globals,
    -- these are the modal's own (close, and eventually scroll) -- Help.modalSections(state)
    -- with the real state.mode == "help" resolves M.per_mode.help via M.contextEntries the
    -- same way any other mode does, so this is no different from how "This page" is built.
    local ownEntries = Help.modalSections(state)[1].entries
    if #ownEntries > 0 then
        sections[#sections + 1] = {title = "This modal", entries = ownEntries}
    end
    local rows = helpRows(sections, width)

    -- Row 2 and the last row are reserved for the scroll affordance rather than shared with
    -- content, so "[more v]" never overwrites a wrapped detail line the way it would if it
    -- shared the last content row.
    local top, bottom = 3, height - 1
    local scroll = math.floor(tonumber(state.help_scroll) or 1)
    local offset, visible = self:_windowed(top, bottom, #rows, scroll, function(index, y)
        local entryRow = rows[index]
        if entryRow.kind == "header" then
            self:_band(y)
            self:_bandText(2, y, entryRow.text, math.max(1, width - 2))
        elseif entryRow.kind == "entry" then
            if entryRow.label then
                Draw.text(surface, 2, y, entryRow.label, entryRow.labelWidth,
                    Theme.role.focus, Theme.role.ground)
            end
            if entryRow.detail then
                Draw.text(surface, entryRow.detailX, y, entryRow.detail, entryRow.detailWidth,
                    Theme.role.text, Theme.role.ground)
            end
        end
    end)

    -- The affordance a marquee earns elsewhere for the same reason: a sign that content is
    -- being hidden, not decoration, so it stays muted rather than competing with a control.
    if offset > 1 then
        local hint = "[more ^]"
        Draw.text(surface, width - #hint, 2, hint, #hint, Theme.role.muted, Theme.role.ground)
    end
    if offset + visible - 1 < #rows then
        local hint = "[more v]"
        Draw.text(surface, width - #hint, height, hint, #hint, Theme.role.muted, Theme.role.ground)
    end

    surface.setCursorBlink(false)
    return {hit_regions = hitRegions}
end

function UI:_frame(state, model)
    model = model or {}
    local surface = self.surface
    surface.setBackgroundColor(Theme.role.ground)
    surface.setTextColor(Theme.role.text)
    surface.clear()
    if state.mode == "help" then return self:_help(state, model) end
    if state.mode == "setup_rename" then return self:_setupRename(state, model) end
    if state.mode == "setup" then return self:_setupWizard(state, model) end
    -- Declared before the header, which now contributes the nav tab regions.
    local hitRegions = {}
    self:_header(state, model, hitRegions)
    if state.page == "search" then self:_search(state, model, hitRegions)
    elseif state.page == "storage" then self:_storage(state, model, hitRegions)
    elseif state.page == "requests" then self:_requests(state, model, hitRegions)
    elseif state.page == "alerts" then self:_alerts(state, model, hitRegions)
    elseif state.page == "crafting" then self:_crafting(state, model, hitRegions)
    else self:_setup(model) end
    self:_footer(state, model)
    if state.mode == "quantity" or state.mode == "variant" then self:_overlay(state) end
    surface.setBackgroundColor(Theme.role.ground)
    surface.setTextColor(Theme.role.text)
    surface.setCursorBlink(state.mode == "search" or state.mode == "craft_search")
    return { hit_regions=hitRegions }
end

return UI
