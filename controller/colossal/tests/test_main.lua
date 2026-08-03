local Identity = require("core.identity")
local Index = require("core.index")
local Main = require("main")
local Setup = require("app.setup")
local Store = require("shared.store")
local Transfer = require("core.transfer")
local T = require("tests.mock_cc")

local function tokenTextutils()
    local values,nextId={},0
    local function serialize(value)
        nextId=nextId+1;local key="value"..nextId;values[key]=value;return key
    end
    local function unserialize(key) return values[key] end
    return {serialize=serialize,unserialize=unserialize},
        {encode=serialize,decode=unserialize}
end

local function environment(options)
    options=options or {}
    local surface=T.recordingSurface(51,19)
    return {
        fs=options.fs or T.memoryFs(),data_root="data",
        peripheral=options.peripheral or {
            getNames=function() return {} end,
            hasType=function() return false end,
            getMethods=function() return {} end,
            wrap=function() return nil end,
            find=function() return nil end,
        },
        os={getComputerID=function() return 17 end,getComputerLabel=function() return nil end,
            epoch=function() return 1000 end},
        term={current=function() return surface end},clock=options.clock or function() return 1000 end,
        textutils=options.textutils or {serialize=function() return "{}" end,unserialize=function() return {} end},
        surface=surface,
    }
end

local function chestInventory(size,slots)
    return {
        size=function() return size end,
        list=function() return slots end,
        getItemLimit=function() return 64 end,
        getItemDetail=function(slot)
            local item=slots[slot]; if not item then return nil end
            return {name=item.name,nbt=item.nbt,count=item.count,
                displayName=item.displayName,maxCount=item.maxCount or 64}
        end,
        pushItems=function() return 0 end,
        pullItems=function() return 0 end,
    }
end

local function peripheralFor(inventories)
    return {
        getNames=function() local names={};for name in pairs(inventories) do names[#names+1]=name end;return names end,
        hasType=function() return false end,
        getMethods=function() return {} end,
        wrap=function(name) return inventories[name] end,
        find=function() return nil end,
    }
end

local function configuredConfig()
    return {schema=1,configured=true,
        installation={computer_id=17,computer_label="Test"},
        dropoff={peripheral_name="drop"},pickup={peripheral_name="pickup"},
        storage={{id="a",label="Vault A",peripheral_name="store_a",priority=1,enabled=true}}}
end

return {
    {name="main assembles a safe first-boot setup controller",run=function()
        local env=environment(); local coordinator,services=Main.build(env)
        local model=coordinator:viewModel()
        T.equal(model.configured,false)
        T.equal(model.lifecycle,"SETUP_REQUIRED")
        T.equal(model.ui.mode,"setup")
        T.equal(model.ui.setup_step,1)
        T.truthy(services.setup)
        coordinator:handle({"char","x"})
        T.equal(coordinator:viewModel().lifecycle,"SETUP_REQUIRED")
    end},
    {name="startup retires legacy journal asynchronously without slot inspection or freeze",run=function()
        local fs=T.memoryFs()
        local textutils,codec=tokenTextutils()
        local journal={schema=1,operation={id="request-1",kind="request",state="TRANSFERRING",moved=0},
            step={id="request-1:1",phase="CALLED",source_name="storage",source_slot=2,
                source_epoch=1,source_pre_count=6,destination_name="pickup",
                identity_key="minecraft:stone\0-",limit=6,actual_moved=6},updated_at=1}
        local store=Store.new(fs,codec,"data")
        T.truthy(store:write("journal",journal,Transfer.validateJournal))
        local inspections=0
        local peripheral={getNames=function() return {} end,hasType=function() return false end,
            getMethods=function() return {} end,find=function() return nil end,
            wrap=function() inspections=inspections+1;error("Recovery must not inspect remembered slots") end}
        local coordinator,services=Main.build(environment({fs=fs,textutils=textutils,peripheral=peripheral}))
        T.equal(inspections,0);T.equal(coordinator:viewModel().recovering,false)
        T.equal(coordinator:viewModel().lifecycle,"SETUP_REQUIRED")
        T.truthy(services.recovery)
        coordinator:tick(1000)
        T.equal(fs.exists("data/journal.lua"),false)
        T.equal(services.alerts:active()[1].severity,"warning")
    end},
    {name="learned item metadata is cached to disk without ever persisting stock counts",run=function()
        local textutils,codec=tokenTextutils()
        local fs=T.memoryFs()
        local store=Store.new(fs,codec,"data")
        T.truthy(store:write("config",configuredConfig(),Setup.validateConfig))
        local detailCalls=0
        local inventories={drop=chestInventory(4,{}),pickup=chestInventory(4,{}),
            store_a=chestInventory(4,{[1]={name="minecraft:stone",count=64,
                displayName="Stone",maxCount=64}})}
        local rawDetail=inventories.store_a.getItemDetail
        inventories.store_a.getItemDetail=function(slot) detailCalls=detailCalls+1; return rawDetail(slot) end
        local coordinator=Main.build(environment({fs=fs,textutils=textutils,
            peripheral=peripheralFor(inventories)}))
        for tick=1,40 do coordinator:tick(tick) end
        T.truthy(fs.exists("data/metadata.lua"),"metadata cache should be written to disk")
        local decoded=store:read("metadata",Index.validateMetadata)
        T.truthy(decoded,"persisted metadata must validate")
        local key=Identity.key("minecraft:stone",nil)
        T.equal(decoded.items[key].display_name,"Stone")
        T.equal(decoded.items[key].max_count,64)
        T.equal(decoded.items[key].quantity,nil)
        T.equal(decoded.items[key].count,nil)
        T.equal(detailCalls,1,"one representative getItemDetail call should learn the whole stack")
    end},
    {name="cached metadata is loaded at boot and is not relearned",run=function()
        local textutils,codec=tokenTextutils()
        local fs=T.memoryFs()
        local store=Store.new(fs,codec,"data")
        T.truthy(store:write("config",configuredConfig(),Setup.validateConfig))
        local key=Identity.key("minecraft:stone",nil)
        T.truthy(store:write("metadata",{schema=1,items={
            [key]={display_name="Stone",max_count=64,aliases={}}}},Index.validateMetadata))
        local detailCalls=0
        local inventories={drop=chestInventory(4,{}),pickup=chestInventory(4,{}),
            store_a=chestInventory(4,{[1]={name="minecraft:stone",count=64}})}
        inventories.store_a.getItemDetail=function() detailCalls=detailCalls+1; return nil end
        local coordinator=Main.build(environment({fs=fs,textutils=textutils,
            peripheral=peripheralFor(inventories)}))
        for tick=1,10 do coordinator:tick(tick) end
        local results=coordinator:viewModel().ui.results
        T.truthy(results and results[1],"search results should be populated from the pooled index")
        T.equal(results[1].display_name,"Stone")
        T.equal(detailCalls,0,"an already-cached item must not be relearned")
    end},
    {name="a corrupt metadata cache does not block boot; the system just re-learns",run=function()
        local textutils,codec=tokenTextutils()
        local fs=T.memoryFs()
        local store=Store.new(fs,codec,"data")
        T.truthy(store:write("config",configuredConfig(),Setup.validateConfig))
        fs.files["data/metadata.lua"]="not-a-real-encoded-token"
        local inventories={drop=chestInventory(4,{}),pickup=chestInventory(4,{}),
            store_a=chestInventory(4,{[1]={name="minecraft:stone",count=64,
                displayName="Stone",maxCount=64}})}
        local ok,coordinator=pcall(Main.build,environment({fs=fs,textutils=textutils,
            peripheral=peripheralFor(inventories)}))
        T.truthy(ok,"Main.build must never fail because of an invalid metadata cache")
        for tick=1,20 do coordinator:tick(tick) end
        T.equal(coordinator:viewModel().lifecycle,"READY")
        local results=coordinator:viewModel().ui.results
        T.equal(results[1].display_name,"Stone")
    end},
    {name="metadata writes coalesce during a learning burst instead of hitting disk every tick",run=function()
        local textutils,codec=tokenTextutils()
        local fs=T.memoryFs()
        local store=Store.new(fs,codec,"data")
        T.truthy(store:write("config",configuredConfig(),Setup.validateConfig))
        local inventories={drop=chestInventory(4,{}),pickup=chestInventory(4,{}),
            store_a=chestInventory(4,{
                [1]={name="minecraft:stone",count=64,displayName="Stone",maxCount=64},
                [2]={name="minecraft:dirt",count=64,displayName="Dirt",maxCount=64},
                [3]={name="minecraft:sand",count=64,displayName="Sand",maxCount=64},
            })}
        local nowValue=0
        local coordinator,services=Main.build(environment({fs=fs,textutils=textutils,
            peripheral=peripheralFor(inventories),clock=function() return nowValue end}))
        local writes=0
        local originalWrite=services.store.write
        services.store.write=function(self,...) writes=writes+1; return originalWrite(self,...) end
        for tick=1,60 do nowValue=nowValue+10; coordinator:tick(tick) end
        T.truthy(writes>=1,"the learning burst must still persist eventually")
        T.truthy(writes<3,"writes must coalesce rather than firing once per learned item")
        local decoded=store:read("metadata",Index.validateMetadata)
        T.truthy(decoded)
        T.equal(decoded.items[Identity.key("minecraft:stone",nil)].display_name,"Stone")
        T.equal(decoded.items[Identity.key("minecraft:dirt",nil)].display_name,"Dirt")
        T.equal(decoded.items[Identity.key("minecraft:sand",nil)].display_name,"Sand")
    end},
}