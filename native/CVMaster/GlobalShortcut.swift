/**
 * 全局快捷键的持久化模型、显示格式与冲突检测。
 * @author helele
 * @since 2026-10-20
 */
import AppKit
import Carbon

/// 与 Carbon 注册参数一一对应；label 在录制时按当前键盘布局生成。
struct GlobalShortcut: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    static let defaultShortcut = GlobalShortcut(keyCode: UInt32(kVK_Space),
                                                modifiers: UInt32(optionKey),
                                                label: "Space")

    /// 偏好使用明确类型字段，不把快捷键配置序列化成 JSON。
    private enum Keys {
        static let code = "hotKeyCode"
        static let modifiers = "hotKeyModifiers"
        static let label = "hotKeyLabel"
    }

    /// 读取已保存组合；没有配置时使用默认 ⌥Space。
    static func load(from defaults: UserDefaults = .standard) -> GlobalShortcut {
        guard defaults.object(forKey: Keys.code) != nil else { return .defaultShortcut }
        let code = UInt32(clamping: defaults.integer(forKey: Keys.code))
        let modifiers = UInt32(clamping: defaults.integer(forKey: Keys.modifiers))
        let label = defaults.string(forKey: Keys.label) ?? fallbackLabel(for: code)
        return GlobalShortcut(keyCode: code, modifiers: modifiers, label: label)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Int(keyCode), forKey: Keys.code)
        defaults.set(Int(modifiers), forKey: Keys.modifiers)
        defaults.set(label, forKey: Keys.label)
    }

    /// 至少包含一个主修饰键；仅 Shift 或裸键不能作为全局快捷键。
    var hasRequiredModifier: Bool {
        modifiers & (UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)) != 0
    }

    /// 拒绝仅 Command 的组合，避免抢占复制、粘贴、退出等菜单快捷键。
    var validationMessage: String? {
        guard hasRequiredModifier else { return "请至少包含 ⌘、⌥ 或 ⌃" }
        let hasCommand = modifiers & UInt32(cmdKey) != 0
        let hasShift = modifiers & UInt32(shiftKey) != 0
        let hasOptionOrControl = modifiers & (UInt32(optionKey) | UInt32(controlKey)) != 0
        if hasCommand && !hasOptionOrControl && !hasShift {
            return "仅使用 ⌘ 的组合会与复制、粘贴等菜单快捷键冲突，请加入 ⌥、⌃ 或 ⇧"
        }
        return nil
    }

    /// 显示顺序与 macOS 一致：⌃⌥⇧⌘ + 键名。
    var display: String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + label
    }

    /// 与已启用的系统符号快捷键比较；系统设置占用的组合不一定让 Carbon 返回明确错误。
    static func systemConflict(for shortcut: GlobalShortcut) -> String? {
        var keys: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&keys) == noErr,
              let entries = keys?.takeRetainedValue() as? [[String: Any]] else { return nil }
        for entry in entries {
            let enabled = (entry[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue ?? false
            let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value
            let modifiers = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value
            guard enabled, code == shortcut.keyCode, modifiers == shortcut.modifiers else { continue }
            return "该组合已被系统快捷键占用，请换一个组合"
        }
        return nil
    }

    /// 录制时从 NSEvent 提取 Carbon 修饰键，忽略大小写锁定等功能键状态。
    static func modifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    /// 录制时生成可读键名；字母数字使用当前布局，特殊键使用系统符号。
    static func label(for event: NSEvent) -> String {
        let code = Int(event.keyCode)
        switch code {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default:
            if let index = functionKeyCodes.firstIndex(of: code) { return "F\(index + 1)" }
            if let characters = event.charactersIgnoringModifiers,
               characters.count == 1, !characters.isEmpty {
                return characters.uppercased()
            }
            return "Key\(code)"
        }
    }

    /// 偏好缺少标签时的兜底名称；常用键覆盖，其他键显示键码。
    private static func fallbackLabel(for code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: return "Key\(code)"
        }
    }

    private static let functionKeyCodes: [Int] = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ]
}
