-- The single source of truth for what every key does. `keymap.lua` decides what a keypress
-- means; this module decides how that gets described to an operator, in the footer hint line
-- and in the F1 help modal. Before this existed the footer was a block of hand-written
-- strings that drifted from what keymap.lua actually accepted -- this table is what both the
-- footer and the modal read, so a control that changes here changes in both places at once.
--
-- Each entry: `key` is the display form (matching how the footer already wrote them, e.g.
-- "Up/Down", "F10"), `label` is the terse footer wording, `detail` is the fuller modal
-- sentence, `important` marks entries the footer is allowed to show, and the optional
-- `when(state)` predicate gates an entry that keymap.lua itself only accepts in some states.
-- Every entry here must be something keymap.command actually accepts in the states `when`
-- allows -- tests.test_help drives keymap.command directly to enforce that.
local M = {}

-- Mirrors keymap.lua's own recovery-release guard: once armed, every key on the Alerts page
-- either confirms, re-arms, or cancels, so none of the ordinary page or global controls (nor
-- Help itself) actually do what they normally do there.
local function recoveryArmed(state)
    return state.mode == "page" and state.page == "alerts" and state.recovery_confirm_armed
end

-- "Global" is aspirational: keymap.lua refuses P inside the two search boxes and craft_plan
-- (letters and P-as-pin are spoken for), refuses the digit page shortcuts inside quantity,
-- variant and craft_quantity (digits are the input there), and the setup/setup_rename modes
-- never reach the shared dispatch at all because their own blocks return unconditionally.
-- Encoding those suppressions here, rather than assuming a global control always fires, is
-- what keeps the modal from advertising a key that does nothing.
M.global = {
    {key="F10", label="back", detail="Leave this screen and go back", important=true,
        when=function(state)
            return state.mode ~= "search" and state.mode ~= "craft_search" and
                state.mode ~= "setup" and state.mode ~= "setup_rename" and
                state.mode ~= "help" and not recoveryArmed(state)
        end},
    {key="P", label="pause", detail="Pause or resume automation", important=true,
        when=function(state)
            return state.mode ~= "search" and state.mode ~= "craft_search" and
                state.mode ~= "craft_plan" and state.mode ~= "setup" and
                state.mode ~= "setup_rename" and state.mode ~= "help" and
                not recoveryArmed(state)
        end},
    {key="1-6", label=nil, detail="Switch pages", important=false,
        when=function(state)
            return state.mode ~= "quantity" and state.mode ~= "variant" and
                state.mode ~= "craft_quantity" and state.mode ~= "setup" and
                state.mode ~= "setup_rename" and state.mode ~= "help" and
                not recoveryArmed(state)
        end},
    {key="F1", label=nil, detail="Open this help screen", important=false,
        when=function(state) return state.mode ~= "help" and not recoveryArmed(state) end},
}

M.per_mode = {
    -- Ordered so the entry the layout test pins ("Delete clear") survives narrowing first:
    -- the footer drops trailing whole entries when a line does not fit, so the entry every
    -- width must keep has to come first, not last.
    search = {
        {key="Delete", label="clear", detail="Clear the search box", important=true},
        {key="Enter", label="retrieve", detail="Open the retrieve prompt for the selected item",
            important=true},
        {key="Up/Down", label="select", detail="Move the selection up or down the result list",
            important=true},
    },
    quantity = {
        {key="Enter", label="1", detail="Request one", important=true},
        {key="S", label="stack", detail="Request a full stack", important=true},
        {key="A", label="all", detail="Request everything available", important=true},
        {key="0-9", label="exact", detail="Type an exact quantity, then Enter", important=true},
        {key="C", label="craft", detail="Plan a craft for what storage cannot fill",
            important=false},
    },
    variant = {
        {key="Up/Down", label="select", detail="Move the selection among exact variants",
            important=true},
        {key="Enter", label="select", detail="Choose the highlighted variant", important=true},
    },
    craft_search = {
        {key="Delete", label="clear", detail="Clear the recipe search box", important=true},
        {key="Enter", label="choose", detail="Open the quantity prompt for the selected recipe",
            important=true},
        {key="Tab", label="jobs", detail="View craft jobs", important=true},
        {key="Up/Down", label="select", detail="Move the selection up or down the recipe list",
            important=true},
    },
    craft_quantity = {
        {key="0-9", label="amount", detail="Type the quantity to craft", important=true},
        {key="Enter", label="plan", detail="Plan the craft", important=true},
        {key="A", label="max", detail="Plan the maximum craftable amount", important=true},
    },
    craft_plan = {
        {key="Enter", label="craft", detail="Commit the plan", important=true},
        {key="D", label="destination", detail="Toggle delivery between storage and pickup",
            important=true},
        {key="P", label="pin choice", detail="Pin the highlighted tag or recipe choice",
            important=true},
        {key="Up/Down", label="select", detail="Move the selection among chosen tags",
            important=false},
    },
    craft_jobs = {
        {key="Up/Down", label="select", detail="Move the selection among craft jobs",
            important=true},
        {key="R", label="retry", detail="Retry the selected craft job", important=true},
        {key="C", label="cancel", detail="Cancel the selected craft job", important=true},
        {key="Enter", label="confirm", detail="Confirm the selected craft job", important=true},
        {key="Tab", label="search", detail="Return to recipe search", important=true},
    },
    setup = {
        {key="Up/Down", label="select", detail="Move the selection", important=true},
        {key="Enter", label="select", detail="Choose the highlighted option", important=true},
        {key="Left", label="back", detail="Go to the previous step", important=true},
        {key="Right", label="next", detail="Go to the next step", important=true},
        {key="F10", label="cancel", detail="Cancel setup and return to the Setup page",
            important=true},
        {key="R", label="rename", detail="Rename the selected storage node", important=true,
            when=function(state) return state.setup_step == 4 end},
    },
    setup_rename = {
        {key="Enter", label="save", detail="Save the new name", important=true},
        {key="Backspace", label=nil, detail="Delete the last character", important=true},
        {key="Delete", label="clear", detail="Clear the text", important=true},
        {key="Left", label="cancel", detail="Cancel the rename", important=true},
    },
    -- mode="page" covers four different pages; the digit shortcuts and Enter-to-open-setup
    -- live under state.page, since "page" alone does not say which one.
    page = {
        storage = {
            {key="Up/Down", label="scroll", detail="Scroll the node list", important=true},
        },
        requests = {
            {key="Up/Down", label="select", detail="Move the selection among requests",
                important=true},
            {key="R", label="retry", detail="Retry the selected request", important=true},
            {key="C", label="cancel", detail="Cancel the selected request", important=true},
        },
        alerts = {
            {key="Up/Down", label=nil, detail="Move the selection among alerts", important=true,
                when=function(state) return not recoveryArmed(state) end},
            {key="A", label="dismiss", detail="Dismiss the selected alert", important=true,
                when=function(state) return not recoveryArmed(state) end},
            -- The recovery release confirm is its own two-key sequence, not the ordinary
            -- dismiss above: Enter confirms release, A re-arms it, and every other key
            -- (including F10 and the globals) cancels rather than doing its usual job.
            {key="Enter", label="confirm release", detail="Give up proof of what an " ..
                "interrupted transfer moved and release recovery", important=true,
                when=recoveryArmed},
            {key="A", label="re-arm", detail="Arm the recovery release again", important=true,
                when=recoveryArmed},
        },
        setup = {
            {key="Enter", label="setup", detail="Open the full setup wizard", important=false},
        },
    },
}

local function important(entry) return entry.important end
local function notImportant(entry) return not entry.important end

local function filter(list, state, predicate)
    local result = {}
    for _, entry in ipairs(list or {}) do
        if (not predicate or predicate(entry)) and (not entry.when or entry.when(state)) then
            result[#result + 1] = entry
        end
    end
    return result
end

-- Ordered important-first, then non-important, each group keeping registry order -- the
-- order the modal lists a section in.
local function ordered(list, state)
    local result = filter(list, state, important)
    for _, entry in ipairs(filter(list, state, notImportant)) do result[#result + 1] = entry end
    return result
end

function M.contextEntries(state)
    if state.mode == "page" then return (M.per_mode.page or {})[state.page] or {} end
    return M.per_mode[state.mode] or {}
end

-- The footer's list: this context's entries first (so a page's own controls read before the
-- generic ones), then the globals that actually apply here, important only, registry order.
function M.footerEntries(state)
    local entries = filter(M.contextEntries(state), state, important)
    for _, entry in ipairs(filter(M.global, state, important)) do entries[#entries + 1] = entry end
    return entries
end

local function entryText(entry)
    return entry.label and (entry.key .. " " .. entry.label) or entry.key
end

-- Never pulls in a non-important entry to fill leftover width, and never clips a label mid-
-- word: when the joined line does not fit, whole trailing entries are dropped instead.
function M.footerText(state, width)
    width = width or math.huge
    local entries = M.footerEntries(state)
    for count = #entries, 0, -1 do
        local parts = {}
        for index = 1, count do parts[#parts + 1] = entryText(entries[index]) end
        local text = table.concat(parts, "  ")
        if #text <= width then return text end
    end
    return ""
end

-- The modal's content: "This page" (the mode being returned to) then "Everywhere" (the
-- globals that apply there), important entries first within each section.
function M.modalSections(state)
    return {
        {title = "This page", entries = ordered(M.contextEntries(state), state)},
        {title = "Everywhere", entries = ordered(M.global, state)},
    }
end

return M
