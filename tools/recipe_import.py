"""Convert Minecraft crafting recipes into the controller's Lua recipe pack.

Reads the server jar READ-ONLY. Never writes anywhere near the live server.

    python tools/recipe_import.py --jar "C:/Servers/.../server-1.18.2.jar" \
        --out controller/colossal/recipes
"""

import argparse
import io
import json
import os
import re
import zipfile

from recipe_pack import build_pack, render_pack

BUNDLER_PREFIX = "META-INF/versions/"
STALE_SHARD_RE = re.compile(r"^pack_(\d+)\.lua$")


def _recipe_root(namespace):
    return "data/%s/recipes/" % namespace


def open_data_jar(path, namespace):
    """Return an open ZipFile holding data/<namespace>/recipes/ (and assets/).

    Mojang ships the 1.18.2 server as a bundler whose real jar is nested at
    META-INF/versions/<version>/server-<version>.jar. Opening the outer jar
    directly finds zero recipes for "minecraft", which is silent and confusing,
    so unwrap it -- but only when the outer jar genuinely lacks data for the
    *requested* namespace. A shaded multi-release mod jar can carry both a
    bundler-style manifest and real recipe data in the outer jar; unwrapping
    unconditionally would discard the very data the caller asked for. When an
    unwrap is needed, prefer whichever nested jar actually contains data for
    the namespace, not just the lexicographically first one.

    The caller owns the returned ZipFile and is responsible for closing it
    (e.g. via `with`).
    """
    recipe_root = _recipe_root(namespace)
    try:
        outer = zipfile.ZipFile(path)
    except FileNotFoundError:
        raise SystemExit("jar not found: %s" % path)
    except zipfile.BadZipFile as exc:
        raise SystemExit("not a valid zip file: %s (%s)" % (path, exc))

    if any(name.startswith(recipe_root) for name in outer.namelist()):
        return outer

    nested = [
        name for name in outer.namelist()
        if name.startswith(BUNDLER_PREFIX) and name.endswith(".jar")
    ]
    try:
        for name in sorted(nested):
            try:
                candidate = zipfile.ZipFile(io.BytesIO(outer.read(name)))
            except zipfile.BadZipFile:
                continue
            if any(n.startswith(recipe_root) for n in candidate.namelist()):
                return candidate
            candidate.close()
        raise SystemExit(
            "no recipe data for namespace %r in %s or any nested jar" % (namespace, path)
        )
    finally:
        # Any nested jar we kept was already read fully into memory above, so
        # the outer handle is not needed past this point either way. This is a
        # live server directory; don't hold a read handle open longer than
        # necessary.
        outer.close()


def read_namespace(jar, namespace):
    recipes, tags = {}, {}
    recipe_root = _recipe_root(namespace)
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


# --------------------------------------------------------------- whole-pack scan
#
# Reading one namespace out of one jar is the vanilla case. A modpack is different: the
# craftable set is spread across every mod jar, under each mod's own namespace, and no
# single jar owns the item tags that recipes refer to.

RECIPE_RE = re.compile(r"^data/([a-z0-9_.-]+)/recipes/(.+)\.json$")
ITEM_TAG_RE = re.compile(r"^data/([a-z0-9_.-]+)/tags/items/(.+)\.json$")
LANG_RE = re.compile(r"^assets/([a-z0-9_.-]+)/lang/en_us\.json$")


def read_jar(jar):
    """Return (recipes, tags, lang, malformed_count) for every namespace in one jar.

    A single unparseable file is counted rather than raised. Across several hundred mod
    jars there is usually at least one, and abandoning the whole import over a recipe the
    converter would have skipped anyway is worse than reporting it.
    """
    recipes, tags, lang, malformed = {}, {}, {}, 0
    for name in jar.namelist():
        recipe = RECIPE_RE.match(name)
        tag = ITEM_TAG_RE.match(name)
        language = LANG_RE.match(name)
        if not (recipe or tag or language):
            continue
        try:
            body = json.loads(jar.read(name))
        except (ValueError, UnicodeDecodeError):
            malformed += 1
            continue
        if recipe:
            recipes["%s:%s" % (recipe.group(1), recipe.group(2))] = body
        elif tag:
            tags["%s:%s" % (tag.group(1), tag.group(2))] = {
                "replace": bool(body.get("replace", False)),
                "values": body.get("values", []) or [],
            }
        else:
            lang.update(body)
    return recipes, tags, lang, malformed


def merge_tags(accumulated, incoming):
    """Fold one jar's item tags into the running set.

    Tags accumulate. A tag like forge:ingots/iron is contributed to by every mod that adds
    an iron ingot and owned by none of them, so assigning instead of extending keeps only
    whichever jar happened to be read last -- and every recipe using that tag then resolves
    to a single item. Only an explicit "replace": true discards earlier contributions,
    which is exactly what it means in a datapack.
    """
    for key, entry in incoming.items():
        if entry["replace"]:
            accumulated[key] = list(entry["values"])
        else:
            accumulated.setdefault(key, []).extend(entry["values"])
    return accumulated


KUBEJS_SCHEMA = 1


def read_kubejs(path):
    """Read a runtime dump written by tools/kubejs/pellstore_export.js.

    This is authoritative in a way a jar scan cannot be. Around 10% of modded crafting
    recipes are gated behind `conditions`, and the common ones -- quark:flag,
    supplementaries:flag, thermal:flag, mysticalagriculture:* -- depend on each mod's
    config, which only exists at runtime. A jar scan reports both halves of a mutually
    exclusive pair, so the controller can plan a craft that produces a different item than
    it expects and then block on the mismatch.

    Tags arrive already resolved by the game, so nothing here needs flattening and nothing
    can disagree with what the server will accept.
    """
    try:
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except FileNotFoundError:
        raise SystemExit("kubejs dump not found: %s\n"
                         "         copy tools/kubejs/pellstore_export.js into "
                         "<server>/kubejs/server_scripts/ and run /reload" % path)
    except ValueError as exc:
        raise SystemExit("kubejs dump is not valid json: %s (%s)" % (path, exc))

    schema = payload.get("schema")
    if schema != KUBEJS_SCHEMA:
        raise SystemExit("kubejs dump schema %r is not supported (expected %d); "
                         "regenerate it with the current pellstore_export.js"
                         % (schema, KUBEJS_SCHEMA))

    recipes = {}
    for entry in payload.get("recipes") or []:
        recipe_id = entry.get("id")
        if not recipe_id:
            raise SystemExit("kubejs dump contains a recipe with no id")
        recipes[recipe_id] = entry.get("recipe") or {}

    tags = {}
    for name, items in (payload.get("tags") or {}).items():
        tags[name] = list(items)

    return recipes, tags, {"recipes": len(recipes), "tags": len(tags)}


def jar_paths(sources):
    """Expand a list of directories and/or jar files into a sorted list of jar paths.

    The mods directory is not the whole story: Forge itself ships the `forge:*` item tags
    (forge:ingots/iron and 192 others) from its own jar under libraries/, and thousands of
    modded recipes reference them. Leaving it out does not fail -- every one of those tags
    silently resolves to no items, and the recipes using them become uncraftable.
    """
    paths = []
    for source in sources:
        if os.path.isdir(source):
            found = sorted(name for name in os.listdir(source) if name.endswith(".jar"))
            if not found:
                raise SystemExit("no .jar files in %s" % source)
            paths.extend(os.path.join(source, name) for name in found)
        elif os.path.isfile(source):
            paths.append(source)
        else:
            raise SystemExit("not a directory or file: %s" % source)
    return paths


def read_mods(sources):
    """Scan every jar named by `sources`. Returns (recipes, tags, lang, report).

    Jars are read in sorted order so a repeated run produces byte-identical output; when
    two jars define the same recipe id the later one wins, which is reported rather than
    silently resolved.
    """
    if isinstance(sources, str):
        sources = [sources]
    recipes, tags, lang = {}, {}, {}
    report = {"jars": 0, "unreadable": [], "malformed": 0, "collisions": 0}
    for path in jar_paths(sources):
        name = os.path.basename(path)
        try:
            archive = zipfile.ZipFile(path)
        except (zipfile.BadZipFile, OSError):
            report["unreadable"].append(name)
            continue
        with archive:
            found, jarTags, jarLang, malformed = read_jar(archive)
        report["jars"] += 1
        report["malformed"] += malformed
        for key, body in found.items():
            if key in recipes:
                report["collisions"] += 1
            recipes[key] = body
        merge_tags(tags, jarTags)
        lang.update(jarLang)
    return recipes, tags, lang, report


def prune_stale_shards(out_dir, shard_count):
    """Remove pack_NN.lua files left behind by a previous run with more shards.

    Regenerating with a smaller --shards would otherwise leave e.g. pack_05.lua
    behind even though index.lua now declares a lower shard_count. Task 10
    deploys everything under this directory from a manifest, so an orphaned
    shard would ship to the live game computer. Returns the paths removed.
    """
    removed = []
    for name in sorted(os.listdir(out_dir)):
        match = STALE_SHARD_RE.match(name)
        if match and int(match.group(1)) > shard_count:
            path = os.path.join(out_dir, name)
            os.remove(path)
            removed.append(path)
    return removed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jar", help="server or mod jar to read")
    parser.add_argument("--mods", nargs="+", metavar="PATH",
                        help="directories and/or jar files to scan, across every "
                             "namespace. Pass the mods directory AND the Forge universal "
                             "jar: Forge owns the forge:* item tags that modded recipes "
                             "refer to. Combine with --jar to include vanilla.")
    parser.add_argument("--kubejs", metavar="DUMP",
                        help="a pellstore_recipes.json written by "
                             "tools/kubejs/pellstore_export.js. This is the recipe set the "
                             "game actually has, with conditions already resolved; prefer "
                             "it over --mods for a modpack. Pair with --mods to pick up "
                             "display names.")
    parser.add_argument("--out", required=True, help="output directory for the pack")
    parser.add_argument("--namespace", default="minecraft",
                        help="which namespace --jar is read for (ignored by --mods)")
    parser.add_argument("--shards", type=int, default=4)
    args = parser.parse_args()

    if not args.jar and not args.mods and not args.kubejs:
        raise SystemExit("nothing to read: pass --kubejs, --jar, --mods, or a combination")

    recipes, tags, lang = {}, {}, {}

    # Vanilla first, so a mod jar that deliberately overrides a vanilla recipe id wins.
    if args.jar:
        with open_data_jar(args.jar, args.namespace) as jar:
            found, jarTags = read_namespace(jar, args.namespace)
            if not found:
                raise SystemExit("no recipes found for namespace %s" % args.namespace)
            recipes.update(found)
            merge_tags(tags, {key: {"replace": False, "values": values}
                              for key, values in jarTags.items()})
            lang.update(read_lang(jar))
        print("%s: %d recipes" % (os.path.basename(args.jar), len(recipes)))

    if args.mods:
        modRecipes, modTags, modLang, report = read_mods(args.mods)
        for key, body in modRecipes.items():
            recipes[key] = body
        merge_tags(tags, {key: {"replace": False, "values": values}
                          for key, values in modTags.items()})
        lang.update(modLang)
        print("%d jars scanned, %d recipes, %d item tags" % (
            report["jars"], len(modRecipes), len(modTags)))
        if report["unreadable"]:
            print("  %d unreadable: %s" % (len(report["unreadable"]),
                                           ", ".join(report["unreadable"][:5])))
        if report["malformed"]:
            print("  %d malformed json files skipped" % report["malformed"])
        if report["collisions"]:
            print("  %d recipe ids defined more than once; the last jar won"
                  % report["collisions"])

    # Last, so the runtime set wins over anything read from disk: where they disagree, the
    # game is right and the jars are describing recipes that conditions turned off.
    if args.kubejs:
        liveRecipes, liveTags, report = read_kubejs(args.kubejs)
        if args.mods or args.jar:
            print("kubejs dump overrides %d of %d jar-read recipes"
                  % (sum(1 for key in liveRecipes if key in recipes), len(recipes)))
            recipes = {key: body for key, body in recipes.items() if key in liveRecipes}
        recipes.update(liveRecipes)
        # Resolved tags replace rather than extend: the game has already decided what each
        # tag contains, and adding jar-read members back would reintroduce items the
        # running server does not actually accept.
        for name, items in liveTags.items():
            tags[name] = items
        print("kubejs dump: %d recipes, %d resolved tags"
              % (report["recipes"], report["tags"]))

    if not recipes:
        raise SystemExit("no recipes found")

    try:
        pack = build_pack(recipes, tags, lang, shard_count=args.shards)
    except ValueError as exc:
        raise SystemExit(str(exc))

    files = render_pack(pack)

    os.makedirs(args.out, exist_ok=True)
    for name, text in sorted(files.items()):
        target = os.path.join(args.out, name)
        with open(target, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        print("wrote %s (%d bytes)" % (target, len(text.encode("utf-8"))))

    for path in prune_stale_shards(args.out, args.shards):
        print("removed stale shard %s" % path)

    print("%d recipes, %d outputs, %d tags, %d items" % (
        sum(len(bodies) for bodies in pack["shards"].values()),
        len(pack["index"]["outputs"]),
        len(pack["tags"]["tags"]),
        len(pack["items"]["ids"]),
    ))

    skipped = pack.get("skipped") or {}
    if skipped:
        print("%d recipes left out, by cause:" % sum(skipped.values()))
        for reason in sorted(skipped, key=lambda name: -skipped[name]):
            print("  %-22s %d" % (reason, skipped[reason]))


if __name__ == "__main__":
    main()
