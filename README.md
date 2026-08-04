# ComputerCraft Colossal Storage

A search-first CC:Tweaked storage terminal backed by one or more networked Colossal Chests.

The controller indexes wired inventory peripherals, imports items from a dedicated drop-off inventory, and fulfills exact item-and-quantity requests into a dedicated pickup inventory. Multiple Colossal Chests appear as one pooled store. A stationary crafty turtle adds multi-step recipe crafting.

## Status

Deployed and running. The controller handles imports, retrieval, and crafting; all three have been exercised on a live server.

## Scope

- Responsive search-first advanced-computer UI
- Resizable status monitor
- Multiple labeled storage nodes
- Exact wired inventory transfers
- Dedicated drop-off and pickup inventories
- NBT-aware indexing and requests
- Durable transfer reconciliation and explicit error states
- Configuration-and-alias backup
- Multi-step crafting through a stationary crafty turtle, from a generated recipe pack

Crafting is optional: it is only constructed when a buffer inventory and a turtle are both bound in configuration. Without them nothing else changes.

The recipe pack ships with vanilla recipes. `tools/recipe_import.py --mods` regenerates it from a whole modpack; see `docs/operations.md`.

## Development

The deployable controller lives under `controller/`. From that directory, run the Lua suite with:

```text
lua colossal/tests/run.lua
```

Tests and documentation are development artifacts and must never be copied to a live ComputerCraft computer.
## Installation and operations

The exact deployment allow-list is `controller/colossal/deployment_manifest.lua`. Copy those paths relative to `controller/` only; the manifest excludes tests, documentation, development helpers, and mutable data.

See `docs/operations.md` for wired topology, setup, lifecycle states, backup/recovery, upgrades, and the required live-deployment safety gate. No live server files are changed by repository development or tests.