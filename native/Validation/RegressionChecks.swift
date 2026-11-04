/*
 * Standalone, synthetic-only checks for production storage, thumbnails and pure policies.
 * No application lifecycle, clipboard monitor/library, XCTest, or real user database is loaded.
 * author: helele
 * since: 2026-10-20
 */
import Foundation
import Carbon
import SQLite3
import Darwin

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(message) }
}

/// A separate, short-lived SQLite connection is used only for fixtures and fault injection.
private final class FixtureDatabase {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ directory: URL) throws {
        let result = sqlite3_open_v2(directory.appendingPathComponent("history.sqlite").path,
                                     &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK else { throw CheckFailure("Cannot open synthetic SQLite fixture") }
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw CheckFailure("Fixture SQL failed: \(message)")
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CheckFailure("Fixture SQL prepare failed: \(message)")
        }
        return statement
    }

    func bind(_ values: [String], to statement: OpaquePointer) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else {
                throw CheckFailure("Fixture bind failed")
            }
        }
    }

    func run(_ statement: OpaquePointer, values: [String]) throws {
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CheckFailure("Fixture insert failed: \(message)") }
    }

    func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var output: [[String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return output }
            guard status == SQLITE_ROW else { throw CheckFailure("Fixture query failed: \(message)") }
            output.append((0..<sqlite3_column_count(statement)).map {
                sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? ""
            })
        }
    }

    func integer(_ sql: String, _ values: [String] = []) throws -> Int {
        guard let value = try rows(sql, values).first?.first, let result = Int(value) else {
            throw CheckFailure("Fixture integer query returned no integer")
        }
        return result
    }

    var message: String { sqlite3_errmsg(handle).map { String(cString: $0) } ?? "SQLite error" }
}

/// Injected thumbnail work executes synchronously off-actor; the lock exposes only test counters.
private final class WorkProbe: @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var started = 0
    private var completed = 0
    private var active = 0
    private var peak = 0

    func work(blocking: Bool = true, result: Data? = Data([42])) -> Data? {
        lock.lock()
        started += 1
        active += 1
        peak = max(peak, active)
        lock.unlock()
        if blocking { gate.wait() }
        lock.lock()
        completed += 1
        active -= 1
        lock.unlock()
        return result
    }

    var counts: (started: Int, completed: Int, peak: Int) {
        lock.lock(); defer { lock.unlock() }
        return (started, completed, peak)
    }
}

@main
private struct RegressionChecks {
    private static let marker = "cvmaster-isolated-regressions\n"
    private static let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a4h8AAAAASUVORK5CYII=")!

    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count >= 2, arguments[0] == "--workspace" else {
                throw CheckFailure("Use native/scripts/check-regressions.sh; a marked temporary workspace is required")
            }
            // Preserve runner's physical path: Foundation standardization can reintroduce /var or /tmp aliases.
            let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
            try validateWorkspace(root)
            if try SingleInstanceChecks.runHelperIfRequested(arguments: Array(arguments.dropFirst(2)), workspace: root) { return }
            let options = Set(arguments.dropFirst(2))
            try require(options.isSubset(of: ["--benchmark", "--benchmark-large"]), "Unknown harness option")
            print("All fixtures are synthetic; no application or clipboard lifecycle is instantiated.")
            let checks: [(String, (URL) async throws -> Void)] = [
                ("single-instance lifetime locks, subprocess races and unsafe targets", SingleInstanceChecks.run),
                ("stable kind keys and v3 migration", migration),
                ("Unicode metadata byte bounds, aggregate capture and legacy projections", metadataBounds),
                ("asset recovery excludes uncommitted writer assets", recoveryIsolation),
                ("capture round trips, duplicate statistics and preserved metadata", roundTrips),
                ("literal LIKE / trigram / forced fallback semantic parity", searchParity),
                ("batched group projection, totals and date/kind/scope limits", groupsAndFilters),
                ("group deletion, ordering, persistence and atomic rollback", groupManagement),
                ("pruning rollback and protected retention", pruningRollback),
                ("private metadata/assets and symlink attacks fail closed", privacy),
                ("RTF conversion budgets and raw/plain-text recovery", richText),
                ("clear retains groups and external referenced files", clearing),
                ("thumbnail deduplication, deadline, cancellation and worker cap", thumbnails),
                ("two-phase clipboard cursor, bounded retries and delayed data", captureCursor),
                ("pure privacy gate and per-item capture budgets", capturePolicy),
                ("default shortcut, saved preferences and reset round trips", globalShortcut),
                ("pure paste handoff request binding and focus transitions", pasteHandoff),
                ("pure paste focus restoration single-use permits and cancellation", pasteFocusRestoration)
            ]
            for (index, check) in checks.enumerated() {
                let start = DispatchTime.now().uptimeNanoseconds
                do {
                    try await check.1(child(root, "case-\(index)"))
                } catch {
                    throw CheckFailure("\(check.0): \(error)")
                }
                print(String(format: "PASS %@ (%.1f ms)", check.0, milliseconds(since: start)))
            }
            print("PASS \(checks.count) regression suites")
            if options.contains("--benchmark") || options.contains("--benchmark-large") {
                try await benchmark(child(root, "benchmark"), large: options.contains("--benchmark-large"))
            }
        } catch {
            let text = "FAIL \(error)\n"
            FileHandle.standardError.write(Data(text.utf8))
            exit(1)
        }
    }

    private static func validateWorkspace(_ root: URL) throws {
        let parent = root.deletingLastPathComponent()
        try require(root.lastPathComponent == "data" && parent.lastPathComponent.hasPrefix("cvmaster-regressions."),
                    "Refusing workspace outside runner-owned temporary directory")
        try require(try String(contentsOf: root.appendingPathComponent(".owned"), encoding: .utf8) == marker,
                    "Missing workspace ownership marker")
        try require(try String(contentsOf: parent.appendingPathComponent(".owned"), encoding: .utf8) == marker,
                    "Missing runner ownership marker")
        for directory in [root, parent] {
            let info = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            try require(info.isDirectory == true && info.isSymbolicLink != true, "Workspace must not be a symlink")
        }
    }

    private static func child(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func capture(_ text: String, kind: ClipKind = .text,
                                representations: [ClipRepresentation]? = nil, source: String = "Synthetic") -> ClipCapture {
        ClipCapture(kind: kind, title: String(text.prefix(120)), excerpt: String(text.prefix(240)),
                    searchText: kind == .image ? "" : text, source: source, sourceBundleID: "local.synthetic.validation",
                    representations: representations ?? [ClipRepresentation(item: 0, type: "public.utf8-plain-text", data: Data(text.utf8))])
    }

    private static func page(_ store: HistoryStore, query: String = "", scope: String = "all", kind: ClipKind? = nil,
                             interval: DateInterval? = nil, limit: Int = 300) async throws -> HistoryPage {
        try await store.page(query: query, scope: scope, kind: kind, interval: interval, limit: limit)
    }

    private static func expectError(_ expected: LibraryError, _ operation: () async throws -> Void) async throws {
        do {
            try await operation()
        } catch let error as LibraryError {
            try require(String(describing: error) == String(describing: expected),
                        "Expected \(expected), received \(error)")
            return
        }
        throw CheckFailure("Expected \(expected), operation unexpectedly succeeded")
    }

    /// v3 fixture includes source_bundle_id; no real database is copied to manufacture migration input.
    private static func makeV3(_ directory: URL) throws {
        _ = try child(directory, "assets")
        let db = try FixtureDatabase(directory)
        try db.execute("""
            CREATE TABLE entry(id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL UNIQUE,kind TEXT NOT NULL,
                title TEXT NOT NULL,excerpt TEXT NOT NULL,search_text TEXT NOT NULL,source TEXT NOT NULL,
                copied_at REAL NOT NULL,byte_size INTEGER NOT NULL,pinned INTEGER NOT NULL DEFAULT 0,
                copies INTEGER NOT NULL DEFAULT 1,source_bundle_id TEXT NOT NULL DEFAULT '');
            CREATE TABLE user_group(id TEXT PRIMARY KEY,name TEXT NOT NULL COLLATE NOCASE UNIQUE,
                color INTEGER NOT NULL,position INTEGER NOT NULL);
            CREATE TABLE entry_group(entry_id TEXT NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
                group_id TEXT NOT NULL REFERENCES user_group(id) ON DELETE CASCADE,PRIMARY KEY(entry_id,group_id));
            CREATE TABLE representation(id TEXT PRIMARY KEY,entry_id TEXT NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
                item_order INTEGER NOT NULL,uti TEXT NOT NULL,filename TEXT NOT NULL UNIQUE,byte_size INTEGER NOT NULL);
            PRAGMA user_version=3;
            """)
    }

    private static func insertRows(_ directory: URL, _ rows: [(id: UUID, kind: String, text: String, date: Double)]) throws {
        let db = try FixtureDatabase(directory)
        let statement = try db.prepare("""
            INSERT INTO entry(id,fingerprint,kind,title,excerpt,search_text,source,source_bundle_id,copied_at,byte_size)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """)
        defer { sqlite3_finalize(statement) }
        try db.execute("BEGIN IMMEDIATE")
        do {
            for row in rows {
                try db.run(statement, values: [row.id.uuidString, row.id.uuidString, row.kind, String(row.text.prefix(120)),
                                              String(row.text.prefix(240)), row.text, "Synthetic", "local.synthetic.validation",
                                              String(row.date), String(row.text.utf8.count)])
            }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    private static func migration(_ directory: URL) async throws {
        for kind in ClipKind.allCases {
            try require(ClipKind.fromStorageValue(kind.storageValue) == kind, "Stable kind key does not round-trip")
            try require(ClipKind.fromStorageValue(kind.rawValue) == kind, "Legacy localized kind does not decode")
        }
        try require(ClipKind.fromStorageValue("future-kind") == .text, "Unknown kind projection must remain resilient")
        try makeV3(directory)
        let ids = (0..<5).map { _ in UUID() }
        let kinds = ClipKind.allCases.map(\.rawValue) + ["future-kind"]
        try insertRows(directory, zip(ids, kinds).enumerated().map {
            (id: $0.element.0, kind: $0.element.1, text: "migration-\($0.offset)", date: Double(100 + $0.offset))
        })
        let group = UUID(), earlierGroup = UUID(), middleGroup = UUID()
        let legacyGroups: [[String]]
        do {
            let db = try FixtureDatabase(directory)
            let statement = try db.prepare("INSERT INTO user_group(id,name,color,position) VALUES(?,?,?,?)")
            defer { sqlite3_finalize(statement) }
            for values in [[group.uuidString, "Migration Alpha", "2", "40"],
                           [earlierGroup.uuidString, "Migration Zulu", "3", "3"],
                           [middleGroup.uuidString, "Migration Middle", "1", "17"]] {
                try db.run(statement, values: values)
            }
            legacyGroups = try db.rows("SELECT id,name,color,position FROM user_group ORDER BY position,id")
            try db.execute("UPDATE entry SET pinned=1,copies=7 WHERE id='\(ids[0].uuidString)'")
            try db.execute("INSERT INTO entry_group VALUES('\(ids[0].uuidString)','\(group.uuidString)')")
        }
        let store = HistoryStore(directory: directory)
        try await store.prepare()
        let result = try await page(store)
        try require(result.total == 5 && result.clips.count == 5, "Migration lost an entry or unknown kind broke page")
        guard let preserved = result.clips.first(where: { $0.id == ids[0] }) else { throw CheckFailure("Migrated entry missing") }
        try require(preserved.pinned && preserved.copies == 7 && preserved.groups == [group], "Migration changed protected metadata")
        try require(preserved.sourceBundleID == "local.synthetic.validation", "Migration lost source bundle identity")
        let db = try FixtureDatabase(directory)
        try require(try db.integer("PRAGMA user_version") == 4, "Expected schema v4")
        try require(try db.rows("SELECT id,name,color,position FROM user_group ORDER BY position,id") == legacyGroups,
                    "Migration changed legacy group metadata, positions or catalog order")
        try require(try await store.groupCatalog().map(\.id) == [earlierGroup, middleGroup, group],
                    "Migrated group catalog ignored persisted positions")
        let reopened = HistoryStore(directory: directory)
        try require(try await reopened.groupCatalog().map(\.id) == [earlierGroup, middleGroup, group],
                    "Reopening migrated history changed group catalog order")
        for (id, kind) in zip(ids.prefix(4), ClipKind.allCases) {
            try require(try db.rows("SELECT kind FROM entry WHERE id=?", [id.uuidString]).first?.first == kind.storageValue,
                        "Migration did not use stable English key")
        }
        try require(try db.rows("SELECT kind FROM entry WHERE id=?", [ids[4].uuidString]).first?.first == "future-kind",
                    "Migration overwrote an unknown kind")
        try require(try db.rows("PRAGMA integrity_check").first?.first == "ok", "Migrated database integrity check failed")
        try require(try db.rows("PRAGMA foreign_key_check").isEmpty, "Migrated database foreign keys invalid")
    }

    private static func roundTrips(_ directory: URL) async throws {
        let store = HistoryStore(directory: directory)
        let external = directory.appendingPathComponent("synthetic-original.txt")
        try Data("external file must survive".utf8).write(to: external)
        let captures = [
            capture("unique plain text 中文"),
            capture("https://example.invalid/synthetic", kind: .link,
                    representations: [ClipRepresentation(item: 0, type: "public.url", data: Data("https://example.invalid/synthetic".utf8))]),
            capture("synthetic image", kind: .image,
                    representations: [ClipRepresentation(item: 0, type: "public.png", data: image)]),
            capture("synthetic-original.txt", kind: .file,
                    representations: [ClipRepresentation(item: 0, type: "public.file-url", data: Data(external.absoluteString.utf8))])
        ]
        for value in captures { try await store.save(value, retention: 0) }
        let before = try await page(store)
        try require(before.total == 4 && Set(before.clips.map(\.kind)) == Set(ClipKind.allCases), "Capture kinds did not round-trip")
        try require(before.storedBytes == captures.flatMap(\.representations).reduce(0) { $0 + $1.data.count }, "Stored byte statistics incorrect")
        for value in captures {
            guard let clip = before.clips.first(where: { $0.kind == value.kind }) else { throw CheckFailure("Capture missing") }
            let originals = try await store.representations(clip.id)
            try require(originals.count == value.representations.count && originals[0].data == value.representations[0].data,
                        "Raw capture bytes changed")
            try require(clip.hasFileReference == (value.kind == .file), "File-reference projection incorrect")
        }
        let textID = before.clips.first(where: { $0.kind == .text })!.id
        try await store.saveGroup(nil, name: "Kept on duplicate")
        let groups = try await store.groupCatalog()
        try await store.setGroup(textID, group: groups[0].id, included: true)
        try await store.setPinned(textID, true)
        let duplicateDB = try FixtureDatabase(directory)
        try duplicateDB.execute("""
            CREATE TRIGGER unchanged_search_guard BEFORE UPDATE OF search_text ON entry
            WHEN old.search_text=new.search_text BEGIN SELECT RAISE(ABORT,'Unnecessary search index update'); END;
            """)
        defer { try? duplicateDB.execute("DROP TRIGGER unchanged_search_guard") }
        try await store.save(capture("unique plain text 中文", source: "Synthetic Again"), retention: 0)
        let after = try await page(store)
        let duplicate = after.clips.first(where: { $0.id == textID })!
        try require(after.storedEntries == 4 && after.storedBytes == before.storedBytes, "Duplicate changed storage totals")
        try require(duplicate.copies == 2 && duplicate.pinned && duplicate.groups == [groups[0].id], "Duplicate lost counters or metadata")
        try require(duplicate.source == "Synthetic Again", "Duplicate source was not refreshed")
        try await store.markCopied(textID)
        try require(try await page(store).clips.first(where: { $0.id == textID })?.copies == 3, "markCopied did not increment count")
    }

    private static func likePattern(_ query: String) -> String {
        let escaped = MetadataBounds.query(query).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private static func referenceIDs(_ db: FixtureDatabase, query: String) throws -> [String] {
        if query.isEmpty {
            return try db.rows("SELECT id FROM entry ORDER BY pinned DESC,copied_at DESC,id LIMIT 300").compactMap(\.first)
        }
        return try db.rows("""
            SELECT id FROM entry WHERE kind IN ('text','link','file') AND search_text LIKE ? ESCAPE '\\'
            ORDER BY pinned DESC,copied_at DESC,id LIMIT 300
            """, [likePattern(query)]).compactMap(\.first)
    }

    private static func searchParity(_ directory: URL) async throws {
        let normalDirectory = try child(directory, "candidate")
        let fallbackDirectory = try child(directory, "fallback")
        let candidate = HistoryStore(directory: normalDirectory)
        let fallback = HistoryStore(directory: fallbackDirectory, enablesTrigram: false)
        try await candidate.prepare()
        try await fallback.prepare()
        let corpus = [
            "ordinary needle alpha BETA gamma", "literal 100% complete and under_score",
            "literal back\\slash /forward/slash", "double \"quote\" and 'single' quote",
            "中文子串测试与汉字", "emoji 😀🙃🙂 cluster family 👨‍👩‍👧‍👦",
            "punctuation .,:;!?()-[]{} + and a-b", "newlines first\nsecond\r\nthird",
            "Accented École école Äpfel äpfel Straße STRASSE", "combining e\u{301} versus é",
            "tiny a Z 中 文 ab XY 中文", "percent%_\\ mixture", "\" OR * : - NOT AND near",
            "image hidden needle", "file-needle-中文.txt", "https://example.invalid/needle?q=100%"
        ]
        let rows = corpus.enumerated().map { index, text in
            (id: UUID(), kind: index == 13 ? "image" : index == 14 ? "file" : index == 15 ? "link" : "text",
             text: text, date: Double(index + 100))
        }
        try insertRows(normalDirectory, rows)
        try insertRows(fallbackDirectory, rows)
        let queries = ["", "needle", "NEEDLE", "100%", "%", "_", "\\", "/", "\"", "'", "\"quote\"", "a-b",
                       "中文", "子串测", "汉", "a", "ab", "XY", "Z", "中", "文", "😀", "😀🙃🙂", "\n", "\r\n",
                       "first\nsecond", "École", "école", "Ä", "ä", "STRASSE", "e\u{301}", "é", "%_\\", "OR *", "NOT AND",
                       "no-synthetic-match-zzzz", String(repeating: "x", count: 257),
                       "e" + String(repeating: "\u{301}", count: 10_000)]
        let db = try FixtureDatabase(normalDirectory)
        for query in queries {
            let expected = try referenceIDs(db, query: query)
            let actual = try await page(candidate, query: query)
            let forcedLike = try await page(fallback, query: query)
            try require(actual.clips.map { $0.id.uuidString } == expected && actual.total == expected.count,
                        "Candidate LIKE parity failed for \(String(reflecting: query))")
            try require(forcedLike.clips.map { $0.id.uuidString } == expected && forcedLike.total == expected.count,
                        "Forced fallback LIKE parity failed for \(String(reflecting: query))")
            try require(actual.storedEntries == corpus.count, "Search changed global storage statistics")
        }
        let virtual = try db.rows("SELECT name FROM sqlite_master WHERE type='table' AND sql LIKE '%fts5%' AND sql LIKE '%trigram%'")
        print("  search cases=\(queries.count), candidate trigram=\(virtual.isEmpty ? "unavailable (legitimate fallback)" : "available"), forced LIKE=verified")
    }

    private static func groupsAndFilters(_ directory: URL) async throws {
        let store = HistoryStore(directory: directory)
        try await store.prepare()
        let rows = (0..<80).map { index in
            (id: UUID(), kind: index.isMultiple(of: 2) ? "text" : "link", text: "batch item \(index)", date: Double(1_000 + index))
        }
        try insertRows(directory, rows)
        try await store.saveGroup(nil, name: "Alpha")
        try await store.saveGroup(nil, name: "Beta")
        let catalog = try await store.groupCatalog()
        let alpha = catalog[0].id, beta = catalog[1].id
        var memberships: [UUID: Set<UUID>] = [:]
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 2) {
                try await store.setGroup(row.id, group: alpha, included: true)
                memberships[row.id, default: []].insert(alpha)
            }
            if index.isMultiple(of: 3) {
                try await store.setGroup(row.id, group: beta, included: true)
                memberships[row.id, default: []].insert(beta)
            }
            if index.isMultiple(of: 5) { try await store.setPinned(row.id, true) }
        }
        let result = try await page(store, limit: 13)
        try require(result.clips.count == 13 && result.total == 80, "LIMIT incorrectly changed filtered total")
        for clip in result.clips { try require(clip.groups == memberships[clip.id, default: []], "Batched group membership leaked across entries") }
        let inAlpha = try await page(store, scope: alpha.uuidString, limit: 7)
        try require(inAlpha.clips.count == 7 && inAlpha.total == 40, "Group scope count/LIMIT incorrect")
        try require(inAlpha.clips.allSatisfy { $0.groups.contains(alpha) }, "Group scope returned unrelated entry")
        let pinned = try await page(store, scope: "pinned", limit: 300)
        try require(pinned.total == 16 && pinned.clips.allSatisfy(\.pinned), "Pinned scope failed")
        let interval = DateInterval(start: Date(timeIntervalSince1970: 1_010), end: Date(timeIntervalSince1970: 1_020))
        let combined = try await page(store, scope: alpha.uuidString, kind: .text, interval: interval, limit: 2)
        try require(combined.total == 5 && combined.clips.count == 2, "Combined date/kind/group filtering wrong")
        try require(combined.clips.allSatisfy { $0.copiedAt >= interval.start && $0.copiedAt < interval.end }, "Date interval is not half-open")
        let empty = try await page(store, query: "definitely-absent", scope: alpha.uuidString, kind: .link)
        try require(empty.clips.isEmpty && empty.total == 0 && empty.storedEntries == 80, "Empty grouped page incorrect")
        try require(try await store.groupCatalog().map(\.id) == catalog.map(\.id), "Empty page changed full group catalog")
        try await store.setGroup(rows[0].id, group: alpha, included: false)
        let removed = try await page(store, scope: alpha.uuidString)
        try require(removed.total == 39 && !removed.clips.contains(where: { $0.id == rows[0].id }), "Group removal did not update scope")
        try require(try await page(store, limit: 0).clips.count == 1, "Minimum page limit was not bounded")
        try require(try await page(store, limit: Int.max).clips.count == 80, "Large limit lost rows")
    }

    /// Every group fixture lives beneath the runner-owned directory, including referenced originals.
    private static func groupManagement(_ directory: URL) async throws {
        try await groupDeletion(child(directory, "deletion"))
        try await groupOrdering(child(directory, "ordering"))
    }

    private static func requireGroupOrder(_ store: HistoryStore, _ db: FixtureDatabase,
                                          _ ids: [UUID]) async throws {
        try require(try await store.groupCatalog().map(\.id) == ids, "Group catalog order differs from requested order")
        let positions = try db.rows("SELECT id,position FROM user_group ORDER BY position,id")
        try require(positions == ids.enumerated().map { [$0.element.uuidString, String($0.offset)] },
                    "Moved group positions are not atomic, unique and continuous from zero")
    }

    private static func groupDeletion(_ directory: URL) async throws {
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

    private static func groupOrdering(_ directory: URL) async throws {
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

    private static func pruningRollback(_ directory: URL) async throws {
        let store = HistoryStore(directory: directory)
        try await store.save(capture("aged unprotected history"), retention: 0)
        try await store.save(capture("aged pinned history"), retention: 0)
        try await store.save(capture("aged grouped history"), retention: 0)
        let initial = try await page(store)
        let unprotected = initial.clips.first(where: { $0.title == "aged unprotected history" })!.id
        let pinned = initial.clips.first(where: { $0.title == "aged pinned history" })!.id
        let grouped = initial.clips.first(where: { $0.title == "aged grouped history" })!.id
        try await store.setPinned(pinned, true)
        try await store.saveGroup(nil, name: "Protected")
        let catalog = try await store.groupCatalog()
        try await store.setGroup(grouped, group: catalog[0].id, included: true)
        do {
            let db = try FixtureDatabase(directory)
            try db.execute("UPDATE entry SET copied_at=1")
            try db.execute("CREATE TRIGGER validation_abort BEFORE INSERT ON entry BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;")
        }
        let assetDirectory = directory.appendingPathComponent("assets")
        let assetsBefore = Set(try FileManager.default.contentsOfDirectory(atPath: assetDirectory.path))
        try await expectError(.storage) { try await store.save(capture("must fail without pruning"), retention: 1) }
        let after = try await page(store)
        try require(after.total == 3 && after.clips.contains(where: { $0.id == unprotected }), "Failed save pruned existing history")
        try require(after.storedBytes == initial.storedBytes, "Failed save changed stored bytes")
        let restored = try await store.representations(unprotected)
        try require(String(data: restored[0].data, encoding: .utf8) == "aged unprotected history", "Failed save removed old asset")
        try require(Set(try FileManager.default.contentsOfDirectory(atPath: assetDirectory.path)) == assetsBefore,
                    "Failed save leaked or deleted asset files")
        do { try FixtureDatabase(directory).execute("DROP TRIGGER validation_abort") }
        try await store.save(capture("successful retry prunes only unprotected"), retention: 1)
        let retried = try await page(store)
        try require(retried.total == 3 && !retried.clips.contains(where: { $0.id == unprotected }), "Successful retry did not prune aged history")
        try require(retried.clips.contains(where: { $0.id == pinned && $0.pinned }) && retried.clips.contains(where: { $0.id == grouped }),
                    "Retention pruned protected history")
        let db = try FixtureDatabase(directory)
        try require(try db.rows("PRAGMA integrity_check").first?.first == "ok", "Rollback database integrity failed")
        try require(try db.rows("PRAGMA foreign_key_check").isEmpty, "Rollback left broken foreign keys")
    }

    private static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static func privacy(_ directory: URL) async throws {
        let ordinary = try child(directory, "ordinary")
        // prepare must repair an existing permissive app-owned directory as well as create private files.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ordinary.path)
        let assets = try child(ordinary, "assets")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: assets.path)
        let store = HistoryStore(directory: ordinary)
        try await store.save(capture("private payload"), retention: 0)
        try require(try mode(ordinary) == 0o700 && mode(assets) == 0o700, "History directories are not mode 0700")
        for file in ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm"] {
            let url = ordinary.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path) {
                try require(try mode(url) == 0o600, "Metadata file \(file) is not mode 0600")
            }
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: assets.path) {
            try require(try mode(assets.appendingPathComponent(name)) == 0o600, "Content asset is not mode 0600")
        }
        let clip = try await page(store).clips[0]
        let db = try FixtureDatabase(ordinary)
        let assetName = try db.rows("SELECT filename FROM representation WHERE entry_id=?", [clip.id.uuidString])[0][0]
        let asset = assets.appendingPathComponent(assetName)
        let sentinel = directory.appendingPathComponent("symlink-read-target")
        let sentinelData = Data("private payload".utf8) // same size prevents a false pass based only on byte count
        try sentinelData.write(to: sentinel)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sentinel.path)
        try FileManager.default.removeItem(at: asset)
        try FileManager.default.createSymbolicLink(at: asset, withDestinationURL: sentinel)
        try await expectError(.missingContent) { _ = try await store.representations(clip.id) }
        try require(try Data(contentsOf: sentinel) == sentinelData && mode(sentinel) == 0o644, "Asset read followed or changed symlink target")

        try await store.delete(clip.id)
        try require(try Data(contentsOf: sentinel) == sentinelData, "Delete followed an asset symlink")

        for component in ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm"] {
            for attackKind in ["hardlink", "directory", "fifo"] {
                let attack = try child(directory, "\(attackKind)-\(component.replacingOccurrences(of: ".", with: "-"))")
                let attemptedRoot = try child(attack, "store")
                let location = attemptedRoot.appendingPathComponent(component)
                let target = attack.appendingPathComponent("untouched")
                try Data("hardlink sentinel".utf8).write(to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
                switch attackKind {
                case "hardlink": try FileManager.default.linkItem(at: target, to: location)
                case "directory": _ = try child(attemptedRoot, component)
                default: try require(mkfifo(location.path, 0o600) == 0, "Cannot create synthetic FIFO")
                }
                let attackedStore = HistoryStore(directory: attemptedRoot)
                try await expectError(.storage) { try await attackedStore.prepare() }
                try require(try String(contentsOf: target, encoding: .utf8) == "hardlink sentinel" && mode(target) == 0o644,
                            "\(attackKind) metadata rejection modified target")
            }
        }

        // Replacing the visible assets path after prepare must not redirect writes outside the owned FD.
        let swappedRoot = try child(directory, "swapped-store")
        let swappedStore = HistoryStore(directory: swappedRoot)
        try await swappedStore.prepare()
        let ownedAssets = swappedRoot.appendingPathComponent("assets")
        try FileManager.default.moveItem(at: ownedAssets, to: swappedRoot.appendingPathComponent("owned-assets"))
        let escapeTarget = try child(directory, "escape-target")
        try FileManager.default.createSymbolicLink(at: ownedAssets, withDestinationURL: escapeTarget)
        do {
            try await swappedStore.save(capture("must not escape owned assets"), retention: 0)
        } catch let error as LibraryError {
            try require(String(describing: error) == String(describing: LibraryError.storage), "Unexpected assets-swap error")
        }
        try require(try FileManager.default.contentsOfDirectory(atPath: escapeTarget.path).isEmpty,
                    "Active assets-directory replacement redirected a content write")

        for component in ["root", "assets", "history.sqlite", "history.sqlite-wal", "history.sqlite-shm"] {
            let attack = try child(directory, "attack-\(component.replacingOccurrences(of: ".", with: "-"))")
            let target: URL
            let attemptedRoot: URL
            if component == "root" || component == "assets" {
                target = try child(attack, "target")
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                let content = target.appendingPathComponent("sentinel")
                try Data("do not touch".utf8).write(to: content)
                if component == "root" {
                    attemptedRoot = attack.appendingPathComponent("linked-root")
                    try FileManager.default.createSymbolicLink(at: attemptedRoot, withDestinationURL: target)
                } else {
                    attemptedRoot = try child(attack, "store")
                    try FileManager.default.createSymbolicLink(at: attemptedRoot.appendingPathComponent("assets"), withDestinationURL: target)
                }
            } else {
                attemptedRoot = try child(attack, "store")
                target = attack.appendingPathComponent("target")
                try Data("do not touch".utf8).write(to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
                try FileManager.default.createSymbolicLink(at: attemptedRoot.appendingPathComponent(component), withDestinationURL: target)
            }
            let targetMode = try mode(target)
            let attackedStore = HistoryStore(directory: attemptedRoot)
            try await expectError(.storage) { try await attackedStore.prepare() }
            let info = try target.resourceValues(forKeys: [.isDirectoryKey])
            let sentinelURL = info.isDirectory == true ? target.appendingPathComponent("sentinel") : target
            try require(try String(contentsOf: sentinelURL, encoding: .utf8) == "do not touch" && mode(target) == targetMode,
                        "\(component) symlink attack modified its target")
            if info.isDirectory == true {
                try require(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["sentinel"],
                            "\(component) symlink attack wrote through target directory")
            }
        }
    }

    private static func rtf(_ count: Int, character: Character = "r") -> Data {
        Data(("{\\rtf1\\ansi " + String(repeating: String(character), count: count) + "}").utf8)
    }

    private static func richText(_ directory: URL) async throws {
        let store = HistoryStore(directory: directory)
        let budget = ClipboardFormats.maximumRichTextPreviewBytes
        let oversized = rtf(budget + 1)
        let original = ClipCapture(kind: .text, title: "oversized RTF", excerpt: "", searchText: "", source: "Synthetic",
                                   sourceBundleID: "", representations: [ClipRepresentation(item: 0, type: "public.rtf", data: oversized)])
        try await store.save(original, retention: 0)
        let large = try await page(store).clips[0]
        let raw = try await store.representations(large.id)
        try require(raw[0].data == oversized, "Oversized RTF raw copy must remain available")
        let preview = try await store.preview(large.id)
        try require(preview.text.utf8.count <= 16_384 && !preview.text.contains(String(repeating: "r", count: 1_000)),
                    "Normal preview parsed over-budget RTF")
        try await expectError(.richTextTooLarge) { _ = try await store.plainText(large.id, kind: .text) }
        try require(ClipboardFormats.richText(oversized) == nil, "Rich-text parser accepted over-budget data")

        let parts = [ClipRepresentation(item: 0, type: "public.rtf", data: rtf(budget / 2 + 1, character: "a")),
                     ClipRepresentation(item: 1, type: "public.rtf", data: rtf(budget / 2 + 1, character: "b"))]
        try await store.save(ClipCapture(kind: .text, title: "aggregate RTF", excerpt: "", searchText: "", source: "Synthetic",
                                        sourceBundleID: "", representations: parts), retention: 0)
        let aggregate = try await page(store).clips.first(where: { $0.title == "aggregate RTF" || $0.id != large.id })!
        try await expectError(.richTextTooLarge) { _ = try await store.plainText(aggregate.id, kind: .text) }
        let aggregatePreview = try await store.preview(aggregate.id)
        try require(aggregatePreview.text.utf8.count <= 16_384, "Aggregate rich-text preview exceeded detail budget")

        let plaintext = String(repeating: "p", count: budget + 1)
        try await store.save(capture(plaintext), retention: 0)
        let plainID = try await page(store).clips.first(where: { $0.byteSize == plaintext.utf8.count })!.id
        let converted = try await store.plainText(plainID, kind: .text)
        try require(converted.count == 1 && converted[0].data == Data(plaintext.utf8), "RTF input budget incorrectly limits pure text")
        let small = rtf(12, character: "s")
        try await store.save(ClipCapture(kind: .text, title: "small RTF", excerpt: "", searchText: "", source: "Synthetic",
                                        sourceBundleID: "", representations: [ClipRepresentation(item: 0, type: "public.rtf", data: small)]), retention: 0)
        let smallPage = try await page(store, query: String(repeating: "s", count: 12))
        try require(smallPage.total == 1, "Small RTF was not extracted for search")
        let smallText = try await store.plainText(smallPage.clips[0].id, kind: .text)
        try require(String(data: smallText[0].data, encoding: .utf8) == String(repeating: "s", count: 12), "Small RTF conversion failed")
        let truncatedRTF = rtf(20_000, character: "z")
        try await store.save(ClipCapture(kind: .text, title: "preview truncation", excerpt: "", searchText: "", source: "Synthetic",
                                        sourceBundleID: "", representations: [ClipRepresentation(item: 0, type: "public.rtf", data: truncatedRTF)]), retention: 0)
        let truncatedID = try await page(store, query: String(repeating: "z", count: 12)).clips[0].id
        let truncatedPreview = try await store.preview(truncatedID)
        try require(truncatedPreview.text.hasPrefix(String(repeating: "z", count: 16_000))
                    && truncatedPreview.text.contains("预览已截断") && truncatedPreview.text.utf8.count <= 16_384,
                    "RTF preview omitted its truncation notice or exceeded the detail budget")
        let completeRTF = try await store.plainText(truncatedID, kind: .text)
        try require(completeRTF[0].data == Data(String(repeating: "z", count: 20_000).utf8),
                    "Preview metadata budget truncated plain-text RTF recovery")
        let mixed = [ClipRepresentation(item: 0, type: "public.rtf", data: oversized),
                     ClipRepresentation(item: 0, type: "public.utf8-plain-text", data: Data("preferred text".utf8))]
        try await store.save(capture("preferred text", representations: mixed), retention: 0)
        let mixedID = try await page(store, query: "preferred text").clips[0].id
        let preferred = try await store.plainText(mixedID, kind: .text)
        try require(String(data: preferred[0].data, encoding: .utf8) == "preferred text", "Unused RTF should not consume conversion budget")
    }

    private static func clearing(_ directory: URL) async throws {
        let store = HistoryStore(directory: directory)
        let external = directory.appendingPathComponent("keep-original.txt")
        try Data("external synthetic file".utf8).write(to: external)
        try await store.save(capture("keep-original.txt", kind: .file,
                                     representations: [ClipRepresentation(item: 0, type: "public.file-url", data: Data(external.absoluteString.utf8))]), retention: 0)
        try await store.save(capture("newer retained"), retention: 0)
        let entries = try await page(store)
        let old = entries.clips.first(where: { $0.kind == .file })!.id
        try await store.saveGroup(nil, name: "Survives clear")
        try await store.saveGroup(nil, name: "Empty group retained")
        try await store.saveGroup(nil, name: "Tail group retained")
        let originalCatalog = try await store.groupCatalog()
        try await store.moveGroup(originalCatalog[0].id, offset: 1)
        try await store.moveGroup(originalCatalog[2].id, offset: -1)
        let catalog = try await store.groupCatalog()
        try await store.setGroup(old, group: catalog[0].id, included: true)
        try await store.setPinned(old, true)
        let db = try FixtureDatabase(directory)
        let groupRows = try db.rows("SELECT id,name,color,position FROM user_group ORDER BY position,id")
        do {
            let statement = try db.prepare("UPDATE entry SET copied_at=? WHERE id=?")
            defer { sqlite3_finalize(statement) }
            try db.run(statement, values: ["1", old.uuidString])
        }
        try require(try await store.clear(before: Date(timeIntervalSince1970: 2)) == 1, "Date clear must remove even protected old rows")
        try require(try await page(store).total == 1, "Date clear removed wrong count")
        try require(try await store.groupCatalog().map(\.id) == catalog.map(\.id)
                    && db.rows("SELECT id,name,color,position FROM user_group ORDER BY position,id") == groupRows,
                    "Date clear changed group definitions or reordered the catalog")
        try require(try await store.clear() == 1, "Clear returned wrong count")
        let empty = try await page(store)
        try require(empty.total == 0 && empty.storedEntries == 0 && empty.storedBytes == 0, "Clear left stale statistics")
        try require(try await store.groupCatalog().map(\.id) == catalog.map(\.id)
                    && db.rows("SELECT id,name,color,position FROM user_group ORDER BY position,id") == groupRows,
                    "Clear deleted group definitions or changed their persisted order")
        let reopened = HistoryStore(directory: directory)
        try require(try await reopened.groupCatalog().map(\.id) == catalog.map(\.id), "Reopening cleared history changed group order")
        try require(try db.rows("SELECT * FROM entry_group").isEmpty, "Clear left group relations to deleted entries")
        try require(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("assets").path).isEmpty,
                    "Clear left orphan assets")
        try require(try String(contentsOf: external, encoding: .utf8) == "external synthetic file", "Clear deleted referenced original")
        try require(try await store.clear() == 0, "Clearing empty history should be a no-op")
    }

    private static func waitUntil(_ description: String, timeout: TimeInterval = 2,
                                  _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            try require(Date() < deadline, "Timed out waiting for \(description)")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func thumbnails(_ directory: URL) async throws {
        let probe = WorkProbe()
        let configuration = ThumbnailPipeline.Configuration(timeout: 0.15, failureCooldown: 0.02,
                                                              timeoutCooldown: 0.05, negativeCacheLimit: 8,
                                                              maximumWaitersPerJob: 8)
        let pipeline = ThumbnailPipeline(configuration: configuration) { _, _ in probe.work() }
        let source = ThumbnailSource.stored(directory.appendingPathComponent("same-synthetic-asset"))
        let first = Task { await pipeline.thumbnail(source, maximum: 100) }
        let second = Task { await pipeline.thumbnail(source, maximum: 100) }
        try await waitUntil("first deduplicated worker") { probe.counts.started == 1 }
        let other = Task { await pipeline.thumbnail(.stored(directory.appendingPathComponent("other")), maximum: 100) }
        try await waitUntil("two worker slots") { probe.counts.started == 2 }
        let overloaded = await pipeline.thumbnail(.stored(directory.appendingPathComponent("rejected-no-queue")), maximum: 100)
        try require(overloaded == nil && probe.counts.started == 2, "Pipeline queued or started work beyond fixed cap two")
        let firstResult = await first.value, secondResult = await second.value, otherResult = await other.value
        try require(firstResult == nil && secondResult == nil && otherResult == nil, "Blocked thumbnail did not time out")
        let afterTimeout = await pipeline.thumbnail(.stored(directory.appendingPathComponent("after-timeout")), maximum: 100)
        try require(afterTimeout == nil && probe.counts.started == 2, "Timeout released a still-running worker slot")
        probe.gate.signal(); probe.gate.signal()
        try await waitUntil("underlying worker completion") { probe.counts.completed == 2 }
        let deadline = Date().addingTimeInterval(2)
        probe.gate.signal()
        var fresh: Data?
        repeat {
            fresh = await pipeline.thumbnail(.stored(directory.appendingPathComponent("fresh")), maximum: 100)
            if fresh == nil { try await Task.sleep(for: .milliseconds(2)) }
            try require(Date() < deadline, "Worker slot was not reclaimed after synchronous completion")
        } while fresh == nil
        try require(fresh == Data([42]) && probe.counts.started == 3, "Completed worker did not publish result")
        try require(probe.counts.peak <= 2, "Underlying thumbnail concurrency exceeded cap")

        let cancellation = WorkProbe()
        let cancelPipeline = ThumbnailPipeline(configuration: configuration) { _, _ in cancellation.work() }
        let cancelled = Task { await cancelPipeline.thumbnail(.stored(directory.appendingPathComponent("cancelled")), maximum: 100) }
        try await waitUntil("cancellable worker") { cancellation.counts.started == 1 }
        cancelled.cancel()
        try require(await cancelled.value == nil, "Cancellation returned data")
        let secondWorker = Task { await cancelPipeline.thumbnail(.stored(directory.appendingPathComponent("second")), maximum: 100) }
        try await waitUntil("second worker after cancellation") { cancellation.counts.started == 2 }
        let capped = await cancelPipeline.thumbnail(.stored(directory.appendingPathComponent("still-capped")), maximum: 100)
        try require(capped == nil && cancellation.counts.started == 2, "Cancellation released a still-running worker slot")
        cancellation.gate.signal(); cancellation.gate.signal()
        _ = await secondWorker.value
        try await waitUntil("cancelled underlying workers") { cancellation.counts.completed == 2 }
    }

    private static func captureCursor(_: URL) async throws {
        let start = ContinuousClock.now
        func idle(_ observation: ClipboardChangeCursor.Observation) -> Bool {
            if case .idle = observation { return true }
            return false
        }
        func attempt(_ observation: ClipboardChangeCursor.Observation) throws -> ClipboardChangeCursor.Attempt {
            guard case .attempt(let attempt) = observation else { throw CheckFailure("Expected a pending clipboard attempt") }
            return attempt
        }
        var cursor = ClipboardChangeCursor()
        try require(idle(cursor.observe(change: 10, blocked: false, now: start)), "Uninitialized cursor backfilled content")
        try require(idle(cursor.observe(change: 10, blocked: false, now: start)), "Unchanged clipboard was captured")
        let first = try attempt(cursor.observe(change: 11, blocked: false, now: start))
        try require(first.change == 11 && cursor.finish(first, resolution: .retryable, now: start) == .pending,
                    "First unavailable read committed its generation")
        let retry = try attempt(cursor.observe(change: 11, blocked: false, now: start.advanced(by: .milliseconds(500))))
        try require(retry == first && cursor.finish(retry, resolution: .commit) == .committed,
                    "Same-generation ready data could not commit")
        try require(idle(cursor.observe(change: 11, blocked: false)), "Committed generation was captured twice")

        for next in [12, 4] {
            cursor.resetBaseline(to: 10, blocked: false)
            let old = try attempt(cursor.observe(change: 11, blocked: false, now: start))
            let newer = try attempt(cursor.observe(change: next, blocked: false, now: start))
            try require(newer.change == next && newer != old, "Changed counter did not replace pending request")
            try require(cursor.finish(old, resolution: .commit) == .stale
                        && cursor.finish(old, resolution: .retryable) == .stale,
                        "Old snapshot consumed the new generation")
            try require(cursor.finish(newer, resolution: .commit) == .committed, "New generation was skipped after invalidation")
        }

        cursor.resetBaseline(to: 10, blocked: false)
        let beforeReset = try attempt(cursor.observe(change: 11, blocked: false, now: start))
        cursor.resetBaseline(to: 10, blocked: false)
        let afterReset = try attempt(cursor.observe(change: 11, blocked: false, now: start))
        try require(beforeReset != afterReset && cursor.finish(beforeReset, resolution: .commit) == .stale
                    && cursor.finish(afterReset, resolution: .commit) == .committed,
                    "Baseline reset allowed a stale same-count result to commit")
        try require(cursor.finish(afterReset, resolution: .commit) == .stale, "Completed attempt was reusable")

        cursor.resetBaseline(to: 10, blocked: false)
        let beforeReturn = try attempt(cursor.observe(change: 11, blocked: false, now: start))
        try require(cursor.finish(beforeReturn, resolution: .retryable, now: start) == .pending,
                    "Counter-return fixture did not stay pending")
        try require(idle(cursor.observe(change: 10, blocked: false, now: start.advanced(by: .milliseconds(500)))),
                    "Returning to committed generation was not idle")
        try require(cursor.finish(beforeReturn, resolution: .commit) == .stale
                    && cursor.finish(beforeReturn, resolution: .retryable) == .stale,
                    "Returning to committed generation did not invalidate old pending")
        let restartedAt = start.advanced(by: .seconds(2))
        let afterReturn = try attempt(cursor.observe(change: 11, blocked: false, now: restartedAt))
        try require(afterReturn != beforeReturn, "Reappearing generation reused the old request identity")
        for index in 0...ClipboardChangeCursor.maximumRetries {
            let now = restartedAt.advanced(by: .milliseconds(index * 400))
            let current = try attempt(cursor.observe(change: 11, blocked: false, now: now))
            try require(current == afterReturn
                        && cursor.finish(current, resolution: .retryable, now: now)
                            == (index < ClipboardChangeCursor.maximumRetries ? .pending : .exhausted),
                        "Reappearing generation inherited the old retry budget or deadline")
        }

        cursor.resetBaseline(to: 10, blocked: false)
        let invalidated = try attempt(cursor.observe(change: 11, blocked: false, now: start))
        cursor.resetBaseline(to: 12, blocked: false)
        try require(!cursor.resetBaseline(to: 13, blocked: false, ifPending: invalidated),
                    "Late invalidation advanced the already-reset baseline")
        let copiedAfterReset = try attempt(cursor.observe(change: 13, blocked: false, now: start))
        try require(!cursor.resetBaseline(to: 14, blocked: true, ifPending: invalidated)
                    && cursor.finish(copiedAfterReset, resolution: .commit) == .committed,
                    "Late invalidation discarded a new request or changed its blocked state")
        let active = try attempt(cursor.observe(change: 14, blocked: false, now: start))
        try require(cursor.resetBaseline(to: 15, blocked: true, ifPending: active)
                    && cursor.finish(active, resolution: .commit) == .stale,
                    "Current privacy invalidation did not advance baseline and discard pending")
        try require(idle(cursor.observe(change: 16, blocked: false, now: start)),
                    "Current privacy invalidation backfilled resumed content")
        _ = try attempt(cursor.observe(change: 17, blocked: false, now: start))

        cursor = ClipboardChangeCursor()
        try require(!cursor.resetBaseline(to: 18, blocked: true, ifPending: active)
                    && idle(cursor.observe(change: 19, blocked: false, now: start)),
                    "Stopped lifecycle accepted an old invalidation callback")

        cursor.resetBaseline(to: 10, blocked: false)
        let limited = try attempt(cursor.observe(change: 11, blocked: false, now: start))
        for index in 0...ClipboardChangeCursor.maximumRetries {
            let now = start.advanced(by: .milliseconds(index * 400))
            let current = try attempt(cursor.observe(change: 11, blocked: false, now: now))
            let result = cursor.finish(current, resolution: .retryable, now: now)
            try require(current == limited && result == (index < ClipboardChangeCursor.maximumRetries ? .pending : .exhausted),
                        "Retry budget was not initial attempt plus three retries")
        }
        try require(idle(cursor.observe(change: 11, blocked: false)), "Exhausted generation kept polling data")
        _ = try attempt(cursor.observe(change: 12, blocked: false))

        cursor.resetBaseline(to: 20, blocked: false)
        let expiring = try attempt(cursor.observe(change: 21, blocked: false, now: start))
        try require(cursor.finish(expiring, resolution: .retryable, now: start) == .pending, "Expiry fixture did not stay pending")
        guard case .expired = cursor.observe(change: 21, blocked: false, now: start.advanced(by: .seconds(2))) else {
            throw CheckFailure("Retry deadline permitted another data read")
        }
        try require(idle(cursor.observe(change: 21, blocked: false)), "Expired generation emitted repeated expiry")
        cursor.resetBaseline(to: 20, blocked: false)
        let slow = try attempt(cursor.observe(change: 21, blocked: false, now: start))
        try require(cursor.finish(slow, resolution: .retryable, now: start.advanced(by: .seconds(2))) == .exhausted,
                    "Slow provider extended retry deadline")

        for reset in [false, true] {
            cursor.resetBaseline(to: 30, blocked: false)
            let pending = try attempt(cursor.observe(change: 31, blocked: false, now: start))
            if reset { cursor.resetBaseline(to: 32, blocked: true) }
            else { try require(idle(cursor.observe(change: 32, blocked: true)), "Blocked cursor captured content") }
            try require(cursor.finish(pending, resolution: .commit) == .stale, "Blocked cursor retained old pending result")
            try require(idle(cursor.observe(change: 33, blocked: false)) && idle(cursor.observe(change: 33, blocked: false)),
                        "Resume backfilled blocked content")
            let resumed = try attempt(cursor.observe(change: 34, blocked: false))
            try require(cursor.finish(resumed, resolution: .commit) == .committed, "First post-resume new copy was lost")
        }

        cursor.resetBaseline(to: 40, blocked: false)
        let delayed = try attempt(cursor.observe(change: 41, blocked: false, now: start))
        let types = [["public.utf8-plain-text"], ["public.url"]]
        let incomplete = try ClipboardCapturePolicy.capture(itemTypes: types, source: "Synthetic", bundleID: "local.synthetic") { item, _ in
            item == 0 ? Data("ready first item".utf8) : nil
        }
        guard case .retryable = incomplete else { throw CheckFailure("Missing required data was ignored or partially saved") }
        try require(cursor.finish(delayed, resolution: .retryable, now: start) == .pending, "Delayed payload consumed generation")
        let delayedRetry = try attempt(cursor.observe(change: 41, blocked: false, now: start.advanced(by: .milliseconds(500))))
        let complete = try ClipboardCapturePolicy.capture(itemTypes: types, source: "Synthetic", bundleID: "local.synthetic") { item, _ in
            Data((item == 0 ? "ready first item" : "https://example.invalid/ready").utf8)
        }
        guard case .ready(let capture) = complete else { throw CheckFailure("Ready same-generation payload was not captured") }
        try require(capture.representations.count == 2 && capture.searchText.contains("ready first item")
                    && cursor.finish(delayedRetry, resolution: .commit) == .committed,
                    "Delayed payload did not preserve all items or commit once")

        for empty in [[], [[]]] as [[[String]]] {
            let result = try ClipboardCapturePolicy.capture(itemTypes: empty, source: "Synthetic", bundleID: "") { _, _ in
                throw CheckFailure("Empty declaration invoked data provider")
            }
            guard case .retryable = result else { throw CheckFailure("Empty declaration was permanently ignored") }
        }
        cursor.resetBaseline(to: 50, blocked: false)
        let sensitiveAttempt = try attempt(cursor.observe(change: 51, blocked: false, now: start))
        try require(cursor.finish(sensitiveAttempt, resolution: .retryable, now: start) == .pending,
                    "Sensitive-arrival fixture did not stay pending")
        for type in ClipboardCapturePolicy.sensitiveTypes {
            let result = try ClipboardCapturePolicy.capture(itemTypes: [[], [type]], source: "Synthetic", bundleID: "") { _, _ in
                throw CheckFailure("Sensitive retry invoked data provider")
            }
            guard case .ignored = result else { throw CheckFailure("Late sensitive marker was retried") }
        }
        try require(cursor.finish(sensitiveAttempt, resolution: .commit) == .committed
                    && idle(cursor.observe(change: 51, blocked: false)), "Sensitive generation remained retryable")
    }

    private static func capturePolicy(_ directory: URL) async throws {
        try require(!ClipboardCapturePolicy.isBlocked(sleeping: false, sessionInactive: false, onConsole: true,
                                                      loginComplete: true, secureInput: false), "Active known session was blocked")
        for state in [(true, false, Optional(true), Optional(true), false),
                      (false, true, Optional(true), Optional(true), false),
                      (false, false, Optional(false), Optional(true), false),
                      (false, false, Optional(true), Optional(false), false),
                      (false, false, nil, Optional(true), false),
                      (false, false, Optional(true), nil, false),
                      (false, false, Optional(true), Optional(true), true)] {
            try require(ClipboardCapturePolicy.isBlocked(sleeping: state.0, sessionInactive: state.1, onConsole: state.2,
                                                         loginComplete: state.3, secureInput: state.4), "Unknown/blocked session was not fail-closed")
        }
        var reads = 0
        for type in ClipboardCapturePolicy.sensitiveTypes {
            let sensitive = try ClipboardCapturePolicy.capture(itemTypes: [["public.utf8-plain-text"], [type]],
                                                                source: "Synthetic", bundleID: "") { _, _ in
                reads += 1
                return Data("must not be read".utf8)
            }
            guard case .ignored = sensitive else { throw CheckFailure("Sensitive item was not ignored") }
            try require(reads == 0, "Sensitive item invoked data provider")
        }
        let unsupported = try ClipboardCapturePolicy.capture(itemTypes: [["local.unsupported"]], source: "Synthetic", bundleID: "") { _, _ in
            reads += 1
            return Data([1])
        }
        guard case .ignored = unsupported else { throw CheckFailure("Unsupported item was not ignored") }
        try require(reads == 0, "Unsupported item invoked data provider")
        try await expectError(.unsupported) {
            _ = try ClipboardCapturePolicy.capture(itemTypes: Array(repeating: ["public.utf8-plain-text"], count: 25),
                                                    source: "Synthetic", bundleID: "") { _, _ in
                reads += 1
                return Data([1])
            }
        }
        try require(reads == 0, "Over-item-budget capture invoked provider")
        let tooLarge = Data(repeating: 0x61, count: StorageLimits.maximumRepresentationBytes + 1)
        let optional = try ClipboardCapturePolicy.capture(itemTypes: [["public.utf8-plain-text", "public.html", "public.png"]],
                                                           source: "Synthetic", bundleID: "local.synthetic") { _, type in
            type == "public.utf8-plain-text" ? Data("required text".utf8) : tooLarge
        }
        guard case .ready(let optional) = optional else { throw CheckFailure("Required text was suppressed") }
        try require(optional.representations.count == 1 && optional.kind == .text && optional.searchText == "required text",
                    "Oversized optional image/HTML suppressed required text")
        try await expectError(.unsupported) {
            _ = try ClipboardCapturePolicy.capture(itemTypes: [["public.utf8-plain-text"]], source: "Synthetic", bundleID: "") { _, _ in tooLarge }
        }
        let unavailable = try ClipboardCapturePolicy.capture(itemTypes: [["public.utf8-plain-text"], ["public.url"]],
                                                             source: "Synthetic", bundleID: "") { item, _ in
            item == 0 ? Data("first must not be saved alone".utf8) : nil
        }
        guard case .retryable = unavailable else { throw CheckFailure("Unavailable item was not retryable") }
        let urls = [directory.appendingPathComponent("first.txt"), directory.appendingPathComponent("second.pdf")]
        let unavailableFile = try ClipboardCapturePolicy.capture(itemTypes: [["public.file-url"], ["public.file-url", "public.png"]],
                                                                 source: "Synthetic", bundleID: "") { item, type in
            if type == "public.png" { return image }
            return item == 0 ? Data(urls[0].absoluteString.utf8) : nil
        }
        guard case .retryable = unavailableFile else { throw CheckFailure("Unavailable file URL was replaced by optional pixels") }
        for data in [Data(), Data("not a file URL".utf8), tooLarge] {
            try await expectError(.unsupported) {
                _ = try ClipboardCapturePolicy.capture(itemTypes: [["public.file-url"]], source: "Synthetic", bundleID: "") { _, _ in data }
            }
        }
        try await expectError(.unsupported) {
            _ = try ClipboardCapturePolicy.capture(itemTypes: [["public.utf8-plain-text"]], source: "Synthetic", bundleID: "") { _, _ in Data() }
        }
        let optionalMissing = try ClipboardCapturePolicy.capture(itemTypes: [["public.utf8-plain-text", "public.html"]],
                                                                 source: "Synthetic", bundleID: "") { _, type in
            type == "public.html" ? nil : Data("required content".utf8)
        }
        guard case .ready = optionalMissing else { throw CheckFailure("Unavailable optional format delayed a complete item") }
        try await expectError(.unsupported) {
            _ = try ClipboardCapturePolicy.capture(itemTypes: [["public.utf8-plain-text"], ["public.file-url"]],
                                                    source: "Synthetic", bundleID: "") { item, _ in
                item == 0 ? nil : Data("invalid required URL".utf8)
            }
        }
        let largePixel = Data(repeating: 0x62, count: StorageLimits.maximumRepresentationBytes)
        let files = try ClipboardCapturePolicy.capture(itemTypes: [["public.png", "public.file-url"], ["public.png", "public.file-url"]],
                                                        source: "Synthetic", bundleID: "") { item, type in
            type == "public.file-url" ? Data(urls[item].absoluteString.utf8) : largePixel
        }
        guard case .ready(let files) = files else { throw CheckFailure("Multi-file capture unexpectedly missing") }
        try require(files.representations.filter { $0.type == "public.file-url" }.count == 2 && files.kind == .file,
                    "Optional pixels displaced a required file URL")
        try require(files.representations.reduce(0) { $0 + $1.data.count } <= StorageLimits.maximumCaptureBytes,
                    "Capture exceeded aggregate byte budget")
        try require(files.searchText == "first.txt\nsecond.pdf" && !files.searchText.contains(directory.path),
                    "File search projection leaked directory paths")
        let fallback = try ClipboardCapturePolicy.capture(itemTypes: [["public.png", "public.jpeg"]], source: "Synthetic", bundleID: "") { _, type in
            type == "public.png" ? nil : image
        }
        guard case .ready(let fallback) = fallback else { throw CheckFailure("Missing image representation had no fallback") }
        try require(fallback.representations.count == 1 && fallback.representations[0].type == "public.jpeg",
                    "Missing first image provider did not fall back to next supported representation")
    }

    /// Pure event sequences reproduce await-time focus races without AppKit, AX, or a running app.
    private static func globalShortcut(_: URL) async throws {
        let expected = GlobalShortcut(keyCode: UInt32(kVK_ANSI_V),
                                      modifiers: UInt32(cmdKey) | UInt32(shiftKey), label: "V")
        try require(GlobalShortcut.defaultShortcut == expected, "Default shortcut must be Command-Shift-V")
        try require(expected.display == "⇧⌘V", "Default shortcut display must use macOS modifier order")
        try require(expected.validationMessage == nil, "Command-Shift-V must pass shortcut validation")

        let suite = "cvMaster.RegressionChecks.GlobalShortcut.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw CheckFailure("Cannot create isolated shortcut preferences")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        try require(GlobalShortcut.load(from: defaults) == expected, "Unset preferences must use the new default")

        let savedShortcuts = [
            GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), label: "Space"),
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey) | UInt32(shiftKey), label: "H")
        ]
        for shortcut in savedShortcuts {
            shortcut.save(to: defaults)
            try require(GlobalShortcut.load(from: defaults) == shortcut, "Saved shortcuts must not be overwritten by the new default")
        }
        GlobalShortcut.defaultShortcut.save(to: defaults)
        try require(GlobalShortcut.load(from: defaults) == expected, "Reset default must persist Command-Shift-V")

        let commandV = GlobalShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey), label: "V")
        try require(commandV.validationMessage != nil, "Command-V alone must still be rejected")
    }

    private static func pasteHandoff(_: URL) async throws {
        let own: Int32 = 1_001, original: Int32 = 2_002, unrelated: Int32 = 3_003
        let target = UUID(), otherTarget = UUID()

        func opened(ownActivationDelivered: Bool = true) -> PasteHandoffPolicy {
            var policy = PasteHandoffPolicy(ownProcessIdentifier: own, initiallyActiveProcessIdentifier: original)
            policy.panelWillOpen(targetID: target, processIdentifier: original, frontmostProcessIdentifier: original)
            if ownActivationDelivered { policy.applicationActivated(own) }
            return policy
        }

        func loading() throws -> PasteHandoffPolicy {
            var policy = opened()
            try require(policy.beginRequest(targetID: target, processIdentifier: original,
                                            frontmostProcessIdentifier: own, panelIsShown: true),
                        "Initial paste request was not bound to its open panel")
            return policy
        }

        func restoring() throws -> PasteHandoffPolicy {
            var policy = try loading()
            try require(policy.beginPreparation(targetID: target, frontmostProcessIdentifier: own,
                                                ownApplicationIsActive: true, panelIsShown: true),
                        "Uninterrupted loading request could not begin restoration")
            policy.panelDidClose()
            return policy
        }

        // Current frontmost PID alone cannot acknowledge delayed restoration; the expected event must arrive.
        var delayed = try restoring()
        let beforeActivation = delayed.focusGeneration
        try require(delayed.preparationIsValid(targetID: target, frontmostProcessIdentifier: own),
                    "Restoration did not allow waiting while own application was still frontmost")
        try require(delayed.preparationIsValid(targetID: target, frontmostProcessIdentifier: original),
                    "Restoration rejected the target PID before its delayed activation notification")
        try require(!delayed.restorationAcknowledged(targetID: target) && !delayed.markPrepared(targetID: target),
                    "Polling the target PID incorrectly acknowledged restoration")
        delayed.applicationActivated(original)
        try require(delayed.focusGeneration == beforeActivation + 1 && delayed.restorationAcknowledged(targetID: target),
                    "Expected target activation was not acknowledged at its actual generation")
        try require(delayed.preparationIsValid(targetID: target, frontmostProcessIdentifier: original)
                    && delayed.markPrepared(targetID: target), "Acknowledged restoration could not become prepared")
        try require(delayed.isPrepared(targetID: target, frontmostProcessIdentifier: original), "Prepared request was not usable")
        try require(!delayed.isPrepared(targetID: otherTarget, frontmostProcessIdentifier: original)
                    && !delayed.isPrepared(targetID: target, frontmostProcessIdentifier: unrelated),
                    "Prepared request was rebound to a different target or frontmost process")
        try require(delayed.mayPresentFailure, "Uninterrupted request lost safe failure presentation")
        delayed.finishRequest()
        try require(!delayed.isPrepared(targetID: target, frontmostProcessIdentifier: original)
                    && !delayed.markPrepared(targetID: target) && delayed.mayPresentFailure,
                    "Finished request was reusable or lost its failure-presentation decision")

        // A nonactivating panel leaves A continuously frontmost, so no nonexistent new A event is required.
        var alreadyActive = opened(ownActivationDelivered: false)
        try require(alreadyActive.beginRequest(targetID: target, processIdentifier: original,
                                              frontmostProcessIdentifier: original, panelIsShown: true),
                    "Already-frontmost original process could not start a request")
        try require(alreadyActive.beginPreparation(targetID: target, frontmostProcessIdentifier: original,
                                                   ownApplicationIsActive: false, panelIsShown: true),
                    "Already-frontmost original process could not prepare")
        try require(!alreadyActive.restorationAcknowledged(targetID: target) && !alreadyActive.markPrepared(targetID: target),
                    "Prepared state did not require intentional panel-close acknowledgement")
        alreadyActive.panelDidClose()
        try require(alreadyActive.focusGeneration == 0 && alreadyActive.restorationAcknowledged(targetID: target)
                    && alreadyActive.markPrepared(targetID: target)
                    && alreadyActive.isPrepared(targetID: target, frontmostProcessIdentifier: original),
                    "Continuously active target incorrectly required an extra activation event")

        // One delayed popup-own event is expected during loading or restoration, never a reusable exception.
        for duringRestoration in [false, true] {
            var lateOwn = opened(ownActivationDelivered: false)
            try require(lateOwn.beginRequest(targetID: target, processIdentifier: original,
                                            frontmostProcessIdentifier: own, panelIsShown: true), "Late-own request rejected")
            if duringRestoration {
                try require(lateOwn.beginPreparation(targetID: target, frontmostProcessIdentifier: own,
                                                     ownApplicationIsActive: true, panelIsShown: true), "Late-own preparation rejected")
                lateOwn.panelDidClose()
            }
            lateOwn.applicationActivated(own)
            if !duringRestoration {
                try require(lateOwn.beginPreparation(targetID: target, frontmostProcessIdentifier: own,
                                                     ownApplicationIsActive: true, panelIsShown: true),
                            "Expected popup activation invalidated loading request")
                lateOwn.panelDidClose()
            }
            lateOwn.applicationActivated(original)
            try require(lateOwn.restorationAcknowledged(targetID: target) && lateOwn.markPrepared(targetID: target),
                        "Expected own/target activation pair did not complete restoration")
            lateOwn.applicationActivated(own)
            try require(!lateOwn.isPrepared(targetID: target, frontmostProcessIdentifier: original) && !lateOwn.mayPresentFailure,
                        "A second own activation reused the popup exception")
        }

        // User actions during content loading invalidate the original request permanently, even after A returns.
        for event in ["switch", "switch-back", "close", "close-back", "duplicate-own", "unknown"] {
            var interrupted = try loading()
            switch event {
            case "switch": interrupted.applicationActivated(unrelated)
            case "switch-back": interrupted.applicationActivated(unrelated); interrupted.applicationActivated(original)
            case "close": interrupted.panelDidClose()
            case "close-back": interrupted.panelDidClose(); interrupted.applicationActivated(original)
            case "duplicate-own": interrupted.applicationActivated(own)
            default: interrupted.applicationActivated(nil)
            }
            try require(!interrupted.beginPreparation(targetID: target, frontmostProcessIdentifier: original,
                                                      ownApplicationIsActive: false, panelIsShown: true),
                        "Loading-time \(event) was adopted by a late preparation")
            try require(!interrupted.beginRequest(targetID: target, processIdentifier: original,
                                                  frontmostProcessIdentifier: original, panelIsShown: true)
                        && !interrupted.mayPresentFailure, "Invalidated \(event) request was rebound or allowed focus-stealing failure UI")
        }

        // Duplicate close delivery is idempotent after intentional closure, both while restoring and prepared.
        for prepared in [false, true] {
            var duplicateClose = try restoring()
            if prepared {
                duplicateClose.applicationActivated(original)
                try require(duplicateClose.markPrepared(targetID: target), "Duplicate-close fixture was not prepared")
            }
            let dismissal = duplicateClose.dismissalGeneration
            duplicateClose.panelDidClose()
            try require(duplicateClose.dismissalGeneration == dismissal && duplicateClose.mayPresentFailure,
                        "Duplicate close changed the dismissal generation or invalidated the request")
            if prepared {
                try require(duplicateClose.isPrepared(targetID: target, frontmostProcessIdentifier: original),
                            "Duplicate close invalidated a prepared request")
            } else {
                duplicateClose.applicationActivated(original)
                try require(duplicateClose.markPrepared(targetID: target),
                            "Duplicate close prevented a restoring request from completing")
            }
        }

        // Current-active confirmation does not require a duplicate activation event, but never adopts another target.
        var currentActive = try restoring()
        let activeGeneration = currentActive.focusGeneration
        try require(currentActive.confirmActiveTarget(targetID: target, frontmostProcessIdentifier: original,
                                                      targetIsActive: true)
                    && currentActive.focusGeneration == activeGeneration && currentActive.markPrepared(targetID: target)
                    && currentActive.isPrepared(targetID: target, frontmostProcessIdentifier: original),
                    "Stable active target could not prepare without a duplicate activation notification")
        for mismatch in ["target", "frontmost", "unknown-frontmost", "inactive", "not-closed", "third-party", "finished"] {
            var policy = try restoring()
            if mismatch == "not-closed" {
                policy = try loading()
                try require(policy.beginPreparation(targetID: target, frontmostProcessIdentifier: own,
                                                     ownApplicationIsActive: true, panelIsShown: true),
                            "Unclosed confirmation fixture could not prepare")
            } else if mismatch == "third-party" {
                policy.applicationActivated(unrelated)
                policy.applicationActivated(original)
            } else if mismatch == "finished" {
                policy.finishRequest()
            }
            let frontmost: Int32? = mismatch == "unknown-frontmost" ? nil : mismatch == "frontmost" ? unrelated : original
            try require(!policy.confirmActiveTarget(targetID: mismatch == "target" ? otherTarget : target,
                                                    frontmostProcessIdentifier: frontmost,
                                                    targetIsActive: mismatch != "inactive"),
                        "Current-active confirmation accepted \(mismatch)")
        }

        // Reopening after failure creates a fresh panel and request; closing that new panel still invalidates it.
        var retry = try restoring()
        retry.finishRequest()
        let retryTarget = UUID()
        let previousPanel = retry.panelGeneration
        retry.panelWillOpen(targetID: retryTarget, processIdentifier: original, frontmostProcessIdentifier: original)
        try require(retry.panelGeneration == previousPanel + 1
                    && retry.beginRequest(targetID: retryTarget, processIdentifier: original,
                                          frontmostProcessIdentifier: original, panelIsShown: true),
                    "Reopened failure panel could not start a fresh request")
        try require(!retry.isPrepared(targetID: target, frontmostProcessIdentifier: original),
                    "Reopened failure panel retained the previous preparation")
        var successfulRetry = retry
        try require(successfulRetry.beginPreparation(targetID: retryTarget, frontmostProcessIdentifier: original,
                                                      ownApplicationIsActive: false, panelIsShown: true),
                    "Reopened failure panel could not prepare its fresh request")
        successfulRetry.panelDidClose()
        try require(successfulRetry.confirmActiveTarget(targetID: retryTarget, frontmostProcessIdentifier: original,
                                                        targetIsActive: true)
                    && successfulRetry.markPrepared(targetID: retryTarget)
                    && successfulRetry.isPrepared(targetID: retryTarget, frontmostProcessIdentifier: original),
                    "Fresh retry request could not complete preparation")
        retry.panelDidClose()
        try require(!retry.beginPreparation(targetID: retryTarget, frontmostProcessIdentifier: original,
                                            ownApplicationIsActive: false, panelIsShown: false)
                    && !retry.confirmActiveTarget(targetID: retryTarget, frontmostProcessIdentifier: original,
                                                  targetIsActive: true),
                    "Closing the new failure panel did not invalidate its request")

        // Unexpected transitions while restoring or prepared cannot be repaired by returning to A.
        for phase in ["restoring", "prepared"] {
            for event in ["switch-back", "duplicate-target", "unknown"] {
                var interrupted = try restoring()
                if phase == "prepared" || event == "duplicate-target" {
                    interrupted.applicationActivated(original)
                }
                if phase == "prepared" {
                    try require(interrupted.markPrepared(targetID: target), "Prepared interruption fixture was not prepared")
                }
                switch event {
                case "switch-back": interrupted.applicationActivated(unrelated); interrupted.applicationActivated(original)
                case "duplicate-target": interrupted.applicationActivated(original)
                default: interrupted.applicationActivated(nil)
                }
                try require(!interrupted.restorationAcknowledged(targetID: target)
                            && !interrupted.isPrepared(targetID: target, frontmostProcessIdentifier: original)
                            && !interrupted.markPrepared(targetID: target) && !interrupted.mayPresentFailure,
                            "\(phase)-time \(event) did not permanently invalidate handoff")
            }
        }

        // Initial target/process/panel identity is fixed before loading, not inferred later from the PID.
        for mismatch in ["target", "process", "frontmost", "unknown-frontmost", "hidden-panel"] {
            var policy = opened()
            let frontmost: Int32? = mismatch == "unknown-frontmost" ? nil : mismatch == "frontmost" ? unrelated : own
            try require(!policy.beginRequest(targetID: mismatch == "target" ? otherTarget : target,
                                              processIdentifier: mismatch == "process" ? unrelated : original,
                                              frontmostProcessIdentifier: frontmost, panelIsShown: mismatch != "hidden-panel"),
                        "Initial \(mismatch) mismatch was accepted")
        }
        for mismatch in ["target", "frontmost", "hidden-panel"] {
            var policy = try loading()
            try require(!policy.beginPreparation(targetID: mismatch == "target" ? otherTarget : target,
                                                 frontmostProcessIdentifier: mismatch == "frontmost" ? unrelated : own,
                                                 ownApplicationIsActive: true, panelIsShown: mismatch != "hidden-panel"),
                        "Preparation rebound an initial \(mismatch) mismatch")
        }
        var reused = try loading()
        try require(reused.beginPreparation(targetID: target, frontmostProcessIdentifier: own,
                                            ownApplicationIsActive: true, panelIsShown: true), "Single-use fixture could not prepare")
        try require(!reused.beginPreparation(targetID: target, frontmostProcessIdentifier: own,
                                             ownApplicationIsActive: true, panelIsShown: true), "Preparation was reusable for the same request")
        var reopened = try loading()
        reopened.panelWillOpen(targetID: otherTarget, processIdentifier: original, frontmostProcessIdentifier: own)
        try require(!reopened.beginPreparation(targetID: target, frontmostProcessIdentifier: own,
                                               ownApplicationIsActive: true, panelIsShown: true), "Old request survived a new panel generation")
        var noPanel = PasteHandoffPolicy(ownProcessIdentifier: own, initiallyActiveProcessIdentifier: original)
        try require(!noPanel.beginRequest(targetID: target, processIdentifier: original,
                                          frontmostProcessIdentifier: original, panelIsShown: true), "Request started without a captured panel target")
    }

    /// Only synthetic identities and observations enter this suite; no AX or clipboard API is loaded.
    private static func pasteFocusRestoration(_: URL) async throws {
        let target = UUID(), otherTarget = UUID()
        let now = ContinuousClock.now
        let deadline = now.advanced(by: .seconds(1))
        let observations: [PasteFocusObservation] = [.original, .missingInput, .originalInputContainer,
                                                     .differentInput, .differentWindow]

        func request(hasSavedInput: Bool = true) -> PasteFocusRestorationRequest {
            PasteFocusRestorationRequest(targetID: target, hasSavedInput: hasSavedInput, deadline: deadline)
        }

        func requireRejected(_ request: PasteFocusRestorationRequest, _ context: String,
                             at instant: ContinuousClock.Instant) throws {
            try require(!request.isValid(now: instant), "\(context) retained a valid restoration permit")
            for _ in 0..<2 {
                for observation in observations {
                    try require(request.action(for: observation, targetID: target, now: instant) == .reject,
                                "\(context) revived when the original target/focus returned")
                }
            }
        }

        let original = request()
        try require(original.isValid(now: now), "Fresh focus request was invalid")
        for _ in 0..<4 {
            try require(original.action(for: .original, targetID: target, now: now) == .ready,
                        "Original input requested restoration instead of being immediately ready")
        }
        try require(original.action(for: .missingInput, targetID: target, now: now) == .restoreSavedInput,
                    "Readiness incorrectly consumed the unused restoration permit")

        for lostFocus in [PasteFocusObservation.missingInput, .originalInputContainer] {
            let recovering = request()
            try require(recovering.action(for: lostFocus, targetID: target, now: now) == .restoreSavedInput,
                        "Recoverable original-window focus loss was not granted one restoration")
            for _ in 0..<4 {
                for observation in [PasteFocusObservation.missingInput, .originalInputContainer] {
                    try require(recovering.action(for: observation, targetID: target, now: now) == .wait,
                                "Repeated or alternating focus loss issued another restoration")
                }
            }
            try require(recovering.action(for: .original, targetID: target, now: now) == .ready,
                        "Restored original input did not become ready")
            try require(recovering.action(for: lostFocus, targetID: target, now: now) == .wait,
                        "Returning to original input reset the per-request restoration budget")
            try require(recovering.action(for: .original, targetID: target, now: now) == .ready
                        && recovering.isValid(now: now), "Waiting invalidated an otherwise unchanged original target")
        }

        // Production maps (saved input: none, current input: none) to .original, not .missingInput.
        let noInput = request(hasSavedInput: false)
        try require(noInput.action(for: .original, targetID: target, now: now) == .ready,
                    "Stable original window without an exposed input node could not become ready")
        for lostFocus in [PasteFocusObservation.missingInput, .originalInputContainer] {
            let unavailable = request(hasSavedInput: false)
            try require(unavailable.action(for: lostFocus, targetID: target, now: now) == .reject,
                        "Request without a saved input node was allowed to restore focus")
            try requireRejected(unavailable, "Missing saved input", at: now)
        }

        // Cancellation (including production error handling) and identity changes permanently revoke this request.
        for interruption in ["cancel", "deadline", "wrong-target", "different-input", "different-window"] {
            for restorationAlreadyGranted in [false, true] {
                let interrupted = request()
                if restorationAlreadyGranted {
                    try require(interrupted.action(for: .missingInput, targetID: target, now: now) == .restoreSavedInput,
                                "Interruption fixture did not obtain its initial restoration permit")
                }
                let rejectedAt: ContinuousClock.Instant
                switch interruption {
                case "cancel":
                    interrupted.cancel()
                    interrupted.cancel() // Idempotent, including cancellation before any restoration is granted.
                    rejectedAt = now
                case "deadline":
                    try require(interrupted.isValid(now: deadline.advanced(by: .nanoseconds(-1)))
                                && interrupted.action(for: .original, targetID: target,
                                                      now: deadline.advanced(by: .nanoseconds(-1))) == .ready,
                                "Focus request expired before its exact deadline")
                    try require(interrupted.action(for: .original, targetID: target, now: deadline) == .reject,
                                "Focus request accepted its inclusive expiration boundary")
                    rejectedAt = deadline.advanced(by: .nanoseconds(1))
                case "wrong-target":
                    try require(interrupted.action(for: .original, targetID: otherTarget, now: now) == .reject,
                                "Focus request accepted a different target identity")
                    rejectedAt = now
                default:
                    let observation: PasteFocusObservation = interruption == "different-input" ? .differentInput : .differentWindow
                    try require(interrupted.action(for: observation, targetID: target, now: now) == .reject,
                                "Focus request accepted a different input or window")
                    rejectedAt = now
                }
                try requireRejected(interrupted, "\(interruption), restoration granted=\(restorationAlreadyGranted)", at: rejectedAt)

                let fresh = request()
                try require(fresh.action(for: .original, targetID: target, now: now) == .ready
                            && fresh.action(for: .missingInput, targetID: target, now: now) == .restoreSavedInput
                            && fresh.action(for: .originalInputContainer, targetID: target, now: now) == .wait,
                            "\(interruption) leaked cancellation or a spent permit into a new request for the same target")
                try requireRejected(interrupted, "Old request after independent new request", at: rejectedAt)
            }
        }

        // Child tasks race the real production lock, not a serialized synthetic replacement.
        let callers = 64
        for _ in 0..<8 {
            let concurrent = request()
            let counts = await withTaskGroup(of: (restore: Bool, wait: Bool).self) { group in
                for index in 0..<callers {
                    let observation: PasteFocusObservation = index.isMultiple(of: 2) ? .missingInput : .originalInputContainer
                    group.addTask {
                        let action = concurrent.action(for: observation, targetID: target, now: now)
                        return (action == .restoreSavedInput, action == .wait)
                    }
                }
                var restores = 0, waits = 0
                for await result in group {
                    if result.restore { restores += 1 }
                    if result.wait { waits += 1 }
                }
                return (restores, waits)
            }
            try require(counts.0 == 1 && counts.1 == callers - 1,
                        "Concurrent focus checks issued multiple restorations or rejected an unchanged target")
            concurrent.cancel()
            let rejected = await withTaskGroup(of: Bool.self) { group in
                for index in 0..<callers {
                    let observation = observations[index % observations.count]
                    group.addTask {
                        concurrent.action(for: observation, targetID: target, now: now) == .reject
                            && !concurrent.isValid(now: now)
                    }
                }
                var allRejected = true
                for await result in group { allRejected = allRejected && result }
                return allRejected
            }
            try require(rejected, "A concurrent call started a new restoration after cancellation returned")

            let racingCancellation = request()
            let cancellationCounts = await withTaskGroup(of: (restore: Bool, revoked: Bool).self) { group in
                for index in 0..<callers {
                    let observation: PasteFocusObservation = index.isMultiple(of: 2) ? .missingInput : .originalInputContainer
                    group.addTask {
                        let action = racingCancellation.action(for: observation, targetID: target, now: now)
                        racingCancellation.cancel()
                        // A granted action is not permission to start a later setter after synchronous cancellation.
                        let revoked = !racingCancellation.isValid(now: now)
                            && racingCancellation.action(for: observation, targetID: target, now: now) == .reject
                            && racingCancellation.action(for: .original, targetID: target, now: now) == .reject
                        return (action == .restoreSavedInput, revoked)
                    }
                }
                var restores = 0, allRevoked = true
                for await result in group {
                    if result.restore { restores += 1 }
                    allRevoked = allRevoked && result.revoked
                }
                return (restores, allRevoked)
            }
            try require(cancellationCounts.0 == 1 && cancellationCounts.1,
                        "Racing cancellation allowed a duplicate restoration or a post-cancel permission")
            try requireRejected(racingCancellation, "Concurrent action/cancel race", at: now)
        }
    }

    private static func requireBoundedMetadata(_ value: ClipCapture) throws {
        try require(value.title.utf8.count <= 4_096 && value.title.count <= 120, "Capture title exceeds metadata bounds")
        try require(value.excerpt.utf8.count <= 8_192 && value.excerpt.count <= 240, "Capture excerpt exceeds metadata bounds")
        try require(value.searchText.utf8.count <= 131_072 && value.searchText.count <= 32_768,
                    "Capture search text exceeds shared output bounds")
        try require(value.source.utf8.count <= 1_024 && value.sourceBundleID.utf8.count <= 1_024,
                    "Capture source metadata exceeds bounds")
    }

    private static func requireBoundedClip(_ value: Clip) throws {
        try require(value.title.utf8.count <= 4_096 && value.title.count <= 120, "Page title exceeds metadata bounds")
        try require(value.excerpt.utf8.count <= 8_192 && value.excerpt.count <= 240, "Page excerpt exceeds metadata bounds")
        try require(value.source.utf8.count <= 1_024 && value.sourceBundleID.utf8.count <= 1_024,
                    "Page source metadata exceeds bounds")
    }

    /// Full synthetic capture/store paths, not a string-only demonstration of grapheme amplification.
    private static func metadataBounds(_ directory: URL) async throws {
        for normal in ["Aé中😀Z", "e\u{301}", "👨‍👩‍👧‍👦"] {
            for budget in 0...32 {
                var expected = ""
                for scalar in normal.unicodeScalars {
                    guard expected.utf8.count + scalar.utf8.count <= budget else { break }
                    expected.unicodeScalars.append(scalar)
                }
                let fromString = BoundedText.prefix(normal, maximumBytes: budget)
                let fromData = BoundedText.decode(Data(normal.utf8), maximumBytes: budget)
                try require(fromString == expected && fromData == expected,
                            "Valid UTF-8 boundary created a replacement scalar or exceeded the byte budget")
            }
        }
        let malformed = Data([0xF0, 0x28, 0x8C, 0x28, 0xFF, 0x61])
        let repaired = String(decoding: malformed, as: UTF8.self)
        for budget in 0...24 {
            let decoded = BoundedText.decode(malformed, maximumBytes: budget)
            try require(decoded == BoundedText.prefix(repaired, maximumBytes: budget) && decoded.utf8.count <= budget,
                        "Invalid UTF-8 repair is not scalar-safe and output-bounded")
        }
        let text = "e" + String(repeating: "\u{301}", count: 60_000)
        let raw = Data(text.utf8)
        let count = 24
        try require(raw.count * count <= StorageLimits.maximumCaptureBytes, "Synthetic aggregate exceeds raw capture budget")
        let result = try ClipboardCapturePolicy.capture(itemTypes: Array(repeating: ["public.utf8-plain-text"], count: count),
                                                        source: text, bundleID: String(repeating: "x", count: 1_025)) { _, _ in raw }
        guard case .ready(let captured) = result else { throw CheckFailure("Bounded metadata suppressed valid raw content") }
        try requireBoundedMetadata(captured)
        try require(captured.sourceBundleID.isEmpty && captured.representations.count == count,
                    "Oversized identity was truncated into a different ID, or raw items were lost")
        try require(captured.representations.allSatisfy { $0.data == raw }, "Metadata limits changed original capture bytes")
        let store = HistoryStore(directory: directory)
        try await store.save(captured, retention: 0)
        let first = try await page(store)
        guard let clip = first.clips.first else { throw CheckFailure("Bounded capture was not saved") }
        try requireBoundedClip(clip)
        let restored = try await store.representations(clip.id)
        try require(restored.count == count, "Multi-item raw recovery lost an item")
        for (original, recovered) in zip(captured.representations, restored) {
            try require(original.item == recovered.item && original.type == recovered.type && original.data == recovered.data,
                        "Metadata normalization altered raw representation identity or data")
        }
        let db = try FixtureDatabase(directory)
        let byteLengths = try db.rows("""
            SELECT length(CAST(title AS BLOB)),length(CAST(excerpt AS BLOB)),length(CAST(search_text AS BLOB)),
                   length(CAST(source AS BLOB)),length(CAST(source_bundle_id AS BLOB)) FROM entry WHERE id=?
            """, [clip.id.uuidString])
        let limits = [4_096, 8_192, 131_072, 1_024, 1_024]
        try require(byteLengths.count == 1, "Missing persisted metadata")
        for (value, maximum) in zip(byteLengths[0], limits) {
            try require(Int(value).map { $0 <= maximum } == true, "Persisted metadata exceeds UTF-8 byte budget")
        }

        // A provider can supply a syntactically valid URL even when its basename cannot exist on disk.
        let fileName = "a" + String(repeating: "\u{301}", count: 1_000_000) + ".png"
        let fileData = Data(("file:///" + fileName).utf8)
        let files = try ClipboardCapturePolicy.capture(itemTypes: [["public.file-url"]], source: "Synthetic", bundleID: "") { _, _ in fileData }
        guard case .ready(let files) = files else { throw CheckFailure("Synthetic file URL was rejected") }
        try requireBoundedMetadata(files)
        try require(files.kind == .image && files.representations[0].data == fileData,
                    "Truncated filename changed full-extension image classification or original URL")
        try require(!files.searchText.contains("file:///"), "File metadata search includes its path")
        try await store.save(files, retention: 0)

        // Storage must defend itself even if a caller bypasses ClipboardCapturePolicy.
        let untrusted = ClipCapture(kind: .text, title: text, excerpt: text, searchText: text, source: text,
                                    sourceBundleID: String(repeating: "x", count: 1_025),
                                    representations: [ClipRepresentation(item: 0, type: "public.utf8-plain-text", data: Data("storage-only".utf8))])
        try await store.save(untrusted, retention: 0)
        let direct = try await page(store).clips.first { $0.kind == .text && $0.id != clip.id }!
        try await store.setPinned(direct.id, true)
        try await store.saveGroup(nil, name: "Preserved")
        let group = try await store.groupCatalog()[0].id
        try await store.setGroup(direct.id, group: group, included: true)
        try await store.save(untrusted, retention: 0)
        let duplicate = try await page(store).clips.first { $0.id == direct.id }!
        try requireBoundedClip(duplicate)
        try require(duplicate.copies == 2 && duplicate.pinned && duplicate.groups == [group] && duplicate.sourceBundleID.isEmpty,
                    "Metadata normalization changed duplicate/protected identity")

        // Old oversized rows stay readable without constructing unbounded Swift list strings.
        let update = try db.prepare("UPDATE entry SET title=?,excerpt=?,source=?,source_bundle_id=? WHERE id=?")
        defer { sqlite3_finalize(update) }
        try db.run(update, values: [text, text, text, String(repeating: "x", count: 1_025), direct.id.uuidString])
        let legacy = try await page(store).clips.first { $0.id == direct.id }!
        try requireBoundedClip(legacy)
        try require(legacy.sourceBundleID.isEmpty, "Legacy oversized identity was silently truncated")
        try await expectError(.nameConflict) { try await store.saveGroup(nil, name: text) }
        try require(try await store.groupCatalog().count == 1, "Rejected oversized group was persisted")
        _ = try await page(store, query: text)

        // Normal text preserves the old Character-prefix semantics while it fits the byte budget.
        for normal in ["first line\nsecond 中文", String(repeating: "中", count: 300),
                       String(repeating: "👨‍👩‍👧‍👦", count: 150), String(repeating: "e\u{301}", count: 250)] {
            let input = Data(normal.utf8)
            let result = try ClipboardCapturePolicy.capture(itemTypes: [["public.utf8-plain-text"]], source: "Synthetic", bundleID: "local.synthetic") { _, _ in input }
            guard case .ready(let value) = result else { throw CheckFailure("Normal Unicode capture failed") }
            try requireBoundedMetadata(value)
            try require(value.searchText == normal && value.excerpt == String(normal.prefix(240))
                        && value.title == String(normal.split(whereSeparator: \.isNewline).first!.prefix(120)),
                        "Normal Unicode character-prefix semantics changed")
        }
        let separatorInputs = [Data(String(repeating: "a", count: 32_767).utf8), Data("b".utf8)]
        let separated = try ClipboardCapturePolicy.capture(itemTypes: Array(repeating: ["public.utf8-plain-text"], count: 2), source: "Synthetic", bundleID: "") { index, _ in separatorInputs[index] }
        guard case .ready(let separated) = separated else { throw CheckFailure("Separator boundary capture failed") }
        try requireBoundedMetadata(separated)
        try require(separated.searchText.count <= 32_768, "Item separator was not charged to the shared character budget")

        let rtf = Data(("{\\rtf1\\ansi\\uc1 a" + String(repeating: "\\u769?", count: 30_000) + "}").utf8)
        try require(rtf.count < ClipboardFormats.maximumRichTextPreviewBytes, "Synthetic RTF exceeds parser budget")
        let rich = try ClipboardCapturePolicy.capture(itemTypes: [["public.rtf"]], source: "Synthetic", bundleID: "") { _, _ in rtf }
        guard case .ready(let rich) = rich else { throw CheckFailure("RTF-only capture failed") }
        try await store.save(rich, retention: 0)
        let richID = try db.rows("SELECT entry_id FROM representation WHERE uti='public.rtf'").first!.first!
        let richClip = try await page(store).clips.first { $0.id.uuidString == richID }!
        try requireBoundedClip(richClip)
        let richOriginals = try await store.representations(richClip.id)
        try require(richOriginals.count == 1 && richOriginals[0].data == rtf, "RTF metadata fallback changed raw bytes")
        print("  metadata amplification fixtures: 24 legal text items, 2 MB file URL, storage bypass and legacy rows")
    }

    /// A prepared reader must not collect assets belonging to another connection's uncommitted write.
    private static func recoveryIsolation(_ directory: URL) async throws {
        let store = HistoryStore(directory: directory)
        try await store.prepare()
        let db = try FixtureDatabase(directory)
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        let kept = UUID().uuidString, entry = UUID().uuidString
        let keptFile = assets.appendingPathComponent(kept)
        let orphanFile = assets.appendingPathComponent(UUID().uuidString)
        try Data([9]).write(to: orphanFile)
        try db.execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? db.execute("ROLLBACK") } }
        try Data([1, 2, 3]).write(to: keptFile)
        try db.execute("""
            INSERT INTO entry(id,fingerprint,kind,title,excerpt,search_text,source,copied_at,byte_size)
            VALUES('\(entry)','\(entry)','text','Synthetic','Synthetic','Synthetic','Synthetic',1000,3);
            INSERT INTO representation VALUES('\(kept)','\(entry)',0,'public.utf8-plain-text','\(kept)',3);
            """)
        try await expectError(.storage) { try await store.recoverAssets() }
        try require(FileManager.default.fileExists(atPath: keptFile.path)
                    && FileManager.default.fileExists(atPath: orphanFile.path),
                    "Recovery changed assets before obtaining the writer lock")
        try db.execute("COMMIT")
        committed = true
        try await store.recoverAssets()
        try require(FileManager.default.fileExists(atPath: keptFile.path)
                    && !FileManager.default.fileExists(atPath: orphanFile.path),
                    "Recovery lost a committed asset or retained a true orphan")
        let originals = try await store.representations(UUID(uuidString: entry)!)
        try require(originals.count == 1 && originals[0].data == Data([1, 2, 3]), "Committed content cannot be restored")

        let rolledBack = assets.appendingPathComponent(UUID().uuidString)
        try db.execute("BEGIN IMMEDIATE")
        committed = false
        try Data([4]).write(to: rolledBack)
        try await expectError(.storage) { try await store.recoverAssets() }
        try require(FileManager.default.fileExists(atPath: rolledBack.path), "Recovery removed an in-flight rollback asset")
        try db.execute("ROLLBACK")
        committed = true
        try await store.recoverAssets()
        try require(!FileManager.default.fileExists(atPath: rolledBack.path)
                    && FileManager.default.fileExists(atPath: keptFile.path), "Post-rollback orphan recovery is incorrect")
        try require(try db.rows("PRAGMA integrity_check").first?.first == "ok", "Recovery damaged SQLite integrity")
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func machineString(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: value.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
    }

    private static func diskBytes(_ directory: URL) throws -> Int {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        return try files.reduce(0) { $0 + ((try $1.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) }
    }

    private static func requireSamePage(_ lhs: HistoryPage, _ rhs: HistoryPage) throws {
        try require(lhs.total == rhs.total && lhs.storedEntries == rhs.storedEntries && lhs.storedBytes == rhs.storedBytes
                    && lhs.clips.count == rhs.clips.count, "Page totals or projection size differ")
        for (a, b) in zip(lhs.clips, rhs.clips) {
            try require(a.id == b.id && a.kind == b.kind && a.title == b.title && a.excerpt == b.excerpt
                        && a.source == b.source && a.sourceBundleID == b.sourceBundleID && a.copiedAt == b.copiedAt
                        && a.byteSize == b.byteSize && a.pinned == b.pinned && a.copies == b.copies
                        && a.groups == b.groups && a.hasFileReference == b.hasFileReference,
                        "Production query modes returned different metadata, groups or order")
        }
    }

    /// Both branches execute complete production pages; these are warm queries, not UI or RSS measurements.
    private static func benchmark(_ directory: URL, large: Bool) async throws {
        print("BENCHMARK equal-work production pages; alternating warm samples; synthetic histories only")
        print("  OS=\(ProcessInfo.processInfo.operatingSystemVersionString), CPU=\(machineString("machdep.cpu.brand_string")), cores=\(ProcessInfo.processInfo.processorCount), RAM=\(ProcessInfo.processInfo.physicalMemory), SQLite=\(String(cString: sqlite3_libversion()))")
        for characters in large ? [2_048, 32_768] : [2_048] {
            let dataDirectory = try child(directory, "chars-\(characters)")
            let candidateDirectory = try child(dataDirectory, "candidate")
            let fallbackDirectory = try child(dataDirectory, "fallback")
            // Modes use distinct databases: optional-index initialization changes persistent triggers.
            try await HistoryStore(directory: candidateDirectory).prepare()
            try await HistoryStore(directory: fallbackDirectory, enablesTrigram: false).prepare()
            let databases = try [FixtureDatabase(candidateDirectory), FixtureDatabase(fallbackDirectory)]
            let group = UUID().uuidString
            for db in databases {
                try db.execute("INSERT INTO user_group VALUES('\(group)','Benchmark Group',0,0)")
            }
            let inserts = try databases.map { try $0.prepare("""
                INSERT INTO entry(id,fingerprint,kind,title,excerpt,search_text,source,source_bundle_id,copied_at,byte_size,pinned)
                VALUES(?,?,?,?,?,?,?,?,?,?,?)
                """) }
            defer { for statement in inserts { sqlite3_finalize(statement) } }
            let chunk = "synthetic ASCII 中文检索 punctuation_- ".padding(toLength: 64, withPad: "abcdef", startingAt: 0)
            var inserted = 0, expectedBytes = 0
            for count in [1_000, 5_000, 10_000] {
                let start = DispatchTime.now().uptimeNanoseconds
                for db in databases { try db.execute("BEGIN IMMEDIATE") }
                do {
                    for index in inserted..<count {
                        let suffix = index.isMultiple(of: 97) ? " selective-needle-唯一匹配" : " ordinary-content"
                        let body = String(String(repeating: chunk, count: characters / chunk.count + 1).prefix(characters - suffix.count)) + suffix
                        let id = UUID().uuidString
                        let values = [id, id, index.isMultiple(of: 11) ? "link" : "text", "Synthetic \(index)",
                                      "Synthetic fixture", body, "Synthetic", "local.synthetic.validation",
                                      String(1_000 + index / 3), String(body.utf8.count), index.isMultiple(of: 53) ? "1" : "0"]
                        for (db, statement) in zip(databases, inserts) {
                            try db.run(statement, values: values)
                            if index.isMultiple(of: 7) { try db.execute("INSERT INTO entry_group VALUES('\(id)','\(group)')") }
                        }
                        expectedBytes += body.utf8.count
                    }
                    for db in databases { try db.execute("COMMIT") }
                } catch {
                    for db in databases { try? db.execute("ROLLBACK") }
                    throw error
                }
                inserted = count
                for db in databases { try db.execute("PRAGMA wal_checkpoint(TRUNCATE)") }
                print(String(format: "  rows=%d chars=%d build-both=%.1fms candidate-disk=%d LIKE-disk=%d bytes",
                             count, characters, milliseconds(since: start), try diskBytes(candidateDirectory), try diskBytes(fallbackDirectory)))
                // A fresh measurement store avoids stale capacity caches after out-of-store fixture inserts.
                let candidate = HistoryStore(directory: candidateDirectory)
                let fallback = HistoryStore(directory: fallbackDirectory, enablesTrigram: false)
                try await candidate.prepare()
                try await fallback.prepare()
                let available = try !databases[0].rows("SELECT name FROM sqlite_master WHERE type='table' AND sql LIKE '%fts5%' AND sql LIKE '%trigram%'").isEmpty
                print("    candidate-mode=\(available ? "trigram" : "LIKE fallback (tokenizer unavailable)"); comparison-mode=forced LIKE")
                var cases = ["selective-needle", "中文检索", "not-present-anywhere", "中", "AS", "_%"].map {
                    (label: $0, query: $0, scope: "all", kind: Optional<ClipKind>.none, interval: Optional<DateInterval>.none, limit: 60)
                }
                cases += [
                    ("high-hit/group", "中文检索", group, nil, nil, 60),
                    ("high-hit/pinned", "中文检索", "pinned", nil, nil, 60),
                    ("high-hit/type+time/300", "中文检索", "all", .text,
                     DateInterval(start: Date(timeIntervalSince1970: 1_000 + Double(count / 6)),
                                  end: Date(timeIntervalSince1970: 1_001 + Double(count / 3))), 300)
                ]
                for item in cases {
                    func measuredPage(_ store: HistoryStore) async throws -> HistoryPage {
                        try await page(store, query: item.query, scope: item.scope, kind: item.kind,
                                       interval: item.interval, limit: item.limit)
                    }
                    let warm = try await measuredPage(candidate)
                    try requireSamePage(warm, await measuredPage(fallback))
                    try require(warm.storedEntries == count && warm.storedBytes == expectedBytes,
                                "Benchmark capacity projection is stale after fixture growth")
                    if item.scope == "all", item.kind == nil, item.interval == nil {
                        let expected = try databases[0].integer("SELECT COUNT(*) FROM entry WHERE kind IN ('text','link','file') AND search_text LIKE ? ESCAPE '\\'", [likePattern(item.query)])
                        let ids = try referenceIDs(databases[0], query: item.query)
                        try require(warm.total == expected && warm.clips.map { $0.id.uuidString } == Array(ids.prefix(item.limit)),
                                    "Benchmark production page differs from independent LIKE oracle")
                    }
                    var production: [Double] = [], like: [Double] = []
                    for sample in 0..<15 {
                        var actual: HistoryPage?, forced: HistoryPage?
                        for useCandidate in sample.isMultiple(of: 2) ? [true, false] : [false, true] {
                            let started = DispatchTime.now().uptimeNanoseconds
                            let result = try await measuredPage(useCandidate ? candidate : fallback)
                            let elapsed = milliseconds(since: started)
                            if useCandidate { production.append(elapsed); actual = result }
                            else { like.append(elapsed); forced = result }
                        }
                        guard let actual, let forced else { throw CheckFailure("Incomplete benchmark sample") }
                        try requireSamePage(actual, forced)
                    }
                    print(String(format: "    case=%@ candidate-page p50=%.2f p95=%.2fms forced-LIKE-page p50=%.2f p95=%.2fms samples=15",
                                 item.label, percentile(production, 0.5), percentile(production, 0.95), percentile(like, 0.5), percentile(like, 0.95)))
                }
            }
        }
    }
}
