local Refresh = require("app.planning_refresh")
local T = require("tests.mock_cc")

local function snapshots()
    return {
        {node_id="a", peripheral_name="store_a"},
        {node_id="b", peripheral_name="store_b"},
        {node_id="c", peripheral_name="store_c"},
    }
end

return {
    {name="first viable plan requests a targeted refresh",run=function()
        local action,state=Refresh.advance(nil,{"b","a","b"},true)
        T.equal(action,"SCAN")
        T.equal(state.mode,"targeted")
        T.arrayEqual(state.storage_node_ids,{"a","b"})
        T.equal(state.retargets,0)
    end},
    {name="a plan contained by the refreshed union can commit",run=function()
        local state={mode="targeted",storage_node_ids={"a","b"},retargets=0}
        local action,nextState=Refresh.advance(state,{"a"},true)
        T.equal(action,"COMMIT")
        T.equal(nextState,state)
    end},
    {name="one target shift accumulates both scopes",run=function()
        local state={mode="targeted",storage_node_ids={"a"},retargets=0}
        local action,nextState=Refresh.advance(state,{"b"},true)
        T.equal(action,"SCAN")
        T.equal(nextState.mode,"targeted")
        T.equal(nextState.retargets,1)
        T.arrayEqual(nextState.storage_node_ids,{"a","b"})
        action=Refresh.advance(nextState,{"a"},true)
        T.equal(action,"COMMIT","a subset of the refreshed union is safe")
    end},
    {name="a second unrefreshed shift widens to the full pool",run=function()
        local state={mode="targeted",storage_node_ids={"a","b"},retargets=1}
        local action,nextState=Refresh.advance(state,{"c"},true)
        T.equal(action,"SCAN")
        T.equal(nextState.mode,"full")
        action=Refresh.advance(nextState,{"c"},true)
        T.equal(action,"COMMIT")
    end},
    {name="no plan receives one full-pool retry then terminates",run=function()
        local action,state=Refresh.advance(nil,{},false)
        T.equal(action,"SCAN")
        T.equal(state.mode,"full")
        action,state=Refresh.advance(state,{},false)
        T.equal(action,"FINAL_NO_PLAN")
    end},
    {name="targeted names include the endpoint and accumulated storage scope",run=function()
        local names=assert(Refresh.names(
            {mode="targeted",storage_node_ids={"b","a"},retargets=1},
            snapshots(),{node_id="pickup"}))
        T.arrayEqual(names,{"a","b","pickup"})
    end},
    {name="full names include every storage node and the endpoint",run=function()
        local names=assert(Refresh.names(
            {mode="full",storage_node_ids={},retargets=1},
            snapshots(),{node_id="drop"}))
        T.arrayEqual(names,{"a","b","c","drop"})
    end},
    {name="names rejects a targeted node absent from the storage snapshot set",run=function()
        local names,reason=Refresh.names(
            {mode="targeted",storage_node_ids={"missing"},retargets=0},
            snapshots(),{node_id="pickup"})
        T.equal(names,nil)
        T.equal(reason.code,"PLANNING_SCOPE_MISSING")
    end},
}
