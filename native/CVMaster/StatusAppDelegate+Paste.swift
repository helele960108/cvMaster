/**
 * 粘贴交接：打开列表时绑定目标应用，准备阶段确认稳定前台并恢复原输入节点，
 * 写入剪贴板后再次校验并向保存的 PID 定向发送 ⌘V；失败时仅在安全前提下重新显示反馈。
 * @author helele
 * @since 2026-11-09
 */
import AppKit
import ApplicationServices
import Carbon
import OSLog

@MainActor
extension StatusAppDelegate {
    /// MainActor 只检查本地状态与授权，不同步调用其他进程的 AX 树。
    func requireSavedPasteTarget(clipboardWritten: Bool = false) throws -> (NSRunningApplication, UUID) {
        guard AXIsProcessTrusted() else {
            if !clipboardWritten { library.promptForAccessibilityIfNeeded() }
            pasteLogger.error("Paste rejected: accessibility permission missing for current signed build")
            // 仅写入前可以声称剪贴板未改变，写入后统一提示手动粘贴。
            throw clipboardWritten ? LibraryError.pasteTargetUnavailable : LibraryError.pastePermissionRequired
        }
        guard let application = pasteApplication, !application.isTerminated, let target = pasteTargetID,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            pasteLogger.error("Paste rejected: target application unavailable")
            throw LibraryError.pasteTargetUnavailable
        }
        return (application, target)
    }

    /// 初次同步检查固定用户请求，内容 await 后不能采纳新焦点；最终同步检查只接受同一准备结果。
    func validatePasteTarget() throws {
        let (application, target) = try requireSavedPasteTarget()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if library.copying {
            guard preparedPasteTarget == target, preparedFocusGeneration == focusGeneration,
                  pasteHandoff.isPrepared(targetID: target, frontmostProcessIdentifier: frontmost),
                  let deadline = preparedPasteDeadline, ContinuousClock.now < deadline,
                  targetIsReady(application) else { throw LibraryError.pasteTargetUnavailable }
        } else {
            clearPreparedPasteTarget()
            guard pasteHandoff.beginRequest(targetID: target, processIdentifier: application.processIdentifier,
                                            frontmostProcessIdentifier: frontmost, panelIsShown: popover.isShown) else {
                throw LibraryError.pasteTargetUnavailable
            }
        }
    }

    func targetIsReady(_ application: NSRunningApplication) -> Bool {
        let modifiers = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        return !popover.isShown && !NSApp.isActive && !application.isTerminated && application.isActive && modifiers.isEmpty
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
    }

    func clearPreparedPasteTarget() {
        pasteFocusRequest?.cancel()
        pasteFocusRequest = nil
        preparedPasteTarget = nil
        preparedFocusGeneration = nil
        preparedPasteDeadline = nil
    }

    /// 面板关闭或重新打开时作废旧快照；AX 引用只在 PasteTargetWorker 队列内释放。
    func resetPasteTargetCapture() {
        pasteFocusRequest?.cancel()
        pasteFocusRequest = nil
        pasteTargetCapture = nil
        pasteTargetSnapshot = nil
    }

    /// 只在原输入节点可验证时恢复焦点；不同窗口 / 不同输入框一律拒绝，不回退到当前 responder。
    func prepareOriginalFocus(snapshot: PasteTargetSnapshot, targetID: UUID,
                                      overallDeadline: ContinuousClock.Instant) async throws {
        let focusDeadline = min(overallDeadline, ContinuousClock.now.advanced(by: .milliseconds(700)))
        guard ContinuousClock.now < focusDeadline else { throw LibraryError.pasteTargetUnavailable }
        let request = PasteFocusRestorationRequest(targetID: snapshot.id,
                                                   hasSavedInput: snapshot.hasInputNode,
                                                   deadline: focusDeadline)
        pasteFocusRequest = request
        defer {
            request.cancel()
            pasteFocusRequest = nil
        }
        while ContinuousClock.now < focusDeadline {
            try Task.checkCancellation()
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard pasteHandoff.preparationIsValid(targetID: targetID, frontmostProcessIdentifier: frontmost) else {
                throw LibraryError.pasteTargetUnavailable
            }
            switch await pasteTargetWorker.prepareFocus(snapshot, request: request) {
            case .ready:
                guard await pasteTargetWorker.validate(snapshot, deadline: focusDeadline) else {
                    throw LibraryError.pasteTargetUnavailable
                }
                return
            case .waiting:
                try await Task.sleep(for: .milliseconds(20))
            case .rejected:
                throw LibraryError.pasteTargetUnavailable
            }
        }
        throw LibraryError.pasteTargetUnavailable
    }

    /// 剪贴板覆盖前关闭列表并等待目标应用稳定激活；有原快照时恢复并校验原输入节点。
    func preparePasteTarget() async throws {
        clearPreparedPasteTarget()
        let (application, target) = try requireSavedPasteTarget()
        // 先确认最初点击时的请求仍有效。此处之前禁止 close / deactivate / activate，
        // 否则内容读取期间用户转到 C，会被迟到的准备操作强行拉回原应用 A。
        guard pasteHandoff.beginPreparation(targetID: target,
                                           frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                           ownApplicationIsActive: NSApp.isActive, panelIsShown: popover.isShown) else {
            throw LibraryError.pasteTargetUnavailable
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(2500))
        let animated = popover.animates
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
        popover.animates = false
        // policy 中的 intentionalClosePending 只允许本次关闭事件；其他关闭均使请求失效。
        popover.close()
        // 关闭完成即可确认；delegate 可能延迟送达，策略会忽略重复关闭确认。
        if !popover.isShown { pasteHandoff.panelDidClose() }
        popover.animates = animated
        guard pasteHandoff.preparationIsValid(targetID: target,
                                              frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier) else {
            throw LibraryError.pasteTargetUnavailable
        }
        // macOS 14+ 使用协作式激活；deactivate 本身不等于允许目标应用取得激活权。
        // 先向绑定进程让出激活权，再请求激活；随后确认实际激活状态，不更换目标。
        NSApp.yieldActivation(to: application)
        NSApp.deactivate()
        guard pasteHandoff.preparationIsValid(targetID: target,
                                              frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier) else {
            throw LibraryError.pasteTargetUnavailable
        }
        if !application.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier {
            let activated = application.activate(options: [])
            pasteLogger.notice("Paste activation requested: accepted=\(activated)")
            guard activated else { throw LibraryError.pasteTargetUnavailable }
        }
        var stableSince: ContinuousClock.Instant?
        var stableGeneration = focusGeneration
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let (_, currentTarget) = try requireSavedPasteTarget()
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard currentTarget == target,
                  pasteHandoff.preparationIsValid(targetID: target, frontmostProcessIdentifier: frontmost) else {
                throw LibraryError.pasteTargetUnavailable
            }
            // 当前应用模式允许以实际激活状态确认，不等待已激活应用不会重复产生的通知。
            // 代数变化必须重新计时；第三方应用事件仍由策略永久撤销请求。
            if targetIsReady(application), application.isActive {
                if stableSince == nil || stableGeneration != focusGeneration {
                    stableSince = .now
                    stableGeneration = focusGeneration
                }
                if let stableSince, stableSince.duration(to: .now) >= .milliseconds(100),
                   pasteHandoff.confirmActiveTarget(targetID: target, frontmostProcessIdentifier: frontmost,
                                                     targetIsActive: application.isActive) {
                    if let capture = pasteTargetCapture {
                        let snapshot = await capture.value()
                        pasteTargetSnapshot = snapshot
                        if let snapshot {
                            try await prepareOriginalFocus(snapshot: snapshot, targetID: target,
                                                           overallDeadline: deadline)
                        } else {
                            // 目标应用没有暴露可验证的原窗口 / 输入节点时保留当前 active responder 语义。
                            pasteLogger.notice("AX snapshot unavailable; using current active responder")
                        }
                    }
                    guard pasteHandoff.markPrepared(targetID: target) else {
                        throw LibraryError.pasteTargetUnavailable
                    }
                    preparedPasteTarget = target
                    preparedFocusGeneration = focusGeneration
                    preparedPasteDeadline = .now.advanced(by: .milliseconds(500))
                    try validatePasteTarget()
                    pasteLogger.notice("Paste target prepared: current active application stable")
                    return
                }
            } else {
                stableSince = nil
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        pasteLogger.error("Paste preparation deadline reached")
        throw LibraryError.pasteTargetUnavailable
    }

    /// 写入完成后先复核原 AX 输入节点，再同步复核激活应用并定向派发；最终检查与派发之间不再 await。
    func pasteToTarget() async throws {
        defer {
            clearPreparedPasteTarget()
            pasteHandoff.finishRequest()
        }
        let (application, target) = try requireSavedPasteTarget(clipboardWritten: true)
        guard preparedPasteTarget == target, preparedFocusGeneration == focusGeneration,
              pasteHandoff.isPrepared(targetID: target,
                                      frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier),
              let preparedDeadline = preparedPasteDeadline, ContinuousClock.now < preparedDeadline,
              targetIsReady(application) else { throw LibraryError.pasteTargetUnavailable }
        if let snapshot = pasteTargetSnapshot {
            guard await pasteTargetWorker.validate(snapshot, deadline: preparedDeadline) else {
                throw LibraryError.pasteTargetUnavailable
            }
        }
        try Task.checkCancellation()
        let deadline = preparedDeadline
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            throw LibraryError.pasteTargetUnavailable
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // 只定向保存的 PID；不使用全局 HID 路由，也不选择控件、点击坐标或提交消息。
        // 有原快照时已在写入前恢复并复核原输入节点；无快照时由目标应用当前 responder 决定。
        guard ContinuousClock.now < deadline, AXIsProcessTrusted(), targetIsReady(application),
              pasteHandoff.isPrepared(targetID: target,
                                      frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier) else {
            throw LibraryError.pasteTargetUnavailable
        }
        down.postToPid(application.processIdentifier)
        up.postToPid(application.processIdentifier)
        pasteLogger.notice("Paste shortcut dispatched to current active application: pid=\(application.processIdentifier, privacy: .private)")
    }

    /// 失败仅在目标应用或本应用仍在前台时显示说明，不抢走第三个应用的焦点。
    func presentPasteFailureIfSafe() {
        clearPreparedPasteTarget()
        pasteHandoff.finishRequest()
        guard pasteHandoff.mayPresentFailure, let application = pasteApplication, !application.isTerminated,
              let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontmost == application.processIdentifier || frontmost == ProcessInfo.processInfo.processIdentifier,
              !popover.isShown, let button = statusItem?.button else { return }
        // 失败前的面板已关闭，旧请求也已结束；重试必须创建新的会话，不能复活旧准备许可。
        // 仅沿用上面验证仍在前台（或本应用临时持有前台）的目标，不收养第三方应用。
        resetPasteTargetCapture()
        pasteTargetID = UUID()
        pasteTargetCapture = pasteTargetWorker.beginCapture(
            processIdentifier: application.processIdentifier,
            deadline: .now.advanced(by: .milliseconds(700)))
        pasteHandoff.panelWillOpen(targetID: pasteTargetID, processIdentifier: application.processIdentifier,
                                   frontmostProcessIdentifier: frontmost)
        library.panelOpened()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
