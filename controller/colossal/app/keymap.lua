local M = {}

local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return result
end

local function hitCommand(state, x, y)
    for _, region in ipairs(state.hit_regions or {}) do
        if x >= region.x1 and x <= region.x2 and y >= region.y1 and y <= region.y2 then
            return clone(region.command)
        end
    end
end

function M.command(event, state)
    if type(event) ~= "table" or type(state) ~= "table" then return nil end
    local name = event[1]
    if name == "mouse_click" then return hitCommand(state, event[3], event[4]) end
    if name == "mouse_scroll" then
        return {type="MOVE",delta=event[2] > 0 and 1 or -1}
    end
    if name == "paste" and state.mode == "search" then
        return {type="QUERY_APPEND",text=tostring(event[2] or "")}
    end
    if name == "char" then
        local character = tostring(event[2] or "")
        if state.suppress_char == character then
            return {type="CONSUME_CHAR",text=character}
        end
        if state.mode == "search" then return {type="QUERY_APPEND",text=character} end
        if state.mode == "quantity" and character:match("^%d$") then
            return {type="SET_QUANTITY",digit=character}
        end
        return nil
    end
    if name ~= "key" then return nil end

    local key = event[2]
    if key == keys.escape then return nil end
    if state.mode == "setup" then
        if key == keys.f10 then return {type="CANCEL_SETUP"} end
        if key == keys.up then return {type="SETUP_MOVE",delta=-1} end
        if key == keys.down then return {type="SETUP_MOVE",delta=1} end
        if key == keys.enter then return {type="SETUP_SELECT"} end
        if key == keys.left or key == keys.backspace then return {type="SETUP_BACK"} end
        if key == keys.right then return {type="SETUP_NEXT"} end
        return nil
    end
    -- A recovery release abandons proof of what an interrupted transfer moved, so once
    -- armed, every key either confirms, re-arms, or cancels: nothing falls through to
    -- ordinary page navigation while the destructive action is primed.
    if state.mode == "page" and state.page == "alerts" and state.recovery_confirm_armed then
        if key == keys.enter then return {type="CONFIRM_RECOVERY_RELEASE"} end
        if key == keys.x then return {type="ARM_RECOVERY_RELEASE"} end
        return {type="CANCEL_RECOVERY_RELEASE"}
    end

    if key == keys.f10 and state.mode ~= "search" then return {type="CANCEL"} end

    -- Pause is available everywhere except the search text box, where letter keys are
    -- ordinary query characters.
    if state.mode ~= "search" and key == keys.p then return {type="TOGGLE_PAUSE"} end

    if state.mode ~= "quantity" and state.mode ~= "variant" then
        local pages, digits = {}, {}
        if keys.one then pages[keys.one],digits[keys.one]="search","1" end
        if keys.two then pages[keys.two],digits[keys.two]="storage","2" end
        if keys.three then pages[keys.three],digits[keys.three]="requests","3" end
        if keys.four then pages[keys.four],digits[keys.four]="alerts","4" end
        if keys.five then pages[keys.five],digits[keys.five]="setup","5" end
        if pages[key] then
            return {type="OPEN_PAGE",page=pages[key],suppress_char=digits[key]}
        end
    end
    if state.mode == "page" and state.page == "setup" and key == keys.enter then
        return {type="OPEN_SETUP"}
    end
    if state.mode == "page" and (state.page == "storage" or state.page == "requests" or
        state.page == "alerts") then
        if key == keys.up then return {type="MOVE",delta=-1} end
        if key == keys.down then return {type="MOVE",delta=1} end
    end
    if state.mode == "page" and state.page == "requests" then
        if key == keys.r then return {type="RETRY_REQUEST"} end
        if key == keys.c then return {type="CANCEL_REQUEST"} end
    end
    if state.mode == "page" and state.page == "alerts" then
        if key == keys.a then return {type="ACKNOWLEDGE_ALERT"} end
        if key == keys.x then return {type="ARM_RECOVERY_RELEASE"} end
    end

    if state.mode == "search" then
        if key == keys.backspace then return {type="QUERY_BACKSPACE"} end
        if key == keys.up then return {type="MOVE",delta=-1} end
        if key == keys.down then return {type="MOVE",delta=1} end
        if key == keys.enter then return {type="OPEN_QUANTITY"} end
    elseif state.mode == "quantity" then
        if key == keys.s then return {type="REQUEST",quantity="stack"} end
        if key == keys.a then return {type="REQUEST",quantity="all"} end
        if key == keys.backspace then return {type="QUANTITY_BACKSPACE"} end
        if key == keys.enter then
            local text = state.quantity_text or ""
            if text == "" then return {type="REQUEST",quantity="one"} end
            local quantity = tonumber(text)
            if quantity and quantity >= 1 and quantity % 1 == 0 then
                return {type="REQUEST",quantity=quantity}
            end
        end
    elseif state.mode == "variant" then
        if key == keys.up then return {type="MOVE",delta=-1} end
        if key == keys.down then return {type="MOVE",delta=1} end
        if key == keys.enter then return {type="ACTIVATE"} end
    end
    return nil
end

return M
