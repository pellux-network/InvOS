local TurtleLink = {}
TurtleLink.__index = TurtleLink

local PROTOCOL = "invos-craft"

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
        pending = nil, inbox = {},
    }, TurtleLink)
end

local SIDES = {"bottom", "top", "left", "right", "front", "back"}

-- rednet.send throws "No open sides" unless a modem has been opened, and the controller
-- has no other reason to touch rednet, so nothing else opens one. Without this the very
-- first craft reports the turtle unreachable when the turtle is sitting right there
-- listening: the failure is on the sending end.
--
-- Idempotent, and re-checked on every send rather than once at construction, because a
-- modem can be detached and reattached while the controller runs.
function TurtleLink:_ensureOpen()
    if type(self.rednet.isOpen) == "function" then
        local ok, open = pcall(self.rednet.isOpen)
        if ok and open then return true end
    end
    for _, side in ipairs(SIDES) do
        local ok, kind = pcall(self.peripheral.getType, side)
        if ok and kind == "modem" then
            local opened = pcall(self.rednet.open, side)
            if opened then
                self.side = side
                return true
            end
        end
    end
    return false
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
    if not self:_ensureOpen() then
        return nil, "no modem is open, so the crafting turtle cannot be reached"
    end
    local target = self:id()
    if not target then self:forget(); return nil, "the crafting turtle is not reachable" end
    local ok, sent = pcall(self.rednet.send, target, command, self.protocol)
    if not ok or sent == false then
        self:forget()
        return nil, "the crafting turtle did not accept the command"
    end
    -- Drop anything left over from an earlier job so a stale reply cannot be
    -- mistaken for this one's.
    self.inbox = {}
    self.pending = command.job
    return true
end

-- Replies arrive as rednet_message events on the controller's main event loop, and are
-- handed here by the coordinator. They are NOT read with rednet.receive.
--
-- rednet.receive only catches a message that lands while it is waiting. The craft
-- service polls from the work loop, which spends almost all of its time scanning,
-- planning or sleeping, so a reply arriving outside that sliver of a tick was consumed
-- by the event loop and discarded as unrecognised. The turtle answered and the
-- controller threw the answer away, then timed out blaming the turtle.
function TurtleLink:deliver(sender, message, protocol)
    if protocol ~= nil and protocol ~= self.protocol then return false end
    if type(message) ~= "table" then return false end
    local expected = self:id()
    if expected and sender ~= expected then return false end
    self.inbox[#self.inbox + 1] = message
    return true
end

function TurtleLink:poll()
    if not self.pending then return nil end
    local message = table.remove(self.inbox, 1)
    if message == nil then return nil end
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
