/**
 * 外部引用文件可读性的有界检查：固定工作槽、三秒调用者截止，不为异常挂载点新增线程。
 * @author helele
 * @since 2026-10-20
 */
import Foundation
import Dispatch

/// 外部文件可读性也可能被异常挂载点阻塞；仅两个实际工作槽，无排队替代线程。
/// 三秒仅限制调用者等待，取消 / 超时不会释放仍在系统调用中的槽。
final class FileAvailability: @unchecked Sendable {
    static let shared = FileAvailability()
    private let lock = NSLock()
    private var active = 0
    private let workers = DispatchQueue(label: "local.helele.cvmaster.availability", qos: .utility, attributes: .concurrent)
    private let deadlines = DispatchQueue(label: "local.helele.cvmaster.availability.deadlines", qos: .utility)

    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var timer: DispatchSourceTimer?
        private var finished = false

        func install(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
            let installed = lock.withLock {
                guard !finished else { return false }
                self.continuation = continuation
                return true
            }
            if !installed { continuation.resume(returning: false) }
            return installed
        }

        func startDeadline(on queue: DispatchQueue) {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 3)
            source.setEventHandler { [weak self] in self?.finish(false) }
            lock.withLock {
                source.resume()
                if finished { source.setEventHandler(handler: nil); source.cancel() }
                else { timer = source }
            }
        }

        func finish(_ value: Bool) {
            let result = lock.withLock { () -> (CheckedContinuation<Bool, Never>?, DispatchSourceTimer?) in
                guard !finished else { return (nil, nil) }
                finished = true
                let result = (continuation, timer)
                continuation = nil
                timer = nil
                return result
            }
            result.1?.setEventHandler(handler: nil)
            result.1?.cancel()
            result.0?.resume(returning: value)
        }
    }

    func check(_ urls: [URL]) async -> Bool {
        guard !Task.isCancelled, urls.count <= StorageLimits.maximumRepresentations else { return false }
        guard !urls.isEmpty else { return true }
        // 这里只检查纯 URL 属性，不在存储 actor 内查询外部卷或解析符号链接。
        guard urls.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost")
            && !$0.path.utf8.contains(0) }) else { return false }
        let waiter = Waiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard waiter.install(continuation) else { return }
                let admitted = lock.withLock {
                    guard active < 2 else { return false }
                    active += 1
                    return true
                }
                guard admitted else { waiter.finish(false); return }
                waiter.startDeadline(on: deadlines)
                workers.async { [self] in
                    defer { lock.withLock { active -= 1 } }
                    // 不调用下载 API；元数据 / access 本身仍可能触发 OS 文件系统行为。
                    let readable = urls.allSatisfy { url in
                        guard let info = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
                              info.isUbiquitousItem != true || info.ubiquitousItemDownloadingStatus == .current
                                || info.ubiquitousItemDownloadingStatus == .downloaded else { return false }
                        return FileManager.default.isReadableFile(atPath: url.path)
                    }
                    waiter.finish(readable)
                }
            }
        } onCancel: {
            waiter.finish(false)
        }
    }
}
