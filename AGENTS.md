# AGENTS.md

## Project

This repository contains a search-first CC:Tweaked wired-inventory storage terminal backed by one or more Colossal Chests. Version 1 supports Drop-off imports, pooled NBT-aware indexing, exact retrieval requests, a controller UI, and a resizable public monitor.

Crafting is specified in `docs/superpowers/specs/2026-08-04-crafting-system-design.md` and being built in four stages. Stages 1 to 3 are merged: the recipe pack, `core/recipe_repo.lua`, `core/craft_prefs.lua`, `core/craft_planner.lua`, `app/craft_service.lua`, `app/craft_buffer.lua`, `app/turtle_link.lua`, and the turtle firmware under `turtle/`.

Crafting is wired into `main.lua` but stays off unless both `craft_buffer` and `turtle` are bound in config; without them the craft service is never constructed and every existing behaviour is unchanged. Stage 4 adds the Crafting page and the crafting monitor, so nothing is reachable from the terminal yet.

Operators drive recovery from the terminal: retry and cancel on the Requests page, acknowledge on the Alerts page, a two-key confirmed release for a recovery that cannot prove what an interrupted transfer moved, and a global pause. `controller/startup.lua` supervises the runtime with a capped restart backoff.

## Repository layout

- `controller/startup.lua` is the deployable CraftOS entry point.
- `controller/colossal/main.lua` assembles the application.
- `controller/colossal/app/` contains services, coordination, setup, UI, and monitor rendering.
- `controller/colossal/core/` contains inventory scanning, indexing, planning, transfers, reconciliation, and registry logic.
- `controller/colossal/shared/` contains runtime, codec, and durable-store helpers.
- `controller/colossal/recipes/` holds the generated crafting recipe pack. It is deployed like code, never hand-edited; regenerate it with `tools/recipe_import.py` and see `docs/operations.md`. Hand-written recipes go in `colossal/data/custom_recipes.lua` instead, which takes precedence over it.
- `turtle/` is the crafting turtle's own deployable tree, with its own `deployment_manifest.lua`. It is a second live computer: never deploy controller files to it, and never deploy its files to the controller. Both manifests define a module named `deployment_manifest`, so tests must load one of them by explicit path rather than by `require`, and must not prepend the turtle tree to `package.path`.
- `tools/` holds host-side build tooling that is never deployed. Its Python tests run with `python -m unittest test_recipe_pack` from `tools/`.
- `controller/colossal/tests/` contains the host-runnable Lua suite and must never be deployed.
- `controller/colossal/deployment_manifest.lua` is the exact runtime deployment allow-list.
- `docs/operations.md` describes topology, setup, recovery, upgrades, and deployment safety.
- `docs/superpowers/specs/` holds design specs and `docs/superpowers/plans/` holds smaller work items. Pending: `specs/2026-08-04-crafting-system-design.md` (supersedes `specs/2026-08-03-crafting-turtle-design.md`), `plans/2026-08-03-batch-limit-tuning.md`.

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
- Because reconciliation measures an aggregate delta per identity, one baseline can cover several pushes of that identity, and distinct identities are independent conserved quantities so one scan can serve a baseline for each. `Transfer:executeBatch` and `Transfer:executeMultiBatch` rely on this: preflight every source and destination before issuing anything, stop on an unknown call outcome and leave the journal at `CALLING`, and never replay the remaining steps. A negative delta for any identity blocks the whole batch rather than partially accepting it.
- Every source in a batch is planned against the **same** storage snapshot, so a slot one plan claims must be reserved before the next source is planned, via the planner's `owned_slots` hook. Otherwise two item types both select the first empty slot. Keep the `DESTINATION_COLLISION` check as well: it is what caught this on the first live mixed drop-off, before anything was issued.
- Journal schemas 1, 2, 3 and 4 must all keep validating, verifying and recovering. An upgrade must never orphan a journal that was in flight when the controller stopped.
- Batching is bounded by two limits with different jobs: `slot_batch_limit` caps how many Drop-off slots join one cycle, `batch_limit` caps the moves issued in it and therefore how much a single ambiguous window can span. Raise either only with a live measurement, and ship a behaviour-preserving value first when the code path underneath is new.
- A zero-movement or ambiguous operation must settle into an explicit blocked or recovery state rather than retrying from unrelated background scan generations. `SHORT_TRANSFER` and `PICKUP_FULL` therefore wait for explicit operator retry: `generation` increments on every completed node scan, so it is never evidence that the relevant inventory changed.
- A node is only ever scanned for a reason: requested (`requestRescan`, from peripheral events and the planning/verification gates), never scanned (no snapshot, including a node just knocked offline), or stale past `scanRefreshInterval`. An idle coordinator with fresh snapshots does no scan work. `_initialIndexComplete` and every gate depend on this staying request-driven; do not reintroduce an unconditional queue refill, or every node is rescanned forever regardless of freshness again.
- Nothing tells the coordinator when an item physically lands in Drop-off; the only way it finds out is a rescan. So `scanRefreshInterval` is not just a CPU/traffic dial, it is the upper bound on how long a fresh deposit sits unnoticed before an import even starts. Raising it trades that responsiveness for fewer background scans; a verification-gate's own forced rescan is unaffected by it either way, since that always discards and restarts regardless of freshness.
- A change observed before any inventory call is not ambiguous, because nothing was issued. Abandon the stale attempt and rediscover rather than entering a terminal state.
- A blocked batch replans the very same sources; it never rediscovers. So an item type that currently cannot be placed must be set aside with a backoff *and* its attempt abandoned, or a few unplaceable stacks low in the Drop-off hide every importable slot behind them.
- Redraws happen only when something user-visible changed, so every such change must mark the coordinator dirty: scan completion, lifecycle transition, automation tick, recorded error, and command handling. A missed mark shows as a stale screen rather than an error, so verify against a live retrieval, not only tests.
- Learned item metadata is a re-learnable cache. Persist display names, stack limits, and per-identity request counts and last-requested timestamps only; never persist quantities, slots, or node contents, and always boot successfully when the cache is missing or invalid. Usage stats are only ever added to an identity that already has a display name and stack limit, so a cached entry always has both or neither.
- Retrieval verification depends on controlled Storage state, not mutable Pickup contents.
- The scanned inventory index is derived state and must never be persisted as authoritative stock truth.
- Item identity is namespaced item ID plus the CC:Tweaked NBT hash; never merge distinct NBT variants.
- `inventory.list()` does not provide item stack limits. Drop-off scans must obtain and validate `getItemDetail(slot).maxCount` for the slot the importer will consume, which is the lowest occupied slot; detailing any other slot buys nothing. Large Storage scans must not add per-item detail calls.
- `inventory.list()` returns only occupied slots, so scan cost is proportional to occupied slots, not inventory size. A mostly empty Colossal Chest scans quickly regardless of its slot count.
- Every peripheral call yields for roughly one server tick, while pure Lua between yields is comparatively free. Optimise the number of peripheral calls and the number of work-loop ticks, not Lua loop bodies. Budget scan work by role: per-slot detail calls stay bounded, pure slot bookkeeping can absorb a bulk budget.
- Keep input handling responsive: scans, transfers, rendering, and metadata enrichment must remain bounded cooperative work.

## Development and testing

- Make behavior changes in an isolated Git worktree and use test-first development.
- Keep modules focused and dependency-injected so inventory, UI, and failure paths can be tested without Minecraft.
- From `controller/`, run focused tests with `lua colossal/tests/run.lua tests.<module>`. Register any new test module in the `defaultModules` list in `colossal/tests/run.lua`.
- Host Lua is 5.4; CC:Tweaked runs Lua 5.2. A green host suite does not prove CC compatibility, so avoid host-only syntax and treat version-sensitive semantics with suspicion.
- Before committing or merging runtime changes, run the complete suite with `lua colossal/tests/run.lua` and run `git diff --check`. Check the interpreter's exit code; piping the run through `grep` masks a failing suite.
- Size any performance work against the live installation before optimising. A benchmark built on assumed scale, or on fakes where peripheral calls return instantly, will point at the wrong bottleneck.
- A gate cycle costs roughly the same whether it carries one item or hundreds, so throughput work belongs in reducing the number of cycles, not the cost of each. Compare time per unit of work moved, never seconds per cycle: a change that amortises fixed overhead correctly makes each cycle slower.
- When a design argues that some bad state cannot arise, still assert it. The claim that batched plans could never target the same slot was wrong, and the guard written against it turned a silent double-fill into a clean named failure before anything was issued.
- A test double that is more permissive than the real thing hides integration bugs. `recipe_repo`'s injected loader matched `^pack_(%d+)$`, so it accepted the unpadded `pack_1` the module asked for while the converter emits `pack_01.lua`. Every unit test passed and all 639 outputs were silently uncraftable. Pin the exact contract in the test, and keep a check that exercises the real artifact.
- When several independent changes are parallelised across agents, assign strict per-file ownership so the branches merge cleanly, and review returned work against the code rather than trusting the report.
- Test changes must cover conservation of items, one-call transfer behavior, restart recovery, responsive input, renderer bounds, and live failure reproductions when relevant.
- Host tests and repository development must not read from or write to live Minecraft inventories.

## Git and integration

- `main` is the local integration branch.
- Keep unrelated user changes intact and never use destructive reset or checkout commands to discard them.
- Merge only from a clean, fully tested branch; rerun the full suite on the merged `main` tree.
- Remove only worktrees created under this repository's `.worktrees/` directory, and only after their commits are merged and verified.
- No Git remote is currently configured. Re-check `git remote -v` before assuming push or pull behavior.
