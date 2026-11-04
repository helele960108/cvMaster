/**
 * 历史记录、分组与内容表示的轻量模型。
 * 列表投影不持有原图、文件本体或完整正文。
 * @author helele
 * @since 2026-10-19
 */
using System.Globalization;

namespace CvMaster.Core;

/// <summary>用户可见的主展示类型；同一条记录仍可保留多种原始表示。</summary>
public enum ClipKind
{
    Text,
    Link,
    Image,
    File
}

public static class ClipKindExtensions
{
    /// <summary>数据库中持久化的稳定值，不随界面文案变化。</summary>
    public static string ToStorageValue(this ClipKind kind) => kind switch
    {
        ClipKind.Text => "文本",
        ClipKind.Link => "链接",
        ClipKind.Image => "图片",
        ClipKind.File => "文件",
        _ => "文本"
    };

    public static ClipKind FromStorageValue(string value) => value switch
    {
        "文本" => ClipKind.Text,
        "链接" => ClipKind.Link,
        "图片" => ClipKind.Image,
        "文件" => ClipKind.File,
        _ => throw new LibraryException(LibraryErrorCode.Storage)
    };

    public static string DisplayName(this ClipKind kind) => kind switch
    {
        ClipKind.Text => "文本",
        ClipKind.Link => "链接",
        ClipKind.Image => "图片",
        ClipKind.File => "文件",
        _ => "文本"
    };
}

/// <summary>分页列表中的轻量投影，不包含任何大体积内容。</summary>
public sealed class Clip
{
    public Clip(
        Guid id,
        ClipKind kind,
        string title,
        string source,
        string sourceProcess,
        DateTimeOffset copiedAt,
        long byteSize,
        bool pinned,
        IReadOnlySet<Guid> groups,
        int copies,
        string excerpt,
        bool hasFileReference)
    {
        Id = id;
        Kind = kind;
        Title = title;
        Source = source;
        SourceProcess = sourceProcess;
        CopiedAt = copiedAt;
        ByteSize = byteSize;
        Pinned = pinned;
        Groups = groups;
        Copies = copies;
        Excerpt = excerpt;
        HasFileReference = hasFileReference;
    }

    /// <summary>稳定 UUID；重复复制不会改变标识。</summary>
    public Guid Id { get; }

    public ClipKind Kind { get; }

    /// <summary>最多 120 字符的安全纯文本标题。</summary>
    public string Title { get; }

    /// <summary>尽力推断的来源应用显示名称，不作绝对准确性承诺。</summary>
    public string Source { get; }

    /// <summary>来源进程名，用于排除规则与应用图标；旧记录可能为空。</summary>
    public string SourceProcess { get; }

    public DateTimeOffset CopiedAt { get; }

    /// <summary>已保存表示的总字节数，不代表引用文件本体大小。</summary>
    public long ByteSize { get; }

    public bool Pinned { get; }

    /// <summary>持久化的多对多分组关系。</summary>
    public IReadOnlySet<Guid> Groups { get; }

    /// <summary>首次采集及主动重复复制的累计次数。</summary>
    public int Copies { get; }

    /// <summary>详情的短摘要，不使用完整正文作为列表数据源。</summary>
    public string Excerpt { get; }

    /// <summary>原始表示包含文件引用；与用户可见类型独立。</summary>
    public bool HasFileReference { get; }

    public bool IsImageFile => Kind == ClipKind.Image && HasFileReference;

    public string SizeText => ByteSizeFormatter.Format(ByteSize);
}

/// <summary>单层持久化分组；颜色为可重建的语义标记。</summary>
public sealed record ClipGroup(Guid Id, string Name, int ColorIndex);

/// <summary>单个剪贴板 item 的一种受支持表示。</summary>
public sealed record ClipRepresentation(int Item, string Type, byte[] Data);

/// <summary>从剪贴板读取后提交后台存储的有界快照。</summary>
public sealed class ClipCapture
{
    public required ClipKind Kind { get; init; }
    public required string Title { get; init; }
    public required string Excerpt { get; init; }

    /// <summary>有限的可搜索纯文本；文件记录仅保存文件名。</summary>
    public required string SearchText { get; init; }

    public required string Source { get; init; }
    public required string SourceProcess { get; init; }
    public required IReadOnlyList<ClipRepresentation> Representations { get; init; }

    /// <summary>采集开始时的隐私状态代数；保存前与当前代数不一致则丢弃。</summary>
    public long PrivacyEpoch { get; set; }
}

/// <summary>全库容量统计，不受搜索或筛选影响。</summary>
public sealed record StorageStats(int Entries, long Bytes);

/// <summary>一次后台分页查询结果。</summary>
public sealed record HistoryPage(
    IReadOnlyList<Clip> Clips,
    int Total,
    int StoredEntries,
    long StoredBytes);

/// <summary>按需加载的详情；图片仅返回可解码的本地路径。</summary>
public sealed record ClipPreviewData(
    string Text,
    string? ImagePath,
    IReadOnlyList<string> FilePaths,
    bool Truncated,
    bool HasFileReference);

/// <summary>查询条件在进入存储层前固定，避免 UI 状态变化影响后台结果。</summary>
public sealed record ClipSearchQuery(
    string Query,
    string Scope,
    ClipKind? Kind,
    ClipTimeRange TimeRange,
    int Limit);

public static class ByteSizeFormatter
{
    /// <summary>容量展示统一使用 1024 进制；0 字节显示为 0 KB。</summary>
    public static string Format(long bytes)
    {
        if (bytes <= 0)
        {
            return "0 KB";
        }

        string[] units = ["B", "KB", "MB", "GB", "TB"];
        double value = bytes;
        var unit = 0;
        while (value >= 1024 && unit < units.Length - 1)
        {
            value /= 1024;
            unit++;
        }

        return unit == 0
            ? string.Create(CultureInfo.InvariantCulture, $"{bytes} B")
            : string.Create(CultureInfo.InvariantCulture, $"{value:0.#} {units[unit]}");
    }
}
