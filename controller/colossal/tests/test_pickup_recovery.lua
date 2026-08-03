local Transfer=require("core.transfer")
local T=require("tests.mock_cc")

local function journal(kind)
    return {schema=1,operation={id="move",kind=kind,state="TRANSFERRING",moved=0},
        step={id="move:1",phase="CALLED",source_name="storage",source_slot=6,
            source_epoch=10,source_pre_count=6,destination_name=kind=="request" and "pickup" or "storage",
            destination_slot=1,destination_epoch=20,destination_pre_count=0,
            identity_key="the_vault:gem_xenium\0-",limit=6,actual_moved=6},updated_at=1}
end

local function transfer()
    return Transfer.new({store={write=function() return true end},adapter={},clock=function() return 2 end})
end

return {
    {name="reboot recovery accepts a completed retrieval after player empties Pickup",run=function()
        local result=transfer():recover(journal("request"),{
            source={identity_key=nil,count=0},destination={identity_key=nil,count=0}})
        T.equal(result.state,"COMPLETE")
        T.equal(result.moved,6)
    end},
    {name="recovery re-evaluates a retrieval journal failed only because Pickup was emptied",run=function()
        local value=journal("request");value.step.phase="FAILED"
        local result=transfer():recover(value,{
            source={identity_key=nil,count=0},destination={identity_key=nil,count=0}})
        T.equal(result.state,"COMPLETE")
    end},
    {name="reboot recovery keeps strict destination conservation for imports",run=function()
        local result=transfer():recover(journal("import"),{
            source={identity_key=nil,count=0},destination={identity_key=nil,count=0}})
        T.equal(result.state,"FAILED")
        T.equal(result.reason.code,"VERIFY_MISMATCH")
    end},
}