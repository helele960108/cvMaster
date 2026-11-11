/*
 * Shared fixtures and helpers for the isolated regression checks (synthetic-only).
 * author: helele
 * since: 2026-10-20
 */
import Foundation
import Carbon
import SQLite3
import Darwin

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(message) }
}

/// A separate, short-lived SQLite connection is used only for fixtures and fault injection.
final class FixtureDatabase {
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
final class WorkProbe: @unchecked Sendable {
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

extension RegressionChecks {
    static func validateWorkspace(_ root: URL) throws {
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

    static func child(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return url
    }

    static func capture(_ text: String, kind: ClipKind = .text,
                                representations: [ClipRepresentation]? = nil, source: String = "Synthetic") -> ClipCapture {
        ClipCapture(kind: kind, title: String(text.prefix(120)), excerpt: String(text.prefix(240)),
                    searchText: kind == .image ? "" : text, source: source, sourceBundleID: "local.synthetic.validation",
                    representations: representations ?? [ClipRepresentation(item: 0, type: "public.utf8-plain-text", data: Data(text.utf8))])
    }

    static func page(_ store: HistoryStore, query: String = "", scope: String = "all", kind: ClipKind? = nil,
                             interval: DateInterval? = nil, limit: Int = 300) async throws -> HistoryPage {
        try await store.page(query: query, scope: scope, kind: kind, interval: interval, limit: limit)
    }

    static func expectError(_ expected: LibraryError, _ operation: () async throws -> Void) async throws {
        do {
            try await operation()
        } catch let error as LibraryError {
            try require(String(describing: error) == String(describing: expected),
                        "Expected \(expected), received \(error)")
            return
        }
        throw CheckFailure("Expected \(expected), operation unexpectedly succeeded")
    }

    static func waitUntil(_ description: String, timeout: TimeInterval = 2,
                                  _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            try require(Date() < deadline, "Timed out waiting for \(description)")
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
