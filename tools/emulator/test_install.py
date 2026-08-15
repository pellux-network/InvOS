"""Emulator integration test for install.lua's fetch/verify/write flow.

Runs the real install.lua against a real CraftOS-PC computer, pointed at a
local HTTP server standing in for GitHub -- confirmed live (see
docs/superpowers/specs/2026-08-15-self-update-design.md) that CraftOS-PC's
headless --raw mode supports the http API with no special config. This
proves the whole fetch/verify/write path for real, deterministically and
without touching GitHub, rather than only the pure functions install_test.lua
already covers.
"""

import http.server
import os
import threading
import time
import unittest

import harness as harness_module
import provision
import scenario as scenario_module
import session

SKIP = os.environ.get("INVOS_SKIP_EMULATOR") == "1"

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))


def read_file(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()

FIXTURE_MANIFEST = 'local M={files={"startup.lua","storage/greeting.lua"}}\nreturn M\n'
FIXTURE_STARTUP = 'print("fixture startup")\n'
FIXTURE_GREETING = 'return "hello from the fixture"\n'
FIXTURE_VERSION = "9.9.9\n"
FIXTURE_BROKEN_LUA = "this is not valid lua ((\n"


class FixtureServer(object):
    """Serves fixture manifest/file/version content at the paths install.lua
    expects: <base>/<ref>/<prefix>/deployment_manifest.lua, etc.
    """

    def __init__(self, routes):
        self.routes = dict(routes)
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = outer.routes.get(self.path)
                if body is None:
                    self.send_response(404)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(body.encode("utf-8"))

            def log_message(self, *args):
                pass

        self.httpd = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def start(self):
        self.thread.start()
        return "http://127.0.0.1:%d" % self.port

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def run_install(routes, mode="install", ref="v9.9.9", timeout=30, harness=None):
    """Boot a computer, run install.lua against a fixture server, and return
    (harness, computer_dir) once it's done or timeout.

    Harness.prepare() seeds the *real* InvOS controller tree onto the
    computer (including a real startup.lua) -- it is not a bare computer --
    so a fresh Harness().prepare() is created unless an already-prepared one
    is passed in via `harness`. Reusing one is what lets the update-mode
    no-op test observe state a previous run left behind, since prepare()
    would otherwise wipe and reseed the directory on every call.

    "Done" has two different shapes, because install.lua's success path
    calls os.reboot(): shell.run() never returns to the wrapper script below
    on success, so the marker it writes afterward only ever appears on a
    *failure* path (fetch/parse error, no reboot). On success, the signal is
    version.txt newly appearing instead -- "newly" matters because a reused
    harness may already have one on disk from an earlier call, in which case
    only the marker (the update-mode no-op path takes no reboot either) means
    this run is actually done.
    """
    server = FixtureServer(routes)
    base_url = server.start()
    try:
        if harness is None:
            harness = harness_module.Harness()
            harness.prepare(scenario_module.Scenario(inventories=[], config=None))
        executable = harness.provisioner.ensure()
        computer_dir = harness.computer_dir

        install_source = read_file(os.path.join(REPO_ROOT, "install.lua"))
        with open(os.path.join(computer_dir, "install.lua"), "w", encoding="utf-8") as handle:
            handle.write(install_source)

        marker = os.path.join(computer_dir, "install_done.txt")
        if os.path.exists(marker):
            os.remove(marker)
        version_file = os.path.join(computer_dir, "version.txt")
        version_existed_before = os.path.exists(version_file)

        script = os.path.join(harness.workdir, "run_install.lua")
        with open(script, "w", encoding="utf-8") as handle:
            handle.write(
                'shell.run("install.lua", "%s", "%s", "%s")\n'
                'local f = fs.open("/install_done.txt", "w") f.write("done") f.close()\n'
                % (mode, ref, base_url))

        active = session.Session(executable, harness.data_dir, script=script)
        active.start()
        try:
            deadline = time.time() + timeout
            while True:
                if os.path.exists(marker):
                    break
                if not version_existed_before and os.path.exists(version_file):
                    break
                if active.process.poll() is not None:
                    break
                if time.time() > deadline:
                    break
                time.sleep(0.1)
            # A brief settle: the file just became visible on host disk, but
            # CraftOS-PC's write().close() may not be fully flushed the
            # instant os.path.exists() first sees it.
            time.sleep(0.3)
        finally:
            active.stop()
        return harness, computer_dir
    finally:
        server.stop()


def routes_for(ref, manifest=FIXTURE_MANIFEST, startup=FIXTURE_STARTUP,
               greeting=FIXTURE_GREETING, version=FIXTURE_VERSION):
    # Mirrors the real repo layout install.lua actually walks: the manifest
    # lives at controller/storage/deployment_manifest.lua, but the paths it
    # lists ("startup.lua", "storage/greeting.lua" here) are relative to
    # controller/, its grandparent -- not to the manifest's own directory.
    prefix = "controller"
    return {
        "/%s/%s/storage/deployment_manifest.lua" % (ref, prefix): manifest,
        "/%s/%s/startup.lua" % (ref, prefix): startup,
        "/%s/%s/storage/greeting.lua" % (ref, prefix): greeting,
        "/%s/version.txt" % ref: version,
    }


@unittest.skipIf(SKIP, "INVOS_SKIP_EMULATOR=1")
class InstallTests(unittest.TestCase):
    def test_a_clean_install_writes_every_manifest_file_and_version(self):
        _, computer_dir = run_install(routes_for("v9.9.9"))
        self.assertEqual(
            read_file(os.path.join(computer_dir, "storage", "greeting.lua")),
            FIXTURE_GREETING)
        self.assertEqual(
            read_file(os.path.join(computer_dir, "version.txt")),
            FIXTURE_VERSION)

    def test_a_404_on_one_file_writes_nothing(self):
        # greeting.lua is fixture-only -- never part of the real manifest
        # Harness.prepare() seeds -- so its absence is an unambiguous "install
        # wrote nothing" signal, unlike startup.lua, which always exists
        # because prepare() seeds a real one before install.lua ever runs.
        routes = routes_for("v9.9.9")
        del routes["/v9.9.9/controller/storage/greeting.lua"]
        _, computer_dir = run_install(routes)
        self.assertFalse(os.path.exists(os.path.join(computer_dir, "storage", "greeting.lua")))
        self.assertFalse(os.path.exists(os.path.join(computer_dir, "version.txt")))

    def test_a_syntactically_broken_file_writes_nothing(self):
        routes = routes_for("v9.9.9", startup=FIXTURE_BROKEN_LUA)
        _, computer_dir = run_install(routes)
        self.assertFalse(os.path.exists(os.path.join(computer_dir, "storage", "greeting.lua")))
        self.assertFalse(os.path.exists(os.path.join(computer_dir, "version.txt")))

    def test_update_mode_no_ops_when_already_current(self):
        routes = routes_for("v9.9.9")
        harness, computer_dir = run_install(routes, mode="install", ref="v9.9.9")
        self.assertEqual(
            read_file(os.path.join(computer_dir, "version.txt")),
            FIXTURE_VERSION)
        os.remove(os.path.join(computer_dir, "storage", "greeting.lua"))
        run_install(routes, mode="update", ref="v9.9.9", harness=harness)
        # update saw a matching local version and returned before fetching
        # anything, so the file removed above (which a real update would
        # have re-fetched) stays gone.
        self.assertFalse(os.path.exists(os.path.join(computer_dir, "storage", "greeting.lua")))


if __name__ == "__main__":
    unittest.main()
