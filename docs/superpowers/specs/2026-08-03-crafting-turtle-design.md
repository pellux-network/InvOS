# Crafting turtle

Status: **superseded by `2026-08-04-crafting-system-design.md`.** Kept because its
reconciliation-scope reasoning is still correct and is what the newer design builds on.

Three of its open questions have since been answered from evidence: a wired modem does network
a turtle, the turtle exposes no inventory over that network, and staging happens in a dedicated
buffer chest rather than in Pickup. See the newer spec.

Crafting was listed as future work in v1; this was the first concrete design for it.

## Topology

A Crafty Turtle sits directly above the **Pickup** chest, networked to the controller.

```
        [ Crafting Turtle ]   -- Crafty upgrade, plus a modem
                 |               suckDown / dropDown
        [   Pickup chest   ]   -- normal retrieval destination
```

Verified against `cc-tweaked-1.18.2-1.101.3.jar`:

- `upgrade.minecraft.crafting_table.adjective` = "Crafty" — the crafting upgrade is
  registered under the `minecraft` namespace, not `computercraft`.
- `upgrade.computercraft.wireless_modem_normal` / `_advanced` = "Wireless" / "Ender".
- There is **no wired modem turtle upgrade**.

A turtle has two upgrade slots. Crafty takes one. If an adjacent wired modem block can put a
turtle on the network — reported to work, not verified from the host — the second slot stays
free; otherwise it holds a Wireless or Ender modem. Either is sufficient. Ender if the
station may ever be outside the controller's chunk.

## Flow

1. Operator requests a craft on the controller.
2. Controller resolves the recipe and issues **ordinary retrievals** for each ingredient,
   which deliver to Pickup exactly as any retrieval does.
3. Controller tells the turtle, over rednet, which item belongs in which crafting slot.
4. Turtle `suckDown`s the ingredients, arranges them into the 3x3 grid, `turtle.craft()`s.
5. Turtle `dropDown`s the result into Pickup for the operator to collect.

Storing the result instead of collecting it is the same flow with the turtle dropping into
Drop-off, which the existing import path then handles unchanged.

## Why Pickup, and not a dedicated crafting chest

An earlier suggestion in this project was a dedicated crafting-input inventory, on the
grounds that anything moving items around could corrupt reconciliation. That reasoning does
not apply here, and the dedicated chest is the worse design.

Reconciliation baselines are captured **only** from nodes with `role == "storage"` — see
`Coordinator:_context` and `Transfer:executeMultiBatch`, which passes `storageSnapshots` to
`captureMany`. Pickup contents never enter a baseline. More than that, tolerating a mutable
Pickup is an explicit runtime invariant:

> Retrieval verification depends on controlled Storage state, not mutable Pickup contents.

It is enforced, not merely stated: `Transfer:_preflightMulti` returns immediately for
retrievals without inspecting the destination, covered by the test *"retrieval never inspects
mutable Pickup contents"*. A retrieval proves itself by measuring the storage **decrease**;
what happens to items after they land in Pickup is deliberately outside its concern.

So a turtle emptying Pickup is precisely the case the architecture was built to withstand. A
dedicated chest would add an inventory role, config, a scan target and new code paths to
re-derive a property Pickup already has.

**The warning that does still hold:** the turtle must never touch storage nodes directly.
Storage totals moving for reasons the controller did not cause is exactly what surfaces as
`RECONCILE_DIRECTION`, which halts automation for operator review.

Drop-off is also outside the reconciliation scope, but it is unsuitable as a staging area for
a different reason: the import loop continuously drains it, so staged ingredients would race
the controller trying to put them back into storage. Pickup is never drained automatically.

## Risks to design around

**Pickup is shared with players.** Every retrieval lands there. A player collecting during
staging breaks the craft with ingredients already pulled from storage. Mitigations, in
increasing cost: have the turtle verify it received exactly what was promised before
crafting; sequence crafting against other pending retrievals; or add a second Pickup node
bound to crafting only, which needs `Registry.validate` and setup changes.

**`PICKUP_FULL` blocks retrieval.** Zero-movement into Pickup is a deliberate stop awaiting
explicit operator retry, not an automatic one — `generation` advances on every scan and is
not evidence Pickup drained. Staging many ingredients makes this more likely. It is now
recoverable from the terminal with `R` on the Requests page.

**Grid placement is the bulk of the turtle code.** `turtle.craft()` reads slots 1-3, 5-7 and
9-11 as the 3x3 grid, while `suckDown` fills the first free slot. The turtle must therefore
place each ingredient deliberately, either sucking in a controlled order or sucking then
rearranging. Unavoidable under any topology.

**Failure recovery.** A craft that fails midway leaves ingredients in the turtle. The turtle
should return everything to Pickup rather than hold stock, so no inventory is stranded in a
place the controller cannot see. The controller should treat a turtle that stops responding
as an alert, not a hang.

## Open questions

- **Recipe storage.** Entirely unbuilt. Recipes are static data, not stock truth, so they can
  live in `colossal/data/` under the same validated-store pattern as config and aliases. A
  hand-maintained file is the cheap start; reading the server's recipe registry is not
  available to CC.
- **Ingredient sourcing.** Whether a craft may itself request sub-crafts, or only draw
  ingredients that already exist. Recursive crafting is a much larger design.
- **Turtle protocol.** Message shape, rednet protocol name, timeouts, and what the controller
  does when the turtle is unreachable.
- Whether an adjacent wired modem genuinely networks a turtle in 1.101.3, which decides
  whether the second upgrade slot is free.

## Constraints for whoever builds this

- Do not touch `core/transfer.lua` or `core/reconciliation.lua`. This design deliberately
  needs no change to either; if it starts to, the staging choice is wrong.
- The turtle is not a storage node and must never be added as one.
- Follow the deployment rules in `AGENTS.md`. A turtle is a second live computer, so it needs
  the same shutdown-confirm, manifest-gated, hash-verified treatment, and it will need its
  own manifest.
