using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace GlitchMod
{
    public sealed class LauncherUpdateInfo
    {
        public string Version { get; set; }
        public string Tag { get; set; }
        public string ReleasePageUrl { get; set; }
        public string ZipUrl { get; set; }
        public string HashUrl { get; set; }
    }

    public sealed class PreparedLauncherUpdate
    {
        public LauncherUpdateInfo Update { get; set; }
        public string WorkDirectory { get; set; }
        public string PackageDirectory { get; set; }
        public string VerifiedSha256 { get; set; }
    }

    public interface ILauncherUpdateService
    {
        Task<LauncherUpdateInfo> CheckForUpdateAsync(string currentVersion, int timeoutMs);
        Task<PreparedLauncherUpdate> PrepareUpdateAsync(LauncherUpdateInfo update, int timeoutMs);
        void StartApply(PreparedLauncherUpdate prepared);
    }

    public sealed class LauncherUpdateService : ILauncherUpdateService
    {
        public const string ReleasesApi =
            "https://api.github.com/repos/OriginUnknowns/TeleglitchDMEMPClient/releases?per_page=20";

        private const long MaximumDownloadBytes = 64L * 1024L * 1024L;
        private const long MaximumExtractedBytes = 256L * 1024L * 1024L;
        private const int MaximumArchiveEntries = 4096;

        private sealed class GitHubRelease
        {
            public string tag_name { get; set; }
            public string html_url { get; set; }
            public bool draft { get; set; }
            public bool prerelease { get; set; }
            public GitHubAsset[] assets { get; set; }
        }

        private sealed class GitHubAsset
        {
            public string name { get; set; }
            public string browser_download_url { get; set; }
        }

        public async Task<LauncherUpdateInfo> CheckForUpdateAsync(string currentVersion, int timeoutMs)
        {
            if (string.IsNullOrWhiteSpace(currentVersion) || currentVersion == "payload missing")
                return null;

            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            using (HttpClient client = CreateClient(timeoutMs, currentVersion))
            {
                string body = await client.GetStringAsync(ReleasesApi).ConfigureAwait(false);
                return SelectLatestRelease(body, currentVersion);
            }
        }

        public async Task<PreparedLauncherUpdate> PrepareUpdateAsync(
            LauncherUpdateInfo update, int timeoutMs)
        {
            if (update == null) throw new ArgumentNullException("update");
            RequireHttps(update.ZipUrl, "release ZIP");
            RequireHttps(update.HashUrl, "release checksum");

            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            string workDirectory = Path.Combine(
                Path.GetTempPath(), "GlitchModUpdate-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(workDirectory);
            string zipPath = Path.Combine(workDirectory, "release.zip");

            try
            {
                byte[] zipBytes;
                byte[] hashBytes;
                using (HttpClient client = CreateClient(timeoutMs, update.Version))
                {
                    Task<byte[]> zipTask = client.GetByteArrayAsync(update.ZipUrl);
                    Task<byte[]> hashTask = client.GetByteArrayAsync(update.HashUrl);
                    await Task.WhenAll(zipTask, hashTask).ConfigureAwait(false);
                    zipBytes = zipTask.Result;
                    hashBytes = hashTask.Result;
                }
                if (zipBytes.LongLength <= 0 || zipBytes.LongLength > MaximumDownloadBytes)
                    throw new InvalidDataException("The downloaded GlitchMod ZIP has an invalid size.");
                if (hashBytes.LongLength <= 0 || hashBytes.LongLength > 16384)
                    throw new InvalidDataException("The downloaded checksum file has an invalid size.");

                File.WriteAllBytes(zipPath, zipBytes);
                string hashText = Encoding.UTF8.GetString(hashBytes);
                return VerifyAndExtract(update, zipPath, hashText, workDirectory);
            }
            catch
            {
                TryDeleteDirectory(workDirectory);
                throw;
            }
        }

        public void StartApply(PreparedLauncherUpdate prepared)
        {
            if (prepared == null || prepared.Update == null)
                throw new ArgumentNullException("prepared");
            if (!Directory.Exists(prepared.PackageDirectory))
                throw new DirectoryNotFoundException("The verified update package is missing.");

            string currentExecutable = Assembly.GetExecutingAssembly().Location;
            string targetDirectory = Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory);
            if (!string.Equals(Path.GetFileName(currentExecutable), "GlitchMod.exe",
                StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException(
                    "Self-update is only available from the packaged GlitchMod.exe.");

            string helperPath = Path.Combine(prepared.WorkDirectory, "GlitchMod-Updater.exe");
            File.Copy(currentExecutable, helperPath, true);
            var start = new ProcessStartInfo
            {
                FileName = helperPath,
                Arguments = "--apply-update "
                    + EncodeArgument(prepared.PackageDirectory) + " "
                    + EncodeArgument(targetDirectory) + " "
                    + Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture),
                WorkingDirectory = prepared.WorkDirectory,
                UseShellExecute = false
            };
            Process.Start(start);
        }

        public static LauncherUpdateInfo SelectLatestRelease(
            string releasesJson, string currentVersion)
        {
            if (string.IsNullOrWhiteSpace(releasesJson)) return null;
            var serializer = new JavaScriptSerializer();
            GitHubRelease[] releases = serializer.Deserialize<GitHubRelease[]>(releasesJson)
                ?? new GitHubRelease[0];
            LauncherUpdateInfo best = null;
            foreach (GitHubRelease release in releases)
            {
                if (release == null || release.draft || string.IsNullOrWhiteSpace(release.tag_name))
                    continue;
                string version = release.tag_name.Trim();
                if (version.StartsWith("v", StringComparison.OrdinalIgnoreCase))
                    version = version.Substring(1);
                if (!IsValidVersion(version) || CompareVersions(version, currentVersion) <= 0)
                    continue;

                string zipName = "GlitchMod-" + version + "-win-x86.zip";
                string hashName = zipName + ".sha256";
                GitHubAsset zip = (release.assets ?? new GitHubAsset[0]).FirstOrDefault(
                    asset => asset != null && string.Equals(asset.name, zipName,
                        StringComparison.OrdinalIgnoreCase));
                GitHubAsset hash = (release.assets ?? new GitHubAsset[0]).FirstOrDefault(
                    asset => asset != null && string.Equals(asset.name, hashName,
                        StringComparison.OrdinalIgnoreCase));
                if (zip == null || hash == null
                    || string.IsNullOrWhiteSpace(zip.browser_download_url)
                    || string.IsNullOrWhiteSpace(hash.browser_download_url))
                    continue;
                if (best != null && CompareVersions(version, best.Version) <= 0) continue;

                best = new LauncherUpdateInfo
                {
                    Version = version,
                    Tag = release.tag_name,
                    ReleasePageUrl = release.html_url,
                    ZipUrl = zip.browser_download_url,
                    HashUrl = hash.browser_download_url
                };
            }
            return best;
        }

        public static int CompareVersions(string left, string right)
        {
            VersionParts a = VersionParts.Parse(left);
            VersionParts b = VersionParts.Parse(right);
            int core = a.Major.CompareTo(b.Major);
            if (core == 0) core = a.Minor.CompareTo(b.Minor);
            if (core == 0) core = a.Patch.CompareTo(b.Patch);
            if (core != 0) return core;
            if (a.PreRelease.Length == 0 && b.PreRelease.Length == 0) return 0;
            if (a.PreRelease.Length == 0) return 1;
            if (b.PreRelease.Length == 0) return -1;
            int common = Math.Min(a.PreRelease.Length, b.PreRelease.Length);
            for (int index = 0; index < common; index++)
            {
                string x = a.PreRelease[index];
                string y = b.PreRelease[index];
                long xn;
                long yn;
                bool xNumber = long.TryParse(x, NumberStyles.None, CultureInfo.InvariantCulture, out xn);
                bool yNumber = long.TryParse(y, NumberStyles.None, CultureInfo.InvariantCulture, out yn);
                int part;
                if (xNumber && yNumber) part = xn.CompareTo(yn);
                else if (xNumber) part = -1;
                else if (yNumber) part = 1;
                else part = string.Compare(x, y, StringComparison.OrdinalIgnoreCase);
                if (part != 0) return part;
            }
            return a.PreRelease.Length.CompareTo(b.PreRelease.Length);
        }

        public static PreparedLauncherUpdate VerifyAndExtract(
            LauncherUpdateInfo update, string zipPath, string hashText, string workDirectory)
        {
            if (update == null) throw new ArgumentNullException("update");
            if (!File.Exists(zipPath)) throw new FileNotFoundException("Update ZIP not found.", zipPath);
            if (!IsValidVersion(update.Version))
                throw new InvalidDataException("The update version is invalid.");
            Match hashMatch = Regex.Match(hashText ?? "", @"(?i)\b[0-9a-f]{64}\b");
            if (!hashMatch.Success)
                throw new InvalidDataException("The release checksum file did not contain a SHA-256 hash.");
            string expectedHash = hashMatch.Value.ToLowerInvariant();
            string actualHash = ComputeSha256(zipPath);
            if (!string.Equals(actualHash, expectedHash, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The downloaded release failed SHA-256 verification.");

            string extractionRoot = Path.Combine(workDirectory, "package");
            if (Directory.Exists(extractionRoot))
                throw new IOException("The update extraction directory already exists.");
            Directory.CreateDirectory(extractionRoot);
            string extractionPrefix = EnsureTrailingSeparator(Path.GetFullPath(extractionRoot));
            string topLevel = null;
            long totalBytes = 0;
            int entryCount = 0;

            using (ZipArchive archive = ZipFile.OpenRead(zipPath))
            {
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    entryCount++;
                    if (entryCount > MaximumArchiveEntries)
                        throw new InvalidDataException("The update archive contains too many files.");
                    if (string.IsNullOrWhiteSpace(entry.FullName) || entry.FullName.Length > 512)
                        throw new InvalidDataException("The update archive contains an invalid path.");

                    string archivePath = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                    string first = archivePath.Split(Path.DirectorySeparatorChar)[0];
                    if (string.IsNullOrWhiteSpace(first) || first == "." || first == "..")
                        throw new InvalidDataException("The update archive has an invalid top-level folder.");
                    if (topLevel == null) topLevel = first;
                    else if (!string.Equals(topLevel, first, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("The update archive must contain one top-level folder.");

                    string destination = Path.GetFullPath(Path.Combine(extractionRoot, archivePath));
                    if (!destination.StartsWith(extractionPrefix, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("The update archive attempted to write outside its folder.");
                    if (entry.FullName.EndsWith("/", StringComparison.Ordinal)
                        || entry.FullName.EndsWith("\\", StringComparison.Ordinal))
                    {
                        Directory.CreateDirectory(destination);
                        continue;
                    }
                    totalBytes += entry.Length;
                    if (totalBytes > MaximumExtractedBytes)
                        throw new InvalidDataException("The expanded update is unexpectedly large.");
                    Directory.CreateDirectory(Path.GetDirectoryName(destination));
                    entry.ExtractToFile(destination, true);
                }
            }

            string expectedTopLevel = "GlitchMod-" + update.Version;
            if (!string.Equals(topLevel, expectedTopLevel, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException(
                    "The update archive folder does not match version " + update.Version + ".");
            string packageDirectory = Path.Combine(extractionRoot, topLevel);
            string executablePath = Path.Combine(packageDirectory, "GlitchMod.exe");
            string releasePath = Path.Combine(packageDirectory, "payload", "release.json");
            if (!File.Exists(executablePath) || !File.Exists(releasePath))
                throw new InvalidDataException("The update archive is missing GlitchMod.exe or payload metadata.");

            var serializer = new JavaScriptSerializer();
            PayloadInfo payload = serializer.Deserialize<PayloadInfo>(File.ReadAllText(releasePath));
            if (payload == null || !string.Equals(payload.version, update.Version,
                StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The update payload version does not match its release.");

            return new PreparedLauncherUpdate
            {
                Update = update,
                WorkDirectory = workDirectory,
                PackageDirectory = packageDirectory,
                VerifiedSha256 = actualHash
            };
        }

        private static HttpClient CreateClient(int timeoutMs, string version)
        {
            var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = true });
            client.Timeout = TimeSpan.FromMilliseconds(Math.Max(1000, timeoutMs));
            client.DefaultRequestHeaders.UserAgent.ParseAdd(
                "GlitchMod/" + (string.IsNullOrWhiteSpace(version) ? "unknown" : version));
            client.DefaultRequestHeaders.Accept.Add(
                new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
            return client;
        }

        private static void RequireHttps(string value, string label)
        {
            Uri uri;
            if (!Uri.TryCreate(value, UriKind.Absolute, out uri)
                || uri.Scheme != Uri.UriSchemeHttps)
                throw new InvalidDataException("The " + label + " URL is not HTTPS.");
        }

        private static bool IsValidVersion(string value)
        {
            return !string.IsNullOrWhiteSpace(value)
                && Regex.IsMatch(value, @"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$");
        }

        private static string ComputeSha256(string path)
        {
            using (SHA256 sha = SHA256.Create())
            using (FileStream stream = File.OpenRead(path))
                return BitConverter.ToString(sha.ComputeHash(stream))
                    .Replace("-", "").ToLowerInvariant();
        }

        private static string EnsureTrailingSeparator(string path)
        {
            return path.EndsWith(Path.DirectorySeparatorChar.ToString(), StringComparison.Ordinal)
                ? path
                : path + Path.DirectorySeparatorChar;
        }

        private static string EncodeArgument(string value)
        {
            return Convert.ToBase64String(Encoding.UTF8.GetBytes(value ?? ""));
        }

        private static void TryDeleteDirectory(string path)
        {
            try
            {
                if (Directory.Exists(path)) Directory.Delete(path, true);
            }
            catch { }
        }

        private sealed class VersionParts
        {
            public long Major;
            public long Minor;
            public long Patch;
            public string[] PreRelease;

            public static VersionParts Parse(string value)
            {
                value = (value ?? "0.0.0").Trim();
                if (value.StartsWith("v", StringComparison.OrdinalIgnoreCase))
                    value = value.Substring(1);
                int plus = value.IndexOf('+');
                if (plus >= 0) value = value.Substring(0, plus);
                string[] halves = value.Split(new[] { '-' }, 2);
                string[] core = halves[0].Split('.');
                long major;
                long minor;
                long patch;
                long.TryParse(core.Length > 0 ? core[0] : "0", out major);
                long.TryParse(core.Length > 1 ? core[1] : "0", out minor);
                long.TryParse(core.Length > 2 ? core[2] : "0", out patch);
                return new VersionParts
                {
                    Major = major,
                    Minor = minor,
                    Patch = patch,
                    PreRelease = halves.Length > 1
                        ? halves[1].Split(new[] { '.' }, StringSplitOptions.RemoveEmptyEntries)
                        : new string[0]
                };
            }
        }
    }

    public static class LauncherUpdateHelper
    {
        private const int MoveFileDelayUntilReboot = 0x4;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool MoveFileEx(string existingFile, string newFile, int flags);

        public static bool IsApplyCommand(string[] args)
        {
            return args != null && args.Length >= 4
                && string.Equals(args[0], "--apply-update", StringComparison.Ordinal);
        }

        public static int RunApplyCommand(string[] args)
        {
            string logPath = Path.Combine(Path.GetTempPath(), "GlitchMod-update.log");
            try
            {
                if (!IsApplyCommand(args)) return 2;
                string packageDirectory = DecodeArgument(args[1]);
                string targetDirectory = DecodeArgument(args[2]);
                int processId;
                if (!int.TryParse(args[3], NumberStyles.None, CultureInfo.InvariantCulture,
                    out processId))
                    throw new InvalidDataException("The updater received an invalid process ID.");

                WaitForProcess(processId);
                ApplyStagedFiles(packageDirectory, targetDirectory);

                string targetExecutable = Path.Combine(targetDirectory, "GlitchMod.exe");
                Process.Start(new ProcessStartInfo
                {
                    FileName = targetExecutable,
                    WorkingDirectory = targetDirectory,
                    UseShellExecute = true
                });

                TryDeleteDirectory(Path.GetDirectoryName(packageDirectory));
                string self = Assembly.GetExecutingAssembly().Location;
                MoveFileEx(self, null, MoveFileDelayUntilReboot);
                File.WriteAllText(logPath,
                    DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture)
                    + " update applied successfully" + Environment.NewLine);
                return 0;
            }
            catch (Exception error)
            {
                try
                {
                    File.WriteAllText(logPath,
                        DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture)
                        + " update failed" + Environment.NewLine + error + Environment.NewLine);
                }
                catch { }
                return 1;
            }
        }

        public static void ApplyStagedFiles(string packageDirectory, string targetDirectory)
        {
            string package = Path.GetFullPath(packageDirectory);
            string target = Path.GetFullPath(targetDirectory);
            string packagePrefix = EnsureTrailingSeparator(package);
            string targetPrefix = EnsureTrailingSeparator(target);
            if (!Directory.Exists(package)
                || !File.Exists(Path.Combine(package, "GlitchMod.exe"))
                || !File.Exists(Path.Combine(package, "payload", "release.json")))
                throw new InvalidDataException("The staged GlitchMod update is incomplete.");
            if (!Directory.Exists(target)
                || string.Equals(target, Path.GetPathRoot(target), StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The updater target directory is unsafe.");

            foreach (string source in Directory.GetFiles(package, "*", SearchOption.AllDirectories))
            {
                string fullSource = Path.GetFullPath(source);
                if (!fullSource.StartsWith(packagePrefix, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("The staged update contains an unsafe source path.");
                string relative = fullSource.Substring(packagePrefix.Length);
                string destination = Path.GetFullPath(Path.Combine(target, relative));
                if (!destination.StartsWith(targetPrefix, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("The staged update contains an unsafe destination path.");
                Directory.CreateDirectory(Path.GetDirectoryName(destination));
                CopyWithRetry(fullSource, destination);
            }
        }

        private static void CopyWithRetry(string source, string destination)
        {
            Exception last = null;
            for (int attempt = 0; attempt < 20; attempt++)
            {
                try
                {
                    File.Copy(source, destination, true);
                    return;
                }
                catch (IOException error)
                {
                    last = error;
                    Thread.Sleep(150);
                }
                catch (UnauthorizedAccessException error)
                {
                    last = error;
                    Thread.Sleep(150);
                }
            }
            throw new IOException("Could not replace " + destination + ".", last);
        }

        private static void WaitForProcess(int processId)
        {
            if (processId <= 0) return;
            try
            {
                Process process = Process.GetProcessById(processId);
                process.WaitForExit(30000);
                if (!process.HasExited)
                    throw new TimeoutException("GlitchMod did not exit in time for its update.");
            }
            catch (ArgumentException)
            {
                // The parent already exited.
            }
        }

        private static string DecodeArgument(string value)
        {
            return Encoding.UTF8.GetString(Convert.FromBase64String(value));
        }

        private static string EnsureTrailingSeparator(string path)
        {
            return path.EndsWith(Path.DirectorySeparatorChar.ToString(), StringComparison.Ordinal)
                ? path
                : path + Path.DirectorySeparatorChar;
        }

        private static void TryDeleteDirectory(string path)
        {
            try
            {
                if (Directory.Exists(path)) Directory.Delete(path, true);
            }
            catch { }
        }
    }
}
