local Monitor = require("app.monitor")
local Theme = require("app.theme")
local T = require("tests.mock_cc")

local function model(overrides)
    local value = {
        lifecycle="READY", lifecycle_reason="all required inventories healthy",
        total_items=148302, total_types=2204,
        nodes={
            {id="dropoff", role="dropoff", label="Drop-off", state="READY", occupied=9, size=27},
            {id="s1", role="storage", label="Main Vault", state="READY", occupied=420, size=3075},
            {id="pickup", role="pickup", label="Pickup", state="READY", occupied=0, size=27},
        },
        alerts={}, requests={},
    }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

local function render(width, height, value)
    local surface = T.recordingSurface(width, height)
    Monitor.render(surface, value or model())
    return surface
end

local function painted(surface, color, width, height)
    local count = 0
    for y = 1, height do
        for x = 1, width do
            if surface.backgroundAt(x, y) == color then count = count + 1 end
        end
    end
    return count
end

return {
    { name = "the wall monitor leads with the number you read from a distance", run = function()
        local surface = render(79, 24)
        -- The total is drawn as block glyphs, so it is painted, not written: there is no
        -- "148,302" to search for, only a lot of coloured cells in the top band.
        local cells = 0
        for y = 3, 8 do
            for x = 1, 79 do
                if surface.backgroundAt(x, y) == Theme.role.focus then cells = cells + 1 end
            end
        end
        -- Seven glyphs at roughly ten lit cells each. The point of the assertion is that
        -- the total is painted at all rather than written as ordinary text, which was zero.
        T.truthy(cells > 50, "expected block digits, got " .. cells .. " painted cells")
        T.contains(surface.allText(), "ITEMS")
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "each node is metered, and a full one is coloured for it", run = function()
        local full = model()
        full.nodes[2].occupied, full.nodes[2].size = 2950, 3075
        local surface = render(79, 24, full)
        T.contains(surface.allText(), "Main Vault")
        T.truthy(painted(surface, Theme.role.alert, 79, 24) > 0,
            "a node at 96 percent must not be metered in the healthy colour")
    end },
    { name = "the active request is shown with its progress", run = function()
        local surface = render(79, 24, model({active_request={id="r1",
            display_name="Iron Ingot", state="TRANSFERRING", delivered=16, requested=64}}))
        local text = surface.allText()
        T.contains(text, "Iron Ingot")
        T.contains(text, "16 / 64")
    end },
    { name = "no activity says so rather than leaving a hole", run = function()
        T.contains(render(79, 24).allText(), "No active request")
    end },
    { name = "the highest alert gets a band of its own", run = function()
        local surface = render(79, 24, model({highest_alert={key="a", severity="critical",
            message="Pickup is full"}}))
        T.contains(surface.allText(), "Pickup is full")
        T.truthy(painted(surface, Theme.role.alert, 79, 24) > 0)
    end },
    { name = "the medium tier keeps the totals and the state", run = function()
        local surface = render(40, 13)
        local text = surface.allText()
        T.contains(text, "INVOS")
        T.contains(text, "148,302")
        T.contains(text, "READY")
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "the small tier still names the product and the totals", run = function()
        local surface = render(20, 7)
        local text = surface.allText()
        T.contains(text, "INVOS")
        T.contains(text, "148,302")
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "the monitor never draws outside its surface at any size", run = function()
        for _, size in ipairs({{79,24},{57,20},{45,14},{40,13},{24,8},{20,7},{15,5},{8,3}}) do
            local surface = render(size[1], size[2], model({
                highest_alert={key="a", severity="critical", message="Pickup is full"}}))
            T.equal(surface.writesOutsideBounds(), 0,
                size[1] .. "x" .. size[2] .. " drew outside")
        end
    end },
    { name = "enrichment progress replaces the lifecycle reason while learning", run = function()
        local surface = render(79, 24, model({enrichment={learned=1200, total=3000}}))
        local text = surface.allText()
        T.contains(text, "1,200")
        T.equal(text:find("all required inventories healthy", 1, true), nil)
    end },
    { name = "the monitor ends every frame it begins", run = function()
        local frames = {begun=0, ended=0}
        local surface = T.recordingSurface(79, 24)
        surface.beginFrame = function() frames.begun = frames.begun + 1 end
        surface.endFrame = function() frames.ended = frames.ended + 1 end
        Monitor.render(surface, model())
        Monitor.render(surface, {})
        T.equal(frames.ended, frames.begun,
            "a frame begun and never ended leaves the window hidden forever")
    end },
    { name = "storage nodes appear on a monitor that is not 24 rows tall", run = function()
        -- The large tier starts at 14 rows. Hardcoding the node rows for a 24-row monitor
        -- made every shorter one draw an empty STORAGE NODES section.
        for _, size in ipairs({{57,16},{57,20},{50,14},{79,24}}) do
            local surface = render(size[1], size[2])
            T.contains(surface.allText(), "Main Vault",
                "no nodes listed at " .. size[1] .. "x" .. size[2])
        end
    end },
    { name = "the totals never spill off the right edge", run = function()
        for _, size in ipairs({{57,16},{45,14},{62,18},{79,24}}) do
            local surface = render(size[1], size[2], model({total_items=59383,
                total_types=553}))
            local text = surface.allText()
            T.equal(surface.writesOutsideBounds(), 0)
            -- Whichever way the type count is drawn, its label must be whole. A clipped
            -- "DISTINC" is how this showed up in world.
            local truncated = text:find("DISTINC", 1, true) and not text:find("DISTINCT", 1, true)
            T.truthy(not truncated, "the type label was clipped at " .. size[1] .. " columns")
        end
    end },
    { name = "a narrow monitor still reports the type count somehow", run = function()
        local surface = render(57, 16, model({total_items=59383, total_types=553}))
        T.contains(surface.allText(), "553",
            "the count must fall back to text when block digits will not fit")
    end },
    { name = "the chests are signposted with arrows pointing at them", run = function()
        -- The monitor hangs above the real chests, so these label the world, not the model.
        -- Losing them costs a player the ability to tell which chest is which.
        for _, size in ipairs({{57,16},{79,24},{50,14}}) do
            local surface = render(size[1], size[2])
            local label = surface.line(size[2] - 1)
            local arrows = surface.line(size[2])
            T.contains(label, "DROP-OFF", "no drop-off signpost at " .. size[1] .. "x" .. size[2])
            T.contains(label, "PICKUP", "no pickup signpost at " .. size[1] .. "x" .. size[2])
            T.truthy(arrows:find("v", 1, true) ~= nil,
                "no arrow pointing at the chests at " .. size[1] .. "x" .. size[2])
            T.equal(surface.writesOutsideBounds(), 0)
        end
    end },
    { name = "the signposts sit over the chests they point at", run = function()
        local surface = render(79, 24)
        local arrows = surface.line(24)
        local first = arrows:find("v", 1, true)
        local second = arrows:find("v", first + 1, true)
        T.truthy(second ~= nil, "expected two arrows, one per chest")
        T.truthy(first < 40 and second > 40,
            "the arrows must sit apart, over the two chests, not together")
    end },
    { name = "the big number does not sit on top of its label", run = function()
        local surface = render(79, 24)
        -- Block glyphs occupy five rows from row 3, so row 8 has to stay clear or the
        -- descenders touch the caption underneath.
        local touching = 0
        for x = 1, 79 do
            if surface.backgroundAt(x, 8) == Theme.role.focus
                or surface.backgroundAt(x, 8) == Theme.role.text then touching = touching + 1 end
        end
        T.equal(touching, 0, "the glyph row and the label row are adjacent")
        T.contains(surface.line(9), "ITEMS STORED")
    end },
    { name = "a namespaced node name keeps its meaningful half", run = function()
        local named = model()
        named.nodes[2].label = "colossalchests:colossal_chest_0"
        local surface = render(57, 16, named)
        local text = surface.allText()
        T.contains(text, "colossal_chest_0",
            "the namespace should be dropped before the name is, not after")
        T.equal(surface.writesOutsideBounds(), 0)
    end },
}
