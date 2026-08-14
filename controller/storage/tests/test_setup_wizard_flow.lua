keys = keys or {}
keys.up=keys.up or 200; keys.down=keys.down or 208; keys.enter=keys.enter or 28
keys.left=keys.left or 203; keys.right=keys.right or 205
keys.f10=keys.f10 or 68; keys.r=keys.r or 19; keys.backspace=keys.backspace or 14
keys.delete=keys.delete or 211

local Main = require("main")
local T = require("tests.mock_cc")

local function chestInventory(size)
    return {
        size=function() return size end,
        list=function() return {} end,
        getItemLimit=function() return 64 end,
        getItemDetail=function() return nil end,
        pushItems=function() return 0 end,
        pullItems=function() return 0 end,
    }
end

-- Two discoverable inventories (drop, pick) is enough for the Drop-off/Pickup guard
-- tests; storage/rename tests add a third (a).
local function environment(inventories)
    inventories = inventories or {drop=chestInventory(27), pick=chestInventory(27)}
    local surface = T.recordingSurface(51, 19)
    return {
        fs=T.memoryFs(), data_root="data",
        peripheral={
            getNames=function() local n={}; for name in pairs(inventories) do n[#n+1]=name end; return n end,
            hasType=function(name,kind) return inventories[name]~=nil and kind=="inventory" end,
            getMethods=function() return {"size","list","getItemDetail","getItemLimit","pushItems","pullItems"} end,
            wrap=function(name) return inventories[name] end,
            find=function() return nil end,
        },
        os={getComputerID=function() return 17 end,getComputerLabel=function() return "Test" end,
            epoch=function() return 1000 end},
        term={current=function() return surface end}, clock=function() return 1000 end,
        textutils={serialize=function() return "{}" end, unserialize=function() return {} end},
        surface=surface,
    }
end

return {
    {name="Right on Drop-off does not advance without a selection, and shows a hint",run=function()
        local coordinator = Main.build(environment())
        T.equal(coordinator:viewModel().ui.setup_step, 1)
        coordinator:handle({"key", keys.right}) -- discovery -> step 2
        T.equal(coordinator:viewModel().ui.setup_step, 2)
        coordinator:handle({"key", keys.right}) -- no dropoff chosen yet
        local model = coordinator:viewModel()
        T.equal(model.ui.setup_step, 2, "must not advance past an unassigned Drop-off")
        T.truthy(model.ui.setup_issues[1])
        T.contains(model.ui.setup_issues[1].message, "Drop-off")
    end},
    {name="Right after selecting Drop-off with Enter advances normally",run=function()
        local coordinator = Main.build(environment())
        coordinator:handle({"key", keys.right}) -- step 2
        coordinator:handle({"key", keys.enter}) -- assigns first discovered inventory, advances to 3
        T.equal(coordinator:viewModel().ui.setup_step, 3)
        coordinator:handle({"key", keys.right}) -- no pickup chosen yet
        T.equal(coordinator:viewModel().ui.setup_step, 3, "must not advance past an unassigned Pickup")
    end},
    {name="Right on Validate runs validation instead of skipping straight to Review",run=function()
        local coordinator = Main.build(environment())
        -- Walk to step 9 with dropoff/pickup assigned but no storage nodes, so validate()
        -- stays blocking (MISSING_STORAGE) and we can see Right refuse to skip past it.
        coordinator:handle({"key", keys.right}) -- 1 -> 2
        coordinator:handle({"key", keys.enter}) -- assign dropoff, -> 3
        coordinator:handle({"key", keys.enter}) -- assign pickup, -> 4
        coordinator:handle({"key", keys.right}) -- 4 -> 5 (no storage added: MISSING_STORAGE)
        coordinator:handle({"key", keys.right}) -- 5 -> 6
        coordinator:handle({"key", keys.right}) -- 6 -> 7
        coordinator:handle({"key", keys.right}) -- 7 -> 8
        coordinator:handle({"key", keys.right}) -- 8 -> 9 (auto-validates on arrival)
        T.equal(coordinator:viewModel().ui.setup_step, 9)
        coordinator:handle({"key", keys.right}) -- must re-validate, not jump to 10
        local model = coordinator:viewModel()
        T.equal(model.ui.setup_step, 9, "blocking issues must keep Right from reaching Review")
        local sawMissingStorage = false
        for _, issue in ipairs(model.ui.setup_issues) do
            if issue.message and issue.message:find("storage", 1, true) then sawMissingStorage = true end
        end
        T.truthy(sawMissingStorage)
    end},
    {name="Validate lists every issue and jumps to the step that fixes it",run=function()
        local coordinator = Main.build(environment())
        coordinator:handle({"key", keys.right}) -- 1 -> 2
        coordinator:handle({"key", keys.enter}) -- assign dropoff, -> 3
        coordinator:handle({"key", keys.enter}) -- assign pickup, -> 4
        for _ = 4, 8 do coordinator:handle({"key", keys.right}) end -- -> 9, auto-validates
        local model = coordinator:viewModel()
        T.equal(model.ui.setup_step, 9)
        local jumpIndex
        for index, choice in ipairs(model.ui.setup_choices) do
            if choice.jump_step == 4 then jumpIndex = index end
        end
        T.truthy(jumpIndex, "MISSING_STORAGE should offer a jump to step 4")
        for _ = 2, jumpIndex do coordinator:handle({"key", keys.down}) end
        coordinator:handle({"key", keys.enter})
        T.equal(coordinator:viewModel().ui.setup_step, 4)
    end},
    {name="Validate resolves a suspected duplicate in place via confirm_nodes",run=function()
        local inventories = {drop=chestInventory(27), pick=chestInventory(27),
            a=chestInventory(3075), b=chestInventory(3075)}
        local coordinator, services = Main.build(environment(inventories))
        local setup = services.setup
        setup:assign("dropoff", "drop")
        setup:assign("pickup", "pick")
        setup:addStorage("a", "Vault A", 1)
        setup:addStorage("b", "Vault B", 2)
        coordinator:command({type="SYNC_SETUP", step=9, choices={}, issues={}})
        coordinator:handle({"key", keys.enter}) -- run validation
        local model = coordinator:viewModel()
        T.equal(model.ui.setup_step, 9)
        local confirmIndex
        for index, choice in ipairs(model.ui.setup_choices) do
            if choice.confirm_nodes then confirmIndex = index end
        end
        T.truthy(confirmIndex, "identical empty chests should surface a duplicate-confirm row")
        for _ = 2, confirmIndex do coordinator:handle({"key", keys.down}) end
        coordinator:handle({"key", keys.enter})
        model = coordinator:viewModel()
        T.equal(model.ui.setup_step, 9, "confirming stays on Validate")
        local stillSuspected = false
        for _, choice in ipairs(model.ui.setup_choices) do
            if choice.confirm_nodes then stillSuspected = true end
        end
        T.equal(stillSuspected, false, "the pair is no longer flagged as suspected after confirming")
    end},
    {name="Review summarizes the bound roles before save",run=function()
        local inventories = {drop=chestInventory(27), pick=chestInventory(27), a=chestInventory(3075)}
        local coordinator, services = Main.build(environment(inventories))
        local setup = services.setup
        setup:assign("dropoff", "drop")
        setup:assign("pickup", "pick")
        setup:addStorage("a", "Vault A", 1)
        coordinator:command({type="SYNC_SETUP", step=9, choices={}, issues={}})
        coordinator:handle({"key", keys.enter}) -- run validation, advances to 10 (ok)
        local model = coordinator:viewModel()
        T.equal(model.ui.setup_step, 10)
        local byLabel = {}
        for _, row in ipairs(model.ui.setup_summary) do byLabel[row.label] = row.detail end
        T.equal(byLabel["Drop-off"], "drop")
        T.equal(byLabel["Pickup"], "pick")
        T.equal(byLabel["Storage nodes"], "1 enabled / 1 total")
        T.equal(byLabel["Craft buffer"], "not set")
    end},
}
