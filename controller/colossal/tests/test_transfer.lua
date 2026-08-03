local Store = require("shared.store")
local Transfer = require("core.transfer")
local T = require("tests.mock_cc")

local stone = "minecraft:stone\0-"

local function tokenCodec()
    local values, nextId = {}, 0
    return {
        encode = function(value) nextId=nextId+1; local key="j"..nextId; values[key]=value; return key end,
        decode = function(key) if not values[key] then error("bad journal token") end; return values[key] end,
    }
end

local function requestStep(limit)
    return {
        source_name="store_a", source_slot=4, source_epoch=10, source_pre_count=64,
        destination_name="pickup", identity_key=stone, limit=limit or 64,
    }
end

local function importStep(limit)
    local value=requestStep(limit)
    value.destination_slot=1
    value.destination_epoch=20
    value.destination_pre_count=0
    return value
end

local function operation(kind)
    return { id=(kind or "request").."-1", kind=kind or "request", state="TRANSFERRING", moved=0 }
end

local function adapter(moved)
    local value = { calls = { inspect=0, push=0 }, pushed = nil }
    value.observed = {
        ["store_a:4"] = { identity_key=stone, count=64, generation=10 },
        ["pickup:1"] = { identity_key=nil, count=0, generation=20 },
    }
    function value:inspect(name, slot)
        self.calls.inspect = self.calls.inspect + 1
        return true, self.observed[name .. ":" .. slot]
    end
    function value:push(source, destination, sourceSlot, transferLimit, destinationSlot)
        self.calls.push = self.calls.push + 1
        self.pushed = { source=source,destination=destination,source_slot=sourceSlot,
            limit=transferLimit,destination_slot=destinationSlot }
        return true, moved
    end
    return value
end

local function makeTransfer(moved, fsApi)
    fsApi = fsApi or T.memoryFs()
    local store = Store.new(fsApi, tokenCodec(), "colossal/data")
    local inventory = adapter(moved)
    return Transfer.new({ store=store, adapter=inventory, clock=function() return 1234 end }),
        store, inventory, fsApi
end

return {
    { name = "retrieval journals an unslotted push and rescans only storage", run = function()
        local transfer, store, inventory = makeTransfer(17)
        local result = transfer:execute(operation("request"), requestStep(64))
        T.equal(result.state, "VERIFYING")
        T.equal(result.moved, 17)
        T.equal(inventory.calls.inspect,1)
        T.equal(inventory.pushed.destination_slot,nil)
        T.arrayEqual(result.rescan,{"store_a"})
        local journal = store:recover("journal", Transfer.validateJournal)
        T.equal(journal.step.phase, "CALLED")
        T.equal(journal.step.actual_moved, 17)
        T.equal(journal.step.destination_slot,nil)
    end },
    { name = "retrieval verification needs only the observed source", run = function()
        local transfer, store = makeTransfer(17)
        local result = transfer:execute(operation("request"), requestStep(64))
        local verified = transfer:verify(result.journal, {
            source = { identity_key=stone, count=47 },
        })
        T.equal(verified.state, "COMPLETE")
        T.equal(verified.moved, 17)
        T.equal(store:recover("journal", Transfer.validateJournal).step.phase, "VERIFIED")
    end },
    { name = "import retains exact destination preflight and two-node rescans", run = function()
        local transfer, _, inventory = makeTransfer(17)
        local result=transfer:execute(operation("import"),importStep(64))
        T.equal(result.state,"VERIFYING")
        T.equal(inventory.calls.inspect,2)
        T.equal(inventory.pushed.destination_slot,1)
        T.arrayEqual(result.rescan,{"store_a","pickup"})
    end },
    { name = "journal activation failure prevents any inventory movement", run = function()
        local fsApi = T.memoryFs()
        fsApi.failMoveTo = "colossal/data/journal.lua"
        local transfer, _, inventory = makeTransfer(64, fsApi)
        local result = transfer:execute(operation("request"), requestStep(64))
        T.equal(result.state, "FAILED")
        T.equal(result.reason.code, "JOURNAL_WRITE")
        T.equal(inventory.calls.push, 0)
    end },
    { name = "changed source identity fails preflight before journaling movement", run = function()
        local transfer, _, inventory = makeTransfer(64)
        inventory.observed["store_a:4"] = {
            identity_key="minecraft:dirt\0-", count=64, generation=10,
        }
        local result = transfer:execute(operation("request"), requestStep(64))
        T.equal(result.state, "FAILED")
        T.equal(result.reason.code, "SOURCE_CHANGED")
        T.equal(inventory.calls.push, 0)
    end },
    { name = "changed import destination contents fail preflight", run = function()
        local transfer, _, inventory = makeTransfer(64)
        inventory.observed["pickup:1"] = { identity_key="minecraft:dirt\0-", count=3, generation=20 }
        local result = transfer:execute(operation("import"), importStep(64))
        T.equal(result.state, "FAILED")
        T.equal(result.reason.code, "DESTINATION_CHANGED")
        T.equal(inventory.calls.push, 0)
    end },
    { name = "retrieval transfer exception is ambiguous and rescans only storage", run = function()
        local transfer, store, inventory = makeTransfer(64)
        function inventory:push() self.calls.push=self.calls.push+1; error("network vanished") end
        local result = transfer:execute(operation("request"), requestStep(64))
        T.equal(result.state, "FAILED")
        T.equal(result.reason.code, "TRANSFER_EXCEPTION")
        T.equal(result.reason.ambiguous, true)
        T.arrayEqual(result.rescan, { "store_a" })
        T.equal(store:recover("journal", Transfer.validateJournal).step.phase, "CALLING")
    end },
    { name = "invalid returned quantities never become verified movement", run = function()
        for _, moved in ipairs({ -1, 65, "many" }) do
            local transfer = makeTransfer(moved)
            local result = transfer:execute(operation("request"), requestStep(64))
            T.equal(result.state, "FAILED")
            T.equal(result.reason.code, "INVALID_MOVED_COUNT")
            T.equal(result.reason.ambiguous, true)
        end
    end },
    { name = "zero is an authoritative short transfer", run = function()
        local transfer = makeTransfer(0)
        local result = transfer:execute(operation("request"), requestStep(64))
        T.equal(result.state, "VERIFYING")
        T.equal(result.moved, 0)
    end },
}