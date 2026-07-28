using System;
using System.Windows;

namespace GlitchMod
{
    public partial class App : Application
    {
        private void Application_Startup(object sender, StartupEventArgs e)
        {
            if (LauncherUpdateHelper.IsApplyCommand(e.Args))
            {
                ShutdownMode = ShutdownMode.OnExplicitShutdown;
                Environment.ExitCode = LauncherUpdateHelper.RunApplyCommand(e.Args);
                Shutdown(Environment.ExitCode);
                return;
            }

            var window = new MainWindow();
            MainWindow = window;
            window.Show();
        }
    }
}
