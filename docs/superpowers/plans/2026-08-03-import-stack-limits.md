# Import Stack Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import non-stackable and reduced-stack items into exact valid storage slots without zero-movement blocks.

**Architecture:** Enrich occupied Drop-off scan entries with authoritative `getItemDetail(slot).maxCount`; do not detail Storage or Pickup entries. Feed the existing `max_count` snapshot field through the unchanged Import Service and planner capacity model.

**Tech Stack:** CC:Tweaked CraftOS Lua, inventory peripheral API, table-driven Lua tests, Git.

## Global Constraints

- Only Drop-off scans make per-item detail calls.
- Detail identity and count must match the basic `list()` entry.
- `maxCount` must be a positive integer; the scanner never guesses 64 after requesting authoritative detail.
- Storage, Pickup, transfer, retrieval, and recovery behavior remain unchanged.

---

### Task 1: Authoritative Drop-off stack limits

**Files:**
- Modify: `controller/colossal/tests/test_scanner.lua`
- Modify: `controller/colossal/core/scanner.lua`

**Interfaces:**
- Consumes: `Scanner:begin(node)` where `node.role == "dropoff"`, plus `inventory.getItemDetail(slot)`.
- Produces: Drop-off snapshot items with integer `max_count`; structured scan failures for unavailable, mismatched, or malformed details.

- [ ] Add failing scanner tests proving a Drop-off detail call records `max_count=1`, while a Storage scan makes zero detail calls.
- [ ] Add failing table-driven tests for thrown detail calls, nil detail, identity/count mismatch, and invalid `maxCount`.
- [ ] Run `lua colossal/tests/run.lua tests.test_scanner` and confirm the new enrichment assertion fails because `max_count` is absent.
- [ ] In `Scanner:step`, detail only Drop-off entries, verify name/NBT/count equality, validate positive integer `maxCount`, and copy it to `max_count`.
- [ ] Re-run scanner tests and confirm all pass.

### Task 2: Exact reduced-stack import planning

**Files:**
- Modify: `controller/colossal/tests/test_planner.lua`
- Modify: `controller/colossal/tests/test_acceptance.lua`

**Interfaces:**
- Consumes: Drop-off source `max_count` and existing `Planner.planImport(source, storageSnapshots)`.
- Produces: plans that skip full non-stackable matches and cap 16-stack matches before using empty slots.

- [ ] Add planner coverage where `max_count=1` skips an occupied match and selects an empty slot, and `max_count=16` fills a 15-item match by one before selecting an empty slot.
- [ ] Update the acceptance harness to preserve each fake item's `maxCount` through detail and transfer operations.
- [ ] Add a failing acceptance test that deposits one non-stackable tool, then a second, and expects two distinct occupied storage slots with no blocked import.
- [ ] Run `lua colossal/tests/run.lua tests.test_planner tests.test_acceptance` and confirm the acceptance test fails under the scanner's old 64-item assumption.
- [ ] Re-run after Task 1 and confirm both deposits complete.

### Task 3: Verification and deployment

**Files:**
- Deploy: `controller/colossal/core/scanner.lua` to computer `4` only after shutdown and identity verification.

**Interfaces:**
- Consumes: manifest-approved runtime and live config identifying computer 4 as `StorageController`.
- Produces: matching repository/live scanner hashes with config and aliases preserved.

- [ ] Run focused scanner, planner, acceptance, import, coordinator, and responsiveness tests.
- [ ] Run the full `lua colossal/tests/run.lua` suite and `git diff --check`.
- [ ] Commit with `git commit -m "fix: honor exact import stack limits"`.
- [ ] After the user shuts down computer 4, deploy only `colossal/core/scanner.lua`, verify its SHA-256 hash, and confirm no development artifacts were copied.
- [ ] Boot and verify the waiting Chest Upgrade Tool imports into a separate empty storage slot.
