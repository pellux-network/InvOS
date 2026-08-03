local Backup=require("app.backup")
local Setup=require("app.setup")
local Store=require("shared.store")
local T=require("tests.mock_cc")

local methods={"size","list","getItemDetail","getItemLimit","pushItems","pullItems"}
local function codec()local v,n={},0;return{encode=function(x)n=n+1;local k="v"..n;v[k]=x;return k end,decode=function(k)return v[k]end}end
local function inv(size,listed)return{size=function()return size end,list=function()return listed or{}end}end
local function deps(inventories,overrides)
    local api={}
    function api.getNames()local r={};for n in pairs(inventories)do r[#r+1]=n end;return r end
    function api.hasType(name,kind)return kind=="inventory" and inventories[name]~=nil end
    function api.getMethods(name)return overrides and overrides[name] or methods end
    function api.wrap(name)return inventories[name]end
    return{peripheral=api,store=Store.new(T.memoryFs(),codec(),"colossal/data"),backup=Backup,
        os={getComputerID=function()return 8 end,getComputerLabel=function()return "ColossalStorage"end},
        clock=function()return 1 end}
end
local function issue(report,code)for _,value in ipairs(report.issues)do if value.code==code then return value end end end

return {
    {name="validation rejects Drop-off and Pickup role collision without transfers",run=function()
        local setup=Setup.new(deps({shared=inv(27),big=inv(3075)}))
        setup:assign("dropoff","shared");setup:assign("pickup","shared");setup:addStorage("big","Main",1)
        local report=setup:validate()
        T.equal(report.ok,false)
        T.truthy(issue(report,"ROLE_COLLISION"))
    end},
    {name="validation reports every missing required inventory method",run=function()
        local setup=Setup.new(deps({drop=inv(27),pickup=inv(27),big=inv(3075)},
            {drop={"size","list"},pickup=methods,big=methods}))
        setup:assign("dropoff","drop");setup:assign("pickup","pickup");setup:addStorage("big","Main",1)
        local report=setup:validate()
        T.equal(report.ok,false)
        local missing=issue(report,"MISSING_METHOD")
        T.truthy(missing)
        T.contains(missing.message,"getItemDetail")
        T.contains(missing.message,"pushItems")
    end},
    {name="identical storage interfaces are blocked as suspicious duplicates",run=function()
        local same={[1]={name="minecraft:stone",count=64}}
        local setup=Setup.new(deps({drop=inv(27),pickup=inv(27),a=inv(3075,same),b=inv(3075,same)}))
        setup:assign("dropoff","drop");setup:assign("pickup","pickup")
        setup:addStorage("a","Wall A",1);setup:addStorage("b","Wall B",2)
        local report=setup:validate()
        T.equal(report.ok,false)
        T.truthy(issue(report,"DUPLICATE_SUSPECTED"))
        local second=setup:draft().storage[2]
        setup:updateStorage(second.id,{enabled=false})
        T.equal(setup:validate().ok,true)
    end},
    {name="validation is read-only even when transfer methods exist",run=function()
        local transfers=0
        local fullMethods={}
        for _,name in ipairs(methods)do fullMethods[name]=true end
        local function tracked(size)return{size=function()return size end,list=function()return{}end,
            pushItems=function()transfers=transfers+1 end,pullItems=function()transfers=transfers+1 end}end
        local setup=Setup.new(deps({drop=tracked(27),pickup=tracked(27),big=tracked(3075)}))
        setup:assign("dropoff","drop");setup:assign("pickup","pickup");setup:addStorage("big","Main",1)
        T.equal(setup:validate().ok,true)
        T.equal(transfers,0)
    end},
    {name="stale validation report cannot commit a changed draft",run=function()
        local setup=Setup.new(deps({drop=inv(27),pickup=inv(27),big=inv(3075),other=inv(27)}))
        setup:assign("dropoff","drop");setup:assign("pickup","pickup");setup:addStorage("big","Main",1)
        local report=setup:validate();setup:assign("dropoff","other")
        local ok,reason=setup:commit(report)
        T.equal(ok,nil);T.contains(reason,"draft changed")
    end},
}
