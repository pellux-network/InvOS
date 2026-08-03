# AGENTS.md

## Project

This repository contains a search-first CC:Tweaked wired-inventory storage terminal backed by one or more Colossal Chests. Version 1 supports Drop-off imports, pooled NBT-aware indexing, exact retrieval requests, a controller UI, and a resizable public monitor. Crafting remains future work.

## Repository layout

- `controller/startup.lua` is the deployable CraftOS entry point.
- `controller/colossal/main.lua` assembles the application.
- `controller/colossal/app/` contains services, coordination, setup, UI, and monitor rendering.
- `controller/colossal/core/` contains inventory scanning, indexing, planning, transfers, reconciliation, and registry logic.
- `controller/colossal/shared/` contains runtime, codec, and durable-store helpers.
- `controller/colossal/tests/` contains the host-runnable Lua suite and must never be deployed.
- `controller/colossal/deployment_manifest.lua` is the exact runtime deployment allow-list.
- `docs/operations.md` describes topology, setup, recovery, upgrades, and deployment safety.

## Live-server safety

- Treat every ComputerCraft directory as production with real players and items.
- The current live controller is computer `#4`, labeled `StorageController`, under `C:\Servers\Wold's Vaults\world\computercraft\computer\4`.
- Before every live write, confirm shutdown explicitly in the current conversation and re-read `colossal/data/config.lua` to verify both numeric ID and label.
- Never execute ComputerCraft startup programs, controller runtime, peripheral calls, or turtle actions from the host.
- Deploy only manifest-approved runtime paths relative to `controller/`; never copy tests, docs, Git metadata, plans, Markdown, or host helpers.
- Preserve `colossal/data/`, especially `config.lua`, `aliases.lua`, and any active journal, unless the user explicitly authorizes a fresh install.
- Compare repository and live SHA-256 hashes after deployment and check the live tree for development artifacts.
- Keep temporary host helpers outside this repository and remove them after use.

## Runtime invariants

- Keep exactly one coordinator work loop capable of scanning or advancing automation. Peripheral calls may yield, so concurrent work loops can duplicate transfers.
- Journal transfer intent before the inventory call. Never replay an uncertain or already-called transfer.
- For reconciliation, aggregate exact-identity storage deltas are authoritative. A `pushItems` return value is diagnostic and must not override measured storage truth.
- Retrieval verification depends on controlled Storage state, not mutable Pickup contents.
- The scanned inventory index is derived state and must never be persisted as authoritative stock truth.
- Item identity is namespaced item ID plus the CC:Tweaked NBT hash; never merge distinct NBT variants.
- `inventory.list()` does not provide item stack limits. Drop-off scans must obtain and validate `getItemDetail(slot).maxCount`; large Storage scans must not add per-item detail calls.
- A zero-movement or ambiguous operation must settle into an explicit blocked/recovery state instead of retrying from unrelated background scan generations.
- Keep input handling responsive: scans, transfers, rendering, and metadata enrichment must remain bounded cooperative work.

## Development and testing

- Make behavior changes in an isolated Git worktree and use test-first development.
- Keep modules focused and dependency-injected so inventory, UI, and failure paths can be tested without Minecraft.
- From `controller/`, run focused tests with `lua colossal/tests/run.lua tests.<module>`.
- Before committing or merging runtime changes, run the complete suite with `lua colossal/tests/run.lua` and run `git diff --check`.
- Test changes must cover conservation of items, one-call transfer behavior, restart recovery, responsive input, renderer bounds, and live failure reproductions when relevant.
- Host tests and repository development must not read from or write to live Minecraft inventories.

## Git and integration

- `main` is the local integration branch.
- Keep unrelated user changes intact and never use destructive reset or checkout commands to discard them.
- Merge only from a clean, fully tested branch; rerun the full suite on the merged `main` tree.
- Remove only worktrees created under this repository's `.worktrees/` directory, and only after their commits are merged and verified.
- No Git remote is currently configured. Re-check `git remote -v` before assuming push or pull behavior.
