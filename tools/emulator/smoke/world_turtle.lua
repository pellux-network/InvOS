-- The emulated turtle's world: everything a real turtle's body does, performed on
-- computer 0 where the chests actually live.
--
-- CraftOS-PC cannot emulate a turtle, and its peripherals do not cross computers:
-- computer 1 can talk rednet to computer 0 but cannot wrap a single one of its
-- chests. So the turtle firmware runs for real on computer 1 with an injected
-- `turtle` global (smoke/turtle_api.lua) that forwards every call here, and this
-- module -- running beside the controller under parallel -- owns the items.
--
-- Movement is real pushItems/pullItems between emulated chests, so the emulator
-- enforces conservation, slot counts and stack limits rather than this file
-- booking items by hand. Crafting is the one exception, because crafting really
-- does destroy and create: ingredients are pushed into a void chest and the
-- output is inserted with setItem.
--
-- Never deployed, and nothing under controller/ or turtle/ may require it.

local Oracle = dofile("/craft_oracle.lua")

local WorldTurtle = {}
WorldTurtle.__index = WorldTurtle

local PROTOCOL = "invos-emu-world"
local SLOT_COUNT = 16

function WorldTurtle.new(spec, world)
    assert(type(spec) == "table", "a turtle world spec is required")
    return setmetatable({
        buffer = assert(spec.buffer, "the craft buffer's peripheral name is required"),
        inventory = assert(spec.inventory, "the turtle inventory's name is required"),
        void = assert(spec.void, "the void inventory's name is required"),
        -- The generated pack by default, so any modded item the controller can
        -- plan is an item the world can actually craft. An explicit table in the
        -- spec overrides it, which is how a scenario makes the world disagree.
        oracle = Oracle.forSpec(spec.recipes, spec.pack_dir),
        world = world,
        selected = 1,
    }, WorldTurtle)
end

function WorldTurtle:_list(name)
    return peripheral.call(name, "list") or {}
end

function WorldTurtle:_stackLimit(id)
    if self.world and self.world.stackLimitFor then return self.world.stackLimitFor(id) end
    return 64
end

function WorldTurtle:_displayName(id)
    if self.world and self.world.displayNameFor then return self.world.displayNameFor(id) end
    return id
end

local function validSlot(slot)
    return type(slot) == "number" and slot >= 1 and slot <= SLOT_COUNT and slot % 1 == 0
end

function WorldTurtle:select(slot)
    if not validSlot(slot) then return false end
    self.selected = slot
    return true
end

function WorldTurtle:count(slot)
    slot = slot or self.selected
    if not validSlot(slot) then return 0 end
    local item = self:_list(self.inventory)[slot]
    return item and item.count or 0
end

function WorldTurtle:detail(slot)
    slot = slot or self.selected
    if not validSlot(slot) then return nil end
    return peripheral.call(self.inventory, "getItemDetail", slot)
end

-- suckDown always takes the buffer's LOWEST occupied slot. The controller's
-- staging depends on that being true and on nothing else establishing an order:
-- the buffer is filled by one withdrawal per ingredient and those land wherever
-- there is room, so a harness that picked a convenient slot instead would hide
-- the very ordering bug the executor was rewritten to survive.
function WorldTurtle:suckDown()
    local contents = self:_list(self.buffer)
    local lowest
    for slot in pairs(contents) do
        if not lowest or slot < lowest then lowest = slot end
    end
    if not lowest then return false end

    -- Into the selected slot first, as a real turtle does, then into whatever
    -- else can take it. A slot holding a different item accepts nothing, which
    -- the emulator enforces by moving zero.
    local moved = peripheral.call(self.inventory, "pullItems",
        self.buffer, lowest, nil, self.selected) or 0
    if moved > 0 then return true end
    for slot = 1, SLOT_COUNT do
        if slot ~= self.selected then
            moved = peripheral.call(self.inventory, "pullItems",
                self.buffer, lowest, nil, slot) or 0
            if moved > 0 then return true end
        end
    end
    return false
end

-- Drop the selected slot into the buffer, as a real turtle's dropDown does:
-- spilling across as many buffer slots as it takes.
--
-- The spilling itself lives in World.fillFirstAvailableSlot, which makes a
-- slotless pushItems behave the way CC:Tweaked's does, because the controller
-- depends on that too. Before it existed the turtle could only ever drop its
-- *first* stack of output: a craft yielding two stacks left half of it held, the
-- controller saw a shortfall it then tried to withdraw from storage, and the job
-- waited forever on a withdrawal that could never complete.
function WorldTurtle:dropDown(count)
    local moved = peripheral.call(self.inventory, "pushItems",
        self.buffer, self.selected, count) or 0
    return moved > 0
end

-- A push to the inventory's own name, which CraftOS-PC supports and which is what
-- a turtle moving a stack between two of its own slots amounts to.
function WorldTurtle:transferTo(slot, count)
    if not validSlot(slot) then return false end
    local moved = peripheral.call(self.inventory, "pushItems",
        self.inventory, self.selected, count, slot) or 0
    return moved > 0
end

-- Insert `total` of `id` the way a crafting result appears: into the selected slot
-- if it will take it, then into any slot that will. setItem ADDS to an occupied
-- slot rather than replacing it, respects the stack limit, and refuses a different
-- item by inserting nothing, so this needs no bookkeeping of its own.
function WorldTurtle:_produce(id, total)
    local limit = self:_stackLimit(id)
    local remaining = total
    local order = {self.selected}
    for slot = 1, SLOT_COUNT do
        if slot ~= self.selected then order[#order + 1] = slot end
    end
    for _, slot in ipairs(order) do
        if remaining <= 0 then break end
        local inserted = peripheral.call(self.inventory, "setItem", slot, {
            name = id,
            count = math.min(remaining, limit),
            displayName = self:_displayName(id),
            maxCount = limit,
        }) or 0
        remaining = remaining - inserted
    end
    return total - remaining
end

function WorldTurtle:craft(limit)
    local contents = self:_list(self.inventory)
    local grid, runs = {}, limit or 64
    local occupied = false
    for position, slot in ipairs(Oracle.GRID_SLOTS) do
        local item = contents[slot]
        if item then
            grid[position] = item.name
            occupied = true
            if item.count < runs then runs = item.count end
        end
    end
    if not occupied then return false, "the crafting grid is empty" end

    local recipe = self.oracle:match(grid)
    if not recipe then return false, "no recipe matches the grid" end
    if runs < 1 then return false, "not enough of an ingredient for one craft" end

    -- Consume by pushing into the void: setItem cannot clear or decrement a slot,
    -- so a sink is the only way to make items leave without a real destination.
    -- This relies on a slotless push spilling across slots (see
    -- World.fillFirstAvailableSlot): a cell holding a full stack fills a void slot,
    -- and without spilling the next cell's push moved nothing -- failing the craft
    -- with the earlier cells already destroyed, which lost items outright.
    for position, slot in ipairs(Oracle.GRID_SLOTS) do
        if grid[position] then
            local moved = peripheral.call(self.inventory, "pushItems",
                self.void, slot, runs) or 0
            if moved < runs then
                return false, "the emulated void is full; this run was too large"
            end
        end
    end

    local produced = self:_produce(recipe.output, recipe.count * runs)
    if produced <= 0 then
        return false, "the crafted output did not fit in the turtle"
    end
    return true
end

local HANDLERS = {
    ping = function() return true end,
    select = WorldTurtle.select,
    count = WorldTurtle.count,
    detail = WorldTurtle.detail,
    suckDown = WorldTurtle.suckDown,
    dropDown = WorldTurtle.dropDown,
    transferTo = WorldTurtle.transferTo,
    craft = WorldTurtle.craft,
}

--- Run one request. Returns whatever the handler returns.
function WorldTurtle:handle(request)
    if type(request) ~= "table" then return nil end
    local handler = HANDLERS[request.op]
    if not handler then return nil end
    local args = request.args or {}
    return handler(self, table.unpack(args, 1, request.n or args.n or #args))
end

--- The rednet loop. Never returns; run it under parallel beside the controller.
--
-- Every coroutine under parallel sees every event, so this consuming
-- rednet_message events on its own protocol cannot starve the controller's event
-- loop of the turtle's craft replies.
function WorldTurtle:serve()
    for _, side in ipairs({"back", "left", "right", "top", "bottom", "front"}) do
        if peripheral.getType(side) == "modem" then
            pcall(rednet.open, side)
            break
        end
    end
    while true do
        local sender, request = rednet.receive(PROTOCOL, 1)
        if sender and type(request) == "table" then
            local packed = table.pack(pcall(self.handle, self, request))
            local reply
            if packed[1] then
                reply = {seq = request.seq, ok = true,
                         value = {table.unpack(packed, 2, packed.n)}, n = packed.n - 1}
            else
                reply = {seq = request.seq, ok = false, error = tostring(packed[2])}
            end
            rednet.send(sender, reply, PROTOCOL)
        end
    end
end

return WorldTurtle
