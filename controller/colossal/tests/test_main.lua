local Main = require("main")
local T = require("tests.mock_cc")

local function environment()
    local surface=T.recordingSurface(51,19)
    return {
        fs=T.memoryFs(),data_root="data",
        peripheral={
            getNames=function() return {} end,
            hasType=function() return false end,
            getMethods=function() return {} end,
            wrap=function() return nil end,
            find=function() return nil end,
        },
        os={getComputerID=function() return 17 end,getComputerLabel=function() return nil end,
            epoch=function() return 1000 end},
        term={current=function() return surface end},clock=function() return 1000 end,
        textutils={serialize=function() return "{}" end,unserialize=function() return {} end},
        surface=surface,
    }
end

return {
    {name="main assembles a safe first-boot setup controller",run=function()
        local env=environment(); local coordinator,services=Main.build(env)
        local model=coordinator:viewModel()
        T.equal(model.configured,false)
        T.equal(model.lifecycle,"SETUP_REQUIRED")
        T.equal(model.ui.mode,"setup")
        T.equal(model.ui.setup_step,1)
        T.truthy(services.setup)
        coordinator:handle({"char","x"})
        T.equal(coordinator:viewModel().lifecycle,"SETUP_REQUIRED")
    end},
}
