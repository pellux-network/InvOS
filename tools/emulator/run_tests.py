"""Run the emulator test suite by category, instead of the whole slow thing.

`test_smoke.py` and `test_smoke_nbt.py` each boot a real CraftOS-PC emulator per
test class -- several seconds apiece -- so running everything on every change is
slow enough to avoid. Each category below boots only the emulator classes that
actually exercise the area you changed.

    python3 run_tests.py fast              # no emulator boot, always run these
    python3 run_tests.py smoke             # Search/index/theme/navigation
    python3 run_tests.py setup-wizard      # the unconfigured-computer wizard
    python3 run_tests.py nbt               # NBT variant scanning/search
    python3 run_tests.py manifest keys     # deployment manifest + key-code drift
    python3 run_tests.py emulator          # every category that boots an emulator
    python3 run_tests.py all               # everything
    python3 run_tests.py --list            # show categories and what they cover

Extra arguments (e.g. -v, -k pattern) pass straight through to unittest.
"""

import subprocess
import sys

CATEGORIES = {
    "fast": (
        ["test_rawterm", "test_scenario", "test_render", "test_session"],
        "harness/protocol unit tests -- no emulator, run these on every change",
    ),
    "smoke": (
        ["test_smoke.EmulatorSmokeTests"],
        "boots a configured install: Search, index totals, navigation, theme",
    ),
    "setup-wizard": (
        ["test_smoke.SetupWizardTests"],
        "boots an unconfigured install: discovery and the setup wizard flow",
    ),
    "manifest": (
        ["test_smoke.ManifestTests"],
        "deployment_manifest.lua completeness and the CC:Tweaked Lua version",
    ),
    "keys": (
        ["test_smoke.KeyTableTests"],
        "rawterm.KEYS pinned against the running emulator's own key codes",
    ),
    "nbt": (
        ["test_smoke_nbt.NbtVariantTests"],
        "NBT-distinct item variants surviving scan, index and search",
    ),
    "install": (
        ["test_install.InstallTests"],
        "install.lua fetch/verify/write against a local fixture server",
    ),
}

EMULATOR_CATEGORIES = ["smoke", "setup-wizard", "manifest", "keys", "nbt", "install"]


def targets_for(names):
    targets = []
    for name in names:
        if name not in CATEGORIES:
            known = ", ".join(sorted(CATEGORIES) + ["emulator", "all"])
            raise SystemExit("unknown category %r -- known categories: %s" % (name, known))
        targets.extend(CATEGORIES[name][0])
    return targets


def main(argv):
    if "--list" in argv:
        width = max(len(name) for name in CATEGORIES)
        for name in sorted(CATEGORIES):
            modules, description = CATEGORIES[name]
            print("%-*s  %s" % (width, name, description))
        print("%-*s  %s" % (width, "emulator", "every category that boots an emulator"))
        print("%-*s  %s" % (width, "all", "every category"))
        return 0

    names = [arg for arg in argv if not arg.startswith("-")]
    passthrough = [arg for arg in argv if arg.startswith("-")]
    if not names:
        raise SystemExit(__doc__)

    if "all" in names:
        names = list(CATEGORIES)
    elif "emulator" in names:
        names = [n for n in names if n != "emulator"] + EMULATOR_CATEGORIES

    # de-duplicate while keeping order, in case categories overlap
    seen = set()
    ordered = []
    for name in names:
        if name not in seen:
            seen.add(name)
            ordered.append(name)

    targets = targets_for(ordered)
    command = [sys.executable, "-m", "unittest"] + targets + passthrough
    print("+ " + " ".join(command))
    return subprocess.call(command)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
