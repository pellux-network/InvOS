local Coordinator = require("app.coordinator")
local T = require("tests.mock_cc")

local function fullConfig()
    return {
        configured = true,
        dropoff = {peripheral_name="ironchests:netherite_chest_1"},
        pickup = {peripheral_name="ironchests:diamond_chest_1"},
        craft_buffer = {peripheral_name="ironchests:diamond_chest_3"},
        turtle = {peripheral_name="turtle_2"},
        storage = {{id="storage_6", label="Main Vault", priority=6, enabled=true,
            peripheral_name="colossalchests:colossal_chest_0"}},
    }
end

local function byRole(nodes, role)
    for _, node in ipairs(nodes) do if node.role == role then return node end end
end

local function coordinator()
    local ui = {}
    function ui:reduce(state) return state end
    function ui:render() end
    return Coordinator.new{
        configured = true, clock = function() return 1 end,
        scanner = {begin = function(_, node) return {node=node} end,
            step = function(_, scan) return true, {node_id=scan.node.id, size=27, occupied=0,
                slots={}, health="READY"} end},
        nodes = {}, ui = ui,
        initial_ui = {mode="page", page="search", results={}, hit_regions={}},
        keymap = {command = function() end},
        build_index = function() return {items = function() return {} end} end,
        search = function() return {} end,
        lifecycle = {derive = function() return "READY", "" end},
        registry = {},
    }
end

return {
    { name = "the craft buffer is a node, not just a config entry", run = function()
        local nodes = Coordinator.nodesFrom(fullConfig())
        local buffer = byRole(nodes, "craft_buffer")
        T.truthy(buffer ~= nil, "the craft buffer must appear in the node list")
        T.equal(buffer.peripheral_name, "ironchests:diamond_chest_3")
    end },
    { name = "finishing the wizard keeps the craft buffer bound", run = function()
        -- The wizard saves craft_buffer into the configuration and then hands it here. This
        -- rebuild used to drop it, so the buffer bound and immediately vanished from Nodes.
        local c = coordinator()
        T.equal(c:completeSetup(fullConfig()), true)
        local buffer = byRole(c:viewModel().nodes, "craft_buffer")
        T.truthy(buffer ~= nil, "the craft buffer vanished when setup completed")
        T.equal(buffer.peripheral_name, "ironchests:diamond_chest_3")
    end },
    { name = "a configuration without crafting gets no buffer node", run = function()
        local config = fullConfig()
        config.craft_buffer = nil
        T.equal(byRole(Coordinator.nodesFrom(config), "craft_buffer"), nil)
    end },
    { name = "roles keep the names a person reads, not their ids", run = function()
        local c = coordinator()
        c:completeSetup(fullConfig())
        local nodes = c:viewModel().nodes
        T.equal(byRole(nodes, "dropoff").label, "Drop-off")
        T.equal(byRole(nodes, "pickup").label, "Pickup")
        T.equal(byRole(nodes, "storage").label, "Main Vault")
    end },
    { name = "replacing the nodes forgets any scan backoff they had", run = function()
        local c = coordinator()
        c.scanFailedAt["dropoff"] = 1
        c.scanFailures["dropoff"] = 6
        c:completeSetup(fullConfig())
        T.equal(c.scanFailedAt["dropoff"], nil,
            "a reconfigured node must not inherit the old one's backoff")
        T.equal(c.scanFailures["dropoff"], nil)
    end },
}
