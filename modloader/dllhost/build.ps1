# Build the modloader DLL host (version.dll proxy).
#
# Requires LLVM-MinGW with i686 target. Install via:
#   winget install --id MartinStorsjo.LLVM-MinGW.UCRT
#
# Outputs version.dll next to this script.

$ErrorActionPreference = "Stop"

$cxx = "C:\Users\Toni\AppData\Local\Microsoft\WinGet\Packages\MartinStorsjo.LLVM-MinGW.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe\llvm-mingw-20260519-ucrt-x86_64\bin\i686-w64-mingw32-g++.exe"
if (-not (Test-Path $cxx)) {
    Write-Error "i686 g++ not found. Install with: winget install --id MartinStorsjo.LLVM-MinGW.UCRT"
}

Push-Location $PSScriptRoot
try {
    & $cxx -shared -O2 -static `
        -o version.dll `
        main.cpp version.def `
        -Wl,--out-implib,libversion.a `
        -lkernel32

    if ($LASTEXITCODE -ne 0) { Write-Error "Build failed (exit $LASTEXITCODE)" }

    Write-Host "Built: $(Resolve-Path version.dll)"
    Get-Item version.dll | Select-Object Name, Length, LastWriteTime | Format-Table
} finally {
    Pop-Location
}
