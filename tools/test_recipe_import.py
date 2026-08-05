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
    read_kubejs,
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


class ReadKubeJsTest(unittest.TestCase):
    """The runtime dump is authoritative in a way a jar scan cannot be: about 10% of modded
    crafting recipes are gated behind conditions that depend on each mod's config."""

    def dump(self, payload):
        handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        with handle:
            json.dump(payload, handle)
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def test_reads_recipes_keyed_by_id(self):
        path = self.dump({"schema": 1,
                          "recipes": {"quark:dark_oak_chest":
                                      shaped("quark:dark_oak_chest")},
                          "tags": {}})
        recipes, tags, _ = read_kubejs(path)
        self.assertEqual(list(recipes), ["quark:dark_oak_chest"])
        self.assertEqual(recipes["quark:dark_oak_chest"]["result"]["item"],
                         "quark:dark_oak_chest")
        self.assertEqual(tags, {})

    def test_tags_come_resolved_from_the_game(self):
        # The game already expanded these, so nothing here needs flattening and nothing can
        # disagree with what the server will actually accept.
        path = self.dump({"schema": 1, "recipes": {},
                          "tags": {"minecraft:planks": ["minecraft:oak_planks",
                                                        "minecraft:dark_oak_planks"]}})
        _, tags, _ = read_kubejs(path)
        self.assertEqual(tags["minecraft:planks"],
                         ["minecraft:oak_planks", "minecraft:dark_oak_planks"])

    def test_an_empty_tag_is_kept_rather_than_dropped(self):
        # Kept so "resolves to nothing" stays distinguishable from "never mentioned", which
        # is what the undefined-tag warning reports on.
        path = self.dump({"schema": 1, "recipes": {}, "tags": {"mod:absent": []}})
        _, tags, _ = read_kubejs(path)
        self.assertEqual(tags["mod:absent"], [])

    def test_a_report_counts_what_was_read(self):
        path = self.dump({"schema": 1,
                          "recipes": {"a:one": shaped("a:one"),
                                      "a:two": shaped("a:two")},
                          "tags": {"t:x": ["a:i"]}})
        _, _, report = read_kubejs(path)
        self.assertEqual(report["recipes"], 2)
        self.assertEqual(report["tags"], 1)

    def test_an_unknown_schema_is_refused(self):
        # A dump from a newer script must not be read under old assumptions.
        path = self.dump({"schema": 99, "recipes": {}, "tags": {}})
        with self.assertRaises(SystemExit):
            read_kubejs(path)

    def test_a_missing_file_is_a_clean_error(self):
        with self.assertRaises(SystemExit):
            read_kubejs(os.path.join(tempfile.gettempdir(), "no-such-dump-12345.json"))

    def test_malformed_json_is_a_clean_error(self):
        handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        with handle:
            handle.write("{not json")
        self.addCleanup(os.unlink, handle.name)
        with self.assertRaises(SystemExit):
            read_kubejs(handle.name)

    def test_a_list_shaped_dump_is_refused(self):
        # An older export wrote a list of {id, recipe}. Reading it as a mapping would
        # silently yield nothing rather than failing.
        path = self.dump({"schema": 1, "recipes": [{"id": "a:one",
                                                    "recipe": shaped("a:one")}],
                          "tags": {}})
        with self.assertRaises(SystemExit):
            read_kubejs(path)

    def test_an_entry_that_is_not_an_object_is_refused(self):
        path = self.dump({"schema": 1, "recipes": {"a:one": "not a recipe"}, "tags": {}})
        with self.assertRaises(SystemExit):
            read_kubejs(path)


if __name__ == "__main__":
    unittest.main()
