/**
 * 列表 / 预览缩略图：按需解码、限制并发、LRU 缓存 24 张且总量不超过 2 MB。
 * 引用文件可能位于异常磁盘或断开卷，读取与解码限制 3 秒等待；
 * 超时只解除调用方等待，实际系统调用仍占用工作名额，避免不断派生阻塞线程。
 * @author helele
 * @since 2026-10-19
 */
using System.IO;
using System.Windows.Media.Imaging;
using CvMaster.Core;

namespace CvMaster.Services;

public sealed class ThumbnailService : IDisposable
{
    private static readonly TimeSpan DecodeTimeout = TimeSpan.FromSeconds(3);
    private readonly HistoryStore _store;
    private readonly SemaphoreSlim _decodeGate = new(2, 2);
    private readonly object _gate = new();
    private readonly Dictionary<Guid, CacheEntry> _cache = new();
    private readonly LinkedList<Guid> _order = new();
    /// <summary>本次运行中已超时的资产 / 引用路径；同一路径不再反复创建阻塞读取。</summary>
    private readonly HashSet<string> _timedOutSources = new(StringComparer.OrdinalIgnoreCase);
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

        string? path;
        try
        {
            path = await _store.GetThumbnailSourceAsync(id, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (Exception exception)
        {
            AppLog.Error("thumbnail-source", exception);
            return null;
        }

        if (string.IsNullOrEmpty(path))
        {
            return null;
        }

        var key = IsStoredAsset(path) ? id.ToString("N") : path;
        lock (_gate)
        {
            if (_timedOutSources.Contains(key))
            {
                return null;
            }
        }

        var image = await DecodeBoundedAsync(path, StorageLimits.ListThumbnailPixels, key, cancellationToken)
            .ConfigureAwait(false);
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

    /// <summary>侧边预览按需解码；与其他缩略图共享两个工作名额和超时规则。</summary>
    public Task<BitmapSource?> LoadPreviewAsync(string path, CancellationToken cancellationToken) =>
        DecodeBoundedAsync(path, StorageLimits.PreviewThumbnailPixels, path, cancellationToken);

    /// <summary>
    /// 超时只让调用方停止等待；未结束的任务继续持有工作名额，直到真实系统调用返回。
    /// 这样异常挂载点最多占满两个名额，而不会为每次列表刷新继续创建线程。
    /// </summary>
    private async Task<BitmapSource?> DecodeBoundedAsync(
        string path,
        int decodePixelWidth,
        string? timeoutKey,
        CancellationToken cancellationToken)
    {
        if (cancellationToken.IsCancellationRequested)
        {
            return null;
        }

        await _decodeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        Task<BitmapSource?> work;
        try
        {
            work = Task.Run(
                () =>
                {
                    try
                    {
                        return IsUsableSource(path) ? Decode(path, decodePixelWidth) : null;
                    }
                    catch (Exception)
                    {
                        // 单张缩略图失败不应影响列表或其他卡片。
                        return null;
                    }
                    finally
                    {
                        ReleaseGate();
                    }
                },
                CancellationToken.None);
        }
        catch
        {
            ReleaseGate();
            throw;
        }

        var timeout = Task.Delay(DecodeTimeout, cancellationToken);
        var completed = await Task.WhenAny(work, timeout).ConfigureAwait(false);
        if (completed != work)
        {
            if (!cancellationToken.IsCancellationRequested && timeoutKey is not null)
            {
                lock (_gate)
                {
                    if (_timedOutSources.Count < 256)
                    {
                        _timedOutSources.Add(timeoutKey);
                    }
                }
            }

            return null;
        }

        return await work.ConfigureAwait(false);
    }

    private bool IsStoredAsset(string path)
    {
        try
        {
            var root = Path.GetFullPath(_store.AssetsDirectory) + Path.DirectorySeparatorChar;
            var full = Path.GetFullPath(path);
            return full.StartsWith(root, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }

    /// <summary>
    /// 内置资产只要求普通文件；外部引用还要求本地固定卷、图片扩展名、
    /// 体积上限，且拒绝符号链接 / 离线占位文件。所有检查都在限时工作线程内执行。
    /// </summary>
    private bool IsUsableSource(string path)
    {
        try
        {
            var stored = IsStoredAsset(path);
            if (!stored)
            {
                // 先拒绝网络卷 / 非图片扩展名，避免为明显不可用的路径创建阻塞读取。
                if (!Path.IsPathFullyQualified(path) ||
                    path.StartsWith(@"\\", StringComparison.Ordinal) ||
                    !HistoryStore.IsImagePath(path))
                {
                    return false;
                }

                var root = Path.GetPathRoot(path);
                if (string.IsNullOrEmpty(root) ||
                    new DriveInfo(root).DriveType is not (DriveType.Fixed or DriveType.Ram))
                {
                    return false;
                }
            }

            var info = new FileInfo(path);
            if (!info.Exists || info.Length <= 0 ||
                info.Attributes.HasFlag(FileAttributes.ReparsePoint) ||
                info.Attributes.HasFlag(FileAttributes.Offline) ||
                info.Attributes.HasFlag(FileAttributes.Directory))
            {
                return false;
            }

            return stored || info.Length <= StorageLimits.MaximumReferencedImageBytes;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }

    private static BitmapSource? Decode(string path, int decodePixelWidth)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
            image.DecodePixelWidth = decodePixelWidth;
            image.StreamSource = stream;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception exception) when (exception is IOException or NotSupportedException or ArgumentException or FileFormatException)
        {
            return null;
        }
    }

    private void ReleaseGate()
    {
        try
        {
            _decodeGate.Release();
        }
        catch (ObjectDisposedException)
        {
            // 应用退出时尚未结束的系统调用可以安全地忽略许可释放。
        }
    }

    public void Clear()
    {
        lock (_gate)
        {
            _cache.Clear();
            _order.Clear();
            _cachedBytes = 0;
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
