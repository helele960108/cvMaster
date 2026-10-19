/**
 * 再次复制用例：后台读取表示、UI 线程写入剪贴板、恢复原窗口并定向粘贴。
 * 写入失败保留原剪贴板；粘贴失败会明确反馈而不伪造成功。
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

            uint sequence;
            _monitor.BeginSelfWrite();
            try
            {
                var dispatcher = Application.Current.Dispatcher;
                sequence = await dispatcher.InvokeAsync(() =>
                {
                    hidePanel();
                    return ClipboardWriter.Write(representations);
                }).Task.ConfigureAwait(false);
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
            LibraryErrorCode? error = null;
            if (_settings.AutoPaste && target is not null)
            {
                try
                {
                    pasteSent = await TargetPaster.TryPasteAsync(target, cancellationToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch (Exception exception)
                {
                    AppLog.Error("paste-target", exception);
                    pasteSent = false;
                }

                if (!pasteSent)
                {
                    error = LibraryErrorCode.PasteTargetUnavailable;
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

            return new PasteResult(true, pasteSent, error);
        }
        finally
        {
            _gate.Release();
        }
    }
}
