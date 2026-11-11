/**
 * SQLite 串行后台存储核心：连接生命周期、目录描述符与私有权限加固。
 * 查询、变更、分组、内容读取、资产与缩略图缓存分别位于 HistoryStore+*.swift 扩展。
 * 关系型元数据与独立内容文件，不使用 JSON 字段；所有操作均与 MainActor 隔离。
 * @author helele
 * @since 2026-10-19
 */
import Foundation
import SQLite3
import OSLog
import Darwin

/// 只允许预定义绑定类型，不拼接用户提供的 SQL。
enum SQLValue {
    case text(String), integer(Int), real(Double)
}

actor HistoryStore {
    // 以下状态由各扩展文件共享，仅限本 actor 隔离域内访问。
    /// 数据库连接仅由本 actor 访问，避免并发共享 SQLite 指针。
    var database: OpaquePointer?
    var root: URL?
    var rootDescriptor: Int32 = -1
    var assetsDescriptor: Int32 = -1
    let directoryOverride: URL?
    let enablesTrigram: Bool
    var hasTrigram = false
    var cachedStats: StorageStats?
    let logger = Logger(subsystem: "local.helele.cvmaster", category: "storage")
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// 缩略图像素缓存、失效代数与活跃等待者计数，见 HistoryStore+Thumbnails.swift。
    var thumbnailCache = ThumbnailCache()

    /// 可注入独立目录并关闭可选索引，供隔离回归测试；默认仍只使用应用目录。
    init(directory: URL? = nil, enablesTrigram: Bool = true) {
        directoryOverride = directory
        self.enablesTrigram = enablesTrigram
    }

    isolated deinit {
        sqlite3_close(database)
        if assetsDescriptor >= 0 { Darwin.close(assetsDescriptor) }
        if rootDescriptor >= 0 { Darwin.close(rootDescriptor) }
    }

    /// 首次初始化后复用连接；不回退到临时库，不跟随应用目录、数据库或边车符号链接。
    func prepare() throws {
        if database != nil {
            try verifyDirectories()
            try secureDatabaseFile("history.sqlite")
            try hardenSidecars()
            return
        }
        do {
            let directory = try StoragePaths.applicationDirectory(directory: directoryOverride)
            rootDescriptor = StoragePaths.retryOnInterrupt { Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            try StoragePaths.secureDirectory(rootDescriptor)
            if StoragePaths.retryOnInterrupt({ mkdirat(rootDescriptor, "assets", 0o700) }) != 0, errno != EEXIST { throw LibraryError.storage }
            assetsDescriptor = StoragePaths.retryOnInterrupt { openat(rootDescriptor, "assets", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            try StoragePaths.secureDirectory(assetsDescriptor)
            // 在 SQLite 打开前创建 0600 普通文件，避免先暴露内容再 chmod 的时间窗口。
            try secureDatabaseFile("history.sqlite", create: true)
            try hardenSidecars()
            let file = directory.appendingPathComponent("history.sqlite")
            var connection: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
            guard sqlite3_open_v2(file.path, &connection, flags, nil) == SQLITE_OK else {
                sqlite3_close(connection)
                throw LibraryError.storage
            }
            database = connection
            root = directory
            sqlite3_busy_timeout(connection, 1500)
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA journal_mode=WAL")
            try hardenSidecars()
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA cache_size=-2048")
            try execute("PRAGMA journal_size_limit=4194304")
            let version = try scalar("PRAGMA user_version")
            guard version <= 4 else { throw LibraryError.storage }
            try execute("""
                CREATE TABLE IF NOT EXISTS entry(
                    id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
                    title TEXT NOT NULL, excerpt TEXT NOT NULL, search_text TEXT NOT NULL,
                    source TEXT NOT NULL, copied_at REAL NOT NULL, byte_size INTEGER NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0, copies INTEGER NOT NULL DEFAULT 1);
                CREATE INDEX IF NOT EXISTS entry_order ON entry(pinned DESC,copied_at DESC,id);
                CREATE TABLE IF NOT EXISTS user_group(
                    id TEXT PRIMARY KEY,name TEXT NOT NULL COLLATE NOCASE UNIQUE,color INTEGER NOT NULL,position INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS entry_group(
                    entry_id TEXT NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
                    group_id TEXT NOT NULL REFERENCES user_group(id) ON DELETE CASCADE,
                    PRIMARY KEY(entry_id,group_id));
                CREATE INDEX IF NOT EXISTS group_entries ON entry_group(group_id,entry_id);
                CREATE TABLE IF NOT EXISTS representation(
                    id TEXT PRIMARY KEY,entry_id TEXT NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
                    item_order INTEGER NOT NULL,uti TEXT NOT NULL,filename TEXT NOT NULL UNIQUE,byte_size INTEGER NOT NULL);
                CREATE INDEX IF NOT EXISTS representation_entry ON representation(entry_id,item_order);
                CREATE TABLE IF NOT EXISTS search_meta(id INTEGER PRIMARY KEY CHECK(id=1),dirty INTEGER NOT NULL);
                INSERT OR IGNORE INTO search_meta(id,dirty) VALUES(1,1);
                """)
            try transaction {
                if version < 2 {
                    try execute("ALTER TABLE entry ADD COLUMN source_bundle_id TEXT NOT NULL DEFAULT ''")
                }
                if version < 3 { try reclassifyImageFiles() }
                if version < 4 {
                    // 显示文案不再是持久化键；未知类型保留原值，读取时安全回退为文本。
                    for kind in ClipKind.allCases {
                        try execute("UPDATE entry SET kind=? WHERE kind=?", [.text(kind.storageValue), .text(kind.rawValue)])
                    }
                }
                try execute("PRAGMA user_version=4")
            }
            try configureSearch()
            try recoverAssets()
            logger.info("Local storage ready; schema version 4")
        } catch {
            sqlite3_close(database)
            database = nil
            root = nil
            hasTrigram = false
            if assetsDescriptor >= 0 { Darwin.close(assetsDescriptor); assetsDescriptor = -1 }
            if rootDescriptor >= 0 { Darwin.close(rootDescriptor); rootDescriptor = -1 }
            logger.error("Local storage initialization failed")
            throw LibraryError.storage
        }
    }

    /// 拒绝准备后 root/assets 被替换为其他 inode；资产 I/O 仍相对已打开描述符执行。
    func verifyDirectories() throws {
        guard let root else { throw LibraryError.storage }
        var openedRoot = stat(), pathRoot = stat(), openedAssets = stat(), pathAssets = stat()
        guard fstat(rootDescriptor, &openedRoot) == 0, lstat(root.path, &pathRoot) == 0,
              (pathRoot.st_mode & S_IFMT) == S_IFDIR,
              StoragePaths.sameIdentity(openedRoot, pathRoot),
              fstat(assetsDescriptor, &openedAssets) == 0,
              fstatat(rootDescriptor, "assets", &pathAssets, AT_SYMLINK_NOFOLLOW) == 0,
              (pathAssets.st_mode & S_IFMT) == S_IFDIR,
              StoragePaths.sameIdentity(openedAssets, pathAssets) else {
            throw LibraryError.storage
        }
        try StoragePaths.secureDirectory(rootDescriptor)
        try StoragePaths.secureDirectory(assetsDescriptor)
    }

    func secureDatabaseFile(_ name: String, create: Bool = false) throws {
        let descriptor = openat(rootDescriptor, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
        if descriptor < 0, !create, errno == ENOENT { return }
        guard descriptor >= 0 else { throw LibraryError.storage }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0 else { throw LibraryError.storage }
    }

    func hardenSidecars() throws {
        try secureDatabaseFile("history.sqlite-wal")
        try secureDatabaseFile("history.sqlite-shm")
        try secureDatabaseFile("history.sqlite-journal")
    }
}
