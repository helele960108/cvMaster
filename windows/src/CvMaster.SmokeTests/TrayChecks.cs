using System.Buffers.Binary;
using CvMaster.Services;

namespace CvMaster.SmokeTests;

internal static class TrayChecks
{
    public static void Run(Action<string, bool> check)
    {
        Console.WriteLine("Windows tray presentation checks");
        const string shortcut = "Ctrl+Shift+V";
        foreach (var (lightTaskbar, assetColor) in new[] { (true, "dark"), (false, "light") })
        {
            var active = TrayPresentation.Create(lightTaskbar, true, false, shortcut);
            var paused = TrayPresentation.Create(lightTaskbar, true, true, shortcut);
            var disabled = TrayPresentation.Create(lightTaskbar, false, false, shortcut);
            check($"{assetColor} 字标使用与任务栏相反的颜色",
                active.ResourcePath == $"Assets/tray-{assetColor}.ico");
            check($"{assetColor} 字标未开启和暂停使用同一资源",
                disabled.ResourcePath == $"Assets/tray-{assetColor}-paused.ico" && paused.ResourcePath == disabled.ResourcePath);
            check($"{assetColor} 字标在提示中保留快捷键并区分暂停 / 未开启",
                active.Tooltip == $"cvMaster · {shortcut}" && paused.Tooltip == $"cvMaster · {shortcut} · 已暂停记录" &&
                disabled.Tooltip == $"cvMaster · {shortcut} · 未开启记录" &&
                TrayPresentation.Create(lightTaskbar, false, true, shortcut) == disabled);
        }

        // 这里只测试 ICO 目录的尺寸选择与边界防护；帧内容由 Windows user32 解码。
        var ico = IconDirectory(16, 24, 32, 256);
        check("ICO 帧精确匹配 150% DPI", TrayIconFrames.Select(ico, 24).SequenceEqual(new byte[] { 24 }));
        check("缺少精确 ICO 尺寸时优先下采样", TrayIconFrames.Select(ico, 20).SequenceEqual(new byte[] { 24 }));
        check("ICO 目录的 0 尺寸代表 256 像素", TrayIconFrames.Select(ico, 256).SequenceEqual(new byte[] { 0 }));
        check("拒绝截断的 ICO 目录", TrayIconFrames.Select(ico.AsSpan(0, 16), 24).IsEmpty);
        BinaryPrimitives.WriteUInt32LittleEndian(ico.AsSpan(6 + 16 + 12), uint.MaxValue);
        check("跳过偏移越界的 ICO 帧", TrayIconFrames.Select(ico, 24).SequenceEqual(new byte[] { 32 }));
    }

    private static byte[] IconDirectory(params int[] sizes)
    {
        var directoryEnd = 6 + 16 * sizes.Length;
        var bytes = new byte[directoryEnd + sizes.Length];
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(2), 1);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(4), (ushort)sizes.Length);
        for (var i = 0; i < sizes.Length; i++)
        {
            var dimension = sizes[i] == 256 ? (byte)0 : (byte)sizes[i];
            var entry = bytes.AsSpan(6 + i * 16);
            entry[0] = dimension;
            entry[1] = dimension;
            BinaryPrimitives.WriteUInt32LittleEndian(entry[8..], 1);
            BinaryPrimitives.WriteUInt32LittleEndian(entry[12..], (uint)(directoryEnd + i));
            bytes[directoryEnd + i] = dimension;
        }

        return bytes;
    }
}
