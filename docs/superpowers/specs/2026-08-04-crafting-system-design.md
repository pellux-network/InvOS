# Crafting system

Status: specified, not implemented. Supersedes `2026-08-03-crafting-turtle-design.md`, which
remains accurate about reconciliation scope and is the reasoning this design builds on.

This covers recipe storage, multistep craft planning, craft execution through a crafty
turtle, and the crafting UI. Compacting is explicitly out of scope and is designed *for*, not
built here.

## What changed since the turtle spec

The earlier spec left four open questions. Three are now answered from evidence rather than
assumption.

**A wired modem does network a turtle.** The controller's peripheral list reports the crafting
turtle as an attached peripheral. The turtle's second upgrade slot stays free; no wireless or
ender modem is needed. Rednet runs over the wired modem.

**The turtle exposes no inventory.** The peripheral list reports the turtle as one type --
`turtle_2 (turtle)` -- while every chest reports two, for example
`ironchests:netherite_chest_1 (ironchests:netherite_chest, inventory)`. Confirmed twice, on
two different turtle instances. The turtle peripheral therefore offers only computer control
(`turnOn`, `shutdown`, `reboot`, `isOn`), not turtle actions and not an inventory. The
controller cannot push items into the turtle. Items reach it only by `suckDown` from the
inventory directly beneath it.

*Re-verify at implementation time.* If the turtle ever reports an `inventory` type, the
controller could push straight into grid slots and the staging design collapses to something
much simpler.

**The turtle's peripheral name is volatile and must never be hardcoded.** It was `turtle_1`
in one observation and `turtle_2` in the next, because CC derives the name from the computer
ID and a rebuilt turtle receives a new one. It is a Setup binding like every inventory.

Rednet addresses computers by ID, not by peripheral name, so the controller resolves the
turtle's rednet ID at runtime with `peripheral.call(<bound name>, "getID")` rather than
storing an ID that can go stale. A rebuilt turtle then needs one Setup rebind and nothing
else.

**Staging happens in a dedicated buffer, not in Pickup.** See Topology.

The fourth question, recipe storage, is answered by the Recipe pipeline section.

## Topology

```
        [ Crafting Turtle ]   Crafty upgrade + wired modem
                 |              suckDown / dropDown -- the only direct access it needs
        [  Craft Buffer   ]   plain chest + wired modem, role "craft_buffer"
                 |
        =============== wired network ===============
          Storage   <->   Buffer   <->   Pickup   <->   Drop-off
```

The turtle and buffer sit behind the system with no player access. The turtle needs direct
adjacency to exactly one inventory: the buffer beneath it. Every other movement -- pulling
ingredients from Storage into the Buffer, pushing a finished result from the Buffer to Pickup
-- is an ordinary network `pushItems`, which the controller already performs for every
transfer today.

Use a 27-slot chest or larger. A 3x3 recipe stages up to nine distinct ingredient stacks and
the result needs somewhere to land.

### Confirmed bindings

The full hardware is built and wired. Observed from the controller, every role below is bound
in Setup and none is hardcoded:

| role | peripheral |
|---|---|
| Drop-off | `ironchests:netherite_chest_1` |
| Storage | `colossalchests:colossal_chest_0` |
| Pickup | `ironchests:diamond_chest_1` |
| Craft buffer | `ironchests:diamond_chest_2` |
| Crafting turtle | `turtle_2` -- *volatile, see above* |
| Main monitor | `top` |
| Crafting monitor | `monitor_0` |

Also attached and unused by this design: `bottom (modem, peripheral_hub)` and
`speaker_0 (speaker)`.

Note that Pickup and the buffer are both `ironchests:diamond_chest`, distinguished only by
their trailing index. `Registry.validate` already rejects binding one peripheral to two roles,
which is what stops a mis-set Setup from pointing crafting at the chest players collect from.

### Why a dedicated buffer rather than Pickup

The earlier spec put the turtle above Pickup and argued the dedicated chest was the worse
design. That argument was about *reconciliation*, and it still holds: reconciliation baselines
are captured only from nodes with `role == "storage"`, so a mutable Pickup is tolerated by
construction. The buffer does not weaken that -- it is not `role == "storage"` either, so it
never enters a baseline, and `core/transfer.lua` and `core/reconciliation.lua` need no change.

What the earlier spec did not weigh is *multistep*. A single craft stages ingredients once. A
multistep craft stages repeatedly across many cycles while intermediates accumulate. Over that
window, Pickup's two properties become disqualifying:

- **Players share it.** Every retrieval lands there. A player collecting mid-job takes
  ingredients already withdrawn from storage. The earlier spec lists this as the top risk and
  offers "add a second Pickup node bound to crafting only" as the expensive mitigation. That
  mitigation is this design.
- **`PICKUP_FULL` is a deliberate stop, not an automatic retry.** `generation` advances on
  every scan and is not evidence Pickup drained, so a full Pickup blocks awaiting explicit
  operator retry. Staging many ingredients across many steps makes that likely.

With a buffer, crafting never touches Pickup until final delivery, so `PICKUP_FULL` is
reachable only on the last hop; nothing can steal a staged ingredient; and intermediates park
in the buffer between steps instead of round-tripping through storage.

Drop-off remains unsuitable for staging for the reason the earlier spec gives: the import loop
continuously drains it, so staged ingredients would race the controller putting them back.

## Recipe pipeline

### Source

A host-side converter reads the vanilla recipe and tag data out of the server jar already on
disk. On this installation that is:

```
C:\Servers\Wold's Vaults\libraries\net\minecraft\server\1.18.2\server-1.18.2.jar
```

which is a Mojang *bundler* jar. The real jar is nested at
`META-INF/versions/1.18.2/server-1.18.2.jar`, and that is what must be opened.

Verified contents of the nested jar (9082 entries):

| data | count | disposition |
|---|---|---|
| `minecraft:crafting_shaped` | 543 | imported |
| `minecraft:crafting_shapeless` | 183 | imported |
| `minecraft:crafting_special_*` | 13 | dropped -- hardcoded in Java, no data to read |
| smelting / blasting / smoking / campfire | 112 | dropped -- not a 3x3 craft |
| `minecraft:stonecutting` | 198 | dropped -- not a 3x3 craft |
| `minecraft:smithing` | 9 | dropped -- not a 3x3 craft |
| `data/minecraft/tags/items/*.json` | 71 | imported |
| `assets/minecraft/lang/en_us.json` | 2042 usable entries | imported |

726 recipes are imported, covering 639 distinct output items. 78 of those outputs have more
than one recipe. 12 recipes use ingredient alternation lists. 12 of the 71 tags nest inside
other tags; `#minecraft:logs` expands to 32 items.

Raw compact JSON for the imported set is 148,536 bytes. Interning item IDs brings the emitted
pack well under that, against a CC computer space limit of 1,000,000 bytes.

The lang file matters more than it looks: it is the only way the Crafting page can display a
proper name for an item that has never been in storage, because `getItemDetail` requires the
item to physically exist in a scanned inventory.

### Emitted pack

**Generated packs are deployed build artifacts, not mutable data.** They are written to
`colossal/recipes/` and listed in `deployment_manifest.lua`, exactly like runtime code, and
loaded with `require` rather than through `shared/store.lua`.

They cannot live under `colossal/data/`. That directory is preserved and never copied by the
deployment gate, so a pack placed there would never reach the live computer; and
`tests/test_deployment.lua` asserts that no manifest path contains the substring `data`, so
the manifest could not list it either. The split is on mutability, not on file type:

| path | nature | deployed? |
|---|---|---|
| `colossal/recipes/*.lua` | generated, regenerated wholesale, never hand-edited | yes, manifest-listed |
| `colossal/data/custom_recipes.lua` | hand-edited operator content | no, preserved |
| `colossal/data/craft_prefs.lua` | operator preferences, written at runtime | no, preserved |

Generated pack files:

- `items.lua` -- interned item IDs plus their display names, as two parallel arrays. Recipes
  reference integer indices into it. Always resident.
- `index.lua` -- the sorted item indices that at least one recipe produces, plus the shard
  count. Always resident. Together with `items.lua` this is the Crafting page's search corpus.
- `pack_NN.lua` -- recipe bodies in shards, loaded on demand and cached. A recipe lives in
  shard `1 + (output_index % shard_count)`, so every recipe for one output shares a shard and
  resolving an output costs exactly one file load.
- `tags.lua` -- the 71 tags, **pre-flattened by the converter**, so the controller never does
  recursive tag expansion at runtime.

The two `colossal/data/` files use the existing validated-store pattern, so a corrupt or
absent one falls back rather than preventing boot -- the same treatment `metadata.lua` gets.

Every recipe body keeps a `type` field even though only the two crafting types are imported,
so a later furnace or stonecutter extension adds recipes without a pack migration.

### Extensibility

Three mechanisms. `custom_recipes.lua` takes precedence over every generated pack; among
generated packs, later-loaded wins, and load order is declared in config.

1. `colossal/data/custom_recipes.lua` -- hand-editable, preserved across deployments, always
   wins.
2. Additional generated packs -- the same converter pointed at mod jars (`data/<ns>/recipes/`
   and `data/<ns>/tags/items/` have identical structure) or at a KubeJS dump.
3. Programmatic generation -- the compacting feature will emit a pack this way.

The repo module **merges** packs rather than replacing them. That is the seam compacting
depends on.

A KubeJS `forEachRecipe` server script is the correct route for the full modded set on this
server, because 410 mods plus KubeJS scripts mean the on-disk mod JSONs are not the whole
truth -- KubeJS adds and removes recipes at load time. That is a later step; vanilla-only is
the first target.

## Craft planner -- `core/craft_planner.lua`

A pure function. It takes an index snapshot, the recipe repo, and the preference store, and
returns a plan. It touches no peripherals, which is what makes the entire multistep tree
testable without Minecraft.

Resolving a target `(identity, quantity)`:

1. **Pick the recipe.** `custom_recipes.lua` wins; then a pinned preference; else deterministic
   first by recipe ID. 78 vanilla outputs need this tie-break.
2. **Size the batch.** `turtle.craft()` crafts repeatedly until one grid cell empties, so it
   produces up to 64x the recipe output in a single call when every cell holds a full stack.
   Crafts per call is the `min` over occupied cells of that cell item's stack limit, capped at
   64, and further bounded by available stock and by buffer capacity. 64 chests is one
   `craft()` call over 512 planks, not 64 calls. A recipe using an unstackable ingredient such
   as a bucket is pinned to one craft per call. AGENTS.md: throughput work belongs in reducing
   cycles, and this is where the cycles are.
3. **Resolve tags against a running reservation ledger.** Availability is always
   `live_quantity - already_reserved_by_this_plan`. Without the ledger, two branches of the
   tree both see the same 30 planks and both claim them.

   Candidates rank by: a pin that is actually available, then most-stocked, then craftable at
   all, then item ID. **Rank order alone is not sufficient**, so the planner tries candidates
   in that order and keeps the first that genuinely resolves, rolling the ledger back between
   attempts.

   The reason is concrete, and was found by running against the real pack rather than a
   fixture. Every one of the eight vanilla plank types is craftable, so when all are out of
   stock a rank-ordered choice picks `acacia_planks` alphabetically and the craft fails —
   with oak logs sitting in storage and `oak_planks` reachable the whole time. Ranking can
   only see what is craftable in principle, never what is craftable from the stock on hand.
   Trying candidates is what closes that gap. A member already in stock still ranks first and
   succeeds immediately, so the search only does real work in the case that was broken.

   **Alternation lists resolve the same way.** 12 vanilla recipes give an ingredient as a list
   such as `[{"item": "..."}, {"tag": "..."}]`. The converter flattens each list to the union
   of its concrete items, after which it is indistinguishable from a tag and takes the
   identical selection rule. The planner has one ambiguity mechanism, not two.
4. **Recurse on shortfall**, leaf-first, with a depth limit of 6 and a cycle guard on the set
   of outputs currently being resolved. `iron_ingot <-> iron_block` and comparable loops are
   real and otherwise recurse forever.
5. **Aggregate shortfalls rather than failing fast.** An item neither in stock nor craftable
   makes the plan impossible, but the planner returns the complete missing list so the UI
   shows everything at once rather than one item per attempt.

Output shape: ordered craft steps (leaf-first), per-identity storage withdrawals, the concrete
item chosen for each tag, and any shortfalls.

**Ingredients only ever match the NBT-free identity.** A recipe JSON names a plain item ID,
while the index keys on name plus NBT hash. Restricting ingredient matching to the variant
with no NBT means an enchanted or damaged item is never silently consumed.

## Craft execution -- `app/craft_service.lua`

A fourth entry in the existing `automationCursor` rotation in `app/coordinator.lua`, alongside
recovery, imports, and requests. This preserves the invariant that exactly one work loop can
advance automation, and guarantees a craft's transfers never overlap an import or a retrieval.

### Item movement reuses existing pipelines

**Storage -> Buffer (ingredient staging) goes through `app/requests.lua`.** A craft-owned
ingredient withdrawal is an ordinary Request whose destination is the buffer instead of
Pickup. This keeps a single storage-withdrawal path: same lifecycle states, same journal, same
reconciliation, same retry and cancel, and the withdrawals appear on the Requests page instead
of being invisible activity. A second direct-to-`executeMultiBatch` path would be free to
drift from the real one.

Three consequences follow, all accepted:

- **Cancelling a craft job cancels its outstanding craft-owned Request**, and cancelling that
  Request directly from the Requests page blocks the owning job. The two must not disagree.
- **Craft-owned Requests are exactly as non-durable as operator Requests** -- both live in
  memory. A controller restart drops both, so an abandoned job leaves no orphan request
  behind, and any transfer that was genuinely in flight is covered by the existing journal.
- **A craft's ingredient withdrawal queues behind older operator requests**, because
  `Requests:_next()` walks creation order. A craft can therefore wait on a large retrieval.
  That is the correct trade for a single serialization point, but it is a real property, not
  an oversight.

**Buffer -> Storage (purge and leftovers only) stays craft-service-owned.** `ImportService` is
hard-bound to `context.dropoff` and *continuously* discovers and drains it. Pointing a
continuous drainer at the buffer would make it fight staging for the same items. This
direction uses the same `planner.planImport` plus `transfer:executeMultiBatch` with
`kind = "import"` -- the same core machinery, a different service.

**Buffer -> Pickup (final delivery) is a plain unjournalled push.** This is the default and
overwhelmingly common destination for a finished craft: the operator asked for the item, so it
goes where they collect it. No storage total moves on this hop, so there is nothing for
reconciliation to protect. The buffer is a registered, scanned node, so an interrupted push
leaves items the controller can still see and re-derive on the next scan.

Delivery to storage instead is available as a per-job toggle, and takes the journalled
`kind = "import"` path above rather than this one.

### Operation kinds

No new transfer operation kind is introduced, so `core/transfer.lua` and
`core/reconciliation.lua` are untouched, as the earlier spec requires. `transfer.lua` allows
only `kind == "request"` and `kind == "import"`, and each craft movement maps onto one:

| movement | kind | reconciliation direction |
|---|---|---|
| Storage -> Buffer | `request` | storage decreases -- correct |
| Buffer -> Storage | `import` | storage increases -- correct |
| Buffer -> Pickup | none | no storage delta exists |

`planner.planImport` never required its source to be Drop-off; it takes a source slot
descriptor. Sourcing it from the buffer needs no change beyond obtaining `max_count` for the
buffer slot via `getItemDetail`.

### Grid placement by observation, not control

`kind == "request"` deliberately skips destination preflight and passes `destinationSlot =
nil`, so a request-shaped move cannot target an exact buffer slot. It does not need to.

`suckDown` always takes from the buffer's lowest occupied slot, so the turtle's suck order is
*forced*. The controller does not need to control the buffer layout -- only to know it. After
staging, the buffer is rescanned through the normal scan path, the controller reads the actual
slot layout, and emits the turtle's step list already in that order.

This is what makes the turtle thin and makes leftover intermediates in low slots harmless.

### Job queue

Jobs queue, and **exactly one runs at a time**. This is not a throttling policy that could be
relaxed later -- it is forced by the hardware. There is one buffer chest and one turtle, so two
concurrent jobs would interleave their ingredients in the same inventory and break the
buffer-exactness invariant directly. Concurrency here would not be faster, it would be wrong.

The queue mirrors `app/requests.lua`, which already solves this shape:

- An ordered list plus an `byId` map. `_next()` returns the oldest non-terminal job, and only
  that job advances on a tick. Every other job sits in `QUEUED` and is not planned, not
  staged, and consumes nothing.
- Terminal jobs are pruned against a cap, as `Requests:_prune()` does. Without it the list
  grows forever and every redraw pays to deep-copy it.
- Planning is deliberately deferred to the moment a job becomes active, never at enqueue time.
  A job queued behind two others must plan against the stock that exists when its turn comes,
  not the stock at the time it was submitted -- the jobs ahead of it will have consumed
  materials it was counting on.

**Deferred planning has a consequence that must not be papered over.** The operator confirmed a
specific plan on the `craft_plan` screen, but by the time a queued job activates, the re-plan
may legitimately differ: a different tag member is now the most-stocked, or sub-crafts are
needed that were not needed before. Silently running the new plan would break the "nothing
moves until this screen is confirmed" guarantee, which is the whole point of that screen.

So: if the activation re-plan differs *materially* from the confirmed one -- a different
concrete item chosen for any tag, or any sub-craft added -- the job blocks and asks for
re-confirmation rather than proceeding. A plan that differs only in which storage slots the
same items come from is not material and proceeds silently.

**A job must leave the buffer empty before the next one starts.** Leftovers and byproducts go
back to storage as the final act of a job, not lazily at the start of the next one, so every
job begins from a known-clean buffer and a failed job cannot poison its successor.

Cancellation:

- A `QUEUED` job cancels immediately -- nothing has moved.
- The active job follows `Requests:cancel` semantics: if it is mid-transfer it is marked
  `cancel_requested` and settles at the next safe boundary rather than being torn down
  mid-flight. The buffer purge still runs, so nothing is stranded.

The queue is in-memory, like the jobs in it and like operator requests. A controller restart
drops the whole queue; that follows from craft jobs being non-durable, and is the behaviour to
expect rather than a gap.

### Job state machine

The active job advances through these per craft step, leaf-first:

- **PLANNING** -- replans against current stock on every entry, behind the existing planning
  verification gate, exactly as imports and requests do. Stock changes between steps are
  picked up rather than assumed away.
- **STAGING**, in two sub-phases:
  - *purge* -- anything in the buffer not needed by this step returns to storage
    (`kind = "import"`, journalled).
  - *fill* -- the deficit is withdrawn from storage as craft-owned Requests.

  Together these establish the invariant that **at craft time the buffer holds exactly this
  step's ingredients and nothing else**. AGENTS.md requires asserting such claims rather than
  arguing them, so this is an assertion, not a comment. It is also what makes the
  observed-order scheme safe when an intermediate from the previous step already occupies a
  low buffer slot.
- **STAGED** -- force a buffer rescan, read the actual slot layout, build the turtle command
  in ascending-buffer-slot order.
- **CRAFTING** -- rednet send, then return. Later ticks poll for the reply against a timeout;
  nothing blocks. The turtle's suck, craft and drop touch no storage node, so imports and
  retrievals continue while it works. This is the only genuinely parallel part of the system.
- **COLLECTING** -- rescan, verify the expected output landed. Intermediates stay in the
  buffer for the next step, with no storage round-trip.
- **DELIVERING** -- the finished craft goes to the job's chosen destination: Pickup by default
  as an unjournalled push, or storage via `kind = "import"` if the operator toggled it on the
  plan screen. Leftover ingredients and recipe byproducts (buckets, bottles) always return to
  storage regardless of the toggle, since those are not what the operator asked for.

  On the Pickup path, Pickup can be full, and it is the one hop where that matters. Zero
  movement into Pickup blocks the job with `PICKUP_FULL` awaiting explicit operator retry,
  matching the existing retrieval semantics -- `generation` advances on every scan and is never
  evidence that Pickup drained. Until it is retried the result sits in the buffer, which is a
  scanned node, so it is visible rather than stranded.

Failure paths:

- Turtle unreachable or timed out -> job `BLOCKED` with an alert and backoff, mirroring
  `Requests:_block`. Never a hang, as the earlier spec requires.
- Turtle reports an ingredient mismatch or a failed craft -> the turtle drops everything back
  into the buffer and the job blocks. The replan on retry sees real stock.
- Zero-movement or ambiguous staging -> the Request's own blocked state, with a role-derived
  `BUFFER_FULL` in place of `PICKUP_FULL`, keeping the same deliberate no-auto-retry
  semantics.

### Restart recovery

**Craft jobs are deliberately not durable. The buffer is.** Transfers are already covered by
the existing journal. An interrupted job is abandoned and the queue behind it is dropped; on
boot, a non-empty buffer with no active job raises an alert offering to return its contents to
storage. Nothing is stranded where the controller cannot see it, which is the property the
earlier spec asks for.

A durable job store would buy very little and would cost a fifth journal-adjacent schema that
must keep validating forever.

## Turtle firmware

The turtle holds no state between jobs and ends every job empty. It knows nothing about
recipes, tags, or planning; its only item knowledge is one string comparison.

Command shape:

```lua
{op="craft", job="craft-4-17",
 steps={ {expect="minecraft:oak_planks", cells={1,2,3,5,7,9,10,11}, per_cell=1},
         {expect="minecraft:coal",       cells={6},                 per_cell=1} },
 result={name="minecraft:chest", count=1}}
```

`steps` is in ascending buffer-slot order, which is the order `suckDown` will encounter them.
`cells` are turtle inventory slots; `turtle.craft()` reads slots 1-3, 5-7 and 9-11 as the 3x3
grid. For a shapeless recipe the planner assigns cells in ascending grid order, since position
carries no meaning.

`per_cell` is the **batch multiplier**, identical across every step of a job -- it is how many
of that ingredient each of its cells holds, and therefore how many outputs the single
`turtle.craft()` call produces. Every vanilla grid cell consumes exactly one item per craft, so
`per_cell` is the batch count and nothing else. It is not a per-ingredient ratio.

Per step the turtle does: `select(cells[1])`, `suckDown(per_cell * #cells)`, verify
`getItemDetail(cells[1]).name == expect`, then `transferTo` `per_cell` items into each
remaining cell. Then `turtle.craft()`, and `dropDown()` sweeping **all 16 slots** -- the craft
result does not reliably land in a predictable slot, and byproducts such as emptied buckets
stay behind in grid cells. Then reply.

Other operations: `{op="ping"}` for liveness, and `{op="purge"}` to drop everything down into
the buffer -- also the turtle's own response to any failure.

The turtle is a second live computer. It needs its own deployment manifest and the same
shutdown-confirm, manifest-gated, hash-verified treatment as the controller, per AGENTS.md.

## UI

New page 6, Crafting, added to the `pages` table in `app/keymap.lua`.

- **`craft_search`** -- queries the *recipe* index, not the storage index. All 639 outputs are
  listed with display name, `in stock: N`, and craftability. This is the point of the page:
  crafting things you hold zero of. It is the primary way to start a craft.
- **`craft_quantity`** -- the same affordances as retrieval, with `a` meaning *max craftable
  from current stock*, computed by the planner across the whole tree including sub-crafts, not
  just from ingredients already at the top level.
- **`craft_plan`** -- the resolved plan before anything moves: the concrete item chosen for
  each tag, sub-craft steps in order, raw materials consumed, shortfalls in red. `d` toggles
  the delivery destination between Pickup (default) and Storage, `p` pins the chosen item for
  that tag into the preference store, Enter commits, F10 backs out. **Nothing moves until this
  screen is confirmed.**
- **`craft_jobs`** -- the queue in run order, newest-first for display as the Requests page
  does, with the active job marked and queued jobs showing their position. `r` retries and `c`
  cancels, matching the Requests page. Committing from `craft_plan` enqueues rather than
  starting immediately when a job is already running, and the plan screen says so instead of
  appearing to stall.

Secondary entry point: on the Search page, a request whose quantity exceeds stock shows
`Craftable -- C to plan` and jumps into `craft_plan` for the shortfall. This is a shortcut,
not the main route.

Requests page: craft-owned requests display their owning job so a burst of ingredient
withdrawals is identifiable rather than mysterious.

## Crafting monitor -- `app/craft_monitor.lua`

A separate module rather than a fourth size tier in `app/monitor.lua`, because it renders a
different model -- the active craft job -- not a smaller version of the storage model.

`monitor_0` is a 1x1 monitor: 7x5 characters at text scale 1, 15x10 at scale 0.5. The design
targets 0.5.

```
CRAFTING
Chest
 3 / 16
STEP 2/3
[####    ]
oak_planks
STAGING
+2 queued
```

The queue-depth line is omitted entirely when nothing is waiting, rather than rendering
`+0 queued`. On a 15x10 surface every line is worth something.

Idle shows the craftable-type count and `IDLE`. Blocked shows the reason in red.

### Binding both monitors

`colossal/main.lua` currently binds `peripheral.find("monitor")` and takes whichever comes
first, which is arbitrary with two monitors attached. Config gains
`monitors = {main = <name>, crafting = <name>}` and a setup step to pick each. The existing
find stays as the fallback when unbound, so an install that has not been reconfigured keeps
working.

Config schema goes 1 -> 2, adding `monitors`, `craft_buffer`, and `turtle` as first-class
bindings alongside `dropoff`, `pickup`, and `storage`. The hardware is all built and wired, so
none of these is a hypothetical optional extra and the schema does not pretend otherwise.

They remain *absent-tolerant* for one reason only, which is not the same as optional: the
controller must still boot and run storage without them, so that a fresh install can reach the
Setup wizard and an operator who has not yet bound the buffer is not locked out of retrieval.
Crafting features disable themselves when unbound; the system never refuses to start. The
schema 1 -> 2 migration fills `monitors.main` from the existing `peripheral.find` result and
leaves the crafting bindings for Setup.

## Changes to existing modules

All defaults preserve current behaviour exactly.

| module | change |
|---|---|
| `core/planner.lua` | `planRetrieval`'s `pickup` parameter becomes `destination`. It is only read for `.health` and `.peripheral_name`; a pure rename. |
| `app/requests.lua` | `create(identity, quantity, opts)` gains `opts.destination_role` and `opts.owner`. `tick` reads `context[destination_role or "pickup"]`. `PICKUP_FULL` becomes role-derived. `record_usage` is skipped for craft-owned requests, so search ranking keeps reflecting what people ask for rather than what recipes consume. |
| `app/coordinator.lua` | `_context` gains the `craft_buffer` snapshot. `_preflightNames("requests")` derives its destination from the in-flight request instead of always Pickup. `craft_service` joins the automation rotation. |
| `core/registry.lua` | `craft_buffer` becomes a fourth role in `validate`, entered into `bindings` so it cannot collide with Drop-off, Pickup, or a storage node. This matters concretely here: Pickup and the buffer are both `ironchests:diamond_chest`. |
| `colossal/main.lua` | `nodesFrom` adds the buffer node; monitor and turtle bindings; craft service wiring. |
| `app/keymap.lua`, `app/ui.lua` | Crafting page and its modes. |
| `deployment_manifest.lua` | new runtime files; a second manifest for the turtle. |
| `core/transfer.lua`, `core/reconciliation.lua` | **unchanged** |

## Known cost, and why it is accepted

A Request carries one identity, so a three-ingredient craft step becomes three requests and
therefore three gate cycles, where a single direct multi-identity batch would be one.
AGENTS.md is explicit that the gate cycle is the unit of cost, so this is worth naming.

It is accepted on live evidence, not on argument: retrievals on the real installation complete
nearly instantly, so a few extra cycles per craft step are not a meaningful cost against the
value of a single storage-withdrawal path. AGENTS.md requires performance work to be sized
against the live installation rather than assumed, and that measurement has been made.

Do not pre-optimise this into a multi-identity request line. If staging ever does become slow
-- most plausibly on a much larger recipe tree, or after the Colossal Chest grows enough to
make scans expensive -- measure it again first.

## Testing

- Converter: host tests over a fixture jar subset, covering nested-tag flattening, the
  dropped recipe types, item interning, and display-name extraction.
- Planner: pure, so the whole tree is testable -- tag choice, the reservation ledger, cycle
  guard, depth limit, shortfall aggregation, batch sizing, NBT-free ingredient matching.
- Craft service: against the existing `mock_cc` plus a fake rednet and fake turtle, covering
  unreachable, timeout, ingredient mismatch, partial craft, and restart with a non-empty
  buffer.
- Queue behaviour: only the active job advances; a queued job plans against stock as it exists
  when it becomes active rather than at enqueue time; a job leaves the buffer empty before its
  successor starts; cancelling a queued job moves nothing; terminal jobs are pruned.
- The buffer-exactness invariant is asserted in code and tested directly.
- Register every new test module in `defaultModules` in `colossal/tests/run.lua`.

Host tests must not read from or write to live Minecraft inventories.

## Build order

Four independently shippable plans:

1. **Recipe pipeline** -- converter, pack format, repo module, tag flattening, preference
   store. No in-game moving parts; fully host-testable.
2. **Craft planner** -- pure multistep resolution over the pack. No peripherals, no UI.
3. **Craft execution** -- buffer role, config and setup changes, `craft_service`, turtle
   firmware and its manifest, rednet protocol.
4. **UI and crafting monitor** -- Crafting page, Search shortfall hook, `craft_monitor.lua`,
   monitor bindings.

## Out of scope: compacting

Recorded here only so the seams stay right. Compacting is a generated recipe *source* (2x2 and
3x3 compaction recipes and their reverses) plus an auto-trigger policy, riding on parts 1-3
unchanged. That is why the repo module merges packs rather than replacing them, and why the
planner takes the repo as an injected dependency.

Note that this server already carries a `kubejs/server_scripts/vh_compressio` script, so its
compaction recipes are KubeJS-defined and will need the KubeJS dump route rather than jar
extraction.

## Constraints for whoever builds this

- Do not modify `core/transfer.lua` or `core/reconciliation.lua`. This design needs no change
  to either. If it starts to, the staging choice is wrong.
- The buffer is not a storage node and must never be added as one.
- The turtle must never touch a storage node directly. Storage totals moving for reasons the
  controller did not cause surfaces as `RECONCILE_DIRECTION` and halts automation.
- The turtle is a second live computer: its own manifest, and the same shutdown-confirm,
  hash-verified deployment gate as the controller.
- Re-verify the turtle's peripheral type list on the live system before building the staging
  path. Never hardcode its peripheral name; it has already changed once between observations.
