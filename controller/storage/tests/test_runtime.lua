local Runtime = require("shared.runtime")
local T = require("tests.mock_cc")

return {
    { name = "safeCall converts exceptions to stable reasons", run = function()
        local ok, reason = Runtime.safeCall("scan main", function() error("cable gone") end)
        T.equal(ok, nil)
        T.contains(reason, "scan main")
        T.contains(reason, "cable gone")
    end },
    { name = "safeCall preserves multiple successful values", run = function()
        local ok, first, second = Runtime.safeCall("values", function() return 7, "ok" end)
        T.equal(ok, true)
        T.equal(first, 7)
        T.equal(second, "ok")
    end },
    { name = "installation rejects a moved computer", run = function()
        local fake = {
            getComputerID = function() return 9 end,
            getComputerLabel = function() return "Other" end,
        }
        local ok, reason = Runtime.verifyInstallation(fake,
            { computer_id = 4, computer_label = "StorageController" })
        T.equal(ok, nil)
        T.contains(reason, "expected #4 StorageController")
    end },
    { name = "installation accepts the recorded computer", run = function()
        local fake = {
            getComputerID = function() return 4 end,
            getComputerLabel = function() return "StorageController" end,
        }
        T.equal(Runtime.verifyInstallation(fake,
            { computer_id = 4, computer_label = "StorageController" }), true)
    end },
}
