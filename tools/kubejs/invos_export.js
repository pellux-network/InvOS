// Exports the crafting recipes the game actually has, for the InvOS recipe pack.
//
// Copy this file into <server>/kubejs/server_scripts/ and restart the server. It writes
// kubejs/exported/invos_recipes.json and does nothing else -- it adds, removes and
// modifies no recipes.
//
// It reads MinecraftServer.getRecipeManager() on server.load, which is the collection a
// crafting table matches against. Everything else was tried first and was wrong:
//
//   * Mod jars cannot be read directly. About 10% of modded recipes are gated behind
//     `conditions` that depend on each mod's config and only resolve at runtime, so a jar
//     scan reports recipes that are switched off -- including both halves of a mutually
//     exclusive pair, which makes the controller plan a craft that produces a different
//     item than it expects after consuming the materials.
//
//   * KubeJS's `recipes` event cannot be read either. forEachRecipe walks the recipes
//     loaded from datapacks, not the ones scripts add. This pack adds 10,186 recipes and
//     removes 2,409 from scripts, so that view was missing thousands of real recipes and
//     still contained thousands that no longer exist.
//
// Reading the manager also removes every special case. Ingredients arrive already resolved
// to concrete items, so tags need no expansion; conditions and script edits are already
// applied; and a recipe's serialiser stops mattering, so cucumber:shaped_no_mirror,
// KubeJS's own ShapedKubeJSRecipe and anything else are handled by the same code.
//
// Written for KubeJS Forge 1802 (verified against 1802.5.5-build.569). This Rhino does not
// reliably catch exceptions thrown inside Java calls, so the code below checks for null
// rather than relying on try/catch -- three diagnostic runs died proving that.

// priority: 0

const OUTPUT_PATH = 'kubejs/exported/invos_recipes.json'
const SCHEMA = 2

const $ForgeRegistries = java('net.minecraftforge.registries.ForgeRegistries')
const $RecipeType = java('net.minecraft.world.item.crafting.RecipeType')
const $ShapedRecipe = java('net.minecraft.world.item.crafting.ShapedRecipe')

function itemIdOf(stack) {
    if (stack === null || stack === undefined) return null
    var item = stack.getItem()
    if (item === null || item === undefined) return null
    // getKey returns null for an item with no registry entry, and stringifying that null
    // throws inside Rhino's conversion rather than at the call.
    var key = $ForgeRegistries.ITEMS.getKey(item)
    if (key === null || key === undefined) return null
    return String(key)
}

// ShapedRecipe's width and height are mapped names; m_44220_ / m_44221_ are the obfuscated
// ones. A missing method is a JS TypeError, which is catchable, unlike a Java throw.
function dimension(recipe, mapped, obfuscated) {
    try { return recipe[mapped]() } catch (a) {}
    try { return recipe[obfuscated]() } catch (b) {}
    return null
}

onEvent('server.load', function (event) {
    var manager = event.server.getMinecraftServer().getRecipeManager()
    var all = manager.getRecipes()

    // Interning tables. A single plank cell resolves to 412 concrete items on this pack,
    // so writing each cell's options inline would produce a file many times larger than
    // the recipes themselves.
    var itemIds = []
    var itemIndex = {}
    var optionSets = []
    var optionIndex = {}

    function internItem(id) {
        var known = itemIndex[id]
        if (known !== undefined) return known
        itemIds.push(id)
        itemIndex[id] = itemIds.length
        return itemIds.length
    }

    function internOptions(ids) {
        if (ids.length === 0) return 0
        ids.sort()
        var key = ids.join('\\u0000')
        var known = optionIndex[key]
        if (known !== undefined) return known
        var interned = []
        for (var i = 0; i < ids.length; i++) interned.push(internItem(ids[i]))
        optionSets.push(interned)
        optionIndex[key] = optionSets.length
        return optionSets.length
    }

    // One ingredient's accepted items, already resolved by the game.
    function cellOf(ingredient) {
        if (ingredient === null || ingredient === undefined) return 0
        if (ingredient.isEmpty()) return 0
        var stacks = ingredient.getItems()
        if (stacks === null || stacks === undefined) return 0
        var ids = []
        var seen = {}
        for (var i = 0; i < stacks.length; i++) {
            var id = itemIdOf(stacks[i])
            if (id !== null && !seen[id]) { seen[id] = true; ids.push(id) }
        }
        return internOptions(ids)
    }

    var recipes = {}
    var total = 0
    var crafting = 0
    var exported = 0
    var special = 0
    var noResult = 0
    var noLayout = 0
    var emptyCell = 0

    all.forEach(function (recipe) {
        total++
        if (recipe.getType() !== $RecipeType.CRAFTING) return
        crafting++

        // Special recipes build their output from the inputs (map cloning, firework
        // assembly, banner duplication). There is no fixed result to record.
        if (recipe.isSpecial()) { special++; return }

        var resultStack = recipe.getResultItem()
        var resultId = itemIdOf(resultStack)
        if (resultId === null || resultStack.isEmpty()) { noResult++; return }

        var ingredients = recipe.getIngredients()
        if (ingredients === null || ingredients === undefined) { noLayout++; return }

        var shaped = (recipe instanceof $ShapedRecipe)
        var width = null
        var height = null
        if (shaped) {
            width = dimension(recipe, 'getWidth', 'm_44220_')
            height = dimension(recipe, 'getHeight', 'm_44221_')
            if (width === null || height === null) { noLayout++; return }
            if (width > 3 || height > 3) { noLayout++; return }
        }

        var cells = []
        var unsatisfiable = false
        for (var i = 0; i < ingredients.size(); i++) {
            var cell = cellOf(ingredients.get(i))
            // A shaped recipe legitimately has holes. A shapeless one listing an
            // ingredient nothing satisfies cannot be crafted at all.
            if (cell === 0 && !shaped) unsatisfiable = true
            cells.push(cell)
        }
        if (unsatisfiable) { emptyCell++; return }

        var entry = {
            shaped: shaped,
            cells: cells,
            result: {item: internItem(resultId), count: resultStack.getCount()},
        }
        if (shaped) { entry.width = width; entry.height = height }
        recipes[String(recipe.getId())] = entry
        exported++
    })

    var payload = {
        schema: SCHEMA,
        generated_by: 'tools/kubejs/invos_export.js',
        items: itemIds,
        options: optionSets,
        recipes: recipes,
    }

    var target = java('dev.latvian.mods.kubejs.util.UtilsJS')
        .getFileFromPath(OUTPUT_PATH).toPath()
    JsonIO.write(target, JsonIO.of(payload))

    console.info('[invos] exported ' + exported + ' of ' + crafting +
        ' crafting recipes (' + total + ' in the manager) to ' + target)
    console.info('[invos] ' + itemIds.length + ' items, ' + optionSets.length +
        ' distinct ingredient sets')
    console.info('[invos] left out: ' + special + ' special, ' + noResult +
        ' with no fixed result, ' + noLayout + ' with an unusable layout, ' +
        emptyCell + ' with an unsatisfiable ingredient')
})
