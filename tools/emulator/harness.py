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
TURTLE_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "turtle"))
FIXTURE_PACK = os.path.join(CONTROLLER_ROOT, "storage", "tests", "fixtures", "recipes")
LOCAL_PACK = os.path.join(CONTROLLER_ROOT, "storage", "recipes")


def recipe_pack_dir(name):
    """Where the recipe pack the emulated controller plans against comes from.

    "fixture" is the committed vanilla pack the host craft tests already use:
    deterministic, present on a fresh clone, small, and agreeing with the world
    oracle's recipes. "local" is the real generated pack under storage/recipes/,
    which is gitignored per-deployment data derived from one modpack's own game
    -- useful for debugging modded scale, absent in CI.
    """
    if name in (None, "none"):
        return None
    if name == "fixture":
        return FIXTURE_PACK
    if name == "local":
        if not os.path.isdir(LOCAL_PACK):
            raise ValueError(
                "no generated recipe pack at %s; regenerate it with "
                "tools/recipe_import.py or use --pack fixture" % LOCAL_PACK)
        return LOCAL_PACK
    raise ValueError("unknown recipe pack %r; choose fixture, local or none" % (name,))


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

    def __init__(self, controller_root=None, workdir=None, provisioner=None,
                 recipe_pack="fixture"):
        self.controller_root = os.path.abspath(controller_root or CONTROLLER_ROOT)
        self.workdir = os.path.abspath(workdir or default_workdir(self.controller_root))
        self.provisioner = provisioner or provision.Provisioner()
        self.recipe_pack = recipe_pack

    @property
    def data_dir(self):
        return os.path.join(self.workdir, "data")

    @property
    def computer_dir(self):
        return os.path.join(self.data_dir, "computer", "0")

    @property
    def turtle_dir(self):
        """The crafting turtle's own computer directory: a second live computer."""
        return os.path.join(self.data_dir, "computer", "1")

    def prepare(self, scenario):
        """Build every computer directory for ``scenario`` and return its file list."""
        executable = self.provisioner.ensure()

        if os.path.isdir(self.workdir):
            shutil.rmtree(self.workdir)
        os.makedirs(self.computer_dir)

        # craft_oracle.lua goes on every computer beside world.lua: both describe
        # the emulated world rather than any one scenario, and it is pure enough
        # to be probed without standing a turtle up. world_turtle.lua actually
        # drives peripherals, so it only appears where there is a turtle to drive.
        extra = {
            "scenario.lua": scenario.to_lua(),
            "world.lua": _read(os.path.join(SMOKE_DIR, "world.lua")),
            "craft_oracle.lua": _read(os.path.join(SMOKE_DIR, "craft_oracle.lua")),
            "run_main.lua": _read(os.path.join(SMOKE_DIR, "run_main.lua")),
        }
        if getattr(scenario, "turtle", None):
            extra["world_turtle.lua"] = _read(os.path.join(SMOKE_DIR, "world_turtle.lua"))

        installation = session.Installation(self.controller_root, self.computer_dir)
        files = installation.install(extra_files=extra)

        self._install_recipe_pack()
        if getattr(scenario, "turtle", None):
            self._install_turtle(scenario)
        return executable, files

    def _install_recipe_pack(self):
        """Copy the recipe pack in beside the manifest's file set.

        The generated pack is deliberately NOT in deployment_manifest.lua: it is
        per-deployment data derived from one modpack's own game, not source, and
        tools/deploy.py pushes it separately. Installing it separately here is
        what a real deployment looks like, not a way around the manifest.
        """
        source = recipe_pack_dir(self.recipe_pack)
        if not source:
            return
        shutil.copytree(source, os.path.join(self.computer_dir, "storage", "recipes"))

    def _install_turtle(self, scenario):
        """Build computer 1 from the turtle tree's own allow-list.

        Never from the controller's: they are two live computers, and mixing the
        trees is the mistake the two manifests exist to make impossible.
        """
        installation = session.Installation(
            TURTLE_ROOT, self.turtle_dir,
            manifest_relative="deployment_manifest.lua",
            minimum_files=5)
        installation.install(extra_files={
            "turtle_api.lua": _read(os.path.join(SMOKE_DIR, "turtle_api.lua")),
            "scenario.lua": scenario.turtle_lua(),
        })

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
