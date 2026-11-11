/**
 * 设置页的全局快捷键录制器：点击后捕获下一次按键，Esc 取消，失败保持录制并提示。
 * @author helele
 * @since 2026-11-09
 */
import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorder: View {
    @ObservedObject var library: ClipboardLibrary
    @ViewState private var recording = false
    @ViewState private var monitor: Any?

    private var shortcut: GlobalShortcut { library.globalShortcut }
    private var conflict: String? { library.shortcutConflict }

    var body: some View {
        Button(action: startRecording) {
            HStack(spacing: 6) {
                Text(recording ? "按下快捷键…" : shortcut.display)
                if conflict != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
            }
            .font(.callout)
            .foregroundStyle(labelColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(minWidth: 96)
            .background(recording ? ClipboardLibrary.accent.opacity(0.12)
                                  : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(recording ? "按下新的快捷键，Esc 取消" : "点击录制新的全局快捷键")
        .accessibilityLabel(accessibilityLabel)
        .onDisappear { stopRecording() }
    }

    private var labelColor: Color {
        if conflict != nil { return .orange }
        if recording { return ClipboardLibrary.accent }
        return .primary
    }

    private var borderColor: Color {
        if conflict != nil { return .orange.opacity(0.8) }
        if recording { return ClipboardLibrary.accent.opacity(0.6) }
        return Color(nsColor: .separatorColor).opacity(0.5)
    }

    private var accessibilityLabel: String {
        if recording {
            return conflict.map { "正在录制全局快捷键，上次组合无效：\($0)，请重新按下组合或按 Esc 取消" }
                ?? "正在录制全局快捷键，按下组合或按 Esc 取消"
        }
        let base = "全局快捷键，当前 \(shortcut.display)，点击录制"
        return conflict.map { "\(base)，上次设置失败：\($0)" } ?? base
    }

    /// 本地监听只捕获设置窗口内的按键，不安装全局输入监听。
    private func startRecording() {
        guard !recording else { return }
        // 设置窗口未必是前台窗口；先激活应用，避免按键被其他应用接收。
        NSApp.activate()
        NSApp.keyWindow?.makeKey()
        library.clearShortcutConflict()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            let candidate = GlobalShortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: GlobalShortcut.modifiers(from: event.modifierFlags),
                label: GlobalShortcut.label(for: event)
            )
            // 校验或注册失败时保持录制，用户可以直接再按一次组合。
            if library.updateGlobalShortcut(candidate) {
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

