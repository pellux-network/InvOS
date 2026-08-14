#!/usr/bin/env python3
"""Command line front end for the InvOS emulator harness.

Examples::

    python3 tools/emulator/craftos.py shot --out /tmp/search.png
    python3 tools/emulator/craftos.py shot --keys "type:vault" --keys down
    python3 tools/emulator/craftos.py text --scenario unconfigured
    python3 tools/emulator/craftos.py profile
    python3 tools/emulator/craftos.py doctor
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import harness as harness_module
import provision
import rawterm
import scenario as scenario_module

SCENARIOS = {
    "configured": scenario_module.configured,
    "unconfigured": scenario_module.unconfigured,
}


def build_scenario(name, profile=False):
    if name not in SCENARIOS:
        raise SystemExit("unknown scenario %r; choose from %s"
                         % (name, ", ".join(sorted(SCENARIOS))))
    built = SCENARIOS[name]()
    if profile:
        built.profile = True
    return built


def apply_steps(active, steps):
    """Apply a list of ``key``/``type:text``/``click:x,y`` steps to a session."""
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
        active.settle(quiet_for=0.5, timeout=8)


def run_session(args, then):
    scenario = build_scenario(args.scenario, profile=getattr(args, "profile", False))
    harness = harness_module.Harness(workdir=args.workdir)
    active = harness.start(scenario)
    try:
        active.wait_for(lambda screen: screen.text_dump().strip() != "",
                        timeout=args.timeout, description="the first drawn frame")
        active.settle(quiet_for=args.settle, timeout=args.timeout)
        apply_steps(active, getattr(args, "keys", None))
        active.settle(quiet_for=args.settle, timeout=args.timeout)
        return then(active, harness)
    finally:
        active.stop()


def command_text(args):
    def show(active, _harness):
        print(active.text())
        return 0
    return run_session(args, show)


def command_shot(args):
    def shoot(active, harness):
        width, height = active.screenshot(args.out, scale=args.scale,
                                          font_roots=harness.provisioner.font_roots())
        print("wrote %s (%dx%d)" % (args.out, width, height))
        return 0
    return run_session(args, shoot)


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
    print("font:     %s" % (font or "NOT FOUND -- screenshots will fail"))
    print("keys:     %d names available" % len(rawterm.KEYS))
    return 0 if font else 1


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

    args = parser.parse_args(argv)
    handlers = {"text": command_text, "shot": command_shot,
                "profile": command_profile, "doctor": command_doctor}
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
