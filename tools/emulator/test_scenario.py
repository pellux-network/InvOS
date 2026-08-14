"""Tests for scenario construction and Lua serialisation."""

import unittest

import scenario


class LuaSerialisationTests(unittest.TestCase):
    def test_serialises_scalars(self):
        self.assertEqual(scenario.lua_value(None), "nil")
        self.assertEqual(scenario.lua_value(True), "true")
        self.assertEqual(scenario.lua_value(12), "12")

    def test_quotes_and_escapes_strings(self):
        self.assertEqual(scenario.lua_value('a "b"'), '"a \\"b\\""')

    def test_serialises_a_list_as_a_lua_array(self):
        self.assertEqual(scenario.lua_value([]), "{}")
        self.assertIn('"x"', scenario.lua_value(["x"]))

    def test_keys_that_are_not_identifiers_are_bracketed(self):
        rendered = scenario.lua_value({"minecraft:chest": 1})
        self.assertIn('["minecraft:chest"]', rendered)

    def test_rejects_types_it_cannot_represent(self):
        with self.assertRaises(TypeError):
            scenario.lua_value(object())


class DistributionTests(unittest.TestCase):
    def test_conserves_every_item(self):
        # Conservation of items is the property this repository cares most about,
        # so the fixture builder is held to it too: a scenario that quietly lost
        # items would make every stock assertion built on it meaningless.
        stock = scenario.DEFAULT_STOCK
        groups = scenario.distribute(stock)
        expected = sum(entry["count"] for entry in stock)
        actual = sum(entry["count"] for group in groups for entry in group)
        self.assertEqual(actual, expected)

    def test_no_inventory_is_given_more_slots_than_it_has(self):
        for group in scenario.distribute(scenario.DEFAULT_STOCK):
            slots = sum(scenario._slots_for(entry) for entry in group)
            self.assertLessEqual(slots, scenario.DOUBLE_CHEST_SLOTS)

    def test_splits_one_item_type_across_inventories_when_it_overflows(self):
        groups = scenario.distribute([{"id": "minecraft:cobblestone", "count": 64 * 100}])
        self.assertGreater(len(groups), 1)
        names = {entry["id"] for group in groups for entry in group}
        self.assertEqual(names, {"minecraft:cobblestone"})

    def test_respects_a_stack_limit_below_64(self):
        groups = scenario.distribute([{"id": "minecraft:ender_pearl", "count": 32}])
        self.assertEqual(scenario._slots_for(groups[0][0]), 2)


class ConfiguredScenarioTests(unittest.TestCase):
    def test_produces_a_config_the_controller_accepts(self):
        built = scenario.configured()
        config = built.config
        self.assertTrue(config["configured"])
        # Setup.validateConfig requires these exact field names.
        self.assertIsInstance(config["installation"]["computer_id"], int)
        self.assertIsInstance(config["installation"]["computer_label"], str)

    def test_drop_off_and_pickup_are_different_inventories(self):
        config = scenario.configured().config
        self.assertNotEqual(config["dropoff"]["peripheral_name"],
                            config["pickup"]["peripheral_name"])

    def test_storage_nodes_never_collide_with_the_role_inventories(self):
        config = scenario.configured().config
        roles = {config["dropoff"]["peripheral_name"],
                 config["pickup"]["peripheral_name"]}
        for node in config["storage"]:
            self.assertNotIn(node["peripheral_name"], roles)

    def test_storage_ids_are_unique(self):
        nodes = scenario.configured().config["storage"]
        ids = [node["id"] for node in nodes]
        self.assertEqual(len(ids), len(set(ids)))

    def test_every_declared_storage_node_exists_as_an_inventory(self):
        built = scenario.configured()
        declared = {node["peripheral_name"] for node in built.config["storage"]}
        existing = {inventory["name"] for inventory in built.inventories}
        self.assertTrue(declared.issubset(existing))

    def test_unconfigured_scenario_has_no_config(self):
        self.assertIsNone(scenario.unconfigured().config)

    def test_renders_to_a_lua_chunk(self):
        rendered = scenario.configured().to_lua()
        self.assertTrue(rendered.startswith("return {"))
        self.assertIn("inventories", rendered)


if __name__ == "__main__":
    unittest.main()
