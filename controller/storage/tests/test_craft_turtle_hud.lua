-- Covers the turtle's own presentation layer: theme.lua, draw.lua, splash.lua, hud.lua,
-- and that deployment_manifest.lua names exactly the files that exist on disk.
--
-- These modules `require("crafter.draw")` / `require("crafter.theme")` internally. Per
-- AGENTS.md, tests must not prepend the turtle tree to package.path -- both manifests
-- define a module named `deployment_manifest`, and doing so would shadow the controller's
-- own for every test that runs after this one. Pre-seeding package.loaded instead lets
-- each module's internal require resolve without ever touching package.path; it is safe
-- here because none of these module names ("crafter.*") collide with anything the
-- controller defines.
local function loadTurtleModule(name, path)
    if not package.loaded[name] then
        package.loaded[name] = dofile(path)
    end
    return package.loaded[name]
end

local Theme = loadTurtleModule("crafter.theme", "../turtle/crafter/theme.lua")
local Draw = loadTurtleModule("crafter.draw", "../turtle/crafter/draw.lua")
local Splash = loadTurtleModule("crafter.splash", "../turtle/crafter/splash.lua")
local Hud = loadTurtleModule("crafter.hud", "../turtle/crafter/hud.lua")
local Manifest = dofile("../turtle/deployment_manifest.lua")
local T = require("tests.mock_cc")

local function fakeSleep()
    local calls = {}
    return function(seconds) calls[#calls + 1] = seconds end, calls
end

local function paintedCells(surface, color, width, height)
    local count = 0
    for y = 1, height do
        for x = 1, width do
            if surface.backgroundAt(x, y) == color then count = count + 1 end
        end
    end
    return count
end

local function idleStatus(overrides)
    local status = {id = 5, label = "Crafter", side = "back", now = 42,
        state = "IDLE", job = nil, last = nil, jobs_done = 3}
    for key, value in pairs(overrides or {}) do status[key] = value end
    return status
end

return {
    -- theme.lua
    {name = "statusColor maps every turtle-visible state to a semantic role", run = function()
        T.equal(Theme.statusColor("READY"), Theme.role.ok)
        T.equal(Theme.statusColor("STAGING"), Theme.role.working)
        T.equal(Theme.statusColor("CRAFTING"), Theme.role.working)
        T.equal(Theme.statusColor("PURGING"), Theme.role.working)
        T.equal(Theme.statusColor("ERROR"), Theme.role.alert)
        T.equal(Theme.statusColor("BLOCKED"), Theme.role.alert)
    end},
    {name = "apply and restore never error on a surface with no palette", run = function()
        local bare = {}
        T.equal(Theme.apply(bare), false)
        T.equal(Theme.restore(bare), false)
    end},

    -- draw.lua
    {name = "text clips to the surface and never writes outside it", run = function()
        local surface = T.recordingSurface(10, 3)
        Draw.text(surface, 8, 1, "way too long for the surface", 10)
        T.equal(surface.writesOutsideBounds(), 0)
    end},
    {name = "meter fills proportionally to its fraction", run = function()
        local surface = T.recordingSurface(20, 3)
        Draw.meter(surface, 1, 1, 10, 0.5, colors and colors.lime or 32, colors and colors.blue or 2048)
        local filled = 0
        for x = 1, 5 do if surface.backgroundAt(x, 1) == (colors and colors.lime or 32) then filled = filled + 1 end end
        T.truthy(filled >= 4, "half of a 10-cell meter should be at least 4-5 filled cells")
    end},
    {name = "blockText paints the requested glyphs and returns the cursor after them", run = function()
        local surface = T.recordingSurface(40, 6)
        local nextX = Draw.blockText(surface, 1, 1, "IO", Theme.role.brand)
        T.truthy(nextX > 1, "cursor should advance past the painted glyphs")
        T.truthy(paintedCells(surface, Theme.role.brand, 40, 6) > 0)
    end},

    -- splash.lua
    {name = "the wordmark plays and names the crafting turtle", run = function()
        local surface = T.recordingSurface(39, 13)
        Splash.play(surface, fakeSleep(), {id = 5, label = "Crafter", side = "back"})
        local text = surface.allText()
        T.contains(text, "CRAFTING TURTLE")
        T.contains(text, "#5")
        T.contains(text, "Crafter")
        T.contains(text, "modem:back")
        T.truthy(paintedCells(surface, Theme.role.brand, 39, 13) > 20,
            "expected a wordmark painted in brand colour")
        T.equal(surface.writesOutsideBounds(), 0)
    end},
    {name = "a screen too small for the block wordmark still names the product", run = function()
        local surface = T.recordingSurface(10, 5)
        Splash.play(surface, fakeSleep(), {id = 5, label = "Crafter", side = "back"})
        local text = surface.allText()
        T.contains(text, "InvOS")
        T.contains(text, "CRAFTER")
        T.equal(surface.writesOutsideBounds(), 0)
    end},
    {name = "the splash never writes outside a range of turtle-sized screens", run = function()
        for _, size in ipairs({{39, 13}, {26, 13}, {20, 10}, {10, 5}}) do
            local surface = T.recordingSurface(size[1], size[2])
            Splash.play(surface, fakeSleep(), {id = 1, label = "x", side = "left"})
            T.equal(surface.writesOutsideBounds(), 0, ("%dx%d surface"):format(size[1], size[2]))
        end
    end},
    {name = "splash tolerates missing identity info", run = function()
        local surface = T.recordingSurface(39, 13)
        local ok = pcall(Splash.play, surface, fakeSleep())
        T.equal(ok, true)
    end},

    -- hud.lua
    {name = "an idle turtle shows READY, uptime and jobs completed", run = function()
        local surface = T.recordingSurface(39, 13)
        Hud.render(surface, idleStatus())
        local text = surface.allText()
        T.contains(text, "CRAFTER")
        T.contains(text, "IDLE")
        T.contains(text, "JOBS COMPLETE 3")
        T.contains(text, "#5")
        T.contains(text, "Crafter")
        local ok = 0
        for x = 1, 39 do if surface.backgroundAt(x, 4) == Theme.role.ok then ok = ok + 1 end end
        T.truthy(ok > 30, "an idle, listening turtle should read as healthy, not muted")
    end},
    {name = "an active job shows the item, target quantity and a staging meter", run = function()
        local surface = T.recordingSurface(39, 13)
        Hud.render(surface, idleStatus({state = "STAGING",
            job = {item = "minecraft:oak_planks", quantity = 4, filled = 3, total = 8}}))
        local text = surface.allText()
        T.contains(text, "STAGING")
        T.contains(text, "oak_planks")
        T.equal(text:find("minecraft:", 1, true), nil, "the namespace carries no information here")
        T.contains(text, "x4")
        T.contains(text, "3 / 8")
        local metered = 0
        for y = 1, 13 do
            for x = 1, 39 do
                local bg = surface.backgroundAt(x, y)
                if bg == Theme.role.craft or bg == Theme.role.track then metered = metered + 1 end
            end
        end
        T.truthy(metered > 0, "staging progress must render as a meter")
    end},
    {name = "the state banner is colour-coded and uses the full width", run = function()
        local surface = T.recordingSurface(39, 13)
        Hud.render(surface, idleStatus({state = "CRAFTING", job = {item = "x", quantity = 1}}))
        local width = 0
        for x = 1, 39 do
            if surface.backgroundAt(x, 4) == Theme.role.working then width = width + 1 end
        end
        T.truthy(width > 30, "the banner should span nearly the full width")
    end},
    {name = "the last result is shown after a job finishes, success and failure alike", run = function()
        local ok = T.recordingSurface(39, 13)
        Hud.render(ok, idleStatus({last = {ok = true, item = "minecraft:chest", quantity = 1}}))
        T.contains(ok.allText(), "OK")
        T.contains(ok.allText(), "chest")

        local failed = T.recordingSurface(39, 13)
        Hud.render(failed, idleStatus({last = {ok = false, code = "INGREDIENT_SHORT",
            message = "the buffer held too little minecraft:oak_planks"}}))
        T.contains(failed.allText(), "FAIL")
    end},
    {name = "nothing is ever drawn outside the turtle's screen, at any size", run = function()
        local statuses = {idleStatus(), idleStatus({state = "CRAFTING",
            job = {item = "minecraft:polished_blackstone_brick_stairs", quantity = 64,
                filled = 5, total = 9}})}
        for _, size in ipairs({{39, 13}, {20, 8}, {12, 6}, {4, 3}}) do
            for _, status in ipairs(statuses) do
                local surface = T.recordingSurface(size[1], size[2])
                Hud.render(surface, status)
                T.equal(surface.writesOutsideBounds(), 0, ("%dx%d surface"):format(size[1], size[2]))
            end
        end
    end},
    {name = "an empty status renders without erroring", run = function()
        local surface = T.recordingSurface(39, 13)
        Hud.render(surface, nil)
        T.contains(surface.allText(), "IDLE")
    end},
    {name = "the hud ends every frame it begins", run = function()
        local frames = {begun = 0, ended = 0}
        local surface = T.recordingSurface(39, 13)
        surface.beginFrame = function() frames.begun = frames.begun + 1 end
        surface.endFrame = function() frames.ended = frames.ended + 1 end
        Hud.render(surface, idleStatus())
        Hud.render(surface, idleStatus({state = "CRAFTING", job = {item = "x"}}))
        T.equal(frames.ended, frames.begun)
    end},

    -- deployment_manifest.lua
    {name = "every turtle manifest path exists on disk", run = function()
        local missing = {}
        for _, path in ipairs(Manifest.files) do
            local handle = io.open("../turtle/" .. path, "r")
            if handle then handle:close() else missing[#missing + 1] = path end
        end
        T.equal(#missing, 0, "manifest names files that do not exist: " .. table.concat(missing, ", "))
    end},
    {name = "the new presentation modules are on the turtle's allow-list", run = function()
        for _, path in ipairs({"crafter/theme.lua", "crafter/draw.lua",
            "crafter/splash.lua", "crafter/hud.lua"}) do
            T.equal(Manifest.allowed(path), true, path)
        end
    end},
    {name = "the turtle manifest still refuses development artifacts", run = function()
        for _, path in ipairs({"README.md", "../controller/storage/app/theme.lua",
            "storage/data/config.lua", "crafter/../../controller/storage/main.lua"}) do
            T.equal(Manifest.allowed(path), false, path)
        end
    end},
}
