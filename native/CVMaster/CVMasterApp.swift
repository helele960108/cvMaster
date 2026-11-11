/**
 * 菜单栏常驻入口：图标与全局快捷键共用同一原生浮层，不创建管理窗口。
 * 粘贴交接与全局快捷键位于 StatusAppDelegate+Paste.swift / +Shortcut.swift。
 * @author helele
 * @since 2026-10-19
 */
import AppKit
import ApplicationServices
import Carbon
import Combine
import Darwin
import OSLog
import SwiftUI

@main
private enum CVMasterLauncher {
    /// 同步持锁后才进入 SwiftUI，重复启动不构造 delegate/library，也不激活已有实例。
    @MainActor
    static func main() {
        do {
            guard let token = try SingleInstanceLock.acquire() else { return }
            withExtendedLifetime(token) { CVMasterApp.main() }
        } catch {
            Logger(subsystem: "local.helele.cvmaster", category: "startup")
                .error("Single-instance startup validation failed")
            Darwin.exit(EXIT_FAILURE)
        }
    }
}

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
    var statusItem: NSStatusItem?
    /// 唯一浮层实例，点击图标和热键都切换此浮层。
    let popover = NSPopover()
    /// Carbon 注册句柄，退出时注销，不监听或收集键盘输入。
    var hotKey: EventHotKeyRef?
    /// 热键回调安装句柄，退出时释放。
    var eventHandler: EventHandlerRef?
    /// 持有外观订阅，设置变更与启动恢复共用同一条同步路径。
    private var appearanceSubscription: AnyCancellable?

    /// 打开列表时的外部应用；选择内容后优先恢复该应用的原输入节点。
    var pasteApplication: NSRunningApplication?
    /// 每次打开列表独立生成的请求身份，不包含窗口、输入内容或 AX 引用。
    var pasteTargetID: UUID?
    /// 原目标 AX 快照与串行焦点恢复；仅在打开列表时捕获一次，后续不重新抓取输入框。
    let pasteTargetWorker = PasteTargetWorker()
    var pasteTargetCapture: PasteTargetWorker.Capture?
    var pasteTargetSnapshot: PasteTargetSnapshot?
    var pasteFocusRequest: PasteFocusRestorationRequest?
    /// 同步消费激活 / 关闭事件；内容读取、焦点恢复和最终发送共用同一份请求身份。
    var pasteHandoff = PasteHandoffPolicy(
        ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
        initiallyActiveProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
    )
    var focusGeneration: UInt64 { pasteHandoff.focusGeneration }
    /// 剪贴板写入前确认激活应用；同步检查只接受同一份准备结果。
    var preparedPasteTarget: UUID?
    var preparedFocusGeneration: UInt64?
    var preparedPasteDeadline: ContinuousClock.Instant?
    /// 使用 Combine 自动注销工作区通知，不建立键盘监听。
    private var activationSubscription: AnyCancellable?
    /// 快捷键变更后同步菜单栏提示，避免注册完成前后读到旧组合。
    private var shortcutSubscription: AnyCancellable?
    /// 仅记录粘贴阶段与错误码，不记录输入框内容、剪贴板内容或文件名。
    let pasteLogger = Logger(subsystem: "local.helele.cvmaster", category: "paste")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.current = self
        NSApp.setActivationPolicy(.accessory)
        activationSubscription = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                // NSWorkspace 在主线程发通知；不再 receive(on:) 二次排队，避免 PID 先变、代数后变。
                // 必须消费该事件的应用，而非稍后查询时已经再次改变的当前前台进程。
                MainActor.assumeIsolated {
                    let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    self?.pasteLogger.notice("Workspace activation received: ownActive=\(NSApp.isActive, privacy: .public)")
                    self?.pasteHandoff.applicationActivated(application?.processIdentifier)
                }
            }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // 独立的单色模板图由系统适配菜单栏明暗，不给标志添加底板。
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

    /// 裁去主图的大幅留白后等比显示 CV；模板图由系统负责明暗及选中态着色。
    /// 启动时只加载一次，不在轮询或列表刷新时重新绘制。
    private func makeStatusIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        let side: CGFloat = 18
        let scale = side / max(image.size.width, image.size.height)
        image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.isTemplate = true
        image.accessibilityDescription = "cvMaster 剪贴板"
        return image
    }

    /// 仅固定当前外部应用，不查询 AX 树，避免菜单栏临时焦点阻断列表或自动粘贴。
    @objc func togglePopover() {
        guard !library.copying, let button = statusItem?.button else { return }
        library.refreshAccessibilityStatus()
        if popover.isShown { popover.performClose(nil); return }
        clearPreparedPasteTarget()
        resetPasteTargetCapture()
        let application = NSWorkspace.shared.frontmostApplication
        pasteApplication = application?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : application
        pasteTargetID = pasteApplication == nil ? nil : UUID()
        if let application = pasteApplication {
            pasteTargetCapture = pasteTargetWorker.beginCapture(
                processIdentifier: application.processIdentifier,
                deadline: .now.advanced(by: .milliseconds(700)))
        }
        library.resizePanel(to: library.panelHeight)
        library.panelOpened()
        pasteHandoff.panelWillOpen(targetID: pasteTargetID, processIdentifier: pasteApplication?.processIdentifier,
                                   frontmostProcessIdentifier: application?.processIdentifier)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        updateResizeHandlePlacement()
        // 等原生 popover 完成锚定后再测量一次，避免动画期间仍使用预估位置。
        Task { @MainActor [weak self] in self?.updateResizeHandlePlacement() }
    }

    /// 按状态图标与浮层的实际屏幕位置，把手柄放到远离图标的一端。
    func updateResizeHandlePlacement() {
        guard let button = statusItem?.button,
              let iconWindow = button.window,
              let panelWindow = popover.contentViewController?.view.window,
              panelWindow.isVisible else { return }
        let iconRect = iconWindow.convertToScreen(button.convert(button.bounds, to: nil))
        library.updateResizeHandleEdge(iconAbovePanel: iconRect.midY > panelWindow.frame.midY)
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

    func popoverDidShow(_ notification: Notification) { updateResizeHandlePlacement() }

    func applicationWillTerminate(_ notification: Notification) {
        clearPreparedPasteTarget()
        library.monitor?.stop()
        unregisterHotKey()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        Self.current = nil
    }
}
