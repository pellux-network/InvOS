-- Crafting turtle entry point. Deployed to the turtle, never to the controller.
--
-- Deliberately thin: it opens a modem, listens on the craft protocol, and hands every
-- message to the executor. All recipe knowledge, planning and item accounting lives on
-- the controller, so this program does not change when recipes or the planner do. The one
-- thing it owns outright is its own screen: a boot splash, then a status display driven by
-- the executor's notify callback and by the rednet replies this loop already produces.
package.path = "/crafter/?.lua;/?.lua;" .. package.path

local Executor = require("crafter.executor")
local Hud = require("crafter.hud")
local Splash = require("crafter.splash")
local Theme = require("crafter.theme")

local PROTOCOL = "invos-craft"

-- How often the idle screen redraws with no message pending, purely so the uptime clock
-- does not look frozen. A craft job redraws on every notify call regardless of this.
local IDLE_REFRESH_SECONDS = 1

local function openModem()
    for _, side in ipairs({"left", "right", "top", "bottom", "front", "back"}) do
        if peripheral.getType(side) == "modem" then
            rednet.open(side)
            return side
        end
    end
    return nil
end

local function noModemScreen(id, label)
    Theme.apply(term)
    term.setBackgroundColor(Theme.role.ground)
    term.setTextColor(Theme.role.alert)
    term.clear()
    term.setCursorPos(1, 1)
    term.write("NO MODEM ATTACHED")
    term.setCursorPos(1, 2)
    term.setTextColor(Theme.role.muted)
    term.write("crafter #" .. tostring(id) .. " (" .. tostring(label) .. ") is unreachable")
end

-- Turns an executor notify event into a status mutation and an immediate redraw. Kept
-- separate from the receive loop below so a render failure (pcall'd here) can never take
-- down a craft in progress -- the HUD only displays status, it never gates one.
local function makeNotify(status)
    return function(event, data)
        data = data or {}
        if event == "staging" then
            status.state = "STAGING"
            status.job = {item = data.item, quantity = data.quantity, filled = 0, total = 0}
        elseif event == "stage_progress" then
            if status.job then
                status.job.filled, status.job.total = data.filled, data.total
            end
        elseif event == "crafting" then
            status.state = "CRAFTING"
            if status.job then status.job.filled, status.job.total = nil, nil end
        elseif event == "purging" then
            status.state = "PURGING"
        end
        status.now = os.clock()
        pcall(Hud.render, term, status)
    end
end

local function main()
    local side = openModem()
    local id = os.getComputerID()
    local label = os.getComputerLabel() or "crafter"
    if not side then
        noModemScreen(id, label)
        printError("No modem attached; the crafting turtle cannot be reached.")
        return
    end

    Splash.play(term, sleep, {id = id, label = label, side = side})

    local status = {id = id, label = label, side = side, now = os.clock(),
        state = "IDLE", job = nil, last = nil, jobs_done = 0}
    local executor = Executor.new({turtle = turtle, label = label, notify = makeNotify(status)})

    -- Start empty. A reboot mid-job leaves ingredients held; returning them to the buffer
    -- keeps them somewhere the controller can account for.
    executor:purge()
    pcall(Hud.render, term, status)

    while true do
        local sender, message = rednet.receive(PROTOCOL, IDLE_REFRESH_SECONDS)
        if sender then
            local ok, reply = pcall(function() return executor:handle(message) end)
            if not ok then
                reply = {ok = false, code = "EXECUTOR_ERROR", message = tostring(reply)}
                pcall(function() executor:purge() end)
            end
            rednet.send(sender, reply, PROTOCOL)

            if type(message) == "table" and message.op == "craft" then
                local result = message.result or {}
                status.last = {ok = reply.ok, item = result.name, quantity = result.count,
                    code = reply.code, message = reply.message}
                if reply.ok then status.jobs_done = status.jobs_done + 1 end
            end
            status.state, status.job = "IDLE", nil
        end
        status.now = os.clock()
        pcall(Hud.render, term, status)
    end
end

if ... == nil then
    local ok, reason = xpcall(main, function(value)
        return debug and debug.traceback and debug.traceback(value, 2) or tostring(value)
    end)
    if not ok then
        pcall(Theme.restore, term)
        printError("InvOS crafter failed: " .. tostring(reason))
    end
end
