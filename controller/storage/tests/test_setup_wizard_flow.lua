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
}
