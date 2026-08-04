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

local NOTICE_LIMIT = 50

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
        ui=deps.ui, keymap=deps.keymap, scanBudget=deps.scan_budget or 512,
        dropoffScanBudget=deps.dropoff_scan_budget or 32,
        metadataBudget=deps.metadata_budget or 1, configured=deps.configured ~= false,
        recovering=deps.recovering == true, paused=deps.paused == true,
        uiState=copy(deps.initial_ui or {}), nodes={}, nodeById={},
        snapshots={}, scanQueue={}, targeted={}, generation=0, scanRevision={}, automationCursor=1, verificationGate=nil,
        scanCompletedAt={}, scanRefreshInterval=deps.scan_refresh_interval or 2000,
        metadata=copy(deps.metadata or {}), notices={}, dirty=true,
    }, Coordinator)
    self:_replaceNodes(deps.nodes or {})
    self:_refreshLifecycle()
    return self
end

function Coordinator:_replaceNodes(nodes)
    self.nodes, self.nodeById, self.scanQueue = {}, {}, {}
    self.snapshots,self.scanRevision,self.activeScan,self.index,self.enrichment={}, {}, nil, nil, nil
    self.scanCompletedAt = {}
    for _, definition in ipairs(nodes) do
        local node = nodeView(definition)
        self.nodes[#self.nodes + 1] = node
        self.nodeById[node.id] = node
    end
end

function Coordinator:_recordError(component, reason, node)
    local message = clean(reason)
    self.notices[#self.notices + 1] = {severity="error",component=component,message=message}
    while #self.notices > NOTICE_LIMIT do table.remove(self.notices, 1) end
    if node then node.state, node.reason = "ERROR", message end
    if self.deps.alerts and type(self.deps.alerts.set) == "function" then
        pcall(self.deps.alerts.set, self.deps.alerts, "component_error:" .. tostring(component),
            "critical", component .. " error: " .. message, {component=component})
    end
    self.dirty = true
end

-- Lifecycle only needs role health counts. Building it without snapshot copies keeps
-- the per-tick cost independent of how many slots the storage pool holds.
function Coordinator:_statusContext(now)
    local ready, unhealthy = 0, 0
    local dropoffReady, pickupReady = false, false
    for _, node in ipairs(self.nodes) do
        if node.state == "READY" then
            if node.role == "storage" then ready = ready + 1 end
            if node.role == "dropoff" then dropoffReady = true end
            if node.role == "pickup" then pickupReady = true end
        elseif node.state ~= "DISABLED" and node.role == "storage" then unhealthy = unhealthy + 1 end
    end
    return {
        now=now, configured=self.configured, recovering=self.recovering, paused=self.paused,
        initial_index_complete=self:_initialIndexComplete(), ready_storage=ready,
        unhealthy_nodes=unhealthy, dropoff_ready=dropoffReady, pickup_ready=pickupReady,
        generation=self.generation,
    }
end

function Coordinator:_context(now)
    local context = self:_statusContext(now)
    local storage = {}
    for _, node in ipairs(self.nodes) do
        if node.role == "storage" and node.state~="DISABLED" then
            local snapshot=copy(self.snapshots[node.id] or {node_id=node.id,
                peripheral_name=node.peripheral_name,slots={}})
            snapshot.health=node.state
            storage[#storage + 1]=snapshot
        end
    end
    context.dropoff=self:_snapshotForRole("dropoff")
    context.pickup=self:_snapshotForRole("pickup")
    -- Absent on an installation with no crafting turtle, which is why every consumer
    -- has to tolerate it being nil rather than assume a buffer exists.
    context.craft_buffer=self:_snapshotForRole("craft_buffer")
    context.storage=storage
    context.index=self.index
    return context
end

function Coordinator:epochFor(peripheralName)
    for _, snapshot in pairs(self.snapshots) do
        if snapshot.peripheral_name == peripheralName then return snapshot.epoch or 0 end
    end
    return 0
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
        local ok, state, reason = pcall(derive, self:_statusContext(now or self.clock()))
        local previous, previousReason = self.lifecycle, self.lifecycleReason
        if ok then self.lifecycle, self.lifecycleReason = state, reason
        else self.lifecycle, self.lifecycleReason = "ERROR", clean(state) end
        if self.lifecycle ~= previous or self.lifecycleReason ~= previousReason then
            self.dirty = true
        end
    else
        self.lifecycle = self.configured and "INDEXING" or "SETUP_REQUIRED"
    end
end

-- A tall terminal has room for far more than 10 rows once the results list scrolls, and a
-- fixed cap left nothing to scroll to. Derive a generous bound from the live surface height
-- when one is available, and otherwise fall back to a bound well above the old default.
function Coordinator:_defaultSearchLimit()
    local surface = self.ui and self.ui.surface
    if surface and type(surface.getSize) == "function" then
        local ok, _, height = pcall(surface.getSize)
        if ok and type(height) == "number" and height > 0 then
            return math.max(50, height * 4)
        end
    end
    return 50
end

-- Usage stats are only ever added to an identity that enrichment already gave a
-- display_name and max_count, so every cached entry always has both or neither: a
-- partial entry would fail Index.validateMetadata and block persisting everything else.
function Coordinator:recordItemRequested(identityKey, timestamp)
    local existing = self.metadata[identityKey]
    if type(existing) ~= "table" then return end
    local details = copy(existing)
    details.request_count = (details.request_count or 0) + 1
    details.last_requested = timestamp or self.clock()
    self.metadata[identityKey] = details
    self.dirty = true
    self:_rebuildIndex()
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
            self.deps.aliases or {}, self.deps.search_limit or self:_defaultSearchLimit())
        if queryOk then
            local reduced, effect = self.ui:reduce(self.uiState,
                {type="SYNC_RESULTS",results=results or {}})
            self.uiState = reduced or self.uiState
            self:_dispatch(effect)
        else self:_recordError("search", results) end
    else self:_recordError("index", result) end
end

-- Drop-off scans call getItemDetail per occupied slot, so they stay peripheral bounded.
-- Every other role is pure Lua slot bookkeeping and can absorb a bulk budget.
function Coordinator:_budgetFor(node)
    if node.role == "dropoff" then return self.dropoffScanBudget end
    return self.scanBudget
end

-- Idle refill only offers a node once it is actually worth scanning: currently missing a
-- snapshot (never scanned, or knocked offline since its last one -- either way treated as
-- infinitely stale so it wins any tie) or stale past scanRefreshInterval. Returning nil lets
-- the work loop go quiet instead of rescanning every node forever regardless of freshness.
function Coordinator:_staleNodeId(now)
    local bestId, bestAge
    for _, node in ipairs(self.nodes) do
        if node.state ~= "DISABLED" then
            local age
            if not self.snapshots[node.id] then
                age = math.huge
            else
                local completedAt = self.scanCompletedAt[node.id]
                age = completedAt and (now - completedAt) or math.huge
            end
            if age >= self.scanRefreshInterval and (not bestAge or age > bestAge) then
                bestId, bestAge = node.id, age
            end
        end
    end
    return bestId
end

function Coordinator:_scanStep(now)
    if not self.configured then return false end
    for name,service in pairs({recovery=self.deps.recovery,imports=self.deps.imports,
        requests=self.deps.requests,crafts=self.deps.crafts}) do
        local state
        if name~="requests" and service and type(service.status)=="function" then
            local value=service:status();state=value and value.state
        elseif name=="requests" and service and type(service.list)=="function" then
            for _,value in ipairs(service:list()) do
                if value.state~="COMPLETE" and value.state~="CANCELLED" and
                    value.state~="FAILED" then state=value.state;break end
            end
        end
        if state=="TRANSFERRING" then return false end
    end
    if not self.activeScan then
        local id = table.remove(self.scanQueue, 1) or self:_staleNodeId(now)
        local node = id and self.nodeById[id]
        if not node then return false end
        -- Starting a fresh scan (never scanned, or retrying after an ERROR/OFFLINE) is
        -- user-visible even before it finishes, so it must repaint even though a merely
        -- in-progress step normally does not.
        if not self.snapshots[node.id] then node.state = "SCANNING"; self.dirty = true end
        local ok, scan = pcall(self.scanner.begin, self.scanner, node)
        if not ok then self:_recordError("scanner", scan, node); return true end
        self.activeScan = {state=scan,node=node}
    end
    local active = self.activeScan
    local ok, done, snapshot, reason = pcall(self.scanner.step, self.scanner,
        active.state, self:_budgetFor(active.node))
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
            self.scanCompletedAt[active.node.id] = now
            active.node.state, active.node.reason = "READY", nil
            self.generation = self.generation + 1
            self:_rebuildIndex()
        else self:_recordError("scanner", reason and reason.message or reason, active.node) end
        -- Only a finished scan changes anything on screen. Marking dirty on every partial
        -- step repainted the terminal and the monitor at the full work-loop rate forever,
        -- rebuilding the whole item list each time.
        self.dirty = true
    end
    return true
end

function Coordinator:_enrichStep()
    if not self.index or not self.deps.enrich_step or not self.deps.registry then return end
    local ok, state = pcall(self.deps.enrich_step, self.index, self.deps.registry,
        self.metadataBudget, self.enrichment)
    if not ok then self:_recordError("metadata", state); return end
    self.enrichment = state
    -- Enrichment owns this table and mutates it in place, so hold the reference rather than
    -- rebuilding a copy of it on every tick. Index.build already deep-copies whatever it is
    -- handed, and newEnrichmentState copies back out of the index, so no caller can reach in
    -- and corrupt enrichment through it.
    if state and state.metadata and self.metadata ~= state.metadata then
        self.metadata = state.metadata
        self.dirty = true
    end
end

local function serviceState(name,service)
    if not service then return "IDLE" end
    if name~="requests" and type(service.status)=="function" then
        local value=service:status(); return value and value.state or "IDLE"
    end
    if name=="requests" and type(service.list)=="function" then
        for _,value in ipairs(service:list()) do
            if value.state~="COMPLETE" and value.state~="CANCELLED" and
                value.state~="FAILED" then return value.state end
        end
    end
    return "IDLE"
end

function Coordinator:topologyChangeSafe()
    local entries={{"recovery",self.deps.recovery},{"imports",self.deps.imports},
        {"requests",self.deps.requests},{"crafts",self.deps.crafts}}
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

-- Which destination a retrieval is heading for depends on the request in flight, not on
-- the service. Scanning Pickup for a craft withdrawal would gate on the wrong inventory
-- and leave the buffer's snapshot stale at the moment the plan is made.
function Coordinator:_requestDestinationRole()
    local service=self.deps.requests
    if not service or type(service.list)~="function" then return "pickup" end
    local ok,listed=pcall(service.list,service)
    if not ok then return "pickup" end
    for _,request in ipairs(listed) do
        if request.state~="COMPLETE" and request.state~="CANCELLED" and
            request.state~="FAILED" then
            return request.destination_role or "pickup"
        end
    end
    return "pickup"
end

function Coordinator:_preflightNames(serviceName)
    local names={}
    local destination=serviceName=="requests" and self:_requestDestinationRole() or nil
    for _,node in ipairs(self.nodes) do
        local relevant=node.role=="storage" or
            serviceName=="requests" and node.role==destination or
            serviceName=="imports" and node.role=="dropoff" or
            serviceName=="crafts" and node.role=="craft_buffer"
        if node.state~="DISABLED" and relevant then names[#names+1]=node.id end
    end
    return names
end

function Coordinator:_automationStep(now)
    if self.paused or self.recovering then return end
    local recoveryState=serviceState("recovery",self.deps.recovery)
    if not self.configured and (recoveryState=="IDLE" or recoveryState=="COMPLETE") then return end
    local entries={{"recovery",self.deps.recovery},{"imports",self.deps.imports},
        {"requests",self.deps.requests},{"crafts",self.deps.crafts}}
    local selected
    if self.verificationGate then
        if not self:_gateReady() then return end
        for _,entry in ipairs(entries) do if entry[1]==self.verificationGate.service then selected=entry end end
        self.verificationGate=nil
    else
        -- Never begin planning a new transfer while one is already in flight. Planning
        -- gates a rescan and then issues moves, and two services doing that at once share
        -- one journal while each measures aggregate storage deltas the other is changing,
        -- which shows up as items credited to the wrong step. Deferring costs a tick.
        local inFlight = false
        for _,entry in ipairs(entries) do
            local state=serviceState(entry[1],entry[2])
            if state=="TRANSFERRING" or state=="VERIFYING" then inFlight=true;break end
        end
        if not inFlight then
            for _,entry in ipairs(entries) do
                if (entry[1]=="imports" or entry[1]=="requests" or entry[1]=="crafts") and
                    serviceState(entry[1],entry[2])=="PLANNING" then
                    self:_setVerificationGate(entry[1],self:_preflightNames(entry[1]),"planning")
                    return
                end
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
    -- Automation advancing is user-visible: request progress, node states, alerts.
    self.dirty=true
    if not ok then self:_recordError(selected[1],result)
    elseif type(result)=="table" and result.rescan and
        (result.state=="VERIFYING" or result.state=="BLOCKED" or selected[1]=="crafts") then
        -- Crafting asks for a rescan from its own states, not VERIFYING or BLOCKED: the
        -- turtle drops output into the buffer without anything telling the controller.
        --
        -- A gate can never open while the asking service is TRANSFERRING, because
        -- _scanStep refuses to scan then and the revision it waits on never advances --
        -- which stops the whole rotation, including the transfer the gate is waiting on.
        -- Queue the rescan instead and let it happen once the transfer settles.
        if serviceState(selected[1],selected[2])=="TRANSFERRING" then
            self:requestRescan(result.rescan)
        else
            self:_setVerificationGate(selected[1],result.rescan)
        end
    end
end

function Coordinator:workStep(now)
    now = now or self.clock()
    self:_scanStep(now)
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
    elseif effect.type == "RETRY_REQUEST" and self.deps.requests then
        local target = self.deps.requests.list and self:_requestsDisplay()[effect.index]
        if target then
            local ok, reason = pcall(self.deps.requests.retry, self.deps.requests, target.id)
            if not ok then self:_recordError("request", reason) end
        end
    elseif effect.type == "CANCEL_REQUEST" and self.deps.requests then
        local target = self.deps.requests.list and self:_requestsDisplay()[effect.index]
        if target then
            local ok, reason = pcall(self.deps.requests.cancel, self.deps.requests, target.id)
            if not ok then self:_recordError("request", reason) end
        end
    elseif effect.type == "ACKNOWLEDGE_ALERT" and self.deps.alerts then
        local target = self.deps.alerts.active and self.deps.alerts:active()[effect.index]
        if target then
            local ok, reason = pcall(self.deps.alerts.acknowledge, self.deps.alerts, target.key)
            if not ok then self:_recordError("alert", reason) end
        end
    elseif effect.type == "RESOLVE_RECOVERY" and self.deps.recovery then
        local ok, reason = pcall(self.deps.recovery.resolve, self.deps.recovery)
        if not ok then self:_recordError("recovery", reason) end
    elseif effect.type == "PLAN_CRAFT" then
        self:_planCraft(effect)
    elseif effect.type == "COMMIT_CRAFT" then
        if self.deps.crafts then
            local ok, reason = pcall(self.deps.crafts.enqueue, self.deps.crafts,
                effect.item, effect.quantity,
                {destination=effect.destination, confirmed=effect.plan})
            if not ok then self:_recordError("craft", reason) end
        else
            self:_recordError("craft", "crafting is not configured; bind a buffer and turtle")
        end
    elseif effect.type == "PIN_CRAFT_CHOICE" and self.deps.craft_prefs then
        local ok, reason = pcall(self.deps.craft_prefs.pinTag, self.deps.craft_prefs,
            effect.tag, effect.item)
        if not ok then self:_recordError("craft", reason) end
    elseif effect.type == "RETRY_CRAFT" or effect.type == "CANCEL_CRAFT" or
        effect.type == "CONFIRM_CRAFT" then
        local service = self.deps.crafts
        local target = service and service.list and service:list()[effect.index]
        if service and target then
            local method = effect.type == "RETRY_CRAFT" and service.retry or
                (effect.type == "CANCEL_CRAFT" and service.cancel or service.confirm)
            local ok, reason = pcall(method, service, target.id)
            if not ok then self:_recordError("craft", reason) end
        end
    elseif effect.type == "TOGGLE_PAUSE" then
        if self.paused then self:resume() else self:pause() end
    elseif effect.type == "SETUP_COMMITTED" and effect.config then
        self:completeSetup(effect.config)
    elseif self.deps.on_effect then
        local ok, reason = pcall(self.deps.on_effect, effect, self)
        if not ok then self:_recordError("command", reason) end
    end
end


-- Planning is a pure computation over the current index, so it runs inline on the
-- keypress rather than going through the automation rotation. Nothing moves here; the
-- resulting plan is only rendered so the operator can confirm it.
function Coordinator:_planCraft(effect)
    local repo, planner = self.deps.recipes, self.deps.craft_planner
    if not repo or not planner then return end
    local context = {
        repo = repo, prefs = self.deps.craft_prefs,
        available = function(itemId) return self:_craftStock(itemId) end,
        stack_limit = function() return 64 end,
    }
    local quantity = effect.quantity
    if quantity == "max" then
        local ok, most = pcall(planner.maxCraftable, effect.item, context)
        quantity = ok and most or 0
    end
    local plan
    if type(quantity) ~= "number" or quantity < 1 then
        plan = {ok=false, item=effect.item, quantity=0, steps={}, withdrawals={},
            chosen={}, shortfalls={{item=effect.item, missing=1}},
            reason={code="NOTHING_CRAFTABLE", message="Nothing can be crafted right now"}}
    else
        local ok, computed = pcall(planner.plan, {item=effect.item, quantity=quantity}, context)
        if not ok then self:_recordError("craft", computed); return end
        plan = computed
    end
    local reduced = self.ui:reduce(self.uiState, {type="SYNC_CRAFT_PLAN", plan=plan})
    self.uiState = reduced or self.uiState
    self.dirty = true
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
    elseif name == "rednet_message" then
        -- The turtle's reply lands here, on the only loop that sees every event. The
        -- craft service reads it from the link's inbox on its next tick.
        local link = self.deps.turtle_link
        if link and type(link.deliver) == "function" then
            local ok, reason = pcall(link.deliver, link, event[2], event[3], event[4])
            if not ok then self:_recordError("turtle link", reason) end
            self.dirty = true
        end
    end
    local ok, command = pcall(self.keymap.command, event, self.uiState)
    if not ok then self:_recordError("keymap", command); return end
    if command then
        self:command(command)
        if command.type == "QUERY_APPEND" or command.type == "QUERY_BACKSPACE" then self:_rebuildIndex() end
        if command.type == "CRAFT_QUERY_APPEND" or command.type == "CRAFT_QUERY_BACKSPACE" or
            (command.type == "OPEN_PAGE" and command.page == "crafting") then
            self:_syncCraft()
        end
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

-- Requests:list() stays creation-order (oldest first): the gating checks above scan it
-- for the first non-terminal entry, which is only the in-flight request in that order.
-- Reverse a copy for display, so the Requests page and its retry/cancel selection agree
-- on "topmost row is newest" without disturbing that gating scan.
function Coordinator:_requestsDisplay()
    local raw = self.deps.requests and self.deps.requests.list and self.deps.requests:list() or {}
    local reversed = {}
    for index = #raw, 1, -1 do reversed[#reversed + 1] = raw[index] end
    return reversed
end

local TERMINAL_REQUEST = {COMPLETE=true, CANCELLED=true, FAILED=true}

-- The request actually in flight is the oldest non-terminal one, because Requests:_next()
-- processes creation order, not the newest one: a burst of queued retrievals must not pin
-- "current activity" on a request that has not started while older ones keep progressing.
-- requestsNewestFirst is already reversed for display, so walk it back-to-front. Once
-- nothing is active, fall back to the newest entry so "last activity" still shows something.
local function activeRequest(requestsNewestFirst)
    for index = #requestsNewestFirst, 1, -1 do
        local request = requestsNewestFirst[index]
        if not TERMINAL_REQUEST[request.state] then return request end
    end
    return requestsNewestFirst[1]
end

-- Enrichment learns display names and stack limits gradually and deliberately never blocks
-- INDEXING/READY (AGENTS.md: "a failed getItemDetail call does not stop scanning or input"),
-- so without this a wiped metadata cache looks identical to a fully settled system while
-- thousands of getItemDetail calls are still queued behind it, one per tick.
function Coordinator:_enrichmentProgress()
    local state = self.enrichment
    if not state or state.done then return nil end
    return {learned = state.cursor - 1, total = #state.keys}
end


-- The recipe catalogue is 639 entries and does not change while the controller runs, so
-- it is built once rather than rebuilt per keystroke. Stock is looked up per displayed
-- result instead, which is bounded by the display limit.
function Coordinator:_craftCatalogue()
    if self.craftCatalogue then return self.craftCatalogue end
    local repo = self.deps.recipes
    if not repo or type(repo.outputs) ~= "function" then return {} end
    local ok, listed = pcall(repo.outputs, repo)
    self.craftCatalogue = ok and listed or {}
    return self.craftCatalogue
end

function Coordinator:_craftStock(itemId)
    if not self.index or type(self.index.quantity) ~= "function" then return 0 end
    local key = tostring(itemId) .. string.char(0) .. "-"
    local ok, quantity = pcall(self.index.quantity, self.index, key)
    if not ok or type(quantity) ~= "number" then return 0 end
    return quantity
end

function Coordinator:_craftSearch(query)
    local needle = tostring(query or ""):lower()
    local results, limit = {}, 60
    for _, entry in ipairs(self:_craftCatalogue()) do
        if #results >= limit then break end
        local label = tostring(entry.display_name or entry.item):lower()
        if needle == "" or label:find(needle, 1, true) or
            tostring(entry.item):lower():find(needle, 1, true) then
            results[#results + 1] = {item=entry.item, display_name=entry.display_name,
                quantity=self:_craftStock(entry.item)}
        end
    end
    return results
end

-- Jobs change without any keypress: they advance through the automation rotation, and a
-- commit adds one. So this belongs in the redraw path alongside the request and alert
-- counts, not only on the keystrokes that opened the page. Syncing it on keystrokes
-- alone left the list showing whatever it held when the page was opened, so a freshly
-- committed job read as "No craft jobs" and a running one appeared frozen at QUEUED.
function Coordinator:_syncCraftJobs()
    local jobs = self.deps.crafts and self.deps.crafts.list and self.deps.crafts:list() or {}
    local view = {}
    for index, job in ipairs(jobs) do
        view[index] = {item=job.item, display_name=job.item, state=job.state,
            quantity=job.quantity, id=job.id,
            reason=job.reason and job.reason.message or nil}
    end
    local synced = self.ui:reduce(self.uiState, {type="SYNC_CRAFT_JOBS", jobs=view})
    self.uiState = synced or self.uiState
end

-- The recipe list only changes when the query does, so it stays on the keystroke path.
function Coordinator:_syncCraft()
    local reduced = self.ui:reduce(self.uiState,
        {type="SYNC_CRAFT_RESULTS", results=self:_craftSearch(self.uiState.craft_query)})
    self.uiState = reduced or self.uiState
    self:_syncCraftJobs()
end

-- What the 1x1 crafting monitor renders. Deliberately a different model from the storage
-- monitor's, which is why it is a separate renderer rather than another size tier.
function Coordinator:_craftMonitorModel()
    local service = self.deps.crafts
    local catalogue = #self:_craftCatalogue()
    if not service or type(service.list) ~= "function" then
        return {active=nil, queued=0, craftable_types=catalogue}
    end
    local jobs, active, queued = service:list(), nil, 0
    for _, job in ipairs(jobs) do
        local terminal = job.state == "COMPLETE" or job.state == "CANCELLED" or
            job.state == "FAILED"
        if not terminal then
            if not active then active = job else queued = queued + 1 end
        end
    end
    if not active then return {active=nil, queued=0, craftable_types=catalogue} end
    local steps = active.plan and #active.plan.steps or nil
    local current = active.plan and active.step_index and active.plan.steps[active.step_index]
    return {
        active = {item=active.item, display_name=active.item, state=active.state,
            step=active.step_index, steps=steps, quantity=active.quantity,
            produced=current and current.produced or 0,
            current_item=current and current.item or nil,
            reason=active.reason and active.reason.code or nil},
        queued = queued, craftable_types = catalogue,
    }
end

function Coordinator:_model()
    local items = self.index and self.index.items and self.index:items() or {}
    local total=0; for _, item in ipairs(items) do total=total+(item.quantity or 0) end
    local alerts = self.deps.alerts and self.deps.alerts.active and self.deps.alerts:active() or {}
    local requests = self:_requestsDisplay()
    local nodes=copy(self.nodes)
    for _,node in ipairs(nodes) do
        local snapshot=self.snapshots[node.id]
        if snapshot then node.size,node.occupied=snapshot.size,snapshot.occupied end
    end
    return {lifecycle=self.lifecycle,lifecycle_reason=self.lifecycleReason,nodes=nodes,
        total_items=total,total_types=#items,alerts=copy(alerts),requests=copy(requests),
        highest_alert=alerts[1],active_request=activeRequest(requests),
        dropoff=self:_nodeForRole("dropoff"),pickup=self:_nodeForRole("pickup"),
        enrichment=self:_enrichmentProgress(),
        notices=copy(self.notices),generation=self.generation,configured=self.configured}
end

function Coordinator:_nodeForRole(role)
    for _, node in ipairs(self.nodes) do if node.role==role then return copy(node) end end
end

function Coordinator:_syncPageCounts(model)
    local requestsReduced = self.ui:reduce(self.uiState,
        {type="SYNC_REQUESTS",count=#(model.requests or {})})
    self.uiState = requestsReduced or self.uiState
    local alertsReduced = self.ui:reduce(self.uiState,
        {type="SYNC_ALERTS",count=#(model.alerts or {})})
    self.uiState = alertsReduced or self.uiState
    self:_syncCraftJobs()
end

function Coordinator:redraw()
    local model=self:_model()
    self:_syncPageCounts(model)
    local ok, result=pcall(self.ui.render,self.ui,self.uiState,model)
    if not ok then self:_recordError("terminal",result)
    elseif type(result) == "table" and result.hit_regions then
        self.uiState.hit_regions = result.hit_regions
    end
    if self.deps.monitor and self.deps.monitor_surface then
        local monitorOk, monitorReason=pcall(self.deps.monitor.render,self.deps.monitor_surface,model)
        if not monitorOk then self:_recordError("monitor",monitorReason) end
    end
    if self.deps.craft_monitor and self.deps.craft_monitor_surface then
        local craftOk, craftReason=pcall(self.deps.craft_monitor.render,
            self.deps.craft_monitor_surface,self:_craftMonitorModel())
        if not craftOk then self:_recordError("craft monitor",craftReason) end
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
    local function worker()
        local interval=(self.deps.intervals or {}).worker or 0.05
        while true do self:workStep(self.clock()); sleep(interval) end
    end
    parallel.waitForAny(events,worker)
end

return Coordinator
