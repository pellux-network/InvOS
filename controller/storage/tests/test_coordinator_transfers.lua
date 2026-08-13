local Coordinator=require("app.coordinator")
local T=require("tests.mock_cc")

local function base(nodes,scanner,imports,requests,recovery)
    local ui={reduce=function(_,state) return state end,render=function() end}
    return Coordinator.new({clock=function() return 1 end,scanner=scanner,nodes=nodes,
        ui=ui,keymap={command=function() end},initial_ui={query="",results={}},
        build_index=function() return {items=function() return {} end} end,
        search=function() return {} end,lifecycle={derive=function() return "READY","" end},
        imports=imports,requests=requests,recovery=recovery})
end

return {
    {name="verification waits for every targeted scan before resuming the worker",run=function()
        local importCalls,requestCalls=0,0;local imports={}
        function imports:status() return {state=importCalls==1 and "VERIFYING" or "IDLE"} end
        function imports:tick() importCalls=importCalls+1;if importCalls==1 then
            return {state="VERIFYING",rescan={"source","destination"}} end;return {state="COMPLETE"} end
        local requests={list=function() return {} end,tick=function() requestCalls=requestCalls+1 end}
        local scanner={begin=function(_,node) return {node=node} end}
        function scanner:step(scan) return true,{node_id=scan.node.id,
            peripheral_name=scan.node.peripheral_name,epoch=importCalls*10+requestCalls+1,
            size=27,occupied=0,slots={},health="READY"} end
        local coordinator=base({{id="source",role="dropoff",peripheral_name="source"},
            {id="destination",role="storage",peripheral_name="destination"}},scanner,imports,requests)
        coordinator:tick(1);T.equal(importCalls,1)
        coordinator:tick(2);T.equal(importCalls,1)
        coordinator:tick(3);T.equal(importCalls,2)
        coordinator:tick(4);T.equal(requestCalls,1)
    end},
    {name="automation context exposes every configured storage node and its live health",run=function()
        local captured
        local requests={list=function() return {{state="PLANNING"}} end,
            tick=function(_,context) captured=context.storage end}
        local scanner={begin=function(_,node) return {node=node} end,
            step=function(_,scan) return true,{node_id=scan.node.id,
                peripheral_name=scan.node.peripheral_name,epoch=1,size=27,occupied=0,
                slots={},health="READY"} end}
        local coordinator=base({{id="a",role="storage",peripheral_name="a"},
            {id="b",role="storage",peripheral_name="b"},
            {id="reserve",role="storage",peripheral_name="reserve",enabled=false}},scanner,
            {status=function() return {state="IDLE"} end},requests)
        for tick=1,6 do coordinator:tick(tick);if captured then break end end
        T.equal(#captured,2);T.equal(captured[1].health,"READY")
        T.equal(captured[2].node_id,"b");T.equal(captured[2].health,"READY")
    end},
    {name="planning waits for a fresh complete pool scan then executes before another scan",run=function()
        local state,requestCalls,scans="PLANNING",0,0;local scanAtPlan
        local requests={list=function() return {{state=state}} end}
        function requests:tick()
            requestCalls=requestCalls+1
            if state=="PLANNING" then state="TRANSFERRING";scanAtPlan=scans
            else state="VERIFYING";T.equal(scans,scanAtPlan) end
        end
        local scanner={begin=function(_,node) return {node=node} end}
        function scanner:step(scan)
            scans=scans+1;return true,{node_id=scan.node.id,
                peripheral_name=scan.node.peripheral_name,epoch=scans,size=27,
                occupied=0,slots={},health="READY"}
        end
        local coordinator=base({{id="a",role="storage",peripheral_name="a"},
            {id="b",role="storage",peripheral_name="b"},
            {id="pickup",role="pickup",peripheral_name="pickup"}},scanner,
            {status=function() return {state="IDLE"} end},requests)
        coordinator:tick(1);T.equal(requestCalls,0)
        for tick=2,8 do coordinator:tick(tick);if requestCalls==2 then break end end
        T.equal(requestCalls,2);T.equal(state,"VERIFYING")
    end},
    {name="request preflight ignores unrelated Drop-off while import ignores unrelated Pickup",run=function()
        local function run(serviceName)
            local calls,unrelated=0,0
            local service={status=function() return {state="PLANNING"} end,
                list=function() return {{state="PLANNING"}} end,
                tick=function() calls=calls+1 end}
            local scanner={begin=function(_,node)
                if serviceName=="requests" and node.role=="dropoff" or
                    serviceName=="imports" and node.role=="pickup" then unrelated=unrelated+1 end
                return {node=node}
            end,step=function(_,scan) return true,{node_id=scan.node.id,
                peripheral_name=scan.node.peripheral_name,epoch=1,size=27,occupied=0,
                slots={},health="READY"} end}
            local imports=serviceName=="imports" and service or {status=function() return {state="IDLE"} end}
            local requests=serviceName=="requests" and service or {list=function() return {} end}
            local coordinator=base({{id="store",role="storage",peripheral_name="store"},
                {id="drop",role="dropoff",peripheral_name="drop"},
                {id="pickup",role="pickup",peripheral_name="pickup"}},scanner,imports,requests)
            for tick=1,6 do coordinator:tick(tick);if calls>0 then break end end
            T.equal(calls,1);T.equal(unrelated,0)
        end
        run("requests");run("imports")
    end},
    {name="topology commit is refused while transfer or recovery reconciliation is unresolved",run=function()
        local scanner={begin=function(_,node) return {node=node} end,
            step=function(_,scan) return true,{node_id=scan.node.id,
                peripheral_name=scan.node.peripheral_name,epoch=1,size=27,occupied=0,
                slots={},health="READY"} end}
        local function assertBlocked(requests,recovery)
            local coordinator=base({{id="store",role="storage",peripheral_name="old"}},scanner,
                {status=function() return {state="IDLE"} end},requests,recovery)
            local ok,reason=coordinator:completeSetup({configured=true,
                dropoff={peripheral_name="drop"},pickup={peripheral_name="pickup"},
                storage={{id="store",peripheral_name="new"}}})
            T.equal(ok,nil);T.truthy(reason)
            T.equal(coordinator:viewModel().nodes[1].peripheral_name,"old")
        end
        assertBlocked({list=function() return {{state="VERIFYING"}} end})
        assertBlocked({list=function() return {{state="FAILED"},{state="VERIFYING"}} end})
        assertBlocked({list=function() return {} end},
            {status=function() return {state="VERIFYING"} end})
    end},
    {name="failed request cannot hide a later in-flight request from scan gating",run=function()
        local scans=0;local scanner={begin=function(_,node) return {node=node} end,
            step=function() scans=scans+1;return false end}
        local requests={list=function() return {{state="FAILED"},{state="TRANSFERRING"}} end,
            tick=function() end}
        local coordinator=base({{id="store",role="storage",peripheral_name="store"}},scanner,
            {status=function() return {state="IDLE"} end},requests)
        coordinator:tick(1);T.equal(scans,0)
    end},
    {name="retrieval reconciliation receives storage snapshots without slot observations",run=function()
        local requestCalls,sourceBegins,pickupBegins=0,0,0;local observedField="unset";local storageCount=0
        local requests={}
        function requests:list() return {{state=requestCalls==1 and "VERIFYING" or "PLANNING"}} end
        function requests:tick(context)
            requestCalls=requestCalls+1
            if requestCalls==1 then return {state="VERIFYING",rescan={"source"}} end
            observedField=context.observed;storageCount=#context.storage
            return {state="COMPLETE"}
        end
        local scanner={}
        function scanner:begin(node) if node.id=="source" then sourceBegins=sourceBegins+1 else pickupBegins=pickupBegins+1 end;return {node=node} end
        function scanner:step(scan) return true,{node_id=scan.node.id,peripheral_name=scan.node.peripheral_name,
            epoch=sourceBegins+pickupBegins,size=27,occupied=0,slots={},health="READY"} end
        local coordinator=base({{id="source",role="storage",peripheral_name="source"},
            {id="pickup",role="pickup",peripheral_name="pickup"}},scanner,
            {status=function() return {state="IDLE"} end},requests)
        for tick=1,10 do coordinator:tick(tick);if requestCalls==2 then break end end
        T.equal(requestCalls,2);T.equal(sourceBegins>=2,true);T.equal(pickupBegins>=1,true)
        T.equal(observedField,nil);T.equal(storageCount,1)
    end},
}