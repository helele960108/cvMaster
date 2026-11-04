/**
 * 真实 AX 回归：启动独立 AppKit 目标进程，跨进程读取 / 恢复原输入节点。
 * 需要当前登录会话和辅助功能权限；不读取文本内容、选区、剪贴板或用户数据库。
 * 仅由 check-ax.sh 构建运行，不参与应用构建或分发。
 * @author helele
 * @since 2026-11-04
 */
import AppKit
import ApplicationServices
import Darwin

private struct AXCheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw AXCheckError(message) }
}

@MainActor
private func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return result == .success ? value : nil
}

@MainActor
private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

@MainActor
private func children(_ element: AXUIElement) -> [AXUIElement] {
    (copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

@MainActor
private func role(_ element: AXUIElement) -> String {
    (copyAttribute(element, kAXRoleAttribute) as? String) ?? ""
}

@MainActor
private func focusedElement(_ application: AXUIElement) -> AXUIElement? {
    axElement(copyAttribute(application, kAXFocusedUIElementAttribute))
}

@MainActor
private func setFocused(_ element: AXUIElement, _ focused: Bool) -> Bool {
    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString,
                                 focused ? kCFBooleanTrue : kCFBooleanFalse) == .success
}

/// 系统级 AX 前台应用 PID；仅用于测试确认目标确实处于前台。
@MainActor
private func focusedApplicationPID() -> pid_t? {
    guard let element = axElement(copyAttribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute)) else {
        return nil
    }
    var pid: pid_t = 0
    return AXUIElementGetPid(element, &pid) == .success ? pid : nil
}

@MainActor
private func ensureFrontmost(_ application: NSRunningApplication, pid: pid_t) async throws {
    for _ in 0..<20 {
        if focusedApplicationPID() == pid { return }
        application.activate(options: [.activateAllWindows])
        try await Task.sleep(for: .milliseconds(100))
    }
    throw AXCheckError("AX 目标进程未成为前台应用")
}

@main
private struct AXChecks {
    @MainActor
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 2, arguments[0] == "--target-app" else {
                throw AXCheckError("用法：ax-checks --target-app <AXTargetApp>")
            }
            guard AXIsProcessTrusted() else {
                throw AXCheckError("当前测试进程没有辅助功能权限；请在系统设置中允许终端或测试宿主")
            }

            let targetPath = arguments[1]
            guard FileManager.default.isExecutableFile(atPath: targetPath) else {
                throw AXCheckError("AX 目标进程不存在或不可执行：\(targetPath)")
            }
            let pidFile = NSTemporaryDirectory() + "cvmaster-ax-target-\(UUID().uuidString).pid"
            defer { try? FileManager.default.removeItem(atPath: pidFile) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: targetPath)
            process.arguments = [pidFile]
            try process.run()
            defer { stop(process) }

            var targetPID: pid_t = 0
            for _ in 0..<50 {
                if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
                   let parsed = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    targetPID = parsed
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard targetPID > 0 else { throw AXCheckError("AX 目标进程未在 5 秒内报告 PID") }

            guard let application = NSRunningApplication(processIdentifier: targetPID) else {
                throw AXCheckError("无法取得 AX 目标进程")
            }
            // 激活目标应用及其窗口，确保跨进程 AX 检查在真实前台条件下运行。
            application.activate(options: [.activateAllWindows])
            try await ensureFrontmost(application, pid: targetPID)
            try await Task.sleep(for: .milliseconds(300))

            let appElement = AXUIElementCreateApplication(targetPID)
            guard let window = axElement(copyAttribute(appElement, kAXFocusedWindowAttribute)) else {
                throw AXCheckError("AX 目标进程没有聚焦窗口")
            }
            let fields = children(window).filter { role($0) == kAXTextFieldRole }
            guard fields.count >= 2 else {
                throw AXCheckError("AX 目标窗口未暴露两个文本框")
            }
            let fieldA = fields[0]
            let fieldB = fields[1]

            try require(setFocused(fieldA, true), "无法聚焦原输入框 A")
            try await Task.sleep(for: .milliseconds(150))
            guard let initial = focusedElement(appElement), CFEqual(initial, fieldA) else {
                throw AXCheckError("无法验证原输入框 A 已聚焦")
            }

            let worker = PasteTargetWorker()
            let capture = worker.beginCapture(processIdentifier: targetPID,
                                              deadline: .now.advanced(by: .seconds(2)))
            guard let snapshot = await capture.value() else {
                throw AXCheckError("PasteTargetWorker 未能捕获原输入节点")
            }
            try require(snapshot.hasInputNode, "捕获快照应包含输入节点")

            // 让目标进程退出输入焦点；窗口本身仍保持聚焦，属于可恢复的原输入容器。
            kill(targetPID, SIGUSR1)
            try await Task.sleep(for: .milliseconds(300))
            try await ensureFrontmost(application, pid: targetPID)
            if let current = focusedElement(appElement), CFEqual(current, fieldA) {
                throw AXCheckError("目标进程没有退出输入焦点，无法验证恢复")
            }

            let request = PasteFocusRestorationRequest(
                targetID: snapshot.id,
                hasSavedInput: snapshot.hasInputNode,
                deadline: .now.advanced(by: .seconds(2)))
            var restored = false
            for _ in 0..<60 {
                switch await worker.prepareFocus(snapshot, request: request) {
                case .ready:
                    restored = true
                case .waiting:
                    try await Task.sleep(for: .milliseconds(20))
                    continue
                case .rejected:
                    throw AXCheckError("焦点恢复被拒绝")
                }
                break
            }
            guard restored, let afterRestore = focusedElement(appElement), CFEqual(afterRestore, fieldA) else {
                throw AXCheckError("焦点没有恢复到原输入框 A")
            }
            let valid = await worker.validate(snapshot, deadline: .now.advanced(by: .seconds(2)))
            try require(valid, "恢复后原目标校验失败")
            print("PASS restore original input node")

            // 同一应用内切换到另一个输入框时必须拒绝，不能把内容投递到错误位置。
            try await ensureFrontmost(application, pid: targetPID)
            try require(setFocused(fieldA, true), "无法重新聚焦原输入框 A")
            try await Task.sleep(for: .milliseconds(150))
            let capture2 = worker.beginCapture(processIdentifier: targetPID,
                                               deadline: .now.advanced(by: .seconds(2)))
            guard let snapshot2 = await capture2.value() else {
                throw AXCheckError("第二次捕获原输入节点失败")
            }
            try require(setFocused(fieldB, true), "无法聚焦另一个输入框 B")
            try await Task.sleep(for: .milliseconds(150))
            let request2 = PasteFocusRestorationRequest(
                targetID: snapshot2.id,
                hasSavedInput: snapshot2.hasInputNode,
                deadline: .now.advanced(by: .seconds(2)))
            let result = await worker.prepareFocus(snapshot2, request: request2)
            guard case .rejected = result else {
                throw AXCheckError("切换到另一个输入框后仍被允许恢复")
            }
            guard let stillB = focusedElement(appElement), CFEqual(stillB, fieldB) else {
                throw AXCheckError("拒绝恢复时不应改变当前输入焦点")
            }
            print("PASS reject different input node")
            print("PASS real AX regression")
        } catch {
            FileHandle.standardError.write(Data("FAIL real AX regression: \(error)\n".utf8))
            exit(1)
        }
    }

    /// 测试结束确保目标 AppKit 进程退出；SIGTERM 后仍存活则强制终止。
    @MainActor
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<10 {
            if !process.isRunning { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(process.processIdentifier, SIGKILL)
    }
}
