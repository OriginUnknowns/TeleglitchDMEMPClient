using GlitchMod;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;

namespace GlitchMod.CoreTests
{
    internal static class TestMain
    {
        private static int Main(string[] args)
        {
            try
            {
                if (args.Length != 2)
                    throw new ArgumentException("Usage: GlitchMod.CoreTests.exe <payload> <disposable-game-copy>");

                string payload = Path.GetFullPath(args[0]);
                string game = Path.GetFullPath(args[1]);
                Environment.SetEnvironmentVariable("GLITCHMOD_PAYLOAD", payload);
                Environment.SetEnvironmentVariable("GLITCHMOD_APPDATA", Path.Combine(game, "_test-appdata"));
                var processStarts = new List<ProcessStartInfo>();
                var core = new LauncherCore(info => processStarts.Add(info));
                GameValidation validation = core.ValidateGame(game);
                Check(validation.Found, "Disposable game copy was not detected.");
                Check(validation.Supported, "Disposable game executable hash was not accepted.");
                Check(core.Payload.relay.host == "yamanote.proxy.rlwy.net", "Release relay host mismatch.");
                Check(core.Payload.relay.port == 58057, "Release relay port mismatch.");

                string initPath = Path.Combine(game, "lua", "init.lua");
                byte[] originalInit = File.ReadAllBytes(initPath);
                byte[] versionSentinel = Encoding.ASCII.GetBytes("prior-version-dll");
                byte[] socketSentinel = Encoding.ASCII.GetBytes("prior-socket-core");
                string configSentinel = "-- prior multiplayer config\r\nreturn { host = \"localhost\", port = 1 }\r\n";
                File.WriteAllBytes(Path.Combine(game, "version.dll"), versionSentinel);
                Directory.CreateDirectory(Path.Combine(game, "socket"));
                File.WriteAllBytes(Path.Combine(game, "socket", "core.dll"), socketSentinel);
                Directory.CreateDirectory(Path.Combine(game, "mods"));
                File.WriteAllText(Path.Combine(game, "mods", "mp_config.lua"), configSentinel, new UTF8Encoding(false));

                string statePath = Path.Combine(game, "modloader", "glitchmod-state.json");
                if (File.Exists(statePath)) File.Delete(statePath);

                var multiplayer = new LaunchProfile
                {
                    Id = "multiplayer",
                    Name = "Multiplayer Alpha",
                    Description = "test",
                    Multiplayer = true,
                    EnabledMods = new List<string> { "mp_client" }
                };
                var vanilla = new LaunchProfile
                {
                    Id = "vanilla",
                    Name = "Vanilla",
                    Description = "test",
                    Multiplayer = false,
                    EnabledMods = new List<string>()
                };
                var settings = new LauncherSettings
                {
                    GamePath = game,
                    SelectedProfile = vanilla.Id,
                    Profiles = new List<LaunchProfile> { multiplayer, vanilla }
                };
                core.SaveSettings(settings);
                LauncherSettings reloaded = core.LoadSettings();
                Check(reloaded.GamePath == game, "Saved game path did not reload.");
                Check(reloaded.SelectedProfile == vanilla.Id, "Selected profile did not reload.");

                core.InstallOrRepair(game, multiplayer, false);

                string patchedInit = File.ReadAllText(initPath);
                Check(patchedInit.Contains(LauncherCore.LoaderBegin), "Loader marker was not installed.");
                Check(patchedInit.Contains(LauncherCore.LoaderEnd), "Loader end marker was not installed.");
                Check(File.Exists(statePath), "Install state was not written.");
                string generatedConfig = File.ReadAllText(Path.Combine(game, "mods", "mp_config.lua"));
                Check(generatedConfig.Contains("yamanote.proxy.rlwy.net"), "Relay host was not generated.");
                Check(generatedConfig.Contains("58057"), "Relay port was not generated.");
                Check(File.ReadAllText(Path.Combine(game, "modloader", "enabled.txt")).Contains("mp_client"),
                    "Multiplayer profile did not enable mp_client.");
                Check(core.CheckRelayAsync(10000).GetAwaiter().GetResult(), "Manager relay health check failed.");

                core.ApplyProfile(game, vanilla);
                Check(!File.ReadAllText(Path.Combine(game, "modloader", "enabled.txt")).Contains("mp_client"),
                    "Vanilla profile did not disable mp_client.");
                core.ApplyProfile(game, multiplayer);
                Check(File.ReadAllText(Path.Combine(game, "modloader", "enabled.txt")).Contains("mp_client"),
                    "Multiplayer profile did not restore mp_client.");

                core.Launch(game, vanilla);
                Check(processStarts.Count == 1, "Launch did not invoke the process starter exactly once.");
                Check(processStarts[0].FileName == Path.Combine(game, "Teleglitch.exe"),
                    "Launch targeted the wrong executable.");
                Check(processStarts[0].WorkingDirectory == game, "Launch used the wrong working directory.");
                Check(processStarts[0].UseShellExecute, "Launch did not request shell execution.");
                Check(!File.ReadAllText(Path.Combine(game, "modloader", "enabled.txt")).Contains("mp_client"),
                    "Vanilla launch did not apply the vanilla profile.");

                core.OpenGameFolder(game);
                Check(processStarts.Count == 2, "Open game folder did not invoke the process starter.");
                Check(string.Equals(processStarts[1].FileName, "explorer.exe", StringComparison.OrdinalIgnoreCase),
                    "Open game folder did not target Explorer.");
                Check(processStarts[1].Arguments.Contains(game), "Open game folder used the wrong path.");

                string importedZip = Path.Combine(game, "glitchmod-test-mod.zip");
                using (ZipArchive archive = ZipFile.Open(importedZip, ZipArchiveMode.Create))
                {
                    WriteEntry(archive, "coolmod/manifest.lua",
                        "return { name = \"Cool Test Mod\", version = \"1.2.3\", description = \"test\" }");
                    WriteEntry(archive, "coolmod/init.lua", "return true");
                }
                ModInfo imported = core.ImportModZip(game, importedZip);
                Check(imported != null && imported.Folder == "coolmod", "Safe ZIP mod was not imported.");
                Check(File.Exists(Path.Combine(game, "mods", "coolmod", "init.lua")), "Imported mod content is missing.");

                string maliciousZip = Path.Combine(game, "glitchmod-malicious-mod.zip");
                using (ZipArchive archive = ZipFile.Open(maliciousZip, ZipArchiveMode.Create))
                {
                    WriteEntry(archive, "evil/manifest.lua", "return { name = \"Evil\" }");
                    WriteEntry(archive, "evil/../../escaped.txt", "must not escape");
                }
                bool blocked = false;
                try { core.ImportModZip(game, maliciousZip); }
                catch (InvalidDataException) { blocked = true; }
                Check(blocked, "ZIP path traversal was not blocked.");
                Check(!File.Exists(Path.Combine(game, "escaped.txt")), "ZIP path traversal escaped the mods folder.");

                core.RemoveLoader(game);
                Check(File.ReadAllBytes(initPath).SequenceEqual(originalInit), "lua/init.lua was not restored exactly.");
                Check(File.ReadAllBytes(Path.Combine(game, "version.dll")).SequenceEqual(versionSentinel),
                    "Existing version.dll was not restored.");
                Check(File.ReadAllBytes(Path.Combine(game, "socket", "core.dll")).SequenceEqual(socketSentinel),
                    "Existing socket/core.dll was not restored.");
                Check(File.ReadAllText(Path.Combine(game, "mods", "mp_config.lua")) == configSentinel,
                    "Existing mp_config.lua was not restored.");
                Check(!File.Exists(Path.Combine(game, "mods", "mp_client", "init.lua")),
                    "Managed multiplayer client was not removed.");
                Check(File.Exists(Path.Combine(game, "mods", "coolmod", "init.lua")),
                    "Imported user mod should remain after loader removal.");

                Console.WriteLine("GlitchMod core integration: PASS");
                Console.WriteLine("Payload: " + core.Payload.version);
                Console.WriteLine("Relay: " + core.Payload.relay.host + ":" + core.Payload.relay.port);
                return 0;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine(error.ToString());
                return 1;
            }
        }

        private static void WriteEntry(ZipArchive archive, string name, string content)
        {
            ZipArchiveEntry entry = archive.CreateEntry(name);
            using (Stream stream = entry.Open())
            using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
                writer.Write(content);
        }

        private static void Check(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
        }
    }
}
