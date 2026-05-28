# Installs mp_client.lua into Teleglitch DME by copying into the game's mods/
# folder and patching lua/init.lua to dofile() the mod on startup.
#
# Re-run any time you pull a new version of mp_client.lua. Idempotent.
#
# Usage:   powershell -ExecutionPolicy Bypass -File .\install.ps1
# Or:      .\install.ps1 -GamePath "E:\SteamLibrary\steamapps\common\TeleglitchDME"

param(
    [string]$GamePath = "E:\SteamLibrary\steamapps\common\TeleglitchDME"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $GamePath)) {
    Write-Error "Game path not found: $GamePath"
}

$modsDir = Join-Path $GamePath "mods"
$initLua = Join-Path $GamePath "lua\init.lua"
$srcMod  = Join-Path $PSScriptRoot "mp_client.lua"
$dstMod  = Join-Path $modsDir "mp_client.lua"

if (-not (Test-Path $modsDir)) { New-Item -ItemType Directory -Path $modsDir | Out-Null }

Copy-Item -Path $srcMod -Destination $dstMod -Force
Write-Host "Copied mp_client.lua -> $dstMod"

# Ensure init.lua loads the mod. Patch if not already present.
$initContent = Get-Content $initLua -Raw
if ($initContent -notmatch 'mods/mp_client\.lua') {
    $loader = @'

-- multiplayer client mod
do
    local ok, err = pcall(dofile, "mods/mp_client.lua")
    if not ok then
        local f = io.open("mp_client_load_error.txt", "w")
        if f then f:write("LOAD ERROR: " .. tostring(err) .. "\n"); f:close() end
    end
end

'@
    # Insert after the last dofile(...) call in init.lua's preamble.
    $patched = $initContent -replace '(dofile\("lua/arenas\.lua"\))', "`$1$loader"
    Set-Content -Path $initLua -Value $patched -Encoding utf8
    Write-Host "Patched init.lua to load mp_client.lua"
} else {
    Write-Host "init.lua already loads mp_client.lua (skipping patch)"
}

Write-Host "Done."
