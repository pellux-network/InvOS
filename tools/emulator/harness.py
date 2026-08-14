"""One call to get from a repository checkout to a driveable InvOS terminal."""

import hashlib
import os
import shutil
import tempfile

import provision
import scenario as scenario_module
import session

HERE = os.path.dirname(os.path.abspath(__file__))
SMOKE_DIR = os.path.join(HERE, "smoke")
CONTROLLER_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "controller"))


def default_workdir(controller_root=None):
    """A scratch directory private to one checkout.

    ``prepare`` rmtree's this path before every run, so two checkouts sharing it
    delete each other's computer directory mid-boot -- which looks like a random
    boot failure in the code under test rather than like contention. That is not
    hypothetical: three agents working in sibling git worktrees hit it at once,
    and only ``craftos.py`` had a ``--workdir`` escape hatch, so the unittest
    suites could not isolate themselves at all. Keying the path to the checkout
    makes concurrent worktrees safe without anyone having to know to ask.
    """
    base = os.environ.get("TMPDIR") or tempfile.gettempdir()
    root = os.path.abspath(controller_root or CONTROLLER_ROOT)
    digest = hashlib.sha256(root.encode("utf-8")).hexdigest()[:8]
    return os.path.join(base, "invos-emulator-run-" + digest)


class Harness(object):
    """Installs the controller onto an emulated computer and starts it."""

    def __init__(self, controller_root=None, workdir=None, provisioner=None):
        self.controller_root = os.path.abspath(controller_root or CONTROLLER_ROOT)
        self.workdir = os.path.abspath(workdir or default_workdir(self.controller_root))
        self.provisioner = provisioner or provision.Provisioner()

    @property
    def data_dir(self):
        return os.path.join(self.workdir, "data")

    @property
    def computer_dir(self):
        return os.path.join(self.data_dir, "computer", "0")

    def prepare(self, scenario):
        """Build the computer directory for ``scenario`` and return its file list."""
        executable = self.provisioner.ensure()

        if os.path.isdir(self.workdir):
            shutil.rmtree(self.workdir)
        os.makedirs(self.computer_dir)

        installation = session.Installation(self.controller_root, self.computer_dir)
        files = installation.install(extra_files={
            "scenario.lua": scenario.to_lua(),
            "world.lua": _read(os.path.join(SMOKE_DIR, "world.lua")),
        })
        return executable, files

    def start(self, scenario=None, boot_timeout=session.DEFAULT_BOOT_TIMEOUT):
        """Prepare and start a session, returning it already running."""
        scenario = scenario or scenario_module.configured()
        executable, _files = self.prepare(scenario)

        active = session.Session(
            executable, self.data_dir,
            script=os.path.join(SMOKE_DIR, "boot.lua"),
            font_path=self.provisioner.font_path())
        active.start()
        return active


def _read(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()
