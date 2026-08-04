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
        T.equal(seen["colossal/app/recovery.lua"],true)
        T.equal(seen["colossal/core/reconciliation.lua"],true)
    end},
    {name="deployment policy rejects development artifacts",run=function()
        for _,path in ipairs({"README.md",".git/config","colossal/tests/run.lua",
            "colossal/data/config.lua","docs/operations.md","copy-helper.ps1"}) do
            T.equal(Manifest.allowed(path),false,path)
        end
    end},
    {name="deployment manifest carries the recipe pack and crafting modules",run=function()
        local seen={}
        for _,path in ipairs(Manifest.files) do seen[path]=true end
        T.equal(seen["colossal/core/recipe_repo.lua"],true)
        T.equal(seen["colossal/core/craft_prefs.lua"],true)
        T.equal(seen["colossal/recipes/items.lua"],true)
        T.equal(seen["colossal/recipes/index.lua"],true)
        T.equal(seen["colossal/recipes/tags.lua"],true)
        T.equal(seen["colossal/recipes/pack_01.lua"],true)
    end},
    {name="hand-edited crafting state and host tooling are never deployed",run=function()
        for _,path in ipairs({"colossal/data/custom_recipes.lua",
            "colossal/data/craft_prefs.lua","tools/recipe_import.py",
            "tools/recipe_pack.py"}) do
            T.equal(Manifest.allowed(path),false,path)
        end
    end},
    -- The manifest names shard files explicitly, so it and the converter's --shards
    -- default have to agree. A mismatch either strands a shard on the host or names
    -- a file that does not exist, and neither shows up until deployment.
    {name="every manifest path exists on disk",run=function()
        local missing={}
        for _,path in ipairs(Manifest.files) do
            local handle=io.open(path,"r")
            if handle then handle:close() else missing[#missing+1]=path end
        end
        T.equal(#missing,0,"manifest names files that do not exist: "..table.concat(missing,", "))
    end},
    {name="every generated shard on disk is named in the manifest",run=function()
        local listed={}
        for _,path in ipairs(Manifest.files) do listed[path]=true end
        local index=require("recipes.index")
        for shard=1,index.shard_count do
            local path=("colossal/recipes/pack_%02d.lua"):format(shard)
            T.equal(listed[path],true,"shard missing from manifest: "..path)
        end
    end},
}
