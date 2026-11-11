/**
 * 置顶、分组变更与目录刷新；分组写入期间禁止重复操作。
 * @author helele
 * @since 2026-11-09
 */
import Foundation

@MainActor
extension ClipboardLibrary {
    func setPinned(_ clip: Clip) {
        mutate { try await $0.setPinned(clip.id, !clip.pinned) }
    }

    func setGroup(_ clip: Clip, group: UUID, included: Bool) {
        guard !changingGroups else { return }
        mutate { try await $0.setGroup(clip.id, group: group, included: included) }
    }

    func saveGroup(_ id: UUID?, name: String) {
        changeGroups { try await $0.saveGroup(id, name: name) }
    }

    func deleteGroup(_ id: UUID) {
        changeGroups(deleting: id) { try await $0.deleteGroup(id) }
    }

    func moveGroup(_ id: UUID, offset: Int) {
        changeGroups { try await $0.moveGroup(id, offset: offset) }
    }

    /// 写入不随浮层关闭而取消；只回读分组目录，删除时才刷新历史归属。
    func changeGroups(deleting id: UUID? = nil,
                              _ action: @escaping @Sendable (HistoryStore) async throws -> Void) {
        guard !changingGroups else { return }
        changingGroups = true
        groupsVersion += 1
        groupsTask?.cancel()
        groupsTask = nil
        Task { [weak self, store] in
            defer { self?.changingGroups = false }
            var committed = false
            do {
                try await action(store)
                committed = true
            } catch { self?.report(error) }
            guard let self else { return }
            var scopeChanged = false
            do {
                let groups = try await store.groupCatalog()
                scopeChanged = self.applyGroupCatalog(groups)
            } catch {
                self.report(error)
                // 删除已提交但目录读取失败时，不能继续展示确定已删除的筛选。
                if committed, let id {
                    self.groups.removeAll { $0.id == id }
                    if self.scope == id.uuidString {
                        self.scope = "all"
                        scopeChanged = true
                    }
                }
            }
            if committed, id != nil, !scopeChanged {
                self.scheduleSearch(resetLimit: false)
            }
        }
    }

    /// 只对成功读取的目录修复失效 scope；启动时的空数组不能作为删除依据。
    @discardableResult
    func applyGroupCatalog(_ groups: [ClipGroup]) -> Bool {
        self.groups = groups
        if let id = UUID(uuidString: scope), !groups.contains(where: { $0.id == id }) {
            scope = "all"
            return true
        }
        return false
    }

    /// 分组规模上限 100，独立目录读取成本小，使用版本号防止旧结果覆盖。
    func refreshGroups() {
        guard !changingGroups else { return }
        groupsVersion += 1
        let version = groupsVersion
        groupsTask?.cancel()
        groupsTask = Task { [weak self, store] in
            do {
                let groups = try await store.groupCatalog()
                guard let self, !Task.isCancelled, self.groupsVersion == version else { return }
                self.applyGroupCatalog(groups)
            } catch {
                guard !Task.isCancelled else { return }
                self?.report(error)
            }
        }
    }
}
