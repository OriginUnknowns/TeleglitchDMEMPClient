# Install the TeleglitchDME mod loader + Teleglitch MP Client mod (FULL runtime).
#
# Deploys EVERY file the mod needs at runtime, so a clean checkout installs to a
# working state. Composes:
#   1. modloader/install-loader.ps1  -> sets up modloader/ and patches init.lua
#   2. mods/mp_client/               -> <GamePath>/mods/mp_client/
#   3. mods/mp_config|json|identity  -> <GamePath>/mods/   (config preserved if present)
#   4. runtime/socket.lua            -> <GamePath>/socket.lua          (LuaSocket loader)
#      runtime/socket/core.dll       -> <GamePath>/socket/core.dll     (LuaSocket native)
#   5. modloader/dllhost/version.dll -> <GamePath>/version.dll         (native bridge; built artifact)
#
# Re-run safely; idempotent.
#
# Usage:  powershell -ExecutionPolicy Bypass -File .\install.ps1
#         .\install.ps1 -GamePath "E:\SteamLibrary\steamapps\common\TeleglitchDME"

param(
    [string]$GamePath = "E:\SteamLibrary\steamapps\common\TeleglitchDME"
)

$ErrorActionPreference = "Stop"

# Step 1: install loader infrastructure (loader.lua, enabled.txt, manager.ps1, init.lua patch).
& (Join-Path $PSScriptRoot "modloader\install-loader.ps1") -GamePath $GamePath

# Step 2: copy mp_client mod folder.
$srcMod = Join-Path $PSScriptRoot "mods\mp_client"
$dstMod = Join-Path $GamePath "mods\mp_client"
New-Item -ItemType Directory -Force -Path $dstMod | Out-Null
Copy-Item -Force -Path (Join-Path $srcMod "init.lua")     -Destination (Join-Path $dstMod "init.lua")
Copy-Item -Force -Path (Join-Path $srcMod "manifest.lua") -Destination (Join-Path $dstMod "manifest.lua")
Write-Host "Copied mp_client mod -> $dstMod"

# Step 3: copy helper mods into <GamePath>/mods/.
#   mp_json.lua / mp_identity.lua are code -> always overwrite.
#   mp_config.lua holds host/port -> only copy if missing, so we don't clobber a
#   user's relay address (mirrors the enabled.txt "preserve toggles" rule).
$modsDst = Join-Path $GamePath "mods"
New-Item -ItemType Directory -Force -Path $modsDst | Out-Null
Copy-Item -Force -Path (Join-Path $PSScriptRoot "mods\mp_json.lua")     -Destination (Join-Path $modsDst "mp_json.lua")
Copy-Item -Force -Path (Join-Path $PSScriptRoot "mods\mp_identity.lua") -Destination (Join-Path $modsDst "mp_identity.lua")
Write-Host "Copied mp_json.lua, mp_identity.lua -> $modsDst"

$cfgDst = Join-Path $modsDst "mp_config.lua"
if (-not (Test-Path $cfgDst)) {
    Copy-Item -Path (Join-Path $PSScriptRoot "mods\mp_config.lua") -Destination $cfgDst
    Write-Host "Created default mp_config.lua (edit host/port for your relay)"
} else {
    Write-Host "Kept existing mp_config.lua (host/port preserved)"
}

# Step 4: LuaSocket runtime. socket.lua is the pure-Lua loader (game root);
# socket/core.dll is the native module. require('socket') needs both.
Copy-Item -Force -Path (Join-Path $PSScriptRoot "runtime\socket.lua") -Destination (Join-Path $GamePath "socket.lua")
$socketDir = Join-Path $GamePath "socket"
New-Item -ItemType Directory -Force -Path $socketDir | Out-Null
Copy-Item -Force -Path (Join-Path $PSScriptRoot "runtime\socket\core.dll") -Destination (Join-Path $socketDir "core.dll")
Write-Host "Copied socket.lua + socket\core.dll (LuaSocket)"

# Step 5: native bridge version.dll (DLL-hijack proxy + luaopen_mp_native).
# Built by modloader\dllhost\build.ps1; gitignored as a regenerable artifact.
# Deploy it if present, otherwise tell the user to build it. The Lua mod runs
# (pure-Lua, no native hooks) without it, but bullet replication needs it.
$dllSrc = Join-Path $PSScriptRoot "modloader\dllhost\version.dll"
if (Test-Path $dllSrc) {
    Copy-Item -Force -Path $dllSrc -Destination (Join-Path $GamePath "version.dll")
    Write-Host "Copied version.dll (native bridge) -> $GamePath"
} else {
    Write-Warning "version.dll not found at $dllSrc -- native bridge will be absent."
    Write-Warning "Build it first:  powershell -ExecutionPolicy Bypass -File .\modloader\dllhost\build.ps1"
}

# Make sure mp_client is in enabled.txt (the loader copies a default that
# already has it, but if the user had a pre-existing enabled.txt without
# this mod, append it).
$enabledTxt = Join-Path $GamePath "modloader\enabled.txt"
$enabled = if (Test-Path $enabledTxt) { Get-Content $enabledTxt } else { @() }
$enabledNames = $enabled | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith("#") }
if ($enabledNames -notcontains "mp_client") {
    Add-Content -Path $enabledTxt -Value "mp_client"
    Write-Host "Appended mp_client to enabled.txt"
}

Write-Host ""
Write-Host "Done. Launch Teleglitch normally."
