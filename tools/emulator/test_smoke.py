"""Boot InvOS in a real CraftOS runtime and assert on what it draws.

These are the tests the host Lua suite cannot be: they run the controller under
ComputerCraft's own Lua 5.2 against emulated inventories, from the file list in
`storage/deployment_manifest.lua`. A module that only parses under host Lua 5.4,
or one that was never added to the manifest, fails here rather than in Minecraft.

They are slow -- each boots an emulator -- so they are kept out of the fast unit
suite and run with:

    python3 -m unittest test_smoke

Set ``INVOS_SKIP_EMULATOR=1`` to skip them where no emulator can be provisioned.
"""

import os
import time
import unittest

import harness as harness_module
import provision
import scenario as scenario_module
import session

SKIP = os.environ.get("INVOS_SKIP_EMULATOR") == "1"


def run_probe(script_name, source, output_name, timeout=60, scenario=None,
              recipe_pack="fixture"):
    """Run a Lua probe on an emulated computer and return what it wrote.

    The probes below end with ``os.shutdown()``, which stops the *computer* but
    not the CraftOS-PC *process*: in raw mode the emulator keeps serving its
    host until stdin reaches EOF, so waiting on the process alone hangs until
    the timeout. Waiting for the file the probe writes and then closing stdin is
    what makes a probe run finish -- and the exit code is still asserted, so a
    probe that crashed the emulator does not pass quietly.

    ``scenario`` defaults to a bare computer with no world, which is what a probe
    about the runtime itself wants. Pass one to get its files installed: a probe
    about a harness module needs that module on the computer. The probe replaces
    the boot script entirely either way, so nothing is started for it.
    """
    harness = harness_module.Harness(recipe_pack=recipe_pack)
    executable, _ = harness.prepare(
        scenario or scenario_module.Scenario(inventories=[], config=None))
    script = os.path.join(harness.workdir, script_name)
    with open(script, "w", encoding="utf-8") as handle:
        handle.write(source)

    output = os.path.join(harness.computer_dir, output_name)
    active = session.Session(executable, harness.data_dir, script=script)
    active.start()
    try:
        deadline = time.time() + timeout
        while not os.path.exists(output):
            if active.process.poll() is not None:
                raise AssertionError(
                    "emulator exited (code %s) before writing %s\n%s"
                    % (active.process.returncode, output_name, active.stderr))
            if time.time() > deadline:
                raise AssertionError(
                    "%s did not write %s within %.0fs\n%s"
                    % (script_name, output_name, timeout, active.stderr))
            time.sleep(0.1)
        active.process.stdin.close()
        if active.process.wait(timeout=30) != 0:
            raise AssertionError("emulator exited with code %d\n%s"
                                 % (active.process.returncode, active.stderr))
    finally:
        active.stop()

    with open(output, encoding="utf-8") as handle:
        return handle.read()


@unittest.skipIf(SKIP, "INVOS_SKIP_EMULATOR=1")
class EmulatorSmokeTests(unittest.TestCase):
    """One emulator per test class: booting costs seconds, so it is shared."""

    harness = None
    session = None

    @classmethod
    def setUpClass(cls):
        cls.harness = harness_module.Harness()
        cls.session = cls.harness.start(scenario_module.configured())
        cls.session.wait_for_text("INVOS", timeout=90)
        cls.session.settle(quiet_for=2.5, timeout=60)

    @classmethod
    def tearDownClass(cls):
        if cls.session:
            cls.session.stop()

    def setUp(self):
        # Every test starts from Search with an empty query, so a test that
        # navigates cannot change what the next one sees.
        #
        # F10 comes first because the digit shortcuts are not live in every
        # mode: app/keymap.lua hands digits to the quantity and variant boxes as
        # input rather than as navigation, so a test that left one of those open
        # would strand the next one there. F10 is CANCEL from every mode that
        # swallows digits, and is inert on Search itself.
        self.session.press("f10")
        self.session.press("one")
        self.session.press("delete")
        self.session.settle(quiet_for=0.8, timeout=15)

    def test_boots_to_the_search_page(self):
        screen = self.session.screen
        self.assertTrue(screen.contains("INVOS"), self.session.text())
        self.assertTrue(screen.contains("1 SEARCH"), self.session.text())

    def test_reports_the_installation_healthy(self):
        self.assertTrue(self.session.screen.contains("healthy"), self.session.text())

    def test_indexes_stock_across_every_storage_node(self):
        # The scenario spreads one item type over several chests, so a correct
        # total is evidence the index aggregates across nodes rather than
        # reporting whichever node was scanned last.
        self.assertTrue(self.session.screen.contains("10,882"), self.session.text())

    def test_typing_filters_the_item_list(self):
        self.session.type_text("diamond")
        self.session.settle(quiet_for=1.0, timeout=15)
        text = self.session.text()
        self.assertIn("Diamond", text)
        self.assertNotIn("Cobblestone", text)

    def test_number_keys_switch_pages(self):
        self.session.press("two")
        self.session.settle(quiet_for=1.2, timeout=15)
        self.assertTrue(self.session.screen.contains("NODE"), self.session.text())

    def test_arrow_keys_move_the_selection(self):
        first = self.session.text()
        self.session.press("down")
        self.session.settle(quiet_for=0.8, timeout=15)
        self.assertNotEqual(first, self.session.text())

    def test_the_terminal_is_the_size_a_computer_has_in_game(self):
        self.assertEqual((self.session.screen.width, self.session.screen.height),
                         (51, 19))

    def test_the_theme_palette_is_applied(self):
        # app/theme.lua repaints the palette, so a screen still showing
        # ComputerCraft's defaults would mean the theme never took effect.
        default_white = (240, 240, 240)
        self.assertNotEqual(self.session.screen.palette[0], default_white)


@unittest.skipIf(SKIP, "INVOS_SKIP_EMULATOR=1")
class ManifestTests(unittest.TestCase):
    """The manifest is the install list, so booting from it proves it complete."""

    def test_every_manifest_file_exists(self):
        harness = harness_module.Harness()
        installation = session.Installation(harness.controller_root,
                                            os.path.join(harness.workdir, "manifest-check"))
        files = installation.install()
        self.assertGreater(len(files), 30)

    def test_the_runtime_is_the_lua_version_minecraft_uses(self):
        # AGENTS.md: host Lua is 5.4 and CC:Tweaked is 5.2, so a green host suite
        # does not prove CC compatibility. This asserts the emulator really is
        # the older one, which is the whole reason these tests exist.
        written = run_probe(
            "version.lua",
            'local f = fs.open("/version.txt", "w") '
            'f.write(_VERSION) f.close() os.shutdown()\n',
            "version.txt")
        self.assertEqual(written.strip(), "Lua 5.2")


@unittest.skipIf(SKIP, "INVOS_SKIP_EMULATOR=1")
class KeyTableTests(unittest.TestCase):
    def test_key_codes_match_the_running_runtime(self):
        """rawterm.KEYS must match the emulator's own keys API.

        The raw protocol carries a single byte, so this table cannot be derived
        from CC:Tweaked's published GLFW codes. Pinning it against the runtime
        is what stops a CraftOS-PC upgrade silently remapping every keystroke.
        """
        import rawterm

        names = ["enter", "up", "down", "left", "right", "tab", "backspace",
                 "space", "one", "two", "six", "a", "q", "delete", "f10"]
        written = run_probe(
            "keys.lua",
            'local f = fs.open("/keys.txt", "w")\n'
            'for _, n in ipairs({%s}) do f.write(n .. "=" .. tostring(keys[n]) .. "\\n") end\n'
            'f.close() os.shutdown()\n'
            % ", ".join('"%s"' % name for name in names),
            "keys.txt")
        runtime = dict(line.split("=", 1) for line in written.strip().splitlines())

        for name in names:
            self.assertEqual(str(rawterm.KEYS[name]), runtime[name].strip(),
                             "rawterm.KEYS[%r] disagrees with the runtime" % name)


@unittest.skipIf(SKIP, "INVOS_SKIP_EMULATOR=1")
class SetupWizardTests(unittest.TestCase):
    """A computer with a network but no config, which is what a fresh install is.

    The wizard is how every real installation starts, and its first job is
    read-only discovery of what is on the wired network -- a step that cannot be
    exercised by host fakes at all, because there is no network to discover.
    """

    session = None

    @classmethod
    def setUpClass(cls):
        cls.harness = harness_module.Harness()
        cls.session = cls.harness.start(scenario_module.unconfigured())
        cls.session.wait_for_text("SETUP WIZARD", timeout=90)
        cls.session.settle(quiet_for=2.0, timeout=60)

    @classmethod
    def tearDownClass(cls):
        if cls.session:
            cls.session.stop()

    def test_an_unconfigured_computer_boots_into_the_wizard(self):
        self.assertTrue(self.session.screen.contains("SETUP WIZARD"),
                        self.session.text())

    def test_discovery_finds_every_inventory_on_the_network(self):
        # The scenario puts four inventories on the modem. Discovery is
        # read-only, so this also pins that the wizard reports what it found
        # without binding anything yet.
        self.assertTrue(self.session.screen.contains("4 inventories"),
                        self.session.text())

    def test_the_wizard_advances_and_offers_the_discovered_inventories(self):
        self.session.press("enter")
        self.session.wait_for_text("2 / 10", timeout=30)
        self.session.settle(quiet_for=1.0, timeout=20)
        text = self.session.text()
        self.assertIn("Drop-off", text)
        # Sizes come from the real peripherals, so a double chest reads 54 and a
        # barrel 27 -- the wizard is showing measured capacity, not a guess.
        self.assertIn("54 slots", text)
        self.assertIn("27 slots", text)


if __name__ == "__main__":
    unittest.main()
