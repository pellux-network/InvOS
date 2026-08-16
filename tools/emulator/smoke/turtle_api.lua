-- The `turtle` global on the emulated crafting turtle.
--
-- CraftOS-PC has no turtles at all, so this is the one part of the crafting path
-- the harness genuinely fakes. It fakes as little as possible: it holds no item
-- state, makes no decisions, and answers nothing on its own. Every call is one
-- rednet round trip to the world server on computer 0, which owns the chests and
-- performs the move -- because peripherals do not cross computers, so a turtle
-- that tried to hold its own inventory would need syncing, and a test would then
-- be asserting on the sync.
--
-- Only the seven methods turtle/crafter/executor.lua and turtle/startup.lua
-- actually use are provided. Anything else the firmware grows will fail loudly as
-- a nil call rather than quietly returning a plausible false.

local PROTOCOL = "invos-emu-world"
local TIMEOUT = 15

local scenario = fs.exists("/scenario.lua") and dofile("/scenario.lua") or {}
if type(scenario) ~= "table" then scenario = {} end
local SERVER = scenario.world_server or 0

local sequence = 0

-- Errors rather than returning false on a transport failure. A false here would
-- be indistinguishable from "the buffer was empty", which is a legitimate answer
-- the executor acts on -- so a broken harness would look like a legitimate craft
-- failure and send someone hunting a controller bug that does not exist.
local function rpc(op, ...)
    sequence = sequence + 1
    local args = table.pack(...)
    local request = {seq = sequence, op = op, args = args, n = args.n}
    if not rednet.send(SERVER, request, PROTOCOL) then
        error("emulated turtle: could not reach the world server for " .. op, 0)
    end
    local deadline = os.clock() + TIMEOUT
    while os.clock() < deadline do
        local sender, reply = rednet.receive(PROTOCOL, 1)
        if sender == SERVER and type(reply) == "table" and reply.seq == request.seq then
            if not reply.ok then
                error("emulated turtle: " .. op .. " failed: " .. tostring(reply.error), 0)
            end
            local value = reply.value or {}
            return table.unpack(value, 1, reply.n or #value)
        end
    end
    error("emulated turtle: the world server did not answer " .. op, 0)
end

local api = {}

function api.select(slot) return rpc("select", slot) end
function api.getItemCount(slot) return rpc("count", slot) end
function api.getItemDetail(slot) return rpc("detail", slot) end
function api.suckDown(count) return rpc("suckDown", count) end
function api.dropDown(count) return rpc("dropDown", count) end
function api.transferTo(slot, count) return rpc("transferTo", slot, count) end
function api.craft(limit) return rpc("craft", limit) end

--- Block until the world server is listening, or give up.
--
-- The firmware purges into the buffer before its first message, so the server has
-- to be up before startup.lua runs. It is not, yet: the controller adds it to its
-- parallel set only once the world is built, and this computer boots the moment
-- periphemu creates it.
function api.waitForWorld(attempts)
    for _ = 1, attempts or 30 do
        if pcall(rpc, "ping") then return true end
    end
    return false
end

return api
