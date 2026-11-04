/**
 * 真实 AX 回归的测试目标：一个独立 AppKit 进程，提供窗口和两个文本框。
 * SIGUSR1 让窗口退出输入焦点，用于验证 cvMaster 能恢复到原输入节点。
 * 仅由 check-ax.sh 启动，不参与应用构建或分发。
 * @author helele
 * @since 2026-11-04
 */
import AppKit

@MainActor
final class AXTargetDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var fieldA: NSTextField!
    private var fieldB: NSTextField!
    private var resignSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 260, y: 260, width: 420, height: 220),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "cvMaster AX Target"
        fieldA = NSTextField(frame: NSRect(x: 40, y: 130, width: 320, height: 24))
        fieldA.stringValue = "original"
        fieldA.setAccessibilityIdentifier("cvMaster.ax.fieldA")
        fieldB = NSTextField(frame: NSRect(x: 40, y: 80, width: 320, height: 24))
        fieldB.stringValue = "other"
        fieldB.setAccessibilityIdentifier("cvMaster.ax.fieldB")
        window.contentView?.addSubview(fieldA)
        window.contentView?.addSubview(fieldB)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(fieldA)
        NSApp.activate(ignoringOtherApps: true)

        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            self?.window.makeFirstResponder(nil)
        }
        source.resume()
        resignSource = source

        // 测试进程通过该文件取得 PID；只写入当前进程标识，不包含其他数据。
        if let path = CommandLine.arguments.dropFirst().first {
            try? "\(getpid())".write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

@main
struct AXTargetMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AXTargetDelegate()
        app.delegate = delegate
        app.run()
    }
}
