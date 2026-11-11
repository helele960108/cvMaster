/*
 * Entry point for the isolated, synthetic-only regression harness (see native/scripts/check-regressions.sh).
 * No application lifecycle, clipboard monitor/library, XCTest, or real user database is loaded.
 * author: helele
 * since: 2026-10-20
 */
import Foundation
import Darwin

@main
struct RegressionChecks {
    static let marker = "cvmaster-isolated-regressions\n"
    static let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a4h8AAAAASUVORK5CYII=")!

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
                ("session lock resolver fails closed and blocks capture", sessionLock),
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
}
