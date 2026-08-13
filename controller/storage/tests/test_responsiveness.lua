local Coordinator = require("app.coordinator")
local T = require("tests.mock_cc")

local function base()
    local completed, renderCount = 0, 0
    local scanner={}
    function scanner:begin(node) return {node=node,left=4} end
    function scanner:step(scan)
        scan.left=scan.left-1
        if scan.left>0 then return false end
        completed=completed+1
        return true,{node_id=scan.node.id,peripheral_name=scan.node.peripheral_name,
            epoch=completed,size=3075,occupied=0,slots={},health="READY"}
    end
    local ui={}
    function ui:reduce(state,command)
        local value={query=state.query,mode=state.mode,page=state.page,results={},hit_regions={}}
        if command.type=="QUERY_APPEND" then value.query=value.query..command.text end
        return value
    end
    function ui:render() renderCount=renderCount+1 end
    return {
        scanner=scanner,nodes={{id="storage",role="storage",peripheral_name="huge"}},
        scan_budget=32,clock=function() return 1 end,ui=ui,
        keymap={command=function(event) if event[1]=="char" then return {type="QUERY_APPEND",text=event[2]} end end},
        initial_ui={query="",mode="search",page="search",results={},hit_regions={}},
        build_index=function() return {items=function() return {} end} end,
        search=function() return {} end,
        lifecycle={derive=function(context) return context.configured and "INDEXING" or "SETUP_REQUIRED","" end},
        completed=function() return completed end,renders=function() return renderCount end,
    }
end

return {
    {name="typing remains responsive during a multi-step colossal scan",run=function()
        local d=base(); local coordinator=Coordinator.new(d)
        coordinator:tick(1); coordinator:handle({"char","g"}); coordinator:tick(2)
        coordinator:handle({"char","o"}); coordinator:tick(3)
        T.equal(coordinator:viewModel().ui.query,"go")
        T.equal(d.completed(),0)
        coordinator:tick(4); T.equal(d.completed(),1)
    end},
    {name="first setup completion starts normal work without reboot",run=function()
        local d=base(); d.configured=false
        local coordinator=Coordinator.new(d)
        coordinator:tick(1); T.equal(d.completed(),0)
        coordinator:completeSetup({configured=true,storage={{id="storage",peripheral_name="huge"}}})
        for value=2,5 do coordinator:tick(value) end
        T.equal(d.completed(),1)
        T.equal(coordinator:viewModel().configured,true)
    end},
    {name="peripheral changes schedule a targeted health refresh",run=function()
        local d=base(); local coordinator=Coordinator.new(d)
        coordinator:handle({"peripheral_detach","huge"})
        T.equal(coordinator:viewModel().nodes[1].state,"OFFLINE")
        coordinator:handle({"peripheral","huge"}); coordinator:tick(2)
        T.equal(coordinator:viewModel().nodes[1].state,"SCANNING")
    end},
    {name="monitor resize requests a redraw without scanning",run=function()
        local d=base(); local coordinator=Coordinator.new(d)
        coordinator:handle({"monitor_resize","monitor_0"})
        T.equal(d.renders(),1)
        T.equal(d.completed(),0)
    end},
    {name="heartbeat ticks continue without a matching timer event",run=function()
        local d=base(); local coordinator=Coordinator.new(d)
        for value=1,4 do coordinator:tick(value) end
        T.equal(d.completed(),1)
    end},
}
