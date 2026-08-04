"""Tests for reading recipe data out of jars.

The vanilla path reads one namespace out of one jar. Scanning a mods directory is a
different job: every namespace in every jar, with item tags accumulated across jars rather
than overwritten, because a tag like forge:ingots/iron is contributed to by many mods and
owned by none of them.
"""
import io
import json
import os
import tempfile
import unittest
import zipfile

from recipe_import import (
    merge_tags,
    read_jar,
    read_mods,
)


def make_jar(entries):
    """Build an in-memory jar from {path: python-object-or-bytes}."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for path, body in entries.items():
            if isinstance(body, bytes):
                archive.writestr(path, body)
            else:
                archive.writestr(path, json.dumps(body))
    buffer.seek(0)
    return buffer


def shaped(output):
    return {"type": "minecraft:crafting_shaped", "pattern": ["#"],
            "key": {"#": {"item": "minecraft:stick"}},
            "result": {"item": output}}


class ReadJarTest(unittest.TestCase):
    def test_reads_every_namespace_not_just_minecraft(self):
        jar = zipfile.ZipFile(make_jar({
            "data/minecraft/recipes/stick.json": shaped("minecraft:stick"),
            "data/create/recipes/cogwheel.json": shaped("create:cogwheel"),
            "data/thermal/recipes/machines/press.json": shaped("thermal:press"),
        }))
        recipes, _, _, bad = read_jar(jar)
        self.assertEqual(bad, 0)
        self.assertEqual(set(recipes), {
            "minecraft:stick", "create:cogwheel", "thermal:machines/press"})

    def test_nested_recipe_paths_keep_their_directory_in_the_id(self):
        # Two mods routinely ship recipes/a/x.json and recipes/b/x.json. Dropping the
        # directory would collapse them onto one id and silently lose one.
        jar = zipfile.ZipFile(make_jar({
            "data/create/recipes/crushing/ore.json": shaped("create:a"),
            "data/create/recipes/milling/ore.json": shaped("create:b"),
        }))
        recipes, _, _, _ = read_jar(jar)
        self.assertEqual(set(recipes), {"create:crushing/ore", "create:milling/ore"})

    def test_reads_item_tags_with_their_replace_flag(self):
        jar = zipfile.ZipFile(make_jar({
            "data/forge/tags/items/ingots/iron.json":
                {"replace": True, "values": ["create:iron_ingot"]},
            "data/forge/tags/items/nuggets.json": {"values": ["minecraft:gold_nugget"]},
        }))
        _, tags, _, _ = read_jar(jar)
        self.assertEqual(tags["forge:ingots/iron"],
                         {"replace": True, "values": ["create:iron_ingot"]})
        self.assertEqual(tags["forge:nuggets"],
                         {"replace": False, "values": ["minecraft:gold_nugget"]})

    def test_reads_english_lang_from_any_namespace(self):
        jar = zipfile.ZipFile(make_jar({
            "assets/create/lang/en_us.json": {"item.create.cogwheel": "Cogwheel"},
            "assets/create/lang/de_de.json": {"item.create.cogwheel": "Zahnrad"},
        }))
        _, _, lang, _ = read_jar(jar)
        self.assertEqual(lang, {"item.create.cogwheel": "Cogwheel"})

    def test_malformed_json_is_counted_not_fatal(self):
        # One broken file among 400-odd mods must not abandon the whole import.
        jar = zipfile.ZipFile(make_jar({
            "data/broken/recipes/bad.json": b"{not json",
            "data/good/recipes/fine.json": shaped("good:fine"),
        }))
        recipes, _, _, bad = read_jar(jar)
        self.assertEqual(set(recipes), {"good:fine"})
        self.assertEqual(bad, 1)


class MergeTagsTest(unittest.TestCase):
    def test_contributions_accumulate_across_jars(self):
        # This is the whole reason tags are merged rather than assigned. Every mod adding
        # an iron ingot contributes to forge:ingots/iron; overwriting keeps only whichever
        # jar was read last, and every recipe using the tag then sees one item.
        accumulated = {}
        merge_tags(accumulated, {"forge:ingots/iron":
                                 {"replace": False, "values": ["minecraft:iron_ingot"]}})
        merge_tags(accumulated, {"forge:ingots/iron":
                                 {"replace": False, "values": ["create:iron_ingot"]}})
        self.assertEqual(accumulated["forge:ingots/iron"],
                         ["minecraft:iron_ingot", "create:iron_ingot"])

    def test_replace_discards_what_came_before(self):
        accumulated = {"forge:ingots/iron": ["minecraft:iron_ingot"]}
        merge_tags(accumulated, {"forge:ingots/iron":
                                 {"replace": True, "values": ["create:iron_ingot"]}})
        self.assertEqual(accumulated["forge:ingots/iron"], ["create:iron_ingot"])

    def test_an_unrelated_tag_is_untouched(self):
        accumulated = {"forge:nuggets": ["minecraft:gold_nugget"]}
        merge_tags(accumulated, {"forge:ingots": {"replace": False, "values": ["x:y"]}})
        self.assertEqual(accumulated["forge:nuggets"], ["minecraft:gold_nugget"])


class ReadModsTest(unittest.TestCase):
    def write(self, directory, name, entries):
        with open(os.path.join(directory, name), "wb") as handle:
            handle.write(make_jar(entries).getvalue())

    def test_scans_every_jar_and_merges_their_tags(self):
        with tempfile.TemporaryDirectory() as directory:
            self.write(directory, "a.jar", {
                "data/aaa/recipes/one.json": shaped("aaa:one"),
                "data/forge/tags/items/ingots.json": {"values": ["aaa:ingot"]},
            })
            self.write(directory, "b.jar", {
                "data/bbb/recipes/two.json": shaped("bbb:two"),
                "data/forge/tags/items/ingots.json": {"values": ["bbb:ingot"]},
            })
            recipes, tags, _, report = read_mods(directory)
        self.assertEqual(set(recipes), {"aaa:one", "bbb:two"})
        self.assertEqual(sorted(tags["forge:ingots"]), ["aaa:ingot", "bbb:ingot"])
        self.assertEqual(report["jars"], 2)

    def test_a_file_that_is_not_a_zip_is_reported_not_fatal(self):
        with tempfile.TemporaryDirectory() as directory:
            with open(os.path.join(directory, "broken.jar"), "wb") as handle:
                handle.write(b"this is not a jar")
            self.write(directory, "good.jar", {"data/good/recipes/x.json": shaped("good:x")})
            recipes, _, _, report = read_mods(directory)
        self.assertEqual(set(recipes), {"good:x"})
        self.assertEqual(report["unreadable"], ["broken.jar"])

    def test_a_source_may_be_a_single_jar_file(self):
        # Forge ships the forge:* item tags from its own jar under libraries/, not from
        # the mods directory. Thousands of modded recipes reference those tags, and
        # leaving the jar out does not fail -- every one of them silently resolves to no
        # items instead.
        with tempfile.TemporaryDirectory() as directory:
            mods = os.path.join(directory, "mods")
            os.mkdir(mods)
            self.write(mods, "a.jar", {"data/aaa/recipes/one.json": shaped("aaa:one")})
            self.write(directory, "forge.jar",
                       {"data/forge/tags/items/ingots/iron.json":
                        {"values": ["minecraft:iron_ingot"]}})
            recipes, tags, _, report = read_mods(
                [mods, os.path.join(directory, "forge.jar")])
        self.assertEqual(set(recipes), {"aaa:one"})
        self.assertEqual(tags["forge:ingots/iron"], ["minecraft:iron_ingot"])
        self.assertEqual(report["jars"], 2)

    def test_a_missing_directory_is_a_clean_error(self):
        with self.assertRaises(SystemExit):
            read_mods(os.path.join(tempfile.gettempdir(), "definitely-not-here-12345"))

    def test_later_jars_overriding_a_recipe_id_are_counted(self):
        with tempfile.TemporaryDirectory() as directory:
            self.write(directory, "a.jar", {"data/ns/recipes/x.json": shaped("ns:first")})
            self.write(directory, "z.jar", {"data/ns/recipes/x.json": shaped("ns:second")})
            recipes, _, _, report = read_mods(directory)
        self.assertEqual(report["collisions"], 1)
        self.assertEqual(recipes["ns:x"]["result"]["item"], "ns:second")


if __name__ == "__main__":
    unittest.main()
