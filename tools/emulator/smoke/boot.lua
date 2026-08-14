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
        shell.run("/storage/main.lua")
    else
        shell.run("/startup.lua")
    end
end

if scenario.world and scenario.world.profile then
    parallel.waitForAny(runApplication, flushProfileForever)
    return
end

if scenario.skip_splash then
    -- The splash is a real part of a cold boot, but it costs seconds on every
    -- run. Scenarios that are asserting on a later screen can skip straight to
    -- the application; the splash gets its own scenario instead.
    shell.run("/storage/main.lua")
else
    shell.run("/startup.lua")
end
