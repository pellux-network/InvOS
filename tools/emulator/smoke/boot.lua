-- Emulator entry point: build the world, seed config, then hand over to InvOS.
--
-- CraftOS-PC runs this via `--script`, before the computer's own startup. It
-- reads a scenario table written by the host harness, stands up the emulated
-- wired network, optionally writes `storage/data/config.lua` so a run can start
-- past the setup wizard, and then runs the real `startup.lua`.
--
-- Nothing here is deployable and nothing in `controller/` may require it. The
-- config it writes goes to the emulator's scratch computer directory, never to
-- a live tree.

local SCENARIO = "/scenario.lua"
local WORLD = "/world.lua"

local function fail(message)
    term.setBackgroundColour(colours.black)
    term.setTextColour(colours.red)
    term.clear()
    term.setCursorPos(1, 1)
    print("EMULATOR HARNESS FAILURE")
    print(message)
    -- Stay up rather than shutting down: the harness reads this off the screen,
    -- and a computer that exits immediately gives it nothing to report.
    while true do os.pullEventRaw() end
end

-- CraftOS-PC runs --script on EVERY computer, not only the one --id names, so
-- this file is the crafting turtle's entry point as well as the controller's.
-- The turtle is a genuinely separate computer: its own filesystem, its own rednet
-- ID, and none of the controller's peripherals -- which is why its branch shares
-- nothing below except the failure screen.
if os.getComputerID() ~= 0 then
    local turtleScenario = {}
    if fs.exists(SCENARIO) then
        local loaded, value = pcall(dofile, SCENARIO)
        if loaded and type(value) == "table" then turtleScenario = value end
    end

    if peripheral.getType("back") ~= "modem" then periphemu.create("back", "modem") end
    rednet.open("back")

    local loadedApi, api = pcall(dofile, "/turtle_api.lua")
    if not loadedApi then fail("turtle api failed to load: " .. tostring(api)) end
    _G.turtle = api

    -- The firmware purges into the buffer before its first message, so the world
    -- server has to be listening before startup.lua runs. It is not, yet: the
    -- controller adds it to its parallel set only once the world is built, and
    -- this computer boots the moment periphemu creates it.
    if not api.waitForWorld(30) then
        fail("the world server on computer 0 never answered")
    end

    if turtleScenario.skip_splash then
        -- The turtle's splash is a real part of a cold boot and costs seconds on
        -- every run, exactly as the controller's does. Same reasoning, same
        -- treatment -- and the firmware itself is untouched.
        package.loaded["crafter.splash"] = {play = function() end}
    end

    shell.run("/startup.lua")
    return
end

if not fs.exists(SCENARIO) then fail("missing " .. SCENARIO) end

local loadedScenario, scenario = pcall(dofile, SCENARIO)
if not loadedScenario then fail("scenario failed to load: " .. tostring(scenario)) end
scenario = scenario or {}

-- Loaded once and kept: `dofile` re-executes the module and would hand back a
-- fresh table, so a second load would not carry the profiler state that
-- World.profilePeripherals installs on this one.
local world = nil
if scenario.world then
    local loadedWorld, World = pcall(dofile, WORLD)
    if not loadedWorld then fail("world failed to load: " .. tostring(World)) end
    local built, reason = pcall(World.build, scenario.world)
    if not built then fail("world failed to build: " .. tostring(reason)) end
    world = World
end

-- The turtle's world, and the turtle itself. Created before anything else that
-- takes a raw-protocol window, because windows are numbered in creation order:
-- with a monitor created first the turtle lands on window 2, and the harness
-- identifies it as the lowest non-zero window. The computer boots itself -- isOn
-- is already true on creation -- and runs this same script down the branch above.
local turtleWorld = nil
if world and scenario.world.turtle then
    local loadedTurtle, WorldTurtle = pcall(dofile, "/world_turtle.lua")
    if not loadedTurtle then fail("world_turtle failed to load: " .. tostring(WorldTurtle)) end
    local built, server = pcall(WorldTurtle.new, scenario.world.turtle, world)
    if not built then fail("turtle world failed to build: " .. tostring(server)) end
    turtleWorld = server
    periphemu.create(scenario.world.turtle.id or 1, "computer")
end

if scenario.config then
    if not fs.exists("/storage/data") then fs.makeDir("/storage/data") end
    local handle = fs.open("/storage/data/config.lua", "w")
    handle.write(textutils.serialize(scenario.config, { compact = true }))
    handle.close()
end

-- Extra data files (aliases, metadata, a pre-seeded journal for recovery runs)
-- are written the same way the controller would write them, through
-- textutils.serialize, so the store reads them back with its own codec.
for name, value in pairs(scenario.data or {}) do
    if not fs.exists("/storage/data") then fs.makeDir("/storage/data") end
    local handle = fs.open("/storage/data/" .. name .. ".lua", "w")
    handle.write(textutils.serialize(value, { compact = true }))
    handle.close()
end

-- With profiling on, the counts are flushed on a timer beside the application
-- so the host can read them mid-run rather than only after a clean exit -- which
-- matters because the controller is a supervisor loop that does not exit.
local function flushProfileForever()
    while true do
        sleep(1)
        if world and world.flushProfile then pcall(world.flushProfile) end
    end
end

local function runApplication()
    if scenario.skip_splash then
        -- The splash is a real part of a cold boot, but it costs seconds on every
        -- run. Scenarios that are asserting on a later screen can skip straight to
        -- the application; the splash gets its own scenario instead.
        shell.run("/storage/main.lua")
    else
        shell.run("/startup.lua")
    end
end

local function serveTurtleWorld()
    turtleWorld:serve()
end

-- One place starts the application, whatever else is running beside it. Each
-- coroutine under parallel sees every event, so the world server reading its own
-- rednet protocol cannot starve the controller's event loop of craft replies.
local tasks = {runApplication}
if scenario.world and scenario.world.profile then tasks[#tasks + 1] = flushProfileForever end
if turtleWorld then tasks[#tasks + 1] = serveTurtleWorld end

if #tasks == 1 then
    runApplication()
else
    parallel.waitForAny(table.unpack(tasks))
end
