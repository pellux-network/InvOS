# Colossal Storage v1 Design

**Date:** 2026-08-02
**Status:** Written specification awaiting user review

## Purpose

Build a new CC:Tweaked storage terminal around wired inventory transfers rather than mobile turtle sorting. One controller presents a seamless pooled view of any number of Colossal Chests, imports items from a dedicated drop-off inventory, and fulfills exact item-and-quantity requests into a dedicated pickup inventory.

This is a separate project from the route-driven drop-off organizer. Infrastructure ideas may be reused, but navigation, backplanes, chest assignments, mobile fuel management, and route teaching are out of scope.

## Confirmed platform behavior

An in-game compatibility test passed against the pack's Colossal Chest implementation:

- The interface appeared as a CC:Tweaked `inventory` peripheral.
- A 3,075-slot Colossal Chest returned its complete sparse inventory through `list()`.
- `pushItems` withdrew an exact source slot and quantity.
- Reverse transfer deposited an exact quantity.
- NBT identity and counts remained consistent, and cleanup restored both inventories.

## Version 1 scope

Version 1 includes:

- Search, browse, and exact-quantity retrieval.
- Automatic import from one dedicated drop-off inventory.
- One dedicated pickup inventory used only for fulfilled requests.
- Any number of configured, labeled, prioritized Colossal Chest storage nodes.
- A pooled NBT-aware inventory index.
- Responsive advanced-computer UI and resizable status monitor.
- Transfer journaling, reconciliation, alerts, setup, and settings backup.

Version 1 excludes crafting execution, recipe definitions, route movement, GPS, physical container mapping, and mobile turtle fuel management. It preserves a request/worker boundary for a stationary crafty-turtle worker in version 2.

## Physical topology

All managed inventories are attached to one CC:Tweaked wired network:

- Controller wired modem.
- One wired modem on the drop-off inventory.
- One wired modem on the pickup inventory.
- One wired modem on exactly one Interface block per physical Colossal Chest.

The controller may also have a wireless modem later for a crafting worker, but wireless communication is not required for v1 storage transfers.

Only one interface per physical Colossal Chest may be configured. Configuring two interfaces for the same multiblock would double-count one physical inventory. Setup warns about suspicious nodes with identical size and contents but does not silently decide that they are duplicates.

## Component architecture

### Peripheral registry

Discovers inventory peripherals and stores explicit role bindings:

- `dropoff`: exactly one required inventory.
- `pickup`: exactly one required inventory.
- `storage`: one or more labeled nodes with stable internal IDs and priorities.

Raw peripheral names are stored bindings, not user-facing identities. Missing or renamed peripherals remain offline until explicitly rebound.

### Inventory scanner

Scans one inventory at a time and returns a validated snapshot containing peripheral identity, scan epoch, size, occupied slots, item identities, counts, and health. Scans are protected against peripheral exceptions and invalid responses.

Storage nodes are scanned in rotation so a large pool cannot monopolize the event loop. Transfer-affected nodes receive an immediate targeted rescan. The index stores stale snapshots for display only and never allocates from stale data.

### Metadata catalogue

The basic inventory API supplies registry name, count, and optional NBT fingerprint. The catalogue fetches one representative `getItemDetail` per identity in the background to cache display name, maximum stack size, and useful searchable metadata.

Search remains usable before enrichment finishes. User-defined aliases are persistent and override neither registry identity nor NBT identity.

### Pooled index

The index maps each item identity to live source records:

```lua
{
  inventory_id = "main",
  peripheral_name = "colossalchests:colossal_chest_0",
  slot = 417,
  name = "minecraft:cobblestone",
  nbt = nil,
  count = 64,
}
```

Identical identities aggregate across slots and storage nodes for display and allocation. Different NBT fingerprints remain separate variants. The index is entirely rebuildable and is never backed up as stock truth.

### Import engine

The import engine scans occupied drop-off slots and transfers them into the storage pool. Allocation order is:

1. Live storage slots already containing the exact identity and having room.
2. Empty capacity in storage-node priority order.
3. Subsequent healthy nodes when a transfer moves less than requested.

The engine uses returned moved quantities as authoritative, rescans affected inventories, and leaves any unaccepted remainder in Drop-off. It never discards, drops, or substitutes an item.

### Request and transfer engine

A retrieval request contains request ID, exact item identity, requested quantity, and creation epoch. The planner allocates live source slots across any number of storage nodes.

Before transfer it verifies:

- Requested identity and quantity are still available.
- Pickup is online and has compatible space.
- Every planned source snapshot is fresh.
- No conflicting transfer owns the same source slot.

Execution journals each planned step, invokes `pushItems`, records the actual moved count, and rescans source and pickup inventories. A request ends as `COMPLETE`, `PARTIAL`, `BLOCKED`, `FAILED`, or `CANCELLED`. It never reports success from planned quantities alone.

### Controller coordinator

The coordinator owns cooperative loops for UI events, heartbeat/ticks, rotating scans, imports, requests, metadata enrichment, backup, and monitor redraws. Long operations are bounded and yield between units of work. A failed scan or transfer cannot terminate the UI loop.

### Crafting extension boundary

The request engine distinguishes terminal withdrawal requests from future worker requests. Version 2 may reserve ingredients into a staging inventory, dispatch a crafting job, verify outputs, and return results through the same inventory and request primitives. No recipe format or crafting behavior is defined in v1.

## Search-first terminal UI

The advanced computer opens directly to Search. At the standard 51x19 terminal size it contains:

- Compact health header.
- Always-focused search field.
- Ranked result list with display name and pooled live quantity.
- Selected identity/variant details.
- Context-sensitive fixed footer.

Typing updates results immediately. Ranking order is:

1. Exact display-name match.
2. Word-prefix match.
3. Registry-name or alias match.
4. Substring match.
5. Conservative fuzzy match for minor typographical errors.

An empty query shows recent and frequently requested identities. Search operates on the last immutable index snapshot and never waits synchronously for storage scans or metadata calls.

Enter opens a quantity prompt:

- Enter again requests one.
- `S` requests one maximum stack.
- `A` requests all currently available.
- Digits enter an exact quantity.
- Back/F10 cancels without losing the query.

When multiple NBT variants exist, the UI presents a variant chooser. It does not merge incompatible gear, tools, or modded identities. Mouse input is supported but every workflow is keyboard-complete.

Secondary pages provide Storage Nodes, Requests, Alerts, and Setup. Search remains one key away from every page.

## Resizable monitor

The monitor is status-only. Every render reads its current dimensions, and `monitor_resize` triggers immediate redraw.

Breakpoints are content-driven:

- Small: overall state, storage availability, and highest alert.
- Medium: pool summary, storage-node health, Drop-off/Pickup state, and active request.
- Large, including the existing 2x6 wall: node overview, recent transfers, current activity, I/O state, and prominent alerts with deliberate spacing.

A monitor failure never affects terminal input or inventory processing.

## State models

### Controller lifecycle

- `BOOTING`: loading and validating local persistence; automation is not active.
- `SETUP_REQUIRED`: required role bindings or configuration are absent or invalid.
- `RECOVERING`: an unfinished journal exists; affected inventories are being rescanned and no new transfers may start.
- `INDEXING`: configuration is valid and initial live snapshots are being built.
- `READY`: all required I/O and at least one storage node are healthy; imports and requests may run.
- `DEGRADED`: core service remains safe and usable with reduced capacity or a non-critical component unavailable.
- `PAUSED`: the operator has stopped new automation; scans and UI remain active.
- `ERROR`: a controller-wide invariant or persistence failure makes automated movement unsafe.

The lifecycle is derived centrally from validated conditions and operation ownership. Headers, monitor status, and automation gates all consume this one state; they do not independently infer online/offline status.

### Storage node

- `DISCOVERED`: visible but unconfigured.
- `SCANNING`: current scan in progress.
- `READY`: fresh validated snapshot available.
- `STALE`: last snapshot retained for display but excluded from allocation.
- `OFFLINE`: configured peripheral missing.
- `ERROR`: peripheral call or response invalid.
- `DISABLED`: operator excluded the node.

### Import operation

- `PENDING`: Drop-off contains work.
- `PLANNING`: destination allocation in progress.
- `TRANSFERRING`: one bounded transfer step active.
- `VERIFYING`: affected inventories being rescanned.
- `COMPLETE`: source slot emptied as planned.
- `PARTIAL`: some quantity moved and a remainder remains.
- `BLOCKED`: no healthy storage capacity accepts the remainder.
- `FAILED`: an unexpected operation error requires attention.

### Retrieval request

- `DRAFT`: quantity selection not confirmed.
- `QUEUED`: accepted and awaiting execution.
- `PLANNING`: live sources and pickup capacity being allocated.
- `TRANSFERRING`: one bounded transfer step active.
- `VERIFYING`: actual counts being reconciled.
- `COMPLETE`: requested quantity delivered.
- `PARTIAL`: exact delivered quantity recorded; remainder not delivered.
- `BLOCKED`: pickup capacity, stale source, or temporarily unavailable node prevents progress.
- `FAILED`: invariant or peripheral error requires operator review.
- `CANCELLED`: no further steps will start; already moved items remain accurately reported.

State transitions are explicit and tested. UI labels derive from these states rather than unrelated booleans.

### Transition and retry rules

- Only the coordinator mutates operation state, and every transition is checked against an allowed-transition table.
- One transfer step owns one source slot and one destination at a time. Other work may scan and render, but it may not allocate owned slots.
- `BLOCKED` is recoverable and condition-driven. A relevant peripheral, inventory, or capacity change queues a bounded replan; timers provide rate-limited fallback retries.
- `FAILED` is not retried automatically until its invariant or adapter error has been classified. The operator may retry after the affected inventories are rescanned.
- Cancellation stops future steps only. It never attempts to reverse already verified movement automatically.
- Repeated identical failures use exponential backoff and one deduplicated alert, preventing a bad peripheral from flooding the event loop or disk.
- Every operation records `updated_at`, a concise reason code, and verified moved quantity so the terminal and monitor can explain the current state.

## Failure semantics

- **Storage node offline:** exclude it from allocations, display its last snapshot as stale, and continue using healthy nodes.
- **Pickup full:** reject or block before moving storage items. If the player changes Pickup during execution, record any partial delivery and stop safely.
- **Storage pool full:** leave remaining items in Drop-off and raise a capacity alert.
- **Short transfer:** accept only the returned moved quantity, rescan, and replan the remainder when safe.
- **Peripheral exception:** catch it at the adapter boundary, mark the affected node or operation, and keep other loops running.
- **Peripheral rename/replacement:** require explicit rebind; never infer solely from similar contents.
- **Controller reboot:** enter `RECOVERING`, load configuration and journal, rescan all affected inventories, reconcile actual quantities, then resume only operations proven safe. An ambiguous in-flight step is never replayed automatically; it becomes `FAILED` with the observed counts and requires an operator retry after a fresh scan.
- **Monitor disconnect:** mark display unavailable and continue full terminal operation.
- **Metadata failure:** retain registry-name search and retry enrichment later.
- **Duplicate configured interface:** warn and disable automatic use until the operator resolves it.

Alerts are condition-based and deduplicated. Acknowledging an alert does not resolve its underlying condition; recovery or explicit operator action does.

## Persistence and backup

Persistent local data contains:

- Peripheral bindings, logical node IDs, labels, and priorities.
- Aliases and metadata cache.
- UI preferences.
- Compact request history.
- Active transfer journal.

The floppy backup contains configuration and aliases only. Program source is reinstalled separately. Inventory snapshots, counts, metadata cache, request history, and active journals are excluded from backup.

Writes use validated staged replacement so interruption cannot leave the only active copy truncated. Each persisted document has a schema version and validation step. If the primary document is invalid, the controller attempts the last-known-good staged copy; if neither validates, it enters `SETUP_REQUIRED` for configuration loss or `ERROR` for an unsafe journal loss and does not move items.

## Setup flow

The full-screen setup wizard:

1. Discovers inventory peripherals and their sizes/types.
2. Assigns the unique Drop-off role.
3. Assigns the unique Pickup role.
4. Adds and labels one or more Storage nodes.
5. Sets storage priority order.
6. Validates required methods: `size`, `list`, `getItemDetail`, `getItemLimit`, `pushItems`, and `pullItems` where used.
7. Performs read-only scans and checks role uniqueness.
8. Shows a review page and enables automation only after explicit confirmation.

Setup does not move items during validation. A separate diagnostic tool may perform reversible transfer testing in a disposable chest.

## Testing strategy

Host-side Lua tests use simulated peripheral inventories and deterministic event sources. Required coverage includes:

- Multi-node aggregation and priority allocation.
- Exact and general NBT identities.
- Retrieval spanning multiple slots and nodes.
- Full and concurrently modified Pickup.
- Full storage pool and partial imports.
- Short transfer returns and peripheral exceptions.
- Node disconnect/reconnect and stale snapshot exclusion.
- Reboot journal reconciliation without duplicate movement, including an ambiguous in-flight call that must stop for review.
- Allowed and forbidden lifecycle/operation state transitions, retry backoff, alert deduplication, and pause/resume gates.
- Duplicate interface suspicion and explicit rebinding.
- Search ranking, aliases, fuzzy matching, variants, quantity shortcuts, keyboard flow, mouse flow, and clipping.
- Monitor rendering at small, medium, and 2x6 dimensions.
- Backup content boundaries and interrupted writes.
- UI responsiveness while scans and transfers are active.

The previously passed in-game Colossal Chest transfer script remains the compatibility smoke test for the actual modpack.

## Acceptance criteria

Version 1 is complete when:

- A user can deposit arbitrary items and see them imported without assigning destinations.
- Search remains responsive while multiple Colossal Chests are scanning.
- A user can locate an item by display name, registry name, or alias and request an exact quantity.
- The exact delivered quantity is verified and visible.
- Multiple Colossal Chests behave as one pool with no configured software limit.
- Individual node failure degrades capacity without falsely reporting the whole system offline.
- Full Drop-off, Pickup, and storage conditions produce actionable alerts without loss.
- Reboot reconciliation cannot duplicate a completed transfer.
- The advanced-computer UI is keyboard-complete, mouse-capable, and polished at 51x19.
- The status monitor remains legible and balanced after resizing.
- All host-side tests pass and the in-game compatibility smoke test passes.