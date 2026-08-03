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
    return palette.cyan
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
        state.selection, state.scroll, state.notice = 1, 1, nil
    elseif kind == "QUERY_BACKSPACE" then
        state.query = state.query:sub(1, math.max(0, #state.query - 1))
        state.selection, state.scroll, state.notice = 1, 1, nil
    elseif kind == "MOVE" then
        if state.mode == "variant" then
            state.variant_selection = math.max(1,
                math.min(#(state.variants or {}), state.variant_selection + command.delta))
        else
            state.selection = math.max(1,
                math.min(math.max(1, state.result_count or 0), state.selection + command.delta))
        end
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
        if state.mode == "variant" then
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
        state.mode, state.quantity_text, state.variants = "search", "", nil
    elseif kind == "OPEN_PAGE" then
        state.page = command.page
        state.mode = command.page == "search" and "search" or "page"
        state.notice = nil
    end
    return state
end

function UI:_header(state, model)
    local surface = self.surface
    local width = surface.getSize()
    fill(surface, 1, palette.gray)
    surface.setTextColor(palette.white)
    writeClipped(surface, 2, 1, "COLOSSAL STORAGE", 20)
    local lifecycle = model.lifecycle or "BOOTING"
    surface.setTextColor(stateColor(lifecycle))
    writeClipped(surface, math.max(1, width - #lifecycle - 1), 1, lifecycle, #lifecycle)
    fill(surface, 2, palette.black)
    surface.setTextColor(palette.lightGray)
    writeClipped(surface, 2, 2, "1 SEARCH  2 NODES  3 REQUESTS  4 ALERTS  5 SETUP", width - 2)
end

function UI:_footer(state, model)
    local surface = self.surface
    local width, height = surface.getSize()
    if height < 2 then return end
    fill(surface, height - 1, palette.gray)
    surface.setTextColor(palette.white)
    local help = state.page == "search" and
        "Type search  Up/Down select  Enter retrieve" or "1 Search  F10 back"
    writeClipped(surface, 2, height - 1, help, width - 2)
    fill(surface, height, palette.black)
    surface.setTextColor(state.notice and palette.cyan or palette.lightGray)
    writeClipped(surface, 2, height, state.notice or model.lifecycle_reason or "", width - 2)
end

function UI:_search(state, model, hitRegions)
    local surface = self.surface
    local width, height = surface.getSize()
    fill(surface, 3, palette.black)
    surface.setTextColor(palette.cyan)
    writeClipped(surface, 2, 3, "> " .. state.query .. (state.mode == "search" and "_" or ""), width - 2)
    local bodyTop, bodyBottom = 5, height - 3
    local split = width >= 45 and math.floor(width * 0.62) or width
    local visible = math.max(0, bodyBottom - bodyTop + 1)
    local results = model.search_results or state.results or {}
    if #results == 0 then
        surface.setTextColor(palette.lightGray)
        writeClipped(surface, 2, bodyTop,
            state.query == "" and "Start typing to search stored items" or "No matching items", width - 3)
    else
        local scroll = state.scroll
        if state.selection < scroll then scroll = state.selection end
        if state.selection >= scroll + visible then scroll = state.selection - visible + 1 end
        for row = 0, visible - 1 do
            local index = scroll + row
            local item = results[index]
            if item then
                local y = bodyTop + row
                local selected = index == state.selection
                fill(surface, y, selected and palette.cyan or palette.black)
                surface.setTextColor(selected and palette.black or palette.white)
                writeClipped(surface, 2, y, (selected and "> " or "  ") ..
                    tostring(item.display_name or item.name), split - 11)
                local count = formatNumber(item.quantity)
                writeClipped(surface, math.max(2, split - #count), y, count, #count)
                hitRegions[#hitRegions + 1] = {x1=1,y1=y,x2=split,y2=y,
                    command={type="ACTIVATE",index=index}}
            end
        end
        if split < width then
            local selected = results[state.selection]
            if selected then
                surface.setTextColor(palette.cyan)
                writeClipped(surface, split + 2, bodyTop,
                    selected.display_name or selected.name, width - split - 2)
                surface.setTextColor(palette.lightGray)
                writeClipped(surface, split + 2, bodyTop + 2, selected.name, width - split - 2)
                writeClipped(surface, split + 2, bodyTop + 4,
                    formatNumber(selected.quantity) .. " available", width - split - 2)
                local variantCount = #(selected.variants or {})
                if variantCount > 1 then
                    writeClipped(surface, split + 2, bodyTop + 5,
                        variantCount .. " exact variants", width - split - 2)
                end
                surface.setTextColor(palette.white)
                writeClipped(surface, split + 2, math.min(bodyBottom, bodyTop + 7),
                    "Enter to retrieve", width - split - 2)
            end
        end
    end
end

function UI:_storage(model)
    local surface = self.surface
    local width, height = surface.getSize()
    surface.setTextColor(palette.cyan); writeClipped(surface, 2, 3, "STORAGE NODES", width - 2)
    local nodes = model.nodes or {}
    if #nodes == 0 then
        surface.setTextColor(palette.lightGray)
        writeClipped(surface, 2, 5, "No storage nodes configured", width - 3)
        writeClipped(surface, 2, 6, "Open Setup to add a Colossal Chest", width - 3)
        return
    end
    for index, node in ipairs(nodes) do
        local y = 4 + index
        if y >= height - 1 then break end
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

function UI:_requests(model)
    local surface = self.surface
    local width, height = surface.getSize()
    surface.setTextColor(palette.cyan); writeClipped(surface, 2, 3, "REQUESTS", width - 2)
    local requests = model.requests or {}
    if #requests == 0 then
        surface.setTextColor(palette.lightGray)
        writeClipped(surface, 2, 5, "No requests yet", width - 3)
        writeClipped(surface, 2, 6, "Press 1 and search for an item to retrieve", width - 3)
        return
    end
    for index, request in ipairs(requests) do
        local y = 4 + index
        if y >= height - 1 then break end
        surface.setTextColor(stateColor(request.state))
        writeClipped(surface, 2, y, request.state or "", 12)
        surface.setTextColor(palette.white)
        writeClipped(surface, 15, y, request.display_name or request.id, width - 29)
        local progress = formatNumber(request.delivered or 0) .. " / " ..
            formatNumber(request.requested or 0)
        surface.setTextColor(palette.lightGray)
        writeClipped(surface, math.max(16, width - #progress - 1), y, progress, #progress)
    end
end

function UI:_alerts(model)
    local surface = self.surface
    local width, height = surface.getSize()
    surface.setTextColor(palette.cyan); writeClipped(surface, 2, 3, "ALERTS", width - 2)
    local alerts = model.alerts or {}
    if #alerts == 0 then
        surface.setTextColor(palette.lime)
        writeClipped(surface, 2, 5, "No active alerts", width - 3)
        surface.setTextColor(palette.lightGray)
        writeClipped(surface, 2, 6, "Storage conditions are healthy", width - 3)
        return
    end
    for index, alert in ipairs(alerts) do
        local y = 4 + index
        if y >= height - 1 then break end
        surface.setTextColor(alert.severity == "critical" and palette.red or palette.yellow)
        writeClipped(surface, 2, y, alert.acknowledged and "-" or "!", 1)
        surface.setTextColor(palette.white)
        writeClipped(surface, 4, y, alert.message, width - 5)
    end
end

function UI:_setup(model)
    local surface = self.surface
    local width = surface.getSize()
    surface.setTextColor(palette.cyan); writeClipped(surface, 2, 3, "SETUP", width - 2)
    surface.setTextColor(palette.white)
    writeClipped(surface, 2, 5, "Review or change inventory roles", width - 3)
    surface.setTextColor(palette.lightGray)
    writeClipped(surface, 2, 7, "Drop-off: " .. tostring(model.dropoff and model.dropoff.state or "unassigned"), width - 3)
    writeClipped(surface, 2, 8, "Pickup:  " .. tostring(model.pickup and model.pickup.state or "unassigned"), width - 3)
    writeClipped(surface, 2, 10, "Enter opens the full setup wizard", width - 3)
end

function UI:_overlay(state)
    local surface = self.surface
    local width, height = surface.getSize()
    local boxWidth = math.min(40, width - 4)
    if boxWidth < 18 then return end
    local left = math.floor((width - boxWidth) / 2) + 1
    local top = math.max(4, math.floor((height - 7) / 2))
    for y = top, math.min(height - 1, top + 6) do fill(surface, y, palette.gray) end
    if state.mode == "quantity" then
        surface.setTextColor(palette.cyan)
        writeClipped(surface, left + 2, top, "Retrieve " ..
            tostring(state.identity.display_name or state.identity.name), boxWidth - 4)
        surface.setTextColor(palette.white)
        writeClipped(surface, left + 2, top + 1,
            formatNumber(state.identity.available) .. " available", boxWidth - 4)
        writeClipped(surface, left + 2, top + 2,
            "Amount: " .. (state.quantity_text ~= "" and state.quantity_text or "_"), boxWidth - 4)
        surface.setTextColor(palette.lightGray)
        writeClipped(surface, left + 2, top + 4, "Enter 1   S stack   A all", boxWidth - 4)
        writeClipped(surface, left + 2, top + 5, "Digits exact   F10 back", boxWidth - 4)
    elseif state.mode == "variant" then
        surface.setTextColor(palette.cyan)
        writeClipped(surface, left + 2, top, "Choose exact variant", boxWidth - 4)
        for index, variant in ipairs(state.variants or {}) do
            if index > 4 then break end
            surface.setTextColor(index == state.variant_selection and palette.black or palette.white)
            if index == state.variant_selection then fill(surface, top + index, palette.cyan) end
            writeClipped(surface, left + 2, top + index,
                (index == state.variant_selection and "> " or "  ") .. variant.display_name,
                boxWidth - 4)
        end
        surface.setTextColor(palette.lightGray)
        writeClipped(surface, left + 2, top + 5, "Enter select   F10 back", boxWidth - 4)
    end
end

function UI:_setupWizard(state, model)
    local surface = self.surface
    local width, height = surface.getSize()
    local names = {
        "Discover inventories", "Assign Drop-off", "Assign Pickup",
        "Storage nodes", "Validate layout", "Review and enable",
    }
    fill(surface, 1, palette.gray)
    surface.setTextColor(palette.white)
    writeClipped(surface, 2, 1, "SETUP WIZARD", 20)
    local progress = tostring(state.setup_step or 1) .. " / " .. #names
    surface.setTextColor(palette.cyan)
    writeClipped(surface, math.max(2, width - #progress - 1), 1, progress, #progress)
    surface.setTextColor(palette.cyan)
    writeClipped(surface, 2, 3, names[state.setup_step or 1] or "Setup", width - 3)
    surface.setTextColor(palette.lightGray)
    writeClipped(surface, 2, 4, "Select the exact wired inventory for this role.", width - 3)
    local choices = state.setup_choices or {}
    if #choices == 0 then
        writeClipped(surface, 2, 6, "No choices on this step", width - 3)
    else
        for index, choice in ipairs(choices) do
            local y = 5 + index
            if y >= height - 3 then break end
            local selected = index == state.selection
            fill(surface, y, selected and palette.cyan or palette.black)
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
    elseif state.page == "storage" then self:_storage(model)
    elseif state.page == "requests" then self:_requests(model)
    elseif state.page == "alerts" then self:_alerts(model)
    else self:_setup(model) end
    self:_footer(state, model)
    if state.mode == "quantity" or state.mode == "variant" then self:_overlay(state) end
    surface.setBackgroundColor(palette.black)
    surface.setTextColor(palette.white)
    surface.setCursorBlink(state.mode == "search")
    return { hit_regions=hitRegions }
end

return UI
