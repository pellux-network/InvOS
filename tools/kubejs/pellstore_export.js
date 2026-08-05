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
// Written for KubeJS Forge 1802 (verified against 1802.5.5-build.569). Note the lowercase
// `java(...)` loader: `Java.loadClass` is KubeJS 6 syntax and does not exist here.

// priority: 0

const $KubeJSPaths = java('dev.latvian.mods.kubejs.KubeJSPaths')

// Only the two 3x3 types, because those are the only ones a crafty turtle can perform.
const CRAFTING_TYPES = ['minecraft:crafting_shaped', 'minecraft:crafting_shapeless']

// Everything below builds plain JS values and converts once at the end with JsonIO.of.
// Populating Gson containers directly does not work here: JsonArray.add is overloaded on
// both JsonElement and String, and Rhino refuses the call as ambiguous rather than picking.
onEvent('recipes', event => {
    const recipes = {}
    const tagNames = []
    const seenTag = {}
    let skipped = 0
    let exported = 0

    // Walk the Gson tree directly rather than converting it. Every tag the exported
    // recipes refer to is collected, so the importer needs no second source and cannot
    // disagree with the game about what a tag contains.
    const noteTags = element => {
        if (element === null || element === undefined) return
        if (element.isJsonObject()) {
            const object = element.getAsJsonObject()
            if (object.has('tag')) {
                const value = object.get('tag')
                if (value.isJsonPrimitive()) {
                    const name = value.getAsString()
                    if (!seenTag[name]) {
                        seenTag[name] = true
                        tagNames.push(name)
                    }
                }
            }
            object.entrySet().forEach(entry => noteTags(entry.getValue()))
        } else if (element.isJsonArray()) {
            element.getAsJsonArray().forEach(noteTags)
        }
    }

    event.forEachRecipe({}, recipe => {
        const json = recipe.originalJson || recipe.json
        if (!json) {
            skipped++
            return
        }
        if (!json.has('type')) return
        if (CRAFTING_TYPES.indexOf(json.get('type').getAsString()) === -1) return

        // Keyed by id: the importer keys recipes by id too, and two mods shipping the same
        // path under different namespaces must stay distinct.
        recipes[String(recipe.id)] = JsonIO.toObject(json)
        exported++

        noteTags(json)
    })

    // Resolve each tag through the game itself. A tag that resolves to nothing is kept as
    // an empty list rather than dropped, so the importer can tell "empty" from "unknown".
    const tags = {}
    let unresolved = 0
    tagNames.forEach(name => {
        const items = []
        try {
            Ingredient.of('#' + name).stacks.forEach(stack => items.push(String(stack.id)))
        } catch (error) {
            unresolved++
            console.warn('[pellstore] could not resolve tag ' + name + ': ' + error)
        }
        tags[name] = items
    })

    const target = $KubeJSPaths.EXPORTED.resolve('pellstore_recipes.json')
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
