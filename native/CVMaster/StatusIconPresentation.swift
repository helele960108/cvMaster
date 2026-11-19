/// 与 Windows 托盘共用状态语义，只反映用户设置的记录开关和暂停。
struct StatusIconPresentation {
    let inactive: Bool
    let tooltip: String

    init(recordingEnabled: Bool, paused: Bool, shortcut: String) {
        let state = !recordingEnabled ? "未开启记录" : (paused ? "已暂停记录" : nil)
        inactive = state != nil
        tooltip = ["cvMaster", shortcut, state].compactMap { $0 }.joined(separator: " · ")
    }
}
