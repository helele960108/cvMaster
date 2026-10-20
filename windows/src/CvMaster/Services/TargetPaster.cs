/**
 * 定向粘贴：只向打开浮层前保存的外部窗口发送标准 Ctrl+V。
 * 目标已关闭、前台切换失败或权限更高时拒绝发送，避免把内容送错窗口。
 * @author helele
 * @since 2026-10-19
 */
using System.Diagnostics;
using System.Runtime.InteropServices;
using CvMaster.Interop;

namespace CvMaster.Services;

public static class TargetPaster
{
    private const int MediumIntegrity = 0x2000;
    private static readonly TimeSpan PreparationDeadline = TimeSpan.FromMilliseconds(2500);
    private static readonly TimeSpan StableDuration = TimeSpan.FromMilliseconds(100);

    /// <summary>目标窗口仍存在、PID 未变且进程未退出。</summary>
    public static bool IsTargetAlive(PasteTarget target)
    {
        if (!IsWindowForTarget(target))
        {
            return false;
        }

        try
        {
            using var process = Process.GetProcessById(target.ProcessId);
            return !process.HasExited;
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or NotSupportedException or System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    /// <summary>当前前台仍是目标窗口或本应用；第三方应用前台时不得抢焦点。</summary>
    public static bool IsOwnOrTargetForeground(PasteTarget target)
    {
        var foreground = NativeMethods.GetForegroundWindow();
        if (foreground == IntPtr.Zero)
        {
            return false;
        }

        if (foreground == target.Handle)
        {
            return true;
        }

        NativeMethods.GetWindowThreadProcessId(foreground, out var processId);
        return processId == (uint)Environment.ProcessId;
    }

    /// <summary>
    /// 剪贴板写入前确认目标可接收：恢复窗口、等待实际前台、修饰键释放，
    /// 并要求连续 100 ms 稳定。与 macOS 端的“当前激活应用”交接语义一致。
    /// </summary>
    public static async Task<bool> PrepareAsync(PasteTarget target, CancellationToken cancellationToken)
    {
        if (!IsWindowForTarget(target))
        {
            AppLog.Error("paste-target-invalid");
            return false;
        }

        if (!IsOwnOrTargetForeground(target))
        {
            AppLog.Error("paste-target-not-frontmost");
            return false;
        }

        if (!HasSufficientIntegrity(target))
        {
            AppLog.Error("paste-target-integrity");
            return false;
        }

        if (NativeMethods.IsIconic(target.Handle))
        {
            NativeMethods.ShowWindowAsync(target.Handle, NativeMethods.SW_RESTORE);
        }

        var deadline = Stopwatch.StartNew();
        var lastActivationRequest = TimeSpan.FromMilliseconds(-1000);
        TimeSpan? stableSince = null;

        while (deadline.Elapsed < PreparationDeadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var foreground = NativeMethods.GetForegroundWindow();
            var ready = IsWindowForTarget(target) &&
                        foreground == target.Handle &&
                        !AnyModifierDown();
            if (ready)
            {
                stableSince ??= deadline.Elapsed;
                if (deadline.Elapsed - stableSince.Value >= StableDuration)
                {
                    AppLog.Info("paste-target-ready");
                    return true;
                }
            }
            else
            {
                stableSince = null;
                if (foreground != target.Handle)
                {
                    // 第三方应用取得前台时立即撤销请求，不把焦点强行抢回原目标。
                    if (foreground != IntPtr.Zero)
                    {
                        NativeMethods.GetWindowThreadProcessId(foreground, out var foregroundProcess);
                        if (foregroundProcess != (uint)Environment.ProcessId &&
                            foregroundProcess != (uint)target.ProcessId)
                        {
                            AppLog.Error("paste-target-preempted");
                            return false;
                        }
                    }

                    if (deadline.Elapsed - lastActivationRequest >= TimeSpan.FromMilliseconds(250))
                    {
                        lastActivationRequest = deadline.Elapsed;
                        NativeMethods.SetForegroundWindow(target.Handle);
                    }
                }
            }

            await Task.Delay(20, cancellationToken).ConfigureAwait(false);
        }

        AppLog.Error("paste-preparation-deadline");
        return false;
    }

    /// <summary>写入剪贴板前的同步复核：目标仍是前台且没有修饰键按下。</summary>
    public static bool IsReady(PasteTarget target) =>
        IsWindowForTarget(target) &&
        NativeMethods.GetForegroundWindow() == target.Handle &&
        !AnyModifierDown();

    /// <summary>写入剪贴板后、派发按键前同步复核；检查与派发之间不再 await。</summary>
    public static bool Send(PasteTarget target)
    {
        if (!IsReady(target))
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

    private static bool IsWindowForTarget(PasteTarget target)
    {
        if (target.Handle == IntPtr.Zero ||
            !NativeMethods.IsWindow(target.Handle) ||
            NativeMethods.GetWindowThreadProcessId(target.Handle, out var processId) == 0 ||
            processId != (uint)target.ProcessId ||
            target.ProcessId == Environment.ProcessId)
        {
            return false;
        }

        return true;
    }

    /// <summary>目标完整性级别高于当前进程时拒绝发送，避免静默丢弃或跨权限边界。</summary>
    private static bool HasSufficientIntegrity(PasteTarget target)
    {
        var currentLevel = GetIntegrityLevel(Environment.ProcessId) ?? MediumIntegrity;
        var targetLevel = GetIntegrityLevel(target.ProcessId);
        return targetLevel is not null && targetLevel <= currentLevel;
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
