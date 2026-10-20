/**
 * 菜单栏图标下的唯一主界面：紧凑搜索、分组切换和内容列表，详情按需展开。
 * @author helele
 * @since 2026-10-19
 */
import AppKit
import SwiftUI

struct QuickPanelView: View {
    /// 当前有界历史投影，原始内容由后台存储按需读取。
    @ObservedObject var library: ClipboardLibrary
    /// 关闭同一菜单栏浮层，不退出进程。
    let close: () -> Void
    /// 当前侧边预览条目，与键盘选择独立，悬停不滚动或改变列表选择。
    @ViewState<UUID?> private var previewID = nil
    /// 唯一悬停任务，快速划过时取消，防止连续读取内容。
    @ViewState<Task<Void, Never>?> private var hoverTask = nil
    /// 分组创建和重命名的轻量原生表单状态。
    @ViewState<Bool> private var editingGroup = false
    /// nil 表示创建新分组，否则编辑该稳定标识。
    @ViewState<UUID?> private var groupID = nil
    /// 尚未保存的分组名称。
    @ViewState<String> private var groupName = ""
    /// 待删除条目标识，确认前不更改数据。
    @ViewState<UUID?> private var pendingDelete = nil
    /// 删除确认状态。
    @ViewState<Bool> private var deleting = false
    /// 拖动期间暂停侧边预览，避免浮层重新锚定干扰连续调整。
    @ViewState<Bool> private var resizing = false
    /// 权限横幅仅在本次应用运行内可稍后关闭，下次启动仍会提示。
    @ViewState<Bool> private var permissionBannerDismissed = false
    /// 搜索焦点，在每次浮层显示时恢复。
    @FocusState private var focused: Bool
    /// 系统设置入口只从次级菜单触发。
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            search
            filters
            if showsPermissionBanner { permissionBanner }
            Divider().padding(.horizontal, 14)
            if !library.recordingEnabled {
                VStack(alignment: .leading, spacing: 9) {
                    Text("开启后自动保存新复制的内容，仅保存在本机。可随时暂停、排除应用或删除历史。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("开启剪贴板记录") { library.recordingEnabled = true }
                        .buttonStyle(.glassProminent)
                }.padding(16)
            }
            results
            footer
            resizeHandle
        }
        .frame(width: 350)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        // 统一继承 AppKit 外观，避免撤销 SwiftUI 颜色偏好时内容仍停留在旧主题。
        .onAppear { library.reconcileSelection(); dismissPreview(); focused = true }
        .onDisappear { dismissPreview() }
        .onChange(of: library.query) { dismissPreview() }
        .onChange(of: library.scope) { dismissPreview() }
        .onChange(of: library.kind) { dismissPreview() }
        .onChange(of: library.timeRange) { dismissPreview() }
        .onChange(of: library.accessibilityGranted) {
            // 重新授权后复位，未来若再次撤销权限仍会显示引导。
            if library.accessibilityGranted { permissionBannerDismissed = false }
        }
        .onChange(of: library.clips.map(\.id)) { dismissPreview() }
        .onChange(of: editingGroup) { if editingGroup { dismissPreview() } }
        .onChange(of: deleting) { if deleting { dismissPreview() } }
        // 写入剪贴板前解除 SwiftUI 搜索焦点，避免原生关闭后焦点绑定再次激活搜索框。
        .onChange(of: library.copying) { if library.copying { focused = false; dismissPreview() } }
        .onExitCommand(perform: close)
        .sheet(isPresented: $editingGroup) { groupEditor }
        .alert("确认删除？", isPresented: $deleting) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let pendingDelete { library.delete(pendingDelete) }
                pendingDelete = nil
                library.reconcileSelection()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "clipboard.fill").foregroundStyle(ClipboardLibrary.accent)
            Text("cvMaster").font(.headline)
            Spacer()
            if library.paused {
                Label("已暂停", systemImage: "pause.fill").font(.caption2).foregroundStyle(.secondary)
            }
            Menu {
                Button(library.paused ? "恢复记录" : "暂停记录", systemImage: library.paused ? "play" : "pause") {
                    library.paused.toggle()
                }
                Button("新建分组…", systemImage: "folder.badge.plus") { editGroup(nil) }
                if let id = UUID(uuidString: library.scope) {
                    Button("重命名当前分组…", systemImage: "pencil") { editGroup(id) }
                }
                Divider()
                Button("设置…", systemImage: "gearshape") {
                    close()
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Divider()
                Button("退出 cvMaster", systemImage: "power") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("更多操作")
        }.padding(.horizontal, 18).padding(.top, 15).padding(.bottom, 12)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(library.timeRange == .all ? "搜索剪贴板…" : "搜索剪贴板… · \(library.timeRange.rawValue)", text: $library.query)
                .textFieldStyle(.plain).focused($focused)
                .onSubmit(pasteSelected)
                .onKeyPress(.downArrow) { dismissPreview(); library.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { dismissPreview(); library.moveSelection(-1); return .handled }
            if !library.query.isEmpty {
                Button { library.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(PanelButtonStyle()).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
            }
            timeFilter
        }
        .font(.callout).padding(.horizontal, 10).padding(.vertical, 6)
        .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 14)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        scopeChip("全部", scope: "all")
                        scopeChip("置顶", scope: "pinned")
                        ForEach(library.groups) { scopeChip($0.name, scope: $0.id.uuidString) }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("分组筛选")
                // 新建入口固定在滚动区域外，分组再多也无需滚动寻找。
                Button { editGroup(nil) } label: {
                    Image(systemName: "plus")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PanelButtonStyle())
                .help("新建分组")
                .accessibilityLabel("新建分组")
            }
            HStack(spacing: 4) {
                typeChip(nil)
                ForEach(ClipKind.allCases) { typeChip($0) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("内容类型筛选")
        }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)
    }

    /// 仅在已开启记录且缺少辅助功能权限时提示；关闭记录时由记录引导优先。
    private var showsPermissionBanner: Bool {
        library.recordingEnabled && !library.accessibilityGranted && !permissionBannerDismissed
    }

    /// 情境式权限引导：说明用途、直达系统设置，并允许本次运行内稍后处理。
    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.caption)
                .foregroundStyle(ClipboardLibrary.accent)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("自动粘贴需要辅助功能权限")
                    .font(.caption.weight(.semibold))
                Text("授权后，回车或双击可直接粘贴到原输入位置。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            Spacer(minLength: 4)
            Button("去开启") { library.openAccessibilitySettings() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("打开系统设置 → 隐私与安全性 → 辅助功能")
            Button { permissionBannerDismissed = true } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("稍后")
            .help("本次使用期间不再提示")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(ClipboardLibrary.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(ClipboardLibrary.accent.opacity(0.25), lineWidth: 1)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    /// 原生菜单覆盖展示，不改变列表高度；固定命中区域与清除搜索按钮互不重叠。
    /// 直接使用按钮而非内嵌 Picker，避免 Picker 标签在菜单中额外占一行。
    private var timeFilter: some View {
        Menu {
            ForEach(ClipTimeRange.allCases) { range in
                Button {
                    library.timeRange = range
                } label: {
                    if library.timeRange == range {
                        Label(range.rawValue, systemImage: "checkmark")
                    } else {
                        Text(range.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: "clock")
                .foregroundStyle(library.timeRange == .all ? Color.secondary : ClipboardLibrary.accent)
                .frame(width: 28, height: 28)
                .background(library.timeRange == .all ? .clear : ClipboardLibrary.accent.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topTrailing) {
                    if library.timeRange != .all {
                        Circle().fill(ClipboardLibrary.accent).frame(width: 4, height: 4)
                            .padding(3).allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("时间筛选：\(library.timeRange.rawValue)")
        .accessibilityLabel("时间筛选")
        .accessibilityValue(library.timeRange.rawValue)
        .simultaneousGesture(TapGesture().onEnded { dismissPreview() })
    }

    /// 类型筛选直接显示在分组下方；与分组共同过滤，切换类型不重置分组。
    private func typeChip(_ kind: ClipKind?) -> some View {
        let selected = library.kind == kind
        return Button { library.kind = kind } label: {
            Text(kind?.rawValue ?? "全部类型")
                .font(.caption).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? ClipboardLibrary.accent.opacity(0.13) : .clear, in: Capsule())
                .foregroundStyle(selected ? ClipboardLibrary.accent : .secondary)
                // 命中范围包含文字周围留白，与上排分组按钮保持一致。
                .frame(minWidth: 44, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .accessibilityLabel("内容类型：\(kind?.rawValue ?? "全部类型")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func scopeChip(_ name: String, scope: String) -> some View {
        Button { library.scope = scope } label: {
            Text(name).font(.caption).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 5)
                .background(library.scope == scope ? ClipboardLibrary.accent.opacity(0.13) : .clear, in: Capsule())
                .foregroundStyle(library.scope == scope ? ClipboardLibrary.accent : .secondary)
                // 保持胶囊视觉尺寸，扩展整个标签的命中区域，避免 plain 样式只响应文字。
                .frame(minWidth: 44, minHeight: 32)
                .contentShape(Rectangle())
        }.buttonStyle(PanelButtonStyle()).accessibilityAddTraits(library.scope == scope ? .isSelected : [])
    }

    private var results: some View {
        Group {
            if library.loading && library.clips.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.visibleClips.isEmpty {
                // 轻量空状态避免 ContentUnavailableView 在浮层缩容时产生递归布局。
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
                    Text(library.query.isEmpty ? "还没有内容" : "没有找到内容")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("换个分组、时间范围或关键词试试。")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
                .accessibilityElement(children: .combine)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 9) {
                            ForEach(library.visibleClips) { clip in row(clip).id(clip.id) }
                            if library.hasMore {
                                Button("加载更多") { library.loadMore() }
                                    .buttonStyle(PanelButtonStyle()).font(.caption).padding(8).disabled(library.loading)
                            } else if library.clips.count == StorageLimits.maximumLoaded {
                                Text("已加载 \(StorageLimits.maximumLoaded) 条，请搜索缩小范围").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(12)
                    }
                    .onChange(of: library.selection) { if let id = library.selection { proxy.scrollTo(id) } }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ clip: Clip) -> some View {
        Button {
            library.selection = clip.id
        } label: {
            ClipCardContent(library: library, clip: clip)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(clip.showsImage ? 0 : 13)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        // 单击只负责定位条目；双击沿用回车与右键菜单的同一个粘贴用例。
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard !library.copying, !library.loading else { return }
                library.selection = clip.id
                library.paste(clip)
            }
        )
        .disabled(library.copying || library.loading)
        .help("单击选中，双击粘贴到原输入位置；悬停查看预览")
        // 每行只暴露一条合并后的语义，避免图片、来源和类型子元素重复朗读。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: clip))
        .accessibilityHint("双击粘贴；悬停查看预览")
        .accessibilityAction(named: Text("粘贴")) {
            library.selection = clip.id
            library.paste(clip)
        }
        .accessibilityAction(named: Text("预览内容")) { showPreview(clip.id) }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(library.selection == clip.id ? ClipboardLibrary.accent.opacity(0.8) : Color(nsColor: .separatorColor).opacity(0.4),
                              lineWidth: library.selection == clip.id ? 1.5 : 0.5)
                .allowsHitTesting(false)
        }
        .onHover { inside in schedulePreview(clip.id, inside: inside) }
        .onDisappear { if previewID == clip.id { dismissPreview() } }
        .popover(isPresented: Binding(get: { previewID == clip.id }, set: { shown in
            if !shown, previewID == clip.id { dismissPreview() }
        }), arrowEdge: .trailing) {
            SidePreviewView(library: library, clip: clip)
                .onHover { inside in schedulePreview(clip.id, inside: inside) }
        }
        .contextMenu {
            Button("预览内容", systemImage: "eye") { showPreview(clip.id) }
            Button("粘贴", systemImage: "doc.on.clipboard") { library.paste(clip) }.disabled(library.copying || library.loading)
            if clip.kind == .text || clip.kind == .link {
                Button("粘贴为纯文本", systemImage: "textformat") { library.paste(clip, plainText: true) }
                    .disabled(library.copying || library.loading)
                    .help("移除格式后粘贴到原输入位置")
            }
            Button(clip.pinned ? "取消置顶" : "置顶", systemImage: "pin") { library.setPinned(clip) }
            Menu("加入分组") {
                if library.groups.isEmpty {
                    Text("暂无分组，请先新建分组")
                } else {
                    ForEach(library.groups) { group in
                        let included = library.clips.first { $0.id == clip.id }?.groups.contains(group.id) ?? false
                        // 原生菜单使用明确的按钮和勾选标识，避免 Toggle 桥接丢失显示或状态。
                        Button {
                            library.setGroup(clip, group: group.id, included: !included)
                        } label: {
                            if included { Label(group.name, systemImage: "checkmark") }
                            else { Text(group.name) }
                        }
                        .accessibilityValue(included ? "已加入" : "未加入")
                    }
                }
                Divider()
                Button("新建分组…", systemImage: "folder.badge.plus") { editGroup(nil) }
            }
            Divider()
            Button("删除记录…", systemImage: "trash", role: .destructive) { pendingDelete = clip.id; deleting = true }
        }
    }

    /// 系统 popover 锚定条目侧边，空间不足时由 AppKit 调整位置。
    private func showPreview(_ id: UUID) {
        hoverTask?.cancel()
        guard previewID != id else { return }
        previewID = id
        library.loadPreview(id)
    }

    /// 单行语义合并为一条：置顶状态、类型与正文（或文件名）、来源应用。
    private func accessibilityLabel(for clip: Clip) -> String {
        var parts: [String] = []
        if clip.pinned { parts.append("已置顶") }
        switch clip.kind {
        case .image:
            parts.append("图片")
        case .file:
            parts.append("文件：\(clip.title)")
        case .text, .link:
            let text = (clip.excerpt.isEmpty ? clip.title : clip.excerpt)
                .replacingOccurrences(of: "\n", with: " ")
            parts.append("\(clip.kind.rawValue)：\(String(text.prefix(120)))")
        }
        parts.append("来自\(clip.source)")
        return parts.joined(separator: "，")
    }

    /// 悬停 280 ms 才加载，离开延迟 200 ms，允许鼠标进入侧边预览操作。
    private func schedulePreview(_ id: UUID, inside: Bool) {
        guard !resizing else { return }
        hoverTask?.cancel()
        if inside, previewID == id { return }
        if !inside, previewID != id { return }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(inside ? 280 : 200))
            guard !Task.isCancelled else { return }
            if inside { showPreview(id) }
            else if previewID == id { dismissPreview() }
        }
    }

    /// 关闭时取消延迟任务与后台结果交付，立即释放短正文和缩略图引用。
    private func dismissPreview() {
        hoverTask?.cancel()
        hoverTask = nil
        previewID = nil
        library.loadPreview(nil)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if let feedback = library.feedback {
                    Text(feedback).foregroundStyle(ClipboardLibrary.accent).lineLimit(4).fixedSize(horizontal: false, vertical: true).help(feedback).accessibilityLabel(feedback)
                } else {
                    Text("\(library.total) 条 · 本地保存").foregroundStyle(.secondary)
                    Spacer()
                    Text(library.shortcutAvailable ? library.globalShortcut.display : "热键不可用")
                        .foregroundStyle(library.shortcutAvailable ? Color.secondary : .orange)
                        .lineLimit(1)
                        .help(library.shortcutAvailable ? "全局快捷键：\(library.globalShortcut.display)"
                                                        : "全局快捷键不可用，请在设置中重新录制")
                        .help("↑↓ 选择，回车或双击粘贴；Esc 收起")
                }
            }.font(.caption2).padding(.horizontal, 18).padding(.vertical, 11)
        }
    }

    /// 底部独立手柄只调整列表可用高度，不压缩顶部筛选或卡片字体。
    private var resizeHandle: some View {
        PanelResizeHandle(
            currentHeight: { library.panelHeight },
            resize: { height, finished in library.resizePanel(to: height, persist: finished) },
            draggingChanged: { active in
                resizing = active
                if active { dismissPreview() }
            }
        )
            .frame(height: 18)
            .help("上下拖动调整列表高度")
            .accessibilityLabel("调整列表高度")
            .accessibilityValue("\(Int(library.panelHeight)) 点")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: library.resizePanel(to: library.panelHeight + 40, persist: true)
                case .decrement: library.resizePanel(to: library.panelHeight - 40, persist: true)
                @unknown default: break
                }
            }
    }

    private func pasteSelected() {
        if let clip = library.selectedClip { library.paste(clip) }
    }

    private func editGroup(_ id: UUID?) {
        groupID = id
        groupName = library.groups.first { $0.id == id }?.name ?? ""
        editingGroup = true
    }

    private var groupEditor: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(groupID == nil ? "新建分组" : "重命名分组").font(.headline)
            TextField("分组名称", text: $groupName).textFieldStyle(.roundedBorder)
            Text("1–20 个字符，名称不可重复。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { editingGroup = false }
                Button("保存") {
                    library.saveGroup(groupID, name: groupName)
                    editingGroup = false
                }.disabled(!validName).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 300)
    }

    private var validName: Bool {
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 20 && !library.groups.contains {
            $0.id != groupID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }
}
