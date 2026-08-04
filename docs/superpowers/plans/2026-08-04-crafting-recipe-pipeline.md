# Crafting Recipe Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert vanilla Minecraft 1.18.2 crafting recipes into a compact Lua pack the controller can query, and expose it through a merge-aware repo module plus an operator preference store.

**Architecture:** A host-side Python converter reads the nested vanilla server jar and emits plain Lua modules under `controller/colossal/recipes/`. A runtime module `core/recipe_repo.lua` loads them, merges hand-written recipes from `colossal/data/custom_recipes.lua` on top, and answers output/ingredient/tag queries with lazily-loaded shards. Nothing in this stage touches a peripheral, a monitor, or the turtle.

**Tech Stack:** Python 3 stdlib only (`zipfile`, `json`, `unittest`) for the converter. Lua 5.4 on the host for tests; the emitted pack and all runtime modules must remain Lua 5.2 compatible for CC:Tweaked.

**Spec:** `docs/superpowers/specs/2026-08-04-crafting-system-design.md`

---

## Critical constraints

Read these before starting. Violating any one of them breaks a rule the existing suite enforces.

1. **Lua 5.2 compatibility in every file under `controller/`.** The host runs 5.4 but CC:Tweaked runs 5.2. No integer division (`//`), no bitwise operators, no `math.type`, no integer/float distinction. Use `math.floor(a / b)`. A green host suite does not prove CC compatibility.
2. **Generated packs go in `controller/colossal/recipes/`, never `colossal/data/`.** `tests/test_deployment.lua` asserts no manifest path contains the substring `data`, and `AGENTS.md` says `colossal/data/` is preserved and never deployed. A pack under `data/` could not be listed in the manifest and would never reach the live computer.
3. **Never read from or write to the live Minecraft server.** The converter reads a jar under `C:\Servers\` **read-only** and only when explicitly run by an operator. Tests must build their own fixture jars in a temp directory and must never open the real one.
4. **Every new test module must be registered** in `defaultModules` in `controller/colossal/tests/run.lua` or it silently never runs.
5. **Baseline is 343 passed, 0 failed.** Verify before you start and after every task. The count must only ever go up.

---

## File Structure

| path | responsibility | deployed |
|---|---|---|
| `tools/recipe_import.py` | Converter CLI: jar -> Lua pack | no |
| `tools/recipe_pack.py` | Pure conversion logic, no file or CLI I/O | no |
| `tools/test_recipe_pack.py` | Python unit tests over synthetic fixture jars | no |
| `controller/colossal/recipes/items.lua` | Interned item IDs + display names (generated) | yes |
| `controller/colossal/recipes/index.lua` | Craftable outputs + shard count (generated) | yes |
| `controller/colossal/recipes/tags.lua` | Pre-flattened tags (generated) | yes |
| `controller/colossal/recipes/pack_NN.lua` | Recipe bodies, sharded (generated) | yes |
| `controller/colossal/core/recipe_repo.lua` | Loads, merges and queries packs | yes |
| `controller/colossal/core/craft_prefs.lua` | Validated store for pinned tag/recipe choices | yes |
| `controller/colossal/tests/test_recipe_repo.lua` | Repo tests | no |
| `controller/colossal/tests/test_craft_prefs.lua` | Preference store tests | no |

`tools/recipe_pack.py` is split from `tools/recipe_import.py` deliberately: the conversion logic is the part worth testing, and keeping it free of `argparse` and file writes means tests call functions rather than shelling out.

---

## Pack format

This is the interface every later stage depends on. Define it once, here.

**Ingredient reference** — one of:
- a positive integer: an index into `items.ids`
- a string: a tag name, looked up in `tags.lua`
- `0`: an empty grid cell (shaped recipes only)

Alternation lists (`[{"item": ...}, {"tag": ...}]`) become **synthetic tags** named `@alt:<n>`, so the runtime has exactly one ambiguity mechanism rather than two.

```lua
-- colossal/recipes/items.lua
return {
  schema = 1,
  ids   = { "minecraft:acacia_planks", "minecraft:chest", ... },  -- index -> item id
  names = { "Acacia Planks",           "Chest",           ... },  -- parallel to ids
}

-- colossal/recipes/index.lua
return {
  schema = 1,
  pack = "vanilla-1.18.2",
  shard_count = 4,
  outputs = { 2, 7, 11, ... },  -- sorted item indices that at least one recipe produces
}

-- colossal/recipes/tags.lua
return {
  schema = 1,
  tags = {
    ["minecraft:planks"] = { 1, 14, 22, ... },  -- item indices, sorted
    ["@alt:1"]           = { 5, 9 },
  },
}

-- colossal/recipes/pack_01.lua
return {
  schema = 1,
  recipes = {
    { id = "minecraft:chest", output = 7, count = 1, shaped = true,
      grid = { "minecraft:planks", "minecraft:planks", "minecraft:planks",
               "minecraft:planks", 0,                  "minecraft:planks",
               "minecraft:planks", "minecraft:planks", "minecraft:planks" } },
    { id = "minecraft:stick", output = 11, count = 4, shaped = false,
      ingredients = { "minecraft:planks", "minecraft:planks" } },
  },
}
```

**Sharding rule:** a recipe lives in shard `1 + (output_index % shard_count)`. Every recipe for a given output therefore shares one shard, so resolving an output requires loading exactly one shard file.

---

## Task 1: Worktree and converter scaffolding

**Files:**
- Create: `tools/recipe_pack.py`
- Create: `tools/test_recipe_pack.py`

- [ ] **Step 1: Create the isolated worktree**

`AGENTS.md` requires behaviour changes in an isolated worktree.

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage && git worktree add .worktrees/recipe-pipeline -b feat/recipe-pipeline
```

Expected: `Preparing worktree (new branch 'feat/recipe-pipeline')`.

All remaining work happens in `.worktrees/recipe-pipeline`.

- [ ] **Step 2: Confirm the baseline suite is green before changing anything**

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && lua colossal/tests/run.lua 2>&1 | tail -1
```

Expected: `RESULT 343 passed, 0 failed`

- [ ] **Step 3: Write the failing test for nested tag flattening**

Create `tools/test_recipe_pack.py`. `#minecraft:logs` really does nest in vanilla, and expands to 32 items, so flattening must recurse and must tolerate a cycle rather than hanging.

```python
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
```

- [ ] **Step 4: Run it to confirm it fails**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/tools && python -m unittest test_recipe_pack -v
```

Expected: `ModuleNotFoundError: No module named 'recipe_pack'`

- [ ] **Step 5: Write the minimal implementation**

Create `tools/recipe_pack.py`:

```python
"""Pure conversion logic for turning Minecraft recipe JSON into a Lua pack.

Deliberately free of CLI parsing and file writes so it can be unit tested by
calling functions. tools/recipe_import.py is the thin CLI wrapper.
"""


def _tag_entry_id(entry):
    """A tag value is either a plain string or {"id": ..., "required": ...}."""
    if isinstance(entry, dict):
        return entry.get("id", "")
    return entry


def flatten_tags(raw_tags):
    """Expand nested "#tag" references into flat, sorted, deduplicated item lists.

    Cycles terminate rather than recursing forever; a reference to a tag that does
    not exist contributes nothing instead of raising.
    """
    resolved = {}

    def expand(name, seen):
        if name in seen:
            return set()
        seen = seen | {name}
        items = set()
        for entry in raw_tags.get(name, []):
            value = _tag_entry_id(entry)
            if not value:
                continue
            if value.startswith("#"):
                items |= expand(value[1:], seen)
            else:
                items.add(value)
        return items

    for name in raw_tags:
        resolved[name] = sorted(expand(name, frozenset()))
    return resolved
```

- [ ] **Step 6: Run the tests to confirm they pass**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/tools && python -m unittest test_recipe_pack -v
```

Expected: `Ran 4 tests` ... `OK`

- [ ] **Step 7: Commit**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline && git add tools/recipe_pack.py tools/test_recipe_pack.py && git commit -m "feat: flatten nested Minecraft item tags"
```

---

## Task 2: Intern item IDs and extract display names

**Files:**
- Modify: `tools/recipe_pack.py`
- Modify: `tools/test_recipe_pack.py`

- [ ] **Step 1: Write the failing tests**

Append to `tools/test_recipe_pack.py`, above the `if __name__` block:

```python
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
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/tools && python -m unittest test_recipe_pack -v
```

Expected: `ImportError: cannot import name 'ItemTable' from 'recipe_pack'`

- [ ] **Step 3: Implement**

Append to `tools/recipe_pack.py`:

```python
class ItemTable:
    """Interns item IDs to 1-based indices so the emitted pack stores each long
    namespaced ID exactly once instead of on every recipe that mentions it."""

    def __init__(self):
        self._by_id = {}
        self._ids = []

    def index(self, item_id):
        existing = self._by_id.get(item_id)
        if existing is not None:
            return existing
        self._ids.append(item_id)
        assigned = len(self._ids)
        self._by_id[item_id] = assigned
        return assigned

    def ids(self):
        return list(self._ids)


def display_names(item_ids, lang):
    """Map item IDs to human names using the jar's en_us.json.

    An item can be translated under item.<ns>.<path> or block.<ns>.<path>; some
    exist under both. Untranslated IDs fall back to the raw ID so the Crafting
    page always has something to render.
    """
    names = []
    for item_id in item_ids:
        namespace, _, path = item_id.partition(":")
        names.append(
            lang.get("item.%s.%s" % (namespace, path))
            or lang.get("block.%s.%s" % (namespace, path))
            or item_id
        )
    return names
```

- [ ] **Step 4: Run to confirm pass**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/tools && python -m unittest test_recipe_pack -v
```

Expected: `Ran 9 tests` ... `OK`

- [ ] **Step 5: Commit**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline && git add tools/recipe_pack.py tools/test_recipe_pack.py && git commit -m "feat: intern item ids and resolve display names"
```

---

## Task 3: Convert shaped and shapeless recipes

**Files:**
- Modify: `tools/recipe_pack.py`
- Modify: `tools/test_recipe_pack.py`

- [ ] **Step 1: Write the failing tests**

Append to `tools/test_recipe_pack.py`, above the `if __name__` block:

```python
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
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/tools && python -m unittest test_recipe_pack -v
```

Expected: `ImportError: cannot import name 'Converter' from 'recipe_pack'`

- [ ] **Step 3: Implement**

Append to `tools/recipe_pack.py`:

```python
CRAFTABLE_TYPES = ("minecraft:crafting_shaped", "minecraft:crafting_shapeless")


class Converter:
    """Turns raw recipe JSON into pack recipe bodies.

    Only the two 3x3 crafting types are convertible. Smelting, blasting, smoking,
    campfire cooking, stonecutting and smithing are not 3x3 crafts, and the
    crafting_special_* recipes are hardcoded in Java with no data to read.
    """

    def __init__(self):
        self.items = ItemTable()
        self.synthetic_tags = {}
        self._alt_by_signature = {}

    def _reference(self, ingredient):
        """Resolve one ingredient to a pack reference: an item index, or a tag name."""
        if isinstance(ingredient, list):
            return self._alternation(ingredient)
        if "tag" in ingredient:
            return ingredient["tag"]
        return self.items.index(ingredient["item"])

    def _alternation(self, options):
        """Collapse an alternation list into a synthetic tag, so the runtime has one
        ambiguity mechanism instead of two. Identical lists share a tag."""
        members = []
        for option in options:
            if "tag" in option:
                members.append("#" + option["tag"])
            else:
                members.append(option["item"])
        signature = tuple(members)
        existing = self._alt_by_signature.get(signature)
        if existing is not None:
            return existing
        name = "@alt:%d" % (len(self._alt_by_signature) + 1)
        self._alt_by_signature[signature] = name
        self.synthetic_tags[name] = members
        return name

    def convert(self, recipe_id, recipe):
        kind = recipe.get("type")
        if kind not in CRAFTABLE_TYPES:
            return None
        result = recipe.get("result") or {}
        output_id = result.get("item")
        if not output_id:
            return None
        body = {
            "id": recipe_id,
            "output": self.items.index(output_id),
            "output_id": output_id,
            "count": int(result.get("count", 1)),
            "shaped": kind == "minecraft:crafting_shaped",
        }
        if body["shaped"]:
            body["grid"] = self._grid(recipe)
        else:
            body["ingredients"] = [
                self._reference(entry) for entry in recipe.get("ingredients", [])
            ]
        return body

    def _grid(self, recipe):
        """Expand a pattern into a fixed 9-cell grid, left- and top-aligned.

        turtle.craft() reads turtle slots 1-3, 5-7 and 9-11 as the 3x3 grid, so the
        pack stores position explicitly rather than making the runtime re-derive it
        from a ragged pattern.
        """
        key = recipe.get("key", {})
        grid = [0] * 9
        for row, line in enumerate(recipe.get("pattern", [])):
            for column, symbol in enumerate(line):
                if symbol == " ":
                    continue
                grid[row * 3 + column] = self._reference(key[symbol])
        return grid
```

- [ ] **Step 4: Run to confirm pass**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/tools && python -m unittest test_recipe_pack -v
```

Expected: `Ran 15 tests` ... `OK`

- [ ] **Step 5: Commit**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline && git add tools/recipe_pack.py tools/test_recipe_pack.py && git commit -m "feat: convert shaped and shapeless recipes to pack bodies"
```

---

## Task 4: Emit the Lua pack

**Files:**
- Modify: `tools/recipe_pack.py`
- Modify: `tools/test_recipe_pack.py`

- [ ] **Step 1: Write the failing tests**

The emitted files are `require`d by CC's Lua 5.2, so they must be plain table literals with no 5.3+ syntax. Append to `tools/test_recipe_pack.py`:

```python
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
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/tools && python -m unittest test_recipe_pack -v
```

Expected: `ImportError: cannot import name 'lua_value' from 'recipe_pack'`

- [ ] **Step 3: Implement**

Append to `tools/recipe_pack.py`:

```python
def lua_value(value):
    """Render a Python value as a Lua 5.2-compatible literal.

    Table keys are sorted so regenerating an unchanged pack produces an identical
    file and shows up as no diff.
    """
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return '"%s"' % escaped
    if isinstance(value, list):
        return "{%s}" % ",".join(lua_value(entry) for entry in value)
    if isinstance(value, dict):
        parts = []
        for key in sorted(value, key=str):
            parts.append("[%s]=%s" % (lua_value(key), lua_value(value[key])))
        return "{%s}" % ",".join(parts)
    raise TypeError("cannot render %r as Lua" % (value,))


def build_pack(recipes, raw_tags, lang, shard_count=4):
    """Convert every craftable recipe and assemble the emitted pack structure."""
    converter = Converter()
    flat_tags = flatten_tags(raw_tags)

    bodies = []
    for recipe_id in sorted(recipes):
        body = converter.convert(recipe_id, recipes[recipe_id])
        if body is not None:
            bodies.append(body)

    # Synthetic alternation tags reference real tags with a leading '#', so resolve
    # them against the already-flattened vanilla tags.
    for name, members in converter.synthetic_tags.items():
        resolved = []
        for member in members:
            if member.startswith("#"):
                resolved.extend(flat_tags.get(member[1:], []))
            else:
                resolved.append(member)
        flat_tags[name] = sorted(set(resolved))

    referenced = set()
    for body in bodies:
        for reference in body.get("grid", []) + body.get("ingredients", []):
            if isinstance(reference, str):
                referenced.add(reference)

    tags = {}
    for name in sorted(referenced):
        members = [converter.items.index(item) for item in flat_tags.get(name, [])]
        tags[name] = sorted(members)

    shards = {}
    outputs = set()
    for body in bodies:
        outputs.add(body["output"])
        shard = 1 + (body["output"] % shard_count)
        shards.setdefault(shard, []).append(
            {key: body[key] for key in body if key != "output_id"}
        )

    ids = converter.items.ids()
    return {
        "items": {"schema": 1, "ids": ids, "names": display_names(ids, lang)},
        "index": {"schema": 1, "pack": "vanilla-1.18.2",
                  "shard_count": shard_count, "outputs": sorted(outputs)},
        "tags": {"schema": 1, "tags": tags},
        "shards": shards,
        "shard_count": shard_count,
    }


HEADER = "-- generated by tools/recipe_import.py -- do not edit by hand\n"


def render_pack(pack):
    """Render the pack structure to {filename: Lua source}."""
    files = {
        "items.lua": HEADER + "return " + lua_value(pack["items"]) + "\n",
        "index.lua": HEADER + "return " + lua_value(pack["index"]) + "\n",
        "tags.lua": HEADER + "return " + lua_value(pack["tags"]) + "\n",
    }
    for shard in range(1, pack["shard_count"] + 1):
        body = {"schema": 1, "recipes": pack["shards"].get(shard, [])}
        files["pack_%02d.lua" % shard] = HEADER + "return " + lua_value(body) + "\n"
    return files
```

- [ ] **Step 4: Run to confirm pass**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/tools && python -m unittest test_recipe_pack -v
```

Expected: `Ran 25 tests` ... `OK`

- [ ] **Step 5: Commit**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline && git add tools/recipe_pack.py tools/test_recipe_pack.py && git commit -m "feat: render the recipe pack as Lua source"
```

---

## Task 5: The converter CLI

**Files:**
- Create: `tools/recipe_import.py`

- [ ] **Step 1: Write the CLI**

This is thin glue over the tested logic, so it gets a smoke run against the real jar rather than unit tests. The nested-jar handling is the part that matters: the 1.18.2 server jar is a Mojang *bundler* and contains only 104 entries; the real 9082-entry jar is inside it.

```python
"""Convert Minecraft crafting recipes into the controller's Lua recipe pack.

Reads the server jar READ-ONLY. Never writes anywhere near the live server.

    python tools/recipe_import.py --jar "C:/Servers/.../server-1.18.2.jar" \
        --out controller/colossal/recipes
"""

import argparse
import io
import json
import os
import zipfile

from recipe_pack import build_pack, render_pack

BUNDLER_PREFIX = "META-INF/versions/"


def open_data_jar(path):
    """Return a ZipFile holding data/ and assets/.

    Mojang ships the 1.18.2 server as a bundler whose real jar is nested at
    META-INF/versions/<version>/server-<version>.jar. Opening the outer jar
    directly finds zero recipes, which is silent and confusing, so unwrap it.
    """
    outer = zipfile.ZipFile(path)
    if any(name.startswith("data/minecraft/recipes/") for name in outer.namelist()):
        return outer
    nested = [
        name for name in outer.namelist()
        if name.startswith(BUNDLER_PREFIX) and name.endswith(".jar")
    ]
    if not nested:
        raise SystemExit("no recipe data and no nested jar in %s" % path)
    return zipfile.ZipFile(io.BytesIO(outer.read(sorted(nested)[0])))


def read_namespace(jar, namespace):
    recipes, tags = {}, {}
    recipe_root = "data/%s/recipes/" % namespace
    tag_root = "data/%s/tags/items/" % namespace
    for name in jar.namelist():
        if name.startswith(recipe_root) and name.endswith(".json"):
            key = "%s:%s" % (namespace, name[len(recipe_root):-5])
            recipes[key] = json.loads(jar.read(name))
        elif name.startswith(tag_root) and name.endswith(".json"):
            key = "%s:%s" % (namespace, name[len(tag_root):-5])
            tags[key] = json.loads(jar.read(name)).get("values", [])
    return recipes, tags


def read_lang(jar):
    for name in jar.namelist():
        if name.endswith("lang/en_us.json"):
            return json.loads(jar.read(name))
    return {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jar", required=True, help="server or mod jar to read")
    parser.add_argument("--out", required=True, help="output directory for the pack")
    parser.add_argument("--namespace", default="minecraft")
    parser.add_argument("--shards", type=int, default=4)
    args = parser.parse_args()

    jar = open_data_jar(args.jar)
    recipes, tags = read_namespace(jar, args.namespace)
    if not recipes:
        raise SystemExit("no recipes found for namespace %s" % args.namespace)

    pack = build_pack(recipes, tags, read_lang(jar), shard_count=args.shards)
    files = render_pack(pack)

    os.makedirs(args.out, exist_ok=True)
    for name, text in sorted(files.items()):
        target = os.path.join(args.out, name)
        with open(target, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        print("wrote %s (%d bytes)" % (target, len(text)))
    print("%d recipes, %d outputs, %d tags, %d items" % (
        sum(len(bodies) for bodies in pack["shards"].values()),
        len(pack["index"]["outputs"]),
        len(pack["tags"]["tags"]),
        len(pack["items"]["ids"]),
    ))


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Generate the real pack**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline && python tools/recipe_import.py --jar "C:/Servers/Wold's Vaults/libraries/net/minecraft/server/1.18.2/server-1.18.2.jar" --out controller/colossal/recipes
```

Expected: four `wrote ...` lines plus a summary reporting **726 recipes** and **639 outputs**. If the recipe count is 0, the bundler unwrap failed.

- [ ] **Step 3: Verify every emitted file is loadable Lua**

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && for f in colossal/recipes/*.lua; do luac -p "$f" || echo "SYNTAX FAIL $f"; done && echo "all parsed"
```

Expected: `all parsed` with no `SYNTAX FAIL` lines.

- [ ] **Step 4: Check the pack fits the CC computer space limit**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && du -cb colossal/recipes/*.lua | tail -1
```

Expected: total well under 1,000,000 bytes. If it exceeds ~400,000, stop and reconsider the encoding before continuing.

- [ ] **Step 5: Commit**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline && git add tools/recipe_import.py controller/colossal/recipes && git commit -m "feat: add the recipe converter CLI and generate the vanilla pack"
```

---

## Task 6: Recipe repo — load and query outputs

**Files:**
- Create: `controller/colossal/core/recipe_repo.lua`
- Create: `controller/colossal/tests/test_recipe_repo.lua`
- Modify: `controller/colossal/tests/run.lua`

- [ ] **Step 1: Write the failing test**

Create `controller/colossal/tests/test_recipe_repo.lua`. The repo takes an injected loader so tests never depend on the generated pack.

```lua
local RecipeRepo = require("core.recipe_repo")
local T = require("tests.mock_cc")

local function pack()
    return {
        items = {schema=1, ids={"minecraft:oak_planks","minecraft:chest","minecraft:stick"},
            names={"Oak Planks","Chest","Stick"}},
        index = {schema=1, pack="test", shard_count=2, outputs={2,3}},
        tags  = {schema=1, tags={["minecraft:planks"]={1}}},
        shards = {
            [1] = {schema=1, recipes={
                {id="minecraft:stick", output=3, count=4, shaped=false,
                 ingredients={"minecraft:planks","minecraft:planks"}},
            }},
            [2] = {schema=1, recipes={
                {id="minecraft:chest", output=2, count=1, shaped=true,
                 grid={"minecraft:planks","minecraft:planks","minecraft:planks",
                       "minecraft:planks",0,"minecraft:planks",
                       "minecraft:planks","minecraft:planks","minecraft:planks"}},
            }},
        },
    }
end

local function loaderFor(value, counter)
    return function(name)
        if counter then counter[name] = (counter[name] or 0) + 1 end
        if name == "items" then return value.items end
        if name == "index" then return value.index end
        if name == "tags" then return value.tags end
        local shard = name:match("^pack_(%d+)$")
        if shard then return value.shards[tonumber(shard)] end
        return nil
    end
end

return {
    {name="repo lists every craftable output with its display name",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack())})
        local outputs = repo:outputs()
        T.equal(#outputs, 2)
        T.equal(outputs[1].item, "minecraft:chest")
        T.equal(outputs[1].display_name, "Chest")
        T.equal(outputs[2].item, "minecraft:stick")
    end},
    {name="repo reports whether an item is craftable",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack())})
        T.equal(repo:isCraftable("minecraft:chest"), true)
        T.equal(repo:isCraftable("minecraft:oak_planks"), false)
        T.equal(repo:isCraftable("minecraft:nonexistent"), false)
    end},
    {name="repo resolves an item id to its display name",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack())})
        T.equal(repo:displayName("minecraft:oak_planks"), "Oak Planks")
        T.equal(repo:displayName("minecraft:unknown"), "minecraft:unknown")
    end},
    {name="repo boots with an empty pack rather than failing",run=function()
        local repo = RecipeRepo.new({loader=function() return nil end})
        T.arrayEqual(repo:outputs(), {})
        T.equal(repo:isCraftable("minecraft:chest"), false)
    end},
}
```

- [ ] **Step 2: Register the module in the runner**

In `controller/colossal/tests/run.lua`, add `"tests.test_recipe_repo",` immediately after the line `"tests.test_planner",`.

- [ ] **Step 3: Run to confirm failure**

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && lua colossal/tests/run.lua tests.test_recipe_repo
```

Expected: `FAIL tests.test_recipe_repo load: ...module 'core.recipe_repo' not found`

- [ ] **Step 4: Implement**

Create `controller/colossal/core/recipe_repo.lua`. Lua 5.2 compatible: no `//`, no bitwise operators.

```lua
local RecipeRepo = {}
RecipeRepo.__index = RecipeRepo

-- The generated pack is deployed code under colossal/recipes/, not mutable data,
-- so it is required rather than read through shared/store.lua. A missing or broken
-- pack must never stop the controller booting: crafting simply reports nothing
-- craftable, exactly as a missing metadata cache degrades to re-learning.
local function defaultLoader(name)
    local ok, value = pcall(require, "recipes." .. name)
    if not ok or type(value) ~= "table" then return nil end
    return value
end

function RecipeRepo.new(deps)
    deps = deps or {}
    local self = setmetatable({
        loader = deps.loader or defaultLoader,
        shards = {}, byOutput = nil,
    }, RecipeRepo)
    self.items = self.loader("items") or {ids={}, names={}}
    self.index = self.loader("index") or {outputs={}, shard_count=1}
    self.tagData = self.loader("tags") or {tags={}}
    self.indexById = {}
    for position, id in ipairs(self.items.ids or {}) do self.indexById[id] = position end
    return self
end

function RecipeRepo:itemAt(position)
    return (self.items.ids or {})[position]
end

function RecipeRepo:displayName(itemId)
    local position = self.indexById[itemId]
    if not position then return itemId end
    return (self.items.names or {})[position] or itemId
end

function RecipeRepo:outputs()
    local result = {}
    for _, position in ipairs(self.index.outputs or {}) do
        local id = self:itemAt(position)
        if id then
            result[#result + 1] = {item=id, display_name=self:displayName(id)}
        end
    end
    table.sort(result, function(left, right) return left.item < right.item end)
    return result
end

function RecipeRepo:isCraftable(itemId)
    local position = self.indexById[itemId]
    if not position then return false end
    for _, output in ipairs(self.index.outputs or {}) do
        if output == position then return true end
    end
    return false
end

return RecipeRepo
```

- [ ] **Step 5: Run to confirm pass**

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && lua colossal/tests/run.lua tests.test_recipe_repo
```

Expected: `RESULT 4 passed, 0 failed`

- [ ] **Step 6: Commit**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline && git add controller/colossal/core/recipe_repo.lua controller/colossal/tests/test_recipe_repo.lua controller/colossal/tests/run.lua && git commit -m "feat: load the recipe pack and query craftable outputs"
```

---

## Task 7: Recipe repo — lazy shards and tag expansion

**Files:**
- Modify: `controller/colossal/core/recipe_repo.lua`
- Modify: `controller/colossal/tests/test_recipe_repo.lua`

- [ ] **Step 1: Write the failing tests**

Append these entries inside the returned table in `controller/colossal/tests/test_recipe_repo.lua`, before the closing `}`:

```lua
    {name="repo returns recipe bodies for an output",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack())})
        local recipes = repo:recipesFor("minecraft:chest")
        T.equal(#recipes, 1)
        T.equal(recipes[1].id, "minecraft:chest")
        T.equal(recipes[1].shaped, true)
        T.equal(recipes[1].count, 1)
        T.equal(#recipes[1].grid, 9)
    end},
    {name="repo loads only the shard an output maps to, and caches it",run=function()
        local counter = {}
        local repo = RecipeRepo.new({loader=loaderFor(pack(), counter)})
        repo:recipesFor("minecraft:chest")
        repo:recipesFor("minecraft:chest")
        T.equal(counter["pack_2"], 1, "shard should load once")
        T.equal(counter["pack_1"], nil, "unrelated shard must not load")
    end},
    {name="repo expands a tag reference to concrete item ids",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack())})
        T.arrayEqual(repo:expand("minecraft:planks"), {"minecraft:oak_planks"})
        T.arrayEqual(repo:expand("minecraft:missing"), {})
    end},
    {name="repo resolves an ingredient reference of either form",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack())})
        T.arrayEqual(repo:resolve("minecraft:planks"), {"minecraft:oak_planks"})
        T.arrayEqual(repo:resolve(2), {"minecraft:chest"})
        T.arrayEqual(repo:resolve(0), {})
    end},
    {name="repo returns nothing for an unknown output",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack())})
        T.arrayEqual(repo:recipesFor("minecraft:nonexistent"), {})
    end},
    {name="repo survives a shard that fails to load",run=function()
        local value = pack()
        value.shards[2] = nil
        local repo = RecipeRepo.new({loader=loaderFor(value)})
        T.arrayEqual(repo:recipesFor("minecraft:chest"), {})
    end},
```

- [ ] **Step 2: Run to confirm failure**

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && lua colossal/tests/run.lua tests.test_recipe_repo
```

Expected: failures reporting `attempt to call a nil value (method 'recipesFor')`

- [ ] **Step 3: Implement**

Add these methods to `controller/colossal/core/recipe_repo.lua`, immediately before the final `return RecipeRepo`:

```lua
-- A recipe lives in shard 1 + (output_index % shard_count), so every recipe for one
-- output shares a shard and resolving an output costs exactly one file load.
-- math.floor keeps this Lua 5.2 safe; '//' does not exist there.
function RecipeRepo:_shardFor(position)
    local count = self.index.shard_count or 1
    if count < 1 then count = 1 end
    return 1 + (position - math.floor(position / count) * count)
end

function RecipeRepo:_shard(number)
    local cached = self.shards[number]
    if cached ~= nil then return cached end
    local loaded = self.loader(("pack_%d"):format(number))
    if type(loaded) ~= "table" or type(loaded.recipes) ~= "table" then
        loaded = {recipes = {}}
    end
    self.shards[number] = loaded
    return loaded
end

function RecipeRepo:recipesFor(itemId)
    local position = self.indexById[itemId]
    if not position then return {} end
    local result = {}
    for _, body in ipairs(self:_shard(self:_shardFor(position)).recipes) do
        if body.output == position then result[#result + 1] = body end
    end
    return result
end

function RecipeRepo:expand(tagName)
    local members = (self.tagData.tags or {})[tagName]
    if type(members) ~= "table" then return {} end
    local result = {}
    for _, position in ipairs(members) do
        local id = self:itemAt(position)
        if id then result[#result + 1] = id end
    end
    return result
end

-- An ingredient reference is a tag name, an item index, or 0 for an empty cell.
-- Collapsing both forms here means the planner never branches on reference type.
function RecipeRepo:resolve(reference)
    if type(reference) == "string" then return self:expand(reference) end
    if type(reference) == "number" and reference > 0 then
        local id = self:itemAt(reference)
        if id then return {id} end
    end
    return {}
end
```

- [ ] **Step 4: Run to confirm pass**

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && lua colossal/tests/run.lua tests.test_recipe_repo
```

Expected: `RESULT 10 passed, 0 failed`

- [ ] **Step 5: Verify the shard rule against the real generated pack**

The Python side computes `1 + (output % shard_count)` and the Lua side must agree exactly, or recipes become unreachable in production while every unit test still passes.

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && lua -e 'package.path="colossal/?.lua;"..package.path; local R=require("core.recipe_repo").new({}); local outs=R:outputs(); local missing=0; for _,entry in ipairs(outs) do if #R:recipesFor(entry.item)==0 then missing=missing+1 end end; print(#outs.." outputs, "..missing.." unreachable")'
```

Expected: `639 outputs, 0 unreachable`. Any non-zero `unreachable` means the two shard formulas disagree.

- [ ] **Step 6: Commit**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline && git add controller/colossal/core/recipe_repo.lua controller/colossal/tests/test_recipe_repo.lua && git commit -m "feat: lazily load recipe shards and expand tag references"
```

---

## Task 8: Recipe repo — merge custom recipes

**Files:**
- Modify: `controller/colossal/core/recipe_repo.lua`
- Modify: `controller/colossal/tests/test_recipe_repo.lua`

- [ ] **Step 1: Write the failing tests**

Custom recipes are hand-written, so they name items by ID (`"minecraft:oak_planks"`) and tags with a leading hash (`"#minecraft:planks"`). The repo **normalizes them into the exact shape generated recipes have** at load time, so nothing downstream ever has to ask where a recipe came from.

Append inside the returned table in `controller/colossal/tests/test_recipe_repo.lua`:

```lua
    {name="custom recipes take precedence over the generated pack",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack()), custom={
            schema=1, recipes={
                {id="custom:chest", output_item="minecraft:chest", count=2, shaped=false,
                 ingredient_items={"minecraft:oak_planks"}},
            }}})
        local recipes = repo:recipesFor("minecraft:chest")
        T.equal(#recipes, 1, "generated recipe must be replaced, not appended")
        T.equal(recipes[1].id, "custom:chest")
        T.equal(recipes[1].count, 2)
    end},
    {name="a custom recipe is normalised into generated-recipe shape",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack()), custom={
            schema=1, recipes={
                {id="custom:chest", output_item="minecraft:chest", count=2, shaped=false,
                 ingredient_items={"minecraft:oak_planks","#minecraft:planks"}},
            }}})
        local body = repo:recipesFor("minecraft:chest")[1]
        T.equal(body.output_item, nil, "raw hand-written fields must not survive")
        T.equal(body.ingredient_items, nil)
        T.equal(body.output, repo:indexOf("minecraft:chest"))
        T.arrayEqual(repo:resolve(body.ingredients[1]), {"minecraft:oak_planks"})
        T.arrayEqual(repo:resolve(body.ingredients[2]), {"minecraft:oak_planks"})
    end},
    {name="a custom shaped recipe normalises its grid to nine cells",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack()), custom={
            schema=1, recipes={
                {id="custom:torch", output_item="minecraft:torch", count=4, shaped=true,
                 grid_items={"minecraft:stick"}},
            }}})
        local body = repo:recipesFor("minecraft:torch")[1]
        T.equal(#body.grid, 9)
        T.arrayEqual(repo:resolve(body.grid[1]), {"minecraft:stick"})
        T.equal(body.grid[2], 0)
        T.equal(body.grid[9], 0)
    end},
    {name="custom recipes add outputs the generated pack lacks",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack()), custom={
            schema=1, recipes={
                {id="custom:widget", output_item="minecraft:widget", count=1, shaped=false,
                 ingredient_items={"minecraft:stick"}},
            }}})
        T.equal(repo:isCraftable("minecraft:widget"), true)
        T.equal(#repo:recipesFor("minecraft:widget"), 1)
        local found=false
        for _,entry in ipairs(repo:outputs()) do
            if entry.item=="minecraft:widget" then found=true end
        end
        T.equal(found, true, "new output must appear in the search corpus")
    end},
    {name="an output untouched by custom recipes still resolves from its shard",run=function()
        local repo = RecipeRepo.new({loader=loaderFor(pack()), custom={
            schema=1, recipes={
                {id="custom:widget", output_item="minecraft:widget", count=1, shaped=false,
                 ingredient_items={"minecraft:stick"}},
            }}})
        T.equal(#repo:recipesFor("minecraft:stick"), 1)
        T.equal(repo:recipesFor("minecraft:stick")[1].id, "minecraft:stick")
    end},
    {name="an invalid custom file is ignored rather than fatal",run=function()
        for _, bad in ipairs({{schema=2, recipes={}}, {schema=1}, "nonsense",
            {schema=1, recipes="no"}, {schema=1, recipes={{id="x"}}}}) do
            local repo = RecipeRepo.new({loader=loaderFor(pack()), custom=bad})
            T.equal(repo:isCraftable("minecraft:chest"), true)
            T.equal(repo:recipesFor("minecraft:chest")[1].id, "minecraft:chest")
        end
    end},
    {name="custom recipe validation names the field that is wrong",run=function()
        local ok, reason = RecipeRepo.validateCustom({schema=1, recipes={{id="x"}}})
        T.equal(ok, nil)
        T.contains(reason, "output_item")
        T.equal(RecipeRepo.validateCustom({schema=1, recipes={}}), true)
    end},
```

- [ ] **Step 2: Run to confirm failure**

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && lua colossal/tests/run.lua tests.test_recipe_repo
```

Expected: failures reporting `generated recipe must be replaced, not appended`

- [ ] **Step 3: Implement**

Add to `controller/colossal/core/recipe_repo.lua` before `return RecipeRepo`:

```lua
-- Custom recipes are hand-edited under colossal/data/, so they name items by ID and
-- tags with a leading '#'. Validation covers exactly the fields the loader will
-- dereference; anything looser would fail later, further from the mistake.
function RecipeRepo.validateCustom(value)
    if type(value) ~= "table" or value.schema ~= 1 or type(value.recipes) ~= "table" then
        return nil, "custom recipe schema is invalid"
    end
    for position, body in ipairs(value.recipes) do
        local label = "custom recipe " .. position
        if type(body) ~= "table" then return nil, label .. " must be a table" end
        if type(body.id) ~= "string" or body.id == "" then
            return nil, label .. " requires an id"
        end
        if type(body.output_item) ~= "string" or body.output_item == "" then
            return nil, label .. " requires an output_item"
        end
        if type(body.count) ~= "number" or body.count < 1 or body.count % 1 ~= 0 then
            return nil, label .. " requires a positive integer count"
        end
        local list = body.shaped and body.grid_items or body.ingredient_items
        if type(list) ~= "table" then
            return nil, label .. " requires grid_items or ingredient_items"
        end
    end
    return true
end
```

Then, still in `recipe_repo.lua`, add custom handling. Replace the whole `RecipeRepo.new` function with:

```lua
function RecipeRepo.new(deps)
    deps = deps or {}
    local self = setmetatable({
        loader = deps.loader or defaultLoader,
        shards = {}, custom = {}, customOutputs = {},
    }, RecipeRepo)
    self.items = self.loader("items") or {ids={}, names={}}
    self.index = self.loader("index") or {outputs={}, shard_count=1}
    self.tagData = self.loader("tags") or {tags={}}
    self.indexById = {}
    for position, id in ipairs(self.items.ids or {}) do self.indexById[id] = position end
    self:_loadCustom(deps.custom)
    return self
end

function RecipeRepo:indexOf(itemId) return self.indexById[itemId] end

-- Interning a hand-written item ID that the generated pack never mentioned extends
-- the items table. names has no entry for it, so displayName falls back to the raw
-- ID, which is correct: nothing knows a nicer name for it.
function RecipeRepo:_intern(itemId)
    local existing = self.indexById[itemId]
    if existing then return existing end
    self.items.ids[#self.items.ids + 1] = itemId
    local assigned = #self.items.ids
    self.indexById[itemId] = assigned
    return assigned
end

-- "#minecraft:planks" is a tag reference and stays a string, minus the hash, because
-- that is how generated recipes encode a tag. Anything else is an item ID and becomes
-- an interned index. The result is byte-for-byte the shape a generated recipe has, so
-- no consumer ever branches on a recipe's origin.
function RecipeRepo:_customReference(entry)
    if entry == 0 or entry == nil then return 0 end
    if type(entry) ~= "string" or entry == "" then return 0 end
    if entry:sub(1, 1) == "#" then return entry:sub(2) end
    return self:_intern(entry)
end

function RecipeRepo:_loadCustom(value)
    if value == nil then return end
    if not RecipeRepo.validateCustom(value) then return end
    for _, body in ipairs(value.recipes) do
        local target = body.output_item
        local normalised = {
            id = body.id, count = body.count, shaped = body.shaped == true,
            output = self:_intern(target),
        }
        if normalised.shaped then
            normalised.grid = {}
            for cell = 1, 9 do
                normalised.grid[cell] = self:_customReference((body.grid_items or {})[cell])
            end
        else
            normalised.ingredients = {}
            for position, entry in ipairs(body.ingredient_items or {}) do
                normalised.ingredients[position] = self:_customReference(entry)
            end
        end
        if not self.custom[target] then
            self.custom[target] = {}
            self.customOutputs[#self.customOutputs + 1] = target
        end
        self.custom[target][#self.custom[target] + 1] = normalised
    end
end
```

Replace `RecipeRepo:recipesFor` with:

```lua
function RecipeRepo:recipesFor(itemId)
    local overridden = self.custom[itemId]
    if overridden then return overridden end
    local position = self.indexById[itemId]
    if not position then return {} end
    local result = {}
    for _, body in ipairs(self:_shard(self:_shardFor(position)).recipes) do
        if body.output == position then result[#result + 1] = body end
    end
    return result
end
```

Replace `RecipeRepo:isCraftable` with:

```lua
function RecipeRepo:isCraftable(itemId)
    if self.custom[itemId] then return true end
    local position = self.indexById[itemId]
    if not position then return false end
    for _, output in ipairs(self.index.outputs or {}) do
        if output == position then return true end
    end
    return false
end
```

Replace `RecipeRepo:outputs` with:

```lua
function RecipeRepo:outputs()
    local seen, result = {}, {}
    local function add(id)
        if id and not seen[id] then
            seen[id] = true
            result[#result + 1] = {item=id, display_name=self:displayName(id)}
        end
    end
    for _, position in ipairs(self.index.outputs or {}) do add(self:itemAt(position)) end
    for _, id in ipairs(self.customOutputs) do add(id) end
    table.sort(result, function(left, right) return left.item < right.item end)
    return result
end
```

- [ ] **Step 4: Run to confirm pass**

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && lua colossal/tests/run.lua tests.test_recipe_repo
```

Expected: `RESULT 17 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline && git add controller/colossal/core/recipe_repo.lua controller/colossal/tests/test_recipe_repo.lua && git commit -m "feat: merge hand-written custom recipes over the generated pack"
```

---

## Task 9: The craft preference store

**Files:**
- Create: `controller/colossal/core/craft_prefs.lua`
- Create: `controller/colossal/tests/test_craft_prefs.lua`
- Modify: `controller/colossal/tests/run.lua`

- [ ] **Step 1: Write the failing test**

Create `controller/colossal/tests/test_craft_prefs.lua`:

```lua
local CraftPrefs = require("core.craft_prefs")
local T = require("tests.mock_cc")

return {
    {name="preferences default to empty and validate",run=function()
        local value = CraftPrefs.default()
        T.equal(CraftPrefs.validate(value), true)
        T.equal(next(value.tags), nil)
        T.equal(next(value.recipes), nil)
    end},
    {name="a pinned tag choice round-trips",run=function()
        local prefs = CraftPrefs.new(CraftPrefs.default())
        prefs:pinTag("minecraft:planks", "minecraft:oak_planks")
        T.equal(prefs:tagChoice("minecraft:planks"), "minecraft:oak_planks")
        T.equal(prefs:tagChoice("minecraft:logs"), nil)
        T.equal(CraftPrefs.validate(prefs:value()), true)
    end},
    {name="a pinned recipe choice round-trips",run=function()
        local prefs = CraftPrefs.new(CraftPrefs.default())
        prefs:pinRecipe("minecraft:chest", "custom:chest")
        T.equal(prefs:recipeChoice("minecraft:chest"), "custom:chest")
    end},
    {name="pinning again replaces the previous choice",run=function()
        local prefs = CraftPrefs.new(CraftPrefs.default())
        prefs:pinTag("minecraft:planks", "minecraft:oak_planks")
        prefs:pinTag("minecraft:planks", "minecraft:birch_planks")
        T.equal(prefs:tagChoice("minecraft:planks"), "minecraft:birch_planks")
    end},
    {name="unpinning removes a choice",run=function()
        local prefs = CraftPrefs.new(CraftPrefs.default())
        prefs:pinTag("minecraft:planks", "minecraft:oak_planks")
        prefs:unpinTag("minecraft:planks")
        T.equal(prefs:tagChoice("minecraft:planks"), nil)
    end},
    {name="the store never returns its internal table",run=function()
        local prefs = CraftPrefs.new(CraftPrefs.default())
        prefs:pinTag("minecraft:planks", "minecraft:oak_planks")
        local copy = prefs:value()
        copy.tags["minecraft:planks"] = "tampered"
        T.equal(prefs:tagChoice("minecraft:planks"), "minecraft:oak_planks")
    end},
    {name="validation rejects malformed preference files",run=function()
        for _, bad in ipairs({
            {schema=2, tags={}, recipes={}},
            {schema=1, tags="no", recipes={}},
            {schema=1, tags={}, recipes="no"},
            {schema=1, tags={[1]="x"}, recipes={}},
            {schema=1, tags={a=2}, recipes={}},
            {schema=1, tags={a=""}, recipes={}},
        }) do
            T.equal(CraftPrefs.validate(bad), nil)
        end
        T.equal(CraftPrefs.validate(CraftPrefs.default()), true)
    end},
    {name="a corrupt preference file degrades to empty rather than failing",run=function()
        local prefs = CraftPrefs.new("nonsense")
        T.equal(prefs:tagChoice("minecraft:planks"), nil)
        T.equal(CraftPrefs.validate(prefs:value()), true)
    end},
}
```

- [ ] **Step 2: Register the module in the runner**

In `controller/colossal/tests/run.lua`, add `"tests.test_craft_prefs",` immediately after `"tests.test_recipe_repo",`.

- [ ] **Step 3: Run to confirm failure**

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && lua colossal/tests/run.lua tests.test_craft_prefs
```

Expected: `FAIL tests.test_craft_prefs load: ...module 'core.craft_prefs' not found`

- [ ] **Step 4: Implement**

Create `controller/colossal/core/craft_prefs.lua`:

```lua
local CraftPrefs = {}
CraftPrefs.__index = CraftPrefs

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

function CraftPrefs.default()
    return {schema=1, tags={}, recipes={}}
end

-- Preferences are operator convenience, never correctness, so a corrupt file must
-- degrade to "no pins" rather than block crafting. Same treatment as the metadata
-- cache: re-pinnable, never authoritative.
local function validateMap(map, label)
    if type(map) ~= "table" then return nil, label .. " must be a table" end
    for key, value in pairs(map) do
        if type(key) ~= "string" or key == "" then
            return nil, label .. " keys must be non-empty strings"
        end
        if type(value) ~= "string" or value == "" then
            return nil, label .. " values must be non-empty strings"
        end
    end
    return true
end

function CraftPrefs.validate(value)
    if type(value) ~= "table" or value.schema ~= 1 then
        return nil, "craft preference schema is invalid"
    end
    local tagsOk, tagsReason = validateMap(value.tags, "tag preferences")
    if not tagsOk then return nil, tagsReason end
    local recipesOk, recipesReason = validateMap(value.recipes, "recipe preferences")
    if not recipesOk then return nil, recipesReason end
    return true
end

function CraftPrefs.new(value)
    local stored = value
    if not CraftPrefs.validate(stored) then stored = CraftPrefs.default() end
    return setmetatable({value_ = copy(stored)}, CraftPrefs)
end

function CraftPrefs:value() return copy(self.value_) end

function CraftPrefs:tagChoice(tagName) return self.value_.tags[tagName] end
function CraftPrefs:recipeChoice(itemId) return self.value_.recipes[itemId] end

function CraftPrefs:pinTag(tagName, itemId) self.value_.tags[tagName] = itemId end
function CraftPrefs:unpinTag(tagName) self.value_.tags[tagName] = nil end

function CraftPrefs:pinRecipe(itemId, recipeId) self.value_.recipes[itemId] = recipeId end
function CraftPrefs:unpinRecipe(itemId) self.value_.recipes[itemId] = nil end

return CraftPrefs
```

- [ ] **Step 5: Run to confirm pass**

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && lua colossal/tests/run.lua tests.test_craft_prefs
```

Expected: `RESULT 8 passed, 0 failed`

- [ ] **Step 6: Commit**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline && git add controller/colossal/core/craft_prefs.lua controller/colossal/tests/test_craft_prefs.lua controller/colossal/tests/run.lua && git commit -m "feat: add the craft preference store"
```

---

## Task 10: Deployment manifest and full verification

**Files:**
- Modify: `controller/colossal/deployment_manifest.lua`
- Modify: `controller/colossal/tests/test_deployment.lua`

- [ ] **Step 1: Write the failing test**

Append inside the returned table in `controller/colossal/tests/test_deployment.lua`, before the closing `}`:

```lua
    {name="deployment manifest carries the recipe pack and crafting modules",run=function()
        local seen={}
        for _,path in ipairs(Manifest.files) do seen[path]=true end
        T.equal(seen["colossal/core/recipe_repo.lua"],true)
        T.equal(seen["colossal/core/craft_prefs.lua"],true)
        T.equal(seen["colossal/recipes/items.lua"],true)
        T.equal(seen["colossal/recipes/index.lua"],true)
        T.equal(seen["colossal/recipes/tags.lua"],true)
        T.equal(seen["colossal/recipes/pack_01.lua"],true)
    end},
    {name="hand-edited crafting state is never deployed",run=function()
        for _,path in ipairs({"colossal/data/custom_recipes.lua",
            "colossal/data/craft_prefs.lua","tools/recipe_import.py",
            "tools/recipe_pack.py"}) do
            T.equal(Manifest.allowed(path),false,path)
        end
    end},
```

- [ ] **Step 2: Run to confirm failure**

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && lua colossal/tests/run.lua tests.test_deployment
```

Expected: `FAIL deployment manifest carries the recipe pack and crafting modules: ... expected true, got nil`

- [ ] **Step 3: Implement**

In `controller/colossal/deployment_manifest.lua`, add these entries to the `files` list. Put the two `core/` modules with the other core files and the recipes at the end:

```lua
    "colossal/core/craft_prefs.lua",
    "colossal/core/recipe_repo.lua",
    "colossal/recipes/items.lua",
    "colossal/recipes/index.lua",
    "colossal/recipes/tags.lua",
    "colossal/recipes/pack_01.lua",
    "colossal/recipes/pack_02.lua",
    "colossal/recipes/pack_03.lua",
    "colossal/recipes/pack_04.lua",
```

The shard count is fixed at 4 here and in the converter's `--shards` default. If you ever change it, both this list and the default must change together.

- [ ] **Step 4: Run the deployment tests**

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && lua colossal/tests/run.lua tests.test_deployment
```

Expected: `RESULT 4 passed, 0 failed`

- [ ] **Step 5: Verify every manifest path actually exists on disk**

A manifest entry naming a missing file would fail at deployment time, not test time.

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && lua -e 'package.path="colossal/?.lua;"..package.path; local M=require("deployment_manifest"); local missing=0; for _,p in ipairs(M.files) do local h=io.open(p,"r"); if h then h:close() else print("MISSING "..p); missing=missing+1 end end; print(missing.." missing")'
```

Expected: `0 missing`

- [ ] **Step 6: Run the complete suite**

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && lua colossal/tests/run.lua; echo "exit=$?"
```

Expected: `RESULT 370 passed, 0 failed` and `exit=0`. Check the exit code — piping through `grep` would mask a failing suite.

- [ ] **Step 7: Run the Python suite once more**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/tools && python -m unittest test_recipe_pack -v 2>&1 | tail -3
```

Expected: `OK`

- [ ] **Step 8: Check whitespace**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline && git diff --check && echo "clean"
```

Expected: `clean`

- [ ] **Step 9: Commit**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline && git add controller/colossal/deployment_manifest.lua controller/colossal/tests/test_deployment.lua && git commit -m "feat: deploy the recipe pack and crafting modules"
```

---

## Task 11: Document the converter

**Files:**
- Modify: `docs/operations.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: Add a recipe pack section to `docs/operations.md`**

Append this section at the end of the file:

```markdown
## Regenerating the crafting recipe pack

The recipe pack under `controller/colossal/recipes/` is generated, not hand-written. It is
deployed like code and must never be edited directly; hand-written recipes belong in
`colossal/data/custom_recipes.lua`, which is preserved across deployments and takes precedence.

To regenerate from the vanilla server jar:

```
python tools/recipe_import.py \
  --jar "C:/Servers/Wold's Vaults/libraries/net/minecraft/server/1.18.2/server-1.18.2.jar" \
  --out controller/colossal/recipes
```

The 1.18.2 server jar is a Mojang bundler; the converter unwraps the nested jar at
`META-INF/versions/1.18.2/server-1.18.2.jar` automatically. Expect 726 recipes across 639
outputs. A count of 0 means the unwrap failed.

The jar is read read-only. Regenerating touches nothing on the live server.

Changing `--shards` requires updating the `colossal/recipes/pack_NN.lua` entries in
`deployment_manifest.lua` to match, or the new shards will not deploy.
```

- [ ] **Step 2: Add the converter to the repository layout in `AGENTS.md`**

In the `## Repository layout` section, after the line describing `controller/colossal/shared/`, insert:

```markdown
- `controller/colossal/recipes/` holds the generated crafting recipe pack; regenerate it with `tools/recipe_import.py` and never hand-edit it.
- `tools/` holds host-side build tooling that is never deployed.
```

- [ ] **Step 3: Verify the docs reference real paths**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline && ls tools/recipe_import.py controller/colossal/recipes/index.lua && echo "paths ok"
```

Expected: `paths ok`

- [ ] **Step 4: Commit**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline && git add docs/operations.md AGENTS.md && git commit -m "docs: describe regenerating the crafting recipe pack"
```

---

## Task 12: Merge

- [ ] **Step 1: Re-run the full suite on the branch**

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/.worktrees/recipe-pipeline/controller && lua colossal/tests/run.lua; echo "exit=$?"
```

Expected: `RESULT 370 passed, 0 failed`, `exit=0`

- [ ] **Step 2: Merge into main**

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage && git merge --no-ff feat/recipe-pipeline -m "feat: add the crafting recipe pipeline"
```

- [ ] **Step 3: Re-run the full suite on merged main**

`AGENTS.md` requires rerunning the suite on the merged tree, not only on the branch.

```bash
export PATH="/c/Users/Pellux/AppData/Local/Programs/Lua/bin:$PATH" && cd /c/Users/Pellux/Coding/computercraft-colossal-storage/controller && lua colossal/tests/run.lua; echo "exit=$?"
```

Expected: `RESULT 370 passed, 0 failed`, `exit=0`

- [ ] **Step 4: Remove the worktree**

Only after the commits are merged and verified.

```bash
cd /c/Users/Pellux/Coding/computercraft-colossal-storage && git worktree remove .worktrees/recipe-pipeline && git branch -d feat/recipe-pipeline
```

---

## Out of scope for this stage

Deliberately not built here, to keep the stage shippable on its own:

- The craft planner (stage 2) — multistep resolution, the reservation ledger, batch sizing.
- Wiring `recipe_repo` or `craft_prefs` into `main.lua` — nothing constructs them yet. Stage 2 does, when there is a planner to consume them.
- Loading `custom_recipes.lua` and `craft_prefs.lua` from disk through `shared/store.lua`. The repo and prefs modules accept injected values; the store wiring lands with the `main.lua` wiring in stage 2.
- Any KubeJS or mod-jar import. The converter already accepts `--namespace` and any jar, but exercising that is a later step.
