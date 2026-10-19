/**
 * 列表投影：只持有轻量元数据与派生的展示文案，不持有原图或完整正文。
 * @author helele
 * @since 2026-10-19
 */
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Media;
using CvMaster.Core;

namespace CvMaster.ViewModels;

public sealed class ClipRow : INotifyPropertyChanged
{
    private string _relativeTime;

    public ClipRow(Clip clip)
    {
        Clip = clip;
        _relativeTime = FormatRelativeTime(clip.CopiedAt);
        Section = clip.Pinned
            ? "置顶"
            : clip.CopiedAt.LocalDateTime.Date == DateTime.Today
                ? "今天"
                : clip.CopiedAt.LocalDateTime.Date == DateTime.Today.AddDays(-1)
                    ? "昨天"
                    : "更早";

        if (clip.Kind == ClipKind.Image)
        {
            PrimaryText = string.IsNullOrWhiteSpace(clip.Title) ? "图片" : clip.Title;
            SecondaryText = clip.HasFileReference ? $"图片文件 · {clip.SizeText}" : $"图片 · {clip.SizeText}";
        }
        else if (clip.Kind == ClipKind.File)
        {
            PrimaryText = clip.Title;
            SecondaryText = $"{FileCountText} · 文件引用 · {clip.SizeText}";
        }
        else
        {
            PrimaryText = string.IsNullOrWhiteSpace(clip.Excerpt) ? clip.Title : clip.Excerpt;
            SecondaryText = string.Empty;
        }

        KindIcon = Application.Current.TryFindResource(clip.Kind switch
        {
            ClipKind.Text => "Icon.Text",
            ClipKind.Link => "Icon.Link",
            ClipKind.Image => "Icon.Image",
            _ => "Icon.File"
        }) as Geometry;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public Clip Clip { get; }

    public string Section { get; }

    public string PrimaryText { get; }

    public string SecondaryText { get; }

    public bool HasSecondary => !string.IsNullOrEmpty(SecondaryText);

    public string RelativeTime
    {
        get => _relativeTime;
        private set
        {
            if (_relativeTime == value)
            {
                return;
            }

            _relativeTime = value;
            OnPropertyChanged();
        }
    }

    public bool IsImage => Clip.Kind == ClipKind.Image;
    public bool IsFile => Clip.Kind == ClipKind.File;
    public bool IsTextLike => Clip.Kind is ClipKind.Text or ClipKind.Link;
    public Geometry? KindIcon { get; }

    public void RefreshRelativeTime() => RelativeTime = FormatRelativeTime(Clip.CopiedAt);

    private string FileCountText
    {
        get
        {
            var count = Clip.Excerpt.Split('\n', StringSplitOptions.RemoveEmptyEntries).Length;
            if (count > 1)
            {
                return $"{count} 个文件";
            }

            return "1 个文件";
        }
    }

    private static string FormatRelativeTime(DateTimeOffset copiedAt)
    {
        var local = copiedAt.ToLocalTime();
        var now = DateTimeOffset.Now;
        var span = now - local;
        if (span < TimeSpan.Zero)
        {
            return "刚刚";
        }

        if (span < TimeSpan.FromMinutes(1))
        {
            return "刚刚";
        }

        if (span < TimeSpan.FromHours(1))
        {
            return $"{Math.Max(1, (int)span.TotalMinutes)}分钟前";
        }

        if (span < TimeSpan.FromHours(24))
        {
            return $"{Math.Max(1, (int)span.TotalHours)}小时前";
        }

        var days = (now.LocalDateTime.Date - local.LocalDateTime.Date).Days;
        return days switch
        {
            <= 1 => "昨天",
            < 7 => $"{days}天前",
            _ => local.ToString("yyyy/M/d")
        };
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
