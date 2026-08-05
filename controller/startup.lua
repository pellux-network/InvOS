local path = "/colossal/main.lua"
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
