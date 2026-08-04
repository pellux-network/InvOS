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
