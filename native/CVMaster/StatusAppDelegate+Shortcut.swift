/**
 * 全局快捷键：Carbon 热键的一次性处理器安装、注册、冲突检查与失败回退。
 * @author helele
 * @since 2026-11-09
 */
import AppKit
import Carbon

@MainActor
extension StatusAppDelegate {
    /// 安装一次热键事件处理；之后只更换注册组合，不重复安装 handler。
    @discardableResult
    func installShortcutHandler() -> Bool {
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
    func registerInitialShortcut() {
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
    func changeGlobalShortcut(_ shortcut: GlobalShortcut) -> String? {
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
    func registerHotKey(_ shortcut: GlobalShortcut) -> OSStatus {
        unregisterHotKey()
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x43564D53, id: 1)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                         GetApplicationEventTarget(), 0, &reference)
        if status == noErr { hotKey = reference }
        return status
    }

    func unregisterHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    func hotKeyError(_ status: OSStatus) -> String {
        status == eventHotKeyExistsErr
            ? "该组合已被其他应用占用，请换一个组合"
            : "无法注册该快捷键（错误 \(status)）"
    }

    /// 菜单栏提示跟随当前组合与注册状态，不永久显示默认键。
    func updateStatusItemTooltip() {
        statusItem?.button?.toolTip = library.shortcutAvailable
            ? "cvMaster · \(library.globalShortcut.display)"
            : "cvMaster · 快捷键不可用，请点击图标"
    }
}
