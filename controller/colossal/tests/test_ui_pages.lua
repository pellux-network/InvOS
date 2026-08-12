local UI = require("app.ui")
local Theme = require("app.theme")
local T = require("tests.mock_cc")

local function nodes(count)
    local list = {{id="dropoff", role="dropoff", label="Drop-off", state="READY",
        occupied=9, size=27}}
    for index = 1, (count or 3) do
        list[#list + 1] = {id="s"..index, role="storage", label="Vault "..index,
            state="READY", occupied=index * 20, size=100}
    end
    list[#list + 1] = {id="pickup", role="pickup", label="Pickup", state="READY",
        occupied=0, size=27}
    return list
end

local function render(page, model, mutate)
    local surface = T.recordingSurface(51, 19)
    local screen = UI.new(surface)
    local state = UI.initialState()
    state.page, state.mode = page, "page"
    if mutate then mutate(state) end
    screen:render(state, model)
    return surface
end

return {
    { name = "the nodes page meters each node's fill", run = function()
        local surface = render("storage", {lifecycle="READY", nodes=nodes(3)})
        local text = surface.allText()
        T.contains(text, "Vault 1")
        T.contains(text, "NODE")
        T.contains(text, "20%", "a node at 20 of 100 must say so")
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "a node near capacity is metered in the warning colour", run = function()
        local full = nodes(1)
        full[2].occupied, full[2].size = 95, 100
        local surface = render("storage", {lifecycle="READY", nodes=full})
        local alerted = 0
        for y = 1, 19 do
            for x = 1, 51 do
                if surface.backgroundAt(x, y) == Theme.role.alert then alerted = alerted + 1 end
            end
        end
        T.truthy(alerted > 0, "a node at 95 percent must not be metered in the healthy colour")
    end },
    { name = "the requests page meters delivery progress", run = function()
        local surface = render("requests", {lifecycle="READY", nodes=nodes(1), requests={
            {id="r1", display_name="Iron Ingot", state="TRANSFERRING", delivered=16, requested=64},
        }})
        local text = surface.allText()
        T.contains(text, "Iron Ingot")
        T.contains(text, "16 / 64")
        T.contains(text, "REQUEST")
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "the alerts page separates critical from warning", run = function()
        local surface = render("alerts", {lifecycle="DEGRADED", nodes=nodes(1), alerts={
            {key="a1", severity="critical", message="Pickup is full", acknowledged=false},
            {key="a2", severity="warning", message="Vault 1 is filling", acknowledged=true},
        }}, function(state) state.alert_selection = 2 end)
        local text = surface.allText()
        T.contains(text, "Pickup is full")
        T.contains(text, "Vault 1 is filling")
        T.contains(text, "ALERT")
        T.equal(surface.writesOutsideBounds(), 0)
    end },
    { name = "empty states still explain themselves", run = function()
        local cases = {
            {page="requests", text="No requests yet"},
            {page="alerts", text="No active alerts"},
            {page="setup", text="Review or change inventory roles"},
        }
        for _, case in ipairs(cases) do
            local surface = render(case.page, {lifecycle="READY", nodes=nodes(1)})
            T.contains(surface.allText(), case.text)
            T.equal(surface.writesOutsideBounds(), 0)
        end
    end },
    { name = "every page draws inside its surface at every size", run = function()
        for _, page in ipairs({"storage", "requests", "alerts", "setup"}) do
            for _, size in ipairs({{51,19},{80,24},{40,14},{26,12},{18,8}}) do
                local surface = T.recordingSurface(size[1], size[2])
                local screen = UI.new(surface)
                local state = UI.initialState()
                state.page, state.mode = page, "page"
                screen:render(state, {lifecycle="READY", nodes=nodes(20), requests={
                    {id="r1", display_name="Iron", state="QUEUED", delivered=0, requested=9},
                }, alerts={{key="a", severity="critical", message="Full", acknowledged=false}}})
                T.equal(surface.writesOutsideBounds(), 0,
                    page .. " at " .. size[1] .. "x" .. size[2])
            end
        end
    end },
}
