/**
 * 进程身份与图标：按进程名缓存显示名和 16px 图标，不扫描无关目录。
 * @author helele
 * @since 2026-10-19
 */
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CvMaster.Interop;

namespace CvMaster.Services;

public static class ProcessCatalog
{
    private static readonly object Gate = new();
    private static readonly Dictionary<string, ProcessMeta> Cache = new(StringComparer.OrdinalIgnoreCase);

    private sealed record ProcessMeta(string DisplayName, ImageSource? Icon);

    public static string Normalize(string processName)
    {
        if (string.IsNullOrWhiteSpace(processName))
        {
            return string.Empty;
        }

        var trimmed = processName.Trim();
        return trimmed.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? trimmed : trimmed + ".exe";
    }

    public static string DisplayName(string processName)
    {
        var normalized = Normalize(processName);
        if (normalized.Length == 0)
        {
            return "未知应用";
        }

        lock (Gate)
        {
            if (Cache.TryGetValue(normalized, out var cached))
            {
                return cached.DisplayName;
            }
        }

        var meta = LoadMeta(normalized);
        lock (Gate)
        {
            if (Cache.Count >= 64)
            {
                Cache.Clear();
            }

            Cache[normalized] = meta;
        }

        return meta.DisplayName;
    }

    public static ImageSource? Icon(string processName)
    {
        var normalized = Normalize(processName);
        if (normalized.Length == 0)
        {
            return null;
        }

        lock (Gate)
        {
            if (Cache.TryGetValue(normalized, out var cached))
            {
                return cached.Icon;
            }
        }

        var meta = LoadMeta(normalized);
        lock (Gate)
        {
            if (Cache.Count >= 64)
            {
                Cache.Clear();
            }

            Cache[normalized] = meta;
        }

        return meta.Icon;
    }

    /// <summary>列出有可见窗口的运行中应用；已排除项和本应用不进入菜单。</summary>
    public static IReadOnlyList<RunningApplication> ListRunningApplications(IEnumerable<string> excluded)
    {
        var excludedSet = new HashSet<string>(
            excluded.Select(Normalize),
            StringComparer.OrdinalIgnoreCase);
        var self = Normalize(Path.GetFileName(Environment.ProcessPath) ?? "cvMaster.exe");
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<RunningApplication>();

        foreach (var process in Process.GetProcesses())
        {
            try
            {
                if (process.Id == Environment.ProcessId || process.MainWindowHandle == IntPtr.Zero)
                {
                    continue;
                }

                var processName = Normalize(process.ProcessName);
                if (processName.Length == 0 || processName.Equals(self, StringComparison.OrdinalIgnoreCase) ||
                    excludedSet.Contains(processName) || !seen.Add(processName))
                {
                    continue;
                }

                var meta = LoadMeta(processName, process);
                result.Add(new RunningApplication(processName, meta.DisplayName, meta.Icon));
            }
            catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception)
            {
                // 进程可能在枚举期间退出。
            }
            finally
            {
                process.Dispose();
            }
        }

        return result
            .OrderBy(item => item.DisplayName, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(item => item.ProcessName, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static ProcessMeta LoadMeta(string processName, Process? knownProcess = null)
    {
        Process? owned = null;
        try
        {
            var process = knownProcess;
            if (process is null)
            {
                var shortName = Path.GetFileNameWithoutExtension(processName);
                var candidates = Process.GetProcessesByName(shortName);
                if (candidates.Length == 0)
                {
                    return new ProcessMeta(
                        Path.GetFileNameWithoutExtension(processName),
                        null);
                }

                process = candidates[0];
                owned = process;
            }

            string? path = null;
            string? description = null;
            try
            {
                path = process.MainModule?.FileName;
                description = process.MainModule?.FileVersionInfo.FileDescription;
            }
            catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException)
            {
                // 32/64 位交叉或受保护进程可能无法读取模块信息。
            }

            var name = string.IsNullOrWhiteSpace(description)
                ? Path.GetFileNameWithoutExtension(processName)
                : description.Trim();
            var icon = path is null ? null : LoadFileIcon(path);
            return new ProcessMeta(name, icon);
        }
        catch (Exception exception)
        {
            AppLog.Error("process-meta", exception);
            return new ProcessMeta(Path.GetFileNameWithoutExtension(processName), null);
        }
        finally
        {
            owned?.Dispose();
        }
    }

    private static ImageSource? LoadFileIcon(string path)
    {
        var info = new NativeMethods.SHFILEINFO();
        var result = NativeMethods.SHGetFileInfoW(
            path,
            0,
            ref info,
            (uint)Marshal.SizeOf<NativeMethods.SHFILEINFO>(),
            NativeMethods.SHGFI_ICON | NativeMethods.SHGFI_SMALLICON);
        if (result == IntPtr.Zero || info.hIcon == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            var image = Imaging.CreateBitmapSourceFromHIcon(
                info.hIcon,
                Int32Rect.Empty,
                BitmapSizeOptions.FromEmptyOptions());
            image.Freeze();
            return image;
        }
        catch (Exception exception)
        {
            AppLog.Error("process-icon", exception);
            return null;
        }
        finally
        {
            NativeMethods.DestroyIcon(info.hIcon);
        }
    }
}

public sealed record RunningApplication(string ProcessName, string DisplayName, ImageSource? Icon);
