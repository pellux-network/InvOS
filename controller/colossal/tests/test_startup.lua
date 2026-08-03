local T = require("tests.mock_cc")

local function runStartup(script)
    local previousShell, previousPrintError, previousSleep = shell, printError, sleep
    local calls, printed, slept = {}, {}, {}
    shell = { run = function(path) calls[#calls + 1] = path; return script.run(#calls) end }
    printError = function(message) printed[#printed + 1] = message end
    sleep = function(seconds)
        slept[#slept + 1] = seconds
        if script.sleep then script.sleep(seconds) end
    end
    local chunk, loadReason = loadfile("startup.lua")
    local ok, runReason = false, loadReason
    if chunk then ok, runReason = pcall(chunk) end
    shell, printError, sleep = previousShell, previousPrintError, previousSleep
    if not ok then error(runReason, 0) end
    return calls, printed, slept
end

return {
    { name = "startup launches the colossal application", run = function()
        local calls, printed, slept = runStartup({ run = function() return true end })
        T.arrayEqual(calls, { "/colossal/main.lua" })
        T.equal(#printed, 0)
        T.equal(#slept, 0)
    end },
    { name = "startup restarts after a failure with backoff, then succeeds", run = function()
        local results = { false, false, true }
        local calls, printed, slept = runStartup({ run = function(n) return results[n] end })
        T.arrayEqual(calls, { "/colossal/main.lua", "/colossal/main.lua", "/colossal/main.lua" })
        T.arrayEqual(slept, { 1, 2 })
        T.equal(#printed, 2)
        T.contains(printed[1], "error")
        T.contains(printed[1], "restarting")
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
