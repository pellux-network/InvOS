<div align="center">
  <img src="docs/assets/wordmark.svg" alt="InvOS — Inventory Operating System" width="420">

  <p>
    A search-first storage terminal for CC:Tweaked, backed by pooled standard containers
    and an optional crafty-turtle crafting pipeline.
  </p>

  <p>
    <a href="https://github.com/pellux-network/InvOS/releases/latest">
      <img alt="release" src="https://img.shields.io/github/v/release/pellux-network/InvOS?color=B91C2E">
    </a>
    <a href="https://github.com/pellux-network/InvOS/actions/workflows/ci.yml">
      <img alt="CI" src="https://github.com/pellux-network/InvOS/actions/workflows/ci.yml/badge.svg">
    </a>
    <img alt="runtime" src="https://img.shields.io/badge/runtime-CC%3ATweaked%20%2F%20CraftOS-2b2b2b">
    <a href="LICENSE.md">
      <img alt="license" src="https://img.shields.io/badge/license-MIT-blue">
    </a>
  </p>

  <p>
    <a href="https://github.com/pellux-network/InvOS/wiki"><b>Documentation</b></a> ·
    <a href="https://github.com/pellux-network/InvOS/wiki/Installation">Install</a> ·
    <a href="https://github.com/pellux-network/InvOS/wiki/Daily-Use">Daily use</a> ·
    <a href="https://github.com/pellux-network/InvOS/wiki/Troubleshooting">Troubleshooting</a>
  </p>
</div>

---

Point a modpack's worth of storage at one wired network and get one searchable inventory
back. InvOS indexes every storage container you give it, takes deposits through a dedicated
Drop-off, fulfills exact item-and-quantity requests into a dedicated Pickup, and — if you
give it a spare turtle — plans and executes multi-step crafting against your own live
recipe set. No mainframe, no external database: it's one advanced computer, some wired
modems, and over 1,000 tests standing behind it.

<p align="center">
  <img src="docs/assets/screenshots/02-search.png" width="620" alt="InvOS Search page">
</p>

## Why InvOS

- **Search-first.** Type part of a name, get live results while background scans keep
  indexing. No menu tree to dig through.
- **One pooled store.** Any number of standard containers appear as a single inventory with
  priority ordering, not a wall of separate chests to check by hand.
- **NBT-aware.** Distinct NBT variants of the same item are tracked and requested
  separately, so you get the enchanted pickaxe you asked for, not just *a* pickaxe.
- **Crafting that plans ahead.** Ask for 250 sticks and the planner resolves ingredients,
  tags, and multi-step trees against what's *actually in stock* — not a fixed recipe
  ordering — and drives a stationary crafty turtle to make them.
- **Built to survive a restart.** Every in-flight transfer is journaled before the
  inventory call that makes it real. A crash mid-transfer reconciles from measured storage
  deltas on the next boot; nothing is replayed blind and nothing is assumed.
- **Honest about failure.** A full inventory, an offline node, an unprovable journal — each
  becomes a named, operator-actionable alert instead of a silent stall.

## Features

- Responsive, search-first advanced-computer UI, keyboard- and mouse-driven
- A deliberate sixteen-color palette, shared by every screen, restored on exit
- Resizable public status monitor, auto-detecting its own size tier, with the stored-item
  total in block digits readable across a base
- Multiple labeled, priority-ordered storage nodes pooled as one store
- Exact wired-inventory transfers with durable journaling and reconciliation
- Dedicated drop-off and pickup inventories, decoupled from storage
- NBT-aware indexing and requests
- Configuration-and-alias floppy backup
- Optional multi-step crafting through a stationary crafty turtle, from a recipe pack
  generated straight from the running game

Crafting is entirely optional: it's only constructed when a buffer inventory and a turtle
are both bound in configuration. Leave them unbound and nothing else changes.

<p align="center">
  <img src="docs/assets/screenshots/08-monitor.png" width="620" alt="Wall-mounted status monitor">
  <br>
  <sub>The public wall display beside the terminal. <a href="https://github.com/pellux-network/InvOS/wiki">See every screen in the wiki.</a></sub>
</p>

## Quick start

1. Wire one advanced computer, a dedicated Drop-off inventory, a dedicated Pickup
   inventory, every storage container interface, and (optionally) a crafty turtle with its
   buffer chest, all onto one wired modem network.
2. On the computer, run:

   ```
   wget run https://raw.githubusercontent.com/pellux-network/InvOS/main/install.lua
   ```

   Run the same command on the turtle — the installer detects which one it's running on.
   This needs `http` enabled in the server's ComputerCraft config.
3. Boot the computer. `startup.lua` launches the application and opens the setup wizard on
   first run. Setup stays read-only until you explicitly save.
4. Deposit items in Drop-off. InvOS imports them into priority order automatically, and
   indexes anything already sitting in storage.

Full detail: **[Installation](https://github.com/pellux-network/InvOS/wiki/Installation)**,
**[Hardware Setup](https://github.com/pellux-network/InvOS/wiki/Hardware-Setup)**, and
**[First-Run Setup](https://github.com/pellux-network/InvOS/wiki/First-Run-Setup)**.

## Documentation

The **[wiki](https://github.com/pellux-network/InvOS/wiki)** is the place to start.

| | |
|---|---|
| **Getting started** | [Installation](https://github.com/pellux-network/InvOS/wiki/Installation) · [Hardware Setup](https://github.com/pellux-network/InvOS/wiki/Hardware-Setup) · [First-Run Setup](https://github.com/pellux-network/InvOS/wiki/First-Run-Setup) |
| **Using InvOS** | [Daily Use](https://github.com/pellux-network/InvOS/wiki/Daily-Use) · [Crafting](https://github.com/pellux-network/InvOS/wiki/Crafting) · [Keybindings](https://github.com/pellux-network/InvOS/wiki/Keybindings) · [Status and Alerts](https://github.com/pellux-network/InvOS/wiki/Status-and-Alerts) |
| **When things go wrong** | [Troubleshooting](https://github.com/pellux-network/InvOS/wiki/Troubleshooting) · [Recovery](https://github.com/pellux-network/InvOS/wiki/Recovery) |
| **Contributing** | [Architecture](https://github.com/pellux-network/InvOS/wiki/Architecture) · [Development](https://github.com/pellux-network/InvOS/wiki/Development) |

In this repository:

| File | What it's for |
|---|---|
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Workflow, test expectations, code conventions, releases |
| [`AGENTS.md`](AGENTS.md) | The runtime and crafting invariants, and the reasoning behind each |
| [`docs/operations.md`](docs/operations.md) | Deploying to a live installation, and generating a recipe pack |
| [`docs/emulator.md`](docs/emulator.md) | Running InvOS headlessly under CraftOS-PC |
| [`docs/backlog.md`](docs/backlog.md) | Known gaps and untested paths, ordered by risk |

## Architecture

- `controller/` — the deployable CraftOS controller. `storage/app/` holds services,
  coordination, setup, and rendering; `storage/core/` holds scanning, indexing, planning,
  transfers, and reconciliation; `storage/shared/` holds runtime, codec, and durable-store
  helpers.
- `turtle/` — the crafting turtle's own deployable tree. It never shares files with the
  controller in either direction.
- `tools/` — host-side build tooling that is never deployed: the recipe-pack converter, the
  live deployment gate, and a CraftOS-PC harness that boots and screenshots the controller
  headlessly.

The load-bearing design decision: **transfer intent is journaled before the inventory call
that makes it real, and reconciliation trusts measured storage deltas rather than what a
call claimed it did.** Everything about recovery follows from that.

See [Architecture](https://github.com/pellux-network/InvOS/wiki/Architecture) for the full
picture, and [`AGENTS.md`](AGENTS.md) for the invariants themselves.

## Development

```bash
# Lua suite (from controller/)
lua storage/tests/run.lua

# Python suite (from tools/)
python -m unittest test_recipe_pack test_recipe_import test_deploy

# install.lua's pure functions (from the repo root)
lua install_test.lua

# Emulator harness (from tools/emulator/) — the second command boots CraftOS-PC
python3 -m unittest test_rawterm test_scenario test_render test_session
python3 -m unittest test_smoke test_smoke_nbt test_install
```

InvOS runs unmodified in [CraftOS-PC](https://www.craftos-pc.cc), so a change can be booted
under the same Lua 5.2 ComputerCraft uses — the host suite runs on 5.4 — and its terminal
read back as text or rendered to a PNG.

[`CONTRIBUTING.md`](CONTRIBUTING.md) has the full workflow and the live-deployment safety
rules. [Development](https://github.com/pellux-network/InvOS/wiki/Development) covers the
repository layout, the emulator, and recipe-pack generation.

## License

MIT — see [`LICENSE.md`](LICENSE.md).
