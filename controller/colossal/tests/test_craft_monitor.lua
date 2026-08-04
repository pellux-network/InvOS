local CraftMonitor = require("app.craft_monitor")
local T = require("tests.mock_cc")

-- A 1x1 monitor is 15x10 characters at text scale 0.5, and 7x5 at scale 1. Both are
-- exercised: the small one is what an operator gets if they never set the scale.
local function scaled() return T.recordingSurface(15, 10) end
local function unscaled() return T.recordingSurface(7, 5) end

local function activeModel(overrides)
    local model = {
        active = {item="minecraft:chest", display_name="Chest", state="STAGING",
            step=2, steps=3, quantity=16, produced=3, current_item="minecraft:oak_planks"},
        queued = 2, craftable_types = 639,
    }
    for key, value in pairs(overrides or {}) do
        if key == "active" then
            for field, item in pairs(value) do model.active[field] = item end
        else model[key] = value end
    end
    return model
end

return {
    {name="an active craft shows item, progress, step and state",run=function()
        local surface = scaled()
        CraftMonitor.render(surface, activeModel())
        local text = surface.allText()
        T.contains(text, "CRAFTING")
        T.contains(text, "Chest")
        T.contains(text, "3 / 16")
        T.contains(text, "STEP 2/3")
        T.contains(text, "STAGING")
    end},
    {name="the ingredient being staged is shown without its namespace",run=function()
        local surface = scaled()
        CraftMonitor.render(surface, activeModel())
        local text = surface.allText()
        T.contains(text, "oak_planks")
        T.equal(text:find("minecraft:", 1, true), nil,
            "the namespace wastes half the width and carries no information")
    end},
    {name="queue depth appears only when something is waiting",run=function()
        local busy = scaled()
        CraftMonitor.render(busy, activeModel())
        T.contains(busy.allText(), "+2 queued")

        local alone = scaled()
        CraftMonitor.render(alone, activeModel({queued=0}))
        T.equal(alone.allText():find("queued", 1, true), nil,
            "rendering '+0 queued' would waste a line on a 10-line screen")
    end},
    {name="an idle system shows the recipe count rather than a blank screen",run=function()
        local surface = scaled()
        CraftMonitor.render(surface, {active=nil, queued=0, craftable_types=639})
        local text = surface.allText()
        T.contains(text, "IDLE")
        T.contains(text, "639")
    end},
    {name="a blocked job shows its reason",run=function()
        local surface = scaled()
        CraftMonitor.render(surface, activeModel({active={state="BLOCKED",
            reason="INSUFFICIENT_MATERIALS"}}))
        local text = surface.allText()
        T.contains(text, "BLOCKED")
        T.contains(text, "INSUFFICIENT")
    end},
    {name="a progress bar reflects completed steps",run=function()
        local surface = scaled()
        CraftMonitor.render(surface, activeModel({active={step=3, steps=3}}))
        T.contains(surface.allText(), "[")
    end},
    {name="nothing is ever drawn outside the surface",run=function()
        for _, surface in ipairs({scaled(), unscaled(), T.recordingSurface(4, 3)}) do
            CraftMonitor.render(surface, activeModel())
            T.equal(surface.writesOutsideBounds(), 0, "renderer must respect its bounds")
        end
    end},
    {name="an unscaled 7x5 monitor still says what is happening",run=function()
        local surface = unscaled()
        CraftMonitor.render(surface, activeModel())
        local text = surface.allText()
        T.contains(text, "CRAFT")
        T.contains(text, "Chest")
        T.equal(surface.writesOutsideBounds(), 0)
    end},
    {name="an unscaled idle monitor is not blank",run=function()
        local surface = unscaled()
        CraftMonitor.render(surface, {active=nil})
        T.contains(surface.allText(), "IDLE")
    end},
    {name="a long item name is clipped rather than overflowing",run=function()
        -- Built directly rather than through the override helper: assigning nil to a Lua
        -- table key removes it, so overriding display_name to nil would keep the default.
        local surface = scaled()
        CraftMonitor.render(surface, {active={
            item="minecraft:polished_blackstone_brick_stairs",
            state="STAGING", quantity=1, produced=0}})
        T.equal(surface.writesOutsideBounds(), 0)
        T.contains(surface.allText(), "polished")
    end},
    {name="an empty model renders without erroring",run=function()
        local surface = scaled()
        CraftMonitor.render(surface, nil)
        T.equal(surface.writesOutsideBounds(), 0)
        T.contains(surface.allText(), "IDLE")
    end},
}
