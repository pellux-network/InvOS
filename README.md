# ComputerCraft Colossal Storage

A search-first CC:Tweaked storage terminal backed by one or more networked Colossal Chests.

The controller indexes wired inventory peripherals, imports items from a dedicated drop-off inventory, and fulfills exact item-and-quantity requests into a dedicated pickup inventory. Multiple Colossal Chests appear as one pooled store. A stationary crafty turtle can be added in a later version for recipe-based crafting.

## Status

Version 1 is implemented on the feature branch with a cooperative controller, durable exact transfers, a first-run setup wizard, responsive search and retrieval, and a resizable public status monitor. Crafting remains reserved for version 2.

## Scope

- Responsive search-first advanced-computer UI
- Resizable status monitor
- Multiple labeled storage nodes
- Exact wired inventory transfers
- Dedicated drop-off and pickup inventories
- NBT-aware indexing and requests
- Durable transfer reconciliation and explicit error states
- Configuration-and-alias backup

Crafting and recipe storage are intentionally reserved for version 2.

## Development

The deployable controller lives under `controller/`. From that directory, run the Lua suite with:

```text
lua colossal/tests/run.lua
```

Tests and documentation are development artifacts and must never be copied to a live ComputerCraft computer.
## Installation and operations

The exact deployment allow-list is `controller/colossal/deployment_manifest.lua`. Copy those paths relative to `controller/` only; the manifest excludes tests, documentation, development helpers, and mutable data.

See `docs/operations.md` for wired topology, setup, lifecycle states, backup/recovery, upgrades, and the required live-deployment safety gate. No live server files are changed by repository development or tests.