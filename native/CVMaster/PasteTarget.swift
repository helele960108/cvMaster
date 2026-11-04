/**
 * 原粘贴位置的辅助功能快照与串行校验；不读取文本、选区内容或剪贴板。
 * 当前生产粘贴路径使用“当前激活应用”语义，不引用本文件的 AX 捕获 / 焦点恢复实现；
 * 保留供未来恢复原输入节点时参考，修改前先阅读 docs/性能与实现约束.md。
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

    /// 提交已在同步调用内完成，等待句柄不负责调度 AX 工作。
    struct Capture: Sendable {
        fileprivate let pending: PendingResult<PasteTargetSnapshot?>

        func value() async -> PasteTargetSnapshot? { await pending.value() }
    }

    /// 工作可能早于等待者完成；结果及唯一等待者均受锁保护，不持有或访问任何 AX 引用。
    fileprivate final class PendingResult<Result: Sendable>: @unchecked Sendable {
        private enum State {
            case pending
            case finished(Result)
        }

        private let lock = NSLock()
        private var state: State = .pending
        private var continuation: CheckedContinuation<Result, Never>?
        private var timer: DispatchSourceTimer?

        init(timer: DispatchSourceTimer) { self.timer = timer }

        init(completed result: Result) { state = .finished(result) }

        func value() async -> Result {
            await withCheckedContinuation { continuation in
                let current = lock.withLock {
                    if case .pending = state {
                        precondition(self.continuation == nil)
                        self.continuation = continuation
                    }
                    return state
                }
                if case let .finished(result) = current { continuation.resume(returning: result) }
            }
        }

        func finish(_ result: Result, beforeResume: () -> Void = {}) {
            let completion = lock.withLock { () -> (CheckedContinuation<Result, Never>?, DispatchSourceTimer?)? in
                guard case .pending = state else { return nil }
                // 超时胜者必须先撤销写许可，再让已存在或稍后加入的等待者观察到结果。
                beforeResume()
                state = .finished(result)
                let continuation = self.continuation
                self.continuation = nil
                let timer = self.timer
                self.timer = nil
                return (continuation, timer)
            }
            guard let (continuation, timer) = completion else { return }
            timer?.cancel()
            continuation?.resume(returning: result)
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

        /// 仅输出固定失败分类及系统错误码，不包含 AX 节点、窗口标题或用户内容。
        var diagnosticCode: String {
            switch self {
            case .unavailable: return "unavailable"
            case .deadline: return "deadline"
            case let .accessibility(code): return "ax-error-\(code)"
            }
        }
    }

    /// 调用返回前固定截止时间并完成后台入队；不在主线程执行或等待 AX 消息。
    func beginCapture(processIdentifier: pid_t, deadline: ContinuousClock.Instant) -> Capture {
        Capture(pending: beginSubmit(fallback: nil, deadline: deadline) { worker in
            worker.captureSynchronously(processIdentifier: processIdentifier, deadline: deadline)
        })
    }

    /// 唯一允许恢复焦点的入口，只能用于剪贴板写入前；每个请求最多写一次原节点。
    func prepareFocus(_ snapshot: PasteTargetSnapshot, request: PasteFocusRestorationRequest) async -> PasteFocusPreparationResult {
        await withTaskCancellationHandler {
            await submit(fallback: .rejected, deadline: request.deadline, onTimeout: { request.cancel() }) { worker in
                worker.prepareFocusSynchronously(snapshot, request: request)
            }
        } onCancel: {
            request.cancel()
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
                                         onTimeout: @escaping @Sendable () -> Void = {},
                                         _ operation: @escaping @Sendable (PasteTargetWorker) -> Result) async -> Result {
        guard !Task.isCancelled else { return fallback }
        return await beginSubmit(fallback: fallback, deadline: deadline, onTimeout: onTimeout, operation).value()
    }

    private func beginSubmit<Result: Sendable>(fallback: Result, deadline: ContinuousClock.Instant,
                                              onTimeout: @escaping @Sendable () -> Void = {},
                                              _ operation: @escaping @Sendable (PasteTargetWorker) -> Result) -> PendingResult<Result> {
        guard ContinuousClock.now < deadline else { return PendingResult(completed: fallback) }
        let admitted = submissionLock.withLock {
            guard !occupied else { return false }
            occupied = true
            return true
        }
        guard admitted else {
            logger.error("AX operation rejected: worker still occupied")
            return PendingResult(completed: fallback)
        }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        let pending = PendingResult<Result>(timer: timer)
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let seconds = max(0, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
        timer.schedule(deadline: .now() + seconds, leeway: .milliseconds(1))
        let operationLogger = logger
        timer.setEventHandler { [weak pending] in
            pending?.finish(fallback, beforeResume: {
                operationLogger.error("AX operation timed out: caller deadline reached")
                onTimeout()
            })
        }
        timer.resume()
        queue.async {
            let result = autoreleasepool {
                ContinuousClock.now < deadline ? operation(self) : fallback
            }
            // 不在计时器路径释放名额；AX 不返回时后续请求立即失败，UI 仍可浏览历史。
            self.submissionLock.withLock { self.occupied = false }
            pending.finish(ContinuousClock.now < deadline ? result : fallback)
        }
        return pending
    }

    private func captureSynchronously(processIdentifier: pid_t, deadline: ContinuousClock.Instant) -> PasteTargetSnapshot? {
        dispatchPrecondition(condition: .onQueue(queue))
        savedTarget = nil
        // 阶段名均为固定常量；notice/error 可留在系统日志，避免 debug 未持久化导致无法排查。
        var stage = "permission-and-process"
        do {
            try checkDeadline(deadline)
            guard processIdentifier > 0, processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                throw Failure.unavailable
            }
            let application = AXUIElementCreateApplication(processIdentifier)
            try requirePID(application, equals: processIdentifier, deadline: deadline)
            // 捕获发生在菜单栏 mouse-down：系统 AX 焦点可能暂属于菜单栏而非来源应用。
            // 此阶段由 MainActor 在入队前 / 返回后验证 NSWorkspace 前台 PID 与激活代数；
            // 这里只读取指定来源应用，不能用系统 AX 焦点把它提前拒绝，也不能改采其他应用。
            stage = "read-original-focus"
            let focus = try readFocus(application, processIdentifier: processIdentifier, deadline: deadline)
            stage = "original-input-editability"
            if let input = focus.input { try requireEditable(input, deadline: deadline) }
            // 两次读取必须相同，防止捕获过程中同一进程内切换窗口 / 输入框。
            stage = "read-repeated-focus"
            let repeated = try readFocus(application, processIdentifier: processIdentifier, deadline: deadline)
            stage = "compare-original-focus"
            try requireSameFocus(repeated, as: focus)
            try checkDeadline(deadline)
            let snapshot = PasteTargetSnapshot(id: UUID(), processIdentifier: processIdentifier, hasInputNode: focus.input != nil)
            savedTarget = SavedTarget(snapshot: snapshot, application: application, focus: focus)
            return snapshot
        } catch {
            let reason = (error as? Failure)?.diagnosticCode ?? "unexpected"
            logger.error("AX capture rejected: stage=\(stage, privacy: .public), reason=\(reason, privacy: .public)")
            return nil
        }
    }

    private func prepareFocusSynchronously(_ snapshot: PasteTargetSnapshot,
                                           request: PasteFocusRestorationRequest) -> PasteFocusPreparationResult {
        dispatchPrecondition(condition: .onQueue(queue))
        let deadline = request.deadline
        do {
            guard request.targetID == snapshot.id, request.isValid(),
                  let savedTarget, savedTarget.snapshot.id == snapshot.id,
                  savedTarget.snapshot.processIdentifier == snapshot.processIdentifier else { throw Failure.unavailable }
            let pid = snapshot.processIdentifier
            try requirePID(savedTarget.application, equals: pid, deadline: deadline)
            try requireFrontmost(pid, deadline: deadline)
            let current = try readFocus(savedTarget.application, processIdentifier: pid, deadline: deadline)
            let observation = try restorationObservation(current, original: savedTarget.focus, deadline: deadline)
            switch request.action(for: observation, targetID: snapshot.id) {
            case .reject:
                throw Failure.unavailable
            case .ready:
                guard validateSynchronously(snapshot, deadline: deadline), request.isValid() else { throw Failure.unavailable }
                return .ready
            case .wait:
                return .waiting
            case .restoreSavedInput:
                guard let input = savedTarget.focus.input else { throw Failure.unavailable }
                try requirePID(savedTarget.focus.window, equals: pid, deadline: deadline)
                try requirePID(input, equals: pid, deadline: deadline)
                guard let inputWindow = try element(input, attribute: kAXWindowAttribute, deadline: deadline),
                      CFEqual(inputWindow, savedTarget.focus.window) else { throw Failure.unavailable }
                try requirePID(inputWindow, equals: pid, deadline: deadline)
                try requireEditable(input, deadline: deadline)
                // 选区可写不等于可编辑；主动恢复还要求文本值或选中文字本身可写。
                let writableValue = try isSettable(input, attribute: kAXValueAttribute, deadline: deadline)
                let writableText = try isSettable(input, attribute: kAXSelectedTextAttribute, deadline: deadline)
                guard writableValue || writableText,
                      try isSettable(input, attribute: kAXFocusedAttribute, deadline: deadline) else { throw Failure.unavailable }
                let repeated = try readFocus(savedTarget.application, processIdentifier: pid, deadline: deadline)
                try requireSameFocus(repeated, as: current)
                try prepareMessaging(input, deadline: deadline)
                try requireFrontmost(pid, deadline: deadline)
                guard request.isValid() else { throw Failure.unavailable }
                // 不持许可锁跨 AX IPC；已发送的系统消息无法撤回，写入后仍必须深度复核。
                let result = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                try checkDeadline(deadline)
                guard result == .success, request.isValid() else { throw Failure.unavailable }
                logger.notice("AX original input focus restoration requested")
                // 下轮只观察稳定状态，不再次写入，也不重新捕获输入节点。
                return .waiting
            }
        } catch {
            request.cancel()
            logger.debug("AX focus preparation rejected: saved target unavailable, changed or over deadline")
            return .rejected
        }
    }

    /// 只允许原节点暂时消失，或焦点退回其非编辑祖先；其他节点不能当作可恢复的失焦。
    private func restorationObservation(_ current: Focus, original: Focus,
                                        deadline: ContinuousClock.Instant) throws -> PasteFocusObservation {
        guard CFEqual(current.window, original.window) else { return .differentWindow }
        switch (original.input, current.input) {
        case (.none, .none): return .original
        case let (.some(originalInput), .some(currentInput)) where CFEqual(originalInput, currentInput): return .original
        case (.some, .none): return .missingInput
        case let (.some(originalInput), .some(currentInput)):
            guard let role = try attributeValue(currentInput, attribute: kAXRoleAttribute, deadline: deadline) as? String,
                  [kAXWindowRole, kAXGroupRole, kAXScrollAreaRole, kAXSplitGroupRole].contains(role) else {
                return .differentInput
            }
            for attribute in [kAXValueAttribute, kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute] {
                if try isSettable(currentInput, attribute: attribute, deadline: deadline) { return .differentInput }
            }
            var ancestor = originalInput
            // AX 父链由其他进程提供，限制深度，循环 / 缺失 / 错误均不得扩大恢复范围。
            for _ in 0..<12 {
                guard let parent = try element(ancestor, attribute: kAXParentAttribute, deadline: deadline) else { break }
                if CFEqual(parent, currentInput) { return .originalInputContainer }
                if CFEqual(parent, original.window) || CFEqual(parent, ancestor) { break }
                ancestor = parent
            }
            return .differentInput
        default: return .differentInput
        }
    }

    private func isSettable(_ element: AXUIElement, attribute: String, deadline: ContinuousClock.Instant) throws -> Bool {
        try prepareMessaging(element, deadline: deadline)
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        try checkDeadline(deadline)
        switch result {
        case .success: return settable.boolValue
        case .noValue, .attributeUnsupported: return false
        default: throw Failure.accessibility(result.rawValue)
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
            // 部分应用在输入框失焦后把窗口本身报告为 focused UI element；窗口的窗口就是自己。
            if CFEqual(input, window) {
                return Focus(window: window, input: input)
            }
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

    /// 仅在关闭浮层、恢复目标应用后的准备 / 最终校验使用，捕获阶段不要求系统 AX 聚焦应用一致。
    private func requireFrontmost(_ processIdentifier: pid_t, deadline: ContinuousClock.Instant) throws {
        guard let application = try element(AXUIElementCreateSystemWide(), attribute: kAXFocusedApplicationAttribute, deadline: deadline) else {
            logger.error("AX frontmost check rejected: focused application not exposed")
            throw Failure.unavailable
        }
        do {
            try requirePID(application, equals: processIdentifier, deadline: deadline)
        } catch {
            let reason = (error as? Failure)?.diagnosticCode ?? "unexpected"
            logger.error("AX frontmost check rejected: focused application identity, reason=\(reason, privacy: .public)")
            throw error
        }
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
