local Draw = require("app.draw")
local Layout = require("app.layout")
local Theme = require("app.theme")

local UI = {}
UI.__index = UI

local palette = colors or {
    white=1, orange=2, magenta=4, lightBlue=8, yellow=16, lime=32,
    pink=64, gray=128, lightGray=256, cyan=512, purple=1024, blue=2048,
    brown=4096, green=8192, red=16384, black=32768,
}

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
-- The window ends on the selection rather than starting on it, so arrowing down the list
-- scrolls under a cursor that stays put. Starting the window on the selection instead makes
-- the cursor jump to the top of a fresh page every time it reaches the bottom of one.
local function scrollFor(selection, count, visible)
    if visible < 1 then return 1 end
    selection = math.max(1, selection or 1)
    local maxScroll = math.max(1, (count or 0) - visible + 1)
    return math.max(1, math.min(selection - visible + 1, maxScroll))
end

local function writeClipped(surface, x, y, text, width)
    local sw, sh = surface.getSize()
    if y < 1 or y > sh or x > sw or width <= 0 then return end
    text = tostring(text or "")
    if x < 1 then
        local remove = 1 - x
        text = text:sub(remove + 1)
        width, x = width - remove, 1
    end
    if width <= 0 then return end
    text = text:sub(1, math.min(width, sw - x + 1))
    if #text > 0 then surface.setCursorPos(x, y); surface.write(text) end
end

local function fill(surface, y, color)
    local width, height = surface.getSize()
    if y < 1 or y > height then return end
    surface.setBackgroundColor(color)
    surface.setCursorPos(1, y)
    surface.write(string.rep(" ", width))
end

local function stateColor(state)
    if state == "READY" or state == "COMPLETE" then return palette.lime end
    if state == "DEGRADED" or state == "BLOCKED" or state == "PARTIAL" then return palette.yellow end
    if state == "ERROR" or state == "FAILED" or state == "OFFLINE" then return palette.red end
    return palette.orange
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
        notice=nil, hit_regions={},
        request_selection=1, request_count=0, alert_selection=1, alert_count=0,
        storage_scroll=1, recovery_confirm_armed=false,
        craft_query="", craft_results={}, craft_result_count=0, craft_selection=1,
        craft_scroll=1, craft_quantity_text="", craft_item=nil, craft_plan=nil,
        craft_destination="pickup", craft_plan_selection=1,
        craft_jobs={}, craft_job_count=0, craft_job_selection=1,
    }
end

local function selectedResult(state)
    return state.results and state.results[state.selection] or nil
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
    elseif kind == "CONSUME_CHAR" then
        state.suppress_char = nil
    elseif kind == "QUERY_BACKSPACE" then
        state.query = state.query:sub(1, math.max(0, #state.query - 1))
        state.selection, state.scroll, state.notice = 1, 1, nil
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
    elseif kind == "CRAFT_QUERY_BACKSPACE" then
        state.craft_query = state.craft_query:sub(1, math.max(0, #state.craft_query - 1))
        state.craft_selection, state.craft_scroll = 1, 1
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
    elseif kind == "ACKNOWLEDGE_ALERT" then
        return state, {type="ACKNOWLEDGE_ALERT",index=state.alert_selection}
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
    elseif kind == "ACTIVATE" then
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
            local selected = state.variants[state.variant_selection]
            if selected then enterQuantity(state, selected, selectedResult(state) or selected) end
        elseif state.mode == "search" and command.index then
            state.selection = command.index
            return self:reduce(state, {type="OPEN_QUANTITY"})
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
        state.setup_step = command.step or state.setup_step or 1
        state.setup_choices = copy(command.choices or {})
        state.setup_choice_count = #state.setup_choices
        state.setup_issues = copy(command.issues or {})
        state.selection = math.max(1, math.min(state.selection,
            math.max(1, state.setup_choice_count)))
    elseif kind == "SETUP_MOVE" then
        state.selection = math.max(1, math.min(math.max(1, state.setup_choice_count or 0),
            state.selection + command.delta))
    elseif kind == "SETUP_SELECT" then
        return state, {type="SETUP_SELECT",step=state.setup_step,index=state.selection}
    elseif kind == "SETUP_NEXT" or kind == "SETUP_BACK" then
        return state, {type=kind,step=state.setup_step}
    elseif kind == "CANCEL_SETUP" then
        state.mode, state.page = "page", "setup"
        return state, {type="CANCEL_SETUP"}
    elseif kind == "CANCEL" then
        -- Within the Crafting page F10 steps back one level rather than leaving the
        -- page, so backing out of a plan does not lose the search that found it.
        if state.mode == "craft_plan" then
            state.mode, state.craft_plan = "craft_quantity", nil
        elseif state.mode == "craft_quantity" then
            state.mode, state.craft_quantity_text = "craft_search", ""
        elseif state.mode == "craft_jobs" then
            state.mode = "craft_search"
        else
            state.mode, state.page, state.quantity_text, state.variants = "search", "search", "", nil
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
function UI:_nav(state, regions)
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
function UI:_list(top, bottom, count, selection, render)
    local visible = math.max(0, bottom - top + 1)
    local scroll = scrollFor(selection, count, visible)
    for offset = 0, visible - 1 do
        local index = scroll + offset
        if index > (count or 0) then break end
        render(index, top + offset, index == selection)
    end
    return scroll, visible
end

-- One list row: an optional status marker, a name, and a right-aligned value. Selection is a
-- filled row in the focus colour with inverted text -- the same on every page. The pages used
-- to disagree, Search filling red and Crafting filling grey, which read as two products.
function UI:_row(y, selected, from, to, marker, markerColor, left, right, rightColor)
    local surface = self.surface
    local background = selected and Theme.role.focus or Theme.role.ground
    local primary = selected and Theme.role.ground or Theme.role.text
    Draw.band(surface, y, background, from, to)
    if marker then
        Draw.text(surface, from + 1, y, marker, 1,
            selected and Theme.role.ground or (markerColor or Theme.role.muted), background)
    end
    right = right and tostring(right) or nil
    local nameWidth = math.max(1, (to - from + 1) - #(right or "") - 4)
    Draw.text(surface, from + 3, y, left, nameWidth, primary, background)
    if right then
        Draw.rightText(surface, to - 1, y, right,
            selected and Theme.role.ground or (rightColor or Theme.role.muted), background)
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

function UI:_header(state, model)
    local surface = self.surface
    local regions = Layout.regions(surface.getSize())
    Draw.band(surface, regions.header, Theme.role.panel)
    Draw.text(surface, 2, regions.header, "INVOS", 20, Theme.role.brand, Theme.role.panel)
    local lifecycle = model.lifecycle or "BOOTING"
    Draw.rightText(surface, regions.width - 1, regions.header, lifecycle,
        Theme.statusColor(lifecycle), Theme.role.panel)
    Draw.band(surface, regions.nav, Theme.role.ground)
    self:_nav(state, regions)
end

local function footerHelp(state)
    if state.page == "search" then return "Type search  Up/Down select  Enter retrieve" end
    if state.page == "requests" then
        return "Up/Down select  R retry  C cancel  P pause  F10 back"
    end
    if state.page == "alerts" then
        return "Up/Down  A acknowledge  X+Enter release recovery"
    end
    if state.page == "storage" then return "Up/Down scroll  P pause  F10 back" end
    if state.page == "crafting" then
        if state.mode == "craft_plan" then
            return "Enter craft  D destination  P pin choice  F10 back"
        end
        if state.mode == "craft_quantity" then return "Digits then Enter  A max  F10 back" end
        if state.mode == "craft_jobs" then
            return "Up/Down select  R retry  C cancel  Enter confirm  Tab search"
        end
        return "Type to find a recipe  Enter choose  Tab jobs  F10 back"
    end
    return "1 Search  P pause  F10 back"
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
    Draw.text(surface, 2, regions.footer, footerHelp(state), regions.width - 2,
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

    local queryRow = regions.content.top + 1
    Draw.band(surface, queryRow, Theme.role.ground)
    Draw.text(surface, 2, queryRow, ">", 1, Theme.role.focus, Theme.role.ground)
    Draw.text(surface, 4, queryRow, state.query .. (state.mode == "search" and "_" or ""),
        regions.width - 4, Theme.role.text, Theme.role.ground)

    local bandRow = queryRow + 2
    local bodyTop = bandRow + 1
    self:_band(bandRow)
    self:_bandText(2, bandRow, "ITEM", math.max(1, listTo - 2))
    Draw.rightText(surface, listTo - 1, bandRow, "STOCK", Theme.role.muted, Theme.role.panel)
    if paneFrom then
        self:_bandText(paneFrom, bandRow, "SELECTED", regions.width - paneFrom)
        Draw.divider(surface, split, bandRow, regions.content.bottom, Theme.role.panel)
    end

    local results = model.search_results or state.results or {}
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
                tostring(item.display_name or item.name), formatNumber(item.quantity))
            hitRegions[#hitRegions + 1] = {x1=1, y1=y, x2=listTo, y2=y,
                command={type="ACTIVATE", index=index}}
        end)

    local selected = results[state.selection]
    if paneFrom and selected then
        local paneWidth = regions.width - paneFrom
        Draw.text(surface, paneFrom, bodyTop, tostring(selected.display_name or selected.name),
            paneWidth, Theme.role.focus, Theme.role.ground)
        Draw.text(surface, paneFrom, bodyTop + 1, tostring(selected.name), paneWidth,
            Theme.role.muted, Theme.role.ground)
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
        local button = "  ENTER  RETRIEVE "
        Draw.text(surface, paneFrom, math.min(regions.content.bottom, bodyTop + 10), button,
            math.min(#button, paneWidth), Theme.role.text, Theme.role.brand)
    end
    self:_strip(regions, model)
end

-- Nodes, requests and alerts share one fixed content band (row 5 through height-2).
-- Keeping the geometry in one place keeps their scrolling consistent with each other.
local function listBand(height)
    local bodyTop, bodyBottom = 5, height - 2
    return bodyTop, math.max(0, bodyBottom - bodyTop + 1)
end

function UI:_storage(state, model)
    local surface = self.surface
    local width, height = surface.getSize()
    surface.setTextColor(palette.red); writeClipped(surface, 2, 3, "STORAGE NODES", width - 2)
    local nodes = model.nodes or {}
    if #nodes == 0 then
        surface.setTextColor(palette.lightGray)
        writeClipped(surface, 2, 5, "No storage nodes configured", width - 3)
        writeClipped(surface, 2, 6, "Open Setup to add a Colossal Chest", width - 3)
        return
    end
    local bodyTop, visible = listBand(height)
    local scroll = math.max(1, math.min((state or {}).storage_scroll or 1,
        math.max(1, #nodes - visible + 1)))
    for row = 0, visible - 1 do
        local node = nodes[scroll + row]
        if node then
            local y = bodyTop + row
            surface.setTextColor(stateColor(node.state))
            writeClipped(surface, 2, y, "o", 1)
            surface.setTextColor(palette.white)
            writeClipped(surface, 4, y, node.label or node.id, math.max(1, width - 30))
            surface.setTextColor(palette.lightGray)
            local capacity = formatNumber(node.occupied or 0) .. " / " ..
                formatNumber(node.size or 0) .. " slots"
            writeClipped(surface, math.max(4, width - #capacity - 10), y, capacity, #capacity)
            surface.setTextColor(stateColor(node.state))
            writeClipped(surface, math.max(4, width - #(node.state or "") - 1), y,
                node.state or "", #(node.state or ""))
        end
    end
end

function UI:_requests(state, model)
    local surface = self.surface
    local width, height = surface.getSize()
    surface.setTextColor(palette.red); writeClipped(surface, 2, 3, "REQUESTS", width - 2)
    local requests = model.requests or {}
    if #requests == 0 then
        surface.setTextColor(palette.lightGray)
        writeClipped(surface, 2, 5, "No requests yet", width - 3)
        writeClipped(surface, 2, 6, "Press 1 and search for an item to retrieve", width - 3)
        return
    end
    local bodyTop, visible = listBand(height)
    local selection = math.max(1, math.min(#requests, (state or {}).request_selection or 1))
    local scroll = 1
    if selection >= scroll + visible then scroll = selection - visible + 1 end
    for row = 0, visible - 1 do
        local index = scroll + row
        local request = requests[index]
        if request then
            local y = bodyTop + row
            local selected = index == selection
            if selected then fill(surface, y, palette.red) end
            surface.setTextColor(selected and palette.black or stateColor(request.state))
            writeClipped(surface, 2, y, request.state or "", 12)
            surface.setTextColor(selected and palette.black or palette.white)
            writeClipped(surface, 15, y, request.display_name or request.id, width - 29)
            local progress = formatNumber(request.delivered or 0) .. " / " ..
                formatNumber(request.requested or 0)
            surface.setTextColor(selected and palette.black or palette.lightGray)
            writeClipped(surface, math.max(16, width - #progress - 1), y, progress, #progress)
        end
    end
end

function UI:_alerts(state, model)
    local surface = self.surface
    local width, height = surface.getSize()
    surface.setTextColor(palette.red); writeClipped(surface, 2, 3, "ALERTS", width - 2)
    local alerts = model.alerts or {}
    if #alerts == 0 then
        surface.setTextColor(palette.lime)
        writeClipped(surface, 2, 5, "No active alerts", width - 3)
        surface.setTextColor(palette.lightGray)
        writeClipped(surface, 2, 6, "Storage conditions are healthy", width - 3)
        return
    end
    local bodyTop, visible = listBand(height)
    local selection = math.max(1, math.min(#alerts, (state or {}).alert_selection or 1))
    local scroll = 1
    if selection >= scroll + visible then scroll = selection - visible + 1 end
    for row = 0, visible - 1 do
        local index = scroll + row
        local alert = alerts[index]
        if alert then
            local y = bodyTop + row
            local selected = index == selection
            if selected then fill(surface, y, palette.red) end
            surface.setTextColor(selected and palette.black or
                (alert.severity == "critical" and palette.red or palette.yellow))
            writeClipped(surface, 2, y, alert.acknowledged and "-" or "!", 1)
            surface.setTextColor(selected and palette.black or palette.white)
            writeClipped(surface, 4, y, alert.message, width - 5)
        end
    end
end

function UI:_setup(model)
    local surface = self.surface
    local width = surface.getSize()
    surface.setTextColor(palette.red); writeClipped(surface, 2, 3, "SETUP", width - 2)
    surface.setTextColor(palette.white)
    writeClipped(surface, 2, 5, "Review or change inventory roles", width - 3)
    surface.setTextColor(palette.lightGray)
    writeClipped(surface, 2, 7, "Drop-off: " .. tostring(model.dropoff and model.dropoff.state or "unassigned"), width - 3)
    writeClipped(surface, 2, 8, "Pickup:  " .. tostring(model.pickup and model.pickup.state or "unassigned"), width - 3)
    writeClipped(surface, 2, 10, "Enter opens the full setup wizard", width - 3)
end

-- The retrieve prompt. With a detail pane on screen it replaces the pane's contents, so the
-- list you were reading stays visible and the prompt appears where you were already looking.
-- A floating box over the middle of the list was the old behaviour and it hid the thing you
-- had just selected. Narrow screens have no pane, so they keep the centred box.
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
    local width, height = surface.getSize()
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
    fill(surface, 1, palette.gray)
    surface.setTextColor(palette.white)
    writeClipped(surface, 2, 1, "SETUP WIZARD", 20)
    local progress = tostring(state.setup_step or 1) .. " / " .. #names
    surface.setTextColor(palette.red)
    writeClipped(surface, math.max(2, width - #progress - 1), 1, progress, #progress)
    surface.setTextColor(palette.red)
    writeClipped(surface, 2, 3, names[state.setup_step or 1] or "Setup", width - 3)
    surface.setTextColor(palette.lightGray)
    writeClipped(surface, 2, 4, prompts[state.setup_step or 1] or
        "Select the exact wired peripheral for this role.", width - 3)
    local choices = state.setup_choices or {}
    if #choices == 0 then
        writeClipped(surface, 2, 6, "No choices on this step", width - 3)
    else
        for index, choice in ipairs(choices) do
            local y = 5 + index
            if y >= height - 3 then break end
            local selected = index == state.selection
            fill(surface, y, selected and palette.red or palette.black)
            surface.setTextColor(selected and palette.black or palette.white)
            writeClipped(surface, 2, y, (selected and "> " or "  ") ..
                tostring(choice.label or choice.name), math.max(1, width - 18))
            surface.setTextColor(selected and palette.black or palette.lightGray)
            writeClipped(surface, math.max(3, width - #(choice.detail or "") - 1), y,
                choice.detail or "", #(choice.detail or ""))
        end
    end
    local issues = state.setup_issues or (model.setup and model.setup.issues) or {}
    if #issues > 0 then
        surface.setTextColor(palette.yellow)
        writeClipped(surface, 2, height - 4, "! " .. tostring(issues[1].message), width - 3)
    end
    fill(surface, height - 1, palette.gray)
    surface.setTextColor(palette.white)
    writeClipped(surface, 2, height - 1,
        "Up/Down  Enter select  Left back  Right next", width - 3)
    fill(surface, height, palette.black)
    surface.setTextColor(palette.lightGray)
    writeClipped(surface, 2, height, "F10 cancel", width - 3)
    surface.setCursorBlink(false)
    return {hit_regions={}}
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

    -- craft_search and craft_quantity share the recipe list; the quantity prompt draws
    -- over it as an overlay so the item stays visible while typing.
    local queryRow = regions.content.top
    Draw.text(surface, 2, queryRow, ">", 1, Theme.role.focus, Theme.role.ground)
    Draw.text(surface, 4, queryRow,
        state.craft_query .. (state.mode == "craft_search" and "_" or ""),
        regions.width - 4, Theme.role.text, Theme.role.ground)
    local bandRow = queryRow + 1
    self:_band(bandRow)
    self:_bandText(2, bandRow, "RECIPE", regions.width - 2)
    Draw.rightText(surface, regions.width - 1, bandRow, "STOCK",
        Theme.role.muted, Theme.role.panel)
    local results = state.craft_results or {}
    if #results == 0 then
        Draw.text(surface, 2, bandRow + 1, "No matching recipes", regions.width - 2,
            Theme.role.muted, Theme.role.ground)
    end
    self:_list(bandRow + 1, bottom, #results, state.craft_selection or 1,
        function(index, y, selected)
            local entry = results[index]
            self:_row(y, selected, 1, regions.width, nil, nil,
                tostring(entry.display_name or entry.item),
                "have " .. formatNumber(entry.quantity or 0),
                (entry.quantity or 0) > 0 and Theme.role.ok or Theme.role.muted)
            hitRegions[#hitRegions + 1] = {x1=1, y1=y, x2=regions.width, y2=y,
                command={type="MOVE", delta=index - (state.craft_selection or 1)}}
        end)
    if state.mode == "craft_quantity" then
        Draw.band(surface, bottom, Theme.role.panel)
        Draw.text(surface, 2, bottom, "How many? " .. state.craft_quantity_text,
            regions.width - 2, Theme.role.text, Theme.role.panel)
    else
        self:_strip(regions, model)
    end
end

function UI:render(state, model)
    model = model or {}
    local surface = self.surface
    surface.setBackgroundColor(palette.black)
    surface.setTextColor(palette.white)
    surface.clear()
    if state.mode == "setup" then return self:_setupWizard(state, model) end
    self:_header(state, model)
    local hitRegions = {}
    if state.page == "search" then self:_search(state, model, hitRegions)
    elseif state.page == "storage" then self:_storage(state, model)
    elseif state.page == "requests" then self:_requests(state, model)
    elseif state.page == "alerts" then self:_alerts(state, model)
    elseif state.page == "crafting" then self:_crafting(state, model, hitRegions)
    else self:_setup(model) end
    self:_footer(state, model)
    if state.mode == "quantity" or state.mode == "variant" then self:_overlay(state) end
    surface.setBackgroundColor(palette.black)
    surface.setTextColor(palette.white)
    surface.setCursorBlink(state.mode == "search" or state.mode == "craft_search")
    return { hit_regions=hitRegions }
end

return UI
