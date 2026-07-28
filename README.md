# GlitchMod + Teleglitch DME Multiplayer

GlitchMod is a small profile-based Windows mod manager for **Teleglitch: Die
More Edition**. The bundled Multiplayer Alpha profile installs the native bridge
and Lua client, keeps per-profile mod selections, writes the public relay config,
and launches the game. A Vanilla profile starts the game with all mods disabled.

## Play the multiplayer alpha

1. Open the [GlitchMod Alpha 3 release](https://github.com/OriginUnknowns/TeleglitchDMEMPClient/releases/tag/v0.1.0-alpha.3).
2. Under **Assets**, download `GlitchMod-0.1.0-alpha.3-win-x86.zip`. Do not
   download GitHub's automatic "Source code" ZIP.
3. Extract the entire ZIP, then run `GlitchMod.exe`.
4. GlitchMod normally finds the Steam game automatically. If it does not, click
   **CHANGE** and choose the Teleglitch DME folder containing `Teleglitch.exe`.
5. Select **MULTIPLAYER ALPHA** and click **INSTALL / REPAIR**.
6. Click **LAUNCH MULTIPLAYER**, then create or join a room in the game's
   multiplayer menu.

That is the complete setup. There is no account, command line, port forwarding,
server address, or separate installer. Multiplayer files ship in the ZIP;
GlitchMod only downloads a newer release after you approve its update prompt.
Everyone joining the same room should use the same GlitchMod release.

The `.sha256` asset is optional verification data; most players do not need it.

Starting with Alpha 3, GlitchMod checks public GitHub prereleases at startup.
When an update is available it asks once, verifies the downloaded ZIP against
its published SHA-256, replaces the launcher and bundled payload, and restarts.

## Current multiplayer scope

- Room browser and named rooms
- Up to four players
- Synchronized remote players, projectiles, melee, items, containers, mobs,
  deaths, level exits, campaign transitions, chat, and game over
- One always-on Railway relay replica, exposed over raw TCP

This is an alpha and currently supports the Windows/Steam release of
Teleglitch: Die More Edition.

## Build a release

```powershell
.\launcher\build-release.ps1 `
  -Version 0.1.0-alpha.3 `
  -RelayHost yamanote.proxy.rlwy.net `
  -RelayPort 58057
```

The script builds the 32-bit native proxy DLL and .NET Framework 4.8 manager,
then writes the ZIP and SHA-256 file to `dist/`.
