# GlitchMod + Teleglitch DME Multiplayer

GlitchMod is a small profile-based Windows mod manager for **Teleglitch: Die
More Edition**. The bundled Multiplayer Alpha profile installs the native bridge
and Lua client, keeps per-profile mod selections, writes the public relay config,
and launches the game. A Vanilla profile starts the game with all mods disabled.

## Player install

Download the latest `GlitchMod-*-win-x86.zip` release, extract it, and run
`GlitchMod.exe`. The ZIP is self-contained; no PowerShell command or separate
runtime install is required.

## Current multiplayer scope

- Room browser and named rooms
- Up to four players
- Synchronized remote players, projectiles, melee, items, containers, mobs,
  deaths, level exits, campaign transitions, chat, and game over
- One always-on Railway relay replica, exposed over raw TCP

This is an alpha. Everyone in a room should use the same GlitchMod release.

## Build a release

```powershell
.\launcher\build-release.ps1 `
  -Version 0.1.0-alpha.1 `
  -RelayHost yamanote.proxy.rlwy.net `
  -RelayPort 58057
```

The script builds the 32-bit native proxy DLL and .NET Framework 4.8 manager,
then writes the ZIP and SHA-256 file to `dist/`.
