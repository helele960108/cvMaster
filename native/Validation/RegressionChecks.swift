/*
 * Standalone, synthetic-only checks for production storage and thumbnail code.
 * No application lifecycle, clipboard monitor/library, XCTest, or real user database is loaded.
 * author: helele
 * since: 2026-10-20
 */
import Foundation
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
            let options = Set(arguments.dropFirst(2))
            try require(options.isSubset(of: ["--benchmark", "--benchmark-large"]), "Unknown harness option")
            print("All fixtures are synthetic; no application or clipboard lifecycle is instantiated.")
            let checks: [(String, (URL) async throws -> Void)] = [
                ("stable kind keys and v3 migration", migration),
                ("capture round trips, duplicate statistics and preserved metadata", roundTrips),
                ("literal LIKE / trigram / forced fallback semantic parity", searchParity),
                ("batched group projection, totals and date/kind/scope limits", groupsAndFilters),
                ("pruning rollback and protected retention", pruningRollback),
                ("private metadata/assets and symlink attacks fail closed", privacy),
                ("RTF conversion budgets and raw/plain-text recovery", richText),
                ("clear retains groups and external referenced files", clearing),
                ("thumbnail deduplication, deadline, cancellation and worker cap", thumbnails),
                ("pure privacy gate and per-item capture budgets", capturePolicy),
                ("pure paste handoff request binding and focus transitions", pasteHandoff)
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
        let group = UUID()
        do {
            let db = try FixtureDatabase(directory)
            let statement = try db.prepare("INSERT INTO user_group(id,name,color,position) VALUES(?,?,0,0)")
            defer { sqlite3_finalize(statement) }
            try db.run(statement, values: [group.uuidString, "Migration Group"])
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
        let escaped = String(query.prefix(256)).replacingOccurrences(of: "\\", with: "\\\\")
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
                       "no-synthetic-match-zzzz", String(repeating: "x", count: 257)]
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
        let catalog = try await store.groupCatalog()
        try await store.setGroup(old, group: catalog[0].id, included: true)
        try await store.setPinned(old, true)
        do {
            let db = try FixtureDatabase(directory)
            let statement = try db.prepare("UPDATE entry SET copied_at=? WHERE id=?")
            defer { sqlite3_finalize(statement) }
            try db.run(statement, values: ["1", old.uuidString])
        }
        try require(try await store.clear(before: Date(timeIntervalSince1970: 2)) == 1, "Date clear must remove even protected old rows")
        try require(try await page(store).total == 1, "Date clear removed wrong count")
        try require(try await store.clear() == 1, "Clear returned wrong count")
        let empty = try await page(store)
        try require(empty.total == 0 && empty.storedEntries == 0 && empty.storedBytes == 0, "Clear left stale statistics")
        try require(try await store.groupCatalog().map(\.id) == catalog.map(\.id), "Clear deleted group definitions")
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

    private static func capturePolicy(_ directory: URL) async throws {
        var gate = ClipboardCapturePolicy.Gate()
        try require(!gate.shouldCapture(change: 10, blocked: false), "Uninitialized gate captured existing content")
        gate.resetBaseline(to: 10, blocked: false)
        try require(!gate.shouldCapture(change: 10, blocked: false), "Unchanged clipboard was captured")
        try require(gate.shouldCapture(change: 11, blocked: false), "Normal new change was skipped")
        try require(!gate.shouldCapture(change: 12, blocked: true), "Blocked clipboard was captured")
        try require(!gate.shouldCapture(change: 13, blocked: false), "Resume backfilled content from blocked interval")
        try require(!gate.shouldCapture(change: 13, blocked: false), "Resume baseline was not retained")
        try require(gate.shouldCapture(change: 14, blocked: false), "First post-resume new copy was skipped")
        gate.resetBaseline(to: 20, blocked: true)
        try require(!gate.shouldCapture(change: 21, blocked: false) && gate.shouldCapture(change: 22, blocked: false),
                    "Explicit blocked reset did not skip first resumed sample")
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
            try require(sensitive == nil && reads == 0, "Sensitive item invoked data provider")
        }
        let unsupported = try ClipboardCapturePolicy.capture(itemTypes: [["local.unsupported"]], source: "Synthetic", bundleID: "") { _, _ in
            reads += 1
            return Data([1])
        }
        try require(unsupported == nil && reads == 0, "Unsupported item invoked data provider")
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
        try require(optional?.representations.count == 1 && optional?.kind == .text && optional?.searchText == "required text",
                    "Oversized optional image/HTML suppressed required text")
        try await expectError(.unsupported) {
            _ = try ClipboardCapturePolicy.capture(itemTypes: [["public.utf8-plain-text"]], source: "Synthetic", bundleID: "") { _, _ in tooLarge }
        }
        try await expectError(.unsupported) {
            _ = try ClipboardCapturePolicy.capture(itemTypes: [["public.utf8-plain-text"], ["public.url"]],
                                                    source: "Synthetic", bundleID: "") { item, _ in
                item == 0 ? Data("first must not be saved alone".utf8) : nil
            }
        }
        let urls = [directory.appendingPathComponent("first.txt"), directory.appendingPathComponent("second.pdf")]
        try await expectError(.unsupported) {
            _ = try ClipboardCapturePolicy.capture(itemTypes: [["public.file-url"], ["public.file-url", "public.png"]],
                                                    source: "Synthetic", bundleID: "") { item, type in
                if type == "public.png" { return image }
                return item == 0 ? Data(urls[0].absoluteString.utf8) : nil
            }
        }
        let largePixel = Data(repeating: 0x62, count: StorageLimits.maximumRepresentationBytes)
        let files = try ClipboardCapturePolicy.capture(itemTypes: [["public.png", "public.file-url"], ["public.png", "public.file-url"]],
                                                        source: "Synthetic", bundleID: "") { item, type in
            type == "public.file-url" ? Data(urls[item].absoluteString.utf8) : largePixel
        }
        guard let files else { throw CheckFailure("Multi-file capture unexpectedly missing") }
        try require(files.representations.filter { $0.type == "public.file-url" }.count == 2 && files.kind == .file,
                    "Optional pixels displaced a required file URL")
        try require(files.representations.reduce(0) { $0 + $1.data.count } <= StorageLimits.maximumCaptureBytes,
                    "Capture exceeded aggregate byte budget")
        try require(files.searchText == "first.txt\nsecond.pdf" && !files.searchText.contains(directory.path),
                    "File search projection leaked directory paths")
        let fallback = try ClipboardCapturePolicy.capture(itemTypes: [["public.png", "public.jpeg"]], source: "Synthetic", bundleID: "") { _, type in
            type == "public.png" ? nil : image
        }
        try require(fallback?.representations.count == 1 && fallback?.representations[0].type == "public.jpeg",
                    "Missing first image provider did not fall back to next supported representation")
    }

    /// Pure event sequences reproduce await-time focus races without AppKit, AX, or a running app.
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

        // Unexpected transitions while restoring or prepared cannot be repaired by returning to A.
        for phase in ["restoring", "prepared"] {
            for event in ["switch-back", "close", "duplicate-target", "unknown"] {
                var interrupted = try restoring()
                if phase == "prepared" || event == "duplicate-target" {
                    interrupted.applicationActivated(original)
                }
                if phase == "prepared" {
                    try require(interrupted.markPrepared(targetID: target), "Prepared interruption fixture was not prepared")
                }
                switch event {
                case "switch-back": interrupted.applicationActivated(unrelated); interrupted.applicationActivated(original)
                case "close": interrupted.panelDidClose()
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

    /// Warm-query microbenchmark, not application latency or an Instruments memory measurement.
    private static func benchmark(_ directory: URL, large: Bool) async throws {
        print("BENCHMARK warm synthetic SQLite queries; not UI latency; no real history used")
        print("  OS=\(ProcessInfo.processInfo.operatingSystemVersionString), CPU=\(machineString("machdep.cpu.brand_string")), cores=\(ProcessInfo.processInfo.processorCount), RAM=\(ProcessInfo.processInfo.physicalMemory), SQLite=\(String(cString: sqlite3_libversion()))")
        for characters in large ? [2_048, 32_768] : [2_048] {
            // One incrementally populated database per text size avoids holding three worst-case FTS databases at once.
            let dataDirectory = try child(directory, "chars-\(characters)")
            let store = HistoryStore(directory: dataDirectory)
            try await store.prepare()
            let db = try FixtureDatabase(dataDirectory)
            let insert = try db.prepare("""
                INSERT INTO entry(id,fingerprint,kind,title,excerpt,search_text,source,source_bundle_id,copied_at,byte_size)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                """)
            defer { sqlite3_finalize(insert) }
            let chunk = "synthetic ASCII 中文检索 punctuation_- ".padding(toLength: 64, withPad: "abcdef", startingAt: 0)
            var inserted = 0
            for count in [1_000, 5_000, 10_000] {
                let start = DispatchTime.now().uptimeNanoseconds
                try db.execute("BEGIN IMMEDIATE")
                do {
                    for index in inserted..<count {
                        let suffix = index.isMultiple(of: 97) ? " selective-needle-唯一匹配" : " ordinary-content"
                        let body = String(String(repeating: chunk, count: characters / chunk.count + 1).prefix(characters - suffix.count)) + suffix
                        let id = UUID().uuidString
                        try db.run(insert, values: [id, id, "text", "Synthetic \(index)", "Synthetic fixture", body, "Synthetic", "",
                                                    String(1_000 + index), String(body.utf8.count)])
                    }
                    try db.execute("COMMIT")
                } catch {
                    try? db.execute("ROLLBACK")
                    throw error
                }
                inserted = count
                try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                print(String(format: "  rows=%d chars=%d build=%.1fms disk=%d bytes", count, characters, milliseconds(since: start), try diskBytes(dataDirectory)))
                let queries = ["selective-needle", "中文检索", "not-present-anywhere", "中", "AS", "_%"]
                let countSQL = try db.prepare("SELECT COUNT(*) FROM entry e WHERE e.kind IN ('text','link','file') AND e.search_text LIKE ? ESCAPE '\\'")
                let pageSQL = try db.prepare("SELECT e.id FROM entry e WHERE e.kind IN ('text','link','file') AND e.search_text LIKE ? ESCAPE '\\' ORDER BY e.pinned DESC,e.copied_at DESC,e.id LIMIT 60")
                defer { sqlite3_finalize(countSQL); sqlite3_finalize(pageSQL) }
                for query in queries {
                    _ = try await page(store, query: query, limit: 60)
                    var production: [Double] = [], like: [Double] = []
                    for _ in 0..<15 {
                        var started = DispatchTime.now().uptimeNanoseconds
                        let actual = try await page(store, query: query, limit: 60)
                        production.append(milliseconds(since: started))
                        started = DispatchTime.now().uptimeNanoseconds
                        try db.bind([likePattern(query)], to: countSQL)
                        try require(sqlite3_step(countSQL) == SQLITE_ROW, "LIKE benchmark count failed")
                        let expected = Int(sqlite3_column_int64(countSQL, 0))
                        sqlite3_reset(countSQL)
                        try db.bind([likePattern(query)], to: pageSQL)
                        var ids: [String] = []
                        while true {
                            let status = sqlite3_step(pageSQL)
                            if status == SQLITE_DONE { break }
                            try require(status == SQLITE_ROW, "LIKE benchmark page failed")
                            ids.append(String(cString: sqlite3_column_text(pageSQL, 0)))
                        }
                        sqlite3_reset(pageSQL)
                        like.append(milliseconds(since: started))
                        try require(actual.total == expected && actual.clips.map { $0.id.uuidString } == ids, "Benchmark query semantic mismatch")
                    }
                    print(String(format: "    query=%@ page p50=%.2f p95=%.2fms LIKE-only(count+ids) p50=%.2f p95=%.2fms samples=15",
                                 String(reflecting: query), percentile(production, 0.5), percentile(production, 0.95), percentile(like, 0.5), percentile(like, 0.95)))
                }
            }
        }
    }
}
