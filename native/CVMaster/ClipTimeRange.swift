/**
 * 时间筛选范围与相对时间标签；近 N 天按用户当前日历与时区计算。
 * @author helele
 * @since 2026-11-09
 */
import SwiftUI

/// 时间范围按用户当前日历和时区计算；近 N 天包含今天及此前 N−1 个自然日。
enum ClipTimeRange: String, CaseIterable, Identifiable, Sendable {
    case all = "全部时间"
    case today = "今天"
    case yesterday = "昨天"
    case last7Days = "近7天"
    case last30Days = "近30天"

    var id: String { rawValue }

    /// 查询开始时固定区间，闭开边界避免午夜重复；不按固定秒数推算自然日。
    func interval(at now: Date, calendar: Calendar = .current) -> DateInterval? {
        guard self != .all, let today = calendar.dateInterval(of: .day, for: now) else { return nil }
        let offset: Int
        switch self {
        case .all: return nil
        case .today: return today
        case .yesterday: offset = -1
        case .last7Days: offset = -6
        case .last30Days: offset = -29
        }
        guard let start = calendar.date(byAdding: .day, value: offset, to: today.start) else { return nil }
        return DateInterval(start: start, end: self == .yesterday ? today.start : today.end)
    }
}

/// 只刷新时间标签，不刷新卡片正文、缩略图或共享列表状态。
struct ClipRelativeTime: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(label(at: context.date)).help(date.formatted(date: .numeric, time: .standard))
        }
    }

    /// 分钟、小时按实际间隔，跨日使用日历天数；异常未来时间不显示负数。
    private func label(at now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60))分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600))小时前" }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date),
                                                   to: Calendar.current.startOfDay(for: now)).day ?? 0
        if days == 1 { return "昨天" }
        if days < 7 { return "\(max(1, days))天前" }
        return date.formatted(.dateTime.year().month().day())
    }
}
