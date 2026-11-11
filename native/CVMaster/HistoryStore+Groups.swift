/**
 * 分组增删改与手动排序；全部在事务内读取最新目录，不信任 UI 传入的索引。
 * @author helele
 * @since 2026-11-09
 */
import Foundation
import SQLite3

extension HistoryStore {
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
}
