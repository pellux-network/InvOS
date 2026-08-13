# Storage Rebrand: Remove Colossal Chest Naming

## Context

The controller module lives at `controller/colossal/`, and "Colossal Chest" /
"Colossal Storage" naming is threaded through code comments, test fixtures,
UI copy, and living documentation. The underlying storage logic has never
actually depended on Colossal Chests specifically: `app/setup.lua` validates
every node through the generic CC:Tweaked `peripheral.hasType(name,
"inventory")` interface, which any standard container implements, and the
system already pools multiple labeled, priority-ordered nodes into one
store. This is a naming/branding pass, not a behavior change: confirm the
generic-container behavior holds, then remove the Colossal-specific naming
so the project stops implying a dependency it doesn't have.

## Goals

- Confirm (don't just assume) that no code path special-cases Colossal
  Chests or otherwise assumes a specific container type.
- Rename the module directory `controller/colossal/` to `controller/storage/`
  and update every reference to the old path.
- Replace "Colossal Chest" / "Colossal Storage" wording in code comments,
  test fixtures, UI copy, and living docs with generic "storage node" /
  "container" language.
- Leave real in-game IDs (the generated recipe pack) and dated historical
  spec/plan documents untouched.

## Non-goals

- No live server redeploy. Repo-only; the live tree at
  `G:\world\computercraft\computer\4\colossal\` is untouched until a
  separate, deliberate deploy step.
- No change to recipe pack *content* under `controller/storage/recipes/`
  (formerly `controller/colossal/recipes/`) — those are real mod-registered
  item/recipe IDs (`colossalchests:colossal_chest_0`,
  `colossalchests:uncolossal_chest`, etc.) sourced from the live modpack.
  They move with the directory rename but are not hand-edited.
- No rewriting of dated historical documents under
  `docs/superpowers/specs/` and `docs/superpowers/plans/` (e.g.
  `2026-08-02-colossal-storage-v1-design.md`). They record decisions made
  at the time and stay as-is.
- No behavior change to peripheral validation, scanning, or pooling logic —
  this spec is confirming existing generic behavior and renaming, not adding
  container-type logic.

## Design

### 1. Directory rename

`controller/colossal/` → `controller/storage/`, a straight `git mv` of the
whole tree (`app/`, `core/`, `shared/`, `recipes/`, `tests/`,
`deployment_manifest.lua`, `main.lua`).

Every reference to the old path updates in the same change:

- `controller/startup.lua`: `package.path` prefix and the supervised entry
  point path (`/colossal/main.lua` → `/storage/main.lua`), plus
  `env.data_root` default (`/colossal/data` → `/storage/data`).
- `controller/storage/tests/run.lua`: `package.path` prefix.
- `controller/storage/deployment_manifest.lua`: every listed path
  (`colossal/...` → `storage/...`), including the comment referencing
  `colossal/data/`.
- `tools/deploy.py`: `PRESERVED = ("colossal/data",)` and every other
  `colossal/...` path (config marker lookup, backup/restore paths, manifest
  path, docstring references).
- `tools/recipe_import.py`: `--out controller/colossal/recipes` example in
  the header comment.
- All `require(...)` calls and `package.path` manipulations across
  `controller/storage/**/*.lua` and `controller/storage/tests/**/*.lua`
  that reference the `colossal.` module prefix.
- Every test file that instantiates `Store.new(..., "colossal/data")` as a
  fixture root path, and `controller/storage/tests/test_deployment.lua`'s
  literal `"colossal/..."` path assertions and `^colossal/` pattern match,
  which must move in lockstep with the manifest or the "every manifest path
  exists on disk" test fails.

### 1a. Backup key rename (decided during planning)

`app/backup.lua` writes and reads the config-and-alias floppy backup under
the literal key `"colossal-backup"` — this is an on-disk filename for a
physical backup floppy, not just internal naming. Confirmed with the user:
rename outright to `"invos-backup"`, no backward-compatibility fallback for
floppies already written under the old key.

### 2. Technical confirmation (no behavior change expected)

Before/alongside the rename, verify these hold (already true from initial
investigation, re-confirmed as part of implementation):

- `app/setup.lua` node validation uses `peripheral.hasType(name,
  "inventory")`, never a Colossal-specific type string.
- No module keys off a peripheral's `getType()` result to gate storage
  behavior (`turtle_link.lua`'s `getType` use is for the turtle/modem link,
  unrelated to storage nodes — out of scope).
- Node pooling (`core/registry.lua`, `core/scanner.lua`,
  `core/reconciliation.lua`) treats every node identically regardless of
  peripheral type or count.

If any of these turn out false, that's a real bug to fix as part of this
work, not just a rename — flag it before proceeding further.

### 3. Test fixtures

Rename example peripheral names that read as real Colossal Chest network
names to a generic placeholder (`"minecraft:chest_0"` or similar,
matching whichever convention keeps existing assertions meaningful):

- `controller/storage/tests/test_config_nodes.lua`
- `controller/storage/tests/test_scan_backoff.lua`
- `controller/storage/tests/test_setup_crafting.lua`
- `controller/storage/tests/test_monitor.lua` (also update the truncation
  assertion string that checks for `"colossal_chest_0"`)

### 4. UI copy and comments

- `app/setup.lua`: duplicate-interface warning ("...may expose the same
  Colossal Chest") → generic "storage node" wording.
- `app/ui.lua`: empty-state message ("Open Setup to add a Colossal Chest")
  → generic "storage node" wording.
- `app/monitor.lua`: comment about label truncation using
  `"colossalchests:colossal_chest_0"` as its example → replace with a
  generic example string.

### 5. Living documentation

Update wording (not historical facts) in:

- `README.md` — tagline, "One pooled store" bullet, quick start steps.
- `AGENTS.md` — project description, repository layout section.
- `CONTRIBUTING.md` — path references and prose.
- `docs/operations.md` — title, topology instructions, all `colossal/...`
  path references, wording throughout ("Colossal Storage v1 Operations" →
  generic title, "Colossal Chest interface" → "storage node interface").
- `docs/backlog.md` — the one wording reference to `colossal_chest_0` as an
  example label.

## Testing

- `lua storage/tests/run.lua` (full suite) from `controller/`, post-rename.
- `python -m unittest test_recipe_pack test_recipe_import` from `tools/`,
  confirming `deploy.py` and `recipe_import.py` path changes don't break
  existing tests.
- `git diff --check` for whitespace/line-ending issues per repo convention.
- Grep the full tree post-change for residual case-insensitive `colossal`
  matches outside the excluded recipe pack IDs and historical spec/plan
  docs, to confirm nothing was missed.

## Risks

- **Live/repo drift**: after this merges, the live server's deployed tree
  (`.../computer/4/colossal/`) no longer matches the repo's
  `controller/storage/` layout until a deliberate redeploy. `startup.lua`
  and `deployment_manifest.lua` in the repo will reference paths that don't
  exist on the live tree yet. This is intentional (non-goal: no live
  redeploy) but means the live server must not be redeployed piecemeal from
  this branch — only as a full, deliberate deploy following
  `docs/operations.md`'s upgrade procedure once ready.
- **Mechanical scope**: ~68 files touched, almost all mechanical text
  changes, but the directory rename means every `require` path in the
  renamed tree must be verified rather than assumed correct.
