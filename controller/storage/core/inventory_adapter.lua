local Identity = require("core.identity")

local Adapter = {}
Adapter.__index = Adapter

local function clean(value)
    return tostring(value or "unknown inventory error"):gsub("[%c]+", " "):sub(1, 240)
end

function Adapter.new(peripheralApi, generationProvider)
    assert(type(peripheralApi)=="table" and type(peripheralApi.wrap)=="function",
        "peripheral API is required")
    assert(type(generationProvider)=="function", "generation provider is required")
    return setmetatable({peripheral=peripheralApi,generation=generationProvider},Adapter)
end

function Adapter:_wrap(name)
    local ok, inventory=pcall(self.peripheral.wrap,name)
    if not ok then return nil,clean(inventory) end
    if type(inventory)~="table" then return nil,"inventory "..tostring(name).." is unavailable" end
    return inventory
end

function Adapter:inspect(name,slot)
    local inventory,reason=self:_wrap(name)
    if not inventory then return nil,reason end
    if type(inventory.getItemDetail)~="function" then
        return nil,"inventory "..tostring(name).." cannot inspect slots"
    end
    local ok,item=pcall(inventory.getItemDetail,slot)
    if not ok then return nil,clean(item) end
    local generation=self.generation(name)
    if item==nil then return true,{count=0,identity_key=nil,generation=generation} end
    if type(item)~="table" or type(item.name)~="string" or type(item.count)~="number" then
        return nil,"inventory "..tostring(name).." returned an invalid item detail"
    end
    return true,{name=item.name,nbt=item.nbt,count=item.count,
        identity_key=Identity.key(item.name,item.nbt),generation=generation,
        display_name=item.displayName,max_count=item.maxCount}
end

function Adapter:push(sourceName,destinationName,fromSlot,limit,toSlot)
    local source,reason=self:_wrap(sourceName)
    if not source then return nil,reason end
    if type(source.pushItems)~="function" then
        return nil,"inventory "..tostring(sourceName).." cannot push items"
    end
    local ok,moved
    if toSlot==nil then
        ok,moved=pcall(source.pushItems,destinationName,fromSlot,limit)
    else
        ok,moved=pcall(source.pushItems,destinationName,fromSlot,limit,toSlot)
    end
    if not ok then return nil,clean(moved) end
    if type(moved)~="number" then return nil,"pushItems returned "..type(moved) end
    return true,moved
end

function Adapter:getItemDetail(name,slot)
    local inventory,reason=self:_wrap(name)
    if not inventory then return nil,reason end
    local ok,detail=pcall(inventory.getItemDetail,slot)
    if not ok then return nil,clean(detail) end
    if type(detail)~="table" then return nil,"slot is empty" end
    return true,detail
end

return Adapter