using System.IO;
using System.Windows;
using CvMaster.Interop;

namespace CvMaster.Services;

// 由托盘窗口所属的 UI 线程独占。切换主题/状态以及 Explorer 重建时复用原有句柄。
internal sealed class TrayIconImages : IDisposable
{
    private readonly Dictionary<string, byte[]> _resources = new();
    private readonly Dictionary<(string ResourcePath, int Size), IntPtr> _icons = new();
    private readonly Lazy<(IntPtr Handle, bool Owned)> _fallback = new(LoadFallback);

    public IntPtr Get(string resourcePath, int size)
    {
        var key = (resourcePath, size);
        if (!_icons.TryGetValue(key, out var icon))
        {
            icon = LoadIcon(resourcePath, size);
            _icons.Add(key, icon);
        }

        return icon != IntPtr.Zero ? icon : _fallback.Value.Handle;
    }

    private IntPtr LoadIcon(string resourcePath, int size)
    {
        if (!_resources.TryGetValue(resourcePath, out var bytes))
        {
            try
            {
                var uri = new Uri($"pack://application:,,,/cvMaster;component/{resourcePath}");
                using var resource = Application.GetResourceStream(uri)?.Stream
                    ?? throw new IOException("Missing tray icon resource.");
                using var buffer = new MemoryStream();
                resource.CopyTo(buffer);
                bytes = buffer.ToArray();
            }
            catch (Exception exception)
            {
                AppLog.Error("tray-icon-resource", exception);
                bytes = [];
            }

            // 也缓存读取失败，避免每次通知都尝试重新打开资源。
            _resources.Add(resourcePath, bytes);
        }

        if (bytes.Length == 0)
        {
            return IntPtr.Zero;
        }

        try
        {
            var frame = TrayIconFrames.Select(bytes, size);
            if (!frame.IsEmpty)
            {
                // 不用 LR_SHARED：每个返回的 HICON 由此缓存持有并释放。
                var icon = NativeMethods.CreateIconFromResourceEx(frame.ToArray(), (uint)frame.Length, true,
                    0x00030000, size, size, 0);
                if (icon != IntPtr.Zero)
                {
                    return icon;
                }
            }

            AppLog.Error("tray-icon-create");
        }
        catch (Exception exception)
        {
            AppLog.Error("tray-icon-create", exception);
        }

        return IntPtr.Zero;
    }

    private static (IntPtr Handle, bool Owned) LoadFallback()
    {
        if (Environment.ProcessPath is { Length: > 0 } executable)
        {
            try
            {
                NativeMethods.ExtractIconExW(executable, 0, out var large, out var small, 1);
                if (small != IntPtr.Zero)
                {
                    if (large != IntPtr.Zero && large != small)
                    {
                        NativeMethods.DestroyIcon(large);
                    }

                    return (small, true);
                }

                if (large != IntPtr.Zero)
                {
                    return (large, true);
                }
            }
            catch (Exception exception)
            {
                AppLog.Error("tray-icon-extract", exception);
            }
        }

        // LoadIconW 返回的内置图标是共享句柄，不应销毁。
        return (NativeMethods.LoadIconW(IntPtr.Zero, NativeMethods.IDI_APPLICATION), false);
    }

    public void Dispose()
    {
        foreach (var icon in _icons.Values)
        {
            if (icon != IntPtr.Zero)
            {
                NativeMethods.DestroyIcon(icon);
            }
        }

        _icons.Clear();
        _resources.Clear();
        if (_fallback.IsValueCreated && _fallback.Value.Owned)
        {
            NativeMethods.DestroyIcon(_fallback.Value.Handle);
        }
    }
}
