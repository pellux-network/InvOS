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

On the controller, type any part of an item name. Results update while background scans continue. Select an item, choose an exact NBT variant when necessary, and request one, a stack, all available, or an exact number. Retrieved items arrive in Pickup. The public monitor is status-only and resizes automatically.

Never manually modify an inventory while its transfer is in progress. The controller verifies every move and will stop rather than guess when observed counts differ.

## Lifecycle states

- `READY`: required inventories are healthy and the initial index is complete.
- `DEGRADED`: the system remains usable with reduced capacity or an unavailable role/node; read the alert.
- `PAUSED`: scans and UI remain available, but automated movement is stopped by the operator.
- `RECOVERING`: a durable transfer journal needs reconciliation; new transfers are blocked.
- `SETUP_REQUIRED`: configuration is absent, invalid for this computer, or not yet committed.
- `INDEXING`: the initial live inventory index is still being built.
- `ERROR`: persistence or another critical controller boundary failed. Input remains available when safe.

## Recovery

### Full inventory

Empty or expand the named Drop-off, Pickup, or storage node. The alert remains active while blocked work is preserved. A changed inventory generation triggers a retry; no restart is required.

### Offline node

Check the wired modem, cable, interface, and chunk loading. Reattaching the peripheral schedules it for an immediate targeted scan. Other healthy storage nodes remain available in `DEGRADED` mode.

### Ambiguous journal

`RECOVERING` after a restart means the controller cannot prove whether an in-flight `pushItems` call occurred. Do not delete the journal or repeat the request blindly. Compare the named source and destination slots, correct any external changes, then use the recovery action shown by the controller. Ambiguous moves require explicit operator intervention.

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
