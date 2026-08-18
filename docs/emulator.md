# Running InvOS in an emulator

InvOS normally runs on a ComputerCraft computer inside Minecraft. It also runs,
unmodified, inside [CraftOS-PC](https://www.craftos-pc.cc) — a C++ ComputerCraft
emulator. `tools/emulator/` boots the working tree on an emulated computer,
drives it with keys and clicks, and reads the screen back as text or as a PNG.

This closes a gap the host Lua suite cannot: **host Lua is 5.4, ComputerCraft is
Lua 5.2.** A green host suite does not prove CC compatibility. The emulator runs
the same Lua 5.2 the game does, against the same file list a real deployment
installs.

## Quick start

```bash
python3 tools/emulator/craftos.py doctor          # check/install the emulator
python3 tools/emulator/craftos.py text            # print the Search page
python3 tools/emulator/craftos.py shot --out /tmp/search.png
```

The first run downloads a prebuilt CraftOS-PC release — the AppImage on Linux,
the official portable zip on Windows — into a per-user cache (`~/.cache/invos-emulator/`
on Linux, `%LOCALAPPDATA%\invos-emulator\` on Windows) and extracts it. Nothing
is installed system-wide and nothing needs root or admin.

On a minimal Linux install the AppImage needs two shared libraries that are not
present by default. `doctor` reports them:

```bash
sudo apt-get install -y libpulse0 libxss1
```

## Windows: a real GUI window

Everything above runs the same on Windows, driven headlessly over CraftOS-PC's
`--raw` protocol exactly as on Linux — no display needed. For watching a
scenario play out in an actual window instead, use `gui`:

```powershell
python tools/emulator/craftos.py gui
python tools/emulator/craftos.py gui --scenario unconfigured
python tools/emulator/craftos.py gui --scenario crafting
python tools/emulator/craftos.py gui --scenario crafting --pack local
```

This installs the working tree from `storage/deployment_manifest.lua` and the
chosen scenario into a scratch computer directory, same as every other
subcommand, then launches CraftOS-PC's windowed build (`CraftOS-PC.exe`, not
the `--raw`-piped console build the harness itself drives) pointed at that
directory and detached from the launching shell. It boots straight to whatever
the scenario would show headlessly — the Search page for `configured`, the
setup wizard for `unconfigured` — except now it is a real SDL window you can
type and click into by hand, and the one case in docs/emulator.md's
"Other CraftOS-PC debugging tools" table that needs a display (the `debugger`
peripheral) works here.

`--scenario crafting` opens **two** windows, because it is two computers: the
controller, and the crafting turtle `smoke/boot.lua` creates. Both are real and
both take input, so a craft can be driven by hand from the Crafting page (key 6)
and watched on the turtle's own screen as it stages, crafts and purges. Add
`--pack local` to do it against the real generated modpack rather than the
vanilla fixture — the combination worth reaching for when a modded recipe
misbehaves and you want to watch it happen rather than read a screen dump.

`doctor` prints the GUI build's path alongside the console one when they
differ, which is only on Windows — the Linux AppImage's `AppRun` serves both
roles, opening a window itself whenever `--raw` is left off.

## Driving the terminal

`--keys` takes a repeatable step, applied in order:

| Step | Meaning |
| --- | --- |
| `down`, `enter`, `two`, `f10` | press a named key (`rawterm.KEYS`) |
| `type:vault rock` | type text as character events |
| `click:12,7` | click terminal cell x=12, y=7 (1-based, as CC reports) |
| `wait:READY` | block until the text appears on screen |

Pressing a printable key sends the `char` event a real keyboard pairs with it.
That is not cosmetic: InvOS arms a `suppress_char` when a digit selects a page,
so a driver that sent the key alone would leave it armed and silently swallow
the next character typed.

```bash
# Search for "vault", move down one row, and screenshot the result
python3 tools/emulator/craftos.py shot --keys "type:vault" --keys down --out /tmp/vault.png
```

From Python:

```python
import harness, scenario
session = harness.Harness().start(scenario.configured())
session.wait_for_text("INVOS")
session.type_text("diamond")
session.settle()
assert session.screen.contains("Vault Diamond")
session.screenshot("/tmp/diamond.png")
session.stop()
```

## Scenarios

A scenario is the whole world a run starts in: which inventories exist, what is
in them, and what `storage/data/config.lua` says.

- `scenario.unconfigured()` — a network with inventories but no config, so the
  controller boots into the setup wizard.
- `scenario.configured()` — a commissioned installation with stock spread across
  eight double chests, which boots straight to Search.
- `scenario.configured(stock=scenario.with_nbt_variants())` — the same, plus
  NBT-distinct tools: three plain diamond swords, two differently enchanted ones,
  and a pickaxe that exists *only* as a variant. Search groups them and reports
  `3 exact variants`; crafting ignores all but the plain form.

- `scenario.crafting()` — the same commissioned installation with a craft buffer
  and a crafting turtle bound, so the whole crafting pipeline runs. See
  [Crafting](#crafting) below.

`scenario.distribute()` splits a stock list across containers by stack limit, so
a single item type larger than one chest lands in several — which is what a real
pooled store looks like, and the case that exercises cross-node aggregation.

## Crafting

`scenario.crafting()` boots **two** computers. Computer 0 is the controller;
computer 1 is the crafting turtle, running `turtle/startup.lua` and
`crafter/executor.lua` unmodified, installed from `turtle/deployment_manifest.lua`
— its own allow-list, never mixed with the controller's.

```bash
python3 tools/emulator/craftos.py craft "Oak Planks" --count 4
python3 tools/emulator/craftos.py craft "Stick" --count 8 --shot-dir /tmp/craft
python3 tools/emulator/craftos.py shot --scenario crafting --window turtle --out /tmp/turtle.png
python3 tools/emulator/run_tests.py craft
```

`craft` drives the real Crafting page exactly as an operator would — key 6, type a
query, Enter, a quantity, Enter, Enter — waits for the job to stop moving, and
prints the plan, the jobs list, the Crafting page and the turtle's own screen. It
exits non-zero unless the job reached `COMPLETE`.

What is real: rednet on the `invos-craft` protocol, `TurtleLink` resolving the
turtle's ID through `peripheral.call("computer_1", "getID")`, the firmware, the
HUD, the planner, the recipe pack, and every item movement in and out of the
buffer as real `pushItems`/`pullItems` between emulated chests.

What is faked, and only this: the `turtle` API, because CraftOS-PC has no turtles;
and the recipe truth behind `turtle.craft()`, because there is no Minecraft.

**Why the turtle needs a proxy.** Peripherals do not cross computers in
CraftOS-PC. Computer 1 can talk rednet to computer 0 but cannot wrap a single one
of its chests, so `smoke/turtle_api.lua` forwards each of the seven methods the
firmware uses to `smoke/world_turtle.lua`, which owns the buffer, a chest standing
in for the turtle's sixteen slots, and a void chest that crafting consumes into
(`setItem` cannot clear a slot, so a sink is the only way to make items leave).
A round trip costs about 0.2 ms, so the RPC layer is never what a craft waits on.

A craft takes a few seconds here: about 7 seconds for a whole test including
driving the UI, and 4 seconds from committing a 256-stick two-step craft to
`COMPLETE`. That is InvOS's own pacing — the work loop's tick plus
scan-freshness gates across plan, stage, craft, collect and deliver — not
emulation overhead. If a crafting test ever takes *minutes*,
something is wrong with the test rather than with the emulator: see
"Driving this from an agent" below.

**What the world knows how to craft.** By default, everything the installed
recipe pack does. `smoke/craft_oracle.lua` loads every shard, inverts the tag
table, and indexes each recipe by its first occupied cell, so matching a staged
grid is a lookup rather than a scan. Measured on a real modpack: 26,087 recipes
indexed in about 100 ms, and every shaped recipe in the pack matches when its own
grid is replayed through it — including the 3,888 modded ones sampled by
`ModdedPackTests`.

That is a deliberate change from an earlier design where the oracle was a small
hand-written table kept independent of the pack. Independence bought one thing:
the oracle could disagree with the pack. It cost the ability to test any modded
item at all, which is where the defects actually come from. The disagreement case
is still available on demand — `scenario.crafting(recipes=[...])` takes an
explicit list, and an empty one makes the world know nothing — so nothing was
lost except it no longer being the default.

**What a green craft run does not prove.** A pack recipe the game does not
actually have is still only findable in game: the oracle believes the same file
the planner does, so it can reproduce that *symptom* on demand but cannot detect
the real case. And nothing here models server ticks.

One transport limitation worth knowing: `rednet.receive` discards messages that do
not match its protocol filter, so while the shim is waiting inside an RPC the
firmware's own loop is not reading. The controller never sends a second command
while one is in flight, so this cannot bite today — but firmware that expected
unsolicited messages mid-craft would need a different transport.

### The recipe pack

The controller plans against `storage/recipes/`, which is gitignored
per-deployment data and absent on a fresh clone. The harness installs the
committed vanilla fixture pack from `controller/storage/tests/fixtures/recipes/`
instead: deterministic, present in CI, and agreeing with the oracle's recipes.

```bash
python3 tools/emulator/craftos.py craft "Stick" --count 8 --pack local
```

`--pack local` uses the real generated pack when you need modded scale, and
errors if there is none. It works: that command has run a two-step craft to
`COMPLETE` against a pack of 22,705 outputs across 24 shards. It is worth doing
after a re-export, because it is the cheapest way to exercise the planner at real
scale — the `minecraft:planks` tag has 412 members there against the fixture's
eight, and only oak is in stock, so the craft only completes if tag-candidate
rollback picks oak. That is the shape of a defect that reached a live
installation once already.

Installing the pack outside `deployment_manifest.lua` is not a way around the
manifest — it is what a real deployment does, and why `tools/deploy.py` pushes it
separately.

## How it works

1. **Install.** The computer directory is built from the paths in
   `storage/deployment_manifest.lua`, not from a glob. The emulator therefore
   runs exactly the file set a real deployment produces, and a module missing
   from the manifest fails to boot here instead of in Minecraft.
2. **Build the world.** `smoke/boot.lua` runs before the computer's own startup.
   It creates a wired modem and the scenario's inventories through `periphemu`,
   seeds their contents, optionally writes `storage/data/config.lua`, and then
   runs the real `startup.lua`.
3. **Read the screen.** CraftOS-PC's `--raw` renderer emits one framed packet per
   terminal update containing the characters, per-cell colours and the live
   16-colour palette. `rawterm.py` decodes it; `render.py` draws it with the same
   font atlas the emulator itself uses.
4. **Send input.** Key, character and mouse packets go back on stdin.

Everything runs headless. No display server is involved, so it works over SSH
and in CI.

### Why not the emulator's own screenshot?

CraftOS-PC has `term.screenshot()`. It returns `true` and then writes nothing
and hangs when no GUI renderer is attached, which is exactly the headless case
this harness serves. The GUI renderer itself aborts under WSLg. Rendering from
the raw stream is what works, and it is drawn from the emulator's own
framebuffer and palette, so it shows what the computer shows.

## Fidelity, and its limits

What is faithful:

- **Lua 5.2**, ComputerCraft 1.112.0 — the version Minecraft runs.
- **The palette is read from the running computer**, so the colours
  `app/theme.lua` installs are the colours rendered. Drawing against
  ComputerCraft's default sixteen would show colours the program has replaced.
- **Glyphs come from the emulator's own font atlas** (`hdfont.bmp`), blitted from
  the same 16×22 cell grid at the same 12×18 glyph size.
- **Named peripherals only appear once a modem exists**, mirroring the wired
  network that puts containers on the network in game.

Where the emulator differs from Minecraft, and what the harness does:

| Difference | Handling |
| --- | --- |
| CraftOS-PC's emulated chest returns only `name` and `count` from `getItemDetail`; CC:Tweaked also returns `displayName`, `maxCount`, `tags` | `World.enrichItemDetails` adds them, so the controller's learned-metadata paths behave as they do in game rather than seeing every item permanently unnamed. Patches the emulated computer only — the controller never knows. |
| Emulated chests start empty and are filled with `setItem`, which is a CraftOS-PC extension | Confined to `smoke/world.lua`. Nothing in `controller/` may call it. |
| **`pushItems`/`pullItems` with no target slot do not fill the first available slot.** CraftOS-PC only merges into an existing matching stack, and moves *nothing* once that stack is full — even with the rest of the inventory empty. CC:Tweaked spills into the first slot that will take them | `World.fillFirstAvailableSlot` restores CC's behaviour for every caller. This is the most consequential fidelity fix here: `core/planner.lua`'s `planRetrieval` deliberately names a destination node and no slot, so without it *any* multi-stack retrieval, craft delivery or drop-off import blocks with `PICKUP_FULL` against an almost-empty Pickup. Nothing in the controller is wrong; the emulator was. |
| CraftOS-PC has no turtles at all: `periphemu.create(_, "turtle")` returns false and there is no `turtle` global | `scenario.crafting()` runs the real `turtle/` firmware on a second emulated computer over real rednet, with `turtle` injected by `smoke/turtle_api.lua` — a proxy that owns no item state and forwards every call to a world server beside the controller. `scenario.configured()` still leaves crafting unbound, which is a supported installation in its own right. |
| Nothing decides whether a staged grid forms a recipe, because there is no Minecraft | `smoke/craft_oracle.lua` answers it, by default from the same recipe pack the controller plans against — every recipe, tags and all, so any modded item that can be planned can be crafted. It re-checks the *arrangement* independently: which cell holds what, how many, and whether an item really is a member of the tag the recipe asked for. It cannot catch a pack that claims a recipe the game does not have, since it believes the same file; a scenario passing an explicit recipe list makes the world disagree on purpose, which is that failure's shape. |
| CraftOS-PC accepts `nbt` on `setItem` and never reports it back from `list` or `getItemDetail` | `smoke/world.lua` remembers seeded NBT per inventory and slot and re-attaches it, as CC:Tweaked does. **It does not follow items through `pushItems`/`pullItems`**, so a seeded variant reads back correctly only where it was placed — enough for scanning, indexing, search and planning, not for transfers. Tests that move a variant would be asserting on the harness, so they are not written. |

The rendered PNG has no Minecraft chrome: in game the terminal sits inside the
computer's GUI frame. Everything inside that frame matches.

## Tests

```bash
cd tools/emulator
python3 -m unittest test_rawterm test_scenario test_render test_session   # fast, no emulator
python3 -m unittest test_smoke test_smoke_nbt test_install test_craft     # boots the emulator
```

`test_smoke` and `test_smoke_nbt` boot InvOS and assert on what it draws. `test_install`
boots a fresh, unprovisioned computer against a local fixture HTTP server and asserts on
what `install.lua` fetches and writes. `test_craft` boots the controller *and* the crafting
turtle and crafts through them. They
are slow — most classes start an emulator, and `ManifestTests`/`KeyTableTests`
start a fresh one per test — so running the whole thing on every change is not
worth it. They skip entirely with `INVOS_SKIP_EMULATOR=1` where one cannot be
provisioned.

Two of `test_smoke`'s tests exist specifically to catch drift rather than to
test InvOS: one pins `_VERSION` to `Lua 5.2`, and one re-dumps the `keys` table
from the running emulator and compares it to `rawterm.KEYS`.

### Running by category

`run_tests.py` groups the suite by what a change is likely to touch, so a
change to one area only reboots the emulator classes that cover it:

```bash
cd tools/emulator
python3 run_tests.py --list          # show every category and what it covers
python3 run_tests.py fast            # harness/protocol unit tests, no emulator boot
python3 run_tests.py smoke           # Search, index totals, navigation, theme
python3 run_tests.py setup-wizard    # the unconfigured-computer setup wizard
python3 run_tests.py nbt             # NBT variant scanning/search
python3 run_tests.py craft           # the emulated turtle: oracle, boot, real crafts
python3 run_tests.py scan-scaling    # retrieval/import call counts at 1 and 20 storage nodes
python3 run_tests.py manifest keys   # deployment manifest + key-code drift
python3 run_tests.py emulator        # every category that boots an emulator
python3 run_tests.py all             # everything test_smoke.py's `-m unittest` invocation covers
```

`all` finishes in about four minutes -- three without a generated recipe pack,
since the modpack tests skip -- so the categories are still a convenience
rather than something to agonise over — when in doubt, run everything.
`manifest` and `keys` remain the slowest relative to their size, because each
test in those two classes boots its own bare computer via `run_probe` rather
than sharing a class-level session.
Extra arguments (`-v`, `-k pattern`, ...) pass straight through to `unittest`.

`scan-scaling` profiles complete retrieval and Drop-off transactions inside Lua 5.2 after
boot indexing has finished. Its scenario-only F8 hook resets the peripheral-call profile;
F7 then deposits an item into Drop-off with CraftOS-PC's `setItem` and requests a rescan.
Those hooks live only in the emulator harness and are never installed by either deployment
manifest. The assertions compare exact call counts at 1 and 20 storage nodes, so this test
catches node-count-dependent planning or reconciliation scans without treating host timing
as a model of server ticks.

The workdir is keyed to the checkout it runs from — `invos-emulator-run-<hash>`
under `$TMPDIR` — so separate clones and separate git worktrees no longer
collide. `Harness.prepare()` deletes its workdir before every run, so two trees
sharing one path used to delete each other's computer directory mid-boot and
present it as a random boot failure. Two `run_tests.py` invocations in the *same*
checkout still race; give one of them a different `TMPDIR`.

### Driving this from an agent

The emulator is the closest thing to the real game available from the host, so
prefer it over the host Lua suite for anything user-visible. Two things are
worth knowing before you start, both learned the hard way:

- **Run the suites in the foreground, with a timeout.** `timeout 300 python3
  run_tests.py all 2>&1 | tail -30` blocks, finishes in about four minutes, and
  prints what matters. Backgrounding one and waiting for it to announce itself
  does not work — nothing notifies you, and it is easy to sit idle.
- **If it feels slow, measure before blaming the emulator.** CraftOS-PC runs
  without CC's tick budget, so it is almost never the emulator. These suites once
  took six to seven minutes and almost none of it was emulation. `settle()`
  waited for the screen to stop changing, but InvOS marquees any label too long
  for its column, so on most pages the screen never stops — and settle ran to
  its timeout every single time, 60s twice per capture plus 8s per keypress. A
  90-key scroll took over twenty minutes to deliver 90 keystrokes. Timing a run
  at 0, 1 and 4 keys found it in minutes; guessing did not.
- **A slow run is usually a driver that stopped checking.** The crafting tests
  first took 525 seconds; 540 of those were three 180-second timeouts, because
  the Crafting page keeps its query between visits and the driver never pressed
  Delete. The second craft typed into a dirty box, matched no recipe, and its
  digits went into the query instead of the quantity prompt — so no job was ever
  created and the wait had nothing to find. **Confirm each step changed the
  screen before sending the next**, so a driver mistake is reported in seconds
  instead of being indistinguishable from slow work. Measuring first also showed
  the world RPC costs 0.18 ms a round trip, ruling out the layer that looked
  suspicious.
- **Then a slow run means a real bug, so go and find it.** Once the driver was
  honest, a 256-stick craft took its whole 300-second timeout — because it was
  wedged, not slow. Sampling the jobs list, then dumping the Requests and Alerts
  pages, located it in minutes: the turtle was dropping only the first stack of a
  two-stack output, so the controller saw a shortfall and waited forever on a
  withdrawal for planks that only existed inside the turtle. The same underlying
  divergence then failed the craft itself and destroyed items. Both were
  `pushItems` not spilling (see the fidelity table). The same craft now finishes
  in **4 seconds**. Nothing in `controller/` or `turtle/` needed changing —
  but nothing would have found it without running a craft this size.
- **Use `craftos.py` for single screens.** One `text` or `shot` capture boots
  once and returns in well under a minute, so checking a specific screen is much
  cheaper than running a whole category. Reach for the suites to prove nothing
  regressed, and for `craftos.py` to see what your change actually looks like.

A rendered screen outranks a passing host test. If the two disagree, the screen
is right — the host suite runs Lua 5.4 against a mock terminal, and the emulator
runs the Lua 5.2 the game runs against the real one.

## Counting peripheral calls

Every peripheral call yields for roughly a server tick while pure Lua between
yields is comparatively free, so the number worth tuning is the call count. In
Minecraft that can only be inferred from timings. Here it is counted exactly:

```bash
python3 tools/emulator/craftos.py profile
```

This boots with the peripheral API instrumented and prints totals per method —
`list`, `getItemDetail`, `pushItems` and so on — for the boot and first scan.

## Other CraftOS-PC debugging tools

CraftOS-PC ships debugging facilities ComputerCraft does not have. Not all are
usable headlessly:

| Tool | Usable headless | Notes |
| --- | --- | --- |
| Full Lua `debug` library | yes | CC:Tweaked restricts it; here `debug.traceback`, `debug.gethook` and friends are available inside the computer. |
| `debugger` peripheral | no | `periphemu.create("left", "debugger")` opens a GUI window with breakpoints, a call stack and a sampling profiler. Needs the SDL renderer. `setBreakpoint(file, line)` and `print(value)` are the API. |
| VS Code debug adapter | yes (needs a port) | CraftOS-PC ≥ 2.7 speaks DAP on port `12100 + computer id`. With the official CraftOS-PC extension this gives real breakpoints and variable inspection in `controller/` sources. |
| `mounter` API | yes | Mount host directories into a running computer, e.g. to expose a recipe pack without reinstalling. |
| `config` API | yes | Read and set ComputerCraft config at runtime (`config.set("maxComputerCapacity", ...)`). |
| `periphemu` | yes | Creates the emulated peripherals this harness is built on. |
| `--exec` / `--script` | yes | Run a chunk or a file before the computer's own startup. |

The debugger's GUI is the one genuinely useful tool that needs a display. On a
machine with a working SDL setup, `--gui` plus a `debugger` peripheral is worth
reaching for when a fault is hard to localise from the screen alone; under WSLg
the GUI renderer currently aborts, so the DAP adapter is the practical route.

## Boundaries

- The harness is host-side tooling under `tools/`. It is never deployed, and
  nothing under `controller/` or `turtle/` may require any part of it.
- Every run builds a fresh scratch computer directory under a temp path. The
  harness never reads or writes a live Minecraft tree, and `storage/data/` in
  the emulator is a throwaway copy.
