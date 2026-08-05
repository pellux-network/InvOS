"""Pure conversion logic for turning Minecraft recipe JSON into a Lua pack.

Deliberately free of CLI parsing and file writes so it can be unit tested by
calling functions. tools/recipe_import.py is the thin CLI wrapper.
"""

import warnings


class Unconvertible(ValueError):
    """A recipe the pack cannot represent faithfully.

    A ValueError so the strict single-recipe contract callers already rely on is
    unchanged; `reason` lets a bulk import report what it left out and why.
    """

    def __init__(self, message, reason):
        super().__init__(message)
        self.reason = reason


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


CRAFTABLE_TYPES = ("minecraft:crafting_shaped", "minecraft:crafting_shapeless")


def normalise_type(kind):
    """A resource location with no namespace means minecraft:.

    Vanilla writes "minecraft:crafting_shaped"; a datapack may write plain
    "crafting_shaped", and the game treats them identically. Matching only the
    qualified form dropped 1,135 real grid recipes on the live modpack -- 146
    from mysticalagriculture alone, so whole mods looked uncraftable.
    """
    if not isinstance(kind, str):
        return ""
    return kind if ":" in kind else "minecraft:" + kind


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
        """Resolve one ingredient to a pack reference: an item index, or a tag name.

        Vanilla only ever writes {"item":...}, {"tag":...} or a list of those. Mods add
        custom ingredient types, and anything this cannot represent faithfully is refused
        rather than approximated: a recipe converted by ignoring the constraint it
        actually carries would craft from the wrong stack.
        """
        if isinstance(ingredient, list):
            return self._alternation(ingredient)
        if not isinstance(ingredient, dict):
            raise Unconvertible("ingredient is not an object", "malformed_ingredient")
        if "nbt" in ingredient:
            # forge:nbt and forge:partial_nbt demand a specific variant. Ingredient
            # matching in the controller is deliberately NBT-free, so this cannot be
            # honoured and must not be silently widened to "any variant".
            raise Unconvertible("ingredient constrains NBT", "nbt_ingredient")
        if "tag" in ingredient:
            return ingredient["tag"]
        if "item" not in ingredient:
            raise Unconvertible(
                "ingredient has neither item nor tag (type=%r)" % ingredient.get("type"),
                "custom_ingredient")
        return self.items.index(ingredient["item"])

    def _alternation(self, options):
        """Collapse an alternation list into a synthetic tag, so the runtime has one
        ambiguity mechanism instead of two. Identical lists share a tag."""
        members = []
        for option in options:
            if not isinstance(option, dict):
                raise Unconvertible("alternation option is not an object",
                                    "malformed_ingredient")
            if "nbt" in option:
                raise Unconvertible("alternation option constrains NBT", "nbt_ingredient")
            if "tag" in option:
                members.append("#" + option["tag"])
            elif "item" in option:
                members.append(option["item"])
            else:
                raise Unconvertible(
                    "alternation option has neither item nor tag (type=%r)"
                    % option.get("type"), "custom_ingredient")
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
        kind = normalise_type(kind)
        if kind not in CRAFTABLE_TYPES:
            return None
        result = recipe.get("result") or {}
        if not isinstance(result, dict):
            raise Unconvertible("result is not an object", "malformed_result")
        output_id = result.get("item")
        if not output_id:
            return None
        if "nbt" in result:
            # The output is a specific variant. The controller identifies the crafted item
            # by plain id, so it could neither verify nor deliver this correctly.
            raise Unconvertible("result carries NBT", "nbt_result")
        body = {
            "id": recipe_id,
            "output": self.items.index(output_id),
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
        pattern = recipe.get("pattern", [])
        if len(pattern) > 3:
            raise ValueError(
                "recipe pattern has %d rows, but the grid only has 3: %r"
                % (len(pattern), pattern)
            )
        for row, line in enumerate(pattern):
            if len(line) > 3:
                raise ValueError(
                    "recipe pattern row %r has %d columns, but the grid only has 3"
                    % (line, len(line))
                )
            for column, symbol in enumerate(line):
                if symbol == " ":
                    continue
                if symbol not in key:
                    raise Unconvertible(
                        "pattern uses %r but the key does not define it" % symbol,
                        "missing_key")
                grid[row * 3 + column] = self._reference(key[symbol])
        return grid


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
        escaped = (
            value.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t")
            .replace("\x00", "\\000")
        )
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
    if not isinstance(shard_count, int) or shard_count < 1:
        raise ValueError("shard_count must be a positive integer, got %r" % (shard_count,))

    converter = Converter()
    flat_tags = flatten_tags(raw_tags)

    # A whole-modpack import reads tens of thousands of recipes, and a handful will always
    # be shapes this cannot represent. Abandoning the run over one of them is far worse
    # than leaving it out and saying so, so the strict per-recipe contract is kept and the
    # tolerance lives here, where the count is visible.
    bodies, skipped = [], {}
    for recipe_id in sorted(recipes):
        try:
            body = converter.convert(recipe_id, recipes[recipe_id])
        except ValueError as exc:
            reason = getattr(exc, "reason", "invalid_recipe")
            skipped[reason] = skipped.get(reason, 0) + 1
            continue
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

    # A recipe can reference a tag the jar never defines -- vanilla never does
    # this, but a mod jar referencing another mod's tag can. That recipe becomes
    # unsatisfiable (its tag resolves to no items), which is worth flagging to
    # the operator, but not worth aborting generation over.
    undefined = sorted(name for name in referenced if name not in flat_tags)
    if undefined:
        warnings.warn(
            "recipes reference undefined tags (each becomes unsatisfiable): %s"
            % ", ".join(undefined)
        )

    tags = {}
    for name in sorted(referenced):
        members = [converter.items.index(item) for item in flat_tags.get(name, [])]
        tags[name] = sorted(members)

    shards = {}
    outputs = set()
    for body in bodies:
        outputs.add(body["output"])
        shard = 1 + (body["output"] % shard_count)
        shards.setdefault(shard, []).append(body)

    ids = converter.items.ids()
    return {
        "items": {"schema": 1, "ids": ids, "names": display_names(ids, lang)},
        "index": {"schema": 1, "pack": "vanilla-1.18.2",
                  "shard_count": shard_count, "outputs": sorted(outputs)},
        "tags": {"schema": 1, "tags": tags},
        "shards": shards,
        "shard_count": shard_count,
        "skipped": skipped,
    }


HEADER = "-- generated by tools/recipe_import.py -- do not edit by hand\n"


def render_pack(pack):
    """Render the pack structure to {filename: Lua source}.

    Callers must write these strings as UTF-8 with LF newlines: a naive
    open(path, "w") on Windows defaults to the system codepage and would
    mangle non-ASCII display names.
    """
    files = {
        "items.lua": HEADER + "return " + lua_value(pack["items"]) + "\n",
        "index.lua": HEADER + "return " + lua_value(pack["index"]) + "\n",
        "tags.lua": HEADER + "return " + lua_value(pack["tags"]) + "\n",
    }
    for shard in range(1, pack["shard_count"] + 1):
        files["pack_%02d.lua" % shard] = _render_shard(pack["shards"].get(shard, []))
    return files


def _render_shard(bodies):
    """Render one shard file with one recipe literal per line.

    At real vanilla scale a single-line table is a ~90KB unreadable blob; one
    line per recipe keeps regeneration diffs reviewable and gives a runtime
    parse error some locality.
    """
    lines = [HEADER.rstrip("\n"), "return {", "  schema = 1,", "  recipes = {"]
    for body in bodies:
        lines.append("    %s," % lua_value(body))
    lines.append("  },")
    lines.append("}")
    return "\n".join(lines) + "\n"
