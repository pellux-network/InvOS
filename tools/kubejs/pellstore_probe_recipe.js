// Diagnostic only. Asks Minecraft's RecipeManager which recipes produce a given item.
//
// This exists because the exporter and the game disagree: an operator crafts
// the_vault:mystical_powder in a standard crafting table, and KubeJS's `recipes` event --
// which is what the exporter reads -- contains nothing that produces it. Both cannot be
// true, so this asks the object the crafting table itself matches against rather than
// KubeJS's JSON wrapper around datapack load.
//
// Fires on server.load, after everything is registered. Modifies nothing.
// Delete this file once the question is answered.
//
// Every uncertain call is tried several ways in one run and reports which worked. Doing
// otherwise costs a full server restart per guess, which is how this investigation has
// already been spending its time.

// priority: 0

const PROBE_ITEM = 'the_vault:mystical_powder'

// Registry lookup, avoiding ItemStackJS: its of() is overloaded and KubeJS registers a
// type wrapper that can make an ItemStack argument ambiguous to Rhino.
const $ForgeRegistries = java('net.minecraftforge.registries.ForgeRegistries')

function itemIdOf(stack) {
    try {
        // getKey returns null for an item with no registry entry, and stringifying that
        // null is itself an NPE inside Rhino -- which killed the previous scan outright.
        var key = $ForgeRegistries.ITEMS.getKey(stack.getItem())
        if (key === null || key === undefined) return null
        return String(key)
    } catch (error) {
        return null
    }
}

function resultOf(recipe) {
    // getResultItem is the mapped name; m_8043_ is the obfuscated one. Which resolves
    // depends on whether KubeJS's remapper is active for this call site.
    try { return {stack: recipe.getResultItem(), how: 'getResultItem'} } catch (a) {}
    try { return {stack: recipe.m_8043_(), how: 'm_8043_'} } catch (b) {}
    return null
}

onEvent('server.load', function (event) {
    var manager = event.server.getMinecraftServer().getRecipeManager()
    var all = manager.getRecipes()
    var total = 0
    var hits = 0
    var unreadable = 0
    var crafting = 0
    var failed = 0
    var accessor = null

    // One recipe must never end the scan. The whole body is guarded, because the recipes
    // worth finding here are exactly the unusual ones most likely to throw.
    all.forEach(function (recipe) {
        total++
        try {
            var kind = '?'
            try { kind = String(recipe.getType()) } catch (error) {}
            if (kind.indexOf('crafting') !== -1) crafting++

            var got = resultOf(recipe)
            if (!got || !got.stack) { unreadable++; return }
            accessor = accessor || got.how
            var id = itemIdOf(got.stack)
            if (id === null) { unreadable++; return }
            if (id.indexOf(PROBE_ITEM) === -1) return
            hits++
            var cls = '?'
            try { cls = String(recipe.getClass().getName()) } catch (error) {}
            var rid = '?'
            try { rid = String(recipe.getId()) } catch (error) {}
            console.info('[pellstore-probe] MAKES  recipe=' + rid +
                '  type=' + kind + '  class=' + cls)
        } catch (error) {
            failed++
        }
    })

    console.info('[pellstore-probe] result accessor: ' + accessor)
    console.info('[pellstore-probe] manager holds ' + total + ' recipes, ' + crafting +
        ' of crafting type; ' + unreadable + ' had no readable result, ' + failed +
        ' threw and were skipped')
    console.info('[pellstore-probe] ' + hits + ' produce ' + PROBE_ITEM)
})
