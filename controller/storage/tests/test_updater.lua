local Updater = require("app.updater")
local Alerts = require("app.alerts")
local T = require("tests.mock_cc")

local function fakeHttp()
    local requested = {}
    return {
        request = function(url) requested[#requested+1] = url end,
        requested = requested,
    }
end

local function fakeTurtleLink(sendResult)
    local sent = {}
    return {
        send = function(self, command)
            sent[#sent+1] = command
            return sendResult ~= false, sendResult == false and "unreachable" or nil
        end,
        poll = function() return nil end,
        sent = sent,
    }
end

local RELEASES_BODY_NEWER = '{"tag_name":"v9.9.9"}'
local RELEASES_BODY_SAME = '{"tag_name":"v1.0.0"}'

return {
    {name="maybeCheck fires an http request on the first call", run=function()
        local http = fakeHttp()
        local updater = Updater.new({http=http, clock=function() return 0 end,
            alerts=Alerts.new(function() return 0 end), local_version="1.0.0"})
        updater:maybeCheck(0)
        T.equal(#http.requested, 1, "should fire one request")
    end},

    {name="maybeCheck does not fire again before the interval elapses", run=function()
        local http = fakeHttp()
        local updater = Updater.new({http=http, clock=function() return 0 end,
            alerts=Alerts.new(function() return 0 end), local_version="1.0.0",
            check_interval_ms=1000})
        updater:maybeCheck(0)
        updater:maybeCheck(500)
        T.equal(#http.requested, 1, "should still be exactly one request")
    end},

    {name="maybeCheck fires again once the interval elapses", run=function()
        local http = fakeHttp()
        local updater = Updater.new({http=http, clock=function() return 0 end,
            alerts=Alerts.new(function() return 0 end), local_version="1.0.0",
            check_interval_ms=1000})
        updater:maybeCheck(0)
        updater:maybeCheck(1500)
        T.equal(#http.requested, 2, "should fire a second request")
    end},

    {name="a newer release raises the update_available alert", run=function()
        local alerts = Alerts.new(function() return 0 end)
        local updater = Updater.new({http=fakeHttp(), clock=function() return 0 end,
            alerts=alerts, local_version="1.0.0"})
        updater:maybeCheck(0)
        updater:handleHttpEvent({"http_success", updater.RELEASES_LATEST_URL,
            {readAll=function() return RELEASES_BODY_NEWER end, close=function() end}})
        local active = alerts:active()
        T.equal(#active, 1, "should have raised one alert")
        T.equal(active[1].key, "update_available", "alert key should be update_available")
    end},

    {name="an equal release does not raise an alert", run=function()
        local alerts = Alerts.new(function() return 0 end)
        local updater = Updater.new({http=fakeHttp(), clock=function() return 0 end,
            alerts=alerts, local_version="1.0.0"})
        updater:maybeCheck(0)
        updater:handleHttpEvent({"http_success", updater.RELEASES_LATEST_URL,
            {readAll=function() return RELEASES_BODY_SAME end, close=function() end}})
        T.equal(#alerts:active(), 0, "should not have raised an alert")
    end},

    {name="a request failure raises no alert and does not error", run=function()
        local alerts = Alerts.new(function() return 0 end)
        local updater = Updater.new({http=fakeHttp(), clock=function() return 0 end,
            alerts=alerts, local_version="1.0.0"})
        updater:maybeCheck(0)
        local ok = pcall(updater.handleHttpEvent, updater,
            {"http_failure", updater.RELEASES_LATEST_URL, "Could not connect"})
        T.equal(ok, true, "should not error on a failed check")
        T.equal(#alerts:active(), 0, "should not have raised an alert")
    end},

    {name="trigger sends an update command to the turtle and awaits its ack", run=function()
        local link = fakeTurtleLink()
        local updater = Updater.new({http=fakeHttp(), clock=function() return 0 end,
            alerts=Alerts.new(function() return 0 end), local_version="1.0.0",
            turtle_link=link, resolved_ref="v1.2.3"})
        updater:trigger()
        T.equal(#link.sent, 1, "should have sent one command")
        T.equal(link.sent[1].op, "update", "command op should be update")
        T.equal(link.sent[1].ref, "v1.2.3", "should send the resolved ref")
        T.equal(updater:phase(), "awaiting_turtle_ack", "should be awaiting an ack")
    end},

    {name="tick moves to turtle_unreachable after the ack timeout elapses", run=function()
        local link = fakeTurtleLink()
        local updater = Updater.new({http=fakeHttp(), clock=function() return 0 end,
            alerts=Alerts.new(function() return 0 end), local_version="1.0.0",
            turtle_link=link, resolved_ref="v1.2.3", turtle_ack_timeout_ms=5000})
        updater:trigger()
        updater:tick(4000)
        T.equal(updater:phase(), "awaiting_turtle_ack", "should still be waiting before the deadline")
        updater:tick(6000)
        T.equal(updater:phase(), "turtle_unreachable", "should give up after the deadline")
    end},

    {name="trigger with no turtle_link goes straight to updating", run=function()
        local updater = Updater.new({http=fakeHttp(), clock=function() return 0 end,
            alerts=Alerts.new(function() return 0 end), local_version="1.0.0",
            resolved_ref="v1.2.3",
            shell={run=function() end}, os={reboot=function() end}, fs=T.memoryFs()})
        updater:trigger()
        T.equal(updater:phase(), "updating", "should skip the turtle handshake entirely")
    end},

    {name="cancel returns to idle from any armed phase", run=function()
        local link = fakeTurtleLink()
        local updater = Updater.new({http=fakeHttp(), clock=function() return 0 end,
            alerts=Alerts.new(function() return 0 end), local_version="1.0.0",
            turtle_link=link, resolved_ref="v1.2.3"})
        updater:trigger()
        updater:cancel()
        T.equal(updater:phase(), nil, "should be back to idle")
    end},
}
