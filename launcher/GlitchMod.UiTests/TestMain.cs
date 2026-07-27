using GlitchMod;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;

namespace GlitchMod.UiTests
{
    internal static class TestMain
    {
        [STAThread]
        private static int Main(string[] args)
        {
            App app = null;
            MainWindow window = null;
            try
            {
                if (args.Length != 2)
                    throw new ArgumentException("Usage: GlitchMod.UiTests.exe <payload> <disposable-game-copy>");

                string payload = Path.GetFullPath(args[0]);
                string game = Path.GetFullPath(args[1]);
                Environment.SetEnvironmentVariable("GLITCHMOD_PAYLOAD", payload);
                Environment.SetEnvironmentVariable("GLITCHMOD_APPDATA", Path.Combine(game, "_ui-test-appdata"));

                var processStarts = new List<ProcessStartInfo>();
                var core = new LauncherCore(info => processStarts.Add(info));
                string importZip = Path.Combine(game, "button-import.zip");
                using (ZipArchive archive = ZipFile.Open(importZip, ZipArchiveMode.Create))
                {
                    WriteEntry(archive, "buttonmod/manifest.lua",
                        "return { name = \"Button Test Mod\", version = \"1.0.0\", description = \"test\" }");
                    WriteEntry(archive, "buttonmod/init.lua", "return true");
                }
                var dialogs = new FakeDialogs
                {
                    GameFolder = game,
                    ModZip = importZip,
                    ConfirmRemove = true,
                    ConfirmUnsupported = true
                };
                LauncherSettings settings = core.LoadSettings();
                settings.GamePath = game;
                settings.SelectedProfile = "vanilla";
                core.SaveSettings(settings);

                app = new App();
                app.InitializeComponent();
                window = new MainWindow(core, dialogs);

                LauncherSettings windowSettings = GetField<LauncherSettings>(window, "settings");
                LaunchProfile vanilla = windowSettings.Profiles.First(profile => profile.Id == "vanilla");
                SetField(window, "selectedProfile", vanilla);
                Invoke(window, "RenderProfiles");
                Invoke(window, "RefreshAll");

                AssertHandlerInventory();
                AssertLaunchButtonColors(app, window);

                var profiles = Find<StackPanel>(window, "ProfilesPanel");
                Check(profiles.Children.Count == 2, "Profile buttons did not render.");
                Click(ProfileButton(profiles, 0));
                Check(Find<TextBlock>(window, "ProfileTitle").Text == "MULTIPLAYER ALPHA",
                    "Multiplayer profile button did not select its profile.");
                Check(Find<Button>(window, "LaunchButton").Content.ToString().Contains("MULTIPLAYER"),
                    "Multiplayer profile did not update the launch button.");
                Check(Find<TextBlock>(window, "ModsSummaryText").Text == "1 enabled",
                    "Multiplayer profile did not report its required mod.");

                profiles = Find<StackPanel>(window, "ProfilesPanel");
                Click(ProfileButton(profiles, 1));
                Check(Find<TextBlock>(window, "ProfileTitle").Text == "VANILLA",
                    "Vanilla profile button did not select its profile.");
                Check(Find<Button>(window, "LaunchButton").Content.ToString().Contains("VANILLA"),
                    "Vanilla profile did not update the launch button.");

                CheckBox modToggle = FindFirst<CheckBox>(Find<StackPanel>(window, "ModsPanel"));
                Check(modToggle != null && modToggle.IsEnabled, "Vanilla mod toggle was not available.");
                modToggle.IsChecked = true;
                Check(Find<TextBlock>(window, "ModsSummaryText").Text == "1 enabled",
                    "Mod toggle did not enable the mod.");
                modToggle.IsChecked = false;
                Check(Find<TextBlock>(window, "ModsSummaryText").Text == "0 enabled",
                    "Mod toggle did not disable the mod.");

                Click(FindButtonByText(window, "CHANGE"));
                Check(Find<TextBlock>(window, "StatusText").Text == "GAME PATH UPDATED",
                    "Change button did not apply the selected game folder.");

                Click(Find<Button>(window, "InstallButton"));
                Check(core.InstalledVersion(game) == core.Payload.version,
                    "Install / Repair button did not install the payload.");
                Check(Find<TextBlock>(window, "LoaderStateText").Text == "Ready",
                    "Install / Repair button did not refresh loader state.");

                processStarts.Clear();
                Click(Find<Button>(window, "LaunchButton"));
                Check(processStarts.Count == 1, "Launch button did not invoke the process starter.");
                Check(processStarts[0].FileName == Path.Combine(game, "Teleglitch.exe"),
                    "Launch button targeted the wrong executable.");
                Check(Find<TextBlock>(window, "StatusText").Text.Contains("RUNNING"),
                    "Launch button did not update status.");

                Button openFolder = FindButtonByText(window, "OPEN GAME FOLDER");
                Check(openFolder != null, "Open Game Folder button was not found.");
                Click(openFolder);
                Check(processStarts.Count == 2, "Open Game Folder button did not invoke the process starter.");
                Check(string.Equals(processStarts[1].FileName, "explorer.exe", StringComparison.OrdinalIgnoreCase),
                    "Open Game Folder button did not target Explorer.");

                Click(FindButtonByText(window, "+  IMPORT MOD ZIP"));
                Check(File.Exists(Path.Combine(game, "mods", "buttonmod", "init.lua")),
                    "Import Mod ZIP button did not import the selected archive.");
                Check(GetField<LauncherSettings>(window, "settings").Profiles
                        .First(profile => profile.Id == "vanilla").EnabledMods.Contains("buttonmod"),
                    "Imported mod was not enabled in the selected profile.");

                Click(FindButtonByText(window, "REMOVE LOADER"));
                Check(core.InstalledVersion(game) == null, "Remove Loader button did not clear install state.");
                Check(File.Exists(Path.Combine(game, "mods", "buttonmod", "init.lua")),
                    "Remove Loader button removed an imported user mod.");

                window.WindowState = WindowState.Normal;
                Click(FindButtonByText(window, "□"));
                Check(window.WindowState == WindowState.Maximized, "Maximize button handler did not maximize.");
                Click(FindButtonByText(window, "□"));
                Check(window.WindowState == WindowState.Normal, "Maximize button handler did not restore.");
                Click(FindButtonByText(window, "—"));
                Check(window.WindowState == WindowState.Minimized, "Minimize button handler did not minimize.");
                window.WindowState = WindowState.Normal;

                Check(dialogs.Errors.Count == 0, "A button path reported an unexpected UI error.");
                Click(FindButtonByText(window, "×"));
                window = null;

                Console.WriteLine("GlitchMod off-screen button audit: PASS");
                Console.WriteLine("All visible buttons and the mod toggle were exercised with fake dialogs/process launching.");
                return 0;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine(error.ToString());
                return 1;
            }
            finally
            {
                if (window != null)
                {
                    try { window.Close(); }
                    catch { }
                }
                if (app != null)
                {
                    try { app.Shutdown(); }
                    catch { }
                }
            }
        }

        private static void AssertHandlerInventory()
        {
            string[] handlers =
            {
                "Profile_Click",
                "ModToggle_Changed",
                "BrowseGame_Click",
                "InstallRepair_Click",
                "Launch_Click",
                "RemoveLoader_Click",
                "ImportMod_Click",
                "OpenGameFolder_Click",
                "Minimize_Click",
                "Maximize_Click",
                "Close_Click"
            };
            foreach (string handler in handlers)
            {
                Check(typeof(MainWindow).GetMethod(handler, BindingFlags.Instance | BindingFlags.NonPublic) != null,
                    "Missing button handler: " + handler);
            }
        }

        private static void WriteEntry(ZipArchive archive, string name, string content)
        {
            ZipArchiveEntry entry = archive.CreateEntry(name);
            using (Stream stream = entry.Open())
            using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
                writer.Write(content);
        }

        private static void AssertLaunchButtonColors(App app, MainWindow window)
        {
            var launch = Find<Button>(window, "LaunchButton");
            launch.ApplyTemplate();
            var border = launch.Template.FindName("Border", launch) as Border;
            Check(border != null, "Launch button template border was not created.");
            Check(TextElement.GetForeground(border).ToString() == launch.Foreground.ToString(),
                "Launch button template did not receive the button foreground.");

            var textStyle = app.Resources[typeof(TextBlock)] as Style;
            bool overridesForeground = textStyle != null && textStyle.Setters
                .OfType<Setter>()
                .Any(setter => setter.Property == TextBlock.ForegroundProperty);
            Check(!overridesForeground, "Implicit TextBlock style overrides button foreground.");
            Check(window.Foreground.ToString() != launch.Foreground.ToString(),
                "Launch button foreground does not contrast with the window text.");
        }

        private static Button ProfileButton(StackPanel panel, int index)
        {
            var border = panel.Children[index] as Border;
            return border == null ? null : border.Child as Button;
        }

        private static Button FindButtonByText(DependencyObject root, string text)
        {
            return Descendants(root).OfType<Button>()
                .FirstOrDefault(button => string.Equals(button.Content as string, text, StringComparison.Ordinal));
        }

        private static T FindFirst<T>(DependencyObject root) where T : DependencyObject
        {
            return Descendants(root).OfType<T>().FirstOrDefault();
        }

        private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
        {
            foreach (object childObject in LogicalTreeHelper.GetChildren(root))
            {
                var child = childObject as DependencyObject;
                if (child == null) continue;
                yield return child;
                foreach (DependencyObject descendant in Descendants(child))
                    yield return descendant;
            }
        }

        private static T Find<T>(FrameworkElement root, string name) where T : FrameworkElement
        {
            T value = root.FindName(name) as T;
            if (value == null) throw new InvalidOperationException("Missing named control: " + name);
            return value;
        }

        private static T GetField<T>(object target, string name)
        {
            FieldInfo field = target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic);
            if (field == null) throw new MissingFieldException(target.GetType().FullName, name);
            return (T)field.GetValue(target);
        }

        private static void SetField(object target, string name, object value)
        {
            FieldInfo field = target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic);
            if (field == null) throw new MissingFieldException(target.GetType().FullName, name);
            field.SetValue(target, value);
        }

        private static object Invoke(object target, string name, params object[] args)
        {
            MethodInfo method = target.GetType().GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic);
            if (method == null) throw new MissingMethodException(target.GetType().FullName, name);
            try { return method.Invoke(target, args); }
            catch (TargetInvocationException error) { throw error.InnerException ?? error; }
        }

        private static void Click(Button button)
        {
            Check(button != null, "Expected button was null.");
            button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        }

        private static void Check(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
        }

        private sealed class FakeDialogs : ILauncherDialogs
        {
            public FakeDialogs()
            {
                Warnings = new List<string>();
                Errors = new List<string>();
            }

            public string GameFolder { get; set; }
            public string ModZip { get; set; }
            public bool ConfirmUnsupported { get; set; }
            public bool ConfirmRemove { get; set; }
            public List<string> Warnings { get; private set; }
            public List<string> Errors { get; private set; }

            public string ChooseGameFolder(string selectedPath) { return GameFolder; }
            public string ChooseModZip(Window owner) { return ModZip; }
            public bool ConfirmUnsupportedBuild(string message) { return ConfirmUnsupported; }
            public bool ConfirmRemoveLoader() { return ConfirmRemove; }
            public void ShowWarning(string message, string title) { Warnings.Add(title + ": " + message); }
            public void ShowError(string message, string title) { Errors.Add(title + ": " + message); }
        }
    }
}
