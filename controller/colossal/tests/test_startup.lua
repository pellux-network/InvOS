local T = require("tests.mock_cc")

local function runStartup(shellResult)
    local previousShell, previousPrintError = shell, printError
    local calls, printed = {}, {}
    shell = { run = function(path) calls[#calls + 1] = path; return shellResult end }
    printError = function(message) printed[#printed + 1] = message end
    local chunk, loadReason = loadfile("startup.lua")
    local ok, runReason = false, loadReason
    if chunk then ok, runReason = pcall(chunk) end
    shell, printError = previousShell, previousPrintError
    if not ok then error(runReason, 0) end
    return calls, printed
end

return {
    { name = "startup launches the colossal application", run = function()
        local calls, printed = runStartup(true)
        T.arrayEqual(calls, { "/colossal/main.lua" })
        T.equal(#printed, 0)
    end },
    { name = "startup reports an application failure", run = function()
        local _, printed = runStartup(false)
        T.arrayEqual(printed, { "Colossal Storage stopped with an error" })
    end },
}
