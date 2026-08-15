-- Standalone host test for install.lua's pure functions. Deliberately outside
-- controller/storage/tests/ (and not registered in its run.lua): install.lua
-- is a repo-root artifact fetched standalone via `wget run`, not part of the
-- controller/turtle deployable trees those tests cover, and reaching outside
-- that tree from inside it would fight the existing package.path convention
-- for no benefit. Run directly: `lua install_test.lua`.

local Install = dofile("install.lua")

local failures = 0
local function check(label, condition)
    if condition then
        print("PASS " .. label)
    else
        print("FAIL " .. label)
        failures = failures + 1
    end
end

-- extractTagName
check("extractTagName reads tag_name out of a releases-API body",
    Install.extractTagName('{"url":"x","tag_name":"v1.2.3","name":"v1.2.3"}') == "v1.2.3")
check("extractTagName returns nil when the field is absent",
    Install.extractTagName('{"url":"x"}') == nil)
check("extractTagName returns nil for nil input",
    Install.extractTagName(nil) == nil)

-- stripV
check("stripV strips a leading v", Install.stripV("v1.2.3") == "1.2.3")
check("stripV leaves an unprefixed version alone", Install.stripV("1.2.3") == "1.2.3")

-- compareVersions
check("compareVersions: equal versions", Install.compareVersions("1.0.0", "1.0.0") == 0)
check("compareVersions: equal versions, one v-prefixed",
    Install.compareVersions("v1.0.0", "1.0.0") == 0)
check("compareVersions: a is older (patch)", Install.compareVersions("1.0.0", "1.0.1") == -1)
check("compareVersions: a is older (minor)", Install.compareVersions("1.0.9", "1.1.0") == -1)
check("compareVersions: a is older (major)", Install.compareVersions("1.9.9", "2.0.0") == -1)
check("compareVersions: a is newer", Install.compareVersions("2.0.0", "1.9.9") == 1)

-- validateManifestTable
local ok, files = Install.validateManifestTable({files = {"startup.lua", "storage/main.lua"}})
check("validateManifestTable accepts a well-formed manifest table", ok == true)
check("validateManifestTable returns the file list", files and #files == 2 and files[1] == "startup.lua")

local badOk, badReason = Install.validateManifestTable({files = {}})
check("validateManifestTable rejects an empty file list", badOk == false and type(badReason) == "string")

local wrongShapeOk = Install.validateManifestTable({not_files = {}})
check("validateManifestTable rejects a table with no files key", wrongShapeOk == false)

local notTableOk = Install.validateManifestTable("not a table")
check("validateManifestTable rejects a non-table", notTableOk == false)

if failures > 0 then
    print(failures .. " FAILED")
    os.exit(1)
else
    print("ALL PASSED")
end
