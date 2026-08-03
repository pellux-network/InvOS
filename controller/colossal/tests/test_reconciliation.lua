local Reconciliation=require("core.reconciliation")
local T=require("tests.mock_cc")

local echo="the_vault:gem_echo\0-"
local wutodie="the_vault:gem_wutodie\0-"

local function snapshot(id,slots,health)
    return {node_id=id,peripheral_name="store_"..id,health=health or "READY",slots=slots or {}}
end

return {
    {name="retrieval measures pooled identity decrease across slot compaction",run=function()
        local baseline=assert(Reconciliation.capture(echo,{
            snapshot("a",{[7]={identity_key=echo,count=3}}),
            snapshot("b",{[2]={identity_key=echo,count=4},[3]={identity_key=wutodie,count=29}}),
        }))
        T.equal(baseline.total,7)
        T.arrayEqual(baseline.node_ids,{"a","b"})
        local result=Reconciliation.measure("request",baseline,{
            snapshot("a",{[7]={identity_key=wutodie,count=29}}),
            snapshot("b",{[2]={identity_key=echo,count=4}}),
        })
        T.equal(result.state,"READY")
        T.equal(result.before_total,7)
        T.equal(result.after_total,4)
        T.equal(result.moved,3)
    end},
    {name="import measures aggregate storage increase",run=function()
        local baseline=assert(Reconciliation.capture(echo,{
            snapshot("a",{[1]={identity_key=echo,count=4}}),
        }))
        local result=Reconciliation.measure("import",baseline,{
            snapshot("a",{[8]={identity_key=echo,count=9}}),
        })
        T.equal(result.state,"READY")
        T.equal(result.moved,5)
    end},
    {name="baseline capture rejects an incomplete configured storage scope",run=function()
        local baseline,cause=Reconciliation.capture(echo,{
            snapshot("a",{[1]={identity_key=echo,count=3}}),
            snapshot("b",{},"ERROR"),
        })
        T.equal(baseline,nil);T.equal(cause.code,"STORAGE_SCOPE_INCOMPLETE")
        T.arrayEqual(cause.rescan,{"a","b"})
    end},
    {name="missing baseline node postpones rather than inventing movement",run=function()
        local baseline={identity_key=echo,total=7,node_ids={"a","b"}}
        local result=Reconciliation.measure("request",baseline,{
            snapshot("a",{}),
        })
        T.equal(result.state,"WAITING")
        T.equal(result.reason.code,"STORAGE_SCOPE_INCOMPLETE")
        T.arrayEqual(result.rescan,{"a","b"})
    end},
    {name="aggregate reconciliation keeps exact NBT identities separate",run=function()
        local healing="minecraft:potion\0healing"
        local strength="minecraft:potion\0strength"
        local baseline=assert(Reconciliation.capture(healing,{
            snapshot("a",{[1]={identity_key=healing,count=5},[2]={identity_key=strength,count=12}}),
        }))
        T.equal(baseline.total,5)
        local result=Reconciliation.measure("request",baseline,{
            snapshot("a",{[1]={identity_key=strength,count=12}}),
        })
        T.equal(result.moved,5)
    end},
}
