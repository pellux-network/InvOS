"""One call to get from a repository checkout to a driveable InvOS terminal."""

import os
import shutil

import provision
import scenario as scenario_module
import session

HERE = os.path.dirname(os.path.abspath(__file__))
SMOKE_DIR = os.path.join(HERE, "smoke")
CONTROLLER_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "controller"))


def default_workdir():
    return os.path.join(os.environ.get("TMPDIR", "/tmp"), "invos-emulator-run")


class Harness(object):
    """Installs the controller onto an emulated computer and starts it."""

    def __init__(self, controller_root=None, workdir=None, provisioner=None):
        self.controller_root = os.path.abspath(controller_root or CONTROLLER_ROOT)
        self.workdir = os.path.abspath(workdir or default_workdir())
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
