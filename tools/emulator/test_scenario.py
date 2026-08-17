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

    def test_configured_still_leaves_crafting_unbound(self):
        # A supported configuration in its own right, and the one every existing
        # smoke test asserts against: no buffer and no turtle means the craft
        # service is never constructed and everything else runs unchanged.
        built = scenario.configured()
        self.assertIsNone(built.config["craft_buffer"])
        self.assertIsNone(built.config["turtle"])
        self.assertIsNone(built.turtle)

    def test_optional_runtime_environment_is_serialised_for_the_boot_harness(self):
        built = scenario.configured()
        built.environment = {"scan_refresh_interval": 123456}
        rendered = built.to_lua()
        self.assertIn("environment", rendered)
        self.assertIn("scan_refresh_interval = 123456", rendered)


class CraftingScenarioTests(unittest.TestCase):
    def test_binds_a_buffer_and_a_turtle(self):
        built = scenario.crafting()
        self.assertEqual(built.config["craft_buffer"],
                         {"peripheral_name": scenario.CRAFT_BUFFER_NAME})
        # The turtle is bound by its computer peripheral's name, which is what
        # TurtleLink resolves a rednet ID through.
        self.assertEqual(built.config["turtle"], {"peripheral_name": "computer_1"})

    def test_the_buffer_exists_as_an_inventory(self):
        names = [entry["name"] for entry in scenario.crafting().inventories]
        self.assertIn(scenario.CRAFT_BUFFER_NAME, names)

    def test_the_buffer_is_not_also_a_storage_node(self):
        built = scenario.crafting()
        storage = [node["peripheral_name"] for node in built.config["storage"]]
        self.assertNotIn(scenario.CRAFT_BUFFER_NAME, storage)

    def test_the_world_declares_the_turtle(self):
        rendered = scenario.crafting().to_lua()
        self.assertIn("emu:crafter_inventory", rendered)
        self.assertIn("emu:void", rendered)

    def test_stock_can_craft_the_tree_but_holds_no_intermediate(self):
        ids = [entry["id"] for entry in scenario.CRAFT_STOCK]
        self.assertIn("minecraft:oak_log", ids)
        self.assertIn("minecraft:coal", ids)
        self.assertIn("minecraft:stick", ids)
        # No planks: a stick craft must go through planks rather than finding
        # the intermediate already in storage, which is what makes it a tree.
        self.assertNotIn("minecraft:oak_planks", ids)

    def test_the_turtle_gets_its_own_small_scenario(self):
        built = scenario.crafting()
        self.assertTrue(built.turtle)
        turtle_lua = built.turtle_lua()
        self.assertIn("skip_splash", turtle_lua)
        self.assertIn("world_server", turtle_lua)
        # It must not carry the controller's world: peripherals do not cross
        # computers, so those inventories are ones the turtle can never reach.
        self.assertNotIn("inventories", turtle_lua)

    def test_recipes_can_be_overridden_to_make_the_world_disagree(self):
        # An empty list serialises as "{}", so a world told to know no recipes
        # says so explicitly -- which is how "the pack has a recipe the game
        # does not" is reproduced.
        self.assertIn("recipes = {}", scenario.crafting(recipes=[]).to_lua())

    def test_recipes_are_omitted_when_not_overridden(self):
        # Left out entirely, so craft_oracle.lua's own defaults stay the single
        # place the world's recipes are written down.
        self.assertNotIn("recipes", scenario.crafting().to_lua())


if __name__ == "__main__":
    unittest.main()
