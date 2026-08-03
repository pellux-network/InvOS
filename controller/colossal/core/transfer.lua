local Transfer={}
Transfer.__index=Transfer

local legacyPhases={PREPARED=true,CALLING=true,CALLED=true,VERIFIED=true,FAILED=true}
local phases={INTENT=true,CALLING=true,CALLED=true,RECONCILED=true}

local function copy(value,seen)
    if type(value)~="table" then return value end
    seen=seen or {};if seen[value] then return seen[value] end
    local result={};seen[value]=result
    for key,item in pairs(value) do result[copy(key,seen)]=copy(item,seen) end
    return result
end
local function copyArray(values)
    local result={};for index,value in ipairs(values or {}) do result[index]=value end;return result
end
local function reason(code,message,ambiguous)
    return {code=code,message=tostring(message),ambiguous=ambiguous==true}
end
local function failed(code,message,ambiguous,rescan)
    return {state="FAILED",moved=0,reason=reason(code,message,ambiguous),rescan=copyArray(rescan)}
end
local function integer(value,minimum)
    return type(value)=="number" and value%1==0 and value>=(minimum or 0)
end
local function validateOperation(value)
    return type(value)=="table" and type(value.id)=="string" and
        (value.kind=="request" or value.kind=="import") and type(value.state)=="string"
end
local function validateLegacy(value)
    if not validateOperation(value.operation) then return nil,"journal operation is invalid" end
    local step=value.step
    if type(step)~="table" or type(step.id)~="string" or not legacyPhases[step.phase] then
        return nil,"journal step is invalid"
    end
    for _,field in ipairs({"source_name","destination_name","identity_key"}) do
        if type(step[field])~="string" then return nil,"journal step "..field.." is invalid" end
    end
    for _,field in ipairs({"source_slot","source_epoch","source_pre_count","limit","actual_moved"}) do
        if not integer(step[field]) then return nil,"journal step "..field.." is invalid" end
    end
    if value.operation.kind~="request" then
        for _,field in ipairs({"destination_slot","destination_epoch","destination_pre_count"}) do
            if not integer(step[field]) then return nil,"journal step "..field.." is invalid" end
        end
    end
    if type(value.updated_at)~="number" then return nil,"journal timestamp is invalid" end
    return true
end
local function validateScope(step)
    if not integer(step.storage_pre_count) or type(step.storage_node_ids)~="table" or
        #step.storage_node_ids<1 then return nil,"journal storage baseline is invalid" end
    local prior,seen=nil,{}
    for _,nodeId in ipairs(step.storage_node_ids) do
        if type(nodeId)~="string" or nodeId=="" or seen[nodeId] or
            (prior and nodeId<prior) then return nil,"journal storage scope is invalid" end
        seen[nodeId],prior=true,nodeId
    end
    return true
end
function Transfer.validateJournal(value)
    if type(value)~="table" then return nil,"journal is invalid" end
    if value.schema==1 then return validateLegacy(value) end
    if value.schema~=2 then return nil,"journal schema must be 1 or 2" end
    if not validateOperation(value.operation) then return nil,"journal operation is invalid" end
    local step=value.step
    if type(step)~="table" or type(step.id)~="string" or not phases[step.phase] then
        return nil,"journal step is invalid"
    end
    for _,field in ipairs({"source_name","destination_name","identity_key"}) do
        if type(step[field])~="string" then return nil,"journal step "..field.." is invalid" end
    end
    for _,field in ipairs({"source_slot","source_epoch","source_pre_count","limit"}) do
        if not integer(step[field]) then return nil,"journal step "..field.." is invalid" end
    end
    local scopeOk,scopeReason=validateScope(step);if not scopeOk then return nil,scopeReason end
    if value.operation.kind~="request" then
        for _,field in ipairs({"destination_slot","destination_epoch","destination_pre_count"}) do
            if not integer(step[field]) then return nil,"journal step "..field.." is invalid" end
        end
    end
    if step.reported_moved~=nil and not integer(step.reported_moved) then
        return nil,"journal reported movement is invalid"
    end
    if step.phase=="CALLED" and not integer(step.reported_moved) then
        return nil,"called journal requires reported movement"
    end
    if step.phase=="RECONCILED" and not integer(step.actual_moved) then
        return nil,"reconciled journal requires actual movement"
    end
    if type(value.updated_at)~="number" then return nil,"journal timestamp is invalid" end
    return true
end

function Transfer.new(deps)
    assert(type(deps)=="table","transfer dependencies are required")
    assert(type(deps.store)=="table","transfer store is required")
    assert(type(deps.adapter)=="table","inventory adapter is required")
    assert(type(deps.clock)=="function","transfer clock is required")
    assert(type(deps.reconciliation)=="table","transfer reconciliation is required")
    return setmetatable({store=deps.store,adapter=deps.adapter,clock=deps.clock,
        reconciliation=deps.reconciliation},Transfer)
end
function Transfer:_inspect(name,slot)
    if type(self.adapter.inspect)~="function" then return nil,"inventory adapter cannot inspect slots" end
    local callOk,ok,observed=pcall(self.adapter.inspect,self.adapter,name,slot)
    if not callOk then return nil,tostring(ok) end
    if not ok or type(observed)~="table" then return nil,tostring(observed) end
    return observed
end
function Transfer:_preflight(operation,step)
    local source,sourceReason=self:_inspect(step.source_name,step.source_slot)
    if not source then return nil,reason("SOURCE_UNAVAILABLE",sourceReason,false) end
    if source.identity_key~=step.identity_key or source.count~=step.source_pre_count or
        source.count<step.limit then
        return nil,reason("SOURCE_CHANGED","source no longer matches the planned snapshot",false)
    end
    if operation.kind=="request" then return true end
    local destination,destinationReason=self:_inspect(step.destination_name,step.destination_slot)
    if not destination then return nil,reason("DESTINATION_UNAVAILABLE",destinationReason,false) end
    local identityOk=step.destination_pre_count==0 and
        (destination.identity_key==nil or destination.count==0) or
        destination.identity_key==step.identity_key
    if not identityOk or destination.count~=step.destination_pre_count then
        return nil,reason("DESTINATION_CHANGED","destination no longer matches the planned snapshot",false)
    end
    return true
end
local function makeJournal(operation,step,baseline,now)
    return {schema=2,operation={id=operation.id,kind=operation.kind,state=operation.state,
        moved=operation.moved or 0},step={id=operation.id..":"..tostring(operation.next_step or 1),
        phase="INTENT",source_name=step.source_name,source_slot=step.source_slot,
        source_epoch=step.source_epoch,source_pre_count=step.source_pre_count,
        destination_name=step.destination_name,destination_slot=step.destination_slot,
        destination_epoch=step.destination_epoch,destination_pre_count=step.destination_pre_count,
        identity_key=step.identity_key,limit=step.limit,storage_pre_count=baseline.total,
        storage_node_ids=copyArray(baseline.node_ids)},updated_at=now}
end
function Transfer:_write(journal,phase)
    journal.step.phase=phase;journal.updated_at=self.clock()
    local callOk,saved,writeReason=pcall(self.store.write,self.store,"journal",journal,
        Transfer.validateJournal)
    if not callOk then return nil,tostring(saved) end
    return saved,writeReason
end
local function rescanFor(operation,step,nodeIds)
    local result,seen={},{}
    for _,name in ipairs(nodeIds or {}) do seen[name]=true;result[#result+1]=name end
    if operation.kind=="import" and not seen[step.source_name] then result[#result+1]=step.source_name end
    return result
end
function Transfer:execute(operation,step,storageSnapshots)
    if not validateOperation(operation) or type(step)~="table" then
        return failed("INVALID_OPERATION","operation and transfer step are required",false)
    end
    local baseline,baselineReason=self.reconciliation.capture(step.identity_key,storageSnapshots)
    if not baseline then return {state="FAILED",moved=0,reason=copy(baselineReason),
        rescan=copyArray(baselineReason.rescan or {})} end
    local ready,preflightReason=self:_preflight(operation,step)
    if not ready then return {state="FAILED",moved=0,reason=preflightReason,
        rescan=rescanFor(operation,step,baseline.node_ids)} end
    local journal=makeJournal(operation,step,baseline,self.clock())
    local saved,saveReason=self:_write(journal,"INTENT")
    if not saved then return failed("JOURNAL_WRITE",saveReason,false,baseline.node_ids) end
    saved,saveReason=self:_write(journal,"CALLING")
    if not saved then return failed("JOURNAL_WRITE",saveReason,false,baseline.node_ids) end
    local destinationSlot=operation.kind=="request" and nil or step.destination_slot
    local callOk,ok,moved=pcall(self.adapter.push,self.adapter,step.source_name,
        step.destination_name,step.source_slot,step.limit,destinationSlot)
    local callReason
    if not callOk then callReason=reason("TRANSFER_EXCEPTION",ok,true)
    elseif not ok then callReason=reason("TRANSFER_EXCEPTION",moved,true)
    elseif not integer(moved) then
        callReason=reason("INVALID_MOVED_COUNT","inventory returned "..tostring(moved),true)
    end
    if callReason then
        return {state="VERIFYING",moved=0,journal=copy(journal),reason=callReason,
            rescan=rescanFor(operation,step,baseline.node_ids)}
    end
    local called=copy(journal);called.step.reported_moved=moved
    saved,saveReason=self:_write(called,"CALLED")
    if not saved then return {state="VERIFYING",moved=moved,journal=copy(journal),
        reason=reason("JOURNAL_WRITE_AFTER_CALL",saveReason,true),
        rescan=rescanFor(operation,step,baseline.node_ids)} end
    journal=called
    return {state="VERIFYING",moved=moved,journal=copy(journal),
        rescan=rescanFor(operation,step,baseline.node_ids)}
end
local function baselineFor(journal)
    return {identity_key=journal.step.identity_key,total=journal.step.storage_pre_count,
        node_ids=copyArray(journal.step.storage_node_ids)}
end
function Transfer:verify(journal,storageSnapshots)
    local valid,validationReason=Transfer.validateJournal(journal)
    if not valid then return failed("INVALID_JOURNAL",validationReason,false) end
    if journal.schema~=2 then return {state="LEGACY",moved=0,
        reason=reason("LEGACY_JOURNAL","Legacy slot journal cannot be reconciled",true)} end
    if journal.step.phase=="RECONCILED" then
        return {state="COMPLETE",moved=journal.step.actual_moved,
            reported_moved=journal.step.reported_moved,journal=copy(journal)}
    end
    if journal.step.phase~="CALLING" and journal.step.phase~="CALLED" then
        return failed("INVALID_VERIFY_PHASE","journal is not awaiting reconciliation",false)
    end
    local result=self.reconciliation.measure(journal.operation.kind,baselineFor(journal),storageSnapshots)
    if result.state=="WAITING" then return result end
    if result.state~="READY" then return failed(result.reason.code,result.reason.message,false,result.rescan) end
    if result.moved<0 then return {state="WAITING",moved=0,
        reason=reason("RECONCILE_DIRECTION",
            "Storage total changed opposite the transfer direction; awaiting operator review",true),
        rescan=copyArray(journal.step.storage_node_ids)} end
    local reconciled=copy(journal);reconciled.step.actual_moved=result.moved
    local saved,saveReason=self:_write(reconciled,"RECONCILED")
    if not saved then return {state="WAITING",moved=result.moved,
        reason=reason("JOURNAL_WRITE",saveReason,true),
        rescan=copyArray(journal.step.storage_node_ids)} end
    return {state="COMPLETE",moved=result.moved,reported_moved=reconciled.step.reported_moved,
        journal=reconciled,before_total=result.before_total,after_total=result.after_total}
end
function Transfer:recover(journal,storageSnapshots)
    local valid,validationReason=Transfer.validateJournal(journal)
    if not valid then return failed("INVALID_JOURNAL",validationReason,false) end
    if journal.schema==1 then return {state="LEGACY",moved=0,
        reason=reason("LEGACY_JOURNAL","Legacy slot journal retired without replay",true)} end
    if journal.step.phase=="INTENT" then return {state="DISCARD_SAFE",moved=0,journal=copy(journal)} end
    return self:verify(journal,storageSnapshots)
end
function Transfer:retire()
    if type(self.store.delete)~="function" then return nil,"store cannot retire journals" end
    local callOk,deleted,deleteReason=pcall(self.store.delete,self.store,"journal")
    if not callOk then return nil,tostring(deleted) end
    return deleted,deleteReason
end

return Transfer