# InvOS Operations

Host-side procedures for people working on the repository: deploying a build to a live
installation, and generating the crafting recipe pack.

> **Running InvOS is documented in the [wiki](https://github.com/pellux-network/InvOS/wiki).**
> Topology, installation, the setup wizard, daily use, crafting, lifecycle states, recovery
> and upgrades all live there, and the wiki is canonical for them. This file covers only
> what happens on a development host, which the wiki deliberately does not.
>
> - Building the network: [Hardware Setup](https://github.com/pellux-network/InvOS/wiki/Hardware-Setup)
> - Installing and upgrading: [Installation](https://github.com/pellux-network/InvOS/wiki/Installation)
> - Commissioning: [First-Run Setup](https://github.com/pellux-network/InvOS/wiki/First-Run-Setup)
> - Operating it: [Daily Use](https://github.com/pellux-network/InvOS/wiki/Daily-Use), [Crafting](https://github.com/pellux-network/InvOS/wiki/Crafting)
> - Diagnosis: [Troubleshooting](https://github.com/pellux-network/InvOS/wiki/Troubleshooting), [Status and Alerts](https://github.com/pellux-network/InvOS/wiki/Status-and-Alerts), [Recovery](https://github.com/pellux-network/InvOS/wiki/Recovery)

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

The recipe pack under `controller/storage/recipes/` is generated, not hand-written, and never edited directly: the next regeneration overwrites it. It's per-deployment data derived from one modpack's own game rather than source, so it's gitignored and not listed in `deployment_manifest.lua`; `tools/deploy.py` pushes it to the live controller separately, from whatever local copy exists (see its `deploy_recipe_pack` step). A fresh clone has no pack until you generate one below, and the controller runs fine without it — crafting just reports nothing craftable until you deploy one.

Hand-written recipes belong in `storage/data/custom_recipes.lua`, which lives with the mutable data the deployment gate preserves, and which takes precedence over every generated pack. Operator tag and recipe pins live alongside it in `storage/data/craft_prefs.lua`.

To regenerate from the vanilla server jar:

```
python tools/recipe_import.py \
  --jar "<server-root>/libraries/net/minecraft/server/<version>/server-<version>.jar" \
  --out controller/storage/recipes
```

`<server-root>` below is the server directory — often a network mount, as described in
*Deploying to a live installation* — with `mods`, `libraries` and `kubejs` sitting directly
beneath it.

Expect 726 recipes across 639 outputs, written as 7 files totalling roughly 129 KB. A recipe count of 0 means the jar was opened but no recipe data was found for the namespace.

The 1.18.2 server jar is a Mojang *bundler*: opening it directly finds 104 entries and no recipes at all. The converter unwraps the real jar nested at `META-INF/versions/1.18.2/server-1.18.2.jar` automatically, and only when the outer jar genuinely lacks data for the requested namespace.

The jar is read read-only. Regenerating changes nothing on the live server, and can be done while the server is running.

Only `crafting_shaped` and `crafting_shapeless` recipes are imported, because those are the only ones a crafty turtle can perform. Smelting, blasting, smoking, campfire cooking, stonecutting and smithing are skipped, as are the `crafting_special_*` recipes, which are hardcoded in Java with no data to read.

Two flags exist for later use. `--namespace` points the converter at a mod's data (`data/<namespace>/recipes/`), and `--shards` changes how many `pack_NN.lua` files are emitted.

**Changing `--shards` needs no manifest edit.** The pack is not listed in `deployment_manifest.lua` at all — `tests/test_deployment.lua` asserts the manifest never lists it — and `tools/deploy.py` pushes whatever shard files exist locally through its own `deploy_recipe_pack` step. `recipe_repo` resolves a shard by zero-padded name (`pack_01.lua`) from the count recorded in the pack's own `index.lua`, so the pack stays self-describing. The converter prunes shard files above the new count so stale shards cannot be deployed.

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
python tools/recipe_import.py \
  --jar "<server-root>/libraries/net/minecraft/server/<version>/server-<version>.jar" \
  --kubejs "<server-root>/kubejs/exported/invos_recipes.json" \
  --mods "<server-root>/mods" \
  --out controller/storage/recipes --shards 24
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
  --jar "<server-root>/libraries/net/minecraft/server/<version>/server-<version>.jar" \
  --mods "<server-root>/mods" \
         "<server-root>/libraries/net/minecraftforge/forge/<forge-version>/forge-<forge-version>-universal.jar" \
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
- **`--shards` needs no manifest edit.** The pack is deliberately absent from
  `deployment_manifest.lua`, and `tests/test_deployment.lua` asserts it stays that way; the
  pack records its own `shard_count` in `index.lua` and `recipe_repo` resolves shards by
  zero-padded name from it. The converter prunes shards above the new count so a stale one
  cannot ship.
- **Recipe id collisions are resolved by filename order, not mod load order.** About 1,600
  ids are defined by more than one jar; the alphabetically last jar wins, which may not be
  what the game does. This affects which of several duplicate recipes is offered, not
  whether crafting works.

Verify a modded pack exactly as above — expect `14538 outputs, 0 unreachable`. That check
matters more here than for vanilla, because shard placement is exercised across sixteen
files and thousands of outputs rather than four and a few hundred.
