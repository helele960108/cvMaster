/**
 * 次级原生设置，真实保存记录偏好与保留规则，不伪装未实现能力。
 * @author helele
 * @since 2026-10-19
 */
import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

/// 待确认的清理范围；cutoff 为 nil 表示清空全部历史。
private struct CleanupRequest {
    let cutoff: Date?
}

struct PreferencesView: View {
    /// 单一共享状态，设置变化立即影响采集策略。
    @ObservedObject var library: ClipboardLibrary
    /// 按时间清理或清空全部都需要明确的二次确认。
    @ViewState<CleanupRequest?> private var pendingCleanup: CleanupRequest?

    var body: some View {
        TabView {
            Tab("通用", systemImage: "gearshape") {
                Form {
                    Section("启动") {
                        Toggle("登录时启动", isOn: Binding(
                            get: { library.launchAtLogin },
                            set: { library.setLaunchAtLogin($0) }
                        ))
                        if library.launchAtLoginRequiresApproval {
                            HStack(spacing: 8) {
                                Label("等待系统允许", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                                Spacer()
                                Button("打开登录项设置") { library.openLoginItemsSettings() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                        Text("登录 Mac 后自动在菜单栏待命，不显示 Dock 图标。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("快捷键") {
                        HStack(spacing: 10) {
                            Text("唤起列表")
                            Spacer(minLength: 12)
                            ShortcutRecorder(library: library)
                            Button("恢复默认") { library.resetGlobalShortcut() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(library.globalShortcut == .defaultShortcut)
                                .help("恢复为 \(GlobalShortcut.defaultShortcut.display)")
                        }
                        if let conflict = library.shortcutConflict {
                            Label(conflict, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("快捷键设置失败：\(conflict)")
                        }
                        Text("快捷键需包含 ⌥、⌃ 或 ⌘⇧；仅 ⌘ 会与复制、粘贴等菜单快捷键冲突。Esc 取消。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Section("权限") {
                        Toggle("允许记录剪贴板", isOn: $library.recordingEnabled)
                        accessibilityPermission
                        if !library.accessibilityGranted {
                            Text("授权后仍无效？请在系统设置中移除旧 cvMaster 条目，再重新添加 ~/Applications/cvMaster.app。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Picker("外观", selection: $library.appearance) {
                            ForEach(AppAppearance.allCases) { appearance in
                                Text(appearance.title).tag(appearance)
                            }
                        }
                        .pickerStyle(.segmented)
                        .help("立即应用于列表浮层与设置窗口，关闭应用后仍保留选择")
                    }
                    Section {
                        Text("只保留菜单栏图标。选择记录后收起并粘贴到原输入位置，需辅助功能授权；关闭记录后不会追溯保存当前剪贴板。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let feedback = library.feedback {
                        Text(feedback).font(.caption).foregroundStyle(ClipboardLibrary.accent)
                    }
                }.formStyle(.grouped)
                .onAppear {
                    library.refreshAccessibilityStatus()
                    library.refreshLaunchAtLoginStatus()
                }
            }
            Tab("记录与隐私", systemImage: "hand.raised") {
                RecordsPrivacySettings(library: library)
            }
            Tab("存储与清理", systemImage: "internaldrive") {
                Form {
                    Section {
                        LabeledContent("已用条数", value: "\(library.storedEntries.formatted()) 条 / \(StorageLimits.maximumEntries.formatted()) 条")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("已用条数")
                            .accessibilityValue("\(library.storedEntries.formatted()) 条，上限 \(StorageLimits.maximumEntries.formatted()) 条")
                        LabeledContent("已用内容量", value: "\(byteText(library.storedBytes)) / \(byteText(StorageLimits.maximumBytes))")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("已用内容量")
                            .accessibilityValue("\(byteText(library.storedBytes))，上限 \(byteText(StorageLimits.maximumBytes))")
                        Text("内容量仅统计内容表示，不含数据库、WAL 和原始文件。")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("历史保留", selection: $library.retention) {
                            Text("7 天").tag(7)
                            Text("30 天").tag(30)
                            Text("90 天").tag(90)
                            Text("180 天").tag(180)
                            Text("1 年").tag(365)
                            Text("永久保留").tag(0)
                        }
                        .help("永久保留不按时间清理，但仍受 \(StorageLimits.maximumEntries.formatted()) 条 / \(byteText(StorageLimits.maximumBytes)) 上限约束")
                    }
                    Section {
                        Text("新内容入库时清理过期和超限记录。选择“永久保留”时不按时间清理，但仍受条数与容量上限约束。自动清理不会删除置顶与已分组内容；保护内容占满容量时拒绝新增。单条最多 16 MB，每种表示最多 8 MB。")
                            .font(.caption).foregroundStyle(.secondary)
                        Menu {
                            Button("清理 1 小时前的记录") { requestCleanup(olderThan: 3_600) }
                            Button("清理 1 天前的记录") { requestCleanup(olderThan: 86_400) }
                            Button("清理 7 天前的记录") { requestCleanup(olderThan: 604_800) }
                            Button("清理 30 天前的记录") { requestCleanup(olderThan: 2_592_000) }
                            Button("清理 1 年前的记录") { requestCleanup(olderThan: 31_536_000) }
                            Divider()
                            Button("清空全部历史…", role: .destructive) { pendingCleanup = CleanupRequest(cutoff: nil) }
                        } label: {
                            Label("清理历史…", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        Text("按时间清理删除所选时间点之前的记录；置顶与已分组内容也会一并清理。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let feedback = library.feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
                }.formStyle(.grouped)
                .onAppear { library.refreshStorageStats() }
            }
        }
        .frame(width: 560, height: 460)
        // 统一继承 AppKit 外观，避免撤销 SwiftUI 颜色偏好时内容仍停留在旧主题。
        .alert("清理历史？", isPresented: cleanupConfirmation, presenting: pendingCleanup) { request in
            Button("取消", role: .cancel) { pendingCleanup = nil }
            Button("清理", role: .destructive) {
                if let cutoff = request.cutoff {
                    library.clear(before: cutoff)
                } else {
                    library.clear()
                }
                pendingCleanup = nil
            }
        } message: { request in
            if let cutoff = request.cutoff {
                let message = "将永久删除早于 \(cutoff.formatted(date: .abbreviated, time: .shortened)) 的记录，包含其中的置顶与分组内容；保留分组结构，不删除引用的原文件。"
                Text(message).accessibilityLabel(message)
            } else {
                let message = "将永久删除全部历史记录，包含置顶与分组内容；保留分组结构，不删除引用的原文件。"
                Text(message).accessibilityLabel(message)
            }
        }
    }

    /// 辅助功能状态与入口；授权后由应用激活自动刷新，也可手动重新检测。
    private var accessibilityPermission: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("辅助功能")
                Text("用于恢复原输入位置并发送 ⌘V，不读取输入内容")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(library.accessibilityGranted ? "已授权" : "未授权")
                    .font(.callout)
                    .foregroundStyle(library.accessibilityGranted ? Color.green : ClipboardLibrary.accent)
                    .accessibilityLabel("辅助功能权限")
                    .accessibilityValue(library.accessibilityGranted ? "已授权" : "未授权")
                if !library.accessibilityGranted {
                    HStack(spacing: 6) {
                        Button("去开启") { library.openAccessibilitySettings() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("打开系统设置 → 隐私与安全性 → 辅助功能")
                        Button("重新检测") { library.refreshAccessibilityStatus() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("从系统设置返回后会自动检测")
                    }
                }
            }
        }
    }

    /// 待确认项存在时展示系统警告，取消或确认后统一清空状态。
    private var cleanupConfirmation: Binding<Bool> {
        Binding(
            get: { pendingCleanup != nil },
            set: { if !$0 { pendingCleanup = nil } }
        )
    }

    /// 以当前时间为基准计算清理边界，避免菜单打开期间时间漂移。
    private func requestCleanup(olderThan seconds: TimeInterval) {
        pendingCleanup = CleanupRequest(cutoff: Date().addingTimeInterval(-seconds))
    }

    /// 容量展示沿用文件大小格式；0 字节显示为 0 KB，避免系统输出非数字文案。
    private func byteText(_ bytes: Int) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

