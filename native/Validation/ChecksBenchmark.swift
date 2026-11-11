/*
 * Regression checks – search benchmark: synthetic data only, opt-in.
 * Synthetic fixtures only; never touches the real clipboard or history database.
 * author: helele
 * since: 2026-11-09
 */
import Foundation
import Carbon
import SQLite3
import Darwin

extension RegressionChecks {
    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func machineString(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: value.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
    }

    static func diskBytes(_ directory: URL) throws -> Int {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        return try files.reduce(0) { $0 + ((try $1.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) }
    }

    static func requireSamePage(_ lhs: HistoryPage, _ rhs: HistoryPage) throws {
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
    static func benchmark(_ directory: URL, large: Bool) async throws {
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
