local Backup=require("app.backup")
local Setup=require("app.setup")
local Store=require("shared.store")
local T=require("tests.mock_cc")

return {
    {name="operator can explicitly confirm two suspicious nodes are physically distinct",run=function()
        local methods={"size","list","getItemDetail","getItemLimit","pushItems","pullItems"}
        local function inventory(size)return{size=function()return size end,list=function()return{}end}end
        local inventories={drop=inventory(27),pickup=inventory(27),a=inventory(3075),b=inventory(3075)}
        local peripheral={getNames=function()return{"drop","pickup","a","b"}end,
            hasType=function(name,kind)return kind=="inventory"and inventories[name]~=nil end,
            getMethods=function()return methods end,wrap=function(name)return inventories[name]end}
        local values,n={},0;local codec={encode=function(v)n=n+1;local k="d"..n;values[k]=v;return k end,
            decode=function(k)return values[k]end}
        local setup=Setup.new({peripheral=peripheral,
            store=Store.new(T.memoryFs(),codec,"storage/data"),backup=Backup,
            os={getComputerID=function()return 8 end,getComputerLabel=function()return"StorageController"end},
            clock=function()return 1 end})
        setup:assign("dropoff","drop");setup:assign("pickup","pickup")
        local first=setup:addStorage("a","Vault A",1);local second=setup:addStorage("b","Vault B",2)
        T.equal(setup:validate().ok,false)
        T.truthy(setup:confirmDistinct(first.id,second.id))
        local report=setup:validate()
        T.equal(report.ok,true)
        local found=false
        for _,issue in ipairs(report.issues)do
            if issue.code=="DUPLICATE_CONFIRMED" then found=true;T.equal(issue.blocking,false)end
        end
        T.equal(found,true)
    end},
}
