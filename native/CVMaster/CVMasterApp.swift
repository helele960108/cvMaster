/**
 * 菜单栏常驻入口：图标与全局快捷键共用同一原生浮层，不创建管理窗口。
 * @author helele
 * @since 2026-10-19
 */
import AppKit
import ApplicationServices
import Carbon
import Combine
import OSLog
import SwiftUI

@main
struct CVMasterApp: App {
    /// 系统生命周期代理，负责菜单栏图标、浮层及全局热键释放。
    @NSApplicationDelegateAdaptor(StatusAppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            PreferencesView(library: delegate.library)
                .tint(ClipboardLibrary.accent)
        }
    }
}

/// 使用系统 popover 自动锚定菜单栏图标，点击外部关闭，不显示 Dock 图标。
@MainActor
final class StatusAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    /// 回调仅在主线程任务内访问的弱引用，不延长应用生命周期。
    static weak var current: StatusAppDelegate?
    /// 共享的轻量 UI 投影与后台持久化用例。
    let library = ClipboardLibrary()
    /// 保持常驻菜单栏图标存活。
    private var statusItem: NSStatusItem?
    /// 唯一浮层实例，点击图标和热键都切换此浮层。
    private let popover = NSPopover()
    /// Carbon 注册句柄，退出时注销，不监听或收集键盘输入。
    private var hotKey: EventHotKeyRef?
    /// 热键回调安装句柄，退出时释放。
    private var eventHandler: EventHandlerRef?
    /// 持有外观订阅，设置变更与启动恢复共用同一条同步路径。
    private var appearanceSubscription: AnyCancellable?

    /// 打开列表时的外部应用；选择内容后向该应用当前 responder 发送粘贴，不绑定 AX 输入节点。
    private var pasteApplication: NSRunningApplication?
    /// 每次打开列表独立生成的请求身份，不包含窗口、输入内容或 AX 引用。
    private var pasteTargetID: UUID?
    /// 同步消费激活 / 关闭事件；内容读取、焦点恢复和最终发送共用同一份请求身份。
    private var pasteHandoff = PasteHandoffPolicy(
        ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
        initiallyActiveProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
    )
    private var focusGeneration: UInt64 { pasteHandoff.focusGeneration }
    /// 剪贴板写入前确认激活应用；同步检查只接受同一份准备结果。
    private var preparedPasteTarget: UUID?
    private var preparedFocusGeneration: UInt64?
    private var preparedPasteDeadline: ContinuousClock.Instant?
    /// 使用 Combine 自动注销工作区通知，不建立键盘监听。
    private var activationSubscription: AnyCancellable?
    /// 快捷键变更后同步菜单栏提示，避免注册完成前后读到旧组合。
    private var shortcutSubscription: AnyCancellable?
    /// 仅记录粘贴阶段与错误码，不记录输入框内容、剪贴板内容或文件名。
    private let pasteLogger = Logger(subsystem: "local.helele.cvmaster", category: "paste")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.current = self
        NSApp.setActivationPolicy(.accessory)
        activationSubscription = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                // NSWorkspace 在主线程发通知；不再 receive(on:) 二次排队，避免 PID 先变、代数后变。
                // 必须消费该事件的应用，而非稍后查询时已经再次改变的当前前台进程。
                MainActor.assumeIsolated {
                    let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    self?.pasteLogger.notice("Workspace activation received: pid=\(application?.processIdentifier ?? -1), ownActive=\(NSApp.isActive)")
                    self?.pasteHandoff.applicationActivated(application?.processIdentifier)
                }
            }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // 菜单栏独立生成透明圆角小图，不改动应用原图或系统按钮高亮形状。
            if let image = makeStatusIcon() {
                button.image = image
            } else {
                // 资源异常时保留可识别的入口，不影响用户打开历史列表。
                button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "cvMaster 剪贴板")
                button.image?.isTemplate = true
            }
            button.toolTip = "cvMaster · \(library.globalShortcut.display)"
            button.target = self
            button.action = #selector(togglePopover)
            // 按下时固定来源 APP，不等 mouse-up；后续不读取或恢复 AX 输入节点。
            button.sendAction(on: [.leftMouseDown])
        }
        statusItem = item
        popover.delegate = self
        library.validatePasteTarget = { [weak self] in
            guard let self else { throw LibraryError.pasteTargetUnavailable }
            do { try self.validatePasteTarget() }
            catch {
                self.presentPasteFailureIfSafe()
                throw error
            }
        }
        library.preparePasteTarget = { [weak self] in
            guard let self else { throw LibraryError.pasteTargetUnavailable }
            do { try await self.preparePasteTarget() }
            catch {
                self.presentPasteFailureIfSafe()
                throw error
            }
        }
        library.performPaste = { [weak self] in
            guard let self else { throw LibraryError.pasteTargetUnavailable }
            do { try await self.pasteToTarget() }
            catch {
                self.presentPasteFailureIfSafe()
                throw error
            }
        }
        let monitor = ClipboardMonitor(library: library)
        library.monitor = monitor
        monitor.start()
        library.start()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 350, height: library.panelHeight)
        library.onResize = { [weak self] requested in
            guard let self else { return requested }
            let screen = self.statusItem?.button?.window?.screen ?? NSScreen.main
            let maximum = min(1000, max(300, (screen?.visibleFrame.height ?? 700) - 50))
            let height = min(requested, maximum)
            guard abs(self.popover.contentSize.height - height) >= 1 else { return height }
            // 连续调整禁止隐式窗口动画，避免上一帧动画追赶下一帧鼠标位置。
            let animated = self.popover.animates
            self.popover.animates = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                self.popover.contentSize = NSSize(width: 350, height: height)
            }
            self.popover.animates = animated
            return height
        }
        let hosting = NSHostingController(rootView:
            QuickPanelView(library: library, close: { [weak self] in self?.popover.performClose(nil) })
                .tint(ClipboardLibrary.accent)
        )
        // 高度由 NSPopover 单独管理，不让 SwiftUI 理想尺寸反向驱动窗口。
        hosting.sizingOptions = []
        popover.contentViewController = hosting
        appearanceSubscription = library.$appearance.sink { [weak self] appearance in
            self?.applyAppearance(appearance)
        }
        library.applyGlobalShortcut = { [weak self] shortcut in
            guard let self else { return "快捷键服务不可用" }
            return self.changeGlobalShortcut(shortcut)
        }
        shortcutSubscription = library.$globalShortcut
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemTooltip() }
        if installShortcutHandler() { registerInitialShortcut() }
    }

    /// 同步应用、独立浮层及宿主视图；nil 同时清除各层覆盖，恢复系统外观继承。
    /// SwiftUI 内容不再单独设置 preferredColorScheme，避免切回系统时留下旧的颜色方案。
    /// 菜单栏锚点可能提供不同于应用的外观，因此不能仅设置 NSApp.appearance。
    private func applyAppearance(_ appearance: AppAppearance) {
        let nativeAppearance = appearance.nativeAppearance
        NSApp.appearance = nativeAppearance
        popover.appearance = nativeAppearance
        popover.contentViewController?.view.appearance = nativeAppearance
    }

    /// 启动时仅绘制一次 18 pt 图标，抗锯齿圆角外保持透明，避免方形底色生硬。
    /// 使用 AppKit 当前显示比例生成位图，不在轮询或列表刷新时反复绘制。
    private func makeStatusIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let source = NSImage(contentsOf: url) else { return nil }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.shouldAntialias = true
        let bounds = NSRect(origin: .zero, size: size)
        NSBezierPath(roundedRect: bounds, xRadius: 4.5, yRadius: 4.5).addClip()
        source.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = "cvMaster 剪贴板"
        return image
    }

    /// 仅固定当前外部应用，不查询 AX 树，避免菜单栏临时焦点阻断列表或自动粘贴。
    @objc func togglePopover() {
        guard !library.copying, let button = statusItem?.button else { return }
        library.refreshAccessibilityStatus()
        if popover.isShown { popover.performClose(nil); return }
        clearPreparedPasteTarget()
        let application = NSWorkspace.shared.frontmostApplication
        pasteApplication = application?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : application
        pasteTargetID = pasteApplication == nil ? nil : UUID()
        library.resizePanel(to: library.panelHeight)
        library.panelOpened()
        pasteHandoff.panelWillOpen(targetID: pasteTargetID, processIdentifier: pasteApplication?.processIdentifier,
                                   frontmostProcessIdentifier: application?.processIdentifier)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// MainActor 只检查本地状态与授权，不同步调用其他进程的 AX 树。
    private func requireSavedPasteTarget(clipboardWritten: Bool = false) throws -> (NSRunningApplication, UUID) {
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
    private func validatePasteTarget() throws {
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

    private func targetIsReady(_ application: NSRunningApplication) -> Bool {
        let modifiers = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        return !popover.isShown && !NSApp.isActive && !application.isTerminated && application.isActive && modifiers.isEmpty
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
    }

    private func clearPreparedPasteTarget() {
        preparedPasteTarget = nil
        preparedFocusGeneration = nil
        preparedPasteDeadline = nil
    }

    /// 剪贴板覆盖前关闭列表并等待目标应用稳定激活，不再恢复或限制某个 AX 输入节点。
    private func preparePasteTarget() async throws {
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
                                                     targetIsActive: application.isActive),
                   pasteHandoff.markPrepared(targetID: target) {
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

    /// 写入完成后同步复核已准备的激活应用并定向派发；检查与派发之间不再 await。
    private func pasteToTarget() async throws {
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
        // 当前 responder 由目标应用决定；只保证向已核验的激活进程投递，不保证内容被接收。
        guard ContinuousClock.now < deadline, AXIsProcessTrusted(), targetIsReady(application),
              pasteHandoff.isPrepared(targetID: target,
                                      frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier) else {
            throw LibraryError.pasteTargetUnavailable
        }
        down.postToPid(application.processIdentifier)
        up.postToPid(application.processIdentifier)
        pasteLogger.notice("Paste shortcut dispatched to current active application: pid=\(application.processIdentifier)")
    }

    /// 失败仅在目标应用或本应用仍在前台时显示说明，不抢走第三个应用的焦点。
    private func presentPasteFailureIfSafe() {
        clearPreparedPasteTarget()
        pasteHandoff.finishRequest()
        guard pasteHandoff.mayPresentFailure, let application = pasteApplication,
              let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontmost == application.processIdentifier || frontmost == ProcessInfo.processInfo.processIdentifier,
              !popover.isShown, let button = statusItem?.button else { return }
        library.panelOpened()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// 安装一次热键事件处理；之后只更换注册组合，不重复安装 handler。
    @discardableResult
    private func installShortcutHandler() -> Bool {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in StatusAppDelegate.current?.togglePopover() }
            return noErr
        }, 1, &type, nil, &eventHandler)
        guard installed == noErr else {
            library.setShortcutRegistration(available: false, conflict: "快捷键服务不可用，请点击菜单栏图标")
            updateStatusItemTooltip()
            return false
        }
        return true
    }

    /// 注册持久化的快捷键；系统占用或注册失败时保留图标入口并说明原因。
    private func registerInitialShortcut() {
        let shortcut = library.globalShortcut
        if let message = shortcut.validationMessage {
            library.setShortcutRegistration(available: false, conflict: message)
            updateStatusItemTooltip()
            return
        }
        if let conflict = GlobalShortcut.systemConflict(for: shortcut) {
            library.setShortcutRegistration(available: false, conflict: conflict)
            updateStatusItemTooltip()
            return
        }
        let status = registerHotKey(shortcut)
        library.setShortcutRegistration(available: status == noErr,
                                        conflict: status == noErr ? nil : hotKeyError(status))
        updateStatusItemTooltip()
    }

    /// 设置页更换快捷键：先检查系统组合，再替换注册；失败时恢复旧组合。
    private func changeGlobalShortcut(_ shortcut: GlobalShortcut) -> String? {
        guard eventHandler != nil else { return "快捷键服务不可用，请重启应用" }
        if let message = shortcut.validationMessage { return message }
        if let conflict = GlobalShortcut.systemConflict(for: shortcut) { return conflict }
        let previous = library.globalShortcut
        let status = registerHotKey(shortcut)
        if status == noErr { return nil }
        let restore = registerHotKey(previous)
        let message = hotKeyError(status)
        library.setShortcutRegistration(available: restore == noErr,
                                        conflict: restore == noErr ? message : "\(message)；原快捷键也未恢复，请重新设置")
        updateStatusItemTooltip()
        return restore == noErr ? message : "\(message)；原快捷键也未恢复，请重新设置"
    }

    /// 先注销旧组合再注册新组合；成功时保存新的 Carbon 引用。
    private func registerHotKey(_ shortcut: GlobalShortcut) -> OSStatus {
        unregisterHotKey()
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x43564D53, id: 1)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                         GetApplicationEventTarget(), 0, &reference)
        if status == noErr { hotKey = reference }
        return status
    }

    private func unregisterHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func hotKeyError(_ status: OSStatus) -> String {
        status == eventHotKeyExistsErr
            ? "该组合已被其他应用占用，请换一个组合"
            : "无法注册该快捷键（错误 \(status)）"
    }

    /// 菜单栏提示跟随当前组合与注册状态，不永久显示默认键。
    private func updateStatusItemTooltip() {
        statusItem?.button?.toolTip = library.shortcutAvailable
            ? "cvMaster · \(library.globalShortcut.display)"
            : "cvMaster · 快捷键不可用，请点击图标"
    }

    func popoverDidClose(_ notification: Notification) {
        pasteHandoff.panelDidClose()
        library.panelClosed()
    }

    /// 从系统设置返回或其他方式重新激活应用时，刷新辅助功能与登录项状态。
    func applicationDidBecomeActive(_ notification: Notification) {
        library.refreshAccessibilityStatus()
        library.refreshLaunchAtLoginStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clearPreparedPasteTarget()
        library.monitor?.stop()
        unregisterHotKey()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        Self.current = nil
    }
}
