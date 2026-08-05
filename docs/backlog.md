# Backlog

Ordered by what would hurt most if left alone. Everything here is grounded in something
actually observed on the live installation — where an item is speculative, it says so.

## Correctness

### The pack goes stale silently
The recipe pack is a snapshot of the game taken at export time. Change a mod, a config flag
or a KubeJS script and the pack is wrong with no indication: the controller will offer
recipes that no longer exist and hide ones that now do. This is exactly the failure that
cost most of the 2026-08-05 session, and nothing currently detects it.

Cheapest useful version: have `pellstore_export.js` also write the crafting-recipe count and
a hash of the recipe ids, and have the controller warn on the Crafting page when its pack
does not match what the server last exported. Needs a channel from the export to the
controller, so it is not free.

### Recipes the pack cannot represent
Counted and reported at import, currently 234 on this pack:

- **208 NBT-bearing results.** The controller identifies a crafted item by plain id, so it
  can neither verify nor deliver a specific variant. Supportable only if the output NBT is
  deterministic and the identity model grows to carry it.
- **21 NBT-constrained ingredients** (`forge:nbt`, `forge:partial_nbt`). Ingredient matching
  is deliberately NBT-free; honouring these means teaching the planner and the turtle about
  variants.
- **5 custom ingredient types** carrying neither item nor tag.
- Separately, `cucumber:shaped_tag` (tag result) and `cucumber:shaped_transfer_damage`
  (output inherits an ingredient's durability) are refused by type.

None of these are wrong today — a refused recipe is absent, never miscrafted — but each is a
thing the operator can make by hand and not through the system.

### 7,967 outputs have no display name
7,421 are `everycomp`, which generates its blocks at runtime and ships no static lang entry,
so no jar can name them. The recipe manager does not carry language data either. Possible
fix: have the export ask the game for each item's display name. Untested — server-side
translation may return the raw key rather than the English string.

### Planner search bounds are unvalidated
`MAX_TAG_TRIALS = 8`, `MAX_RECIPE_TRIALS = 4` and `RESOLVE_BUDGET = 20000` were chosen to
stop a combinatorial explosion on a 412-member tag, not measured. A craft that fails with
`INSUFFICIENT_MATERIALS` while the materials are present would be the symptom of a cap set
too low. Worth measuring against real multi-step crafts before trusting them.

## Untested paths

These work in the host suite and have never run in game:

- **A large batched craft against the modded pack.** 500 sticks worked against the vanilla
  pack; nothing that size has run since the pack grew to 22,705 outputs.
- **A deep tree** — three or more chained intermediates.
- **A queued second job** while one is running.
- **The `TRANSFER_STALLED` alert.** Added after a real stall, never seen fire.
- **Job cancellation mid-craft.**

## Performance

Measured on the host, never on a ComputerCraft computer, where everything is far slower:

- `items.lua` is 1.85 MB and parsed eagerly at boot. Boot time on #4 has not been measured
  since the pack grew; if `INDEXING` now takes noticeably longer, this is why.
- Crafting search costs ~10 ms per keystroke on host over 22,391 entries. The catalogue and
  its lowercased search index are both resident.
- The pack is 5.89 MB against a 10,000,000 byte `computer_space_limit`. Another large mod
  addition could approach it.

## UI polish

- **Nothing distinguishes "no such item" from "exists but is not grid-craftable".** An
  operator searching for something a machine makes gets an empty list and no explanation.
  This caused real confusion.
- **Search ranking is tuned against three queries** (`chest`, `oak`, `piston`). The tier
  order is a judgement call and may rank oddly on other searches.
- **Tag and recipe pins have no UI.** `core/craft_prefs.lua` supports pinning which item a
  tag resolves to and which recipe an output uses; nothing exposes it, so the planner's
  choice cannot be overridden.
- **Job progress is coarse** — state and step index, no per-step detail.

## Original scope, still deferred

- **The Compacting menu.** Explicitly out of scope in the crafting spec, and it rides on the
  pipeline that now works: auto-compaction of cobblestone and similar into 2x/3x blocks.

## Tooling

- `tools/deploy.py` has no `--dry-run`.
- The re-export loop (restart → export → regenerate → verify → deploy) is documented but
  manual, and it is now the routine way to pick up modpack changes.
- **Test doubles keep being more permissive than reality.** This has caused defects
  repeatedly: a loader accepting `pack_1` when the converter writes `pack_01`; a fake turtle
  with no slot or stack limits; single-ingredient staging tests that could not see the buffer
  ordering bug; hand-written dump fixtures using ints where KubeJS emits floats. A shared
  fake that models CC's real constraints once would be worth more than the individual fixes.
