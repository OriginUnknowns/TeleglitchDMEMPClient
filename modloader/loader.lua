-- TeleglitchDME mod loader (Lua side).
--
-- Loaded once from lua/init.lua via:
--     pcall(dofile, "modloader/loader.lua")
--
-- Reads modloader/enabled.txt (one mod name per line, # comments allowed),
-- and dofiles mods/<name>/init.lua for each. Failures are logged to
-- modloader/load_errors.txt but never propagated — one broken mod must
-- not take down the rest.

local function logf(fmt, ...)
    local f = io.open("modloader/loader.log", "a")
    if not f then return end
    f:write(os.date("%H:%M:%S ") .. string.format(fmt, ...) .. "\n")
    f:close()
end

local function log_err(name, err)
    local f = io.open("modloader/load_errors.txt", "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S ") .. name .. ": " .. tostring(err) .. "\n")
        f:close()
    end
end

local function read_enabled()
    local f = io.open("modloader/enabled.txt", "r")
    if not f then return {} end
    local out = {}
    for line in f:lines() do
        local trimmed = line:match("^%s*(.-)%s*$") or ""
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            out[#out + 1] = trimmed
        end
    end
    f:close()
    return out
end

local function load_manifest(name)
    local path = "mods/" .. name .. "/manifest.lua"
    local f = io.open(path, "r")
    if not f then return nil end
    f:close()
    local ok, m = pcall(dofile, path)
    if not ok or type(m) ~= "table" then return nil end
    return m
end

logf("modloader: starting")
local enabled = read_enabled()
logf("modloader: %d mods enabled", #enabled)

local loaded_mods = {}  -- exposed as global for inter-mod handshake
for _, name in ipairs(enabled) do
    local manifest = load_manifest(name)
    local label = manifest and (manifest.name or name) or name
    local version = manifest and manifest.version or "?"
    local entry = "mods/" .. name .. "/init.lua"
    local f = io.open(entry, "r")
    if not f then
        logf("SKIP %s (no init.lua at %s)", name, entry)
        log_err(name, "missing init.lua")
    else
        f:close()
        local ok, err = pcall(dofile, entry)
        if ok then
            logf("OK  %s v%s", label, version)
            loaded_mods[name] = { manifest = manifest }
        else
            logf("ERR %s: %s", label, tostring(err))
            log_err(name, err)
        end
    end
end

_G.MODLOADER = { loaded = loaded_mods, enabled = enabled }
logf("modloader: done")
