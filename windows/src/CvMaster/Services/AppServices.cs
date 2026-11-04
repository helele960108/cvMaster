/**
 * 应用服务容器：把存储、监听、主题、快捷键、托盘与视图模型串成单实例。
 * 剪贴板工作线程的回调统一切回 UI 线程，避免跨线程更新界面状态。
 * @author helele
 * @since 2026-10-19
 */
using System.Windows;
using System.Windows.Threading;
using CvMaster.Core;
using CvMaster.ViewModels;

namespace CvMaster.Services;

public sealed class AppServices : IAsyncDisposable
{
    private bool _disposed;

    public AppServices()
    {
        Settings = new SettingsService();
        Theme = new ThemeService();
        Store = new HistoryStore();
        Thumbnails = new ThumbnailService(Store);
        HotKeys = new HotKeyService();
        Foreground = new ForegroundTracker();
        Library = new LibraryViewModel(Store, Settings, Theme, Thumbnails, HotKeys);
        Monitor = new ClipboardMonitor(
            () => Settings.RecordingEnabled && !Library.Paused,
            () => Settings.SkipSensitive,
            () => Settings.ExcludedProcessList,
            () => Foreground.CaptureCurrentOrLast(),
            () => Library.PrivacyEpoch,
            capture =>
            {
                // 使用采集开始时的代数；排队到 UI 后若暂停、关闭记录或清空，旧回调会被拒绝。
                var privacyEpoch = capture.PrivacyEpoch;
                Dispatch(() => _ = Library.AcceptCaptureAsync(capture, privacyEpoch));
            },
            code => Dispatch(() => Library.ReportCaptureError(code)));
        Library.Monitor = Monitor;
        Paste = new PasteService(Store, Monitor, Settings);
    }

    public SettingsService Settings { get; }

    public ThemeService Theme { get; }

    public HistoryStore Store { get; }

    public ThumbnailService Thumbnails { get; }

    public HotKeyService HotKeys { get; }

    public ForegroundTracker Foreground { get; }

    public ClipboardMonitor Monitor { get; }

    public PasteService Paste { get; }

    public LibraryViewModel Library { get; }

    public TrayIcon? Tray { get; set; }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        await Store.InitializeAsync(cancellationToken);
        await Library.InitializeAsync();
    }

    public void StartMonitoring() => Monitor.Start();

    private static void Dispatch(Action action)
    {
        var application = Application.Current;
        if (application is null)
        {
            return;
        }

        var dispatcher = application.Dispatcher;
        if (dispatcher.HasShutdownStarted || dispatcher.HasShutdownFinished)
        {
            return;
        }

        dispatcher.BeginInvoke(DispatcherPriority.Background, action);
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Tray?.Dispose();
        Monitor.Dispose();
        HotKeys.Dispose();
        Foreground.Dispose();
        Library.Dispose();
        Thumbnails.Dispose();
        await Store.DisposeAsync();
    }
}
