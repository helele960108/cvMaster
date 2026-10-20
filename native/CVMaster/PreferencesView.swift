/**
 * 次级原生设置，真实保存记录偏好与保留规则，不伪装未实现能力。
 * @author helele
 * @since 2026-10-19
 */
import AppKit
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
                    Section("权限") {
                        Toggle("允许记录剪贴板", isOn: $library.recordingEnabled)
                        accessibilityPermission
                        if !library.accessibilityGranted {
                            Text("授权后仍无效？请在系统设置中移除旧 cvMaster 条目，再重新添加 ~/Applications/cvMaster.app。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        LabeledContent("唤起列表", value: library.shortcutAvailable ? "⌥ Space · 全局" : "快捷键不可用，请点击菜单栏图标")
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

/// 排除来源应用：列表直接展示图标、名称与 Bundle ID，添加时优先选择正在运行或已安装的应用。
private struct RecordsPrivacySettings: View {
    @ObservedObject var library: ClipboardLibrary
    /// 手动输入仅作为找不到应用时的兜底，不要求用户先知道 Bundle ID。
    @ViewState<Bool> private var manualEntry = false
    /// 移除前保留待确认的 Bundle ID，避免误触后立即恢复采集。
    @ViewState<String?> private var pendingRemoval: String?
    /// 内置默认项仅用于显示标记，不阻止用户移除或重新添加。
    private let defaultApplicationIDs: Set<String> = [
        "com.agilebits.onepassword7", "com.1password.1password", "com.apple.Passwords"
    ]

    var body: some View {
        let ids = library.excludedApplicationIDs
        Form {
            Section {
                if ids.isEmpty {
                    EmptyExcludedApplicationsView()
                } else {
                    ForEach(ids, id: \.self) { bundleID in
                        ExcludedApplicationRow(bundleID: bundleID,
                                              isDefault: defaultApplicationIDs.contains(bundleID)) {
                            pendingRemoval = bundleID
                        }
                    }
                }
                addApplicationMenu
            } header: {
                HStack {
                    Text("排除来源应用")
                    Spacer()
                    Text("\(ids.count) 个应用").foregroundStyle(.secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("自动跳过支持的敏感、瞬时及自动生成标记，但不能保证过滤所有密码。来源应用仅为推断，排除规则不是绝对安全边界。")
                    Text("内容仅保存在本机，不联网。文件仅保存引用，不备份本体。数据未采用应用级加密，删除也不等于安全擦除系统备份。")
                    if let feedback = library.feedback {
                        Text(feedback).foregroundStyle(ClipboardLibrary.accent)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $manualEntry) {
            ManualBundleIDSheet { bundleID in
                if let error = library.addExcludedApplication(bundleID) { return error }
                library.notify("已排除 \(ApplicationDirectory.shared.displayName(for: bundleID))")
                return nil
            } dismiss: {
                manualEntry = false
            }
        }
        .alert("移除排除项？", isPresented: removalConfirmation, presenting: pendingRemoval) { bundleID in
            Button("取消", role: .cancel) { pendingRemoval = nil }
            Button("移除", role: .destructive) {
                let name = ApplicationDirectory.shared.displayName(for: bundleID)
                library.removeExcludedApplication(bundleID)
                library.notify("已取消排除 \(name)")
                pendingRemoval = nil
            }
        } message: { bundleID in
            Text("移除后，来自“\(ApplicationDirectory.shared.displayName(for: bundleID))”的复制内容将不再被排除；已有历史不受影响。")
        }
    }

    /// 待确认项存在时展示系统警告，取消或确认后统一清空状态。
    private var removalConfirmation: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )
    }

    /// 正在运行的应用位于菜单顶部，无需再打开文件选择器。
    private var addApplicationMenu: some View {
        Menu {
            let apps = runningApplications
            if apps.isEmpty {
                Button("没有可添加的运行中应用") {}.disabled(true)
            } else {
                Section("正在运行") {
                    ForEach(apps) { app in
                        Button {
                            add(app.bundleID, name: app.name)
                        } label: {
                            Label {
                                Text(app.name)
                            } icon: {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                } else {
                                    Image(systemName: "app.dashed")
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            Button {
                chooseInstalledApplication()
            } label: {
                Label("选择已安装的应用…", systemImage: "folder")
            }
            Button {
                manualEntry = true
            } label: {
                Label("手动输入 Bundle ID…", systemImage: "keyboard")
            }
        } label: {
            Label("添加应用…", systemImage: "plus")
                .foregroundStyle(ClipboardLibrary.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    /// 菜单内容在打开时重新求值；已排除的应用不再重复出现。
    private var runningApplications: [ApplicationInfo] {
        ApplicationDirectory.shared.runningApplications(excluding: library.excludedApplicationIDSet)
    }

    /// 排除项只保存 Bundle ID；失败原因直接作为设置页提示，不写入日志正文。
    private func add(_ bundleID: String, name: String? = nil) {
        if let ownBundleID = Bundle.main.bundleIdentifier,
           ownBundleID.caseInsensitiveCompare(bundleID) == .orderedSame {
            library.notify("不能排除 cvMaster 本身")
            return
        }
        if let error = library.addExcludedApplication(bundleID) {
            library.notify(error)
        } else {
            library.notify("已排除 \(name ?? ApplicationDirectory.shared.displayName(for: bundleID))")
        }
    }

    /// 只选择可读取 Bundle ID 的普通应用；取消选择不修改现有排除列表。
    private func chooseInstalledApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.message = "选择要排除来源的应用"
        panel.prompt = "添加"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            library.notify("未能读取所选应用的 Bundle ID")
            return
        }
        add(bundleID)
    }
}

/// 单条排除项：与列表共用的应用图标缩略图，Bundle ID 作为可核对的次要信息。
private struct ExcludedApplicationRow: View {
    let bundleID: String
    let isDefault: Bool
    let remove: () -> Void

    var body: some View {
        let info = ApplicationDirectory.shared.info(for: bundleID)
        HStack(spacing: 10) {
            Group {
                if let icon = info.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable().scaledToFit()
                }
            }
            .frame(width: 20, height: 20)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(info.name)
                    if isDefault {
                        Text("默认")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(bundleID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.medium)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("取消排除 \(info.name)")
            .accessibilityLabel("取消排除 \(info.name)")
        }
        .padding(.vertical, 3)
    }
}

/// 空状态只说明当前没有排除项，不增加额外管理入口。
private struct EmptyExcludedApplicationsView: View {
    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 5) {
                Image(systemName: "shield").font(.title3).foregroundStyle(.secondary)
                Text("尚未排除任何应用").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 12)
    }
}

/// 手动输入只用于无法从本机应用列表找到的 Bundle ID；校验失败时保留输入。
private struct ManualBundleIDSheet: View {
    let onAdd: (String) -> String?
    let dismiss: () -> Void
    @ViewState private var value = ""
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("手动输入 Bundle ID").font(.headline)
            Text("适用于未安装或不在运行中的应用；无法解析时仍会显示 Bundle ID。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("com.example.app", text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加") { submit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submit() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = onAdd(trimmed) {
            error = message
            return
        }
        dismiss()
    }
}
