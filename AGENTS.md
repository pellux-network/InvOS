# AGENTS.md

## Project

This repository contains a search-first CC:Tweaked wired-inventory storage terminal backed by one or more Colossal Chests. Version 1 supports Drop-off imports, pooled NBT-aware indexing, exact retrieval requests, a controller UI, and a resizable public monitor. Crafting remains future work.

Operators drive recovery from the terminal: retry and cancel on the Requests page, acknowledge on the Alerts page, a two-key confirmed release for a recovery that cannot prove what an interrupted transfer moved, and a global pause. `controller/startup.lua` supervises the runtime with a capped restart backoff.

## Repository layout

- `controller/startup.lua` is the deployable CraftOS entry point.
- `controller/colossal/main.lua` assembles the application.
- `controller/colossal/app/` contains services, coordination, setup, UI, and monitor rendering.
- `controller/colossal/core/` contains inventory scanning, indexing, planning, transfers, reconciliation, and registry logic.
- `controller/colossal/shared/` contains runtime, codec, and durable-store helpers.
- `controller/colossal/tests/` contains the host-runnable Lua suite and must never be deployed.
- `controller/colossal/deployment_manifest.lua` is the exact runtime deployment allow-list.
- `docs/operations.md` describes topology, setup, recovery, upgrades, and deployment safety.
- `docs/superpowers/specs/` holds design specs; `2026-08-03-multi-identity-batching-design.md` is specified and not yet implemented.

## Live-server safety

- Treat every ComputerCraft directory as production with real players and items.
- The current live controller is computer `#4`, labeled `StorageController`, under `C:\Servers\Wold's Vaults\world\computercraft\computer\4`.
- Before every live write, confirm shutdown explicitly in the current conversation and re-read `colossal/data/config.lua` to verify both numeric ID and label. A confirmation never carries forward to a later deployment.
- Never execute ComputerCraft startup programs, controller runtime, peripheral calls, or turtle actions from the host.
- Deploy only manifest-approved runtime paths relative to `controller/`; never copy tests, docs, Git metadata, plans, Markdown, or host helpers. Gate every write on `deployment_manifest.lua` so an unlisted path is refused rather than copied.
- Preserve `colossal/data/`, especially `config.lua`, `aliases.lua`, `metadata.lua`, and any active journal, unless the user explicitly authorizes a fresh install. Back the directory up to a host scratch path before deploying.
- The live tree uses LF; the repository working copy is CRLF under `core.autocrlf`. Write LF and compare LF-normalized SHA-256 hashes, otherwise every file appears to differ.
- After deployment verify all of: LF-normalized hashes for every manifest file, `luac -p` on every deployed file, no strays outside the manifest and `colossal/data/`, and `colossal/data/` unchanged against the backup.
- Confirm the controller is quiescent before writing by sampling the `colossal/data/` directory mtime; an active controller rewrites its journal continuously.
- Measure live behaviour only through read-only observation. Polling `colossal/data/journal.lua` for phase transitions yields per-transfer timings without touching the controller.
- Keep temporary host helpers outside this repository and remove them after use.

## Runtime invariants

- Keep exactly one coordinator work loop capable of scanning or advancing automation. Peripheral calls may yield, so concurrent work loops can duplicate transfers.
- Journal transfer intent before the inventory call. Never replay an uncertain or already-called transfer.
- For reconciliation, aggregate exact-identity storage deltas are authoritative. A `pushItems` return value is diagnostic and must not override measured storage truth.
- Because reconciliation measures an aggregate delta per identity, one baseline can cover several pushes of that identity. `Transfer:executeBatch` relies on this: preflight every source and destination before issuing anything, stop on an unknown call outcome and leave the journal at `CALLING`, and never replay the remaining steps. Distinct item identities are independent conserved quantities, which is what would make multi-identity batching sound.
- Journal schemas 1, 2 and 3 must all keep validating, verifying and recovering. An upgrade must never orphan a journal that was in flight when the controller stopped.
- A zero-movement result (`SHORT_TRANSFER`, `PICKUP_FULL`) waits for explicit operator retry by design and must not resume from background scan generations. `generation` increments on every completed node scan, so it is not evidence that the relevant inventory changed.
- A change observed before any inventory call is not ambiguous, because nothing was issued. Abandon the stale attempt and rediscover rather than entering a terminal state.
- Learned item metadata is a re-learnable cache. Persist display names and stack limits only; never persist quantities, slots, or node contents, and always boot successfully when the cache is missing or invalid.
- Retrieval verification depends on controlled Storage state, not mutable Pickup contents.
- The scanned inventory index is derived state and must never be persisted as authoritative stock truth.
- Item identity is namespaced item ID plus the CC:Tweaked NBT hash; never merge distinct NBT variants.
- `inventory.list()` does not provide item stack limits. Drop-off scans must obtain and validate `getItemDetail(slot).maxCount` for the slot the importer will consume, which is the lowest occupied slot; detailing any other slot buys nothing. Large Storage scans must not add per-item detail calls.
- `inventory.list()` returns only occupied slots, so scan cost is proportional to occupied slots, not inventory size. A mostly empty Colossal Chest scans quickly regardless of its slot count.
- Every peripheral call yields for roughly one server tick, while pure Lua between yields is comparatively free. Optimise the number of peripheral calls and the number of work-loop ticks, not Lua loop bodies. Budget scan work by role: per-slot detail calls stay bounded, pure slot bookkeeping can absorb a bulk budget.
- A zero-movement or ambiguous operation must settle into an explicit blocked/recovery state instead of retrying from unrelated background scan generations.
- Keep input handling responsive: scans, transfers, rendering, and metadata enrichment must remain bounded cooperative work.

## Development and testing

- Make behavior changes in an isolated Git worktree and use test-first development.
- Keep modules focused and dependency-injected so inventory, UI, and failure paths can be tested without Minecraft.
- From `controller/`, run focused tests with `lua colossal/tests/run.lua tests.<module>`. Register any new test module in the `defaultModules` list in `colossal/tests/run.lua`.
- Host Lua is 5.4; CC:Tweaked runs Lua 5.2. A green host suite does not prove CC compatibility, so avoid host-only syntax and treat version-sensitive semantics with suspicion.
- Before committing or merging runtime changes, run the complete suite with `lua colossal/tests/run.lua` and run `git diff --check`. Check the interpreter's exit code; piping the run through `grep` masks a failing suite.
- Size any performance work against the live installation before optimising. A benchmark built on assumed scale, or on fakes where peripheral calls return instantly, will point at the wrong bottleneck.
- When several independent changes are parallelised across agents, assign strict per-file ownership so the branches merge cleanly, and review returned work against the code rather than trusting the report.
- Test changes must cover conservation of items, one-call transfer behavior, restart recovery, responsive input, renderer bounds, and live failure reproductions when relevant.
- Host tests and repository development must not read from or write to live Minecraft inventories.

## Git and integration

- `main` is the local integration branch.
- Keep unrelated user changes intact and never use destructive reset or checkout commands to discard them.
- Merge only from a clean, fully tested branch; rerun the full suite on the merged `main` tree.
- Remove only worktrees created under this repository's `.worktrees/` directory, and only after their commits are merged and verified.
- No Git remote is currently configured. Re-check `git remote -v` before assuming push or pull behavior.
