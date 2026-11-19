namespace CvMaster.Services;

internal readonly record struct TrayPresentation(string ResourcePath, string Tooltip)
{
    public static TrayPresentation Create(bool lightTaskbar, bool recordingEnabled, bool paused, string shortcut)
    {
        // 仅反映用户可见的记录开关和暂停，不跟随瞬态的隐私拦截。
        var color = lightTaskbar ? "dark" : "light";
        var inactive = !recordingEnabled || paused ? "-paused" : string.Empty;
        var status = !recordingEnabled ? " · 未开启记录" : paused ? " · 已暂停记录" : string.Empty;
        return new TrayPresentation($"Assets/tray-{color}{inactive}.ico", $"cvMaster · {shortcut}{status}");
    }
}
