/**
 * 全局快捷键解析与注册：单一组合，不采集按键内容。
 * 默认 Alt+Space；冲突时保留托盘入口并允许在设置中修改。
 * @author helele
 * @since 2026-10-19
 */
using System.Windows.Input;
using System.Windows.Interop;
using CvMaster.Interop;

namespace CvMaster.Services;

public sealed record HotKeyGesture(ModifierKeys Modifiers, Key Key)
{
    public static HotKeyGesture Default { get; } = new(ModifierKeys.Alt, Key.Space);

    public uint NativeModifiers
    {
        get
        {
            var value = NativeMethods.MOD_NOREPEAT;
            if (Modifiers.HasFlag(ModifierKeys.Control))
            {
                value |= NativeMethods.MOD_CONTROL;
            }

            if (Modifiers.HasFlag(ModifierKeys.Alt))
            {
                value |= NativeMethods.MOD_ALT;
            }

            if (Modifiers.HasFlag(ModifierKeys.Shift))
            {
                value |= NativeMethods.MOD_SHIFT;
            }

            if (Modifiers.HasFlag(ModifierKeys.Windows))
            {
                value |= NativeMethods.MOD_WIN;
            }

            return value;
        }
    }

    /// <summary>
    /// 至少包含 Ctrl、Alt 或 Win；仅 Ctrl 会与复制、粘贴等菜单快捷键冲突。
    /// 与 macOS 端的快捷键校验规则保持一致。
    /// </summary>
    public string? ValidationMessage
    {
        get
        {
            if ((Modifiers & (ModifierKeys.Control | ModifierKeys.Alt | ModifierKeys.Windows)) == 0)
            {
                return "请至少包含 Ctrl、Alt 或 Win。";
            }

            if (Modifiers == ModifierKeys.Control)
            {
                return "仅使用 Ctrl 的组合会与复制、粘贴等快捷键冲突，请加入 Alt、Shift 或 Win。";
            }

            return null;
        }
    }

    public string Display
    {
        get
        {
            var parts = new List<string>(5);
            if (Modifiers.HasFlag(ModifierKeys.Control))
            {
                parts.Add("Ctrl");
            }

            if (Modifiers.HasFlag(ModifierKeys.Alt))
            {
                parts.Add("Alt");
            }

            if (Modifiers.HasFlag(ModifierKeys.Shift))
            {
                parts.Add("Shift");
            }

            if (Modifiers.HasFlag(ModifierKeys.Windows))
            {
                parts.Add("Win");
            }

            parts.Add(KeyDisplay(Key));
            return string.Join("+", parts);
        }
    }

    public static HotKeyGesture? FromKeyEvent(KeyEventArgs args)
    {
        var key = args.Key == Key.System ? args.SystemKey : args.Key;
        if (IsModifierKey(key) || key is Key.Escape or Key.Tab or Key.None)
        {
            return null;
        }

        var modifiers = Keyboard.Modifiers & (ModifierKeys.Control | ModifierKeys.Alt | ModifierKeys.Shift | ModifierKeys.Windows);
        // 组合是否合法由 ValidationMessage 判定，录制界面可以给出具体原因并继续等待。
        return new HotKeyGesture(modifiers, key);
    }

    public static HotKeyGesture? Parse(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var parts = value.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length < 2)
        {
            return null;
        }

        var modifiers = ModifierKeys.None;
        for (var index = 0; index < parts.Length - 1; index++)
        {
            switch (parts[index].ToLowerInvariant())
            {
                case "ctrl":
                case "control":
                    modifiers |= ModifierKeys.Control;
                    break;
                case "alt":
                    modifiers |= ModifierKeys.Alt;
                    break;
                case "shift":
                    modifiers |= ModifierKeys.Shift;
                    break;
                case "win":
                case "windows":
                    modifiers |= ModifierKeys.Windows;
                    break;
                default:
                    return null;
            }
        }

        if (modifiers == ModifierKeys.None || !TryParseKey(parts[^1], out var key))
        {
            return null;
        }

        var gesture = new HotKeyGesture(modifiers, key);
        return gesture.ValidationMessage is null ? gesture : null;
    }

    private static bool TryParseKey(string value, out Key key)
    {
        key = Key.None;
        var trimmed = value.Trim();
        if (trimmed.Length == 1)
        {
            var character = char.ToUpperInvariant(trimmed[0]);
            if (character is >= 'A' and <= 'Z')
            {
                key = (Key)Enum.Parse(typeof(Key), character.ToString());
                return true;
            }

            if (character is >= '0' and <= '9')
            {
                key = (Key)Enum.Parse(typeof(Key), "D" + character);
                return true;
            }

            key = character switch
            {
                '`' => Key.Oem3,
                '-' => Key.OemMinus,
                '=' => Key.OemPlus,
                ',' => Key.OemComma,
                '.' => Key.OemPeriod,
                '/' => Key.OemQuestion,
                ';' => Key.OemSemicolon,
                '\'' => Key.OemQuotes,
                '[' => Key.OemOpenBrackets,
                ']' => Key.OemCloseBrackets,
                '\\' => Key.OemPipe,
                _ => Key.None
            };
            return key != Key.None;
        }

        if (trimmed.Equals("Space", StringComparison.OrdinalIgnoreCase))
        {
            key = Key.Space;
            return true;
        }

        if (!Enum.TryParse<Key>(trimmed, ignoreCase: true, out key))
        {
            return false;
        }

        return !IsModifierKey(key) && key is not (Key.Escape or Key.Tab or Key.None);
    }

    public static string KeyDisplay(Key key) => key switch
    {
        Key.Space => "Space",
        Key.D0 => "0",
        Key.D1 => "1",
        Key.D2 => "2",
        Key.D3 => "3",
        Key.D4 => "4",
        Key.D5 => "5",
        Key.D6 => "6",
        Key.D7 => "7",
        Key.D8 => "8",
        Key.D9 => "9",
        Key.Oem3 => "`",
        Key.OemMinus => "-",
        Key.OemPlus => "=",
        Key.OemComma => ",",
        Key.OemPeriod => ".",
        Key.OemQuestion => "/",
        Key.OemSemicolon => ";",
        Key.OemQuotes => "'",
        Key.OemOpenBrackets => "[",
        Key.OemCloseBrackets => "]",
        Key.OemPipe => "\\",
        Key.Return => "Enter",
        _ => key.ToString()
    };

    private static bool IsModifierKey(Key key) => key is
        Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or
        Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin;
}

public sealed class HotKeyService : IDisposable
{
    private const int HotKeyId = 1;
    private readonly HwndSource _source;
    private HotKeyGesture? _current;
    private bool _suspended;
    private bool _disposed;

    public HotKeyService()
    {
        var parameters = new HwndSourceParameters("cvMaster.HotKey")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0,
            ParentWindow = NativeMethods.HWND_MESSAGE
        };
        _source = new HwndSource(parameters);
        _source.AddHook(WndProc);
    }

    public event EventHandler? Pressed;

    public HotKeyGesture? Current => _current;

    public bool IsRegistered { get; private set; }

    public bool TryRegister(HotKeyGesture gesture)
    {
        Unregister();
        var virtualKey = KeyInterop.VirtualKeyFromKey(gesture.Key);
        if (virtualKey == 0)
        {
            return false;
        }

        if (!NativeMethods.RegisterHotKey(_source.Handle, HotKeyId, gesture.NativeModifiers, (uint)virtualKey))
        {
            IsRegistered = false;
            return false;
        }

        _current = gesture;
        _suspended = false;
        IsRegistered = true;
        return true;
    }

    /// <summary>快捷键录制期间临时注销，避免按下旧组合时切换浮层。</summary>
    public void Suspend()
    {
        if (_current is null || _suspended)
        {
            return;
        }

        Unregister();
        _suspended = true;
    }

    public bool Resume()
    {
        if (_current is null || !_suspended)
        {
            return IsRegistered;
        }

        var gesture = _current;
        _suspended = false;
        return TryRegister(gesture);
    }

    private void Unregister()
    {
        if (IsRegistered)
        {
            NativeMethods.UnregisterHotKey(_source.Handle, HotKeyId);
            IsRegistered = false;
        }
    }

    private IntPtr WndProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == NativeMethods.WM_HOTKEY && wParam.ToInt32() == HotKeyId)
        {
            handled = true;
            Pressed?.Invoke(this, EventArgs.Empty);
        }

        return IntPtr.Zero;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Unregister();
        _source.RemoveHook(WndProc);
        _source.Dispose();
    }
}
