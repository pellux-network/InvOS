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
    """Schema 2 comes from MinecraftServer's RecipeManager rather than KubeJS's json view.

    That is the only source that holds script-added recipes: this pack adds 10,186 and
    removes 2,409 from scripts, and the json view showed neither. Ingredients arrive
    already resolved to concrete items, so there are no tags to expand and no conditions
    left to evaluate.
    """

    def dump(self, payload):
        handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        with handle:
            json.dump(payload, handle)
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def base(self, recipes, items=None, options=None):
        return {"schema": 2,
                "items": items or ["minecraft:stick", "minecraft:oak_planks", "mod:widget"],
                "options": options or [[1], [2]],
                "recipes": recipes}

    def test_a_shaped_recipe_becomes_a_pattern_and_key(self):
        path = self.dump(self.base({"mod:w": {
            "shaped": True, "width": 2, "height": 2,
            "cells": [1, 0, 0, 2],
            "result": {"item": 3, "count": 4}}}))
        recipes, _, _ = read_kubejs(path)
        body = recipes["mod:w"]
        self.assertEqual(body["type"], "minecraft:crafting_shaped")
        self.assertEqual(body["pattern"], ["a ", " b"])
        self.assertEqual(body["key"]["a"], {"item": "minecraft:stick"})
        self.assertEqual(body["key"]["b"], {"item": "minecraft:oak_planks"})
        self.assertEqual(body["result"], {"item": "mod:widget", "count": 4})

    def test_a_shapeless_recipe_lists_its_ingredients(self):
        path = self.dump(self.base({"mod:w": {
            "shaped": False, "cells": [1, 2],
            "result": {"item": 3, "count": 1}}}))
        body = read_kubejs(path)[0]["mod:w"]
        self.assertEqual(body["type"], "minecraft:crafting_shapeless")
        self.assertEqual(body["ingredients"],
                         [{"item": "minecraft:stick"}, {"item": "minecraft:oak_planks"}])

    def test_a_cell_accepting_several_items_becomes_an_alternation(self):
        # The game resolved this ingredient to every item it accepts. The converter turns
        # a list into a synthetic tag, which is the same mechanism a real tag used.
        path = self.dump(self.base(
            {"mod:w": {"shaped": False, "cells": [1],
                       "result": {"item": 3, "count": 1}}},
            options=[[1, 2]]))
        body = read_kubejs(path)[0]["mod:w"]
        self.assertEqual(body["ingredients"],
                         [[{"item": "minecraft:stick"}, {"item": "minecraft:oak_planks"}]])

    def test_a_narrow_shaped_recipe_keeps_its_shape(self):
        # A 1x3 recipe must not be widened; the pack places cells into a 3x3 grid and a
        # wrong width would put ingredients in the wrong slots.
        path = self.dump(self.base({"mod:w": {
            "shaped": True, "width": 1, "height": 3,
            "cells": [1, 1, 1],
            "result": {"item": 3, "count": 1}}}))
        body = read_kubejs(path)[0]["mod:w"]
        self.assertEqual(body["pattern"], ["a", "a", "a"])

    def test_tags_are_empty_because_ingredients_arrive_resolved(self):
        path = self.dump(self.base({"mod:w": {
            "shaped": False, "cells": [1], "result": {"item": 3, "count": 1}}}))
        _, tags, _ = read_kubejs(path)
        self.assertEqual(tags, {})

    def test_the_report_counts_what_was_read(self):
        path = self.dump(self.base({
            "a:one": {"shaped": False, "cells": [1], "result": {"item": 3, "count": 1}},
            "a:two": {"shaped": False, "cells": [2], "result": {"item": 3, "count": 1}}}))
        self.assertEqual(read_kubejs(path)[2]["recipes"], 2)

    def test_schema_one_is_refused_with_a_pointer_to_the_new_script(self):
        with self.assertRaises(SystemExit):
            read_kubejs(self.dump({"schema": 1, "recipes": {}, "tags": {}}))

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

    def test_indices_written_as_floats_are_accepted(self):
        # KubeJS serialises every JS number as a double, so the dump says 1.0 where it
        # means index 1. Rejecting that would fail the entire import on a real dump while
        # every hand-written fixture passed.
        path = self.dump({"schema": 2.0,
                          "items": ["minecraft:stick", "mod:widget"],
                          "options": [[1.0]],
                          "recipes": {"mod:w": {
                              "shaped": True, "width": 1.0, "height": 1.0,
                              "cells": [1.0],
                              "result": {"item": 2.0, "count": 4.0}}}})
        body = read_kubejs(path)[0]["mod:w"]
        self.assertEqual(body["pattern"], ["a"])
        self.assertEqual(body["key"]["a"], {"item": "minecraft:stick"})
        self.assertEqual(body["result"], {"item": "mod:widget", "count": 4})

    def test_a_fractional_index_is_still_refused(self):
        path = self.dump({"schema": 2, "items": ["a:b"], "options": [[1]],
                          "recipes": {"mod:w": {"shaped": False, "cells": [1.5],
                                                "result": {"item": 1, "count": 1}}}})
        with self.assertRaises(SystemExit):
            read_kubejs(path)

    def test_an_out_of_range_index_is_refused_rather_than_guessed(self):
        path = self.dump(self.base({"mod:w": {
            "shaped": False, "cells": [99], "result": {"item": 3, "count": 1}}}))
        with self.assertRaises(SystemExit):
            read_kubejs(path)


if __name__ == "__main__":
    unittest.main()
