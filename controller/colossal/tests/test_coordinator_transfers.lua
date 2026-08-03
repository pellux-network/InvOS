local Coordinator=require("app.coordinator")
local T=require("tests.mock_cc")

local function base(nodes,scanner,imports,requests)
    local ui={reduce=function(_,state) return state end,render=function() end}
    return Coordinator.new({clock=function() return 1 end,scanner=scanner,nodes=nodes,
        ui=ui,keymap={command=function() end},initial_ui={query="",results={}},
        build_index=function() return {items=function() return {} end} end,
        search=function() return {} end,lifecycle={derive=function() return "READY","" end},
        imports=imports,requests=requests})
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
            {id="b",role="storage",peripheral_name="b"}},scanner,
            {status=function() return {state="IDLE"} end},requests)
        coordinator:tick(1)
        T.equal(#captured,2);T.equal(captured[1].health,"READY")
        T.equal(captured[2].node_id,"b");T.equal(captured[2].health,"SCANNING")
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
        coordinator:tick(1);coordinator:tick(2)
        T.equal(requestCalls,2);T.equal(sourceBegins,2);T.equal(pickupBegins,0)
        T.equal(observedField,nil);T.equal(storageCount,1)
    end},
}