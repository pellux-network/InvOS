#!/usr/bin/env python3
"""Command line front end for the InvOS emulator harness.

Examples::

    python3 tools/emulator/craftos.py shot --out /tmp/search.png
    python3 tools/emulator/craftos.py shot --keys "type:vault" --keys down
    python3 tools/emulator/craftos.py text --scenario unconfigured
    python3 tools/emulator/craftos.py craft "Oak Planks" --count 4
    python3 tools/emulator/craftos.py shot --scenario crafting --window turtle
    python3 tools/emulator/craftos.py profile
    python3 tools/emulator/craftos.py doctor
"""

import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import harness as harness_module
import provision
import rawterm
import scenario as scenario_module
import session

SCENARIOS = {
    "configured": scenario_module.configured,
    "unconfigured": scenario_module.unconfigured,
    "crafting": scenario_module.crafting,
}

# The job states the Crafting page shows once a job has stopped moving.
CRAFT_TERMINAL_STATES = ("COMPLETE", "BLOCKED", "FAILED", "CANCELLED")


def build_scenario(name, profile=False):
    if name not in SCENARIOS:
        raise SystemExit("unknown scenario %r; choose from %s"
                         % (name, ", ".join(sorted(SCENARIOS))))
    built = SCENARIOS[name]()
    if profile:
        built.profile = True
    return built


def apply_steps(active, steps):
    """Apply a list of ``key``/``type:text``/``click:x,y`` steps to a session.

    Only ``wait:`` steps block on the screen reaching a state; the rest just
    need the input delivered in order, because run_session settles once after
    the whole sequence. Settling after every step instead made each keypress
    cost a full settle timeout, so driving a list 90 rows down took twenty
    minutes of almost pure waiting.
    """
    for step in steps or []:
        if step.startswith("type:"):
            active.type_text(step[5:])
        elif step.startswith("click:"):
            x, y = step[6:].split(",")
            active.click(int(x), int(y))
        elif step.startswith("wait:"):
            active.wait_for_text(step[5:])
        else:
            active.press(step)


def run_session(args, then):
    scenario = build_scenario(args.scenario, profile=getattr(args, "profile", False))
    harness = harness_module.Harness(workdir=args.workdir,
                                     recipe_pack=getattr(args, "pack", "fixture"))
    active = harness.start(scenario)
    try:
        active.wait_for(lambda screen: screen.text_dump().strip() != "",
                        timeout=args.timeout, description="the first drawn frame")
        # --timeout is the budget for *booting*, which legitimately takes tens
        # of seconds. Settling is a different question -- either the screen goes
        # quiet promptly or it is animating and never will -- so it gets its own
        # short cap rather than inheriting the boot budget and burning it whole.
        settle_cap = max(2.0, args.settle * 3)
        active.settle(quiet_for=args.settle, timeout=settle_cap)
        apply_steps(active, getattr(args, "keys", None))
        active.settle(quiet_for=args.settle, timeout=settle_cap)
        return then(active, harness)
    finally:
        active.stop()


def command_text(args):
    def show(active, _harness):
        print(active.text(window=args.window))
        return 0
    return run_session(args, show)


def command_shot(args):
    def shoot(active, harness):
        width, height = active.screenshot(args.out, scale=args.scale,
                                          font_roots=harness.provisioner.font_roots(),
                                          window=args.window)
        print("wrote %s (%dx%d)" % (args.out, width, height))
        return 0
    return run_session(args, shoot)


def command_craft(args):
    """Queue one craft through the real UI and report how it ended.

    This is the debugging tool the emulated turtle exists for: one command boots
    a crafting world, drives the Crafting page exactly as an operator would, and
    prints both screens once the job stops moving. A blocked job's reason is on
    the Crafting page, which is the thing worth seeing.
    """
    args.scenario = "crafting"

    def craft(active, harness):
        active.wait_for_text("CRAFTER", timeout=args.timeout, window="turtle")
        active.press("f10")
        active.press("six")
        active.press("delete")  # the Crafting page keeps its query across visits
        active.settle(quiet_for=args.settle, timeout=20)
        active.type_text(args.item)
        # Each step that should change the screen is confirmed before the next is
        # sent, so a query that matches nothing is reported in seconds rather
        # than looking like a slow craft for the whole job timeout.
        active.wait_for(lambda s: not s.contains("No matching recipes"), timeout=15,
                        description="the recipe list to match %r" % args.item)
        for _ in range(args.row):
            active.press("down")
        active.press("enter")
        active.wait_for(lambda s: s.contains("How many?"), timeout=15,
                        description="the quantity prompt for %r" % args.item)
        active.type_text(str(args.count))
        active.press("enter")
        active.wait_for(lambda s: s.contains("PLAN"), timeout=30,
                        description="a plan for %d x %r" % (args.count, args.item))
        if args.destination == "storage":
            active.press("d")
        plan = active.text()
        active.press("enter")   # commit; ui.lua switches to the jobs list itself

        finished = True
        try:
            active.wait_for(
                lambda s: any(state in s.text_dump() for state in CRAFT_TERMINAL_STATES),
                timeout=args.job_timeout,
                description="the craft job to reach a terminal state")
        except session.Timeout as timeout:
            finished = False
            print(timeout, file=sys.stderr)

        jobs = active.text()
        print("--- plan ---\n%s" % plan)
        print("--- jobs ---\n%s" % jobs)
        active.press("f2")      # jobs -> the recipe list, where a block's reason shows
        active.settle(quiet_for=args.settle, timeout=20)
        print("--- crafting page ---\n%s" % active.text())
        print("--- turtle ---\n%s" % active.text(window="turtle"))
        if args.shot_dir:
            os.makedirs(args.shot_dir, exist_ok=True)
            roots = harness.provisioner.font_roots()
            active.screenshot(os.path.join(args.shot_dir, "terminal.png"), font_roots=roots)
            active.screenshot(os.path.join(args.shot_dir, "turtle.png"),
                              font_roots=roots, window="turtle")
            print("wrote screenshots to %s" % args.shot_dir)
        return 0 if finished and "COMPLETE" in jobs else 1

    return run_session(args, craft)


def command_profile(args):
    args.profile = True

    def report(active, harness):
        path = os.path.join(harness.computer_dir, "profile.lua")
        if not os.path.exists(path):
            print("no profile was written; the run may not have reached a scan",
                  file=sys.stderr)
            return 1
        with open(path, "r", encoding="utf-8") as handle:
            print(handle.read())
        return 0
    return run_session(args, report)


def command_doctor(args):
    provisioner = provision.Provisioner()
    missing = provisioner.check_libraries()
    if missing:
        print(provisioner.describe_missing(missing), file=sys.stderr)
        return 1
    executable = provisioner.ensure()
    font = provisioner.font_path()
    print("emulator: %s" % executable)
    if provisioner.gui_executable != executable:
        print("gui:      %s" % provisioner.gui_executable)
    print("font:     %s" % (font or "NOT FOUND -- screenshots will fail"))
    print("keys:     %d names available" % len(rawterm.KEYS))
    return 0 if font else 1


def command_gui(args):
    """Install the scenario and open it in a real, windowed CraftOS-PC.

    Unlike every other subcommand this does not drive the terminal over the
    `--raw` protocol: it hands the prepared computer directory to the GUI
    build and leaves a human to type and click, the way one would run the
    game outside of any test. Useful for watching a scenario play out, or for
    the debugger peripheral and other tools that need a real SDL window
    (see docs/emulator.md).

    `--scenario crafting` opens **two** windows: the controller, and the crafting
    turtle that `smoke/boot.lua` creates. Both are real computers you can type
    into, so a craft can be driven by hand from the Crafting page and watched on
    the turtle's own screen as it stages, crafts and purges.
    """
    scenario = build_scenario(args.scenario)
    harness = harness_module.Harness(workdir=args.workdir,
                                     recipe_pack=getattr(args, "pack", "fixture"))
    _executable, files = harness.prepare(scenario)
    gui_executable = harness.provisioner.gui_executable
    if not os.path.exists(gui_executable):
        print("no GUI build at %s" % gui_executable, file=sys.stderr)
        return 1

    command = [gui_executable, "--directory", harness.data_dir, "--id", "0",
               "--script", os.path.join(harness_module.SMOKE_DIR, "boot.lua")]
    popen_kwargs = {"cwd": os.path.dirname(gui_executable)}
    if sys.platform == "win32":
        popen_kwargs["creationflags"] = (subprocess.DETACHED_PROCESS
                                         | subprocess.CREATE_NEW_PROCESS_GROUP)
    else:
        popen_kwargs["start_new_session"] = True
    process = subprocess.Popen(command, **popen_kwargs)

    print("Installed %d files into %s" % (len(files), harness.computer_dir))
    if getattr(scenario, "turtle", None):
        print("Installed the crafting turtle into %s" % harness.turtle_dir)
        print("Two windows will open: computer 0 is the controller, computer %d "
              "the turtle." % (scenario.turtle.get("id", 1),))
    print("Launched %s (pid %d)" % (gui_executable, process.pid))
    return 0


def main(argv=None):
    # The shared options are attached to every subcommand as well as the top
    # level, so both `craftos.py --keys down shot` and the more natural
    # `craftos.py shot --keys down` work.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--scenario", default="configured",
                        help="which world to boot (default: configured)")
    common.add_argument("--workdir", default=None,
                        help="scratch directory for the emulated computer")
    common.add_argument("--settle", type=float, default=1.5,
                        help="seconds of screen quiet before capturing")
    common.add_argument("--timeout", type=float, default=60.0)
    common.add_argument("--keys", action="append", default=[],
                        help="input step: a key name, type:TEXT, click:X,Y or wait:TEXT")
    common.add_argument("--pack", default="fixture",
                        choices=("fixture", "local", "none"),
                        help="which recipe pack the controller plans against")
    common.add_argument("--window", default="terminal",
                        help="which screen to read: terminal or turtle")

    parser = argparse.ArgumentParser(description=__doc__, parents=[common],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("text", parents=[common],
                        help="print the terminal as text")

    shot = commands.add_parser("shot", parents=[common],
                               help="render the terminal to a PNG")
    shot.add_argument("--out", default="screen.png")
    shot.add_argument("--scale", type=int, default=1)

    commands.add_parser("profile", parents=[common],
                        help="count the peripheral calls a boot makes")
    commands.add_parser("doctor", parents=[common],
                        help="check the emulator is installable and runnable")
    commands.add_parser("gui", parents=[common],
                        help="install the scenario and open it in a windowed CraftOS-PC")

    craft = commands.add_parser("craft", parents=[common],
                                help="queue one craft and report how it ended")
    craft.add_argument("item", help="a Crafting-page search query, e.g. 'Oak Planks'")
    craft.add_argument("--count", type=int, default=1)
    craft.add_argument("--row", type=int, default=0,
                       help="how many rows down the filtered list to select")
    craft.add_argument("--destination", default="pickup",
                       choices=("pickup", "storage"))
    craft.add_argument("--job-timeout", type=float, default=240.0)
    craft.add_argument("--shot-dir", default=None,
                       help="write terminal.png and turtle.png here")

    args = parser.parse_args(argv)
    handlers = {"text": command_text, "shot": command_shot,
                "profile": command_profile, "doctor": command_doctor,
                "gui": command_gui, "craft": command_craft}
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
