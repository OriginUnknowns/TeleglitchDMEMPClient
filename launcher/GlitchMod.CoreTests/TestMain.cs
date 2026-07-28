using GlitchMod;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
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

                Check(LauncherUpdateService.CompareVersions("0.1.0-alpha.10", "0.1.0-alpha.2") > 0,
                    "Updater compared numeric prerelease identifiers lexically.");
                Check(LauncherUpdateService.CompareVersions("0.1.0", "0.1.0-alpha.99") > 0,
                    "Updater did not rank a stable release above its prerelease.");
                Check(LauncherUpdateService.CompareVersions("1.0.0-alpha", "1.0.0-beta") < 0,
                    "Updater prerelease ordering is incorrect.");

                string releaseList = "["
                    + "{\"tag_name\":\"v0.1.0-alpha.3\",\"draft\":true,\"assets\":[]},"
                    + "{\"tag_name\":\"v0.1.0-alpha.10\",\"draft\":false,"
                    + "\"html_url\":\"https://example.invalid/v0.1.0-alpha.10\",\"assets\":["
                    + "{\"name\":\"GlitchMod-0.1.0-alpha.10-win-x86.zip\","
                    + "\"browser_download_url\":\"https://example.invalid/update.zip\"},"
                    + "{\"name\":\"GlitchMod-0.1.0-alpha.10-win-x86.zip.sha256\","
                    + "\"browser_download_url\":\"https://example.invalid/update.zip.sha256\"}]},"
                    + "{\"tag_name\":\"v0.1.0-alpha.9\",\"draft\":false,\"assets\":[]}"
                    + "]";
                LauncherUpdateInfo latest = LauncherUpdateService.SelectLatestRelease(
                    releaseList, "0.1.0-alpha.2");
                Check(latest != null && latest.Version == "0.1.0-alpha.10",
                    "Updater did not select the highest complete non-draft release.");

                string updateVersion = "9.9.9";
                var updateInfo = new LauncherUpdateInfo { Version = updateVersion };
                string updateZip = Path.Combine(game, "verified-update.zip");
                using (ZipArchive archive = ZipFile.Open(updateZip, ZipArchiveMode.Create))
                {
                    WriteEntry(archive, "GlitchMod-" + updateVersion + "/GlitchMod.exe", "new-launcher");
                    WriteEntry(archive, "GlitchMod-" + updateVersion + "/payload/release.json",
                        "{\"version\":\"" + updateVersion + "\",\"relay\":{\"host\":\"example.invalid\",\"port\":1},"
                        + "\"supported_game_hashes\":[]}");
                    WriteEntry(archive, "GlitchMod-" + updateVersion + "/README.txt", "updated");
                }
                string updateHash = Sha256(updateZip);
                string updateWork = Path.Combine(game, "_verified-update");
                Directory.CreateDirectory(updateWork);
                PreparedLauncherUpdate prepared = LauncherUpdateService.VerifyAndExtract(
                    updateInfo, updateZip, updateHash + "  release.zip", updateWork);
                Check(prepared.VerifiedSha256 == updateHash,
                    "Updater did not retain the verified SHA-256.");
                Check(File.Exists(Path.Combine(prepared.PackageDirectory, "payload", "release.json")),
                    "Updater did not safely extract the verified package.");

                string launcherTarget = Path.Combine(game, "_launcher-target");
                Directory.CreateDirectory(Path.Combine(launcherTarget, "payload"));
                File.WriteAllText(Path.Combine(launcherTarget, "GlitchMod.exe"), "old-launcher");
                File.WriteAllText(Path.Combine(launcherTarget, "payload", "release.json"),
                    "{\"version\":\"old\"}");
                LauncherUpdateHelper.ApplyStagedFiles(prepared.PackageDirectory, launcherTarget);
                Check(File.ReadAllText(Path.Combine(launcherTarget, "GlitchMod.exe")) == "new-launcher",
                    "Updater helper did not replace the launcher.");
                Check(File.ReadAllText(Path.Combine(launcherTarget, "README.txt")) == "updated",
                    "Updater helper did not copy the complete release.");

                bool badHashBlocked = false;
                string badHashWork = Path.Combine(game, "_bad-hash-update");
                Directory.CreateDirectory(badHashWork);
                try
                {
                    LauncherUpdateService.VerifyAndExtract(
                        updateInfo, updateZip, new string('0', 64), badHashWork);
                }
                catch (InvalidDataException) { badHashBlocked = true; }
                Check(badHashBlocked, "Updater accepted a release with the wrong SHA-256.");

                string maliciousUpdateZip = Path.Combine(game, "malicious-update.zip");
                using (ZipArchive archive = ZipFile.Open(maliciousUpdateZip, ZipArchiveMode.Create))
                {
                    WriteEntry(archive, "GlitchMod-" + updateVersion + "/GlitchMod.exe", "new-launcher");
                    WriteEntry(archive, "GlitchMod-" + updateVersion + "/payload/release.json",
                        "{\"version\":\"" + updateVersion + "\"}");
                    WriteEntry(archive, "GlitchMod-" + updateVersion + "/../../update-escaped.txt", "blocked");
                }
                bool updateTraversalBlocked = false;
                string maliciousUpdateWork = Path.Combine(game, "_malicious-update");
                Directory.CreateDirectory(maliciousUpdateWork);
                try
                {
                    LauncherUpdateService.VerifyAndExtract(updateInfo, maliciousUpdateZip,
                        Sha256(maliciousUpdateZip), maliciousUpdateWork);
                }
                catch (InvalidDataException) { updateTraversalBlocked = true; }
                Check(updateTraversalBlocked, "Updater ZIP path traversal was not blocked.");
                Check(!File.Exists(Path.Combine(game, "update-escaped.txt")),
                    "Updater ZIP path traversal escaped its staging folder.");

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

        private static string Sha256(string path)
        {
            using (SHA256 sha = SHA256.Create())
            using (FileStream stream = File.OpenRead(path))
                return BitConverter.ToString(sha.ComputeHash(stream))
                    .Replace("-", "").ToLowerInvariant();
        }

        private static void Check(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
        }
    }
}
