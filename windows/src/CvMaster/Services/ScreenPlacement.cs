/**
 * 多显示器定位：使用托盘图标的物理像素矩形与目标显示器 DPI，换算为 WPF DIP。
 * @author helele
 * @since 2026-10-19
 */
using System.Windows;
using CvMaster.Interop;

namespace CvMaster.Services;

/// <summary>物理像素矩形；由托盘图标等 Win32 接口提供。</summary>
public readonly record struct PixelRect(int Left, int Top, int Right, int Bottom);

/// <summary>浮层相对托盘图标的位置；用于把缩放手柄放到远离图标的一侧。</summary>
public enum PanelPlacement
{
    Floating,
    AboveIcon,
    BelowIcon
}

public static class ScreenPlacement
{
    /// <summary>将浮层放在托盘图标上方；空间不足时放在下方，并返回实际相对位置。</summary>
    public static PanelPlacement PlacePanel(Window window, double width, double height, PixelRect? trayRect)
    {
        var anchor = trayRect ?? DefaultTrayAnchor();
        var centerX = (anchor.Left + anchor.Right) / 2.0;
        var centerY = (anchor.Top + anchor.Bottom) / 2.0;
        var (scaleX, scaleY) = GetScale(centerX, centerY);
        var work = GetWorkAreaDip(centerX, centerY, scaleX, scaleY);

        double left;
        double top;
        if (trayRect is { } rect)
        {
            left = (rect.Left + rect.Right) / 2.0 / scaleX - width / 2.0;
            top = rect.Top / scaleY - height - 8.0;
            if (top < work.Top + 8.0)
            {
                top = rect.Bottom / scaleY + 8.0;
            }
        }
        else
        {
            left = work.Right - width - 12.0;
            top = work.Bottom - height - 12.0;
        }

        left = Math.Clamp(left, work.Left + 8.0, Math.Max(work.Left + 8.0, work.Right - width - 8.0));
        top = Math.Clamp(top, work.Top + 8.0, Math.Max(work.Top + 8.0, work.Bottom - height - 8.0));
        window.Left = Math.Round(left);
        window.Top = Math.Round(top);

        if (trayRect is not { } icon)
        {
            return PanelPlacement.Floating;
        }

        var iconCenterY = (icon.Top + icon.Bottom) / 2.0 / scaleY;
        var panelCenterY = top + height / 2.0;
        return panelCenterY <= iconCenterY ? PanelPlacement.AboveIcon : PanelPlacement.BelowIcon;
    }

    /// <summary>当前显示器工作区（DIP），用于约束拖动后的窗口尺寸。</summary>
    public static Rect GetWorkArea(Window window) => GetWindowWorkAreaDip(window);

    /// <summary>将侧边预览放在浮层右侧，空间不足时翻到左侧。</summary>
    public static void PlaceBesidePanel(Window panel, Window preview, double width, double height, double anchorTop)
    {
        var work = GetWindowWorkAreaDip(panel);
        var right = panel.Left + panel.Width + 8.0;
        var left = panel.Left - width - 8.0;
        var targetLeft = right + width <= work.Right - 8.0 ? right : left;
        var targetTop = Math.Clamp(anchorTop, work.Top + 8.0, Math.Max(work.Top + 8.0, work.Bottom - height - 8.0));
        preview.Left = Math.Round(targetLeft);
        preview.Top = Math.Round(targetTop);
    }

    public static void CenterOnCursorScreen(Window window, double width, double height)
    {
        NativeMethods.GetCursorPos(out var cursor);
        var (scaleX, scaleY) = GetScale(cursor.X, cursor.Y);
        var work = GetWorkAreaDip(cursor.X, cursor.Y, scaleX, scaleY);
        window.Left = Math.Round(work.Left + (work.Width - width) / 2.0);
        window.Top = Math.Round(work.Top + (work.Height - height) / 2.0);
    }

    private static PixelRect DefaultTrayAnchor()
    {
        NativeMethods.GetCursorPos(out var cursor);
        return new PixelRect(cursor.X, cursor.Y, cursor.X, cursor.Y);
    }

    private static (double ScaleX, double ScaleY) GetScale(double physicalX, double physicalY)
    {
        var point = new NativeMethods.POINT((int)physicalX, (int)physicalY);
        var monitor = NativeMethods.MonitorFromPoint(point, NativeMethods.MONITOR_DEFAULTTONEAREST);
        if (monitor != IntPtr.Zero &&
            NativeMethods.GetDpiForMonitor(monitor, NativeMethods.MDT_EFFECTIVE_DPI, out var dpiX, out var dpiY) == 0 &&
            dpiX > 0 && dpiY > 0)
        {
            return (dpiX / 96.0, dpiY / 96.0);
        }

        return (1.0, 1.0);
    }

    private static Rect GetWorkAreaDip(double physicalX, double physicalY, double scaleX, double scaleY)
    {
        var point = new NativeMethods.POINT((int)physicalX, (int)physicalY);
        var monitor = NativeMethods.MonitorFromPoint(point, NativeMethods.MONITOR_DEFAULTTONEAREST);
        var info = new NativeMethods.MONITORINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.MONITORINFO>() };
        if (monitor != IntPtr.Zero && NativeMethods.GetMonitorInfoW(monitor, ref info))
        {
            return new Rect(
                info.rcWork.Left / scaleX,
                info.rcWork.Top / scaleY,
                (info.rcWork.Right - info.rcWork.Left) / scaleX,
                (info.rcWork.Bottom - info.rcWork.Top) / scaleY);
        }

        var work = SystemParameters.WorkArea;
        return work;
    }

    private static Rect GetWindowWorkAreaDip(Window window)
    {
        var handle = new System.Windows.Interop.WindowInteropHelper(window).Handle;
        if (handle != IntPtr.Zero && NativeMethods.GetWindowRect(handle, out var rect))
        {
            var (scaleX, scaleY) = GetScale(
                rect.Left + (rect.Right - rect.Left) / 2.0,
                rect.Top + (rect.Bottom - rect.Top) / 2.0);
            return GetWorkAreaDip(
                rect.Left + (rect.Right - rect.Left) / 2.0,
                rect.Top + (rect.Bottom - rect.Top) / 2.0,
                scaleX,
                scaleY);
        }

        return SystemParameters.WorkArea;
    }
}
