local UI = require("app.ui")
local Monitor = require("app.monitor")
local T = require("tests.mock_cc")

-- Two monitor sections vanished silently on short screens while the suite stayed green: the
-- tests checked that nothing drew out of bounds and that content appeared at one size, but
-- nothing asserted "this section is present at this size". These do.

local function storageModel()
    return {
        lifecycle="READY", lifecycle_reason="all required inventories healthy",
        total_items=59420, total_types=551,
        nodes={
            {id="dropoff", role="dropoff", label="Drop-off", state="READY", occupied=9, size=27},
            {id="s1", role="storage", label="Main Vault", state="READY", occupied=420, size=3075},
            {id="pickup", role="pickup", label="Pickup", state="READY", occupied=0, size=27},
        },
        requests={{id="r1", display_name="Iron Ingot", state="QUEUED", delivered=0, requested=64}},
        alerts={{key="a", severity="warning", message="Vault filling", acknowledged=false}},
    }
end

-- Every size the large monitor tier covers, plus the tiers below it.
local MONITOR_SIZES = {{79,24},{72,22},{62,20},{57,17},{57,16},{50,15},{45,14}}

local function monitorText(width, height, model)
    local surface = T.recordingSurface(width, height)
    Monitor.render(surface, model or storageModel())
    return surface.allText(), surface
end

local function pageText(page, width, height, mutate)
    local surface = T.recordingSurface(width, height)
    local screen = UI.new(surface)
    local state = UI.initialState()
    state.page, state.mode = page, page == "search" and "search" or "page"
    if mutate then mutate(state) end
    screen:render(state, storageModel())
    return surface.allText(), surface
end

return {
    { name = "the wall monitor keeps every section at every size it claims to support",
      run = function()
        for _, size in ipairs(MONITOR_SIZES) do
            local text = monitorText(size[1], size[2])
            local label = size[1] .. "x" .. size[2]
            T.contains(text, "INVOS", "no wordmark at " .. label)
            T.contains(text, "STORAGE NODES", "no node band at " .. label)
            T.contains(text, "Main Vault", "no node listed at " .. label)
            T.contains(text, "CURRENT ACTIVITY", "no activity band at " .. label)
            T.contains(text, "DROP-OFF", "no drop-off anywhere at " .. label)
            T.contains(text, "PICKUP", "no pickup anywhere at " .. label)
        end
    end },
    { name = "the chest gauges survive every size that has signposts", run = function()
        -- The gauges are the percentages; the signposts are the labels with arrows. Losing
        -- the gauges while keeping the signposts is exactly the regression that slipped
        -- through, because both contain the word DROP-OFF.
        for _, size in ipairs(MONITOR_SIZES) do
            local _, surface = monitorText(size[1], size[2])
            local found = false
            for y = 1, size[2] do
                local line = surface.line(y)
                if line:find("DROP-OFF", 1, true) and line:find("%%") then found = true end
            end
            T.truthy(found, "no drop-off gauge at " .. size[1] .. "x" .. size[2])
        end
    end },
    { name = "every terminal page keeps its band and its content at every size",
      run = function()
        local expectations = {
            {page="storage", band="NODE", content="Main Vault"},
            {page="requests", band="REQUEST", content="Iron Ingot"},
            {page="alerts", band="ALERT", content="Vault filling"},
        }
        for _, case in ipairs(expectations) do
            for _, size in ipairs({{51,19},{80,24},{40,14},{26,12}}) do
                local text = pageText(case.page, size[1], size[2])
                local label = case.page .. " at " .. size[1] .. "x" .. size[2]
                T.contains(text, case.band, "no band on " .. label)
                T.contains(text, case.content, "no content on " .. label)
            end
        end
    end },
    { name = "the header shows the version on a wide enough terminal", run = function()
        local surface = T.recordingSurface(51, 19)
        local screen = UI.new(surface)
        local state = UI.initialState()
        state.page, state.mode = "search", "search"
        screen:render(state, {lifecycle="READY", version="1.2.3", nodes=storageModel().nodes})
        local text = surface.allText()
        T.contains(text, "INVOS")
        T.contains(text, "1.2.3")
    end },
    { name = "the header omits the version on a pocket-sized terminal", run = function()
        local surface = T.recordingSurface(26, 12)
        local screen = UI.new(surface)
        local state = UI.initialState()
        state.page, state.mode = "search", "search"
        screen:render(state, {lifecycle="READY", version="1.2.3", nodes=storageModel().nodes})
        local text = surface.allText()
        T.contains(text, "INVOS")
        T.equal(text:find("1.2.3", 1, true), nil)
    end },
    { name = "the header does not error with no version at all", run = function()
        local surface = T.recordingSurface(51, 19)
        local screen = UI.new(surface)
        local state = UI.initialState()
        state.page, state.mode = "search", "search"
        screen:render(state, {lifecycle="READY", nodes=storageModel().nodes})
        T.contains(surface.allText(), "INVOS")
    end },
    { name = "the search page keeps its list and its pane wherever the pane exists",
      run = function()
        for _, size in ipairs({{51,19},{80,24},{40,14},{62,18}}) do
            local Layout = require("app.layout")
            local regions = Layout.regions(size[1], size[2])
            local surface = T.recordingSurface(size[1], size[2])
            local screen = UI.new(surface)
            local state = UI.initialState()
            state.results = {{identity_key="i", name="minecraft:iron_ingot",
                display_name="Iron Ingot", quantity=1284, max_count=64,
                variants={{identity_key="i", display_name="Iron Ingot", quantity=1284}}}}
            state.result_count, state.selection = 1, 1
            screen:render(state, {lifecycle="READY", search_results=state.results,
                nodes=storageModel().nodes})
            local text = surface.allText()
            local label = size[1] .. "x" .. size[2]
            T.contains(text, "ITEM", "no list band at " .. label)
            T.contains(text, "Iron Ingot", "no result at " .. label)
            if regions.split then
                -- The id is clipped to the pane width, which at 40 columns is 16, so this
                -- checks the pane shows an id at all rather than the whole of one.
                T.contains(text, "minecraft:", "no detail pane at " .. label)
                T.contains(text, "RETRIEVE", "no action button at " .. label)
            end
        end
    end },
}
