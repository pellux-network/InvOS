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
    if name == "paste" and state.mode == "craft_search" then
        return {type="CRAFT_QUERY_APPEND",text=tostring(event[2] or "")}
    end
    if name == "char" then
        local character = tostring(event[2] or "")
        if state.suppress_char == character then
            return {type="CONSUME_CHAR",text=character}
        end
        if state.mode == "search" then return {type="QUERY_APPEND",text=character} end
        if state.mode == "craft_search" then return {type="CRAFT_QUERY_APPEND",text=character} end
        if state.mode == "quantity" and character:match("^%d$") then
            return {type="SET_QUANTITY",digit=character}
        end
        if state.mode == "craft_quantity" and character:match("^%d$") then
            return {type="SET_CRAFT_QUANTITY",digit=character}
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

    if key == keys.f10 and state.mode ~= "search" and state.mode ~= "craft_search" then
        return {type="CANCEL"}
    end

    -- Pause is available everywhere except the search text box, where letter keys are
    -- ordinary query characters.
    if state.mode ~= "search" and state.mode ~= "craft_search" and
        state.mode ~= "craft_plan" and key == keys.p then return {type="TOGGLE_PAUSE"} end

    -- Digits stay page shortcuts inside both search boxes, exactly as they are on the
    -- Search page: the paired char event is suppressed so the digit never lands in the
    -- query. Only the quantity boxes claim digits, because there they are the input.
    if state.mode ~= "quantity" and state.mode ~= "variant" and
        state.mode ~= "craft_quantity" then
        local pages, digits = {}, {}
        if keys.one then pages[keys.one],digits[keys.one]="search","1" end
        if keys.two then pages[keys.two],digits[keys.two]="storage","2" end
        if keys.three then pages[keys.three],digits[keys.three]="requests","3" end
        if keys.four then pages[keys.four],digits[keys.four]="alerts","4" end
        if keys.five then pages[keys.five],digits[keys.five]="setup","5" end
        if keys.six then pages[keys.six],digits[keys.six]="crafting","6" end
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
    -- The Crafting page is search-first like the Search page, so typing filters recipes
    -- and the action keys live in the plan and job modes rather than here.
    if state.mode == "craft_search" then
        if key == keys.backspace then return {type="CRAFT_QUERY_BACKSPACE"} end
        if key == keys.up then return {type="MOVE",delta=-1} end
        if key == keys.down then return {type="MOVE",delta=1} end
        if key == keys.enter then return {type="OPEN_CRAFT_QUANTITY"} end
        if key == keys.tab then return {type="OPEN_CRAFT_JOBS"} end
    elseif state.mode == "craft_quantity" then
        if key == keys.a then return {type="CRAFT_QUANTITY_MAX",char="a"} end
        if key == keys.backspace then return {type="CRAFT_QUANTITY_BACKSPACE"} end
        if key == keys.enter then return {type="PLAN_CRAFT"} end
    elseif state.mode == "craft_plan" then
        -- Nothing has moved yet at this point; Enter is the only thing that commits.
        if key == keys.enter then return {type="COMMIT_CRAFT"} end
        if key == keys.d then return {type="TOGGLE_CRAFT_DESTINATION"} end
        if key == keys.p then return {type="PIN_CRAFT_CHOICE"} end
        if key == keys.up then return {type="MOVE",delta=-1} end
        if key == keys.down then return {type="MOVE",delta=1} end
    elseif state.mode == "craft_jobs" then
        if key == keys.up then return {type="MOVE",delta=-1} end
        if key == keys.down then return {type="MOVE",delta=1} end
        if key == keys.r then return {type="RETRY_CRAFT"} end
        if key == keys.c then return {type="CANCEL_CRAFT"} end
        if key == keys.enter then return {type="CONFIRM_CRAFT"} end
        if key == keys.tab then return {type="OPEN_CRAFT_SEARCH"} end
    end
    if state.mode == "page" and state.page == "alerts" then
        if key == keys.a then return {type="ACKNOWLEDGE_ALERT"} end
        if key == keys.x then return {type="ARM_RECOVERY_RELEASE"} end
    end

    if state.mode == "quantity" and key == keys.c then
        -- Shortcut from a retrieval that cannot be filled: plan the shortfall instead.
        return {type="OPEN_CRAFT_FOR_SELECTION", char="c"}
    end
    if state.mode == "search" then
        if key == keys.backspace then return {type="QUERY_BACKSPACE"} end
        if key == keys.up then return {type="MOVE",delta=-1} end
        if key == keys.down then return {type="MOVE",delta=1} end
        if key == keys.enter then return {type="OPEN_QUANTITY"} end
    elseif state.mode == "quantity" then
        -- A REQUEST here drops mode back to "search" before the char event that
        -- shares this keypress arrives, so name it for suppression there.
        if key == keys.s then return {type="REQUEST",quantity="stack",char="s"} end
        if key == keys.a then return {type="REQUEST",quantity="all",char="a"} end
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
