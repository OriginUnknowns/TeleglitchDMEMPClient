# TeleglitchDME DLL Host (proxy)

A tiny Windows DLL that ships as `version.dll`, gets loaded by
`Teleglitch.exe` via standard DLL search order, forwards every export to
the real `C:\Windows\System32\version.dll`, and on startup `LoadLibrary`s
each native mod listed in `modloader/enabled_native.txt`.

Each native mod is a separate `.dll` placed at
`<GamePath>/mods/<modname>/mod.dll`. The host calls each mod's optional
`ModInit(const ModloaderApi*)` export.

## Status

Foundation working: DLL injects into Teleglitch.exe via version.dll
hijack, logs to `modloader/dllhost.log`, loads optional native mods from
`modloader/enabled_native.txt`. No engine hooks yet.

## Build

Needs LLVM-MinGW with i686 target (Teleglitch is 32-bit x86).

```powershell
winget install --id MartinStorsjo.LLVM-MinGW.UCRT
.\build.ps1
```

Outputs `version.dll` next to this README. The `install-dllhost.ps1`
script (todo) will copy it into the game folder.

## Install

After build, copy `version.dll` into `<GamePath>/`. Game launches normally;
hosted mods load from `mods/<name>/mod.dll`.
