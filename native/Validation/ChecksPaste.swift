/*
 * Regression checks – shortcut and paste handoff: pure state policies and single-use focus permits.
 * Synthetic fixtures only; never touches the real clipboard or history database.
 * author: helele
 * since: 2026-11-09
 */
import Foundation
import Carbon
import SQLite3
import Darwin

extension RegressionChecks {
    /// Pure event sequences reproduce await-time focus races without AppKit, AX, or a running app.
    static func globalShortcut(_: URL) async throws {
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

    static func pasteHandoff(_: URL) async throws {
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
    static func pasteFocusRestoration(_: URL) async throws {
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
}
