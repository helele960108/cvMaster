/*
 * Regression checks – thumbnails: deduplication, deadlines, cancellation and the worker cap.
 * Synthetic fixtures only; never touches the real clipboard or history database.
 * author: helele
 * since: 2026-11-09
 */
import Foundation
import Carbon
import SQLite3
import Darwin

extension RegressionChecks {
    static func thumbnails(_ directory: URL) async throws {
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
}
