# Backlog

Ordered by what would hurt most if left alone. Everything here is grounded in something
actually observed on a live installation — where an item is speculative, it says so.

Figures derived from a recipe pack are marked *(pack-dependent)*. They describe one
generated pack and drift on every regeneration, so treat them as scale, not as constants;
re-measure before relying on one. Counts below were last measured 2026-08-16.

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
Counted and reported at import; 234 on the pack these figures were taken from
*(pack-dependent)*:

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

### Thousands of outputs have no display name
7,997 of 22,705 outputs on the current pack, of which 7,421 are `everycomp`
*(pack-dependent)*. `everycomp` generates its blocks at runtime and ships no static lang
entry, so no jar can name them; the recipe manager does not carry language data either.
Such an item stores its raw id as its name, so it is searchable only by id.

Possible fix: have the export ask the game for each item's display name. Untested —
server-side translation may return the raw key rather than the English string.

Re-measure from `controller/` with:

```bash
lua -e 'local it=dofile("storage/recipes/items.lua") local ix=dofile("storage/recipes/index.lua")
local out={} for _,p in ipairs(ix.outputs or {}) do out[p]=true end
local n=0 for i,id in ipairs(it.ids) do if out[i] and it.names[i]==id then n=n+1 end end
print(n.." of "..#(ix.outputs or {}).." outputs unnamed")'
```

### Planner search bounds are unvalidated
`MAX_TAG_TRIALS = 8`, `MAX_RECIPE_TRIALS = 4` and `RESOLVE_BUDGET = 20000` were chosen to
stop a combinatorial explosion on a 412-member tag, not measured. A craft that fails with
`INSUFFICIENT_MATERIALS` while the materials are present would be the symptom of a cap set
too low. Worth measuring against real multi-step crafts before trusting them.

## Untested paths

`tools/emulator/` narrowed this list but did not empty it. It runs the controller under
ComputerCraft's own Lua 5.2 against emulated inventories, which is a real third tier between
the host suite and the live installation. It now boots the crafting turtle too — a second
emulated computer running `turtle/` over real rednet — so the crafting pipeline no longer runs
only against host fakes. See [`emulator.md`](emulator.md) for what it does and does not
reproduce, and for the oracle's limits.

These work in the host suite and have never run in game:

- **A large batched craft against the modded pack.** 256 sticks — one turtle call with
  `per_cell` at 64 — now runs in the emulator against the fixture pack, and an 8-stick
  two-step craft runs against the real modded pack. A batch in the *hundreds against the
  modded pack* has still not run anywhere, and neither has anything at all in game.
- **The `TRANSFER_STALLED` alert.** Added after a real stall, never seen fire. Forcing it
  needs a transfer wedged for 60 seconds, which the harness can only do by stalling the world
  server — a minute of test time to watch an alert that deliberately does not intervene.

Now covered outside the host suite, under real CC Lua 5.2 rather than in game: boot from the
deployment manifest, indexing and stock aggregation across eight containers, search filtering,
page navigation, the setup wizard's discovery step, NBT variants staying distinct through
scanning and indexing, and — since the emulated turtle — a whole craft from plan through
staging, the turtle command, collection and delivery. Specifically: a single-ingredient craft,
a two-ingredient one, a two-step tree, a **three-step tree** (logs to planks to sticks to
torches), a **256-item batch** in one turtle call, a **second job queued behind a running
one**, **cancelling a running job** and proving the next one still completes, a world that
refuses a recipe the pack claims, and — where a generated pack exists — a craft against the
real modpack plus a check that every recipe it declares is one the emulated world can match.
Emulated, not played — but no longer only host fakes.

**`install.lua`'s turtle-side auto-detection.** The `turtle` global now exists on the emulated
crafting turtle, so the `turtle ~= nil` branch is reachable there — but
`tools/emulator/test_install.py` still exercises only the controller branch. The turtle branch
is proven by that logic being read correctly, not by an install actually running against a
turtle.

## Performance

Measured on the host, never on a ComputerCraft computer, where everything is far slower.
`python3 tools/emulator/craftos.py profile` now counts peripheral calls exactly — the unit
that actually costs server ticks, and previously only inferrable from wall-clock timings.
It confirms the scanner issues one `size` and one `list` per node per scan and nothing else
per slot beyond the metadata budget. It does not model tick cost, so it ranks work rather
than predicting how long the real computer takes:

- Ordinary retrieval and Drop-off import now refresh only the storage nodes named by a
  tentative plan, replan against those fresh snapshots, and reconcile only the storage
  endpoints actually touched. The Lua 5.2 emulator regression holds retrieval at eight
  profiled calls (`3 size`, `3 list`, `1 getItemDetail`, `1 pushItems`) with both 1 and 20
  storage nodes. Import holds at sixteen controller calls (`5 size`, `5 list`,
  `5 getItemDetail`, `1 pushItems`); its test records a seventeenth, harness-only `setItem`
  call used to deposit the item after profiling is reset. A 1/5/10/20-node emulator sweep
  was correspondingly flat (retrieval 1.85--1.87s; import 0.52--0.56s), but those host
  wall-clock values do not predict live server ticks. Initial indexing, ordinary background
  refresh, crafting plans, and the bounded no-plan/retarget fallback intentionally still
  inspect the full storage pool.
- `items.lua` is 1.85 MB and parsed eagerly at boot *(pack-dependent)*. Boot time has not
  been measured on a real computer since the pack grew; if `INDEXING` takes noticeably
  longer, this is why.
- Crafting search costs ~10 ms per keystroke on host over the full catalogue, currently
  22,705 outputs *(pack-dependent)*. The catalogue and its lowercased search index are both
  resident.
- The pack is 5.89 MB against a 10,000,000 byte `computer_space_limit` *(pack-dependent)*.
  Another large mod addition could approach it.

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
- **Job progress is coarse.** The jobs list shows the state name, plus a queue position for
  `QUEUED` (`ui.lua`'s craft-jobs view) — no step index and no per-step detail, so a
  multi-step craft looks identical at step one and step five.
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
  real runtime — and it covers inventories, stack limits, slot counts and Lua 5.2 semantics.
  It now covers the turtle too: the firmware runs unmodified on a second emulated computer,
  and the `turtle` API it is given moves items with real `pushItems`/`pullItems` between
  emulated chests, so slot counts and stack limits are enforced by the emulator rather than
  by the fake. The remaining double is the recipe oracle, and it is deliberately small.
- **The emulated world's recipes now come from the pack.** `smoke/craft_oracle.lua` loads
  every shard and resolves tags, so any item the controller can plan is one the emulator can
  craft — 26,087 recipes indexed in about 100ms on a real modpack. It therefore cannot catch
  a pack claiming a recipe the game does not have, since it believes the same file; passing
  an explicit recipe list still makes the world disagree on demand. The earlier hand-written
  five-recipe table had that independence by default and could test no modded item at all,
  which was the wrong trade for a system whose defects come from modded crafting.
- **Emulated NBT does not survive item movement.** `smoke/world.lua` re-attaches seeded NBT
  per inventory and slot because CraftOS-PC's chests drop it entirely; the shim does not
  follow items through `pushItems`/`pullItems`. Enough for indexing, search and planning;
  not enough to test a transfer that moves a variant.
