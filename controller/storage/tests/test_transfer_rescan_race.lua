local Coordinator=require("app.coordinator")
local T=require("tests.mock_cc")

return {{name="post-transfer gate discards a source scan started before the move",run=function()
    local sourceBegins=0
    local scanner={}
    function scanner:begin(node)
        if node.id=="source" then sourceBegins=sourceBegins+1 end
        return {node=node,remaining=node.id=="source" and sourceBegins==1 and 2 or 1}
    end
    function scanner:step(scan)
        scan.remaining=scan.remaining-1
        if scan.remaining>0 then return false end
        return true,{node_id=scan.node.id,peripheral_name=scan.node.peripheral_name,
            epoch=sourceBegins,size=27,occupied=0,slots={},health="READY"}
    end
    local state="PLANNING";local requestTicks=0
    local requests={}
    function requests:list() return {{id="request",state=state}} end
    function requests:tick()
        requestTicks=requestTicks+1
        if requestTicks==1 then return {state="PLANNING",rescan={"source","destination"}} end
        if requestTicks==2 then state="TRANSFERRING";return {state=state} end
        if requestTicks==3 then state="VERIFYING";return {state=state,rescan={"source","destination"}} end
        state="COMPLETE";return {state=state}
    end
    local ui={reduce=function(_,value) return value end,render=function() end}
    local coordinator=Coordinator.new({clock=function() return requestTicks end,scanner=scanner,
        nodes={{id="source",role="storage",peripheral_name="source"},
            {id="destination",role="pickup",peripheral_name="destination"}},
        ui=ui,keymap={command=function() end},initial_ui={query="",results={}},
        build_index=function() return {items=function() return {} end} end,search=function() return {} end,
        lifecycle={derive=function() return "READY","" end},requests=requests})
    for tick=1,10 do coordinator:tick(tick);if requestTicks==4 then break end end
    T.equal(sourceBegins,3)
    T.equal(requestTicks,4)
end}}
