local Backup = require("app.backup")
local Setup = require("app.setup")
local Store = require("shared.store")
local T = require("tests.mock_cc")

local requiredMethods={"size","list","getItemDetail","getItemLimit","pushItems","pullItems"}

local function tokenCodec()
    local values,nextId={},0
    return {encode=function(v) nextId=nextId+1;local k="s"..nextId;values[k]=v;return k end,
        decode=function(k)return assert(values[k],"bad token")end}
end

local function inventory(size,listed)
    return {size=function() return size end,list=function() return listed or {} end,
        getItemDetail=function()end,getItemLimit=function()return 64 end,
        pushItems=function() error("validation must not transfer") end,
        pullItems=function() error("validation must not transfer") end}
end

local function peripheral(inventories,methodOverrides)
    local calls={push=0,pull=0}
    local api={calls=calls}
    function api.getNames() local names={};for name in pairs(inventories)do names[#names+1]=name end;return names end
    function api.hasType(name,kind)return inventories[name]~=nil and kind=="inventory" end
    function api.getMethods(name)return methodOverrides and methodOverrides[name] or requiredMethods end
    function api.wrap(name)return inventories[name] end
    return api
end

local function dependencies(inventories,methodOverrides)
    local fsApi=T.memoryFs();local store=Store.new(fsApi,tokenCodec(),"storage/data")
    return {peripheral=peripheral(inventories,methodOverrides),store=store,backup=Backup,
        os={getComputerID=function()return 8 end,getComputerLabel=function()return "ColossalStorage" end},
        clock=function()return 100 end},store,fsApi
end

local function configure(setup)
    setup:assign("dropoff","drop")
    setup:assign("pickup","pickup")
    setup:addStorage("big","Main Vault",1)
end

return {
    {name="setup discovers inventories with stable readable descriptors",run=function()
        local deps=dependencies({big=inventory(3075),pickup=inventory(27),drop=inventory(27)})
        local discovered=Setup.new(deps):discover()
        T.equal(#discovered,3)
        T.equal(discovered[1].name,"big")
        T.equal(discovered[1].size,3075)
        T.equal(discovered[1].inventory,true)
    end},
    {name="setup keeps edits in a draft until validated commit",run=function()
        local deps,store=dependencies({big=inventory(3075),pickup=inventory(27),drop=inventory(27)})
        local setup=Setup.new(deps)
        configure(setup)
        T.equal(store:recover("config",Setup.validateConfig),nil)
        local report=setup:validate()
        T.equal(report.ok,true)
        T.truthy(setup:commit(report))
        local saved=store:recover("config",Setup.validateConfig)
        T.equal(saved.configured,true)
        T.equal(saved.installation.computer_id,8)
        T.equal(saved.installation.computer_label,"ColossalStorage")
        T.equal(saved.storage[1].label,"Main Vault")
        T.equal(saved.storage[1].priority,1)
    end},
    {name="cancelling setup restores the active configuration",run=function()
        local current={schema=1,configured=true,installation={computer_id=8,computer_label="ColossalStorage"},
            dropoff={peripheral_name="drop"},pickup={peripheral_name="pickup"},storage={
                {id="storage_1",peripheral_name="big",label="Original",priority=1,enabled=true}}}
        local deps=dependencies({big=inventory(3075),pickup=inventory(27),drop=inventory(27),other=inventory(27)})
        local setup=Setup.new(deps,current)
        setup:assign("dropoff","other")
        T.equal(setup:draft().dropoff.peripheral_name,"other")
        setup:cancel()
        T.equal(setup:draft().dropoff.peripheral_name,"drop")
        T.equal(setup:draft().storage[1].label,"Original")
    end},
    {name="setup can disable and relabel a storage node without deleting it",run=function()
        local deps=dependencies({big=inventory(3075),pickup=inventory(27),drop=inventory(27)})
        local setup=Setup.new(deps);configure(setup)
        local id=setup:draft().storage[1].id
        T.truthy(setup:updateStorage(id,{label="Deep Vault",enabled=false,priority=4}))
        local node=setup:draft().storage[1]
        T.equal(node.label,"Deep Vault")
        T.equal(node.enabled,false)
        T.equal(node.priority,4)
    end},
}
