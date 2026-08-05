// Exports the crafting recipes the game actually has, for the PellStore recipe pack.
//
// Copy this file into <server>/kubejs/server_scripts/ and restart the server (or run
// /reload). It writes kubejs/exported/pellstore_recipes.json and does nothing else -- it
// adds, removes and modifies no recipes.
//
// Why this exists rather than reading the mod jars: about 10% of modded crafting recipes
// are gated behind `conditions`, and the common ones (quark:flag, supplementaries:flag,
// thermal:flag, mysticalagriculture:*) depend on each mod's config, which is only knowable
// at runtime. Reading jars finds recipes that are not active -- including both halves of a
// mutually exclusive pair. Quark's chest is the clearest case: `minecraft:chest` from any
// planks and `quark:dark_oak_chest` from dark oak planks are gated on opposite states of
// the same `variant_chests` flag, so a jar scan reports both and the controller would plan
// a craft that produces a different item than it expects, after consuming the materials.
//
// This event fires after conditions are resolved and after every script has run, so what
// it sees is what the game will actually craft.
//
// Written for KubeJS Forge 1802 (verified against 1802.5.5-build.569). Two things about
// this Rhino that cost a restart each, both of which fail only at run time:
//
//   * The Java loader is the lowercase `java('...')`. `Java.loadClass` is KubeJS 6 syntax
//     and raises ReferenceError: "Java" is not defined.
//   * `const` and `let` inside a function that runs more than once raise
//     "TypeError: redeclaration of var <name>". Function-body declarations here are `var`
//     for that reason; only the two module-level constants use `const`.

// priority: 0

// Where the dump lands, relative to the game directory.
const OUTPUT_PATH = 'kubejs/exported/pellstore_recipes.json'
const OUTPUT_NAME = 'pellstore_recipes.json'

// Getting a writable Path is the one genuinely awkward step, so try several routes and
// report which worked rather than spending a server restart per attempt. Ruled out already:
// Utils.getFileFromPath (the Utils binding is UtilsWrapper, which has no file helpers),
// java.nio.file.Paths (the class filter blocks java.nio whatever disableClassFilter says),
// and KubeJSPaths.EXPORTED.resolve(str) (ambiguous between resolve(Path) and
// resolve(String), which Rhino refuses rather than choosing).
function outputPath() {
    var attempts = []

    // UtilsJS is a KubeJS class, and KubeJS classes do load -- KubeJSPaths did.
    // getFileFromPath(Object) and File.toPath() each have exactly one signature.
    try {
        return {path: java('dev.latvian.mods.kubejs.util.UtilsJS')
            .getFileFromPath(OUTPUT_PATH).toPath(), how: 'UtilsJS.getFileFromPath'}
    } catch (error) {
        attempts.push('UtilsJS.getFileFromPath: ' + error)
    }

    // FileSystem.getPath is the only method of that name, so no overload to resolve, and
    // this touches no class by name -- only instance methods on objects already in hand.
    try {
        var exported = java('dev.latvian.mods.kubejs.KubeJSPaths').EXPORTED
        return {path: exported.getFileSystem().getPath(String(exported), OUTPUT_NAME),
            how: 'FileSystem.getPath'}
    } catch (error) {
        attempts.push('FileSystem.getPath: ' + error)
    }

    // KubeJS.getGameDirectory() returns a Path; toAbsolutePath/normalize take no arguments.
    try {
        var game = java('dev.latvian.mods.kubejs.KubeJS').getGameDirectory()
        return {path: game.getFileSystem().getPath(String(game), OUTPUT_PATH),
            how: 'KubeJS.getGameDirectory'}
    } catch (error) {
        attempts.push('KubeJS.getGameDirectory: ' + error)
    }

    throw new Error('no writable path could be obtained -- ' + attempts.join(' | '))
}

// Only the two 3x3 types, because those are the only ones a crafty turtle can perform.
const CRAFTING_TYPES = ['minecraft:crafting_shaped', 'minecraft:crafting_shapeless']

// Recipe bodies are kept as the Gson objects the game loaded and never converted to JS.
// A JsonIO.toObject -> JsonIO.of round trip is lossy: it turns strings that look like
// numbers into numbers, and a shaped recipe's pattern rows are exactly that -- "000"
// came back as bare 000 and the whole dump was invalid JSON.
//
// JsonObject.add(String, JsonElement) has a single signature so it is safe to call.
// JsonArray.add is the one to avoid: it is overloaded on both JsonElement and String, and
// Rhino refuses the call as ambiguous rather than picking.
onEvent('recipes', function (event) {
    var $JsonObject = java('com.google.gson.JsonObject')
    var recipes = new $JsonObject()
    var tagNames = []
    var seenTag = {}
    var skipped = 0
    var exported = 0
    var unresolved = 0

    // Walk the Gson tree directly rather than converting it. Every tag the exported
    // recipes refer to is collected, so the importer needs no second source and cannot
    // disagree with the game about what a tag contains.
    function noteTags(node) {
        if (node === null || node === undefined) return
        if (node.isJsonObject()) {
            var asObject = node.getAsJsonObject()
            if (asObject.has('tag')) {
                var tagValue = asObject.get('tag')
                if (tagValue.isJsonPrimitive()) {
                    var tagName = tagValue.getAsString()
                    if (!seenTag[tagName]) {
                        seenTag[tagName] = true
                        tagNames.push(tagName)
                    }
                }
            }
            asObject.entrySet().forEach(function (pair) { noteTags(pair.getValue()) })
        } else if (node.isJsonArray()) {
            node.getAsJsonArray().forEach(noteTags)
        }
    }

    event.forEachRecipe({}, function (recipe) {
        var recipeJson = recipe.originalJson || recipe.json
        if (!recipeJson) {
            skipped++
            return
        }
        if (!recipeJson.has('type')) return
        // A resource location with no namespace means minecraft:. Datapacks write plain
        // "crafting_shaped" freely, and matching only the qualified form silently dropped
        // 1,135 real grid recipes on this pack -- most of two mods.
        var kind = recipeJson.get('type').getAsString()
        if (kind.indexOf(':') === -1) kind = 'minecraft:' + kind
        if (CRAFTING_TYPES.indexOf(kind) === -1) return

        // Keyed by id: the importer keys recipes by id too, and two mods shipping the same
        // path under different namespaces must stay distinct.
        recipes.add(String(recipe.id), recipeJson)
        exported++

        noteTags(recipeJson)
    })

    // Resolve each tag through the game itself. A tag that resolves to nothing is kept as
    // an empty list rather than dropped, so the importer can tell "empty" from "unknown".
    // Item ids never look numeric, so converting these string lists through JsonIO.of is
    // safe in a way converting recipe bodies is not.
    var tags = new $JsonObject()
    tagNames.forEach(function (tagName) {
        var items = []
        try {
            Ingredient.of('#' + tagName).stacks.forEach(function (stack) {
                items.push(String(stack.id))
            })
        } catch (error) {
            unresolved++
            console.warn('[pellstore] could not resolve tag ' + tagName + ': ' + error)
        }
        tags.add(tagName, JsonIO.of(items))
    })

    var resolved = outputPath()
    var target = resolved.path
    // add(String, JsonElement) throughout: addProperty is overloaded across String,
    // Number, Boolean and Character, which is the ambiguity this whole script works around.
    var payload = new $JsonObject()
    payload.add('schema', JsonIO.of(1))
    payload.add('generated_by', JsonIO.of('tools/kubejs/pellstore_export.js'))
    payload.add('recipes', recipes)
    payload.add('tags', tags)
    JsonIO.write(target, payload)

    console.info('[pellstore] exported ' + exported + ' crafting recipes and ' +
        tagNames.length + ' item tags to ' + target + ' (via ' + resolved.how + ')')
    if (skipped > 0) {
        console.warn('[pellstore] ' + skipped + ' recipes had no readable json and were skipped')
    }
    if (unresolved > 0) {
        console.warn('[pellstore] ' + unresolved + ' tags could not be resolved')
    }
})
