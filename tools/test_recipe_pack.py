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


if __name__ == "__main__":
    unittest.main()
