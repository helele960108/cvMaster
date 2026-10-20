/**
 * 应用生命周期：单实例、托盘常驻、事件驱动监听与按需设置窗口。
 * 启动不显示主窗口；创建失败写入无内容日志并安全退出。
 * @author helele
 * @since 2026-10-19
 */
using System.Windows;
using System.Windows.Threading;
using CvMaster.Services;
using CvMaster.Views;
using Microsoft.Win32;

namespace CvMaster;

public partial class App : Application
{
    private SingleInstance? _singleInstance;
    private QuickPanelWindow? _panel;
    private SettingsWindow? _settingsWindow;
    private bool _reportedUnhandled;

    public static AppServices Services { get; private set; } = null!;

    public static App CurrentApp => (App)Current;

    public bool IsShuttingDown { get; private set; }

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _singleInstance = new SingleInstance();
        if (!_singleInstance.TryAcquire())
        {
            Shutdown();
            return;
        }

        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnDomainUnhandledException;
        TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;

        try
        {
            Services = new AppServices();
            Services.Theme.Apply(ThemeService.Parse(Services.Settings.Appearance));
            await Services.InitializeAsync();

            Services.Library.InitializeHotKey();
            _panel = new QuickPanelWindow();
            Services.HotKeys.Pressed += (_, _) => Dispatcher.BeginInvoke(ShowPanel);
            Services.Tray = new TrayIcon(
                togglePanel: () => Dispatcher.BeginInvoke(ShowPanel),
                openSettings: OpenSettings,
                exit: ExitApplication,
                isPaused: () => Services.Library.Paused,
                togglePause: () =>
                {
                    Services.Library.Paused = !Services.Library.Paused;
                    Services.Library.SetFeedback(Services.Library.Paused ? "剪贴板记录已暂停" : "剪贴板记录已恢复");
                });
            Services.Tray.UpdateTooltip(
                $"cvMaster · {Services.Library.ShortcutDisplay}{(Services.Library.Paused ? " · 已暂停" : string.Empty)}");
            Services.StartMonitoring();
            _singleInstance.StartListener(Dispatcher, ShowPanel);
            SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;

            if (!Services.Library.ShortcutAvailable)
            {
                Services.Tray.ShowBalloon("快捷键不可用", "Alt+Space 已被其他应用占用，请点击托盘图标或在设置中更换。");
            }
            else if (!Services.Settings.OnboardingShown)
            {
                Services.Settings.OnboardingShown = true;
                var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(800) };
                timer.Tick += (_, _) =>
                {
                    timer.Stop();
                    Services.Tray?.ShowBalloon(
                        "cvMaster 正在后台运行",
                        $"按 {Services.Library.ShortcutDisplay} 打开列表；首次使用请点击托盘图标开启记录。");
                };
                timer.Start();
            }

            AppLog.Info("startup");
        }
        catch (Exception exception)
        {
            AppLog.Error("startup", exception);
            MessageBox.Show(
                "cvMaster 启动失败。请查看本地日志后重试。",
                "cvMaster",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            ExitApplication();
        }
    }

    private void ShowPanel()
    {
        if (IsShuttingDown)
        {
            return;
        }

        _panel?.ShowPanel();
    }

    public void OpenSettings()
    {
        if (IsShuttingDown)
        {
            return;
        }

        _panel?.HidePanel();
        if (_settingsWindow is { IsVisible: true })
        {
            _settingsWindow.Show();
            _settingsWindow.Activate();
            return;
        }

        _settingsWindow = new SettingsWindow();
        _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    public void ExitApplication()
    {
        if (IsShuttingDown)
        {
            return;
        }

        IsShuttingDown = true;
        AppLog.Info("shutdown");

        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;

        try
        {
            _panel?.HidePanel();
        }
        catch (Exception exception)
        {
            AppLog.Error("shutdown-panel", exception);
        }

        try
        {
            _settingsWindow?.Close();
        }
        catch (Exception exception)
        {
            AppLog.Error("shutdown-settings", exception);
        }

        _ = ShutdownServicesAsync();
    }

    private async Task ShutdownServicesAsync()
    {
        try
        {
            if (Services is not null)
            {
                await Services.DisposeAsync();
            }
        }
        catch (Exception exception)
        {
            AppLog.Error("shutdown-services", exception);
        }
        finally
        {
            Shutdown();
        }
    }

    private void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category == UserPreferenceCategory.General || e.Category == UserPreferenceCategory.Color)
        {
            Dispatcher.BeginInvoke(() => Services.Theme.RefreshSystemAppearance());
        }
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        AppLog.Error("dispatcher-unhandled", e.Exception);
        e.Handled = true;
        if (_reportedUnhandled || IsShuttingDown)
        {
            return;
        }

        _reportedUnhandled = true;
        MessageBox.Show(
            "界面遇到未预期的问题，已记录本地日志。可继续使用，必要时请重启 cvMaster。",
            "cvMaster",
            MessageBoxButton.OK,
            MessageBoxImage.Warning);
    }

    private static void OnDomainUnhandledException(object sender, UnhandledExceptionEventArgs e) =>
        AppLog.Error("domain-unhandled", e.ExceptionObject as Exception);

    private static void OnUnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        AppLog.Error("task-unobserved", e.Exception);
        e.SetObserved();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        _singleInstance?.Dispose();
        base.OnExit(e);
    }
}
