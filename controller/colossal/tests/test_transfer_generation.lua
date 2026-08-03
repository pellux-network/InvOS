local Transfer=require("core.transfer")
local T=require("tests.mock_cc")

local function store()
    return {write=function() return true end}
end

return {{name="unchanged live slots tolerate harmless scan generation advances",run=function()
    local stone="minecraft:stone\0-";local pushed=0
    local adapter={}
    function adapter:inspect(name)
        if name=="source" then return true,{identity_key=stone,count=12,generation=11} end
        return true,{identity_key=nil,count=0,generation=21}
    end
    function adapter:push() pushed=pushed+1;return true,12 end
    local transfer=Transfer.new({store=store(),adapter=adapter,clock=function() return 1 end})
    local result=transfer:execute({id="move",kind="request",state="TRANSFERRING"},{
        source_name="source",source_slot=1,source_epoch=10,source_pre_count=12,
        destination_name="pickup",destination_slot=1,destination_epoch=20,destination_pre_count=0,
        identity_key=stone,limit=12})
    T.equal(result.state,"VERIFYING")
    T.equal(pushed,1)
end}}