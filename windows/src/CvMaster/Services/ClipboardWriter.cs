/**
 * 将已保存的原始表示写回系统剪贴板。
 * 只在准备成功后清空剪贴板；写入的复杂格式不执行、不联网。
 * @author helele
 * @since 2026-10-19
 */
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Media.Imaging;
using CvMaster.Core;
using CvMaster.Interop;

namespace CvMaster.Services;

public static class ClipboardWriter
{
    /// <summary>必须在 STA UI 线程调用；返回写入后的剪贴板序列号。</summary>
    public static uint Write(IReadOnlyList<ClipRepresentation> representations)
    {
        if (!Application.Current.Dispatcher.CheckAccess())
        {
            throw new InvalidOperationException("Clipboard writes must run on the UI thread.");
        }

        var data = new DataObject();
        var text = JoinText(representations, "text/plain") ?? JoinText(representations, "text/url");
        var html = representations.FirstOrDefault(item => item.Type == "text/html");
        var rtf = representations.FirstOrDefault(item => item.Type == "text/rtf");
        var png = representations.FirstOrDefault(item => item.Type == "image/png");
        var htmlText = html is null ? null : DecodeUtf8(html.Data);
        var rtfText = rtf is null ? null : DecodeUtf8(rtf.Data);
        var files = representations
            .Where(item => item.Type == "windows/file-list")
            .SelectMany(item => HistoryStore.DecodeFileList(item.Data))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (files.Length > 0)
        {
            data.SetData(DataFormats.FileDrop, files);
        }

        if (png is not null)
        {
            data.SetData("PNG", new MemoryStream(png.Data, writable: false));
            if (TryDecodeBitmap(png.Data) is { } bitmap)
            {
                data.SetData(DataFormats.Bitmap, bitmap);
            }
        }

        if (!string.IsNullOrEmpty(htmlText))
        {
            data.SetData(DataFormats.Html, EnsureHtmlPayload(htmlText));
        }

        if (!string.IsNullOrEmpty(rtfText))
        {
            data.SetData(DataFormats.Rtf, rtfText);
        }

        if (!string.IsNullOrEmpty(text))
        {
            data.SetData(DataFormats.UnicodeText, text);
        }

        if (files.Length == 0 &&
            png is null &&
            string.IsNullOrEmpty(htmlText) &&
            string.IsNullOrEmpty(rtfText) &&
            string.IsNullOrEmpty(text))
        {
            throw new LibraryException(LibraryErrorCode.MissingContent);
        }

        Exception? lastError = null;
        for (var attempt = 0; attempt < 10; attempt++)
        {
            try
            {
                Clipboard.SetDataObject(data, copy: true);
                return NativeMethods.GetClipboardSequenceNumber();
            }
            catch (Exception exception) when (exception is COMException or ExternalException)
            {
                lastError = exception;
                Thread.Sleep(40);
            }
        }

        AppLog.Error("clipboard-write", lastError);
        throw new LibraryException(LibraryErrorCode.Storage, lastError);
    }

    private static string? JoinText(IReadOnlyList<ClipRepresentation> representations, string type)
    {
        var parts = representations
            .Where(item => item.Type == type)
            .OrderBy(item => item.Item)
            .Select(item => DecodeUtf8(item.Data))
            .Where(value => !string.IsNullOrEmpty(value))
            .ToArray();
        return parts.Length == 0 ? null : string.Join("\n", parts);
    }

    private static string DecodeUtf8(byte[] data) =>
        Encoding.UTF8.GetString(data).TrimEnd('\0');

    private static BitmapSource? TryDecodeBitmap(byte[] png)
    {
        try
        {
            using var stream = new MemoryStream(png, writable: false);
            var frame = BitmapFrame.Create(
                stream,
                BitmapCreateOptions.IgnoreColorProfile,
                BitmapCacheOption.OnLoad);
            if ((long)frame.PixelWidth * frame.PixelHeight > StorageLimits.MaximumImagePixels)
            {
                return null;
            }

            frame.Freeze();
            return frame;
        }
        catch (Exception exception) when (exception is IOException or NotSupportedException or ArgumentException)
        {
            return null;
        }
    }

    /// <summary>WPF 的 HTML 剪贴板格式要求 CF_HTML 头部；没有时补齐固定宽度偏移。</summary>
    private static string EnsureHtmlPayload(string html)
    {
        if (html.Contains("StartHTML:", StringComparison.Ordinal))
        {
            return html;
        }

        const string prefix = "<html><body><!--StartFragment-->";
        const string suffix = "<!--EndFragment--></body></html>";
        var body = prefix + html + suffix;
        string Header(int start, int end, int fragmentStart, int fragmentEnd) =>
            $"Version:0.9\r\nStartHTML:{start:D10}\r\nEndHTML:{end:D10}\r\nStartFragment:{fragmentStart:D10}\r\nEndFragment:{fragmentEnd:D10}\r\n";
        var placeholder = Header(0, 0, 0, 0);
        var startOffset = Encoding.UTF8.GetByteCount(placeholder);
        var endOffset = startOffset + Encoding.UTF8.GetByteCount(body);
        var fragmentStart = startOffset + Encoding.UTF8.GetByteCount(prefix);
        var fragmentEnd = fragmentStart + Encoding.UTF8.GetByteCount(html);
        return Header(startOffset, endOffset, fragmentStart, fragmentEnd) + body;
    }
}
