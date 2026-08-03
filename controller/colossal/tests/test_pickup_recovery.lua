local Reconciliation=require("core.reconciliation")
local Transfer=require("core.transfer")
local T=require("tests.mock_cc")

return {{name="retrieval reconciliation never needs a Pickup observation",run=function()
    local echo="the_vault:gem_echo\0-"
    local journal={schema=2,operation={id="move",kind="request",state="VERIFYING",moved=0},
        step={id="move:1",phase="CALLED",source_name="storage",source_slot=6,
            source_epoch=10,source_pre_count=3,destination_name="pickup",identity_key=echo,
            limit=2,storage_pre_count=3,storage_node_ids={"storage"},reported_moved=1},updated_at=1}
    local transfer=Transfer.new({store={write=function() return true end},adapter={},
        clock=function() return 2 end,reconciliation=Reconciliation})
    local result=transfer:verify(journal,{{node_id="storage",health="READY",slots={}}})
    T.equal(result.state,"COMPLETE");T.equal(result.moved,3)
end}}