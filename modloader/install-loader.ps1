# Install the TeleglitchDME mod loader into the game directory.
#
# What it does:
#   1. Copies modloader/loader.lua into <GamePath>/modloader/loader.lua
#   2. Copies modloader/enabled.txt if missing (preserves user toggles)
#   3. Copies modloader/manager.ps1 alongside for the UI
#   4. Patches <GamePath>/lua/init.lua to dofile() loader.lua exactly once
#
# Re-run safely; idempotent. To uninstall: delete the modloader/ folder and
# revert the one-line patch in lua/init.lua (look for "modloader/loader.lua").
#
# Usage:  powershell -ExecutionPolicy Bypass -File .\install-loader.ps1
# Or:     .\install-loader.ps1 -GamePath "E:\SteamLibrary\steamapps\common\TeleglitchDME"

param(
    [string]$GamePath = "E:\SteamLibrary\steamapps\common\TeleglitchDME"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $GamePath)) {
    Write-Error "Game path not found: $GamePath"
}

$loaderDir = Join-Path $GamePath "modloader"
$modsDir   = Join-Path $GamePath "mods"
$initLua   = Join-Path $GamePath "lua\init.lua"
$srcDir    = $PSScriptRoot

New-Item -ItemType Directory -Force -Path $loaderDir | Out-Null
New-Item -ItemType Directory -Force -Path $modsDir   | Out-Null

# Always overwrite loader script (it's our code).
Copy-Item -Force -Path (Join-Path $srcDir "loader.lua")   -Destination (Join-Path $loaderDir "loader.lua")
Write-Host "Copied loader.lua -> $loaderDir\loader.lua"

# Only copy enabled.txt if user doesn't have one yet (preserves toggles).
$enabledDst = Join-Path $loaderDir "enabled.txt"
if (-not (Test-Path $enabledDst)) {
    Copy-Item -Path (Join-Path $srcDir "enabled.txt") -Destination $enabledDst
    Write-Host "Created default enabled.txt"
} else {
    Write-Host "Kept existing enabled.txt"
}

# Manager UI — always overwrite (it's our code).
Copy-Item -Force -Path (Join-Path $srcDir "manager.ps1") -Destination (Join-Path $loaderDir "manager.ps1")
Write-Host "Copied manager.ps1 -> $loaderDir\manager.ps1"

# Patch init.lua exactly once.
$initContent = Get-Content $initLua -Raw
if ($initContent -notmatch 'modloader/loader\.lua') {
    $patch = @'

-- TeleglitchDME mod loader (DO NOT REMOVE this block to keep mods working)
do
    local ok, err = pcall(dofile, "modloader/loader.lua")
    if not ok then
        local f = io.open("modloader/init_load_error.txt", "w")
        if f then f:write("LOADER INIT ERROR: " .. tostring(err) .. "\n"); f:close() end
    end
end

'@
    # Insert after the last dofile() in init.lua's preamble (after arenas.lua).
    if ($initContent -match '(dofile\("lua/arenas\.lua"\))') {
        $patched = $initContent -replace '(dofile\("lua/arenas\.lua"\))', "`$1$patch"
    } else {
        # Fallback: prepend the patch if arenas.lua not found.
        $patched = $patch + "`n" + $initContent
    }
    Set-Content -Path $initLua -Value $patched -Encoding utf8
    Write-Host "Patched init.lua to load mod loader"
} else {
    Write-Host "init.lua already loads mod loader (skipping patch)"
}

Write-Host ""
Write-Host "Mod loader installed."
Write-Host "  Game folder: $GamePath"
Write-Host "  Run the manager UI:  powershell -ExecutionPolicy Bypass -File `"$loaderDir\manager.ps1`""
