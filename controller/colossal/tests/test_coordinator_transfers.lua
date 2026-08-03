local Coordinator=require("app.coordinator")
local T=require("tests.mock_cc")

return {
    {name="transfer verification waits for both targeted rescans and serializes workers",run=function()
        local importCalls,requestCalls=0,0
        local imports={}
        function imports:status() return {state=importCalls==1 and "VERIFYING" or "IDLE"} end
        function imports:tick()
            importCalls=importCalls+1
            if importCalls==1 then return {state="VERIFYING",rescan={"source","destination"}} end
            return {state="COMPLETE"}
        end
        local requests={list=function() return {} end,tick=function() requestCalls=requestCalls+1 end}
        local scanner={begin=function(_,node) return {node=node} end}
        function scanner:step(scan)
            return true,{node_id=scan.node.id,peripheral_name=scan.node.peripheral_name,
                epoch=importCalls*10+requestCalls+1,size=27,occupied=0,slots={},health="READY"}
        end
        local ui={reduce=function(_,state) return state end,render=function() end}
        local coordinator=Coordinator.new({clock=function() return 1 end,scanner=scanner,
            nodes={{id="source",role="dropoff",peripheral_name="source"},
                {id="destination",role="storage",peripheral_name="destination"}},
            ui=ui,keymap={command=function() end},initial_ui={query="",results={}},
            build_index=function() return {items=function() return {} end} end,
            search=function() return {} end,lifecycle={derive=function() return "READY","" end},
            imports=imports,requests=requests})
        coordinator:tick(1)
        T.equal(importCalls,1);T.equal(requestCalls,0)
        coordinator:tick(2)
        T.equal(importCalls,1);T.equal(requestCalls,0)
        coordinator:tick(3)
        T.equal(importCalls,2);T.equal(requestCalls,0)
        coordinator:tick(4)
        T.equal(requestCalls,1)
    end},
}
