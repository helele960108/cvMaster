/**
 * 通用剪贴板轻量监测：500 ms 轮询、休眠暂停、明确同意后采集及敏感标记排除。
 * @author helele
 * @since 2026-10-19
 */
import AppKit
import Carbon
import CoreGraphics
import OSLog

@MainActor
final class ClipboardMonitor {
    /// 反向弱引用避免状态容器与轮询服务互相持有。
    private weak var library: ClipboardLibrary?
    /// 休眠 / 隐私阻止期间仅推进变更基线，不读取内容。
    private var timer: Timer?
    private var cursor = ClipboardChangeCursor()
    /// 同代数重试沿用首次观察到的来源，不把后来切换的前台应用当作复制来源。
    private var pendingSource: (attempt: ClipboardChangeCursor.Attempt, name: String, bundleID: String)?
    private var sleeping = false
    private var sessionInactive = false
    private let lockMonitor = SessionLockMonitor()
    /// 轮询被 App Nap / 系统休眠长时间暂停时，无法确认期间是否锁屏；恢复首轮保守跳过该窗口。
    private static let maximumPollGap: Duration = .seconds(5)
    private var lastPollAt: ContinuousClock.Instant?
    private var readingSnapshot = false
    /// 延迟数据提供者可能重入主循环；生命周期 / 基线变化使正在读取的快照失效。
    private var baselineVersion: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: "local.helele.cvmaster", category: "clipboard")

    init(library: ClipboardLibrary) { self.library = library }

    /// 整个进程仅启动一个轮询器，退出时显式释放计时器和观察者。
    func start() {
        guard timer == nil else { return }
        sleeping = false
        sessionInactive = false
        lockMonitor.onTransition = { [weak self] locked in
            guard let self else { return }
            if locked { self.library?.invalidatePendingCapture() }
            self.resetBaseline()
        }
        lockMonitor.start()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = true; self?.resetBaseline() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = false; self?.resetBaseline() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionInactive = true; self?.resetBaseline() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionInactive = false; self?.resetBaseline() }
        })
        resetBaseline()
        lastPollAt = nil
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.15
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        lockMonitor.stop()
        sleeping = false
        sessionInactive = false
        cursor = ClipboardChangeCursor()
        pendingSource = nil
        lastPollAt = nil
        baselineVersion &+= 1
    }

    /// 应用主动复制、暂停或授权变更后更新基线，避免自采集和追溯暂停期间内容。
    func resetBaseline() {
        baselineVersion &+= 1
        pendingSource = nil
        cursor.resetBaseline(to: NSPasteboard.general.changeCount, blocked: captureBlocked())
    }

    private func captureBlocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        // 公开会话键识别非控制台 / 未登录会话；锁屏使用未公开键并叠加锁屏通知。
        return ClipboardCapturePolicy.isBlocked(
            sleeping: sleeping, sessionInactive: sessionInactive,
            onConsole: session?[kCGSessionOnConsoleKey as String] as? Bool,
            loginComplete: session?[kCGSessionLoginDoneKey as String] as? Bool,
            secureInput: IsSecureEventInputEnabled(),
            screenLocked: lockMonitor.isLocked)
    }

    /// 供 ClipboardLibrary 在真正保存前复核，避免锁屏后的在途快照落库。
    func isCaptureBlocked() -> Bool { captureBlocked() }

    private func poll() {
        guard timer != nil, !readingSnapshot, let library else { return }
        lockMonitor.refresh()
        let now = ContinuousClock.Instant.now
        if ClipboardCapturePolicy.shouldRebaseAfterPollGap(lastPoll: lastPollAt, now: now,
                                                           maximumGap: Self.maximumPollGap) {
            resetBaseline()
        }
        lastPollAt = now
        let pasteboard = NSPasteboard.general
        let change = pasteboard.changeCount
        let attempt: ClipboardChangeCursor.Attempt
        // 被阻止及恢复首轮均只推进基线；关闭记录时也不保留待重试内容。
        switch cursor.observe(change: change, blocked: captureBlocked() || !library.recordingEnabled || library.paused) {
        case .idle:
            pendingSource = nil
            return
        case .expired:
            pendingSource = nil
            reportUnavailableData()
            return
        case .attempt(let observed):
            attempt = observed
        }
        if pendingSource?.attempt != attempt {
            let source = NSWorkspace.shared.frontmostApplication
            pendingSource = (attempt, source?.localizedName ?? "未知应用", source?.bundleIdentifier ?? "")
        }
        guard let source = pendingSource else { return }
        guard !library.captureBusy else {
            finish(attempt, resolution: .commit)
            library.skippedChange()
            return
        }
        guard !sourceIsExcluded(source.bundleID, library: library) else {
            finish(attempt, resolution: .commit)
            return
        }
        readingSnapshot = true
        defer { readingSnapshot = false }
        let version = baselineVersion
        do {
            let result = try snapshot(pasteboard, change: change, version: version,
                                      source: source.name, bundleID: source.bundleID)
            try validateSnapshot(pasteboard, change: change, version: version, bundleID: source.bundleID)
            switch result {
            case .ready(let capture):
                // 读取与提交之间可能锁屏；接受前再次刷新并 fail-closed，不把在途内容落库。
                lockMonitor.refresh()
                guard !captureBlocked() else {
                    finish(attempt, resolution: .commit)
                    return
                }
                if finish(attempt, resolution: .commit) == .committed { library.accept(capture) }
            case .retryable:
                if finish(attempt, resolution: .retryable) == .exhausted { reportUnavailableData() }
            case .ignored:
                finish(attempt, resolution: .commit)
            }
        } catch SnapshotError.changed {
            // 不把最新 changeCount 设为已处理；下一轮以新的请求替换旧快照。
        } catch SnapshotError.contextInvalidated {
            guard timer != nil, baselineVersion == version else { return }
            if cursor.resetBaseline(to: pasteboard.changeCount, blocked: captureBlocked(), ifPending: attempt) {
                baselineVersion &+= 1
                pendingSource = nil
            }
        } catch SnapshotError.sensitive, SnapshotError.excluded {
            finish(attempt, resolution: .commit)
        } catch {
            if finish(attempt, resolution: .commit) == .committed {
                logger.notice("Clipboard capture skipped: unsupported or over size budget")
                library.notify(LibraryError.unsupported.localizedDescription)
            }
        }
    }

    @discardableResult
    private func finish(_ attempt: ClipboardChangeCursor.Attempt,
                        resolution: ClipboardChangeCursor.Resolution) -> ClipboardChangeCursor.Completion {
        let completion = cursor.finish(attempt, resolution: resolution)
        if completion != .pending, pendingSource?.attempt == attempt { pendingSource = nil }
        return completion
    }

    private func sourceIsExcluded(_ bundleID: String, library: ClipboardLibrary) -> Bool {
        let exclusions = library.excludedApplicationIDSet
        let currentBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return exclusions.contains(bundleID.lowercased()) || exclusions.contains(currentBundle.lowercased())
    }

    private func reportUnavailableData() {
        logger.notice("Clipboard capture skipped: data unavailable after bounded retries")
        library?.notify(LibraryError.unsupported.localizedDescription)
    }

    private enum SnapshotError: Error { case changed, contextInvalidated, sensitive, excluded }

    private func validateSnapshot(_ pasteboard: NSPasteboard, change: Int, version: UInt64, bundleID: String) throws {
        guard timer != nil, baselineVersion == version, !captureBlocked(),
              let library, library.recordingEnabled, !library.paused else { throw SnapshotError.contextInvalidated }
        guard pasteboard.changeCount == change else { throw SnapshotError.changed }
        let types = (pasteboard.types ?? []).map(\.rawValue)
        guard pasteboard.changeCount == change else { throw SnapshotError.changed }
        guard ClipboardCapturePolicy.sensitiveTypes.isDisjoint(with: types) else { throw SnapshotError.sensitive }
        guard !sourceIsExcluded(bundleID, library: library) else { throw SnapshotError.excluded }
    }

    /// AppKit 数据读取发生在主线程；仅白名单、有界数量和大小，不解析或解码原图。
    /// 延迟提供数据在读取前无法预知大小，读取后立即限额；系统调用仍可能短暂阻塞。
    private func snapshot(_ pasteboard: NSPasteboard, change: Int, version: UInt64,
                          source: String, bundleID: String) throws -> ClipboardCapturePolicy.ReadResult {
        try validateSnapshot(pasteboard, change: change, version: version, bundleID: bundleID)
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return .retryable }
        try validateSnapshot(pasteboard, change: change, version: version, bundleID: bundleID)
        guard items.count <= StorageLimits.maximumRepresentations else { throw LibraryError.unsupported }
        let itemTypes = items.map { $0.types.map(\.rawValue) }
        return try ClipboardCapturePolicy.capture(itemTypes: itemTypes, source: source, bundleID: bundleID) { index, type in
            try validateSnapshot(pasteboard, change: change, version: version, bundleID: bundleID)
            guard ClipboardCapturePolicy.sensitiveTypes.isDisjoint(with: items[index].types.map(\.rawValue)) else {
                throw SnapshotError.sensitive
            }
            let data = items[index].data(forType: NSPasteboard.PasteboardType(type))
            // 延迟提供者可能切换剪贴板所有者或重入主循环，读取后须重新验证而非混合版本。
            try validateSnapshot(pasteboard, change: change, version: version, bundleID: bundleID)
            guard items.allSatisfy({ ClipboardCapturePolicy.sensitiveTypes.isDisjoint(with: $0.types.map(\.rawValue)) }) else {
                throw SnapshotError.sensitive
            }
            guard pasteboard.changeCount == change else { throw SnapshotError.changed }
            return data
        }
    }
}
