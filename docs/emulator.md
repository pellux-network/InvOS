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

`scenario.distribute()` splits a stock list across containers by stack limit, so
a single item type larger than one chest lands in several — which is what a real
pooled store looks like, and the case that exercises cross-node aggregation.

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
| Turtles are a second computer; the crafting turtle is not emulated yet | `scenario.configured()` leaves `craft_buffer` and `turtle` unset, so crafting is reported unavailable — a supported configuration. |
| CraftOS-PC accepts `nbt` on `setItem` and never reports it back from `list` or `getItemDetail` | `smoke/world.lua` remembers seeded NBT per inventory and slot and re-attaches it, as CC:Tweaked does. **It does not follow items through `pushItems`/`pullItems`**, so a seeded variant reads back correctly only where it was placed — enough for scanning, indexing, search and planning, not for transfers. Tests that move a variant would be asserting on the harness, so they are not written. |

The rendered PNG has no Minecraft chrome: in game the terminal sits inside the
computer's GUI frame. Everything inside that frame matches.

## Tests

```bash
cd tools/emulator
python3 -m unittest test_rawterm test_scenario test_render test_session   # fast, no emulator
python3 -m unittest test_smoke test_smoke_nbt test_install                # boots the emulator, ~6-7 minutes
```

`test_smoke` and `test_smoke_nbt` boot InvOS and assert on what it draws. `test_install`
boots a fresh, unprovisioned computer against a local fixture HTTP server and asserts on
what `install.lua` fetches and writes. They
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
python3 run_tests.py manifest keys   # deployment manifest + key-code drift
python3 run_tests.py emulator        # every category that boots an emulator
python3 run_tests.py all             # everything test_smoke.py's `-m unittest` invocation covers
```

`all` finishes in about 70 seconds, so the categories are now a convenience
rather than something to agonise over — when in doubt, run everything.
`manifest` and `keys` remain the slowest relative to their size, because each
test in those two classes boots its own bare computer via `run_probe` rather
than sharing a class-level session.
Extra arguments (`-v`, `-k pattern`, ...) pass straight through to `unittest`.

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
  run_tests.py all 2>&1 | tail -30` blocks, finishes in about 70 seconds, and
  prints what matters. Backgrounding one and waiting for it to announce itself
  does not work — nothing notifies you, and it is easy to sit idle.
- **If it feels slow, measure before blaming the emulator.** These suites once
  took six to seven minutes and almost none of it was emulation. `settle()`
  waited for the screen to stop changing, but InvOS marquees any label too long
  for its column, so on most pages the screen never stops — and settle ran to
  its timeout every single time, 60s twice per capture plus 8s per keypress. A
  90-key scroll took over twenty minutes to deliver 90 keystrokes. Timing a run
  at 0, 1 and 4 keys found it in minutes; guessing did not.
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
