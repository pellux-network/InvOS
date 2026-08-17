local M={files={
    "startup.lua",
    "storage/main.lua",
    "storage/deployment_manifest.lua",
    "storage/app/alerts.lua",
    "storage/app/backup.lua",
    "storage/app/buffer.lua",
    "storage/app/craft_buffer.lua",
    "storage/app/craft_monitor.lua",
    "storage/app/craft_service.lua",
    "storage/app/coordinator.lua",
    "storage/app/draw.lua",
    "storage/app/help.lua",
    "storage/app/import_service.lua",
    "storage/app/keymap.lua",
    "storage/app/layout.lua",
    "storage/app/lifecycle.lua",
    "storage/app/match.lua",
    "storage/app/monitor.lua",
    "storage/app/requests.lua",
    "storage/app/recovery.lua",
    "storage/app/search.lua",
    "storage/app/turtle_link.lua",
    "storage/app/setup.lua",
    "storage/app/splash.lua",
    "storage/app/theme.lua",
    "storage/app/ui.lua",
    "storage/app/updater.lua",
    "storage/core/craft_planner.lua",
    "storage/core/craft_prefs.lua",
    "storage/core/identity.lua",
    "storage/core/index.lua",
    "storage/core/inventory_adapter.lua",
    "storage/core/planner.lua",
    "storage/core/reconciliation.lua",
    "storage/core/recipe_repo.lua",
    "storage/core/registry.lua",
    "storage/core/scanner.lua",
    "storage/core/storage_scope.lua",
    "storage/core/transfer.lua",
    "storage/shared/codec.lua",
    "storage/shared/runtime.lua",
    "storage/shared/store.lua",
    -- The generated crafting recipe pack under storage/recipes/ is deliberately NOT
    -- listed here. It is per-deployment data derived from one modpack's own game, not
    -- source, so it is gitignored and never fetched by install.lua; tools/deploy.py
    -- pushes it separately, outside this allow-list, if a local copy exists.
}}

local listed={};for _,path in ipairs(M.files) do listed[path]=true end
function M.allowed(path) return listed[tostring(path):gsub("\\","/")] == true end

return M
