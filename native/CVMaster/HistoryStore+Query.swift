/**
 * 分页查询、全库容量统计与分组目录读取。
 * @author helele
 * @since 2026-11-09
 */
import Foundation
import SQLite3

extension HistoryStore {
    /// trigram 候选数达到此值即视为低选择性，回退到顺序 LIKE；约为 10,000 条上限的 10%。
    static let trigramSelectivityProbe = 1_024

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
                let match = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                // 高命中查询用 trigram 物化大量 rowid 反而慢于顺序 LIKE 扫描；先做有界探测，
                // 命中数达到阈值就只用 LIKE。LIKE 子句始终保留作精确复核，结果集与是否使用索引无关。
                let hits = try scalar("SELECT COUNT(*) FROM (SELECT rowid FROM entry_search WHERE entry_search MATCH ? LIMIT ?)",
                                      [.text(match), .integer(Self.trigramSelectivityProbe)])
                try Task.checkCancellation()
                if hits < Self.trigramSelectivityProbe {
                    clauses.append("e.rowid IN (SELECT rowid FROM entry_search WHERE entry_search MATCH ?)")
                    values.append(.text(match))
                }
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

    func readGroups() throws -> [ClipGroup] {
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
}
