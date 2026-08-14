"""Describe an emulated InvOS installation, and serialise it for the computer.

A scenario is the whole world a run starts from: which inventories exist, what
is in them, and what `storage/data/config.lua` says. Keeping that in one
declarative object means a smoke test reads as a statement about an
installation rather than a pile of setup calls, and means the same world can be
re-created byte for byte when a screenshot needs comparing.

Values cross into the emulator as a Lua table, written by :func:`to_lua`.
"""

DEFAULT_STOCK = [
    {"id": "the_vault:vault_rock", "count": 933},
    {"id": "minecraft:iron_ingot", "count": 4399},
    {"id": "minecraft:cobblestone", "count": 5045},
    {"id": "the_vault:vault_cobblestone", "count": 10882},
    {"id": "the_vault:larimar_gem", "count": 1515},
    {"id": "minecraft:stick", "count": 412},
    {"id": "the_vault:vault_diamond", "count": 42},
    {"id": "minecraft:diamond", "count": 244},
    {"id": "minecraft:firework_rocket", "count": 10},
    {"id": "minecraft:wheat", "count": 906},
]

# Display names the automatic prettifier would get wrong. Everything else falls
# back to title-casing the item id, which matches how these items read in game.
CATALOGUE = {
    "the_vault:vault_rock": {"displayName": "Vault Rock"},
    "the_vault:vault_cobblestone": {"displayName": "Vault Cobblestone"},
    "the_vault:larimar_gem": {"displayName": "Larimar Gem"},
    "the_vault:vault_diamond": {"displayName": "Vault Diamond"},
}


def lua_value(value, indent=0):
    """Serialise a Python value as a Lua literal."""
    pad = "    " * indent
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        escaped = (value.replace("\\", "\\\\").replace('"', '\\"')
                   .replace("\n", "\\n"))
        return '"%s"' % escaped
    if isinstance(value, (list, tuple)):
        if not value:
            return "{}"
        items = ",\n".join("%s    %s" % (pad, lua_value(v, indent + 1)) for v in value)
        return "{\n%s\n%s}" % (items, pad)
    if isinstance(value, dict):
        if not value:
            return "{}"
        parts = []
        for key, item in value.items():
            if isinstance(key, str) and key.replace("_", "a").isalnum():
                rendered_key = key
            else:
                rendered_key = "[%s]" % lua_value(key)
            parts.append("%s    %s = %s" % (pad, rendered_key, lua_value(item, indent + 1)))
        return "{\n%s\n%s}" % (",\n".join(parts), pad)
    raise TypeError("cannot serialise %r as Lua" % (value,))


class Scenario(object):
    """One emulated installation, ready to be written into a computer."""

    def __init__(self, inventories=None, config=None, data=None,
                 modem="back", catalogue=None, skip_splash=True, profile=False):
        self.inventories = inventories if inventories is not None else []
        self.config = config
        self.data = data or {}
        self.modem = modem
        self.catalogue = catalogue if catalogue is not None else dict(CATALOGUE)
        self.skip_splash = skip_splash
        self.profile = profile

    def to_lua(self):
        world = {
            "modem": self.modem,
            "inventories": self.inventories,
            "catalogue": self.catalogue,
            "profile": self.profile,
        }
        table = {"world": world, "skip_splash": self.skip_splash}
        if self.config is not None:
            table["config"] = self.config
        if self.data:
            table["data"] = self.data
        return "return %s\n" % lua_value(table)


def unconfigured():
    """A fresh computer with a network but no config: boots into the wizard."""
    return Scenario(
        inventories=[
            {"name": "minecraft:chest_0", "double": True},
            {"name": "minecraft:chest_1", "double": True},
            {"name": "minecraft:barrel_0"},
            {"name": "minecraft:barrel_1"},
        ],
        config=None,
    )


DOUBLE_CHEST_SLOTS = 54

# Stack limits that are not 64, mirrored from world.lua so the host can predict
# how many slots a stock list needs before the emulator refuses to fit it.
STACK_LIMITS = {
    "minecraft:ender_pearl": 16,
    "minecraft:snowball": 16,
    "minecraft:egg": 16,
    "minecraft:diamond_sword": 1,
    "minecraft:diamond_pickaxe": 1,
}


def _slots_for(entry):
    limit = entry.get("maxCount") or STACK_LIMITS.get(entry["id"], 64)
    count = entry.get("count", 1)
    return -(-count // limit)  # ceiling division


def distribute(stock, slots_per_inventory=DOUBLE_CHEST_SLOTS):
    """Split ``stock`` into per-inventory lists that each fit in one container.

    A single item type larger than one container is split across containers,
    which is what a real pooled store looks like once anything is stockpiled --
    and it is the case that exercises the controller's cross-node aggregation.
    """
    groups, current, used = [], [], 0
    for entry in stock:
        remaining = dict(entry)
        while _slots_for(remaining) > 0:
            free = slots_per_inventory - used
            if free <= 0:
                groups.append(current)
                current, used = [], 0
                continue
            limit = remaining.get("maxCount") or STACK_LIMITS.get(remaining["id"], 64)
            takeable = min(remaining["count"], free * limit)
            portion = dict(remaining)
            portion["count"] = takeable
            current.append(portion)
            used += _slots_for(portion)
            remaining["count"] -= takeable
            if remaining["count"] <= 0:
                break
    if current:
        groups.append(current)
    return groups


# Stock that exists in several NBT-distinct forms plus a plain form. InvOS keys
# identity on name plus NBT, so these are four distinct items that happen to
# share an item ID -- and the plain sword is the only one crafting will consider.
NBT_STOCK = [
    {"id": "minecraft:diamond_sword", "count": 3},
    {"id": "minecraft:diamond_sword", "count": 1, "nbt": "sharpness5",
     "displayName": "Diamond Sword"},
    {"id": "minecraft:diamond_sword", "count": 1, "nbt": "looting3",
     "displayName": "Diamond Sword"},
    {"id": "minecraft:diamond_pickaxe", "count": 1, "nbt": "efficiency4",
     "displayName": "Diamond Pickaxe"},
]


def with_nbt_variants(stock=None):
    """Default stock plus NBT-distinct variants of two tools.

    Used to exercise the paths that only exist because two items can share an
    ID: identity keying, per-variant search results, and crafting's decision to
    consider only the NBT-free form.
    """
    return (DEFAULT_STOCK if stock is None else list(stock)) + NBT_STOCK


def configured(stock=None, storage_count=None):
    """A commissioned installation with stock, which boots straight to Search."""
    stock = DEFAULT_STOCK if stock is None else stock
    groups = distribute(stock) or [[]]
    if storage_count is not None and storage_count > len(groups):
        groups += [[] for _ in range(storage_count - len(groups))]

    inventories = [
        {"name": "minecraft:barrel_0"},           # drop-off
        {"name": "minecraft:barrel_1"},           # pickup
    ]
    storage = []
    for index, group in enumerate(groups):
        name = "minecraft:chest_%d" % index
        inventories.append({"name": name, "double": True, "stock": group})
        storage.append({
            "id": "storage_%d" % index,
            "label": "Storage %d" % (index + 1),
            "peripheral_name": name,
            "priority": index + 1,
            "enabled": True,
        })

    config = {
        "schema": 2,
        "configured": True,
        # Setup.validateConfig requires both of these, by these names: an
        # installation missing them is rejected and the controller falls back to
        # the wizard rather than reporting a bad config.
        "installation": {"computer_id": 0, "computer_label": "InvOS Emulator"},
        "dropoff": {"peripheral_name": "minecraft:barrel_0"},
        "pickup": {"peripheral_name": "minecraft:barrel_1"},
        "storage": storage,
        "craft_buffer": None,
        "turtle": None,
        "monitors": None,
    }
    return Scenario(inventories=inventories, config=config)
