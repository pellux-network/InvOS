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
