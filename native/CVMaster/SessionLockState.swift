/**
 * macOS 会话锁屏状态：会话字典为主、锁屏/解锁通知为低延迟补充。
 * CGSSessionScreenIsLocked 是未公开键；键缺失按未锁定，字典缺失或值异常由 monitor fail-closed。
 * @author helele
 * @since 2026-11-04
 */
import CoreGraphics
import Foundation
import OSLog

enum SessionLockResolution: Equatable {
    case locked
    case unlocked
    case unknown
}

/// 纯解析器，可由合成字典驱动，不访问系统状态。
struct SessionLockResolver {
    static let screenIsLockedKey = "CGSSessionScreenIsLocked"

    static func resolve(_ dictionary: [String: Any]?) -> SessionLockResolution {
        guard let dictionary else { return .unknown }
        guard let value = dictionary[screenIsLockedKey] else { return .unlocked }
        guard let number = value as? NSNumber else { return .unknown }
        return number.boolValue ? .locked : .unlocked
    }
}

/// 只负责维护锁屏状态；采集基线、取消在途任务由 ClipboardMonitor 处理。
@MainActor
final class SessionLockMonitor {
    private(set) var isLocked = false
    /// 最近一次观察到锁定 / 锁定通知的时间；字典恢复未锁定后短暂保持，覆盖通知先到、字典滞后的窗口。
    private let notificationGrace: Duration = .milliseconds(750)
    private var lockedObservedAt: ContinuousClock.Instant?
    private var observers: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: "local.helele.cvmaster", category: "session-lock")

    /// 状态真正变化时回调；同一状态重复通知不会触发。
    var onTransition: ((Bool) -> Void)?

    func start() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: .init("com.apple.screenIsLocked"),
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(true) }
        })
        observers.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(false) }
        })
        refresh()
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        lockedObservedAt = nil
    }

    /// 每轮采集前调用；通知可能丢失，会话字典是最终兜底。
    func refresh(now: ContinuousClock.Instant = .now) {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        switch SessionLockResolver.resolve(session) {
        case .locked:
            setLocked(true, now: now)
        case .unlocked:
            if let observedAt = lockedObservedAt, observedAt.duration(to: now) < notificationGrace {
                return
            }
            setLocked(false, now: now)
        case .unknown:
            // 会话字典缺失或值类型异常时 fail-closed；下一轮有效字典会恢复。
            setLocked(true, now: now)
        }
    }

    private func setLocked(_ locked: Bool, now: ContinuousClock.Instant = .now) {
        let changed = isLocked != locked
        isLocked = locked
        if locked {
            // 锁定通知与字典确认都会刷新保护窗口。
            lockedObservedAt = now
        } else {
            lockedObservedAt = nil
        }
        if changed {
            logger.notice("Session lock state changed: locked=\(locked, privacy: .public)")
            onTransition?(locked)
        }
    }
}
