-- The crafting turtle is a second live computer with its own deployment allow-list.
-- Paths are relative to turtle/. It must never receive controller files, tests or docs.
local M={files={
    "startup.lua",
    "deployment_manifest.lua",
    "crafter/executor.lua",
}}

local listed={};for _,path in ipairs(M.files) do listed[path]=true end
function M.allowed(path) return listed[tostring(path):gsub("\\","/")] == true end

return M
