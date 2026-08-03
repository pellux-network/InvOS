local Recovery=require("app.recovery")
local T=require("tests.mock_cc")

local function alerts()
    local values={}
    return {
        set=function(_,key,severity,message,details)
            values[#values+1]={key=key,severity=severity,message=message,details=details}
        end,
        values=values,
    }
end

return {
    {name="incomplete recovery waits for complete targeted scans without replay",run=function()
        local calls,retired=0,0
        local transfer={recover=function(_,journal,storage)
            calls=calls+1;T.equal(journal.id,"journal");T.equal(#storage,1)
            return {state="WAITING",rescan={"a","b"},reason={code="STORAGE_SCOPE_INCOMPLETE",message="waiting"}}
        end,retire=function() retired=retired+1;return true end}
        local service=Recovery.new({journal={id="journal"},transfer=transfer,alerts=alerts()})
        local result=service:tick({storage={{node_id="a"}}})
        T.equal(result.state,"VERIFYING");T.equal(result.rescan[2],"b")
        T.equal(service:status().state,"VERIFYING");T.equal(calls,1);T.equal(retired,0)
    end},
    {name="completed recovery records measured result and retires journal once",run=function()
        local retired=0;local notices=alerts()
        local transfer={recover=function() return {state="COMPLETE",moved=3,reported_moved=1} end,
            retire=function() retired=retired+1;return true end}
        local service=Recovery.new({journal={},transfer=transfer,alerts=notices})
        local result=service:tick({storage={}})
        T.equal(result.state,"COMPLETE");T.equal(result.moved,3);T.equal(retired,1)
        T.equal(notices.values[1].severity,"warning")
        service:tick({storage={}});T.equal(retired,1)
    end},
    {name="legacy journal is warned and retired without replay",run=function()
        local retired=0;local notices=alerts()
        local transfer={recover=function() return {state="LEGACY",reason={code="LEGACY_JOURNAL",message="legacy"}} end,
            retire=function() retired=retired+1;return true end}
        local service=Recovery.new({journal={},transfer=transfer,alerts=notices})
        T.equal(service:tick({storage={}}).state,"COMPLETE")
        T.equal(retired,1);T.equal(notices.values[1].severity,"warning")
    end},
    {name="unresolved recovery failure is retained and blocks mutation",run=function()
        local retired=0;local notices=alerts()
        local transfer={recover=function() return {state="FAILED",rescan={"a"},
            reason={code="UNRESOLVED",message="cannot prove movement",ambiguous=true}} end,
            retire=function() retired=retired+1;return true end}
        local service=Recovery.new({journal={},transfer=transfer,alerts=notices})
        local result=service:tick({storage={}})
        T.equal(result.state,"BLOCKED");T.equal(service:status().state,"BLOCKED")
        T.equal(retired,0);T.equal(notices.values[1].severity,"critical")
    end},
    {name="retirement failure alerts but does not freeze startup",run=function()
        local notices=alerts()
        local transfer={recover=function() return {state="DISCARD_SAFE",moved=0} end,
            retire=function() return nil,"disk unavailable" end}
        local service=Recovery.new({journal={},transfer=transfer,alerts=notices})
        local result=service:tick({storage={}})
        T.equal(result.state,"COMPLETE");T.equal(service:status().state,"COMPLETE")
        T.equal(notices.values[#notices.values].severity,"warning")
    end},
}
