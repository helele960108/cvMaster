import Foundation
import Dispatch
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// `referenced` identifies the stored UTF-8 file-URL representation, not the external image itself.
enum ThumbnailSource: Sendable {
    case stored(URL)
    case referenced(URL)
}

/// Bounded, off-actor image I/O. A deadline limits callers' waiting, NOT the lifetime of a syscall.
/// Only actual synchronous completion releases a worker slot; two stuck reads exhaust this pipeline
/// rather than spawning replacement threads. Completed images belong to HistoryStore's cache only.
actor ThumbnailPipeline {
    static let shared = ThumbnailPipeline()

    /// Admission failure is transient and is deliberately not put in the negative cache.
    enum Result: Sendable {
        case image(Data)
        case unavailable
        case busy
    }

    /// Internal injection supports isolated regression tests without exposing a public unsafe hook.
    /// Limits may be reduced for tests, but cannot increase the production resource bounds.
    struct Configuration: Sendable {
        let timeout: TimeInterval
        let failureCooldown: TimeInterval
        let timeoutCooldown: TimeInterval
        let negativeCacheLimit: Int
        let maximumWaitersPerJob: Int

        init(timeout: TimeInterval = 3, failureCooldown: TimeInterval = 2,
             timeoutCooldown: TimeInterval = 30, negativeCacheLimit: Int = 256,
             maximumWaitersPerJob: Int = 128) {
            self.timeout = timeout.isFinite ? min(max(timeout, 0.001), 30) : 3
            self.failureCooldown = failureCooldown.isFinite ? min(max(failureCooldown, 0), 60) : 2
            self.timeoutCooldown = timeoutCooldown.isFinite ? min(max(timeoutCooldown, 0), 300) : 30
            self.negativeCacheLimit = min(max(negativeCacheLimit, 0), 256)
            self.maximumWaitersPerJob = min(max(maximumWaitersPerJob, 1), 128)
        }
    }

    private struct Key: Hashable, Sendable {
        let asset: URL
        let maximum: Int
        // An image asset and a file-URL text asset have different decoding semantics.
        let referenced: Bool
    }

    private struct Job {
        let id: UUID
        var waiters: [Waiter]
        var timer: DispatchSourceTimer?
        var timedOut = false
    }

    /// Cancellation can happen before continuation installation or while the actor is busy.
    /// Every mutable field is protected by the lock; resumption always happens outside the lock.
    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result, Never>?
        private var finished = false

        var isFinished: Bool { lock.withLock { finished } }

        func install(_ continuation: CheckedContinuation<Result, Never>) -> Bool {
            let installed = lock.withLock {
                guard !finished else { return false }
                self.continuation = continuation
                return true
            }
            if !installed { continuation.resume(returning: .unavailable) }
            return installed
        }

        func finish(_ result: Result) {
            let continuation = lock.withLock {
                guard !finished else { return Optional<CheckedContinuation<Result, Never>>.none }
                finished = true
                let value = self.continuation
                self.continuation = nil
                return value
            }
            continuation?.resume(returning: result)
        }
    }

    private static let workerLimit = 2
    private static let maximumPixels = 1_024
    private static let maximumOutputBytes = 2 * 1_024 * 1_024
    private let configuration: Configuration
    private let work: @Sendable (ThumbnailSource, Int) -> Data?
    // No work is submitted before admission. At most two blocks can be doing synchronous work.
    private let workers = DispatchQueue(label: "local.helele.cvmaster.thumbnails.work",
                                        qos: .utility, attributes: .concurrent)
    private let deadlines = DispatchQueue(label: "local.helele.cvmaster.thumbnails.deadlines", qos: .utility)
    private let clock = ContinuousClock()
    private var jobs: [Key: Job] = [:]
    private var failures: [Key: ContinuousClock.Instant] = [:]

    init(configuration: Configuration = Configuration(),
         work: @escaping @Sendable (ThumbnailSource, Int) -> Data? = ThumbnailPipeline.generateThumbnail) {
        self.configuration = configuration
        self.work = work
    }

    func thumbnail(_ source: ThumbnailSource, maximum: Int) async -> Data? {
        if case .image(let data) = await thumbnailResult(source, maximum: maximum) { return data }
        return nil
    }

    /// Optional richer API for bounded caller-side busy retries; there is no internal pending queue.
    func thumbnailResult(_ source: ThumbnailSource, maximum: Int) async -> Result {
        guard !Task.isCancelled, maximum > 0 else { return .unavailable }
        let asset: URL
        let referenced: Bool
        switch source {
        case .stored(let url): asset = url; referenced = false
        case .referenced(let url): asset = url; referenced = true
        }
        guard Self.isLocalFileURL(asset) else { return .unavailable }
        // URL equality needs no disk access. Do not resolve symlinks or fetch metadata on this actor.
        let key = Key(asset: asset, maximum: min(maximum, Self.maximumPixels), referenced: referenced)
        let waiter = Waiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard waiter.install(continuation), !waiter.isFinished else { return }
                admit(source, key: key, waiter: waiter)
            }
        } onCancel: {
            // Cancelling one waiter never cancels a shared job, timer, or another waiter's result.
            // No cleanup Task is needed: admission prunes cancelled waiters, and the timer clears them.
            waiter.finish(.unavailable)
        }
    }

    /// A permission/download change can invalidate cooldowns, but cannot release stuck worker slots.
    func resetFailures() { failures.removeAll(keepingCapacity: true) }

    private func admit(_ source: ThumbnailSource, key: Key, waiter: Waiter) {
        let now = clock.now
        failures = failures.filter { $0.value > now }
        guard failures[key] == nil else { waiter.finish(.unavailable); return }
        if var job = jobs[key] {
            guard !job.timedOut else { waiter.finish(.unavailable); return }
            job.waiters.removeAll { $0.isFinished }
            guard job.waiters.count < configuration.maximumWaitersPerJob else {
                jobs[key] = job
                waiter.finish(.busy)
                return
            }
            job.waiters.append(waiter)
            jobs[key] = job
            return
        }
        guard jobs.count < Self.workerLimit else { waiter.finish(.busy); return }
        guard !waiter.isFinished else { return }

        let id = UUID()
        let timer = DispatchSource.makeTimerSource(queue: deadlines)
        timer.schedule(deadline: .now() + configuration.timeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.expire(key, id: id) }
        }
        jobs[key] = Job(id: id, waiters: [waiter], timer: timer)
        timer.resume()
        let work = self.work
        workers.async {
            let data = autoreleasepool { work(source, key.maximum) }
            Task { await self.complete(key, id: id, data: data) }
        }
    }

    private func expire(_ key: Key, id: UUID) {
        guard var job = jobs[key], job.id == id, !job.timedOut else { return }
        stopTimer(job.timer)
        job.timer = nil
        job.timedOut = true
        let waiters = job.waiters
        job.waiters.removeAll(keepingCapacity: false)
        jobs[key] = job // Crucially, still occupies one of the two worker slots.
        recordFailure(key, timedOut: true)
        for waiter in waiters { waiter.finish(.unavailable) }
    }

    private func complete(_ key: Key, id: UUID, data: Data?) {
        guard let job = jobs[key], job.id == id else { return }
        stopTimer(job.timer)
        jobs.removeValue(forKey: key) // The ONLY path releasing a worker slot.
        guard !job.timedOut else { return } // Discard late data; do not warm a hidden positive cache.
        let result: Result
        if let data, !data.isEmpty, data.count <= Self.maximumOutputBytes {
            result = .image(data)
        } else {
            recordFailure(key, timedOut: false)
            result = .unavailable
        }
        for waiter in job.waiters { waiter.finish(result) }
    }

    private func stopTimer(_ timer: DispatchSourceTimer?) {
        timer?.setEventHandler(handler: nil)
        timer?.cancel()
    }

    private func recordFailure(_ key: Key, timedOut: Bool) {
        let limit = configuration.negativeCacheLimit
        guard limit > 0 else { return }
        let now = clock.now
        failures = failures.filter { $0.value > now }
        // Stored assets have a short TTL even on timeout; a still-running job remains blocked anyway.
        let cooldown = timedOut && key.referenced ? configuration.timeoutCooldown : configuration.failureCooldown
        guard cooldown > 0 else { return }
        if failures[key] == nil, failures.count >= limit,
           let oldest = failures.min(by: { $0.value < $1.value })?.key {
            failures.removeValue(forKey: oldest)
        }
        failures[key] = now.advanced(by: .seconds(cooldown))
    }

    // MARK: - Synchronous worker-only file access and decoding

    private nonisolated static func isLocalFileURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
            && !url.path.utf8.contains(0)
    }

    private nonisolated static func generateThumbnail(_ source: ThumbnailSource, _ maximum: Int) -> Data? {
        let data: Data?
        switch source {
        case .stored(let asset):
            data = readFile(asset, maximum: 8 * 1_024 * 1_024)
        case .referenced(let asset):
            guard let reference = readFile(asset, maximum: 16 * 1_024),
                  let text = String(data: reference, encoding: .utf8),
                  let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  isLocalFileURL(url),
                  UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
                  let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                      .fileSizeKey, .volumeIsLocalKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
                  info.isRegularFile == true, info.isSymbolicLink != true, info.volumeIsLocal == true,
                  (info.isUbiquitousItem != true || info.ubiquitousItemDownloadingStatus == .current
                      || info.ubiquitousItemDownloadingStatus == .downloaded),
                  let size = info.fileSize, size > 0, size <= 64 * 1_024 * 1_024 else { return nil }
            data = readFile(url, maximum: 64 * 1_024 * 1_024)
        }
        guard let data else { return nil }
        return downsample(data, maximum: maximum)
    }

    /// A no-follow leaf open plus fstat closes the metadata/leaf-replacement race for type and size.
    /// Ancestor symlinks (including macOS /tmp and /var aliases) are not atomically excluded; neither
    /// URL metadata nor cloud state is a security boundary against same-UID directory/file mutation.
    /// O_NONBLOCK prevents FIFO waiting but CANNOT impose a deadline on ordinary filesystem calls.
    private nonisolated static func readFile(_ url: URL, maximum: Int) -> Data? {
        guard isLocalFileURL(url) else { return nil }
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var before = stat()
        var volume = statfs()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_size > 0, before.st_size <= off_t(maximum),
              before.st_flags & UInt32(SF_DATALESS) == 0,
              Darwin.fstatfs(descriptor, &volume) == 0,
              volume.f_flags & UInt32(MNT_LOCAL) != 0 else { return nil }

        let count = Int(before.st_size)
        // Bounded Data avoids ImageIO reopening a raced URL and keeps input <=64 MiB per worker.
        // With two workers, raw file buffers total <=128 MiB, plus decoder/thumbnail/PNG buffers.
        var data = Data(count: count)
        let readAll = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < count {
                let amount = Darwin.read(descriptor, base.advanced(by: offset), min(count - offset, 64 * 1_024))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { return false }
                offset += amount
            }
            return true
        }
        var after = stat()
        guard readAll, Darwin.fstat(descriptor, &after) == 0,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return nil }
        return data
    }

    private nonisolated static func downsample(_ data: Data, maximum: Int) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false,
                                      kCGImageSourceShouldCacheImmediately: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximum,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCache: false,
                  kCGImageSourceShouldCacheImmediately: false] as CFDictionary),
              image.width > 0, image.height > 0,
              image.width <= maximum, image.height <= maximum else { return nil }

        // Refuse excess encoder bytes as they are emitted, not after growing an unbounded Data.
        let output = ThumbnailOutput(maximum: maximumOutputBytes)
        var callbacks = CGDataConsumerCallbacks(putBytes: { pointer, bytes, count in
            guard let pointer else { return 0 }
            return Unmanaged<ThumbnailOutput>.fromOpaque(pointer).takeUnretainedValue().append(bytes, count: count)
        }, releaseConsumer: { pointer in
            if let pointer { Unmanaged<ThumbnailOutput>.fromOpaque(pointer).release() }
        })
        let pointer = Unmanaged.passRetained(output).toOpaque()
        guard let consumer = CGDataConsumer(info: pointer, cbks: &callbacks) else {
            Unmanaged<ThumbnailOutput>.fromOpaque(pointer).release()
            return nil
        }
        guard let destination = CGImageDestinationCreateWithDataConsumer(consumer, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output.result()
    }
}

/// ImageIO consumer callback state. Locking covers callbacks even if an encoder uses another thread.
private final class ThumbnailOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: Int
    private var data = Data()
    private var overflowed = false

    init(maximum: Int) { self.maximum = maximum }

    func append(_ bytes: UnsafeRawPointer, count: Int) -> Int {
        lock.withLock {
            guard !overflowed, count <= maximum - data.count else {
                overflowed = true
                return 0
            }
            data.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
            return count
        }
    }

    func result() -> Data? { lock.withLock { overflowed || data.isEmpty ? nil : data } }
}
