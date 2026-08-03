local Manifest=require("deployment_manifest")
local T=require("tests.mock_cc")

return {
    {name="deployment manifest contains only runtime Lua files",run=function()
        local seen={}
        for _,path in ipairs(Manifest.files) do
            T.equal(path:match("%.lua$")~=nil,true)
            T.equal(path=="startup.lua" or path:match("^colossal/")~=nil,true)
            T.equal(path:find("/tests/",1,true),nil)
            T.equal(path:find("data",1,true),nil)
            T.equal(seen[path],nil);seen[path]=true
        end
        T.equal(seen["startup.lua"],true)
        T.equal(seen["colossal/main.lua"],true)
        T.equal(seen["colossal/deployment_manifest.lua"],true)
    end},
    {name="deployment policy rejects development artifacts",run=function()
        for _,path in ipairs({"README.md",".git/config","colossal/tests/run.lua",
            "colossal/data/config.lua","docs/operations.md","copy-helper.ps1"}) do
            T.equal(Manifest.allowed(path),false,path)
        end
    end},
}
