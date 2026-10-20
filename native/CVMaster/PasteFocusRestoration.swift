/**
 * 原输入焦点恢复的单次许可；不访问 AX、AppKit 或剪贴板。
 * @author helele
 * @since 2026-10-20
 */
import Foundation

/// missing / container 只表示原窗口内丢失输入焦点，不包含其他输入框或 AX 错误。
enum PasteFocusObservation: Sendable {
    case original
    case missingInput
    case originalInputContainer
    case differentInput
    case differentWindow
}

enum PasteFocusPreparationResult: Sendable {
    case ready
    case waiting
    case rejected
}

/// 主线程撤销后，后台即使稍后完成 AX 查询也不能再开始焦点写入；许可不会被重新启用。
/// 系统焦点检查与 AX 写入仍非原子操作，已发出的系统消息不能被硬取消。
final class PasteFocusRestorationRequest: @unchecked Sendable {
    enum Action: Equatable {
        case ready
        case restoreSavedInput
        case wait
        case reject
    }

    let targetID: UUID
    let deadline: ContinuousClock.Instant
    private let lock = NSLock()
    private let hasSavedInput: Bool
    private var cancelled = false
    private var restorationAttempted = false

    init(targetID: UUID, hasSavedInput: Bool, deadline: ContinuousClock.Instant) {
        self.targetID = targetID
        self.hasSavedInput = hasSavedInput
        self.deadline = deadline
    }

    func cancel() { lock.withLock { cancelled = true } }

    func isValid(now: ContinuousClock.Instant = .now) -> Bool {
        lock.withLock { !cancelled && now < deadline }
    }

    func action(for observation: PasteFocusObservation, targetID: UUID,
                now: ContinuousClock.Instant = .now) -> Action {
        lock.withLock {
            guard !cancelled, now < deadline, targetID == self.targetID else {
                cancelled = true
                return .reject
            }
            switch observation {
            case .original:
                return .ready
            case .missingInput, .originalInputContainer:
                guard hasSavedInput else { cancelled = true; return .reject }
                guard !restorationAttempted else { return .wait }
                restorationAttempted = true
                return .restoreSavedInput
            case .differentInput, .differentWindow:
                cancelled = true
                return .reject
            }
        }
    }
}
