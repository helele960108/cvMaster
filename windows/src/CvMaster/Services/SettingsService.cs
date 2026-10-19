/**
 * 明确类型的本地设置：注册表 HKCU 下的标量字段，不把业务对象序列化为 JSON。
 * 剪贴板内容不进入设置；排除列表仅保存进程名。
 * @author helele
 * @since 2026-10-19
 */
using System.IO;
using Microsoft.Win32;

namespace CvMaster.Services;

public sealed class SettingsService
{
    private const string SettingsKey = @"Software\cvMaster";
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValue = "cvMaster";
    private const string DefaultExclusions = "1Password.exe\nBitwarden.exe\nKeePass.exe\nKeePassXC.exe";

    private bool _recordingEnabled;
    private bool _autoPaste = true;
    private bool _skipSensitive = true;
    private bool _runAtStartup;
    private bool _onboardingShown;
    private string _appearance = "system";
    private string _hotKey = "Alt+Space";
    private int _retentionDays = 30;
    private int _panelHeight = 600;
    private string _excludedProcesses = DefaultExclusions;

    public SettingsService()
    {
        Load();
    }

    public bool RecordingEnabled
    {
        get => _recordingEnabled;
        set
        {
            if (_recordingEnabled == value)
            {
                return;
            }

            _recordingEnabled = value;
            WriteDword("RecordingEnabled", value ? 1 : 0);
        }
    }

    public bool AutoPaste
    {
        get => _autoPaste;
        set
        {
            if (_autoPaste == value)
            {
                return;
            }

            _autoPaste = value;
            WriteDword("AutoPaste", value ? 1 : 0);
        }
    }

    public bool SkipSensitive
    {
        get => _skipSensitive;
        set
        {
            if (_skipSensitive == value)
            {
                return;
            }

            _skipSensitive = value;
            WriteDword("SkipSensitive", value ? 1 : 0);
        }
    }

    public bool RunAtStartup
    {
        get => _runAtStartup;
        set
        {
            if (_runAtStartup == value)
            {
                return;
            }

            _runAtStartup = value;
            WriteDword("RunAtStartup", value ? 1 : 0);
            UpdateStartupRegistration(value);
        }
    }

    public bool OnboardingShown
    {
        get => _onboardingShown;
        set
        {
            if (_onboardingShown == value)
            {
                return;
            }

            _onboardingShown = value;
            WriteDword("OnboardingShown", value ? 1 : 0);
        }
    }

    /// <summary>system / light / dark；非法值回退 system。</summary>
    public string Appearance
    {
        get => _appearance;
        set
        {
            var normalized = value is "light" or "dark" or "system" ? value : "system";
            if (_appearance == normalized)
            {
                return;
            }

            _appearance = normalized;
            WriteString("Appearance", normalized);
        }
    }

    public string HotKey
    {
        get => _hotKey;
        set
        {
            if (_hotKey == value)
            {
                return;
            }

            _hotKey = value;
            WriteString("HotKey", value);
        }
    }

    public int RetentionDays
    {
        get => _retentionDays;
        set
        {
            var normalized = Math.Clamp(value, 0, 3650);
            if (_retentionDays == normalized)
            {
                return;
            }

            _retentionDays = normalized;
            WriteDword("RetentionDays", normalized);
        }
    }

    public int PanelHeight
    {
        get => _panelHeight;
        set
        {
            var normalized = Math.Clamp(value, 420, 1000);
            if (_panelHeight == normalized)
            {
                return;
            }

            _panelHeight = normalized;
            WriteDword("PanelHeight", normalized);
        }
    }

    public IReadOnlyList<string> ExcludedProcessList => ParseExcluded(_excludedProcesses);

    public string ExcludedProcesses
    {
        get => _excludedProcesses;
        set
        {
            var normalized = string.Join('\n', ParseExcluded(value));
            if (_excludedProcesses == normalized)
            {
                return;
            }

            _excludedProcesses = normalized;
            WriteString("ExcludedProcesses", normalized);
        }
    }

    /// <summary>添加排除进程；返回面向用户的错误，成功时只更新持久化配置。</summary>
    public string? AddExcludedProcess(string value)
    {
        var normalized = NormalizeProcessName(value);
        if (normalized.Length == 0)
        {
            return "请输入应用进程名，例如 1Password.exe";
        }

        if (normalized.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || Path.GetFileName(normalized) != normalized)
        {
            return "进程名不能包含路径或非法字符";
        }

        if (normalized.Equals(Path.GetFileName(Environment.ProcessPath) ?? "cvMaster.exe", StringComparison.OrdinalIgnoreCase))
        {
            return "不能排除 cvMaster 本身";
        }

        var items = ExcludedProcessList.ToList();
        if (items.Any(item => item.Equals(normalized, StringComparison.OrdinalIgnoreCase)))
        {
            return "该应用已在排除列表中";
        }

        if (items.Count >= 100)
        {
            return "排除列表最多 100 个应用";
        }

        items.Add(normalized);
        ExcludedProcesses = string.Join('\n', items);
        return null;
    }

    public void RemoveExcludedProcess(string processName)
    {
        var items = ExcludedProcessList
            .Where(item => !item.Equals(processName, StringComparison.OrdinalIgnoreCase))
            .ToList();
        ExcludedProcesses = string.Join('\n', items);
    }

    public static string NormalizeProcessName(string value)
    {
        var trimmed = value.Trim().Trim('"');
        if (trimmed.Length == 0)
        {
            return string.Empty;
        }

        if (trimmed.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) is false)
        {
            trimmed += ".exe";
        }

        return trimmed;
    }

    private static IReadOnlyList<string> ParseExcluded(string value)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<string>();
        foreach (var part in value.Split(['\r', '\n', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var normalized = NormalizeProcessName(part);
            if (normalized.Length > 0 && seen.Add(normalized))
            {
                result.Add(normalized);
            }
        }

        return result;
    }

    private void Load()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(SettingsKey, writable: false);
            if (key is not null)
            {
                _recordingEnabled = ReadDword(key, "RecordingEnabled") == 1;
                _autoPaste = ReadDword(key, "AutoPaste", 1) == 1;
                _skipSensitive = ReadDword(key, "SkipSensitive", 1) == 1;
                _runAtStartup = ReadDword(key, "RunAtStartup") == 1;
                _onboardingShown = ReadDword(key, "OnboardingShown") == 1;
                _appearance = ReadString(key, "Appearance", "system");
                _hotKey = ReadString(key, "HotKey", "Alt+Space");
                _retentionDays = (int)ReadDword(key, "RetentionDays", 30);
                _panelHeight = (int)ReadDword(key, "PanelHeight", 600);
                _excludedProcesses = ReadString(key, "ExcludedProcesses", DefaultExclusions);
            }
        }
        catch (Exception exception)
        {
            AppLog.Error("settings-load", exception);
        }

        _appearance = _appearance is "light" or "dark" or "system" ? _appearance : "system";
        _retentionDays = Math.Clamp(_retentionDays, 0, 3650);
        _panelHeight = Math.Clamp(_panelHeight, 420, 1000);
        _excludedProcesses = string.Join('\n', ParseExcluded(_excludedProcesses));
        _runAtStartup = IsStartupRegistered();
    }

    private static uint ReadDword(RegistryKey key, string name, uint fallback = 0) =>
        key.GetValue(name) is int value ? unchecked((uint)value) : fallback;

    private static string ReadString(RegistryKey key, string name, string fallback) =>
        key.GetValue(name) as string ?? fallback;

    private void WriteDword(string name, int value)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(SettingsKey, writable: true);
            key?.SetValue(name, value, RegistryValueKind.DWord);
        }
        catch (Exception exception)
        {
            AppLog.Error("settings-write", exception);
        }
    }

    private void WriteString(string name, string value)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(SettingsKey, writable: true);
            key?.SetValue(name, value, RegistryValueKind.String);
        }
        catch (Exception exception)
        {
            AppLog.Error("settings-write", exception);
        }
    }

    private static bool IsStartupRegistered()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: false);
            return key?.GetValue(RunValue) is string;
        }
        catch (Exception exception)
        {
            AppLog.Error("startup-read", exception);
            return false;
        }
    }

    private static void UpdateStartupRegistration(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (key is null)
            {
                return;
            }

            if (enabled && Environment.ProcessPath is { } executable)
            {
                key.SetValue(RunValue, $"\"{executable}\" --background", RegistryValueKind.String);
            }
            else
            {
                key.DeleteValue(RunValue, throwOnMissingValue: false);
            }
        }
        catch (Exception exception)
        {
            AppLog.Error("startup-write", exception);
        }
    }
}
