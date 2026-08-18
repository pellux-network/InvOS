local Reconciliation=require("core.reconciliation")
local Store=require("shared.store")
local Transfer=require("core.transfer")
local T=require("tests.mock_cc")

local echo="the_vault:gem_echo\0-"
local wutodie="the_vault:gem_wutodie\0-"

local function codec()
    local values,id={},0
    return {encode=function(value) id=id+1;local key="j"..id;values[key]=value;return key end,
        decode=function(key) return assert(values[key],"bad token") end}
end
local function snapshot(id,slots,health)
    return {node_id=id,peripheral_name="store_"..id,health=health or "READY",slots=slots or {}}
end
local function requestStep(limit)
    return {source_name="store_a",source_slot=7,source_epoch=10,source_pre_count=3,
        destination_name="pickup",identity_key=echo,limit=limit or 2}
end
local function importStep(limit)
    return {source_name="drop",source_slot=1,source_epoch=10,source_pre_count=5,
        destination_name="store_a",destination_slot=8,destination_epoch=20,
        destination_pre_count=0,identity_key=echo,limit=limit or 5}
end
local function operation(kind)
    return {id=(kind or "request").."-1",kind=kind or "request",state="TRANSFERRING",moved=0}
end
local function makeTransfer(reported)
    local fs=T.memoryFs();local store=Store.new(fs,codec(),"storage/data")
    local adapter={push_calls=0,observed={
        ["store_a:7"]={identity_key=echo,count=3,generation=10},
        ["drop:1"]={identity_key=echo,count=5,generation=10},
        ["store_a:8"]={identity_key=nil,count=0,generation=20}}}
    function adapter:inspect(name,slot) return true,self.observed[name..":"..slot] end
    function adapter:push() self.push_calls=self.push_calls+1;return true,reported end
    local transfer=Transfer.new({store=store,adapter=adapter,clock=function() return 100 end,
        reconciliation=Reconciliation})
    return transfer,store,adapter,fs
end

return {
    {name="compacted retrieval reconciles aggregate movement instead of reported count",run=function()
        local transfer,store,adapter=makeTransfer(1)
        local before={snapshot("a",{[7]={identity_key=echo,count=3}})}
        local called=transfer:execute(operation("request"),requestStep(2),before)
        T.equal(called.state,"VERIFYING");T.equal(adapter.push_calls,1)
        T.equal(called.journal.schema,2);T.equal(called.journal.step.phase,"CALLED")
        T.equal(called.journal.step.storage_pre_count,3)
        T.equal(called.journal.step.reported_moved,1)
        local complete=transfer:verify(called.journal,{
            snapshot("a",{[7]={identity_key=wutodie,count=29}})})
        T.equal(complete.state,"COMPLETE");T.equal(complete.moved,3)
        T.equal(complete.reported_moved,1)
        T.equal(store:recover("journal",Transfer.validateJournal).step.phase,"RECONCILED")
    end},
    {name="retrieval journals only the storage nodes used by its plan",run=function()
        local transfer,_,adapter=makeTransfer(2)
        local called=transfer:execute(operation("request"),requestStep(2),{
            snapshot("a",{[7]={identity_key=echo,count=3}}),snapshot("b",{},"ERROR")})
        T.equal(called.state,"VERIFYING")
        T.arrayEqual(called.journal.step.storage_node_ids,{"a"})
        T.arrayEqual(called.rescan,{"a"})
        local complete=transfer:verify(called.journal,{snapshot("a",{})})
        T.equal(complete.state,"COMPLETE");T.equal(adapter.push_calls,1)
    end},
    {name="import reconciles aggregate storage increase",run=function()
        local transfer,_,adapter=makeTransfer(2)
        local called=transfer:execute(operation("import"),importStep(5),{snapshot("a",{})})
        local complete=transfer:verify(called.journal,{
            snapshot("a",{[9]={identity_key=echo,count=5}})})
        T.equal(complete.state,"COMPLETE");T.equal(complete.moved,5)
        T.equal(complete.reported_moved,2);T.equal(adapter.push_calls,1)
    end},
    {name="changed source fails before journal or inventory mutation",run=function()
        local transfer,_,adapter=makeTransfer(2)
        adapter.observed["store_a:7"]={identity_key=wutodie,count=29}
        local result=transfer:execute(operation("request"),requestStep(2),{snapshot("a",{})})
        T.equal(result.state,"FAILED");T.equal(result.reason.code,"SOURCE_CHANGED")
        T.equal(adapter.push_calls,0)
    end},
    {name="missing touched storage mapping fails before journal or inventory mutation",run=function()
        local transfer,store,adapter=makeTransfer(2)
        local result=transfer:execute(operation("request"),requestStep(2),{
            snapshot("b",{})})
        T.equal(result.state,"FAILED")
        T.equal(result.reason.code,"STORAGE_SCOPE_MISSING")
        T.equal(adapter.push_calls,0)
        T.equal(store:recover("journal",Transfer.validateJournal),nil)
    end},
    {name="transfer exception leaves a calling journal for scan recovery",run=function()
        local transfer,store,adapter=makeTransfer(2)
        function adapter:push() self.push_calls=self.push_calls+1;error("network vanished") end
        local result=transfer:execute(operation("request"),requestStep(2),{
            snapshot("a",{[7]={identity_key=echo,count=3}})})
        T.equal(result.state,"VERIFYING");T.equal(result.reason.ambiguous,true)
        T.equal(result.journal.step.phase,"CALLING");T.equal(adapter.push_calls,1)
        T.equal(store:recover("journal",Transfer.validateJournal).step.phase,"CALLING")
        local complete=transfer:verify(result.journal,{snapshot("a",{})})
        T.equal(complete.state,"COMPLETE");T.equal(complete.moved,3)
        T.equal(adapter.push_calls,1)
    end},
    {name="called journal write failure remains verifying without another push",run=function()
        local failCalled=true;local adapter={push_calls=0}
        function adapter:inspect() return true,{identity_key=echo,count=3} end
        function adapter:push() self.push_calls=self.push_calls+1;return true,1 end
        local store={write=function(_,_,journal)
            if journal.step.phase=="CALLED" and failCalled then failCalled=false;return nil,"disk hiccup" end
            return true
        end,delete=function() return true end}
        local transfer=Transfer.new({store=store,adapter=adapter,clock=function() return 1 end,
            reconciliation=Reconciliation})
        local result=transfer:execute(operation("request"),requestStep(2),{
            snapshot("a",{[7]={identity_key=echo,count=3}})})
        T.equal(result.state,"VERIFYING");T.equal(result.reason.code,"JOURNAL_WRITE_AFTER_CALL")
        T.equal(result.journal.step.phase,"CALLING");T.equal(adapter.push_calls,1)
        local complete=transfer:verify(result.journal,{snapshot("a",{})})
        T.equal(complete.state,"COMPLETE");T.equal(complete.moved,3);T.equal(adapter.push_calls,1)
    end},
    {name="thrown called journal write remains verifying without another push",run=function()
        local adapter={push_calls=0}
        function adapter:inspect() return true,{identity_key=echo,count=3} end
        function adapter:push() self.push_calls=self.push_calls+1;return true,1 end
        local store={write=function(_,_,journal)
            if journal.step.phase=="CALLED" then error("disk detached") end
            return true
        end,delete=function() return true end}
        local transfer=Transfer.new({store=store,adapter=adapter,clock=function() return 1 end,
            reconciliation=Reconciliation})
        local result=transfer:execute(operation("request"),requestStep(2),{
            snapshot("a",{[7]={identity_key=echo,count=3}})})
        T.equal(result.state,"VERIFYING");T.equal(result.reason.code,"JOURNAL_WRITE_AFTER_CALL")
        T.equal(result.journal.step.phase,"CALLING");T.equal(adapter.push_calls,1)
    end},
    {name="opposite direction delta stays pending and cannot be retried",run=function()
        local transfer,_,adapter=makeTransfer(1)
        local called=transfer:execute(operation("request"),requestStep(2),{
            snapshot("a",{[7]={identity_key=echo,count=3}})})
        local waiting=transfer:verify(called.journal,{
            snapshot("a",{[7]={identity_key=echo,count=4}})})
        T.equal(waiting.state,"WAITING");T.equal(waiting.reason.code,"RECONCILE_DIRECTION")
        T.equal(adapter.push_calls,1)
    end},
    {name="reconciled journal write failure remains pending without another push",run=function()
        local adapter={push_calls=0}
        function adapter:inspect() return true,{identity_key=echo,count=3} end
        function adapter:push() self.push_calls=self.push_calls+1;return true,2 end
        local store={write=function(_,_,journal)
            if journal.step.phase=="RECONCILED" then return nil,"disk full" end
            return true
        end,delete=function() return true end}
        local transfer=Transfer.new({store=store,adapter=adapter,clock=function() return 1 end,
            reconciliation=Reconciliation})
        local called=transfer:execute(operation("request"),requestStep(2),{
            snapshot("a",{[7]={identity_key=echo,count=3}})})
        local waiting=transfer:verify(called.journal,{snapshot("a",{})})
        T.equal(waiting.state,"WAITING");T.equal(waiting.reason.code,"JOURNAL_WRITE")
        T.equal(adapter.push_calls,1)
    end},
    {name="retirement removes every journal variant",run=function()
        local transfer,store=makeTransfer(2)
        local called=transfer:execute(operation("request"),requestStep(2),{
            snapshot("a",{[7]={identity_key=echo,count=3}})})
        transfer:verify(called.journal,{snapshot("a",{[7]={identity_key=echo,count=1}})})
        T.truthy(transfer:retire())
        local value=store:recover("journal",Transfer.validateJournal)
        T.equal(value,nil)
    end},
}
