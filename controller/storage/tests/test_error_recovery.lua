local Coordinator = require("app.coordinator")
local Alerts = require("app.alerts")
local T = require("tests.mock_cc")

local function dependencies()
    local scanCalls, imports, requests, metadata = 0,0,0,0
    local scanner={begin=function(_,node) return {node=node} end}
    function scanner:step(scan)
        scanCalls=scanCalls+1
        if scanCalls==1 then error("detached during scan") end
        return true,{node_id=scan.node.id,peripheral_name=scan.node.peripheral_name,
            epoch=scanCalls,size=27,occupied=0,slots={},health="READY"}
    end
    local ui={}
    function ui:reduce(state,command)
        return {query=command.type=="QUERY_APPEND" and state.query..command.text or state.query,
            mode="search",page="search",results={},hit_regions={}}
    end
    function ui:render() end
    return {
        scanner=scanner,nodes={{id="storage",role="storage",peripheral_name="store"}},
        clock=function() return 1 end,ui=ui,initial_ui={query="",mode="search",page="search",results={},hit_regions={}},
        keymap={command=function(event) if event[1]=="char" then return {type="QUERY_APPEND",text=event[2]} end end},
        build_index=function() return {items=function() return {{key="x",name="x",quantity=1}} end} end,
        search=function() return {} end,lifecycle={derive=function(c) return c.recovering and "RECOVERING" or "READY","" end},
        imports={tick=function() imports=imports+1 end,status=function() return {state="IDLE"} end},
        requests={tick=function() requests=requests+1 end,list=function() return {} end},
        enrich_step=function(_,_,budget,state) metadata=metadata+budget; return state or {done=true,metadata={}} end,
        metadata_budget=1,registry={},
        counts=function() return scanCalls,imports,requests,metadata end,
    }
end

return {
    {name="failed scanner boundary leaves terminal input alive",run=function()
        local d=dependencies(); local coordinator=Coordinator.new(d)
        coordinator:tick(1)
        T.equal(coordinator:viewModel().nodes[1].state,"ERROR")
        coordinator:handle({"char","r"})
        T.equal(coordinator:viewModel().ui.query,"r")
        coordinator:tick(2)
        T.equal(coordinator:viewModel().nodes[1].state,"READY")
    end},
    {name="journal reconciliation runs first without freezing controller lifecycle",run=function()
        local d=dependencies();local recoveryTicks=0
        d.recovery={status=function()
            return {state=recoveryTicks==0 and "VERIFYING" or "COMPLETE"}
        end,tick=function()
            recoveryTicks=recoveryTicks+1;return {state="COMPLETE"}
        end}
        local coordinator=Coordinator.new(d);coordinator:tick(1)
        local _,imports,requests=d.counts()
        T.equal(recoveryTicks,1);T.equal(imports,0);T.equal(requests,0)
        T.equal(coordinator:viewModel().recovering,false)
        T.equal(coordinator:viewModel().lifecycle,"READY")
        coordinator:tick(2);coordinator:tick(3)
        _,imports,requests=d.counts();T.equal(imports,1);T.equal(requests,1)
    end},
    {name="metadata enrichment respects its per-step budget",run=function()
        local d=dependencies(); local coordinator=Coordinator.new(d)
        coordinator:tick(1); coordinator:tick(2)
        local _,_,_,metadata=d.counts()
        T.equal(metadata,1)
    end},
    {name="targeted transfer rescans are accepted while degraded",run=function()
        local d=dependencies(); local coordinator=Coordinator.new(d)
        coordinator:notifyTransfer({rescan={"store"}})
        coordinator:tick(1); coordinator:tick(2)
        local scans=d.counts(); T.equal(scans,2)
    end},
    {name="a redraw crash from the tick loop is caught and recorded instead of killing workStep",run=function()
        local d=dependencies()
        d.alerts={active=function() error("boom") end}
        local coordinator=Coordinator.new(d)
        coordinator:workStep(1)
        T.truthy(#coordinator.notices>0, "the crash must be recorded")
        T.contains(coordinator.notices[#coordinator.notices].message,"boom")
        coordinator:workStep(2)
        T.truthy(#coordinator.notices>0, "workStep must still be callable afterward")
    end},
    {name="a redraw crash reached through handle is caught and recorded",run=function()
        local d=dependencies()
        d.alerts={active=function() error("boom") end}
        local coordinator=Coordinator.new(d)
        coordinator:handle({"term_resize"})
        T.truthy(#coordinator.notices>0, "the crash must be recorded")
        T.contains(coordinator.notices[#coordinator.notices].message,"boom")
    end},
    {name="a scanner failure clears once the same node scans successfully",run=function()
        local d=dependencies()
        d.alerts=Alerts.new(function() return 100 end)
        local coordinator=Coordinator.new(d)
        coordinator:tick(1)
        T.equal(#coordinator:viewModel().alerts,1)
        T.equal(coordinator:viewModel().alerts[1].key,"component_error:scanner")
        coordinator:tick(2)
        T.equal(#coordinator:viewModel().alerts,0)
    end},
    {name="an index rebuild failure clears once rebuilding succeeds",run=function()
        local d=dependencies()
        d.alerts=Alerts.new(function() return 100 end)
        local calls=0
        d.build_index=function()
            calls=calls+1
            if calls==1 then error("index corrupt") end
            return {items=function() return {} end}
        end
        local coordinator=Coordinator.new(d)
        coordinator:_rebuildIndex()
        T.equal(coordinator:viewModel().alerts[1].key,"component_error:index")
        coordinator:_rebuildIndex()
        T.equal(#coordinator:viewModel().alerts,0)
    end},
    {name="a search failure clears once search succeeds",run=function()
        local d=dependencies()
        d.alerts=Alerts.new(function() return 100 end)
        local calls=0
        d.search=function()
            calls=calls+1
            if calls==1 then error("search index locked") end
            return {}
        end
        local coordinator=Coordinator.new(d)
        coordinator:_rebuildIndex()
        T.equal(coordinator:viewModel().alerts[1].key,"component_error:search")
        coordinator:_rebuildIndex()
        T.equal(#coordinator:viewModel().alerts,0)
    end},
    {name="a metadata enrichment failure clears once enrichment succeeds",run=function()
        local d=dependencies()
        d.alerts=Alerts.new(function() return 100 end)
        local calls=0
        d.enrich_step=function(_,_,_,state)
            calls=calls+1
            if calls==1 then error("registry unavailable") end
            return state or {done=true,metadata={}}
        end
        local coordinator=Coordinator.new(d)
        coordinator:_rebuildIndex()
        coordinator:_enrichStep()
        T.equal(coordinator:viewModel().alerts[1].key,"component_error:metadata")
        coordinator:_enrichStep()
        T.equal(#coordinator:viewModel().alerts,0)
    end},
    {name="an automation service failure clears once its next tick succeeds",run=function()
        local d=dependencies()
        d.alerts=Alerts.new(function() return 100 end)
        d.requests=nil
        local calls=0
        d.imports={status=function() return {state="IDLE"} end,
            tick=function()
                calls=calls+1
                if calls==1 then error("push failed") end
                return {state="IDLE"}
            end}
        local coordinator=Coordinator.new(d)
        coordinator:_automationStep(1000)
        T.equal(coordinator:viewModel().alerts[1].key,"component_error:imports")
        coordinator:_automationStep(1001)
        T.equal(#coordinator:viewModel().alerts,0)
    end},
}
