/**
 * 设置页“记录与隐私”：排除来源应用的列表、添加与移除确认。
 * @author helele
 * @since 2026-11-09
 */
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 排除来源应用：列表直接展示图标、名称与 Bundle ID，添加时优先选择正在运行或已安装的应用。
struct RecordsPrivacySettings: View {
    @ObservedObject var library: ClipboardLibrary
    /// 手动输入仅作为找不到应用时的兜底，不要求用户先知道 Bundle ID。
    @ViewState<Bool> private var manualEntry = false
    /// 移除前保留待确认的 Bundle ID，避免误触后立即恢复采集。
    @ViewState<String?> private var pendingRemoval: String?
    /// 内置默认项仅用于显示标记，与采集默认值共用同一来源。
    private let defaultApplicationIDs = Set(PreferenceDefault.excludedApplicationIDs)

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
struct ExcludedApplicationRow: View {
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
struct EmptyExcludedApplicationsView: View {
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
struct ManualBundleIDSheet: View {
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
