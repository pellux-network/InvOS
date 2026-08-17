-- Run main.lua as a module from a normal CraftOS shell environment, which supplies
-- `package`/`require`; the raw --script environment that boot.lua starts in does not.
local scenario = dofile("/scenario.lua") or {}
package.path = "/storage/?.lua;/storage/?/init.lua;" .. package.path
local Main = require("main")
if type(Main) ~= "table" or type(Main.run) ~= "function" then
    error("main module did not return Main", 0)
end

local profileWorld
if scenario.world and scenario.world.profile then
    profileWorld = dofile("/world.lua")
    profileWorld.profilePeripherals()
end

local coordinator=Main.build(scenario.environment or {})
coordinator:redraw()
local timer=os.startTimer(0.05)
while true do
    local event={os.pullEventRaw()}
    if profileWorld and event[1]=="key" and event[2]==keys.f7 then
        local dropoff=scenario.config and scenario.config.dropoff
        if not dropoff then error("profile deposit requires a configured Drop-off",0) end
        peripheral.call(dropoff.peripheral_name,"setItem",1,{
            name="minecraft:stone",count=1,displayName="Stone",maxCount=64})
        coordinator:requestRescan({"dropoff"})
    elseif profileWorld and event[1]=="key" and event[2]==keys.f8 then
        local marker=fs.open("/profile-reset","w")
        if marker then marker.write("reset") marker.close() end
        if fs.exists("/profile-reset") then
            fs.delete("/profile-reset")
            profileWorld.resetProfile()
        end
    elseif event[1]=="timer" and event[2]==timer then
        coordinator:workStep()
        timer=os.startTimer(0.05)
        if profileWorld then profileWorld.flushProfile() end
    else
        coordinator:handle(event)
    end
end
