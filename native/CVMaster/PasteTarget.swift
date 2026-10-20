/**
 * 原粘贴位置的辅助功能快照与串行校验；不读取文本、选区内容或剪贴板。
 * @author helele
 * @since 2026-10-20
 */
import ApplicationServices
import Foundation
import OSLog

/// 跨执行器只传递不可变标识；AX 引用永远留在 PasteTargetWorker 的串行队列内。
struct PasteTargetSnapshot: Sendable {
    let id: UUID
    let processIdentifier: pid_t
    let hasInputNode: Bool
}

/// unchecked 仅用于队列封闭的所有权：savedTarget 及其中全部 AX 引用只能在 queue 上访问；
/// occupied 另由 submissionLock 保护。超时只解除调用方等待，不释放尚在 AX IPC 中的工作名额。
final class PasteTargetWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.helele.cvmaster.paste-target", qos: .userInitiated)
    private let timerQueue = DispatchQueue(label: "local.helele.cvmaster.paste-target-deadline", qos: .userInitiated)
    private let logger = Logger(subsystem: "local.helele.cvmaster", category: "paste-target")
    private let submissionLock = NSLock()
    private var occupied = false
    private var savedTarget: SavedTarget?

    /// 工作完成与计时器竞争的 continuation 只在锁内取出一次；不持有或访问任何 AX 引用。
    private final class PendingResult<Result: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result, Never>?
        private var timer: DispatchSourceTimer?

        init(_ continuation: CheckedContinuation<Result, Never>, timer: DispatchSourceTimer) {
            self.continuation = continuation
            self.timer = timer
        }

        func finish(_ result: Result) {
            let completion = lock.withLock { () -> (CheckedContinuation<Result, Never>, DispatchSourceTimer?)? in
                guard let continuation else { return nil }
                self.continuation = nil
                let timer = self.timer
                self.timer = nil
                return (continuation, timer)
            }
            guard let (continuation, timer) = completion else { return }
            timer?.cancel()
            continuation.resume(returning: result)
        }
    }

    private struct Focus {
        let window: AXUIElement
        let input: AXUIElement?
    }

    private struct SavedTarget {
        let snapshot: PasteTargetSnapshot
        let application: AXUIElement
        let focus: Focus
    }

    private enum Failure: Error {
        case unavailable
        case deadline
        case accessibility(Int32)
    }

    /// deadline 覆盖排队和调用方等待；过期只返回 nil，绝不启动替代 AX 工作。
    func capture(processIdentifier: pid_t, deadline: ContinuousClock.Instant) async -> PasteTargetSnapshot? {
        await submit(fallback: nil, deadline: deadline) { worker in
            worker.captureSynchronously(processIdentifier: processIdentifier, deadline: deadline)
        }
    }

    /// 只校验同一份原始引用，永远不以新窗口或新输入节点替换快照。
    func validate(_ snapshot: PasteTargetSnapshot, deadline: ContinuousClock.Instant) async -> Bool {
        await submit(fallback: false, deadline: deadline) { worker in
            worker.validateSynchronously(snapshot, deadline: deadline)
        }
    }

    /// 仅一个实际 AX 工作可占用队列；调用方超时后仍保留名额，直到阻塞调用真正返回。
    /// 计时器是独立队列上的 continuation 竞争，不等待 AX 消息，也不尝试跨线程释放 AX 引用。
    private func submit<Result: Sendable>(fallback: Result, deadline: ContinuousClock.Instant,
                                         _ operation: @escaping @Sendable (PasteTargetWorker) -> Result) async -> Result {
        guard !Task.isCancelled, ContinuousClock.now < deadline else { return fallback }
        let admitted = submissionLock.withLock {
            guard !occupied else { return false }
            occupied = true
            return true
        }
        guard admitted else { return fallback }
        return await withCheckedContinuation { continuation in
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            let pending = PendingResult(continuation, timer: timer)
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let seconds = max(0, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
            timer.schedule(deadline: .now() + seconds, leeway: .milliseconds(1))
            timer.setEventHandler { [weak pending] in pending?.finish(fallback) }
            timer.resume()
            queue.async {
                let result = autoreleasepool {
                    ContinuousClock.now < deadline ? operation(self) : fallback
                }
                // 不在计时器路径释放名额；AX 不返回时后续请求立即失败，UI 仍可浏览历史。
                self.submissionLock.withLock { self.occupied = false }
                pending.finish(ContinuousClock.now < deadline ? result : fallback)
            }
        }
    }

    private func captureSynchronously(processIdentifier: pid_t, deadline: ContinuousClock.Instant) -> PasteTargetSnapshot? {
        dispatchPrecondition(condition: .onQueue(queue))
        savedTarget = nil
        do {
            try checkDeadline(deadline)
            guard processIdentifier > 0, processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                throw Failure.unavailable
            }
            let application = AXUIElementCreateApplication(processIdentifier)
            try requirePID(application, equals: processIdentifier, deadline: deadline)
            try requireFrontmost(processIdentifier, deadline: deadline)
            let focus = try readFocus(application, processIdentifier: processIdentifier, deadline: deadline)
            if let input = focus.input { try requireEditable(input, deadline: deadline) }
            // 两次读取必须相同，防止捕获过程中同一进程内切换窗口 / 输入框。
            let repeated = try readFocus(application, processIdentifier: processIdentifier, deadline: deadline)
            try requireSameFocus(repeated, as: focus)
            try requireFrontmost(processIdentifier, deadline: deadline)
            try checkDeadline(deadline)
            let snapshot = PasteTargetSnapshot(id: UUID(), processIdentifier: processIdentifier, hasInputNode: focus.input != nil)
            savedTarget = SavedTarget(snapshot: snapshot, application: application, focus: focus)
            return snapshot
        } catch {
            logger.debug("AX capture rejected: original focus could not be verified")
            return nil
        }
    }

    private func validateSynchronously(_ snapshot: PasteTargetSnapshot, deadline: ContinuousClock.Instant) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        do {
            try checkDeadline(deadline)
            guard let savedTarget, savedTarget.snapshot.id == snapshot.id,
                  savedTarget.snapshot.processIdentifier == snapshot.processIdentifier else {
                throw Failure.unavailable
            }
            let pid = snapshot.processIdentifier
            try requirePID(savedTarget.application, equals: pid, deadline: deadline)
            try requireFrontmost(pid, deadline: deadline)
            let focus = try readFocus(savedTarget.application, processIdentifier: pid, deadline: deadline)
            try requireSameFocus(focus, as: savedTarget.focus)
            if let input = savedTarget.focus.input { try requireEditable(input, deadline: deadline) }
            let repeated = try readFocus(savedTarget.application, processIdentifier: pid, deadline: deadline)
            try requireSameFocus(repeated, as: savedTarget.focus)
            try requireFrontmost(pid, deadline: deadline)
            try checkDeadline(deadline)
            return true
        } catch {
            logger.debug("AX validation rejected: saved target changed, unavailable or over deadline")
            return false
        }
    }

    /// 原窗口始终必需；有输入节点时还必须能证明节点属于该 PID 和该窗口。
    private func readFocus(_ application: AXUIElement, processIdentifier: pid_t, deadline: ContinuousClock.Instant) throws -> Focus {
        guard let window = try element(application, attribute: kAXFocusedWindowAttribute, deadline: deadline) else {
            throw Failure.unavailable
        }
        try requirePID(window, equals: processIdentifier, deadline: deadline)
        var input = try element(application, attribute: kAXFocusedUIElementAttribute, deadline: deadline)
        if input == nil {
            // 部分应用只通过系统焦点暴露节点；同样检查 PID，绝不接受本应用搜索框。
            input = try element(AXUIElementCreateSystemWide(), attribute: kAXFocusedUIElementAttribute, deadline: deadline)
        }
        if let input {
            try requirePID(input, equals: processIdentifier, deadline: deadline)
            guard let inputWindow = try element(input, attribute: kAXWindowAttribute, deadline: deadline) else {
                throw Failure.unavailable
            }
            try requirePID(inputWindow, equals: processIdentifier, deadline: deadline)
            guard CFEqual(inputWindow, window) else { throw Failure.unavailable }
        }
        return Focus(window: window, input: input)
    }

    private func requireSameFocus(_ current: Focus, as original: Focus) throws {
        guard CFEqual(current.window, original.window) else { throw Failure.unavailable }
        switch (original.input, current.input) {
        case let (.some(original), .some(current)):
            guard CFEqual(original, current) else { throw Failure.unavailable }
        case (.none, .none):
            // 仅持续未暴露节点时允许原窗口 responder 回退，不收养后来出现的新节点。
            break
        default:
            throw Failure.unavailable
        }
    }

    private func requireFrontmost(_ processIdentifier: pid_t, deadline: ContinuousClock.Instant) throws {
        guard let application = try element(AXUIElementCreateSystemWide(), attribute: kAXFocusedApplicationAttribute, deadline: deadline) else {
            throw Failure.unavailable
        }
        try requirePID(application, equals: processIdentifier, deadline: deadline)
    }

    private func requirePID(_ element: AXUIElement, equals expected: pid_t, deadline: ContinuousClock.Instant) throws {
        try prepareMessaging(element, deadline: deadline)
        var pid: pid_t = 0
        let result = AXUIElementGetPid(element, &pid)
        try checkDeadline(deadline)
        guard result == .success, pid == expected else { throw Failure.unavailable }
    }

    /// 仅 .noValue / .attributeUnsupported 表示未暴露节点；超时、无效引用、错误类型均拒绝。
    private func element(_ owner: AXUIElement, attribute: String, deadline: ContinuousClock.Instant) throws -> AXUIElement? {
        guard let value = try attributeValue(owner, attribute: attribute, deadline: deadline) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw Failure.unavailable }
        return (value as! AXUIElement)
    }

    private func attributeValue(_ owner: AXUIElement, attribute: String, deadline: ContinuousClock.Instant) throws -> CFTypeRef? {
        try prepareMessaging(owner, deadline: deadline)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(owner, attribute as CFString, &value)
        try checkDeadline(deadline)
        switch result {
        case .success:
            guard let value else { throw Failure.unavailable }
            return value
        case .noValue, .attributeUnsupported:
            return nil
        default:
            throw Failure.accessibility(result.rawValue)
        }
    }

    /// 不读取 AXValue / AXSelectedText / AXSelectedTextRange 的内容，仅询问可写性及角色元数据。
    private func requireEditable(_ element: AXUIElement, deadline: ContinuousClock.Instant) throws {
        guard let enabled = try attributeValue(element, attribute: kAXEnabledAttribute, deadline: deadline),
              CFGetTypeID(enabled) == CFBooleanGetTypeID(), (enabled as? Bool) == true else {
            throw Failure.unavailable
        }
        for attribute in [kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute] {
            try prepareMessaging(element, deadline: deadline)
            var settable = DarwinBoolean(false)
            let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
            try checkDeadline(deadline)
            if result == .success, settable.boolValue { return }
            guard result == .success || result == .attributeUnsupported || result == .noValue else {
                throw Failure.accessibility(result.rawValue)
            }
        }
        guard let value = try attributeValue(element, attribute: kAXRoleAttribute, deadline: deadline),
              let role = value as? String else { throw Failure.unavailable }
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else {
            // 第三方可返回任意角色字符串；截断且私有记录，不将其视作公开系统常量。
            let safeRole = String(role.prefix(64))
            logger.debug("AX focus is not editable: role=\(safeRole, privacy: .private)")
            throw Failure.unavailable
        }
    }

    /// public messaging timeout 是每次消息的请求限制，不是可强制取消 AX IPC 的硬时限。
    /// 调用前后检查连续时钟；独立计时器解除调用方等待，但不响应的 IPC 仍独占此串行工作名额。
    private func prepareMessaging(_ element: AXUIElement, deadline: ContinuousClock.Instant) throws {
        try checkDeadline(deadline)
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard seconds > 0 else { throw Failure.deadline }
        let result = AXUIElementSetMessagingTimeout(element, Float(min(0.15, seconds)))
        try checkDeadline(deadline)
        guard result == .success else { throw Failure.accessibility(result.rawValue) }
    }

    private func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
        guard ContinuousClock.now < deadline else { throw Failure.deadline }
        guard AXIsProcessTrusted() else { throw Failure.unavailable }
    }
}
