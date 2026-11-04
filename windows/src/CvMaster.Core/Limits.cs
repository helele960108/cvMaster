/**
 * 统一限额：避免常驻应用随着历史增长变成全量内存缓存。
 * @author helele
 * @since 2026-10-19
 */
namespace CvMaster.Core;

public static class StorageLimits
{
    /// <summary>首屏元数据条数。</summary>
    public const int PageSize = 60;

    /// <summary>当前最多加载的元数据；关闭浮层后缩回首屏。</summary>
    public const int MaximumLoaded = 300;

    public const int MaximumEntries = 10_000;
    public const long MaximumBytes = 1_000_000_000;
    public const int MaximumCaptureBytes = 16 * 1024 * 1024;
    public const int MaximumRepresentationBytes = 8 * 1024 * 1024;
    public const int MaximumRepresentations = 24;
    public const int SearchableCharacters = 32_768;
    public const int MaximumRichTextPreviewBytes = 256 * 1024;
    public const int MaximumPreviewTextBytes = 16_000;
    public const int MaximumTitleCharacters = 120;
    public const int MaximumExcerptCharacters = 240;
    public const int MaximumGroupNameCharacters = 20;
    public const int MaximumGroupNameBytes = 1024;
    public const int MaximumGroups = 100;
    public const int MaximumFileReferences = 100;

    /// <summary>图片解码前的像素上限，避免超大截图拖垮后台线程。</summary>
    public const long MaximumImagePixels = 24_000_000;

    /// <summary>引用图片文件用于缩略图时的体积上限。</summary>
    public const long MaximumReferencedImageBytes = 64 * 1024 * 1024;

    /// <summary>单张预览缩略图的最大边长（物理像素）。</summary>
    public const int PreviewThumbnailPixels = 420;

    /// <summary>列表缩略图的最大边长（物理像素）。</summary>
    public const int ListThumbnailPixels = 96;

    /// <summary>列表缩略图缓存条数与总字节上限。</summary>
    public const int ThumbnailCacheEntries = 24;
    public const long ThumbnailCacheBytes = 2 * 1024 * 1024;
}
