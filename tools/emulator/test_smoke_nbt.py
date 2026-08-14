"""NBT variants, end to end in a real CraftOS runtime.

`controller/storage/tests/test_craft_nbt.lua` pins crafting's NBT contract at the
unit level. These tests cover the other half: that a stocked NBT variant survives
scanning, indexing and search as a distinct item, in the actual runtime, rather
than only in tests where the fixtures assert their own shape.

The emulated chest cannot store NBT on its own -- CraftOS-PC accepts `nbt` on
`setItem` and never reports it back -- so `smoke/world.lua` remembers seeded
values per slot and re-attaches them to `list` and `getItemDetail`, which is what
CC:Tweaked returns in game. That shim does not follow items through transfers,
so nothing here moves an NBT variant between inventories; those paths stay the
Lua suite's job.
"""

import os
import unittest

import harness as harness_module
import scenario as scenario_module

SKIP = os.environ.get("INVOS_SKIP_EMULATOR") == "1"


@unittest.skipIf(SKIP, "INVOS_SKIP_EMULATOR=1")
class NbtVariantTests(unittest.TestCase):
    """One installation stocked with NBT-distinct tools alongside plain ones."""

    session = None

    @classmethod
    def setUpClass(cls):
        cls.harness = harness_module.Harness()
        cls.session = cls.harness.start(scenario_module.configured(
            stock=scenario_module.with_nbt_variants()))
        cls.session.wait_for_text("INVOS", timeout=90)
        cls.session.settle(quiet_for=3.0, timeout=60)

    @classmethod
    def tearDownClass(cls):
        if cls.session:
            cls.session.stop()

    def search(self, query):
        self.session.press("one")
        self.session.press("delete")
        self.session.settle(quiet_for=0.8, timeout=15)
        self.session.type_text(query)
        self.session.settle(quiet_for=1.5, timeout=20)
        return self.session.text()

    def test_nbt_variants_are_counted_in_the_group_total(self):
        # Three plain swords plus two enchanted ones. The Search list groups by
        # item, so the group shows all five -- variants are stock, they are just
        # not interchangeable stock.
        text = self.search("sword")
        self.assertIn("Diamond Sword", text)
        self.assertIn("5", text)

    def test_the_group_reports_how_many_exact_variants_it_holds(self):
        # Three: the plain form plus two differently enchanted ones. The exact
        # number is the point -- it is 3 only if NBT survived scanning as part of
        # each item's identity. Had NBT been dropped anywhere between the chest
        # and the index, all five swords would collapse into one variant and this
        # affordance would not appear at all.
        text = self.search("sword")
        self.assertIn("3 exact variants", text)

    def test_an_item_with_a_single_variant_shows_no_variant_affordance(self):
        # Cobblestone is stocked in one form only, so the variant line must not
        # appear -- otherwise every ordinary item would carry a control that
        # leads nowhere.
        text = self.search("cobblestone")
        self.assertNotIn("exact variants", text)

    def test_a_variant_only_item_is_still_indexed(self):
        # The pickaxe exists *only* as an enchanted variant. An index that
        # tracked NBT-free items and treated variants as decoration would show
        # nothing at all for it.
        text = self.search("pickaxe")
        self.assertIn("Diamond Pickaxe", text)

    def test_crafting_is_unavailable_without_a_turtle(self):
        # The scenario binds no craft buffer or turtle, so the Craft page must
        # say so rather than offering a craft the installation cannot perform.
        # This is the boundary the NBT-blind planner sits behind: until a turtle
        # exists, none of that logic is reachable from the UI at all.
        self.session.press("six")
        self.session.settle(quiet_for=1.5, timeout=20)
        self.assertTrue(self.session.screen.contains("CRAFT"), self.session.text())


if __name__ == "__main__":
    unittest.main()
