local Reconciliation = require("core.reconciliation")
local Transfer = require("core.transfer")
local T = require("tests.mock_cc")

local stone = "minecraft:stone\0-"

local function storage(count)
    return {{node_id="store", peripheral_name="store", health="READY",
        slots={[1]={identity_key=stone, count=count or 30}}}}
end

-- Three planner steps out of one Drop-off slot: top up two partial stacks, then a fresh slot.
local function importSteps()
    return {
        {source_name="drop", source_slot=1, source_epoch=1, source_pre_count=70,
            destination_name="store", destination_slot=4, destination_epoch=1,
            destination_pre_count=60, identity_key=stone, limit=4},
        {source_name="drop", source_slot=1, source_epoch=1, source_pre_count=66,
            destination_name="store", destination_slot=9, destination_epoch=1,
            destination_pre_count=63, identity_key=stone, limit=1},
        {source_name="drop", source_slot=1, source_epoch=1, source_pre_count=65,
            destination_name="store", destination_slot=12, destination_epoch=1,
            destination_pre_count=0, identity_key=stone, limit=65},
    }
end

local function harness(options)
    options = options or {}
    local pushes, inspects, writes = {}, {}, {}
    local adapter = {
        inspect = function(_, name, slot)
            inspects[#inspects + 1] = name .. ":" .. tostring(slot)
            if name == "drop" then return true, {identity_key=stone, count=70} end
            local pre = ({[4]=60, [9]=63, [12]=0})[slot]
            if pre == 0 then return true, {identity_key=nil, count=0} end
            return true, {identity_key=stone, count=pre}
        end,
        push = function(_, _, _, _, limit, toSlot)
            pushes[#pushes + 1] = {limit=limit, slot=toSlot}
            if options.pushFails and #pushes == options.pushFails then return nil, "cable cut" end
            return true, limit
        end,
    }
    local store = {write=function(_, _, value)
        writes[#writes + 1] = value.batch and value.batch.phase or value.step.phase
        return true
    end, delete=function() return true end}
    local transfer = Transfer.new({store=store, adapter=adapter, clock=function() return 7 end,
        reconciliation=Reconciliation})
    return transfer, pushes, inspects, writes
end

local operation = {id="import-5", kind="import", state="TRANSFERRING", moved=0}

return {
    {name="a batch issues every planned push under one journal", run=function()
        local transfer, pushes, _, writes = harness()
        local result = transfer:executeBatch(operation, importSteps(), storage(123))
        T.equal(result.state, "VERIFYING")
        T.equal(#pushes, 3, "every planned step is issued")
        T.arrayEqual({pushes[1].slot, pushes[2].slot, pushes[3].slot}, {4, 9, 12})
        T.arrayEqual({pushes[1].limit, pushes[2].limit, pushes[3].limit}, {4, 1, 65})
        T.arrayEqual(writes, {"INTENT", "CALLING", "CALLED"},
            "journal cost is per batch, not per step")
        T.equal(result.moved, 70, "reported movement is the batch total")
    end},

    {name="one baseline covers the whole batch", run=function()
        local transfer = harness()
        local snapshots = storage(123)
        snapshots[#snapshots + 1] = {node_id="unused", peripheral_name="store_unused",
            health="ERROR", slots={}}
        local result = transfer:executeBatch(operation, importSteps(), snapshots)
        T.equal(result.journal.schema, 3)
        T.equal(result.journal.batch.storage_pre_count, 123,
            "a single fresh baseline is captured before any push")
        T.equal(result.journal.batch.identity_key, stone)
        T.equal(#result.journal.batch.steps, 3)
        T.equal(result.journal.batch.limit_total, 70)
        T.arrayEqual(result.journal.batch.storage_node_ids, {"store"})
    end},

    {name="every destination is preflighted before any push", run=function()
        local transfer, pushes, inspects = harness()
        transfer:executeBatch(operation, importSteps(), storage(123))
        T.equal(#pushes, 3)
        T.arrayEqual(inspects, {"drop:1", "store:4", "store:9", "store:12"},
            "source once, then each distinct destination, all before pushing")
    end},

    {name="a mid-batch call failure stops and still reconciles", run=function()
        local transfer, pushes = harness({pushFails=2})
        local result = transfer:executeBatch(operation, importSteps(), storage(123))
        T.equal(result.state, "VERIFYING", "an ambiguous batch still measures storage truth")
        T.equal(#pushes, 2, "remaining steps are abandoned rather than replayed")
        T.truthy(result.reason, "the failure is reported")
        T.equal(result.reason.ambiguous, true)
    end},

    {name="batch verification measures the aggregate identity delta", run=function()
        local transfer = harness()
        local result = transfer:executeBatch(operation, importSteps(), storage(123))
        local verified = transfer:verify(result.journal, storage(193))
        T.equal(verified.state, "COMPLETE")
        T.equal(verified.moved, 70, "measured delta, not the reported total")
        T.equal(verified.reported_moved, 70)
    end},

    {name="a batch journal that never reached the call is discard safe", run=function()
        local transfer = harness()
        local result = transfer:executeBatch(operation, importSteps(), storage(123))
        local journal = result.journal
        journal.batch.phase = "INTENT"
        T.equal(transfer:recover(journal, storage(123)).state, "DISCARD_SAFE")
    end},

    {name="batch journals are validated", run=function()
        local transfer = harness()
        local journal = transfer:executeBatch(operation, importSteps(), storage(123)).journal
        T.truthy(Transfer.validateJournal(journal))
        local missingSteps = transfer:executeBatch(operation, importSteps(), storage(123)).journal
        missingSteps.batch.steps = {}
        T.equal(Transfer.validateJournal(missingSteps), nil)
        local badScope = transfer:executeBatch(operation, importSteps(), storage(123)).journal
        badScope.batch.storage_node_ids = {}
        T.equal(Transfer.validateJournal(badScope), nil)
    end},

    {name="schema 2 journals still validate and reconcile", run=function()
        local legacy = {schema=2, operation={id="import-1", kind="import",
            state="TRANSFERRING", moved=0},
            step={id="import-1:1", phase="CALLED", source_name="drop", source_slot=1,
                source_epoch=1, source_pre_count=5, destination_name="store",
                destination_slot=1, destination_epoch=1, destination_pre_count=0,
                identity_key=stone, limit=5, reported_moved=5, storage_pre_count=30,
                storage_node_ids={"store"}}, updated_at=1}
        T.truthy(Transfer.validateJournal(legacy), "an in-flight upgrade must not orphan a journal")
        local transfer = harness()
        local verified = transfer:verify(legacy, storage(35))
        T.equal(verified.state, "COMPLETE")
        T.equal(verified.moved, 5)
    end},
}
