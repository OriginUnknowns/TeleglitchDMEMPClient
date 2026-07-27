param(
    [string]$Version = "0.1.0-alpha.1",
    [Parameter(Mandatory = $true)][string]$RelayHost,
    [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$RelayPort
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$managerDir = Join-Path $PSScriptRoot "GlitchMod"
$distDir = Join-Path $repoRoot "dist"
$stageName = "GlitchMod-$Version"
$stageDir = Join-Path $distDir $stageName
$payloadDir = Join-Path $stageDir "payload"
$zipPath = Join-Path $distDir "$stageName-win-x86.zip"
$hashPath = $zipPath + ".sha256"
$msbuild = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe"

if (-not (Test-Path $msbuild)) {
    throw ".NET Framework MSBuild was not found at $msbuild"
}
if ($RelayHost -notmatch "^[A-Za-z0-9.-]+$") {
    throw "RelayHost must be a DNS hostname."
}

& (Join-Path $repoRoot "modloader\dllhost\build.ps1")
if ($LASTEXITCODE -ne 0) { throw "Native bridge build failed." }

Push-Location $managerDir
try {
    & $msbuild "GlitchMod.csproj" "/t:Rebuild" "/p:Configuration=Release" "/m"
    if ($LASTEXITCODE -ne 0) { throw "GlitchMod build failed." }
} finally {
    Pop-Location
}

if (Test-Path $stageDir) { Remove-Item -LiteralPath $stageDir -Recurse -Force }
if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
if (Test-Path $hashPath) { Remove-Item -LiteralPath $hashPath -Force }

New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
Copy-Item (Join-Path $managerDir "bin\Release\GlitchMod.exe") (Join-Path $stageDir "GlitchMod.exe")
Copy-Item (Join-Path $PSScriptRoot "README-PLAYTEST.txt") (Join-Path $stageDir "README.txt")

$payloadCopies = @(
    @("modloader\loader.lua", "modloader\loader.lua"),
    @("modloader\dllhost\version.dll", "modloader\dllhost\version.dll"),
    @("mods\mp_client\init.lua", "mods\mp_client\init.lua"),
    @("mods\mp_client\manifest.lua", "mods\mp_client\manifest.lua"),
    @("mods\mp_json.lua", "mods\mp_json.lua"),
    @("mods\mp_identity.lua", "mods\mp_identity.lua"),
    @("runtime\socket.lua", "runtime\socket.lua"),
    @("runtime\socket\core.dll", "runtime\socket\core.dll")
)

foreach ($copy in $payloadCopies) {
    $source = Join-Path $repoRoot $copy[0]
    $target = Join-Path $payloadDir $copy[1]
    if (-not (Test-Path $source)) { throw "Missing payload source: $source" }
    New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force
}

$release = [ordered]@{
    version = $Version
    relay = [ordered]@{
        host = $RelayHost
        port = $RelayPort
    }
    supported_game_hashes = @(
        "28DDC3F47A4C65490D82978795C1DB31F81A8F4F4ECDB90F70A3D4E10FBD93B5"
    )
}
$release | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $payloadDir "release.json") -Encoding UTF8

Compress-Archive -LiteralPath $stageDir -DestinationPath $zipPath -CompressionLevel Optimal
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
"$hash  $(Split-Path $zipPath -Leaf)" | Set-Content -LiteralPath $hashPath -Encoding ASCII

Write-Host ""
Write-Host "Built release:"
Write-Host "  $zipPath"
Write-Host "  SHA256 $hash"
