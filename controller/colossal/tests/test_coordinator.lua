local Coordinator = require("app.coordinator")
local T = require("tests.mock_cc")

local function deps()
    local scans = {begun={}, steps=0}
    local scanner = {}
    function scanner:begin(node)
        scans.begun[#scans.begun + 1] = node.id
        return {node=node, remaining=1}
    end
    function scanner:step(scan)
        scans.steps = scans.steps + 1
        scan.remaining = scan.remaining - 1
        if scan.remaining > 0 then return false end
        return true, {node_id=scan.node.id, peripheral_name=scan.node.peripheral_name,
            epoch=scans.steps, size=27, occupied=0, slots={}, health="READY",
            priority=scan.node.priority}
    end
    local ui = {}
    function ui:reduce(state, command)
        local nextState = {query=state.query, mode=state.mode, page=state.page,
            results=state.results, hit_regions={}}
        if command.type == "QUERY_APPEND" then nextState.query=nextState.query..command.text end
        return nextState
    end
    function ui:render() end
    local keymap = {command=function(event)
        if event[1]=="char" then return {type="QUERY_APPEND",text=event[2]} end
    end}
    return {
        clock=function() return 1000 end,
        scanner=scanner, scan_budget=8,
        nodes={
            {id="dropoff",role="dropoff",peripheral_name="drop"},
            {id="storage_1",role="storage",peripheral_name="store1",priority=1},
            {id="storage_2",role="storage",peripheral_name="store2",priority=2},
            {id="pickup",role="pickup",peripheral_name="pickup"},
        },
        ui=ui, keymap=keymap,
        initial_ui={query="",mode="search",page="search",results={},hit_regions={}},
        build_index=function() return {items=function() return {} end} end,
        search=function() return {} end,
        lifecycle={derive=function() return "INDEXING","building index" end},
        scans=scans,
    }
end

return {
    {name="input is handled without advancing scanner work",run=function()
        local d=deps(); local coordinator=Coordinator.new(d)
        coordinator:handle({"char","s"})
        T.equal(coordinator:viewModel().ui.query,"s")
        T.equal(d.scans.steps,0)
        coordinator:tick(1000)
        T.equal(d.scans.steps,1)
        T.equal(coordinator:viewModel().ui.query,"s")
    end},
    {name="view models are immutable copies",run=function()
        local coordinator=Coordinator.new(deps())
        local first=coordinator:viewModel(); first.ui.query="corrupt"; first.nodes[1].state="BROKEN"
        local second=coordinator:viewModel()
        T.equal(second.ui.query,"")
        T.notEqual(second.nodes[1].state,"BROKEN")
    end},
    {name="scheduled scans rotate fairly across every node",run=function()
        local d=deps(); local coordinator=Coordinator.new(d)
        for _=1,4 do coordinator:tick(1000) end
        T.arrayEqual(d.scans.begun,{"dropoff","storage_1","storage_2","pickup"})
    end},
    {name="targeted rescans are promoted ahead of background rotation",run=function()
        local d=deps(); local coordinator=Coordinator.new(d)
        coordinator:tick(1000)
        coordinator:requestRescan({"pickup","storage_2"})
        coordinator:tick(1001); coordinator:tick(1002)
        T.arrayEqual(d.scans.begun,{"dropoff","pickup","storage_2"})
    end},
    {name="pause and resume gate automation without blocking scans",run=function()
        local d=deps(); local automation=0
        d.imports={tick=function() automation=automation+1 end,status=function() return {state="IDLE"} end}
        local coordinator=Coordinator.new(d)
        coordinator:pause(); coordinator:tick(1000); T.equal(automation,0)
        coordinator:resume(); coordinator:tick(1001); T.equal(automation,1)
        T.equal(d.scans.steps,2)
    end},
}
