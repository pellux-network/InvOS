keys=keys or {escape=1,enter=28,backspace=14,up=200,down=208,left=203,right=205,
    one=2,two=3,three=4,four=5,five=6,s=31,a=30,f10=68}

local Alerts=require("app.alerts")
local Coordinator=require("app.coordinator")
local Imports=require("app.import_service")
local Keymap=require("app.keymap")
local Lifecycle=require("app.lifecycle")
local Monitor=require("app.monitor")
local Requests=require("app.requests")
local Search=require("app.search")
local UI=require("app.ui")
local Adapter=require("core.inventory_adapter")
local Index=require("core.index")
local Planner=require("core.planner")
local Reconciliation=require("core.reconciliation")
local Scanner=require("core.scanner")
local Transfer=require("core.transfer")
local Codec=require("shared.codec")
local Store=require("shared.store")
local T=require("tests.mock_cc")

local function clone(value)
    if type(value)~="table" then return value end
    local result={};for key,item in pairs(value) do result[key]=clone(item) end;return result
end

local function Harness(options)
    options=options or {}
    local now=0
    local inventories={drop={size=8,slots={}},pickup={size=8,slots={}},
        store_a={size=4,slots={}},store_b={size=4,slots={}}}
    local peripheralApi={}
    function peripheralApi.wrap(name)
        local inventory=inventories[name];if not inventory then return nil end
        return {
            size=function() return inventory.size end,
            list=function() return clone(inventory.slots) end,
            getItemLimit=function() return 64 end,
            getItemDetail=function(slot)
                local item=inventory.slots[slot];if not item then return nil end
                local detail=clone(item);detail.displayName=item.name:gsub("minecraft:",""):gsub("_"," ")
                detail.maxCount=64;return detail
            end,
            pushItems=function(destination,fromSlot,limit,toSlot)
                if options.pushItems then
                    return options.pushItems(name,inventories,destination,fromSlot,limit,toSlot)
                end
                local source=inventory.slots[fromSlot];local target=inventories[destination]
                if not source or not target then return 0 end
                local selected=toSlot
                if not selected then for slot=1,target.size do if not target.slots[slot] then selected=slot;break end end end
                if not selected then return 0 end
                local existing=target.slots[selected]
                if existing and (existing.name~=source.name or existing.nbt~=source.nbt) then return 0 end
                local capacity=64-(existing and existing.count or 0)
                local moved=math.min(limit or source.count,source.count,capacity)
                if moved<=0 then return 0 end
                if existing then existing.count=existing.count+moved
                else target.slots[selected]={name=source.name,nbt=source.nbt,count=moved} end
                source.count=source.count-moved;if source.count==0 then inventory.slots[fromSlot]=nil end
                return moved
            end,
            pullItems=function() return 0 end,
        }
    end
    local function clock() return now end
    local alerts=Alerts.new(clock)
    local tokens,tokenId={},0
    local codec={encode=function(value) tokenId=tokenId+1;tokens[tostring(tokenId)]=clone(value);return tostring(tokenId) end,
        decode=function(value) return clone(tokens[value]) end}
    local store=Store.new(T.memoryFs(),codec,"data")
    local coordinator
    local adapter=Adapter.new(peripheralApi,function(name)
        if not coordinator then return 0 end
        for _,snapshot in pairs(coordinator:viewModel().snapshots) do
            if snapshot.peripheral_name==name then return snapshot.epoch end
        end
        return 0
    end)
    local transfer=Transfer.new({store=store,adapter=adapter,clock=clock,
        reconciliation=Reconciliation})
    local imports=Imports.new({planner=Planner,transfer=transfer,alerts=alerts,
        transition=Lifecycle.transition,clock=clock})
    local requests=Requests.new({planner=Planner,transfer=transfer,alerts=alerts,
        transition=Lifecycle.transition,clock=clock,idGenerator=function(n) return "request-"..n end})
    local ui=UI.new(T.recordingSurface(51,19));local monitor=T.recordingSurface(50,16)
    coordinator=Coordinator.new({clock=clock,scanner=Scanner.new(peripheralApi,clock),
        nodes={{id="drop",role="dropoff",peripheral_name="drop"},
            {id="a",label="Vault A",role="storage",peripheral_name="store_a",priority=1},
            {id="b",label="Vault B",role="storage",peripheral_name="store_b",priority=2},
            {id="pickup",role="pickup",peripheral_name="pickup"}},
        ui=ui,keymap=Keymap,initial_ui=UI.initialState(),build_index=Index.build,
        search=Search.query,lifecycle=Lifecycle,imports=imports,requests=requests,alerts=alerts,
        monitor=Monitor,monitor_surface=monitor,enrich_step=Index.enrichStep,registry=adapter})
    local value={coordinator=coordinator,requests=requests,inventories=inventories,
        monitor=monitor,alerts=alerts}
    function value:tick() now=now+1;self.coordinator:tick(now) end
    function value:runUntil(predicate,limit)
        for _=1,limit do self:tick();if predicate(self.coordinator:viewModel()) then return end end
        local model=self.coordinator:viewModel()
        local import=imports:status();local request=requests:list()[1]
        error("acceptance timeout lifecycle="..tostring(model.lifecycle)..
            " import="..tostring(import.state)..":"..tostring(import.reason and import.reason.code)..":"..tostring(import.reason and import.reason.message)..
            " request="..tostring(request and request.state)..":"..
            tostring(request and request.reason and request.reason.code),2)
    end
    function value:count(name,key)
        local total=0;for _,item in pairs(inventories[name].slots) do
            local actual=item.name.."\0"..tostring(item.nbt or "-");if actual==key then total=total+item.count end
        end;return total
    end
    function value:storageCount(key) return self:count("store_a",key)+self:count("store_b",key) end
    return value
end

return {
    {name="deposit search and exact quantity retrieval conserve items end to end",run=function()
        local app=Harness();local key="minecraft:stone\0-"
        app.inventories.drop.slots[1]={name="minecraft:stone",count=64}
        app.inventories.drop.slots[2]={name="minecraft:stone",count=36}
        app:runUntil(function() return app:storageCount(key)==100 end,500)
        for character in ("stone"):gmatch(".") do app.coordinator:handle({"char",character}) end
        app.coordinator:handle({"key",keys.enter})
        app.coordinator:handle({"char","7"});app.coordinator:handle({"char","0"})
        app.coordinator:handle({"key",keys.enter})
        app:runUntil(function(model) return model.requests[1] and model.requests[1].state=="COMPLETE" end,500)
        T.equal(app:count("pickup",key),70)
        T.equal(app:storageCount(key),30)
        T.equal(app:count("drop",key)+app:count("pickup",key)+app:storageCount(key),100)
        T.contains(app.monitor.allText(),"COLOSSAL STORAGE")
    end},
    {name="misreported compacted retrieval completes once from pooled inventory truth",run=function()
        local calls=0;local echo="the_vault:gem_echo\0-"
        local app=Harness({pushItems=function(sourceName,inventories,destination,fromSlot)
            calls=calls+1;T.equal(sourceName,"store_a")
            local source=inventories[sourceName].slots[fromSlot]
            T.equal(source.name,"the_vault:gem_echo")
            inventories[destination].slots[1]={name=source.name,count=3}
            inventories[sourceName].slots[fromSlot]={name="the_vault:gem_wutodie",count=29}
            return 1
        end})
        app.inventories.store_a.slots[1]={name="the_vault:gem_echo",count=3}
        app:runUntil(function(model) return model.total_types==1 end,80)
        app.requests:create({key=echo,name="the_vault:gem_echo",display_name="Echo Gem"},2)
        app:runUntil(function(model)
            return model.requests[1] and model.requests[1].state=="COMPLETE"
        end,200)
        local request=app.requests:list()[1]
        T.equal(request.delivered,3);T.equal(calls,1)
        T.equal(app:count("pickup",echo),3);T.equal(app:storageCount(echo),0)
        local active=app.alerts:active();T.equal(active[1].severity,"critical")
        T.equal(active[1].details.code,"OVER_DELIVERY")
    end},
    {name="exact NBT variants remain separate across pooled nodes",run=function()
        local app=Harness();local left,right="minecraft:potion\0healing","minecraft:potion\0strength"
        app.inventories.store_a.slots[1]={name="minecraft:potion",nbt="healing",count=5}
        app.inventories.store_b.slots[1]={name="minecraft:potion",nbt="strength",count=7}
        app:runUntil(function(model) return model.total_types==2 end,80)
        app.requests:create({key=right,name="minecraft:potion",nbt="strength",display_name="strength potion"},4)
        app:runUntil(function(model) return model.requests[1] and model.requests[1].state=="COMPLETE" end,200)
        T.equal(app:count("pickup",right),4);T.equal(app:storageCount(right),3)
        T.equal(app:storageCount(left),5)
    end},
}
