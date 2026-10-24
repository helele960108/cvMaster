/**
 * 紧凑浮层交互：局部按钮悬停反馈与屏幕坐标驱动的原生缩放手柄。
 * @author helele
 * @since 2026-10-19
 */
import AppKit
import SwiftUI

/// 悬停仅更新按钮自身，不发布共享状态或触发历史查询；禁用时不显示交互高亮。
struct PanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration)
    }

    private struct Feedback: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var enabled
        @ViewState<Bool> private var hovered = false

        var body: some View {
            configuration.label
                .background(ClipboardLibrary.accent.opacity(enabled ? (configuration.isPressed ? 0.18 : hovered ? 0.09 : 0) : 0),
                            in: RoundedRectangle(cornerRadius: 7))
                .onHover { hovered = $0 }
        }
    }
}

/// 行区域登记器，不参与命中测试；实际鼠标事件由本应用唯一的本地路由按可见区域处理。
struct PanelRowClickTarget: NSViewRepresentable {
    /// 稳定条目标识，防止惰性列表复用后串用上一条目的点击序列。
    let itemID: UUID
    /// 内容加载或粘贴期间禁止选中与粘贴。
    let enabled: Bool
    /// 首击立即选中，同一条目的系统双击完成后请求粘贴。
    let clicked: (Bool) -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.setAccessibilityElement(false)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) {
        if view.itemID != itemID || !enabled { RowMouseRouter.shared.invalidate(view) }
        view.itemID = itemID
        view.enabled = enabled
        view.clicked = clicked
    }

    static func dismantleNSView(_ view: ClickView, coordinator: ()) {
        RowMouseRouter.shared.remove(view)
        view.clicked = nil
    }

    final class ClickView: NSView {
        var itemID: UUID?
        var enabled = false
        var clicked: ((Bool) -> Void)?

        /// 不覆盖 SwiftUI 的命中结果：滚轮、右键菜单及辅助功能仍由原宿主处理。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            RowMouseRouter.shared.remove(self)
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { RowMouseRouter.shared.add(self) }
        }
    }

    /// 一个窗口内路由服务所有可见行，不为每张卡片安装监听，不读取其他进程的输入。
    @MainActor
    private final class RowMouseRouter {
        static let shared = RowMouseRouter()
        private let rows = NSHashTable<ClickView>.weakObjects()
        private var monitor: Any?
        private weak var pressedRow: ClickView?
        private weak var firstRow: ClickView?
        private var firstItemID: UUID?
        private var firstTimestamp: TimeInterval?
        private var pressedItemID: UUID?
        private var isDoubleClick = false

        func add(_ row: ClickView) {
            rows.add(row)
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                // 只观察本应用派发前的事件；不消费鼠标，宿主仍可正常激活窗口。
                return event
            }
        }

        func remove(_ row: ClickView) {
            invalidate(row)
            rows.remove(row)
            if rows.allObjects.isEmpty, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        func invalidate(_ row: ClickView) {
            if pressedRow === row { pressedRow = nil; pressedItemID = nil; isDoubleClick = false }
            if firstRow === row { firstRow = nil; firstItemID = nil; firstTimestamp = nil }
        }

        /// 只接受同窗口、未隐藏且落在滚动裁剪后可见范围内的行，不命中离屏 / 遮挡面板。
        private func row(at event: NSEvent) -> ClickView? {
            guard let window = event.window, window.isVisible, window.attachedSheet == nil,
                  !event.modifierFlags.contains(.control) else { return nil }
            return rows.allObjects.first { row in
                row.window === window && row.enabled && !row.isHiddenOrHasHiddenAncestor
                    && row.visibleRect.contains(row.convert(event.locationInWindow, from: nil))
            }
        }

        private func handle(_ event: NSEvent) {
            switch event.type {
            case .leftMouseDown:
                let row = row(at: event)
                pressedRow = row
                pressedItemID = row?.itemID
                isDoubleClick = event.clickCount == 2 && row != nil && row === firstRow
                    && row?.itemID == firstItemID && firstTimestamp.map {
                        event.timestamp - $0 <= NSEvent.doubleClickInterval
                    } == true
                if event.clickCount == 1, let row {
                    firstRow = row
                    firstItemID = row.itemID
                    firstTimestamp = event.timestamp
                } else {
                    firstRow = nil; firstItemID = nil; firstTimestamp = nil
                }
                // 立即选中，不等 mouseUp，更不要求当前 responder 或上次选中项先变更。
                row?.clicked?(false)
            case .leftMouseDragged:
                pressedRow = nil; pressedItemID = nil; isDoubleClick = false
                firstRow = nil; firstItemID = nil; firstTimestamp = nil
            case .leftMouseUp:
                let target = pressedRow
                let paste = isDoubleClick && target != nil && target === row(at: event)
                    && target?.itemID == pressedItemID
                pressedRow = nil; pressedItemID = nil; isDoubleClick = false
                if paste { target?.clicked?(true) }
            default:
                break
            }
        }
    }
}

/// 原生手柄将高频鼠标事件限制为至多一个待执行更新，松开时立即提交最后尺寸。
struct PanelResizeHandle: NSViewRepresentable {
    /// 手柄所在边决定拖动方向：顶部手柄向上拖增高，底部手柄向下拖增高。
    let edge: PanelResizeEdge
    /// 从容器读取实际高度，不依赖 SwiftUI 布局坐标。
    let currentHeight: () -> CGFloat
    /// finished 为 true 时写入用户偏好，其余仅修改原生窗口。
    let resize: (CGFloat, Bool) -> Void
    /// 仅开始、结束通知 SwiftUI，拖动期间阻止侧边预览。
    let draggingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: GripView, context: Context) {
        view.callbacks = self
    }

    final class GripView: NSView {
        var callbacks: PanelResizeHandle?
        private var tracking: NSTrackingArea?
        private var hovered = false
        private var dragging = false
        private var startY: CGFloat = 0
        private var startHeight: CGFloat = 0
        private var pendingHeight: CGFloat = 0
        /// 最多保留一个约 60 Hz 更新任务，无事件队列积压。
        private var updateTask: Task<Void, Never>?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
        override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

        override func draw(_ dirtyRect: NSRect) {
            let active = hovered || dragging
            if active {
                NSColor.controlAccentColor.withAlphaComponent(0.09).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 7, dy: 1), xRadius: 5, yRadius: 5).fill()
            }
            (active ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 19, y: bounds.midY - 2, width: 38, height: 4), xRadius: 2, yRadius: 2).fill()
        }

        override func mouseDown(with event: NSEvent) {
            guard let callbacks else { return }
            startY = NSEvent.mouseLocation.y
            startHeight = callbacks.currentHeight()
            pendingHeight = startHeight
            dragging = true
            callbacks.draggingChanged(true)
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard dragging else { return }
            // 屏幕坐标不随 popover 移动；每次从起点计算，避免累计误差和回弹。
            pendingHeight = requestedHeight()
            guard updateTask == nil else { return }
            updateTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self, self.dragging else { return }
                self.updateTask = nil
                self.callbacks?.resize(self.pendingHeight, false)
            }
        }

        override func mouseUp(with event: NSEvent) {
            guard dragging else { return }
            pendingHeight = requestedHeight()
            finishDrag()
        }

        /// 顶部手柄向上拖动增高，底部手柄向下拖动增高；始终使用屏幕坐标计算。
        private func requestedHeight() -> CGFloat {
            let edge = callbacks?.edge ?? .bottom
            let delta = edge == .top
                ? NSEvent.mouseLocation.y - startY
                : startY - NSEvent.mouseLocation.y
            return startHeight + delta
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { finishDrag() }
            super.viewWillMove(toWindow: newWindow)
        }

        /// 关闭浮层时也取消待执行更新，不让旧任务修改下次打开的窗口。
        private func finishDrag() {
            updateTask?.cancel()
            updateTask = nil
            guard dragging else { return }
            dragging = false
            callbacks?.resize(pendingHeight, true)
            callbacks?.draggingChanged(false)
            needsDisplay = true
        }
    }
}
