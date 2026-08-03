local Store = require("shared.store")
local Transfer = require("core.transfer")
local T = require("tests.mock_cc")

local stone = "minecraft:stone\0-"

local function tokenCodec()
    local values, nextId = {}, 0
    return {
        encode=function(value) nextId=nextId+1; local key="r"..nextId; values[key]=value; return key end,
        decode=function(key) return assert(values[key], "bad token") end,
    }
end

local function journal(phase, moved)
    return {
        schema=1,
        operation={ id="request-1", kind="request", state="TRANSFERRING", moved=0 },
        step={
            id="request-1:1", phase=phase, source_name="store_a", source_slot=4,
            source_epoch=10, source_pre_count=64, destination_name="pickup",
            identity_key=stone, limit=64, actual_moved=moved or 0,
        },
        updated_at=100,
    }
end

local function transfer()
    local calls = 0
    local inventory = {
        inspect=function() return true, {} end,
        push=function() calls=calls+1; return true, 64 end,
    }
    local store = Store.new(T.memoryFs(), tokenCodec(), "colossal/data")
    return Transfer.new({store=store,adapter=inventory,clock=function() return 200 end}),
        store, function() return calls end
end

return {
    { name = "prepared recovery returns to planning without moving items", run = function()
        local value, _, pushCalls = transfer()
        local resolution = value:recover(journal("PREPARED"), {})
        T.equal(resolution.state, "PLANNING")
        T.equal(resolution.replay_safe, true)
        T.equal(pushCalls(), 0)
    end },
    { name = "calling recovery is always failed and never replayed", run = function()
        local value, _, pushCalls = transfer()
        local resolution = value:recover(journal("CALLING"), {
            source={ identity_key=stone, count=57 },
        })
        T.equal(resolution.state, "FAILED")
        T.equal(resolution.reason.code, "AMBIGUOUS_IN_FLIGHT")
        T.equal(resolution.observed.source.count, 57)
        T.equal(pushCalls(), 0)
    end },
    { name = "called recovery verifies exact recorded source movement", run = function()
        local value, store, pushCalls = transfer()
        local resolution = value:recover(journal("CALLED", 17), {
            source={ identity_key=stone, count=47 },
        })
        T.equal(resolution.state, "COMPLETE")
        T.equal(resolution.moved, 17)
        T.equal(store:recover("journal", Transfer.validateJournal).step.phase, "VERIFIED")
        T.equal(pushCalls(), 0)
    end },
    { name = "called recovery rejects mismatched observed source counts", run = function()
        local value, _, pushCalls = transfer()
        local resolution = value:recover(journal("CALLED", 17), {
            source={ identity_key=stone, count=48 },
        })
        T.equal(resolution.state, "FAILED")
        T.equal(resolution.reason.code, "VERIFY_MISMATCH")
        T.equal(pushCalls(), 0)
    end },
    { name = "verified recovery completes without duplicate movement", run = function()
        local value, _, pushCalls = transfer()
        local resolution = value:recover(journal("VERIFIED", 17), {})
        T.equal(resolution.state, "COMPLETE")
        T.equal(resolution.moved, 17)
        T.equal(pushCalls(), 0)
    end },
}