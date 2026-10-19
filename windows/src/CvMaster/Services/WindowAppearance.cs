/**
 * 无边框窗口的系统外观：圆角、深色标题栏与资源管理器主题。
 * @author helele
 * @since 2026-10-19
 */
using System.Windows;
using System.Windows.Interop;
using CvMaster.Interop;

namespace CvMaster.Services;

public static class WindowAppearance
{
    public static void Apply(Window window, bool dark)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero)
        {
            return;
        }

        var darkValue = dark ? 1 : 0;
        if (NativeMethods.DwmSetWindowAttribute(
                handle,
                NativeMethods.DWMWA_USE_IMMERSIVE_DARK_MODE,
                ref darkValue,
                sizeof(int)) != 0)
        {
            // Windows 10 1809–1909 使用属性 19；失败时保持系统默认标题栏。
            NativeMethods.DwmSetWindowAttribute(handle, 19, ref darkValue, sizeof(int));
        }

        var corner = NativeMethods.DWMWCP_ROUND;
        NativeMethods.DwmSetWindowAttribute(
            handle,
            NativeMethods.DWMWA_WINDOW_CORNER_PREFERENCE,
            ref corner,
            sizeof(int));

        try
        {
            NativeMethods.SetWindowTheme(handle, dark ? "DarkMode_Explorer" : "Explorer", null);
        }
        catch (Exception)
        {
            // 旧系统不提供 DarkMode_Explorer 时忽略。
        }
    }
}
