local Theme = require("app.theme")
local T = require("tests.mock_cc")

-- A surface that records palette writes. mock_cc's recordingSurface has no palette API,
-- which is deliberately also the case this module must survive.
local function paletteSurface()
    local writes = {}
    return {
        getSize = function() return 51, 19 end,
        setPaletteColour = function(slot, value) writes[slot] = value end,
        writes = writes,
    }
end

return {
    { name = "every role resolves to a real colour slot", run = function()
        -- Theme.palette, not the `colors` global: the host test environment has no CC
        -- globals at all beyond the `keys` table test_craft_ui defines for itself.
        local slots = {}
        for _, value in pairs(Theme.palette) do slots[value] = true end
        local count = 0
        for name, value in pairs(Theme.role) do
            T.equal(type(value), "number", name .. " must be a colour value")
            T.equal(slots[value], true, name .. " must be one of the sixteen CC slots")
            count = count + 1
        end
        T.equal(count, 15, "a role added without a test is a role nothing checks")
    end },
    { name = "brand and alert are different reds", run = function()
        T.equal(Theme.role.brand ~= Theme.role.alert, true,
            "an alert that is the same colour as the chrome does not read as an alert")
    end },
    { name = "apply writes every InvOS slot value", run = function()
        local surface = paletteSurface()
        T.equal(Theme.apply(surface), true)
        for name, value in pairs(Theme.slots) do
            T.equal(surface.writes[Theme.palette[name]], value, name .. " was not applied")
        end
    end },
    { name = "restore puts back the CC defaults exactly", run = function()
        local surface = paletteSurface()
        Theme.apply(surface)
        T.equal(Theme.restore(surface), true)
        for name, value in pairs(Theme.defaults) do
            T.equal(surface.writes[Theme.palette[name]], value, name .. " was not restored")
        end
    end },
    { name = "restore covers every slot apply touches", run = function()
        for name in pairs(Theme.slots) do
            T.equal(Theme.defaults[name] ~= nil, true,
                name .. " is applied but has no default to restore, so it would stay changed")
        end
    end },
    { name = "a surface with no palette API is refused, not crashed on", run = function()
        T.equal(Theme.apply(T.recordingSurface(51, 19)), false)
        T.equal(Theme.restore(T.recordingSurface(51, 19)), false)
        T.equal(Theme.apply(nil), false)
    end },
    { name = "restore is reachable from every exit path", run = function()
        local startup = io.open("startup.lua")
        T.equal(startup ~= nil, true, "run the suite from controller/, not colossal/")
        local text = startup:read("a"); startup:close()
        T.contains(text, "restore",
            "an InvOS that exits without restoring leaves the shell in InvOS colours")
        local main = io.open("colossal/main.lua")
        local mainText = main:read("a"); main:close()
        T.contains(mainText, "Theme.restore")
    end },
    { name = "status colours separate healthy, degraded and failed", run = function()
        T.equal(Theme.statusColor("READY"), Theme.role.ok)
        T.equal(Theme.statusColor("COMPLETE"), Theme.role.ok)
        T.equal(Theme.statusColor("DEGRADED"), Theme.role.warn)
        T.equal(Theme.statusColor("BLOCKED"), Theme.role.warn)
        T.equal(Theme.statusColor("PARTIAL"), Theme.role.warn)
        T.equal(Theme.statusColor("ERROR"), Theme.role.alert)
        T.equal(Theme.statusColor("FAILED"), Theme.role.alert)
        T.equal(Theme.statusColor("OFFLINE"), Theme.role.alert)
        T.equal(Theme.statusColor("TRANSFERRING"), Theme.role.working)
        T.equal(Theme.statusColor(nil), Theme.role.working)
    end },
}
