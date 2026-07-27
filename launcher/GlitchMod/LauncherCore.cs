using Microsoft.Win32;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace GlitchMod
{
    public sealed class LauncherSettings
    {
        public string GamePath { get; set; }
        public string SelectedProfile { get; set; }
        public List<LaunchProfile> Profiles { get; set; }
    }

    public sealed class LaunchProfile
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Description { get; set; }
        public bool Multiplayer { get; set; }
        public List<string> EnabledMods { get; set; }
    }

    public sealed class ModInfo
    {
        public string Folder { get; set; }
        public string Name { get; set; }
        public string Version { get; set; }
        public string Description { get; set; }
    }

    public sealed class PayloadInfo
    {
        public string version { get; set; }
        public RelayInfo relay { get; set; }
        public string[] supported_game_hashes { get; set; }
    }

    public sealed class RelayInfo
    {
        public string host { get; set; }
        public int port { get; set; }
    }

    public sealed class InstallState
    {
        public string payload_version { get; set; }
        public string installed_at_utc { get; set; }
        public string patch_style { get; set; }
        public Dictionary<string, string> backups { get; set; }
        public List<string> managed_files { get; set; }
    }

    public sealed class GameValidation
    {
        public bool Found { get; set; }
        public bool Supported { get; set; }
        public string Hash { get; set; }
        public string Message { get; set; }
    }

    public sealed class LauncherCore
    {
        public const string LoaderBegin = "-- GLITCHMOD_LOADER_BEGIN";
        public const string LoaderEnd = "-- GLITCHMOD_LOADER_END";

        private readonly JavaScriptSerializer json = new JavaScriptSerializer();
        private readonly string appDataDir;
        private readonly string settingsPath;
        private readonly Action<ProcessStartInfo> processStarter;

        public string BaseDirectory { get; private set; }
        public string PayloadDirectory { get; private set; }
        public PayloadInfo Payload { get; private set; }

        public LauncherCore() : this(null)
        {
        }

        public LauncherCore(Action<ProcessStartInfo> processStarter)
        {
            this.processStarter = processStarter ?? (info => { Process.Start(info); });
            BaseDirectory = AppDomain.CurrentDomain.BaseDirectory;
            string appDataOverride = Environment.GetEnvironmentVariable("GLITCHMOD_APPDATA");
            appDataDir = !string.IsNullOrWhiteSpace(appDataOverride)
                ? Path.GetFullPath(appDataOverride)
                : Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "GlitchMod");
            settingsPath = Path.Combine(appDataDir, "settings.json");
            Directory.CreateDirectory(appDataDir);

            string overridePayload = Environment.GetEnvironmentVariable("GLITCHMOD_PAYLOAD");
            PayloadDirectory = !string.IsNullOrWhiteSpace(overridePayload)
                ? Path.GetFullPath(overridePayload)
                : Path.Combine(BaseDirectory, "payload");
            Payload = LoadPayload();
        }

        public LauncherSettings LoadSettings()
        {
            LauncherSettings settings = null;
            if (File.Exists(settingsPath))
            {
                try { settings = json.Deserialize<LauncherSettings>(File.ReadAllText(settingsPath)); }
                catch { settings = null; }
            }
            if (settings == null) settings = NewSettings();
            if (settings.Profiles == null || settings.Profiles.Count == 0)
                settings.Profiles = DefaultProfiles();
            if (string.IsNullOrWhiteSpace(settings.SelectedProfile))
                settings.SelectedProfile = "multiplayer";
            return settings;
        }

        public void SaveSettings(LauncherSettings settings)
        {
            Directory.CreateDirectory(appDataDir);
            WriteUtf8(settingsPath, json.Serialize(settings));
        }

        public PayloadInfo LoadPayload()
        {
            string path = Path.Combine(PayloadDirectory, "release.json");
            if (!File.Exists(path))
            {
                return new PayloadInfo
                {
                    version = "payload missing",
                    relay = new RelayInfo { host = "", port = 0 },
                    supported_game_hashes = new string[0]
                };
            }
            try
            {
                PayloadInfo info = json.Deserialize<PayloadInfo>(File.ReadAllText(path));
                if (info.relay == null) info.relay = new RelayInfo();
                if (info.supported_game_hashes == null) info.supported_game_hashes = new string[0];
                return info;
            }
            catch (Exception ex)
            {
                throw new InvalidDataException("Invalid payload release.json: " + ex.Message, ex);
            }
        }

        public string DetectGamePath()
        {
            foreach (string registryPath in GetRegistryInstallLocations())
            {
                if (LooksLikeGame(registryPath)) return Path.GetFullPath(registryPath);
            }

            foreach (string steamRoot in GetSteamRoots())
            {
                string steamApps = Path.Combine(steamRoot, "steamapps");
                string manifest = Path.Combine(steamApps, "appmanifest_234390.acf");
                string installDir = "TeleglitchDME";
                if (File.Exists(manifest))
                {
                    Match match = Regex.Match(File.ReadAllText(manifest),
                        "\"installdir\"\\s+\"([^\"]+)\"", RegexOptions.IgnoreCase);
                    if (match.Success) installDir = match.Groups[1].Value;
                }
                string candidate = Path.Combine(steamApps, "common", installDir);
                if (LooksLikeGame(candidate)) return Path.GetFullPath(candidate);
            }
            return null;
        }

        public bool LooksLikeGame(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return false;
            return File.Exists(Path.Combine(path, "Teleglitch.exe"))
                && File.Exists(Path.Combine(path, "lua52.dll"))
                && File.Exists(Path.Combine(path, "lua", "init.lua"));
        }

        public GameValidation ValidateGame(string path)
        {
            if (!LooksLikeGame(path))
            {
                return new GameValidation
                {
                    Found = false,
                    Supported = false,
                    Message = "Teleglitch.exe, lua52.dll, or lua\\init.lua is missing."
                };
            }

            string hash = Sha256(Path.Combine(path, "Teleglitch.exe"));
            bool supported = Payload.supported_game_hashes.Any(
                h => string.Equals(h, hash, StringComparison.OrdinalIgnoreCase));
            return new GameValidation
            {
                Found = true,
                Supported = supported,
                Hash = hash,
                Message = supported
                    ? "SUPPORTED STEAM BUILD"
                    : "UNRECOGNIZED GAME BUILD · " + hash.Substring(0, 12)
            };
        }

        public List<ModInfo> ScanMods(string gamePath)
        {
            var result = new List<ModInfo>();
            if (!LooksLikeGame(gamePath)) return result;
            string modsDir = Path.Combine(gamePath, "mods");
            if (!Directory.Exists(modsDir)) return result;

            foreach (string dir in Directory.GetDirectories(modsDir).OrderBy(x => x))
            {
                string manifest = Path.Combine(dir, "manifest.lua");
                if (!File.Exists(manifest)) continue;
                string text = File.ReadAllText(manifest);
                result.Add(new ModInfo
                {
                    Folder = Path.GetFileName(dir),
                    Name = LuaField(text, "name") ?? Path.GetFileName(dir),
                    Version = LuaField(text, "version") ?? "?",
                    Description = LuaField(text, "description") ?? "No description provided."
                });
            }
            return result;
        }

        public InstallState ReadInstallState(string gamePath)
        {
            string path = Path.Combine(gamePath, "modloader", "glitchmod-state.json");
            if (!File.Exists(path)) return null;
            try { return json.Deserialize<InstallState>(File.ReadAllText(path)); }
            catch { return null; }
        }

        public string InstalledVersion(string gamePath)
        {
            InstallState state = ReadInstallState(gamePath);
            return state == null ? null : state.payload_version;
        }

        public void InstallOrRepair(string gamePath, LaunchProfile profile, bool allowUnsupported)
        {
            GameValidation validation = ValidateGame(gamePath);
            if (!validation.Found) throw new InvalidOperationException(validation.Message);
            if (!validation.Supported && !allowUnsupported)
                throw new InvalidOperationException(
                    "This Teleglitch.exe build is not in the payload compatibility list. " +
                    "Native hooks are address-specific, so GlitchMod refused to install.");

            RequirePayloadFile("modloader\\loader.lua");
            RequirePayloadFile("mods\\mp_client\\init.lua");
            RequirePayloadFile("modloader\\dllhost\\version.dll");
            RequirePayloadFile("runtime\\socket\\core.dll");

            string loaderDir = Path.Combine(gamePath, "modloader");
            string backupDir = Path.Combine(loaderDir, "backups", "glitchmod");
            Directory.CreateDirectory(loaderDir);
            Directory.CreateDirectory(backupDir);
            Directory.CreateDirectory(Path.Combine(gamePath, "mods"));

            InstallState state = ReadInstallState(gamePath) ?? new InstallState();
            if (state.backups == null) state.backups = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (state.managed_files == null) state.managed_files = new List<string>();

            var copies = new[]
            {
                Pair("modloader\\loader.lua", "modloader\\loader.lua", false),
                Pair("mods\\mp_client\\init.lua", "mods\\mp_client\\init.lua", false),
                Pair("mods\\mp_client\\manifest.lua", "mods\\mp_client\\manifest.lua", false),
                Pair("mods\\mp_json.lua", "mods\\mp_json.lua", false),
                Pair("mods\\mp_identity.lua", "mods\\mp_identity.lua", false),
                Pair("runtime\\socket.lua", "socket.lua", true),
                Pair("runtime\\socket\\core.dll", "socket\\core.dll", true),
                Pair("modloader\\dllhost\\version.dll", "version.dll", true)
            };

            foreach (FilePair pair in copies)
            {
                string source = Path.Combine(PayloadDirectory, pair.Source);
                string target = Path.Combine(gamePath, pair.Target);
                if (pair.ProtectExisting) BackupCollision(gamePath, target, pair.Target, source, state);
                Directory.CreateDirectory(Path.GetDirectoryName(target));
                File.Copy(source, target, true);
                AddManaged(state, pair.Target);
            }

            PatchGameInit(gamePath, state);
            BackupExisting(gamePath, Path.Combine(gamePath, "mods", "mp_config.lua"),
                "mods\\mp_config.lua", state);
            WriteMultiplayerConfig(gamePath);
            AddManaged(state, "mods\\mp_config.lua");
            ApplyProfile(gamePath, profile);

            state.payload_version = Payload.version;
            state.installed_at_utc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
            string statePath = Path.Combine(loaderDir, "glitchmod-state.json");
            WriteUtf8(statePath, json.Serialize(state));
        }

        public void ApplyProfile(string gamePath, LaunchProfile profile)
        {
            if (!LooksLikeGame(gamePath)) throw new InvalidOperationException("Select a valid Teleglitch installation first.");
            string loaderDir = Path.Combine(gamePath, "modloader");
            Directory.CreateDirectory(loaderDir);
            var mods = (profile.EnabledMods ?? new List<string>())
                .Where(IsSafeFolderName)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
            string enabled = "# Managed by GlitchMod · profile: " + profile.Name + "\r\n"
                + string.Join("\r\n", mods)
                + (mods.Count > 0 ? "\r\n" : "");
            WriteUtf8(Path.Combine(loaderDir, "enabled.txt"), enabled);
            if (profile.Multiplayer) WriteMultiplayerConfig(gamePath);
        }

        public void RemoveLoader(string gamePath)
        {
            if (!LooksLikeGame(gamePath)) throw new InvalidOperationException("Select a valid Teleglitch installation first.");
            InstallState state = ReadInstallState(gamePath);
            if (state != null)
            {
                foreach (string relative in state.managed_files ?? new List<string>())
                {
                    if (!IsSafeRelativePath(relative)) continue;
                    string target = Path.Combine(gamePath, relative);
                    string backupRelative;
                    if (state.backups != null && state.backups.TryGetValue(relative, out backupRelative)
                        && IsSafeRelativePath(backupRelative))
                    {
                        string backup = Path.Combine(gamePath, backupRelative);
                        if (File.Exists(backup))
                        {
                            Directory.CreateDirectory(Path.GetDirectoryName(target));
                            File.Copy(backup, target, true);
                            continue;
                        }
                    }
                    if (File.Exists(target)) File.Delete(target);
                }
            }

            bool restoredInit = false;
            if (state != null && state.backups != null)
            {
                string initBackupRelative;
                if (state.backups.TryGetValue("lua\\init.lua", out initBackupRelative)
                    && IsSafeRelativePath(initBackupRelative))
                {
                    string initBackup = Path.Combine(gamePath, initBackupRelative);
                    if (File.Exists(initBackup))
                    {
                        File.Copy(initBackup, Path.Combine(gamePath, "lua", "init.lua"), true);
                        restoredInit = true;
                    }
                }
            }
            if (!restoredInit) UnpatchGameInit(gamePath);
            string enabledPath = Path.Combine(gamePath, "modloader", "enabled.txt");
            if (File.Exists(enabledPath))
            {
                string[] lines = File.ReadAllLines(enabledPath)
                    .Where(line => !string.Equals(line.Trim(), "mp_client", StringComparison.OrdinalIgnoreCase))
                    .ToArray();
                WriteUtf8(enabledPath, string.Join("\r\n", lines) + "\r\n");
            }
            string statePath = Path.Combine(gamePath, "modloader", "glitchmod-state.json");
            if (File.Exists(statePath)) File.Delete(statePath);
        }

        public void Launch(string gamePath, LaunchProfile profile)
        {
            processStarter(PrepareLaunch(gamePath, profile));
        }

        public ProcessStartInfo PrepareLaunch(string gamePath, LaunchProfile profile)
        {
            ApplyProfile(gamePath, profile);
            return new ProcessStartInfo
            {
                FileName = Path.Combine(gamePath, "Teleglitch.exe"),
                WorkingDirectory = gamePath,
                UseShellExecute = true
            };
        }

        public void OpenGameFolder(string gamePath)
        {
            processStarter(PrepareOpenGameFolder(gamePath));
        }

        public ProcessStartInfo PrepareOpenGameFolder(string gamePath)
        {
            if (string.IsNullOrWhiteSpace(gamePath) || !Directory.Exists(gamePath))
                throw new InvalidOperationException("Select a valid Teleglitch installation first.");
            return new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = "\"" + Path.GetFullPath(gamePath) + "\"",
                UseShellExecute = true
            };
        }

        public ModInfo ImportModZip(string gamePath, string zipPath)
        {
            if (!LooksLikeGame(gamePath)) throw new InvalidOperationException("Select a valid Teleglitch installation first.");
            string importedFolder;
            using (ZipArchive archive = ZipFile.OpenRead(zipPath))
            {
                ZipArchiveEntry manifest = archive.Entries.FirstOrDefault(e =>
                    string.Equals(Path.GetFileName(e.FullName), "manifest.lua", StringComparison.OrdinalIgnoreCase));
                if (manifest == null) throw new InvalidDataException("The ZIP does not contain a manifest.lua.");

                string normalizedManifest = manifest.FullName.Replace('\\', '/').TrimStart('/');
                string prefix = normalizedManifest.Substring(0, normalizedManifest.Length - "manifest.lua".Length).Trim('/');
                string suggested = string.IsNullOrWhiteSpace(prefix)
                    ? Path.GetFileNameWithoutExtension(zipPath)
                    : prefix.Split('/').Last();
                string folder = SafeFolderName(suggested);
                importedFolder = folder;
                string destination = Path.Combine(gamePath, "mods", folder);
                Directory.CreateDirectory(destination);

                string prefixWithSlash = string.IsNullOrWhiteSpace(prefix) ? "" : prefix + "/";
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    string normalized = entry.FullName.Replace('\\', '/').TrimStart('/');
                    if (!normalized.StartsWith(prefixWithSlash, StringComparison.OrdinalIgnoreCase)) continue;
                    string relative = normalized.Substring(prefixWithSlash.Length);
                    if (string.IsNullOrWhiteSpace(relative) || relative.EndsWith("/")) continue;
                    string target = Path.GetFullPath(Path.Combine(destination, relative.Replace('/', Path.DirectorySeparatorChar)));
                    string destinationRoot = Path.GetFullPath(destination) + Path.DirectorySeparatorChar;
                    if (!target.StartsWith(destinationRoot, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("Unsafe path in mod ZIP: " + entry.FullName);
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    using (Stream input = entry.Open())
                    using (FileStream output = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None))
                        input.CopyTo(output);
                }
            }
            return ScanMods(gamePath).FirstOrDefault(m =>
                string.Equals(m.Folder, importedFolder, StringComparison.OrdinalIgnoreCase));
        }

        public async Task<bool> CheckRelayAsync(int timeoutMs)
        {
            if (Payload.relay == null || string.IsNullOrWhiteSpace(Payload.relay.host)
                || Payload.relay.port < 1 || Payload.relay.port > 65535)
                return false;
            using (var client = new TcpClient())
            {
                Task connect = client.ConnectAsync(Payload.relay.host, Payload.relay.port);
                Task timeout = Task.Delay(timeoutMs);
                Task finished = await Task.WhenAny(connect, timeout);
                if (finished != connect) return false;
                try { await connect; return client.Connected; }
                catch { return false; }
            }
        }

        private PayloadInfo NewPayload()
        {
            return new PayloadInfo { relay = new RelayInfo(), supported_game_hashes = new string[0] };
        }

        private LauncherSettings NewSettings()
        {
            return new LauncherSettings
            {
                SelectedProfile = "multiplayer",
                Profiles = DefaultProfiles()
            };
        }

        private static List<LaunchProfile> DefaultProfiles()
        {
            return new List<LaunchProfile>
            {
                new LaunchProfile
                {
                    Id = "multiplayer",
                    Name = "Multiplayer Alpha",
                    Description = "Co-op campaign through the OriginUnknowns relay.",
                    Multiplayer = true,
                    EnabledMods = new List<string> { "mp_client" }
                },
                new LaunchProfile
                {
                    Id = "vanilla",
                    Name = "Vanilla",
                    Description = "Teleglitch with every managed mod disabled.",
                    Multiplayer = false,
                    EnabledMods = new List<string>()
                }
            };
        }

        private IEnumerable<string> GetRegistryInstallLocations()
        {
            foreach (RegistryView view in new[] { RegistryView.Registry32, RegistryView.Registry64 })
            {
                RegistryKey baseKey = null;
                try
                {
                    baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view);
                    using (RegistryKey key = baseKey.OpenSubKey(
                        @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 234390"))
                    {
                        object value = key == null ? null : key.GetValue("InstallLocation");
                        if (value != null) yield return value.ToString();
                    }
                }
                finally { if (baseKey != null) baseKey.Dispose(); }
            }
        }

        private IEnumerable<string> GetSteamRoots()
        {
            var roots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam"))
            {
                object value = key == null ? null : (key.GetValue("SteamPath") ?? key.GetValue("SteamExe"));
                if (value != null)
                {
                    string path = value.ToString().Replace('/', '\\');
                    if (path.EndsWith("steam.exe", StringComparison.OrdinalIgnoreCase))
                        path = Path.GetDirectoryName(path);
                    if (Directory.Exists(path)) roots.Add(path);
                }
            }

            foreach (string root in roots.ToArray())
            {
                string vdf = Path.Combine(root, "steamapps", "libraryfolders.vdf");
                if (!File.Exists(vdf)) continue;
                foreach (Match match in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\""))
                {
                    string path = match.Groups[1].Value.Replace(@"\\", @"\");
                    if (Directory.Exists(path)) roots.Add(path);
                }
            }
            return roots;
        }

        private void WriteMultiplayerConfig(string gamePath)
        {
            if (Payload.relay == null || string.IsNullOrWhiteSpace(Payload.relay.host)
                || Payload.relay.port < 1 || Payload.relay.port > 65535)
                throw new InvalidDataException("The bundled payload has no valid multiplayer relay endpoint.");
            if (!Regex.IsMatch(Payload.relay.host, @"^[A-Za-z0-9.-]+$"))
                throw new InvalidDataException("The bundled relay hostname is invalid.");

            string config = "-- Generated by GlitchMod. Rewritten when the Multiplayer profile is launched.\r\n"
                + "return {\r\n"
                + "    host = \"" + Payload.relay.host + "\",\r\n"
                + "    port = " + Payload.relay.port.ToString(CultureInfo.InvariantCulture) + ",\r\n"
                + "    name_override = nil,\r\n"
                + "    send_rate_hz = 30,\r\n"
                + "}\r\n";
            string target = Path.Combine(gamePath, "mods", "mp_config.lua");
            Directory.CreateDirectory(Path.GetDirectoryName(target));
            WriteUtf8(target, config);
        }

        private void PatchGameInit(string gamePath, InstallState state)
        {
            string initPath = Path.Combine(gamePath, "lua", "init.lua");
            string content = File.ReadAllText(initPath);
            if (content.Contains(LoaderBegin))
            {
                state.patch_style = "glitchmod";
                return;
            }

            string relativeBackup = Path.Combine("modloader", "backups", "glitchmod", "lua-init.pre-glitchmod.lua");
            string backup = Path.Combine(gamePath, relativeBackup);
            if (!File.Exists(backup)) File.Copy(initPath, backup);
            state.backups["lua\\init.lua"] = relativeBackup;

            if (content.Contains("modloader/loader.lua"))
                content = RemoveLegacyLoaderBlock(content);

            string block = "\r\n\r\n" + LoaderBegin + "\r\n"
                + "do\r\n"
                + "    local ok, err = pcall(dofile, \"modloader/loader.lua\")\r\n"
                + "    if not ok then\r\n"
                + "        local f = io.open(\"modloader/init_load_error.txt\", \"w\")\r\n"
                + "        if f then f:write(\"LOADER INIT ERROR: \" .. tostring(err) .. \"\\n\"); f:close() end\r\n"
                + "    end\r\n"
                + "end\r\n"
                + LoaderEnd + "\r\n";
            const string needle = "dofile(\"lua/arenas.lua\")";
            int index = content.IndexOf(needle, StringComparison.Ordinal);
            content = index >= 0
                ? content.Insert(index + needle.Length, block)
                : block + "\r\n" + content;
            WriteUtf8(initPath, content);
            state.patch_style = "glitchmod";
        }

        private void UnpatchGameInit(string gamePath)
        {
            string initPath = Path.Combine(gamePath, "lua", "init.lua");
            if (!File.Exists(initPath)) return;
            string content = File.ReadAllText(initPath);
            int start = content.IndexOf(LoaderBegin, StringComparison.Ordinal);
            int end = content.IndexOf(LoaderEnd, StringComparison.Ordinal);
            if (start >= 0 && end >= start)
            {
                end += LoaderEnd.Length;
                while (start > 0 && (content[start - 1] == '\r' || content[start - 1] == '\n')) start--;
                while (end < content.Length && (content[end] == '\r' || content[end] == '\n')) end++;
                content = content.Remove(start, end - start);
                WriteUtf8(initPath, content);
            }
        }

        private static string RemoveLegacyLoaderBlock(string content)
        {
            int start = content.IndexOf("-- TeleglitchDME mod loader", StringComparison.Ordinal);
            if (start < 0) return content;
            int end = content.IndexOf("\nend", start, StringComparison.Ordinal);
            if (end < 0) return content;
            end += 4;
            while (start > 0 && (content[start - 1] == '\r' || content[start - 1] == '\n')) start--;
            while (end < content.Length && (content[end] == '\r' || content[end] == '\n')) end++;
            return content.Remove(start, end - start);
        }

        private void BackupExisting(string gamePath, string target, string relative, InstallState state)
        {
            if (!File.Exists(target) || state.backups.ContainsKey(relative)) return;
            string safe = Regex.Replace(relative, @"[^A-Za-z0-9._-]", "_");
            string backupRelative = Path.Combine("modloader", "backups", "glitchmod", safe + ".pre-glitchmod.bak");
            string backup = Path.Combine(gamePath, backupRelative);
            Directory.CreateDirectory(Path.GetDirectoryName(backup));
            if (!File.Exists(backup)) File.Copy(target, backup);
            state.backups[relative] = backupRelative;
        }

        private void BackupCollision(string gamePath, string target, string relative, string source, InstallState state)
        {
            if (!File.Exists(target) || FilesEqual(target, source) || state.backups.ContainsKey(relative)) return;
            string safe = Regex.Replace(relative, @"[^A-Za-z0-9._-]", "_");
            string backupRelative = Path.Combine("modloader", "backups", "glitchmod", safe + ".pre-glitchmod.bak");
            string backup = Path.Combine(gamePath, backupRelative);
            Directory.CreateDirectory(Path.GetDirectoryName(backup));
            if (!File.Exists(backup)) File.Copy(target, backup);
            state.backups[relative] = backupRelative;
        }

        private void RequirePayloadFile(string relative)
        {
            string full = Path.Combine(PayloadDirectory, relative);
            if (!File.Exists(full)) throw new FileNotFoundException("Payload is incomplete: " + relative, full);
        }

        private static string LuaField(string content, string field)
        {
            Match match = Regex.Match(content, @"\b" + Regex.Escape(field) + @"\s*=\s*[""']([^""']+)[""']");
            return match.Success ? match.Groups[1].Value : null;
        }

        private static string Sha256(string path)
        {
            using (SHA256 sha = SHA256.Create())
            using (FileStream stream = File.OpenRead(path))
                return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
        }

        private static bool FilesEqual(string a, string b)
        {
            var left = new FileInfo(a);
            var right = new FileInfo(b);
            if (left.Length != right.Length) return false;
            return string.Equals(Sha256(a), Sha256(b), StringComparison.OrdinalIgnoreCase);
        }

        private static void WriteUtf8(string path, string content)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            File.WriteAllText(path, content, new UTF8Encoding(false));
        }

        private static bool IsSafeFolderName(string value)
        {
            return !string.IsNullOrWhiteSpace(value)
                && value.IndexOfAny(Path.GetInvalidFileNameChars()) < 0
                && value != "." && value != "..";
        }

        private static string SafeFolderName(string value)
        {
            string safe = Regex.Replace(value ?? "imported_mod", @"[^A-Za-z0-9._-]", "_").Trim('_', '.');
            return string.IsNullOrWhiteSpace(safe) ? "imported_mod" : safe;
        }

        private static bool IsSafeRelativePath(string relative)
        {
            if (string.IsNullOrWhiteSpace(relative) || Path.IsPathRooted(relative)) return false;
            string normalized = relative.Replace('/', '\\');
            return !normalized.Split('\\').Any(part => part == "..");
        }

        private static void AddManaged(InstallState state, string relative)
        {
            if (!state.managed_files.Any(x => string.Equals(x, relative, StringComparison.OrdinalIgnoreCase)))
                state.managed_files.Add(relative);
        }

        private static FilePair Pair(string source, string target, bool protectExisting)
        {
            return new FilePair { Source = source, Target = target, ProtectExisting = protectExisting };
        }

        private sealed class FilePair
        {
            public string Source;
            public string Target;
            public bool ProtectExisting;
        }
    }
}
