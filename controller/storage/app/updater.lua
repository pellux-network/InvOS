local Updater = {}
Updater.__index = Updater

local RELEASES_LATEST_URL = "https://api.github.com/repos/pellux-network/InvOS/releases/latest"
local INSTALL_URL = "https://raw.githubusercontent.com/pellux-network/InvOS/main/install.lua"

local function extractTagName(body)
    if type(body) ~= "string" then return nil end
    return body:match('"tag_name"%s*:%s*"([^"]+)"')
end

local function stripV(ref) return tostring(ref):gsub("^v", "") end

local function compareVersions(a, b)
    local partsA, partsB = {}, {}
    for part in stripV(a):gmatch("%d+") do partsA[#partsA + 1] = tonumber(part) end
    for part in stripV(b):gmatch("%d+") do partsB[#partsB + 1] = tonumber(part) end
    for index = 1, math.max(#partsA, #partsB) do
        local left, right = partsA[index] or 0, partsB[index] or 0
        if left < right then return -1 end
        if left > right then return 1 end
    end
    return 0
end

function Updater.new(deps)
    assert(type(deps) == "table", "updater dependencies are required")
    return setmetatable({
        http = deps.http, os = deps.os, clock = deps.clock, alerts = deps.alerts,
        turtleLink = deps.turtle_link, shell = deps.shell, fs = deps.fs,
        localVersion = deps.local_version,
        checkIntervalMs = deps.check_interval_ms or (6 * 60 * 60 * 1000),
        turtleAckTimeoutMs = deps.turtle_ack_timeout_ms or 5000,
        -- Test-only escape hatch: production always resolves the ref from a
        -- real check; tests that only exercise trigger()/tick() would
        -- otherwise need to fake a full check cycle just to set one up.
        resolvedRef = deps.resolved_ref,
        lastCheckedAt = nil,
        phaseValue = nil, turtleAckDeadline = nil,
    }, Updater)
end

Updater.RELEASES_LATEST_URL = RELEASES_LATEST_URL

function Updater:phase() return self.phaseValue end

-- Gated purely on the interval elapsing, not on whether a previous request
-- is still outstanding: if an http_success/http_failure event was ever lost
-- (dropped connection, whatever), a "wait for it to resolve first" guard
-- would permanently disable checking from that point on. Two outstanding
-- requests to the same URL is harmless -- handleHttpEvent treats either
-- response the same way.
function Updater:maybeCheck(now)
    if not self.http or type(self.http.request) ~= "function" then return end
    if self.lastCheckedAt and (now - self.lastCheckedAt) < self.checkIntervalMs then return end
    self.lastCheckedAt = now
    pcall(self.http.request, RELEASES_LATEST_URL)
end

function Updater:handleHttpEvent(event)
    local name, url, handleOrError = event[1], event[2], event[3]
    if url ~= RELEASES_LATEST_URL then return end
    if name ~= "http_success" or type(handleOrError) ~= "table" then return end
    local ok, body = pcall(handleOrError.readAll)
    pcall(handleOrError.close)
    if not ok or not body then return end
    local tag = extractTagName(body)
    if not tag then return end
    self.resolvedRef = tag
    if self.localVersion and compareVersions(self.localVersion, stripV(tag)) < 0 then
        if self.alerts then
            self.alerts:set("update_available", "info",
                "InvOS " .. tag .. " is available (running " .. tostring(self.localVersion) .. ")",
                {ref = tag})
        end
    elseif self.alerts then
        pcall(self.alerts.resolve, self.alerts, "update_available")
    end
end

function Updater:trigger()
    if self.turtleLink then
        pcall(self.turtleLink.send, self.turtleLink, {op = "update", ref = self.resolvedRef})
        self.phaseValue = "awaiting_turtle_ack"
        self.turtleAckDeadline = (self.clock and self.clock() or 0) + self.turtleAckTimeoutMs
    else
        self.phaseValue = "updating"
        self:_runSelfUpdate()
    end
end

function Updater:proceedWithoutTurtle()
    self.phaseValue = "updating"
    self:_runSelfUpdate()
end

function Updater:cancel()
    self.phaseValue = nil
    self.turtleAckDeadline = nil
end

function Updater:tick(now)
    if self.phaseValue ~= "awaiting_turtle_ack" then return end
    if self.turtleLink and type(self.turtleLink.poll) == "function" then
        local reply = self.turtleLink:poll()
        if reply then
            self.phaseValue = "updating"
            self:_runSelfUpdate()
            return
        end
    end
    if self.turtleAckDeadline and now >= self.turtleAckDeadline then
        self.phaseValue = "turtle_unreachable"
    end
end

-- Blocking by design: this only runs after an explicit, already-confirmed
-- operator action, and ends in os.reboot(), which never returns on success.
function Updater:_runSelfUpdate()
    if not self.http or not self.fs or not self.shell then return end
    local handle = self.http.get and self.http.get(INSTALL_URL) or nil
    if not handle then return end
    local source = handle.readAll()
    handle.close()
    local file = self.fs.open("/install_update.lua", "w")
    file.write(source)
    file.close()
    self.shell.run("/install_update.lua", "update", self.resolvedRef)
end

return Updater
