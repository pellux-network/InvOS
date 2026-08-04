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
    parser.add_argument("--jar", required=True, help="server or mod jar to read")
    parser.add_argument("--out", required=True, help="output directory for the pack")
    parser.add_argument("--namespace", default="minecraft")
    parser.add_argument("--shards", type=int, default=4)
    args = parser.parse_args()

    with open_data_jar(args.jar, args.namespace) as jar:
        recipes, tags = read_namespace(jar, args.namespace)
        if not recipes:
            raise SystemExit("no recipes found for namespace %s" % args.namespace)
        lang = read_lang(jar)

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


if __name__ == "__main__":
    main()
