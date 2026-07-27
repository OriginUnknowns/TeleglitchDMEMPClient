using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace GlitchMod
{
    public partial class MainWindow : Window
    {
        private readonly LauncherCore core;
        private readonly ILauncherDialogs dialogs;
        private LauncherSettings settings;
        private LaunchProfile selectedProfile;
        private List<ModInfo> installedMods = new List<ModInfo>();

        private Brush Acid { get { return (Brush)FindResource("Acid"); } }
        private Brush Muted { get { return (Brush)FindResource("Muted"); } }
        private Brush Paper { get { return (Brush)FindResource("Paper"); } }
        private Brush Line { get { return (Brush)FindResource("Line"); } }
        private Brush Panel { get { return (Brush)FindResource("Panel"); } }
        private Brush Danger { get { return (Brush)FindResource("Danger"); } }

        public MainWindow() : this(new LauncherCore(), new SystemLauncherDialogs())
        {
        }

        public MainWindow(LauncherCore launcherCore) : this(launcherCore, new SystemLauncherDialogs())
        {
        }

        public MainWindow(LauncherCore launcherCore, ILauncherDialogs launcherDialogs)
        {
            InitializeComponent();
            try
            {
                if (launcherCore == null) throw new ArgumentNullException("launcherCore");
                if (launcherDialogs == null) throw new ArgumentNullException("launcherDialogs");
                core = launcherCore;
                dialogs = launcherDialogs;
                settings = core.LoadSettings();
            }
            catch (Exception ex)
            {
                if (launcherDialogs != null)
                    launcherDialogs.ShowError(ex.Message, "GlitchMod could not start");
                Close();
                return;
            }
            Loaded += MainWindow_Loaded;
        }

        private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
        {
            if (string.IsNullOrWhiteSpace(settings.GamePath) || !core.LooksLikeGame(settings.GamePath))
            {
                settings.GamePath = core.DetectGamePath();
                core.SaveSettings(settings);
            }
            selectedProfile = settings.Profiles.FirstOrDefault(p => p.Id == settings.SelectedProfile)
                ?? settings.Profiles.First();
            RenderProfiles();
            RefreshAll();

            RelayStateText.Text = "Checking…";
            RelayStatusDot.Fill = Muted;
            bool online = await core.CheckRelayAsync(2500);
            RelayStateText.Text = online ? "Online" : "Unavailable";
            RelayStatusDot.Fill = online ? Acid : Danger;
        }

        private void RefreshAll()
        {
            RefreshGameState();
            RenderProfileDetails();
            RenderMods();
        }

        private void RefreshGameState()
        {
            if (string.IsNullOrWhiteSpace(settings.GamePath))
            {
                GamePathText.Text = "No installation selected";
                GameStatusText.Text = "NOT FOUND";
                GameStatusDot.Fill = Danger;
                LoaderStateText.Text = "Not installed";
                LoaderVersionText.Text = "Choose your game folder";
                LaunchButton.IsEnabled = false;
                InstallButton.IsEnabled = false;
                return;
            }

            GamePathText.Text = settings.GamePath;
            GameValidation validation;
            try { validation = core.ValidateGame(settings.GamePath); }
            catch (Exception ex)
            {
                validation = new GameValidation { Found = false, Supported = false, Message = ex.Message };
            }
            GameStatusText.Text = validation.Message;
            GameStatusDot.Fill = validation.Supported ? Acid : (validation.Found ? Brushes.Orange : Danger);
            LaunchButton.IsEnabled = validation.Found;
            InstallButton.IsEnabled = validation.Found;

            string installed = core.InstalledVersion(settings.GamePath);
            if (installed == null)
            {
                LoaderStateText.Text = "Not installed";
                LoaderVersionText.Text = "Ready to install payload " + core.Payload.version;
            }
            else if (string.Equals(installed, core.Payload.version, StringComparison.OrdinalIgnoreCase))
            {
                LoaderStateText.Text = "Ready";
                LoaderVersionText.Text = "Payload " + installed;
            }
            else
            {
                LoaderStateText.Text = "Update available";
                LoaderVersionText.Text = installed + " → " + core.Payload.version;
            }

            RelayAddressText.Text = core.Payload.relay != null
                && !string.IsNullOrWhiteSpace(core.Payload.relay.host)
                ? core.Payload.relay.host + ":" + core.Payload.relay.port
                : "No endpoint configured";
            installedMods = validation.Found ? core.ScanMods(settings.GamePath) : new List<ModInfo>();
        }

        private void RenderProfiles()
        {
            ProfilesPanel.Children.Clear();
            foreach (LaunchProfile profile in settings.Profiles)
            {
                bool active = selectedProfile != null && profile.Id == selectedProfile.Id;
                var border = new Border
                {
                    BorderBrush = active ? Acid : Line,
                    BorderThickness = new Thickness(active ? 1.5 : 1),
                    Background = active ? new SolidColorBrush(Color.FromRgb(31, 38, 30)) : Panel,
                    CornerRadius = new CornerRadius(4),
                    Margin = new Thickness(0, 0, 0, 9)
                };
                var button = new Button
                {
                    Tag = profile.Id,
                    Background = Brushes.Transparent,
                    BorderThickness = new Thickness(0),
                    Padding = new Thickness(13, 11, 11, 11),
                    HorizontalContentAlignment = HorizontalAlignment.Stretch,
                    Cursor = Cursors.Hand
                };
                button.Click += Profile_Click;

                var grid = new Grid();
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
                grid.ColumnDefinitions.Add(new ColumnDefinition());
                var mark = new Rectangle
                {
                    Width = 4,
                    Height = 25,
                    RadiusX = 1,
                    RadiusY = 1,
                    Fill = active ? Acid : Muted,
                    VerticalAlignment = VerticalAlignment.Center
                };
                var text = new StackPanel { Margin = new Thickness(8, 0, 0, 0) };
                text.Children.Add(new TextBlock
                {
                    Text = profile.Name.ToUpperInvariant(),
                    Foreground = active ? Paper : Muted,
                    FontFamily = new FontFamily("Consolas"),
                    FontSize = 12,
                    FontWeight = FontWeights.Bold
                });
                text.Children.Add(new TextBlock
                {
                    Text = profile.Multiplayer ? "NETWORK PROFILE" : "CLEAN PROFILE",
                    Foreground = active ? Acid : Muted,
                    FontFamily = new FontFamily("Consolas"),
                    FontSize = 10,
                    Margin = new Thickness(0, 3, 0, 0)
                });
                Grid.SetColumn(text, 1);
                grid.Children.Add(mark);
                grid.Children.Add(text);
                button.Content = grid;
                border.Child = button;
                ProfilesPanel.Children.Add(border);
            }
        }

        private void RenderProfileDetails()
        {
            if (selectedProfile == null) return;
            ProfileTitle.Text = selectedProfile.Name.ToUpperInvariant();
            ProfileSubtitle.Text = selectedProfile.Description;
            LaunchButton.Content = selectedProfile.Multiplayer ? "▶  LAUNCH MULTIPLAYER" : "▶  LAUNCH VANILLA";
        }

        private void RenderMods()
        {
            ModsPanel.Children.Clear();
            if (selectedProfile == null) return;

            var mods = new List<ModInfo>(installedMods);
            if (!mods.Any(m => m.Folder.Equals("mp_client", StringComparison.OrdinalIgnoreCase)))
            {
                mods.Insert(0, new ModInfo
                {
                    Folder = "mp_client",
                    Name = "Multiplayer Client",
                    Version = core.Payload.version,
                    Description = "Bundled co-op client and native bridge."
                });
            }

            foreach (ModInfo mod in mods)
            {
                bool required = selectedProfile.Multiplayer
                    && mod.Folder.Equals("mp_client", StringComparison.OrdinalIgnoreCase);
                bool enabled = required || selectedProfile.EnabledMods.Any(
                    m => m.Equals(mod.Folder, StringComparison.OrdinalIgnoreCase));
                var border = new Border
                {
                    Background = Panel,
                    BorderBrush = enabled ? Acid : Line,
                    BorderThickness = new Thickness(1),
                    CornerRadius = new CornerRadius(4),
                    Padding = new Thickness(12, 10, 10, 10),
                    Margin = new Thickness(0, 0, 0, 9)
                };
                var grid = new Grid();
                grid.ColumnDefinitions.Add(new ColumnDefinition());
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var info = new StackPanel();
                info.Children.Add(new TextBlock
                {
                    Text = mod.Name,
                    FontFamily = new FontFamily("Segoe UI Semibold"),
                    FontSize = 13,
                    TextTrimming = TextTrimming.CharacterEllipsis
                });
                info.Children.Add(new TextBlock
                {
                    Text = mod.Folder + "  ·  " + mod.Version,
                    Foreground = Muted,
                    FontFamily = new FontFamily("Consolas"),
                    FontSize = 10,
                    Margin = new Thickness(0, 3, 0, 0)
                });
                var toggle = new CheckBox
                {
                    IsChecked = enabled,
                    IsEnabled = !required,
                    Tag = mod.Folder,
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(12, 0, 3, 0),
                    ToolTip = required ? "Required by this profile" : "Enable in this profile"
                };
                toggle.Checked += ModToggle_Changed;
                toggle.Unchecked += ModToggle_Changed;
                Grid.SetColumn(toggle, 1);
                grid.Children.Add(info);
                grid.Children.Add(toggle);
                border.Child = grid;
                ModsPanel.Children.Add(border);
            }
            ModsSummaryText.Text = selectedProfile.EnabledMods.Count + " enabled";
        }

        private void Profile_Click(object sender, RoutedEventArgs e)
        {
            Button clicked = sender as Button;
            string id = clicked == null ? null : clicked.Tag as string;
            LaunchProfile profile = settings.Profiles.FirstOrDefault(p => p.Id == id);
            if (profile == null) return;
            selectedProfile = profile;
            settings.SelectedProfile = profile.Id;
            core.SaveSettings(settings);
            RenderProfiles();
            RenderProfileDetails();
            RenderMods();
            SetStatus("PROFILE SELECTED · " + profile.Name.ToUpperInvariant());
        }

        private void ModToggle_Changed(object sender, RoutedEventArgs e)
        {

            CheckBox box = sender as CheckBox;
            string folder = box == null ? null : box.Tag as string;
            if (string.IsNullOrWhiteSpace(folder) || selectedProfile == null) return;
            selectedProfile.EnabledMods.RemoveAll(m => m.Equals(folder, StringComparison.OrdinalIgnoreCase));
            if (box.IsChecked == true) selectedProfile.EnabledMods.Add(folder);
            if (selectedProfile.Multiplayer
                && !selectedProfile.EnabledMods.Any(m => m.Equals("mp_client", StringComparison.OrdinalIgnoreCase)))
                selectedProfile.EnabledMods.Insert(0, "mp_client");
            core.SaveSettings(settings);
            ModsSummaryText.Text = selectedProfile.EnabledMods.Count + " enabled";
        }

        private void BrowseGame_Click(object sender, RoutedEventArgs e)
        {
            string selectedPath = dialogs.ChooseGameFolder(settings.GamePath);
            if (string.IsNullOrWhiteSpace(selectedPath)) return;
            if (!core.LooksLikeGame(selectedPath))
            {
                dialogs.ShowWarning("That folder does not contain a complete Teleglitch DME installation.",
                    "Not a Teleglitch folder");
                return;
            }
            settings.GamePath = selectedPath;
            core.SaveSettings(settings);
            RefreshAll();
            SetStatus("GAME PATH UPDATED");
        }

        private void InstallRepair_Click(object sender, RoutedEventArgs e)
        {
            RunUiAction("INSTALLING PAYLOAD", () =>
            {
                GameValidation validation = core.ValidateGame(settings.GamePath);
                bool allowUnsupported = false;
                if (!validation.Supported)
                {
                    if (!dialogs.ConfirmUnsupportedBuild(validation.Message)) return;
                    allowUnsupported = true;
                }
                core.InstallOrRepair(settings.GamePath, selectedProfile, allowUnsupported);
                RefreshAll();
                SetStatus("PAYLOAD READY · " + core.Payload.version);
            });
        }

        private void Launch_Click(object sender, RoutedEventArgs e)
        {
            RunUiAction("PREPARING INSTANCE", () =>
            {
                if (selectedProfile.Multiplayer)
                {
                    string installed = core.InstalledVersion(settings.GamePath);
                    if (!string.Equals(installed, core.Payload.version, StringComparison.OrdinalIgnoreCase))
                    {
                        GameValidation validation = core.ValidateGame(settings.GamePath);
                        if (!validation.Supported)
                            throw new InvalidOperationException("This game executable is not supported by the bundled native bridge.");
                        core.InstallOrRepair(settings.GamePath, selectedProfile, false);
                    }
                }
                core.Launch(settings.GamePath, selectedProfile);
                SetStatus("RUNNING · " + selectedProfile.Name.ToUpperInvariant());
            });
        }

        private void RemoveLoader_Click(object sender, RoutedEventArgs e)
        {
            if (!dialogs.ConfirmRemoveLoader()) return;
            RunUiAction("REMOVING LOADER", () =>
            {
                core.RemoveLoader(settings.GamePath);
                RefreshAll();
                SetStatus("LOADER REMOVED");
            });
        }

        private void ImportMod_Click(object sender, RoutedEventArgs e)
        {
            string zipPath = dialogs.ChooseModZip(this);
            if (string.IsNullOrWhiteSpace(zipPath)) return;
            RunUiAction("IMPORTING MOD", () =>
            {
                ModInfo imported = core.ImportModZip(settings.GamePath, zipPath);
                RefreshAll();
                if (imported != null)
                {
                    if (!selectedProfile.EnabledMods.Any(m => m.Equals(imported.Folder, StringComparison.OrdinalIgnoreCase)))
                        selectedProfile.EnabledMods.Add(imported.Folder);
                    core.SaveSettings(settings);
                    RenderMods();
                    SetStatus("IMPORTED · " + imported.Name.ToUpperInvariant());
                }
            });
        }

        private void OpenGameFolder_Click(object sender, RoutedEventArgs e)
        {
            if (string.IsNullOrWhiteSpace(settings.GamePath) || !Directory.Exists(settings.GamePath)) return;
            RunUiAction("OPENING GAME FOLDER", () => core.OpenGameFolder(settings.GamePath));
        }

        private void RunUiAction(string runningStatus, Action action)
        {
            try
            {
                SetStatus(runningStatus);
                action();
            }
            catch (Exception ex)
            {
                SetStatus("ERROR");
                dialogs.ShowError(ex.Message, "GlitchMod");
            }
        }

        private void SetStatus(string value) { StatusText.Text = value; }

        private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ClickCount == 2) ToggleMaximize();
            else DragMove();
        }

        private void Minimize_Click(object sender, RoutedEventArgs e) { WindowState = WindowState.Minimized; }
        private void Maximize_Click(object sender, RoutedEventArgs e) { ToggleMaximize(); }
        private void Close_Click(object sender, RoutedEventArgs e) { Close(); }
        private void ToggleMaximize()
        {
            WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
        }
    }
}
