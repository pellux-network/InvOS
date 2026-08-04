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
    {name="recordItemRequested bumps usage stats for an enriched identity and marks the coordinator dirty",run=function()
        local d=deps()
        local buildCalls=0
        d.build_index=function() buildCalls=buildCalls+1; return {items=function() return {} end} end
        d.metadata={["mod:item"]={display_name="Item",max_count=64}}
        local coordinator=Coordinator.new(d)
        buildCalls=0
        coordinator.dirty=false
        coordinator:recordItemRequested("mod:item",555)
        T.equal(coordinator.metadata["mod:item"].request_count,1)
        T.equal(coordinator.metadata["mod:item"].last_requested,555)
        T.equal(coordinator.metadata["mod:item"].display_name,"Item")
        T.equal(buildCalls,1,"the index must be rebuilt so search picks up the new stats")
        T.equal(coordinator.dirty,true)
    end},
    {name="recordItemRequested does nothing for an identity that has not been enriched yet",run=function()
        local d=deps()
        local buildCalls=0
        d.build_index=function() buildCalls=buildCalls+1; return {items=function() return {} end} end
        local coordinator=Coordinator.new(d)
        buildCalls=0
        coordinator:recordItemRequested("mod:unknown",555)
        T.equal(coordinator.metadata["mod:unknown"],nil)
        T.equal(buildCalls,0)
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
    {name="a node retrying after an error marks the coordinator dirty when it starts scanning again",run=function()
        local d=deps()
        local storageAttempts,renders=0,0
        d.scanner={}
        function d.scanner:begin(node)
            if node.id=="storage_1" then
                storageAttempts=storageAttempts+1
                if storageAttempts==1 then error("simulated failure") end
                return {node=node,remaining=2}
            end
            return {node=node,remaining=1}
        end
        function d.scanner:step(scan)
            scan.remaining=scan.remaining-1
            if scan.remaining>0 then return false end
            return true,{node_id=scan.node.id,peripheral_name=scan.node.peripheral_name,
                epoch=1,size=27,occupied=0,slots={},health="READY"}
        end
        d.ui={reduce=function(_,state) return state end,render=function() renders=renders+1 end}
        local coordinator=Coordinator.new(d)
        coordinator:tick(1000) -- dropoff scans and completes
        coordinator:tick(1000) -- storage_1's first attempt fails
        T.equal(coordinator:viewModel().nodes[2].state,"ERROR")
        renders=0
        coordinator:tick(1000) -- storage_1 retries; still mid-scan at the end of this tick
        T.equal(renders,1,"retrying a failed node's scan is user-visible and must repaint")
        T.equal(coordinator:viewModel().nodes[2].state,"SCANNING")
    end},
    {name="the default scan refresh interval is short, since nothing else notices a fresh Drop-off deposit",run=function()
        local coordinator=Coordinator.new(deps())
        T.equal(coordinator.scanRefreshInterval,2000,
            "a long default leaves deposits unnoticed for that whole interval, not just idle CPU cost")
    end},
    {name="requestRescan forces an immediate rescan even when the node is still fresh",run=function()
        local d=deps(); d.scan_refresh_interval=1000000
        local coordinator=Coordinator.new(d)
        for _=1,4 do coordinator:tick(1000) end
        T.arrayEqual(d.scans.begun,{"dropoff","storage_1","storage_2","pickup"})
        coordinator:requestRescan({"storage_1"})
        coordinator:tick(1001)
        T.arrayEqual(d.scans.begun,{"dropoff","storage_1","storage_2","pickup","storage_1"})
    end},
    {name="disabling a scanned storage node purges its snapshot and index source",run=function()
        local d=deps();local coordinator=Coordinator.new(d)
        coordinator:tick(1000);coordinator:tick(1001)
        T.truthy(coordinator:viewModel().snapshots.storage_1)
        coordinator:completeSetup({configured=true,
            dropoff={peripheral_name="drop"},pickup={peripheral_name="pickup"},
            storage={{id="storage_1",peripheral_name="store1",enabled=false}}})
        local model=coordinator:viewModel()
        T.equal(model.snapshots.storage_1,nil);T.equal(model.nodes[2].state,"DISABLED")
    end},
    {name="pause and resume gate automation without blocking scans",run=function()
        local d=deps(); local automation=0
        d.imports={tick=function() automation=automation+1 end,status=function() return {state="IDLE"} end}
        local coordinator=Coordinator.new(d)
        coordinator:pause(); coordinator:tick(1000); T.equal(automation,0)
        coordinator:resume(); coordinator:tick(1001); T.equal(automation,1)
        T.equal(d.scans.steps,2)
    end},
    {name="active request tracks the request actually being worked, not just the newest queued",run=function()
        local d=deps()
        d.requests={list=function()
            return {
                {id="request-1",display_name="Stone",state="TRANSFERRING",delivered=10,requested=64},
                {id="request-2",display_name="Dirt",state="QUEUED",delivered=0,requested=32},
            }
        end}
        local coordinator=Coordinator.new(d)
        local model=coordinator:viewModel()
        T.equal(model.active_request.id,"request-1",
            "the in-flight request should be current activity, not the newest queued one")
    end},
    {name="active request falls back to the most recent request once nothing is active",run=function()
        local d=deps()
        d.requests={list=function()
            return {
                {id="request-1",display_name="Stone",state="COMPLETE",delivered=64,requested=64},
                {id="request-2",display_name="Dirt",state="CANCELLED",delivered=0,requested=32},
            }
        end}
        local coordinator=Coordinator.new(d)
        local model=coordinator:viewModel()
        T.equal(model.active_request.id,"request-2",
            "with nothing active, last activity should still show the most recent request")
    end},
    {name="enrichment progress is exposed in the view model while metadata is still being learned",run=function()
        local d=deps()
        d.registry={}
        d.enrich_step=function(_,_,_,state)
            if state then return state end
            return {cursor=1,keys={"a","b","c"},metadata={},failures={},done=false}
        end
        local coordinator=Coordinator.new(d)
        coordinator:tick(1000)
        local model=coordinator:viewModel()
        T.truthy(model.enrichment,"in-progress enrichment must be visible in the model")
        T.equal(model.enrichment.learned,0)
        T.equal(model.enrichment.total,3)
    end},
    {name="enrichment progress is absent from the view model once learning finishes",run=function()
        local d=deps()
        d.registry={}
        d.enrich_step=function() return {cursor=4,keys={"a","b","c"},metadata={},failures={},done=true} end
        local coordinator=Coordinator.new(d)
        coordinator:tick(1000)
        local model=coordinator:viewModel()
        T.equal(model.enrichment,nil)
    end},
    {name="run has exactly one automation work loop",run=function()
        local coordinator=Coordinator.new(deps())
        local priorParallel=parallel
        local loopCount
        parallel={waitForAny=function(...)
            loopCount=select("#",...)
        end}
        local ok,reason=pcall(coordinator.run,coordinator)
        parallel=priorParallel
        if not ok then error(reason,0) end
        T.equal(loopCount,2)
    end},
}
