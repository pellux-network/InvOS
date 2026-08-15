package.path = "/storage/?.lua;/storage/?/init.lua;" .. package.path

local Alerts = require("app.alerts")
local CraftBuffer = require("app.craft_buffer")
local CraftMonitor = require("app.craft_monitor")
local CraftService = require("app.craft_service")
local TurtleLink = require("app.turtle_link")
local Backup = require("app.backup")
local Coordinator = require("app.coordinator")
local ImportService = require("app.import_service")
local Keymap = require("app.keymap")
local Lifecycle = require("app.lifecycle")
local Monitor = require("app.monitor")
local Requests = require("app.requests")
local Recovery = require("app.recovery")
local Search = require("app.search")
local Buffer = require("app.buffer")
local Setup = require("app.setup")
local Theme = require("app.theme")
local UI = require("app.ui")
local CraftPlanner = require("core.craft_planner")
local CraftPrefs = require("core.craft_prefs")
local Identity = require("core.identity")
local Index = require("core.index")
local RecipeRepo = require("core.recipe_repo")
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
    return {schema=2,configured=false,installation=nil,dropoff=nil,pickup=nil,storage={},
        craft_buffer=nil,turtle=nil,monitors=nil}
end

local function aliasesDefault() return {schema=1,items={}} end

local function metadataDefault() return {schema=1,items={}} end

-- Learned display names and stack limits, plus per-identity request counts and last-
-- requested timestamps, are a re-learnable cache, never authoritative stock truth, so a
-- missing or invalid cache must fall back quietly and re-learn. Writes are budgeted: only
-- when the cache actually grew or an existing entry's usage stats advanced, and coalesced
-- so a burst of activity does not hammer disk once per change every tick. Both signals are
-- monotonically non-decreasing (keys are never removed, usage stats only ever increase),
-- so comparing against the high-water mark is enough without diffing the whole cache.
local function metadataPersister(persistStore, validator, now)
    local lastWrittenCount, lastWrittenActivity, lastWriteAt, minIntervalMs = 0, 0, -math.huge, 5000
    return function(state)
        if type(state) ~= "table" or type(state.metadata) ~= "table" then return end
        local count, activity = 0, 0
        for _, details in pairs(state.metadata) do
            count = count + 1
            if type(details) == "table" and (details.last_requested or 0) > activity then
                activity = details.last_requested
            end
        end
        if count <= lastWrittenCount and activity <= lastWrittenActivity then return end
        local nowMs = now()
        if not state.done and (nowMs - lastWriteAt) < minIntervalMs then return end
        local saved = persistStore:write("metadata", {schema=1, items=copy(state.metadata)}, validator)
        if saved then lastWrittenCount, lastWrittenActivity, lastWriteAt = count, activity, nowMs end
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

-- Delegates to Coordinator.nodesFrom so boot and "finish the wizard" cannot disagree about
-- what the nodes are. They did: the coordinator's copy dropped the craft buffer.
local function nodesFrom(config)
    if not config.configured then return {} end
    return Coordinator.nodesFrom(config)
end

local function firstMonitor(peripheralApi)
    if type(peripheralApi.find)~="function" then return nil end
    local ok,result=pcall(peripheralApi.find,"monitor")
    if ok and type(result)=="table" then return result end
end

-- With two monitors attached, peripheral.find returns an arbitrary one, so each is bound
-- by name in config. The find stays as the fallback for an installation that has not
-- been reconfigured yet, which keeps an existing schema 1 install working unchanged.
local function boundMonitor(peripheralApi,name,fallback)
    if type(name)=="string" and name~="" and type(peripheralApi.wrap)=="function" then
        local ok,surface=pcall(peripheralApi.wrap,name)
        if ok and type(surface)=="table" and type(surface.getSize)=="function" then
            return surface
        end
    end
    if fallback then return firstMonitor(peripheralApi) end
    return nil
end


-- Only codes with one unambiguous fix location get a jump. PERIPHERAL_MISSING,
-- MISSING_METHOD, DUPLICATE_BINDING, and DUPLICATE_CONFIRMED name a peripheral or role in
-- their own message instead; showing the full message is enough context without guessing.
local SETUP_ISSUE_STEP = {
    MISSING_DROPOFF=2, ROLE_COLLISION=2,
    MISSING_PICKUP=3,
    MISSING_STORAGE=4,
    BUFFER_COLLISION=5, TURTLE_WITHOUT_BUFFER=5,
}

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
    -- Every crafting binding is optional and skippable: an installation without a turtle
    -- must still be able to finish Setup.
    local function addSkip(label)
        choices[#choices+1]={label=label or "Skip (no crafting)",detail="leave unbound"}
    end
    local function addByType(kind,exclude)
        for _,entry in ipairs(service:discoverByType(kind)) do
            if entry.name~=exclude then
                choices[#choices+1]={name=entry.name,label=entry.name,detail=kind}
            end
        end
    end
    local function bound(name,current)
        if current and name==current then return "[bound] "..name end
        return name
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
                if node.peripheral_name==choice.name then
                    choice.label="[added] "..choice.label
                    if node.label ~= node.peripheral_name then
                        choice.detail = "as \""..node.label.."\""
                    end
                end
            end
        end
    elseif step==5 then
        addSkip()
        addInventories(function(name,value)
            if value.dropoff and name==value.dropoff.peripheral_name then return false end
            if value.pickup and name==value.pickup.peripheral_name then return false end
            for _,node in ipairs(value.storage or {}) do
                if node.peripheral_name==name then return false end
            end
            return true
        end)
        for _,choice in ipairs(choices) do
            if choice.name and draft.craft_buffer and
                choice.name==draft.craft_buffer.peripheral_name then
                choice.label="[bound] "..choice.label
            end
        end
    elseif step==6 then
        addSkip()
        addByType("turtle")
        for _,choice in ipairs(choices) do
            if choice.name and draft.turtle and choice.name==draft.turtle.peripheral_name then
                choice.label="[bound] "..choice.label
            end
        end
    elseif step==7 or step==8 then
        local monitors=draft.monitors or {}
        addSkip(step==7 and "Skip (auto-detect)" or "Skip (no crafting monitor)")
        addByType("monitor", step==8 and monitors.main or nil)
        local current=step==7 and monitors.main or monitors.crafting
        for _,choice in ipairs(choices) do
            if choice.name then choice.label=bound(choice.name,current) end
        end
    elseif step==9 then
        choices={{label="Run validation and continue",detail="moves no items"}}
        local report=service:validate()
        for _,iss in ipairs(report.issues) do
            local row={label=iss.message,blocking=iss.blocking}
            if iss.code=="DUPLICATE_SUSPECTED" and iss.details and iss.details.nodes then
                row.confirm_nodes=iss.details.nodes
                row.detail="Enter confirms these are two different containers"
            elseif SETUP_ISSUE_STEP[iss.code] then
                row.jump_step=SETUP_ISSUE_STEP[iss.code]
                row.detail="Enter jumps to step "..row.jump_step
            end
            choices[#choices+1]=row
        end
    elseif step==10 then choices={{label="Save configuration and enable",detail="starts immediately"}} end
    return choices
end

local function setupSummary(service)
    local draft=service:draft()
    local function role(label,binding)
        return {label=label,detail=binding and binding.peripheral_name or "not set"}
    end
    local enabled,total=0,0
    for _,node in ipairs(draft.storage or {}) do
        total=total+1
        if node.enabled~=false then enabled=enabled+1 end
    end
    local monitors=draft.monitors or {}
    return {
        role("Drop-off",draft.dropoff),
        role("Pickup",draft.pickup),
        {label="Storage nodes",detail=enabled.." enabled / "..total.." total"},
        role("Craft buffer",draft.craft_buffer),
        role("Crafting turtle",draft.turtle),
        {label="Main monitor",detail=monitors.main or "auto-detect"},
        {label="Crafting monitor",detail=monitors.crafting or "not set"},
    }
end

local function syncSetup(coordinator,service,step,issues)
    local clamped=math.max(1,math.min(10,step))
    coordinator:command({type="SYNC_SETUP",step=clamped,
        choices=setupChoices(service,clamped),issues=issues or {},
        summary=clamped==10 and setupSummary(service) or nil})
    coordinator:redraw()
end

function Main.build(environment)
    local env=environment or {}
    local fsApi=env.fs or fs
    local peripheralApi=env.peripheral or peripheral
    local osApi=env.os or os
    local termApi=env.term or term
    local now=env.clock or clock(osApi)
    local root=env.data_root or "/storage/data"
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
    --
    -- Raised from 8: live measurement with slot_batch_limit=8 showed 6 of 7 batches hitting
    -- the steps=8 cap exactly, meaning batch_limit -- not slot_batch_limit -- was the
    -- binding constraint.
    local imports=ImportService.new({planner=Planner,transfer=transfer,alerts=alerts,
        transition=Lifecycle.transition,clock=now,
        slot_batch_limit=env.slot_batch_limit or 8, batch_limit=env.batch_limit or 16})
    local requests=Requests.new({planner=Planner,transfer=transfer,alerts=alerts,
        transition=Lifecycle.transition,clock=now,
        idGenerator=function(counter) return "request-"..osApi.getComputerID().."-"..counter end,
        batch_limit=env.batch_limit or 16,
        record_usage=function(key,timestamp)
            if coordinator then coordinator:recordItemRequested(key,timestamp) end
        end})
    local uiState=UI.initialState()
    if not config.configured then
        uiState.page,uiState.mode,uiState.setup_step="setup","setup",1
    end
    local monitors=(config.monitors or {})
    local monitorSurface=env.monitor_surface or
        boundMonitor(peripheralApi,monitors.main,true)
    local craftMonitorSurface=env.craft_monitor_surface or
        boundMonitor(peripheralApi,monitors.crafting,false)

    -- The palette is per surface, and a monitor bound after startup gets its own when the
    -- peripheral event lands. A surface with no palette API renders in stock colours.
    local terminalSurface=termApi.current and termApi.current() or termApi
    Theme.apply(terminalSurface)
    Theme.apply(monitorSurface)
    Theme.apply(craftMonitorSurface)

    -- Wrapped after the palette, because a window copies its parent's palette when it is
    -- created. Every render then lands in one blit instead of clearing the screen and
    -- repainting it in view of the player.
    terminalSurface=Buffer.wrap(terminalSurface)
    monitorSurface=Buffer.wrap(monitorSurface)
    craftMonitorSurface=Buffer.wrap(craftMonitorSurface)

    -- Built from the buffered surface, not the raw one: constructing the UI before the wrap
    -- would leave it drawing straight to the screen and the buffering would do nothing.
    local ui=UI.new(terminalSurface)

    -- Crafting is optional. Without a bound buffer and turtle the modules are simply not
    -- built, the coordinator sees no craft service, and everything else runs unchanged.
    local crafts, link
    local recipes=RecipeRepo.new({custom=load(store,fsApi,root,"custom_recipes",
        RecipeRepo.validateCustom,nil)})
    local craftPrefs=CraftPrefs.new(load(store,fsApi,root,"craft_prefs",
        CraftPrefs.validate,CraftPrefs.default()))
    if config.configured and config.craft_buffer and config.turtle then
        -- A second importer instance, private to the buffer, so draining the buffer and
        -- draining Drop-off never share in-flight state.
        local bufferImports=ImportService.new({planner=Planner,transfer=transfer,alerts=alerts,
            transition=Lifecycle.transition,clock=now,slot_batch_limit=env.slot_batch_limit or 8,
            batch_limit=env.batch_limit or 16})
        local buffer=CraftBuffer.new({imports=bufferImports,adapter=adapter})
        link=TurtleLink.new({rednet=env.rednet or rednet,peripheral=peripheralApi,
            name=config.turtle.peripheral_name})
        crafts=CraftService.new({planner=CraftPlanner,repo=recipes,prefs=craftPrefs,
            requests=requests,buffer=buffer,link=link,alerts=alerts,
            transition=Lifecycle.transition,clock=now,
            idGenerator=function(counter) return "craft-"..osApi.getComputerID().."-"..counter end,
            stack_limit=function(itemId)
                local details=metadata.items and metadata.items[Identity.key(itemId,nil)]
                return details and details.max_count or 64
            end})
    end
    local report
    local function onEffect(effect,active)
        if effect.type=="OPEN_SETUP" then syncSetup(active,setup,1)
        elseif effect.type=="CANCEL_SETUP" then setup:cancel()
        elseif effect.type=="SETUP_BACK" then syncSetup(active,setup,(effect.step or 1)-1)
        elseif effect.type=="SETUP_NEXT" then
            local step=effect.step or 1
            local draft=setup:draft()
            if step==2 and not draft.dropoff then
                syncSetup(active,setup,2,
                    {{message="Select a Drop-off inventory, then press Enter",blocking=true}})
            elseif step==3 and not draft.pickup then
                syncSetup(active,setup,3,
                    {{message="Select a Pickup inventory, then press Enter",blocking=true}})
            elseif step==9 then
                report=setup:validate()
                syncSetup(active,setup,report.ok and 10 or 9,report.issues)
            else
                local nextStep=math.min(10,step+1)
                if nextStep==9 then report=setup:validate() end
                syncSetup(active,setup,nextStep,report and report.issues)
            end
        elseif effect.type=="RENAME_CONFIRM" then
            local text=tostring(effect.text or "")
            setup:updateStorage(effect.node_id,{label=text~="" and text or nil})
            syncSetup(active,setup,4)
        elseif effect.type=="RENAME_CANCEL" then
            syncSetup(active,setup,4)
        elseif effect.type=="RENAME_STORAGE_REQUEST" then
            local choices=setupChoices(setup,4)
            local choice=choices[effect.index or 1]
            local found
            if choice then
                for _,node in ipairs(setup:draft().storage or {}) do
                    if node.peripheral_name==choice.name then found=node; break end
                end
            end
            if found then
                active:command({type="OPEN_RENAME",node_id=found.id,text=found.label})
                active:redraw()
            end
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
                if found then
                    setup:removeStorage(found.id)
                    syncSetup(active,setup,4)
                else
                    local node=setup:addStorage(choice.name,choice.name)
                    active:command({type="OPEN_RENAME",node_id=node.id,text=node.label})
                    active:redraw()
                end
            elseif (step==5 or step==6 or step==7 or step==8) and choice then
                -- choice.name is nil for the Skip entry, which clears the binding.
                local roles={[5]="craft_buffer",[6]="turtle",
                    [7]="monitor_main",[8]="monitor_crafting"}
                setup:assign(roles[step],choice.name)
                syncSetup(active,setup,step+1)
            elseif step==9 then
                if choice and choice.confirm_nodes then
                    setup:confirmDistinct(choice.confirm_nodes[1],choice.confirm_nodes[2])
                    syncSetup(active,setup,9,{})
                elseif choice and choice.jump_step then
                    syncSetup(active,setup,choice.jump_step,{})
                else
                    report=setup:validate()
                    syncSetup(active,setup,report.ok and 10 or 9,{})
                end
            elseif step==10 and report and report.ok then
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
        -- Storage scanning is pure Lua: Scanner:begin makes the one list() call and step()
        -- only walks the table it returned, so this budget is not bounding peripheral work,
        -- it is bounding how many slots are examined per work-loop tick -- and every tick
        -- costs a sleep. On a Colossal Chest holding thousands of occupied slots, 512 turned
        -- one scan into tens of ticks, and a Drop-off import pays two scans per batch (the
        -- planning gate and the verification gate). That fixed cost, not batch_limit, is what
        -- bounded import throughput: raising batch_limit only stretched the gap between
        -- batches because each batch paid the same full-chest scan regardless.
        --
        -- dropoff_scan_budget stays small on purpose. Drop-off scans DO make a getItemDetail
        -- call per occupied slot, so that budget bounds real peripheral work and raising it
        -- would cost a server tick per extra slot.
        scan_budget=env.scan_budget or 4096,dropoff_scan_budget=32,
        scan_refresh_interval=env.scan_refresh_interval,
        lifecycle=Lifecycle,recovery=recovery,imports=imports,requests=requests,alerts=alerts,
        crafts=crafts,recipes=recipes,craft_prefs=craftPrefs,craft_planner=CraftPlanner,
        turtle_link=link,
        craft_monitor=CraftMonitor,
        monitor=Monitor,monitor_surface=monitorSurface,
        craft_monitor_surface=craftMonitorSurface,on_effect=onEffect,
        intervals={heartbeat=0.25}})

    if not config.configured then syncSetup(coordinator,setup,1) end
    return coordinator,{store=store,setup=setup,transfer=transfer,recovery=recovery,
        imports=imports,requests=requests,alerts=alerts,adapter=adapter,
        crafts=crafts,recipes=recipes,craft_prefs=craftPrefs}
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
    -- setPaletteColour changes the terminal, not the program. Leaving InvOS colours behind
    -- looks like a corrupted computer rather than a program that forgot to tidy up.
    pcall(Theme.restore, term.current and term.current() or term)
    if not ok then printError("InvOS failed: "..tostring(reason)) end
end

return Main