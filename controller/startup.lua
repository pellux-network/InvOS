local path = "/colossal/main.lua"
local delay = 1
while true do
    local ok = shell.run(path)
    if ok then break end
    printError("Colossal Storage stopped with an error; restarting in " .. delay .. "s")
    local slept = pcall(sleep, delay)
    if not slept then
        printError("Colossal Storage supervisor stopped by operator")
        break
    end
    delay = math.min(delay * 2, 30)
end
