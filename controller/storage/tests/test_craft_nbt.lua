-- Crafting's treatment of NBT variants.
--
-- The rest of the system keys items on identity -- name plus NBT -- so an
-- enchanted sword and a plain one are two different items. Crafting deliberately
-- does not: recipes name items without NBT, so ingredient matching is NBT-free.
-- That decision is made independently in three places, by three different
-- mechanisms, and until now only `craft_buffer`'s share of it was covered:
-- test_craft_planner, test_craft_service and test_craft_endtoend contain no NBT
-- case at all. These tests pin the contract those three places have to keep.
--
-- The subtle one is `snapshot`. An NBT-bearing item contributes *zero* to its
-- name's total, so it can never be spent as an ingredient -- but its name is
-- still present as a key, so the safety assertion in `CraftService:_stage`
-- ("the buffer holds nothing this step does not use") can still see it. Count
-- and visibility are separate concerns there, and dropping either one breaks a
-- different guarantee.

local CraftBuffer = require("app.craft_buffer")
local Identity = require("core.identity")
local Index = require("core.index")
local T = require("tests.mock_cc")

local function slot(name, count, nbt)
    return {name=name, count=count, nbt=nbt,
        identity_key=Identity.key(name, nbt), max_count=64}
end

local function bufferContext(slots)
    return {
        craft_buffer = {node_id="craft_buffer", peripheral_name="buffer",
            health="READY", epoch=1, size=27, slots=slots or {}},
        pickup = {peripheral_name="pickup", health="READY"},
        storage = {{node_id="storage", health="READY", slots={}}},
        generation = 1, now = 100,
    }
end

local function buffer()
    return CraftBuffer.new({imports = {tick = function() end},
        adapter = {push = function() return true, 0 end}})
end

local function snapshotOf(slots)
    return buffer():snapshot(bufferContext(slots))
end

return {
    {name="an NBT variant in the buffer contributes nothing to its item total",run=function()
        local totals = snapshotOf({[1] = slot("minecraft:diamond_sword", 1, "sharpness5")})
        T.equal(totals["minecraft:diamond_sword"], 0,
            "an enchanted sword must never be spendable as a plain sword")
    end},

    {name="an NBT variant is still visible as a key so the staging assert can see it",run=function()
        -- CraftService:_stage asserts the buffer holds nothing beyond the current
        -- step's ingredients. It iterates the keys of this snapshot, so an NBT
        -- variant that vanished from the table entirely would sit in the buffer
        -- unnoticed and the turtle would craft against contents the controller
        -- never observed. Counting it as zero is what keeps it both unusable and
        -- visible.
        local totals = snapshotOf({[1] = slot("minecraft:diamond_sword", 1, "looting3")})
        local keys = {}
        for key in pairs(totals) do keys[#keys + 1] = key end
        T.arrayEqual(keys, {"minecraft:diamond_sword"})
    end},

    {name="a plain stack aggregates while its NBT sibling stays excluded",run=function()
        local totals = snapshotOf({
            [1] = slot("minecraft:diamond_sword", 2),
            [2] = slot("minecraft:diamond_sword", 1, "sharpness5"),
            [3] = slot("minecraft:diamond_sword", 3),
        })
        T.equal(totals["minecraft:diamond_sword"], 5,
            "only the two NBT-free stacks count toward the usable total")
    end},

    {name="several distinct NBT variants of one item still total zero",run=function()
        local totals = snapshotOf({
            [1] = slot("minecraft:diamond_sword", 1, "sharpness5"),
            [2] = slot("minecraft:diamond_sword", 1, "looting3"),
        })
        T.equal(totals["minecraft:diamond_sword"], 0)
    end},

    {name="an NBT variant is always excess, even within a keep budget for its name",run=function()
        -- _excess drains anything the current step does not need. An NBT variant
        -- is excess unconditionally: the keep budget is expressed per item name,
        -- and honouring it for a variant would strand an unusable item in the
        -- buffer for as long as the plain form was wanted.
        local context = bufferContext({
            [1] = slot("minecraft:diamond_sword", 1, "sharpness5"),
        })
        local excess = buffer():_excess(context, {["minecraft:diamond_sword"] = 64})
        T.equal(#excess, 1, "the variant is drained despite a generous keep budget")
        T.equal(excess[1].nbt, "sharpness5")
    end},

    {name="a plain item within its keep budget is not excess",run=function()
        local context = bufferContext({[1] = slot("minecraft:diamond_sword", 1)})
        local excess = buffer():_excess(context, {["minecraft:diamond_sword"] = 64})
        T.equal(#excess, 0, "the NBT-free form is exactly what the step wants to keep")
    end},

    {name="planning availability counts only the NBT-free variant",run=function()
        -- CraftService:_planContext looks stock up as Identity.key(itemId, nil),
        -- so the planner is answered with the plain form's quantity alone. This
        -- pins the index contract that lookup depends on: were it to fall back to
        -- a name-wide total, the planner would promise a craft against enchanted
        -- tools the buffer then refuses to spend, and the job would stall with
        -- materials apparently in stock.
        local index = Index.build({{
            health = "READY",
            slots = {
                [1] = slot("minecraft:diamond_sword", 2),
                [2] = slot("minecraft:diamond_sword", 5, "sharpness5"),
            },
        }})
        T.equal(index:quantity(Identity.key("minecraft:diamond_sword", nil)), 2,
            "the five enchanted swords are not craftable material")
        T.equal(index:quantity(Identity.key("minecraft:diamond_sword", "sharpness5")), 5,
            "but they are still tracked, and requestable, in their own right")
    end},

    {name="identity keeps variants of one item distinct",run=function()
        T.notEqual(Identity.key("minecraft:diamond_sword", "sharpness5"),
            Identity.key("minecraft:diamond_sword", nil))
    end},
}
