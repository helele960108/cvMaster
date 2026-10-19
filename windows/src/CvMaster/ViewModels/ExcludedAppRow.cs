/**
 * 设置页排除项的一行；名称与图标按进程名缓存解析。
 * @author helele
 * @since 2026-10-19
 */
using System.Windows.Media;

namespace CvMaster.ViewModels;

public sealed record ExcludedAppRow(string ProcessName, string DisplayName, ImageSource? Icon);
