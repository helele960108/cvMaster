import Foundation

extension RegressionChecks {
    static func statusIconPresentation(_: URL) async throws {
        let shortcut = "⇧⌘V"
        let cases: [(Bool, Bool, Bool, String)] = [
            (true, false, false, ""),
            (true, true, true, " · 已暂停记录"),
            (false, false, true, " · 未开启记录"),
            (false, true, true, " · 未开启记录")
        ]
        for (enabled, paused, inactive, suffix) in cases {
            let result = StatusIconPresentation(recordingEnabled: enabled, paused: paused, shortcut: shortcut)
            try require(result.inactive == inactive, "Unexpected menu bar recording icon state")
            try require(result.tooltip == "cvMaster · \(shortcut)\(suffix)", "Unexpected menu bar recording tooltip")
        }
    }
}
