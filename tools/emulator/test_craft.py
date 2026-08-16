"""Crafting in the emulator: the oracle, the turtle booting, and real crafts.

The whole crafting pipeline has only ever run against host fakes and against a
live modded installation. Every crafting invariant in AGENTS.md was found on that
installation after a green host suite. These tests put the pipeline in between:
the real controller, the real turtle firmware, real rednet, and a world that can
refuse a badly staged grid.

    python3 run_tests.py craft

Set ``INVOS_SKIP_EMULATOR=1`` to skip the emulator classes where one cannot be
provisioned. OraclePackAgreementTests needs no emulator and always runs.
"""

import os
import re
import unittest

import harness as harness_module
import scenario as scenario_module
import test_smoke

SKIP = os.environ.get("INVOS_SKIP_EMULATOR") == "1"

ORACLE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "smoke", "craft_oracle.lua")


def oracle_outputs():
    """The item ids craft_oracle.lua can produce, read straight from the Lua.

    Parsed rather than executed: the alternative is a Lua interpreter on the
    host, and the outputs are written as literals there precisely so this stays a
    one-line regex.
    """
    with open(ORACLE_PATH, encoding="utf-8") as handle:
        return re.findall(r'output\s*=\s*"([^"]+)"', handle.read())


def pack_items(pack_dir):
    """Every namespaced item id a recipe pack's item table names."""
    with open(os.path.join(pack_dir, "items.lua"), encoding="utf-8") as handle:
        return set(re.findall(r'"([a-z0-9_.-]+:[a-z0-9_./-]+)"', handle.read()))


class OraclePackAgreementTests(unittest.TestCase):
    """Two independent sources of truth, held to naming the same items.

    The oracle must not be derived from the pack -- an oracle that cannot
    disagree cannot catch a planner committing to a recipe the game lacks. But an
    oracle output the pack has never heard of is simply unreachable: the Crafting
    page only offers what the pack lists, so a test using it would pass by never
    running anything.
    """

    def test_every_oracle_output_exists_in_the_fixture_pack(self):
        items = pack_items(harness_module.FIXTURE_PACK)
        outputs = oracle_outputs()
        self.assertGreaterEqual(len(outputs), 5, outputs)
        for output in outputs:
            self.assertIn(output, items, "%s is not in the fixture recipe pack" % output)

    def test_the_scenario_stock_is_named_by_the_pack_too(self):
        items = pack_items(harness_module.FIXTURE_PACK)
        for entry in scenario_module.CRAFT_STOCK:
            self.assertIn(entry["id"], items, entry["id"])


@unittest.skipIf(SKIP, "INVOS_SKIP_EMULATOR=1")
class OracleTests(unittest.TestCase):
    """The oracle's match rules, exercised in the Lua the emulator actually runs.

    Running these through a probe rather than through host Lua is not ceremony:
    host Lua is 5.4 and CC:Tweaked is 5.2, and this module is loaded by the
    emulator. One probe boot covers every assertion, so the cost is one boot.
    """

    ASSERTIONS = r'''
local Oracle = dofile("/craft_oracle.lua")
local failures = {}
local function check(name, condition)
    if not condition then failures[#failures + 1] = name end
end

local PLANK, LOG = "minecraft:oak_planks", "minecraft:oak_log"
local COAL, STICK = "minecraft:coal", "minecraft:stick"
local oracle = Oracle.new()

check("grid slots map 3x3 to a turtle", Oracle.GRID_SLOTS[1] == 1
    and Oracle.GRID_SLOTS[4] == 5 and Oracle.GRID_SLOTS[7] == 9
    and Oracle.GRID_SLOTS[9] == 11)

local sticks = oracle:match({[1] = PLANK, [4] = PLANK})
check("shaped match", sticks ~= nil and sticks.output == STICK and sticks.count == 4)

check("shaped position matters", oracle:match({[2] = PLANK, [5] = PLANK}) == nil)
check("shaped extra cell refused", oracle:match({[1] = PLANK, [4] = PLANK, [7] = PLANK}) == nil)

local planks = oracle:match({[1] = LOG})
check("shapeless match", planks ~= nil and planks.output == PLANK and planks.count == 4)
check("shapeless anywhere in the grid", oracle:match({[5] = LOG}) ~= nil)

local torch = oracle:match({[1] = COAL, [4] = STICK})
check("two-ingredient match", torch ~= nil and torch.output == "minecraft:torch")
check("two ingredients swapped is not the recipe",
    oracle:match({[1] = STICK, [4] = COAL}) == nil)

check("empty grid matches nothing", oracle:match({}) == nil)
check("unknown item matches nothing", oracle:match({[1] = "minecraft:bedrock"}) == nil)

local custom = Oracle.new({{output = "x:y", count = 2, shapeless = {"x:z"}}})
check("an override replaces the defaults", custom:match({[1] = "x:z"}) ~= nil
    and custom:match({[1] = LOG}) == nil)

local handle = fs.open("/oracle.txt", "w")
handle.write(#failures == 0 and "OK" or table.concat(failures, "\n"))
handle.close()
os.shutdown()
'''

    def test_the_oracle_matches_grids_the_way_the_world_should(self):
        # A turtle-less scenario on purpose: the oracle is pure, so standing up
        # a second computer to ask it about a grid would test everything except
        # the thing under test.
        written = test_smoke.run_probe(
            "oracle.lua", self.ASSERTIONS, "oracle.txt",
            scenario=scenario_module.configured())
        self.assertEqual(written.strip(), "OK")


if __name__ == "__main__":
    unittest.main()
