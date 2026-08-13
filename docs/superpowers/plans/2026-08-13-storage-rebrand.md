# Storage Rebrand Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every "Colossal Chest" / "Colossal Storage" naming reference from the repository — rename the `controller/colossal/` module tree to `controller/storage/`, generalize test fixtures, UI copy, and living docs to describe standard containers, and rename the on-disk backup key — with no change to actual storage behavior.

**Architecture:** This is a naming/branding pass, not a behavior change. The storage logic already validates every node through the generic CC:Tweaked `peripheral.hasType(name, "inventory")` interface and already pools multiple labeled nodes into one store, confirmed in Task 1. Every later task is a mechanical rename: a directory move, literal string replacements in source/test/doc files, and one deliberate no-fallback rename of an on-disk backup key. Each task's validation step is running the existing test suite to confirm it stays green, not writing new failing tests — there is no new behavior to drive out with TDD here.

**Tech Stack:** Lua 5.4 (host tests) / Lua 5.2 (CC:Tweaked runtime), Python 3 (`tools/`).

**Spec:** `docs/superpowers/specs/2026-08-13-storage-rebrand-design.md`

## Global Constraints

- No behavior change to peripheral validation, scanning, pooling, or transfer logic — only naming, paths, and one on-disk key change.
- No live server redeploy. Everything in this plan is repo-only.
- Real in-game IDs in `controller/storage/recipes/` (formerly `controller/colossal/recipes/`) are never edited — they come from the live modpack and must keep matching it.
- Dated historical documents under `docs/superpowers/specs/` and `docs/superpowers/plans/` (e.g. `2026-08-02-colossal-storage-v1-design.md`) are never edited — they record decisions made at the time.
- The backup key `"colossal-backup"` renames outright to `"invos-backup"` with **no** backward-compatibility fallback — confirmed with the user; any backup floppy written under the old key will no longer be found by `recover()`.
- Before every commit in this plan: run the full Lua suite (`lua storage/tests/run.lua` from `controller/`, or `lua colossal/tests/run.lua` for the one task that runs before the rename) and confirm it is green. Check the interpreter's exit code directly.
- Run commands from the repository root unless a step says otherwise; `cd` into `controller/` or `tools/` as shown.

---

### Task 1: Pre-flight audit — confirm no code path special-cases a container type

**Files:** None modified. Read-only verification.

**Interfaces:**
- Produces: a go/no-go confirmation that Task 2 onward is a pure rename. If this audit finds a real type-gated dependency, stop and report it — it becomes a bug-fix task inserted before the rename, not a mechanical change.

- [ ] **Step 1: Confirm node validation is generic**

Read `controller/colossal/app/setup.lua` around line 216 and line 242. Confirm both calls are:

```lua
local typeOk, isInventory = pcall(self.peripheral.hasType, name, "inventory")
...
local ok, matches = pcall(self.peripheral.hasType, name, kind)
```

Neither call passes a Colossal-specific type string (e.g. `"colossalchests:colossal_chest"`). `kind` is a caller-supplied role type (`"inventory"`, `"turtle"`, `"monitor"`, etc.), never a peripheral brand.

- [ ] **Step 2: Confirm pooling logic is peripheral-agnostic**

Grep for `colossal` (case-insensitive) inside `controller/colossal/core/registry.lua`, `controller/colossal/core/scanner.lua`, and `controller/colossal/core/reconciliation.lua`:

```bash
grep -ri colossal controller/colossal/core/registry.lua controller/colossal/core/scanner.lua controller/colossal/core/reconciliation.lua
```

Expected: no matches. These modules key every operation off `node.id` / `node.peripheral_name`, never a peripheral type check.

- [ ] **Step 3: Confirm `turtle_link.lua`'s `getType` use is unrelated to storage**

Read `controller/colossal/app/turtle_link.lua` around line 37 (`pcall(self.peripheral.getType, side)`). Confirm this call identifies the turtle/modem link peripheral for `rednet`, not a storage node — out of scope for this rebrand.

- [ ] **Step 4: Record the confirmation**

No file changes. If all three checks pass (they are expected to, based on the initial investigation in the spec), proceed to Task 2. If any check fails, stop and report the specific dependency found before continuing.

---

### Task 2: Rename `controller/colossal/` to `controller/storage/` and fix all path plumbing

**Files:**
- Rename: `controller/colossal/` → `controller/storage/` (whole tree: `app/`, `core/`, `shared/`, `recipes/`, `tests/`, `data/` if present, `main.lua`, `deployment_manifest.lua`)
- Modify: `controller/startup.lua`
- Modify: `controller/storage/tests/run.lua`
- Modify: `controller/storage/main.lua`
- Modify: `controller/storage/deployment_manifest.lua`
- Modify: `controller/storage/core/recipe_repo.lua`
- Modify: `controller/storage/tests/test_deployment.lua`
- Modify: `controller/storage/tests/test_ui_purity.lua`
- Modify: `controller/storage/tests/test_startup.lua`
- Modify: `controller/storage/tests/test_theme.lua`
- Modify: `controller/storage/tests/test_craft_buffer.lua`
- Modify: `controller/storage/tests/test_setup_validation.lua`
- Modify: `controller/storage/tests/test_transfer.lua`
- Modify: `controller/storage/tests/test_store_failures.lua`
- Modify: `controller/storage/tests/test_store.lua`
- Modify: `controller/storage/tests/test_setup_recovery.lua` (path only — the `colossal-backup` key on line 45 is Task 3)
- Modify: `controller/storage/tests/test_setup_duplicates.lua`
- Modify: `controller/storage/tests/test_setup.lua`
- Modify: `controller/storage/tests/test_backup.lua` (path only — the `colossal-backup` keys are Task 3)
- Modify: `controller/storage/tests/test_setup_crafting.lua` (path only, line 48 — peripheral names on lines 23/59 are Task 5)
- Modify: `.gitignore`

**Interfaces:**
- Consumes: Task 1's confirmation that this is safe as a pure rename.
- Produces: `controller/storage/` as the module root every later task edits. All internal `require("app.x")` / `require("core.x")` calls are unaffected by the rename (they're relative to `package.path`, not the `colossal`/`storage` prefix), so no per-module `require` edits are needed — only `package.path` strings, the manifest, and literal test-fixture path strings.

- [ ] **Step 1: Move the directory**

```bash
cd "C:\Users\Pellux\Coding\InvOS"
git mv controller/colossal controller/storage
git status
```

Expected: `git status` shows every file under the new path as a rename (`renamed:` prefix), not a delete+add pair.

- [ ] **Step 2: Fix `controller/startup.lua`**

Change:
```lua
package.path = "/colossal/?.lua;/colossal/?/init.lua;" .. package.path
```
to:
```lua
package.path = "/storage/?.lua;/storage/?/init.lua;" .. package.path
```

Change:
```lua
local path = "/colossal/main.lua"
```
to:
```lua
local path = "/storage/main.lua"
```

- [ ] **Step 3: Fix `controller/storage/tests/run.lua`**

Change:
```lua
package.path = "colossal/?.lua;colossal/?/init.lua;" .. package.path
```
to:
```lua
package.path = "storage/?.lua;storage/?/init.lua;" .. package.path
```

- [ ] **Step 4: Fix `controller/storage/main.lua`**

Change:
```lua
local root=env.data_root or "/colossal/data"
```
to:
```lua
local root=env.data_root or "/storage/data"
```

- [ ] **Step 5: Fix `controller/storage/deployment_manifest.lua`**

Every listed path and the one comment referencing `colossal/data/` use the `colossal/` prefix. Use the Edit tool with `replace_all: true` on this file: old string `colossal/`, new string `storage/`. This covers all ~46 listed file paths and the comment.

- [ ] **Step 6: Fix `controller/storage/core/recipe_repo.lua`**

Two comments reference the old path. Use `replace_all: true`: old string `colossal/`, new string `storage/` (covers `colossal/recipes/` on line 4 and `colossal/data/` on line 132).

- [ ] **Step 7: Fix `controller/storage/tests/test_deployment.lua`**

This file's every `colossal` reference is a path string or the `^colossal/` match pattern (verified — no prose). Use `replace_all: true`: old string `colossal/`, new string `storage/`. This covers the regex pattern, every `seen[...]` key, and every path in the `for _, path in ipairs({...})` literals.

- [ ] **Step 8: Fix `controller/storage/tests/test_ui_purity.lua`**

Use `replace_all: true`: old string `colossal/`, new string `storage/`. Covers:
```lua
local file = io.open("colossal/app/" .. module .. ".lua")
T.equal(file ~= nil, true, "run the suite from controller/, not colossal/")
```

- [ ] **Step 9: Fix `controller/storage/tests/test_startup.lua`**

Use `replace_all: true`: old string `/colossal/main.lua`, new string `/storage/main.lua`. This covers all four occurrences (line 55 and the three inside the array literal on line 62).

Then a second edit, old string `the colossal application`, new string `the storage application` (test name on line 53).

- [ ] **Step 10: Fix `controller/storage/tests/test_theme.lua`**

Use `replace_all: true`: old string `colossal/`, new string `storage/`. Covers:
```lua
T.equal(startup ~= nil, true, "run the suite from controller/, not colossal/")
local main = io.open("colossal/main.lua")
```

- [ ] **Step 11: Fix `controller/storage/tests/test_craft_buffer.lua`**

Edit 1 — old string `path:find("colossal", 1, true)`, new string `path:find("storage", 1, true)` (line 262; no trailing slash, must be handled separately from the path-prefix edits).

Edit 2 — `replace_all: true`: old string `colossal/`, new string `storage/`. Covers the three path-prefix occurrences on lines 270–271 (`colossal/main.lua`, `colossal/core/craft_planner.lua`, `crafter/../colossal/main.lua`).

- [ ] **Step 12: Fix the remaining `colossal/data` fixture-path files**

Each of these files uses `"colossal/data"` only as a fake store-root argument to `Store.new(...)`. In each, use `replace_all: true`: old string `colossal/data`, new string `storage/data`.

- `controller/storage/tests/test_setup_validation.lua` (line 15)
- `controller/storage/tests/test_transfer.lua` (line 30)
- `controller/storage/tests/test_store_failures.lua` (lines 20, 31)
- `controller/storage/tests/test_store.lua` (13 occurrences, lines 46–111)
- `controller/storage/tests/test_setup_recovery.lua` (line 10 only — do not touch line 45's `colossal-backup`, that's Task 3)
- `controller/storage/tests/test_setup_duplicates.lua` (line 17)
- `controller/storage/tests/test_setup.lua` (line 32)
- `controller/storage/tests/test_backup.lua` (lines 24, 40, 61 only — do not touch the `colossal-backup` keys, that's Task 3)
- `controller/storage/tests/test_setup_crafting.lua` (line 48 only — do not touch the `colossalchests:colossal_chest_0` peripheral names on lines 23/59, that's Task 5)

- [ ] **Step 13: Fix `.gitignore`**

Change:
```
controller/colossal/data/
```
to:
```
controller/storage/data/
```

- [ ] **Step 14: Run the full suite**

```bash
cd "C:\Users\Pellux\Coding\InvOS\controller"
lua storage/tests/run.lua
echo "exit: $?"
```

Expected: all tests pass, exit code 0. If anything fails, it is almost certainly a missed `colossal/` string in a file this task should have caught — grep for it:

```bash
grep -ril colossal storage/
```

- [ ] **Step 15: `git diff --check` and commit**

```bash
cd "C:\Users\Pellux\Coding\InvOS"
git diff --check
git add controller/ .gitignore
git commit -m "chore: rename controller/colossal to controller/storage"
```

---

### Task 3: Rename the backup floppy key from `colossal-backup` to `invos-backup`

**Files:**
- Modify: `controller/storage/app/backup.lua`
- Modify: `controller/storage/tests/test_backup.lua`
- Modify: `controller/storage/tests/test_setup_recovery.lua`

**Interfaces:**
- Consumes: `Store:write(name, value, validator)` / `Store:recover(name, validator)` from `controller/storage/shared/store.lua` (unchanged — `name` is just the key/filename argument).
- Produces: the backup floppy is now written and read under the key `"invos-backup"`. No fallback to the old key — confirmed with the user as an outright rename.

- [ ] **Step 1: Rename the key in `app/backup.lua`**

Use `replace_all: true`: old string `colossal-backup`, new string `invos-backup`. Covers both:
```lua
function M.export(store, mount, config, aliases)
    local payload = { schema = 1, config = config, aliases = aliases }
    return store:at(mount):write("colossal-backup", payload, M.validate)
end

function M.import(store, mount)
    return store:at(mount):recover("colossal-backup", M.validate)
end
```

- [ ] **Step 2: Update `controller/storage/tests/test_backup.lua`**

Use `replace_all: true`: old string `colossal-backup`, new string `invos-backup`. Covers the `recover(...)` call (line 28), the `write(...)` call (line 41), and the assertion `T.contains(reason, "no valid colossal-backup")` (line 64) — the message text is generated dynamically from the key name in `Store:recover`, so this assertion must track the new key.

- [ ] **Step 3: Update `controller/storage/tests/test_setup_recovery.lua`**

Old string: `T.contains(reason,"no valid colossal-backup")`
New string: `T.contains(reason,"no valid invos-backup")`

- [ ] **Step 4: Run the full suite**

```bash
cd "C:\Users\Pellux\Coding\InvOS\controller"
lua storage/tests/run.lua
echo "exit: $?"
```

Expected: all tests pass, exit code 0.

- [ ] **Step 5: Commit**

```bash
cd "C:\Users\Pellux\Coding\InvOS"
git add controller/storage/app/backup.lua controller/storage/tests/test_backup.lua controller/storage/tests/test_setup_recovery.lua
git commit -m "chore: rename backup floppy key from colossal-backup to invos-backup"
```

---

### Task 4: Fix `tools/deploy.py` and `tools/recipe_import.py` path references

**Files:**
- Modify: `tools/deploy.py`
- Modify: `tools/recipe_import.py`

**Interfaces:**
- Consumes: the renamed `controller/storage/deployment_manifest.lua` from Task 2 — `deploy.py`'s manifest path argument must point at the new location.
- Produces: no change to `deploy.py`'s or `recipe_import.py`'s behavior; only the hardcoded path strings move.

- [ ] **Step 1: Fix `tools/deploy.py` — path-with-slash references**

Use `replace_all: true`: old string `colossal/`, new string `storage/`. Covers:
- Line 20: `...never anything under colossal/data.` (docstring)
- Line 23: `8. colossal/data survived byte-for-byte.` (docstring)
- Line 41: `PRESERVED = ("colossal/data",)`
- Line 244: `Only manifest files: colossal/data holds serialized tables...` (docstring)
- Line 265: `"""colossal/data must survive byte-for-byte."""`
- Line 332: `repo / "controller/colossal/deployment_manifest.lua"`

- [ ] **Step 2: Fix `tools/deploy.py` — bare pathlib segments**

Use `replace_all: true`: old string `"colossal"`, new string `"storage"` (quotes included, so this matches only the bare quoted segment, not the path-with-slash strings already handled in Step 1). Covers the five `computers / str(controller_id) / "colossal" / "data" / ...`-style joins on lines 81, 89, 110, 267, 268.

- [ ] **Step 3: Fix `tools/recipe_import.py`**

Change:
```python
    python tools/recipe_import.py --jar "G:/libraries/.../server-1.18.2.jar" \
        --out controller/colossal/recipes
```
to:
```python
    python tools/recipe_import.py --jar "G:/libraries/.../server-1.18.2.jar" \
        --out controller/storage/recipes
```

- [ ] **Step 4: Sanity-check both files still parse**

```bash
cd "C:\Users\Pellux\Coding\InvOS\tools"
python -m py_compile deploy.py recipe_import.py
echo "exit: $?"
```

Expected: exit code 0, no output (a syntax error would print a traceback).

- [ ] **Step 5: Run the Python suite**

```bash
cd "C:\Users\Pellux\Coding\InvOS\tools"
python -m unittest test_recipe_pack test_recipe_import
echo "exit: $?"
```

Expected: all tests pass, exit code 0. (Neither test file references `colossal`, confirmed during planning, so this run is a regression check, not a fixture update.)

- [ ] **Step 6: Commit**

```bash
cd "C:\Users\Pellux\Coding\InvOS"
git add tools/deploy.py tools/recipe_import.py
git commit -m "chore: update deploy.py and recipe_import.py for the storage rename"
```

---

### Task 5: Generalize test-fixture peripheral names

**Files:**
- Modify: `controller/storage/tests/test_config_nodes.lua`
- Modify: `controller/storage/tests/test_scan_backoff.lua`
- Modify: `controller/storage/tests/test_setup_crafting.lua`

**Interfaces:**
- Consumes: nothing new — these are fixture literals passed into `Coordinator.new`, `Coordinator.nodesFrom`, and `Setup.new`/`addStorage`, whose signatures are unchanged.
- Produces: no behavior change — `"minecraft:chest_0"` exercises the exact same generic-inventory code path `"colossalchests:colossal_chest_0"` did, confirmed in Task 1. Verified not asserted by exact string elsewhere in these files during planning.

- [ ] **Step 1: Fix `controller/storage/tests/test_config_nodes.lua`**

Old string: `peripheral_name="colossalchests:colossal_chest_0"`
New string: `peripheral_name="minecraft:chest_0"`

- [ ] **Step 2: Fix `controller/storage/tests/test_scan_backoff.lua`**

Use `replace_all: true`: old string `colossalchests:colossal_chest_0`, new string `minecraft:chest_0`. Covers both the error string on line 12 and the fixture on line 26.

- [ ] **Step 3: Fix `controller/storage/tests/test_setup_crafting.lua`**

Use `replace_all: true`: old string `colossalchests:colossal_chest_0`, new string `minecraft:chest_0`. Covers the `peripherals()` fixture entry (line 23) and the `addStorage(...)` call (line 59). This file already mixes several chest-mod namespaces (`ironchests:...`) as fixtures — `minecraft:chest_0` fits the same pattern.

- [ ] **Step 4: Run the full suite**

```bash
cd "C:\Users\Pellux\Coding\InvOS\controller"
lua storage/tests/run.lua
echo "exit: $?"
```

Expected: all tests pass, exit code 0.

- [ ] **Step 5: Commit**

```bash
cd "C:\Users\Pellux\Coding\InvOS"
git add controller/storage/tests/test_config_nodes.lua controller/storage/tests/test_scan_backoff.lua controller/storage/tests/test_setup_crafting.lua
git commit -m "test: generalize example peripheral names away from Colossal Chest"
```

---

### Task 6: Generalize UI copy, code comments, and test flavor-text

**Files:**
- Modify: `controller/storage/app/setup.lua`
- Modify: `controller/storage/app/ui.lua`
- Modify: `controller/storage/app/monitor.lua`
- Modify: `controller/storage/tests/test_monitor.lua`
- Modify: `controller/storage/tests/test_setup_validation.lua`
- Modify: `controller/storage/tests/test_setup_recovery.lua`
- Modify: `controller/storage/tests/test_setup_duplicates.lua`
- Modify: `controller/storage/tests/test_setup.lua`
- Modify: `controller/storage/tests/test_runtime.lua`

**Interfaces:**
- Consumes: nothing new.
- Produces: no behavior change — these are user-facing strings and one cosmetic fixture value (`getComputerLabel`) that several test files already read/write as arbitrary flavor text.

- [ ] **Step 1: Fix the duplicate-interface warning in `app/setup.lua`**

Old string: `" may expose the same Colossal Chest", true,`
New string: `" may expose the same storage container", true,`

- [ ] **Step 2: Fix the empty-state message in `app/ui.lua`**

Old string:
```lua
        Draw.text(surface, 2, bandRow + 2, "Open Setup to add a Colossal Chest",
```
New string:
```lua
        Draw.text(surface, 2, bandRow + 2, "Open Setup to add a storage node",
```

This matches the existing generic wording one line above it (`"No storage nodes configured"`).

- [ ] **Step 3: Fix the truncation-example comment in `app/monitor.lua`**

Old string:
```lua
-- Trim from the left of a namespaced id so the meaningful part survives a narrow column:
-- "colossalchests:colossal_chest_0" reads as "colossal_chest_0", never "colossalches".
```
New string:
```lua
-- Trim from the left of a namespaced id so the meaningful part survives a narrow column:
-- "modid:long_container_name_0" reads as "long_container_name_0", never "modid:long_conta".
```

- [ ] **Step 4: Update `controller/storage/tests/test_monitor.lua` to match**

Old string:
```lua
        named.nodes[2].label = "colossalchests:colossal_chest_0"
        local surface = render(57, 16, named)
        local text = surface.allText()
        T.contains(text, "colossal_chest_0",
```
New string:
```lua
        named.nodes[2].label = "modid:long_container_name_0"
        local surface = render(57, 16, named)
        local text = surface.allText()
        T.contains(text, "long_container_name_0",
```

- [ ] **Step 5: Rename the `ColossalStorage` fixture label to `StorageController` in each of these five files**

`test_setup_crafting.lua` already uses `"StorageController"` as this same fixture's label (line 51) — this step brings the remaining files in line with that existing convention. In each file, use `replace_all: true`: old string `ColossalStorage`, new string `StorageController`.

- `controller/storage/tests/test_setup_validation.lua` (lines 16, 25)
- `controller/storage/tests/test_setup_recovery.lua` (line 16)
- `controller/storage/tests/test_setup_duplicates.lua` (line 18)
- `controller/storage/tests/test_setup.lua` (lines 34, 64, 69)
- `controller/storage/tests/test_runtime.lua` (lines 23, 25, 30, 33)

- [ ] **Step 6: Run the full suite**

```bash
cd "C:\Users\Pellux\Coding\InvOS\controller"
lua storage/tests/run.lua
echo "exit: $?"
```

Expected: all tests pass, exit code 0.

- [ ] **Step 7: Commit**

```bash
cd "C:\Users\Pellux\Coding\InvOS"
git add controller/storage/app/setup.lua controller/storage/app/ui.lua controller/storage/app/monitor.lua controller/storage/tests/test_monitor.lua controller/storage/tests/test_setup_validation.lua controller/storage/tests/test_setup_recovery.lua controller/storage/tests/test_setup_duplicates.lua controller/storage/tests/test_setup.lua controller/storage/tests/test_runtime.lua
git commit -m "feat: generalize Colossal Chest wording in UI copy and comments"
```

---

### Task 7: Update living documentation

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `CONTRIBUTING.md`
- Modify: `docs/operations.md`
- Modify: `docs/backlog.md`

**Interfaces:** None — prose and path references only.

- [ ] **Step 1: Fix `README.md`**

Old string (tagline, lines 5–7):
```
    A search-first storage terminal for CC:Tweaked, backed by pooled Colossal Chests
    and an optional crafty-turtle crafting pipeline.
```
New string:
```
    A search-first storage terminal for CC:Tweaked, backed by pooled standard containers
    and an optional crafty-turtle crafting pipeline.
```

Old string (line 20): `InvOS indexes every Colossal Chest you give it, takes deposits through a dedicated`
New string: `InvOS indexes every storage container you give it, takes deposits through a dedicated`

Old string (lines 30–31):
```
- **One pooled store.** Any number of Colossal Chests appear as a single inventory with
  priority ordering, not a wall of separate chests to check by hand.
```
New string:
```
- **One pooled store.** Any number of standard containers appear as a single inventory with
  priority ordering, not a wall of separate chests to check by hand.
```

Old string (lines 103–105):
```
1. Wire one advanced computer, a dedicated Drop-off inventory, a dedicated Pickup
   inventory, every Colossal Chest interface, and (optionally) a crafty turtle with its
   buffer chest, all onto one wired modem network.
```
New string:
```
1. Wire one advanced computer, a dedicated Drop-off inventory, a dedicated Pickup
   inventory, every storage container interface, and (optionally) a crafty turtle with its
   buffer chest, all onto one wired modem network.
```

Then, for the remaining path references, use `replace_all: true`: old string `colossal/`, new string `storage/`. This covers:
- `controller/colossal/deployment_manifest.lua` (quick start step 2 and the architecture section)
- `/colossal/main.lua` (quick start step 3)
- `controller/colossal/app/splash.lua` (the "What it looks like" section link)
- `colossal/app/`, `colossal/core/`, `colossal/shared/`, `colossal/recipes/` (architecture section)
- `lua colossal/tests/run.lua` (development section)

- [ ] **Step 2: Fix `AGENTS.md`**

Old string (line 5):
```
This repository contains a search-first CC:Tweaked wired-inventory storage terminal backed by one or more Colossal Chests. Version 1 supports Drop-off imports, pooled NBT-aware indexing, exact retrieval requests, a controller UI, and a resizable public monitor.
```
New string:
```
This repository contains a search-first CC:Tweaked wired-inventory storage terminal backed by one or more standard storage containers. Version 1 supports Drop-off imports, pooled NBT-aware indexing, exact retrieval requests, a controller UI, and a resizable public monitor.
```

Then, for the repository-layout path references, use `replace_all: true`: old string `colossal/`, new string `storage/`. This covers every `controller/colossal/...` reference in the "Repository layout" section (`main.lua`, `app/`, `core/`, `shared/`, `recipes/`, `data/custom_recipes.lua`, `tests/`, `deployment_manifest.lua`) and the `colossal/app/splash.lua` reference near the top of that section.

- [ ] **Step 3: Fix `CONTRIBUTING.md`**

Use `replace_all: true`: old string `colossal/`, new string `storage/`. This file's every `colossal` reference is a path (`controller/colossal/tests/`, `lua colossal/tests/run.lua`, `controller/colossal/main.lua`, `controller/colossal/app/*.lua`, `controller/colossal/recipes/`, `colossal/data/custom_recipes.lua`) — no prose wording to adjust.

- [ ] **Step 4: Fix `docs/operations.md`**

Old string (title, line 1): `# Colossal Storage v1 Operations`
New string: `# InvOS Operations`

Old string (line 5): `Use one advanced computer as the controller. Connect it, the Drop-off inventory, the Pickup inventory, every Colossal Chest interface, and the status monitor to one wired modem network. Right-click each wired modem so its red connection indicator is active.`
New string: `Use one advanced computer as the controller. Connect it, the Drop-off inventory, the Pickup inventory, every storage container interface, and the status monitor to one wired modem network. Right-click each wired modem so its red connection indicator is active.`

Old string (line 7): `Expose exactly one inventory interface per physical Colossal Chest. Multiple interfaces on the same structure can make one inventory appear twice and invalidate capacity and transfer planning. The setup validator flags identical interfaces, but the operator remains responsible for confirming the physical topology.`
New string: `Expose exactly one inventory interface per physical storage container. Multiple interfaces on the same container can make one inventory appear twice and invalidate capacity and transfer planning. The setup validator flags identical interfaces, but the operator remains responsible for confirming the physical topology.`

Old string (line 9): `The Drop-off and Pickup must be separate inventories and must not be Colossal Chest storage nodes. Wireless modems do not expose adjacent inventories to the peripheral network.`
New string: `The Drop-off and Pickup must be separate inventories and must not be pooled storage nodes. Wireless modems do not expose adjacent inventories to the peripheral network.`

Old string (line 26): `4. Add each physical Colossal Chest once. Give every node a recognizable label. Lower priority numbers receive imports first.`
New string: `4. Add each physical storage container once. Give every node a recognizable label. Lower priority numbers receive imports first.`

Old string (line 27): `5. Run validation. It checks availability, required wired-inventory methods, role collisions, and suspicious duplicate Colossal interfaces without moving items.`
New string: `5. Run validation. It checks availability, required wired-inventory methods, role collisions, and suspicious duplicate storage interfaces without moving items.`

Then, for the remaining path references, use `replace_all: true`: old string `colossal/`, new string `storage/`. This covers every `controller/colossal/deployment_manifest.lua`, `colossal/data`, `/colossal/main.lua`, `controller/colossal/recipes`, and shell-command path reference throughout the rest of the file (Fresh install step 3–4, the deployment-safety checklist, the recipe-pack section, and the example `recipe_import.py` / `luac` commands).

- [ ] **Step 5: Fix `docs/backlog.md`**

Old string:
```
- **Storage node labels default to the peripheral name.** Setup writes the peripheral name as
  the label, so the Nodes page reads `colossal_chest_0` rather than anything a person chose.
  The wizard has no rename step.
```
New string:
```
- **Storage node labels default to the peripheral name.** Setup writes the peripheral name as
  the label, so the Nodes page reads `chest_0` rather than anything a person chose.
  The wizard has no rename step.
```

- [ ] **Step 6: Commit**

```bash
cd "C:\Users\Pellux\Coding\InvOS"
git add README.md AGENTS.md CONTRIBUTING.md docs/operations.md docs/backlog.md
git commit -m "docs: remove Colossal Chest wording from living documentation"
```

---

### Task 8: Final verification sweep

**Files:** None modified (verification only, unless it finds a gap — see Step 1).

**Interfaces:** None.

- [ ] **Step 1: Grep the whole tree for residual `colossal` matches**

```bash
cd "C:\Users\Pellux\Coding\InvOS"
grep -ril colossal . --exclude-dir=.git
```

Expected remaining matches, and only these:
- `controller/storage/recipes/*.lua` — real mod-registered recipe/item IDs (`colossalchests:colossal_chest_0`, `colossalchests:uncolossal_chest`, etc.), explicitly out of scope.
- `docs/superpowers/specs/2026-08-02-colossal-storage-v1-design.md`, `docs/superpowers/plans/2026-08-02-colossal-storage-v1.md`, and any other dated historical spec/plan filenames or their internal contents — explicitly out of scope.
- `docs/superpowers/specs/2026-08-13-storage-rebrand-design.md` and this plan file itself — they document the rebrand and are expected to mention the old name.

If anything else turns up, fix it before proceeding — it means an earlier task's file list was incomplete.

- [ ] **Step 2: Run the full Lua suite**

```bash
cd "C:\Users\Pellux\Coding\InvOS\controller"
lua storage/tests/run.lua
echo "exit: $?"
```

Expected: all tests pass, exit code 0.

- [ ] **Step 3: Run the full Python suite**

```bash
cd "C:\Users\Pellux\Coding\InvOS\tools"
python -m unittest test_recipe_pack test_recipe_import
echo "exit: $?"
```

Expected: all tests pass, exit code 0.

- [ ] **Step 4: `git diff --check` against the whole branch**

```bash
cd "C:\Users\Pellux\Coding\InvOS"
git diff --check main
```

Expected: no output. (If this plan is executed directly on `main`, compare against the commit before Task 1 instead.)

- [ ] **Step 5: Report**

No commit for this task — it is verification of Tasks 1–7's commits. Summarize: suite status, Python suite status, and confirmation that the only remaining `colossal` matches are the recipe pack and historical documents.
