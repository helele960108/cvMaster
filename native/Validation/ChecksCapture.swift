/*
 * Regression checks – capture policy: two-phase cursor, privacy gate and session-lock resolver.
 * Synthetic fixtures only; never touches the real clipboard or history database.
 * author: helele
 * since: 2026-11-09
 */
import Foundation
import Carbon
import SQLite3
import Darwin

extension RegressionChecks {
    static func captureCursor(_: URL) async throws {
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

    static func capturePolicy(_ directory: URL) async throws {
        try require(!ClipboardCapturePolicy.isBlocked(sleeping: false, sessionInactive: false, onConsole: true,
                                                      loginComplete: true, secureInput: false, screenLocked: false),
                    "Active known session was blocked")
        for state in [(true, false, Optional(true), Optional(true), false, false),
                      (false, true, Optional(true), Optional(true), false, false),
                      (false, false, Optional(false), Optional(true), false, false),
                      (false, false, Optional(true), Optional(false), false, false),
                      (false, false, nil, Optional(true), false, false),
                      (false, false, Optional(true), nil, false, false),
                      (false, false, Optional(true), Optional(true), true, false),
                      (false, false, Optional(true), Optional(true), false, true)] {
            try require(ClipboardCapturePolicy.isBlocked(sleeping: state.0, sessionInactive: state.1, onConsole: state.2,
                                                         loginComplete: state.3, secureInput: state.4, screenLocked: state.5),
                        "Unknown/blocked session was not fail-closed")
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

    /// Lock-state parsing is pure; the notification-backed monitor is deliberately not started here.
    static func sessionLock(_: URL) async throws {
        let key = SessionLockResolver.screenIsLockedKey
        try require(SessionLockResolver.resolve(nil) == .unknown, "Missing session dictionary must stay unknown")
        try require(SessionLockResolver.resolve([:]) == .unlocked, "Absent screen-lock key must mean unlocked")
        try require(SessionLockResolver.resolve([key: NSNumber(value: true)]) == .locked,
                    "True screen-lock value was not locked")
        try require(SessionLockResolver.resolve([key: NSNumber(value: false)]) == .unlocked,
                    "False screen-lock value was not unlocked")
        try require(SessionLockResolver.resolve([key: "true"]) == .unknown,
                    "Malformed screen-lock value must fail closed")
        try require(ClipboardCapturePolicy.isBlocked(sleeping: false, sessionInactive: false, onConsole: true,
                                                     loginComplete: true, secureInput: false, screenLocked: true),
                    "Screen lock did not block capture")
        try require(!ClipboardCapturePolicy.isBlocked(sleeping: false, sessionInactive: false, onConsole: true,
                                                      loginComplete: true, secureInput: false, screenLocked: false),
                    "Unlocked active session was blocked")
        let now = ContinuousClock.Instant.now
        try require(!ClipboardCapturePolicy.shouldRebaseAfterPollGap(lastPoll: nil, now: now, maximumGap: .seconds(5)),
                    "Initial poll must not be treated as a gap")
        try require(!ClipboardCapturePolicy.shouldRebaseAfterPollGap(lastPoll: now.advanced(by: .seconds(-5)),
                                                                     now: now, maximumGap: .seconds(5)),
                    "Gap at the threshold must not rebase")
        try require(ClipboardCapturePolicy.shouldRebaseAfterPollGap(lastPoll: now.advanced(by: .seconds(-6)),
                                                                    now: now, maximumGap: .seconds(5)),
                    "Long poll gap must conservatively rebase")
    }
}
