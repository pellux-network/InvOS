local Recovery={}
Recovery.__index=Recovery

local function copy(value,seen)
    if type(value)~="table" then return value end
    seen=seen or {};if seen[value] then return seen[value] end
    local result={};seen[value]=result
    for key,item in pairs(value) do result[copy(key,seen)]=copy(item,seen) end
    return result
end

function Recovery.new(deps)
    assert(type(deps)=="table","recovery dependencies are required")
    assert(type(deps.transfer)=="table","recovery transfer is required")
    assert(type(deps.alerts)=="table","recovery alerts are required")
    return setmetatable({journal=deps.journal,transfer=deps.transfer,alerts=deps.alerts,
        event={state=deps.journal and "VERIFYING" or "COMPLETE",moved=0}},Recovery)
end

function Recovery:status()
    return copy(self.event)
end

function Recovery:_alert(severity,message,details)
    self.alerts:set("journal_recovery",severity,message,details)
end

function Recovery:_finish(result,severity,message)
    local retired,reason=self.transfer:retire()
    if not retired then
        self:_alert("warning","Transfer recovery finished, but its old journal could not be removed: "..
            tostring(reason),{code="JOURNAL_RETIRE_FAILED"})
    elseif message then
        self:_alert(severity,message,{code=result.reason and result.reason.code,
            moved=result.moved,reported_moved=result.reported_moved})
    end
    self.journal=nil
    self.event={state="COMPLETE",moved=result.moved or 0,
        reported_moved=result.reported_moved,retired=retired==true}
    return copy(self.event)
end

function Recovery:tick(context)
    if not self.journal then return copy(self.event) end
    local result=self.transfer:recover(self.journal,(context or {}).storage or {})
    if result.state=="WAITING" then
        self.event={state="VERIFYING",moved=0,rescan=copy(result.rescan or {}),
            reason=copy(result.reason)}
        return copy(self.event)
    end
    if result.state=="COMPLETE" then
        local differs=result.reported_moved~=nil and result.reported_moved~=result.moved
        return self:_finish(result,differs and "warning" or "info",
            differs and ("Recovered transfer from storage totals: inventory moved "..
                tostring(result.moved)..", peripheral reported "..tostring(result.reported_moved)) or
                ("Recovered unfinished transfer: "..tostring(result.moved or 0).." item(s) moved"))
    end
    if result.state=="LEGACY" then
        return self:_finish(result,"warning",
            "Retired an old transfer journal without replaying it; current storage contents remain authoritative")
    end
    if result.state=="DISCARD_SAFE" then
        return self:_finish(result,"info","Discarded a transfer intent recorded before any inventory call")
    end
    return self:_finish(result,"warning","Retired an unreadable transfer journal without replaying it")
end

return Recovery
