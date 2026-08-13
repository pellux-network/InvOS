local T = require("tests.mock_cc")

-- The splash plays before the first shell.run, entirely through its own sleep calls.
-- Those must never be mistaken for the supervisor's backoff delays, so only sleeps
-- observed once a run has actually started are counted into `slept`; splash's own are
-- kept separately for the tests that care it ran at all.
local function runStartup(script)
    local previousShell, previousPrintError, previousSleep, previousTerm =
        shell, printError, sleep, term
    local calls, printed, slept, splashSleeps = {}, {}, {}, {}
    local runsStarted = false
    shell = { run = function(path)
        runsStarted = true
        calls[#calls + 1] = path
        return script.run(#calls)
    end }
    printError = function(message) printed[#printed + 1] = message end
    sleep = function(seconds)
        if runsStarted then
            slept[#slept + 1] = seconds
            if script.sleep then script.sleep(seconds) end
        else
            splashSleeps[#splashSleeps + 1] = seconds
        end
    end
    term = T.recordingSurface(51, 19)
    local surface = term
    local chunk, loadReason = loadfile("startup.lua")
    local ok, runReason = false, loadReason
    if chunk then ok, runReason = pcall(chunk) end
    shell, printError, sleep, term = previousShell, previousPrintError, previousSleep, previousTerm
    if not ok then error(runReason, 0) end
    return calls, printed, slept, splashSleeps, surface
end

return {
    { name = "a cold boot plays the splash on the terminal before launching", run = function()
        local calls, printed, slept, splashSleeps, surface =
            runStartup({ run = function() return true end })
        T.truthy(#splashSleeps > 1, "expected the splash to animate through several frames")
        T.contains(surface.allText(), "INVENTORY OPERATING SYSTEM")
        T.equal(#printed, 0)
    end },
    { name = "a crash-restart does not replay the splash", run = function()
        local results = { false, false, true }
        local calls, printed, slept, splashSleeps =
            runStartup({ run = function(n) return results[n] end })
        -- The splash runs once at the top of this file, before shell.run is ever called;
        -- restarting main.lua from the supervisor loop below never re-enters that code.
        T.truthy(#splashSleeps > 1, "expected exactly one splash, played before the first run")
        T.equal(#calls, 3)
    end },
    { name = "startup launches the storage application", run = function()
        local calls, printed, slept = runStartup({ run = function() return true end })
        T.arrayEqual(calls, { "/storage/main.lua" })
        T.equal(#printed, 0)
        T.equal(#slept, 0)
    end },
    { name = "startup restarts after a failure with backoff, then succeeds", run = function()
        local results = { false, false, true }
        local calls, printed, slept = runStartup({ run = function(n) return results[n] end })
        T.arrayEqual(calls, { "/storage/main.lua", "/storage/main.lua", "/storage/main.lua" })
        T.arrayEqual(slept, { 1, 2 })
        T.equal(#printed, 2)
        T.contains(printed[1], "error")
        T.contains(printed[1], "restarting")
    end },
    { name = "backoff resets after a run that lasted a long time", run = function()
        -- crash, crash, then a long healthy run, then crash again: the next wait must be
        -- the fresh 1s rather than carrying the escalated delay from a month ago.
        local elapsed = { 0, 0, 600, 0 }
        local at = 0
        local previousClock = os.clock
        os.clock = function() return at end
        local ok, calls, printed, slept = pcall(runStartup, {
            run = function(n) at = at + (elapsed[n] or 0); return n > 4 end,
        })
        os.clock = previousClock
        if not ok then error(calls, 0) end
        T.arrayEqual(slept, { 1, 2, 1, 2 })
    end },
    { name = "backoff escalates and caps at 30 seconds", run = function()
        local failures = 8
        local calls, printed, slept = runStartup({
            run = function(n) return n > failures end,
        })
        T.equal(#calls, failures + 1)
        T.arrayEqual(slept, { 1, 2, 4, 8, 16, 30, 30, 30 })
    end },
    { name = "a human at the keyboard can stop the restart loop during backoff", run = function()
        local calls, printed, slept = runStartup({
            run = function() return false end,
            sleep = function() error("Terminated", 0) end,
        })
        T.equal(#calls, 1)
        T.arrayEqual(slept, { 1 })
        T.equal(#printed, 2)
        T.contains(printed[2], "operator")
    end },
}
