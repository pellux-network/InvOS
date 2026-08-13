local Coordinator = require("app.coordinator")
local Main = require("main")
local T = require("tests.mock_cc")

local function slots(count)
    local result = {}
    for slot = 1, count do
        result[slot] = {name="minecraft:stone", count=64, identity_key="minecraft:stone\0-", max_count=64}
    end
    return result
end

local function base(options)
    options = options or {}
    local completed, budgets = 0, {}
    local scanner = {}
    function scanner:begin(node) return {node=node, left=options.steps or 1} end
    function scanner:step(scan, budget)
        budgets[#budgets + 1] = {role=scan.node.role, budget=budget}
        scan.left = scan.left - 1
        if scan.left > 0 then return false end
        completed = completed + 1
        return true, {node_id=scan.node.id, peripheral_name=scan.node.peripheral_name,
            epoch=100 + completed, size=64, occupied=2, slots=slots(2), health="READY"}
    end
    local ui = {}
    function ui:reduce(state) return state end
    function ui:render() end
    return {
        scanner=scanner, ui=ui,
        nodes=options.nodes or {{id="storage_1", role="storage", peripheral_name="colossal_0"}},
        clock=function() return 1 end,
        keymap={command=function() return nil end},
        initial_ui={query="", mode="search", page="search", results={}},
        build_index=function() return {items=function() return {} end} end,
        search=function() return {} end,
        lifecycle={derive=function() return "INDEXING", "" end},
        budgets=function() return budgets end,
        completed=function() return completed end,
    }
end

return {
    {name="lifecycle derivation never materializes storage snapshot copies", run=function()
        local seen
        local deps = base()
        deps.lifecycle = {derive=function(context) seen = context; return "INDEXING", "" end}
        local coordinator = Coordinator.new(deps)
        coordinator:tick(1)
        T.equal(deps.completed(), 1)
        T.truthy(seen, "lifecycle derive must receive a context")
        T.equal(seen.storage, nil, "lifecycle context must not copy storage snapshots")
        T.equal(seen.ready_storage, 1, "lifecycle still needs healthy storage counts")
        T.equal(seen.initial_index_complete, true)
    end},

    {name="automation still receives full storage snapshots", run=function()
        local received
        local deps = base()
        deps.imports = {status=function() return {state="IDLE"} end,
            tick=function(_, context) received = context; return {state="IDLE"} end}
        local coordinator = Coordinator.new(deps)
        coordinator:tick(1)
        T.truthy(received, "automation must receive a context")
        T.equal(#received.storage, 1, "automation needs every storage snapshot")
        T.equal(received.storage[1].slots[1].identity_key, "minecraft:stone\0-")
        T.equal(received.storage[1].health, "READY")
    end},

    {name="storage scans use the bulk budget and drop-off scans stay peripheral bounded", run=function()
        local deps = base({nodes={
            {id="dropoff", role="dropoff", peripheral_name="chest_0"},
            {id="storage_1", role="storage", peripheral_name="colossal_0"},
        }})
        deps.scan_budget, deps.dropoff_scan_budget = 512, 32
        local coordinator = Coordinator.new(deps)
        coordinator:tick(1)
        coordinator:tick(2)
        local budgets = deps.budgets()
        T.equal(#budgets, 2)
        T.equal(budgets[1].role, "dropoff")
        T.equal(budgets[1].budget, 32, "drop-off detail calls stay bounded")
        T.equal(budgets[2].role, "storage")
        T.equal(budgets[2].budget, 512, "storage slots are pure Lua work")
    end},

    {name="default storage scan budget outpaces the drop-off detail budget", run=function()
        local deps = base({nodes={
            {id="dropoff", role="dropoff", peripheral_name="chest_0"},
            {id="storage_1", role="storage", peripheral_name="colossal_0"},
        }})
        local coordinator = Coordinator.new(deps)
        coordinator:tick(1)
        coordinator:tick(2)
        local budgets = deps.budgets()
        T.equal(budgets[1].budget, 32, "default drop-off budget must not regress")
        T.truthy(budgets[2].budget >= 512, "default storage budget must be bulk sized")
    end},

    {name="metadata is only re-copied when enrichment actually progressed", run=function()
        local copies = 0
        local metadata = {}
        for index = 1, 40 do metadata["item" .. index] = {display_name="n", max_count=64} end
        local deps = base()
        deps.registry = {}
        deps.enrich_step = function(_, _, _, state)
            -- a settled enrichment returns the same state, tick after tick
            return state or {cursor=1, done=true, metadata=metadata}
        end
        local coordinator = Coordinator.new(deps)
        coordinator:tick(1)
        local seen = coordinator.metadata
        for value = 2, 12 do
            coordinator:tick(value)
            if coordinator.metadata ~= seen then copies = copies + 1; seen = coordinator.metadata end
        end
        T.equal(copies, 0,
            "a settled enrichment must not rebuild the metadata table every tick")
    end},

    {name="partial scan steps do not repaint the screen", run=function()
        -- A scan spread over several work steps changes nothing on screen until it finishes,
        -- so only its completion should repaint. The node is well inside the default refresh
        -- interval for the rest of the run, so on-demand scheduling scans it once and goes idle.
        local deps = base({steps=4})
        local renders = 0
        deps.ui = {reduce=function(_, state) return state end, render=function() renders = renders + 1 end}
        local coordinator = Coordinator.new(deps)
        for value = 1, 12 do coordinator:tick(value) end
        T.equal(deps.completed(), 1, "a fresh node must not be rescanned before it goes stale")
        T.equal(renders, 2,
            "only the first frame and the one completion should repaint over twelve ticks")
    end},

    {name="an idle coordinator does not rescan a fresh node, then scans once it goes stale", run=function()
        local deps = base({steps=1})
        deps.scan_refresh_interval = 100
        local coordinator = Coordinator.new(deps)
        coordinator:tick(1)
        T.equal(deps.completed(), 1, "the never-scanned node scans promptly")
        coordinator:tick(50)
        T.equal(deps.completed(), 1, "fresh inside the refresh interval must not rescan")
        coordinator:tick(102)
        T.equal(deps.completed(), 2, "stale past the refresh interval rescans exactly once")
    end},

    {name="epoch lookup resolves a peripheral without copying the view model", run=function()
        local deps = base()
        local coordinator = Coordinator.new(deps)
        coordinator:tick(1)
        T.equal(coordinator:epochFor("colossal_0"), 101)
        T.equal(coordinator:epochFor("not_bound"), 0)
        local calls = 0
        coordinator.viewModel = function() calls = calls + 1; return {} end
        T.equal(coordinator:epochFor("colossal_0"), 101)
        T.equal(calls, 0, "epoch lookup must not build a view model")
    end},

    {name="transfer epoch provider reads coordinator epochs directly", run=function()
        local inventory = {
            size=function() return 1 end,
            list=function() return {} end,
            getItemDetail=function() return {name="minecraft:stone", count=4, maxCount=64} end,
        }
        local surface = T.recordingSurface(51, 19)
        local coordinator, services = Main.build({
            fs=T.memoryFs(), data_root="data",
            peripheral={getNames=function() return {} end, hasType=function() return false end,
                getMethods=function() return {} end, wrap=function() return inventory end,
                find=function() return nil end},
            os={getComputerID=function() return 17 end, getComputerLabel=function() return nil end,
                epoch=function() return 1000 end},
            term={current=function() return surface end}, clock=function() return 1000 end,
            textutils={serialize=function() return "{}" end, unserialize=function() return {} end},
        })
        local calls = 0
        coordinator.viewModel = function() calls = calls + 1; return {} end
        local ok, observed = services.adapter:inspect("colossal_0", 1)
        T.equal(ok, true)
        T.equal(observed.count, 4)
        T.equal(calls, 0, "every transfer inspect must avoid a full view model copy")
    end},
}
