# Backlog

Ordered by what would hurt most if left alone. Everything here is grounded in something
actually observed on the live installation — where an item is speculative, it says so.

## Correctness

### The pack goes stale silently
The recipe pack is a snapshot of the game taken at export time. Change a mod, a config flag
or a KubeJS script and the pack is wrong with no indication: the controller will offer
recipes that no longer exist and hide ones that now do. This is exactly the failure that
cost most of the 2026-08-05 session, and nothing currently detects it.

Cheapest useful version: have `invos_export.js` also write the crafting-recipe count and
a hash of the recipe ids, and have the controller warn on the Crafting page when its pack
does not match what the server last exported. Needs a channel from the export to the
controller, so it is not free.

### Recipes the pack cannot represent
Counted and reported at import, currently 234 on this pack:

- **208 NBT-bearing results.** The controller identifies a crafted item by plain id, so it
  can neither verify nor deliver a specific variant. Supportable only if the output NBT is
  deterministic and the identity model grows to carry it.
- **21 NBT-constrained ingredients** (`forge:nbt`, `forge:partial_nbt`). Ingredient matching
  is deliberately NBT-free; honoring these means teaching the planner and the turtle about
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

`tools/emulator/` narrowed this list but did not empty it. It runs the controller under
ComputerCraft's own Lua 5.2 against emulated inventories, which is a real third tier between
the host suite and the live installation — but it emulates no crafting turtle, so every
crafting path below still has never run outside host fakes. See
[`emulator.md`](emulator.md) for what it does and does not reproduce.

These work in the host suite and have never run in game:

- **A large batched craft against the modded pack.** 500 sticks worked against the vanilla
  pack; nothing that size has run since the pack grew to 22,391 outputs.
- **A deep tree** — three or more chained intermediates.
- **A queued second job** while one is running.
- **The `TRANSFER_STALLED` alert.** Added after a real stall, never seen fire.
- **Job cancellation mid-craft.**

Now covered outside the host suite, under real CC Lua 5.2 rather than in game: boot from the
deployment manifest, indexing and stock aggregation across eight containers, search filtering,
page navigation, the setup wizard's discovery step, and NBT variants staying distinct through
scanning and indexing. Emulated, not played — but no longer only host fakes.

**`install.lua`'s turtle-side auto-detection.** The emulator has no crafting turtle (above),
so `tools/emulator/test_install.py` only exercises the controller branch of
`install.lua`'s `turtle ~= nil` check. The turtle branch itself is proven only by that same
logic being read correctly, not by actually booting a turtle against it — same limitation,
same reason, as the crafting paths above.

## Performance

Measured on the host, never on a ComputerCraft computer, where everything is far slower.
`python3 tools/emulator/craftos.py profile` now counts peripheral calls exactly — the unit
that actually costs server ticks, and previously only inferrable from wall-clock timings.
It confirms the scanner issues one `size` and one `list` per node per scan and nothing else
per slot beyond the metadata budget. It does not model tick cost, so it ranks work rather
than predicting how long the real computer takes:

- `items.lua` is 1.85 MB and parsed eagerly at boot. Boot time on #4 has not been measured
  since the pack grew; if `INDEXING` now takes noticeably longer, this is why.
- Crafting search costs ~10 ms per keystroke on host over 22,391 entries. The catalog and
  its lowercased search index are both resident.
- The pack is 5.89 MB against a 10,000,000 byte `computer_space_limit`. Another large mod
  addition could approach it.

## UI polish

The visual system is built: shared palette, drawing primitives and layout, all six pages and
both monitors, double buffering, and a clickable terminal. What follows is what it did not
address.

- **Nothing distinguishes "no such item" from "exists but is not grid-craftable".** An
  operator searching for something a machine makes gets an empty list and no explanation.
  This caused real confusion.
- **Search ranking is tuned against three queries** (`chest`, `oak`, `piston`). The tier
  order is a judgment call and may rank oddly on other searches.
- **Recipe pins have no UI, and no pin can be cleared.** `core/craft_prefs.lua` supports
  pinning both which item a tag resolves to (`pinTag`) and which recipe an output uses
  (`pinRecipe`), plus unpinning either. Only `pinTag` is wired up: `P` on the plan review
  screen pins the highlighted tag choice. `pinRecipe`, `unpinTag` and `unpinRecipe` have no
  caller in `app/`, so an output with several recipes cannot be steered, and a tag pinned by
  mistake cannot be undone from the terminal.
- **Job progress is coarse** — state and step index, no per-step detail.
- **The Search stock meter is relative to the largest item on screen**, so the same item reads
  differently depending on what else the query matched. Nothing here has a real ceiling, so an
  absolute scale would need one invented; this was the least arbitrary option, not a good one.
- **The boot splash is not double-buffered.** It clears and repaints per frame like everything
  else did before `app/buffer.lua`; it looks fine at current frame rates, and the fix is the
  same wrap applied in `startup.lua` if it ever does not.

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
  `tools/emulator/` is the strongest version of that — it is not a double at all, but the
  real runtime — and it already covers inventories, stack limits, slot counts and Lua 5.2
  semantics. It does not yet cover the turtle, which is where several of the defects above
  actually came from, so the argument for a constrained shared fake still stands for
  `turtle/`.
- **The emulator has no crafting turtle.** `periphemu` can create a `computer` peripheral, so
  a second emulated computer running `turtle/` is possible in principle; until then crafting
  is exercised only by host fakes, and `scenario.configured()` deliberately leaves the turtle
  unbound so the Craft page reports crafting unavailable rather than pretending.
- **Emulated NBT does not survive item movement.** `smoke/world.lua` re-attaches seeded NBT
  per inventory and slot because CraftOS-PC's chests drop it entirely; the shim does not
  follow items through `pushItems`/`pullItems`. Enough for indexing, search and planning;
  not enough to test a transfer that moves a variant.
