# AGENTS.md

## Project

This repository contains a search-first CC:Tweaked wired-inventory storage terminal backed by one or more standard storage containers. Version 1 supports Drop-off imports, pooled NBT-aware indexing, exact retrieval requests, a controller UI, and a resizable public monitor.

Crafting is specified in `docs/superpowers/specs/2026-08-04-crafting-system-design.md` and all four stages are merged: the generated recipe pack, `core/recipe_repo.lua`, `core/craft_prefs.lua`, `core/craft_planner.lua`, `app/craft_service.lua`, `app/craft_buffer.lua`, `app/turtle_link.lua`, `app/craft_monitor.lua`, the Crafting page on key 6, and the turtle firmware under `turtle/`.

**It is deployed and working in game.** Crafting, Drop-off import and retrieval have all been exercised on the live server. Crafting stays off unless both `craft_buffer` and `turtle` are bound in config; without them the craft service is never constructed and every existing behavior is unchanged.

Getting there took seven defects that the host suite could not have found, every one of them the controller acting on something it had not verified. That history is the most useful thing in this file — see "Crafting invariants" below.

The deployed recipe pack is the **live modpack's**, sourced from the running game rather than from jars: 24,583 recipes across 22,391 outputs, 24 shards, 6.0 MB, against `computer_space_limit = 10000000`. Multi-step crafting, single crafts, imports and retrievals have all been exercised against it in game, including a chest, which this modpack routes through `quark:oak_chest` rather than the vanilla planks recipe.

Operators drive recovery from the terminal: retry and cancel on the Requests page, acknowledge on the Alerts page, a two-key confirmed release for a recovery that cannot prove what an interrupted transfer moved, and a global pause. `controller/startup.lua` supervises the runtime with a capped restart backoff.

## Repository layout

- `controller/startup.lua` is the deployable CraftOS entry point. It plays the boot splash
  (`storage/app/splash.lua`) once per real cold boot, then supervises `storage/main.lua`
  with a capped restart backoff; a splash failure is caught and logged, never blocking boot.
- `controller/storage/main.lua` assembles the application.
- `controller/storage/app/` contains services, coordination, setup, UI, monitor rendering,
  and the boot splash.
- The presentation layer is shared, not per-screen: `app/theme.lua` owns the palette and the
  semantic color roles, `app/draw.lua` the drawing primitives, `app/layout.lua` the screen
  regions, and `app/buffer.lua` the double buffering. **Screens name a role, never a color
  slot** (`Theme.role.focus`, never `colors.pink`), and no renderer keeps its own copy of a
  drawing helper -- `tests/test_ui_purity.lua` fails if one grows back.
- `controller/storage/core/` contains inventory scanning, indexing, planning, transfers, reconciliation, and registry logic.
- `controller/storage/shared/` contains runtime, codec, and durable-store helpers.
- `controller/storage/recipes/` holds the generated crafting recipe pack. It is deployed like code, never hand-edited; regenerate it with `tools/recipe_import.py` and see `docs/operations.md`. Hand-written recipes go in `storage/data/custom_recipes.lua` instead, which takes precedence over it.
- `turtle/` is the crafting turtle's own deployable tree, with its own `deployment_manifest.lua`. It is a second live computer: never deploy controller files to it, and never deploy its files to the controller. Both manifests define a module named `deployment_manifest`, so tests must load one of them by explicit path rather than by `require`, and must not prepend the turtle tree to `package.path`. `turtle/crafter/theme.lua` and `turtle/crafter/draw.lua` are deliberate trimmed copies of `app/theme.lua` and `app/draw.lua`, not shared modules -- the turtle tree cannot require anything under `controller/storage/`. `turtle/crafter/splash.lua` and `turtle/crafter/hud.lua` are the turtle's own boot animation and live status screen; `executor.lua` reports progress to them through an optional, dependency-injected `notify(event, data)` callback that every existing caller and test can ignore.
- `tools/` holds host-side build tooling that is never deployed. Its Python tests run with `python -m unittest test_recipe_pack test_recipe_import` from `tools/`. `tools/deploy.py` is the live deployment gate; `tools/recipe_import.py` generates the recipe pack.
- `tools/emulator/` boots the controller in the CraftOS-PC emulator and drives it headlessly; see `docs/emulator.md`. It installs from `deployment_manifest.lua`, so a module missing from the manifest fails to boot there rather than in Minecraft, and it runs the Lua 5.2 that CC:Tweaked runs rather than the host's 5.4. Nothing under `controller/` or `turtle/` may require any part of it. `smoke/world.lua` uses CraftOS-PC-only calls (`periphemu`, `setItem`) and patches `getItemDetail` to return the `displayName`/`maxCount`/`tags` that CC:Tweaked returns and the emulator does not; that patch exists to match Minecraft, and the controller must never depend on it.
- `controller/storage/tests/` contains the host-runnable Lua suite and must never be deployed.
- `controller/storage/deployment_manifest.lua` is the exact runtime deployment allow-list.
- `docs/operations.md` describes topology, setup, recovery, upgrades, and deployment safety.
- `docs/backlog.md` lists known gaps, untested paths and polish, ordered by risk.
- `docs/assets/wordmark.svg` is the project wordmark used in `README.md`.
- `CONTRIBUTING.md` is the developer-facing onboarding doc: workflow, test commands, code
  conventions, and a condensed pointer into this file's live-deployment safety rules.
- `docs/superpowers/specs/` holds design specs and `docs/superpowers/plans/` holds smaller work items. Pending: `specs/2026-08-04-crafting-system-design.md` (supersedes `specs/2026-08-03-crafting-turtle-design.md`), `plans/2026-08-03-batch-limit-tuning.md`. Built and merged: `specs/2026-08-12-ui-visual-system-design.md`, with its four plans under `plans/2026-08-12-ui-*.md`.

## Rendering

- **Every render must end the frame it begins.** `UI:render` and both monitors hide a buffered
  window, draw, and show it again. A path that returns early or throws without ending the frame
  leaves the window hidden: the application keeps running perfectly and the screen freezes on
  the last frame shown, which is indistinguishable from a hang. Each render therefore has a
  single entry and exit with the body under `pcall`.
- **Rendering must never mutate UI state.** Scroll offsets are computed from the selection at
  render time and discarded; `tests/test_ui_purity.lua` enforces it.
- **Never hardcode a row or column for one screen size.** Two monitor sections silently
  vanished on shorter monitors because their rows were written for a 79x24 wall display.
  Derive every position from the real width and height, and drop whole sections when they do
  not fit rather than letting them overlap. `tests/test_ui_sections.lua` asserts each screen
  still shows its sections at every size its tier claims to support.
- **Measure block glyphs before drawing them.** `Draw.blockText` paints six columns per
  character; a number drawn without checking runs off the edge and clips mid-glyph.
- **The wall monitor is output-only.** It renders a different layout from the terminal, so the
  terminal's hit regions would match the wrong coordinates there. Hit regions are the
  terminal's alone.

## Live-server safety

- Treat every ComputerCraft directory as production with real players and items.
- The server no longer runs on this machine. The world is mounted over sshfs as drive `G:`, so the computer tree is `G:\world\computercraft\computer` and the server root (`mods`, `libraries`, `kubejs`) is `G:\` itself. Every path is a network round trip: deployments and backups are slow, and a dropped mount looks like a missing directory rather than an error worth retrying through.
- The current live controller is computer `#4`, labeled `StorageController`, under `G:\world\computercraft\computer\4`. The crafting turtle is `#5`. A folder number is a filesystem id and has nothing to do with a peripheral name.
- Before every live write, confirm shutdown explicitly in the current conversation and re-read `storage/data/config.lua` to verify both numeric ID and label. A confirmation never carries forward to a later deployment. Do not infer quiescence from file mtimes; that reasoning was used once and was wrong even though the outcome was safe.
- Deploy with `tools/deploy.py`, which enforces the whole gate below in one command and refuses rather than guesses. `docs/operations.md` documents it. Do not hand-roll a deployment script in a scratch directory.
- `luac.exe` and Python are Windows binaries and cannot open Git Bash `/c/...` paths. `luac` reports "cannot open", which reads like a syntax error; a `/g/world/...` path handed to Windows Python silently creates `C:\g\world\...` rather than failing. Pass `G:/world/computercraft/computer` in Windows form.
- From WSL, `G:` does not auto-mount under `/mnt/g` the way local drives do, so WSL's own `python3` can never reach it regardless of path style. Invoke Windows Python by full path instead -- `/mnt/c/Users/Pellux/AppData/Local/Programs/Python/Launcher/py.exe` -- from a working directory under `/mnt/c/...` so its interop path translation resolves the script and `--repo` default correctly. See `docs/operations.md` for the full trap.
- Never execute ComputerCraft startup programs, controller runtime, peripheral calls, or turtle actions from the host.
- Deploy only manifest-approved runtime paths relative to `controller/`; never copy tests, docs, Git metadata, plans, Markdown, or host helpers. Gate every write on `deployment_manifest.lua` so an unlisted path is refused rather than copied.
- Preserve `storage/data/`, especially `config.lua`, `aliases.lua`, `metadata.lua`, and any active journal, unless the user explicitly authorizes a fresh install. Back the directory up to a host scratch path before deploying.
- The live tree uses LF; the repository working copy is CRLF under `core.autocrlf`. Write LF and compare LF-normalized SHA-256 hashes, otherwise every file appears to differ.
- **The sshfs mount does not truncate on `open("wb")`.** Writing a file that got shorter leaves the previous version's tail in place past the new end, so the module silently stops parsing. Observed 2026-08-12: a 138-line `draw.lua` landed as 150 lines, reproduced identically across two deployments. `tools/deploy.py` now unlinks before writing; any other tool that writes to the live tree must do the same. This is exactly why the gate verifies hashes and runs `luac -p` on what actually landed rather than trusting the write.
- After deployment verify all of: LF-normalized hashes for every manifest file, `luac -p` on every deployed file, no strays outside the manifest and `storage/data/`, and `storage/data/` unchanged against the backup.
- Confirm the controller is quiescent before writing by sampling the `storage/data/` directory mtime; an active controller rewrites its journal continuously.
- Measure live behavior only through read-only observation. Polling `storage/data/journal.lua` for phase transitions yields per-transfer timings without touching the controller.
- Keep temporary host helpers outside this repository and remove them after use.

## Runtime invariants

- Keep exactly one coordinator work loop capable of scanning or advancing automation. Peripheral calls may yield, so concurrent work loops can duplicate transfers.
- Journal transfer intent before the inventory call. Never replay an uncertain or already-called transfer.
- For reconciliation, aggregate exact-identity storage deltas are authoritative. A `pushItems` return value is diagnostic and must not override measured storage truth.
- Because reconciliation measures an aggregate delta per identity, one baseline can cover several pushes of that identity, and distinct identities are independent conserved quantities so one scan can serve a baseline for each. `Transfer:executeBatch` and `Transfer:executeMultiBatch` rely on this: preflight every source and destination before issuing anything, stop on an unknown call outcome and leave the journal at `CALLING`, and never replay the remaining steps. A negative delta for any identity blocks the whole batch rather than partially accepting it.
- Every source in a batch is planned against the **same** storage snapshot, so a slot one plan claims must be reserved before the next source is planned, via the planner's `owned_slots` hook. Otherwise two item types both select the first empty slot. Keep the `DESTINATION_COLLISION` check as well: it is what caught this on the first live mixed drop-off, before anything was issued.
- Journal schemas 1, 2, 3 and 4 must all keep validating, verifying and recovering. An upgrade must never orphan a journal that was in flight when the controller stopped.
- Batching is bounded by two limits with different jobs: `slot_batch_limit` caps how many Drop-off slots join one cycle, `batch_limit` caps the moves issued in it and therefore how much a single ambiguous window can span. Raise either only with a live measurement, and ship a behavior-preserving value first when the code path underneath is new.
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
- `inventory.list()` returns only occupied slots, so scan cost is proportional to occupied slots, not inventory size. A mostly empty container scans quickly regardless of its slot count.
- Every peripheral call yields for roughly one server tick, while pure Lua between yields is comparatively free. Optimise the number of peripheral calls and the number of work-loop ticks, not Lua loop bodies. Budget scan work by role: per-slot detail calls stay bounded, pure slot bookkeeping can absorb a bulk budget.
- Keep input handling responsive: scans, transfers, rendering, and metadata enrichment must remain bounded cooperative work.

## Crafting invariants

These were all found on the live server, after a green suite. Each one is now covered by a
test; the reasoning matters more than the test, because the same mistake has recurred in
several shapes.

- **A service must never gate itself on a rescan while it is in a state that forbids scanning.** `_scanStep` refuses to scan any node while a service reports `TRANSFERRING`. A verification gate raised from inside that state waits on a scan revision the same state prevents from advancing, so the service is never ticked again and its transfer never settles. `CraftBuffer:drain` reports its importer's state so the caller can tell the difference; the coordinator queues rather than gates a rescan asked for by a service that is itself transferring.
- **Having nothing left to move is not the same as being finished.** The buffer importer's last pass moves the items and only then goes to `VERIFYING`, so a rescan makes the buffer look empty while a transfer is still open. Reporting `DONE` there abandoned the importer mid-cycle: its journal was never retired — and that journal belongs to the `transfer` instance every service shares — while `status()` reported `VERIFYING` for good, which told the coordinator a transfer was permanently in flight and stopped every service from planning again. A drain is only done when there is nothing to move *and* no open journal.
- **No service may begin planning while another has a transfer in flight.** Two services planning and issuing moves at once share one journal while each measures aggregate storage deltas the other is changing, which surfaces as items credited to the wrong step. The craft drain runs its own `ImportService`, so `CraftService:status()` must report that inner state or the drain is invisible to the check.
- **That rule has no upper bound, so one wedged service silently stops the whole installation.** `_stallStep` raises `TRANSFER_STALLED` naming the service after 60 seconds in flight. It deliberately does not intervene — forcing a half-finished transfer from outside is how items get lost — it only stops the stall from looking like whichever feature the operator was using.
- **A rescan is the only thing that tells the controller the turtle produced anything.** Nothing else reports it. Without one, the drain sees the pre-craft snapshot, decides there is nothing to move, strands the output in the buffer, and delivery quietly pulls the same item out of storage instead.
- **`turtle.craft()` reads inventory slots 1-3, 5-7 and 9-11 as the 3x3 grid.** Slots 4, 8 and 12-16 sit outside it. Only grid positions 1-3 map to themselves, so passing a position straight through as a slot puts most of a recipe in the wrong place and anything landing in slot 4, 8 or 12+ is not in the grid at all.
- **`per_cell` is how many crafts *this call* performs, not the step's maximum batch.** Every vanilla grid cell consumes one item per craft. Sending the maximum told the turtle to stage 64 logs for a two-craft step.
- **A turtle slot holds one stack, so an ingredient cannot be gathered into one cell and spread from there.** `per_cell * #cells` routinely exceeds 64. Fill each cell directly, and verify every cell rather than only the first.
- **A craft quantity means "make N", not "bring stock up to N".** The "up to" behavior is the Search page's retrieval. The planner draws ingredients from storage but never the requested item itself.
- **`rednet.send` throws "No open sides" unless a modem is opened first,** and the controller has no other reason to use rednet. The turtle's reply arrives as an event on the work loop, so the link needs an inbox: polling `rednet.receive` loses a reply that lands between polls.
- **An output can have many recipes, and the first is not necessarily usable.** Vanilla nearly always had one, so committing to a single choice was invisible; the live pack gives `minecraft:stick` seven, and the two that sort first want a modded wood nobody stocks. Recipes are tried in rank order with ledger rollback, like tag candidates.
- **Both searches roll back and retry, so their costs multiply.** `minecraft:planks` has 412 members against vanilla's 8. Each decision tries a bounded number of alternatives with a whole-plan budget as backstop, and ranking includes one level of lookahead — is this candidate craftable from what is *actually in stock* — so the right option sorts first and the caps rarely bite. Planning runs inline on a keypress, so an unbounded search is not an option even though it does terminate.
- **suckDown takes the buffer's lowest occupied slot, so staging cannot assume the buffer's order matches the recipe's.** The buffer is filled by one withdrawal per ingredient and those land wherever there is room, with two withdrawals of one item able to end up either side of a third. The executor identifies each stack in a scratch slot and routes it to the cells that want it. Every recipe crafted before this had a single ingredient type, where any order is the right order, so a two-ingredient recipe was the first to put the wrong item in a cell -- single-ingredient tests cannot cover this.
- **A live pack is not a fixture.** The planner picked `acacia_planks` with only oak logs in stock; only running the real recipe pack found it. Tag candidates are now tried in order with ledger rollback.
- **Mod jars describe recipes that may not exist.** About 10% of modded crafting recipes carry `conditions`, and the common ones are config flags (`quark:flag`, `thermal:flag`, `mysticalagriculture:*`) that only resolve at runtime. A jar scan reports both halves of a mutually exclusive pair — Quark's `minecraft:chest` and `quark:dark_oak_chest` are gated on opposite states of one flag — and the controller then plans a craft that produces a different item and blocks on `OUTPUT_MISSING` after consuming real materials. For a modpack, source the recipe set from `tools/kubejs/invos_export.js`, which runs after conditions resolve. Jar scanning is a superset, correct only for vanilla.

## Development and testing

- Make behavior changes in an isolated Git worktree and use test-first development.
- Keep modules focused and dependency-injected so inventory, UI, and failure paths can be tested without Minecraft.
- From `controller/`, run focused tests with `lua storage/tests/run.lua tests.<module>`. Register any new test module in the `defaultModules` list in `storage/tests/run.lua`.
- Host Lua is 5.4; CC:Tweaked runs Lua 5.2. A green host suite does not prove CC compatibility, so avoid host-only syntax and treat version-sensitive semantics with suspicion. `python3 -m unittest test_smoke` from `tools/emulator/` boots the controller under the real Lua 5.2 and is the cheapest way to prove a change actually runs; it is not a substitute for the host suite, which covers far more. The full emulator suite (`python3 tools/emulator/run_tests.py all`) runs in about 70 seconds, so run it rather than agonising over which category to pick; `--list` shows them (`fast`, `smoke`, `setup-wizard`, `manifest`, `keys`, `nbt`, `emulator`, `all`) if you do want to narrow it. It used to take several minutes, and almost none of that was emulation: `settle()` waited for the screen to stop changing, which on a page with a marquee never happens, so it ran to its timeout every time -- 60s twice per capture and 8s per keypress. If the harness ever feels slow again, measure before assuming the emulator is the cost. The workdir is keyed to the checkout, so separate clones and worktrees no longer collide; two invocations from the *same* checkout still race, so give one a different `TMPDIR`. Run the slow categories in the foreground with a timeout rather than backgrounding them and waiting to be notified, and use `tools/emulator/craftos.py text`/`shot` when you only need to look at one screen. See `docs/emulator.md`.
- Verify UI changes against a rendered frame, not only against tests: `python3 tools/emulator/craftos.py shot --out /tmp/screen.png` draws the terminal from the emulator's own framebuffer and palette. Layout regressions that every unit test passes are visible there.
- Before committing or merging runtime changes, run the complete suite with `lua storage/tests/run.lua` and run `git diff --check`. Check the interpreter's exit code; piping the run through `grep` masks a failing suite.
- Size any performance work against the live installation before optimizing. A benchmark built on assumed scale, or on fakes where peripheral calls return instantly, will point at the wrong bottleneck.
- A gate cycle costs roughly the same whether it carries one item or hundreds, so throughput work belongs in reducing the number of cycles, not the cost of each. Compare time per unit of work moved, never seconds per cycle: a change that amortises fixed overhead correctly makes each cycle slower.
- When a design argues that some bad state cannot arise, still assert it. The claim that batched plans could never target the same slot was wrong, and the guard written against it turned a silent double-fill into a clean named failure before anything was issued.
- A test double that is more permissive than the real thing hides integration bugs. `recipe_repo`'s injected loader matched `^pack_(%d+)$`, so it accepted the unpadded `pack_1` the module asked for while the converter emits `pack_01.lua`. Every unit test passed and all 639 outputs were silently uncraftable. Pin the exact contract in the test, and keep a check that exercises the real artifact.
- When several independent changes are parallelised across agents, assign strict per-file ownership so the branches merge cleanly, and review returned work against the code rather than trusting the report.
- Test changes must cover conservation of items, one-call transfer behavior, restart recovery, responsive input, renderer bounds, and live failure reproductions when relevant.
- Host tests and repository development must not read from or write to live Minecraft inventories.

## Git and integration

- `main` is the local integration branch.
- Keep unrelated user changes intact and never use destructive reset or checkout commands to discard them.
- Merge only from a clean, fully tested branch; rerun the full host Lua suite (`lua storage/tests/run.lua`, cheap) on the merged `main` tree, plus `python3 tools/emulator/run_tests.py all`, which is now cheap enough (~70s) to run on every merge rather than choosing categories by hand.
- Remove only worktrees created under this repository's `.worktrees/` directory, and only after their commits are merged and verified.
- No Git remote is currently configured. Re-check `git remote -v` before assuming push or pull behavior.
- **Claude Code's `EnterWorktree` tool locks the calling session into that worktree for the rest of its life.** Once called, the harness sandboxes every subsequent git operation in that session -- even read-only ones like `git -C <other-path> rev-parse` -- to stay inside the worktree; a plain `cd` back to the repo root does not work. The only way out is that same session calling `ExitWorktree`. This has already bitten two separate sessions: a background job that entered a worktree to do feature work could not itself merge or clean up afterward, and a second session that entered the *same* worktree just to help fix a conflict got locked in exactly the same way -- entering to help propagates the lock, it does not lend a way out. If a session will need to merge or clean up its own work later, skip `EnterWorktree` and work on a plain branch in the shared checkout instead; if directory-level isolation is genuinely needed, call `ExitWorktree` before touching `main` rather than having a second session enter the same worktree.
