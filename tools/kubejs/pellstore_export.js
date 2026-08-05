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

const $KubeJSPaths = java('dev.latvian.mods.kubejs.KubeJSPaths')

// Only the two 3x3 types, because those are the only ones a crafty turtle can perform.
const CRAFTING_TYPES = ['minecraft:crafting_shaped', 'minecraft:crafting_shapeless']

// Everything below builds plain JS values and converts once at the end with JsonIO.of.
// Populating Gson containers directly does not work here: JsonArray.add is overloaded on
// both JsonElement and String, and Rhino refuses the call as ambiguous rather than picking.
onEvent('recipes', function (event) {
    var recipes = {}
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
        if (CRAFTING_TYPES.indexOf(recipeJson.get('type').getAsString()) === -1) return

        // Keyed by id: the importer keys recipes by id too, and two mods shipping the same
        // path under different namespaces must stay distinct.
        recipes[String(recipe.id)] = JsonIO.toObject(recipeJson)
        exported++

        noteTags(recipeJson)
    })

    // Resolve each tag through the game itself. A tag that resolves to nothing is kept as
    // an empty list rather than dropped, so the importer can tell "empty" from "unknown".
    var tags = {}
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
        tags[tagName] = items
    })

    var target = $KubeJSPaths.EXPORTED.resolve('pellstore_recipes.json')
    JsonIO.write(target, JsonIO.of({
        schema: 1,
        generated_by: 'tools/kubejs/pellstore_export.js',
        recipes: recipes,
        tags: tags,
    }))

    console.info('[pellstore] exported ' + exported + ' crafting recipes and ' +
        tagNames.length + ' item tags to ' + target)
    if (skipped > 0) {
        console.warn('[pellstore] ' + skipped + ' recipes had no readable json and were skipped')
    }
    if (unresolved > 0) {
        console.warn('[pellstore] ' + unresolved + ' tags could not be resolved')
    }
})
