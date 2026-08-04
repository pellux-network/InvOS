local M={files={
    "startup.lua",
    "colossal/main.lua",
    "colossal/deployment_manifest.lua",
    "colossal/app/alerts.lua",
    "colossal/app/backup.lua",
    "colossal/app/craft_buffer.lua",
    "colossal/app/craft_service.lua",
    "colossal/app/coordinator.lua",
    "colossal/app/import_service.lua",
    "colossal/app/keymap.lua",
    "colossal/app/lifecycle.lua",
    "colossal/app/monitor.lua",
    "colossal/app/requests.lua",
    "colossal/app/recovery.lua",
    "colossal/app/search.lua",
    "colossal/app/turtle_link.lua",
    "colossal/app/setup.lua",
    "colossal/app/ui.lua",
    "colossal/core/craft_planner.lua",
    "colossal/core/craft_prefs.lua",
    "colossal/core/identity.lua",
    "colossal/core/index.lua",
    "colossal/core/inventory_adapter.lua",
    "colossal/core/planner.lua",
    "colossal/core/reconciliation.lua",
    "colossal/core/recipe_repo.lua",
    "colossal/core/registry.lua",
    "colossal/core/scanner.lua",
    "colossal/core/transfer.lua",
    "colossal/shared/codec.lua",
    "colossal/shared/runtime.lua",
    "colossal/shared/store.lua",
    -- The generated crafting recipe pack. These are build artifacts, not mutable
    -- state, which is why they live outside colossal/data/ and ship like code.
    -- Regenerate with tools/recipe_import.py; never hand-edit.
    -- The shard list must match the converter's --shards default (4). Changing one
    -- without the other either strands a shard on the host or names a missing file.
    "colossal/recipes/items.lua",
    "colossal/recipes/index.lua",
    "colossal/recipes/tags.lua",
    "colossal/recipes/pack_01.lua",
    "colossal/recipes/pack_02.lua",
    "colossal/recipes/pack_03.lua",
    "colossal/recipes/pack_04.lua",
}}

local listed={};for _,path in ipairs(M.files) do listed[path]=true end
function M.allowed(path) return listed[tostring(path):gsub("\\","/")] == true end

return M
