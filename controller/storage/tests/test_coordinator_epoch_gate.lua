local Coordinator=require("app.coordinator")
local T=require("tests.mock_cc")

return {{name="planned transfer executes before background scans can invalidate its epochs",run=function()
    local scans,transfers=0,0
    local imports={status=function() return {state="TRANSFERRING"} end,
        tick=function() transfers=transfers+1;return {state="VERIFYING",rescan={"store"}} end}
    local scanner={begin=function(_,node) return {node=node} end,
        step=function(scan) scans=scans+1;return true,{node_id=scan.node.id,
            peripheral_name=scan.node.peripheral_name,epoch=scans,size=27,slots={},occupied=0,health="READY"} end}
    local ui={reduce=function(_,state) return state end,render=function() end}
    local coordinator=Coordinator.new({clock=function() return 1 end,scanner=scanner,
        nodes={{id="store",role="storage",peripheral_name="store"}},ui=ui,
        keymap={command=function() end},initial_ui={query="",results={}},
        build_index=function() return {items=function() return {} end} end,search=function() return {} end,
        lifecycle={derive=function() return "READY","" end},imports=imports})
    coordinator:tick(1)
    T.equal(transfers,1);T.equal(scans,0)
end}}
