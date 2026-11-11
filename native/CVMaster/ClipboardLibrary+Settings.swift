/**
 * 辅助功能授权、登录项、全局快捷键与排除来源应用的偏好用例。
 * @author helele
 * @since 2026-11-09
 */
import AppKit
@preconcurrency import ApplicationServices
import ServiceManagement

@MainActor
extension ClipboardLibrary {
    /// 重新读取系统授权状态；打开浮层、应用激活和进入设置时调用，不做定时轮询。
    func refreshAccessibilityStatus() {
        let granted = AXIsProcessTrusted()
        if granted != accessibilityGranted {
            accessibilityGranted = granted
            // 重新授权后复位，未来若再次撤销权限仍可触发一次系统提示。
            if granted { accessibilityPromptShown = false }
        }
    }

    /// 首次缺少权限时触发系统授权提示，确保应用出现在辅助功能列表中。
    func promptForAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted(), !accessibilityPromptShown else { return }
        accessibilityPromptShown = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 首次点击先走系统授权提示，之后直接打开辅助功能设置页。
    func openAccessibilitySettings() {
        guard !AXIsProcessTrusted() else { refreshAccessibilityStatus(); return }
        if !accessibilityPromptShown {
            promptForAccessibilityIfNeeded()
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshAccessibilityStatus()
    }

    /// 读取系统登录项状态；应用激活或进入设置时调用，不维护独立偏好副本。
    func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        launchAtLoginRequiresApproval = status == .requiresApproval
    }

    /// 注册或移除登录项；需要用户批准时保持开启状态，并在设置页给出入口。
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if launchAtLogin {
                // 系统设置中可能已关闭该项；状态未标记为开启时不重复调用 unregister。
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
            if launchAtLoginRequiresApproval {
                notify("登录项已注册，请在系统设置 → 通用 → 登录项中允许 cvMaster")
            } else if launchAtLogin == enabled {
                notify(enabled ? "已开启登录时启动" : "已关闭登录时启动")
            } else {
                notify("登录项状态未改变，请在系统设置中检查")
            }
        } catch {
            refreshLaunchAtLoginStatus()
            notify("无法更新登录时启动：\(error.localizedDescription)")
        }
    }

    /// 打开系统设置 → 通用 → 登录项，供待批准状态使用。
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// 应用代理回写真实注册状态；启动注册失败或恢复失败时由代理调用。
    func setShortcutRegistration(available: Bool, conflict: String?) {
        shortcutAvailable = available
        shortcutConflict = conflict
    }

    /// 先校验组合，再交由应用代理注册；失败保留原快捷键并显示原因。
    @discardableResult
    func updateGlobalShortcut(_ shortcut: GlobalShortcut) -> Bool {
        if shortcut == globalShortcut, shortcutAvailable {
            shortcutConflict = nil
            return true
        }
        if let message = shortcut.validationMessage {
            shortcutConflict = message
            return false
        }
        guard let applyGlobalShortcut else {
            shortcutConflict = "快捷键服务尚未就绪"
            return false
        }
        if let error = applyGlobalShortcut(shortcut) {
            shortcutConflict = error
            return false
        }
        shortcutConflict = nil
        shortcutAvailable = true
        globalShortcut = shortcut
        shortcut.save()
        return true
    }

    /// 开始录制新组合时清除上一次的校验失败提示；注册服务本身不可用时保留原因。
    func clearShortcutConflict() {
        guard shortcutAvailable else { return }
        shortcutConflict = nil
    }

    /// 恢复默认 ⇧⌘V；同样经过冲突检查。
    func resetGlobalShortcut() {
        updateGlobalShortcut(.defaultShortcut)
    }

    /// 添加排除项；返回面向用户的错误，成功时只更新持久化配置，由调用方给出提示。
    @discardableResult
    func addExcludedApplication(_ bundleID: String) -> String? {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*$"#, options: .regularExpression) != nil else {
            return "请输入有效的 Bundle ID，例如 com.example.app"
        }
        let ids = excludedApplicationIDs
        guard !ids.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return "该应用已在排除列表中"
        }
        excludedApplications = (ids + [trimmed]).joined(separator: "\n")
        return nil
    }

    /// 移除排除项；不存在时不做写入，避免无意义地触发偏好刷新。
    func removeExcludedApplication(_ bundleID: String) {
        let ids = excludedApplicationIDs
        guard ids.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) else { return }
        excludedApplications = ids
            .filter { $0.caseInsensitiveCompare(bundleID) != .orderedSame }
            .joined(separator: "\n")
    }
}
