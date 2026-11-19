/**
 * 托盘图标：自己创建隐藏窗口和 Shell_NotifyIcon，支持精确锚定浮层。
 * 图标与菜单由应用主线程持有，退出时显式删除。
 * @author helele
 * @since 2026-10-19
 */
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Threading;
using CvMaster.Interop;
using Microsoft.Win32;

namespace CvMaster.Services;

public sealed class TrayIcon : IDisposable
{
    private const uint IconId = 1;
    private const int CallbackMessage = NativeMethods.WM_APP + 100;
    private const uint AddFlags = NativeMethods.NIF_MESSAGE | NativeMethods.NIF_ICON | NativeMethods.NIF_TIP;

    private readonly Action _togglePanel;
    private readonly Action _openSettings;
    private readonly Action _exit;
    private readonly Func<bool> _isPaused;
    private readonly Action _togglePause;
    private readonly Func<bool, TrayPresentation> _getPresentation;
    private readonly HwndSource _source;
    private readonly uint _taskbarCreatedMessage;
    private readonly TrayIconImages _images = new();
    private IntPtr _publishedIcon;
    private string? _publishedTooltip;
    private bool _lightTaskbar;
    private int _iconSize;
    private bool _refreshQueued;
    private bool _added;
    private bool _ignoreNextUp;
    private bool _disposed;

    internal TrayIcon(
        Action togglePanel,
        Action openSettings,
        Action exit,
        Func<bool> isPaused,
        Action togglePause,
        Func<bool, TrayPresentation> getPresentation)
    {
        _togglePanel = togglePanel;
        _openSettings = openSettings;
        _exit = exit;
        _isPaused = isPaused;
        _togglePause = togglePause;
        _getPresentation = getPresentation;

        var parameters = new HwndSourceParameters("cvMaster.Tray")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0,
            ExtendedWindowStyle = 0x00000080 | 0x08000000 // WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE
        };
        _taskbarCreatedMessage = NativeMethods.RegisterWindowMessageW("TaskbarCreated");
        _source = new HwndSource(parameters);
        try
        {
            _source.AddHook(WndProc);
            RefreshSystemAppearance();
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    public PixelRect? GetIconRect()
    {
        var identifier = new NativeMethods.NOTIFYICONIDENTIFIER
        {
            cbSize = Marshal.SizeOf<NativeMethods.NOTIFYICONIDENTIFIER>(),
            hWnd = _source.Handle,
            uID = IconId,
            guidItem = Guid.Empty
        };
        if (NativeMethods.Shell_NotifyIconGetRect(ref identifier, out var rect) != 0)
        {
            return null;
        }

        return rect.Right > rect.Left && rect.Bottom > rect.Top
            ? new PixelRect(rect.Left, rect.Top, rect.Right, rect.Bottom)
            : null;
    }

    internal void RefreshSystemAppearance()
    {
        if (_disposed)
        {
            return;
        }

        _lightTaskbar = IsLightTaskbar();
        _iconSize = GetTaskbarIconSize();
        RefreshPresentation();
    }

    internal void RefreshPresentation()
    {
        if (_disposed)
        {
            return;
        }

        var presentation = _getPresentation(_lightTaskbar);
        var icon = _images.Get(presentation.ResourcePath, _iconSize);
        var tooltip = Truncate(presentation.Tooltip, 127);
        var flags = !_added ? AddFlags :
            (icon != _publishedIcon ? NativeMethods.NIF_ICON : 0u) |
            (tooltip != _publishedTooltip ? NativeMethods.NIF_TIP : 0u);
        if (flags == 0)
        {
            return;
        }

        var data = CreateData();
        data.uFlags = flags;
        data.uCallbackMessage = CallbackMessage;
        data.hIcon = icon;
        data.szTip = tooltip;
        var operation = _added ? NativeMethods.NIM_MODIFY : NativeMethods.NIM_ADD;
        if (NativeMethods.Shell_NotifyIconW(operation, ref data))
        {
            _added = true;
            _publishedIcon = icon;
            _publishedTooltip = tooltip;
        }
        else
        {
            AppLog.Error(_added ? "tray-modify" : "tray-add");
        }
    }

    public void ShowBalloon(string title, string message)
    {
        if (!_added)
        {
            return;
        }

        var data = CreateData();
        data.uFlags = NativeMethods.NIF_INFO;
        data.szInfoTitle = Truncate(title, 63);
        data.szInfo = Truncate(message, 255);
        data.dwInfoFlags = NativeMethods.NIIF_INFO;
        data.uVersion = 5000;
        NativeMethods.Shell_NotifyIconW(NativeMethods.NIM_MODIFY, ref data);
    }

    private static bool IsLightTaskbar()
    {
        if (SystemParameters.HighContrast)
        {
            // 高对比模式使用系统配色，而不是普通的任务栏主题设置。
            var color = SystemColors.WindowColor;
            return 299 * color.R + 587 * color.G + 114 * color.B >= 128000;
        }

        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", writable: false);
            // 未提供设置时按经典的深色任务栏处理。
            return key?.GetValue("SystemUsesLightTheme") is int value && value != 0;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private int GetTaskbarIconSize()
    {
        // 隐藏窗口不跟随任务栏移动；优先用主任务栏的 DPI。
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 14393))
        {
            return 16;
        }

        var taskbar = NativeMethods.FindWindowW("Shell_TrayWnd", null);
        var dpi = taskbar == IntPtr.Zero ? 0u : NativeMethods.GetDpiForWindow(taskbar);
        if (dpi == 0)
        {
            dpi = NativeMethods.GetDpiForWindow(_source.Handle);
        }

        var size = NativeMethods.GetSystemMetricsForDpi(NativeMethods.SM_CXSMICON, dpi == 0 ? 96u : dpi);
        return Math.Clamp(size, 16, 256);
    }

    private void QueueSystemAppearanceRefresh()
    {
        if (_refreshQueued || _disposed)
        {
            return;
        }

        _refreshQueued = true;
        // 离开消息处理后重读配色，给 WPF 的高对比系统资源一次更新机会。
        _source.Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() =>
        {
            _refreshQueued = false;
            RefreshSystemAppearance();
        }));
    }

    private NativeMethods.NOTIFYICONDATAW CreateData() => new()
    {
        cbSize = (uint)Marshal.SizeOf<NativeMethods.NOTIFYICONDATAW>(),
        hWnd = _source.Handle,
        uID = IconId,
        szTip = string.Empty,
        szInfo = string.Empty,
        szInfoTitle = string.Empty,
        guidItem = Guid.Empty
    };

    private IntPtr WndProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (_taskbarCreatedMessage != 0 && message == _taskbarCreatedMessage)
        {
            _added = false;
            QueueSystemAppearanceRefresh();
            handled = true;
            return IntPtr.Zero;
        }

        if (message is NativeMethods.WM_SETTINGCHANGE or NativeMethods.WM_SYSCOLORCHANGE or
            NativeMethods.WM_THEMECHANGED or NativeMethods.WM_DISPLAYCHANGE or NativeMethods.WM_DPICHANGED)
        {
            QueueSystemAppearanceRefresh();
        }

        if (message != CallbackMessage)
        {
            return IntPtr.Zero;
        }

        var notification = (int)lParam;
        switch (notification)
        {
            case NativeMethods.WM_LBUTTONDBLCLK:
                _ignoreNextUp = true;
                handled = true;
                break;
            case NativeMethods.WM_LBUTTONUP:
                if (_ignoreNextUp)
                {
                    _ignoreNextUp = false;
                }
                else
                {
                    _togglePanel();
                }

                handled = true;
                break;
            case NativeMethods.WM_RBUTTONUP:
            case NativeMethods.WM_CONTEXTMENU:
                ShowContextMenu();
                handled = true;
                break;
        }

        return IntPtr.Zero;
    }

    private void ShowContextMenu()
    {
        var menu = new ContextMenu { Placement = PlacementMode.MousePoint, StaysOpen = false };
        var open = new MenuItem { Header = "打开 cvMaster", FontWeight = FontWeights.SemiBold };
        open.Click += (_, _) => _togglePanel();
        var pause = new MenuItem { Header = _isPaused() ? "恢复记录" : "暂停记录" };
        pause.Click += (_, _) => _togglePause();
        var settings = new MenuItem { Header = "设置…" };
        settings.Click += (_, _) => _openSettings();
        var exit = new MenuItem { Header = "退出 cvMaster" };
        exit.Click += (_, _) => _exit();

        menu.Items.Add(open);
        menu.Items.Add(new Separator());
        menu.Items.Add(pause);
        menu.Items.Add(settings);
        menu.Items.Add(new Separator());
        menu.Items.Add(exit);
        menu.IsOpen = true;
    }

    private static string Truncate(string value, int maximum) =>
        value.Length <= maximum ? value : value[..maximum];

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        try
        {
            if (_added)
            {
                var data = CreateData();
                NativeMethods.Shell_NotifyIconW(NativeMethods.NIM_DELETE, ref data);
                _added = false;
            }
        }
        finally
        {
            try
            {
                _source.Dispose();
            }
            finally
            {
                _images.Dispose();
            }
        }
    }
}
