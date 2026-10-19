/**
 * 列表 / 预览缩略图：按需解码、限制并发、LRU 缓存 24 张且总量不超过 2 MB。
 * 不把原图装入 UI，也不缓存引用文件的完整内容。
 * @author helele
 * @since 2026-10-19
 */
using System.IO;
using System.Windows.Media.Imaging;
using CvMaster.Core;

namespace CvMaster.Services;

public sealed class ThumbnailService : IDisposable
{
    private readonly HistoryStore _store;
    private readonly SemaphoreSlim _decodeGate = new(2, 2);
    private readonly object _gate = new();
    private readonly Dictionary<Guid, CacheEntry> _cache = new();
    private readonly LinkedList<Guid> _order = new();
    private long _cachedBytes;
    private bool _disposed;

    public ThumbnailService(HistoryStore store)
    {
        _store = store;
    }

    public async Task<BitmapSource?> GetListThumbnailAsync(Guid id, CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            if (_cache.TryGetValue(id, out var cached))
            {
                _order.Remove(id);
                _order.AddLast(id);
                return cached.Image;
            }
        }

        await _decodeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var path = await _store.GetThumbnailSourceAsync(id, cancellationToken).ConfigureAwait(false);
            if (string.IsNullOrEmpty(path))
            {
                return null;
            }

            var image = await Task.Run(
                () => Decode(path, StorageLimits.ListThumbnailPixels),
                cancellationToken).ConfigureAwait(false);
            if (image is null)
            {
                return null;
            }

            var cost = Math.Max(1, (long)image.PixelWidth * image.PixelHeight * 4);
            lock (_gate)
            {
                if (_cache.ContainsKey(id))
                {
                    return image;
                }

                while (_order.Count > 0 &&
                       (_order.Count >= StorageLimits.ThumbnailCacheEntries ||
                        _cachedBytes + cost > StorageLimits.ThumbnailCacheBytes))
                {
                    var oldest = _order.First!.Value;
                    _order.RemoveFirst();
                    if (_cache.Remove(oldest, out var removed))
                    {
                        _cachedBytes -= removed.Cost;
                    }
                }

                if (cost <= StorageLimits.ThumbnailCacheBytes)
                {
                    _cache[id] = new CacheEntry(image, cost);
                    _order.AddLast(id);
                    _cachedBytes += cost;
                }
            }

            return image;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (Exception exception)
        {
            AppLog.Error("thumbnail", exception);
            return null;
        }
        finally
        {
            _decodeGate.Release();
        }
    }

    public static Task<BitmapSource?> LoadPreviewAsync(string path, CancellationToken cancellationToken) =>
        Task.Run(() => Decode(path, StorageLimits.PreviewThumbnailPixels), cancellationToken);

    public void Clear()
    {
        lock (_gate)
        {
            _cache.Clear();
            _order.Clear();
            _cachedBytes = 0;
        }
    }

    private static BitmapSource? Decode(string path, int decodePixelWidth)
    {
        try
        {
            if (!File.Exists(path))
            {
                return null;
            }

            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
            image.DecodePixelWidth = decodePixelWidth;
            image.UriSource = new Uri(path, UriKind.Absolute);
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception exception) when (exception is IOException or NotSupportedException or UriFormatException or ArgumentException)
        {
            return null;
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Clear();
        _decodeGate.Dispose();
    }

    private sealed record CacheEntry(BitmapSource Image, long Cost);
}
