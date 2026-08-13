-- The splash plays once per real cold boot, never on an automatic crash-restart below:
-- this file only runs when CraftOS itself starts it, not on the while loop's retries.
-- A rendering bug in it must never be able to keep the real application from starting.
package.path = "/storage/?.lua;/storage/?/init.lua;" .. package.path
local Splash = require("app.splash")
local Theme = require("app.theme")
local splashOk, splashReason = pcall(Splash.play, term.current and term.current() or term, sleep)
if not splashOk then printError("InvOS splash failed: " .. tostring(splashReason)) end

local path = "/storage/main.lua"
-- A run that stayed up a long time is evidence the earlier fault cleared, so its next
-- failure starts from a fresh backoff rather than inheriting an escalation from weeks ago.
local healthyRunSeconds = 300
local delay = 1
while true do
    local startedAt = os.clock()
    local ok = shell.run(path)
    if ok then break end
    if os.clock() - startedAt >= healthyRunSeconds then delay = 1 end
    printError("InvOS stopped with an error; restarting in " .. delay .. "s")
    local slept = pcall(sleep, delay)
    if not slept then
        printError("InvOS supervisor stopped by operator")
        break
    end
    delay = math.min(delay * 2, 30)
end

-- The loop above exits when the application stops cleanly or the operator interrupts the
-- backoff. Either way the terminal must not be left in InvOS colours.
pcall(Theme.restore, term.current and term.current() or term)
