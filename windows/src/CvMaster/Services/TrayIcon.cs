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
using CvMaster.Interop;

namespace CvMaster.Services;

public sealed class TrayIcon : IDisposable
{
    private const uint IconId = 1;
    private const int CallbackMessage = NativeMethods.WM_APP + 100;
    private const uint TooltipFlags = NativeMethods.NIF_MESSAGE | NativeMethods.NIF_ICON | NativeMethods.NIF_TIP;

    private readonly Action _togglePanel;
    private readonly Action _openSettings;
    private readonly Action _exit;
    private readonly Func<bool> _isPaused;
    private readonly Action _togglePause;
    private readonly HwndSource _source;
    private readonly uint _taskbarCreatedMessage;
    private readonly IntPtr _smallIcon;
    private readonly IntPtr _largeIcon;
    private readonly bool _ownsIcons;
    private string _tooltip = "cvMaster · Alt+Space";
    private bool _added;
    private bool _ignoreNextUp;
    private bool _disposed;

    public TrayIcon(
        Action togglePanel,
        Action openSettings,
        Action exit,
        Func<bool> isPaused,
        Action togglePause)
    {
        _togglePanel = togglePanel;
        _openSettings = openSettings;
        _exit = exit;
        _isPaused = isPaused;
        _togglePause = togglePause;

        var parameters = new HwndSourceParameters("cvMaster.Tray")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0,
            ExtendedWindowStyle = 0x00000080 | 0x08000000 // WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE
        };
        _source = new HwndSource(parameters);
        _source.AddHook(WndProc);
        _taskbarCreatedMessage = NativeMethods.RegisterWindowMessageW("TaskbarCreated");
        var icons = LoadIcons();
        _largeIcon = icons.Large;
        _smallIcon = icons.Small;
        _ownsIcons = icons.Owns;
        AddIcon();
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

    public void UpdateTooltip(string tooltip)
    {
        _tooltip = tooltip;
        if (!_added)
        {
            return;
        }

        var data = CreateData();
        data.uFlags = NativeMethods.NIF_TIP;
        data.szTip = Truncate(tooltip, 127);
        NativeMethods.Shell_NotifyIconW(NativeMethods.NIM_MODIFY, ref data);
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

    private void AddIcon()
    {
        var data = CreateData();
        data.uFlags = TooltipFlags;
        data.uCallbackMessage = CallbackMessage;
        data.hIcon = _smallIcon != IntPtr.Zero ? _smallIcon : _largeIcon;
        data.szTip = Truncate(_tooltip, 127);
        _added = NativeMethods.Shell_NotifyIconW(NativeMethods.NIM_ADD, ref data);
        if (!_added)
        {
            AppLog.Error("tray-add");
        }
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
        if (message == _taskbarCreatedMessage)
        {
            _added = false;
            AddIcon();
            handled = true;
            return IntPtr.Zero;
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

    private static (IntPtr Large, IntPtr Small, bool Owns) LoadIcons()
    {
        var executable = Environment.ProcessPath;
        if (!string.IsNullOrEmpty(executable))
        {
            try
            {
                NativeMethods.ExtractIconExW(executable, 0, out var large, out var small, 1);
                if (large != IntPtr.Zero || small != IntPtr.Zero)
                {
                    return (large, small, true);
                }
            }
            catch (Exception exception)
            {
                AppLog.Error("tray-icon-extract", exception);
            }
        }

        var fallback = NativeMethods.LoadIconW(IntPtr.Zero, NativeMethods.IDI_APPLICATION);
        return (fallback, fallback, false);
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
        if (_added)
        {
            var data = CreateData();
            NativeMethods.Shell_NotifyIconW(NativeMethods.NIM_DELETE, ref data);
            _added = false;
        }

        _source.RemoveHook(WndProc);
        _source.Dispose();
        if (!_ownsIcons)
        {
            return;
        }

        if (_smallIcon != IntPtr.Zero)
        {
            NativeMethods.DestroyIcon(_smallIcon);
        }

        if (_largeIcon != IntPtr.Zero && _largeIcon != _smallIcon)
        {
            NativeMethods.DestroyIcon(_largeIcon);
        }
    }
}
