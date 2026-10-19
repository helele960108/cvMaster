/**
 * 时间筛选按用户本地日历计算；边界为闭开区间，避免午夜重复。
 * @author helele
 * @since 2026-10-19
 */
namespace CvMaster.Core;

public enum ClipTimeRange
{
    All,
    Today,
    Yesterday,
    Last7Days,
    Last30Days
}

public static class ClipTimeRangeExtensions
{
    public static string DisplayName(this ClipTimeRange range) => range switch
    {
        ClipTimeRange.All => "全部时间",
        ClipTimeRange.Today => "今天",
        ClipTimeRange.Yesterday => "昨天",
        ClipTimeRange.Last7Days => "近7天",
        ClipTimeRange.Last30Days => "近30天",
        _ => "全部时间"
    };

    /// <summary>返回 Unix 毫秒的闭开边界；全部时间返回 null。</summary>
    public static (long StartMs, long EndMs)? GetBounds(this ClipTimeRange range, DateTimeOffset now)
    {
        if (range == ClipTimeRange.All)
        {
            return null;
        }

        var localNow = TimeZoneInfo.ConvertTime(now, TimeZoneInfo.Local);
        var today = localNow.Date;
        var start = StartOfLocalDay(today);
        var end = StartOfLocalDay(today.AddDays(1));
        switch (range)
        {
            case ClipTimeRange.Today:
                break;
            case ClipTimeRange.Yesterday:
                end = start;
                start = StartOfLocalDay(today.AddDays(-1));
                break;
            case ClipTimeRange.Last7Days:
                start = StartOfLocalDay(today.AddDays(-6));
                break;
            case ClipTimeRange.Last30Days:
                start = StartOfLocalDay(today.AddDays(-29));
                break;
        }

        return (start.ToUnixTimeMilliseconds(), end.ToUnixTimeMilliseconds());
    }

    private static DateTimeOffset StartOfLocalDay(DateTime localDate)
    {
        var unspecified = DateTime.SpecifyKind(localDate.Date, DateTimeKind.Unspecified);
        return new DateTimeOffset(unspecified, TimeZoneInfo.Local.GetUtcOffset(unspecified));
    }
}
