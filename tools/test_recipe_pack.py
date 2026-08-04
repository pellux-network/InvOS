import unittest

from recipe_pack import flatten_tags


class FlattenTagsTest(unittest.TestCase):
    def test_expands_nested_tags(self):
        raw = {
            "minecraft:logs": ["#minecraft:oak_logs", "#minecraft:birch_logs"],
            "minecraft:oak_logs": ["minecraft:oak_log", "minecraft:stripped_oak_log"],
            "minecraft:birch_logs": ["minecraft:birch_log"],
        }
        flat = flatten_tags(raw)
        self.assertEqual(
            flat["minecraft:logs"],
            ["minecraft:birch_log", "minecraft:oak_log", "minecraft:stripped_oak_log"],
        )

    def test_flat_tag_is_unchanged(self):
        raw = {"minecraft:planks": ["minecraft:oak_planks", "minecraft:birch_planks"]}
        self.assertEqual(
            flatten_tags(raw)["minecraft:planks"],
            ["minecraft:birch_planks", "minecraft:oak_planks"],
        )

    def test_cyclic_tags_terminate(self):
        raw = {"a": ["#b", "minecraft:stone"], "b": ["#a", "minecraft:dirt"]}
        flat = flatten_tags(raw)
        self.assertEqual(flat["a"], ["minecraft:dirt", "minecraft:stone"])

    def test_object_entries_and_missing_tags_are_tolerated(self):
        raw = {"a": [{"id": "minecraft:stone", "required": False}, "#nope"]}
        self.assertEqual(flatten_tags(raw)["a"], ["minecraft:stone"])


from recipe_pack import ItemTable, display_names


class ItemTableTest(unittest.TestCase):
    def test_interns_ids_stably_and_deduplicates(self):
        table = ItemTable()
        first = table.index("minecraft:stone")
        again = table.index("minecraft:stone")
        other = table.index("minecraft:dirt")
        self.assertEqual(first, again)
        self.assertNotEqual(first, other)

    def test_indices_are_one_based_for_lua(self):
        table = ItemTable()
        self.assertEqual(table.index("minecraft:stone"), 1)
        self.assertEqual(table.index("minecraft:dirt"), 2)

    def test_ids_round_trip_in_index_order(self):
        table = ItemTable()
        table.index("minecraft:stone")
        table.index("minecraft:dirt")
        self.assertEqual(table.ids(), ["minecraft:stone", "minecraft:dirt"])


class DisplayNamesTest(unittest.TestCase):
    def test_prefers_item_key_then_block_key(self):
        lang = {
            "item.minecraft.stick": "Stick",
            "block.minecraft.stone": "Stone",
            "item.minecraft.stone": "Stone Item",
        }
        names = display_names(["minecraft:stick", "minecraft:stone"], lang)
        self.assertEqual(names, ["Stick", "Stone Item"])

    def test_falls_back_to_the_raw_id_when_untranslated(self):
        names = display_names(["mod:widget"], {})
        self.assertEqual(names, ["mod:widget"])


from recipe_pack import Converter


class ConvertRecipeTest(unittest.TestCase):
    def setUp(self):
        self.converter = Converter()

    def test_shaped_recipe_expands_to_a_nine_cell_grid(self):
        recipe = {
            "type": "minecraft:crafting_shaped",
            "pattern": ["##", "##"],
            "key": {"#": {"tag": "minecraft:planks"}},
            "result": {"item": "minecraft:crafting_table"},
        }
        converted = self.converter.convert("minecraft:crafting_table", recipe)
        self.assertTrue(converted["shaped"])
        self.assertEqual(converted["count"], 1)
        self.assertEqual(
            converted["grid"],
            ["minecraft:planks", "minecraft:planks", 0,
             "minecraft:planks", "minecraft:planks", 0,
             0, 0, 0],
        )

    def test_shaped_pattern_is_left_aligned_into_the_grid(self):
        recipe = {
            "type": "minecraft:crafting_shaped",
            "pattern": ["X", "#"],
            "key": {"X": {"item": "minecraft:coal"}, "#": {"item": "minecraft:stick"}},
            "result": {"item": "minecraft:torch", "count": 4},
        }
        converted = self.converter.convert("minecraft:torch", recipe)
        coal = self.converter.items.index("minecraft:coal")
        stick = self.converter.items.index("minecraft:stick")
        self.assertEqual(converted["count"], 4)
        self.assertEqual(converted["grid"], [coal, 0, 0, stick, 0, 0, 0, 0, 0])

    def test_shapeless_recipe_keeps_an_ingredient_list(self):
        recipe = {
            "type": "minecraft:crafting_shapeless",
            "ingredients": [{"item": "minecraft:oak_log"}],
            "result": {"item": "minecraft:oak_planks", "count": 4},
        }
        converted = self.converter.convert("minecraft:oak_planks", recipe)
        self.assertFalse(converted["shaped"])
        self.assertEqual(converted["count"], 4)
        self.assertEqual(len(converted["ingredients"]), 1)

    def test_alternation_list_becomes_a_synthetic_tag(self):
        recipe = {
            "type": "minecraft:crafting_shapeless",
            "ingredients": [[{"item": "minecraft:gold_ingot"}, {"tag": "minecraft:planks"}]],
            "result": {"item": "minecraft:widget"},
        }
        converted = self.converter.convert("minecraft:widget", recipe)
        reference = converted["ingredients"][0]
        self.assertEqual(reference, "@alt:1")
        self.assertIn("@alt:1", self.converter.synthetic_tags)
        self.assertEqual(
            self.converter.synthetic_tags["@alt:1"],
            ["minecraft:gold_ingot", "#minecraft:planks"],
        )

    def test_identical_alternations_reuse_one_synthetic_tag(self):
        recipe = {
            "type": "minecraft:crafting_shapeless",
            "ingredients": [
                [{"item": "minecraft:a"}, {"item": "minecraft:b"}],
                [{"item": "minecraft:a"}, {"item": "minecraft:b"}],
            ],
            "result": {"item": "minecraft:widget"},
        }
        converted = self.converter.convert("minecraft:widget", recipe)
        self.assertEqual(converted["ingredients"], ["@alt:1", "@alt:1"])
        self.assertEqual(len(self.converter.synthetic_tags), 1)

    def test_unsupported_recipe_types_are_skipped(self):
        for kind in ("minecraft:smelting", "minecraft:stonecutting",
                     "minecraft:smithing", "minecraft:crafting_special_repairitem"):
            self.assertIsNone(
                self.converter.convert("x", {"type": kind, "result": {"item": "y"}})
            )


from recipe_pack import lua_value, build_pack, render_pack


class LuaValueTest(unittest.TestCase):
    def test_renders_scalars(self):
        self.assertEqual(lua_value(7), "7")
        self.assertEqual(lua_value(True), "true")
        self.assertEqual(lua_value("hi"), '"hi"')

    def test_escapes_quotes_and_backslashes(self):
        self.assertEqual(lua_value('a"b\\c'), '"a\\"b\\\\c"')

    def test_renders_arrays_and_string_keyed_tables(self):
        self.assertEqual(lua_value([1, 2]), "{1,2}")
        self.assertEqual(lua_value({"a": 1}), '{["a"]=1}')

    def test_table_keys_are_sorted_for_reproducible_output(self):
        self.assertEqual(lua_value({"b": 1, "a": 2}), '{["a"]=2,["b"]=1}')


class BuildPackTest(unittest.TestCase):
    def setUp(self):
        self.recipes = {
            "minecraft:chest": {
                "type": "minecraft:crafting_shaped",
                "pattern": ["###", "# #", "###"],
                "key": {"#": {"tag": "minecraft:planks"}},
                "result": {"item": "minecraft:chest"},
            },
            "minecraft:stick": {
                "type": "minecraft:crafting_shapeless",
                "ingredients": [{"tag": "minecraft:planks"}, {"tag": "minecraft:planks"}],
                "result": {"item": "minecraft:stick", "count": 4},
            },
            "minecraft:skipped": {
                "type": "minecraft:smelting",
                "result": {"item": "minecraft:iron_ingot"},
            },
        }
        self.tags = {"minecraft:planks": ["minecraft:oak_planks", "minecraft:birch_planks"]}
        self.lang = {"item.minecraft.chest": "Chest", "item.minecraft.stick": "Stick"}

    def test_drops_uncraftable_recipe_types(self):
        pack = build_pack(self.recipes, self.tags, self.lang, shard_count=2)
        ids = sorted(r["id"] for shard in pack["shards"].values() for r in shard)
        self.assertEqual(ids, ["minecraft:chest", "minecraft:stick"])

    def test_outputs_are_sorted_item_indices(self):
        pack = build_pack(self.recipes, self.tags, self.lang, shard_count=2)
        self.assertEqual(pack["index"]["outputs"], sorted(pack["index"]["outputs"]))
        self.assertEqual(len(pack["index"]["outputs"]), 2)

    def test_tag_members_are_stored_as_item_indices(self):
        pack = build_pack(self.recipes, self.tags, self.lang, shard_count=2)
        members = pack["tags"]["tags"]["minecraft:planks"]
        ids = pack["items"]["ids"]
        self.assertEqual(
            sorted(ids[index - 1] for index in members),
            ["minecraft:birch_planks", "minecraft:oak_planks"],
        )

    def test_only_tags_actually_referenced_are_emitted(self):
        tags = dict(self.tags)
        tags["minecraft:unused"] = ["minecraft:dirt"]
        pack = build_pack(self.recipes, tags, self.lang, shard_count=2)
        self.assertNotIn("minecraft:unused", pack["tags"]["tags"])

    def test_every_recipe_lands_in_the_shard_its_output_maps_to(self):
        pack = build_pack(self.recipes, self.tags, self.lang, shard_count=2)
        for shard_number, bodies in pack["shards"].items():
            for body in bodies:
                self.assertEqual(1 + (body["output"] % 2), shard_number)

    def test_rendered_pack_is_valid_lua_returning_a_table(self):
        pack = build_pack(self.recipes, self.tags, self.lang, shard_count=2)
        rendered = render_pack(pack)
        self.assertIn("items.lua", rendered)
        self.assertIn("index.lua", rendered)
        self.assertIn("tags.lua", rendered)
        self.assertIn("pack_01.lua", rendered)
        for name, text in rendered.items():
            self.assertTrue(text.startswith("-- generated"), name)
            self.assertIn("return {", text)
            self.assertNotIn("//", text)


if __name__ == "__main__":
    unittest.main()
