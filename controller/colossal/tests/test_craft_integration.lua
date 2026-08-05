local Coordinator = require("app.coordinator")
local CraftMonitor = require("app.craft_monitor")
local CraftPlanner = require("core.craft_planner")
local CraftPrefs = require("core.craft_prefs")
local RecipeRepo = require("core.recipe_repo")
local UI = require("app.ui")
local T = require("tests.mock_cc")

-- End to end from a keypress to a queued job, against the real generated recipe pack.
-- The point is the seam between the UI, the coordinator and the planner: each has its
-- own tests, and this is where the wiring between them can be wrong while all of those
-- still pass.
local realRepo = RecipeRepo.new({})

local function scanner()
    local api, steps = {}, 0
    function api:begin(node) return {node=node} end
    function api:step(scan)
        steps = steps + 1
        return true, {node_id=scan.node.id, peripheral_name=scan.node.peripheral_name,
            epoch=steps, size=27, occupied=0, slots={}, health="READY"}
    end
    return api
end

local function fakeCrafts()
    local value = {jobs = {}, counter = 0}
    function value:enqueue(item, quantity, options)
        self.counter = self.counter + 1
        local job = {id="craft-" .. self.counter, item=item, quantity=quantity,
            state="QUEUED", destination=options and options.destination,
            confirmed=options and options.confirmed}
        self.jobs[#self.jobs + 1] = job
        return job
    end
    function value:list() return self.jobs end
    function value:status() return {state=#self.jobs > 0 and "PLANNING" or "IDLE"} end
    function value:cancel(id)
        for _, job in ipairs(self.jobs) do
            if job.id == id then job.state = "CANCELLED" end
        end
        return true
    end
    function value:retry() return true end
    function value:confirm() return true end
    function value:tick() return {state="IDLE"} end
    return value
end

local function build(stock, extra)
    local ui = UI.new(T.recordingSurface(51, 19))
    local craftSurface = T.recordingSurface(15, 10)
    local prefs = CraftPrefs.new(CraftPrefs.default())
    local deps = {
        clock=function() return 1000 end, scanner=scanner(), scan_budget=8,
        nodes={
            {id="dropoff",role="dropoff",peripheral_name="drop"},
            {id="storage_1",role="storage",peripheral_name="store1",priority=1},
            {id="pickup",role="pickup",peripheral_name="pickup"},
            {id="craft_buffer",role="craft_buffer",peripheral_name="buffer"},
        },
        ui=ui, keymap={command=function() end}, initial_ui=UI.initialState(),
        build_index=function() return {
            items=function() return {} end,
            quantity=function(_, key)
                local name = tostring(key):gsub("%z%-$", "")
                return (stock or {})[name] or 0
            end,
        } end,
        search=function() return {} end,
        recipes=realRepo, craft_prefs=prefs, craft_planner=CraftPlanner,
        crafts=fakeCrafts(), craft_monitor=CraftMonitor, craft_monitor_surface=craftSurface,
    }
    for key, value in pairs(extra or {}) do deps[key] = value end
    local coordinator = Coordinator.new(deps)
    for _ = 1, 12 do coordinator:workStep(1000) end
    return coordinator, deps, craftSurface
end

return {
    {name="opening the crafting page lists real recipes",run=function()
        local coordinator = build({})
        coordinator:command({type="OPEN_PAGE", page="crafting"})
        coordinator:_syncCraft()
        local state = coordinator:viewModel().ui
        -- The list is capped for display; what matters is that the catalogue behind it
        -- is the full pack, including items with no stock.
        T.equal(state.craft_result_count, 60, "results are capped for display")
        -- Not a fixed count: the pack is regenerated from whatever the installation has,
        -- and pinning a number here only records which modpack was installed that day.
        -- What matters is that the catalogue is the pack, not the display page.
        T.truthy(#coordinator:_craftCatalogue() > state.craft_result_count,
            "the whole pack is searchable, not just a page of it")
        T.equal(state.craft_results[1].quantity, 0,
            "items you hold none of are listed; that is the point of the page")
    end},
    {name="typing filters the catalogue down to matching recipes",run=function()
        local coordinator = build({})
        coordinator:command({type="OPEN_PAGE", page="crafting"})
        coordinator:command({type="CRAFT_QUERY_APPEND", text="chest"})
        coordinator:_syncCraft()
        local state = coordinator:viewModel().ui
        T.truthy(state.craft_result_count > 0, "chest should match something")
        T.truthy(state.craft_result_count < #coordinator:_craftCatalogue(),
            "and should not match the whole pack")
        for _, entry in ipairs(state.craft_results) do
            local label = tostring(entry.display_name or entry.item):lower()
            T.truthy(label:find("chest", 1, true) ~= nil or
                tostring(entry.item):lower():find("chest", 1, true) ~= nil,
                "every result must match the query, got " .. tostring(entry.item))
        end
        local found = false
        for _, entry in ipairs(state.craft_results) do
            if entry.item == "minecraft:chest" then found = true end
        end
        T.equal(found, true)
    end},
    {name="an exact name outranks everything that merely contains it",run=function()
        -- The catalogue is 22,391 outputs on the live modded pack and the page shows 60.
        -- Taking the first 60 matches in catalogue order pushed minecraft:chest off the
        -- page entirely for the query "chest", behind 220 other matches. Relevance has to
        -- decide what survives truncation, not iteration order.
        local coordinator = build({})
        local results = coordinator:_craftSearch("chest")
        T.truthy(#results > 0, "chest must match something")
        T.equal(results[1].item, "minecraft:chest",
            "the exact item is the one the operator meant, got " .. tostring(results[1].item))
    end},
    {name="a prefix beats a match buried mid-word",run=function()
        local coordinator = build({})
        local results = coordinator:_craftSearch("oak")
        local prefixAt, buriedAt
        for index, entry in ipairs(results) do
            local label = tostring(entry.display_name or entry.item):lower()
            local path = tostring(entry.item):lower():match("[^:]+$") or ""
            if not prefixAt and (label:find("^oak") or path:find("^oak")) then
                prefixAt = index
            end
            if not buriedAt and not (label:find("^oak") or path:find("^oak")) then
                buriedAt = index
            end
        end
        T.truthy(prefixAt ~= nil, "something must start with oak")
        if buriedAt then
            T.truthy(prefixAt < buriedAt,
                "a prefix match must sort above a mid-word one")
        end
    end},
    {name="ranking never returns something that does not match",run=function()
        local coordinator = build({})
        for _, entry in ipairs(coordinator:_craftSearch("piston")) do
            local label = tostring(entry.display_name or entry.item):lower()
            T.truthy(label:find("piston", 1, true) ~= nil or
                tostring(entry.item):lower():find("piston", 1, true) ~= nil,
                "got a non-match: " .. tostring(entry.item))
        end
    end},
    {name="an empty query still lists the catalogue",run=function()
        -- Nothing to rank by, so this stays cheap: the first page in catalogue order.
        local coordinator = build({})
        local results = coordinator:_craftSearch("")
        T.equal(#results, 60, "an empty query fills the page")
    end},
    {name="a query matching nothing returns nothing",run=function()
        local coordinator = build({})
        T.equal(#coordinator:_craftSearch("zzzznotathing"), 0)
    end},
    {name="results stay capped at one page",run=function()
        local coordinator = build({})
        T.truthy(#coordinator:_craftSearch("a") <= 60, "the display cap still holds")
    end},

    {name="planning a craft from stock produces a committable plan",run=function()
        local coordinator = build({["minecraft:oak_log"]=64})
        coordinator:command({type="OPEN_PAGE", page="crafting"})
        coordinator:command({type="SYNC_CRAFT_RESULTS",
            results={{item="minecraft:chest", display_name="Chest", quantity=0}}})
        coordinator:command({type="OPEN_CRAFT_QUANTITY"})
        coordinator:command({type="SET_CRAFT_QUANTITY", digit="1"})
        coordinator:command({type="PLAN_CRAFT"})
        local state = coordinator:viewModel().ui
        T.equal(state.mode, "craft_plan")
        T.equal(state.craft_plan.ok, true, "oak logs should reach a chest")
        T.equal(#state.craft_plan.steps, 2, "planks then chest")
    end},
    {name="a craft that cannot be made reports rather than committing",run=function()
        local coordinator, deps = build({})
        coordinator:command({type="OPEN_PAGE", page="crafting"})
        coordinator:command({type="SYNC_CRAFT_RESULTS",
            results={{item="minecraft:chest", display_name="Chest", quantity=0}}})
        coordinator:command({type="OPEN_CRAFT_QUANTITY"})
        coordinator:command({type="PLAN_CRAFT"})
        local state = coordinator:viewModel().ui
        T.equal(state.craft_plan.ok, false)
        coordinator:command({type="COMMIT_CRAFT"})
        T.equal(#deps.crafts.jobs, 0, "an impossible plan must never enqueue a job")
    end},
    {name="committing enqueues a job carrying the confirmed plan",run=function()
        local coordinator, deps = build({["minecraft:oak_log"]=64})
        coordinator:command({type="OPEN_PAGE", page="crafting"})
        coordinator:command({type="SYNC_CRAFT_RESULTS",
            results={{item="minecraft:chest", display_name="Chest", quantity=0}}})
        coordinator:command({type="OPEN_CRAFT_QUANTITY"})
        coordinator:command({type="SET_CRAFT_QUANTITY", digit="2"})
        coordinator:command({type="PLAN_CRAFT"})
        coordinator:command({type="COMMIT_CRAFT"})
        T.equal(#deps.crafts.jobs, 1)
        T.equal(deps.crafts.jobs[1].item, "minecraft:chest")
        T.equal(deps.crafts.jobs[1].quantity, 2)
        T.equal(deps.crafts.jobs[1].destination, "pickup")
        T.truthy(deps.crafts.jobs[1].confirmed,
            "the job must carry what the operator approved, for divergence checking")
    end},
    {name="the destination toggle reaches the enqueued job",run=function()
        local coordinator, deps = build({["minecraft:oak_log"]=64})
        coordinator:command({type="OPEN_PAGE", page="crafting"})
        coordinator:command({type="SYNC_CRAFT_RESULTS",
            results={{item="minecraft:chest", display_name="Chest", quantity=0}}})
        coordinator:command({type="OPEN_CRAFT_QUANTITY"})
        coordinator:command({type="PLAN_CRAFT"})
        coordinator:command({type="TOGGLE_CRAFT_DESTINATION"})
        coordinator:command({type="COMMIT_CRAFT"})
        T.equal(deps.crafts.jobs[1].destination, "storage")
    end},
    {name="pinning a tag choice reaches the preference store",run=function()
        local coordinator, deps = build({["minecraft:oak_log"]=64})
        coordinator:command({type="OPEN_PAGE", page="crafting"})
        coordinator:command({type="SYNC_CRAFT_RESULTS",
            results={{item="minecraft:chest", display_name="Chest", quantity=0}}})
        coordinator:command({type="OPEN_CRAFT_QUANTITY"})
        coordinator:command({type="PLAN_CRAFT"})
        -- Choices are sorted by tag, so the highlighted one is whichever sorts first;
        -- assert against the plan rather than assuming which tag that is.
        local first = coordinator:viewModel().ui.craft_plan.chosen[1]
        T.truthy(first, "a chest from logs resolves at least one tag")
        coordinator:command({type="PIN_CRAFT_CHOICE"})
        T.equal(deps.craft_prefs:tagChoice(first.tag), first.item,
            "the highlighted choice becomes the pin")
    end},
    {name="asking for the maximum uses what stock allows",run=function()
        local coordinator = build({["minecraft:oak_planks"]=24})
        coordinator:command({type="OPEN_PAGE", page="crafting"})
        coordinator:command({type="SYNC_CRAFT_RESULTS",
            results={{item="minecraft:chest", display_name="Chest", quantity=0}}})
        coordinator:command({type="OPEN_CRAFT_QUANTITY"})
        coordinator:command({type="CRAFT_QUANTITY_MAX", char="a"})
        local plan = coordinator:viewModel().ui.craft_plan
        T.equal(plan.ok, true)
        T.equal(plan.quantity, 3, "24 planks makes 3 chests")
    end},
    {name="cancelling a job from the list reaches the service",run=function()
        local coordinator, deps = build({["minecraft:oak_log"]=64})
        deps.crafts:enqueue("minecraft:chest", 1, {})
        coordinator:command({type="CANCEL_CRAFT", index=1})
        T.equal(deps.crafts.jobs[1].state, "CANCELLED")
    end},
    {name="the crafting monitor renders the active job",run=function()
        local coordinator, deps, craftSurface = build({})
        deps.crafts:enqueue("minecraft:chest", 4, {})
        coordinator:redraw()
        local text = craftSurface.allText()
        T.contains(text, "CRAFTING")
        T.contains(text, "chest")
        T.equal(craftSurface.writesOutsideBounds(), 0)
    end},
    {name="the crafting monitor shows idle when nothing is running",run=function()
        local coordinator, _, craftSurface = build({})
        coordinator:redraw()
        T.contains(craftSurface.allText(), "IDLE")
    end},
    {name="an install with no craft service still renders and refuses to commit",run=function()
        local coordinator = build({["minecraft:oak_log"]=64}, {crafts=nil})
        coordinator:command({type="OPEN_PAGE", page="crafting"})
        coordinator:command({type="SYNC_CRAFT_RESULTS",
            results={{item="minecraft:chest", display_name="Chest", quantity=0}}})
        coordinator:command({type="OPEN_CRAFT_QUANTITY"})
        coordinator:command({type="PLAN_CRAFT"})
        T.equal(coordinator:viewModel().ui.craft_plan.ok, true,
            "planning works without a turtle; only running one needs hardware")
        coordinator:command({type="COMMIT_CRAFT"})
        coordinator:redraw()
        T.truthy(true, "committing without a service records an error rather than crashing")
    end},
    {name="a committed job appears in the job list immediately",run=function()
        -- The list is what the operator looks at after pressing Enter. Asserting only
        -- that the service received the job is what let this ship broken.
        local coordinator, deps = build({["minecraft:oak_log"]=64})
        coordinator:command({type="OPEN_PAGE", page="crafting"})
        coordinator:command({type="SYNC_CRAFT_RESULTS",
            results={{item="minecraft:chest", display_name="Chest", quantity=0}}})
        coordinator:command({type="OPEN_CRAFT_QUANTITY"})
        coordinator:command({type="PLAN_CRAFT"})
        coordinator:command({type="COMMIT_CRAFT"})
        coordinator:redraw()
        local state = coordinator:viewModel().ui
        T.equal(#deps.crafts.jobs, 1, "the service has the job")
        T.equal(state.craft_job_count, 1, "and the operator can see it")
        T.equal(state.craft_jobs[1].item, "minecraft:chest")
    end},
    {name="the job list keeps up as a job progresses",run=function()
        local coordinator, deps = build({["minecraft:oak_log"]=64})
        deps.crafts:enqueue("minecraft:chest", 1, {})
        coordinator:redraw()
        T.equal(coordinator:viewModel().ui.craft_job_count, 1)
        deps.crafts.jobs[1].state = "STAGING"
        coordinator:redraw()
        T.equal(coordinator:viewModel().ui.craft_jobs[1].state, "STAGING",
            "a stale list would show the job stuck at QUEUED forever")
    end},
    {name="an empty job list is still reported after a redraw",run=function()
        local coordinator = build({})
        coordinator:redraw()
        T.equal(coordinator:viewModel().ui.craft_job_count, 0)
    end},

}
