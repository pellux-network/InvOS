"""Tests for the parts of the session driver that need no emulator.

The manifest is the deployment allow-list, so the parsing and copying around it
is worth pinning down on the host: a manifest that silently installs the wrong
file set turns every emulator test downstream into a test of the wrong tree.
"""

import os
import tempfile
import unittest

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


class SessionInputTests(unittest.TestCase):
    def test_press_rejects_an_unknown_key_name(self):
        # Caught before any packet is framed, so a typo'd key name is a test
        # error rather than a silent no-op the emulator ignores.
        driver = session.Session("craftos", "/nonexistent")
        with self.assertRaises(ValueError):
            driver.press("anykey")


if __name__ == "__main__":
    unittest.main()
