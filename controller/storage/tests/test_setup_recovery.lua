local Backup=require("app.backup")
local Setup=require("app.setup")
local Store=require("shared.store")
local T=require("tests.mock_cc")

local function codec()local v,n={},0;return{encode=function(x)n=n+1;local k="b"..n;v[k]=x;return k end,decode=function(k)return assert(v[k])end}end
local methods={"size","list","getItemDetail","getItemLimit","pushItems","pullItems"}
local function inventory(size)return{size=function()return size end,list=function()return{}end}end
local function environment()
    local fsApi=T.memoryFs();local store=Store.new(fsApi,codec(),"storage/data")
    local inventories={drop=inventory(27),pickup=inventory(27),big=inventory(3075)}
    local peripheral={getNames=function()return{"drop","pickup","big"}end,
        hasType=function(name,kind)return inventories[name]~=nil and kind=="inventory"end,
        getMethods=function()return methods end,wrap=function(name)return inventories[name]end}
    local setup=Setup.new({peripheral=peripheral,store=store,backup=Backup,
        os={getComputerID=function()return 8 end,getComputerLabel=function()return"ColossalStorage"end},
        clock=function()return 1 end})
    return setup,store
end

return {
    {name="backup recovery creates a review draft and does not auto-commit",run=function()
        local setup,store=environment()
        local backupConfig={schema=1,configured=true,installation={computer_id=99,computer_label="Old"},
            dropoff={peripheral_name="drop"},pickup={peripheral_name="pickup"},storage={
                {id="storage_1",peripheral_name="big",label="Recovered Vault",priority=1,enabled=true}}}
        local aliases={schema=1,items={rock="minecraft:stone"}}
        T.truthy(Backup.export(store,"disk",backupConfig,aliases))
        local review=setup:recoverBackup("disk")
        T.equal(review.requires_confirmation,true)
        T.equal(review.draft.storage[1].label,"Recovered Vault")
        T.equal(review.draft.installation,nil)
        T.equal(store:recover("config",Setup.validateConfig),nil)
        local report=setup:validate();T.equal(report.ok,true)
        T.truthy(setup:commit(report))
        local saved=store:recover("config",Setup.validateConfig)
        T.equal(saved.installation.computer_id,8)
        local savedAliases=store:recover("aliases",Setup.validateAliases)
        T.equal(savedAliases.items.rock,"minecraft:stone")
    end},
    {name="missing backup leaves the current draft untouched",run=function()
        local setup=environment();setup:assign("dropoff","drop")
        local before=setup:draft()
        local review,reason=setup:recoverBackup("empty-disk")
        T.equal(review,nil);T.contains(reason,"no valid colossal-backup")
        T.equal(setup:draft().dropoff.peripheral_name,before.dropoff.peripheral_name)
    end},
}
