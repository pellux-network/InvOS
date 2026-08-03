local M={files={
    "startup.lua",
    "colossal/main.lua",
    "colossal/deployment_manifest.lua",
    "colossal/app/alerts.lua",
    "colossal/app/backup.lua",
    "colossal/app/coordinator.lua",
    "colossal/app/import_service.lua",
    "colossal/app/keymap.lua",
    "colossal/app/lifecycle.lua",
    "colossal/app/monitor.lua",
    "colossal/app/requests.lua",
    "colossal/app/recovery.lua",
    "colossal/app/search.lua",
    "colossal/app/setup.lua",
    "colossal/app/ui.lua",
    "colossal/core/identity.lua",
    "colossal/core/index.lua",
    "colossal/core/inventory_adapter.lua",
    "colossal/core/planner.lua",
    "colossal/core/reconciliation.lua",
    "colossal/core/registry.lua",
    "colossal/core/scanner.lua",
    "colossal/core/transfer.lua",
    "colossal/shared/codec.lua",
    "colossal/shared/runtime.lua",
    "colossal/shared/store.lua",
}}

local listed={};for _,path in ipairs(M.files) do listed[path]=true end
function M.allowed(path) return listed[tostring(path):gsub("\\","/")] == true end

return M
