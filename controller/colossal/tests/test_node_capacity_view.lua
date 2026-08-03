local Coordinator=require("app.coordinator")
local T=require("tests.mock_cc")

return {{name="node view reports live occupied and total slot counts",run=function()
    local scanner={begin=function(_,node) return {node=node} end}
    function scanner:step(scan)
        return true,{node_id=scan.node.id,peripheral_name=scan.node.peripheral_name,
            epoch=1,size=3075,occupied=213,slots={},health="READY"}
    end
    local ui={reduce=function(_,state) return state end,render=function() end}
    local coordinator=Coordinator.new({clock=function() return 1 end,scanner=scanner,
        nodes={{id="vault",label="Main Vault",role="storage",peripheral_name="vault"}},
        ui=ui,keymap={command=function() end},initial_ui={query="",results={}},
        build_index=function() return {items=function() return {} end} end,search=function() return {} end,
        lifecycle={derive=function() return "READY","" end}})
    coordinator:tick(1)
    local node=coordinator:viewModel().nodes[1]
    T.equal(node.occupied,213)
    T.equal(node.size,3075)
end}}