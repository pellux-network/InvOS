local Transfer=require("core.transfer")
local T=require("tests.mock_cc")

local stone="minecraft:stone\0-"
local function execute(kind,destination)
    local pushed=0
    local adapter={inspect=function(_,name)
        if name=="source" then return true,{identity_key=stone,count=12,generation=1} end
        return true,destination
    end,push=function() pushed=pushed+1;return true,4 end}
    local transfer=Transfer.new({store={write=function() return true end},adapter=adapter,clock=function() return 1 end})
    local result=transfer:execute({id="move",kind=kind,state="TRANSFERRING"},{
        source_name="source",source_slot=1,source_epoch=1,source_pre_count=12,
        destination_name="pickup",destination_slot=1,destination_epoch=1,
        destination_pre_count=5,identity_key=stone,limit=4})
    return result,pushed
end

return {
    {name="retrieval proceeds when player emptied same-item Pickup slot after planning",run=function()
        local result,pushed=execute("request",{identity_key=nil,count=0,generation=2})
        T.equal(result.state,"VERIFYING");T.equal(pushed,1)
    end},
    {name="import retains strict destination count preflight",run=function()
        local result,pushed=execute("import",{identity_key=nil,count=0,generation=2})
        T.equal(result.state,"FAILED");T.equal(result.reason.code,"DESTINATION_CHANGED");T.equal(pushed,0)
    end},
}