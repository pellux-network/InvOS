"""Exact peripheral-call regression for operation-scoped storage scans."""

import os
import re
import time
import unittest

import harness as harness_module
import scenario as scenario_module


SKIP = os.environ.get("INVOS_SKIP_EMULATOR") == "1"


def read_profile(path):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as handle:
        value = handle.read()
    result = {key: int(count) for key, count in
              re.findall(r"([A-Za-z][A-Za-z0-9_]*)=(\d+)", value)}
    return result if "total" in result else None


def wait_for_profile(path, predicate, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        profile = read_profile(path)
        if profile is not None and predicate(profile):
            return profile
        time.sleep(0.05)
    raise AssertionError("profile did not reach the expected state: %r" % read_profile(path))


@unittest.skipIf(SKIP, "INVOS_SKIP_EMULATOR=1")
class ScanScalingTests(unittest.TestCase):
    def profile_retrieval(self, storage_count):
        scenario = scenario_module.configured(
            stock=[{"id": "minecraft:stone", "count": 64}],
            storage_count=storage_count)
        scenario.profile = True
        scenario.environment = {"scan_refresh_interval": 1000000000}
        harness = harness_module.Harness(recipe_pack="none")
        active = harness.start(scenario)
        profile_path = os.path.join(harness.computer_dir, "profile.lua")
        try:
            active.wait_for_text("healthy", timeout=90)
            active.settle(quiet_for=1.0, timeout=15)

            active.press("f8")
            wait_for_profile(profile_path,
                             lambda profile: profile.get("total") == 0)

            active.press("one")
            active.press("delete")
            active.type_text("stone")
            active.wait_for_text("Stone", timeout=15)
            active.press("enter")
            active.wait_for_text("Retrieve", timeout=15)
            active.type_text("1")
            active.press("enter")
            active.press("three")
            active.wait_for_text("1 / 1", timeout=60)
            return wait_for_profile(profile_path,
                lambda profile: profile.get("pushItems") == 1 and
                    profile.get("size", 0) >= 3 and profile.get("list", 0) >= 3)
        finally:
            active.stop()

    def test_retrieval_call_count_is_independent_of_storage_node_count(self):
        for storage_count in (1, 20):
            with self.subTest(storage_count=storage_count):
                profile = self.profile_retrieval(storage_count)
                self.assertEqual(profile.get("pushItems"), 1)
                self.assertEqual(profile.get("size"), 3)
                self.assertEqual(profile.get("list"), 3)


if __name__ == "__main__":
    unittest.main()
