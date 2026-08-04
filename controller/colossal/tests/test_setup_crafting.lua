local Backup = require("app.backup")
local Setup = require("app.setup")
local Store = require("shared.store")
local T = require("tests.mock_cc")

local methods = {"size","list","getItemDetail","getItemLimit","pushItems","pullItems"}

local function codec()
    local values, count = {}, 0
    return {
        encode = function(value) count = count + 1; local key = "v"..count; values[key] = value; return key end,
        decode = function(key) return values[key] end,
    }
end

-- A peripheral API carrying more than inventories, which is the whole point: the turtle
-- and the monitors are not inventories and discover() will never surface them.
local function peripherals()
    local kinds = {
        ["ironchests:netherite_chest_1"] = {inventory=true},
        ["ironchests:diamond_chest_1"]   = {inventory=true},
        ["ironchests:diamond_chest_2"]   = {inventory=true},
        ["colossalchests:colossal_chest_0"] = {inventory=true},
        ["turtle_2"] = {turtle=true},
        ["monitor_0"] = {monitor=true},
        ["top"] = {monitor=true},
        ["speaker_0"] = {speaker=true},
    }
    local api = {}
    function api.getNames()
        local names = {}
        for name in pairs(kinds) do names[#names+1] = name end
        table.sort(names)
        return names
    end
    function api.hasType(name, kind) return (kinds[name] or {})[kind] == true end
    function api.getMethods() return methods end
    function api.wrap(name)
        if not (kinds[name] or {}).inventory then return nil end
        return {size=function() return 27 end, list=function() return {} end}
    end
    return api
end

local function setup()
    return Setup.new({
        peripheral=peripherals(),
        store=Store.new(T.memoryFs(), codec(), "colossal/data"),
        backup=Backup,
        os={getComputerID=function() return 4 end,
            getComputerLabel=function() return "StorageController" end},
        clock=function() return 1 end,
    })
end

local function configured(service)
    service:assign("dropoff", "ironchests:netherite_chest_1")
    service:assign("pickup", "ironchests:diamond_chest_1")
    service:addStorage("colossalchests:colossal_chest_0", "Main", 1)
    return service
end

return {
    {name="discovery by type finds the turtle, which is not an inventory",run=function()
        local found = setup():discoverByType("turtle")
        T.equal(#found, 1)
        T.equal(found[1].name, "turtle_2")
    end},
    {name="discovery by type finds both monitors",run=function()
        local found = setup():discoverByType("monitor")
        T.equal(#found, 2)
        T.equal(found[1].name, "monitor_0")
        T.equal(found[2].name, "top")
    end},
    {name="inventory discovery still excludes the turtle and monitors",run=function()
        local names = {}
        for _, entry in ipairs(setup():discover()) do names[entry.name] = true end
        T.equal(names["turtle_2"], nil)
        T.equal(names["monitor_0"], nil)
        T.equal(names["ironchests:diamond_chest_2"], true)
    end},
    {name="the crafting bindings can be assigned",run=function()
        local service = configured(setup())
        T.equal(service:assign("craft_buffer", "ironchests:diamond_chest_2"), true)
        T.equal(service:assign("turtle", "turtle_2"), true)
        T.equal(service:assign("monitor_main", "top"), true)
        T.equal(service:assign("monitor_crafting", "monitor_0"), true)
        local draft = service:draft()
        T.equal(draft.craft_buffer.peripheral_name, "ironchests:diamond_chest_2")
        T.equal(draft.turtle.peripheral_name, "turtle_2")
        T.equal(draft.monitors.main, "top")
        T.equal(draft.monitors.crafting, "monitor_0")
    end},
    {name="skipping clears an optional binding",run=function()
        local service = configured(setup())
        service:assign("craft_buffer", "ironchests:diamond_chest_2")
        service:assign("turtle", "turtle_2")
        service:assign("monitor_crafting", "monitor_0")
        T.equal(service:assign("craft_buffer", nil), true)
        T.equal(service:assign("turtle", nil), true)
        T.equal(service:assign("monitor_crafting", nil), true)
        local draft = service:draft()
        T.equal(draft.craft_buffer, nil)
        T.equal(draft.turtle, nil)
        T.equal(draft.monitors, nil, "an empty monitor table is dropped entirely")
    end},
    {name="the required roles cannot be cleared",run=function()
        local service = configured(setup())
        T.equal(service:assign("dropoff", nil), nil)
        T.equal(service:assign("pickup", nil), nil)
        T.equal(service:draft().dropoff.peripheral_name, "ironchests:netherite_chest_1")
    end},
    {name="an unknown role is refused",run=function()
        T.equal(setup():assign("furnace", "x"), nil)
    end},
    {name="the buffer cannot be bound to Pickup",run=function()
        local service = configured(setup())
        service:assign("craft_buffer", "ironchests:diamond_chest_1")
        local report = service:validate()
        T.equal(report.ok, false, "both are ironchests:diamond_chest; only the index differs")
    end},
    {name="a validated crafting setup commits as schema 2",run=function()
        local service = configured(setup())
        service:assign("craft_buffer", "ironchests:diamond_chest_2")
        service:assign("turtle", "turtle_2")
        service:assign("monitor_main", "top")
        service:assign("monitor_crafting", "monitor_0")
        local report = service:validate()
        T.equal(report.ok, true, "a complete crafting setup must validate")
        T.equal(service:commit(report), true)
        local saved = service:draft()
        T.equal(saved.schema, 2)
        T.equal(saved.configured, true)
        T.equal(saved.craft_buffer.peripheral_name, "ironchests:diamond_chest_2")
        T.equal(saved.turtle.peripheral_name, "turtle_2")
        T.equal(saved.monitors.crafting, "monitor_0")
        T.equal(Setup.validateConfig(saved), true)
    end},
    {name="an installation with no crafting hardware still commits",run=function()
        local service = configured(setup())
        local report = service:validate()
        T.equal(report.ok, true)
        T.equal(service:commit(report), true)
        local saved = service:draft()
        T.equal(saved.schema, 2)
        T.equal(saved.craft_buffer, nil, "skipping crafting must not block Setup")
        T.equal(Setup.validateConfig(saved), true)
    end},
}
