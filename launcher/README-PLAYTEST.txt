GLITCHMOD — TELEGLITCH MULTIPLAYER ALPHA
=========================================

Quick start
-----------
1. Extract the entire ZIP. Keep GlitchMod.exe beside the payload folder.
2. Run GlitchMod.exe.
3. GlitchMod normally finds Teleglitch automatically. If it does not, click
   CHANGE and choose the game folder containing Teleglitch.exe.
4. Select MULTIPLAYER ALPHA and click INSTALL / REPAIR.
5. Click LAUNCH MULTIPLAYER.
6. In Teleglitch, create or join a room from the multiplayer menu.

There is no separate installer. Multiplayer assets are bundled; only an update
you approve is downloaded. The manager backs up files it must replace and
REMOVE LOADER restores them. Imported mod folders are deliberately retained.

GlitchMod checks for launcher/payload updates at startup. It asks before
downloading, verifies the published SHA-256, applies the update, and restarts.

Profiles
--------
MULTIPLAYER ALPHA enables the bundled co-op client and connects to the official
playtest relay. VANILLA disables every mod before starting the game.

Mods
----
Use IMPORT MOD ZIP for mods containing a manifest.lua. Each profile remembers
its own enabled-mod list. Native mods or mods made for another Teleglitch build
may still be incompatible; GlitchMod cannot sandbox Lua code.

Alpha notes
-----------
- Windows/Steam Teleglitch: Die More Edition is the supported build.
- Rooms support up to four players.
- Everyone should use the same GlitchMod release.
- Room state is temporary. If the host leaves, the room closes.
- The executable is currently unsigned, so Windows may show a reputation
  warning on first launch.

Support reports are most useful with:
- what each player was doing,
- the level and weapon/item involved,
- modloader\loader.log and mods\mp_client.log from the game folder.
