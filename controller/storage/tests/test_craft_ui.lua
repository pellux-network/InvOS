-- CC exposes `keys` as a global. test_keymap defines its own copy, but this module is
-- required earlier in the run, so it needs one of its own rather than depending on load
-- order. Includes six/tab/d, which the crafting page uses.
keys = keys or {}
for name, code in pairs({
    backspace=14, up=200, down=208, enter=28, tab=15, s=31, a=30, d=32, f10=68,
    escape=1, one=2, two=3, three=4, four=5, five=6, six=7,
    r=19, c=46, p=25, x=45,
}) do
    if keys[name] == nil then keys[name] = code end
end

local Keymap = require("app.keymap")
local UI = require("app.ui")
local Draw = require("app.draw")
local T = require("tests.mock_cc")

local function ui() return UI.new(T.recordingSurface(51, 19)) end

local function crafting(overrides)
    local state = UI.initialState()
    state.page, state.mode = "crafting", "craft_search"
    state.craft_results = {
        {item="minecraft:chest", display_name="Chest", quantity=0},
        {item="minecraft:stick", display_name="Stick", quantity=12},
    }
    state.craft_result_count = 2
    for key, value in pairs(overrides or {}) do state[key] = value end
    return state
end

local function samplePlan()
    return {ok=true, item="minecraft:chest", quantity=2,
        steps={{item="minecraft:oak_planks", produced=8},{item="minecraft:chest", produced=2}},
        withdrawals={{item="minecraft:oak_log", count=2}},
        chosen={{tag="minecraft:planks", item="minecraft:oak_planks"}},
        shortfalls={}}
end

return {
    {name="key 6 opens the crafting page in search mode",run=function()
        local command = Keymap.command({"key", keys.six}, {mode="page", page="search"})
        T.equal(command.type, "OPEN_PAGE")
        T.equal(command.page, "crafting")
        local state = ui():reduce(UI.initialState(), command)
        T.equal(state.page, "crafting")
        T.equal(state.mode, "craft_search", "typing must filter recipes straight away")
    end},
    {name="key 5 still opens setup",run=function()
        local command = Keymap.command({"key", keys.five}, {mode="page", page="search"})
        T.equal(command.page, "setup", "renumbering setup would break muscle memory")
    end},
    {name="typing filters recipes without touching the retrieval search",run=function()
        local surface = ui()
        local state = surface:reduce(crafting(), {type="CRAFT_QUERY_APPEND", text="ch"})
        T.equal(state.craft_query, "ch")
        T.equal(state.query, "", "the two search boxes are independent")
    end},
    {name="recipes with no stock are still listed",run=function()
        local surface = ui()
        surface:render(crafting(), {})
        local text = surface.surface.allText()
        T.contains(text, "Chest")
        T.contains(text, "0")
    end},
    {name="only the selected recipe's name scrolls; unselected long names hold still",
        run=function()
        local longName = "A Very Long Recipe Name That Overflows Any Reasonable Column Width"
        local prefix = longName:sub(1, 8)
        local state = crafting({craft_results={
            {item="minecraft:a", display_name=longName, quantity=0},
            {item="minecraft:b", display_name=longName, quantity=5},
        }, craft_result_count=2, craft_selection=1})
        local surface = ui()
        local now = (Draw.MARQUEE_HOLD_STEPS + 2) * Draw.MARQUEE_STEP_MS
        surface:render(state, {lifecycle="READY", now=now})
        local text = surface.surface.allText()
        local occurrences, from = 0, 1
        while true do
            local found = text:find(prefix, from, true)
            if not found then break end
            occurrences = occurrences + 1
            from = found + 1
        end
        T.equal(occurrences, 1,
            "the literal prefix must appear exactly once, from the unselected row only")
    end},
    {name="the selected recipe's name and id scroll in the SELECTED pane",run=function()
        local longName = "A Very Long Recipe Name That Overflows Any Reasonable Column Width"
        local longId = "somemod:a_very_long_item_id_that_overflows_any_reasonable_column"
        local state = crafting({craft_results={
            {item=longId, display_name=longName, quantity=3},
        }, craft_result_count=1, craft_selection=1})
        local surface = ui()
        local atStart = surface.surface
        surface:render(state, {lifecycle="READY", now=0})
        local startText = atStart.allText()
        T.contains(startText, longName:sub(1, 8))
        T.contains(startText, longId:sub(1, 8))

        local later = ui()
        local now = (Draw.MARQUEE_HOLD_STEPS + 2) * Draw.MARQUEE_STEP_MS
        later:render(state, {lifecycle="READY", now=now})
        local laterText = later.surface.allText()
        T.equal(laterText:find(longName:sub(1, 8), 1, true), nil,
            "the display name must have scrolled away from its starting position")
        T.equal(laterText:find(longId:sub(1, 8), 1, true), nil,
            "the item id must have scrolled away from its starting position")
    end},
    {name="choosing an item asks for a quantity",run=function()
        local surface = ui()
        local state = surface:reduce(crafting(), {type="OPEN_CRAFT_QUANTITY"})
        T.equal(state.mode, "craft_quantity")
        T.equal(state.craft_item.item, "minecraft:chest")
    end},
    {name="clicking a craft result dispatches ACTIVATE, matching how Search rows behave",
        run=function()
        local surface = ui()
        local state = crafting()
        local layout = surface:render(state, {lifecycle="READY"})
        local row
        for y = 1, 19 do if surface.surface.line(y):find("Stick", 1, true) then row = y end end
        T.truthy(row ~= nil, "Stick is not on screen")
        state.hit_regions = layout.hit_regions
        local command = Keymap.command({"mouse_click", 1, 5, row}, state)
        T.truthy(command ~= nil, "clicking a craft result did nothing")
        T.equal(command.type, "ACTIVATE", "craft rows must dispatch ACTIVATE like Search rows do")
        T.equal(command.index, 2)
    end},
    {name="clicking a craft result twice opens the quantity prompt; once only selects it",
        run=function()
        local surface = ui()
        local state = crafting()
        state = surface:reduce(state, {type="ACTIVATE", index=2})
        T.equal(state.craft_selection, 2)
        T.equal(state.mode, "craft_search",
            "the first click must only highlight, not open the quantity prompt")
        state = surface:reduce(state, {type="ACTIVATE", index=2})
        T.equal(state.mode, "craft_quantity", "a second click on the same recipe opens quantity")
        T.equal(state.craft_item.item, "minecraft:stick")
    end},
    {name="typing in the recipe search re-arms the click so a repeat click only selects",
        run=function()
        local surface = ui()
        local state = crafting()
        state = surface:reduce(state, {type="ACTIVATE", index=1})
        state = surface:reduce(state, {type="CRAFT_QUERY_APPEND", text="c"})
        state.craft_results, state.craft_result_count = crafting().craft_results, 2
        state = surface:reduce(state, {type="ACTIVATE", index=1})
        T.equal(state.mode, "craft_search",
            "typing must re-arm the click so the next one only selects")
    end},
    {name="a quantity is typed and planned",run=function()
        local surface = ui()
        local state = surface:reduce(crafting({mode="craft_quantity",
            craft_item={item="minecraft:chest"}}), {type="SET_CRAFT_QUANTITY", digit="4"})
        T.equal(state.craft_quantity_text, "4")
        local _, effect = surface:reduce(state, {type="PLAN_CRAFT"})
        T.equal(effect.type, "PLAN_CRAFT")
        T.equal(effect.quantity, 4)
        T.equal(effect.item, "minecraft:chest")
    end},
    {name="an empty quantity means one",run=function()
        local surface = ui()
        local _, effect = surface:reduce(crafting({mode="craft_quantity",
            craft_item={item="minecraft:chest"}}), {type="PLAN_CRAFT"})
        T.equal(effect.quantity, 1)
    end},
    {name="A asks for the maximum craftable",run=function()
        local surface = ui()
        local _, effect = surface:reduce(crafting({mode="craft_quantity",
            craft_item={item="minecraft:chest"}}), {type="CRAFT_QUANTITY_MAX", char="a"})
        T.equal(effect.quantity, "max")
    end},
    {name="the plan is shown before anything moves",run=function()
        local surface = ui()
        local state = surface:reduce(crafting(),
            {type="SYNC_CRAFT_PLAN", plan=samplePlan(), item={display_name="Chest"}})
        T.equal(state.mode, "craft_plan")
        surface:render(state, {})
        local text = surface.surface.allText()
        T.contains(text, "PLAN")
        T.contains(text, "oak_planks")
        T.contains(text, "use 2 x minecraft:oak_log")
        T.contains(text, "deliver to pickup")
    end},
    {name="nothing is committed until Enter is pressed on the plan",run=function()
        local surface = ui()
        local state = surface:reduce(crafting(), {type="SYNC_CRAFT_PLAN", plan=samplePlan()})
        local following, effect = surface:reduce(state, {type="COMMIT_CRAFT"})
        T.equal(effect.type, "COMMIT_CRAFT")
        T.equal(effect.item, "minecraft:chest")
        T.equal(effect.quantity, 2)
        T.equal(effect.destination, "pickup")
        T.equal(following.mode, "craft_jobs", "committing shows the queue")
    end},
    {name="an impossible plan cannot be committed",run=function()
        local surface = ui()
        local plan = samplePlan()
        plan.ok = false
        plan.shortfalls = {{item="minecraft:oak_log", missing=4}}
        local state = surface:reduce(crafting(), {type="SYNC_CRAFT_PLAN", plan=plan})
        local _, effect = surface:reduce(state, {type="COMMIT_CRAFT"})
        T.equal(effect, nil, "a plan that cannot succeed must not be committable")
        surface:render(state, {})
        T.contains(surface.surface.allText(), "Cannot craft")
        T.contains(surface.surface.allText(), "4 x minecraft:oak_log")
    end},
    {name="the delivery destination toggles, defaulting to Pickup",run=function()
        local surface = ui()
        local state = crafting({craft_plan=samplePlan(), mode="craft_plan"})
        T.equal(state.craft_destination, "pickup")
        state = surface:reduce(state, {type="TOGGLE_CRAFT_DESTINATION"})
        T.equal(state.craft_destination, "storage")
        state = surface:reduce(state, {type="TOGGLE_CRAFT_DESTINATION"})
        T.equal(state.craft_destination, "pickup")
    end},
    {name="a tag choice can be pinned from the plan",run=function()
        local surface = ui()
        local state = crafting({craft_plan=samplePlan(), mode="craft_plan",
            craft_plan_selection=1})
        local _, effect = surface:reduce(state, {type="PIN_CRAFT_CHOICE"})
        T.equal(effect.type, "PIN_CRAFT_CHOICE")
        T.equal(effect.tag, "minecraft:planks")
        T.equal(effect.item, "minecraft:oak_planks")
    end},
    {name="the job list marks the running job and numbers the queue",run=function()
        local surface = ui()
        local state = crafting({mode="craft_jobs"})
        state = surface:reduce(state, {type="SYNC_CRAFT_JOBS", jobs={
            {item="minecraft:chest", display_name="Chest", state="STAGING"},
            {item="minecraft:stick", display_name="Stick", state="QUEUED"},
        }})
        T.equal(state.craft_job_count, 2)
        surface:render(state, {})
        local text = surface.surface.allText()
        T.contains(text, "STAGING")
        T.contains(text, "QUEUED #1")
    end},
    {name="retry, cancel and confirm act on the highlighted job",run=function()
        local surface = ui()
        local state = crafting({mode="craft_jobs", craft_job_selection=2, craft_job_count=2})
        for _, pair in ipairs({{"RETRY_CRAFT"}, {"CANCEL_CRAFT"}, {"CONFIRM_CRAFT"}}) do
            local _, effect = surface:reduce(state, {type=pair[1]})
            T.equal(effect.type, pair[1])
            T.equal(effect.index, 2)
        end
    end},
    {name="F10 steps back one level instead of leaving the page",run=function()
        local surface = ui()
        local state = crafting({mode="craft_plan", craft_plan=samplePlan()})
        state = surface:reduce(state, {type="CANCEL"})
        T.equal(state.mode, "craft_quantity")
        T.equal(state.page, "crafting", "backing out of a plan must not lose the search")
        state = surface:reduce(state, {type="CANCEL"})
        T.equal(state.mode, "craft_search")
        state = surface:reduce(state, {type="CANCEL"})
        T.equal(state.page, "search", "from the top level it leaves")
    end},
    {name="C on a retrieval plans only the shortfall",run=function()
        local surface = ui()
        local state = UI.initialState()
        state.mode = "quantity"
        state.results = {{name="minecraft:chest", display_name="Chest", quantity=10}}
        state.selection, state.quantity_text = 1, "64"
        local following, effect = surface:reduce(state, {type="OPEN_CRAFT_FOR_SELECTION", char="c"})
        T.equal(effect.type, "PLAN_CRAFT")
        T.equal(effect.quantity, 54, "10 in stock of 64 asked for leaves 54 to craft")
        T.equal(following.page, "crafting")
    end},
    {name="the navigation bar offers the crafting page",run=function()
        local narrow = ui()
        narrow:render(crafting(), {})
        T.contains(narrow.surface.line(2), "6 CRAFT",
            "a page nobody can see listed is a page nobody finds")
        local wide = UI.new(T.recordingSurface(80, 19))
        wide:render(crafting(), {})
        T.contains(wide.surface.line(2), "6 CRAFTING")
        T.contains(wide.surface.line(2), "1 SEARCH")
    end},
    {name="digits leave the recipe search rather than typing into it",run=function()
        local command = Keymap.command({"key", keys.one}, {mode="craft_search", craft_query="ch"})
        T.equal(command.type, "OPEN_PAGE", "the recipe search must not trap the page shortcuts")
        T.equal(command.page, "search")
        T.equal(command.suppress_char, "1")
        local consume = Keymap.command({"char", "1"},
            {mode="craft_search", craft_query="ch", suppress_char="1"})
        T.equal(consume.type, "CONSUME_CHAR", "the paired char must not land in the query")
        T.equal(Keymap.command({"char", "1"}, {mode="craft_search", craft_query="ch"}).type,
            "CRAFT_QUERY_APPEND", "a bare digit still types when no shortcut fired")
    end},
    {name="a long recipe list scrolls to keep the selection visible",run=function()
        local results = {}
        for index = 1, 40 do
            results[index] = {item="minecraft:item"..index,
                display_name="Recipe "..index, quantity=index}
        end
        local surface = ui()
        surface:render(crafting({craft_results=results, craft_result_count=40,
            craft_selection=30}), {})
        local text = surface.surface.allText()
        T.contains(text, "Recipe 30", "the selected recipe must stay on screen")
        T.equal(text:find("Recipe 1 ", 1, true), nil,
            "the list must scroll rather than always starting at the top")
    end},
    {name="a long craft job list scrolls to keep the selection visible",run=function()
        local jobs = {}
        for index = 1, 40 do
            jobs[index] = {item="minecraft:item"..index,
                display_name="Job "..index, state="QUEUED"}
        end
        local surface = ui()
        surface:render(crafting({mode="craft_jobs", craft_jobs=jobs, craft_job_count=40,
            craft_job_selection=30}), {})
        local text = surface.surface.allText()
        T.contains(text, "Job 30", "the selected job must stay on screen")
        T.equal(text:find("Job 1 ", 1, true), nil,
            "the list must scroll rather than always starting at the top")
    end},
    {name="rendering a scrolled crafting list never mutates UI state",run=function()
        local results = {}
        for index = 1, 40 do
            results[index] = {item="minecraft:item"..index,
                display_name="Recipe "..index, quantity=index}
        end
        local state = crafting({craft_results=results, craft_result_count=40,
            craft_selection=30, craft_scroll=1})
        ui():render(state, {})
        T.equal(state.craft_scroll, 1, "render must not write a scroll offset back to state")
        T.equal(state.craft_selection, 30)
    end},
    {name="the crafting page uses the same selection colour as every other page",run=function()
        local Theme = require("app.theme")
        local surface = ui()
        surface:render(crafting({craft_selection=1}), {})
        local focus = 0
        for y = 1, 19 do
            if surface.surface.backgroundAt(2, y) == Theme.role.focus then focus = focus + 1 end
        end
        T.truthy(focus >= 1, "crafting used to fill grey while Search filled red")
    end},
    {name="the recipe list is labelled",run=function()
        local surface = ui()
        surface:render(crafting(), {})
        local text = surface.surface.allText()
        T.contains(text, "RECIPE")
        T.contains(text, "STOCK")
    end},
    {name="the plan names items rather than printing raw ids",run=function()
        local surface = ui()
        local state = crafting({mode="craft_plan", craft_plan=samplePlan(),
            craft_item={item="minecraft:chest", display_name="Chest"}})
        surface:render(state, {})
        T.contains(surface.surface.allText(), "Chest")
    end},
    {name="the crafting page has a detail pane like Search",run=function()
        local surface = ui()
        surface:render(crafting({craft_selection=1}), {})
        local text = surface.surface.allText()
        T.contains(text, "SELECTED", "crafting must be banded the same way Search is")
        T.contains(text, "minecraft:chest", "the pane must name the exact recipe output")
        T.contains(text, "ENTER")
    end},
    {name="the quantity prompt uses the pane rather than a band across the bottom",run=function()
        local surface = ui()
        local state = crafting({mode="craft_quantity", craft_quantity_text="12",
            craft_item={item="minecraft:chest", display_name="Chest"}})
        surface:render(state, {})
        local text = surface.surface.allText()
        T.contains(text, "How many")
        T.contains(text, "12")
        T.contains(text, "Chest", "the recipe list must stay visible while typing")
        T.contains(text, "Stick", "and so must the rest of the list")
    end},
    {name="the crafting page never draws outside its surface",run=function()
        for _, mode in ipairs({"craft_search", "craft_quantity", "craft_plan", "craft_jobs"}) do
            for _, size in ipairs({{51,19},{26,12},{18,8}}) do
                local surface = UI.new(T.recordingSurface(size[1], size[2]))
                local state = crafting({mode=mode, craft_plan=samplePlan(),
                    craft_jobs={{item="minecraft:chest", state="QUEUED"}}, craft_job_count=1})
                surface:render(state, {})
                T.equal(surface.surface.writesOutsideBounds(), 0,
                    mode .. " at " .. size[1] .. "x" .. size[2])
            end
        end
    end},
}
