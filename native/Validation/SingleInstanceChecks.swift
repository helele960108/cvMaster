/*
 * Synthetic-only process lock checks; helpers run only after the runner validates its workspace.
 * No AppKit, application lifecycle, clipboard or history database is loaded.
 * author: helele
 * since: 2026-11-04
 */
import Foundation
import Darwin

private struct InstanceCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func instanceRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw InstanceCheckFailure(message) }
}

enum SingleInstanceChecks {
    /// Call after validateWorkspace and before the main runner's ordinary option validation.
    static func runHelperIfRequested(arguments: [String], workspace: URL) throws -> Bool {
        guard arguments.first == "--single-instance-helper" else { return false }
        try instanceRequire(arguments.count == 3 && ["probe", "hold", "race"].contains(arguments[1]),
                            "Invalid single-instance helper arguments")
        let directory = try helperDirectory(arguments[2], workspace: workspace)
        let mode = arguments[1]
        if mode == "race" {
            report("ready")
            try receiveGate()
        }
        guard let token = try SingleInstanceLock.acquire(directory: directory) else {
            report("occupied")
            return true
        }
        try withExtendedLifetime(token) {
            report("acquired")
            if mode != "probe" { try receiveGate() }
        }
        return true
    }

    static func run(_ directory: URL) async throws {
        let workspace = directory.deletingLastPathComponent()
        _ = try helperDirectory(directory.lastPathComponent, workspace: workspace)
        let held = try fixture(directory, "held")
        var identity: stat?
        try withToken(held) {
            identity = try fileInfo(held.appendingPathComponent(".instance.lock"))
            try instanceRequire(try probe(held, workspace: workspace) == "occupied", "Child bypassed parent's lock")
            try instanceRequire(try fileInfo(held).st_mode & 0o777 == 0o700, "Lock root is not private")
            try instanceRequire(identity!.st_mode & 0o777 == 0o600 && identity!.st_nlink == 1,
                                "Lock file permissions or link count are invalid")
        }
        try instanceRequire(try probe(held, workspace: workspace) == "acquired", "Lock did not release on close")
        try instanceRequire(StoragePaths.sameIdentity(identity!, try fileInfo(held.appendingPathComponent(".instance.lock"))),
                            "Closing a lock replaced or removed its inode")

        // A parked exec child must not retain its parent's lock after the parent's token is released.
        let inherited = try fixture(directory, "close-on-exec")
        var parked: Child?
        try withToken(inherited) {
            let child = try Child("race", directory: inherited, workspace: workspace)
            parked = child
            try instanceRequire(try child.line() == "ready", "Exec child failed to park")
        }
        guard let parked else { throw InstanceCheckFailure("Missing exec child") }
        defer { parked.stop() }
        try instanceRequire(try probe(inherited, workspace: workspace) == "acquired", "Lock leaked across exec")
        try parked.sendGate()
        try instanceRequire(try parked.line() == "acquired", "Parked child could not acquire released lock")
        try parked.sendGate()
        try parked.finish()

        for abrupt in [false, true] {
            let target = try fixture(directory, abrupt ? "killed-exit" : "normal-exit")
            let owner = try Child("hold", directory: target, workspace: workspace)
            defer { owner.stop() }
            try instanceRequire(try owner.line() == "acquired", "Child failed to acquire lock")
            let before = try fileInfo(target.appendingPathComponent(".instance.lock"))
            try instanceRequire(try probe(target, workspace: workspace) == "occupied", "Second child bypassed owner")
            if abrupt { try owner.killOwner() } else { try owner.sendGate() }
            try owner.finish(expectKilled: abrupt)
            try instanceRequire(try probe(target, workspace: workspace) == "acquired", "Exited child retained lock")
            try instanceRequire(StoragePaths.sameIdentity(before, try fileInfo(target.appendingPathComponent(".instance.lock"))),
                                "Process exit changed the lock inode")
        }

        let contested = try fixture(directory, "simultaneous")
        var competitors: [Child] = []
        defer { for child in competitors { child.stop() } }
        for _ in 0..<6 { competitors.append(try Child("race", directory: contested, workspace: workspace)) }
        for child in competitors {
            try instanceRequire(try child.line() == "ready", "Contender failed to reach common gate")
        }
        for child in competitors { try child.sendGate() }
        var winners: [Child] = []
        for child in competitors {
            let result = try child.line()
            try instanceRequire(result == "acquired" || result == "occupied", "Invalid contender result")
            if result == "acquired" { winners.append(child) }
        }
        try instanceRequire(winners.count == 1, "Simultaneous contenders did not produce exactly one owner")
        for winner in winners { try winner.sendGate() }
        for child in competitors { try child.finish() }
        try instanceRequire(try probe(contested, workspace: workspace) == "acquired", "Contended lock failed to release")
        try attacks(directory)
    }

    private static func attacks(_ directory: URL) throws {
        let sentinel = directory.appendingPathComponent("sentinel")
        let payload = Data("synthetic lock sentinel\n".utf8)
        try payload.write(to: sentinel)
        try instanceRequire(chmod(sentinel.path, 0o640) == 0, "Cannot set sentinel permissions")
        let original = try fileInfo(sentinel)
        for kind in ["symlink", "hardlink", "fifo", "directory"] {
            let root = try fixture(directory, kind)
            let lock = root.appendingPathComponent(".instance.lock")
            switch kind {
            case "symlink": try instanceRequire(symlink(sentinel.path, lock.path) == 0, "Cannot create symlink fixture")
            case "hardlink": try instanceRequire(link(sentinel.path, lock.path) == 0, "Cannot create hardlink fixture")
            case "fifo": try instanceRequire(mkfifo(lock.path, 0o640) == 0, "Cannot create FIFO fixture")
            default: try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false,
                                                             attributes: [.posixPermissions: 0o750])
            }
            let before = try fileInfo(lock)
            try expectRejected(root)
            let after = try fileInfo(lock)
            let sentinelAfter = try fileInfo(sentinel)
            try instanceRequire(StoragePaths.sameIdentity(before, after) && before.st_mode == after.st_mode,
                                "Rejected lock fixture was altered")
            try instanceRequire(try Data(contentsOf: sentinel) == payload
                && StoragePaths.sameIdentity(original, sentinelAfter) && original.st_mode == sentinelAfter.st_mode,
                                "Rejected lock changed sentinel contents or permissions")
            if kind == "hardlink" { try FileManager.default.removeItem(at: lock) }
        }
        let linkedRoot = directory.appendingPathComponent("linked-root")
        let targetRoot = try fixture(directory, "root-sentinel")
        try instanceRequire(chmod(targetRoot.path, 0o750) == 0, "Cannot set root sentinel permissions")
        try instanceRequire(symlink(targetRoot.path, linkedRoot.path) == 0, "Cannot create linked root fixture")
        let rootBefore = try fileInfo(targetRoot)
        try expectRejected(linkedRoot)
        let rootAfter = try fileInfo(targetRoot)
        try instanceRequire(rootBefore.st_mode == rootAfter.st_mode && StoragePaths.sameIdentity(rootBefore, rootAfter),
                            "Rejected root symlink changed target directory")
        try instanceRequire(!FileManager.default.fileExists(atPath: targetRoot.appendingPathComponent(".instance.lock").path),
                            "Rejected root symlink created a lock in its target")
    }

    private static func expectRejected(_ directory: URL) throws {
        do {
            let token = try SingleInstanceLock.acquire(directory: directory)
            withExtendedLifetime(token) {}
        } catch is StoragePaths.Failure { return }
        throw InstanceCheckFailure("Unsafe lock fixture was not rejected")
    }

    private static func withToken(_ directory: URL, operation: () throws -> Void) throws {
        guard let token = try SingleInstanceLock.acquire(directory: directory) else {
            throw InstanceCheckFailure("Synthetic lock was unexpectedly occupied")
        }
        try withExtendedLifetime(token, operation)
    }

    private static func fixture(_ directory: URL, _ name: String) throws -> URL {
        let result = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return result
    }

    private static func fileInfo(_ url: URL) throws -> stat {
        var result = stat()
        try instanceRequire(StoragePaths.retryOnInterrupt { lstat(url.path, &result) } == 0, "Cannot inspect synthetic fixture")
        return result
    }

    /// Relative, existing, owned directories only; neither absolute paths nor symlink escapes are helper inputs.
    private static func helperDirectory(_ relative: String, workspace: URL) throws -> URL {
        let components = relative.components(separatedBy: "/")
        try instanceRequire(workspace.lastPathComponent == "data"
            && workspace.deletingLastPathComponent().lastPathComponent.hasPrefix("cvmaster-regressions."),
                            "Helper requires runner-owned workspace")
        try instanceRequire(!components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && !relative.utf8.contains(0), "Helper path must be workspace-relative")
        var current = workspace
        for component in [""] + components {
            if !component.isEmpty { current.appendPathComponent(component, isDirectory: true) }
            let info = try fileInfo(current)
            try instanceRequire((info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid() && info.st_nlink > 0,
                                "Helper directory must be owned and must not be a symlink")
        }
        return current
    }

    private static func probe(_ directory: URL, workspace: URL) throws -> String {
        let child = try Child("probe", directory: directory, workspace: workspace)
        defer { child.stop() }
        let result = try child.line()
        try child.finish()
        return result
    }

    private static func report(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }

    private static func receiveGate() throws {
        var byte: UInt8 = 0
        let count = StoragePaths.retryOnInterrupt { Int32(Darwin.read(STDIN_FILENO, &byte, 1)) }
        try instanceRequire(count == 1 && byte == 1, "Missing helper gate")
    }

    private final class Child {
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()

        init(_ mode: String, directory: URL, workspace: URL) throws {
            let prefix = workspace.path + "/"
            try instanceRequire(directory.path.hasPrefix(prefix), "Child directory is outside workspace")
            let relative = String(directory.path.dropFirst(prefix.count))
            _ = try helperDirectory(relative, workspace: workspace)
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--workspace", workspace.path, "--single-instance-helper", mode, relative]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            input.fileHandleForReading.closeFile()
            output.fileHandleForWriting.closeFile()
        }

        deinit { stop() }

        func line() throws -> String {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            var bytes: [UInt8] = []
            while ProcessInfo.processInfo.systemUptime < deadline && bytes.count < 64 {
                var pollFD = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = StoragePaths.retryOnInterrupt { poll(&pollFD, 1, 100) }
                try instanceRequire(ready >= 0, "Cannot poll helper output")
                if ready == 0 { continue }
                var byte: UInt8 = 0
                let count = Darwin.read(pollFD.fd, &byte, 1)
                if count < 0 && errno == EINTR { continue }
                try instanceRequire(count == 1, "Helper exited before reporting a result")
                if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
                bytes.append(byte)
            }
            throw InstanceCheckFailure("Timed out waiting for helper result")
        }

        func sendGate() throws { try input.fileHandleForWriting.write(contentsOf: Data([1])) }

        func killOwner() throws {
            try instanceRequire(Darwin.kill(process.processIdentifier, SIGKILL) == 0, "Cannot stop synthetic lock owner")
        }

        func finish(expectKilled: Bool = false) throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
            try instanceRequire(!process.isRunning, "Timed out waiting for helper exit")
            process.waitUntilExit()
            try instanceRequire(expectKilled
                ? process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL
                : process.terminationReason == .exit && process.terminationStatus == 0, "Helper failed")
        }

        func stop() {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
    }
}
