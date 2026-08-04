// Exports the crafting recipes the game actually has, for the PellStore recipe pack.
//
// Copy this file into <server>/kubejs/server_scripts/ and run /reload (or restart the
// server). It writes kubejs/exported/pellstore_recipes.json and does nothing else -- it
// adds, removes and modifies no recipes.
//
// Why this exists rather than reading the mod jars: about 10% of modded crafting recipes
// are gated behind `conditions`, and the common ones (quark:flag, supplementaries:flag,
// thermal:flag, mysticalagriculture:*) depend on each mod's config, which is only knowable
// at runtime. Reading jars finds recipes that are not active -- including both halves of a
// mutually exclusive pair. Quark's chest is the clearest case: `minecraft:chest` from any
// planks and `quark:dark_oak_chest` from dark oak planks are gated on opposite states of
// the same `variant_chests` flag, so a jar scan reports both and the controller would plan
// a craft that produces a different item than it expects.
//
// This event fires after conditions are resolved and after every script has run, so what
// it sees is what the game will actually craft.
//
// Verified against KubeJS Forge 1802.5.5-build.569.

// priority: 0

const $JsonIO = Java.loadClass('dev.latvian.mods.kubejs.util.JsonIO')
const $JsonArray = Java.loadClass('com.google.gson.JsonArray')
const $JsonObject = Java.loadClass('com.google.gson.JsonObject')
const $KubeJSPaths = Java.loadClass('dev.latvian.mods.kubejs.KubeJSPaths')

// Only the two 3x3 types, because those are the only ones a crafty turtle can perform.
const CRAFTING_TYPES = ['minecraft:crafting_shaped', 'minecraft:crafting_shapeless']

onEvent('recipes', event => {
    const recipes = new $JsonArray()
    const tagNames = []
    const seenTag = {}
    let skipped = 0

    // Every tag the exported recipes refer to, so the importer needs no second source and
    // cannot disagree with the game about what a tag contains.
    const noteTags = value => {
        if (value === null || value === undefined) return
        if (Array.isArray(value)) {
            value.forEach(noteTags)
            return
        }
        if (typeof value !== 'object') return
        if (value.tag && typeof value.tag === 'string' && !seenTag[value.tag]) {
            seenTag[value.tag] = true
            tagNames.push(value.tag)
        }
        for (let key in value) noteTags(value[key])
    }

    event.forEachRecipe({}, recipe => {
        const json = recipe.originalJson || recipe.json
        if (!json) {
            skipped++
            return
        }
        const typeElement = json.get('type')
        if (!typeElement || CRAFTING_TYPES.indexOf(typeElement.getAsString()) === -1) return

        // Carry the id alongside the body: the importer keys recipes by id, and two mods
        // shipping the same path under different namespaces must stay distinct.
        const entry = new $JsonObject()
        entry.addProperty('id', String(recipe.id))
        entry.add('recipe', json)
        recipes.add(entry)

        noteTags(JSON.parse($JsonIO.toString(json)))
    })

    // Resolve each tag through the game itself. A tag that resolves to nothing is kept as
    // an empty list rather than dropped, so the importer can tell "empty" from "unknown".
    const tags = new $JsonObject()
    tagNames.forEach(name => {
        const items = new $JsonArray()
        try {
            Ingredient.of('#' + name).stacks.forEach(stack => items.add(String(stack.id)))
        } catch (error) {
            console.warn('[pellstore] could not resolve tag ' + name + ': ' + error)
        }
        tags.add(name, items)
    })

    const payload = new $JsonObject()
    payload.addProperty('schema', 1)
    payload.addProperty('generated_by', 'tools/kubejs/pellstore_export.js')
    payload.add('recipes', recipes)
    payload.add('tags', tags)

    const target = $KubeJSPaths.EXPORTED.resolve('pellstore_recipes.json')
    $JsonIO.write(target, payload)

    console.info('[pellstore] exported ' + recipes.size() + ' crafting recipes and ' +
        tagNames.length + ' item tags to ' + target)
    if (skipped > 0) {
        console.warn('[pellstore] ' + skipped + ' recipes had no readable json and were skipped')
    }
})
