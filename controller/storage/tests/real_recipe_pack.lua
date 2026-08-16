-- Loads the vanilla-1.18.2 fixture pack under tests/fixtures/recipes/ rather than
-- whatever happens to be checked out at storage/recipes/ (per-deployment data, gitignored,
-- absent on a fresh clone). A test double that is more permissive than a real pack hides
-- real bugs in core.craft_planner, which is why these tests want a real pack at all rather
-- than the small hand-built fixtures most other craft tests use -- see recipe_repo tests
-- named "real pack: ..." across test_craft_planner, test_craft_integration and
-- test_craft_endtoend for the specific regressions this has caught before.
local RecipeRepo = require("core.recipe_repo")

local FIXTURE_DIR = "storage/tests/fixtures/recipes/"

local function fixtureLoader(name)
    local chunk = loadfile(FIXTURE_DIR .. name .. ".lua")
    if not chunk then return nil end
    local ok, value = pcall(chunk)
    if not ok or type(value) ~= "table" then return nil end
    return value
end

return RecipeRepo.new({loader = fixtureLoader})
