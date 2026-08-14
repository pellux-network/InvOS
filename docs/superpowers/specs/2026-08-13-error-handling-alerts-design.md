# Error handling, recovery, and the Alerts page

## Context

Operators report that minor, expected conditions -- e.g. more items
landing in Pickup while a previous batch is still draining -- sometimes
take the whole controller down and require a manual restart, and that the
Alerts page's two clearing actions ("acknowledge" and the recovery
"release") are confusing and often don't actually make anything happen:
the monitor's error banner can stay lit indefinitely with no way to clear
it.

Tracing the actual code turned up three separate, compounding problems:

1. **A real crash gap.** `Coordinator:redraw` (`app/coordinator.lua:1002-1004`)
   calls `self:_model()` and `self:_syncPageCounts(model)` *before* its
   first `pcall`. `_model()` aggregates nodes, requests, alerts and
   gauge counts from live, concurrently-changing state -- exactly what a
   race between "items land in Pickup" and "a batch is mid-drain" would
   perturb. Any error there escapes `redraw` -> `workStep` -> the
   `worker` coroutine -> `parallel.waitForAny` -> `Main.run`, caught only
   by the single top-level `xpcall` in `main.lua:508-515`, which prints
   and ends the whole program. `startup.lua`'s supervisor then restarts
   it. `Coordinator:run`'s `events()` loop (`app/coordinator.lua:1029-1031`)
   has the same shape: `self:handle(...)` is called with no enclosing
   `pcall` at that level.
2. **Alerts that never self-clear.** `Coordinator:_recordError`
   (`app/coordinator.lua:98-108`) is the catch-all: nearly every `pcall`
   failure in the coordinator funnels into a `critical`
   `component_error:<name>` alert via `alerts:set`. Nothing ever calls
   `alerts:resolve` for that same key when the component subsequently
   succeeds, so once any component fails once, its alert -- and the
   monitor's red banner, which just renders `alerts:active()`'s top
   entry (`app/monitor.lua:181-185`, `224-227`, `239-242`) -- persists
   forever. `Coordinator:_stallStep` (`app/coordinator.lua:524-549`)
   already does this correctly for stalled transfers (`pcall(alerts.resolve,
   ...)` once the state moves on); the rest of the coordinator just never
   adopted the pattern.
3. **Two confusing, mostly-inert clearing actions.** `Alerts:acknowledge`
   (`app/alerts.lua:43-49`) only flips a cosmetic flag -- it doesn't
   remove the alert, doesn't touch the monitor banner, and doesn't
   unblock anything. `Recovery:resolve` (`app/recovery.lua:47-58`), wired
   to the page-global `X` / `ARM_RECOVERY_RELEASE` key
   (`app/keymap.lua:147`, `71-78`), is the *only* action that ever
   really clears anything -- but it's a special-purpose, deliberately
   destructive escape hatch for one specific state (a `BLOCKED` transfer
   recovery, discarding proof of what an interrupted transfer moved), not
   a general "make this alert go away" button, and it isn't tied to
   which alert is even selected.

A fourth thing looked at and *rejected*: letting imports/requests/crafts
keep running while a recovery is `BLOCKED`. `Recovery` is only ever
constructed once, at boot, from a single journal file left on disk after
a crash (`main.lua:279-309`); `core/transfer.lua:270` writes new
transfers to that same single `"journal"` store key. Running a new
transfer while an old, unresolved one is still `BLOCKED` would overwrite
that slot before the operator ever reviewed it, silently destroying the
evidence needed to know what the interrupted transfer actually moved.
`Coordinator:_automationStep`'s priority selection of a `BLOCKED`
recovery over the round-robin (`app/coordinator.lua:479-480`) is
therefore protecting something real, not a scheduling bug, and this
design leaves it in place.

## Goals

- A transient or unexpected error in the coordinator's own bookkeeping
  can no longer crash the whole controller; it degrades to a caught,
  recorded alert like every other failure already does.
- An alert raised for a component that has since succeeded again clears
  itself; the monitor's banner stops staying lit for conditions that are
  no longer true.
- The Alerts page has exactly one action -- Dismiss -- for making an
  alert go away, applied to whichever alert is selected.
- The one alert that genuinely cannot be dismissed for free (a `BLOCKED`
  recovery) still requires its existing two-key confirmation, but that
  confirmation is reached through the same Dismiss action rather than a
  separate, always-present key.

## Non-goals

- No change to the `BLOCKED`-recovery scheduler priority
  (`app/coordinator.lua:479-480`) or to the single-journal-slot
  invariant -- see "rejected" above.
- No change to `Recovery:resolve`'s semantics (still discards proof of
  what moved; still requires the two-key confirm).
- No change to how `import_service.lua`, `craft_service.lua`, and
  `requests.lua` manage their *own* alert keys on success/failure --
  they already call `alerts:resolve` themselves correctly. This design
  only adds the missing auto-clear for the generic
  `component_error:<name>` alerts the coordinator raises on their
  behalf.
- No new alert severities or alert types beyond the existing
  `critical`/`warning`/`info`.

## Design

### 1. Crash hardening (`app/coordinator.lua`)

Wrap `Coordinator:workStep`'s body in one outer `pcall`:

```lua
function Coordinator:workStep(now)
    now = now or self.clock()
    local ok, reason = pcall(function()
        self:_scanStep(now)
        self:_enrichStep()
        self:_automationStep(now)
        self:_stallStep(now)
        self:_refreshLifecycle(now)
        if self.dirty then self:redraw() end
    end)
    if not ok then self:_recordError("coordinator", reason) end
end
```

This is a last-resort net, not a replacement for the existing per-call
`pcall`s -- it specifically closes the `_model()`/`_syncPageCounts()` gap
in `redraw` (and any other bookkeeping code that isn't already wrapped)
without needing to enumerate every possible defect. `_recordError` sets
`self.dirty = true`, so the next `workStep` still redraws with the
newly-recorded alert visible.

`Coordinator:run`'s `events()` loop gets the same treatment around
`self:handle(...)`:

```lua
local function events()
    while true do
        local event = {os.pullEventRaw()}
        local ok, reason = pcall(self.handle, self, event)
        if not ok then self:_recordError("input", reason) end
    end
end
```

After this change, the top-level `xpcall` in `main.lua` should only ever
fire for failures in `pcall`/`xpcall` machinery itself or a stack
overflow -- not for ordinary application-level bugs.

### 2. Alerts auto-clear on success (`app/coordinator.lua`)

Add a small helper next to `_recordError`:

```lua
function Coordinator:_clearError(component)
    if self.deps.alerts and type(self.deps.alerts.resolve) == "function" then
        pcall(self.deps.alerts.resolve, self.deps.alerts, "component_error:" .. tostring(component))
    end
end
```

Every existing `if not ok then self:_recordError(X, reason) end` call
site that has a meaningful "this succeeded" branch gets a matching
`else self:_clearError(X) end` (or the equivalent restructure where the
site is an `elseif` chain). This applies to, at minimum: `_scanStep`'s
scanner result, `_enrichStep`'s search/index result, `_automationStep`'s
service tick (line ~495-498), `_dispatch`'s per-effect handlers (request,
alert, recovery, craft, command, ui, setup, turtle link), `handle`'s
keymap dispatch, and `redraw`'s terminal/monitor/craft-monitor render
calls. Each of these already has a component name in its `_recordError`
call; `_clearError` reuses the same name so the key matches exactly.

Where a call site's "success" doesn't map to a single clean point (e.g.
`_scanStep` scans one node per call, not all nodes at once), clear using
that same per-unit key rather than trying to batch it -- consistent with
how `_recordError` already scopes those alerts per-node/per-component.

No changes to `alerts.lua` itself: `set`/`resolve` already do exactly
what's needed.

### 3. One Dismiss action (`app/alerts.lua`, `app/coordinator.lua`, `app/ui.lua`, `app/keymap.lua`)

**`app/alerts.lua`**: delete `Alerts:acknowledge` and the `acknowledged`
/ `acknowledged_at` fields entirely. `Alerts:set`/`:resolve`/`:active`
are unchanged.

**`app/coordinator.lua`**: when building the alerts list for the view
model (currently `coordinator.lua:982`), annotate the one alert that
needs confirmation. The BLOCKED-recovery alert is the only one that ever
needs this, and the coordinator already has both `alerts:active()` and
`recovery.status()` in scope at that point:

```lua
local recoveryBlocked = self.deps.recovery and
    serviceState("recovery", self.deps.recovery) == "BLOCKED"
for _, alert in ipairs(alerts) do
    alert.requires_confirm = recoveryBlocked and alert.key == "journal_recovery"
end
```

Replace the `ACKNOWLEDGE_ALERT` effect with `DISMISS_ALERT`, keeping the
same shape as the handler it replaces (`coordinator.lua:583-588`) but
calling `resolve` instead of `acknowledge`:

```lua
elseif effect.type == "DISMISS_ALERT" and self.deps.alerts then
    local target = self.deps.alerts.active and self.deps.alerts:active()[effect.index]
    if target then
        local ok, reason = pcall(self.deps.alerts.resolve, self.deps.alerts, target.key)
        if not ok then self:_recordError("alert", reason) end
    end
```

**`app/ui.lua` reducer**: `ACKNOWLEDGE_ALERT`'s case becomes:

```lua
elseif kind == "DISMISS_ALERT" then
    local alert = (model.alerts or {})[state.alert_selection]
    if alert and alert.requires_confirm then
        state.recovery_confirm_armed = true
        state.notice = "Press Enter to release recovery: gives up proof of what the " ..
            "interrupted transfer moved. Any other key cancels."
    else
        return state, {type="DISMISS_ALERT", index=state.alert_selection}
    end
```

The existing `ARM_RECOVERY_RELEASE` / `CANCEL_RECOVERY_RELEASE` /
`CONFIRM_RECOVERY_RELEASE` cases and the `RESOLVE_RECOVERY` effect are
unchanged -- Dismiss now arms the same state machine instead of a
separate key doing it.

`UI:_alerts` (`app/ui.lua:825-853`) drops the `acknowledged and "-" or
"!"` marker (nothing left to distinguish -- an alert is either listed or
it's gone) and simplifies to a plain severity-colored row.

**`app/keymap.lua`**: on the `alerts` page, replace both bindings

```lua
if key == keys.a then return {type="ACKNOWLEDGE_ALERT"} end
if key == keys.x then return {type="ARM_RECOVERY_RELEASE"} end
```

with one:

```lua
if key == keys.a then return {type="DISMISS_ALERT"} end
```

The `recovery_confirm_armed` key-handling block above it
(`keymap.lua:74-78`) is unchanged -- it already takes over all key
handling once armed, regardless of what armed it.

Footer hint text (`app/ui.lua:616`) changes from `"Up/Down A acknowledge
X+Enter release recovery"` to `"Up/Down A dismiss"`.

### 4. Monitor banner (`app/monitor.lua`)

No code change. It already renders `model.highest_alert` straight from
`alerts:active()`; sections 2 and 3 make that list -- and therefore the
banner -- clear itself.

## Testing

- **Crash hardening**: inject a dependency (e.g. a fake `alerts` or
  `ui`) whose method throws, drive one `workStep`/`handle` call, and
  assert the coordinator is still usable afterward (subsequent calls
  succeed) and a `component_error:coordinator` (or `input`) alert was
  recorded. Cover both the `_model()`/`redraw` path and the `events()`
  path.
- **Auto-clear**: for a representative sample of `_recordError` call
  sites (at least `_automationStep`'s service tick and one `_dispatch`
  effect), drive a failing call followed by a succeeding one and assert
  the corresponding `component_error:*` alert is present after the
  first and gone after the second.
- **Dismiss reducer**: an ordinary alert dispatches `DISMISS_ALERT` and
  is removed from `alerts:active()`; the `requires_confirm` alert instead
  arms `recovery_confirm_armed` and leaves the alert present until
  `CONFIRM_RECOVERY_RELEASE` fires; any other key while armed still
  cancels (existing behavior, re-verify unchanged).
- **Regression**: remove/replace the existing `acknowledge`-specific
  test(s); the full `controller/storage/tests/run.lua` suite (753 tests
  as of this writing) must still pass.
- Host tests only, per `CONTRIBUTING.md` -- nothing here touches a live
  installation.

## Risks

- Wrapping `workStep` in `pcall` changes what "the coordinator is
  broken" looks like from the outside: previously a crash was visible as
  the whole program dying (loud, but unambiguous); now it's a
  `component_error:coordinator` alert like any other (quieter, but the
  app keeps running). This is the intended tradeoff, but it means a
  genuinely fatal, unrecoverable defect (e.g. corrupted `self` state)
  could now loop forever inside a `pcall` that keeps catching the same
  error every tick instead of stopping. `_recordError`'s auto-clear
  (section 2) won't clear this one, since the same component keeps
  failing, so the alert (and monitor banner) will stay lit -- which is
  the correct signal for that case.
- Broad `else self:_clearError(X) end` additions touch many call sites
  in an already-large file (`coordinator.lua` is ~1039 lines); each one
  needs to be checked individually against the surrounding branch
  structure (several are `elseif` chains, not simple `if/else`) rather
  than mechanically templated.
