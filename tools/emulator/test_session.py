"""Tests for the parts of the session driver that need no emulator.

The manifest is the deployment allow-list, so the parsing and copying around it
is worth pinning down on the host: a manifest that silently installs the wrong
file set turns every emulator test downstream into a test of the wrong tree.
"""

import os
import tempfile
import time
import unittest

import harness
import rawterm
import session


def write(path, contents=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(contents)
    return path


def manifest_source(paths):
    """A Lua chunk shaped like the repository's real deployment manifest."""
    entries = "\n".join('    "%s",' % p for p in paths)
    return "return {\n  files = {\n%s\n  },\n}\n" % entries


class ManifestParsingTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)

    def test_parses_quoted_lua_paths(self):
        names = ["app/mod%02d.lua" % i for i in range(12)]
        path = write(os.path.join(self.tempdir.name, "manifest.lua"),
                     manifest_source(names))
        self.assertEqual(session.manifest_files(path), names)

    def test_ignores_quoted_strings_that_are_not_lua_files(self):
        names = ["app/mod%02d.lua" % i for i in range(12)]
        source = 'local version = "1.4.0"\n' + manifest_source(names)
        path = write(os.path.join(self.tempdir.name, "manifest.lua"), source)
        self.assertEqual(session.manifest_files(path), names)

    def test_raises_when_too_few_entries_are_parsed(self):
        # The count guard exists so that a change to the manifest's format
        # fails loudly here instead of quietly installing a partial tree.
        path = write(os.path.join(self.tempdir.name, "manifest.lua"),
                     manifest_source(["app/only.lua", "app/two.lua"]))
        with self.assertRaises(session.EmulatorError):
            session.manifest_files(path)


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.controller = os.path.join(self.tempdir.name, "controller")
        self.computer = os.path.join(self.tempdir.name, "computer")
        self.names = ["startup.lua"] + ["app/mod%02d.lua" % i for i in range(11)]

    def _build_tree(self, create=None):
        for name in (self.names if create is None else create):
            write(os.path.join(self.controller, name), "-- %s\n" % name)
        write(os.path.join(self.controller, "storage", "deployment_manifest.lua"),
              manifest_source(self.names))

    def test_installs_exactly_the_manifest_listed_files(self):
        # A glob would drag in scratch files and stale modules; the point of
        # booting from the manifest is that the emulator runs the same file set
        # a real deployment would produce.
        self._build_tree()
        write(os.path.join(self.controller, "app", "not_in_manifest.lua"), "-- no")
        installed = session.Installation(self.controller, self.computer).install()

        self.assertEqual(sorted(installed), sorted(self.names))
        for name in self.names:
            self.assertTrue(os.path.isfile(os.path.join(self.computer, name)), name)
        self.assertFalse(
            os.path.exists(os.path.join(self.computer, "app", "not_in_manifest.lua")))

    def test_creates_the_storage_data_directory(self):
        # The controller expects storage/data/ to exist before it writes config.
        self._build_tree()
        session.Installation(self.controller, self.computer).install()
        self.assertTrue(os.path.isdir(os.path.join(self.computer, "storage", "data")))

    def test_writes_extra_files_into_nested_directories(self):
        self._build_tree()
        session.Installation(self.controller, self.computer).install(
            extra_files={"storage/data/config.lua": "return {configured=true}"})
        with open(os.path.join(self.computer, "storage", "data", "config.lua"),
                  encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "return {configured=true}")

    def test_replaces_a_previous_installation(self):
        self._build_tree()
        stale = write(os.path.join(self.computer, "app", "stale.lua"), "-- old")
        session.Installation(self.controller, self.computer).install()
        self.assertFalse(os.path.exists(stale))

    def test_raises_listing_the_files_the_manifest_names_but_the_tree_lacks(self):
        # The manifest is the allow-list, so a name in it with no file behind it
        # is a broken deployment, not something to skip past.
        self._build_tree(create=self.names[:-2])
        with self.assertRaises(session.EmulatorError) as caught:
            session.Installation(self.controller, self.computer).install()
        message = str(caught.exception)
        for missing in self.names[-2:]:
            self.assertIn(missing, message)


class WorkdirIsolationTests(unittest.TestCase):
    # Harness.prepare() rmtree's its workdir before every run, so two checkouts
    # sharing one path delete each other's computer directory mid-boot. That
    # presents as a random boot failure in the code under test, which is a long
    # way from the real cause -- hence a test rather than a convention.
    def test_two_checkouts_get_different_workdirs(self):
        first = harness.default_workdir("/repo/one/controller")
        second = harness.default_workdir("/repo/two/controller")
        self.assertNotEqual(first, second)

    def test_the_same_checkout_is_stable_across_calls(self):
        # Stable, because a run that cannot find the directory the previous call
        # created would reinstall the tree on every single command.
        self.assertEqual(harness.default_workdir("/repo/one/controller"),
                         harness.default_workdir("/repo/one/controller"))

    def test_a_relative_path_matches_its_absolute_form(self):
        # The suites are run from tools/emulator/ and the CLI from the repo root,
        # so the same checkout reaches this by two different spellings.
        absolute = os.path.abspath("controller")
        self.assertEqual(harness.default_workdir("controller"),
                         harness.default_workdir(absolute))

    def test_the_harness_defaults_to_its_own_controller_root(self):
        driver = harness.Harness(controller_root="/repo/one/controller",
                                 provisioner=object())
        self.assertEqual(driver.workdir,
                         os.path.abspath(harness.default_workdir("/repo/one/controller")))


class SessionInputTests(unittest.TestCase):
    def test_press_rejects_an_unknown_key_name(self):
        # Caught before any packet is framed, so a typo'd key name is a test
        # error rather than a silent no-op the emulator ignores.
        driver = session.Session("craftos", "/nonexistent")
        with self.assertRaises(ValueError):
            driver.press("anykey")


def terminal_payload(line, window=0):
    """A one-row terminal-contents payload showing ``line``."""
    return rawterm.encode_terminal_contents(window, line)


def queue_frames(driver, lines, window=0):
    for line in lines:
        driver._queue.put(rawterm.Packet(rawterm.PACKET_TERMINAL_CONTENTS, window,
                                         terminal_payload(line, window)))


class WindowRoutingTests(unittest.TestCase):
    """A second computer's terminal arrives as another raw-protocol window.

    Windows are numbered in creation order -- a probe with a monitor present put
    the monitor on 1 and the turtle on 2 -- so the turtle is found as the lowest
    non-zero window that has drawn, never as a hardcoded number.
    """

    def driver(self):
        return session.Session("craftos", "/nonexistent")

    def test_window_zero_is_still_the_default_screen(self):
        driver = self.driver()
        queue_frames(driver, ["CONTROLLER"])
        driver.pump(timeout=0.05)
        self.assertIn("CONTROLLER", driver.screen.text_dump())

    def test_other_windows_no_longer_overwrite_window_zero(self):
        driver = self.driver()
        queue_frames(driver, ["CONTROLLER"])
        driver.pump(timeout=0.05)
        queue_frames(driver, ["CRAFTER"], window=1)
        driver.pump(timeout=0.05, window=1)
        self.assertIn("CONTROLLER", driver.screen.text_dump())
        self.assertIn("CRAFTER", driver.screens[1].text_dump())

    def test_the_turtle_window_is_the_lowest_non_zero_one(self):
        driver = self.driver()
        queue_frames(driver, ["CONTROLLER"])
        queue_frames(driver, ["CRAFTER"], window=2)
        driver.pump(timeout=0.05)
        self.assertEqual(driver.turtle_window, 2)

    def test_the_turtle_window_falls_back_to_one_before_any_frame(self):
        self.assertEqual(self.driver().turtle_window, 1)

    def test_resolve_window_accepts_names(self):
        driver = self.driver()
        self.assertEqual(driver.resolve_window(None), 0)
        self.assertEqual(driver.resolve_window("terminal"), 0)
        self.assertEqual(driver.resolve_window("turtle"), 1)
        self.assertEqual(driver.resolve_window(3), 3)

    def test_pump_reports_change_only_for_the_window_asked_about(self):
        driver = self.driver()
        queue_frames(driver, ["CRAFTER"], window=1)
        self.assertFalse(driver.pump(timeout=0.05, window=0))
        queue_frames(driver, ["CRAFTER 2"], window=1)
        self.assertTrue(driver.pump(timeout=0.05, window=1))

    def test_text_reads_the_window_it_is_given(self):
        driver = self.driver()
        queue_frames(driver, ["CONTROLLER"])
        queue_frames(driver, ["CRAFTER"], window=1)
        driver.pump(timeout=0.05)
        driver.pump(timeout=0.05, window=1)
        self.assertIn("CONTROLLER", driver.text())
        self.assertIn("CRAFTER", driver.text(window="turtle"))
        self.assertEqual(driver.text(window=9), "")


class SettleTests(unittest.TestCase):
    """Why settle() is not simply "wait for no packets".

    Both behaviours here were measured against the real emulator: CraftOS-PC
    resends an unchanged terminal several times a second, and InvOS marquees
    long labels forever. Between them, the original settle() could never return
    early on any page, so it always ran to its timeout -- 60s per capture and 8s
    per keypress, which is where a 90-key scroll spent twenty minutes.
    """

    def driver(self):
        return session.Session("craftos", "/nonexistent")

    def test_resending_an_identical_frame_is_not_an_update(self):
        driver = self.driver()
        queue_frames(driver, ["HELLO"])
        self.assertTrue(driver.pump(timeout=0.05), "first frame should count")
        queue_frames(driver, ["HELLO", "HELLO"])
        self.assertFalse(driver.pump(timeout=0.05),
                         "an unchanged repaint must not read as an update")

    def test_a_changed_frame_is_an_update(self):
        driver = self.driver()
        queue_frames(driver, ["HELLO"])
        driver.pump(timeout=0.05)
        queue_frames(driver, ["WORLD"])
        self.assertTrue(driver.pump(timeout=0.05))

    def test_settle_returns_once_a_static_screen_stops_repainting(self):
        driver = self.driver()
        queue_frames(driver, ["HELLO", "HELLO"])
        started = time.time()
        driver.settle(quiet_for=0.05, timeout=5.0)
        self.assertLess(time.time() - started, 2.0,
                        "settle waited out its timeout on a static screen")

    def test_settle_returns_on_an_animation_rather_than_waiting_it_out(self):
        # A marquee cycles, so frames recur. Without cycle detection this queue
        # never goes quiet and settle burns the whole timeout.
        driver = self.driver()
        queue_frames(driver, ["ABC", "BCA", "CAB"] * 40)
        started = time.time()
        driver.settle(quiet_for=0.05, timeout=5.0)
        self.assertLess(time.time() - started, 2.0,
                        "settle waited out its timeout on a cycling screen")


if __name__ == "__main__":
    unittest.main()
