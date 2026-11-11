/**
 * 本地偏好键与浮层尺寸常量；偏好只存明确类型的字段，不把业务对象序列化为 JSON。
 * @author helele
 * @since 2026-11-09
 */
import Foundation
import CoreGraphics

/// UserDefaults 键集中声明，避免多处字符串拼写不一致。
enum PreferenceKey {
    static let panelHeight = "panelHeight"
    static let appearance = "appearance"
    static let recordingEnabled = "recordingEnabled"
    static let recordingPaused = "recordingPaused"
    static let retentionDays = "retentionDays"
    static let excludedApplications = "excludedApplications"
}

/// 默认值与边界；保留天数 0 表示不按时间清理，容量上限始终生效。
enum PreferenceDefault {
    static let retentionDays = 30
    /// 内置排除的常见密码管理器 Bundle ID；设置页仅用它标记“默认”，不阻止用户移除或重新添加。
    static let excludedApplicationIDs = ["com.agilebits.onepassword7", "com.1password.1password", "com.apple.Passwords"]
    /// 持久化为换行分隔的 Bundle ID，不把结构化对象序列化为 JSON。
    static let excludedApplications = excludedApplicationIDs.joined(separator: "\n")
}

/// 浮层固定宽度与可调高度范围；实际高度另受当前屏幕可用空间限制。
enum PanelMetrics {
    static let width: CGFloat = 350
    static let defaultHeight: CGFloat = 600
    static let minimumHeight: CGFloat = 420
    static let maximumHeight: CGFloat = 1000

    /// 非有限值或低于下限的已保存高度回退到默认值，过大值收敛到上限。
    static func restoredHeight(_ saved: Double) -> CGFloat {
        guard saved.isFinite, saved >= minimumHeight else { return defaultHeight }
        return min(CGFloat(saved), maximumHeight)
    }

    static func clamped(_ requested: CGFloat) -> CGFloat {
        min(max(requested, minimumHeight), maximumHeight)
    }
}
