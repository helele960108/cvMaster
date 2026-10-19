/**
 * 定向粘贴：只向打开浮层前保存的外部窗口发送标准 Ctrl+V。
 * 目标已关闭、前台切换失败或权限更高时拒绝发送，避免把内容送错窗口。
 * @author helele
 * @since 2026-10-19
 */
using System.Runtime.InteropServices;
using CvMaster.Interop;

namespace CvMaster.Services;

public static class TargetPaster
{
    private const int MediumIntegrity = 0x2000;

    public static async Task<bool> TryPasteAsync(PasteTarget target, CancellationToken cancellationToken)
    {
        if (target.Handle == IntPtr.Zero ||
            !NativeMethods.IsWindow(target.Handle) ||
            NativeMethods.GetWindowThreadProcessId(target.Handle, out var processId) == 0 ||
            processId != (uint)target.ProcessId ||
            target.ProcessId == Environment.ProcessId)
        {
            AppLog.Error("paste-target-invalid");
            return false;
        }

        var currentLevel = GetIntegrityLevel(Environment.ProcessId) ?? MediumIntegrity;
        var targetLevel = GetIntegrityLevel(target.ProcessId);
        if (targetLevel is null || targetLevel > currentLevel)
        {
            // 更高完整性级别或无法核验的目标可能静默丢弃 SendInput。
            AppLog.Error("paste-target-integrity");
            return false;
        }

        if (NativeMethods.IsIconic(target.Handle))
        {
            NativeMethods.ShowWindowAsync(target.Handle, NativeMethods.SW_RESTORE);
        }

        NativeMethods.SetForegroundWindow(target.Handle);
        var foreground = false;
        for (var attempt = 0; attempt < 40; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (NativeMethods.GetForegroundWindow() == target.Handle)
            {
                foreground = true;
                break;
            }

            await Task.Delay(20, cancellationToken).ConfigureAwait(false);
        }

        if (!foreground)
        {
            AppLog.Error("paste-foreground");
            return false;
        }

        for (var attempt = 0; attempt < 40; attempt++)
        {
            if (!AnyModifierDown())
            {
                break;
            }

            if (attempt == 39)
            {
                AppLog.Error("paste-modifiers");
                return false;
            }

            await Task.Delay(20, cancellationToken).ConfigureAwait(false);
        }

        if (!NativeMethods.IsWindow(target.Handle) ||
            NativeMethods.GetForegroundWindow() != target.Handle)
        {
            AppLog.Error("paste-target-lost");
            return false;
        }

        var inputs = new[]
        {
            KeyInput(NativeMethods.VK_CONTROL, keyUp: false),
            KeyInput(NativeMethods.VK_V, keyUp: false),
            KeyInput(NativeMethods.VK_V, keyUp: true),
            KeyInput(NativeMethods.VK_CONTROL, keyUp: true)
        };
        var sent = NativeMethods.SendInput(
            (uint)inputs.Length,
            inputs,
            Marshal.SizeOf<NativeMethods.INPUT>());
        if (sent != (uint)inputs.Length)
        {
            AppLog.Error("paste-send");
            return false;
        }

        AppLog.Info("paste-sent");
        return true;
    }

    private static NativeMethods.INPUT KeyInput(int virtualKey, bool keyUp) => new()
    {
        type = NativeMethods.INPUT_KEYBOARD,
        U = new NativeMethods.InputUnion
        {
            ki = new NativeMethods.KEYBDINPUT
            {
                wVk = (ushort)virtualKey,
                wScan = 0,
                dwFlags = keyUp ? NativeMethods.KEYEVENTF_KEYUP : 0,
                time = 0,
                dwExtraInfo = IntPtr.Zero
            }
        }
    };

    private static bool AnyModifierDown() =>
        IsDown(NativeMethods.VK_MENU) ||
        IsDown(NativeMethods.VK_CONTROL) ||
        IsDown(NativeMethods.VK_SHIFT) ||
        IsDown(NativeMethods.VK_LWIN) ||
        IsDown(NativeMethods.VK_RWIN);

    private static bool IsDown(int virtualKey) =>
        (NativeMethods.GetAsyncKeyState(virtualKey) & 0x8000) != 0;

    /// <summary>读取进程完整性级别 RID；无法读取时返回 null。</summary>
    private static int? GetIntegrityLevel(int processId)
    {
        var process = NativeMethods.OpenProcess(
            NativeMethods.PROCESS_QUERY_LIMITED_INFORMATION,
            false,
            (uint)processId);
        if (process == IntPtr.Zero)
        {
            return null;
        }

        IntPtr token = IntPtr.Zero;
        try
        {
            if (!NativeMethods.OpenProcessToken(process, NativeMethods.TOKEN_QUERY, out token))
            {
                return null;
            }

            NativeMethods.GetTokenInformation(token, NativeMethods.TokenIntegrityLevel, IntPtr.Zero, 0, out var length);
            if (length <= 0)
            {
                return null;
            }

            var buffer = Marshal.AllocHGlobal(length);
            try
            {
                if (!NativeMethods.GetTokenInformation(token, NativeMethods.TokenIntegrityLevel, buffer, length, out _))
                {
                    return null;
                }

                var label = Marshal.PtrToStructure<NativeMethods.TOKEN_MANDATORY_LABEL>(buffer);
                var countPointer = NativeMethods.GetSidSubAuthorityCount(label.Label.Sid);
                var count = Marshal.ReadByte(countPointer);
                if (count == 0)
                {
                    return null;
                }

                var ridPointer = NativeMethods.GetSidSubAuthority(label.Label.Sid, (uint)(count - 1));
                return Marshal.ReadInt32(ridPointer);
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
        finally
        {
            if (token != IntPtr.Zero)
            {
                NativeMethods.CloseHandle(token);
            }

            NativeMethods.CloseHandle(process);
        }
    }
}
