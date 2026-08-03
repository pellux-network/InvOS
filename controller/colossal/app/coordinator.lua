local Coordinator = {}
Coordinator.__index = Coordinator

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function clean(reason)
    return tostring(reason or "unknown error"):gsub("[%c]+", " "):sub(1, 240)
end

local function nodeView(node)
    return {
        id=node.id, role=node.role, label=node.label or node.id,
        peripheral_name=node.peripheral_name, priority=node.priority,
        state=node.enabled == false and "DISABLED" or "SCANNING",
    }
end

local function removeQueued(queue, wanted)
    local result = {}
    for _, id in ipairs(queue) do if not wanted[id] then result[#result + 1] = id end end
    return result
end

function Coordinator.new(deps)
    assert(type(deps) == "table", "coordinator dependencies are required")
    assert(type(deps.scanner) == "table", "scanner is required")
    assert(type(deps.ui) == "table", "UI is required")
    assert(type(deps.keymap) == "table", "keymap is required")
    local self = setmetatable({
        deps=deps, clock=assert(deps.clock, "clock is required"), scanner=deps.scanner,
        ui=deps.ui, keymap=deps.keymap, scanBudget=deps.scan_budget or 32,
        metadataBudget=deps.metadata_budget or 1, configured=deps.configured ~= false,
        recovering=deps.recovering == true, paused=deps.paused == true,
        uiState=copy(deps.initial_ui or {}), nodes={}, nodeById={},
        snapshots={}, scanQueue={}, targeted={}, generation=0, scanRevision={}, automationCursor=1, verificationGate=nil,
        metadata=copy(deps.metadata or {}), notices={}, dirty=true,
    }, Coordinator)
    self:_replaceNodes(deps.nodes or {})
    self:_refreshLifecycle()
    return self
end

function Coordinator:_replaceNodes(nodes)
    self.nodes, self.nodeById, self.scanQueue = {}, {}, {}
    self.snapshots,self.scanRevision,self.activeScan,self.index,self.enrichment={}, {}, nil, nil, nil
    for _, definition in ipairs(nodes) do
        local node = nodeView(definition)
        self.nodes[#self.nodes + 1] = node
        self.nodeById[node.id] = node
        if node.state ~= "DISABLED" then self.scanQueue[#self.scanQueue + 1] = node.id end
    end
end

function Coordinator:_recordError(component, reason, node)
    local message = clean(reason)
    self.notices[#self.notices + 1] = {severity="error",component=component,message=message}
    if node then node.state, node.reason = "ERROR", message end
    self.dirty = true
end

function Coordinator:_context(now)
    local ready, unhealthy = 0, 0
    local dropoffReady, pickupReady = false, false
    for _, node in ipairs(self.nodes) do
        if node.state == "READY" then
            if node.role == "storage" then ready = ready + 1 end
            if node.role == "dropoff" then dropoffReady = true end
            if node.role == "pickup" then pickupReady = true end
        elseif node.state ~= "DISABLED" and node.role == "storage" then unhealthy = unhealthy + 1 end
    end
    local storage = {}
    for _, node in ipairs(self.nodes) do
        if node.role == "storage" and node.state~="DISABLED" then
            local snapshot=copy(self.snapshots[node.id] or {node_id=node.id,
                peripheral_name=node.peripheral_name,slots={}})
            snapshot.health=node.state
            storage[#storage + 1]=snapshot
        end
    end
    return {
        now=now, configured=self.configured, recovering=self.recovering, paused=self.paused,
        initial_index_complete=self:_initialIndexComplete(), ready_storage=ready,
        unhealthy_nodes=unhealthy, dropoff_ready=dropoffReady, pickup_ready=pickupReady,
        dropoff=self:_snapshotForRole("dropoff"), pickup=self:_snapshotForRole("pickup"),
        storage=storage, index=self.index, generation=self.generation,
    }
end

function Coordinator:_snapshotForRole(role)
    for _, node in ipairs(self.nodes) do
        if node.role == role then return self.snapshots[node.id] end
    end
end

function Coordinator:_initialIndexComplete()
    local enabled = 0
    for _, node in ipairs(self.nodes) do
        if node.state ~= "DISABLED" then
            enabled = enabled + 1
            if not self.snapshots[node.id] then return false end
        end
    end
    return enabled > 0
end

function Coordinator:_refreshLifecycle(now)
    local derive = self.deps.lifecycle and self.deps.lifecycle.derive
    if derive then
        local ok, state, reason = pcall(derive, self:_context(now or self.clock()))
        if ok then self.lifecycle, self.lifecycleReason = state, reason
        else self.lifecycle, self.lifecycleReason = "ERROR", clean(state) end
    else
        self.lifecycle = self.configured and "INDEXING" or "SETUP_REQUIRED"
    end
end

function Coordinator:_rebuildIndex()
    local snapshots = {}
    for _, node in ipairs(self.nodes) do
        local snapshot = self.snapshots[node.id]
        if snapshot and node.role == "storage" and node.state=="READY" then
            snapshots[#snapshots + 1] = snapshot
        end
    end
    local ok, result = pcall(self.deps.build_index, snapshots, self.metadata)
    if ok then
        self.index, self.enrichment = result, nil
        local queryOk, results = pcall(self.deps.search, result, self.uiState.query or "",
            self.deps.aliases or {}, self.deps.search_limit or 10)
        if queryOk then
            local reduced, effect = self.ui:reduce(self.uiState,
                {type="SYNC_RESULTS",results=results or {}})
            self.uiState = reduced or self.uiState
            self:_dispatch(effect)
        else self:_recordError("search", results) end
    else self:_recordError("index", result) end
end

function Coordinator:_scanStep()
    if not self.configured then return false end
    for name,service in pairs({recovery=self.deps.recovery,imports=self.deps.imports,requests=self.deps.requests}) do
        local state
        if name~="requests" and service and type(service.status)=="function" then
            local value=service:status();state=value and value.state
        elseif name=="requests" and service and type(service.list)=="function" then
            for _,value in ipairs(service:list()) do
                if value.state~="COMPLETE" and value.state~="CANCELLED" then state=value.state;break end
            end
        end
        if state=="TRANSFERRING" then return false end
    end
    if not self.activeScan then
        local id = table.remove(self.scanQueue, 1)
        if not id then
            for _, node in ipairs(self.nodes) do
                if node.state ~= "DISABLED" then self.scanQueue[#self.scanQueue + 1] = node.id end
            end
            id = table.remove(self.scanQueue, 1)
        end
        local node = id and self.nodeById[id]
        if not node then return false end
        if not self.snapshots[node.id] then node.state = "SCANNING" end
        local ok, scan = pcall(self.scanner.begin, self.scanner, node)
        if not ok then self:_recordError("scanner", scan, node); return true end
        self.activeScan = {state=scan,node=node}
    end
    local active = self.activeScan
    local ok, done, snapshot, reason = pcall(self.scanner.step, self.scanner,
        active.state, self.scanBudget)
    if not ok then
        self:_recordError("scanner", done, active.node)
        self.activeScan = nil
        return true
    end
    if done then
        self.activeScan = nil
        if snapshot then
            snapshot.priority = active.node.priority
            self.snapshots[active.node.id] = snapshot
            self.scanRevision[active.node.id]=(self.scanRevision[active.node.id] or 0)+1
            active.node.state, active.node.reason = "READY", nil
            self.generation = self.generation + 1
            self:_rebuildIndex()
        else self:_recordError("scanner", reason and reason.message or reason, active.node) end
    end
    self.dirty = true
    return true
end

function Coordinator:_enrichStep()
    if not self.index or not self.deps.enrich_step or not self.deps.registry then return end
    local ok, state = pcall(self.deps.enrich_step, self.index, self.deps.registry,
        self.metadataBudget, self.enrichment)
    if not ok then self:_recordError("metadata", state); return end
    self.enrichment = state
    if state and state.metadata then self.metadata = copy(state.metadata) end
end

local function serviceState(name,service)
    if not service then return "IDLE" end
    if name~="requests" and type(service.status)=="function" then
        local value=service:status(); return value and value.state or "IDLE"
    end
    if name=="requests" and type(service.list)=="function" then
        for _,value in ipairs(service:list()) do
            if value.state~="COMPLETE" and value.state~="CANCELLED" then return value.state end
        end
    end
    return "IDLE"
end

function Coordinator:topologyChangeSafe()
    local entries={{"recovery",self.deps.recovery},{"imports",self.deps.imports},
        {"requests",self.deps.requests}}
    for _,entry in ipairs(entries) do
        local state=serviceState(entry[1],entry[2])
        if state=="TRANSFERRING" or state=="VERIFYING" or
            entry[1]=="recovery" and state=="BLOCKED" then
            return nil,"Finish or resolve the active "..entry[1].." reconciliation before saving topology"
        end
    end
    if self.verificationGate and self.verificationGate.phase=="verification" then
        return nil,"Finish the active transfer reconciliation before saving topology"
    end
    return true
end

function Coordinator:_gateReady()
    for id,required in pairs(self.verificationGate.required) do
        if (self.scanRevision[id] or 0)<required then return false end
    end
    return true
end

function Coordinator:_setVerificationGate(serviceName,names,phase)
    local required={}
    for _,name in ipairs(names or {}) do
        for _,node in ipairs(self.nodes) do
            if node.id==name or node.peripheral_name==name then
                required[node.id]=(self.scanRevision[node.id] or 0)+1
            end
        end
    end
    self.verificationGate={service=serviceName,required=required,phase=phase or "verification"}
    self:requestRescan(names)
end

function Coordinator:_preflightNames(serviceName)
    local names={}
    for _,node in ipairs(self.nodes) do
        local relevant=node.role=="storage" or serviceName=="requests" and node.role=="pickup" or
            serviceName=="imports" and node.role=="dropoff"
        if node.state~="DISABLED" and relevant then names[#names+1]=node.id end
    end
    return names
end

function Coordinator:_automationStep(now)
    if self.paused or self.recovering then return end
    local recoveryState=serviceState("recovery",self.deps.recovery)
    if not self.configured and (recoveryState=="IDLE" or recoveryState=="COMPLETE") then return end
    local entries={{"recovery",self.deps.recovery},{"imports",self.deps.imports},
        {"requests",self.deps.requests}}
    local selected
    if self.verificationGate then
        if not self:_gateReady() then return end
        for _,entry in ipairs(entries) do if entry[1]==self.verificationGate.service then selected=entry end end
        self.verificationGate=nil
    else
        for _,entry in ipairs(entries) do
            if (entry[1]=="imports" or entry[1]=="requests") and
                serviceState(entry[1],entry[2])=="PLANNING" then
                self:_setVerificationGate(entry[1],self:_preflightNames(entry[1]),"planning")
                return
            end
        end
        for _,entry in ipairs(entries) do
            local state=serviceState(entry[1],entry[2])
            if state=="TRANSFERRING" or state=="VERIFYING" or
                entry[1]=="recovery" and state=="BLOCKED" then selected=entry;break end
        end
        if not selected then
            for offset=0,#entries-1 do
                local index=((self.automationCursor+offset-1)%#entries)+1
                local name,service=entries[index][1],entries[index][2]
                local state=serviceState(name,service)
                if service and type(service.tick)=="function" and
                    (name~="recovery" or state~="COMPLETE" and state~="IDLE") then
                    selected=entries[index];self.automationCursor=index%#entries+1;break
                end
            end
        end
    end
    if not selected or not selected[2] or type(selected[2].tick)~="function" then return end
    local ok,result=pcall(selected[2].tick,selected[2],self:_context(now))
    if not ok then self:_recordError(selected[1],result)
    elseif type(result)=="table" and (result.state=="VERIFYING" or result.state=="BLOCKED") and result.rescan then
        self:_setVerificationGate(selected[1],result.rescan)
    end
end

function Coordinator:workStep(now)
    now = now or self.clock()
    self:_scanStep()
    self:_enrichStep()
    self:_automationStep(now)
    self:_refreshLifecycle(now)
    if self.dirty then self:redraw() end
end

function Coordinator:tick(now) self:workStep(now or self.clock()) end

function Coordinator:_dispatch(effect)
    if not effect then return end
    if effect.type == "CREATE_REQUEST" and self.deps.requests then
        local identity = effect.identity or {}
        identity.key = identity.key or identity.identity_key
        local ok, reason = pcall(self.deps.requests.create, self.deps.requests,
            identity, effect.quantity)
        if not ok then self:_recordError("request", reason) end
    elseif effect.type == "SETUP_COMMITTED" and effect.config then
        self:completeSetup(effect.config)
    elseif self.deps.on_effect then
        local ok, reason = pcall(self.deps.on_effect, effect, self)
        if not ok then self:_recordError("command", reason) end
    end
end

function Coordinator:command(command)
    if type(command)~="table" then return end
    local reducedOk,nextState,effect=pcall(self.ui.reduce,self.ui,self.uiState,command)
    if not reducedOk then self:_recordError("ui",nextState); return end
    self.uiState=nextState or self.uiState
    self:_dispatch(effect)
    if not effect and command.type=="OPEN_SETUP" and self.deps.on_effect then
        local ok,reason=pcall(self.deps.on_effect,{type="OPEN_SETUP"},self)
        if not ok then self:_recordError("setup",reason) end
    end
    self.dirty=true
    return effect
end

function Coordinator:handle(event)
    if type(event) ~= "table" then return end
    local name, peripheralName = event[1], event[2]
    if name == "peripheral_detach" or name == "peripheral" then
        for _, node in ipairs(self.nodes) do
            if node.peripheral_name == peripheralName then
                self.snapshots[node.id] = nil
                node.state = name == "peripheral_detach" and "OFFLINE" or "SCANNING"
                if name == "peripheral" then self:requestRescan({peripheralName}) end
            end
        end
        self:_refreshLifecycle(); self.dirty=true
    elseif name == "monitor_resize" or name == "term_resize" then
        self.dirty=true; self:redraw()
    end
    local ok, command = pcall(self.keymap.command, event, self.uiState)
    if not ok then self:_recordError("keymap", command); return end
    if command then
        self:command(command)
        if command.type == "QUERY_APPEND" or command.type == "QUERY_BACKSPACE" then self:_rebuildIndex() end
        self:redraw()
    end
end

function Coordinator:requestRescan(names)
    local wanted, promoted = {}, {}
    for _, name in ipairs(names or {}) do
        for _, node in ipairs(self.nodes) do
            if node.id == name or node.peripheral_name == name then
                if not wanted[node.id] and node.state ~= "DISABLED" then
                    wanted[node.id]=true; promoted[#promoted+1]=node.id
                end
            end
        end
    end
    if self.activeScan and wanted[self.activeScan.node.id] then self.activeScan=nil end
    self.scanQueue = removeQueued(self.scanQueue, wanted)
    for index=#promoted,1,-1 do table.insert(self.scanQueue,1,promoted[index]) end
end

function Coordinator:notifyTransfer(result)
    if result and result.rescan then self:requestRescan(result.rescan) end
end

function Coordinator:completeSetup(config)
    local safe,reason=self:topologyChangeSafe()
    if not safe then return nil,reason end
    self.configured = type(config)=="table" and config.configured ~= false
    if type(config)=="table" and (config.dropoff or config.pickup) then
        local nodes={}
        if config.dropoff then nodes[#nodes+1]={id="dropoff",role="dropoff",peripheral_name=config.dropoff.peripheral_name} end
        for _, node in ipairs(config.storage or {}) do
            local value=copy(node); value.role="storage"; nodes[#nodes+1]=value
        end
        if config.pickup then nodes[#nodes+1]={id="pickup",role="pickup",peripheral_name=config.pickup.peripheral_name} end
        self:_replaceNodes(nodes)
    else self:requestRescan((function() local r={} for _,n in ipairs(self.nodes) do r[#r+1]=n.id end return r end)()) end
    self:_refreshLifecycle(); self.dirty=true
    return true
end

function Coordinator:pause() self.paused=true; self:_refreshLifecycle(); self.dirty=true end
function Coordinator:resume() self.paused=false; self:_refreshLifecycle(); self.dirty=true end
function Coordinator:setRecovering(value) self.recovering=value==true; self:_refreshLifecycle(); self.dirty=true end

function Coordinator:_model()
    local items = self.index and self.index.items and self.index:items() or {}
    local total=0; for _, item in ipairs(items) do total=total+(item.quantity or 0) end
    local alerts = self.deps.alerts and self.deps.alerts.active and self.deps.alerts:active() or {}
    local requests = self.deps.requests and self.deps.requests.list and self.deps.requests:list() or {}
    local nodes=copy(self.nodes)
    for _,node in ipairs(nodes) do
        local snapshot=self.snapshots[node.id]
        if snapshot then node.size,node.occupied=snapshot.size,snapshot.occupied end
    end
    return {lifecycle=self.lifecycle,lifecycle_reason=self.lifecycleReason,nodes=nodes,
        total_items=total,total_types=#items,alerts=copy(alerts),requests=copy(requests),
        highest_alert=alerts[1],active_request=requests[1],
        dropoff=self:_nodeForRole("dropoff"),pickup=self:_nodeForRole("pickup"),
        notices=copy(self.notices),generation=self.generation,configured=self.configured}
end

function Coordinator:_nodeForRole(role)
    for _, node in ipairs(self.nodes) do if node.role==role then return copy(node) end end
end

function Coordinator:redraw()
    local model=self:_model()
    local ok, reason=pcall(self.ui.render,self.ui,self.uiState,model)
    if not ok then self:_recordError("terminal",reason) end
    if self.deps.monitor and self.deps.monitor_surface then
        local monitorOk, monitorReason=pcall(self.deps.monitor.render,self.deps.monitor_surface,model)
        if not monitorOk then self:_recordError("monitor",monitorReason) end
    end
    self.dirty=false
end

function Coordinator:viewModel()
    local value=self:_model(); value.ui=copy(self.uiState); value.snapshots=copy(self.snapshots)
    value.paused=self.paused; value.recovering=self.recovering
    return copy(value)
end

function Coordinator:run()
    local function events()
        while true do self:handle({os.pullEventRaw()}) end
    end
    local function heartbeat()
        while true do sleep((self.deps.intervals or {}).heartbeat or 0.25); self:tick(self.clock()) end
    end
    local function worker()
        while true do self:workStep(self.clock()); sleep(0) end
    end
    parallel.waitForAny(events,heartbeat,worker)
end

return Coordinator
