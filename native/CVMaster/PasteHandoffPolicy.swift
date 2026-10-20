/**
 * 粘贴请求的纯状态交接策略；不调用 AppKit、AX、剪贴板或计时器。
 * @author helele
 * @since 2026-10-20
 */
import Foundation

/// 由 MainActor 同步投递原始激活 / 关闭事件；请求一旦失效，切回原应用也不能恢复。
struct PasteHandoffPolicy {
    private enum Phase {
        case loading
        case restoring(acknowledgedGeneration: UInt64?)
        case prepared(generation: UInt64)
    }

    private struct Request {
        let targetID: UUID
        let processIdentifier: Int32
        let panelGeneration: UInt64
        // 保存用户发起请求时的三种代数，不以后来看到的 PID 重新建立请求。
        let initialFocusGeneration: UInt64
        let initialDismissalGeneration: UInt64
        var acceptedFocusGeneration: UInt64
        var acceptedDismissalGeneration: UInt64
        var phase: Phase = .loading
        var intentionalClosePending = false
        var closeAcknowledged = false
    }

    private let ownProcessIdentifier: Int32
    private var lastActivatedProcessIdentifier: Int32?
    private(set) var focusGeneration: UInt64 = 0
    private(set) var dismissalGeneration: UInt64 = 0
    private(set) var panelGeneration: UInt64 = 0
    private(set) var mayPresentFailure = false
    private var panelTargetID: UUID?
    private var panelProcessIdentifier: Int32?
    private var panelVisible = false
    private var panelValid = false
    private var expectedOwnActivation = false
    private var request: Request?

    init(ownProcessIdentifier: Int32, initiallyActiveProcessIdentifier: Int32?) {
        self.ownProcessIdentifier = ownProcessIdentifier
        lastActivatedProcessIdentifier = initiallyActiveProcessIdentifier
    }

    /// 展示调用前登记本应用可能产生的一次激活事件，不能把它误当成用户切换应用。
    mutating func panelWillOpen(targetID: UUID?, processIdentifier: Int32?, frontmostProcessIdentifier: Int32?) {
        panelGeneration &+= 1
        panelTargetID = targetID
        panelProcessIdentifier = processIdentifier
        panelVisible = true
        panelValid = true
        expectedOwnActivation = frontmostProcessIdentifier != ownProcessIdentifier
        request = nil
        mayPresentFailure = false
    }

    /// 直接消费通知里的 PID，不以稍后读取的 frontmostApplication 替换事件身份。
    mutating func applicationActivated(_ processIdentifier: Int32?) {
        focusGeneration &+= 1
        lastActivatedProcessIdentifier = processIdentifier
        if expectedOwnActivation, processIdentifier == ownProcessIdentifier {
            // 仅等待中的本应用浮层激活可被承认，恢复已完成后不能再接受本应用抢焦点。
            switch request?.phase {
            case .none, .loading, .restoring(acknowledgedGeneration: nil):
                expectedOwnActivation = false
                request?.acceptedFocusGeneration = focusGeneration
                return
            default:
                break
            }
        }
        if var request, case .restoring(acknowledgedGeneration: nil) = request.phase,
           processIdentifier == request.processIdentifier {
            // 必须收到预期原进程的实际激活通知，不能因 PID 已变化就提前冻结代数。
            expectedOwnActivation = false
            request.acceptedFocusGeneration = focusGeneration
            request.phase = .restoring(acknowledgedGeneration: focusGeneration)
            self.request = request
            return
        }
        invalidate()
    }

    mutating func panelDidClose() {
        // 主动关闭的同步确认与 delegate 通知可先后抵达，只消费一次。
        guard panelVisible else { return }
        dismissalGeneration &+= 1
        panelVisible = false
        if var request, request.intentionalClosePending {
            request.intentionalClosePending = false
            request.closeAcknowledged = true
            request.acceptedDismissalGeneration = dismissalGeneration
            self.request = request
        } else {
            invalidate()
        }
    }

    /// 在最初的同步 validate 中固定请求；内容加载期间不允许用户激活 / 关闭后重新收养目标。
    mutating func beginRequest(targetID: UUID, processIdentifier: Int32,
                               frontmostProcessIdentifier: Int32?, panelIsShown: Bool) -> Bool {
        guard panelValid, panelVisible, panelIsShown, panelTargetID == targetID,
              panelProcessIdentifier == processIdentifier,
              frontmostProcessIdentifier == ownProcessIdentifier || frontmostProcessIdentifier == processIdentifier else {
            invalidate()
            return false
        }
        request = Request(targetID: targetID, processIdentifier: processIdentifier, panelGeneration: panelGeneration,
                          initialFocusGeneration: focusGeneration, initialDismissalGeneration: dismissalGeneration,
                          acceptedFocusGeneration: focusGeneration, acceptedDismissalGeneration: dismissalGeneration)
        mayPresentFailure = true
        return true
    }

    /// 必须先通过本检查，调用者才可关闭浮层、deactivate 或 activate 原进程。
    mutating func beginPreparation(targetID: UUID, frontmostProcessIdentifier: Int32?,
                                   ownApplicationIsActive: Bool, panelIsShown: Bool) -> Bool {
        guard var request, request.targetID == targetID, case .loading = request.phase,
              epochsMatch(request), panelValid, panelVisible, panelIsShown,
              frontmostProcessIdentifier == ownProcessIdentifier || frontmostProcessIdentifier == request.processIdentifier else {
            invalidate()
            return false
        }
        // 若浮层根本没有激活本应用，原进程已被先前通知/初始快照确认且持续在前台，不等不存在的新通知。
        // 一旦需要恢复，则只能由 applicationActivated 中的预期通知确认，不能轮询 PID 猜测完成。
        let alreadyActive = frontmostProcessIdentifier == request.processIdentifier && !ownApplicationIsActive
            && lastActivatedProcessIdentifier == request.processIdentifier
        request.phase = .restoring(acknowledgedGeneration: alreadyActive ? focusGeneration : nil)
        request.intentionalClosePending = true
        self.request = request
        if alreadyActive { expectedOwnActivation = false }
        return true
    }

    mutating func preparationIsValid(targetID: UUID, frontmostProcessIdentifier: Int32?) -> Bool {
        guard let request, request.targetID == targetID, case let .restoring(acknowledged) = request.phase,
              epochsMatch(request) else {
            invalidate()
            return false
        }
        if let acknowledged {
            guard acknowledged == focusGeneration, frontmostProcessIdentifier == request.processIdentifier else {
                invalidate()
                return false
            }
        } else if let frontmostProcessIdentifier,
                  frontmostProcessIdentifier != ownProcessIdentifier && frontmostProcessIdentifier != request.processIdentifier {
            invalidate()
            return false
        }
        return true
    }

    /// 当前激活应用模式：调用方已确认目标稳定激活且修饰键释放，不要求重复激活通知。
    /// 只承认既有请求、原进程及主动关闭；代数不符或第三方切换后绝不能重新收养请求。
    mutating func confirmActiveTarget(targetID: UUID, frontmostProcessIdentifier: Int32?,
                                      targetIsActive: Bool) -> Bool {
        guard var request, request.targetID == targetID, request.closeAcknowledged,
              epochsMatch(request), case .restoring = request.phase,
              targetIsActive, frontmostProcessIdentifier == request.processIdentifier else { return false }
        request.acceptedFocusGeneration = focusGeneration
        request.phase = .restoring(acknowledgedGeneration: focusGeneration)
        expectedOwnActivation = false
        self.request = request
        return true
    }

    func restorationAcknowledged(targetID: UUID) -> Bool {
        guard let request, request.targetID == targetID, request.closeAcknowledged, epochsMatch(request),
              case let .restoring(acknowledged) = request.phase, acknowledged == focusGeneration else { return false }
        return true
    }

    mutating func markPrepared(targetID: UUID) -> Bool {
        guard restorationAcknowledged(targetID: targetID) else { return false }
        request?.phase = .prepared(generation: focusGeneration)
        return true
    }

    func isPrepared(targetID: UUID, frontmostProcessIdentifier: Int32?) -> Bool {
        guard let request, request.targetID == targetID, request.closeAcknowledged, epochsMatch(request),
              case let .prepared(generation) = request.phase, generation == focusGeneration,
              frontmostProcessIdentifier == request.processIdentifier else { return false }
        return true
    }

    /// 操作结束时释放请求；保留失败是否可显示，供外层错误处理决定是否重新展示浮层。
    mutating func finishRequest() { request = nil }

    private func epochsMatch(_ request: Request) -> Bool {
        request.panelGeneration == panelGeneration && request.acceptedFocusGeneration == focusGeneration
            && request.acceptedDismissalGeneration == dismissalGeneration
    }

    private mutating func invalidate() {
        request = nil
        panelValid = false
        expectedOwnActivation = false
        mayPresentFailure = false
    }
}
