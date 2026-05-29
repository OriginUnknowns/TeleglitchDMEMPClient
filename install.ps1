# Install the TeleglitchDME mod loader + Teleglitch MP Client mod.
#
# Composes two steps:
#   1. modloader/install-loader.ps1  -> sets up modloader/ and patches init.lua
#   2. Copies mods/mp_client/ into <GamePath>/mods/mp_client/
#
# Re-run safely; idempotent.
#
# Usage:  powershell -ExecutionPolicy Bypass -File .\install.ps1
#         .\install.ps1 -GamePath "E:\SteamLibrary\steamapps\common\TeleglitchDME"

param(
    [string]$GamePath = "E:\SteamLibrary\steamapps\common\TeleglitchDME"
)

$ErrorActionPreference = "Stop"

# Step 1: install loader infrastructure.
& (Join-Path $PSScriptRoot "modloader\install-loader.ps1") -GamePath $GamePath

# Step 2: copy mp_client mod folder.
$srcMod = Join-Path $PSScriptRoot "mods\mp_client"
$dstMod = Join-Path $GamePath "mods\mp_client"
New-Item -ItemType Directory -Force -Path $dstMod | Out-Null
Copy-Item -Force -Path (Join-Path $srcMod "init.lua")     -Destination (Join-Path $dstMod "init.lua")
Copy-Item -Force -Path (Join-Path $srcMod "manifest.lua") -Destination (Join-Path $dstMod "manifest.lua")
Write-Host "Copied mp_client mod -> $dstMod"

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
