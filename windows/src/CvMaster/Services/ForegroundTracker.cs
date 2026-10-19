/**
 * 前台窗口追踪：记录最近一个非本进程、非任务栏的外部窗口。
 * 点击托盘图标不会丢失原输入位置；粘贴时只回到该窗口。
 * @author helele
 * @since 2026-10-19
 */
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using CvMaster.Interop;

namespace CvMaster.Services;

public sealed record ForegroundInfo(IntPtr Handle, int ProcessId, string ProcessName)
{
    public PasteTarget ToTarget() => new(Handle, ProcessId, ProcessName);
}

public sealed record PasteTarget(IntPtr Handle, int ProcessId, string ProcessName);

public sealed class ForegroundTracker : IDisposable
{
    private static readonly HashSet<string> ShellClasses = new(StringComparer.OrdinalIgnoreCase)
    {
        "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow", "Progman", "WorkerW"
    };

    private readonly object _gate = new();
    private readonly NativeMethods.WinEventDelegate _callback;
    private readonly IntPtr _hook;
    private ForegroundInfo? _last;
    private bool _disposed;

    public ForegroundTracker()
    {
        _callback = OnForegroundChanged;
        _hook = NativeMethods.SetWinEventHook(
            NativeMethods.EVENT_SYSTEM_FOREGROUND,
            NativeMethods.EVENT_SYSTEM_FOREGROUND,
            IntPtr.Zero,
            _callback,
            0,
            0,
            NativeMethods.WINEVENT_OUTOFCONTEXT);
        if (_hook == IntPtr.Zero)
        {
            AppLog.Error("foreground-hook");
        }
    }

    public ForegroundInfo? LastExternal
    {
        get
        {
            lock (_gate)
            {
                return _last;
            }
        }
    }

    /// <summary>优先使用当前外部前台窗口；任务栏或本应用获得焦点时回退到最近外部窗口。</summary>
    public ForegroundInfo? CaptureCurrentOrLast()
    {
        var current = Describe(NativeMethods.GetForegroundWindow());
        if (current is not null)
        {
            Remember(current);
            return current;
        }

        return LastExternal;
    }

    private void OnForegroundChanged(
        IntPtr hook,
        uint eventType,
        IntPtr hwnd,
        int idObject,
        int idChild,
        uint thread,
        uint time)
    {
        if (eventType != NativeMethods.EVENT_SYSTEM_FOREGROUND)
        {
            return;
        }

        var info = Describe(hwnd);
        if (info is not null)
        {
            Remember(info);
        }
    }

    private void Remember(ForegroundInfo info)
    {
        lock (_gate)
        {
            _last = info;
        }
    }

    private static ForegroundInfo? Describe(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !NativeMethods.IsWindow(hwnd) || !NativeMethods.IsWindowVisible(hwnd))
        {
            return null;
        }

        var root = NativeMethods.GetAncestor(hwnd, NativeMethods.GA_ROOT);
        if (root != IntPtr.Zero)
        {
            hwnd = root;
        }

        NativeMethods.GetWindowThreadProcessId(hwnd, out var processId);
        if (processId == 0 || processId == Environment.ProcessId)
        {
            return null;
        }

        var className = new StringBuilder(256);
        NativeMethods.GetClassNameW(hwnd, className, className.Capacity);
        if (ShellClasses.Contains(className.ToString()))
        {
            return null;
        }

        try
        {
            using var process = Process.GetProcessById((int)processId);
            var processName = ProcessCatalog.Normalize(process.ProcessName);
            return processName.Length == 0 ? null : new ForegroundInfo(hwnd, (int)processId, processName);
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException)
        {
            return null;
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (_hook != IntPtr.Zero)
        {
            NativeMethods.UnhookWinEvent(_hook);
        }
    }
}
