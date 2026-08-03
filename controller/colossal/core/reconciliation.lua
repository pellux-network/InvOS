local M={}

local function copyArray(values)
    local result={}
    for index,value in ipairs(values or {}) do result[index]=value end
    return result
end

local function reason(code,message,retryable)
    return {code=code,message=message,retryable=retryable==true}
end

local function identityTotal(identityKey,slots)
    if type(slots)~="table" then
        return nil,reason("MALFORMED_STORAGE_SNAPSHOT","Storage slots must be a table",false)
    end
    local total=0
    for slot,item in pairs(slots) do
        if type(slot)~="number" or slot<1 or slot%1~=0 or type(item)~="table" or
            type(item.identity_key)~="string" or item.identity_key=="" or
            type(item.count)~="number" or item.count<1 or item.count%1~=0 then
            return nil,reason("MALFORMED_STORAGE_SNAPSHOT",
                "Storage snapshot contains an invalid slot item",false)
        end
        if item.identity_key==identityKey then total=total+item.count end
    end
    return total
end

local function validBaseline(value)
    if type(value)~="table" or type(value.identity_key)~="string" or
        type(value.total)~="number" or value.total<0 or value.total%1~=0 or
        type(value.node_ids)~="table" or #value.node_ids<1 then return false end
    local prior,seen=nil,{}
    for _,nodeId in ipairs(value.node_ids) do
        if type(nodeId)~="string" or nodeId=="" or seen[nodeId] or
            (prior and nodeId<prior) then return false end
        seen[nodeId],prior=true,nodeId
    end
    return true
end

function M.capture(identityKey,snapshots)
    if type(identityKey)~="string" or identityKey=="" then
        return nil,reason("INVALID_IDENTITY","Exact item identity is required",false)
    end
    local total,nodeIds,seen,incomplete=0,{},{},false
    for _,snapshot in ipairs(snapshots or {}) do
        if type(snapshot)~="table" or type(snapshot.node_id)~="string" or
            snapshot.node_id=="" or type(snapshot.health)~="string" or
            type(snapshot.slots)~="table" then
            return nil,reason("MALFORMED_STORAGE_SNAPSHOT",
                "Storage scope contains an invalid node snapshot",false)
        end
        if seen[snapshot.node_id] then
            return nil,reason("DUPLICATE_STORAGE_NODE","Storage scope contains duplicate node IDs",false)
        end
        seen[snapshot.node_id]=true
        nodeIds[#nodeIds+1]=snapshot.node_id
        if snapshot.health=="READY" then
            local subtotal,cause=identityTotal(identityKey,snapshot.slots)
            if subtotal==nil then return nil,cause end
            total=total+subtotal
        else incomplete=true end
    end
    table.sort(nodeIds)
    if #nodeIds==0 then
        return nil,reason("NO_STORAGE_SCOPE","No configured storage scope is available",true)
    end
    if incomplete then
        local cause=reason("STORAGE_SCOPE_INCOMPLETE",
            "Waiting for every configured storage node",true)
        cause.rescan=copyArray(nodeIds)
        return nil,cause
    end
    return {identity_key=identityKey,total=total,node_ids=nodeIds}
end

function M.measure(kind,baseline,snapshots)
    if kind~="request" and kind~="import" then
        return {state="FAILED",reason=reason("INVALID_DIRECTION","Unknown transfer direction",false)}
    end
    if not validBaseline(baseline) then
        return {state="FAILED",reason=reason("INVALID_BASELINE","Storage baseline is invalid",false)}
    end
    local byId={}
    for _,snapshot in ipairs(snapshots or {}) do
        if type(snapshot)~="table" or type(snapshot.node_id)~="string" or snapshot.node_id=="" then
            return {state="FAILED",reason=reason("MALFORMED_STORAGE_SNAPSHOT",
                "Storage scope contains an invalid node snapshot",false)}
        end
        if byId[snapshot.node_id] then
            return {state="FAILED",reason=reason("DUPLICATE_STORAGE_NODE",
                "Storage scope contains duplicate node IDs",false)}
        end
        byId[snapshot.node_id]=snapshot
    end
    local after=0
    for _,nodeId in ipairs(baseline.node_ids) do
        local snapshot=byId[nodeId]
        if not snapshot or snapshot.health~="READY" then
            return {state="WAITING",reason=reason("STORAGE_SCOPE_INCOMPLETE",
                "Waiting for every baseline storage node",true),
                rescan=copyArray(baseline.node_ids)}
        end
        local subtotal,cause=identityTotal(baseline.identity_key,snapshot.slots)
        if subtotal==nil then return {state="FAILED",reason=cause} end
        after=after+subtotal
    end
    local moved=kind=="request" and baseline.total-after or after-baseline.total
    return {state="READY",before_total=baseline.total,after_total=after,moved=moved}
end

return M
