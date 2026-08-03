package.path = "/colossal/?.lua;/colossal/?/init.lua;" .. package.path

local Alerts = require("app.alerts")
local Backup = require("app.backup")
local Coordinator = require("app.coordinator")
local ImportService = require("app.import_service")
local Keymap = require("app.keymap")
local Lifecycle = require("app.lifecycle")
local Monitor = require("app.monitor")
local Requests = require("app.requests")
local Recovery = require("app.recovery")
local Search = require("app.search")
local Setup = require("app.setup")
local UI = require("app.ui")
local Index = require("core.index")
local InventoryAdapter = require("core.inventory_adapter")
local Planner = require("core.planner")
local Reconciliation = require("core.reconciliation")
local Scanner = require("core.scanner")
local Transfer = require("core.transfer")
local Codec = require("shared.codec")
local Store = require("shared.store")

local Main = {}

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function clock(osApi)
    return function()
        if type(osApi.epoch)=="function" then return osApi.epoch("utc") end
        return math.floor((osApi.clock and osApi.clock() or 0)*1000)
    end
end

local function configDefault()
    return {schema=1,configured=false,installation=nil,dropoff=nil,pickup=nil,storage={}}
end

local function aliasesDefault() return {schema=1,items={}} end

local function metadataDefault() return {schema=1,items={}} end

-- Learned display names and stack limits are a re-learnable cache, never authoritative
-- stock truth, so a missing or invalid cache must fall back quietly and re-learn.
-- Writes are budgeted: only when the learned set actually grows, and coalesced so a
-- burst of learning at boot does not hammer disk once per item every tick.
local function metadataPersister(persistStore, validator, now)
    local lastWrittenCount, lastWriteAt, minIntervalMs = 0, -math.huge, 5000
    return function(state)
        if type(state) ~= "table" or type(state.metadata) ~= "table" then return end
        local count = 0
        for _ in pairs(state.metadata) do count = count + 1 end
        if count <= lastWrittenCount then return end
        local nowMs = now()
        if not state.done and (nowMs - lastWriteAt) < minIntervalMs then return end
        local saved = persistStore:write("metadata", {schema=1, items=copy(state.metadata)}, validator)
        if saved then lastWrittenCount, lastWriteAt = count, nowMs end
    end
end

local function existsEither(fsApi,root,name)
    return fsApi.exists(fsApi.combine(root,name..".lua")) or
        fsApi.exists(fsApi.combine(root,name..".previous.lua"))
end

local function load(store,fsApi,root,name,validator,fallback)
    if not existsEither(fsApi,root,name) then return fallback end
    local value,reason=store:recover(name,validator)
    if value then return value,reason end
    return fallback,reason
end

local function nodesFrom(config)
    if not config.configured then return {} end
    local nodes={{id="dropoff",label="Drop-off",role="dropoff",
        peripheral_name=config.dropoff.peripheral_name}}
    for _,definition in ipairs(config.storage or {}) do
        nodes[#nodes+1]={id=definition.id,label=definition.label,role="storage",
            peripheral_name=definition.peripheral_name,priority=definition.priority,
            enabled=definition.enabled}
    end
    nodes[#nodes+1]={id="pickup",label="Pickup",role="pickup",
        peripheral_name=config.pickup.peripheral_name}
    return nodes
end

local function firstMonitor(peripheralApi)
    if type(peripheralApi.find)~="function" then return nil end
    local ok,result=pcall(peripheralApi.find,"monitor")
    if ok and type(result)=="table" then return result end
end


local function setupChoices(service,step)
    local discovered=service:discover()
    local draft=service:draft()
    local choices={}
    local function addInventories(filter)
        for _,entry in ipairs(discovered) do
            if not filter or filter(entry.name,draft) then
                choices[#choices+1]={name=entry.name,label=entry.name,
                    detail=entry.size and (tostring(entry.size).." slots") or "inventory"}
            end
        end
    end
    if step==1 then
        choices={{label="Continue with "..#discovered.." inventories",detail="read-only discovery"}}
    elseif step==2 or step==3 then addInventories()
    elseif step==4 then
        addInventories(function(name,value)
            return not value.dropoff or name~=value.dropoff.peripheral_name and
                (not value.pickup or name~=value.pickup.peripheral_name)
        end)
        for _,choice in ipairs(choices) do
            for _,node in ipairs(draft.storage or {}) do
                if node.peripheral_name==choice.name then choice.label="[added] "..choice.label end
            end
        end
    elseif step==5 then choices={{label="Run read-only validation",detail="moves no items"}}
    elseif step==6 then choices={{label="Save configuration and enable",detail="starts immediately"}} end
    return choices
end

local function syncSetup(coordinator,service,step,issues)
    coordinator:command({type="SYNC_SETUP",step=math.max(1,math.min(6,step)),
        choices=setupChoices(service,step),issues=issues or {}})
    coordinator:redraw()
end

function Main.build(environment)
    local env=environment or {}
    local fsApi=env.fs or fs
    local peripheralApi=env.peripheral or peripheral
    local osApi=env.os or os
    local termApi=env.term or term
    local now=env.clock or clock(osApi)
    local root=env.data_root or "/colossal/data"
    local store=Store.new(fsApi,Codec.new(env.textutils or textutils),root)
    local config,configReason=load(store,fsApi,root,"config",Setup.validateConfig,configDefault())
    local aliases,aliasReason=load(store,fsApi,root,"aliases",Setup.validateAliases,aliasesDefault())
    -- A missing or invalid metadata cache is never fatal: it just means every item
    -- gets re-learned via getItemDetail as before, so no alert is raised for it.
    local metadata=load(store,fsApi,root,"metadata",Index.validateMetadata,metadataDefault())
    local journal,journalReason
    if existsEither(fsApi,root,"journal") then
        journal,journalReason=store:recover("journal",Transfer.validateJournal)
    end

    local alerts=Alerts.new(now)
    if configReason and config.configured==false then
        alerts:set("config_recovery","warning","Configuration needs review: "..tostring(configReason))
    end
    if aliasReason and aliases==nil then
        aliases=aliasesDefault(); alerts:set("alias_recovery","warning","Aliases could not be recovered")
    end
    if config.configured and config.installation and
        config.installation.computer_id~=osApi.getComputerID() then
        config.configured=false
        alerts:set("identity_mismatch","critical",
            "Configuration belongs to computer #"..tostring(config.installation.computer_id).."; review Setup")
    end

    local setup=Setup.new({peripheral=peripheralApi,store=store,backup=Backup,os=osApi,clock=now},config)
    local scanner=Scanner.new(peripheralApi,now)
    local coordinator
    local adapter=InventoryAdapter.new(peripheralApi,function(name)
        if not coordinator then return 0 end
        return coordinator:epochFor(name)
    end)
    local transfer=Transfer.new({store=store,adapter=adapter,clock=now,
        reconciliation=Reconciliation})
    local recovery
    if journal then
        recovery=Recovery.new({journal=journal,transfer=transfer,alerts=alerts})
    elseif journalReason then
        local retired,retireReason=transfer:retire()
        alerts:set("journal_recovery","warning",
            "Unreadable transfer journal was retired without replay: "..tostring(journalReason)..
            (retired and "" or "; removal failed: "..tostring(retireReason)),
            {code=retired and "INVALID_JOURNAL_RETIRED" or "JOURNAL_RETIRE_FAILED"})
    end
    -- A gate cycle costs about the same whether it carries one item or hundreds, so let one
    -- drain several Drop-off slots. The cap bounds how much a single ambiguous window can
    -- span; every item type in the batch is still measured against its own storage total.
    local imports=ImportService.new({planner=Planner,transfer=transfer,alerts=alerts,
        transition=Lifecycle.transition,clock=now,
        slot_batch_limit=env.slot_batch_limit or 8})
    local requests=Requests.new({planner=Planner,transfer=transfer,alerts=alerts,
        transition=Lifecycle.transition,clock=now,
        idGenerator=function(counter) return "request-"..osApi.getComputerID().."-"..counter end})
    local ui=UI.new(termApi.current and termApi.current() or termApi)
    local uiState=UI.initialState()
    if not config.configured then
        uiState.page,uiState.mode,uiState.setup_step="setup","setup",1
    end
    local monitorSurface=env.monitor_surface or firstMonitor(peripheralApi)
    local report
    local function onEffect(effect,active)
        if effect.type=="OPEN_SETUP" then syncSetup(active,setup,1)
        elseif effect.type=="CANCEL_SETUP" then setup:cancel()
        elseif effect.type=="SETUP_BACK" then syncSetup(active,setup,(effect.step or 1)-1)
        elseif effect.type=="SETUP_NEXT" then
            local nextStep=math.min(6,(effect.step or 1)+1)
            if nextStep==6 then report=setup:validate() end
            syncSetup(active,setup,nextStep,report and report.issues)
        elseif effect.type=="SETUP_SELECT" then
            local step=effect.step or 1
            local choices=setupChoices(setup,step)
            local choice=choices[effect.index or 1]
            if step==1 then syncSetup(active,setup,2)
            elseif (step==2 or step==3) and choice then
                setup:assign(step==2 and "dropoff" or "pickup",choice.name)
                syncSetup(active,setup,step+1)
            elseif step==4 and choice then
                local found
                for _,node in ipairs(setup:draft().storage or {}) do
                    if node.peripheral_name==choice.name then found=node; break end
                end
                if found then setup:removeStorage(found.id)
                else setup:addStorage(choice.name,choice.name) end
                syncSetup(active,setup,4)
            elseif step==5 then
                report=setup:validate()
                syncSetup(active,setup,report.ok and 6 or 5,report.issues)
            elseif step==6 and report and report.ok then
                local topologyOk,topologyReason=active:topologyChangeSafe()
                if not topologyOk then
                    alerts:set("setup_save","warning",topologyReason)
                    syncSetup(active,setup,6,{topologyReason})
                else
                    local saved,reason=setup:commit(report)
                    if saved then
                        config=setup:draft(); active:completeSetup(config)
                        alerts:resolve("setup_save")
                        active:command({type="CANCEL_SETUP"}); active:redraw()
                    else alerts:set("setup_save","critical","Setup could not be saved: "..tostring(reason)) end
                end
            end
        end
    end

    local persistMetadata=metadataPersister(store,Index.validateMetadata,now)
    local function enrichStep(index,registry,budget,state)
        local nextState=Index.enrichStep(index,registry,budget,state)
        persistMetadata(nextState)
        return nextState
    end

    coordinator=Coordinator.new({clock=now,scanner=scanner,nodes=nodesFrom(config),
        configured=config.configured,ui=ui,keymap=Keymap,initial_ui=uiState,
        build_index=Index.build,search=Search.query,aliases=aliases.items,
        enrich_step=enrichStep,registry=adapter,metadata_budget=1,metadata=metadata.items,
        scan_budget=512,dropoff_scan_budget=32,
        lifecycle=Lifecycle,recovery=recovery,imports=imports,requests=requests,alerts=alerts,
        monitor=Monitor,monitor_surface=monitorSurface,on_effect=onEffect,
        intervals={heartbeat=0.25}})

    if not config.configured then syncSetup(coordinator,setup,1) end
    return coordinator,{store=store,setup=setup,transfer=transfer,recovery=recovery,
        imports=imports,requests=requests,alerts=alerts,adapter=adapter}
end

function Main.run(environment)
    local coordinator=Main.build(environment)
    coordinator:redraw()
    coordinator:run()
end

if ...==nil then
    local ok,reason=xpcall(function() Main.run() end,function(value)
        return debug and debug.traceback and debug.traceback(value,2) or tostring(value)
    end)
    if not ok then printError("PellStore failed: "..tostring(reason)) end
end

return Main