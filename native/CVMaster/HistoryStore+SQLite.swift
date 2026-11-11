/**
 * SQLite 语句、事务与列读取辅助：只绑定预定义类型，错误统一映射为存储失败。
 * @author helele
 * @since 2026-11-09
 */
import Foundation
import SQLite3

extension HistoryStore {
    /// 所有修改事务内不检查任务取消：开始后必须完整提交或回滚。
    func transaction<T>(_ operation: () throws -> T) throws -> T {
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

    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        if values.isEmpty && sql.contains(";") {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw LibraryError.storage }
            return
        }
        let prepared = try statement(sql, values)
        defer { sqlite3_finalize(prepared) }
        // PRAGMA 可能返回一行；必须继续到 DONE，不能把后续错误当作成功。
        while try next(prepared) { }
    }

    func statement(_ sql: String, _ values: [SQLValue] = []) throws -> OpaquePointer {
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
    func next(_ query: OpaquePointer) throws -> Bool {
        let status = sqlite3_step(query)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw LibraryError.storage }
        return status == SQLITE_ROW
    }

    func scalar(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        let query = try statement(sql, values)
        defer { sqlite3_finalize(query) }
        guard try next(query) else { throw LibraryError.storage }
        let value = Int(sqlite3_column_int64(query, 0))
        guard try !next(query) else { throw LibraryError.storage }
        return value
    }

    func text(_ query: OpaquePointer, _ column: Int32, maximumBytes: Int = StorageLimits.searchableBytes,
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
}
