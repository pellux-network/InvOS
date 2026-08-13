local Alerts = {}
Alerts.__index = Alerts

local severityRank = { critical=3, warning=2, info=1 }

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

function Alerts.new(clock)
    assert(type(clock) == "function", "alert clock is required")
    return setmetatable({ clock=clock, conditions={} }, Alerts)
end

function Alerts:set(key, severity, message, details)
    assert(type(key) == "string" and key ~= "", "alert key is required")
    assert(severityRank[severity], "invalid alert severity")
    assert(type(message) == "string" and message ~= "", "alert message is required")
    local now = self.clock()
    local alert = self.conditions[key]
    if alert then
        alert.severity = severity
        alert.message = message
        alert.details = copy(details)
        alert.updated_at = now
        alert.occurrences = alert.occurrences + 1
    else
        alert = {
            key=key, severity=severity, message=message, details=copy(details),
            created_at=now, updated_at=now, occurrences=1, acknowledged=false,
        }
        self.conditions[key] = alert
    end
    return copy(alert)
end

function Alerts:acknowledge(key)
    local alert = self.conditions[key]
    if not alert then return nil, "unknown alert " .. tostring(key) end
    alert.acknowledged = true
    alert.acknowledged_at = self.clock()
    return true
end

function Alerts:resolve(key)
    if not self.conditions[key] then return nil, "unknown alert " .. tostring(key) end
    self.conditions[key] = nil
    return true
end

function Alerts:active()
    local result = {}
    for _, alert in pairs(self.conditions) do result[#result + 1] = copy(alert) end
    table.sort(result, function(left, right)
        local leftRank, rightRank = severityRank[left.severity], severityRank[right.severity]
        if leftRank ~= rightRank then return leftRank > rightRank end
        if left.created_at ~= right.created_at then return left.created_at < right.created_at end
        return left.key < right.key
    end)
    return result
end

return Alerts
