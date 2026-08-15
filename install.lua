-- InvOS installer: fetches either the controller or the crafting turtle's
-- deployable tree from a GitHub release and writes it onto this computer.
--
-- Usage: install.lua [install|update|reinstall] [ref] [raw_base]
--   install.lua                              -- install the latest release
--   install.lua update                       -- update to the latest release
--   install.lua reinstall                    -- force a full reinstall
--   install.lua install v1.2.3               -- install a specific ref
--   install.lua install v1.2.3 http://host   -- fetch from somewhere else
--
-- Auto-detects which side to install by checking for the `turtle` global,
-- which CC:Tweaked only exposes on turtle-type computers. Never touches
-- storage/data/: that path is simply never in either deployment_manifest.lua.
--
-- Distributed via: wget run
-- https://raw.githubusercontent.com/pellux-network/InvOS/main/install.lua

local OWNER_REPO = "pellux-network/InvOS"
local DEFAULT_RAW_BASE = "https://raw.githubusercontent.com/" .. OWNER_REPO
local RELEASES_LATEST_URL = "https://api.github.com/repos/" .. OWNER_REPO .. "/releases/latest"

-- Pattern match rather than a JSON decoder: this is the only field ever read
-- from the response, and CC:Tweaked's textutils.unserialiseJSON would be one
-- more thing to fake in a host test for no benefit here.
local function extractTagName(body)
    if type(body) ~= "string" then return nil end
    return body:match('"tag_name"%s*:%s*"([^"]+)"')
end

local function stripV(ref)
    return tostring(ref):gsub("^v", "")
end

local function compareVersions(a, b)
    local partsA, partsB = {}, {}
    for part in stripV(a):gmatch("%d+") do partsA[#partsA + 1] = tonumber(part) end
    for part in stripV(b):gmatch("%d+") do partsB[#partsB + 1] = tonumber(part) end
    for index = 1, math.max(#partsA, #partsB) do
        local left, right = partsA[index] or 0, partsB[index] or 0
        if left < right then return -1 end
        if left > right then return 1 end
    end
    return 0
end

local function validateManifestTable(value)
    if type(value) ~= "table" or type(value.files) ~= "table" then
        return false, "not a recognisable manifest table"
    end
    if #value.files == 0 then
        return false, "manifest lists no files"
    end
    for _, entry in ipairs(value.files) do
        if type(entry) ~= "string" or entry == "" then
            return false, "manifest contains a non-string or empty file entry"
        end
    end
    return true, value.files
end

-- The manifest file's own location is not the same thing as the root its
-- listed paths are relative to: controller/storage/deployment_manifest.lua
-- lists paths relative to controller/ (its grandparent -- e.g. "startup.lua"
-- means controller/startup.lua, exactly as tools/deploy.py's source_root for
-- the controller target is repo/"controller", not repo/"controller/storage")
-- while turtle/deployment_manifest.lua lists paths relative to its own
-- directory, turtle/. Conflating the two here would 404 on almost every file
-- for the controller side, since prefix/relPath would double up "storage/".
local function detectSide()
    if turtle ~= nil then return "turtle", "turtle", "deployment_manifest.lua" end
    return "controller", "controller", "storage/deployment_manifest.lua"
end

local function resolveRef(explicitRef)
    if explicitRef and explicitRef ~= "" then return explicitRef end
    local handle, err = http.get(RELEASES_LATEST_URL)
    if not handle then
        error("could not resolve the latest release: " .. tostring(err))
    end
    local body = handle.readAll()
    handle.close()
    local tag = extractTagName(body)
    if not tag then
        error("the releases API response had no tag_name")
    end
    return tag
end

local function fetchText(url)
    local handle, err = http.get(url)
    if not handle then
        return nil, tostring(err)
    end
    local body = handle.readAll()
    handle.close()
    return body
end

-- Fetches the manifest and every file it lists, plus root version.txt, all
-- into memory first. Nothing is written until every fetch has succeeded and
-- every .lua file has parsed -- a failed install leaves the existing
-- installation untouched rather than half-overwritten.
local function fetchAll(rawBase, ref, prefix, manifestRelPath)
    local manifestUrl = rawBase .. "/" .. ref .. "/" .. prefix .. "/" .. manifestRelPath
    local manifestText, manifestErr = fetchText(manifestUrl)
    if not manifestText then
        return nil, "could not fetch " .. manifestUrl .. ": " .. tostring(manifestErr)
    end
    local chunk, loadErr = load(manifestText, "deployment_manifest.lua")
    if not chunk then
        return nil, "deployment_manifest.lua did not parse: " .. tostring(loadErr)
    end
    local manifestOk, manifestTable = pcall(chunk)
    if not manifestOk then
        return nil, "deployment_manifest.lua errored when run: " .. tostring(manifestTable)
    end
    local validOk, filesOrReason = validateManifestTable(manifestTable)
    if not validOk then
        return nil, "deployment_manifest.lua " .. filesOrReason
    end

    local fetched = {}
    for _, relPath in ipairs(filesOrReason) do
        local url = rawBase .. "/" .. ref .. "/" .. prefix .. "/" .. relPath
        local text, err = fetchText(url)
        if not text then
            return nil, "could not fetch " .. url .. ": " .. tostring(err)
        end
        if relPath:match("%.lua$") then
            local ok, parseErr = load(text, relPath)
            if not ok then
                return nil, relPath .. " did not parse: " .. tostring(parseErr)
            end
        end
        fetched[relPath] = text
    end

    local versionUrl = rawBase .. "/" .. ref .. "/version.txt"
    local versionText, versionErr = fetchText(versionUrl)
    if not versionText then
        return nil, "could not fetch " .. versionUrl .. ": " .. tostring(versionErr)
    end

    return {files = fetched, version = versionText}
end

local function writeFile(path, content)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local handle = fs.open(path, "w")
    handle.write(content)
    handle.close()
end

local function readLocalVersion()
    if not fs.exists("/version.txt") then return nil end
    local handle = fs.open("/version.txt", "r")
    local text = handle.readAll()
    handle.close()
    return text
end

local function main(mode, explicitRef, rawBase)
    mode = mode or "install"
    rawBase = rawBase or DEFAULT_RAW_BASE

    local side, prefix, manifestRelPath = detectSide()
    print("install.lua: detected " .. side)

    local ref = resolveRef(explicitRef)
    print("install.lua: resolving " .. ref .. " from " .. rawBase)

    if mode == "update" then
        local current = readLocalVersion()
        if current and compareVersions(current, stripV(ref)) >= 0 then
            print("install.lua: already on " .. tostring(current) .. ", nothing to do")
            return
        end
    end

    local fetched, err = fetchAll(rawBase, ref, prefix, manifestRelPath)
    if not fetched then
        print("install.lua: FAILED, nothing written -- " .. tostring(err))
        error(err)
    end

    local written = 0
    for relPath, content in pairs(fetched.files) do
        writeFile("/" .. relPath, content)
        written = written + 1
    end
    writeFile("/version.txt", fetched.version)

    print("install.lua: wrote " .. written .. " files, version " .. tostring(fetched.version))
    print("install.lua: rebooting")
    os.reboot()
end

-- Real CC execution (wget run, shell.run, or a bare `lua install.lua` at the
-- CraftOS prompt) always has a global `shell` available; install_test.lua's
-- plain host-Lua `dofile` never does, so this is what tells "being executed"
-- apart from "being loaded for its exports" -- the usual `... == nil` idiom
-- this codebase uses elsewhere can't do that here, since a zero-arg real run
-- and a zero-arg dofile are otherwise indistinguishable.
if shell ~= nil then
    main(...)
end

return {
    extractTagName = extractTagName,
    stripV = stripV,
    compareVersions = compareVersions,
    validateManifestTable = validateManifestTable,
    OWNER_REPO = OWNER_REPO,
    DEFAULT_RAW_BASE = DEFAULT_RAW_BASE,
    RELEASES_LATEST_URL = RELEASES_LATEST_URL,
}
