"""Crafting in the emulator: the oracle, the turtle booting, and real crafts.

The whole crafting pipeline has only ever run against host fakes and against a
live modded installation. Every crafting invariant in AGENTS.md was found on that
installation after a green host suite. These tests put the pipeline in between:
the real controller, the real turtle firmware, real rednet, and a world that can
refuse a badly staged grid.

    python3 run_tests.py craft

Set ``INVOS_SKIP_EMULATOR=1`` to skip the emulator classes where one cannot be
provisioned. OraclePackAgreementTests needs no emulator and always runs.
"""

import os
import re
import unittest

import harness as harness_module
import scenario as scenario_module
import test_smoke

SKIP = os.environ.get("INVOS_SKIP_EMULATOR") == "1"

ORACLE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "smoke", "craft_oracle.lua")


def oracle_outputs():
    """The item ids craft_oracle.lua can produce, read straight from the Lua.

    Parsed rather than executed: the alternative is a Lua interpreter on the
    host, and the outputs are written as literals there precisely so this stays a
    one-line regex.
    """
    with open(ORACLE_PATH, encoding="utf-8") as handle:
        return re.findall(r'output\s*=\s*"([^"]+)"', handle.read())


def pack_items(pack_dir):
    """Every namespaced item id a recipe pack's item table names."""
    with open(os.path.join(pack_dir, "items.lua"), encoding="utf-8") as handle:
        return set(re.findall(r'"([a-z0-9_.-]+:[a-z0-9_./-]+)"', handle.read()))


class OraclePackAgreementTests(unittest.TestCase):
    """Two independent sources of truth, held to naming the same items.

    The oracle must not be derived from the pack -- an oracle that cannot
    disagree cannot catch a planner committing to a recipe the game lacks. But an
    oracle output the pack has never heard of is simply unreachable: the Crafting
    page only offers what the pack lists, so a test using it would pass by never
    running anything.
    """

    def test_every_oracle_output_exists_in_the_fixture_pack(self):
        items = pack_items(harness_module.FIXTURE_PACK)
        outputs = oracle_outputs()
        self.assertGreaterEqual(len(outputs), 5, outputs)
        for output in outputs:
            self.assertIn(output, items, "%s is not in the fixture recipe pack" % output)

    def test_the_scenario_stock_is_named_by_the_pack_too(self):
        items = pack_items(harness_module.FIXTURE_PACK)
        for entry in scenario_module.CRAFT_STOCK:
            self.assertIn(entry["id"], items, entry["id"])


@unittest.skipIf(SKIP, "INVOS_SKIP_EMULATOR=1")
class OracleTests(unittest.TestCase):
    """The oracle's match rules, exercised in the Lua the emulator actually runs.

    Running these through a probe rather than through host Lua is not ceremony:
    host Lua is 5.4 and CC:Tweaked is 5.2, and this module is loaded by the
    emulator. One probe boot covers every assertion, so the cost is one boot.
    """

    ASSERTIONS = r'''
local Oracle = dofile("/craft_oracle.lua")
local failures = {}
local function check(name, condition)
    if not condition then failures[#failures + 1] = name end
end

local PLANK, LOG = "minecraft:oak_planks", "minecraft:oak_log"
local COAL, STICK = "minecraft:coal", "minecraft:stick"
local oracle = Oracle.new()

check("grid slots map 3x3 to a turtle", Oracle.GRID_SLOTS[1] == 1
    and Oracle.GRID_SLOTS[4] == 5 and Oracle.GRID_SLOTS[7] == 9
    and Oracle.GRID_SLOTS[9] == 11)

local sticks = oracle:match({[1] = PLANK, [4] = PLANK})
check("shaped match", sticks ~= nil and sticks.output == STICK and sticks.count == 4)

check("shaped position matters", oracle:match({[2] = PLANK, [5] = PLANK}) == nil)
check("shaped extra cell refused", oracle:match({[1] = PLANK, [4] = PLANK, [7] = PLANK}) == nil)

local planks = oracle:match({[1] = LOG})
check("shapeless match", planks ~= nil and planks.output == PLANK and planks.count == 4)
check("shapeless anywhere in the grid", oracle:match({[5] = LOG}) ~= nil)

local torch = oracle:match({[1] = COAL, [4] = STICK})
check("two-ingredient match", torch ~= nil and torch.output == "minecraft:torch")
check("two ingredients swapped is not the recipe",
    oracle:match({[1] = STICK, [4] = COAL}) == nil)

check("empty grid matches nothing", oracle:match({}) == nil)
check("unknown item matches nothing", oracle:match({[1] = "minecraft:bedrock"}) == nil)

local custom = Oracle.new({{output = "x:y", count = 2, shapeless = {"x:z"}}})
check("an override replaces the defaults", custom:match({[1] = "x:z"}) ~= nil
    and custom:match({[1] = LOG}) == nil)

local handle = fs.open("/oracle.txt", "w")
handle.write(#failures == 0 and "OK" or table.concat(failures, "\n"))
handle.close()
os.shutdown()
'''

    def test_the_oracle_matches_grids_the_way_the_world_should(self):
        # A turtle-less scenario on purpose: the oracle is pure, so standing up
        # a second computer to ask it about a grid would test everything except
        # the thing under test.
        written = test_smoke.run_probe(
            "oracle.lua", self.ASSERTIONS, "oracle.txt",
            scenario=scenario_module.configured())
        self.assertEqual(written.strip(), "OK")


@unittest.skipIf(SKIP, "INVOS_SKIP_EMULATOR=1")
class WorldServerTests(unittest.TestCase):
    """The world server, driven directly rather than through rednet.

    Item movement is real pushItems/pullItems between emulated chests, so these
    assert the emulator's own conservation as much as the server's logic: a stack
    that vanished here would vanish in a craft too.
    """

    ASSERTIONS = r'''
local World = dofile("/world.lua")
local WorldTurtle = dofile("/world_turtle.lua")
local scenario = dofile("/scenario.lua")
World.build(scenario.world)

local BUFFER = scenario.world.turtle.buffer
local INV = scenario.world.turtle.inventory
local server = WorldTurtle.new(scenario.world.turtle, World)

local failures = {}
local function check(name, condition)
    if not condition then failures[#failures + 1] = name end
end
local function countIn(name, slot)
    local item = peripheral.call(name, "list")[slot]
    return item and item.count or 0
end

-- The fidelity fix everything below rests on: a slotless push must fill the first
-- available slot, as CC:Tweaked does. CraftOS-PC only merges into a matching
-- stack and moves nothing once it is full. The controller relies on CC's
-- behaviour directly -- core/planner.lua's planRetrieval names a destination node
-- and no slot on purpose -- so without this a multi-stack retrieval to Pickup
-- blocks with PICKUP_FULL against an almost-empty Pickup.
peripheral.call(BUFFER, "setItem", 1, {name = "minecraft:cobblestone", count = 64, maxCount = 64})
peripheral.call(INV, "setItem", 1, {name = "minecraft:cobblestone", count = 64, maxCount = 64})
local spilled = peripheral.call(INV, "pushItems", BUFFER, 1)
check("a slotless push spills past a full stack, moved " .. tostring(spilled), spilled == 64)
check("and it landed in the next slot", countIn(BUFFER, 2) == 64)
peripheral.call(BUFFER, "pushItems", scenario.world.turtle.void, 1)
peripheral.call(BUFFER, "pushItems", scenario.world.turtle.void, 2)

peripheral.call(BUFFER, "setItem", 1, {name = "minecraft:oak_log", count = 8, maxCount = 64})

check("select bounds", server:handle({op = "select", args = {17}}) == false)
server:handle({op = "select", args = {16}})
check("suckDown takes the lowest buffer slot", server:handle({op = "suckDown", args = {}}) == true)
check("it landed in the selected slot", countIn(INV, 16) == 8)
check("the buffer gave them up", countIn(BUFFER, 1) == 0)

-- transferTo is a push to the inventory's own name, which CraftOS-PC allows.
check("transferTo moves part of a stack", server:handle({op = "transferTo", args = {1, 3}}) == true)
check("source kept the rest", countIn(INV, 16) == 5)
check("destination took its share", countIn(INV, 1) == 3)

-- Only the 3x3 grid is a recipe. Slot 16 sits outside it, so five logs there plus
-- three in slot 1 is still just "three logs in cell 1".
local ok = server:handle({op = "craft", args = {}})
check("a matching grid crafts", ok == true)

local function heldOf(name, id)
    local total = 0
    for _, item in pairs(peripheral.call(name, "list")) do
        if item.name == id then total = total + item.count end
    end
    return total
end

-- The three logs in the cell are gone; the five parked outside the grid in slot
-- 16 are untouched, because slots 4, 8 and 12-16 are not part of the recipe.
check("the grid's ingredients were consumed, held " .. heldOf(INV, "minecraft:oak_log"),
    heldOf(INV, "minecraft:oak_log") == 5)
check("and they went to the void", heldOf(scenario.world.turtle.void, "minecraft:oak_log") == 3)

local produced = heldOf(INV, "minecraft:oak_planks")
-- 3 logs in one cell = 3 runs of a 4-plank recipe.
check("output is count times runs, got " .. produced, produced == 12)

-- A grid nothing matches must refuse rather than invent an output.
peripheral.call(INV, "setItem", 2, {name = "minecraft:cobblestone", count = 4, maxCount = 64})
local bad = server:handle({op = "craft", args = {}})
check("an unmatched grid refuses", bad == false)
check("and consumed nothing", countIn(INV, 2) == 4)

-- dropDown returns items to the buffer, which is how every job ends.
server:handle({op = "select", args = {2}})
check("dropDown returns items", server:handle({op = "dropDown", args = {}}) == true)
check("the turtle slot is empty", countIn(INV, 2) == 0)

-- A craft yielding more than one stack has to drop ALL of it.
--
-- CraftOS-PC's pushItems will not spill into an empty slot: given no explicit
-- toSlot it only merges into a matching stack and moves nothing once that stack
-- is full, where CC:Tweaked fills the first available slot.
-- World.fillFirstAvailableSlot restores CC's behaviour for every caller.
-- Without it the turtle dropped only its first stack, the controller saw a
-- shortfall, and a 256-stick craft waited forever on a withdrawal for planks that
-- only existed inside the turtle.
peripheral.call(INV, "setItem", 3, {name = "minecraft:cobblestone", count = 64, maxCount = 64})
peripheral.call(INV, "setItem", 4, {name = "minecraft:cobblestone", count = 64, maxCount = 64})
peripheral.call(BUFFER, "setItem", 1, {name = "minecraft:cobblestone", count = 64, maxCount = 64})
for _, slot in ipairs({3, 4}) do
    server:handle({op = "select", args = {slot}})
    server:handle({op = "dropDown", args = {}})
end
local cobbleInBuffer = 0
for _, item in pairs(peripheral.call(BUFFER, "list")) do
    if item.name == "minecraft:cobblestone" then cobbleInBuffer = cobbleInBuffer + item.count end
end
check("two stacks drop past a full one, got " .. cobbleInBuffer, cobbleInBuffer == 192)
check("nothing is left held", countIn(INV, 3) == 0 and countIn(INV, 4) == 0)

-- The same quirk bit crafting itself: consuming a full stack from one cell fills a
-- void slot, and the next cell's push then moved nothing -- failing the craft with
-- the earlier cells already destroyed. Two cells of 64 is the smallest case.
for _, slot in ipairs({1, 2, 3, 5, 6, 7, 9, 10, 11, 16}) do
    local held = peripheral.call(INV, "list")[slot]
    if held then
        server:handle({op = "select", args = {slot}})
        server:handle({op = "dropDown", args = {}})
    end
end
peripheral.call(INV, "setItem", 1, {name = "minecraft:oak_planks", count = 64, maxCount = 64})
peripheral.call(INV, "setItem", 5, {name = "minecraft:oak_planks", count = 64, maxCount = 64})
local crafted = server:handle({op = "craft", args = {}})
check("a craft consuming two full stacks succeeds", crafted == true)
local sticks = 0
for _, item in pairs(peripheral.call(INV, "list")) do
    if item.name == "minecraft:stick" then sticks = sticks + item.count end
end
-- 64 runs of a 4-stick recipe, spread over four slots because one holds 64.
check("it produced 64 runs worth, got " .. sticks, sticks == 256)
check("both cells were consumed",
    countIn(INV, 1) == 0 or peripheral.call(INV, "list")[1].name == "minecraft:stick")

local handle = fs.open("/world.txt", "w")
handle.write(#failures == 0 and "OK" or table.concat(failures, "\n"))
handle.close()
os.shutdown()
'''

    def test_the_world_server_moves_and_crafts_real_items(self):
        written = test_smoke.run_probe(
            "world_turtle_probe.lua", self.ASSERTIONS, "world.txt",
            scenario=scenario_module.crafting())
        self.assertEqual(written.strip(), "OK")


@unittest.skipIf(SKIP, "INVOS_SKIP_EMULATOR=1")
class TurtleBootTests(unittest.TestCase):
    """The second computer runs the real firmware and can reach its world."""

    harness = None
    session = None

    @classmethod
    def setUpClass(cls):
        cls.harness = harness_module.Harness()
        cls.session = cls.harness.start(scenario_module.crafting())
        cls.session.wait_for_text("INVOS", timeout=120)
        cls.session.settle(quiet_for=2.5, timeout=60)

    @classmethod
    def tearDownClass(cls):
        if cls.session:
            cls.session.stop()

    def test_the_turtle_draws_its_own_status_screen(self):
        # crafter/hud.lua's header. Reaching it means the firmware booted, the
        # injected turtle global answered executor:purge()'s sixteen calls, and
        # the world server replied to every one.
        self.session.wait_for_text("CRAFTER", timeout=90, window="turtle")
        self.assertIn("listening for jobs", self.session.text(window="turtle"))

    def test_the_turtle_window_is_not_the_controller_window(self):
        self.session.wait_for_text("CRAFTER", timeout=90, window="turtle")
        self.assertNotEqual(self.session.turtle_window, 0)
        self.assertIn("INVOS", self.session.text())

    def test_the_controller_offers_recipes_to_craft(self):
        self.session.press("f10")
        self.session.press("six")
        self.session.settle(quiet_for=1.2, timeout=20)
        text = self.session.text()
        self.assertIn("RECIPE", text)
        self.assertNotIn("No matching recipes", text)


TERMINAL_STATES = ("COMPLETE", "BLOCKED", "FAILED", "CANCELLED")


def queue_craft(active, query, count, rows=0):
    """Queue a craft through the real UI, returning once it is committed.

    The keys come from app/keymap.lua: 6 opens Crafting, Delete clears the query,
    typing filters the recipe list, Enter opens the quantity prompt, digits then
    Enter plans it, and Enter commits. Committing sets the mode to craft_jobs
    itself (ui.lua's COMMIT_CRAFT), so the jobs list is already on screen --
    pressing F2 here would toggle straight back off it.

    Every step that should change the screen is checked before the next one is
    sent. That is not belt-and-braces: without it, a driver mistake is
    indistinguishable from a slow craft, and the run burns the whole job timeout
    before reporting a screen that has been wrong since the second keystroke.
    Clearing the query is the specific mistake -- the Crafting page keeps its
    query across visits, so a second craft typed into a dirty box matches no
    recipe, and the digits meant for the quantity prompt land in the query.
    """
    active.press("f10")
    active.press("six")
    active.press("delete")      # CRAFT_QUERY_CLEAR; the page keeps its query
    active.settle(quiet_for=0.8, timeout=20)
    active.type_text(query)
    active.wait_for(lambda s: not s.contains("No matching recipes"), timeout=15,
                    description="the recipe list to match %r" % query)
    for _ in range(rows):
        active.press("down")
    active.press("enter")
    active.wait_for(lambda s: s.contains("How many?"), timeout=15,
                    description="the quantity prompt for %r" % query)
    active.type_text(str(count))
    active.press("enter")
    plan = active.wait_for(lambda s: s.contains("PLAN"), timeout=30,
                           description="a plan for %d x %r" % (count, query))
    plan_text = plan.text_dump()
    active.press("enter")       # commit; this lands on the jobs list
    return plan_text


def terminal_count(text):
    """How many jobs on the jobs list have stopped moving.

    Each job is one row showing its state, so this counts finished jobs -- which
    is the only safe way to wait in a shared session. Waiting for *any* terminal
    word matches a job that finished during an earlier test and returns
    instantly, so the craft under test is never actually awaited and the
    assertion passes without having run anything.
    """
    return sum(text.count(state) for state in TERMINAL_STATES)


def craft_jobs_text(active):
    """Open the craft jobs list, read it, and return to the recipe list."""
    active.press("f10")
    active.press("six")
    active.press("f2")          # craft_search -> craft_jobs
    active.wait_for(lambda s: s.contains("CRAFT JOBS"), timeout=15,
                    description="the craft jobs list")
    active.settle(quiet_for=0.6, timeout=15)
    text = active.text()
    active.press("f2")          # back to the recipe list
    return text


def wait_for_new_terminal(active, before, timeout=90, description=None):
    """Wait until one more job than `before` has stopped moving."""
    screen = active.wait_for(
        lambda s: terminal_count(s.text_dump()) > before,
        timeout=timeout,
        description=description or "a craft job to reach a terminal state")
    return screen.text_dump()


def drive_craft(active, query, count, rows=0, timeout=90):
    """Queue a craft and wait for that craft -- not an earlier one -- to finish."""
    before = terminal_count(craft_jobs_text(active))
    queue_craft(active, query, count, rows=rows)
    return wait_for_new_terminal(active, before, timeout=timeout,
                                 description="%d x %r to finish" % (count, query))


@unittest.skipIf(SKIP, "INVOS_SKIP_EMULATOR=1")
class CraftingEndToEndTests(unittest.TestCase):
    """A real craft: real planner, real staging, real firmware, real rednet."""

    harness = None
    session = None

    @classmethod
    def setUpClass(cls):
        cls.harness = harness_module.Harness()
        cls.session = cls.harness.start(scenario_module.crafting())
        cls.session.wait_for_text("INVOS", timeout=120)
        cls.session.wait_for_text("CRAFTER", timeout=120, window="turtle")
        cls.session.settle(quiet_for=2.5, timeout=60)

    @classmethod
    def tearDownClass(cls):
        if cls.session:
            cls.session.stop()

    def test_a_single_step_craft_completes(self):
        # Planks from logs: one step, one ingredient, the simplest whole pipeline.
        jobs = drive_craft(self.session, "Oak Planks", 4)
        self.assertIn("COMPLETE", jobs)
        self.assertNotIn("BLOCKED", jobs)

    def test_a_two_ingredient_craft_completes(self):
        # Torches need coal and sticks, both in stock, so it stays one step. The
        # buffer holds two item types at once, which is the case that first put
        # the wrong item in a grid cell on a live installation: every craft
        # before it had a single ingredient, where any order is the right order.
        jobs = drive_craft(self.session, "Torch", 4)
        self.assertIn("COMPLETE", jobs)

    def test_a_two_step_tree_completes(self):
        # No planks in stock, so sticks need planks crafted first. Exercises the
        # between-steps drain, the rescan that is the only thing telling the
        # controller the turtle produced anything, and step_index advancing.
        jobs = drive_craft(self.session, "Stick", 8)
        self.assertIn("COMPLETE", jobs)

    def test_the_turtle_reports_its_finished_jobs(self):
        drive_craft(self.session, "Oak Planks", 4)
        # jobs_done is cumulative across this class's shared session, so a
        # non-zero count means the firmware ran a craft through to a reply.
        turtle = self.session.text(window="turtle")
        self.assertIn("JOBS COMPLETE", turtle)
        self.assertNotIn("JOBS COMPLETE 0", turtle)

    def test_a_second_job_queued_behind_a_running_one_also_completes(self):
        # Exactly one job runs at a time -- there is one buffer and one turtle,
        # so two at once would interleave ingredients in the same chest. The
        # second must wait rather than be dropped or run alongside.
        before = terminal_count(craft_jobs_text(self.session))
        queue_craft(self.session, "Oak Planks", 4)
        queue_craft(self.session, "Torch", 4)
        # Both, not just one: the count has to rise by two.
        jobs = self.session.wait_for(
            lambda s: terminal_count(s.text_dump()) >= before + 2, timeout=240,
            description="both queued craft jobs to finish").text_dump()
        self.assertNotIn("BLOCKED", jobs)
        self.assertNotIn("FAILED", jobs)

    def test_a_batched_craft_of_hundreds_completes(self):
        # 256 sticks is 64 crafts of one recipe, which the planner issues as a
        # single turtle call with per_cell=64 -- the number that meant "this
        # call's crafts", not "the step's maximum", and told the turtle to stage
        # 64 logs for a two-craft step when it was read the other way.
        before = terminal_count(craft_jobs_text(self.session))
        plan = queue_craft(self.session, "Stick", 256)
        self.assertIn("craft", plan)
        jobs = wait_for_new_terminal(self.session, before, timeout=300,
                                     description="256 sticks to finish")
        self.assertIn("COMPLETE", jobs)
        self.assertNotIn("BLOCKED", jobs)


@unittest.skipIf(SKIP, "INVOS_SKIP_EMULATOR=1")
class WorldDisagreesTests(unittest.TestCase):
    """A recipe the pack has and the world does not.

    On a live modded installation this is what a conditions-gated mod recipe
    does: the pack describes it, the running game does not have it, and the
    controller consumes real materials before finding out. Here the world is
    simply told to know nothing, which is the same shape of failure.
    """

    def test_the_job_blocks_instead_of_inventing_an_output(self):
        harness = harness_module.Harness()
        active = harness.start(scenario_module.crafting(recipes=[]))
        try:
            active.wait_for_text("INVOS", timeout=120)
            active.wait_for_text("CRAFTER", timeout=120, window="turtle")
            active.settle(quiet_for=2.5, timeout=60)
            jobs = drive_craft(active, "Oak Planks", 4)
            self.assertIn("BLOCKED", jobs)
            self.assertNotIn("COMPLETE", jobs)
        finally:
            active.stop()


@unittest.skipIf(SKIP, "INVOS_SKIP_EMULATOR=1")
class DeepTreeTests(unittest.TestCase):
    """Three chained intermediates, which the host suite never reached.

    With neither sticks nor planks in stock, a torch needs logs turned into
    planks, planks into sticks, and only then sticks and coal into torches. Each
    step is a separate turtle command with its own staging, its own drain and its
    own forced rescan, so this is where a step boundary that half-works shows up.
    """

    harness = None
    session = None

    @classmethod
    def setUpClass(cls):
        cls.harness = harness_module.Harness()
        cls.session = cls.harness.start(
            scenario_module.crafting(stock=scenario_module.DEEP_CRAFT_STOCK))
        cls.session.wait_for_text("INVOS", timeout=120)
        cls.session.wait_for_text("CRAFTER", timeout=120, window="turtle")
        cls.session.settle(quiet_for=2.5, timeout=60)

    @classmethod
    def tearDownClass(cls):
        if cls.session:
            cls.session.stop()

    def test_a_three_step_tree_completes(self):
        before = terminal_count(craft_jobs_text(self.session))
        plan = queue_craft(self.session, "Torch", 4)
        # The plan lists one "craft N x item" line per step, so a three-deep tree
        # is visible before anything is committed.
        steps = [line for line in plan.splitlines() if line.strip().startswith("craft ")]
        self.assertGreaterEqual(len(steps), 3, plan)
        jobs = wait_for_new_terminal(self.session, before, timeout=300,
                                     description="a three-step torch craft to finish")
        self.assertIn("COMPLETE", jobs)
        self.assertNotIn("BLOCKED", jobs)


@unittest.skipIf(SKIP, "INVOS_SKIP_EMULATOR=1")
class CancellationTests(unittest.TestCase):
    """Cancelling a running job, and proving the installation still works after.

    Cancellation is not just a state change: a job cancelled mid-flight has
    ingredients in the buffer and possibly a request outstanding, and
    craft_service drains the buffer on the way out. The valuable assertion is not
    that the job says CANCELLED but that the next craft still completes -- a
    cancel that stranded items would wedge everything behind it.
    """

    harness = None
    session = None

    @classmethod
    def setUpClass(cls):
        cls.harness = harness_module.Harness()
        cls.session = cls.harness.start(scenario_module.crafting())
        cls.session.wait_for_text("INVOS", timeout=120)
        cls.session.wait_for_text("CRAFTER", timeout=120, window="turtle")
        cls.session.settle(quiet_for=2.5, timeout=60)

    @classmethod
    def tearDownClass(cls):
        if cls.session:
            cls.session.stop()

    def test_a_running_job_can_be_cancelled_and_the_next_one_still_runs(self):
        queue_craft(self.session, "Stick", 256)
        # Committing lands on the jobs list with the new job selected, so C
        # cancels the job that is running rather than an older one.
        self.session.wait_for(lambda s: s.contains("CRAFT JOBS"), timeout=20,
                              description="the craft jobs list")
        self.session.press("c")
        jobs = self.session.wait_for(
            lambda s: "CANCELLED" in s.text_dump(), timeout=180,
            description="the job to report CANCELLED").text_dump()
        self.assertIn("CANCELLED", jobs)

        after = drive_craft(self.session, "Oak Planks", 4, timeout=180)
        self.assertIn("COMPLETE", after)


@unittest.skipIf(SKIP, "INVOS_SKIP_EMULATOR=1")
@unittest.skipUnless(os.path.isdir(harness_module.LOCAL_PACK),
                     "no generated recipe pack at controller/storage/recipes/")
class ModdedPackTests(unittest.TestCase):
    """The real modpack, which is where the defects actually come from.

    Skipped when there is no generated pack, because it is per-deployment data
    and absent on a fresh clone or in CI. Where one exists these are the most
    valuable tests in the file: modded items, modded tags and a recipe set three
    orders of magnitude larger than the fixture's.
    """

    ORACLE_ASSERTIONS = r'''
local Oracle = dofile("/craft_oracle.lua")
local out = {}
local oracle = Oracle.fromPack()
if not oracle then
    local handle = fs.open("/modded.txt", "w")
    handle.write("no pack was loaded")
    handle.close()
    os.shutdown()
    return
end

local items = dofile("/storage/recipes/items.lua")
local index = dofile("/storage/recipes/index.lua")
local tags = dofile("/storage/recipes/tags.lua").tags or {}
local function anyMember(reference)
    if type(reference) == "number" then return items.ids[reference] end
    local members = tags[reference]
    return members and members[1] and items.ids[members[1]] or nil
end

-- Replay each recipe's own grid back through the oracle, staged from the tags it
-- names. A recipe the pack declares but the oracle cannot match is a recipe the
-- emulated world would refuse to craft while the planner happily planned it.
local checked, modded, failed = 0, 0, {}
for shard = 1, index.shard_count do
    local pack = dofile(("/storage/recipes/pack_%02d.lua"):format(shard))
    for _, recipe in ipairs(pack.recipes or {}) do
        if recipe.shaped and recipe.grid then
            local grid, ok = {}, true
            for cell = 1, 9 do
                local reference = recipe.grid[cell]
                if reference and reference ~= 0 then
                    local id = anyMember(reference)
                    if not id then ok = false break end
                    grid[cell] = id
                end
            end
            if ok then
                checked = checked + 1
                local output = items.ids[recipe.output] or ""
                if not output:match("^minecraft:") then modded = modded + 1 end
                if not oracle:match(grid) and #failed < 5 then
                    failed[#failed + 1] = tostring(recipe.id)
                end
            end
        end
    end
end

out[#out + 1] = ("recipes=%d checked=%d modded=%d unmatched=%s"):format(
    oracle.recipeCount, checked, modded,
    #failed == 0 and "none" or table.concat(failed, ","))
local handle = fs.open("/modded.txt", "w")
handle.write(table.concat(out, "\n"))
handle.close()
os.shutdown()
'''

    def test_the_oracle_matches_every_recipe_the_modpack_declares(self):
        written = test_smoke.run_probe(
            "modded_oracle.lua", self.ORACLE_ASSERTIONS, "modded.txt", timeout=180,
            scenario=scenario_module.crafting(), recipe_pack="local")
        self.assertIn("unmatched=none", written, written)
        fields = dict(part.split("=", 1) for part in written.split())
        # A pack this size is the point: the fixture has a few hundred recipes.
        self.assertGreater(int(fields["recipes"]), 5000, written)
        self.assertGreater(int(fields["modded"]), 100, written)

    def test_a_craft_completes_against_the_modpack(self):
        harness = harness_module.Harness(recipe_pack="local")
        active = harness.start(scenario_module.crafting())
        try:
            active.wait_for_text("INVOS", timeout=180)
            active.wait_for_text("CRAFTER", timeout=180, window="turtle")
            active.settle(quiet_for=2.5, timeout=60)
            # Sticks want the minecraft:planks tag, which has hundreds of members
            # in a modpack against the fixture's eight, and only oak is in stock.
            # It only completes if tag-candidate ranking and rollback pick oak --
            # the defect that reached a live installation as acacia_planks.
            jobs = drive_craft(active, "Stick", 8, timeout=240)
            self.assertIn("COMPLETE", jobs)
            self.assertNotIn("BLOCKED", jobs)
        finally:
            active.stop()


if __name__ == "__main__":
    unittest.main()
