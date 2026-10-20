/**
 * 再次复制用例：先确认目标可接收，再写剪贴板并定向派发粘贴。
 * 目标未准备好时保留原剪贴板；写入后发送失败只提示手动粘贴，不伪造成功。
 * @author helele
 * @since 2026-10-19
 */
using System.Windows;
using CvMaster.Core;

namespace CvMaster.Services;

public sealed record PasteResult(
    bool ClipboardWritten,
    bool PasteSent,
    LibraryErrorCode? Error)
{
    public static PasteResult Busy { get; } = new(false, false, null);
}

public sealed class PasteService
{
    private readonly HistoryStore _store;
    private readonly ClipboardMonitor _monitor;
    private readonly SettingsService _settings;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public PasteService(HistoryStore store, ClipboardMonitor monitor, SettingsService settings)
    {
        _store = store;
        _monitor = monitor;
        _settings = settings;
    }

    public async Task<PasteResult> PasteAsync(
        Clip clip,
        bool plainText,
        PasteTarget? target,
        Action hidePanel,
        CancellationToken cancellationToken)
    {
        if (!await _gate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        {
            return PasteResult.Busy;
        }

        try
        {
            if (_settings.AutoPaste)
            {
                // 粘贴请求必须在内容读取前绑定目标；第三方应用已在前台时不再抢焦点。
                if (target is null ||
                    !TargetPaster.IsTargetAlive(target) ||
                    !TargetPaster.IsOwnOrTargetForeground(target))
                {
                    return new PasteResult(false, false, LibraryErrorCode.PasteTargetNotReady);
                }
            }

            IReadOnlyList<ClipRepresentation> representations;
            try
            {
                representations = plainText
                    ? await _store.GetPlainTextAsync(clip.Id, clip.Kind, cancellationToken).ConfigureAwait(false)
                    : await _store.GetRepresentationsAsync(clip.Id, cancellationToken).ConfigureAwait(false);
            }
            catch (LibraryException exception)
            {
                return new PasteResult(false, false, exception.Code);
            }

            var dispatcher = Application.Current.Dispatcher;
            await dispatcher.InvokeAsync(hidePanel).Task.ConfigureAwait(false);

            if (_settings.AutoPaste)
            {
                if (!await TargetPaster.PrepareAsync(target!, cancellationToken).ConfigureAwait(false))
                {
                    // 剪贴板此时尚未改动，用户可以直接重试。
                    return new PasteResult(false, false, LibraryErrorCode.PasteTargetNotReady);
                }
            }

            uint sequence;
            _monitor.BeginSelfWrite();
            try
            {
                var (ready, writtenSequence) = await dispatcher.InvokeAsync(() =>
                {
                    // 在真正写入剪贴板的同一 UI 回调里复核，缩小第三方应用抢占前后的时间窗。
                    if (_settings.AutoPaste && !TargetPaster.IsReady(target!))
                    {
                        return (false, 0u);
                    }

                    return (true, ClipboardWriter.Write(representations));
                }).Task.ConfigureAwait(false);
                if (!ready)
                {
                    _monitor.EndSelfWrite(0);
                    return new PasteResult(false, false, LibraryErrorCode.PasteTargetNotReady);
                }

                sequence = writtenSequence;
            }
            catch (LibraryException exception)
            {
                _monitor.EndSelfWrite(0);
                return new PasteResult(false, false, exception.Code);
            }
            catch (Exception exception)
            {
                _monitor.EndSelfWrite(0);
                AppLog.Error("paste-write", exception);
                return new PasteResult(false, false, LibraryErrorCode.Storage);
            }

            _monitor.EndSelfWrite(sequence);

            var pasteSent = false;
            if (_settings.AutoPaste)
            {
                try
                {
                    pasteSent = TargetPaster.Send(target!);
                }
                catch (Exception exception)
                {
                    AppLog.Error("paste-target", exception);
                    pasteSent = false;
                }

                if (!pasteSent)
                {
                    return new PasteResult(true, false, LibraryErrorCode.PasteTargetUnavailable);
                }
            }

            try
            {
                await _store.MarkCopiedAsync(clip.Id, cancellationToken).ConfigureAwait(false);
            }
            catch (LibraryException exception)
            {
                AppLog.Error("paste-mark", exception);
            }

            return new PasteResult(true, pasteSent, null);
        }
        finally
        {
            _gate.Release();
        }
    }
}
