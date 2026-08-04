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
