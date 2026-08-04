local TurtleLink = {}
TurtleLink.__index = TurtleLink

local PROTOCOL = "pellstore-craft"

-- Rednet addresses computers by ID, but the turtle is bound in config by peripheral
-- name, and that name is volatile: it derives from the computer ID, so a rebuilt turtle
-- gets a new one. Resolving the ID at runtime through the bound peripheral means a
-- rebuild costs one Setup rebind and nothing else, and a stored ID can never go stale.
function TurtleLink.new(deps)
    assert(type(deps) == "table", "turtle link dependencies are required")
    return setmetatable({
        rednet = assert(deps.rednet, "rednet API is required"),
        peripheral = assert(deps.peripheral, "peripheral API is required"),
        name = assert(deps.name, "the turtle peripheral name is required"),
        protocol = deps.protocol or PROTOCOL,
        timeout = deps.timeout or 0,
        pending = nil,
    }, TurtleLink)
end

function TurtleLink:id()
    if self.cachedId then return self.cachedId end
    local ok, value = pcall(self.peripheral.call, self.name, "getID")
    if not ok or type(value) ~= "number" then return nil end
    self.cachedId = value
    return value
end

-- A rebuilt or replaced turtle changes both name and ID, so an unreachable turtle drops
-- the cache rather than retrying a dead address forever.
function TurtleLink:forget() self.cachedId = nil end

function TurtleLink:send(command)
    local target = self:id()
    if not target then self:forget(); return nil, "the crafting turtle is not reachable" end
    local ok, sent = pcall(self.rednet.send, target, command, self.protocol)
    if not ok or sent == false then
        self:forget()
        return nil, "the crafting turtle did not accept the command"
    end
    self.pending = command.job
    return true
end

-- Non-blocking by design: the craft service polls between work-loop ticks, so the
-- controller keeps importing and retrieving while the turtle works.
function TurtleLink:poll()
    if not self.pending then return nil end
    local ok, sender, message = pcall(self.rednet.receive, self.protocol, self.timeout)
    if not ok or sender == nil or type(message) ~= "table" then return nil end
    self.pending = nil
    return message
end

function TurtleLink:ping()
    local target = self:id()
    if not target then return false end
    local ok = pcall(self.rednet.send, target, {op="ping"}, self.protocol)
    return ok == true
end

return TurtleLink
