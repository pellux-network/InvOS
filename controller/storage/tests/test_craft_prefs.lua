local CraftPrefs = require("core.craft_prefs")
local T = require("tests.mock_cc")

return {
    {name="preferences default to empty and validate",run=function()
        local value = CraftPrefs.default()
        T.equal(CraftPrefs.validate(value), true)
        T.equal(next(value.tags), nil)
        T.equal(next(value.recipes), nil)
    end},
    {name="a pinned tag choice round-trips",run=function()
        local prefs = CraftPrefs.new(CraftPrefs.default())
        prefs:pinTag("minecraft:planks", "minecraft:oak_planks")
        T.equal(prefs:tagChoice("minecraft:planks"), "minecraft:oak_planks")
        T.equal(prefs:tagChoice("minecraft:logs"), nil)
        T.equal(CraftPrefs.validate(prefs:value()), true)
    end},
    {name="a pinned recipe choice round-trips",run=function()
        local prefs = CraftPrefs.new(CraftPrefs.default())
        prefs:pinRecipe("minecraft:chest", "custom:chest")
        T.equal(prefs:recipeChoice("minecraft:chest"), "custom:chest")
    end},
    {name="pinning again replaces the previous choice",run=function()
        local prefs = CraftPrefs.new(CraftPrefs.default())
        prefs:pinTag("minecraft:planks", "minecraft:oak_planks")
        prefs:pinTag("minecraft:planks", "minecraft:birch_planks")
        T.equal(prefs:tagChoice("minecraft:planks"), "minecraft:birch_planks")
    end},
    {name="unpinning removes a choice",run=function()
        local prefs = CraftPrefs.new(CraftPrefs.default())
        prefs:pinTag("minecraft:planks", "minecraft:oak_planks")
        prefs:unpinTag("minecraft:planks")
        T.equal(prefs:tagChoice("minecraft:planks"), nil)
        prefs:pinRecipe("minecraft:chest", "custom:chest")
        prefs:unpinRecipe("minecraft:chest")
        T.equal(prefs:recipeChoice("minecraft:chest"), nil)
    end},
    {name="the store never hands out its internal table",run=function()
        local prefs = CraftPrefs.new(CraftPrefs.default())
        prefs:pinTag("minecraft:planks", "minecraft:oak_planks")
        local copy = prefs:value()
        copy.tags["minecraft:planks"] = "tampered"
        T.equal(prefs:tagChoice("minecraft:planks"), "minecraft:oak_planks")
    end},
    {name="the store does not alias the table it was constructed from",run=function()
        local source = CraftPrefs.default()
        source.tags["minecraft:planks"] = "minecraft:oak_planks"
        local prefs = CraftPrefs.new(source)
        source.tags["minecraft:planks"] = "tampered"
        T.equal(prefs:tagChoice("minecraft:planks"), "minecraft:oak_planks")
    end},
    {name="validation rejects malformed preference files",run=function()
        for _, bad in ipairs({
            {schema=2, tags={}, recipes={}},
            {schema=1, tags="no", recipes={}},
            {schema=1, tags={}, recipes="no"},
            {schema=1, tags={[1]="x"}, recipes={}},
            {schema=1, tags={a=2}, recipes={}},
            {schema=1, tags={a=""}, recipes={}},
        }) do
            T.equal(CraftPrefs.validate(bad), nil)
        end
        T.equal(CraftPrefs.validate(CraftPrefs.default()), true)
    end},
    {name="a corrupt preference file degrades to empty rather than failing",run=function()
        for _, bad in ipairs({"nonsense", {schema=9}, {}}) do
            local prefs = CraftPrefs.new(bad)
            T.equal(prefs:tagChoice("minecraft:planks"), nil)
            T.equal(CraftPrefs.validate(prefs:value()), true)
        end
    end},
}
