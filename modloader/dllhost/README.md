# TeleglitchDME DLL Host (proxy)

A tiny Windows DLL that ships as `version.dll`, gets loaded by
`Teleglitch.exe` via standard DLL search order, forwards every export to
the real `C:\Windows\System32\version.dll`, and on startup `LoadLibrary`s
each native mod listed in `modloader/enabled_native.txt`.

Each native mod is a separate `.dll` placed at
`<GamePath>/mods/<modname>/mod.dll`. The host calls each mod's optional
`ModInit(const ModloaderApi*)` export.

## Status

Source scaffold only — **not yet built**. Compile when we start the MP
DLL overhaul.

## Build (planned)

Needs MSVC Build Tools or MinGW-w64 32-bit (Teleglitch is x86).

```bat
cl /LD /MD /O2 main.cpp /link /OUT:version.dll /DEF:version.def
```

or with MinGW:

```bash
i686-w64-mingw32-g++ -shared -O2 main.cpp -o version.dll -Wl,--out-implib,libversion.a -static-libgcc -static-libstdc++
```

## Install

After build, copy `version.dll` into `<GamePath>/`. Game launches normally;
hosted mods load from `mods/<name>/mod.dll`.
