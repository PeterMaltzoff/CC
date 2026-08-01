-- update_miner.lua
-- Download or update turtle scripts from GitHub.
--
-- SETUP (once):
--   1. Create a public GitHub repo and push this project to it.
--   2. Set GITHUB_USER / GITHUB_REPO below.
--   3. Copy this file to the turtle once (re-copy only if this script itself changes).
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
local GITHUB_REF    = "main"
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

    -- Sanity-check strip_miner (reject empty/HTML/cached garbage).
    if entry.path == "strip_miner.lua" and not body:find("local VERSION = ", 1, true) then
        print("FAILED: strip_miner.lua missing VERSION marker — download may be corrupt.")
        return false
    end

    local handle = fs.open(entry.path, "w")
    if not handle then
        print("FAILED: could not write " .. entry.path)
        return false
    end

    handle.write(body)
    handle.close()
    if entry.path == "strip_miner.lua" then
        local ver = body:match('local VERSION = "([^"]+)"')
        if ver then
            print("  Version: " .. ver)
        end
    end
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

-- Default local debug upload target (receive_debug.py on your PC).
if not fs.exists("debug_server.txt") then
    local h = fs.open("debug_server.txt", "w")
    if h then
        h.write("http://127.0.0.1:8787/debug")
        h.close()
        print("Wrote debug_server.txt -> http://127.0.0.1:8787/debug")
    end
end

if ok_count == #FILES then
    print("All files ready. Example:")
    print("  strip_miner.lua 1 64")
    print("Debug upload: run `python receive_debug.py` on PC, then:")
    print("  lua")
    print('  require("turtle_lib").upload_debug()')
else
    print(ok_count .. "/" .. #FILES .. " files updated.")
end
