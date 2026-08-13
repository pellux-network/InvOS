local Reconciliation = require("core.reconciliation")
local Transfer = require("core.transfer")
local T = require("tests.mock_cc")

local stone = "minecraft:stone\0-"
local pearl = "minecraft:ender_pearl\0-"

local function storage(stoneCount, pearlCount)
    return {{node_id="store", health="READY", slots={
        [1]={identity_key=stone, count=stoneCount or 20},
        [2]={identity_key=pearl, count=pearlCount or 10}}}}
end

-- Two Drop-off slots holding different item types, each planned into its own storage slot.
local function mixedSteps()
    return {
        {identity_key=stone, source_name="drop", source_slot=3, source_epoch=1,
            source_pre_count=64, destination_name="store", destination_slot=41,
            destination_epoch=1, destination_pre_count=0, limit=64},
        {identity_key=pearl, source_name="drop", source_slot=7, source_epoch=1,
            source_pre_count=16, destination_name="store", destination_slot=52,
            destination_epoch=1, destination_pre_count=0, limit=16},
    }
end

local function harness(options)
    options = options or {}
    local pushes, inspects, writes = {}, {}, {}
    local sourceCounts = options.sourceCounts or {[3]=64, [7]=16}
    local adapter = {
        inspect = function(_, name, slot)
            inspects[#inspects + 1] = name .. ":" .. tostring(slot)
            if name == "drop" then
                local identity = slot == 3 and stone or pearl
                return true, {identity_key=identity, count=sourceCounts[slot]}
            end
            if options.destinationOccupied then
                return true, {identity_key=stone, count=5}
            end
            return true, {identity_key=nil, count=0}
        end,
        push = function(_, _, _, _, limit, toSlot)
            pushes[#pushes + 1] = {limit=limit, slot=toSlot}
            if options.pushFails and #pushes == options.pushFails then return nil, "cable cut" end
            return true, limit
        end,
    }
    local store = {write=function(_, _, value)
        writes[#writes + 1] = (value.batch and value.batch.phase) or value.step.phase
        return true
    end, delete=function() return true end}
    return Transfer.new({store=store, adapter=adapter, clock=function() return 7 end,
        reconciliation=Reconciliation}), pushes, inspects, writes
end

local operation = {id="import-9", kind="import", state="TRANSFERRING", moved=0}

return {
    {name="two identities move under one baseline and one journal", run=function()
        local transfer, pushes, _, writes = harness()
        local result = transfer:executeMultiBatch(operation, mixedSteps(), storage())
        T.equal(result.state, "VERIFYING")
        T.equal(#pushes, 2)
        T.arrayEqual({pushes[1].slot, pushes[2].slot}, {41, 52})
        T.arrayEqual(writes, {"INTENT", "CALLING", "CALLED"},
            "journal cost is per batch, not per identity")
        T.equal(result.journal.schema, 4)
        T.equal(#result.journal.batch.identities, 2)
        T.equal(#result.journal.batch.steps, 2)
    end},

    {name="each identity records its own baseline", run=function()
        local transfer = harness()
        local journal = transfer:executeMultiBatch(operation, mixedSteps(), storage(20, 10)).journal
        local byKey = {}
        for _, entry in ipairs(journal.batch.identities) do byKey[entry.identity_key] = entry end
        T.equal(byKey[stone].storage_pre_count, 20)
        T.equal(byKey[pearl].storage_pre_count, 10)
        T.equal(byKey[stone].limit_total, 64)
        T.equal(byKey[pearl].limit_total, 16)
        T.equal(journal.batch.identities[1].identity_key < journal.batch.identities[2].identity_key,
            true, "identities are sorted for deterministic validation")
    end},

    {name="verification credits each identity from its own delta", run=function()
        local transfer = harness()
        local result = transfer:executeMultiBatch(operation, mixedSteps(), storage(20, 10))
        local verified = transfer:verify(result.journal, storage(84, 26))
        T.equal(verified.state, "COMPLETE")
        T.equal(verified.moved_by_identity[stone], 64)
        T.equal(verified.moved_by_identity[pearl], 16)
        T.equal(verified.moved, 80, "the scalar total is the sum across identities")
    end},

    {name="an untouched identity in the batch measures zero without failing", run=function()
        local transfer = harness()
        local result = transfer:executeMultiBatch(operation, mixedSteps(), storage(20, 10))
        local verified = transfer:verify(result.journal, storage(84, 10))
        T.equal(verified.state, "COMPLETE")
        T.equal(verified.moved_by_identity[stone], 64)
        T.equal(verified.moved_by_identity[pearl], 0)
        T.equal(verified.moved, 64)
    end},

    {name="one negative delta blocks the whole batch for review", run=function()
        local transfer = harness()
        local result = transfer:executeMultiBatch(operation, mixedSteps(), storage(20, 10))
        local verified = transfer:verify(result.journal, storage(84, 2))
        T.equal(verified.state, "WAITING")
        T.equal(verified.reason.code, "RECONCILE_DIRECTION")
        T.equal(verified.reason.ambiguous, true)
    end},

    {name="colliding destination slots are refused before any push", run=function()
        local transfer, pushes = harness()
        local steps = mixedSteps()
        steps[2].destination_slot = steps[1].destination_slot
        local result = transfer:executeMultiBatch(operation, steps, storage())
        T.equal(result.state, "FAILED")
        T.equal(result.reason.code, "DESTINATION_COLLISION")
        T.equal(#pushes, 0, "nothing may be issued once a collision is known")
    end},

    {name="every source and destination is preflighted before any push", run=function()
        local transfer, pushes, inspects = harness()
        transfer:executeMultiBatch(operation, mixedSteps(), storage())
        T.equal(#pushes, 2)
        T.arrayEqual(inspects, {"drop:3", "drop:7", "store:41", "store:52"})
    end},

    {name="a source holding less than its planned total is refused", run=function()
        local transfer, pushes = harness({sourceCounts={[3]=64, [7]=4}})
        local result = transfer:executeMultiBatch(operation, mixedSteps(), storage())
        T.equal(result.state, "FAILED")
        T.equal(result.reason.code, "SOURCE_CHANGED")
        T.equal(#pushes, 0)
    end},

    {name="a changed destination is refused, keeping strict import preflight", run=function()
        local transfer, pushes = harness({destinationOccupied=true})
        local result = transfer:executeMultiBatch(operation, mixedSteps(), storage())
        T.equal(result.state, "FAILED")
        T.equal(result.reason.code, "DESTINATION_CHANGED")
        T.equal(#pushes, 0)
    end},

    {name="an unknown call outcome stops the batch and still reconciles", run=function()
        local transfer, pushes, _, writes = harness({pushFails=2})
        local result = transfer:executeMultiBatch(operation, mixedSteps(), storage())
        T.equal(result.state, "VERIFYING", "storage totals still decide what moved")
        T.equal(#pushes, 2, "remaining steps are abandoned, never replayed")
        T.equal(result.reason.ambiguous, true)
        T.arrayEqual(writes, {"INTENT", "CALLING"},
            "an unproven call may not claim CALLED")
    end},

    {name="a multi identity journal that never called is discard safe", run=function()
        local transfer = harness()
        local journal = transfer:executeMultiBatch(operation, mixedSteps(), storage()).journal
        journal.batch.phase = "INTENT"
        T.equal(transfer:recover(journal, storage()).state, "DISCARD_SAFE")
    end},

    {name="schema 4 journals are validated", run=function()
        local transfer = harness()
        T.truthy(Transfer.validateJournal(
            transfer:executeMultiBatch(operation, mixedSteps(), storage()).journal))
        local noIdentities = transfer:executeMultiBatch(operation, mixedSteps(), storage()).journal
        noIdentities.batch.identities = {}
        T.equal(Transfer.validateJournal(noIdentities), nil)
        local unsorted = transfer:executeMultiBatch(operation, mixedSteps(), storage()).journal
        unsorted.batch.identities[1].identity_key, unsorted.batch.identities[2].identity_key =
            unsorted.batch.identities[2].identity_key, unsorted.batch.identities[1].identity_key
        T.equal(Transfer.validateJournal(unsorted), nil, "identity order must be deterministic")
        local orphanStep = transfer:executeMultiBatch(operation, mixedSteps(), storage()).journal
        orphanStep.batch.steps[1].identity_key = "minecraft:dirt\0-"
        T.equal(Transfer.validateJournal(orphanStep), nil,
            "every step must belong to a recorded identity")
    end},

    {name="a single identity batch still works through the multi path", run=function()
        local transfer, pushes = harness()
        local steps = {mixedSteps()[1]}
        local result = transfer:executeMultiBatch(operation, steps, storage(20, 10))
        T.equal(result.state, "VERIFYING")
        T.equal(#pushes, 1)
        T.equal(#result.journal.batch.identities, 1)
        local verified = transfer:verify(result.journal, storage(84, 10))
        T.equal(verified.state, "COMPLETE")
        T.equal(verified.moved, 64)
    end},
}
