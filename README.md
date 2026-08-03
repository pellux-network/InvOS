# ComputerCraft Colossal Storage

A search-first CC:Tweaked storage terminal backed by one or more networked Colossal Chests.

The controller indexes wired inventory peripherals, imports items from a dedicated drop-off inventory, and fulfills exact item-and-quantity requests into a dedicated pickup inventory. Multiple Colossal Chests appear as one pooled store. A stationary crafty turtle can be added in a later version for recipe-based crafting.

## Status

Version 1 is being implemented from the approved design in `docs/superpowers/specs/2026-08-02-colossal-storage-v1-design.md`.

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