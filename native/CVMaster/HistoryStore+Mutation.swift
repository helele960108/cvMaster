/**
 * 采集入库、保留策略清理、删除与置顶；清理与入库共享事务，提交后才回收资产。
 * @author helele
 * @since 2026-11-09
 */
import Foundation
import SQLite3
import CryptoKit
import OSLog

extension HistoryStore {
    /// 摘要 / 搜索允许有界回退；不改变原始表示，也不在主线程解析 RTF。
    func readableCapture(_ capture: ClipCapture) -> ClipCapture {
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
        for id in prunedIDs { thumbnailCache.invalidate(id) }
        unlinkAssets(removed)
    }

    /// 一次聚合容量，最多 256 个一批读取 / 删除；始终保留置顶与已分组记录。
    func prune(retention: Int, incoming: Int, addingEntry: Bool) throws -> (ids: [UUID], filenames: [String]) {
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

    func assetNames(for ids: [UUID]) throws -> [String] {
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
        thumbnailCache.invalidate(id)
        unlinkAssets(names)
    }

    /// 删除提交是成功边界；资产回收 / checkpoint 失败不伪装成删除回滚。
    /// 不自动 VACUUM：空闲页留待复用，不保证文件缩小或安全擦除已删除正文。
    @discardableResult
    func clear() throws -> Int { try clearEntries(before: nil) }

    @discardableResult
    func clear(before cutoff: Date) throws -> Int { try clearEntries(before: cutoff) }

    func clearEntries(before cutoff: Date?) throws -> Int {
        try prepare()
        let values: [SQLValue] = cutoff.map { [.real($0.timeIntervalSince1970)] } ?? []
        let filter = cutoff == nil ? "" : " WHERE copied_at<?"
        let removed = try transaction {
            let count = try scalar("SELECT COUNT(*) FROM entry\(filter)", values)
            try execute("DELETE FROM entry\(filter)", values)
            return count
        }
        cachedStats = nil
        thumbnailCache.removeAll()
        finishCleanup()
        return removed
    }

    func finishCleanup() {
        do { try recoverAssets() } catch { logger.warning("Committed deletion; asset maintenance deferred") }
        do { try execute("PRAGMA wal_checkpoint(TRUNCATE)") } catch { logger.warning("Committed deletion; checkpoint deferred") }
    }

    func setPinned(_ id: UUID, _ pinned: Bool) throws {
        try prepare()
        try execute("UPDATE entry SET pinned=? WHERE id=?", [.integer(pinned ? 1 : 0), .text(id.uuidString)])
    }


    func markCopied(_ id: UUID) throws {
        try prepare()
        try execute("UPDATE entry SET copied_at=?,copies=copies+1 WHERE id=?", [.real(Date().timeIntervalSince1970), .text(id.uuidString)])
    }
}
