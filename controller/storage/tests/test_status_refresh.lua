local Coordinator=require("app.coordinator")
local T=require("tests.mock_cc")

return {{name="healthy node remains READY during a background refresh scan",run=function()
    local begins=0
    local scanner={}
    function scanner:begin(node) begins=begins+1;return {node=node,remaining=begins==1 and 1 or 2} end
    function scanner:step(scan)
        scan.remaining=scan.remaining-1
        if scan.remaining>0 then return false end
        return true,{node_id=scan.node.id,peripheral_name=scan.node.peripheral_name,
            epoch=begins,size=27,occupied=0,slots={},health="READY"}
    end
    local ui={reduce=function(_,state) return state end,render=function() end}
    local coordinator=Coordinator.new({clock=function() return begins end,scanner=scanner,
        nodes={{id="storage",role="storage",peripheral_name="store"}},ui=ui,
        keymap={command=function() end},initial_ui={query="",results={}},
        build_index=function() return {items=function() return {} end} end,search=function() return {} end,
        lifecycle={derive=function(context)
            return context.ready_storage==1 and "READY" or "DEGRADED",""
        end}})
    coordinator:tick(1);T.equal(coordinator:viewModel().nodes[1].state,"READY")
    coordinator:tick(2)
    T.equal(coordinator:viewModel().nodes[1].state,"READY")
    T.equal(coordinator:viewModel().lifecycle,"READY")
end}}