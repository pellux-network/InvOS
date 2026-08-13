local CraftBuffer = require("app.craft_buffer")
local TurtleLink = require("app.turtle_link")
-- Loaded by explicit path, NOT require: the turtle's manifest module has the same name
-- as the controller's, and require caches by name, so requiring it here would hand the
-- turtle's manifest to test_deployment and vice versa depending on load order.
local TurtleManifest = dofile("../turtle/deployment_manifest.lua")
local T = require("tests.mock_cc")

-- A link whose modem opens and whose turtle resolves, so tests can focus on the inbox.
local function workingLink()
    return TurtleLink.new({
        rednet = {send=function() return true end, receive=function() return nil end,
            isOpen=function() return true end, open=function() return true end},
        peripheral = {call=function() return 7 end, getType=function() return "modem" end},
        name = "turtle_2"})
end

local function bufferContext(slots, health)
    return {
        craft_buffer = {node_id="craft_buffer", peripheral_name="buffer",
            health=health or "READY", epoch=1, size=27, slots=slots or {}},
        pickup = {peripheral_name="pickup", health="READY"},
        storage = {{node_id="storage", health="READY", slots={}}},
        generation = 1, now = 100,
    }
end

local function slot(name, count, nbt)
    return {name=name, count=count, nbt=nbt,
        identity_key=name .. "\0" .. (nbt or "-"), max_count=64}
end

local function fakeImports(results)
    local value = {seen = {}, cursor = 0}
    function value:tick(context)
        self.cursor = self.cursor + 1
        self.seen[#self.seen + 1] = context.dropoff
        return results[math.min(self.cursor, #results)] or {state="IDLE"}
    end
    return value
end

local function fakeAdapter(behaviour)
    local value = {pushes = {}, mode = behaviour or "ok"}
    function value:push(from, to, fromSlot, limit)
        self.pushes[#self.pushes + 1] = {from=from, to=to, slot=fromSlot, limit=limit}
        if self.mode == "fail" then return nil, "inventory offline" end
        if self.mode == "full" then return true, 0 end
        return true, limit
    end
    return value
end

local function buffer(imports, adapter)
    return CraftBuffer.new({imports = imports or fakeImports({{state="IDLE"}}),
        adapter = adapter or fakeAdapter()})
end

return {
    {name="a snapshot aggregates the buffer by item name",run=function()
        local craft = buffer()
        local totals = craft:snapshot(bufferContext({
            [1] = slot("minecraft:oak_planks", 8),
            [3] = slot("minecraft:oak_planks", 4),
            [5] = slot("minecraft:coal", 1),
        }))
        T.equal(totals["minecraft:oak_planks"], 12)
        T.equal(totals["minecraft:coal"], 1)
    end},
    {name="ordering follows ascending slot, which is what suckDown does",run=function()
        local craft = buffer()
        local order = craft:ordered(bufferContext({
            [7] = slot("minecraft:coal", 1),
            [2] = slot("minecraft:oak_planks", 8),
        }))
        T.equal(order[1].slot, 2)
        T.equal(order[1].name, "minecraft:oak_planks")
        T.equal(order[2].slot, 7)
    end},
    {name="a buffer holding only what the step needs is already drained",run=function()
        local imports = fakeImports({{state="IDLE"}})
        local craft = buffer(imports)
        local result = craft:drain(bufferContext({[1] = slot("minecraft:oak_planks", 8)}),
            {["minecraft:oak_planks"] = 8})
        T.equal(result.state, "DONE")
        T.equal(#imports.seen, 0, "nothing should be moved")
    end},
    {name="only the excess is offered to the importer",run=function()
        local imports = fakeImports({{state="TRANSFERRING"}})
        local craft = buffer(imports)
        craft:drain(bufferContext({
            [1] = slot("minecraft:oak_planks", 8),
            [2] = slot("minecraft:cobblestone", 64),
        }), {["minecraft:oak_planks"] = 8})
        local offered = imports.seen[1]
        T.equal(offered.slots[2].name, "minecraft:cobblestone", "the excess is offered")
        T.equal(offered.slots[1], nil, "the ingredient must not be taken away again")
        T.equal(offered.peripheral_name, "buffer")
    end},
    {name="draining with no keep offers everything",run=function()
        local imports = fakeImports({{state="TRANSFERRING"}})
        local craft = buffer(imports)
        craft:drain(bufferContext({
            [1] = slot("minecraft:oak_planks", 8),
            [2] = slot("minecraft:cobblestone", 64),
        }), {})
        local offered = imports.seen[1]
        T.truthy(offered.slots[1] and offered.slots[2], "a full drain offers every slot")
    end},
    {name="a partially kept item drains the surplus slots",run=function()
        local imports = fakeImports({{state="TRANSFERRING"}})
        local craft = buffer(imports)
        craft:drain(bufferContext({
            [1] = slot("minecraft:oak_planks", 8),
            [2] = slot("minecraft:oak_planks", 8),
        }), {["minecraft:oak_planks"] = 8})
        local offered = imports.seen[1]
        T.equal(offered.slots[1], nil, "the first slot covers the budget")
        T.truthy(offered.slots[2], "the second is surplus")
    end},
    {name="an NBT-bearing item is always drained, never used as an ingredient",run=function()
        local imports = fakeImports({{state="TRANSFERRING"}})
        local craft = buffer(imports)
        craft:drain(bufferContext({
            [1] = slot("minecraft:oak_planks", 8, "abc123"),
        }), {["minecraft:oak_planks"] = 8})
        T.truthy(imports.seen[1].slots[1], "an enchanted or damaged variant is not an ingredient")
    end},
    {name="a blocked import blocks the drain",run=function()
        local craft = buffer(fakeImports({{state="BLOCKED", reason={code="STORAGE_FULL"}}}))
        local result = craft:drain(bufferContext({[1] = slot("minecraft:cobblestone", 64)}), {})
        T.equal(result.state, "BLOCKED")
        T.equal(result.reason.code, "STORAGE_FULL")
    end},
    {name="an unavailable buffer blocks rather than pretending to succeed",run=function()
        local craft = buffer()
        T.equal(craft:drain(bufferContext({}, "OFFLINE"), {}).state, "BLOCKED")
        T.equal(craft:drain({}, {}).state, "BLOCKED")
    end},
    {name="delivery to Pickup pushes straight from the buffer",run=function()
        local adapter = fakeAdapter()
        local craft = buffer(nil, adapter)
        local result = craft:deliver(bufferContext({
            [1] = slot("minecraft:chest", 3),
        }), "minecraft:chest", 3, "pickup")
        T.equal(result.state, "DONE")
        T.equal(result.moved, 3)
        T.equal(adapter.pushes[1].from, "buffer")
        T.equal(adapter.pushes[1].to, "pickup")
    end},
    {name="delivery spans several slots of the same item",run=function()
        local adapter = fakeAdapter()
        local craft = buffer(nil, adapter)
        local result = craft:deliver(bufferContext({
            [1] = slot("minecraft:chest", 2),
            [2] = slot("minecraft:chest", 2),
        }), "minecraft:chest", 4, "pickup")
        T.equal(result.state, "DONE")
        T.equal(result.moved, 4)
        T.equal(#adapter.pushes, 2)
    end},
    {name="a full Pickup blocks delivery for explicit retry",run=function()
        local craft = buffer(nil, fakeAdapter("full"))
        local result = craft:deliver(bufferContext({[1] = slot("minecraft:chest", 1)}),
            "minecraft:chest", 1, "pickup")
        T.equal(result.state, "BLOCKED")
        T.equal(result.reason.code, "PICKUP_FULL")
    end},
    {name="a failed push blocks rather than reporting success",run=function()
        local craft = buffer(nil, fakeAdapter("fail"))
        local result = craft:deliver(bufferContext({[1] = slot("minecraft:chest", 1)}),
            "minecraft:chest", 1, "pickup")
        T.equal(result.state, "BLOCKED")
        T.equal(result.reason.code, "DELIVERY_FAILED")
    end},
    {name="delivery to storage keeps everything except the result",run=function()
        local imports = fakeImports({{state="TRANSFERRING"}})
        local craft = buffer(imports)
        craft:deliver(bufferContext({
            [1] = slot("minecraft:chest", 1),
            [2] = slot("minecraft:oak_planks", 4),
        }), "minecraft:chest", 1, "storage")
        local offered = imports.seen[1]
        T.truthy(offered.slots[1], "the result is what goes to storage")
        T.equal(offered.slots[2], nil, "leftovers are not swept up by delivery")
    end},

    -- Turtle link
    {name="the turtle rednet ID is resolved from the bound peripheral",run=function()
        local calls = {}
        local link = TurtleLink.new({
            rednet = {send=function(id, message) calls[#calls+1]={id=id,message=message}; return true end,
                receive=function() return nil end, isOpen=function() return true end,
                open=function() return true end},
            peripheral = {call=function(name, method) calls.resolved={name,method}; return 7 end,
                getType=function() return "modem" end},
            name = "turtle_2"})
        T.equal(link:send({op="craft", job="craft-1"}), true)
        T.equal(calls[1].id, 7, "sent to the resolved computer ID, not the peripheral name")
        T.arrayEqual(calls.resolved, {"turtle_2", "getID"})
    end},
    {name="an unreachable turtle reports failure and forgets its cached ID",run=function()
        local link = TurtleLink.new({
            rednet = {send=function() return true end, receive=function() return nil end,
                isOpen=function() return true end, open=function() return true end},
            peripheral = {call=function() error("no such peripheral") end,
                getType=function() return "modem" end},
            name = "turtle_2"})
        local ok, reason = link:send({op="craft", job="craft-1"})
        T.equal(ok, nil)
        T.contains(reason, "not reachable")
        T.equal(link.cachedId, nil, "a rebuilt turtle must not be retried at a dead ID")
    end},
    {name="a reply handed in by the event loop is returned by poll",run=function()
        local link = workingLink()
        T.equal(link:poll(), nil, "nothing is pending yet")
        link:send({op="craft", job="craft-1"})
        T.equal(link:poll(), nil, "no reply has arrived")
        T.equal(link:deliver(7, {ok=true, job="craft-1"}, "invos-craft"), true)
        local reply = link:poll()
        T.equal(reply.ok, true)
        T.equal(link:poll(), nil, "a reply is consumed once")
    end},
    {name="a reply that arrives between polls is not lost",run=function()
        -- This is the failure that stalled a live craft: the reply landed while the work
        -- loop was busy elsewhere, so rednet.receive never saw it and the job timed out.
        local link = workingLink()
        link:send({op="craft", job="craft-1"})
        for _ = 1, 5 do link:poll() end
        link:deliver(7, {ok=true}, "invos-craft")
        for _ = 1, 5 do
            local reply = link:poll()
            if reply then T.equal(reply.ok, true); return end
        end
        T.truthy(false, "the reply must survive until it is polled")
    end},
    {name="a message on another protocol is ignored",run=function()
        local link = workingLink()
        link:send({op="craft", job="craft-1"})
        T.equal(link:deliver(7, {ok=true}, "some-other-protocol"), false)
        T.equal(link:poll(), nil)
    end},
    {name="a message from another computer is ignored",run=function()
        local link = workingLink()
        link:send({op="craft", job="craft-1"})
        T.equal(link:deliver(99, {ok=true}, "invos-craft"), false)
        T.equal(link:poll(), nil)
    end},
    {name="a new job never sees a stale reply",run=function()
        local link = workingLink()
        link:send({op="craft", job="craft-1"})
        link:deliver(7, {ok=true, job="craft-1"}, "invos-craft")
        link:send({op="craft", job="craft-2"})
        T.equal(link:poll(), nil, "the previous job's reply must not settle this one")
    end},

    -- Turtle deployment manifest
    {name="the turtle manifest carries only the turtle's own runtime",run=function()
        local seen = {}
        for _, path in ipairs(TurtleManifest.files) do
            T.equal(path:match("%.lua$") ~= nil, true, path)
            T.equal(path:find("storage", 1, true), nil, "controller files never reach the turtle")
            T.equal(path:find("tests", 1, true), nil, path)
            seen[path] = true
        end
        T.equal(seen["startup.lua"], true)
        T.equal(seen["crafter/executor.lua"], true)
    end},
    {name="the turtle manifest refuses controller and development paths",run=function()
        for _, path in ipairs({"storage/main.lua", "storage/core/craft_planner.lua",
            "README.md", "tools/recipe_import.py", "crafter/../storage/main.lua"}) do
            T.equal(TurtleManifest.allowed(path), false, path)
        end
    end},
    {name="sending opens a modem first, because nothing else does",run=function()
        -- The controller has no other reason to use rednet, so if the link does not open
        -- a modem, every craft reports the turtle unreachable while it sits listening.
        local opened, sent = {}, {}
        local link = TurtleLink.new({
            rednet = {
                isOpen = function() return false end,
                open = function(side) opened[#opened+1] = side; return true end,
                send = function(id, message) sent[#sent+1] = id; return true end,
                receive = function() return nil end},
            peripheral = {call = function() return 7 end,
                getType = function(side) return side == "bottom" and "modem" or nil end},
            name = "turtle_2"})
        T.equal(link:send({op="craft", job="craft-1"}), true)
        T.arrayEqual(opened, {"bottom"}, "the modem side is found and opened")
        T.equal(sent[1], 7)
    end},
    {name="an already open modem is not reopened",run=function()
        local opened = {}
        local link = TurtleLink.new({
            rednet = {
                isOpen = function() return true end,
                open = function(side) opened[#opened+1] = side; return true end,
                send = function() return true end, receive = function() return nil end},
            peripheral = {call = function() return 7 end,
                getType = function() return "modem" end},
            name = "turtle_2"})
        link:send({op="craft", job="craft-1"})
        T.equal(#opened, 0)
    end},
    {name="a modem on another side is still found",run=function()
        local opened = {}
        local link = TurtleLink.new({
            rednet = {
                isOpen = function() return false end,
                open = function(side) opened[#opened+1] = side; return true end,
                send = function() return true end, receive = function() return nil end},
            peripheral = {call = function() return 7 end,
                getType = function(side) return side == "left" and "modem" or nil end},
            name = "turtle_2"})
        T.equal(link:send({op="craft", job="craft-1"}), true)
        T.arrayEqual(opened, {"left"})
    end},
    {name="no modem at all reports why rather than blaming the turtle",run=function()
        local link = TurtleLink.new({
            rednet = {isOpen = function() return false end,
                open = function() return true end,
                send = function() return true end, receive = function() return nil end},
            peripheral = {call = function() return 7 end,
                getType = function() return nil end},
            name = "turtle_2"})
        local ok, reason = link:send({op="craft", job="craft-1"})
        T.equal(ok, nil)
        T.contains(reason, "no modem is open")
    end},

    {name="a drain in flight is reported so nothing else can transfer",run=function()
        -- The coordinator grants exclusive use of the transfer machinery based on this.
        -- Reporting IDLE while the importer is mid-transfer lets the Drop-off importer
        -- run alongside it, two transfers sharing one journal, each measuring aggregate
        -- storage deltas the other is changing.
        local imports = {state = "TRANSFERRING"}
        function imports:status() return {state = self.state} end
        function imports:tick() return {state = self.state} end
        local craft = CraftBuffer.new({imports = imports, adapter = fakeAdapter()})
        T.equal(craft:status().state, "TRANSFERRING")
        imports.state = "VERIFYING"
        T.equal(craft:status().state, "VERIFYING")
        imports.state = "IDLE"
        T.equal(craft:status().state, "IDLE")
    end},
    {name="a working drain reports the importer state that produced it",run=function()
        -- The caller decides whether it is safe to wait on a rescan from this. A rescan
        -- gate raised while the importer is TRANSFERRING waits on a scan that the same
        -- state forbids, so a drain that hides which state it is in deadlocks the job.
        local craft = buffer(fakeImports({{state="TRANSFERRING"}}))
        local moving = craft:drain(bufferContext({[1] = slot("minecraft:cobblestone", 64)}), {})
        T.equal(moving.state, "WORKING")
        T.equal(moving.inner, "TRANSFERRING")

        local settling = buffer(fakeImports({{state="COMPLETE"}}))
            :drain(bufferContext({[1] = slot("minecraft:cobblestone", 64)}), {})
        T.equal(settling.state, "WORKING")
        T.equal(settling.inner, "COMPLETE", "a settled pass is where a rescan belongs")
    end},
    {name="a drain lets its importer finish verifying even with nothing left to move",run=function()
        -- The last pass physically moves the items and only then goes to VERIFYING, so the
        -- rescan that follows makes the buffer look empty. Reporting DONE there strands the
        -- importer mid-verification: its journal is never retired -- and the journal belongs
        -- to the transfer service every other service shares -- while status() reports
        -- VERIFYING forever, which tells the coordinator a transfer is permanently in flight
        -- and stops every service, not just crafting, from ever planning again.
        local imports = {state="VERIFYING", ticks=0}
        function imports:status() return {state=self.state} end
        function imports:tick()
            self.ticks = self.ticks + 1
            self.state = "COMPLETE"
            return {state=self.state}
        end
        local craft = CraftBuffer.new({imports=imports, adapter=fakeAdapter()})
        local settling = craft:drain(bufferContext({}), {})
        T.equal(settling.state, "WORKING", "an unsettled importer is not a finished drain")
        T.equal(imports.ticks, 1, "it must be ticked so its journal is retired")
        T.equal(craft:drain(bufferContext({}), {}).state, "DONE", "and DONE once it settles")
    end},
    {name="an empty buffer with an idle importer is done immediately",run=function()
        local imports = {ticks=0}
        function imports:status() return {state="IDLE"} end
        function imports:tick() self.ticks = self.ticks + 1; return {state="IDLE"} end
        local craft = CraftBuffer.new({imports=imports, adapter=fakeAdapter()})
        T.equal(craft:drain(bufferContext({}), {}).state, "DONE")
        T.equal(imports.ticks, 0, "nothing to settle and nothing to move")
    end},
    {name="a buffer with no importer status reports idle rather than erroring",run=function()
        local craft = CraftBuffer.new({imports = {tick = function() end},
            adapter = fakeAdapter()})
        T.equal(craft:status().state, "IDLE")
    end},

}
