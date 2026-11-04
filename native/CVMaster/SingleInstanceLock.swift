/**
 * 启动前的进程级互斥；只处理应用根目录与锁文件，不打开历史库或内容资产。
 * @author helele
 * @since 2026-11-04
 */
import Foundation
import Darwin

/// 锁与历史存储共用同一默认路径；错误不携带路径或文件内容。
enum StoragePaths {
    enum Failure: Error { case unavailable }

    static func applicationDirectory(directory: URL? = nil) throws -> URL {
        let result: URL
        if let directory {
            result = directory
        } else {
            result = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("cvMaster", isDirectory: true)
        }
        guard result.isFileURL, result.host == nil || result.host == "" || result.host == "localhost",
              result.path.hasPrefix("/"), !result.path.utf8.contains(0), result.path != "/",
              !result.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw Failure.unavailable
        }
        return result
    }

    static func retryOnInterrupt(_ operation: () -> Int32) -> Int32 {
        var result: Int32
        repeat { result = operation() } while result == -1 && errno == EINTR
        return result
    }

    static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    /// 仅在描述符验证后收紧本目录；不遍历或 chmod 已有数据库、边车与资产。
    static func secureDirectory(_ descriptor: Int32) throws {
        var info = stat()
        guard descriptor >= 0, retryOnInterrupt({ fstat(descriptor, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), info.st_nlink > 0,
              retryOnInterrupt({ fchmod(descriptor, 0o700) }) == 0 else { throw Failure.unavailable }
    }
}

/// flock 属于打开的文件描述；持有 token 到应用 main 返回，关闭时不 unlink，保持 inode 稳定。
final class SingleInstanceLock {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    /// nil 仅表示另一进程已持锁；其余异常一律 fail closed，不能继续构造应用。
    static func acquire(directory: URL? = nil) throws -> SingleInstanceLock? {
        let root = try StoragePaths.applicationDirectory(directory: directory)
        if StoragePaths.retryOnInterrupt({ mkdir(root.path, 0o700) }) != 0, errno != EEXIST {
            throw StoragePaths.Failure.unavailable
        }
        let directoryFD = StoragePaths.retryOnInterrupt {
            Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else { throw StoragePaths.Failure.unavailable }
        defer { Darwin.close(directoryFD) }
        try verifyDirectory(directoryFD, at: root)
        try StoragePaths.secureDirectory(directoryFD)
        try verifyDirectory(directoryFD, at: root)

        let flags = O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var fileFD = StoragePaths.retryOnInterrupt {
            openat(directoryFD, ".instance.lock", flags | O_CREAT | O_EXCL, 0o600)
        }
        if fileFD < 0, errno == EEXIST {
            fileFD = StoragePaths.retryOnInterrupt { openat(directoryFD, ".instance.lock", flags) }
        }
        guard fileFD >= 0 else { throw StoragePaths.Failure.unavailable }
        var transferred = false
        defer { if !transferred { Darwin.close(fileFD) } }
        try verifyFile(fileFD, in: directoryFD)
        let result = StoragePaths.retryOnInterrupt { flock(fileFD, LOCK_EX | LOCK_NB) }
        if result != 0 {
            if errno == EWOULDBLOCK || errno == EAGAIN { return nil }
            throw StoragePaths.Failure.unavailable
        }
        // 持锁后再次核对目录与文件身份，拒绝 open/flock 之间的替换或新硬链接。
        try verifyDirectory(directoryFD, at: root)
        try verifyFile(fileFD, in: directoryFD)
        guard StoragePaths.retryOnInterrupt({ fchmod(fileFD, 0o600) }) == 0 else {
            throw StoragePaths.Failure.unavailable
        }
        try verifyDirectory(directoryFD, at: root)
        try verifyFile(fileFD, in: directoryFD)
        transferred = true
        return SingleInstanceLock(descriptor: fileFD)
    }

    private static func verifyDirectory(_ descriptor: Int32, at directory: URL) throws {
        var opened = stat(), named = stat()
        guard StoragePaths.retryOnInterrupt({ fstat(descriptor, &opened) }) == 0,
              StoragePaths.retryOnInterrupt({ lstat(directory.path, &named) }) == 0,
              (opened.st_mode & S_IFMT) == S_IFDIR, (named.st_mode & S_IFMT) == S_IFDIR,
              opened.st_uid == getuid(), opened.st_nlink > 0,
              StoragePaths.sameIdentity(opened, named) else { throw StoragePaths.Failure.unavailable }
    }

    private static func verifyFile(_ descriptor: Int32, in directory: Int32) throws {
        var opened = stat(), named = stat()
        guard StoragePaths.retryOnInterrupt({ fstat(descriptor, &opened) }) == 0,
              StoragePaths.retryOnInterrupt({ fstatat(directory, ".instance.lock", &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG, (named.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == getuid(), opened.st_nlink == 1, named.st_nlink == 1,
              StoragePaths.sameIdentity(opened, named) else { throw StoragePaths.Failure.unavailable }
    }
}
