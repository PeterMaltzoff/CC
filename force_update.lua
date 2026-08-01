-- force_update.lua
-- One-shot download of latest scripts from GitHub (bypasses stale caches).
-- USAGE: force_update

local GITHUB_USER = "PeterMaltzoff"
local GITHUB_REPO = "CC"
local GITHUB_REF  = "main"

local FILES = { "turtle_lib.lua", "strip_miner.lua" }

print("Force update from GitHub (" .. GITHUB_REF .. ")")
print("")

for _, name in ipairs(FILES) do
    local url = ("https://raw.githubusercontent.com/%s/%s/%s/%s?%s"):format(
        GITHUB_USER, GITHUB_REPO, GITHUB_REF, name, os.epoch("utc")
    )
    print("Fetching " .. name .. "...")

    if not http.checkURL(url) then
        print("FAILED: HTTP blocked. Enable HTTP in server config.")
        return
    end

    local response = http.get(url)
    if not response then
        print("FAILED: could not download " .. name)
        return
    end

    local body = response.readAll()
    response.close()

    if body:sub(1, 6) == "<html>" or body:sub(1, 15) == "<!DOCTYPE html>" then
        print("FAILED: bad response for " .. name)
        return
    end

    local handle = fs.open(name, "w")
    if not handle then
        print("FAILED: could not write " .. name)
        return
    end
    handle.write(body)
    handle.close()
    print("OK: " .. name)
end

print("")
print("Done. Run: strip_miner 1 8")
print("You should see: strip_miner 1.0.5")
