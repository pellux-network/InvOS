# InvOS Operations

## Physical topology

Use one advanced computer as the controller. Connect it, the Drop-off inventory, the Pickup inventory, every storage container interface, and the status monitor to one wired modem network. Right-click each wired modem so its red connection indicator is active.

Expose exactly one inventory interface per physical storage container. Multiple interfaces on the same container can make one inventory appear twice and invalidate capacity and transfer planning. The setup validator flags identical interfaces, but the operator remains responsible for confirming the physical topology.

The Drop-off and Pickup must be separate inventories and must not be pooled storage nodes. Wireless modems do not expose adjacent inventories to the peripheral network.

## Fresh install

1. Shut down the target ComputerCraft computer.
2. Confirm its numeric computer ID and label.
3. Copy only the files listed in `controller/storage/deployment_manifest.lua`, preserving paths relative to `controller/`.
4. Do not copy tests, documentation, Git files, development helpers, or any `storage/data` directory.
5. Boot the computer. Root `startup.lua` launches `/storage/main.lua` automatically.

The first boot opens the full-screen setup wizard. Setup remains read-only until the final save.

## First setup

1. Review wired inventory discovery.
2. Assign the dedicated Drop-off.
3. Assign the dedicated Pickup.
4. Add each physical storage container once. Give every node a recognizable label. Lower priority numbers receive imports first.
5. Run validation. It checks availability, required wired-inventory methods, role collisions, and suspicious duplicate storage interfaces without moving items.
6. Review and save. The installation captures the controller computer ID and starts indexing immediately; no reboot is required.

Use `5 SETUP` from the main interface to review or change configuration later. Arrow keys, Enter, Left/Right, `R` (rename, on the storage step), and F10 control the wizard; Escape is intentionally not captured because Minecraft uses it to close the computer screen.

## Normal use

Put items in Drop-off. The controller imports them into healthy storage nodes in priority order. Items already in storage are indexed automatically.

Importing is batched. Each cycle scans storage, issues every planned move, then rescans to measure what actually landed, so the cost of a cycle is mostly fixed regardless of how much it carries. Two limits bound a batch: `slot_batch_limit` caps how many Drop-off slots join one cycle, and `batch_limit` caps the total moves issued in it. Raising `slot_batch_limit` is what makes a large mixed drop-off drain quickly; it ships at 1, matching single-slot importing, and should only be raised after the multi-item path has been watched on a live controller. Every item type in a batch is still measured separately against its own before-and-after storage total, so a batch spanning many types is proven exactly as one type is.

On the controller, type any part of an item name. Results update while background scans continue. Select an item, choose an exact NBT variant when necessary, and request one, a stack, all available, or an exact number. Retrieved items arrive in Pickup. The public monitor is status-only and resizes automatically.

Once the initial index is built, a node is rescanned only for a reason: an operator or automation action requests it (a peripheral reattaching, or a planning/verification gate before a transfer), or its last scan is older than `scan_refresh_interval` (default 2 seconds, injectable), which is how the system notices a chest a player edited by hand. This is also the only way Drop-off contents are noticed at all: nothing tells the coordinator when an item physically lands there, so an idle controller only discovers a fresh deposit on the next staleness rescan, up to `scan_refresh_interval` after it happened. `READY` means the index is both complete and settled, not merely that it once was.

Digit keys `1`-`5` jump directly to Search, Nodes, Requests, Alerts, and Setup. From any of those secondary pages, `F10` always returns to Search.

Avoid manually changing storage while a transfer is verifying. The controller treats complete live storage scans as truth, measures movement by exact item-and-NBT totals across the whole configured storage pool, and waits rather than guessing when a node is unavailable or an unrelated change makes the result ambiguous.

## Crafting

Crafting is optional. It is only constructed when both a `craft_buffer` inventory and a
`turtle` are bound in config; without them the craft service does not exist and every other
behavior is unchanged.

### Topology

The crafty turtle sits behind the system with a buffer chest, both on the wired network.
The turtle needs no direct access to Drop-off or Pickup: it only ever sucks from and drops
into the buffer directly below it. Everything else moves over the network.

Bind four things in Setup: the buffer inventory, the turtle peripheral, the main monitor,
and the 1x1 crafting monitor. The turtle's peripheral name (`turtle_2`, say) is unrelated to
its computer id; the id is only the folder name on disk.

The turtle is deliberately thin. It holds no state between jobs, knows nothing about
recipes or storage, and does one string comparison per step so a staging mistake becomes a
clean refusal instead of a wrong craft. Every operation ends with it empty, so a reboot
mid-job strands nothing.

### Using it

Key `6` opens Crafting. It lists every craftable output in the pack, including items you
hold none of, which is the point: you cannot search for what you do not have. Pick an item,
enter a quantity, review the plan, and commit.

A quantity means **make that many**, not top up to that many. Asking for 250 sticks crafts
250 regardless of what is already in storage. The "up to" behavior lives on the Search
page, as an ordinary retrieval.

Results go to Pickup by default; the destination toggles to storage per job. One job runs
at a time and the rest queue, because there is one buffer and one turtle, and two jobs would
interleave ingredients in the same chest.

Ingredients are withdrawn through the ordinary request pipeline, addressed to the buffer
instead of Pickup. That is deliberate: every item movement stays inside the transfer and
reconciliation machinery that the rest of the system already proves, rather than a second
path that would have to be proved separately.

### When a job blocks

A blocked job stops and names its cause on the Crafting page; retry and cancel are bound
there. Jobs are not durable — a controller restart clears them — but nothing is stranded:
anything left in the buffer with no active job is returned to storage automatically.

The causes worth recognizing:

- `INSUFFICIENT_MATERIALS` — the plan cannot be satisfied from stock. The shortfall lists
  what is missing.
- `TURTLE_UNREACHABLE` — the turtle did not accept or did not answer. Check that it is
  running, that its modem is attached, and that it is on the same wired network.
- `INGREDIENT_MISMATCH` or `CRAFT_FAILED` — the buffer did not hold what the controller
  expected. The turtle refuses rather than crafting something else.
- `OUTPUT_MISSING` — the turtle reported success but the buffer holds no result.
- `BUFFER_NOT_EMPTY` — items were found in the buffer with no job running, left by an
  interrupted job. They are returned to storage; the alert clears itself.

One alert is not about crafting specifically. `TRANSFER_STALLED` names a service that has
claimed a transfer for over a minute without settling. No service may begin planning while
another has a transfer in flight, so a service wedged mid-transfer stops the whole
installation — imports and retrievals included — and the only other symptom is that nothing
happens. Nothing intervenes automatically: forcing a half-finished transfer from outside is
how items get lost. Restart the controller, which reconciles the journal on boot.

## Lifecycle states

- `READY`: required inventories are healthy and the initial index is complete.
- `DEGRADED`: search and status remain usable, but inventory movement waits whenever a configured storage node or required I/O inventory is unhealthy.
- `PAUSED`: scans and UI remain available, but automated movement is stopped by the operator.
- `RECOVERING`: reserved for compatibility; current recovery runs as a responsive background worker and does not globally replace the UI.
- `SETUP_REQUIRED`: configuration is absent, invalid for this computer, or not yet committed.
- `INDEXING`: the initial live inventory index is still being built.
- `ERROR`: persistence or another critical controller boundary failed. Input remains available when safe.

## Recovery

### Full inventory

Empty or expand the named Drop-off, Pickup, or storage node. The alert remains active while blocked work is preserved.

Most blocked work resumes on its own: a changed inventory generation or the expiring retry backoff returns it to planning without a restart. Two cases deliberately do not, because a move that measured zero must not be replayed from unrelated background scan generations:

- An import blocked as `SHORT_TRANSFER`, meaning storage accepted nothing.
- A request blocked as `PICKUP_FULL`, meaning Pickup accepted nothing.

Both wait for an explicit operator retry. Until retry and cancel are bound to keys, the only way to issue one is to restart the controller, which clears in-flight import and request state without touching storage.

### Offline node

Check the wired modem, cable, interface, and chunk loading. Reattaching the peripheral schedules it for an immediate targeted scan. Search remains available in `DEGRADED`, but transfers wait for every configured storage node so pooled totals cannot omit inventory.

### Ambiguous journal

After a restart, the controller reconciles an unfinished call from the saved exact identity total across the recorded storage-node scope. It never inspects remembered Pickup/Drop-off contents, trusts a compacted slot, or repeats the call. If every recorded node is healthy, recovery completes from the aggregate delta and retires the journal. If the delta is impossible or the journal cannot be proven, the normal UI remains responsive but inventory automation stays blocked behind a critical alert. Do not delete the journal or repeat the request; restore every recorded storage node and review any concurrent manual storage changes.

If the block cannot be cleared by restoring nodes, an operator can release it explicitly. Releasing retires the unprovable journal, records a warning naming the release, and lets automation continue. Only do this after comparing storage totals against expectations, because releasing abandons the attempt to prove what the interrupted call moved.

A Drop-off change noticed before any inventory call is not ambiguous, because nothing was issued. The import abandons that attempt and rediscovers whatever the Drop-off holds next tick, so taking items back out of Drop-off mid-import no longer stalls importing.

### Corrupted configuration

The staged store retains one previous validated configuration. If neither copy is valid, the controller enters setup. Recover a configuration-only floppy or reassign the inventories. Never copy a config from another controller without reviewing and committing it; installation identity is recaptured during recovery.

### Failed metadata

Names and stack sizes are enriched gradually. A failed `getItemDetail` call does not stop scanning or input. Restore the peripheral connection and allow the next enrichment pass to retry.

## Floppy backup and recovery

Backups contain only validated configuration and item aliases. They intentionally exclude program files, inventory counts, derived indexes, request history, transfer journals, and snapshots.

Insert a writable floppy in a connected disk drive and use the backup action. On a fresh installation, choose recovery in setup, review every discovered binding, run validation, and explicitly save. Recovery never enables automation automatically.

## Upgrade and rollback

1. Pause automation and wait until no transfer is in `TRANSFERRING` or `VERIFYING`.
2. Make a configuration/alias floppy backup.
3. Shut down the controller.
4. Replace only manifest-listed runtime files. Preserve that computer's `storage/data` directory in place.
5. Boot, confirm the installation identity, and verify `READY` before resuming normal use.

For rollback, restore the previous runtime files while leaving local data in place. Never move inventory snapshots or journals between computers. If data schema compatibility is uncertain, recover the configuration-only floppy through fresh setup instead.

Before any live installation, rerun the creative-world compatibility script against the target modpack and require `ALL TESTS PASSED`. Then perform a disposable-stack conservation smoke test: Drop-off + Pickup + all storage counts must equal the starting count.

## Deploying to a live installation

The live installation is a running Minecraft world with real player items in it. Every
deployment goes through `tools/deploy.py`, which is the whole gate in one command and
refuses rather than guesses at every step.

**Boot the change in the emulator first.** The host suite runs on Lua 5.4 and the computer
runs 5.2, so a green suite does not prove the code loads in game — and the emulator installs
from the same `deployment_manifest.lua` the deploy gate uses, so a module missing from the
manifest fails there instead of on the live computer:

```bash
cd tools/emulator && python3 -m unittest test_smoke
```

This is a cheap pre-flight, not a substitute for the gate below or for the host suite. See
[`emulator.md`](emulator.md).

**The controller does not need to be powered off.** Booting a ComputerCraft computer loads
its filesystem into the host's memory; nothing on disk is touched again except the
computer's own writes, and those never land outside `storage/data/` — a directory this gate
never writes to. The real hazard is racing an in-flight write to `storage/data/` (a
mid-transfer journal, an in-progress config save), which is exactly what step 3 below
catches: it refuses outright if a journal is present, and samples file mtimes across a short
window to confirm nothing else is actively changing before backing anything up.

If your target computer's files live on a network mount (sshfs and similar), point
`--computers` at it directly:

```bash
python tools/deploy.py --computers "/path/to/world/computercraft/computer" \
  --controller-id <id> --turtle-id <id>
```

Every path there is then a network round trip, so the backup and verify passes take
noticeably longer than a local deployment; that is the mount, not a hang. If the mount has
dropped, the tree simply looks absent and the script refuses at step 1 — remount rather than
retry.

`--controller-id` is required; `--turtle-id` is required unless you pass `--no-turtle` for
an installation without crafting. Backups go to `.deploy-backups/` in the repository, which
is git-ignored.

The gate runs in this order and stops at the first refusal:

1. **The target is really the live tree.** It anchors on an existing
   `<computers>/<id>/storage/data/config.lua`. A Git Bash `/g/...` path handed to Windows
   Python resolves against the drive root and silently creates `C:\g\world\...`, so
   without this a whole deployment lands in a directory nobody ever looks at.
2. **The recorded identity matches.** `computer_id` in the live `config.lua` must equal the
   id being deployed to.
3. **Nothing is in flight.** Any `journal*` file in `storage/data/` is a refusal outright;
   mtimes must then hold still across a sample window.
4. **Both trees are backed up** before a single byte is written.
5. **Only manifest-listed paths are written**, LF-only, and never anything under
   `storage/data/`.
6. **Every written file is verified**: LF-normalized SHA-256, no CR bytes, and no strays
   beside it outside the manifest and preserved data.
7. **Every deployed module parses** under `luac -p`. A green host suite does not prove a
   deployed file parses, and this has caught a real corrupted write.
8. **`storage/data/` survived** byte-for-byte against the backup taken in step 4.

Exit status is 0 only if every check passed. On any problem the live tree is in an unknown
state; restore from the printed backup path before booting.

Three traps worth knowing if you're deploying from WSL or Git Bash to a Windows-side target,
because each has caused real damage or wasted a debug cycle on a setup like that:

- `luac.exe` and a Windows Python are Windows binaries. They cannot open Git Bash `/c/...`
  or similar paths. `luac` reports "cannot open", which reads exactly like a syntax error at
  a glance — pass Windows-form paths (`C:/...`) instead.
- `storage/data/*.lua` are serialized tables, not Lua chunks. They are correctly not
  parseable, which is why the parse check covers manifest files only.
- **From WSL, `python`/`python3` off `PATH` is the Linux interpreter**, which cannot reach a
  Windows-side network mount (e.g. an sshfs-mapped drive) that doesn't auto-mount under
  `/mnt/*` the way local drives do — the tree just looks missing, not merely at the wrong
  path. Invoke the Windows Python launcher by its full path instead (typically under
  `%LOCALAPPDATA%\Programs\Python\Launcher\py.exe`, translated to its WSL-visible path) so
  the process is a genuine Windows process with native access to the drive. Run it with a
  working directory under `/mnt/c/...` (e.g. the repo root) so WSL's interop path translation
  resolves a relative script path and the `--repo` default correctly.

After booting, exercise one ordinary import and one retrieval before trusting a release.
Most defects in this system have surfaced as a service quietly not starting rather than as
an error.

## Regenerating the crafting recipe pack

The recipe pack under `controller/storage/recipes/` is generated, not hand-written. It is deployed like code and listed in `deployment_manifest.lua`. Never edit it directly: the next regeneration overwrites it.

Hand-written recipes belong in `storage/data/custom_recipes.lua`, which lives with the mutable data the deployment gate preserves, and which takes precedence over every generated pack. Operator tag and recipe pins live alongside it in `storage/data/craft_prefs.lua`.

To regenerate from the vanilla server jar:

```
python tools/recipe_import.py \
  --jar "G:/libraries/net/minecraft/server/1.18.2/server-1.18.2.jar" \
  --out controller/storage/recipes
```

Server paths below are all under the sshfs mount described in *Deploying to a live
installation*: `G:\` is the server root, so `mods`, `libraries` and `kubejs` sit directly
beneath it.

Expect 726 recipes across 639 outputs, written as 7 files totalling roughly 129 KB. A recipe count of 0 means the jar was opened but no recipe data was found for the namespace.

The 1.18.2 server jar is a Mojang *bundler*: opening it directly finds 104 entries and no recipes at all. The converter unwraps the real jar nested at `META-INF/versions/1.18.2/server-1.18.2.jar` automatically, and only when the outer jar genuinely lacks data for the requested namespace.

The jar is read read-only. Regenerating changes nothing on the live server, and can be done while the server is running.

Only `crafting_shaped` and `crafting_shapeless` recipes are imported, because those are the only ones a crafty turtle can perform. Smelting, blasting, smoking, campfire cooking, stonecutting and smithing are skipped, as are the `crafting_special_*` recipes, which are hardcoded in Java with no data to read.

Two flags exist for later use. `--namespace` points the converter at a mod's data (`data/<namespace>/recipes/`), and `--shards` changes how many `pack_NN.lua` files are emitted.

**Changing `--shards` requires editing `deployment_manifest.lua` to match.** The manifest names each shard file explicitly. The suite has two guards for this — one asserting every manifest path exists, one asserting every shard the pack declares is listed — so a mismatch fails the test run rather than a live deployment. The converter also prunes shard files above the new count so stale shards cannot be deployed.

### Verifying a regenerated pack

From `controller/`:

```
lua -e 'package.path="storage/?.lua;"..package.path; local R=require("core.recipe_repo").new({}); local o=R:outputs(); local m=0; for _,e in ipairs(o) do if #R:recipesFor(e.item)==0 then m=m+1 end end; print(#o.." outputs, "..m.." unreachable")'
```

Expect `639 outputs, 0 unreachable`. A non-zero unreachable count means the converter's shard placement and `recipe_repo`'s shard lookup disagree, which the unit tests cannot catch because they use an injected loader rather than the real files.

### Importing every modded recipe

**Export from the running game.** Two independent reasons the files on disk are not the
recipe set:

*Conditions.* Roughly 10% of modded crafting recipes are gated behind `conditions`, and the
common ones — `quark:flag`, `supplementaries:flag`, `thermal:flag`,
`sophisticatedcore:item_enabled`, `mysticalagriculture:*` — depend on each mod's config,
which only exists at runtime. Quark's chest is the clearest case: `minecraft:chest` from any
planks is gated on `forge:not(quark:flag variant_chests)` while `quark:dark_oak_chest` is
gated on the same flag being *on*. A jar scan yields both, so the controller plans
`minecraft:chest`, the turtle crafts a `quark:dark_oak_chest`, and the job blocks on
`OUTPUT_MISSING` having already consumed the materials.

*Scripts.* KubeJS scripts add and remove recipes at runtime. This pack adds 10,186 and
removes 2,409 — none of which exist in any file. Reading KubeJS's own `recipes` event is not
enough either: `forEachRecipe` walks the recipes loaded from datapacks, not the ones scripts
add, so it misses thousands of real recipes while still listing thousands that were removed.

So the export reads `MinecraftServer.getRecipeManager()`, which is the collection a crafting
table matches against. That also removes every special case: ingredients arrive already
resolved to concrete items so tags need no expansion, conditions and script edits are already
applied, and a recipe's serialiser stops mattering — `cucumber:shaped_no_mirror` and KubeJS's
own `ShapedKubeJSRecipe` need no special handling.

1. Copy `tools/kubejs/invos_export.js` into `<server>/kubejs/server_scripts/`.
2. Restart the server. The script adds, removes and modifies nothing; it fires on
   `server.load` and writes `kubejs/exported/invos_recipes.json`.
3. Convert, pairing the dump with the jars so display names come along — the recipe manager
   carries no language data:

```bash
python tools/recipe_import.py   --jar "G:/libraries/net/minecraft/server/1.18.2/server-1.18.2.jar"   --kubejs "G:/kubejs/exported/invos_recipes.json"   --mods "G:/mods"   --out controller/storage/recipes --shards 24
```

**`--jar` is not optional if you want vanilla items named.** Without it every vanilla item
renders as a raw id, because vanilla's `en_us.json` lives only in the server jar.

With `--kubejs` the dump *replaces* the jar-read recipes rather than merging with them: it
already is the complete set. Jars contribute only language data.

Measured against the live installation:

| | |
|---|---|
| recipes in the manager | 45,946 |
| of crafting type | 26,440 |
| exported | 26,087 |
| converted to the pack | 26,087 |
| distinct outputs | 22,705 |
| unreachable on load | 0 |
| pack size | 5.89 MB |

The export leaves out special recipes (map cloning, firework assembly — no fixed output) and
any whose ingredient nothing satisfies, and reports both counts. The converter additionally
refuses NBT-constrained ingredients and results: honoring them is impossible when ingredient
matching is NBT-free, and ignoring them would craft from the wrong stack. A recipe left out is
uncraftable through this system; it is never crafted wrongly.

The console line reports what it exported. If it does not appear, check
`logs/kubejs/server.txt` — script errors go there, not to `latest.log`.

Two things about KubeJS 1802's Rhino, each of which cost a server restart to learn: the Java
loader is the lowercase `java('...')` (`Java.loadClass` is KubeJS 6 syntax), and `const`/`let`
inside a function that runs more than once raises "redeclaration of var". Exceptions thrown
inside Java calls are also not reliably catchable, so the script checks for null rather than
relying on `try`/`catch`.

#### Reading jars directly

Useful for vanilla, for a pack with no KubeJS, or as a cross-check. It reads whole jars
instead of one namespace; sources may be directories or single jar files, and any number of
them. **It does not evaluate `conditions`**, so treat its output as a superset of what the
game will actually craft:

```bash
python tools/recipe_import.py \
  --jar "G:/libraries/net/minecraft/server/1.18.2/server-1.18.2.jar" \
  --mods "G:/mods" \
         "G:/libraries/net/minecraftforge/forge/1.18.2-40.3.11/forge-1.18.2-40.3.11-universal.jar" \
  --out controller/storage/recipes --shards 16
```

**The Forge universal jar is not optional.** Forge ships the `forge:*` item tags —
`forge:ingots/iron` and 192 others — from its own jar under `libraries/`, not from `mods/`.
Thousands of modded recipes refer to them. Leaving it out does not fail: 54 extra tags
silently resolve to no items and every recipe using them becomes uncraftable. The converter
warns about tags that are referenced but never defined; that list is the check.

Measured against the live 1.18.2 installation (408 jars), before conditions are accounted
for — 1,653 of these carry conditions and an unknown fraction of those are inactive:

| | |
|---|---|
| recipes read | 36,714 |
| convertible to 3x3 crafting | 16,721 |
| distinct outputs | 14,538 |
| item tags | 727 |
| distinct items | 17,708 |
| left out, with named causes | 360 |
| pack size | 3,785,761 bytes across 19 files |

The converter refuses what it cannot represent faithfully rather than approximating it, and
prints the causes. NBT-constrained ingredients and NBT-bearing results are the bulk of it:
ingredient matching in the controller is deliberately NBT-free, so honoring them is
impossible and ignoring them would craft from the wrong stack. Custom ingredient types
carrying neither an item nor a tag are the rest. A recipe left out is uncraftable through
this system; it is never crafted wrongly.

Three constraints to plan for:

- **Raise `computer_space_limit` before deploying a modded pack.** It sits in
  `world/serverconfig/computercraft-server.toml` and defaults to `1000000` (1 MB). The full
  pack is roughly 3.8 MB, so set it to at least `4000000`; `8000000` leaves headroom for
  `storage/data/` and future regeneration. The server must restart to pick it up.
  `items.lua`, `index.lua` and `tags.lua` total about 1.1 MB and are always resident;
  shards are roughly 165 KB each and load lazily, only when an output in them is queried.
- **`--shards` must match `deployment_manifest.lua`.** The manifest names each shard file
  explicitly, so a 16-shard pack needs `pack_01` through `pack_16` listed. Two suite guards
  catch a mismatch at test time rather than at deployment, and the converter prunes shards
  above the new count so a stale one cannot ship.
- **Recipe id collisions are resolved by filename order, not mod load order.** About 1,600
  ids are defined by more than one jar; the alphabetically last jar wins, which may not be
  what the game does. This affects which of several duplicate recipes is offered, not
  whether crafting works.

Verify a modded pack exactly as above — expect `14538 outputs, 0 unreachable`. That check
matters more here than for vanilla, because shard placement is exercised across sixteen
files and thousands of outputs rather than four and a few hundred.
