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
