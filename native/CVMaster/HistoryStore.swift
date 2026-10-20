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
import ImageIO
import UniformTypeIdentifiers
import OSLog

/// 只允许预定义绑定类型，不拼接用户提供的 SQL。
private enum SQLValue {
    case text(String), integer(Int), real(Double)
}

/// 缩略图来源：内置资产可直接解码，外部引用必须离开串行存储 actor 再读取。
private enum ThumbnailSource: Sendable {
    case stored(URL), referenced(URL)
}

/// 超时与正常失败分开，只有超时文件才在同一进程内跳过，避免反复创建阻塞读取。
private enum ThumbnailOutcome: Sendable {
    case finished(Data?), timedOut
}

/// 异常挂载点上的文件可能让系统调用永久阻塞；记录后本次运行不再重试同一资产。
private final class TimedOutThumbnailCache: @unchecked Sendable {
    static let shared = TimedOutThumbnailCache()
    private let lock = NSLock()
    private var paths: Set<String> = []

    func contains(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return paths.contains(path)
    }

    func insert(_ path: String) {
        lock.lock(); paths.insert(path); lock.unlock()
    }
}

/// 只允许第一个结果恢复等待者；卡死任务稍后完成时不会再次恢复。
private final class ThumbnailRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ThumbnailOutcome, Never>?

    init(_ continuation: CheckedContinuation<ThumbnailOutcome, Never>) {
        self.continuation = continuation
    }

    func finish(_ outcome: ThumbnailOutcome) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }
}

actor HistoryStore {
    /// 数据库连接仅由本 actor 访问，避免并发共享 SQLite 指针。
    private var database: OpaquePointer?
    /// 应用独占数据目录；nil 表示尚未成功初始化，不自动切换临时存储。
    private var root: URL?
    /// 元数据日志不记录正文、路径或 SQL 参数。
    private let logger = Logger(subsystem: "local.helele.cvmaster", category: "storage")
    /// SQLite 对绑定字符串进行复制，避免 Swift 临时缓冲区生命周期问题。
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// 首次初始化后复用一个连接；禁用同步联网、自动建种子或隐式覆盖旧库。
    func prepare() throws {
        guard database == nil else { return }
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true).appendingPathComponent("cvMaster", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var connection: OpaquePointer?
        let file = directory.appendingPathComponent("history.sqlite")
        guard sqlite3_open_v2(file.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            throw LibraryError.storage
        }
        database = connection
        root = directory
        do {
            sqlite3_busy_timeout(connection, 1500)
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA cache_size=-2048")
            try execute("PRAGMA journal_size_limit=4194304")
            let version = try scalar("PRAGMA user_version")
            guard version <= 3 else { throw LibraryError.storage }
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
                """)
            // v1 记录保留，空标识使用通用图标；迁移与版本号更新一起提交。
            if version < 2 {
                do {
                    try execute("BEGIN IMMEDIATE")
                    try execute("ALTER TABLE entry ADD COLUMN source_bundle_id TEXT NOT NULL DEFAULT ''")
                    try execute("PRAGMA user_version=2")
                    try execute("COMMIT")
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
            }
            // 旧文件记录只更新可见分类，不触碰资产、分组、置顶或复制表示。
            if version < 3 {
                do {
                    try execute("BEGIN IMMEDIATE")
                    try reclassifyImageFiles()
                    try execute("PRAGMA user_version=3")
                    try execute("COMMIT")
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try recoverAssets()
            logger.info("Local storage ready; schema version 3")
        } catch {
            sqlite3_close(database)
            database = nil
            root = nil
            logger.error("Local storage initialization failed")
            throw LibraryError.storage
        }
    }

    /// 仅扫描轻量文件名元数据，不读取原文件；不完整的多文件摘要保守保持文件分类。
    private func reclassifyImageFiles() throws {
        let query = try statement("""
            SELECT e.id,e.title,e.excerpt,COUNT(DISTINCT r.item_order)
            FROM entry e JOIN representation r ON r.entry_id=e.id AND r.uti='public.file-url'
            WHERE e.kind=? GROUP BY e.id
            """, [.text(ClipKind.file.rawValue)])
        defer { sqlite3_finalize(query) }
        var ids: [String] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw LibraryError.storage }
            let count = Int(sqlite3_column_int(query, 3))
            let names = text(query, 2).split(separator: "\n").map(String.init)
            let candidates = count == 1 ? [text(query, 1)] : names
            if candidates.count == count, ClipboardFormats.areImageFiles(candidates) {
                ids.append(text(query, 0))
            }
        }
        for id in ids { try execute("UPDATE entry SET kind=? WHERE id=?", [.text(ClipKind.image.rawValue), .text(id)]) }
    }

    /// 运行预定义 SQL，写入使用参数绑定；调用方负责事务边界。
    private func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        // Schema 初始化包含多个固定语句，不接收用户输入。
        if values.isEmpty && sql.contains(";") {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw LibraryError.storage }
            return
        }
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw LibraryError.storage }
    }

    /// 绑定所有用户输入；返回的语句必须由调用方 finalize。
    private func statement(_ sql: String, _ values: [SQLValue] = []) throws -> OpaquePointer {
        guard let database else { throw LibraryError.storage }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw LibraryError.storage }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(prepared, index, text, -1, transient)
            case .integer(let number): result = sqlite3_bind_int64(prepared, index, Int64(number))
            case .real(let number): result = sqlite3_bind_double(prepared, index, number)
            }
            if result != SQLITE_OK { sqlite3_finalize(prepared); throw LibraryError.storage }
        }
        return prepared
    }

    private func scalar(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        let query = try statement(sql, values)
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw LibraryError.storage }
        return Int(sqlite3_column_int64(query, 0))
    }

    private func text(_ query: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(query, column) else { return "" }
        return String(cString: value)
    }

    /// 所有筛选在磁盘查询层执行；LIMIT 控制投影量，不读取内容文件。
    /// 非空关键词仅匹配文本 / 链接内容或文件名称；图片不参与搜索，分组仅作为独立范围筛选。
    func page(query: String, scope: String, kind: ClipKind?, interval: DateInterval?, limit: Int) throws -> HistoryPage {
        try prepare()
        var clauses = ["1=1"]
        var values: [SQLValue] = []
        if scope == "pinned" { clauses.append("e.pinned=1") }
        else if let id = UUID(uuidString: scope) {
            clauses.append("EXISTS(SELECT 1 FROM entry_group eg WHERE eg.entry_id=e.id AND eg.group_id=?)")
            values.append(.text(id.uuidString))
        }
        if let kind { clauses.append("e.kind=?"); values.append(.text(kind.rawValue)) }
        // 参数绑定时间边界，在 LIMIT 前过滤全库，计数与分页使用相同条件。
        if let interval {
            clauses.append("e.copied_at>=? AND e.copied_at<?")
            values += [.real(interval.start.timeIntervalSince1970), .real(interval.end.timeIntervalSince1970)]
        }
        if !query.isEmpty {
            let escaped = String(query.prefix(256)).replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            // 按可见类型限制搜索，旧图片索引即使含文件名也不能命中，无需改写历史数据。
            // search_text 在文本 / 链接中保存内容，在文件中仅保存文件名，不检索分组名或路径。
            clauses.append("e.kind IN (?,?,?) AND e.search_text LIKE ? ESCAPE '\\'")
            values += [.text(ClipKind.text.rawValue), .text(ClipKind.link.rawValue), .text(ClipKind.file.rawValue), .text("%\(escaped)%")]
        }
        let filter = clauses.joined(separator: " AND ")
        let count = try scalar("SELECT COUNT(*) FROM entry e WHERE \(filter)", values)
        let queryStatement = try statement("SELECT e.id,e.kind,e.title,e.excerpt,e.source,e.copied_at,e.byte_size,e.pinned,e.copies,e.source_bundle_id,EXISTS(SELECT 1 FROM representation r WHERE r.entry_id=e.id AND r.uti='public.file-url') FROM entry e WHERE \(filter) ORDER BY e.pinned DESC,e.copied_at DESC,e.id LIMIT ?", values + [.integer(min(max(limit, 1), StorageLimits.maximumLoaded))])
        defer { sqlite3_finalize(queryStatement) }
        var clips: [Clip] = []
        while true {
            let status = sqlite3_step(queryStatement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let id = UUID(uuidString: text(queryStatement, 0)), let kind = ClipKind(rawValue: text(queryStatement, 1)) else { throw LibraryError.storage }
            let relations = try statement("SELECT group_id FROM entry_group WHERE entry_id=?", [.text(id.uuidString)])
            var groups: Set<UUID> = []
            while sqlite3_step(relations) == SQLITE_ROW { if let group = UUID(uuidString: text(relations, 0)) { groups.insert(group) } }
            sqlite3_finalize(relations)
            clips.append(Clip(id: id, kind: kind, title: text(queryStatement, 2), source: text(queryStatement, 4), sourceBundleID: text(queryStatement, 9),
                              copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(queryStatement, 5)),
                              byteSize: Int(sqlite3_column_int64(queryStatement, 6)), pinned: sqlite3_column_int(queryStatement, 7) != 0,
                              groups: groups, copies: Int(sqlite3_column_int(queryStatement, 8)), excerpt: text(queryStatement, 3), hasFileReference: sqlite3_column_int(queryStatement, 10) != 0))
        }
        let stats = try storageStats()
        return HistoryPage(clips: clips, total: count,
                           storedEntries: stats.entries, storedBytes: stats.bytes)
    }

    /// 读取全库条数和内容表示总字节；不受列表筛选影响，供设置页容量展示使用。
    func storageStats() throws -> StorageStats {
        try prepare()
        return StorageStats(entries: try scalar("SELECT COUNT(*) FROM entry"),
                            bytes: try scalar("SELECT COALESCE(SUM(byte_size),0) FROM entry"))
    }

    /// 独立读取完整分组目录，不依赖历史列表筛选、分页或搜索结果。
    func groupCatalog() throws -> [ClipGroup] {
        try prepare()
        return try readGroups()
    }

    private func readGroups() throws -> [ClipGroup] {
        let query = try statement("SELECT id,name,color FROM user_group ORDER BY position,id")
        defer { sqlite3_finalize(query) }
        var groups: [ClipGroup] = []
        while sqlite3_step(query) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(query, 0)) else { throw LibraryError.storage }
            groups.append(ClipGroup(id: id, name: text(query, 1), colorIndex: Int(sqlite3_column_int(query, 2))))
        }
        return groups
    }

    /// 对 RTF-only 内容补充有界摘要和搜索文本，HTML-only 不使用 WebKit 隐式渲染。
    private func readableCapture(_ capture: ClipCapture) -> ClipCapture {
        guard capture.kind == .text, capture.searchText.isEmpty else { return capture }
        let parts = capture.representations.filter { $0.type == "public.rtf" }
        var remaining = ClipboardFormats.maximumRichTextPreviewBytes
        var strings: [String] = []
        for part in parts {
            guard part.data.count <= remaining else { break }
            remaining -= part.data.count
            if let value = ClipboardFormats.richText(part.data) { strings.append(value) }
        }
        let text = String(strings.joined(separator: "\n").prefix(StorageLimits.searchableCharacters))
        guard !text.isEmpty else { return capture }
        let title = String(text.split(whereSeparator: \.isNewline).first?.prefix(120) ?? "富文本内容")
        return ClipCapture(kind: capture.kind, title: title, excerpt: String(text.prefix(240)), searchText: text,
                           source: capture.source, sourceBundleID: capture.sourceBundleID, representations: capture.representations)
    }

    /// 快照先写独立文件，再用事务发布；失败回收新文件，不破坏已有内容。
    func save(_ capture: ClipCapture, retention: Int) throws {
        try prepare()
        guard let root, !capture.representations.isEmpty else { throw LibraryError.storage }
        // 不在主线程解析富文本；仅补全缺少纯文本表示的 RTF 摘要，不修改原始表示。
        let capture = readableCapture(capture)
        let bytes = capture.representations.reduce(0) { $0 + $1.data.count }
        guard bytes <= StorageLimits.maximumCaptureBytes else { throw LibraryError.unsupported }
        var hasher = SHA256()
        // 类型、item 边界和长度参与指纹，避免不同表示的串联碰撞。
        for representation in capture.representations {
            hasher.update(data: Data("\(representation.item):\(representation.type):\(representation.data.count):".utf8))
            hasher.update(data: representation.data)
        }
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if try scalar("SELECT COUNT(*) FROM entry WHERE fingerprint=?", [.text(fingerprint)]) > 0 {
            try execute("UPDATE entry SET copied_at=?,copies=copies+1,source=?,source_bundle_id=? WHERE fingerprint=?", [.real(Date().timeIntervalSince1970), .text(capture.source), .text(capture.sourceBundleID), .text(fingerprint)])
            return
        }
        try prune(retention: retention, incoming: bytes)
        let id = UUID().uuidString
        var written: [URL] = []
        do {
            try execute("BEGIN IMMEDIATE")
            try execute("INSERT INTO entry(id,fingerprint,kind,title,excerpt,search_text,source,source_bundle_id,copied_at,byte_size) VALUES(?,?,?,?,?,?,?,?,?,?)",
                        [.text(id), .text(fingerprint), .text(capture.kind.rawValue), .text(capture.title), .text(capture.excerpt),
                         .text(String(capture.searchText.prefix(StorageLimits.searchableCharacters))), .text(capture.source), .text(capture.sourceBundleID),
                         .real(Date().timeIntervalSince1970), .integer(bytes)])
            for representation in capture.representations {
                let assetID = UUID().uuidString
                let url = root.appendingPathComponent("assets/\(assetID)")
                try representation.data.write(to: url, options: .atomic)
                written.append(url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                try execute("INSERT INTO representation(id,entry_id,item_order,uti,filename,byte_size) VALUES(?,?,?,?,?,?)",
                            [.text(assetID), .text(id), .integer(representation.item), .text(representation.type), .text(assetID), .integer(representation.data.count)])
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            for url in written { try? FileManager.default.removeItem(at: url) }
            logger.error("Capture transaction failed; new assets rolled back")
            throw LibraryError.storage
        }
    }

    /// 清理仅删除非保护记录；超过保护容量时拒绝新内容，不无限增长磁盘。
    private func prune(retention: Int, incoming: Int) throws {
        // 本 actor 内没有挂起点，容量预检与后续清理之间不会插入其他存储操作。
        // 即使回收全部非保护内容也放不下时直接拒绝，不能先删除历史再报容量不足。
        let protectedFilter = "pinned=1 OR EXISTS(SELECT 1 FROM entry_group WHERE entry_id=entry.id)"
        let protectedCount = try scalar("SELECT COUNT(*) FROM entry WHERE \(protectedFilter)")
        let protectedBytes = try scalar("SELECT COALESCE(SUM(byte_size),0) FROM entry WHERE \(protectedFilter)")
        guard protectedCount < StorageLimits.maximumEntries,
              protectedBytes + incoming <= StorageLimits.maximumBytes else { throw LibraryError.capacity }
        // 0 天表示不按时间清理；容量超限时仍从最旧的非保护记录开始回收。
        let cutoff = retention > 0
            ? Date().addingTimeInterval(-Double(retention) * 86_400).timeIntervalSince1970
            : -Double.greatestFiniteMagnitude
        var count = try scalar("SELECT COUNT(*) FROM entry")
        var bytes = try scalar("SELECT COALESCE(SUM(byte_size),0) FROM entry")
        // 常规入库只取一个候选，不为每次复制构造全库候选数组。
        while true {
            let overBudget = count >= StorageLimits.maximumEntries || bytes + incoming > StorageLimits.maximumBytes
            let query = try statement("SELECT id,byte_size FROM entry WHERE pinned=0 AND NOT EXISTS(SELECT 1 FROM entry_group WHERE entry_id=entry.id) AND (?=1 OR copied_at<?) ORDER BY copied_at LIMIT 1",
                                      [.integer(overBudget ? 1 : 0), .real(cutoff)])
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { sqlite3_finalize(query); break }
            guard status == SQLITE_ROW, let id = UUID(uuidString: text(query, 0)) else {
                sqlite3_finalize(query); throw LibraryError.storage
            }
            let size = Int(sqlite3_column_int64(query, 1))
            sqlite3_finalize(query)
            try delete(id)
            count -= 1
            bytes -= size
        }
        guard count < StorageLimits.maximumEntries, bytes + incoming <= StorageLimits.maximumBytes else { throw LibraryError.capacity }
    }

    /// 仅删除 UUID 命名的应用资产，绝不删除用户原文件；数据库提交后清理文件。
    func delete(_ id: UUID) throws {
        try prepare()
        let query = try statement("SELECT filename FROM representation WHERE entry_id=?", [.text(id.uuidString)])
        var filenames: [String] = []
        while sqlite3_step(query) == SQLITE_ROW { filenames.append(text(query, 0)) }
        sqlite3_finalize(query)
        try execute("DELETE FROM entry WHERE id=?", [.text(id.uuidString)])
        thumbnails.removeValue(forKey: id)
        thumbnailOrder.removeAll { $0 == id }
        for filename in filenames { if let url = assetURL(filename) { try? FileManager.default.removeItem(at: url) } }
    }

    /// 清空内容但保留分组结构，不删除任何剪贴板引用的原文件；返回删除条数。
    @discardableResult
    func clear() throws -> Int {
        try prepare()
        let removed = try scalar("SELECT COUNT(*) FROM entry")
        try execute("DELETE FROM entry")
        try finishCleanup()
        return removed
    }

    /// 删除早于 cutoff 的记录，包含置顶与已分组内容；返回删除条数。
    @discardableResult
    func clear(before cutoff: Date) throws -> Int {
        try prepare()
        let timestamp = cutoff.timeIntervalSince1970
        let removed = try scalar("SELECT COUNT(*) FROM entry WHERE copied_at<?", [.real(timestamp)])
        guard removed > 0 else { return 0 }
        try execute("DELETE FROM entry WHERE copied_at<?", [.real(timestamp)])
        try finishCleanup()
        return removed
    }

    /// 清理缩略图缓存、孤立资产并回收数据库空间；分组结构不受影响。
    private func finishCleanup() throws {
        thumbnails.removeAll()
        thumbnailOrder.removeAll()
        try recoverAssets()
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("VACUUM")
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

    /// 编辑前校验 Unicode 大小写重名，不依赖 SQLite NOCASE 的 ASCII 限制。
    func saveGroup(_ id: UUID?, name: String) throws {
        try prepare()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = try readGroups()
        guard !trimmed.isEmpty, trimmed.count <= 20, groups.count < 100 || id != nil,
              !groups.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else { throw LibraryError.nameConflict }
        if let id { try execute("UPDATE user_group SET name=? WHERE id=?", [.text(trimmed), .text(id.uuidString)]) }
        else {
            try execute("INSERT INTO user_group(id,name,color,position) VALUES(?,?,?,?)", [.text(UUID().uuidString), .text(trimmed), .integer(groups.count % 4), .integer(groups.count)])
        }
    }

    /// 复制时才恢复有界原始表示；返回前检查文件引用，不读取文件本体。
    func representations(_ id: UUID) throws -> [ClipRepresentation] {
        try prepare()
        let query = try statement("SELECT item_order,uti,filename,byte_size FROM representation WHERE entry_id=? ORDER BY item_order,id", [.text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        var result: [ClipRepresentation] = []
        var size = 0
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw LibraryError.storage }
            let expected = Int(sqlite3_column_int64(query, 3))
            size += expected
            guard size <= StorageLimits.maximumCaptureBytes, let url = assetURL(text(query, 2)),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attributes[.size] as? NSNumber)?.intValue == expected else { throw LibraryError.missingContent }
            let data = try Data(contentsOf: url)
            let type = text(query, 1)
            if type == "public.file-url" {
                guard let value = String(data: data, encoding: .utf8), let file = URL(string: value), file.isFileURL,
                      FileManager.default.isReadableFile(atPath: file.path) else { throw LibraryError.unavailableFile }
            }
            result.append(ClipRepresentation(item: Int(sqlite3_column_int(query, 0)), type: type, data: data))
        }
        guard !result.isEmpty else { throw LibraryError.missingContent }
        return result
    }

    /// 将文本 / 链接恢复为唯一的纯文本表示，不改动历史中保存的原始格式。
    /// 优先纯文本，链接优先原始 URL；RTF 在后台提取文字，不使用可能加载外部资源的 HTML 渲染器。
    /// 多个 item 按原顺序用换行连接；转换失败时不清空用户剪贴板。
    func plainText(_ id: UUID, kind: ClipKind) throws -> [ClipRepresentation] {
        guard kind == .text || kind == .link else { throw LibraryError.unsupported }
        let originals = try representations(id)
        let indices = Set(originals.map(\.item)).sorted()
        var parts: [String] = []
        var bytes = 0
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

    /// 用户从历史再次复制后更新排序和次数，不重复采集自身写入内容。
    func markCopied(_ id: UUID) throws {
        try prepare()
        try execute("UPDATE entry SET copied_at=?,copies=copies+1 WHERE id=?", [.real(Date().timeIntervalSince1970), .text(id.uuidString)])
    }

    /// 按 item 原顺序聚合文本，文件引用仅展示文件名，不将本地路径交付预览。
    /// 整条详情共享 16 KB 文本及 256 KB RTF 解析预算，只生成一张缩略图。
    func preview(_ id: UUID) async throws -> ClipPreview {
        try prepare()
        // 显式排序表示优先级，避免随机资产 UUID 决定同一 item 展示哪种文本。
        var preview = ""
        var textItems: Set<Int> = []
        var richTextBudget = ClipboardFormats.maximumRichTextPreviewBytes
        var truncated = false
        var storedThumbnail: URL?
        var referencedThumbnail: URL?
        // 预留截断提示空间，正文与提示合计不超过 16 KB。
        let textBudget = 16_000
        do {
            let query = try statement("""
                SELECT uti,filename,item_order FROM representation WHERE entry_id=?
                ORDER BY item_order,CASE uti WHEN 'public.file-url' THEN 0
                    WHEN 'public.utf8-plain-text' THEN 1 WHEN 'public.url' THEN 2
                    WHEN 'public.rtf' THEN 3 ELSE 4 END,id
                """, [.text(id.uuidString)])
            defer { sqlite3_finalize(query) }
            while true {
                let status = sqlite3_step(query)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw LibraryError.storage }
                let type = text(query, 0)
                let item = Int(sqlite3_column_int(query, 2))
                guard let url = assetURL(text(query, 1)) else { continue }
                // 缩略图只记录候选；查询结束后再在 actor 外生成，引用文件阻塞时不影响其他存储操作。
                if ClipboardFormats.rasterImages.contains(type) {
                    if storedThumbnail == nil { storedThumbnail = url }
                } else if type == "public.file-url", referencedThumbnail == nil {
                    referencedThumbnail = url
                }
                // 缺失或无法解析的表示不占用 item，允许其他格式继续回退。
                if !textItems.contains(item) {
                    let separator = preview.isEmpty ? "" : "\n"
                    let remaining = textBudget - preview.utf8.count - separator.utf8.count
                    var value: String?
                    if type == "public.file-url" {
                        // 路径只用于内部读取与再次复制，预览仅交付解码后的末级文件名。
                        if let data = previewData(url, maximum: 16_385), data.count <= 16_384,
                           let raw = String(data: data, encoding: .utf8),
                           let reference = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                           reference.isFileURL {
                            value = reference.lastPathComponent
                        }
                    } else if ["public.utf8-plain-text", "public.url"].contains(type) {
                        if let data = previewData(url, maximum: max(1, remaining + 1)), !data.isEmpty {
                            value = String(decoding: data, as: UTF8.self)
                        }
                    } else if type == "public.rtf",
                              let data = previewData(url, maximum: richTextBudget + 1), data.count <= richTextBudget {
                        richTextBudget -= data.count
                        value = ClipboardFormats.richText(data)
                    }
                    if let value, !value.isEmpty {
                        textItems.insert(item)
                        if remaining > 0 {
                            var bounded = String(decoding: value.utf8.prefix(remaining), as: UTF8.self)
                            // 截在多字节字符中间时替换字符可能多占字节，收紧到总预算内。
                            while bounded.utf8.count > remaining { bounded.removeLast() }
                            preview += separator + bounded
                            if bounded != value { truncated = true }
                        } else {
                            truncated = true
                        }
                    }
                }
            }
        }
        var thumbnail: Data?
        if let storedThumbnail {
            // 已保存的像素表示优先；即使同时存在文件引用，也不读取原文件。
            thumbnail = await Self.boundedThumbnail(.stored(storedThumbnail), maximum: 420)
        } else if let referencedThumbnail {
            thumbnail = await Self.boundedThumbnail(.referenced(referencedThumbnail), maximum: 420)
        }
        if truncated { preview += "\n…预览已截断，复制保留原始内容" }
        return ClipPreview(text: preview, thumbnail: thumbnail)
    }

    /// 有界读取失败时留给其他表示回退，不把单个缺失资产当成整个预览失败。
    private func previewData(_ url: URL, maximum: Int) -> Data? {
        guard maximum > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maximum)
    }

    /// 仅接受本地、非符号链接的普通图片文件，拒绝网络卷和未下载云文件。
    /// 引用只保存路径，源文件删除、移动或无权限时返回空，不中断其他内容预览。
    nonisolated private static func referencedImageThumbnail(_ asset: URL, maximum: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: asset) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_385), data.count <= 16_384,
              let value = String(data: data, encoding: .utf8),
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
              let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                          .fileSizeKey, .volumeIsLocalKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              info.isRegularFile == true, info.isSymbolicLink != true, info.volumeIsLocal == true,
              (info.isUbiquitousItem != true || info.ubiquitousItemDownloadingStatus == .current
               || info.ubiquitousItemDownloadingStatus == .downloaded), let size = info.fileSize, size > 0, size <= 64 * 1024 * 1024
        else { return nil }
        return makeThumbnail(url, maximum: maximum)
    }

    /// ImageIO 直接从文件降采样，关闭原图解码缓存；输出始终受目标像素上限约束。
    nonisolated private static func makeThumbnail(_ url: URL, maximum: Int) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                  [kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceThumbnailMaxPixelSize: maximum,
                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// 文件读取与解码可能因异常挂载点永久阻塞；放到 actor 外执行并限制等待时间。
    /// 使用非结构化任务竞速，避免结构化任务组在退出时继续等待卡死的子任务。
    /// 超时后记录该资产，本次运行不再重试，串行 SQLite 与列表查询继续工作。
    nonisolated private static func boundedThumbnail(_ source: ThumbnailSource, maximum: Int) async -> Data? {
        let key: String?
        if case .referenced(let asset) = source {
            key = asset.path
            if TimedOutThumbnailCache.shared.contains(asset.path) { return nil }
        } else {
            key = nil
        }
        let generation = Task.detached(priority: .utility) {
            generateThumbnail(source, maximum: maximum)
        }
        let timeout = Task.detached {
            try? await Task.sleep(for: .seconds(3))
            return !Task.isCancelled
        }
        let outcome: ThumbnailOutcome = await withCheckedContinuation { continuation in
            let race = ThumbnailRace(continuation)
            Task.detached {
                let data = await generation.value
                race.finish(.finished(data))
            }
            Task.detached {
                if await timeout.value { race.finish(.timedOut) }
            }
        }
        if case .timedOut = outcome {
            if let key { TimedOutThumbnailCache.shared.insert(key) }
            return nil
        }
        guard case .finished(let data) = outcome else { return nil }
        return data
    }

    nonisolated private static func generateThumbnail(_ source: ThumbnailSource, maximum: Int) -> Data? {
        switch source {
        case .stored(let url): return makeThumbnail(url, maximum: maximum)
        case .referenced(let asset): return referencedImageThumbnail(asset, maximum: maximum)
        }
    }

    /// 列表缩略图缓存最多 24 张，总量最多 2 MB；只缓存降采样 PNG，不读取完整图片到 UI。
    private var thumbnails: [UUID: Data] = [:]
    private var thumbnailOrder: [UUID] = []

    func thumbnail(_ id: UUID) async throws -> Data? {
        try prepare()
        let sources = try thumbnailSources(id)
        // 优先使用已保存的像素表示；只有没有内置图片时才读取引用文件。
        let source = sources.stored.map(ThumbnailSource.stored) ?? sources.referenced.map(ThumbnailSource.referenced)
        guard let source else { return nil }
        let usesReference: Bool
        if case .referenced = source { usesReference = true } else { usesReference = false }
        // 引用可在应用外修改、删除或撤销权限，不按记录 UUID 永久复用旧缩略图。
        if !usesReference, let cached = thumbnails[id] { return cached }
        guard let data = await Self.boundedThumbnail(source, maximum: 640), data.count <= 2 * 1024 * 1024 else { return nil }
        if usesReference { return data }
        while !thumbnailOrder.isEmpty && (thumbnailOrder.count >= 24 || thumbnails.values.reduce(0, { $0 + $1.count }) + data.count > 2 * 1024 * 1024) {
            thumbnails.removeValue(forKey: thumbnailOrder.removeFirst())
        }
        thumbnails[id] = data
        thumbnailOrder.append(id)
        return data
    }

    /// 只查询候选资产，不读取文件；引用路径的校验与解码在 actor 外执行。
    private func thumbnailSources(_ id: UUID) throws -> (stored: URL?, referenced: URL?) {
        let query = try statement("SELECT uti,filename FROM representation WHERE entry_id=? ORDER BY item_order,id", [.text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        var stored: URL?
        var referenced: URL?
        while sqlite3_step(query) == SQLITE_ROW {
            let type = text(query, 0)
            guard let url = assetURL(text(query, 1)) else { continue }
            if ClipboardFormats.rasterImages.contains(type) {
                if stored == nil { stored = url }
            } else if type == "public.file-url", referenced == nil {
                referenced = url
            }
        }
        return (stored, referenced)
    }

    /// 路径必须是 UUID 文件名，拒绝数据库损坏导致的目录穿越。
    private func assetURL(_ name: String) -> URL? {
        guard UUID(uuidString: name) != nil else { return nil }
        return root?.appendingPathComponent("assets/\(name)")
    }

    /// 启动或清空后回收未提交文件；缺失原始资产保留记录，复制时明确报错。
    private func recoverAssets() throws {
        guard let root else { throw LibraryError.storage }
        let query = try statement("SELECT filename FROM representation")
        var referenced: Set<String> = []
        while sqlite3_step(query) == SQLITE_ROW { referenced.insert(text(query, 0)) }
        sqlite3_finalize(query)
        let directory = root.appendingPathComponent("assets")
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if !referenced.contains(file.lastPathComponent) { try FileManager.default.removeItem(at: file) }
        }
    }
}
