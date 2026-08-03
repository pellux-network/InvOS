local M = {}

local allowed = {
    request = {
        DRAFT = { QUEUED=true, CANCELLED=true },
        QUEUED = { PLANNING=true, CANCELLED=true },
        PLANNING = { TRANSFERRING=true, BLOCKED=true, FAILED=true, CANCELLED=true },
        TRANSFERRING = { VERIFYING=true, PARTIAL=true, BLOCKED=true, FAILED=true },
        VERIFYING = { COMPLETE=true, PARTIAL=true, BLOCKED=true, FAILED=true },
        BLOCKED = { PLANNING=true, CANCELLED=true },
        PARTIAL = { PLANNING=true, CANCELLED=true },
        FAILED = { PLANNING=true, CANCELLED=true },
    },
    import = {
        PENDING = { PLANNING=true, COMPLETE=true, FAILED=true },
        PLANNING = { TRANSFERRING=true, BLOCKED=true, COMPLETE=true, FAILED=true },
        TRANSFERRING = { VERIFYING=true, PARTIAL=true, BLOCKED=true, FAILED=true },
        VERIFYING = { COMPLETE=true, PARTIAL=true, BLOCKED=true, FAILED=true },
        BLOCKED = { PLANNING=true },
        PARTIAL = { PLANNING=true, BLOCKED=true, FAILED=true },
        FAILED = { PLANNING=true },
    },
    storage = {
        DISCOVERED = { SCANNING=true, DISABLED=true },
        SCANNING = { READY=true, STALE=true, OFFLINE=true, ERROR=true, DISABLED=true },
        READY = { SCANNING=true, STALE=true, OFFLINE=true, ERROR=true, DISABLED=true },
        STALE = { SCANNING=true, OFFLINE=true, ERROR=true, DISABLED=true },
        OFFLINE = { SCANNING=true, DISABLED=true },
        ERROR = { SCANNING=true, OFFLINE=true, DISABLED=true },
        DISABLED = { DISCOVERED=true, SCANNING=true },
    },
}

function M.transition(kind, from, to)
    if allowed[kind] and allowed[kind][from] and allowed[kind][from][to] then return true end
    return nil, ("forbidden %s transition %s -> %s"):format(
        tostring(kind), tostring(from), tostring(to))
end

function M.derive(context)
    if context.persistence_error or context.journal_error then
        return "ERROR", tostring(context.persistence_error or context.journal_error)
    end
    if not context.configured then return "SETUP_REQUIRED", "required setup is incomplete" end
    if context.recovering then return "RECOVERING", "unfinished transfer reconciliation" end
    if context.paused then return "PAUSED", "automation paused by operator" end
    if not context.initial_index_complete then return "INDEXING", "building initial live inventory index" end

    local reasons = {}
    if (context.ready_storage or 0) < 1 then reasons[#reasons + 1] = "no healthy storage" end
    if not context.dropoff_ready then reasons[#reasons + 1] = "Drop-off unavailable" end
    if not context.pickup_ready then reasons[#reasons + 1] = "Pickup unavailable" end
    if (context.unhealthy_nodes or 0) > 0 then
        reasons[#reasons + 1] = tostring(context.unhealthy_nodes) .. " storage node(s) unhealthy"
    end
    if #reasons > 0 then return "DEGRADED", table.concat(reasons, "; ") end
    return "READY", "all required inventories healthy"
end

return M
