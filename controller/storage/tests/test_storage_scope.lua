local Scope = require("core.storage_scope")
local T = require("tests.mock_cc")

local function snapshot(id, name, health)
    return {
        node_id = id,
        peripheral_name = name,
        health = health or "READY",
        slots = {},
    }
end

return {
    {name="request scope contains only unique source storage nodes",run=function()
        local selected, ids = Scope.select("request", {
            {source_name="store_b", destination_name="pickup"},
            {source_name="store_a", destination_name="pickup"},
            {source_name="store_b", destination_name="pickup"},
        }, {
            snapshot("a", "store_a"),
            snapshot("b", "store_b"),
            snapshot("c", "store_c"),
        })
        T.arrayEqual(ids, {"a", "b"})
        T.equal(selected[1].node_id, "a")
        T.equal(selected[2].node_id, "b")
    end},
    {name="import scope contains only unique destination storage nodes",run=function()
        local selected, ids = Scope.select("import", {
            {source_name="drop", destination_name="store_c"},
            {source_name="drop", destination_name="store_a"},
        }, {
            snapshot("a", "store_a"),
            snapshot("b", "store_b"),
            snapshot("c", "store_c"),
        })
        T.arrayEqual(ids, {"a", "c"})
        T.equal(selected[1].peripheral_name, "store_a")
        T.equal(selected[2].peripheral_name, "store_c")
    end},
    {name="scope retains an unhealthy touched node for reconciliation to reject",run=function()
        local selected, ids = Scope.select("request", {
            {source_name="store_a", destination_name="pickup"},
        }, {snapshot("a", "store_a", "ERROR")})
        T.arrayEqual(ids, {"a"})
        T.equal(selected[1].health, "ERROR")
    end},
    {name="scope rejects a missing touched peripheral",run=function()
        local selected, ids, reason = Scope.select("request", {
            {source_name="missing", destination_name="pickup"},
        }, {snapshot("a", "store_a")})
        T.equal(selected, nil)
        T.equal(ids, nil)
        T.equal(reason.code, "STORAGE_SCOPE_MISSING")
        T.equal(reason.peripheral_name, "missing")
    end},
    {name="scope rejects duplicate storage peripheral mappings",run=function()
        local selected, ids, reason = Scope.select("import", {
            {source_name="drop", destination_name="store"},
        }, {snapshot("a", "store"), snapshot("b", "store")})
        T.equal(selected, nil)
        T.equal(ids, nil)
        T.equal(reason.code, "DUPLICATE_STORAGE_PERIPHERAL")
    end},
    {name="scope validates operation kind and step endpoints",run=function()
        local selected, _, reason = Scope.select("sideways", {}, {})
        T.equal(selected, nil)
        T.equal(reason.code, "INVALID_STORAGE_SCOPE")
        selected, _, reason = Scope.select("request", {{destination_name="pickup"}}, {})
        T.equal(selected, nil)
        T.equal(reason.code, "INVALID_STORAGE_SCOPE")
    end},
}
