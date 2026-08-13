local Reconciliation = require("core.reconciliation")
local T = require("tests.mock_cc")

local stone = "minecraft:stone\0-"
local pearl = "minecraft:ender_pearl\0-"
local coal  = "minecraft:coal\0-"

local function node(id, health, slots)
    return {node_id=id, health=health or "READY", slots=slots or {}}
end

local function slots(spec)
    local result = {}
    for slot, entry in pairs(spec) do
        result[slot] = {identity_key=entry[1], count=entry[2]}
    end
    return result
end

-- A snapshot whose slot table counts how many times it is walked, so the single-pass
-- requirement is a real assertion rather than a comment.
local function countingNode(id, spec)
    local walks = 0
    local raw = slots(spec)
    local proxy = {}
    for slot, item in pairs(raw) do proxy[slot] = item end
    return {node_id=id, health="READY", slots=proxy,
        walks=function() return walks end,
        mark=function() walks = walks + 1 end}
end

return {
    {name="captureMany totals every requested identity from one scan", run=function()
        local snapshots = {node("a", "READY", slots{[1]={stone,20},[2]={pearl,7},[3]={stone,5}}),
                           node("b", "READY", slots{[1]={pearl,3},[2]={coal,64}})}
        local baseline = Reconciliation.captureMany({stone, pearl}, snapshots)
        T.truthy(baseline, "a healthy scope must capture")
        T.equal(baseline.totals[stone], 25)
        T.equal(baseline.totals[pearl], 10)
        T.equal(baseline.totals[coal], nil, "only requested identities are captured")
        T.arrayEqual(baseline.node_ids, {"a", "b"})
    end},

    {name="captureMany reports an identity absent from storage as zero", run=function()
        local baseline = Reconciliation.captureMany({stone, pearl},
            {node("a", "READY", slots{[1]={stone,4}})})
        T.equal(baseline.totals[stone], 4)
        T.equal(baseline.totals[pearl], 0, "an unseen identity is zero, not nil")
    end},

    {name="captureMany waits for an incomplete storage scope", run=function()
        local baseline, reason = Reconciliation.captureMany({stone},
            {node("a", "READY", slots{[1]={stone,4}}), node("b", "OFFLINE")})
        T.equal(baseline, nil)
        T.equal(reason.code, "STORAGE_SCOPE_INCOMPLETE")
        T.equal(reason.retryable, true)
        T.arrayEqual(reason.rescan, {"a", "b"})
    end},

    {name="captureMany refuses duplicate nodes and malformed slots", run=function()
        local duplicate, duplicateReason = Reconciliation.captureMany({stone},
            {node("a", "READY", {}), node("a", "READY", {})})
        T.equal(duplicate, nil)
        T.equal(duplicateReason.code, "DUPLICATE_STORAGE_NODE")
        local malformed, malformedReason = Reconciliation.captureMany({stone},
            {node("a", "READY", {[1]={identity_key=stone}})})
        T.equal(malformed, nil)
        T.equal(malformedReason.code, "MALFORMED_STORAGE_SNAPSHOT")
    end},

    {name="captureMany rejects an empty or invalid identity set", run=function()
        local none, noneReason = Reconciliation.captureMany({}, {node("a")})
        T.equal(none, nil)
        T.equal(noneReason.code, "INVALID_IDENTITY")
        local bad, badReason = Reconciliation.captureMany({""}, {node("a")})
        T.equal(bad, nil)
        T.equal(badReason.code, "INVALID_IDENTITY")
    end},

    {name="captureMany cost does not scale with the number of identities", run=function()
        -- The point of a single pass is that adding identities is free. Reading each slot
        -- N extra times for N identities is exactly what must not happen, so compare the
        -- observed slot reads for one identity against six.
        local function readsFor(keys)
            local visits = 0
            local observed = {}
            for slot = 1, 30 do
                local item = {identity_key=(slot % 2 == 0) and stone or pearl, count=1}
                observed[slot] = setmetatable({}, {__index=function(_, key)
                    visits = visits + 1
                    return item[key]
                end})
            end
            local baseline = Reconciliation.captureMany(keys,
                {{node_id="a", health="READY", slots=observed}})
            T.truthy(baseline, "the counted scope must still capture")
            return visits
        end
        -- Extra identities are all absent from storage, so the set of matching slots is
        -- identical in both runs and any difference can only come from re-walking.
        local one = readsFor({stone})
        local six = readsFor({stone, "a\0-", "b\0-", "c\0-", "d\0-", "e\0-"})
        T.equal(six, one,
            "six identities read " .. six .. " slot fields against " .. one .. " for one")
    end},

    {name="measureMany credits each identity against its own baseline", run=function()
        local baseline = {node_ids={"a"}, totals={[stone]=20, [pearl]=10}}
        local after = {node("a", "READY", slots{[1]={stone,84},[2]={pearl,10}})}
        local result = Reconciliation.measureMany("import", baseline, after)
        T.equal(result.state, "READY")
        T.equal(result.moved[stone], 64)
        T.equal(result.moved[pearl], 0, "an untouched identity measures zero")
        T.equal(result.before[stone], 20)
        T.equal(result.after[stone], 84)
    end},

    {name="a delta in one identity cannot affect another", run=function()
        local baseline = {node_ids={"a"}, totals={[stone]=20, [pearl]=10}}
        local after = {node("a", "READY", slots{[1]={stone,20},[2]={pearl,74},[3]={coal,999}})}
        local result = Reconciliation.measureMany("import", baseline, after)
        T.equal(result.moved[stone], 0, "stone is untouched by pearl movement")
        T.equal(result.moved[pearl], 64)
    end},

    {name="measureMany honours transfer direction per kind", run=function()
        local baseline = {node_ids={"a"}, totals={[stone]=20}}
        local after = {node("a", "READY", slots{[1]={stone,8}})}
        T.equal(Reconciliation.measureMany("request", baseline, after).moved[stone], 12)
        T.equal(Reconciliation.measureMany("import", baseline, after).moved[stone], -12)
    end},

    {name="measureMany waits when a baseline node is not READY", run=function()
        local baseline = {node_ids={"a","b"}, totals={[stone]=20}}
        local result = Reconciliation.measureMany("import", baseline,
            {node("a", "READY", {}), node("b", "OFFLINE")})
        T.equal(result.state, "WAITING")
        T.equal(result.reason.code, "STORAGE_SCOPE_INCOMPLETE")
        T.arrayEqual(result.rescan, {"a","b"})
    end},

    {name="measureMany rejects an invalid baseline and direction", run=function()
        T.equal(Reconciliation.measureMany("sideways", {node_ids={"a"}, totals={[stone]=1}},
            {node("a")}).reason.code, "INVALID_DIRECTION")
        T.equal(Reconciliation.measureMany("import", {node_ids={}, totals={}},
            {node("a")}).reason.code, "INVALID_BASELINE")
        T.equal(Reconciliation.measureMany("import", {node_ids={"b","a"}, totals={[stone]=1}},
            {node("a")}).reason.code, "INVALID_BASELINE", "node ids must stay sorted")
    end},
}
