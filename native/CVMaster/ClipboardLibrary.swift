/**
 * UI 状态与后台存储用例协调：防抖查询、有界采集、按需预览及真实再次复制。
 * @author helele
 * @since 2026-10-19
 */
import AppKit
@preconcurrency import ApplicationServices
import ServiceManagement
import SwiftUI
import OSLog

@MainActor
final class ClipboardLibrary: ObservableObject {
    static let accent = Color(red: 0.67, green: 0.33, blue: 0.18)
    /// 只保留当前最多 300 条元数据；关闭浮层后回收为首屏大小。
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var groups: [ClipGroup] = []
    @Published private(set) var total = 0
    /// 全库条数与内容表示字节，仅供容量展示，不受当前搜索或筛选影响。
    @Published private(set) var storedEntries = 0
    @Published private(set) var storedBytes = 0
    @Published var scope = "all" { didSet { if oldValue != scope { scheduleSearch() } } }
    @Published var query = "" { didSet { if oldValue != query { scheduleSearch(debounce: true) } } }
    @Published var kind: ClipKind? { didSet { if oldValue != kind { scheduleSearch() } } }
    /// 与分组、内容类型和关键词共同生效，默认不限制时间。
    @Published var timeRange: ClipTimeRange = .all {
        didSet { if oldValue != timeRange { scheduleSearch() } }
    }
    /// 容器尺寸不发布给列表；拖动只调整原生窗口，结束后才保存偏好。
    private(set) var panelHeight: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "panelHeight")
        return saved.isFinite && saved >= 420 ? min(saved, 1000) : 600
    }()
    /// 由原生容器限制实际可用屏幕高度并同步 popover 尺寸。
    var onResize: ((CGFloat) -> CGFloat)?

    func resizePanel(to height: CGFloat, persist: Bool = false) {
        guard height.isFinite else { return }
        let requested = min(max(height, 420), 1000)
        panelHeight = onResize?(requested) ?? requested
        if persist { UserDefaults.standard.set(Double(panelHeight), forKey: "panelHeight") }
    }

    @Published var selection: UUID?
    @Published var shortcutAvailable = true
    /// 当前全局快捷键；注册由应用代理执行，成功后才持久化。
    @Published private(set) var globalShortcut = GlobalShortcut.load()
    /// 最近一次录制失败或启动注册失败的原因。
    @Published private(set) var shortcutConflict: String?
    /// 应用代理注入：尝试注册新组合，返回冲突说明或 nil。
    var applyGlobalShortcut: ((GlobalShortcut) -> String?)?
    /// 辅助功能权限状态；浮层引导与设置页共用，每次从系统实时读取。
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    /// 系统授权提示每次应用运行最多触发一次，避免反复弹窗。
    private var accessibilityPromptShown = false
    /// 登录项状态直接读取系统，不使用独立偏好副本。
    @Published private(set) var launchAtLogin = false
    /// 已注册但等待用户在系统设置中批准。
    @Published private(set) var launchAtLoginRequiresApproval = false
    /// 外观偏好只存储枚举字符串；应用代理订阅变化并同步原生容器，不重建浮层或轮询服务。
    @Published var appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
        }
    }
    /// 首次使用默认不采集，必须在浮层明确开启；设置为独立布尔偏好。
    @Published var recordingEnabled = UserDefaults.standard.bool(forKey: "recordingEnabled") {
        didSet { UserDefaults.standard.set(recordingEnabled, forKey: "recordingEnabled"); monitor?.resetBaseline() }
    }
    @Published var paused = false { didSet { monitor?.resetBaseline() } }
    /// 0 表示不按时间清理；缺省仍为 30 天，容量上限始终生效。
    @Published var retention = (UserDefaults.standard.object(forKey: "retentionDays") == nil
        ? 30
        : max(0, UserDefaults.standard.integer(forKey: "retentionDays"))) {
        didSet { UserDefaults.standard.set(retention, forKey: "retentionDays") }
    }
    /// 换行分隔的 bundle ID 配置，不将结构化对象序列化为 JSON。
    @Published var excludedApplications = UserDefaults.standard.string(forKey: "excludedApplications") ?? "com.agilebits.onepassword7\ncom.1password.1password\ncom.apple.Passwords" {
        didSet { UserDefaults.standard.set(excludedApplications, forKey: "excludedApplications") }
    }
    /// 设置页展示与采集共用的有序去重列表；空白行和重复 ID 不会产生多个条目。
    var excludedApplicationIDs: [String] {
        var seen = Set<String>()
        return excludedApplications.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { seen.insert($0.lowercased()).inserted }
    }
    /// 采集路径使用的小写集合；只在剪贴板变化时读取，不参与 500 ms 轮询。
    var excludedApplicationIDSet: Set<String> {
        Set(excludedApplicationIDs.map { $0.lowercased() })
    }
    @Published private(set) var feedback: String?
    @Published private(set) var loading = false
    @Published private(set) var copying = false
    @Published private(set) var preview: ClipPreview?
    @Published private(set) var previewLoading = false
    /// 写入剪贴板前校验原输入位置与辅助功能权限，失败时保留原剪贴板。
    var validatePasteTarget: (() throws -> Void)?
    /// 写入完成后由原生容器收起浮层、恢复焦点并发送粘贴；等待期间阻止重复操作。
    var performPaste: (() async throws -> Void)?
    /// 生命周期由应用代理持有；监测器反向弱引用本对象。
    var monitor: ClipboardMonitor?
    private let store = HistoryStore()
    private let logger = Logger(subsystem: "local.helele.cvmaster", category: "library")
    private var searchTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    /// 分组目录单独刷新，不被搜索防抖任务取消，也不接收历史页的旧目录。
    private var groupsTask: Task<Void, Never>?
    private var groupsVersion = 0
    private var feedbackTask: Task<Void, Never>?
    /// 查询版本防止在 actor 等待期间过期结果覆盖新状态。
    private var searchVersion = 0
    private var previewVersion = 0
    private var limit = StorageLimits.pageSize
    private var panelVisible = false
    /// 清空过程中暂停新采集，防止用户确认清空后又插入先前排队内容。
    private var clearing = false
    /// 采集无积压队列；后台写入未完成时丢弃后续变化并计数，不无限保存 Data。
    private(set) var captureBusy = false
    private var skippedChanges = 0

    var visibleClips: [Clip] { clips }
    var selectedClip: Clip? { clips.first { $0.id == selection } }
    var hasMore: Bool { clips.count < total && clips.count < StorageLimits.maximumLoaded }

    func start() { refreshGroups(); scheduleSearch(); refreshAccessibilityStatus(); refreshLaunchAtLoginStatus() }

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

    /// 恢复默认 ⌥Space；同样经过冲突检查。
    func resetGlobalShortcut() {
        updateGlobalShortcut(.defaultShortcut)
    }

    /// 设置页打开时刷新全库容量统计，不受当前搜索、分组或时间筛选影响。
    func refreshStorageStats() {
        Task { [weak self, store] in
            do {
                let stats = try await store.storageStats()
                guard let self else { return }
                self.storedEntries = stats.entries
                self.storedBytes = stats.bytes
            } catch { self?.report(error) }
        }
    }

    func panelOpened() {
        panelVisible = true
        refreshAccessibilityStatus()
        refreshGroups()
        preview = nil
        scheduleSearch()
    }

    func panelClosed() {
        panelVisible = false
        // 取消只能阻止未开始的查询；版本失效同时拒绝已在 actor 中执行的旧结果。
        searchVersion += 1
        searchTask?.cancel()
        searchTask = nil
        loading = false
        previewVersion += 1
        previewTask?.cancel()
        preview = nil
        if clips.count > StorageLimits.pageSize { clips = Array(clips.prefix(StorageLimits.pageSize)) }
        limit = StorageLimits.pageSize
    }

    /// 保留至多一个待执行查询；中文子串用 SQLite LIKE，避免主线程扫描全库。
    func scheduleSearch(debounce: Bool = false, resetLimit: Bool = true) {
        searchVersion += 1
        let version = searchVersion
        searchTask?.cancel()
        if resetLimit { limit = StorageLimits.pageSize }
        let query = self.query, scope = self.scope, kind = self.kind, limit = self.limit
        let interval = timeRange.interval(at: Date())
        loading = true
        searchTask = Task { [weak self, store] in
            if debounce { try? await Task.sleep(for: .milliseconds(140)) }
            guard !Task.isCancelled else { return }
            do {
                let page = try await store.page(query: query, scope: scope, kind: kind, interval: interval, limit: limit)
                guard let self, !Task.isCancelled, version == self.searchVersion else { return }
                self.clips = page.clips; self.total = page.total
                self.storedEntries = page.storedEntries; self.storedBytes = page.storedBytes
                self.loading = false
                self.reconcileSelection()
            } catch {
                guard let self, !Task.isCancelled, version == self.searchVersion else { return }
                self.loading = false
                self.report(error)
            }
        }
    }

    func loadMore() {
        guard hasMore, !loading else { return }
        limit = min(limit + StorageLimits.pageSize, StorageLimits.maximumLoaded)
        scheduleSearch(resetLimit: false)
    }

    func reconcileSelection() {
        if !clips.contains(where: { $0.id == selection }) { selection = clips.first?.id }
    }

    func moveSelection(_ offset: Int) {
        guard !clips.isEmpty else { return }
        let current = clips.firstIndex { $0.id == selection } ?? 0
        selection = clips[min(max(current + offset, 0), clips.count - 1)].id
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

    /// 主线程只移交有界快照；哈希、去重、写文件和关系操作都在 actor 上执行。
    func accept(_ capture: ClipCapture) {
        guard !captureBusy, !clearing else { skippedChange(); return }
        captureBusy = true
        let days = retention
        Task { [weak self, store] in
            do {
                try await store.save(capture, retention: days)
                guard let self else { return }
                self.captureBusy = false
                if self.panelVisible { self.scheduleSearch() }
            } catch {
                self?.captureBusy = false
                self?.report(error)
            }
        }
    }

    func skippedChange() {
        skippedChanges += 1
        logger.notice("Capture skipped under backpressure; count: \(self.skippedChanges)")
    }

    /// 粘贴前校验目标并后台读取原始表示，准备成功后才清空剪贴板；自写 changeCount 由监测器跳过。
    /// plainText 为 true 时仅对文本 / 链接生效，转换完成后才写回系统剪贴板。
    func paste(_ clip: Clip, plainText: Bool = false) {
        guard !copying, !loading else { return }
        guard !plainText || clip.kind == .text || clip.kind == .link else { return }
        do {
            guard let validatePasteTarget, performPaste != nil else { throw LibraryError.pasteTargetUnavailable }
            try validatePasteTarget()
        } catch { report(error); return }
        copying = true
        Task { [weak self, store] in
            do {
                let representations: [ClipRepresentation]
                if plainText { representations = try await store.plainText(clip.id, kind: clip.kind) }
                else { representations = try await store.representations(clip.id) }
                guard let self else { return }
                var items: [Int: NSPasteboardItem] = [:]
                for representation in representations {
                    let item = items[representation.item] ?? NSPasteboardItem()
                    // 写入临时 item 失败时不清空系统剪贴板，避免返回不完整的多格式内容。
                    guard item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type)) else {
                        throw LibraryError.missingContent
                    }
                    items[representation.item] = item
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.writeObjects(items.keys.sorted().compactMap { items[$0] }) else {
                    self.monitor?.resetBaseline(); throw LibraryError.missingContent
                }
                self.monitor?.resetBaseline()
                // 读取期间目标可能已关闭；原生层重新校验，失败不会向其他窗口发送内容。
                guard let performPaste = self.performPaste else { throw LibraryError.pasteTargetUnavailable }
                try await performPaste()
                self.copying = false
                // 仅在粘贴事件已发送后记录使用次数，不把写入剪贴板当作粘贴成功。
                do { try await store.markCopied(clip.id) }
                catch { self.report(error) }
            } catch { self?.copying = false; self?.report(error) }
        }
    }

    /// 每次只保留一个详情；查询代数防止切换条目后旧缩略图覆盖新条目。
    func loadPreview(_ id: UUID?) {
        previewVersion += 1
        let version = previewVersion
        previewTask?.cancel()
        preview = nil
        guard let id else { previewLoading = false; return }
        previewLoading = true
        previewTask = Task { [weak self, store] in
            do {
                let result = try await store.preview(id)
                guard let self, !Task.isCancelled, version == self.previewVersion else { return }
                self.preview = result; self.previewLoading = false
            } catch {
                guard let self, !Task.isCancelled, version == self.previewVersion else { return }
                self.previewLoading = false; self.report(error)
            }
        }
    }

    /// 单张小图按需获取，失败使用占位，不让列表绘制触发全局错误提示。
    func thumbnail(_ id: UUID) async -> Data? {
        guard !Task.isCancelled else { return nil }
        return try? await store.thumbnail(id)
    }

    func setPinned(_ clip: Clip) {
        mutate { try await $0.setPinned(clip.id, !clip.pinned) }
    }

    func setGroup(_ clip: Clip, group: UUID, included: Bool) {
        mutate { try await $0.setGroup(clip.id, group: group, included: included) }
    }

    /// 保存成功后立即刷新独立目录，不让高频采集或搜索取消分组更新。
    func saveGroup(_ id: UUID?, name: String) {
        Task { [weak self, store] in
            do {
                try await store.saveGroup(id, name: name)
                self?.refreshGroups()
                self?.scheduleSearch()
            } catch { self?.report(error) }
        }
    }

    /// 分组规模上限 100，独立目录读取成本小，使用版本号防止旧结果覆盖。
    func refreshGroups() {
        groupsVersion += 1
        let version = groupsVersion
        groupsTask?.cancel()
        groupsTask = Task { [weak self, store] in
            do {
                let groups = try await store.groupCatalog()
                guard let self, !Task.isCancelled, self.groupsVersion == version else { return }
                self.groups = groups
            } catch {
                guard !Task.isCancelled else { return }
                self?.report(error)
            }
        }
    }

    func delete(_ id: UUID) { mutate { try await $0.delete(id) } }
    /// 清空全部历史，保留分组结构；清理完成后刷新列表与容量统计。
    func clear() {
        performClear(before: nil)
    }

    /// 删除早于 cutoff 的历史记录，包含置顶与已分组内容；保留分组结构。
    func clear(before cutoff: Date) {
        performClear(before: cutoff)
    }

    private func performClear(before cutoff: Date?) {
        guard !clearing else { return }
        clearing = true
        Task { [weak self, store] in
            do {
                let removed: Int
                if let cutoff {
                    removed = try await store.clear(before: cutoff)
                } else {
                    removed = try await store.clear()
                }
                guard let self else { return }
                self.clearing = false
                self.monitor?.resetBaseline()
                self.scheduleSearch()
                if cutoff != nil {
                    self.notify(removed > 0 ? "已清理 \(removed) 条记录" : "没有早于该时间的记录")
                } else {
                    self.notify("已清空全部历史")
                }
            } catch {
                self?.clearing = false
                self?.report(error)
            }
        }
    }

    private func mutate(_ action: @escaping @Sendable (HistoryStore) async throws -> Void) {
        Task { [weak self, store] in
            do { try await action(store); self?.scheduleSearch() }
            catch { self?.report(error) }
        }
    }

    func notify(_ text: String) {
        feedbackTask?.cancel()
        feedback = text
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.feedback = nil
        }
    }

    private func report(_ error: Error) {
        if let error = error as? LibraryError {
            // 仅输出预定义错误码，便于区分授权 / 焦点问题，不记录用户内容。
            logger.error("Local operation failed: \(String(describing: error), privacy: .public)")
        } else {
            logger.error("Local operation failed; content omitted")
        }
        notify((error as? LibraryError)?.localizedDescription ?? LibraryError.storage.localizedDescription)
    }
}
