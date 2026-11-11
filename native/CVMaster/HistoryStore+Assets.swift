/**
 * 内容资产文件的描述符相对读写、孤立资产回收与权限收紧。
 * @author helele
 * @since 2026-11-09
 */
import Foundation
import SQLite3
import OSLog
import Darwin

extension HistoryStore {
    func assetURL(_ name: String) -> URL? {
        guard UUID(uuidString: name) != nil else { return nil }
        return root?.appendingPathComponent("assets/\(name)")
    }

    func assetData(_ name: String, maximum: Int, expectedSize: Int? = nil) throws -> Data {
        guard UUID(uuidString: name) != nil, maximum >= 0 else { throw LibraryError.missingContent }
        let descriptor = openat(assetsDescriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw LibraryError.missingContent }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size >= 0 else { throw LibraryError.missingContent }
        if let expectedSize, info.st_size != Int64(expectedSize) { throw LibraryError.missingContent }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximum) ?? Data()
        if let expectedSize, data.count != expectedSize { throw LibraryError.missingContent }
        return data
    }

    /// UUID 独占创建、0600 起始权限；未提交文件不可见，失败只回收本次创建的文件。
    func writeAsset(_ data: Data, name: String) throws {
        let descriptor = openat(assetsDescriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LibraryError.storage }
        defer { Darwin.close(descriptor) }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw LibraryError.storage }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw LibraryError.storage }
        } catch {
            unlinkat(assetsDescriptor, name, 0)
            throw error
        }
    }

    func unlinkAssets(_ names: [String]) {
        for name in names where UUID(uuidString: name) != nil {
            if unlinkat(assetsDescriptor, name, 0) != 0, errno != ENOENT {
                logger.warning("Orphan asset removal deferred")
            }
        }
    }

    /// BEGIN IMMEDIATE 覆盖完整引用扫描和 unlink，阻止另一连接在扫描后提交新资产引用。
    /// 删除自身已先提交；维护失败仍由调用者记录延后，不伪装删除回滚。checkpoint 在事务外。
    func recoverAssets() throws {
        guard assetsDescriptor >= 0 else { throw LibraryError.storage }
        try transaction {
            let query = try statement("SELECT filename FROM representation")
            var referenced: Set<String> = []
            do {
                defer { sqlite3_finalize(query) }
                while try next(query) {
                    let name = text(query, 0, maximumBytes: 36, rejectOversized: true)
                    guard UUID(uuidString: name) != nil else { throw LibraryError.storage }
                    referenced.insert(name)
                }
            }
            let duplicate = dup(assetsDescriptor)
            guard duplicate >= 0 else { throw LibraryError.storage }
            guard let directory = fdopendir(duplicate) else { Darwin.close(duplicate); throw LibraryError.storage }
            defer { closedir(directory) }
            // dup 共享目录位置，每次扫描前重置，否则清空后的扫描可能从 EOF 开始。
            rewinddir(directory)
            while true {
                errno = 0
                guard let item = readdir(directory) else {
                    guard errno == 0 else { throw LibraryError.storage }
                    break
                }
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                guard UUID(uuidString: name) != nil else { continue }
                if !referenced.contains(name) { unlinkAssets([name]); continue }
                // 已有资产也收紧权限；不 chmod 链接、目录、其他所有者或多硬链接文件。
                let descriptor = openat(assetsDescriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                if descriptor < 0 { continue }
                var info = stat()
                let regular = fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
                if regular, info.st_uid == getuid(), info.st_nlink == 1 {
                    let status = fchmod(descriptor, 0o600)
                    Darwin.close(descriptor)
                    guard status == 0 else { throw LibraryError.storage }
                } else { Darwin.close(descriptor) }
            }
        }
    }
}
