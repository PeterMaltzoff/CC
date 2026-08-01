-- update_miner.lua
-- Download or update turtle scripts from GitHub.
--
-- SETUP (once):
--   1. Create a public GitHub repo and push this project to it.
--   2. Set GITHUB_USER / GITHUB_REPO / GITHUB_BRANCH below.
--   3. Copy this file to the turtle (only needed once, or when this script changes).
--
-- PC workflow after edits:
--   git add -A && git commit -m "update miner" && git push
--
-- Turtle workflow:
--   update_miner
--
-- Requires HTTP enabled in server config (http.get).

-- === CONFIG — edit these after creating your GitHub repo ===
local GITHUB_USER   = "PeterMaltzoff"
local GITHUB_REPO   = "CC"
-- Pin to a commit so GitHub/proxy caches cannot serve an stale file.
-- Bump this when you push fixes (git rev-parse --short HEAD on your PC).
local GITHUB_REF    = "9d0f8ae"
-- ===========================================================

local FILES = {
    { path = "turtle_lib.lua",  label = "Turtle Lib" },
    { path = "strip_miner.lua", label = "Strip Miner" },
}

local function raw_url(path)
    local cache_bust = tostring(os.epoch("utc"))
    return ("https://raw.githubusercontent.com/%s/%s/%s/%s?%s"):format(
        GITHUB_USER, GITHUB_REPO, GITHUB_REF, path, cache_bust
    )
end

local function download_file(entry)
    local url = raw_url(entry.path)
    local verb = fs.exists(entry.path) and "Updating" or "Downloading"
    print(verb .. " " .. entry.label .. " -> " .. entry.path)
    print("  " .. url)

    if GITHUB_USER == "YOUR_USERNAME" then
        print("FAILED: set GITHUB_USER in update_miner.lua")
        return false
    end

    if not http.checkURL(url) then
        print("FAILED: HTTP blocked or URL unreachable.")
        print("Enable HTTP in server config.")
        return false
    end

    local response = http.get(url)
    if not response then
        print("FAILED: HTTP request failed.")
        return false
    end

    local body = response.readAll()
    response.close()

    if not body or body == "" then
        print("FAILED: empty response (wrong repo/branch/path?).")
        return false
    end

    -- GitHub returns an HTML error page for missing files; catch the obvious case.
    if body:sub(1, 15) == "<!DOCTYPE html>" or body:sub(1, 6) == "<html>" then
        print("FAILED: file not found on GitHub.")
        return false
    end

    -- Reject accidentally cached/wrong downloads of strip_miner.
    if entry.path == "strip_miner.lua" and not body:find('local VERSION = "1.0.5"', 1, true) then
        print("FAILED: strip_miner.lua looks outdated (missing version marker).")
        print("Try again, or download manually from GitHub.")
        return false
    end

    local handle = fs.open(entry.path, "w")
    if not handle then
        print("FAILED: could not write " .. entry.path)
        return false
    end

    handle.write(body)
    handle.close()
    print("OK: " .. entry.path)
    return true
end

print("Miner updater (GitHub)")
print("")

local ok_count = 0
for _, entry in ipairs(FILES) do
    if download_file(entry) then
        ok_count = ok_count + 1
    end
    print("")
end

if ok_count == #FILES then
    print("All files ready. Example:")
    print("  strip_miner.lua 1 64")
else
    print(ok_count .. "/" .. #FILES .. " files updated.")
end
