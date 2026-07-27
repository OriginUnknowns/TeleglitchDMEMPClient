# Build the modloader DLL host (version.dll proxy).
#
# Requires LLVM-MinGW with i686 target. Install via:
#   winget install --id MartinStorsjo.LLVM-MinGW.UCRT
#
# Outputs version.dll next to this script. Compiles main.cpp together with the
# vendored MinHook sources (main.cpp only #includes MinHook.h, so the .c files
# must be compiled in — otherwise MH_* link as undefined symbols).

$ErrorActionPreference = "Stop"

$compiler = Get-Command "i686-w64-mingw32-g++.exe" -ErrorAction SilentlyContinue
if ($compiler) {
    $cxx = $compiler.Source
} else {
    $wingetRoot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    $cxx = Get-ChildItem -Path $wingetRoot -Filter "i686-w64-mingw32-g++.exe" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*MartinStorsjo.LLVM-MinGW.UCRT*" } |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $cxx -or -not (Test-Path $cxx)) {
    Write-Error "i686 g++ not found. Install with: winget install --id MartinStorsjo.LLVM-MinGW.UCRT"
}

Push-Location $PSScriptRoot
try {
    $sources = @(
        "main.cpp",
        "puff\puff.c",
        "minhook\hook.c",
        "minhook\buffer.c",
        "minhook\trampoline.c",
        "minhook\hde\hde32.c"
    )
    $buildArgs = @("-shared", "-O2", "-static", "-o", "version.dll") +
        $sources +
        @("version.def", "-Wl,--out-implib,libversion.a", "-lkernel32")

    & $cxx @buildArgs
    if ($LASTEXITCODE -ne 0) { Write-Error "Build failed (exit $LASTEXITCODE)" }

    Write-Host "Built: $(Resolve-Path version.dll)"
    Get-Item version.dll | Select-Object Name, Length, LastWriteTime | Format-Table
} finally {
    Pop-Location
}
