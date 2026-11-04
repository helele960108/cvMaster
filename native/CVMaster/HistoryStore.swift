/**
 * SQLite 串行后台存储：关系型元数据与独立内容文件，不使用 JSON 字段。
 * 所有查询、索引、哈希、磁盘读写及图片降采样均与 MainActor 隔离。
 * @author helele
 * @since 2026-10-19
 */
import Foundation
import AppKit
import SQLite3
import CryptoKit
import OSLog
import Darwin
import Dispatch

/// 只允许预定义绑定类型，不拼接用户提供的 SQL。
private enum SQLValue {
    case text(String), integer(Int), real(Double)
}

/// 外部文件可读性也可能被异常挂载点阻塞；仅两个实际工作槽，无排队替代线程。
/// 三秒仅限制调用者等待，取消 / 超时不会释放仍在系统调用中的槽。
private final class FileAvailability: @unchecked Sendable {
    static let shared = FileAvailability()
    private let lock = NSLock()
    private var active = 0
    private let workers = DispatchQueue(label: "local.helele.cvmaster.availability", qos: .utility, attributes: .concurrent)
    private let deadlines = DispatchQueue(label: "local.helele.cvmaster.availability.deadlines", qos: .utility)

    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var timer: DispatchSourceTimer?
        private var finished = false

        func install(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
            let installed = lock.withLock {
                guard !finished else { return false }
                self.continuation = continuation
                return true
            }
            if !installed { continuation.resume(returning: false) }
            return installed
        }

        func startDeadline(on queue: DispatchQueue) {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 3)
            source.setEventHandler { [weak self] in self?.finish(false) }
            lock.withLock {
                source.resume()
                if finished { source.setEventHandler(handler: nil); source.cancel() }
                else { timer = source }
            }
        }

        func finish(_ value: Bool) {
            let result = lock.withLock { () -> (CheckedContinuation<Bool, Never>?, DispatchSourceTimer?) in
                guard !finished else { return (nil, nil) }
                finished = true
                let result = (continuation, timer)
                continuation = nil
                timer = nil
                return result
            }
            result.1?.setEventHandler(handler: nil)
            result.1?.cancel()
            result.0?.resume(returning: value)
        }
    }

    func check(_ urls: [URL]) async -> Bool {
        guard !Task.isCancelled, urls.count <= StorageLimits.maximumRepresentations else { return false }
        guard !urls.isEmpty else { return true }
        // 这里只检查纯 URL 属性，不在存储 actor 内查询外部卷或解析符号链接。
        guard urls.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost")
            && !$0.path.utf8.contains(0) }) else { return false }
        let waiter = Waiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard waiter.install(continuation) else { return }
                let admitted = lock.withLock {
                    guard active < 2 else { return false }
                    active += 1
                    return true
                }
                guard admitted else { waiter.finish(false); return }
                waiter.startDeadline(on: deadlines)
                workers.async { [self] in
                    defer { lock.withLock { active -= 1 } }
                    // 不调用下载 API；元数据 / access 本身仍可能触发 OS 文件系统行为。
                    let readable = urls.allSatisfy { url in
                        guard let info = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
                              info.isUbiquitousItem != true || info.ubiquitousItemDownloadingStatus == .current
                                || info.ubiquitousItemDownloadingStatus == .downloaded else { return false }
                        return FileManager.default.isReadableFile(atPath: url.path)
                    }
                    waiter.finish(readable)
                }
            }
        } onCancel: {
            waiter.finish(false)
        }
    }
}

actor HistoryStore {
    /// 数据库连接仅由本 actor 访问，避免并发共享 SQLite 指针。
    private var database: OpaquePointer?
    private var root: URL?
    private var rootDescriptor: Int32 = -1
    private var assetsDescriptor: Int32 = -1
    private let directoryOverride: URL?
    private let enablesTrigram: Bool
    private var hasTrigram = false
    private var cachedStats: StorageStats?
    private let logger = Logger(subsystem: "local.helele.cvmaster", category: "storage")
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// 可注入独立目录并关闭可选索引，供隔离回归测试；默认仍只使用应用目录。
    init(directory: URL? = nil, enablesTrigram: Bool = true) {
        directoryOverride = directory
        self.enablesTrigram = enablesTrigram
    }

    isolated deinit {
        sqlite3_close(database)
        if assetsDescriptor >= 0 { Darwin.close(assetsDescriptor) }
        if rootDescriptor >= 0 { Darwin.close(rootDescriptor) }
    }

    /// 首次初始化后复用连接；不回退到临时库，不跟随应用目录、数据库或边车符号链接。
    func prepare() throws {
        if database != nil {
            try verifyDirectories()
            try secureDatabaseFile("history.sqlite")
            try hardenSidecars()
            return
        }
        do {
            let directory = try StoragePaths.applicationDirectory(directory: directoryOverride)
            rootDescriptor = StoragePaths.retryOnInterrupt { Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            try StoragePaths.secureDirectory(rootDescriptor)
            if StoragePaths.retryOnInterrupt({ mkdirat(rootDescriptor, "assets", 0o700) }) != 0, errno != EEXIST { throw LibraryError.storage }
            assetsDescriptor = StoragePaths.retryOnInterrupt { openat(rootDescriptor, "assets", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            try StoragePaths.secureDirectory(assetsDescriptor)
            // 在 SQLite 打开前创建 0600 普通文件，避免先暴露内容再 chmod 的时间窗口。
            try secureDatabaseFile("history.sqlite", create: true)
            try hardenSidecars()
            let file = directory.appendingPathComponent("history.sqlite")
            var connection: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
            guard sqlite3_open_v2(file.path, &connection, flags, nil) == SQLITE_OK else {
                sqlite3_close(connection)
                throw LibraryError.storage
            }
            database = connection
            root = directory
            sqlite3_busy_timeout(connection, 1500)
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA journal_mode=WAL")
            try hardenSidecars()
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA cache_size=-2048")
            try execute("PRAGMA journal_size_limit=4194304")
            let version = try scalar("PRAGMA user_version")
            guard version <= 4 else { throw LibraryError.storage }
            try execute("""
                CREATE TABLE IF NOT EXISTS entry(
                    id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
                    title TEXT NOT NULL, excerpt TEXT NOT NULL, search_text TEXT NOT NULL,
                    source TEXT NOT NULL, copied_at REAL NOT NULL, byte_size INTEGER NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0, copies INTEGER NOT NULL DEFAULT 1);
                CREATE INDEX IF NOT EXISTS entry_order ON entry(pinned DESC,copied_at DESC,id);
                CREATE TABLE IF NOT EXISTS user_group(
                    id TEXT PRIMARY KEY,name TEXT NOT NULL COLLATE NOCASE UNIQUE,color INTEGER NOT NULL,position INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS entry_group(
                    entry_id TEXT NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
                    group_id TEXT NOT NULL REFERENCES user_group(id) ON DELETE CASCADE,
                    PRIMARY KEY(entry_id,group_id));
                CREATE INDEX IF NOT EXISTS group_entries ON entry_group(group_id,entry_id);
                CREATE TABLE IF NOT EXISTS representation(
                    id TEXT PRIMARY KEY,entry_id TEXT NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
                    item_order INTEGER NOT NULL,uti TEXT NOT NULL,filename TEXT NOT NULL UNIQUE,byte_size INTEGER NOT NULL);
                CREATE INDEX IF NOT EXISTS representation_entry ON representation(entry_id,item_order);
                CREATE TABLE IF NOT EXISTS search_meta(id INTEGER PRIMARY KEY CHECK(id=1),dirty INTEGER NOT NULL);
                INSERT OR IGNORE INTO search_meta(id,dirty) VALUES(1,1);
                """)
            try transaction {
                if version < 2 {
                    try execute("ALTER TABLE entry ADD COLUMN source_bundle_id TEXT NOT NULL DEFAULT ''")
                }
                if version < 3 { try reclassifyImageFiles() }
                if version < 4 {
                    // 显示文案不再是持久化键；未知类型保留原值，读取时安全回退为文本。
                    for kind in ClipKind.allCases {
                        try execute("UPDATE entry SET kind=? WHERE kind=?", [.text(kind.storageValue), .text(kind.rawValue)])
                    }
                }
                try execute("PRAGMA user_version=4")
            }
            try configureSearch()
            try recoverAssets()
            logger.info("Local storage ready; schema version 4")
        } catch {
            sqlite3_close(database)
            database = nil
            root = nil
            hasTrigram = false
            if assetsDescriptor >= 0 { Darwin.close(assetsDescriptor); assetsDescriptor = -1 }
            if rootDescriptor >= 0 { Darwin.close(rootDescriptor); rootDescriptor = -1 }
            logger.error("Local storage initialization failed")
            throw LibraryError.storage
        }
    }

    /// 拒绝准备后 root/assets 被替换为其他 inode；资产 I/O 仍相对已打开描述符执行。
    private func verifyDirectories() throws {
        guard let root else { throw LibraryError.storage }
        var openedRoot = stat(), pathRoot = stat(), openedAssets = stat(), pathAssets = stat()
        guard fstat(rootDescriptor, &openedRoot) == 0, lstat(root.path, &pathRoot) == 0,
              (pathRoot.st_mode & S_IFMT) == S_IFDIR,
              StoragePaths.sameIdentity(openedRoot, pathRoot),
              fstat(assetsDescriptor, &openedAssets) == 0,
              fstatat(rootDescriptor, "assets", &pathAssets, AT_SYMLINK_NOFOLLOW) == 0,
              (pathAssets.st_mode & S_IFMT) == S_IFDIR,
              StoragePaths.sameIdentity(openedAssets, pathAssets) else {
            throw LibraryError.storage
        }
        try StoragePaths.secureDirectory(rootDescriptor)
        try StoragePaths.secureDirectory(assetsDescriptor)
    }

    private func secureDatabaseFile(_ name: String, create: Bool = false) throws {
        let descriptor = openat(rootDescriptor, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
        if descriptor < 0, !create, errno == ENOENT { return }
        guard descriptor >= 0 else { throw LibraryError.storage }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0 else { throw LibraryError.storage }
    }

    private func hardenSidecars() throws {
        try secureDatabaseFile("history.sqlite-wal")
        try secureDatabaseFile("history.sqlite-shm")
        try secureDatabaseFile("history.sqlite-journal")
    }

    /// 索引是可重建的优化，不是历史库可用性的前提；不支持 FTS5/trigram 时继续 LIKE。
    private func configureSearch() throws {
        var supported = false
        if enablesTrigram {
            do {
                try execute("CREATE VIRTUAL TABLE temp.trigram_probe USING fts5(value,tokenize='trigram',detail=full)")
                try execute("DROP TABLE temp.trigram_probe")
                supported = true
            } catch {
                try? execute("DROP TABLE IF EXISTS temp.trigram_probe")
            }
        }
        if supported {
            do {
                try transaction {
                    let existed = try scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='entry_search'") > 0
                    let triggers = try scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('entry_search_ai','entry_search_ad','entry_search_au')")
                    let dirty = try scalar("SELECT dirty FROM search_meta WHERE id=1") != 0
                    try dropSearchTriggers()
                    try execute("CREATE VIRTUAL TABLE IF NOT EXISTS entry_search USING fts5(search_text,content='entry',content_rowid='rowid',tokenize='trigram',detail=full)")
                    if !existed || dirty || triggers != 3 { try execute("INSERT INTO entry_search(entry_search) VALUES('rebuild')") }
                    try execute("""
                        CREATE TRIGGER entry_search_ai AFTER INSERT ON entry BEGIN
                            INSERT INTO entry_search(rowid,search_text) VALUES(new.rowid,new.search_text); END;
                        CREATE TRIGGER entry_search_ad AFTER DELETE ON entry BEGIN
                            INSERT INTO entry_search(entry_search,rowid,search_text) VALUES('delete',old.rowid,old.search_text); END;
                        CREATE TRIGGER entry_search_au AFTER UPDATE OF search_text ON entry BEGIN
                            INSERT INTO entry_search(entry_search,rowid,search_text) VALUES('delete',old.rowid,old.search_text);
                            INSERT INTO entry_search(rowid,search_text) VALUES(new.rowid,new.search_text); END;
                        UPDATE search_meta SET dirty=0 WHERE id=1;
                        """)
                }
                hasTrigram = true
                return
            } catch {
                logger.warning("Optional search index unavailable; using exact substring scan")
            }
        }
        // 能力缺失期间不让旧 FTS 触发器破坏写入，并记录下次支持时必须重建。
        try transaction {
            try dropSearchTriggers()
            try execute("""
                UPDATE search_meta SET dirty=1 WHERE id=1;
                CREATE TRIGGER entry_search_ai AFTER INSERT ON entry BEGIN UPDATE search_meta SET dirty=1 WHERE id=1; END;
                CREATE TRIGGER entry_search_ad AFTER DELETE ON entry BEGIN UPDATE search_meta SET dirty=1 WHERE id=1; END;
                CREATE TRIGGER entry_search_au AFTER UPDATE OF search_text ON entry BEGIN UPDATE search_meta SET dirty=1 WHERE id=1; END;
                """)
        }
        hasTrigram = false
    }

    private func dropSearchTriggers() throws {
        try execute("""
            DROP TRIGGER IF EXISTS entry_search_ai;
            DROP TRIGGER IF EXISTS entry_search_ad;
            DROP TRIGGER IF EXISTS entry_search_au;
            """)
    }

    /// 仅扫描文件名元数据；迁移时同时接受旧显示键与稳定键，不修改原始表示。
    private func reclassifyImageFiles() throws {
        let query = try statement("""
            SELECT e.id,e.title,e.excerpt,COUNT(DISTINCT r.item_order)
            FROM entry e JOIN representation r ON r.entry_id=e.id AND r.uti='public.file-url'
            WHERE e.kind IN (?,?) GROUP BY e.id
            """, [.text(ClipKind.file.rawValue), .text(ClipKind.file.storageValue)])
        defer { sqlite3_finalize(query) }
        var ids: [String] = []
        while try next(query) {
            let count = Int(sqlite3_column_int(query, 3))
            let names = text(query, 2).split(separator: "\n").map(String.init)
            let candidates = count == 1 ? [text(query, 1)] : names
            if candidates.count == count, ClipboardFormats.areImageFiles(candidates) { ids.append(text(query, 0)) }
        }
        for id in ids { try execute("UPDATE entry SET kind=? WHERE id=?", [.text(ClipKind.image.storageValue), .text(id)]) }
    }

    /// 所有修改事务内不检查任务取消：开始后必须完整提交或回滚。
    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        if values.isEmpty && sql.contains(";") {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw LibraryError.storage }
            return
        }
        let prepared = try statement(sql, values)
        defer { sqlite3_finalize(prepared) }
        // PRAGMA 可能返回一行；必须继续到 DONE，不能把后续错误当作成功。
        while try next(prepared) { }
    }

    private func statement(_ sql: String, _ values: [SQLValue] = []) throws -> OpaquePointer {
        guard let database else { throw LibraryError.storage }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            sqlite3_finalize(prepared)
            throw LibraryError.storage
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let value): result = sqlite3_bind_text(prepared, index, value, Int32(value.utf8.count), transient)
            case .integer(let value): result = sqlite3_bind_int64(prepared, index, Int64(value))
            case .real(let value): result = sqlite3_bind_double(prepared, index, value)
            }
            if result != SQLITE_OK { sqlite3_finalize(prepared); throw LibraryError.storage }
        }
        return prepared
    }

    /// 任何 SQLite 错误都向上传递，尤其不能让不完整的资产引用扫描触发误删。
    private func next(_ query: OpaquePointer) throws -> Bool {
        let status = sqlite3_step(query)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw LibraryError.storage }
        return status == SQLITE_ROW
    }

    private func scalar(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        let query = try statement(sql, values)
        defer { sqlite3_finalize(query) }
        guard try next(query) else { throw LibraryError.storage }
        let value = Int(sqlite3_column_int64(query, 0))
        guard try !next(query) else { throw LibraryError.storage }
        return value
    }

    private func text(_ query: OpaquePointer, _ column: Int32, maximumBytes: Int = StorageLimits.searchableBytes,
                      maximumCharacters: Int? = nil, rejectOversized: Bool = false) -> String {
        guard let value = sqlite3_column_text(query, column) else { return "" }
        let count = Int(sqlite3_column_bytes(query, column))
        if rejectOversized {
            guard count <= maximumBytes else { return "" }
            // 身份字段不可截成另一个值；有界原始字节必须完整且合法，损坏身份直接置空。
            return String(bytes: UnsafeBufferPointer(start: value, count: count), encoding: .utf8) ?? ""
        }
        return BoundedText.decode(UnsafeBufferPointer(start: value, count: count),
                                  maximumBytes: maximumBytes, maximumCharacters: maximumCharacters)
    }

    /// 3 个及以上码点使用 trigram 候选，仍以转义 LIKE 精确复核；短查询保持子串扫描。
    /// 取消只能在语句之间 / 行之间生效，不承诺中断正在运行的 sqlite3_step。
    func page(query: String, scope: String, kind: ClipKind?, interval: DateInterval?, limit: Int) throws -> HistoryPage {
        try Task.checkCancellation()
        try prepare()
        try Task.checkCancellation()
        var clauses = ["1=1"]
        var values: [SQLValue] = []
        if scope == "pinned" { clauses.append("e.pinned=1") }
        else if let id = UUID(uuidString: scope) {
            clauses.append("EXISTS(SELECT 1 FROM entry_group eg WHERE eg.entry_id=e.id AND eg.group_id=?)")
            values.append(.text(id.uuidString))
        }
        if let kind { clauses.append("e.kind=?"); values.append(.text(kind.storageValue)) }
        if let interval {
            clauses.append("e.copied_at>=? AND e.copied_at<?")
            values += [.real(interval.start.timeIntervalSince1970), .real(interval.end.timeIntervalSince1970)]
        }
        let term = MetadataBounds.query(query)
        if !term.isEmpty {
            let escaped = term.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            if hasTrigram, term.unicodeScalars.count >= 3, !term.contains("\0") {
                clauses.append("e.rowid IN (SELECT rowid FROM entry_search WHERE entry_search MATCH ?)")
                values.append(.text("\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""))
            }
            clauses.append("e.kind IN (?,?,?) AND e.search_text LIKE ? ESCAPE '\\'")
            values += [.text(ClipKind.text.storageValue), .text(ClipKind.link.storageValue), .text(ClipKind.file.storageValue), .text("%\(escaped)%")]
        }
        let filter = clauses.joined(separator: " AND ")
        let count = try scalar("SELECT COUNT(*) FROM entry e WHERE \(filter)", values)
        try Task.checkCancellation()
        var clips: [Clip] = []
        // 不使用 COUNT OVER 强制完成全体排序；无结果时也必须保留独立全库统计。
        if count > 0 {
            let queryStatement = try statement("""
                SELECT e.id,e.kind,e.title,e.excerpt,e.source,e.copied_at,e.byte_size,e.pinned,e.copies,e.source_bundle_id,
                    EXISTS(SELECT 1 FROM representation r WHERE r.entry_id=e.id AND r.uti='public.file-url')
                FROM entry e WHERE \(filter) ORDER BY e.pinned DESC,e.copied_at DESC,e.id LIMIT ?
                """, values + [.integer(min(max(limit, 1), StorageLimits.maximumLoaded))])
            defer { sqlite3_finalize(queryStatement) }
            while try next(queryStatement) {
                try Task.checkCancellation()
                guard let id = UUID(uuidString: text(queryStatement, 0, maximumBytes: 36, rejectOversized: true)) else { throw LibraryError.storage }
                clips.append(Clip(id: id, kind: ClipKind.fromStorageValue(text(queryStatement, 1, maximumBytes: 32)),
                    title: text(queryStatement, 2, maximumBytes: StorageLimits.titleBytes, maximumCharacters: StorageLimits.titleCharacters),
                    source: text(queryStatement, 4, maximumBytes: StorageLimits.sourceBytes),
                    sourceBundleID: text(queryStatement, 9, maximumBytes: StorageLimits.sourceBundleIDBytes, rejectOversized: true),
                    copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(queryStatement, 5)),
                    byteSize: Int(sqlite3_column_int64(queryStatement, 6)), pinned: sqlite3_column_int(queryStatement, 7) != 0,
                    groups: [], copies: Int(sqlite3_column_int(queryStatement, 8)),
                    excerpt: text(queryStatement, 3, maximumBytes: StorageLimits.excerptBytes, maximumCharacters: StorageLimits.excerptCharacters),
                    hasFileReference: sqlite3_column_int(queryStatement, 10) != 0))
            }
        }
        try Task.checkCancellation()
        // 只为当前最多 300 条取关联，一条有界查询替代每行一个 SELECT。
        if !clips.isEmpty {
            let placeholders = Array(repeating: "?", count: clips.count).joined(separator: ",")
            let relations = try statement("SELECT entry_id,group_id FROM entry_group WHERE entry_id IN (\(placeholders))",
                clips.map { .text($0.id.uuidString) })
            defer { sqlite3_finalize(relations) }
            var groups: [UUID: Set<UUID>] = [:]
            while try next(relations) {
                try Task.checkCancellation()
                guard let id = UUID(uuidString: text(relations, 0)), let group = UUID(uuidString: text(relations, 1)) else { throw LibraryError.storage }
                groups[id, default: []].insert(group)
            }
            clips = clips.map { clip in
                Clip(id: clip.id, kind: clip.kind, title: clip.title, source: clip.source, sourceBundleID: clip.sourceBundleID,
                    copiedAt: clip.copiedAt, byteSize: clip.byteSize, pinned: clip.pinned, groups: groups[clip.id] ?? [],
                    copies: clip.copies, excerpt: clip.excerpt, hasFileReference: clip.hasFileReference)
            }
        }
        try Task.checkCancellation()
        let stats = try storageStats()
        return HistoryPage(clips: clips, total: count, storedEntries: stats.entries, storedBytes: stats.bytes)
    }

    /// 容量只在内容变更后重算；分组、置顶及普通搜索不重复扫描 SUM。
    func storageStats() throws -> StorageStats {
        try prepare()
        if let cachedStats { return cachedStats }
        let query = try statement("SELECT COUNT(*),COALESCE(SUM(byte_size),0) FROM entry")
        defer { sqlite3_finalize(query) }
        guard try next(query) else { throw LibraryError.storage }
        let stats = StorageStats(entries: Int(sqlite3_column_int64(query, 0)), bytes: Int(sqlite3_column_int64(query, 1)))
        guard try !next(query) else { throw LibraryError.storage }
        cachedStats = stats
        return stats
    }

    func groupCatalog() throws -> [ClipGroup] {
        try prepare()
        return try readGroups()
    }

    private func readGroups() throws -> [ClipGroup] {
        let query = try statement("SELECT id,name,color FROM user_group ORDER BY position,id")
        defer { sqlite3_finalize(query) }
        var groups: [ClipGroup] = []
        while try next(query) {
            guard let id = UUID(uuidString: text(query, 0)) else { throw LibraryError.storage }
            groups.append(ClipGroup(id: id,
                name: text(query, 1, maximumBytes: StorageLimits.groupNameBytes, maximumCharacters: StorageLimits.groupNameCharacters),
                colorIndex: Int(sqlite3_column_int(query, 2))))
        }
        return groups
    }

    /// 摘要 / 搜索允许有界回退；不改变原始表示，也不在主线程解析 RTF。
    private func readableCapture(_ capture: ClipCapture) -> ClipCapture {
        guard capture.kind == .text, capture.searchText.isEmpty else { return capture }
        var remaining = ClipboardFormats.maximumRichTextPreviewBytes
        var output = BoundedText.Builder()
        for part in capture.representations where part.type == "public.rtf" {
            guard !output.isFull, part.data.count <= remaining else { break }
            remaining -= part.data.count
            if let value = ClipboardFormats.richText(part.data) { output.append(value) }
        }
        let value = output.value
        guard !value.isEmpty else { return capture }
        return MetadataBounds.normalize(ClipCapture(kind: capture.kind,
            title: String(value.split(maxSplits: 1, whereSeparator: \.isNewline).first ?? "富文本内容"),
            excerpt: value, searchText: value, source: capture.source,
            sourceBundleID: capture.sourceBundleID, representations: capture.representations))
    }

    /// 清理与入库共享一个事务；失败不删除旧元数据 / 资产，提交后才 unlink 被回收的文件。
    /// 重复采集同样执行保留期清理，先更新时间以保留刚复制的那条记录。
    func save(_ original: ClipCapture, retention: Int) throws {
        try prepare()
        guard !original.representations.isEmpty, original.representations.count <= StorageLimits.maximumRepresentations,
              original.representations.allSatisfy({ $0.data.count <= StorageLimits.maximumRepresentationBytes }) else { throw LibraryError.unsupported }
        let bytes = original.representations.reduce(0) { $0 + $1.data.count }
        guard bytes <= StorageLimits.maximumCaptureBytes else { throw LibraryError.unsupported }
        let capture = readableCapture(MetadataBounds.normalize(original))
        var hasher = SHA256()
        for representation in capture.representations {
            hasher.update(data: Data("\(representation.item):\(representation.type):\(representation.data.count):".utf8))
            hasher.update(data: representation.data)
        }
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        var written: [String] = []
        var removed: [String] = []
        var prunedIDs: [UUID] = []
        do {
            try hardenSidecars()
            try transaction {
                let duplicate = try scalar("SELECT COUNT(*) FROM entry WHERE fingerprint=?", [.text(fingerprint)]) > 0
                if duplicate {
                    try execute("UPDATE entry SET copied_at=?,copies=copies+1,source=?,source_bundle_id=? WHERE fingerprint=?",
                        [.real(Date().timeIntervalSince1970), .text(capture.source), .text(capture.sourceBundleID), .text(fingerprint)])
                    // 仅修复发生变化的派生元数据；普通重复复制不触发 search_text 的 FTS 重建写入。
                    try execute("""
                        UPDATE entry SET title=?,excerpt=?,search_text=? WHERE fingerprint=?
                            AND (title<>? OR excerpt<>? OR search_text<>?)
                        """, [.text(capture.title), .text(capture.excerpt), .text(capture.searchText), .text(fingerprint),
                              .text(capture.title), .text(capture.excerpt), .text(capture.searchText)])
                }
                let pruned = try prune(retention: retention, incoming: duplicate ? 0 : bytes, addingEntry: !duplicate)
                removed = pruned.filenames
                prunedIDs = pruned.ids
                if !duplicate {
                    let id = UUID().uuidString
                    try execute("INSERT INTO entry(id,fingerprint,kind,title,excerpt,search_text,source,source_bundle_id,copied_at,byte_size) VALUES(?,?,?,?,?,?,?,?,?,?)",
                        [.text(id), .text(fingerprint), .text(capture.kind.storageValue), .text(capture.title), .text(capture.excerpt),
                         .text(capture.searchText), .text(capture.source), .text(capture.sourceBundleID),
                         .real(Date().timeIntervalSince1970), .integer(bytes)])
                    for representation in capture.representations {
                        let name = UUID().uuidString
                        try writeAsset(representation.data, name: name)
                        written.append(name)
                        try execute("INSERT INTO representation(id,entry_id,item_order,uti,filename,byte_size) VALUES(?,?,?,?,?,?)",
                            [.text(name), .text(id), .integer(representation.item), .text(representation.type), .text(name), .integer(representation.data.count)])
                    }
                }
            }
        } catch {
            unlinkAssets(written)
            logger.error("Capture transaction failed; new assets rolled back")
            throw error
        }
        cachedStats = nil
        for id in prunedIDs { invalidateThumbnail(id) }
        unlinkAssets(removed)
    }

    /// 一次聚合容量，最多 256 个一批读取 / 删除；始终保留置顶与已分组记录。
    private func prune(retention: Int, incoming: Int, addingEntry: Bool) throws -> (ids: [UUID], filenames: [String]) {
        let query = try statement("""
            SELECT COUNT(*),COALESCE(SUM(byte_size),0),
                COALESCE(SUM(CASE WHEN pinned=1 OR EXISTS(SELECT 1 FROM entry_group WHERE entry_id=entry.id) THEN 1 ELSE 0 END),0),
                COALESCE(SUM(CASE WHEN pinned=1 OR EXISTS(SELECT 1 FROM entry_group WHERE entry_id=entry.id) THEN byte_size ELSE 0 END),0)
            FROM entry
            """)
        var count: Int
        var bytes: Int
        do {
            defer { sqlite3_finalize(query) }
            guard try next(query) else { throw LibraryError.storage }
            count = Int(sqlite3_column_int64(query, 0))
            bytes = Int(sqlite3_column_int64(query, 1))
            let protectedCount = Int(sqlite3_column_int64(query, 2))
            let protectedBytes = Int(sqlite3_column_int64(query, 3))
            guard protectedCount + (addingEntry ? 1 : 0) <= StorageLimits.maximumEntries,
                  protectedBytes <= StorageLimits.maximumBytes - incoming else { throw LibraryError.capacity }
            guard try !next(query) else { throw LibraryError.storage }
        }
        let cutoff = retention > 0 ? Date().addingTimeInterval(-Double(retention) * 86_400).timeIntervalSince1970 : -Double.greatestFiniteMagnitude
        func overBudget() -> Bool { count + (addingEntry ? 1 : 0) > StorageLimits.maximumEntries || bytes > StorageLimits.maximumBytes - incoming }
        var ids: [UUID] = []
        var filenames: [String] = []
        while true {
            let candidates = try statement("""
                SELECT id,byte_size,copied_at FROM entry
                WHERE pinned=0 AND NOT EXISTS(SELECT 1 FROM entry_group WHERE entry_id=entry.id)
                    AND (?=1 OR copied_at<?) ORDER BY copied_at,id LIMIT 256
                """, [.integer(overBudget() ? 1 : 0), .real(cutoff)])
            var batch: [UUID] = []
            do {
                defer { sqlite3_finalize(candidates) }
                while try next(candidates) {
                    guard let id = UUID(uuidString: text(candidates, 0)) else { throw LibraryError.storage }
                    if overBudget() || sqlite3_column_double(candidates, 2) < cutoff {
                        let size = Int(sqlite3_column_int64(candidates, 1))
                        guard size >= 0 else { throw LibraryError.storage }
                        batch.append(id)
                        count -= 1
                        bytes -= size
                    }
                }
            }
            guard !batch.isEmpty else { break }
            filenames += try assetNames(for: batch)
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            try execute("DELETE FROM entry WHERE id IN (\(placeholders))", batch.map { .text($0.uuidString) })
            ids += batch
        }
        guard !overBudget() else { throw LibraryError.capacity }
        return (ids, filenames)
    }

    private func assetNames(for ids: [UUID]) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let query = try statement("SELECT filename FROM representation WHERE entry_id IN (\(placeholders))", ids.map { .text($0.uuidString) })
        defer { sqlite3_finalize(query) }
        var names: [String] = []
        while try next(query) {
            let name = text(query, 0)
            guard UUID(uuidString: name) != nil else { throw LibraryError.storage }
            names.append(name)
        }
        return names
    }

    func delete(_ id: UUID) throws {
        try prepare()
        let names = try transaction {
            let names = try assetNames(for: [id])
            try execute("DELETE FROM entry WHERE id=?", [.text(id.uuidString)])
            return names
        }
        cachedStats = nil
        invalidateThumbnail(id)
        unlinkAssets(names)
    }

    /// 删除提交是成功边界；资产回收 / checkpoint 失败不伪装成删除回滚。
    /// 不自动 VACUUM：空闲页留待复用，不保证文件缩小或安全擦除已删除正文。
    @discardableResult
    func clear() throws -> Int { try clearEntries(before: nil) }

    @discardableResult
    func clear(before cutoff: Date) throws -> Int { try clearEntries(before: cutoff) }

    private func clearEntries(before cutoff: Date?) throws -> Int {
        try prepare()
        let values: [SQLValue] = cutoff.map { [.real($0.timeIntervalSince1970)] } ?? []
        let filter = cutoff == nil ? "" : " WHERE copied_at<?"
        let removed = try transaction {
            let count = try scalar("SELECT COUNT(*) FROM entry\(filter)", values)
            try execute("DELETE FROM entry\(filter)", values)
            return count
        }
        cachedStats = nil
        thumbnailGeneration &+= 1
        thumbnails.removeAll()
        thumbnailOrder.removeAll()
        thumbnailBytes = 0
        finishCleanup()
        return removed
    }

    private func finishCleanup() {
        do { try recoverAssets() } catch { logger.warning("Committed deletion; asset maintenance deferred") }
        do { try execute("PRAGMA wal_checkpoint(TRUNCATE)") } catch { logger.warning("Committed deletion; checkpoint deferred") }
    }

    func setPinned(_ id: UUID, _ pinned: Bool) throws {
        try prepare()
        try execute("UPDATE entry SET pinned=? WHERE id=?", [.integer(pinned ? 1 : 0), .text(id.uuidString)])
    }

    func setGroup(_ entry: UUID, group: UUID, included: Bool) throws {
        try prepare()
        if included {
            try execute("INSERT OR IGNORE INTO entry_group(entry_id,group_id) VALUES(?,?)", [.text(entry.uuidString), .text(group.uuidString)])
        } else {
            try execute("DELETE FROM entry_group WHERE entry_id=? AND group_id=?", [.text(entry.uuidString), .text(group.uuidString)])
        }
    }

    func saveGroup(_ id: UUID?, name: String) throws {
        try prepare()
        guard let trimmed = MetadataBounds.normalizedGroupName(name) else { throw LibraryError.nameConflict }
        try transaction {
            let groups = try readGroups()
            if let id, !groups.contains(where: { $0.id == id }) { throw LibraryError.missingGroup }
            guard groups.count < 100 || id != nil,
                  !groups.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else { throw LibraryError.nameConflict }
            if let id {
                try execute("UPDATE user_group SET name=? WHERE id=?", [.text(trimmed), .text(id.uuidString)])
            } else {
                let position = try scalar("SELECT COALESCE(MAX(position),-1)+1 FROM user_group")
                try execute("INSERT INTO user_group(id,name,color,position) VALUES(?,?,?,?)",
                    [.text(UUID().uuidString), .text(trimmed), .integer(groups.count % 4), .integer(position)])
            }
        }
    }

    /// 外键仅解除此分组的归属，不删除历史、原始表示或引用文件，也不触发保留期清理。
    func deleteGroup(_ id: UUID) throws {
        try prepare()
        try transaction {
            try execute("DELETE FROM user_group WHERE id=?", [.text(id.uuidString)])
        }
    }

    /// 以事务中的最新目录计算相邻位置，不接收可能过期的 UI 索引或完整目录快照。
    func moveGroup(_ id: UUID, offset: Int) throws {
        try prepare()
        guard offset == -1 || offset == 1 else { throw LibraryError.storage }
        try transaction {
            var groups = try readGroups()
            guard let index = groups.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingGroup }
            let destination = index + offset
            guard groups.indices.contains(destination) else { return }
            groups.swapAt(index, destination)
            for (position, group) in groups.enumerated() {
                try execute("UPDATE user_group SET position=? WHERE id=?", [.integer(position), .text(group.id.uuidString)])
            }
        }
    }

    /// SQLite 语句和保存资产先完整读取并关闭，再挂起检查外部文件；删除代数拒绝过期复制。
    func representations(_ id: UUID) async throws -> [ClipRepresentation] {
        try Task.checkCancellation()
        try prepare()
        let generation = thumbnailGeneration
        let originals = try savedRepresentations(id)
        var references: [URL] = []
        for representation in originals where representation.type == "public.file-url" {
            guard let value = String(data: representation.data, encoding: .utf8), let url = URL(string: value), url.isFileURL else {
                throw LibraryError.unavailableFile
            }
            references.append(url)
        }
        let available = await FileAvailability.shared.check(references)
        try Task.checkCancellation()
        guard generation == thumbnailGeneration else { throw LibraryError.missingContent }
        guard available else { throw LibraryError.unavailableFile }
        return originals
    }

    /// fd 相对读取，不跟随符号链接；函数返回前 finalize，不跨 await 保留 SQLite 指针。
    private func savedRepresentations(_ id: UUID) throws -> [ClipRepresentation] {
        let query = try statement("SELECT item_order,uti,filename,byte_size FROM representation WHERE entry_id=? ORDER BY item_order,id", [.text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        var result: [ClipRepresentation] = []
        var size = 0
        while try next(query) {
            let expected = Int(sqlite3_column_int64(query, 3))
            guard expected >= 0, expected <= StorageLimits.maximumRepresentationBytes,
                  size <= StorageLimits.maximumCaptureBytes - expected,
                  result.count < StorageLimits.maximumRepresentations else { throw LibraryError.missingContent }
            size += expected
            let data = try assetData(text(query, 2), maximum: expected, expectedSize: expected)
            let type = text(query, 1)
            result.append(ClipRepresentation(item: Int(sqlite3_column_int(query, 0)), type: type, data: data))
        }
        guard !result.isEmpty else { throw LibraryError.missingContent }
        return result
    }

    /// 原始纯文本 / URL 优先；RTF 共享 256 KiB 解析预算，超限明确失败，绝不返回截断粘贴。
    func plainText(_ id: UUID, kind: ClipKind) async throws -> [ClipRepresentation] {
        guard kind == .text || kind == .link else { throw LibraryError.unsupported }
        let originals = try await representations(id)
        let indices = Set(originals.map(\.item)).sorted()
        var parts: [String] = []
        var bytes = 0
        var richTextBudget = ClipboardFormats.maximumRichTextPreviewBytes
        for index in indices {
            let items = originals.filter { $0.item == index }
            let types = kind == .link ? ["public.url", "public.utf8-plain-text"] : ["public.utf8-plain-text", "public.url"]
            var value: String?
            for type in types {
                if let item = items.first(where: { $0.type == type }), let text = String(data: item.data, encoding: .utf8) {
                    value = text
                    break
                }
            }
            if value == nil, let rtf = items.first(where: { $0.type == "public.rtf" }) {
                guard rtf.data.count <= richTextBudget else { throw LibraryError.richTextTooLarge }
                richTextBudget -= rtf.data.count
                value = try NSAttributedString(data: rtf.data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
            }
            guard let value else { throw LibraryError.plainTextUnavailable }
            bytes += value.utf8.count + (parts.isEmpty ? 0 : 1)
            guard bytes <= StorageLimits.maximumCaptureBytes else { throw LibraryError.unsupported }
            parts.append(value)
        }
        let data = Data(parts.joined(separator: "\n").utf8)
        guard !data.isEmpty else { throw LibraryError.plainTextUnavailable }
        return [ClipRepresentation(item: 0, type: "public.utf8-plain-text", data: data)]
    }

    func markCopied(_ id: UUID) throws {
        try prepare()
        try execute("UPDATE entry SET copied_at=?,copies=copies+1 WHERE id=?", [.real(Date().timeIntervalSince1970), .text(id.uuidString)])
    }

    /// 整条详情共享 16 KB 文本 / 256 KiB RTF 预算；420px 与列表 640px 共用同一有界缓存。
    func preview(_ id: UUID) async throws -> ClipPreview {
        try Task.checkCancellation()
        try prepare()
        var preview = ""
        var textItems: Set<Int> = []
        var richTextBudget = ClipboardFormats.maximumRichTextPreviewBytes
        var truncated = false
        var storedThumbnail: URL?
        var referencedThumbnail: URL?
        let textBudget = 16_000
        do {
            let query = try statement("""
                SELECT uti,filename,item_order FROM representation WHERE entry_id=?
                ORDER BY item_order,CASE uti WHEN 'public.file-url' THEN 0
                    WHEN 'public.utf8-plain-text' THEN 1 WHEN 'public.url' THEN 2
                    WHEN 'public.rtf' THEN 3 ELSE 4 END,id
                """, [.text(id.uuidString)])
            defer { sqlite3_finalize(query) }
            while try next(query) {
                try Task.checkCancellation()
                let type = text(query, 0)
                let item = Int(sqlite3_column_int(query, 2))
                let name = text(query, 1)
                guard let url = assetURL(name) else { throw LibraryError.storage }
                if ClipboardFormats.rasterImages.contains(type) {
                    if storedThumbnail == nil { storedThumbnail = url }
                } else if type == "public.file-url", referencedThumbnail == nil { referencedThumbnail = url }
                if !textItems.contains(item) {
                    let separator = preview.isEmpty ? "" : "\n"
                    let remaining = textBudget - preview.utf8.count - separator.utf8.count
                    var value: String?
                    if type == "public.file-url" {
                        if let data = try? assetData(name, maximum: 16_385), data.count <= 16_384,
                           let raw = String(data: data, encoding: .utf8),
                           let reference = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), reference.isFileURL {
                            value = reference.lastPathComponent
                        }
                    } else if ["public.utf8-plain-text", "public.url"].contains(type) {
                        // 额外读取最多一个 scalar，不能把读取边界切断的有效 UTF-8 误判为损坏数据。
                        if let data = try? assetData(name, maximum: max(4, remaining + 4)), !data.isEmpty {
                            value = BoundedText.decode(data, maximumBytes: max(0, remaining))
                            if data.count > max(0, remaining) { truncated = true }
                        }
                    } else if type == "public.rtf", let data = try? assetData(name, maximum: richTextBudget + 1), data.count <= richTextBudget {
                        richTextBudget -= data.count
                        value = ClipboardFormats.richText(data, maximumBytes: max(4, remaining + 4), maximumCharacters: nil)
                        if let value, value.utf8.count > max(0, remaining) { truncated = true }
                    }
                    if let value, !value.isEmpty {
                        textItems.insert(item)
                        if remaining > 0 {
                            let bounded = BoundedText.prefix(value, maximumBytes: remaining)
                            preview += separator + bounded
                            if bounded != value { truncated = true }
                        } else { truncated = true }
                    }
                }
            }
        }
        try Task.checkCancellation()
        let generation = thumbnailGeneration
        let source = storedThumbnail.map(ThumbnailSource.stored) ?? referencedThumbnail.map(ThumbnailSource.referenced)
        let thumbnail = await requestedThumbnail(id, source: source, maximum: 420)
        try Task.checkCancellation()
        guard generation == thumbnailGeneration else { return ClipPreview(text: "", thumbnail: nil) }
        if truncated { preview += "\n…预览已截断，复制保留原始内容" }
        return ClipPreview(text: preview, thumbnail: thumbnail)
    }

    private struct ThumbnailKey: Hashable {
        let id: UUID
        let maximum: Int
    }

    /// 只缓存像素表示，不长期复用可能被外部应用替换的文件引用。
    private var thumbnails: [ThumbnailKey: Data] = [:]
    private var thumbnailOrder: [ThumbnailKey] = []
    private var thumbnailBytes = 0
    private var activeThumbnailRequests = 0
    /// 挂起期间发生删除 / 清空 / 自动回收时，拒绝旧解码结果重新写回缓存。
    private var thumbnailGeneration: UInt64 = 0

    private func invalidateThumbnail(_ id: UUID) {
        thumbnailGeneration &+= 1
        for key in thumbnailOrder where key.id == id {
            if let old = thumbnails.removeValue(forKey: key) { thumbnailBytes -= old.count }
        }
        thumbnailOrder.removeAll { $0.id == id }
    }

    func thumbnail(_ id: UUID) async throws -> Data? {
        try Task.checkCancellation()
        try prepare()
        let sources = try thumbnailSources(id)
        let source = sources.stored.map(ThumbnailSource.stored) ?? sources.referenced.map(ThumbnailSource.referenced)
        return await requestedThumbnail(id, source: source, maximum: 640)
    }

    /// 最多 12 个活跃等待者；只有 BUSY 重试两次，失败 / 超时不重试，不积累无限等待队列。
    private func requestedThumbnail(_ id: UUID, source: ThumbnailSource?, maximum: Int) async -> Data? {
        guard let source, !Task.isCancelled else { return nil }
        let usesReference: Bool
        if case .referenced = source { usesReference = true } else { usesReference = false }
        let key = ThumbnailKey(id: id, maximum: maximum)
        if !usesReference, let cached = thumbnails[key] { return cached }
        guard activeThumbnailRequests < 12 else { return nil }
        activeThumbnailRequests += 1
        defer { activeThumbnailRequests -= 1 }
        let generation = thumbnailGeneration
        for attempt in 0..<3 {
            guard !Task.isCancelled, generation == thumbnailGeneration else { return nil }
            let result = await ThumbnailPipeline.shared.thumbnailResult(source, maximum: maximum)
            guard !Task.isCancelled, generation == thumbnailGeneration else { return nil }
            switch result {
            case .unavailable: return nil
            case .busy:
                guard attempt < 2 else { return nil }
                do { try await Task.sleep(for: .milliseconds(attempt == 0 ? 80 : 160)) }
                catch { return nil }
            case .image(let data):
                guard data.count <= 2 * 1024 * 1024 else { return nil }
                if usesReference { return data }
                // 多个等待者不能重复添加顺序键 / 字节数。
                if let cached = thumbnails[key] { return cached }
                while !thumbnailOrder.isEmpty && (thumbnailOrder.count >= 24 || thumbnailBytes + data.count > 2 * 1024 * 1024) {
                    if let old = thumbnails.removeValue(forKey: thumbnailOrder.removeFirst()) { thumbnailBytes -= old.count }
                }
                thumbnails[key] = data
                thumbnailOrder.append(key)
                thumbnailBytes += data.count
                return data
            }
        }
        return nil
    }

    private func thumbnailSources(_ id: UUID) throws -> (stored: URL?, referenced: URL?) {
        let query = try statement("SELECT uti,filename FROM representation WHERE entry_id=? ORDER BY item_order,id", [.text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        var stored: URL?
        var referenced: URL?
        while try next(query) {
            try Task.checkCancellation()
            let type = text(query, 0)
            guard let url = assetURL(text(query, 1)) else { throw LibraryError.storage }
            if ClipboardFormats.rasterImages.contains(type) {
                if stored == nil { stored = url }
            } else if type == "public.file-url", referenced == nil { referenced = url }
        }
        return (stored, referenced)
    }

    private func assetURL(_ name: String) -> URL? {
        guard UUID(uuidString: name) != nil else { return nil }
        return root?.appendingPathComponent("assets/\(name)")
    }

    private func assetData(_ name: String, maximum: Int, expectedSize: Int? = nil) throws -> Data {
        guard UUID(uuidString: name) != nil, maximum >= 0 else { throw LibraryError.missingContent }
        let descriptor = openat(assetsDescriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw LibraryError.missingContent }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size >= 0 else { throw LibraryError.missingContent }
        if let expectedSize, info.st_size != Int64(expectedSize) { throw LibraryError.missingContent }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximum) ?? Data()
        if let expectedSize, data.count != expectedSize { throw LibraryError.missingContent }
        return data
    }

    /// UUID 独占创建、0600 起始权限；未提交文件不可见，失败只回收本次创建的文件。
    private func writeAsset(_ data: Data, name: String) throws {
        let descriptor = openat(assetsDescriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LibraryError.storage }
        defer { Darwin.close(descriptor) }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw LibraryError.storage }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw LibraryError.storage }
        } catch {
            unlinkat(assetsDescriptor, name, 0)
            throw error
        }
    }

    private func unlinkAssets(_ names: [String]) {
        for name in names where UUID(uuidString: name) != nil {
            if unlinkat(assetsDescriptor, name, 0) != 0, errno != ENOENT {
                logger.warning("Orphan asset removal deferred")
            }
        }
    }

    /// BEGIN IMMEDIATE 覆盖完整引用扫描和 unlink，阻止另一连接在扫描后提交新资产引用。
    /// 删除自身已先提交；维护失败仍由调用者记录延后，不伪装删除回滚。checkpoint 在事务外。
    func recoverAssets() throws {
        guard assetsDescriptor >= 0 else { throw LibraryError.storage }
        try transaction {
            let query = try statement("SELECT filename FROM representation")
            var referenced: Set<String> = []
            do {
                defer { sqlite3_finalize(query) }
                while try next(query) {
                    let name = text(query, 0, maximumBytes: 36, rejectOversized: true)
                    guard UUID(uuidString: name) != nil else { throw LibraryError.storage }
                    referenced.insert(name)
                }
            }
            let duplicate = dup(assetsDescriptor)
            guard duplicate >= 0 else { throw LibraryError.storage }
            guard let directory = fdopendir(duplicate) else { Darwin.close(duplicate); throw LibraryError.storage }
            defer { closedir(directory) }
            // dup 共享目录位置，每次扫描前重置，否则清空后的扫描可能从 EOF 开始。
            rewinddir(directory)
            while true {
                errno = 0
                guard let item = readdir(directory) else {
                    guard errno == 0 else { throw LibraryError.storage }
                    break
                }
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                guard UUID(uuidString: name) != nil else { continue }
                if !referenced.contains(name) { unlinkAssets([name]); continue }
                // 已有资产也收紧权限；不 chmod 链接、目录、其他所有者或多硬链接文件。
                let descriptor = openat(assetsDescriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                if descriptor < 0 { continue }
                var info = stat()
                let regular = fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
                if regular, info.st_uid == getuid(), info.st_nlink == 1 {
                    let status = fchmod(descriptor, 0o600)
                    Darwin.close(descriptor)
                    guard status == 0 else { throw LibraryError.storage }
                } else { Darwin.close(descriptor) }
            }
        }
    }
}
