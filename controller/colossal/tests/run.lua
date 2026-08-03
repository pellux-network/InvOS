package.path = "colossal/?.lua;colossal/?/init.lua;" .. package.path

local defaultModules = {
    "tests.test_startup",
    "tests.test_runtime",
    "tests.test_store",
    "tests.test_store_failures",
    "tests.test_backup",
    "tests.test_identity",
    "tests.test_registry",
    "tests.test_lifecycle",
    "tests.test_scanner",
    "tests.test_index",
    "tests.test_planner",
    "tests.test_reconciliation",
    "tests.test_transfer",
    "tests.test_recovery",
    "tests.test_recovery_service",
    "tests.test_alerts",
    "tests.test_import_service",
    "tests.test_requests",
    "tests.test_service_recovery",
    "tests.test_search",
    "tests.test_keymap",
    "tests.test_ui",
    "tests.test_ui_layout",
    "tests.test_ui_purity",
    "tests.test_monitor",
    "tests.test_setup",
    "tests.test_setup_validation",
    "tests.test_setup_recovery",
    "tests.test_setup_duplicates",
    "tests.test_setup_ui",
    "tests.test_inventory_adapter",
    "tests.test_coordinator",
    "tests.test_coordinator_transfers",
    "tests.test_operator_controls",
    "tests.test_responsiveness",
    "tests.test_error_recovery",
    "tests.test_main",
    "tests.test_coordinator_epoch_gate",
    "tests.test_import_freshness",
    "tests.test_acceptance",
    "tests.test_deployment",
    "tests.test_status_refresh",
    "tests.test_transfer_generation",
    "tests.test_pickup_recovery",
    "tests.test_transfer_rescan_race",
    "tests.test_node_capacity_view",
    "tests.test_pickup_preflight",
    "tests.test_request_replan",
    "tests.test_hot_paths",
    "tests.test_transfer_batch",
    "tests.test_reconciliation_many",
    "tests.test_transfer_multibatch",
}

local modules = {}
if type(arg) == "table" and #arg > 0 then
    for index = 1, #arg do modules[#modules + 1] = arg[index] end
else
    modules = defaultModules
end

local passed, failed = 0, 0
for _, moduleName in ipairs(modules) do
    local loaded, tests = pcall(require, moduleName)
    if not loaded then
        failed = failed + 1
        print("FAIL " .. moduleName .. " load: " .. tostring(tests))
    else
        for _, test in ipairs(tests) do
            local ok, reason = pcall(test.run)
            if ok then
                passed = passed + 1
                print("PASS " .. test.name)
            else
                failed = failed + 1
                print("FAIL " .. test.name .. ": " .. tostring(reason))
            end
        end
    end
end

print(("RESULT %d passed, %d failed"):format(passed, failed))
if failed > 0 then error("test suite failed", 0) end
