/*
 * Regression checks – storage: migration, round trips, search semantics, filters, retention, clearing and metadata bounds.
 * Synthetic fixtures only; never touches the real clipboard or history database.
 * author: helele
 * since: 2026-11-09
 */
import Foundation
import Carbon
import SQLite3
import Darwin

extension RegressionChecks {
    /// v3 fixture includes source_bundle_id; no real database is copied to manufacture migration input.
    static func makeV3(_ directory: URL) throws {
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

    static func insertRows(_ directory: URL, _ rows: [(id: UUID, kind: String, text: String, date: Double)]) throws {
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

    static func migration(_ directory: URL) async throws {
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

    static func roundTrips(_ directory: URL) async throws {
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

    static func likePattern(_ query: String) -> String {
        let escaped = MetadataBounds.query(query).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    static func referenceIDs(_ db: FixtureDatabase, query: String) throws -> [String] {
        if query.isEmpty {
            return try db.rows("SELECT id FROM entry ORDER BY pinned DESC,copied_at DESC,id LIMIT 300").compactMap(\.first)
        }
        return try db.rows("""
            SELECT id FROM entry WHERE kind IN ('text','link','file') AND search_text LIKE ? ESCAPE '\\'
            ORDER BY pinned DESC,copied_at DESC,id LIMIT 300
            """, [likePattern(query)]).compactMap(\.first)
    }

    static func searchParity(_ directory: URL) async throws {
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

    static func groupsAndFilters(_ directory: URL) async throws {
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

    static func pruningRollback(_ directory: URL) async throws {
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

    static func clearing(_ directory: URL) async throws {
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

    /// Full synthetic capture/store paths, not a string-only demonstration of grapheme amplification.
    static func metadataBounds(_ directory: URL) async throws {
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

    static func requireBoundedMetadata(_ value: ClipCapture) throws {
        try require(value.title.utf8.count <= 4_096 && value.title.count <= 120, "Capture title exceeds metadata bounds")
        try require(value.excerpt.utf8.count <= 8_192 && value.excerpt.count <= 240, "Capture excerpt exceeds metadata bounds")
        try require(value.searchText.utf8.count <= 131_072 && value.searchText.count <= 32_768,
                    "Capture search text exceeds shared output bounds")
        try require(value.source.utf8.count <= 1_024 && value.sourceBundleID.utf8.count <= 1_024,
                    "Capture source metadata exceeds bounds")
    }

    static func requireBoundedClip(_ value: Clip) throws {
        try require(value.title.utf8.count <= 4_096 && value.title.count <= 120, "Page title exceeds metadata bounds")
        try require(value.excerpt.utf8.count <= 8_192 && value.excerpt.count <= 240, "Page excerpt exceeds metadata bounds")
        try require(value.source.utf8.count <= 1_024 && value.sourceBundleID.utf8.count <= 1_024,
                    "Page source metadata exceeds bounds")
    }

    /// A prepared reader must not collect assets belonging to another connection's uncommitted write.
    static func recoveryIsolation(_ directory: URL) async throws {
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
}
