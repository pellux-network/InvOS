local Adapter = require("core.inventory_adapter")
local T = require("tests.mock_cc")

return {
    {name="adapter inspects exact identity against the current scan generation",run=function()
        local inventories={source={getItemDetail=function(slot)
            T.equal(slot,4); return {name="minecraft:stone",count=12,nbt="abc",displayName="Stone",maxCount=64}
        end}}
        local adapter=Adapter.new({wrap=function(name) return inventories[name] end},
            function(name) return name=="source" and 42 or 0 end)
        local ok,item=adapter:inspect("source",4)
        T.equal(ok,true); T.equal(item.count,12); T.equal(item.generation,42)
        T.equal(item.identity_key,"minecraft:stone\0abc")
    end},
    {name="adapter represents an empty slot without inventing an identity",run=function()
        local adapter=Adapter.new({wrap=function() return {getItemDetail=function() return nil end} end},
            function() return 8 end)
        local ok,item=adapter:inspect("store",9)
        T.equal(ok,true); T.equal(item.count,0); T.equal(item.identity_key,nil); T.equal(item.generation,8)
    end},
    {name="adapter performs exact slotted wired pushItems calls",run=function()
        local called
        local adapter=Adapter.new({wrap=function(name)
            if name=="source" then return {pushItems=function(...)
                called={...}; return 7
            end} end
            return {}
        end},function() return 1 end)
        local ok,moved=adapter:push("source","pickup",3,7,11)
        T.equal(ok,true); T.equal(moved,7)
        T.arrayEqual(called,{"pickup",3,7,11})
    end},
    {name="adapter omits the destination slot for unslotted wired pushes",run=function()
        local called,count
        local adapter=Adapter.new({wrap=function(name)
            if name=="source" then return {pushItems=function(...)
                count=select("#",...);called={...};return 7
            end} end
            return {}
        end},function() return 1 end)
        local ok,moved=adapter:push("source","pickup",3,7,nil)
        T.equal(ok,true);T.equal(moved,7);T.equal(count,3)
        T.arrayEqual(called,{"pickup",3,7})
    end},
    {name="adapter returns structured failures for detached inventories",run=function()
        local adapter=Adapter.new({wrap=function() return nil end},function() return 1 end)
        local ok,reason=adapter:inspect("gone",1)
        T.equal(ok,nil); T.contains(reason,"gone")
    end},
}