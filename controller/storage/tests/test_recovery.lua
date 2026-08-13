local Reconciliation=require("core.reconciliation")
local Transfer=require("core.transfer")
local T=require("tests.mock_cc")

local echo="the_vault:gem_echo\0-"
local function snapshot(count)
    return {node_id="a",health="READY",slots=count>0 and {[1]={identity_key=echo,count=count}} or {}}
end
local function journal(schema,phase)
    if schema==1 then
        return {schema=1,operation={id="old",kind="request",state="VERIFYING",moved=0},
            step={id="old:1",phase="FAILED",source_name="store_a",source_slot=7,
                source_epoch=1,source_pre_count=3,destination_name="pickup",
                destination_slot=2,destination_epoch=1,destination_pre_count=0,
                identity_key=echo,limit=2,actual_moved=1},updated_at=1}
    end
    return {schema=2,operation={id="new",kind="request",state="VERIFYING",moved=0},
        step={id="new:1",phase=phase,source_name="store_a",source_slot=7,
            source_epoch=1,source_pre_count=3,destination_name="pickup",identity_key=echo,
            limit=2,storage_pre_count=3,storage_node_ids={"a"},reported_moved=1,
            actual_moved=phase=="RECONCILED" and 3 or nil},updated_at=1}
end
local function transfer()
    local pushes=0
    local value=Transfer.new({store={write=function() return true end,delete=function() return true end},
        adapter={push=function() pushes=pushes+1 end},clock=function() return 2 end,
        reconciliation=Reconciliation})
    return value,function() return pushes end
end

return {
    {name="legacy slot journal is identified without replay",run=function()
        local value,pushes=transfer();local result=value:recover(journal(1,"FAILED"),{})
        T.equal(result.state,"LEGACY");T.equal(pushes(),0)
    end},
    {name="intent before call is safe to discard",run=function()
        local value,pushes=transfer();local result=value:recover(journal(2,"INTENT"),{})
        T.equal(result.state,"DISCARD_SAFE");T.equal(pushes(),0)
    end},
    {name="calling restart reconciles aggregate delta without replay",run=function()
        local value,pushes=transfer();local result=value:recover(journal(2,"CALLING"),{snapshot(0)})
        T.equal(result.state,"COMPLETE");T.equal(result.moved,3);T.equal(pushes(),0)
    end},
    {name="called restart reconciles aggregate delta without replay",run=function()
        local value,pushes=transfer();local result=value:recover(journal(2,"CALLED"),{snapshot(1)})
        T.equal(result.state,"COMPLETE");T.equal(result.moved,2);T.equal(pushes(),0)
    end},
    {name="reconciled restart returns recorded result without replay",run=function()
        local value,pushes=transfer();local result=value:recover(journal(2,"RECONCILED"),{})
        T.equal(result.state,"COMPLETE");T.equal(result.moved,3);T.equal(pushes(),0)
    end},
}