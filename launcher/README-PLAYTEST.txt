GLITCHMOD — TELEGLITCH MULTIPLAYER ALPHA
=========================================

Quick start
-----------
1. Extract the entire ZIP. Keep GlitchMod.exe beside the payload folder.
2. Run GlitchMod.exe.
3. Confirm that your Steam Teleglitch: Die More Edition folder is detected.
4. Select MULTIPLAYER ALPHA.
5. Click INSTALL / REPAIR, then LAUNCH MULTIPLAYER.
6. In Teleglitch, use the multiplayer lobby to create or join a room.

There is no separate installer and no files are downloaded at runtime. The
manager backs up files it must replace and REMOVE LOADER restores them. Imported
mod folders are deliberately retained.

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
