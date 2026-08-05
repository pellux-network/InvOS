import os
import shutil
import subprocess
import tempfile
import unittest

from recipe_pack import (
    Converter,
    ItemTable,
    build_pack,
    display_names,
    flatten_tags,
    lua_value,
    render_pack,
)

# Prefer whatever "luac" resolves to on PATH; fall back to the known install
# location on this machine so the suite keeps working here without setup, but
# degrade to a skip (see HAVE_LUAC below) rather than a hard error anywhere
# else -- a test suite that only runs on one machine has stopped being a
# safety net.
LUAC = (
    shutil.which("luac")
    or r"C:\Users\Pellux\AppData\Local\Programs\Lua\bin\luac.exe"
)
HAVE_LUAC = os.path.exists(LUAC)


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

    def test_rejects_a_pattern_wider_than_three_columns(self):
        recipe = {
            "type": "minecraft:crafting_shaped",
            "pattern": ["####"],
            "key": {"#": {"item": "minecraft:stick"}},
            "result": {"item": "minecraft:widget"},
        }
        with self.assertRaises(ValueError):
            self.converter.convert("minecraft:widget", recipe)

    def test_rejects_a_pattern_taller_than_three_rows(self):
        recipe = {
            "type": "minecraft:crafting_shaped",
            "pattern": ["#", "#", "#", "#"],
            "key": {"#": {"item": "minecraft:stick"}},
            "result": {"item": "minecraft:widget"},
        }
        with self.assertRaises(ValueError):
            self.converter.convert("minecraft:widget", recipe)


class UnqualifiedRecipeTypeTest(unittest.TestCase):
    """A resource location with no namespace means minecraft:.

    Vanilla writes "minecraft:crafting_shaped", but a datapack may write plain
    "crafting_shaped" and the game treats them identically. Matching only the qualified
    form silently dropped 1,135 real grid recipes on the live pack, 146 of them from
    mysticalagriculture alone -- entire mods looked uncraftable.
    """

    def setUp(self):
        self.converter = Converter()

    def shaped(self, kind):
        return {"type": kind, "pattern": ["#"], "key": {"#": {"item": "minecraft:stick"}},
                "result": {"item": "mod:widget"}}

    def test_unqualified_shaped_is_converted(self):
        self.assertIsNotNone(self.converter.convert("mod:x", self.shaped("crafting_shaped")))

    def test_unqualified_shapeless_is_converted(self):
        body = self.converter.convert("mod:x", {
            "type": "crafting_shapeless",
            "ingredients": [{"item": "minecraft:stick"}],
            "result": {"item": "mod:widget"}})
        self.assertIsNotNone(body)
        self.assertFalse(body["shaped"])

    def test_the_qualified_form_still_works(self):
        body = self.converter.convert("mod:x", self.shaped("minecraft:crafting_shaped"))
        self.assertIsNotNone(body)
        self.assertTrue(body["shaped"])

    def test_a_namespaced_lookalike_is_still_refused(self):
        # create:crafting_shaped would be a different serializer entirely, not a grid
        # recipe a turtle can perform.
        self.assertIsNone(self.converter.convert("mod:x", self.shaped("create:crafting_shaped")))

    def test_other_unqualified_types_are_still_refused(self):
        self.assertIsNone(self.converter.convert("mod:x", self.shaped("smelting")))


class CustomGridSerialiserTest(unittest.TestCase):
    """Some mods register ordinary crafting-table recipes under their own serialiser.

    A turtle can perform those: they are RecipeType.CRAFTING with a vanilla pattern/key
    body, and the serialiser only changes matching rules the pack does not rely on.
    Cucumber's shaped_no_mirror is 249 recipes on the live pack, much of Mystical
    Agriculture, and was being dropped as if it were a machine recipe.
    """

    def setUp(self):
        self.converter = Converter()

    def test_shaped_no_mirror_is_a_grid_recipe(self):
        body = self.converter.convert("ma:x", {
            "type": "cucumber:shaped_no_mirror",
            "pattern": ["EEE", "EEE", "EEE"],
            "key": {"E": {"item": "ma:essence"}},
            "result": {"item": "ma:ingot", "count": 3}})
        self.assertIsNotNone(body)
        self.assertTrue(body["shaped"], "it places an exact grid, mirroring is irrelevant")
        self.assertEqual(body["count"], 3)

    def test_a_tag_result_is_refused(self):
        # The output would be whichever mod's ingot the game picks. The controller
        # identifies a crafted item by exact id, so it could not verify or deliver this.
        self.assertIsNone(self.converter.convert("ma:x", {
            "type": "cucumber:shaped_tag",
            "pattern": ["EEE"], "key": {"E": {"item": "ma:essence"}},
            "result": {"tag": "forge:ingots/aluminum", "count": 8}}))

    def test_a_damage_transferring_recipe_is_refused(self):
        # The output inherits durability from an ingredient, which the pack cannot express.
        self.assertIsNone(self.converter.convert("ma:x", {
            "type": "cucumber:shaped_transfer_damage", "transfer_nbt": True,
            "pattern": [" G ", "ISI", " G "],
            "key": {"G": {"item": "ma:gem"}, "I": {"item": "ma:ingot"},
                    "S": {"item": "ma:axe"}},
            "result": {"item": "ma:better_axe"}}))


class UnrepresentableIngredientTest(unittest.TestCase):
    """Vanilla only ever writes {"item":...}, {"tag":...} or a list of those. A modpack
    does not, and a recipe the pack cannot represent faithfully must be left out rather
    than approximated -- crafting it would consume the wrong items."""

    def setUp(self):
        self.converter = Converter()

    def shaped(self, ingredient, result=None):
        return {
            "type": "minecraft:crafting_shaped",
            "pattern": ["#"],
            "key": {"#": ingredient},
            "result": result or {"item": "minecraft:widget"},
        }

    def test_an_nbt_constrained_ingredient_is_refused(self):
        # forge:nbt and forge:partial_nbt demand a specific variant. Ingredient matching
        # in the controller is deliberately NBT-free, so honouring this is impossible and
        # ignoring it would craft from the wrong stack.
        recipe = self.shaped({"type": "forge:nbt", "item": "mod:tool",
                              "nbt": {"Damage": 0}})
        with self.assertRaises(ValueError):
            self.converter.convert("mod:x", recipe)

    def test_an_ingredient_with_neither_item_nor_tag_is_refused(self):
        with self.assertRaises(ValueError):
            self.converter.convert("mod:x", self.shaped({"type": "mod:custom_matcher"}))

    def test_a_pattern_symbol_missing_from_the_key_is_refused(self):
        recipe = {
            "type": "minecraft:crafting_shaped",
            "pattern": ["#%"],
            "key": {"#": {"item": "minecraft:stick"}},
            "result": {"item": "minecraft:widget"},
        }
        with self.assertRaises(ValueError):
            self.converter.convert("mod:x", recipe)

    def test_an_nbt_bearing_result_is_refused(self):
        recipe = self.shaped({"item": "minecraft:stick"},
                             result={"item": "mod:tool", "nbt": {"Energy": 0}})
        with self.assertRaises(ValueError):
            self.converter.convert("mod:x", recipe)

    def test_an_alternation_containing_an_unrepresentable_option_is_refused(self):
        recipe = self.shaped([{"item": "minecraft:stick"},
                              {"type": "forge:nbt", "item": "mod:tool", "nbt": {}}])
        with self.assertRaises(ValueError):
            self.converter.convert("mod:x", recipe)

    def test_a_plain_typed_item_ingredient_is_still_accepted(self):
        # Mods routinely write the explicit {"type":"minecraft:item"} form for something
        # entirely ordinary. Refusing that would drop thousands of good recipes.
        body = self.converter.convert(
            "mod:x", self.shaped({"type": "minecraft:item", "item": "minecraft:stick"}))
        self.assertIsNotNone(body)


class SkippedRecipeReportingTest(unittest.TestCase):
    """One unrepresentable recipe among tens of thousands must not abandon the import."""

    def test_a_bad_recipe_is_skipped_and_its_neighbours_still_convert(self):
        recipes = {
            "mod:good": {"type": "minecraft:crafting_shapeless",
                         "ingredients": [{"item": "minecraft:stick"}],
                         "result": {"item": "mod:good"}},
            "mod:bad": {"type": "minecraft:crafting_shapeless",
                        "ingredients": [{"type": "mod:matcher"}],
                        "result": {"item": "mod:bad"}},
            "mod:also_good": {"type": "minecraft:crafting_shapeless",
                              "ingredients": [{"item": "minecraft:stone"}],
                              "result": {"item": "mod:also_good"}},
        }
        pack = build_pack(recipes, {}, {})
        converted = sum(len(bodies) for bodies in pack["shards"].values())
        self.assertEqual(converted, 2)
        self.assertEqual(sum(pack["skipped"].values()), 1)

    def test_skips_are_reported_by_reason(self):
        recipes = {
            "mod:oversized": {"type": "minecraft:crafting_shaped",
                              "pattern": ["####"],
                              "key": {"#": {"item": "minecraft:stick"}},
                              "result": {"item": "mod:oversized"}},
            "mod:nbt": {"type": "minecraft:crafting_shapeless",
                        "ingredients": [{"item": "mod:tool", "nbt": {}}],
                        "result": {"item": "mod:nbt"}},
        }
        pack = build_pack(recipes, {}, {})
        self.assertEqual(sum(pack["skipped"].values()), 2)
        self.assertEqual(len(pack["skipped"]), 2, "each cause is counted separately")

    def test_a_clean_pack_reports_no_skips(self):
        recipes = {"mod:good": {"type": "minecraft:crafting_shapeless",
                                "ingredients": [{"item": "minecraft:stick"}],
                                "result": {"item": "mod:good"}}}
        self.assertEqual(build_pack(recipes, {}, {})["skipped"], {})


class LuaValueTest(unittest.TestCase):
    def test_renders_scalars(self):
        self.assertEqual(lua_value(7), "7")
        self.assertEqual(lua_value(True), "true")
        self.assertEqual(lua_value("hi"), '"hi"')

    def test_escapes_quotes_and_backslashes(self):
        self.assertEqual(lua_value('a"b\\c'), '"a\\"b\\\\c"')

    def test_escapes_control_characters(self):
        self.assertEqual(
            lua_value("a\nb\tc\rd\x00e"),
            '"a\\nb\\tc\\rd\\000e"',
        )

    def test_escapes_a_null_before_a_digit_without_creating_an_ambiguous_escape(self):
        # Lua's \ddd decimal escape greedily consumes up to three digits, so an
        # unpadded "\0" followed by an ASCII digit would merge into a single,
        # wrong byte (e.g. "\05" is byte 5, not NUL followed by '5'). Zero-padding
        # to "\000" always consumes exactly three digits, so a trailing literal
        # digit stays a separate character.
        self.assertEqual(lua_value("\x005"), '"\\0005"')

    def test_renders_arrays_and_string_keyed_tables(self):
        self.assertEqual(lua_value([1, 2]), "{1,2}")
        self.assertEqual(lua_value({"a": 1}), '{["a"]=1}')

    def test_table_keys_are_sorted_for_reproducible_output(self):
        self.assertEqual(lua_value({"b": 1, "a": 2}), '{["a"]=2,["b"]=1}')


def _parse_with_luac(path):
    """Run luac -p against a file and return the CompletedProcess."""
    return subprocess.run(
        [LUAC, "-p", path],
        capture_output=True,
        text=True,
    )


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
        # Chosen so the item indices land on 1, 2 and 8: CPython's set iterates
        # these in slot order (8, 1, 2), not ascending order, so this fixture
        # actually distinguishes sorted(outputs) from list(outputs) -- unlike a
        # fixture with two small, already-ascending indices.
        def craft(item_id, ingredients=None):
            return {
                "type": "minecraft:crafting_shapeless",
                "ingredients": [{"item": i} for i in (ingredients or [])],
                "result": {"item": item_id},
            }

        recipes = {
            "minecraft:a_target_low": craft("minecraft:target_low"),
            "minecraft:b_filler_intern": craft(
                "minecraft:intern_b",
                ["minecraft:f3", "minecraft:f4", "minecraft:f5", "minecraft:f6", "minecraft:f7"],
            ),
            "minecraft:c_target_high": craft("minecraft:target_high"),
        }
        pack = build_pack(recipes, {}, {}, shard_count=2)
        self.assertEqual(pack["items"]["ids"][0], "minecraft:target_low")
        self.assertEqual(pack["items"]["ids"][7], "minecraft:target_high")
        self.assertEqual(pack["index"]["outputs"], [1, 2, 8])

    def test_tag_members_are_stored_as_item_indices(self):
        # "minecraft:oak_planks" is interned early (index 1, via its own recipe)
        # while "minecraft:planks" is flattened alphabetically, so resolving the
        # tag encounters birch_planks (a new, higher index) before oak_planks
        # (already interned at 1). This makes the final [1, 5] only correct if
        # the tag's members are actually sorted, not just as-encountered.
        recipes = {
            "minecraft:0_make_oak_planks": {
                "type": "minecraft:crafting_shapeless",
                "ingredients": [{"item": "minecraft:oak_log"}],
                "result": {"item": "minecraft:oak_planks", "count": 4},
            },
            "minecraft:chest": self.recipes["minecraft:chest"],
            "minecraft:stick": self.recipes["minecraft:stick"],
        }
        pack = build_pack(recipes, self.tags, self.lang, shard_count=2)
        ids = pack["items"]["ids"]
        self.assertEqual(ids[0], "minecraft:oak_planks")
        self.assertEqual(ids[4], "minecraft:birch_planks")
        self.assertEqual(pack["tags"]["tags"]["minecraft:planks"], [1, 5])

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

    def test_rejects_non_positive_shard_count(self):
        with self.assertRaises(ValueError):
            build_pack(self.recipes, self.tags, self.lang, shard_count=0)

    def test_recipe_referencing_an_undefined_tag_still_builds_but_warns(self):
        # Zero occurrences in vanilla, but a mod jar can reference another
        # mod's tag that isn't present in this jar's own tag data. The recipe
        # must still build -- with an empty, unsatisfiable member list -- and
        # the operator must be warned rather than the run aborting outright.
        recipes = {
            "minecraft:widget": {
                "type": "minecraft:crafting_shapeless",
                "ingredients": [{"tag": "othermod:unknown_tag"}],
                "result": {"item": "minecraft:widget"},
            },
        }
        with self.assertWarns(UserWarning) as caught:
            pack = build_pack(recipes, {}, {}, shard_count=1)
        self.assertIn("othermod:unknown_tag", str(caught.warning))
        self.assertEqual(pack["tags"]["tags"]["othermod:unknown_tag"], [])

    @unittest.skipUnless(HAVE_LUAC, "luac not found on PATH or at the known install location")
    def test_rendered_files_are_syntactically_valid_lua(self):
        # This only proves the output parses, not that it parses under Lua 5.2
        # specifically -- the available luac reports "Lua 5.4.6", and a 5.4 parser
        # accepts constructs (//, bitwise operators, goto) that 5.2 forbids. That
        # gap is acceptable here because lua_value() can only ever emit comments,
        # `return`, table constructors, integer literals, string literals and
        # booleans, and that grammar subset is identical between Lua 5.2 and 5.4.
        pack = build_pack(self.recipes, self.tags, self.lang, shard_count=2)
        rendered = render_pack(pack)
        self.assertIn("items.lua", rendered)
        self.assertIn("index.lua", rendered)
        self.assertIn("tags.lua", rendered)
        self.assertIn("pack_01.lua", rendered)
        # The three metadata files derive "schema" through lua_value, so a typo
        # there would already fail elsewhere. The shard file hand-writes its
        # schema field as literal text, making it the one place the pack-format
        # version could silently drift without any test noticing.
        self.assertIn("schema = 1,", rendered["pack_01.lua"])
        with tempfile.TemporaryDirectory() as tmp_dir:
            for name, text in rendered.items():
                path = os.path.join(tmp_dir, name)
                with open(path, "w", encoding="utf-8", newline="\n") as handle:
                    handle.write(text)
                result = _parse_with_luac(path)
                self.assertEqual(
                    result.returncode, 0,
                    "%s failed to parse: %s" % (name, result.stderr),
                )

    @unittest.skipUnless(HAVE_LUAC, "luac not found on PATH or at the known install location")
    def test_control_characters_in_display_names_still_parse_as_lua(self):
        lang = dict(self.lang)
        # Includes a NUL immediately followed by a digit ("\x005"): with an
        # unpadded "\0" escape this would merge into a single wrong byte instead
        # of staying NUL + '5', so this is the case that actually exercises the
        # \000 zero-padding fix.
        lang["item.minecraft.chest"] = "Chest\n\t\"quoted\"\\slash\x005digit\x00end"
        pack = build_pack(self.recipes, self.tags, lang, shard_count=2)
        rendered = render_pack(pack)
        with tempfile.TemporaryDirectory() as tmp_dir:
            path = os.path.join(tmp_dir, "items.lua")
            with open(path, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(rendered["items.lua"])
            result = _parse_with_luac(path)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
