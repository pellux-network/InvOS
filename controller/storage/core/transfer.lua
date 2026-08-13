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
local function validateNodeScope(nodeIds)
    if type(nodeIds)~="table" or #nodeIds<1 then return nil,"journal storage scope is invalid" end
    local prior,seen=nil,{}
    for _,nodeId in ipairs(nodeIds) do
        if type(nodeId)~="string" or nodeId=="" or seen[nodeId] or
            (prior and nodeId<prior) then return nil,"journal storage scope is invalid" end
        seen[nodeId],prior=true,nodeId
    end
    return true
end
local function validateScope(step)
    if not integer(step.storage_pre_count) then return nil,"journal storage baseline is invalid" end
    return validateNodeScope(step.storage_node_ids)
end
-- Schema 3 records one reconciliation baseline covering several pushes of a single exact
-- identity. Reconciliation measures an aggregate storage delta, so it cannot tell one push
-- from six - which is exactly why a batch stays provable without journalling each call.
local function validateBatch(value)
    if not validateOperation(value.operation) then return nil,"journal operation is invalid" end
    local batch=value.batch
    if type(batch)~="table" or type(batch.id)~="string" or not phases[batch.phase] then
        return nil,"journal batch is invalid"
    end
    if type(batch.identity_key)~="string" or batch.identity_key=="" then
        return nil,"journal batch identity is invalid"
    end
    if type(batch.steps)~="table" or #batch.steps<1 then
        return nil,"journal batch requires at least one step"
    end
    local total=0
    for _,step in ipairs(batch.steps) do
        if type(step)~="table" or type(step.source_name)~="string" or
            type(step.destination_name)~="string" then return nil,"journal batch step is invalid" end
        if not integer(step.source_slot,1) or not integer(step.limit,1) then
            return nil,"journal batch step is invalid"
        end
        if value.operation.kind~="request" then
            if not integer(step.destination_slot,1) or not integer(step.destination_pre_count) then
                return nil,"journal batch step destination is invalid"
            end
        end
        total=total+step.limit
    end
    if batch.limit_total~=total then return nil,"journal batch limit does not match its steps" end
    local scopeOk,scopeReason=validateScope(batch);if not scopeOk then return nil,scopeReason end
    if batch.reported_total~=nil and not integer(batch.reported_total) then
        return nil,"journal reported movement is invalid"
    end
    if batch.phase=="CALLED" and not integer(batch.reported_total) then
        return nil,"called journal requires reported movement"
    end
    if batch.phase=="RECONCILED" and not integer(batch.actual_moved) then
        return nil,"reconciled journal requires actual movement"
    end
    if type(value.updated_at)~="number" then return nil,"journal timestamp is invalid" end
    return true
end

-- Schema 4 carries one baseline per distinct identity over a shared node scope. Identities
-- are sorted so validation is deterministic, and every step must name one of them.
local function validateMultiBatch(value)
    if not validateOperation(value.operation) then return nil,"journal operation is invalid" end
    local batch=value.batch
    if type(batch)~="table" or type(batch.id)~="string" or not phases[batch.phase] then
        return nil,"journal batch is invalid"
    end
    if type(batch.identities)~="table" or #batch.identities<1 then
        return nil,"journal batch requires at least one identity"
    end
    local totals,prior={},nil
    for _,entry in ipairs(batch.identities) do
        if type(entry)~="table" or type(entry.identity_key)~="string" or
            entry.identity_key=="" then return nil,"journal batch identity is invalid" end
        if totals[entry.identity_key] or (prior and entry.identity_key<prior) then
            return nil,"journal batch identities must be unique and sorted"
        end
        if not integer(entry.storage_pre_count) or not integer(entry.limit_total,1) then
            return nil,"journal batch identity baseline is invalid"
        end
        if entry.reported_total~=nil and not integer(entry.reported_total) then
            return nil,"journal reported movement is invalid"
        end
        if batch.phase=="CALLED" and not integer(entry.reported_total) then
            return nil,"called journal requires reported movement"
        end
        if batch.phase=="RECONCILED" and not integer(entry.actual_moved) then
            return nil,"reconciled journal requires actual movement"
        end
        totals[entry.identity_key],prior=0,entry.identity_key
    end
    if type(batch.steps)~="table" or #batch.steps<1 then
        return nil,"journal batch requires at least one step"
    end
    local claimed={}
    for _,step in ipairs(batch.steps) do
        if type(step)~="table" or type(step.identity_key)~="string" or
            totals[step.identity_key]==nil then
            return nil,"journal batch step names an unrecorded identity"
        end
        if type(step.source_name)~="string" or type(step.destination_name)~="string" or
            not integer(step.source_slot,1) or not integer(step.limit,1) then
            return nil,"journal batch step is invalid"
        end
        if value.operation.kind~="request" then
            if not integer(step.destination_slot,1) or not integer(step.destination_pre_count) then
                return nil,"journal batch step destination is invalid"
            end
            local key=step.destination_name.."\0"..step.destination_slot
            if claimed[key] then return nil,"journal batch step destinations collide" end
            claimed[key]=true
        end
        totals[step.identity_key]=totals[step.identity_key]+step.limit
    end
    for _,entry in ipairs(batch.identities) do
        if totals[entry.identity_key]~=entry.limit_total then
            return nil,"journal batch limit does not match its steps"
        end
    end
    local scopeOk,scopeReason=validateNodeScope(batch.storage_node_ids)
    if not scopeOk then return nil,scopeReason end
    if type(value.updated_at)~="number" then return nil,"journal timestamp is invalid" end
    return true
end

function Transfer.validateJournal(value)
    if type(value)~="table" then return nil,"journal is invalid" end
    if value.schema==1 then return validateLegacy(value) end
    if value.schema==3 then return validateBatch(value) end
    if value.schema==4 then return validateMultiBatch(value) end
    if value.schema~=2 then return nil,"journal schema must be 1, 2, 3 or 4" end
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
local function record(journal)
    if journal.schema==3 or journal.schema==4 then return journal.batch end
    return journal.step
end
local function reportedOf(journal)
    local value=record(journal)
    if journal.schema==4 then
        local total=0
        for _,entry in ipairs(value.identities) do total=total+(entry.reported_total or 0) end
        return total
    end
    if journal.schema==3 then return value.reported_total end
    return value.reported_moved
end
function Transfer:_write(journal,phase)
    record(journal).phase=phase;journal.updated_at=self.clock()
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
local function sourceGroups(steps)
    local seen,order={},{}
    for _,step in ipairs(steps) do
        local key=step.source_name.."\0"..tostring(step.source_slot)
        if not seen[key] then
            seen[key]={name=step.source_name,slot=step.source_slot,
                identity_key=step.identity_key,total=0}
            order[#order+1]=seen[key]
        end
        seen[key].total=seen[key].total+step.limit
    end
    return order
end

-- Preflight everything before issuing anything. Planner destination slots are distinct, so
-- no push can invalidate another push's preflight.
function Transfer:_preflightBatch(operation,steps)
    for _,group in ipairs(sourceGroups(steps)) do
        local source,sourceReason=self:_inspect(group.name,group.slot)
        if not source then return nil,reason("SOURCE_UNAVAILABLE",sourceReason,false) end
        if source.identity_key~=group.identity_key or source.count<group.total then
            return nil,reason("SOURCE_CHANGED","source no longer matches the planned snapshot",false)
        end
    end
    if operation.kind=="request" then return true end
    for _,step in ipairs(steps) do
        local destination,destinationReason=self:_inspect(step.destination_name,step.destination_slot)
        if not destination then return nil,reason("DESTINATION_UNAVAILABLE",destinationReason,false) end
        local identityOk=step.destination_pre_count==0 and
            (destination.identity_key==nil or destination.count==0) or
            destination.identity_key==step.identity_key
        if not identityOk or destination.count~=step.destination_pre_count then
            return nil,reason("DESTINATION_CHANGED","destination no longer matches the planned snapshot",false)
        end
    end
    return true
end

local function makeBatchJournal(operation,steps,baseline,now)
    local recorded,total={},0
    for index,step in ipairs(steps) do
        total=total+step.limit
        recorded[index]={source_name=step.source_name,source_slot=step.source_slot,
            source_epoch=step.source_epoch,destination_name=step.destination_name,
            destination_slot=step.destination_slot,destination_epoch=step.destination_epoch,
            destination_pre_count=step.destination_pre_count,limit=step.limit}
    end
    return {schema=3,operation={id=operation.id,kind=operation.kind,state=operation.state,
        moved=operation.moved or 0},
        batch={id=operation.id..":"..tostring(operation.next_step or 1),phase="INTENT",
            identity_key=steps[1].identity_key,limit_total=total,steps=recorded,
            storage_pre_count=baseline.total,storage_node_ids=copyArray(baseline.node_ids)},
        updated_at=now}
end

local function rescanForBatch(operation,steps,nodeIds)
    local result,seen={},{}
    for _,name in ipairs(nodeIds or {}) do seen[name]=true;result[#result+1]=name end
    if operation.kind=="import" then
        for _,step in ipairs(steps) do
            if not seen[step.source_name] then
                seen[step.source_name]=true;result[#result+1]=step.source_name
            end
        end
    end
    return result
end

function Transfer:executeBatch(operation,steps,storageSnapshots)
    if not validateOperation(operation) or type(steps)~="table" or #steps<1 then
        return failed("INVALID_OPERATION","operation and at least one transfer step are required",false)
    end
    local identity=steps[1].identity_key
    for _,step in ipairs(steps) do
        if type(step)~="table" or step.identity_key~=identity then
            return failed("MIXED_IDENTITY","a batch moves exactly one exact item identity",false)
        end
    end
    local baseline,baselineReason=self.reconciliation.capture(identity,storageSnapshots)
    if not baseline then return {state="FAILED",moved=0,reason=copy(baselineReason),
        rescan=copyArray(baselineReason.rescan or {})} end
    local ready,preflightReason=self:_preflightBatch(operation,steps)
    if not ready then return {state="FAILED",moved=0,reason=preflightReason,
        rescan=rescanForBatch(operation,steps,baseline.node_ids)} end

    local journal=makeBatchJournal(operation,steps,baseline,self.clock())
    local rescan=rescanForBatch(operation,steps,baseline.node_ids)
    local saved,saveReason=self:_write(journal,"INTENT")
    if not saved then return failed("JOURNAL_WRITE",saveReason,false,baseline.node_ids) end
    saved,saveReason=self:_write(journal,"CALLING")
    if not saved then return failed("JOURNAL_WRITE",saveReason,false,baseline.node_ids) end

    local reported,callReason=0,nil
    for _,step in ipairs(steps) do
        local destinationSlot=operation.kind=="request" and nil or step.destination_slot
        local callOk,ok,moved=pcall(self.adapter.push,self.adapter,step.source_name,
            step.destination_name,step.source_slot,step.limit,destinationSlot)
        if not callOk then callReason=reason("TRANSFER_EXCEPTION",ok,true);break end
        if not ok then callReason=reason("TRANSFER_EXCEPTION",moved,true);break end
        if not integer(moved) then
            callReason=reason("INVALID_MOVED_COUNT","inventory returned "..tostring(moved),true);break
        end
        reported=reported+moved
    end
    -- An unknown call outcome leaves the journal at CALLING; only a batch whose every issued
    -- call returned a count may claim CALLED. Either way storage totals decide what moved.
    if callReason then
        return {state="VERIFYING",moved=reported,journal=copy(journal),reason=callReason,rescan=rescan}
    end
    journal.batch.reported_total=reported
    saved,saveReason=self:_write(journal,"CALLED")
    if not saved then return {state="VERIFYING",moved=reported,journal=copy(journal),
        reason=reason("JOURNAL_WRITE_AFTER_CALL",saveReason,true),rescan=rescan} end
    return {state="VERIFYING",moved=reported,journal=copy(journal),rescan=rescan}
end

local function identityGroups(steps)
    local seen,order={},{}
    for _,step in ipairs(steps) do
        if not seen[step.identity_key] then
            seen[step.identity_key]={identity_key=step.identity_key,total=0,steps={}}
            order[#order+1]=seen[step.identity_key]
        end
        local group=seen[step.identity_key]
        group.total=group.total+step.limit
        group.steps[#group.steps+1]=step
    end
    return order,seen
end

function Transfer:_preflightMulti(operation,steps)
    for _,group in ipairs(sourceGroups(steps)) do
        local source,sourceReason=self:_inspect(group.name,group.slot)
        if not source then return nil,reason("SOURCE_UNAVAILABLE",sourceReason,false) end
        if source.identity_key~=group.identity_key or source.count<group.total then
            return nil,reason("SOURCE_CHANGED","source no longer matches the planned snapshot",false)
        end
    end
    if operation.kind=="request" then return true end
    for _,step in ipairs(steps) do
        local destination,destinationReason=self:_inspect(step.destination_name,step.destination_slot)
        if not destination then return nil,reason("DESTINATION_UNAVAILABLE",destinationReason,false) end
        local identityOk=step.destination_pre_count==0 and
            (destination.identity_key==nil or destination.count==0) or
            destination.identity_key==step.identity_key
        if not identityOk or destination.count~=step.destination_pre_count then
            return nil,reason("DESTINATION_CHANGED","destination no longer matches the planned snapshot",false)
        end
    end
    return true
end

local function makeMultiJournal(operation,groups,baseline,steps,now)
    local identities={}
    for index,group in ipairs(groups) do
        identities[index]={identity_key=group.identity_key,
            storage_pre_count=baseline.totals[group.identity_key],limit_total=group.total}
    end
    table.sort(identities,function(left,right)
        return left.identity_key<right.identity_key
    end)
    local recorded={}
    for index,step in ipairs(steps) do
        recorded[index]={identity_key=step.identity_key,source_name=step.source_name,
            source_slot=step.source_slot,source_epoch=step.source_epoch,
            destination_name=step.destination_name,destination_slot=step.destination_slot,
            destination_epoch=step.destination_epoch,
            destination_pre_count=step.destination_pre_count,limit=step.limit}
    end
    return {schema=4,operation={id=operation.id,kind=operation.kind,state=operation.state,
        moved=operation.moved or 0},
        batch={id=operation.id..":"..tostring(operation.next_step or 1),phase="INTENT",
            identities=identities,steps=recorded,
            storage_node_ids=copyArray(baseline.node_ids)},
        updated_at=now}
end

function Transfer:executeMultiBatch(operation,steps,storageSnapshots)
    if not validateOperation(operation) or type(steps)~="table" or #steps<1 then
        return failed("INVALID_OPERATION","operation and at least one transfer step are required",false)
    end
    for _,step in ipairs(steps) do
        if type(step)~="table" or type(step.identity_key)~="string" or step.identity_key=="" then
            return failed("INVALID_OPERATION","every transfer step needs an exact identity",false)
        end
    end
    -- Two plans may only ever claim an empty slot or a slot already holding their own
    -- identity, so a shared destination means the plans were built from inconsistent
    -- snapshots. Refuse before issuing anything rather than double-filling a slot.
    if operation.kind~="request" then
        local claimed={}
        for _,step in ipairs(steps) do
            local key=step.destination_name.."\0"..tostring(step.destination_slot)
            if claimed[key] then
                return failed("DESTINATION_COLLISION",
                    "two planned steps target the same storage slot",false)
            end
            claimed[key]=true
        end
    end

    local groups=identityGroups(steps)
    local keys={}
    for index,group in ipairs(groups) do keys[index]=group.identity_key end
    local baseline,baselineReason=self.reconciliation.captureMany(keys,storageSnapshots)
    if not baseline then return {state="FAILED",moved=0,reason=copy(baselineReason),
        rescan=copyArray(baselineReason.rescan or {})} end
    local ready,preflightReason=self:_preflightMulti(operation,steps)
    if not ready then return {state="FAILED",moved=0,reason=preflightReason,
        rescan=rescanForBatch(operation,steps,baseline.node_ids)} end

    local journal=makeMultiJournal(operation,groups,baseline,steps,self.clock())
    local rescan=rescanForBatch(operation,steps,baseline.node_ids)
    local saved,saveReason=self:_write(journal,"INTENT")
    if not saved then return failed("JOURNAL_WRITE",saveReason,false,baseline.node_ids) end
    saved,saveReason=self:_write(journal,"CALLING")
    if not saved then return failed("JOURNAL_WRITE",saveReason,false,baseline.node_ids) end

    local reported,callReason={},nil
    for _,key in ipairs(keys) do reported[key]=0 end
    for _,step in ipairs(steps) do
        local destinationSlot=operation.kind=="request" and nil or step.destination_slot
        local callOk,ok,moved=pcall(self.adapter.push,self.adapter,step.source_name,
            step.destination_name,step.source_slot,step.limit,destinationSlot)
        if not callOk then callReason=reason("TRANSFER_EXCEPTION",ok,true);break end
        if not ok then callReason=reason("TRANSFER_EXCEPTION",moved,true);break end
        if not integer(moved) then
            callReason=reason("INVALID_MOVED_COUNT","inventory returned "..tostring(moved),true);break
        end
        reported[step.identity_key]=reported[step.identity_key]+moved
    end
    local total=0
    for _,value in pairs(reported) do total=total+value end
    if callReason then
        return {state="VERIFYING",moved=total,journal=copy(journal),reason=callReason,rescan=rescan}
    end
    for _,entry in ipairs(journal.batch.identities) do
        entry.reported_total=reported[entry.identity_key]
    end
    saved,saveReason=self:_write(journal,"CALLED")
    if not saved then return {state="VERIFYING",moved=total,journal=copy(journal),
        reason=reason("JOURNAL_WRITE_AFTER_CALL",saveReason,true),rescan=rescan} end
    return {state="VERIFYING",moved=total,journal=copy(journal),rescan=rescan}
end

local function baselineFor(journal)
    local value=record(journal)
    return {identity_key=value.identity_key,total=value.storage_pre_count,
        node_ids=copyArray(value.storage_node_ids)}
end

local function manyBaselineFor(journal)
    local totals={}
    for _,entry in ipairs(journal.batch.identities) do
        totals[entry.identity_key]=entry.storage_pre_count
    end
    return {totals=totals,node_ids=copyArray(journal.batch.storage_node_ids)}
end
-- Every identity in the batch is proven separately against its own baseline. A negative
-- delta anywhere means storage moved opposite the transfer, so the whole batch waits for a
-- human rather than partially accepting a result nobody can explain.
function Transfer:_verifyMulti(journal,storageSnapshots)
    local result=self.reconciliation.measureMany(journal.operation.kind,
        manyBaselineFor(journal),storageSnapshots)
    if result.state=="WAITING" then return result end
    if result.state~="READY" then
        return failed(result.reason.code,result.reason.message,false,result.rescan)
    end
    for _,entry in ipairs(journal.batch.identities) do
        if result.moved[entry.identity_key]<0 then
            return {state="WAITING",moved=0,
                reason=reason("RECONCILE_DIRECTION",
                    "Storage total changed opposite the transfer direction; awaiting operator review",true),
                rescan=copyArray(journal.batch.storage_node_ids)}
        end
    end
    local reconciled=copy(journal)
    local total=0
    for _,entry in ipairs(reconciled.batch.identities) do
        entry.actual_moved=result.moved[entry.identity_key]
        total=total+entry.actual_moved
    end
    local saved,saveReason=self:_write(reconciled,"RECONCILED")
    if not saved then return {state="WAITING",moved=total,
        reason=reason("JOURNAL_WRITE",saveReason,true),
        rescan=copyArray(journal.batch.storage_node_ids)} end
    return {state="COMPLETE",moved=total,moved_by_identity=copy(result.moved),
        reported_moved=reportedOf(reconciled),journal=reconciled,
        before_total=result.before,after_total=result.after}
end

function Transfer:verify(journal,storageSnapshots)
    local valid,validationReason=Transfer.validateJournal(journal)
    if not valid then return failed("INVALID_JOURNAL",validationReason,false) end
    if journal.schema==1 then return {state="LEGACY",moved=0,
        reason=reason("LEGACY_JOURNAL","Legacy slot journal cannot be reconciled",true)} end
    local entry=record(journal)
    if entry.phase=="RECONCILED" then
        return {state="COMPLETE",moved=entry.actual_moved,
            reported_moved=reportedOf(journal),journal=copy(journal)}
    end
    if entry.phase~="CALLING" and entry.phase~="CALLED" then
        return failed("INVALID_VERIFY_PHASE","journal is not awaiting reconciliation",false)
    end
    if journal.schema==4 then return self:_verifyMulti(journal,storageSnapshots) end
    local result=self.reconciliation.measure(journal.operation.kind,baselineFor(journal),storageSnapshots)
    if result.state=="WAITING" then return result end
    if result.state~="READY" then return failed(result.reason.code,result.reason.message,false,result.rescan) end
    if result.moved<0 then return {state="WAITING",moved=0,
        reason=reason("RECONCILE_DIRECTION",
            "Storage total changed opposite the transfer direction; awaiting operator review",true),
        rescan=copyArray(entry.storage_node_ids)} end
    local reconciled=copy(journal);record(reconciled).actual_moved=result.moved
    local saved,saveReason=self:_write(reconciled,"RECONCILED")
    if not saved then return {state="WAITING",moved=result.moved,
        reason=reason("JOURNAL_WRITE",saveReason,true),
        rescan=copyArray(entry.storage_node_ids)} end
    return {state="COMPLETE",moved=result.moved,reported_moved=reportedOf(reconciled),
        journal=reconciled,before_total=result.before_total,after_total=result.after_total}
end
function Transfer:recover(journal,storageSnapshots)
    local valid,validationReason=Transfer.validateJournal(journal)
    if not valid then return failed("INVALID_JOURNAL",validationReason,false) end
    if journal.schema==1 then return {state="LEGACY",moved=0,
        reason=reason("LEGACY_JOURNAL","Legacy slot journal retired without replay",true)} end
    if record(journal).phase=="INTENT" then return {state="DISCARD_SAFE",moved=0,journal=copy(journal)} end
    return self:verify(journal,storageSnapshots)
end
function Transfer:retire()
    if type(self.store.delete)~="function" then return nil,"store cannot retire journals" end
    local callOk,deleted,deleteReason=pcall(self.store.delete,self.store,"journal")
    if not callOk then return nil,tostring(deleted) end
    return deleted,deleteReason
end

return Transfer