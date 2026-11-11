/*
 * Regression checks – groups: deletion, manual ordering, persistence and atomic rollback.
 * Synthetic fixtures only; never touches the real clipboard or history database.
 * author: helele
 * since: 2026-11-09
 */
import Foundation
import Carbon
import SQLite3
import Darwin

extension RegressionChecks {
    /// Every group fixture lives beneath the runner-owned directory, including referenced originals.
    static func groupManagement(_ directory: URL) async throws {
        try await groupDeletion(child(directory, "deletion"))
        try await groupOrdering(child(directory, "ordering"))
    }

    static func requireGroupOrder(_ store: HistoryStore, _ db: FixtureDatabase,
                                          _ ids: [UUID]) async throws {
        try require(try await store.groupCatalog().map(\.id) == ids, "Group catalog order differs from requested order")
        let positions = try db.rows("SELECT id,position FROM user_group ORDER BY position,id")
        try require(positions == ids.enumerated().map { [$0.element.uuidString, String($0.offset)] },
                    "Moved group positions are not atomic, unique and continuous from zero")
    }

    static func groupDeletion(_ directory: URL) async throws {
        let store = HistoryStore(directory: directory)
        let external = directory.appendingPathComponent("keep-group-original.txt")
        let externalBytes = Data("external group original must survive".utf8)
        try externalBytes.write(to: external)
        let rich = [ClipRepresentation(item: 0, type: "public.utf8-plain-text", data: Data("group raw text 中文".utf8)),
                    ClipRepresentation(item: 0, type: "public.rtf", data: rtf(16)),
                    ClipRepresentation(item: 1, type: "public.utf8-plain-text", data: Data("second raw item".utf8))]
        try await store.save(capture("shared protected entry", representations: rich), retention: 0)
        try await store.save(capture("keep-group-original.txt", kind: .file,
            representations: [ClipRepresentation(item: 0, type: "public.file-url", data: Data(external.absoluteString.utf8))]), retention: 0)
        try await store.save(capture("other group entry"), retention: 0)
        let entries = try await page(store)
        let shared = entries.clips.first { $0.title == "shared protected entry" }!.id
        let file = entries.clips.first { $0.kind == .file }!.id
        let other = entries.clips.first { $0.title == "other group entry" }!.id
        for name in ["Delete populated", "Keep memberships", "Delete empty"] {
            try await store.saveGroup(nil, name: name)
        }
        let catalog = try await store.groupCatalog()
        let removed = catalog[0].id, kept = catalog[1].id, empty = catalog[2].id
        try await store.setGroup(shared, group: removed, included: true)
        try await store.setGroup(file, group: removed, included: true)
        try await store.setGroup(shared, group: kept, included: true)
        try await store.setGroup(other, group: kept, included: true)
        try await store.setPinned(shared, true)
        try await store.markCopied(shared)
        try await store.markCopied(shared)
        let db = try FixtureDatabase(directory)
        try db.execute("UPDATE entry SET copied_at=1 WHERE id='\(file.uuidString)'")
        let before = try await page(store)
        let entryRows = try db.rows("SELECT * FROM entry ORDER BY id")
        let representationRows = try db.rows("SELECT * FROM representation ORDER BY id")
        let groupRows = try db.rows("SELECT * FROM user_group ORDER BY id")
        let memberships = try db.rows("SELECT * FROM entry_group ORDER BY entry_id,group_id")
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        // A valid UUID orphan would be collected by cleanup; group-only edits must not invoke it.
        let orphan = assets.appendingPathComponent(UUID().uuidString)
        try Data("group edits must not run asset cleanup".utf8).write(to: orphan)
        var assetBytes: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: assets.path) {
            assetBytes[name] = try Data(contentsOf: assets.appendingPathComponent(name))
        }
        try db.execute("""
            CREATE TRIGGER validation_group_delete_fail AFTER DELETE ON user_group
            WHEN old.id='\(removed.uuidString)' BEGIN SELECT RAISE(FAIL,'synthetic group delete failure'); END;
            """)
        try await expectError(.storage) { try await store.deleteGroup(removed) }
        try require(try db.rows("SELECT * FROM user_group ORDER BY id") == groupRows
                    && db.rows("SELECT * FROM entry_group ORDER BY entry_id,group_id") == memberships,
                    "Failed group deletion lost its definition or cascaded memberships")
        try requireSamePage(before, try await page(store))
        try db.execute("DROP TRIGGER validation_group_delete_fail")

        try await store.deleteGroup(empty)
        let withoutEmpty = try db.rows("SELECT * FROM user_group ORDER BY id")
        try await store.deleteGroup(empty)
        try require(try db.rows("SELECT * FROM user_group ORDER BY id") == withoutEmpty,
                    "Repeated empty-group deletion changed the catalog")
        try requireSamePage(before, try await page(store))
        try await store.deleteGroup(removed)
        try await store.deleteGroup(removed)
        try require(try await store.groupCatalog().map(\.id) == [kept], "Deleting populated group removed another definition")
        try require(try db.rows("SELECT * FROM user_group ORDER BY id") == groupRows.filter { $0[0] == kept.uuidString },
                    "Group deletion changed another group's name, color or position")
        try require(try db.rows("SELECT * FROM entry_group ORDER BY entry_id,group_id") == memberships.filter { $0[1] != removed.uuidString },
                    "Populated-group deletion changed other group memberships")
        let after = try await page(store)
        try require(after.total == before.total && after.storedEntries == before.storedEntries && after.storedBytes == before.storedBytes,
                    "Deleting a group deleted entries or changed storage totals")
        try require(after.clips.first { $0.id == shared }.map { $0.pinned && $0.copies == 3 && $0.groups == [kept] } == true,
                    "Deleting a group lost pinned state, copies or shared membership")
        try require(after.clips.first { $0.id == file }?.groups.isEmpty == true,
                    "Deleting a file's last membership removed the entry or retained the relation")
        try require(try await page(store, scope: removed.uuidString).total == 0, "Deleted group scope still returns entries")
        try require(try await page(store, scope: kept.uuidString).total == 2, "Other group scope lost shared entries")
        try await expectError(.missingGroup) { try await store.saveGroup(removed, name: "No resurrection") }
        for offset in [-1, 1] {
            try await expectError(.missingGroup) { try await store.moveGroup(removed, offset: offset) }
        }
        try await store.deleteGroup(kept)
        try await store.deleteGroup(kept)
        try await store.deleteGroup(UUID())
        try require(try await store.groupCatalog().isEmpty, "Last-group deletion left a definition or recreated a deleted group")
        try require(try db.rows("SELECT * FROM entry_group").isEmpty, "Last-group deletion left memberships")
        try require(try db.rows("SELECT * FROM entry ORDER BY id") == entryRows
                    && db.rows("SELECT * FROM representation ORDER BY id") == representationRows,
                    "Group-only edits changed entry metadata, copies, pins or representation records")
        let remaining = try await page(store)
        try require(remaining.total == before.total && remaining.storedBytes == before.storedBytes,
                    "Last-group deletion pruned unprotected history or invalidated storage totals")
        try require(Set(try FileManager.default.contentsOfDirectory(atPath: assets.path)) == Set(assetBytes.keys),
                    "Group deletion removed content assets or ran orphan cleanup")
        for (name, bytes) in assetBytes {
            try require(try Data(contentsOf: assets.appendingPathComponent(name)) == bytes, "Group deletion changed asset bytes")
        }
        for clip in remaining.clips {
            let originals = try await store.representations(clip.id)
            try require(originals.count == representationRows.filter { $0[1] == clip.id.uuidString }.count,
                        "Group deletion broke raw representation recovery")
            for original in originals {
                let row = representationRows.first { $0[1] == clip.id.uuidString && $0[2] == String(original.item) && $0[3] == original.type }!
                try require(original.data == assetBytes[row[4]], "Group deletion changed recovered raw representation bytes")
            }
        }
        try require(try Data(contentsOf: external) == externalBytes, "Group deletion changed an externally referenced file")
        try require(try db.rows("PRAGMA foreign_key_check").isEmpty, "Group deletion left broken foreign keys")
        try require(try db.rows("PRAGMA integrity_check").first?.first == "ok", "Group deletion damaged SQLite integrity")
    }

    static func groupOrdering(_ directory: URL) async throws {
        let store = HistoryStore(directory: directory)
        for name in ["Zulu", "Alpha", "Middle", "Tail"] { try await store.saveGroup(nil, name: name) }
        let initial = try await store.groupCatalog()
        let a = initial[0].id, b = initial[1].id, c = initial[2].id, d = initial[3].id
        let db = try FixtureDatabase(directory)
        try await requireGroupOrder(store, db, [a, b, c, d])
        try await store.save(capture("ordering preserves entry"), retention: 0)
        let entry = try await page(store).clips[0].id
        try await store.setGroup(entry, group: c, included: true)
        try await store.setGroup(entry, group: d, included: true)
        let preservedPage = try await page(store)
        let originalRows = try db.rows("SELECT id,color,position FROM user_group ORDER BY position,id")
        try await store.saveGroup(c, name: "  Renamed  ")
        try require(try await store.groupCatalog().first { $0.id == c }?.name == "Renamed", "Group rename was not normalized")
        try require(try db.rows("SELECT id,color,position FROM user_group ORDER BY position,id") == originalRows,
                    "Rename changed group identity, color or ordering")
        let renamedRows = try db.rows("SELECT * FROM user_group ORDER BY id")
        try await expectError(.nameConflict) { try await store.saveGroup(c, name: "zulu") }
        try await expectError(.nameConflict) { try await store.saveGroup(nil, name: "ZULU") }
        try require(try db.rows("SELECT * FROM user_group ORDER BY id") == renamedRows, "Name conflict partially changed groups")
        // FAIL leaves changes made by the statement intact unless the API really rolls its transaction back.
        try db.execute("""
            CREATE TRIGGER validation_group_insert_fail AFTER INSERT ON user_group
            BEGIN SELECT RAISE(FAIL,'synthetic group insert failure'); END;
            """)
        try await expectError(.storage) { try await store.saveGroup(nil, name: "Must roll back") }
        try require(try db.rows("SELECT * FROM user_group ORDER BY id") == renamedRows, "Failed group creation was not rolled back")
        try db.execute("DROP TRIGGER validation_group_insert_fail")
        try db.execute("""
            CREATE TRIGGER validation_group_rename_fail AFTER UPDATE OF name ON user_group
            BEGIN SELECT RAISE(FAIL,'synthetic group rename failure'); END;
            """)
        try await expectError(.storage) { try await store.saveGroup(c, name: "Must also roll back") }
        try require(try db.rows("SELECT * FROM user_group ORDER BY id") == renamedRows, "Failed group rename was not rolled back")
        try db.execute("DROP TRIGGER validation_group_rename_fail")
        try db.execute("""
            UPDATE user_group SET position=CASE id WHEN '\(a.uuidString)' THEN 4 WHEN '\(b.uuidString)' THEN 10
                WHEN '\(c.uuidString)' THEN 30 ELSE 70 END;
            """)
        try await store.saveGroup(nil, name: "Newest")
        let e = try await store.groupCatalog().last!.id
        try require(try await store.groupCatalog().map(\.id) == [a, b, c, d, e], "New group was inserted into a position hole instead of at the end")
        try require(try db.integer("SELECT position FROM user_group WHERE id=?", [e.uuidString]) == 71,
                    "Group creation used count instead of MAX(position)+1")
        try await store.moveGroup(a, offset: 1)
        try await requireGroupOrder(store, db, [b, a, c, d, e])
        try await store.moveGroup(a, offset: -1)
        try await requireGroupOrder(store, db, [a, b, c, d, e])
        try await store.moveGroup(e, offset: -1)
        try await requireGroupOrder(store, db, [a, b, c, e, d])
        try await store.moveGroup(e, offset: 1)
        try await requireGroupOrder(store, db, [a, b, c, d, e])
        let orderedRows = try db.rows("SELECT * FROM user_group ORDER BY id")
        try await store.moveGroup(a, offset: -1)
        try await store.moveGroup(e, offset: 1)
        for offset in [0, -2, 2, Int.min, Int.max] {
            try await expectError(.storage) { try await store.moveGroup(c, offset: offset) }
        }
        try require(try db.rows("SELECT * FROM user_group ORDER BY id") == orderedRows, "Boundary or invalid-offset move changed positions")
        try db.execute("""
            CREATE TABLE validation_group_moves(n INTEGER NOT NULL);
            INSERT INTO validation_group_moves VALUES(0);
            CREATE TRIGGER validation_group_move_fail AFTER UPDATE OF position ON user_group BEGIN
                UPDATE validation_group_moves SET n=n+1;
                SELECT CASE WHEN (SELECT n FROM validation_group_moves)=2
                    THEN RAISE(FAIL,'synthetic mid-move failure') END;
            END;
            """)
        try await expectError(.storage) { try await store.moveGroup(a, offset: 1) }
        try require(try db.rows("SELECT * FROM user_group ORDER BY id") == orderedRows
                    && db.integer("SELECT n FROM validation_group_moves") == 0,
                    "Mid-move failure left partial positions or committed trigger side effects")
        try await requireGroupOrder(store, db, [a, b, c, d, e])
        try db.execute("DROP TRIGGER validation_group_move_fail; DROP TABLE validation_group_moves;")
        try await store.moveGroup(a, offset: 1)
        try await store.moveGroup(a, offset: -1)
        let otherStore = HistoryStore(directory: directory)
        // The original store already observed c at index 2; another writer moves it before this request.
        try await otherStore.moveGroup(c, offset: -1)
        try await store.moveGroup(c, offset: -1)
        try await requireGroupOrder(store, db, [c, a, b, d, e])
        try await otherStore.deleteGroup(a)
        try await store.moveGroup(b, offset: 1)
        try await requireGroupOrder(store, db, [c, d, b, e])
        try await expectError(.missingGroup) { try await store.saveGroup(a, name: "Deleted elsewhere") }
        try await expectError(.missingGroup) { try await store.moveGroup(a, offset: 1) }
        try requireSamePage(preservedPage, try await page(store))
        let persisted = try db.rows("SELECT * FROM user_group ORDER BY position,id")
        let reopened = HistoryStore(directory: directory)
        try await requireGroupOrder(reopened, db, [c, d, b, e])
        try require(try db.rows("SELECT * FROM user_group ORDER BY position,id") == persisted, "Reopening changed persisted group metadata or positions")
        for id in [c, d, b] { try await store.deleteGroup(id) }
        let singleton = try db.rows("SELECT * FROM user_group")
        try await store.moveGroup(e, offset: -1)
        try await store.moveGroup(e, offset: 1)
        try require(try await store.groupCatalog().map(\.id) == [e] && db.rows("SELECT * FROM user_group") == singleton,
                    "Single-group boundary moves changed the group or its persisted position")
        try await store.deleteGroup(e)
        try await store.saveGroup(nil, name: "Restart at zero")
        try await requireGroupOrder(store, db, try await store.groupCatalog().map(\.id))
        try require(try db.rows("PRAGMA foreign_key_check").isEmpty, "Group ordering left broken foreign keys")
        try require(try db.rows("PRAGMA integrity_check").first?.first == "ok", "Group ordering damaged SQLite integrity")
    }
}
