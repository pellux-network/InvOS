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


if __name__ == "__main__":
    unittest.main()
