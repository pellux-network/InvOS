# Colossal Storage v1 Operations

## Physical topology

Use one advanced computer as the controller. Connect it, the Drop-off inventory, the Pickup inventory, every Colossal Chest interface, and the status monitor to one wired modem network. Right-click each wired modem so its red connection indicator is active.

Expose exactly one inventory interface per physical Colossal Chest. Multiple interfaces on the same structure can make one inventory appear twice and invalidate capacity and transfer planning. The setup validator flags identical interfaces, but the operator remains responsible for confirming the physical topology.

The Drop-off and Pickup must be separate inventories and must not be Colossal Chest storage nodes. Wireless modems do not expose adjacent inventories to the peripheral network.

## Fresh install

1. Shut down the target ComputerCraft computer.
2. Confirm its numeric computer ID and label.
3. Copy only the files listed in `controller/colossal/deployment_manifest.lua`, preserving paths relative to `controller/`.
4. Do not copy tests, documentation, Git files, development helpers, or any `colossal/data` directory.
5. Boot the computer. Root `startup.lua` launches `/colossal/main.lua` automatically.

The first boot opens the full-screen setup wizard. Setup remains read-only until the final save.

## First setup

1. Review wired inventory discovery.
2. Assign the dedicated Drop-off.
3. Assign the dedicated Pickup.
4. Add each physical Colossal Chest once. Give every node a recognizable label. Lower priority numbers receive imports first.
5. Run validation. It checks availability, required wired-inventory methods, role collisions, and suspicious duplicate Colossal interfaces without moving items.
6. Review and save. The installation captures the controller computer ID and starts indexing immediately; no reboot is required.

Use `5 SETUP` from the main interface to review or change configuration later. Arrow keys, Enter, Left/Right, and F10 control the wizard; Escape is intentionally not captured because Minecraft uses it to close the computer screen.

## Normal use

Put items in Drop-off. The controller imports them into healthy storage nodes in priority order. Items already in storage are indexed automatically.

Importing is batched. Each cycle scans storage, issues every planned move, then rescans to measure what actually landed, so the cost of a cycle is mostly fixed regardless of how much it carries. Two limits bound a batch: `slot_batch_limit` caps how many Drop-off slots join one cycle, and `batch_limit` caps the total moves issued in it. Raising `slot_batch_limit` is what makes a large mixed drop-off drain quickly; it ships at 1, matching single-slot importing, and should only be raised after the multi-item path has been watched on a live controller. Every item type in a batch is still measured separately against its own before-and-after storage total, so a batch spanning many types is proven exactly as one type is.

On the controller, type any part of an item name. Results update while background scans continue. Select an item, choose an exact NBT variant when necessary, and request one, a stack, all available, or an exact number. Retrieved items arrive in Pickup. The public monitor is status-only and resizes automatically.

Avoid manually changing storage while a transfer is verifying. The controller treats complete live storage scans as truth, measures movement by exact item-and-NBT totals across the whole configured storage pool, and waits rather than guessing when a node is unavailable or an unrelated change makes the result ambiguous.

## Lifecycle states

- `READY`: required inventories are healthy and the initial index is complete.
- `DEGRADED`: search and status remain usable, but inventory movement waits whenever a configured storage node or required I/O inventory is unhealthy.
- `PAUSED`: scans and UI remain available, but automated movement is stopped by the operator.
- `RECOVERING`: reserved for compatibility; current recovery runs as a responsive background worker and does not globally replace the UI.
- `SETUP_REQUIRED`: configuration is absent, invalid for this computer, or not yet committed.
- `INDEXING`: the initial live inventory index is still being built.
- `ERROR`: persistence or another critical controller boundary failed. Input remains available when safe.

## Recovery

### Full inventory

Empty or expand the named Drop-off, Pickup, or storage node. The alert remains active while blocked work is preserved.

Most blocked work resumes on its own: a changed inventory generation or the expiring retry backoff returns it to planning without a restart. Two cases deliberately do not, because a move that measured zero must not be replayed from unrelated background scan generations:

- An import blocked as `SHORT_TRANSFER`, meaning storage accepted nothing.
- A request blocked as `PICKUP_FULL`, meaning Pickup accepted nothing.

Both wait for an explicit operator retry. Until retry and cancel are bound to keys, the only way to issue one is to restart the controller, which clears in-flight import and request state without touching storage.

### Offline node

Check the wired modem, cable, interface, and chunk loading. Reattaching the peripheral schedules it for an immediate targeted scan. Search remains available in `DEGRADED`, but transfers wait for every configured storage node so pooled totals cannot omit inventory.

### Ambiguous journal

After a restart, the controller reconciles an unfinished call from the saved exact identity total across the recorded storage-node scope. It never inspects remembered Pickup/Drop-off contents, trusts a compacted slot, or repeats the call. If every recorded node is healthy, recovery completes from the aggregate delta and retires the journal. If the delta is impossible or the journal cannot be proven, the normal UI remains responsive but inventory automation stays blocked behind a critical alert. Do not delete the journal or repeat the request; restore every recorded storage node and review any concurrent manual storage changes.

If the block cannot be cleared by restoring nodes, an operator can release it explicitly. Releasing retires the unprovable journal, records a warning naming the release, and lets automation continue. Only do this after comparing storage totals against expectations, because releasing abandons the attempt to prove what the interrupted call moved.

A Drop-off change noticed before any inventory call is not ambiguous, because nothing was issued. The import abandons that attempt and rediscovers whatever the Drop-off holds next tick, so taking items back out of Drop-off mid-import no longer stalls importing.

### Corrupted configuration

The staged store retains one previous validated configuration. If neither copy is valid, the controller enters setup. Recover a configuration-only floppy or reassign the inventories. Never copy a config from another controller without reviewing and committing it; installation identity is recaptured during recovery.

### Failed metadata

Names and stack sizes are enriched gradually. A failed `getItemDetail` call does not stop scanning or input. Restore the peripheral connection and allow the next enrichment pass to retry.

## Floppy backup and recovery

Backups contain only validated configuration and item aliases. They intentionally exclude program files, inventory counts, derived indexes, request history, transfer journals, and snapshots.

Insert a writable floppy in a connected disk drive and use the backup action. On a fresh installation, choose recovery in setup, review every discovered binding, run validation, and explicitly save. Recovery never enables automation automatically.

## Upgrade and rollback

1. Pause automation and wait until no transfer is in `TRANSFERRING` or `VERIFYING`.
2. Make a configuration/alias floppy backup.
3. Shut down the controller.
4. Replace only manifest-listed runtime files. Preserve that computer's `colossal/data` directory in place.
5. Boot, confirm the installation identity, and verify `READY` before resuming normal use.

For rollback, restore the previous runtime files while leaving local data in place. Never move inventory snapshots or journals between computers. If data schema compatibility is uncertain, recover the configuration-only floppy through fresh setup instead.

Before any live installation, rerun the creative-world compatibility script against the target modpack and require `ALL TESTS PASSED`. Then perform a disposable-stack conservation smoke test: Drop-off + Pickup + all storage counts must equal the starting count.
