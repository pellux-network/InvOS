-- Exercises turtle/startup.lua end to end: modem detection, the splash, the HUD-driven
-- receive loop, and how a craft reply feeds back into the status screen. Modeled on
-- tests.test_startup's harness (load the real file with loadfile, run it under mocked
-- globals, inspect what it did).
--
-- The receive loop is intentionally infinite (the turtle never has a reason to stop
-- listening), so the fake rednet.receive raises once its scripted steps run out. startup.lua's
-- own top-level xpcall catches that, so the chunk still returns normally -- this is a test
-- harness detail, not a real failure path.
local T = require("tests.mock_cc")

local function loadTurtleModule(name, path)
    if not package.loaded[name] then
        package.loaded[name] = dofile(path)
    end
    return package.loaded[name]
end
loadTurtleModule("crafter.theme", "../turtle/crafter/theme.lua")
loadTurtleModule("crafter.draw", "../turtle/crafter/draw.lua")
loadTurtleModule("crafter.splash", "../turtle/crafter/splash.lua")
loadTurtleModule("crafter.hud", "../turtle/crafter/hud.lua")
loadTurtleModule("crafter.executor", "../turtle/crafter/executor.lua")

-- A minimal turtle inventory: one buffer slot's worth of a single ingredient, enough to
-- drive one craft through to a reply. Ingredient-staging edge cases are executor.lua's own
-- job (tests.test_craft_turtle); this only needs the reply to reach the HUD.
local function fakeTurtleApi(itemName)
    local api = {slots = {}, selected = 1, dropped = {}}
    api.buffer = {{name = itemName, count = 8}}
    function api.select(slot) api.selected = slot; return true end
    function api.getItemCount(slot) local e = api.slots[slot or api.selected]; return e and e.count or 0 end
    function api.getItemDetail(slot)
        local e = api.slots[slot or api.selected]
        return e and {name = e.name, count = e.count} or nil
    end
    function api.suckDown()
        for index, entry in ipairs(api.buffer) do
            if entry and entry.count > 0 then
                local taken = entry.count
                entry.count = 0
                api.buffer[index] = false
                api.slots[api.selected] = {name = entry.name, count = taken}
                return true
            end
        end
        return false
    end
    function api.transferTo(slot, count)
        local from = api.slots[api.selected]
        if not from or from.count < count then return false end
        from.count = from.count - count
        api.slots[slot] = {name = from.name, count = (api.slots[slot] and api.slots[slot].count or 0) + count}
        if from.count == 0 then api.slots[api.selected] = nil end
        return true
    end
    function api.dropDown()
        local e = api.slots[api.selected]
        if not e then return false end
        api.dropped[#api.dropped + 1] = {name = e.name, count = e.count}
        api.slots[api.selected] = nil
        return true
    end
    function api.craft()
        for _, slot in ipairs({1, 2, 3, 5, 6, 7, 9, 10, 11}) do
            local e = api.slots[slot]
            if e then
                e.count = e.count - 1
                if e.count <= 0 then api.slots[slot] = nil end
            end
        end
        api.slots[16] = {name = "minecraft:chest", count = 1}
        return true
    end
    return api
end

local function chestCraftMessage()
    return {op = "craft", job = "job-1",
        steps = {{expect = "minecraft:oak_planks", cells = {1, 2, 3, 5, 7, 9, 10, 11}, per_cell = 1}},
        result = {name = "minecraft:chest", count = 1}}
end

-- Runs turtle/startup.lua under mocked globals. `steps` scripts successive rednet.receive
-- results ({sender=, message=} or {} for a timeout); once exhausted, receive raises to
-- unwind the otherwise-infinite loop.
local function runTurtleStartup(options)
    options = options or {}
    local previous = {rednet = rednet, turtle = _G.turtle, peripheral = peripheral, term = term,
        sleep = sleep, printError = printError,
        getComputerID = os.getComputerID, getComputerLabel = os.getComputerLabel}

    local sent, printed, receiveCalls = {}, {}, 0
    local surface = T.recordingSurface(39, 13)

    _G.peripheral = {getType = function(side)
        if options.noModem then return nil end
        return side == "back" and "modem" or nil
    end}
    _G.rednet = {
        open = function() end,
        send = function(id, reply, protocol) sent[#sent + 1] = {id = id, reply = reply, protocol = protocol} end,
        receive = function(protocol, timeout)
            receiveCalls = receiveCalls + 1
            local step = options.steps and options.steps[receiveCalls]
            if not step then error("test-stop") end
            return step.sender, step.message
        end,
    }
    _G.turtle = options.turtleApi or fakeTurtleApi("minecraft:oak_planks")
    _G.term = surface
    _G.sleep = function() end
    _G.printError = function(message) printed[#printed + 1] = tostring(message) end
    os.getComputerID = function() return 5 end
    os.getComputerLabel = function() return "Crafter" end

    local chunk, loadReason = loadfile("../turtle/startup.lua")
    local ok, runReason = false, loadReason
    if chunk then ok, runReason = pcall(chunk) end

    _G.rednet, _G.turtle, _G.peripheral, _G.term = previous.rednet, previous.turtle, previous.peripheral, previous.term
    _G.sleep, _G.printError = previous.sleep, previous.printError
    os.getComputerID, os.getComputerLabel = previous.getComputerID, previous.getComputerLabel

    if not ok then error(runReason, 0) end
    return {sent = sent, printed = printed, surface = surface}
end

return {
    {name = "no modem shows an alert screen instead of crashing", run = function()
        local result = runTurtleStartup({noModem = true})
        T.contains(result.surface.allText(), "NO MODEM")
        T.truthy(#result.printed > 0, "expected an error to be reported")
        T.contains(result.printed[1], "No modem attached")
    end},
    {name = "boots to an idle HUD and survives a receive timeout", run = function()
        local result = runTurtleStartup({steps = {{}}}) -- one timeout, then test-stop
        T.contains(result.surface.allText(), "CRAFTER")
        T.contains(result.surface.allText(), "IDLE")
    end},
    {name = "a successful craft replies ok and the HUD shows the result", run = function()
        local result = runTurtleStartup({steps = {{sender = 99, message = chestCraftMessage()}}})
        T.equal(#result.sent, 1)
        T.equal(result.sent[1].id, 99)
        T.equal(result.sent[1].reply.ok, true)
        local text = result.surface.allText()
        T.contains(text, "OK")
        T.contains(text, "chest")
        T.contains(text, "JOBS COMPLETE 1")
    end},
    {name = "a failed craft replies with the failure and does not count as a job", run = function()
        local result = runTurtleStartup({
            turtleApi = fakeTurtleApi("minecraft:cobblestone"),
            steps = {{sender = 99, message = chestCraftMessage()}},
        })
        T.equal(result.sent[1].reply.ok, false)
        local text = result.surface.allText()
        T.contains(text, "FAIL")
        T.contains(text, "JOBS COMPLETE 0")
    end},
    {name = "a ping is answered without disturbing the idle screen", run = function()
        local result = runTurtleStartup({steps = {{sender = 7, message = {op = "ping"}}}})
        T.equal(result.sent[1].reply.ok, true)
        T.equal(result.sent[1].reply.label, "Crafter")
        T.contains(result.surface.allText(), "IDLE")
    end},
}
