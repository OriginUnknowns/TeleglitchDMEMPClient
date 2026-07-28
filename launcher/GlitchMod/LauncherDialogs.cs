using Microsoft.Win32;
using System.Windows;

namespace GlitchMod
{
    public interface ILauncherDialogs
    {
        string ChooseGameFolder(string selectedPath);
        string ChooseModZip(Window owner);
        bool ConfirmUnsupportedBuild(string message);
        bool ConfirmRemoveLoader();
        bool ConfirmLauncherUpdate(string currentVersion, string newVersion);
        void ShowWarning(string message, string title);
        void ShowError(string message, string title);
    }

    public sealed class SystemLauncherDialogs : ILauncherDialogs
    {
        public string ChooseGameFolder(string selectedPath)
        {
            using (var dialog = new System.Windows.Forms.FolderBrowserDialog())
            {
                dialog.Description = "Choose the Teleglitch: Die More Edition folder";
                dialog.ShowNewFolderButton = false;
                if (!string.IsNullOrWhiteSpace(selectedPath)) dialog.SelectedPath = selectedPath;
                return dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK
                    ? dialog.SelectedPath
                    : null;
            }
        }

        public string ChooseModZip(Window owner)
        {
            var dialog = new OpenFileDialog
            {
                Title = "Import a Teleglitch mod ZIP",
                Filter = "ZIP archives (*.zip)|*.zip",
                CheckFileExists = true
            };
            return dialog.ShowDialog(owner) == true ? dialog.FileName : null;
        }

        public bool ConfirmUnsupportedBuild(string message)
        {
            return MessageBox.Show(
                message + "\n\nThe native bridge is address-specific. Continue only if this is the Steam DME build you expect.",
                "Unrecognized game build", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes;
        }

        public bool ConfirmRemoveLoader()
        {
            return MessageBox.Show(
                "Remove the GlitchMod loader and restore any files it backed up?\n\nImported mod folders will be kept.",
                "Remove loader", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;
        }

        public bool ConfirmLauncherUpdate(string currentVersion, string newVersion)
        {
            return MessageBox.Show(
                "GlitchMod " + newVersion + " is available (installed: " + currentVersion + ").\n\n"
                + "Download the verified update, replace the launcher and bundled payload, then restart GlitchMod?",
                "GlitchMod update available", MessageBoxButton.YesNo, MessageBoxImage.Information)
                == MessageBoxResult.Yes;
        }

        public void ShowWarning(string message, string title)
        {
            MessageBox.Show(message, title, MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        public void ShowError(string message, string title)
        {
            MessageBox.Show(message, title, MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }
}
