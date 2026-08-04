-- Crafting turtle entry point. Deployed to the turtle, never to the controller.
--
-- Deliberately tiny: it opens a modem, listens on the craft protocol, and hands every
-- message to the executor. All recipe knowledge, planning and item accounting lives on
-- the controller, so this program does not change when recipes or the planner do.
package.path = "/crafter/?.lua;/?.lua;" .. package.path

local Executor = require("crafter.executor")
local PROTOCOL = "pellstore-craft"

local function openModem()
    for _, side in ipairs({"left", "right", "top", "bottom", "front", "back"}) do
        if peripheral.getType(side) == "modem" then
            rednet.open(side)
            return side
        end
    end
    return nil
end

local function main()
    local side = openModem()
    if not side then
        printError("No modem attached; the crafting turtle cannot be reached.")
        return
    end
    local executor = Executor.new({turtle = turtle, label = os.getComputerLabel() or "crafter"})

    -- Start empty. A reboot mid-job leaves ingredients held; returning them to the
    -- buffer keeps them somewhere the controller can account for.
    executor:purge()

    print("PellStore crafter ready on " .. side .. " (id " .. os.getComputerID() .. ")")
    while true do
        local sender, message = rednet.receive(PROTOCOL)
        if sender then
            local ok, reply = pcall(function() return executor:handle(message) end)
            if not ok then
                reply = {ok = false, code = "EXECUTOR_ERROR", message = tostring(reply)}
                pcall(function() executor:purge() end)
            end
            rednet.send(sender, reply, PROTOCOL)
        end
    end
end

if ... == nil then
    local ok, reason = xpcall(main, function(value)
        return debug and debug.traceback and debug.traceback(value, 2) or tostring(value)
    end)
    if not ok then printError("PellStore crafter failed: " .. tostring(reason)) end
end
