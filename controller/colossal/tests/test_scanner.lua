local Scanner = require("core.scanner")
local T = require("tests.mock_cc")

local function peripheralFor(inventory)
    return {
        wrap = function(name)
            if name == "missing" then return nil end
            return inventory
        end,
    }
end

local function makeInventory(listed, size, detail)
    local calls = { size = 0, list = 0, detail = 0 }
    return {
        calls = calls,
        size = function() calls.size = calls.size + 1; return size or 3075 end,
        list = function() calls.list = calls.list + 1; return listed end,
        getItemDetail = function(slot)
            calls.detail = calls.detail + 1
            return detail and detail(slot) or nil
        end,
    }
end

return {
    { name = "scanner validates a large sparse inventory in bounded steps", run = function()
        local listed = {}
        for index = 1, 70 do
            listed[index * 5] = { name = "minecraft:stone", count = index, nbt = nil }
        end
        listed[417] = { name = "minecraft:cobblestone", count = 64, nbt = nil }
        local inventory = makeInventory(listed, 3075)
        local scanner = Scanner.new(peripheralFor(inventory), function() return 1234 end)
        local scan = scanner:begin({ id = "main", peripheral_name = "colossal_0" })
        local done, snapshot = scanner:step(scan, 32)
        T.equal(done, false)
        T.equal(snapshot, nil)
        T.equal(inventory.calls.list, 1)
        while not done do done, snapshot = scanner:step(scan, 32) end
        T.equal(inventory.calls.list, 1)
        T.equal(snapshot.size, 3075)
        T.equal(snapshot.epoch, 1234)
        T.equal(snapshot.occupied, 71)
        T.equal(snapshot.slots[417].name, "minecraft:cobblestone")
        T.equal(snapshot.slots[417].count, 64)
        T.equal(snapshot.health, "READY")
    end },
    { name = "scanner result does not retain mutable peripheral item tables", run = function()
        local listed = { [4] = { name = "minecraft:stone", count = 12 } }
        local scanner = Scanner.new(peripheralFor(makeInventory(listed, 27)), function() return 1 end)
        local scan = scanner:begin({ id = "dropoff", peripheral_name = "drop" })
        local done, snapshot = scanner:step(scan, 8)
        T.equal(done, true)
        listed[4].count = 1
        listed[4].name = "minecraft:dirt"
        T.equal(snapshot.slots[4].count, 12)
        T.equal(snapshot.slots[4].name, "minecraft:stone")
    end },
    { name = "scanner turns size exceptions into structured node errors", run = function()
        local inventory = {
            size = function() error("cable\ndisconnected") end,
            list = function() return {} end,
        }
        local scanner = Scanner.new(peripheralFor(inventory), function() return 1 end)
        local scan = scanner:begin({ id = "main", peripheral_name = "colossal_0" })
        local done, snapshot, reason = scanner:step(scan, 8)
        T.equal(done, true)
        T.equal(snapshot, nil)
        T.equal(reason.code, "PERIPHERAL_ERROR")
        T.equal(reason.node_id, "main")
        T.contains(reason.message, "size main")
        T.equal(reason.message:find("\n", 1, true), nil)
    end },
    { name = "scanner turns list detach into a structured node error", run = function()
        local inventory = {
            size = function() return 27 end,
            list = function() error("peripheral detached") end,
        }
        local scanner = Scanner.new(peripheralFor(inventory), function() return 1 end)
        local scan = scanner:begin({ id = "dropoff", peripheral_name = "drop" })
        local done, _, reason = scanner:step(scan, 8)
        T.equal(done, true)
        T.equal(reason.code, "PERIPHERAL_ERROR")
        T.contains(reason.message, "list dropoff")
    end },
    { name = "scanner rejects malformed sparse entries without throwing", run = function()
        local cases = {
            { listed = { [0] = { name = "minecraft:stone", count = 1 } }, code = "INVALID_SLOT" },
            { listed = { [1] = { count = 1 } }, code = "INVALID_ITEM" },
            { listed = { [1] = { name = "minecraft:stone", count = 0 } }, code = "INVALID_COUNT" },
            { listed = { [1] = { name = "minecraft:stone", count = 1, nbt = 7 } }, code = "INVALID_NBT" },
        }
        for _, case in ipairs(cases) do
            local scanner = Scanner.new(peripheralFor(makeInventory(case.listed, 27)), function() return 1 end)
            local scan = scanner:begin({ id = "test", peripheral_name = "inventory" })
            local done, snapshot, reason = scanner:step(scan, 8)
            T.equal(done, true)
            T.equal(snapshot, nil)
            T.equal(reason.code, case.code)
        end
    end },
    { name = "Drop-off scan records authoritative item stack limits", run = function()
        local listed={ [2]={name="the_vault:chest_upgrade_tool",count=1} }
        local inventory=makeInventory(listed,27,function(slot)
            T.equal(slot,2)
            return {name="the_vault:chest_upgrade_tool",count=1,maxCount=1}
        end)
        local scanner=Scanner.new(peripheralFor(inventory),function() return 5 end)
        local done,snapshot=scanner:step(scanner:begin({id="drop",role="dropoff",
            peripheral_name="drop"}),8)
        T.equal(done,true)
        T.equal(snapshot.slots[2].max_count,1)
        T.equal(inventory.calls.detail,1)
    end },
    { name = "Storage scan never requests per-item details", run = function()
        local inventory=makeInventory({[1]={name="minecraft:stone",count=64}},3075,
            function() error("storage detail must not be called") end)
        local scanner=Scanner.new(peripheralFor(inventory),function() return 5 end)
        local done,snapshot=scanner:step(scanner:begin({id="main",role="storage",
            peripheral_name="colossal"}),8)
        T.equal(done,true)
        T.equal(snapshot.slots[1].count,64)
        T.equal(inventory.calls.detail,0)
    end },
    { name = "Drop-off rejects unavailable mismatched and invalid details", run = function()
        local base={name="minecraft:ender_pearl",count=1,nbt="same"}
        local cases={
            {detail=function() error("detached") end,code="PERIPHERAL_ERROR"},
            {detail=function() return nil end,code="DETAIL_MISSING"},
            {detail=function() return {name="minecraft:stone",count=1,nbt="same",maxCount=16} end,
                code="DETAIL_MISMATCH"},
            {detail=function() return {name=base.name,count=2,nbt=base.nbt,maxCount=16} end,
                code="DETAIL_MISMATCH"},
            {detail=function() return {name=base.name,count=base.count,nbt=base.nbt,maxCount=0} end,
                code="INVALID_MAX_COUNT"},
        }
        for _,case in ipairs(cases) do
            local inventory=makeInventory({[1]=base},27,case.detail)
            local scanner=Scanner.new(peripheralFor(inventory),function() return 5 end)
            local done,snapshot,reason=scanner:step(scanner:begin({id="drop",role="dropoff",
                peripheral_name="drop"}),8)
            T.equal(done,true)
            T.equal(snapshot,nil)
            T.equal(reason and reason.code,case.code)
        end
    end },
    { name = "scanner reports a missing wrapped peripheral", run = function()
        local scanner = Scanner.new(peripheralFor({}), function() return 1 end)
        local scan = scanner:begin({ id = "missing", peripheral_name = "missing" })
        local done, _, reason = scanner:step(scan, 8)
        T.equal(done, true)
        T.equal(reason.code, "PERIPHERAL_MISSING")
    end },
}
