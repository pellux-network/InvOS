local Main = require("main")
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
        term={current=function() return surface end},clock=function() return 1000 end,
        textutils=options.textutils or {serialize=function() return "{}" end,unserialize=function() return {} end},
        surface=surface,
    }
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
}