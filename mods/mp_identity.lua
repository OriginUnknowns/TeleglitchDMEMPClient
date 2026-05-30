-- mp_identity.lua — best-effort player name detection.
-- Priority: explicit config override > Steam PersonaName from loginusers.vdf > Windows USERNAME > "Player".

local M = {}

-- Try common Steam install locations for the loginusers.vdf file.
local function find_loginusers_vdf()
    local candidates = {
        [[C:\Program Files (x86)\Steam\config\loginusers.vdf]],
        [[C:\Program Files\Steam\config\loginusers.vdf]],
        (os.getenv("ProgramFiles(x86)") or "") .. [[\Steam\config\loginusers.vdf]],
        (os.getenv("ProgramFiles") or "")    .. [[\Steam\config\loginusers.vdf]],
        (os.getenv("ProgramW6432") or "")    .. [[\Steam\config\loginusers.vdf]],
    }
    for _, p in ipairs(candidates) do
        local fh = io.open(p, "r")
        if fh then fh:close(); return p end
    end
    return nil
end

-- Parse the user from loginusers.vdf. We want the entry with "MostRecent" "1".
-- VDF format excerpt:
--   "users"
--   {
--       "76561198XXXXXXX"
--       {
--           "AccountName"  "kito_steam"
--           "PersonaName"  "Kito"
--           "MostRecent"   "1"
--       }
--   }
local function parse_steam_persona(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local content = fh:read("*a")
    fh:close()
    if not content then return nil end

    -- Find each user block: "<digits>" { ... "MostRecent" "1" ... "PersonaName" "<name>" ... }
    -- We scan for blocks and pick the one with MostRecent=1.
    local best_name = nil
    local fallback_name = nil  -- last seen persona if no MostRecent flag
    -- A user block is `"steamid64" { ... }`. Match its body.
    for body in content:gmatch('"%d+"%s*{(.-)}\n?%s*"?') do
        local persona = body:match('"PersonaName"%s*"([^"]+)"')
        local most_recent = body:match('"MostRecent"%s*"(%d)"')
        if persona then
            fallback_name = persona
            if most_recent == "1" then best_name = persona end
        end
    end
    return best_name or fallback_name
end

function M.get_name(config_override)
    if config_override and config_override ~= "" then return config_override, "config" end
    -- Steam
    local ok, name = pcall(function()
        local path = find_loginusers_vdf()
        if not path then return nil end
        return parse_steam_persona(path)
    end)
    if ok and name and name ~= "" then return name, "steam" end
    -- Windows username
    local u = os.getenv("USERNAME")
    if u and u ~= "" then return u, "windows" end
    return "Player", "default"
end

return M
