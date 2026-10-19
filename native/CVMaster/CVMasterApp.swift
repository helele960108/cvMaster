/**
 * 菜单栏常驻入口：图标与全局快捷键共用同一原生浮层，不创建管理窗口。
 * @author helele
 * @since 2026-10-19
 */
import AppKit
@preconcurrency import ApplicationServices
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

    /// 打开浮层前的外部应用，粘贴时只允许回到此进程，不向当前任意窗口发送按键。
    private var pasteApplication: NSRunningApplication?
    /// 打开浮层前的可编辑焦点；不读取输入框的现有内容。
    private var pasteElement: AXUIElement?
    /// 即使目标延迟暴露输入节点，也必须在原窗口中重试，禁止回退到其他窗口。
    private var pasteWindow: AXUIElement?
    /// 当前进程仅首次缺少权限时请求系统提示，后续点击只显示应用内说明，避免反复弹窗。
    private var requestedAccessibilityPermission = false
    /// 菜单栏点击可能先激活本应用，保留最近的外部应用作为原输入位置的候选。
    private var lastExternalApplication: NSRunningApplication?
    /// 使用 Combine 自动注销工作区通知，不建立键盘监听。
    private var activationSubscription: AnyCancellable?
    /// 仅记录粘贴阶段与错误码，不记录输入框内容、剪贴板内容或文件名。
    private let pasteLogger = Logger(subsystem: "local.helele.cvmaster", category: "paste")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.current = self
        NSApp.setActivationPolicy(.accessory)
        rememberExternalApplication()
        activationSubscription = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // AppKit 工作区通知通过主 RunLoop 投递，外部应用变更不跨线程访问 UI。
                MainActor.assumeIsolated { self?.rememberExternalApplication() }
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
            button.toolTip = "cvMaster · ⌥Space"
            button.target = self
            button.action = #selector(togglePopover)
        }
        statusItem = item
        popover.delegate = self
        library.validatePasteTarget = { [weak self] in
            guard let self else { throw LibraryError.pasteTargetUnavailable }
            try self.validatePasteTarget()
        }
        library.performPaste = { [weak self] in
            guard let self else { throw LibraryError.pasteTargetUnavailable }
            do { try await self.pasteToTarget() }
            catch {
                // 已收起后才发生的失败重新展示列表，让错误反馈可见，不重复捕获目标。
                if !self.popover.isShown, let button = self.statusItem?.button {
                    self.library.panelOpened()
                    self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                }
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
        registerShortcut()
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

    /// 只在菜单栏图标下展示，不在屏幕中央额外创建一个窗口。
    @objc func togglePopover() {
        // 粘贴交接期间不能重新唤起搜索框，避免目标应用恢复前再次抢走键盘焦点。
        guard !library.copying, let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        capturePasteTarget()
        library.resizePanel(to: library.panelHeight)
        library.panelOpened()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        updateResizeHandlePlacement()
        // 等原生 popover 完成锚定后再测量一次，避免动画期间仍使用预估位置。
        Task { @MainActor [weak self] in self?.updateResizeHandlePlacement() }
    }

    /// 按状态图标与浮层的实际屏幕位置，把手柄放到远离图标的一端。
    private func updateResizeHandlePlacement() {
        guard let button = statusItem?.button,
              let iconWindow = button.window,
              let panelWindow = popover.contentViewController?.view.window,
              panelWindow.isVisible else { return }
        let iconRect = iconWindow.convertToScreen(button.convert(button.bounds, to: nil))
        library.updateResizeHandleEdge(iconAbovePanel: iconRect.midY > panelWindow.frame.midY)
    }

    /// 在搜索框取得焦点前保存外部输入位置；未授权时不读取其他应用的辅助功能树。
    private func capturePasteTarget() {
        rememberExternalApplication()
        pasteApplication = lastExternalApplication
        pasteElement = nil
        pasteWindow = nil
        guard AXIsProcessTrusted(), let application = pasteApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let app = accessibilityApplication(application)
        // Electron / Chromium 可延迟创建辅助功能树；主动启用手动辅助功能，不读写用户文本。
        // 原生应用不支持此属性时忽略，仅在目标窗口恢复后继续做严格焦点检查。
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        pasteWindow = accessibilityElement(app, attribute: kAXFocusedWindowAttribute)
        pasteElement = focusedElement(in: application)
        let hasWindow = pasteWindow != nil
        let hasElement = pasteElement != nil
        let editable = pasteElement.map(isEditable) ?? false
        pasteLogger.notice("Paste target captured: window=\(hasWindow), element=\(hasElement), editable=\(editable)")
    }

    /// 只记住实际前台的外部进程，忽略本应用的搜索框、设置窗口和权限提示。
    private func rememberExternalApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApplication = application
    }

    /// 设置短超时，第三方应用无响应时不长时间阻塞菜单栏主线程。
    private func accessibilityApplication(_ application: NSRunningApplication) -> AXUIElement {
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        return app
    }

    /// 仅读取指定的节点引用，不读取节点的文本值；错误码用于定位目标应用兼容性。
    private func accessibilityElement(_ owner: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(owner, attribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            pasteLogger.debug("AX node lookup failed: attribute=\(attribute, privacy: .public), code=\(result.rawValue)")
            return nil
        }
        return (value as! AXUIElement)
    }

    /// 优先使用目标应用焦点，必要时回退系统焦点，但必须核验节点所属进程。
    private func focusedElement(in application: NSRunningApplication) -> AXUIElement? {
        let app = accessibilityApplication(application)
        if let element = accessibilityElement(app, attribute: kAXFocusedUIElementAttribute) { return element }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              let element = accessibilityElement(AXUIElementCreateSystemWide(), attribute: kAXFocusedUIElementAttribute) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == application.processIdentifier else { return nil }
        return element
    }

    /// 粘贴使用快捷键，不要求直接修改 AXValue；网页和 Electron 编辑器可能只允许修改选区。
    /// 已禁用的节点拒绝操作，非文本角色仍须暴露可写选区，不向普通按钮或容器发送内容。
    private func isEditable(_ element: AXUIElement) -> Bool {
        var enabled: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) == .success,
           let enabled = enabled as? Bool, !enabled { return false }
        for attribute in [kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute] {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success,
               settable.boolValue { return true }
        }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String else { return false }
        // 标准文本角色支持键盘粘贴，即使不支持程序直接设置 AXValue。
        let editable = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
        if !editable { pasteLogger.debug("AX focus is not editable: role=\(role, privacy: .public)") }
        return editable
    }

    /// 在改写剪贴板之前无提示地检查权限；每次启动最多请求一次系统授权提示。
    /// 不缓存授权结果，用户在系统设置授权后，下次操作立即重新检查真实状态。
    private func validatePasteTarget() throws {
        guard AXIsProcessTrusted() else {
            if !requestedAccessibilityPermission {
                requestedAccessibilityPermission = true
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            pasteLogger.error("Paste rejected: accessibility permission missing for current signed build")
            throw LibraryError.pastePermissionRequired
        }
        guard let application = pasteApplication, !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              pasteWindow != nil || pasteElement != nil else {
            pasteLogger.error("Paste rejected: original application or window unavailable")
            throw LibraryError.pasteTargetUnavailable
        }
    }

    /// 收起浮层后恢复原应用 / 原窗口并发送标准 ⌘V；可读取原输入节点时额外核验节点一致。
    /// 部分应用不暴露 AX 输入节点，但仍支持系统粘贴，此时由原窗口的 responder 处理命令。
    /// 不选择控件、不点击坐标、不提交消息；窗口变化、权限撤销或应用退出时终止。
    private func pasteToTarget() async throws {
        try validatePasteTarget()
        guard let application = pasteApplication else { throw LibraryError.pasteTargetUnavailable }
        let originalElement = pasteElement
        let originalWindow = pasteWindow
        // 明确得到非编辑节点时不能退回当前任意输入框；仅节点缺失时允许在原窗口中重试。
        if let originalElement, !isEditable(originalElement) {
            pasteLogger.error("Paste rejected: captured node is not editable")
            throw LibraryError.pasteTargetUnavailable
        }
        // 关闭动画会延后 key window 归还，粘贴时直接关闭，避免与焦点恢复竞争。
        let animated = popover.animates
        let panelWindow = popover.contentViewController?.view.window
        // 只解除搜索框的 first responder，浮层可见性由 NSPopover 管理。
        // 禁止直接 orderOut / resignKey 宿主窗口，否则会使 isShown 与真实窗口状态失步。
        panelWindow?.makeFirstResponder(nil)
        popover.animates = false
        // 用户已明确执行粘贴，直接关闭而非可被 field editor 拒绝的 performClose 请求。
        popover.close()
        popover.animates = animated
        NSApp.deactivate()
        let activated = application.activate(options: [])
        pasteLogger.notice("Paste activation requested: accepted=\(activated)")
        // 仅保留最后一个阻塞条件，不记录窗口标题、聊天对象或输入内容。
        var blockedStage = "activation"
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(25))
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let modifiers = CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
            guard frontmost == application.processIdentifier else { blockedStage = "activation"; continue }
            // 必须确认本应用的浮层已隐藏且不再持有 key window，避免搜索框成为粘贴接收方。
            guard !popover.isShown else { blockedStage = "popover-close"; continue }
            // 定向进程投递不依赖已隐藏宿主窗口可能滞后的 isKeyWindow 缓存。
            guard !NSApp.isActive else { blockedStage = "application-deactivation"; continue }
            guard modifiers.isEmpty else { blockedStage = "modifier-release"; continue }
            guard AXIsProcessTrusted(), !application.isTerminated else {
                pasteLogger.error("Paste stopped: permission revoked or target exited")
                throw LibraryError.pasteTargetUnavailable
            }
            // 未捕获到输入节点时仅允许在原窗口重试，绝不向同一应用的其他窗口回退。
            let app = accessibilityApplication(application)
            if let originalWindow {
                guard let window = accessibilityElement(app, attribute: kAXFocusedWindowAttribute),
                      CFEqual(window, originalWindow) else { blockedStage = "original-window"; continue }
            }
            if let originalElement {
                guard let focused = focusedElement(in: application), CFEqual(focused, originalElement),
                      isEditable(focused) else { blockedStage = "original-input"; continue }
            } else {
                // 缺少 AX 输入节点并不表示不存在光标；必须有原窗口作为边界，交由原 responder 粘贴。
                guard originalWindow != nil else { throw LibraryError.pasteTargetUnavailable }
            }
            guard let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
                throw LibraryError.pasteTargetUnavailable
            }
            down.flags = .maskCommand
            up.flags = .maskCommand
            // 定向投递到打开列表前保存的外部进程，不使用全局 HID 路由。
            // 即使系统前台状态与 key window 交接存在时差，事件也不能落入 cvMaster 搜索框。
            down.postToPid(application.processIdentifier)
            up.postToPid(application.processIdentifier)
            let checkedInputNode = originalElement != nil
            pasteLogger.notice("Paste shortcut dispatched directly to saved external process: original window verified, input node checked=\(checkedInputNode)")
            return
        }
        pasteLogger.error("Paste timed out: stage=\(blockedStage, privacy: .public)")
        throw LibraryError.pasteTargetUnavailable
    }

    /// 注册单一系统热键，不申请辅助功能权限；冲突时保留图标入口并提示。
    private func registerShortcut() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in StatusAppDelegate.current?.togglePopover() }
            return noErr
        }, 1, &type, nil, &eventHandler)
        guard installed == noErr else {
            library.shortcutAvailable = false
            return
        }
        let identifier = EventHotKeyID(signature: 0x43564D53, id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), identifier,
                                             GetApplicationEventTarget(), 0, &hotKey)
        library.shortcutAvailable = registered == noErr
        if registered != noErr { statusItem?.button?.toolTip = "cvMaster · 快捷键不可用，请点击图标" }
    }

    func popoverDidClose(_ notification: Notification) { library.panelClosed() }

    func popoverDidShow(_ notification: Notification) { updateResizeHandlePlacement() }

    func applicationWillTerminate(_ notification: Notification) {
        library.monitor?.stop()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        Self.current = nil
    }
}
