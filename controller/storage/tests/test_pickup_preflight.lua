local Reconciliation=require("core.reconciliation")
local Transfer=require("core.transfer")
local T=require("tests.mock_cc")

local stone="minecraft:stone\0-"
local function execute(kind,destination)
    local pushed,destinationInspections=0,0
    local adapter={inspect=function(_,name)
        if name=="source" then return true,{identity_key=stone,count=12,generation=1} end
        destinationInspections=destinationInspections+1
        return true,destination
    end,push=function() pushed=pushed+1;return true,4 end}
    local transfer=Transfer.new({store={write=function() return true end},adapter=adapter,
        clock=function() return 1 end,reconciliation=Reconciliation})
    local step={source_name="source",source_slot=1,source_epoch=1,source_pre_count=12,
        destination_name="pickup",identity_key=stone,limit=4}
    if kind=="import" then
        step.destination_slot=1;step.destination_epoch=1;step.destination_pre_count=5
    end
    local storageName=kind=="request" and "source" or "pickup"
    local result=transfer:execute({id="move",kind=kind,state="TRANSFERRING"},step,
        {{node_id="store",peripheral_name=storageName,health="READY",
            slots={[1]={identity_key=stone,count=12}}}})
    return result,pushed,destinationInspections
end

return {
    {name="retrieval never inspects mutable Pickup contents",run=function()
        local result,pushed,inspections=execute("request",{identity_key="minecraft:dirt\0-",count=64})
        T.equal(result.state,"VERIFYING");T.equal(pushed,1);T.equal(inspections,0)
    end},
    {name="import retains strict destination count preflight",run=function()
        local result,pushed,inspections=execute("import",{identity_key=nil,count=0,generation=2})
        T.equal(result.state,"FAILED");T.equal(result.reason.code,"DESTINATION_CHANGED")
        T.equal(pushed,0);T.equal(inspections,1)
    end},
}
