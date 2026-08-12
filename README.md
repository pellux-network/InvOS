<div align="center">
  <img src="docs/assets/wordmark.svg" alt="InvOS — Inventory Operating System" width="420">

  <p>
    A search-first storage terminal for CC:Tweaked, backed by pooled Colossal Chests
    and an optional crafty-turtle crafting pipeline.
  </p>

  <p>
    <img alt="status" src="https://img.shields.io/badge/status-deployed%20%26%20live-B91C2E">
    <img alt="lua tests" src="https://img.shields.io/badge/lua%20tests-600%20passing-B91C2E">
    <img alt="python tests" src="https://img.shields.io/badge/python%20tests-74%20passing-B91C2E">
    <img alt="runtime" src="https://img.shields.io/badge/runtime-CC%3ATweaked%20%2F%20CraftOS-2b2b2b">
  </p>
</div>

---

Point a modpack's worth of storage at one wired network and get one searchable inventory
back. InvOS indexes every Colossal Chest you give it, takes deposits through a dedicated
Drop-off, fulfills exact item-and-quantity requests into a dedicated Pickup, and — if you
give it a spare turtle — plans and executes multi-step crafting against your own live
recipe set. No mainframe, no external database: it's one advanced computer, some wired
modems, and about 600 tests standing behind it.

## Why InvOS

- **Search-first.** Type part of a name, get live results while background scans keep
  indexing. No menu tree to dig through.
- **One pooled store.** Any number of Colossal Chests appear as a single inventory with
  priority ordering, not a wall of separate chests to check by hand.
- **NBT-aware.** Distinct NBT variants of the same item are tracked and requested
  separately, so you get the enchanted pickaxe you asked for, not just *a* pickaxe.
- **Crafting that plans ahead.** Ask for 250 sticks and the planner resolves ingredients,
  tags, and multi-step trees against what's *actually in stock* — not a fixed recipe
  ordering — and drives a stationary crafty turtle to make them.
- **Built to survive a restart.** Every in-flight transfer is journaled before the
  inventory call that makes it real. A crash mid-transfer reconciles from measured storage
  deltas on the next boot; nothing is replayed blind and nothing is assumed.
- **Honest about failure.** Full inventory, an offline node, an unprovable journal — every
  one of these becomes a named, operator-actionable alert instead of a silent stall.

## What it looks like

InvOS runs on the computer's own terminal for search and control, with an optional large
status monitor and a 1×1 crafting monitor for anyone walking by:

```
┌────────────────────────────────────────────────────┐
│ InvOS                                        READY  │
│ Search: oak plank_                                   │
│                                                        │
│   > Oak Planks                            4,213       │
│     Oak Log                                 812       │
│     Oak Fence                                96        │
│     Oak Fence Gate                           12        │
│                                                        │
│ 1 Search  2 Nodes  3 Requests  4 Alerts  5 Setup      │
└────────────────────────────────────────────────────┘
```

A cold boot plays a brief animated wordmark on the terminal before the application takes
over — see [`controller/colossal/app/splash.lua`](controller/colossal/app/splash.lua).

## Status

**Deployed and running.** Imports, retrievals, and crafting have all been exercised on a
live server, against a live-exported recipe pack of 24,583 recipes across 22,391 craftable
outputs. See [`docs/backlog.md`](docs/backlog.md) for the known gaps and untested paths,
tracked openly rather than hidden.

## Features

- Responsive, search-first advanced-computer UI
- Resizable public status monitor, auto-detecting its own size tier
- Multiple labeled, priority-ordered storage nodes pooled as one store
- Exact wired-inventory transfers with durable journaling and reconciliation
- Dedicated drop-off and pickup inventories, decoupled from storage
- NBT-aware indexing and requests
- Configuration-and-alias floppy backup
- Optional multi-step crafting through a stationary crafty turtle, from a recipe pack
  generated straight from the running game

Crafting is entirely optional: it's only constructed when a buffer inventory and a turtle
are both bound in configuration. Leave them unbound and nothing else changes.

## Quick start

1. Wire one advanced computer, a dedicated Drop-off inventory, a dedicated Pickup
   inventory, every Colossal Chest interface, and (optionally) a crafty turtle with its
   buffer chest, all onto one wired modem network.
2. Copy only the paths listed in
   [`controller/colossal/deployment_manifest.lua`](controller/colossal/deployment_manifest.lua),
   relative to `controller/`, onto the computer. Never copy tests, docs, or development
   helpers — they're excluded by design.
3. Boot the computer. `startup.lua` launches `/colossal/main.lua` automatically and opens
   the full-screen setup wizard on first run. Setup stays read-only until you explicitly
   save.
4. Deposit items in Drop-off. InvOS imports them into priority order automatically, and
   indexes anything already sitting in storage.

Full topology, setup, recovery, upgrade, and deployment-safety details live in
[`docs/operations.md`](docs/operations.md) — read it before touching a live installation.

## Usage

Type any part of an item name on the Search page; results update live as background scans
continue. Select an item, resolve an exact NBT variant if there is one, and request a
single item, a stack, everything available, or an exact number. Digit keys `1`–`5` jump
straight to Search, Nodes, Requests, Alerts, and Setup; `F10` always returns to Search.

With a turtle and buffer bound, key `6` opens Crafting: pick a craftable output — including
ones you currently hold none of — enter a quantity, review the plan, and commit. A quantity
means *make that many*, not *top up to that many*; the "up to" behaviour is an ordinary
Search retrieval.

## Architecture

- `controller/` — the deployable CraftOS controller.
  - `colossal/app/` — services, coordination, setup, UI, and monitor rendering.
  - `colossal/core/` — inventory scanning, indexing, planning, transfers, and
    reconciliation.
  - `colossal/shared/` — runtime, codec, and durable-store helpers.
  - `colossal/recipes/` — the generated crafting recipe pack; never hand-edited.
- `turtle/` — the crafting turtle's own deployable tree. It never shares files with the
  controller in either direction.
- `tools/` — host-side build tooling that is never deployed: `recipe_import.py` builds the
  recipe pack, `deploy.py` gates every live deployment.

See [`AGENTS.md`](AGENTS.md) for the full set of runtime and crafting invariants this
system is built against — the reasoning behind the design, not just the shape of it.

## Development

```bash
# Lua suite (from controller/)
lua colossal/tests/run.lua

# Python suite (from tools/)
python -m unittest test_recipe_pack test_recipe_import
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full development workflow, testing
expectations, and the live-deployment safety rules that apply to any change touching a real
installation.

## License

No license has been chosen for this repository yet. Until one is added, all rights are
reserved by default — open an issue if you'd like to use this code and a license hasn't
shown up.
