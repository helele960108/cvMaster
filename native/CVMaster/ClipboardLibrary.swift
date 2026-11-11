/**
 * UI 状态与后台存储用例协调的主类：已发布状态、防抖查询、按需预览与清理。
 * 设置 / 采集 / 粘贴 / 分组用例位于 ClipboardLibrary+*.swift 扩展。
 * 约定：Swift 无法让 private(set) 跨文件扩展可写，因此扩展需要写入的发布属性为普通 var；
 * 视图层只读取这些属性，修改必须经由本类的方法，保持单一变更入口。
 * @author helele
 * @since 2026-10-19
 */
import AppKit
@preconcurrency import ApplicationServices
import ServiceManagement
import SwiftUI
import OSLog

/// 缩放手柄所在的边；始终选择远离菜单栏图标的一端。
enum PanelResizeEdge: Equatable {
    case top
    case bottom
}

@MainActor
final class ClipboardLibrary: ObservableObject {
    static let accent = Color(red: 0.67, green: 0.33, blue: 0.18)
    /// 只保留当前最多 300 条元数据；关闭浮层后回收为首屏大小。
    @Published private(set) var clips: [Clip] = []
    @Published var groups: [ClipGroup] = []
    /// 分组写入及权威目录回读期间阻止重复操作，不影响历史列表浏览。
    @Published var changingGroups = false
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
    private(set) var panelHeight: CGFloat = PanelMetrics.restoredHeight(UserDefaults.standard.double(forKey: PreferenceKey.panelHeight))
    /// 由原生容器限制实际可用屏幕高度并同步 popover 尺寸。
    var onResize: ((CGFloat) -> CGFloat)?
    /// 由原生容器在浮层显示后按状态图标的实际位置更新。
    @Published private(set) var resizeHandleEdge: PanelResizeEdge = .bottom

    /// 图标位于浮层上方时手柄放底部，图标位于下方时手柄放顶部。
    func updateResizeHandleEdge(iconAbovePanel: Bool) {
        let edge: PanelResizeEdge = iconAbovePanel ? .bottom : .top
        if resizeHandleEdge != edge {
            resizeHandleEdge = edge
        }
    }

    func resizePanel(to height: CGFloat, persist: Bool = false) {
        guard height.isFinite else { return }
        let requested = PanelMetrics.clamped(height)
        panelHeight = onResize?(requested) ?? requested
        if persist { UserDefaults.standard.set(Double(panelHeight), forKey: PreferenceKey.panelHeight) }
    }

    @Published var selection: UUID?
    @Published var shortcutAvailable = true
    /// 当前全局快捷键；注册由应用代理执行，成功后才持久化。
    @Published var globalShortcut = GlobalShortcut.load()
    /// 最近一次录制失败或启动注册失败的原因。
    @Published var shortcutConflict: String?
    /// 应用代理注入：尝试注册新组合，返回冲突说明或 nil。
    var applyGlobalShortcut: ((GlobalShortcut) -> String?)?
    /// 辅助功能权限状态；浮层引导与设置页共用，每次从系统实时读取。
    @Published var accessibilityGranted = AXIsProcessTrusted()
    /// 系统授权提示每次应用运行最多触发一次，避免反复弹窗。
    var accessibilityPromptShown = false
    /// 登录项状态直接读取系统，不使用独立偏好副本。
    @Published var launchAtLogin = false
    /// 已注册但等待用户在系统设置中批准。
    @Published var launchAtLoginRequiresApproval = false
    /// 外观偏好只存储枚举字符串；应用代理订阅变化并同步原生容器，不重建浮层或轮询服务。
    @Published var appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: PreferenceKey.appearance) ?? "") ?? .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: PreferenceKey.appearance)
        }
    }
    /// 首次使用默认不采集，必须在浮层明确开启；设置为独立布尔偏好。
    @Published var recordingEnabled = UserDefaults.standard.bool(forKey: PreferenceKey.recordingEnabled) {
        didSet { UserDefaults.standard.set(recordingEnabled, forKey: PreferenceKey.recordingEnabled); monitor?.resetBaseline() }
    }
    @Published var paused = UserDefaults.standard.bool(forKey: PreferenceKey.recordingPaused) {
        didSet {
            UserDefaults.standard.set(paused, forKey: PreferenceKey.recordingPaused)
            monitor?.resetBaseline()
        }
    }
    /// 0 表示不按时间清理；缺省仍为 30 天，容量上限始终生效。
    @Published var retention = (UserDefaults.standard.object(forKey: PreferenceKey.retentionDays) == nil
        ? PreferenceDefault.retentionDays
        : max(0, UserDefaults.standard.integer(forKey: PreferenceKey.retentionDays))) {
        didSet { UserDefaults.standard.set(retention, forKey: PreferenceKey.retentionDays) }
    }
    /// 换行分隔的 bundle ID 配置，不将结构化对象序列化为 JSON。
    @Published var excludedApplications = UserDefaults.standard.string(forKey: PreferenceKey.excludedApplications) ?? PreferenceDefault.excludedApplications {
        didSet { UserDefaults.standard.set(excludedApplications, forKey: PreferenceKey.excludedApplications) }
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
    @Published var copying = false
    @Published private(set) var preview: ClipPreview?
    @Published private(set) var previewLoading = false
    /// 写入剪贴板前校验当前激活的 APP 与辅助功能权限，失败时保留原剪贴板。
    var validatePasteTarget: (() throws -> Void)?
    /// 关闭列表并确认目标 APP 稳定激活；成功后才允许改写剪贴板。
    var preparePasteTarget: (() async throws -> Void)?
    /// 写入完成后重新核验目标并发送粘贴；等待期间阻止重复操作。
    var performPaste: (() async throws -> Void)?
    /// 生命周期由应用代理持有；监测器反向弱引用本对象。
    var monitor: ClipboardMonitor?
    let store = HistoryStore()
    let logger = Logger(subsystem: "local.helele.cvmaster", category: "library")
    var searchTask: Task<Void, Never>?
    /// 清空等待已接收的写入结束，避免尚未进入存储 actor 的旧快照在清空后落盘。
    var captureTask: Task<Void, Never>?
    var captureGeneration: UInt64 = 0
    private var previewTask: Task<Void, Never>?
    /// 分组目录单独刷新，不被搜索防抖任务取消，也不接收历史页的旧目录。
    var groupsTask: Task<Void, Never>?
    var groupsVersion = 0
    var feedbackTask: Task<Void, Never>?
    /// 查询版本防止在 actor 等待期间过期结果覆盖新状态。
    private var searchVersion = 0
    private var previewVersion = 0
    private var limit = StorageLimits.pageSize
    var panelVisible = false
    /// 清空过程中暂停新采集，防止用户确认清空后又插入先前排队内容。
    var clearing = false
    /// 采集无积压队列；后台写入未完成时丢弃后续变化并计数，不无限保存 Data。
    var captureBusy = false
    var skippedChanges = 0

    var visibleClips: [Clip] { clips }
    var selectedClip: Clip? { clips.first { $0.id == selection } }
    var hasMore: Bool { clips.count < total && clips.count < StorageLimits.maximumLoaded }

    func start() { refreshGroups(); scheduleSearch(); refreshAccessibilityStatus(); refreshLaunchAtLoginStatus() }

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
        loadPreview(nil)
        if clips.count > StorageLimits.pageSize { clips = Array(clips.prefix(StorageLimits.pageSize)) }
        limit = StorageLimits.pageSize
    }

    /// 防抖并拒绝旧结果；子串匹配与可用索引由存储层统一选择。
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
    /// 每次只保留一个详情；查询代数防止切换条目后旧缩略图覆盖新条目。
    func loadPreview(_ id: UUID?) {
        previewVersion += 1
        let version = previewVersion
        previewTask?.cancel()
        previewTask = nil
        previewLoading = false
        preview = nil
        guard let id else { return }
        previewLoading = true
        previewTask = Task { [weak self, store] in
            do {
                let result = try await store.preview(id)
                guard let self, !Task.isCancelled, version == self.previewVersion else { return }
                self.previewTask = nil
                self.preview = result; self.previewLoading = false
            } catch {
                guard let self, !Task.isCancelled, version == self.previewVersion else { return }
                self.previewTask = nil
                self.previewLoading = false; self.report(error)
            }
        }
    }

    /// 单张小图按需获取，失败使用占位，不让列表绘制触发全局错误提示。
    func thumbnail(_ id: UUID) async -> Data? {
        guard !Task.isCancelled else { return nil }
        return try? await store.thumbnail(id)
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

    func performClear(before cutoff: Date?) {
        guard !clearing else { return }
        clearing = true
        let pendingCapture = captureTask
        Task { [weak self, store] in
            await pendingCapture?.value
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

    func mutate(_ action: @escaping @Sendable (HistoryStore) async throws -> Void) {
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

    func report(_ error: Error) {
        if let error = error as? LibraryError {
            // 仅输出预定义错误码，便于区分授权 / 焦点问题，不记录用户内容。
            logger.error("Local operation failed: \(String(describing: error), privacy: .public)")
        } else {
            logger.error("Local operation failed; content omitted")
        }
        notify((error as? LibraryError)?.localizedDescription ?? LibraryError.storage.localizedDescription)
    }
}
