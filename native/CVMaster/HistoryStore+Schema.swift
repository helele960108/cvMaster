/**
 * 可选 FTS5 trigram 索引与旧分类迁移；索引缺失时回退到精确子串扫描。
 * @author helele
 * @since 2026-11-09
 */
import Foundation
import SQLite3
import OSLog

extension HistoryStore {
    /// 索引是可重建的优化，不是历史库可用性的前提；不支持 FTS5/trigram 时继续 LIKE。
    func configureSearch() throws {
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

    func dropSearchTriggers() throws {
        try execute("""
            DROP TRIGGER IF EXISTS entry_search_ai;
            DROP TRIGGER IF EXISTS entry_search_ad;
            DROP TRIGGER IF EXISTS entry_search_au;
            """)
    }

    /// 仅扫描文件名元数据；迁移时同时接受旧显示键与稳定键，不修改原始表示。
    func reclassifyImageFiles() throws {
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
}
